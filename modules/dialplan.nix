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
    concatStringsSep
    filter
    filterAttrs
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
  inherit (import ./lib.nix {inherit lib;}) moduleLoaded toSection;

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
            description = ''
              Priority label, usable as a Goto() target. It may not be empty,
              contain `,` or `)`, start with `+` or `-`, or be a whole number,
              which Goto() takes for a priority.
            '';
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
        description = ''
          Contexts included in this one (`include =>`), searched in order
          after its own extensions and switches. A context listed twice, as
          when two modules include it, is included once, where it comes
          first.
        '';
      };
      switches = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["Realtime/default@extensions"];
        description = ''
          Alternative switches (`switch =>`), asked in order after the
          context's own extensions and before its includes. One listed twice
          is written once. The module of a Realtime, Lua, DUNDi, Loopback or
          IAX2 switch is loaded with it.
        '';
      };
      ignorePatterns = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["9"];
        description = "Patterns after which dial tone continues (`ignorepat =>`), each written once.";
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
        description = ''
          Device state hints (`exten => 101,hint,PJSIP/101`) for BLF and
          presence: devices joined by `&`, each a channel driver and a
          resource (`PJSIP/101`) or a state provider and a name
          (`Custom:dnd101`, `Queue:support_avail`), then optionally a comma
          and `CustomPresence:<name>`. A hint may only have a `(` after a
          variable, as in `PJSIP/''${GLOBAL(PHONE)}`, since Asterisk cuts it
          there otherwise.
        '';
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
      comment = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "calls from the provider";
        description = "Comment written above the context in {file}`extensions.conf`.";
      };
    };
  };

  stepString = step:
    if isString step
    then step
    else asteriskLib.dialplan.app step.app step.args;

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
    comment = mkDefault context.comment;
    # several modules can each list one; Asterisk refuses the second
    # (main/pbx.c ast_context_add_include2 and the like)
    include = unique context.includes;
    switch = unique context.switches;
    ignorepat = unique context.ignorePatterns;
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
  # contexts res_parking creates for its parking lots. Included files, and AEL
  # or Lua dialplans whose module is loaded to read them, can define any
  # context.
  dialplan = cfg.settings."extensions.conf" or {};

  # the modules that provide switches, by the name before the /, which
  # Asterisk takes in any case (pbx/pbx_realtime.c, pbx/pbx_lua.c,
  # pbx/pbx_dundi.c, pbx/pbx_loopback.c, channels/chan_iax2.c)
  switchModules = {
    realtime = "pbx_realtime.so";
    lua = "pbx_lua.so";
    dundi = "pbx_dundi.so";
    loopback = "pbx_loopback.so";
    iax2 = "chan_iax2.so";
  };
  neededSwitchModules = unique (lib.concatMap (
    s:
      lib.concatMap (switch: let
        name = lib.toLower (lib.head (lib.splitString "/" switch));
      in
        optional (switchModules ? ${name}) switchModules.${name})
      (filter isString (toList (s.switch or []) ++ toList (s.eswitch or []) ++ toList (s.lswitch or [])))
  ) (attrValues dialplan));

  toList = v:
    if builtins.isList v
    then v
    else [v];
  loaded = moduleLoaded cfg;
  parkingLots = filter (lot: lot.name != "general") (attrValues (cfg.settings."res_parking.conf" or {}));
  parkingContexts =
    map (lot: lot.context or "parkedcalls") parkingLots
    # res_parking adds a lot called `default` when there is none
    ++ optional (!(builtins.any (lot: lot.name == "default") parkingLots)) "parkedcalls";
  dialplanSections = format.sectionNames {
    sections = dialplan;
    includes = cfg.includes."extensions.conf" or [];
    extraConfig = cfg.extraConfig."extensions.conf" or "";
  };
  otherDialplans = lib.filterAttrs (file: module: cfg.renderedFiles ? ${file} && loaded module) {
    "extensions.ael" = "pbx_ael.so";
    "extensions.lua" = "pbx_lua.so";
  };
  # Asterisk keeps the first 79 bytes of a section name (main/config.c struct
  # ast_category), and pbx_config makes sections of one name one context
  mergedContexts = lib.optionals (dialplanSections != null) (
    filter (names: builtins.length names > 1) (
      map (sort (a: b: a < b)) (attrValues (lib.groupBy (builtins.substring 0 79) (unique dialplanSections)))
    )
  );
  # pbx_config takes a section called general or globals, in any case, for
  # its settings or its global variables (pbx/pbx_config.c pbx_load_config)
  reserved = name: builtins.elem (lib.toLower name) ["general" "globals"];
  knownContexts =
    if dialplanSections == null || otherDialplans != {}
    then null
    else filter (name: !(reserved name)) dialplanSections ++ lib.optionals (loaded "res_parking.so") parkingContexts;

  # pbx_config reads the globals and contexts of extensions.conf
  hasDialplan =
    builtins.any (s: s.name != "general") (attrValues dialplan)
    || (cfg.extraConfig."extensions.conf" or "") != ""
    || (cfg.includes."extensions.conf" or []) != [];

  danglingIncludes = lib.concatMap (
    s:
      map (target: "[${s.name}] include => ${target}") (
        filter (
          target: isString target && !(builtins.elem (format.includedContext target) knownContexts)
        ) (toList (s.include or []))
      )
  ) (attrValues dialplan);
  # a lookup skips an included context named, but for case, like one it searched
  # already, though context names are case-sensitive (main/pbx.c:2527-2531, 703-711)
  # TODO: drop this once pbx_find_extension compares the contexts it searched with case
  includers = lib.foldl' (acc: s:
    lib.foldl' (acc: target: acc // {${target} = (acc.${target} or []) ++ [s.name];}) acc (
      map format.includedContext (filter isString (toList (s.include or [])))
    )) {} (attrValues dialplan);
  # a context and every context whose includes reach it
  reachedFrom = name: let
    go = seen: queue:
      if queue == []
      then seen
      else let
        new = filter (s: !(seen ? ${s})) (unique (includers.${lib.head queue} or []));
      in
        go (seen // lib.genAttrs new (_: true)) (lib.tail queue ++ new);
  in
    go {${name} = true;} [name];
  # names of contexts and include targets alike but for case, in groups
  alikeNames = filter (names: builtins.length names > 1) (
    map (names: sort (a: b: a < b) (unique names)) (attrValues (builtins.groupBy lib.toLower (map (s: s.name) (attrValues dialplan) ++ attrNames includers)))
  );
  alikeReached =
    lib.concatMap (
      names:
        lib.concatMap (
          a:
            lib.concatMap (b: let
              common = attrNames (builtins.intersectAttrs (reachedFrom a) (reachedFrom b));
            in
              optional (a < b && common != []) "${a} and ${b} (from ${lib.head common})")
            names
        )
        names
    )
    alikeNames;
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
  reservedContexts = filter reserved (attrNames dcfg.contexts);
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
  # pbx_config reads a hint like a step, App(arguments), and keeps what comes
  # before its first ( unless that part has a variable or expression
  # (pbx/pbx_config.c:1859-1866)
  cutHints = lib.concatLists (
    mapAttrsToList (
      name: context:
        map (ext: "${name}/${ext}") (
          filter (ext: let
            before = builtins.head (lib.splitString "(" context.hints.${ext});
          in
            lib.hasInfix "(" context.hints.${ext} && !(lib.hasInfix "\${" before || lib.hasInfix "$[" before))
          (attrNames context.hints)
        )
    )
    dcfg.contexts
  );
  # the drivers and providers that give a hint's devices a state, in any case,
  # and the prefixes modules publish states under, as written (main/devicestate.c)
  hintDrivers = ["PJSIP" "Local" "IAX2" "DAHDI" "Motif" "USTM" "AudioSocket" "WebSocket" "MulticastRTP" "UnicastRTP" "Console" "Mobile"];
  hintProviders = ["Custom" "Park" "Calendar" "Meetme" "Agent" "SLA" "ccss" "Stasis"];
  hintPrefixes = ["Queue" "confbridge" "MWI"];
  inAnyCase = names: name: builtins.elem (lib.toLower name) (map lib.toLower names);
  # a variable can name anything
  known = check: s: lib.hasInfix "$" s || check s;
  knownDevice = known (device: let
    provider = builtins.match "([^/:]*):.*" device;
    driver = builtins.match "([^/]*)/.*" device;
  in
    if provider != null
    then inAnyCase hintProviders (builtins.head provider) || builtins.elem (builtins.head provider) hintPrefixes
    else driver != null && inAnyCase hintDrivers (builtins.head driver));
  # func_presencestate is the only presence provider (main/presencestate.c)
  knownPresence = known (presence: lib.hasPrefix "custompresence:" (lib.toLower presence));
  knownHint = hint: let
    parts = builtins.match "([^,]*)(,(.*))?" hint;
    presence = builtins.elemAt parts 2;
  in
    parts
    != null
    && builtins.all knownDevice (filter (device: device != "") (lib.splitString "&" (builtins.head parts)))
    && (presence == null || knownPresence presence);
  unknownHints = lib.concatLists (
    mapAttrsToList (
      name: context:
        lib.mapAttrsToList (ext: hint: "${name}/${ext} (${hint})") (filterAttrs (_: hint: !(knownHint hint)) context.hints)
    )
    dcfg.contexts
  );
  # Goto() reads a label that is a whole number as a priority and one that
  # starts with + or - as a jump from the current step (main/pbx.c
  # pbx_parse_location), and pbx_config ends a label at its first ) and the
  # priority at a comma
  unreachable = label: label == "" || builtins.match "[+-].*|[[:space:]]*[0-9]+[[:space:]]*|.*[),].*" label != null;
  badLabels = lib.concatLists (
    mapAttrsToList (
      name: context:
        lib.concatLists (mapAttrsToList (
            ext: steps: let
              labels = filter (label: label != null && unreachable label) (map (step:
                if isString step
                then null
                else step.label)
              steps);
            in
              optional (labels != []) "${name}/${ext}: ${lib.concatMapStringsSep ", " builtins.toJSON labels}"
          )
          context.extensions)
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
      description = ''
        Global variables (`[globals]`), readable as `''${NAME}` in the
        dialplan. Asterisk fills in `''${...}` and `$[...]` in a value once,
        when it loads the dialplan, with the globals written before it, in
        the order of their names.
      '';
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
      description = ''
        Dialplan contexts. Asterisk fills in `''${...}` in extension names,
        hints, includes, ignore patterns and switches once, when it loads the
        dialplan, with the global variables, and in steps each time a call
        runs them.
      '';
    };

    knownContexts = mkOption {
      type = types.nullOr (types.listOf types.str);
      readOnly = true;
      description = ''
        Every context of the dialplan at runtime: the contexts of
        {file}`extensions.conf`, section headers in its raw text and the
        contexts of res_parking's parking lots. Null when included files or
        an AEL or Lua dialplan, with pbx_ael or pbx_lua loaded, make that
        unknowable. Other modules use it to check references to contexts.
      '';
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      modules.needed."the dialplan in extensions.conf" = mkIf hasDialplan ["pbx_config.so"];
      modules.needed."switches in extensions.conf" = mkIf (neededSwitchModules != []) neededSwitchModules;

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
            // toSection dcfg.general;
        }
        // lib.optionalAttrs (dcfg.globals != {}) {
          globals =
            {
              order = 1;
            }
            // toSection dcfg.globals;
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
        assertion = alikeReached == [];
        message = "services.asterisk.dialplan: include chains reach contexts named alike but for case, and Asterisk searches only the first of the two it reaches, skipping the other without a word: ${concatStringsSep ", " alikeReached}. Rename one context of each pair.";
      }
      {
        assertion = knownContexts == null || danglingSubroutines == [];
        message = ''
          services.asterisk: pre-dial subroutines refer to contexts that are not defined:
            ${concatStringsSep "\n  " danglingSubroutines}
        '';
      }
      {
        assertion = mergedContexts == [];
        message = ''
          services.asterisk: dialplan contexts that Asterisk would merge, since it only keeps the first 79 bytes of a context's name:
            ${concatStringsSep "\n  " (map (concatStringsSep ", ") mergedContexts)}
        '';
      }
      {
        assertion = badLabels == [];
        message = "services.asterisk.dialplan: step labels that Goto() cannot reach (a label may not be empty, contain `,` or `)`, start with + or -, or be a whole number): ${concatStringsSep "; " badLabels}.";
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
        assertion = cutHints == [];
        message = "services.asterisk.dialplan: hints that Asterisk cuts at their first ( unless a variable comes before it: ${concatStringsSep ", " cutHints}.";
      }
      {
        assertion = unknownHints == [];
        message = "services.asterisk.dialplan: hints with a device Asterisk has no state for, which it takes as invalid without a word: ${concatStringsSep ", " unknownHints}. Write devices joined by &, each <driver>/<resource> with a driver of ${concatStringsSep ", " hintDrivers} or <provider>:<name> with a provider of ${concatStringsSep ", " (hintProviders ++ hintPrefixes)}, then optionally ,CustomPresence:<name>.";
      }
      {
        assertion = reservedContexts == [];
        message = "services.asterisk.dialplan.contexts: `general` and `globals` are reserved, in any case; use dialplan.general and dialplan.globals: ${concatStringsSep ", " reservedContexts}.";
      }
    ];
  };
}
