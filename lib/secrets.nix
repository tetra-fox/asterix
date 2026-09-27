# Secret references for Asterisk configuration values.
#
# Any configuration value (typed or freeform) may be a secret reference instead
# of a literal:
#
#   { _secret = "/run/agenix/alice"; }    # a file, e.g. from agenix or sops-nix
#   { _credential = "alice-password"; }   # a systemd credential the unit loads
#
# The `_secret` attribute follows the convention of nixpkgs'
# `utils.genJqSecretsReplacement`. The generated configuration only contains a
# placeholder; the real value is substituted at service start into a tmpfs, so
# secret contents never reach the Nix store.
{ lib }:
let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    hasPrefix
    isAttrs
    isList
    isPath
    isString
    substring
    unique
    ;
in
rec {
  # Reference a secret stored in a file. The file is read by systemd
  # (LoadCredential=) as root, so root-only files from agenix or sops-nix work.
  secret =
    path:
    if isPath path || isString path then
      { _secret = toString path; }
    else
      throw "asterisk: secret expects a path string, got ${builtins.typeOf path}";

  # Reference a systemd credential by name that the service already receives,
  # for example via LoadCredentialEncrypted= or ImportCredential=.
  credential =
    name:
    if isString name then
      { _credential = name; }
    else
      throw "asterisk: credential expects a credential name string, got ${builtins.typeOf name}";

  isSecret =
    v:
    isAttrs v
    && (
      (attrNames v == [ "_secret" ] && isString v._secret)
      || (attrNames v == [ "_credential" ] && isString v._credential)
    );

  # Stable identifier for a reference: changing the path changes the id.
  secretId =
    ref:
    substring 0 32 (
      builtins.hashString "sha256" (
        if ref ? _secret then "file:${ref._secret}" else "credential:${ref._credential}"
      )
    );

  # Token written into the store copy of the configuration.
  placeholder = ref: "@NIX_ASTERISK_SECRET_${secretId ref}@";

  # Name under which the unit receives the secret in $CREDENTIALS_DIRECTORY.
  credentialName = ref: if ref ? _secret then "secret-${secretId ref}" else ref._credential;

  # Credential names must be valid systemd credential names.
  isValidCredentialName =
    name: name != "" && name != "." && name != ".." && builtins.match "[A-Za-z0-9_.-]+" name != null;

  # A secret file inside the Nix store is world-readable and therefore leaked.
  isStorePath = ref: ref ? _secret && hasPrefix builtins.storeDir ref._secret;

  # All secret references found anywhere inside a value (attrsets and lists
  # are walked recursively), without duplicates.
  collect =
    value:
    let
      go =
        v:
        if isSecret v then
          [ v ]
        else if isAttrs v then
          if v ? outPath then [ ] else concatMap go (attrValues v)
        else if isList v then
          concatMap go v
        else
          [ ];
    in
    unique (go value);

  # True if no value anywhere in `value` is a secret reference.
  isSecretFree = value: collect value == [ ];
}
