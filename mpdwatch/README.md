# mpdwatch

Standalone MPD watcher and control helper used by the DMS MPD plugins.

It provides:

- snapshot streaming for the main MPD widget
- album browser dumps for the MPD Browser widget
- MPD control actions
- clerk integration for album lists, random playback, and album ratings

## Build

```sh
cd /home/carnager/Code/dank-material-shell-plugins/mpdwatch
go build -o mpdwatch .
```

Install the resulting binary somewhere in your `PATH`, or point the `Watcher Binary` setting in the `mpd` plugin to its absolute path.
