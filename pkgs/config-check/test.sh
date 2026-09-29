# tests of problems.awk, run when the check is built: test.sh PROBLEMS.AWK
set -euo pipefail
cd "$(mktemp -d)"

cat > log << 'EOF'
[Sep 29 11:41:28] Asterisk 22.8.2 built by nixbld @ localhost on a x86_64 running Linux on 2026-09-13 16:36:28 UTC
[Sep 29 11:41:28] WARNING[44] res_pjsip_outbound_registration.c: No response received from 'sip:203.0.113.5' on registration attempt to 'sip:5551000@203.0.113.5', retrying in '60'
[Sep 29 11:41:28] ERROR[44] res_pjsip.c: Error 120101 'Network is unreachable' sending OPTIONS request to endpoint provider
[Sep 29 11:41:28] ERROR[44] res_pjsip.c: Error 171039 'Unsupported transport (PJSIP_EUNSUPTRANSPORT)' sending OPTIONS request to endpoint gate
[Sep 29 11:41:28] WARNING[18] pbx_config.c: No closing parenthesis found? 'Dial(PJSIP/101' at line 9 of extensions.conf
[Sep 29 11:41:28] NOTICE[18] cdr.c: CDR simple logging enabled.
EOF
# an entry that fills the logger's 8191 bytes loses its line break, and the
# next one follows it on the same line (main/logger.c logger_print_normal)
long() {
  local head="[Sep  9 11:41:29] $1"
  printf '%s' "$head"
  head -c $((8191 - ${#head})) /dev/zero | tr '\0' x
}
{
  long "WARNING[18] pbx_config.c: No closing parenthesis found? 'Dial("
  echo "[Sep  9 11:41:29] WARNING[44] res_pjsip_outbound_registration.c: No response received from 'sip:203.0.113.5' on registration attempt to 'sip:5551000@203.0.113.5', retrying in '60'"
  long "WARNING[44] res_pjsip_outbound_registration.c: No response received from 'sip:203.0.113.5' on registration attempt to 'sip:"
  echo "[Sep  9 11:41:29] ERROR[18] config.c: after a long registration attempt"
  long "ERROR[44] res_pjsip.c: Error 120101 'Network is unreachable' sending OPTIONS request to endpoint "
  long "WARNING[18] pbx_config.c: after a long unreachable network"
  echo "[Sep  9 11:41:29] VERBOSE[1] asterisk.c: Asterisk Ready."
  echo "[Sep  9 11:41:30] WARNING[60] res_pjsip_registrar.c: after loading, which is no configuration problem"
} >> log
gawk -f "$1" log > actual || true
cat > expected << 'EOF'
ERROR[44] res_pjsip.c: Error 171039 'Unsupported transport (PJSIP_EUNSUPTRANSPORT)' sending OPTIONS request to endpoint gate
WARNING[18] pbx_config.c: No closing parenthesis found? 'Dial(PJSIP/101' at line 9 of extensions.conf
EOF
{
  long "WARNING[18] pbx_config.c: No closing parenthesis found? 'Dial(" | cut -c19-
  echo "ERROR[18] config.c: after a long registration attempt"
  long "WARNING[18] pbx_config.c: after a long unreachable network" | cut -c19-
} >> expected
diff -u expected actual

# nothing to report
grep -v -e ERROR -e WARNING log > quiet
if gawk -f "$1" quiet; then
  echo "problems.awk reported problems in a log without any" >&2
  exit 1
fi
