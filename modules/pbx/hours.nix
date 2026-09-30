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
    concatLists
    concatMapStringsSep
    elemAt
    escapeShellArgs
    hasInfix
    mapAttrs'
    mapAttrsToList
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    showOption
    types
    unique
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};

  day = "(sun|mon|tue|wed|thu|fri|sat)";
  days = "${day}(-${day})?";
  # GotoIfTime skips a time past 23:59 or a day outside 1 to 31
  # (main/pbx_timing.c get_timerange and lookup_name)
  timeOfDay = "([01][0-9]|2[0-3]):[0-5][0-9]";
  monthDay = "(0?[1-9]|[12][0-9]|3[01])";
  # the days of each month, with feb 29 of leap years
  monthDays = {
    jan = 31;
    feb = 29;
    mar = 31;
    apr = 30;
    may = 31;
    jun = 30;
    jul = 31;
    aug = 31;
    sep = 30;
    oct = 31;
    nov = 30;
    dec = 31;
  };
  month = "(${lib.concatStringsSep "|" (builtins.attrNames monthDays)})";

  rangeType = types.submodule {
    options = {
      days = mkOption {
        type = types.strMatching "[*]|${days}(&${days})*";
        example = "mon-fri";
        description = "Days of the week: `mon-fri`, `sat`, `mon&wed`, or `*` for every day.";
      };
      time = mkOption {
        type = types.strMatching "${timeOfDay}-${timeOfDay}";
        example = "09:00-17:00";
        description = "Opening hours of those days, in `timezone`, up to the end of the last minute: `00:00-23:59` is the whole day.";
      };
    };
  };

  hoursType = types.submodule {
    options = {
      timezone = mkOption {
        type = types.strMatching "[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*";
        example = "America/Los_Angeles";
        description = ''
          Time zone of the opening hours, from the tz database (tzdata), but
          not one of `right/`, which count leap seconds. Required: NixOS
          servers usually run in UTC.
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
        type = types.listOf (types.strMatching "${month} ${monthDay}(-${monthDay})?");
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
          Number a phone dials to close now, whatever `open` says, for
          example when everyone leaves early, and again to go back to `open`.
          It stays closed until then, across days and restarts. It also works
          as a busy lamp key, lit while closed this way. The state is kept by
          Asterisk (astdb), not in the Nix configuration.
        '';
      };
    };
  };

  zoneFile = zone: "${pkgs.tzdata}/share/zoneinfo/${zone}";
  stateDevice = name: "Custom:${pbxLib.objectContext "hours" name}";

  # Asterisk cuts device names at 79 bytes (main/devicestate.c
  # ast_devstate_changed), so the busy lamp of a longer one never lights
  maxNameLength = 79 - builtins.stringLength (stateDevice "");

  # Gosub ends its target at the first (; with closeEarly, Set() ends the
  # variable at = and the hint splits its devices at &
  badNames = builtins.filter (name:
    pbxLib.breaksContext name
    || hasInfix "(" name
    || (cfg.hours.${name}.closeEarly != null && (hasInfix "=" name || hasInfix "&" name || builtins.stringLength name > maxNameLength)))
  (builtins.attrNames cfg.hours);

  # a day its month lacks never comes, and GotoIfTime wraps a range that
  # ends before it starts within the month (main/pbx_timing.c get_range)
  badHolidays = concatLists (mapAttrsToList (name: hours:
    map (date: "${showOption ["pbx" "hours" name "holidays"]}: ${date}") (builtins.filter (date: let
      m = builtins.match "([a-z]+) ([0-9]+)(-([0-9]+))?" date;
      first = lib.toIntBase10 (elemAt m 1);
      last =
        if elemAt m 3 == null
        then first
        else lib.toIntBase10 (elemAt m 3);
    in
      first > monthDays.${elemAt m 0} || last < first)
    hours.holidays))
  cfg.hours);

  # Asterisk takes the leap seconds of a zone file into its local time
  # (main/stdtime/localtime.c timesub), which the system clock does not count
  leapZones = lib.filterAttrs (_: hours: lib.hasPrefix "right/" hours.timezone) cfg.hours;

  hoursSection = name: hours: let
    state = stateDevice name;
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
    description = ''
      Opening hours, used by {option}`pbx.inbound` to route calls. A name
      cannot contain `,` `;` `[` `]` `''${` `$[` `(` or a line break, nor end
      with white space, and with `closeEarly` not `&` or `=` either, nor be
      longer than ${toString maxNameLength} bytes.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.dialplan.contexts = mapAttrs' (name: hours: nameValuePair (pbxLib.objectContext "hours" name) (hoursSection name hours)) cfg.hours;

    assertions = [
      {
        assertion = badNames == [];
        message = ''
          pbx.hours: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] ''${ $[ or (, nor & or = or more than ${toString maxNameLength} bytes with closeEarly):
            ${concatMapStringsSep "\n  " (name: showOption ["pbx" "hours" name]) badNames}
        '';
      }
      {
        assertion = badHolidays == [];
        message = ''
          pbx.hours: holidays on a day their month does not have, or that end before they start:
            ${lib.concatStringsSep "\n  " badHolidays}
        '';
      }
      {
        assertion = leapZones == {};
        message = ''
          pbx.hours: time zones of right/, which count leap seconds as the system clock does not, so the hours would open and close 27 s late; use the zone without right/:
            ${concatMapStringsSep "\n  " (name: "${showOption ["pbx" "hours" name "timezone"]}: ${leapZones.${name}.timezone}") (builtins.attrNames leapZones)}
        '';
      }
    ];

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
