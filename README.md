# asterix

NixOS module for [Asterisk](https://www.asterisk.org/), with a provisioning server for phones and an optional, opinionated layer for common setups such as ring groups and business hours. Intended for anything from a household intercom to a small office PBX with SIP trunks, conferences and queues.

## Quick start

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    asterix = {
      url = "github:tetra-fox/asterix";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.sops-nix.follows = "sops-nix";
    };

    # not required, agenix works, or plaintext if you're a menace
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, asterix, sops-nix, ... }: {
    nixosConfigurations.pbx = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        asterix.nixosModules.default
        sops-nix.nixosModules.sops
        ./configuration.nix
        ./pbx.nix
      ];
    };
  };
}
```

```nix
# pbx.nix: two phones that call each other by dialing 101 and 102
{ config, lib, ... }:
let
  inherit (config.lib.asterisk) secret;
in
{
  sops.defaultSopsFile = ./secrets.yaml; # with keys sip-101 and sip-102
  sops.secrets = lib.genAttrs [ "sip-101" "sip-102" ] (_: {
    reloadUnits = [ "asterisk.service" ];
  });

  services.asterisk = {
    enable = true;
    openFirewall = true;

    pjsip = {
      transports.udp = { };
      endpoints = {
        "101" = {
          context = "phones";
          auth.password = secret config.sops.secrets.sip-101.path;
        };
        "102" = {
          context = "phones";
          auth.password = secret config.sops.secrets.sip-102.path;
        };
      };
    };

    dialplan.contexts.phones.extensions."_10X" = [
      "Dial(PJSIP/\${EXTEN},30)"
      "Hangup()"
    ];
  };
}
```

Phones register as user `101`/`102` with the password from `secrets.yaml`, at
the host's address on port 5060. `asterisk -rx "pjsip show endpoints"` shows them.

`openFirewall` opens SIP and RTP on every interface. On a host with a public
address, limit it with `firewallInterfaces` and a SIP ACL (`pjsip.acls`), as
[the intercom example](examples/household-intercom.nix) does.

See [examples](examples/) for more.

A full list of options is in the options reference: `nix build .#docs`.

## What it does

- **Phones, dialplan and the rest as options.** PJSIP phones and trunks, the
  dialplan, voicemail, conferences, queues, music on hold, call features, AMI,
  ARI and call records. Anything else can be written as Nix too (see below).
- **Passwords can stay out of the Nix store.** Pass them as files, such as
  sops-nix secrets, and they are read when Asterisk starts (see the [examples](examples/)).
- **Asterisk checks the configuration before it is deployed.** Building the
  system starts Asterisk with the new configuration in the build sandbox. If
  Asterisk reports an error or a warning while loading it, or the dialplan uses
  an application or function that no loaded module provides, the build fails.
  See `checkConfig` in the options reference.
- **Reload instead of restart.** Changes are applied with a reload where
  possible, so calls stay up. Only changes like a new SIP port
  restart it, and phones stay registered across a restart.
- **`openFirewall` opens only what your configuration uses:** the SIP ports and
  the RTP range, and AMI or HTTP only if you ask for them.
- **Several networks.** Give each network its own SIP transport and pin phones
  to it. Asterisk relays the audio, so phones on different networks never talk
  to each other directly.
- **NAT.** Options for a PBX behind NAT and for phones behind NAT, plus STUN
  and TURN.
- **Sandboxed.** Asterisk runs as its own user, without extra privileges.
- **Phone provisioning.** Supported devices fetch their configuration from the
  PBX. See [PROVISIONING.md](PROVISIONING.md).

## Secrets

