# The options campaign (catalog rows CORE-01 and CORE-04). Every option of
# services.asterisk and pbx is set, one at a time, on a small valid base: to
# its default, to other valid values, to its boundaries, to invalid values
# and, where a string lands in a file, to strings with the characters that
# mean something to Asterisk. options.py evaluates every case (T0) and boots
# Asterisk on the ones that evaluate, many to a configuration (T1).
{
  pkgs,
  self,
  # the q7s of each option's strings carry a tag of the option, so the
  # strings of many options can be told apart in one configuration
  # (readback.nix)
  tagged ? false,
}: let
  inherit (pkgs) lib;
  inherit
    (lib)
    attrNames
    concatLists
    concatMap
    concatStringsSep
    elem
    filter
    hasInfix
    hasPrefix
    head
    imap0
    isAttrs
    isList
    listToAttrs
    mapAttrsToList
    nameValuePair
    optional
    optionals
    tail
    ;
  inherit (self.lib) secret credential format;
  lightEval = import ./light-eval.nix {inherit pkgs;};
  fullEval = (import ../eval-lib.nix {inherit pkgs self;}).evalConfig;

  bases = {
    core = {
      module = self.nixosModules.default;
      config.services.asterisk = {
        enable = true;
        pjsip = {
          transports.udp = {};
          endpoints."101" = {
            context = "internal";
            auth.password = secret "/run/secrets/101";
          };
        };
        dialplan.contexts.internal.extensions."_1XX" = ["Dial(PJSIP/\${EXTEN})"];
      };
    };
    # an object of each kind a destination can name, with the names and
    # mailboxes the options' examples name, on numbers no example uses
    pbx = {
      module = self.nixosModules.pbx;
      config = {
        pbx = {
          enable = true;
          extensions = {
            "201" = {
              password = secret "/run/secrets/201";
              voicemail.pin = secret "/run/secrets/vm-201";
            };
            "202".password = secret "/run/secrets/202";
          };
          ringGroups.sales = {
            number = "620";
            members = ["201" "202"];
          };
          queues.support.number = "630";
          conferences.board.number = "820";
          ivrs.main = {
            number = "720";
            prompt.sound = "demo-congrats";
            options."1".ringGroup = "sales";
          };
          hours.office = {
            timezone = "America/Los_Angeles";
            open = [
              {
                days = "mon-fri";
                time = "09:00-17:00";
              }
            ];
          };
        };
        services.asterisk = {
          pjsip = {
            transports.udp = {};
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret "/run/secrets/trunk";
            };
          };
          queues.queues.support.members = ["PJSIP/201"];
          voicemail.mailboxes = {
            "200".pin = secret "/run/secrets/vm-200";
            "200@sales".pin = secret "/run/secrets/vm-200-sales";
          };
          # dialplan of one's own that context destinations send calls to,
          # with the s extension they go to when they name none
          dialplan.contexts.hand.extensions = {
            s = ["NoOp(hand s)" "Hangup()"];
            "201" = ["NoOp(hand 201)" "Hangup()"];
          };
        };
      };
    };
  };

  # The smallest valid object each option lives in, by option path: `name`
  # names the object for a <name> or * step, `def` gives its other options
  # (from the rest of the path below it). A `slot` is a destination or
  # prompt, which takes one tag, so its def only applies when the case sets
  # the slot itself.
  anchors = let
    tlsFiles = {
      certFile = "/var/lib/acme/pbx/cert.pem";
      keyFile = "/var/lib/acme/pbx/key.pem";
    };
  in {
    "services.asterisk.ami".def = _: {enable = true;};
    "services.asterisk.ami.users.<name>" = {
      name = "monitor";
      def = _: {secret = secret "/run/secrets/ami";};
    };
    "services.asterisk.ari" = {
      def = _: {enable = true;};
      extra.services.asterisk.http.enable = true;
    };
    "services.asterisk.ari.users.<name>" = {
      name = "app";
      def = _: {password = secret "/run/secrets/ari";};
    };
    "services.asterisk.http".def = _: {enable = true;};
    "services.asterisk.http.tls".def = _: {enable = true;} // tlsFiles;
    "services.asterisk.cdr.csv".def = _: {enable = true;};
    "services.asterisk.cdr.sqlite".def = _: {enable = true;};
    "services.asterisk.cel".def = _: {enable = true;};
    "services.asterisk.cel.sqlite".def = _: {enable = true;};
    "services.asterisk.confbridge.bridges.<name>".name = "board";
    "services.asterisk.confbridge.users.<name>".name = "chair";
    "services.asterisk.confbridge.menus".def = _: {};
    "services.asterisk.dialplan.contexts.<name>" = {
      name = "campaign";
      def = _: {extensions.s = ["NoOp()"];};
    };
    "services.asterisk.features.applications.<name>" = {
      name = "monkeys";
      def = _: {
        dtmf = "*9";
        app = "Playback";
        args = "tt-monkeys";
      };
    };
    "services.asterisk.includes.<name>".name = "pjsip.conf";
    "services.asterisk.includes.<name>.*".def = _: {
      file = "/var/lib/asterisk/pjsip-local.conf";
      optional = true;
    };
    "services.asterisk.musicOnHold.classes.<name>" = {
      name = "office";
      def = _: {directory = "moh";};
    };
    "services.asterisk.pjsip.acls.<name>" = {
      name = "lan";
      def = _: {permit = ["10.0.0.0/8"];};
    };
    # without auth or identify, an endpoint that takes registrations is open
    # only on purpose
    "services.asterisk.pjsip.endpoints.<name>" = {
      name = "102";
      def = _: {
        context = "internal";
        open = true;
      };
    };
    "services.asterisk.pjsip.endpoints.<name>.auth".def = _: {password = secret "/run/secrets/102";};
    "services.asterisk.pjsip.endpoints.<name>.identify".def = _: {match = ["10.0.0.5"];};
    "services.asterisk.pjsip.endpoints.<name>.outboundAuth".def = _: {
      username = "102";
      password = secret "/run/secrets/102-outbound";
    };
    "services.asterisk.pjsip.transports.<name>" = {
      name = "lan";
      def = rest:
        if rest != [] && head rest == "tls"
        then {
          protocol = "tls";
          port = 5071;
        }
        else {
          protocol = "tcp";
          port = 5070;
        };
    };
    "services.asterisk.pjsip.transports.<name>.tls".def = _: tlsFiles;
    "services.asterisk.pjsip.trunks.<name>" = {
      name = "provider";
      def = _: {
        host = "sip.provider.example";
        username = "5551000";
        password = secret "/run/secrets/trunk";
        context = "internal";
      };
    };
    "services.asterisk.pjsip.trunks.<name>.outboundAuth".def = _: {
      username = "5551000";
      password = secret "/run/secrets/trunk-auth";
    };
    "services.asterisk.pjsip.trunks.<name>.identify".def = _: {match = ["203.0.113.10"];};
    # persistentmembers is only written with a queue
    "services.asterisk.queues".def = _: {queues.support = {};};
    "services.asterisk.queues.queues.<name>".name = "sales";
    "services.asterisk.queues.queues.<name>.members.*".def = _: {interface = "PJSIP/101";};
    "services.asterisk.settings.<name>".name = "extensions.conf";
    "services.asterisk.settings.<name>.<name>" = {
      name = "campaign";
      def = _: {exten = ["s,1,NoOp()"];};
    };
    "services.asterisk.syntax.<name>".name = "pjsip.conf";
    "services.asterisk.voicemail".def = _: {enable = true;};
    "services.asterisk.voicemail.mailboxes.<name>" = {
      name = "7001";
      def = _: {pin = secret "/run/secrets/vm-7001";};
    };

    "pbx.conferences.<name>".name = "room";
    "pbx.emergency".def = _: {
      numbers = ["911"];
      trunk = "provider";
      notify = ["201"];
    };
    "pbx.extensions.<name>" = {
      name = "203";
      def = _: {password = secret "/run/secrets/203";};
    };
    "pbx.extensions.<name>.voicemail".def = _: {pin = secret "/run/secrets/vm-203";};
    "pbx.hours.<name>" = {
      name = "support";
      def = _: {
        timezone = "Europe/Berlin";
        open = [
          {
            days = "mon-fri";
            time = "08:00-16:00";
          }
        ];
      };
    };
    "pbx.hours.<name>.open.*".def = _: {
      days = "mon-fri";
      time = "08:00-16:00";
    };
    "pbx.inbound.<name>" = {
      name = "5551001";
      def = rest:
        if rest != [] && elem (head rest) ["hours" "open" "closed"]
        then {
          trunk = "provider";
          hours = "office";
          open.extension = "201";
          closed.extension = "202";
        }
        else {
          trunk = "provider";
          destination.extension = "201";
        };
    };
    "pbx.ivrs.<name>" = {
      name = "menu";
      def = _: {prompt.sound = "demo-congrats";};
    };
    "pbx.ivrs.<name>.options.<name>" = {
      name = "2";
      slot = true;
      def = _: {extension = "201";};
    };
    # pbx.outbound needs pbx.emergency, here with no emergency numbers
    "pbx.outbound" = {
      def = _: {
        prefix = "9";
        trunk = "provider";
      };
      extra.pbx.emergency.numbers = [];
    };
    "pbx.paging.<name>" = {
      name = "front";
      def = _: {
        number = "651";
        members = ["201" "202"];
      };
    };
    "pbx.phones".def = _: {
      enable = true;
      listenAddress = "10.0.20.10";
      allowedNetworks = ["10.0.20.0/24"];
    };
    "pbx.phones.files.<name>" = {
      name = "phone.cfg";
      def = _: {text = "campaign";};
    };
    "pbx.phones.grandstream.ht801".def = _: {
      enable = true;
      devices."201".mac = "c0:74:ad:00:02:01";
    };
    "pbx.phones.grandstream.ht801.devices.<name>" = {
      name = "202";
      def = _: {mac = "c0:74:ad:00:02:02";};
    };
    "pbx.queues.<name>" = {
      name = "help";
      extra.services.asterisk.queues.queues.help = {};
    };
    "pbx.ringGroups.<name>" = {
      name = "team";
      def = _: {
        members = ["201"];
        trunk = "provider";
      };
    };
  };

  # a destination's tags that are submodules
  slotTagAnchors = {
    context = {
      context = "hand";
      extension = "201";
    };
    voicemail.mailbox = "201";
  };

  values = import ./values.nix {inherit pkgs secret credential;};

  # every option a user can set, with its type
  optionTree = (lightEval self.nixosModules.pbx []).options;
  walk = opts:
    concatMap (opt: let
      sub = opt.type.getSubOptions opt.loc;
    in
      optional ((opt.visible or true) == true && !(opt.internal or false) && !(elem "_module" opt.loc)) opt
      ++ optionals (sub != {}) (walk sub))
    (lib.collect lib.isOption opts);
  options = walk {
    inherit (optionTree.services) asterisk;
    inherit (optionTree) pbx;
  };

  pathKey = concatStringsSep ".";
  showPath = lib.concatMapStringsSep "." lib.strings.escapeNixIdentifier;

  # a destination or a prompt: one tag, never merged with another
  isSlot = t: t.name == "attrTag" || (t.name == "nullOr" && t.nestedTypes.elemType.name == "attrTag");
  slots =
    map (opt: pathKey opt.loc) (filter (opt: isSlot opt.type) options)
    ++ ["pbx.ivrs.<name>.options.<name>"];

  # whether an option of type `t` takes `v`, without evaluating submodules
  takes = t: v: let
    nested = t.nestedTypes or {};
  in
    if t.name == "nullOr"
    then v == null || takes nested.elemType v
    else if t.name == "either"
    then takes nested.left v || takes nested.right v
    else if t.name == "coercedTo"
    then takes nested.coercedType v || takes nested.finalType v
    else if t.name == "listOf"
    then isList v && builtins.all (takes nested.elemType) v && (v != [] || !(hasPrefix "non-empty" t.description))
    else if elem t.name ["attrsOf" "lazyAttrsOf"]
    then isAttrs v && builtins.all (takes nested.elemType) (builtins.attrValues v)
    else if elem t.name ["submodule" "attrTag"]
    then isAttrs v
    else t.check v;

  # values at the edges of a type: the smallest and largest it takes, where
  # C integer types end, and what it just does not take
  maxInt = 9223372036854775807;
  edges = t: let
    nested = t.nestedTypes or {};
    big = [2147483647 2147483648 4294967296 maxInt];
  in
    if t.name == "nullOr"
    then [null] ++ edges nested.elemType
    else if t.name == "bool"
    then [true false "yes"]
    else if t.name == "int"
    then [0 (-1) (-maxInt - 1) "1"] ++ big
    else if t.name == "unsignedInt"
    then [0 1 (-1)] ++ big
    else if t.name == "positiveInt"
    then [1 0 (-1)] ++ big
    else if hasPrefix "unsignedInt" t.name
    then [0 1 1023 1024 65535 65536 (-1)]
    else if t.name == "enum"
    then t.functor.payload.values ++ ["q7enum"]
    else if t.name == "listOf"
    then [[]] ++ map (v: [v]) (filter (v: v != null && !isList v) (edges nested.elemType))
    else if t.name == "either"
    then edges nested.left ++ edges nested.right
    else if t.name == "coercedTo"
    then edges nested.coercedType ++ edges nested.finalType
    else [];

  # strings with the characters that mean something in a configuration file,
  # between q7s so each is found where it lands; the non-ASCII one is written
  # as JSON escapes to keep this file ASCII
  adversarial = {
    semicolon = "q7;q7";
    comma = "q7,q7";
    pipe = "q7|q7";
    quote = "q7\"q7";
    dollar = "q7$q7";
    variable = "q7\${Q7}q7";
    parentheses = "q7()q7";
    brackets = "q7[]q7";
    arrow = "q7=>q7";
    backslash = "q7\\q7";
    leadingSpaces = "  q7";
    nonAscii = builtins.fromJSON ''"q7\u00e9\u20ac\ud83d\ude00q7"'';
    # longer than the 8190 bytes Asterisk reads of a line (main/config.c)
    long = "q7${lib.strings.replicate 9000 "x"}q7";
    empty = "";
    lineBreak = "q7\nq7";
  };
  adversarialOf = option:
    if tagged
    then lib.mapAttrs (_: lib.replaceStrings ["q7"] ["q7${builtins.substring 0 8 (builtins.hashString "sha256" option)}"]) adversarial
    else adversarial;

  # a value of type `t` with `s` where a string goes, or null; maps get it
  # under `key`
  stringIn = t: key: s: let
    nested = t.nestedTypes or {};
    wrap = f: v:
      if v == null
      then null
      else f v;
  in
    if elem t.name ["str" "separatedString"] || hasPrefix "strMatching" t.name
    then s
    else if t.name == "nullOr"
    then stringIn nested.elemType key s
    else if t.name == "listOf"
    then wrap lib.toList (stringIn nested.elemType key s)
    else if elem t.name ["attrsOf" "lazyAttrsOf"]
    then wrap (v: {${key} = v;}) (stringIn nested.elemType key s)
    else if t.name == "either"
    then let
      left = stringIn nested.left key s;
    in
      if left != null
      then left
      else stringIn nested.right key s
    else if t.name == "coercedTo"
    then stringIn nested.coercedType key s
    else null;

  unset = {_campaign = "unset";};
  instance = {_campaign = "instance";};

  # The value at option path `prefix` (at `concrete` in the configuration)
  # for a case that sets `leaf` at the end of `rest`, with the anchors on the
  # way. `names` replaces an anchor's name. The leaf replaces what the
  # anchors give there, and overrides the base where the base sets it.
  build = base: names: prefix: concrete: rest: leaf: let
    key = pathKey prefix;
    anchor = anchors.${key} or {};
    parentIsSlot = prefix != [] && elem (pathKey (lib.init prefix)) slots;
    def =
      (
        if anchor ? def && !(elem key slots && rest != [])
        then anchor.def rest
        else {}
      )
      // lib.optionalAttrs (parentIsSlot && rest != []) (slotTagAnchors.${lib.last prefix} or {});
    seg = head rest;
    childPrefix = prefix ++ [seg];
    childKey =
      if elem seg ["<name>" "*"]
      then names.${pathKey childPrefix} or anchors.${pathKey childPrefix}.name or seg
      else seg;
    child = build base names childPrefix (concrete ++ [childKey]) (tail rest) leaf;
    old = def.${childKey} or null;
  in
    if rest == [] && leaf == instance
    then def
    else if rest == [] && leaf == unset
    then unset
    else if rest == []
    then
      if lib.hasAttrByPath concrete bases.${base}.config
      then lib.mkOverride 90 leaf
      else leaf
    else if seg == "*"
    then optional (child != unset) child
    else if child == unset
    then removeAttrs def [childKey]
    else
      def
      // {
        ${childKey} =
          if tail rest == [] || elem (pathKey childPrefix) slots || !(isAttrs old && isAttrs child)
          then child
          else lib.recursiveUpdate old child;
      };

  # modules the anchors on an option's path add elsewhere
  anchorExtras = segs:
    concatMap (i: let
      anchor = anchors.${pathKey (lib.take i segs)} or {};
    in
      optional (anchor ? extra) anchor.extra)
    (lib.range 1 (builtins.length segs));

  specOf = option: values.${option} or {};

  unwrap = entry:
    if isAttrs entry && entry ? _campaign
    then entry._campaign
    else {
      value = entry;
      extra = {};
    };

  # the settings of a module, as paths and value hashes
  leaves = let
    go = path: v:
      if isAttrs v && v != {} && !(v ? _type) && !(format.types.secret.check v) && !(lib.isDerivation v)
      then concatLists (mapAttrsToList (k: go (path ++ [k])) v)
      else [
        {
          path = showPath path;
          value = builtins.hashString "sha256" (builtins.toJSON v);
        }
      ];
  in
    go [];

  # without store path hashes, so a label stays when nixpkgs changes
  showValue = v: let
    json = lib.concatMapStrings (part:
      if isList part
      then "<store>/"
      else part) (builtins.split "${builtins.storeDir}/[0-9a-z]{32}-" (builtins.toJSON v));
  in
    if isAttrs v && v ? _campaign
    then "${showValue v._campaign.value} with ${concatStringsSep ", " (map (leaf: leaf.path) (leaves v._campaign.extra))}"
    else if format.types.secret.check v
    then
      if v ? _credential
      then "credential"
      else "secret"
    else if lib.isDerivation v
    then "<${v.name}>"
    else if builtins.stringLength json > 100
    then "${builtins.substring 0 40 json}... (${toString (builtins.stringLength json)} bytes)"
    else json;

  mkCase = {
    opt,
    label,
    expect,
    value ? unset,
    marker ? null,
    names ? {},
    extra ? {},
    loc ? opt.loc,
  }: let
    option = pathKey opt.loc;
    base =
      if hasPrefix "pbx." option
      then "pbx"
      else "core";
    # where the case's value is in the configuration
    concrete = imap0 (i: seg: let
      prefix = pathKey (lib.take (i + 1) loc);
    in
      if elem seg ["<name>" "*"]
      then names.${prefix} or anchors.${prefix}.name or seg
      else seg)
    loc;
  in {
    # a case that leaves its option unset claims that too
    unsetPath = optional (value == unset) (showPath concrete);
    # a label may name a store path, and an attribute name cannot
    id = builtins.unsafeDiscardStringContext "${option} = ${label}";
    inherit option label expect marker base;
    full = (specOf option).full or false;
    # strings some other program reads, which options.py lists instead
    verbatim = (specOf option).verbatim or true;
    # where a wrong value of the option is meant to fail: evaluation, or,
    # for freeform keys only Asterisk knows, loading
    guard = (specOf option).guard or "t0";
    # why a case cannot do what it expects, when that is a known limit
    limitation = (specOf option).limitations.${label} or null;
    modules =
      [(build base names [] [] loc value) extra]
      ++ anchorExtras loc
      ++ lib.toList ((specOf option).extra or []);
  };

  casesOf = opt: let
    option = pathKey opt.loc;
    spec = specOf option;
    t = opt.type;
    isTag = elem (pathKey (lib.init opt.loc)) slots;
    fromSpec = expect:
      map (entry: let
        e = unwrap entry;
      in
        mkCase {
          inherit opt expect;
          label = showValue entry;
          inherit (e) value extra;
        });
    example = opt.example or null;
    # a default that depends on other options has no value in the tree
    plainExample =
      example
      != null
      && !(isAttrs example && example ? _type)
      && (!(opt ? default) || (builtins.tryEval (opt.default != example)).value);
    key = spec.key or "q7key";
    strings =
      if spec.strings or true
      then adversarialOf option
      else {};
    # a value the table gives says more than the same value from the type
    given = map (entry: showValue (unwrap entry).value) (spec.valid or [] ++ spec.invalid or [] ++ spec.warn or []);
  in
    optional (!isTag) (mkCase {
      inherit opt;
      label = "default";
      expect =
        spec.default
        or (
          if opt ? default
          then "accept"
          else "reject"
        );
    })
    ++ map (v:
      mkCase {
        inherit opt;
        label = showValue v;
        value = v;
        expect =
          if takes t v
          then "accept"
          else "reject";
      }) (filter (v: !(elem (showValue v) given)) (lib.unique (edges t)))
    ++ optional plainExample (mkCase {
      inherit opt;
      label = "example ${showValue example}";
      value = example;
      expect = "accept";
    })
    ++ fromSpec "accept" (spec.valid or [])
    ++ fromSpec "reject" (spec.invalid or [])
    ++ fromSpec "warn" (spec.warn or [])
    ++ optionals (stringIn t key "x" != null) (lib.mapAttrsToList (name: s:
      mkCase {
        inherit opt;
        label = "string ${name}";
        value = stringIn t key s;
        expect =
          if name == "lineBreak"
          then spec.lineBreak or "reject"
          else "verbatim";
        marker =
          if elem name ["empty" "lineBreak"]
          then null
          else s;
      })
    strings)
    # the names of a collection's objects land in the files too
    ++ optionals (anchors ? "${option}.<name>" && (spec.names or true)) (lib.mapAttrsToList (name: s:
      mkCase {
        inherit opt;
        label = "name ${name}";
        expect = "verbatim";
        loc = opt.loc ++ ["<name>"];
        value = instance;
        names."${option}.<name>" = s;
        marker =
          if name == "empty"
          then null
          else s;
      }) (removeAttrs (adversarialOf option) ["lineBreak"]));

  # options that cannot be set: read-only, or removed from nixpkgs' module
  fixed =
    map (loc: {
      inherit loc;
      value = {};
    }) [
      ["services" "asterisk" "confFiles"]
      ["services" "asterisk" "useTheseDefaultConfFiles"]
      ["services" "asterisk" "provisioning"]
    ]
    ++ map (opt: {
      inherit (opt) loc;
      value = null;
    }) (filter (opt: opt.readOnly or false) options);

  cases =
    concatMap (opt: optionals (!(opt.readOnly or false)) (casesOf opt)) options
    ++ map (f: {
      id = "${pathKey f.loc} = set";
      option = pathKey f.loc;
      label = "set";
      expect = "reject";
      marker = null;
      base = "core";
      full = false;
      verbatim = true;
      guard = "t0";
      limitation = null;
      modules = [(lib.setAttrByPath f.loc f.value)];
    })
    fixed;

  evaluate = mode: case: let
    base = bases.${case.base};
  in
    if mode == "full"
    then fullEval ([base.module base.config] ++ case.modules)
    else (lightEval base.module ([base.config] ++ case.modules)).config;

  # the checks that boot a configuration (T1), not the ones NixOS adds
  bootChecks = config: filter (d: hasPrefix "asterisk-" d.name || hasPrefix "pbx-" d.name) config.system.checks;

  # what a configuration does at evaluation (T0): its failed assertions and
  # warnings, where the case's string landed, and the checks that boot it
  # (T1), whose store paths a whole NixOS evaluation shares
  outcome = mode: case: let
    c = evaluate mode case;
    failed = map (a: a.message) (filter (a: !a.assertion) c.assertions);
    files =
      lib.optionalAttrs c.services.asterisk.enable c.services.asterisk.renderedFiles
      // lib.optionalAttrs (c ? pbx && c.pbx.phones.enable) (lib.mapAttrs' (name: file: nameValuePair "phones/${name}" file.text) c.pbx.phones.files);
    # unit settings and firewall interfaces some strings end up in
    unitLines = let
      service = c.systemd.services.asterisk.serviceConfig or {};
      socket = c.systemd.sockets.asterisk-provisioning or null;
    in
      lib.toList (service.LoadCredential or [])
      ++ optional (service ? ExecStart) service.ExecStart
      ++ optionals (socket != null) (socket.listenStreams ++ lib.toList socket.socketConfig.IPAddressAllow)
      ++ attrNames c.networking.firewall.interfaces;
    # Asterisk's files escape `;` outside comments, the HT801 files are XML
    written = file: line: let
      m = case.marker;
    in
      if hasPrefix "phones/" file
      then
        hasInfix (
          if lib.hasSuffix ".xml" file
          then lib.escapeXML m
          else m
        )
        line
      else
        builtins.any (form: hasInfix form line) [
          (format.escapeValue m)
          # a caller ID name between quotes, where Asterisk drops each \ and
          # keeps the character after it (main/callerid.c ast_callerid_parse)
          ''"${format.escapeValue (lib.escape ["\\" "\""] m)}"''
        ]
        || (hasPrefix ";" line && hasInfix m line);
    lines = concatLists (mapAttrsToList (file: text: map (line: {inherit file line;}) (lib.splitString "\n" text)) files);
    found =
      map (l: "${l.file}: ${builtins.substring 0 160 l.line}") (filter (l: written l.file l.line) lines)
      ++ map (line: "unit: ${builtins.substring 0 160 line}") (filter (hasInfix case.marker) unitLines)
      # the names in settings and pbx.phones.files name files
      ++ map (file: "file: ${builtins.substring 0 160 file}") (filter (hasInfix case.marker) (attrNames files));
    units = lib.filterAttrs (name: _: hasPrefix "asterisk" name);
    firewall = fw: {inherit (fw) allowedTCPPorts allowedUDPPorts allowedUDPPortRanges;};
  in
    {
      inherit failed;
      inherit (c) warnings;
    }
    // lib.optionalAttrs (failed == []) {
      files = builtins.hashString "sha256" (builtins.toJSON files);
      units = builtins.hashString "sha256" (builtins.toJSON {
        services = lib.mapAttrs (_: s: {inherit (s) serviceConfig restartTriggers reloadTriggers;}) (units c.systemd.services);
        sockets = lib.mapAttrs (_: s: {inherit (s) listenStreams socketConfig;}) (units c.systemd.sockets);
        firewall = firewall c.networking.firewall // {interfaces = lib.mapAttrs (_: firewall) c.networking.firewall.interfaces;};
      });
      checks = map (d: d.drvPath) (bootChecks c);
      # the modules Asterisk loads, which one case could give another
      modules = builtins.hashString "sha256" (lib.optionalString c.services.asterisk.enable (c.services.asterisk.renderedFiles."modules.conf" or ""));
    }
    // lib.optionalAttrs (failed == [] && mode == "full") {
      # the whole system, with everything the case's values reach
      toplevel = builtins.unsafeDiscardStringContext c.system.build.toplevel.drvPath;
    }
    # nix-eval-jobs leaves out a meta attribute with a null in it
    // lib.optionalAttrs (case.marker != null) {landing = lib.take 3 found;}
    // lib.optionalAttrs (case.marker != null && case.verbatim or true) {verbatim = found != [];};

  # what a case sets, as paths and value hashes, so options.py can put
  # cases that do not touch each other into one configuration; the modules
  # of its `outcome` count as a setting, since a module one case loads could
  # provide what another one lacks and hide that case's failure
  claims = case: outcome:
    concatMap leaves (filter (m: m != {}) case.modules)
    ++ map (path: {
      inherit path;
      value = "unset";
    }) (case.unsetPath or [])
    ++ lib.optional (outcome ? modules) {
      path = "loadedModules";
      value = outcome.modules;
    };

  # one configuration with the `chosen` cases, whose claims do not collide:
  # the union of their settings
  combined = chosen: {
    id = "batch";
    marker = null;
    inherit (head chosen) base;
    modules = [(lib.foldl' lib.recursiveUpdate {} (concatMap (case: case.modules) chosen))];
  };

  stub = derivation {
    name = "campaign-case";
    inherit (pkgs.stdenv.hostPlatform) system;
    builder = "/bin/sh";
  };
  job = meta: stub // {inherit meta;};
in {
  inherit cases evaluate outcome claims combined;

  checksOf = case: bootChecks (evaluate "light" case);

  # what options.py reads first: every case, without evaluating it
  manifest = map (case: {inherit (case) id option label expect base full guard limitation;}) cases;

  # jobs for nix-eval-jobs: the T0 outcome of the cases at `indices`, or of
  # the configurations of `batches`, with the light or the whole NixOS
  # evaluation
  jobs = {
    mode ? "light",
    indices ? lib.range 0 (builtins.length cases - 1),
    batches ? [],
  }:
    listToAttrs (map (i: let
        case = builtins.elemAt cases i;
        o = outcome mode case;
      in
        nameValuePair "c${toString i}" (job {
          index = i;
          outcome = o;
          claims = claims case o;
        }))
      indices
      ++ imap0 (i: batch:
        nameValuePair "b${toString i}" (job {
          index = i;
          outcome = outcome mode (combined (map (builtins.elemAt cases) batch));
        }))
      batches);
}
