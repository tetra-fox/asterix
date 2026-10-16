# services.asterix.recordings: call recording, in pbx-record. Before a call
# rings anything, its `call` routine decides on the caller's channel whether
# the call is recorded, and Dial's U() starts MixMonitor on the channel that
# answers, through its `s`. featureCodes.record is automixmon of
# features.conf, which the Dial options of pbxLib.recordOptions enable.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkDefault
    mkIf
    mkMerge
    mkOption
    optional
    optionals
    types
    ;

  cfg = config.services.asterix;
  rcfg = cfg.recordings;
  code = cfg.featureCodes.record;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (pbxLib) app;

  records = pbxLib.recordsCalls cfg;
  # MixMonitor and automixmon take a name without a directory as one in it
  directory = "${config.services.asterisk.paths.spool}/monitor";

  # the notice's sound, in a list that is empty without one
  notice = optional (rcfg.notice != null) (pbxLib.promptSound "recording" "notice" rcfg.notice);
  playNotice = optional (notice != []) (app "Playback" notice);
  # the date and time of day, as file names start
  now = "\${STRFTIME(\${EPOCH},,%Y%m%d-%H%M%S)}";

  # PBX_RECORD is empty until something decides: `1` records the call,
  # `answer` also plays the notice to whoever answers, and `member` records
  # it only when a phone that records its own calls answers
  decided = ''"''${PBX_RECORDING}" != "" | "''${PBX_RECORD}" = "1" | "''${PBX_RECORD}" = "answer"'';
  call =
    [
      # a caller's number is theirs to choose, so only these characters of it
      # reach a file name
      (app "Set" ["__PBX_FROM=\${FILTER(0-9*#+,\${CALLERID(num)})}"])
      (app "Set" ["__PBX_TO=\${ARG3}"])
    ]
    ++ optionals (code != null) (
      [
        (app "Set" ["__TOUCH_MIXMONITOR_PREFIX=${now}-\${PBX_FROM}-\${ARG3}"])
        (app "Set" ["__TOUCH_MIXMONITOR=\${UNIQUEID}"])
      ]
      # automixmon plays it to both sides once it records
      ++ map (sound: app "Set" ["__TOUCH_MIXMONITOR_MESSAGE_START=${sound}"]) notice
    )
    ++ optionals records [
      (app "GotoIf" ["$[${decided}]?done"])
      (app "GotoIf" [''$["''${PBX_RECORDS}" = "1"]?answer''])
      (app "GotoIf" ["$[\${ARG1}]?record"])
      (app "GotoIf" [''$[''${ARG2} & "''${PBX_RECORD}" = ""]?member''])
    ]
    ++ [
      {
        app = "Return";
        args = [];
        label = "done";
      }
    ]
    ++ optionals records (
      [
        {
          app = "Set";
          args = ["__PBX_RECORD=answer"];
          label = "answer";
        }
        (app "Return" [])
      ]
      ++ pbxLib.labelFirst "record" (
        # a caller who heard the notice for a member does not hear it again
        optionals (notice != []) ([(app "GotoIf" [''$["''${PBX_RECORD}" != ""]?recorded''])] ++ playNotice)
        ++ pbxLib.labelFirst "recorded" [
          (app "Set" ["__PBX_RECORD=1"])
          (app "Return" [])
        ]
      )
      ++ pbxLib.labelFirst "member" (
        playNotice
        ++ [
          (app "Set" ["__PBX_RECORD=member"])
          (app "Return" [])
        ]
      )
    );

  # PBX_RECORDING, which every channel dialled from this one inherits, names
  # the file, so a call that goes on from a channel that records is not
  # recorded twice
  answered =
    [
      (app "GotoIf" [''$["''${PBX_RECORDING}" != ""]?done''])
      (app "GotoIf" [''$["''${PBX_RECORD}" = "1" | "''${PBX_RECORD}" = "answer" | "''${PBX_RECORDS}" = "1"]?:done''])
    ]
    ++ optionals (notice != []) ([(app "GotoIf" [''$["''${PBX_RECORD}" != "answer"]?start''])] ++ playNotice)
    ++ pbxLib.labelFirst "start" [
      (app "Set" ["__PBX_RECORDING=${now}-\${PBX_FROM}-\${PBX_TO}-\${UNIQUEID}.wav"])
      # b: only while the channel is in a call, not while it is on its own
      (app "MixMonitor" ["\${PBX_RECORDING}" "b"])
    ]
    ++ [
      {
        app = "Return";
        args = [];
        label = "done";
      }
    ];
