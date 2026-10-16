# services.asterix.voicemail: mailboxes of no extension, in voicemail context
# default with the extensions' own, and the voicemail.conf limits and e-mail
# settings a PBX sets
{
  config,
  lib,
  options,
  ...
}: let
  inherit
    (lib)
    filterAttrs
    mapAttrs
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterix;
  coreOptions = options.services.asterisk.voicemail;
  inherit ((import ../../lib {inherit lib;}).format.types) secretOrString;

  # a layer option with the type, default and text of the core option it
  # writes to
  sameAs = option:
    mkOption (builtins.intersectAttrs {
        type = null;
        default = null;
        example = null;
        description = null;
      }
      option);
  emailOptions = ["command" "fromAddress" "fromName" "attach"];

  mailboxType = types.submodule ({name, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        defaultText = lib.literalMD "the mailbox number";
        description = "Owner's name, for the directory and e-mails. No comma: voicemail.conf ends the name there.";
      };
      pin = mkOption {
        type = secretOrString;
        example = lib.literalExpression "config.lib.asterisk.secret config.sops.secrets.vm-200.path";
        description = "Mailbox PIN, normally a secret reference.";
      };
      email = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Address notified of new messages (see {option}`services.asterix.voicemail.email`).";
      };
    };
  });

  # an extension with a mailbox owns <number>@default
  extensionBoxes = filterAttrs (_: e: e.voicemail != null) cfg.extensions;
  clashes = builtins.filter (box: extensionBoxes ? ${box}) (builtins.attrNames cfg.voicemail.mailboxes);
in {
  options.services.asterix.voicemail = {
    mailboxes = mkOption {
      type = types.attrsOf mailboxType;
      default = {};
      example = lib.literalExpression ''
        {
          "200" = {
            name = "Sales";
            pin = config.lib.asterisk.secret config.sops.secrets.vm-200.path;
          };
        }
      '';
      description = ''
        Mailboxes of no extension, such as a team's, keyed by number. Like
        an extension's, each is `<number>@default`, so a `voicemail`
        destination reaches it by number. A number holds letters, digits and
        `_*#+-`, does not start with `*` or `#`, and is not that of an
        extension with `voicemail`.
      '';
    };
    maxMessages = sameAs coreOptions.maxMessages;
    maxSeconds = sameAs coreOptions.maxSeconds;
    email = lib.genAttrs emailOptions (name: sameAs coreOptions.email.${name});
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = clashes == [];
        message = "services.asterix.voicemail.mailboxes: these numbers are the mailboxes of extensions with voicemail: ${lib.concatStringsSep ", " clashes}.";
      }
    ];

    services.asterisk.voicemail = {
      # a clashing mailbox is left out, so that the assertion reports it and
      # not the merge of its fields with the extension's
      mailboxes = mapAttrs (box: m: {
        mailbox = box;
        context = "default";
        fullName = mkDefault m.name;
        pin = mkDefault m.pin;
        email = mkDefault m.email;
      }) (removeAttrs cfg.voicemail.mailboxes clashes);
      maxMessages = mkDefault cfg.voicemail.maxMessages;
      maxSeconds = mkDefault cfg.voicemail.maxSeconds;
      email = lib.genAttrs emailOptions (name: mkDefault cfg.voicemail.email.${name});
    };
  };
}
