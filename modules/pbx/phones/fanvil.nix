# Provisioning for Fanvil phones, door phones and paging gateways: each
# pbx.phones device of one of these models gets a `<mac>.cfg` in Fanvil's
# sysConf XML, in which each line, a SIP account, registers as its endpoint.
#
# Every key set here is in the key map (vNcDotNameMap.txt) of the firmware
# images at download.fanvil.com that the models run: X4U, X5U, X6U, X7, X7C
# and X210 2.12.26.4; X301, X303 and X305 2.12.24.19; X3S Lite and Pro, X3SG
# Lite, X3SW and X3U Pro 2.12.22.2; X306 2.12.20.12; X1S, X1SG, X3SG and X3U
# 2.4.12; H1, H2U, H3W, H4 and H5W 2.12.24; H601 and H602 2.12.20; H603W
# 2.14.3; H6W 2.12.6.6; i10S, i16S, PA2S and PA3 2.12.52; i61 to i64 2.12.55.
# Most are in the web interface's help texts there too, and all but
# ota.FDPSEnable in FusionPBX's and Wazo's templates. A model's line count is
# its firmware's (Max sip Lines in default_sys_config.txt) and its datasheet's.
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
    concatStringsSep
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

  cfg = config.pbx.phones.fanvil;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  pbxLib = import ../lib.nix {inherit lib;};

  # line counts; P, G and W variants (PoE, gigabit, Wi-Fi) are the model they
  # extend, such as the X301W a fanvil-x301
  models = {
    fanvil-x1s = 2;
    fanvil-x1sg = 2;
    fanvil-x3s-lite = 2;
    fanvil-x3s-pro = 4;
    fanvil-x3sg = 4;
    fanvil-x3sg-lite = 2;
    fanvil-x3sw = 4;
    fanvil-x3u = 6;
    fanvil-x3u-pro = 6;
    fanvil-x4u = 12;
    fanvil-x5u = 16;
    fanvil-x5u-r = 16;
    fanvil-x6u = 20;
    fanvil-x7 = 20;
    fanvil-x7c = 20;
    fanvil-x210 = 20;
    fanvil-x301 = 2;
    fanvil-x303 = 4;
    fanvil-x305 = 2;
    fanvil-x306 = 2;
    fanvil-h1 = 2;
    fanvil-h2u = 2;
    fanvil-h3w = 2;
    fanvil-h4 = 2;
    fanvil-h5w = 2;
    fanvil-h601 = 2;
    fanvil-h602 = 2;
    fanvil-h603w = 2;
    fanvil-h6w = 2;
    fanvil-i10s = 2;
    fanvil-i16s = 2;
    fanvil-i61 = 2;
    fanvil-i62 = 2;
    fanvil-i63 = 2;
    fanvil-i64 = 2;
    fanvil-pa2s = 2;
    fanvil-pa3 = 2;
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  line = n: key: "sip.line.${toString n}.${key}";

  # the endpoint of each of the model's lines, null for an unused one
  lineEndpoints = device: device.lines ++ lib.genList (_: null) (models.${device.model} - builtins.length device.lines);

  lineSettings = n: name:
    if name == null
    then {${line n "EnableReg"} = 0;}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in {
      ${line n "EnableReg"} = 1;
      # SIP user, sent as the user of From and To: Asterisk looks up the
      # endpoint by the From user and its aor by the To user
      ${line n "PhoneNumber"} = name;
      ${line n "RegisterUser"} = auth.username;
      ${line n "RegisterPswd"} = auth.password;
      ${line n "RegisterAddr"} = pcfg.sipServer;
      ${line n "RegisterPort"} = pcfg.sipPort;
    };

  commonSettings =
    {
      # this server, which the phone asks for `<mac>.cfg` after every reboot
      "ap.FlashServerIP" = "http://${format.hostPort pcfg.listenAddress (
        if pcfg.port == 80
        then null
        else pcfg.port
      )}";
      "ap.FlashFileName" = "$mac.cfg";
      "ap.FlashProtocol" = 4; # HTTP
      "ap.FlashMode" = 1; # update after reboot
      "ota.FDPSEnable" = 0; # Fanvil's redirection server, https://fdps.fanvil.com by default
    }
    // optionalAttrs (pcfg.ntpServer != null) {
      "phone.date.EnableSNTP" = 1;
      "phone.date.SNTPServer" = pcfg.ntpServer;
    }
    // optionalAttrs (pcfg.adminPassword != null) {
      # account 1 is the web interface's admin, level 10 an administrator
      "web.account.1.Name" = "admin";
      "web.account.1.Password" = pcfg.adminPassword;
      "web.account.1.Level" = 10;
    };

  deviceSettings = device:
    commonSettings
    // lib.mergeAttrsList (lib.imap1 lineSettings (lineEndpoints device))
    // cfg.settings
    // device.settings;

  # devices with a plain admin password that is not 1 to 39 letters and
  # digits, which every firmware takes; a secret is only known at runtime
  invalidAdminPasswords = attrNames (filterAttrs (_: device: let
    password = (commonSettings // cfg.settings // device.settings)."web.account.1.Password" or null;
  in
    password != null && !secrets.holdsSecret password && builtins.match "[A-Za-z0-9]{1,39}" (toString password) == null)
  devices);

  # a path of elements below <sysConf>, a number after an element being its
  # index: sip.line.1.PhoneNumber is <sip><line index="1"><PhoneNumber>
  element = "[A-Za-z_][A-Za-z0-9_-]*";
  badKeys = builtins.filter (key: builtins.match "(${element}([.][0-9]+)?[.])*${element}" key == null) (
    attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices)
  );

  # the settings of each device that `keys device values` picks, as
  # `<name> <key>`
  findKeys = keys:
    lib.concatLists (mapAttrsToList (name: device: map (key: "${name} ${key}") (keys device (deviceSettings device))) validDevices);

  controlCharacters = findKeys (_: values: builtins.filter (key: pbxLib.hasControlCharacter values.${key}) (attrNames values));

  # where the device registers and fetches its file
  wildcardServers = findKeys (device: values:
    builtins.filter (key: values ? ${key} && pbxLib.sendsToWildcard values.${key}) (
      ["ap.FlashServerIP"] ++ lib.genList (i: line (i + 1) "RegisterAddr") models.${device.model}
    ));

  # a key that is also the start of another can be no XML element
  nestedKeys = findKeys (_: values: let
    keys = attrNames values;
  in
    builtins.filter (key: builtins.any (other: lib.hasPrefix "${key}." other) keys) keys);

  # the first element of a key, its index and the key below it; a key with an
  # empty element is one element, and reported by an assertion
  splitKey = key: let
    m = builtins.match "([^.]+)([.]([0-9]+))?([.](.*))?" key;
  in
    if m == null
    then {
      name = key;
      index = null;
      rest = null;
    }
    else {
      name = builtins.elemAt m 0;
      index = builtins.elemAt m 2;
      rest = builtins.elemAt m 4;
    };

  # the elements of `values` at one depth, by name, then index
  renderElements = indent: values: let
    entries = mapAttrsToList (key: value: splitKey key // {inherit value;}) values;
    groups = lib.groupBy (e: e.name + optionalString (e.index != null) "#${e.index}") entries;
    index = e:
      if e.index == null
      then 0
      else lib.toIntBase10 e.index;
    before = a: b: let
      ea = builtins.head groups.${a};
      eb = builtins.head groups.${b};
    in
      if ea.name == eb.name
      then index ea < index eb
      else ea.name < eb.name;
    render = id: let
      group = groups.${id};
      e = builtins.head group;
      open = "${indent}<${e.name}${optionalString (e.index != null) " index=\"${e.index}\""}>";
      children = builtins.filter (c: c.rest != null) group;
    in
      if children == []
      then "${open}${pbxLib.phoneValueText pbxLib.escapeXml e.value}</${e.name}>\n"
      else "${open}\n${renderElements "${indent}  " (lib.listToAttrs (map (c: nameValuePair c.rest c.value) children))}${indent}</${e.name}>\n";
  in
    concatStrings (map render (lib.sort before (attrNames groups)));

  deviceXml = device: ''
    <?xml version="1.0" encoding="UTF-8"?>
    <sysConf>
    ${renderElements "  " (deviceSettings device)}</sysConf>
  '';
