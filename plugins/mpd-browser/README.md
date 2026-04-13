# MPD Browser

Dedicated album browser widget for Dank Material Shell / DMS.

This plugin splits album browsing out of the main MPD widget into its own bar pill and popout. It is designed for fast queueing with keyboard navigation and rofi-style filtering.

## Features

- Separate album browser widget with its own popout
- `Albums` and `Latest` modes
- Tokenized search across album metadata
- Keyboard navigation with arrow keys, `PageUp`, `PageDown`, `Home`, and `End`
- `Tab` / `Shift+Tab` switches between `Albums` and `Latest`
- `Add`, `Insert`, and `Replace` actions on the selected album
- Optional external album upload action
- Random album / random tracks menu
- Left click opens regular album mode
- Right click opens latest mode

## Settings

The plugin id is `mpdBrowser`.

- `sharedPluginId`: plugin id to read shared MPD settings from, defaults to `mpd`
- `defaultMode`: mode used when the widget is opened through generic widget IPC, either `album` or `latest`
- `uploadEnabled`: enable the optional upload action, defaults to `false`
- `uploadBinaryPath`: path or command name for the upload client; only used when uploads are enabled

By default, this plugin reads MPD and clerk connection settings from the main `mpd` plugin.

If upload is enabled and a binary path is configured, the browser shows an `Upload` action for albums. The configured binary is called directly and must accept:

```sh
<binary> --artist "<album artist>" --album "<album name>" --date "<release date>"
```

## Usage

Add the widget to a bar section in DMS first. A loaded plugin is not enough for DMS widget IPC; it must actually be mounted as a bar widget.

Build the shared watcher binary first:

```sh
cd /home/carnager/Code/dank-material-shell-plugins/tools/mpdwatch
go build -o mpdwatch .
```

Then either put `mpdwatch` in your `PATH` or set `Watcher Binary` in the main `mpd` plugin settings to the absolute binary path.

Useful commands:

```sh
dms ipc call widget list
dms ipc call widget toggle mpdBrowser
dms ipc call widget reveal mpdBrowser
dms ipc call widget hide mpdBrowser
```

## Limitations

- Generic DMS widget IPC can open or close the widget, but it cannot directly choose `Albums` vs `Latest`.
- `defaultMode` controls which tab opens when the widget is triggered through generic widget IPC.
- If you want separate shell commands such as `openAlbum` and `openLatest`, that requires a shell-level DMS IPC bridge in `DMSShellIPC.qml`.

## Relationship To `mpd`

- [`../mpd`](../mpd) remains the main track widget.
- `mpdBrowser` reuses the same MPD / clerk settings by default through `sharedPluginId: "mpd"`.
- Both plugins rely on the same watcher backend from [`../../tools/mpdwatch`](../../tools/mpdwatch).
