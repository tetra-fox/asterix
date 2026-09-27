# services.asterisk-declarative: all layers.
{
  imports = [
    ./asterisk.nix
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
