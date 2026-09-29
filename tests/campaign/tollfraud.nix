# tollfraud.py on a system: the probe (probe.nix) shows the dialplan, the
# globals, the queues and the context of each trunk of
# services.asterisk.pjsip.trunks, and the walk writes every way from a trunk
# to a trunk's Dial to $out/report.json, and its exit code to $out/status.
# The outside numbers the configuration names are the external members of
# pbx.ringGroups, with the trunk each is called through.
#
#   tollfraud { name = "office"; config = evalConfig [ ./office.nix ]; }
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./probe.nix {inherit pkgs self;};
  scripts = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [./dialplan.py ./tollfraud.py];
  };
in
  {
    name,
    config,
  }: let
    trunks = builtins.attrNames config.services.asterisk.pjsip.trunks;
    pbx = config.pbx or {};
    # a ring group without a trunk of its own uses pbx.outbound's
    trunkOf = group:
      if group.trunk != null
      then group.trunk
      else pbx.outbound.trunk;
    named = lib.concatMap (group:
      map (number: {
        trunk = trunkOf group;
        inherit number;
      })
      group.external) (builtins.attrValues (pbx.ringGroups or {}));
    policy = pkgs.writeText "asterisk-tollfraud-${name}.json" (builtins.toJSON {inherit trunks named;});
    result = probe {
      name = "tollfraud-${name}";
      inherit config;
      commands = ["dialplan show" "dialplan show globals" "queue show"] ++ map (trunk: "pjsip show endpoint ${trunk}") trunks;
    };
  in
    pkgs.runCommand "asterisk-tollfraud-${name}" {} ''
      mkdir $out
      cp ${result}/probe.json $out/probe.json
      cp ${policy} $out/policy.json
      status=0
      ${lib.getExe pkgs.python3} ${scripts}/tollfraud.py walk $out/probe.json $out/policy.json > $out/report.json || status=$?
      echo "$status" > $out/status
    ''
