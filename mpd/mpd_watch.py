#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time
import tomllib
import urllib.error
import urllib.request

from mpd import CommandError
from mpd import ConnectionError
from mpd import MPDClient


CLERK_CACHE_TTL_SECONDS = 60
_clerk_album_cache = {}
_clerk_album_cache_expires_at = 0.0


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def extract_year(value):
    match = re.search(r"(\d{4})", value or "")
    return match.group(1) if match else ""


def normalize_rating_value(value):
    text = str(value or "").strip()
    if not text:
        return ""

    try:
        if "/" in text:
            number_text, scale_text = text.split("/", 1)
            number = float(number_text.strip())
            scale = float(scale_text.strip())
            if scale > 0:
                value = number * 5.0 / scale
            else:
                value = number
        else:
            value = float(text)
    except ValueError:
        return ""

    if value > 10:
        value = value / 20.0
    elif value > 5:
        value = value / 2.0

    value = max(0.0, min(5.0, value))
    rounded = round(value * 2.0) / 2.0
    text = f"{rounded:.1f}".rstrip("0").rstrip(".")
    return text


def normalize_clerk_base_url(value):
    return str(value or "").strip().rstrip("/")


def resolve_clerk_api_base_url(base_url_arg):
    normalized = normalize_clerk_base_url(base_url_arg)
    if normalized:
        return normalized

    xdg_config_home = os.environ.get("XDG_CONFIG_HOME", os.path.join(os.path.expanduser("~"), ".config"))
    config_path = os.path.join(xdg_config_home, "clerk", "clerk-api-rofi.conf")
    try:
        with open(config_path, "rb") as handle:
            config = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError):
        return ""

    return normalize_clerk_base_url(config.get("general", {}).get("api_base_url", ""))


def clerk_request(base_url, endpoint, method="GET", payload=None):
    normalized_base_url = normalize_clerk_base_url(base_url)
    if not normalized_base_url:
        return None

    url = normalized_base_url + "/" + str(endpoint or "").lstrip("/")
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"

    request = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            body = response.read()
    except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError):
        return None

    if not body:
        return None

    try:
        return json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None


def clerk_album_cache_key(albumartist, album, date):
    if not album:
        return ""
    return "\x1f".join((str(albumartist or ""), str(album or ""), str(date or "")))


def fetch_clerk_album_cache(base_url, force=False):
    global _clerk_album_cache
    global _clerk_album_cache_expires_at

    normalized_base_url = normalize_clerk_base_url(base_url)
    if not normalized_base_url:
        return {}

    now = time.time()
    if not force and now < _clerk_album_cache_expires_at:
        return _clerk_album_cache

    response = clerk_request(normalized_base_url, "albums")
    if not isinstance(response, list):
        if now < _clerk_album_cache_expires_at and _clerk_album_cache:
            return _clerk_album_cache
        return {}

    cache = {}
    for album in response:
        key = clerk_album_cache_key(
            album.get("albumartist", ""),
            album.get("album", ""),
            album.get("date", ""),
        )
        if not key:
            continue
        cache[key] = {
            "id": str(album.get("id", "")),
            "rating": normalize_rating_value(album.get("rating", "")),
        }

    _clerk_album_cache = cache
    _clerk_album_cache_expires_at = now + CLERK_CACHE_TTL_SECONDS
    return cache


def normalize_clerk_album_entry(album):
    album = album or {}
    date = str(album.get("date", "") or "")
    return {
        "id": str(album.get("id", "") or ""),
        "album": str(album.get("album", "") or ""),
        "albumartist": str(album.get("albumartist", "") or ""),
        "date": date,
        "year": extract_year(date),
        "rating": normalize_rating_value(album.get("rating", "")),
    }


def fetch_clerk_album_list(base_url, mode="album"):
    normalized_base_url = normalize_clerk_base_url(base_url)
    if not normalized_base_url:
        return None

    endpoint = "latest_albums" if mode == "latest" else "albums"
    response = clerk_request(normalized_base_url, endpoint)
    if not isinstance(response, list):
        return []

    albums = []
    for album in response:
        entry = normalize_clerk_album_entry(album)
        if entry.get("id") and entry.get("album"):
            albums.append(entry)
    return albums


