# Provisioning for Snom desk phones: each pbx.phones device of one of these
# models gets a `snom<model>-<MAC>.htm`, the settings file a Snom requests
# from a setting server URL without a file name, in which each line, an
# identity, registers as its endpoint.
#
# Every setting is in Snom's D-Series settings reference, the file name in its
# Auto Provisioning page and the line counts in its datasheets
# (service.snom.com, firmware 10.1.226.16; the D120's last firmware is
# 10.1.54.24, the D315's 10.1.198.19).
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
    mapAttrs'
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optionalAttrs
    optionalString
    types
    ;

  cfg = config.pbx.phones.snom;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format;
  pbxLib = import ../lib.nix {inherit lib;};

  # identities per model; the D86x have a second web interface, the Phone
  # Manager, with logins of its own, and the D120's firmware has no tr369_enable
  desk = lines: {
    inherit lines;
    phoneManager = false;
    tr369 = true;
  };
  models = {
    snom-d120 = desk 2 // {tr369 = false;};
    snom-d140 = desk 2;
    snom-d150 = desk 2;
    snom-d315 = desk 4;
    snom-d335 = desk 12;
    snom-d385 = desk 12;
    snom-d713 = desk 6;
    snom-d717 = desk 6;
    snom-d735 = desk 12;
    snom-d785 = desk 12;
    snom-d812 = desk 12;
    snom-d815 = desk 12;
    snom-d862 = desk 8 // {phoneManager = true;};
    snom-d865 = desk 12 // {phoneManager = true;};
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  # the phone type in the names of the files a phone requests, such as snomD785
  phoneType = device: "snom${lib.toUpper (lib.removePrefix "snom-" device.model)}";

  server = format.hostPort pcfg.listenAddress (
    if pcfg.port == 80
    then null
    else pcfg.port
  );

  # the endpoint of each of the model's lines, null for an unused one
  lineEndpoints = device: let
    count = models.${device.model}.lines;
  in
    device.lines ++ lib.genList (_: null) (count - builtins.length device.lines);

  lineSettings = index: name: let
    key = setting: "${setting}[${toString index}]";
  in
    if name == null
    then {${key "user_active"} = "off";}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in {
      ${key "user_active"} = "on";
      # registration user, sent as the user of From and To: Asterisk looks up
      # the endpoint by the From user and its aor by the To user
      ${key "user_name"} = name;
      ${key "user_pname"} = auth.username;
      ${key "user_pass"} = auth.password;
      ${key "user_host"} = pbxLib.sipServerText pcfg;
    };

  deviceSettings = device: let
    model = models.${device.model};
    password = pcfg.adminPassword;
  in
    filterAttrs (_: v: v != null) {
      ntp_server = pcfg.ntpServer;
      timezone = cfg.timeZone;
      # this server and the phone's own file, so the phone keeps coming back
      # here instead of to Snom's redirection service (SRAPS)
      setting_server = "http://${server}/${phoneType device}-{mac}.htm";
      update_policy = "settings_only"; # never update the firmware
    }
    # index 1 is Snom's device management (SRAPS), on by default from 10.1.161
    # until 10.1.226
    // optionalAttrs model.tr369 {"tr369_enable[1]" = "false";}
    # the web interface takes a user and a password; on the D86x it is the old
    # one on port 3112, next to the Phone Manager
    // optionalAttrs (password != null) (
      {
        http_user = "admin";
        http_pass = password;
      }
      // optionalAttrs model.phoneManager {
        webserver_admin_name = "admin";
        webserver_admin_password = password;
      }
    )
    // lib.mergeAttrsList (lib.imap1 lineSettings (lineEndpoints device))
    // cfg.settings
    // device.settings;

  # the module's settings are read-only on the phone; setting_server, so a
  # phone can be moved to another server, and the settings options are writable
  permission = device: key:
    if key == "setting_server" || (cfg.settings // device.settings) ? ${key}
    then "RW"
    else "R";

  # `name`, or `name[index]` for the element `name` with the idx attribute
  matchKey = builtins.match "([A-Za-z0-9_]+)([[](0|[1-9][0-9]*)[]])?";
  isKey = key: matchKey key != null;
  parseKey = key: let
    m = matchKey key;
  in
    if m == null || lib.elemAt m 2 == null
    then {
      name = key;
      index = null;
    }
    else {
      name = builtins.head m;
      index = lib.elemAt m 2;
    };

  # settings without an index first, then by index, so each line's are together
  sortedKeys = values: let
    rank = key: let
      inherit (parseKey key) index;
    in
      if index == null
      then -1
      else lib.toInt index;
  in
    lib.sort (a: b:
      if rank a != rank b
      then rank a < rank b
      else a < b) (attrNames values);

  # the settings of each phone that match `predicate`, as `<name> <setting>`
  findValues = predicate: keys:
    lib.concatLists (mapAttrsToList (name: device: let
      values = deviceSettings device;
    in
      map (key: "${name} ${key}") (builtins.filter (key: predicate values.${key}) (keys values)))
    validDevices);

  controlCharacters = findValues pbxLib.hasControlCharacter sortedKeys;

  # where the phone fetches its file and its lines register
  wildcardServers = findValues pbxLib.sendsToWildcard (values: builtins.filter (key: key == "setting_server" || (parseKey key).name == "user_host") (sortedKeys values));

  deviceXml = device: let
    values = deviceSettings device;
    setting = key: let
      inherit (parseKey key) name index;
    in "    <${name}${optionalString (index != null) " idx=\"${index}\""} perm=\"${permission device key}\">${pbxLib.phoneValueText pbxLib.escapeXml values.${key}}</${name}>\n";
  in ''
    <?xml version="1.0" encoding="utf-8"?>
    <settings>
      <phone-settings>
    ${concatStrings (map setting (sortedKeys values))}  </phone-settings>
    </settings>
  '';
in {
  options.pbx.phones.snom = {
    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "GER+1";
      description = "Time zone of the Snom phones (`timezone`), one of the values listed in Snom's settings reference; `null` keeps their default.";
    };

    settings = mkOption {
      type = types.attrsOf pbxLib.phoneValue;
      default = {};
      example = {
        language = "Deutsch";
        tone_scheme = "GER";
      };
      description = "Settings for every Snom phone, replacing the module's and writable on the phone: `name`, or `name[index]` for an indexed one such as `user_realname[1]`.";
    };
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: model: {inherit (model) lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.devices: Snom settings cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = wildcardServers == [];
          message = "pbx.phones.devices: Snom settings that send phones to 0.0.0.0 or ::, which no phone can reach: ${lib.concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings.setting_server.";
        }
        {
          assertion = builtins.all isKey (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices)
          );
          message = "pbx.phones: settings of Snom phones must be setting names such as language, or name[index] for an indexed one such as user_realname[1].";
        }
      ];

      pbx.phones.files = mapAttrs' (_: device:
        nameValuePair "${phoneType device}-${lib.toUpper device.mac}.htm" {
          text = deviceXml device;
          escape = "xml";
          inherit (device) allowedAddress;
        })
      validDevices;
    })
  ];
}
