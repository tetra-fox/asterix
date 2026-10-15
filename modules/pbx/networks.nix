# services.asterix.networks: where phones and trunks are reached. Each network
# turns into PJSIP transports on its address, the firewall on its interface,
# the subnets of the global ACL, and the contact ACL of its extensions. The
# trunks send over its transport too, see trunks.nix.
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
    optionalAttrs
    types
    ;

  cfg = config.services.asterix;
  pbxLib = import ./lib.nix {inherit lib;};
  inherit (import ../lib.nix {inherit lib;}) isAddress;

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
          registrations only from there. When every network with extensions
          lists subnets, the PBX takes SIP requests only from them and from
          the addresses of the trunks. A network of trunks alone needs none.
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
  networkOf = pbxLib.networkOf cfg.networks;

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

  # a network of trunks alone needs no subnets, the trunks' addresses cover it
  onNetwork = name: objects: builtins.any (o: networkOf o == name) (builtins.attrValues objects);
  trunksOnly = name: onNetwork name cfg.trunks && !(onNetwork name cfg.extensions);
  restricted = cfg.networks != {} && builtins.all (name: cfg.networks.${name}.subnets != [] || trunksOnly name) networkNames;
  # core-only trunks too, since the ACL applies to all of them
  trunks = config.services.asterisk.pjsip.trunks;
  matchOf = t: lib.optionals (t.identify != null) t.identify.match;
  addressesOf = t: builtins.filter isAddress (matchOf t ++ [t.host]);
  trunkAddresses = concatMap addressesOf (builtins.attrValues trunks);
  # trunks whose provider the global ACL keeps out, as it takes no host names
  unreachableTrunks = builtins.attrNames (filterAttrs (_: t: addressesOf t == [] || !(builtins.all isAddress (matchOf t))) trunks);

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
    assertions =
      [
        {
          assertion = cfg.networks != {};
          message = "services.asterix.networks is empty, so phones have no transport to reach the PBX on. Remove the definition to get the default network, or define one.";
        }
      ]
      ++ concatMap (kind: let
        objects = cfg.${kind};
        unplaced = builtins.filter (name: networkOf objects.${name} == null) (builtins.attrNames objects);
        unknown = builtins.filter (name: let
          network = networkOf objects.${name};
        in
          network != null && !(cfg.networks ? ${network})) (builtins.attrNames objects);
      in [
        {
          assertion = unplaced == [];
          message = "services.asterix.${kind}: ${concatStringsSep ", " unplaced} name no network, and there are several (${concatStringsSep ", " networkNames}). Set network on each.";
        }
        {
          assertion = unknown == [];
          message = "services.asterix.${kind}: ${concatStringsSep ", " (map (name: "${name} (${networkOf objects.${name}})") unknown)} name networks that are not in services.asterix.networks.";
        }
      ]) ["extensions" "trunks"]
      ++ [
        {
          assertion = !restricted || unreachableTrunks == [];
          message = "services.asterix.trunks: ${concatStringsSep ", " unreachableTrunks} have no address as host or in identify.match, or host names in identify.match. Every network with extensions lists subnets, so the PBX takes SIP requests only from them and from those addresses of the trunks, and a pjsip ACL takes no host names, so it would reject the provider's requests, the BYE that ends a call included. List the provider's addresses or networks in identify.match.";
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
          permit = lib.unique (concatMap (n: n.subnets) (builtins.attrValues cfg.networks) ++ trunkAddresses);
        };
      };

      pjsip.endpoints = lib.mapAttrs (_: e: let
        name = networkOf e;
        n = cfg.networks.${name};
      in
        mkIf (name != null && cfg.networks ? ${name}) {
          transport = mkDefault (pbxLib.pinned name n);
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
