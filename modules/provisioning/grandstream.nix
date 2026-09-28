# Provisioning for Grandstream phones (GRP260x, GRP261x/262x/263x, GXP16xx,
# GXP21xx and similar): serves `cfg<MAC>.xml` in Grandstream's gs_provision
# format over HTTP from nginx.
#
# Each phone is tied to an endpoint of services.asterisk-declarative.pjsip, and
# its SIP credentials are taken from there. Files contain passwords, so they
# are rendered at runtime into a tmpfs with the same secret mechanism as
# Asterisk's configuration; the store only holds placeholders. Secrets given
# as systemd credentials (`credential "name"`) must also be loaded into
# grandstream-provisioning.service.
#
# P-values were checked against Grandstream's configuration templates
# (config-template.zip from grandstream.com/support/tools: GRP260x 1.0.7.71,
# GRP261x/2x/3x/5x/7x 1.0.15.8, GXP16xx 1.0.7.81, GXP2130/40/60/70/35
# 1.0.11.106). Other vendors can be added as sibling modules under
# services.asterisk-declarative.provisioning.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    attrNames
    attrValues
    concatMapStringsSep
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
    optional
    optionalAttrs
    toLower
    types
    unique
    ;

  cfg = config.services.asterisk-declarative.provisioning.grandstream;
  acfg = config.services.asterisk-declarative;
  asteriskLib = import ../../lib { inherit lib; };
  inherit (asteriskLib) format secrets;

  runtimeDir = "/run/grandstream-provisioning";

  valueType =
    types.oneOf [
      types.str
      types.int
      format.types.secret
    ]
    // {
      description = "string, integer or secret reference";
    };

  phoneType = types.submodule (
    { name, ... }:
    {
      options = {
        mac = mkOption {
          type = types.strMatching "([0-9a-fA-F]{2}[:-]?){5}[0-9a-fA-F]{2}";
          example = "00:0b:82:12:34:56";
          description = "MAC address of the phone (any of the usual notations).";
        };
        endpoint = mkOption {
          type = types.str;
          default = name;
          defaultText = literalExpression "<name>";
          description = ''
            Endpoint in {option}`services.asterisk-declarative.pjsip.endpoints`
            whose credentials the phone registers with.
          '';
        };
        displayName = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Name on the phone's display (P3); defaults to the name in the endpoint's caller ID.";
        };
        allowedAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10.0.20.21";
          description = ''
            Only this address may download the phone's file, which contains its
            SIP password. Use it together with a static DHCP lease.
          '';
        };
        settings = mkOption {
          type = types.attrsOf valueType;
          default = { };
          example = {
            P1362 = "de";
          };
          description = "Additional P-values for this phone, overriding the common ones.";
        };
      };
    }
  );

  normalizeMac = mac: toLower (lib.replaceStrings [ ":" "-" ] [ "" "" ] mac);

  # "Kitchen" <101>  ->  Kitchen
  callerIdName =
    callerId:
    let
      m = builtins.match ''[[:space:]]*"([^"]*)".*'' callerId;
    in
    if m == null then null else builtins.head m;

  endpointOf = phone: acfg.pjsip.endpoints.${phone.endpoint} or null;

  # Common P-values (see the templates named above).
  commonSettings = filterAttrs (_: v: v != null) (
    {
      P47 = cfg.sipServer; # SIP server
      P30 = cfg.ntpServer; # NTP server
      P64 = cfg.timeZone; # time zone
      P298 = if cfg.autoAnswerByCallInfo then 1 else 0; # allow auto answer by Call-Info/Alert-Info
      P26072 = if cfg.autoAnswerWarningTone then 1 else 0; # warning tone before auto answer
      P212 = 1; # config upgrade via HTTP
      # config server path: this server
      P237 = cfg.listenAddress + lib.optionalString (cfg.port != 80) ":${toString cfg.port}";
      P2 = cfg.adminPassword; # admin password of the web interface
    }
    // optionalAttrs cfg.disableCloud {
      P1409 = 0; # TR-069 (GDMS cloud management) off
      P1414 = 0; # 3CX auto provisioning off
    }
    // (
      if cfg.firmware.server == null then
        {
          P238 = 2; # always skip the firmware check
          P194 = 0; # no automatic upgrade
        }
      else
        {
          P6767 = 1; # firmware upgrade via HTTP
          P192 = cfg.firmware.server; # firmware server path
          P238 = 1; # check only when the firmware prefix/suffix changes
        }
    )
    // cfg.settings
  );

  phoneSettings =
    name: phone:
    let
      endpoint = endpointOf phone;
      inherit (endpoint) auth;
    in
    commonSettings
    // {
      P271 = 1; # account 1 active
      P270 = name; # account name
      P35 = auth.username; # SIP user ID
      P36 = auth.username; # authentication ID
      P34 = auth.password; # authentication password
      P3 =
        if phone.displayName != null then
          phone.displayName
        else if endpoint.callerId != null && callerIdName endpoint.callerId != null then
          callerIdName endpoint.callerId
        else
          phone.endpoint; # display name
    }
    // phone.settings;

  escapeXml = lib.replaceStrings [ "&" "<" ">" "\"" "'" ] [ "&amp;" "&lt;" "&gt;" "&quot;" "&apos;" ];

  valueText =
    v:
    if secrets.isSecret v then
      secrets.placeholder v
    else if isInt v then
      toString v
    else
      escapeXml v;

  # numeric order; keys that are not P-values are reported by an assertion
  pNumber =
    p:
    let
      m = builtins.match "P([0-9]+)" p;
    in
    if m == null then 0 else lib.toInt (builtins.head m);

  phoneXml =
    name: phone:
    let
      values = phoneSettings name phone;
      keys = lib.sort (a: b: pNumber a < pNumber b) (attrNames values);
    in
    ''
      <?xml version="1.0" encoding="UTF-8"?>
      <gs_provision version="1">
        <mac>${normalizeMac phone.mac}</mac>
        <config version="1">
      ${concatStrings (map (p: "    <${p}>${valueText values.${p}}</${p}>\n") keys)}  </config>
      </gs_provision>
    '';

  templates = pkgs.linkFarm "grandstream-provisioning" (
    mapAttrsToList (name: phone: {
      name = "cfg${normalizeMac phone.mac}.xml";
      path = pkgs.writeText "cfg${normalizeMac phone.mac}.xml" (phoneXml name phone);
    }) cfg.phones
  );

  secretRefs = unique (
    lib.concatMap (name: secrets.fromText (phoneXml name cfg.phones.${name})) (attrNames cfg.phones)
  );

  # nginx binds `listenAddress` and fails if it is not configured yet: the
  # static address of an interface other than the default gateway's is not
  # ordered before network-online.target. nginx starts after this unit.
  waitForAddress = pkgs.writeShellScript "grandstream-provisioning-wait" ''
    waited=0
    until [ -n "$(${pkgs.iproute2}/bin/ip -o address show to ${lib.escapeShellArg cfg.listenAddress} -tentative)" ]; do
      if [ "$waited" -eq 0 ]; then
        echo "grandstream-provisioning: waiting for address ${cfg.listenAddress}"
      elif [ "$waited" -ge 90 ]; then
        echo "grandstream-provisioning: address ${cfg.listenAddress} is not configured on this host" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 1
      waited=$((waited + 1))
    done
  '';
  waitsForAddress =
    !(builtins.elem cfg.listenAddress [
      "0.0.0.0"
      "::"
      "*"
    ]);

  renderer = pkgs.writeShellApplication {
    name = "grandstream-provisioning-render";
    runtimeInputs = with pkgs; [
      coreutils
      findutils
      gnugrep
    ];
    text = ''
      shopt -u patsub_replacement 2>/dev/null || true
      shopt -s nullglob
      umask 0077
      amp='&amp;' lt='&lt;' gt='&gt;' quot='&quot;' apos='&apos;'

      new=$(mktemp -d "${runtimeDir}/.new.XXXXXXXX")
      for template in ${templates}/*; do
        cp -L --no-preserve=mode,ownership "$template" "$new"/
      done

      substitute() {
        local placeholder=$1 credential=$2 value file content
        value=$(< "$CREDENTIALS_DIRECTORY/$credential")
        value=''${value%$'\r'}
        value=''${value//&/"$amp"}
        value=''${value//</"$lt"}
        value=''${value//>/"$gt"}
        value=''${value//\"/"$quot"}
        value=''${value//\'/"$apos"}
        while IFS= read -r -d "" file; do
          content=$(< "$file")
          printf '%s\n' "''${content//"$placeholder"/"$value"}" > "$file"
        done < <(grep -rlFZ -- "$placeholder" "$new" || true)
      }

      ${concatMapStringsSep "\n" (
        ref:
        "substitute ${
          lib.escapeShellArgs [
            (secrets.placeholder ref)
            (secrets.credentialName ref)
          ]
        }"
      ) secretRefs}

      if grep -rqF '@NIX_ASTERISK_SECRET:' "$new"; then
        echo "grandstream-provisioning: unresolved secret placeholder" >&2
        exit 1
      fi

      find ${runtimeDir} -maxdepth 1 -name 'cfg*.xml' -delete
      for file in "$new"/*; do
        chmod 0400 "$file"
        mv "$file" ${runtimeDir}/
      done
      rmdir "$new"
    '';
  };
in
{
  options.services.asterisk-declarative.provisioning.grandstream = {
    enable = mkEnableOption "provisioning of Grandstream phones over HTTP";

    listenAddress = mkOption {
      type = types.str;
      example = "10.0.20.10";
      description = ''
        Address nginx serves the provisioning files on. Use the address on the
        phones' network only; the files contain SIP passwords. Point the phones
        at it with DHCP option 66 (`http://10.0.20.10`) or once in their web
        interface; afterwards they keep using this server (P237).
      '';
    };

    port = mkOption {
      type = types.port;
      default = 80;
      description = "HTTP port.";
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      example = [ "10.0.20.0/24" ];
      description = "Networks allowed to download provisioning files (nginx `allow`).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the HTTP port (and NTP, if served) on `firewallInterfaces`.";
    };

    firewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "voip" ];
      description = "Interfaces the firewall is opened on; empty means all.";
    };

    sipServer = mkOption {
      type = types.str;
      default = cfg.listenAddress;
      defaultText = literalExpression "listenAddress";
      example = "10.0.20.10:5060";
      description = "SIP server the phones register to (P47).";
    };

    ntpServer = mkOption {
      type = types.nullOr types.str;
      default = if cfg.ntp.serve then cfg.listenAddress else null;
      defaultText = literalExpression "if ntp.serve then listenAddress else null";
      description = "NTP server of the phones (P30); `null` keeps the phone's default.";
    };

    ntp = {
      serve = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Run chrony on this host and let `allowedNetworks` query it, for
          phones on a network without internet access.
        '';
      };
    };

    timeZone = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "CET-1CEST-2,M3.5.0/02:00:00,M10.5.0/03:00:00";
      description = "Time zone (P64): `auto` or a POSIX TZ string as listed in the templates.";
    };

    autoAnswerByCallInfo = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Answer calls automatically when the INVITE carries
        `Call-Info: ...;answer-after=0` or `Alert-Info: info=alert-autoanswer`
        (P298), which is how the paging helpers mark intercom calls.
      '';
    };

    autoAnswerWarningTone = mkOption {
      type = types.bool;
      default = true;
      description = "Play a warning tone before an auto-answered intercom call (P26072).";
    };

    disableCloud = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Turn off TR-069 management (P1409, which points at Grandstream's GDMS
        cloud by default) and 3CX auto provisioning (P1414).
      '';
    };

    firmware = {
      server = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.0.20.10/firmware";
        description = ''
          Firmware server path (P192, over HTTP). `null` disables firmware
          checks (P238 = 2) and automatic upgrades, so phones never contact
          Grandstream's firmware server.
        '';
      };
      directory = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = ''
          Directory with firmware images served under `/firmware/`; set
          `firmware.server` to `"<listenAddress>/firmware"` to use it.
        '';
      };
    };

    adminPassword = mkOption {
      type = types.nullOr valueType;
      default = null;
      example = literalExpression "config.lib.asterisk.secret config.sops.secrets.phone-admin.path";
      description = "Password of the phones' web interface (P2), normally a secret reference.";
    };

    settings = mkOption {
      type = types.attrsOf valueType;
      default = { };
      example = {
        P1362 = "en";
        P8 = 0;
      };
      description = "Additional P-values for every phone.";
    };

    phones = mkOption {
      type = types.attrsOf phoneType;
      default = { };
      example = literalExpression ''
        {
          kitchen = { mac = "00:0b:82:12:34:56"; endpoint = "101"; allowedAddress = "10.0.20.21"; };
          office = { mac = "000b82abcdef"; endpoint = "103"; };
        }
      '';
      description = "Phones to provision, keyed by an account name.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = acfg.enable;
        message = "services.asterisk-declarative.provisioning.grandstream requires services.asterisk-declarative.enable.";
      }
    ]
    ++ mapAttrsToList (name: phone: {
      assertion = endpointOf phone != null && (endpointOf phone).auth != null;
      message = "services.asterisk-declarative.provisioning.grandstream.phones.${name}: endpoint `${phone.endpoint}` must exist in pjsip.endpoints and have `auth` set.";
    }) cfg.phones
    ++ [
      {
        assertion =
          let
            macs = map (phone: normalizeMac phone.mac) (attrValues cfg.phones);
          in
          lib.allUnique macs;
        message = "services.asterisk-declarative.provisioning.grandstream.phones: MAC addresses must be unique.";
      }
      {
        assertion = builtins.all (p: builtins.match "P[0-9]+" p != null) (
          attrNames cfg.settings ++ lib.concatMap (phone: attrNames phone.settings) (attrValues cfg.phones)
        );
        message = "services.asterisk-declarative.provisioning.grandstream: settings keys must be P-values such as P1362.";
      }
    ]
    ++ map (ref: {
      assertion = !(secrets.isStorePath ref) && secrets.isValidReference ref;
      message = "services.asterisk-declarative.provisioning.grandstream: invalid secret reference ${secrets.placeholder ref}.";
    }) secretRefs;

    systemd.services.grandstream-provisioning = {
      description = "Render Grandstream provisioning files";
      wantedBy = [
        "multi-user.target"
        "nginx.service"
      ];
      before = [ "nginx.service" ];
      restartTriggers = [ templates ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = lib.optional waitsForAddress "${waitForAddress}";
        ExecStart = "${renderer}/bin/grandstream-provisioning-render";
        User = config.services.nginx.user;
        Group = config.services.nginx.group;
        # secret files; systemd credentials (`credential "name"`) must be
        # loaded into this unit by the user, as for asterisk.service
        LoadCredential = map (ref: "${secrets.credentialName ref}:${ref._secret}") (
          lib.filter (ref: ref ? _secret) secretRefs
        );
        # owner only: nginx serves the files, the renderer (same user) writes them
        RuntimeDirectory = "grandstream-provisioning";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        CapabilityBoundingSet = [ "" ];
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        # no IP traffic; netlink only to see whether the address is up
        IPAddressDeny = "any";
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_UNIX"
          "AF_NETLINK"
        ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [ "@system-service" ];
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts.grandstream-provisioning = {
        listen = [
          {
            addr = cfg.listenAddress;
            inherit (cfg) port;
          }
        ];
        root = runtimeDir;
        extraConfig = ''
          ${concatMapStringsSep "\n" (net: "allow ${net};") cfg.allowedNetworks}
          deny all;
        '';
        locations = {
          "/".return = "404";
        }
        // mapAttrs' (
          _: phone:
          nameValuePair "= /cfg${normalizeMac phone.mac}.xml" {
            extraConfig =
              if phone.allowedAddress != null then
                ''
                  allow ${phone.allowedAddress};
                  deny all;
                ''
              else
                "";
          }
        ) cfg.phones
        // optionalAttrs (cfg.firmware.directory != null) {
          "/firmware/".alias = "${cfg.firmware.directory}/";
        };
      };
    };

    services.chrony = mkIf cfg.ntp.serve {
      enable = true;
      # keep serving (the phones' only clock) while upstream servers are unreachable
      extraConfig = ''
        ${concatMapStringsSep "\n" (net: "allow ${net}") cfg.allowedNetworks}
        local stratum 10
      '';
    };

    networking.firewall =
      let
        ports = {
          allowedTCPPorts = [ cfg.port ];
          allowedUDPPorts = optional cfg.ntp.serve 123;
        };
      in
      mkIf cfg.openFirewall (
        if cfg.firewallInterfaces == [ ] then
          ports
        else
          { interfaces = lib.genAttrs cfg.firewallInterfaces (_: ports); }
      );
  };
}
