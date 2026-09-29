# The build-time check of pbx.hours time zones fails on names tzdata does not
# have as a zone, and passes real ones.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig;

  checkFor = timezone:
    lib.findFirst (check: check.name == "pbx-hours-timezones") (throw "no time zone check")
    (evalConfig [
      {
        imports = [self.nixosModules.pbx];
        pbx = {
          enable = true;
          hours.office = {
            inherit timezone;
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
          };
        };
      }
    ]).system.checks;

  # a misspelt zone, and a text file of zoneinfo
  failing = [
    "America/Los_Angles"
    "leapseconds"
  ];
  passing = [
    "America/Los_Angeles"
    "UTC"
  ];
in
  pkgs.runCommand "asterisk-pbx-timezone-tests" {} ''
    ${lib.concatMapStrings (zone: ''
        grep -qF ${lib.escapeShellArg "pbx.hours: ${zone} is not a time zone of tzdata"} ${pkgs.testers.testBuildFailure (checkFor zone)}/testBuildFailure.log
      '')
      failing}
    : ${lib.concatMapStringsSep " " (zone: "${checkFor zone}") passing}
    touch $out
  ''
