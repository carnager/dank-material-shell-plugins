# Dank Material Shell Plugins

Monorepo for standalone Dank Material Shell / DMS plugins plus helper tools.

## Layout

- `plugins/mpd`: main MPD track widget
- `plugins/mpd-browser`: dedicated MPD album browser widget
- `plugins/systemd-user-services`: start/stop control for configured `systemd --user` services
- `plugins/home-assistant-control`: Home Assistant widget
- `plugins/public-transport`: public transport departures and journey lookup widget
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
- `dms-plugin-systemd-user-services`
- `dms-plugin-home-assistant-control`
- `dms-plugin-public-transport`
- `default` / `all`

The MPD plugin package patches its default watcher path to the packaged `mpdwatch` binary on Nix, while still keeping the runtime setting as an override.

The flake also exposes:

- a NixOS module at `nixosModules.default` that links packaged plugins into `/etc/xdg/quickshell/dms-plugins`
- a Home Manager module at `homeManagerModules.default` and `homeManagerModules.dankMaterialShellPlugins` that links packaged plugins into `~/.config/DankMaterialShell/plugins`

Both modules also install runtime helper packages required by the selected plugin packages, such as `mpdwatch` for the MPD plugins.

Example Home Manager usage:

```nix
let
  pluginPkgs = inputs.dmsPlugins.packages.${pkgs.stdenv.hostPlatform.system};
in {
  programs.dankMaterialShellPlugins = {
    enable = true;
    packages = [
      pluginPkgs."dms-plugin-mpd"
      pluginPkgs."dms-plugin-public-transport"
    ];
  };
}
```

## Versioning

Each component now carries its own `VERSION` file so it can evolve independently even while staying in one repo.
