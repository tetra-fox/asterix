{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  rcfg = cfg.rtp;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;
  inherit (import ./lib.nix {inherit lib;}) toSection;
in {
  options.services.asterisk.rtp = {
    portRange = {
      from = mkOption {
        type = types.port;
        default = 10000;
        description = "First UDP port for RTP and RTCP. Asterisk raises a port below 1024 to 1024.";
      };
      to = mkOption {
        type = types.port;
        default = 20000;
        description = "Last UDP port for RTP and RTCP. Each call leg uses two ports.";
      };
    };

    strictRtp = mkOption {
      type = types.nullOr (
        types.enum [
          true
          false
          "seqno"
        ]
      );
      default = null;
      description = "Drop RTP from unexpected sources (`strictrtp`); Asterisk's default is `yes`.";
    };

    ice = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = "Offer ICE candidates in SDP (`icesupport`); Asterisk's default is `yes`.";
    };

    stunServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "stun.example.org:3478";
      description = "STUN server used to discover the public address for ICE.";
    };

    turn = {
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "turn.example.org:3478";
        description = "TURN server offered as ICE relay candidate.";
      };
      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "TURN user name.";
      };
      password = mkOption {
        type = types.nullOr format.types.secretOrString;
        default = null;
        description = "TURN password, normally a secret reference.";
      };
    };

    settings = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        rtcpinterval = 5000;
      };
      description = "Additional keys of rtp.conf's `[general]` section.";
    };
  };

  config = mkIf cfg.enable {
    # the range is checked on the final rtp.conf, in asterisk.nix
    services.asterisk.settings."rtp.conf".general = lib.mkMerge [
      (toSection {
        rtpstart = rcfg.portRange.from;
        rtpend = rcfg.portRange.to;
        strictrtp = rcfg.strictRtp;
        icesupport = rcfg.ice;
        stunaddr = rcfg.stunServer;
        turnaddr = rcfg.turn.server;
        turnusername = rcfg.turn.username;
        turnpassword = rcfg.turn.password;
      })
      rcfg.settings
    ];
  };
}
