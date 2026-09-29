# The gate's share of the options campaign: cases picked by a fixed seed,
# each evaluated against what it expects (T0), and the valid ones booted by
# Asterisk in as few configurations as their settings allow (T1). The cases
# in known.nix stay out; options.py runs every case.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  campaign = import ./options.nix {inherit pkgs self;};
  known = import ./known.nix;

  seed = "asterix";
  size = 50;
  rank = case: builtins.hashString "sha256" "${seed}:${case.id}";
  sample = lib.take size (lib.sort (a: b: rank a < rank b) (builtins.filter (case: !(known ? ${case.id})) campaign.cases));

  evaluated = case: let
    result = builtins.tryEval (let
      outcome = campaign.outcome "light" case;
    in
      builtins.deepSeq outcome outcome);
  in
    if result.success
    then {
      rejected = result.value.failed != [];
      outcome = result.value;
    }
    else {rejected = true;};

  # what differs from the expectation at evaluation; rejections at boot and
  # boots of strings are left to options.py
  problem = case: let
    e = evaluated case;
  in
    {
      accept = lib.optionalString e.rejected "rejected at evaluation";
      warn =
        if e.rejected
        then "rejected at evaluation"
        else lib.optionalString (e.outcome.warnings == []) "no warning";
      reject = lib.optionalString (!e.rejected) "evaluates";
      verbatim = lib.optionalString (!e.rejected && !(e.outcome.verbatim or true)) "not written as given";
    }
    .${
      case.expect
    };
  problems = lib.concatMap (case: let
    p = problem case;
  in
    lib.optional (p != "") {${case.id} = p;})
  sample;

  # the valid cases that boot Asterisk, packed like options.py does: no path
  # set to two values, nothing set below a value another case sets, the same
  # modules loaded, and none that turns the check off for the others
  valid = builtins.filter (case:
    builtins.elem case.expect ["accept" "warn"]
    && builtins.any (check: check.name == "asterisk-config-check") (campaign.checksOf case))
  sample;
  prefixes = path: map (i: builtins.substring 0 i path) (builtins.filter (i: builtins.substring i 1 path == ".") (lib.range 0 (builtins.stringLength path - 1)));
  fits = batch: claims:
    builtins.all (claim:
      (batch.taken.${claim.path} or claim.value)
      == claim.value
      && !(batch.below ? ${claim.path})
      && !(builtins.any (p: batch.taken ? ${p}) (prefixes claim.path)))
    claims;
  add = batch: case: claims: {
    cases = batch.cases ++ [case];
    taken = batch.taken // lib.listToAttrs (map (claim: lib.nameValuePair claim.path claim.value) claims);
    below = batch.below // lib.genAttrs (lib.concatMap (claim: prefixes claim.path) claims) (_: true);
  };
  empty = {
    cases = [];
    taken = {};
    below = {};
  };
  batches =
    lib.foldl' (batches: case: let
      claims = campaign.claims case ((evaluated case).outcome or {});
      i = lib.lists.findFirstIndex (batch: batch.cases != [] && (builtins.head batch.cases).base == case.base && fits batch claims) null batches;
    in
      if i == null
      then batches ++ [(add empty case claims)]
      else
        lib.imap0 (j: batch:
          if j == i
          then add batch case claims
          else batch)
        batches)
    []
    valid;
  boots = lib.concatMap (batch: campaign.checksOf (campaign.combined batch.cases)) batches;
in
  pkgs.runCommand "asterisk-campaign-options"
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
      echo "cases that did not do what they expect:" >&2
      cat "$reportPath" >&2
      exit 1
    fi
    cp "$casesPath" $out
  ''
