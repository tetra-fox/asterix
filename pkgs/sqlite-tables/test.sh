# tests of sqlite-tables, run when it is built: test.sh SQLITE-TABLES SQLITE3
set -euo pipefail
tables=$1 sqlite3=$2
cd "$(mktemp -d)"
mkdir config

# conf MODULE TEXT: the file of cdr_sqlite3_custom or cel_sqlite3_custom
conf() {
  printf '%s\n' "$2" > "config/$1_sqlite3_custom.conf"
}

# check QUERY EXPECTED
check() {
  actual=$("$sqlite3" master.db "$1")
  if [ "$actual" != "$2" ]; then
    printf 'sqlite-tables: %s gave\n%s\ninstead of\n%s\n' "$1" "$actual" "$2" >&2
    exit 1
  fi
}

columns() {
  echo "select group_concat(name, ',') from pragma_table_info('$1')"
}

# a new database gets each table as the module creates it, the default name
# without a table, and nothing of a comment
conf cdr $'; Generated\n\n[master]\ncolumns => calldate, src , dst\ntable => cdr\nvalues => \'${CDR(start)}\', \'${CDR(src)}\', \'${CDR(dst)}\''
conf cel $'[master]\ncolumns => eventtype, eventtime ; uniqueid\nvalues => \'${eventtype}\', \'${eventtime}\''
"$tables" master.db config
check "select sql from sqlite_master where name = 'cdr'" "CREATE TABLE cdr (AcctId INTEGER PRIMARY KEY, calldate,src,dst)"
check "select sql from sqlite_master where name = 'cel'" "CREATE TABLE cel (AcctId INTEGER PRIMARY KEY, eventtype,eventtime)"

# more columns are added and the rows kept; a name is the same in any case
"$sqlite3" master.db "insert into cdr (calldate, src, dst) values ('2026-09-30', '101', '102')"
conf cdr $'[master]\ncolumns => CallDate, src, dst, linkedid, "peer account"'
"$tables" master.db config
check "$(columns cdr)" "AcctId,calldate,src,dst,linkedid,peer account"
check "select src, dst, linkedid is null from cdr" "101|102|1"

# fewer columns, as after a rollback, remove none, and the same ones twice add
# none
conf cdr $'[master]\ncolumns => calldate, LINKEDID'
"$tables" master.db config
"$tables" master.db config
check "$(columns cdr)" "AcctId,calldate,src,dst,linkedid,peer account"

# another table is created next to the old one
conf cdr $'[master]\ntable => calls\ncolumns => src'
"$tables" master.db config
check "$(columns calls)" "AcctId,src"
check "select count(*) from cdr" "1"

# the first [master] that is not a template, and its first table and columns
conf cel $'[master](!)\ncolumns => template\n[other]\ncolumns => other\n[Master]\nTable = events\ncolumns=eventtype\ncolumns => second\n[master]\ncolumns => third'
"$tables" master.db config
check "$(columns events)" "AcctId,eventtype"

# without columns the module does not load, and nothing is created
rm config/*
conf cdr $'[master]\ntable => unused'
"$tables" unused.db config
if [ -e unused.db ]; then
  echo "sqlite-tables: created a database for a module that does not load" >&2
  exit 1
fi

# fails DATABASE MESSAGE
fails() {
  if "$tables" "$1" config 2> error; then
    printf 'sqlite-tables: no error for %s\n' "$1" >&2
    exit 1
  fi
  if ! grep -qF "$2" error; then
    printf 'sqlite-tables: expected "%s", got "%s"\n' "$2" "$(cat error)" >&2
    exit 1
  fi
}

# a database it cannot read, or a table it cannot change, fails naming the file
conf cdr $'[master]\ntable => frozen\ncolumns => calldate'
echo garbage > garbage.db
fails garbage.db "cannot create the table that cdr_sqlite3_custom.conf names in garbage.db"
"$sqlite3" master.db "create view frozen as select 1 as AcctId"
fails master.db "cannot add the columns that cdr_sqlite3_custom.conf names to frozen in master.db"
