# AMI is off by default. When enabled it listens on the loopback address; users are
# restricted to the loopback network unless `permit` says otherwise, and the
# firewall is only opened when `openFirewall` is set.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatStringsSep
    mapAttrs'
    mkDefault
    mkIf
    mkMerge
    mkOption
    nameValuePair
    types
    ;

  cfg = config.services.asterisk;
  acfg = cfg.ami;
  asteriskLib = import ../lib {inherit lib;};
  inherit (asteriskLib) format;

  secretOrString =
    types.either types.str format.types.secret
    // {
      description = "string or secret reference";
    };

  userType = types.submodule {
    options = {
      secret = mkOption {
        type = secretOrString;
        description = "Password, normally a secret reference.";
      };
      read = mkOption {
        type = types.listOf types.str;
        default = ["all"];
        example = [
          "system"
          "call"
        ];
        description = "Event classes the user receives (`read`).";
      };
      write = mkOption {
        type = types.listOf types.str;
        default = [];
        example = [
          "system"
          "call"
          "originate"
        ];
        description = "Action classes the user may run (`write`); none by default.";
      };
      permit = mkOption {
        type = types.listOf types.str;
        default = [
          "127.0.0.1/255.255.255.255"
          "::1/128"
        ];
        description = "Networks the user may connect from; everything else is denied.";
      };
      settings = mkOption {
        type = types.attrsOf format.types.value;
        default = {};
        example = {
          writetimeout = 1000;
        };
        description = "Additional keys of the user's section.";
      };
    };
  };
in {
  options.services.asterisk.ami = {
    enable = lib.mkEnableOption "the Asterisk Manager Interface (AMI)";

    address = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Address AMI listens on.";
    };

    port = mkOption {
      type = types.port;
      default = 5038;
      description = "TCP port AMI listens on.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open the AMI port (on {option}`services.asterisk.firewallInterfaces`
        when {option}`services.asterisk.openFirewall` is set). AMI
        is unencrypted; prefer a tunnel.
      '';
    };

    users = mkOption {
      type = types.attrsOf userType;
      default = {};
      example = lib.literalExpression ''
        {
          monitoring.secret = config.lib.asterisk.secret config.sops.secrets.ami-monitoring.path;
          dialer = {
            secret = config.lib.asterisk.secret config.sops.secrets.ami-dialer.path;
            write = [ "originate" "call" ];
          };
        }
      '';
      description = "AMI users.";
    };

    settings = mkOption {
      type = types.attrsOf format.types.value;
      default = {};
      example = {
        displayconnects = false;
      };
      description = "Additional keys of manager.conf's `[general]` section.";
    };
  };

  config = mkIf (cfg.enable && acfg.enable) {
    services.asterisk = {
      settings."manager.conf" =
        {
          general = mkMerge [
            {
              enabled = mkDefault true;
              bindaddr = mkDefault acfg.address;
              port = mkDefault acfg.port;
            }
            acfg.settings
          ];
        }
        // mapAttrs' (
          name: u:
            nameValuePair "user:${name}" (mkMerge [
              {
                inherit name;
                secret = mkDefault u.secret;
                read = mkIf (u.read != []) (mkDefault (concatStringsSep "," u.read));
                write = mkIf (u.write != []) (mkDefault (concatStringsSep "," u.write));
                deny = [
                  "0.0.0.0/0.0.0.0"
                  "::/0"
                ];
                inherit (u) permit;
              }
              u.settings
            ])
        )
        acfg.users;

      firewall.tcpPorts = mkIf acfg.openFirewall [acfg.port];
    };

    assertions = [
      {
        assertion = !(acfg.users ? general);
        message = "services.asterisk.ami.users: `general` is reserved.";
      }
    ];
  };
}
