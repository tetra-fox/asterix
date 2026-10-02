# Provisioning devices

Supported phones fetch their SIP server, account and password from the PBX
over HTTP. Point each one at the PBX once, with DHCP option 66 or its web
interface, and the config it downloads keeps it there.

## Supported devices

| Vendor      | Devices                                                         | File                                 |
| ----------- | --------------------------------------------------------------- | ------------------------------------ |
| Cisco       | 6800, 7800, 8800 and ATA 191/192 on multiplatform firmware, SPA | `<mac>.xml`                          |
| Fanvil      | X, H and i series, PA2S, PA3                                    | `<mac>.cfg`                          |
| Grandstream | HT8xx adapters, GXP, GRP, WP, GHP and GXV phones                | `cfg<mac>.xml`                       |
| Poly        | VVX, Edge E                                                     | `<mac>.cfg` and `<mac>-settings.cfg` |
| Snom        | D series                                                        | `snom<model>-<MAC>.htm`              |
| Yealink     | T3x, T4x, T5x, CP920, CP925, CP965                              | `<mac>.cfg`                          |

None has run on real hardware yet. Each file is checked against the vendor's
documentation and against FusionPBX's and Wazo's templates, and the HT801's
against a simulated device. Try one device before the rest.

## Setup

Import `asterix.nixosModules.pbx`, which includes the core. The rest of the
pbx layer stays off unless you set `pbx.enable`.

```nix
pbx.phones = {
  listenAddress = "10.0.20.10"; # the PBX's address on the phones' network
  allowedNetworks = [ "10.0.20.0/24" ];
  openFirewall = true;
  firewallInterfaces = [ "voip" ];

  devices."101" = {
    model = "grandstream-ht801";
    mac = "c0:74:ad:00:01:01"; # line 1 registers as endpoint 101
  };
};
```

- Files go over plain HTTP, since a phone can't use HTTPS before it's
  provisioned. Keep the phones' network to phones.
- Each line of a device (an adapter's port, a phone's account) registers as an
  endpoint, from the first in `lines`. `lines` defaults to the device's name,
  so `devices."101"` is line 1 as endpoint 101. `lines = [ "103" null "105" ]`
  leaves line 2 unused.
- An unused line is turned off on every provisioning, even one set up on the
  device.
- `sipServer` (default `listenAddress`) is the host alone, and `sipPort`
  (default 5060) its port.
- `pbx.phones.<vendor>.settings`, then `devices.<name>.settings`, replace what
  the module sets, in the vendor's own keys, which its section names.
- Only `allowedNetworks` can connect, but anything there can fetch every
  file, passwords included, by guessing MACs. With a static DHCP lease, set
  the device's `allowedAddress` to lock its file to it.
- A DHCP option 66 that names another server usually wins over the server a
  file sets.
- A file with `tftp = true`, such as a Cisco model's first file, is served
  over TFTP too, on UDP port 69, which `openFirewall` opens as well.
- A `listenAddress` of `0.0.0.0` or `::` fails evaluation until `sipServer`
  and the vendor's provisioning server setting name a real address.
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

Set `escape = "xml"` on XML files so secrets get escaped, and `escape = "line"`
on `key = value` files so a secret with a line break fails instead of starting
a setting of its own. `tftp = true` serves a file over TFTP as well, to the
same addresses.

## Cisco

Phones and adapters with third-party call control firmware. Phones with
enterprise (CUCM) firmware don't work. On the adapters, line n is port n.

| `model`                                                                                    | Lines |
| ------------------------------------------------------------------------------------------ | ----- |
| `cisco-7811`, `cisco-7832`, `cisco-8832`, `cisco-spa301`, `cisco-spa502g`, `cisco-spa512g` | 1     |
| `cisco-6821`, `cisco-7821`, `cisco-ata191`, `cisco-ata192`, `cisco-spa112`, `cisco-spa122` | 2     |
| `cisco-spa303`                                                                             | 3     |
| `cisco-6841`, `cisco-6851`, `cisco-6861`, `cisco-7841`, `cisco-spa504g`, `cisco-spa514g`   | 4     |
| `cisco-6871`                                                                               | 6     |
| `cisco-spa508g`, `cisco-spa8000`                                                           | 8     |
| `cisco-8811`, `cisco-8841`, `cisco-8845`, `cisco-8851`, `cisco-8861`, `cisco-8865`         | 10    |
| `cisco-spa509g`                                                                            | 12    |
| `cisco-7861`                                                                               | 16    |

