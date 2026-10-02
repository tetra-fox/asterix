# Provisioning devices

Supported phones fetch their SIP server, account and password from the PBX
over HTTP. Point each one at the PBX once, with DHCP option 66 or its web
interface, and the config it downloads keeps it there.

## Supported devices

| Vendor      | Device | Hardware | Option                         | Tested on real hardware |
| ----------- | ------ | -------- | ------------------------------ | ----------------------- |
| Grandstream | HT801  | V1, V2   | `pbx.phones.grandstream.ht801` | not yet                 |

## Setup

Import `asterix.nixosModules.pbx`, which includes the core. The rest of the
pbx layer stays off unless you set `pbx.enable`.

```nix
pbx.phones = {
  listenAddress = "10.0.20.10"; # the PBX's address on the phones' network
  allowedNetworks = [ "10.0.20.0/24" ];
  openFirewall = true;
  firewallInterfaces = [ "voip" ];

  grandstream.ht801 = {
    enable = true;
    devices."101".mac = "c0:74:ad:00:01:01"; # registers as endpoint 101
  };
};
```

- Files go over plain HTTP, since a phone can't use HTTPS before it's
  provisioned. Keep the phones' network to phones.
- Only `allowedNetworks` can connect, but anything there can fetch every
  file, passwords included, by guessing MACs. With a static DHCP lease, set
  the device's `allowedAddress` to lock its file to it.
- After a password changes, restart `asterisk-provisioning.service`
  (sops-nix: `restartUnits`) and reboot the device.
- `journalctl -u asterisk-provisioning` logs every request.

[`examples/household-intercom-ht801.nix`](examples/household-intercom-ht801.nix)
is a complete config.

## Unsupported devices

Write their files yourself. Or upstream them pls :3

Secrets work in the text:

```nix
pbx.phones.files."0015651234ab.cfg" = {
  text = ''
    account.1.password = ${config.lib.asterisk.secret config.sops.secrets.sip-101.path}
  '';
  allowedAddress = "10.0.20.21";
};
```

Set `escape = "xml"` on XML files so secrets get escaped.

## Grandstream HT801

Analog adapter for one phone. Each one is tied to `devices.<name>.endpoint`
(the attribute name by default) and downloads `cfg<mac>.xml`.

| P-value | Setting                | Value                                    |
| ------- | ---------------------- | ---------------------------------------- |
| P271    | account active         | yes                                      |
| P47     | SIP server             | `sipServer` (default `listenAddress`)    |
| P35     | SIP user ID            | the endpoint's name                      |
| P36     | authentication ID      | the endpoint's auth user name            |
| P34     | password               | the endpoint's password                  |
| P212    | config download        | HTTP                                     |
| P237    | config server          | `listenAddress`, plus the port if not 80 |
| P238    | firmware check         | skipped (default: Grandstream's server)  |
| P1409   | TR-069                 | off (default: Grandstream's GDMS cloud)  |
| P2      | web interface password | `adminPassword`, if set                  |
| P30     | NTP server             | `ntpServer`, if set                      |
| P64     | time zone              | `timeZone`, if set                       |

Anything else goes in `settings` or `devices.<name>.settings`. The P-values
come from Grandstream's config templates (ht80x 1.0.65.3, ht80x_v2 1.0.15.2,
`config-template.zip` at grandstream.com/support/tools).

Caveats:

- Only tested against a simulated device in a VM test. Try one adapter first.
- P1414 ("Auto Provision") is left alone, since turning it off might stop
  provisioning.
- On V2 hardware the web interface password must be 4 to 30 characters.
- A `listenAddress` of `0.0.0.0` or `::` fails evaluation until `sipServer`
  and `settings.P237` name a real address.
- IPv6 goes into P47 bare (`2001:db8::10`) and into P237 bracketed
  (`[2001:db8::10]:port`).
- Calls ring the phone, it can't auto-answer.

## Adding a device

It needs someone who owns one to test it, and:

1. a module in `modules/pbx/phones/<vendor>/` that writes into
   `pbx.phones.files`, imported from `modules/pbx/phones/default.nix`, like
   `grandstream/ht801.nix`
2. only settings the vendor documents for that device, with the source and its
   version
3. a VM test like `tests/vm/ht801.nix`, plus a check on the real device
4. a row in the table above and a section here
