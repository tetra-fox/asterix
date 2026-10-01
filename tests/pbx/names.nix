# Each name of the adversarial set that evaluation accepts for a ring group,
# opening hours, a page, a conference or a queue, followed through a call to
# its object (the probe, tests/campaign/probe.nix): the call reaches the
# object's context and runs its steps as it does with a plain name. The names
# evaluation rejects are cases of ./assertions.nix and ../assertions.nix; ;
# [ ] and a trailing space make no section name (lib/format.nix).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ../campaign/probe.nix {inherit pkgs self;};

  long = lib.strings.replicate 80 "n";
  names = {
    ringGroups = ["a|b" "a$b" "a)b" "a(b)" "a=>b" " lead" "héllo wörld" "" long];
    closeEarly = ["a|b" "a$b" "a)b" " lead" "héllo wörld" "" "a\"b"];
    # the names hours only take without closeEarly
    hours = ["a=>b" long];
    paging = ["a|b" "a$b" "a=>b" " lead" "héllo wörld" "" long];
    conferences = ["a|b" "a$b" "a)b" "a(b)" "a=>b" " lead" "héllo wörld"];
    queues = ["a|b" "a$b" "a)b" "a(b)" "a=>b" "héllo wörld"];
  };
  objects = kind: lib.imap1 (i: name: {inherit i name;}) names.${kind};
  forEach = kind: f: lib.listToAttrs (map f (objects kind));

  done = extension: {
    context = {
      context = "done";
      inherit extension;
    };
  };
  hours = {
    timezone = "UTC";
    open = [
      {
        days = "mon-fri";
        time = "09:00-17:00";
      }
    ];
  };
  # a Wednesday, 10:00
  open = "2026-12-02T10:00:00Z";

  # Asterisk keeps 79 bytes of the context a channel is in
  context = kind: name: builtins.substring 0 79 "pbx-${kind}-${name}";

  # each call, the contexts its channel passes through, its last step, the
  # marks of done it reaches, the steps of the object that the call's other
  # channels run and what Asterisk warns about
  samples =
    map (o: {
      call = {
        extension = "60${toString o.i}";
        context = "pbx-internal";
      };
      contexts = ["pbx-internal" (context "ringgroup" o.name) "done"];
      marks = ["done rg${toString o.i}"];
      legs = ["${context "ringgroup" o.name},5559000"];
    }) (objects "ringGroups")
    ++ lib.concatMap (o: [
      {
        call = {
          extension = "*28${toString o.i}";
          context = "pbx-internal";
        };
        contexts = ["pbx-internal" (context "hours" o.name)];
        answered = true;
        warnings = lib.optional (lib.hasInfix " " o.name) "Please avoid unnecessary spaces on variables as it may lead to unexpected results ('DEVICE_STATE(Custom:pbx-hours-${o.name})' set to 'INUSE').";
      }
      {
        call = {
          extension = "55540${toString o.i}";
          context = "pbx-inbound-provider";
          time = open;
        };
        contexts = ["pbx-inbound-provider" (context "hours" o.name) "pbx-inbound-provider" "done"];
        marks = ["done c${toString o.i}closed"];
      }
    ]) (objects "closeEarly")
    ++ map (o: {
      call = {
        extension = "55530${toString o.i}";
        context = "pbx-inbound-provider";
        time = open;
      };
      contexts = ["pbx-inbound-provider" (context "hours" o.name) "pbx-inbound-provider" "done"];
      marks = ["done h${toString o.i}open"];
    }) (objects "hours")
    # a page and a conference last until the probe hangs up
    ++ map (o: {
      call = {
        extension = "65${toString o.i}";
        context = "pbx-internal";
        limit = 1;
      };
      contexts = ["pbx-internal" (context "paging" o.name)];
      last = "Page(Local/201@pbx-paging-${o.name}/n)";
      # the member's Local channel, and the pre-dial routine on its device
      legs = ["${context "paging" o.name},201" "${context "paging" o.name},headers"];
      answered = true;
      limitReached = true;
    }) (objects "paging")
    ++ map (o: {
      call = {
        extension = "80${toString o.i}";
        context = "pbx-internal";
        limit = 1;
      };
      contexts = ["pbx-internal" (context "conference" o.name)];
      last = "ConfBridge(${o.name})";
      answered = true;
      limitReached = true;
    }) (objects "conferences")
    ++ map (o: {
      call = {
        extension = "61${toString o.i}";
        context = "pbx-internal";
      };
      contexts = ["pbx-internal" (context "queue" o.name) "done"];
      marks = ["done q${toString o.i}"];
      answered = true;
    }) (objects "queues");

  result = probe {
    name = "pbx-names";
    modules = [
      self.nixosModules.pbx
      ({config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        pbx = {
          enable = true;
          extensions."201".password = secret "sip-201";
          outbound = {
            prefix = "9";
            trunk = "provider";
          };
          ringGroups = forEach "ringGroups" (o:
            lib.nameValuePair o.name {
              number = "60${toString o.i}";
              members = ["201"];
              external = ["5559000"];
              noAnswer = done "rg${toString o.i}";
            });
          hours =
            forEach "closeEarly" (o: lib.nameValuePair o.name (hours // {closeEarly = "*28${toString o.i}";}))
            // forEach "hours" (o: lib.nameValuePair o.name hours);
          inbound =
            forEach "closeEarly" (o:
              lib.nameValuePair "55540${toString o.i}" {
                trunk = "provider";
                hours = o.name;
                open = done "c${toString o.i}open";
                closed = done "c${toString o.i}closed";
              })
            // forEach "hours" (o:
              lib.nameValuePair "55530${toString o.i}" {
                trunk = "provider";
                hours = o.name;
                open = done "h${toString o.i}open";
                closed = done "h${toString o.i}closed";
              });
          paging = forEach "paging" (o:
            lib.nameValuePair o.name {
              number = "65${toString o.i}";
              members = ["201"];
            });
          conferences = forEach "conferences" (o: lib.nameValuePair o.name {number = "80${toString o.i}";});
          queues = forEach "queues" (o:
            lib.nameValuePair o.name {
              number = "61${toString o.i}";
              timeout = 1;
              noAnswer = done "q${toString o.i}";
            });
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "trunk";
              register = false;
              # a qualify, which fails without DNS, would mark the provider
              # unreachable at a random moment among the calls to it
              qualifyFrequency = 0;
            };
            # the phone of 201 is this Asterisk, which answers busy
            endpoints = {
              "201".aor = {
                contacts = ["sip:busy@127.0.0.1:5060"];
                qualifyFrequency = 0;
              };
              busy-line = {
                context = "busy-line";
                identify.match = ["127.0.0.1"];
                aor = null;
              };
            };
          };
          # a queue tries its busy member again after a second, not five
          queues.queues = forEach "queues" (o:
            lib.nameValuePair o.name {
              members = ["PJSIP/201"];
              retry = 1;
            });
          dialplan.contexts = {
            busy-line.extensions.busy = ["Busy()"];
            done.extensions = lib.genAttrs (
              map (o: "rg${toString o.i}") (objects "ringGroups")
              ++ lib.concatMap (o: ["c${toString o.i}open" "c${toString o.i}closed"]) (objects "closeEarly")
              ++ lib.concatMap (o: ["h${toString o.i}open" "h${toString o.i}closed"]) (objects "hours")
              ++ map (o: "q${toString o.i}") (objects "queues")
            ) (extension: ["NoOp(done ${extension})" "Hangup()"]);
          };
        };
      })
    ];
    calls = map (sample: sample.call) samples;
  };

  expected =
    map (sample: {
      inherit (sample) contexts;
      last = sample.last or "Hangup()";
      marks = sample.marks or [];
      legs = sample.legs or [];
      answered = sample.answered or false;
      limitReached = sample.limitReached or false;
      warnings = sample.warnings or [];
    })
    samples;
in
  pkgs.runCommand "asterisk-pbx-names-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON expected;
    passAsFile = ["expected"];
  } ''
    jq -S '[.calls[] | .channel as $channel | {
      contexts: reduce (.steps[] | select(.channel == $channel) | .context) as $context ([]; if last == $context then . else . + [$context] end),
      last: ([.steps[] | select(.channel == $channel)] | last | "\(.application)(\(.data))"),
      marks: [.steps[] | select(.channel == $channel and .context == "done" and .application == "NoOp") | .data],
      legs: [.steps[] | select(.channel != $channel and (.context | test("^pbx-(ringgroup|paging)-"))) | "\(.context),\(.extension)"] | unique,
      answered,
      limitReached,
      warnings: [.log[] | select(.level == "WARNING" or .level == "ERROR") | .message]
    }]' ${result}/probe.json > actual
    if ! diff -u <(jq -S . "$expectedPath") actual; then
      echo "a call to an object went elsewhere, see ${result}/probe.json" >&2
      exit 1
    fi
    touch $out
  ''
