# Provisioning files for phones and adapters, served over HTTP by
# pkgs/provisioning-server from a systemd socket.
#
# `devices` are phones and adapters of the models that vendor modules (see
# grandstream.nix) add to `models`; each vendor module writes the files of its
# devices into `files`, as users may by hand. Their text may contain secret
# references, which are substituted at service start into a tmpfs like
# Asterisk's own configuration, so the store only holds placeholders. Secrets
# given as systemd credentials (`credential "name"`) must also be loaded into
# asterisk-provisioning.service.
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
    filterAttrs
    literalExpression
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    optionalString
    types
    unique
    ;

  cfg = config.pbx.phones;
  asteriskLib = import ../../../lib {inherit lib;};
  inherit (asteriskLib) format secrets;
  moduleLib = import ../../lib.nix {inherit lib;};
  pbxLib = import ../lib.nix {inherit lib;};

  deviceType = types.submodule (
    {name, ...}: {
      options = {
        model = mkOption {
          type = types.enum (attrNames cfg.models);
          example = "grandstream-ht814";
          description = "Model of the device, as `<vendor>-<model>`.";
        };
        mac = mkOption {
          type = types.strMatching "([0-9a-fA-F]{2}[:-]?){5}[0-9a-fA-F]{2}";
          apply = mac: lib.toLower (lib.replaceStrings [":" "-"] ["" ""] mac);
          example = "c0:74:ad:12:34:56";
          description = "MAC address of the device: twelve hexadecimal digits, in pairs separated by `:` or `-`, or not separated.";
        };
        lines = mkOption {
          type = types.listOf (types.nullOr types.str);
          default = [name];
          defaultText = literalExpression "[ <name> ]";
          example = ["101" null "103"];
          description = ''
            Endpoints in {option}`services.asterisk.pjsip.endpoints` that the
            device's lines (an adapter's phone ports, a phone's accounts)
            register as, from line 1. A line given as `null` or past the end of
            the list is turned off.
          '';
        };
        allowedAddress = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10.0.20.21";
          description = ''
            Only this address may download the device's file, which contains
            its SIP passwords. Use it together with a static DHCP lease.
          '';
        };
        settings = mkOption {
          type = types.attrsOf pbxLib.phoneValue;
          default = {};
          example = {
            P1362 = "de";
          };
          description = "Settings in the vendor's own format, replacing what the modules set; PROVISIONING.md names each vendor's.";
        };
      };
    }
  );

  # the device sends one user name, for the endpoint and its aor
  registers = name: let
    endpoint = config.services.asterisk.pjsip.endpoints.${name} or null;
  in
    endpoint != null && endpoint.auth != null && endpoint.aor != null && endpoint.aor.name == name;

  unregistered = device: unique (builtins.filter (name: name != null && !registers name) device.lines);

  tooManyLines = device: builtins.length device.lines > cfg.models.${device.model}.lines;

  macs = map (device: device.mac) (attrValues cfg.devices);
  sharesMac = device: builtins.length (builtins.filter (mac: mac == device.mac) macs) > 1;

  runtimeDir = "/run/asterisk-provisioning";

  server = pkgs.callPackage ../../../pkgs/provisioning-server/package.nix {};

  # one line per file: `NAME`, then the ADDRESS that alone may fetch it, if one
  # does, and `tftp` if it is served over TFTP too
  manifest = pkgs.writeText "asterisk-provisioning-manifest" (
    concatStrings (mapAttrsToList (name: file: "${name}${optionalString (file.allowedAddress != null) " ${file.allowedAddress}"}${optionalString file.tftp " tftp"}\n") cfg.files)
  );

  # the port devices send TFTP requests to, which the server answers from
  tftpPort = 69;
  serveTftp = builtins.any (file: file.tftp) (attrValues cfg.files);

  fileType = types.submodule {
    options = {
      text = mkOption {
        type = types.str;
        description = ''
          Contents of the file. Secret references can be interpolated
          (`"''${config.lib.asterisk.secret "/run/secrets/x"}"`).
        '';
      };
      escape = mkOption {
        type = types.enum [
          "none"
          "line"
          "xml"
        ];
        default = "none";
        description = "How secret values are substituted into the file: as they are (`none`), refusing control characters (`line`, for one-line values) or escaped for XML (`xml`).";
      };
      allowedAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "10.0.20.21";
        description = ''
          Only this address may download the file (others get 403). Use it for
          files that contain one device's password, together with a static DHCP
          lease.
        '';
      };
      tftp = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Serve the file over TFTP too, on UDP port 69, for devices that fetch
          their first file that way.
        '';
      };
    };
  };

  templates = pkgs.linkFarm "asterisk-provisioning" (
    mapAttrsToList (name: file: {
      inherit name;
      path = pkgs.writeText name file.text;
    })
    cfg.files
  );

  secretRefs = unique (lib.concatMap (file: secrets.fromText file.text) (attrValues cfg.files));
  secretManifest = pkgs.writeText "asterisk-provisioning-secrets" (secrets.manifest {} secretRefs);

  # files with secrets, by how their values are escaped
  filesFor = escape: attrNames (filterAttrs (_: file: file.escape == escape && secrets.fromText file.text != []) cfg.files);

  # addresses as the server (Rust's IpAddr) and systemd parse them: IPv4
  # without leading zeros, IPv6 without brackets or zone
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  ipv4 = "${octet}[.]${octet}[.]${octet}[.]${octet}";
  isIPv4 = address: builtins.match ipv4 address != null;
  # up to eight groups of hex digits, one `::` for one or more zero groups,
  # and an IPv4 address as the last two
  isIPv6 = address: let
    embedded = builtins.match "(.*:)${ipv4}" address;
    hex =
      if embedded == null
      then address
      else builtins.head embedded + "0:0";
    halves = lib.splitString "::" hex;
    groups = lib.concatMap (half: lib.optionals (half != "") (lib.splitString ":" half)) halves;
    count = builtins.length groups;
  in
    builtins.all (group: builtins.match "[0-9A-Fa-f]{1,4}" group != null) groups
    && (
      if builtins.length halves == 1
      then count == 8
      else builtins.length halves == 2 && count <= 7
    );
  isAddress = address: isIPv4 address || isIPv6 address;

  # entries systemd would not take for IPAddressAllow= (an empty one resets the
  # list): each holds addresses, with or without a prefix length, or the names
  # systemd knows
  invalidNetworks = lib.filter (entry: let
    tokens = lib.filter (token: builtins.isString token && token != "") (builtins.split "[[:space:]]+" entry);
    valid = token: let
      prefix = builtins.match "([^/]*)/0*([0-9]{1,3})" token;
      length = lib.toInt (lib.last prefix);
    in
      builtins.elem token ["any" "localhost" "link-local" "multicast"]
      || (
        if prefix == null
        then isAddress token
        else (isIPv4 (builtins.head prefix) && length <= 32) || (isIPv6 (builtins.head prefix) && length <= 128)
      );
  in
    tokens == [] || !(builtins.all valid tokens))
  cfg.allowedNetworks;

  # files whose allowedAddress the server cannot parse, so it would not start
  invalidAddresses = filterAttrs (_: file: file.allowedAddress != null && !isAddress file.allowedAddress) cfg.files;

  renderer = pkgs.writeShellApplication {
    name = "asterisk-provisioning-render";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      (callPackage ../../../pkgs/render-secrets/package.nix {})
    ];
    text = ''
      shopt -s nullglob
      umask 0077

      # the runtime directory is new on every start of the unit
      for template in ${templates}/*; do
        cp -L --no-preserve=mode,ownership "$template" ${runtimeDir}/
      done

      cd ${runtimeDir}
      ${lib.concatMapStrings (escape:
        lib.optionalString (filesFor escape != []) ''
          render-secrets ${escape} ${secretManifest} ${lib.escapeShellArgs (filesFor escape)}
        '') ["none" "line" "xml"]}
      if grep -rqF '@NIX_ASTERISK_SECRET:' ${runtimeDir}; then
        echo "asterisk-provisioning: unresolved secret placeholder" >&2
        exit 1
      fi

      for file in ${runtimeDir}/*; do
        chmod 0400 "$file"
      done
    '';
  };
in {
  imports = [
    ./cisco.nix
    ./fanvil.nix
    ./grandstream.nix
    ./poly.nix
    ./snom.nix
    ./yealink.nix
  ];

  options.pbx.phones = {
    enable =
      mkEnableOption "serving provisioning files for phones over HTTP"
      // {
        default = cfg.devices != {};
        defaultText = literalExpression "config.pbx.phones.devices != { }";
      };

    listenAddress = mkOption {
      type = types.str;
      example = "10.0.20.10";
      description = ''
        Address the provisioning files are served on, on the phones' network
        only: the files usually contain SIP passwords. It may be configured
        after the socket is set up (`FreeBind=`).
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
      description = ''
        Networks allowed to connect. systemd drops connections from anywhere
        else (`IPAddressAllow=` on the socket) before the server sees them.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the HTTP port on `firewallInterfaces`, and UDP port 69 if a file is served over TFTP.";
    };

    firewallInterfaces = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["voip"];
      description = "Interfaces the firewall is opened on; empty means all.";
    };

    files = mkOption {
      type = types.attrsOf fileType;
      default = {};
      example = literalExpression ''
        {
          "0015651234ab.cfg" = {
            text = '''
              #!version:1.0.0.1
              account.1.password = ''${config.lib.asterisk.secret config.sops.secrets.sip-101.path}
            ''';
            allowedAddress = "10.0.20.21";
          };
        }
      '';
      description = ''
        Files served at `/<name>`, written by vendor modules or by hand. Every
        other path is answered with 404.
      '';
    };

    sipServer = mkOption {
      type = types.str;
      default = cfg.listenAddress;
      defaultText = literalExpression "config.pbx.phones.listenAddress";
      example = "pbx.example.org";
      description = "Host name or address of the SIP server the devices' lines register to, without the port.";
    };

    sipPort = mkOption {
      type = types.port;
      default = 5060;
      description = "Port of {option}`pbx.phones.sipServer`. Devices that take the server and its port as one value get the port only when it is not 5060, SIP's default.";
    };

    ntpServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.0.20.10";
      description = "NTP server of the devices; `null` keeps their default.";
    };

    adminPassword = mkOption {
      type = types.nullOr pbxLib.phoneValue;
      default = null;
      example = literalExpression "config.lib.asterisk.secret config.sops.secrets.phones-admin.path";
      description = ''
        Password of the devices' web interface, normally a secret reference. A
        plain string or integer is stored world-readable in the Nix store and
        triggers a warning.
      '';
    };

    devices = mkOption {
      type = types.attrsOf deviceType;
      default = {};
      example = literalExpression ''
        {
          "101" = { model = "grandstream-ht801"; mac = "c0:74:ad:12:34:56"; allowedAddress = "10.0.20.21"; };
          garage = { model = "grandstream-ht802"; mac = "c074ad654321"; lines = [ "102" "103" ]; };
        }
      '';
      description = "Phones and adapters to provision.";
    };

    models = mkOption {
      internal = true;
      visible = false;
      type = types.attrsOf (types.submodule {
        options.lines = mkOption {
          type = types.ints.positive;
          description = "How many lines the model has.";
        };
      });
      default = {};
      description = "Models that `devices.<name>.model` takes, added by the vendor modules.";
    };

    validDevices = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.raw;
      default = filterAttrs (_: device: !tooManyLines device && unregistered device == [] && !sharesMac device) cfg.devices;
      description = "Devices whose files the vendor modules write: the others fail an assertion, and their lines may name endpoints that do not exist or their files those of another device.";
    };
  };

  config = mkIf cfg.enable {
    warnings = lib.optional (cfg.adminPassword != null && !secrets.holdsSecret cfg.adminPassword) "pbx.phones.adminPassword is not a secret reference, so it is stored world-readable in the Nix store; use config.lib.asterisk.secret instead.";

    assertions =
      [
        {
          assertion = config.services.asterisk.enable;
          message = "pbx.phones requires services.asterisk.enable.";
        }
        {
          assertion = builtins.all (name: builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_.+-]*" name != null) (attrNames cfg.files);
          message = "pbx.phones.files: file names may only contain letters, digits and _.+- (no directories).";
        }
        {
          assertion = cfg.allowedNetworks != [];
          message = "pbx.phones.allowedNetworks is empty, so systemd would drop every connection; list the phones' networks.";
        }
        {
          assertion = invalidNetworks == [];
          message = "pbx.phones.allowedNetworks: entries must be addresses, networks such as 10.0.20.0/24, or any, localhost, link-local or multicast, which is what systemd takes: ${lib.concatMapStringsSep ", " (entry: "`${entry}`") invalidNetworks}.";
        }
        {
          assertion = invalidAddresses == {};
          message = "pbx.phones.files: allowedAddress must be one IPv4 or IPv6 address: ${lib.concatStringsSep ", " (mapAttrsToList (name: file: "${name} has `${file.allowedAddress}`") invalidAddresses)}.";
        }
        {
          # the socket's ListenStream= takes an address and the port
          assertion = isAddress cfg.listenAddress;
          message = "pbx.phones.listenAddress must be one IPv4 or IPv6 address: ${builtins.toJSON cfg.listenAddress}.";
        }
        {
          assertion = moduleLib.invalidInterfaces cfg.firewallInterfaces == [];
          message = "pbx.phones.firewallInterfaces: Linux takes interface names of 1 to 15 bytes without /, : or whitespace: ${
            lib.concatMapStringsSep ", " builtins.toJSON (moduleLib.invalidInterfaces cfg.firewallInterfaces)
          }.";
        }
        {
          assertion = lib.allUnique macs;
          message = "pbx.phones.devices: MAC addresses must be unique.";
        }
        {
          # [v6]:port or host:port, where a bare IPv6 address has more colons
          assertion = builtins.match "[[].*|[^:]*:[^:]*" cfg.sipServer == null;
          message = "pbx.phones.sipServer is ${builtins.toJSON cfg.sipServer}, but takes the host alone; give the port in pbx.phones.sipPort.";
        }
      ]
      ++ mapAttrsToList (name: device: let
        count = cfg.models.${device.model}.lines;
      in {
        assertion = !tooManyLines device;
        message = "pbx.phones.devices.${name}: a ${device.model} has ${toString count} line${optionalString (count > 1) "s"}, but lines lists ${toString (builtins.length device.lines)}.";
      })
      cfg.devices
      ++ mapAttrsToList (name: device: {
        assertion = unregistered device == [];
        message = "pbx.phones.devices.${name}: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: ${lib.concatMapStringsSep ", " (e: "`${e}`") (unregistered device)}.";
      })
      cfg.devices
      ++ map (ref: {
        assertion = !(secrets.isStorePath ref) && secrets.isValidReference ref;
        message = "pbx.phones: invalid secret reference ${secrets.placeholderOf ref}.";
      })
      secretRefs;

    systemd.sockets.asterisk-provisioning = {
      description = "Phone provisioning";
      wantedBy = ["sockets.target"];
      listenStreams = [(format.hostPort cfg.listenAddress cfg.port)];
      socketConfig = {
        FreeBind = true;
        IPAddressDeny = "any";
        IPAddressAllow = cfg.allowedNetworks;
        FileDescriptorName = "http";
      };
    };

    systemd.sockets.asterisk-provisioning-tftp = mkIf serveTftp {
      description = "Phone provisioning over TFTP";
      wantedBy = ["sockets.target"];
      listenDatagrams = [(format.hostPort cfg.listenAddress tftpPort)];
      socketConfig = {
        FreeBind = true;
        IPAddressDeny = "any";
        IPAddressAllow = cfg.allowedNetworks;
        FileDescriptorName = "tftp";
        Service = "asterisk-provisioning.service";
      };
    };

    systemd.services.asterisk-provisioning = let
      sockets = ["asterisk-provisioning.socket"] ++ lib.optional serveTftp "asterisk-provisioning-tftp.socket";
    in {
      description = "Phone provisioning";
      # started at boot rather than on the first request, so a missing secret
      # shows up in the unit's status right away
      wantedBy = ["multi-user.target"];
      requires = sockets;
      after = sockets;
      serviceConfig = {
        Type = "exec";
        Sockets = sockets;
        ExecStartPre = "${renderer}/bin/asterisk-provisioning-render";
        ExecStart = "${lib.getExe server} ${runtimeDir} ${manifest}";
        Restart = "on-failure";
        DynamicUser = true;
        LoadCredential = map (ref: "${secrets.credentialName ref}:${ref._secret}") (
          lib.filter (ref: ref ? _secret) secretRefs
        );
        RuntimeDirectory = "asterisk-provisioning";
        RuntimeDirectoryMode = "0700";
        UMask = "0077";

        # the sockets from the .socket units are the only network access (the
        # service's IPAddressDeny does not apply to sockets passed in)
        PrivateNetwork = true;
        RestrictAddressFamilies = "none";
        IPAddressDeny = "any";

        CapabilityBoundingSet = "";
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateUsers = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectControlGroups = true;
        ProtectProc = "invisible";
        ProcSubset = "pid";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
      };
    };

    networking.firewall = mkIf cfg.openFirewall (moduleLib.firewallOn cfg.firewallInterfaces {
      allowedTCPPorts = [cfg.port];
      allowedUDPPorts = lib.optional serveTftp tftpPort;
    });
  };
}