The settings are from Cisco's multiplatform admin guides (12.0(7)SR3), the
ATA 191 and 192 provisioning guide (11.3(1)), the SPA100 provisioning guide
(1.3), and the SPA300/SPA500 and SPA8000 admin guides; the lines from Cisco's
data sheets.

Point DHCP option 66 at the PBX's address. A factory device then fetches its
model's file over TFTP: `8841-3PCC.xml` for an 8841, `spa112.cfg` for an
SPA112, `spa502G.cfg` for an SPA502G. That file holds only
`http://<listenAddress>/$MA.xml` (`$MA` is the MAC) in `Profile_Rule` and
`Profile_Rule_B`, so the device fetches its own file right after, and keeps
coming back to it. The ATA 191 and 192 fetch theirs over HTTPS out of the box,
so give them that URL as their Profile Rule (Voice > Provisioning) or in DHCP
option 160 instead.

| Element                | Value                                                     |
| ---------------------- | --------------------------------------------------------- |
| `Profile_Rule`         | `http://<listenAddress>/$MA.xml`, plus the port if not 80 |
| `Profile_Rule_B`       | empty, after the model's first file set it                |
| `Webex_Onboard_Enable` | `No` (default `Yes`), on multiplatform phones             |
| admin password         | `adminPassword`, if set, in the element below             |
| NTP server             | `ntpServer`, if set, in the element below                 |

| Devices                          | Admin password                                  | NTP server                                                                 |
| -------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------------- |
| multiplatform phones             | `Admin_Password`                                | `Primary_NTP_Server`                                                       |
| ATA 191, ATA 192, SPA112, SPA122 | `router-configuration/Web_Login_Admin_Password` | `router-configuration/Time_Setup/Time_Server`, `Time_Server_Mode` `manual` |
| SPA phones, SPA8000              | `Admin_Passwd`                                  | `Primary_NTP_Server`                                                       |

