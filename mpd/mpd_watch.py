#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time

from mpd import CommandError
from mpd import ConnectionError
from mpd import MPDClient


def emit(payload):
    sys.stdout.write(json.dumps(payload, ensure_ascii=True) + "\n")
    sys.stdout.flush()


def extract_year(value):
    match = re.search(r"(\d{4})", value or "")
    return match.group(1) if match else ""


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


def normalize_track(song):
    song = song or {}
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
    }


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


def build_album_info(client, song):
    song = song or {}
    album = song.get("album", "") or ""
    if not album:
        return {
            "title": "",
            "albumartist": "",
            "year": "",
            "track_count": 0,
            "tracks": [],
        }

    matches = client.find("album", album)
    albumartist = song.get("albumartist", "") or ""
    date = song.get("date", "") or ""
    year = extract_year(date)

    if albumartist:
        filtered = [item for item in matches if (item.get("albumartist", "") or "") == albumartist]
        if filtered:
            matches = filtered

    sorted_matches = sorted(matches, key=track_sort_key)
    tracks = []
    files = []
    current_file = song.get("file", "") or ""
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

    return {
        "title": album,
        "albumartist": albumartist,
        "year": year,
        "track_count": len(tracks),
        "tracks": tracks,
        "files": files,
        "current_index": current_index,
    }


def build_queue_info(client, status):
    current_pos = int(status.get("song", "-1") or -1)
    queue = []
    for item in client.playlistinfo():
        track = normalize_track(item)
        try:
            pos = int(item.get("pos", "-1") or -1)
        except ValueError:
            pos = -1
        queue.append({
            "pos": pos,
            "tracknumber": track["tracknumber"],
            "artist": track["artist"],
            "title": track["title"] or track["filename"],
            "album": track["album"],
            "current": pos == current_pos,
        })
    return {
        "current_pos": current_pos,
        "tracks": queue,
    }


def read_art_blob(client, file_path):
    if not file_path:
        return None

    for command_name in ("albumart", "readpicture"):
        try:
            response = getattr(client, command_name)(file_path)
        except (CommandError, ConnectionError, OSError):
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


def snapshot(client, art_path):
    status = client.status()
    song = client.currentsong()
    return {
        "type": "snapshot",
        "connected": True,
        "state": status.get("state", "stop"),
        "track": normalize_track(song),
        "album_info": build_album_info(client, song),
        "queue_info": build_queue_info(client, status),
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


def perform_action(host, port, password, action, arg):
    client = build_client()
    try:
        client.connect(host, port)
        if password:
            client.password(password)

        song = client.currentsong()
        album_info = build_album_info(client, song)

        if action == "toggle":
            status = client.status()
            state = status.get("state", "stop")
            if state == "play":
                client.pause(1)
            else:
                client.pause(0)
        elif action == "next":
            client.next()
        elif action == "previous":
            client.previous()
        elif action == "play_pos" and arg:
            client.play(int(arg))
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
    parser.add_argument("--action", choices=("toggle", "next", "previous", "play_pos", "add_album", "insert_album", "replace_album"), default="")
    parser.add_argument("--arg", default="")
    args = parser.parse_args()

    host, password = resolve_host_and_password(args.host, args.password)
    if args.action:
        perform_action(host, args.port, password, args.action, args.arg)
        return

    while True:
        client = build_client()
        try:
            client.connect(host, args.port)
            if password:
                client.password(password)

            song = client.currentsong()
            art_path = cache_album_art(client, song)
            emit(snapshot(client, art_path))

            while True:
                changes = client.idle("player", "playlist", "options")
                song = client.currentsong()
                if not changes or "player" in changes or "playlist" in changes:
                    art_path = cache_album_art(client, song)
                emit(snapshot(client, art_path))
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
                    "track_count": 0,
                    "tracks": [],
                    "files": [],
                    "current_index": -1,
                },
                "queue_info": {
                    "current_pos": -1,
                    "tracks": [],
                },
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
