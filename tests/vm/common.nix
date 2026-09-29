# Settings shared by all VM test nodes: small, quick to boot under TCG.
{lib, ...}: {
  documentation.enable = false;
  virtualisation = {
    memorySize = lib.mkDefault 1024;
    cores = lib.mkDefault 2;
    # QEMU's user network reaches the host and the internet when a driver runs
    # outside the nix sandbox; tests talk only over their vlans
    restrictNetwork = true;
  };
}
