{ lib, callPackage, systemd }:

let
  helper = import ../../nix/lib.nix { inherit lib; };
  buildPlugin = callPackage ../../nix/plugin.nix { };
  version = helper.trimFile ./VERSION;
  systemctlPath = lib.getExe' systemd "systemctl";
in
buildPlugin {
  pname = "dms-plugin-systemd-user-services";
  inherit version;
  src = helper.cleanComponentSource ./.;
  installName = "systemd-user-services";
  passthru = {
    dmsRuntimePackages = [ systemd ];
  };
  substitutions = [
    {
      path = "SystemdUserServicesWidget.qml";
      from = ''loadPluginValue("systemctlBinary", "systemctl")'';
      to = ''loadPluginValue("systemctlBinary", "${systemctlPath}")'';
    }
    {
      path = "SystemdUserServicesSettings.qml";
      from = ''placeholder: "systemctl"'';
      to = ''placeholder: "${systemctlPath}"'';
    }
    {
      path = "SystemdUserServicesSettings.qml";
      from = ''defaultValue: "systemctl"'';
      to = ''defaultValue: "${systemctlPath}"'';
    }
  ];
}
