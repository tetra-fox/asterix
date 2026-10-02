# Evaluation tests of the files the Snom module writes.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig placeholderFor;

  # two extensions on the phones' network
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
        listenAddress = "10.0.20.10";
        allowedNetworks = ["10.0.20.0/24"];
      };
    };
    services.asterisk.pjsip.transports.udp = {};
  };

  # the text of every file, by name, with a phone of `model` for extension
  # 201, which each test adds to
  files = model: module:
    lib.mapAttrs (_: file: file.text)
    (evalConfig [
      base
      module
      {
        pbx.phones.devices."201" = {
          inherit model;
          mac = "00:04:13:00:02:01";
        };
      }
    ]).pbx.phones.files;
in {
  run = lib.runTests;
  tests = {
    # every setting the module sets, without an index first and then by line;
    # the auth user name may differ from the endpoint, a null line and the
    # ones past the end of the list are turned off, settings for every Snom
    # replace the module's and a phone's replace both, and are writable on the
    # phone
    testSnomD315File = {
      expr = files "snom-d315" {
        services.asterisk.pjsip.endpoints."201".auth.username = "kitchen";
        pbx.phones = {
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
            lines = ["201" null "202"];
            settings = {
              language = "English";
              "user_host[3]" = "10.0.20.11";
            };
          };
        };
      };
      expected = {
        "snomD315-000413000201.htm" = ''
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

    # the D86x's Phone Manager gets the admin login too; the setting server
    # has the port when it is not 80
    testSnomD862File = {
      expr = files "snom-d862" {
        pbx.phones = {
          port = 8080;
          adminPassword = "a&b";
        };
      };
      expected = {
        "snomD862-000413000201.htm" = ''
          <?xml version="1.0" encoding="utf-8"?>
          <settings>
            <phone-settings>
              <http_pass perm="R">a&amp;b</http_pass>
              <http_user perm="R">admin</http_user>
              <setting_server perm="RW">http://10.0.20.10:8080/snomD862-{mac}.htm</setting_server>
              <update_policy perm="R">settings_only</update_policy>
              <webserver_admin_name perm="R">admin</webserver_admin_name>
              <webserver_admin_password perm="R">a&amp;b</webserver_admin_password>
              <tr369_enable idx="1" perm="R">false</tr369_enable>
              <user_active idx="1" perm="R">on</user_active>
              <user_host idx="1" perm="R">10.0.20.10</user_host>
              <user_name idx="1" perm="R">201</user_name>
              <user_pass idx="1" perm="R">${placeholderFor "/run/secrets/201"}</user_pass>
              <user_pname idx="1" perm="R">201</user_pname>
              <user_active idx="2" perm="R">off</user_active>
              <user_active idx="3" perm="R">off</user_active>
              <user_active idx="4" perm="R">off</user_active>
              <user_active idx="5" perm="R">off</user_active>
              <user_active idx="6" perm="R">off</user_active>
              <user_active idx="7" perm="R">off</user_active>
              <user_active idx="8" perm="R">off</user_active>
            </phone-settings>
          </settings>
        '';
      };
    };

    # the D120's last firmware has no tr369_enable
    testSnomD120File = {
      expr = files "snom-d120" {};
      expected = {
        "snomD120-000413000201.htm" = ''
          <?xml version="1.0" encoding="utf-8"?>
          <settings>
            <phone-settings>
              <setting_server perm="RW">http://10.0.20.10/snomD120-{mac}.htm</setting_server>
              <update_policy perm="R">settings_only</update_policy>
              <user_active idx="1" perm="R">on</user_active>
              <user_host idx="1" perm="R">10.0.20.10</user_host>
              <user_name idx="1" perm="R">201</user_name>
              <user_pass idx="1" perm="R">${placeholderFor "/run/secrets/201"}</user_pass>
              <user_pname idx="1" perm="R">201</user_pname>
              <user_active idx="2" perm="R">off</user_active>
            </phone-settings>
          </settings>
        '';
      };
    };
  };
}
