# Provisioning files for phones and adapters, served over HTTP by nginx.
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
    filterAttrs
    literalExpression
    mapAttrs'
    mapAttrsToList
    mkEnableOption
    mkIf
    mkOption
    nameValuePair
    types
    unique
    ;

  cfg = config.services.asterisk.provisioning;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) secrets;

  runtimeDir = "/run/asterisk-provisioning";

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
          Only this address may download the file. Use it for files that contain
          one device's password, together with a static DHCP lease.
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

  # nginx binds `listenAddress` and fails if it is not configured yet: the
  # static address of an interface other than the default gateway's is not
  # ordered before network-online.target. nginx starts after this unit.
  waitForAddress = pkgs.writeShellScript "asterisk-provisioning-wait" ''
    waited=0
    until [ -n "$(${pkgs.iproute2}/bin/ip -o address show to ${lib.escapeShellArg cfg.listenAddress} -tentative)" ]; do
      if [ "$waited" -eq 0 ]; then
        echo "asterisk-provisioning: waiting for address ${cfg.listenAddress}"
      elif [ "$waited" -ge 90 ]; then
        echo "asterisk-provisioning: address ${cfg.listenAddress} is not configured on this host" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/sleep 1
      waited=$((waited + 1))
    done
  '';
  waitsForAddress = !(builtins.elem cfg.listenAddress ["0.0.0.0" "::"]);

  substituteCalls = escape:
    concatMapStringsSep "\n" (
      ref: "substitute ${
        lib.escapeShellArgs ([
            escape
            (secrets.placeholder ref)
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

      new=$(mktemp -d "${runtimeDir}/.new.XXXXXXXX")
      for template in ${templates}/*; do
        cp -L --no-preserve=mode,ownership "$template" "$new"/
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
          content=$(< "$new/$file")
          printf '%s\n' "''${content//"$placeholder"/"$value"}" > "$new/$file"
        done
      }

      ${substituteCalls "none"}
      ${substituteCalls "xml"}

      if grep -rqF '@NIX_ASTERISK_SECRET:' "$new"; then
        echo "asterisk-provisioning: unresolved secret placeholder" >&2
        exit 1
      fi

      find ${runtimeDir} -maxdepth 1 -type f -delete
      for file in "$new"/*; do
        chmod 0400 "$file"
        mv "$file" ${runtimeDir}/
      done
      rmdir "$new"
    '';
  };
in {
  options.services.asterisk.provisioning = {
    enable = mkEnableOption "serving provisioning files for phones over HTTP";

    listenAddress = mkOption {
      type = types.str;
      example = "10.0.20.10";
      description = ''
        Address nginx serves the provisioning files on, on the phones'
        network only: the files usually contain SIP passwords.
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
        message = "services.asterisk.provisioning: invalid secret reference ${secrets.placeholder ref}.";
      })
      secretRefs;

    systemd.services.asterisk-provisioning = {
      description = "Render phone provisioning files";
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
        ExecStart = "${renderer}/bin/asterisk-provisioning-render";
        User = config.services.nginx.user;
        Group = config.services.nginx.group;
        LoadCredential = map (ref: "${secrets.credentialName ref}:${ref._secret}") (
          lib.filter (ref: ref ? _secret) secretRefs
        );
        # owner only: nginx serves the files, the renderer (same user) writes them
        RuntimeDirectory = "asterisk-provisioning";
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
      virtualHosts.asterisk-provisioning = {
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
            name: file:
              nameValuePair "= /${name}" {
                extraConfig = lib.optionalString (file.allowedAddress != null) ''
                  allow ${file.allowedAddress};
                  deny all;
                '';
              }
          )
          cfg.files;
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
