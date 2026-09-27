# The smallest useful configuration: two SIP phones that can call each other
# by dialing 101 and 102. Passwords are read from files at service start
# (agenix/sops-nix style paths) and never enter the Nix store.
{ config, ... }:
let
  inherit (config.lib.asterisk) secret;

  phone = extension: {
    endpoint = {
      name = extension;
      type = "endpoint";
      context = "phones";
      disallow = "all";
      allow = [
        "g722"
        "ulaw"
      ];
      auth = extension;
      aors = extension;
      direct_media = false;
    };
    auth = {
      name = extension;
      type = "auth";
      username = extension;
      password = secret "/run/agenix/sip-${extension}";
    };
    aor = {
      name = extension;
      type = "aor";
      max_contacts = 1;
      remove_existing = true;
    };
  };
  alice = phone "101";
  bob = phone "102";
in
{
  services.asterisk-declarative = {
    enable = true;
    openFirewall = true;

    settings = {
      "pjsip.conf" = {
        transport-udp = {
          type = "transport";
          protocol = "udp";
          bind = "0.0.0.0:5060";
        };
        "101" = alice.endpoint;
        "101-auth" = alice.auth;
        "101-aor" = alice.aor;
        "102" = bob.endpoint;
        "102-auth" = bob.auth;
        "102-aor" = bob.aor;
      };

      "extensions.conf".phones.exten = [
        "_10X,1,Dial(PJSIP/\${EXTEN},30)"
        "_10X,n,Hangup()"
      ];

      "rtp.conf".general = {
        rtpstart = 10000;
        rtpend = 10999;
      };
    };
  };
}
