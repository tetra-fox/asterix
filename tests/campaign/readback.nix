# CORE-04 at T1 (P7): the strings of the options campaign (options.nix, with
# each option's strings tagged), read back from the Asterisk that loads
# them. readback.py packs many cases into one configuration, and the probe
# (probe.nix) runs every command that shows what the configuration defines,
# and a call that reads with functions what no command shows.
{
  pkgs,
  self,
}: let
  inherit (pkgs) lib;
  inherit (self.lib) format;
  campaign = import ./options.nix {
    inherit pkgs self;
    tagged = true;
  };
  probe = import ./probe.nix {inherit pkgs self;};

  # an argument of a CLI command, as main/cli.c parse_args reads it
  cliArg = s:
    if s == ""
    then ''""''
    else
      lib.concatMapStrings (c:
        if builtins.elem c ["\\" "\"" " " "\t"]
        then "\\${c}"
        else c) (lib.stringToCharacters s);

  # the commands that show what a configuration defines: the lists, and each
  # object that has a command of its own
  commands = c: let
    sections = file: (format.resolveInheritance (c.services.asterisk.settings.${file} or {})).sections;
    typed = file: type: map (s: s.name) (builtins.filter (s: (s.type or null) == type) (sections file));
    named = file: map (s: s.name) (builtins.filter (s: s.name != "general") (sections file));
    each = command: map (name: "${command} ${cliArg name}");
  in
    [
      "core show settings"
      "core show hints"
      "dialplan show"
      "dialplan show globals"
      "pjsip show settings"
      "manager show settings"
      "manager show users"
      "ari show status"
      "ari show users"
      "confbridge show profile bridges"
      "confbridge show profile users"
      "confbridge show menus"
      "features show"
      "http show status"
      "logger show channels"
      "moh show classes"
      "queue show"
      "rtp show settings"
      "voicemail show users"
      "voicemail show zones"
      "cdr show status"
      "cel show status"
      "acl show"
    ]
    ++ lib.concatMap (type: each "pjsip show ${type}" (typed "pjsip.conf" type)) ["endpoint" "aor" "auth" "transport" "identify" "registration"]
    ++ each "manager show user" (named "manager.conf")
    ++ each "ari show user" (typed "ari.conf" "user")
    ++ each "confbridge show profile bridge" (typed "confbridge.conf" "bridge")
    ++ each "confbridge show profile user" (typed "confbridge.conf" "user")
    ++ each "confbridge show menu" (typed "confbridge.conf" "menu")
    ++ each "acl show" (named "acl.conf");

  # what no command shows, read with VM_INFO in a call: the PIN, name and
  # addresses of each mailbox an argument holds as it is, but no e-mail
  # address where none is set, which VM_INFO reads through a null pointer
  # (apps/app_voicemail.c:13420-13422, 13696)
  reader = {config, ...}: let
    boxes = builtins.filter (box: builtins.match "[A-Za-z0-9_-]+" "${box.mailbox}${box.context}" != null) (builtins.attrValues config.services.asterisk.voicemail.mailboxes);
  in
    lib.mkIf (config.services.asterisk.enable && config.services.asterisk.voicemail.enable && boxes != []) {
      services.asterisk.dialplan.contexts.asterix-readback.extensions.s =
        lib.concatMap (box: map (field: "NoOp(\${VM_INFO(${box.mailbox}@${box.context},${field})})") (["password" "fullname" "pager"] ++ lib.optional (box.email != null) "email")) boxes
        ++ ["Hangup()"];
    };

  stub = derivation {
    name = "campaign-readback";
    inherit (pkgs.stdenv.hostPlatform) system;
    builder = "/bin/sh";
  };
  job = meta: stub // {inherit meta;};
in {
  # the cases with a string to look for, by their index in options.nix
  manifest = builtins.filter (case: case.marker != null) (lib.imap0 (index: case: {
      inherit index;
      inherit (case) id option label base marker;
    })
    campaign.cases);

  # jobs for nix-eval-jobs: the T0 outcome of the cases at `indices`, and the
  # probe of the configuration of each of `batches`
  jobs = {
    indices ? [],
    batches ? [],
  }:
    lib.listToAttrs (map (i: let
        case = builtins.elemAt campaign.cases i;
        o = campaign.outcome "light" case;
      in
        lib.nameValuePair "c${toString i}" (job {
          outcome = o;
          claims = campaign.claims case o;
        }))
      indices
      ++ lib.imap0 (k: batch: let
        combined = campaign.combined (map (builtins.elemAt campaign.cases) batch);
        c = campaign.evaluate "light" (combined // {modules = combined.modules ++ [reader];});
      in
        lib.nameValuePair "b${toString k}" (job {
          probe =
            builtins.unsafeDiscardStringContext
            (probe {
              name = "readback-${toString k}";
              config = c;
              commands = commands c;
              calls = lib.optional (c.services.asterisk.dialplan.contexts ? asterix-readback) {
                extension = "s";
                context = "asterix-readback";
              };
            })
            .drvPath;
        }))
      batches);
}
