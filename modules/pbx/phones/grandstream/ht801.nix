# Provisioning for Grandstream HT801 adapters: each adapter gets a
# `cfg<mac>.xml` (Grandstream's gs_provision format) with the SIP account of a
# services.asterisk.pjsip endpoint, served by pbx.phones.
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

  cfg = config.pbx.phones.grandstream.ht801;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../../lib {inherit lib;};
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
          description = "MAC address of the adapter: twelve hexadecimal digits, in pairs separated by `:` or `-`, or not separated.";
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

  # the adapter sends one user name, for the endpoint and its aor
  registers = device: let
    endpoint = endpointOf device;
  in
    endpoint != null && endpoint.auth != null && endpoint.aor != null && endpoint.aor.name == device.endpoint;

  commonSettings = filterAttrs (_: v: v != null) (
    {
      P47 = cfg.sipServer; # primary SIP server
      P30 = cfg.ntpServer; # NTP server
      P64 = cfg.timeZone; # time zone
      P2 = cfg.adminPassword; # admin password of the web interface
      P212 = 1; # config upgrade via HTTP
      # config server path: this server, so the adapter keeps coming back here
      P237 = format.hostPort pcfg.listenAddress (
        if pcfg.port == 80
        then null
        else pcfg.port
      );
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
      # SIP user ID, sent as the user of From and To: Asterisk looks up the
      # endpoint by the From user and its aor by the To user
      P35 = device.endpoint;
      P36 = auth.username; # authentication ID
      P34 = auth.password; # authentication password
    }
    // device.settings;

  # adapters with a plain admin password (P2) outside the 4 to 30 characters
  # V2 hardware takes; a secret's length is only known at runtime
  invalidAdminPasswords = attrNames (filterAttrs (_: device: let
    p2 = (commonSettings // device.settings).P2 or null;
    length = builtins.stringLength (toString p2);
  in
    p2 != null && !secrets.holdsSecret p2 && (length < 4 || length > 30))
  cfg.devices);

  # the P-values of each adapter with a control character, which XML holds
  # none of but tab and line breaks, and a P-value is one line; render-secrets
  # refuses them in secrets
  controlCharacters = lib.concatLists (mapAttrsToList (name: device: let
    values = deviceSettings device;
  in
    map (p: "${name} ${p}") (
      builtins.filter (p: builtins.isString values.${p} && builtins.match ".*[[:cntrl:]].*" values.${p} != null) (
        lib.sort (a: b: pNumber a < pNumber b) (attrNames values)
      )
    ))
  (filterAttrs (_: registers) cfg.devices));

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
  options.pbx.phones.grandstream.ht801 = {
    enable = mkEnableOption "provisioning of Grandstream HT801 adapters over HTTP";

    sipServer = mkOption {
      type = types.str;
      default = pcfg.listenAddress;
      defaultText = literalExpression "config.pbx.phones.listenAddress";
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
        reference. A plain string or integer is stored world-readable in the
        Nix store and triggers a warning. HT801 V2 requires 4 to 30
        characters; a plain value outside that fails evaluation.
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
    warnings = lib.optional (cfg.adminPassword != null && !secrets.holdsSecret cfg.adminPassword) "pbx.phones.grandstream.ht801.adminPassword is not a secret reference, so it is stored world-readable in the Nix store; use config.lib.asterisk.secret instead.";

    assertions =
      [
        {
          assertion = lib.allUnique (map (device: normalizeMac device.mac) (attrValues cfg.devices));
          message = "pbx.phones.grandstream.ht801.devices: MAC addresses must be unique.";
        }
        {
          assertion = invalidAdminPasswords == [];
          message = "pbx.phones.grandstream.ht801: the admin password (P2) of ${lib.concatStringsSep ", " invalidAdminPasswords} is not 4 to 30 characters long, which HT801 V2 hardware requires.";
        }
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.grandstream.ht801: P-values cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = builtins.all (p: builtins.match "P[0-9]+" p != null) (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues cfg.devices)
          );
          message = "pbx.phones.grandstream.ht801: settings keys must be P-values such as P1362.";
        }
      ]
      ++ mapAttrsToList (name: device: {
        assertion = registers device;
        message = "pbx.phones.grandstream.ht801.devices.${name}: endpoint `${device.endpoint}` must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the adapter registers with one user name for both.";
      })
      cfg.devices;

    pbx.phones = {
      enable = true;
      # an adapter that cannot register gets no file; the assertion names it
      files = mapAttrs' (_: device:
        nameValuePair "cfg${normalizeMac device.mac}.xml" {
          text = deviceXml device;
          escape = "xml";
          inherit (device) allowedAddress;
        })
      (filterAttrs (_: registers) cfg.devices);
    };
  };
}
