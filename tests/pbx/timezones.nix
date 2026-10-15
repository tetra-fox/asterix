# The build-time check of services.asterix.hours time zones fails on names
# tzdata does not have as a zone, and passes a real one
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
        imports = [self.nixosModules.default];
        services.asterix = {
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
in
  pkgs.runCommand "asterisk-pbx-timezone-tests" {} ''
    ${lib.concatMapStrings (zone: ''
        grep -qF ${lib.escapeShellArg "services.asterix.hours: ${zone} is not a time zone of tzdata"} ${pkgs.testers.testBuildFailure (checkFor zone)}/testBuildFailure.log
      '')
      failing}
    : ${checkFor "America/Los_Angeles"}
    touch $out
  ''
