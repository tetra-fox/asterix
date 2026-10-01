# pbx: extensions, ring groups, queues, conferences, voice menus, paging,
# business hours, routes and phone provisioning, written into the options of
# the core module (services.asterisk), which stays usable on its own. Every
# object gets a context of its own, pbx-<kind>-<name>, and phones dial from
# pbx-internal.
{
  config,
  lib,
  options,
  ...
}: let
  cfg = config.pbx;
  core = config.services.asterisk;
  asteriskLib = import ../../lib {inherit lib;};
  objects = ["extensions" "ringGroups" "queues" "conferences" "ivrs" "paging" "hours" "inbound" "outbound" "emergency" "voicemailMenu"];

  # the steps the pbx modules write, by context and extension, read from
  # their own definitions of the contexts: those of the files in this
  # directory, with the mkIf of a context applied
  generated = let
    own = builtins.filter (def: lib.hasPrefix "${toString ./.}/" (toString def.file)) options.services.asterisk.dialplan.contexts.definitionsWithLocations;
    applied = context:
      if (context._type or null) == "if"
      then lib.optionalAttrs context.condition (applied context.content)
      else context;
  in
    lib.zipAttrsWith (_: lib.zipAttrsWith (_: lib.concatLists)) (map (def: lib.mapAttrs (_: context: (applied context).extensions or {}) def.value) own);
  merged = core.dialplan.contexts;

  # Nix concatenates the lists of several definitions, so steps defined
  # elsewhere for an extension the pbx writes end up before or after its own.
  # Compared as dialplan text, since merged steps carry defaults the
  # generated ones lack.
  stepText = step:
    if builtins.isString step
    then step
    else "${
      if (step.label or null) == null
      then ""
      else step.label
    }:${asteriskLib.dialplan.app step.app step.args}";
  extended = lib.concatLists (lib.mapAttrsToList (context: extensions:
    map (extension: "${context}/${extension}") (builtins.filter (extension: let
      own = map stepText extensions.${extension};
      all = map stepText (merged.${context}.extensions.${extension} or []);
      n = builtins.length own;
    in
      builtins.length all > n && (lib.take n all == own || lib.drop (builtins.length all - n) all == own)) (builtins.attrNames extensions)))
  generated);

  # each step is one line of extensions.conf, so an extension with more lines
  # than steps has lines from settings
  sections = lib.groupBy (s: s.name) (builtins.attrValues (core.settings."extensions.conf" or {}));
  extendedInSettings = lib.concatLists (lib.mapAttrsToList (context: extensions: let
    lines = lib.groupBy (exten: exten.extension) (builtins.filter (exten: exten != null && exten.priority != "hint") (
      map (line: asteriskLib.format.splitExten (toString line)) (lib.concatMap (s: lib.toList (s.exten or [])) (sections.${context} or []))
    ));
  in
    map (extension: "${context}/${extension}") (builtins.filter (extension: builtins.length (lines.${extension} or []) > builtins.length (merged.${context}.extensions.${extension} or [])) (builtins.attrNames extensions)))
  generated);

  ownSteps = "steps of your own can go in the context's extraConfig, which is written as it is, or in a context of your own that a `context` destination names.";
in {
  # the core by the path the flake exports it as, so importing both is fine
  imports = [
    ../.
    ./conferences.nix
    ./destinations.nix
    ./extensions.nix
    ./hours.nix
    ./ivrs.nix
    ./numbering.nix
    ./paging.nix
    ./phones
    ./queues.nix
    ./ring-groups.nix
    ./routes.nix
  ];

  options.pbx.enable = lib.mkEnableOption "the PBX layer, and with it Asterisk";

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.asterisk.enable = lib.mkDefault true;

      assertions = [
        {
          assertion = extended == [];
          message = "pbx: steps were added to ${lib.concatStringsSep ", " extended} from elsewhere, so they run before or after the pbx's own. Change these through the pbx options, or replace their steps with lib.mkForce; ${ownSteps}";
        }
        {
          assertion = extendedInSettings == [];
          message = "pbx: steps were added to ${lib.concatStringsSep ", " extendedInSettings} from elsewhere, as lines of services.asterisk.settings.\"extensions.conf\". Change these through the pbx options; ${ownSteps}";
        }
      ];
    })
    {
      warnings = lib.optional (!cfg.enable && builtins.any (name: !(builtins.elem cfg.${name} [{} null])) objects) "pbx objects are defined, but pbx.enable is not set, so they do nothing.";
    }
  ];
}
