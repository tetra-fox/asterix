# SIP test client for VM tests: pjsua (from pjproject) run as a transient
# systemd unit, controlled through pjsua's telnet CLI by `sip-phone`.
#
#   sip-phone start NAME USER PASSWORD SERVER SIP_PORT CLI_PORT [pjsua args]
#   sip-phone cli NAME COMMAND...      e.g. sip-phone cli alice call new sip:102@pbx
#   sip-phone stop NAME
#
# The phone answers every call, loops received audio back and sends audio
# continuously (no VAD), so RTP flows in both directions. Full SIP traces are
# logged to /tmp/sip-phone-NAME.log.
{ pkgs, ... }:
let
  sipPhone = pkgs.writeShellApplication {
    name = "sip-phone";
    runtimeInputs = [
      pkgs.pjsip
      pkgs.coreutils
      pkgs.systemd
    ];
    text = ''
      command=$1
      shift
      mkdir -p /run/sip-phone
      case $command in
        start)
          name=$1 user=$2 password=$3 server=$4 sip_port=$5 cli_port=$6
          shift 6
          echo "$cli_port" > "/run/sip-phone/$name.port"
          rm -f "/tmp/sip-phone-$name.log"
          systemd-run --unit="sip-phone-$name" --collect \
            pjsua \
              --id="sip:$user@$server" --registrar="sip:$server" \
              --realm='*' --username="$user" --password="$password" \
              --null-audio --no-vad --no-tcp --local-port="$sip_port" \
              --auto-answer=200 --auto-loop \
              --use-cli --cli-telnet-port="$cli_port" --no-cli-console \
              --log-file="/tmp/sip-phone-$name.log" --log-level=5 --app-log-level=3 \
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
in
{
  environment.systemPackages = [ sipPhone ];
}
