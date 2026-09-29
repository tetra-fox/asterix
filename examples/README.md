# Examples

Starting points for your own configuration: copy one and fill in your
addresses, extensions and names. Passwords come from sops-nix, so your sops
file needs the keys each example lists.

The examples are tested as written, in NixOS VM tests (`tests/vm/`).

## minimal.nix

Two SIP phones that call each other by dialing 101 and 102.

Secrets: `sip-101`, `sip-102`.

## household-intercom.nix

An intercom on a host with several networks. Phones call each other directly,
and three or more can meet in a conference room.

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

The host does not route between the networks. Asterisk relays calls and their
audio, so phones on different networks never talk to each other directly. SIP
and RTP are only reachable from the trusted LAN and the VoIP VLAN: the firewall
is opened on those two interfaces, a SIP ACL only allows their subnets, and each
has its own transport bound to the host's address there. A phone's password
only works from its own network.

Adapt the `site` block to your network.

Secrets: `sip-101`, `sip-102`, `sip-201`, `sip-202`.

### household-intercom-ht801.nix

Provisioning for the intercom's two HT801 adapters: they fetch their
configuration from the host. Add it to your intercom configuration with the
adapters' real MAC addresses (on the label under each adapter), then point each
adapter at `http://10.0.20.10` once, with DHCP option 66 or its web interface.

Secrets: `ht801-admin`, the password of the adapters' web interface (4 to 30
characters).

## small-office.nix

A small office PBX with a SIP trunk, written with the PBX layer: import
`asterix.nixosModules.pbx` instead of `nixosModules.default`.

| Network | Addresses      | Devices                                             |
| ------- | -------------- | --------------------------------------------------- |
| lan     | 10.1.0.0/24    | desk phones and softphones                          |
| wan     | 203.0.113.0/24 | the provider's network (here: directly attached)    |

| Extension  | What                                                                        |
| ---------- | --------------------------------------------------------------------------- |
| 201-203    | phones; busy or unavailable goes to the phone's voicemail                   |
| 5551000    | the office's number: rings 201 and 202 for 15 s, then the sales mailbox 200 |
| 9 + number | outbound calls through the provider, showing 5551000                        |
| 911, 9911  | emergency calls; reception (201) is called at the same time                 |
| 600        | support queue (201, 202)                                                    |
| 800        | conference bridge                                                           |
| \*97       | voicemail menu                                                              |

The trunk, the queue's members and the conference profiles are core options,
next to `pbx`. It also shows keys without a typed option, set through the
`settings` of a typed object.

Secrets: `sip-trunk`, `sip-201` to `sip-203`, `vm-200` to `vm-203`.
