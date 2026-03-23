# Dank Material Shell Plugins

Monorepo for standalone Dank Material Shell / DMS plugins plus helper tools.

## Layout

- `plugins/mpd`: main MPD track widget
- `plugins/mpd-browser`: dedicated MPD album browser widget
- `plugins/home-assistant-control`: Home Assistant widget
- `tools/mpdwatch`: standalone MPD watcher/helper binary used by the MPD plugins
- `nix`: shared Nix packaging helpers

## Packaging

This repo now supports two packaging styles:

- Nix: root `flake.nix` plus per-component `default.nix`
- Arch-style local packaging: per-component `PKGBUILD`

DMS discovers plugins from:

- `~/.config/DankMaterialShell/plugins/`
- `/etc/xdg/quickshell/dms-plugins`

Available Nix packages:

- `mpdwatch`
- `dms-plugin-mpd`
- `dms-plugin-mpd-browser`
- `dms-plugin-home-assistant-control`
- `default` / `all`

The MPD plugin package patches its default watcher path to the packaged `mpdwatch` binary on Nix, while still keeping the runtime setting as an override.

The flake also exposes a small NixOS module that links packaged plugins into `/etc/xdg/quickshell/dms-plugins`, which is the system-level directory DMS already watches.

## Versioning

Each component now carries its own `VERSION` file so it can evolve independently even while staying in one repo.
