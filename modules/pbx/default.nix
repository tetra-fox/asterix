# pbx: extensions, ring groups, queues, conferences, voice menus, paging,
# business hours, routes and phone provisioning, written into the options of
# the core module (services.asterisk), which stays usable on its own. Every
# object gets a context of its own, pbx-<kind>-<name>, and phones dial from
# pbx-internal.
{
  config,
  lib,
  ...
}: let
  cfg = config.pbx;
  objects = ["extensions" "ringGroups" "queues" "conferences" "ivrs" "paging" "hours" "inbound"];
in {
  # the core by the path the flake exports it as, so importing both is fine
  imports = [
    ../.
    ./conferences.nix
    ./destinations.nix
    ./extensions.nix
    ./hours.nix
    ./ivrs.nix
    ./numbering.nix
    ./paging.nix
    ./phones
    ./queues.nix
    ./ring-groups.nix
    ./routes.nix
  ];

  options.pbx.enable = lib.mkEnableOption "the PBX layer, and with it Asterisk";

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      services.asterisk.enable = lib.mkDefault true;
    })
    {
      warnings = lib.optional (!cfg.enable && builtins.any (name: cfg.${name} != {}) objects) "pbx objects are defined, but pbx.enable is not set, so they do nothing.";
    }
  ];
}
