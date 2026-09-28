# Transfers and parking: a blind and an attended transfer by REFER from the
# phone, with music on hold for the caller while the transferring phone
# consults, a blind transfer by DTMF feature code, and a call parked on 700
# and picked up by dialing its parking space
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;

  extensions = [
    "301"
    "302"
    "303"
  ];
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-transfers";

    nodes = {
      pbx = {config, ...}: {
        imports = [
          self.nixosModules.default
          ./common.nix
          (import ./secrets.nix {
            fixed = lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") extensions);
          })
        ];

        services.asterisk = {
          enable = true;
          openFirewall = true;

          # the test follows calls through verbose messages in the journal
          logger.channels.console = [
            "notice"
            "warning"
            "error"
            "verbose"
          ];
          settings."asterisk.conf".options.verbose = 3;

          pjsip = {
            transports.udp = {};
            endpoints = lib.genAttrs extensions (extension: {
              context = "office";
              auth.password = config.lib.asterisk.secret "/run/test-secrets/sip-${extension}";
            });
          };

          features = {
            featureMap.blindxfer = "#1";
            general.transferdigittimeout = 3;
          };

          # no typed option: 700 parks a call, 701 to 720 pick it up again
          modules.load = ["res_parking.so"];
          settings."res_parking.conf".default = {
            parkext = 700;
            parkpos = "701-720";
            context = "parkedcalls";
          };

          dialplan.contexts.office = {
            includes = ["parkedcalls"];
            # t: the called phone may transfer with the feature code
            extensions."_30X" = [
              "Dial(PJSIP/\${EXTEN},20,t)"
              "Hangup()"
            ];
          };
        };
      };

      phones = {
        imports = [
          ./common.nix
          ./phone.nix
        ];
      };
    };

    testScript =
      builtins.readFile ./phone.py
      + ''
        start_all()
        pbx.wait_for_unit("asterisk.service")

        caller, transferrer, target = (
            Phone(phones, ext, ext, f"pw-{ext}", "pbx", sip_port=5060 + i, cli_port=2300 + i)
            for i, ext in enumerate(["301", "302", "303"])
        )

        with subtest("phones register"):
            start_phones([caller, transferrer, target])
            wait_contacts(pbx, 3)

        with subtest("blind transfer: the called phone sends the caller on with REFER"):
            ended = transferrer.disconnects()
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.transfer("303")
            wait_bridged(pbx, "301", "303")
            transferrer.wait_disconnected(after=ended)
            print(wait_for_media_both_ways(pbx, [caller, target]))
            caller.hangup()
            wait_idle(pbx)

        with subtest("attended transfer: the caller hears music on hold until it is handed over"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            held = transferrer.current_call()
            transferrer.hold()
            wait_journal(pbx, cursor, "Started music on hold, class 'default', on channel 'PJSIP/301-")
            transferrer.call("303")
            wait_bridged(pbx, "302", "303")
            transferrer.transfer_replaces(held)
            wait_bridged(pbx, "301", "303")
            wait_journal(pbx, cursor, "Stopped music on hold on PJSIP/301-")
            pbx.wait_until_fails("asterisk -rx 'core show channels concise' | grep -q '^PJSIP/302-'")
            print(wait_for_media_both_ways(pbx, [caller, target]))
            caller.hangup()
            wait_idle(pbx)

        with subtest("blind transfer by DTMF feature code"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.dtmf("#1")
            wait_journal(pbx, cursor, "Playing 'pbx-transfer\\.")
            transferrer.dtmf("303")
            wait_bridged(pbx, "301", "303")
            print(wait_for_media_both_ways(pbx, [caller, target]))
            caller.hangup()
            wait_idle(pbx)

        with subtest("a call transferred to the parking extension is picked up from its space"):
            cursor = journal_cursor(pbx)
            caller.call("302")
            wait_bridged(pbx, "301", "302")
            transferrer.transfer("700")
            wait_journal(pbx, cursor, "Parking 'PJSIP/301-[0-9a-f]+' in 'default' at space 701")
            target.call("701")
            wait_bridged(pbx, "301", "303")
            print(wait_for_media_both_ways(pbx, [caller, target]))
            caller.hangup()
            wait_idle(pbx)
      '';
  }
