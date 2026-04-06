{ config, lib, pkgs, ... }:

let
  cfg = config.programs.dankMaterialShellPlugins;
  helper = import ./lib.nix { inherit lib; };
  bundle = pkgs.symlinkJoin {
    name = "dms-plugin-bundle";
    paths = cfg.packages;
  };
  runtimePackages = lib.concatMap (pkg: pkg.passthru.dmsRuntimePackages or [ ]) cfg.packages;
in {
  options.programs.dankMaterialShellPlugins = {
    enable = lib.mkEnableOption "user-installed Dank Material Shell plugins";

    packages = lib.mkOption {
      type = with lib.types; listOf package;
      default = [ ];
      description = "Plugin packages to expose through ~/.config/DankMaterialShell/plugins.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.packages != [ ]) {
    home.file.".config/DankMaterialShell/plugins" = {
      source = "${bundle}/${helper.pluginInstallRoot}";
      recursive = true;
    };
    home.packages = runtimePackages;
  };
}
