{ lib, callPackage, mpdwatch }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  buildPlugin = callPackage ../../nix/plugin.nix { };
  version = helper.trimFile ./VERSION;
  watcherPath = lib.getExe mpdwatch;
in
buildPlugin {
  pname = "dms-plugin-mpd";
  inherit version;
  src = helper.cleanComponentSource ./.;
  installName = "mpd";
  substitutions = [
    {
      path = "MpdRuntimeConfig.qml";
      from = ''property string watcherBinaryPath: "mpdwatch"'';
      to = ''property string watcherBinaryPath: "${watcherPath}"'';
    }
    {
      path = "MpdRuntimeConfig.qml";
      from = ''return text.length > 0 ? text : "mpdwatch";'';
      to = ''return text.length > 0 ? text : "${watcherPath}";'';
    }
    {
      path = "MpdRuntimeConfig.qml";
      from = ''savedSetting("watcherBinary", "mpdwatch")'';
      to = ''savedSetting("watcherBinary", "${watcherPath}")'';
    }
    {
      path = "MpdSettings.qml";
      from = ''placeholder: "mpdwatch"'';
      to = ''placeholder: "${watcherPath}"'';
    }
    {
      path = "MpdSettings.qml";
      from = ''defaultValue: "mpdwatch"'';
      to = ''defaultValue: "${watcherPath}"'';
    }
  ];
}
