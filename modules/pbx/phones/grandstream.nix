# Provisioning for Grandstream analog adapters and phones: each pbx.phones
# device of one of these models gets a `cfg<mac>.xml` (Grandstream's
# gs_provision format) in which each line, an adapter's phone port or a
# phone's SIP account, registers as its endpoint.
#
# Every P-value set here is in Grandstream's configuration templates for the
# models that use it, for every hardware version (config-template.zip from
# grandstream.com/support/tools: ht80x 1.0.65.3, ht80x_v2 1.0.15.3, ht81x
# 1.0.65.3, ht81x_v2 1.0.15.3, ht813 1.0.19.6, ht818 1.0.65.1, gxp16xx
# 1.0.7.81, gxp17xx 1.0.1.133, gxp2130_40_60_70_35 1.0.11.106, grp260x
# 1.0.7.71, grp26xx 1.0.15.19, wp810_822_825 1.0.11.83, wp8x6 1.0.3.39, wp820
# 1.0.7.90, wp856 1.0.3.16, ghp6xx 1.0.1.101, ghp63x 1.0.1.50, gxv34x0
# 1.0.5.40, gxv33xx 1.0.3.57). A phone's lines are the SIP accounts that its
# template and its datasheet give the model, the smaller number where they
# differ.
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

  cfg = config.pbx.phones.grandstream;
  pcfg = config.pbx.phones;
  acfg = config.services.asterisk;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  pbxLib = import ../lib.nix {inherit lib;};

  # SIP account 1 of every model, an adapter's port 1
  account1 = {
    active = "P271";
    server = "P47";
    user = "P35";
    auth = "P36";
    password = "P34";
  };

  # the HT802's second port, which has the second account
  ht802Port2 = {
    active = "P401";
    server = "P747";
    user = "P735";
    auth = "P736";
    password = "P734";
  };

  # a phone's account whose P-values follow `base`: P401 to P406 for account 2
  phoneAccount = base: let
    p = n: "P${toString (base + n)}";
  in {
    active = p 1;
    server = p 2;
    user = p 4;
    auth = p 5;
    password = p 6;
  };

  # a phone's accounts from 1: accounts 2 to 4 follow P400, P500 and P600, 5
  # and 6 P1700 and P1800, 7 to 16 P50600 to P51500
  phoneAccounts = [account1] ++ map phoneAccount ([400 500 600 1700 1800] ++ lib.genList (i: 50600 + 100 * i) 10);

  # the GRP260x has accounts 5 and 6 at P701 and P801
  grp260xAccounts = [account1] ++ map phoneAccount [400 500 600 700 800];

  # the P-values of port i + 1 of an adapter whose ports all register to the
  # SIP server of profile 1
  profilePort = i: let
    p = first: "P${toString (first + i)}";
  in {
    active = p 4595;
    user = p 4060;
    auth = p 4090;
    password = p 4120;
    profile = p 4150;
  };

  # the time zone, in the strings that the adapters' and the phones' templates
  # list, except the Android ones'
  zone = optionalAttrs (cfg.timeZone != null) {P64 = cfg.timeZone;};

  # TR-069 off (Grandstream's GDMS cloud by default)
  noTr069 = {P1409 = 0;};

  # an adapter whose ports have SIP accounts of their own
  withAccounts = count: {
    lines = lib.take count [account1 ht802Port2];
    shared = zone // noTr069;
    adapter = true;
  };
  withProfile = count: {
    lines = lib.genList profilePort count;
    shared =
      zone
      // noTr069
      // {
        P271 = 1; # profile 1 active
        P47 = pbxLib.sipServerText pcfg; # its primary SIP server
      };
    adapter = true;
  };

  phone = accounts: count: {
    lines = lib.take count accounts;
    shared = zone // noTr069;
    adapter = false;
  };
  # gxp16xx and gxp17xx have no TR-069 setting
  gxp = count: phone phoneAccounts count // {shared = zone;};
  # the Android phones take zone names such as Europe/Berlin in P64
  android = count: phone phoneAccounts count // {shared = noTr069;};

  # W, P and G variants (Wi-Fi, PoE, gigabit) are the model they extend,
  # except the GRP2613W, which has more accounts than the GRP2613
  models = {
    grandstream-ht801 = withAccounts 1;
    grandstream-ht802 = withAccounts 2;
    # the phone port; the FXO port, for a phone company line, has the second
    # account, which is left alone
    grandstream-ht813 = withAccounts 1;
    grandstream-ht812 = withProfile 2;
    grandstream-ht814 = withProfile 4;
    grandstream-ht818 = withProfile 8;

    grandstream-gxp1610 = gxp 1;
    grandstream-gxp1615 = gxp 1;
    grandstream-gxp1620 = gxp 2;
    grandstream-gxp1625 = gxp 2;
    grandstream-gxp1628 = gxp 2;
    grandstream-gxp1630 = gxp 3;
    grandstream-gxp1760 = gxp 3;
    grandstream-gxp1780 = gxp 4;
    grandstream-gxp1782 = gxp 4;

    grandstream-gxp2130 = phone phoneAccounts 3;
    grandstream-gxp2135 = phone phoneAccounts 4;
    grandstream-gxp2140 = phone phoneAccounts 4;
    grandstream-gxp2160 = phone phoneAccounts 6;
    grandstream-gxp2170 = phone phoneAccounts 6;

    grandstream-grp2601 = phone grp260xAccounts 2;
    grandstream-grp2602 = phone grp260xAccounts 4;
    grandstream-grp2603 = phone grp260xAccounts 6;
    grandstream-grp2604 = phone grp260xAccounts 6;

    grandstream-grp2610 = phone phoneAccounts 2;
    grandstream-grp2611g = phone phoneAccounts 3;
    grandstream-grp2612 = phone phoneAccounts 4;
    grandstream-grp2613 = phone phoneAccounts 4;
    grandstream-grp2613w = phone phoneAccounts 6;
    grandstream-grp2614 = phone phoneAccounts 12;
    grandstream-grp2615 = phone phoneAccounts 16;
    grandstream-grp2616 = phone phoneAccounts 16;
    grandstream-grp2624 = phone phoneAccounts 12;
    grandstream-grp2634 = phone phoneAccounts 12;
    grandstream-grp2636 = phone phoneAccounts 16;
    grandstream-grp2650 = phone phoneAccounts 16;
    grandstream-grp2670 = phone phoneAccounts 16;

    grandstream-wp810 = phone phoneAccounts 2;
    grandstream-wp822 = phone phoneAccounts 2;
    grandstream-wp825 = phone phoneAccounts 2;
    grandstream-wp816 = phone phoneAccounts 2;
    grandstream-wp826 = phone phoneAccounts 3;
    grandstream-wp836 = phone phoneAccounts 3;

    grandstream-ghp610 = phone phoneAccounts 2;
    grandstream-ghp611 = phone phoneAccounts 2;
    grandstream-ghp620 = phone phoneAccounts 2;
    grandstream-ghp621 = phone phoneAccounts 2;
    grandstream-ghp630 = phone phoneAccounts 2;
    grandstream-ghp631 = phone phoneAccounts 2;

    grandstream-wp820 = android 2;
    grandstream-wp856 = android 6;
    grandstream-gxv3350 = android 16;
    grandstream-gxv3370 = android 16;
    grandstream-gxv3380 = android 16;
    grandstream-gxv3450 = android 16;
    grandstream-gxv3470 = android 16;
    grandstream-gxv3480 = android 16;
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;

  # the endpoint of each of the model's lines, null for an unused one
  lineEndpoints = device: let
    count = builtins.length models.${device.model}.lines;
  in
    device.lines ++ lib.genList (_: null) (count - builtins.length device.lines);

  lineSettings = line: name:
    if name == null
    then {${line.active} = 0;}
    else let
      inherit (acfg.pjsip.endpoints.${name}) auth;
    in
      {
        ${line.active} = 1;
        # SIP user ID, sent as the user of From and To: Asterisk looks up the
        # endpoint by the From user and its aor by the To user
        ${line.user} = name;
        ${line.auth} = auth.username;
        ${line.password} = auth.password;
      }
      // optionalAttrs (line ? server) {${line.server} = pbxLib.sipServerText pcfg;}
      // optionalAttrs (line ? profile) {${line.profile} = 0;}; # profile 1

  commonSettings = filterAttrs (_: v: v != null) {
    P30 = pcfg.ntpServer; # NTP server
    P2 = pcfg.adminPassword; # admin password of the web interface
    P212 = 1; # config upgrade via HTTP
    # config server path: this server, so the device keeps coming back here
    P237 = format.hostPort pcfg.listenAddress (
      if pcfg.port == 80
      then null
      else pcfg.port
    );
    P238 = 2; # always skip the firmware check (Grandstream's server by default)
  };

  deviceSettings = device: let
    model = models.${device.model};
  in
    commonSettings
    // model.shared
    // lib.mergeAttrsList (lib.zipListsWith lineSettings model.lines (lineEndpoints device))
    // cfg.settings
    // device.settings;

  # adapters with a plain admin password (P2) that is not 4 to 30 characters
  # (V2 hardware) from ! to ~ (V1 hardware); a secret is only known at runtime
  invalidAdminPasswords = attrNames (filterAttrs (_: device: let
    p2 = (commonSettings // cfg.settings // device.settings).P2 or null;
  in
    models.${device.model}.adapter && p2 != null && !secrets.holdsSecret p2 && builtins.match "[!-~]{4,30}" (toString p2) == null)
  devices);

  # numeric order; keys that are not P-values are reported by an assertion
  pNumber = p: let
    m = builtins.match "P([0-9]+)" p;
  in
    if m == null
    then 0
    else lib.toInt (builtins.head m);
  sortedKeys = values: lib.sort (a: b: pNumber a < pNumber b) (attrNames values);

  # the P-values of each device that match `predicate`, as `<name> <P-value>`,
  # out of `keys device values`
  findValues = predicate: keys:
    lib.concatLists (mapAttrsToList (name: device: let
      values = deviceSettings device;
    in
      map (p: "${name} ${p}") (builtins.filter (p: values ? ${p} && predicate values.${p}) (keys device values)))
    validDevices);

  controlCharacters = findValues pbxLib.hasControlCharacter (_: sortedKeys);

  # where the device registers, P47 being profile 1's server on the HT812,
  # HT814 and HT818, and where it fetches its file
  serverKeys = device: ["P47" "P237"] ++ map (line: line.server) (builtins.filter (line: line ? server) models.${device.model}.lines);
  wildcardServers = findValues pbxLib.sendsToWildcard (device: values: builtins.filter (p: builtins.elem p (serverKeys device)) (sortedKeys values));

  deviceXml = device: let
    values = deviceSettings device;
  in ''
    <?xml version="1.0" encoding="UTF-8"?>
    <gs_provision version="1">
      <mac>${device.mac}</mac>
      <config version="1">
    ${concatStrings (map (p: "    <${p}>${pbxLib.phoneValueText pbxLib.escapeXml values.${p}}</${p}>\n") (sortedKeys values))}  </config>
    </gs_provision>
  '';
in {
  imports = [
    (lib.mkRemovedOptionModule ["pbx" "phones" "grandstream" "ht801"] "Grandstream adapters moved to pbx.phones.devices, each with a model: devices.\"101\" = { model = \"grandstream-ht801\"; mac = \"...\"; }. sipServer, ntpServer and adminPassword moved to pbx.phones, timeZone and settings to pbx.phones.grandstream.")
  ];

  options.pbx.phones.grandstream = {
    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
      description = "Time zone of the Grandstream devices (P64), one of the values listed in their templates; `null` keeps their default. The Android phones (GXV33xx, GXV34xx, WP820, WP856) take zone names such as `Europe/Berlin` instead and get theirs only from `settings`.";
    };

    settings = mkOption {
      type = types.attrsOf pbxLib.phoneValue;
      default = {};
      example = {
        P1362 = "en";
      };
      description = "P-values for every Grandstream device, replacing the module's.";
    };
  };

  config = mkMerge [
    {pbx.phones.models = lib.mapAttrs (_: model: {lines = builtins.length model.lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = invalidAdminPasswords == [];
          message = "pbx.phones: the admin password (P2) of ${lib.concatStringsSep ", " invalidAdminPasswords} is not 4 to 30 characters from ASCII 33 (!) to 126 (~), which Grandstream's V2 hardware requires of the length and V1 hardware of the characters.";
        }
        {
          assertion = controlCharacters == [];
          message = "pbx.phones.devices: P-values cannot contain control characters: ${lib.concatStringsSep ", " controlCharacters}.";
        }
        {
          assertion = wildcardServers == [];
          message = "pbx.phones.devices: P-values that send devices to 0.0.0.0 or ::, which no device can reach: ${lib.concatStringsSep ", " wildcardServers}. Set pbx.phones.listenAddress to the PBX's address on the devices' network, or give that address in pbx.phones.sipServer and settings.P237.";
        }
        {
          assertion = builtins.all (p: builtins.match "P[0-9]+" p != null) (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues devices)
          );
          message = "pbx.phones: settings of Grandstream devices must be P-values such as P1362.";
        }
      ];

      pbx.phones.files = mapAttrs' (_: device:
        nameValuePair "cfg${device.mac}.xml" {
          text = deviceXml device;
          escape = "xml";
          inherit (device) allowedAddress;
        })
      validDevices;
    })
  ];
}
