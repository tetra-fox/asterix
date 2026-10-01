# Asterisk runs in the foreground under systemd, so the `console` channel is
# its standard output and ends up in the journal (`journalctl -u asterisk`).
{
  config,
  lib,
  pkgs,
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
  logfiles = removeAttrs (cfg.settings."logger.conf".logfiles or {}) format.metaAttrs;
  general = cfg.settings."logger.conf".general or {};

  # the `security` level only exists once res_security_log registers it
  logsSecurity =
    builtins.any (
      levels: builtins.elem "security" (map (level: lib.toLower (lib.trim level)) (lib.splitString "," levels))
    )
    (builtins.filter builtins.isString (builtins.attrValues logfiles));

  # a channel other than the console and syslog is a file, below the log
  # directory unless its name starts with /, and with appendhostname the
  # host's name after a dot (main/logger.c make_filename)
  channelFiles =
    map (
      name:
        if lib.hasPrefix "/" name
        then name
        else "${cfg.paths.log}/${name}"
    ) (
      builtins.filter (name: lib.toLower name != "console" && !lib.hasPrefix "syslog" (lib.toLower name)) (builtins.attrNames logfiles)
    );
  appendHostName = format.isTrue (general.appendhostname or false);
  # the kernel's name, which Asterisk reads with gethostname(): the sysctl's if
  # set, or else networking.hostName, which leaves it to the network when empty
  hostName = let
    sysctl = config.boot.kernel.sysctl."kernel.hostname" or null;
  in
    if sysctl != null
    then toString sysctl
    else config.networking.hostName;
  # the files that grow with every call; Asterisk itself only rotates a log
  # past 1 GB on a logger reload (main/logger.c reload_logger)
  rotatedFiles =
    (
      if !appendHostName
      then channelFiles
      else if hostName == ""
      then []
      else map (file: "${file}.${hostName}") channelFiles
    )
    ++ lib.optional (format.isTrue (general.queue_log or false)) "${cfg.paths.log}/${general.queue_log_name or "queue_log"}"
    ++ lib.optional cfg.cdr.csv.enable "${cfg.paths.log}/cdr-csv/*.csv";
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

        logrotate rotates the files weekly and keeps four old ones,
        compressed but for the newest, as it does with {file}`queue_log` and
        the CSV CDRs; the settings are defaults in
        `services.logrotate.settings.asterisk`.
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
      description = ''
        Write queue events to {file}`/var/log/asterisk/queue_log`, which
        logrotate rotates like the file log channels (see
        {option}`services.asterisk.logger.channels`).
      '';
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

    warnings = lib.optional (appendHostName && hostName == "" && channelFiles != []) "services.asterisk: logger.conf's appendhostname adds the host's name to the log files ${concatStringsSep ", " channelFiles}, and with networking.hostName empty that name comes from the network when Asterisk starts, so logrotate does not rotate them. Set networking.hostName, or remove appendhostname.";

    # as nixpkgs' nginx module rotates its logs; Asterisk keeps a log file open
    # until a logger reload, and cdr_csv opens its files for every record
    services.logrotate.settings.asterisk = mkIf (rotatedFiles != []) (mapAttrs (_: mkDefault) {
      files = rotatedFiles;
      frequency = "weekly";
      rotate = 4;
      compress = true;
      delaycompress = true;
      # the service's user and group
      su = "asterisk asterisk";
      sharedscripts = true;
      # as root the client sets its scheduling policy (main/asterisk.c:3964),
      # which logrotate's system call filter forbids, as it does setpriv's capset
      postrotate = "[ ! -S ${cfg.paths.runtime}/asterisk.ctl ] || ${lib.getExe pkgs.su-exec} asterisk:asterisk ${cfg.package}/bin/asterisk -C ${cfg.paths.template}/asterisk.conf -rx 'logger reload'";
    });
  };
}
