# examples/minimal.nix: two phones register and call each other, with media
# relayed by Asterisk in both directions.
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

  testScript =
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
    '';
}
