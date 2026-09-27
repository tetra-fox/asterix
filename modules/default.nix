# services.asterisk-declarative: all layers.
{
  imports = [
    ./asterisk.nix
    ./dialplan.nix
    ./logger.nix
    ./modules-conf.nix
    ./pjsip.nix
    ./rtp.nix
    ./voicemail.nix
  ];
}
