# Provisioning for the Cisco 7942G and 7962G on SIP firmware: each device gets
# a `SEP<MAC>.cnf.xml` (the configuration Cisco's call manager writes) in which
# each line registers as its endpoint, served over HTTP on port 6970 too, from
# which the 9.x loads, SCCP and SIP, fetch every file. With `cisco.firmware`, a
# factory or SCCP phone that DHCP option 150 sends here also loads that SIP
# firmware. The directories button lists the extensions, from `directory.xml`
# in Cisco's phone service format, through the menu `directories.xml`.
#
# The elements are those a 7962G on SIP 9.4(2)SR3 took from a hand-written
# file, after the examples of github.com/lparakhin/-Cisco-7962G-SIP. Cisco
# documents the format only for its own call manager.
{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit
    (lib)
    attrNames
    attrValues
    concatStrings
    concatMapStrings
    filterAttrs
    mapAttrs'
    mapAttrsToList
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    optionalString
    types
    ;

  cfg = config.services.asterix.phones.cisco;
  pcfg = config.services.asterix.phones;
  acfg = config.services.asterisk;
  extensions = config.services.asterix.extensions;
  inherit ((import ../../../lib {inherit lib;}).format) hostPort;
  pbxLib = import ../lib.nix {inherit lib;};

  fileUrl = name: "http://${hostPort pcfg.listenAddress (
    if pcfg.port == 80
    then null
    else pcfg.port
  )}/${name}";

  # the extensions by name, then number
  entries = lib.sort (a: b: let
    x = lib.toLower a.name;
    y = lib.toLower b.name;
  in
    if x == y
    then a.number < b.number
    else x < y) (mapAttrsToList (number: e: {
      inherit number;
      inherit (e) name;
    })
    extensions);
  # a CiscoIPPhoneDirectory holds at most 32 entries (Cisco Unified IP Phone
  # Services Application Development Notes)
  maxEntries = 32;

  # `device` is Cisco's device type, which the default configuration keys a
  # model's load by, and `term` the load file a factory phone fetches
  models = {
    cisco-7942g = {
      lines = 2;
      device = 404;
      name = "Cisco 7942";
      term = "term42.default.loads";
    };
    cisco-7962g = {
      lines = 6;
      device = 434;
      name = "Cisco 7962";
      term = "term62.default.loads";
    };
  };

  devices = filterAttrs (_: device: models ? ${device.model}) pcfg.devices;
  validDevices = filterAttrs (_: device: models ? ${device.model}) pcfg.validDevices;
  modelsInUse = lib.unique (map (device: device.model) (attrValues validDevices));

  # endpoints the lines of these phones register as
  lineEndpoints = lib.unique (lib.concatMap (device: builtins.filter (name: name != null) device.lines) (attrValues devices));

  text = pbxLib.phoneValueText pbxLib.escapeXml;

  # the phone sends from a port of its own but names 5060 in Via without
  # asking for rport, and listens only there
  sendsRportless = name: let
    endpoint = acfg.pjsip.endpoints.${name} or null;
  in
    endpoint != null && !endpoint.behindNat && (endpoint.settings.force_rport or null) == false;

  line = n: name: let
    inherit (acfg.pjsip.endpoints.${name}) auth;
    displayName = extensions.${name}.name or name;
  in ''
    <line button="${toString n}">
      <featureID>9</featureID>
      <featureLabel>${text name}</featureLabel>
      <proxy>USECALLMANAGER</proxy>
      <port>${toString pcfg.sipPort}</port>
      <name>${text name}</name>
      <displayName>${text displayName}</displayName>
      <autoAnswer>
        <autoAnswerEnabled>2</autoAnswerEnabled>
      </autoAnswer>
      <callWaiting>3</callWaiting>
      <authName>${text auth.username}</authName>
      <authPassword>${text auth.password}</authPassword>
      <sharedLine>false</sharedLine>
      <messageWaitingLampPolicy>1</messageWaitingLampPolicy>
      <messagesNumber>${optionalString (config.services.asterix.voicemailMenu != null) (text config.services.asterix.voicemailMenu)}</messagesNumber>
      <ringSettingIdle>4</ringSettingIdle>
      <ringSettingActive>5</ringSettingActive>
      <contact>${text name}</contact>
      <forwardCallInfoDisplay>
        <callerName>true</callerName>
        <callerNumber>true</callerNumber>
        <redirectedNumber>false</redirectedNumber>
        <dialedNumber>true</dialedNumber>
      </forwardCallInfoDisplay>
    </line>
  '';

  callManager = ''
    <callManagerGroup>
      <members>
        <member priority="0">
          <callManager>
            <ports>
              <ethernetPhonePort>2000</ethernetPhonePort>
              <sipPort>${toString pcfg.sipPort}</sipPort>
            </ports>
            <processNodeName>${text pcfg.sipServer}</processNodeName>
          </callManager>
        </member>
      </members>
    </callManagerGroup>
  '';

  # `s` without its last line break, each line indented by `spaces`
  block = spaces: s: lib.concatMapStringsSep "\n" (l: lib.fixedWidthString spaces " " "" + l) (lib.splitString "\n" (lib.removeSuffix "\n" s));

  ntps = ''
    <ntps>
      <ntp>
        <name>${text pcfg.ntpServer}</name>
        <ntpMode>Unicast</ntpMode>
      </ntp>
    </ntps>
  '';

  deviceXml = device: ''
    <device>
      <deviceProtocol>SIP</deviceProtocol>
      <devicePool>
        <dateTimeSetting>
          <dateTemplate>M/D/Ya</dateTemplate>
    ${optionalString (cfg.timeZone != null) "      <timeZone>${text cfg.timeZone}</timeZone>\n"}${optionalString (pcfg.ntpServer != null) "${block 6 ntps}\n"}    </dateTimeSetting>
    ${block 4 callManager}
      </devicePool>
      <sipProfile>
        <sipProxies>
          <registerWithProxy>true</registerWithProxy>
        </sipProxies>
        <sipCallFeatures>
          <cnfJoinEnabled>true</cnfJoinEnabled>
          <rfc2543Hold>false</rfc2543Hold>
          <callHoldRingback>2</callHoldRingback>
          <localCfwdEnable>true</localCfwdEnable>
          <semiAttendedTransfer>true</semiAttendedTransfer>
          <anonymousCallBlock>2</anonymousCallBlock>
          <callerIdBlocking>2</callerIdBlocking>
          <dndControl>0</dndControl>
          <remoteCcEnable>true</remoteCcEnable>
        </sipCallFeatures>
        <sipStack>
          <sipInviteRetx>6</sipInviteRetx>
          <sipRetx>10</sipRetx>
          <timerInviteExpires>180</timerInviteExpires>
          <timerRegisterExpires>3600</timerRegisterExpires>
          <timerRegisterDelta>5</timerRegisterDelta>
          <timerKeepAliveExpires>120</timerKeepAliveExpires>
          <timerSubscribeExpires>120</timerSubscribeExpires>
          <timerSubscribeDelta>5</timerSubscribeDelta>
          <timerT1>500</timerT1>
          <timerT2>4000</timerT2>
          <maxRedirects>70</maxRedirects>
          <remotePartyID>true</remotePartyID>
          <userInfo>None</userInfo>
        </sipStack>
        <autoAnswerTimer>1</autoAnswerTimer>
        <autoAnswerAltBehavior>false</autoAnswerAltBehavior>
        <autoAnswerOverride>true</autoAnswerOverride>
        <transferOnhookEnabled>false</transferOnhookEnabled>
        <enableVad>false</enableVad>
        <preferredCodec>none</preferredCodec>
        <dtmfAvtPayload>101</dtmfAvtPayload>
        <dtmfDbLevel>3</dtmfDbLevel>
        <dtmfOutofBand>avt</dtmfOutofBand>
        <alwaysUsePrimeLine>false</alwaysUsePrimeLine>
        <alwaysUsePrimeLineVoiceMail>false</alwaysUsePrimeLineVoiceMail>
        <kpml>3</kpml>
        <natEnabled>false</natEnabled>
        <phoneLabel>${text (lib.findFirst (name: name != null) "" device.lines)}</phoneLabel>
        <stutterMsgWaiting>0</stutterMsgWaiting>
        <callStats>false</callStats>
        <silentPeriodBetweenCallWaitingBursts>10</silentPeriodBetweenCallWaitingBursts>
        <disableLocalSpeedDialConfig>false</disableLocalSpeedDialConfig>
        <startMediaPort>10000</startMediaPort>
        <stopMediaPort>20000</stopMediaPort>
        <sipLines>
    ${block 6 (concatStrings (lib.imap1 (n: name: optionalString (name != null) (line n name)) device.lines))}
        </sipLines>
        <voipControlPort>${toString pcfg.sipPort}</voipControlPort>
        <dscpForAudio>184</dscpForAudio>
        <ringSettingBusyStationPolicy>0</ringSettingBusyStationPolicy>
        <dialTemplate>dialplan.xml</dialTemplate>
      </sipProfile>
      <commonProfile>
        <backgroundImageAccess>true</backgroundImageAccess>
        <callLogBlfEnabled>1</callLogBlfEnabled>
      </commonProfile>
    ${optionalString (cfg.firmware != null) "  <loadInformation>${text cfg.firmware.load}</loadInformation>\n"}  <vendorConfig>
        <disableSpeaker>false</disableSpeaker>
        <disableSpeakerAndHeadset>false</disableSpeakerAndHeadset>
        <pcPort>0</pcPort>
        <settingsAccess>1</settingsAccess>
        <garp>0</garp>
        <voiceVlanAccess>0</voiceVlanAccess>
        <videoCapability>0</videoCapability>
        <autoSelectLineEnable>0</autoSelectLineEnable>
        <webAccess>0</webAccess>
        <spanToPCPort>1</spanToPCPort>
        <loggingDisplay>1</loggingDisplay>
        <loadServer></loadServer>
        <sshAccess>1</sshAccess>
        <g722CodecSupport>2</g722CodecSupport>
        <handsetWidebandEnable>1</handsetWidebandEnable>
        <headsetWidebandEnable>1</headsetWidebandEnable>
      </vendorConfig>
      <versionStamp>1</versionStamp>
      <deviceSecurityMode>1</deviceSecurityMode>
      <transportLayerProtocol>2</transportLayerProtocol>
      <dialToneSetting>2</dialToneSetting>
      <encrConfig>false</encrConfig>
      <advertiseG722Codec>1</advertiseG722Codec>
      <directoryURL>${text (fileUrl "directories.xml")}</directoryURL>
    </device>
  '';

  # the phone adds the items of the menu at directoryURL under its call logs,
  # and shows nothing for a directory there
  directoriesXml = ''
    <CiscoIPPhoneMenu>
      <Title>Directories</Title>
      <Prompt>Select a directory</Prompt>
      <MenuItem>
        <Name>Extensions</Name>
        <URL>${text (fileUrl "directory.xml")}</URL>
      </MenuItem>
    </CiscoIPPhoneMenu>
  '';

  directoryXml = ''
    <CiscoIPPhoneDirectory>
      <Title>Extensions</Title>
      <Prompt>Select an entry</Prompt>
    ${block 2 (concatMapStrings (e: ''
        <DirectoryEntry>
          <Name>${text e.name}</Name>
          <Telephone>${text e.number}</Telephone>
        </DirectoryEntry>
      '')
      entries)}
    </CiscoIPPhoneDirectory>
  '';

  # what a phone with no file of its own takes, and the load of each model
  defaultXml = ''
    <Default>
    ${block 2 callManager}
    ${optionalString (cfg.firmware != null) (concatMapStrings (model: "  <loadInformation${toString models.${model}.device} model=\"${models.${model}.name}\">${text cfg.firmware.load}</loadInformation${toString models.${model}.device}>\n") modelsInUse)}</Default>
  '';

  # the numbers phones dial: those that start no other number go out at the
  # last digit, the others after a pause, as does anything else. * is the
  # template's wildcard, so a * in a number is escaped
  numbers = builtins.filter (n: builtins.match "[0-9*#]+" n != null) (attrNames (acfg.dialplan.contexts.pbx-internal.extensions or {}));
  startsAnother = n: builtins.any (other: other != n && lib.hasPrefix n other) numbers;
  dialTemplate = ''
    <DIALTEMPLATE>
    ${concatMapStrings (n: "  <TEMPLATE MATCH=\"${lib.replaceStrings ["*"] ["\\*"] n}\" Timeout=\"${
        if startsAnother n
        then "3"
        else "0"
      }\"/>\n")
      numbers}  <TEMPLATE MATCH="*" Timeout="3"/>
    </DIALTEMPLATE>
  '';

  # the load files and every image they name; the images are listed in a
  # signed binary file, as file names in plain text
  firmwareCheck = pkgs.runCommand "pbx-cisco-79xx-firmware" {} ''
    dir=${cfg.firmware.directory}
    for loads in ${lib.escapeShellArgs (["${cfg.firmware.load}.loads"] ++ map (model: models.${model}.term) modelsInUse)}; do
      if [ ! -f "$dir/$loads" ]; then
        echo "services.asterix.phones.cisco.firmware.directory has no $loads" >&2
        exit 1
      fi
      for image in $(grep -aoE '[A-Za-z0-9_.-]+\.sbn' "$dir/$loads"); do
        if [ ! -f "$dir/$image" ]; then
          echo "services.asterix.phones.cisco.firmware.directory has no $image, which $loads names" >&2
          exit 1
        fi
      done
    done
    touch $out
  '';