in {
  options.pbx.phones.fanvil.settings = mkOption {
    type = types.attrsOf pbxLib.phoneValue;
    default = {};
    example = {
      "phone.display.DefaultLanguage" = "en";
    };
    description = ''
      Settings for every Fanvil device, replacing the module's: paths of
      elements below `<sysConf>`, as in a configuration exported from the
      phone, with an element's index after it (`sip.line.1.DisplayName` is
      `<sip><line index="1"><DisplayName>`).
    '';
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: lines: {inherit lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = invalidAdminPasswords == [];
          message = "pbx.phones: the admin password (web.account.1.Password) of ${concatStringsSep ", " invalidAdminPasswords} is not 1 to 39 letters and digits, which is what every Fanvil firmware takes (the X1S, X1SG, X3SG, X3U and X305 take no symbols).";
        }
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.devices: Fanvil settings cannot contain control characters: ${concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = wildcardServers == [];
          message = "pbx.phones.devices: Fanvil settings that send devices to 0.0.0.0 or ::, which no device can reach: ${concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.\"ap.FlashServerIP\".";
        }
        {
          assertion = badKeys == [];
          message = "pbx.phones: settings of Fanvil devices must be paths of sysConf elements such as sip.line.1.DisplayName: ${concatStringsSep ", " (map builtins.toJSON badKeys)}.";
        }
        {
          assertion = nestedKeys == [];
          message = "pbx.phones.devices: Fanvil settings that other settings are below, which one XML element cannot be: ${concatStringsSep ", " nestedKeys}.";
        }
      ];

      pbx.phones.files = mapAttrs' (_: device:
        nameValuePair "${device.mac}.cfg" {
          text = deviceXml device;
          escape = "xml";
          inherit (device) allowedAddress;
        })
      validDevices;
    })
  ];
}
