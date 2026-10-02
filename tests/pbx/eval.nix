# Evaluation-only tests of the pbx layer: the dialplan its objects turn into
# and the core options it writes.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # two phones and a trunk, which each test adds to
  base = {config, ...}: let
    inherit (config.lib.asterisk) secret;
  in {
    imports = [self.nixosModules.pbx];
    pbx = {
      enable = true;
      extensions = {
        "201" = {
          name = "Reception";
          password = secret "/run/secrets/201";
          voicemail.pin = secret "/run/secrets/vm-201";
        };
        "202".password = secret "/run/secrets/202";
      };
      inbound."5551000" = {
        trunk = "provider";
        destination.extension = "201";
      };
    };
    services.asterisk = {
      pjsip.transports.udp = {};
      pjsip.trunks.provider = {
        host = "sip.provider.example";
        username = "5551000";
        password = secret "/run/secrets/trunk";
      };
    };
  };

  configOf = module:
    evalConfig [
      base
      module
    ];

  # the context `name` of extensions.conf, with its comment
  context = name: module:
    lib.findFirst (block: builtins.elem "[${name}]" (lib.splitString "\n" block)) null (
      lib.splitString "\n\n" (lib.removeSuffix "\n" (configOf module).services.asterisk.renderedFiles."extensions.conf")
    );

  zoneFile = zone: "${pkgs.tzdata}/share/zoneinfo/${zone}";

  # the step of a hangup destination: no answer (19) for a caller not
  # answered yet whose channel has no cause or normal clearing
  hangup = ''Hangup(''${IF($["''${CHANNEL(state)}" != "Up" & (''${HANGUPCAUSE} = 0 | ''${HANGUPCAUSE} = 16)]?19)})'';

  # a Grandstream adapter for extension 201 on the phones' network, an HT801
  # unless a test says otherwise, which each test adds to
  adapter = module:
    configOf {
      imports = [module];
      pbx.phones = {
        listenAddress = lib.mkDefault "10.0.20.10";
        allowedNetworks = lib.mkDefault ["10.0.20.0/24"];
        devices."201" = {
          model = lib.mkDefault "grandstream-ht801";
          mac = lib.mkDefault "c0:74:ad:00:02:01";
        };
      };
    };

  # the line of the adapter's file that sets `p`
  pLine = p: config: lib.findFirst (lib.hasPrefix "    <${p}>") null (lib.splitString "\n" config.pbx.phones.files."cfgc074ad000201.xml".text);

  # the section of pjsip.conf with this type and name
  pjsipSection = type: name: files:
    lib.findFirst (block: lib.hasPrefix "[${name}]\ntype = ${type}\n" block) null (lib.splitString "\n\n" files."pjsip.conf");
