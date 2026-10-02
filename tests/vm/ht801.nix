# HT801 provisioning for the household intercom, and the provisioning service
# under it: files are served on the VoIP address only, carry the endpoints'
# credentials (rendered at runtime, escaped per file format) and respect
# per-device address restrictions. Hand-written files with odd names, a
# credential, 10 MB and many files are served as written, those marked for
# TFTP over it too; hostile requests get nothing they may not have, and 1,000
# idle connections from one client do not delay another. Adapters on pjsua register with the credentials of their
# files; a deploy that changes one's password reloads Asterisk and restarts
# the provisioning service, keeps the process, the calls and the
# registrations, and the adapter registers again with the password of its
# new file. A rotated secret is served after a restart, a missing one fails
# the unit; the socket is bound before its address exists. On :: and port
# 8080, the adapters are sent to the PBX's address, IPv6 and IPv4-mapped peers
# are told apart and the firewall is open on the phones' interface only.
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

  # 10 MiB of text, and 100 small files (1,000 take 24 s more to build, and 7 s
  # more at each start of the unit)
  big = lib.strings.replicate (10 * 1024 * 1024 / 64) (lib.strings.replicate 63 "x" + "\n");
  sample = map (i: "file${toString i}.cfg") (lib.range 1 100);

  # opens N connections from 10.0.20.22 that send nothing, then fetches
  # adapter 101's file from 10.0.20.21 and prints how long that took
  idleClients = pkgs.writeText "idle-clients.py" ''
    import socket
    import sys
    import time

    server = ("10.0.20.10", 80)
    idle = []
    for _ in range(int(sys.argv[1])):
        s = socket.socket()
        s.bind(("10.0.20.22", 0))
        s.connect(server)
        idle.append(s)
    started = time.monotonic()
    s = socket.create_connection(server, timeout=5, source_address=("10.0.20.21", 0))
    s.sendall(b"GET /cfgc074ad000101.xml HTTP/1.1\r\nHost: 10.0.20.10\r\n\r\n")
    response = b""
    while chunk := s.recv(65536):
        response += chunk
    assert response.startswith(b"HTTP/1.1 200 OK"), response[:100]
    print(time.monotonic() - started)
  '';
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-ht801-provisioning";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret credential;
      in {
        imports = [
          self.nixosModules.pbx
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
        networking.interfaces.voip.ipv6.addresses = [
          {
            address = "fd00:20::10";
            prefixLength = 64;
          }
        ];
        pbx.phones = {
          devices = {
            # adapter 101 has a static lease
            "101".allowedAddress = "10.0.20.21";
            # a Cisco phone on 10.0.20.22, whose model's file goes over TFTP
            desk = {
              model = "cisco-8841";
              mac = "00:62:ec:00:02:01";
              lines = ["201"];
              allowedAddress = "10.0.20.22";
            };
          };
          files =
            {
              # the admin password as it is, and escaped for XML for one other
              # device only
              "notes.txt".text = "admin=${secret config.sops.secrets.ht801-admin.path}";
              "phone.xml" = {
                text = "<password>${secret config.sops.secrets.ht801-admin.path}</password>\n";
                escape = "xml";
                allowedAddress = "10.0.20.22";
              };
              # a name gawk and mv would take for an option or standard input
              "-".text = "sip=${secret config.sops.secrets.sip-101.path}\n";
              # a credential the unit is given by the configuration, not the module
              "credential.txt".text = "pin=${credential "provisioning-pin"}";
              "big.txt".text = big;
              # over TFTP too, to 10.0.20.22 only
              "tftp-22.cfg" = {
                text = "for 22\n";
                tftp = true;
                allowedAddress = "10.0.20.22";
              };
            }
            // lib.genAttrs sample (name: {text = name;});
        };
        systemd.services.asterisk-provisioning.serviceConfig.SetCredential = "provisioning-pin:4711";

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

        # :: takes IPv4 clients too, which the server sees as ::ffff:a.b.c.d;
        # the LAN may connect, so only the firewall keeps it out. The adapters
        # are sent to the PBX's address, since they cannot connect to ::
        specialisation.dualstack.configuration.pbx.phones = {
          listenAddress = lib.mkForce "::";
          port = 8080;
          sipServer = "10.0.20.10";
          grandstream.settings.P237 = "10.0.20.10:8080";
          cisco.settings.Profile_Rule = "http://10.0.20.10:8080/$MA.xml";
          allowedNetworks = lib.mkForce [
            "10.0.20.0/24"
            "10.0.10.0/24"
            "fd00:20::/64"
          ];
          files."v6.txt" = {
            text = "for fd00:20::21";
            allowedAddress = "fd00:20::21";
          };
        };
      };

      adapters = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        virtualisation.vlans = [2];
        # .21 is adapter 101's static lease; .22 is any other device
        networking.interfaces.eth1 = {
          ipv4.addresses = lib.mkForce [
            {
              address = "10.0.20.21";
              prefixLength = 24;
            }
            {
              address = "10.0.20.22";
              prefixLength = 24;
            }
          ];
          ipv6.addresses = [
            {
              address = "fd00:20::21";
              prefixLength = 64;
            }
            {
              address = "fd00:20::22";
              prefixLength = 64;
            }
          ];
        };
        environment.systemPackages = [
          pkgs.curl
          pkgs.libxml2
          pkgs.python3
        ];
      };

      softphone = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.0.10.21")
        ];
        virtualisation.vlans = [1];
        environment.systemPackages = [pkgs.curl];
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
        # nothing on the adapters node waits for network-online.target: wait for its addresses
        for address in ["10.0.20.21", "10.0.20.22", "fd00:20::21", "fd00:20::22"]:
            adapters.wait_until_succeeds(f"ip -o address show to {address} -tentative | grep -q .")

        def fetch(name, source="10.0.20.21", server="10.0.20.10"):
            output = f"/tmp/{name or 'index'}"
            return adapters.succeed(
                f"curl -sg --interface {source} -o {output} -w '%{{http_code}}' http://{server}/{name}"
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
                "<P2>a&amp;b&lt;c&gt;&quot;d&apos;e]]&gt;</P2>",
            ]:
                assert expected in xml, f"{expected} missing from {xml}"

        def provisioned(ext, source="10.0.20.21"):
            """The P-values of adapter `ext`'s file, as the adapter fetches it."""
            assert fetch(f"cfgc074ad000{ext}.xml", source) == "200"
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

        with subtest("the provisioning units run, with one file per adapter that only their user reads"):
            pbx.succeed("systemctl is-active asterisk-provisioning.socket asterisk-provisioning.service")
            files = pbx.succeed("stat -c '%A %U %n' /run/asterisk-provisioning/cfg*.xml").splitlines()
            assert files == [
                f"-r-------- asterisk-provisioning /run/asterisk-provisioning/cfgc074ad000{ext}.xml" for ext in ["101", "102"]
            ], files

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
            for phone in [*ata.values(), soft]:
                phone.stop()

        with subtest("secrets are only in the runtime copy"):
            renderer = pbx.succeed("systemctl cat asterisk-provisioning.service | grep -o '/nix/store/[^ ]*-asterisk-provisioning-render' | head -1").strip()
            # the renderer, the file templates it copies and the linkFarm of them
            paths = [p for p in pbx.succeed(f"nix-store -qR {renderer}").split() if "provisioning" in p or "-cfg" in p or "-notes.txt" in p]
            assert any(p.endswith("-cfgc074ad000101.xml") for p in paths), paths
            # exit status 1: searched everything, no match
            status, output = pbx.execute(f"grep -rl ata-101-pw {' '.join(paths)} 2>&1")
            assert status == 1, f"grep exited with {status}: {output}"
            pbx.succeed("test \"$(stat -c '%U %a' /run/asterisk-provisioning/cfgc074ad000101.xml)\" = 'asterisk-provisioning 400'")

        with subtest("hand-written files are served as written"):
            assert fetch("notes.txt") == "200"
            notes = adapters.succeed("cat /tmp/notes.txt")
            assert notes == "admin=a&b<c>\"d'e]]>", notes
            assert fetch("phone.xml") == "403"
            assert fetch("phone.xml", source="10.0.20.22") == "200"
            adapters.succeed("xmllint --noout /tmp/phone.xml")
            phone = adapters.succeed("cat /tmp/phone.xml")
            assert phone == "<password>a&amp;b&lt;c&gt;&quot;d&apos;e]]&gt;</password>\n", phone
            assert fetch("-") == "200"
            dash = adapters.succeed("cat /tmp/-")
            assert dash == "sip=ata-101-pw\n", dash
            assert fetch("credential.txt") == "200"
            pin = adapters.succeed("cat /tmp/credential.txt")
            assert pin == "pin=4711", pin
            assert fetch("big.txt") == "200"
            digest = adapters.succeed("sha256sum < /tmp/big.txt").split()[0]
            assert digest == "${builtins.hashString "sha256" big}", digest
            files = adapters.succeed("curl -sf --interface 10.0.20.21 'http://10.0.20.10/file[1-${toString (lib.length sample)}].cfg'")
            assert files == "${lib.concatStrings sample}", files

        with subtest("files are restricted to the adapter's address and unknown paths"):
            assert fetch("cfgc074ad000101.xml", source="10.0.20.22") == "403"
            assert fetch("cfgc074ad000102.xml", source="10.0.20.22") == "200"
            assert fetch("cfgc074ad999999.xml") == "404"
            assert fetch("") == "404"
            journal = pbx.succeed("journalctl --sync && journalctl -u asterisk-provisioning.service")
            assert "10.0.20.22 GET /cfgc074ad000101.xml 403" in journal, journal

        def tftp(name, source="10.0.20.21"):
            return adapters.execute(f"curl -s --max-time 10 --interface {source} -o /tmp/tftp tftp://10.0.20.10/{name}")[0]

        with subtest("files marked for TFTP are served over it to the addresses allowed, other files are not"):
            # curl's exit codes for a TFTP access violation and a file TFTP does not have
            assert tftp("tftp-22.cfg") == 69
            assert tftp("tftp-22.cfg", source="10.0.20.22") == 0
            assert adapters.succeed("cat /tmp/tftp") == "for 22\n"
            assert tftp("cfgc074ad000102.xml") == 68
            journal = pbx.succeed("journalctl --sync && journalctl -u asterisk-provisioning.service")
            assert "10.0.20.21 TFTP tftp-22.cfg forbidden" in journal, journal

        with subtest("a factory Cisco phone fetches its model's file over TFTP, which sends it to its own file over HTTP"):
            # the phone's default rule names the file from the root, /$PSN.xml
            assert tftp("/8841-3PCC.xml", source="10.0.20.22") == 0
            bootstrap = adapters.succeed("cat /tmp/tftp")
            found = re.search(r"<Profile_Rule_B>([^<]*)</Profile_Rule_B>", bootstrap)
            assert found, bootstrap
            rule = found.group(1)
            assert rule == "http://10.0.20.10/$MA.xml", bootstrap
            profile = adapters.succeed(f"curl -sf --interface 10.0.20.22 {rule.replace('$MA', '0062ec000201')}")
            for expected in [
                "<User_ID_1_>201</User_ID_1_>",
                "<Password_1_>soft-201-pw</Password_1_>",
                "<Profile_Rule>http://10.0.20.10/$MA.xml</Profile_Rule>",
                "<Profile_Rule_B></Profile_Rule_B>",
            ]:
                assert expected in profile, f"{expected} missing from {profile}"

        with subtest("hostile requests get no file they may not have and do not delay others"):
            def http_code(arguments, source="10.0.20.22"):
                return adapters.succeed(
                    f"curl -s --interface {source} -o /dev/null -w '%{{http_code}}' {arguments}"
                ).strip()
            # a request in absolute form names a host, which is not a way around the address
            assert http_code("--request-target http://elsewhere/cfgc074ad000101.xml http://10.0.20.10/") == "403"
            # curl removes dot segments, even encoded ones, unless told not to
            assert http_code("--path-as-is http://10.0.20.10/../cfgc074ad000102.xml") == "404"
            assert http_code("--path-as-is http://10.0.20.10/%2e%2e/cfgc074ad000102.xml") == "404"
            assert http_code("-X POST http://10.0.20.10/cfgc074ad000102.xml") == "405"
            # hyper answers a request head over 16 KiB with 431, or the reset of
            # closing the rest of it unread reaches curl first
            assert http_code("http://10.0.20.10/$(head -c 65536 /dev/zero | tr '\\0' a)") != "200"
            pid = pbx.succeed("systemctl show -P MainPID asterisk-provisioning.service")
            waited = float(adapters.succeed("ulimit -n 4096; python3 ${idleClients} 1000"))
            print(f"10.0.20.21 waited {waited:.3f} s behind 1,000 idle connections")
            assert "10.0.20.22: too many connections" in pbx.succeed("journalctl --sync && journalctl -u asterisk-provisioning.service")
            assert pbx.succeed("systemctl show -P MainPID asterisk-provisioning.service") == pid

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
            # set-property wrote the whole list into a drop-in, which would
            # replace the list of the configuration switched to below
            pbx.succeed("rm -r /run/systemd/system.control/asterisk-provisioning.socket.d")
            pbx.succeed("systemctl daemon-reload")

        with subtest("a rotated secret is served after a restart, a missing one fails the unit"):
            # what sops-nix does with restartUnits (the example) when a secret changes
            pbx.succeed("printf rotated-102 > /run/secrets/sip-102")
            pbx.succeed("systemctl restart asterisk-provisioning.service")
            assert fetch("cfgc074ad000102.xml") == "200"
            xml = adapters.succeed("cat /tmp/cfgc074ad000102.xml")
            assert "<P34>rotated-102</P34>" in xml, xml
            pbx.succeed("mv /run/secrets/sip-102 /run/sip-102")
            cursor = pbx.succeed("journalctl --sync && journalctl -n 0 --show-cursor | sed -n 's/^-- cursor: //p'").strip()
            pbx.fail("systemctl restart asterisk-provisioning.service")
            # it fails before the renderer runs; systemd names the file it
            # missed only at debug level (src/core/exec-credential.c:736)
            pbx.wait_until_succeeds("systemctl is-failed asterisk-provisioning.service")
            status = pbx.execute("systemctl status asterisk-provisioning.service")[1]
            assert "status=243/CREDENTIALS" in status, status
            journal = pbx.succeed(f"journalctl --sync && journalctl -u asterisk-provisioning.service --after-cursor '{cursor}'")
            assert "Failed to set up credentials: No such file or directory" in journal, journal
            pbx.succeed("mv /run/sip-102 /run/secrets/sip-102")
            pbx.succeed("systemctl reset-failed asterisk-provisioning.service asterisk-provisioning.socket")
            pbx.succeed("systemctl restart asterisk-provisioning.service")
            assert fetch("cfgc074ad000102.xml") == "200"

        with subtest("the socket is bound before its address exists and serves once it does"):
            # stopping the socket stops the service, which requires it
            pbx.succeed("systemctl stop asterisk-provisioning.socket")
            pbx.succeed("ip address del 10.0.20.10/24 dev voip")
            pbx.succeed("systemctl start asterisk-provisioning.socket asterisk-provisioning.service")
            pbx.succeed("ss -Hltn | grep -F 10.0.20.10:80")
            pbx.succeed("ip address add 10.0.20.10/24 dev voip")
            assert fetch("cfgc074ad000101.xml") == "200"

        with subtest("on :: and port 8080, adapters get the PBX's address and IPv6 and IPv4-mapped peers are told apart"):
            pbx.wait_until_succeeds("ip -o address show to fd00:20::10 -tentative | grep -q .")
            pbx.succeed(f"{base}/specialisation/dualstack/bin/switch-to-configuration test")
            pbx.wait_for_unit("asterisk-provisioning.service")
            assert fetch("cfgc074ad000101.xml", server="10.0.20.10:8080") == "200"
            xml = adapters.succeed("cat /tmp/cfgc074ad000101.xml")
            assert "<P47>10.0.20.10</P47>" in xml and "<P237>10.0.20.10:8080</P237>" in xml, xml
            assert fetch("cfgc074ad000101.xml", source="10.0.20.22", server="10.0.20.10:8080") == "403"
            assert fetch("v6.txt", source="fd00:20::21", server="[fd00:20::10]:8080") == "200"
            assert fetch("v6.txt", source="fd00:20::22", server="[fd00:20::10]:8080") == "403"
            assert fetch("cfgc074ad000101.xml", source="fd00:20::21", server="[fd00:20::10]:8080") == "403"
            journal = pbx.succeed("journalctl --sync && journalctl -u asterisk-provisioning.service")
            assert "::ffff:10.0.20.22 GET /cfgc074ad000101.xml 403" in journal, journal
            assert "fd00:20::22 GET /v6.txt 403" in journal, journal

        with subtest("the firewall is open on the phones' interface only"):
            url = "http://10.0.10.10:8080/cfgc074ad000102.xml"
            bootstrap_url = "tftp://10.0.10.10/8841-3PCC.xml"
            softphone.fail(f"curl -s --max-time 3 {url}")
            softphone.fail(f"curl -s --max-time 3 -o /dev/null {bootstrap_url}")
            # the sockets would take them: only the firewall keeps the LAN out
            pbx.succeed("iptables -I nixos-fw -i lan -p tcp --dport 8080 -j nixos-fw-accept")
            pbx.succeed("iptables -I nixos-fw -i lan -p udp --dport 69 -j nixos-fw-accept")
            softphone.succeed(f"curl -sf --max-time 3 -o /dev/null {url}")
            softphone.succeed(f"curl -sf --max-time 3 -o /dev/null {bootstrap_url}")
      '';
  }
