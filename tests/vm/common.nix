# Settings shared by all VM test nodes: small, quick to boot under TCG.
{lib, ...}: {
  documentation.enable = false;
  virtualisation = {
    memorySize = lib.mkDefault 1024;
    cores = lib.mkDefault 2;
  };
}
