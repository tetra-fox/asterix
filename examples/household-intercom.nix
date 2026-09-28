# Household intercom on a multi-homed host: phones call each other directly,
# and three or more can meet in a conference room.
#
#   servers VLAN  10.0.1.0/24   the host's main network (SSH, WAN); no SIP here
#   trusted LAN   10.0.10.0/24  softphones on Wi-Fi
#   VoIP VLAN     10.0.20.0/24  analog phones on Grandstream HT801 adapters, no
#                               WAN access
#
# The host does not route between the VLANs; Asterisk bridges calls and
# relays their media (direct_media = no), so phones on different VLANs never
# talk to each other directly. SIP and RTP are only reachable from the
# trusted LAN and the VoIP VLAN (firewall per interface, SIP ACL per subnet,
# transports bound to those two addresses only).
#
#   101-102  analog phones (HT801)
#   201-202  softphones
#   800      conference room
#
# Passwords come from sops-nix (set sops.defaultSopsFile in the host's
# configuration). Adapt the `site` block to your network.
{
  config,
  lib,
  ...
}: let
  inherit (config.lib.asterisk) secret;

  site = {
    trusted = {
      interface = "lan";
      address = "10.0.10.10";
      subnet = "10.0.10.0/24";
    };
    voip = {
      interface = "voip";
      address = "10.0.20.10";
      subnet = "10.0.20.0/24";
    };
  };

  # extension -> phone; `network` picks the transport the phone is reached on
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

  services.asterisk = {
    enable = true;

    # SIP and RTP only on the two phone networks.
    openFirewall = true;
    firewallInterfaces = [
      site.trusted.interface
      site.voip.interface
    ];

    pjsip = {
      transports = {
        trusted.address = site.trusted.address;
        voip.address = site.voip.address;
      };

      # Requests from anywhere else are rejected before authentication.
      acls.phones = {
        deny = [
          "0.0.0.0/0.0.0.0"
          "::/0"
        ];
        permit = [
          site.trusted.subnet
          site.voip.subnet
        ];
      };

      endpoints =
        lib.mapAttrs (extension: phone: {
          context = "intercom";
          transport = phone.network;
          callerId = ''"${phone.name}" <${extension}>'';
          auth.password = secret config.sops.secrets."sip-${extension}".path;
          # Only accept registrations from the phone's own network.
          settings = {
            contact_deny = "0.0.0.0/0.0.0.0";
            contact_permit = site.${phone.network}.subnet;
          };
        })
        phones;
    };

    dialplan.contexts.intercom = {
      hints = lib.mapAttrs (extension: _: "PJSIP/${extension}") phones;

      extensions =
        lib.mapAttrs (extension: _: [
          "Dial(PJSIP/${extension},30)"
          "Hangup()"
        ])
        phones
        // {
          # everyone who dials 800 is in the same conference
          "800" = [
            "Answer()"
            "ConfBridge(800)"
            "Hangup()"
          ];
        };
    };
  };
}
