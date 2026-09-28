# Each context is rendered into `settings."extensions.conf".<context>`, so
# extensions can be added there too. Every extension is written as one
# contiguous block: optional hint, then `exten => ext,1,...` followed by
# `same => n,...` lines.
#
# Escaping: Asterisk variables look like Nix antiquotations. Write
# `"\${EXTEN}"` in double-quoted strings, `''${EXTEN}` in indented strings, or
# use `config.lib.asterisk.dialplan.var "EXTEN"`. Semicolons are escaped by
# the generator and must not be escaped by hand.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    attrNames
    attrValues
    concatLists
    concatMapStringsSep
    concatStringsSep
    filter
    filterAttrs
    hasInfix
    imap0
    isString
    mapAttrs
    mapAttrsToList
    mkDefault
    mkIf
    mkOption
    optional
    sort
    types
    unique
    ;

  cfg = config.services.asterisk;
  dcfg = cfg.dialplan;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;

  stepType =
    types.either types.str (
      types.submodule {
        options = {
          app = mkOption {
            type = types.str;
            example = "Dial";
            description = "Dialplan application name.";
          };
          args = mkOption {
            type = types.listOf (types.either types.str types.int);
            default = [];
            example = [
              "PJSIP/101"
              30
            ];
            description = "Application arguments, joined with commas (not escaped).";
          };
          label = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "voicemail";
            description = "Priority label, usable as a Goto() target.";
          };
        };
      }
    )
    // {
      description = ''dialplan step ("App(arguments)" or { app, args, label })'';
    };

  contextType = types.submodule {
    options = {
      includes = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Contexts included in this one (`include =>`), searched in order.";
      };
      switches = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["Realtime/default@extensions"];
        description = "Alternative switches (`switch =>`).";
      };
      ignorePatterns = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["9"];
        description = "Patterns after which dial tone continues (`ignorepat =>`).";
      };
      extensions = mkOption {
        type = types.attrsOf (types.listOf stepType);
        default = {};
        example = lib.literalExpression ''
          {
            "100" = [ "Answer()" "Playback(hello-world)" "Hangup()" ];
            "_1XX" = [
              { app = "Dial"; args = [ "PJSIP/''${EXTEN}" 20 ]; }
              { app = "VoiceMail"; args = [ "''${EXTEN}@default" ]; label = "unavailable"; }
            ];
          }
        '';
        description = ''
          Extensions (patterns such as `_1XX` are allowed) mapped to their
          steps. The first step gets priority 1, the following ones `n`.
        '';
      };
      hints = mkOption {
        type = types.attrsOf types.str;
        default = {};
        example = {
          "101" = "PJSIP/101";
        };
        description = "Device state hints (`exten => 101,hint,PJSIP/101`) for BLF and presence.";
      };
      extraConfig = mkOption {
        type = types.lines;
        default = "";
        example = "exten => 999,1,Playback(tt-monkeys)";
        description = ''
          Raw dialplan lines for this context, written verbatim in a second
          `[context]` block at the end of the file (Asterisk merges both).
        '';
      };
    };
  };

  argString = arg:
    if isString arg
    then arg
    else toString arg;

  stepString = step:
    if isString step
    then step
    else "${step.app}(${concatMapStringsSep "," argString step.args})";

  priority = index: step:
    (
      if index == 0
      then "1"
      else "n"
    )
    + (
      if !(isString step) && step.label != null
      then "(${step.label})"
      else ""
    );

  extensionLines = context: extension:
    optional (context.hints ? ${extension}) "${extension},hint,${context.hints.${extension}}"
    ++ imap0 (i: step: "${extension},${priority i step},${stepString step}") (
      context.extensions.${extension} or []
    );

  contextSection = name: context: {
    inherit name;
    include = context.includes;
    switch = context.switches;
    ignorepat = context.ignorePatterns;
    exten = concatLists (
      map (extensionLines context) (
        sort (a: b: a < b) (unique (attrNames context.extensions ++ attrNames context.hints))
      )
    );
  };

  rawBlocks = concatStringsSep "\n\n" (
    mapAttrsToList (name: context: "[${name}]\n${context.extraConfig}") (
      filterAttrs (_: context: context.extraConfig != "") dcfg.contexts
    )
  );

  # Every context that exists at runtime, where that can be known: the
  # sections of extensions.conf, section headers in its raw text and the
  # contexts res_parking creates for its parking lots. Included files and AEL
  # or Lua dialplans can define any context.
  dialplan = cfg.settings."extensions.conf" or {};
  extra = cfg.extraConfig."extensions.conf" or "";
  toList = v:
    if builtins.isList v
    then v
    else [v];
  modulesConf = cfg.settings."modules.conf".modules or {};
  loaded = module:
    !(builtins.elem module (toList (modulesConf.noload or [])))
    && (
      builtins.elem (modulesConf.autoload or false) [
        true
        "yes"
      ]
      || builtins.elem module (toList (modulesConf.load or []) ++ toList (modulesConf.preload or []))
    );
  parkingLots = filter (lot: lot.name != "general") (attrValues (cfg.settings."res_parking.conf" or {}));
  parkingContexts =
    map (lot: lot.context or "parkedcalls") parkingLots
    # res_parking adds a lot called `default` when there is none
    ++ optional (!(builtins.any (lot: lot.name == "default") parkingLots)) "parkedcalls";
  knowable =
    (cfg.includes."extensions.conf" or [])
    == []
    && !(builtins.any (directive: hasInfix directive extra) [
      "#include"
      "#tryinclude"
      "#exec"
    ])
    && !(builtins.any (file: cfg.settings ? ${file} || cfg.extraConfig ? ${file}) [
      "extensions.ael"
      "extensions.lua"
    ]);
  knownContexts =
    if knowable
    then
      map (s: s.name) (attrValues dialplan)
      ++ lib.concatMap (
        line: let
          m = builtins.match "[[:space:]]*[[]([^]]+)[]].*" line;
        in
          if m == null
          then []
          else m
      ) (lib.splitString "\n" extra)
      ++ lib.optionals (loaded "res_parking.so") parkingContexts
    else null;

  danglingIncludes = lib.concatMap (
    s:
      map (target: "[${s.name}] include => ${target}") (
        filter (
          target: isString target && !(builtins.elem (lib.head (lib.splitString "," target)) knownContexts)
        ) (toList (s.include or []))
      )
  ) (attrValues dialplan);
  # Pre-dial subroutines of Dial()/Page() written as b(context^exten^priority)
  # or B(context^exten^priority).
  gosubTargets = line:
    lib.concatMap (m:
      if builtins.isList m
      then [(builtins.elemAt m 0)]
      else []) (
      builtins.split "[bB][(]([^()^,]+)\\^[^()^,]+\\^[0-9n]+[)]" line
    );
  danglingSubroutines = lib.concatMap (
    s:
      lib.concatMap (
        line:
          map (target: "[${s.name}] ${target} (in: ${line})") (
            filter (target: !(builtins.elem target knownContexts)) (gosubTargets line)
          )
      ) (filter isString (toList (s.exten or [])))
  ) (attrValues dialplan);
  emptyExtensions = lib.concatLists (
    mapAttrsToList (
      name: context:
        map (ext: "${name}/${ext}") (
          filter (ext: context.extensions.${ext} == [] && !(context.hints ? ${ext})) (
            attrNames context.extensions
          )
        )
    )
    dcfg.contexts
  );
  badExtensionNames = lib.concatLists (
    mapAttrsToList (
      name: context:
        map (ext: "${name}/${ext}") (
          filter (ext: builtins.match "[^,;[:space:]]+" ext == null) (
            attrNames context.extensions ++ attrNames context.hints
          )
        )
    )
    dcfg.contexts
  );
