# Add-on for household-intercom.nix: provisions the three Grandstream desk
# phones from this host. Import it next to the intercom example together with
# the `grandstream-provisioning` module:
#
#   imports = [
#     asterix.nixosModules.default
#     asterix.nixosModules.grandstream-provisioning
#     ./household-intercom.nix
#     ./household-intercom-provisioning.nix
#   ];
#
# Point the phones at http://10.0.20.10 once (DHCP option 66 or their web
# interface).
{config, ...}: {
  # the phones' files are rendered again when the password changes
  sops.secrets.phone-admin.restartUnits = ["grandstream-provisioning.service"];

  services.asterisk.provisioning.grandstream = {
    enable = true;
    listenAddress = "10.0.20.10";
    allowedNetworks = ["10.0.20.0/24"];
    openFirewall = true;
    firewallInterfaces = ["voip"];

    # the VoIP VLAN has no internet access: serve NTP from this host
    ntp.serve = true;
    timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
    adminPassword = config.lib.asterisk.secret config.sops.secrets.phone-admin.path;

    phones = {
      kitchen = {
        mac = "00:0b:82:00:01:01";
        endpoint = "101";
      };
      living-room = {
        mac = "00:0b:82:00:01:02";
        endpoint = "102";
      };
      office = {
        mac = "00:0b:82:00:01:03";
        endpoint = "103";
      };
    };
  };
}
