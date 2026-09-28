# Asterisk configuration file format (layer 0).
#
# Asterisk's configuration syntax resembles INI but differs in ways that
# lib.generators.toINI cannot express:
#
#   * section names may repeat (PJSIP endpoint/auth/aor objects share a name),
#   * sections can be templates `[name](!)` and inherit `[name](a,b)`,
#   * keys may repeat (`allow`, `permit`, `exten`) and their order matters,
#   * `key => value` and `key = value` are both used, by convention per file,
#   * `#include` and `#tryinclude` are directives,
#   * `;` starts a comment anywhere unless escaped as `\;`.
#
# Everything here is pure: it only needs `lib`.
{lib}: let
  inherit
    (lib)
    attrNames
    concatMap
    concatStringsSep
    elem
    filter
    foldl'
    hasInfix
    isBool
    isFloat
    isInt
    isList
    isString
    isStringLike
    mkOption
    optional
    optionalString
    replaceStrings
    sort
    subtractLists
    ;

  secrets = import ./secrets.nix {inherit lib;};

  # Options of a section that describe the section itself rather than
  # key/value pairs inside it.
  metaAttrs = [
    "_module"
    "name"
    "order"
    "template"
    "inherits"
  ];

  contextString = ctx:
    concatStringsSep ", " (
      optional (ctx.file or null != null) ctx.file
      ++ optional (ctx.section or null != null) "section [${ctx.section}]"
      ++ optional (ctx.key or null != null) "key \"${ctx.key}\""
    );

  fail = ctx: msg: throw "asterisk config (${contextString ctx}): ${msg}";

  hasNewline = s: builtins.match ".*[\n\r].*" s != null;