in {
  options.services.asterisk.dialplan = {
    general = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        autofallthrough = false;
      };
      description = ''
        Keys of the `[general]` section. The module sets `static`,
        `writeprotect` (Asterisk must not rewrite the generated dialplan) and
        `clearglobalvars` (removed globals disappear on reload) to `yes`.
      '';
    };

    globals = mkOption {
      type = types.attrsOf format.types.atom;
      default = {};
      example = lib.literalExpression ''
        {
          TRUNK = "PJSIP/provider";
          OPERATOR = "101";
        }
      '';
      description = "Global variables (`[globals]`), readable as `\${NAME}` in the dialplan.";
    };

    contexts = mkOption {
      type = types.attrsOf contextType;
      default = {};
      example = lib.literalExpression ''
        {
          internal = {
            hints."101" = "PJSIP/101";
            extensions = {
              "_1XX" = [ "Dial(PJSIP/''${EXTEN},30)" "Hangup()" ];
              "*97" = [ "VoiceMailMain(''${CALLERID(num)}@default)" ];
            };
          };
          phones.includes = [ "internal" ];
        }
      '';
      description = "Dialplan contexts.";
    };

    knownContexts = mkOption {
      type = types.nullOr (types.listOf types.str);
      readOnly = true;
      internal = true;
      description = ''
        Every context of the dialplan at runtime, for checking references to
        contexts, or null when included files or an AEL or Lua dialplan make
        that unknowable.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      dialplan.knownContexts = knownContexts;

      dialplan.general = {
        static = mkDefault true;
        writeprotect = mkDefault true;
        clearglobalvars = mkDefault true;
      };

      settings."extensions.conf" =
        {
          general =
            {
              order = 0;
            }
            // mapAttrs (_: v:
              if builtins.isList v
              then v
              else mkDefault v)
            dcfg.general;
        }
        // lib.optionalAttrs (dcfg.globals != {}) {
          globals =
            {
              order = 1;
            }
            // mapAttrs (_: mkDefault) (filterAttrs (_: v: v != null) dcfg.globals);
        }
        // mapAttrs contextSection dcfg.contexts;

      extraConfig."extensions.conf" = mkIf (rawBlocks != "") rawBlocks;
    };

    assertions = [
      {
        assertion = knownContexts == null || danglingIncludes == [];
        message = ''
          services.asterisk: dialplan includes contexts that are not defined:
            ${concatStringsSep "\n  " danglingIncludes}
        '';
      }
      {
        assertion = knownContexts == null || danglingSubroutines == [];
        message = ''
          services.asterisk: pre-dial subroutines refer to contexts that are not defined:
            ${concatStringsSep "\n  " danglingSubroutines}
        '';
      }
      {
        assertion = emptyExtensions == [];
        message = "services.asterisk.dialplan: extensions without steps or hint: ${concatStringsSep ", " emptyExtensions}.";
      }
      {
        assertion = badExtensionNames == [];
        message = "services.asterisk.dialplan: invalid extension name(s) (no commas, semicolons or spaces): ${concatStringsSep ", " badExtensionNames}.";
      }
      {
        assertion = !(dcfg.contexts ? general || dcfg.contexts ? globals);
        message = "services.asterisk.dialplan.contexts: `general` and `globals` are reserved; use dialplan.general and dialplan.globals.";
      }
    ];
  };
}
