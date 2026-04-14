{
  description = "Dank Material Shell plugins and helper tools";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      homeManagerModule = import ./nix/home-manager-module.nix;
    in {
      nixosModules.default = import ./nix/module.nix;
      homeManagerModules.default = homeManagerModule;
      homeManagerModules.dankMaterialShellPlugins = homeManagerModule;

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          mpdwatch = pkgs.callPackage ./tools/mpdwatch/default.nix { };
          mpd = pkgs.callPackage ./plugins/mpd/default.nix { inherit mpdwatch; };
          mpdBrowser = pkgs.callPackage ./plugins/mpd-browser/default.nix { inherit mpdwatch; };
          systemdUserServices = pkgs.callPackage ./plugins/systemd-user-services/default.nix {
            systemd = pkgs.systemd;
          };
          homeAssistantControl = pkgs.callPackage ./plugins/home-assistant-control/default.nix { };
          publicTransport = pkgs.callPackage ./plugins/public-transport/default.nix { };
          pluginPackages = [
            mpd
            mpdBrowser
            systemdUserServices
            homeAssistantControl
            publicTransport
          ];
          allPackages = pkgs.symlinkJoin {
            name = "dank-material-shell-packages";
            paths = [
              mpdwatch
            ] ++ pluginPackages;
            passthru = {
              dmsRuntimePackages = pkgs.lib.concatMap (pkg: pkg.passthru.dmsRuntimePackages or [ ]) pluginPackages;
            };
          };
        in {
          inherit mpdwatch;
          "dms-plugin-mpd" = mpd;
          "dms-plugin-mpd-browser" = mpdBrowser;
          "dms-plugin-systemd-user-services" = systemdUserServices;
          "dms-plugin-home-assistant-control" = homeAssistantControl;
          "dms-plugin-public-transport" = publicTransport;
          all = allPackages;
          default = allPackages;
        });
    };
}
