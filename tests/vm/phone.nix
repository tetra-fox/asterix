# SIP test client for VM tests: pjsua (from pjproject) run as a transient
# systemd unit, controlled through pjsua's telnet CLI by `sip-phone`.
#
#   sip-phone start NAME USER PASSWORD SERVER SIP_PORT CLI_PORT TONE [pjsua args]
#   sip-phone cli NAME COMMAND...      e.g. sip-phone cli alice call new sip:102@pbx
#   sip-phone stop NAME
#
# The phone sends a sine of TONE Hz on every call without pause (no VAD), so
# RTP flows in both directions, and records what its calls bring to
# /tmp/sip-phone-NAME.wav, so a test can tell who hears whom (tones.py). Full
# SIP traces are logged to /tmp/sip-phone-NAME.log. Whether it registers
# (--registrar), how it answers (--auto-answer) and its transport flags
# (--no-tcp, --ipv6, ...) come with the pjsua args, from phone.py.
{pkgs, ...}: let
  pjsip = pkgs.pjsip.overrideAttrs (old: {
    # fixes for pjsua's CLI (pjsua_app_cli.c, unfixed in pjproject master):
    # `call transfer_replaces` only accepts call ids when built with video and
    # stops listing them at the current call, and `im add_b` zeroes the buddy
    # config, so it subscribes from account 0 instead of the buddy's account
    # TODO: remove once pjproject fixes them
    patches = (old.patches or []) ++ [./pjsua-cli.patch];
    # pjsua never flushes its log file (upstream comments the call out for
    # speed), so a line a test waits for could stay in the stdio buffer
    # indefinitely. Flush after every message. pjproject also leaves IPv6
    # out unless config_site.h asks for it.
    postPatch =
      (old.postPatch or "")
      + ''
        substituteInPlace pjsip/src/pjsua-lib/pjsua_core.c --replace-fail \
          'pj_file_write(pjsua_var.log_file, buffer, &size);' \
          'pj_file_write(pjsua_var.log_file, buffer, &size); pj_file_flush(pjsua_var.log_file);'
        echo '#define PJ_HAS_IPV6 1' > pjlib/include/pj/config_site.h
      '';
  });

  sipPhone = pkgs.writeShellApplication {
    name = "sip-phone";
    runtimeInputs = [
      pjsip
      pkgs.coreutils
      pkgs.gawk
      pkgs.getent
      pkgs.gnused
      pkgs.iproute2
      pkgs.sox
      pkgs.systemd
    ];
    text = ''
      command=$1
      shift
      mkdir -p /run/sip-phone
      case $command in
        start)
          name=$1 user=$2 password=$3 server=$4 sip_port=$5 cli_port=$6 tone=$7
          shift 7
          echo "$cli_port" > "/run/sip-phone/$name.port"
          rm -f "/tmp/sip-phone-$name.log" "/tmp/sip-phone-$name.wav"
          # one second of a whole number of periods, which pjsua loops without
          # a click; quiet enough that 20 phones mixed together don't clip
          sox -n -r 16000 -b 16 -c 1 "/run/sip-phone/$name-tone.wav" synth 1 sine "$tone" vol 0.05
          # pjsua advertises the address of the default route's interface in
          # its SDP, which in the test VMs is QEMU's user network: every VM has
          # the same one there, so audio sent to it never arrives. Advertise
          # the address this machine reaches the server from instead. pjsua
          # would also give an IPv6 address to its IPv4 transport, which then
          # fails to start, so IPv6 phones run on machines without QEMU's
          # network, where pjsua finds its address itself.
          ip_addr=()
          case $server in
            \[*) ;;
            *)
              address=$(getent ahostsv4 "''${server%%[:;]*}" | awk 'NR == 1 { print $1 }')
              source=$(ip -o route get "$address" | sed -n 's/.* src \([^ ]*\).*/\1/p')
              ip_addr=(--ip-addr="$source")
              ;;
          esac
          # --log-append: pjsua reopens its log file when the CLI starts,
          # which would truncate a registration logged before that
          systemd-run --unit="sip-phone-$name" --collect \
            pjsua \
              --id="sip:$user@$server" \
              --realm='*' --username="$user" --password="$password" \
              "''${ip_addr[@]}" \
              --null-audio --no-vad --local-port="$sip_port" \
              --play-file="/run/sip-phone/$name-tone.wav" --auto-play \
              --rec-file="/tmp/sip-phone-$name.wav" --auto-rec \
              --use-cli --cli-telnet-port="$cli_port" --no-cli-console \
              --log-file="/tmp/sip-phone-$name.log" --log-append --log-level=5 --app-log-level=3 \
              "$@"
          ;;
        cli)
          name=$1
          shift
          port=$(cat "/run/sip-phone/$name.port")
          exec 3<>"/dev/tcp/127.0.0.1/$port"
          printf '%s\r\n' "$*" >&3
          sleep 1
          timeout 1 cat <&3 || true
          exec 3>&-
          ;;
        stop)
          systemctl stop "sip-phone-$1" || true
          ;;
        *)
          echo "usage: sip-phone start|cli|stop ..." >&2
          exit 1
          ;;
      esac
    '';
  };
in {
  environment.systemPackages = [sipPhone];
  # phones take what the PBX sends to the Contact they give, such as the ACK
  # for a TCP or TLS callee's answer, which comes over a new connection
  networking.firewall.enable = false;
}
