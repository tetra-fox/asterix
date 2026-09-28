# Two companies on one PBX. Both have extensions 100 and 101, which reach
# their own phones only; each has its own trunk to the same carrier address,
# and a call to a company's number rings that company's phone although both
# trunks match the carrier's address (the registration's `line` tells them
# apart); outbound calls go out on the company's own account. ACME has a second
# trunk to the carrier's backup address, which takes its calls while the
# primary address does not answer.
#
#   lan  VLAN 1  10.1.0.0/24     pbx .10, phones .21
#   wan  VLAN 2  203.0.113.0/24  pbx .10, carrier .5 (primary) and .6 (backup)
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  # company -> its number at the carrier and its phones (extension -> name)
  companies = {
    acme = {
      number = "5551000";
      phones = {
        "100" = "Wile";
        "101" = "Road Runner";
      };
    };
    globex = {
      number = "5552000";
      phones = {
        "100" = "Hank";
        "101" = "Scorpio";
      };
    };
  };

  phoneNames = lib.concatLists (
    lib.mapAttrsToList (company: c: map (extension: "${company}-${extension}") (lib.attrNames c.phones)) companies
  );

  onlyAddresses = interface: addresses: {
    networking.interfaces.${interface}.ipv4.addresses = lib.mkForce (map (address: {
        inherit address;
        prefixLength = 24;
      })
      addresses);
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-tenants";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret;
        trunk = company: host: {
          inherit host;
          username = companies.${company}.number;
          password = secret "/run/test-secrets/trunk-${company}";
          context = "${company}-inbound";
          registration.contactUser = companies.${company}.number;
          # notice quickly that the carrier stopped answering
          qualifyFrequency = 5;
        };
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed =
              lib.mapAttrs' (company: c: lib.nameValuePair "trunk-${company}" "trunk-${c.number}") companies
              // lib.listToAttrs (map (name: lib.nameValuePair "sip-${name}" "pw-${name}") phoneNames);
          })
          (onlyAddresses "lan" ["10.1.0.10"])
          (onlyAddresses "wan" ["203.0.113.10"])
        ];
        virtualisation.interfaces = {
          lan.vlan = 1;
          wan.vlan = 2;
        };

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports.udp = {};

            endpoints = lib.concatMapAttrs (company: c:
              lib.mapAttrs' (extension: name:
                lib.nameValuePair "${company}-${extension}" {
                  context = company;
                  callerId = ''"${name}" <${extension}>'';
                  auth.password = secret "/run/test-secrets/sip-${company}-${extension}";
                })
              c.phones)
            companies;

            trunks = {
              acme = trunk "acme" "203.0.113.5";
              acme-backup = trunk "acme" "203.0.113.6";
              globex = trunk "globex" "203.0.113.5";
            };
          };

          dialplan.contexts = {
            acme.extensions = {
              "_1XX" = [
                "Dial(PJSIP/acme-\${EXTEN},20)"
                "Hangup()"
              ];
              "_9X." = [
                "Dial(PJSIP/\${EXTEN:1}@acme,30)"
                "GotoIf($[\"\${DIALSTATUS}\" = \"CHANUNAVAIL\"]?backup)"
                "Hangup()"
                {
                  label = "backup";
                  app = "Dial";
                  args = [
                    "PJSIP/\${EXTEN:1}@acme-backup"
                    30
                  ];
                }
                "Hangup()"
              ];
            };
            globex.extensions = {
              "_1XX" = [
                "Dial(PJSIP/globex-\${EXTEN},20)"
                "Hangup()"
              ];
              "_9X." = [
                "Dial(PJSIP/\${EXTEN:1}@globex,30)"
                "Hangup()"
              ];
            };
            acme-inbound.extensions.${companies.acme.number} = [
              "Dial(PJSIP/acme-100,20)"
              "Hangup()"
            ];
            globex-inbound.extensions.${companies.globex.number} = [
              "Dial(PJSIP/globex-100,20)"
              "Hangup()"
            ];
          };
        };
      };

      # the carrier, also built with this module: one account per company,
      # reachable on the primary and the backup address
      carrier = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.mapAttrs' (_: c: lib.nameValuePair "customer-${c.number}" "trunk-${c.number}") companies;
          })
          (onlyAddresses "eth1" [
            "203.0.113.5"
            "203.0.113.6"
          ])
        ];
        virtualisation.vlans = [2];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          pjsip = {
            transports = {
              primary.address = "203.0.113.5";
              backup.address = "203.0.113.6";
            };
            endpoints = lib.mapAttrs' (_: c:
              lib.nameValuePair c.number {
                context = "carrier";
                auth.password = config.lib.asterisk.secret "/run/test-secrets/customer-${c.number}";
                # registered once through each address
                aor.maxContacts = 2;
              })
            companies;
          };

          dialplan.contexts = {
            # remember which account called which number, from which address
            carrier.extensions."_X." = [
              "Set(DB(calls/\${EXTEN})=\${CHANNEL(endpoint)} \${CALLERID(num)} \${CHANNEL(pjsip,local_addr)})"
              "Answer()"
              "Playback(tt-monkeys)"
              "Wait(30)"
              "Hangup()"
            ];
            # audio for calls placed to the companies
            feed.extensions.s = [
              "Playback(tt-monkeys)"
              "Wait(30)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (onlyAddresses "eth1" ["10.1.0.21"])
        ];
        virtualisation.vlans = [1];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        carrier.wait_for_unit("asterisk.service")

        names = ${builtins.toJSON phoneNames}
        numbers = ${builtins.toJSON (lib.mapAttrs (_: c: c.number) companies)}
        phone = {
            name: Phone(phones, name, name, f"pw-{name}", "10.1.0.10", sip_port=5060 + i, cli_port=2300 + i)
            for i, name in enumerate(names)
        }

        def carried(number):
            """Account, caller number and carrier address of the call to `number`."""
            carrier.wait_until_succeeds(f"asterisk -rx 'database get calls {number}' | grep -q Value", timeout=90)
            return asterisk(carrier, f"database get calls {number}").split("Value: ", 1)[1].split()

        with subtest("every trunk registers"):
            pbx.wait_until_succeeds("test $(asterisk -rx 'pjsip show registrations' | grep -c Registered) -eq 3", timeout=180)
            start_phones(list(phone.values()))
            # and the static contacts of the three trunks
            wait_contacts(pbx, len(names) + 3)

        with subtest("the same extension reaches a different phone in each company"):
            for company in ["acme", "globex"]:
                caller, callee = phone[f"{company}-100"], phone[f"{company}-101"]
                caller.call("101")
                wait_bridged(pbx, caller.user, callee.user)
                print(wait_for_media_both_ways(pbx, [caller, callee]))
                caller.hangup()
                wait_idle(pbx)

        with subtest("a company cannot reach the other company's phones"):
            invites = phone["globex-101"].requests("INVITE")
            rejected = phone["acme-100"].count("DISCONNECTED \\[reason=404")
            phone["acme-100"].call("globex-101")
            phone["acme-100"].wait_count("DISCONNECTED \\[reason=404", rejected + 1)
            assert phone["globex-101"].requests("INVITE") == invites

        with subtest("each company's number rings its own phone, although both trunks match the carrier address"):
            # globex first: identified by address instead of line, its calls
            # would land on acme, the first trunk with that address
            for company, trunks in [("globex", {"globex"}), ("acme", {"acme", "acme-backup"})]:
                carrier.succeed(f"asterisk -rx 'channel originate PJSIP/{numbers[company]} extension s@feed'")
                wait_bridged(pbx, f"{company}-100")
                [members] = [m for m in bridges(pbx).values() if f"{company}-100" in m]
                assert members - {f"{company}-100"} <= trunks, members
                print(wait_for_media_both_ways(pbx, [phone[f"{company}-100"]], count=2))
                phone[f"{company}-100"].hangup()
                wait_idle(pbx)

        with subtest("outbound calls go out on the company's own account"):
            phone["acme-101"].call("95559001")
            assert carried("5559001")[:2] == ["5551000", "5551000"], carried("5559001")
            phone["acme-101"].hangup()
            phone["globex-101"].call("95559002")
            assert carried("5559002")[:2] == ["5552000", "5552000"], carried("5559002")
            phone["globex-101"].hangup()
            wait_idle(pbx)

        with subtest("while the primary address does not answer, ACME's calls take the backup trunk"):
            assert carried("5559001")[2].startswith("203.0.113.5:"), carried("5559001")
            carrier.succeed("iptables -I INPUT -d 203.0.113.5 -s 203.0.113.10 -j DROP")
            pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -E '^ *Contact: +acme/sip:203.0.113.5.* Unavail'", timeout=90)
            phone["acme-101"].call("95559003")
            account, caller_id, address = carried("5559003")
            assert (account, caller_id) == ("5551000", "5551000"), (account, caller_id)
            assert address.startswith("203.0.113.6:"), address
            phone["acme-101"].hangup()
            wait_idle(pbx)
            carrier.succeed("iptables -D INPUT -d 203.0.113.5 -s 203.0.113.10 -j DROP")
      '';
  }
