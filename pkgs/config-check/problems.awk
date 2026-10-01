# prints the errors and warnings Asterisk logged while it loaded the
# configuration, up to "Asterisk Ready.", without the ones that come from the
# build having no network, see package.nix; exits 1 when there are none
#
#   gawk [-v named=FILE] -f problems.awk LOG
#
# With autoload, NAMED lists the modules modules.conf names, and the log has
# the loader's verbose messages: what the other modules log as they load is
# left out

BEGIN {
    if (named != "")
        while ((getline line < named) > 0) {
            sub(/\.so$/, "", line)
            is_named[line] = 1
        }
}

# an entry that fills the logger's 8191 bytes loses its line break
# (main/logger.c logger_print_normal) and the next one follows it on the same
# line, so a line is taken apart where the date and level of an entry start
function entries(line, list,    n) {
    n = 0
    while (match(substr(line, 2), /\[[A-Z][a-z][a-z] [ 0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] [A-Z]+\[[0-9]+\]/)) {
        list[++n] = substr(line, 1, RSTART)
        line = substr(line, RSTART + 1)
    }
    list[++n] = line
    return n
}

# outbound registrations start 1 to 11 s after their module loads, and the
# first qualify of a contact comes within max_initial_qualify_time, so on a
# slow machine a failed attempt can land here; the build has no network to
# send them to, and that is no configuration error
function unreachable(entry) {
    return entry ~ /^\[[^]]*\] WARNING\[[0-9]+\] res_pjsip_outbound_registration\.c: .*registration attempt/ ||
        entry ~ /^\[[^]]*\] ERROR\[[0-9]+\] res_pjsip\.c: Error [0-9]+ 'Network is unreachable' sending [A-Z]+ request to endpoint /
}

# a module that autoload brought in: one the loader started, which
# modules.conf does not name
function autoloaded(module) {
    sub(/\.so$/, "", module)
    return (module in started) && !(module in is_named)
}

# whether an entry comes from a module that autoload brought in: what the
# loader's thread logs while the module loads, from `Loading NAME.so.` to
# `NAME.so => (...)` or the loader's next line, which takes in what
# res_sorcery_config and config_options log for it, what the module's own
# source file logs, and the loader's lines that name only such modules, or
# modules that depend on them and that modules.conf does not name either
# (main/loader.c start_resource and load_modules); the loader's summary that
# some modules failed to load goes too, as each of them has a line of its own
function unwanted(thread, source, message,    module, m, n, k, others) {
    module = source
    if (sub(/\.c$/, "", module) && autoloaded(module))
        return 1
    if (source == "loader.c") {
        if (match(message, /^([^ ]+) declined to load\.$/, m))
            return autoloaded(m[1])
        if (match(message, /^Declined modules which depend on ([^:]+): (.*)$/, m)) {
            n = split(m[2], others, ", ")
            for (k = 1; k <= n; k++)
                if (others[k] in is_named)
                    return 0
            return autoloaded(m[1])
        }
        if (match(message, /^(Module|The deprecated module) '([^']+)' has been loaded/, m))
            return autoloaded(m[2])
        return message == "Some non-required modules failed to load."
    }
    return loading != "" && thread == loading_thread && autoloaded(loading)
}

{
    n = entries($0, list)
    for (i = 1; i <= n; i++) {
        if (list[i] ~ /^\[[^]]*\] VERBOSE\[[0-9]+\] asterisk\.c: Asterisk Ready\./)
            exit
        parsed = match(list[i], /^\[[^]]*\] ([A-Z]+)\[([0-9]+)\] ([^:]*): (.*)/, e)
        if (named != "" && parsed && e[3] == "loader.c") {
            if (match(e[4], /^Loading ([^ ]*)\.$/, m)) {
                loading = m[1] ~ /\.so$/ ? m[1] : ""
                loading_thread = e[2]
                sub(/\.so$/, "", loading)
                if (loading != "")
                    started[loading] = 1
            } else
                loading = ""
        }
        if (list[i] ~ /^\[[^]]*\] (ERROR|WARNING)\[/ && !unreachable(list[i]) &&
            !(named != "" && parsed && unwanted(e[2], e[3], e[4]))) {
            sub(/^\[[^]]*\] /, "", list[i])
            print list[i]
            found = 1
        }
    }
}

END {
    exit !found
}
