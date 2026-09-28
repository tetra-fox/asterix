# Provisioning files for phones and adapters, served over HTTP by
# pkgs/provisioning-server from a systemd socket.
#
# Vendor modules (see ht801.nix) and users write `files`; their text may
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
    concatMapStringsSep
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

  cfg = config.services.asterisk.provisioning;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) secrets;

  runtimeDir = "/run/asterisk-provisioning";

  server = pkgs.callPackage ../pkgs/provisioning-server/package.nix {};

  # one line per file: `NAME`, or `NAME ADDRESS` for a file only ADDRESS may fetch
  manifest = pkgs.writeText "asterisk-provisioning-manifest" (
    concatStrings (mapAttrsToList (name: file: "${name}${optionalString (file.allowedAddress != null) " ${file.allowedAddress}"}\n") cfg.files)
  );

  listenStream =
    if lib.hasInfix ":" cfg.listenAddress
    then "[${cfg.listenAddress}]:${toString cfg.port}"
    else "${cfg.listenAddress}:${toString cfg.port}";

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

  # secret references per escaping, so one secret used in files with
  # different formats is substituted correctly in each
  refsFor = escape:
    unique (lib.concatMap (file: secrets.fromText file.text) (
      attrValues (filterAttrs (_: file: file.escape == escape) cfg.files)
    ));
  secretRefs = unique (refsFor "none" ++ refsFor "xml");

  filesFor = escape: attrNames (filterAttrs (_: file: file.escape == escape) cfg.files);

  substituteCalls = escape:
    concatMapStringsSep "\n" (
      ref: "substitute ${
        lib.escapeShellArgs ([
            escape
            (secrets.placeholderOf ref)
            (secrets.credentialName ref)
          ]
          ++ filesFor escape)
      }"
    ) (refsFor escape);

  renderer = pkgs.writeShellApplication {
    name = "asterisk-provisioning-render";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
    ];
    text = ''
      shopt -u patsub_replacement 2>/dev/null || true
      shopt -s nullglob
      umask 0077
      amp='&amp;' lt='&lt;' gt='&gt;' quot='&quot;' apos='&apos;'

      # the runtime directory is new on every start of the unit
      for template in ${templates}/*; do
        cp -L --no-preserve=mode,ownership "$template" ${runtimeDir}/
      done

      # substitute ESCAPE PLACEHOLDER CREDENTIAL FILE...
      substitute() {
        local escape=$1 placeholder=$2 credential=$3 value file content
        shift 3
        value=$(< "$CREDENTIALS_DIRECTORY/$credential")
        value=''${value%$'\r'}
        if [ "$escape" = xml ]; then
          value=''${value//&/"$amp"}
          value=''${value//</"$lt"}
          value=''${value//>/"$gt"}
          value=''${value//\"/"$quot"}
          value=''${value//\'/"$apos"}
        fi
        for file in "$@"; do
          content=$(< "${runtimeDir}/$file")
          printf '%s\n' "''${content//"$placeholder"/"$value"}" > "${runtimeDir}/$file"
        done
      }

      ${substituteCalls "none"}
      ${substituteCalls "xml"}

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
  options.services.asterisk.provisioning = {
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
          message = "services.asterisk.provisioning requires services.asterisk.enable.";
        }
        {
          assertion = builtins.all (name: builtins.match "[A-Za-z0-9_+-][A-Za-z0-9_.+-]*" name != null) (attrNames cfg.files);
          message = "services.asterisk.provisioning.files: file names may only contain letters, digits and _.+- (no directories).";
        }
      ]
      ++ map (ref: {
        assertion = !(secrets.isStorePath ref) && secrets.isValidReference ref;
        message = "services.asterisk.provisioning: invalid secret reference ${secrets.placeholderOf ref}.";
      })
      secretRefs;

    systemd.sockets.asterisk-provisioning = {
      description = "Phone provisioning";
      wantedBy = ["sockets.target"];
      listenStreams = [listenStream];
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