in {
  run = lib.runTests;
  tests = {
    # an adapter registers as the endpoint (and its aor) and authenticates
    # with the auth user name, which may differ
    testGrandstreamUserIdIsTheEndpoint = {
      expr = builtins.filter (line: builtins.match " *<P3[56]>.*" line != null) (
        lib.splitString "\n"
        (adapter {
          services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        }).pbx.phones.files."cfgc074ad000201.xml".text
      );
      expected = [
        "    <P35>201</P35>"
        "    <P36>kitchen</P36>"
      ];
    };

    # every P-value the module sets for an HT801, in numeric order; common
    # settings replace the module's values and an adapter's settings replace
    # both
    testGrandstreamHt801File = {
      expr =
        (adapter {
          pbx.phones = {
            ntpServer = "10.0.20.1";
            adminPassword = self.lib.secret "/run/secrets/ht801-admin";
            grandstream = {
              timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
              settings = {
                P238 = 0;
                P1362 = "de";
              };
            };
            devices."201".settings = {
              P47 = "10.0.20.11";
              P1362 = "en";
            };
          };
        }).pbx.phones.files."cfgc074ad000201.xml".text;
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <gs_provision version="1">
          <mac>c074ad000201</mac>
          <config version="1">
            <P2>${placeholderFor "/run/secrets/ht801-admin"}</P2>
            <P30>10.0.20.1</P30>
            <P34>${placeholderFor "/run/secrets/201"}</P34>
            <P35>201</P35>
            <P36>201</P36>
            <P47>10.0.20.11</P47>
            <P64>CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00</P64>
            <P212>1</P212>
            <P237>10.0.20.10</P237>
            <P238>0</P238>
            <P271>1</P271>
            <P1362>en</P1362>
            <P1409>0</P1409>
          </config>
        </gs_provision>
      '';
    };

    # each line, a port with an account of its own, registers to sipServer
    testGrandstreamHt802File = {
      expr =
        (adapter {
          pbx.phones.devices."201" = {
            model = "grandstream-ht802";
            lines = ["201" "202"];
          };
        }).pbx.phones.files."cfgc074ad000201.xml".text;
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <gs_provision version="1">
          <mac>c074ad000201</mac>
          <config version="1">
            <P34>${placeholderFor "/run/secrets/201"}</P34>
            <P35>201</P35>
            <P36>201</P36>
            <P47>10.0.20.10</P47>
            <P212>1</P212>
            <P237>10.0.20.10</P237>
            <P238>2</P238>
            <P271>1</P271>
            <P401>1</P401>
            <P734>${placeholderFor "/run/secrets/202"}</P734>
            <P735>202</P735>
            <P736>202</P736>
            <P747>10.0.20.10</P747>
            <P1409>0</P1409>
          </config>
        </gs_provision>
      '';
    };

    # the ports share profile 1's server; a null line and the ones past the
    # end of the list are turned off
    testGrandstreamHt814File = {
      expr =
        (adapter {
          pbx.phones.devices."201" = {
            model = "grandstream-ht814";
            lines = ["201" null "202"];
          };
        }).pbx.phones.files."cfgc074ad000201.xml".text;
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <gs_provision version="1">
          <mac>c074ad000201</mac>
          <config version="1">
            <P47>10.0.20.10</P47>
            <P212>1</P212>
            <P237>10.0.20.10</P237>
            <P238>2</P238>
            <P271>1</P271>
            <P1409>0</P1409>
            <P4060>201</P4060>
            <P4062>202</P4062>
            <P4090>201</P4090>
            <P4092>202</P4092>
            <P4120>${placeholderFor "/run/secrets/201"}</P4120>
            <P4122>${placeholderFor "/run/secrets/202"}</P4122>
            <P4150>0</P4150>
            <P4152>0</P4152>
            <P4595>1</P4595>
            <P4596>0</P4596>
            <P4597>1</P4597>
            <P4598>0</P4598>
          </config>
        </gs_provision>
      '';
    };

    # a plain admin password is escaped for XML, an integer is written as it
    # is, a secret is left to the service
    testGrandstreamAdminPassword = {
      expr = map (adminPassword: pLine "P2" (adapter {pbx.phones = {inherit adminPassword;};})) [
        "a&b<c>\"d'e]]>"
        1234
        (self.lib.secret "/run/secrets/ht801-admin")
      ];
      expected = [
        "    <P2>a&amp;b&lt;c&gt;&quot;d&apos;e]]&gt;</P2>"
        "    <P2>1234</P2>"
        "    <P2>${placeholderFor "/run/secrets/ht801-admin"}</P2>"
      ];
    };

    # every spelling the option takes names the file, and fills <mac>, with the
    # address in lowercase without separators
    testGrandstreamMacSpellings = {
      expr =
        lib.mapAttrs (_: file: lib.findFirst (lib.hasPrefix "  <mac>") null (lib.splitString "\n" file.text))
        (adapter {
          pbx.phones.devices =
            lib.mapAttrs (_: mac: {
              inherit mac;
              model = "grandstream-ht801";
              lines = ["201"];
            }) {
              colons = "C0:74:AD:00:02:0A";
              hyphens = "c0-74-ad-00-02-0b";
              none = "C074AD00020c";
              mixed = "c0:74-ad0002:0D";
            };
        }).pbx.phones.files;
      expected = {
        "cfgc074ad000201.xml" = "  <mac>c074ad000201</mac>";
        "cfgc074ad00020a.xml" = "  <mac>c074ad00020a</mac>";
        "cfgc074ad00020b.xml" = "  <mac>c074ad00020b</mac>";
        "cfgc074ad00020c.xml" = "  <mac>c074ad00020c</mac>";
        "cfgc074ad00020d.xml" = "  <mac>c074ad00020d</mac>";
      };
    };

    # the socket and the configuration server the adapters keep (P237), with
    # an IPv6 address in brackets as in a URL
    testGrandstreamConfigServer = {
      expr =
        map (listen: let
          config = adapter {pbx.phones = listen;};
        in {
          socket = config.systemd.sockets.asterisk-provisioning.listenStreams;
          server = pLine "P237" config;
        }) [
          {port = 8080;}
          {listenAddress = "fd00:20::10";}
          {
            listenAddress = "fd00:20::10";
            port = 8080;
          }
        ];
      expected = [
        {
          socket = ["10.0.20.10:8080"];
          server = "    <P237>10.0.20.10:8080</P237>";
        }
        {
          socket = ["[fd00:20::10]:80"];
          server = "    <P237>[fd00:20::10]</P237>";
        }
        {
          socket = ["[fd00:20::10]:8080"];
          server = "    <P237>[fd00:20::10]:8080</P237>";
        }
      ];
    };

    # the port is opened on firewallInterfaces, or on every interface when
    # the list is empty
    testPhonesFirewall = {
      expr =
        map (interfaces: let
          inherit
            (adapter {
              pbx.phones = {
                port = 8080;
                openFirewall = true;
                firewallInterfaces = interfaces;
              };
            })
            networking
            ;
        in {
          everywhere = builtins.elem 8080 networking.firewall.allowedTCPPorts;
          voip = builtins.elem 8080 (networking.firewall.interfaces.voip.allowedTCPPorts or []);
        }) [
          ["voip"]
          []
        ];
      expected = [
        {
          everywhere = false;
          voip = true;
        }
        {
          everywhere = true;
          voip = false;
        }
      ];
    };

    testExtensionFallsBackToItsMailbox = {
      expr = context "pbx-extension-201" {};
      expected = ''
        ; from pbx.extensions."201"
        [pbx-extension-201]
        exten => s,1,Dial(''${PJSIP_DIAL_CONTACTS(201)},20)
         same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
         same => n,VoiceMail(201@default,u)
         same => n,Hangup()
         same => n(busy),VoiceMail(201@default,b)
         same => n,Hangup()'';
    };

    testExtensionWithoutMailboxHangsUp = {
      expr = context "pbx-extension-202" {
        pbx.extensions."202" = {
          ringTime = 30;
          busy.extension = "201";
        };
      };
      expected = ''
        ; from pbx.extensions."202"
        [pbx-extension-202]
        exten => s,1,Dial(''${PJSIP_DIAL_CONTACTS(202)},30)
         same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
         same => n,${hangup}
         same => n(busy),Goto(pbx-extension-201,s,1)'';
    };

    testExtensionEndpointAndMailbox = {
      expr = let
        asterisk = (configOf {}).services.asterisk;
      in {
        endpoint = {
          inherit (asterisk.pjsip.endpoints."201") context callerId mailboxes;
        };
        mailbox = asterisk.voicemail.mailboxes."201".fullName;
        withoutMailbox = asterisk.pjsip.endpoints."202".mailboxes;
      };
      expected = {
        endpoint = {
          context = "pbx-internal";
          callerId = ''"Reception" <201>'';
          mailboxes = ["201@default"];
        };
        mailbox = "Reception";
        withoutMailbox = [];
      };
    };

    # a phone that loses power in a call sends no BYE, so Asterisk hangs up an
    # extension's call after a minute without RTP from it; trunks keep 0
    testRtpTimeouts = {
      expr = let
        files = (configOf {}).services.asterisk.renderedFiles;
        timeouts = type: name: builtins.filter (lib.hasPrefix "rtp_timeout") (lib.splitString "\n" (pjsipSection type name files));
      in {
        extension = timeouts "endpoint" "201";
        trunk = timeouts "endpoint" "provider";
      };
      expected = {
        extension = ["rtp_timeout = 60"];
        trunk = [];
      };
    };

    # an extension's pickup groups are both the groups its calls ring in and
    # those it picks up from, and a plain endpoint setting replaces either
    testPickupGroups = {
      expr = let
        files =
          (configOf {
            pbx.extensions = {
              "201".pickupGroups = [
                "front"
                "sales team"
              ];
              "202".pickupGroups = ["front"];
            };
            services.asterisk.pjsip.endpoints."202".settings.named_pickup_group = "front,back";
          }).services.asterisk.renderedFiles;
      in
        lib.genAttrs ["201" "202"] (number: builtins.filter (lib.hasPrefix "named_") (lib.splitString "\n" (pjsipSection "endpoint" number files)));
      expected = {
        "201" = [
          "named_call_group = front,sales team"
          "named_pickup_group = front,sales team"
        ];
        "202" = [
          "named_call_group = front"
          "named_pickup_group = front,back"
        ];
      };
    };

    # pbx writes defaults, so plain core definitions win
    testCoreOptionsOverridePbx = {
      expr = let
        asterisk =
          (configOf {
            services.asterisk = {
              pjsip.endpoints."201" = {
                context = "reception";
                callerId = ''"Front desk" <201>'';
              };
              voicemail.mailboxes."201".fullName = "Front desk";
              dialplan.contexts.pbx-extension-201.comment = "reception";
            };
          }).services.asterisk;
      in {
        inherit (asterisk.pjsip.endpoints."201") context callerId;
        mailbox = asterisk.voicemail.mailboxes."201".fullName;
        comment = asterisk.dialplan.contexts.pbx-extension-201.comment;
      };
      expected = {
        context = "reception";
        callerId = ''"Front desk" <201>'';
        mailbox = "Front desk";
        comment = "reception";
      };
    };

    # and so do plain definitions in settings, where the scalars pbx writes
    # end up as defaults too
    testSettingsOverridePbx = {
      expr = let
        files =
          (configOf ({config, ...}: {
            services.asterisk.settings = {
              "pjsip.conf" = {
                "endpoint:201" = {
                  context = "reception";
                  callerid = ''"Front desk" <201>'';
                };
                "auth:201".password = config.lib.asterisk.secret "/run/secrets/front-desk";
              };
              "voicemail.conf".default."201" = "-${config.lib.asterisk.secret "/run/secrets/vm-front-desk"},Front desk";
            };
          })).services.asterisk.renderedFiles;
        lines = pattern: text: builtins.filter (line: builtins.match pattern line != null) (lib.splitString "\n" text);
      in {
        endpoint = lines "(callerid|context) = .*" (pjsipSection "endpoint" "201" files);
        auth = lines "password = .*" (pjsipSection "auth" "201" files);
        mailbox = lines "201 => .*" files."voicemail.conf";
      };
      expected = {
        endpoint = [
          ''callerid = "Front desk" <201>''
          "context = reception"
        ];
        auth = ["password = ${placeholderFor "/run/secrets/front-desk"}"];
        mailbox = ["201 => -${placeholderFor "/run/secrets/vm-front-desk"},Front desk"];
      };
    };

    testRingAllWithExternalNumber = let
      module = {
        pbx = {
          ringGroups.front = {
            members = [
              "201"
              "202"
            ];
            external = ["5559000"];
            noAnswer.voicemail = {
              mailbox = "201";
              greeting = "busy";
            };
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };
          emergency.numbers = [];
        };
      };
    in {
      expr = {
        group = context "pbx-ringgroup-front" module;
        confirm = context "pbx-confirm" module;
      };
      expected = {
        group = ''
          ; from pbx.ringGroups.front
          [pbx-ringgroup-front]
          exten => 5559000,1,Set(CALLERID(num)=5551000)
           same => n,Dial(PJSIP/''${EXTEN}@provider,20,U(pbx-confirm)b(pbx-caller-id^s^1(sip.provider.example)))
           same => n,Hangup()
          exten => s,1,Dial(''${PJSIP_DIAL_CONTACTS(201)}&''${PJSIP_DIAL_CONTACTS(202)}&Local/5559000@pbx-ringgroup-front/n,20,b(pbx-confirm^leg^1))
           same => n,VoiceMail(201@default,b)
           same => n,Hangup()'';
        confirm = ''
          ; from pbx.ringGroups: confirmation of external members
          [pbx-confirm]
          exten => drop,1,Set(PBX_LEG=''${IMPORT(''${CHANNEL:0:-1}2,DIALEDPEERNAME)})
           same => n,GotoIf($["''${PBX_LEG}" = ""]?done)
           same => n,SoftHangup(''${PBX_LEG})
           same => n(done),Return()
          exten => leg,1,GotoIf($["''${CHANNEL(channeltype)}" != "Local"]?done)
           same => n,Set(CHANNEL(hangup_handler_push)=pbx-confirm,drop,1)
           same => n(done),Return()
          exten => s,1,Set(GOSUB_RESULT=CONTINUE)
           same => n,Read(PBX_CONFIRM,followme/no-recording&followme/options,1,,3,5)
           same => n,GotoIf($["''${PBX_CONFIRM}" != "1"]?reject)
           same => n,Set(GOSUB_RESULT=)
           same => n(reject),Return()'';
      };
    };

    # only the external number's Local channel needs the predial routine
    testHuntRingsOneAfterTheOther = {
      expr = context "pbx-ringgroup-hunt" {
        pbx.ringGroups.hunt = {
          members = [
            "202"
            "201"
          ];
          external = ["5559000"];
          trunk = "provider";
          strategy = "hunt";
          ringTime = 10;
        };
      };
      expected = ''
        ; from pbx.ringGroups.hunt
        [pbx-ringgroup-hunt]
        exten => 5559000,1,Dial(PJSIP/''${EXTEN}@provider,10,U(pbx-confirm))
         same => n,Hangup()
        exten => s,1,Dial(''${PJSIP_DIAL_CONTACTS(202)},10)
         same => n,Dial(''${PJSIP_DIAL_CONTACTS(201)},10)
         same => n,Dial(Local/5559000@pbx-ringgroup-hunt/n,10,b(pbx-confirm^leg^1))
         same => n,${hangup}'';
    };

    testHoursRoutine = {
      expr = context "pbx-hours-office" {
        pbx.hours.office = {
          timezone = "America/Los_Angeles";
          open = [
            {
              days = "mon-fri";
              time = "09:00-17:00";
            }
            {
              days = "sat";
              time = "10:00-12:00";
            }
          ];
          holidays = [
            "dec 24-26"
            "jan 1"
          ];
          closeEarly = "*28";
        };
      };
      expected = let
        zone = zoneFile "America/Los_Angeles";
      in ''
        ; from pbx.hours.office
        [pbx-hours-office]
        exten => s,1,GotoIf($["''${DEVICE_STATE(Custom:pbx-hours-office)}" = "INUSE"]?closed)
         same => n,GotoIfTime(*,*,24-26,dec,${zone}?closed)
         same => n,GotoIfTime(*,*,1,jan,${zone}?closed)
         same => n,GotoIfTime(09:00-17:00,mon-fri,*,*,${zone}?open)
         same => n,GotoIfTime(10:00-12:00,sat,*,*,${zone}?open)
         same => n(closed),Return(closed)
         same => n(open),Return(open)
        exten => toggle,1,Answer()
         same => n,GotoIf($["''${DEVICE_STATE(Custom:pbx-hours-office)}" = "INUSE"]?reopen)
         same => n,Set(DEVICE_STATE(Custom:pbx-hours-office)=INUSE)
         same => n,Playback(activated)
         same => n,Hangup()
         same => n(reopen),Set(DEVICE_STATE(Custom:pbx-hours-office)=NOT_INUSE)
         same => n,Playback(de-activated)
         same => n,Hangup()'';
    };

    # a range past midnight on given days opens until 23:59 on them and from
    # 00:00 on the days after, ranges of days that wrap around the week
    # included; on every day the time range alone does that
    testHoursPastMidnight = {
      expr = context "pbx-hours-night" {
        pbx.hours.night = {
          timezone = "UTC";
          open = [
            {
              days = "mon-fri";
              time = "22:00-06:00";
            }
            {
              days = "sat&sun";
              time = "23:30-00:00";
            }
            {
              days = "fri-mon";
              time = "21:00-01:00";
            }
            {
              days = "*";
              time = "20:00-02:00";
            }
          ];
        };
      };
      expected = let
        zone = zoneFile "UTC";
      in ''
        ; from pbx.hours.night
        [pbx-hours-night]
        exten => s,1,GotoIfTime(22:00-23:59,mon-fri,*,*,${zone}?open)
         same => n,GotoIfTime(00:00-06:00,tue-sat,*,*,${zone}?open)
         same => n,GotoIfTime(23:30-23:59,sat&sun,*,*,${zone}?open)
         same => n,GotoIfTime(00:00-00:00,sun&mon,*,*,${zone}?open)
         same => n,GotoIfTime(21:00-23:59,fri-mon,*,*,${zone}?open)
         same => n,GotoIfTime(00:00-01:00,sat-tue,*,*,${zone}?open)
         same => n,GotoIfTime(20:00-02:00,*,*,*,${zone}?open)
         same => n(closed),Return(closed)
         same => n(open),Return(open)'';
    };

    testInboundByHours = {
      expr = context "pbx-inbound-provider" {
        pbx = {
          hours.office = {
            timezone = "Europe/Berlin";
            open = [
              {
                days = "*";
                time = "08:00-18:00";
              }
            ];
          };
          inbound."5551000" = lib.mkForce {
            trunk = "provider";
            hours = "office";
            open.extension = "201";
            closed.voicemail = "201";
          };
          inbound."5551001" = {
            trunk = "provider";
            destination.hangup = true;
          };
        };
      };
      expected = ''
        ; from pbx.inbound: calls from trunk provider
        [pbx-inbound-provider]
        exten => 5551000,1,Gosub(pbx-hours-office,s,1)
         same => n,GotoIf($["''${GOSUB_RETVAL}" = "open"]?open)
         same => n,VoiceMail(201@default,u)
         same => n,Hangup()
         same => n(open),Goto(pbx-extension-201,s,1)
        exten => 5551001,1,${hangup}'';
    };

    # a trunk's From names its account, so the calls pbx gives a caller ID
    # carry it in P-Asserted-Identity, in the trunk's From domain, and other
    # calls nothing new; emergency calls take pbx.outbound's without their own
    testCallerIdReachesTheProvider = let
      module = {config, ...}: {
        pbx = {
          outbound = {
            prefix = "9";
            trunk = "provider";
            callerId = "5551000";
          };
          emergency = {
            numbers = ["911"];
            trunk = "emergency";
          };
          ringGroups.cell = {
            number = "630";
            external = ["5559000"];
            trunk = "mobile";
          };
        };
        services.asterisk.pjsip.trunks = {
          emergency = {
            host = "2001:db8::5";
            username = "5551000";
            password = config.lib.asterisk.secret "/run/secrets/trunk";
          };
          mobile = {
            host = "sip.mobile.example";
            fromDomain = "mobile.example";
            username = "5551000";
            password = config.lib.asterisk.secret "/run/secrets/trunk";
          };
        };
      };
      dials = name: module: builtins.filter (lib.hasInfix "Dial(PJSIP/") (lib.splitString "\n" (context name module));
    in {
      expr = {
        outbound = dials "pbx-outbound" module;
        emergency = dials "pbx-emergency" module;
        cell = dials "pbx-ringgroup-cell" module;
        routine = context "pbx-caller-id" module;
        withoutCallerId = {
          outbound = dials "pbx-outbound" {
            pbx.outbound = {
              prefix = "9";
              trunk = "provider";
            };
          };
          routine = context "pbx-caller-id" {};
        };
      };
      expected = {
        outbound = [" same => n,Dial(PJSIP/\${EXTEN:1}@provider,,b(pbx-caller-id^s^1(sip.provider.example)))"];
        emergency = [" same => n,Dial(PJSIP/911@emergency,,b(pbx-caller-id^s^1([2001:db8::5])))"];
        cell = [" same => n,Dial(PJSIP/\${EXTEN}@mobile,20,U(pbx-confirm)b(pbx-caller-id^s^1(mobile.example)))"];
        routine = ''
          ; from pbx.outbound and pbx.emergency: their caller ID in P-Asserted-Identity
          [pbx-caller-id]
          exten => s,1,Set(PJSIP_HEADER(add,P-Asserted-Identity)=<sip:''${CONNECTEDLINE(num)}@''${ARG1}>)
           same => n,Return()'';
        withoutCallerId = {
          outbound = ["exten => _9X.,1,Dial(PJSIP/\${EXTEN:1}@provider)"];
          routine = null;
        };
      };
    };

    # a number that arrives through two trunks routes from both
    testInboundOnTwoTrunks = let
      module = {config, ...}: {
        services.asterisk.pjsip.trunks.second = {
          host = "sip.second.example";
          username = "5552000";
          password = config.lib.asterisk.secret "/run/secrets/second";
        };
        pbx.inbound."5551000".trunk = lib.mkForce [
          "provider"
          "second"
        ];
      };
    in {
      expr = map (trunk: context "pbx-inbound-${trunk}" module) ["provider" "second"];
      expected = [
        ''
          ; from pbx.inbound: calls from trunk provider
          [pbx-inbound-provider]
          exten => 5551000,1,Goto(pbx-extension-201,s,1)''
        ''
          ; from pbx.inbound: calls from trunk second
          [pbx-inbound-second]
          exten => 5551000,1,Goto(pbx-extension-201,s,1)''
      ];
    };

    # the prefix comes off however long it is
    testOutboundPrefixes = {
      expr =
        map (
          prefix:
            context "pbx-outbound" {
              pbx = {
                outbound = {
                  inherit prefix;
                  trunk = "provider";
                };
                emergency.numbers = [];
              };
            }
        ) [
          "9"
          "00"
          ""
        ];
      expected = [
        ''
          ; from pbx.outbound
          [pbx-outbound]
          exten => _9X.,1,Dial(PJSIP/''${EXTEN:1}@provider)
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()''
        ''
          ; from pbx.outbound
          [pbx-outbound]
          exten => _00X.,1,Dial(PJSIP/''${EXTEN:2}@provider)
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()''
        ''
          ; from pbx.outbound
          [pbx-outbound]
          exten => _X.,1,Dial(PJSIP/''${EXTEN}@provider)
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()''
      ];
    };

    # emergency calls go out through pbx.outbound's trunk unless they name
    # one, and without emergency numbers there is no emergency context
    testEmergencyTrunk = {
      expr =
        map (
          numbers:
            context "pbx-emergency" {
              pbx = {
                outbound = {
                  prefix = "9";
                  trunk = "provider";
                };
                emergency.numbers = numbers;
              };
            }
        ) [
          ["112"]
          []
        ];
      expected = [
        ''
          ; from pbx.emergency
          [pbx-emergency]
          exten => 112,1,Dial(PJSIP/112@provider)
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()''
        null
      ];
    };

    # the phones' numbers, with emergency numbers also after the prefix
    testInternalNumbers = let
      module = {
        pbx = {
          voicemailMenu = "*97";
          ringGroups.front = {
            number = "600";
            members = ["201"];
          };
          conferences.board.number = "800";
          hours.office = {
            timezone = "UTC";
            open = [
              {
                days = "*";
                time = "00:00-23:59";
              }
            ];
            closeEarly = "*28";
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
          };
          emergency = {
            numbers = [
              "112"
              "911"
            ];
            trunk = "provider";
            callerId = "5551000";
            notify = [
              "201"
              "202"
            ];
          };
        };
      };
    in {
      expr = {
        internal = context "pbx-internal" module;
        emergency = context "pbx-emergency" module;
        devices = context "pbx-devices" module;
      };
      expected = {
        internal = ''
          ; from pbx: what the phones of pbx.extensions dial
          [pbx-internal]
          include => pbx-outbound
          exten => *28,hint,Custom:pbx-hours-office
          exten => *28,1,Goto(pbx-hours-office,toggle,1)
          exten => *97,1,Answer()
           same => n,VoiceMailMain(''${CALLERID(num)}@default)
           same => n,Hangup()
          exten => 112,1,Goto(pbx-emergency,112,1)
          exten => 201,hint,PJSIP/201
          exten => 201,1,Goto(pbx-extension-201,s,1)
          exten => 202,hint,PJSIP/202
          exten => 202,1,Goto(pbx-extension-202,s,1)
          exten => 600,1,Goto(pbx-ringgroup-front,s,1)
          exten => 800,1,Goto(pbx-conference-board,s,1)
          exten => 911,1,Goto(pbx-emergency,911,1)
          exten => 9112,1,Goto(pbx-emergency,112,1)
          exten => 9911,1,Goto(pbx-emergency,911,1)'';
        emergency = ''
          ; from pbx.emergency
          [pbx-emergency]
          exten => 112,1,Gosub(notify,1(201))
           same => n,Gosub(notify,1(202))
           same => n,Set(CALLERID(num)=5551000)
           same => n,Dial(PJSIP/112@provider,,b(pbx-caller-id^s^1(sip.provider.example)))
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()
          exten => 911,1,Gosub(notify,1(201))
           same => n,Gosub(notify,1(202))
           same => n,Set(CALLERID(num)=5551000)
           same => n,Dial(PJSIP/911@provider,,b(pbx-caller-id^s^1(sip.provider.example)))
           same => n,GotoIf($["''${DIALSTATUS}" = "BUSY"]?busy)
           same => n,Congestion()
           same => n(busy),Hangup()
          exten => notify,1,GotoIf($["''${CUT(CHANNEL,-,1)}" = "PJSIP/''${ARG1}"]?done)
           same => n,Originate(Local/''${ARG1}@pbx-devices,app,SayDigits,''${CALLERID(num)},,30,acn)
           same => n(done),Return()'';
        devices = ''
          ; from pbx: every device of an extension, through a Local channel
          [pbx-devices]
          exten => 201,1,Dial(''${PJSIP_DIAL_CONTACTS(201)})
           same => n,Hangup()
          exten => 202,1,Dial(''${PJSIP_DIAL_CONTACTS(202)})
           same => n,Hangup()'';
      };
    };

    # optional application arguments are left off from the end
    testQueueAndConferenceArguments = let
      module = {
        pbx = {
          queues = {
            support.number = "610";
            sales = {
              timeout = 120;
              noAnswer.voicemail = "201";
            };
          };
          conferences = {
            board = {};
            quiet.userProfile = "muted";
          };
        };
        services.asterisk = {
          queues.queues = {
            support.members = ["PJSIP/201"];
            sales.members = ["PJSIP/202"];
          };
          confbridge.users.muted.startMuted = true;
        };
      };
    in {
      expr = map (name: context name module) [
        "pbx-queue-support"
        "pbx-queue-sales"
        "pbx-conference-board"
        "pbx-conference-quiet"
      ];
      expected = [
        ''
          ; from pbx.queues.support
          [pbx-queue-support]
          exten => s,1,Answer()
           same => n,Queue(support)
           same => n,${hangup}''
        ''
          ; from pbx.queues.sales
          [pbx-queue-sales]
          exten => s,1,Answer()
           same => n,Queue(sales,,,,120)
           same => n,VoiceMail(201@default,u)
           same => n,Hangup()''
        ''
          ; from pbx.conferences.board
          [pbx-conference-board]
          exten => s,1,Answer()
           same => n,ConfBridge(board)
           same => n,Hangup()''
        ''
          ; from pbx.conferences.quiet
          [pbx-conference-quiet]
          exten => s,1,Answer()
           same => n,ConfBridge(quiet,,muted)
           same => n,Hangup()''
      ];
    };

    # extensions as members, next to the core's own: a Local channel into
    # pbx-devices rings every device, and the extension's endpoint gives the
    # member's state
    testQueueMembers = let
      module = {
        pbx.queues.support = {
          number = "610";
          members = [
            "201"
            "202"
          ];
        };
        services.asterisk.queues.queues.support.members = ["PJSIP/301"];
      };
    in {
      expr = {
        members = builtins.filter (lib.hasPrefix "member") (lib.splitString "\n" (configOf module).services.asterisk.renderedFiles."queues.conf");
        devices = context "pbx-devices" module;
      };
      expected = {
        members = [
          "member => PJSIP/301"
          "member => Local/201@pbx-devices/n,,201,PJSIP/201"
          "member => Local/202@pbx-devices/n,,202,PJSIP/202"
        ];
        devices = ''
          ; from pbx: every device of an extension, through a Local channel
          [pbx-devices]
          exten => 201,1,Dial(''${PJSIP_DIAL_CONTACTS(201)})
           same => n,Hangup()
          exten => 202,1,Dial(''${PJSIP_DIAL_CONTACTS(202)})
           same => n,Hangup()'';
      };
    };

    # calls from a trunk without a context of its own start in
    # pbx-inbound-<trunk>, even without numbers there
    testTrunkContexts = let
      module = {config, ...}: {
        services.asterisk.pjsip.trunks = {
          backup = {
            host = "sip.backup.example";
            username = "5552000";
            password = config.lib.asterisk.secret "/run/secrets/backup";
            context = "from-backup";
          };
          spare = {
            host = "sip.spare.example";
            username = "5553000";
            password = config.lib.asterisk.secret "/run/secrets/spare";
          };
        };
        services.asterisk.dialplan.contexts.from-backup.extensions."5552000" = ["Hangup()"];
      };
    in {
      expr = {
        contexts = lib.mapAttrs (_: trunk: trunk.context) (configOf module).services.asterisk.pjsip.trunks;
        backup = context "pbx-inbound-backup" module;
        spare = context "pbx-inbound-spare" module;
      };
      expected = {
        contexts = {
          backup = "from-backup";
          provider = "pbx-inbound-provider";
          spare = "pbx-inbound-spare";
        };
        backup = null;
        spare = ''
          ; from pbx.inbound: calls from trunk spare
          [pbx-inbound-spare]'';
      };
    };

    # the attempt counter replays the prompt, the last timeout or invalid
    # key takes noInput or invalid; with directDial the menu includes the
    # context of every extension's number, after its own keys
    testIvrMenu = let
      module = {
        pbx = {
          ivrs.main = {
            number = "700";
            prompt.text = "For reception, press 1.";
            options = {
              "1".extension = "201";
              "#".hangup = true;
            };
            directDial = true;
            timeout = 3;
            attempts = 2;
            noInput.voicemail = "201";
          };
          inbound."5551000".destination = lib.mkForce {ivr = "main";};
        };
      };
    in {
      expr = {
        ivr = context "pbx-ivr-main" module;
        directDial = context "pbx-directdial" module;
        inbound = context "pbx-inbound-provider" module;
        prompts = map (package: package.name) (configOf module).services.asterisk.sounds.packages;
      };
      expected = {
        ivr = ''
          ; from pbx.ivrs.main
          [pbx-ivr-main]
          include => pbx-directdial
          exten => #,1,${hangup}
          exten => 1,1,Goto(pbx-extension-201,s,1)
          exten => i,1,Playback(pbx-invalid)
           same => n,GotoIf($[''${PBX_ATTEMPT} < 2]?s,prompt)
           same => n,${hangup}
          exten => s,1,Answer()
           same => n,Set(PBX_ATTEMPT=0)
           same => n(prompt),Set(PBX_ATTEMPT=$[''${PBX_ATTEMPT} + 1])
           same => n,Background(pbx/ivr-main)
           same => n,WaitExten(3)
          exten => t,1,GotoIf($[''${PBX_ATTEMPT} < 2]?s,prompt)
           same => n,VoiceMail(201@default,u)
           same => n,Hangup()'';
        directDial = ''
          ; from pbx.ivrs: the extensions a menu with directDial lets callers dial
          [pbx-directdial]
          exten => 201,1,Goto(pbx-extension-201,s,1)
          exten => 202,1,Goto(pbx-extension-202,s,1)'';
        inbound = ''
          ; from pbx.inbound: calls from trunk provider
          [pbx-inbound-provider]
          exten => 5551000,1,Goto(pbx-ivr-main,s,1)'';
        prompts = ["pbx-ivr-prompts"];
      };
    };

    testDisabledPbxWritesNothing = {
      expr = let
        asterisk = (configOf {pbx.enable = lib.mkForce false;}).services.asterisk;
      in {
        inherit (asterisk) enable;
        contexts = builtins.attrNames asterisk.dialplan.contexts;
        endpoints = builtins.attrNames asterisk.pjsip.endpoints;
      };
      expected = {
        enable = false;
        contexts = [];
        endpoints = [];
      };
    };
  };
}
