# prints the errors and warnings Asterisk logged while it loaded the
# configuration, up to "Asterisk Ready.", without the ones that come from the
# build having no network, see package.nix; exits 1 when there are none
#
#   gawk -f problems.awk LOG

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

{
    n = entries($0, list)
    for (i = 1; i <= n; i++) {
        if (list[i] ~ /^\[[^]]*\] VERBOSE\[[0-9]+\] asterisk\.c: Asterisk Ready\./)
            exit
        if (list[i] ~ /^\[[^]]*\] (ERROR|WARNING)\[/ && !unreachable(list[i])) {
            sub(/^\[[^]]*\] /, "", list[i])
            print list[i]
            found = 1
        }
    }
}

END {
    exit !found
}
