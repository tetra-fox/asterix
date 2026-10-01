# Each queue renders into `settings."queues.conf".<queue>`; static members are
# `member =>` lines.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    mapAttrs
    mkDefault
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  qcfg = cfg.queues;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;
  inherit (import ./lib.nix {inherit lib;}) toSection;

  memberType = types.submodule {
    options = {
      interface = mkOption {
        type = types.str;
        example = "PJSIP/201";
        description = "Device that is called.";
      };
      penalty = mkOption {
        # larger penalties overflow the int app_queue ranks members by, which then
        # rings them first, and make wrandom divide by zero (apps/app_queue.c:6264-6312)
        # TODO: allow larger penalties once app_queue ranks members without overflowing
        type = types.nullOr (types.ints.between 0 2146);
        default = null;
        description = ''
          Members with a higher penalty are only called when every member with
          a lower one is paused, busy, in wrap-up time or unreachable, not when
          they do not answer. With the `wrandom` strategy the penalty is a
          weight instead: the higher it is, the less likely the member is
          called first. At most 2146, since app_queue overflows on larger
          penalties and rings those members first.
        '';
      };
      name = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Name shown in queue logs and `queue show`.";
      };
      stateInterface = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Device whose state decides whether the member is available.";
      };
    };
  };

  queueType = types.submodule {
    options = {
      strategy = mkOption {
        type = types.enum [
          "ringall"
          "leastrecent"
          "fewestcalls"
          "random"
          "rrmemory"
          "rrordered"
          "linear"
          "wrandom"
        ];
        default = "ringall";
        description = ''
          How members are chosen. A queue that a deploy switches to `linear`
          rings its members in its old order, not the listed one, until
          Asterisk restarts, since a reload keeps the queue's member list as
          it was.
        '';
      };
      timeout = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = "Seconds a member's phone rings before the next attempt.";
      };
      retry = mkOption {
        # Asterisk replaces 0 with its default of 5
        type = types.nullOr types.ints.positive;
        default = null;
        description = "Seconds to wait before trying all members again.";
      };
      wrapupTime = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = "Seconds a member is left alone after a call (`wrapuptime`).";
      };
      maxLength = mkOption {
        type = types.nullOr types.ints.unsigned;
        default = null;
        description = "Maximum number of waiting callers (`maxlen`, 0 is unlimited).";
      };
      musicOnHoldClass = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Music on hold class for waiting callers (`musicclass`).";
      };
      members = mkOption {
        type = types.listOf (types.coercedTo types.str (interface: {inherit interface;}) memberType);
        default = [];
        example = [
          "PJSIP/201"
          {
            interface = "PJSIP/202";
            penalty = 1;
            name = "Sales";
          }
        ];
        description = "Static members (`member =>`).";
      };
      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
        example = {
          announce-frequency = 60;
          joinempty = "paused,invalid";
        };
        description = "Additional keys of the queue's section.";
      };
    };
  };

  # app_queue splits a member line like application arguments: at commas
  # outside quotes, parentheses and brackets, dropping quotes and the backslash
  # that makes the next character literal
  escapeField = lib.replaceStrings ["\\" "," "\"" "(" ")" "[" "]"] ["\\\\" "\\," "\\\"" "\\(" "\\)" "\\[" "\\]"];

  # app_queue takes a section called general in any case for its settings
  # (apps/app_queue.c reload_queues)
  reserved = builtins.filter (name: lib.toLower name == "general") (builtins.attrNames qcfg.queues);
  # queues.conf keeps the first 79 bytes of a queue's name (main/config.c
  # struct ast_category), and Queue() looks for the whole name
  longNames = builtins.filter (name: builtins.stringLength name > 79) (builtins.attrNames qcfg.queues);

  memberValue = m:
    format.joinFields (map escapeField [
      m.interface
      (
        if m.penalty == null
        then ""
        else toString m.penalty
      )
      (
        if m.name == null
        then ""
        else m.name
      )
      (
        if m.stateInterface == null
        then ""
        else m.stateInterface
      )
    ]);
in {
  options.services.asterisk.queues = {
    persistentMembers = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Keep members added at runtime (AddQueueMember) across restarts in
        astdb. Off by default, so the configured members are the whole truth.
      '';
    };

    queues = mkOption {
      type = types.attrsOf queueType;
      default = {};
      example = lib.literalExpression ''
        {
          support = {
            strategy = "rrmemory";
            timeout = 15;
            members = [ "PJSIP/201" "PJSIP/202" ];
          };
        }
      '';
      description = ''
        Call queues, used as `Queue(support)` in the dialplan. Asterisk keeps
        79 bytes of a queue's name, and takes `general`, in any case, for its
        settings.
      '';
    };
  };

  config = mkIf (cfg.enable && qcfg.queues != {}) {
    services.asterisk = {
      modules.needed."services.asterisk.queues.queues" = ["app_queue.so"];

      # also there without rules: a reload that finds no queuerules.conf keeps
      # the old rules (apps/app_queue.c reload_queue_rules)
      settings."queuerules.conf" = {};

      settings."queues.conf" =
        {
          general.persistentmembers = mkDefault qcfg.persistentMembers;
        }
        // mapAttrs (
          _: q:
            mkMerge [
              (toSection {
                inherit (q) strategy timeout retry;
                wrapuptime = q.wrapupTime;
                maxlen = q.maxLength;
                musicclass = q.musicOnHoldClass;
                member = map memberValue q.members;
              })
              q.settings
            ]
        )
        qcfg.queues;
    };

    assertions = [
      {
        assertion = reserved == [];
        message = "services.asterisk.queues.queues: `general` is reserved, in any case: ${lib.concatStringsSep ", " reserved}.";
      }
      {
        assertion = longNames == [];
        message = "services.asterisk.queues.queues: names longer than 79 bytes, which Asterisk cuts, so Queue() never finds them: ${lib.concatStringsSep ", " longNames}.";
      }
    ];
  };
}
