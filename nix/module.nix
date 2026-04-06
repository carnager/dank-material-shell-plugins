{ config, lib, pkgs, ... }:

let
  cfg = config.programs.dankMaterialShellPlugins;
  helper = import ./lib.nix { inherit lib; };
in {
  options.programs.dankMaterialShellPlugins = {
    enable = lib.mkEnableOption "system-installed Dank Material Shell plugins";

    packages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = "Plugin packages to expose through /etc/xdg/quickshell/dms-plugins.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.packages != [ ]) {
    environment.etc."xdg/quickshell/dms-plugins".source =
      "${pkgs.symlinkJoin {
        name = "dms-plugin-bundle";
        paths = cfg.packages;
      }}/${helper.pluginInstallRoot}";
  };
}
