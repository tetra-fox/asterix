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

  # a problem for each reference check (an object, a parent, an endpoint
  # context, an include) and one that no included file or dialplan hides
  everyReference = {
    services.asterisk = {
      pjsip.endpoints = {
        "101".settings.outbound_auth = "elsewhere";
        "102" = {
          context = "from-elsewhere";
          aor = null;
        };
      };
      settings."pjsip.conf" = {
        gate.inherits = ["elsewhere"];
        again = {
          name = "101";
          type = "endpoint";
        };
      };
      dialplan.contexts.internal.includes = ["from-elsewhere"];
    };
  };
  reported = {
    reference = "services.asterisk: pjsip.conf references objects that do not exist:\n  [101] (type=endpoint) outbound_auth = elsewhere: no auth named `elsewhere`\n";
    parent = "services.asterisk: pjsip.conf sections inherit from sections that are not rendered before them, so Asterisk would not load the file:\n  [gate](elsewhere)\n";
    duplicate = "services.asterisk: pjsip.conf defines these objects more than once (same type and name):\n  endpoint 101\n";
    context = "services.asterisk: PJSIP endpoints use dialplan contexts that are not defined:\n  [102] context = from-elsewhere\n";
    include = "services.asterisk: dialplan includes contexts that are not defined:\n  [internal] include => from-elsewhere\n";
  };
  withEveryReference = module: {
    imports = [everyReference];
    services.asterisk = module;
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

    # `early` is rendered before the template it inherits
    parentRenderedAfterChild = {
      module.services.asterisk.settings."pjsip.conf" = {
        early = {
          order = 0;
          inherits = ["late"];
        };
        late = {
          template = true;
          type = "endpoint";
          context = "internal";
        };
      };
      assertion = "not rendered before them, so Asterisk would not load the file:\n  [early](late)";
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

    everyReferenceIsChecked = {
      module = everyReference;
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    # included files can define any pjsip object: the pjsip reference checks
    # stop, the others go on
    includedPjsipFiles = {
      module = withEveryReference {includes."pjsip.conf" = ["pjsip-local.conf"];};
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    includedPjsipFilesInRawText = {
      module = withEveryReference {extraConfig."pjsip.conf" = ''#tryinclude "pjsip-local.conf"'';};
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    # so can other sorcery backends, however sorcery.conf is written
    sorceryMapping = {
      module = withEveryReference {settings."sorcery.conf".res_pjsip.auth = "astdb,auths";};
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    sorceryMappingByName = {
      module = withEveryReference {
        settings."sorcery.conf".mapping = {
          name = "res_pjsip";
          auth = "astdb,auths";
        };
      };
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    sorceryMappingInRawText = {
      module = withEveryReference {
        extraConfig."sorcery.conf" = ''
          [res_pjsip]
          auth = astdb,auths
        '';
      };
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
    };

    includedSorceryFiles = {
      module = withEveryReference {includes."sorcery.conf" = ["sorcery-local.conf"];};
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
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

    # an include ends its context at a | too, the old separator of the time
    includeOfContextWithPipe = {
      module.services.asterisk.dialplan.contexts = {
        internal.includes = ["a|b"];
        "a|b".extensions.s = ["Answer()"];
      };
      assertion = "[internal] include => a|b";
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

    # included files can define any context: the context checks stop, the
    # pjsip ones go on
    includedDialplanFiles = {
      module = withEveryReference {includes."extensions.conf" = ["extensions-local.conf"];};
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
      ];
    };

    # so can AEL and Lua dialplans, once their module is loaded to read them
    aelDialplan = {
      module = withEveryReference {
        extraConfig."extensions.ael" = "context from-elsewhere { 1 => Answer(); };";
        modules.load = [
          "res_ael_share"
          "pbx_ael"
        ];
      };
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
      ];
    };

    includedAelDialplan = {
      module = withEveryReference {
        includes."extensions.ael" = ["/var/lib/asterisk/extensions.ael"];
        modules.load = [
          "res_ael_share"
          "pbx_ael"
        ];
      };
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
      ];
    };

    luaDialplan = {
      module = withEveryReference {
        extraConfig."extensions.lua" = ''extensions = { ["from-elsewhere"] = {} }'';
        modules.load = ["pbx_lua"];
      };
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
      ];
    };

    # without pbx_ael, Asterisk never reads extensions.ael
    aelDialplanWithoutModule = {
      module = withEveryReference {extraConfig."extensions.ael" = "context from-elsewhere { 1 => Answer(); };";};
      assertions = [
        reported.reference
        reported.parent
        reported.duplicate
        reported.context
        reported.include
      ];
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

    # Asterisk moves an RTP port below 1024 up to 1024, and one above 65535
    # down to it, without a word
    rtpRangeBelow1024Throws = {
      module.services.asterisk.rtp.portRange.from = 1000;
      throws = true;
    };

    rtpRangeOutside1024To65535FromSettings = {
      module.services.asterisk.settings."rtp.conf".general = {
        rtpstart = 1000;
        rtpend = 70000;
      };
      assertion = "Asterisk takes ports from 1024 to 65535 and moves others into that range; `from` is 1000 and `to` 70000.";
    };

    chanSip = {
      module.services.asterisk.modules.load = ["chan_sip"];
      assertion = "chan_sip.so is not supported";
    };

    # Asterisk drops a module in noload without a message, and each of these
    # options does nothing without its module
    noloadOfNeededModules = {
      module = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
      in {
        services.asterisk = {
          voicemail.mailboxes."101".pin = secret "vm-101";
          queues.queues.support.members = ["PJSIP/101"];
          confbridge.bridges.board.maxMembers = 5;
          musicOnHold.classes.office.directory = "moh";
          features.featureMap = {
            parkcall = "#72";
            disconnect = "*0";
            automixmon = "*3";
          };
          cdr = {
            csv.enable = true;
            sqlite.enable = true;
          };
          cel.sqlite.enable = true;
          logger.channels.security = ["security"];
          http.enable = true;
          ari = {
            enable = true;
            users.app.password = secret "ari";
          };
          pjsip = {
            transports.ws.protocol = "ws";
            acls.lan.permit = ["10.0.0.0/8"];
            endpoints."101".mailboxes = ["101@default"];
            trunks.provider = {
              host = "203.0.113.5";
              username = "5551000";
              password = secret "trunk";
              context = "internal";
            };
          };
          modules.noload = [
            "app_voicemail.so"
            "app_queue"
            "app_confbridge.so"
            "res_musiconhold.so"
            "res_parking.so"
            "bridge_builtin_features.so"
            "app_mixmonitor.so"
            "cdr_csv.so"
            "cdr_sqlite3_custom.so"
            "cel_sqlite3_custom.so"
            "res_security_log.so"
            "res_ari.so"
            "res_pjsip_transport_websocket.so"
            "res_http_websocket.so"
            "pbx_config.so"
            "chan_pjsip.so"
            "res_pjsip_authenticator_digest.so"
            "res_pjsip_acl.so"
            "res_pjsip_mwi.so"
            "res_pjsip_mwi_body_generator.so"
            "res_pjsip_registrar.so"
            "res_pjsip_outbound_registration.so"
            "res_pjsip_outbound_authenticator_digest.so"
            "res_pjsip_endpoint_identifier_ip.so"
          ];
        };
      };
      assertions = [
        ''
          services.asterisk.modules.noload removes modules the configuration needs:
            res_pjsip_acl.so for acls in pjsip.conf
            res_pjsip_registrar.so for aors that accept registrations in pjsip.conf
            chan_pjsip.so for endpoints in pjsip.conf
            res_pjsip_authenticator_digest.so for endpoints with auth in pjsip.conf
            res_pjsip_mwi.so, res_pjsip_mwi_body_generator.so for endpoints with mailboxes in pjsip.conf
            res_pjsip_endpoint_identifier_ip.so for identify sections in pjsip.conf
            res_pjsip_outbound_authenticator_digest.so for outbound_auth in pjsip.conf
            res_pjsip_outbound_registration.so for registrations in pjsip.conf
            res_ari.so for services.asterisk.ari
            cdr_csv.so for services.asterisk.cdr.csv
            cdr_sqlite3_custom.so for services.asterisk.cdr.sqlite
            cel_sqlite3_custom.so for services.asterisk.cel.sqlite
            app_confbridge.so for services.asterisk.confbridge
            bridge_builtin_features.so, app_mixmonitor.so for services.asterisk.features.featureMap.automixmon
            bridge_builtin_features.so for services.asterisk.features.featureMap.disconnect
            res_parking.so for services.asterisk.features.featureMap.parkcall
            res_musiconhold.so for services.asterisk.musicOnHold.classes
            res_http_websocket.so, res_pjsip_transport_websocket.so for services.asterisk.pjsip.transports (ws, wss)
            app_queue.so for services.asterisk.queues.queues
            app_voicemail.so for services.asterisk.voicemail
            pbx_config.so for the dialplan in extensions.conf
            res_security_log.so for the security level in logger.conf
        ''
      ];
    };

    # the example of the option: no option needs it
    noloadOfUnneededModule = {
      module.services.asterisk.modules.noload = ["res_pjsip_messaging.so"];
      assertions = [];
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

    # a path lands in a LoadCredential= line of asterisk.service, where a line
    # break starts a line of its own and a backslash at the end joins the next
    # line to it
    credentialPathsBreakingUnit = {
      module.services.asterisk.pjsip.transports.tls = {
        protocol = "tls";
        tls = {
          certFile = "/var/lib/acme/pbx/cert.pem\\";
          keyFile = "/var/lib/acme/pbx/key.pem\nExecStartPre=/bin/false";
        };
      };
      assertion = "services.asterisk.credentials: paths cannot contain a line break or end with a backslash, which would change the lines of asterisk.service: pjsip-tls-cert, pjsip-tls-key.";
    };

    # systemd keeps a service's credentials in 1 MiB, where each takes a page
    # of 4 KiB at least: with the baseline's secret, 256 fit and 257 do not
    credentialsFillingTheirFilesystem = {
      module = {config, ...}: {
        services.asterisk = {
          credentials.tls-key = "/run/secrets/tls-key";
          pjsip.endpoints = lib.genAttrs (map toString (lib.range 1000 1254)) (extension: {
            context = "internal";
            auth.password = config.lib.asterisk.secret "/run/secrets/${extension}";
          });
        };
      };
      assertions = [
        "services.asterisk: asterisk.service would get 257 credentials, one for each secret file and each of services.asterisk.credentials, and systemd fits at most 256 in the 1 MiB it gives a service's credentials, each taking at least a page of 4 KiB; Asterisk would not start."
      ];
    };
    credentialsFillingTheirFilesystemOneLess = {
      module = {config, ...}: {
        services.asterisk.pjsip.endpoints = lib.genAttrs (map toString (lib.range 1000 1254)) (extension: {
          context = "internal";
          auth.password = config.lib.asterisk.secret "/run/secrets/${extension}";
        });
      };
      assertions = [];
      warnings = [];
    };

    # Asterisk forks into the background with -F, which the config check
    # cannot see, and systemd stops the service once its process has exited
    forkArgument = {
      module.services.asterisk.extraArguments = ["-vF"];
      assertion = "services.asterisk.extraArguments: with -F Asterisk forks into the background, and systemd stops the service once the process it started has exited.";
    };

    # Asterisk's getopt takes options and their values, and Asterisk never
    # reads the other words: -, -- and all after it
    extraArgumentsThatAreNotOptions = {
      module.services.asterisk.extraArguments = ["vvv" "-dL" "2" "-" "--" "-F"];
      assertions = [''services.asterisk.extraArguments: Asterisk ignores words that are not options or their values: "vvv", "-", "--", "-F".''];
    };

    # the unit's system call filter keeps Asterisk from changing its user, even
    # to the one it runs as, and Asterisk takes a group only when it starts as
    # root
    userAndGroup = {
      module.services.asterisk = {
        extraArguments = ["-vU" "asterisk" "-Gasterisk"];
        settings."asterisk.conf".options = {
          runuser = "asterisk";
          RunGroup = "asterisk";
        };
      };
      assertions = [''services.asterisk: asterisk.service runs Asterisk as the asterisk user and group, which Asterisk cannot switch: given a user it exits, since it cannot become another user and the unit's system call filter refuses it even its own, and it ignores a group unless it starts as root. Remove extraArguments -U, extraArguments -G, settings."asterisk.conf".options.RunGroup, settings."asterisk.conf".options.runuser.''];
    };

    # the firewall's rules name the interfaces
    firewallInterfaceNames = {
      module.services.asterisk.firewallInterfaces = [
        "lan"
        "lan\nreboot"
        "a/b"
        "enp5s0-long-name"
        "."
      ];
      assertion = ''services.asterisk.firewallInterfaces: Linux takes interface names of 1 to 15 bytes without /, : or whitespace: "lan\nreboot", "a/b", "enp5s0-long-name", ".".'';
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

    # Asterisk keeps the first 10 keys of a feature's sequence
    featureKeysLongerThan10 = {
      module.services.asterisk.features = {
        featureMap = {
          blindxfer = "#1234567890";
          atxfer = "*123456789";
        };
        applications = {
          monkeys = {
            dtmf = "*1234567890";
            app = "Playback";
            args = "tt-monkeys";
          };
          weasels = {
            dtmf = "*123456788";
            app = "Playback";
            args = "tt-weasels";
          };
        };
      };
      assertions = ["services.asterisk.features: key sequences longer than the 10 keys Asterisk keeps: featureMap.blindxfer, applications.monkeys.dtmf."];
    };

    # pbx_config reads a hint like a step, App(arguments), and keeps what
    # comes before its first ( unless a variable comes first
    # (pbx/pbx_config.c:1859-1866)
    hintWithParenthesis = {
      module.services.asterisk.dialplan.contexts.internal.hints = {
        "101" = "Custom:front(1)";
        "102" = "PJSIP/\${GLOBAL(PHONE)}";
      };
      assertions = ["services.asterisk.dialplan: hints that Asterisk cuts at their first ( unless a variable comes before it: internal/101."];
    };

    # manager.c skips a section called general in any case, which it reads as
    # its settings, so no such user can log in
    # their ports are only opened together with services.asterisk.openFirewall
    amiAndHttpOpenFirewallAlone = {
      module.services.asterisk = {
        ami = {
          enable = true;
          openFirewall = true;
        };
        http = {
          enable = true;
          openFirewall = true;
        };
      };
      warnings = [
        "services.asterisk.ami.openFirewall opens the AMI port only together with services.asterisk.openFirewall, which is off."
        "services.asterisk.http.openFirewall opens the HTTP ports only together with services.asterisk.openFirewall, which is off."
      ];
    };

    amiUserNamedGeneralInAnotherCase = {
      module = {config, ...}: {
        services.asterisk.ami = {
          enable = true;
          users = lib.genAttrs ["General" "monitor"] (_: {
            secret = config.lib.asterisk.secret "/run/secrets/ami";
          });
        };
      };
      assertion = "services.asterisk.ami.users: `general` is reserved, in any case: General.";
    };

    # AMI reads a line into 1024 bytes, so `Secret: `, the secret and the
    # line's CRLF have to fit; a secret's own length counts when the service
    # starts
    amiSecretsLongerThanALoginLine = {
      module = {config, ...}: {
        services.asterisk.ami = {
          enable = true;
          users = {
            dialer.secret = lib.strings.replicate 1014 "d";
            monitor.secret = lib.strings.replicate 1015 "m";
            vault.secret = "${lib.strings.replicate 1015 "v"}${config.lib.asterisk.secret "/run/secrets/ami"}";
          };
        };
      };
      assertion = "services.asterisk: AMI secrets longer than the 1014 bytes a Login can send, since AMI reads a line into 1024 bytes with `Secret: ` and the line end; use shorter ones: monitor, vault.";
    };

    # Asterisk takes AMI ports from 1024 up
    amiPortBelow1024Throws = {
      module.services.asterisk.ami = {
        enable = true;
        port = 1023;
      };
      throws = true;
    };

    reservedContextName = {
      module.services.asterisk.dialplan.contexts.globals.extensions.s = ["Answer()"];
      assertion = "`general` and `globals` are reserved";
    };

    # Asterisk takes a section called general or globals in any case for its
    # settings or its global variables: [General] is no context, and the lines
    # of [GLOBALS] become variables called exten and same
    reservedContextNameInAnotherCase = {
      module.services.asterisk.dialplan.contexts = {
        General.extensions.s = ["Answer()"];
        GLOBALS.extensions.s = ["Answer()"];
      };
      assertion = "services.asterisk.dialplan.contexts: `general` and `globals` are reserved, in any case; use dialplan.general and dialplan.globals: GLOBALS, General.";
    };

    endpointInGeneralSection = {
      module.services.asterisk.pjsip.endpoints."101".context = lib.mkForce "general";
      assertion = "[101] context = general";
    };

    # Asterisk keeps 79 bytes of a section name, which makes the long-x contexts
    # one; a long name of its own works, and so does a context's raw lines block
    contextsAlikeInTheirFirst79Bytes = let
      long = "long-" + lib.strings.replicate 74 "x";
    in {
      module.services.asterisk = {
        dialplan.contexts = {
          "${long}-a".extensions."1" = ["Answer()"];
          "${long}-b" = {
            extensions."2" = ["Answer()"];
            extraConfig = "exten => 4,1,Answer()";
          };
          "other-${long}".extensions."3" = ["Answer()"];
        };
        extraConfig."extensions.conf" = ''
          [${long}]
          exten => 5,1,Answer()
        '';
      };
      assertion = ''
        services.asterisk: dialplan contexts that Asterisk would merge, since it only keeps the first 79 bytes of a context's name:
          ${long}, ${long}-a, ${long}-b
      '';
    };

    # Goto takes a whole number for a priority and drops a leading + or -, and
    # Asterisk ends a label at its first ); a space or ( is kept
    unreachableLabels = {
      module.services.asterisk.dialplan.contexts.internal.extensions."100" =
        ["Answer()"]
        ++ map (label: {
          app = "NoOp";
          inherit label;
        }) ["3" " 12 " "a)b" "+x" "-1" "" " x" "a(b" "3a"];
      assertion = ''services.asterisk.dialplan: step labels that Goto() cannot reach (a label may not be empty, contain `,` or `)`, start with + or -, or be a whole number): internal/100: "3", " 12 ", "a)b", "+x", "-1", "".'';
    };

    # every record would fail to insert; cel_sqlite3_custom takes the CUT()
    # below for three values
    sqliteValuesUnlikeColumns = {
      module.services.asterisk = {
        cdr.sqlite.enable = true;
        cel = {
          enable = true;
          sqlite.enable = true;
        };
        settings."cdr_sqlite3_custom.conf".master.values = "'\${CDR(src)}', '\${CDR(dst)}'";
        settings."cel_sqlite3_custom.conf".master = {
          columns = "eventtype, exten";
          values = "'\${eventtype}', '\${CUT(CHANNEL(exten),-,1)}'";
        };
      };
      assertions = [
        ''
          services.asterisk: the number of values differs from the number of columns, so every record would fail to insert (cel_sqlite3_custom separates values at every comma, cdr_sqlite3_custom at commas outside (), [], "" and after \):
            cdr_sqlite3_custom.conf: columns 16, values 2
            cel_sqlite3_custom.conf: columns 2, values 4
        ''
      ];
    };

    sqliteValuesWithArguments = {
      module.services.asterisk = {
        cdr.sqlite.enable = true;
        settings."cdr_sqlite3_custom.conf".master = {
          columns = "src, dst";
          values = "'\${CDR(src)}', '\${CUT(CDR(dst),-,1)}'";
        };
      };
      assertions = [];
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

    # HTTP basic authentication carries 255 bytes of `user:password`; a crypt
    # hash is not what clients send, and a secret's own length counts when
    # the service starts
    ariPasswordsLongerThanBasicAuthentication = {
      module = {config, ...}: {
        services.asterisk = {
          http.enable = true;
          ari = {
            enable = true;
            users = {
              app.password = lib.strings.replicate 252 "a";
              b.password = lib.strings.replicate 253 "b";
              hashed.password = lib.strings.replicate 300 "h";
              vault.password = "${lib.strings.replicate 250 "v"}${config.lib.asterisk.secret "/run/secrets/ari"}";
            };
          };
          settings."ari.conf"."user:hashed".password_format = "crypt";
        };
      };
      assertion = ''
        services.asterisk: ARI passwords longer than HTTP basic authentication carries, 255 bytes of `user:password`; use shorter ones:
          app, at most 251 bytes
          vault, at most 249 bytes
      '';
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

    # VoiceMailMain ends a PIN at #, takes one that starts with * for a jump
    # to extension a, and keeps the - of a PIN that starts with one, after the
    # one the module writes; a * further on can be typed, and a secret's own
    # characters count when the service starts
    voicemailPinsNoPhoneCanType = {
      module = {config, ...}: {
        services.asterisk.voicemail.mailboxes = {
          "101".pin = "-1234";
          "102".pin = "*1234";
          "103".pin = "12#4";
          "104".pin = "1*2";
          "105".pin = "${config.lib.asterisk.secret "/run/secrets/vm-105"}#";
          "106".pin = "${config.lib.asterisk.secret "/run/secrets/vm-106"}*";
        };
      };
      assertion = "services.asterisk.voicemail.mailboxes: PINs cannot start with - or *, or contain #, which no phone can type into VoiceMailMain: 101@default, 102@default, 103@default, 105@default.";
    };

    # 79 bytes of a PIN with the `-` of a typed one, where \; is one byte and a
    # comment none; a secret's own length counts when the service starts
    voicemailPinLongerThan79Bytes = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes = {
            "101".pin = lib.strings.replicate 79 "1";
            "102".pin = "1;" + lib.strings.replicate 76 "1";
          };
          settings."voicemail.conf".sales = {
            "200" = "${lib.strings.replicate 70 "2"}${config.lib.asterisk.secret "/run/secrets/vm-200"}${lib.strings.replicate 10 "2"},Sales";
            "201" = "${config.lib.asterisk.secret "/run/secrets/vm-201"}${lib.strings.replicate 79 "2"},Sales";
          };
          extraConfig."voicemail.conf" = ''
            [support]
            300 => ${lib.strings.replicate 80 "3"} ; the PIN
            301 => ${lib.strings.replicate 79 "3"} ; the PIN
          '';
        };
      };
      assertion = ''
        services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
          PIN of 101@default, to 79 bytes
          PIN of 200@sales, to 79 bytes
          PIN of 300@support, to 79 bytes
      '';
    };

    # as long as the PIN: a mailbox's name and pager address, from typed and
    # layer-1 mailboxes, and the sender address; the sender name has 99 bytes
    voicemailValuesLongerThanAsteriskKeeps = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail = {
            mailboxes = {
              "101" = {
                pin = config.lib.asterisk.secret "/run/secrets/vm-101";
                fullName = lib.strings.replicate 80 "n";
                pagerEmail = lib.strings.replicate 68 "p" + "@example.org";
              };
              "102" = {
                pin = config.lib.asterisk.secret "/run/secrets/vm-102";
                fullName = lib.strings.replicate 79 "n";
                pagerEmail = lib.strings.replicate 67 "p" + "@example.org";
              };
            };
            email = {
              command = "/run/current-system/sw/bin/msmtp -t";
              fromAddress = lib.strings.replicate 68 "f" + "@example.org";
              fromName = lib.strings.replicate 100 "s";
            };
          };
          settings."voicemail.conf".sales."200" = "1234,${lib.strings.replicate 80 "n"}";
        };
      };
      assertion = ''
        services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
          [general] fromstring, to 99 bytes
          [general] serveremail, to 79 bytes
          name of 101@default, to 79 bytes
          pager address of 101@default, to 79 bytes
          name of 200@sales, to 79 bytes
      '';
    };

    # app_voicemail ignores a mailbox whose number starts with *, which
    # jumps to extension a in VoiceMailMain
    voicemailMailboxStartingWithStar = {
      module.services.asterisk.voicemail.mailboxes."*42".pin = "1234";
      assertion = "mailbox numbers may only contain letters, digits and _*#+-, and not start with *";
    };

    # Asterisk reads a line of voicemail.conf that starts with # as a
    # directive
    voicemailMailboxStartingWithHash = {
      module.services.asterisk.voicemail.mailboxes."#42".pin = "1234";
      assertion = "and not start with * or #: #42@default.";
    };

    # app_voicemail splits the options at | and each at its first =
    voicemailOptionWithPipe = {
      module = {config, ...}: {
        services.asterisk.voicemail.mailboxes = {
          "101" = {
            pin = config.lib.asterisk.secret "/run/secrets/vm-101";
            options.emailsubject = "New message | office";
          };
          "102" = {
            pin = config.lib.asterisk.secret "/run/secrets/vm-102";
            options."a=b" = true;
          };
        };
      };
      assertion = "option names cannot contain | or =, nor their values | (101@default, 102@default)";
    };

    # the options of a mailbox and the [general] keys that app_voicemail
    # copies into buffers of fixed size, whatever the case of their names: a
    # value as long as the buffer keeps is not reported
    voicemailOptionsLongerThanAsteriskKeeps = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail = {
            mailboxes."101" = {
              pin = config.lib.asterisk.secret "/run/secrets/vm-101";
              options = {
                tz = lib.strings.replicate 79 "t";
                language = lib.strings.replicate 40 "l";
                attachfmt = lib.strings.replicate 20 "a";
                fromstring = lib.strings.replicate 99 "f";
                Serveremail = lib.strings.replicate 80 "s";
              };
            };
            settings = {
              pagerfromstring = lib.strings.replicate 100 "p";
              charset = lib.strings.replicate 32 "c";
              locale = lib.strings.replicate 19 "l";
            };
          };
          settings."voicemail.conf".sales."200" = "1234,Sales,,,callback=${lib.strings.replicate 80 "c"}|exitcontext=sales";
        };
      };
      assertion = ''
        services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
          [general] charset, to 31 bytes
          [general] pagerfromstring, to 99 bytes
          option Serveremail of 101@default, to 79 bytes
          option attachfmt of 101@default, to 19 bytes
          option language of 101@default, to 39 bytes
          option callback of 200@sales, to 79 bytes
      '';
    };

    # app_voicemail keeps 63 bytes of each context of cidinternalcontexts,
    # after the blanks before it, and reads the first 10, where a comma at the
    # end starts none
    voicemailInternalContextsLongerThanAsteriskKeeps = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
          settings.cidinternalcontexts = "${lib.strings.replicate 63 "a"},\t${lib.strings.replicate 64 "b"},";
        };
      };
      assertions = [
        ''
          services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
            context 2 of [general] cidinternalcontexts, to 63 bytes
        ''
      ];
    };

    voicemailElevenInternalContexts = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
          settings.cidinternalcontexts = "a,b,c,d,e,f,g,h,,j,k,";
        };
      };
      assertions = ["services.asterisk.voicemail: Asterisk reads the first 10 contexts of cidinternalcontexts and ignores the rest: k."];
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

    # app_voicemail takes general and zonemessages in any case, and the
    # section aliasescontext names, for no voicemail context, so it never
    # loads a mailbox there
    voicemailReservedContextsInAnyCase = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes = {
            "101@General".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
            "102@zoneMessages".pin = config.lib.asterisk.secret "/run/secrets/vm-102";
            "103@MyAliases".pin = config.lib.asterisk.secret "/run/secrets/vm-103";
            "104@sales".pin = config.lib.asterisk.secret "/run/secrets/vm-104";
          };
          settings.aliasescontext = "myaliases";
        };
      };
      assertions = ["services.asterisk.voicemail.mailboxes: `general`, `zonemessages` and the context aliasescontext names are reserved, in any case: 101@General, 102@zoneMessages, 103@MyAliases."];
    };

    # app_voicemail sends a mailbox's MWI to its aliases too, while a mailbox
    # named in another case gets none
    mwiForAliasAndMailboxInAnotherCase = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail = {
            mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
            settings.aliasescontext = "myaliases";
          };
          settings."voicemail.conf".MyAliases."1234@devices" = "101@default";
          pjsip.endpoints."101".mailboxes = [
            "1234@devices"
            "101@Default"
          ];
        };
      };
      assertions = [
        ''
          services.asterisk: PJSIP endpoints reference voicemail boxes that are not defined:
            pjsip.endpoints.101.mailboxes: 101@Default
        ''
      ];
    };

    # app_voicemail sends a mailbox's MWI as box@context and Asterisk compares
    # the names exactly, so a mailbox named without its context gets none
    mwiForMailboxWithoutContext = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes = {
            "101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
            "200@sales".pin = config.lib.asterisk.secret "/run/secrets/vm-200";
          };
          pjsip.endpoints."101".mailboxes = [
            "101"
            "200"
            "200@sales"
            "101@default@x"
          ];
        };
      };
      assertions = [
        ''
          services.asterisk: PJSIP endpoints name voicemail boxes without their context, and Asterisk sends a mailbox's MWI only as box@context:
            pjsip.endpoints.101.mailboxes: 101, write 101@default
            pjsip.endpoints.101.mailboxes: 200, write 200@sales
        ''
        ''
          services.asterisk: PJSIP endpoints reference voicemail boxes that are not defined:
            pjsip.endpoints.101.mailboxes: 101@default@x
        ''
      ];
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

    # the mailboxes of voicemail.conf's raw text count by name
    mwiForMailboxInExtraConfig = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          pjsip.endpoints."101".mailboxes = [
            "200@sales"
            "201@sales"
          ];
          extraConfig."voicemail.conf" = ''
            [sales]
            200 => 1234,Sales ; the shop
          '';
        };
      };
      assertions = [
        ''
          services.asterisk: PJSIP endpoints reference voicemail boxes that are not defined:
            pjsip.endpoints.101.mailboxes: 201@sales
        ''
      ];
    };

    # an included file can define any mailbox
    mwiForMailboxInIncludedFile = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          pjsip.endpoints."101".mailboxes = ["200@sales"];
          includes."voicemail.conf" = ["/var/lib/asterisk/voicemail-local.conf"];
        };
      };
      assertions = [];
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

    # only user profiles have a music on hold class: app_confbridge declined
    # to load a bridge profile with one
    confbridgeBridgeMusicOnHoldClass = {
      module.services.asterisk.confbridge.bridges.board.musicOnHoldClass = "default";
      assertion = "Set services.asterisk.confbridge.users.<name>.musicOnHoldClass instead.";
    };

    # the store holds only their placeholders
    secretsInterpolatedIntoStringsDoNotWarn = {
      module = {config, ...}: let
        inherit (config.lib.asterisk) secret credential;
      in {
        services.asterisk = {
          pjsip.endpoints."101".auth.password = lib.mkForce "${secret "/run/secrets/101"}${credential "pepper"}";
          voicemail.mailboxes."101".pin = "${secret "/run/secrets/vm"}";
        };
      };
      assertions = [];
      warnings = [];
    };

    # Asterisk skips a line of more than 8190 bytes; a secret counts when the
    # service starts, and AEL and Lua have parsers of their own
    lineLongerThan8190Bytes = {
      module = {config, ...}: {
        services.asterisk = {
          settings."long.conf".s = {
            a = lib.strings.replicate 8187 "x";
            b = lib.strings.replicate 8186 "x";
            c = "${config.lib.asterisk.secret "/run/secrets/c"}${lib.strings.replicate 8186 "x"}";
          };
          extraConfig."extensions.lua" = ''t = "${lib.strings.replicate 8200 "x"}"'';
        };
      };
      assertions = [
        ''
          services.asterisk: lines longer than 8190 bytes, which Asterisk skips:
            long.conf, line 4: a = xxxxxxxxxxxxxxxxxxxxxxxxxxxx...
        ''
      ];
    };

    sameKeyWarns = {
      module.services.asterisk.settings."extensions.conf".internal.same = ["n,Hangup()"];
      warning = "`same` keys in settings.\"extensions.conf\"";
    };

    # Asterisk splits a callerid into a name and a number and keeps 79 bytes
    # of each: here a name of 79 bytes, where each of these characters takes
    # 3, a name of 81, a name whose backslashes Asterisk drops, a number that
    # Asterisk shrinks to 79 digits, and from settings a name without quotes
    # and a number alone of 80 digits
    callerIdLongerThanAsteriskKeeps = let
      mountains = n: lib.concatStrings (lib.replicate n (builtins.fromJSON ''"\u5c71"''));
      digits = n: lib.strings.replicate n "1";
    in {
      module = {config, ...}: {
        services.asterisk = {
          pjsip = {
            endpoints = {
              "101".callerId = ''"${mountains 26}!" <101>'';
              "102" = {
                context = "internal";
                callerId = ''"${mountains 27}" <102>'';
              };
              "103" = {
                context = "internal";
                callerId = ''"${lib.strings.replicate 40 "\\\""}" <103>'';
              };
            };
            trunks.provider = {
              host = "203.0.113.5";
              username = "5551000";
              password = config.lib.asterisk.secret "/run/secrets/trunk";
              context = "internal";
              callerId = "Office <(${digits 79}) - >";
            };
          };
          settings."pjsip.conf" = {
            gate = {
              type = "endpoint";
              context = "internal";
              callerid = "${lib.strings.replicate 80 "n"} <104>";
            };
            door = {
              type = "endpoint";
              context = "internal";
              callerid = "${digits 80}";
            };
          };
        };
      };
      assertions = [
        ''
          services.asterisk: PJSIP endpoints with a caller ID longer than the 79 bytes of name and of number Asterisk keeps:
            [door] number of 80 bytes
            [102] name of 81 bytes
            [gate] name of 80 bytes
        ''
      ];
    };

    # Asterisk hears inband DTMF in ulaw and alaw calls only, and the default
    # codecs put g722 first
    inbandDtmfWithTheDefaultCodecsWarns = {
      module.services.asterisk.pjsip.endpoints."101".dtmfMode = "inband";
      assertions = [];
      warning = "dtmf_mode = inband lose the keys of calls in the other codecs they allow:\n  [101] g722";
    };

    inbandDtmfWithUlawAndAlawDoesNotWarn = {
      module.services.asterisk.pjsip.endpoints."101" = {
        dtmfMode = "inband";
        allow = [
          "ulaw"
          "alaw"
        ];
      };
      assertions = [];
      warnings = [];
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

    # queues.conf keeps the first 79 bytes of a section's name, while Queue()
    # looks for the whole name
    queueNameLongerThan79Bytes = {
      module.services.asterisk.queues.queues = {
        ${lib.strings.replicate 80 "q"}.members = ["PJSIP/101"];
        ${lib.strings.replicate 79 "r"}.members = ["PJSIP/101"];
      };
      assertion = "services.asterisk.queues.queues: names longer than 79 bytes, which Asterisk cuts, so Queue() never finds them: ${lib.strings.replicate 80 "q"}.";
    };

    # app_queue reads a section called general in any case as its settings
    queueNamedGeneralInAnotherCase = {
      module.services.asterisk.queues.queues.General.members = ["PJSIP/101"];
      assertion = "services.asterisk.queues.queues: `general` is reserved, in any case: General.";
    };

    # Asterisk waits its default of 5 seconds instead
    queueRetryZeroThrows = {
      module.services.asterisk.queues.queues.support.retry = 0;
      throws = true;
    };

    # values Asterisk ignores without a word, outside the closed sets it knows
    amiClassUnknownThrows = {
      module = {config, ...}: {
        services.asterisk.ami = {
          enable = true;
          users.monitor = {
            secret = config.lib.asterisk.secret "/run/secrets/ami";
            read = ["System"];
          };
        };
      };
      throws = true;
    };
    logLevelUnknownThrows = {
      module.services.asterisk.logger.channels.messages = ["notice" "warnings"];
      throws = true;
    };
    confbridgeMenuActionUnknownThrows = {
      module.services.asterisk.confbridge.menus.admin_menu."*1" = "toggle_mute,kick_last";
      throws = true;
    };
    featureKeysUnknownThrows = {
      module.services.asterisk.features.featureMap.blindxfer = "#x";
      throws = true;
    };
    applicationKeysUnknownThrows = {
      module.services.asterisk.features.applications.monkeys = {
        dtmf = "*e";
        app = "Playback";
        args = "tt-monkeys";
      };
      throws = true;
    };
    hintDeviceOrPresenceUnknown = {
      module.services.asterisk.dialplan.contexts.internal.hints = {
        "101" = "SIP/101";
        "102" = "PJSIP/102,Presence:102";
        "103" = "queue:support_avail";
        "104" = "PJSIP/104&Custom:dnd104";
      };
      assertion = "services.asterisk.dialplan: hints with a device Asterisk has no state for, which it takes as invalid without a word: internal/101 (SIP/101), internal/102 (PJSIP/102,Presence:102), internal/103 (queue:support_avail). Write devices joined by &";
    };
    # Asterisk reads 0.5 as 0, which is no limit
    maxCallsNotAWholeNumber = {
      module.services.asterisk.settings."asterisk.conf".options.maxcalls = 0.5;
      assertions = [''services.asterisk: settings."asterisk.conf".options.maxcalls takes a whole number of calls, or 0 for no limit: Asterisk reads only the digits a value starts with, so 0.5 means no limit.''];
    };

    # app_queue ranks a member by its penalty times 1000000 in an int, which
    # overflows from 2147 on
    queuePenaltyAbove2146Throws = {
      module.services.asterisk.queues.queues.support.members = [
        {
          interface = "PJSIP/101";
          penalty = 2147;
        }
      ];
      throws = true;
    };
  };
in {
  run = checkCases base;
  tests = cases;
}
