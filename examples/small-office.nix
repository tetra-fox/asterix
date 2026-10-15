# Small office PBX with a SIP trunk (see README.md)
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

  services.asterix = {
    enable = true;

    # SIP and RTP open on both interfaces, and requests only from the two
    # subnets
    openFirewall = true;
    networks = {
      lan = {
        interface = "lan";
        address = "10.1.0.10";
        subnets = ["10.1.0.0/24"];
      };
      # no phones here. The provider's subnet, since without it the networks
      # set no SIP ACL
      wan = {
        interface = "wan";
        address = "203.0.113.10";
        subnets = ["203.0.113.0/24"];
      };
    };

    trunks.provider = {
      network = "wan";
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
      # the provider's servers. This network contains sip.provider.example.
      identify.match = ["203.0.113.0/24"];
      matchProviderHost = false;
    };

    # calls a phone does not take go to its own mailbox
    extensions =
      builtins.mapAttrs (extension: name: {
        inherit name;
        network = "lan";
        password = sopsSecret "sip-${extension}";
        voicemail.pin = sopsSecret "vm-${extension}";
      })
      phones;
    voicemailMenu = "*97";

    voicemail = {
      # the sales team's mailbox, which belongs to no phone
      mailboxes."200" = {
        name = "Sales team";
        pin = sopsSecret "vm-200";
      };
      maxMessages = 100;
      maxSeconds = 300;
    };

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
      members = [
        "201"
        "202"
      ];
      strategy = "ringall";
      memberTimeout = 20;
      retry = 5;
      musicOnHold = "default";
      maxWait = 120;
      noAnswer.voicemail = "200";
    };

    conferences.office = {
      number = "800";
      maxMembers = 20;
      musicOnHoldWhenEmpty = true;
      announceJoinLeave = false;
    };

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
}
