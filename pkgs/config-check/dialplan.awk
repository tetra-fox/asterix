# reports what the dialplan names that Asterisk does not have, see
# package.nix: an application, function or switch no loaded module provides,
# a sound no language has, or one that a language calls use lacks, and a
# Goto() or Gosub() target that does not exist
#
#   gawk -v applications=FILE -v functions=FILE -v switches=FILE \
#     -v settings=FILE -v formats=FILE -v languages=FILE \
#     -v asterisk=PROGRAM -v config=FILE -f dialplan.awk DIALPLAN
#
# APPLICATIONS is the output of `core show applications`, FUNCTIONS of
# `core show functions`, SWITCHES of `core show switches`, SETTINGS of `core
# show settings`, FORMATS of `core show file formats` and DIALPLAN of
# `dialplan show`. LANGUAGES lists the languages endpoints set, one a line.
# `PROGRAM -C FILE -rx COMMAND` runs a CLI command on the running Asterisk

@load "filefuncs"

# application and switch names are not case sensitive, function names are
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
    while ((getline line < switches) > 0)
        if (match(line, /^([A-Za-z0-9_]+): /, m))
            has_switch[tolower(m[1])] = 1

    while ((getline line < settings) > 0) {
        if (match(line, /^  Default language: +([^ ]*)/, m))
            in_use[m[1]] = 1
        else if (match(line, /^  Language prefix: +([A-Za-z]*)/, m))
            language_prefix = m[1] == "Enabled"
        else if (match(line, /^  Sounds search custom dir: +([A-Za-z]*)/, m))
            custom_dir = m[1] == "Enabled"
        else if (match(line, /^  Data directory: +(.*[^ ])/, m))
            sounds_dir = m[1] "/sounds"
    }
    # the extensions of every file format, which Asterisk tries in turn, and
    # of wav49, whose files it calls .WAV (main/file.c filehelper and
    # build_filename)
    listed = 0
    while ((getline line < formats) > 0) {
        if (line ~ /^-+ /)
            listed = 1
        else if (listed && split(line, columns) == 3) {
            n = split(columns[3], extensions, "|")
            for (i = 1; i <= n; i++)
                file_extension[extensions[i] == "wav49" ? "WAV" : extensions[i]] = 1
        }
    }
    while ((getline line < languages) > 0)
        if (line != "")
            in_use[line] = 1
}

function report(what) {
    printf "%s: no loaded module provides the %s\n", site, what
    missing++
}

function check_function(name) {
    if (!(name in has_function))
        report("function " name)
}

# argument I, from 1, of application data, as Asterisk separates it: at
# commas outside parentheses, brackets and double quotes, which it drops, and
# with a backslash taking the next character as it is (main/app.c
# __ast_app_separate_args)
function field(data, i,    n, paren, bracket, quote, c, k, current) {
    n = 1
    current = ""
    for (k = 1; k <= length(data); k++) {
        c = substr(data, k, 1)
        if (c == "(")
            paren++
        else if (c == ")" && paren)
            paren--
        else if (c == "[")
            bracket++
        else if (c == "]" && bracket)
            bracket--
        else if (c == "\"") {
            quote = !quote
            continue
        } else if (c == "\\")
            c = substr(data, ++k, 1)
        else if (c == "," && !paren && !bracket && !quote) {
            if (n == i)
                return current
            n++
            current = ""
            continue
        }
        current = current c
    }
    return n == i ? current : ""
}

