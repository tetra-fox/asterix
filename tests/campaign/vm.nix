# The VM tier of the generated-configuration campaign (configs.py vm): each
# configuration of `plan` becomes a specialisation of the pbx, which the test
# switches to in turn and calls as configs.py planned. The pbx logs every
# dialplan step to campaign.json, where a marker call separates the calls,
# and configs.py compares each with the routing oracle.
#
#   pbx       10.4.0.10
#   provider  10.4.0.5, accounts 5550000 (trunk provider) and 5551000
#             (trunk second); answers the pbx's calls and hangs up after 1 s
#   phones    10.4.0.21, an Asterisk registered as extensions 201 to 204,
#             which ring and never answer
#
# `plan` is a JSON file: a list of { modules; extensions; trunks; calls; },
# with `modules` as configs.nix decodes them, the extensions the phones
# register as, the trunks the pbx registers, and each call { from,
# extension, keys?, limit } of a phone or { trunk, extension, limit } of the
# provider.
{
  pkgs,
  self,
}: {
  name,
  plan,
}: let
  inherit (pkgs) lib;
  campaign = import ./configs.nix {inherit pkgs self;};
  configurations = builtins.fromJSON (builtins.readFile plan);

  pool = ["201" "202" "203" "204"];
  accounts = {
    provider = "5550000";
    second = "5551000";
  };

  onlyAddress = address: {
    networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
  secrets = import ../vm/secrets.nix {
    fixed =
      {
        "trunk-0" = "trunk-pw-0";
        "trunk-1" = "trunk-pw-1";
      }
      // lib.genAttrs (map (n: "sip-${n}") pool) (secret: "pw-${lib.removePrefix "sip-" secret}")
      // lib.genAttrs (map (n: "vm-${n}") pool ++ ["vm-200" "vm-300" "vm-200-at-sales" "vm-400-at-support"]) (_: "4242");
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-campaign-${name}";

    nodes = {
      pbx = {
        imports = [
          self.nixosModules.pbx
          ../vm/common.nix
          secrets
          (onlyAddress "10.4.0.10")
        ];
        pbx.enable = true;
        services.asterisk = {
          openFirewall = true;
          pjsip.transports.udp = {};
          settings = {
            "asterisk.conf".options.verbose = 3;
            "logger.conf".logfiles."campaign.json" = "[json]verbose(3),notice,warning,error,dtmf";
          };
          # a call to m<i>-<j> marks where call j of configuration i starts
          dialplan.contexts.campaign-mark.extensions."_m." = ["NoOp(campaign mark \${EXTEN})" "Hangup()"];
        };
        specialisation = lib.listToAttrs (lib.imap0 (i: c:
          lib.nameValuePair "c${toString i}" {
            configuration.imports = map campaign.decode c.modules;
          })
        configurations);
        virtualisation.memorySize = 1536;
      };

      provider = {
        imports = [
          self.nixosModules.default
          ../vm/common.nix
          (onlyAddress "10.4.0.5")
        ];
        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            endpoints = lib.mapAttrs' (trunk: account:
              lib.nameValuePair account {
                context = "carrier";
                auth.password = "trunk-pw-${
                  if trunk == "provider"
                  then "0"
                  else "1"
                }";
              })
            accounts;
          };
          dialplan.contexts = {
            carrier.extensions."_X." = ["Answer()" "Wait(1)" "Hangup()"];
            feed.extensions.s = ["Wait(3600)"];
          };
        };
      };

      phones = {
        imports = [
          self.nixosModules.default
          ../vm/common.nix
          (onlyAddress "10.4.0.21")
        ];
        services.asterisk = {
          enable = true;
          openFirewall = true;
          pjsip = {
            transports.udp = {};
            trunks = lib.genAttrs (map (n: "ext-${n}") pool) (trunk: let
              n = lib.removePrefix "ext-" trunk;
            in {
              host = "10.4.0.10";
              username = n;
              password = "pw-${n}";
              context = "ringing";
              matchProviderHost = false;
              registration = {
                contactUser = n;
                retryInterval = 2;
              };
            });
          };
          dialplan.contexts = {
            ringing.extensions = lib.genAttrs ["_X." "_[*#]." "s"] (_: ["Ringing()" "Wait(3600)"]);
            # the caller's end of a call; with keys as the extension, it sends
            # them once the pbx answers, half a second apart after a second
            caller.extensions = {
              s = ["Wait(3600)"];
              "_[0-9*#]!" = ["SendDTMF(ww\${EXTEN})" "Wait(3600)"];
            };
          };
        };
      };
    };

    testScript = ''
      import json
      import shlex
      import time

      PLAN = json.loads(${builtins.toJSON (builtins.toJSON configurations)})
      ACCOUNTS = ${builtins.toJSON accounts}

      def cli(machine, command):
          return machine.succeed(f"asterisk -rx {shlex.quote(command)}")

      def channels(machine):
          return int(cli(machine, "core show channels count").split()[0])

      def hang_up_all():
          for machine in (phones, provider, pbx):
              cli(machine, "channel request hangup all")
          pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -q '^0 active channels'", timeout=60)

      def mark(label):
          cli(pbx, f"channel originate Local/m{label}@campaign-mark application Wait 0")
          pbx.wait_until_succeeds("asterisk -rx 'core show channels count' | grep -q '^0 active channels'", timeout=30)

      start_all()
      for machine in (pbx, provider, phones):
          machine.wait_for_unit("asterisk.service")

      for i, c in enumerate(PLAN):
          with subtest(f"configuration {i}"):
              pbx.succeed(f"/run/booted-system/specialisation/c{i}/bin/switch-to-configuration test")
              pbx.wait_for_unit("asterisk.service")
              pbx.wait_until_succeeds("asterisk -rx 'core waitfullybooted'", timeout=60)
              cli(phones, "pjsip send register *all")
              cli(pbx, "pjsip send register *all")
              for n in c["extensions"]:
                  pbx.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -q ' {n}/sip:'", timeout=60)
              for trunk in c["trunks"]:
                  provider.wait_until_succeeds(f"asterisk -rx 'pjsip show contacts' | grep -q ' {ACCOUNTS[trunk]}/sip:'", timeout=60)
              for j, call in enumerate(c["calls"]):
                  mark(f"{i}-{j}")
                  if "trunk" in call:
                      machine = provider
                      cli(provider, f"channel originate PJSIP/{call['extension']}@{ACCOUNTS[call['trunk']]} extension s@feed")
                  else:
                      machine = phones
                      then = call.get("keys") or "s"
                      cli(phones, f"channel originate PJSIP/{call['extension']}@ext-{call['from']} extension {then}@caller")
                  deadline = time.time() + call["limit"]
                  while channels(pbx) + channels(machine) > 0 and time.time() < deadline:
                      time.sleep(0.2)
                  hang_up_all()
              mark(f"{i}-end")
              # after each configuration, so a failed one leaves the log of the others
              pbx.succeed("cp /var/log/asterisk/campaign.json /tmp/campaign.json")
              pbx.copy_from_vm("/tmp/campaign.json", "")
    '';
  }
