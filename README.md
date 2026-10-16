# asterix

NixOS modules for Asterisk: a PBX made of extensions, trunks, ring groups, queues and business hours, with no dialplan to write, on top of Asterisk's config files as Nix options. Comes with a provisioning server for phones.

Intended for anything from a household intercom to a small office PBX with SIP trunks, conferences and queues.

| Docs                               | What                                        |
| ---------------------------------- | ------------------------------------------- |
| [Quick start](#quick-start)        | two phones calling each other               |
| [examples/](examples/)             | complete configs, most run in a VM test     |
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

  services.asterix = {
    enable = true;
    openFirewall = true;
    extensions = {
      "101".password = secret config.sops.secrets.sip-101.path;
      "102".password = secret config.sops.secrets.sip-102.path;
    };
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
   opens SIP and RTP on every interface. Describe the phones' network in
   `services.asterix.networks`, with its interface, address and subnets, as
   [the intercom example](examples/household-intercom.nix) does.

## Features

| Feature                          | What                                                                                                                                                                          |
| -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **A PBX without dialplan**       | extensions, trunks, voicemail, ring groups, queues, conferences, voice menus, paging, business hours, call routes and call recording, in `services.asterix`                   |
| **Asterisk as Nix options**      | under it, `services.asterisk`: PJSIP, dialplan, voicemail, conferences, queues, music on hold, call features, AMI, ARI and call records. Anything else goes in `settings`     |
| **A bad config fails the build** | Asterisk boots the new config in the build sandbox, and any error or warning fails it, as does a dialplan that uses a missing application, sound or extension (`checkConfig`) |
| **Reloads, not restarts**        | deploys reload where they can, so calls stay up                                                                                                                               |
| **Several networks**             | each gets its own transport and firewall rules, and its phones register only from its subnets. Asterisk relays the audio between them                                         |
| **NAT**                          | on either side, plus STUN and TURN                                                                                                                                            |
| **Sandboxed**                    | `systemd-analyze security` rates it 1.5                                                                                                                                       |
| **Phone provisioning**           | Cisco, Fanvil, Grandstream, Poly, Snom and Yealink devices, in `services.asterix.phones`: [PROVISIONING.md](PROVISIONING.md)                                                  |

## Secrets

Give `config.lib.asterisk.secret` the path of a file outside the Nix store.
The file can stay root-only, and any secret manager works. With
[sops-nix](https://github.com/Mic92/sops-nix):

```nix
sops.secrets.sip-101.reloadUnits = [ "asterisk.service" ]; # reload on change, no restart

services.asterix.extensions."101".password = config.lib.asterisk.secret config.sops.secrets.sip-101.path;
```

agenix has no `reloadUnits`. Reload on the encrypted file instead, which
changes when the secret does:

```nix
age.secrets.sip-101.file = ./secrets/sip-101.age;
systemd.services.asterisk.reloadTriggers = [ ./secrets/sip-101.age ];

services.asterix.extensions."101".password = config.lib.asterisk.secret config.age.secrets.sip-101.path;
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

## PBX

`services.asterix` is the PBX, in the objects its admin thinks in.
`nixosModules.default` brings it, with the core under it.

| Object                                                   | Option                           |
| -------------------------------------------------------- | -------------------------------- |
| networks the phones and trunks are on                    | `services.asterix.networks`      |
| extensions, each with its own mailbox                    | `services.asterix.extensions`    |
| other mailboxes, and voicemail limits                    | `services.asterix.voicemail`     |
| SIP trunks                                               | `services.asterix.trunks`        |
| ring groups                                              | `services.asterix.ringGroups`    |
| queues                                                   | `services.asterix.queues`        |
| conference rooms                                         | `services.asterix.conferences`   |
| voice menus                                              | `services.asterix.ivrs`          |
| announcements                                            | `services.asterix.announcements` |
| paging groups                                            | `services.asterix.paging`        |
| opening hours                                            | `services.asterix.hours`         |
| do not disturb, call forwarding and record codes         | `services.asterix.featureCodes`  |
| call parking                                             | `services.asterix.parking`       |
| calls in, by number                                      | `services.asterix.inbound`       |
| callers turned away on calls from trunks                 | `services.asterix.blocklist`     |
| calls out, by prefix                                     | `services.asterix.outbound`      |
| emergency numbers                                        | `services.asterix.emergency`     |
| how long recordings are kept, and the notice before them | `services.asterix.recordings`    |
| phones that fetch their config from the PBX              | `services.asterix.phones`        |

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

  services.asterix = {
    enable = true;
    extensions = {
      "201" = { name = "Reception"; password = secret "sip-201"; voicemail.pin = secret "vm-201"; };
      "202" = { name = "Sales"; password = secret "sip-202"; voicemail.pin = secret "vm-202"; };
    };
    trunks.provider = { host = "sip.provider.example"; username = "5551000"; password = secret "sip-trunk"; };
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
}
```

| Rule                  | What                                                                                                                                                                                                                                                                                                                           |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| networks              | without `networks`, SIP is open on every address, to anyone. With several, each extension and trunk names its `network`. Once every network with extensions lists `subnets`, requests from elsewhere are refused                                                                                                               |
| contexts              | each object gets its own, `pbx-<kind>-<name>`. phones dial from `pbx-internal`                                                                                                                                                                                                                                                 |
| overrides             | everything the PBX generates is a default on `services.asterisk`, which a definition there or `settings` overrides                                                                                                                                                                                                             |
| refused at evaluation | a number with two owners, a missing trunk, member or destination, a loop of destinations that no key press breaks                                                                                                                                                                                                              |
| emergency numbers     | no default, since they depend on where the PBX is. `outbound` requires them, or `emergency.numbers = [ ];` for a PBX that makes no emergency calls                                                                                                                                                                             |
| feature codes         | none until set, such as FreePBX's `*76` for do not disturb and `*72`/`*73` to forward every call. A phone sets them for its own extension. Forwards go to extensions, or out through `outbound`, never to an emergency number                                                                                                  |
| call parking          | off until set, such as FreePBX's `parking.number = "70";` with slots 71 to 78. A phone parks a call by transferring it to the number, and any phone takes it back by dialling its slot, which also has a busy lamp. A call left parked past `timeout` rings the phone that parked it, then goes to that extension's `noAnswer` |
| call recording        | `record` on an extension, inbound number, ring group or queue records its calls from the answer, once per call, into `/var/lib/asterisk/spool/monitor`. On other calls, a phone starts and stops one with `featureCodes.record`, such as FreePBX's `*1`. No notice and no expiry until set, since the laws differ              |

Voice menus, announcements and paging groups:

```nix
services.asterix = {
  ivrs.main = {
    number = "700";
    prompt.text = "For sales, press 1. For the front desk, press 2.";
    options = {
      "1".extension = "202";
      "2".ringGroup = "front";
    };
    noInput.announcement = "goodbye";
  };

  announcements.goodbye.prompt.text = "Nobody chose. Goodbye.";

  paging.all = { number = "650"; members = [ "201" "202" ]; };
};
```

| Object       | What                                                                                                                                                                   |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| voice menu   | plays a prompt, recorded or spoken by flite at build time, and sends each key to a destination. `{ ivr = "main"; }` works as a destination anywhere, like in `inbound` |
|              | after `attempts` prompts, a caller who pressed nothing goes to `noInput`, one who pressed an unknown key to `invalid`                                                  |
| announcement | plays a prompt `repeat` times, then sends the call to `destination`, by default a hangup                                                                               |
| paging       | calls several phones and asks them to auto-answer. Pages are one-way unless `duplex` is set, skip phones in a call, and only reach phones set to allow auto-answer     |

[small-office.nix](examples/small-office.nix) is a complete example.

## Core

`services.asterisk` writes Asterisk's config files from Nix options. The PBX
writes into it, and what the PBX has no option for goes there. A `context`
destination sends a call into dialplan of your own:

```nix
services.asterix.ivrs.main.options."9".context.context = "weasels";
services.asterisk.dialplan.contexts.weasels.extensions.s = [ "Answer()" "Playback(tt-weasels)" "Hangup()" ];
```

To run the core alone, import `asterix.nixosModules.asterisk` instead of
`nixosModules.default`. [core-only.nix](examples/core-only.nix) is the quick
start written that way.

### Custom config

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

### Dialplan

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
| build the checks against another Asterisk  | `nix build .#packageChecks.asterisk_23.roundtrip` (also `asterisk_20`, `asterisk_22`)            |
| run every non-VM check against all of them | `python3 tests/campaign/packages.py DIR`, logs in `DIR`. Add `--nixpkgs REF` for another nixpkgs |

The checks build against nixpkgs' `asterisk` otherwise.
