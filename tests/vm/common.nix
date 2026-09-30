# Settings shared by all VM test nodes: small, quick to boot under TCG.
{
  config,
  lib,
  ...
}: {
  options.capture = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Capture every frame of each vlan interface; the load tests turn it off, their RTP would fill the build directory.";
  };

  config = {
    documentation.enable = false;
    virtualisation = {
      memorySize = lib.mkDefault 1024;
      cores = lib.mkDefault 2;
      # QEMU's user network reaches the host and the internet when a driver runs
      # outside the nix sandbox; tests talk only over their vlans
      restrictNetwork = true;
      # QEMU writes every frame of each vlan interface to <interface>.pcap in the
      # node's state directory, which outlives a failed run outside the sandbox
      # and `nix build --keep-failed` inside it. The netdev ids follow the
      # numbering in nixpkgs' nixos/lib/testing/network.nix.
      qemu.options = lib.mkIf config.capture (lib.imap1 (
        i: interface: "-object filter-dump,id=capture${toString i},netdev=vlan${toString i},file=\"$TMPDIR\"/${interface.name}.pcap"
      ) (lib.attrValues config.virtualisation.allInterfaces));
    };
  };
}
