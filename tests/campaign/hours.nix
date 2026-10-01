# The opening hours oracle (hours.py) against the dialplan of pbx.hours, in
# the T1 probe: a few kinds of opening hours in each zone, instants that
# hours.py picks around their edges, offset changes, holidays and leap days,
# run through each pbx-hours-<name> routine with TESTTIME, then again while
# the close-early toggles are on and once they are off again.
#
#   run { zones = [ "UTC" ]; sample = 300; seed = "asterix"; }
#
# Without `sample` it runs every instant hours.py picks, in `chunks` calls:
# as many as its plan has (hours.py sweep).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./probe.nix {inherit pkgs self;};
  python = lib.getExe pkgs.python3;
  zoneinfo = "${pkgs.tzdata}/share/zoneinfo";
  # instants to a call: the check's logger drops what comes past a queue of
  # 1000 messages (main/logger.c logger_queue_limit), and an instant logs up
  # to 11 steps
  chunk = 50;

  zones = [
    "UTC"
    "Europe/London"
    # a negative daylight saving time in tzdata
    "Europe/Dublin"
    "America/New_York"
    "America/Los_Angeles"
    # southern hemisphere
    "Australia/Sydney"
    "America/Santiago"
    "Pacific/Auckland"
    # offsets of half and three quarters of an hour
    "Asia/Kolkata"
    "Asia/Kathmandu"
    "Pacific/Chatham"
    # a daylight saving time of half an hour
    "Australia/Lord_Howe"
    # changes at 26:00 and at -01:00, which need version 3 of the zone format
    "Asia/Jerusalem"
    "America/Nuuk"
    # daylight saving time off for Ramadan every year
    "Africa/Casablanca"
  ];

  kinds = {
    office = {
      open = [
        {
          days = "mon-fri";
          time = "09:00-17:00";
        }
        {
          days = "sat";
          time = "10:00-13:59";
        }
      ];
      holidays = [
        "dec 24-26"
        "jan 1"
        "feb 29"
      ];
    };
    # every night, a range of days that wraps around the week, single minutes
    # at both ends of the day, and holidays around the changes of offset
    night = {
      open = [
        {
          days = "*";
          time = "22:00-06:00";
        }
        {
          days = "fri-mon";
          time = "12:00-12:29";
        }
        {
          days = "tue&thu";
          time = "00:00-00:00";
        }
        {
          days = "wed-wed";
          time = "23:59-23:59";
        }
      ];
      holidays = [
        "mar 29-31"
        "oct 01-02"
      ];
    };
    # the hours in which offsets change
    shift = {
      open = [
        {
          days = "*";
          time = "01:00-02:59";
        }
        {
          days = "sat-sun";
          time = "00:00-23:59";
        }
      ];
      holidays = ["apr 5-6"];
    };
    # ranges past midnight on given days, also on days that wrap around the
    # week, which the routine splits at midnight
    overnight = {
      open = [
        {
          days = "fri";
          time = "22:00-06:00";
        }
        {
          days = "sat-mon";
          time = "23:00-00:30";
        }
      ];
    };
  };

  hoursOf = zones:
    lib.listToAttrs (lib.concatLists (lib.imap0 (i: timezone:
      lib.mapAttrsToList (kind: hours:
        lib.nameValuePair "z${toString i}-${kind}" (hours
          // {inherit timezone;}
          # in two zones: a toggle takes 1.6 s, the length of its prompt
          // lib.optionalAttrs (kind == "office" && i < 2) {closeEarly = "*5${toString i}";}))
      kinds)
    zones));
in {
  inherit zones;

  run = {
    zones ? [],
    sample ? null,
    seed ? "asterix",
    chunks ? (sample + chunk - 1) / chunk,
  }: let
    hours = hoursOf zones;
    hoursFile = pkgs.writeText "hours.json" (builtins.toJSON hours);
    plan = pkgs.runCommand "asterisk-hours-plan" {} ''
      ${python} ${./hours.py} plan ${hoursFile} ${zoneinfo} $out --chunk ${toString chunk} ${lib.optionalString (sample != null) "--sample ${toString sample} --seed ${seed}"}
    '';
    closingEarly = lib.filterAttrs (_: h: h ? closeEarly) hours;
    toggles =
      lib.mapAttrsToList (_: h: {
        extension = h.closeEarly;
        context = "pbx-internal";
      })
      closingEarly;
    sweep = extension: {
      inherit extension;
      context = "hours-sweep";
    };
    result = probe {
      name = "hours";
      modules = [
        {
          imports = [self.nixosModules.pbx];
          pbx = {
            enable = true;
            inherit hours;
          };
          services.asterisk.includes."extensions.conf" = ["${plan}/sweep.conf"];
        }
      ];
      calls =
        map (i: sweep "s${toString i}") (lib.range 0 (chunks - 1))
        ++ toggles
        ++ lib.mapAttrsToList (name: _: sweep "early-${name}") closingEarly
        ++ toggles
        ++ lib.mapAttrsToList (name: _: sweep "reopened-${name}") closingEarly;
    };
    report = pkgs.runCommand "asterisk-hours-report" {} ''
      ${python} ${./hours.py} check ${hoursFile} ${zoneinfo} ${plan}/plan.json ${result}/probe.json $out
    '';
  in
    pkgs.runCommand "asterisk-hours-oracle" {
      nativeBuildInputs = [pkgs.jq];
      passthru = {inherit plan report;};
    } ''
      if ! jq -e '.disagree == 0 and .problems == []' ${report}/report.json > /dev/null; then
        jq '.problems, .disagreements[:20]' ${report}/report.json >&2
        echo "the dialplan disagrees with the oracle, see ${report}/report.json" >&2
        exit 1
      fi
      cp ${report}/report.json $out
    '';
}
