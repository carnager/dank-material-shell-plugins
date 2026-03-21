# MPD

Track-focused MPD widget for Dank Material Shell / DMS.

It shows the currently playing track in the bar and opens a track popup with playback controls, album and artist navigation, cover art, ratings, and clerk-powered random playback actions.

## Features

- Event-driven MPD watcher backed by the external `mpdwatch` Go binary
- Configurable bar text format
- Optional cover art in the bar
- Track popup with transport controls
- Album and artist drill-down inside the popup
- Track and album ratings
- Random album / random tracks actions through clerk

## Settings

The plugin id is `mpd`.

- `host`: MPD host name or IP address
- `port`: MPD TCP port
- `password`: optional MPD password
- `clerkApiBaseUrl`: optional clerk API base URL
- `watcherBinary`: path or command name for the `mpdwatch` binary
- `format`: bar text template
- `cover`: `true` or `false` for bar cover art
- `maxWidth`: maximum bar width in pixels, `0` disables the limit
- `alignment`: `left` or `right`

Supported `format` placeholders:

- `{tracknumber}`
- `{artist}`
- `{title}`
- `{album}`
- `{albumartist}`
- `{date}`
- `{year}`
- `{filename}`

## Clerk Integration

If `clerkApiBaseUrl` is empty, the watcher tries to read `~/.config/clerk/clerk-api-rofi.conf` and uses `general.api_base_url` from there.

Clerk is used for:

- album ratings
- random album / tracks actions

## Build

The widget now calls an external `mpdwatch` binary directly. Build it from the top-level `mpdwatch/` project:

```sh
cd /home/carnager/Code/dank-material-shell-plugins/mpdwatch
go build -o mpdwatch .
```

Then either:

- place `mpdwatch` somewhere in your `PATH`, or
- set `Watcher Binary` in the plugin settings to the absolute binary path

## Notes

- This widget is track-focused again. The dedicated album browser now lives in [`../mpd-browser`](../mpd-browser).
- The runtime dependency is now the external `mpdwatch` binary from [`../mpdwatch`](../mpdwatch).
