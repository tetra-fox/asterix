# Mailboxes render as `mailbox => PIN,full name,email,pager email,options`
# lines in their context section, with the PIN as a secret placeholder.
# Mailboxes are declarative: a PIN changed from the phone (VoiceMailMain) is
# not saved, because the generated configuration is read-only.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    attrValues
    concatStringsSep
    elemAt
    filter
    filterAttrs
    hasInfix
    isBool
    isString
    mapAttrs
    mapAttrsToList
    mkDefault
    mkIf
    mkMerge
    mkOption
    splitString
    types
    unique
    ;

  cfg = config.services.asterisk;
  vcfg = cfg.voicemail;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format secrets;

  secretOrString =
    types.either types.str format.types.secret
    // {
      description = "string or secret reference";
    };

  mailboxType = types.submodule (
    {name, ...}: let
      parts = splitString "@" name;
    in {
      options = {
        mailbox = mkOption {
          type = types.str;
          default = elemAt parts 0;
          defaultText = lib.literalMD "the part of the attribute name before `@`";
          description = "Mailbox number.";
        };
        context = mkOption {
          type = types.str;
          default =
            if builtins.length parts > 1
            then elemAt parts 1
            else "default";
          defaultText = lib.literalMD "the part of the attribute name after `@`, or `default`";
          description = "Voicemail context the mailbox belongs to.";
        };
        pin = mkOption {
          type = secretOrString;
          example = lib.literalExpression "config.lib.asterisk.secret config.sops.secrets.vm-101.path";
          description = ''
            Mailbox PIN, normally a secret reference. A plain string is stored in
            the world-readable Nix store and triggers a warning.
          '';
        };
        fullName = mkOption {
          type = types.str;
          default = elemAt parts 0;
          defaultText = lib.literalMD "the mailbox number";
          description = "Owner's name, used by the directory and in e-mails.";
        };
        email = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address notified of new messages (see `voicemail.email`).";
        };
        pagerEmail = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address receiving a short notification (pager e-mail).";
        };
        options = mkOption {
          type = types.attrsOf (
            types.oneOf [
              types.bool
              types.int
              types.str
            ]
          );
          default = {};
          example = {
            attach = true;
            delete = false;
            saycid = true;
          };
          description = "Per-mailbox options overriding `[general]` (`attach=yes|delete=no`).";
        };
      };
    }
  );

  optionValue = v:
    if isBool v
    then
      (
        if v
        then "yes"
        else "no"
      )
    else toString v;

  pinText = pin:
    if secrets.isSecret pin
    then secrets.placeholder pin
    else pin;

  mailboxLine = box: let
    fields = [
      (pinText box.pin)
      box.fullName
      (
        if box.email == null
        then ""
        else box.email
      )
      (
        if box.pagerEmail == null
        then ""
        else box.pagerEmail
      )
      (concatStringsSep "|" (mapAttrsToList (k: v: "${k}=${optionValue v}") box.options))
    ];
    # drop empty trailing fields
    trim = list:
      if list != [] && lib.last list == ""
      then trim (lib.init list)
      else list;
  in
    concatStringsSep "," (trim fields);

  mailboxes = attrValues vcfg.mailboxes;
  contexts = unique (map (box: box.context) mailboxes);

  badFields =
    filter (
      box:
        builtins.any (field: field != null && hasInfix "," field) [
          box.fullName
          box.email
          box.pagerEmail
        ]
    )
    mailboxes;

  # mailboxes referenced by typed PJSIP endpoints (MWI) that are not defined
  voicemailConf = cfg.settings."voicemail.conf" or {};
  missingMailboxes = lib.concatLists (
    mapAttrsToList (
      endpoint: e:
        map (ref: "pjsip.endpoints.${endpoint}.mailboxes: ${ref}") (
          filter (
            ref: let
              p = splitString "@" ref;
              box = elemAt p 0;
              context =
                if builtins.length p > 1
                then elemAt p 1
                else "default";
            in
              !(builtins.any (s: s.name == context && s ? ${box}) (attrValues voicemailConf))
          )
          e.mailboxes
        )
    )
    cfg.pjsip.endpoints
  );