in rec {
  inherit metaAttrs;

  # Syntax conventions. `=>` and `=` are equivalent to Asterisk's parser in
  # practically all modules; the arrow is used where upstream samples use it.
  defaultSyntax = {
    # Keys rendered as `key => value`.
    arrowKeys = [];
    # Sections in which every key is rendered as `key => value`.
    arrowSections = [];
    # Keys rendered first, in this order; all others follow alphabetically.
    # `disallow` must precede `allow` for codec lists.
    keyOrder = [
      "type"
      "disallow"
      "allow"
      "deny"
      "permit"
      "contact_deny"
      "contact_permit"
    ];
    # Render consecutive `exten` lines of one extension as `same =>`.
    compactExtensions = false;
  };

  knownSyntax = {
    "extensions.conf" = {
      arrowKeys = [
        "exten"
        "same"
        "include"
        "switch"
        "eswitch"
        "lswitch"
        "ignorepat"
      ];
      keyOrder = [
        "include"
        "switch"
        "eswitch"
        "lswitch"
        "ignorepat"
        "exten"
        "same"
      ];
      compactExtensions = true;
    };
    "modules.conf" = {
      arrowKeys = [
        "load"
        "noload"
        "preload"
        "require"
        "preload-require"
      ];
      keyOrder = [
        "autoload"
        "preload"
        "preload-require"
        "require"
        "load"
        "noload"
      ];
    };
    "asterisk.conf".arrowSections = ["directories"];
    "logger.conf".arrowSections = ["logfiles"];
    "queues.conf".arrowKeys = ["member"];
    "features.conf".arrowSections = ["applicationmap"];
    "musiconhold.conf".keyOrder = ["mode"];
  };

  # Syntax for a file name: defaults overlaid with the known conventions.
  syntaxFor = file: defaultSyntax // (knownSyntax.${file} or {});

  # Asterisk values cannot contain line breaks, and `;` must be escaped.
  escapeValue = replaceStrings [";"] ["\\;"];

  # whether Asterisk reads a value as true (ast_true in main/utils.c)
  isTrue = v:
    v
    == true
    || ((isString v || isInt v) && elem (lib.toLower (toString v)) ["yes" "true" "y" "t" "1" "on"]);

  # `host:port`, with an IPv6 address in brackets
  hostPort = host: port:
    (
      if hasInfix ":" host
      then "[${host}]"
      else host
    )
    + optionalString (port != null) ":${toString port}";

  # comma-separated positional fields, such as a mailbox or a queue member,
  # without empty fields at the end
  joinFields = fields: let
    trim = list:
      if list != [] && lib.last list == ""
      then trim (lib.init list)
      else list;
  in
    concatStringsSep "," (trim fields);

  isValidKey = k: isString k && builtins.match "[^][;=#[:space:]]([^;=\n\r]*[^;=[:space:]])?" k != null;

  isValidSectionName = n: isString n && builtins.match "[^][;[:space:]]([^][;\n\r]*[^][;[:space:]])?" n != null;

  # Render a single (non-list) value to its string form.
  mkValueString = {
    secretPlaceholder ? secrets.placeholderOf,
    ctx ? {},
  }: v:
    if isBool v
    then
      (
        if v
        then "yes"
        else "no"
      )
    else if isInt v
    then toString v
    else if isFloat v
    then lib.strings.floatToString v
    else if secrets.isSecret v
    then secretPlaceholder v
    else if isString v
    then
      (
        if hasNewline v
        then fail ctx "value contains a line break"
        else escapeValue v
      )
    else if isStringLike v
    then
      # paths are copied to the store; derivations render as their output path
      "${v}"
    else fail ctx "unsupported value of type ${builtins.typeOf v}: ${lib.generators.toPretty {} v}";

  # The keys of a section in rendering order.
  orderKeys = syntax: keys: let
    first = filter (k: elem k keys) syntax.keyOrder;
  in
    first ++ subtractLists first keys;

  # Split `100,n(label),Dial(...)` into extension and the remainder.
  splitExten = s: let
    m = builtins.match "([^,]*),([^,]*)(,.*)?" s;
  in
    if m == null
    then null
    else {
      extension = lib.trim (builtins.elemAt m 0);
      priority = lib.trim (builtins.elemAt m 1);
      rest = lib.removePrefix "," (
        lib.trim (builtins.elemAt m 1)
        + (
          if builtins.elemAt m 2 == null
          then ""
          else builtins.elemAt m 2
        )
      );
    };

  # Rewrite consecutive `exten` lines of the same extension as `same =>`.
  # Hint lines are never compacted and never start a `same` run.
  compactExtenLines = entries:
    (
      foldl'
      (
        acc: e: let
          parts =
            if e.key == "exten" && e.raw
            then splitExten e.value
            else null;
          isHint = parts != null && parts.priority == "hint";
        in
          if parts == null
          then {
            last = null;
            out = acc.out ++ [e];
          }
          else if !isHint && acc.last == parts.extension
          then {
            inherit (acc) last;
            out =
              acc.out
              ++ [
                (
                  e
                  // {
                    key = "same";
                    value = parts.rest;
                    indent = " ";
                  }
                )
              ];
          }
          else {
            last =
              if isHint
              then null
              else parts.extension;
            out = acc.out ++ [e];
          }
      )
      {
        last = null;
        out = [];
      }
      entries
    ).out;

  # Lines of one section: header plus `key = value` entries.
  renderSection = {
    syntax,
    file ? null,
    secretPlaceholder ? secrets.placeholderOf,
  }: id: section: let
    name = section.name or id;
    template = section.template or false;
    inherits = section.inherits or [];
    ctx = {
      inherit file;
      section = name;
    };
    body = removeAttrs section metaAttrs;
    keys = orderKeys syntax (attrNames body);
    arrowSection = elem name syntax.arrowSections;

    entriesFor = key: let
      ctx' =
        ctx
        // {
          inherit key;
        };
      v = body.${key};
      values = filter (x: x != null) (
        if isList v
        then v
        else [v]
      );
    in
      if !isValidKey key
      then fail ctx' "invalid key name"
      else
        map (x: {
          inherit key;
          value =
            mkValueString {
              inherit secretPlaceholder;
              ctx = ctx';
            }
            x;
          # only literal strings take part in `same =>` compaction
          raw = isString x;
          arrow = arrowSection || elem key syntax.arrowKeys;
          indent = "";
        })
        values;

    entries = concatMap entriesFor keys;
    entries' =
      if syntax.compactExtensions
      then compactExtenLines entries
      else entries;

    options = optional template "!" ++ inherits;
    header = "[${name}]" + optionalString (options != []) "(${concatStringsSep "," options})";
  in
    if !isValidSectionName name
    then fail ctx "invalid section name"
    else if !(builtins.all isValidSectionName inherits)
    then fail ctx "invalid name in inherits: ${builtins.toJSON inherits}"
    else
      [header]
      ++ map (e: "${e.indent}${e.key} ${
        if e.arrow
        then "=>"
        else "="
      } ${e.value}")
      entries';

  # Default position of a section: `[general]` (and extensions.conf's
  # `[globals]`) first, everything else after.
  defaultOrder = name:
    if name == "general"
    then 0
    else if name == "globals"
    then 1
    else 1000;

  # Section ids ordered by (order, templates first, id).
  sortSections = sections: let
    key = id: {
      inherit id;
      order = sections.${id}.order or (defaultOrder (sections.${id}.name or id));
      template = sections.${id}.template or false;
    };
    lessThan = a: b:
      if a.order != b.order
      then a.order < b.order
      else if a.template != b.template
      then a.template
      else a.id < b.id;
  in
    map (k: k.id) (sort lessThan (map key (attrNames sections)));

  renderInclude = inc: let
    i =
      if isString inc
      then {file = inc;}
      else inc;
    directive =
      if i.optional or false
      then "#tryinclude"
      else "#include";
  in
    if hasNewline i.file
    then throw "asterisk config: include path contains a line break"
    else ''${directive} "${i.file}"'';

  # names of a file's sections at runtime: the ones in `sections` and the
  # section headers in its raw text, or null when it includes other files,
  # which can define any section
  sectionNames = {
    sections ? {},
    includes ? [],
    extraConfig ? "",
  }:
    if includes != [] || builtins.any (directive: hasInfix directive extraConfig) ["#include" "#tryinclude" "#exec"]
    then null
    else
      lib.mapAttrsToList (id: section: section.name or id) sections
      ++ concatMap (
        line: let
          m = builtins.match "[[:space:]]*[[]([^]]+)[]].*" line;
        in
          if m == null
          then []
          else m
      ) (lib.splitString "\n" extraConfig);

  # Render a whole file.
  #
  #   sections    : attrset of id -> section (see `types.section`)
  #   includes    : list of paths or { file; optional ? false; }, rendered first
  #   extraConfig : raw text appended verbatim
  render = {
    syntax ? defaultSyntax,
    file ? null,
    secretPlaceholder ? secrets.placeholderOf,
    header ? null,
  }: {
    sections ? {},
    includes ? [],
    extraConfig ? "",
  }: let
    syntax' = defaultSyntax // syntax;
    blocks =
      optional (header != null) (map (l: "; ${l}") (lib.splitString "\n" header))
      ++ optional (includes != []) (map renderInclude includes)
      ++ map (
        id:
          renderSection {
            syntax = syntax';
            inherit file secretPlaceholder;
          }
          id
          sections.${id}
      ) (sortSections sections)
      ++ optional (extraConfig != "") [(lib.removeSuffix "\n" extraConfig)];
  in
    concatStringsSep "\n\n" (map (concatStringsSep "\n") blocks) + "\n";

  types = rec {
    secret = lib.mkOptionType {
      name = "asteriskSecret";
      description = "secret reference ({ _secret = path; } or { _credential = name; })";
      descriptionClass = "noun";
      check = secrets.isSecret;
      # references made with `secret` carry a __toString function, which ==
      # cannot compare; compare the reference itself
      merge = loc: defs: let
        refs = map (def: secrets.normalize def.value) defs;
      in
        if builtins.all (ref: ref == builtins.head refs) refs
        then (builtins.head defs).value
        else
          throw "The option `${lib.showOption loc}' has conflicting secret references: ${
            lib.concatMapStringsSep ", " (def: "${secrets.placeholderOf def.value} in ${def.file}") defs
          }";
    };

    secretOrString =
      lib.types.either lib.types.str secret
      // {
        description = "string or secret reference";
      };

    atom =
      lib.types.nullOr (
        lib.types.oneOf [
          lib.types.bool
          lib.types.int
          lib.types.float
          lib.types.str
          lib.types.path
          secret
        ]
      )
      // {
        description = "Asterisk config atom (null, bool, int, float, string, path or secret reference)";
      };

    value =
      lib.types.either atom (lib.types.listOf atom)
      // {
        description = "${atom.description}, or a list of them for repeated keys";
      };

    section = lib.types.submodule (
      {
        name,
        config,
        ...
      }: {
        freeformType = lib.types.attrsOf value;
        options = {
          name = mkOption {
            type = lib.types.str;
            default = name;
            defaultText = lib.literalMD "the attribute name";
            description = ''
              Asterisk section (category) name. Several sections may share a
              name, for example a PJSIP endpoint, auth and aor all called
              `alice`.
            '';
          };
          order = mkOption {
            type = lib.types.int;
            default = defaultOrder config.name;
            defaultText = lib.literalMD "0 for `general`, 1 for `globals`, 1000 otherwise";
            description = ''
              Sections are rendered sorted by this value, then templates
              before other sections, then by attribute name.
            '';
          };
          template = mkOption {
            type = lib.types.bool;
            default = false;
            description = "Render the section as a template: `[name](!)`.";
          };
          inherits = mkOption {
            type = lib.types.listOf lib.types.str;
            default = [];
            description = ''
              Sections (usually templates) this section inherits from:
              `[name](a,b)`. They must be rendered earlier in the file.
            '';
          };
        };
      }
    );

    sections = lib.types.attrsOf section;
  };
}
