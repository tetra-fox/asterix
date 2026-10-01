# The addresses Asterisk binds on a phone VLAN, with scripted networking and
# with systemd-networkd side by side. While Asterisk runs, the addresses go
# away and come back: Asterisk keeps its sockets, and phones register and call
# again without a restart. Restarted while the link is down, Asterisk starts
# at once with scripted networking and once the link is back with
# systemd-networkd. It waits for an IPv6 address in duplicate address
# detection, which only systemd-networkd's go through (scripted networking
# adds its addresses with nodad). Restarted while an address never comes up,
# it waits 90 s, fails naming the address, and starts once the address is
# there, as Restart= starts it again.
#
#   VLAN 1  scripted  voip 10.2.0.10, fd00:2::10
#           networkd  voip 10.2.0.11, fd00:2::11
#           phones    10.2.0.21, fd00:2::21: 101 and 102 on each over IPv4,
#                     103 on each over IPv6
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = ["101" "102" "103"];

  pbx = {
    v4,
    v6,
    useNetworkd,
  }: {config, ...}: {
    imports = [
      self.nixosModules.default
      ./common.nix
      (import ./secrets.nix {
        fixed = lib.listToAttrs (map (e: lib.nameValuePair "sip-${e}" "pw-${e}") extensions);
      })
    ];
    virtualisation.interfaces.voip.vlan = 1;
    networking = {
      inherit useNetworkd;
      interfaces.voip = {
        ipv4.addresses = lib.mkForce [
          {
            address = v4;
            prefixLength = 24;
          }
        ];
        ipv6.addresses = [
          {
            address = v6;
            prefixLength = 64;
          }
        ];
      };
    };

    services.asterisk = {
      enable = true;
      openFirewall = true;
      pjsip = {
        transports = {
          udp.address = v4;
          udp6.address = v6;
        };
        endpoints = lib.genAttrs extensions (extension: {
          context = "phones";
          auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
          # a short interval keeps the test short; phones that missed a
          # qualify can be called again once the next one reaches them
          aor.qualifyFrequency = 10;
        });
      };
      dialplan.contexts.phones.extensions."_1XX" = [
        "Dial(PJSIP/\${EXTEN},20)"
        "Hangup()"
      ];
    };
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-faults-net";

    nodes = {
      scripted = pbx {
        v4 = "10.2.0.10";
        v6 = "fd00:2::10";
        useNetworkd = false;
      };
      networkd = pbx {
        v4 = "10.2.0.11";
        v6 = "fd00:2::11";
        useNetworkd = true;
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
        virtualisation.vlans = [1];
        networking.interfaces.eth1 = {
          ipv4.addresses = lib.mkForce [
            {
              address = "10.2.0.21";
              prefixLength = 24;
            }
          ];
          ipv6.addresses = [
            {
              address = "fd00:2::21";
              prefixLength = 64;
            }
          ];
        };
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        addresses = {scripted: ("10.2.0.10", "fd00:2::10"), networkd: ("10.2.0.11", "fd00:2::11")}
        pbxs = list(addresses)

        def link(machine, state):
            """The phone VLAN's link, as a switch port that goes down and up."""
            machine.send_monitor_command(f"set_link vlan1 {state}")

        def remove_addresses(machine):
            """The phone VLAN's addresses go away, as each networking backend
            removes them."""
            if machine is scripted:
                machine.succeed("systemctl stop network-addresses-voip.service")
            else:
                machine.succeed("ip address flush dev voip scope global")

        def restore_addresses(machine):
            if machine is scripted:
                machine.succeed("systemctl start network-addresses-voip.service")
            else:
                machine.succeed("networkctl reconfigure voip")

        def has_address(machine, address):
            return machine.execute(f"ip -o address show dev voip to {address} -tentative | grep -q .")[0] == 0

        def listening(machine):
            v4, v6 = addresses[machine]
            sockets = machine.succeed("ss -Hlun 'sport = :5060'")
            assert f"{v4}:5060" in sockets and f"[{v6}]:5060" in sockets, sockets

        start_all()
        for machine in pbxs:
            machine.wait_for_unit("asterisk.service")

        phone = {}
        port = 5060
        for machine, (v4, v6) in addresses.items():
            for extension, server in [("101", v4), ("102", v4), ("103", f"[{v6}]")]:
                phone[machine, extension] = Phone(phones, f"{machine.name}-{extension}", extension, f"pw-{extension}", server, sip_port=port, cli_port=port - 2760)
                port += 1

        def register_and_call():
            """Every phone registers again, and on each pbx 101 calls 102 and
            hears it, once Asterisk qualified the contacts again."""
            registered = {p: p.count("registration success") for p in phone.values()}
            cli_parallel([(p, "rr") for p in phone.values()])
            for p in phone.values():
                p.wait_count("registration success", registered[p] + 1, timeout=30)
            for machine in pbxs:
                # the aors' qualifyFrequency (10 s)
                machine.wait_until_succeeds("test $(asterisk -rx 'pjsip show contacts' | grep -cE '^ *Contact: .* Avail ') -eq 3", timeout=15)
                caller, callee = phone[machine, "101"], phone[machine, "102"]
                caller.call("102")
                wait_bridged(machine, "101", "102")
                wait_hears(caller, [callee.tone])
                caller.hangup()
                wait_idle(machine)

        with subtest("phones register over both families with scripted networking and with systemd-networkd"):
            phones.wait_until_succeeds("ip -o address show dev eth1 to fd00:2::21 -tentative | grep -q .")
            start_phones(list(phone.values()))
            wait_registrations({p: 200 for p in phone.values()})

        with subtest("a bound address goes away and comes back: Asterisk keeps its sockets, and phones register and call again"):
            for machine, (v4, v6) in addresses.items():
                remove_addresses(machine)
                assert not has_address(machine, v4) and not has_address(machine, v6)
                listening(machine)
            for machine, (_, v6) in addresses.items():
                restore_addresses(machine)
                machine.wait_until_succeeds(f"ip -o address show dev voip to {v6} -tentative | grep -q .", timeout=30)
            register_and_call()

        with subtest("Asterisk restarted while the link is down: it starts at once with scripted networking, and once the link is back with systemd-networkd"):
            cursor = journal_cursor(networkd)
            for machine in pbxs:
                link(machine, "off")
            # systemd-networkd removes the addresses of a link without carrier,
            # scripted networking keeps them
            networkd.wait_until_succeeds("! ip -o address show dev voip | grep -q 'inet 10.2.0.11/'", timeout=30)
            for machine in pbxs:
                machine.succeed("systemctl restart --no-block asterisk.service")
            scripted.wait_for_unit("asterisk.service")
            wait_journal(networkd, cursor, "asterisk-config: waiting for address 10.2.0.11$")
            assert networkd.get_unit_property("asterisk.service", "ActiveState") == "activating"
            for machine in pbxs:
                link(machine, "on")
            networkd.wait_for_unit("asterisk.service", timeout=30)
            for machine in pbxs:
                listening(machine)
            register_and_call()

        with subtest("Asterisk waits for an IPv6 address in duplicate address detection, which scripted networking skips"):
            cursors = {machine: journal_cursor(machine) for machine in pbxs}
            for machine in pbxs:
                # five probes keep an address tentative for about 5 s
                machine.succeed("systemctl stop asterisk.service", "sysctl -w net.ipv6.conf.voip.dad_transmits=5")
                remove_addresses(machine)
                restore_addresses(machine)
                machine.succeed("systemctl start --no-block asterisk.service")
            wait_journal(networkd, cursors[networkd], "asterisk-config: waiting for address fd00:2::11$")
            for machine in pbxs:
                machine.wait_for_unit("asterisk.service", timeout=30)
                listening(machine)
            # scripted networking adds its addresses with nodad
            assert "waiting for address" not in journal_since(scripted, cursors[scripted])
            register_and_call()

        with subtest("an address that never comes up: Asterisk waits 90 s, fails naming it, and starts once it is there"):
            cursors = {machine: journal_cursor(machine) for machine in pbxs}
            for machine in pbxs:
                remove_addresses(machine)
                machine.succeed("systemctl restart --no-block asterisk.service")
            for machine, (v4, _) in addresses.items():
                wait_journal(machine, cursors[machine], f"asterisk-config: address {v4} is not configured on this host$", timeout=100)
                wait_journal(machine, cursors[machine], "asterisk.service: Failed with result 'exit-code'")
                # Restart=on-failure starts it again 5 s later, and it waits again
                wait_journal(machine, cursors[machine], f"asterisk-config: waiting for address {v4}$", count=2, timeout=15)
                restore_addresses(machine)
            for machine in pbxs:
                machine.wait_for_unit("asterisk.service", timeout=30)
                listening(machine)
            register_and_call()
      '';
  }
