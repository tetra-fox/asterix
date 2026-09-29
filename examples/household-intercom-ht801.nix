# Provisioning for the HT801 adapters of the household intercom (see README.md)
{
  config,
  lib,
  ...
}: {
  # the files embed these passwords: render them again when one changes
  sops.secrets = lib.genAttrs ["ht801-admin" "sip-101" "sip-102"] (_: {
    restartUnits = ["asterisk-provisioning.service"];
  });

  pbx.phones = {
    listenAddress = "10.0.20.10";
    allowedNetworks = ["10.0.20.0/24"];
    openFirewall = true;
    firewallInterfaces = ["voip"];

    grandstream.ht801 = {
      enable = true;
      timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
      adminPassword = config.lib.asterisk.secret config.sops.secrets.ht801-admin.path;

      devices = {
        "101".mac = "c0:74:ad:00:01:01";
        "102".mac = "c0:74:ad:00:01:02";
      };
    };
  };
}
