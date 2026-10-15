# Evaluation-only tests of the files services.asterix.phones writes: each vendor's format,
# and the parts of one with logic of their own
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # the files of extensions 201 and 202 on the phones' network and the devices
  # a test adds
  files = module:
    (evalConfig [
      ({config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [self.nixosModules.default];
        services.asterix = {
          enable = true;
          extensions = {
            "201".password = secret "/run/secrets/201";
            "202".password = secret "/run/secrets/202";
          };
          phones = {
            listenAddress = "10.0.20.10";
            allowedNetworks = ["10.0.20.0/24"];
          };
        };
        services.asterisk.pjsip.transports.udp = {};
      })
      module
    ]).services.asterix.phones.files;

  texts = module: lib.mapAttrs (_: file: file.text) (files module);
in {
  run = lib.runTests;
  tests = {
    # a factory Cisco device fetches the file of its model from the server in
    # DHCP option 66, one for all devices of the model, which names the
    # device's own file in the rule it fetches next
    testCiscoBootstrapFiles = {
      expr = lib.mapAttrs (_: file: file.text) (lib.filterAttrs (_: file: file.tftp) (files {
        services.asterix.phones.devices = {
          desk = {
            model = "cisco-8841";
            mac = "00:62:ec:00:02:01";
            lines = ["201"];
          };
          lobby = {
            model = "cisco-8841";
            mac = "00:62:ec:00:02:02";
            lines = ["202"];
          };
          hall = {
            model = "cisco-spa502g";
            mac = "00:62:ec:00:02:03";
            lines = ["202"];
          };
          garage = {
            model = "cisco-spa112";
            mac = "00:62:ec:00:02:04";
            lines = ["202"];
          };
        };
      }));
      expected = let
        bootstrap = ''
          <?xml version="1.0" encoding="UTF-8"?>
          <flat-profile>
            <Profile_Rule>http://10.0.20.10/$MA.xml</Profile_Rule>
            <Profile_Rule_B>http://10.0.20.10/$MA.xml</Profile_Rule_B>
          </flat-profile>
        '';
      in {
        "8841-3PCC.xml" = bootstrap;
        "spa112.cfg" = bootstrap;
        "spa502G.cfg" = bootstrap;
        "spa502g.cfg" = bootstrap;
      };
    };

    # a Cisco phone with multiplatform firmware: a null line and the ones past
    # the end are turned off, the auth user may differ from the endpoint,
    # common settings replace the module's values and a device's settings
    # replace both
    testCiscoMultiplatformFile = {
      expr =
        (texts {
          services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
          services.asterix.phones = {
            ntpServer = "10.0.20.1";
            adminPassword = self.lib.secret "/run/secrets/phone-admin";
            cisco.settings = {
              Webex_Onboard_Enable = "Yes";
              Time_Zone = "GMT+01:00";
            };
            devices.desk = {
              model = "cisco-6841";
              mac = "00:62:ec:00:02:01";
              lines = ["201" null "202"];
              settings = {
                Proxy_3_ = "10.0.20.11";
                Time_Zone = "GMT+02:00";
              };
            };
          };
        })."0062ec000201.xml";
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <flat-profile>
          <Admin_Password>${placeholderFor "/run/secrets/phone-admin"}</Admin_Password>
          <Auth_ID_1_>201</Auth_ID_1_>
          <Auth_ID_3_>kitchen</Auth_ID_3_>
          <Line_Enable_1_>Yes</Line_Enable_1_>
          <Line_Enable_2_>No</Line_Enable_2_>
          <Line_Enable_3_>Yes</Line_Enable_3_>
          <Line_Enable_4_>No</Line_Enable_4_>
          <Password_1_>${placeholderFor "/run/secrets/201"}</Password_1_>
          <Password_3_>${placeholderFor "/run/secrets/202"}</Password_3_>
          <Primary_NTP_Server>10.0.20.1</Primary_NTP_Server>
          <Profile_Rule>http://10.0.20.10/$MA.xml</Profile_Rule>
          <Profile_Rule_B></Profile_Rule_B>
          <Proxy_1_>10.0.20.10</Proxy_1_>
          <Proxy_3_>10.0.20.11</Proxy_3_>
          <Time_Zone>GMT+02:00</Time_Zone>
          <User_ID_1_>201</User_ID_1_>
          <User_ID_3_>202</User_ID_3_>
          <Webex_Onboard_Enable>Yes</Webex_Onboard_Enable>
        </flat-profile>
      '';
    };

    # a Cisco adapter with a router: the admin password and NTP server go into
    # the router configuration, as does a setting given as a path, and the
    # port of the second line has an account of its own
    testCiscoRouterAdapterFile = {
      expr =
        (texts {
          services.asterix.phones = {
            ntpServer = "10.0.20.1";
            adminPassword = self.lib.secret "/run/secrets/phone-admin";
            devices.garage = {
              model = "cisco-ata191";
              mac = "00:62:ec:00:02:01";
              lines = [null "202"];
              settings."router-configuration/Time_Setup/Time_Zone" = "+01 2 2";
            };
          };
        })."0062ec000201.xml";
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <flat-profile>
          <Auth_ID_2_>202</Auth_ID_2_>
          <Line_Enable_1_>No</Line_Enable_1_>
          <Line_Enable_2_>Yes</Line_Enable_2_>
          <Password_2_>${placeholderFor "/run/secrets/202"}</Password_2_>
          <Profile_Rule>http://10.0.20.10/$MA.xml</Profile_Rule>
          <Profile_Rule_B></Profile_Rule_B>
          <Proxy_2_>10.0.20.10</Proxy_2_>
          <Use_Auth_ID_2_>Yes</Use_Auth_ID_2_>
          <User_ID_2_>202</User_ID_2_>
          <router-configuration>
            <Web_Login_Admin_Password>${placeholderFor "/run/secrets/phone-admin"}</Web_Login_Admin_Password>
            <Time_Setup>
              <Time_Server>10.0.20.1</Time_Server>
              <Time_Server_Mode>manual</Time_Server_Mode>
              <Time_Zone>+01 2 2</Time_Zone>
            </Time_Setup>
          </router-configuration>
        </flat-profile>
      '';
    };

    # every setting of a Fanvil X303's four lines: a used line, a null one, a
    # used one with its own auth user name and one past the end of the list;
    # fanvil.settings replace the module's values and a device's settings
    # replace both
    testFanvilFile = {
      expr = lib.mapAttrs (_: file: {inherit (file) text escape allowedAddress;}) (files {
        services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
        services.asterix.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/fanvil-admin";
          fanvil.settings = {
            "ap.FlashMode" = 2;
            "phone.display.DefaultLanguage" = "de";
          };
          devices."201" = {
            model = "fanvil-x303";
            mac = "0C:38:3E:00:02:01";
            lines = ["201" null "202"];
            allowedAddress = "10.0.20.21";
            settings = {
              "phone.display.DefaultLanguage" = "en";
              "sip.line.1.DisplayName" = "Reception & Desk";
            };
          };
        };
      });
      expected = {
        "0c383e000201.cfg" = {
          text = ''
            <?xml version="1.0" encoding="UTF-8"?>
            <sysConf>
              <ap>
                <FlashFileName>$mac.cfg</FlashFileName>
                <FlashMode>2</FlashMode>
                <FlashProtocol>4</FlashProtocol>
                <FlashServerIP>http://10.0.20.10</FlashServerIP>
              </ap>
              <ota>
                <FDPSEnable>0</FDPSEnable>
              </ota>
              <phone>
                <date>
                  <EnableSNTP>1</EnableSNTP>
                  <SNTPServer>10.0.20.1</SNTPServer>
                </date>
                <display>
                  <DefaultLanguage>en</DefaultLanguage>
                </display>
              </phone>
              <sip>
                <line index="1">
                  <DisplayName>Reception &amp; Desk</DisplayName>
                  <EnableReg>1</EnableReg>
                  <PhoneNumber>201</PhoneNumber>
                  <RegisterAddr>10.0.20.10</RegisterAddr>
                  <RegisterPort>5060</RegisterPort>
                  <RegisterPswd>${placeholderFor "/run/secrets/201"}</RegisterPswd>
                  <RegisterUser>201</RegisterUser>
                </line>
                <line index="2">
                  <EnableReg>0</EnableReg>
                </line>
                <line index="3">
                  <EnableReg>1</EnableReg>
                  <PhoneNumber>202</PhoneNumber>
                  <RegisterAddr>10.0.20.10</RegisterAddr>
                  <RegisterPort>5060</RegisterPort>
                  <RegisterPswd>${placeholderFor "/run/secrets/202"}</RegisterPswd>
                  <RegisterUser>kitchen</RegisterUser>
                </line>
                <line index="4">
                  <EnableReg>0</EnableReg>
                </line>
              </sip>
              <web>
                <account index="1">
                  <Level>10</Level>
                  <Name>admin</Name>
                  <Password>${placeholderFor "/run/secrets/fanvil-admin"}</Password>
                </account>
              </web>
            </sysConf>
          '';
          escape = "xml";
          allowedAddress = "10.0.20.21";
        };
      };
    };

    # a Grandstream phone's accounts 2 to 6 and 7 to 16 follow their own
    # P-values, in numeric order; a null line and the ones past the end are
    # turned off; common settings replace the module's values and a phone's
    # settings replace both
    testGrandstreamPhoneFile = {
      expr =
        (texts {
          services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
          services.asterix.phones = {
            ntpServer = "10.0.20.1";
            adminPassword = self.lib.secret "/run/secrets/phone-admin";
            grandstream = {
              timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
              settings = {
                P238 = 0;
                P1362 = "de";
              };
            };
            devices.desk = {
              model = "grandstream-grp2614";
              mac = "c0:74:ad:00:02:01";
              lines = ["201" null null null null null "202"];
              settings = {
                P50602 = "10.0.20.11";
                P1362 = "en";
              };
            };
          };
        })."cfgc074ad000201.xml";
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <gs_provision version="1">
          <mac>c074ad000201</mac>
          <config version="1">
            <P2>${placeholderFor "/run/secrets/phone-admin"}</P2>
            <P30>10.0.20.1</P30>
            <P34>${placeholderFor "/run/secrets/201"}</P34>
            <P35>201</P35>
            <P36>201</P36>
            <P47>10.0.20.10</P47>
            <P64>CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00</P64>
            <P212>1</P212>
            <P237>10.0.20.10</P237>
            <P238>0</P238>
            <P271>1</P271>
            <P401>0</P401>
            <P501>0</P501>
            <P601>0</P601>
            <P1362>en</P1362>
            <P1409>0</P1409>
            <P1701>0</P1701>
            <P1801>0</P1801>
            <P50601>1</P50601>
            <P50602>10.0.20.11</P50602>
            <P50604>202</P50604>
            <P50605>kitchen</P50605>
            <P50606>${placeholderFor "/run/secrets/202"}</P50606>
            <P50701>0</P50701>
            <P50801>0</P50801>
            <P50901>0</P50901>
            <P51001>0</P51001>
            <P51101>0</P51101>
          </config>
        </gs_provision>
      '';
    };

    # the ports of an HT814 share profile 1's server; a null line and the ones
    # past the end of the list are turned off
    testGrandstreamHt814File = {
      expr =
        (texts {
          services.asterix.phones.devices.garage = {
            model = "grandstream-ht814";
            mac = "c0:74:ad:00:02:01";
            lines = ["201" null "202"];
          };
        })."cfgc074ad000201.xml";
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
      expr = map (adminPassword:
        lib.findFirst (lib.hasPrefix "    <P2>") null (lib.splitString "\n"
          (texts {
            services.asterix.phones = {
              inherit adminPassword;
              devices."201" = {
                model = "grandstream-ht801";
                mac = "c0:74:ad:00:02:01";
              };
            };
          })."cfgc074ad000201.xml")) [
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

    # every parameter the module sets for a Poly VVX, in natural order, in the
    # file the master file names; line 2 is past the end of lines, common
    # settings replace the module's values and the phone's settings replace
    # both
    testPolyVvxFiles = {
      expr = texts {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        services.asterix.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/poly-admin";
          poly.settings = {
            "feature.lens.enabled" = 1;
            "lcl.ml.lang" = "German_Germany";
          };
          devices."201" = {
            model = "poly-vvx150";
            mac = "64:16:7f:00:02:01";
            settings = {
              "lcl.ml.lang" = "English_United_Kingdom";
              "reg.1.label" = "Front & back";
            };
          };
        };
      };
      expected = {
        "64167f000201.cfg" = ''
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <APPLICATION APP_FILE_PATH="sip.ld" CONFIG_FILES="64167f000201-settings.cfg"/>
        '';
        "64167f000201-settings.cfg" = ''
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <polycomConfig
            device.auth.localAdminPassword="${placeholderFor "/run/secrets/poly-admin"}"
            device.auth.localAdminPassword.set="1"
            device.baseProfile="Generic"
            device.baseProfile.set="1"
            device.prov.serverName="http://10.0.20.10"
            device.prov.serverName.set="1"
            device.prov.serverType="HTTP"
            device.prov.serverType.set="1"
            device.prov.ztpEnabled="0"
            device.prov.ztpEnabled.set="1"
            device.set="1"
            feature.da.enabled="0"
            feature.lens.enabled="1"
            feature.obitalk.enabled="0"
            feature.pcc.enabled="0"
            lcl.ml.lang="English_United_Kingdom"
            reg.1.address="201"
            reg.1.auth.password="${placeholderFor "/run/secrets/201"}"
            reg.1.auth.userId="kitchen"
            reg.1.label="Front &amp; back"
            reg.1.server.1.address="10.0.20.10"
            reg.1.server.1.port="5060"
            reg.2.address=""
            tcpIpApp.sntp.address="10.0.20.1"
            tcpIpApp.sntp.address.overrideDHCP="1"
          />
        '';
      };
    };

    # every setting the module sets for a Snom D315, without an index first
    # and then by line, in a file named with the MAC address in capitals; the
    # auth user name may differ from the endpoint, a null line and the ones
    # past the end of the list are turned off, settings for every Snom replace
    # the module's and a phone's replace both, and are writable on the phone
    testSnomD315File = {
      expr = texts {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        services.asterix.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/snom-admin";
          snom = {
            timeZone = "GER+1";
            settings = {
              language = "Deutsch";
              update_policy = "auto_update";
            };
          };
          devices."201" = {
            model = "snom-d315";
            mac = "00:04:13:ab:cd:01";
            lines = ["201" null "202"];
            settings = {
              language = "English";
              "user_host[3]" = "10.0.20.11";
            };
          };
        };
      };
      expected = {
        "snomD315-000413ABCD01.htm" = ''
          <?xml version="1.0" encoding="utf-8"?>
          <settings>
            <phone-settings>
              <http_pass perm="R">${placeholderFor "/run/secrets/snom-admin"}</http_pass>
              <http_user perm="R">admin</http_user>
              <language perm="RW">English</language>
              <ntp_server perm="R">10.0.20.1</ntp_server>
              <setting_server perm="RW">http://10.0.20.10/snomD315-{mac}.htm</setting_server>
              <timezone perm="R">GER+1</timezone>
              <update_policy perm="RW">auto_update</update_policy>
              <tr369_enable idx="1" perm="R">false</tr369_enable>
              <user_active idx="1" perm="R">on</user_active>
              <user_host idx="1" perm="R">10.0.20.10</user_host>
              <user_name idx="1" perm="R">201</user_name>
              <user_pass idx="1" perm="R">${placeholderFor "/run/secrets/201"}</user_pass>
              <user_pname idx="1" perm="R">kitchen</user_pname>
              <user_active idx="2" perm="R">off</user_active>
              <user_active idx="3" perm="R">on</user_active>
              <user_host idx="3" perm="RW">10.0.20.11</user_host>
              <user_name idx="3" perm="R">202</user_name>
              <user_pass idx="3" perm="R">${placeholderFor "/run/secrets/202"}</user_pass>
              <user_pname idx="3" perm="R">202</user_pname>
              <user_active idx="4" perm="R">off</user_active>
            </phone-settings>
          </settings>
        '';
      };
    };

    # every key the module sets for a Yealink T33G, in natural order: a used
    # account with an auth user name of its own, a null line and one past the
    # end of lines; common settings replace the module's values and the
    # phone's settings replace both
    testYealinkT33gFile = {
      expr = texts {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        services.asterix.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/yealink-admin";
          yealink.settings = {
            "account.1.label" = "Kitchen";
            "lang.gui" = "German";
          };
          devices."201" = {
            model = "yealink-t33g";
            mac = "80:5e:c0:00:02:01";
            lines = ["201" null "202"];
            settings = {
              "account.3.sip_server.1.address" = "10.0.20.11";
              "lang.gui" = "English";
            };
          };
        };
      };
      expected = {
        "805ec0000201.cfg" = ''
          #!version:1.0.0.1
          account.1.auth_name = kitchen
          account.1.enable = 1
          account.1.label = Kitchen
          account.1.password = ${placeholderFor "/run/secrets/201"}
          account.1.sip_server.1.address = 10.0.20.10
          account.1.sip_server.1.port = 5060
          account.1.user_name = 201
          account.2.enable = 0
          account.3.auth_name = 202
          account.3.enable = 1
          account.3.password = ${placeholderFor "/run/secrets/202"}
          account.3.sip_server.1.address = 10.0.20.11
          account.3.sip_server.1.port = 5060
          account.3.user_name = 202
          account.4.enable = 0
          lang.gui = English
          local_time.ntp_server1 = 10.0.20.1
          static.auto_provision.server.url = http://10.0.20.10/
          static.dm.enable = 0
          static.security.user_password = admin:${placeholderFor "/run/secrets/yealink-admin"}
        '';
      };
    };
  };
}
