# services.asterix.trunks: provider accounts, written to
# services.asterisk.pjsip.trunks. Calls from a trunk start in
# pbx-inbound-<name>, and it sends over the transport of its network.
{
  config,
  lib,
  options,
  ...
}: let
  inherit
    (lib)
    mkDefault
    mkIf
    mkOption
    types
    ;

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};

  core = options.services.asterisk.pjsip.trunks.type;
  layer = {
    name,
    config,
    ...
  }: {
    options.network = mkOption {
      type = types.nullOr types.str;
      default = null;
      defaultText = lib.literalMD "the only network of {option}`services.asterix.networks`";
      example = "wan";
      description = "Network of {option}`services.asterix.networks` the trunk sends over.";
    };
    config = {
      context = mkDefault (pbxLib.objectContext "inbound" name);
      transport = let
        network = pbxLib.networkOf cfg.networks config;
      in
        mkIf (network != null && cfg.networks ? ${network}) (mkDefault (pbxLib.pinned network cfg.networks.${network}));
    };
  };
in {
  options.services.asterix.trunks = mkOption {
    # the core's type, with `layer` added to the modules of each trunk
    type = core.substSubModules (core.getSubModules ++ [layer]);
    default = {};
    example = lib.literalExpression ''
      {
        provider = {
          host = "sip.provider.example";
          username = "5551000";
          password = config.lib.asterisk.secret config.sops.secrets.trunk.path;
          identify.match = [ "203.0.113.0/24" ];
        };
      }
    '';
    description = ''
      SIP provider accounts, with the options of
      {option}`services.asterisk.pjsip.trunks` and `network`. Calls from a
      trunk start in `pbx-inbound-<name>`, which holds its numbers of
      {option}`services.asterix.inbound`, unless it sets a `context` of its
      own. It sends over the transport of its network unless it sets a
      `transport`.
    '';
  };

  config = mkIf cfg.enable {
    # every submodule value carries `_module`, and the core has no `network`
    services.asterisk.pjsip.trunks = lib.mapAttrs (_: trunk: removeAttrs trunk ["_module" "network"]) cfg.trunks;
  };
}