Any value can be a secret: give `config.lib.asterisk.secret` the path of a file
outside the Nix store. With [sops-nix](https://github.com/Mic92/sops-nix):

```nix
sops.secrets.sip-101.reloadUnits = [ "asterisk.service" ];

services.asterisk.pjsip.endpoints."101".auth.password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
```

The file can stay readable by root only. With `reloadUnits`, a changed password
is applied on the next deploy without restarting Asterisk. A secret can also be
part of a longer value, as in `"${secret path},Front desk"`.

Other secret managers work the same way, since `secret` only takes a path.

A password written as a plain string works too, but it ends up in the Nix
store, which every user on the host can read. The module warns about plain
strings in password fields.

## Anything the options don't cover

Every Asterisk configuration file can be written as Nix in `settings`, one
attribute per section:

```nix
services.asterisk.settings."followme.conf"."101".number = [ "5551234,30" ];
```

`settings` also changes what the options generate. Those sections have ids:
`endpoint:<name>`, `auth:<name>`, `aor:<name>`, `identify:<name>`,
`registration:<name>`, `transport:<name>` and `acl:<name>` in pjsip.conf,
`bridge:<name>`, `user:<name>` and `menu:<name>` in confbridge.conf, and the
context name in extensions.conf.

```nix
services.asterisk.settings."pjsip.conf"."endpoint:101".direct_media = true;
```

For raw text there is `extraConfig."<file>"`.

## Dialplan

Asterisk variables look like Nix string interpolation, so they need escaping.
Each of these produces `Dial(PJSIP/${EXTEN},30)`:

```nix
"Dial(PJSIP/\${EXTEN},30)"                   # double-quoted string
''Dial(PJSIP/''${EXTEN},30)''                # indented string
"Dial(PJSIP/${var "EXTEN"},30)"              # let var = config.lib.asterisk.dialplan.var;
```

Semicolons do not need to be escaped.

```nix
{ config, ... }:
let
  dp = config.lib.asterisk.dialplan;
in
{
  services.asterisk.dialplan = {
    globals.TRUNK = "PJSIP/provider";
    contexts = {
      internal = {
        includes = [ "outbound" ];
        hints."101" = "PJSIP/101";
        extensions = {
          "101" = [
            "Dial(PJSIP/101,20)"
            { app = "VoiceMail"; args = [ "101@default" "u" ]; label = "vm"; }
            "Hangup()"
          ];
          # everyone who dials 800 joins the same conference
          "800" = [ "Answer()" (dp.app "ConfBridge" [ "800" ]) ];
        };
      };
      outbound.extensions."_9X." = [ "Dial(\${TRUNK}/\${EXTEN:1})" ];
    };
  };
}
```

renders the following:

```ini
[internal]
include => outbound
exten => 101,hint,PJSIP/101
exten => 101,1,Dial(PJSIP/101,20)
 same => n(vm),VoiceMail(101@default,u)
 same => n,Hangup()
exten => 800,1,Answer()
 same => n,ConfBridge(800)
```

The helpers `var` and `app` are in `config.lib.asterisk.dialplan`, and in
`asterix.lib` outside a NixOS configuration.

## PBX layer

`nixosModules.pbx` adds `pbx.*` on top of the options above: extensions with
voicemail, ring groups, queues, conference rooms, opening hours and routes to
and from trunks, the way a PBX admin thinks of them. It imports the core, so
it replaces `nixosModules.default` in `imports`.

```nix
{ config, ... }:
let
  secret = name: config.lib.asterisk.secret config.sops.secrets.${name}.path;
in
{
  imports = [ asterix.nixosModules.pbx ];

  pbx = {
    enable = true;
    extensions = {
      "201" = { name = "Reception"; password = secret "sip-201"; voicemail.pin = secret "vm-201"; };
      "202" = { name = "Sales"; password = secret "sip-202"; voicemail.pin = secret "vm-202"; };
    };
    ringGroups.front = { members = [ "201" "202" ]; noAnswer.voicemail = "201"; };
    hours.office = {
      timezone = "America/Los_Angeles";
      open = [ { days = "mon-fri"; time = "09:00-17:00"; } ];
      closeEarly = "*28";
    };
    inbound."5551000" = {
      trunk = "provider";
      hours = "office";
      open.ringGroup = "front";
      closed.voicemail = "201";
    };
    outbound = { prefix = "9"; trunk = "provider"; callerId = "5551000"; };
  };

  # trunks, transports and everything else stay core options
  services.asterisk.pjsip = {
    transports.udp = { };
    trunks.provider = { host = "sip.provider.example"; username = "5551000"; password = secret "sip-trunk"; };
  };
}
```

Each object becomes a context of its own, `pbx-<kind>-<name>`, with a comment
saying which option it came from, and phones dial from `pbx-internal`. The
layer only writes core options, as defaults, so anything it generates can be
changed with the core options or `settings`. Evaluation fails when a number
has two owners or a destination, trunk or member does not exist.

Emergency numbers have no defaults, since they depend on where the PBX is:
see `pbx.emergency`. [small-office.nix](examples/small-office.nix) is a
complete example.

## Development

`nix flake check` runs every check, including NixOS VM tests. `nix fmt`
formats everything, and `nix develop` has the Rust toolchain for the
provisioning server.
