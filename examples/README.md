# Examples

Copy one and fill in your addresses, extensions and names. Each runs as written
in a VM test.

| Example                                                      | What                                                        | Import                                   | Secrets                                                   | VM test                 |
| ------------------------------------------------------------ | ----------------------------------------------------------- | ---------------------------------------- | --------------------------------------------------------- | ----------------------- |
| [minimal.nix](minimal.nix)                                   | two SIP phones that call each other by dialing 101 and 102  | `nixosModules.default`                   | `sip-101`, `sip-102`                                      | `vm-minimal`            |
| [household-intercom.nix](household-intercom.nix)             | an intercom across several networks, with a conference room | `nixosModules.default`                   | `sip-101`, `sip-102`, `sip-201`, `sip-202`                | `vm-household-intercom` |
| [household-intercom-ht801.nix](household-intercom-ht801.nix) | provisioning for the intercom's two HT801 adapters          | `nixosModules.pbx`, next to the intercom | `ht801-admin`                                             | `vm-ht801`              |
| [small-office.nix](small-office.nix)                         | a small office PBX with a SIP trunk, on the pbx layer       | `nixosModules.pbx`                       | `sip-trunk`, `sip-201` to `sip-203`, `vm-200` to `vm-203` | `vm-small-office`       |

Passwords come from sops-nix. A changed secret reloads Asterisk, or restarts
the provisioning server, through sops-nix's `reloadUnits` and `restartUnits`.

- By default sops-nix leaves that to switch-to-configuration, which NixOS 26.05
  warns goes away in 26.11, so the examples need revisiting before then.
- `sops.useSystemdActivation = true` does it from a systemd unit instead. It's
  the default with systemd-sysusers or userborn, but the VM tests don't use it.

## household-intercom.nix

| Network      | Addresses    | Devices                                                    |
| ------------ | ------------ | ---------------------------------------------------------- |
| servers VLAN | 10.0.1.0/24  | the host's main network (SSH, WAN), no SIP                 |
| trusted LAN  | 10.0.10.0/24 | softphones on Wi-Fi                                        |
| VoIP VLAN    | 10.0.20.0/24 | analog phones on Grandstream HT801 adapters, no WAN access |

| Extension | What                                               |
| --------- | -------------------------------------------------- |
| 101, 102  | analog phones (HT801)                              |
| 201, 202  | softphones                                         |
| 800       | conference room                                    |
| 911       | a recording says that these phones cannot call 911 |

- The host doesn't route between the networks. Asterisk relays calls and audio
  across them.
- SIP and RTP are open only on the trusted LAN and the VoIP VLAN, each with its
  own transport, and a phone's password only works from its own network.
- To adapt it, change the `site` block.

## household-intercom-ht801.nix

1. Import it next to the intercom, with `asterix.nixosModules.pbx`.
2. Fill in the adapters' MACs, from the label underneath.
3. Point each adapter at `http://10.0.20.10` once, in DHCP option 66 or its web
   interface.

`ht801-admin` is the adapters' web interface password: 4 to 30 characters,
ASCII without spaces.

## small-office.nix

| Network | Addresses      | Devices                                          |
| ------- | -------------- | ------------------------------------------------ |
| lan     | 10.1.0.0/24    | desk phones and softphones                       |
| wan     | 203.0.113.0/24 | the provider's network (here: directly attached) |

| Extension  | What                                                                        |
| ---------- | --------------------------------------------------------------------------- |
| 201-203    | phones. Busy or unavailable goes to the phone's voicemail                   |
| 5551000    | the office's number: rings 201 and 202 for 15 s, then the sales mailbox 200 |
| 9 + number | outbound calls through the provider, showing 5551000                        |
| 911, 9911  | emergency calls. Reception (201) is called at the same time                 |
| 600        | support queue (201, 202)                                                    |
| 800        | conference bridge                                                           |
| \*97       | voicemail menu                                                              |

- The trunk, queue strategy and conference profiles are core options, next to
  `pbx`.
- A few keys that have no typed option are set through a typed object's
  `settings`.