def read_sticker(client, file_path, name):
    if not file_path:
        return ""

    try:
        return str(client.sticker_get("song", file_path, name) or "")
    except (CommandError, ConnectionError, OSError):
        return ""


def read_first_album_sticker(client, songs, name):
    for song in songs or []:
        value = read_sticker(client, (song or {}).get("file", "") or "", name)
        if value:
            return value
    return ""


def detect_image_extension(blob):
    if blob.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if blob.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if blob.startswith((b"GIF87a", b"GIF89a")):
        return ".gif"
    if blob.startswith(b"RIFF") and blob[8:12] == b"WEBP":
        return ".webp"
    return ".img"


def normalize_track(song, stickers=None):
    song = song or {}
    stickers = stickers or {}
    file_path = song.get("file", "") or ""
    file_name = os.path.basename(file_path) if file_path else ""
    track = (song.get("track", "") or "").split("/", 1)[0]
    date = song.get("date", "") or ""
    return {
        "tracknumber": track,
        "artist": song.get("artist", "") or song.get("name", "") or "",
        "title": song.get("title", "") or "",
        "album": song.get("album", "") or "",
        "albumartist": song.get("albumartist", "") or "",
        "date": date,
        "year": extract_year(date),
        "filename": file_name or file_path,
        "rating": normalize_rating_value(stickers.get("rating", song.get("rating", ""))),
        "albumrating": normalize_rating_value(stickers.get("albumrating", song.get("albumrating", ""))),
    }


def album_key(song):
    song = song or {}
    album = song.get("album", "") or ""
    albumartist = song.get("albumartist", "") or song.get("artist", "") or song.get("name", "") or ""
    if not album:
        return ""
    return albumartist + "\x1f" + album


def split_album_key(value):
    parts = (value or "").split("\x1f", 1)
    if len(parts) != 2:
        return "", ""
    return parts[0], parts[1]


def track_sort_key(song):
    disc = (song.get("disc", "") or "0").split("/", 1)[0]
    track = (song.get("track", "") or "0").split("/", 1)[0]
    try:
        disc_num = int(disc)
    except ValueError:
        disc_num = 0
    try:
        track_num = int(track)
    except ValueError:
        track_num = 0
    return (disc_num, track_num, song.get("title", "") or song.get("file", "") or "")


def build_album_info_for_values(client, albumartist, album, date="", current_file="", clerk_album_cache=None):
    if not album:
        return {
            "title": "",
            "albumartist": "",
            "year": "",
            "albumrating": "",
            "clerk_id": "",
            "art_path": "",
            "track_count": 0,
            "tracks": [],
        }

    matches = client.find("album", album)

    if albumartist:
        filtered = [item for item in matches if (item.get("albumartist", "") or "") == albumartist]
        if filtered:
            matches = filtered

    if date:
        filtered = [item for item in matches if (item.get("date", "") or "") == date]
        if filtered:
            matches = filtered

    sorted_matches = sorted(matches, key=track_sort_key)
    date = sorted_matches[0].get("date", "") if sorted_matches else ""
    year = extract_year(date)
    clerk_entry = (clerk_album_cache or {}).get(clerk_album_cache_key(albumartist, album, date), {})
    albumrating = str(clerk_entry.get("rating", "") or "")
    tracks = []
    files = []
    current_index = -1
    for index, item in enumerate(sorted_matches):
        track = normalize_track(item)
        item_file = item.get("file", "") or ""
        files.append(item_file)
        if item_file and item_file == current_file:
            current_index = index
        tracks.append({
            "tracknumber": track["tracknumber"],
            "title": track["title"] or track["filename"],
        })
    art_song = sorted_matches[current_index] if current_index >= 0 and current_index < len(sorted_matches) else (sorted_matches[0] if sorted_matches else {})
    art_path = cache_album_art(client, art_song)

    return {
        "title": album,
        "albumartist": albumartist,
        "year": year,
        "albumrating": albumrating,
        "clerk_id": str(clerk_entry.get("id", "") or ""),
        "art_path": art_path,
        "track_count": len(tracks),
        "tracks": tracks,
        "files": files,
        "current_index": current_index,
    }


