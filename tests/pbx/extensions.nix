# Extensions through the probe (tests/campaign/probe.nix): each kind of
# destination in `noAnswer`, reached after the phone rang for `ringTime`, and
# in `busy`, reached when the phone answers busy; and names with quotes, with
# letters outside ASCII and of 79 bytes, read back from Asterisk as the caller
# ID. The phones are this Asterisk itself, at static contacts that ring
# without answering or answer busy.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  kinds = {
    conference.conference = "board";
    context = {context.context = "landed";};
    extension.extension = "201";
    hangup.hangup = true;
    ivr.ivr = "lobby";
    queue.queue = "desk";
    ringGroup.ringGroup = "front";
    voicemail.voicemail = "200";
  };
  kindNames = builtins.attrNames kinds;

  # extensions 211 ... that ring without an answer, and 221 ... that answer
  # busy, one for each kind, in the order of kindNames
  extensionFor = first: kind: toString (first + lib.lists.findFirstIndex (k: k == kind) null kindNames);
  ringing = extensionFor 211;
  answersBusy = extensionFor 221;

  # where each kind ends: the contexts after the extension's own, and the
  # last step
  hangup = {
    application = "Hangup";
    data = "";
    how = "hangup";
  };
  ends = {
    conference = {
      contexts = ["pbx-conference-board"];
      ended = {
        application = "ConfBridge";
        data = "board";
        how = "hangup";
      };
    };
    context = {
      contexts = ["landed"];
      ended = hangup;
    };
    extension = {
      contexts = ["pbx-extension-201"];
      ended = hangup;
    };
    hangup = {
      contexts = [];
      ended = hangup;
    };
    ivr = {
      contexts = ["pbx-ivr-lobby"];
      ended = hangup;
    };
    queue = {
      contexts = ["pbx-queue-desk"];
      ended = hangup;
    };
    ringGroup = {
      contexts = ["pbx-ringgroup-front"];
      ended = hangup;
    };
    voicemail = {
      contexts = [];
      ended = {
        application = "VoiceMail";
        data = "200@default,u";
        how = "hangup";
      };
    };
  };

  # each call, and whether the extension's check of the Dial status finds
  # the phone busy
  samples =
    map (kind: {
      number = ringing kind;
      inherit kind;
      busy = false;
    })
    kindNames
    ++ map (kind: {
      number = answersBusy kind;
      inherit kind;
      busy = true;
    })
    kindNames;

  names = {
    "231" = ''Front "Desk"'';
    "232" = builtins.fromJSON ''"J\u00fcrgen M\u00fcller"'';
    "233" = builtins.fromJSON ''"\u53d7\u4ed8 \u5c71\u7530"'';
    # the longest name Asterisk keeps whole, 79 bytes
    "234" = lib.concatStrings (lib.replicate 26 (builtins.fromJSON ''"\u5c71"'')) + "!";
  };

  result = probe {
    name = "pbx-extensions";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
        phone = contact: {
          aor = {
            contacts = ["sip:${contact}@127.0.0.1:5060"];
            qualifyFrequency = 0;
          };
        };
      in {
        pbx = {
          enable = true;
          extensions =
            {"201".password = secret "sip-201";}
            // lib.listToAttrs (map (kind:
              lib.nameValuePair (ringing kind) {
                password = secret "sip-${ringing kind}";
                ringTime = 1;
                noAnswer = kinds.${kind};
              })
            kindNames)
            // lib.listToAttrs (map (kind:
              lib.nameValuePair (answersBusy kind) {
                password = secret "sip-${answersBusy kind}";
                busy = kinds.${kind};
              })
            kindNames)
            // lib.mapAttrs (number: name: {
              inherit name;
              password = secret "sip-${number}";
            })
            names;
          ringGroups.front.members = ["201"];
          queues.desk.timeout = 1;
          conferences.board = {};
          ivrs.lobby = {
            prompt.sound = "beep";
            timeout = 1;
            attempts = 1;
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            endpoints =
              lib.listToAttrs (map (kind: lib.nameValuePair (ringing kind) (phone "ring")) kindNames)
              // lib.listToAttrs (map (kind: lib.nameValuePair (answersBusy kind) (phone "busy")) kindNames)
              // {
                # the phones' side of those calls
                line = {
                  context = "line";
                  identify.match = ["127.0.0.1"];
                  aor = null;
                };
              };
          };
          queues.queues.desk.members = ["PJSIP/201"];
          voicemail.mailboxes."200".pin = secret "vm-200";
          dialplan.contexts = {
            line.extensions = {
              ring = [
                "Ringing()"
                "Wait(30)"
              ];
              busy = ["Busy()"];
            };
            landed.extensions.s = ["Hangup()"];
          };
        };
      })
    ];
    commands = map (number: "pjsip show endpoint ${number}") (builtins.attrNames names);
    calls =
      map (sample: {
        extension = sample.number;
        context = "pbx-internal";
        # a conference goes on until the probe hangs up
        limit = 3;
      })
      samples;
  };

  expected = {
    calls =
      map (sample: {
        contexts = ["pbx-internal" "pbx-extension-${sample.number}"] ++ ends.${sample.kind}.contexts;
        busy = "${
          if sample.busy
          then "1"
          else "0"
        }?busy";
        ended = ends.${sample.kind}.ended;
      })
      samples;
    callerIds = lib.mapAttrsToList (number: name: ''"${lib.escape [''"''] name}" <${number}>'') names;
  };
in
  pkgs.runCommand "asterisk-pbx-extensions-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # each call's own channel, and the callerid line of each endpoint
    jq -S '{
      calls: [.calls[] | .channel as $channel | [.steps[] | select(.channel == $channel)] as $steps | {
        contexts: reduce ($steps[] | .context) as $context ([]; if last == $context then . else . + [$context] end),
        busy: [$steps[] | select(.application == "GotoIf")][0].data,
        ended: (.ended[] | select(.channel == $channel) | {application, data, how})
      }],
      callerIds: [.commands[].output | capture("\n *callerid +: (?<id>[^\n]*)\n").id]
    }' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
