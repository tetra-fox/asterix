# services.asterix.blocklist: callers turned away on calls from trunks, in
# pbx-blocklist. Each route of services.asterix.inbound calls its `s` first,
# which returns `blocked` for a caller on the list, and the call then goes to
# the extension `blocked`.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMapStringsSep
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterix;
  bl = cfg.blocklist;
  pbxLib = import ./lib.nix {inherit lib;};

  # an entry that is not a number or pattern has no extension, the assertion
  # below names it
  numbers = builtins.partition (number: builtins.match pbxLib.numberOrPattern number != null) (lib.unique bl.numbers);
in {
  options.services.asterix.blocklist = {
    numbers = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["+15551234567" "15551234567" "5551234567" "_1800XXXXXXX"];
      description = ''
        Callers turned away on calls from trunks, unless the number of
        {option}`services.asterix.inbound` they called sets
        `blocklist = false`. Calls between extensions are not checked, and
        neither are calls from a trunk with a `context` of its own.

        A caller is known by the user part of From, or of P-Asserted-Identity
        or Remote-Party-ID on a trunk that trusts them (`trust_id_inbound`).
        A number matches only as written, so +15551234567, 15551234567 and
        5551234567 are three numbers. List each form the provider sends.

        An entry is a number of digits, `*` and `#` with an optional leading
        `+`, or a dialplan pattern such as `_1800XXXXXXX`.
      '';
    };

    anonymous = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to turn away callers who withhold their number, on the same
        calls as `numbers`: those whose number is empty, or is `anonymous`,
        `restricted` or `unavailable` in any case, and those whose
        presentation is not allowed. `Privacy: id` counts only on a trunk
        that trusts P-Asserted-Identity (`trust_id_inbound`). A provider that
        sends a number of its own for a withheld one needs that number in
        `numbers`.
      '';
    };

    destination = mkOption {
      type = pbxLib.destination;
      default = {hangup = true;};
      description = "Where a call from a caller turned away goes.";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts = mkIf (pbxLib.blocksCallers bl) {
      pbx-blocklist = {
        comment = mkDefault "from services.asterix.blocklist";
        # Asterisk takes s/<number>, which matches the caller's number, before
        # s (main/pbx.c ast_add_extension2_lockopt)
        extensions =
          lib.listToAttrs (map (number: lib.nameValuePair "s/${number}" [(pbxLib.app "Return" ["blocked"])]) numbers.right)
          // {
            s =
              lib.optionals bl.anonymous [
                # every presentation but allowed* withholds the number, and
                # one without a number is unavailable (main/channel.c
                # ast_party_id_presentation)
                (pbxLib.app "GotoIf" [''$["''${CALLERID(pres):0:7}" != "allowed"]?withheld''])
                # the caller's number stays out of an expression, which runs
                # any function written into it, and goes into REGEX, which
                # gives 0 or 1
                (pbxLib.app "GotoIf" [''''${REGEX("^(anonymous|restricted|unavailable)$" ''${TOLOWER(''${CALLERID(num)})})}?withheld''])
              ]
              ++ [(pbxLib.app "Return" [])]
              ++ lib.optional bl.anonymous {
                app = "Return";
                args = ["blocked"];
                label = "withheld";
              };
            blocked = pbxLib.steps bl.destination;
          };
      };
    };

    assertions = [
      {
        assertion = numbers.wrong == [];
        message = "services.asterix.blocklist.numbers: an entry must be a number of digits, * and #, with an optional leading +, or a pattern of such numbers that starts with _, such as _555XXXXXXX: ${concatMapStringsSep ", " builtins.toJSON numbers.wrong}.";
      }
    ];
  };
}
