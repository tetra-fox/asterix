# reports dialplan lines that use an application or function Asterisk does
# not have, see package.nix
#
#   gawk -v applications=FILE -v functions=FILE -f dialplan.awk DIALPLAN
#
# APPLICATIONS is the output of `core show applications`, FUNCTIONS of
# `core show functions` and DIALPLAN of `dialplan show`

# application names are not case sensitive, function names are
BEGIN {
    while ((getline line < applications) > 0)
        if (match(line, /^ *([A-Za-z0-9_]+): /, m))
            has_application[tolower(m[1])] = 1
    listed = 0
    while ((getline line < functions) > 0) {
        if (line ~ /^-+$/)
            listed = 1
        else if (listed && match(line, /^[A-Za-z0-9_]+ /))
            has_function[substr(line, 1, RLENGTH - 1)] = 1
    }
}

# every priority line ends with where it was defined, such as
# [extensions.conf:12]
function report(what,    source) {
    match($0, /\[([^]]*)\] *$/, source)
    printf "%s (%s, %s): no loaded module provides the %s\n", source[1], context, extension, what
    missing++
}

function check_function(name) {
    if (!(name in has_function))
        report("function " name)
}

match($0, /^\[ Context '([^']*)'/, m) {
    context = m[1]
}

match($0, /^ *'([^']*)' =>/, m) {
    extension = m[1]
}

# a priority: `N. App(data)`, after the extension or a label if any
match($0, /^ *('[^']*' => +)?(\[[^]]*\] +)? *[0-9]+\. /) {
    rest = substr($0, RLENGTH + 1)
    if (!match(rest, /^[A-Za-z0-9_]+\(/))
        next
    app = substr(rest, 1, RLENGTH - 1)
    data = substr(rest, RLENGTH + 1)
    if (!(tolower(app) in has_application))
        report("application " app)
    # Set(FUNCTION(...)=value) writes to a function
    if (tolower(app) == "set" && match(data, /^[A-Za-z0-9_]+\(/))
        check_function(substr(data, 1, RLENGTH - 1))
    while (match(data, /\$\{[A-Za-z0-9_]+\(/)) {
        name = substr(data, RSTART + 2, RLENGTH - 3)
        data = substr(data, RSTART + RLENGTH)
        check_function(name)
    }
}

END {
    exit (missing > 0)
}
