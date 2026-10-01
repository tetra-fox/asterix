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
    # Asterisk moves a port outside 1024-65535 into that range without a word
    # (res/res_rtp_asterisk.c:10080-10093)
    portRange = {
      from = mkOption {
        type = types.ints.between 1024 65535;
        default = 10000;
        description = "First UDP port for RTP and RTCP.";
      };
      to = mkOption {
        type = types.ints.between 1024 65535;
        default = 20000;
        description = ''
          Last UDP port for RTP. Each call leg takes an even port for RTP and
          the one above it for RTCP, so an even `to` uses `to + 1` as well,
          which `openFirewall` opens.
        '';
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
      description = ''
        Drop RTP from sources other than the one Asterisk learns in the first
        5 seconds of a call's media (`strictrtp`; `seqno` learns from sequence
        numbers alone). Asterisk's default is `yes`. A phone whose address or
        port changes after that, as behind a NAT that rebinds, is not heard
        for the rest of the call, and Asterisk logs it only at debug level.
        With `false`, Asterisk takes RTP from any source, and for endpoints
        with `behindNat` sends its own to where it comes from.
      '';
    };

    ice = mkOption {
      type = types.nullOr types.bool;
      default = null;
      description = ''
        Gather ICE candidates for the RTP of every call leg (`icesupport`);
        Asterisk's default is `yes`. Only endpoints with `ice_support` in
        their settings offer them, and then they include every address of
        the host, private ones too (`ice_deny` in `settings` leaves some out).
      '';
    };

    stunServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "stun.example.org:3478";
      description = ''
        STUN server Asterisk asks for its public address, which ICE offers as
        a candidate. With `ice`, Asterisk asks it for every call leg, endpoints
        without ICE too, and the call waits up to 9 seconds for each answer.
        It asks in RFC 3489 form, which servers that only follow RFC 5389
        ignore, such as coturn without `rfc3489-compatibility`.
      '';
    };

    turn = {
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "turn.example.org:3478";
        description = ''
          TURN server offered as ICE relay candidate. With `ice`, Asterisk
          allocates a relay on it over TCP for every call leg, endpoints
          without ICE too.
        '';
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
