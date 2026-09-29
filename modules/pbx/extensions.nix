# pbx.extensions: a phone (PJSIP endpoint), its mailbox and what happens to
# calls it does not take, in pbx-extension-<number>
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
        description = "Name shown as caller ID, and the mailbox owner's name.";
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
        description = "Mailbox `<number>@default` for the extension.";
      };
      ringTime = mkOption {
        type = types.ints.positive;
        default = 20;
        description = "Seconds the phone rings before the call goes to `noAnswer`.";
      };
      noAnswer = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the unavailable greeting, or hangup without a mailbox";
        description = "Where a call goes when nobody answers or the phone is not registered.";
      };
      busy = mkOption {
        type = types.nullOr pbxLib.destination;
        default = null;
        defaultText = lib.literalMD "the mailbox with the busy greeting, or hangup without a mailbox";
        description = "Where a call goes when the phone is busy.";
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
        a hint for busy lamps and, with `voicemail`, a mailbox.
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
    services.asterisk = {
      pjsip.endpoints =
        mapAttrs (number: e: {
          context = mkDefault "pbx-internal";
          callerId = mkDefault ''"${e.name}" <${number}>'';
          auth.password = mkDefault e.password;
          mailboxes = optional (e.voicemail != null) "${number}@default";
        })
        cfg.extensions;

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
                    "PJSIP/${number}"
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
        cfg.extensions;
    };
  };
}
