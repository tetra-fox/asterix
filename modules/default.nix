# services.asterisk-declarative: all layers.
{
  imports = [
    ./asterisk.nix
    ./confbridge.nix
    ./dialplan.nix
    ./logger.nix
    ./modules-conf.nix
    ./musiconhold.nix
    ./pjsip.nix
    ./queues.nix
    ./rtp.nix
    ./voicemail.nix
  ];
}
