# Pure helpers, independent of any NixOS configuration. Inside NixOS modules
# the same functions are available as `config.lib.asterisk`.
{ lib }:
let
  format = import ./format.nix { inherit lib; };
  secrets = import ./secrets.nix { inherit lib; };
in
{
  inherit format secrets;
  inherit (secrets) secret credential;
}
