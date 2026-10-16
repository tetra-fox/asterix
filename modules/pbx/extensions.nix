# services.asterix.extensions: a phone (PJSIP endpoint), its mailbox and what
# happens to calls it does not take, in pbx-extension-<number>, and
# pbx-devices, which rings every device of an extension for queues and
# emergency notify
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

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit ((import ../../lib {inherit lib;}).format.types) secretOrString;

  extensionType = types.submodule ({name, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = name;
        defaultText = lib.literalMD "the extension number";
        description = ''
          Caller ID name, and the mailbox owner's name. At most 79 bytes,
          where a letter outside ASCII takes two to four. With `voicemail`,
          no comma: voicemail.conf ends the owner's name there.
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
              description = "Address notified of new messages (see {option}`services.asterix.voicemail.email`).";
            };
          };
        });
        default = null;
        description = "Mailbox `<number>@default` for the extension. A mailbox number cannot start with `*` or `#` (see {option}`services.asterisk.voicemail.mailboxes`).";
      };
      network = mkOption {
        type = types.nullOr types.str;
        default = null;
        defaultText = lib.literalMD "the only network of {option}`services.asterix.networks`";
        example = "voip";
        description = "Network of {option}`services.asterix.networks` the phone is on.";
      };
      maxContacts = mkOption {
        type = types.ints.positive;
        default = 1;
        description = ''
          Devices that can register as the extension at once, such as a desk
          phone and a softphone. One more replaces the registration that
          expires soonest.
        '';
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
          Call pickup groups. Dialling the pickup code (`pickupexten` of
          {file}`features.conf`, `*8` by default) answers a call ringing at
          an extension that shares a group.
        '';
      };
      record = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether to record every call the phone makes or answers, also
          through a ring group or queue ({option}`services.asterix.recordings`).
          A caller to a ring group or queue with such a member hears the
          notice even when another member answers.
        '';
      };
      noAnswer = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the unavailable greeting, or hangup without a mailbox";
        description = ''
          Where a call goes when nobody answers within `ringTime`, also
          during another call with call waiting, or when the phone is not
          registered.
        '';
      };
      busy = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the busy greeting, or hangup without a mailbox";
        description = ''
          Where a call goes when every device of the extension answers busy,
          as a phone in a call does without call waiting, and while do not
          disturb is on ({option}`services.asterix.featureCodes.dnd`).
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

  codes = cfg.featureCodes;
  forwards = kind: codes.forward.${kind}.on != null;
  anyForward = builtins.any forwards (builtins.attrNames pbxLib.forwardSounds);

  # steps to `forward`, with the target of forward `kind` of the extension in
  # PBX_FORWARD, when one is set that a forward may go to. A call that left
  # the extension by a forward before stays, so a loop of forwards ends.
  forwardIf = number: kind:
    lib.optionals (forwards kind) [
      (pbxLib.app "Set" ["PBX_FORWARD=\${DB(${pbxLib.forwardKey number kind})}"])
      (pbxLib.app "GotoIf" [''$["''${HASH(pbx-forwarded,${number})}" = "" & ${pbxLib.forwardable "PBX_FORWARD"}]?forward''])
    ];

  dialOptions = let
    options = pbxLib.recordOptions cfg {
      called = true;
      calling = true;
    };
  in
    optional (options != "") options;
  # a queue member's phone, whose caller the queue's own options cover
  memberOptions = pbxLib.recordOptions cfg {
    called = true;
    calling = false;
  };

  # the extensions a Local channel into pbx-devices rings
  rungThroughLocal = lib.unique (
    lib.concatMap (queue: queue.members) (builtins.attrValues cfg.queues)
    ++ lib.optionals (cfg.emergency != null) cfg.emergency.notify
  );
in {
  options.services.asterix = {
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
        every device registered as the extension. A call hangs up after 60
        seconds without RTP from the phone outside hold
        ({option}`services.asterisk.pjsip.endpoints.<name>.rtpTimeout`), so
        a phone that loses power does not leave its call running.
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
        message = "services.asterix.extensions: Asterisk keeps 79 bytes of a caller ID name and drops the rest, even in the middle of a letter, so these names are too long: ${
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
          aor.maxContacts = mkDefault e.maxContacts;
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
              comment = mkDefault ''from services.asterix.extensions."${number}"'';
              extensions.s =
                forwardIf number "always"
                ++ optional (codes.dnd != null) (
                  pbxLib.app "GotoIf" [''$["''${DEVICE_STATE(${pbxLib.dndDevice number})}" = "INUSE"]?busy'']
                )
                ++ pbxLib.recordCall cfg e.record false number
                ++ [
                  (pbxLib.app "Dial" (
                    [
                      (pbxLib.devices number)
                      e.ringTime
                    ]
                    ++ dialOptions
                  ))
                  (pbxLib.app "GotoIf" [''$["''${DIALSTATUS}" = "BUSY"]?busy''])
                ]
                # a parked call its phone does not take back comes in here
                # (parking.nix)
                ++ pbxLib.labelFirst "noanswer" (
                  forwardIf number "noAnswer"
                  ++ pbxLib.steps (
                    if e.noAnswer != null
                    then e.noAnswer
                    else fallback number e "unavailable"
                  )
                )
                ++ pbxLib.labelFirst "busy" (
                  forwardIf number "busy"
                  ++ pbxLib.steps (
                    if e.busy != null
                    then e.busy
                    else fallback number e "busy"
                  )
                )
                ++ lib.optionals anyForward [
                  {
                    app = "Set";
                    args = ["HASH(pbx-forwarded,${number})=1"];
                    label = "forward";
                  }
                  (pbxLib.app "Goto" ["pbx-forward" "\${PBX_FORWARD}" "1"])
                ];
            }
        )
        cfg.extensions
        // optionalAttrs (rungThroughLocal != []) {
          # Dial() has no timeout: the queue or Originate() that called the
          # Local channel hangs it up after its own
          pbx-devices = {
            comment = mkDefault "from services.asterix: every device of an extension, through a Local channel";
            extensions = lib.genAttrs rungThroughLocal (number: [
              (pbxLib.app "Dial" (
                [(pbxLib.devices number)]
                ++ lib.optionals (memberOptions != "") ["" memberOptions]
              ))
              (pbxLib.app "Hangup" [])
            ]);
          };
        };
    };
  };
}
