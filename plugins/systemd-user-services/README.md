# User Services

Generic control widget for `systemd --user` services.

## Features

- Lets you add services from a picker backed by `systemctl --user list-unit-files`
- Persists the chosen service list in plugin state
- Shows current active state for each configured service
- Toggles each service between `start` and `stop`
- Toggles each service between `enable` and `disable` when the unit supports it
- Removes services directly from the popout
- Uses a single generic service-manager icon in the bar

## Settings

- `systemctlBinary`: path or command name for `systemctl`

Configured services are managed in the widget popout through `Add`, `Start` / `Stop`, `Enable` / `Disable`, and remove buttons.

## Packaging

- Nix package: `dms-plugin-systemd-user-services`
- Arch package: `dms-plugin-systemd-user-services`
