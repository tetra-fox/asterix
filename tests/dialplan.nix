# The dialplan options against an oracle (tests/campaign/dialplan.py) written
# from their descriptions and Asterisk's documented rules: for each number,
# `dialplan show NUMBER@CONTEXT` and the steps a call runs, through the probe
# (tests/campaign/probe.nix). The contexts come from three modules, so steps,
# includes and ignore patterns merge in module order, with lib.mkBefore and
# lib.mkAfter.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  probe = import ./campaign/probe.nix {inherit pkgs self;};

  # a list that goes first or last among the definitions of several modules
  before = values: {before = values;};
  after = values: {after = values;};

  # an extension that names itself, then hangs up
  marked = context: extension: ["NoOp(${context} ${extension})" "Hangup()"];

  modules = [
    {
      phones = {
        includes = [
          "internal"
          "outbound"
        ];
        switches = ["Loopback/@loop"];
        ignorePatterns = ["9"];
        extensions =
          lib.genAttrs [
            "100"
            "100/5551234"
            "1-01"
            "s"
            "_1XX"
            "_1[0-4]X"
            "_1NX"
            "_10[5-9]"
            "_1X."
            "_1X!"
          ] (marked "phones")
          // {
            goto = ["Goto(labels,start,top)"];
          };
      };
      internal = {
        ignorePatterns = ["2"];
        extensions = lib.genAttrs ["200" "_2XX" "_1XX"] (marked "internal");
      };
      outbound.extensions."_9X." = marked "outbound" "_9X.";
      emergency.extensions."911" = marked "emergency" "911";
      loop.extensions = lib.genAttrs ["201" "300"] (marked "loop");
      labels.extensions.start = [
        "NoOp(labels start)"
        "Goto(top)"
        "NoOp(labels skipped)"
      ];
      invalid.extensions = {
        "1" = ["Goto(2,1)"];
        i = marked "invalid" "i";
      };
      hangup.extensions = {
        "1" = marked "hangup" "1";
        h = ["NoOp(hangup h)"];
      };
    }
    {
      phones = {
        includes = before ["emergency"];
        ignorePatterns = ["8"];
        extensions."100" = before ["NoOp(phones 100 first)"];
      };
      labels.extensions.start = after [
        {
          app = "NoOp";
          args = ["labels top"];
          label = "top";
        }
        "Hangup()"
      ];
    }
    {
      phones = {
        # what the first module has already
        includes = ["internal"];
        switches = ["Loopback/@loop"];
        ignorePatterns = ["9"];
        hints."100" = "Custom:phones";
        extraConfig = ''
          exten => 400,1,NoOp(phones raw 400)
          exten => 400,2,Hangup()
        '';
        settings = [
          "500,1,NoOp(phones settings 500)"
          "500,2,Hangup()"
        ];
      };
    }
  ];

  query = context: number: {inherit context number;};
  queries =
    map (query "phones") [
      "100"
      "101"
      "102"
      "150"
      "107"
      "1000"
      "10"
      "s"
      "200"
      "250"
      "201"
      "911"
      "9123"
      "400"
      "500"
      "goto"
    ]
    ++ [
      (query "phones" "100" // {callerId = "5551234";})
      (query "labels" "start")
      (query "invalid" "1")
      (query "hangup" "1")
    ];

  order = value:
    if value ? before
    then lib.mkBefore value.before
    else if value ? after
    then lib.mkAfter value.after
    else value;
  toModule = contexts: {
    services.asterisk = {
      dialplan.contexts = lib.mapAttrs (_: context:
        lib.mapAttrs (key: value:
          if key == "extensions"
          then lib.mapAttrs (_: order) value
          else order value) (removeAttrs context ["settings"]))
      contexts;
      settings."extensions.conf" = lib.mapAttrs (_: context: {exten = context.settings;}) (lib.filterAttrs (_: context: context ? settings) contexts);
    };
  };

  result = probe {
    name = "dialplan";
    modules =
      [
        {
          services.asterisk = {
            enable = true;
            modules.load = ["pbx_loopback"];
          };
        }
      ]
      ++ map toModule modules;
    commands = map (q: "dialplan show ${q.number}@${q.context}") queries;
    calls = map (q: {extension = q.number;} // removeAttrs q ["number"]) queries;
  };
in
  pkgs.runCommand "asterisk-dialplan-tests" {
    scenario = builtins.toJSON {inherit modules queries;};
    passAsFile = ["scenario"];
  } ''
    ${lib.getExe pkgs.python3} ${./campaign/dialplan.py} check "$scenarioPath" ${result}/probe.json
    touch $out
  ''
