# Intercom on a host with several networks (see README.md)
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (config.lib.asterisk) secret;

  # what someone who dials 911 on these phones hears
  noEmergencyCalls = pkgs.runCommand "sounds-no-emergency-calls" {nativeBuildInputs = [pkgs.flite];} ''
    mkdir -p $out/sounds/en/custom
    flite -voice slt -o $out/sounds/en/custom/no-emergency-calls.wav16 \
      -t "This phone cannot call nine one one. Use a cell phone."
  '';

  # adapt to your network
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

    sounds.packages = [noEmergencyCalls];

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
          # there is no line out, so say that instead of an error tone
          "911" = [
            "Answer()"
            "Playback(custom/no-emergency-calls)"
            "Playback(custom/no-emergency-calls)"
            "Hangup()"
          ];
        };
    };
  };
}
