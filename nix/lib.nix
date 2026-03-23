{ lib }:

rec {
  trimFile = path: lib.removeSuffix "\n" (builtins.readFile path);

  pluginInstallRoot = "etc/xdg/quickshell/dms-plugins";

  cleanComponentSource = src:
    lib.cleanSourceWith {
      inherit src;
      filter = path: type:
        let
          base = builtins.baseNameOf path;
        in !lib.elem base [
          "__pycache__"
          ".gobuild"
          ".gomodcache"
          "PKGBUILD"
          "default.nix"
          "result"
          "mpdwatch"
          "clerk-api-rofi"
        ];
    };
}
