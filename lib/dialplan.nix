# Helpers for writing dialplan in Nix.
#
# Escaping: Nix and Asterisk both use `${...}`. In Nix double-quoted strings
# write `"\${EXTEN}"`, in indented strings `''${EXTEN}`, or use `var "EXTEN"`.
# Semicolons need no escaping; the generator does that.
{lib}: let
  inherit
    (lib)
    concatMapStringsSep
    isString
    ;

  argString = arg:
    if isString arg
    then arg
    else toString arg;
in {
  # `var "EXTEN"` is the Asterisk variable reference `${EXTEN}`.
  var = name: "\${${name}}";

  # `app "Dial" [ "PJSIP/alice" 30 ]` is `Dial(PJSIP/alice,30)`. Arguments are
  # joined with commas and not escaped.
  app = name: args: "${name}(${concatMapStringsSep "," argString args})";
}
