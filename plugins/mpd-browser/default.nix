{ lib, callPackage, mpdwatch }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  buildPlugin = callPackage ../../nix/plugin.nix { };
  version = helper.trimFile ./VERSION;
in
buildPlugin {
  pname = "dms-plugin-mpd-browser";
  inherit version;
  src = helper.cleanComponentSource ./.;
  installName = "mpd-browser";
  passthru = {
    dmsRuntimePackages = [ mpdwatch ];
  };
}
