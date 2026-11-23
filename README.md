<div align="center">

# ReXUI

**One panel for SSH, V2Ray, OpenVPN, UDP and DNS tunnels, with a one-file installer**

SSH · SSL · WebSocket · UDPGW · VLESS (Reality, XHTTP, TCP TLS) · Trojan · OpenVPN (TCP + HTTP proxy) · Hysteria2 (UDP) · DNS tunnel + V2Ray

![version](https://img.shields.io/badge/version-1.0-1f6feb) ![license](https://img.shields.io/badge/license-GPL--3.0-16a34a) ![os](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-x86__64%20%7C%20arm64-6b7385)

</div>

---

<p align="center"><img src="screenshots/dashboard-dark.png" alt="ReXUI dashboard (dark)" width="100%"></p>

## Screenshots

| Dashboard (light) | V2Ray users |
|---|---|
| <img src="screenshots/dashboard-light.png" alt="Dashboard light"> | <img src="screenshots/users.png" alt="Users table"> |
| **User details** | **OpenVPN user (.ovpn + bug host)** |
| <img src="screenshots/user-details.png" alt="User details"> | <img src="screenshots/openvpn-user.png" alt="OpenVPN user"> |
| **UDP users (Hysteria2)** | **Who is online** |
| <img src="screenshots/udp-users.png" alt="UDP users"> | <img src="screenshots/online.png" alt="Online users"> |
| **DNS tunnel settings** | **Server tools** |
| <img src="screenshots/dns-settings.png" alt="DNS settings"> | <img src="screenshots/settings.png" alt="Settings tools"> |
| **Login** | **Share card** |
| <img src="screenshots/login.jpg" alt="Login page"> | <img src="screenshots/share-card.png" alt="Share card" width="60%"> |

| Phone: dashboard | Phone: users | Phone: UDP user |
|---|---|---|
| <img src="screenshots/mobile-dashboard.png" alt="Phone dashboard"> | <img src="screenshots/mobile-users.png" alt="Phone users"> | <img src="screenshots/mobile-udp-user.png" alt="Phone UDP user"> |
| **User's own page** | **User's OpenVPN page** | |
| <img src="screenshots/mobile-user-page.png" alt="User page"> | <img src="screenshots/mobile-openvpn-page.png" alt="User OpenVPN page"> | |

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

---

## Features

**Users, one tab per protocol**
- **V2Ray users:** VLESS Reality, XHTTP, TCP TLS and Trojan in one subscription link
- **SSH users:** SSH, SSL, WebSocket, UDPGW, with ready payloads
- **OpenVPN users:** own certificate per user, .ovpn download with port, HTTP proxy and Host (bug host)
- **UDP users:** Hysteria2 with port hopping, own password, speed limit per user
- **DNS users:** V2Ray inside a DNS tunnel (dnstt), for networks where only DNS is open. *Needs your own domain.*
- Every type has its own add button and trial (1 day / 2 GB)
- Data limit, expiry, device limit (2 recommended), monthly reset, expiry from first use
- Disable with a reason, clone, notes, bulk actions (add days, device limit, reset, disable, delete), CSV export / import
- Share card image with QR for WhatsApp, new link / UUID / certificate in one tap

**Built for many users**
- Add, edit or disable users without restarting Xray: nobody else gets disconnected
- OpenVPN runs one process per CPU core and spreads new connections between them
- Fair share per OpenVPN user (CAKE), speed limit per UDP user
- DNS cache in Xray, IPv4 first, bigger connection table, small logs, batched saves
- Fast panel with 1000+ users (paged list, compressed live updates)
- Watchdog restarts a service that stops working and tells you on Telegram

**Panel**
- Dashboard with live, 1 hour and 24 hour graphs, top users, usage per protocol, server traffic
- Online page for every protocol, kick, device limit
- Light, dark and black themes, accent colours, your own brand name
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
- Speed test, port check, disk cleanup, swap, Xray auto update with rollback
- Let's Encrypt certificate, DuckDNS updater, fake website, BBR

---

## Default ports

| Service | Port |
|---|---|
| SSH | 22 |
| SSH SSL / TLS | 443 |
| SSH WebSocket | 8880 |
| SSH WebSocket TLS | 2083 |
| UDPGW | 7300 (local) |
| VLESS XHTTP TLS | 8443 |
| VLESS TCP TLS | 2053 |
| Trojan TLS | 2096 |
| VLESS Reality | 8444 |
| VLESS XHTTP | 8080 |
| OpenVPN TCP | 1194, 110 |
| HTTP proxy for OpenVPN (Squid) | 3128 |
| Hysteria2 (UDP) | 443/udp + 20000-30000/udp (port hopping) |
| DNS tunnel | 53/udp |
| Fake website | 80 |
| Panel | random (shown after install) |

Open these ports in your VPS provider's firewall (TCP and the UDP ones). Ports can be changed from `menu`.

---

## Client apps

| Users | Apps |
|---|---|
| V2Ray | [v2rayNG](https://github.com/2dust/v2rayNG/releases/latest), [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases/latest), [Hiddify](https://github.com/hiddify/hiddify-app/releases/latest), NPV Tunnel |
| SSH | HTTP Custom, HTTP Injector, NPV Tunnel and other SSH / SSL / WebSocket apps |
| OpenVPN | [OpenVPN Connect](https://openvpn.net/client/), HTTP Custom |
| UDP (Hysteria2) | v2rayNG, NekoBox, Hiddify, NPV Tunnel |
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

## Terminal menu

```
menu
```

Uninstall, panel info, panel login reset (also turns off 2FA), port change (all protocols),
service restart, SSL certificate (Let's Encrypt or your own), backup and restore,
update ReXUI, update Xray core and geo files, roll back Xray.

---

## Tips

- Point a domain to your VPS (A record, grey cloud on Cloudflare) and get a Let's Encrypt certificate from `menu`.
- Device limit 2 works best for most people (phone + one more, or Wi-Fi to mobile data).
- For lots of users pick a VPS with 2 or more CPU cores: OpenVPN uses every core.
- Change the panel path in **Settings → General** if anyone else learns it.

---

## Made by

<p align="center">
  <b>Ali</b> (<a href="https://github.com/chaliraza777">@chaliraza777</a>) &nbsp;🤝&nbsp; <b>Claude</b> (Anthropic)
</p>

<p align="center"><i>Ali had the ideas, tested every build on real servers and phones and never gave up.<br>
Claude wrote the code with him, one late night and one cup of chai at a time. ☕❤️</i></p>

---

## License

ReXUI is free software under the **GNU General Public License v3.0**.  
You can use, study, share and change it. If you share a changed version, it must stay under GPL-3.0 with its source code public, and keep the credit to ReXUI.

© 2026 Ali ([chaliraza777](https://github.com/chaliraza777))

> Use ReXUI only where it is legal, and follow your VPS provider's terms.
