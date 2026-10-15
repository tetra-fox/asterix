# HT801 provisioning for the household intercom: each adapter's file carries
# its endpoint's credentials and the admin password, rendered at runtime and
# escaped for XML, only the provisioning user reads it, and no secret is in
# the store. Adapters on pjsua register with the credentials of their files;
# a deploy that changes one's password reloads Asterisk and restarts the
# provisioning service, keeps the process, the calls and the registrations,
# and the adapter registers again with the password of its new file.
{
  pkgs,
  self,
  sopsSecrets,
}: let
  inherit (pkgs) lib;

  address = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = lib.mkForce [
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
            ht801-admin = ''a&b<c>"d'e]]>'';
          })
          (address "lan" "10.0.10.10")
          (address "voip" "10.0.20.10")
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          voip.vlan = 2;
        };

        # a deploy that changes adapter 102's password: the same secrets file,
        # encrypted for the same key, which tests/sops.nix keeps next to it
        specialisation.rotated.configuration.sops.defaultSopsFile = let
          file = config.sops.defaultSopsFile;
          key = "${dirOf file}/key.txt";
        in
          lib.mkForce (pkgs.runCommand "asterisk-test-sops-rotated.yaml"
            {
              nativeBuildInputs = [
                pkgs.age
                pkgs.jq
                pkgs.sops
              ];
            }
            ''
              SOPS_AGE_KEY_FILE=${key} sops --decrypt --input-type yaml --output-type json ${file} \
                | jq '.["sip-102"] = "rotated-102-by-deploy"' > secrets.json
              sops --encrypt --age "$(age-keygen -y ${key})" --input-type json --output-type yaml secrets.json > $out
            '');
      };

      adapters = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.0.20.21")
        ];
        virtualisation.vlans = [2];
        environment.systemPackages = [
          pkgs.curl
          pkgs.libxml2
        ];
      };

      softphone = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.0.10.21")
        ];
        virtualisation.vlans = [1];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk-provisioning.service")
        base = pbx.succeed("readlink -f /run/current-system").strip()
        # nothing on the adapters node waits for network-online.target: wait for its address
        adapters.wait_until_succeeds("ip -o address show to 10.0.20.21 -tentative | grep -q .")

        def fetch(name):
            return adapters.succeed(
                f"curl -s --interface 10.0.20.21 -o /tmp/{name} -w '%{{http_code}}' http://10.0.20.10/{name}"
            ).strip()

        def provisioned(ext):
            """The P-values of adapter `ext`'s file, as the adapter fetches it."""
            assert fetch(f"cfgc074ad000{ext}.xml") == "200"
            xml = adapters.succeed(f"cat /tmp/cfgc074ad000{ext}.xml")
            return dict(re.findall(r"<(P\d+)>([^<]*)</P\d+>", xml))

        def adapter(ext, sip_port, cli_port):
            """A pjsua on the adapters' machine with the account adapter `ext`
            fetched: server, user and authentication ID, and password."""
            values = provisioned(ext)
            assert values["P35"] == values["P36"] == ext, values
            return Phone(adapters, ext, values["P35"], values["P34"], values["P47"], sip_port=sip_port, cli_port=cli_port)

        def hear_each_other(a, b):
            wait_hears(a, [b.tone])
            wait_hears(b, [a.tone])

        with subtest("an adapter downloads its configuration with its credentials"):
            assert fetch("cfgc074ad000101.xml") == "200"
            adapters.succeed("xmllint --noout /tmp/cfgc074ad000101.xml")
            xml = adapters.succeed("cat /tmp/cfgc074ad000101.xml")
            for expected in [
                "<P34>ata-101-pw</P34>",
                "<P2>a&amp;b&lt;c&gt;&quot;d&apos;e]]&gt;</P2>",
            ]:
                assert expected in xml, f"{expected} missing from {xml}"

        with subtest("each adapter's file is only readable by the provisioning user, and the secrets are only in that runtime copy"):
            pbx.succeed("systemctl is-active asterisk-provisioning.socket asterisk-provisioning.service")
            files = pbx.succeed("stat -c '%A %U %n' /run/asterisk-provisioning/cfg*.xml").splitlines()
            assert files == [
                f"-r-------- asterisk-provisioning /run/asterisk-provisioning/cfgc074ad000{ext}.xml" for ext in ["101", "102"]
            ], files
            renderer = pbx.succeed("systemctl cat asterisk-provisioning.service | grep -o '/nix/store/[^ ]*-asterisk-provisioning-render' | head -1").strip()
            # the renderer, the file templates it copies and the linkFarm of them
            paths = [p for p in pbx.succeed(f"nix-store -qR {renderer}").split() if "provisioning" in p or "-cfg" in p]
            assert any(p.endswith("-cfgc074ad000101.xml") for p in paths), paths
            # exit status 1: searched everything, no match
            status, output = pbx.execute(f"grep -rl ata-101-pw {' '.join(paths)} 2>&1")
            assert status == 1, f"grep exited with {status}: {output}"

        with subtest("adapters on pjsua register with the credentials of their files, and one calls a softphone"):
            ata = {"101": adapter("101", 5060, 2300), "102": adapter("102", 5061, 2301)}
            soft = Phone(softphone, "201", "201", "soft-201-pw", "10.0.10.10", sip_port=5060, cli_port=2300)
            start_phones([*ata.values(), soft])
            wait_registrations({ata["101"]: 200, ata["102"]: 200, soft: 200})
            ata["101"].call("201")
            wait_bridged(pbx, "101", "201")
            hear_each_other(ata["101"], soft)

        with subtest("a deploy that changes an adapter's password reloads Asterisk and restarts provisioning, keeps the process, the call and the registrations, and the adapter registers with the password of its new file"):
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service")
            talking = {c["name"] for c in channels(pbx)}
            cursor = journal_cursor(pbx)
            output = pbx.succeed(f"{base}/specialisation/rotated/bin/switch-to-configuration test 2>&1")
            print(output)
            acted = {
                line.split(" the following units: ")[0]: line.split(": ", 1)[1].split(", ")
                for line in output.splitlines()
                if " the following units: " in line
            }
            # sops-nix's reloadUnits and restartUnits of the two examples
            assert "asterisk.service" in acted.get("reloading", []), output
            assert "asterisk-provisioning.service" in acted.get("restarting", []), output
            assert all("asterisk.service" not in acted.get(a, []) for a in ["stopping", "starting", "restarting"]), output
            wait_journal(pbx, cursor, "asterisk-config: module reload res_pjsip.so")
            assert "rotated-102-by-deploy" in asterisk(pbx, "pjsip show auth 102")
            assert pbx.succeed("systemctl show -P MainPID asterisk.service") == pid, "asterisk was restarted"
            assert {c["name"] for c in channels(pbx)} == talking
            hear_each_other(ata["101"], soft)
            contacts = asterisk(pbx, "pjsip show contacts")
            for ext in ["101", "102", "201"]:
                assert f"Contact:  {ext}/sip:{ext}@" in contacts, contacts
            # the adapter reboots and fetches its new file
            ata["102"].stop()
            ata["102"] = adapter("102", 5062, 2302)
            assert ata["102"].password == "rotated-102-by-deploy"
            start_phones([ata["102"]])
            wait_registrations({ata["102"]: 200})
            cli_parallel([(ata["101"], "call hangup_all")])
            wait_idle(pbx)
      '';
  }
