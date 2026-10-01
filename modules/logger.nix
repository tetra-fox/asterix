# Asterisk runs in the foreground under systemd, so the `console` channel is
# its standard output and ends up in the journal (`journalctl -u asterisk`).
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    filterAttrs
    mapAttrs
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  inherit (import ../lib {inherit lib;}) format;

  # the levels logger.c and modules register, in any case, and * for all; it
  # skips any other without a word (main/logger.c:211-219, make_components)
  levels = ["debug" "trace" "notice" "warning" "error" "verbose" "dtmf" "security" "fax" "cc" "pjsip_history"];
  level =
    types.addCheck types.str (
      level: let
        name = lib.toLower (lib.trim level);
      in
        builtins.elem name levels || name == "*" || builtins.match "verbose[(][0-9]+[)]" name != null
    )
    // {
      description = "log level (${concatStringsSep ", " levels}, verbose(<level>) or *, in any case)";
    };

  # the `security` level only exists once res_security_log registers it
  logsSecurity =
    builtins.any (
      levels: builtins.elem "security" (map (level: lib.toLower (lib.trim level)) (lib.splitString "," levels))
    )
    (builtins.filter builtins.isString (builtins.attrValues (
      removeAttrs (cfg.settings."logger.conf".logfiles or {}) format.metaAttrs
    )));
in {
  options.services.asterisk.logger = {
    channels = mkOption {
      type = types.attrsOf (types.listOf level);
      default = {};
      example = {
        console = [
          "notice"
          "warning"
          "error"
          "verbose"
        ];
        messages = [
          "notice"
          "warning"
          "error"
        ];
        security = ["security"];
        "syslog.local0" = [
          "warning"
          "error"
        ];
      };
      description = ''
        Log channels (the `[logfiles]` section), mapping a channel to its
        levels; `security` loads res_security_log.so. A channel with a
        formatter such as `[json]` goes in `settings."logger.conf".logfiles`
        instead. `console` is standard output, which goes to the journal;
        Asterisk adds `verbose` to it whatever its levels, so the `verbose`
        option of asterisk.conf alone decides which verbose messages reach
        the journal. `syslog.<facility>` logs to syslog; any other name is a
        file in {file}`/var/log/asterisk`. `console` defaults to
        `notice,warning,error`; set a channel to `[ ]` to remove it.
      '';
    };

    dateFormat = mkOption {
      type = types.str;
      default = "%F %T.%3q";
      description = "strftime(3) format of log timestamps (`%q` adds fractions of a second).";
    };

    queueLog = mkOption {
      type = types.bool;
      default = false;
      description = "Write queue events to {file}`/var/log/asterisk/queue_log`.";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      modules.needed."the security level in logger.conf" = mkIf logsSecurity ["res_security_log.so"];

      logger.channels.console = mkDefault [
        "notice"
        "warning"
        "error"
      ];

      settings."logger.conf" = {
        general = {
          order = 0;
          dateformat = mkDefault cfg.logger.dateFormat;
          queue_log = mkDefault cfg.logger.queueLog;
        };
        logfiles = mapAttrs (_: concatStringsSep ",") (
          filterAttrs (_: levels: levels != []) cfg.logger.channels
        );
      };
    };
  };
}
