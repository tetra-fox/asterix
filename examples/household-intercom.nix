# Intercom on a host with several networks (see README.md)
{
  config,
  lib,
  ...
}: let
  inherit (config.lib.asterisk) secret;

  # phones by extension, each on a network of services.asterix.networks
  phones = {
    "101" = {
      name = "Kitchen";
      network = "voip";
    };
    "102" = {
      name = "Living room";
      network = "voip";
    };
    "201" = {
      name = "Phone A";
      network = "trusted";
    };
    "202" = {
      name = "Phone B";
      network = "trusted";
    };
  };
in {
  # Phones on one VLAN must not reach the other VLAN through this host.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = false;
    "net.ipv6.conf.all.forwarding" = false;
  };

  # root-only files are fine: asterisk.service reads them as credentials, and
  # a reload picks up a changed password
  sops.secrets =
    lib.mapAttrs' (
      extension: _: lib.nameValuePair "sip-${extension}" {reloadUnits = ["asterisk.service"];}
    )
    phones;

  services.asterix = {
    enable = true;

    # SIP and RTP only on these interfaces, requests only from the subnets,
    # and each phone registers only from its own network
    openFirewall = true;
    networks = {
      trusted = {
        interface = "lan";
        address = "10.0.10.10";
        subnets = ["10.0.10.0/24"];
      };
      voip = {
        interface = "voip";
        address = "10.0.20.10";
        subnets = ["10.0.20.0/24"];
      };
    };

    extensions =
      lib.mapAttrs (extension: phone: {
        inherit (phone) name network;
        password = secret config.sops.secrets."sip-${extension}".path;
        ringTime = 30;
      })
      phones;

    # everyone who dials 800 is in the same conference
    conferences.everyone.number = "800";

    # there is no line out, so say that instead of an error tone
    announcements.no-emergency-calls = {
      number = "911";
      prompt.text = "This phone cannot call nine one one. Use a cell phone.";
      repeat = 2;
    };
  };
}
