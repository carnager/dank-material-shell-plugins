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
    in {
      nixosModules.default = import ./nix/module.nix;

      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          mpdwatch = pkgs.callPackage ./tools/mpdwatch/default.nix { };
          mpd = pkgs.callPackage ./plugins/mpd/default.nix { inherit mpdwatch; };
          mpdBrowser = pkgs.callPackage ./plugins/mpd-browser/default.nix { };
          homeAssistantControl = pkgs.callPackage ./plugins/home-assistant-control/default.nix { };
          publicTransport = pkgs.callPackage ./plugins/public-transport/default.nix { };
          allPackages = pkgs.symlinkJoin {
            name = "dank-material-shell-packages";
            paths = [
              mpdwatch
              mpd
              mpdBrowser
              homeAssistantControl
              publicTransport
            ];
          };
        in {
          inherit mpdwatch;
          "dms-plugin-mpd" = mpd;
          "dms-plugin-mpd-browser" = mpdBrowser;
          "dms-plugin-home-assistant-control" = homeAssistantControl;
          "dms-plugin-public-transport" = publicTransport;
          all = allPackages;
          default = allPackages;
        });
    };
}
