# nixpkgs' Asterisk is built without ODBC, so only the CSV and SQLite backends
# have typed options. Records are written below /var/log/asterisk.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mkDefault
    mkIf
    mkMerge
    mkOption
    splitString
    types
    ;

  cfg = config.services.asterisk;
  ccfg = cfg.cdr;
  ecfg = cfg.cel;
  asteriskLib = import ../lib {inherit lib;};
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

  # the channel ast_cel_fabricate_channel_from_event makes for each event has
  # these few variables, everything else is in its channel fields
  celColumns = {
    eventtype = var "eventtype";
    eventtime = var "eventtime";
    cidname = var "CALLERID(name)";
    cidnum = var "CALLERID(num)";
    exten = var "CHANNEL(exten)";
    context = var "CHANNEL(context)";
    channame = var "CHANNEL(channame)";
    appname = var "CHANNEL(appname)";
    appdata = var "CHANNEL(appdata)";
    uniqueid = var "CHANNEL(uniqueid)";
    linkedid = var "CHANNEL(linkedid)";
    peer = var "BRIDGEPEER";
  };

  sqliteSection = table: columns: {
    table = mkDefault table;
    columns = mkDefault (concatStringsSep ", " (builtins.attrNames columns));
    values = mkDefault (concatStringsSep ", " (map (v: "'${v}'") (builtins.attrValues columns)));
  };

  # the arguments __ast_app_separate_args (main/app.c) makes of a string:
  # commas inside (), [] or "" and after a backslash do not separate them
  argumentCount = s:
    (lib.foldl' (
        acc: c:
          if acc.escaped
          then acc // {escaped = false;}
          else if c == "\\"
          then acc // {escaped = true;}
          else if c == "("
          then acc // {parens = acc.parens + 1;}
          else if c == ")"
          then acc // {parens = lib.max 0 (acc.parens - 1);}
          else if c == "["
          then acc // {brackets = acc.brackets + 1;}
          else if c == "]"
          then acc // {brackets = lib.max 0 (acc.brackets - 1);}
          else if c == "\""
          then acc // {quoted = !acc.quoted;}
          else if c == "," && acc.parens == 0 && acc.brackets == 0 && !acc.quoted
          then acc // {count = acc.count + 1;}
          else acc
      ) {
        count = 1;
        parens = 0;
        brackets = 0;
        quoted = false;
        escaped = false;
      } (lib.stringToCharacters s))
    .count;

  # how each module separates its values; both separate columns at every comma
  valueCounts = {
    # into at most 200 (cdr/cdr_sqlite3_custom.c load_values_config)
    "cdr_sqlite3_custom.conf" = values: lib.min 200 (argumentCount values);
    "cel_sqlite3_custom.conf" = values: builtins.length (splitString "," values);
  };

  # the INSERT of every record fails when the numbers differ
  # (cdr/cdr_sqlite3_custom.c write_cdr)
  sqliteMismatches = lib.concatLists (
    lib.mapAttrsToList (
      file: valueCount: let
        master = cfg.settings.${file}.master or {};
        columns = builtins.length (splitString "," master.columns);
        values = valueCount master.values;
      in
        lib.optional (builtins.isString (master.columns or null) && builtins.isString (master.values or null) && columns != values)
        "${file}: columns ${toString columns}, values ${toString values}"
    )
    valueCounts
  );

  sqliteOptions = what: defaultTable: notes: {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether to write ${what} records to an SQLite database. Before
        Asterisk starts and before each reload, the table is created as the
        module would create it and the columns it lacks are added; none is
        ever removed, so the records of an older configuration still fit.${notes}
      '';
    };
    table = mkOption {
      type = types.str;
      default = defaultTable;
      description = "Table name. The database is {file}`/var/log/asterisk/master.db`.";
    };
  };
in {
  options.services.asterisk = {
    cdr = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Generate call detail records (`[general] enable`).";
      };

      unanswered = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Also record calls that were never answered and never offered to
          another channel, such as one to an extension that hangs up without
          answering. A call offered to a phone is recorded either way, as
          `NO ANSWER` when nobody picked up.
        '';
      };

      csv = {
        enable = lib.mkEnableOption "CDRs as CSV in {file}`/var/log/asterisk/cdr-csv/Master.csv`";
        settings = mkOption {
          type = types.attrsOf format.types.value;
          default = {};
          example = {
            usegmtime = true;
            loguniqueid = true;
          };
          description = "Keys of cdr.conf's `[csv]` section.";
        };
      };

      sqlite = sqliteOptions "CDR" "cdr" "";

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
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
        default = ["ALL"];
        example = [
          "CHAN_START"
          "CHAN_END"
          "ANSWER"
          "HANGUP"
        ];
        description = "Events to log.";
      };

      sqlite = sqliteOptions "CEL" "cel" "\n\nTo reload cel_sqlite3_custom.so by hand, use `module refresh cel_sqlite3_custom.so`: Asterisk's own reload of it, which `core reload` also runs, can stop its records until the next restart.";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    {
      services.asterisk = {
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
        modules.needed = {
          "services.asterisk.cdr.csv" = mkIf ccfg.csv.enable ["cdr_csv.so"];
          "services.asterisk.cdr.sqlite" = mkIf ccfg.sqlite.enable ["cdr_sqlite3_custom.so"];
          "services.asterisk.cel.sqlite" = mkIf ecfg.sqlite.enable ["cel_sqlite3_custom.so"];
        };
      };

      assertions = [
        {
          assertion = sqliteMismatches == [];
          message = ''
            services.asterisk: the number of values differs from the number of columns, so every record would fail to insert (cel_sqlite3_custom separates values at every comma, cdr_sqlite3_custom at commas outside (), [], "" and after \):
              ${concatStringsSep "\n  " sqliteMismatches}
          '';
        }
      ];
    }

    (mkIf ccfg.csv.enable {
      # cdr_csv writes to <astlogdir>/cdr-csv but does not create it
      systemd.services.asterisk.serviceConfig.LogsDirectory = ["asterisk/cdr-csv"];

      # cdr_csv declines to load when [csv] has no keys: write its defaults
      services.asterisk.settings."cdr.conf".csv =
        {
          accountlogs = mkDefault true;
          usegmtime = mkDefault false;
          loguniqueid = mkDefault false;
          loguserfield = mkDefault false;
          newcdrcolumns = mkDefault false;
        }
        // ccfg.csv.settings;
    })

    (mkIf ccfg.sqlite.enable {
      services.asterisk.settings."cdr_sqlite3_custom.conf".master =
        sqliteSection ccfg.sqlite.table cdrColumns;
    })

    (mkIf ecfg.sqlite.enable {
      services.asterisk.settings."cel_sqlite3_custom.conf".master =
        sqliteSection ecfg.sqlite.table celColumns;
    })

    {
      # cdr_sqlite3_custom.conf and cel_sqlite3_custom.conf use `key => value`
      services.asterisk.syntax =
        lib.genAttrs
        [
          "cdr_sqlite3_custom.conf"
          "cel_sqlite3_custom.conf"
        ]
        (_: {
          arrowSections = ["master"];
        });
    }
  ]);
}
