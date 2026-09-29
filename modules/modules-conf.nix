# Autoload is off and an explicit module list is loaded. The options put the
# modules they need in `needed`, which is loaded even without the default
# list and which noload cannot remove. Asterisk does not load a module's
# dependencies by itself, so the default list includes them.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    mkIf
    mkOption
    types
    unique
    ;

  cfg = config.services.asterisk;

  baseModules = [
    # object storage used by res_pjsip and others
    "res_sorcery_astdb.so"
    "res_sorcery_config.so"
    "res_sorcery_memory.so"
    "res_sorcery_memory_cache.so"
    # media
    "res_timing_timerfd.so"
    "res_rtp_asterisk.so"
    "res_srtp.so"
    "res_musiconhold.so"
    "res_format_attr_opus.so"
    "chan_bridge_media.so"
    "bridge_simple.so"
    "bridge_native_rtp.so"
    "bridge_softmix.so"
    "bridge_holding.so"
    "bridge_builtin_features.so"
    "bridge_builtin_interval_features.so"
    "codec_ulaw.so"
    "codec_alaw.so"
    "codec_a_mu.so"
    "codec_g722.so"
    "codec_gsm.so"
    "codec_resample.so"
    "codec_opus_open_source.so"
    "format_gsm.so"
    "format_pcm.so"
    "format_sln.so"
    "format_wav.so"
    "format_wav_gsm.so"
    # dialplan
    "pbx_config.so"
    "res_clioriginate.so"
    "app_chanisavail.so"
    "app_confbridge.so"
    "app_dial.so"
    "app_directed_pickup.so"
    "app_echo.so"
    "app_exec.so"
    "app_milliwatt.so"
    "app_mixmonitor.so"
    "app_originate.so"
    "app_page.so"
    "app_playback.so"
    "app_playtones.so"
    "app_read.so"
    "app_readexten.so"
    "app_record.so"
    "app_sayunixtime.so"
    "app_senddtmf.so"
    "app_softhangup.so"
    "app_stack.so"
    "app_transfer.so"
    "app_userevent.so"
    "app_verbose.so"
    "app_waituntil.so"
    "app_while.so"
    "func_callerid.so"
    "func_cdr.so"
    "func_channel.so"
    "func_cut.so"
    "func_db.so"
    "func_devstate.so"
    "func_dialplan.so"
    "func_env.so"
    "func_extstate.so"
    "func_global.so"
    "func_groupcount.so"
    "func_hangupcause.so"
    "func_logic.so"
    "func_math.so"
    "func_rand.so"
    "func_sprintf.so"
    "func_strings.so"
    "func_timeout.so"
    "func_uri.so"
    "func_uuid.so"
  ];

  pjsipModules = [
    "res_pjproject.so"
    "res_pjsip.so"
    "res_pjsip_session.so"
    "chan_pjsip.so"
    "res_pjsip_acl.so"
    "res_pjsip_authenticator_digest.so"
    "res_pjsip_caller_id.so"
    "res_pjsip_dialog_info_body_generator.so"
    "res_pjsip_diversion.so"
    "res_pjsip_dlg_options.so"
    "res_pjsip_dtmf_info.so"
    "res_pjsip_empty_info.so"
    "res_pjsip_endpoint_identifier_ip.so"
    "res_pjsip_endpoint_identifier_user.so"
    "res_pjsip_exten_state.so"
    "res_pjsip_header_funcs.so"
    "res_pjsip_logger.so"
    "res_pjsip_messaging.so"
    "res_pjsip_mwi.so"
    "res_pjsip_mwi_body_generator.so"
    "res_pjsip_nat.so"
    "res_pjsip_notify.so"
    "res_pjsip_one_touch_record_info.so"
    "res_pjsip_outbound_authenticator_digest.so"
    "res_pjsip_outbound_publish.so"
    "res_pjsip_outbound_registration.so"
    "res_pjsip_path.so"
    "res_pjsip_pidf_body_generator.so"
    "res_pjsip_pidf_digium_body_supplement.so"
    "res_pjsip_pidf_eyebeam_body_supplement.so"
    "res_pjsip_pubsub.so"
    "res_pjsip_refer.so"
    "res_pjsip_registrar.so"
    "res_pjsip_rfc3326.so"
    "res_pjsip_sdp_rtp.so"
    "res_pjsip_xpidf_body_generator.so"
    "func_pjsip_aor.so"
    "func_pjsip_contact.so"
    "func_pjsip_endpoint.so"
  ];

  # Removed in Asterisk 21 and deprecated before; never load it.
  legacyModules = ["chan_sip.so"];

  normalize = name:
    if lib.hasSuffix ".so" name
    then name
    else "${name}.so";

  moduleListType = types.listOf types.str;

  # Every module that will be loaded must exist in the package; this catches
  # typos at build time instead of as a log line at runtime.
  loadedModules = lib.subtractLists (map normalize cfg.modules.noload) (
    unique (map normalize (cfg.modules.load ++ cfg.modules.preload))
  );

  # Asterisk drops a module in noload without a message, and the option that
  # needs it then does nothing
  removedNeeds = lib.concatLists (
    lib.mapAttrsToList (what: modules: let
      removed = builtins.filter (module: builtins.elem module (map normalize cfg.modules.noload)) (map normalize modules);
    in
      lib.optional (removed != []) "${lib.concatStringsSep ", " removed} for ${what}")
    cfg.modules.needed
  );
  modulesCheck = pkgs.runCommand "asterisk-modules-check" {} ''
    missing=0
    for module in ${lib.escapeShellArgs loadedModules}; do
      if [ ! -e "${cfg.package}/lib/asterisk/modules/$module" ]; then
        echo "services.asterisk.modules: $module does not exist in ${cfg.package.name}" >&2
        missing=1
      fi
    done
    [ "$missing" = 0 ] && touch "$out"
  '';
