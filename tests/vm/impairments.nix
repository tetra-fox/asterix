# A phone calls a number at the provider through the trunk while both links
# lose, delay, jitter, reorder or duplicate what they carry, one kind after
# the other and then all at once: each call sets up, both ends hear each other
# for as long as it lasts, the hangup ends it at both ends, and Asterisk holds
# no more files or sockets afterwards than before the first call.
#
#   VLAN 1  10.4.1.0/24  pbx .10, phones .21 (201)
#   VLAN 2  10.4.2.0/24  pbx .10, provider .21 (a pjsua the trunk calls)
{
  pkgs,
  self,
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
    name = "asterisk-impairments";

    nodes = {
      pbx = {config, ...}: let
        inherit (config.lib.asterisk) secret;
      in {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = {
              sip-201 = "pw-201";
              trunk = "trunk-5551000";
            };
          })
          (address "eth1" "10.4.1.10")
          (address "eth2" "10.4.2.10")
        ];
        virtualisation.vlans = [
          1
          2
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            endpoints."201" = {
              context = "office";
              auth.password = secret "/run/test-secrets/sip-201";
            };
            trunks.carrier = {
              host = "10.4.2.21";
              username = "5551000";
              password = secret "/run/test-secrets/trunk";
              context = "office";
              register = false;
              # Asterisk skips a contact whose last qualify failed, and the
              # provider's pjsua starts after the pbx first qualifies it
              qualifyFrequency = 5;
            };
          };
          dialplan.contexts.office.extensions."_9X." = [
            "Dial(PJSIP/\${EXTEN:1}@carrier,30)"
            "Hangup()"
          ];
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.4.1.21")
        ];
        virtualisation.vlans = [1];
      };

      provider = {
        imports = [
          ./common.nix
          ./phone.nix
          (address "eth1" "10.4.2.21")
        ];
        virtualisation.vlans = [2];
      };
    };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")
        phones.wait_until_succeeds("ip -o address show to 10.4.1.21 | grep -q .")
        provider.wait_until_succeeds("ip -o address show to 10.4.2.21 | grep -q .")

        anna = Phone(phones, "anna", "201", "pw-201", "10.4.1.10", sip_port=5060, cli_port=2300)
        carrier = Phone(provider, "carrier", "carrier", "none", "10.4.2.10", sip_port=5060, cli_port=2300, register=False)
        start_phones([anna, carrier])
        wait_registrations({anna: 200})
        pbx.wait_until_succeeds("asterisk -rx 'pjsip show contacts' | grep -qE '^ *Contact: +carrier/sip:.* Avail'", timeout=30)

        # both ways on the phone link and on the trunk link: netem only shapes
        # what leaves an interface
        links = [(pbx, "eth1"), (phones, "eth1"), (pbx, "eth2"), (provider, "eth1")]

        def held():
            """Files Asterisk has open and UDP sockets it has bound"""
            pid = pbx.succeed("systemctl show -P MainPID asterisk.service").strip()
            return pbx.succeed(f"ls /proc/{pid}/fd | wc -l; ss -Huanp | grep -c asterisk").split()

        def share(phone, mark, tone):
            """The share of 100 ms windows since `mark` in which `phone` heard `tone`"""
            windows = heard(phone, mark)
            return sum(any(abs(f - tone) <= TOLERANCE for f in w) for w in windows) / max(len(windows), 1)

        before = held()
        for settings in [
            ["loss", "1%"],
            ["loss", "5%"],
            ["loss", "20%"],
            ["delay", "50ms"],
            ["delay", "500ms"],
            ["delay", "100ms", "50ms"],
            ["delay", "10ms", "reorder", "25%", "50%"],
            ["duplicate", "5%"],
            ["delay", "500ms", "100ms", "loss", "20%", "duplicate", "5%", "reorder", "10%"],
        ]:
            with subtest(f"a call through the trunk survives {' '.join(settings)} on both links, and leaves nothing behind"):
                for machine, interface in links:
                    netem(machine, interface, *settings)
                calls = carrier.confirmed()
                ended = carrier.disconnects()
                anna.call("95551234")
                carrier.wait_confirmed(after=calls, timeout=60)
                wait_bridged(pbx, "201", "carrier")
                marks = (recorded(anna), recorded(carrier))
                wait_recorded(anna, marks[0], 6)
                wait_recorded(carrier, marks[1], 6)
                # all at once, a phone's jitter buffer drops about half
                heard_by = {"anna": share(anna, marks[0], carrier.tone), "carrier": share(carrier, marks[1], anna.tone)}
                assert all(s >= 0.25 for s in heard_by.values()), heard_by
                wait_bridged(pbx, "201", "carrier", timeout=1)
                anna.hangup()
                carrier.wait_disconnected(after=ended, timeout=60)
                wait_idle(pbx)
                for machine, interface in links:
                    netem(machine, interface)
                assert held() == before, (before, held())
      '';
  }
