#!/usr/bin/env python3

import json
import socket
import sys
import time
from datetime import datetime
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen


class TransportError(Exception):
    pass


DEFAULT_BASE_URL = "https://api.transitous.org"
REQUEST_TIMEOUT_SECONDS = 12
REQUEST_RETRIES = 2


def fail(message: str, code: int = 1) -> None:
    print(json.dumps({"error": message}, ensure_ascii=True))
    raise SystemExit(code)


def normalize_base_url(value: str) -> str:
    base = (value or "").strip()
    if not base:
        return DEFAULT_BASE_URL
    if base.rstrip("/") == "https://v6.db.transport.rest":
        return DEFAULT_BASE_URL
    return base[:-1] if base.endswith("/") else base


def is_timeout_error(error: object) -> bool:
    if isinstance(error, TimeoutError):
        return True
    if isinstance(error, socket.timeout):
        return True
    if isinstance(error, URLError):
        reason = error.reason
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return True
        if isinstance(reason, str) and "timed out" in reason.lower():
            return True
    return False


def is_retryable_http_error(status_code: int) -> bool:
    return status_code in (429, 500, 502, 503, 504)


def fetch_json(base_url: str, path: str, params: dict[str, object] | None = None) -> object:
    url = normalize_base_url(base_url) + path
    if params:
        query = urlencode([(key, str(value)) for key, value in params.items() if value is not None])
        if query:
            url += "?" + query

    request = Request(
        url,
        headers={
            "accept": "application/json",
            "user-agent": "dms-public-transport/1.0",
        },
    )

    last_error: Exception | None = None
    for attempt in range(REQUEST_RETRIES + 1):
        try:
            with urlopen(request, timeout=REQUEST_TIMEOUT_SECONDS) as response:
                return json.loads(response.read().decode("utf-8"))
        except HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace").strip()
            if attempt < REQUEST_RETRIES and is_retryable_http_error(exc.code):
                time.sleep(0.5 * (attempt + 1))
                continue
            if exc.code == 503:
                raise TransportError("Die Transport-API ist momentan ueberlastet (503). Bitte versuche es gleich noch einmal.") from exc
            if exc.code == 429:
                raise TransportError("Das Ratenlimit der Transport-API wurde erreicht (429). Bitte versuche es in Kuerze erneut.") from exc
            if exc.code == 404:
                raise TransportError("Die angefragte Station wurde in der Transport-API nicht gefunden.") from exc
            if detail:
                raise TransportError(f"Transport-API-Fehler {exc.code}: {detail}") from exc
            raise TransportError(f"Transport-API-Fehler {exc.code}.") from exc
        except json.JSONDecodeError as exc:
            raise TransportError("Die Transport-API hat ungueltiges JSON zurueckgegeben.") from exc
        except (URLError, TimeoutError, socket.timeout) as exc:
            last_error = exc
            if attempt < REQUEST_RETRIES and is_timeout_error(exc):
                time.sleep(0.35 * (attempt + 1))
                continue
            if is_timeout_error(exc):
                raise TransportError("Zeitueberschreitung bei der Anfrage an die Transport-API.") from exc
            if isinstance(exc, URLError):
                raise TransportError(f"Transport-API nicht erreichbar: {exc.reason}") from exc
            raise TransportError("Transport-API nicht erreichbar.") from exc

    raise TransportError(f"Anfrage an die Transport-API fehlgeschlagen: {last_error}")


