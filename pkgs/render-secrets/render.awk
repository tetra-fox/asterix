# replaces secret placeholders in one file, see package.nix
#
#   gawk -v mode=MODE -v manifest=MANIFEST -v file=FILE -v pattern=REGEX -f render.awk < FILE

function fail(message) {
    print "render-secrets: " message > "/dev/stderr"
    exit 1
}

# the value of a placeholder's credential, escaped for `mode`, read once
function value(placeholder,    name, path, line, lines, count, status, v, parts, n, i, c) {
    if (placeholder in cache)
        return cache[placeholder]
    if (!(placeholder in credential))
        fail("no credential for " placeholder " in " manifest)
    name = credential[placeholder]
    path = ENVIRON["CREDENTIALS_DIRECTORY"] "/" name
    count = 0
    while ((status = (getline line < path)) > 0)
        lines[++count] = line
    if (status < 0 || ENVIRON["CREDENTIALS_DIRECTORY"] == "")
        fail("secret " source[placeholder] " (credential " name ") is not available")
    close(path)

    # line breaks at the end of the file are not part of the value
    while (count > 0 && lines[count] == "")
        count--
    v = ""
    for (i = 1; i <= count; i++)
        v = v (i > 1 ? "\n" : "") lines[i]
    sub(/\r$/, "", v)

    if (isField[placeholder] && index(v, ","))
        fail("secret " source[placeholder] " is one field of a comma-separated value, so it cannot contain a comma")
    if (isPin[placeholder] && v ~ /^[-*]|#/)
        fail("secret " source[placeholder] " is in a voicemail PIN, so it cannot start with - or *, or contain #")
    if (maxLength[placeholder] != "" && length(v) > maxLength[placeholder] + 0)
        fail("secret " source[placeholder] " is longer than " maxLength[placeholder] " bytes, the most it can have where Asterisk uses it")
    if (mode == "asterisk") {
        if (count > 1 || index(v, "\r"))
            fail("secret " source[placeholder] " contains a line break")
        if (v ~ /^[[:space:]]|[[:space:]]$/)
            fail("secret " source[placeholder] " has leading or trailing whitespace, which Asterisk config files cannot represent")
        n = split(v, parts, ";")
        v = parts[1]
        for (i = 2; i <= n; i++)
            v = v "\\;" parts[i]
    } else if (mode == "line") {
        if (v ~ /[[:cntrl:]]/)
            fail("secret " source[placeholder] " contains a control character, which a one-line value cannot hold")
    } else if (mode == "xml") {
        if (v ~ /[[:cntrl:]]/)
            fail("secret " source[placeholder] " contains a control character, which XML or a one-line value cannot hold")
        n = length(v)
        c = v
        v = ""
        for (i = 1; i <= n; i++)
            v = v ((substr(c, i, 1) in entity) ? entity[substr(c, i, 1)] : substr(c, i, 1))
    } else if (mode != "none") {
        fail("unknown mode " mode)
    }
    cache[placeholder] = v
    return v
}

BEGIN {
    while ((status = (getline line < manifest)) > 0) {
        split(line, fields, "\t")
        credential[fields[1]] = fields[2]
        source[fields[1]] = fields[3]
        isField[fields[1]] = fields[4] == "field"
        maxLength[fields[1]] = fields[5]
        isPin[fields[1]] = fields[6] == "pin"
    }
    if (status < 0)
        fail("cannot read " manifest)
    close(manifest)

    entity["&"] = "&amp;"
    entity["<"] = "&lt;"
    entity[">"] = "&gt;"
    entity["\""] = "&quot;"
    entity["'"] = "&apos;"
}

# left to right, so a value is never searched for placeholders itself. RT is
# kept first: reading a credential with getline sets it too
{
    terminator = RT
    rest = $0
    out = ""
    sources = ""
    while (match(rest, pattern)) {
        placeholder = substr(rest, RSTART, RLENGTH)
        out = out substr(rest, 1, RSTART - 1) value(placeholder)
        sources = sources (sources == "" ? "" : ", ") source[placeholder]
        rest = substr(rest, RSTART + RLENGTH)
    }
    # Asterisk skips a longer line and logs how it begins (main/config.c
    # config_text_file_load); the module checks the lines without secrets
    if (mode == "asterisk" && sources != "" && length(out rest) > 8190)
        fail("line " FNR " of " file " is longer than 8190 bytes with " sources " in it, which Asterisk skips")
    printf "%s%s", out rest, terminator
}
