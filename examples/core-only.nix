# Two phones that call each other, with services.asterisk alone: import
# asterix.nixosModules.asterisk (see README.md)
{
  config,
  lib,
  ...
}: let
  inherit (config.lib.asterisk) secret;
in {
  sops.secrets = lib.genAttrs ["sip-101" "sip-102"] (_: {
    reloadUnits = ["asterisk.service"];
  });

  services.asterisk = {
    enable = true;
    openFirewall = true;

    pjsip = {
      transports.udp = {};
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
