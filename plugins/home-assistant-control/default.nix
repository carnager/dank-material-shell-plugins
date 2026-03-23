{ lib, callPackage, curl, python3 }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  buildPlugin = callPackage ../../nix/plugin.nix { };
  version = helper.trimFile ./VERSION;
  python = python3.withPackages (ps: [ ps.websockets ]);
in
buildPlugin {
  pname = "dms-plugin-home-assistant-control";
  inherit version;
  src = helper.cleanComponentSource ./.;
  installName = "home-assistant-control";
  substitutions = [
    {
      path = "HomeAssistantWidget.qml";
      from = ''["python3", fetchScriptPath, baseUrl, accessToken]'';
      to = ''["${lib.getExe python}", fetchScriptPath, baseUrl, accessToken]'';
    }
    {
      path = "HomeAssistantWidget.qml";
      from = ''["curl", "-sS", "--connect-timeout", "3", "--max-time", "6", "-k", "-X", "POST"'';
      to = ''["${lib.getExe curl}", "-sS", "--connect-timeout", "3", "--max-time", "6", "-k", "-X", "POST"'';
    }
  ];
}
