# Provisioning files for phones and adapters, served over HTTP by
# pkgs/asterix-provisioning-server from a systemd socket. Vendor modules add their
# models to `models` and write the files of their `devices` into `files`, as
# users may by hand. Secret references in the text are substituted at service
# start into a tmpfs, so the store only holds placeholders. Secrets given as
# systemd credentials (`credential "name"`) must also be loaded into
# asterix-provisioning.service.
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

  cfg = config.services.asterix.phones;
  networks = config.services.asterix.networks;
  # the only network, the default of `network`
  network =
    if builtins.length (attrNames networks) == 1
    then builtins.head (attrNames networks)
    else null;
  net =
    if cfg.network != null && networks ? ${cfg.network}
    then networks.${cfg.network}
    else throw "services.asterix.phones.network must name a network of services.asterix.networks (${lib.concatStringsSep ", " (attrNames networks)}).";
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
          description = "MAC address of the device, twelve hexadecimal digits, in pairs separated by `:` or `-` or not separated.";
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
          description = "Settings in the vendor's own format, replacing what the modules set. PROVISIONING.md names each vendor's format.";
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

  runtimeDir = "/run/asterix-provisioning";

  server = pkgs.callPackage ../../../pkgs/asterix-provisioning-server/package.nix {};

  # one line per file: `NAME`, then the ADDRESS that alone may fetch it, if one
  # does, and `tftp` if it is served over TFTP too. The renderer adds the files
  # of `directories` at service start
  manifest = pkgs.writeText "asterix-provisioning-manifest" (
    concatStrings (mapAttrsToList (name: file: "${name}${optionalString (file.allowedAddress != null) " ${file.allowedAddress}"}${optionalString file.tftp " tftp"}\n") cfg.files)
  );
  runtimeManifest = "${runtimeDir}/.manifest";

  # the port devices send TFTP requests to, which the server answers from
  tftpPort = 69;
  serveTftp = cfg.directories != [] || builtins.any (file: file.tftp) (attrValues cfg.files);

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
          Whether to also serve the file over TFTP, on UDP port 69, for
          devices that fetch their first file that way.
        '';
      };
    };
  };

  templates = pkgs.linkFarm "asterix-provisioning" (
    mapAttrsToList (name: file: {
      inherit name;
      path = pkgs.writeText name file.text;
    })
    cfg.files
  );

  secretRefs = unique (lib.concatMap (file: secrets.fromText file.text) (attrValues cfg.files));
  secretManifest = pkgs.writeText "asterix-provisioning-secrets" (secrets.manifest {} secretRefs);

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
    name = "asterix-provisioning-render";
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
      cp ${manifest} ${runtimeManifest}

      directories=(${lib.escapeShellArgs (map (directory: "${directory}") cfg.directories)})
      for directory in "''${directories[@]}"; do
        for file in "$directory"/*; do
          name=''${file##*/}
          if [[ ! $name =~ ^[A-Za-z0-9_+-][A-Za-z0-9_.+-]*$ ]]; then
            echo "asterix-provisioning: $file: file names may only contain letters, digits and _.+-" >&2
            exit 1
          fi
          if [ -e "${runtimeDir}/$name" ]; then
            echo "asterix-provisioning: $file has the name of another served file" >&2
            exit 1
          fi
          cp -L --no-preserve=mode,ownership "$file" ${runtimeDir}/
          echo "$name tftp" >> ${runtimeManifest}
        done
      done

      cd ${runtimeDir}
      ${lib.concatMapStrings (escape:
        lib.optionalString (filesFor escape != []) ''
          render-secrets ${escape} ${secretManifest} ${lib.escapeShellArgs (filesFor escape)}
        '') ["none" "line" "xml"]}
      if grep -rqF '@NIX_ASTERISK_SECRET:' ${runtimeDir}; then
        echo "asterix-provisioning: unresolved secret placeholder" >&2
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
    ./cisco-79xx.nix
    ./fanvil.nix
    ./grandstream.nix
    ./poly.nix
    ./snom.nix
    ./yealink.nix
  ];

  options.services.asterix.phones = {
    enable =
      mkEnableOption "serving provisioning files for phones over HTTP"
      // {
        default = cfg.devices != {};
        defaultText = literalExpression "config.services.asterix.phones.devices != { }";
      };

    network = mkOption {
      type = types.nullOr types.str;
      default = network;
      defaultText = lib.literalMD "the only network of {option}`services.asterix.networks`";
      description = "Network of {option}`services.asterix.networks` the devices are on, which gives the defaults of `listenAddress` and `allowedNetworks` and the interface the firewall opens.";
    };

    listenAddress = mkOption {
      type = types.str;
      default = net.address;
      defaultText = lib.literalMD "the address of `network`";
      example = "10.0.20.10";
      description = ''
        Address the provisioning files are served on. Keep it on the phones'
        network, since the files usually contain SIP passwords. The address
        need not exist yet when the socket starts (`FreeBind=`).
      '';
    };

    port = mkOption {
      type = types.port;
      default = 80;
      description = "HTTP port.";
    };

    allowedNetworks = mkOption {
      type = types.listOf types.str;
      default = net.subnets;
      defaultText = lib.literalMD "the subnets of `network`";
      example = ["10.0.20.0/24"];
      description = ''
        Networks allowed to connect. systemd drops other connections
        (`IPAddressAllow=` on the socket).
      '';
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
      defaultText = literalExpression "config.services.asterix.phones.listenAddress";
      example = "pbx.example.org";
      description = "Host name or address of the SIP server the devices' lines register to, without the port.";
    };

    sipPort = mkOption {
      type = types.port;
      default = 5060;
      description = "Port of {option}`services.asterix.phones.sipServer`. Devices that take the server and port as one value get the port only when it is not 5060.";
    };

    ntpServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "10.0.20.10";
      description = "NTP server of the devices. When null, they keep their default.";
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

    directories = mkOption {
      internal = true;
      visible = false;
      type = types.listOf types.path;
      default = [];
      description = "Directories whose files are served as they are, over HTTP and TFTP, to anyone in `allowedNetworks`, such as firmware. Their names are read at service start.";
    };

    httpPorts = mkOption {
      internal = true;
      visible = false;
      type = types.listOf types.port;
      default = [];
      description = "Ports HTTP is served on besides `port`, which vendor modules add for devices that fetch from a fixed port.";
    };

    validDevices = mkOption {
      internal = true;
      readOnly = true;
      type = types.attrsOf types.raw;
      default = filterAttrs (_: device: !tooManyLines device && unregistered device == [] && !sharesMac device) cfg.devices;
      description = "Devices that pass the device assertions, whose files the vendor modules write.";
    };
  };

  config = mkIf cfg.enable {
    warnings = lib.optional (cfg.adminPassword != null && !secrets.holdsSecret cfg.adminPassword) "services.asterix.phones.adminPassword is not a secret reference, so it is stored world-readable in the Nix store; use config.lib.asterisk.secret instead.";

    assertions =
      [
        {
          assertion = config.services.asterix.enable;
          message = "services.asterix.phones requires services.asterix.enable.";
        }
        {
          assertion = builtins.all (name: builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_.+-]*" name != null) (attrNames cfg.files);
          message = "services.asterix.phones.files: file names may only contain letters, digits and _.+- (no directories).";
        }
        {
          assertion = cfg.allowedNetworks != [];
          message = "services.asterix.phones.allowedNetworks is empty, so systemd would drop every connection; list the phones' networks.";
        }
        {
          assertion = invalidNetworks == [];
          message = "services.asterix.phones.allowedNetworks: entries must be addresses, networks such as 10.0.20.0/24, or any, localhost, link-local or multicast, which is what systemd takes: ${lib.concatMapStringsSep ", " (entry: "`${entry}`") invalidNetworks}.";
        }
        {
          assertion = invalidAddresses == {};
          message = "services.asterix.phones.files: allowedAddress must be one IPv4 or IPv6 address: ${lib.concatStringsSep ", " (mapAttrsToList (name: file: "${name} has `${file.allowedAddress}`") invalidAddresses)}.";
        }
        {
          # the socket's ListenStream= takes an address and the port
          assertion = isAddress cfg.listenAddress;
          message = "services.asterix.phones.listenAddress must be one IPv4 or IPv6 address: ${builtins.toJSON cfg.listenAddress}.";
        }
        {
          assertion = lib.allUnique macs;
          message = "services.asterix.phones.devices: MAC addresses must be unique.";
        }
        {
          # [v6]:port or host:port, where a bare IPv6 address has more colons
          assertion = builtins.match "[[].*|[^:]*:[^:]*" cfg.sipServer == null;
          message = "services.asterix.phones.sipServer is ${builtins.toJSON cfg.sipServer}, but takes the host alone; give the port in services.asterix.phones.sipPort.";
        }
      ]
      ++ mapAttrsToList (name: device: let
        count = cfg.models.${device.model}.lines;
      in {
        assertion = !tooManyLines device;
        message = "services.asterix.phones.devices.${name}: a ${device.model} has ${toString count} line${optionalString (count > 1) "s"}, but lines lists ${toString (builtins.length device.lines)}.";
      })
      cfg.devices
      ++ mapAttrsToList (name: device: {
        assertion = unregistered device == [];
        message = "services.asterix.phones.devices.${name}: endpoints must exist in pjsip.endpoints, have `auth` set and an `aor` named like the endpoint, since the device registers each line with one user name for both: ${lib.concatMapStringsSep ", " (e: "`${e}`") (unregistered device)}.";
      })
      cfg.devices
      ++ map (ref: {
        assertion = !(secrets.isStorePath ref) && secrets.isValidReference ref;
        message = "services.asterix.phones: invalid secret reference ${secrets.placeholderOf ref}.";
      })
      secretRefs;

    systemd.sockets.asterix-provisioning = {
      description = "Phone provisioning";
      wantedBy = ["sockets.target"];
      listenStreams = map (format.hostPort cfg.listenAddress) (lib.unique ([cfg.port] ++ cfg.httpPorts));
      socketConfig = {
        FreeBind = true;
        IPAddressDeny = "any";
        IPAddressAllow = cfg.allowedNetworks;
        FileDescriptorName = "http";
      };
    };

    systemd.sockets.asterix-provisioning-tftp = mkIf serveTftp {
      description = "Phone provisioning over TFTP";
      wantedBy = ["sockets.target"];
      listenDatagrams = [(format.hostPort cfg.listenAddress tftpPort)];
      socketConfig = {
        FreeBind = true;
        IPAddressDeny = "any";
        IPAddressAllow = cfg.allowedNetworks;
        FileDescriptorName = "tftp";
        Service = "asterix-provisioning.service";
      };
    };

    systemd.services.asterix-provisioning = let
      sockets = ["asterix-provisioning.socket"] ++ lib.optional serveTftp "asterix-provisioning-tftp.socket";
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
        ExecStartPre = "${renderer}/bin/asterix-provisioning-render";
        ExecStart = "${lib.getExe server} ${runtimeDir} ${runtimeManifest}";
        Restart = "on-failure";
        DynamicUser = true;
        LoadCredential = map (ref: "${secrets.credentialName ref}:${ref._secret}") (
          lib.filter (ref: ref ? _secret) secretRefs
        );
        RuntimeDirectory = "asterix-provisioning";
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

    networking.firewall = mkIf config.services.asterix.openFirewall (moduleLib.firewallOn (lib.optional (net.interface != null) net.interface) {
      allowedTCPPorts = lib.unique ([cfg.port] ++ cfg.httpPorts);
      allowedUDPPorts = lib.optional serveTftp tftpPort;
    });
  };
}
