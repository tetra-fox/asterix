# Evaluation tests of the provisioning files of Fanvil phones.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  base = {config, ...}: let
    inherit (config.lib.asterisk) secret;
  in {
    imports = [self.nixosModules.pbx];
    pbx = {
      enable = true;
      extensions = {
        "201".password = secret "/run/secrets/201";
        "202".password = secret "/run/secrets/202";
      };
      phones = {
        listenAddress = lib.mkDefault "10.0.20.10";
        allowedNetworks = ["10.0.20.0/24"];
        devices."201" = {
          model = lib.mkDefault "fanvil-x303";
          mac = lib.mkDefault "0C:38:3E:00:02:01";
        };
      };
    };
    services.asterisk.pjsip.transports.udp = {};
  };

  # the files of a Fanvil X303 for extension 201, which each test adds to
  files = module: (evalConfig [base module]).pbx.phones.files;
in {
  run = lib.runTests;
  tests = {
    # every setting of the X303's four lines: a used line, a null one, a used
    # one with its own auth user name and one past the end of the list;
    # fanvil.settings replace the module's values and a device's settings
    # replace both
    testFanvilFile = {
      expr = lib.mapAttrs (_: file: {inherit (file) text escape allowedAddress;}) (files {
        services.asterisk.pjsip.endpoints."202".auth.username = "kitchen";
        pbx.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/fanvil-admin";
          fanvil.settings = {
            "ap.FlashMode" = 2;
            "phone.display.DefaultLanguage" = "de";
          };
          devices."201" = {
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
  };
}