in {
  options.services.asterix.phones.cisco = {
    firmware = mkOption {
      type = types.nullOr (types.submodule {
        options = {
          load = mkOption {
            type = types.strMatching "[A-Za-z0-9_.-]+";
            example = "SIP42.9-4-2SR3-1S";
            description = "Name of the SIP load, the name of its `.loads` file without the extension.";
          };
          directory = mkOption {
            type = types.path;
            description = "Directory with the files of Cisco's firmware zip for the 7942G and 7962G: the load's `.loads` file, `term42.default.loads`, `term62.default.loads` and the `.sbn` images.";
          };
        };
      });
      default = null;
      description = ''
        SIP firmware for the 7942G and 7962G. A phone that runs another load,
        SCCP included, loads this one, and a factory reset phone takes it
        from the `term` load file. Without it, these phones must already run
        SIP firmware.
      '';
    };

    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "Pacific Standard/Daylight Time";
      description = "Time zone of the 7942G and 7962G, in the names of Cisco's call manager. When null, they keep their default.";
    };
  };

  config = mkMerge [
    {services.asterix.phones.models = lib.mapAttrs (_: model: {inherit (model) lines;}) models;}

    (mkIf (devices != {}) {
      assertions = [
        {
          assertion = builtins.all (device: device.settings == {}) (attrValues devices);
          message = "services.asterix.phones.devices: the 7942G and 7962G take no settings.";
        }
        {
          assertion = builtins.all sendsRportless (builtins.filter (name: acfg.pjsip.endpoints ? ${name}) lineEndpoints);
          message = "services.asterix.phones.devices: the endpoints of these 7942G and 7962G lines need force_rport off, without behindNat, since the phone listens only on the port it names in Via: ${
            lib.concatStringsSep ", " (builtins.filter (name: acfg.pjsip.endpoints ? ${name} && !sendsRportless name) lineEndpoints)
          }.";
        }
      ];

      # an extension the phone registers as answers on the port it names
      services.asterisk.pjsip.endpoints = lib.genAttrs (builtins.filter (name: extensions ? ${name}) lineEndpoints) (_: {
        settings = {
          force_rport = mkDefault false;
          rewrite_contact = mkDefault false;
        };
      });

      services.asterix.phones = {
        httpPorts = [6970];
        directories = lib.optional (cfg.firmware != null) cfg.firmware.directory;
        files =
          mapAttrs' (_: device:
            nameValuePair "SEP${lib.toUpper device.mac}.cnf.xml" {
              text = deviceXml device;
              escape = "xml";
              inherit (device) allowedAddress;
            })
          validDevices
          // {
            "XMLDefault.cnf.xml".text = defaultXml;
            "dialplan.xml".text = dialTemplate;
            "directories.xml".text = directoriesXml;
            "directory.xml".text = directoryXml;
          };
      };

      warnings = lib.optional (builtins.length entries > maxEntries) "services.asterix.phones: the 7942G and 7962G show at most ${toString maxEntries} entries of a directory, so their directories button lists only the first ${toString maxEntries} of ${toString (builtins.length entries)} extensions by name.";

      system.checks = lib.optional (cfg.firmware != null) firmwareCheck;
    })
  ];
}
