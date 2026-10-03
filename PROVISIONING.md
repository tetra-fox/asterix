# Provisioning phones

The PBX writes each phone's and adapter's config, SIP accounts included, and
serves it over HTTP. You list the devices, and they fetch their file on boot.

## Quick start

1. **Import the pbx layer**: `asterix.nixosModules.pbx` instead of
   `nixosModules.default`. It includes the core.
2. **Add the provisioning server and your devices**:

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

3. **Point each device at the PBX once**, in DHCP option 66 or as the
   provisioning server in its web interface (add `:port` if it isn't 80):

   | Vendor                | DHCP                              | First boot                                                 |
   | --------------------- | --------------------------------- | ---------------------------------------------------------- |
   | Cisco                 | 66 = `10.0.20.10`                 | fetches its model's file over TFTP, then its own over HTTP |
   | Cisco ATA 191 and 192 | 160 = `http://10.0.20.10/$MA.xml` | tries HTTPS on option 66, which the PBX doesn't serve      |
   | Fanvil                | 66 = `http://10.0.20.10`          | asks Fanvil's redirection service first                    |
   | Grandstream           | 66 = `http://10.0.20.10`          |                                                            |
   | Poly                  | 66 = `http://10.0.20.10`          | needs the `http://`, since the phones default to FTP       |
   | Snom                  | 66 = `http://10.0.20.10`, no 67   | asks Snom's redirection service first                      |
   | Yealink               | 66 = `http://10.0.20.10`          |                                                            |

4. **Deploy and watch** `journalctl -u asterisk-provisioning`, which logs every
   request. A device registers once it has its file.

[`examples/household-intercom-ht801.nix`](examples/household-intercom-ht801.nix)
is a complete config.

## Options

All under `pbx.phones`.

| Option                                  | Default                 | What                                                                    |
| --------------------------------------- | ----------------------- | ----------------------------------------------------------------------- |
| `listenAddress`                         | required                | the PBX's address on the phones' network, where files are served        |
| `port`                                  | `80`                    | HTTP port                                                               |
| `allowedNetworks`                       | required                | the only networks that can connect                                      |
| `openFirewall`, `firewallInterfaces`    | off, all                | open the HTTP port, and UDP 69 when TFTP is in use                      |
| `sipServer`, `sipPort`                  | `listenAddress`, `5060` | where lines register: the host alone, and its port                      |
| `ntpServer`                             | device's own            | NTP server                                                              |
| `adminPassword`                         | device's own            | web interface password, normally a secret reference                     |
| `devices.<name>.model`                  | required                | `<vendor>-<model>`, from [Supported devices](#supported-devices)        |
| `devices.<name>.mac`                    | required                | any spelling: `c0:74:ad:00:01:01`, `C0-74-AD-00-01-01`, `c074ad000101`  |
| `devices.<name>.lines`                  | `[ <name> ]`            | the endpoint each line registers as, from line 1. `null` leaves one off |
| `devices.<name>.allowedAddress`         | anyone                  | the only address that may fetch the device's file                       |
| `devices.<name>.settings`               | `{}`                    | raw settings in the vendor's keys, over everything else                 |
| `<vendor>.settings`                     | `{}`                    | raw settings for all of a vendor's devices                              |
| `grandstream.timeZone`, `snom.timeZone` | device's own            | time zone, in the vendor's format                                       |
| `files.<name>`                          |                         | hand-written files, see [Other devices](#other-devices)                 |

## Good to know

- Files go over plain HTTP, since a phone can't use HTTPS before it's
  provisioned. Keep the phones' network to phones.
- Anything in `allowedNetworks` can fetch every file, passwords included, by
  guessing MACs. `allowedAddress` with a static DHCP lease locks a device's
  file to it.
- A line that's `null` or past the end of `lines` is turned off on every
  provisioning, even one set up on the device.
- A DHCP option 66 that names another server usually wins over the one in a
  device's file.
- A `listenAddress` of `0.0.0.0` or `::` fails evaluation until `sipServer` and
  the vendor's server setting name a real address.
- After a password changes, restart `asterisk-provisioning.service` (sops-nix:
  `restartUnits`) and reboot the device.

## Supported devices

None has run on real hardware yet: each file is checked against the vendor's
documentation and against FusionPBX's and Wazo's templates (see
[Sources](#sources)). Try one device first.

| Vendor      | Devices                                                         | File                                 | Details                                       |
| ----------- | --------------------------------------------------------------- | ------------------------------------ | --------------------------------------------- |
| Cisco       | 6800, 7800, 8800 and ATA 191/192 on multiplatform firmware, SPA | `<mac>.xml`                          | [Cisco](#cisco)                               |
| Fanvil      | X, H and i series, PA2S, PA3                                    | `<mac>.cfg`                          | [Fanvil](#fanvil)                             |
| Grandstream | HT801, HT802, HT812, HT813, HT814, HT818                        | `cfg<mac>.xml`                       | [Grandstream adapters](#grandstream-adapters) |
| Grandstream | GXP, GRP, WP, GHP and GXV phones                                | `cfg<mac>.xml`                       | [Grandstream phones](#grandstream-phones)     |
| Poly        | VVX, Edge E                                                     | `<mac>.cfg` and `<mac>-settings.cfg` | [Poly](#poly)                                 |
| Snom        | D series                                                        | `snom<model>-<MAC>.htm`              | [Snom](#snom)                                 |
| Yealink     | T3x, T4x, T5x, CP920, CP925, CP965                              | `<mac>.cfg`                          | [Yealink](#yealink)                           |

<details>
<summary>Cisco: 30 models</summary>

| `model`         | Type             | Lines |
| --------------- | ---------------- | ----- |
| `cisco-6821`    | desk phone       | 2     |
| `cisco-6841`    | desk phone       | 4     |
| `cisco-6851`    | desk phone       | 4     |
| `cisco-6861`    | desk phone       | 4     |
| `cisco-6871`    | desk phone       | 6     |
| `cisco-7811`    | desk phone       | 1     |
| `cisco-7821`    | desk phone       | 2     |
| `cisco-7832`    | conference phone | 1     |
| `cisco-7841`    | desk phone       | 4     |
| `cisco-7861`    | desk phone       | 16    |
| `cisco-8811`    | desk phone       | 10    |
| `cisco-8832`    | conference phone | 1     |
| `cisco-8841`    | desk phone       | 10    |
| `cisco-8845`    | desk phone       | 10    |
| `cisco-8851`    | desk phone       | 10    |
| `cisco-8861`    | desk phone       | 10    |
| `cisco-8865`    | desk phone       | 10    |
| `cisco-ata191`  | analog adapter   | 2     |
| `cisco-ata192`  | analog adapter   | 2     |
| `cisco-spa112`  | analog adapter   | 2     |
| `cisco-spa122`  | analog adapter   | 2     |
| `cisco-spa301`  | desk phone       | 1     |
| `cisco-spa303`  | desk phone       | 3     |
| `cisco-spa502g` | desk phone       | 1     |
| `cisco-spa504g` | desk phone       | 4     |
| `cisco-spa508g` | desk phone       | 8     |
| `cisco-spa509g` | desk phone       | 12    |
| `cisco-spa512g` | desk phone       | 1     |
| `cisco-spa514g` | desk phone       | 4     |
| `cisco-spa8000` | analog adapter   | 8     |

</details>

<details>
<summary>Fanvil: 37 models</summary>

| `model`            | Type                                  | Lines |
| ------------------ | ------------------------------------- | ----- |
| `fanvil-h1`        | hotel phone                           | 2     |
| `fanvil-h2u`       | hotel phone                           | 2     |
| `fanvil-h3w`       | hotel phone                           | 2     |
| `fanvil-h4`        | hotel phone (also H4W)                | 2     |
| `fanvil-h5w`       | hotel phone                           | 2     |
| `fanvil-h6w`       | hotel phone                           | 2     |
| `fanvil-h601`      | hotel phone (also H601W)              | 2     |
| `fanvil-h602`      | hotel phone (also H602W)              | 2     |
| `fanvil-h603w`     | hotel phone                           | 2     |
| `fanvil-i10s`      | door phone (also i10SV, i10SD)        | 2     |
| `fanvil-i16s`      | door phone (also i16SV)               | 2     |
| `fanvil-i61`       | door phone                            | 2     |
| `fanvil-i62`       | door phone                            | 2     |
| `fanvil-i63`       | door phone                            | 2     |
| `fanvil-i64`       | door phone                            | 2     |
| `fanvil-pa2s`      | paging gateway                        | 2     |
| `fanvil-pa3`       | paging gateway                        | 2     |
| `fanvil-x1s`       | desk phone (also X1SP)                | 2     |
| `fanvil-x1sg`      | desk phone                            | 2     |
| `fanvil-x3s-lite`  | desk phone (also X3SP Lite)           | 2     |
| `fanvil-x3s-pro`   | desk phone (also X3SP Pro)            | 4     |
| `fanvil-x3sg`      | desk phone                            | 4     |
| `fanvil-x3sg-lite` | desk phone                            | 2     |
| `fanvil-x3sw`      | desk phone                            | 4     |
| `fanvil-x3u`       | desk phone                            | 6     |
| `fanvil-x3u-pro`   | desk phone                            | 6     |
| `fanvil-x4u`       | desk phone                            | 12    |
| `fanvil-x5u`       | desk phone                            | 16    |
| `fanvil-x5u-r`     | desk phone                            | 16    |
| `fanvil-x6u`       | desk phone                            | 20    |
| `fanvil-x7`        | desk phone                            | 20    |
| `fanvil-x7c`       | desk phone                            | 20    |
| `fanvil-x210`      | desk phone                            | 20    |
| `fanvil-x301`      | desk phone (also X301P, X301G, X301W) | 2     |
| `fanvil-x303`      | desk phone (also X303P, X303G, X303W) | 4     |
| `fanvil-x305`      | desk phone                            | 2     |
| `fanvil-x306`      | desk phone                            | 2     |

</details>

<details>
<summary>Grandstream adapters: 6 models</summary>

| `model`             | Type           | Lines |
| ------------------- | -------------- | ----- |
| `grandstream-ht801` | analog adapter | 1     |
| `grandstream-ht802` | analog adapter | 2     |
| `grandstream-ht812` | analog adapter | 2     |
| `grandstream-ht813` | analog adapter | 1     |
| `grandstream-ht814` | analog adapter | 4     |
| `grandstream-ht818` | analog adapter | 8     |

</details>

<details>
<summary>Grandstream phones: 51 models</summary>

| `model`                | Type        | Lines |
| ---------------------- | ----------- | ----- |
| `grandstream-ghp610`   | hotel phone | 2     |
| `grandstream-ghp611`   | hotel phone | 2     |
| `grandstream-ghp620`   | hotel phone | 2     |
| `grandstream-ghp621`   | hotel phone | 2     |
| `grandstream-ghp630`   | hotel phone | 2     |
| `grandstream-ghp631`   | hotel phone | 2     |
| `grandstream-grp2601`  | desk phone  | 2     |
| `grandstream-grp2602`  | desk phone  | 4     |
| `grandstream-grp2603`  | desk phone  | 6     |
| `grandstream-grp2604`  | desk phone  | 6     |
| `grandstream-grp2610`  | desk phone  | 2     |
| `grandstream-grp2611g` | desk phone  | 3     |
| `grandstream-grp2612`  | desk phone  | 4     |
| `grandstream-grp2613`  | desk phone  | 4     |
| `grandstream-grp2613w` | desk phone  | 6     |
| `grandstream-grp2614`  | desk phone  | 12    |
| `grandstream-grp2615`  | desk phone  | 16    |
| `grandstream-grp2616`  | desk phone  | 16    |
| `grandstream-grp2624`  | desk phone  | 12    |
| `grandstream-grp2634`  | desk phone  | 12    |
| `grandstream-grp2636`  | desk phone  | 16    |
| `grandstream-grp2650`  | desk phone  | 16    |
| `grandstream-grp2670`  | desk phone  | 16    |
| `grandstream-gxp1610`  | desk phone  | 1     |
| `grandstream-gxp1615`  | desk phone  | 1     |
| `grandstream-gxp1620`  | desk phone  | 2     |
| `grandstream-gxp1625`  | desk phone  | 2     |
| `grandstream-gxp1628`  | desk phone  | 2     |
| `grandstream-gxp1630`  | desk phone  | 3     |
| `grandstream-gxp1760`  | desk phone  | 3     |
| `grandstream-gxp1780`  | desk phone  | 4     |
| `grandstream-gxp1782`  | desk phone  | 4     |
| `grandstream-gxp2130`  | desk phone  | 3     |
| `grandstream-gxp2135`  | desk phone  | 4     |
| `grandstream-gxp2140`  | desk phone  | 4     |
| `grandstream-gxp2160`  | desk phone  | 6     |
| `grandstream-gxp2170`  | desk phone  | 6     |
| `grandstream-gxv3350`  | video phone | 16    |
| `grandstream-gxv3370`  | video phone | 16    |
| `grandstream-gxv3380`  | video phone | 16    |
| `grandstream-gxv3450`  | video phone | 16    |
| `grandstream-gxv3470`  | video phone | 16    |
| `grandstream-gxv3480`  | video phone | 16    |
| `grandstream-wp810`    | Wi-Fi phone | 2     |
| `grandstream-wp816`    | Wi-Fi phone | 2     |
| `grandstream-wp820`    | Wi-Fi phone | 2     |
| `grandstream-wp822`    | Wi-Fi phone | 2     |
| `grandstream-wp825`    | Wi-Fi phone | 2     |
| `grandstream-wp826`    | Wi-Fi phone | 3     |
| `grandstream-wp836`    | Wi-Fi phone | 3     |
| `grandstream-wp856`    | Wi-Fi phone | 6     |

</details>

<details>
<summary>Poly: 21 models</summary>

| `model`          | Type       | Lines |
| ---------------- | ---------- | ----- |
| `poly-edge-e100` | desk phone | 8     |
| `poly-edge-e220` | desk phone | 16    |
| `poly-edge-e300` | desk phone | 32    |
| `poly-edge-e320` | desk phone | 32    |
| `poly-edge-e350` | desk phone | 32    |
| `poly-edge-e400` | desk phone | 34    |
| `poly-edge-e450` | desk phone | 34    |
| `poly-edge-e500` | desk phone | 34    |
| `poly-edge-e550` | desk phone | 34    |
| `poly-vvx101`    | desk phone | 1     |
| `poly-vvx150`    | desk phone | 2     |
| `poly-vvx201`    | desk phone | 2     |
| `poly-vvx250`    | desk phone | 34    |
| `poly-vvx301`    | desk phone | 34    |
| `poly-vvx311`    | desk phone | 34    |
| `poly-vvx350`    | desk phone | 34    |
| `poly-vvx401`    | desk phone | 34    |
| `poly-vvx411`    | desk phone | 34    |
| `poly-vvx450`    | desk phone | 34    |
| `poly-vvx501`    | desk phone | 34    |
| `poly-vvx601`    | desk phone | 34    |

</details>

<details>
<summary>Snom: 14 models</summary>

| `model`     | Type       | Lines |
| ----------- | ---------- | ----- |
| `snom-d120` | desk phone | 2     |
| `snom-d140` | desk phone | 2     |
| `snom-d150` | desk phone | 2     |
| `snom-d315` | desk phone | 4     |
| `snom-d335` | desk phone | 12    |
| `snom-d385` | desk phone | 12    |
| `snom-d713` | desk phone | 6     |
| `snom-d717` | desk phone | 6     |
| `snom-d735` | desk phone | 12    |
| `snom-d785` | desk phone | 12    |
| `snom-d812` | desk phone | 12    |
| `snom-d815` | desk phone | 12    |
| `snom-d862` | desk phone | 8     |
| `snom-d865` | desk phone | 12    |

</details>

<details>
<summary>Yealink: 28 models</summary>

| `model`         | Type             | Lines |
| --------------- | ---------------- | ----- |
| `yealink-cp920` | conference phone | 1     |
| `yealink-cp925` | conference phone | 1     |
| `yealink-cp965` | conference phone | 1     |
| `yealink-t30`   | desk phone       | 1     |
| `yealink-t30p`  | desk phone       | 1     |
| `yealink-t31`   | desk phone       | 2     |
| `yealink-t31g`  | desk phone       | 2     |
| `yealink-t31p`  | desk phone       | 2     |
| `yealink-t31w`  | desk phone       | 2     |
| `yealink-t33g`  | desk phone       | 4     |
| `yealink-t33p`  | desk phone       | 4     |
| `yealink-t34w`  | desk phone       | 4     |
| `yealink-t41s`  | desk phone       | 6     |
| `yealink-t42s`  | desk phone       | 12    |
| `yealink-t42u`  | desk phone       | 12    |
| `yealink-t43u`  | desk phone       | 12    |
| `yealink-t44u`  | desk phone       | 12    |
| `yealink-t44w`  | desk phone       | 12    |
| `yealink-t46s`  | desk phone       | 16    |
| `yealink-t46u`  | desk phone       | 16    |
| `yealink-t48s`  | desk phone       | 16    |
| `yealink-t48u`  | desk phone       | 16    |
| `yealink-t53`   | desk phone       | 12    |
| `yealink-t53w`  | desk phone       | 12    |
| `yealink-t54w`  | desk phone       | 16    |
| `yealink-t57w`  | desk phone       | 16    |
| `yealink-t58a`  | desk phone       | 16    |
| `yealink-t58w`  | desk phone       | 16    |

</details>

## Cisco

Third-party call control firmware only: phones with enterprise (CUCM) firmware
don't work. On the adapters, line n is port n.

| Key                                             | Setting                                         | Value                                         |
| ----------------------------------------------- | ----------------------------------------------- | --------------------------------------------- |
| `Profile_Rule`                                  | provisioning server                             | `http://<listenAddress>/$MA.xml`              |
| `Profile_Rule_B`                                | second rule, which the model's first file sets  | empty                                         |
| `Webex_Onboard_Enable`                          | Webex cloud onboarding, multiplatform phones    | `No`                                          |
| `Admin_Password`                                | admin password, multiplatform phones            | `adminPassword`                               |
| `Admin_Passwd`                                  | admin password, SPA phones and SPA8000          | `adminPassword`                               |
| `router-configuration/Web_Login_Admin_Password` | admin password, ATA 191/192 and SPA112/122      | `adminPassword`                               |
| `Primary_NTP_Server`                            | NTP server, phones and SPA8000                  | `ntpServer`                                   |
| `router-configuration/Time_Setup/Time_Server`   | NTP server, ATA 191/192 and SPA112/122          | `ntpServer`, with `Time_Server_Mode` `manual` |
| `Line_Enable_n_`                                | line n                                          | `Yes`, `No` if unused                         |
| `Proxy_n_`                                      | SIP server                                      | `sipServer`, plus `:sipPort` if not 5060      |
| `User_ID_n_`                                    | SIP user                                        | the endpoint's name                           |
| `Auth_ID_n_`                                    | auth user                                       | the endpoint's auth user name                 |
| `Password_n_`                                   | password                                        | the endpoint's password                       |
| `Use_Auth_ID_n_`                                | use the auth user, all but multiplatform phones | `Yes`                                         |

- `settings` keys are the element names of the device's `/admin/config.xml`,
  or a path into a section: `router-configuration/Time_Setup/Time_Zone`.
- The model's first file (`8841-3PCC.xml`, `spa112.cfg`, `spa502G.cfg`) holds
  only the two rules, so the device fetches its own file right after.
- Admin password: 8 to 127 characters from `!` to `~` of three kinds on
  multiplatform phones, at least 8 on the ATA 191/192, at most 32 on the
  SPA112/122.
- A multiplatform phone or ATA 191/192 that gets no provisioning server from
  DHCP asks Cisco's activation servers. No setting turns that off.

## Fanvil

Fanvil's sysConf format, firmware 2.4 to 2.14. P, G and W variants take the
model they extend.

| Key                                       | Setting              | Value                          |
| ----------------------------------------- | -------------------- | ------------------------------ |
| `ap.FlashServerIP`                        | provisioning server  | `http://<listenAddress>`       |
| `ap.FlashFileName`                        | file name            | `$mac.cfg`                     |
| `ap.FlashProtocol`, `ap.FlashMode`        | protocol, when       | HTTP (`4`), every reboot (`1`) |
| `ota.FDPSEnable`                          | Fanvil's redirection | `0`                            |
| `web.account.1.Name`, `Password`, `Level` | web interface admin  | `admin`, `adminPassword`, `10` |
| `phone.date.EnableSNTP`, `SNTPServer`     | NTP server           | `1`, `ntpServer`               |
| `sip.line.n.EnableReg`                    | line n               | `1`, `0` if unused             |
| `sip.line.n.PhoneNumber`                  | SIP user             | the endpoint's name            |
| `sip.line.n.RegisterUser`                 | auth user            | the endpoint's auth user name  |
| `sip.line.n.RegisterPswd`                 | password             | the endpoint's password        |
| `sip.line.n.RegisterAddr`, `RegisterPort` | SIP server           | `sipServer`, `sipPort`         |

- `settings` keys are paths below `<sysConf>`, a number being the index of the
  element before it: `sip.line.1.DisplayName`. The web interface exports the
  whole configuration (System > Configurations), time zone included.
- A device skips a file it applied last time, so a change in its web interface
  stays until the file changes.
- Web interface password: 1 to 39 letters and digits.
- The X3S/X3SP (neither Lite nor Pro), X4, X4G, X1, X1P, X2P, X2C, H3, H5,
  i12, i16V, i18S, i20S, i32V, i33V and PA2 take another format and aren't
  supported.

## Grandstream adapters

HT8xx analog adapters, whose lines are their phone ports. V1 and V2 hardware
get the same file.

| P-value | Setting                | Value                                    |
| ------- | ---------------------- | ---------------------------------------- |
| P212    | config download        | HTTP                                     |
| P237    | config server          | `listenAddress`, plus the port if not 80 |
| P238    | firmware check         | skipped                                  |
| P1409   | TR-069 (GDMS cloud)    | off                                      |
| P2      | web interface password | `adminPassword`, if set                  |
| P30     | NTP server             | `ntpServer`, if set                      |
| P64     | time zone              | `grandstream.timeZone`, if set           |

HT801, HT802 and HT813: each port has a SIP account of its own.

| Port 1 | Port 2 | Setting           | Value                                   |
| ------ | ------ | ----------------- | --------------------------------------- |
| P271   | P401   | account active    | yes, no for an unused port              |
| P47    | P747   | SIP server        | `sipServer`, with `sipPort` if not 5060 |
| P35    | P735   | SIP user ID       | the endpoint's name                     |
| P36    | P736   | authentication ID | the endpoint's auth user name           |
| P34    | P734   | password          | the endpoint's password                 |

HT812, HT814 and HT818: every port registers with profile 1, which gets P271
(on) and P47 (the SIP server).

| P-value   | Setting           | Value                         |
| --------- | ----------------- | ----------------------------- |
| P4594 + n | port n enabled    | yes, no for an unused port    |
| P4059 + n | SIP user ID       | the endpoint's name           |
| P4089 + n | authentication ID | the endpoint's auth user name |
| P4119 + n | password          | the endpoint's password       |
| P4149 + n | profile           | profile 1                     |

- `settings` take P-values.
- Left alone: the HT813's FXO port, profile 2 of the HT812/HT814/HT818, and
  P1414 (turning it off might stop provisioning).
- Web interface password: 4 to 30 characters on V2 hardware, no spaces on V1.
- IPv6 goes into P47 bare and into P237 in brackets.
- Calls ring the phone. It can't auto-answer.

## Grandstream phones

Desk, Wi-Fi, hotel and video phones, whose lines are their SIP accounts. They
get the adapters' P212, P237, P238, P1409, P2, P30 and P64, except that the
GXP16xx and GXP17xx have no P1409, and the Android phones (WP820, WP856,
GXV33xx, GXV34xx) take a zone name like `Europe/Berlin` in P64, from
`settings` only.

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

- The GRP260x has accounts 5 and 6 at P701 to P706 and P801 to P806.
- W, P and G variants take the model they extend, except the GRP2613W.
- The GXP1610/1615 get 1 line, as their template says. Their datasheet says 2.
- Older GRP2612/2613 hardware has 2 and 3 accounts.

## Poly

VVX phones on UC Software, Edge E phones on PVOS. `<mac>.cfg` names
`<mac>-settings.cfg`, which holds the parameters.

| Key                                                                     | Setting                              | Value                                |
| ----------------------------------------------------------------------- | ------------------------------------ | ------------------------------------ |
| `device.set`                                                            | apply `device.*` parameters          | `1`                                  |
| `device.baseProfile`                                                    | profile                              | `Generic`                            |
| `device.prov.serverName`, `serverType`                                  | provisioning server                  | `http://<listenAddress>`, `HTTP`     |
| `feature.da.enabled`, `feature.obitalk.enabled`                         | Poly's analytics, OBiTALK cloud      | `0`                                  |
| `device.prov.ztpEnabled`, `feature.lens.enabled`, `feature.pcc.enabled` | ZTP, Lens, Cloud Connector, VVX only | `0`                                  |
| `device.auth.localAdminPassword`                                        | admin password                       | `adminPassword`                      |
| `tcpIpApp.sntp.address`                                                 | NTP server, over DHCP's              | `ntpServer`                          |
| `reg.n.address`                                                         | registration n                       | the endpoint's name, empty if unused |
| `reg.n.auth.userId`, `reg.n.auth.password`                              | auth user, password                  | the endpoint's                       |
| `reg.n.server.1.address`, `port`                                        | SIP server                           | `sipServer`, `sipPort`               |

- Each `device.*` parameter comes with its `.set` at `1`. One from `settings`
  needs that too.
- Changes on the phone win over provisioning until they're reset (Settings >
  Advanced > Administration Settings > Reset to Defaults).
- Admin password: 1 to 32 ASCII characters without `<` and `>`, and not 456.
- Trio, CCX and the OBi Edition VVX phones aren't supported.

## Snom

D series desk phones on firmware 10.1. The file name has the MAC in uppercase.

| Key                                                | Setting                        | Value                                          |
| -------------------------------------------------- | ------------------------------ | ---------------------------------------------- |
| `setting_server`                                   | provisioning server            | `http://<listenAddress>/snom<model>-{mac}.htm` |
| `update_policy`                                    | updates                        | `settings_only`, never firmware                |
| `tr369_enable[1]`                                  | Snom's device management       | `false`, not on the D120                       |
| `http_user`, `http_pass`                           | web interface login            | `admin`, `adminPassword`                       |
| `webserver_admin_name`, `webserver_admin_password` | Phone Manager login, D862/D865 | `admin`, `adminPassword`                       |
| `ntp_server`                                       | NTP server                     | `ntpServer`                                    |
| `timezone`                                         | time zone                      | `snom.timeZone`, such as `GER+1`               |
| `user_active[n]`                                   | line n                         | `on`, `off` if unused                          |
| `user_host[n]`                                     | SIP server                     | `sipServer`, plus `:sipPort` if not 5060       |
| `user_name[n]`                                     | SIP user                       | the endpoint's name                            |
| `user_pname[n]`, `user_pass[n]`                    | auth user, password            | the endpoint's                                 |

- `settings` keys are a setting's name, or `name[index]` for an indexed one:
  `"user_realname[1]" = "Reception"`.
- What the module sets is read-only on the phone. `setting_server` and
  `settings` are writable.
- A setting removed from the config keeps its last value on the phone.
- The D862 and D865 show a welcome screen until `language` is set.
- The C520, C620 and the M series DECT bases aren't supported.

## Yealink

Desk and conference phones on firmware V84 or later.

| Key                                      | Setting             | Value                                            |
| ---------------------------------------- | ------------------- | ------------------------------------------------ |
| `static.auto_provision.server.url`       | provisioning server | `http://<listenAddress>/`                        |
| `static.dm.enable`                       | device management   | `0`, not on the T31W, T34W, T58A, T58W and CP965 |
| `static.security.user_password`          | admin password      | `admin:` and `adminPassword`                     |
| `local_time.ntp_server1`                 | NTP server          | `ntpServer`                                      |
| `account.n.enable`                       | account n           | `1`, `0` if unused                               |
| `account.n.user_name`                    | SIP user            | the endpoint's name                              |
| `account.n.auth_name`, `password`        | auth user, password | the endpoint's                                   |
| `account.n.sip_server.1.address`, `port` | SIP server          | `sipServer`, `sipPort`                           |

- `settings` take parameter names: `"local_time.time_zone" = "+1"` with
  `"local_time.time_zone_name" = "Germany(Berlin)"`.
- An NTP server from DHCP wins unless `local_time.manual_ntp_srv_prior` is 1.
- Admin password: 1 to 32 characters from `!` to `~`, no colon. V87 firmware
  makes you change the default one on first use.
- A phone a reseller put in Yealink's RPS can be set up from the reseller's
  server after a factory reset. Yealink's RPS MAC removal tool takes it out.
- DECT base stations (W60B, W70B, W80B) aren't supported.

## Other devices

Write their files yourself. Or upstream them pls :3

```nix
pbx.phones.files."0015651234ab.cfg" = {
  text = ''
    account.1.password = ${config.lib.asterisk.secret config.sops.secrets.sip-101.path}
  '';
  allowedAddress = "10.0.20.21";
};
```

| Option           | Default | What                                                              |
| ---------------- | ------- | ----------------------------------------------------------------- |
| `text`           |         | contents. Secret references are filled in when the service starts |
| `escape`         | `none`  | `xml` escapes secrets, `line` refuses one with a line break       |
| `allowedAddress` | anyone  | the only address that may fetch the file                          |
| `tftp`           | off     | serve it over TFTP too, on UDP port 69                            |

## Adding a device

A device nobody has tried on real hardware is fine.

1. Add a module `modules/pbx/phones/<vendor>.nix` like `yealink.nix`, or a
   model to an existing vendor's `models`. It adds its models to
   `pbx.phones.models` as `<vendor>-<model>` and writes their devices' files
   into `pbx.phones.files`.
2. Set only settings the vendor documents for that device, cite the source and
   its version, and cross-check them against FusionPBX's and Wazo's templates.
3. Test the files it writes in `tests/pbx/phones-<vendor>.nix`, listed in the
   `pbx-phones` suite of `tests/default.nix`.
4. Add the vendor to the tables here and a section like the ones above.

## Sources

Every key is cross-checked against FusionPBX's and Wazo's templates, and line
counts against the vendors' datasheets.

| Vendor      | Documents                                                                                                                                                                                                                                                                                                                                                                                                                |
| ----------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Cisco       | Multiplatform desk and conference phone admin guides (12.0(7)SR3), ATA 191/192 provisioning guide (11.3(1)), SPA100 provisioning guide (1.3), SPA300/SPA500 admin guide (OL-19749-09), SPA8000 admin guide (OL-17901-01)                                                                                                                                                                                                 |
| Fanvil      | the key maps and help texts inside the firmware images at download.fanvil.com (2.4 to 2.14). Fanvil's public guides don't list the keys                                                                                                                                                                                                                                                                                  |
| Grandstream | `config-template.zip` from grandstream.com/support/tools: ht80x 1.0.65.3, ht80x_v2 1.0.15.3, ht81x 1.0.65.3, ht81x_v2 1.0.15.3, ht813 1.0.19.6, ht818 1.0.65.1, gxp16xx 1.0.7.81, gxp17xx 1.0.1.133, gxp2130_40_60_70_35 1.0.11.106, grp260x 1.0.7.71, grp26xx 1.0.15.19, wp810_822_825 1.0.11.83, wp8x6 1.0.3.39, wp820 1.0.7.90, wp856 1.0.3.16, ghp6xx 1.0.1.101, ghp63x 1.0.1.50, gxv33xx 1.0.3.57, gxv34x0 1.0.5.40 |
| Poly        | UC Software 6.4.0 administrator guide, Edge E parameter reference (PVOS 8.2.1)                                                                                                                                                                                                                                                                                                                                           |
| Snom        | settings reference at service.snom.com (10.1.226.16)                                                                                                                                                                                                                                                                                                                                                                     |
| Yealink     | SIP-T2/T3/T4/T5/CP920 administrator guide (V86.60), VP59/T58/CP96X administrator guide (V86.11). The T31W and T34W take the keys FusionPBX and Wazo set                                                                                                                                                                                                                                                                  |
