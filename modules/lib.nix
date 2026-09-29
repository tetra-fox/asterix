# Helpers the modules share. Unlike ../lib, they are not part of the flake's
# lib or config.lib.asterisk.
{lib}: let
  format = import ../lib/format.nix {inherit lib;};

  # `200` or `200@sales` as the mailbox and its voicemail context
  splitMailbox = mailbox: let
    parts = lib.splitString "@" mailbox;
  in {
    box = builtins.head parts;
    context =
      if builtins.length parts > 1
      then builtins.elemAt parts 1
      else "default";
  };
in {
  inherit splitMailbox;

  # whether the sections of voicemail.conf in settings, which hold the typed
  # mailboxes too, have `mailbox`: `200` or `200@sales`
  hasMailbox = voicemailConf: mailbox: let
    ref = splitMailbox mailbox;
  in
    builtins.any (s: s.name == ref.context && s ? ${ref.box}) (lib.attrValues voicemailConf);

  # typed option values as section keys: scalars become defaults, so settings
  # replace them, lists stay definitions, so settings extend them, and nulls
  # are dropped
  toSection = attrs:
    lib.mapAttrs (_: v:
      if lib.isList v
      then v
      else lib.mkDefault v) (lib.filterAttrs (_: v: v != null) attrs);

  settingsOption = what:
    lib.mkOption {
      type = lib.types.attrsOf format.types.value;
      default = {};
      description = ''
        Additional keys for the generated ${what} section. They take
        precedence over single values generated from the typed options and
        extend generated lists.
      '';
    };

  # networking.firewall settings opening `ports` on `interfaces`, or on every
  # interface when the list is empty
  firewallOn = interfaces: ports:
    if interfaces == []
    then ports
    else {interfaces = lib.genAttrs interfaces (_: ports);};
}