in {
  options.services.asterix.recordings = mkOption {
    type = types.submodule {
      options = {
        keepDays = mkOption {
          type = types.nullOr types.ints.positive;
          default = null;
          example = 90;
          description = "Days a recording is kept. A timer deletes older ones once a day. Without it, recordings are kept until deleted by hand.";
        };
        notice = mkOption {
          type = types.nullOr pbxLib.prompt;
          default = null;
          example = {text = "This call may be recorded.";};
          description = ''
            What is played before a call is recorded. There is none by
            default, as the laws on recording calls differ. The caller hears
            it before anything rings, answered first, when what they called
            records: an extension, ring group, queue or inbound number with
            `record`, or a ring group or queue with a member that records.
            On a call that a phone with `record` makes, whoever answers hears
            it instead, before the recording starts. A recording started with
            {option}`services.asterix.featureCodes.record` plays it to both
            sides as it starts.
          '';
        };
      };
    };
    default = {};
    description = ''
      Call recording, which `record` of
      {option}`services.asterix.extensions`,
      {option}`services.asterix.inbound`,
      {option}`services.asterix.ringGroups` and
      {option}`services.asterix.queues` turns on, and
      {option}`services.asterix.featureCodes.record` during a call.

      A call is recorded from when it is answered, by a phone, a number
      outside or a queue member, into one WAV file of both sides in
      {file}`/var/lib/asterisk/spool/monitor`, which only root and the
      asterisk user can read. A file is named
      `<date>-<time>-<from>-<to>-<id>.wav`: the date and time it was
      answered, the caller's number with only digits, `*`, `#` and `+` kept,
      the extension, ring group, queue or number called, and the unique ID
      of the channel that answered. One started with the code is named
      `<date>-<time>-<from>-<to>-<seconds>-<id>.wav`, with the date and time
      the call started ringing, the Unix time the code was pressed and the
      unique ID of the caller's channel.

      Each call is recorded once, however many objects along its way
      record, into one file on the side that answered. When the caller
      transfers it, it stays in that file. When the side that answered
      transfers it, that file ends, and where the call goes it is recorded
      again if it would be. Voicemail, conferences, pages and emergency
      calls are not recorded.
    '';
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf (records || code != null) {
      services.asterisk.dialplan.contexts.pbx-record = {
        comment = mkDefault "from services.asterix.recordings: whether a call is recorded, decided before it rings, and its recording, started when it is answered";
        extensions =
          {inherit call;}
          // lib.optionalAttrs records {s = answered;};
      };

      services.asterisk.sounds.packages = pbxLib.promptSounds pkgs "recording" (lib.optionalAttrs (rcfg.notice != null) {notice.prompt = rcfg.notice;});

      # a phone's own variables, on the calls it makes and those it answers
      services.asterisk.pjsip.endpoints = lib.mapAttrs (_: e: {
        settings.set_var = optional e.record "PBX_RECORDS=1" ++ optional (code != null) "PBX_PHONE=1";
      }) (lib.filterAttrs (_: e: e.record || code != null) cfg.extensions);
    })

    (mkIf records {
      services.asterisk.modules.needed."services.asterix.recordings" = ["app_mixmonitor.so"];
    })

    (mkIf (code != null) {
      services.asterisk.features.featureMap.automixmon = code;
    })

    (mkIf (rcfg.keepDays != null) {
      systemd.services.asterisk-recordings-expire = {
        description = "Delete call recordings older than ${toString rcfg.keepDays} days";
        # Asterisk creates the directory as it starts
        unitConfig.ConditionPathIsDirectory = directory;
        serviceConfig = {
          Type = "oneshot";
          User = "asterisk";
          Group = "asterisk";
          ExecStart = "${pkgs.findutils}/bin/find ${directory} -type f -mmin +${toString (rcfg.keepDays * 24 * 60)} -delete";
          ReadWritePaths = [directory];
          PrivateNetwork = true;
          CapabilityBoundingSet = "";
          NoNewPrivileges = true;
          PrivateDevices = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelTunables = true;
          ProtectKernelModules = true;
          ProtectControlGroups = true;
          RestrictAddressFamilies = "none";
          SystemCallArchitectures = "native";
          SystemCallFilter = [
            "@system-service"
            "~@privileged"
          ];
        };
      };
      systemd.timers.asterisk-recordings-expire = {
        wantedBy = ["timers.target"];
        timerConfig = {
          OnCalendar = "daily";
          Persistent = true;
        };
      };
    })

    {
      assertions = [
        {
          assertion = rcfg.notice == null || !(pbxLib.silentPrompt rcfg.notice);
          message = ''services.asterix.recordings.notice: flite speaks the text as silence, since it holds no ASCII letter or digit. Write the text in English, or play a sound file with notice.sound.'';
        }
      ];
    }
  ]);
}
