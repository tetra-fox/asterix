# prints the table and the columns that cdr_sqlite3_custom or
# cel_sqlite3_custom puts in its SQL, a line each, or nothing if it would not
# load: the first table and columns keys, in any case, of the first [master]
# section that is not a template (cdr/cdr_sqlite3_custom.c load_config,
# main/config.c ast_variable_retrieve), not counting what it inherits
#
#   gawk -v table=DEFAULT -f master.awk FILE

{
    line = $0
    # a ; that no backslash escapes starts a comment
    if (match(line, /(^|[^\\]);/))
        line = substr(line, 1, RSTART - 1 + (RLENGTH == 2))
    gsub(/\\;/, ";", line)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
}

line ~ /^\[/ {
    name = substr(line, 2)
    sub(/\].*/, "", name)
    master = !found && tolower(name) == "master" && line !~ /^\[[^]]*\][[:space:]]*\([^)]*!/
    found = found || master
    next
}

master && index(line, "=") {
    key = tolower(substr(line, 1, index(line, "=") - 1))
    value = substr(line, index(line, "=") + 1)
    sub(/^>/, "", value)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
    gsub(/^[[:space:]]+/, "", value)
    if (key == "table" && !seenTable) {
        seenTable = 1
        if (value != "")
            table = value
    }
    if (key == "columns" && !seenColumns) {
        seenColumns = 1
        columns = value
    }
}

END {
    if (columns == "")
        exit
    # the module keeps 79 bytes of the name, and both go through %q, which
    # doubles a single quote; each column is stripped of whitespace
    table = substr(table, 1, 79)
    gsub(/'/, "''", table)
    print table
    n = split(columns, parts, ",")
    list = ""
    for (i = 1; i <= n; i++) {
        column = parts[i]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", column)
        gsub(/'/, "''", column)
        list = list (i > 1 ? "," : "") column
    }
    print list
}
