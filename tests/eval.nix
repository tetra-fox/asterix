# Evaluation-only tests of the NixOS module: what the typed layers render, how
# layer-1 settings combine with them, the ports the firewall opens, the room
# left for secrets, and the unit's triggers.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit
    (import ./eval-lib.nix {inherit pkgs self;})
    evalConfig
    rendered
    placeholderFor
    ;

  phone = {config, ...}: {
    services.asterisk = {
      enable = true;
      pjsip = {
        transports.udp.port = 5060;
        endpoints."101" = {
          context = "internal";
          callerId = ''"Kitchen" <101>'';
          auth.password = config.lib.asterisk.secret "/run/secrets/101";
        };
      };
      dialplan.contexts.internal.extensions."_1XX" = ["Dial(PJSIP/\${EXTEN},30)"];
    };
  };

  unitOf = modules: (evalConfig modules).systemd.services.asterisk;
in {
  run = lib.runTests;
  tests = {
    testLayerOneOverridesTypedScalarsAndExtendsLists = {
      expr = let
        files = rendered [
          phone
          {
            services.asterisk.settings."pjsip.conf"."endpoint:101" = {
              context = "internal";
              callerid = ''"Hall" <101>'';
              # list order across modules is controlled with mkBefore/mkAfter
              allow = lib.mkAfter ["opus"];
              dtmf_mode = "info";
            };
          }
        ];
      in
        builtins.filter (line: builtins.match "(callerid|allow|dtmf_mode) = .*" line != null) (
          lib.splitString "\n" files."pjsip.conf"
        );
      expected = [
        "allow = g722"
        "allow = ulaw"
        "allow = alaw"
        "allow = opus"
        ''callerid = "Hall" <101>''
        "dtmf_mode = info"
      ];
    };

    # Asterisk names its own address in the From of its requests unless the
    # endpoint has from_domain, which an endpoint pinned to a transport with an
    # external address gets; a definition in settings replaces it
    testPinnedEndpointsNameTheExternalAddressInFrom = {
      expr = let
        sections =
          (evalConfig [
            phone
            ({config, ...}: {
              services.asterisk.pjsip = {
                transports = {
                  public = {
                    port = 5070;
                    externalSignalingAddress = "198.51.100.10";
                  };
                  public6 = {
                    address = "::";
                    port = 5072;
                    externalSignalingAddress = "2001:db8::10";
                  };
                };
                endpoints = lib.genAttrs ["102" "103" "104" "105"] (extension: {
                  context = "internal";
                  auth.password = config.lib.asterisk.secret "/run/secrets/${extension}";
                  transport =
                    {
                      "102" = "public";
                      "103" = "public6";
                      "104" = "public";
                      "105" = "udp";
                    }
                    .${
                      extension
                    };
                  settings = lib.optionalAttrs (extension == "104") {from_domain = "pbx.example.org";};
                });
              };
            })
          ]).services.asterisk.settings."pjsip.conf";
      in
        map (extension: sections."endpoint:${extension}".from_domain or null) ["101" "102" "103" "104" "105"];
      expected = [
        null
        "198.51.100.10"
        "[2001:db8::10]"
        "pbx.example.org"
        null
      ];
    };

    # Asterisk takes a request whose From names an endpoint from any address,
    # and challenges none of one without auth: 102 takes requests from its
    # identify's addresses alone, while 101 and 103 have auth, 104 is open on
    # purpose and 105 is known by a host name, which an ACL cannot hold
    testIdentifyWithoutAuthTakesRequestsFromItsAddressesAlone = {
      expr = let
        sections =
          (evalConfig [
            phone
            ({config, ...}: {
              services.asterisk.pjsip.endpoints = {
                "101".identify.match = ["10.0.0.1"];
                "102" = {
                  context = "internal";
                  identify.match = ["10.0.0.2" "10.0.2.0/24" "2001:db8::2"];
                };
                "103" = {
                  context = "internal";
                  identify.match = ["10.0.0.3"];
                  auth.password = config.lib.asterisk.secret "/run/secrets/103";
                };
                "104" = {
                  context = "internal";
                  identify.match = ["10.0.0.4"];
                  open = true;
                };
                "105" = {
                  context = "internal";
                  identify.match = ["10.0.0.5" "gate.example.org"];
                };
              };
            })
          ]).services.asterisk.settings."pjsip.conf";
      in
        map (extension: let
          section = sections."endpoint:${extension}";
        in [(section.deny or null) (section.permit or null)]) ["101" "102" "103" "104" "105"];
      expected = [
        [null null]
        [
          ["0.0.0.0/0.0.0.0" "::/0"]
          ["10.0.0.2" "10.0.2.0/24" "2001:db8::2"]
        ]
        [null null]
        [null null]
        [null null]
      ];
    };

    # a udp transport takes TCP on its address and port too, through a tcp
    # transport with its external addresses, local networks and settings,
    # which the firewall opens; `tcp = false` leaves it out
    testUdpTransportTakesTcpToo = {
      expr =
        map (tcp: let
          config = evalConfig [
            phone
            {
              services.asterisk = {
                openFirewall = true;
                pjsip.transports.udp = {
                  address = "10.0.20.10";
                  externalSignalingAddress = "203.0.113.1";
                  externalMediaAddress = "203.0.113.1";
                  localNet = ["10.0.0.0/8"];
                  allowReload = true;
                  settings.tos = "cs3";
                  inherit tcp;
                };
              };
            }
          ];
          pjsip = config.services.asterisk.renderedFiles."pjsip.conf";
        in {
          named = lib.hasInfix "[udp-tcp]" pjsip;
          listener =
            lib.hasInfix ''
              [udp-tcp]
              type = transport
              allow_reload = yes
              bind = 10.0.20.10:5060
              external_media_address = 203.0.113.1
              external_signaling_address = 203.0.113.1
              local_net = 10.0.0.0/8
              protocol = tcp
              tos = cs3
            ''
            pjsip;
          inherit (config.networking.firewall) allowedTCPPorts allowedUDPPorts;
        }) [
          true
          false
        ];
      expected = [
        {
          named = true;
          listener = true;
          allowedTCPPorts = [5060];
          allowedUDPPorts = [5060];
        }
        {
          named = false;
          listener = false;
          allowedTCPPorts = [];
          allowedUDPPorts = [5060];
        }
      ];
    };

    # the ports open on the listed interfaces alone; Asterisk reads a
    # transport's protocol in any case (res/res_pjsip/config_transport.c,
    # transport_protocol_handler), and a TLS one without a port takes 5061
    testFirewallPerInterface = {
      expr = let
        config = evalConfig [
          phone
          {
            services.asterisk = {
              openFirewall = true;
              firewallInterfaces = ["voip"];
              settings."pjsip.conf" = {
                tcp = {
                  type = "transport";
                  protocol = "TCP";
                  bind = "0.0.0.0:5070";
                };
                tls = {
                  type = "transport";
                  protocol = "Tls";
                  bind = "0.0.0.0";
                  cert_file = "/var/lib/acme/pbx/cert.pem";
                  priv_key_file = "/var/lib/acme/pbx/key.pem";
                };
              };
              rtp.portRange = {
                from = 16384;
                to = 16483;
              };
            };
          }
        ];
      in {
        voip = config.networking.firewall.interfaces.voip;
        global = {
          inherit (config.networking.firewall) allowedUDPPorts allowedTCPPorts allowedUDPPortRanges;
        };
      };
      expected = {
        voip = {
          allowedTCPPorts = [
            5060
            5061
            5070
          ];
          allowedTCPPortRanges = [];
          allowedUDPPorts = [5060];
          allowedUDPPortRanges = [
            {
              from = 16384;
              to = 16483;
            }
          ];
        };
        global = {
          allowedUDPPorts = [];
          allowedTCPPorts = [];
          allowedUDPPortRanges = [];
        };
      };
    };

    # AMI and HTTP listen on the ports of the final manager.conf and
    # http.conf, which settings can change
    testFirewallOpensTheAmiAndHttpPortsAsteriskListensOn = {
      expr =
        map (
          module:
            (evalConfig [
              phone
              {services.asterisk.openFirewall = true;}
              module
            ]).networking.firewall.allowedTCPPorts
        )
        [
          {
            services.asterisk.ami = {
              enable = true;
              openFirewall = true;
              settings.port = 5039;
            };
          }
          {
            services.asterisk.http = {
              enable = true;
              openFirewall = true;
              settings.bindport = 8000;
            };
          }
          {
            services.asterisk.http = {
              enable = true;
              openFirewall = true;
              tls = {
                enable = true;
                certFile = "/var/lib/acme/pbx/cert.pem";
                keyFile = "/var/lib/acme/pbx/key.pem";
              };
              settings.tlsbindaddr = "127.0.0.1:8443";
            };
          }
          # on, but not opened
          {
            services.asterisk = {
              ami = {
                enable = true;
                settings.port = 5039;
              };
              http.enable = true;
            };
          }
        ];
      expected = [
        [
          5039
          5060
        ]
        [
          5060
          8000
        ]
        [
          5060
          8088
          8443
        ]
        [5060]
      ];
    };

    # an even end opens the RTCP port above it too
    testRtpRangeEvenEndOpensRtcp = {
      expr =
        (evalConfig [
          phone
          {
            services.asterisk = {
              openFirewall = true;
              rtp.portRange = {
                from = 10000;
                to = 10100;
              };
            };
          }
        ]).networking.firewall.allowedUDPPortRanges;
      expected = [
        {
          from = 10000;
          to = 10101;
        }
      ];
    };

    # a dialplan change only changes the reload trigger, while transports,
    # modules.conf and the SQLite CDR busy timeout restart the service, as
    # every change does with reloadOnChange off
    testChangesReloadOrRestart = {
      expr = let
        unit = modules: unitOf ([phone] ++ modules);
        base = unit [];
        restarts = a: b: a.restartTriggers != b.restartTriggers;
        dialplan = unit [{services.asterisk.dialplan.contexts.internal.extensions."200" = ["Answer()"];}];
        sqlite = {services.asterisk.cdr.sqlite.enable = true;};
        withoutReload = unit [{services.asterisk.reloadOnChange = false;}];
      in {
        dialplan = {
          sameStart = base.serviceConfig.ExecStart == dialplan.serviceConfig.ExecStart;
          sameStartPre = base.serviceConfig.ExecStartPre == dialplan.serviceConfig.ExecStartPre;
          restarts = restarts base dialplan;
          reloads = base.reloadTriggers != dialplan.reloadTriggers;
        };
        transport = restarts base (unit [{services.asterisk.pjsip.transports.udp.port = lib.mkForce 5070;}]);
        modules = restarts base (unit [{services.asterisk.modules.load = ["app_system.so"];}]);
        busyTimeout = restarts (unit [sqlite]) (unit [
          sqlite
          {services.asterisk.settings."cdr_sqlite3_custom.conf".master.busy_timeout = 20000;}
        ]);
        withoutReload = {
          inherit (withoutReload) reloadTriggers;
          restartTriggers = builtins.length withoutReload.restartTriggers;
        };
      };
      expected = {
        dialplan = {
          sameStart = true;
          sameStartPre = true;
          restarts = false;
          reloads = true;
        };
        transport = true;
        modules = true;
        busyTimeout = true;
        withoutReload = {
          reloadTriggers = [];
          restartTriggers = 2;
        };
      };
    };

    testVoicemailMailboxLines = {
      expr = let
        files = rendered [
          phone
          (
            {config, ...}: {
              services.asterisk.voicemail.mailboxes = {
                "101" = {
                  pin = config.lib.asterisk.secret "/run/secrets/vm-101";
                  fullName = "Alice";
                  email = "alice@example.org";
                  options = {
                    attach = true;
                    volgain = 0.5;
                  };
                };
                "200@sales".pin = config.lib.asterisk.secret "/run/secrets/vm-200";
              };
            }
          )
        ];
      in
        builtins.filter (line: builtins.match "(\\[.*|[0-9]+ => .*)" line != null) (
          lib.splitString "\n" files."voicemail.conf"
        );
      expected = [
        "[general]"
        "[default]"
        "101 => -${placeholderFor "/run/secrets/vm-101"},Alice,alice@example.org,,attach=yes|volgain=0.500000"
        "[sales]"
        "200 => -${placeholderFor "/run/secrets/vm-200"},200,"
      ];
    };

    # the secrets in mailbox lines of typed, layer-1 and raw mailboxes, which
    # app_voicemail splits at commas, and what a secret may add to the other
    # bytes of a value Asterisk keeps a number of bytes of: 79 of a PIN (a
    # typed one's `-` included), a name, a pager or sender address, 255 of an
    # ARI user's `user:password`, which HTTP basic authentication carries, and
    # 1014 of an AMI secret, which a Login sends; a secret used in two places
    # gets the least
    testSecretsInLimitedValues = {
      expr = let
        config = evalConfig [
          phone
          (
            {config, ...}: let
              secret = name: config.lib.asterisk.secret "/run/secrets/${name}";
            in {
              services.asterisk = {
                voicemail.mailboxes = {
                  "101".pin = secret "vm-101";
                  "102".pin = secret "pin";
                };
                settings."voicemail.conf" = {
                  general.serveremail = secret "from";
                  sales = {
                    "200" = "0;${secret "vm-200"},Sales";
                    "201" = "1234,${secret "name"},${secret "email"},pager-${secret "pager"}";
                  };
                };
                extraConfig."voicemail.conf" = ''
                  [support]
                  300 => @NIX_ASTERISK_SECRET:file:/run/secrets/vm-300@ ; the PIN
                '';
                http.enable = true;
                ari = {
                  enable = true;
                  users = {
                    app.password = secret "ari";
                    pinned.password = "pre-${secret "pin"}";
                  };
                };
                ami = {
                  enable = true;
                  users = {
                    monitor.secret = secret "ami";
                    app.secret = "${secret "ari"};";
                  };
                };
              };
            }
          )
        ];
      in {
        inherit (config.services.asterisk) fieldSecrets secretMaxLengths;
      };
      expected = {
        fieldSecrets = map (name: {_secret = "/run/secrets/${name}";}) [
          "vm-101"
          "pin"
          "vm-200"
          "name"
          "email"
          "pager"
          "vm-300"
        ];
        secretMaxLengths = {
          ${placeholderFor "/run/secrets/vm-101"} = 78;
          ${placeholderFor "/run/secrets/pin"} = 78;
          ${placeholderFor "/run/secrets/from"} = 79;
          ${placeholderFor "/run/secrets/vm-200"} = 77;
          ${placeholderFor "/run/secrets/name"} = 79;
          ${placeholderFor "/run/secrets/pager"} = 73;
          ${placeholderFor "/run/secrets/vm-300"} = 79;
          ${placeholderFor "/run/secrets/ari"} = 251;
          ${placeholderFor "/run/secrets/ami"} = 1014;
        };
      };
    };

    # the closed sets take what Asterisk takes: names in any case where it
    # compares so, actions with arguments, an empty key sequence for a
    # feature turned off, and hints with variables or a provider's own names
    testClosedSetsTakeWhatAsteriskTakes = {
      expr = let
        files = rendered [
          phone
          {
            services.asterisk = {
              logger.channels.messages = ["NOTICE" " warning" "verbose(3)"];
              confbridge.menus.admin_menu."*1" = "Toggle_Mute, playback(beep&beep),dialplan_exec(internal,101,1)";
              features.featureMap = {
                blindxfer = "#a";
                atxfer = "";
              };
              dialplan.contexts.internal.hints = {
                "101" = "PJSIP/101&custom:dnd101,CustomPresence:101";
                "102" = "Queue:support_avail&Custom:front/desk";
                "103" = "\${TECH}/103";
              };
            };
          }
        ];
      in
        builtins.filter (line: !(lib.hasInfix "\n${line}\n" (lib.concatStrings (builtins.attrValues files)))) [
          "messages => NOTICE, warning,verbose(3)"
          "*1 = Toggle_Mute, playback(beep&beep),dialplan_exec(internal,101,1)"
          "blindxfer = #a"
          "atxfer = "
          "exten => 101,hint,PJSIP/101&custom:dnd101,CustomPresence:101"
          "exten => 102,hint,Queue:support_avail&Custom:front/desk"
          "exten => 103,hint,\${TECH}/103"
        ];
      expected = [];
    };

    # /ari/asterisk shows every PJSIP password to read-only users too, so ARI
    # loads res_ari_asterisk only when it is listed in modules.load
    testAriLeavesOutTheAsteriskResource = {
      expr = let
        modules =
          (rendered [
            phone
            (
              {config, ...}: {
                services.asterisk = {
                  http.enable = true;
                  ari = {
                    enable = true;
                    users.app.password = config.lib.asterisk.secret "/run/secrets/ari";
                  };
                };
              }
            )
          ])."modules.conf";
      in
        map (module: lib.hasInfix "load => ${module}" modules) [
          "res_ari.so"
          "res_ari_asterisk.so"
        ];
      expected = [
        true
        false
      ];
    };

    # file channels, queue_log and the CSV CDRs are rotated, the console and
    # syslog are not
    testLogrotateFiles = {
      expr =
        map (
          module: (evalConfig [phone module]).services.logrotate.settings.asterisk.files or null
        ) [
          {services.asterisk.logger.channels."syslog.local0" = ["error"];}
          {
            services.asterisk = {
              logger = {
                channels = {
                  full = ["verbose"];
                  "/srv/asterisk/security" = ["security"];
                };
                queueLog = true;
              };
              cdr.csv.enable = true;
            };
          }
          {
            networking.hostName = "pbx";
            services.asterisk = {
              logger.channels.full = ["verbose"];
              settings."logger.conf".general.appendhostname = true;
            };
          }
          # the kernel's name, from the sysctl, or from the network
          {
            networking.hostName = "pbx";
            boot.kernel.sysctl."kernel.hostname" = "pbx.example.org";
            services.asterisk = {
              logger.channels.full = ["verbose"];
              settings."logger.conf".general.appendhostname = true;
            };
          }
          {
            networking.hostName = "";
            services.asterisk = {
              logger = {
                channels.full = ["verbose"];
                queueLog = true;
              };
              settings."logger.conf".general.appendhostname = true;
            };
          }
        ];
      expected = [
        null
        [
          "/srv/asterisk/security"
          "/var/log/asterisk/full"
          "/var/log/asterisk/queue_log"
          "/var/log/asterisk/cdr-csv/*.csv"
        ]
        ["/var/log/asterisk/full.pbx"]
        ["/var/log/asterisk/full.pbx.example.org"]
        ["/var/log/asterisk/queue_log"]
      ];
    };

    # static addresses of interfaces other than the default gateway's may come
    # up after network-online.target; a transport bound to one must wait
    testWaitsForSpecificBindAddresses = {
      expr =
        map
        (
          bind:
            builtins.length
            (unitOf [
              phone
              {services.asterisk.pjsip.transports.udp.address = lib.mkIf (bind != null) bind;}
            ]).serviceConfig.ExecStartPre
        )
        [
          null
          "127.0.0.1"
          "127.0.0.2"
          "127.255.0.1"
          "::1"
          "10.0.20.10"
        ];
      expected = [
        1
        1
        1
        1
        1
        2
      ];
    };
  };
}