def build_album_info(client, song, clerk_album_cache=None):
    song = song or {}
    album = song.get("album", "") or ""
    albumartist = song.get("albumartist", "") or ""
    date = song.get("date", "") or ""
    current_file = song.get("file", "") or ""
    return build_album_info_for_values(client, albumartist, album, date, current_file, clerk_album_cache)


def build_queue_snapshot(client, status, clerk_album_cache=None):
    current_pos = int(status.get("song", "-1") or -1)
    queue = []
    album_details = {}
    for item in client.playlistinfo():
        track = normalize_track(item)
        key = album_key(item)
        try:
            pos = int(item.get("pos", "-1") or -1)
        except ValueError:
            pos = -1
        if key and key not in album_details:
            album_details[key] = build_album_info(client, item, clerk_album_cache)
        queue.append({
            "pos": pos,
            "tracknumber": track["tracknumber"],
            "artist": track["artist"],
            "albumartist": track["albumartist"],
            "title": track["title"] or track["filename"],
            "album": track["album"],
            "album_key": key,
            "current": pos == current_pos,
        })
    return {
        "current_pos": current_pos,
        "tracks": queue,
    }, album_details


def build_artist_album_map(client, artist_names, current_song=None, clerk_album_cache=None):
    artist_albums = {}
    album_details = {}
    current_song = current_song or {}
    current_song_key = album_key(current_song)
    current_song_date = current_song.get("date", "") or ""
    current_song_file = current_song.get("file", "") or ""

    for artist_name in sorted({str(name or "") for name in artist_names if str(name or "").strip()}):
        matches = client.find("albumartist", artist_name)
        if not matches:
            matches = client.find("artist", artist_name)

        albums_for_artist = []
        seen_album_keys = set()
        for item in matches:
            key = album_key(item)
            if not key or key in seen_album_keys:
                continue
            seen_album_keys.add(key)

            item_current_file = ""
            if key == current_song_key and (item.get("date", "") or "") == current_song_date:
                item_current_file = current_song_file
            info = build_album_info_for_values(
                client,
                item.get("albumartist", "") or item.get("artist", "") or item.get("name", "") or "",
                item.get("album", "") or "",
                item.get("date", "") or "",
                item_current_file,
                clerk_album_cache,
            )
            album_details[key] = info
            albums_for_artist.append({
                "album_key": key,
                "title": info.get("title", ""),
                "year": info.get("year", ""),
                "albumrating": info.get("albumrating", ""),
                "track_count": info.get("track_count", 0),
            })

        albums_for_artist.sort(key=lambda item: ((item.get("year", "") or ""), (item.get("title", "") or "")), reverse=True)
        artist_albums[artist_name] = albums_for_artist

    return artist_albums, album_details


def read_art_blob(client, file_path):
    if not file_path:
        return None

    for command_name in ("albumart", "readpicture"):
        try:
            response = getattr(client, command_name)(file_path)
        except (CommandError, ConnectionError, OSError):
            continue

        if not isinstance(response, dict):
            continue

        binary = response.get("binary", b"") or b""
        if binary:
            return bytes(binary)

    return None


def cache_album_art(client, song):
    file_path = (song or {}).get("file", "") or ""
    if not file_path:
        return ""

    blob = read_art_blob(client, file_path)
    if not blob:
        return ""

    digest = hashlib.sha1(file_path.encode("utf-8", errors="ignore") + b"\0" + blob[:256]).hexdigest()
    extension = detect_image_extension(blob)
    art_dir = os.path.join(tempfile.gettempdir(), "dank-plugin-hass-mpd")
    os.makedirs(art_dir, exist_ok=True)
    art_path = os.path.join(art_dir, f"{digest}{extension}")
    if not os.path.exists(art_path):
        with open(art_path, "wb") as handle:
            handle.write(blob)
    return art_path


