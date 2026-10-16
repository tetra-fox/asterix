# services.asterix.parking: call parking in res_parking's default lot, whose
# park number, slots and slot hints res_parking adds to pbx-parking, which
# pbx-internal includes. A parked call nobody takes in time goes back to the
# phone that parked it in pbx-parking-timeout, then on to the no-answer
# destination of its extension.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterix;
  inherit (cfg) parking;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (pbxLib) app;

  slots = pbxLib.parkingSlots parking;
in {
  options.services.asterix.parking = mkOption {
    type = types.nullOr (types.submodule {
      options = {
        number = mkOption {
          # res_parking reads the slots as an int (res/res_parking.c
          # option_handler_parkpos) and names them without leading zeros
          type = types.strMatching "[1-9][0-9]{0,8}";
          example = "700";
          description = ''
            Number a phone transfers a call to, to park it. The slots follow
            it, so with 700 and 8 slots they are 701 to 708. Any phone takes
            a parked call by dialling its slot. With an attended transfer, the
            phone hears the slot before it completes the transfer.
          '';
        };
        slots = mkOption {
          type = types.ints.positive;
          default = 8;
          description = "Number of calls that can be parked at once, each in a slot of its own.";
        };
        timeout = mkOption {
          type = types.ints.positive;
          default = 45;
          description = ''
            Seconds a call stays parked. Then it rings the phone that parked
            it for that extension's `ringTime`, also while do not disturb is
            on, and if nobody answers goes on as the extension's unanswered
            calls do, to its no-answer forward or its `noAnswer` destination.
            A call parked by anything other than an extension, such as a tie
            line, ends instead.
          '';
        };
      };
    });
    default = null;
    example = {number = "700";};
    description = ''
      Call parking, off until set. Each slot has a busy lamp, lit while a
      call is parked in it, which phones get by subscribing to the slot's
      number.
    '';
  };

  config = mkIf (cfg.enable && parking != null) {
    services.asterisk = {
      modules.needed."services.asterix.parking" = ["res_parking.so"];

      # res_parking's default lot, which also takes the calls of the
      # parkcall feature
      settings."res_parking.conf".default = mapAttrs (_: mkDefault) {
        context = "pbx-parking";
        parkext = parking.number;
        parkpos = "${builtins.head slots}-${lib.last slots}";
        parkinghints = "yes";
        parkingtime = parking.timeout;
        # the timed out call enters comebackcontext at the parker's channel
        # name up to its last -, with / as _, or at s (res/parking/
        # parking_controller.c comeback_goto)
        comebacktoorigin = "no";
        comebackcontext = "pbx-parking-timeout";
      };

      dialplan.contexts.pbx-parking-timeout = {
        comment = mkDefault "from services.asterix.parking: parked calls nobody took in time";
        extensions =
          mapAttrs' (number: e:
            nameValuePair "PJSIP_${number}" [
              (app "Dial" [(pbxLib.devices number) e.ringTime])
              (app "Goto" [(pbxLib.objectContext "extension" number) "s" "noanswer"])
            ])
          cfg.extensions
          // {s = [(app "Hangup" [])];};
      };
    };
  };
}
