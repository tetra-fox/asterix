# Evaluation-only tests of the files pbx.phones writes for Yealink phones.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # two phones' extensions, which each test adds a Yealink phone for 201 to, a
  # T33G unless a test says otherwise
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
              model = lib.mkDefault "yealink-t33g";
              mac = "80:5e:c0:00:02:01";
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
    # every key the module sets for a T33G, in natural order: a used account
    # with an auth user name of its own, a null line and one past the end of
    # lines; common settings replace the module's values and the phone's
    # settings replace both
    testYealinkT33gFile = {
      expr = files (phone {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        pbx.phones = {
          ntpServer = "10.0.20.1";
          adminPassword = self.lib.secret "/run/secrets/yealink-admin";
          yealink.settings = {
            "account.1.label" = "Kitchen";
            "lang.gui" = "German";
          };
          devices."201" = {
            lines = ["201" null "202"];
            settings = {
              "account.3.sip_server.1.address" = "10.0.20.11";
              "lang.gui" = "English";
            };
          };
        };
      });
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

    # the Android phones get no device management setting
    testYealinkCp965File = {
      expr = files (phone {
        pbx.phones.devices."201".model = "yealink-cp965";
      });
      expected = {
        "805ec0000201.cfg" = ''
          #!version:1.0.0.1
          account.1.auth_name = 201
          account.1.enable = 1
          account.1.password = ${placeholderFor "/run/secrets/201"}
          account.1.sip_server.1.address = 10.0.20.10
          account.1.sip_server.1.port = 5060
          account.1.user_name = 201
          static.auto_provision.server.url = http://10.0.20.10/
        '';
      };
    };
  };
}
