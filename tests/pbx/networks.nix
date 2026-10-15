# What services.asterix.networks turns into: transports, the global ACL with
# the trunks' addresses, the transport and contact ACL of each extension and
# trunk, and the interfaces the firewall opens, which phones do not break
# when there are several networks and no phones.network
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (import ../eval-lib.nix {inherit pkgs self;}) evalConfig;

  secret = config: name: config.lib.asterisk.secret "/run/secrets/${name}";

  configOf = networks:
    evalConfig [
      ({config, ...}: {
        imports = [self.nixosModules.default];
        services.asterix =
          {
            enable = true;
            openFirewall = true;
            extensions = {
              "201" = {
                password = secret config "201";
                network = lib.mkIf (networks != null) "lan";
              };
              "202" = {
                password = secret config "202";
                network = lib.mkIf (networks != null) "voip";
              };
            };
            trunks.provider = {
              host = "sip.provider.example";
              username = "5551000";
              password = secret config "trunk";
              identify.match = ["203.0.113.0/24"];
              network = lib.mkIf (networks != null) "wan";
            };
          }
          // lib.optionalAttrs (networks != null) {inherit networks;};
      })
    ];

  restricted = configOf {
    lan = {
      interface = "lan";
      address = "10.0.10.1";
      subnets = ["10.0.10.0/24"];
    };
    voip = {
      interface = "voip";
      address = "10.0.20.1";
      subnets = ["10.0.20.0/24"];
      protocols = ["tcp" "tls"];
      tls.certFile = "/run/secrets/cert";
      tls.keyFile = "/run/secrets/key";
    };
    wan = {
      interface = "wan";
      address = "198.51.100.2";
      subnets = ["198.51.100.0/30"];
      externalAddress = "203.0.113.5";
    };
  };

  pick = config: let
    pjsip = config.services.asterisk.pjsip;
  in {
    transports = lib.mapAttrs (_: t: {inherit (t) protocol address externalSignalingAddress localNet;}) pjsip.transports;
    acls = lib.mapAttrs (_: a: {inherit (a) deny permit;}) pjsip.acls;
    endpoints = lib.mapAttrs (_: e: {
      inherit (e) transport;
      contact_permit = e.settings.contact_permit or null;
    }) (lib.getAttrs ["201" "202"] pjsip.endpoints);
    trunk = pjsip.trunks.provider.transport;
    firewall = {
      inherit (config.services.asterisk) firewallInterfaces;
      inherit (config.networking.firewall) allowedTCPPorts;
      interfaces = builtins.attrNames config.networking.firewall.interfaces;
    };
  };
in {
  run = lib.runTests;
  tests = {
    # one network on every address, no ACL, the firewall on every interface
    testDefaultNetwork = {
      expr = pick (configOf null);
      expected = {
        transports.default = {
          protocol = "udp";
          address = "0.0.0.0";
          externalSignalingAddress = null;
          localNet = [];
        };
        acls = {};
        endpoints = {
          "201" = {
            transport = "default";
            contact_permit = null;
          };
          "202" = {
            transport = "default";
            contact_permit = null;
          };
        };
        trunk = "default";
        firewall = {
          firewallInterfaces = [];
          allowedTCPPorts = [5060];
          interfaces = [];
        };
      };
    };

    testRestrictedNetworks = {
      expr = pick restricted;
      expected = {
        transports = {
          lan = {
            protocol = "udp";
            address = "10.0.10.1";
            externalSignalingAddress = null;
            localNet = [];
          };
          voip-tcp = {
            protocol = "tcp";
            address = "10.0.20.1";
            externalSignalingAddress = null;
            localNet = [];
          };
          voip-tls = {
            protocol = "tls";
            address = "10.0.20.1";
            externalSignalingAddress = null;
            localNet = [];
          };
          wan = {
            protocol = "udp";
            address = "198.51.100.2";
            externalSignalingAddress = "203.0.113.5";
            localNet = ["198.51.100.0/30"];
          };
        };
        # one ACL, since pjsip applies every ACL to every request
        acls.asterix-networks = {
          deny = [
            "0.0.0.0/0.0.0.0"
            "::/0"
          ];
          permit = [
            "10.0.10.0/24"
            "10.0.20.0/24"
            "198.51.100.0/30"
            "203.0.113.0/24"
          ];
        };
        endpoints = {
          "201" = {
            transport = "lan";
            contact_permit = ["10.0.10.0/24"];
          };
          "202" = {
            transport = "voip-tcp";
            contact_permit = ["10.0.20.0/24"];
          };
        };
        trunk = "wan";
        firewall = {
          firewallInterfaces = ["lan" "voip" "wan"];
          allowedTCPPorts = [];
          interfaces = ["lan" "voip" "wan"];
        };
      };
    };
  };
}
