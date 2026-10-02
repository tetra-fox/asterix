# Provisioning for Yealink SIP phones on firmware V84 and later: each
# pbx.phones device of one of these models gets a `<mac>.cfg`, Yealink's
# MAC-oriented configuration file, in which each line is an account that
# registers as its endpoint. Without boot files on the server, the phone asks
# for its model's common file and then this one.
#
# Every key set here is in Yealink's administrator guides for the models that
# use it (SIP-T2/T3/T4/T5/CP920 IP Phones Administrator Guide V86.60, which the
# T44U and T44W share as T4U phones; Administrator's Guide for VP59 & SIP-T58 &
# CP96X IP Phones V86.11). The T31W and T34W are in neither guide, and get the
# keys that FusionPBX's and Wazo's templates set for them.
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
    types
    ;

  cfg = config.pbx.phones.yealink;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  pbxLib = import ../lib.nix {inherit lib;};

  phone = lines: {
    inherit lines;
    deviceManagement = true;
  };
  # static.dm.enable is in the SIP phones' guide, which has neither the Android
  # phones nor the T31W and T34W
  withoutDeviceManagement = lines: {
    inherit lines;
    deviceManagement = false;
  };

  # the accounts in the guides' tables, and for the T31W, T34W, T44U and T44W
  # in Yealink's datasheets
  models = {
    yealink-t30 = phone 1;
    yealink-t30p = phone 1;
    yealink-t31 = phone 2;
    yealink-t31g = phone 2;
    yealink-t31p = phone 2;
    yealink-t31w = withoutDeviceManagement 2;
    yealink-t33g = phone 4;
    yealink-t33p = phone 4;
    yealink-t34w = withoutDeviceManagement 4;
    yealink-t41s = phone 6;
    yealink-t42s = phone 12;
    yealink-t42u = phone 12;
    yealink-t43u = phone 12;
    yealink-t44u = phone 12;
    yealink-t44w = phone 12;
    yealink-t46s = phone 16;
    yealink-t46u = phone 16;
    yealink-t48s = phone 16;
    yealink-t48u = phone 16;
    yealink-t53 = phone 12;
    yealink-t53w = phone 12;
    yealink-t54w = phone 16;
    yealink-t57w = phone 16;
    yealink-t58a = withoutDeviceManagement 16;
    yealink-t58w = withoutDeviceManagement 16;
    yealink-cp920 = phone 1;
    yealink-cp925 = phone 1;
    yealink-cp965 = withoutDeviceManagement 1;
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  # the endpoint of each of the model's accounts, null for an unused one
  accountEndpoints = device: device.lines ++ lib.genList (_: null) (models.${device.model}.lines - builtins.length device.lines);

  accountSettings = n: name: let
    key = k: "account.${toString n}.${k}";
  in
    if name == null
    then {${key "enable"} = 0;}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in {
      ${key "enable"} = 1;
      # sent as the user of From and To: Asterisk looks up the endpoint by the
      # From user and its aor by the To user
      ${key "user_name"} = name;
      ${key "auth_name"} = auth.username;
      ${key "password"} = auth.password;
      ${key "sip_server.1.address"} = pcfg.sipServer;
      ${key "sip_server.1.port"} = pcfg.sipPort;
    };

  commonSettings = device:
    filterAttrs (_: v: v != null) {
      "local_time.ntp_server1" = pcfg.ntpServer;
      # the value is <user name>:<password>, here of the administrator
      "static.security.user_password" =
        if pcfg.adminPassword == null
        then null
        else "admin:${pbxLib.phoneValueText lib.id pcfg.adminPassword}";
      # this server, so the phone keeps coming back here
      "static.auto_provision.server.url" = "http://${format.hostPort pcfg.listenAddress (
        if pcfg.port == 80
        then null
        else pcfg.port
      )}/";
    }
    # YMCS/YDMP device management off
    // optionalAttrs models.${device.model}.deviceManagement {"static.dm.enable" = 0;};

  deviceSettings = device:
    commonSettings device
    // lib.mergeAttrsList (lib.imap1 accountSettings (accountEndpoints device))
    // cfg.settings
    // device.settings;

  # phones whose plain static.security.user_password is not user:password with
  # a password a file can set, 1 to 32 characters from ! to ~ but the colon
  invalidAdminPasswords = attrNames (filterAttrs (_: device: let
    values = commonSettings device // cfg.settings // device.settings;
    password = values."static.security.user_password";
  in
    values ? "static.security.user_password" && !secrets.holdsSecret password && builtins.match "[^:]{1,32}:[!-9;-~]{1,32}" (toString password) == null)
  devices);

  # the settings of each phone whose key is `wanted` and whose value matches
  # `predicate`, as `<name> <key>`
  findValues = predicate: wanted:
    lib.concatLists (mapAttrsToList (name: device: let
      values = deviceSettings device;
    in
      map (key: "${name} ${key}") (builtins.filter (key: wanted key && predicate values.${key}) (lib.naturalSort (attrNames values))))
    validDevices);

  controlCharacters = findValues pbxLib.hasControlCharacter (_: true);

  # where the phone registers and fetches its file
  wildcardServers = findValues pbxLib.sendsToWildcard (key: key == "static.auto_provision.server.url" || builtins.match "account[.][0-9]+[.]sip_server[.][0-9]+[.]address" key != null);

  deviceCfg = device: let
    values = deviceSettings device;
  in ''
    #!version:1.0.0.1
    ${concatStrings (map (key: "${key} = ${pbxLib.phoneValueText lib.id values.${key}}\n") (lib.naturalSort (attrNames values)))}'';
in {
  options.pbx.phones.yealink.settings = mkOption {
    type = types.attrsOf pbxLib.phoneValue;
    default = {};
    example = {
      "local_time.time_zone" = "+1";
      "local_time.time_zone_name" = "Germany(Berlin)";
    };
    description = "Configuration parameters for every Yealink device, replacing the module's.";
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: model: {inherit (model) lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = invalidAdminPasswords == [];
          message = "pbx.phones: static.security.user_password of ${lib.concatStringsSep ", " invalidAdminPasswords} is not <user name>:<password> with a password of 1 to 32 characters from ASCII 33 (!) to 126 (~) other than the colon, which is what Yealink phones take from a configuration file.";
        }
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.devices: Yealink settings cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = wildcardServers == [];
          message = "pbx.phones.devices: Yealink settings that send phones to 0.0.0.0 or ::, which no phone can reach: ${lib.concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings.\"static.auto_provision.server.url\".";
        }
        {
          assertion = builtins.all (key: builtins.match "[A-Za-z0-9_]+([.][A-Za-z0-9_]+)*" key != null) (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices)
          );
          message = "pbx.phones: settings of Yealink devices must be configuration parameters such as local_time.time_zone, letters, digits and _ in parts separated by dots.";
        }
      ];

      pbx.phones.files = mapAttrs' (_: device:
        nameValuePair "${device.mac}.cfg" {
          text = deviceCfg device;
          escape = "line";
          inherit (device) allowedAddress;
        })
      validDevices;
    })
  ];
}
