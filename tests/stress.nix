# Load tests, too slow and too large for `nix flake check`; each builds on its
# own with `nix build .#stressTests.<name>`
{
  pkgs,
  self,
}: {
  vm-scale = import ./vm/scale.nix {inherit pkgs self;};
  vm-load = import ./vm/load.nix {inherit pkgs self;};
  vm-reload-cycles = import ./vm/reload-cycles.nix {inherit pkgs self;};
  vm-traffic = import ./vm/traffic.nix {inherit pkgs self;};
}
