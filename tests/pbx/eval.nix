# Evaluation-only tests of the pbx layer: the dialplan its objects turn into
# and the core options it writes.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig;

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

  # an HT801 adapter for extension 201 on the phones' network, which each test
  # adds to
  ht801 = module:
    configOf {
      imports = [module];
      pbx.phones = {
        listenAddress = lib.mkDefault "10.0.20.10";
        allowedNetworks = lib.mkDefault ["10.0.20.0/24"];
        grandstream.ht801 = {
          enable = true;
          devices."201".mac = lib.mkDefault "c0:74:ad:00:02:01";
        };
      };
    };

  # the line of the adapter's file that sets `p`
  pLine = p: config: lib.findFirst (lib.hasPrefix "    <${p}>") null (lib.splitString "\n" config.pbx.phones.files."cfgc074ad000201.xml".text);
in {
  run = lib.runTests;
  tests = {
    # an adapter registers as the endpoint (and its aor) and authenticates
    # with the auth user name, which may differ
    testHt801UserIdIsTheEndpoint = {
      expr = builtins.filter (line: builtins.match " *<P3[56]>.*" line != null) (
        lib.splitString "\n"
        (configOf {
          services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
          pbx.phones = {
            listenAddress = "10.0.20.10";
            allowedNetworks = ["10.0.20.0/24"];
            grandstream.ht801 = {
              enable = true;
              devices."201".mac = "c0:74:ad:00:02:01";
            };
          };
        }).pbx.phones.files."cfgc074ad000201.xml".text
      );
      expected = [
        "    <P35>201</P35>"
        "    <P36>kitchen</P36>"
      ];
    };

    # the socket and the configuration server the adapters keep (P237), with
    # an IPv6 address in brackets as in a URL
    testHt801ConfigServer = {
      expr =
        map (listen: let
          config = ht801 {pbx.phones = listen;};
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
         same => n,Hangup()
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
           same => n,Dial(PJSIP/''${EXTEN}@provider,20,U(pbx-confirm))
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
          exten => s,1,Read(PBX_CONFIRM,followme/no-recording&followme/options,1,,3,5)
           same => n,GotoIf($["''${PBX_CONFIRM}" = "1"]?accept)
           same => n,Set(GOSUB_RESULT=CONTINUE)
           same => n(accept),Return()'';
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
         same => n,Hangup()'';
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
        exten => 5551001,1,Hangup()'';
    };

    # the prefix comes off however long it is
    testOutboundPrefixes = {
      expr =
        map (
          prefix:
            context "pbx-outbound" {
              pbx.outbound = {
                inherit prefix;
                trunk = "provider";
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
           same => n,Hangup()''
        ''
          ; from pbx.outbound
          [pbx-outbound]
          exten => _00X.,1,Dial(PJSIP/''${EXTEN:2}@provider)
           same => n,Hangup()''
        ''
          ; from pbx.outbound
          [pbx-outbound]
          exten => _X.,1,Dial(PJSIP/''${EXTEN}@provider)
           same => n,Hangup()''
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
        notify = context "pbx-emergency-notify" module;
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
          exten => 112,1,Originate(Local/201@pbx-emergency-notify,app,SayDigits,''${CALLERID(num)},,30,acn)
           same => n,Originate(Local/202@pbx-emergency-notify,app,SayDigits,''${CALLERID(num)},,30,acn)
           same => n,Set(CALLERID(num)=5551000)
           same => n,Dial(PJSIP/112@provider)
           same => n,Hangup()
          exten => 911,1,Originate(Local/201@pbx-emergency-notify,app,SayDigits,''${CALLERID(num)},,30,acn)
           same => n,Originate(Local/202@pbx-emergency-notify,app,SayDigits,''${CALLERID(num)},,30,acn)
           same => n,Set(CALLERID(num)=5551000)
           same => n,Dial(PJSIP/911@provider)
           same => n,Hangup()'';
        notify = ''
          ; from pbx.emergency.notify
          [pbx-emergency-notify]
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
           same => n,Hangup()''
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
    # key takes noInput or invalid
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
        inbound = context "pbx-inbound-provider" module;
        prompts = map (package: package.name) (configOf module).services.asterisk.sounds.packages;
      };
      expected = {
        ivr = ''
          ; from pbx.ivrs.main
          [pbx-ivr-main]
          exten => #,1,Hangup()
          exten => 1,1,Goto(pbx-extension-201,s,1)
          exten => 201,1,Goto(pbx-extension-201,s,1)
          exten => 202,1,Goto(pbx-extension-202,s,1)
          exten => i,1,Playback(pbx-invalid)
           same => n,GotoIf($[''${PBX_ATTEMPT} < 2]?s,prompt)
           same => n,Hangup()
          exten => s,1,Answer()
           same => n,Set(PBX_ATTEMPT=0)
           same => n(prompt),Set(PBX_ATTEMPT=$[''${PBX_ATTEMPT} + 1])
           same => n,Background(pbx/ivr-main)
           same => n,WaitExten(3)
          exten => t,1,GotoIf($[''${PBX_ATTEMPT} < 2]?s,prompt)
           same => n,VoiceMail(201@default,u)
           same => n,Hangup()'';
        inbound = ''
          ; from pbx.inbound: calls from trunk provider
          [pbx-inbound-provider]
          exten => 5551000,1,Goto(pbx-ivr-main,s,1)'';
        prompts = ["pbx-ivr-prompts"];
      };
    };

    # a recorded prompt needs no speech synthesis
    testIvrSoundPrompt = {
      expr = let
        module.pbx.ivrs.main.prompt.sound = "custom/main-menu";
      in {
        background = lib.hasInfix "Background(custom/main-menu)" (context "pbx-ivr-main" module);
        packages = (configOf module).services.asterisk.sounds.packages;
      };
      expected = {
        background = true;
        packages = [];
      };
    };

    testPaging = let
      module = {
        pbx.paging = {
          all = {
            number = "650";
            members = [
              "201"
              "202"
            ];
          };
          talk = {
            number = "651";
            members = ["202"];
            duplex = true;
            skipBusy = false;
            headers = ["Alert-Info: intercom"];
          };
        };
      };
    in {
      expr = {
        all = context "pbx-paging-all" module;
        talk = context "pbx-paging-talk" module;
        internal = lib.hasInfix "exten => 650,1,Goto(pbx-paging-all,s,1)" (context "pbx-internal" module);
      };
      expected = {
        all = ''
          ; from pbx.paging.all
          [pbx-paging-all]
          exten => headers,1,Set(PJSIP_HEADER(add,Alert-Info)=<http://example.com>\;info=alert-autoanswer\;delay=0)
           same => n,Set(PJSIP_HEADER(add,Call-Info)=<sip:pbx>\;answer-after=0)
           same => n,Return()
          exten => member,1,GotoIf($["''${CUT(CHANNEL,-,1)}" = "PJSIP/''${ARG1}"]?done)
           same => n,Set(PBX_STATE=''${DEVICE_STATE(PJSIP/''${ARG1})})
           same => n,GotoIf($["''${PBX_STATE}" != "NOT_INUSE" & "''${PBX_STATE}" != "UNKNOWN"]?done)
           same => n,Set(PBX_PAGE=''${PBX_PAGE}&''${PJSIP_DIAL_CONTACTS(''${ARG1})})
           same => n(done),Return()
          exten => s,1,Set(PBX_PAGE=)
           same => n,Gosub(member,1(201))
           same => n,Gosub(member,1(202))
           same => n,Page(''${PBX_PAGE},ib(pbx-paging-all^headers^1))
           same => n,Hangup()'';
        talk = ''
          ; from pbx.paging.talk
          [pbx-paging-talk]
          exten => headers,1,Set(PJSIP_HEADER(add,Alert-Info)=intercom)
           same => n,Return()
          exten => member,1,GotoIf($["''${CUT(CHANNEL,-,1)}" = "PJSIP/''${ARG1}"]?done)
           same => n,Set(PBX_PAGE=''${PBX_PAGE}&''${PJSIP_DIAL_CONTACTS(''${ARG1})})
           same => n(done),Return()
          exten => s,1,Set(PBX_PAGE=)
           same => n,Gosub(member,1(202))
           same => n,Page(''${PBX_PAGE},idb(pbx-paging-talk^headers^1))
           same => n,Hangup()'';
        internal = true;
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
