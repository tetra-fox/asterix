# render-secrets MODE MANIFEST FILE...
#
# Replaces the secret placeholders (lib/secrets.nix) in each FILE, in place,
# with the systemd credentials MANIFEST names, read from
# $CREDENTIALS_DIRECTORY. MANIFEST has one line per secret: the placeholder,
# the credential name, a description for error messages and `field` for a
# secret that is one field of a comma-separated value and so cannot contain a
# comma, separated by tabs. MODE says how values are written:
#
#   asterisk  a single line without leading or trailing whitespace, `;` as `\;`,
#             in a line of at most 8190 bytes
#   xml       `&<>"'` as entities
#   none      unchanged
#
# Every file and credential is read once, however many secrets there are.
{
  lib,
  coreutils,
  gawk,
  writeShellApplication,
}: let
  secrets = import ../../lib/secrets.nix {inherit lib;};
in
  writeShellApplication {
    name = "render-secrets";
    runtimeInputs = [
      coreutils
      gawk
    ];
    text = ''
      mode=$1 manifest=$2
      shift 2
      for file in "$@"; do
        LC_ALL=C gawk -v mode="$mode" -v manifest="$manifest" -v pattern=${lib.escapeShellArg secrets.placeholderPattern} \
          -f ${./render.awk} "$file" > "$file.rendered"
        mv "$file.rendered" "$file"
      done
    '';
    derivationArgs.postCheck = ''
      bash ${./test.sh} "$target"
    '';
  }
