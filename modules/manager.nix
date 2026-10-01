# AMI is off by default. When enabled it listens on the loopback address; users are
# restricted to the loopback network unless `permit` says otherwise, receive
# no events and may run no actions unless `read` and `write` list them, and
# the firewall is only opened when `openFirewall` is set.
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
  inherit (import ./lib.nix {inherit lib;}) limited secretMaxLengths;

  # manager.c takes a section called general in any case for its settings and
  # skips it as a user (main/manager.c __init_manager)
  reserved = builtins.filter (name: lib.toLower name == "general") (builtins.attrNames acfg.users);

  # AMI reads a line into 1024 bytes and drops a longer one, logging its first
  # 25 bytes (main/manager.c:298 and get_input), so a Login's `Secret: ` line
  # with its CRLF leaves 1014 bytes for the secret
  secretBytes = 1014;
  users = builtins.filter (s: lib.toLower s.name != "general") (format.resolveInheritance (cfg.settings."manager.conf" or {})).sections;
  userSecrets = lib.concatMap (user: let
    ctx = {
      file = "manager.conf";
      section = user.name;
      key = "secret";
    };
  in
    map (secret: limited user.name secretBytes (format.mkValueString {inherit ctx;} secret)) (lib.toList (user.secret or [])))
  users;
  longSecrets = builtins.filter (secret: secret.room < 0) userSecrets;

  # the classes manager.c knows, in lower case only; it ignores any other
  # without a word (main/manager.c:750-775 and get_perm)
  class = types.enum [
    "system"
    "call"
    "log"
    "verbose"
    "command"
    "agent"
    "user"
    "config"
    "dtmf"
    "reporting"
    "cdr"
    "dialplan"
    "originate"
    "agi"
    "cc"
    "aoc"
    "test"
    "security"
    "message"
    "all"
    "none"
  ];

  userType = types.submodule {
    options = {
      secret = mkOption {
        type = format.types.secretOrString;
        description = ''
          Password, normally a secret reference. A Login sends it in a line
          that AMI reads into 1024 bytes, `Secret: ` and the line end
          included, so it can have 1014 bytes.
        '';
      };
      read = mkOption {
        type = types.listOf class;
        default = [];
        example = [
          "system"
          "call"
        ];
        description = ''
          Event classes the user receives (`read`); none by default. `all`
          includes `dtmf`, every key pressed in any call, voicemail and
          conference PINs among them.
        '';
      };
      write = mkOption {
        type = types.listOf class;
        default = [];
        example = [
          "system"
          "call"
          "originate"
        ];
        description = ''
          Action classes the user may run (`write`); none by default.
          `system` and `command` let the user read every secret Asterisk
          holds (PJSIPShowAuths, `Command` with any CLI command) and start
          programs as Asterisk; `call` and `reporting` let it read voicemail
          PINs (`Getvar` of `VM_INFO(<mailbox>,password)`). The actions on
          configuration files (GetConfig, GetConfigJSON, ListCategories,
          UpdateConfig, CreateConfig) refuse every file: without
          `live_dangerously` in asterisk.conf, Asterisk takes only files whose
          real path is inside its configuration directory, and
          {file}`/run/asterisk/config` is a link to a new directory from each
          start and reload.
        '';
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
      description = ''
        Address AMI listens on. The service waits for a specific address as
        for a SIP transport's, see
        {option}`services.asterisk.pjsip.transports.<name>.address`.
      '';
    };

    port = mkOption {
      # Asterisk logs a lower port as invalid and then binds an uninitialized
      # one (main/manager.c:9797-9802)
      type = types.ints.between 1024 65535;
      default = 5038;
      description = "TCP port AMI listens on; Asterisk takes none below 1024.";
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
      description = "AMI users. Asterisk takes `general`, in any case, for its settings.";
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

      firewall.ami = acfg.openFirewall;

      secretMaxLengths = secretMaxLengths userSecrets;
    };

    # the flag comes first, so its type is checked when openFirewall is off
    warnings = lib.optional (acfg.openFirewall && !cfg.openFirewall) "services.asterisk.ami.openFirewall opens the AMI port only together with services.asterisk.openFirewall, which is off.";

    assertions = [
      {
        assertion = reserved == [];
        message = "services.asterisk.ami.users: `general` is reserved, in any case: ${concatStringsSep ", " reserved}.";
      }
      {
        assertion = longSecrets == [];
        message = "services.asterisk: AMI secrets longer than the ${toString secretBytes} bytes a Login can send, since AMI reads a line into 1024 bytes with `Secret: ` and the line end; use shorter ones: ${concatStringsSep ", " (map (secret: secret.what) longSecrets)}.";
      }
    ];
  };
}
