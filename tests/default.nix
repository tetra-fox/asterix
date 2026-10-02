# All flake checks. VM tests are nixosTest derivations; the rest are cheap
# evaluation/build checks.
{
  pkgs,
  self,
  sops-nix,
}: let
  inherit (pkgs) lib;

  sopsSecrets = import ./sops.nix {inherit pkgs sops-nix;};

  # Build-time failure with a readable report instead of an evaluation error,
  # so `nix flake check` still evaluates every other check.
  reportFailures = name: failures:
    pkgs.runCommand name
    {
      report = lib.generators.toPretty {} failures;
      passAsFile = ["report"];
    }
    ''
      if [ "$(cat "$reportPath")" != "[ ]" ]; then
        echo "failed:" >&2
        cat "$reportPath" >&2
        exit 1
      fi
      touch $out
    '';

  # every test in these suites evaluates a whole NixOS system, so a suite is
  # split into checks of partSize tests that parallel evaluation can spread
  # out; `check` makes the derivation of a part from its name and its tests
  partSize = 12;
  suiteParts = name: check: tests: let
    names = builtins.attrNames tests;
  in
    lib.listToAttrs (map (i: let
      part = toString (i + 1);
    in
      lib.nameValuePair "${name}-${part}" (check "asterisk-${name}-tests-${part}" (lib.getAttrs (lib.sublist (i * partSize) partSize names) tests)))
    (lib.range 0 ((builtins.length names - 1) / partSize)));

  # a suite whose `run` returns the tests that failed
  evalSuiteParts = name: suite: suiteParts name (check: tests: reportFailures check (suite.run tests)) suite.tests;

  examples = import ./examples.nix {inherit pkgs self sopsSecrets;};
  configCheck = import ./check.nix {
    inherit pkgs self;
    examples = examples.configs;
  };
  readme = import ./readme.nix {inherit pkgs self;};

  # the examples' configuration and checks with another Asterisk package, a
  # sample of the checks with each package (packages.nix)
  packageChecks = import ./packages.nix {inherit pkgs self sops-nix;};
  examplesWith = package:
    pkgs.linkFarm "asterisk-examples-config-${package}" (
      lib.mapAttrs (name: _: packageChecks.${package}."examples-config-${name}") examples.derivations
    );
