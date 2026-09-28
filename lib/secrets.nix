# Secret references for Asterisk configuration values.
#
# Any configuration value (typed or freeform) may be a secret reference instead
# of a literal:
#
#   { _secret = "/run/secrets/alice"; }   # a file, e.g. from sops-nix
#   { _credential = "alice-password"; }   # a systemd credential the unit loads
#
# The `_secret` attribute follows the convention of nixpkgs'
# `utils.genJqSecretsReplacement`. References made with `secret` and
# `credential` can also be interpolated into strings, for values that contain
# a secret next to other text: "${secret "/run/secrets/vm-200"},Sales,s@x.org".
#
# The generated configuration only contains a placeholder naming the
# reference (`@NIX_ASTERISK_SECRET:file:/run/secrets/alice@`). The module finds
# placeholders in the generated files, passes each secret to the service as a
# systemd credential and substitutes it at service start into a tmpfs, so
# secret contents never reach the Nix store.
{lib}: let
  inherit
    (lib)
    attrNames
    attrValues
    concatMap
    filter
    hasPrefix
    isAttrs
    isList
    isPath
    isString
    substring
    unique
    ;

  # Characters allowed in secret paths and credential names, so that a
  # placeholder survives rendering unchanged.
  safePath = p: builtins.match "/[A-Za-z0-9_.+/=-]*" p != null;
  safeName = n: builtins.match "[A-Za-z0-9_.-]+" n != null && n != "." && n != "..";

  withToString = ref: ref // {__toString = placeholderOf;};

  placeholderPattern = "@NIX_ASTERISK_SECRET:(file|credential):([^@]*)@";

  # Placeholder text for a reference.
  placeholderOf = ref:
    if ref ? _secret
    then "@NIX_ASTERISK_SECRET:file:${ref._secret}@"
    else "@NIX_ASTERISK_SECRET:credential:${ref._credential}@";
in {
  inherit placeholderOf placeholderPattern;

  # Reference a secret stored in a file. The file is read by systemd
  # (LoadCredential=) as root, so root-only files such as sops-nix's work.
  secret = path: let
    p = toString path;
  in
    if !(isPath path || isString path)
    then throw "asterisk: secret expects a path, got ${builtins.typeOf path}"
    else if !(safePath p)
    then throw "asterisk: secret path `${p}` must be absolute and only contain letters, digits and _.+/=-"
    else withToString {_secret = p;};

  # Reference a systemd credential by name that the service already receives,
  # for example via LoadCredentialEncrypted= or ImportCredential=.
  credential = name:
    if !(isString name)
    then throw "asterisk: credential expects a name, got ${builtins.typeOf name}"
    else if !(safeName name)
    then throw "asterisk: invalid systemd credential name `${name}`"
    else withToString {_credential = name;};

  isSecret = v:
    isAttrs v
    && (
      let
        names = filter (n: n != "__toString") (attrNames v);
      in
        (names == ["_secret"] && isString v._secret)
        || (names == ["_credential"] && isString v._credential)
    );

  # A reference without its __toString function (comparable with ==).
  normalize = ref: removeAttrs ref ["__toString"];

  # Stable identifier for a reference: changing the path changes the id.
  secretId = ref:
    substring 0 32 (
      builtins.hashString "sha256" (
        if ref ? _secret
        then "file:${ref._secret}"
        else "credential:${ref._credential}"
      )
    );

  # Name under which the unit receives the secret in $CREDENTIALS_DIRECTORY.
  credentialName = ref:
    if ref ? _secret
    then "secret-${substring 0 32 (builtins.hashString "sha256" "file:${ref._secret}")}"
    else ref._credential;

  isValidReference = ref:
    if ref ? _secret
    then safePath ref._secret
    else safeName ref._credential;

  isValidCredentialName = safeName;

  # A secret file inside the Nix store is world-readable and therefore leaked.
  isStorePath = ref: ref ? _secret && hasPrefix builtins.storeDir ref._secret;

  # All references whose placeholders occur in a text, without duplicates.
  fromText = text:
    unique (
      map (
        m:
          if builtins.elemAt m 0 == "file"
          then {_secret = builtins.elemAt m 1;}
          else {_credential = builtins.elemAt m 1;}
      ) (filter isList (builtins.split placeholderPattern text))
    );

  # All secret references found anywhere inside a value (attrsets and lists
  # are walked recursively), without duplicates.
  collect = value: let
    isRef = v:
      isAttrs v
      && (
        let
          names = filter (n: n != "__toString") (attrNames v);
        in
          names == ["_secret"] || names == ["_credential"]
      );
    go = v:
      if isRef v
      then [(removeAttrs v ["__toString"])]
      else if isAttrs v
      then
        if v ? outPath
        then []
        else concatMap go (attrValues v)
      else if isList v
      then concatMap go v
      else [];
  in
    unique (go value);
}