# the sounds of a list such as Playback() takes, a&b, in the languages
# calls use or in LANGUAGE alone; a name from a variable is only known
# during a call, and an absolute path or a URL is outside the sounds
# directory
function sounds(list, language,    n, names, k) {
    n = split(list, names, "&")
    for (k = 1; k <= n; k++)
        if (names[k] != "" && names[k] !~ /\$|^\/|:\/\//)
            add_sound(site, names[k], language)
}

function add_sound(where, name, language) {
    sound_count++
    sound_where[sound_count] = where
    sound_name[sound_count] = name
    sound_language[sound_count] = language
}

# whether a file of NAME exists in LANGUAGE, or outside every language when
# LANGUAGE is empty; without the language prefix, a language goes after the
# last / of NAME (main/file.c fileexists_test)
function exists(name, language,    path, e, st) {
    if (language == "")
        path = sounds_dir "/" name
    else if (language_prefix)
        path = sounds_dir "/" language "/" name
    else
        path = sounds_dir "/" gensub(/([^\/]*)$/, language "/\\1", 1, name)
    for (e in file_extension)
        if (stat(path "." e, st, 1) == 0)
            return 1
    return 0
}

# whether Asterisk finds NAME for a call in LANGUAGE before it falls back to
# English: in the language, the language without each _ suffix and then
# outside every language (main/file.c fileexists_core), also below custom/
# with sounds_search_custom_dir (ast_streamfile)
function found(name, language,    names, n, k, l) {
    n = 1
    names[1] = name
    if (custom_dir)
        names[++n] = "custom/" name
    for (k = 1; k <= n; k++) {
        for (l = language; l != ""; ) {
            if (exists(names[k], l))
                return 1
            if (!sub(/_[^_]*$/, "", l))
                break
        }
        if (exists(names[k], ""))
            return 1
    }
    return 0
}

# whether LANGUAGE, or the language without each _ suffix, has a directory of
# sounds; without the language prefix, sounds keep their languages in
# directories of their own
function has_sounds(language,    st) {
    if (!language_prefix)
        return 1
    for (;;) {
        if (stat(sounds_dir "/" language, st, 1) == 0 && st["type"] == "directory")
            return 1
        if (!sub(/_[^_]*$/, "", language))
            return 0
    }
}

# a sound is missing when no language calls use has it, not even English,
# where Asterisk looks last (main/file.c fileexists_core), and missing in a
# language when English stands in for it; a language with no sounds at all
# is reported once instead
function check_sound(i,    name, where, wanted, language, nowhere) {
    name = sound_name[i]
    where = sound_where[i]
    if (sound_language[i] == "" || sound_language[i] ~ /\$/)
        for (language in in_use)
            wanted[language] = 1
    else
        wanted[sound_language[i]] = 1
    nowhere = !found(name, "en")
    for (language in wanted)
        if (found(name, language))
            nowhere = 0
    if (nowhere)
        print_once(where ": no sound " name)
    # a language from a variable is only known during a call
    else if (sound_language[i] !~ /\$/)
        for (language in wanted)
            if (!(language in without_sounds) && !found(name, language))
                print_once(where ": no sound " name " in language " language)
}

function print_once(line) {
    if (!(line in printed)) {
        printed[line] = 1
        print line
        missing++
    }
}

# S as one word of a shell command
function sq(s) {
    gsub(/'/, "'\\''", s)
    return "'" s "'"
}

# whether LINE of `dialplan show` is a priority, `N. App(data)` after the
# extension or a label if any; P gets its number, label and what follows
function priority(line, p,    m) {
    delete p
    if (!match(line, /^ *('[^']*' => +)?(\[([^]]*)\] +)? *([0-9]+)\. /, m))
        return 0
    p["number"] = m[4] + 0
    p["label"] = m[3]
    p["rest"] = substr(line, RLENGTH + 1)
    return 1
}

# the position of the first CHARACTER of DATA outside parentheses, brackets
# and braces, which keep ${...}, $[...] and the arguments of a Gosub whole,
# or 0
function top(data, character,    depth, k, c) {
    for (k = 1; k <= length(data); k++) {
        c = substr(data, k, 1)
        if (c ~ /[([{]/)
            depth++
        else if (c ~ /[])}]/ && depth > 0)
            depth--
        else if (c == character && depth == 0)
            return k
    }
    return 0
}

# a target of Goto() or Gosub(), [[context,]extension,]priority, which
# Asterisk splits at commas, and a Gosub's at the ( of its arguments
# (main/pbx.c pbx_parseable_goto, apps/app_stack.c gosub_exec); a field left
# out or empty is the call's own (ast_explicit_goto). One from a variable is
# only known during a call, and a priority after + or - counts from the
# current one
function add_target(target, gosub,    n, f) {
    if (gosub)
        sub(/\(.*/, "", target)
    if (target ~ /\$/)
        return
    n = split(target, f, ",")
    if (n == 1) {
        f[3] = f[1]
        f[1] = f[2] = ""
    } else if (n == 2) {
        f[3] = f[2]
        f[2] = f[1]
        f[1] = ""
    }
    if (f[3] == "" || f[3] ~ /^[+-]/)
        return
    target_count++
    target_site[target_count] = site
    target_context[target_count] = f[1] == "" ? context : f[1]
    target_extension[target_count] = f[2] == "" ? extension : f[2]
    target_priority[target_count] = f[3]
}

# the targets of GotoIf(), GotoIfTime() and GosubIf(): after the first ?,
# the second after the first : that follows (main/pbx_builtins.c
# pbx_builtin_gotoif and pbx_builtin_gotoiftime, apps/app_stack.c
# gosubif_exec); an empty one goes on with the next priority
function add_branches(data, gosub,    q, branches, c) {
    q = top(data, "?")
    if (!q)
        return
    branches = substr(data, q + 1)
    c = top(branches, ":")
    if (!c)
        c = length(branches) + 1
    if (c > 1)
        add_target(substr(branches, 1, c - 1), gosub)
    if (c < length(branches))
        add_target(substr(branches, c + 1), gosub)
}

# whether a call in CONTEXT can reach extensions that `dialplan show` does
# not see: through a switch, or through an include with a time, which it
# looks up as a context of that whole name (main/pbx.c show_dialplan_helper)
function open_ended(c, seen,    k) {
    if (c in seen)
        return 0
    seen[c] = 1
    if (c in switched)
        return 1
    for (k = 1; k <= include_count[c]; k++)
        if (included[c, k] ~ /[,|]/ || open_ended(included[c, k], seen))
            return 1
    return 0
}

# whether `dialplan show E@C`, which matches patterns and follows includes as
# a call does, finds extension E, with the numbers and labels of what it
# shows in shown_priority and shown_label
function look_up(c, e,    command, line, p) {
    if ((c, e) in looked_up)
        return looked_up[c, e]
    looked_up[c, e] = 1
    command = sq(asterisk) " -C " sq(config) " -rx " sq("dialplan show " e "@" c)
    while ((command | getline line) > 0)
        if (line ~ /^There is no existence of /)
            looked_up[c, e] = 0
        else if (priority(line, p)) {
            shown_priority[c, e, p["number"]] = 1
            if (p["label"] != "")
                shown_label[c, e, p["label"]] = 1
        }
    close(command)
    return looked_up[c, e]
}

# an extension the dump shows in the target's own context is the one a call
# finds; any other is looked up, unless the CLI cannot take its name or a
# switch or timed include may have it
function check_target(i,    c, e, target, number, where) {
    c = target_context[i]
    e = target_extension[i]
    target = target_priority[i]
    # spaces around a number do not make it a label (main/pbx.c
    # pbx_parse_location)
    number = target ~ /^[[:space:]]*[0-9]+[[:space:]]*$/
    # a call goes on in the context and extension its channel keeps, 79 bytes
    # of each (main/channel_internal_api.c ast_channel_context_set), while a
    # label is looked up by the whole names
    if (number) {
        c = substr(c, 1, 79)
        e = substr(e, 1, 79)
    }
    where = target_site[i] ": "
    if (!(c in has_context)) {
        print_once(where "no context " c)
        return
    }
    if ((c, e) in has_extension) {
        if (number ? ((c, e, target + 0) in has_priority) : ((c, e, target) in has_label))
            return
    } else if ((c e) ~ /[[:space:]]/ || e ~ /@/ || open_ended(c))
        return
    else if (!look_up(c, e)) {
        # a call to a missing extension goes on at the i or e extension of the
        # context, if it has one (main/pbx.c __ast_pbx_run)
        if (!look_up(c, "i") && !look_up(c, "e"))
            print_once(where "no extension " e " in context " c)
        return
    } else if (number ? ((c, e, target + 0) in shown_priority) : ((c, e, target) in shown_label))
        return
    print_once(where "no " (number ? "priority " : "label ") target " in extension " e " of context " c)
}

match($0, /^\[ Context '([^']*)'/, m) {
    context = m[1]
    has_context[context] = 1
}

match($0, /^ *'([^']*)' =>/, m) {
    extension = m[1]
    has_extension[context, extension] = 1
}

match($0, /^  Include => +'([^']*)'/, m) {
    included[context, ++include_count[context]] = m[1]
}

