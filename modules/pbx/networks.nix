# services.asterix.networks: where phones and trunks are reached. Each network
# turns into PJSIP transports on its address, the firewall on its interface,
# the subnets of the global ACL, and the contact ACL of its extensions.
{
  config,
  lib,
  ...
}: let
  inherit
    (lib)
    concatMap
    concatStringsSep
    filterAttrs
    mkDefault
    mkIf
    mkOption
    optional
    optionalAttrs
    types
    ;

  cfg = config.services.asterix;
  core = config.services.asterisk;

  networkType = types.submodule {
    options = {
      interface = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "voip";
        description = "Interface the firewall is opened on, with {option}`services.asterix.openFirewall`. Without it, every interface.";
      };
      address = mkOption {
        type = types.str;
        default = "0.0.0.0";
        example = "10.0.20.10";
        description = "Address of the PBX on this network, which its transports bind; `0.0.0.0` or `::` for all addresses.";
      };
      subnets = mkOption {
        type = types.listOf types.str;
        default = [];
        example = ["10.0.20.0/24"];
        description = ''
          Networks the phones of this network are in. Their extensions accept
          registrations only from there. When every network lists subnets,
          the PBX takes SIP requests only from them and from the
          `identify.match` addresses of the trunks; empty, from anywhere.
        '';
      };
      protocols = mkOption {
        type = types.nonEmptyListOf (types.enum ["udp" "tcp" "tls"]);
        default = ["udp"];
        description = ''
          SIP transports on `address`: transport `<network>` for `udp`, which
          takes TCP on its port too ({option}`services.asterisk.pjsip.transports.<name>.tcp`),
          `<network>-tcp` for `tcp` without `udp`, and `<network>-tls` for
          `tls`. Extensions of the network send over the first of udp, tcp
          and tls it has.
        '';
      };
      externalAddress = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "203.0.113.5";
        description = ''
          Public address of a PBX behind NAT, which its SIP headers and SDP
          give to peers outside `subnets`.
        '';
      };
      tls = {
        certFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Certificate chain (PEM) of the `tls` transport, loaded as a systemd credential, so it may be readable by root only.";
        };
        keyFile = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Private key (PEM) of the `tls` transport, loaded as a systemd credential.";
        };
      };
    };
  };

  networkNames = builtins.attrNames cfg.networks;
  only =
    if builtins.length networkNames == 1
    then builtins.head networkNames
    else null;

  # the network an extension is on, or null when it names none and there are
  # several
  networkOf = e:
    if e.network != null
    then e.network
    else only;

  # the transport the extensions of a network send over
  pinned = name: n:
    if builtins.elem "udp" n.protocols
    then name
    else if builtins.elem "tcp" n.protocols
    then "${name}-tcp"
    else "${name}-tls";

  transportsOf = name: n: let
    shared =
      {address = mkDefault n.address;}
      // optionalAttrs (n.externalAddress != null) {
        externalSignalingAddress = mkDefault n.externalAddress;
        externalMediaAddress = mkDefault n.externalAddress;
        localNet = mkDefault n.subnets;
      };
    has = protocol: builtins.elem protocol n.protocols;
  in
    optionalAttrs (has "udp") {${name} = shared // {protocol = "udp";};}
    // optionalAttrs (has "tcp" && !(has "udp")) {"${name}-tcp" = shared // {protocol = "tcp";};}
    // optionalAttrs (has "tls" && n.tls.certFile != null && n.tls.keyFile != null) {
      "${name}-tls" =
        shared
        // {
          protocol = "tls";
          tls.certFile = mkDefault n.tls.certFile;
          tls.keyFile = mkDefault n.tls.keyFile;
        };
    };

  # an address or network a pjsip ACL takes, which a host name is not
  isAddress = entry: builtins.match "[0-9.]+(/[0-9.]+)?" entry != null || lib.hasInfix ":" entry;

  restricted = cfg.networks != {} && builtins.all (n: n.subnets != []) (builtins.attrValues cfg.networks);
  trunkAddresses = concatMap (t: lib.optionals (t.identify != null) (builtins.filter isAddress t.identify.match)) (builtins.attrValues core.pjsip.trunks);

  unknown = builtins.filter (number: let
    network = networkOf cfg.extensions.${number};
  in
    network != null && !(cfg.networks ? ${network})) (builtins.attrNames cfg.extensions);
  unplaced = builtins.filter (number: networkOf cfg.extensions.${number} == null) (builtins.attrNames cfg.extensions);
  tlsWithoutKeys = builtins.attrNames (filterAttrs (_: n: builtins.elem "tls" n.protocols && (n.tls.certFile == null || n.tls.keyFile == null)) cfg.networks);
  interfaces = map (n: n.interface) (builtins.attrValues cfg.networks);
in {
  options.services.asterix = {
    networks = mkOption {
      type = types.attrsOf networkType;
      default = {default = {};};
      defaultText = lib.literalExpression "{ default = { }; }";
      example = lib.literalExpression ''
        {
          voip = { interface = "voip"; address = "10.0.20.10"; subnets = [ "10.0.20.0/24" ]; };
          lan = { interface = "lan"; address = "10.0.10.10"; subnets = [ "10.0.10.0/24" ]; };
        }
      '';
      description = ''
        Networks the PBX is reached on. Without any, one network named
        `default` takes UDP and TCP on port 5060 on every address, from
        anywhere.
      '';
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Open what the PBX uses on the interfaces of the networks, or on every
        interface when a network has none: the ports of its SIP transports,
        the RTP range, and with phones to provision, their HTTP port and
        TFTP if a file is served over it.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.networks != {};
        message = "services.asterix.networks is empty, so phones have no transport to reach the PBX on. Remove the definition to get the default network, or define one.";
      }
      {
        assertion = unplaced == [];
        message = "services.asterix.extensions: ${concatStringsSep ", " unplaced} name no network, and there are several (${concatStringsSep ", " networkNames}). Set network on each.";
      }
      {
        assertion = unknown == [];
        message = "services.asterix.extensions: ${concatStringsSep ", " (map (number: "${number} (${networkOf cfg.extensions.${number}})") unknown)} name networks that are not in services.asterix.networks.";
      }
      {
        assertion = tlsWithoutKeys == [];
        message = "services.asterix.networks: ${concatStringsSep ", " tlsWithoutKeys} take tls, which needs tls.certFile and tls.keyFile.";
      }
    ];

    services.asterisk = {
      openFirewall = mkDefault cfg.openFirewall;
      firewallInterfaces = mkIf (!(builtins.elem null interfaces)) (mkDefault (lib.unique interfaces));

      pjsip.transports = lib.mkMerge (lib.mapAttrsToList transportsOf cfg.networks);

      # pjsip ACLs apply to every request, so the networks share one
      pjsip.acls = mkIf restricted {
        asterix-networks = {
          deny = [
            "0.0.0.0/0.0.0.0"
            "::/0"
          ];
          permit = concatMap (n: n.subnets) (builtins.attrValues cfg.networks) ++ trunkAddresses;
        };
      };

      pjsip.endpoints = lib.mapAttrs (_: e: let
        name = networkOf e;
        n = cfg.networks.${name};
      in
        mkIf (name != null && cfg.networks ? ${name}) {
          transport = mkDefault (pinned name n);
          settings = mkIf (n.subnets != []) {
            contact_deny = mkDefault [
              "0.0.0.0/0.0.0.0"
              "::/0"
            ];
            contact_permit = mkDefault n.subnets;
          };
        })
      cfg.extensions;
    };
  };
}
