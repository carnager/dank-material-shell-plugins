{ lib, buildGoModule }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  version = helper.trimFile ./VERSION;
in
buildGoModule {
  pname = "mpdwatch";
  inherit version;
  src = helper.cleanComponentSource ./.;
  vendorHash = null;

  postInstall = ''
    install -Dm644 README.md "$out/share/doc/mpdwatch/README.md"
  '';
}