/^  Alt\. Switch => / {
    switched[context] = 1
}

# a switch, `Alt. Switch => 'Name/data'`, which Asterisk passes over on every
# call when no module provides it
match($0, /^  Alt\. Switch => +'([^'\/]*)/, m) && !(tolower(m[1]) in has_switch) {
    printf "(%s): no loaded module provides the switch %s\n", context, m[1]
    missing++
}

# a priority, and where it was defined, such as [extensions.conf:12]
priority($0, p) {
    has_priority[context, extension, p["number"]] = 1
    if (p["label"] != "")
        has_label[context, extension, p["label"]] = 1
    rest = p["rest"]
    if (!match(rest, /^[A-Za-z0-9_]+\(/))
        next
    app = substr(rest, 1, RLENGTH - 1)
    data = substr(rest, RLENGTH + 1)
    match(data, /\) +\[([^]]*)\] *$/, m)
    site = m[1] " (" context ", " extension ")"
    data = substr(data, 1, RSTART - 1)
    if (!(tolower(app) in has_application))
        report("application " app)
    # Set(FUNCTION(...)=value) writes to a function
    if (tolower(app) == "set" && match(data, /^[A-Za-z0-9_]+\(/))
        check_function(substr(data, 1, RLENGTH - 1))
    for (rest = data; match(rest, /\$\{[A-Za-z0-9_]+\(/); ) {
        name = substr(rest, RSTART + 2, RLENGTH - 3)
        rest = substr(rest, RSTART + RLENGTH)
        check_function(name)
    }

    app = tolower(app)
    if (app == "playback" || app == "controlplayback" || app == "backgrounddetect")
        sounds(field(data, 1), "")
    # Background(sounds,options,language,context)
    else if (app == "background")
        sounds(field(data, 1), field(data, 3))
    # Read(variable,sounds,...)
    else if (app == "read")
        sounds(field(data, 2), "")
    # ConfBridge(conference,bridge profile,...)
    else if (app == "confbridge") {
        profile = field(data, 2)
        if (profile !~ /\$/)
            bridge_profiles[profile == "" ? "default_bridge" : profile] = 1
    } else if (app == "goto")
        add_target(data, 0)
    else if (app == "gosub")
        add_target(data, 1)
    else if (app == "gotoif" || app == "gotoiftime")
        add_branches(data, 0)
    else if (app == "gosubif")
        add_branches(data, 1)
}

END {
    PROCINFO["sorted_in"] = "@ind_str_asc"
    # the sounds a bridge profile plays, `sound_...: name`
    for (profile in bridge_profiles) {
        command = sq(asterisk) " -C " sq(config) " -rx " sq("confbridge show profile bridge " profile)
        while ((command | getline line) > 0)
            if (match(line, /^sound_[a-z_]+: +([^ ].*[^ ]|[^ ])/, m) && m[1] !~ /\$|^\/|:\/\//)
                add_sound("bridge profile " profile, m[1], "")
        close(command)
    }
    for (language in in_use)
        if (!has_sounds(language)) {
            without_sounds[language] = 1
            print_once("language " language " has no sounds")
        }
    for (i = 1; i <= sound_count; i++)
        check_sound(i)
    for (i = 1; i <= target_count; i++)
        check_target(i)
    exit (missing > 0)
}
