# examples/minimal.nix: two phones register and call each other, with media
# relayed by Asterisk in both directions, also when a phone registered over
# UDP sends its INVITE of 1300 bytes or more over TCP, as RFC 3261 18.1.1 asks.
{
  pkgs,
  self,
  sopsSecrets,
}:
pkgs.testers.runNixOSTest {
  name = "asterisk-minimal";

  nodes = {
    pbx = {
      imports = [
        self.nixosModules.default
        ../../examples/minimal.nix
        ./common.nix
        (sopsSecrets {
          sip-101 = "secret-101";
          sip-102 = "secret-102";
        })
      ];
    };

    phones = {
      imports = [
        ./common.nix
        ./phone.nix
      ];
    };
  };

  testScript = {nodes, ...}:
    builtins.readFile ./phone.py
    + ''
      start_all()
      pbx.wait_for_unit("asterisk.service")
      server = "pbx"

      alice = Phone(phones, "alice", "101", "secret-101", server, sip_port=5060, cli_port=2300)
      bob = Phone(phones, "bob", "102", "secret-102", server, sip_port=5061, cli_port=2301)
      alice.start()
      bob.start()
      alice.wait_registered()
      bob.wait_registered()

      with subtest("101 calls 102"):
          alice.call("102")
          print(wait_for_media_both_ways(pbx, [alice, bob]))
          alice.hangup()
          wait_idle(pbx)

      with subtest("102 calls 101"):
          bob.call("101")
          print(wait_for_media_both_ways(pbx, [alice, bob]))
          bob.hangup()
          wait_idle(pbx)

      with subtest("102 calls 101 from a phone that sends its INVITE with credentials over TCP"):
          # by address: pjsip moves a request to TCP only when the first address
          # it resolved is IPv4 UDP (sip_util.c), and pbx resolves to IPv6 first
          bob.stop()
          carol = Phone(phones, "carol", "102", "secret-102", "${nodes.pbx.networking.primaryIPAddress}", sip_port=5062, cli_port=2302, tcp=True)
          carol.start()
          carol.wait_registered()
          carol.call("101")
          carol.wait_count("Call [0-9]+ (state changed to CONFIRMED|is DISCONNECTED)", 1)
          # the INVITE that went over TCP and how the call ended, with their times
          lines = re.findall(r"^.*(?:Request msg INVITE/\S+ \S+ to TCP |is DISCONNECTED).*$", carol.log_text(), re.M)
          assert lines and not any("DISCONNECTED" in line for line in lines), lines
          assert carol.count("exceeds UDP size threshold") >= 1
          print(wait_for_media_both_ways(pbx, [alice, carol]))
          carol.hangup()
    '';
}
