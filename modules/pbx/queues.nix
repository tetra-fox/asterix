# pbx.queues: a queue of queues.conf with a number, extensions as members and
# what happens when nobody takes the call, in pbx-queue-<name>
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatMapStringsSep
    concatStringsSep
    filterAttrs
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.pbx;
  core = config.services.asterisk;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;

  queueType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "600";
        description = "Number phones dial to join the queue.";
      };
      members = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "201"
          "202"
        ];
        description = ''
          Extensions of {option}`pbx.extensions` that take the queue's calls,
          each on every device registered as the extension, with the state of
          its endpoint, which counts all of them. They join the members of
          {option}`services.asterisk.queues.queues.<name>.members`.
        '';
      };
      timeout = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Seconds a caller waits before the call goes to `noAnswer`; without it, callers wait until someone answers, unless the queue turns them away.";
      };
      noAnswer = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        example = {voicemail = "200";};
        description = "Where the call goes after `timeout`, and at once when the queue turns the caller away: when it is full (`maxLength`) or has no member to take calls (`joinempty` and `leavewhenempty` of its `settings`).";
      };
    };
  };

  # the queues of the final queues.conf, in lower case as app_queue finds a
  # queue in any case (apps/app_queue.c queue_cmp_cb), without the section it
  # takes for its settings; null when included files can define more
  queueNames = let
    names = format.sectionNames {
      sections = lib.filterAttrs (_: section: !(section.template or false)) (core.settings."queues.conf" or {});
      includes = core.includes."queues.conf" or [];
      extraConfig = core.extraConfig."queues.conf" or "";
    };
  in
    if names == null
    then null
    else lib.remove "general" (map lib.toLower names);
  missing = lib.optionals (queueNames != null) (builtins.filter (name: !(builtins.elem (lib.toLower name) queueNames)) (builtins.attrNames cfg.queues));
  badNames = builtins.filter (name: pbxLib.breaksContext name || pbxLib.breaksArgument name) (builtins.attrNames cfg.queues);
  unknownMembers = concatMap (name: map (member: "pbx.queues.${name}: ${member}") (builtins.filter (member: !(cfg.extensions ? ${member})) cfg.queues.${name}.members)) (builtins.attrNames cfg.queues);
  # queues.conf keeps the first 79 bytes of a queue's name (main/config.c
  # struct ast_category), and Queue() looks for the whole name
  longNames = builtins.filter (name: builtins.stringLength name > 79) (builtins.attrNames cfg.queues);
in {
  options.pbx.queues = mkOption {
    type = types.attrsOf queueType;
    default = {};
    example = lib.literalExpression ''
      { support = { number = "600"; timeout = 120; noAnswer.voicemail = "200"; }; }
    '';
    description = ''
      Queues of {file}`queues.conf`, as numbers, members and destinations.
      The strategy and other settings of a queue stay in
      {option}`services.asterisk.queues.queues` or `settings`, which also
      have to define a queue without `members` here. A name has 1 to 79
      bytes and cannot contain `,` `;` `[` `]` `"` `\` `''${` `$[`, an
      unclosed `(` or a line break, nor start or end with white space.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.modules.needed."pbx.queues" = mkIf (cfg.queues != {}) ["app_queue.so"];

    # PJSIP/<number> would call one device, so a member is a Local channel
    # into pbx-devices, with the state of its endpoint
    services.asterisk.queues.queues = mapAttrs (_: queue: {
      members =
        map (number: {
          interface = "Local/${number}@pbx-devices/n";
          name = number;
          stateInterface = "PJSIP/${number}";
        })
        queue.members;
    }) (filterAttrs (_: queue: queue.members != []) cfg.queues);

    services.asterisk.dialplan.contexts =
      mapAttrs' (
        name: queue:
          nameValuePair (pbxLib.objectContext "queue" name) {
            comment = mkDefault "from pbx.queues.${name}";
            extensions.s =
              [
                (pbxLib.app "Answer" [])
                {
                  app = "Queue";
                  args = [
                    (format.joinFields [
                      name
                      ""
                      ""
                      ""
                      (
                        if queue.timeout == null
                        then ""
                        else toString queue.timeout
                      )
                    ])
                  ];
                }
              ]
              ++ pbxLib.steps queue.noAnswer;
          }
      )
      cfg.queues;

    assertions = [
      {
        assertion = missing == [];
        message = "pbx.queues: ${concatStringsSep ", " missing} are not queues of queues.conf (services.asterisk.queues.queues or settings).";
      }
      {
        assertion = badNames == [];
        message = ''
          pbx.queues: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["pbx" "queues" name]) badNames}
        '';
      }
      {
        assertion = longNames == [];
        message = "pbx.queues: names longer than 79 bytes, which Asterisk cuts, so Queue() never finds them: ${concatStringsSep ", " longNames}.";
      }
      {
        assertion = unknownMembers == [];
        message = ''
          pbx.queues: members that are not extensions of pbx.extensions, where other devices go in services.asterisk.queues.queues.<name>.members:
            ${concatStringsSep "\n  " unknownMembers}
        '';
      }
    ];
  };
}
