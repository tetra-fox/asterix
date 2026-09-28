# The smallest useful configuration: two SIP phones that call each other by
# dialing 101 and 102. Passwords come from sops-nix (set sops.defaultSopsFile
# in the host's configuration) and never enter the Nix store.
{ config, lib, ... }:
let
  inherit (config.lib.asterisk) secret;
in
{
  # root-only files are fine: asterisk.service reads them as credentials, and
  # a reload picks up a changed password
  sops.secrets = lib.genAttrs [ "sip-101" "sip-102" ] (_: {
    reloadUnits = [ "asterisk.service" ];
  });

  services.asterisk-declarative = {
    enable = true;
    openFirewall = true;

    pjsip = {
      transports.udp = { };
      endpoints = {
        "101" = {
          context = "phones";
          auth.password = secret config.sops.secrets.sip-101.path;
        };
        "102" = {
          context = "phones";
          auth.password = secret config.sops.secrets.sip-102.path;
        };
      };
    };

    dialplan.contexts.phones.extensions."_10X" = [
      "Dial(PJSIP/\${EXTEN},30)"
      "Hangup()"
    ];
  };
}
