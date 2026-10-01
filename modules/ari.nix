# http.conf and ari.conf. The HTTP server is also what WebSocket SIP transports
# (`ws`, `wss`) run on.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optionals
    types
    ;

  cfg = config.services.asterisk;
  hcfg = cfg.http;
  acfg = cfg.ari;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;
  inherit (import ./lib.nix {inherit lib;}) toSection;

  credentialPath = kind: "${cfg.paths.credentials}/http-tls-${kind}";

  # res_ari links against res_websocket_client since 20.15.0, 21.10.0 and
  # 22.5.0. With autoload off Asterisk cannot resolve that on its own: the
  # dependency is only known after res_ari.so has been loaded.
  version = cfg.package.version;
  needsWebsocketClient =
    lib.versionAtLeast version "22.5"
    || (lib.versionAtLeast version "21.10" && lib.versionOlder version "22")
    || (lib.versionAtLeast version "20.15" && lib.versionOlder version "21");

  # res_ari.so is in `needed`; Asterisk reports a missing dependency of it,
  # and noload can leave out a resource such as res_ari_recordings.so.
  # res_ari_asterisk.so is left out: its /ari/asterisk/config/dynamic shows
  # every PJSIP password, to read-only users too
  ariModules =
    [
      "res_http_websocket.so"
    ]
    ++ optionals needsWebsocketClient ["res_websocket_client.so"]
    ++ [
      "res_stasis.so"
      "res_stasis_answer.so"
      "res_stasis_device_state.so"
      "res_stasis_playback.so"
      "res_stasis_recording.so"
      "res_stasis_snoop.so"
      "app_stasis.so"
      "res_ari_model.so"
      "res_ari_applications.so"
      "res_ari_bridges.so"
      "res_ari_channels.so"
      "res_ari_device_states.so"
      "res_ari_endpoints.so"
      "res_ari_events.so"
      "res_ari_playbacks.so"
      "res_ari_recordings.so"
      "res_ari_sounds.so"
    ];

  websocketTransports = builtins.filter (
    t:
      builtins.elem t.protocol [
        "ws"
        "wss"
      ]
  ) (builtins.attrValues cfg.pjsip.transports);
