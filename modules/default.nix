# services.asterisk-declarative: all layers.
{
  imports = [
    ./asterisk.nix
    ./confbridge.nix
    ./dialplan.nix
    ./logger.nix
    ./modules-conf.nix
    ./pjsip.nix
    ./rtp.nix
    ./voicemail.nix
  ];
}
