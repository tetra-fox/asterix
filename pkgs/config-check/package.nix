# asterisk-config-check [--low-ports] [--probe PROGRAM] ASTERISK CONFIG [ADDRESS...]
#
# Starts ASTERISK with the configuration in CONFIG and fails if Asterisk logs
# an error or warning while loading it, or if the dialplan uses an application
# or function that no loaded module provides. CONFIG is prepared by
# modules/asterisk.nix: `config/` with `@root@` where the files will be and a
# log channel `check`, `credentials/`, and `hosts` for the names Asterisk
# resolves while loading, since a build has no DNS. Secrets become zeros.
#
# ADDRESS are the addresses Asterisk listens on. IPv4 ones become loopback
# addresses, which a build can bind without privileges. Asterisk only runs in
# a user and network namespace of its own, which some machines forbid, to
# listen on an IPv6 ADDRESS or below port 1024 (--low-ports), or to keep it
# off the network when the build is not sandboxed.
#
# With --probe, a configuration that passes is not stopped at once: PROGRAM
# runs first, with `ASTERISK -C FILE` appended, the command line that reaches
# the running Asterisk (tests/campaign/probe.nix), and the check fails if it
# does.
{
  lib,
  coreutils,
  findutils,
  gawk,
  gnugrep,
  gnused,
  iproute2,
  nss_wrapper,
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
      arguments=("$@")
      low_ports=
      probe=
      while true; do
        case ''${1:-} in
          --low-ports)
            low_ports=1
            shift
            ;;
          --probe)
            probe=$2
            shift 2
            ;;
          *) break ;;
        esac
      done
      asterisk=$1 config=$2
      shift 2

      ipv6=()
      rewrite=()
      loopback=0
      for address in "$@"; do
        case $address in
          *:*) ipv6+=("$address") ;;
          *)
            loopback=$((loopback + 1))
            rewrite+=(-e "s/^([[:space:]]*(bind|bindaddr|tlsbindaddr)[[:space:]]*=>?[[:space:]]*)''${address//./\\.}(:[0-9]+)?([[:space:]]*)$/\\1127.100.0.$loopback\\3\\4/")
            ;;
        esac
      done

      if [ -z "''${ASTERISK_CONFIG_CHECK_NAMESPACE:-}" ]; then
        reasons=()
        # a sandboxed build has no network interface but lo
        links=$(ip -o link show)
        if grep -qv ': lo:' <<< "$links"; then
          reasons+=("to stay off the network of this unsandboxed build")
        fi
        if [ ''${#ipv6[@]} -gt 0 ]; then
          reasons+=("to listen on ''${ipv6[*]}")
        fi
        if [ -n "$low_ports" ]; then
          reasons+=("to listen below port 1024")
        fi
        if [ ''${#reasons[@]} -gt 0 ]; then
          if ! unshare --user --map-root-user --net true; then
            printf -v joined '%s, ' "''${reasons[@]}"
            echo "asterisk-config-check: Asterisk needs a user and network namespace of its own (''${joined%, }), which this machine does not allow" >&2
            exit 1
          fi
          ASTERISK_CONFIG_CHECK_NAMESPACE=1 exec unshare --user --map-root-user --net "$0" "''${arguments[@]}"
        fi
      else
        ip link set lo up
        for address in "''${ipv6[@]}"; do
          ip -6 address add "$address/128" dev lo nodad
        done
      fi

      root=$(mktemp -d)
      cp -rL --no-preserve=mode "$config/." "$root/"
      mkdir -p "$root/run" "$root/lib/spool" "$root/lib/agi-bin" "$root/log"
      # Asterisk checks the length of a digest that follows its algorithm
      find "$root/config" -type f -exec sed -i -E \
        -e "s|@root@|$root|g" \
        -e 's/(SHA-256|SHA-512-256):${secrets.placeholderPattern}/\1:${zeros 64}/g' \
        -e 's/${secrets.placeholderPattern}/${zeros 32}/g' \
        "''${rewrite[@]}" \
        {} +

      rx() {
        "$asterisk" -C "$root/config/asterisk.conf" -rx "$1"
      }
      preload=()
      if [ -f "$root/hosts" ]; then
        preload=(LD_PRELOAD=${nss_wrapper}/lib/libnss_wrapper.so NSS_WRAPPER_HOSTS="$root/hosts")
      fi
      env "''${preload[@]}" "$asterisk" -f -n -C "$root/config/asterisk.conf" > "$root/console" 2>&1 &
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

      failed=0
      # outbound registrations start 1 to 11 s after their module loads, so on
      # a slow machine a failed attempt can land here; the build has no
      # network to answer them, and that is no configuration error
      if grep -E '\] (ERROR|WARNING)\[' "$root/loaded" |
        grep -vE '\] WARNING\[[0-9]+\] res_pjsip_outbound_registration\.c: .*registration attempt' > "$root/problems"; then
        echo "Asterisk logged these while loading the configuration:" >&2
        sed -E 's/^\[[^]]*\] //' "$root/problems" >&2
        failed=1
      fi
      if ! gawk -v applications="$root/applications" -v functions="$root/functions" \
        -f ${./dialplan.awk} "$root/dialplan" >&2; then
        failed=1
      fi
      if [ "$failed" = 0 ] && [ -n "$probe" ]; then
        "$probe" "$asterisk" -C "$root/config/asterisk.conf" || failed=1
      fi
      rx "core stop now" > /dev/null
      wait "$pid"
      exit "$failed"
    '';
  }
