# The gate's share of the generated-configuration campaign (configs.py): the
# seeded configurations of configs-sample.json, which
#
#   configs.py sample tests/campaign/configs-sample.json OUT --seed 1
#
# writes, with the arguments that draw them. Each valid one evaluates without
# a failed assertion or a warning (T0) and boots (T1), each mutation fails at
# evaluation, the calls of the probed ones end where the routing oracle
# predicted (T1 probe), and the file is what its arguments draw today.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  campaign = import ./configs.nix {inherit pkgs self;};
  probe = import ./probe.nix {inherit pkgs self;};
  sample = (builtins.fromJSON (builtins.readFile ./configs-sample.json)).configurations;
  python = pkgs.python3.withPackages (p: [p.hypothesis]);
  # configs.py where a checkout has it, below tests/: Hypothesis also draws
  # constants of the code it runs from, except of files below a directory
  # named tests (hypothesis/internal/constants_ast.py is_local_module_file),
  # so from anywhere else the sample would come out different
  configs = "${self}/tests/campaign/configs.py";

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
  in "${lib.getExe python} ${configs} compare ${spec} ${result}/probe.json")
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
    ${lib.getExe python} ${configs} sample ${./configs-sample.json} --check
    ${lib.concatStringsSep "\n" compared}
    cp "$casesPath" $out
  ''
