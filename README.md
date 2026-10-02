# asterix

NixOS module for [Asterisk](https://www.asterisk.org/), with a provisioning server for phones and an optional, opinionated layer for common setups such as ring groups and business hours.

Intended for anything from a household intercom to a small office PBX with SIP trunks, conferences and queues.

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
the host's address on port 5060, over UDP or TCP.
`asterisk -rx "pjsip show endpoints"` shows them.

`openFirewall` opens SIP and RTP on every interface. On a host with a public
address, limit it with `firewallInterfaces` and a SIP ACL (`pjsip.acls`), as
[the intercom example](examples/household-intercom.nix) does.

See [examples](examples/) for more.

A full list of options is in the options reference: `nix build .#docs`.

## Features

- **Asterisk as Nix options:** PJSIP phones and trunks, dialplan, voicemail,
  conferences, queues, music on hold, call features, AMI, ARI and call
  records. Anything else goes in `settings`.
- **A bad config fails the build.** Asterisk boots the new config in the build
  sandbox, and any error or warning fails it, as does a dialplan that uses a
  missing application, sound or extension. See `checkConfig`.
- **Deploys reload instead of restart** where they can, so calls stay up.
- **Several networks:** give each its own transport and pin phones to it.
  Asterisk relays the audio between them.
- **NAT** on either side, plus STUN and TURN.
- **Sandboxed:** `systemd-analyze security` rates it 1.5.
- **Phone provisioning** through the pbx layer, see
  [PROVISIONING.md](PROVISIONING.md).

## Secrets

Give `config.lib.asterisk.secret` the path of a file outside the Nix store.
The file can stay root-only, and any secret manager works. With
[sops-nix](https://github.com/Mic92/sops-nix):

```nix
sops.secrets.sip-101.reloadUnits = [ "asterisk.service" ]; # reload on change, no restart

services.asterisk.pjsip.endpoints."101".auth.password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
```

Plain strings work too, but they land in the world-readable Nix store, and the
module warns about them.

- A secret can be part of a longer value, like `"${secret path},Front desk"`,
  but Asterisk splits that at commas, so it won't start if the secret has
  one.
- Keep secrets out of dialplan arguments. Asterisk logs those everywhere
  (verbose output, `core show channels`, CDR, CEL, AMI). To check a PIN, use
  `Authenticate(/run/credentials/asterisk.service/<name>)` with
  `services.asterisk.credentials.<name>` and `app_authenticate.so` loaded.
- At runtime, secrets are readable by root, the `asterisk` user and group,
  programs the dialplan starts, AMI users with the write classes listed in
  `services.asterisk.ami.users.<name>.write`, and ARI users (voicemail PINs
  during a call, every PJSIP password if `res_ari_asterisk.so` is loaded).
- Secret files and `services.asterisk.credentials` entries share systemd's
  cap of 256 credentials per service. Past that, the build fails.
- Core dumps are off since they'd hold every secret. To debug a crash, set
  `systemd.services.asterisk.serviceConfig.LimitCORE = "infinity";`.

## Custom config

Any Asterisk config file can be written in `settings`, one attribute per
section:

```nix
services.asterisk.settings."followme.conf"."101".number = [ "5551234,30" ];
```

The same works on what the options generate, by section id:

| File            | Section ids                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| pjsip.conf      | `endpoint:<name>`, `auth:<name>`, `aor:<name>`, `identify:<name>`, `registration:<name>`, `transport:<name>`, `tcp-transport:<name>`, `acl:<name>` |
| confbridge.conf | `bridge:<name>`, `user:<name>`, `menu:<name>`                                                                                                      |
| extensions.conf | the context name                                                                                                                                   |

```nix
services.asterisk.settings."pjsip.conf"."endpoint:101".direct_media = true;
```

For raw text there's `extraConfig."<file>"`.

## Dialplan

Asterisk's `${VAR}` looks like Nix interpolation, so escape it. Each of these
produces `Dial(PJSIP/${EXTEN},30)`:

```nix
"Dial(PJSIP/\${EXTEN},30)"
''Dial(PJSIP/''${EXTEN},30)''
"Dial(PJSIP/${var "EXTEN"},30)"   # var = config.lib.asterisk.dialplan.var
```

Semicolons don't need escaping.

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
          "800" = [ "Answer()" (dp.app "ConfBridge" [ "800" ]) ];
        };
      };
      outbound.extensions."_9X." = [ "Dial(\${TRUNK}/\${EXTEN:1})" ];
    };
  };

  sops.secrets.vm-101.reloadUnits = [ "asterisk.service" ];
  services.asterisk.voicemail.mailboxes."101".pin = config.lib.asterisk.secret config.sops.secrets.vm-101.path;
}
```

renders as:

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

`var` and `app` are in `config.lib.asterisk.dialplan`, or `asterix.lib`
outside NixOS.

## PBX layer

`nixosModules.pbx` adds `pbx.*`: extensions with voicemail, ring groups,
queues, conference rooms, voice menus, paging, opening hours and trunk routes,
the way a PBX admin thinks of them. It includes the core, so use it in place
of `asterix.nixosModules.default` in the quick start's flake.nix:

```nix
# pbx.nix: extensions 201 and 202, and calls to and from a provider
{ config, lib, ... }:
let
  secret = name: config.lib.asterisk.secret config.sops.secrets.${name}.path;
