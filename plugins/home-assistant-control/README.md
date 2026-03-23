# Home Assistant Control

Home Assistant bar widget for Dank Material Shell / DMS.

It adds a pill with a dedicated popup for controlling Home Assistant lights, switches, and matching groups from inside the shell.

## Features

- Fetches Home Assistant state data and registry metadata
- Shows lights, switches, and compatible groups
- Groups entries by room / area when registry data is available
- Search field for filtering devices by name and related group names
- One-click on / off toggling from the popup
- Handles both standalone entities and grouped entities
- Refresh action in the popup

## Settings

The plugin id is `homeAssistantControl`.

- `baseUrl`: Home Assistant base URL including protocol and port
- `accessToken`: Home Assistant long-lived access token

The widget still reads older saved values as a fallback:

- `gatewayIp` -> `baseUrl`
- `apiKey` -> `accessToken`

## Requirements

- A reachable Home Assistant instance
- A long-lived access token with access to the required entities
- Python 3 for `ha_fetch.py`
- `websockets` available for Python, because registry data is fetched through the Home Assistant WebSocket API
- `curl` available, because toggle actions are sent with `curl`

## Behavior

- Opening the popup triggers a refresh
- The popup focuses the filter field automatically
- Search is substring-based and rebuilds the room list live
- Only `light.*`, `switch.*`, and matching groups are shown
- If area or device registry data is available, entries are grouped by room

## Files

- `HomeAssistantWidget.qml`: widget and popup UI
- `HomeAssistantSettings.qml`: plugin settings UI
- `ha_fetch.py`: Home Assistant fetcher for states and registry data
- `home-assistant-control.sh`: legacy direct control helper
- `get_home_assistant_list.sh`: legacy list helper
