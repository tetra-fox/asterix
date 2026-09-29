# tests of render-secrets, run when it is built: test.sh RENDER-SECRETS
set -euo pipefail
render=$1
cd "$(mktemp -d)"
export CREDENTIALS_DIRECTORY=$PWD/credentials
mkdir "$CREDENTIALS_DIRECTORY"

placeholder() { printf '@NIX_ASTERISK_SECRET:file:/run/secrets/%s@' "$1"; }

# secret NAME VALUE [field]: a credential and its manifest line
secret() {
  printf '%s' "$2" > "$CREDENTIALS_DIRECTORY/secret-$1"
  printf '%s\tsecret-%s\t/run/secrets/%s\t%s\n' "$(placeholder "$1")" "$1" "$1" "${3:-}" >> manifest
}

secret semicolon $'p;w&d\\x"$HOME\n'
secret crlf $'pw\r\n'
secret xml $'a&b<c>"d\'e\n'
secret lines $'one\ntwo\n'
secret space $' padded\n'
secret lookalike "$(placeholder semicolon)"
secret comma $'a,b\n'
secret pin $'1234\n' field
secret commapin $'12,34\n' field
long=$(printf '0123456789%.0s' $(seq 818))
secret long "$long"
printf '%s\tsecret-missing\t/run/secrets/missing\n' "$(placeholder missing)" >> manifest

# check MODE INPUT EXPECTED
check() {
  printf '%s' "$2" > file
  "$render" "$1" manifest file
  if ! printf '%s' "$3" | cmp -s - file; then
    printf 'render-secrets %s: expected\n%s\ngot\n%s\n' "$1" "$3" "$(cat file)" >&2
    exit 1
  fi
}

# fails MODE INPUT MESSAGE
fails() {
  printf '%s' "$2" > file
  if "$render" "$1" manifest file 2> error; then
    printf 'render-secrets %s: no error for %s\n' "$1" "$2" >&2
    exit 1
  fi
  if ! grep -qF -- "$3" error; then
    printf 'render-secrets %s: expected "%s", got "%s"\n' "$1" "$3" "$(cat error)" >&2
    exit 1
  fi
}

s=$(placeholder semicolon)
check asterisk \
  "password = $s"$'\n'"200 => $s,Sales,$(placeholder crlf)$s"$'\n'"; a comment"$'\n'"last = $(placeholder lookalike)" \
  'password = p\;w&d\x"$HOME'$'\n''200 => p\;w&d\x"$HOME,Sales,pwp\;w&d\x"$HOME'$'\n''; a comment'$'\n'"last = $s"
check asterisk "x = $(placeholder xml)"$'\n' $'x = a&b<c>"d\'e\n'
check xml "<P34>$(placeholder xml)</P34>"$'\n' $'<P34>a&amp;b&lt;c&gt;&quot;d&apos;e</P34>\n'
check none "$(placeholder lines)|$(placeholder space)" $'one\ntwo| padded'
check asterisk "password = $(placeholder comma)"$'\n'"101 => $(placeholder pin),Sales"$'\n' $'password = a,b\n101 => 1234,Sales\n'

fails asterisk "x = $(placeholder lines)" "secret /run/secrets/lines contains a line break"
fails asterisk "x = $(placeholder space)" "secret /run/secrets/space has leading or trailing whitespace"
fails asterisk "101 => $(placeholder commapin),Sales" "secret /run/secrets/commapin is one field of a comma-separated value, so it cannot contain a comma"
fails asterisk "x = $(placeholder missing)" "secret /run/secrets/missing (credential secret-missing) is not available"
fails none "x = $(placeholder unknown)" "no credential for $(placeholder unknown)"

# Asterisk skips a line of more than 8190 bytes and logs how it begins
check asterisk "abcdefghij$(placeholder long)"$'\n' "abcdefghij$long"$'\n'
fails asterisk $'x = 1\n'"abcdefghijk$(placeholder long)" "line 2 of file is longer than 8190 bytes with /run/secrets/long in it"
if grep -qF 0123456789 error; then
  echo "render-secrets: the error shows the secret" >&2
  exit 1
fi
check xml "abcdefghijk$(placeholder long)" "abcdefghijk$long"
