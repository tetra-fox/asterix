# Call detail records (cdr.conf) and channel event logging (cel.conf) with
# the CSV and SQLite backends built into the nixpkgs package. Records are
# written below /var/log/asterisk. (ODBC backends are not built in nixpkgs'
# Asterisk; other backends can be configured through `settings`.)
{ config, lib, ... }:
let
  inherit (lib)
    concatStringsSep
    mkDefault
    mkIf
    mkMerge
    mkOption
    optionals
    types
    ;

  cfg = config.services.asterisk-declarative;
  ccfg = cfg.cdr;
  ecfg = cfg.cel;
  asteriskLib = import ../lib { inherit lib; };
  inherit (asteriskLib) format;
  inherit (asteriskLib.dialplan) var;

  # column -> dialplan expression evaluated for each record
  cdrColumns = {
    calldate = var "CDR(start)";
    clid = var "CDR(clid)";
    src = var "CDR(src)";
    dst = var "CDR(dst)";
    dcontext = var "CDR(dcontext)";
    channel = var "CDR(channel)";
    dstchannel = var "CDR(dstchannel)";
    lastapp = var "CDR(lastapp)";
    lastdata = var "CDR(lastdata)";
    duration = var "CDR(duration)";
    billsec = var "CDR(billsec)";
    disposition = var "CDR(disposition)";
    amaflags = var "CDR(amaflags)";
    accountcode = var "CDR(accountcode)";
    uniqueid = var "CDR(uniqueid)";
    userfield = var "CDR(userfield)";
  };

  celColumns = {
    eventtype = var "eventtype";
    eventtime = var "eventtime";
    cidname = var "CALLERID(name)";
    cidnum = var "CALLERID(num)";
    exten = var "CEL_EXTEN";
    context = var "CEL_CONTEXT";
    channame = var "CEL_CHANNAME";
    appname = var "CEL_APPNAME";
    appdata = var "CEL_APPDATA";
    uniqueid = var "CEL_UNIQUEID";
    linkedid = var "CEL_LINKEDID";
    peer = var "CEL_PEER";
  };

  sqliteSection = table: columns: {
    table = mkDefault table;
    columns = mkDefault (concatStringsSep ", " (builtins.attrNames columns));
    values = mkDefault (concatStringsSep ", " (map (v: "'${v}'") (builtins.attrValues columns)));
  };

  sqliteOptions = what: defaultTable: {
    enable = lib.mkEnableOption "${what} records in an SQLite database";
    table = mkOption {
      type = types.str;
      default = defaultTable;
      description = "Table name. The database is {file}`/var/log/asterisk/master.db`.";
    };
  };
in
{
  options.services.asterisk-declarative = {
    cdr = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Generate call detail records (`[general] enable`).";
      };

      unanswered = mkOption {
        type = types.bool;
        default = false;
        description = "Also record calls nobody answered.";
      };

      csv = {
        enable = lib.mkEnableOption "CDRs as CSV in {file}`/var/log/asterisk/cdr-csv/Master.csv`";
        settings = mkOption {
          type = types.attrsOf format.types.value;
          default = { };
          example = {
            usegmtime = true;
            loguniqueid = true;
          };
          description = "Keys of cdr.conf's `[csv]` section.";
        };
      };

      sqlite = sqliteOptions "CDR" "cdr";

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = { };
        example = {
          batch = true;
          size = 100;
        };
        description = "Additional keys of cdr.conf's `[general]` section.";
      };
    };

    cel = {
      enable = lib.mkEnableOption "channel event logging (CEL)";

      events = mkOption {
        type = types.listOf types.str;
        default = [ "ALL" ];
        example = [
          "CHAN_START"
          "CHAN_END"
          "ANSWER"
          "HANGUP"
        ];
        description = "Events to log.";
      };

      sqlite = sqliteOptions "CEL" "cel";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.asterisk-declarative = {
        settings."cdr.conf".general = mkMerge [
          {
            enable = mkDefault ccfg.enable;
            unanswered = mkDefault ccfg.unanswered;
          }
          ccfg.settings
        ];
        settings."cel.conf".general = {
          enable = mkDefault ecfg.enable;
          events = mkIf ecfg.enable (mkDefault (concatStringsSep "," ecfg.events));
        };
        modules.load =
          optionals ccfg.csv.enable [ "cdr_csv.so" ]
          ++ optionals ccfg.sqlite.enable [ "cdr_sqlite3_custom.so" ]
          ++ optionals ecfg.sqlite.enable [ "cel_sqlite3_custom.so" ];
      };
    }

    (mkIf ccfg.csv.enable {
      # cdr_csv writes to <astlogdir>/cdr-csv but does not create it
      systemd.services.asterisk.serviceConfig.LogsDirectory = [ "asterisk/cdr-csv" ];

      # cdr_csv declines to load when [csv] has no keys: write its defaults
      services.asterisk-declarative.settings."cdr.conf".csv = {
        accountlogs = mkDefault true;
        usegmtime = mkDefault false;
        loguniqueid = mkDefault false;
        loguserfield = mkDefault false;
        newcdrcolumns = mkDefault false;
      }
      // ccfg.csv.settings;
    })

    (mkIf ccfg.sqlite.enable {
      services.asterisk-declarative.settings."cdr_sqlite3_custom.conf".master =
        sqliteSection ccfg.sqlite.table cdrColumns;
    })

    (mkIf ecfg.sqlite.enable {
      services.asterisk-declarative.settings."cel_sqlite3_custom.conf".master =
        sqliteSection ecfg.sqlite.table celColumns;
    })

    {
      # cdr_sqlite3_custom.conf and cel_sqlite3_custom.conf use `key => value`
      services.asterisk-declarative.syntax =
        lib.genAttrs
          [
            "cdr_sqlite3_custom.conf"
            "cel_sqlite3_custom.conf"
          ]
          (_: {
            arrowSections = [ "master" ];
          });
    }
  ]);
}
