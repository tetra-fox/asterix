# services.asterisk: all layers. Replaces nixpkgs' services.asterisk module.
{ lib, ... }:
{
  disabledModules = [ "services/networking/asterisk.nix" ];

  imports = [
    (lib.mkRemovedOptionModule [
      "services"
      "asterisk"
      "confFiles"
    ] "Use services.asterisk.settings.<file>, or services.asterisk.extraConfig.<file> for raw text.")
    (lib.mkRemovedOptionModule [
      "services"
      "asterisk"
      "useTheseDefaultConfFiles"
    ] "Every configuration file is generated; none are copied from the package.")
    ./ari.nix
    ./asterisk.nix
    ./cdr.nix
    ./confbridge.nix
    ./dialplan.nix
    ./features.nix
    ./logger.nix
    ./manager.nix
    ./modules-conf.nix
    ./musiconhold.nix
    ./pjsip.nix
    ./queues.nix
    ./rtp.nix
    ./voicemail.nix
  ];
}
