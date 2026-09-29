# Destinations followed through the dialplan, call by call (the probe,
# tests/campaign/probe.nix): a menu key goes to a ring group, whose no-answer
# destination is a queue, whose timeout goes to a mailbox. Nobody is
# registered, so the ring group has no phone to ring and the queue no member
# to take the call.
{
  pkgs,
  self,
}: let
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  result = probe {
    name = "pbx-destinations";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        pbx = {
          enable = true;
          extensions = {
            "201".password = secret "sip-201";
            "202".password = secret "sip-202";
          };
          ivrs.menu = {
            number = "700";
            prompt.text = "For sales, press 1.";
            options."1".ringGroup = "sales";
          };
          ringGroups.sales = {
            number = "600";
            members = [
              "201"
              "202"
            ];
            noAnswer.queue = "support";
          };
          queues.support = {
            number = "610";
            timeout = 1;
            noAnswer.voicemail = "200";
          };
        };
        services.asterisk = {
          pjsip.transports.udp = {};
          queues.queues.support.members = [
            "PJSIP/201"
            "PJSIP/202"
          ];
          voicemail.mailboxes."200".pin = secret "vm-200";
        };
      })
    ];
    # each link of the chain dialled from a phone
    calls = [
      {
        extension = "700";
        context = "pbx-internal";
        keys = "1";
      }
      {
        extension = "600";
        context = "pbx-internal";
      }
      {
        extension = "610";
        context = "pbx-internal";
      }
    ];
  };

  # the contexts a call passes through, and where it ends: the mailbox, which
  # hangs up when the caller stays silent
  voicemail = {
    ended = [
      {
        application = "VoiceMail";
        data = "200@default,u";
        how = "hangup";
      }
    ];
    answered = true;
    limitReached = false;
  };
  expected = [
    (voicemail
      // {
        contexts = [
          "pbx-internal"
          "pbx-ivr-menu"
          "pbx-ringgroup-sales"
          "pbx-queue-support"
        ];
      })
    (voicemail
      // {
        contexts = [
          "pbx-internal"
          "pbx-ringgroup-sales"
          "pbx-queue-support"
        ];
      })
    (voicemail
      // {
        contexts = [
          "pbx-internal"
          "pbx-queue-support"
        ];
      })
  ];
in
  pkgs.runCommand "asterisk-pbx-destinations-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    jq -S '[.calls[] | {
      contexts: reduce .steps[].context as $context ([]; if last == $context then . else . + [$context] end),
      ended: [.ended[] | {application, data, how}],
      answered,
      limitReached
    }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
