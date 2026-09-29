# The T1 probe: starts Asterisk on a configuration the way its build-time
# check does, with the same arguments (modules/asterisk.nix), runs CLI
# commands and places calls, and writes what they did to $out/probe.json. The
# fields are described in probe.py.
#
#   probe {
#     name = "menu";
#     modules = [ self.nixosModules.pbx ./office.nix ];
#     commands = [ "dialplan show pbx-internal" ];
#     calls = [ { extension = "700"; context = "pbx-internal"; keys = "1"; } ];
#   }
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig failedAssertions;
  check = lib.getExe (pkgs.callPackage ../../pkgs/config-check/package.nix {});
  python = lib.getExe pkgs.python3;
in
  {
    name,
    modules,
    commands ? [],
    calls ? [],
  }: let
    config = evalConfig modules;
    failed = failedAssertions config;
    configCheck = lib.findFirst (c: lib.hasPrefix "asterisk-config-check" c.name) (throw "probe ${name}: services.asterisk.checkConfig is off") config.system.checks;
    spec = pkgs.writeText "asterisk-probe-${name}.json" (builtins.toJSON {inherit commands calls;});
    drive = pkgs.writeShellScript "asterisk-probe-${name}-drive" ''
      exec ${python} ${./probe.py} drive ${spec} "$out" "$@"
    '';
  in
    assert lib.assertMsg (failed == []) "probe ${name}: the configuration has failed assertions:\n${lib.concatStringsSep "\n" failed}";
      pkgs.runCommand "asterisk-probe-${name}" {} ''
        mkdir $out
        ${check} --probe ${drive} ${lib.escapeShellArgs configCheck.arguments}
        ${python} ${./probe.py} report $out
      ''
