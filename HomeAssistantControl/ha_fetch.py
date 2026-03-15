#!/usr/bin/env python3

import asyncio
import json
import ssl
import sys
import urllib.parse
import urllib.request

import websockets


def normalize_base_url(base_url: str) -> str:
    return base_url.rstrip("/")


def build_api_url(base_url: str, suffix: str) -> str:
    parsed = urllib.parse.urlsplit(normalize_base_url(base_url))
    path = parsed.path.rstrip("/")
    return urllib.parse.urlunsplit((parsed.scheme, parsed.netloc, path + suffix, "", ""))


def build_ssl_context(base_url: str):
    parsed = urllib.parse.urlsplit(base_url)
    if parsed.scheme not in {"https", "wss"}:
        return None
    return ssl._create_unverified_context()


def fetch_states(base_url: str, token: str):
    request = urllib.request.Request(
        build_api_url(base_url, "/api/states"),
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
        },
    )
    context = build_ssl_context(base_url)
    with urllib.request.urlopen(request, timeout=8, context=context) as response:
        return json.load(response)


async def ws_request(ws, request_id: int, request_type: str):
    await ws.send(json.dumps({"id": request_id, "type": request_type}))
    while True:
        message = json.loads(await ws.recv())
        if message.get("id") != request_id:
            continue
        if not message.get("success"):
            raise RuntimeError(f"{request_type} failed")
        return message.get("result", [])


async def fetch_registry(base_url: str, token: str):
    parsed = urllib.parse.urlsplit(normalize_base_url(base_url))
    ws_scheme = "wss" if parsed.scheme == "https" else "ws"
    ws_url = urllib.parse.urlunsplit((ws_scheme, parsed.netloc, parsed.path.rstrip("/") + "/api/websocket", "", ""))
    ssl_context = build_ssl_context(base_url)

    async with websockets.connect(ws_url, open_timeout=8, ssl=ssl_context, max_size=8 * 1024 * 1024) as ws:
        hello = json.loads(await ws.recv())
        if hello.get("type") != "auth_required":
            raise RuntimeError("unexpected websocket handshake")

        await ws.send(json.dumps({"type": "auth", "access_token": token}))
        auth = json.loads(await ws.recv())
        if auth.get("type") != "auth_ok":
            raise RuntimeError("websocket authentication failed")

        areas = await ws_request(ws, 1, "config/area_registry/list")
        devices = await ws_request(ws, 2, "config/device_registry/list")
        entities = await ws_request(ws, 3, "config/entity_registry/list")

        return {
            "areas": {
                area["area_id"]: area.get("name", "Unassigned")
                for area in areas
                if area.get("area_id")
            },
            "devices": {
                device["id"]: device.get("area_id", "")
                for device in devices
                if device.get("id")
            },
            "entities": {
                entity["entity_id"]: {
                    "area_id": entity.get("area_id", ""),
                    "device_id": entity.get("device_id", ""),
                }
                for entity in entities
                if entity.get("entity_id")
            },
        }


async def main():
    if len(sys.argv) != 3:
        print("Usage: ha_fetch.py <base-url> <access-token>", file=sys.stderr)
        return 1

    base_url = normalize_base_url(sys.argv[1])
    token = sys.argv[2]

    states = fetch_states(base_url, token)
    registry = await fetch_registry(base_url, token)
    print(json.dumps({"states": states, "registry": registry}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
