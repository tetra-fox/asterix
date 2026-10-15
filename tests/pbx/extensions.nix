# Extensions through the probe (tests/campaign/probe.nix): a hangup, another
# extension and a mailbox in `noAnswer`, reached after the phone rang for
# `ringTime`, and in `busy`, reached when the phone answers busy, with the
# cause a hangup destination ends such a call with. The phones are this
# Asterisk itself, at static contacts that ring without answering or answer
# busy.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  kinds = {
    extension.extension = "201";
    hangup.hangup = true;
    voicemail.voicemail = "200";
  };
  kindNames = builtins.attrNames kinds;

  # extensions 211 ... that ring without an answer, and 221 ... that answer
  # busy, one for each kind, in the order of kindNames
  extensionFor = first: kind: toString (first + lib.lists.findFirstIndex (k: k == kind) null kindNames);
  ringing = extensionFor 211;
  answersBusy = extensionFor 221;

  # where each kind ends: the contexts after the extension's own, and the
  # last step. A hangup destination gives a caller not answered yet no answer
  # (19), unless the phone answered busy, which stays the call's cause.
  ends = busy: let
    unanswered = {
      application = "Hangup";
      data =
        if busy
        then ""
        else "19";
      how = "hangup";
    };
  in {
    extension = {
      contexts = ["pbx-extension-201"];
      ended = unanswered;
    };
    hangup = {
      contexts = [];
      ended = unanswered;
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

  result = probe {
    name = "pbx-extensions";
    modules = [
      self.nixosModules.default
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
        phone = contact: {
          aor = {
            contacts = ["sip:${contact}@127.0.0.1:5060"];
            qualifyFrequency = 0;
          };
        };
      in {
        services.asterix = {
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
            kindNames);
        };
        services.asterisk = {
          pjsip = {
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
          voicemail.mailboxes."200".pin = secret "vm-200";
          dialplan.contexts.line.extensions = {
            ring = [
              "Ringing()"
              "Wait(30)"
            ];
            busy = ["Busy()"];
          };
        };
      })
    ];
    calls =
      map (sample: {
        extension = sample.number;
        context = "pbx-internal";
        # the probe ends a call to a mailbox after 3 s
        limit = 3;
      })
      samples;
  };

  expected =
    map (sample: {
      contexts = ["pbx-internal" "pbx-extension-${sample.number}"] ++ (ends sample.busy).${sample.kind}.contexts;
      busy = "${
        if sample.busy
        then "1"
        else "0"
      }?busy";
      ended = (ends sample.busy).${sample.kind}.ended;
    })
    samples;
in
  pkgs.runCommand "asterisk-pbx-extensions-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    # each call's own channel
    jq -S '[.calls[] | .channel as $channel | [.steps[] | select(.channel == $channel)] as $steps | {
      contexts: reduce ($steps[] | .context) as $context ([]; if last == $context then . else . + [$context] end),
      busy: [$steps[] | select(.application == "GotoIf")][0].data,
      ended: (.ended[] | select(.channel == $channel) | {application, data, how})
    }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "the calls went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