def snapshot(client, art_path, clerk_base_url=""):
    status = client.status()
    song = client.currentsong()
    song_stickers = {
        "rating": read_sticker(client, song.get("file", "") or "", "rating"),
        "albumrating": read_sticker(client, song.get("file", "") or "", "albumrating"),
    }
    clerk_album_cache = fetch_clerk_album_cache(clerk_base_url)
    queue_info, album_details = build_queue_snapshot(client, status, clerk_album_cache)
    artist_names = set()
    for artist_name in (
        song.get("artist", "") or "",
        song.get("albumartist", "") or "",
        song.get("name", "") or "",
    ):
        if artist_name:
            artist_names.add(artist_name)
    for item in queue_info.get("tracks", []):
        for artist_name in (
            item.get("artist", "") or "",
            item.get("albumartist", "") or "",
        ):
            if artist_name:
                artist_names.add(artist_name)
    artist_albums, artist_album_details = build_artist_album_map(client, artist_names, song, clerk_album_cache)
    album_details.update(artist_album_details)
    return {
        "type": "snapshot",
        "connected": True,
        "state": status.get("state", "stop"),
        "track": normalize_track(song, song_stickers),
        "album_info": build_album_info(client, song, clerk_album_cache),
        "queue_info": queue_info,
        "artist_albums": artist_albums,
        "album_details": album_details,
        "art_path": art_path,
        "error": "",
    }


def resolve_host_and_password(host_arg, password_arg):
    host = host_arg or os.environ.get("MPD_HOST", "localhost")
    password = password_arg or ""
    if "@" in host and not password:
        possible_password, possible_host = host.split("@", 1)
        if possible_password and possible_host:
            password = possible_password
            host = possible_host
    return host, password


def build_client():
    client = MPDClient()
    client.timeout = 10
    client.idletimeout = None
    return client


def is_valid_rating_value(value):
    return str(value or "") in [str(i) for i in range(1, 11)] + ["Delete", "---"]


