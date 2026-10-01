# Trunks against a provider on several addresses, with a DNS server of its
# own and SIPp for the answers the provider's Asterisk never gives.
# Registration: the REGISTER carries the configured expiration, contact user
# and line; a host with an SRV record, or with a NAPTR record that leads to
# one, is registered at the record's target and port; a 407 challenge is
# answered with credentials the test checks; a 403 or 302 stops the
# registration and the journal says why; a registrar answering 503 is asked
# again every retryInterval for as long as it does. A trunk refused for a
# wrong password registers once the right one is in and Asterisk reloads,
# which tries the other refused registrations again. Inbound: a call is
# matched to the trunk whose identify has its source address, given as an
# address, a host name or through an SRV record, or from any address to the
# registered trunk whose line it carries; other calls are refused, also when
# From names a trunk; the number a call arrives at is the Request-URI's, not
# the one in To. When the provider moves to another address and DNS names
# it, the registered trunk qualifies, calls and registers there and sends
# nothing new to the old one, and a host name in identify matches the new
# address only after res_pjsip reloads.
#
#   pbx       203.0.113.1
#   provider  203.0.113.5 sip.provider.example, SIPp's registrars on 5071-5074
#             .6 sip.provider.example once it moves
#             .7 edge.provider.example, the target of the SRV records
#             .8 the gateway of the trunk identified by address
#             .9 gw.provider.example, .11 once it moves
#             .99 an address no identify has
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # the provider's accounts, one per trunk that registers to its Asterisk
  accounts = {
    provider = "5551000";
    srv = "5552000";
    naptr = "5553000";
    rotated = "5558000";
  };
  # trunks that register to SIPp: account, port, and the status SIPp refuses
  # every REGISTER with, or null for a 407 challenge it then accepts
  registrars = {
    proxyauth = {
      account = "5554000";
      port = 5071;
      status = null;
    };
    forbidden = {
      account = "5555000";
      port = 5072;
      status = "403 Forbidden";
    };
    moved = {
      account = "5556000";
      port = 5073;
      status = "302 Moved Temporarily";
    };
    unavailable = {
      account = "5557000";
      port = 5074;
      status = "503 Service Unavailable";
    };
  };

  hosts = sip: gw: ''
    ${sip} sip.provider.example
    203.0.113.7 edge.provider.example
    ${gw} gw.provider.example
  '';

  onlyAddresses = addresses: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce (map (address: {
        inherit address;
        prefixLength = 24;
      })
      addresses);
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-trunks";

    nodes = {
      pbx = {config, ...}: let
        secret = name: config.lib.asterisk.secret "/run/test-secrets/${name}";
        trunk = username: extra:
          lib.recursiveUpdate {
            inherit username;
            password = secret "trunk-${username}";
            context = "from-trunk";
            registration.contactUser = username;
          }
          extra;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              lib.mapAttrs' (_: username: lib.nameValuePair "trunk-${username}" "pw-${username}") (
                accounts
                // lib.mapAttrs (_: r: r.account) registrars
                // {
                  static = "static";
                  named = "named";
                }
              )
              // {"trunk-${accounts.rotated}" = "wrong";};
          })
          (onlyAddresses ["203.0.113.1"])
        ];
        # Asterisk resolves SIP hosts with DNS only
        # (res/res_pjsip/pjsip_resolver.c:698, main/dns.c:296)
        networking.nameservers = ["203.0.113.5"];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            trunks =
              {
                provider = trunk accounts.provider {
                  host = "sip.provider.example";
                  # registers again every 50 s, or 5 s after an attempt that
                  # failed, and notices within seconds that the provider
                  # stopped answering
                  registration = {
                    expiration = 60;
                    retryInterval = 5;
                  };
                  qualifyFrequency = 5;
                };
                srv = trunk accounts.srv {host = "srv.provider.example";};
                naptr = trunk accounts.naptr {
                  host = "naptr.provider.example";
                  # identify looks up SRV records of the host itself, not the
                  # ones its NAPTR record leads to
                  matchProviderHost = false;
                };
                # the gateways only send calls
                static = trunk "static" {
                  host = "203.0.113.8";
                  register = false;
                  identify.match = ["203.0.113.8"];
                  matchProviderHost = false;
                  qualifyFrequency = 0;
                };
                named = trunk "named" {
                  host = "gw.provider.example";
                  register = false;
                  qualifyFrequency = 0;
                };
                # its password is wrong until the test puts the right one in
                rotated = trunk accounts.rotated {
                  host = "sip.provider.example";
                  matchProviderHost = false;
                };
              }
              // lib.mapAttrs (name: r:
                trunk r.account {
                  host = "203.0.113.5";
                  inherit (r) port;
                  # SIPp takes nothing but REGISTER and sends no calls
                  matchProviderHost = false;
                  qualifyFrequency = 0;
                  registration = {
                    retryInterval = 1;
                    # one registration without the line parameter
                    line = name != "proxyauth";
                  };
                })
              registrars;
          };
          # which trunk and number each call arrived at, by Call-ID
          dialplan.contexts.from-trunk.extensions."_X." = [
            "Set(DB(arrived/\${CHANNEL(pjsip,call-id)})=\${CHANNEL(endpoint)} \${EXTEN})"
            "Answer()"
            "Hangup()"
          ];
        };
      };

      provider = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          ./sipp.nix
          (import ./secrets.nix {
            fixed = lib.mapAttrs' (_: account: lib.nameValuePair "customer-${account}" "pw-${account}") accounts;
          })
          (onlyAddresses [
            "203.0.113.5"
            "203.0.113.6"
            "203.0.113.7"
            "203.0.113.8"
            "203.0.113.9"
            "203.0.113.11"
            "203.0.113.99"
          ])
        ];
        networking.firewall.allowedUDPPorts = [53] ++ lib.mapAttrsToList (_: r: r.port) registrars;

        environment.etc =
          {
            # the test moves names to other addresses by rewriting this file
            provider-hosts = {
              mode = "0644";
              text = hosts "203.0.113.5" "203.0.113.9";
            };
          }
          // lib.mapAttrs' (name: r:
            lib.nameValuePair "sipp-registrars/${name}.xml" {
              text = builtins.replaceStrings ["@status@"] [r.status] (builtins.readFile ./sipp/register-refused.xml);
            }) (lib.filterAttrs (_: r: r.status != null) registrars);
        services.dnsmasq = {
          enable = true;
          settings = {
            no-resolv = true;
            local = "/provider.example/";
            addn-hosts = "/etc/provider-hosts";
            srv-host = [
              "_sip._udp.srv.provider.example,edge.provider.example,5070"
              "_sip._udp.naptr-target.provider.example,edge.provider.example,5080"
            ];
            # a replacement other than _sip._udp.<host>, so only the NAPTR
            # record leads there
            naptr-record = "naptr.provider.example,10,10,S,SIP+D2U,,_sip._udp.naptr-target.provider.example";
          };
        };

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            # each bound to its address, which it puts in Contact
            transports = {
              before.address = "203.0.113.5";
              after.address = "203.0.113.6";
              srv = {
                address = "203.0.113.7";
                port = 5070;
              };
              naptr = {
                address = "203.0.113.7";
                port = 5080;
              };
            };
            # the office's accounts; an endpoint's name is its user name
            endpoints = lib.listToAttrs (map (account:
              lib.nameValuePair account {
                context = "carrier";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/customer-${account}";
              }) (lib.attrValues accounts));
          };
          dialplan.contexts.carrier.extensions."_X." = [
            "Answer()"
            "Wait(2)"
            "Hangup()"
          ];
        };
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        import hashlib

        REGISTRARS = json.loads('${builtins.toJSON registrars}')
        MOVED_HOSTS = """${hosts "203.0.113.6" "203.0.113.11"}"""

        # the provider is up before the office starts, and so are SIPp's
        # registrars, as the office registers within 10 s of starting
        provider.start()
        provider.wait_for_unit("asterisk.service")
        provider.wait_for_unit("dnsmasq.service")
        for name, registrar in REGISTRARS.items():
            scenario = f"/etc/sipp-registrars/{name}.xml" if registrar["status"] else "/etc/sipp/register-407.xml"
            provider.succeed(
                f"systemd-run --unit=sipp-{name} -p RemainAfterExit=yes sipp -sf {scenario} "
                f"-i 203.0.113.5 -p {registrar['port']} -m 1 -nostdin -trace_msg -message_file /tmp/sipp-{name}.log"
            )
            provider.wait_until_succeeds(f"ss -Hlun 'sport = :{registrar['port']}' | grep -q {registrar['port']}", timeout=10)
        pbx.start()
        pbx.wait_for_unit("asterisk.service")

        def registrations():
            """The status of each outbound registration, by trunk"""
            listing = asterisk(pbx, "pjsip show registrations")
            return dict(re.findall(r"^ ([\w-]+)/\S+ +\S+ +(\S+)", listing, re.M))

        def wait_trunks(expected, timeout=60):
            deadline = time.time() + timeout
            while True:
                found = registrations()
                if all(found.get(name) == status for name, status in expected.items()):
                    return
                if time.time() > deadline:
                    raise Exception(f"registrations are {found}, expected {expected}")
                time.sleep(1)

        def header(message, name):
            match = re.search(rf"^{name}: (.*?)\r$", message["text"], re.M)
            assert match, message["text"]
            return match.group(1)

        def requests(start, destination, mark=0):
            """Requests starting with `start` the pbx sent to an address:port
            starting with `destination`, after the first `mark` messages of
            its capture, each with the final status it got or None."""
            messages = sip_messages(pbx)
            finals = {}
            for m in messages:
                if m["destination"] == "203.0.113.1:5060" and re.match(r"SIP/2\.0 [2-6]", m["text"]):
                    finals.setdefault((header(m, "Call-ID"), header(m, "CSeq")), int(m["text"].split()[1]))
            return [
                (m, finals.get((header(m, "Call-ID"), header(m, "CSeq"))))
                for m in messages[mark:]
                if m["source"] == "203.0.113.1:5060" and m["destination"].startswith(destination) and m["text"].startswith(start)
            ]

        def wait_request(start, destination, mark, status=200, timeout=30):
            """Wait until the pbx sent a request starting with `start` to
            `destination`, after `mark`, that got `status`."""
            deadline = time.time() + timeout
            while not any(got == status for _, got in requests(start, destination, mark)):
                if time.time() > deadline:
                    raise Exception(f"the pbx sent no {start!r} to {destination} that got {status}")
                time.sleep(1)

        def journal(text, timeout=60):
            pbx.wait_until_succeeds(f"journalctl -u asterisk.service | grep -qF {shlex.quote(text)}", timeout=timeout)

        calls = itertools.count()

        def call(source, number="5551000", caller="gateway", called=None, params=""):
            """A call from `source` on the provider to `number`, From `caller`
            and To `called`. Returns the pbx's final status, and the trunk and
            number the call arrived at, or None."""
            call_id = f"call-{next(calls)}"
            mark = len(sip_messages(pbx))
            sipp(
                provider, "trunk-invite", "203.0.113.1:5060", "-i", source, "-p", "5090", "-s", number,
                "-key", "caller", caller, "-key", "called", called or number, "-key", "params", params, "-cid_str", call_id,
            )
            final = [
                m for m in sip_messages(pbx)[mark:]
                if m["source"] == "203.0.113.1:5060" and m["destination"] == f"{source}:5090" and re.match(r"SIP/2\.0 [2-6]", m["text"])
            ][-1]
            arrived = pbx.succeed(f"asterisk -rx 'database get arrived {call_id}' | sed -n 's/^Value: //p'").strip()
            return int(final["text"].split()[1]), arrived or None

        def digest_valid(request, authorization, password):
            """Whether the digest in the `authorization` header of `request`
            answers its challenge with `password` (RFC 2617)"""
            fields = dict(re.findall(r'(\w+)="?([^",]*)"?', header(request, authorization).removeprefix("Digest ")))

            def md5(text):
                return hashlib.md5(text.encode()).hexdigest()

            ha1 = md5(f"{fields['username']}:{fields['realm']}:{password}")
            ha2 = md5(f"{request['text'].split()[0]}:{fields['uri']}")
            if "qop" in fields:
                return fields["response"] == md5(f"{ha1}:{fields['nonce']}:{fields['nc']}:{fields['cnonce']}:{fields['qop']}:{ha2}")
            return fields["response"] == md5(f"{ha1}:{fields['nonce']}:{ha2}")

        with subtest("each trunk registers as configured, at the target of an SRV record, or of the SRV record a NAPTR record leads to"):
            wait_trunks({"provider": "Registered", "srv": "Registered", "naptr": "Registered"})
            register = next(r for r, status in requests("REGISTER ", "203.0.113.5:5060") if status == 200)
            assert register["text"].startswith("REGISTER sip:sip.provider.example SIP/2.0\r\n"), register["text"]
            assert header(register, "To") == "<sip:5551000@sip.provider.example>", register["text"]
            assert header(register, "Expires") == "60", register["text"]
            contact = re.fullmatch(r"<sip:5551000@203\.0\.113\.1:5060;line=(\w+)>", header(register, "Contact"))
            assert contact, register["text"]
            line = contact.group(1)
            wait_request("REGISTER sip:srv.provider.example SIP/2.0", "203.0.113.7:5070", 0)
            wait_request("REGISTER sip:naptr.provider.example SIP/2.0", "203.0.113.7:5080", 0)

        with subtest("a 407 challenge is answered with the account's credentials"):
            wait_trunks({"proxyauth": "Registered"})
            (_, challenged), (second, accepted) = requests("REGISTER ", "203.0.113.5:5071")
            assert (challenged, accepted) == (407, 200), (challenged, accepted)
            assert digest_valid(second, "Proxy-Authorization", "pw-5554000"), second["text"]
            assert header(second, "Contact") == "<sip:5554000@203.0.113.1:5060>", second["text"]
            provider.succeed("test $(systemctl show -P ExecMainStatus sipp-proxyauth.service) = 0")

        with subtest("a 403 or a 302 stops the registration, and the journal says why"):
            wait_trunks({"forbidden": "Rejected", "moved": "Rejected"})
            for name, status in [("forbidden", 403), ("moved", 302)]:
                registrar = REGISTRARS[name]
                journal(
                    f"Fatal response '{status}' received from 'sip:203.0.113.5:{registrar['port']}' on registration attempt "
                    f"to 'sip:{registrar['account']}@203.0.113.5:{registrar['port']}', stopping outbound registration"
                )

        with subtest("a registrar answering 503 is asked again every retryInterval, beyond the eleven attempts Asterisk's default allows"):
            # five more than Asterisk's default max_retries would send
            deadline = time.time() + 30
            while len(requests("REGISTER ", "203.0.113.5:5074")) < 16:
                assert time.time() < deadline, requests("REGISTER ", "203.0.113.5:5074")
                time.sleep(1)
            times = [r["time"] for r, _ in requests("REGISTER ", "203.0.113.5:5074")][:16]
            gaps = [later - earlier for earlier, later in zip(times, times[1:])]
            # pjsip keeps a timer's expiry in whole milliseconds, so a retry can
            # come up to 1 ms before a full retryInterval after the 503
            assert all(0.999 <= gap < 1.5 for gap in gaps), gaps
            pbx.fail("journalctl -u asterisk.service | grep -q 'Maximum retries reached'")

        with subtest("a call is matched to the trunk whose identify has its source, given as an address, a host name or through an SRV record"):
            for source, trunk in [("203.0.113.5", "provider"), ("203.0.113.8", "static"), ("203.0.113.9", "named"), ("203.0.113.7", "srv")]:
                assert call(source) == (200, f"{trunk} 5551000"), (source, trunk)

        with subtest("a call carrying a registration's line is matched to its trunk from any address"):
            assert call("203.0.113.99", params=f";line={line}") == (200, "provider 5551000")

        with subtest("from any other address a call is refused, also when From names a trunk"):
            for caller in ["gateway", "provider", "static"]:
                assert call("203.0.113.99", caller=caller) == (401, None), caller

        with subtest("a call arrives at the number in the Request-URI, not the one in To"):
            assert call("203.0.113.5", number="5551000", called="5551001") == (200, "provider 5551000")

        with subtest("when the provider's address changes in DNS, the trunk qualifies, calls and registers at the new one"):
            # the provider's old address stops answering
            provider.succeed("iptables -I INPUT -d 203.0.113.5 -s 203.0.113.1 -p udp --dport 5060 -j DROP")
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/sip:sip.provider.example .* Unavail'", timeout=30)
            mark = len(sip_messages(pbx))
            # the provider sends from its new address, which its Asterisk then
            # puts in Contact, and DNS names it
            provider.succeed(
                "ip route replace 203.0.113.1 dev eth1 src 203.0.113.6 && "
                f"echo {shlex.quote(MOVED_HOSTS)} > /etc/provider-hosts && systemctl kill -s HUP dnsmasq.service"
            )
            pbx.wait_until_succeeds("getent ahostsv4 sip.provider.example | grep -q 203.0.113.6")
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +provider/sip:sip.provider.example .* Avail'", timeout=30)
            asterisk(pbx, "channel originate PJSIP/5559999@provider application Wait 1")
            wait_request("INVITE sip:5559999@sip.provider.example", "203.0.113.6:5060", mark)
            # the provider's calls come from its new address, with the line
            assert call("203.0.113.6", params=f";line={line}") == (200, "provider 5551000")
            # the next registration, 50 s after the last one, or 5 s after one
            # sent to the old address timed out
            wait_request("REGISTER sip:sip.provider.example", "203.0.113.6:5060", mark, timeout=100)
            wait_trunks({"provider": "Registered"})
            # the old address got nothing new, only retransmissions of requests
            # sent before the change, which have the same Via
            messages = sip_messages(pbx)

            def to_old_address(chunk):
                return {
                    header(m, "Via") for m in chunk
                    if m["source"] == "203.0.113.1:5060" and m["destination"] == "203.0.113.5:5060" and not m["text"].startswith("SIP/2.0 ")
                }

            assert to_old_address(messages[mark:]) <= to_old_address(messages[:mark])

        with subtest("a refused registration stays stopped until res_pjsip reloads"):
            # their retryInterval is 1 s, and a minute has passed
            for name in ["forbidden", "moved"]:
                assert len(requests("REGISTER ", f"203.0.113.5:{REGISTRARS[name]['port']}")) == 1, name
            states = registrations()
            assert all(states[name] == "Rejected" for name in ["forbidden", "moved"]), states

        with subtest("a host name in identify keeps the address it had until res_pjsip reloads"):
            # gw.provider.example moved along with sip.provider.example
            pbx.succeed("getent ahostsv4 gw.provider.example | grep -q 203.0.113.11")
            assert call("203.0.113.11") == (401, None)
            asterisk(pbx, "module reload res_pjsip.so")
            assert call("203.0.113.11") == (200, "named 5551000")
            assert call("203.0.113.9") == (401, None)

        with subtest("once the right password is in and asterisk reloads, the trunk refused for it registers, and the other refused registrations are tried again"):
            journal(
                "Fatal response '401' received from 'sip:sip.provider.example' on registration attempt "
                "to 'sip:5558000@sip.provider.example', stopping outbound registration"
            )
            mark = len(sip_messages(pbx))
            cursor = journal_cursor(pbx)
            pbx.succeed("printf 'pw-5558000\\n' > /run/test-secrets/trunk-5558000 && systemctl reload asterisk.service")
            wait_journal(pbx, cursor, "asterisk-config: module reload res_pjsip.so")
            wait_trunks({"rotated": "Registered"}, timeout=30)
            for name, status in [("forbidden", 403), ("moved", 302)]:
                wait_request("REGISTER ", f"203.0.113.5:{REGISTRARS[name]['port']}", mark, status=status)
      '';
  }
