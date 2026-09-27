# Household intercom on a multi-homed host.
#
#   servers VLAN  10.0.1.0/24   the host's main network (SSH, WAN); no SIP here
#   trusted LAN   10.0.10.0/24  softphones on Wi-Fi
#   VoIP VLAN     10.0.20.0/24  Grandstream desk phones, no WAN access
#
# The host does not route between the VLANs; Asterisk bridges calls and
# relays their media (direct_media = no), so phones on different VLANs never
# talk to each other directly. SIP and RTP are only reachable from the
# trusted LAN and the VoIP VLAN (firewall per interface, SIP ACL per subnet,
# transports bound to those two addresses only).
#
#   101-103  desk phones   (dial each other directly)
#   201-202  softphones
#   100      page everybody (full duplex, phones auto-answer)
#   110      page downstairs
#   120      page upstairs
#
# Everything here uses the generic module; the paging helpers come from
# `config.lib.asterisk.dialplan`. Adapt the `site` block to your network.
{ config, lib, ... }:
let
  inherit (config.lib.asterisk) secret;
  dp = config.lib.asterisk.dialplan;

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
      groups = [ "downstairs" ];
    };
    "102" = {
      name = "Living room";
      network = "voip";
      groups = [ "downstairs" ];
    };
    "103" = {
      name = "Office";
      network = "voip";
      groups = [ "upstairs" ];
    };
    "201" = {
      name = "Phone A";
      network = "trusted";
      groups = [ ];
    };
    "202" = {
      name = "Phone B";
      network = "trusted";
      groups = [ ];
    };
  };

  pageGroups = {
    "100" = lib.attrNames phones;
    "110" = members "downstairs";
    "120" = members "upstairs";
  };

  members = group: lib.attrNames (lib.filterAttrs (_: phone: lib.elem group phone.groups) phones);
in
{
  # Phones on one VLAN must not reach the other VLAN through this host.
  boot.kernel.sysctl = {
    "net.ipv4.conf.all.forwarding" = false;
    "net.ipv6.conf.all.forwarding" = false;
  };

  services.asterisk-declarative = {
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

      endpoints = lib.mapAttrs (extension: phone: {
        context = "intercom";
        transport = phone.network;
        callerId = ''"${phone.name}" <${extension}>'';
        auth.password = secret "/run/agenix/sip-${extension}";
        # Only accept registrations from the phone's own network.
        settings = {
          contact_deny = "0.0.0.0/0.0.0.0";
          contact_permit = site.${phone.network}.subnet;
        };
      }) phones;
    };

    dialplan.contexts = {
      intercom = {
        # busy lamp field on the desk phones
        hints = lib.mapAttrs (extension: _: "PJSIP/${extension}") phones;

        extensions =
          lib.mapAttrs (extension: _: [
            "Dial(PJSIP/${extension},30)"
            "Hangup()"
          ]) phones
          // lib.mapAttrs (_: endpoints: [
            (dp.page {
              inherit endpoints;
              predial = "page-autoanswer";
              # skip busy phones, including the caller's own
              extraOptions = "s";
            })
            "Hangup()"
          ]) pageGroups;
      };

      # Runs on each paged phone's channel before it is called.
      page-autoanswer = dp.autoAnswerContext { };
    };
  };
}
