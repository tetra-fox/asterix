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
# Voicemail, the queue and the conference use layer-1 settings here, which
# shows how anything without a typed option is configured.
{ config, ... }:
let
  inherit (config.lib.asterisk) secret;

  phones = {
    "201" = "Reception";
    "202" = "Sales";
    "203" = "Boss";
  };
in
{
  services.asterisk-declarative = {
    enable = true;

    openFirewall = true;
    firewallInterfaces = [
      "lan"
      "wan"
    ];

    pjsip = {
      transports.udp = { };

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
        password = secret "/run/agenix/sip-trunk";
        context = "from-provider";
        allow = [
          "g722"
          "alaw"
          "ulaw"
        ];
        # inbound calls arrive for the number we register
        registration.contactUser = "5551000";
        identify.match = [ "203.0.113.0/24" ];
      };

      endpoints = builtins.mapAttrs (extension: name: {
        context = "office";
        callerId = ''"${name}" <${extension}>'';
        auth.password = secret "/run/agenix/sip-${extension}";
        mailboxes = [ "${extension}@default" ];
      }) phones;
    };

    dialplan = {
      globals = {
        MAIN_NUMBER = "5551000";
        RING_GROUP = "PJSIP/201&PJSIP/202";
      };

      contexts = {
        office = {
          includes = [ "outbound" ];
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

    modules.load = [
      "app_queue.so"
      "app_voicemail.so"
    ];

    settings = {
      "voicemail.conf" = {
        general = {
          format = "wav49|wav";
          maxmsg = 100;
          maxsecs = 300;
          attach = false;
        };
        # mailbox => PIN,full name; the PIN is a secret interpolated into the value
        default = {
          "200" = "${secret "/run/agenix/vm-200"},Sales team";
          "201" = "${secret "/run/agenix/vm-201"},Reception";
          "202" = "${secret "/run/agenix/vm-202"},Sales";
          "203" = "${secret "/run/agenix/vm-203"},Boss";
        };
      };

      "queues.conf".support = {
        strategy = "ringall";
        timeout = 20;
        retry = 5;
        musicclass = "default";
        member = [
          "PJSIP/201"
          "PJSIP/202"
        ];
      };

      "confbridge.conf" = {
        default_user = {
          type = "user";
          announce_join_leave = false;
          music_on_hold_when_empty = true;
        };
        default_bridge = {
          type = "bridge";
          max_members = 20;
        };
      };
    };

    syntax."voicemail.conf".arrowSections = [ "default" ];
  };
}
