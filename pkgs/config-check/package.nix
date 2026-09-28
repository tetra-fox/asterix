# asterisk-config-check ASTERISK CONFIG [ADDRESS...]
#
# Starts ASTERISK with the configuration in CONFIG and fails if Asterisk logs
# an error or warning while loading it, or if the dialplan uses an application
# or function that no loaded module provides. CONFIG is prepared by
# modules/asterisk.nix: `config/` with `@root@` where the files will be and a
# log channel `check`, and `credentials/`. Secrets become zeros. Asterisk runs
# in a network namespace of its own that has each ADDRESS.
{
  lib,
  coreutils,
  findutils,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  util-linux,
  writeShellApplication,
}: let
  secrets = import ../../lib/secrets.nix {inherit lib;};
  zeros = n: lib.strings.replicate n "0";
in
  writeShellApplication {
    name = "asterisk-config-check";
    runtimeInputs = [
      coreutils
      findutils
      gawk
      gnugrep
      gnused
      iproute2
      util-linux
    ];
    text = ''
      asterisk=$1 config=$2
      shift 2

      if [ -z "''${ASTERISK_CONFIG_CHECK_NAMESPACE:-}" ]; then
        if ! unshare --user --map-root-user --net true; then
          echo "asterisk-config-check: cannot create a user and network namespace; unprivileged user namespaces may be disabled on this machine" >&2
          exit 1
        fi
        ASTERISK_CONFIG_CHECK_NAMESPACE=1 exec unshare --user --map-root-user --net "$0" "$asterisk" "$config" "$@"
      fi

      ip link set lo up
      for address in "$@"; do
        case $address in
          *:*) ip -6 address add "$address/128" dev lo nodad ;;
          *) ip address add "$address/32" dev lo ;;
        esac
      done

      root=$(mktemp -d)
      cp -rL --no-preserve=mode "$config/." "$root/"
      mkdir -p "$root/run" "$root/lib/spool" "$root/lib/agi-bin" "$root/log"
      # Asterisk checks the length of a digest that follows its algorithm
      find "$root/config" -type f -exec sed -i -E \
        -e "s|@root@|$root|g" \
        -e 's/(SHA-256|SHA-512-256):${secrets.placeholderPattern}/\1:${zeros 64}/g' \
        -e 's/${secrets.placeholderPattern}/${zeros 32}/g' \
        {} +

      rx() {
        "$asterisk" -C "$root/config/asterisk.conf" -rx "$1"
      }
      "$asterisk" -f -n -C "$root/config/asterisk.conf" > "$root/console" 2>&1 &
      pid=$!
      for _ in $(seq 600); do
        if [ -S "$root/run/asterisk.ctl" ] || ! kill -0 "$pid" 2> /dev/null; then
          break
        fi
        sleep 0.1
      done
      if [ ! -S "$root/run/asterisk.ctl" ]; then
        echo "asterisk-config-check: Asterisk did not start:" >&2
        cat "$root/console" >&2
        exit 1
      fi
      if ! timeout 300 "$asterisk" -C "$root/config/asterisk.conf" -rx "core waitfullybooted" > /dev/null; then
        echo "asterisk-config-check: Asterisk did not finish loading:" >&2
        cat "$root/console" >&2
        [ ! -f "$root/log/check" ] || cat "$root/log/check" >&2
        exit 1
      fi
      # only what it logged while loading
      cp "$root/log/check" "$root/loaded"
      rx "dialplan show" > "$root/dialplan"
      rx "core show applications" > "$root/applications"
      rx "core show functions" > "$root/functions"
      rx "core stop now" > /dev/null
      wait "$pid"

      failed=0
      if grep -E '\] (ERROR|WARNING)\[' "$root/loaded" > "$root/problems"; then
        echo "Asterisk logged these while loading the configuration:" >&2
        sed -E 's/^\[[^]]*\] //' "$root/problems" >&2
        failed=1
      fi
      if ! gawk -v applications="$root/applications" -v functions="$root/functions" \
        -f ${./dialplan.awk} "$root/dialplan" >&2; then
        failed=1
      fi
      exit "$failed"
    '';
  }
