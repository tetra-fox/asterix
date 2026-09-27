# The smallest useful configuration: two SIP phones that call each other by
# dialing 101 and 102. Passwords are read from files at service start
# (agenix/sops-nix style paths) and never enter the Nix store.
{ config, ... }:
let
  inherit (config.lib.asterisk) secret;
in
{
  services.asterisk-declarative = {
    enable = true;
    openFirewall = true;

    pjsip = {
      transports.udp = { };
      endpoints = {
        "101" = {
          context = "phones";
          auth.password = secret "/run/agenix/sip-101";
        };
        "102" = {
          context = "phones";
          auth.password = secret "/run/agenix/sip-102";
        };
      };
    };

    dialplan.contexts.phones.extensions."_10X" = [
      "Dial(PJSIP/\${EXTEN},30)"
      "Hangup()"
    ];
  };
}
