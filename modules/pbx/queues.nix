# pbx.queues: a queue of services.asterisk.queues.queues with a number and
# what happens when nobody takes the call, in pbx-queue-<name>
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  format = (import ../../lib {inherit lib;}).format;

  queueType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "600";
        description = "Number phones dial to join the queue.";
      };
      timeout = mkOption {
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Seconds a caller waits before the call goes to `noAnswer`; without it, callers wait until someone answers.";
      };
      noAnswer = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        example = {voicemail = "200";};
        description = "Where the call goes after `timeout`.";
      };
    };
  };

  missing = builtins.filter (name: !(config.services.asterisk.queues.queues ? ${name})) (builtins.attrNames cfg.queues);
in {
  options.pbx.queues = mkOption {
    type = types.attrsOf queueType;
    default = {};
    example = lib.literalExpression ''
      { support = { number = "600"; timeout = 120; noAnswer.voicemail = "200"; }; }
    '';
    description = ''
      Queues of {option}`services.asterisk.queues.queues`, which keeps
      their members and strategy, as numbers and destinations.
    '';
  };

  config = mkIf cfg.enable {
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
        message = "pbx.queues: ${concatStringsSep ", " missing} are not queues of services.asterisk.queues.queues.";
      }
    ];
  };
}
