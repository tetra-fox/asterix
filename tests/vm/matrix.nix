# One VM test of the environment matrix (tests/campaign/matrix.py). Each pbx
# node runs the Asterisk package, IP family (IPv4 with IPv6 turned off, IPv6
# alone, or both), host networking and firewall of its rows, and offers every
# transport of its families: on the internet, or behind the office router,
# which forwards the pbx's SIP and RTP ports from a public address of its own
# and names it to the pbx's transports as their external address. Each row
# is a pair of phones, A and B, and C for transfers, with the row's
# transport, codecs and DTMF mode, on the internet or behind the home router,
# which masquerades them (both families), and endpoints whose passwords are
# secrets of the row's kind: sops-nix, plain files or systemd credentials. In
# a dual stack row A is on IPv4, B and C on IPv6. Phones of each family run on
# machines of that family alone, as pjsua offers IPv4 media wherever it has
# an IPv4 address. The script is matrix.py.
#
#   internet  VLAN 1  198.51.100.0/24, 2001:db8:100::/64: pbxs .11 on, the
#             office router .2 and .101 on (one per pbx behind it), the home
#             router .3, phones4 and phones6 .200; the default route of those
#             on no router is .1, which is no one
#   office    VLAN 2  10.0.0.0/24, fd00:10::/64: office router .1, pbxs .11 on
#   home      VLAN 3  192.168.0.0/24, fd00:20::/64: home router .1, home4 and home6 .50
{
  pkgs,
  self,
  sopsSecrets,
  # a test of tests/campaign/matrix-*.json
  test,
  # the phones and the files the test makes, from the flake's nixpkgs when
  # pkgs is another
  harnessPkgs ? pkgs,
}: let
  inherit (pkgs) lib;

  pbxs = lib.imap1 (index: pbx: pbx // {inherit index;}) test.pbxs;
  pbxNamed = lib.listToAttrs (map (pbx: lib.nameValuePair pbx.name pbx) pbxs);
  behindNat = pbx: pbx.behind-nat;
  natted = builtins.filter behindNat pbxs;
  phonesBehindNat = row: builtins.elem row.nat ["phones" "both"];

  families = pbx:
    {
      ipv4 = ["v4"];
      ipv6 = ["v6"];
      dual = ["v4" "v6"];
    }
    .${
      pbx.ip
    };
  has = pbx: family: builtins.elem family (families pbx);

  # the first part of each network's addresses, which host numbers complete,
  # and a host's addresses on one
  networks = {
    internet = {
      v4 = "198.51.100.";
      v6 = "2001:db8:100::";
    };
    office = {
      v4 = "10.0.0.";
      v6 = "fd00:10::";
    };
    home = {
      v4 = "192.168.0.";
      v6 = "fd00:20::";
    };
  };
  on = network: number: lib.mapAttrs (_: prefix: "${prefix}${toString number}") networks.${network};
  vlans = {
    internet = 1;
    office = 2;
    home = 3;
  };

  # the network the pbx is on, its own addresses there, those phones reach it
  # at, and its default routes: the office router's, and on the internet an
  # address no one has
  site = pbx:
    if behindNat pbx
    then "office"
    else "internet";
  own = pbx: on (site pbx) (10 + pbx.index);
  public = pbx:
    if behindNat pbx
    then on "internet" (100 + pbx.index)
    else own pbx;
  gateway = pbx: on (site pbx) 1;

  rows = lib.imap1 (index: row: let
    pbx = pbxNamed.${row.pbx};
    websocket = builtins.elem row.transport ["ws" "wss"];
    # A, B and C, which only the call script needs
    roles =
      if websocket
      then ["a" "b"]
      else ["a" "b" "c"];
    family = role:
      if pbx.ip == "dual"
      then
        (
          if role == "a"
          then "v4"
          else "v6"
        )
      else builtins.head (families pbx);
    codec = role: let
      pair = lib.splitString "-" row.codecs;
    in
      if row.codecs == "same"
      then "ulaw"
      else if role == "a"
      then builtins.head pair
      else lib.last pair;
    server = role: let
      address = (public pbx).${family role};
      host =
        if family role == "v6"
        then "[${address}]"
        else address;
    in
      host
      + {
        udp = "";
        tcp = ";transport=tcp";
        tls = ":5061;transport=tls";
        ws = ":8088;transport=ws";
        wss = ":8089;transport=wss";
      }
      .${
        row.transport
      };
  in
    row
    // {
      inherit websocket;
      phones =
        lib.imap1 (n: role: let
          extension = toString (1000 + 10 * index + n);
        in {
          inherit role extension;
          password = "pw-${extension}";
          server = server role;
          codec = codec role;
          family = family role;
          pbxAddress = (public pbx).${family role};
          machine =
            (
              if phonesBehindNat row
              then "home"
              else "phones"
            )
            + lib.removePrefix "v" (family role);
        })
        roles;
      # where the pbx's own addresses are private, the part they share
      private = lib.optionals (behindNat pbx) (lib.attrValues networks.office);
    })
  test.rows;
  rowsOn = pbx: builtins.filter (row: row.pbx == pbx.name) rows;

  certificates = import ./certificates.nix {
    pkgs = harnessPkgs;
    pbx = lib.concatMapStringsSep "," (address: "IP:${address}") (lib.concatMap (pbx: map (family: (public pbx).${family}) (families pbx)) pbxs);
  };

  # held parties hear this tone instead of music, which is none of the
  # phones' tones, nor half or twice one (tests/vm/phone.py)
  holdTone = 2500;
  holdMusic = harnessPkgs.runCommand "hold-tone" {nativeBuildInputs = [harnessPkgs.sox];} ''
    mkdir $out
    sox -n -r 8000 -b 16 -c 1 $out/tone.wav synth 5 sine ${toString holdTone} vol 0.05
  '';

  # what phones send as RFC 4733 events and SIP INFO, every key and two equal
  # ones in a row, and as tones from the start of a call without the second
  # of those, since Asterisk relays two equal keys in a row as tones as one
  # (F138, tests/vm/dtmf-tones.py)
  keys = "01234456789*#";
  distinct = lib.concatStrings (lib.foldl' (kept: key:
    if kept != [] && lib.last kept == key
    then kept
    else kept ++ [key]) [] (lib.stringToCharacters keys));
  keypad = harnessPkgs.runCommand "matrix-keypad" {nativeBuildInputs = [(harnessPkgs.python3.withPackages (p: [p.numpy]))];} ''
    mkdir $out
    cp ${./tones.py} tones.py
    PYTHONPATH=. python3 ${./dtmf-tones.py} "$out" '{"keys.wav": [1.5, "${distinct}"]}'
  '';

  address = address: prefixLength: {inherit address prefixLength;};

  # a machine on `vlan` with these addresses and default routes, and no
  # network from QEMU, so the default route is the one to use
  host = {
    vlan,
    v4 ? null,
    v6 ? null,
    gateway,
  }: {
    imports = [./common.nix];
    virtualisation.vlans = [vlan];
    virtualisation.qemu.networkingOptions = lib.mkForce [];
    networking = {
      useDHCP = false;
      interfaces.eth1 = {
        ipv4.addresses = lib.mkForce (lib.optional (v4 != null) (address v4 24));
        ipv6.addresses = lib.mkForce (lib.optional (v6 != null) (address v6 64));
      };
      defaultGateway = lib.mkIf (v4 != null) {
        address = gateway.v4;
        interface = "eth1";
      };
      defaultGateway6 = lib.mkIf (v6 != null) {
        address = gateway.v6;
        interface = "eth1";
      };
    };
  };

  pbxNode = pbx: {config, ...}: let
    inherit (config.lib.asterisk) credential secret;
    mine = rowsOn pbx;
    extensions = kind: lib.concatMap (row: map (phone: phone.extension) row.phones) (builtins.filter (row: row.secrets == kind) mine);
    passwords = kind: lib.listToAttrs (map (extension: lib.nameValuePair "sip-${extension}" "pw-${extension}") (extensions kind));
    password = kind: extension:
      {
        sops-nix = secret config.sops.secrets."sip-${extension}".path;
        files = secret "/run/test-secrets/sip-${extension}";
        credentials = credential "sip-${extension}";
      }
      .${
        kind
      };
    tls = {
      certFile = "${certificates}/pbx.pem";
      keyFile = "${certificates}/pbx.key";
    };
    nat = family:
      lib.optionalAttrs (behindNat pbx) {
        externalSignalingAddress = (public pbx).${family};
        externalMediaAddress = (public pbx).${family};
        localNet = [
          {
            v4 = "${networks.office.v4}0/24";
            v6 = "${networks.office.v6}/64";
          }
          .${
            family
          }
        ];
      };
  in {
    imports =
      [
        self.nixosModules.default
        (host {
          vlan = vlans.${site pbx};
          v4 =
            if has pbx "v4"
            then (own pbx).v4
            else null;
          v6 =
            if has pbx "v6"
            then (own pbx).v6
            else null;
          gateway = gateway pbx;
        })
      ]
      ++ lib.optional (extensions "sops-nix" != []) {
        imports = [(sopsSecrets (passwords "sops-nix"))];
        sops.secrets = lib.mapAttrs (_: _: {}) (passwords "sops-nix");
      }
      ++ lib.optional (extensions "files" != []) (import ./secrets.nix {fixed = passwords "files";})
      ++ lib.optional (extensions "credentials" != []) {
        # encrypted for this host at boot, as an admin would with
        # systemd-creds, and loaded by the unit
        systemd.services.test-credentials = {
          wantedBy = ["multi-user.target"];
          before = ["asterisk.service"];
          requiredBy = ["asterisk.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          path = [config.systemd.package];
          script =
            ''
              install -d -m 0700 /var/lib/test-credentials
            ''
            + lib.concatStrings (lib.mapAttrsToList (name: value: ''
              printf %s ${value} | systemd-creds encrypt --with-key=host --name=${name} - /var/lib/test-credentials/${name}
            '') (passwords "credentials"));
        };
        systemd.services.asterisk.serviceConfig.LoadCredentialEncrypted = map (name: "${name}:/var/lib/test-credentials/${name}") (builtins.attrNames (passwords "credentials"));
      };

    networking = {
      useNetworkd = pbx.networking == "networkd";
      nftables.enable = pbx.firewall == "nftables";
      enableIPv6 = has pbx "v6";
    };

    services.asterisk = {
      enable = true;
      package = pkgs.${pbx.package};
      openFirewall = true;

      http = {
        enable = true;
        address =
          if has pbx "v6"
          then "::"
          else "0.0.0.0";
        openFirewall = true;
        tls = tls // {enable = true;};
      };

      # every transport of the pbx's families, TCP through the UDP ones'
      # listeners; the IPv6 UDP transport is bound to the pbx's address, which
      # the IPv4 one on 0.0.0.0 leaves free
      pjsip.transports =
        lib.optionalAttrs (has pbx "v4") {
          udp = nat "v4";
          tls =
            {
              protocol = "tls";
              inherit tls;
            }
            // nat "v4";
        }
        // lib.optionalAttrs (has pbx "v6") {
          udp6 = {address = (own pbx).v6;} // nat "v6";
          tls6 =
            {
              protocol = "tls";
              address = "::";
              inherit tls;
            }
            // nat "v6";
        }
        // {
          ws.protocol = "ws";
          wss.protocol = "wss";
        };

      pjsip.endpoints = lib.listToAttrs (lib.concatMap (row:
        map (phone:
          lib.nameValuePair phone.extension {
            context = "phones";
            allow = [phone.codec];
            dtmfMode = row.dtmf;
            behindNat = phonesBehindNat row;
            auth.password = password row.secrets phone.extension;
          })
        row.phones)
      mine);

      musicOnHold.classes.default.directory = holdMusic;

      dialplan.contexts.phones.extensions."_1XXX" = [
        "Dial(PJSIP/\${EXTEN},20)"
        "Hangup()"
      ];
    };
  };

  # the machines phones run on: of one family each, on the internet or behind
  # the home router
  phoneMachines = {
    phones4 = {
      vlan = vlans.internet;
      inherit (on "internet" 200) v4;
      gateway = on "internet" 1;
    };
    phones6 = {
      vlan = vlans.internet;
      inherit (on "internet" 200) v6;
      gateway = on "internet" 1;
    };
    home4 = {
      vlan = vlans.home;
      inherit (on "home" 50) v4;
      gateway = on "home" 1;
    };
    home6 = {
      vlan = vlans.home;
      inherit (on "home" 50) v6;
      gateway = on "home" 1;
    };
  };
  phoneNode = machine: {
    imports = [
      (host machine)
      (import ./phone.nix {pkgs = harnessPkgs;})
      (import ./baresip.nix {pkgs = harnessPkgs;})
    ];
  };

  # a router between the internet on wan and `network` on lan
  router = {
    lan,
    wan,
    network,
  }: {
    imports = [./common.nix];
    virtualisation.interfaces = {
      wan.vlan = vlans.internet;
      lan.vlan = vlans.${network};
    };
    virtualisation.qemu.networkingOptions = lib.mkForce [];
    networking = {
      useDHCP = false;
      interfaces = {
        wan.ipv4.addresses = lib.mkForce (map (a: address a 24) wan.v4);
        wan.ipv6.addresses = lib.mkForce (map (a: address a 64) wan.v6);
        lan.ipv4.addresses = lib.mkForce [(address lan.v4 24)];
        lan.ipv6.addresses = lib.mkForce [(address lan.v6 64)];
      };
      nat = {
        enable = true;
        enableIPv6 = true;
      };
    };
  };

  # iptables and ip6tables rules of the office router for a pbx behind it:
  # its SIP ports, TCP and TLS, WebSocket and RTP from its public address,
  # and what it sends from there
  forward = pbx:
    lib.concatMapStrings (family: let
      command =
        if family == "v4"
        then "iptables"
        else "ip6tables";
      inside = (own pbx).${family};
      outside = (public pbx).${family};
    in ''
      ${command} -w -t nat -A nixos-nat-pre -i wan -d ${outside} -p udp -m multiport --dports 5060,10000:20001 -j DNAT --to-destination ${inside}
      ${command} -w -t nat -A nixos-nat-pre -i wan -d ${outside} -p tcp -m multiport --dports 5060,5061,8088,8089 -j DNAT --to-destination ${inside}
      ${command} -w -t nat -A nixos-nat-post -o wan -s ${inside} -j SNAT --to-source ${outside}
    '') (families pbx);

  plan = {
    pbxs =
      map (pbx: {
        inherit (pbx) name behind-nat;
        families = families pbx;
        address = own pbx;
        # the IPv4 address Asterisk takes for its host's: the default route's,
        # or where there is none what the hosts file gives the host name
        hostAddress =
          if has pbx "v4"
          then (own pbx).v4
          else "127.0.0.2";
      })
      pbxs;
    rows =
      map (row: {
        inherit (row) id pbx transport nat codecs dtmf secrets known websocket phones private;
      })
      rows;
  };
