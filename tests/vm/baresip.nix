# A second SIP stack for VM tests: baresip, which shares no code with
# Asterisk, unlike pjsua, and speaks SIP over WebSocket, which pjsua cannot.
# Run as a transient systemd unit by `baresip-phone`.
#
#   baresip-phone start NAME USER PASSWORD SERVER SIP_PORT TONE [CA_FILE]
#
# SERVER is a host name or a bracketed IPv6 address, optionally followed by a
# port and URI parameters, as in `pbx:8089;transport=wss`; the phone reaches
# it over that transport and its address's family, and verifies its
# certificate against CA_FILE if given. Like sip-phone, it answers every call,
# sends a sine of TONE Hz and records what the current call brings to
# /tmp/baresip-phone-NAME.wav. SIP traces go to /tmp/baresip-phone-NAME.log.
{pkgs, ...}: let
  # libre opens SIP WebSocket connections at the path / with no setting for it
  # (src/sip/transp.c:1066-1080), and Asterisk serves them at /ws
  # TODO: remove once libre lets an application choose the path
  libre = pkgs.libre.overrideAttrs (old: {
    postPatch =
      (old.postPatch or "")
      + ''
        substituteInPlace src/sip/transp.c \
          --replace-fail '"%s://%J/"' '"%s://%J/ws"' \
          --replace-fail '"%s://%j/"' '"%s://%j/ws"'
      '';
  });
  baresip = pkgs.baresip.override {
    inherit libre;
    librem = pkgs.librem.override {inherit libre;};
  };

  baresipPhone = pkgs.writeShellApplication {
    name = "baresip-phone";
    runtimeInputs = [
      baresip
      pkgs.coreutils
      pkgs.gawk
      pkgs.getent
      pkgs.gnused
      pkgs.iproute2
      pkgs.systemd
    ];
    text = ''
      command=$1
      shift
      case $command in
        start)
          name=$1 user=$2 password=$3 server=$4 sip_port=$5 tone=$6 ca_file=''${7:-}
          dir=/run/baresip-phone/$name
          mkdir -p "$dir"
          rm -f "/tmp/baresip-phone-$name.log" "/tmp/baresip-phone-$name.wav"
          # baresip resolves names with its own DNS client, which does not
          # read /etc/hosts, so the account talks to the server's address;
          # it binds to the interface it reaches the server through
          case $server in
            \[*)
              address=''${server%%]*}
              address=''${address#\[}
              target="[$address]''${server#*]}"
              family=-6
              ;;
            *)
              host=''${server%%[:;]*}
              address=$(getent ahostsv4 "$host" | awk 'NR == 1 { print $1 }')
              target=$address''${server#"$host"}
              family=-4
              ;;
          esac
          interface=$(ip -o route get "$address" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
          cat > "$dir/config" <<EOF
      module_path ${baresip}/lib/baresip/modules
      sip_listen 0.0.0.0:$sip_port
      audio_source ausine,$tone
      audio_player aufile,/tmp/baresip-phone-$name.wav
      audio_alert aufile,/dev/null
      ring_aufile none
      callwaiting_aufile none
      ringback_aufile none
      hangup_aufile none
      notfound_aufile none
      module g711.so
      module g722.so
      module ausine.so
      module aufile.so
      module_app account.so
      module_app menu.so
      EOF
          if [ -n "$ca_file" ]; then
            echo "sip_cafile $ca_file" >> "$dir/config"
          fi
          echo "<sip:$user@$target>;auth_pass=$password;answermode=auto;regint=600" > "$dir/accounts"
          # line buffered, or a log line a test waits for can sit in stdio's buffer
          systemd-run --unit="baresip-phone-$name" --collect \
            -p StandardOutput="file:/tmp/baresip-phone-$name.log" -p StandardError=inherit \
            stdbuf -oL -eL ${baresip}/bin/baresip -f "$dir" -n "$interface" "$family" -s
          ;;
        *)
          echo "usage: baresip-phone start ..." >&2
          exit 1
          ;;
      esac
    '';
  };
in {
  environment.systemPackages = [baresipPhone];
}
