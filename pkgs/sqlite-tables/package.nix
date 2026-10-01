# sqlite-tables DATABASE DIRECTORY
#
# Adds to DATABASE the table that cdr_sqlite3_custom.conf and
# cel_sqlite3_custom.conf in DIRECTORY each name, and the columns it lacks.
# Asterisk creates a missing table only when the module loads, never on a
# reload, and never adds a column (cdr/cdr_sqlite3_custom.c load_module), so
# without this every record after a change of the table or the columns fails
# to insert. Nothing is ever removed: a table with more columns than a file
# names takes its records too.
{
  lib,
  gawk,
  sqlite,
  writeShellApplication,
}:
writeShellApplication {
  name = "sqlite-tables";
  runtimeInputs = [
    gawk
    sqlite
  ];
  text = ''
    database=$1 directory=$2
    # waits up to 10 s for Asterisk's own writes
    sql() {
      sqlite3 -bail -cmd '.timeout 10000' "$database" "$@"
    }
    for module in cdr cel; do
      file=''${module}_sqlite3_custom.conf
      [ -f "$directory/$file" ] || continue
      master=$(LC_ALL=C gawk -v table="$module" -f ${./master.awk} "$directory/$file")
      [ -n "$master" ] || continue
      table=''${master%%$'\n'*} columns=''${master#*$'\n'}
      # create the table with the module's own statement, then list the
      # columns it lacks, by name as SQLite reads them and in any case
      if ! missing=$(sql "
        CREATE TABLE IF NOT EXISTS $table (AcctId INTEGER PRIMARY KEY, $columns);
        CREATE TEMP TABLE asterix_wanted (AcctId INTEGER PRIMARY KEY, $columns);
        CREATE TEMP VIEW asterix_have AS SELECT * FROM $table;
        SELECT name FROM pragma_table_info('asterix_wanted')
          WHERE lower(name) NOT IN (SELECT lower(name) FROM pragma_table_info('asterix_have'));
      "); then
        echo "sqlite-tables: cannot create the table that $file names in $database" >&2
        exit 1
      fi
      [ -n "$missing" ] || continue
      statements=
      while IFS= read -r column; do
        statements+="ALTER TABLE $table ADD COLUMN \"''${column//\"/\"\"}\";"
      done <<< "$missing"
      if ! sql "BEGIN IMMEDIATE; $statements COMMIT;"; then
        echo "sqlite-tables: cannot add the columns that $file names to $table in $database" >&2
        exit 1
      fi
    done
  '';
  derivationArgs.postCheck = ''
    bash ${./test.sh} "$target" ${lib.getExe sqlite}
  '';
}