in
  pkgs.testers.runNixOSTest {
    name = "asterisk-${test.name}";

    nodes =
      lib.listToAttrs (map (pbx: lib.nameValuePair pbx.name (pbxNode pbx)) pbxs)
      // lib.genAttrs (lib.unique (lib.concatMap (row: map (phone: phone.machine) row.phones) rows)) (name: phoneNode phoneMachines.${name})
      // lib.optionalAttrs (natted != []) {
        officerouter = {
          imports = [
            (router {
              network = "office";
              lan = on "office" 1;
              wan = {
                v4 = [(on "internet" 2).v4] ++ map (pbx: (public pbx).v4) (builtins.filter (pbx: has pbx "v4") natted);
                v6 = [(on "internet" 2).v6] ++ map (pbx: (public pbx).v6) (builtins.filter (pbx: has pbx "v6") natted);
              };
            })
          ];
          networking.nat.extraCommands = lib.concatMapStrings forward natted;
        };
      }
      // lib.optionalAttrs (builtins.any phonesBehindNat rows) {
        homerouter = {
          imports = [
            (router {
              network = "home";
              lan = on "home" 1;
              wan = lib.mapAttrs (_: address: [address]) (on "internet" 3);
            })
          ];
          networking.nat = {
            internalInterfaces = ["lan"];
            externalInterface = "wan";
          };
        };
      };

    extraPythonPackages = p: [p.numpy];

    testScript =
      builtins.readFile ./phone.py
      + builtins.readFile ./tones.py
      + ''
        PLAN = json.loads(${builtins.toJSON (builtins.toJSON plan)})
        CERTIFICATES = "${certificates}"
        KEYPAD = "${keypad}/keys.wav"
        KEYS, DISTINCT = "${keys}", "${distinct}"
        HOLD_TONE = ${toString holdTone}
      ''
      + builtins.readFile ./matrix.py;
  }
