# The gate's share of the generated-configuration campaign (configs.py): the
# seeded configurations of configs-sample.json, which `configs.py sample`
# writes. Each valid one evaluates without a failed assertion or a warning
# (T0) and boots (T1), each mutation fails at evaluation, and the calls of
# the probed ones end where the routing oracle predicted (T1 probe).
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  campaign = import ./configs.nix {inherit pkgs self;};
  probe = import ./probe.nix {inherit pkgs self;};
  sample = builtins.fromJSON (builtins.readFile ./configs-sample.json);
  python = pkgs.python3.withPackages (p: [p.hypothesis]);

  evaluated = case: let
    result = builtins.tryEval (let
      outcome = campaign.outcome "light" case.modules;
    in
      builtins.deepSeq outcome outcome);
  in
    if result.success
    then result.value
    else {failed = ["evaluation error"];};

  problem = case: let
    o = evaluated case;
  in
    if case.expect == "reject"
    then lib.optionalString (o.failed == []) "evaluates"
    else lib.optionalString (o.failed != [] || o.warnings != []) "failed assertions or warnings: ${builtins.toJSON (o.failed ++ o.warnings)}";
  problems = lib.concatMap (case: let
    p = problem case;
  in
    lib.optional (p != "") {${case.id} = p;})
  sample;

  accepted = builtins.filter (case: case.expect == "accept") sample;
  boots = lib.concatMap (case: campaign.bootChecks (campaign.evaluate "light" case.modules)) accepted;
  probed = builtins.filter (case: case ? plan) accepted;
  compared = map (case: let
    result = probe {
      name = "campaign-${case.id}";
      config = campaign.evaluate "light" case.modules;
      calls = map (p: p.call) case.plan;
    };
    spec = pkgs.writeText "campaign-${case.id}.json" (builtins.toJSON case);
  in "${lib.getExe python} ${./.}/configs.py compare ${spec} ${result}/probe.json")
  probed;
in
  pkgs.runCommand "asterisk-campaign-configs"
  {
    inherit boots;
    report = lib.generators.toPretty {} problems;
    cases = lib.concatMapStringsSep "\n" (case: "${case.expect}: ${case.id}") sample;
    passAsFile = [
      "report"
      "cases"
    ];
  }
  ''
    if [ "$(cat "$reportPath")" != "[ ]" ]; then
      echo "configurations that did not do what they expect:" >&2
      cat "$reportPath" >&2
      exit 1
    fi
    ${lib.concatStringsSep "\n" compared}
    cp "$casesPath" $out
  ''
