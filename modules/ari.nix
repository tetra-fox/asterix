# Typed options for Asterisk's HTTP server (http.conf) and the Asterisk REST
# Interface (ari.conf). The HTTP server is also what WebSocket SIP transports
# (`ws`, `wss`) run on.
{ config, lib, ... }:
let
  inherit (lib)
    concatStringsSep
    filterAttrs
    mapAttrs
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optionals
    types
    ;

  cfg = config.services.asterisk-declarative;
  hcfg = cfg.http;
  acfg = cfg.ari;
  asteriskLib = import ../lib { inherit lib; };
  inherit (asteriskLib) format;

  secretOrString = types.either types.str format.types.secret // {
    description = "string or secret reference";
  };

  credentialPath = kind: "${cfg.paths.credentials}/http-tls-${kind}";

  ariModules = [
    "res_http_websocket.so"
    "res_stasis.so"
    "res_stasis_answer.so"
    "res_stasis_device_state.so"
    "res_stasis_playback.so"
    "res_stasis_recording.so"
    "res_stasis_snoop.so"
    "app_stasis.so"
    "res_ari.so"
    "res_ari_model.so"
    "res_ari_applications.so"
    "res_ari_asterisk.so"
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
in
{
  options.services.asterisk-declarative = {
    http = {
      enable = lib.mkEnableOption "Asterisk's built-in HTTP server (needed by ARI and WebSocket transports)";

      address = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Address the HTTP server listens on.";
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
          default = "0.0.0.0";
          description = "Address the HTTPS listener binds to.";
        };
        port = mkOption {
          type = types.port;
          default = 8089;
          description = "Port of the HTTPS listener.";
        };
        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Certificate chain (PEM), loaded as a systemd credential.";
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
          {option}`services.asterisk-declarative.firewallInterfaces` when
          {option}`services.asterisk-declarative.openFirewall` is set).
        '';
      };

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = { };
        example = {
          prefix = "asterisk";
          sessionlimit = 100;
        };
        description = "Additional keys of http.conf's `[general]` section.";
      };
    };

    ari = {
      enable = lib.mkEnableOption "the Asterisk REST Interface (ARI); requires `http.enable`";

      users = mkOption {
        type = types.attrsOf (
          types.submodule {
            options = {
              password = mkOption {
                type = secretOrString;
                description = "Password, normally a secret reference.";
              };
              readOnly = mkOption {
                type = types.bool;
                default = false;
                description = "Only allow GET requests.";
              };
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          { app.password = config.lib.asterisk.secret "/run/agenix/ari-app"; }
        '';
        description = "ARI users (HTTP basic authentication).";
      };

      allowedOrigins = mkOption {
        type = types.listOf types.str;
        default = [ ];
        example = [ "https://ari.example.org" ];
        description = "Origins allowed for cross-origin requests (`allowed_origins`).";
      };

      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = { };
        example = {
          pretty = true;
        };
        description = "Additional keys of ari.conf's `[general]` section.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    (mkIf hcfg.enable {
      services.asterisk-declarative = {
        settings."http.conf".general = mkMerge [
          (mapAttrs (_: mkDefault) (
            filterAttrs (_: v: v != null) (
              {
                enabled = true;
                bindaddr = hcfg.address;
                bindport = hcfg.port;
              }
              // lib.optionalAttrs hcfg.tls.enable {
                tlsenable = true;
                tlsbindaddr = "${hcfg.tls.address}:${toString hcfg.tls.port}";
                tlscertfile = if hcfg.tls.certFile != null then credentialPath "cert" else null;
                tlsprivatekey = if hcfg.tls.keyFile != null then credentialPath "key" else null;
              }
            )
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

        firewall.tcpPorts = mkIf hcfg.openFirewall (
          [ hcfg.port ] ++ optionals hcfg.tls.enable [ hcfg.tls.port ]
        );
      };

      assertions = [
        {
          assertion = hcfg.tls.enable -> (hcfg.tls.certFile != null && hcfg.tls.keyFile != null);
          message = "services.asterisk-declarative.http.tls needs certFile and keyFile.";
        }
      ];
    })

    (mkIf acfg.enable {
      services.asterisk-declarative = {
        modules.load = ariModules;

        settings."ari.conf" = {
          general = mkMerge [
            {
              enabled = mkDefault true;
              allowed_origins = mkIf (acfg.allowedOrigins != [ ]) (
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
        ) acfg.users;
      };

      assertions = [
        {
          assertion = hcfg.enable;
          message = "services.asterisk-declarative.ari.enable requires services.asterisk-declarative.http.enable.";
        }
      ];
    })

    (mkIf (websocketTransports != [ ]) {
      services.asterisk-declarative.modules.load = [
        "res_http_websocket.so"
        "res_pjsip_transport_websocket.so"
      ];

      assertions = [
        {
          assertion = hcfg.enable;
          message = "services.asterisk-declarative: WebSocket transports (ws, wss) require services.asterisk-declarative.http.enable.";
        }
        {
          assertion = builtins.any (t: t.protocol == "wss") websocketTransports -> hcfg.tls.enable;
          message = "services.asterisk-declarative: a wss transport requires services.asterisk-declarative.http.tls.enable.";
        }
      ];
    })
  ]);
}