in {
  options.services.asterisk.modules = {
    autoload = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Load every module Asterisk finds, except the ones in
        {option}`services.asterisk.modules.noload`. Off by default:
        only the modules in {option}`services.asterisk.modules.load`
        are loaded.
      '';
    };

    defaultModules = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Add the module's lean default set to
        {option}`services.asterisk.modules.load`: PJSIP, RTP,
        SRTP, bridging, the ulaw/alaw/G.722/GSM/Opus codecs, sound file
        formats, music on hold, the dialplan and its common applications and
        functions. Remove single modules with
        {option}`services.asterisk.modules.noload`. Without the set, the
        options still load the modules they need, such as chan_pjsip.so for
        PJSIP endpoints, but not the modules those depend on.
      '';
    };

    load = mkOption {
      type = moduleListType;
      default = [];
      example = [
        "app_system.so"
        "cdr_csv.so"
      ];
      description = ''
        Modules to load (`load =>`). Typed options add the modules they need.
        Asterisk does not resolve dependencies when autoload is off, so list
        them too. Names without `.so` get it appended.
      '';
    };

    noload = mkOption {
      type = moduleListType;
      default = [];
      example = ["res_pjsip_messaging.so"];
      description = ''
        Modules never to load (`noload =>`), taking precedence over
        {option}`services.asterisk.modules.load`. A module the
        configuration needs, such as app_voicemail.so with voicemail
        mailboxes or res_pjsip_acl.so with PJSIP ACLs, cannot be listed.
        `chan_sip.so` is always excluded.
      '';
    };

    needed = mkOption {
      type = types.attrsOf moduleListType;
      default = {};
      internal = true;
      description = ''
        Modules the configuration needs, keyed by what needs them. They are
        loaded whatever `defaultModules` says, and `noload` cannot remove
        them.
      '';
    };

    preload = mkOption {
      type = moduleListType;
      default = [];
      example = ["res_odbc.so"];
      description = "Modules loaded before the core initializes (`preload =>`), such as realtime drivers.";
    };
  };

  config = mkIf cfg.enable {
    services.asterisk = {
      modules.load = lib.mkMerge [
        (mkIf cfg.modules.defaultModules (baseModules ++ pjsipModules))
        (lib.concatLists (lib.attrValues cfg.modules.needed))
      ];

      settings."modules.conf".modules = {
        inherit (cfg.modules) autoload;
        preload = unique (map normalize cfg.modules.preload);
        load = unique (map normalize cfg.modules.load);
        noload = unique (legacyModules ++ map normalize cfg.modules.noload);
      };
    };

    system.checks = [modulesCheck];

    assertions = [
      {
        assertion = !(builtins.any (m: builtins.elem (normalize m) legacyModules) cfg.modules.load);
        message = "services.asterisk.modules.load: chan_sip.so is not supported; use PJSIP (chan_pjsip.so).";
      }
      {
        assertion = removedNeeds == [];
        message = ''
          services.asterisk.modules.noload removes modules the configuration needs:
            ${lib.concatStringsSep "\n  " removedNeeds}
        '';
      }
    ];
  };
}