def perform_action(host, port, password, action, arg, clerk_base_url=""):
    if action == "dump_albums":
        mode = "latest" if str(arg or "").strip().lower() == "latest" else "album"
        albums = fetch_clerk_album_list(clerk_base_url, mode)
        emit({
            "type": "album_browser",
            "mode": mode,
            "albums": albums or [],
            "error": "" if albums is not None else "Clerk API unavailable.",
        })
        return
    if action == "queue_clerk_album" and arg:
        parts = str(arg).split(":", 2)
        if len(parts) < 2:
            return
        queue_mode = str(parts[0] or "").strip().lower()
        album_id = str(parts[1] or "").strip()
        list_mode = str(parts[2] or "album").strip().lower() if len(parts) > 2 else "album"
        if queue_mode not in ("add", "insert", "replace") or not album_id:
            return
        clerk_request(
            clerk_base_url,
            f"playlist/add/album/{album_id}",
            method="POST",
            payload={
                "mode": queue_mode,
                "list_mode": "latest" if list_mode == "latest" else "album",
            },
        )
        return
    if action == "random_album":
        clerk_request(clerk_base_url, "playback/random/album", method="POST", payload={})
        return
    if action == "random_tracks":
        clerk_request(clerk_base_url, "playback/random/tracks", method="POST", payload={})
        return
    if action == "set_album_rating" and arg:
        try:
            album_id, rating_value = str(arg).split(":", 1)
        except ValueError:
            return
        if album_id and is_valid_rating_value(rating_value):
            clerk_request(clerk_base_url, f"albums/{album_id}/rating", method="POST", payload={"rating": rating_value})
        return

    client = build_client()
    try:
        client.connect(host, port)
        if password:
            client.password(password)

        song = client.currentsong()
        if action in ("add_album", "insert_album", "replace_album") and arg:
            arg_albumartist, arg_album = split_album_key(arg)
            album_info = build_album_info_for_values(client, arg_albumartist, arg_album, "", "", None)
        else:
            album_info = build_album_info(client, song, None)

        if action == "toggle":
            status = client.status()
            state = status.get("state", "stop")
            if state == "play":
                client.pause(1)
            elif state == "pause":
                client.pause(0)
            else:
                client.play()
        elif action == "stop":
            client.stop()
        elif action == "next":
            client.next()
        elif action == "previous":
            client.previous()
        elif action == "play_pos" and arg:
            client.play(int(arg))
        elif action == "set_track_rating" and is_valid_rating_value(arg):
            track_file = song.get("file", "") or ""
            if track_file:
                if arg == "Delete":
                    client.sticker_delete("song", track_file, "rating")
                elif arg != "---":
                    client.sticker_set("song", track_file, "rating", str(arg))
        elif action == "add_album":
            for file_path in album_info.get("files", []):
                if file_path:
                    client.add(file_path)
        elif action == "insert_album":
            status = client.status()
            try:
                insert_pos = int(status.get("song", "-1") or -1) + 1
            except ValueError:
                insert_pos = len(client.playlistinfo())
            for offset, file_path in enumerate(album_info.get("files", [])):
                if file_path:
                    client.addid(file_path, insert_pos + offset)
        elif action == "replace_album":
            files = [file_path for file_path in album_info.get("files", []) if file_path]
            current_index = album_info.get("current_index", -1)
            client.clear()
            for file_path in files:
                client.add(file_path)
            if files:
                client.play(current_index if current_index >= 0 else 0)
    finally:
        try:
            client.close()
        except (ConnectionError, OSError, CommandError):
            pass
        try:
            client.disconnect()
        except (ConnectionError, OSError, CommandError):
            pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="")
    parser.add_argument("--port", type=int, default=int(os.environ.get("MPD_PORT", "6600")))
    parser.add_argument("--password", default="")
    parser.add_argument("--clerk-api-base-url", default="")
    parser.add_argument("--action", choices=("toggle", "stop", "next", "previous", "play_pos", "add_album", "insert_album", "replace_album", "queue_clerk_album", "dump_albums", "random_album", "random_tracks", "set_track_rating", "set_album_rating"), default="")
    parser.add_argument("--arg", default="")
    args = parser.parse_args()

    host, password = resolve_host_and_password(args.host, args.password)
    clerk_api_base_url = resolve_clerk_api_base_url(args.clerk_api_base_url)
    if args.action:
        perform_action(host, args.port, password, args.action, args.arg, clerk_api_base_url)
        return

    while True:
        client = build_client()
        try:
            client.connect(host, args.port)
            if password:
                client.password(password)

            song = client.currentsong()
            art_path = cache_album_art(client, song)
            emit(snapshot(client, art_path, clerk_api_base_url))

            while True:
                changes = client.idle("player", "playlist", "options")
                song = client.currentsong()
                if not changes or "player" in changes or "playlist" in changes:
                    art_path = cache_album_art(client, song)
                emit(snapshot(client, art_path, clerk_api_base_url))
        except (ConnectionError, CommandError, OSError) as exc:
            emit({
                "type": "snapshot",
                "connected": False,
                "state": "disconnected",
                "track": normalize_track({}),
                "album_info": {
                    "title": "",
                    "albumartist": "",
                    "year": "",
                    "albumrating": "",
                    "clerk_id": "",
                    "art_path": "",
                    "track_count": 0,
                    "tracks": [],
                    "files": [],
                    "current_index": -1,
                },
                "queue_info": {
                    "current_pos": -1,
                    "tracks": [],
                },
                "artist_albums": {},
                "album_details": {},
                "art_path": "",
                "error": str(exc),
            })
            time.sleep(2)
        finally:
            try:
                client.close()
            except (ConnectionError, OSError, CommandError):
                pass
            try:
                client.disconnect()
            except (ConnectionError, OSError, CommandError):
                pass


if __name__ == "__main__":
    main()