in {
  options.services.asterisk.voicemail = {
    enable = mkOption {
      type = types.bool;
      default = vcfg.mailboxes != {};
      defaultText = lib.literalExpression "mailboxes != { }";
      description = "Load app_voicemail.so and render voicemail.conf.";
    };

    mailboxes = mkOption {
      type = types.attrsOf mailboxType;
      default = {};
      example = lib.literalExpression ''
        {
          "101" = {
            fullName = "Alice";
            email = "alice@example.org";
            pin = config.lib.asterisk.secret config.sops.secrets.vm-101.path;
          };
          "200@sales".pin = config.lib.asterisk.secret config.sops.secrets.vm-200.path;
        }
      '';
      description = ''
        Mailboxes, keyed by `mailbox` or `mailbox@context`. Leave messages with
        `VoiceMail(101@default)`, read them with `VoiceMailMain(101@default)`.
      '';
    };

    format = mkOption {
      type = types.nonEmptyListOf types.str;
      default = [
        "wav49"
        "wav"
      ];
      description = ''
        Formats messages are stored in; the first is used for e-mail
        attachments (`wav49` is a small GSM WAV that most clients play).
      '';
    };

    maxMessages = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum number of messages per folder (`maxmsg`).";
    };

    maxSeconds = mkOption {
      type = types.nullOr types.ints.positive;
      default = null;
      description = "Maximum message length in seconds (`maxsecs`).";
    };

    email = {
      command = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = lib.literalExpression ''"''${pkgs.msmtp}/bin/msmtp --read-envelope-from -t"'';
        description = ''
          Command that sends notification e-mails, reading the message on
          standard input (`mailcmd`); `null` sends no e-mail. It runs inside
          Asterisk's sandbox (NoNewPrivileges), so setuid or setgid sendmail
          wrappers such as {file}`/run/wrappers/bin/sendmail` do not work; use an
          SMTP client such as msmtp.
        '';
      };
      fromAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pbx@example.org";
        description = "Sender address of notification e-mails (`serveremail`).";
      };
      fromName = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Voicemail";
        description = "Sender name of notification e-mails (`fromstring`).";
      };
      attach = mkOption {
        type = types.bool;
        default = true;
        description = "Attach the recording to notification e-mails.";
      };
    };

    settings = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        minsecs = 2;
        maxlogins = 3;
      };
      description = "Additional keys of voicemail.conf's `[general]` section.";
    };
  };

  config = mkIf (cfg.enable && vcfg.enable) {
    services.asterisk = {
      modules.load = ["app_voicemail.so"];

      settings."voicemail.conf" = mkMerge (
        [
          {
            general = mkMerge [
              (mapAttrs (_: mkDefault) (
                filterAttrs (_: v: v != null) {
                  format = concatStringsSep "|" vcfg.format;
                  maxmsg = vcfg.maxMessages;
                  maxsecs = vcfg.maxSeconds;
                  mailcmd = vcfg.email.command;
                  serveremail = vcfg.email.fromAddress;
                  fromstring = vcfg.email.fromName;
                  attach = vcfg.email.attach;
                }
              ))
              vcfg.settings
            ];
          }
        ]
        ++ map (box: {
          ${box.context}.${box.mailbox} = mkDefault (mailboxLine box);
        })
        mailboxes
      );

      syntax."voicemail.conf".arrowSections = contexts;
    };

    assertions = [
      {
        assertion = badFields == [];
        message = "services.asterisk.voicemail.mailboxes: names and e-mail addresses cannot contain commas (${
          concatStringsSep ", " (map (box: "${box.mailbox}@${box.context}") badFields)
        }).";
      }
      {
        assertion = builtins.all (box: builtins.match "[A-Za-z0-9_*#+-]+" box.mailbox != null) mailboxes;
        message = "services.asterisk.voicemail.mailboxes: mailbox numbers may only contain letters, digits and _*#+-.";
      }
      {
        assertion = !(builtins.elem "general" contexts || builtins.elem "zonemessages" contexts);
        message = "services.asterisk.voicemail.mailboxes: `general` and `zonemessages` cannot be used as voicemail contexts.";
      }
      {
        assertion = missingMailboxes == [];
        message = ''
          services.asterisk: PJSIP endpoints reference voicemail boxes that are not defined:
            ${concatStringsSep "\n  " missingMailboxes}
        '';
      }
    ];

    warnings = map (
      box: "services.asterisk.voicemail.mailboxes.\"${box.mailbox}@${box.context}\".pin is a plain string, so it is stored world-readable in the Nix store; use config.lib.asterisk.secret instead."
    ) (filter (box: isString box.pin) mailboxes);
  };
}
