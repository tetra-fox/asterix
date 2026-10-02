# Evaluation-only tests of the Grandstream phones' files; the adapters' are
# in eval.nix.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # extensions 201 and 202 and a phone of a test's model on the phones'
  # network, which each test adds to
  phone = module:
    (evalConfig [
      ({config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [self.nixosModules.pbx module];
        pbx = {
          enable = true;
          extensions = {
            "201".password = secret "/run/secrets/201";
            "202".password = secret "/run/secrets/202";
          };
          phones = {
            listenAddress = "10.0.20.10";
            allowedNetworks = ["10.0.20.0/24"];
            devices.desk.mac = "c0:74:ad:00:02:01";
          };
        };
        services.asterisk.pjsip.transports.udp = {};
      })
    ]).pbx.phones.files."cfgc074ad000201.xml".text;
in {
  run = lib.runTests;
  tests = {
    # accounts 2 to 6 and 7 to 16 follow their own P-values; a null line and
    # the ones past the end are turned off; common settings replace the
    # module's values and a phone's settings replace both
    testGrandstreamPhoneFile = {
      expr = phone {
        services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
        pbx.phones = {
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
            lines = ["201" null null null null null "202"];
            settings = {
              P50602 = "10.0.20.11";
              P1362 = "en";
            };
          };
        };
      };
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

    # the GRP260x has accounts 5 and 6 at P701 and P801
    testGrandstreamGrp260xFile = {
      expr = phone {
        pbx.phones.devices.desk = {
          model = "grandstream-grp2603";
          lines = ["201" null null null "202"];
        };
      };
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
            <P401>0</P401>
            <P501>0</P501>
            <P601>0</P601>
            <P701>1</P701>
            <P702>10.0.20.10</P702>
            <P704>202</P704>
            <P705>202</P705>
            <P706>${placeholderFor "/run/secrets/202"}</P706>
            <P801>0</P801>
            <P1409>0</P1409>
          </config>
        </gs_provision>
      '';
    };

    # the GXP16xx and GXP17xx have no TR-069 setting, and the Android phones
    # take another kind of time zone, so they get no P1409 and no P64
    # respectively
    testGrandstreamGxpAndAndroidFiles = {
      expr = map (model:
        phone {
          pbx.phones = {
            grandstream.timeZone = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
            devices.desk = {
              inherit model;
              lines = ["201"];
            };
          };
        }) ["grandstream-gxp1620" "grandstream-wp820"];
      expected = [
        ''
          <?xml version="1.0" encoding="UTF-8"?>
          <gs_provision version="1">
            <mac>c074ad000201</mac>
            <config version="1">
              <P34>${placeholderFor "/run/secrets/201"}</P34>
              <P35>201</P35>
              <P36>201</P36>
              <P47>10.0.20.10</P47>
              <P64>CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00</P64>
              <P212>1</P212>
              <P237>10.0.20.10</P237>
              <P238>2</P238>
              <P271>1</P271>
              <P401>0</P401>
            </config>
          </gs_provision>
        ''
        ''
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
              <P401>0</P401>
              <P1409>0</P1409>
            </config>
          </gs_provision>
        ''
      ];
    };
  };
}
