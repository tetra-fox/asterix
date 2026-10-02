# Provisioning for Poly (formerly Polycom) VVX phones on UC Software and Edge
# E phones on PVOS: each pbx.phones device of one of these models gets a master
# configuration file `<mac>.cfg` whose CONFIG_FILES names `<mac>-settings.cfg`,
# which holds the phone's parameters, and each line, a registration, registers
# as its endpoint.
#
# Every parameter set here is in Poly's documentation of the models that get
# it: UC Software 6.4.0 Administrator Guide (3725-42644-012A) for VVX, Poly
# Edge E Series Phones Parameter Reference Guide PVOS 8.2.1 and Administrator
# Guide PVOS 8.5.0 for Edge E, and Best Practices 35361 (Provisioning with the
# Master Configuration File) for the master file.
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
    mapAttrsToList
    mkIf
    mkMerge
    mkOption
    optionalAttrs
    types
    ;

  cfg = config.pbx.phones.poly;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  pbxLib = import ../lib.nix {inherit lib;};

  # cloud services that UC Software has a switch for and the Edge E guides
  # do not document, all off
  vvx = lines: {
    inherit lines;
    shared = {
      "device.prov.ztpEnabled" = 0; # zero-touch provisioning through Poly's ZTP server
      "device.prov.ztpEnabled.set" = 1;
      "feature.lens.enabled" = 0; # Poly Lens
      "feature.pcc.enabled" = 0; # Polycom Cloud Connector
    };
  };
  edge = lines: {
    inherit lines;
    shared = {};
  };

  # lines are registrations, as many as Poly's tables of maximum registrations
  # per model give
  models = {
    poly-vvx101 = vvx 1;
    poly-vvx150 = vvx 2;
    poly-vvx201 = vvx 2;
    poly-vvx250 = vvx 34;
    poly-vvx301 = vvx 34;
    poly-vvx311 = vvx 34;
    poly-vvx350 = vvx 34;
    poly-vvx401 = vvx 34;
    poly-vvx411 = vvx 34;
    poly-vvx450 = vvx 34;
    poly-vvx501 = vvx 34;
    poly-vvx601 = vvx 34;
    poly-edge-e100 = edge 8;
    poly-edge-e220 = edge 16;
    poly-edge-e300 = edge 32;
    poly-edge-e320 = edge 32;
    poly-edge-e350 = edge 32;
    poly-edge-e400 = edge 34;
    poly-edge-e450 = edge 34;
    poly-edge-e500 = edge 34;
    poly-edge-e550 = edge 34;
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  # the endpoint of each of the model's registrations, null for an unused one
  lineEndpoints = device: device.lines ++ lib.genList (_: null) (models.${device.model}.lines - builtins.length device.lines);

  lineSettings = n: name: let
    reg = key: "reg.${toString n}.${key}";
  in
    # a registration without an address is not used
    if name == null
    then {${reg "address"} = "";}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in {
      # the user of the From and To URIs: Asterisk looks up the endpoint by
      # the From user and its aor by the To user
      ${reg "address"} = name;
      ${reg "auth.userId"} = auth.username;
      ${reg "auth.password"} = auth.password;
      ${reg "server.1.address"} = pcfg.sipServer;
      ${reg "server.1.port"} = pcfg.sipPort;
    };

  # device.* parameters only apply with device.set and their own .set
  commonSettings =
    {
      "device.set" = 1;
      # OpenSIP, rather than a Skype for Business, Teams or Zoom profile
      "device.baseProfile" = "Generic";
      "device.baseProfile.set" = 1;
      # this server, so the phone keeps coming back here when DHCP names none
      "device.prov.serverName" = "http://${format.hostPort pcfg.listenAddress (
        if pcfg.port == 80
        then null
        else pcfg.port
      )}";
      "device.prov.serverName.set" = 1;
      "device.prov.serverType" = "HTTP";
      "device.prov.serverType.set" = 1;
      "feature.da.enabled" = 0; # device analytics, sent to Poly's cloud
      "feature.obitalk.enabled" = 0; # the OBiTALK cloud, for Poly's device management service
    }
    // optionalAttrs (pcfg.adminPassword != null) {
      "device.auth.localAdminPassword" = pcfg.adminPassword;
      "device.auth.localAdminPassword.set" = 1;
    }
    // optionalAttrs (pcfg.ntpServer != null) {
      "tcpIpApp.sntp.address" = pcfg.ntpServer;
      "tcpIpApp.sntp.address.overrideDHCP" = 1;
    };

  deviceSettings = device:
    commonSettings
    // models.${device.model}.shared
    // lib.mergeAttrsList (lib.imap1 lineSettings (lineEndpoints device))
    // cfg.settings
    // device.settings;

  # phones with a plain admin password that is not 1 to 32 characters of
  # ASCII without < and >, or is 456, the factory default; a secret is only
  # known at runtime
  invalidAdminPasswords = attrNames (filterAttrs (_: device: let
    password = (commonSettings // cfg.settings // device.settings)."device.auth.localAdminPassword" or null;
  in
    password != null && !secrets.holdsSecret password && (builtins.match "[ -;=?-~]{1,32}" (toString password) == null || toString password == "456"))
  devices);

  # parameter names, which are XML attribute names in the file
  invalidKeys = lib.unique (builtins.filter (key: builtins.match "[A-Za-z][A-Za-z0-9_-]*([.][A-Za-z0-9_-]+)*" key == null) (
    attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices)
  ));

  # the parameters of each phone that match `predicate`, as `<name> <parameter>`
  findValues = predicate: keyPredicate:
    lib.concatLists (mapAttrsToList (name: device: let
      values = deviceSettings device;
    in
      map (key: "${name} ${key}") (builtins.filter (key: keyPredicate key && predicate values.${key}) (lib.naturalSort (attrNames values))))
    validDevices);

  controlCharacters = findValues pbxLib.hasControlCharacter (_: true);

  # where the phone fetches its files and registers
  wildcardServers = findValues pbxLib.sendsToWildcard (key: key == "device.prov.serverName" || builtins.match "reg[.][0-9]+[.]server[.][0-9]+[.]address" key != null);

  settingsFile = device: "${device.mac}-settings.cfg";

  # the phone looks for new software at sip.ld, and <part number>.sip.ld, on
  # this server
  masterXml = device: ''
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <APPLICATION APP_FILE_PATH="sip.ld" CONFIG_FILES="${settingsFile device}"/>
  '';

  # parameters are attributes, of an element whose name the phone ignores
  settingsXml = device: let
    values = deviceSettings device;
  in
    ''
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <polycomConfig
    ''
    + concatStrings (map (key: "  ${key}=\"${pbxLib.phoneValueText pbxLib.escapeXml values.${key}}\"\n") (lib.naturalSort (attrNames values)))
    + "/>\n";
