# tests of problems.awk, run when the check is built: test.sh PROBLEMS.AWK
set -euo pipefail
cd "$(mktemp -d)"

cat > log << 'EOF'
[Sep 29 11:41:28] Asterisk 22.8.2 built by nixbld @ localhost on a x86_64 running Linux on 2026-09-13 16:36:28 UTC
[Sep 29 11:41:28] WARNING[44] res_pjsip_outbound_registration.c: No response received from 'sip:203.0.113.5' on registration attempt to 'sip:5551000@203.0.113.5', retrying in '60'
[Sep 29 11:41:28] ERROR[44] res_pjsip.c: Error 120101 'Network is unreachable' sending OPTIONS request to endpoint provider
[Sep 29 11:41:28] ERROR[44] res_pjsip.c: Error 171039 'Unsupported transport (PJSIP_EUNSUPTRANSPORT)' sending OPTIONS request to endpoint gate
[Sep 29 11:41:28] WARNING[58] res_musiconhold.c: poll() failed: Interrupted system call
[Sep 29 11:41:28] WARNING[58] res_musiconhold.c: poll() failed: Bad file descriptor
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
WARNING[58] res_musiconhold.c: poll() failed: Bad file descriptor
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

# with autoload, what the modules modules.conf does not name log while they
# load, and their declines, are left out, and what the named ones, other
# threads and the core log after loading stays
printf '%s\n' res_sorcery_config.so res_pjsip.so res_xmpp.so > named
cat > autoload << 'EOF'
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_sorcery_config.so.
[Sep 29 11:41:28] VERBOSE[21] loader.c: res_sorcery_config.so => (Sorcery Configuration File Object Wizard)
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_geolocation.so.
[Sep 29 11:41:28] ERROR[21] res_sorcery_config.c: Unable to load config file 'geolocation.conf'
[Sep 29 11:41:28] VERBOSE[21] loader.c: res_geolocation.so => (res_geolocation Module for Asterisk)
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_pjsip_config_wizard.so.
[Sep 29 11:41:28] VERBOSE[21] loader.c: res_pjsip_config_wizard.so => (PJSIP Config Wizard)
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_adsi.so.
[Sep 29 11:41:28] VERBOSE[21] loader.c: res_adsi.so => (ADSI Resource)
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_pjsip.so.
[Sep 29 11:41:28] ERROR[21] res_pjsip_config_wizard.c: Unable to load config file 'pjsip_wizard.conf'
[Sep 29 11:41:28] ERROR[21] config_options.c: Could not find option suitable for category '101' named 'direct_mdia' at line 32 of
[Sep 29 11:41:28] VERBOSE[21] loader.c: res_pjsip.so => (Basic SIP resource)
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_xmpp.so.
[Sep 29 11:41:28] ERROR[21] config_options.c: Unable to load config file 'xmpp.conf'
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading res_phoneprov.so.
[Sep 29 11:41:28] ERROR[21] res_phoneprov.c: Unable to load config phoneprov.conf
[Sep 29 11:41:28] WARNING[44] res_pjsip.c: another thread during the load of res_phoneprov
[Sep 29 11:41:28] VERBOSE[21] loader.c: Loading app_queue.so.
[Sep 29 11:41:28] WARNING[21] loader.c: Some non-required modules failed to load.
[Sep 29 11:41:28] WARNING[21] loader.c: Module 'res_adsi' has been loaded but may be removed in a future release.
[Sep 29 11:41:28] ERROR[21] loader.c: res_xmpp declined to load.
[Sep 29 11:41:28] ERROR[21] loader.c: Declined modules which depend on res_xmpp: chan_motif
[Sep 29 11:41:28] ERROR[21] loader.c: res_phoneprov declined to load.
[Sep 29 11:41:28] ERROR[21] loader.c: Declined modules which depend on res_phoneprov: res_pjsip_phoneprov_provider
[Sep 29 11:41:28] ERROR[21] loader.c: app_queue declined to load.
[Sep 29 11:41:28] WARNING[21] pbx.c: the core after loading
[Sep 29 11:41:28] VERBOSE[21] asterisk.c: Asterisk Ready.
EOF
gawk -v named=named -f "$1" autoload > actual || true
cat > expected << 'EOF'
ERROR[21] config_options.c: Could not find option suitable for category '101' named 'direct_mdia' at line 32 of
ERROR[21] config_options.c: Unable to load config file 'xmpp.conf'
WARNING[44] res_pjsip.c: another thread during the load of res_phoneprov
ERROR[21] loader.c: res_xmpp declined to load.
ERROR[21] loader.c: Declined modules which depend on res_xmpp: chan_motif
WARNING[21] pbx.c: the core after loading
EOF
diff -u expected actual
