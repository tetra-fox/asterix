# pbx.hours: when a business is open, as a Gosub routine in pbx-hours-<name>
# that returns `open` or `closed`. The close-early toggle is a custom device
# state, which Asterisk keeps in astdb: runtime state, set from a phone, not
# from Nix.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    escapeShellArgs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    types
    unique
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};

  day = "(sun|mon|tue|wed|thu|fri|sat)";
  days = "${day}(-${day})?";
  month = "(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)";

  rangeType = types.submodule {
    options = {
      days = mkOption {
        type = types.strMatching "[*]|${days}(&${days})*";
        example = "mon-fri";
        description = "Days of the week: `mon-fri`, `sat`, `mon&wed`, or `*` for every day.";
      };
      time = mkOption {
        type = types.strMatching "[0-2][0-9]:[0-5][0-9]-[0-2][0-9]:[0-5][0-9]";
        example = "09:00-17:00";
        description = "Opening hours of those days, in `timezone`.";
      };
    };
  };

  hoursType = types.submodule {
    options = {
      timezone = mkOption {
        type = types.strMatching "[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*";
        example = "America/Los_Angeles";
        description = ''
          Time zone of the opening hours, from the tz database (tzdata).
          Required: NixOS servers usually run in UTC.
        '';
      };
      open = mkOption {
        type = types.nonEmptyListOf rangeType;
        example = [
          {
            days = "mon-fri";
            time = "09:00-17:00";
          }
        ];
        description = "Opening hours; outside them it is closed.";
      };
      holidays = mkOption {
        type = types.listOf (types.strMatching "${month} [0-3]?[0-9](-[0-3]?[0-9])?");
        default = [];
        example = [
          "dec 24-26"
          "jan 1"
        ];
        description = "Days that are closed whatever `open` says, as `mon day` or `mon first-last`.";
      };
      closeEarly = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "*28";
        description = ''
          Number a phone dials to close now, and again to open again, for
          example when everyone leaves early. It also works as a busy lamp
          key, lit while closed. The state is kept by Asterisk (astdb), not
          in the Nix configuration.
        '';
      };
    };
  };

  zoneFile = zone: "${pkgs.tzdata}/share/zoneinfo/${zone}";

  hoursSection = name: hours: let
    state = "Custom:${pbxLib.objectContext "hours" name}";
    # GotoIfTime(times,weekdays,monthdays,months,zone?label); a zone name
    # starting with / is a file, which nixpkgs' asterisk needs: it only looks
    # for named zones in /usr/share/zoneinfo
    gotoIfTime = fields: label: "GotoIfTime(${lib.concatStringsSep "," (fields ++ [(zoneFile hours.timezone)])}?${label})";
    holiday = date: let
      parts = lib.splitString " " date;
    in
      gotoIfTime [
        "*"
        "*"
        (builtins.elemAt parts 1)
        (builtins.elemAt parts 0)
      ] "closed";
  in {
    comment = mkDefault "from pbx.hours.${name}";
    extensions =
      {
        s =
          optional (hours.closeEarly != null) (
            pbxLib.app "GotoIf" [''$["''${DEVICE_STATE(${state})}" = "INUSE"]?closed'']
          )
          ++ map holiday hours.holidays
          ++ map (range:
            gotoIfTime [
              range.time
              range.days
              "*"
              "*"
            ] "open")
          hours.open
          ++ [
            {
              app = "Return";
              args = ["closed"];
              label = "closed";
            }
            {
              app = "Return";
              args = ["open"];
              label = "open";
            }
          ];
      }
      // optionalAttrs (hours.closeEarly != null) {
        toggle = [
          (pbxLib.app "Answer" [])
          (pbxLib.app "GotoIf" [''$["''${DEVICE_STATE(${state})}" = "INUSE"]?reopen''])
          (pbxLib.app "Set" ["DEVICE_STATE(${state})=INUSE"])
          (pbxLib.app "Playback" ["activated"])
          (pbxLib.app "Hangup" [])
          {
            app = "Set";
            args = ["DEVICE_STATE(${state})=NOT_INUSE"];
            label = "reopen";
          }
          (pbxLib.app "Playback" ["de-activated"])
          (pbxLib.app "Hangup" [])
        ];
      };
  };

  zones = unique (map (hours: hours.timezone) (builtins.attrValues cfg.hours));
in {
  options.pbx.hours = mkOption {
    type = types.attrsOf hoursType;
    default = {};
    example = lib.literalExpression ''
      {
        office = {
          timezone = "America/Los_Angeles";
          open = [ { days = "mon-fri"; time = "09:00-17:00"; } ];
          holidays = [ "dec 25" "jan 1" ];
          closeEarly = "*28";
        };
      }
    '';
    description = "Opening hours, used by {option}`pbx.inbound` to route calls.";
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts = mapAttrs' (name: hours: nameValuePair (pbxLib.objectContext "hours" name) (hoursSection name hours)) cfg.hours;

    system.checks = optional (zones != []) (
      pkgs.runCommand "pbx-hours-timezones" {} ''
        for zone in ${escapeShellArgs zones}; do
          file="${zoneFile "$zone"}"
          # zoneinfo also holds tables and text files
          if [ ! -f "$file" ] || [ "$(head -c 4 "$file")" != TZif ]; then
            echo "pbx.hours: $zone is not a time zone of tzdata" >&2
            exit 1
          fi
        done
        touch $out
      ''
    );
  };
}
