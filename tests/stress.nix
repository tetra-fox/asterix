# Load tests, too slow and too large for `nix flake check`; each builds on its
# own with `nix build .#stressTests.<name>`
{
  pkgs,
  self,
}: {
  vm-scale = import ./vm/scale.nix {inherit pkgs self;};
}
