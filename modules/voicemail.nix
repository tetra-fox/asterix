# Mailboxes render as `mailbox => -PIN,full name,email,pager email,options`
# lines in their context section, with the PIN as a secret placeholder.
# Mailboxes are declarative: the `-` makes Asterisk refuse a PIN change from
# the phone, which it would use until the next reload but cannot save.
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
  inherit (import ./lib.nix {inherit lib;}) entryOf splitMailbox toSection voicemailLines voicemailMailboxes voicemailSectionKind;

  mailboxType = types.submodule (
    {name, ...}: let
      ref = splitMailbox name;
    in {
      options = {
        mailbox = mkOption {
          type = types.str;
          default = ref.box;
          defaultText = lib.literalMD "the part of the attribute name before `@`";
          description = "Mailbox number.";
        };
        context = mkOption {
          type = types.str;
          default = ref.context;
          defaultText = lib.literalMD "the part of the attribute name after `@`, or `default`";
          description = "Voicemail context the mailbox belongs to. Asterisk reads `general`, `zonemessages` and the context `aliasescontext` names, in any case, as no voicemail context.";
        };
        pin = mkOption {
          type = format.types.secretOrString;
          example = lib.literalExpression "config.lib.asterisk.secret config.sops.secrets.vm-101.path";
          description = ''
            Mailbox PIN, normally a secret reference. A plain string is stored in
            the world-readable Nix store and triggers a warning. It cannot
            contain a comma, which ends the PIN in the mailbox line. Callers
            cannot change it from the phone: it is rendered with Asterisk's `-`
            prefix for unchangeable PINs, so it cannot start with `-` itself.
            Asterisk keeps 79 bytes of the two, so the PIN can have 78.
          '';
        };
        fullName = mkOption {
          type = types.str;
          default = ref.box;
          defaultText = lib.literalMD "the mailbox number";
          description = "Owner's name, used by the directory and in e-mails. Asterisk keeps 79 bytes of it.";
        };
        email = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address notified of new messages (see `voicemail.email`).";
        };
        pagerEmail = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Address receiving a short notification (pager e-mail). Asterisk keeps 79 bytes of it.";
        };
        options = mkOption {
          # volgain takes a fraction
          type = types.attrsOf (
            types.oneOf [
              types.bool
              types.int
              types.float
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
    then secrets.placeholderOf pin
    else pin;

  mailboxLine = box:
    format.joinFields [
      "-${pinText box.pin}"
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

  mailboxes = attrValues vcfg.mailboxes;
  contexts = unique (map (box: box.context) mailboxes);

  # app_voicemail ignores a mailbox that starts with * (apps/app_voicemail.c
  # find_or_create), and Asterisk reads a line that starts with # as a directive
  validNumber = box: builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_*#+-]*" box.mailbox != null;
  badNumbers = filter (box: !validNumber box) mailboxes;

  badFields =
    filter (
      box:
        builtins.any (field: isString field && hasInfix "," field) [
          box.pin
          box.fullName
          box.email
          box.pagerEmail
        ]
    )
    mailboxes;

  # app_voicemail splits the options at every | and each option at its
  # first = (apps/app_voicemail.c apply_options)
  badOptions =
    filter (
      box:
        builtins.any (name: hasInfix "|" name || hasInfix "=" name) (builtins.attrNames box.options)
        || builtins.any (value: hasInfix "|" (optionValue value)) (attrValues box.options)
    )
    mailboxes;

  # the lines of the generated voicemail.conf with their section; app_voicemail
  # reads the ones of voicemail contexts as `mailbox => PIN,name,...`
  lines = voicemailLines (cfg.renderedFiles."voicemail.conf" or "");
  kindOf = voicemailSectionKind lines;
  mailboxLines = filter (mailbox: kindOf mailbox.section == "context") lines;

  # typed mailboxes in a section that is no voicemail context
  reservedContexts = filter (box: kindOf box.context != "context") mailboxes;

  # secrets in them, which app_voicemail splits at every comma
  mailboxLineSecrets = lib.concatMap (mailbox: secrets.fromText mailbox.line) mailboxLines;

  # a value app_voicemail keeps `bytes` of; `room` is what the secrets in it
  # may add to its other bytes, where `\;` is one byte
  limited = what: bytes: text: {
    inherit what bytes;
    refs = secrets.fromText text;
    room = bytes - builtins.stringLength (lib.replaceStrings ["\\;"] [";"] (lib.concatStrings (filter isString (builtins.split secrets.placeholderPattern text))));
  };

  # [general] keys app_voicemail copies into a buffer of fixed size, and the
  # bytes it keeps of them (apps/app_voicemail.c actual_load_config); mailcmd
  # has an assertion of its own
  generalBytes = {
    aliasescontext = 79;
    callback = 79;
    charset = 31;
    dialout = 79;
    emaildateformat = 31;
    exitcontext = 79;
    externnotify = 159;
    externpass = 127;
    externpasscheck = 127;
    externpassnotify = 127;
    fromstring = 99;
    listen-control-forward-key = 11;
    listen-control-pause-key = 11;
    listen-control-restart-key = 11;
    listen-control-reverse-key = 11;
    listen-control-stop-key = 11;
    locale = 19;
    pagerdateformat = 31;
    pagerfromstring = 99;
    serveremail = 79;
    tz = 79;
    userscontext = 79;
    vm-invalid-password = 79;
    vm-login = 79;
    vm-mismatch = 79;
    vm-newpassword = 79;
    vm-newuser = 79;
    vm-passchanged = 79;
    vm-password = 79;
    vm-pls-try-again = 79;
    vm-prepend-timeout = 79;
    vm-reenterpassword = 79;
  };
  # the same for the options of a mailbox (apply_option)
  optionBytes = {
    attachfmt = 19;
    callback = 79;
    dialout = 79;
    exitcontext = 79;
    fromstring = 99;
    language = 39;
    locale = 19;
    serveremail = 79;
    tz = 79;
  };
  # the same for the fields of a mailbox line (struct ast_vm_user, filled by
  # append_mailbox), where a typed PIN starts with its `-`
  mailboxFieldBytes = [
    {
      index = 0;
      name = "PIN";
      bytes = 79;
    }
    {
      index = 1;
      name = "name";
      bytes = 79;
    }
    {
      index = 3;
      name = "pager address";
      bytes = 79;
    }
  ];
  # cidinternalcontexts as app_voicemail reads it: split at each comma but one
  # at the end, without the blanks before each context; it keeps 63 bytes of
  # each of the first 10 (apps/app_voicemail.c actual_load_config)
  internalContexts = value: let
    parts = splitString "," value;
  in
    map (part: builtins.head (builtins.match "[ \t]*(.*)" part)) (
      if lib.last parts == ""
      then lib.init parts
      else parts
    );
  internalContextCount = 10;
  isInternalContexts = entry: lib.toLower entry.key == "cidinternalcontexts";
  limitedValues =
    lib.concatMap (
      line: let
        entry = entryOf line.line;
        fields = splitString "," entry.value;
        kind = kindOf line.section;
      in
        if entry == null || kind == "zonemessages" || kind == "aliases"
        then []
        else if kind == "general"
        then
          lib.optional (generalBytes ? ${lib.toLower entry.key}) (limited "[general] ${entry.key}" generalBytes.${lib.toLower entry.key} entry.value)
          ++ lib.optionals (isInternalContexts entry) (
            lib.imap1 (n: limited "context ${toString n} of [general] ${entry.key}" 63) (lib.take internalContextCount (internalContexts entry.value))
          )
        else
          lib.concatMap (
            field:
              lib.optional (builtins.length fields > field.index)
              (limited "${field.name} of ${entry.key}@${line.section}" field.bytes (builtins.elemAt fields field.index))
          )
          mailboxFieldBytes
          # the options are what follows the fourth comma, split at each | and
          # each at its first = (apply_options)
          ++ lib.concatMap (
            option: let
              parts = builtins.match "([^=]*)=(.*)" option;
              name = builtins.head parts;
            in
              lib.optional (parts != null && optionBytes ? ${lib.toLower name})
              (limited "option ${name} of ${entry.key}@${line.section}" optionBytes.${lib.toLower name} (builtins.elemAt parts 1))
          ) (splitString "|" (concatStringsSep "," (lib.drop 4 fields)))
    )
    lines;
  cutValues = filter (value: value.room < 0) limitedValues;
  ignoredInternalContexts =
    lib.concatMap (
      line: let
        entry = entryOf line.line;
      in
        lib.optionals (entry != null && kindOf line.section == "general" && isInternalContexts entry) (lib.drop internalContextCount (internalContexts entry.value))
    )
    lines;

  # mailboxes referenced by typed PJSIP endpoints (MWI) that are not defined,
  # other than refused ones, which their own assertion names
  voicemailConf = cfg.settings."voicemail.conf" or {};
  knownMailboxes = voicemailMailboxes cfg;
  # Asterisk compares the mailboxes of MWI exactly (main/stasis_state.c), and
  # app_voicemail sends a mailbox's MWI to its aliases too (queue_mwi_event)
  hasMailbox = mailbox: let
    ref = splitMailbox mailbox;
  in
    knownMailboxes == null || (knownMailboxes.contexts.${ref.context} or {}) ? ${ref.box} || knownMailboxes.aliases ? "${ref.box}@${ref.context}";
  refused =
    map (box: {
      box = box.mailbox;
      inherit (box) context;
    })
    (badNumbers ++ reservedContexts);
  missingMailboxes = lib.concatLists (
    mapAttrsToList (
      endpoint: e:
        map (ref: "pjsip.endpoints.${endpoint}.mailboxes: ${ref}") (
          filter (ref: !(hasMailbox ref) && !(builtins.elem (splitMailbox ref) refused)) e.mailboxes
        )
    )
    cfg.pjsip.endpoints
  );

  # mailboxes of the final voicemail.conf with an e-mail or pager address
  mailedBoxes = lib.concatLists (
    mapAttrsToList (
      _: section:
        lib.optionals (kindOf section.name == "context") (
          mapAttrsToList (box: _: "${box}@${section.name}") (
            filterAttrs (
              _: line: let
                fields = splitString "," line;
              in
                isString line && builtins.any (i: builtins.length fields > i && lib.trim (elemAt fields i) != "") [2 3]
            ) (removeAttrs section format.metaAttrs)
          )
        )
    )
    voicemailConf
  );
  # raw text or included files may set mailcmd
  mailCommandKnown = (cfg.extraConfig."voicemail.conf" or "") == "" && (cfg.includes."voicemail.conf" or []) == [];

  # [general] of the final voicemail.conf, where settings replace typed values
  general = voicemailConf.general or {};
  # Asterisk reads the first 10 formats and ignores the rest without a message
  # (AST_MAX_FORMATS in include/asterisk/file.h)
  storedFormats =
    if isString (general.format or null)
    then splitString "|" general.format
    else [];
  # app_voicemail copies mailcmd into a buffer of 160 bytes
  mailCommandLength =
    if isString (general.mailcmd or null)
    then builtins.stringLength general.mailcmd
    else 0;
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
        A mailbox number holds letters, digits and `_*#+-`, and starts with
        neither `*` nor `#`.
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
        Asterisk takes at most 10.
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
          standard input (`mailcmd`). Mailboxes with an e-mail address need
          it: without it Asterisk runs {file}`/usr/sbin/sendmail`, which NixOS
          does not have. It runs inside Asterisk's sandbox (NoNewPrivileges),
          so setuid or setgid sendmail wrappers such as
          {file}`/run/wrappers/bin/sendmail` do not work; use an SMTP client
          such as msmtp. Its password can be a credential
          ({option}`services.asterisk.credentials`), which the command reads
          from {file}`$CREDENTIALS_DIRECTORY/<name>`. Asterisk keeps 159
          characters of it; a longer command has to go into a script.
        '';
      };
      fromAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "pbx@example.org";
        description = "Sender address of notification e-mails (`serveremail`). Asterisk keeps 79 bytes of it.";
      };
      fromName = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "Voicemail";
        description = "Sender name of notification e-mails (`fromstring`). Asterisk keeps 99 bytes of it.";
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

  config = mkMerge [
    # settings."voicemail.conf" can hold mailboxes without the typed options
    (mkIf cfg.enable {
      services.asterisk = {
        fieldSecrets = mailboxLineSecrets;
        # a secret in several values has the least room of them
        secretMaxLengths = lib.zipAttrsWith (_: rooms: lib.foldl' lib.min (builtins.head rooms) rooms) (
          lib.concatMap (value: map (ref: {${secrets.placeholderOf ref} = value.room;}) value.refs) (filter (value: value.room >= 0) limitedValues)
        );
      };

      assertions = [
        {
          assertion = cutValues == [];
          message = ''
            services.asterisk: voicemail values that Asterisk would cut (the `-` before a typed mailbox's PIN counts):
              ${lib.concatMapStringsSep "\n  " (value: "${value.what}, to ${toString value.bytes} bytes") cutValues}
          '';
        }
        {
          assertion = ignoredInternalContexts == [];
          message = "services.asterisk.voicemail: Asterisk reads the first ${toString internalContextCount} contexts of cidinternalcontexts and ignores the rest: ${concatStringsSep ", " ignoredInternalContexts}.";
        }
      ];
    })

    (mkIf (cfg.enable && vcfg.enable) {
      services.asterisk = {
        modules.needed."services.asterisk.voicemail" = ["app_voicemail.so"];

        settings."voicemail.conf" = mkMerge (
          [
            {
              general = mkMerge [
                (toSection {
                  format = concatStringsSep "|" vcfg.format;
                  maxmsg = vcfg.maxMessages;
                  maxsecs = vcfg.maxSeconds;
                  mailcmd = vcfg.email.command;
                  serveremail = vcfg.email.fromAddress;
                  fromstring = vcfg.email.fromName;
                  attach = vcfg.email.attach;
                })
                vcfg.settings
              ];
            }
          ]
          # a mailbox the assertion below refuses is left out, so that the
          # assertion reports it and not the config format
          ++ map (box: {
            ${box.context}.${box.mailbox} = mkDefault (mailboxLine box);
          })
          (filter validNumber mailboxes)
        );

        syntax."voicemail.conf".arrowSections = contexts;
      };

      assertions = [
        {
          assertion = badFields == [];
          message = "services.asterisk.voicemail.mailboxes: PINs, names and e-mail addresses cannot contain commas (${
            concatStringsSep ", " (map (box: "${box.mailbox}@${box.context}") badFields)
          }).";
        }
        {
          assertion = badOptions == [];
          message = "services.asterisk.voicemail.mailboxes: option names cannot contain | or =, nor their values | (${
            concatStringsSep ", " (map (box: "${box.mailbox}@${box.context}") badOptions)
          }).";
        }
        {
          assertion = badNumbers == [];
          message = "services.asterisk.voicemail.mailboxes: mailbox numbers may only contain letters, digits and _*#+-, and not start with * or #: ${
            concatStringsSep ", " (map (box: "${box.mailbox}@${box.context}") badNumbers)
          }.";
        }
        {
          assertion = reservedContexts == [];
          message = "services.asterisk.voicemail.mailboxes: `general`, `zonemessages` and the context aliasescontext names are reserved, in any case: ${
            concatStringsSep ", " (map (box: "${box.mailbox}@${box.context}") reservedContexts)
          }.";
        }
        {
          assertion = !mailCommandKnown || mailedBoxes == [] || (voicemailConf.general.mailcmd or null) != null;
          message = "services.asterisk.voicemail: mailboxes with an e-mail address (${concatStringsSep ", " mailedBoxes}) need voicemail.email.command; without it Asterisk runs /usr/sbin/sendmail, which NixOS does not have.";
        }
        {
          assertion = mailCommandLength <= 159;
          message = "services.asterisk.voicemail.email.command: Asterisk cuts the e-mail command (mailcmd) after 159 characters, this one has ${toString mailCommandLength}; run a longer command from a script, such as one made with pkgs.writeShellScript.";
        }
        {
          assertion = builtins.length storedFormats <= 10;
          message = "services.asterisk.voicemail.format: Asterisk records at most 10 formats and ignores the rest (${concatStringsSep ", " storedFormats}).";
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
      ) (filter (box: !secrets.holdsSecret box.pin) mailboxes);
    })
  ];
}
