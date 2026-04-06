{ lib, stdenvNoCC }:

{
  pname,
  version,
  src,
  installName,
  substitutions ? [ ],
  passthru ? { },
}:

stdenvNoCC.mkDerivation {
  inherit pname version src;
  inherit passthru;

  dontConfigure = true;
  dontBuild = true;

  installPhase =
    let
      destination = "$out/etc/xdg/quickshell/dms-plugins/${installName}";
      substitutionScript = lib.concatMapStrings (sub:
        ''
          substituteInPlace "${destination}/${sub.path}" --replace-fail '${sub.from}' '${sub.to}'
        '') substitutions;
    in ''
      runHook preInstall

      mkdir -p "${destination}"
      cp -R . "${destination}/"
      chmod -R u+w "${destination}"
      find "${destination}" -name __pycache__ -type d -prune -exec rm -rf {} +

      ${substitutionScript}

      runHook postInstall
    '';
}
