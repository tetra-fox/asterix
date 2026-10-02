# Evaluation-only tests of the files of Cisco phones and adapters.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # extensions 201 and 202 and a device of a test's model on the phones'
  # network, which each test adds to
  files = module:
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
            listenAddress = lib.mkDefault "10.0.20.10";
            allowedNetworks = ["10.0.20.0/24"];
            devices.desk.mac = "00:62:ec:00:02:01";
          };
        };
        services.asterisk.pjsip.transports.udp = {};
      })
    ]).pbx.phones.files;

  device = module: (files module)."0062ec000201.xml".text;
in {
  run = lib.runTests;
  tests = {
    # a factory device fetches the file of its model from the server in DHCP
    # option 66, one for all devices of the model, which names the device's own
    # file in the rule it fetches next
    testCiscoBootstrapFiles = {
      expr = lib.mapAttrs (_: file: file.text) (lib.filterAttrs (_: file: file.tftp) (files {
        pbx.phones.devices = {
          desk = {
            model = "cisco-8841";
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

    # a phone with multiplatform firmware: a null line and the ones past the
    # end are turned off, the auth user may differ from the endpoint, common
    # settings replace the module's values and a device's settings replace
    # both
    testCiscoMultiplatformFile = {
      expr = device {
        services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
        pbx.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/phone-admin";
          cisco.settings = {
            Webex_Onboard_Enable = "Yes";
            Time_Zone = "GMT+01:00";
          };
          devices.desk = {
            model = "cisco-6841";
            lines = ["201" null "202"];
            settings = {
              Proxy_3_ = "10.0.20.11";
              Time_Zone = "GMT+02:00";
            };
          };
        };
      };
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

    # an adapter with a router: the admin password and NTP server go into the
    # router configuration, as does a setting given as a path, and the port
    # of the second line has an account of its own
    testCiscoRouterAdapterFile = {
      expr = device {
        pbx.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/phone-admin";
          devices.desk = {
            model = "cisco-ata191";
            lines = [null "202"];
            settings."router-configuration/Time_Setup/Time_Zone" = "+01 2 2";
          };
        };
      };
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

    # an SPA phone, provisioned from another port, with a plain admin
    # password escaped for XML
    testCiscoSpaFile = {
      expr = device {
        pbx.phones = {
          port = 8080;
          adminPassword = "a&b<c";
          devices.desk = {
            model = "cisco-spa504g";
            lines = ["201" null];
          };
        };
      };
      expected = ''
        <?xml version="1.0" encoding="UTF-8"?>
        <flat-profile>
          <Admin_Passwd>a&amp;b&lt;c</Admin_Passwd>
          <Auth_ID_1_>201</Auth_ID_1_>
          <Line_Enable_1_>Yes</Line_Enable_1_>
          <Line_Enable_2_>No</Line_Enable_2_>
          <Line_Enable_3_>No</Line_Enable_3_>
          <Line_Enable_4_>No</Line_Enable_4_>
          <Password_1_>${placeholderFor "/run/secrets/201"}</Password_1_>
          <Profile_Rule>http://10.0.20.10:8080/$MA.xml</Profile_Rule>
          <Profile_Rule_B></Profile_Rule_B>
          <Proxy_1_>10.0.20.10</Proxy_1_>
          <Use_Auth_ID_1_>Yes</Use_Auth_ID_1_>
          <User_ID_1_>201</User_ID_1_>
        </flat-profile>
      '';
    };
  };
}
