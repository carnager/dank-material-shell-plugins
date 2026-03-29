{ lib, callPackage, python3 }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  buildPlugin = callPackage ../../nix/plugin.nix { };
  version = helper.trimFile ./VERSION;
in
buildPlugin {
  pname = "dms-plugin-public-transport";
  inherit version;
  src = helper.cleanComponentSource ./.;
  installName = "public-transport";
  substitutions = [
    {
      path = "PublicTransportWidget.qml";
      from = ''["python3", fetchScriptPath, apiBaseUrl].concat(args)'';
      to = ''["${lib.getExe python3}", fetchScriptPath, apiBaseUrl].concat(args)'';
    }
  ];
}
