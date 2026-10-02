# Evaluation-only tests of the files pbx.phones writes for Poly phones.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # two phones' extensions, which each test adds a Poly phone for 201 to, a
  # VVX 150 unless a test says otherwise
  phone = module:
    evalConfig [
      ({config, ...}: let
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
              model = lib.mkDefault "poly-vvx150";
              mac = "64:16:7f:00:02:01";
            };
          };
        };
        services.asterisk.pjsip.transports.udp = {};
      })
      module
    ];

  files = config: lib.mapAttrs (_: file: file.text) config.pbx.phones.files;
in {
  run = lib.runTests;
  tests = {
    # every parameter the module sets for a VVX, in natural order; line 2 is
    # past the end of lines, common settings replace the module's values and
    # the phone's settings replace both
    testPolyVvxFiles = {
      expr = files (phone {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        pbx.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/poly-admin";
          poly.settings = {
            "feature.lens.enabled" = 1;
            "lcl.ml.lang" = "German_Germany";
          };
          devices."201".settings = {
            "lcl.ml.lang" = "English_United_Kingdom";
            "reg.1.label" = "Front & back";
          };
        };
      });
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

    # an Edge E leaves out the cloud switches only VVX documents; a null line
    # and the ones past the end are unused, the port goes into the URL of this
    # server and sipPort into a parameter of its own
    testPolyEdgeFiles = {
      expr = files (phone {
        pbx.phones = {
          port = 8080;
          sipServer = "10.0.20.11";
          sipPort = 5070;
          devices."201" = {
            model = "poly-edge-e100";
            lines = ["201" null "202"];
          };
        };
      });
      expected = {
        "64167f000201.cfg" = ''
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <APPLICATION APP_FILE_PATH="sip.ld" CONFIG_FILES="64167f000201-settings.cfg"/>
        '';
        "64167f000201-settings.cfg" = ''
          <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
          <polycomConfig
            device.baseProfile="Generic"
            device.baseProfile.set="1"
            device.prov.serverName="http://10.0.20.10:8080"
            device.prov.serverName.set="1"
            device.prov.serverType="HTTP"
            device.prov.serverType.set="1"
            device.set="1"
            feature.da.enabled="0"
            feature.obitalk.enabled="0"
            reg.1.address="201"
            reg.1.auth.password="${placeholderFor "/run/secrets/201"}"
            reg.1.auth.userId="201"
            reg.1.server.1.address="10.0.20.11"
            reg.1.server.1.port="5070"
            reg.2.address=""
            reg.3.address="202"
            reg.3.auth.password="${placeholderFor "/run/secrets/202"}"
            reg.3.auth.userId="202"
            reg.3.server.1.address="10.0.20.11"
            reg.3.server.1.port="5070"
            reg.4.address=""
            reg.5.address=""
            reg.6.address=""
            reg.7.address=""
            reg.8.address=""
          />
        '';
      };
    };
  };
}
