# Provisioning for Cisco phones and adapters with third-party call control
# firmware: each pbx.phones device of one of these models gets a `<mac>.xml`
# (Cisco's XML flat profile) in which each line registers as its endpoint.
#
# Every element set here is in Cisco's guides for the models that use it:
# Cisco IP Desk Phone and Cisco IP Conference Phone with Multiplatform
# Firmware Administration Guides (2025-11-19, firmware 12.0(7)SR3), ATA 191 and
# ATA 192 Provisioning Guide for Multiplatform Firmware (2025-04-10, 11.3(1)),
# Provisioning Guide for SPA100 and SPA200 Series ATAs (78-21581-01, 1.3) and
# SPA100 Series Administration Guide (1.3.5), SPA300 Series, SPA500 Series and
# WIP310 IP Phone Administration Guide (OL-19749-09, 2016), and ATA
# Administration Guide for SPA2102, SPA3102, SPA8000 (OL-17901-01, 2008).
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

  cfg = config.pbx.phones.cisco;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  pbxLib = import ../lib.nix {inherit lib;};

  # the adapters with a router keep their admin password and NTP server in
  # the router configuration, a section nested in the flat profile
  routerAdapter = {
    adminPassword = "router-configuration/Web_Login_Admin_Password";
    ntpServer = server: {
      "router-configuration/Time_Setup/Time_Server" = server;
      # auto, the default, uses the adapter's own NTP server instead
      "router-configuration/Time_Setup/Time_Server_Mode" = "manual";
    };
    useAuthId = true;
    shared = {};
    # ata191.cfg, spa112.cfg
    bootstrap = model: ["${model}.cfg"];
  };

  # what each firmware generation calls the settings the module writes, and
  # the files its factory devices fetch from the server in DHCP option 66, by
  # the model without `cisco-`
  generations = {
    multiplatform = {
      adminPassword = "Admin_Password";
      adminPasswordRule = {
        text = "8 to 127 characters from ASCII 33 (!) to 126 (~) of three kinds out of capital letters, small letters, digits and others, which the multiplatform firmware requires";
        valid = password: let
          kinds = builtins.filter (kind: builtins.match ".*[${kind}].*" password != null) ["A-Z" "a-z" "0-9" "!-/:-@[-`{-~"];
        in
          builtins.match "[!-~]{8,127}" password != null && builtins.length kinds >= 3;
      };
      ntpServer = server: {Primary_NTP_Server = server;};
      useAuthId = false;
      shared.Webex_Onboard_Enable = "No"; # onboarding to Cisco's Webex cloud, on by default
      bootstrap = model: ["${model}-3PCC.xml"];
    };
    ata19x =
      routerAdapter
      // {
        adminPasswordRule = {
          text = "at least 8 characters, which the ATA 191 and ATA 192 require";
          valid = password: builtins.stringLength password >= 8;
        };
      };
    spa100 =
      routerAdapter
      // {
        adminPasswordRule = {
          text = "at most 32 characters, which the SPA112 and SPA122 take";
          valid = password: builtins.stringLength password <= 32;
        };
      };
    spa = {
      adminPassword = "Admin_Passwd";
      adminPasswordRule = null;
      ntpServer = server: {Primary_NTP_Server = server;};
      useAuthId = true;
      shared = {};
      # Cisco's guides don't say whether the G of a model is capital in the name,
      # as Wazo serves it, so both are served
      bootstrap = model: lib.unique ["${model}.cfg" "${lib.removeSuffix "g" model}${lib.optionalString (lib.hasSuffix "g" model) "G"}.cfg"];
    };
  };

  model = generation: lines: {inherit generation lines;};

  models = {
    cisco-6821 = model "multiplatform" 2;
    cisco-6841 = model "multiplatform" 4;
    cisco-6851 = model "multiplatform" 4;
    cisco-6861 = model "multiplatform" 4;
    cisco-6871 = model "multiplatform" 6;
    cisco-7811 = model "multiplatform" 1;
    cisco-7821 = model "multiplatform" 2;
    cisco-7832 = model "multiplatform" 1;
    cisco-7841 = model "multiplatform" 4;
    cisco-7861 = model "multiplatform" 16;
    cisco-8811 = model "multiplatform" 10;
    cisco-8832 = model "multiplatform" 1;
    cisco-8841 = model "multiplatform" 10;
    cisco-8845 = model "multiplatform" 10;
    cisco-8851 = model "multiplatform" 10;
    cisco-8861 = model "multiplatform" 10;
    cisco-8865 = model "multiplatform" 10;
    # adapters: line n is phone port n
    cisco-ata191 = model "ata19x" 2;
    cisco-ata192 = model "ata19x" 2;
    cisco-spa112 = model "spa100" 2;
    cisco-spa122 = model "spa100" 2;
    cisco-spa8000 = model "spa" 8;
    cisco-spa301 = model "spa" 1;
    cisco-spa303 = model "spa" 3;
    cisco-spa502g = model "spa" 1;
    cisco-spa504g = model "spa" 4;
    cisco-spa508g = model "spa" 8;
    cisco-spa509g = model "spa" 12;
    cisco-spa512g = model "spa" 1;
    cisco-spa514g = model "spa" 4;
  };

  generationOf = device: generations.${models.${device.model}.generation};

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  # the endpoint of each of the model's lines, null for an unused one
  lineEndpoints = device: let
    count = models.${device.model}.lines;
  in
    device.lines ++ lib.genList (_: null) (count - builtins.length device.lines);

  lineSettings = generation: n: name: let
    key = setting: "${setting}_${toString n}_";
  in
    if name == null
    then {${key "Line_Enable"} = "No";}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in
      {
        ${key "Line_Enable"} = "Yes";
        ${key "Proxy"} = pbxLib.sipServerText pcfg;
        # sent as the user of From and To: Asterisk looks up the endpoint by
        # the From user and its aor by the To user
        ${key "User_ID"} = name;
        ${key "Auth_ID"} = auth.username;
        ${key "Password"} = auth.password;
      }
      # without it the SPA devices and the ATA 191 and 192 authenticate with
      # User_ID
      // optionalAttrs generation.useAuthId {${key "Use_Auth_ID"} = "Yes";};

  # this server, so the device keeps fetching its own file ($MA is its MAC
  # address in lowercase hex)
  profileRule =
    cfg.settings.Profile_Rule or "http://${format.hostPort pcfg.listenAddress (
      if pcfg.port == 80
      then null
      else pcfg.port
    )}/$MA.xml";

  # what the module sets besides the lines
  baseSettings = device: let
    generation = generationOf device;
  in
    {
      Profile_Rule = profileRule;
      # the bootstrap's second rule, which would fetch this file twice in every
      # resync
      Profile_Rule_B = "";
    }
    // optionalAttrs (pcfg.adminPassword != null) {${generation.adminPassword} = pcfg.adminPassword;}
    // optionalAttrs (pcfg.ntpServer != null) (generation.ntpServer pcfg.ntpServer)
    // generation.shared;

  deviceSettings = device:
    baseSettings device
    // lib.mergeAttrsList (lib.imap1 (lineSettings (generationOf device)) (lineEndpoints device))
    // cfg.settings
    // device.settings;

  # devices of a generation with a plain admin password its rule refuses; a
  # secret is only known at runtime
  invalidAdminPasswords = name: generation:
    attrNames (filterAttrs (_: device: let
      password = (baseSettings device // cfg.settings // device.settings).${generation.adminPassword} or null;
    in
      models.${device.model}.generation == name && password != null && !secrets.holdsSecret password && !generation.adminPasswordRule.valid (toString password))
    devices);

  # the settings of each device that match `predicate`, as `<name> <key>`
  findValues = predicate: keys:
    lib.concatLists (mapAttrsToList (name: device: let
      values = deviceSettings device;
    in
      map (key: "${name} ${key}") (builtins.filter (key: values ? ${key} && predicate values.${key}) (keys device values)))
    validDevices);

  controlCharacters = findValues pbxLib.hasControlCharacter (_: values: lib.naturalSort (attrNames values));

  # where the device registers and fetches its file
  wildcardServers = findValues pbxLib.sendsToWildcard (device: _: ["Profile_Rule"] ++ lib.genList (i: "Proxy_${toString (i + 1)}_") models.${device.model}.lines);

  # an element name, or a path of them through nested sections
  validKey = key: builtins.all (name: builtins.match "[A-Za-z_][A-Za-z0-9_.-]*" name != null) (lib.splitString "/" key);

  # the elements of `values`, keyed by element name or path, the sections
  # after the plain elements
  elements = indent: values: let
    plain = filterAttrs (key: _: !lib.hasInfix "/" key) values;
    nested = filterAttrs (key: _: lib.hasInfix "/" key) values;
    sectionOf = key: builtins.head (lib.splitString "/" key);
    section = name: mapAttrs' (key: nameValuePair (lib.removePrefix "${name}/" key)) (filterAttrs (key: _: sectionOf key == name) nested);
  in
    concatStrings (map (key: "${indent}<${key}>${pbxLib.phoneValueText pbxLib.escapeXml plain.${key}}</${key}>\n") (lib.naturalSort (attrNames plain)))
    + concatStrings (map (name: "${indent}<${name}>\n${elements "${indent}  " (section name)}${indent}</${name}>\n") (lib.unique (map sectionOf (attrNames nested))));

  deviceXml = device: ''
    <?xml version="1.0" encoding="UTF-8"?>
    <flat-profile>
    ${elements "  " (deviceSettings device)}</flat-profile>
  '';

  # what a factory device of the models in use fetches first, over TFTP or
  # HTTP, with nothing in it but where its own file is. The device applies
  # Profile_Rule, then fetches Profile_Rule_B in the same resync, while a
  # changed Profile_Rule alone would wait for the next one
  bootstrapNames = lib.unique (lib.concatMap (device: generations.${models.${device.model}.generation}.bootstrap (lib.removePrefix "cisco-" device.model)) (attrValues validDevices));
  bootstrapXml = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <flat-profile>
    ${elements "  " {
      Profile_Rule = profileRule;
      Profile_Rule_B = profileRule;
    }}</flat-profile>
  '';
in {
  options.pbx.phones.cisco.settings = mkOption {
    type = types.attrsOf pbxLib.phoneValue;
    default = {};
    example = {
      Time_Zone = "GMT+01:00";
      "router-configuration/Time_Setup/Time_Zone" = "+01 2 2";
    };
    description = "Elements of the XML profile of every Cisco device, replacing the module's. An element in a section is given as its path, such as `router-configuration/Time_Setup/Time_Zone`.";
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: model: {inherit (model) lines;}) models;}

    (mkIf (devices != {}) {
      assertions =
        mapAttrsToList (name: generation: let
          invalid = invalidAdminPasswords name generation;
        in {
          assertion = invalid == [];
          message = "pbx.phones: the admin password (${generation.adminPassword}) of ${lib.concatStringsSep ", " invalid} is not ${generation.adminPasswordRule.text}.";
        }) (filterAttrs (_: generation: generation.adminPasswordRule != null) generations)
        ++ [
          {
            assertion = controlCharacters == [];
            message = "pbx.phones.devices: settings of Cisco devices cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
          }
          {
            assertion = wildcardServers == [];
            message = "pbx.phones.devices: settings that send Cisco devices to 0.0.0.0 or ::, which no device can reach: ${lib.concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.Profile_Rule.";
          }
          {
            assertion = builtins.all validKey (attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices));
            message = "pbx.phones: settings of Cisco devices must be XML element names such as Primary_NTP_Server, or paths of them such as router-configuration/Time_Setup/Time_Zone.";
          }
        ];

      pbx.phones.files =
        mapAttrs' (_: device:
          nameValuePair "${device.mac}.xml" {
            text = deviceXml device;
            escape = "xml";
            inherit (device) allowedAddress;
          })
        validDevices
        // lib.listToAttrs (map (name:
          nameValuePair name {
            text = bootstrapXml;
            escape = "xml";
            tftp = true;
          })
        bootstrapNames);
    })
  ];
}