in
{
  sops.defaultSopsFile = ./secrets.yaml;
  sops.secrets = lib.genAttrs [ "sip-201" "sip-202" "vm-201" "vm-202" "sip-trunk" ] (_: {
    reloadUnits = [ "asterisk.service" ];
  });

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
    # 911 with and without the 9, out through the same trunk
    emergency.numbers = [ "911" ];
  };

  # trunks, transports and everything else stay core options
  services.asterisk.pjsip = {
    transports.udp = { };
    trunks.provider = { host = "sip.provider.example"; username = "5551000"; password = secret "sip-trunk"; };
  };
}
```

Each object becomes its own context, `pbx-<kind>-<name>`, and phones dial from
`pbx-internal`. Everything the layer generates is a default on the core
options, so those or `settings` can override it.

Evaluation fails on a number with two owners, a missing trunk, member or
destination, or a loop of destinations that no key press breaks.

A voice menu plays a prompt, recorded or spoken by flite at build time, and
sends each key to a destination. A paging group calls several phones and asks
them to auto-answer:

```nix
pbx = {
  ivrs.main = {
    number = "700";
    prompt.text = "For sales, press 1. For the front desk, press 2.";
    options = {
      "1".extension = "202";
      "2".ringGroup = "front";
    };
    noInput.voicemail = "201";
  };

  paging.all = { number = "650"; members = [ "201" "202" ]; };
};
```

`{ ivr = "main"; }` works as a destination anywhere, like in `inbound`. After
`attempts` prompts, a caller who pressed nothing goes to `noInput`, one who
pressed an unknown key to `invalid`. Pages are one-way unless `duplex` is set,
skip phones in a call, and only work on phones set to allow auto-answer.

Emergency numbers have no default, since they depend on where the PBX is.
`outbound` requires them, or `emergency.numbers = [ ];` for a PBX that makes
no emergency calls. See `pbx.emergency`, and
[small-office.nix](examples/small-office.nix) for a complete example.

## Development

```sh
nix flake check   # every check, VM tests included
nix fmt
nix develop       # Rust toolchain for the provisioning server

# the same checks, evaluated in parallel
nix run nixpkgs#nix-fast-build -- --flake .#checks.x86_64-linux
```

The checks build against nixpkgs' `asterisk`. To try another version:
`nix build .#packageChecks.asterisk_23.probe` (also `asterisk_20`,
`asterisk_22`). `python3 tests/campaign/packages.py DIR` runs every non-VM
check against all of them, logs in `DIR`; add `--nixpkgs REF` for another
nixpkgs.

### Fuzzing

`nix build .#provisioning-server-fuzz` builds a libFuzzer target for the
provisioning server. To fuzz on 8 cores until stopped:

```sh
mkdir -p DIR/corpus
result/bin/connection -fork=8 -ignore_crashes=1 -close_fd_mask=2 \
  -dict=pkgs/provisioning-server/fuzz/connection.dict -artifact_prefix=DIR/ \
  DIR/corpus pkgs/provisioning-server/fuzz/seeds/connection
```

Crashes land in `DIR`. `result/bin/connection DIR/crash-<hash>` replays one
with the server's log.
