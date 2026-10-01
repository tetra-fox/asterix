# pbx.extensions: a phone (PJSIP endpoint), its mailbox and what happens to
# calls it does not take, in pbx-extension-<number>, and pbx-devices, which
# rings every device of an extension for queues and emergency notify
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    filterAttrs
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optional
    optionalAttrs
    types
    ;

  cfg = config.pbx;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit ((import ../../lib {inherit lib;}).format.types) secretOrString;

  extensionType = types.submodule ({name, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        defaultText = lib.literalMD "the extension number";
        description = ''
          Name shown as caller ID, and the mailbox owner's name. At most 79
          bytes, which Asterisk keeps of a caller ID name; a letter outside
          ASCII takes two to four. With `voicemail`, no comma, which ends the
          owner's name in voicemail.conf.
        '';
      };
      password = mkOption {
        type = secretOrString;
        example = lib.literalExpression "config.lib.asterisk.secret config.sops.secrets.sip-201.path";
        description = "SIP password of the phone, normally a secret reference.";
      };
      voicemail = mkOption {
        type = types.nullOr (types.submodule {
          options = {
            pin = mkOption {
              type = secretOrString;
              description = "Mailbox PIN, normally a secret reference.";
            };
            email = mkOption {
              type = types.nullOr types.str;
              default = null;
              description = "Address notified of new messages (see {option}`services.asterisk.voicemail.email`).";
            };
          };
        });
        default = null;
        description = "Mailbox `<number>@default` for the extension, so the number is a mailbox number too, which cannot start with `*` or `#` (see {option}`services.asterisk.voicemail.mailboxes`).";
      };
      ringTime = mkOption {
        type = types.ints.positive;
        default = 20;
        description = "Seconds the phone rings before the call goes to `noAnswer`.";
      };
      pickupGroups = mkOption {
        # Asterisk splits the groups at commas and strips the ends of each
        # (main/channel.c ast_get_namedgroups)
        type = types.listOf (types.strMatching "[^,[:space:]]([^,]*[^,[:space:]])?");
        default = [];
        example = ["front"];
        description = ''
          Call pickup groups. A phone takes a call ringing at an extension
          that shares a group with it by dialling the pickup code, `*8`
          unless `pickupexten` of {file}`features.conf` says otherwise. They
          set the endpoint's `named_call_group` and `named_pickup_group`.
        '';
      };
      noAnswer = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the unavailable greeting, or hangup without a mailbox";
        description = ''
          Where a call goes when nobody answers within `ringTime`, also when
          the phone rings while in another call (call waiting), or when the
          phone is not registered.
        '';
      };
      busy = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the busy greeting, or hangup without a mailbox";
        description = ''
          Where a call goes when the phone answers busy, as a phone in a call
          does without call waiting, or when every device of the extension
          does.
        '';
      };
    };
  });

  fallback = number: e: greeting:
    if e.voicemail != null
    then {
      voicemail = {
        mailbox = number;
        inherit greeting;
      };
    }
    else {hangup = true;};

  # an endpoint's caller ID name is read into 80 bytes, and the rest cut off
  # (res/res_pjsip/pjsip_configuration.c, caller_id_handler)
  longNames = filterAttrs (_: e: builtins.stringLength e.name > 79) cfg.extensions;

  # the extensions a Local channel into pbx-devices rings
  rungThroughLocal = lib.unique (
    lib.concatMap (queue: queue.members) (builtins.attrValues cfg.queues)
    ++ lib.optionals (cfg.emergency != null) cfg.emergency.notify
  );
in {
  options.pbx = {
    extensions = mkOption {
      type = types.attrsOf extensionType;
      default = {};
      example = lib.literalExpression ''
        {
          "201" = {
            name = "Reception";
            password = config.lib.asterisk.secret config.sops.secrets.sip-201.path;
            voicemail.pin = config.lib.asterisk.secret config.sops.secrets.vm-201.path;
          };
        }
      '';
      description = ''
        Phones, keyed by the number that reaches them. Each is a PJSIP
        endpoint named like its number, which dials from `pbx-internal`, with
        a hint for busy lamps and, with `voicemail`, a mailbox. Calls ring
        every device registered as the extension, as many as
        {option}`services.asterisk.pjsip.endpoints.<name>.aor.maxContacts`
        allows (one by default). Asterisk hangs up a call of the extension
        after 60 seconds without RTP from its phone, outside hold
        ({option}`services.asterisk.pjsip.endpoints.<name>.rtpTimeout`), so
        the call of a phone that loses power, which sends no BYE, ends
        instead of running on.
      '';
    };

    voicemailMenu = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "*97";
      description = "Number phones dial to listen to the messages of their own mailbox.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = longNames == {};
        message = "pbx.extensions: Asterisk keeps 79 bytes of a caller ID name and drops the rest, even in the middle of a letter, so these names are too long: ${
          lib.concatMapStringsSep ", " (number: ''"${number}" (${toString (builtins.stringLength longNames.${number}.name)} bytes)'') (builtins.attrNames longNames)
        }.";
      }
    ];

    services.asterisk = {
      pjsip.endpoints =
        mapAttrs (number: e: {
          context = mkDefault "pbx-internal";
          # Asterisk drops each \ of a quoted name and keeps the character after
          # it (main/callerid.c ast_callerid_parse)
          callerId = mkDefault ''"${lib.escape ["\\" "\""] e.name}" <${number}>'';
          auth.password = mkDefault e.password;
          rtpTimeout = mkDefault 60;
          mailboxes = optional (e.voicemail != null) "${number}@default";
          settings = mkIf (e.pickupGroups != []) (let
            groups = mkDefault (lib.concatStringsSep "," e.pickupGroups);
          in {
            named_call_group = groups;
            named_pickup_group = groups;
          });
        })
        cfg.extensions;

      # the voicemail menu's VoiceMailMain needs app_voicemail, which the core
      # loads only once a mailbox exists
      voicemail.enable = mkIf (cfg.voicemailMenu != null) (mkDefault true);

      voicemail.mailboxes =
        mapAttrs (_: e: {
          fullName = mkDefault e.name;
          pin = mkDefault e.voicemail.pin;
          email = mkDefault e.voicemail.email;
        })
        (filterAttrs (_: e: e.voicemail != null) cfg.extensions);

      dialplan.contexts =
        mapAttrs' (
          number: e:
            nameValuePair (pbxLib.objectContext "extension" number) {
              comment = mkDefault ''from pbx.extensions."${number}"'';
              extensions.s =
                [
                  (pbxLib.app "Dial" [
                    (pbxLib.devices number)
                    e.ringTime
                  ])
                  (pbxLib.app "GotoIf" [''$["''${DIALSTATUS}" = "BUSY"]?busy''])
                ]
                ++ pbxLib.steps (
                  if e.noAnswer != null
                  then e.noAnswer
                  else fallback number e "unavailable"
                )
                ++ pbxLib.labelled "busy" (
                  if e.busy != null
                  then e.busy
                  else fallback number e "busy"
                );
            }
        )
        cfg.extensions
        // optionalAttrs (rungThroughLocal != []) {
          # Dial() has no timeout: the queue or Originate() that called the
          # Local channel hangs it up after its own
          pbx-devices = {
            comment = mkDefault "from pbx: every device of an extension, through a Local channel";
            extensions = lib.genAttrs rungThroughLocal (number: [
              (pbxLib.app "Dial" [(pbxLib.devices number)])
              (pbxLib.app "Hangup" [])
            ]);
          };
        };
    };
  };
}
