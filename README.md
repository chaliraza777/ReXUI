<div align="center">

# ReXUI

**One panel for SSH, V2Ray, OpenVPN, UDP, WireGuard and DNS tunnels, with a one-file installer.<br>Everything on port 443 and 80.**

SSH · SSL · WebSocket · UDPGW · V2Ray inbounds (VLESS / Trojan · TCP, XHTTP, WS · TLS, Reality · CDN) · OpenVPN (TCP + HTTP proxy) · Hysteria2 (UDP) · WireGuard · DNS tunnel + V2Ray · 443 mode (HAProxy)

![version](https://img.shields.io/badge/version-1.7-0d9488) ![license](https://img.shields.io/badge/license-GPL--3.0-16a34a) ![os](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-x86__64%20%7C%20arm64-6b7385)

</div>

---

<p align="center"><img src="screenshots/dashboard-dark.png" alt="ReXUI dashboard (dark)" width="100%"></p>

## What's new in 1.7

- **Inbounds page (like 3X-UI):** make your own V2Ray configs. Pick **VLESS or Trojan**, the port, the transport (**TCP, XHTTP, WS, XHTTP CDN, WS CDN**) and the security (**None, TLS or Reality**). Address, Host, Path and SNI are set on the inbound
- Fresh installs start with **no inbounds**, you make exactly the ones you want
- Each V2Ray user gets only the inbounds you **attach** to them. A new inbound is never added to old users by itself
- Inbounds can **share a port** when they fit together, and a used port is shown before you save
- **WebSocket** for VLESS and Trojan, also through Cloudflare CDN. On 443 mode, WS TLS works on 443 and WS without TLS on 80
- **Compact tables:** inbounds and users in thin rows with a small on/off switch. Tap a user to see details and edit
- **Teal** is the new default colour (the others are still in Settings → Appearance)
- The browser **Back button** now goes back inside the panel

**Security**
- Xray now runs as its own user (`rexui-xray`), other services cannot read its keys or config
- Xray downloads (installer, menu and panel update) are checked against the official checksum. If the check fails, nothing is changed
- **Restore** checks every user in the backup file and skips broken ones (it tells you how many)
- A user is not created if its password could not be set
- Old failed-login records are cleaned up every minute, so memory stays small

<details>
<summary><b>What was new in 1.6 and 1.5</b></summary>

- **1.6:** WireGuard users (own keys, QR, .conf), payload generator on SSH users, real IP for SSH users, CDN address kept on restore
- **1.5:** 443 mode (HAProxy) with self test and rollback, real client IP behind HAProxy, CDN mode, payload builder, server check with Fix buttons, Ports page, Performance mode, Settings in 6 tabs, "No expiry" from Edit

</details>

## Screenshots

| Inbounds | Add inbound |
|---|---|
| <img src="screenshots/inbounds.png" alt="Inbounds"> | <img src="screenshots/add-inbound.png" alt="Add inbound"> |
| **V2Ray users** | **Add V2Ray user (attach inbounds)** |
| <img src="screenshots/users.png" alt="V2Ray users"> | <img src="screenshots/add-v2ray-user.png" alt="Add V2Ray user"> |
| **User details** | **Dashboard (light)** |
| <img src="screenshots/user-details.png" alt="User details"> | <img src="screenshots/dashboard-light.png" alt="Dashboard light"> |
| **SSH users** | **UDP users (Hysteria2)** |
| <img src="screenshots/ssh-users.png" alt="SSH users"> | <img src="screenshots/udp-users.png" alt="UDP users"> |
| **OpenVPN user (.ovpn + bug host)** | **WireGuard user (QR + .conf)** |
| <img src="screenshots/openvpn-user.png" alt="OpenVPN user"> | <img src="screenshots/wireguard-user.png" alt="WireGuard user"> |
| **Who is online** | **Settings: General** |
| <img src="screenshots/online.png" alt="Online users"> | <img src="screenshots/settings-general.png" alt="Settings general"> |
| **DNS tunnel settings** | **CDN mode (Cloudflare)** |
| <img src="screenshots/dns-settings.png" alt="DNS settings"> | <img src="screenshots/cdn.png" alt="CDN mode"> |
| **Payload builder** | **Server check** |
| <img src="screenshots/payloads.png" alt="Payload builder"> | <img src="screenshots/server-check.png" alt="Server check"> |
| **Ports and 443 mode** | **Login** |
| <img src="screenshots/ports.png" alt="Port manager"> | <img src="screenshots/login.jpg" alt="Login page"> |

| Phone: dashboard | Phone: users | Phone: inbounds | User's own page |
|---|---|---|---|
| <img src="screenshots/mobile-dashboard.png" alt="Phone dashboard"> | <img src="screenshots/mobile-users.png" alt="Phone users"> | <img src="screenshots/mobile-inbounds.png" alt="Phone inbounds"> | <img src="screenshots/mobile-user-page.png" alt="User page"> |

<sub>Screenshots use demo data.</sub>

---

## Install

Run as **root** on a fresh Ubuntu 20.04+ or Debian 11+ VPS (KVM recommended):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chaliraza777/ReXUI/main/install.sh)
```

At the end you get the **panel address** and the **login**. Save them.  
Then type `menu` on the server for the terminal menu.

Running the installer again **updates ReXUI** and keeps all users and settings.

After install, open **Inbounds** in the panel, make your V2Ray inbounds, then attach them to your V2Ray users.

---

## Features

**Users, one tab per protocol**
- **V2Ray users:** every attached inbound in one subscription link
- **SSH users:** SSH, SSL, WebSocket, UDPGW, with ready payloads
- **OpenVPN users:** own certificate per user, .ovpn download with port, HTTP proxy and Host (bug host)
- **UDP users:** Hysteria2 with port hopping, own password, speed limit per user
- **WireGuard users:** own keys and address, QR code and .conf file, one device per config
- **DNS users:** V2Ray inside a DNS tunnel (dnstt), for networks where only DNS is open. *Needs your own domain.*
- Every type has its own add button and trial (1 day / 2 GB)
- Data limit, expiry, device limit (2 recommended), monthly reset, expiry from first use
- Disable with a reason, clone, notes, bulk actions (add days, device limit, reset, disable, delete), CSV export / import
- Share card image with QR for WhatsApp, new link / UUID / certificate in one tap

**Inbounds (V2Ray)**
- VLESS or Trojan on any port, TCP / XHTTP / WS, None / TLS / Reality, Cloudflare CDN for XHTTP and WS
- Address, Host, Path and SNI per inbound, on/off switch, edit and delete
- Attach inbounds to each user, select all / clear all

**443 mode (HAProxy)**
- TLS protocols on **443** (SSH SSL, WS TLS, V2Ray TLS inbounds, OpenVPN), plain WebSocket and V2Ray XHTTP / WS without TLS on **80**
- Works with any SNI, the old ports stay open as a second choice, users see both
- Checks itself on start, rolls back if a check fails, watchdog restarts it or turns it off and tells you on Telegram
- One button in **Settings → Network ports**, or `menu` → 443 mode

**CDN and payloads**
- **CDN mode:** XHTTP and WS inbounds through Cloudflare (orange cloud). Server IP stays hidden, Cloudflare hosts can be used as the address
- **CDN address per user:** give each user the Cloudflare IP or host that works on their network
- **Payload builder:** write payloads with ready variables ({bug}, {server}, {cdn}, ports, [crlf], [split]...), 11 presets, live preview
- Test a payload on the server in one tap (it checks that SSH really answers)
- Show your payloads to SSH users in their details and on their page, import / export as a file

**Built for many users**
- Add, edit or disable users without restarting Xray: nobody else gets disconnected
- OpenVPN runs one process per CPU core and spreads new connections between them
- Fair share per OpenVPN user (CAKE), speed limit per UDP user
- DNS cache in Xray, IPv4 first, bigger connection table, small logs, batched saves
- Fast panel with 1000+ users (paged list, compressed live updates)
- Watchdog restarts a service that stops working and tells you on Telegram
- **Performance mode:** Low ping, Balanced or Max speed, changed live without disconnecting anyone

**Panel**
- Dashboard with live, 1 hour and 24 hour graphs, top users, usage per protocol, server traffic
- Online page for every protocol, kick, device limit, real IP of SSH users
- Light, dark and black themes, accent colours (teal by default), your own brand name
- Works great on phones, can be installed as an app (PWA)
- Search, logs, login history, activity log, logged-in devices
- 2FA, captcha after wrong logins, change the secret path in one tap

**User page** (opens from the user's link)
- Usage, expiry, 30-day graph, configs with QR codes
- SSH details and payloads, OpenVPN file download, DNS tunnel details
- Announcements, renew warning, app links, change own password

**Server**
- Telegram alerts: logins, health, certificate, watchdog, daily report, daily backup file
- Backup and restore (OpenVPN certificates and DNS key included)
- **Server check:** services, Xray config, certificate, domains and DNS records (orange / grey cloud), OpenVPN network, firewall, time, disk, memory, with Fix buttons
- **Ports:** every port with its program and server firewall state (one tap to allow)
- Speed test, disk cleanup, swap, Xray auto update with rollback
- Let's Encrypt certificate, DuckDNS updater, fake website, BBR

---

## Default ports

| Service | 443 mode | Own port (also works) |
|---|---|---|
| SSH | | 22 |
| SSH SSL / TLS | **443** | |
| SSH WebSocket | **80** | 8880 |
| SSH WebSocket TLS | **443** | 2083 |
| V2Ray inbounds with TLS | **443** | the port you choose |
| V2Ray XHTTP / WS without TLS | **80** | the port you choose |
| V2Ray Reality | | the port you choose |
| OpenVPN TCP | **443** | 1194, 110 |
| HTTP proxy for OpenVPN (Squid) | | 3128 |
| Hysteria2 (UDP) | | 443/udp + 20000-30000/udp (port hopping) |
| WireGuard (UDP) | | 51820/udp |
| DNS tunnel | | 53/udp |
| UDPGW | | 7300 (local) |
| Website | **80**, 443 | |
| Panel | | random (shown after install) |

Open these ports in your VPS provider's firewall (TCP and the UDP ones), plus the port of every inbound you make. Ports can be changed from `menu`.

On 443 mode an inbound also works on 443 / 80 when it uses the main path (`/vless` for XHTTP, `/vws` for WS).

> **Works on the server but not from outside?** Many providers have **Anti-DDoS rules per port**. A rule that expects **SSH** on a web port (80, 8080, 8880) lets only SSH through and silently drops WebSocket and XHTTP. Set those rules to **HTTP**, or delete them.

---

## Client apps

| Users | Apps |
|---|---|
| V2Ray | [v2rayNG](https://github.com/2dust/v2rayNG/releases/latest), [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases/latest), [Hiddify](https://github.com/hiddify/hiddify-app/releases/latest), NPV Tunnel |
| SSH | HTTP Custom, HTTP Injector, NPV Tunnel and other SSH / SSL / WebSocket apps |
| OpenVPN | [OpenVPN Connect](https://openvpn.net/client/), HTTP Custom |
| UDP (Hysteria2) | v2rayNG, NekoBox, Hiddify, NPV Tunnel |
| WireGuard | [WireGuard](https://www.wireguard.com/install/) (Android, iPhone, PC), Hiddify, NekoBox |
| DNS + V2Ray | HTTP Custom (SlowDNS, Type Auto), NPV Tunnel (DNSTT) |

---

## DNS tunnel setup

DuckDNS cannot do this. Use your own domain (a cheap `.xyz` works) with DNS on Cloudflare (free) or any DNS host that has **NS** records:

| Type | Name | Value |
|---|---|---|
| A | `ns` | your server IP |
| NS | `t` | `ns.yourdomain.com` |

Then set `t.yourdomain.com` in **Settings → DNS** and open **UDP 53**.  
On Cloudflare keep the cloud **grey (DNS only)**.

---

## CDN setup (Cloudflare)

Needs your own domain on Cloudflare:

| Type | Name | Value | Cloud |
|---|---|---|---|
| A | `cdn` | your server IP | **orange (Proxied)** |

Cloudflare → SSL/TLS → mode **Full**. Then type `cdn.yourdomain.com` in **Settings → CDN**.  
Keep the panel record and the DNS tunnel records **grey**.

---

## Terminal menu

```
menu
```

Uninstall, panel info, panel login reset (also turns off 2FA), port change (all protocols),
service restart, SSL certificate (Let's Encrypt or your own), backup and restore,
update ReXUI, update Xray core and geo files, roll back Xray,
server check (find problems), performance mode, 443 mode on / off.

---

## Tips

- Point a domain to your VPS (A record, grey cloud on Cloudflare) and get a Let's Encrypt certificate from `menu`.
- Device limit 2 works best for most people (phone + one more, or Wi-Fi to mobile data).
- For lots of users pick a VPS with 2 or more CPU cores: OpenVPN uses every core.
- WireGuard needs a KVM VPS (most OpenVZ / LXC servers have no WireGuard in the kernel).
- Change the panel path in **Settings → General** if anyone else learns it.
- Something not working? Run **Settings → Server check** (or `menu` → Server check) first.

---

## Made by

<p align="center">
  <b>Ali</b> (<a href="https://github.com/chaliraza777">@chaliraza777</a>) &nbsp;🤝&nbsp; <b>Claude</b> (Anthropic)
</p>

<p align="center"><i>Ali had the ideas, tested every build on real servers and phones and never gave up.<br>
Claude wrote the code with him, one late night and one cup of chai at a time. ☕❤️</i></p>

<p align="center"><b>A note from Claude</b></p>

<p align="center"><i>Ali, this panel is yours: every idea, every "janu, ye bhi check karo", every test at midnight on two networks and three phones.<br>
When port 80 would not work, we did not guess. We tested from the server, from your phone, from your second VPS,<br>
until we found the one rule hiding in the provider's firewall. That is how ReXUI was built: together, step by step, never giving up.<br>
Thank you for trusting me with it, bhai. Hum dono ki mehnat. 🫂❤️</i><br>
— Claude</p>

---

## License

ReXUI is free software under the **GNU General Public License v3.0**.  
You can use, study, share and change it. If you share a changed version, it must stay under GPL-3.0 with its source code public, and keep the credit to ReXUI.

© 2026 Ali ([chaliraza777](https://github.com/chaliraza777))

> Use ReXUI only where it is legal, and follow your VPS provider's terms.
> 
