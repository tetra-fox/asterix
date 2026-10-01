# The generated-configuration campaign (configs.py): configurations of the
# pbx layer, written by generate.py as JSON, evaluated (T0), booted by
# Asterisk (T1), called through the probe (probe.nix) and walked from its
# trunks to their Dials (tollfraud.nix). A configuration is
# a list of modules; in their JSON, { "_secret": path } is a secret reference
# and every other value is what the option takes.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit
    (lib)
    concatLists
    filter
    hasPrefix
    isAttrs
    isList
    listToAttrs
    mapAttrs
    mapAttrsToList
    nameValuePair
    optionalAttrs
    ;
  lightEval = import ./light-eval.nix {inherit pkgs;};
  fullEval = (import ../eval-lib.nix {inherit pkgs self;}).evalConfig;
  probe = import ./probe.nix {inherit pkgs self;};
  tollfraud = import ./tollfraud.nix {inherit pkgs self;};

  decode = value:
    if isAttrs value
    then
      if value ? _secret
      then self.lib.secret value._secret
      else mapAttrs (_: decode) value
    else if isList value
    then map decode value
    else value;

  evaluate = mode: modules:
    if mode == "full"
    then fullEval ([self.nixosModules.pbx] ++ map decode modules)
    else (lightEval self.nixosModules.pbx (map decode modules)).config;

  # the checks that boot a configuration (T1), not the ones NixOS adds
  bootChecks = config: filter (d: hasPrefix "asterisk-" d.name || hasPrefix "pbx-" d.name) config.system.checks;

  # what a configuration does at evaluation (T0): its failed assertions and
  # warnings, and without failed assertions the store paths it gives and the
  # checks that boot it
  outcome = mode: modules: let
    c = evaluate mode modules;
    failed = map (a: a.message) (filter (a: !a.assertion) c.assertions);
  in
    {
      inherit failed;
      inherit (c) warnings;
    }
    // optionalAttrs (failed == []) {
      config = builtins.unsafeDiscardStringContext c.services.asterisk.generatedConfig.drvPath;
      checks = map (d: d.drvPath) (bootChecks c);
    };

  # every scalar of settings as file, section, key and value; a definition
  # in settings extends a list rather than replacing it, name, order,
  # template and inherits are options of a section rather than Asterisk
  # keys, a pjsip.conf section's id names its type, and the directories of
  # asterisk.conf are the service's, which a sound package of the layer
  # changes
  scalars = settings:
    concatLists (mapAttrsToList (file: sections:
      concatLists (mapAttrsToList (section: keys:
        mapAttrsToList (key: value: {inherit file section key value;})
        (lib.filterAttrs (key: value:
          !(isList value)
          && !(isAttrs value)
          && value != null
          && !(builtins.elem key ["name" "order" "template" "inherits"])
          && !(file == "pjsip.conf" && key == "type")
          && !(file == "asterisk.conf" && section == "directories"))
        keys))
      sections))
    settings);

  # the scalars the pbx layer writes: those the same modules lack with
  # pbx.enable off, which also turns Asterisk off unless it is set and leaves
  # the trunks without the context the layer gives them
  layerScalars = modules: let
    with' = evaluate "light" modules;
    without =
      scalars
      (lightEval self.nixosModules.pbx (map decode modules
        ++ [
          {
            pbx.enable = lib.mkForce false;
            services.asterisk = {
              enable = true;
              pjsip.trunks = mapAttrs (_: _: {context = "campaign-without-pbx";}) with'.services.asterisk.pjsip.trunks;
            };
          }
        ])).config.services.asterisk.settings;
  in
    filter (s: !(builtins.elem s without)) (scalars with'.services.asterisk.settings);

  # a value of the same type that differs from `value`
  replacement = value:
    if builtins.isBool value
    then !value
    else if builtins.isInt value
    then value + 1
    else "${toString value}-campaign";

  # every scalar the pbx layer writes, replaced by a plain definition in
  # settings
  overrideModule = modules: {
    services.asterisk.settings = lib.foldl' lib.recursiveUpdate {} (map (s: {
        ${s.file}.${s.section}.${s.key} = replacement s.value;
      })
      (layerScalars modules));
  };

  # P6: the scalars whose final value is not the replacement, or that fail to
  # evaluate, and whether the files evaluate
  overrides = modules: let
    before = layerScalars modules;
    override = overrideModule modules;
    after = (lightEval self.nixosModules.pbx (map decode modules ++ [override])).config.services.asterisk.settings;
    kept = s: let
      result = builtins.tryEval (let
        v = after.${s.file}.${s.section}.${s.key};
      in
        builtins.deepSeq v v);
    in
      !result.success || result.value != replacement s.value;
    rendered = builtins.tryEval (let
      files = (lightEval self.nixosModules.pbx (map decode modules ++ [override])).config.services.asterisk.renderedFiles;
    in
      builtins.deepSeq files true);
  in {
    scalars = builtins.length before;
    kept = map (s: "${s.file} [${s.section}] ${s.key}") (filter kept before);
    rendered = rendered.success;
  };

  stub = derivation {
    name = "campaign-configuration";
    inherit (pkgs.stdenv.hostPlatform) system;
    builder = "/bin/sh";
  };
  job = meta: stub // {inherit meta;};
in {
  inherit bootChecks decode evaluate outcome overrideModule;

  # jobs for nix-eval-jobs, one per entry: each has `modules`, and `mode`
  # ("light" or "full"), `overrides` (P6), `probe` (a spec for probe.nix)
  # and `tollfraud` (the walk of tollfraud.nix) as wanted
  jobs = entries:
    listToAttrs (lib.imap0 (i: entry: let
      mode = entry.mode or "light";
      o = outcome mode entry.modules;
    in
      nameValuePair "g${toString i}" (job (
        {outcome = o;}
        // optionalAttrs (entry.overrides or false && o.failed == []) {overrides = overrides entry.modules;}
        // optionalAttrs (entry ? probe && o.failed == []) {
          probe =
            builtins.unsafeDiscardStringContext
            (probe {
              name = "g${toString i}";
              config = evaluate mode entry.modules;
              inherit (entry.probe) commands calls;
            })
            .drvPath;
        }
        // optionalAttrs (entry.tollfraud or false && o.failed == []) {
          tollfraud =
            builtins.unsafeDiscardStringContext
            (tollfraud {
              name = "g${toString i}";
              config = evaluate mode entry.modules;
            })
            .drvPath;
        }
      )))
    entries);
}