in {
  options.services.asterisk = {
    http = {
      enable = lib.mkEnableOption "Asterisk's built-in HTTP server (needed by ARI and WebSocket transports)";

      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = ''
          Address the HTTP server listens on. The service waits for a
          specific address as for a SIP transport's, see
          {option}`services.asterisk.pjsip.transports.<name>.address`.
        '';
      };

      port = mkOption {
        type = types.port;
        default = 8088;
        description = "Port of the plain HTTP listener.";
      };

      tls = {
        enable = lib.mkEnableOption "the HTTPS listener";
        address = mkOption {
          type = types.str;
          default = hcfg.address;
          defaultText = lib.literalExpression "config.services.asterisk.http.address";
          description = ''
            Address the HTTPS listener binds to. The service waits for a
            specific address as for a SIP transport's, see
            {option}`services.asterisk.pjsip.transports.<name>.address`.
          '';
        };
        port = mkOption {
          type = types.port;
          default = 8089;
          description = "Port of the HTTPS listener.";
        };
        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Certificate chain (PEM), loaded as a systemd credential. From
            systemd 260 on, a renewed certificate is applied by
            `systemctl reload asterisk`.
          '';
        };
        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Private key (PEM), loaded as a systemd credential.";
        };
      };

      openFirewall = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Open the HTTP (and HTTPS) port (on
          {option}`services.asterisk.firewallInterfaces` when
          {option}`services.asterisk.openFirewall` is set).
        '';
      };

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
        example = {
          prefix = "asterisk";
          sessionlimit = 100;
        };
        description = "Additional keys of http.conf's `[general]` section.";
      };
    };

    ari = {
      enable = mkOption {
        type = types.bool;
        default = false;
        example = true;
        description = ''
          Whether to enable the Asterisk REST Interface (ARI); requires
          `http.enable`. It loads the resources for applications, bridges,
          channels, device states, endpoints, events, playbacks, recordings
          and sounds, but not `/ari/asterisk` (res_ari_asterisk.so), with
          `info`, `ping`, `modules` (loads and unloads modules), `logging`
          (log channels), `variable` (global variables) and `config/dynamic`,
          which shows and changes PJSIP objects and shows every PJSIP
          password, to read-only users too. An application that needs them
          adds `res_ari_asterisk.so` to
          {option}`services.asterisk.modules.load`.
        '';
      };

      users = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              password = mkOption {
                type = format.types.secretOrString;
                description = "Password, normally a secret reference.";
              };
              readOnly = mkOption {
                type = types.bool;
                default = false;
                description = ''
                  Only allow GET requests. These still read voicemail PINs,
                  with `VM_INFO(<mailbox>,password)` as a variable of any
                  channel, and with res_ari_asterisk.so loaded every PJSIP
                  password, at `/ari/asterisk/config/dynamic/res_pjsip/auth/<name>`.
                '';
              };
            };
          }
        );
        default = {};
        example = lib.literalExpression ''
          { app.password = config.lib.asterisk.secret config.sops.secrets.ari-app.path; }
        '';
        description = "ARI users (HTTP basic authentication).";
      };

      allowedOrigins = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["https://ari.example.org"];
        description = "Origins allowed for cross-origin requests (`allowed_origins`).";
      };

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
        example = {
          pretty = true;
        };
        description = "Additional keys of ari.conf's `[general]` section.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf hcfg.enable {
      services.asterisk = {
        settings."http.conf".general = mkMerge [
          (toSection (
            {
              enabled = true;
              bindaddr = hcfg.address;
              bindport = hcfg.port;
            }
            // lib.optionalAttrs hcfg.tls.enable {
              tlsenable = true;
              tlsbindaddr = format.hostPort hcfg.tls.address hcfg.tls.port;
              tlscertfile =
                if hcfg.tls.certFile != null
                then credentialPath "cert"
                else null;
              tlsprivatekey =
                if hcfg.tls.keyFile != null
                then credentialPath "key"
                else null;
            }
          ))
          hcfg.settings
        ];

        credentials =
          lib.optionalAttrs (hcfg.tls.enable && hcfg.tls.certFile != null) {
            http-tls-cert = hcfg.tls.certFile;
          }
          // lib.optionalAttrs (hcfg.tls.enable && hcfg.tls.keyFile != null) {
            http-tls-key = hcfg.tls.keyFile;
          };

        firewall.http = hcfg.openFirewall;
      };

      # the flag comes first, so its type is checked when openFirewall is off
      warnings = lib.optional (hcfg.openFirewall && !cfg.openFirewall) "services.asterisk.http.openFirewall opens the HTTP ports only together with services.asterisk.openFirewall, which is off.";

      assertions = [
        {
          assertion = hcfg.tls.enable -> (hcfg.tls.certFile != null && hcfg.tls.keyFile != null);
          message = "services.asterisk.http.tls needs certFile and keyFile.";
        }
      ];
    })

    (mkIf acfg.enable {
      services.asterisk = {
        modules.needed."services.asterisk.ari" = ["res_ari.so"];
        modules.load = ariModules;

        # res_websocket_client logs an error when its file is missing; its
        # connections (outbound WebSockets) go into settings
        settings."websocket_client.conf" = mkIf needsWebsocketClient {};

        settings."ari.conf" =
          {
            general = mkMerge [
              {
                enabled = mkDefault true;
                allowed_origins = mkIf (acfg.allowedOrigins != []) (
                  mkDefault (concatStringsSep "," acfg.allowedOrigins)
                );
              }
              acfg.settings
            ];
          }
          // mapAttrs' (
            name: u:
              nameValuePair "user:${name}" {
                inherit name;
                type = "user";
                password = mkDefault u.password;
                read_only = mkDefault u.readOnly;
              }
          )
          acfg.users;
      };

      assertions = [
        {
          assertion = hcfg.enable;
          message = "services.asterisk.ari.enable requires services.asterisk.http.enable.";
        }
      ];
    })

    (mkIf (websocketTransports != []) {
      services.asterisk.modules.needed."services.asterisk.pjsip.transports (ws, wss)" = [
        "res_http_websocket.so"
        "res_pjsip_transport_websocket.so"
      ];

      assertions = [
        {
          assertion = hcfg.enable;
          message = "services.asterisk: WebSocket transports (ws, wss) require services.asterisk.http.enable.";
        }
        {
          assertion = builtins.any (t: t.protocol == "wss") websocketTransports -> hcfg.tls.enable;
          message = "services.asterisk: a wss transport requires services.asterisk.http.tls.enable.";
        }
      ];
    })
  ]);
}
