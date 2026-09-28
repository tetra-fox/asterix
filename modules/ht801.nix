# Provisioning for Grandstream HT801 adapters: nginx serves each adapter its
# `cfg<mac>.xml` (Grandstream's gs_provision format), with the SIP account of a
# services.asterisk.pjsip endpoint.
#
# The files contain the SIP password, so they are rendered at service start
# into a tmpfs like Asterisk's own configuration; the store only holds
# placeholders. Secrets given as systemd credentials (`credential "name"`) must
# also be loaded into ht801-provisioning.service.
#
# Every P-value set here is in Grandstream's HT80x configuration templates for
# both hardware versions (config-template.zip from grandstream.com/support/tools:
# ht80x 1.0.65.3 and ht80x_v2 1.0.15.2).
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
    toLower
    types
    unique
    ;

  cfg = config.services.asterisk.ht801;
  acfg = config.services.asterisk;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format secrets;

  runtimeDir = "/run/ht801-provisioning";

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
      P237 = cfg.listenAddress + lib.optionalString (cfg.port != 80) ":${toString cfg.port}";
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

  valueText = v:
    if secrets.isSecret v
    then secrets.placeholder v
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

  templates = pkgs.linkFarm "ht801-provisioning" (
    mapAttrsToList (_: device: {
      name = "cfg${normalizeMac device.mac}.xml";
      path = pkgs.writeText "cfg${normalizeMac device.mac}.xml" (deviceXml device);
    })
    cfg.devices
  );

  secretRefs = unique (lib.concatMap (device: secrets.fromText (deviceXml device)) (attrValues cfg.devices));

  # nginx binds `listenAddress` and fails if it is not configured yet: the
  # static address of an interface other than the default gateway's is not
  # ordered before network-online.target. nginx starts after this unit.
  waitForAddress = pkgs.writeShellScript "ht801-provisioning-wait" ''
    waited=0
    until [ -n "$(${pkgs.iproute2}/bin/ip -o address show to ${lib.escapeShellArg cfg.listenAddress} -tentative)" ]; do
      if [ "$waited" -eq 0 ]; then
        echo "ht801-provisioning: waiting for address ${cfg.listenAddress}"
      elif [ "$waited" -ge 90 ]; then
        echo "ht801-provisioning: address ${cfg.listenAddress} is not configured on this host" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 1
      waited=$((waited + 1))
    done
  '';
  waitsForAddress = !(builtins.elem cfg.listenAddress ["0.0.0.0" "::"]);

  renderer = pkgs.writeShellApplication {
    name = "ht801-provisioning-render";
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
          ref: "substitute ${
            lib.escapeShellArgs [
              (secrets.placeholder ref)
              (secrets.credentialName ref)
            ]
          }"
        )
        secretRefs}

      if grep -rqF '@NIX_ASTERISK_SECRET:' "$new"; then
        echo "ht801-provisioning: unresolved secret placeholder" >&2
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
in {
  options.services.asterisk.ht801 = {
    enable = mkEnableOption "provisioning of Grandstream HT801 adapters over HTTP";

    listenAddress = mkOption {
      type = types.str;
      example = "10.0.20.10";
      description = ''
        Address nginx serves the provisioning files on, on the adapters'
        network only: the files contain SIP passwords. Point each adapter at
        it once, with DHCP option 66 (`http://10.0.20.10`) or its web
        interface; the file then keeps it pointed here (P237).
      '';
    };

    port = mkOption {
      type = types.port;
      default = 80;
      description = "HTTP port.";
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      example = ["10.0.20.0/24"];
      description = "Networks allowed to download provisioning files (nginx `allow`).";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the HTTP port on `firewallInterfaces`.";
    };

    firewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["voip"];
      description = "Interfaces the firewall is opened on; empty means all.";
    };

    sipServer = mkOption {
      type = types.str;
      default = cfg.listenAddress;
      defaultText = literalExpression "listenAddress";
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
          assertion = acfg.enable;
          message = "services.asterisk.ht801 requires services.asterisk.enable.";
        }
        {
          assertion = lib.allUnique (map (device: normalizeMac device.mac) (attrValues cfg.devices));
          message = "services.asterisk.ht801.devices: MAC addresses must be unique.";
        }
        {
          assertion = builtins.all (p: builtins.match "P[0-9]+" p != null) (
            attrNames cfg.settings ++ lib.concatMap (device: attrNames device.settings) (attrValues cfg.devices)
          );
          message = "services.asterisk.ht801: settings keys must be P-values such as P1362.";
        }
      ]
      ++ mapAttrsToList (name: device: {
        assertion = endpointOf device != null && (endpointOf device).auth != null;
        message = "services.asterisk.ht801.devices.${name}: endpoint `${device.endpoint}` must exist in pjsip.endpoints and have `auth` set.";
      })
      cfg.devices
      ++ map (ref: {
        assertion = !(secrets.isStorePath ref) && secrets.isValidReference ref;
        message = "services.asterisk.ht801: invalid secret reference ${secrets.placeholder ref}.";
      })
      secretRefs;

    systemd.services.ht801-provisioning = {
      description = "Render HT801 provisioning files";
      wantedBy = [
        "multi-user.target"
        "nginx.service"
      ];
      before = ["nginx.service"];
      restartTriggers = [templates];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = lib.optional waitsForAddress "${waitForAddress}";
        ExecStart = "${renderer}/bin/ht801-provisioning-render";
        User = config.services.nginx.user;
        Group = config.services.nginx.group;
        LoadCredential = map (ref: "${secrets.credentialName ref}:${ref._secret}") (
          lib.filter (ref: ref ? _secret) secretRefs
        );
        # owner only: nginx serves the files, the renderer (same user) writes them
        RuntimeDirectory = "ht801-provisioning";
        RuntimeDirectoryMode = "0700";
        RuntimeDirectoryPreserve = true;
        CapabilityBoundingSet = [""];
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
        SystemCallFilter = ["@system-service"];
      };
    };

    services.nginx = {
      enable = true;
      virtualHosts.ht801-provisioning = {
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
        locations =
          {
            "/".return = "404";
          }
          // mapAttrs' (
            _: device:
              nameValuePair "= /cfg${normalizeMac device.mac}.xml" {
                extraConfig =
                  if device.allowedAddress != null
                  then ''
                    allow ${device.allowedAddress};
                    deny all;
                  ''
                  else "";
              }
          )
          cfg.devices;
      };
    };

    networking.firewall = let
      ports.allowedTCPPorts = [cfg.port];
    in
      mkIf cfg.openFirewall (
        if cfg.firewallInterfaces == []
        then ports
        else {interfaces = lib.genAttrs cfg.firewallInterfaces (_: ports);}
      );
  };
}
