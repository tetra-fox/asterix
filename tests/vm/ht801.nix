# HT801 provisioning for the household intercom, and the provisioning service
# under it: files are served on the VoIP address only, carry the endpoints'
# credentials (rendered at runtime, escaped per file format) and respect
# per-device address restrictions.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  address = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = pkgs.lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-ht801-provisioning";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ../../examples/household-intercom.nix
          ../../examples/household-intercom-ht801.nix
          ./common.nix
          (sopsSecrets {
            sip-101 = "ata-101-pw";
            sip-102 = "ata-102-pw";
            sip-201 = "soft-201-pw";
            sip-202 = "soft-202-pw";
            ht801-admin = ''a&b<c>"d'e'';
          })
          (address "lan" "10.0.10.10")
          (address "voip" "10.0.20.10")
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          voip.vlan = 2;
        };
        services.asterisk.provisioning = {
          # adapter 101 has a static lease
          grandstream.ht801.devices."101".allowedAddress = "10.0.20.21";
          # a hand-written file with the admin password, which is not escaped here
          files."notes.txt".text = "admin=${config.lib.asterisk.secret config.sops.secrets.ht801-admin.path}";
        };
      };

      adapters = {
        imports = [./common.nix];
        virtualisation.vlans = [2];
        # .21 is adapter 101's static lease; .22 is any other device
        networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [
          {
            address = "10.0.20.21";
            prefixLength = 24;
          }
          {
            address = "10.0.20.22";
            prefixLength = 24;
          }
        ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.libxml2
        ];
      };

      softphone = {
        imports = [
          ./common.nix
          (address "eth1" "10.0.10.21")
        ];
        virtualisation.vlans = [1];
        environment.systemPackages = [pkgs.curl];
      };
    };

    testScript = ''
      start_all()
      pbx.wait_for_unit("asterisk-provisioning.service")
      # nothing on the adapters node waits for network-online.target: wait for its addresses
      adapters.wait_until_succeeds("ip -o address show to 10.0.20.22 -tentative | grep -q .")
      adapters.wait_until_succeeds("ip -o address show to 10.0.20.21 -tentative | grep -q .")

      def fetch(name, source="10.0.20.21"):
          output = f"/tmp/{name or 'index'}"
          return adapters.succeed(
              f"curl -s --interface {source} -o {output} -w '%{{http_code}}' http://10.0.20.10/{name}"
          ).strip()

      with subtest("an adapter downloads its configuration with its credentials"):
          assert fetch("cfgc074ad000101.xml") == "200"
          adapters.succeed("xmllint --noout /tmp/cfgc074ad000101.xml")
          xml = adapters.succeed("cat /tmp/cfgc074ad000101.xml")
          for expected in [
              "<mac>c074ad000101</mac>",
              "<P271>1</P271>",
              "<P47>10.0.20.10</P47>",
              "<P35>101</P35>",
              "<P36>101</P36>",
              "<P34>ata-101-pw</P34>",
              "<P237>10.0.20.10</P237>",
              "<P238>2</P238>",
              "<P1409>0</P1409>",
              "<P2>a&amp;b&lt;c&gt;&quot;d&apos;e</P2>",
          ]:
              assert expected in xml, f"{expected} missing from {xml}"

      with subtest("secrets are only in the runtime copy"):
          renderer = pbx.succeed("systemctl cat asterisk-provisioning.service | grep -o '/nix/store/[^ ]*-asterisk-provisioning-render' | head -1").strip()
          # the renderer, the file templates it copies and the linkFarm of them
          paths = [p for p in pbx.succeed(f"nix-store -qR {renderer}").split() if "provisioning" in p or "-cfg" in p or "-notes.txt" in p]
          assert any(p.endswith("-cfgc074ad000101.xml") for p in paths), paths
          # exit status 1: searched everything, no match
          status, output = pbx.execute(f"grep -rl ata-101-pw {' '.join(paths)} 2>&1")
          assert status == 1, f"grep exited with {status}: {output}"
          pbx.succeed("test \"$(stat -c '%U %a' /run/asterisk-provisioning/cfgc074ad000101.xml)\" = 'asterisk-provisioning 400'")

      with subtest("a hand-written file gets the same secret unescaped"):
          assert fetch("notes.txt") == "200"
          notes = adapters.succeed("cat /tmp/notes.txt").strip()
          assert notes == "admin=a&b<c>\"d'e", notes

      with subtest("files are restricted to the adapter's address and unknown paths"):
          assert fetch("cfgc074ad000101.xml", source="10.0.20.22") == "403"
          assert fetch("cfgc074ad000102.xml", source="10.0.20.22") == "200"
          assert fetch("cfgc074ad999999.xml") == "404"
          assert fetch("") == "404"
          journal = pbx.succeed("journalctl -u asterisk-provisioning.service")
          assert "10.0.20.22 GET /cfgc074ad000101.xml 403" in journal, journal

      with subtest("nothing is served on the trusted LAN address"):
          softphone.fail("curl -s --max-time 5 http://10.0.10.10/cfgc074ad000102.xml")

      with subtest("the kernel drops connections from outside allowedNetworks"):
          # from the pbx itself: a source address inside 10.0.20.0/24 is let through,
          # 127.0.0.1 never gets a connection until the socket allows it
          url = "http://10.0.20.10/cfgc074ad000102.xml"
          pbx.succeed(f"curl -sf --max-time 5 --interface 10.0.20.10 -o /dev/null {url}")
          pbx.fail(f"curl -s --max-time 5 --interface 127.0.0.1 -o /dev/null {url}")
          pbx.succeed("systemctl set-property --runtime asterisk-provisioning.socket IPAddressAllow=127.0.0.1")
          pbx.succeed(f"curl -sf --max-time 5 --interface 127.0.0.1 -o /dev/null {url}")
    '';
  }