in {
  options.pbx.phones.poly.settings = mkOption {
    type = types.attrsOf pbxLib.phoneValue;
    default = {};
    example = {
      "lcl.ml.lang" = "German_Germany";
    };
    description = "Parameters for every Poly device, replacing the module's.";
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: model: {inherit (model) lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = invalidAdminPasswords == [];
          message = "pbx.phones: the admin password (device.auth.localAdminPassword) of ${lib.concatStringsSep ", " invalidAdminPasswords} is not 1 to 32 characters of ASCII without < and >, or is 456, the factory default, none of which Poly phones take.";
        }
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.devices: Poly parameters cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = wildcardServers == [];
          message = "pbx.phones.devices: Poly parameters that send phones to 0.0.0.0 or ::, which no phone can reach: ${lib.concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the phones' network, or give that address in pbx.phones.sipServer and settings.\"device.prov.serverName\".";
        }
        {
          assertion = invalidKeys == [];
          message = "pbx.phones: settings of Poly devices must be parameter names such as reg.1.label, parts of letters, digits, _ and - separated by dots and starting with a letter: ${lib.concatMapStringsSep ", " builtins.toJSON invalidKeys}.";
        }
      ];

      pbx.phones.files =
        lib.concatMapAttrs (_: device: {
          "${device.mac}.cfg" = {
            text = masterXml device;
            escape = "xml";
            inherit (device) allowedAddress;
          };
          ${settingsFile device} = {
            text = settingsXml device;
            escape = "xml";
            inherit (device) allowedAddress;
          };
        })
        validDevices;
    })
  ];
}
