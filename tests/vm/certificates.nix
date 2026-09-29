# Certificates for the TLS tests, made when a test is built: a test CA,
# certificates it signs for the pbx node (192.168.1.1, 2001:db8:1::1) and a
# phones node (192.168.1.2), and certificates a TLS client must refuse for
# that node: expired, for another host and self-signed. Only `expired`
# expires.
{pkgs}:
pkgs.runCommand "asterisk-test-certificates" {nativeBuildInputs = [pkgs.openssl];} ''
  mkdir $out
  cd $out
  # 99991231235959Z is RFC 5280's notAfter for a certificate that does not expire
  forever=(-not_before 20000101000000Z -not_after 99991231235959Z)
  key() {
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1.key"
  }
  # sign NAME SUBJECT_ALT_NAMES VALIDITY...
  sign() {
    local name=$1 names=$2
    shift 2
    key "$name"
    openssl req -new -key "$name.key" -subj "/CN=$name" |
      openssl x509 -req -CA ca.pem -CAkey ca.key -extfile <(echo "subjectAltName = $names") "$@" -out "$name.pem"
  }

  key ca
  openssl req -x509 -key ca.key -subj /CN=asterisk-test-ca "''${forever[@]}" -out ca.pem
  sign pbx DNS:pbx,IP:192.168.1.1,IP:2001:db8:1::1 "''${forever[@]}"
  sign phone IP:192.168.1.2 "''${forever[@]}"
  sign expired IP:192.168.1.2 -not_before 20000101000000Z -not_after 20000102000000Z
  sign wrong-host DNS:elsewhere,IP:192.168.1.99 "''${forever[@]}"
  key self-signed
  openssl req -x509 -key self-signed.key -subj /CN=self-signed -addext "subjectAltName = IP:192.168.1.2" "''${forever[@]}" -out self-signed.pem
''
