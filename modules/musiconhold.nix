# A class plays the files of a directory, which can be a Nix path or package
# (copied to the store) or a directory relative to Asterisk's data directory
# (`moh` holds the package's default music).
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    mapAttrs
    mkIf
    mkMerge
    mkOption
    types
    ;

  cfg = config.services.asterisk;
  mcfg = cfg.musicOnHold;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;
  inherit (import ./lib.nix {inherit lib;}) toSection;

  # res_musiconhold looks for a relative directory in the data directory in
  # files mode (moh_scan_files), but in its working directory in custom mode,
  # where `nodir` and http:// URLs are no directory (spawn_mp3)
  directoryOf = c: let
    dir = lib.toLower c.directory;
  in
    if c.mode == "custom" && builtins.isString c.directory && !(lib.hasPrefix "/" dir || dir == "nodir" || lib.hasPrefix "http://" dir)
    then "${cfg.paths.data}/${c.directory}"
    else c.directory;

  classType = types.submodule {
    options = {
      mode = mkOption {
        type = types.enum [
          "files"
          "playlist"
          "custom"
        ];
        default = "files";
        description = ''
          `files` plays the files of `directory`, `playlist` plays `entries`,
          `custom` streams the output of `application`.
        '';
      };
      directory = mkOption {
        type = types.nullOr (types.either types.path types.str);
        default = null;
        example = lib.literalExpression "./music";
        description = ''
          Directory with sound files (formats Asterisk has codecs for, such as
          WAV, GSM or ulaw). A Nix path or package is copied to the store; a
          relative string is resolved against Asterisk's data directory.
        '';
      };
      sort = mkOption {
        type = types.nullOr (
          types.enum [
            "random"
            "alpha"
            "randstart"
          ]
        );
        default = null;
        description = "Order of the files.";
      };
      entries = mkOption {
        type = types.listOf types.str;
        default = [];
        description = "Files or URLs played in `playlist` mode (`entry =>`).";
      };
      application = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Command producing signed linear audio in `custom` mode.";
      };
      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
        example = {
          announcement = "queue-thankyou";
        };
        description = "Additional keys of the class section.";
      };
    };
  };
in {
  options.services.asterisk.musicOnHold.classes = mkOption {
    type = types.attrsOf classType;
    default = {};
    example = lib.literalExpression ''
      {
        default.directory = pkgs.linkFarm "office-moh" [
          { name = "hold.wav"; path = ./hold.wav; }
        ];
        quiet = { directory = "moh"; sort = "alpha"; };
      }
    '';
    description = ''
      Music on hold classes. The `default` class plays the music shipped with
      Asterisk unless it is redefined here.
    '';
  };

  config = mkIf cfg.enable {
    services.asterisk.modules.needed."services.asterisk.musicOnHold.classes" = mkIf (mcfg.classes != {}) ["res_musiconhold.so"];

    services.asterisk.settings."musiconhold.conf" =
      mapAttrs (
        _: c:
          mkMerge [
            (toSection {
              inherit
                (c)
                mode
                sort
                application
                ;
              directory = directoryOf c;
              entry = c.entries;
            })
            c.settings
          ]
      )
      mcfg.classes;

    services.asterisk.syntax."musiconhold.conf".arrowKeys = ["entry"];

    assertions =
      lib.mapAttrsToList (name: c: {
        assertion =
          (c.mode == "files" -> c.directory != null)
          && (c.mode == "custom" -> c.application != null)
          && (c.mode == "playlist" -> c.entries != []);
        message = "services.asterisk.musicOnHold.classes.${name}: mode `${c.mode}` needs ${
          {
            files = "a directory";
            custom = "an application";
            playlist = "entries";
          }
        .${
            c.mode
          }
        }.";
      })
      mcfg.classes;
  };
}