in
  import ./lint.nix {inherit pkgs self;}
  // {
    lib-unit = reportFailures "asterisk-lib-unit-tests" (
      import ./lib.nix {
        inherit lib;
        asteriskLib = self.lib;
      }
    );

    pbx-timezones = import ./pbx/timezones.nix {inherit pkgs self;};

    examples = reportFailures "asterisk-examples-eval" examples.problems;

    # commands and calls on Asterisk in the build sandbox (tests/campaign/probe.nix)
    probe = import ./probe.nix {inherit pkgs self;};
    roundtrip = import ./roundtrip.nix {inherit pkgs self;};
    dialplan = import ./dialplan.nix {inherit pkgs self;};
    tollfraud = import ./tollfraud.nix {
      inherit pkgs self;
      examples = examples.configs;
    };
    codec-order = import ./codec-order.nix {inherit pkgs self;};
    musiconhold = import ./musiconhold.nix {inherit pkgs self;};
    voicemail = import ./voicemail.nix {inherit pkgs self;};
    pbx-destinations = import ./pbx/destinations.nix {inherit pkgs self;};
    pbx-numbering = import ./pbx/numbering.nix {inherit pkgs self;};
    pbx-outbound = import ./pbx/outbound.nix {inherit pkgs self;};
    pbx-external = import ./pbx/external.nix {inherit pkgs self;};
    pbx-extensions = import ./pbx/extensions.nix {inherit pkgs self;};
    pbx-names = import ./pbx/names.nix {inherit pkgs self;};
    pbx-menus = import ./pbx/menus.nix {inherit pkgs self;};
    pbx-queues = import ./pbx/queues.nix {inherit pkgs self;};
    pbx-paging = import ./pbx/paging.nix {inherit pkgs self;};

    # opening hours against their oracle at a seeded sample of instants in
    # every zone of tests/campaign/hours.nix, which hours.py sweep runs whole
    campaign-hours = let
      hours = import ./campaign/hours.nix {inherit pkgs self;};
    in
      hours.run {
        inherit (hours) zones;
        sample = 400;
      };

    examples-config-minimal = examples.derivations.minimal;
    examples-config-household-intercom = examples.derivations.household-intercom;
    examples-config-household-intercom-ht801 = examples.derivations.household-intercom-ht801;
    examples-config-small-office = examples.derivations.small-office;
    examples-config-asterisk_20 = examplesWith "asterisk_20";
    examples-config-asterisk_23 = examplesWith "asterisk_23";

    readme = reportFailures "asterisk-readme-eval" readme.problems;
    readme-config = pkgs.linkFarm "asterisk-readme-config" readme.derivations;

    vm-core = import ./vm/core.nix {inherit pkgs self;};

    vm-reload = import ./vm/reload.nix {inherit pkgs self sopsSecrets;};

    vm-minimal = import ./vm/minimal.nix {inherit pkgs self sopsSecrets;};

    vm-household-intercom = import ./vm/household-intercom.nix {inherit pkgs self sopsSecrets;};

    vm-small-office = import ./vm/small-office.nix {inherit pkgs self sopsSecrets;};

    vm-tier2 = import ./vm/tier2.nix {inherit pkgs self;};

    vm-tls-realtime = import ./vm/tls-realtime.nix {inherit pkgs self;};

    vm-ht801 = import ./vm/ht801.nix {inherit pkgs self sopsSecrets;};

    vm-calls = import ./vm/calls.nix {inherit pkgs self;};

    vm-transports = import ./vm/transports.nix {inherit pkgs self;};

    vm-security = import ./vm/security.nix {inherit pkgs self;};

    vm-firewall = import ./vm/firewall.nix {inherit pkgs self;};

    vm-tenants = import ./vm/tenants.nix {inherit pkgs self;};

    vm-trunks = import ./vm/trunks.nix {inherit pkgs self;};

    vm-pbx = import ./vm/pbx.nix {inherit pkgs self;};

    vm-pbx-calls = import ./vm/pbx-calls.nix {inherit pkgs self;};

    vm-upgrade = import ./vm/upgrade.nix {inherit pkgs self;};
    vm-faults = import ./vm/faults.nix {inherit pkgs self;};

    vm-faults-net = import ./vm/faults-net.nix {inherit pkgs self;};

    # builds the server and runs its unit tests
    provisioning-server = self.packages.${pkgs.stdenv.hostPlatform.system}.provisioning-server;

    # the server's fuzz target on its seeds and on the inputs libFuzzer derives from
    # them in a fixed number of runs
    provisioning-server-fuzz = let
      connection = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.provisioning-server-fuzz;
    in
      pkgs.runCommand "provisioning-server-fuzz-check" {} ''
        mkdir corpus
        ${connection} -seed=1 -runs=150000 -verbosity=0 -close_fd_mask=2 -print_final_stats=1 \
          -dict=${../pkgs/provisioning-server/fuzz/connection.dict} \
          corpus ${../pkgs/provisioning-server/fuzz/seeds/connection} || {
          # the target's stderr was closed: run the saved input again to show its panic
          ${connection} crash-*
          exit 1
        }
        touch $out
      '';

    # every option has a description and the reference builds
    docs = import ../docs {inherit pkgs self;};
  }
  # the pairwise rows of the environment matrix
  // lib.listToAttrs (map (test: lib.nameValuePair "vm-${test.name}" (import ./vm/matrix.nix {inherit pkgs self sopsSecrets test;}))
    (lib.importJSON ./campaign/matrix-pairwise.json).tests)
  // evalSuiteParts "eval" (import ./eval.nix {inherit pkgs self;})
  // evalSuiteParts "assertions" (import ./assertions.nix {inherit pkgs self;})
  // evalSuiteParts "pbx-eval" (import ./pbx/eval.nix {inherit pkgs self;})
  // evalSuiteParts "pbx-assertions" (import ./pbx/assertions.nix {inherit pkgs self;})
  // suiteParts "config-check" configCheck.run configCheck.tests
