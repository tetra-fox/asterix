# Add-on for household-intercom.nix: provisions the two HT801 adapters from
# this host. Import it next to the intercom example together with the `ht801`
# module:
#
#   imports = [
#     asterix.nixosModules.default
#     asterix.nixosModules.ht801
#     ./household-intercom.nix
#     ./household-intercom-ht801.nix
#   ];
#
# Point each adapter at http://10.0.20.10 once, with DHCP option 66 or its web
# interface.
{
  config,
  lib,
  ...
}: {
  # the files embed these passwords: render them again when one changes
  sops.secrets = lib.genAttrs ["ht801-admin" "sip-101" "sip-102"] (_: {
    restartUnits = ["ht801-provisioning.service"];
  });

  services.asterisk.provisioning.ht801 = {
    enable = true;
    listenAddress = "10.0.20.10";
    allowedNetworks = ["10.0.20.0/24"];
    openFirewall = true;
    firewallInterfaces = ["voip"];

    timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
    adminPassword = config.lib.asterisk.secret config.sops.secrets.ht801-admin.path;

    devices = {
      "101".mac = "c0:74:ad:00:01:01";
      "102".mac = "c0:74:ad:00:01:02";
    };
  };
}
