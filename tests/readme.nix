# The code blocks of README.md and PROVISIONING.md, read from the files: each
# evaluates to a system without failed assertions or warnings, the system's
# configuration and checks build, and where the text shows what a block
# renders, it renders that. A block that is not a whole configuration gets
# the smallest base that makes it one.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (builtins) elemAt;
  inherit (import ./eval-lib.nix {inherit pkgs self;}) evalConfig systemProblems systemBuild;
  inherit (self.inputs) nixpkgs sops-nix;

  # the fenced code blocks of a Markdown file in order: the language after the
  # fence, the text and the last line of text before the block
  blocksOf = file: let
    step = acc: line: let
      fence = builtins.match "```([a-z]*)" line;
    in
      if acc.open == null
      then
        if fence != null
        then
          acc
          // {
            open = {
              lang = builtins.head fence;
              inherit (acc) before;
              lines = [];
            };
          }
        else if line != ""
        then acc // {before = line;}
        else acc
      else if line == "```"
      then
        acc
        // {
          open = null;
          blocks =
            acc.blocks
            ++ [
              {
                inherit (acc.open) lang before;
                text = lib.concatMapStrings (l: "${l}\n") acc.open.lines;
              }
            ];
        }
      else acc // {open = acc.open // {lines = acc.open.lines ++ [line];};};
  in
    (lib.foldl' step {
      open = null;
      before = "";
      blocks = [];
    } (lib.splitString "\n" (builtins.readFile file))).blocks;

  # the blocks each test below expects, by language and start: one added,
  # removed or moved fails here instead of meeting another block's base
  outlineProblems = file: blocks: expected:
    lib.optional (
      builtins.length blocks
      != builtins.length expected
      || !(builtins.all (x: x) (lib.zipListsWith (block: e: block.lang == e.lang && lib.hasPrefix e.start block.text) blocks expected))
    ) {
      ${baseNameOf file} = {
        blocks = map (block: "${block.lang}: ${builtins.head (lib.splitString "\n" block.text)}") blocks;
        expected = map (e: "${e.lang}: ${lib.removeSuffix "\n" e.start}") expected;
      };
    };

  nixFile = name: text: builtins.toFile "${name}.nix" text;
  # attribute definitions without the braces of a module
  fragment = name: block: import (nixFile name "{ config, lib, ... }: {\n${block.text}}\n");

  readme = blocksOf ../README.md;
  provisioning = blocksOf ../PROVISIONING.md;

  readmeOutline = [
    {
      lang = "nix";
      start = "# flake.nix\n";
    }
    {
      lang = "nix";
      start = "# pbx.nix:";
    }
    {
      lang = "nix";
      start = "sops.secrets.sip-101.";
    }
    {
      lang = "nix";
      start = ''services.asterisk.settings."followme.conf"'';
    }
    {
      lang = "nix";
      start = ''services.asterisk.settings."pjsip.conf"'';
    }
    {
      lang = "nix";
      start = ''"Dial(PJSIP/'';
    }
    {
      lang = "nix";
      start = "{ config, ... }:\nlet\n  dp =";
    }
    {
      lang = "ini";
      start = "[internal]\n";
    }
    {
      lang = "nix";
      start = "{ config, ... }:\nlet\n  secret =";
    }
    {
      lang = "nix";
      start = "pbx = {\n  ivrs.";
    }
    {
      lang = "sh";
      start = "mkdir -p DIR/corpus\n";
    }
  ];
  provisioningOutline = [
    {
      lang = "nix";
      start = "pbx.phones = {\n";
    }
    {
      lang = "nix";
      start = ''pbx.phones.files."'';
    }
  ];

  # sops-nix as the quick start sets it up, with the key the host decrypts
  # with and a file with the keys the blocks name
  sopsKey = "/var/lib/sops-nix/key.txt";
  secretsFile = builtins.toFile "secrets.yaml" ''
    sip-101: ""
    sip-102: ""
  '';
  sopsBase = {
    imports = [sops-nix.nixosModules.sops];
    sops = {
      defaultSopsFile = secretsFile;
      age.keyFile = sopsKey;
    };
  };
  # an endpoint 101 in a context that exists, for the blocks that change one
  endpoint101 = {
    services.asterisk = {
      enable = true;
      pjsip = {
        transports.udp = {};
        endpoints."101".context = "phones";
      };
      dialplan.contexts.phones.extensions."_10X" = ["Dial(PJSIP/\${EXTEN},30)"];
    };
  };

  # the quick start: flake.nix with pbx.nix, and the host's own
  # configuration.nix with what sops-nix needs
  quickStart = let
    configuration = nixFile "configuration" ''
      {
        boot.isContainer = true;
        system.stateVersion = "26.05";
        sops.age.keyFile = "${sopsKey}";
      }
    '';
    pbx = nixFile "pbx" (lib.replaceStrings ["./secrets.yaml"] [''"${secretsFile}"''] (elemAt readme 1).text);
    flake = import (nixFile "flake" (lib.replaceStrings ["./configuration.nix" "./pbx.nix"] [''"${configuration}"'' ''"${pbx}"''] (elemAt readme 0).text));
    ours = import ../flake.nix;
  in {
    config =
      (flake.outputs {
        inherit nixpkgs sops-nix;
        asterix = self;
      }).nixosConfigurations.pbx.config;
    # the inputs it tells users to set are the ones this flake has
    problems =
      lib.optional (
        flake.inputs.nixpkgs.url
        != ours.inputs.nixpkgs.url
        || flake.inputs.sops-nix.url != ours.inputs.sops-nix.url
        || !(builtins.all (input: ours.inputs ? ${input}) (builtins.attrNames flake.inputs.asterix.inputs))
      ) {
        flakeInputs = {
          readme = flake.inputs;
          inherit (ours) inputs;
        };
      };
  };

  systems = {
    quick-start = quickStart.config;
    secrets = evalConfig [
      sopsBase
      endpoint101
      (fragment "readme-secrets" (elemAt readme 2))
    ];
    followme = evalConfig [
      {services.asterisk.enable = true;}
      (fragment "readme-followme" (elemAt readme 3))
    ];
    settings = evalConfig [
      endpoint101
      (fragment "readme-settings" (elemAt readme 4))
    ];
    # VoiceMail(101@default) needs the mailbox, which loads app_voicemail
    dialplan = evalConfig [
      ({config, ...}: {
        services.asterisk = {
          enable = true;
          voicemail.mailboxes."101".pin = config.lib.asterisk.secret "/run/secrets/vm-101";
        };
      })
      (import (nixFile "readme-dialplan" (elemAt readme 6).text))
    ];
    # the block imports the pbx layer from the flake input `asterix`, as
    # flake.nix has it, and uses the sops secrets it names
    pbx = evalConfig pbxModules;
    pbx-menus = evalConfig (pbxModules ++ [(fragment "readme-pbx-menus" (elemAt readme 9))]);
    phones = evalConfig phoneModules;
    phone-files = evalConfig (phoneModules ++ [(fragment "provisioning-files" (elemAt provisioning 1))]);
  };
  pbxModules = [
    sopsBase
    {sops.secrets = lib.genAttrs ["sip-201" "vm-201" "sip-202" "vm-202" "sip-trunk"] (_: {});}
    (import (nixFile "readme-pbx" "asterix: ${(elemAt readme 8).text}") self)
  ];
  # the pbx layer and an endpoint 101 whose password is the sops secret sip-101
  phoneModules = [
    self.nixosModules.pbx
    sopsBase
    endpoint101
    ({config, ...}: {
      sops.secrets.sip-101 = {};
      services.asterisk.pjsip.endpoints."101".auth.password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
    })
    (fragment "provisioning-phones" (elemAt provisioning 0))
  ];

  # "Each of these produces `...`:", with `var` as the comment says
  escapingProblems = let
    block = elemAt readme 5;
    produces = builtins.head (builtins.match ".*produces `([^`]*)`.*" block.before);
    inherit (systems.dialplan.lib.asterisk.dialplan) var;
    values = lib.imap1 (i: line: import (nixFile "readme-escaping-${toString i}" "var: ${line}\n") var) (
      lib.filter (line: line != "") (lib.splitString "\n" block.text)
    );
  in
    lib.optional (builtins.any (value: value != produces) values) {
      escaping = {
        expected = produces;
        inherit values;
      };
    };

  # the dialplan block "renders the following": the context the text shows
  renderedProblems = let
    shown = (elemAt readme 7).text;
    header = builtins.head (lib.splitString "\n" shown);
    context =
      lib.findFirst (lib.hasPrefix header) "" (lib.splitString "\n\n" systems.dialplan.services.asterisk.renderedFiles."extensions.conf")
      + "\n";
  in
    lib.optional (context != shown) {
      rendered = {
        inherit shown context;
      };
    };

  # the fuzzing commands name files of this repository and the fuzz target's
  # program, as `nix build` links it to result/
  fuzzingProblems = let
    words = lib.filter (word: builtins.isString word && word != "") (builtins.split "[[:space:]=\\]+" (elemAt readme 10).text);
    missing = lib.filter (word: lib.hasPrefix "pkgs/" word && !builtins.pathExists (../. + "/${word}")) words;
    programs = map (lib.removePrefix "result/") (lib.filter (lib.hasPrefix "result/") words);
    program = "bin/${baseNameOf (lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.provisioning-server-fuzz)}";
  in
    lib.optional (missing != [] || lib.unique programs != [program]) {
      fuzzing = {
        inherit missing programs program;
      };
    };

  # the P-values of the HT801 table are what the adapter's file has, except
  # the ones set only on request
  tableProblems = let
    rows = lib.filter (line: builtins.match "[|] P[0-9]+ .*" line != null) (lib.splitString "\n" (builtins.readFile ../PROVISIONING.md));
    cells = row: map lib.trim (lib.filter builtins.isString (builtins.split "[|]" row));
    listed = map (row: elemAt (cells row) 1) (lib.filter (row: !(lib.hasInfix "if set" (elemAt (cells row) 3))) rows);
    files = lib.filterAttrs (name: _: lib.hasPrefix "cfg" name) systems.phones.pbx.phones.files;
    rendered = map builtins.head (lib.filter builtins.isList (builtins.split "<(P[0-9]+)>" (builtins.head (lib.attrValues files)).text));
  in
    lib.optional (lib.sort lib.lessThan listed != lib.sort lib.lessThan rendered) {
      ht801Table = {
        inherit listed rendered;
      };
    };
  outline =
    outlineProblems ../README.md readme readmeOutline
    ++ outlineProblems ../PROVISIONING.md provisioning provisioningOutline;
in {
  problems =
    if outline != []
    then outline
    else
      lib.concatLists (lib.mapAttrsToList systemProblems systems)
      ++ quickStart.problems
      ++ escapingProblems
      ++ renderedProblems
      ++ fuzzingProblems
      ++ tableProblems;

  derivations = lib.mapAttrs (_: systemBuild) {
    inherit (systems) quick-start secrets followme settings dialplan pbx-menus phone-files;
  };
}