Line n gets `Line_Enable_n_` (`Yes`, `No` if unused), `Proxy_n_` (`sipServer`,
with `sipPort` if not 5060), `User_ID_n_` (the endpoint's name), `Auth_ID_n_`
(its auth user name) and `Password_n_`, plus `Use_Auth_ID_n_` `Yes` on all but
the multiplatform phones.

Keys of `settings` are the element names of the device's `/admin/config.xml`,
or a path into a section, such as `router-configuration/Time_Setup/Time_Zone`.

- The admin password must be 8 to 127 characters from `!` to `~` of three
  kinds (capitals, small letters, digits, others) on multiplatform phones, at
  least 8 characters on the ATA 191 and 192, and at most 32 on the SPA112 and
  SPA122.
- A multiplatform phone or ATA 191/192 that gets no provisioning server from
  DHCP asks Cisco's activation servers, until it's provisioned and again after
  a factory reset. No setting turns that off.
- The names of the 8832's, 8845's and 8865's first files follow Cisco's
  pattern, `<model>-3PCC.xml`, which no Cisco guide lists for them.
- The devices trim spaces at either end of every value.

## Fanvil

Desk, hotel and door phones and paging gateways on firmware 2.4 to 2.14, in
Fanvil's sysConf format. P, G and W variants take the model they extend.

| `model`                                                                                                                                                                                                                                                                                                                                                                                                      | Lines |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----- |
| `fanvil-x1s` (X1SP), `fanvil-x1sg`, `fanvil-x3s-lite` (X3SP Lite), `fanvil-x3sg-lite`, `fanvil-x301`, `fanvil-x305`, `fanvil-x306`, `fanvil-h1`, `fanvil-h2u`, `fanvil-h3w`, `fanvil-h4`, `fanvil-h5w`, `fanvil-h601`, `fanvil-h602`, `fanvil-h603w`, `fanvil-h6w`, `fanvil-i10s` (i10SV, i10SD), `fanvil-i16s` (i16SV), `fanvil-i61`, `fanvil-i62`, `fanvil-i63`, `fanvil-i64`, `fanvil-pa2s`, `fanvil-pa3` | 2     |
| `fanvil-x3s-pro` (X3SP Pro), `fanvil-x3sg`, `fanvil-x3sw`, `fanvil-x303`                                                                                                                                                                                                                                                                                                                                     | 4     |
| `fanvil-x3u`, `fanvil-x3u-pro`                                                                                                                                                                                                                                                                                                                                                                               | 6     |
| `fanvil-x4u`                                                                                                                                                                                                                                                                                                                                                                                                 | 12    |
| `fanvil-x5u`, `fanvil-x5u-r`                                                                                                                                                                                                                                                                                                                                                                                 | 16    |
| `fanvil-x6u`, `fanvil-x7`, `fanvil-x7c`, `fanvil-x210`                                                                                                                                                                                                                                                                                                                                                       | 20    |

Fanvil's public guides don't list the sysConf keys, so they are from the key
maps and help texts inside the firmware images, and FusionPBX and Wazo set the
same. The lines are from the firmware and the datasheets.

| Key                                       | Value                                                     |
| ----------------------------------------- | --------------------------------------------------------- |
| `ap.FlashServerIP`                        | `http://<listenAddress>`, plus the port if not 80         |
| `ap.FlashFileName`                        | `$mac.cfg`                                                |
| `ap.FlashProtocol`, `ap.FlashMode`        | HTTP (`4`), after every reboot (`1`)                      |
| `ota.FDPSEnable`                          | `0`: Fanvil's redirection service off                     |
| `web.account.1.Name`, `Password`, `Level` | `admin`, `adminPassword` and administrator (`10`), if set |
| `phone.date.EnableSNTP`, `SNTPServer`     | `1` and `ntpServer`, if set                               |

Line n gets `sip.line.n.EnableReg` (`1`, `0` if unused), `PhoneNumber` (the
endpoint's name), `RegisterUser` (its auth user name), `RegisterPswd`,
`RegisterAddr` (`sipServer`) and `RegisterPort` (`sipPort`).

A key of `settings` is the path below `<sysConf>`, a number after an element
being its index: `sip.line.1.DisplayName` is `<sip><line index="1"><DisplayName>`.
The web interface exports the whole configuration (System > Configurations),
the time zone (`phone.date.TimeZone` and others) included.

- A new device asks Fanvil's redirection service before DHCP, and turns it off
  only after its first file from here.
- A device skips a file that is the same as the one it applied last, so a
  change in its web interface stays until the file changes.
- The web interface password must be 1 to 39 letters and digits.
- The X3S and X3SP (neither Lite nor Pro), X4, X4G, X1, X1P, X2P, X2C, H3, H5,
  i12, i16V, i18S, i20S, i32V, i33V and PA2 take another format and aren't
  supported.

## Grandstream HT8xx

Analog adapters, whose lines are their phone ports. Each adapter downloads
`cfg<mac>.xml`.

| `model`             | Lines | Templates                         |
| ------------------- | ----- | --------------------------------- |
| `grandstream-ht801` | 1     | ht80x 1.0.65.3, ht80x_v2 1.0.15.3 |
| `grandstream-ht802` | 2     | ht80x 1.0.65.3, ht80x_v2 1.0.15.3 |
| `grandstream-ht812` | 2     | ht81x 1.0.65.3, ht81x_v2 1.0.15.3 |
| `grandstream-ht813` | 1     | ht813 1.0.19.6                    |
| `grandstream-ht814` | 4     | ht81x 1.0.65.3, ht81x_v2 1.0.15.3 |
| `grandstream-ht818` | 8     | ht818 1.0.65.1, ht81x_v2 1.0.15.3 |

The templates are Grandstream's (`config-template.zip` at
grandstream.com/support/tools), `_v2` for V2 hardware. Every P-value below is
in all of a model's templates, so V1 and V2 get the same file.

Every adapter gets:

| P-value | Setting                | Value                                    |
| ------- | ---------------------- | ---------------------------------------- |
| P212    | config download        | HTTP                                     |
| P237    | config server          | `listenAddress`, plus the port if not 80 |
| P238    | firmware check         | skipped (default: Grandstream's server)  |
| P1409   | TR-069                 | off (default: Grandstream's GDMS cloud)  |
| P2      | web interface password | `adminPassword`, if set                  |
| P30     | NTP server             | `ntpServer`, if set                      |
| P64     | time zone              | `grandstream.timeZone`, if set           |

On the HT801, HT802 and HT813 each port has a SIP account of its own:

| Port 1 | Port 2 | Setting           | Value                                   |
| ------ | ------ | ----------------- | --------------------------------------- |
| P271   | P401   | account active    | yes, no for an unused port              |
| P47    | P747   | SIP server        | `sipServer`, with `sipPort` if not 5060 |
| P35    | P735   | SIP user ID       | the endpoint's name                     |
| P36    | P736   | authentication ID | the endpoint's auth user name           |
| P34    | P734   | password          | the endpoint's password                 |

The HT812, HT814 and HT818 register every port with profile 1, which is turned
on (P271) and gets the SIP server (P47). Port n gets:

| P-value   | Setting           | Value                         |
| --------- | ----------------- | ----------------------------- |
| P4594 + n | port enabled      | yes, no for an unused port    |
| P4059 + n | SIP user ID       | the endpoint's name           |
| P4089 + n | authentication ID | the endpoint's auth user name |
| P4119 + n | password          | the endpoint's password       |
| P4149 + n | profile           | profile 1                     |

`settings` take P-values.

- The HT813's FXO port, for a phone company line, and profile 2 of the HT812,
  HT814 and HT818 are left alone.
- P1414 ("Auto Provision") is left alone, since turning it off might stop
  provisioning.
- The web interface password must be 4 to 30 characters on V2 hardware, and
  V1 hardware only takes ASCII 33 (`!`) to 126 (`~`), so no spaces.
- IPv6 goes into P47 bare (`2001:db8::10`) and into P237 bracketed
  (`[2001:db8::10]:port`).
- Calls ring the phone, it can't auto-answer.

## Grandstream phones

Desk, Wi-Fi, hotel and video phones, whose lines are their SIP accounts. Each
downloads `cfg<mac>.xml`. W (Wi-Fi), P (PoE) and G variants take the model
they extend, except the GRP2613W, which has more accounts than the GRP2613.

| `model`                                                                                                                                                                                                                                                                                                                                                        | Lines |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `grandstream-gxp1610`, `grandstream-gxp1615`                                                                                                                                                                                                                                                                                                                   | 1     |
| `grandstream-gxp1620`, `grandstream-gxp1625`, `grandstream-gxp1628`, `grandstream-grp2601`, `grandstream-grp2610`, `grandstream-wp810`, `grandstream-wp816`, `grandstream-wp820`, `grandstream-wp822`, `grandstream-wp825`, `grandstream-ghp610`, `grandstream-ghp611`, `grandstream-ghp620`, `grandstream-ghp621`, `grandstream-ghp630`, `grandstream-ghp631` | 2     |
| `grandstream-gxp1630`, `grandstream-gxp1760`, `grandstream-gxp2130`, `grandstream-grp2611g`, `grandstream-wp826`, `grandstream-wp836`                                                                                                                                                                                                                          | 3     |
| `grandstream-gxp1780`, `grandstream-gxp1782`, `grandstream-gxp2135`, `grandstream-gxp2140`, `grandstream-grp2602`, `grandstream-grp2612`, `grandstream-grp2613`                                                                                                                                                                                                | 4     |
| `grandstream-gxp2160`, `grandstream-gxp2170`, `grandstream-grp2603`, `grandstream-grp2604`, `grandstream-grp2613w`, `grandstream-wp856`                                                                                                                                                                                                                        | 6     |
| `grandstream-grp2614`, `grandstream-grp2624`, `grandstream-grp2634`                                                                                                                                                                                                                                                                                            | 12    |
| `grandstream-grp2615`, `grandstream-grp2616`, `grandstream-grp2636`, `grandstream-grp2650`, `grandstream-grp2670`, `grandstream-gxv3350`, `grandstream-gxv3370`, `grandstream-gxv3380`, `grandstream-gxv3450`, `grandstream-gxv3470`, `grandstream-gxv3480`                                                                                                    | 16    |

The P-values are from the same `config-template.zip` (gxp16xx 1.0.7.81,
gxp17xx 1.0.1.133, gxp2130_40_60_70_35 1.0.11.106, grp260x 1.0.7.71, grp26xx
1.0.15.19, wp810_822_825 1.0.11.83, wp8x6 1.0.3.39, wp820 1.0.7.90, wp856
1.0.3.16, ghp6xx 1.0.1.101, ghp63x 1.0.1.50, gxv33xx 1.0.3.57, gxv34x0
1.0.5.40). A model's lines are the accounts its template and its datasheet
give it, the smaller number where they differ.

Every phone gets what an adapter does, except that the GXP16xx and GXP17xx
have no TR-069 setting (P1409), and the Android phones (WP820, WP856, GXV33xx,
GXV34xx) take zone names such as `Europe/Berlin` in P64, so they get theirs
only from `settings`.

Each account is turned on, off if unused, with the SIP server (`sipServer`,
with `sipPort` if not 5060), the endpoint's name as SIP user ID, its auth user
name and its password:

| Account | Active                 | SIP server             | SIP user ID            | Authentication ID      | Password               |
| ------- | ---------------------- | ---------------------- | ---------------------- | ---------------------- | ---------------------- |
| 1       | P271                   | P47                    | P35                    | P36                    | P34                    |
| 2       | P401                   | P402                   | P404                   | P405                   | P406                   |
| 3       | P501                   | P502                   | P504                   | P505                   | P506                   |
| 4       | P601                   | P602                   | P604                   | P605                   | P606                   |
| 5       | P1701                  | P1702                  | P1704                  | P1705                  | P1706                  |
| 6       | P1801                  | P1802                  | P1804                  | P1805                  | P1806                  |
| 7       | P50601                 | P50602                 | P50604                 | P50605                 | P50606                 |
| 8 to 16 | 100 higher per account | 100 higher per account | 100 higher per account | 100 higher per account | 100 higher per account |

The GRP260x has accounts 5 and 6 at P701 to P706 and P801 to P806.

- The GXP1610 and GXP1615 get the 1 line of their template, though their
  datasheet says 2.
- Older GRP2612 and GRP2613 hardware has 2 and 3 accounts.

## Poly

VVX phones on UC Software and Edge E phones on PVOS. Each downloads
`<mac>.cfg`, a master configuration file naming `<mac>-settings.cfg`, which
holds its parameters.

| `model`                                                                                                                                                                                                       | Lines |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----- |
| `poly-vvx101`                                                                                                                                                                                                 | 1     |
| `poly-vvx150`, `poly-vvx201`                                                                                                                                                                                  | 2     |
| `poly-edge-e100`                                                                                                                                                                                              | 8     |
| `poly-edge-e220`                                                                                                                                                                                              | 16    |
| `poly-edge-e300`, `poly-edge-e320`, `poly-edge-e350`                                                                                                                                                          | 32    |
| `poly-vvx250`, `poly-vvx301`, `poly-vvx311`, `poly-vvx350`, `poly-vvx401`, `poly-vvx411`, `poly-vvx450`, `poly-vvx501`, `poly-vvx601`, `poly-edge-e400`, `poly-edge-e450`, `poly-edge-e500`, `poly-edge-e550` | 34    |

The parameters are from the UC Software 6.4.0 administrator guide and the
Edge E parameter reference (PVOS 8.2.1); the lines are the most registrations
those guides list, more than the phones' line keys.

Point DHCP option 66 at `http://<listenAddress>`, with the `http://`, since
the phones default to FTP.

| Parameter                        | Value                                             |
| -------------------------------- | ------------------------------------------------- |
| `device.set`                     | `1`, so the `device.*` parameters apply           |
| `device.baseProfile`             | `Generic`, for a plain SIP server                 |
| `device.prov.serverName`         | `http://<listenAddress>`, plus the port if not 80 |
| `device.prov.serverType`         | `HTTP`                                            |
| `feature.da.enabled`             | `0`: device analytics for Poly's cloud off        |
| `feature.obitalk.enabled`        | `0`: the OBiTALK cloud off                        |
| `device.auth.localAdminPassword` | `adminPassword`, if set                           |
| `tcpIpApp.sntp.address`          | `ntpServer`, if set, over the one from DHCP       |

Each `device.*` parameter comes with its `.set` at `1`. VVX phones also get
`device.prov.ztpEnabled`, `feature.lens.enabled` and `feature.pcc.enabled` at
`0`: Poly's zero-touch provisioning, Lens and Cloud Connector off.

Registration n gets `reg.n.address` (the endpoint's name, empty if unused),
`reg.n.auth.userId` (its auth user name), `reg.n.auth.password`,
`reg.n.server.1.address` (`sipServer`) and `reg.n.server.1.port` (`sipPort`).

`settings` take parameter names. A `device.*` one needs its `.set` at `1` too.

- Changes on the phone or in its web interface win over provisioning until
  they're reset (Settings > Advanced > Administration Settings > Reset to
  Defaults).
- `device.set` stays `1`, so the phone puts the `device.*` parameters back on
  every provisioning.
- The admin password must be 1 to 32 characters of ASCII without `<` and `>`,
  and not 456, the factory default.
- Trio, CCX and the OBi Edition VVX phones aren't supported.

## Snom

Desk phones on firmware 10.1. Each downloads `snom<model>-<MAC>.htm`, with the
MAC in uppercase, after asking for `snom<model>.htm`, which gets a 404.

| `model`                                                                                   | Lines |
| ----------------------------------------------------------------------------------------- | ----- |
| `snom-d120`, `snom-d140`, `snom-d150`                                                     | 2     |
| `snom-d315`                                                                               | 4     |
| `snom-d713`, `snom-d717`                                                                  | 6     |
| `snom-d862`                                                                               | 8     |
| `snom-d335`, `snom-d385`, `snom-d735`, `snom-d785`, `snom-d812`, `snom-d815`, `snom-d865` | 12    |

The settings are from Snom's settings reference at service.snom.com, the lines
from Snom's datasheets.

| Setting                                            | Value                                                  |
| -------------------------------------------------- | ------------------------------------------------------ |
| `setting_server`                                   | `http://<listenAddress>[:port]/snom<model>-{mac}.htm`  |
| `update_policy`                                    | `settings_only`: never firmware                        |
| `tr369_enable[1]`                                  | `false`: Snom's device management off, not on the D120 |
| `http_user`, `http_pass`                           | `admin` and `adminPassword`, if set                    |
| `webserver_admin_name`, `webserver_admin_password` | the same on the D862 and D865                          |
| `ntp_server`                                       | `ntpServer`, if set                                    |
| `timezone`                                         | `snom.timeZone`, if set, such as `GER+1`               |

Line n gets `user_active[n]` (`on`, `off` if unused), `user_host[n]`
(`sipServer`, with `sipPort` if not 5060), `user_name[n]` (the endpoint's
name), `user_pname[n]` (its auth user name) and `user_pass[n]`.

A key of `settings` is a setting's name, such as `language`, or
`name[index]`: `"user_realname[1]" = "Reception"` becomes
`<user_realname idx="1">`. What the module sets is read-only on the phone,
`setting_server` and `settings` writable.

- A new phone asks Snom's redirection service before DHCP, and goes to
  `setting_server` once it has its file.
- A setting removed from the config keeps its last value on the phone.
- The D862 and D865 show a welcome screen until `language` is set.
- The C520, C620 and the M series DECT bases take another format and aren't
  supported.

## Yealink

Desk and conference phones on firmware V84 or later. Each downloads
`<mac>.cfg`, after asking for its model's common file, which gets a 404.

| `model`                                                                                                                        | Lines |
| ------------------------------------------------------------------------------------------------------------------------------ | ----- |
| `yealink-t30`, `yealink-t30p`, `yealink-cp920`, `yealink-cp925`, `yealink-cp965`                                               | 1     |
| `yealink-t31`, `yealink-t31g`, `yealink-t31p`, `yealink-t31w`                                                                  | 2     |
| `yealink-t33g`, `yealink-t33p`, `yealink-t34w`                                                                                 | 4     |
| `yealink-t41s`                                                                                                                 | 6     |
| `yealink-t42s`, `yealink-t42u`, `yealink-t43u`, `yealink-t44u`, `yealink-t44w`, `yealink-t53`, `yealink-t53w`                  | 12    |
| `yealink-t46s`, `yealink-t46u`, `yealink-t48s`, `yealink-t48u`, `yealink-t54w`, `yealink-t57w`, `yealink-t58a`, `yealink-t58w` | 16    |

The keys are from Yealink's SIP-T2/T3/T4/T5/CP920 administrator guide (V86.60)
and its VP59/T58/CP96X guide (V86.11). The T31W and T34W are in neither, so
they get the keys FusionPBX and Wazo set for them.

| Key                                | Value                                                                |
| ---------------------------------- | -------------------------------------------------------------------- |
| `static.auto_provision.server.url` | `http://<listenAddress>/`, plus the port if not 80                   |
| `static.dm.enable`                 | `0`: device management off, not on the T31W, T34W, T58A, T58W, CP965 |
| `static.security.user_password`    | `admin:` and `adminPassword`, if set                                 |
| `local_time.ntp_server1`           | `ntpServer`, if set                                                  |

Account n gets `account.n.enable` (`1`, `0` if unused), `account.n.user_name`
(the endpoint's name), `account.n.auth_name` (its auth user name),
`account.n.password`, `account.n.sip_server.1.address` (`sipServer`) and
`account.n.sip_server.1.port` (`sipPort`).

`settings` take parameter names, such as `"local_time.time_zone" = "+1"` with
`"local_time.time_zone_name" = "Germany(Berlin)"`.

- An NTP server from DHCP wins over `ntpServer` unless
  `local_time.manual_ntp_srv_prior` is 1.
- The admin password in the file must be 1 to 32 characters from `!` to `~`
  without a colon.
- V87 firmware makes you change the default admin password on first use.
- A phone a reseller put in Yealink's RPS can be set up from the reseller's
  server after a factory reset; Yealink's RPS MAC removal tool takes it out.
- DECT base stations (W60B, W70B, W80B) aren't supported.

## Adding a device

A device nobody has tried on real hardware is fine. It needs:

1. a module `modules/pbx/phones/<vendor>.nix` that adds its models to
   `pbx.phones.models` as `<vendor>-<model>` and writes their devices' files
   into `pbx.phones.files`, imported from `modules/pbx/phones/default.nix`,
   like `yealink.nix`, or a model in an existing vendor's `models`
2. only settings the vendor documents for that device, with the source and its
   version, cross-checked against FusionPBX's and Wazo's templates
3. a test of the files it gets in `tests/pbx/phones-<vendor>.nix`, listed in
   the `pbx-phones` suite of `tests/default.nix`
4. a row in the table above and a section here
