# What an intruder on the phone network, dialplan code and local users can
# reach on a pbx: requests for extensions that exist and don't get the same
# answers, every wrong password is logged in a form fail2ban's asterisk
# filter matches, malformed SIP and SDP leave Asterisk running without its
# memory growing, the principals that can read secrets are the ones the
# README names, programs the dialplan starts write only to Asterisk's
# directories and read nothing of /home or other units' secrets (D16), and
# calls over the trunk, from its address or with its line, reach none of the
# numbers that go out when a phone dials them (SEC-03).
#
#   pbx       10.3.0.10
#   intruder  10.3.0.66, and 10.3.0.67, which the pbx's SIP ACL denies, and
#             10.3.0.5, the trunk's provider
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # what a program the dialplan starts can write and read, reported to
  # /var/lib/asterisk/probe-$1
  sandboxProbe = pkgs.writeShellApplication {
    name = "sandbox-probe";
    runtimeInputs = [pkgs.coreutils];
    text = ''
      {
        for dir in /var/lib/asterisk /var/log/asterisk /run/asterisk /tmp /var/tmp /dev/shm \
          /var/lib/drop /srv/drop /home/visitor /root /etc /run /var/lib /var/spool /nix/store; do
          if touch "$dir/written-by-$1" 2> /dev/null; then
            echo "write $dir"
          fi
        done
        for file in /home/visitor/notes /run/test-secrets/neighbor /run/credentials/neighbor.service/token \
          /var/lib/neighbor/token /var/lib/private/neighbor/token; do
          if cat "$file" > /dev/null 2>&1; then
            echo "read $file"
          fi
        done
      } > "/var/lib/asterisk/probe-$1.part"
      mv "/var/lib/asterisk/probe-$1.part" "/var/lib/asterisk/probe-$1"
    '';
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-security";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
      in {
        imports = [
          self.nixosModules.pbx
          ./common.nix
          (import ./secrets.nix {
            fixed = {
              sip-201 = "pw-201";
              sip-202 = "pw-202";
              sip-203 = "pw-203";
              sip-sipp = "pw-sipp";
              sip-trunk = "trunk-password";
              vm-201 = "4201";
              ami-dialer = "ami-dialer-pw";
              ami-monitor = "ami-monitor-pw";
              ami-admin = "ami-admin-pw";
              ari-viewer = "ari-viewer-pw";
              neighbor = "neighbor-token";
            };
          })
        ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "10.3.0.10";
            prefixLength = 24;
          }
        ];

        pbx = {
          enable = true;
          extensions = {
            "201" = {
              password = secret "sip-201";
              voicemail.pin = secret "vm-201";
            };
            "202".password = secret "sip-202";
            # forwards to an outside number when it does not answer
            "203" = {
              password = secret "sip-203";
              noAnswer.ringGroup = "cell";
            };
          };
          ringGroups.cell = {
            members = ["202"];
            external = ["5559000"];
          };
          ivrs.main = {
            number = "700";
            prompt.sound = "beep";
            directDial = true;
            options."1".ringGroup = "cell";
          };
          outbound = {
            prefix = "9";
            trunk = "provider";
          };
          emergency = {
            numbers = ["911"];
            trunk = "provider";
          };
          voicemailMenu = "*97";
          inbound."5551000" = {
            trunk = "provider";
            destination.extension = "201";
          };
        };

        services.asterisk = {
          openFirewall = true;
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;
          pjsip = {
            transports.udp = {};
            # the intruder's second address
            acls.intruder.deny = ["10.3.0.67/32"];
            trunks.provider = {
              host = "10.3.0.5";
              username = "5551000";
              password = secret "sip-trunk";
              # registers, and with that has a line, though nobody answers
              qualifyFrequency = 0;
            };
            # a phone that sends offers no phone sends; its calls are busy
            endpoints.sipp = {
              context = "offers";
              auth.password = secret "sip-sipp";
            };
          };
          modules.load = [
            "app_system.so"
            "res_agi.so"
            # res_agi's dependency
            "res_speech.so"
          ];
          dialplan.contexts = {
            offers.extensions."_X." = ["Hangup(17)"];
            sandbox.extensions = {
              system = ["System(${lib.getExe sandboxProbe} system)"];
              agi = ["AGI(${lib.getExe sandboxProbe},agi)"];
            };
          };

          ami = {
            enable = true;
            users = {
              # the example of services.asterisk.ami.users
              dialer = {
                secret = secret "ami-dialer";
                write = [
                  "originate"
                  "call"
                ];
              };
              monitor = {
                secret = secret "ami-monitor";
                write = ["reporting"];
              };
              admin = {
                secret = secret "ami-admin";
                write = [
                  "system"
                  "config"
                  "command"
                ];
              };
            };
          };
          http.enable = true;
          ari = {
            enable = true;
            users.viewer = {
              password = secret "ari-viewer";
              readOnly = true;
            };
          };
        };

        users.users = {
          operator = {
            isNormalUser = true;
            extraGroups = ["asterisk"];
          };
          # a home anyone may read, so only the sandbox keeps Asterisk out
          visitor = {
            isNormalUser = true;
            homeMode = "755";
          };
        };

        # directories anyone may write to, so only the sandbox keeps Asterisk out
        systemd.tmpfiles.rules = [
          "f /home/visitor/notes 0644 visitor users - notes"
          "d /var/lib/drop 1777 root root -"
          "d /srv/drop 1777 root root -"
        ];

        # another unit with a secret, as a credential and in its state directory
        systemd.services.neighbor = {
          wantedBy = ["multi-user.target"];
          after = ["provision-test-secrets.service"];
          requires = ["provision-test-secrets.service"];
          serviceConfig = {
            DynamicUser = true;
            StateDirectory = "neighbor";
            LoadCredential = "token:/run/test-secrets/neighbor";
          };
          path = [pkgs.coreutils];
          script = ''
            cp "$CREDENTIALS_DIRECTORY/token" "$STATE_DIRECTORY/token"
            exec sleep infinity
          '';
        };

        environment.systemPackages = [
          pkgs.curl
          pkgs.fail2ban
          (pkgs.writers.writePython3Bin "ami" {} ./ami.py)
        ];
      };

      intruder = {
        imports = [
          ./common.nix
          ./sip-probe.nix
          ./sipp.nix
        ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "10.3.0.66";
            prefixLength = 24;
          }
          {
            address = "10.3.0.67";
            prefixLength = 24;
          }
          {
            address = "10.3.0.5";
            prefixLength = 24;
          }
        ];
      };
    };

    testScript = ''
      ${builtins.readFile ./phone.py}

      start_all()
      pbx.wait_for_unit("asterisk.service")
      pbx.wait_for_unit("neighbor.service")
      intruder.wait_for_unit("multi-user.target")

      def probe(method, user, password=None, to=None):
          """The responses to one request the intruder sends as `user`."""
          command = f"sip-probe 10.3.0.10 {method} {user}" + (f" {password}" if password else "") + (f" --to {to}" if to else "")
          return [json.loads(line) for line in intruder.succeed(command).splitlines()]

      def statuses(responses):
          return [response["status"] for response in responses]

      def told(responses):
          """What the intruder learns from responses: status, reason and headers,
          without the headers that echo the request and the challenge's nonce
          and opaque, which change with every one."""
          return [
              (
                  response["status"],
                  response["reason"],
                  [
                      (name, "" if name in ["Via", "From", "To", "Call-ID"] else re.sub(r'(nonce|opaque)="[^"]*"', r'\1=""', value))
                      for name, value in response["headers"]
                  ],
              )
              for response in responses
          ]

      def main_pid():
          return pbx.succeed("systemctl show -P MainPID asterisk.service").strip()

      with subtest("requests as an extension, as the trunk and as a number nobody has get the same answers"):
          # 201 and sipp are endpoints, provider is the trunk, 5551000 its
          # account and 299 nothing; every one is asked for a password and
          # refused the one the intruder guesses
          for method in ["OPTIONS", "REGISTER", "INVITE"]:
              answers = {user: told(probe(method, user, "guess")) for user in ["201", "sipp", "provider", "5551000", "299"]}
              assert [status for status, _, _ in answers["201"]] == [401, 401], answers["201"]
              assert all(answer == answers["201"] for answer in answers.values()), (method, answers)
          # nor does the trunk's name call in
          assert statuses(probe("INVITE", "provider", to="5551000")) == [401]

      with subtest("each wrong password is logged with the intruder's address, and fail2ban's asterisk filter finds each"):
          def found():
              """The address of each failure fail2ban's asterisk filter finds in the journal."""
              return pbx.succeed("journalctl --sync && fail2ban-regex -o ip systemd-journal ${pkgs.fail2ban}/etc/fail2ban/filter.d/asterisk.conf").split()

          before = found()
          cursor = journal_cursor(pbx)
          methods = ["REGISTER", "INVITE", "OPTIONS"] * 4
          for i, method in enumerate(methods):
              assert statuses(probe(method, "202", f"guess-{i}")) == [401, 401]
          wait_journal(pbx, cursor, r"Request '[A-Z]+' from '<sip:202@10\.3\.0\.10>' failed for '10\.3\.0\.66:[0-9]+' \(callid: [0-9a-f]+\) - Failed to authenticate$", count=len(methods))
          assert journal_since(pbx, cursor).count("Failed to authenticate") == len(methods)
          after = found()
          assert after[: len(before)] == before and after[len(before) :] == ["10.3.0.66"] * len(methods), (before, after)

      with subtest("malformed SIP and SDP leave Asterisk running, and its memory flat"):
          pid = main_pid()
          # requests no phone sends reach Asterisk's parser from an address its
          # SIP ACL refuses, and offers no phone sends reach its SDP handling
          # from an endpoint that authenticates, each scenario played 300
          # times; the offers one call at a time, as Asterisk keeps the heap
          # that many calls at once take. A loaded host plays about 6 calls a
          # second, so SIPp gets 300 s instead of 60.
          def attack():
              sipp(intruder, "malformed", "10.3.0.10", "-i", "10.3.0.67", "-s", "201", "-m", "300", "-l", "50", "-r", "100", "-timeout", "300")
              sipp(intruder, "malformed-sdp", "10.3.0.10", "-i", "10.3.0.66", "-s", "600", "-au", "sipp", "-ap", "pw-sipp", "-m", "300", "-l", "1", "-r", "100", "-timeout", "300")

          def resident():
              """Asterisk's resident memory in KiB, once the calls are gone, their
              INVITE transactions have ended, 5 s (timer I) after their ACK, and
              malloc has given back the free pages of its heap."""
              wait_idle(pbx)
              time.sleep(10)
              return int(pbx.succeed(f"asterisk -rx 'malloc trim' > /dev/null && grep VmRSS /proc/{pid}/status").split()[1])

          # the first calls grow Asterisk's caches to what it keeps, answered
          # late, some after SIPp sent its next INVITE
          with stalled(pbx):
              attack()
          warm = resident()
          attack()
          attack()
          assert main_pid() == pid, "Asterisk restarted"
          grown = resident() - warm
          # 8 MiB is 14 KiB for each of the 600 calls with offers; from one
          # round to the next the memory varies by up to 2.5 MiB
          assert grown < 8192, f"{grown} KiB more after each scenario played 600 times more"

      with subtest("the principals the README names read secrets, and no one else"):
          # members of the asterisk group, through the CLI
          assert "pw-201" in pbx.succeed("su -l operator -c \"asterisk -rx 'pjsip show auth 201'\"")
          pbx.fail("su -l visitor -c \"asterisk -rx 'pjsip show auth 201'\"")
          for path in ["/run/asterisk/config/pjsip.conf", "/var/lib/asterisk/astdb.sqlite3", "/var/log/asterisk"]:
              pbx.fail(f"su -l visitor -c 'cat {path} || ls {path}'")

          def ami(user, action, *headers):
              return pbx.succeed(f"ami run {user} ami-{user}-pw {shlex.join([action, *headers])}")

          # AMI: call and reporting read voicemail PINs, system every password
          # and command any CLI output
          for user in ["dialer", "monitor"]:
              assert "Value: -4201" in ami(user, "Getvar", "Variable=VM_INFO(201@default,password)")
              for action in [["PJSIPShowAuths"], ["Command", "Command=pjsip show auth 201"]]:
                  assert "Message: Permission denied" in ami(user, *action)
          assert "Response: Success" in ami("admin", "PJSIPShowAuths")
          assert "pw-201" in ami("admin", "Command", "Command=pjsip show auth 201")
          # GetConfig takes only real paths inside the configuration
          # directory, and that is a link to another directory
          assert "File requires escalated privileges" in ami("admin", "GetConfig", "Filename=pjsip.conf")

          # ARI: read-only users too, the trunk's password among them
          for name, password in [("201", "pw-201"), ("provider-outbound", "trunk-password")]:
              objects = json.loads(pbx.succeed(f"curl -sf -u viewer:ari-viewer-pw http://127.0.0.1:8088/ari/asterisk/config/dynamic/res_pjsip/auth/{name}"))
              assert {"attribute": "password", "value": password} in objects, objects

      with subtest("programs the dialplan starts write only to Asterisk's directories and read nothing of /home or other units' secrets"):
          # the secrets are there to be read
          pbx.succeed("test -s /run/credentials/neighbor.service/token && test -s /var/lib/private/neighbor/token")
          for app in ["system", "agi"]:
              asterisk(pbx, f"channel originate Local/{app}@sandbox application Wait 3")
              pbx.wait_until_succeeds(f"test -f /var/lib/asterisk/probe-{app}", timeout=30)
              # /tmp, /var/tmp and /dev/shm are the unit's own
              report = pbx.succeed(f"cat /var/lib/asterisk/probe-{app}").splitlines()
              assert report == [f"write {dir}" for dir in ["/var/lib/asterisk", "/var/log/asterisk", "/run/asterisk", "/tmp", "/var/tmp", "/dev/shm"]], report
              for dir in ["/tmp", "/var/tmp", "/dev/shm", "/var/lib/drop", "/srv/drop"]:
                  pbx.fail(f"test -e {dir}/written-by-{app}")

      with subtest("calls from the trunk, from its address or with its line, to numbers that go out when a phone dials them go nowhere"):
          def invites(mark):
              """The Request-URIs of the INVITEs the pbx sent after the first
              `mark` messages of its capture."""
              return [m["text"].split()[1] for m in sip_messages(pbx)[mark:] if m["source"] == "10.3.0.10:5060" and m["text"].startswith("INVITE ")]

          # the line of the trunk's registration, which nobody answers
          pbx.wait_until_succeeds("asterisk -rx 'pjsip show registrations' | grep -q '^ provider/'")
          register = next(m for m in sip_messages(pbx) if m["source"] == "10.3.0.10:5060" and m["text"].startswith("REGISTER sip:10.3.0.5"))
          contact = re.search(r"^Contact: <sip:[^>]*;line=(\w+)>", register["text"], re.M)
          assert contact, register["text"]
          line = contact.group(1)

          # the outbound prefix and a number, the emergency number with and
          # without it, the menu, its key that rings an outside number and an
          # extension it dials directly, the voicemail menu, call pickup, and
          # an extension that forwards outside
          numbers = ["95551234", "911", "9911", "700", "1", "201", "*97", "*8", "203"]
          mark = len(sip_messages(pbx))
          cursor = journal_cursor(pbx)
          for source, params in [("10.3.0.5", ""), ("10.3.0.66", f";line={line}")]:
              for number in numbers:
                  sipp(intruder, "trunk-invite", "10.3.0.10:5060", "-i", source, "-p", "5090", "-s", number, "-key", "caller", "5551000", "-key", "called", number, "-key", "params", params)
          # each reached the trunk's context, which has none of them, but
          # call pickup, which chan_pjsip tries without the dialplan and
          # refuses with nothing to pick up (channels/chan_pjsip.c:3089-3110);
          # a final response comes again until its ACK arrives
          finals = {}
          for m in sip_messages(pbx)[mark:]:
              call_id = re.search(r"^Call-ID: (\S+)", m["text"], re.M)
              if call_id and m["source"] == "10.3.0.10:5060" and m["destination"].endswith(":5090") and re.match(r"SIP/2\.0 [2-6]", m["text"]):
                  finals.setdefault(call_id.group(1), m["text"].split()[1])
          assert list(finals.values()) == ["403" if number == "*8" else "404" for number in numbers] * 2, finals
          assert invites(mark) == [], invites(mark)
          assert not re.search(r"Executing \[.*\] Dial\(", journal_since(pbx, cursor))

          # dialled from inside, they go out through the trunk
          mark = len(sip_messages(pbx))
          for number in ["95551234", "911", "203"]:
              asterisk(pbx, f"channel originate Local/{number}@pbx-internal application Wait 1")
          expected = ["sip:5551234@10.3.0.5", "sip:911@10.3.0.5", "sip:5559000@10.3.0.5"]
          deadline = time.time() + 30
          while sorted(set(invites(mark))) != sorted(expected):
              assert time.time() < deadline, invites(mark)
              time.sleep(1)
    '';
  }
