# ReXUI

**Self-hosted SSH + Xray panel with one-file installer**

SSH · SSL · SSH WebSocket · UDPGW · VLESS (XHTTP, TCP TLS, Reality) · Trojan

![version](https://img.shields.io/badge/version-1.0-1f6feb) ![license](https://img.shields.io/badge/license-GPL--3.0-16a34a) ![os](https://img.shields.io/badge/Ubuntu%20%7C%20Debian-x86__64%20%7C%20arm64-6b7385)

</div>

---

## Install

Run as **root** on a fresh Ubuntu 20.04+ or Debian 11+ VPS:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/chaliraza777/ReXUI/main/install.sh)
```

At the end you get the **panel address** and the **login**. Save them.  
Then type `menu` on the server for the terminal menu.

Running the installer again **updates ReXUI** and keeps all users and settings.

---

## Features

**Users**
- One user = SSH account + all Xray configs + one subscription link
- Data limit (GB), expiry, device limit, monthly reset day
- Expiry from first connection, trial users (1 day / 2 GB, deleted when they end)
- Clone, notes, disable with a reason, bulk actions, select many users at once
- CSV export / import, share card image (QR + details) for WhatsApp
- New subscription link or new UUID in one tap

**Protocols**
- SSH, SSH over SSL/TLS, SSH WebSocket, SSH WebSocket TLS, UDPGW (BadVPN)
- VLESS XHTTP TLS, VLESS TCP TLS, VLESS Reality (Vision), VLESS XHTTP, Trojan TLS
- Reality target and SNI per user, Reality target finder
- Routing: block torrent, ads, email port 25, Cloudflare WARP for chosen sites

**Panel**
- Dashboard with live, 1 hour and 24 hour graphs, top users, protocol usage, server traffic
- Light, dark and black (AMOLED) themes, accent colours, your own brand name
- Works great on phones, can be installed as an app (PWA)
- Search everything, logs viewer, login history, activity log, logged-in devices
- 2FA (authenticator app), captcha after wrong logins, change the secret path in one tap

**User page** (opens from the subscription link)
- Usage, expiry, 30-day graph, all configs with QR codes, SSH details and payloads
- Announcements, renew warning, app download links, change own password

**Server**
- Telegram alerts: logins, health (CPU / RAM / disk / stopped services), certificate, daily report, daily backup file
- Backup and restore, auto delete of ended users, scheduled reboot
- Speed test, port check, disk cleanup, swap file, Xray auto update with rollback
- DuckDNS updater, fake website on port 80 and on the TLS ports
- Let's Encrypt certificate (menu), BBR enabled

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
| Fake website | 80 |
| Panel | random (shown after install) |

Open these ports in your VPS provider's firewall. Ports can be changed from `menu`.

---

## Client apps

- **Android:** [v2rayNG](https://github.com/2dust/v2rayNG/releases/latest), [NekoBox](https://github.com/MatsuriDayo/NekoBoxForAndroid/releases/latest), [Hiddify](https://github.com/hiddify/hiddify-app/releases/latest)
- **iPhone / PC:** [Hiddify](https://github.com/hiddify/hiddify-app/releases/latest)
- **SSH:** any SSH / SSL / WebSocket tunnel app (HTTP Custom, HTTP Injector, NapsternetV and similar)

Add the user's **subscription link** in the app. It contains every Xray config and shows usage and expiry.

---

## Terminal menu

```
menu
```

Uninstall, panel info, panel login reset (also turns off 2FA), panel restart, port change,
service restart, SSL certificate (Let's Encrypt or your own), backup and restore,
update ReXUI, update Xray core and geo files, roll back Xray.

---

## Tips

- Point a domain to your VPS and get a Let's Encrypt certificate from `menu`. TLS configs then work without "allow insecure".
- On Cloudflare use **DNS only** (grey cloud) for the domain.
- Change the panel path in **Settings → General → Panel address** if anyone else learns it.

---

## License

ReXUI is free software under the **GNU General Public License v3.0**.  
You can use, study, share and change it. If you share a changed version, it must stay under GPL-3.0 with its source code public, and keep the credit to ReXUI.

© 2026 Ali ([chaliraza777](https://github.com/chaliraza777))

> Use ReXUI only where it is legal, and follow your VPS provider's terms.
> 
Co-Authored-By: Claude <noreply@anthropic.com>
Built by Ali with help from Claude (Anthropic).