def parse_iso(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def time_text(value: str | None) -> str:
    parsed = parse_iso(value)
    if not parsed:
        return ""
    return parsed.astimezone().strftime("%H:%M")


def minutes_until(value: str | None) -> int | None:
    parsed = parse_iso(value)
    if not parsed:
        return None
    now = datetime.now(parsed.tzinfo)
    delta = parsed - now
    return int(round(delta.total_seconds() / 60.0))


def duration_minutes(departure: str | None, arrival: str | None) -> int | None:
    start = parse_iso(departure)
    end = parse_iso(arrival)
    if not start or not end:
        return None
    return max(0, int(round((end - start).total_seconds() / 60.0)))


def delay_minutes(actual: str | None, scheduled: str | None) -> int:
    actual_dt = parse_iso(actual)
    scheduled_dt = parse_iso(scheduled)
    if not actual_dt or not scheduled_dt:
        return 0
    return int(round((actual_dt - scheduled_dt).total_seconds() / 60.0))


def parse_favorite_specs(raw: str) -> list[str]:
    specs: list[str] = []
    for chunk in raw.replace("\n", ";").split(";"):
        item = chunk.strip()
        if item:
            specs.append(item)
    return specs


def split_station_spec(spec: str) -> tuple[str, str]:
    raw = (spec or "").strip()
    if "|" not in raw:
        return raw, ""
    label, station_id = raw.rsplit("|", 1)
    return label.strip(), station_id.strip()


def mode_label(mode: str | None) -> str:
    mapping = {
        "WALK": "Zu Fuss",
        "BUS": "Bus",
        "TRAM": "Tram",
        "SUBWAY": "U-Bahn",
        "RAIL": "Bahn",
        "REGIONAL_RAIL": "Regionalbahn",
        "SUBURBAN": "S-Bahn",
        "FERRY": "Faehre",
        "FUNICULAR": "Schwebebahn",
        "COACH": "Fernbus",
    }
    key = str(mode or "").strip().upper()
    return mapping.get(key, key.title() if key else "")


def has_replacement_marker(*values: object) -> bool:
    for value in values:
        text = str(value or "").lower()
        if "sev" in text or "schienenersatz" in text:
            return True
    return False


def looks_like_rail_line(value: str) -> bool:
    text = str(value or "").strip().upper()
    if not text:
        return False
    prefixes = ("S", "RE", "RB", "IC", "ICE", "EC", "IRE", "RS", "ME", "U")
    return text.startswith(prefixes)


def is_replacement_service(mode: str | None, *values: object) -> bool:
    mode_key = str(mode or "").strip().upper()
    if mode_key != "BUS":
        return False
    if has_replacement_marker(*values):
        return True
    return any(looks_like_rail_line(str(value or "")) for value in values)


def display_line_label(mode: str | None, primary: str, secondary: str = "", *context: object) -> tuple[str, str]:
    base_line = str(primary or "").strip() or str(secondary or "").strip()
    replacement = is_replacement_service(mode, primary, secondary, *context)
    if replacement:
        line = f"{base_line} (SEV)" if base_line and "SEV" not in base_line.upper() else (base_line or "SEV")
        return line, "SEV"
    if base_line:
        return base_line, mode_label(mode) or ""
    return mode_label(mode) or "Abschnitt", mode_label(mode) or ""


def station_from_geocode(entry: dict[str, object] | None) -> dict[str, str]:
    item = entry or {}
    station_id = str(item.get("id") or item.get("stopId") or "").strip()
    station_name = str(item.get("name") or station_id).strip()
    return {
        "id": station_id,
        "name": station_name,
        "displayName": station_name,
    }


def is_transitous_stop_id(value: str) -> bool:
    station_id = (value or "").strip()
    return ":" in station_id or station_id.startswith(("de-", "eu-", "nl-", "ch-", "at-", "fi-"))


def resolve_station_name(base_url: str, station_id: str) -> str:
    data = fetch_json(
        base_url,
        "/api/v5/stoptimes",
        {
            "stopId": station_id,
            "n": 1,
        },
    )
    if not isinstance(data, dict):
        return station_id
    place = data.get("place") if isinstance(data.get("place"), dict) else {}
    name = str(place.get("name") or "").strip()
    return name or station_id


def normalized_search_text(value: str) -> str:
    normalized = (value or "").lower().strip()
    replacements = {
        "hauptbahnhof": "hbf",
        "bahnhof": "bf",
        "straße": "strasse",
        "str.": "strasse",
        "-": " ",
        "/": " ",
        "(": " ",
        ")": " ",
        ",": " ",
    }
    for source, target in replacements.items():
        normalized = normalized.replace(source, target)
    return " ".join(normalized.split())


def canonical_station_name(value: str) -> str:
    text = normalized_search_text(value)
    tokens = text.split()
    suffixes = {"bf", "hbf"}
    while tokens and tokens[-1] in suffixes:
        tokens.pop()
    return " ".join(tokens)


def location_priority(query: str, entry: dict[str, object]) -> tuple[int, int, int, int, float, int, str]:
    station = station_from_geocode(entry)
    station_id = station["id"]
    station_name = station["name"].lower()
    normalized_name = normalized_search_text(station["name"])
    normalized_query = normalized_search_text(query)
    canonical_name = canonical_station_name(station["name"])
    canonical_query = canonical_station_name(query)
    modes = entry.get("modes") if isinstance(entry.get("modes"), list) else []
    has_modes = 1 if len(modes) > 0 else 0
    exact_name = 1 if canonical_name == canonical_query else 0
    starts_with = 1 if normalized_name.startswith(normalized_query) else 0
    sev_penalty = 1 if any(token in normalized_name for token in (" sev", " schienenersatz", " ersatz")) or normalized_name.endswith(" sev") else 0
    is_delfi = 1 if station_id.startswith("de-DELFI") else 0
    api_score = float(entry.get("score")) if isinstance(entry.get("score"), (int, float)) else 0.0
    return (-exact_name, -starts_with, sev_penalty, -is_delfi, api_score, -has_modes, station_name + station_id)


def should_reresolve_saved_station(label: str, station_id: str) -> bool:
    if not label:
        return False
    raw_id = str(station_id or "").strip()
    return raw_id.startswith("nl-OpenOV_stoparea:") or raw_id.startswith("de-VBN_")


def geocode_locations(base_url: str, query: str) -> list[dict[str, object]]:
    data = fetch_json(
        base_url,
        "/api/v1/geocode",
        {
            "text": query,
            "language": "de",
            "type": "STOP",
        },
    )
    if not isinstance(data, list):
        return []
    results = [entry for entry in data if isinstance(entry, dict) and str(entry.get("type") or "").upper() == "STOP"]
    results.sort(key=lambda entry: location_priority(query, entry))
    return results


def resolve_location(base_url: str, spec: str) -> dict[str, str]:
    raw = (spec or "").strip()
    if not raw:
        raise TransportError("Es wurde keine Station angegeben.")

    label, station_id = split_station_spec(raw)
    query_text = label or raw

    if station_id and is_transitous_stop_id(station_id):
        if should_reresolve_saved_station(label, station_id):
            locations = geocode_locations(base_url, label)
            for entry in locations:
                station = station_from_geocode(entry)
                if station["id"].startswith("de-DELFI"):
                    return station
            for entry in locations:
                station = station_from_geocode(entry)
                if station["id"]:
                    return station
        station_name = label if label and label != station_id else resolve_station_name(base_url, station_id)
        return {"id": station_id, "name": station_name, "displayName": station_name}

    if raw and is_transitous_stop_id(raw):
        station_name = resolve_station_name(base_url, raw)
        return {"id": raw, "name": station_name, "displayName": station_name}

    if raw.isdigit() and not label:
        raise TransportError(f"Station '{raw}' konnte nicht mit Transitous aufgeloest werden.")

    locations = geocode_locations(base_url, query_text)
    for entry in locations:
        station = station_from_geocode(entry)
        if station["id"]:
            return station

    raise TransportError(f"Station '{query_text}' wurde nicht gefunden.")


def location_results(base_url: str, query: str) -> dict[str, object]:
    raw = (query or "").strip()
    if not raw:
        return {"locations": []}
    results = []
    seen_ids: set[str] = set()
    for entry in geocode_locations(base_url, raw):
        station = station_from_geocode(entry)
        if not station["id"] or station["id"] in seen_ids:
            continue
        seen_ids.add(station["id"])
        results.append(station)
        if len(results) >= 8:
            break
    return {"locations": results}


def favorites_results(base_url: str, raw: str) -> dict[str, object]:
    favorites = []
    errors = []
    seen_ids: set[str] = set()
    for spec in parse_favorite_specs(raw):
        try:
            station = resolve_location(base_url, spec)
            if station["id"] in seen_ids:
                continue
            seen_ids.add(station["id"])
            favorites.append(station)
        except TransportError:
            errors.append(spec)
    return {"favorites": favorites, "unresolved": errors}


def departures_results(base_url: str, station_spec: str) -> dict[str, object]:
    station = resolve_location(base_url, station_spec)
    data = fetch_json(
        base_url,
        "/api/v5/stoptimes",
        {
            "stopId": station["id"],
            "n": 8,
        },
    )
    items = []
    for departure in (data.get("stopTimes") if isinstance(data, dict) else []) or []:
        if not isinstance(departure, dict):
            continue
        place = departure.get("place") if isinstance(departure.get("place"), dict) else {}
        actual = str(place.get("departure") or place.get("arrival") or "")
        scheduled = str(place.get("scheduledDeparture") or place.get("scheduledArrival") or actual)
        line_name, _ = display_line_label(
            str(departure.get("mode") or ""),
            str(departure.get("displayName") or "").strip(),
            str(departure.get("routeShortName") or "").strip(),
            place.get("name"),
            place.get("description"),
            departure.get("headsign"),
            departure.get("agencyName"),
        )
        items.append(
            {
                "line": line_name,
                "direction": str(departure.get("headsign") or departure.get("tripTo", {}).get("name") or "").strip(),
                "when": actual,
                "plannedWhen": scheduled,
                "timeText": time_text(actual),
                "minutes": minutes_until(actual),
                "delayMinutes": delay_minutes(actual, scheduled),
                "platform": str(place.get("track") or place.get("scheduledTrack") or "").strip(),
            }
        )

    return {
        "station": station,
        "departures": items[:10],
    }


def stopover_summary(stop: dict[str, object]) -> dict[str, str]:
    arrival = str(stop.get("arrival") or stop.get("scheduledArrival") or "")
    departure = str(stop.get("departure") or stop.get("scheduledDeparture") or "")
    return {
        "name": str(stop.get("name") or "").strip(),
        "arrivalText": time_text(arrival),
        "departureText": time_text(departure),
    }


def leg_summary(leg: dict[str, object]) -> dict[str, object]:
    origin = leg.get("from") if isinstance(leg.get("from"), dict) else {}
    destination = leg.get("to") if isinstance(leg.get("to"), dict) else {}
    departure = str(origin.get("departure") or origin.get("scheduledDeparture") or leg.get("startTime") or leg.get("scheduledStartTime") or "")
    arrival = str(destination.get("arrival") or destination.get("scheduledArrival") or leg.get("endTime") or leg.get("scheduledEndTime") or "")
    mode = str(leg.get("mode") or "").strip()
    walking = mode.upper() == "WALK"
    if walking:
        line_name = "Zu Fuss"
        product_name = "Zu Fuss"
    else:
        line_name, product_name = display_line_label(
            mode,
            str(leg.get("displayName") or "").strip(),
            str(leg.get("routeShortName") or "").strip(),
            origin.get("name"),
            origin.get("description"),
            destination.get("name"),
            destination.get("description"),
            leg.get("headsign"),
            leg.get("agencyName"),
        )
    stopovers = []
    for stop in leg.get("intermediateStops", []) if isinstance(leg.get("intermediateStops"), list) else []:
        if not isinstance(stop, dict):
            continue
        item = stopover_summary(stop)
        if item["name"]:
            stopovers.append(item)
    return {
        "line": line_name,
        "product": product_name,
        "operator": str(leg.get("agencyName") or "").strip(),
        "direction": str(leg.get("headsign") or destination.get("name") or "").strip(),
        "origin": str(origin.get("name") or "").strip(),
        "destination": str(destination.get("name") or "").strip(),
        "departure": departure,
        "arrival": arrival,
        "departureText": time_text(departure),
        "arrivalText": time_text(arrival),
        "platform": str(origin.get("track") or origin.get("scheduledTrack") or "").strip(),
        "arrivalPlatform": str(destination.get("track") or destination.get("scheduledTrack") or "").strip(),
        "stopovers": stopovers,
    }


def journey_results(base_url: str, from_spec: str, to_spec: str, page_cursor: str = "") -> dict[str, object]:
    origin = resolve_location(base_url, from_spec)
    destination = resolve_location(base_url, to_spec)
    params = {
        "fromPlace": origin["id"],
        "toPlace": destination["id"],
    }
    if page_cursor.strip():
        params["pageCursor"] = page_cursor.strip()
    data = fetch_json(base_url, "/api/v5/plan", params)
    journeys = []
    for itinerary in (data.get("itineraries") if isinstance(data, dict) else []) or []:
        if not isinstance(itinerary, dict):
            continue
        legs = [leg_summary(leg) for leg in itinerary.get("legs", []) if isinstance(leg, dict)]
        if not legs:
            continue
        first_leg = legs[0]
        last_leg = legs[-1]
        summary_lines = []
        for leg in legs:
            line_name = str(leg.get("line") or "").strip()
            if not line_name or line_name == "Zu Fuss":
                continue
            if line_name not in summary_lines:
                summary_lines.append(line_name)
        duration = itinerary.get("duration")
        duration_mins = int(round(float(duration) / 60.0)) if isinstance(duration, (int, float)) else duration_minutes(first_leg["departure"], last_leg["arrival"])
        journeys.append(
            {
                "departure": first_leg["departure"],
                "arrival": last_leg["arrival"],
                "departureText": first_leg["departureText"],
                "arrivalText": last_leg["arrivalText"],
                "durationMinutes": duration_mins,
                "transfers": int(itinerary.get("transfers") or 0),
                "summaryLines": summary_lines,
                "priceText": "",
                "legs": legs,
            }
        )
    return {
        "from": origin,
        "to": destination,
        "journeys": journeys,
        "nextPageCursor": str(data.get("nextPageCursor") or "") if isinstance(data, dict) else "",
        "previousPageCursor": str(data.get("previousPageCursor") or "") if isinstance(data, dict) else "",
    }


def main() -> None:
    try:
        if len(sys.argv) < 3:
            raise TransportError("Verwendung: transport_fetch.py <api-basis> <aktion> [argumente...]")

        base_url = sys.argv[1]
        action = sys.argv[2].strip().lower()
        args = sys.argv[3:]

        if action == "locations":
            payload = location_results(base_url, args[0] if args else "")
        elif action == "favorites":
            payload = favorites_results(base_url, args[0] if args else "")
        elif action == "departures":
            payload = departures_results(base_url, args[0] if args else "")
        elif action == "journeys":
            if len(args) < 2:
                raise TransportError("Die Verbindungssuche benoetigt Start und Ziel.")
            payload = journey_results(base_url, args[0], args[1], args[2] if len(args) > 2 else "")
        else:
            raise TransportError(f"Nicht unterstuetzte Aktion '{action}'.")

        print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
    except TransportError as exc:
        fail(str(exc))


if __name__ == "__main__":
    main()
