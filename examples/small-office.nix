# Small office PBX with a SIP trunk, written with the pbx layer: import
# asterix.nixosModules.pbx (see README.md)
{
  config,
  lib,
  ...
}: let
  phones = {
    "201" = "Reception";
    "202" = "Sales";
    "203" = "Boss";
  };

  sopsSecret = name: config.lib.asterisk.secret config.sops.secrets.${name}.path;
in {
  # root-only files are fine: asterisk.service reads them as credentials, and
  # a reload picks up a changed password
  sops.secrets =
    lib.genAttrs
    (
      [
        "sip-trunk"
        "vm-200"
      ]
      ++ lib.concatMap (extension: [
        "sip-${extension}"
        "vm-${extension}"
      ]) (lib.attrNames phones)
    )
    (_: {
      reloadUnits = ["asterisk.service"];
    });

  pbx = {
    enable = true;

    # calls a phone does not take go to its own mailbox
    extensions =
      builtins.mapAttrs (extension: name: {
        inherit name;
        password = sopsSecret "sip-${extension}";
        voicemail.pin = sopsSecret "vm-${extension}";
      })
      phones;
    voicemailMenu = "*97";

    ringGroups.sales = {
      members = [
        "201"
        "202"
      ];
      ringTime = 15;
      noAnswer.voicemail = "200";
    };

    queues.support = {
      number = "600";
      timeout = 120;
      noAnswer.voicemail = "200";
    };

    conferences."800".number = "800";

    # the office's number
    inbound."5551000" = {
      trunk = "provider";
      destination.ringGroup = "sales";
    };

    outbound = {
      prefix = "9";
      trunk = "provider";
      callerId = "5551000";
    };

    # US rules: 911 works without the 9, and reception is called at the same
    # time and hears the caller's number
    emergency = {
      numbers = ["911"];
      trunk = "provider";
      callerId = "5551000";
      notify = ["201"];
    };
  };

  services.asterisk = {
    openFirewall = true;
    firewallInterfaces = [
      "lan"
      "wan"
    ];

    pjsip = {
      transports.udp = {};

      acls.office = {
        deny = [
          "0.0.0.0/0.0.0.0"
          "::/0"
        ];
        permit = [
          "10.1.0.0/24"
          # the provider's signalling and media servers
          "203.0.113.0/24"
        ];
      };

      trunks.provider = {
        host = "sip.provider.example";
        username = "5551000";
        password = sopsSecret "sip-trunk";
        allow = [
          "g722"
          "alaw"
          "ulaw"
        ];
        # inbound calls arrive for the number we register
        registration.contactUser = "5551000";
        # the provider's servers; this network contains sip.provider.example
        identify.match = ["203.0.113.0/24"];
        matchProviderHost = false;
      };
    };

    voicemail = {
      # the sales team's mailbox, which belongs to no phone
      mailboxes."200" = {
        fullName = "Sales team";
        pin = sopsSecret "vm-200";
      };
      maxMessages = 100;
      maxSeconds = 300;
    };

    # pbx.queues.support gives this queue its number
    queues.queues.support = {
      strategy = "ringall";
      timeout = 20;
      retry = 5;
      musicOnHoldClass = "default";
      members = [
        "PJSIP/201"
        "PJSIP/202"
      ];
    };

    confbridge = {
      bridges.default_bridge.maxMembers = 20;
      users.default_user = {
        musicOnHoldWhenEmpty = true;
        # no typed option for this one: set the key directly
        settings.announce_join_leave = false;
      };
    };
  };
}
