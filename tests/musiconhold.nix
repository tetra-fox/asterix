# Music on hold classes of each mode and sort through the probe
# (tests/campaign/probe.nix): Asterisk lists them as the options say, and a
# call to each starts that class. `random` and no sort differ only in the order
# files play, which the probe does not see.
{
  pkgs,
  self,
}: let
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  moh = "${pkgs.asterisk}/var/lib/asterisk/moh";
  officeMusic = pkgs.linkFarm "office-moh" [
    {
      name = "hold.wav";
      path = "${moh}/macroform-cold_day.wav";
    }
  ];
  stream = "${pkgs.coreutils}/bin/cat /dev/zero";

  classes = {
    alpha = {
      directory = "moh";
      sort = "alpha";
    };
    random = {
      directory = "moh";
      sort = "random";
    };
    randstart = {
      directory = "moh";
      sort = "randstart";
    };
    unsorted.directory = "moh";
    store.directory = officeMusic;
    list = {
      mode = "playlist";
      entries = [
        "${moh}/reno_project-system"
        "${moh}/macroform-cold_day"
      ];
    };
    stream = {
      mode = "custom";
      application = stream;
    };
  };

  result = probe {
    name = "musiconhold";
    modules = [
      {
        services.asterisk = {
          enable = true;
          musicOnHold = {inherit classes;};
          dialplan.contexts.moh.extensions."_[a-z]." = [
            "Answer()"
            "MusicOnHold(\${EXTEN},1)"
            "Hangup()"
          ];
        };
      }
    ];
    commands = [
      "moh show classes"
      "moh show files"
    ];
    calls = map (class: {
      extension = class;
      context = "moh";
    }) (builtins.attrNames classes);
  };

  # what `moh show classes` says about each class
  shown = {
    alpha = "Class: alpha\n\tMode: files\n\tDirectory: moh\n";
    random = "Class: random\n\tMode: files\n\tDirectory: moh\n";
    randstart = "Class: randstart\n\tMode: files\n\tDirectory: moh\n";
    unsorted = "Class: unsorted\n\tMode: files\n\tDirectory: moh\n";
    store = "Class: store\n\tMode: files\n\tDirectory: ${officeMusic}\n";
    list = "Class: list\n\tMode: playlist\n\tDirectory: nodir\n\tFormat: slin\n";
    stream = "Class: stream\n\tMode: custom\n\tDirectory: nodir\n\tApplication: ${stream}\n";
  };

  # the files of the classes whose order the options set, as `moh show files`
  # lists them
  files = {
    alpha = [
      "macroform-cold_day"
      "macroform-robot_dity"
      "macroform-the_simplicity"
      "manolo_camp-morning_coffee"
      "reno_project-system"
    ];
    randstart = files.alpha;
    store = ["hold"];
    list = [
      "reno_project-system"
      "macroform-cold_day"
    ];
  };
in
  pkgs.runCommand "asterisk-musiconhold-tests" {
    nativeBuildInputs = [pkgs.jq];
    expected = builtins.toJSON {inherit shown files;};
    passAsFile = ["expected"];
  } ''
    jq -r --slurpfile expected "$expectedPath" --arg quote "'" '
      def output($command): .commands[] | select(.command == $command) | .output;
      # the file names `moh show files` lists for a class
      def files($class): output("moh show files") | split("Class: ")[]
        | split("\n") | select(.[0] == $class) | .[1:]
        | map(select(startswith("\tFile: ")) | split("/") | last);
      . as $probe
      | $expected[0] as $expected
      | ($expected.shown[]
          | . as $text
          | select($probe | output("moh show classes") | contains($text) | not)
          | "`moh show classes` does not show \($text | tojson)"),
        ($expected.files | to_entries[]
          | . as {key: $class, value: $files}
          | select([$probe | files($class)] != [$files])
          | "`moh show files` lists \([$probe | files($class)] | first | tojson) for \($class), not \($files | tojson)"),
        ($probe.calls[]
          | . as $call
          | select(any($call.log[]; .message | startswith("Started music on hold, class \($quote)\($call.extension)\($quote)")) | not)
          | "the call to \($call.extension) did not start its class, but logged \($call.log | map(.message) | tojson)")
    ' ${result}/probe.json > missing
    if [ -s missing ]; then
      cat missing >&2
      exit 1
    fi
    touch $out
  ''
