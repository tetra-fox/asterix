# asterix

NixOS module for Asterisk, with a provisioning server for phones and an optional, opinionated layer for common setups such as ring groups and business hours.

Intended for anything from a household intercom to a small office PBX with SIP trunks, conferences and queues.

| Docs                               | What                                        |
| ---------------------------------- | ------------------------------------------- |
| [Quick start](#quick-start)        | two phones calling each other               |
| [examples/](examples/)             | complete configs, each run in a VM test     |
| [PROVISIONING.md](PROVISIONING.md) | phones that fetch their config from the PBX |
| `nix build .#docs`                 | the reference of every option               |

## Quick start

1. **Add asterix to your flake.** And optionally, a secrets manager such as sops-nix or agenix.

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

1. **Write `pbx.nix`**: two phones that call each other by dialing 101 and
   102, with their passwords in `secrets.yaml`.

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

1. **Deploy, then register a phone:**

   | Setting  | Value                                      |
   | -------- | ------------------------------------------ |
   | Server   | the host's address, port 5060, UDP or TCP  |
   | User     | `101` or `102`                             |
   | Password | `sip-101` or `sip-102` from `secrets.yaml` |

   `asterisk -rx "pjsip show endpoints"` shows them.

2. **On a host with a public address, narrow the firewall.** `openFirewall`
   opens SIP and RTP on every interface. Add `firewallInterfaces` and a SIP
   ACL (`pjsip.acls`), as [the intercom example](examples/household-intercom.nix)
   does.

## Features

| Feature                          | What                                                                                                                                                                          |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Asterisk as Nix options**      | PJSIP phones and trunks, dialplan, voicemail, conferences, queues, music on hold, call features, AMI, ARI and call records. Anything else goes in `settings`                  |
| **A bad config fails the build** | Asterisk boots the new config in the build sandbox, and any error or warning fails it, as does a dialplan that uses a missing application, sound or extension (`checkConfig`) |
| **Reloads, not restarts**        | deploys reload where they can, so calls stay up                                                                                                                               |
| **Several networks**             | each gets its own transport and phones are pinned to it. Asterisk relays the audio between them                                                                               |
| **NAT**                          | on either side, plus STUN and TURN                                                                                                                                            |
| **Sandboxed**                    | `systemd-analyze security` rates it 1.5                                                                                                                                       |
| **Phone provisioning**           | Cisco, Fanvil, Grandstream, Poly, Snom and Yealink devices, through the pbx layer: [PROVISIONING.md](PROVISIONING.md)                                                         |

## Secrets

Give `config.lib.asterisk.secret` the path of a file outside the Nix store.
The file can stay root-only, and any secret manager works. With
[sops-nix](https://github.com/Mic92/sops-nix):

```nix
sops.secrets.sip-101.reloadUnits = [ "asterisk.service" ]; # reload on change, no restart

services.asterisk.pjsip.endpoints."101".auth.password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
```

| Case                                                           | What happens                                                                                                                                                                                                                                 |
| -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| a plain string instead                                         | works, but lands in the world-readable Nix store, and the module warns                                                                                                                                                                       |
| a secret in a longer value, like `"${secret path},Front desk"` | works, but Asterisk splits it at commas, so it won't start if the secret has one                                                                                                                                                             |
| a secret in a dialplan argument                                | Asterisk logs it everywhere (verbose output, `core show channels`, CDR, CEL, AMI). To check a PIN, use `Authenticate(/run/credentials/asterisk.service/<name>)` with `services.asterisk.credentials.<name>` and `app_authenticate.so` loaded |
| more than 256 secret files and credentials                     | the build fails: that's systemd's cap per service                                                                                                                                                                                            |
| a crash                                                        | core dumps are off, since they'd hold every secret. `systemd.services.asterisk.serviceConfig.LimitCORE = "infinity";` turns them on                                                                                                          |

At runtime, secrets are readable by root, the `asterisk` user and group,
programs the dialplan starts, AMI users with the write classes listed in
`services.asterisk.ami.users.<name>.write`, and ARI users (voicemail PINs
during a call, every PJSIP password if `res_ari_asterisk.so` is loaded).

## Custom config

| To                                    | Use                                                              |
| ------------------------------------- | ---------------------------------------------------------------- |
| write any Asterisk config file        | `services.asterisk.settings."<file>"`, one attribute per section |
| change a section the options generate | the same, with the section's id from the table below             |
| add raw text                          | `services.asterisk.extraConfig."<file>"`                         |

```nix
services.asterisk.settings."followme.conf"."101".number = [ "5551234,30" ];
```

| File            | Section ids                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| pjsip.conf      | `endpoint:<name>`, `auth:<name>`, `aor:<name>`, `identify:<name>`, `registration:<name>`, `transport:<name>`, `tcp-transport:<name>`, `acl:<name>` |
| confbridge.conf | `bridge:<name>`, `user:<name>`, `menu:<name>`                                                                                                      |
| extensions.conf | the context name                                                                                                                                   |

```nix
services.asterisk.settings."pjsip.conf"."endpoint:101".direct_media = true;
```

## Dialplan

Asterisk's `${VAR}` looks like Nix interpolation, so escape it. Semicolons
need no escaping. Each of these produces `Dial(PJSIP/${EXTEN},30)`:

```nix
"Dial(PJSIP/\${EXTEN},30)"
''Dial(PJSIP/''${EXTEN},30)''
"Dial(PJSIP/${var "EXTEN"},30)"   # var = config.lib.asterisk.dialplan.var
```

| Helper              | Gives                       | From                                                           |
| ------------------- | --------------------------- | -------------------------------------------------------------- |
| `var "NAME"`        | `${NAME}`                   | `config.lib.asterisk.dialplan`, or `asterix.lib` outside NixOS |
| `app "Name" [args]` | a step calling `Name(args)` | the same                                                       |

A dialplan with both:

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

## PBX layer

`nixosModules.pbx` adds `pbx.*`, the objects a PBX admin thinks in. It
includes the core, so use it in place of `asterix.nixosModules.default` in the
quick start's flake.nix.

| Object                    | Option            |
| ------------------------- | ----------------- |
| extensions with voicemail | `pbx.extensions`  |
| ring groups               | `pbx.ringGroups`  |
| queues                    | `pbx.queues`      |
| conference rooms          | `pbx.conferences` |
| voice menus               | `pbx.ivrs`        |
| paging groups             | `pbx.paging`      |
| opening hours             | `pbx.hours`       |
| calls in, by number       | `pbx.inbound`     |
| calls out, by prefix      | `pbx.outbound`    |
| emergency numbers         | `pbx.emergency`   |

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

| Rule                  | What                                                                                                                                               |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| contexts              | each object gets its own, `pbx-<kind>-<name>`. phones dial from `pbx-internal`                                                                     |
| overrides             | everything the layer generates is a default on the core options, which or `settings` override                                                      |
| refused at evaluation | a number with two owners, a missing trunk, member or destination, a loop of destinations that no key press breaks                                  |
| emergency numbers     | no default, since they depend on where the PBX is. `outbound` requires them, or `emergency.numbers = [ ];` for a PBX that makes no emergency calls |

Voice menus and paging groups:

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

| Object     | What                                                                                                                                                                   |
| ---------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| voice menu | plays a prompt, recorded or spoken by flite at build time, and sends each key to a destination. `{ ivr = "main"; }` works as a destination anywhere, like in `inbound` |
|            | after `attempts` prompts, a caller who pressed nothing goes to `noInput`, one who pressed an unknown key to `invalid`                                                  |
| paging     | calls several phones and asks them to auto-answer. Pages are one-way unless `duplex` is set, skip phones in a call, and only reach phones set to allow auto-answer     |

[small-office.nix](examples/small-office.nix) is a complete example.

## Development

```sh
nix flake check   # every check, VM tests included
nix fmt
nix develop       # Rust toolchain for the provisioning server

# the same checks, evaluated in parallel
nix run nixpkgs#nix-fast-build -- --flake .#checks.x86_64-linux
```

| To                                         | Run                                                                                              |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------ |
| build the checks against another Asterisk  | `nix build .#packageChecks.asterisk_23.probe` (also `asterisk_20`, `asterisk_22`)                |
| run every non-VM check against all of them | `python3 tests/campaign/packages.py DIR`, logs in `DIR`. Add `--nixpkgs REF` for another nixpkgs |

The checks build against nixpkgs' `asterisk` otherwise.
