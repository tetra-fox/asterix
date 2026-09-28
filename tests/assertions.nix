# Invalid configurations must fail evaluation with a clear message.
#
# Each case evaluates the module with a small configuration and expects a
# substring in a failed assertion (`assertion`), in a warning (`warning`), or
# evaluation of the generated files to throw (`throws`). The result is the
# list of cases that did not behave as expected.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit
    (import ./eval-lib.nix {inherit pkgs self;})
    evalConfig
    failedAssertions
    throws
    ;

  # A valid baseline each case breaks in one place.
  base = {config, ...}: {
    services.asterisk = {
      enable = true;
      pjsip = {
        transports.udp = {};
        endpoints."101" = {
          context = "internal";
          auth.password = config.lib.asterisk.secret "/run/secrets/101";
        };
      };
      dialplan.contexts.internal.extensions."_1XX" = ["Dial(PJSIP/\${EXTEN})"];
    };
  };

  cases = {
    baselineIsValid = {
      module = {};
      assertions = [];
      warnings = [];
    };

    danglingTransport = {
      module.services.asterisk.pjsip.endpoints."101".transport = "tcp";
      assertion = "[101] (type=endpoint) transport = tcp: no transport named `tcp`";
    };

    danglingAorFromLayerOne = {
      module.services.asterisk.settings."pjsip.conf"."endpoint:101".aors = lib.mkForce "nope";
      assertion = "aors = nope: no aor named `nope`";
    };

    danglingIdentifyEndpoint = {
      module.services.asterisk.settings."pjsip.conf".office-identify = {
        name = "office";
        type = "identify";
        endpoint = "office";
        match = ["10.0.0.1"];
      };
      assertion = "endpoint = office: no endpoint named `office`";
    };

    danglingRegistrationAuth = {
      module.services.asterisk.settings."pjsip.conf".reg = {
        type = "registration";
        server_uri = "sip:sip.example";
        client_uri = "sip:1@sip.example";
        outbound_auth = "missing";
      };
      assertion = "outbound_auth = missing: no auth named `missing`";
    };

    registrationEndpointWithoutLine = {
      module.services.asterisk.settings."pjsip.conf".reg = {
        type = "registration";
        server_uri = "sip:sip.example";
        client_uri = "sip:1@sip.example";
        endpoint = "101";
      };
      assertion = "registration(s) reg set `endpoint` without `line = yes`";
    };

    trunkWithoutLineIsValid = {
      module = {config, ...}: {
        services.asterisk.pjsip.trunks.provider = {
          host = "sip.example";
          username = "u";
          password = config.lib.asterisk.secret "/run/secrets/trunk";
          context = "internal";
          registration.line = false;
        };
      };
      assertions = [];
    };

    duplicateObject = {
      module.services.asterisk.settings."pjsip.conf".again = {
        name = "101";
        type = "endpoint";
        context = "internal";
        allow = ["ulaw"];
      };
      assertion = "more than once (same type and name):\n  endpoint 101";
    };

    missingEndpointContext = {
      module.services.asterisk.pjsip.endpoints."102" = {
        context = "nowhere";
        aor = null;
      };
      assertion = "[102] context = nowhere";
    };

    danglingInclude = {
      module.services.asterisk.dialplan.contexts.internal.includes = ["outbound"];
      assertion = "[internal] include => outbound";
    };

    danglingPredialSubroutine = {
      module = {config, ...}: {
        services.asterisk.dialplan.contexts.internal.extensions."100" = [
          (config.lib.asterisk.dialplan.app "Dial" [
            "PJSIP/101"
            20
            "b(announce^s^1)"
          ])
        ];
      };
      assertion = "pre-dial subroutines refer to contexts that are not defined:\n  [internal] announce";
    };

    includeWithTimeSpecIsResolved = {
      module.services.asterisk.dialplan.contexts = {
        internal.includes = ["daytime,09:00-17:00,mon-fri,*,*"];
        daytime.extensions.s = ["Answer()"];
      };
      assertions = [];
    };

    contextsFromExtraConfigAreKnown = {
      module.services.asterisk = {
        pjsip.endpoints."101".context = lib.mkForce "legacy";
        extraConfig."extensions.conf" = ''
          [legacy]
          exten => 1,1,Answer()
        '';
      };
      assertions = [];
    };

    includedFilesDisableContextChecks = {
      module.services.asterisk = {
        pjsip.endpoints."101".context = lib.mkForce "elsewhere";
        includes."extensions.conf" = ["extensions-local.conf"];
      };
      assertions = [];
    };

    tlsWithoutKeys = {
      module.services.asterisk.pjsip.transports.tls.protocol = "tls";
      assertion = "TLS transport(s) tls need a certificate and a private key";
    };

    rtpRangeInverted = {
      module.services.asterisk.rtp.portRange = {
        from = 20000;
        to = 10000;
      };
      assertion = "`from` (20000) must be lower than `to` (10000)";
    };

    chanSip = {
      module.services.asterisk.modules.load = ["chan_sip"];
      assertion = "chan_sip.so is not supported";
    };

    secretInStore = {
      module = {config, ...}: {
        services.asterisk.pjsip.endpoints."101".auth.password = lib.mkForce (
          config.lib.asterisk.secret "${builtins.storeDir}/0000000000000000000000000000000-pw"
        );
      };
      assertion = "is in the\nNix store";
    };

    invalidCredentialName = {
      module.services.asterisk.pjsip.endpoints."101".auth.password = lib.mkForce {
        _credential = "bad/name";
      };
      assertion = "invalid systemd credential name `bad/name`";
    };

    unsafeSecretPath = {
      module.services.asterisk.pjsip.endpoints."101".auth.password = lib.mkForce {
        _secret = "/run/secrets/with space";
      };
      assertion = "secret path `/run/secrets/with space` must be absolute";
    };

    secretInterpolatedIntoValue = {
      module = {config, ...}: {
        services.asterisk.settings."voicemail.conf".default."200" = "${config.lib.asterisk.secret "/run/secrets/vm-200"},Sales,sales@example.org";
      };
      assertions = [];
      warnings = [];
    };

    reservedCredentialName = {
      module.services.asterisk.credentials.secret-x = "/run/x";
      assertion = "invalid or reserved credential name `secret-x`";
    };

    managedDirectory = {
      module.services.asterisk.settings."asterisk.conf".directories.astetcdir =
        lib.mkForce "/etc/asterisk";
      assertion = "directories.astetcdir is managed by the module";
    };

    invalidFileName = {
      module.services.asterisk.settings."../escape.conf".x.a = 1;
      assertion = "invalid configuration file name `../escape.conf`";
    };

    extensionWithoutSteps = {
      module.services.asterisk.dialplan.contexts.internal.extensions."200" = [];
      assertion = "extensions without steps or hint: internal/200";
    };

    extensionNameWithComma = {
      module.services.asterisk.dialplan.contexts.internal.extensions."2,1" = ["Answer()"];
      assertion = "invalid extension name(s)";
    };

    reservedContextName = {
      module.services.asterisk.dialplan.contexts.globals.extensions.s = ["Answer()"];
      assertion = "`general` and `globals` are reserved";
    };

    trunkEndpointNameClash = {
      module = {config, ...}: {
        services.asterisk.pjsip.trunks."101" = {
          host = "sip.example";
          username = "u";
          password = config.lib.asterisk.secret "/run/secrets/trunk";
          context = "internal";
        };
      };
      assertion = "pjsip.trunks and pjsip.endpoints share the name(s) 101";
    };

    # nixpkgs' module is replaced: its options point to the new ones
    upstreamConfFilesRemoved = {
      module.services.asterisk.confFiles."extensions.conf" = "";
      assertion = "Use services.asterisk.settings.<file>";
    };

    ariWithoutHttp = {
      module = {config, ...}: {
        services.asterisk.ari = {
          enable = true;
          users.app.password = config.lib.asterisk.secret "/run/secrets/ari";
        };
      };
      assertion = "ari.enable requires services.asterisk.http.enable";
    };

    wssWithoutHttpTls = {
      module.services.asterisk = {
        http.enable = true;
        pjsip.transports.wss.protocol = "wss";
      };
      assertion = "a wss transport requires services.asterisk.http.tls.enable";
    };

    websocketWithoutHttp = {
      module.services.asterisk.pjsip.transports.ws.protocol = "ws";
      assertion = "WebSocket transports (ws, wss) require services.asterisk.http.enable";
    };

    httpTlsWithoutKey = {
      module.services.asterisk.http = {
        enable = true;
        tls.enable = true;
      };
      assertion = "http.tls needs certFile and keyFile";
    };

    voicemailNameWithComma = {
      module = {config, ...}: {
        services.asterisk.voicemail.mailboxes."101" = {
          pin = config.lib.asterisk.secret "/run/secrets/vm";
          fullName = "Doe, John";
        };
      };
      assertion = "names and e-mail addresses cannot contain commas (101@default)";
    };

    mwiForUndefinedMailbox = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          pjsip.endpoints."101".mailboxes = ["102@default"];
        };
      };
      assertion = "pjsip.endpoints.101.mailboxes: 102@default";
    };

    voicemailPlainPinWarns = {
      module.services.asterisk.voicemail.mailboxes."101".pin = "1234";
      assertions = [];
      warning = "voicemail.mailboxes.\"101@default\".pin is a plain string";
    };

    musicOnHoldFilesWithoutDirectory = {
      module.services.asterisk.musicOnHold.classes.office.sort = "alpha";
      assertion = "musicOnHold.classes.office: mode `files` needs a directory";
    };

    plainPasswordWarns = {
      module.services.asterisk.pjsip.endpoints."101".auth.password = lib.mkForce "hunter2";
      assertions = [];
      warning = ''settings."pjsip.conf"."auth:101".password is a plain string'';
    };

    sameKeyWarns = {
      module.services.asterisk.settings."extensions.conf".internal.same = ["n,Hangup()"];
      warning = "`same` keys in settings.\"extensions.conf\"";
    };

    newlineInValueThrows = {
      module.services.asterisk.pjsip.endpoints."101".callerId = "a\nb";
      throws = true;
    };

    invalidKeyThrows = {
      module.services.asterisk.settings."pjsip.conf"."endpoint:101"."bad key=" = "x";
      throws = true;
    };

    invalidProtocolThrows = {
      module.services.asterisk.pjsip.transports.udp.protocol = "sctp";
      throws = true;
    };

    nestedAttrsetValueThrows = {
      module.services.asterisk.settings."rtp.conf".general.rtpstart.nested = 1;
      throws = true;
    };
  };

  check = name: case: let
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
      ++ lib.optional (case.throws or false && !(throws config.services.asterisk.renderedFiles)) {
        expectedThrow = true;
      };
  in
    lib.optional (problems != []) {${name} = problems;};
in
  lib.concatLists (lib.mapAttrsToList check cases)
