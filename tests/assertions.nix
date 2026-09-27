# Invalid configurations must fail evaluation with a clear message.
#
# Each case evaluates the module with a small configuration and expects a
# substring in a failed assertion (`assertion`), in a warning (`warning`), or
# evaluation of the generated files to throw (`throws`). The result is the
# list of cases that did not behave as expected.
{ pkgs, self }:
let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix { inherit pkgs self; })
    evalConfig
    failedAssertions
    throws
    ;

  # A valid baseline each case breaks in one place.
  base =
    { config, ... }:
    {
      services.asterisk-declarative = {
        enable = true;
        pjsip = {
          transports.udp = { };
          endpoints."101" = {
            context = "internal";
            auth.password = config.lib.asterisk.secret "/run/agenix/101";
          };
        };
        dialplan.contexts.internal.extensions."_1XX" = [ "Dial(PJSIP/\${EXTEN})" ];
      };
    };

  cases = {
    baselineIsValid = {
      module = { };
      assertions = [ ];
      warnings = [ ];
    };

    danglingTransport = {
      module.services.asterisk-declarative.pjsip.endpoints."101".transport = "tcp";
      assertion = "[101] (type=endpoint) transport = tcp: no transport named `tcp`";
    };

    danglingAorFromLayerOne = {
      module.services.asterisk-declarative.settings."pjsip.conf"."endpoint:101".aors = lib.mkForce "nope";
      assertion = "aors = nope: no aor named `nope`";
    };

    danglingIdentifyEndpoint = {
      module.services.asterisk-declarative.settings."pjsip.conf".office-identify = {
        name = "office";
        type = "identify";
        endpoint = "office";
        match = [ "10.0.0.1" ];
      };
      assertion = "endpoint = office: no endpoint named `office`";
    };

    danglingRegistrationAuth = {
      module.services.asterisk-declarative.settings."pjsip.conf".reg = {
        type = "registration";
        server_uri = "sip:sip.example";
        client_uri = "sip:1@sip.example";
        outbound_auth = "missing";
      };
      assertion = "outbound_auth = missing: no auth named `missing`";
    };

    duplicateObject = {
      module.services.asterisk-declarative.settings."pjsip.conf".again = {
        name = "101";
        type = "endpoint";
        context = "internal";
        allow = [ "ulaw" ];
      };
      assertion = "more than once (same type and name):\n  endpoint 101";
    };

    missingEndpointContext = {
      module.services.asterisk-declarative.pjsip.endpoints."102" = {
        context = "nowhere";
        aor = null;
      };
      assertion = "[102] context = nowhere";
    };

    danglingInclude = {
      module.services.asterisk-declarative.dialplan.contexts.internal.includes = [ "outbound" ];
      assertion = "[internal] include => outbound";
    };

    danglingPredialSubroutine = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative.dialplan.contexts.internal.extensions."100" = [
            (config.lib.asterisk.dialplan.page {
              endpoints = [ "101" ];
              predial = "page-autoanswer";
            })
          ];
        };
      assertion = "pre-dial subroutines refer to contexts that are not defined:\n  [internal] page-autoanswer";
    };

    includeWithTimeSpecIsResolved = {
      module.services.asterisk-declarative.dialplan.contexts = {
        internal.includes = [ "daytime,09:00-17:00,mon-fri,*,*" ];
        daytime.extensions.s = [ "Answer()" ];
      };
      assertions = [ ];
    };

    contextsFromExtraConfigAreKnown = {
      module.services.asterisk-declarative = {
        pjsip.endpoints."101".context = lib.mkForce "legacy";
        extraConfig."extensions.conf" = ''
          [legacy]
          exten => 1,1,Answer()
        '';
      };
      assertions = [ ];
    };

    includedFilesDisableContextChecks = {
      module.services.asterisk-declarative = {
        pjsip.endpoints."101".context = lib.mkForce "elsewhere";
        includes."extensions.conf" = [ "extensions-local.conf" ];
      };
      assertions = [ ];
    };

    tlsWithoutKeys = {
      module.services.asterisk-declarative.pjsip.transports.tls.protocol = "tls";
      assertion = "TLS transport(s) tls need a certificate and a private key";
    };

    rtpRangeInverted = {
      module.services.asterisk-declarative.rtp.portRange = {
        from = 20000;
        to = 10000;
      };
      assertion = "`from` (20000) must be lower than `to` (10000)";
    };

    chanSip = {
      module.services.asterisk-declarative.modules.load = [ "chan_sip" ];
      assertion = "chan_sip.so is not supported";
    };

    secretInStore = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative.pjsip.endpoints."101".auth.password = lib.mkForce (
            config.lib.asterisk.secret "${builtins.storeDir}/0000000000000000000000000000000-pw"
          );
        };
      assertion = "is in the\nNix store";
    };

    invalidCredentialName = {
      module.services.asterisk-declarative.pjsip.endpoints."101".auth.password = lib.mkForce {
        _credential = "bad/name";
      };
      assertion = "invalid systemd credential name `bad/name`";
    };

    unsafeSecretPath = {
      module.services.asterisk-declarative.pjsip.endpoints."101".auth.password = lib.mkForce {
        _secret = "/run/agenix/with space";
      };
      assertion = "secret path `/run/agenix/with space` must be absolute";
    };

    secretInterpolatedIntoValue = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative.settings."voicemail.conf".default."200" =
            "${config.lib.asterisk.secret "/run/agenix/vm-200"},Sales,sales@example.org";
        };
      assertions = [ ];
      warnings = [ ];
    };

    reservedCredentialName = {
      module.services.asterisk-declarative.credentials.secret-x = "/run/x";
      assertion = "invalid or reserved credential name `secret-x`";
    };

    managedDirectory = {
      module.services.asterisk-declarative.settings."asterisk.conf".directories.astetcdir =
        lib.mkForce "/etc/asterisk";
      assertion = "directories.astetcdir is managed by the module";
    };

    invalidFileName = {
      module.services.asterisk-declarative.settings."../escape.conf".x.a = 1;
      assertion = "invalid configuration file name `../escape.conf`";
    };

    extensionWithoutSteps = {
      module.services.asterisk-declarative.dialplan.contexts.internal.extensions."200" = [ ];
      assertion = "extensions without steps or hint: internal/200";
    };

    extensionNameWithComma = {
      module.services.asterisk-declarative.dialplan.contexts.internal.extensions."2,1" = [ "Answer()" ];
      assertion = "invalid extension name(s)";
    };

    reservedContextName = {
      module.services.asterisk-declarative.dialplan.contexts.globals.extensions.s = [ "Answer()" ];
      assertion = "`general` and `globals` are reserved";
    };

    trunkEndpointNameClash = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative.pjsip.trunks."101" = {
            host = "sip.example";
            username = "u";
            password = config.lib.asterisk.secret "/run/agenix/trunk";
            context = "internal";
          };
        };
      assertion = "pjsip.trunks and pjsip.endpoints share the name(s) 101";
    };

    upstreamModuleEnabledToo = {
      module.services.asterisk.enable = true;
      assertion = "services.asterisk-declarative and services.asterisk cannot be enabled\ntogether";
    };

    voicemailNameWithComma = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative.voicemail.mailboxes."101" = {
            pin = config.lib.asterisk.secret "/run/agenix/vm";
            fullName = "Doe, John";
          };
        };
      assertion = "names and e-mail addresses cannot contain commas (101@default)";
    };

    mwiForUndefinedMailbox = {
      module =
        { config, ... }:
        {
          services.asterisk-declarative = {
            voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/agenix/vm";
            pjsip.endpoints."101".mailboxes = [ "102@default" ];
          };
        };
      assertion = "pjsip.endpoints.101.mailboxes: 102@default";
    };

    voicemailPlainPinWarns = {
      module.services.asterisk-declarative.voicemail.mailboxes."101".pin = "1234";
      assertions = [ ];
      warning = "voicemail.mailboxes.\"101@default\".pin is a plain string";
    };

    plainPasswordWarns = {
      module.services.asterisk-declarative.pjsip.endpoints."101".auth.password = lib.mkForce "hunter2";
      assertions = [ ];
      warning = ''settings."pjsip.conf"."auth:101".password is a plain string'';
    };

    sameKeyWarns = {
      module.services.asterisk-declarative.settings."extensions.conf".internal.same = [ "n,Hangup()" ];
      warning = "`same` keys in settings.\"extensions.conf\"";
    };

    newlineInValueThrows = {
      module.services.asterisk-declarative.pjsip.endpoints."101".callerId = "a\nb";
      throws = true;
    };

    invalidKeyThrows = {
      module.services.asterisk-declarative.settings."pjsip.conf"."endpoint:101"."bad key=" = "x";
      throws = true;
    };

    invalidProtocolThrows = {
      module.services.asterisk-declarative.pjsip.transports.udp.protocol = "sctp";
      throws = true;
    };

    nestedAttrsetValueThrows = {
      module.services.asterisk-declarative.settings."rtp.conf".general.rtpstart.nested = 1;
      throws = true;
    };
  };

  check =
    name: case:
    let
      config = evalConfig [
        base
        case.module
      ];
      failed = failedAssertions config;
      inherit (config) warnings;
      has = needle: haystack: builtins.any (lib.hasInfix needle) haystack;
      problems =
        lib.optional (case ? assertion && !(has case.assertion failed)) {
          expectedAssertion = case.assertion;
          inherit failed;
        }
        ++ lib.optional (case ? assertions && failed != case.assertions) {
          expectedAssertions = case.assertions;
          inherit failed;
        }
        ++ lib.optional (case ? warning && !(has case.warning warnings)) {
          expectedWarning = case.warning;
          inherit warnings;
        }
        ++ lib.optional (case ? warnings && warnings != case.warnings) {
          expectedWarnings = case.warnings;
          inherit warnings;
        }
        ++
          lib.optional (case.throws or false && !(throws config.services.asterisk-declarative.renderedFiles))
            {
              expectedThrow = true;
            };
    in
    lib.optional (problems != [ ]) { ${name} = problems; };
in
lib.concatLists (lib.mapAttrsToList check cases)
