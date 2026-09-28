# rtp.conf: media port range and NAT traversal (ICE, STUN, TURN).
{ config, lib, ... }:
let
  inherit (lib)
    filterAttrs
    mapAttrs
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  rcfg = cfg.rtp;
  asteriskLib = import ../lib { inherit lib; };
  inherit (asteriskLib) format;
in
{
  options.services.asterisk.rtp = {
    portRange = {
      from = mkOption {
        type = types.port;
        default = 10000;
        description = "First UDP port for RTP and RTCP.";
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
        type = types.nullOr (types.either types.str format.types.secret);
        default = null;
        description = "TURN password, normally a secret reference.";
      };
    };

    settings = mkOption {
      type = types.attrsOf format.types.value;
      default = { };
      example = {
        rtcpinterval = 5000;
      };
      description = "Additional keys of rtp.conf's `[general]` section.";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk.settings."rtp.conf".general = lib.mkMerge [
      (mapAttrs (_: mkDefault) (
        filterAttrs (_: v: v != null) {
          rtpstart = rcfg.portRange.from;
          rtpend = rcfg.portRange.to;
          strictrtp = rcfg.strictRtp;
          icesupport = rcfg.ice;
          stunaddr = rcfg.stunServer;
          turnaddr = rcfg.turn.server;
          turnusername = rcfg.turn.username;
          turnpassword = rcfg.turn.password;
        }
      ))
      rcfg.settings
    ];

    assertions = [
      {
        assertion = rcfg.portRange.from < rcfg.portRange.to;
        message = "services.asterisk.rtp.portRange: `from` (${toString rcfg.portRange.from}) must be lower than `to` (${toString rcfg.portRange.to}).";
      }
    ];
  };
}
