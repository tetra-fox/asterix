# Provisioning files for phones and adapters, served over HTTP by
# pkgs/provisioning-server from a systemd socket.
#
# Vendor modules (see grandstream/) and users write `files`; their text may
# contain secret references, which are substituted at service start into a
# tmpfs like Asterisk's own configuration, so the store only holds
# placeholders. Secrets given as systemd credentials (`credential "name"`) must
# also be loaded into asterisk-provisioning.service.
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

  runtimeDir = "/run/asterisk-provisioning";

  server = pkgs.callPackage ../../../pkgs/provisioning-server/package.nix {};

  # one line per file: `NAME`, or `NAME ADDRESS` for a file only ADDRESS may fetch
  manifest = pkgs.writeText "asterisk-provisioning-manifest" (
    concatStrings (mapAttrsToList (name: file: "${name}${optionalString (file.allowedAddress != null) " ${file.allowedAddress}"}\n") cfg.files)
  );

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
          "xml"
        ];
        default = "none";
        description = "How secret values are escaped when they are substituted into the file.";
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
        '') ["none" "xml"]}
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
  imports = [./grandstream/ht801.nix];

  options.pbx.phones = {
    enable = mkEnableOption "serving provisioning files for phones over HTTP";

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
      description = "Open the HTTP port on `firewallInterfaces`.";
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
  };

  config = mkIf cfg.enable {
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
      ]
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
      };
    };

    systemd.services.asterisk-provisioning = {
      description = "Phone provisioning";
      # started at boot rather than on the first request, so a missing secret
      # shows up in the unit's status right away
      wantedBy = ["multi-user.target"];
      requires = ["asterisk-provisioning.socket"];
      after = ["asterisk-provisioning.socket"];
      serviceConfig = {
        Type = "exec";
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

        # the socket from the .socket unit is the only network access (the
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

    networking.firewall = mkIf cfg.openFirewall (moduleLib.firewallOn cfg.firewallInterfaces {allowedTCPPorts = [cfg.port];});
  };
}
