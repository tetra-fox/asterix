# Provisioning for Grandstream HT801 adapters: each adapter gets a
# `cfg<mac>.xml` (Grandstream's gs_provision format) with the SIP account of a
# services.asterisk.pjsip endpoint, served by services.asterisk.provisioning.
#
# Every P-value set here is in Grandstream's HT80x configuration templates for
# both hardware versions (config-template.zip from grandstream.com/support/tools:
# ht80x 1.0.65.3 and ht80x_v2 1.0.15.2).
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    attrNames
    attrValues
    concatStrings
    filterAttrs
    isInt
    literalExpression
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    toLower
    types
    ;

  cfg = config.services.asterisk.provisioning.grandstream.ht801;
  pcfg = config.services.asterisk.provisioning;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;

  valueType =
    types.oneOf [
      types.str
      types.int
      format.types.secret
    ]
    // {
      description = "string, integer or secret reference";
    };

  deviceType = types.submodule (
    {name, ...}: {
      options = {
        mac = mkOption {
          type = types.strMatching "([0-9a-fA-F]{2}[:-]?){5}[0-9a-fA-F]{2}";
          example = "c0:74:ad:12:34:56";
          description = "MAC address of the adapter (any of the usual notations).";
        };
        endpoint = mkOption {
          type = types.str;
          default = name;
          defaultText = literalExpression "<name>";
          description = ''
            Endpoint in {option}`services.asterisk.pjsip.endpoints` whose
            credentials the adapter's phone port registers with.
          '';
        };
        allowedAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10.0.20.21";
          description = ''
            Only this address may download the adapter's file, which contains
            its SIP password. Use it together with a static DHCP lease.
          '';
        };
        settings = mkOption {
          type = types.attrsOf valueType;
          default = {};
          example = {
            P1362 = "de";
          };
          description = "Additional P-values for this adapter, overriding the common ones.";
        };
      };
    }
  );

  normalizeMac = mac: toLower (lib.replaceStrings [":" "-"] ["" ""] mac);

  endpointOf = device: acfg.pjsip.endpoints.${device.endpoint} or null;

  commonSettings = filterAttrs (_: v: v != null) (
    {
      P47 = cfg.sipServer; # primary SIP server
      P30 = cfg.ntpServer; # NTP server
      P64 = cfg.timeZone; # time zone
      P2 = cfg.adminPassword; # admin password of the web interface
      P212 = 1; # config upgrade via HTTP
      # config server path: this server, so the adapter keeps coming back here
      P237 = pcfg.listenAddress + lib.optionalString (pcfg.port != 80) ":${toString pcfg.port}";
      P238 = 2; # always skip the firmware check (Grandstream's server by default)
      P1409 = 0; # TR-069 off (Grandstream's GDMS cloud by default)
    }
    // cfg.settings
  );

  deviceSettings = device: let
    inherit (endpointOf device) auth;
  in
    commonSettings
    // {
      P271 = 1; # account active
      P35 = auth.username; # SIP user ID
      P36 = auth.username; # authentication ID
      P34 = auth.password; # authentication password
    }
    // device.settings;

  escapeXml = lib.replaceStrings ["&" "<" ">" "\"" "'"] ["&amp;" "&lt;" "&gt;" "&quot;" "&apos;"];

  # secrets become placeholders, which the provisioning service XML-escapes
  valueText = v:
    if secrets.isSecret v
    then secrets.placeholderOf v
    else if isInt v
    then toString v
    else escapeXml v;

  # numeric order; keys that are not P-values are reported by an assertion
  pNumber = p: let
    m = builtins.match "P([0-9]+)" p;
  in
    if m == null
    then 0
    else lib.toInt (builtins.head m);

  deviceXml = device: let
    values = deviceSettings device;
    keys = lib.sort (a: b: pNumber a < pNumber b) (attrNames values);
  in ''
    <?xml version="1.0" encoding="UTF-8"?>
    <gs_provision version="1">
      <mac>${normalizeMac device.mac}</mac>
      <config version="1">
    ${concatStrings (map (p: "    <${p}>${valueText values.${p}}</${p}>\n") keys)}  </config>
    </gs_provision>
  '';
in {
  options.services.asterisk.provisioning.grandstream.ht801 = {
    enable = mkEnableOption "provisioning of Grandstream HT801 adapters over HTTP";

    sipServer = mkOption {
      type = types.str;
      default = pcfg.listenAddress;
      defaultText = literalExpression "config.services.asterisk.provisioning.listenAddress";
      example = "10.0.20.10:5060";
      description = "SIP server the adapters register to (P47).";
    };

    ntpServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.0.20.10";
      description = "NTP server (P30); `null` keeps the adapter's default.";
    };

    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
      description = "Time zone (P64), one of the values listed in the HT80x template.";
    };

    adminPassword = mkOption {
      type = types.nullOr valueType;
      default = null;
      example = literalExpression "config.lib.asterisk.secret config.sops.secrets.ht801-admin.path";
      description = ''
        Password of the adapters' web interface (P2), normally a secret
        reference. HT801 V2 requires 4 to 30 characters.
      '';
    };

    settings = mkOption {
      type = types.attrsOf valueType;
      default = {};
      example = {
        P1362 = "en";
      };
      description = "Additional P-values for every adapter.";
    };

    devices = mkOption {
      type = types.attrsOf deviceType;
      default = {};
      example = literalExpression ''
        {
          "101" = { mac = "c0:74:ad:12:34:56"; allowedAddress = "10.0.20.21"; };
          "102".mac = "c074ad654321";
        }
      '';
      description = "Adapters to provision, keyed by the endpoint they register as by default.";
    };
  };

  config = mkIf cfg.enable {
    assertions =
      [
        {
          assertion = lib.allUnique (map (device: normalizeMac device.mac) (attrValues cfg.devices));
          message = "services.asterisk.provisioning.grandstream.ht801.devices: MAC addresses must be unique.";
        }
        {
          assertion = builtins.all (p: builtins.match "P[0-9]+" p != null) (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues cfg.devices)
          );
          message = "services.asterisk.provisioning.grandstream.ht801: settings keys must be P-values such as P1362.";
        }
      ]
      ++ mapAttrsToList (name: device: {
        assertion = endpointOf device != null && (endpointOf device).auth != null;
        message = "services.asterisk.provisioning.grandstream.ht801.devices.${name}: endpoint `${device.endpoint}` must exist in pjsip.endpoints and have `auth` set.";
      })
      cfg.devices;

    services.asterisk.provisioning = {
      enable = true;
      files = mapAttrs' (_: device:
        nameValuePair "cfg${normalizeMac device.mac}.xml" {
          text = deviceXml device;
          escape = "xml";
          inherit (device) allowedAddress;
        })
      cfg.devices;
    };
  };
}
