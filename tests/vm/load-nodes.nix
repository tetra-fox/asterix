# What the load tests in ../stress.nix share: VMs with 4 cores and no
# capture, whose RTP would fill the build directory, the pbx with gdb for
# heap_in_use() (usage.py), and the SIPp machine, which sends as phones from
# its first address and as a carrier from `carrier`.
{lib}: rec {
  carrier = "192.168.1.100";

  sizing = {
    virtualisation.cores = 4;
    capture = false;
  };

  pbx = {pkgs, ...}: {
    imports = [sizing];
    environment.systemPackages = [pkgs.gdb];
  };

  sipp = {
    imports = [
      ./common.nix
      ./sipp.nix
      sizing
    ];
    virtualisation.memorySize = 2048;
    # SIPp answers calls and takes RTP on ports it picks
    networking.firewall.enable = false;
    networking.interfaces.eth1.ipv4.addresses = lib.mkAfter [
      {
        address = carrier;
        prefixLength = 24;
      }
    ];
  };
}
