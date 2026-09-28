# Small office PBX with a SIP trunk.
#
#   lan  10.1.0.0/24     desk phones and softphones
#   wan  203.0.113.0/24  the provider's network (here: directly attached)
#
#   201-203       phones, busy/unavailable -> personal voicemail
#   5551000       the office's number (DID): rings 201 and 202 for 15 s,
#                 then the sales voicemail box 200
#   9 + number    outbound calls through the provider, presenting 5551000
#   600           support queue (201, 202)
#   800           conference bridge
#   *97           voicemail menu
#
# Keys without a typed option can be set through the `settings` attribute of
# typed objects or through `services.asterisk.settings`.
# Passwords and PINs come from sops-nix (set sops.defaultSopsFile in the host's
# configuration).
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

  services.asterisk = {
    enable = true;

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
        context = "from-provider";
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

      endpoints =
        builtins.mapAttrs (extension: name: {
          context = "office";
          callerId = ''"${name}" <${extension}>'';
          auth.password = sopsSecret "sip-${extension}";
          mailboxes = ["${extension}@default"];
        })
        phones;
    };

    dialplan = {
      globals = {
        MAIN_NUMBER = "5551000";
        RING_GROUP = "PJSIP/201&PJSIP/202";
      };

      contexts = {
        office = {
          includes = ["outbound"];
          hints = builtins.mapAttrs (extension: _: "PJSIP/${extension}") phones;
          extensions = {
            "_20X" = [
              "Dial(PJSIP/\${EXTEN},20)"
              "VoiceMail(\${EXTEN}@default,u)"
              "Hangup()"
            ];
            "600" = [
              "Answer()"
              "Queue(support,,,,120)"
              "VoiceMail(200@default,u)"
              "Hangup()"
            ];
            "800" = [
              "Answer()"
              "ConfBridge(800)"
              "Hangup()"
            ];
            "*97" = [
              "Answer()"
              "VoiceMailMain(\${CALLERID(num)}@default)"
              "Hangup()"
            ];
          };
        };

        outbound.extensions."_9X." = [
          "Set(CALLERID(num)=\${MAIN_NUMBER})"
          "Dial(PJSIP/\${EXTEN:1}@provider,60)"
          "Hangup()"
        ];

        from-provider.extensions."5551000" = [
          "Dial(\${RING_GROUP},15)"
          "VoiceMail(200@default,u)"
          "Hangup()"
        ];
      };
    };

    voicemail = {
      mailboxes =
        {
          "200" = {
            fullName = "Sales team";
            pin = sopsSecret "vm-200";
          };
        }
        // builtins.mapAttrs (extension: name: {
          fullName = name;
          pin = sopsSecret "vm-${extension}";
        })
        phones;
      maxMessages = 100;
      maxSeconds = 300;
    };

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
