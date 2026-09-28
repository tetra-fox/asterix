# Provisioning devices

asterix provides automatic provisioning of IP phones.

A supported device fetches its configuration from the PBX over HTTP: the SIP
server, and the account and password of the PJSIP endpoint it is tied to.
Point it at the PBX once, with DHCP option 66 or its web interface; the
configuration it downloads keeps it pointed there.

## Supported devices

| Vendor      | Device | Hardware | Option                                             | Tested on real hardware |
| ----------- | ------ | -------- | -------------------------------------------------- | ----------------------- |
| Grandstream | HT801  | V1, V2   | `services.asterisk.provisioning.grandstream.ht801` | not yet                 |

## Setup

```nix
services.asterisk.provisioning = {
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

- **Only the phones' network can connect.** Connections from outside
  `allowedNetworks` are dropped.
- **A device's file can be limited to that device.** With a static DHCP lease,
  set its `allowedAddress`; other addresses get 403. Without it, any device on
  the phones' network can fetch every file, SIP passwords included, by trying
  MAC addresses, which are the file names.
- **Passwords given with `secret` stay out of the Nix store**, like in the rest
  of the configuration. When one changes, restart
  `asterisk-provisioning.service` (sops-nix: `restartUnits`) and reboot the
  device to fetch the new file.
- **Files are sent over plain HTTP.** A device cannot use HTTPS before it is
  provisioned, so anyone on the phones' network can read the files in transit.
  Keep that network to phones.

`journalctl -u asterisk-provisioning` logs each request with the device's
address and the answer.

[`examples/household-intercom-ht801.nix`](examples/household-intercom-ht801.nix)
has a complete configuration to copy.

## Devices without support

Write their files yourself; they are served the same way. The text may contain
secrets:

```nix
services.asterisk.provisioning.files."0015651234ab.cfg" = {
  text = ''
    account.1.password = ${config.lib.asterisk.secret config.sops.secrets.sip-101.path}
  '';
  allowedAddress = "10.0.20.21";
};
```

For XML files, set `escape = "xml"` so secret values are escaped.

## Grandstream

### HT801

An adapter for one analog phone. Each adapter is tied to an endpoint in
`devices.<name>.endpoint` (by default the attribute name) and downloads
`cfg<mac>.xml`.

| P-value  | Setting                         | Value                                            |
| -------- | ------------------------------- | ------------------------------------------------ |
| P271     | account active                  | yes                                              |
| P47      | SIP server                      | `sipServer` (by default `listenAddress`)         |
| P35      | SIP user ID                     | the endpoint's name, which is also its aor's     |
| P36      | authentication ID               | the endpoint's auth user name                    |
| P34      | password                        | the endpoint's password                          |
| P212     | configuration download protocol | HTTP                                             |
| P237     | configuration server            | `listenAddress` (with the port, if it is not 80) |
| P238     | firmware check                  | always skipped (Grandstream's server by default) |
| P1409    | TR-069                          | off (Grandstream's GDMS cloud by default)        |
| P2       | web interface password          | `adminPassword`, if set                          |
| P30      | NTP server                      | `ntpServer`, if set                              |
| P64      | time zone                       | `timeZone`, if set                               |

More P-values go in `settings` (every device) or `devices.<name>.settings`.
These P-values are in Grandstream's configuration templates for both hardware
versions (`config-template.zip` from grandstream.com/support/tools: ht80x
1.0.65.3 and ht80x_v2 1.0.15.2).

Caveats and known issues:

- Not tested on a real HT801 yet, only against a simulated device in a VM test.
  Try one adapter first; step 2 of [VALIDATION.md](VALIDATION.md) covers it.
- P1414 is left alone. The HT80x templates only call it "Auto Provision", and
  turning it off might stop the adapter from fetching its file.
- The web interface password of V2 hardware must be 4 to 30 characters.
- A call to the analog phone rings it. It cannot be answered automatically.

## Adding a device

A device is supported once someone who owns it has tested it:

1. A module in `modules/provisioning/<vendor>/`, imported by
   `modules/provisioning/default.nix`, that writes the device's files into
   `services.asterisk.provisioning.files`, like
   `modules/provisioning/grandstream/ht801.nix`.
2. Only settings the vendor documents for that device, with the source (template
   or manual, and its version).
3. A VM test like `tests/vm/ht801.nix`, and a check on the real device.
4. A row in the table above and a section here with what the module sets and
   its caveats.
