# services.asterix.queues: a queue of queues.conf with a number, extensions as
# members and what happens when nobody takes the call, in pbx-queue-<name>
{
  config,
  lib,
  options,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatMapStringsSep
    concatStringsSep
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../../lib {inherit lib;}) format;
  coreQueue = options.services.asterisk.queues.queues.type.getSubOptions [];

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
          Extensions of {option}`services.asterix.extensions` that take the queue's calls,
          each on every device registered as the extension, with the state of
          its endpoint, which counts all of them. They join the members of
          {option}`services.asterisk.queues.queues.<name>.members`.
        '';
      };
      strategy = mkOption {
        inherit (coreQueue.strategy) type default description;
      };
      memberTimeout = mkOption {
        inherit (coreQueue.timeout) type default;
        description = "Seconds a member's phone rings before the queue tries the next one (the queue's `timeout`).";
      };
      retry = mkOption {
        inherit (coreQueue.retry) type default description;
      };
      musicOnHold = mkOption {
        inherit (coreQueue.musicOnHoldClass) type default;
        example = "office";
        description = "Music on hold class of {option}`services.asterisk.musicOnHold.classes` that waiting callers hear (`musicclass`).";
      };
      maxWait = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Seconds a caller waits before the call goes to `noAnswer`. Without it, callers wait until someone answers, unless the queue turns them away.";
      };
      noAnswer = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        example = {voicemail = "200";};
        description = "Where the call goes after `maxWait`, and at once when the queue turns the caller away: when it is full (`maxLength`) or has no member to take calls (`joinempty` and `leavewhenempty` of its `settings`), both of {option}`services.asterisk.queues.queues.<name>`.";
      };
    };
  };

  badNames = builtins.filter (name: pbxLib.breaksContext name || pbxLib.breaksArgument name) (builtins.attrNames cfg.queues);
  # app_queue finds a queue by its name in any case (apps/app_queue.c
  # queue_cmp_cb)
  alike = builtins.filter (names: builtins.length names > 1) (builtins.attrValues (builtins.groupBy lib.toLower (builtins.attrNames cfg.queues)));
  unknownMembers = concatMap (name: map (member: "services.asterix.queues.${name}: ${member}") (builtins.filter (member: !(cfg.extensions ? ${member})) cfg.queues.${name}.members)) (builtins.attrNames cfg.queues);
in {
  options.services.asterix.queues = mkOption {
    type = types.attrsOf queueType;
    default = {};
    example = lib.literalExpression ''
      {
        support = {
          number = "600";
          members = [ "201" "202" ];
          strategy = "rrmemory";
          memberTimeout = 15;
          maxWait = 120;
          noAnswer.voicemail = "200";
        };
      }
    '';
    description = ''
      Call queues, with a number, extensions as members, how they ring and
      where an unanswered call goes. Each one defines
      {option}`services.asterisk.queues.queues.<name>`, where settings
      without an option here can be added. A name has 1 to 79
      bytes and cannot contain `,` `;` `[` `]` `"` `\` `''${` `$[`, an
      unclosed `(` or a line break, nor start or end with white space.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.modules.needed."services.asterix.queues" = mkIf (cfg.queues != {}) ["app_queue.so"];

    # PJSIP/<number> would call one device, so a member is a Local channel
    # into pbx-devices, with the state of its endpoint
    services.asterisk.queues.queues =
      mapAttrs (_: queue: {
        strategy = mkDefault queue.strategy;
        timeout = mkDefault queue.memberTimeout;
        retry = mkDefault queue.retry;
        musicOnHoldClass = mkDefault queue.musicOnHold;
        members =
          map (number: {
            interface = "Local/${number}@pbx-devices/n";
            name = number;
            stateInterface = "PJSIP/${number}";
          })
          queue.members;
      })
      cfg.queues;

    services.asterisk.dialplan.contexts =
      mapAttrs' (
        name: queue:
          nameValuePair (pbxLib.objectContext "queue" name) {
            comment = mkDefault "from services.asterix.queues.${name}";
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
                        if queue.maxWait == null
                        then ""
                        else toString queue.maxWait
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
        assertion = badNames == [];
        message = ''
          services.asterix.queues: names that Asterisk would misread in the dialplan (they may not contain , ; [ ] " \ ''${ $[ or an unclosed parenthesis):
            ${concatMapStringsSep "\n  " (name: lib.showOption ["services" "asterix" "queues" name]) badNames}
        '';
      }
      {
        assertion = alike == [];
        message = "services.asterix.queues: names that differ only in case, which app_queue takes for one queue: ${concatMapStringsSep "; " (concatStringsSep ", ") alike}.";
      }
      {
        assertion = unknownMembers == [];
        message = ''
          services.asterix.queues: members that are not extensions of services.asterix.extensions, where other devices go in services.asterisk.queues.queues.<name>.members:
            ${concatStringsSep "\n  " unknownMembers}
        '';
      }
    ];
  };
}
