# logger.conf: log channels.
#
# Asterisk runs in the foreground under systemd, so the `console` channel is
# its standard output and ends up in the journal (`journalctl -u asterisk`).
{ config, lib, ... }:
let
  inherit (lib)
    concatStringsSep
    filterAttrs
    mapAttrs
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterisk-declarative;
in
{
  options.services.asterisk-declarative.logger = {
    channels = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = { };
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
        security = [ "security" ];
        "syslog.local0" = [
          "warning"
          "error"
        ];
      };
      description = ''
        Log channels (the `[logfiles]` section), mapping a channel to its
        levels (`debug`, `notice`, `warning`, `error`, `verbose`, `dtmf`,
        `fax`, `security`). `console` is standard output, which goes to the
        journal; `syslog.<facility>` logs to syslog; any other name is a file
        in {file}`/var/log/asterisk`. `console` defaults to
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
    services.asterisk-declarative = {
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
          filterAttrs (_: levels: levels != [ ]) cfg.logger.channels
        );
      };
    };
  };
}
