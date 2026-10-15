# services.asterix.announcements: a prompt played to the caller, then a
# destination, in pbx-announcement-<name>. A prompt given as text is spoken
# by flite when the system is built.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};

  announcementType = types.submodule {
    options = {
      number = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "710";
        description = "Number phones dial to hear the announcement.";
      };
      prompt = mkOption {
        type = pbxLib.prompt;
        description = "What the caller hears.";
      };
      repeat = mkOption {
        type = types.ints.positive;
        default = 1;
        description = "How many times the prompt plays.";
      };
      destination = mkOption {
        type = pbxLib.destination;
        default = {hangup = true;};
        description = "Where the call goes after the last time the prompt plays.";
      };
    };
  };
in {
  options.services.asterix.announcements = mkOption {
    type = types.attrsOf announcementType;
    default = {};
    example = lib.literalExpression ''
      {
        closed = {
          prompt.text = "We are closed. Please call again tomorrow.";
          repeat = 2;
          destination.voicemail = "201";
        };
      }
    '';
    description = "Recordings or texts played to the caller, keyed by name: letters, digits, `_` and `-`.";
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      dialplan.contexts = mapAttrs' (name: announcement:
        nameValuePair (pbxLib.objectContext "announcement" name) {
          comment = mkDefault "from services.asterix.announcements.${name}";
          extensions.s =
            [(pbxLib.app "Answer" [])]
            ++ builtins.genList (_: pbxLib.app "Playback" [(pbxLib.promptSound "announcement" name announcement.prompt)]) announcement.repeat
            ++ pbxLib.steps announcement.destination;
        })
      cfg.announcements;
      sounds.packages = pbxLib.promptSounds pkgs "announcement" cfg.announcements;
    };

    assertions = pbxLib.promptAssertions "announcements" cfg.announcements;
  };
}
