# Invalid configurations must fail evaluation with a clear message. The cases
# cover the checks whose logic can break unnoticed: values parsed as Asterisk
# parses them, references and includes, byte counts, and the configurations
# they must let through. The result is the list of cases that did not behave
# as expected (see checkCases in eval-lib.nix).
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
  # context, an include) and one that no included file or dialplan hides; the
  # endpoints are open, since the duplicate of 101 and 102 have no auth
  everyReference = {
    services.asterisk = {
      pjsip.endpoints = {
        "101" = {
          open = true;
          settings.outbound_auth = "elsewhere";
        };
        "102" = {
          context = "from-elsewhere";
          aor = null;
          open = true;
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

    # the type and keys a section inherits count: gate is an endpoint with an
    # aor and an identify, and reg a registration with line = yes
    danglingRefFromTemplate = {
      module.services.asterisk.settings."pjsip.conf" = {
        phone = {
          template = true;
          type = "endpoint";
          context = "internal";
          outbound_auth = "missing";
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
      assertions = [
        ''
          services.asterisk: pjsip.conf references objects that do not exist:
            [gate] (type=endpoint) outbound_auth = missing: no auth named `missing`
        ''
      ];
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

    # so can other sorcery backends
    sorceryMapping = {
      module = withEveryReference {settings."sorcery.conf".res_pjsip.auth = "astdb,auths";};
      assertions = [
        reported.duplicate
        reported.context
        reported.include
      ];
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

    # a lookup skips a context named, but for case, like one it searched
    # already: through an include of an include, and through two includes of
    # one context, one of them timed (main/pbx.c:2527-2531); sales and Sales
    # are each searched from contexts that reach only one of them
    includeChainsReachContextsAlikeButForCase = {
      module.services.asterisk.dialplan.contexts = {
        internal.includes = ["phones" "sales"];
        phones.includes = ["Phones"];
        Phones.extensions."200" = ["Answer()"];
        lobby.includes = ["front" "Front,09:00-17:00,mon-fri,*,*" "Sales"];
        front.extensions."201" = ["Answer()"];
        Front.extensions."202" = ["Answer()"];
        sales.extensions."203" = ["Answer()"];
        Sales.extensions."204" = ["Answer()"];
      };
      assertions = ["services.asterisk.dialplan: include chains reach contexts named alike but for case, and Asterisk searches only the first of the two it reaches, skipping the other without a word: Front and front (from lobby), Phones and phones (from internal). Rename one context of each pair."];
    };

    # an include ends its context at a | too, the old separator of the time
    includeOfContextWithPipe = {
      module.services.asterisk.dialplan.contexts = {
        internal.includes = ["a|b"];
        "a|b".extensions.s = ["Answer()"];
      };
      assertion = "[internal] include => a|b";
    };

    # an AEL dialplan, with pbx_ael loaded to read it, can define any context:
    # the context checks stop, the pjsip ones go on
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

    renamedDefaultParkingLot = {
      module.services.asterisk = {
        modules.load = ["res_parking.so"];
        settings."res_parking.conf".default.context = "parking";
        dialplan.contexts.internal.includes = ["parkedcalls"];
      };
      assertion = "[internal] include => parkedcalls";
    };

    # against the system's CA bundle, any client certificate a public CA
    # signed passes
    verifyClientWithoutCaList = {
      module.services.asterisk.pjsip.transports.tls = {
        protocol = "tls";
        tls = {
          certFile = "/var/lib/acme/pbx/cert.pem";
          keyFile = "/var/lib/acme/pbx/key.pem";
          verifyClient = true;
        };
      };
      assertions = ["services.asterisk: TLS transport(s) tls verify clients against the system's CA bundle, which admits any client whose certificate a public CA signed. Set pjsip.transports.<name>.tls.caListFile to the CA that signs the phones' certificates."];
    };

    # Asterisk takes every request of an endpoint without auth as
    # authenticated, and finds one without identify by the user in From:
    # 102 to 106 let anyone register or call, also without an aor that takes
    # registrations; the others have a password or an identify, or are open on
    # purpose
    endpointsAnyoneCanUse = {
      module = {config, ...}: {
        services.asterisk = {
          pjsip.endpoints = {
            "102".context = "internal";
            "103" = {
              context = "internal";
              aor = null;
              settings.aors = "shared";
            };
            "104" = {
              context = "internal";
              aor = null;
            };
            "105" = {
              context = "internal";
              aor.maxContacts = 0;
            };
            "106" = {
              context = "internal";
              aor.settings.max_contacts = 0;
            };
            "107" = {
              context = "internal";
              settings.auth = "shared";
            };
            "108" = {
              context = "internal";
              identify.match = ["10.0.0.8"];
            };
            "109" = {
              context = "internal";
              open = true;
            };
          };
          settings."pjsip.conf" = {
            "aor:shared" = {
              name = "shared";
              type = "aor";
              max_contacts = 2;
            };
            "auth:shared" = {
              name = "shared";
              type = "auth";
              username = "107";
              password = config.lib.asterisk.secret "/run/secrets/107";
            };
          };
        };
      };
      assertions = ["services.asterisk: PJSIP endpoint(s) 102, 103, 104, 105, 106 have neither auth nor identify, so anyone who reaches the SIP port can register as them, and call from their context by naming them in From. Give each a password (pjsip.endpoints.<name>.auth.password) or an identify for a device known by its address, or set open = true where anyone may use them on purpose."];
    };

    # an identify keeps others out of an endpoint without auth only through an
    # ACL, which the module writes from typed addresses alone: 102 lists a host
    # name and 103 has an identify of settings, while 104 and 105 keep others
    # out through their settings and 106 is open on purpose
    endpointsIdentifiedFromAnywhere = {
      module.services.asterisk = {
        pjsip.endpoints = {
          "102" = {
            context = "internal";
            identify.match = ["10.0.0.2" "gate.example.org"];
          };
          "103" = {
            context = "internal";
            aor.maxContacts = 0;
          };
          "104" = {
            context = "internal";
            aor.maxContacts = 0;
            settings.identify_by = "ip";
          };
          "105" = {
            context = "internal";
            settings = {
              deny = "0.0.0.0/0.0.0.0";
              permit = "10.0.0.5";
            };
          };
          "106" = {
            context = "internal";
            identify.match = ["gate.example.org"];
            open = true;
          };
        };
        settings."pjsip.conf" = lib.genAttrs ["103" "104" "105"] (name: {
          inherit name;
          type = "identify";
          endpoint = name;
          match = "10.0.0.${lib.substring 2 1 name}";
        });
      };
      assertions = ["services.asterisk: PJSIP endpoint(s) 102, 103 have no auth, and Asterisk takes a request whose From names them from any address unless an ACL keeps others out. The module writes that ACL from the addresses in pjsip.endpoints.<name>.identify.match, which it cannot do for a host name, and not from identify sections of settings. List the addresses there, give each a password (pjsip.endpoints.<name>.auth.password), set deny and permit in its settings, or identify_by = ip if it never registers, or set open = true where anyone may use them on purpose."];
    };

    # a family's wildcard address takes the port on its other addresses, and
    # freeform transports count with their protocol in any case
    tcpListenerUnderAWildcard = {
      module.services.asterisk = {
        pjsip.transports = {
          udp.tcp = false;
          lan = {
            address = "10.0.20.10";
            port = 5070;
          };
          v6.address = "2001:db8::10";
        };
        settings."pjsip.conf" = {
          stream = {
            type = "transport";
            protocol = "TCP";
            bind = "0.0.0.0:5070";
          };
          stream6 = {
            type = "transport";
            protocol = "tcp";
            bind = "[::]";
          };
        };
      };
      assertions = [
        ''
          services.asterisk: a udp transport's TCP listener (pjsip.transports.<name>.tcp) and another transport would listen on the same TCP port, which only one of them gets:
            lan-tcp (10.0.20.10:5070) and stream (tcp, 0.0.0.0:5070): set pjsip.transports.lan.tcp = false to keep stream, or remove stream to let lan-tcp take TCP there with the settings of lan
            v6-tcp ([2001:db8::10]:5060) and stream6 (tcp, [::]:5060): set pjsip.transports.v6.tcp = false to keep stream6, or remove stream6 to let v6-tcp take TCP there with the settings of v6
        ''
      ];
    };

    # another family, another port or another address
    tcpListenerBesideTcpTransports = {
      module.services.asterisk.pjsip.transports = {
        tcp6 = {
          protocol = "tcp";
          address = "::";
        };
        tcp = {
          protocol = "tcp";
          port = 5070;
        };
        lan = {
          address = "10.0.20.10";
          port = 5080;
        };
        lan2 = {
          protocol = "tcp";
          address = "10.0.20.11";
          port = 5080;
        };
      };
      assertions = [];
    };

    # Asterisk drops a module in noload without a message, and without
    # res_pjsip_authenticator_digest it takes every request as authenticated
    noloadOfNeededModule = {
      module.services.asterisk.modules.noload = ["res_pjsip_authenticator_digest.so"];
      assertions = [
        ''
          services.asterisk.modules.noload removes modules the configuration needs:
            res_pjsip_authenticator_digest.so for endpoints with auth in pjsip.conf
        ''
      ];
    };

    secretInStore = {
      module = {config, ...}: {
        services.asterisk.pjsip.endpoints."101".auth.password = lib.mkForce (
          config.lib.asterisk.secret "${builtins.storeDir}/0000000000000000000000000000000-pw"
        );
      };
      assertion = "is in the\nNix store";
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

    # Asterisk's getopt takes options and their values, and Asterisk never
    # reads the other words: -, -- and all after it. With -F Asterisk forks
    # into the background, which the config check cannot see
    extraArgumentsAsGetoptReadsThem = {
      module.services.asterisk.extraArguments = ["vvv" "-dL" "2" "-vF" "-" "--" "-F"];
      assertions = [
        "services.asterisk.extraArguments: with -F Asterisk forks into the background, and systemd stops the service once the process it started has exited."
        ''services.asterisk.extraArguments: Asterisk ignores words that are not options or their values: "vvv", "-", "--", "-F".''
      ];
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

    # every record would fail to insert: cdr_sqlite3_custom takes a CUT() for
    # one value, cel_sqlite3_custom for three
    sqliteValuesUnlikeColumns = {
      module.services.asterisk = {
        cdr.sqlite.enable = true;
        cel = {
          enable = true;
          sqlite.enable = true;
        };
        settings."cdr_sqlite3_custom.conf".master.values = "'\${CDR(src)}', '\${CUT(CDR(dst),-,1)}'";
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
    voicemailInternalContextsBeyondWhatAsteriskReads = {
      module = {config, ...}: {
        services.asterisk.voicemail = {
          mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
          settings.cidinternalcontexts = "${lib.strings.replicate 63 "a"},\t${lib.strings.replicate 64 "b"},c,d,e,f,g,h,,j,k,";
        };
      };
      assertions = [
        ''
          services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
            context 2 of [general] cidinternalcontexts, to 63 bytes
        ''
        "services.asterisk.voicemail: Asterisk reads the first 10 contexts of cidinternalcontexts and ignores the rest: k."
      ];
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

    # app_voicemail sends a mailbox's MWI as box@context, to its aliases too,
    # and Asterisk compares the names exactly, so a mailbox named without its
    # context or in another case gets none
    mwiForMailboxNamesComparedExactly = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail = {
            mailboxes = {
              "101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
              "200@sales".pin = config.lib.asterisk.secret "/run/secrets/vm-200";
            };
            settings.aliasescontext = "myaliases";
          };
          settings."voicemail.conf".MyAliases."1234@devices" = "101@default";
          pjsip.endpoints."101".mailboxes = [
            "101"
            "200"
            "200@sales"
            "101@default@x"
            "1234@devices"
            "101@Default"
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
            pjsip.endpoints.101.mailboxes: 101@Default
        ''
      ];
    };

    # app_voicemail looks for a mailbox voicemail.conf lacks in the realtime
    # voicemail family, which extconfig.conf can map to a database
    mwiForRealtimeMailbox = {
      module = {config, ...}: {
        services.asterisk = {
          voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm";
          pjsip.endpoints."101".mailboxes = ["102@default"];
          settings."extconfig.conf".settings.voicemail = "curl,http://vm.example.org";
        };
      };
      assertions = [];
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

    # with voicemail off, MWI comes only for a context that a voicemail.conf
    # of one's own or an endpoint's incoming_mwi_mailbox names
    mwiWithVoicemailOffWarns = {
      module = {config, ...}: {
        services.asterisk = {
          modules.load = ["app_voicemail.so"];
          extraConfig."voicemail.conf" = ''
            [sales]
            200 => 1234,Sales
          '';
          pjsip = {
            endpoints."101".mailboxes = [
              "102@default"
              "103"
              "201@sales"
              "5551000@provider"
            ];
            trunks.provider = {
              host = "203.0.113.5";
              username = "5551000";
              password = config.lib.asterisk.secret "/run/secrets/trunk";
              context = "internal";
              settings.incoming_mwi_mailbox = "5551000@provider";
            };
          };
        };
      };
      assertions = [];
      warnings = [
        ''
          services.asterisk: voicemail is off, and nothing sends MWI for these mailboxes that PJSIP endpoints name, so their message lamps never light:
            pjsip.endpoints.101.mailboxes: 102@default
            pjsip.endpoints.101.mailboxes: 103
          Turn voicemail on and define them in services.asterisk.voicemail.mailboxes, or remove them from the endpoints' mailboxes.
        ''
      ];
    };

    # res_musiconhold plays the default class for one it does not know, and
    # finds a class in any case; queues take three keys for it
    musicOnHoldClassesUndefined = {
      module.services.asterisk = {
        musicOnHold.classes.office.directory = "moh";
        queues.queues.support = {
          members = ["PJSIP/101"];
          musicOnHoldClass = "jazz";
        };
        settings."queues.conf".sales = {
          MusicOnHold = "Office";
          member = ["PJSIP/101"];
        };
        confbridge.users = {
          chair.musicOnHoldClass = "DEFAULT";
          guest.settings.music_on_hold_class = "lounge";
        };
      };
      assertions = [
        ''
          services.asterisk: queues.conf and confbridge.conf name music on hold classes that musiconhold.conf does not define, so callers would hear the default class:
            queues.conf [support] musicclass = jazz
            confbridge.conf [guest] music_on_hold_class = lounge
          Define them in services.asterisk.musicOnHold.classes, or name a class that is defined.
        ''
      ];
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
                auth.password = config.lib.asterisk.secret "/run/secrets/102";
              };
              "103" = {
                context = "internal";
                callerId = ''"${lib.strings.replicate 40 "\\\""}" <103>'';
                auth.password = config.lib.asterisk.secret "/run/secrets/103";
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

    # the package has codec modules for neither g729 nor siren7, so Asterisk
    # passes them through and cannot translate them
    codecsThePackageCannotTranslateWarn = {
      module.services.asterisk = {
        pjsip.endpoints."101".allow = ["g729" "siren7:20"];
        settings."pjsip.conf" = {
          gate = {
            type = "endpoint";
            context = "internal";
            allow = "G729|g723";
          };
          door = {
            type = "endpoint";
            context = "internal";
            allow = "g729, ILBC";
          };
          lobby = {
            type = "endpoint";
            context = "internal";
            allow = "all,!g722";
          };
        };
      };
      assertions = [];
      warnings = [
        ''
          services.asterisk: the package translates none of the codecs these PJSIP endpoints allow, so their calls fail with every endpoint that does not allow the same codec:
            [101] g729, siren7
            [gate] g729, g723
          Allow one it translates as well, such as ulaw, alaw, g722, gsm or opus.
        ''
      ];
    };

    # Asterisk hands each phone of a call with direct media the address the
    # other gave: 211 gives a private one, 203 one of a network that 201 and
    # 202, pinned to lan1's TCP listener, may have no route to; 212 is pinned
    # to no transport and 213 to one on every address, so their network is
    # unknown
    directMediaThatMayNotReach = {
      module = {config, ...}: let
        phone = extension: settings:
          {
            context = "internal";
            directMedia = true;
            auth.password = config.lib.asterisk.secret "/run/secrets/${extension}";
          }
          // settings;
      in {
        services.asterisk = {
          pjsip = {
            transports = {
              lan1.address = "10.3.1.10";
              lan2.address = "10.3.2.10";
            };
            endpoints = {
              "201" = phone "201" {transport = "lan1";};
              "202" = phone "202" {transport = "lan1-tcp";};
              "203" = phone "203" {transport = "lan2";};
              "211" = phone "211" {behindNat = true;};
              "212" = phone "212" {};
              "213" = phone "213" {transport = "udp";};
              "214" = {
                context = "internal";
                transport = "lan2";
                auth.password = config.lib.asterisk.secret "/run/secrets/214";
              };
            };
          };
          # as the README shows it
          settings."pjsip.conf"."endpoint:101" = {
            direct_media = true;
            rewrite_contact = true;
          };
        };
      };
      assertions = [];
      warnings = [
        "services.asterisk: PJSIP endpoints with direct_media and behindNat (rtp_symmetric, force_rport or rewrite_contact): 101, 211. Asterisk hands the other phone of a call the private address such a phone gives, so the call has no audio. Turn directMedia off for them."
        "services.asterisk: PJSIP endpoints with direct_media on transports with different addresses: 10.3.1.10 (201, 202), 10.3.2.10 (203). Asterisk hands each phone of a call between them the address the other gave, without checking that it can reach it, so the call has no audio when their networks have no route between them. Turn directMedia off for them, or keep the endpoints with directMedia on one network."
      ];
    };

    # ",call" grants every class and "sys,call" grants system
    amiClassesInSettingsMisread = {
      module = {config, ...}: {
        services.asterisk.ami = {
          enable = true;
          users.monitor = {
            secret = config.lib.asterisk.secret "/run/secrets/ami";
            read = ["call"];
            settings = {
              read = ",call";
              write = "sys,call";
            };
          };
          users.lister = {
            secret = config.lib.asterisk.secret "/run/secrets/ami";
            settings.read = ["call" "system"];
          };
        };
      };
      assertion = ''
        [lister] read = ["call","system"]
          [monitor] read = ",call"
          [monitor] write = "sys,call"
      '';
    };

    # app_confbridge skips an action it does not know without a word
    confbridgeMenuActionUnknownThrows = {
      module.services.asterisk.confbridge.menus.admin_menu."*1" = "toggle_mute,kick_last";
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
  };
in {
  run = checkCases base;
  tests = cases;
}
