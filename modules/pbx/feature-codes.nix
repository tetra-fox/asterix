# services.asterix.featureCodes: do not disturb and call forwarding, which a
# phone sets for its own extension by dialling a code, in pbx-features, and
# the code that records a call, which recordings.nix applies. The state is in
# astdb, by extension: do not disturb as a custom device state, each
# forward's number under pbx-forward. numbering.nix routes the codes.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatStringsSep
    filter
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkOption
    nameValuePair
    optionalAttrs
    types
    ;

  cfg = config.services.asterix;
  codes = cfg.featureCodes;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (pbxLib) app;

  kinds = builtins.attrNames pbxLib.forwardSounds;

  code = example: description:
    mkOption {
      type = types.nullOr types.str;
      default = null;
      inherit example description;
    };

  forwardOptions = calls: on: off: {
    on = code on ''
      Number a phone dials to forward ${calls}, followed by the target,
      such as `${on}202`, or alone to be asked for it, ending with #. The
      target is an extension, or with {option}`services.asterix.outbound` a
      number outside with the prefix. Other numbers of the PBX, emergency
      numbers among them, are refused. A call forwarded outside presents
      {option}`services.asterix.outbound.callerId`. A call leaves an extension by a
      forward only once, so forwards that lead back to it ring it instead.
      Needs `off`.
    '';
    off = code off "Number a phone dials to stop the forward that `on` set.";
  };

  # the caller's PJSIP endpoint in PBX_EXTENSION, or to `refused` when it is
  # not an extension, such as a tie line
  caller = [
    (app "Answer" [])
    (app "Set" ["PBX_EXTENSION=\${CHANNEL(endpoint)}"])
    (app "GotoIf" [''$[!''${DIALPLAN_EXISTS(${pbxLib.objectContext "extension" "\${PBX_EXTENSION}"})}]?refused''])
  ];
  refused = [
    {
      app = "Playback";
      args = ["invalid"];
      label = "refused";
    }
    (app "Hangup" [])
  ];

  dnd = pbxLib.dndDevice "\${PBX_EXTENSION}";
  dndToggle =
    caller
    ++ [
      (app "GotoIf" [''$["''${DEVICE_STATE(${dnd})}" = "INUSE"]?off''])
      (app "Set" ["DEVICE_STATE(${dnd})=INUSE"])
      (app "Playback" ["do-not-disturb&activated"])
      (app "Hangup" [])
      {
        app = "Set";
        args = ["DEVICE_STATE(${dnd})=NOT_INUSE"];
        label = "off";
      }
      (app "Playback" ["do-not-disturb&de-activated"])
      (app "Hangup" [])
    ]
    ++ refused;

  # PBX_TARGET holds the number dialled after the code, if any
  forwardOn = kind:
    caller
    ++ [
      (app "GotoIf" [''$["''${PBX_TARGET}" != ""]?check''])
      (app "Read" ["PBX_TARGET" "vm-enter-num-to-call&vm-then-pound" "" "" 1 10])
      {
        app = "GotoIf";
        args = [''$[!(${pbxLib.forwardable "PBX_TARGET"})]?refused''];
        label = "check";
      }
      (app "Set" ["DB(${pbxLib.forwardKey "\${PBX_EXTENSION}" kind})=\${PBX_TARGET}"])
      (app "Playback" ["${pbxLib.forwardSounds.${kind}}&is-set-to"])
      (app "SayDigits" ["\${PBX_TARGET}"])
      (app "Hangup" [])
    ]
    ++ refused;

  forwardOff = kind:
    caller
    ++ [
      (app "Set" ["PBX_TARGET=\${DB_DELETE(${pbxLib.forwardKey "\${PBX_EXTENSION}" kind})}"])
      (app "Playback" ["${pbxLib.forwardSounds.${kind}}&de-activated"])
      (app "Hangup" [])
    ]
    ++ refused;

  forwarded = filter (kind: codes.forward.${kind}.on != null) kinds;
  # a forward set from a phone that the phone cannot stop, or the other way
  unpaired = filter (kind: (codes.forward.${kind}.on == null) != (codes.forward.${kind}.off == null)) kinds;
in {
  options.services.asterix.featureCodes = {
    record = mkOption {
      # Asterisk keeps 10 keys of a feature's sequence (features.nix)
      type = types.nullOr (types.strMatching "[0-9*#]{1,10}" // {description = "key sequence of 0-9, * and #, at most 10 keys";});
      default = null;
      example = "*1";
      description = ''
        Keys a phone presses during a call to record it, and again to stop,
        on a call not already recorded by
        {option}`services.asterix.recordings`. Phones and the external
        numbers of a ring group can use it, callers from outside cannot. On
        a call to a ring group or queue with a member that records, only
        the side that answers can, if it does not record. Keys
        that may start the code are held back, so with `*1` a `*` reaches the
        other side once the next key follows or a second has passed. It is
        `automixmon` of {file}`features.conf`.
      '';
    };
    dnd = code "*76" ''
      Number a phone dials to turn do not disturb on for its extension, and
      again to turn it off. Calls to the extension then go to its `busy`
      destination or busy forward without ringing it, unless every call is
      forwarded. Calls through a ring group, queue or page still ring it, as
      do emergency notifications. It also works as a busy lamp key, lit
      while do not disturb is on. The state is kept in astdb, not in the Nix
      configuration.
    '';
    forward = {
      always = forwardOptions "every call to its extension, which then does not ring" "*72" "*73";
      busy = forwardOptions "the calls to its extension that its `busy` destination would take, those while do not disturb is on among them" "*90" "*91";
      noAnswer = forwardOptions "the calls to its extension that its `noAnswer` destination would take" "*52" "*53";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      dialplan.contexts =
        optionalAttrs (codes.dnd != null || forwarded != []) {
          pbx-features = {
            comment = mkDefault "from services.asterix.featureCodes: what the codes change, for the extension that dials them";
            extensions =
              optionalAttrs (codes.dnd != null) {dnd = dndToggle;}
              // lib.listToAttrs (concatMap (kind: [
                  (nameValuePair "${kind}-on" (forwardOn kind))
                  (nameValuePair "${kind}-off" (forwardOff kind))
                ])
                forwarded);
          };
        }
        # a phone subscribes to the busy lamp of the do not disturb code in a
        # context of its own, where it shows its own extension's state
        // optionalAttrs (codes.dnd != null) (mapAttrs' (number: _:
          nameValuePair (pbxLib.objectContext "hints" number) {
            comment = mkDefault ''from services.asterix.featureCodes.dnd: busy lamps of extension "${number}"'';
            includes = ["pbx-internal"];
            hints.${codes.dnd} = mkDefault (pbxLib.dndDevice number);
          })
        cfg.extensions);

      pjsip.endpoints = mkIf (codes.dnd != null) (mapAttrs (number: _: {
          settings.subscribe_context = mkDefault (pbxLib.objectContext "hints" number);
        })
        cfg.extensions);
    };

    assertions = [
      {
        assertion = unpaired == [];
        message = "services.asterix.featureCodes.forward: ${concatStringsSep ", " unpaired} need both `on` and `off`, so a phone can stop the forward it set.";
      }
    ];
  };
}
