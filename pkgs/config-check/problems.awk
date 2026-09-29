# prints the errors and warnings of the log Asterisk wrote while it loaded
# the configuration, without the ones that come from the build having no
# network, see package.nix; exits 1 when there are none
#
#   gawk -f problems.awk LOG

# outbound registrations start 1 to 11 s after their module loads, and the
# first qualify of a contact comes within max_initial_qualify_time, so on a
# slow machine a failed attempt can land here; the build has no network to
# send them to, and that is no configuration error
/\] WARNING\[[0-9]+\] res_pjsip_outbound_registration\.c: .*registration attempt/ {
    next
}

/\] ERROR\[[0-9]+\] res_pjsip\.c: Error [0-9]+ 'Network is unreachable' sending [A-Z]+ request to endpoint / {
    next
}

/\] (ERROR|WARNING)\[/ {
    sub(/^\[[^]]*\] /, "")
    print
    found = 1
}

END {
    exit !found
}
