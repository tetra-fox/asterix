# Invalid configurations must fail evaluation with a clear message. The
# result is the list of cases that did not behave as expected (see
# checkCases in eval-lib.nix).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) checkCases;

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

    # sections of the raw text count, by name only
    authInExtraConfig = {
      module.services.asterisk = {
        pjsip.endpoints."101".settings.outbound_auth = "shared";
        extraConfig."pjsip.conf" = ''
          [shared]
          type = auth
          username = x
          password = y
        '';
      };
      assertions = [];
    };

    danglingRefBesideExtraConfig = {
      module.services.asterisk = {
        pjsip.endpoints."101".settings.outbound_auth = "nope";
        extraConfig."pjsip.conf" = ''
          [shared]
          type = auth
        '';
      };
      assertion = "outbound_auth = nope: no auth named `nope`";
    };

    # the type and keys a section inherits count
    endpointFromTemplate = {
      module.services.asterisk.settings."pjsip.conf" = {
        phone = {
          template = true;
          type = "endpoint";
          context = "internal";
        };
        gate = {
          inherits = ["phone"];
          aors = "gate";
        };
        "aor:gate" = {
          name = "gate";
          type = "aor";
          contact = "sip:10.0.0.5";
        };
        "identify:gate" = {
          name = "gate";
          type = "identify";
          endpoint = "gate";
          match = ["10.0.0.5"];
        };
      };
      assertions = [];
    };

    danglingRefFromTemplate = {
      module.services.asterisk.settings."pjsip.conf" = {
        phone = {
          template = true;
          type = "endpoint";
          context = "internal";
          outbound_auth = "missing";
        };
        gate.inherits = ["phone"];
      };
      assertion = "[gate] (type=endpoint) outbound_auth = missing: no auth named `missing`";
    };

    registrationLineFromTemplate = {
      module.services.asterisk.settings."pjsip.conf" = {
        registration = {
          template = true;
          type = "registration";
          line = true;
        };
        reg = {
          inherits = ["registration"];
          server_uri = "sip:sip.example";
          client_uri = "sip:1@sip.example";
          endpoint = "101";
        };
      };
      assertions = [];
    };

    # the raw text comes after every generated section
    parentInExtraConfig = {
      module.services.asterisk = {
        settings."pjsip.conf".gate.inherits = ["raw-phone"];
        extraConfig."pjsip.conf" = ''
          [raw-phone](!)
          type = endpoint
        '';
      };
      assertion = "[gate](raw-phone)";
    };

    includedFilesDisableReferenceChecks = {
      module.services.asterisk = {
        pjsip.endpoints."101".settings.outbound_auth = "elsewhere";
        includes."pjsip.conf" = ["pjsip-local.conf"];
      };
      assertions = [];
    };

    sorceryBackendsDisableReferenceChecks = {
      module.services.asterisk = {
        pjsip.endpoints."101".settings.outbound_auth = "elsewhere";
        settings."sorcery.conf".res_pjsip.auth = "astdb,auths";
      };
      assertions = [];
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

    registrationLineAsInteger = {
      module.services.asterisk.settings."pjsip.conf".reg = {
        type = "registration";
        server_uri = "sip:sip.example";
        client_uri = "sip:1@sip.example";
        endpoint = "101";
        line = 1;
      };
      assertions = [];
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

    aelDisablesContextChecks = {
      module.services.asterisk = {
        dialplan.contexts.internal.includes = ["from-ael"];
        extraConfig."extensions.ael" = "context from-ael { 1 => Answer(); };";
      };
      assertions = [];
    };

    # res_parking creates the contexts of its parking lots at runtime
    includeOfParkingLot = {
      module.services.asterisk = {
        modules.load = ["res_parking"];
        settings."res_parking.conf".sales.context = "sales-parking";
        dialplan.contexts.internal.includes = [
          "parkedcalls"
          "sales-parking"
        ];
      };
      assertions = [];
    };

    includeOfParkingLotWithoutModule = {
      module.services.asterisk.dialplan.contexts.internal.includes = ["parkedcalls"];
      assertion = "[internal] include => parkedcalls";
    };

    renamedDefaultParkingLot = {
      module.services.asterisk = {
        modules.load = ["res_parking.so"];
        settings."res_parking.conf".default.context = "parking";
        dialplan.contexts.internal.includes = ["parkedcalls"];
      };
      assertion = "[internal] include => parkedcalls";
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

    rtpRangeFromSettings = {
      module.services.asterisk.settings."rtp.conf".general = {
        rtpstart = 10000;
        rtpend = 10000;
      };
      assertion = "`from` (10000) must be lower than `to` (10000)";
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

    voicemailPinWithComma = {
      module.services.asterisk.voicemail.mailboxes."101".pin = "12,34";
      assertion = "PINs, names and e-mail addresses cannot contain commas (101@default)";
    };

    voicemailEmailWithoutCommand = {
      module = {config, ...}: {
        services.asterisk.voicemail.mailboxes."101" = {
          pin = config.lib.asterisk.secret "/run/secrets/vm";
          email = "alice@example.org";
        };
      };
      assertion = "mailboxes with an e-mail address (101@default) need voicemail.email.command";
    };

    voicemailEmailWithCommand = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101" = {
            pin = config.lib.asterisk.secret "/run/secrets/vm";
            email = "alice@example.org";
          };
          email.command = "/run/current-system/sw/bin/msmtp -t";
        };
      };
      assertions = [];
    };

    # app_voicemail keeps the first 159 characters of the command
    voicemailLongestEmailCommand = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          email.command = "/run/current-system/sw/bin/msmtp -t ${lib.fixedWidthString 123 "x" ""}";
        };
      };
      assertions = [];
    };

    voicemailEmailCommandTooLong = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          email.command = "/run/current-system/sw/bin/msmtp -t ${lib.fixedWidthString 124 "x" ""}";
        };
      };
      assertion = "Asterisk cuts the e-mail command (mailcmd) after 159 characters, this one has 160";
    };

    voicemailElevenFormats = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          format = ["wav49" "wav" "wav16" "gsm" "ulaw" "alaw" "g722" "au" "sln" "sln16" "sln48"];
        };
      };
      assertion = "Asterisk records at most 10 formats and ignores the rest";
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

    provisioningMoved = {
      module.services.asterisk.provisioning.listenAddress = "10.0.20.10";
      assertion = "Phone provisioning moved to pbx.phones, in nixosModules.pbx.";
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

    confbridgePlainPinWarns = {
      module.services.asterisk.confbridge.users.guest.pin = "1234";
      assertions = [];
      warning = ''settings."confbridge.conf"."user:guest".pin is a plain string'';
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

    # Asterisk waits its default of 5 seconds instead
    queueRetryZeroThrows = {
      module.services.asterisk.queues.queues.support.retry = 0;
      throws = true;
    };
  };
in {
  run = checkCases base;
  tests = cases;
}
