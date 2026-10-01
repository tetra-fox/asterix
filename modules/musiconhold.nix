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

  # the classes of the final musiconhold.conf, in lower case as Asterisk matches
  # them (res/res_musiconhold.c:2303-2310); null when files or realtime add more
  classes = let
    names = format.sectionNames {
      sections = lib.filterAttrs (_: section: !(section.template or false)) (cfg.settings."musiconhold.conf" or {});
      includes = cfg.includes."musiconhold.conf" or [];
      extraConfig = cfg.extraConfig."musiconhold.conf" or "";
    };
    realtime =
      (cfg.includes."extconfig.conf" or [])
      != []
      || (cfg.extraConfig."extconfig.conf" or "") != ""
      || builtins.any (section: builtins.any (key: lib.toLower key == "musiconhold") (builtins.attrNames section)) (builtins.attrValues (cfg.settings."extconfig.conf" or {}));
  in
    if names == null || realtime
    then null
    else lib.remove "general" (map lib.toLower names);
  # the classes queues and user profiles name, with the keys Asterisk takes in
  # any case (apps/app_queue.c:3533-3534, apps/confbridge/conf_config_parser.c:2637)
  references = file: keep: keys:
    lib.concatMap (
      section:
        lib.concatMap (
          key:
            map (class: {
              inherit class;
              text = "${file} [${section.name}] ${key} = ${class}";
            }) (builtins.filter builtins.isString (lib.toList section.${key}))
        ) (builtins.filter (key: builtins.elem (lib.toLower key) keys) (builtins.attrNames section))
    ) (builtins.filter keep (format.resolveInheritance (cfg.settings.${file} or {})).sections);
  missingClasses = map (reference: reference.text) (
    builtins.filter (reference: !(builtins.elem (lib.toLower reference.class) classes)) (
      references "queues.conf" (section: lib.toLower section.name != "general") ["musicclass" "music" "musiconhold"]
      ++ references "confbridge.conf" (section: lib.toLower (toString (section.type or "")) == "user") ["music_on_hold_class"]
    )
  );

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
      [
        {
          # res_musiconhold plays the default class instead, and warns only when a
          # call asks for the missing one (res/res_musiconhold.c:1013, local_ast_moh_start)
          assertion = classes == null || missingClasses == [];
          message = ''
            services.asterisk: queues.conf and confbridge.conf name music on hold classes that musiconhold.conf does not define, so callers would hear the default class:
              ${lib.concatStringsSep "\n  " missingClasses}
            Define them in services.asterisk.musicOnHold.classes, or name a class that is defined.
          '';
        }
      ]
      ++ lib.mapAttrsToList (name: c: {
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
