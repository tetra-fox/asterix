# Runs of tests/vm/upgrade.nix too long for the gate, or with a system from
# outside this flake, for vmtest.py --expr:
#
#   chain     asterisk_20, the default Asterisk, asterisk_23, the default again
#   previous  asterix at commit `rev` of the repository at `flake`, then this one
#   unstable  this asterix on the flake's nixpkgs, then on nixos-unstable
#
#   vmtest.py upgrade-previous OUT --expr '(import ./tests/campaign/upgrade.nix { flake = ./.; rev = "<commit>"; }).previous'
{
  flake,
  rev ? null,
}: let
  self = builtins.getFlake (toString flake);
  pkgs = self.inputs.nixpkgs.legacyPackages.x86_64-linux;
  upgrade = systems: import ../vm/upgrade.nix {inherit pkgs self systems;};
in {
  chain = upgrade (map (package: {
    name = package;
    inherit package;
  }) ["asterisk_20" "asterisk" "asterisk_23" "asterisk"]);

  previous = upgrade [
    {
      name = "asterix ${rev}";
      asterix = (builtins.getFlake "git+file://${toString flake}?rev=${rev}").nixosModules.default;
    }
    {name = "this asterix";}
  ];

  unstable = upgrade [
    {name = "nixos-26.05";}
    {
      name = "nixos-unstable";
      pkgs = (builtins.getFlake "github:NixOS/nixpkgs/nixos-unstable").legacyPackages.x86_64-linux;
      # the test drives the machine through this shell, whose unit changes
      # with nixpkgs; restarting it would cut the test off
      modules = [{systemd.services.backdoor.restartIfChanged = false;}];
    }
  ];
}
