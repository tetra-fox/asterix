# Grandstream provisioning for the household intercom: phone files are served
# on the VoIP address only, carry the endpoints' credentials (rendered at
# runtime, XML-escaped), respect per-phone address restrictions, and the
# host serves NTP to the VoIP VLAN.
{ pkgs, self }:
let
  address = interface: address: {
    networking.interfaces.${interface}.ipv4.addresses = pkgs.lib.mkForce [
      {
        inherit address;
        prefixLength = 24;
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "asterisk-grandstream-provisioning";

  nodes = {
    pbx = {
      imports = [
        self.nixosModules.default
        self.nixosModules.grandstream-provisioning
        ../../examples/household-intercom.nix
        ../../examples/household-intercom-provisioning.nix
        ./common.nix
        (import ./secrets.nix {
          fixed = {
            sip-101 = "desk-101-pw";
            sip-102 = "desk-102-pw";
            sip-103 = "desk-103-pw";
            sip-201 = "soft-201-pw";
            sip-202 = "soft-202-pw";
            phone-admin = ''a&b<c>"d'e'';
          };
        })
        (address "lan" "10.0.10.10")
        (address "voip" "10.0.20.10")
      ];
      virtualisation.interfaces = {
        lan.vlan = 1;
        voip.vlan = 2;
      };
      # the kitchen phone has a static lease
      services.asterisk-declarative.provisioning.grandstream.phones.kitchen.allowedAddress = "10.0.20.21";
      systemd.services.grandstream-provisioning.after = [ "provision-test-secrets.service" ];
      systemd.services.grandstream-provisioning.requires = [ "provision-test-secrets.service" ];
    };

    deskphone = {
      imports = [ ./common.nix ];
      virtualisation.vlans = [ 2 ];
      # .21 is the kitchen phone's static lease; .22 is any other phone
      networking.interfaces.eth1.ipv4.addresses = pkgs.lib.mkForce [
        {
          address = "10.0.20.21";
          prefixLength = 24;
        }
        {
          address = "10.0.20.22";
          prefixLength = 24;
        }
      ];
      environment.systemPackages = [
        pkgs.curl
        pkgs.libxml2
        pkgs.chrony
      ];
    };

    softphone = {
      imports = [
        ./common.nix
        (address "eth1" "10.0.10.21")
      ];
      virtualisation.vlans = [ 1 ];
      environment.systemPackages = [ pkgs.curl ];
    };
  };

  testScript = ''
    start_all()
    pbx.wait_for_unit("grandstream-provisioning.service")
    pbx.wait_for_unit("nginx.service")
    deskphone.wait_for_unit("network-online.target")

    def fetch(name, source="10.0.20.21"):
        output = f"/tmp/{name or 'index'}"
        return deskphone.succeed(
            f"curl -s --interface {source} -o {output} -w '%{{http_code}}' http://10.0.20.10/{name}"
        ).strip()

    with subtest("a phone downloads its configuration with its credentials"):
        assert fetch("cfg000b82000101.xml") == "200"
        deskphone.succeed("xmllint --noout /tmp/cfg000b82000101.xml")
        xml = deskphone.succeed("cat /tmp/cfg000b82000101.xml")
        for expected in [
            "<mac>000b82000101</mac>",
            "<P47>10.0.20.10</P47>",
            "<P35>101</P35>",
            "<P34>desk-101-pw</P34>",
            "<P3>Kitchen</P3>",
            "<P298>1</P298>",
            "<P1409>0</P1409>",
            "<P238>2</P238>",
            "<P2>a&amp;b&lt;c&gt;&quot;d&apos;e</P2>",
        ]:
            assert expected in xml, f"{expected} missing from {xml}"

    with subtest("secrets are only in the runtime copy"):
        template = pbx.succeed("systemctl cat grandstream-provisioning.service | grep -o '/nix/store/[^ ]*-grandstream-provisioning-render' | head -1").strip()
        pbx.fail(f"nix-store -qR {template} | xargs grep -rl desk-101-pw")
        pbx.succeed("test \"$(stat -c '%U %a' /run/grandstream-provisioning/cfg000b82000101.xml)\" = 'nginx 400'")

    with subtest("files are restricted to the phone's address and unknown paths"):
        assert fetch("cfg000b82000101.xml", source="10.0.20.22") == "403"
        assert fetch("cfg000b82000103.xml", source="10.0.20.22") == "200"
        assert fetch("cfg000b82999999.xml") == "404"
        assert fetch("") == "404"

    with subtest("nothing is served on the trusted LAN address"):
        softphone.fail("curl -s --max-time 5 http://10.0.10.10/cfg000b82000103.xml")

    with subtest("the host serves time to the VoIP VLAN"):
        deskphone.wait_until_succeeds("chronyd -Q -t 20 'server 10.0.20.10 iburst' 2>&1 | grep -q 'System clock wrong by'", timeout=120)
  '';
}
