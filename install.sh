#!/bin/bash
# ReXUI v2.0 installer
# Self-hosted SSH + Xray panel: SSH, SSL, SSH WebSocket (+TLS), UDPGW, Xray (VLESS XHTTP TLS / TCP TLS / Reality / XHTTP, Trojan), OpenVPN (TCP + HTTP proxy), Hysteria2 (UDP), WireGuard, DNS tunnel (dnstt) + V2Ray,
# web panel with users, subscriptions, data and device limits, Telegram alerts, backups, 2FA, and a terminal menu.
# Run as root on Ubuntu or Debian:  bash install.sh   (running it again updates ReXUI and keeps users and settings)
# https://github.com/chaliraza777/ReXUI · License: GPL-3.0 · (c) 2026 Ali (chaliraza777)
set -e
trap 'echo -e "\n\033[1;31mERROR: failed at line $LINENO\033[0m"' ERR
[ "$EUID" -ne 0 ] && { echo "Please run as root"; exit 1; }
SSH_PORT_DEF=22
SSL_PORT=443; WS_PORT=8880; WSTLS_PORT=2083; UDPGW_PORT=7300; VWSTLS_PORT=8443; VTCP_PORT=2053; VWS_PORT=8080; REALITY_PORT=8444; TROJAN_PORT=2096; OVPN1_PORT=1194; OVPN2_PORT=110; SQUID_PORT=3128; HY_PORT=443; HY_HOP=20000-30000; WG_PORT=51820; HYV=2.13.0; DNSTTV=v1.20240513.0
LIB=/usr/local/lib/tunnel
step(){ echo -e "\n\033[1;36m[$1/11]\033[0m $2"; }
busy(){ if ss -tlnp | grep ":$1 " | grep -qv -e stunnel -e python3 -e xray -e squid -e openvpn -e haproxy; then echo "Port $1 is already in use:"; ss -tlnp | grep ":$1 "; exit 1; fi; }
[ -f /etc/tunnel/config ] && . /etc/tunnel/config
if [ -z "$PANEL_PORT" ]; then
  PANEL_PORT=$(shuf -i 20000-59999 -n1)
  while ss -tln | grep -q ":$PANEL_PORT "; do PANEL_PORT=$(shuf -i 20000-59999 -n1); done
fi
[ -n "$WEB_PATH" ] || WEB_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
for p in $SSL_PORT $WS_PORT $WSTLS_PORT $PANEL_PORT $OVPN1_PORT $OVPN2_PORT $SQUID_PORT; do busy $p; done
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/tunnel/cert $LIB

step 1 "Packages"
apt-get update -qq
apt-get install -y -qq openssh-server stunnel4 fail2ban cmake build-essential git openssl curl cron python3 socat unzip iptables openvpn squid >/dev/null
apt-get install -y -qq haproxy >/dev/null 2>&1 || echo -e "\033[1;33mHAProxy could not be installed, 443 mode stays off (everything else works).\033[0m"
[ -c /dev/net/tun ] || echo -e "\033[1;33mWARNING: /dev/net/tun is missing. OpenVPN needs TUN: enable it in your VPS control panel (OpenVZ / LXC) or ask your provider.\033[0m"

step 2 "SSH tuning"
mkdir -p /etc/ssh/sshd_config.d
grep -q '^Include' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/00-tunnel.conf <<S
PasswordAuthentication yes
UseDNS no
TCPKeepAlive yes
ClientAliveInterval 15
ClientAliveCountMax 2
AllowTcpForwarding yes
Compression no
S
sshd -t
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sshd -T | grep -qi '^passwordauthentication yes' || echo "WARNING: PasswordAuthentication could not be enabled, check /etc/ssh/sshd_config"
SSH_PORT=$(sshd -T | awk '/^port /{print $2; exit}'); SSH_PORT=${SSH_PORT:-$SSH_PORT_DEF}
cat > /etc/tunnel/config <<S
SSH_PORT=$SSH_PORT
SSL_PORT=$SSL_PORT
UDPGW_PORT=$UDPGW_PORT
WS_PORT=$WS_PORT
WSTLS_PORT=$WSTLS_PORT
PANEL_PORT=$PANEL_PORT
WEB_PATH=$WEB_PATH
VWSTLS_PORT=$VWSTLS_PORT
VTCP_PORT=$VTCP_PORT
VWS_PORT=$VWS_PORT
REALITY_PORT=$REALITY_PORT
TROJAN_PORT=$TROJAN_PORT
OVPN1_PORT=$OVPN1_PORT
OVPN2_PORT=$OVPN2_PORT
SQUID_PORT=$SQUID_PORT
HY_PORT=$HY_PORT
HY_HOP=$HY_HOP
WG_PORT=$WG_PORT
S

step 3 "SSL + WS TLS (stunnel4, 10-year certificate)"
[ -f /etc/stunnel/stunnel.pem ] || {
  openssl req -new -x509 -days 3650 -nodes -subj "/CN=www.google.com" -out /etc/stunnel/stunnel.pem -keyout /etc/stunnel/stunnel.pem 2>/dev/null
  chmod 600 /etc/stunnel/stunnel.pem; }
cat > /etc/stunnel/stunnel.conf <<S
pid = /var/run/stunnel4/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
sslVersionMin = TLSv1.2
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[ssh-ssl]
accept = $( [ -f /etc/tunnel/h443.on ] && [ "$SSL_PORT" = 443 ] && echo 127.0.0.1:10443 || echo $SSL_PORT )
connect = 127.0.0.1:$SSH_PORT
[ssh-ws-tls]
accept = $WSTLS_PORT
connect = 127.0.0.1:$WS_PORT
S
[ -f /etc/default/stunnel4 ] && sed -i 's/ENABLED=0/ENABLED=1/' /etc/default/stunnel4
systemctl enable stunnel4 >/dev/null 2>&1

step 4 "BadVPN UDPGW"
if [ ! -x /usr/local/bin/badvpn-udpgw ]; then
  cd /tmp && rm -rf badvpn
  git -c advice.detachedHead=false clone -q --depth 1 --branch 1.999.130 https://github.com/ambrop72/badvpn.git
  mkdir badvpn/build && cd badvpn/build
  cmake .. -Wno-dev -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 >/tmp/badvpn-build.log 2>&1 || { echo "BadVPN cmake failed, see /tmp/badvpn-build.log"; exit 1; }
  { make -j$(nproc) && make install; } >>/tmp/badvpn-build.log 2>&1 || { echo "BadVPN build failed, see /tmp/badvpn-build.log"; exit 1; }
  cd /
fi
cat > /etc/systemd/system/badudp.service <<S
[Unit]
Description=BadVPN UDPGW
After=network.target
[Service]
ExecStart=/usr/local/bin/badvpn-udpgw --listen-addr 127.0.0.1:$UDPGW_PORT --max-clients 1000 --max-connections-for-client 100
Restart=always
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
S

step 5 "SSH WS (plain) proxy"
cat > /usr/local/bin/ws-ssh.py <<'PYW'
#!/usr/bin/env python3
import asyncio,sys,socket,re,base64,hashlib,os
LP=int(sys.argv[1]); SSH=('127.0.0.1',int(sys.argv[2]))
G=b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
M=(b'GET ',b'POST ',b'HEAD ',b'PUT ',b'CONNECT ',b'OPTIONS ',b'PATCH ',b'DELETE ',b'HTTP/')
def log(*a): print(*a,flush=True)
# HAProxy (443 / 80 mode) puts a PROXY v2 header in front, so we know the user's real IP.
# Only trusted from 127.0.0.1. Each SSH connection is written to /run/rexui-ws/<local port> = real IP,
# so the panel can show the real IP of SSH users.
SIG=b'\r\n\r\n\x00\r\nQUIT\n'; MAPD='/run/rexui-ws'
async def proxyv2(r,d):
    while len(d)<16 or len(d)<16+int.from_bytes(d[14:16],'big'):
        x=await asyncio.wait_for(r.read(65536),20)
        if not x: return None,b''
        d+=x
    n=int.from_bytes(d[14:16],'big'); a=d[16:16+n]; ip=None
    if d[12]&0x0F==1:
        if d[13]>>4==1 and n>=12: ip=socket.inet_ntop(socket.AF_INET,a[:4])
        elif d[13]>>4==2 and n>=36:
            ip=socket.inet_ntop(socket.AF_INET6,a[:16])
            if ip.startswith('::ffff:'): ip=ip[7:]
    d=d[16+n:]
    if not d: d=await asyncio.wait_for(r.read(65536),20)
    return ip,d
def resp(h):
    if h.startswith(b'CONNECT'): return b'HTTP/1.1 200 Connection established\r\n\r\n'
    k=re.search(rb'(?i)sec-websocket-key:\s*(\S+)',h)
    r=b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
    if k: r+=b'Sec-WebSocket-Accept: '+base64.b64encode(hashlib.sha1(k[1]+G).digest())+b'\r\n'
    return r+b'\r\n'
def nd(w):
    s=w.get_extra_info('socket')
    if s: s.setsockopt(socket.IPPROTO_TCP,socket.TCP_NODELAY,1)
async def pipe(r,w):
    try:
        while True:
            d=await r.read(65536)
            if not d: break
            w.write(d); await w.drain()
    except Exception: pass
    finally: w.close()
async def up(r,w,sw,d):
    hdr=True
    try:
        while True:
            while hdr and d.startswith(M):
                while b'\r\n\r\n' not in d:
                    x=await asyncio.wait_for(r.read(65536),20)
                    if not x: return
                    d+=x
                b,d=d.split(b'\r\n\r\n',1); w.write(resp(b)); await w.drain()
            if d: hdr=False; sw.write(d); await sw.drain()
            d=await r.read(65536)
            if not d: break
    except Exception: pass
    finally: sw.close()
async def h(r,w):
    p=w.get_extra_info('peername'); real=p[0] if p else None; mf=None
    try:
        nd(w)
        d=await asyncio.wait_for(r.read(65536),20)
        if not d: return w.close()
        if real in ('127.0.0.1','::1','::ffff:127.0.0.1') and d.startswith(SIG[:len(d)] if len(d)<12 else SIG):
            ip,d=await proxyv2(r,d)
            if ip: real=ip; p=(ip,p[1])
            if not d: return w.close()
        log(p,'payload',repr(d[:150]))
        if d.startswith(M):
            while b'\r\n\r\n' not in d:
                x=await asyncio.wait_for(r.read(65536),20)
                if not x: return w.close()
                d+=x
            b,d=d.split(b'\r\n\r\n',1); w.write(resp(b)); await w.drain()
        sr,sw=await asyncio.open_connection(*SSH); nd(sw)
        if real and real not in ('127.0.0.1','::1'):
            try:
                mf=MAPD+'/%d'%sw.get_extra_info('sockname')[1]
                with open(mf,'w') as f: f.write(real)
            except OSError: mf=None
        await asyncio.gather(up(r,w,sw,d),pipe(sr,w))
    except Exception as e: log(p,'error',repr(e)); w.close()
    finally:
        if mf:
            try: os.remove(mf)
            except OSError: pass
async def main():
    s=await asyncio.start_server(h,'0.0.0.0',LP)
    async with s: await s.serve_forever()
asyncio.run(main())
PYW
chmod +x /usr/local/bin/ws-ssh.py
cat > /etc/systemd/system/ws-ssh.service <<S
[Unit]
Description=SSH WebSocket proxy
After=network.target
[Service]
User=nobody
RuntimeDirectory=rexui-ws
RuntimeDirectoryMode=0755
ExecStart=/usr/bin/python3 /usr/local/bin/ws-ssh.py $WS_PORT $SSH_PORT
Restart=always
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
S

step 6 "BBR + FQ"
modprobe tcp_bbr || echo "WARNING: BBR could not be loaded on this kernel"
echo tcp_bbr > /etc/modules-load.d/bbr.conf
cat > /etc/sysctl.d/99-speed.conf <<S
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_mtu_probing=1
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.tcp_notsent_lowat=16384
net.core.somaxconn=65535
net.core.netdev_max_backlog=16384
fs.file-max=1048576
S
# many users: bigger connection-tracking table (OpenVPN NAT), forget dead connections sooner
modprobe nf_conntrack 2>/dev/null || true
mkdir -p /etc/modules-load.d /etc/modprobe.d /etc/sysctl.d
echo nf_conntrack > /etc/modules-load.d/rexui-conntrack.conf
echo "options nf_conntrack hashsize=65536" > /etc/modprobe.d/rexui-conntrack.conf
[ -w /sys/module/nf_conntrack/parameters/hashsize ] && echo 65536 > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
cat > /etc/sysctl.d/99-rexui-conntrack.conf <<S
net.netfilter.nf_conntrack_max=262144
net.netfilter.nf_conntrack_tcp_timeout_established=7200
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=120
S
# keep system logs small
mkdir -p /etc/systemd/journald.conf.d
printf '[Journal]\nSystemMaxUse=200M\nRuntimeMaxUse=100M\n' > /etc/systemd/journald.conf.d/rexui.conf
systemctl restart systemd-journald 2>/dev/null || true
sysctl --system >/dev/null 2>&1 || echo "WARNING: some sysctl settings were not applied"

step 7 "Fail2ban"
cat > /etc/fail2ban/jail.local <<S
[sshd]
enabled = true
port = $SSH_PORT
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
S
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

step 8 "Xray core"
if [ ! -x /usr/local/bin/xray ] || [ ! -f /usr/local/bin/geosite.dat ]; then
  case $(uname -m) in x86_64|amd64) XA=64;; aarch64|arm64) XA=arm64-v8a;; *) echo "This CPU ($(uname -m)) is not supported"; exit 1;; esac
  rm -rf /tmp/xr && mkdir /tmp/xr
  curl -fsSL -o /tmp/xr/x.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XA.zip"
  curl -fsSL -o /tmp/xr/x.dgst "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$XA.zip.dgst" || true
  XS=$(grep -ioE '^SHA(2-)?256[^=]*= *[0-9a-f]{64}' /tmp/xr/x.dgst 2>/dev/null | grep -ioE '[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
  if [ -z "$XS" ] || [ "$(sha256sum /tmp/xr/x.zip | awk '{print $1}')" != "$XS" ]; then echo "Xray download check failed (checksum did not match). Stopping, nothing was installed. Run the installer again."; exit 1; fi
  echo "Xray checksum OK"
  unzip -qo /tmp/xr/x.zip xray geoip.dat geosite.dat -d /tmp/xr && install -m 755 /tmp/xr/xray /usr/local/bin/xray
  install -m 644 /tmp/xr/geoip.dat /tmp/xr/geosite.dat /usr/local/bin/ && rm -rf /tmp/xr
fi
/usr/local/bin/xray version | head -1
mkdir -p /usr/local/etc/xray /var/log/xray
touch /var/log/xray/access.log
# Xray gets its own user, so no other service can read its keys
id rexui-xray >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin rexui-xray
systemctl stop xray 2>/dev/null || true; rm -f /dev/shm/rexui-*.sock
chown -R rexui-xray:rexui-xray /var/log/xray; chmod 750 /var/log/xray; chmod 640 /var/log/xray/access.log
for f in /usr/local/etc/xray/config.json /usr/local/etc/xray/cert.crt /usr/local/etc/xray/key.key; do [ -f $f ] && chown root:rexui-xray $f && chmod 640 $f; done
[ -f /etc/tunnel/xray-self.crt ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=rexui" \
  -keyout /etc/tunnel/xray-self.key -out /etc/tunnel/xray-self.crt 2>/dev/null
chmod 600 /etc/tunnel/xray-self.key
cat > /etc/systemd/system/xray.service <<S
[Unit]
Description=Xray (ReXUI)
After=network.target
[Service]
User=rexui-xray
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -c /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
S

echo "Hysteria2 v$HYV (UDP)"
case $(uname -m) in x86_64) HA=amd64;; aarch64|arm64) HA=arm64;; *) HA=;; esac
if [ -z "$HA" ]; then echo "WARNING: Hysteria2 is not available for $(uname -m), UDP users will not work"
elif /usr/local/bin/hysteria version 2>/dev/null | grep -q "v$HYV"; then echo "Hysteria2 is up to date"
else
  HT=$(mktemp -d); HU="https://github.com/apernet/hysteria/releases/download/app/v$HYV"
  if curl -fsSL --max-time 180 -o $HT/hy "$HU/hysteria-linux-$HA" && curl -fsSL --max-time 60 -o $HT/hashes.txt "$HU/hashes.txt"; then
    HW=$(grep -E "[ /*]hysteria-linux-$HA\$" $HT/hashes.txt | awk '{print $1}' | head -1); HG=$(sha256sum $HT/hy | awk '{print $1}')
    if [ -n "$HW" ] && [ "$HW" = "$HG" ]; then install -m 755 $HT/hy /usr/local/bin/hysteria; echo "Hysteria2 installed (checksum OK)"
    else echo "WARNING: Hysteria2 checksum did not match, it was NOT installed"; fi
  else echo "WARNING: Hysteria2 download failed, UDP users will not work until you run the installer again"; fi
  rm -rf $HT
fi

# TUIC was tried in v1.6 builds and removed: clean up an old install
if [ -f /etc/systemd/system/rexui-tuic.service ] || [ -x /usr/local/bin/tuic-server ]; then
  systemctl disable --now rexui-tuic >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/rexui-tuic.service /usr/local/bin/tuic-server; rm -rf /etc/tunnel/tuic
  sed -i '/^TUIC_PORT=/d' /etc/tunnel/config 2>/dev/null || true
  echo "Old TUIC removed"
fi

echo "WireGuard"
apt-get install -y -qq wireguard-tools >/dev/null 2>&1 || echo "WARNING: wireguard-tools could not be installed, WireGuard users will not work"
modprobe wireguard 2>/dev/null || true
if command -v wg >/dev/null && ! { ip link add rxwg-test type wireguard 2>/dev/null && ip link del rxwg-test; }; then
  ip link show rxwg >/dev/null 2>&1 || echo -e "\033[1;33mWARNING: this server's kernel has no WireGuard (common on OpenVZ / LXC). WireGuard users will not work here.\033[0m"
fi

echo "DNS tunnel (dnstt $DNSTTV)"
if [ -x /usr/local/bin/dnstt-server ]; then echo "DNS tunnel is installed"
else
  case $(uname -m) in x86_64) GA=amd64;; aarch64|arm64) GA=arm64;; *) GA=;; esac
  GT=$(mktemp -d)
  GF=$( [ -n "$GA" ] && curl -fsSL --max-time 60 "https://go.dev/dl/?mode=json" 2>/dev/null | python3 -c "
import json,sys
for r in json.load(sys.stdin):
    for f in r['files']:
        if f['os']=='linux' and f['arch']=='$GA' and f['kind']=='archive': print(f['filename'],f['sha256']); sys.exit()" 2>/dev/null || true)
  if [ -n "$GF" ] && echo "Building the DNS tunnel from source (1-3 minutes)..." && curl -fsSL --max-time 600 -o $GT/go.tgz "https://go.dev/dl/${GF% *}" && [ "$(sha256sum $GT/go.tgz | awk '{print $1}')" = "${GF#* }" ]; then
    tar -C $GT -xzf $GT/go.tgz
    if GOPATH=$GT/gp GOCACHE=$GT/gc GOBIN=/usr/local/bin GOTOOLCHAIN=local $GT/go/bin/go install "www.bamsoftware.com/git/dnstt.git/dnstt-server@$DNSTTV" >/dev/null 2>&1; then echo "DNS tunnel installed"
    else echo "WARNING: the DNS tunnel could not be built, DNS users will not work until you run the installer again"; fi
  else echo "WARNING: Go could not be downloaded or checked, the DNS tunnel was not installed"; fi
  rm -rf $GT
fi

step 9 "Web panel"
mkdir -p /opt/tunnel-panel
cat > /opt/tunnel-panel/panel.py <<'PANELPY'
#!/usr/bin/env python3
# ReXUI panel: one user = SSH + Xray (VLESS), subscription, GB limit, device limit, monthly reset, online/kick, backup/restore
import os,sys,re,json,time,hmac,hashlib,secrets,ssl,shutil,socket,subprocess as sp,threading,datetime,pwd,platform,uuid,base64,html,http.server,urllib.request
from urllib.parse import quote,unquote,parse_qs
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
T='/etc/tunnel'; CONF=T+'/config'; LOGIN=T+'/panel.json'; UDB=T+'/users.json'; SETF=T+'/settings.json'; OLDDB='/etc/tunnel-users'
CD=T+'/cert'; SELF=T+'/panel.pem'; XSC,XSK=T+'/xray-self.crt',T+'/xray-self.key'; HTML='/opt/tunnel-panel/index.html'
UHTML='/opt/tunnel-panel/user.html'; QRJS='/opt/tunnel-panel/qr.js'; WARPF=T+'/warp.json'
XD='/usr/local/etc/xray'; XBIN='/usr/local/bin/xray'; XAPI='127.0.0.1:10085'; GB=1073741824
XLOGD='/var/log/xray'; XLOG=XLOGD+'/access.log'; BKD=T+'/backups'
START=time.time()
def rd(p,d=''):
    try:
        with open(p) as f: return f.read()
    except OSError: return d
def env():
    e={}
    for l in rd(CONF).splitlines():
        l=l.strip()
        if '=' in l and not l.startswith('#'): k,v=l.split('=',1); e[k]=v
    return e
E=env()
def P(k,d):
    try: return int(E.get(k,d))
    except ValueError: return d
def run(*a,inp=None,t=40):
    try: return sp.run(list(a),input=inp,capture_output=True,text=True,timeout=t)
    except Exception as x: return sp.CompletedProcess(a,1,'',str(x))
def log(*a): print(*a,flush=True)
class Err(Exception): pass
def today(): return datetime.date.today().isoformat()
def wjson(path,obj,mode=0o600):
    tmp=path+'.tmp'
    with open(tmp,'w') as f: json.dump(obj,f,indent=1)
    os.chmod(tmp,mode); os.replace(tmp,path)

# ---------- login ----------
def hp(p,s): return hashlib.pbkdf2_hmac('sha256',p.encode(),bytes.fromhex(s),200000).hex()
def lread():
    try: return json.loads(rd(LOGIN))
    except Exception: return {}
def setlogin(u,p,keep2fa=False):
    if not u or len(u)>128 or re.search(r'[\x00-\x1f\x7f]',u): raise Err('Username cannot be empty')
    if not p or len(p)>256 or re.search(r'[\x00-\x1f\x7f]',p): raise Err('Password cannot be empty')
    old=lread(); s=secrets.token_hex(16); n={'user':u,'salt':s,'hash':hp(p,s)}
    if keep2fa and old.get('totp'): n['totp'],n['tlast']=old['totp'],old.get('tlast',0)
    wjson(LOGIN,n)
def totp_at(sec,c):
    k=base64.b32decode(sec+'='*(-len(sec)%8)); h=hmac.new(k,c.to_bytes(8,'big'),hashlib.sha1).digest(); o=h[-1]&15
    return '%06d'%((int.from_bytes(h[o:o+4],'big')&0x7fffffff)%1000000)
def totp_check(sec,code,last=0):
    code=re.sub(r'\s','',str(code or ''))
    if not re.fullmatch(r'\d{6}',code) or not sec: return 0
    now=int(time.time()//30)
    for c in (now-1,now,now+1):
        if c>last and hmac.compare_digest(totp_at(sec,c),code): return c
    return 0
TFA_PEND={}
def tfa_setup(tok):
    sec=base64.b32encode(secrets.token_bytes(20)).decode().rstrip('='); TFA_PEND[tok]=sec
    return {'secret':sec,'uri':'otpauth://totp/ReXUI:%s?secret=%s&issuer=ReXUI&digits=6&period=30'%(quote(curuser()),sec)}
def tfa_enable(tok,code):
    sec=TFA_PEND.get(tok); c=totp_check(sec,code)
    if not c: raise Err('Wrong code. Check the time on your phone and try again.')
    l=lread(); l['totp'],l['tlast']=sec,c; wjson(LOGIN,l); TFA_PEND.pop(tok,None); return {'ok':1}
def tfa_disable(code):
    l=lread()
    if not l.get('totp'): return {'ok':1}
    if not totp_check(l['totp'],code,l.get('tlast',0)): raise Err('Wrong code')
    l.pop('totp',None); l.pop('tlast',None); wjson(LOGIN,l); return {'ok':1}
def checklogin(u,p):
    try: c=json.loads(rd(LOGIN))
    except Exception: return False
    a=hmac.compare_digest(u.encode(),c['user'].encode()); b=hmac.compare_digest(hp(p,c['salt']).encode(),c['hash'].encode())
    return a and b
def curuser():
    try: return json.loads(rd(LOGIN))['user']
    except Exception: return ''

# ---------- settings ----------
def sload():
    s={'addr':'','sni':'','host':'','path':'/vless','wspath':'/vws','rsni':'www.microsoft.com','rpriv':'','rpub':'','rsid':'',
       'btorrent':True,'bads':False,'warp':'off','wsites':'geosite:google,geosite:openai,geosite:netflix',
       'b25':True,'autodel':0,'tgtoken':'','tgchat':'','brand':'','tagline':'','accent':'teal',
       'health':True,'report':False,'rhour':9,'tgbackup':False,'reboot':'off','rbday':0,'rbtime':'04:00','announce':'','cname':'{user}-{proto}','flag':'','autoclean':True,'rports':{},'fsite':'off','ftitle':'','xauto':False,'ddns_dom':'','ddns_tok':'','ovhost':'','dns_ns':'','hy_bw':0,'cdn_dom':'','cdn_addr':'','perf':'balanced','h443':True,
       'tgshare':False,'jsub':True,'jfrag':True,'jpk':'tlshello','jlen':'100-200','jint':'10-20','jnoise':False}
    try: s.update({k:v for k,v in json.loads(rd(SETF)).items() if k in s})
    except Exception: pass
    return s
HOSTRE=re.compile(r'(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)*[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?|\d{1,3}(?:\.\d{1,3}){3}')
def hostok(v,what):
    v=str(v or '').strip().lower()
    if v and (len(v)>253 or not HOSTRE.fullmatch(v)): raise Err(what+' is not valid (use a domain or IP)')
    return v
def ssave(d):
    old=rd(SETF); ssave_raw(d)
    e=xray_apply()
    if e:
        with open(SETF,'w') as f: f.write(old)
        xray_apply(); raise Err(e)
    return {'ok':1}
SITERE=re.compile(r'(geosite:[a-z0-9!@._-]+|geoip:[a-z0-9!-]+|domain:[a-z0-9.-]+|full:[a-z0-9.-]+|[a-z0-9-]+(\.[a-z0-9-]+)+)')
def routing_save(d):
    s=sload(); s['btorrent']=bool(d.get('btorrent')); s['bads']=bool(d.get('bads')); s['b25']=bool(d.get('b25',True))
    w=str(d.get('warp','off'))
    if w not in ('off','sites','all'): raise Err('Invalid WARP mode')
    sites=[x.strip().lower() for x in re.split(r'[,\s]+',str(d.get('wsites',''))) if x.strip()]
    for x in sites:
        if not SITERE.fullmatch(x): raise Err(x+' is not valid. Use geosite:name, domain:example.com or example.com')
    if w=='sites' and not sites: raise Err('Add at least one site for WARP')
    if w!='off' and not os.path.exists(WARPF): warp_register()
    old=rd(SETF); s['warp']=w; s['wsites']=','.join(sites); wjson(SETF,s,0o600); smtp_apply()
    e=xray_apply()
    if e:
        with open(SETF,'w') as f: f.write(old)
        xray_apply(); raise Err(e)
    return {'ok':1}
def tls13(host,port=443,sni=None):
    try:
        c=ssl.create_default_context(); c.minimum_version=ssl.TLSVersion.TLSv1_3
        if sni and sni!=host: c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
        with socket.create_connection((host,port),timeout=6) as k:
            with c.wrap_socket(k,server_hostname=sni or host): return True
    except Exception: return False
RPL=threading.Lock()
def rtarget_val(v,old=''):
    t=str(v or '').strip().lower()
    if not t: return ''
    m=re.fullmatch(r'([a-z0-9-]+(?:\.[a-z0-9-]+)+)(?::(\d{1,5}))?',t)
    if not m or re.fullmatch(r'[\d.]+',m[1]): raise Err('Reality target must be a website like www.microsoft.com:443')
    pt=int(m[2] or 443)
    if not 1<=pt<=65535: raise Err('Reality target port must be 1-65535')
    t='%s:%d'%(m[1],pt)
    if t!=old and not tls13(m[1],pt): raise Err('%s did not answer with TLS 1.3. Pick another site for Reality.'%t)
    return t
def rsni_val(v):
    t=hostok(v,'Reality SNI')
    if t and re.fullmatch(r'[\d.]+',t): raise Err('Reality SNI must be a domain name')
    return t
def ureal(u,s):
    t=u.get('rtarget') or s['rsni']+':443'; return t,(u.get('rsni') or t.rsplit(':',1)[0])
def rport(t,s=None):
    s=s or sload(); dt=s['rsni']+':443'
    if t==dt: return P('REALITY_PORT',8444)
    with RPL:
        s=sload(); m=s.get('rports') or {}
        if t in m: return m[t]
        used={int(v) for k,v in E.items() if k.endswith('_PORT') and str(v).isdigit()}|{P('REALITY_PORT',8444),P('TROJAN_PORT',2096)}|set(m.values())|{x['port'] for x in ib_load()}
        lis=run('ss','-Hltn').stdout
        p=P('REALITY_PORT',8444)+1
        while p in used or re.search(r':%d\s'%p,lis): p+=1
        m[t]=p; s['rports']=m; wjson(SETF,s,0o600)
    if run('sh','-c','command -v ufw >/dev/null && ufw status | grep -q "Status: active"').returncode==0: run('ufw','allow','%d/tcp'%p)
    log('reality: target %s uses port %d'%(t,p)); return p
def ssave_raw(d,check=True,keys=False):
    s=sload()
    s['addr']=hostok(d.get('addr'),'Address'); s['sni']=hostok(d.get('sni'),'SNI'); s['host']=hostok(d.get('host'),'Host')
    p=str(d.get('path') or '/vless').strip()
    if not re.fullmatch(r'/[A-Za-z0-9._~/-]{0,60}',p): raise Err('XHTTP path must start with / (letters, numbers, - _ . /)')
    r=hostok(d.get('rsni') or 'www.microsoft.com','Reality SNI')
    if re.fullmatch(r'[\d.]+',r): raise Err('Reality SNI must be a domain name')
    if check and r!=s['rsni'] and not tls13(r): raise Err(r+' did not answer with TLS 1.3 on port 443. Pick another site for Reality.')
    if keys and re.fullmatch(r'[A-Za-z0-9_-]{43}',str(d.get('rpriv',''))) and re.fullmatch(r'[A-Za-z0-9_-]{43}',str(d.get('rpub',''))) and re.fullmatch(r'[0-9a-f]{0,16}',str(d.get('rsid',''))):
        s['rpriv'],s['rpub'],s['rsid']=d['rpriv'],d['rpub'],d['rsid']
    if keys:
        for k in ('btorrent','bads'):
            if isinstance(d.get(k),bool): s[k]=d[k]
        if d.get('warp') in ('off','sites') : s['warp']=d['warp'] if d['warp']=='off' or os.path.exists(WARPF) else 'off'
        if isinstance(d.get('wsites'),str) and all(SITERE.fullmatch(x) for x in d['wsites'].split(',') if x): s['wsites']=d['wsites']
        if isinstance(d.get('b25'),bool): s['b25']=d['b25']
        if isinstance(d.get('autodel'),int) and 0<=d['autodel']<=3650: s['autodel']=d['autodel']
        if re.fullmatch(r'\d{6,12}:[A-Za-z0-9_-]{20,80}',str(d.get('tgtoken',''))) and re.fullmatch(r'-?\d{3,20}',str(d.get('tgchat',''))):
            s['tgtoken'],s['tgchat']=d['tgtoken'],str(d['tgchat'])
        try: s['brand']=textval(d.get('brand'),24,'b'); s['tagline']=textval(d.get('tagline'),80,'t')
        except Err: pass
        if d.get('accent') in ACCENTS: s['accent']=d['accent']
        for k in ('health','report','tgbackup'):
            if isinstance(d.get(k),bool): s[k]=d[k]
        if isinstance(d.get('rhour'),int) and 0<=d['rhour']<=23: s['rhour']=d['rhour']
        try: subpage_save(d); s.update({k:sload()[k] for k in ('announce','cname','flag')})
        except Err: pass
    s['path'],s['rsni']=p,r; wjson(SETF,s,0o600)
def reality_keys(new=False):
    s=sload()
    if s['rpriv'] and s['rpub'] and not new: return s
    r=run(XBIN,'x25519',t=10); pv=re.search(r'PrivateKey:\s*(\S+)',r.stdout); pb=re.search(r'(?:Password|Public\s*key)[^:\n]*:\s*(\S+)',r.stdout,re.I)
    if not (pv and pb): log('reality: key generation failed:',r.stdout[-200:]); return s
    s['rpriv'],s['rpub'],s['rsid']=pv[1],pb[1],secrets.token_hex(8); wjson(SETF,s,0o600); return s
WARPAPI='https://api.cloudflareclient.com/v0a2158/reg'
def warp_register():
    import urllib.request
    k=run(XBIN,'wg',t=10).stdout; pv=re.search(r'PrivateKey:\s*(\S+)',k); pb=re.search(r'(?:Password|Public\s*key)[^:\n]*:\s*(\S+)',k,re.I)
    if not (pv and pb): raise Err('Could not create WireGuard keys')
    body=json.dumps({'key':pb[1],'install_id':'','fcm_token':'','tos':datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None).strftime('%Y-%m-%dT%H:%M:%S.000Z'),'model':'PC','serial_number':'','locale':'en_US'}).encode()
    rq=urllib.request.Request(WARPAPI,data=body,method='POST',headers={'User-Agent':'okhttp/3.12.1','CF-Client-Version':'a-6.10-2158','Content-Type':'application/json'})
    try:
        with urllib.request.urlopen(rq,timeout=20) as r: j=json.loads(r.read().decode())
    except Exception as e: raise Err('Could not register with Cloudflare WARP (%s). Your VPS may be blocked by WARP, try again later.'%str(e)[:80])
    try:
        cf=j['config']; peer=cf['peers'][0]; a=cf['interface']['addresses']
        res=list(base64.b64decode(cf.get('client_id','') or 'AAAA'))[:3]
        w={'priv':pv[1],'peer':peer['public_key'],'v4':a['v4'],'v6':a.get('v6',''),'reserved':res,
           'endpoint':(peer.get('endpoint') or {}).get('host') or 'engage.cloudflareclient.com:2408','id':j.get('id',''),'date':today()}
    except Exception: raise Err('Cloudflare WARP sent an unexpected answer, try again later')
    wjson(WARPF,w); log('warp registered:',w['v4']); return w
def warp_info():
    try: w=json.loads(rd(WARPF)); return {'on':True,'v4':w.get('v4',''),'v6':w.get('v6',''),'date':w.get('date','')}
    except Exception: return {'on':False}
def warp_reset():
    try: os.remove(WARPF)
    except OSError: pass
    s=sload(); s['warp']='off'; wjson(SETF,s,0o600); xray_apply(); return {'ok':1}
# ---------- port 25, telegram, automation ----------
def smtp_apply():
    on=sload()['b25']
    if not shutil.which('iptables'): return
    for f in FAM:
        run(f,'-w','-N','REXUI_SMTP'); run(f,'-w','-F','REXUI_SMTP')
        if run(f,'-w','-C','OUTPUT','-j','REXUI_SMTP').returncode: run(f,'-w','-I','OUTPUT','1','-j','REXUI_SMTP')
        if on: run(f,'-w','-A','REXUI_SMTP','-p','tcp','--dport','25','-j','REJECT','--reject-with','tcp-reset')
TGAPI=os.environ.get('REXUI_TGAPI','https://api.telegram.org/bot%s/%s')
def tg_call(tok,method,data=None):
    import urllib.request,urllib.parse
    rq=urllib.request.Request(TGAPI%(tok,method),data=urllib.parse.urlencode(data).encode() if data else None)
    with urllib.request.urlopen(rq,timeout=15) as r: return json.loads(r.read().decode())
def tg_send(text,s=None):
    s=s or sload()
    if not (s['tgtoken'] and s['tgchat']): return
    def go():
        try: tg_call(s['tgtoken'],'sendMessage',{'chat_id':s['tgchat'],'text':text,'disable_web_page_preview':'true'})
        except Exception as e: log('telegram:',str(e)[:120])
    threading.Thread(target=go,daemon=True).start()
def tok_from(d,s):
    t=str(d.get('tgtoken','')).strip()
    return s['tgtoken'] if t in ('',mask(s['tgtoken'])) else t
def mask(t): return ('•'*8+t[-4:]) if t else ''
def automation_save(d):
    s=sload(); s['autodel']=ival(d,'autodel',0,3650,0)
    t=tok_from(d,s); c=str(d.get('tgchat','')).strip()
    if t and not re.fullmatch(r'\d{6,12}:[A-Za-z0-9_-]{20,80}',t): raise Err('This does not look like a Telegram bot token')
    if c and not re.fullmatch(r'-?\d{3,20}',c): raise Err('Chat ID must be a number')
    s['tgtoken'],s['tgchat']=t,c
    s['health'],s['report'],s['tgbackup']=bool(d.get('health',s['health'])),bool(d.get('report',s['report'])),bool(d.get('tgbackup',s['tgbackup']))
    s['tgshare']=bool(d.get('tgshare',s.get('tgshare',False)))
    s['rhour']=ival(d,'rhour',0,23,s['rhour']); wjson(SETF,s,0o600); return {'ok':1}
ACCENTS=('blue','teal','green','purple','pink','orange','indigo')
def textval(v,n,what):
    t=re.sub(r'[\x00-\x1f\x7f<>]','',str(v or '')).strip()
    if len(t)>n: raise Err('%s is too long (max %d characters)'%(what,n))
    return t
def appearance_save(d):
    s=sload(); s['brand']=textval(d.get('brand'),24,'Brand name'); s['tagline']=textval(d.get('tagline'),80,'Tagline')
    a=str(d.get('accent','teal'))
    if a not in ACCENTS: raise Err('Unknown colour')
    s['accent']=a; wjson(SETF,s,0o600); return {'ok':1}
def brand():
    s=sload(); return {'brand':s['brand'],'tagline':s['tagline'],'accent':s['accent']}
def tg_findchat(d):
    s=sload(); t=tok_from(d,s)
    if not t: raise Err('Enter the bot token first')
    try: j=tg_call(t,'getUpdates')
    except Exception as e: raise Err('Telegram did not answer: '+str(e)[:80])
    ch=[u.get('message',{}).get('chat',{}).get('id') for u in j.get('result',[]) if u.get('message')]
    ch=[c for c in ch if c]
    if not ch: raise Err('No message found. Open your bot in Telegram, send /start, then try again.')
    return {'chat':str(ch[-1])}
def tg_test(d):
    s=sload(); t=tok_from(d,s); c=str(d.get('tgchat','')).strip() or s['tgchat']
    if not (t and c): raise Err('Enter the bot token and chat ID first')
    try: j=tg_call(t,'sendMessage',{'chat_id':c,'text':'ReXUI test message: login alerts are working on '+socket.gethostname()})
    except Exception as e: raise Err('Telegram did not answer: '+str(e)[:80])
    if not j.get('ok'): raise Err('Telegram refused the message')
    return {'ok':1}
def auto_delete():
    n=int(sload().get('autodel') or 0)
    if n<=0: return
    cut=(datetime.date.today()-datetime.timedelta(days=n)).isoformat(); gone=[]
    with UL:
        us=uload()
        for u in us:
            if u['exp']!='never' and u['exp']<cut:
                rmuser(u['name']); gone.append(u['name'])
        if gone: usave([u for u in us if u['name'] not in gone])
    if gone:
        log('auto delete:',gone); xray_apply(); tg_send('ReXUI: deleted %d expired user(s): %s'%(len(gone),', '.join(gone)))
def bulk(d):
    a=str(d.get('action','')); sc=str(d.get('scope','active')); names=d.get('names'); bk=d.get('kind')
    if a not in ('days','reset','disable','enable','delete','dev') or sc not in ('active','all'): raise Err('bad request')
    if names is not None:
        if not isinstance(names,list) or not names or len(names)>5000: raise Err('Select at least one user')
        names={str(x) for x in names}
    elif a not in ('days','reset','dev'): raise Err('bad request')
    days=ival(d,'days',1,3650,1) if a=='days' else 0; dv=ival(d,'dev',0,100,2) if a=='dev' else 0; why=textval(d.get('reason'),200,'Reason') if a=='disable' else ''; n=0; gone=[]
    with UL:
        us=uload()
        for u in us:
            if names is not None:
                if u['name'] not in names: continue
            elif sc=='active' and ustate(u)!='active': continue
            if names is None and bk in ('v2ray','ssh') and kind(u) not in (bk,'both'): continue
            if names is None and bk in ('ovpn','hy2','dns','wg') and kind(u)!=bk: continue
            if a=='days':
                if u['exp']=='never' and not u.get('fdays'): continue
                add_days(u,days)
            elif a=='reset': u['up']=u['down']=0
            elif a=='dev': u['dev']=dv
            elif a=='disable': u['en']=False; u['reason']=why
            elif a=='enable': u['en']=True; u['reason']=''
            elif a=='delete': rmuser(u['name']); gone.append(u['name'])
            n+=1
        usave([u for u in us if u['name'] not in gone])
    enforce(); xray_apply(); ssh_rules(True); return {'ok':1,'count':n}
def geo_ok(): return os.path.exists(os.path.join(os.path.dirname(XBIN),'geosite.dat'))
def new_reality():
    reality_keys(True); xray_apply(); return {'ok':1}

# ---------- certificate ----------
def certinfo():
    c=CD+'/xray.crt'
    if not os.path.exists(c): return {'src':'self-signed','name':'','exp':'','domain':''}
    i=dict(l.split('=',1) for l in rd(CD+'/info').splitlines() if '=' in l)
    e=run('openssl','x509','-in',c,'-noout','-enddate').stdout.strip().split('=',1)[-1]
    n=i.get('NAME','').strip()
    try: days=(datetime.datetime.strptime(e,'%b %d %H:%M:%S %Y %Z')-datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)).days
    except ValueError: days=None
    return {'src':i.get('SOURCE','?'),'name':n,'exp':e,'days':days,'domain':n if re.search('[a-z]',n) and not n.startswith('*') else ''}
def setcert(d):
    write_cert(str(d.get('crt','')),str(d.get('key','')))
    run('systemd-run','--quiet','--on-active=3','/bin/systemctl','restart','tunnel-panel')
    return {'ok':1,'cert':certinfo()}
def write_cert(crt,key,info=None):
    crt=crt.replace('\r','').strip(); key=key.replace('\r','').strip()
    if 'BEGIN CERTIFICATE' not in crt or 'PRIVATE KEY' not in key: raise Err('Certificate or key format is wrong (PEM required)')
    os.makedirs(CD,exist_ok=True); tc,tk=CD+'/.new.crt',CD+'/.new.key'; old=os.umask(0o077)
    try:
        with open(tc,'w') as f: f.write(crt+'\n')
        with open(tk,'w') as f: f.write(key+'\n')
        a=run('openssl','x509','-in',tc,'-noout','-pubkey'); b=run('openssl','pkey','-in',tk,'-pubout')
        if a.returncode: raise Err('Certificate is not valid')
        if b.returncode: raise Err('Private key is not valid')
        if a.stdout.strip()!=b.stdout.strip(): raise Err('Certificate and key do not match')
        try: ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(tc,tk)
        except Exception: raise Err('This certificate could not be loaded')
        os.replace(tc,CD+'/xray.crt'); os.replace(tk,CD+'/xray.key')
    finally:
        os.umask(old)
        for f in (tc,tk):
            try: os.remove(f)
            except OSError: pass
    m=re.search(r'CN\s*=\s*([^,/\n]+)',run('openssl','x509','-in',CD+'/xray.crt','-noout','-subject').stdout)
    with open(CD+'/info','w') as f: f.write(info if info else 'SOURCE=custom\nNAME=%s\n'%(m[1].strip() if m else 'custom'))

# ---------- users (SSH + Xray) ----------
UL=threading.RLock(); NAME=re.compile(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}')
def uload():
    try: return json.loads(rd(UDB)) or []
    except Exception: return []
def usave(us):
    tmp=UDB+'.tmp'
    with open(tmp,'w') as f: json.dump(us,f,separators=(',',':'))
    os.chmod(tmp,0o600); os.replace(tmp,UDB)
KINDS=('v2ray','ssh','both','ovpn','hy2','dns','wg')
def kind(u): return u.get('kind') or 'both'
def hasx(u): return kind(u) in ('v2ray','both')
def hassh(u): return kind(u) in ('ssh','both')
def kindval(v):
    k=str(v or 'both')
    if k not in KINDS: raise Err('Unknown user type')
    return k
def newu(n,pw,e,lim=0.0,sni='',host='',dev=2,rday=0):
    return {'name':n,'pw':pw,'uuid':str(uuid.uuid4()),'exp':e,'lim':lim,'up':0,'down':0,'sni':sni,'host':host,
            'en':True,'lk':False,'sub':secrets.token_hex(16),'created':today(),'dev':dev,'rday':rday,'lreset':today()[:7],'note':'','hist':{},'trial':False,'expts':0,'fdays':0,'reason':'','rtarget':'','rsni':'','kind':'both','ovs':''}
def noteval(d):
    t=re.sub(r'[\x00-\x09\x0b-\x1f\x7f]','',str(d.get('note','') or '')).strip()
    if len(t)>500: raise Err('Note is too long (max 500 characters)')
    return t
def migrate():
    if os.path.exists(UDB): return
    us=[]
    for l in rd(OLDDB).splitlines():
        if ':' in l:
            u,e=l.strip().split(':',1)
            if u and NAME.fullmatch(u): us.append(newu(u,'',e or 'never'))
    usave(us)
def upgrade():
    """Bring data from older ReXUI versions to the current format (runs at every start, does nothing when already done)."""
    try:
        L=ib_load()
        if os.path.exists(IBF): ib_save(L)              # old inbounds get the new fields (flow, sniffing, cert, ...)
        ib_freeze(L)                                     # old V2Ray users ("all inbounds") get a real list, so Edit shows and changes it
    except Exception as e: print('upgrade:',e,flush=True)
def ustate(u,t=None):
    if not u.get('en',True): return 'disabled'
    if u.get('expts') and time.time()>u['expts']: return 'expired'
    if u['exp']!='never' and u['exp']<(t or today()): return 'expired'
    if u.get('lim') and u['up']+u['down']>=u['lim']*GB: return 'limit'
    return 'active'
def setexp(n,e):
    run('chage','-E','-1' if e=='never' else (datetime.date.fromisoformat(e)+datetime.timedelta(days=1)).isoformat(),n)
def ival(d,k,lo,hi,default=None):
    v=str(d.get(k,'')).strip()
    if v=='' and default is not None: return default
    try: v=int(v)
    except ValueError: raise Err('Invalid number')
    if not lo<=v<=hi: raise Err('Value must be between %d and %d'%(lo,hi))
    return v
def fval(d,k,lo,hi):
    try: v=float(str(d.get(k,'0') or '0').strip())
    except ValueError: raise Err('GB limit must be a number')
    if not lo<=v<=hi: raise Err('GB limit must be between %d and %d'%(lo,hi))
    return round(v,3)
def pwok(p):
    if not p or len(p)>256 or re.search(r'[\x00-\x1f\x7f]',p): raise Err('Password cannot be empty')
def sessions_full():
    s={}
    for l in run('ps','-eo','pid=,etimes=,args=').stdout.splitlines():
        p=l.split(None,2)
        if len(p)<3: continue
        m=re.match(r'sshd(?:-session)?: ([^@\s]+)@',p[2])
        if m:
            try: s.setdefault(m[1],[]).append((int(p[1]),int(p[0])))
            except ValueError: pass
    return s
def sessions(): return {k:len(v) for k,v in sessions_full().items()}
WSMAP='/run/rexui-ws'
def ssh_ips():
    """{user: [ip, ...]} for open SSH sessions. Users who came through the WS proxy or HAProxy show their real IP
    (the WS proxy writes it to /run/rexui-ws/<port>); SSH through stunnel only shows 'SSL' because stunnel hides it."""
    peer={}
    for l in run('ss','-tnpH','state','established','( sport = :%d )'%P('SSH_PORT',22)).stdout.splitlines():
        f=l.split()
        if len(f)<5: continue
        ip,_,pt=f[3].rpartition(':'); ip=ip.strip('[]')
        if ip.startswith('::ffff:'): ip=ip[7:]
        if ip in ('127.0.0.1','::1'): ip=rd(WSMAP+'/'+pt).strip() or 'SSL'
        for pid in re.findall(r'pid=(\d+)',' '.join(f[4:])): peer[int(pid)]=ip
    out={}
    for n,L in sessions_full().items():
        for _,pid in L:
            ip=peer.get(pid)
            if not ip:
                try: ip=peer.get(int(rd('/proc/%d/stat'%pid).rsplit(')',1)[1].split()[1]))
                except Exception: ip=None
            out.setdefault(n,[]).append(ip or 'SSL')
    return out
def add_days(u,days):
    if u.get('fdays'): u['fdays']=min(3650,u['fdays']+days); return
    if u['exp']=='never': raise Err('This user has no expiry, days cannot be added')
    if u.get('expts'):
        u['expts']=max(time.time(),u['expts'])+days*86400; u['exp']=datetime.date.fromtimestamp(u['expts']).isoformat()
    else:
        b=max(today(),u['exp']); u['exp']=(datetime.date.fromisoformat(b)+datetime.timedelta(days=days)).isoformat()
    setexp(u['name'],u['exp'])
def mkuser(us,n,p,e,lim=0.0,sni='',host='',dev=2,rday=0,note='',**kw):
    if not NAME.fullmatch(n) or n.isdigit(): raise Err('Username can use letters, numbers, _ . - (max 32, no spaces)')
    if any(x['name']==n for x in us): raise Err('This user already exists')
    try:
        pwd.getpwnam(n); raise Err('This name is already used by the system')
    except KeyError: pass
    pwok(p)
    r=run('useradd','-m','-s','/bin/false',n)
    for flag in ('--badname','--badnames'):
        if r.returncode and 'name' in r.stderr: r=run('useradd',flag,'-m','-s','/bin/false',n)
    if r.returncode: raise Err('Could not create user: '+r.stderr.strip()[-120:])
    if run('chpasswd',inp='%s:%s\n'%(n,p)).returncode:
        run('userdel','-r',n); raise Err('Could not set the password for this user, it was not created')
    b=newu(n,p,e,lim,sni,host,dev,rday); b['note']=note; b.update(kw); us.append(b); setexp(n,e)
    if haswg(b): wg_fill(b,us)
    if hasx(b) and b.get('ibs') is None: b['ibs']=[y['id'] for y in ib_load()]
    return b
def rmuser(n):
    ov_forget(n); ov_kill(n); hy_kick(n); WGON.pop(n,None); run('pkill','-KILL','-u',n); time.sleep(.3); run('userdel','-r',n); IPSEEN.pop(n,None)
def trial_new(d=None):
    k=kindval((d or {}).get('kind','both'))
    with UL:
        us=uload(); names={x['name'] for x in us}
        for _ in range(50):
            n='trial%04d'%secrets.randbelow(10000)
            if n in names: continue
            try: pwd.getpwnam(n); continue
            except KeyError: break
        ts=time.time()+86400
        b=mkuser(us,n,secrets.token_urlsafe(6),datetime.date.fromtimestamp(ts).isoformat(),2.0,dev=1 if k=='wg' else 2,note='Trial account',trial=True,expts=ts,kind=k)
        usave(us)
    enforce(); xray_apply(); ssh_rules(True); return {'ok':1,'name':b['name']}
def trial_cleanup():
    gone=[]
    with UL:
        us=uload()
        for u in us:
            if u.get('trial') and ustate(u) in ('expired','limit'): rmuser(u['name']); gone.append(u['name'])
        if gone: usave([u for u in us if u['name'] not in gone])
    if gone: log('trial ended:',gone); xray_apply(); tg_send('ReXUI: trial ended and deleted: %s'%', '.join(gone))
CSVF=['name','type','password','expiry','data_limit_gb','used_gb','devices','reset_day','sni','host','note','created','status','reality_target','reality_sni']
def csv_export():
    import csv,io
    o=io.StringIO(); w=csv.writer(o); w.writerow(CSVF)
    for u in uload():
        w.writerow([u['name'],kind(u),u['pw'],('first-use+%d'%u['fdays']) if u.get('fdays') else u['exp'],u['lim'] or 0,round((u['up']+u['down'])/GB,3),u.get('dev',0),u.get('rday',0),
                    u['sni'],u['host'],u.get('note',''),u.get('created',''),ustate(u),u.get('rtarget',''),u.get('rsni','')])
    return o.getvalue().encode()
def csv_import(d):
    import csv,io
    t=str(d.get('csv','')); rows=list(csv.DictReader(io.StringIO(t.lstrip('\ufeff'))))
    if not rows or 'name' not in (rows[0].keys()): raise Err('The file needs a header row with at least a "name" column')
    if len(rows)>2000: raise Err('Too many rows (max 2000)')
    ok,bad=[],[]; TC={}
    def rtc(t):
        if t not in TC: TC[t]=rtarget_val(t)
        return TC[t]
    with UL:
        us=uload()
        for i,r in enumerate(rows,2):
            r={str(k).strip().lower():str(v or '').strip() for k,v in r.items() if k}
            n=r.get('name','')
            try:
                e=r.get('expiry','') or 'never'; fd=0
                m=re.fullmatch(r'first-use\+(\d{1,4})',e)
                if m: fd=int(m[1]); e='never'
                elif re.fullmatch(r'\d{1,4}',e): e='never' if e=='0' else (datetime.date.today()+datetime.timedelta(days=int(e))).isoformat()
                elif e!='never':
                    try: datetime.date.fromisoformat(e)
                    except ValueError: raise Err('expiry must be YYYY-MM-DD, a number of days or never')
                def num(k,lo,hi,f=float):
                    try: v=f(r.get(k) or 0)
                    except ValueError: raise Err(k+' must be a number')
                    if not lo<=v<=hi: raise Err('%s must be between %g and %g'%(k,lo,hi))
                    return v
                lim=num('data_limit_gb',0,100000); dev=num('devices',0,100,int); rday=num('reset_day',0,28,int); used=num('used_gb',0,1e7)
                k_=kindval(r.get('type') or 'both')
                b=mkuser(us,n,r.get('password') or secrets.token_urlsafe(8),e,lim,hostok(r.get('sni'),'SNI'),hostok(r.get('host'),'Host'),dev,rday,noteval(r),fdays=fd,rtarget=rtc(r.get('reality_target','')),rsni=rsni_val(r.get('reality_sni')),kind=k_)
                b['down']=int(used*GB); ok.append(n)
            except Err as x: bad.append('Row %d (%s): %s'%(i,n or 'no name',x))
        usave(us)
    enforce(); xray_apply(); ssh_rules(True); return {'ok':1,'added':len(ok),'errors':bad[:50]}
def uapi(a,d):
    n=str(d.get('name','')).strip()
    with UL:
        us=uload(); u=next((x for x in us if x['name']==n),None)
        if a=='add':
            k=kindval(d.get('kind','both')); p=str(d.get('pw',''))
            if k in ('v2ray','ovpn','dns','wg') and not p: p=secrets.token_urlsafe(9)
            pwok(p); days=ival(d,'days',0,3650); lim=fval(d,'lim',0,100000)
            dev=ival(d,'dev',0,100,2); rday=ival(d,'rday',0,28,0); first=bool(d.get('first')) and days>0
            if k=='wg': dev=1
            sni=hostok(d.get('sni'),'SNI'); host=hostok(d.get('host'),'Host'); note=noteval(d); rt=rtarget_val(d.get('rtarget')); rs=rsni_val(d.get('rsni'))
            e='never' if days==0 or first else (datetime.date.today()+datetime.timedelta(days=days)).isoformat()
            ca=hostok(d.get('cdn'),'CDN address')
            ib=ibs_val(d.get('ibs'))
            mkuser(us,n,p,e,lim,sni,host,dev,rday,note,fdays=days if first else 0,rtarget=rt,rsni=rs,kind=k)
            if ca: us[-1]['cdn']=ca
            if kind(us[-1]) in ('v2ray','both'): us[-1]['ibs']=ib
            usave(us)
        elif not u: raise Err('User not found')
        elif a=='edit':
            p=str(d.get('pw','')); days=ival(d,'days',0,3650,0); lim=fval(d,'lim',0,100000)
            dev=ival(d,'dev',0,100,u.get('dev',0)); rday=ival(d,'rday',0,28,u.get('rday',0))
            if haswg(u): dev=1
            if p: pwok(p)
            sni=hostok(d.get('sni'),'SNI'); host=hostok(d.get('host'),'Host')
            if 'rtarget' in d: u['rtarget']=rtarget_val(d.get('rtarget'),u.get('rtarget',''))
            if 'rsni' in d: u['rsni']=rsni_val(d.get('rsni'))
            if 'cdn' in d: u['cdn']=hostok(d.get('cdn'),'CDN address')
            if 'ibs' in d:
                u['ibs']=ibs_val(d.get('ibs'))
            em=str(d.get('expmode','add'))
            if em not in ('add','never','set'): raise Err('bad request')
            if em=='never':
                u['exp']='never'; u['fdays']=0; u.pop('expts',None); setexp(n,'never')
            elif em=='set':
                if days<1: raise Err('Type how many days, from today')
                u['fdays']=0; u.pop('expts',None); u['exp']=(datetime.date.today()+datetime.timedelta(days=days)).isoformat(); setexp(n,u['exp'])
            elif days: add_days(u,days)
            if p:
                if run('chpasswd',inp='%s:%s\n'%(n,p)).returncode: raise Err('Could not change the password')
                u['pw']=p
            if p and hashy(u): hy_kick(n)
            if rday!=u.get('rday',0): u['lreset']=today()[:7]
            u['lim'],u['sni'],u['host'],u['dev'],u['rday']=lim,sni,host,dev,rday
            if 'note' in d: u['note']=noteval(d)
            usave(us)
        elif a=='rename':
            nn=str(d.get('new','')).strip()
            if nn==n: return {'ok':1,'name':n}
            if hassh(u) or hasov(u): raise Err('SSH and OpenVPN users keep their name (it is their login). Make a new user instead.')
            if not NAME.fullmatch(nn) or nn.isdigit(): raise Err('Username can use letters, numbers, _ . - (max 32, no spaces)')
            if any(x['name']==nn for x in us): raise Err('This user already exists')
            try:
                pwd.getpwnam(nn); raise Err('This name is already used by the system')
            except KeyError: pass
            collect(True)   # save the usage counted so far under the old name
            us=uload(); u=next(x for x in us if x['name']==n)
            hy_kick(n); run('pkill','-KILL','-u',n); time.sleep(.2)
            r=run('usermod','-l',nn,'-d','/home/'+nn,'-m',n)
            if r.returncode: raise Err('Could not rename: '+r.stderr.strip()[-120:])
            run('groupmod','-n',nn,n)
            u['name']=nn
            for D_ in (IPSEEN,SPD,LSEEN,UACC,XACT,HYON,WGON):
                if n in D_: D_[nn]=D_.pop(n)
            usave(us); res={'ok':1,'name':nn}
            enforce(); xray_apply(); ssh_rules(True); return res
        elif a=='newsub': u['sub']=secrets.token_hex(16); usave(us)
        elif a=='newuuid': u['uuid']=str(uuid.uuid4()); usave(us)
        elif a=='newwg':
            if not haswg(u): raise Err('This user has no WireGuard account')
            for k in ('wgk','wgp','wgs'): u.pop(k,None)
            wg_fill(u,us); usave(us)
        elif a=='newcert':
            if not hasov(u): raise Err('This user has no OpenVPN account')
            ov_forget(n); u['ovs']=''; usave(us); ov_allow(us); ov_kill(n); return {'ok':1}
        elif a=='toggle':
            u['en']=not u.get('en',True); u['reason']='' if u['en'] else textval(d.get('reason'),200,'Reason'); usave(us)
        elif a=='reset': u['up']=u['down']=0; usave(us)
        elif a=='kick': kick(n); return {'ok':1}
        elif a=='del':
            rmuser(n); us=[x for x in us if x['name']!=n]; usave(us)
        else: raise Err('bad request')
    enforce(); xray_apply(); ssh_rules(True)
    return {'ok':1}

# ---------- links / subscription ----------
def local_ip():
    try:
        k=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); k.connect(('1.1.1.1',53)); ip=k.getsockname()[0]; k.close(); return ip
    except OSError: return socket.gethostname()
def pub_addr(s=None):
    s=s or sload(); return s['addr'] or certinfo()['domain'] or IPS['v4'] or local_ip()
FP={}
def cert_fp():
    c=CD+'/xray.crt' if os.path.exists(CD+'/xray.crt') and os.path.exists(CD+'/xray.key') else XSC
    pem=rd(c)
    if pem not in FP:
        m=re.search(r'-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----',pem)
        FP.clear(); FP[pem]=hashlib.sha256(ssl.PEM_cert_to_DER_cert(m[0])).hexdigest() if m else ''
    return FP[pem]
def links(u):
    if hashy(u): return hy_links(u)
    if haswg(u): return []
    if hasdns(u): return dns_links(u)
    if not hasx(u): return []
    return _links(u)
def ib_tq(x,hh,cdn=False):
    """Transport part of a share link."""
    P_=quote(ib_path(x),safe=''); n=x['net']
    if n=='tcp':
        if x.get('obfs'): return '&type=tcp&headerType=http&host=%s&path=%s'%(quote(x.get('obhost') or 'www.bing.com'),quote(x.get('obpath') or '/',safe=''))
        return '&type=tcp'
    if n=='xhttp': return '&type=xhttp&host=%s&path=%s&mode=%s'%(quote(hh),P_,'packet-up' if cdn and (x.get('xmode') or 'auto')=='auto' else x.get('xmode') or 'auto')
    if n=='ws': return '&type=ws&host=%s&path=%s'%(quote(hh),P_)
    if n=='httpupgrade': return '&type=httpupgrade&host=%s&path=%s'%(quote(hh),P_)
    if n=='grpc': return '&type=grpc&serviceName=%s&mode=%s'%(quote(ib_svc(x),safe=''),'multi' if x.get('multi',True) else 'gun')+('&authority='+quote(x['host']) if x.get('host') else '')
    return ''
def ib_url(x,u,A_,port,q,N):
    """Build the final share link. q = security + transport query (no leading &)."""
    if x['proto']=='trojan': return 'trojan://%s@%s:%d?%s#%s'%(u['uuid'],A_,port,q,N)
    if x['proto']=='vless': return 'vless://%s@%s:%d?encryption=%s&%s#%s'%(u['uuid'],A_,port,quote(x.get('vencc') or 'none',safe=''),q,N)
    p={k:v[0] for k,v in parse_qs(q,keep_blank_values=True).items()}; nt=p.get('type','tcp')
    j={'v':'2','ps':unquote(N),'add':A_.strip('[]'),'port':str(port),'id':u['uuid'],'aid':'0','scy':'auto','net':nt,
       'type':p.get('headerType','none') if nt=='tcp' else ('multi' if p.get('mode')=='multi' else 'gun') if nt=='grpc' else p.get('mode','') if nt=='xhttp' else 'none',
       'host':p.get('host',p.get('authority','')),'path':p.get('serviceName') if nt=='grpc' else p.get('path',''),'tls':'' if p.get('security')=='none' else p.get('security',''),
       'sni':p.get('sni',''),'alpn':p.get('alpn',''),'fp':p.get('fp','')}
    if p.get('allowInsecure'): j['allowInsecure']=1
    if p.get('pcs'): j['pcs']=p['pcs']
    if p.get('ech'): j['ech']=p['ech']
    return 'vmess://'+base64.b64encode(json.dumps(j,separators=(',',':')).encode()).decode()
def ib_exts(x,u,lk,N):
    """One more link per external proxy address (same settings, other address / port)."""
    out=[]
    for e in x.get('ext') or []:
        A_='['+e['addr']+']' if ':' in e['addr'] else e['addr']; nm=N+quote(' · '+(e.get('remark') or e['addr']))
        out.append((x['name']+' · '+(e.get('remark') or e['addr']),ib_url(x,u,A_,e['port'],lk,nm),None))
    return out
def ib_slug(n): return re.sub(r'[^a-z0-9]+','-',n.lower()).strip('-')[:20] or 'config'
def _links(u):
    s=sload(); ci=certinfo(); a=pub_addr(s); cn=ci['name'] if ci['src']!='self-signed' else ''
    host=u.get('host') or s['host'] or ci['domain'] or a
    A='['+a+']' if ':' in a else a; pth=quote(s['path'],safe=''); fp=cert_fp()
    def tlsq(sni,f='chrome'):
        ok=bool(cn) and bool(sni) and (sni==cn or (cn.startswith('*.') and sni.endswith(cn[1:])))
        return 'security=tls'+('&sni='+quote(sni) if sni else '')+('&fp='+f if f!='none' else '')+('' if ok else '&allowInsecure=1'+('&pcs='+fp if fp else ''))
    xh='&type=xhttp&host=%s&path=%s&mode=auto'%(quote(host),pth)
    pa=s['addr'] if s['addr'] and re.search('[a-z]',s['addr']) else ci['domain'] or a; PA='['+pa+']' if ':' in pa else pa
    out=[]
    for x in ib_load():
        if not ib_ok(x) or not uhas_ib(u,x): continue
        b=x.get('b',''); code,typ=IBCODE.get(b,(ib_slug(x['name']),x['name'])); N=cfgname(u,code,typ,s)
        if x['cdn']: out+=cdn_link(u,s,x,N); continue
        if b=='reality':
            if not s['rpub']: continue
            rt,rs=ureal(u,s)
            out.append((x['name'],'vless://%s@%s:%d?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s%s&type=tcp#%s'%(
                u['uuid'],('['+x['addr']+']' if ':' in x['addr'] else x['addr']) if x.get('addr') else A,rport(rt,s),quote(rs),ib_fp(x),s['rpub'],ib_sids(x)[0],
                '&spx='+quote(x['spx'],safe='') if x.get('spx') else '',N)))
            out+=ib_exts(dict(x,port=rport(rt,s)),u,'flow=xtls-rprx-vision&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&type=tcp'%(quote(rs),ib_fp(x),s['rpub'],ib_sids(x)[0]),N); continue
        own=x['port']; main,alt=own,None
        if h_on() and ib_h(x) and own not in (80,443): main,alt=(443 if x['sec']=='tls' else 80),own
        bi=bool(b)   # default inbounds keep the old per-user SNI / Host
        sni=(u.get('sni') if bi else '') or x['sni'] or s['sni'] or ci['domain']
        if x.get('addr'): A_='['+x['addr']+']' if ':' in x['addr'] else x['addr']
        else: A_=PA if x['net']!='tcp' and x['sec']=='none' else A
        hh=(u.get('host') if bi else '') or x.get('host') or ((x['sni'] or s['host'] or ci['domain'] or a) if x['sec']=='reality' or x.get('cmode') in ('path','content') else (s['host'] or ci['domain'] or a))
        tq=ib_tq(x,hh)
        if x['sec']=='reality':
            if not s['rpub']: continue
            sq='security=reality&sni=%s&fp=%s&pbk=%s&sid=%s'%(quote(x['sni']),ib_fp(x),s['rpub'],ib_sids(x)[0])+('&spx='+quote(x['spx'],safe='') if x.get('spx') else '')+('&flow=xtls-rprx-vision' if ib_vision(x) else '')
        elif x['sec']=='tls':
            al_=['http/1.1'] if main==443 and h_on() and own!=443 or own==443 else ib_alpn(x)   # 443 mode (HAProxy) speaks http/1.1
            sq=(('security=tls&sni='+quote(x['sni'])+('&fp='+ib_fp(x) if ib_fp(x)!='none' else '')) if x.get('cmode') in ('path','content') else tlsq(sni,ib_fp(x)))+('&alpn='+quote(','.join(al_),safe='') if al_ else '')+('&ech='+quote(x['echcfg'],safe='') if x.get('ech') and x.get('echcfg') else '')+('&flow=xtls-rprx-vision' if ib_vision(x) else '')
        else: sq='security=none'
        out.append((x['name'],ib_url(x,u,A_,main,sq+tq,N),alt)); out+=ib_exts(x,u,sq+tq,N)
    return out
def link_ob(url):
    """Turn a vless / vmess / trojan share link into an Xray outbound (for the JSON subscription)."""
    if url.startswith('vmess://'):
        j=json.loads(base64.b64decode(url[8:]+'='*(-len(url[8:])%4)))
        pr='vmess'; uid=j['id']; host,port=j['add'],int(j['port']); nt=j.get('net','tcp'); sec=j.get('tls') or 'none'
        q={'type':nt,'host':j.get('host',''),'path':j.get('path',''),'sni':j.get('sni',''),'alpn':j.get('alpn',''),'fp':j.get('fp',''),'security':sec,
           'headerType':j.get('type','none'),'serviceName':j.get('path',''),'mode':j.get('type',''),'ech':j.get('ech','')}
        if j.get('allowInsecure'): q['allowInsecure']='1'
        if j.get('pcs'): q['pcs']=j['pcs']
        name=j.get('ps','')
    else:
        m=re.fullmatch(r'(vless|trojan)://([^@]+)@(\[[^\]]+\]|[^:]+):(\d+)\?([^#]*)#?(.*)',url)
        if not m: return None,''
        pr,uid,host,port=m[1],m[2],m[3].strip('[]'),int(m[4]); q={k:v[0] for k,v in parse_qs(m[5],keep_blank_values=True).items()}; name=unquote(m[6])
        nt=q.get('type','tcp'); sec=q.get('security','none')
    if pr=='trojan': st_={'servers':[{'address':host,'port':port,'password':uid,'level':8}]}
    else:
        us={'id':uid,'level':8}
        if pr=='vless': us['encryption']=q.get('encryption') or 'none'; us.update({'flow':q['flow']} if q.get('flow') else {})
        else: us.update(alterId=0,security='auto')
        st_={'vnext':[{'address':host,'port':port,'users':[us]}]}
    ss={'network':nt,'security':sec}
    if sec=='tls':
        t={'serverName':q.get('sni',''),'fingerprint':q.get('fp') or 'chrome'}
        if q.get('alpn'): t['alpn']=q['alpn'].split(',')
        if q.get('pcs'): t['pinnedPeerCertSha256']=q['pcs']
        if q.get('ech'): t['echConfigList']=q['ech']
        ss['tlsSettings']=t
    if sec=='reality': ss['realitySettings']={'serverName':q.get('sni',''),'fingerprint':q.get('fp') or 'chrome','publicKey':q.get('pbk',''),'shortId':q.get('sid',''),'spiderX':q.get('spx','')}
    if nt=='tcp' and q.get('headerType')=='http': ss['tcpSettings']={'header':{'type':'http','request':{'path':[q.get('path') or '/'],'headers':{'Host':[q.get('host','')]}}}}
    if nt=='ws': ss['wsSettings']={'path':q.get('path','/'),'host':q.get('host','')}
    if nt=='httpupgrade': ss['httpupgradeSettings']={'path':q.get('path','/'),'host':q.get('host','')}
    if nt=='xhttp': ss['xhttpSettings']={'path':q.get('path','/'),'host':q.get('host',''),'mode':q.get('mode') or 'auto'}
    if nt=='grpc': ss['grpcSettings']={'serviceName':q.get('serviceName',''),'multiMode':q.get('mode')=='multi',**({'authority':q['authority']} if q.get('authority') else {})}
    return {'tag':'proxy','protocol':pr,'settings':st_,'streamSettings':ss,'mux':{'enabled':False}},name
def json_sub(u):
    """Full client configs (v2rayNG / v2rayN JSON subscription), with optional TLS fragment and noise."""
    s=sload(); out=[]
    for l in links(u):
        c=json_cfg(l[1],s)
        if c: out.append(c)
    return out
def json_cfg(url,s=None):
    """One full client config (v2rayNG custom config) from a share link."""
    s=s or sload()
    try: ob,name=link_ob(url)
    except Exception: ob=None
    if not ob: return None
    obs=[ob,{'tag':'direct','protocol':'freedom','streamSettings':{'sockopt':{'domainStrategy':'UseIP'}}},{'tag':'block','protocol':'blackhole'}]
    fr=s.get('jfrag') and ob['streamSettings']['security']=='tls'
    if fr or s.get('jnoise'):
        f={'tag':'fragment','protocol':'freedom','settings':{},'streamSettings':{'sockopt':{'tcpNoDelay':True,'domainStrategy':'UseIP'}}}
        if fr: f['settings']['fragment']={'packets':s.get('jpk') or 'tlshello','length':s.get('jlen') or '100-200','interval':s.get('jint') or '10-20'}
        if s.get('jnoise'): f['settings']['noises']=[{'type':'rand','packet':'10-20','delay':'10-16'}]
        ob['streamSettings']['sockopt']={'dialerProxy':'fragment'}; obs.append(f)
    return ({'remarks':name,'log':{'loglevel':'warning'},
        'dns':{'servers':['1.1.1.1','8.8.8.8']},
        'inbounds':[{'tag':'socks','port':10808,'listen':'127.0.0.1','protocol':'socks','settings':{'auth':'noauth','udp':True},'sniffing':{'enabled':True,'destOverride':['http','tls'],'routeOnly':True}},
                    {'tag':'http','port':10809,'listen':'127.0.0.1','protocol':'http','settings':{}}],
        'outbounds':obs,
        'routing':{'domainStrategy':'AsIs','rules':[{'type':'field','ip':['geoip:private'],'outboundTag':'direct'}]}})
def sub_url(u): return 'https://%s:%s/sub/%s'%(certinfo()['domain'] or pub_addr(),E.get('PANEL_PORT',''),u['sub'])
def detail(n):
    u=next((x for x in uload() if x['name']==n),None)
    if not u: raise Err('User not found')
    s=sload(); ci=certinfo(); a=pub_addr(s)
    return {'name':u['name'],'pw':u['pw'],'uuid':u['uuid'],'exp':u['exp'],'lim':u['lim'],'used':u['up']+u['down'],'up':u['up'],'down':u['down'],
            'sni':u['sni'],'host':u['host'],'rtarget':u.get('rtarget',''),'rsni_u':u.get('rsni',''),'cdn':u.get('cdn',''),'rt':ureal(u,s)[0],'rport':rport(ureal(u,s)[0],s),'ibs':u.get('ibs'),'st':ustate(u),'created':u.get('created',''),'dev':u.get('dev',0),'rday':u.get('rday',0),
            'note':u.get('note',''),'hist':hist30(u),'fdays':u.get('fdays',0),'trial':u.get('trial',False),'expts':u.get('expts',0),'reason':u.get('reason',''),'kind':kind(u),
            'ssh':sessions().get(u['name'],0),'sips':ssh_ips().get(u['name'],[]),'ips':xips_on(u['name']),'ovpn':ov_info(u),'hy2':hy_info(u),'wg':wg_info(u),'dns':dns_info(u),'pays':[{'name':p['name'],'mode':p['mode'],'note':p.get('note',''),'text':pay_render(p)} for p in pay_load() if p.get('show') and hassh(u)],'sub':sub_url(u),'jsub':sub_url(u)+'/json' if hasx(u) and sload().get('jsub',True) else '','links':[dict({'name':l[0],'url':l[1]},**({'alt':l[2]} if len(l)>2 and l[2] else {}),**({'json':json_cfg(l[1])} if l[1].startswith(('vless://','trojan://','vmess://')) else {})) for l in links(u)],
            'addr':a,'whost':u['host'] or s['host'] or ci['domain'] or a,'path':s['path'],'rsni':s['rsni'],
            'plaindomain':bool((s['addr'] and re.search('[a-z]',s['addr'])) or ci['domain']),
            'ports':dict({k:str(P(k,d)) for k,d in (('SSH_PORT',22),('UDPGW_PORT',7300))},**{k:str(v) for k,v in h_uports(u)[0].items()}),
            'alt':{k:str(v) for k,v in h_uports(u)[1].items()}}

# ---------- Inbounds (V2Ray configs the admin can add, edit and remove) ----------
IBF=T+'/inbounds.json'; IBL=threading.RLock()
# default inbounds: their port stays in the config file, so the menu and the rest of the panel keep working
IBB={'xhttp-tls':('VLESS XHTTP TLS','vless','xhttp','tls','VWSTLS_PORT',8443,'vless-xhttp-tls'),
     'tcp-tls':('VLESS TCP TLS','vless','tcp','tls','VTCP_PORT',2053,'vless-tcp-tls'),
     'trojan':('Trojan TLS','trojan','tcp','tls','TROJAN_PORT',2096,'trojan-tls'),
     'reality':('VLESS Reality','vless','tcp','reality','REALITY_PORT',8444,'vless-reality'),
     'xhttp':('VLESS XHTTP','vless','xhttp','none','VWS_PORT',8080,'vless-xhttp')}
IBCDN={'cdn-tls':('VLESS XHTTP TLS · CDN','tls','VWSTLS_PORT',8443),'cdn':('VLESS XHTTP · CDN (no TLS)','none','VWS_PORT',8080)}
IBCODE={'xhttp-tls':('xhttp-tls','VLESS XHTTP TLS'),'tcp-tls':('tcp-tls','VLESS TCP TLS'),'trojan':('trojan','Trojan TLS'),'reality':('reality','VLESS Reality'),
        'xhttp':('xhttp','VLESS XHTTP'),'cdn-tls':('cdn-tls','CDN XHTTP TLS'),'cdn':('cdn','CDN XHTTP')}
def ib_defaults(only=None):
    L=[]
    for b,(n,pr,net,sec,k,d,_) in IBB.items():
        if only is None or b in only: L.append({'id':b,'b':b,'name':n,'proto':pr,'net':net,'cdn':False,'sec':sec,'port':P(k,d),'sni':'','addr':'','host':'','path':'','on':True})
    for b,(n,sec,k,d) in IBCDN.items():
        if only is None or b in only: L.append({'id':b,'b':b,'name':n,'proto':'vless','net':'xhttp','cdn':True,'sec':sec,'port':P(k,d),'sni':'','addr':'','host':'','path':'','on':True})
    return L
def ib_load():
    with IBL:
        try: L=json.loads(rd(IBF)) if os.path.exists(IBF) else None
        except Exception: L=None
        if not isinstance(L,list):
            L=[]; wjson(IBF,L,0o600); log('inbounds: empty list made (add inbounds in the panel)')
        for x in L:
            if x.get('b') in IBB: k,d=IBB[x['b']][4],IBB[x['b']][5]; x['port']=P(k,d)
            for k in ('sni','addr','host','path','target','b','alpn','svc','obhost','minv','maxv','echkey','echcfg','spx'): x.setdefault(k,'')
            x.setdefault('fp','chrome'); x.setdefault('xmode','auto'); x.setdefault('multi',True); x.setdefault('obfs',False); x.setdefault('obpath','/')
            x.setdefault('hb',0); x.setdefault('hdrs',[]); x.setdefault('tfo',False); x.setdefault('frag',{}); x.setdefault('rsni',False); x.setdefault('ech',False)
            x.setdefault('flow','vision' if x.get('sec')=='reality' and x.get('proto')=='vless' and x.get('net')=='tcp' else '')
            x.setdefault('sids',[]); x.setdefault('snix',[]); x.setdefault('ext',[]); x.setdefault('sniff',{'on':True,'dest':['http','tls'],'ro':False}); x.setdefault('cmode','panel'); x.setdefault('venc',''); x.setdefault('vdec',''); x.setdefault('vencc',''); x.setdefault('lfb',{}); x.setdefault('rw',{})
            for k in ('cfile','kfile','ccrt','ckey'): x.setdefault(k,'')
            x.setdefault('cdn',False); x.setdefault('on',True)
        return L
def cfg_set(k,v):
    """Change one value in the config file (and in the running panel)."""
    t=rd(CONF); line='%s=%s'%(k,v)
    t=re.sub(r'(?m)^%s=.*$'%re.escape(k),line,t) if re.search(r'(?m)^%s='%re.escape(k),t) else t.rstrip('\n')+'\n'+line+'\n'
    wtext(CONF,t,0o600); E[k]=str(v)
def ufw_allow(p):
    if run('sh','-c','command -v ufw >/dev/null && ufw status | grep -q "Status: active"').returncode==0: run('ufw','allow','%d/tcp'%p)
def ib_hports():
    """Ports the panel uses for things that are not inbounds."""
    r={P(k,d):n for k,d,n in (('SSH_PORT',22,'SSH'),('WS_PORT',8880,'SSH WebSocket'),('WSTLS_PORT',2083,'SSH WebSocket TLS'),('PANEL_PORT',0,'the panel'),
       ('UDPGW_PORT',7300,'UDPGW'),('OVPN1_PORT',1194,'OpenVPN'),('OVPN2_PORT',110,'OpenVPN'),('SQUID_PORT',3128,'the HTTP proxy'))}
    if not (h_on() and P('SSL_PORT',443)==443): r[P('SSL_PORT',443)]='SSH SSL'
    for p in (10085,10088,10443,FBP,DNSUP): r[p]='ReXUI (inside)'
    for t,p in (sload().get('rports') or {}).items(): r[p]='a Reality target of a user'
    r.pop(0,None); return r
def ib_main(net): return sload()['wspath' if net=='ws' else 'path']
def ib_path(x): return x.get('path') or ib_main(x['net'])
FPS=('chrome','firefox','safari','edge','ios','android','random','randomized','none')
ALPNS=('h2','http/1.1')
def ib_fp(x):
    v=x.get('fp') or 'chrome'
    return 'chrome' if v not in FPS or (v=='none' and x.get('sec')=='reality') else v
def ib_alpn(x,srv=False):
    """ALPN list for a TLS inbound. Empty setting = the default for the transport."""
    if x.get('sec')!='tls': return []
    a=[v for v in ALPNS if v in str(x.get('alpn') or '').split(',')]
    if not a: a={'xhttp':['h2','http/1.1'],'ws':['http/1.1'],'httpupgrade':['http/1.1'],'grpc':['h2']}.get(x['net'],[])
    if srv and x['net']=='tcp' and sload()['fsite']!='off' and 'http/1.1' not in a: a=a+['http/1.1']
    return a
PROTOS=('vless','trojan'); NETS=('tcp','xhttp','ws','httpupgrade'); XMODES=('auto','packet-up','stream-up','stream-one')
TLSV=('1.0','1.1','1.2','1.3'); SNIFFS=('http','tls','quic','fakedns')
def ib_svc(x): return x.get('svc') or 'rexgrpc'
def ib_sids(x):
    v=[i for i in (x.get('sids') or []) if re.fullmatch(r'[0-9a-f]{0,16}',str(i))]
    return v or [sload()['rsid']]
def ib_snis(x): return [x['sni']]+[h for h in (x.get('snix') or []) if h and h!=x['sni']]
def ib_vision(x): return x['proto']=='vless' and x['net']=='tcp' and x['sec'] in ('tls','reality') and x.get('flow')=='vision' and not x.get('obfs')
def ib_stream(x,cert=None):
    """Xray streamSettings of one inbound (server side)."""
    net,sec=x['net'],x['sec']; st={'network':net,'security':sec}
    if sec=='tls':
        t=dict(cert or {}); al_=ib_alpn(x,True)
        if x.get('cmode') in ('path','content'):   # read by the panel (root), so Xray does not need access to the files
            c_,k_=(rd(x['cfile']),rd(x['kfile'])) if x['cmode']=='path' else (x['ccrt'],x['ckey'])
            t['certificates']=[{'certificate':c_.strip().splitlines(),'key':k_.strip().splitlines()}]
        if al_: t['alpn']=al_
        if x.get('minv'): t['minVersion']=x['minv']
        if x.get('maxv'): t['maxVersion']=x['maxv']
        if x.get('rsni'): t['rejectUnknownSni']=True
        if x.get('ech') and x.get('echkey'): t['echServerKeys']=x['echkey']
        st['tlsSettings']=t
    if sec=='reality':
        st['realitySettings']={'target':x.get('target') or x['sni']+':443','serverNames':ib_snis(x),'privateKey':sload()['rpriv'],'shortIds':ib_sids(x)}
        lf=x.get('lfb') or {}
        if lf.get('on'):
            v_={'afterBytes':int(lf['after'])*1024,'bytesPerSec':int(lf['rate'])*1024,'burstBytesPerSec':int(lf['rate'])*1024}
            st['realitySettings'].update(limitFallbackUpload=v_,limitFallbackDownload=dict(v_))
    if net=='xhttp': st['xhttpSettings']={'path':ib_path(x),'mode':x.get('xmode') or 'auto'}
    if net=='ws':
        w={'path':ib_path(x)}
        if int(x.get('hb') or 0): w['heartbeatPeriod']=int(x['hb'])
        hd={k:v for k,v in (x.get('hdrs') or [])}
        if hd: w['headers']=hd
        st['wsSettings']=w
    if net=='httpupgrade':
        w={'path':ib_path(x)}; hd={k:v for k,v in (x.get('hdrs') or [])}
        if hd: w['headers']=hd
        st['httpupgradeSettings']=w
    if net=='grpc': st['grpcSettings']={'serviceName':ib_svc(x),'multiMode':bool(x.get('multi',True))}
    if net=='tcp' and x.get('obfs'):
        st['tcpSettings']={'header':{'type':'http','request':{'path':[x.get('obpath') or '/'],'headers':{'Host':[x.get('obhost') or 'www.bing.com']}}}}
    if x.get('tfo'): st['sockopt']={'tcpFastOpen':True}
    f=x.get('frag') or {}
    if f.get('on'): st['finalmask']={'tcp':[{'type':'fragment','settings':{'packets':f.get('packets') or 'tlshello','lengths':[f.get('lengths') or '100-200'],'delays':[f.get('delays') or '10-20']}}]}
    return st
def ib_sniff(x):
    v=x.get('sniff') or {}
    if not v.get('on',True): return {'enabled':False}
    d=[i for i in (v.get('dest') or ['http','tls']) if i in SNIFFS] or ['http','tls']
    return dict({'enabled':True,'destOverride':d},**({'routeOnly':True} if v.get('ro') else {}))
def ib_kind(x):
    st=ib_stream(x); st.pop('realitySettings',None)
    return (x['proto'],x['sec'],(x.get('target') or x['sni']) if x['sec']=='reality' else '',json.dumps(st,sort_keys=True),ib_vision(x),json.dumps(ib_sniff(x),sort_keys=True),
            json.dumps([ib_snis(x),ib_sids(x)]) if x['sec']=='reality' else '',x.get('vdec') or '')
def ib_h(x):
    """Which HAProxy route (443 mode) can carry this inbound: xhttp, vless, trojan or None."""
    if x.get('venc') or x['sec']=='reality' or x['proto']=='vmess' or x['net'] in ('grpc','httpupgrade') or x.get('obfs') or x.get('ech') or ib_vision(x): return None
    if x.get('cmode') in ('path','content') or x.get('frag',{}).get('on') or x.get('tfo') or x.get('minv') or x.get('maxv') or x.get('rsni'): return None
    if x['net'] in ('xhttp','ws') and x['proto']=='vless': return x['net'] if ib_path(x)==ib_main(x['net']) and (x.get('xmode') or 'auto')=='auto' and not x.get('hb') and not x.get('hdrs') else None
    if x['net']=='tcp' and x['sec']=='tls': return 'vless' if x['proto']=='vless' else 'trojan'
    return None
def ib_ok(x):
    """Can this inbound run now? (80/443 need 443 mode.)"""
    return x['on'] and (x['port'] not in (80,443) or h_on())
def ib_check(x,L,old=None):
    n=str(x.get('name') or '').strip()
    if not n or len(n)>40: raise Err('Give the inbound a name (up to 40 letters)')
    pr=x.get('proto'); net=x.get('net'); sec=x.get('sec'); cdn=bool(x.get('cdn'))
    if pr not in PROTOS: raise Err('Protocol must be VLESS or Trojan')
    if net not in NETS: raise Err('Transport must be TCP, XHTTP, WS or HTTPUpgrade')
    if sec not in ('none','tls','reality'): raise Err('Security must be None, TLS or Reality')
    try: p=int(x.get('port'))
    except (TypeError,ValueError): raise Err('Port must be a number')
    if not 1<=p<=65535: raise Err('Port must be 1-65535')
    sni=hostok(x.get('sni'),'SNI'); host=hostok(x.get('host'),'Host'); addr=hostok(x.get('addr'),'Address')
    path=str(x.get('path') or '').strip(); tg=str(x.get('target') or '').strip()
    if path and not re.fullmatch(r'/[A-Za-z0-9._~/-]{0,60}',path): raise Err('Path must start with / (letters, numbers, - _ . /)')
    if net in ('tcp','grpc'): path=''
    if net=='tcp': host=''
    if cdn and net not in ('xhttp','ws','grpc','httpupgrade'): raise Err('CDN works only with XHTTP, WS or HTTPUpgrade')
    if path and path==ib_main(net): path=''
    if sec!='reality': tg=''
    fp=str(x.get('fp') or 'chrome').lower()
    if fp not in FPS: raise Err('Fingerprint must be one of: '+', '.join(FPS))
    if sec=='reality' and fp=='none': raise Err('Reality needs a fingerprint (chrome is best)')
    if sec=='none': fp='chrome'
    al=x.get('alpn') or ''
    if isinstance(al,list): al=','.join(map(str,al))
    al=[v.strip().lower() for v in str(al).split(',') if v.strip()]
    if any(v not in ALPNS for v in al): raise Err('ALPN can be h2 and / or http/1.1')
    if sec!='tls': al=[]
    if net in ('ws','httpupgrade') and al and 'http/1.1' not in al: raise Err('%s needs http/1.1 in ALPN (it does not work on h2 alone)'%('WS' if net=='ws' else 'HTTPUpgrade'))
    if net=='grpc' and al and 'h2' not in al: raise Err('gRPC needs h2 in ALPN')
    al=','.join(v for v in ALPNS if v in al)
    if not sni and (old or {}).get('b')=='reality': sni=sload()['rsni']
    ex=ib_extra(x,pr,net,sec,cdn,p,sni,old)
    if sec=='reality':
        if net in ('ws','httpupgrade'): raise Err('Reality does not work with %s. Use TLS, or pick TCP / XHTTP.'%('WS' if net=='ws' else 'HTTPUpgrade'))
        if cdn: raise Err('Reality does not work through a CDN. Use TLS or None.')
        if not sni or re.fullmatch(r'[\d.]+',sni): raise Err('Reality needs an SNI: a big site with TLS 1.3, like www.microsoft.com')
        if tg:
            m=re.fullmatch(r'([A-Za-z0-9.-]+)(?::(\d{1,5}))?',tg)
            if not m or not 1<=int(m[2] or 443)<=65535: raise Err('Target must look like www.microsoft.com:443')
            tg='%s:%d'%(m[1],int(m[2] or 443))
            if tg==sni+':443': tg=''
        if p in (80,443): raise Err('Reality needs its own port (not 80 or 443). Use for example 8445.')
    if cdn and sec=='tls' and p not in CF_HTTPS: raise Err('Cloudflare CDN with TLS works only on ports '+', '.join(map(str,CF_HTTPS)))
    if cdn and sec=='none' and p not in CF_HTTP: raise Err('Cloudflare CDN without TLS works only on ports '+', '.join(map(str,CF_HTTP)))
    b=(old or {}).get('b','')
    if b and b!='reality' and ib_h(dict(x,proto=pr,net=net,sec=sec,path=path,**ex)) is None and ib_h(old): b=''
    if b and (any(old.get(k)!=v for k,v in (('proto',pr),('net',net),('sec',sec),('cdn',cdn)) if k in old) or path or tg): b=''
    if b in IBB and p in (80,443): raise Err('Default inbounds already use 443/80 when 443 mode is on. Make a new inbound for port %d.'%p)
    if p in (80,443):
        if not h_on(): raise Err('Port %d needs 443 mode. Turn it on in Settings → Network ports, or pick another port.'%p)
        if net=='tcp' and sec!='tls': raise Err('On port %d TCP needs TLS (TCP without TLS cannot share the port). Use XHTTP or WS, or another port.'%p)
        if pr=='trojan' and net!='tcp': raise Err('On port %d Trojan works only with TCP + TLS. Use VLESS for XHTTP / WS here.'%p)
        if pr=='vmess' or net in ('grpc','httpupgrade') or (net=='tcp' and sec!='tls') or (pr=='trojan' and net!='tcp'): pass
        elif path: raise Err('On port %d (443 mode) %s uses the main path %s. Leave Path empty.'%(p,net.upper(),ib_main(net)))
        if ib_h(dict(x,proto=pr,net=net,sec=sec,path=path,**ex)) is None:
            raise Err('Port %d (443 mode) carries only plain VLESS XHTTP / WS and VLESS / Trojan TCP+TLS. %s needs its own port, for example 2083.'%(p,ib_why(dict(x,proto=pr,net=net,sec=sec,**ex))))
    o=dict(x,name=n,proto=pr,net=net,sec=sec,cdn=cdn,port=p,sni=sni,host=host,addr=addr,path=path,target=tg,b=b,fp=fp,alpn=al,on=bool(x.get('on',True)),**ex)
    if o['on'] and p not in (80,443):
        hp=ib_hports()
        if p in hp: raise Err('Port %d is used by %s. Pick another port.'%(p,hp[p]))
        for y in L:
            if y['id']==(old or {}).get('id') or not y['on'] or y['port']!=p: continue
            if o['sec']=='reality' or y['sec']=='reality' or ib_kind(y)!=ib_kind(o):
                raise Err('Port %d is used by the inbound "%s" (a different type). Pick another port.'%(p,y['name']))
        if not any(y['on'] and y['port']==p and y['id']!=(old or {}).get('id') for y in L) and p!=(old or {}).get('port'):
            g=ss_listeners().get(('tcp',p))
            if g and g not in ('xray','?'): raise Err('Port %d is already used by %s on this server. Pick another port.'%(p,g))
    return o
IBKEYS=('name','port','sni','on','proto','net','sec','cdn','addr','host','path','target','fp','alpn','xmode','svc','multi','obfs','obhost','obpath','hb','hdrs','tfo','frag',
        'minv','maxv','rsni','ech','flow','sids','snix','spx','sniff','ext','cmode','cfile','kfile','ccrt','ckey','venc','lfb','rw')
def ib_why(x):
    w=[]
    if x['proto']=='vmess': w.append('VMess')
    if x['net'] in ('grpc','httpupgrade'): w.append({'grpc':'gRPC','httpupgrade':'HTTPUpgrade'}[x['net']])
    if ib_vision(x): w.append('Vision flow')
    for k,t in (('obfs','HTTP obfuscation'),('ech','ECH'),('tfo','TCP Fast Open'),('rsni','Reject Unknown SNI'),('hb','heartbeat'),('hdrs','headers')):
        if x.get(k): w.append(t)
    if x.get('minv') or x.get('maxv'): w.append('TLS version')
    if x.get('cmode') in ('path','content'): w.append('Own certificate')
    if x.get('venc'): w.append('VLESS Encryption')
    if (x.get('frag') or {}).get('on'): w.append('fragment')
    if x['net']=='xhttp' and (x.get('xmode') or 'auto')!='auto': w.append('XHTTP mode')
    return ', '.join(w) or 'custom path'
def ech_keys(name):
    r=run(XBIN,'tls','ech','--serverName',name,t=20); L=[l.strip() for l in (r.stdout or '').splitlines() if l.strip()]
    try: return L[L.index('ECH server keys:')+1],L[L.index('ECH config list:')+1]
    except (ValueError,IndexError): raise Err('Could not make ECH keys (xray tls ech failed). '+(r.stderr or '')[:120])
def cert_paths(all_=False):
    """Files of the panel certificate (Let's Encrypt, or the self-signed one)."""
    L=[(CD+'/xray.crt',CD+'/xray.key'),(XSC,XSK),(XD+'/cert.crt',XD+'/key.key')]
    if all_: return L
    return next(((c,k) for c,k in L[:2] if os.path.exists(c) and os.path.exists(k)),L[1])
def vless_enc(mode):
    """(server decryption, client encryption) strings from `xray vlessenc` (mode x25519 or mlkem)."""
    out=run(XBIN,'vlessenc',t=20).stdout or ''; blocks=out.split('Authentication:')[1:]
    for b in blocks:
        if ('ML-KEM' in b.split('\n')[0])==(mode=='mlkem'):
            d=re.search(r'"decryption":\s*"([^"]+)"',b); e=re.search(r'"encryption":\s*"([^"]+)"',b)
            if d and e: return d[1],e[1]
    raise Err('Could not make VLESS Encryption keys (xray vlessenc failed). Update Xray and try again.')
def ib_extra(x,pr,net,sec,cdn,p,sni,old):
    """Check and clean the advanced settings of an inbound."""
    old=old or {}; o={}
    def hostv(k,what):
        return hostok(x.get(k),what)
    def tb(k): return bool(x.get(k)) and x.get(k) not in ('0','false','off')
    o['xmode']=str(x.get('xmode') or 'auto')
    if o['xmode'] not in XMODES: raise Err('XHTTP mode must be one of: '+', '.join(XMODES))
    if net!='xhttp': o['xmode']='auto'
    sv=str(x.get('svc') or '').strip()
    if sv and not re.fullmatch(r'[A-Za-z0-9._-]{1,60}',sv): raise Err('gRPC service name: letters, numbers, - _ . only')
    o['svc']=sv if net=='grpc' else ''
    o['multi']=bool(x.get('multi',True))
    o['obfs']=net=='tcp' and tb('obfs')
    if o['obfs'] and sec=='reality': raise Err('HTTP obfuscation does not work with Reality')
    o['obhost']=hostv('obhost','Obfuscation host') if o['obfs'] else ''
    op=str(x.get('obpath') or '/').strip() or '/'
    if not re.fullmatch(r'/[A-Za-z0-9._~/?=&%-]{0,80}',op): raise Err('Obfuscation path must start with /')
    o['obpath']=op if o['obfs'] else '/'
    try: hb=int(x.get('hb') or 0)
    except (TypeError,ValueError): raise Err('Heartbeat must be a number of seconds')
    if not 0<=hb<=600: raise Err('Heartbeat must be 0-600 seconds')
    o['hb']=hb if net=='ws' else 0
    hd=[]
    for it in (x.get('hdrs') or []):
        k,v=(str(it[0]).strip(),str(it[1]).strip()) if isinstance(it,(list,tuple)) and len(it)==2 else ('','')
        if not k and not v: continue
        if not re.fullmatch(r'[A-Za-z0-9-]{1,40}',k) or len(v)>200 or any(c in v for c in '\r\n'): raise Err('Header "%s" is not valid'%k[:40])
        if k.lower()=='host': raise Err('Use the Host box for the Host header')
        hd.append([k,v])
    if len(hd)>10: raise Err('Up to 10 headers')
    o['hdrs']=hd if net in ('ws','httpupgrade') else []
    o['tfo']=tb('tfo')
    f=x.get('frag') or {}
    if isinstance(f,dict) and f.get('on'):
        pk=str(f.get('packets') or 'tlshello').strip(); ln=str(f.get('lengths') or '100-200').strip(); dl=str(f.get('delays') or '10-20').strip()
        if not re.fullmatch(r'tlshello|\d{1,2}-\d{1,2}',pk): raise Err('Fragment packets: tlshello or a range like 1-3')
        for v,t in ((ln,'length'),(dl,'delay')):
            if not re.fullmatch(r'\d{1,4}(-\d{1,4})?',v): raise Err('Fragment %s: a number or range like 100-200'%t)
        o['frag']={'on':True,'packets':pk,'lengths':ln,'delays':dl}
    else: o['frag']={}
    mi=str(x.get('minv') or ''); ma=str(x.get('maxv') or '')
    if mi and mi not in TLSV or ma and ma not in TLSV: raise Err('TLS version must be 1.0, 1.1, 1.2 or 1.3')
    if mi and ma and TLSV.index(mi)>TLSV.index(ma): raise Err('TLS min version is higher than max version')
    o['minv'],o['maxv']=(mi,ma) if sec=='tls' else ('','')
    o['rsni']=sec=='tls' and tb('rsni')
    o['ech']=sec=='tls' and tb('ech')
    if o['ech']:
        if cdn: raise Err('ECH does not work through the CDN')
        if o['maxv'] and o['maxv']!='1.3': raise Err('ECH needs TLS 1.3 (set Max version to 1.3 or empty)')
        en=sni or sload().get('domain') or 'cloudflare-ech.com'
        if old.get('ech') and old.get('echkey') and old.get('echsn')==en: o['echkey'],o['echcfg'],o['echsn']=old['echkey'],old['echcfg'],en
        else: k_,c_=ech_keys(en); o['echkey'],o['echcfg'],o['echsn']=k_,c_,en
    else: o['echkey']=o['echcfg']=o['echsn']=''
    cm=str(x.get('cmode') or 'panel')
    if cm not in ('panel','path','content'): raise Err('Certificate must be panel, file path or file content')
    if sec!='tls': cm='panel'
    if cm=='path' and (str(x.get('cfile') or '').strip(),str(x.get('kfile') or '').strip()) in cert_paths(True): cm='panel'   # the panel's own certificate
    o.update(cmode=cm,cfile='',kfile='',ccrt='',ckey='')
    if cm!='panel':
        if cdn: raise Err('Through the CDN the panel certificate is used. Turn CDN off for your own certificate.')
        if not sni: raise Err('Your own certificate needs the SNI (the domain on the certificate)')
        import tempfile
        if cm=='path':
            cf,kf=str(x.get('cfile') or '').strip(),str(x.get('kfile') or '').strip()
            for v,t in ((cf,'Public key (certificate)'),(kf,'Private key')):
                if not v.startswith('/') or not os.path.isfile(v): raise Err(t+' file not found on the server: '+(v or 'empty'))
            ct,kt=rd(cf),rd(kf); o['cfile'],o['kfile']=cf,kf
        else:
            ct=str(x.get('ccrt') or '').strip(); kt=str(x.get('ckey') or '').strip() or (old.get('ckey','') if old.get('cmode')=='content' else '') or str(x.get('_srckey') or '')
            if 'BEGIN CERTIFICATE' not in ct: raise Err('Paste the certificate (-----BEGIN CERTIFICATE-----)')
            if 'PRIVATE KEY' not in kt: raise Err('Paste the private key (-----BEGIN PRIVATE KEY-----)')
            o['ccrt'],o['ckey']=ct,kt
        with tempfile.TemporaryDirectory() as td:
            open(td+'/c','w').write(ct); open(td+'/k','w').write(kt)
            try: ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(td+'/c',td+'/k')
            except Exception: raise Err('The certificate and private key do not match, or one of them is broken')
    ve=str(x.get('venc') or '')
    if ve not in ('','x25519','mlkem'): raise Err('VLESS Encryption must be None, X25519 or ML-KEM-768')
    if pr!='vless' or old.get('b')=='reality': ve=''
    if ve and old.get('venc')==ve and old.get('vdec') and old.get('vencc'): o['venc'],o['vdec'],o['vencc']=ve,old['vdec'],old['vencc']
    elif ve: o['venc']=ve; o['vdec'],o['vencc']=vless_enc(ve)
    else: o['venc']=o['vdec']=o['vencc']=''
    lf=x.get('lfb') if isinstance(x.get('lfb'),dict) else {}
    if sec=='reality' and lf.get('on'):
        try: la,lr=int(float(lf.get('after') or 0)),int(float(lf.get('rate') or 0))
        except (TypeError,ValueError): raise Err('Limit fallback: numbers only')
        if not 0<=la<=1048576: raise Err('Limit fallback: "After" must be 0-1048576 KB')
        if not 1<=lr<=1048576: raise Err('Limit fallback: speed must be 1-1048576 KB/s')
        o['lfb']={'on':True,'after':la,'rate':lr}
    else: o['lfb']={}
    rw=x.get('rw') if isinstance(x.get('rw'),dict) else {}
    sp=rw.get('spares') or []
    if isinstance(sp,str): sp=[v for v in re.split(r'[\s,]+',sp) if v]
    sp=[v for v in dict.fromkeys(hostok(v,'Spare target') for v in sp[:10]) if v and v!=sni]
    o['rw']={'on':bool(rw.get('on')),'spares':sp} if sec=='reality' else {}
    if o['rw'].get('on') and not sp: raise Err('Reality Watch needs at least one spare target (a big site with TLS 1.3, like www.samsung.com)')
    fl=str(x.get('flow','vision' if sec=='reality' else '') or '')
    if fl not in ('','vision'): raise Err('Flow must be empty or xtls-rprx-vision')
    o['flow']=fl if pr=='vless' and net=='tcp' and sec in ('tls','reality') and not o['obfs'] else ''
    if o['flow'] and cdn: raise Err('Vision flow does not work through a CDN')
    sids=x.get('sids') or []
    if isinstance(sids,str): sids=[v for v in re.split(r'[\s,]+',sids) if v]
    sids=[str(v).lower() for v in sids]
    if any(not re.fullmatch(r'[0-9a-f]{0,16}',v) or len(v)%2 for v in sids): raise Err('Short IDs: hex, even length, up to 16 (like a1b2c3d4)')
    if len(sids)>8: raise Err('Up to 8 Short IDs')
    o['sids']=list(dict.fromkeys(sids)) if sec=='reality' else []
    sx=x.get('snix') or []
    if isinstance(sx,str): sx=[v for v in re.split(r'[\s,]+',sx) if v]
    sx=[hostok(v,'SNI') for v in sx][:10]
    o['snix']=[v for v in dict.fromkeys(sx) if v and v!=sni] if sec=='reality' else []
    spx=str(x.get('spx') or '').strip()
    if spx and not re.fullmatch(r'/[A-Za-z0-9._~/?=&%-]{0,80}',spx): raise Err('SpiderX must start with /')
    o['spx']=spx if sec=='reality' else ''
    sn=x.get('sniff') if isinstance(x.get('sniff'),dict) else {'on':True}
    o['sniff']={'on':bool(sn.get('on',True)),'dest':[v for v in SNIFFS if v in (sn.get('dest') or ['http','tls'])],'ro':bool(sn.get('ro'))}
    if o['sniff']['on'] and not o['sniff']['dest']: raise Err('Sniffing is on: pick at least one of HTTP, TLS, QUIC, FakeDNS')
    ext=[]
    for e in (x.get('ext') or [])[:20]:
        if not isinstance(e,dict): continue
        a=hostok(e.get('addr'),'External proxy address')
        if not a: continue
        try: ep=int(e.get('port') or p)
        except (TypeError,ValueError): raise Err('External proxy port must be a number')
        if not 1<=ep<=65535: raise Err('External proxy port must be 1-65535')
        rm=str(e.get('remark') or '').strip()[:30]
        ext.append({'addr':a,'port':ep,'remark':rm})
    o['ext']=ext
    return o
def ib_tls13(x):
    t=x.get('target') or x['sni']+':443'; h,pt=t.rsplit(':',1)
    if not tls13(h,int(pt),x['sni']): raise Err('%s did not answer with TLS 1.3 for the name %s. Pick another site for Reality.'%(t,x['sni']))
def ib_save(L):
    with IBL: wjson(IBF,L,0o600)
def ib_apply_change(old,new):
    if new.get('b') in IBB and old and (old.get('port')!=new['port'] or not old.get('b')):
        cfg_set(IBB[new['b']][4],new['port'])
    if new.get('b')=='reality' and new.get('sni') and new['sni']!=sload()['rsni']:
        s=sload(); s['rsni']=new['sni']; wjson(SETF,s,0o600)
    if new['on'] and new['port'] not in (80,443): ufw_allow(new['port'])
# 1-click set: one inbound of every kind. Only these (marked qk) are removed by "Remove 1-click".
QUICK=[('q1','VLESS TCP Vision TLS',20001,{'proto':'vless','net':'tcp','sec':'tls','flow':'vision'}),
       ('q2','VLESS WS TLS',20002,{'proto':'vless','net':'ws','sec':'tls','path':'/rxws'}),
       ('q3','VLESS HTTPUpgrade TLS',20003,{'proto':'vless','net':'httpupgrade','sec':'tls','path':'/rxhu'}),
       ('q4','VLESS XHTTP Reality',20004,{'proto':'vless','net':'xhttp','sec':'reality','path':'/rxxh'}),
       ('q5','VLESS XHTTP TLS stream-up',20005,{'proto':'vless','net':'xhttp','sec':'tls','path':'/rxsu','xmode':'stream-up'}),
       ('q6','Trojan WS TLS',20006,{'proto':'trojan','net':'ws','sec':'tls','path':'/rxtr'}),
       ('q7','Trojan HTTPUpgrade TLS',20007,{'proto':'trojan','net':'httpupgrade','sec':'tls','path':'/rxth'})]
QOFF={'on':False,'dest':['http','tls'],'ro':False}
def ib_quick(L):
    """Add the 1-click inbounds that are missing. Ports that are taken move to the next free one."""
    have={x.get('qk') for x in L}; add=[]; skip=[]; rs=sload()['rsni']; r_ok=None
    for k,n,p,d in QUICK:
        if k in have: continue
        x=dict(d,name=n,on=True,b='',qk=k,sniff=QOFF)
        if x['sec']=='reality':
            x['sni']=rs
            if r_ok is None: r_ok=bool(rs) and tls13(rs)
            if not r_ok: skip.append(n+' (Reality target %s did not answer with TLS 1.3)'%rs); continue
        last=''
        for pt in list(range(p,p+40))+list(range(p+1000,p+1040)):
            try: o=ib_check(dict(x,port=pt),L+add); break
            except Err as e: last=str(e)
        else: skip.append(n+' ('+last+')'); continue
        o['id']='i'+secrets.token_hex(4); o['b']=''; o['qk']=k; add.append(o)
    return add,skip
def ib_api(a,d):
    with IBL:
        L=ib_load()
        if a=='list': return {'ok':1,'ibs':ib_view(L)}
        if a=='ports':
            u={str(p):n for p,n in ib_hports().items()}
            for (pr,p),g in ss_listeners().items():
                if pr=='tcp' and str(p) not in u and g not in ('xray','haproxy','?') and p not in (80,443): u[str(p)]=g
            for y in L:
                if y['port'] not in (80,443): u.setdefault(str(y['port']),'inbound: '+y['name'])
            return {'ok':1,'used':u}
        if a=='add':
            dd={k:d[k] for k in IBKEYS if k in d}
            src=next((y for y in L if y['id']==d.get('from')),None) if d.get('from') else None
            if src and src.get('cmode')=='content' and not dd.get('ckey'): dd['_srckey']=src.get('ckey','')   # clone keeps the private key
            x=ib_check(dict(dd,b=''),L); x.pop('_srckey',None); x['id']='i'+secrets.token_hex(4); x['b']=''
            if x['sec']=='reality': ib_tls13(x)
            ib_freeze(L); L.append(x); ib_save(L); ib_apply_change(None,x); res={'ok':1,'id':x['id']}
            if (x.get('rw') or {}).get('on'): threading.Thread(target=lambda i_=x['id']:(time.sleep(2),rw_check(i_)),daemon=True).start()
        elif a in ('edit','toggle','del'):
            i=next((k for k,y in enumerate(L) if y['id']==d.get('id')),None)
            if i is None: raise Err('Inbound not found')
            old=L[i]
            if a=='del':
                L.pop(i); ib_save(L)
                us=uload(); ch=False
                for u in us:
                    if isinstance(u.get('ibs'),list) and old['id'] in u['ibs']: u['ibs'].remove(old['id']); ch=True
                if ch: usave(us)
                res={'ok':1}
            else:
                if a=='toggle': d=dict(old,on=not old['on'])
                else:
                    d=dict(old,**{k:d[k] for k in IBKEYS if k in d})
                x=ib_check(d,L,old); x['id']=old['id']
                if x['sec']=='reality' and (x['sni'],x['target'])!=(old['sni'] or (sload()['rsni'] if old.get('b')=='reality' else ''),old.get('target','')): ib_tls13(x)
                ib_apply_change(old,x)
                if (x.get('rw') or {}).get('on') and a=='edit': threading.Thread(target=lambda i_=x['id']:(time.sleep(2),rw_check(i_)),daemon=True).start()
                if x['b']=='reality': x['sni']=''
                L[i]=x; ib_save(L); res={'ok':1}
        elif a=='restore':
            ib_freeze(L); have={y.get('b') for y in L}; add=ib_defaults([b for b in list(IBB)+list(IBCDN) if b not in have])
            for x in add:
                if any(y['on'] and y['port']==x['port'] and ib_kind(y)!=ib_kind(x) for y in L): x['on']=False
            L+=add; ib_save(L); res={'ok':1,'added':len(add)}
        elif a=='quick':
            add,skip=ib_quick(L)
            if not add and not skip: raise Err('All 1-click inbounds are already there.')
            if add: ib_freeze(L); L+=add; ib_save(L)
            for x in add: ib_apply_change(None,x)
            res={'ok':1,'added':[x['name']+' :'+str(x['port']) for x in add],'skipped':skip}
        elif a=='quickdel':
            gone={x['id'] for x in L if x.get('qk')}
            if not gone: raise Err('There are no 1-click inbounds.')
            L=[x for x in L if x['id'] not in gone]; ib_save(L)
            us=uload(); ch=False
            for u in us:
                if isinstance(u.get('ibs'),list) and gone&set(u['ibs']): u['ibs']=[i for i in u['ibs'] if i not in gone]; ch=True
            if ch: usave(us)
            res={'ok':1,'removed':len(gone)}
        elif a=='move':
            i=next((k for k,y in enumerate(L) if y['id']==d.get('id')),None)
            if i is None: raise Err('Inbound not found')
            j=i+(-1 if d.get('dir')=='up' else 1)
            if 0<=j<len(L): L[i],L[j]=L[j],L[i]; ib_save(L)
            res={'ok':1}
        else: raise Err('Unknown action')
    r=xray_apply(force=True)
    if r: raise Err('Saved, but Xray did not accept the new settings: '+r)
    bans_apply(True)
    return res
def ib_view(L=None):
    L=ib_load() if L is None else L; s=sload(); us=[u for u in uload() if hasx(u)]
    out=[]
    for x in L:
        sni=x['sni'] or (s['rsni'] if x.get('b')=='reality' else '')
        warn=''
        if x['port'] in (80,443) and not h_on(): warn='Needs 443 mode: turn it on in Settings → Network ports.'
        elif x['cdn'] and not s.get('cdn_dom'): warn='Set your CDN domain in Settings → CDN, or users get no link for this inbound.'
        x=dict({k:v for k,v in x.items() if k not in ('echkey','ckey','vdec')},ckey_set=bool(x.get('ckey')))
        out.append(dict(x,sni=sni,users=sum(1 for u in us if uhas_ib(u,x)),run=ib_ok(x),warn=warn,
                        hp=(443 if x['sec']=='tls' else 80) if h_on() and ib_h(x) and x['port'] not in (80,443) else 0))
    return out
def ib_restore(L):
    """Inbounds from a backup: keep the ones that are valid here."""
    good=[]
    for x in L:
        if not isinstance(x,dict): continue
        try: y=ib_check(x,good,{'b':x.get('b','')} if x.get('b') in IBB or x.get('b') in IBCDN else None)
        except Err as e: log('restore: inbound skipped:',x.get('name'),e); continue
        y['id']=str(x.get('id') or 'i'+secrets.token_hex(4))[:20]
        if y['b'] in IBB: cfg_set(IBB[y['b']][4],y['port'])
        if y['b']=='reality': y['sni']=''
        good.append(y)
    if good: ib_save(good)
def uhas_ib(u,x):
    v=u.get('ibs'); return v is None or x['id'] in v
def ibs_val(v,L=None):
    """User's inbound choice: a list of inbound ids ('all' = every inbound there is now)."""
    ids=[y['id'] for y in (L or ib_load())]
    if v is None or v=='all': return list(ids)
    if not isinstance(v,list): raise Err('Pick the inbounds for this user')
    v=[str(i) for i in v if str(i) in ids]
    if not v and ids: raise Err('Tick at least one inbound for this user')
    return v
def ib_freeze(L):
    """Users from before (no list yet) keep exactly the inbounds there are now, so a new inbound is not added to them."""
    us=uload(); ids=[y['id'] for y in L]; ch=False
    for u in us:
        if u.get('ibs') is None and hasx(u): u['ibs']=list(ids); ch=True
    if ch: usave(us)
def xray_ports():
    """TCP ports Xray listens on for users (for bans and checks)."""
    ps=sorted({x['port'] for x in ib_load() if ib_ok(x) and x['port'] not in (80,443)}|{rport(ureal(u,sload())[0]) for u in uload() if hasx(u) and u.get('rtarget')})
    return ps+([443,80] if h_on() else [])

# ---------- SSH traffic (iptables owner/connmark) ----------
FAM=['iptables']+(['ip6tables'] if shutil.which('ip6tables') else []); CH=('REXUI_OUT','REXUI_IN'); RUIDS=[None]
def ipt(f,*a): return run(f,'-w','-t','mangle',*a)
def uidof(n):
    try: return pwd.getpwnam(n).pw_uid
    except KeyError: return None
def ssh_rules(force=False):
    uids=tuple(sorted(x for x in (uidof(u['name']) for u in uload()) if x))
    if uids==RUIDS[0] and not force: return
    if not shutil.which('iptables'): return
    ssh_collect(); SP=str(P('SSH_PORT',22))
    for f in FAM:
        for c in CH:
            ipt(f,'-N',c); ipt(f,'-F',c)
            if ipt(f,'-C','INPUT' if c=='REXUI_IN' else 'OUTPUT','-j',c).returncode: ipt(f,'-I','INPUT' if c=='REXUI_IN' else 'OUTPUT','1','-j',c)
        ipt(f,'-A','REXUI_OUT','-o','lo','-j','RETURN'); ipt(f,'-A','REXUI_OUT','-p','tcp','--sport',SP,'-j','RETURN'); ipt(f,'-A','REXUI_IN','-i','lo','-j','RETURN')
        for uid in uids:
            cm=('-m','comment','--comment','u%d'%uid)
            ipt(f,'-A','REXUI_OUT','-m','owner','--uid-owner',str(uid),*cm,'-j','CONNMARK','--set-mark',str(uid))
            ipt(f,'-A','REXUI_IN','-m','connmark','--mark',str(uid),*cm)
    RUIDS[0]=uids
PEND={}
def ssh_collect():
    for f in FAM:
        for c in CH:
            for l in ipt(f,'-L',c,'-n','-v','-x','-Z').stdout.splitlines():
                m=re.search(r'/\* u(\d+) \*/',l)
                if m:
                    try: b=int(l.split()[1])
                    except (IndexError,ValueError): continue
                    k=('up' if c=='REXUI_OUT' else 'down'); x=PEND.setdefault(int(m[1]),{'up':0,'down':0}); x[k]+=b
def purge():
    for u in uload(): run('pkill','-KILL','-u',u['name']); run('userdel','-r',u['name'])
    for f in FAM:
        for c in CH:
            while ipt(f,'-D','INPUT' if c=='REXUI_IN' else 'OUTPUT','-j',c).returncode==0: pass
            ipt(f,'-F',c); ipt(f,'-X',c)
        while run(f,'-w','-D','INPUT','-j','REXUI_BAN').returncode==0: pass
        run(f,'-w','-F','REXUI_BAN'); run(f,'-w','-X','REXUI_BAN')
        while run(f,'-w','-D','OUTPUT','-j','REXUI_SMTP').returncode==0: pass
        run(f,'-w','-F','REXUI_SMTP'); run(f,'-w','-X','REXUI_SMTP')

# ---------- Xray ----------
XLOCK=threading.Lock(); XHASH=['']; XBAD=['','']; XACT={}; XCUR=[None,'']
def xskel(cfg):
    c=json.loads(json.dumps(cfg))
    for i in c['inbounds']: i.get('settings',{}).pop('clients',None)
    return json.dumps(c,sort_keys=True)
def xclients(cfg):
    return {i['tag']:{x['email']:json.dumps(x,sort_keys=True) for x in i.get('settings',{}).get('clients',[])} for i in cfg['inbounds']}
def xray_live(old,new,ch):
    """Apply a change that only adds, removes or edits users through the Xray API, so nobody is disconnected.
    Returns False when a restart is needed (other settings changed, Xray not running, or the API failed)."""
    if not old or XCUR[1]!=ch or xskel(old)!=xskel(new): return False
    if run('systemctl','is-active','--quiet','xray').returncode: return False
    oc,nc=xclients(old),xclients(new); rm={}; add={}
    for t in nc:
        o,n=oc.get(t,{}),nc[t]
        r=[e for e in o if e not in n or o[e]!=n[e]]; a=[e for e in n if e not in o or o[e]!=n[e]]
        if r: rm[t]=r
        if a: add[t]=a
    if not rm and not add: return True
    for t,es in rm.items():
        for i in range(0,len(es),200):
            part=es[i:i+200]; out=run(XBIN,'api','rmu','-s',XAPI,'-tag='+t,*part,t=30)
            m=re.search(r'Removed (\d+) user',out.stdout+out.stderr)
            if not m or int(m[1])!=len(part): log('xray live remove failed on',t,(out.stdout+out.stderr).strip()[-200:]); return False
    if add:
        ibs=[]
        for i in new['inbounds']:
            if i['tag'] in add:
                x=json.loads(json.dumps(i)); keep=set(add[i['tag']])
                x['settings']['clients']=[c for c in x['settings']['clients'] if c['email'] in keep]; x.pop('streamSettings',None); x.pop('sniffing',None)
                x['settings'].pop('fallbacks',None); ibs.append(x)
        f=XD+'/live-users.json'
        with open(f,'w') as fh: json.dump({'inbounds':ibs},fh)
        os.chmod(f,0o600)
        try: out=run(XBIN,'api','adu','-s',XAPI,f,t=60)
        finally:
            try: os.remove(f)
            except OSError: pass
        m=re.search(r'Added (\d+) user',out.stdout+out.stderr)
        if not m or int(m[1])!=sum(len(v) for v in add.values()): log('xray live add failed:',(out.stdout+out.stderr).strip()[-200:]); return False
    log('xray users updated live: +%d -%d'%(sum(len(v) for v in add.values()),sum(len(v) for v in rm.values())))
    # users that are gone completely (disabled, ended, deleted): close their open connections, like a restart used to
    gone={e for t in oc for e in oc[t]}-{e for t in nc for e in nc[t]}
    if gone:
        now=time.time()
        for n in gone:
            for ip in list(IPSEEN.get(n,{})):
                if not shared(ip,n): BANS[ip]=max(BANS.get(ip,0),now+60)
            IPSEEN.pop(n,None)
        bans_apply()
    return True
def xstats():
    d={}
    if not os.path.exists(XBIN): return d
    r=run(XBIN,'api','statsquery','--server='+XAPI,'-pattern','user>>>','-reset',t=10)
    if r.returncode: return d
    try: items=json.loads(r.stdout).get('stat') or []
    except Exception: items=[{'name':a,'value':b} for a,b in re.findall(r'"name":\s*"([^"]+)"[^}]*?"value":\s*"?(\d+)',r.stdout)]
    for it in items:
        p=str(it.get('name','')).split('>>>')
        if len(p)==4 and p[0]=='user':
            try: v=int(it.get('value') or 0)
            except ValueError: v=0
            d.setdefault(p[1],{'up':0,'down':0})['up' if p[3]=='uplink' else 'down']+=v
    return d
def xray_apply(force=False):
    if not os.path.exists(XBIN): return
    with XLOCK:
        s=reality_keys(); act=[u for u in uload() if ustate(u)=='active' and hasx(u)]; cl=[{'id':u['uuid'],'email':u['name'],'level':0} for u in act]
        c,k=CD+'/xray.crt',CD+'/xray.key'
        if not (os.path.exists(c) and os.path.exists(k)): c,k=XSC,XSK
        cert={'certificates':[{'certificateFile':XD+'/cert.crt','keyFile':XD+'/key.key'}]}
        def cli(u,pr,flow=False):
            c={'password':u['uuid']} if pr=='trojan' else {'id':u['uuid']}
            c.update(email=u['name'],level=0)
            if pr=='vmess': c['alterId']=0
            if flow: c['flow']='xtls-rprx-vision'
            return c
        sn={'enabled':True,'destOverride':['http','tls']}; fs=s['fsite']!='off'
        ibs=[]; hs={'xhttp':{},'vless':{},'trojan':{},'ws':{}}; grp={}; rl=None; rx={}
        for x in ib_load():
            if not ib_ok(x): continue
            mem=[u for u in act if uhas_ib(u,x)]; hk=ib_h(x)
            if hk and h_on():
                for u in mem: hs[hk][u['name']]=u
            if x['port'] in (80,443): continue
            if x.get('b')=='reality': rl=mem; rx=x; continue
            if x['sec']=='reality' and not s['rpriv']: continue
            g=grp.setdefault(x['port'],{'x':x,'u':{}})
            for u in mem: g['u'][u['name']]=u
        for p,g in grp.items():
            x=g['x']; mem=list(g['u'].values()); pr,net,sec=x['proto'],x['net'],x['sec']
            st=ib_stream(x,cert)
            vs={'clients':[cli(u,pr,ib_vision(x)) for u in mem]}
            if pr=='vless': vs['decryption']=x.get('vdec') or 'none'
            if net=='tcp' and sec=='tls' and fs and not x.get('obfs') and not x.get('vdec'): vs['fallbacks']=[{'dest':FBP}]   # Xray: fallbacks cannot be used with decryption
            ibs.append({'tag':IBB[x['b']][6] if x.get('b') in IBB else 'ib-%d'%p,'listen':'0.0.0.0','port':p,'protocol':pr,'settings':vs,'streamSettings':st,'sniffing':ib_sniff(x)})
        if dns_on():
            dl=[u for u in uload() if hasdns(u) and ustate(u)=='active']
            ibs.append({'tag':'vless-dns','listen':'127.0.0.1','port':DNSUP,'protocol':'vless','settings':{'clients':[{'id':u['uuid'],'email':u['name'],'level':0} for u in dl],'decryption':'none'},
                        'streamSettings':{'network':'tcp','security':'none'},'sniffing':sn})
        if s['rpriv'] and rl is not None:
            dt=s['rsni']+':443'; grp={dt:[]}
            for u in rl:
                t,sn_=ureal(u,s); grp.setdefault(t,[]).append((u,sn_))
            for t,L in grp.items():
                pt=rport(t,s); names=sorted({x[1] for x in L}|{t.rsplit(':',1)[0]}|(set(rx.get('snix') or []) if t==dt else set()))
                rst={'network':'tcp','security':'reality','realitySettings':{'target':t,'serverNames':names,'privateKey':s['rpriv'],'shortIds':ib_sids(rx)}}
                for k_,v_ in ib_stream(dict(rx,sec='none',net='tcp',flow='')).items():
                    if k_ in ('sockopt','finalmask'): rst[k_]=v_
                lf_=rx.get('lfb') or {}
                if lf_.get('on'):
                    v_={'afterBytes':int(lf_['after'])*1024,'bytesPerSec':int(lf_['rate'])*1024,'burstBytesPerSec':int(lf_['rate'])*1024}
                    rst['realitySettings'].update(limitFallbackUpload=v_,limitFallbackDownload=dict(v_))
                ibs.append({'tag':'vless-reality' if t==dt else 'vless-reality-%d'%pt,'listen':'0.0.0.0','port':pt,'protocol':'vless',
                            'settings':{'clients':[{'id':u['uuid'],'email':u['name'],'level':0,'flow':'xtls-rprx-vision'} for u,_ in L],'decryption':'none'},
                            'streamSettings':rst,'sniffing':ib_sniff(rx) if rx else sn})
        ibs+=h_xinbounds(s,[cli(u,'vless') for u in hs['xhttp'].values()],[cli(u,'vless') for u in hs['vless'].values()],[cli(u,'trojan') for u in hs['trojan'].values()],[cli(u,'vless') for u in hs['ws'].values()])
        obs=[{'protocol':'freedom','tag':'direct','streamSettings':{'sockopt':{'domainStrategy':'UseIPv4v6'}}},{'protocol':'blackhole','tag':'block'}]; rules=[]
        if s['btorrent']: rules.append({'type':'field','protocol':['bittorrent'],'outboundTag':'block'})
        if s['bads'] and geo_ok(): rules.append({'type':'field','domain':['geosite:category-ads-all'],'outboundTag':'block'})
        w=None
        if s['warp']!='off':
            try: w=json.loads(rd(WARPF))
            except Exception: w=None
        if w:
            obs.append({'tag':'warp','protocol':'wireguard','settings':{'secretKey':w['priv'],'address':[w['v4']+'/32']+([w['v6']+'/128'] if w.get('v6') else []),
                        'peers':[{'publicKey':w['peer'],'allowedIPs':['0.0.0.0/0','::/0'],'endpoint':w['endpoint']}],'reserved':w['reserved'],'mtu':1280,'noKernelTun':True}})
            if s['warp']=='all': rules.append({'type':'field','network':'tcp,udp','outboundTag':'warp'})
            else:
                ws=[x for x in s['wsites'].split(',') if x and (geo_ok() or not x.startswith(('geosite:','geoip:')))]
                dm=[x for x in ws if not x.startswith('geoip:')]; ip=[x for x in ws if x.startswith('geoip:')]
                if dm: rules.append({'type':'field','domain':dm,'outboundTag':'warp'})
                if ip: rules.append({'type':'field','ip':ip,'outboundTag':'warp'})
        cfg={'log':{'loglevel':'warning','access':XLOG},'api':{'tag':'api','listen':XAPI,'services':['StatsService','HandlerService']},'stats':{},
             'policy':{'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True,'handshake':4,'connIdle':150,'uplinkOnly':2,'downlinkOnly':4}},'system':{'statsInboundUplink':True,'statsInboundDownlink':True}},
             'dns':{'servers':['1.1.1.1','8.8.8.8','localhost'],'queryStrategy':'UseIP','disableCache':False},
             'inbounds':ibs,'outbounds':obs,'routing':{'domainStrategy':'AsIs','rules':rules}}
        txt=json.dumps(cfg,indent=1); h=hashlib.sha256((txt+rd(c)+rd(k)).encode()).hexdigest()
        if h==XHASH[0] and not force: return
        if h==XBAD[0] and not force: return XBAD[1]
        os.makedirs(XD,exist_ok=True)
        g=nu=0
        for nm in ('rexui-xray','nobody'):
            try: w_=pwd.getpwnam(nm); g,nu=w_.pw_gid,w_.pw_uid; break
            except KeyError: pass
        if not os.path.isdir(XLOGD): os.makedirs(XLOGD,exist_ok=True)
        os.chown(XLOGD,nu,g); os.chmod(XLOGD,0o750)
        if not os.path.exists(XLOG): open(XLOG,'a').close()
        for src,dst in ((c,XD+'/cert.crt'),(k,XD+'/key.key')):
            shutil.copyfile(src,dst+'.tmp'); os.chown(dst+'.tmp',0,g); os.chmod(dst+'.tmp',0o640); os.replace(dst+'.tmp',dst)
        tmp=XD+'/config.new.json'
        with open(tmp,'w') as f: f.write(txt)
        os.chown(tmp,0,g); os.chmod(tmp,0o640)
        t=run(XBIN,'run','-test','-c',tmp,t=20)
        if t.returncode:
            out=(t.stdout+t.stderr).strip(); log('xray config test fail:',out[-400:]); os.remove(tmp)
            msg='Xray did not accept the new settings: '+(out.splitlines() or ['unknown error'])[-1][-160:]
            XBAD[0],XBAD[1]=h,msg; return msg
        try: os.chown(XLOG,nu,g); os.chmod(XLOG,0o640)
        except OSError: pass
        ch=hashlib.sha256((rd(c)+rd(k)).encode()).hexdigest(); live=False
        if not force:
            try: live=xray_live(XCUR[0],cfg,ch)
            except Exception as e: log('xray live update error:',repr(e))
        os.replace(tmp,XD+'/config.json')
        if not live: collect(); run('systemctl','restart','xray'); log('xray config updated, active users:',len(cl))
        XHASH[0]=h; XCUR[0]=cfg; XCUR[1]=ch

# ---------- collect + enforce ----------
def hist30(u):
    h=u.get('hist') or {}; t=datetime.date.today()
    return [[d,h.get(d,[0,0])[0],h.get(d,[0,0])[1]] for d in ((t-datetime.timedelta(days=i)).isoformat() for i in range(29,-1,-1))]
UACC={}; ULAST=[0.0]
def collect(flush=False):
    ssh_collect(); xs=xstats(); xstats_in(); now=time.time()
    try: ov_poll()
    except Exception as e: log('openvpn poll:',repr(e))
    try: hy_poll()
    except Exception as e: log('hysteria poll:',repr(e))
    try: wg_poll()
    except Exception as e: log('wireguard poll:',repr(e))
    op=dict(OVPEND); OVPEND.clear(); hp_=dict(HYPEND); HYPEND.clear(); wp_=dict(WGPEND); WGPEND.clear()
    tr_proto('Hysteria2',sum(v['up'] for v in hp_.values()),sum(v['down'] for v in hp_.values()))
    tr_proto('WireGuard',sum(v['up'] for v in wp_.values()),sum(v['down'] for v in wp_.values()))
    tr_proto('SSH',sum(v['up'] for v in PEND.values()),sum(v['down'] for v in PEND.values()))
    tr_proto('OpenVPN',sum(v['up'] for v in op.values()),sum(v['down'] for v in op.values()))
    for n,v in xs.items():
        if v['up'] or v['down']: XACT[n]=now
    tick={}
    # add up usage in memory and write users.json at most every 30 s (many users = big file)
    for uid,v in list(PEND.items()):
        try: n=pwd.getpwuid(uid).pw_name
        except (KeyError,TypeError): continue
        if v['up'] or v['down']:
            e=UACC.setdefault(n,[0,0]); e[0]+=v['up']; e[1]+=v['down']; t_=tick.setdefault(n,[0,0]); t_[0]+=v['up']; t_[1]+=v['down']
    PEND.clear()
    for src in (xs,op,hp_,wp_):
        for n,v in src.items():
            if v and (v['up'] or v['down']):
                e=UACC.setdefault(n,[0,0]); e[0]+=v['up']; e[1]+=v['down']; t_=tick.setdefault(n,[0,0]); t_[0]+=v['up']; t_[1]+=v['down']
    # live speed per user (bytes per second over the last collect) and when traffic was last seen
    dt=now-SPDT[0] if SPDT[0] else 0
    if not SPDT[0] or dt>=3:
        SPDT[0]=now; SPD.clear()
        if dt<120: SPD.update({n:[int(v[0]/dt),int(v[1]/dt)] for n,v in tick.items()} if dt else {})
    for n in tick: LSEEN[n]=int(now)
    if not UACC or (not flush and now-ULAST[0]<30): return
    with UL:
        acc=dict(UACC); UACC.clear(); ULAST[0]=now; us=uload(); ch=False
        for u in us:
            z=acc.get(u['name'])
            if not z: continue
            u['up']+=z[0]; u['down']+=z[1]; u['seen']=int(now); ch=True
            if u.get('fdays'):
                u['exp']=(datetime.date.today()+datetime.timedelta(days=u['fdays'])).isoformat(); u['fdays']=0; setexp(u['name'],u['exp']); log('first use, expiry starts:',u['name'],u['exp'])
            h=u.setdefault('hist',{}); e=h.setdefault(today(),[0,0]); e[0]+=z[0]; e[1]+=z[1]
            if len(h)>31:
                for k in sorted(h)[:-31]: h.pop(k)
        if ch: usave(us)
def enforce():
    with UL:
        us=uload(); t=today(); ss=None; ch=False; ym=t[:7]
        for u in us:
            rd_=int(u.get('rday',0) or 0)
            if rd_ and int(t[8:10])>=rd_ and u.get('lreset')!=ym:
                u['up']=u['down']=0; u['lreset']=ym; ch=True; log('monthly reset:',u['name'])
            act=ustate(u,t)=='active' and hassh(u)
            if not act and not u.get('lk'):
                run('usermod','-L',u['name']); run('pkill','-KILL','-u',u['name']); u['lk']=True; ch=True
            elif act and u.get('lk'):
                run('usermod','-U',u['name']); u['lk']=False; ch=True
            elif not act:
                ss=ss if ss is not None else sessions()
                if ss.get(u['name']): run('pkill','-KILL','-u',u['name'])
        if ch: usave(us)
        try: ov_enforce(us)
        except Exception as e: log('openvpn enforce:',repr(e))
        try: hy_enforce(us)
        except Exception as e: log('hysteria enforce:',repr(e))
        try:
            if any([wg_fill(u,us) for u in us if haswg(u)]): usave(us)
            wg_enforce(us)
        except Exception as e: log('wireguard enforce:',repr(e))
# ---------- Xray access log: online IPs, device limit ----------
SPD={}; SPDT=[0]; LSEEN={}
IPSEEN={}; XOFF=[None]; WIN=60; BANS={}; BANSET=[None]; BANT=120
LRE=re.compile(r'from (?:tcp:|udp:)?\[?([0-9A-Fa-f.:]+?)\]?:\d+ accepted .*?email: (\S+)')
def xlog_read():
    try: sz=os.path.getsize(XLOG)
    except OSError: return
    if XOFF[0] is None or sz<XOFF[0]: XOFF[0]=sz if XOFF[0] is None else 0
    if sz>XOFF[0]:
        with open(XLOG,'rb') as f:
            f.seek(XOFF[0]); data=f.read(min(sz-XOFF[0],8<<20)); XOFF[0]+=len(data)
        now=time.time()
        for l in data.decode('utf-8','replace').splitlines():
            m=LRE.search(l)
            if m:
                ip,n=m[1],m[2]; e=IPSEEN.setdefault(n,{}).get(ip)
                IPSEEN[n][ip]=[e[0] if e else now,now]
    if sz>20<<20:
        try: open(XLOG,'w').close(); XOFF[0]=0
        except OSError: pass
    cut=time.time()-WIN
    for n in list(IPSEEN):
        IPSEEN[n]={ip:v for ip,v in IPSEEN[n].items() if v[1]>=cut}
        if not IPSEEN[n]: IPSEEN.pop(n)
XONW=35
def xon(n): return time.time()-XACT.get(n,0)<XONW
def xips_on(n): return xips(n) if xon(n) else []
def xips(n):
    now=time.time(); return [{'ip':ip,'ago':int(now-v[1]),'ban':int(max(0,BANS.get(ip,0)-now)),'shared':shared(ip,n)} for ip,v in sorted(IPSEEN.get(n,{}).items(),key=lambda x:x[1][0])]
def bans_apply(force=False):
    now=time.time()
    for ip in [ip for ip,t in BANS.items() if t<=now or ip.startswith('127.') or ip=='::1']: BANS.pop(ip)
    cur=tuple(sorted(BANS))
    if (cur==BANSET[0] and not force) or not shutil.which('iptables'): return
    xp=[str(p) for p in xray_ports()]; chunks=[','.join(xp[i:i+15]) for i in range(0,len(xp),15)]
    for f in FAM:
        run(f,'-w','-N','REXUI_BAN'); run(f,'-w','-F','REXUI_BAN')
        if run(f,'-w','-C','INPUT','-j','REXUI_BAN').returncode: run(f,'-w','-I','INPUT','1','-j','REXUI_BAN')
        for ip in cur:
            if (':' in ip)==(f=='ip6tables'):
                for ports in chunks: run(f,'-w','-A','REXUI_BAN','-s',ip,'-p','tcp','-m','multiport','--dports',ports,'-j','REJECT','--reject-with','tcp-reset')
    BANSET[0]=cur
def shared(ip,n): return any(ip in v for m,v in IPSEEN.items() if m!=n)
def kick(n):
    ov_kill(n); hy_kick(n); wg_kick(n); run('pkill','-KILL','-u',n); now=time.time()
    for ip in list(IPSEEN.get(n,{})):
        if not shared(ip,n): BANS[ip]=max(BANS.get(ip,0),now+60)
    IPSEEN.pop(n,None); bans_apply()
def devices():
    ss=sessions_full(); now=time.time()
    for u in uload():
        lim=int(u.get('dev',0) or 0); n=u['name']
        if lim<=0: continue
        s=sorted(ss.get(n,[]))
        for _,pid in s[lim:]: run('kill','-9',str(pid))
        ips=sorted(IPSEEN.get(n,{}).items(),key=lambda x:x[1][0])
        for ip,_ in ips[lim:]:
            if BANS.get(ip,0)<now and not shared(ip,n): BANS[ip]=now+BANT; log('device limit: blocked',ip,'for',n)
    bans_apply()
    try: ov_devices(uload())
    except Exception as e: log('openvpn devices:',repr(e))
def online():
    ss=sessions(); si=ssh_ips(); out=[]
    for u in uload():
        n=u['name']; ips=xips_on(n); s=ss.get(n,0); ov=[{'ip':c['ip'],'since':c['since']} for c in OVON.get(n,[])]; hy=HYON.get(n,0); wg=WGON.get(n)
        if s or ips or ov or hy or wg: out.append({'name':n,'ssh':s,'sips':si.get(n,[]),'ips':ips,'ov':ov,'hy':hy,'wg':wg['ip'] if wg else '','dev':u.get('dev',0),'kind':kind(u)})
    return out

# ---------- Where online users connect from (map on the Online page) ----------
GEOF=T+'/geo.json'; GEO={}; GEOAPI=os.environ.get('REXUI_GEOAPI','http://ip-api.com/batch'); GEOL=threading.Lock(); SHAREAL={}
def geo_pub(ip):
    import ipaddress
    try: return ipaddress.ip_address(ip).is_global
    except ValueError: return False
def geo_conns():
    """[(user, kind, ip, how)] for everyone online now."""
    out=[]
    for x in online():
        n=x['name']
        for ip in x.get('sips') or []: out.append((n,x['kind'],ip,'SSH'))
        for i in x.get('ips') or []: out.append((n,x['kind'],i['ip'],'V2Ray'))
        for o in x.get('ov') or []: out.append((n,x['kind'],o['ip'],'OpenVPN'))
        if x.get('wg'): out.append((n,x['kind'],x['wg'],'WireGuard'))
        if x.get('hy') and not any(c[0]==n for c in out): out.append((n,x['kind'],'','UDP'))
    return out
def geo_fetch():
    """Look up new IPs (ip-api.com, up to 100 per call). Results are kept 7 days."""
    if not GEOL.acquire(blocking=False): return
    try:
        if not GEO:
            try: GEO.update(json.loads(rd(GEOF) or '{}'))
            except Exception: pass
        now=time.time(); want=[ip for ip in {c[2] for c in geo_conns()} if geo_pub(ip) and now-GEO.get(ip,{}).get('t',0)>7*86400][:100]
        if not want: return
        rq=urllib.request.Request(GEOAPI+'?fields=status,country,countryCode,city,lat,lon,isp,org,query',data=json.dumps(want).encode(),headers={'Content-Type':'application/json','User-Agent':'ReXUI'})
        with urllib.request.urlopen(rq,timeout=15) as r: res=json.loads(r.read())
        for g in res:
            if g.get('status')=='success':
                GEO[g['query']]={'cc':g.get('countryCode',''),'country':g.get('country',''),'city':g.get('city',''),'lat':g.get('lat'),'lon':g.get('lon'),
                                 'isp':(g.get('isp') or g.get('org') or '')[:40],'cdn':'cloudflare' in ((g.get('isp') or '')+(g.get('org') or '')).lower(),'t':int(now)}
        for ip in [k for k,v in GEO.items() if now-v.get('t',0)>30*86400]: GEO.pop(ip,None)
        wjson(GEOF,GEO,0o600)
    except Exception as e: log('geo:',str(e)[:100])
    finally: GEOL.release()
def geo_km(a,b):
    import math
    p1,p2=math.radians(a['lat']),math.radians(b['lat']); dl=math.radians(b['lon']-a['lon'])
    return 6371*math.acos(max(-1,min(1,math.sin(p1)*math.sin(p2)+math.cos(p1)*math.cos(p2)*math.cos(dl))))
def geo_view():
    if not GEO:
        try: GEO.update(json.loads(rd(GEOF) or '{}'))
        except Exception: pass
    us={}; miss=False
    for n,k,ip,how in geo_conns():
        g=GEO.get(ip) if ip else None
        if ip and geo_pub(ip) and not g: miss=True
        e=us.setdefault(n,{'name':n,'kind':k,'conns':[]})
        e['conns'].append(dict({'ip':ip,'how':how,'local':bool(ip) and not geo_pub(ip)},**({k_:g[k_] for k_ in ('cc','country','city','lat','lon','isp','cdn')} if g else {})))
    al=[]
    for e in us.values():
        L=[c for c in e['conns'] if c.get('lat') is not None and not c.get('cdn')]; far=0
        for i in range(len(L)):
            for j in range(i+1,len(L)): far=max(far,geo_km(L[i],L[j]))
        if far>150:
            cs=sorted({c['city'] or c['country'] for c in L}); e['share']=int(far); al.append({'name':e['name'],'places':cs,'km':int(far)})
    if miss: threading.Thread(target=geo_fetch,daemon=True).start()
    return {'ok':1,'users':list(us.values()),'alerts':al,'pending':miss}
def geo_alerts():
    """Telegram message when one account is used from places far apart (at most once in 6 hours per user)."""
    s=sload()
    if not s.get('tgshare'): return
    now=time.time()
    for a in geo_view()['alerts']:
        if now-SHAREAL.get(a['name'],0)>6*3600:
            SHAREAL[a['name']]=now; tg_send('⚠️ Sharing? "%s" is connected from %s at the same time (%d km apart).'%(a['name'],' and '.join(a['places'][:3]),a['km']),s)
# ---------- OpenVPN (TCP, two ports) + Squid HTTP proxy ----------
OVD=T+'/ovpn'; OVCL=OVD+'/clients'; OVBIN='/usr/sbin/openvpn'; SQC='/etc/squid/squid.conf'
OVNET='10.8.0.0/15'; OVL=threading.Lock(); OVPREV={}; OVPEND={}; OVON={}; OVINIT=set(); OVVER=[None]
OVBASE=('rx1194','rx110')
def ovcores(): return max(1,min(os.cpu_count() or 1,4))
def ovi():
    """(instance, listen port, subnet, public port). One OpenVPN process uses one CPU core, so each public port gets
    one instance per core (up to 4). Extra instances listen on internal ports and get new connections from iptables."""
    out=[]; i=0
    for base,key,dflt in (('rx1194','OVPN1_PORT',1194),('rx110','OVPN2_PORT',110)):
        pp=P(key,dflt)
        for j in range(ovcores()):
            out.append((base if j==0 else '%s-%d'%(base,j),pp if j==0 else 19400+i,'10.%d.%d.0'%(8+i//16,(i%16)*16),pp)); i+=1
    return out
def ovports():
    r=[]
    for _,_,_,pp in ovi():
        if pp not in r: r.append(pp)
    return r
def ovports_u(): return ([443] if os.path.exists(T+'/h443.on') else [])+ovports()
def ov_on(): return os.path.exists(OVBIN) or bool(shutil.which('openvpn'))
def hasov(u): return kind(u)=='ovpn'
OVCNF='''[req]
distinguished_name=dn
prompt=no
[dn]
CN=ReXUI
[ca]
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
[srv]
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
[cli]
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=clientAuth
'''
OVUP='''#!/bin/sh
# ReXUI: fair share per user on the tunnel (CAKE per client address), fq_codel when CAKE is missing
tc qdisc replace dev "$1" root cake besteffort dsthost 2>/dev/null || tc qdisc replace dev "$1" root fq_codel 2>/dev/null
exit 0
'''
OVCONNECT='''#!/bin/sh
# ReXUI: only users in the allow list (name + certificate serial) can connect
exec awk -v c="$common_name" -v s="$tls_serial_0" '$1==c && (s=="" || $2==s){f=1} END{exit !f}' %s/allow
'''%OVD
def ossl(*a):
    r=run('openssl',*a,t=90)
    if r.returncode: raise Err('openssl: '+((r.stderr or '').strip().splitlines() or ['failed'])[-1][-160:])
    return r
def ov_issue(cn,ext,crt,key,days=3650):
    sr=secrets.randbits(62)|(1<<62); tmp=OVD+'/tmp-'+secrets.token_hex(4)
    try:
        ossl('req','-new','-newkey','rsa:2048','-nodes','-keyout',tmp+'.key','-out',tmp+'.csr','-subj','/CN='+cn,'-config',OVD+'/openssl.cnf')
        ossl('x509','-req','-in',tmp+'.csr','-CA',OVD+'/ca.crt','-CAkey',OVD+'/ca.key','-set_serial',str(sr),'-days',str(days),'-sha256',
             '-extfile',OVD+'/openssl.cnf','-extensions',ext,'-out',tmp+'.crt')
        os.chmod(tmp+'.key',0o600); os.replace(tmp+'.key',key); os.replace(tmp+'.crt',crt)
    finally:
        for x in ('.key','.csr','.crt'):
            try: os.remove(tmp+x)
            except OSError: pass
    return sr
def ov_tc():
    k=secrets.token_hex(256)
    return '#\n# 2048 bit OpenVPN static key\n#\n-----BEGIN OpenVPN Static key V1-----\n'+'\n'.join(k[i:i+32] for i in range(0,512,32))+'\n-----END OpenVPN Static key V1-----\n'
def ov_pki():
    os.makedirs(OVCL,exist_ok=True); os.chmod(OVD,0o700)
    if rd(OVD+'/openssl.cnf')!=OVCNF:
        with open(OVD+'/openssl.cnf','w') as f: f.write(OVCNF)
    if not (os.path.exists(OVD+'/ca.crt') and os.path.exists(OVD+'/ca.key')):
        for f in os.listdir(OVCL): os.remove(os.path.join(OVCL,f))
        for f in ('server.crt','server.key'):
            try: os.remove(OVD+'/'+f)
            except OSError: pass
        ossl('req','-x509','-newkey','rsa:2048','-nodes','-keyout',OVD+'/ca.key','-out',OVD+'/ca.crt','-days','7300','-sha256',
             '-subj','/CN=ReXUI CA '+secrets.token_hex(3),'-config',OVD+'/openssl.cnf','-extensions','ca')
        os.chmod(OVD+'/ca.key',0o600); log('openvpn: new certificate authority')
    if not (os.path.exists(OVD+'/server.crt') and os.path.exists(OVD+'/server.key')):
        ov_issue('ReXUI server','srv',OVD+'/server.crt',OVD+'/server.key',7300)
    if not os.path.exists(OVD+'/tc.key'):
        with open(OVD+'/tc.key','w') as f: f.write(ov_tc())
        os.chmod(OVD+'/tc.key',0o600)
def ov_ver():
    if OVVER[0] is None:
        m=re.search(r'OpenVPN (\d+)\.(\d+)',run(shutil.which('openvpn') or OVBIN,'--version',t=10).stdout or '')
        OVVER[0]=(int(m[1]),int(m[2])) if m else (2,5)
    return OVVER[0]
def ov_server_conf(name,port,net,idx=0):
    v=ov_ver()
    L=['# ReXUI OpenVPN (%s). Made by the panel, changes are overwritten.'%name,'port %d'%port,'proto tcp','dev rxtun%d'%idx,'dev-type tun','topology subnet',
       'server %s 255.255.240.0'%net,'ca %s/ca.crt'%OVD,'cert %s/server.crt'%OVD,'key %s/server.key'%OVD,'dh none','tls-crypt %s/tc.key'%OVD,
       'tls-version-min 1.2','remote-cert-tls client',
       'push "redirect-gateway def1 bypass-dhcp"','push "dhcp-option DNS 1.1.1.1"','push "dhcp-option DNS 8.8.8.8"',
       'keepalive 10 30','duplicate-cn','persist-key','persist-tun','tcp-nodelay','max-clients 2000','txqueuelen 1000','sndbuf 0','rcvbuf 0',
       'script-security 2','client-connect %s/connect.sh'%OVD,'up %s/up.sh'%OVD,'management %s/%s.sock unix'%(OVD,name),'verb 2','mute 20']
    if v>=(2,5): L+=['data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305:AES-256-CBC','data-ciphers-fallback AES-256-CBC']
    else: L+=['cipher AES-256-GCM','ncp-ciphers AES-256-GCM:AES-128-GCM']
    return '\n'.join(L)+'\n'
def ov_squid_conf():
    return '\n'.join(['# ReXUI: HTTP proxy only for OpenVPN (CONNECT to this server, OpenVPN ports). Made by the panel.',
        'http_port %d'%P('SQUID_PORT',3128),'acl rx_dst dst 127.0.0.1','acl rx_ports port '+' '.join(map(str,sorted(set(ovports()+[443])))),'acl CONNECT method CONNECT',
        'http_access allow CONNECT rx_dst rx_ports','http_access deny all','via off','forwarded_for delete','cache deny all',
        'access_log none','cache_log /dev/null','max_filedescriptors 65535','client_idle_pconn_timeout 1 minute','coredump_dir /var/spool/squid','visible_hostname rexui','shutdown_lifetime 1 seconds'])+'\n'
def wtext(path,txt,mode=0o600):
    if rd(path)==txt: return False
    with open(path+'.tmp','w') as f: f.write(txt)
    os.chmod(path+'.tmp',mode); os.replace(path+'.tmp',path); return True
def ov_setup(restart=True):
    """Certificates, server configs, connect script, allow list and Squid config. Restarts only what changed."""
    if not ov_on(): return
    with OVL:
        ov_pki()
        wtext(OVD+'/connect.sh',OVCONNECT,0o700); wtext(OVD+'/up.sh',OVUP,0o700)
        if not os.path.exists(OVD+'/allow'): wtext(OVD+'/allow','')
        names=set()
        for idx,(name,port,net,_) in enumerate(ovi()):
            names.add(name); new=not os.path.exists(OVD+'/'+name+'.conf')
            if wtext(OVD+'/'+name+'.conf',ov_server_conf(name,port,net,idx)) and restart:
                if name in OVBASE or not new: run('systemctl','restart','rexui-ovpn@'+name)
            if name not in OVBASE and restart and (new or run('systemctl','is-active','--quiet','rexui-ovpn@'+name).returncode):
                run('systemctl','enable','--now','rexui-ovpn@'+name)
        for f in os.listdir(OVD):
            m=re.fullmatch(r'(rx(?:1194|110)-\d+)\.conf',f)
            if m and m[1] not in names:
                run('systemctl','disable','--now','rexui-ovpn@'+m[1]); os.remove(OVD+'/'+f)
        if os.path.isdir('/etc/squid'):
            if os.path.exists(SQC) and not os.path.exists(SQC+'.orig') and 'ReXUI' not in rd(SQC): shutil.copyfile(SQC,SQC+'.orig')
            if wtext(SQC,ov_squid_conf(),0o644) and restart: run('systemctl','restart','squid')
    ov_allow(); ov_net(True)
def ov_net(force=False):
    if not ov_on() or not shutil.which('iptables'): return
    if not force and rd('/proc/sys/net/ipv4/ip_forward').strip()=='1' and run('iptables','-w','-C','FORWARD','-j','REXUI_FWD').returncode==0 and run('iptables','-w','-t','nat','-C','POSTROUTING','-j','REXUI_NAT').returncode==0: return
    if rd('/proc/sys/net/ipv4/ip_forward').strip()!='1': run('sysctl','-qw','net.ipv4.ip_forward=1')
    wtext('/etc/sysctl.d/99-rexui-ovpn.conf','net.ipv4.ip_forward=1\n',0o644)
    i=lambda *a:run('iptables','-w',*a)
    i('-N','REXUI_FWD'); i('-F','REXUI_FWD'); i('-t','nat','-N','REXUI_NAT'); i('-t','nat','-F','REXUI_NAT')
    i('-A','REXUI_FWD','-s',OVNET,'-d',OVNET,'-j','DROP')
    if sload()['b25']: i('-A','REXUI_FWD','-s',OVNET,'-p','tcp','-m','multiport','--dports','25,465,587','-j','REJECT')
    i('-A','REXUI_FWD','-s',OVNET,'-p','tcp','--tcp-flags','SYN,RST','SYN','-j','TCPMSS','--clamp-mss-to-pmtu')
    i('-A','REXUI_FWD','-s',OVNET,'-j','ACCEPT'); i('-A','REXUI_FWD','-d',OVNET,'-m','conntrack','--ctstate','RELATED,ESTABLISHED','-j','ACCEPT')
    i('-t','nat','-A','REXUI_NAT','-s',OVNET,'!','-d',OVNET,'-j','MASQUERADE')
    # spread new OpenVPN connections over the instances of each public port (one per CPU core)
    i('-t','nat','-N','REXUI_OVLB'); i('-t','nat','-F','REXUI_OVLB'); i('-N','REXUI_OVIN'); i('-F','REXUI_OVIN')
    grp={}
    for name,lp,_,pp in ovi(): grp.setdefault(pp,[]).append(lp)
    for pp,lps in grp.items():
        k=len(lps)
        for j in range(1,k):
            i('-t','nat','-A','REXUI_OVLB','-p','tcp','-m','addrtype','--dst-type','LOCAL','--dport',str(pp),'-m','statistic','--mode','random',
              '--probability','%.5f'%(1.0/(k-j+1)),'-j','REDIRECT','--to-ports',str(lps[j]))
            i('-A','REXUI_OVIN','-p','tcp','--dport',str(lps[j]),'-m','conntrack','--ctstate','DNAT','-j','ACCEPT')
    for ch_ in ('PREROUTING','OUTPUT'):
        if i('-t','nat','-C',ch_,'-j','REXUI_OVLB').returncode: i('-t','nat','-I',ch_,'1','-j','REXUI_OVLB')
    if i('-C','INPUT','-j','REXUI_OVIN').returncode: i('-I','INPUT','1','-j','REXUI_OVIN')
    if i('-C','FORWARD','-j','REXUI_FWD').returncode: i('-I','FORWARD','1','-j','REXUI_FWD')
    if i('-t','nat','-C','POSTROUTING','-j','REXUI_NAT').returncode: i('-t','nat','-I','POSTROUTING','1','-j','REXUI_NAT')
def ov_net_purge():
    i=lambda *a:run('iptables','-w',*a)
    while i('-D','FORWARD','-j','REXUI_FWD').returncode==0: pass
    while i('-t','nat','-D','POSTROUTING','-j','REXUI_NAT').returncode==0: pass
    for ch_ in ('PREROUTING','OUTPUT'):
        while i('-t','nat','-D',ch_,'-j','REXUI_OVLB').returncode==0: pass
    while i('-D','INPUT','-j','REXUI_OVIN').returncode==0: pass
    i('-t','nat','-F','REXUI_OVLB'); i('-t','nat','-X','REXUI_OVLB'); i('-F','REXUI_OVIN'); i('-X','REXUI_OVIN')
    i('-F','REXUI_FWD'); i('-X','REXUI_FWD'); i('-t','nat','-F','REXUI_NAT'); i('-t','nat','-X','REXUI_NAT')
def ov_cert(name):
    """Make sure the user has a client certificate. Returns (cert, key)."""
    if not ov_on(): raise Err('OpenVPN is not installed on this server. Run the installer again to add it.')
    with UL:
        us=uload(); u=next((x for x in us if x['name']==name),None)
        if not u or not hasov(u): raise Err('This user has no OpenVPN account')
        c,k=OVCL+'/'+name+'.crt',OVCL+'/'+name+'.key'
        if not (u.get('ovs') and os.path.exists(c) and os.path.exists(k)):
            with OVL: ov_pki(); u['ovs']=str(ov_issue(name,'cli',c,k))
            usave(us); log('openvpn: certificate made for',name)
    ov_allow(); return rd(c),rd(k)
def ov_forget(name):
    for x in ('.crt','.key'):
        try: os.remove(OVCL+'/'+name+x)
        except OSError: pass
def ov_allow(us=None):
    if not ov_on() or not os.path.isdir(OVD): return
    us=us if us is not None else uload(); t=today()
    txt=''.join('%s %s\n'%(u['name'],u['ovs']) for u in us if hasov(u) and u.get('ovs') and ustate(u,t)=='active')
    with OVL: wtext(OVD+'/allow',txt)
def ov_cmd(name,cmd):
    """Send one command to the OpenVPN management socket and wait for its full reply.
    'quit' must not be sent in the same write: OpenVPN drops the queued reply when it closes."""
    p=OVD+'/'+name+'.sock'
    if not os.path.exists(p): return ''
    multi=cmd.startswith('status')
    try:
        s=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM); s.settimeout(4); s.connect(p); b=b''
        while b'\n' not in b:
            c=s.recv(4096)
            if not c: break
            b+=c
        b=b.split(b'\n',1)[1] if b.startswith(b'>INFO') and b'\n' in b else b
        s.sendall((cmd+'\n').encode())
        while len(b)<(8<<20):
            t=b.replace(b'\r',b'')
            if multi and (t.startswith(b'END\n') or b'\nEND\n' in t): break
            if not multi and re.search(rb'(^|\n)(SUCCESS|ERROR):[^\n]*\n',t): break
            c=s.recv(65536)
            if not c: break
            b+=c
        try: s.sendall(b'quit\n')
        except OSError: pass
        s.close(); return b.decode('utf-8','replace')
    except OSError: return ''
def ov_clients(name):
    hdr=None; out=[]
    for l in ov_cmd(name,'status 3').splitlines():
        f=l.rstrip('\r').split('\t')
        if len(f)>2 and f[0]=='HEADER' and f[1]=='CLIENT_LIST': hdr=f[2:]
        elif f[0]=='CLIENT_LIST' and hdr:
            r=dict(zip(hdr,f[1:]))
            try: out.append({'name':r['Common Name'],'ip':r['Real Address'].rsplit(':',1)[0],'rx':int(r['Bytes Received']),'tx':int(r['Bytes Sent']),
                             'since':int(r.get('Connected Since (time_t)') or 0),'cid':r.get('Client ID',''),'inst':name})
            except (KeyError,ValueError): pass
    return out
def ov_poll():
    if not ov_on(): return
    on={}; seen=set()
    for name,_,_,_ in ovi():
        cl=ov_clients(name)
        for c in cl:
            k=(name,c['cid'],c['since']); seen.add(k); p=OVPREV.get(k)
            if p is not None or name in OVINIT:
                up,dn=c['rx']-(p[0] if p else 0),c['tx']-(p[1] if p else 0)
                if up>0 or dn>0: e=OVPEND.setdefault(c['name'],{'up':0,'down':0}); e['up']+=max(0,up); e['down']+=max(0,dn)
            OVPREV[k]=(c['rx'],c['tx']); on.setdefault(c['name'],[]).append(c)
        if os.path.exists(OVD+'/'+name+'.sock'): OVINIT.add(name)
    for k in [k for k in OVPREV if k not in seen]: OVPREV.pop(k)
    OVON.clear(); OVON.update(on)
def ov_kill(name,cid=None,inst=None):
    for n,_,_,_ in ovi():
        if inst and n!=inst: continue
        ov_cmd(n,'client-kill %s'%cid if cid else 'kill %s'%name)
def ov_enforce(us):
    ov_allow(us); t=today()
    for u in us:
        n=u['name']
        if OVON.get(n) and (not hasov(u) or ustate(u,t)!='active'): ov_kill(n); OVON.pop(n,None)
    known={u['name'] for u in us}
    for n in [n for n in OVON if n not in known]: ov_kill(n); OVON.pop(n,None)
def ov_devices(us):
    for u in us:
        lim=int(u.get('dev',0) or 0); cl=OVON.get(u['name'],[])
        if lim>0 and len(cl)>lim:
            # keep the newest sessions: a reconnecting app leaves its old session behind until keepalive ends
            for c in sorted(cl,key=lambda x:(x['since'],str(x['cid'])),reverse=True)[lim:]: ov_kill(u['name'],c['cid'],c['inst']); log('device limit: openvpn',u['name'],c['ip'])
def ov_file(u,port,host,proxy):
    s=sload(); a=pub_addr(s)
    if port not in ovports_u(): raise Err('Unknown OpenVPN port')
    host=hostok(host,'Host'); crt,key=ov_cert(u['name'])
    L=['# %s OpenVPN · %s · TCP %d%s'%(s['brand'] or 'ReXUI',u['name'],port,' via HTTP proxy' if proxy else ''),'client','dev tun','proto tcp']
    if proxy:
        L+=['remote 127.0.0.1 %d'%port,'http-proxy %s %d'%(a,P('SQUID_PORT',3128))]
        if host: L+=['http-proxy-option CUSTOM-HEADER Host %s'%host,'http-proxy-option CUSTOM-HEADER X-Online-Host %s'%host,'http-proxy-option CUSTOM-HEADER X-Forward-Host %s'%host]
    else: L+=['remote %s %d'%(a,port)]
    L+=['resolv-retry infinite','nobind','persist-key','persist-tun','remote-cert-tls server','cipher AES-256-GCM','connect-retry 3 10','verb 3',
        '<ca>',rd(OVD+'/ca.crt').strip(),'</ca>','<cert>',re.search(r'-----BEGIN CERTIFICATE-----[\s\S]+?-----END CERTIFICATE-----',crt)[0],'</cert>',
        '<key>',key.strip(),'</key>','<tls-crypt>',rd(OVD+'/tc.key').strip(),'</tls-crypt>']
    return ('\n'.join(L)+'\n').encode()
def ov_args(q):
    from urllib.parse import parse_qs
    q=parse_qs(q); g=lambda k,d='':(q.get(k) or [d])[0]
    try: port=int(g('port',str(ovports_u()[0])))
    except ValueError: raise Err('Unknown OpenVPN port')
    return port,g('host',sload()['ovhost']),g('proxy','1')!='0'
def ov_set(d):
    s=sload(); s['ovhost']=hostok(d.get('ovhost'),'Host'); wjson(SETF,s,0o600); return {'ok':1}
PEMRE=re.compile(r'-----BEGIN [A-Z ]+-----[A-Za-z0-9+/=\s]+-----END [A-Z ]+-----\s*')
OVFILES=('ca.crt','ca.key','server.crt','server.key','tc.key')
def ov_backup():
    if not all(os.path.exists(OVD+'/'+f) for f in OVFILES): return None
    o={f:rd(OVD+'/'+f) for f in OVFILES}; cl={}
    for u in uload():
        c,k=OVCL+'/'+u['name']+'.crt',OVCL+'/'+u['name']+'.key'
        if hasov(u) and u.get('ovs') and os.path.exists(c) and os.path.exists(k): cl[u['name']]=[rd(c),rd(k)]
    o['clients']=cl; return o
def ov_restore(o,names):
    if not isinstance(o,dict): return
    ok=lambda t:isinstance(t,str) and len(t)<20000 and PEMRE.fullmatch(t)
    tc=o.get('tc.key','')
    if not all(ok(o.get(f)) for f in OVFILES if f!='tc.key') or not (isinstance(tc,str) and 'OpenVPN Static key V1' in tc and len(tc)<4000): log('restore: openvpn certificates skipped'); return
    with OVL:
        os.makedirs(OVCL,exist_ok=True); os.chmod(OVD,0o700)
        for f in OVFILES: wtext(OVD+'/'+f,o[f],0o644 if f.endswith('.crt') else 0o600)
        for f in os.listdir(OVCL): os.remove(os.path.join(OVCL,f))
        for n,v in (o.get('clients') or {}).items():
            if n in names and isinstance(v,list) and len(v)==2 and ok(v[0]) and ok(v[1]):
                wtext(OVCL+'/'+n+'.crt',v[0],0o644); wtext(OVCL+'/'+n+'.key',v[1])
    if ov_on():
        ov_setup(); run('systemctl','restart','rexui-ovpn@rx1194','rexui-ovpn@rx110')
def ov_info(u):
    if not hasov(u): return None
    return {'on':ov_on(),'ports':ovports_u(),'proxy':P('SQUID_PORT',3128),'host':sload()['ovhost'],
            'sess':[{'ip':c['ip'],'since':c['since'],'port':dict((n,pp) for n,_,_,pp in ovi()).get(c['inst'],0)} for c in OVON.get(u['name'],[])]}

# ---------- Hysteria2 (UDP) ----------
HYD=T+'/hy2'; HYBIN='/usr/local/bin/hysteria'; HYL=threading.Lock(); HYON={}; HYPEND={}; HYH=['']; HYHOPS=[None]
HYAUTH=('127.0.0.1',10086); HYSTAT='127.0.0.1:10087'
def hy_on(): return os.path.exists(HYBIN)
def hashy(u): return kind(u)=='hy2'
def hyport(): return P('HY_PORT',443)
def hyhop():
    v=str(E.get('HY_HOP','20000-30000') or '').strip()
    m=re.fullmatch(r'(\d{1,5})-(\d{1,5})',v)
    if not m or v=='0': return None
    a,b=int(m[1]),int(m[2])
    return (a,b) if 1<=a<b<=65535 and not a<=hyport()<=b else None
def hy_secret(name):
    p=HYD+'/'+name
    v=rd(p).strip()
    if not re.fullmatch(r'[0-9a-f]{32}',v):
        v=secrets.token_hex(16); os.makedirs(HYD,exist_ok=True); os.chmod(HYD,0o700); wtext(p,v)
    return v
def hy_conf():
    s=sload(); L=['# ReXUI Hysteria2. Made by the panel, changes are overwritten.','listen: :%d'%hyport(),
       'tls:','  cert: %s/cert.crt'%HYD,'  key: %s/key.key'%HYD,'  sniGuard: disable',
       'auth:','  type: http','  http:','    url: http://%s:%d/%s/auth'%(HYAUTH[0],HYAUTH[1],hy_secret('auth.token')),
       'trafficStats:','  listen: %s'%HYSTAT,'  secret: %s'%hy_secret('stats.secret'),
       *(['bandwidth:','  up: %d mbps'%int(s['hy_bw']),'  down: %d mbps'%int(s['hy_bw'])] if int(s.get('hy_bw') or 0)>0 else []),
       'masquerade:','  type: string','  string:','    content: "404 page not found"','    statusCode: 404',
       'acl:','  inline:']
    L+=['    - reject(%s)'%x for x in ('127.0.0.0/8','10.0.0.0/8','172.16.0.0/12','192.168.0.0/16','169.254.0.0/16','100.64.0.0/10','::1/128','fc00::/7','fe80::/10')]
    if s['b25']: L+=['    - reject(all, tcp/25)','    - reject(all, tcp/465)','    - reject(all, tcp/587)']
    L+=['    - direct(all)','outbounds:','  - name: direct','    type: direct','    direct:','      mode: 46']
    return '\n'.join(L)+'\n'
def hy_setup(restart=True):
    """Config, certificate and port hopping. Restarts Hysteria only when something changed."""
    if not hy_on(): return
    with HYL:
        os.makedirs(HYD,exist_ok=True); os.chmod(HYD,0o700)
        c,k=CD+'/xray.crt',CD+'/xray.key'
        if not (os.path.exists(c) and os.path.exists(k)): c,k=XSC,XSK
        ch=wtext(HYD+'/cert.crt',rd(c),0o600)|wtext(HYD+'/key.key',rd(k),0o600)|wtext(HYD+'/config.yaml',hy_conf())
        if ch and restart: run('systemctl','restart','rexui-hy2')
    hy_hop(True)
def hy_hop(force=False):
    if not hy_on() or not shutil.which('iptables'): return
    h=hyhop(); key=(h,hyport())
    if not force and key==HYHOPS[0] and run('iptables','-w','-t','nat','-C','PREROUTING','-j','REXUI_HOP').returncode==0: return
    for f in FAM:
        i=lambda *a:run(f,'-w','-t','nat',*a)
        i('-N','REXUI_HOP'); i('-F','REXUI_HOP')
        if h: i('-A','REXUI_HOP','-p','udp','-m','addrtype','--dst-type','LOCAL','--dport','%d:%d'%h,'-j','REDIRECT','--to-ports',str(hyport()))
        if i('-C','PREROUTING','-j','REXUI_HOP').returncode: i('-I','PREROUTING','1','-j','REXUI_HOP')
    HYHOPS[0]=key
def hy_purge():
    for f in FAM:
        i=lambda *a:run(f,'-w','-t','nat',*a)
        while i('-D','PREROUTING','-j','REXUI_HOP').returncode==0: pass
        i('-F','REXUI_HOP'); i('-X','REXUI_HOP')
def hy_api(path,body=None):
    req=urllib.request.Request('http://'+HYSTAT+path,data=json.dumps(body).encode() if body is not None else None,
                               headers={'Authorization':hy_secret('stats.secret'),'Content-Type':'application/json'},method='POST' if body is not None else 'GET')
    try:
        with urllib.request.urlopen(req,timeout=4) as r: t=r.read()
        return json.loads(t) if t.strip() else {}
    except Exception: return None
def hy_set(d):
    try: v=int(float(d.get('hy_bw') or 0))
    except (TypeError,ValueError): raise Err('Speed must be a number')
    if not 0<=v<=10000: raise Err('Speed must be 0 to 10000 Mbps')
    s=sload(); s['hy_bw']=v; wjson(SETF,s,0o600); hy_setup(); return {'ok':1}
def hy_poll():
    if not hy_on(): return
    t=hy_api('/traffic?clear=1')
    if isinstance(t,dict):
        for n,v in t.items():
            try: up,dn=int(v.get('tx',0)),int(v.get('rx',0))
            except (TypeError,ValueError,AttributeError): continue
            if up or dn: e=HYPEND.setdefault(n,{'up':0,'down':0}); e['up']+=up; e['down']+=dn
    o=hy_api('/online')
    HYON.clear()
    if isinstance(o,dict): HYON.update({n:int(c) for n,c in o.items() if isinstance(c,int) and c>0})
def hy_kick(*names):
    if hy_on() and names: hy_api('/kick',list(names))
def hy_enforce(us):
    t=today(); bad=[u['name'] for u in us if HYON.get(u['name']) and (not hashy(u) or ustate(u,t)!='active')]
    known={u['name'] for u in us}; bad+=[n for n in HYON if n not in known]
    bad+=[u['name'] for u in us if u['name'] not in bad and int(u.get('dev',0) or 0) and HYON.get(u['name'],0)>int(u['dev'])]
    if bad: hy_kick(*bad); [HYON.pop(n,None) for n in bad]
HYFAIL={}
def hy_auth(d):
    """Called by Hysteria for every new client. auth = "username:password"."""
    a=str(d.get('auth','')); ip=str(d.get('addr','')).rsplit(':',1)[0].strip('[]'); now=time.time()
    f=HYFAIL.get(ip,[0,0])
    if now>f[1]: f=[0,0]
    if f[0]>=20: return {'ok':False}
    n,_,p=a.partition(':')
    u=next((x for x in uload() if x['name']==n),None)
    ok=bool(u) and hashy(u) and bool(p) and hmac.compare_digest(p.encode(),str(u.get('pw','')).encode()) and ustate(u)=='active'
    if not ok:
        HYFAIL[ip]=[f[0]+1,now+600]; return {'ok':False}
    lim=int(u.get('dev',0) or 0)
    if lim and HYON.get(n,0)>=lim: return {'ok':False}
    HYON[n]=HYON.get(n,0)+1
    return {'ok':True,'id':n}
class HyAuthH(BaseHTTPRequestHandler):
    def log_message(self,*a): pass
    def do_POST(self):
        try:
            if self.path!='/%s/auth'%hy_secret('auth.token'): raise ValueError
            n=int(self.headers.get('Content-Length',0) or 0)
            if n>4096: raise ValueError
            r=hy_auth(json.loads(self.rfile.read(n) or b'{}'))
        except Exception: r={'ok':False}
        b=json.dumps(r).encode(); self.send_response(200 if r.get('ok') else 403)
        self.send_header('Content-Type','application/json'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
def hy_auth_server():
    class S(ThreadingHTTPServer): daemon_threads=True; allow_reuse_address=True
    try: S(HYAUTH,HyAuthH).serve_forever()
    except OSError as e: log('hysteria auth server:',e)
def hy_links(u,s=None):
    s=s or sload(); ci=certinfo(); a=pub_addr(s); A='['+a+']' if ':' in a else a; cn=ci['name'] if ci['src']!='self-signed' else ''
    sni=u.get('sni') or s['sni'] or ci['domain']
    ok=bool(cn) and bool(sni) and (sni==cn or (cn.startswith('*.') and sni.endswith(cn[1:])))
    q=('sni='+quote(sni)+'&' if sni else '')+('insecure=0' if ok else 'insecure=1'+('&pinSHA256='+cert_fp() if cert_fp() else ''))
    au=quote(u['name'],safe='')+':'+quote(u['pw'],safe='')
    out=[('Hysteria2','hysteria2://%s@%s:%d/?%s#%s'%(au,A,hyport(),q,cfgname(u,'hy2','Hysteria2',s)))]
    h=hyhop()
    if h: out.append(('Hysteria2 (port hopping)','hysteria2://%s@%s:%d,%d-%d/?%s#%s'%(au,A,hyport(),h[0],h[1],q,cfgname(u,'hy2-hop','Hysteria2 hop',s))))
    return out
def hy_info(u):
    if not hashy(u): return None
    h=hyhop(); return {'on':hy_on(),'port':hyport(),'hop':'%d-%d'%h if h else '','online':HYON.get(u['name'],0)}

# ---------- WireGuard (own user type) ----------
WGD=T+'/wg'; WGIF='rxwg'; WGNET='10.66.0.0/16'; WGL=threading.Lock(); WGPREV={}; WGPEND={}; WGON={}; WGKICK={}; WGST={'cfg':None}
def fail_clean():
    now=time.time()
    for D_ in (FAIL,HYFAIL,SPFAIL):
        for k in [k for k,v in list(D_.items()) if v[1] and v[1]<now]: D_.pop(k,None)
        if len(D_)>20000:
            for k in sorted(D_,key=lambda k:D_[k][1])[:len(D_)-20000]: D_.pop(k,None)
def wg_on(): return bool(shutil.which('wg')) and bool(shutil.which('ip'))
def haswg(u): return kind(u)=='wg'
def wgport(): return P('WG_PORT',51820)
# X25519 (RFC 7748), so keys can be made without the wg tool
_P25519=2**255-19
def _x25519(k,u):
    k=bytearray(k); k[0]&=248; k[31]&=127; k[31]|=64; k=int.from_bytes(k,'little'); x1=int.from_bytes(u,'little')%_P25519
    x2,z2,x3,z3,sw=1,0,x1,1,0
    for t in range(254,-1,-1):
        b=(k>>t)&1; sw^=b
        if sw: x2,x3,z2,z3=x3,x2,z3,z2
        sw=b; A=(x2+z2)%_P25519; AA=A*A%_P25519; B=(x2-z2)%_P25519; BB=B*B%_P25519; Ee=(AA-BB)%_P25519
        C=(x3+z3)%_P25519; Dd=(x3-z3)%_P25519; DA=Dd*A%_P25519; CB=C*B%_P25519
        x3=(DA+CB)**2%_P25519; z3=x1*(DA-CB)**2%_P25519; x2=AA*BB%_P25519; z2=Ee*(AA+121665*Ee)%_P25519
    if sw: x2,z2=x3,z3
    return (x2*pow(z2,_P25519-2,_P25519)%_P25519).to_bytes(32,'little')
def wg_keypair():
    k=bytearray(secrets.token_bytes(32)); k[0]&=248; k[31]&=127; k[31]|=64
    return base64.b64encode(bytes(k)).decode(),base64.b64encode(_x25519(bytes(k),(9).to_bytes(32,'little'))).decode()
def wg_pub(priv): return base64.b64encode(_x25519(base64.b64decode(priv),(9).to_bytes(32,'little'))).decode()
def wg_server():
    os.makedirs(WGD,exist_ok=True); os.chmod(WGD,0o700)
    k=rd(WGD+'/server.key').strip()
    try: ok=len(base64.b64decode(k,validate=True))==32
    except Exception: ok=False
    if not ok: k=wg_keypair()[0]; wtext(WGD+'/server.key',k+'\n')
    return k,wg_pub(k)
def wg_fill(u,us):
    """Gives a WireGuard user keys and an address once. Returns True when something was added."""
    ch=False
    if not u.get('wgk'):
        u['wgk'],u['wgp']=wg_keypair(); u['wgs']=base64.b64encode(secrets.token_bytes(32)).decode(); ch=True
    if not u.get('wgip'):
        used={x.get('wgip') for x in us}
        for i in range(2,65534):
            ip='10.66.%d.%d'%(i//256,i%256)
            if i%256 in (0,255) or ip in used: continue
            u['wgip']=ip; ch=True; break
        else: raise Err('No free WireGuard address left')
    return ch
def wg_conf(us=None):
    us=uload() if us is None else us; t=today(); now=time.time(); k,_=wg_server()
    L=['[Interface]','PrivateKey = '+k,'ListenPort = %d'%wgport()]
    for u in us:
        if haswg(u) and u.get('wgp') and u.get('wgip') and ustate(u,t)=='active' and WGKICK.get(u['name'],0)<now:
            L+=['','[Peer]','PublicKey = '+u['wgp']]+(['PresharedKey = '+u['wgs']] if u.get('wgs') else [])+['AllowedIPs = %s/32'%u['wgip']]
    return '\n'.join(L)+'\n'
def wg_up():
    """Creates the WireGuard interface and its firewall rules if they are missing."""
    if not wg_on(): return False
    with WGL:
        if run('ip','link','show',WGIF).returncode:
            run('modprobe','wireguard')
            r=run('ip','link','add',WGIF,'type','wireguard')
            if r.returncode:
                if not WGST.get('err'): log('wireguard: could not add the interface (no kernel support?):',r.stderr.strip()[-200:])
                WGST['err']=1; return False
            WGST['err']=0
            run('ip','address','add','10.66.0.1/16','dev',WGIF); run('ip','link','set','mtu','1420','up','dev',WGIF); WGST['cfg']=None
        wg_net(); return True
def wg_net():
    if not shutil.which('iptables'): return
    if rd('/proc/sys/net/ipv4/ip_forward').strip()!='1': run('sysctl','-qw','net.ipv4.ip_forward=1')
    wtext('/etc/sysctl.d/99-rexui-wg.conf','net.ipv4.ip_forward=1\n',0o644)
    i=lambda *a:run('iptables','-w',*a)
    if i('-C','FORWARD','-j','REXUI_WGF').returncode==0 and i('-t','nat','-C','POSTROUTING','-j','REXUI_WGN').returncode==0 and WGST.get('b25')==sload()['b25']: return
    i('-N','REXUI_WGF'); i('-F','REXUI_WGF'); i('-t','nat','-N','REXUI_WGN'); i('-t','nat','-F','REXUI_WGN')
    i('-A','REXUI_WGF','-s',WGNET,'-d',WGNET,'-j','DROP')
    if sload()['b25']: i('-A','REXUI_WGF','-s',WGNET,'-p','tcp','-m','multiport','--dports','25,465,587','-j','REJECT')
    i('-A','REXUI_WGF','-s',WGNET,'-p','tcp','--tcp-flags','SYN,RST','SYN','-j','TCPMSS','--clamp-mss-to-pmtu')
    i('-A','REXUI_WGF','-s',WGNET,'-j','ACCEPT'); i('-A','REXUI_WGF','-d',WGNET,'-m','conntrack','--ctstate','RELATED,ESTABLISHED','-j','ACCEPT')
    i('-t','nat','-A','REXUI_WGN','-s',WGNET,'!','-d',WGNET,'-j','MASQUERADE')
    if i('-C','FORWARD','-j','REXUI_WGF').returncode: i('-I','FORWARD','1','-j','REXUI_WGF')
    if i('-t','nat','-C','POSTROUTING','-j','REXUI_WGN').returncode: i('-t','nat','-I','POSTROUTING','1','-j','REXUI_WGN')
    WGST['b25']=sload()['b25']
def wg_purge():
    i=lambda *a:run('iptables','-w',*a)
    while i('-D','FORWARD','-j','REXUI_WGF').returncode==0: pass
    while i('-t','nat','-D','POSTROUTING','-j','REXUI_WGN').returncode==0: pass
    i('-F','REXUI_WGF'); i('-X','REXUI_WGF'); i('-t','nat','-F','REXUI_WGN'); i('-t','nat','-X','REXUI_WGN')
    run('ip','link','del',WGIF)
def wg_sync(us=None):
    """Puts the active WireGuard users on the interface. Connected users stay connected."""
    if not wg_on(): return
    cfg=wg_conf(us)
    if cfg==WGST['cfg'] and run('ip','link','show',WGIF).returncode==0: return
    if not wg_up(): return
    with WGL:
        wtext(WGD+'/rxwg.conf',cfg)
        r=run('wg','syncconf',WGIF,WGD+'/rxwg.conf')
        if r.returncode: log('wireguard sync:',r.stderr.strip()[-200:]); return
        WGST['cfg']=cfg
def wg_dump():
    """{public key: (endpoint ip, last handshake, rx, tx)}"""
    r=run('wg','show',WGIF,'dump',t=10); out={}
    if r.returncode: return out
    for l in r.stdout.splitlines()[1:]:
        f=l.split('\t')
        if len(f)<7: continue
        ep=f[2] if f[2]!='(none)' else ''
        ip=ep.rsplit(':',1)[0].strip('[]') if ep else ''
        try: out[f[0]]=(ip,int(f[4]),int(f[5]),int(f[6]))
        except ValueError: pass
    return out
def wg_poll():
    if not wg_on(): return
    d=wg_dump(); by={u.get('wgp'):u['name'] for u in uload() if haswg(u) and u.get('wgp')}; now=time.time(); WGON.clear()
    for pk,(ip,hs,rx,tx) in d.items():
        n=by.get(pk)
        if not n: continue
        prx,ptx=WGPREV.get(pk,(rx,tx)); WGPREV[pk]=(rx,tx)
        up,dn=(rx-prx if rx>=prx else rx),(tx-ptx if tx>=ptx else tx)
        if up or dn: e=WGPEND.setdefault(n,{'up':0,'down':0}); e['up']+=up; e['down']+=dn
        if hs and now-hs<180: WGON[n]={'ip':ip,'hs':hs}
def wg_kick(*names):
    if not wg_on() or not names: return
    us=uload(); t=time.time()+60; hit=False
    for n in names:
        if any(u['name']==n and haswg(u) for u in us): WGKICK[n]=t; WGON.pop(n,None); hit=True
    if hit: wg_sync(us)
def wg_enforce(us):
    if not wg_on(): return
    now=time.time()
    for n in [n for n,t in WGKICK.items() if t<now]: WGKICK.pop(n)
    wg_sync(us)
def wg_text(u):
    if not haswg(u) or not u.get('wgk'): raise Err('This user has no WireGuard keys yet')
    _,sp_=wg_server(); s=sload(); a=pub_addr(s); A='['+a+']' if ':' in a else a
    return '\n'.join(['[Interface]','PrivateKey = '+u['wgk'],'Address = %s/32'%u['wgip'],'DNS = 1.1.1.1, 8.8.8.8','MTU = 1280','',
                      '[Peer]','PublicKey = '+sp_]+(['PresharedKey = '+u['wgs']] if u.get('wgs') else [])+
                     ['AllowedIPs = 0.0.0.0/0, ::/0','Endpoint = %s:%d'%(A,wgport()),'PersistentKeepalive = 25'])+'\n'
def wg_info(u):
    if not haswg(u): return None
    o=WGON.get(u['name'])
    try: conf=wg_text(u)
    except Err: conf=''
    return {'on':wg_on(),'port':wgport(),'ip':u.get('wgip',''),'conf':conf,'online':bool(o),'from':o['ip'] if o else '','hs':o['hs'] if o else 0}
def wg_backup():
    k=rd(WGD+'/server.key').strip()
    return {'key':k} if k else None
def wg_restore(o):
    k=str((o or {}).get('key',''))
    try: ok=len(base64.b64decode(k,validate=True))==32
    except Exception: ok=False
    if ok: os.makedirs(WGD,exist_ok=True); os.chmod(WGD,0o700); wtext(WGD+'/server.key',k+'\n'); WGST['cfg']=None

# ---------- DNS tunnel (dnstt) + V2Ray ----------
DNSD=T+'/dns'; DNSBIN='/usr/local/bin/dnstt-server'; DNSUP=10809; DNSL=threading.Lock(); DNSRULE=[None]
def dns_on(): return os.path.exists(DNSBIN)
def hasdns(u): return kind(u)=='dns'
def dns_ns(): return sload()['dns_ns']
def dns_keys():
    if not dns_on(): return ''
    os.makedirs(DNSD,exist_ok=True); os.chmod(DNSD,0o700)
    if not (os.path.exists(DNSD+'/server.key') and os.path.exists(DNSD+'/server.pub')):
        r=run(DNSBIN,'-gen-key','-privkey-file',DNSD+'/server.key','-pubkey-file',DNSD+'/server.pub',t=30)
        if r.returncode: log('dnstt key:',(r.stderr or '').strip()[-200:]); return ''
        os.chmod(DNSD+'/server.key',0o600); log('dns tunnel: new key')
    return rd(DNSD+'/server.pub').strip()
def dns_setup(restart=True):
    """Key, start script and the UDP 53 redirect. The tunnel runs only when a nameserver domain is set."""
    if not dns_on(): return
    with DNSL:
        dns_keys(); ns=dns_ns()
        sh='#!/bin/sh\n# ReXUI DNS tunnel. Made by the panel, changes are overwritten.\n'+(
            'exec %s -udp :5300 -privkey-file %s/server.key %s 127.0.0.1:%d\n'%(DNSBIN,DNSD,ns,DNSUP) if ns else 'echo "Set the DNS tunnel domain in the panel (Settings -> DNS)"; exit 0\n')
        ch=wtext(DNSD+'/run.sh',sh,0o700)
        if restart and (ch or (ns and run('systemctl','is-active','--quiet','rexui-dns').returncode)):
            run('systemctl','enable' if ns else 'disable','rexui-dns'); run('systemctl','restart' if ns else 'stop','rexui-dns')
    dns_redirect(True)
def dns_redirect(force=False):
    if not dns_on() or not shutil.which('iptables'): return
    on=bool(dns_ns())
    if not force and on==DNSRULE[0] and (not on or run('iptables','-w','-t','nat','-C','PREROUTING','-j','REXUI_DNS').returncode==0): return
    for f in FAM:
        i=lambda *a:run(f,'-w','-t','nat',*a)
        i('-N','REXUI_DNS'); i('-F','REXUI_DNS')
        if on: i('-A','REXUI_DNS','-p','udp','-m','addrtype','--dst-type','LOCAL','--dport','53','-j','REDIRECT','--to-ports','5300')
        if i('-C','PREROUTING','-j','REXUI_DNS').returncode: i('-I','PREROUTING','1','-j','REXUI_DNS')
    DNSRULE[0]=on
def dns_purge():
    for f in FAM:
        i=lambda *a:run(f,'-w','-t','nat',*a)
        while i('-D','PREROUTING','-j','REXUI_DNS').returncode==0: pass
        i('-F','REXUI_DNS'); i('-X','REXUI_DNS')
def dns_set(d):
    v=hostok(d.get('dns_ns'),'DNS tunnel domain')
    if v and (v.count('.')<2 or re.fullmatch(r'[\d.]+',v)): raise Err('Use a subdomain of your own domain, like t.example.com')
    if v.endswith('duckdns.org'): raise Err('DuckDNS cannot delegate a nameserver. Use your own domain.')
    s=sload(); s['dns_ns']=v; wjson(SETF,s,0o600); dns_setup(); xray_apply(); return {'ok':1}
def dns_links(u,s=None):
    s=s or sload()
    return [('V2Ray inside the DNS tunnel','vless://%s@127.0.0.1:%d?encryption=none&security=none&type=tcp#%s'%(u['uuid'],DNSUP,cfgname(u,'dns','DNS V2Ray',s)))]
def dns_info(u=None):
    if u is not None and not hasdns(u): return None
    ns=dns_ns()
    return {'on':dns_on(),'ns':ns,'pub':rd(DNSD+'/server.pub').strip() if dns_on() else '','ip':IPS['v4'] or local_ip(),
            'nsh':'ns.'+ns.split('.',1)[1] if ns.count('.')>=2 else ''}

# ---------- CDN mode (Cloudflare) ----------
CF_HTTPS=(443,2053,2083,2087,2096,8443); CF_HTTP=(80,8080,8880,2052,2082,2086,2095)
CF_NETS=('173.245.48.0/20','103.21.244.0/22','103.22.200.0/22','103.31.4.0/22','141.101.64.0/18','108.162.192.0/18','190.93.240.0/20','188.114.96.0/20',
         '197.234.240.0/22','198.41.128.0/17','162.158.0.0/15','104.16.0.0/13','104.24.0.0/14','172.64.0.0/13','131.0.72.0/22')
def is_cf(ip):
    import ipaddress
    try: a=ipaddress.ip_address(ip)
    except ValueError: return False
    return any(a in ipaddress.ip_network(n) for n in CF_NETS)
def cdn_set(d):
    dom=hostok(d.get('cdn_dom'),'CDN domain'); addr=hostok(d.get('cdn_addr'),'Address')
    if dom and ('.' not in dom or re.fullmatch(r'[\d.]+',dom)): raise Err('Use a domain like cdn.example.com')
    if dom.endswith('duckdns.org'): raise Err('DuckDNS cannot use Cloudflare. Use your own domain on Cloudflare.')
    s=sload(); s['cdn_dom'],s['cdn_addr']=dom,addr; wjson(SETF,s,0o600); return {'ok':1}
def cdn_link(u,s,x,N):
    dom=s.get('cdn_dom')
    if not dom: return []
    A=(u.get('cdn') if x.get('b') else '') or x.get('addr') or s.get('cdn_addr') or dom; A='['+A+']' if ':' in A else A; pth=quote(ib_path(x),safe=''); dom=x.get('host') or dom
    xh=ib_tq(x,dom,True); tls=x['sec']=='tls'; ok=CF_HTTPS if tls else CF_HTTP
    own=x['port']; main,alt=own,None
    if h_on() and ib_h(x) and own not in (80,443): main,alt=(443 if tls else 80),(own if own in ok else None)
    if main not in ok: return []
    if tls:
        al_=ib_alpn(x); f_=ib_fp(x)   # client ↔ Cloudflare
        q='security=tls&sni=%s'%quote(dom)+('&fp='+f_ if f_!='none' else '')+('&alpn='+quote(','.join(al_),safe='') if al_ else '')+xh
    else: q='security=none'+xh
    return [(x['name'],ib_url(x,u,A,main,q,N),alt)]+ib_exts(x,u,q,N)
def cdn_info():
    s=sload(); d=s.get('cdn_dom','')
    HP=h_ports()[0]
    return {'dom':d,'addr':s.get('cdn_addr',''),'tls':HP['VWSTLS_PORT'] in CF_HTTPS,'http':HP['VWS_PORT'] in CF_HTTP,
            'ports':{'xtls':HP['VWSTLS_PORT'],'x':HP['VWS_PORT'],'ws':HP['WS_PORT'],'wss':HP['WSTLS_PORT']},
            'wsok':HP['WS_PORT'] in CF_HTTP,'wssok':HP['WSTLS_PORT'] in CF_HTTPS}

# ---------- Performance modes ----------
PERFF='/etc/sysctl.d/99-zz-rexui-perf.conf'
PERF={'latency':{'net.ipv4.tcp_notsent_lowat':'16384','net.ipv4.tcp_slow_start_after_idle':'0','net.ipv4.tcp_fastopen':'3',
                 'net.ipv4.tcp_rmem':'4096 87380 8388608','net.ipv4.tcp_wmem':'4096 65536 8388608','net.core.netdev_budget':'300'},
      'balanced':{'net.ipv4.tcp_notsent_lowat':'131072','net.ipv4.tcp_slow_start_after_idle':'0','net.ipv4.tcp_fastopen':'3',
                  'net.ipv4.tcp_rmem':'4096 87380 33554432','net.ipv4.tcp_wmem':'4096 65536 33554432','net.core.netdev_budget':'300'},
      'throughput':{'net.ipv4.tcp_notsent_lowat':'4294967295','net.ipv4.tcp_slow_start_after_idle':'0','net.ipv4.tcp_fastopen':'3',
                    'net.ipv4.tcp_rmem':'4096 131072 67108864','net.ipv4.tcp_wmem':'4096 131072 67108864','net.core.netdev_budget':'600'}}
def perf_apply(mode=None):
    mode=mode or sload().get('perf','balanced')
    if mode not in PERF: mode='balanced'
    txt='# ReXUI performance mode: %s (change it in the panel: Settings -> General)\n'%mode+''.join('%s=%s\n'%kv for kv in PERF[mode].items())
    try:
        if wtext(PERFF,txt,0o644): run('sysctl','-q','-p',PERFF)
    except OSError as e: log('performance mode:',e)
    return mode
def perf_set(d):
    m=str(d.get('perf',''))
    if m not in PERF: raise Err('Unknown mode')
    s=sload(); s['perf']=m; wjson(SETF,s,0o600); perf_apply(m); return {'ok':1}

# ---------- Payload Builder ----------
PAYF=T+'/payloads.json'; PAYMODES=('ws','wstls','ssl','proxy')
def pay_load():
    try: L=json.load(open(PAYF))
    except Exception: L=[]
    return [x for x in L if isinstance(x,dict) and x.get('id')]
def pay_vals(bug='',s=None):
    s=s or sload(); ci=certinfo(); a=pub_addr(s); h=s.get('host') or ci['domain'] or a
    HP=h_ports()[0]
    return {'{server}':h,'{ip}':IPS['v4'] or a,'{bug}':bug or h,'{ws_port}':str(HP['WS_PORT']),'{wss_port}':str(HP['WSTLS_PORT']),
            '{ssl_port}':str(HP['SSL_PORT']),'{path}':s['path'],'{cdn}':s.get('cdn_dom') or h}
def pay_render(p,s=None):
    t=p.get('text',''); v=pay_vals(p.get('bug',''),s)
    for k,x in v.items(): t=t.replace(k,x)
    return t
def pay_clean(d):
    n=str(d.get('name','')).strip()[:60]; t=str(d.get('text','')).replace('\r','')
    if not n: raise Err('Give the payload a name')
    if not t.strip(): raise Err('The payload is empty')
    if len(t)>4000: raise Err('The payload is too long (4000 characters max)')
    m=str(d.get('mode','ws'))
    if m not in PAYMODES: raise Err('Unknown connection type')
    return {'name':n,'text':t,'mode':m,'bug':hostok(d.get('bug'),'Bug host'),'show':bool(d.get('show',True)),'note':str(d.get('note','')).strip()[:200]}
def pay_save(d):
    p=pay_clean(d); L=pay_load(); i=str(d.get('id') or '')
    if i:
        for x in L:
            if x['id']==i: x.update(p); break
        else: raise Err('Payload not found')
    else:
        if len(L)>=200: raise Err('You can keep up to 200 payloads')
        p['id']=secrets.token_hex(4); L.append(p); i=p['id']
    wjson(PAYF,L,0o600); return {'ok':1,'id':i}
def pay_del(d):
    L=pay_load(); n=len(L); L=[x for x in L if x['id']!=str(d.get('id'))]
    if len(L)==n: raise Err('Payload not found')
    wjson(PAYF,L,0o600); return {'ok':1}
def pay_import(d):
    items=d.get('items')
    if not isinstance(items,list) or not items: raise Err('Nothing to import')
    L=pay_load(); have={(x['name'],x['text']) for x in L}; add=0
    for it in items[:200]:
        try: p=pay_clean(it if isinstance(it,dict) else {})
        except Err: continue
        if (p['name'],p['text']) in have or len(L)>=200: continue
        p['id']=secrets.token_hex(4); L.append(p); have.add((p['name'],p['text'])); add+=1
    wjson(PAYF,L,0o600); return {'ok':1,'added':add}
def pay_bytes(text,host,port):
    """Turn app variables into bytes the way tunnel apps do. Returns a list of parts ([split] = send in pieces)."""
    t=text
    rot=re.search(r'\[rotate=([^\]]*)\]',t)
    while rot:
        t=t.replace(rot[0],(rot[1].split(';')[0] or '').strip()); rot=re.search(r'\[rotate=([^\]]*)\]',t)
    rep={'[crlf]':'\r\n','[lf]':'\n','[cr]':'\r','[lfcr]':'\n\r','[host_port]':'%s:%d'%(host,port),'[host]':host,'[port]':str(port),
         '[protocol]':'HTTP/1.1','[method]':'CONNECT','[ua]':'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36',
         '[raw]':'CONNECT %s:%d HTTP/1.1'%(host,port),'[real_raw]':'CONNECT %s:%d HTTP/1.1'%(host,port),'[netData]':'CONNECT %s:%d HTTP/1.1'%(host,port)}
    for k in sorted(rep,key=len,reverse=True): t=t.replace(k,rep[k])
    return [x.encode('utf-8','replace') for x in re.split(r'\[(?:split|delay_split|instant_split|delay)\]',t)]
def pay_test(d):
    p=pay_clean(dict(d,name=d.get('name') or 'test'))
    if p['mode']=='proxy': return {'ok':0,'msg':'Proxy payloads go through a remote proxy, so this server cannot test them by itself.'}
    if p['mode']=='ssl':
        port=P('SSL_PORT',443)
    else: port=P('WS_PORT',8880) if p['mode']=='ws' else P('WSTLS_PORT',2083)
    text=pay_render(p); v=pay_vals(p['bug']); host=v['{bug}']
    parts=pay_bytes(text,host,port); t0=time.time(); got=b''
    try:
        raw=socket.create_connection(('127.0.0.1',port),timeout=6)
        if p['mode'] in ('wstls','ssl'):
            cx=ssl.create_default_context(); cx.check_hostname=False; cx.verify_mode=ssl.CERT_NONE
            raw=cx.wrap_socket(raw,server_hostname=host if re.search('[a-z]',host) else None)
        raw.settimeout(4)
        if p['mode']!='ssl' or text.strip():
            for i,b in enumerate(parts):
                if b: raw.sendall(b)
                if i<len(parts)-1: time.sleep(0.2)
        end=time.time()+4
        while time.time()<end and b'SSH-' not in got and len(got)<16384:
            try: c=raw.recv(4096)
            except socket.timeout: break
            if not c: break
            got+=c
        raw.close()
    except (OSError,ssl.SSLError) as e:
        return {'ok':0,'msg':'Could not connect to port %d on this server: %s'%(port,str(e)[:80])}
    ms=int((time.time()-t0)*1000); first=got.split(b'\r\n',1)[0].decode('latin-1')[:80]
    if b'SSH-' in got:
        return {'ok':1,'msg':'Works on this server: %s, then the SSH server answered (%d ms).'%(('it replied "%s"'%first) if first and not first.startswith('SSH-') else 'connected',ms),'resp':first}
    if first: return {'ok':0,'msg':'The server replied "%s" but SSH did not start. Check the payload lines and the empty line at the end ([crlf][crlf]).'%first,'resp':first}
    return {'ok':0,'msg':'No answer from the server. The payload may be incomplete (it must end with [crlf][crlf]).'}

# ---------- Port Manager ----------
def port_list():
    s=sload(); L=[('Panel','PANEL_PORT',0,'tcp'),('SSH','SSH_PORT',22,'tcp'),('SSH SSL','SSL_PORT',443,'tcp'),('SSH WebSocket','WS_PORT',8880,'tcp'),
       ('SSH WebSocket TLS','WSTLS_PORT',2083,'tcp')]
    seen=set()
    for x in ib_load():
        if ib_ok(x) and x['port'] not in (80,443) and x['port'] not in seen: seen.add(x['port']); L.append((x['name'],'',x['port'],'tcp'))
    L.append(('Fake website','',80,'tcp'))
    if ov_on(): L+=[('OpenVPN','OVPN1_PORT',1194,'tcp'),('OpenVPN','OVPN2_PORT',110,'tcp'),('HTTP proxy (OpenVPN)','SQUID_PORT',3128,'tcp')]
    if hy_on(): L+=[('Hysteria2','HY_PORT',443,'udp')]
    if wg_on(): L+=[('WireGuard','WG_PORT',51820,'udp')]
    if dns_on() and s.get('dns_ns'): L+=[('DNS tunnel','',53,'udp')]
    if h_on(): L=[(('443 mode: SSL and all TLS' if n=='SSH SSL' else '80 mode: WS, XHTTP, website' if n=='Fake website' else n),k,d,pr) for n,k,d,pr in L]
    return [(n,(P(k,d) if k else d),pr) for n,k,d,pr in L]
def ss_listeners():
    """{(proto,port): 'program'} for everything listening on the server (not only on 127.0.0.1)."""
    out={}
    if not shutil.which('ss'):
        for pr in ('tcp','udp'):
            for p_ in listening(pr=='udp'): out[(pr,p_)]='?'
        return out
    for pr,flag in (('tcp','-tlnpH'),('udp','-ulnpH')):
        for l in run('ss',flag).stdout.splitlines():
            f=l.split()
            if len(f)<5: continue
            loc=f[3]; m=re.search(r':(\d+)$',loc)
            if not m or loc.startswith(('127.','[::1]')): continue
            prog=re.search(r'users:\(\("([^"]+)"',l)
            out[(pr,int(m[1]))]=prog[1] if prog else '?'
    return out
def ufw_rules():
    r=run('ufw','status'); txt=r.stdout if r.returncode==0 else ''
    if 'Status: active' not in txt: return None
    al=set()
    for l in txt.splitlines():
        m=re.match(r'^(\d+)(?::(\d+))?(?:/(tcp|udp))?\s+(?:\(v6\)\s+)?ALLOW',l.strip())
        if m:
            a=int(m[1]); b=int(m[2] or m[1])
            for pr in ([m[3]] if m[3] else ['tcp','udp']): al.add((pr,a,b))
    return al
def ports_view():
    ls=ss_listeners(); fw=ufw_rules(); mine=port_list(); res=[]; seen=set()
    for n,p,pr in mine:
        prog=ls.get((pr,p),''); seen.add((pr,p))
        if n=='DNS tunnel': prog=('redirect → '+ls[('udp',5300)]) if ('udp',5300) in ls else ''; seen.add(('udp',5300))
        if fw is None: f='off'
        else: f='open' if any(x[0]==pr and x[1]<=p<=x[2] for x in fw) else 'closed'
        res.append({'name':n,'port':p,'proto':pr,'listen':bool(prog),'prog':prog,'fw':f})
    hop=hyhop() if hy_on() else None
    if hop: res.append({'name':'Hysteria2 port hopping','port':'%d-%d'%hop,'proto':'udp','listen':True,'prog':'redirect','fw':'off' if fw is None else ('open' if any(x[0]=='udp' and x[1]<=hop[0] and x[2]>=hop[1] for x in fw) else 'closed')})
    known={'haproxy','sshd','xray','stunnel4','stunnel','python3','openvpn','squid','hysteria','dnstt-server','badvpn-udpgw','systemd-resolve','chronyd','dhclient','systemd-network'}
    other=[{'port':p,'proto':pr,'prog':g} for (pr,p),g in sorted(ls.items(),key=lambda x:(x[0][0],x[0][1])) if (pr,p) not in seen and g not in known]
    dup={}
    for n,p,pr in mine: dup.setdefault((pr,p),[]).append(n)
    clash=[{'port':p,'proto':pr,'names':sorted(set(v))} for (pr,p),v in dup.items() if len(set(v))>1]
    return {'ports':res,'other':other,'clash':clash,'fw':fw is not None}
CHAPI=os.environ.get('REXUI_CHAPI','https://check-host.net')
def ib_portcheck(d):
    """Is the inbound port open? Xray listening, server firewall (ufw), and from the internet (check-host.net, 3 countries)."""
    x=next((y for y in ib_load() if y['id']==d.get('id')),None)
    if not x: raise Err('Inbound not found')
    p=x['port']; o={'port':p,'name':x['name'],'listen':('tcp',p) in ss_listeners() or (p in (80,443) and h_on())}
    fw=ufw_rules(); o['fw']='off' if fw is None else ('open' if any(r[0]=='tcp' and r[1]<=p<=r[2] for r in fw) else 'closed')
    host=IPS.get('v4') or pub_addr(); o['host']=host
    def get(u):
        rq=urllib.request.Request(u,headers={'Accept':'application/json','User-Agent':'ReXUI'})
        with urllib.request.urlopen(rq,timeout=15) as r: return json.loads(r.read())
    try:
        rid=get('%s/check-tcp?host=%s:%d&max_nodes=3'%(CHAPI,quote(host),p))['request_id']; r={}
        for i in range(8):
            time.sleep(2 if i else 4); r=get('%s/check-result/%s'%(CHAPI,rid))
            if r and all(v is not None for v in r.values()): break
        ok=sum(1 for v in r.values() if isinstance(v,list) and v and isinstance(v[0],dict) and 'error' not in v[0] and v[0].get('time') is not None)
        o['out']={'ok':ok,'n':len(r)}
    except Exception as e: o['out']={'err':'The online checker (check-host.net) could not be reached: '+str(e)[:60]}
    return o
def fw_open(d):
    pr=str(d.get('proto','tcp'))
    if pr not in ('tcp','udp'): raise Err('bad request')
    p=str(d.get('port',''))
    if not re.fullmatch(r'\d{1,5}(-\d{1,5})?',p): raise Err('bad port')
    if ufw_rules() is None: return {'ok':1,'msg':'The server firewall (ufw) is off, so nothing is blocked here.'}
    run('ufw','allow','%s/%s'%(p.replace('-',':'),pr)); return {'ok':1}

# ---------- Server Check ----------
def dnsq(name,qt='A',server='8.8.8.8',timeout=3):
    """Tiny DNS client: returns {'an':[...], 'ns':[...]} (A / NS answers, NS in authority)."""
    tid=os.urandom(2); q=b''.join(bytes([len(x)])+x.encode() for x in name.strip('.').split('.'))+b'\0'
    pkt=tid+b'\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00'+q+{'A':b'\x00\x01','NS':b'\x00\x02'}[qt]+b'\x00\x01'
    s_=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s_.settimeout(timeout)
    try: s_.sendto(pkt,(server,53)); r,_=s_.recvfrom(4096)
    finally: s_.close()
    def rname(o):
        parts=[]; jumped=False; end=o
        while True:
            l=r[o]
            if l==0: o+=1; break
            if l&0xC0==0xC0:
                if not jumped: end=o+2
                o=((l&0x3F)<<8)|r[o+1]; jumped=True; continue
            parts.append(r[o+1:o+1+l].decode('latin-1')); o+=1+l
        return '.'.join(parts),(end if jumped else o)
    an_c,ns_c=int.from_bytes(r[6:8],'big'),int.from_bytes(r[8:10],'big'); o=12
    _,o=rname(o); o+=4; out={'an':[],'ns':[]}
    for i in range(an_c+ns_c):
        _,o=rname(o); t=int.from_bytes(r[o:o+2],'big'); ln=int.from_bytes(r[o+8:o+10],'big'); o+=10
        if t==1 and ln==4: v=socket.inet_ntoa(r[o:o+4])
        elif t==2: v=rname(o)[0]
        else: v=None
        if v: out['an' if i<an_c else 'ns'].append(v)
        o+=ln
    return out
def server_check():
    R=[]; add=lambda id_,name,st,msg,fix=None:R.append({'id':id_,'name':name,'st':st,'msg':msg,'fix':fix})
    s=sload(); ip=IPS['v4']
    for x in services():
        if x['st']=='RUNNING': continue
        add('svc:'+x['unit'],x['name'],'fail' if x['st'] in ('FAILED','IDLE') else 'warn',
            {'FAILED':'Stopped with an error.','IDLE':'Not running (or its port is not open).','NOT INSTALLED':'Not installed. Run the installer again.'}.get(x['st'],x['st']),
            'restart:'+x['unit'] if x['st'] in ('FAILED','IDLE') else None)
    if not [r for r in R if r['id'].startswith('svc:')]: add('svc','Services','ok','All %d services are running.'%len(services()))
    if h_on():
        hb=run('systemctl','is-active','--quiet','haproxy').returncode==0
        add('h443','443 mode (HAProxy)','ok' if hb else 'fail','On: SSH SSL, WS TLS, VLESS TLS, Trojan and OpenVPN work on port 443, WebSocket and XHTTP on port 80. Reality keeps its own port.' if hb else 'HAProxy is not running.',None if hb else 'restart:haproxy')
    elif h_want():
        add('h443','443 mode (HAProxy)','warn',HQ['err'] or 'Off. Turn it on in Settings → Network ports.','h443')
    r=run(XBIN,'run','-test','-c',XD+'/config.json',t=30)
    add('xray','Xray config','ok' if r.returncode==0 else 'fail','The config is valid.' if r.returncode==0 else 'Xray rejects its config: '+((r.stdout+r.stderr).strip().splitlines() or ['?'])[-1][-160:],None if r.returncode==0 else 'xray')
    ci=certinfo()
    if ci['src']=='self-signed': add('cert','Certificate','warn','Self-signed certificate: TLS configs need "allow insecure". Get a free Let\'s Encrypt certificate from menu → SSL.')
    else:
        dl=ci.get('days')
        add('cert','Certificate','ok' if (dl is None or dl>14) else ('warn' if dl>3 else 'fail'),'%s, valid for %s more days.'%(ci['name'],dl if dl is not None else '?'))
    dom=ci['domain'] if ci['src']!='self-signed' else ''
    if dom and ip:
        try:
            a=dnsq(dom)['an']
            if ip in a: add('dom','Panel domain','ok','%s points to this server (%s).'%(dom,ip))
            elif any(is_cf(x) for x in a): add('dom','Panel domain','fail','%s goes through Cloudflare (orange cloud). Make it grey (DNS only) in Cloudflare.'%dom)
            else: add('dom','Panel domain','fail','%s points to %s, not to this server (%s). Fix the A record.'%(dom,', '.join(a) or 'nothing',ip))
        except Exception as e: add('dom','Panel domain','warn','Could not check the domain: %s'%str(e)[:60])
    cd=s.get('cdn_dom')
    if cd:
        try:
            a=dnsq(cd)['an']
            if a and all(is_cf(x) for x in a): add('cdn','CDN domain','ok','%s goes through Cloudflare (orange cloud).'%cd)
            elif ip in a: add('cdn','CDN domain','fail','%s points straight to this server. Turn the cloud orange (Proxied) in Cloudflare.'%cd)
            else: add('cdn','CDN domain','fail','%s does not resolve to Cloudflare (%s). Add an A record to this server with the orange cloud.'%(cd,', '.join(a) or 'no record'))
        except Exception as e: add('cdn','CDN domain','warn','Could not check: %s'%str(e)[:60])
    ns=s.get('dns_ns')
    if ns and dns_on():
        try:
            base=ns.split('.',1)[1]; nsh='ns.'+base
            a=dnsq(nsh)['an']
            if ip and ip not in a: add('dnsns','DNS tunnel','fail','%s must point to this server (%s), it points to %s.'%(nsh,ip,', '.join(a) or 'nothing'))
            else:
                par=dnsq(base,'NS')['an']; deleg=[]
                if par:
                    pip=dnsq(par[0])['an']
                    if pip: q=dnsq(ns,'NS',pip[0]); deleg=q['an']+q['ns']
                if any(x.rstrip('.').lower()==nsh for x in deleg): add('dnsns','DNS tunnel','ok','%s is handed to %s, which points here.'%(ns,nsh))
                else: add('dnsns','DNS tunnel','fail','No NS record for %s → %s yet. Add it in your DNS (Cloudflare: type NS).'%(ns,nsh))
        except Exception as e: add('dnsns','DNS tunnel','warn','Could not check: %s'%str(e)[:60])
    if ov_on():
        f=rd('/proc/sys/net/ipv4/ip_forward').strip()=='1'
        nat=run('iptables','-w','-t','nat','-C','POSTROUTING','-j','REXUI_NAT').returncode==0
        add('fwd','OpenVPN internet','ok' if f and nat else 'fail','Forwarding and NAT are on.' if f and nat else 'OpenVPN users would connect without internet (forwarding or NAT is off).',None if f and nat else 'ovnet')
        add('tun','TUN device','ok' if os.path.exists('/dev/net/tun') else 'fail','Available.' if os.path.exists('/dev/net/tun') else 'Missing: OpenVPN cannot work. Enable TUN in your VPS control panel.')
    fw=ufw_rules()
    if fw is None: add('ufw','Server firewall','ok','ufw is off: only your provider\'s firewall decides which ports are open.')
    else:
        miss=['%s/%s'%(p,pr) for n,p,pr in port_list() if not any(x[0]==pr and x[1]<=p<=x[2] for x in fw)]
        add('ufw','Server firewall','ok' if not miss else 'fail','All ReXUI ports are allowed.' if not miss else 'Blocked by ufw: '+', '.join(miss),None if not miss else 'ufw')
    ls=ss_listeners(); bad=[]
    for n,p,pr in port_list():
        g=ls.get((pr,p))
        if g and g!='?' and g not in ('haproxy','sshd','xray','stunnel4','stunnel','python3','openvpn','squid','hysteria','dnstt-server'): bad.append('%s %d/%s used by %s'%(n,p,pr,g))
    if bad: add('clash','Port conflicts','fail','; '.join(bad))
    sync=run('timedatectl','show','-p','NTPSynchronized','--value').stdout.strip()
    if sync: add('time','Clock','ok' if sync=='yes' else 'warn','In sync.' if sync=='yes' else 'The clock is not synced. Reality and TLS can fail with a wrong clock.',None if sync=='yes' else 'ntp')
    cc=rd('/proc/sys/net/ipv4/tcp_congestion_control').strip()
    add('bbr','BBR','ok' if cc=='bbr' else 'warn','On.' if cc=='bbr' else 'Off (%s). Speed may be lower; run the installer again.'%(cc or '?'))
    st=os.statvfs('/'); fr=st.f_bavail*st.f_frsize; tot=st.f_blocks*st.f_frsize
    add('disk','Disk','ok' if fr>tot*0.1 and fr>1<<30 else ('warn' if fr>300<<20 else 'fail'),'%s free of %s.'%(fmt_b(fr),fmt_b(tot)),None if fr>tot*0.1 else 'clean')
    mi={l.split(':')[0]:int(l.split()[1])*1024 for l in rd('/proc/meminfo').splitlines() if len(l.split())>1}
    av,mt,sw=mi.get('MemAvailable',0),mi.get('MemTotal',1),mi.get('SwapTotal',0)
    add('ram','Memory','ok' if av>mt*0.1 else 'warn','%s free of %s%s.'%(fmt_b(av),fmt_b(mt),'' if sw else ', no swap'))
    if not s.get('tgtoken'): add('tg','Telegram alerts','warn','Off. Add a bot in Settings → Telegram to get alerts when something breaks.')
    order={'fail':0,'warn':1,'ok':2}; R.sort(key=lambda x:order[x['st']])
    return {'t':int(time.time()),'items':R,'fail':sum(1 for x in R if x['st']=='fail'),'warn':sum(1 for x in R if x['st']=='warn')}
def fmt_b(n):
    for u_ in ('B','KB','MB','GB','TB'):
        if n<1024 or u_=='TB': return ('%.1f %s'%(n,u_)) if u_!='B' else '%d B'%n
        n/=1024
def check_fix(d):
    f=str(d.get('fix',''))
    if f.startswith('restart:'):
        u=f.split(':',1)[1]
        if u not in RESTART: raise Err('bad request')
        run('systemctl','restart',u); return {'ok':1,'msg':'Restarted '+u}
    if f=='xray': e=xray_apply(True); return {'ok':0 if e else 1,'msg':e or 'Xray config rebuilt'}
    if f=='ovnet': ov_net(True); return {'ok':1,'msg':'Forwarding and NAT turned on'}
    if f=='ufw':
        for n,p,pr in port_list(): run('ufw','allow','%d/%s'%(p,pr))
        h=hyhop() if hy_on() else None
        if h: run('ufw','allow','%d:%d/udp'%h)
        return {'ok':1,'msg':'ReXUI ports allowed in ufw'}
    if f=='ntp': run('timedatectl','set-ntp','true'); return {'ok':1,'msg':'Clock sync turned on'}
    if f=='h443': x=h_apply(True); return {'ok':1 if x['on'] else 0,'msg':'443 mode is on' if x['on'] else x['err']}
    if f=='clean': r=cleanup(); return {'ok':1,'msg':'Cleanup done' if not isinstance(r,dict) else r.get('msg','Cleanup done')}
    raise Err('bad request')

# ---------- 443 mode (HAProxy on 443 + 80) ----------
HAC='/etc/haproxy/haproxy.cfg'; HAPEM='/etc/haproxy/rexui.pem'; HON=T+'/h443.on'; HSD='/dev/shm'
HSOCK={'xhttp':HSD+'/rexui-xhttp.sock','vless':HSD+'/rexui-vless.sock','trojan':HSD+'/rexui-trojan.sock','ws':HSD+'/rexui-ws.sock'}
HQ={'err':'','lock':threading.RLock(),'fail':0,'hash':''}
def h_has(): return bool(shutil.which('haproxy'))
def h_on(): return os.path.exists(HON)
def h_want(): return bool(sload().get('h443',True))
def h_uports(u,s=None): return h_ports()
def h_ports():
    """Ports users should use. With 443 mode on, TLS goes to 443 and plain HTTP to 80; the old ports stay as a second choice."""
    b={k:P(k,d) for k,d in (('SSL_PORT',443),('WS_PORT',8880),('WSTLS_PORT',2083),('VWSTLS_PORT',8443),('VTCP_PORT',2053),('VWS_PORT',8080),('REALITY_PORT',8444),('TROJAN_PORT',2096))}
    if not h_on(): return b,{}
    main={'SSL_PORT':443,'WS_PORT':80,'WSTLS_PORT':443,'VWSTLS_PORT':443,'VTCP_PORT':443,'VWS_PORT':80,'REALITY_PORT':b['REALITY_PORT'],'TROJAN_PORT':443}
    return main,{k:v for k,v in b.items() if v!=main[k]}
def h_xinbounds(s,cx,cl,tj,cw=()):
    """Extra Xray inbounds on unix sockets for traffic that HAProxy passes on (with the real client IP in a PROXY header)."""
    if not h_on(): return []
    so={'acceptProxyProtocol':True}
    def lst(k): return HSOCK[k]+',0666'
    ibs=[{'tag':'h-xhttp','listen':lst('xhttp'),'port':0,'protocol':'vless','settings':{'clients':cx,'decryption':'none'},
          'streamSettings':{'network':'xhttp','security':'none','xhttpSettings':{'path':s['path'],'mode':'auto'},'sockopt':so},'sniffing':{'enabled':True,'destOverride':['http','tls']}},
         {'tag':'h-vless','listen':lst('vless'),'port':0,'protocol':'vless','settings':{'clients':cl,'decryption':'none'},
          'streamSettings':{'network':'tcp','security':'none','sockopt':so},'sniffing':{'enabled':True,'destOverride':['http','tls']}},
         {'tag':'h-trojan','listen':lst('trojan'),'port':0,'protocol':'trojan','settings':{'clients':tj},
          'streamSettings':{'network':'tcp','security':'none','sockopt':so},'sniffing':{'enabled':True,'destOverride':['http','tls']}}]
    if cw: ibs.append({'tag':'h-ws','listen':lst('ws'),'port':0,'protocol':'vless','settings':{'clients':list(cw),'decryption':'none'},
                      'streamSettings':{'network':'ws','security':'none','wsSettings':{'path':s['wspath']},'sockopt':so},'sniffing':{'enabled':True,'destOverride':['http','tls']}})
    # Reality stays on its own port (not behind HAProxy), so TLS configs can use any SNI on 443
    return ibs
def h_pem():
    c,k=CD+'/xray.crt',CD+'/xray.key'
    if not (os.path.exists(c) and os.path.exists(k)): c,k=XSC,XSK
    return rd(c).strip()+'\n'+rd(k).strip()+'\n'
def h_cfg():
    s=sload(); fs=s['fsite']!='off'
    v6=os.path.exists('/proc/net/if_inet6') and rd('/proc/sys/net/ipv6/conf/all/disable_ipv6').strip()!='1'
    def bind(p): return 'bind :::%d v4v6'%p if v6 else 'bind 0.0.0.0:%d'%p
    xp=re.escape(s['path'].rstrip('/') or '/').replace('\\','\\\\'); wp=re.escape(s['wspath'].rstrip('/') or '/vws').replace('\\','\\\\')
    L=['# Made by the ReXUI panel (443 mode). Changes here are overwritten.',
       'global','    maxconn 100000','    ssl-default-bind-options ssl-min-ver TLSv1.2','    tune.ssl.default-dh-param 2048','',
       'defaults','    mode tcp','    timeout connect 5s','    timeout client 2h','    timeout server 2h','    timeout tunnel 2h',
       '    timeout client-fin 30s','    timeout server-fin 30s','',
       'frontend rx443','    '+bind(443),'    tcp-request inspect-delay 3s',
       # wait for the whole TLS hello (big hellos come in 2 packets) so the SNI is always seen; anything that is not TLS goes on at once
       '    tcp-request content accept if { req.ssl_hello_type 1 } { req.payload_lv(3,2) -m found }',
       '    tcp-request content accept if !{ req.payload(0,1) -m bin 16 } { req.len ge 3 }']
    L+=['    use_backend rx_tls if { req.ssl_hello_type 1 }','    default_backend rx_plain','',
        'frontend rx80','    '+bind(80),'    tcp-request inspect-delay 3s',
        '    tcp-request content accept if { req.ssl_hello_type 1 } { req.payload_lv(3,2) -m found }',
        '    tcp-request content accept if !{ req.payload(0,1) -m bin 16 } { req.len ge 3 }',
        '    use_backend rx_tls if { req.ssl_hello_type 1 }','    default_backend rx_plain','',
        'backend rx_tls','    server t abns@rexui-dec send-proxy-v2','',
        'backend rx_plain','    server p abns@rexui-plain send-proxy-v2','',
        # traffic without TLS (port 80, and port 443 without TLS)
        'frontend rx_plain_in','    bind abns@rexui-plain accept-proxy','    tcp-request inspect-delay 3s',
        "    acl ssh req.payload(0,4) -m bin 5353482d",
        "    acl ovpn req.payload(0,1) -m bin 00",
        "    acl ovpn2 req.payload(2,1) -m bin 38",
        "    acl h2c req.payload(0,14) -m bin 505249202a20485454502f322e30",
        "    acl xpath req.payload(0,0) -m reg ^[A-Z]{3,7}\\\\x20%s[/?\\\\x20]"%xp,
        "    acl wpath req.payload(0,0) -m reg ^GET\\\\x20%s[/?\\\\x20]"%wp,
        "    acl acme req.payload(0,0) -m reg ^(GET|HEAD)\\\\x20/\\\\.well-known/acme-challenge/",
        "    acl upg req.payload(0,0) -m reg -i \\\\r\\\\nupgrade:",
        "    acl page req.payload(0,0) -m reg -i \\\\r\\\\naccept:[^\\\\r]*text/html",
        "    acl moz req.payload(0,0) -m reg -i \\\\r\\\\nuser-agent:[^\\\\r]*mozilla",
        '    tcp-request content accept if ssh','    tcp-request content accept if ovpn ovpn2','    tcp-request content accept if h2c',
        '    tcp-request content accept if HTTP','    tcp-request content accept if { req.len ge 64 }',
        '    use_backend rx_sshp if ssh','    use_backend rx_ssh if { req.len eq 0 }','    use_backend rx_ovpn if ovpn ovpn2',
        '    use_backend rx_xhttp if h2c','    use_backend rx_xhttp if xpath','    use_backend rx_vws if wpath','    use_backend rx_fake if acme']
    if fs: L.append('    use_backend rx_fake if page moz !upg')
    L+=['    default_backend rx_ws','',
        # traffic that came with TLS on 443 (decrypted here)
        'frontend rx_dec_in','    bind abns@rexui-dec accept-proxy ssl crt %s alpn http/1.1'%HAPEM,'    tcp-request inspect-delay 3s',
        "    acl ssh req.payload(0,4) -m bin 5353482d",
        "    acl vless req.payload(0,1) -m bin 00",
        "    acl trojan req.payload(56,2) -m bin 0d0a",
        "    acl hex req.payload(0,1) -m reg ^[0-9a-f]",
        "    acl h2c req.payload(0,14) -m bin 505249202a20485454502f322e30",
        "    acl xpath req.payload(0,0) -m reg ^[A-Z]{3,7}\\\\x20%s[/?\\\\x20]"%xp,
        "    acl wpath req.payload(0,0) -m reg ^GET\\\\x20%s[/?\\\\x20]"%wp,
        "    acl upg req.payload(0,0) -m reg -i \\\\r\\\\nupgrade:",
        "    acl page req.payload(0,0) -m reg -i \\\\r\\\\naccept:[^\\\\r]*text/html",
        "    acl moz req.payload(0,0) -m reg -i \\\\r\\\\nuser-agent:[^\\\\r]*mozilla",
        '    tcp-request content accept if ssh','    tcp-request content accept if vless','    tcp-request content accept if trojan hex',
        '    tcp-request content accept if h2c','    tcp-request content accept if HTTP','    tcp-request content accept if { req.len ge 64 }',
        '    use_backend rx_sshp if ssh','    use_backend rx_ssh if { req.len eq 0 }','    use_backend rx_vless if vless',
        '    use_backend rx_trojan if trojan hex','    use_backend rx_xhttp if h2c','    use_backend rx_xhttp if xpath','    use_backend rx_vws if wpath']+(['    use_backend rx_fake if page moz !upg'] if fs else [])+['    default_backend rx_ws','',
        'backend rx_ssh','    server s 127.0.0.1:%d'%P('SSH_PORT',22),'',
        'backend rx_ws','    server s 127.0.0.1:%d send-proxy-v2'%P('WS_PORT',8880),'',
        # SSH that starts at once (SSL without payload) also goes through the WS proxy, only to keep the real IP
        'backend rx_sshp','    server s 127.0.0.1:%d send-proxy-v2'%P('WS_PORT',8880),'',
        'backend rx_fake','    server s 127.0.0.1:%d'%FBP,'',
        'backend rx_ovpn','    server s 127.0.0.1:%d'%P('OVPN1_PORT',1194),'',
        'backend rx_xhttp','    server s %s send-proxy-v2'%HSOCK['xhttp'],'',
        'backend rx_vless','    server s %s send-proxy-v2'%HSOCK['vless'],'',
        'backend rx_trojan','    server s %s send-proxy-v2'%HSOCK['trojan'],'',
        'backend rx_vws','    server s %s send-proxy-v2'%HSOCK['ws'],'']
    return '\n'.join(L)
def h_ssl_move(on):
    """While 443 mode is on, stunnel's SSH SSL service moves to 127.0.0.1:10443 so HAProxy can use port 443."""
    f='/etc/stunnel/stunnel.conf'; t=rd(f)
    if not t: return False
    want='127.0.0.1:10443' if on and P('SSL_PORT',443)==443 else str(P('SSL_PORT',443))
    n=re.sub(r'(\[ssh-ssl\][^\[]*?accept\s*=\s*)\S+',lambda m:m.group(1)+want,t,count=1)
    if n==t: return False
    wtext(f,n,0o644); run('systemctl','restart','stunnel4'); return True
def h_busy():
    """Programs other than ReXUI's own that sit on TCP 443 or 80."""
    L=ss_listeners(); bad=[]
    for p in (443,80):
        g=L.get(('tcp',p))
        if g and g not in ('stunnel4','stunnel','haproxy','python3','?'): bad.append('%d (%s)'%(p,g))
    for k,d in (('VWSTLS_PORT',8443),('VTCP_PORT',2053),('VWS_PORT',8080),('REALITY_PORT',8444),('TROJAN_PORT',2096),('WS_PORT',8880),('WSTLS_PORT',2083),('PANEL_PORT',0)):
        if P(k,d) in (443,80): bad.append('%d (used by %s in ReXUI, change it with menu → Port change)'%(P(k,d),k.replace('_PORT','')))
    return bad
def h_write():
    """Write the PEM and config, check them with haproxy -c. Returns '' or the error."""
    os.makedirs('/etc/haproxy',exist_ok=True)
    pem=h_pem(); cfg=h_cfg()
    wtext(HAPEM,pem,0o600)
    tmp=HAC+'.rexui-new'; wtext(tmp,cfg,0o644)
    r=run('haproxy','-c','-f',tmp,t=30)
    if r.returncode:
        os.remove(tmp); out=[x for x in (r.stdout+r.stderr).splitlines() if 'ALERT' in x or 'error' in x.lower()]
        return 'HAProxy did not accept the config: '+((out or ['unknown error'])[-1].strip()[-200:])
    if os.path.exists(HAC) and not os.path.exists(HAC+'.orig') and 'ReXUI' not in rd(HAC): shutil.copyfile(HAC,HAC+'.orig')
    os.replace(tmp,HAC); HQ['hash']=hashlib.sha256((cfg+pem).encode()).hexdigest(); return ''
def _h_talk(port,tls,data,want,t=6):
    """Connect to 127.0.0.1:port like an app, send data, read the reply. want(reply_bytes) decides ok."""
    try:
        s=socket.create_connection(('127.0.0.1',port),timeout=t)
        if tls:
            c=ssl.create_default_context(); c.check_hostname=False; c.verify_mode=ssl.CERT_NONE
            s=c.wrap_socket(s,server_hostname='www.example.com')
        if data: s.sendall(data)
        buf=b''; end=time.time()+t
        while time.time()<end and len(buf)<4096:
            try: x=s.recv(4096)
            except socket.timeout: break
            if not x: break
            buf+=x
            if want(buf): break
        s.close(); return want(buf),buf[:80]
    except Exception as e: return False,repr(e)[:80].encode()
def h_selftest():
    """Check the important paths through HAProxy. Returns a list of failed checks."""
    s=sload(); bad=[]; xp=(s['path'].rstrip('/') or '/')
    ssh=lambda b:b.startswith(b'SSH-')
    ws=lambda b:b.startswith(b'HTTP/1.1 101') and b'SSH-' in b
    xr=lambda b:b.startswith(b'HTTP/1.1') and not b.startswith(b'HTTP/1.1 101') and b'SSH-' not in b
    wsreq=b'GET / HTTP/1.1\r\nHost: www.example.com\r\nUpgrade: websocket\r\n\r\n'
    for name,port,tls,data,f in (('SSH SSL on 443',443,True,b'SSH-2.0-ReXUI_check\r\n',ssh),('SSH WebSocket TLS on 443',443,True,wsreq,ws),
                                 ('SSH WebSocket on 80',80,False,wsreq,ws),('SSH on 443 without TLS',443,False,b'SSH-2.0-ReXUI_check\r\n',ssh),
                                 ('VLESS XHTTP TLS on 443',443,True,('GET %s/rexui-check HTTP/1.1\r\nHost: www.example.com\r\n\r\n'%xp).encode(),xr)):
        ok,got=_h_talk(port,tls,data,f)
        if not ok: bad.append('%s (got: %s)'%(name,got.decode('latin-1','replace').replace('\r',' ').replace('\n',' ').strip() or 'nothing'))
    return bad
def h_apply(want=None,why=''):
    """Turn 443 mode on or off so the server matches the setting. Safe: anything that fails turns it back off."""
    with HQ['lock']:
        s=sload(); want=h_want() if want is None else want
        if want and not h_has():
            HQ['err']='HAProxy is not installed. Run the installer again to add it.'; want=False
        if want:
            b=h_busy()
            if b: HQ['err']='Port '+', '.join(b)+' is used by another program, so 443 mode stays off.'; want=False
        if not want:
            if h_on() or run('systemctl','is-active','--quiet','haproxy').returncode==0:
                run('systemctl','disable','--now','haproxy')
                try: os.remove(HON)
                except OSError: pass
                h_ssl_move(False); fsite_apply(); xray_apply(); bans_apply(True)
                log('443 mode off',why)
            return {'on':False,'err':HQ['err']}
        was=h_on()
        open(HON,'w').close()
        if not was: fsite_apply()
        e=xray_apply()
        if e: HQ['err']=e; return h_apply(False,'xray failed')
        old=rd(HAC)+rd(HAPEM); e=h_write()
        if e: HQ['err']=e; return h_apply(False,'config failed')
        h_ssl_move(True); act=run('systemctl','is-active','--quiet','haproxy').returncode==0
        if was and act:
            r=run('systemctl','reload','haproxy') if rd(HAC)+rd(HAPEM)!=old else run('true')
        else: run('systemctl','enable','haproxy'); r=run('systemctl','restart','haproxy')
        time.sleep(1.5)
        if r.returncode or run('systemctl','is-active','--quiet','haproxy').returncode:
            HQ['err']='HAProxy did not start: '+(run('journalctl','-u','haproxy','-n','3','--no-pager','-o','cat').stdout.strip().replace('\n',' ')[-200:] or 'unknown error')
            return h_apply(False,'start failed')
        bad=h_selftest()
        if bad: time.sleep(5); bad=h_selftest()
        if bad:
            HQ['err']='443 mode turned itself off because a check failed: '+'; '.join(bad)
            activity('server',HQ['err'][:300]); return h_apply(False,'self test failed')
        HQ['err']=''; HQ['fail']=0; bans_apply(True)
        if not was: log('443 mode on'); activity('server','443 mode is on (HAProxy on 443 and 80)')
        return {'on':True,'err':''}
def h_set(d):
    s=sload(); s['h443']=bool(d.get('on')); wjson(SETF,s,0o600)
    r=h_apply()
    if s['h443'] and not r['on']: raise Err(r['err'] or '443 mode could not be turned on')
    return r
def h_sync():
    """Called every minute: rewrite the config when the certificate, Reality names or ports changed, and watch HAProxy."""
    if not h_on(): return
    try:
        pem=h_pem(); cfg=h_cfg()
        if hashlib.sha256((cfg+pem).encode()).hexdigest()!=HQ['hash']:
            e=h_write()
            if e: log('443 mode:',e)
            else: run('systemctl','reload','haproxy')
        if run('systemctl','is-active','--quiet','haproxy').returncode:
            HQ['fail']+=1
            if HQ['fail']==2: run('systemctl','restart','haproxy'); log('watchdog: restarted haproxy')
            elif HQ['fail']>=4:
                HQ['fail']=0; s=sload(); s['h443']=False; wjson(SETF,s,0o600); h_apply(False,'haproxy keeps failing')
                HQ['err']='443 mode was turned off because HAProxy kept stopping. Turn it on again from Settings → Network ports.'
                activity('server',HQ['err']); tg_send('ReXUI watchdog: '+HQ['err'])
        else: HQ['fail']=0
    except Exception as e: log('443 mode sync:',repr(e))
def h_info():
    m,alt=h_ports()
    return {'on':h_on(),'want':h_want(),'has':h_has(),'err':HQ['err'],'ports':m,'alt':alt}

# ---------- backup / restore ----------
def backup_obj():
    o={'app':'rexui','ver':2,'date':datetime.datetime.now().isoformat(timespec='seconds'),'users':uload(),'settings':sload()}
    try:
        ob=ov_backup()
        if ob: o['ovpn']=ob
    except Exception as e: log('backup openvpn:',repr(e))
    k,pb=rd(DNSD+'/server.key').strip(),rd(DNSD+'/server.pub').strip()
    if re.fullmatch(r'[0-9a-f]{64}',k) and re.fullmatch(r'[0-9a-f]{64}',pb): o['dns']={'key':k,'pub':pb}
    wb=wg_backup()
    if wb: o['wg']=wb
    o['inbounds']=ib_load()
    pl=pay_load()
    if pl: o['payloads']=pl
    return o
def backup_file(path=None):
    os.makedirs(BKD,exist_ok=True); os.chmod(BKD,0o700)
    path=path or BKD+'/rexui-'+today()+'.json'; wjson(path,backup_obj())
    old=sorted(f for f in os.listdir(BKD) if f.startswith('rexui-') and f.endswith('.json'))
    for f in old[:-7]:
        try: os.remove(os.path.join(BKD,f))
        except OSError: pass
    return path
def restore(o):
    if not isinstance(o,dict) or o.get('app')!='rexui' or not isinstance(o.get('users'),list): raise Err('This is not a ReXUI backup file')
    good=[]; bad=0
    if not isinstance(o.get('users'),list): raise Err('This is not a ReXUI backup file')
    if len(o['users'])>20000: raise Err('Too many users in this backup')
    def same(a,v): return isinstance(v,bool)==isinstance(a,bool) and (isinstance(v,(int,float)) if isinstance(a,(int,float)) else isinstance(v,type(a)))
    for x in o['users']:
        if not isinstance(x,dict): bad+=1; continue
        n=str(x.get('name',''))
        if not NAME.fullmatch(n) or n.isdigit() or not re.fullmatch(r'[0-9a-f-]{36}',str(x.get('uuid',''))): bad+=1; continue
        pw=x.get('pw','')
        if not isinstance(pw,str) or len(pw)>256 or re.search(r'[\x00-\x1f\x7f]',pw): log('restore: user skipped (bad password):',n); bad+=1; continue
        e=x.get('exp','never')
        if e!='never':
            try: datetime.date.fromisoformat(str(e))
            except ValueError: x['exp']='never'
        b=newu(n,'','never'); b.update({k:x[k] for k in b if k in x and same(b[k],x[k])}); b.update({k:str(x[k]) for k in ('cdn','wgk','wgp','wgs','wgip') if x.get(k)})
        if isinstance(x.get('ibs'),list): b['ibs']=[str(i) for i in x['ibs']][:200]
        dv=x.get('dev',2); b['dev']=dv if isinstance(dv,int) and not isinstance(dv,bool) and 0<=dv<=100 else 2
        b['lim']=max(0.0,float(b['lim'])); b['rday']=b['rday'] if isinstance(b['rday'],int) and 0<=b['rday']<=28 else 0
        b['lk']=False; good.append(b)
    if not good and o['users']: raise Err('No valid users found in the backup')
    if isinstance(o.get('settings'),dict):
        try: ssave_raw(o['settings'],check=False,keys=True)
        except Err as e: log('restore: settings skipped:',e)
    with UL:
        us={u['name']:u for u in uload()}
        for b in good:
            n=b['name']
            if uidof(n) is None:
                r=run('useradd','-m','-s','/bin/false',n)
                for flag in ('--badname','--badnames'):
                    if r.returncode and 'name' in r.stderr: r=run('useradd',flag,'-m','-s','/bin/false',n)
                if r.returncode: log('restore: could not create',n); continue
            if run('chpasswd',inp='%s:%s\n'%(n,b['pw'] or secrets.token_urlsafe(12))).returncode: log('restore: could not set the password of',n); continue
            run('usermod','-U',n); setexp(n,b['exp'])
            us[n]=b
        usave(list(us.values()))
    if o.get('ovpn'):
        try: ov_restore(o['ovpn'],{b['name'] for b in good})
        except Exception as e: log('restore openvpn:',repr(e))
    dk=o.get('dns') if isinstance(o.get('dns'),dict) else {}
    if re.fullmatch(r'[0-9a-f]{64}',str(dk.get('key',''))) and re.fullmatch(r'[0-9a-f]{64}',str(dk.get('pub',''))):
        os.makedirs(DNSD,exist_ok=True); os.chmod(DNSD,0o700)
        if wtext(DNSD+'/server.key',dk['key']+'\n')|wtext(DNSD+'/server.pub',dk['pub']+'\n',0o644) and dns_on() and dns_ns(): run('systemctl','restart','rexui-dns')
    if isinstance(o.get('wg'),dict): wg_restore(o['wg'])
    if isinstance(o.get('inbounds'),list) and o['inbounds']:
        try: ib_restore(o['inbounds'])
        except Exception as e: log('restore inbounds:',repr(e))
    if isinstance(o.get('payloads'),list) and o['payloads']:
        try: pay_import({'items':o['payloads']})
        except Err: pass
    perf_apply()
    enforce(); ssh_rules(True); xray_apply(True)
    return {'ok':1,'users':len(good),'skipped':bad}
BKLAST=['']
def auto_backup():
    if BKLAST[0]==today(): return
    BKLAST[0]=today()
    try:
        try: maint_daily()
        except Exception as e: log('cleanup:',repr(e))
        bp=backup_file()
        if sload()['tgbackup']:
            def go():
                try: tg_doc(bp,'ReXUI daily backup %s · %d users. Keep this file private.'%(today(),len(uload())))
                except Exception as e: log('telegram backup:',str(e)[:120])
            threading.Thread(target=go,daemon=True).start()
    except Exception as e: log('auto backup:',repr(e))
    try: auto_delete()
    except Exception as e: log('auto delete:',repr(e))
    c=certinfo()
    if c.get('src')=='domain' and c.get('days') is not None and c['days']<=20: tg_send('⚠️ ReXUI: the Let\'s Encrypt certificate for %s did not renew automatically (%d days left). Run menu → SSL certificate → Renew on the server.'%(c['name'],c['days']))
    elif c.get('days') is not None and c['days'] in (30,14,7,3,1,0): tg_send('ReXUI: your certificate for %s expires in %d day(s).'%(c['name'],c['days']))

def ustate_part(uh):
    """Users for the live view. When nothing changed since the browser's last copy, send only the hash."""
    L=users_list(); h=hashlib.sha1(json.dumps(L,sort_keys=True).encode()).hexdigest()[:16]
    return {'uh':h} if uh and uh==h else {'users':L,'uh':h}
def users_list():
    on=sessions(); now=time.time(); out=[]; td=today()
    for u in uload():
        st=ustate(u); nip=len(IPSEEN.get(u['name'],{})); o=on.get(u['name'],0)+len(OVON.get(u['name'],[]))+HYON.get(u['name'],0)+(1 if u['name'] in WGON else 0)+((nip or 1) if now-XACT.get(u['name'],0)<XONW else 0)
        out.append({'name':u['name'],'exp':u['exp'],'lim':u['lim'],'used':u['up']+u['down'],'on':o,'dev':u.get('dev',0),'rday':u.get('rday',0),'note':u.get('note','')[:80],'created':u.get('created',''),'fdays':u.get('fdays',0),'trial':u.get('trial',False),'expts':u.get('expts',0),'kind':kind(u),
                    'st':'online' if st=='active' and o else st,'spd':SPD.get(u['name'],[0,0]) if o else [0,0],'seen':max(int(u.get('seen',0) or 0),LSEEN.get(u['name'],0)),
                    'today':sum((u.get('hist') or {}).get(td,[0,0]))+sum(UACC.get(u['name'],[0,0]))})
    return out

# ---------- services ----------
def listening(udp=False):
    s=set()
    for f in (('/proc/net/udp','/proc/net/udp6') if udp else ('/proc/net/tcp','/proc/net/tcp6')):
        for l in rd(f).splitlines()[1:]:
            p=l.split()
            if len(p)>3 and p[3]==('07' if udp else '0A'): s.add(int(p[1].rsplit(':',1)[1],16))
    return s
UNITS=['ssh','sshd','stunnel4','ws-ssh','badudp','fail2ban','xray','rexui-ovpn@rx1194','rexui-ovpn@rx110','squid','rexui-hy2','rexui-wg','rexui-dns']
RESTART={'haproxy','ssh','stunnel4','ws-ssh','badudp','fail2ban','xray','rexui-ovpn@rx1194','rexui-ovpn@rx110','squid','rexui-hy2','rexui-wg','rexui-dns'}
def units():
    st={}
    for blk in run('systemctl','show','-p','Id,LoadState,ActiveState',*[u+'.service' for u in UNITS]).stdout.strip().split('\n\n'):
        kv=dict(x.split('=',1) for x in blk.splitlines() if '=' in x)
        i=kv.get('Id','').replace('.service','')
        if i: st[i]=(kv.get('LoadState',''),kv.get('ActiveState',''))
    return st
def xsvc():
    out=[]; seen=set()
    if os.path.exists(XBIN):
        for x in ib_load():
            if ib_ok(x) and x['port'] not in (80,443) and x['port'] not in seen: seen.add(x['port']); out.append((x['name'],'xray',x['port']))
        if not out: out.append(('Xray','xray',0))
    return out
def services():
    st=units(); ls=listening(); lu=listening(True)
    def s(u):
        for x in (['ssh','sshd'] if u=='ssh' else [u]):
            if x in st and st[x][0] not in ('not-found',''): return st[x]
        return ('not-found','inactive')
    out=[]
    for name,u,port in [('SSH','ssh',P('SSH_PORT',22)),('SSL','stunnel4',P('SSL_PORT',443)),('SSH WS','ws-ssh',P('WS_PORT',8880)),
                        ('SSH WS TLS','stunnel4',P('WSTLS_PORT',2083)),('UDPGW','badudp',P('UDPGW_PORT',7300)),('Fail2ban','fail2ban',0),
                        *xsvc(),
                        ('OpenVPN TCP','rexui-ovpn@rx1194',P('OVPN1_PORT',1194)),('OpenVPN TCP','rexui-ovpn@rx110',P('OVPN2_PORT',110)),('HTTP proxy (Squid)','squid',P('SQUID_PORT',3128)),('Hysteria2 UDP','rexui-hy2',-hyport()),('WireGuard UDP','rexui-wg',-wgport()),('DNS tunnel','rexui-dns',-5300)]:
        l,a=s(u); up_=port<0; port=abs(port)
        v='NOT INSTALLED' if l=='not-found' else 'RUNNING' if a=='active' and (not port or port in (lu if up_ else ls)) else 'FAILED' if a=='failed' else 'IDLE'
        if (u.startswith('rexui-ovpn') or u=='squid') and not ov_on(): continue
        if u=='rexui-hy2' and not hy_on(): continue
        if u=='rexui-wg' and not wg_on(): continue
        if u=='rexui-dns' and not dns_on(): continue
        out.append({'name':name,'unit':u,'port':port,'st':v,'udp':up_})
    return out
WDOG={}
def watchdog():
    """Restart a service that is enabled but not working (stopped, failed, or running without its port) for 2 checks in a row.
    At most one restart per service every 10 minutes."""
    now=time.time(); bad=set()
    for x in services():
        if x['st'] in ('IDLE','FAILED'): bad.add(x['unit'])
    ls=listening()
    for name,lp,_,_ in (ovi() if ov_on() else []):
        if name not in OVBASE and lp not in ls: bad.add('rexui-ovpn@'+name)
    if not bad:
        WDOG.clear(); return
    en=run('systemctl','is-enabled',*sorted(bad)).stdout.split()
    for u,e in zip(sorted(bad),en+['']*len(bad)):
        if e!='enabled' or (u=='rexui-dns' and not dns_ns()): WDOG.pop(u,None); continue
        w=WDOG.setdefault(u,{'n':0,'last':0}); w['n']+=1
        if w['n']>=2 and now-w['last']>600:
            w['n']=0; w['last']=now; run('systemctl','restart',u); log('watchdog: restarted',u)
            activity('server','Watchdog restarted %s (it was not working)'%u); tg_send('ReXUI watchdog: restarted %s on %s (it was not working)'%(u,INFO.get('host','server')))
    for u in [u for u in WDOG if u not in bad]: WDOG.pop(u)
def restart(u):
    if u not in RESTART: raise Err('This service cannot be restarted')
    r=run('systemctl','restart',u)
    if r.returncode and u=='ssh': r=run('systemctl','restart','sshd')
    if r.returncode: raise Err('Restart failed: '+(r.stderr.strip()[-120:] or u))
    return {'ok':1}

# ---------- system stats ----------
H={k:[] for k in ('cpu','ram','swap','disk','rx','tx','tcp','udp')}; S={'cpu':0,'rx':0,'tx':0,'rxt':0,'txt':0}
def cpu_t():
    a=list(map(int,rd('/proc/stat').split('\n',1)[0].split()[1:])); return sum(a),a[3]+(a[4] if len(a)>4 else 0)
def net_t():
    r=t=0
    for l in rd('/proc/net/dev').splitlines()[2:]:
        if ':' not in l: continue
        n,v=l.split(':',1); n=n.strip()
        if n=='lo' or n.startswith(('docker','veth','br-','virbr')): continue
        v=v.split(); r+=int(v[0]); t+=int(v[8])
    return r,t
def mem():
    m={}
    for l in rd('/proc/meminfo').splitlines():
        k,v=l.split(':',1); m[k]=int(v.split()[0])*1024
    return m
HMK=('cpu','ram','rx','tx','tcp','udp'); HISTF=T+'/hist.json'; HM={k:[] for k in ('t',)+HMK}; ACC={k:[] for k in HMK}
def hm_load():
    try:
        o=json.loads(rd(HISTF)); cut=time.time()-86400
        keep=[i for i,t in enumerate(o['t']) if t>cut]
        for k in HM: HM[k]=[o[k][i] for i in keep]
    except Exception: pass
def hm_tick():
    if not ACC['cpu']: return
    HM['t'].append(int(time.time()))
    for k in HMK: HM[k].append(round(sum(ACC[k])/len(ACC[k]),2)); ACC[k].clear()
    if len(HM['t'])>1440:
        for k in HM: del HM[k][:-1440]
def hm_save():
    try: wjson(HISTF,HM)
    except Exception as e: log('hist save:',repr(e))
def push(k,v):
    if k in ACC: ACC[k].append(v)
    H[k].append(round(v,2))
    if len(H[k])>60: H[k].pop(0)
def sample():
    m=mem(); du=shutil.disk_usage('/')
    push('ram',100*(1-m['MemAvailable']/m['MemTotal'])); push('swap',100*(1-m['SwapFree']/m['SwapTotal']) if m.get('SwapTotal') else 0); push('disk',100*du.used/du.total)
def monitor():
    pc,pn,pt,i=cpu_t(),net_t(),time.time(),0
    while True:
        time.sleep(5); i+=1
        try:
            c,n,t=cpu_t(),net_t(),time.time(); dt=max(.1,t-pt)
            S['cpu']=max(0,100*(1-(c[1]-pc[1])/max(1,c[0]-pc[0]))); S['rx'],S['tx']=max(0,(n[0]-pn[0])/dt),max(0,(n[1]-pn[1])/dt); S['rxt'],S['txt']=n
            tr_net(n[0]-pn[0],n[1]-pn[1]); pc,pn,pt=c,n,t; push('cpu',S['cpu']); push('rx',S['rx']); push('tx',S['tx']); sample(); tc,uc=conn(); push('tcp',tc); push('udp',uc)
            xlog_read()
            if i%12==0: hm_tick(); health_check(); daily_jobs(); ov_net(); hy_setup(); wg_up(); dns_redirect(); fail_clean()
            if i%12==6:
                try: watchdog()
                except Exception as e: log('watchdog:',repr(e))
                h_sync()
            if i%120==0: hm_save(); tr_save()
            if i%360==1: threading.Thread(target=ddns_update,daemon=True).start()
            if i%4320==24: threading.Thread(target=rx_check,daemon=True).start()
            if i%120==60: threading.Thread(target=rw_check,daemon=True).start()   # Reality Watch every 10 minutes
            if i%12==3: threading.Thread(target=lambda:(geo_fetch(),geo_alerts()),daemon=True).start()
            if i%2==0:
                collect(); enforce(); trial_cleanup(); xray_apply(); ssh_rules(); devices(); auto_backup()
                try: wtext('/run/rexui-online',str(sum(1 for u in users_list() if u['on'])),0o644)
                except Exception: pass
        except Exception as e: log('monitor:',repr(e))
def conn():
    c=lambda fs:sum(max(0,len(rd(f).splitlines())-1) for f in fs)
    return c(('/proc/net/tcp','/proc/net/tcp6')),c(('/proc/net/udp','/proc/net/udp6'))
INFO={}; IPS={'v4':'','v6':''}
def static():
    o=re.search(r'PRETTY_NAME="?([^"\n]+)',rd('/etc/os-release')); c=re.search(r'model name\s*:\s*(.+)',rd('/proc/cpuinfo'))
    v=run('systemd-detect-virt').stdout.strip() or 'none'
    INFO.update(host=socket.gethostname(),os=o[1] if o else platform.system(),kernel=platform.release(),
                cpu=c[1].strip() if c else platform.machine(),cores=os.cpu_count() or 1,virt='No' if v=='none' else v)
def fetch_ips():
    IPS['v4']=run('curl','-4','-s','--max-time','6','ifconfig.me',t=10).stdout.strip()[:45]
    IPS['v6']=run('curl','-6','-s','--max-time','6','ifconfig.me',t=10).stdout.strip()[:45]
XVER=['']
def xinfo():
    if not XVER[0] and os.path.exists(XBIN):
        m=re.search(r'Xray\s+([0-9.]+)',run(XBIN,'version',t=10).stdout); XVER[0]=m[1] if m else '?'
    up=0
    try:
        v=int(run('systemctl','show','xray','-p','ActiveEnterTimestampMonotonic','--value',t=10).stdout.strip() or 0)
        if v: up=max(0,float(rd('/proc/uptime','0').split()[0])-v/1e6)
    except ValueError: pass
    return {'ver':XVER[0],'up':up}
def procinfo():
    st=rd('/proc/self/status'); m=re.search(r'VmRSS:\s+(\d+)',st); t=re.search(r'Threads:\s+(\d+)',st)
    return {'ram':int(m[1])*1024 if m else 0,'threads':int(t[1]) if t else 0}
def state(uh=''):
    m=mem(); du=shutil.disk_usage('/'); tc,uc=conn()
    return {'info':dict(INFO,uptime=float(rd('/proc/uptime','0').split()[0]),puptime=time.time()-START),
            'cpu':S['cpu'],'ram':[m['MemTotal']-m['MemAvailable'],m['MemTotal']],'swap':[m.get('SwapTotal',0)-m.get('SwapFree',0),m.get('SwapTotal',0)],
            'disk':[du.used,du.total],'rx':S['rx'],'tx':S['tx'],'rxt':S['rxt'],'txt':S['txt'],'hist':H,'tcp':tc,'udp':uc,
            'ip':IPS,'stats':stats(),'tools':TOOLS,'fs':FS['err'],'xup':XUP,'rxup':rx_info(),'ddns':dict(DDNS,dom=sload()['ddns_dom']),'stime':time.strftime('%H:%M %Z'),'svc':services(),'xray':xinfo(),'proc':procinfo(),'online':online(),'ibs':ib_view(),'cpath':cert_paths(),'rw':RW,'backups':sorted(os.listdir(BKD))[::-1] if os.path.isdir(BKD) else [],**ustate_part(uh),'cert':certinfo(),'set':dict({k:v for k,v in sload().items() if k not in ('rpriv','tgtoken','ddns_tok')},tgmask=mask(sload()['tgtoken']),ddmask=mask(sload()['ddns_tok'])),'tfa':bool(lread().get('totp')),'warp':warp_info(),'geo':geo_ok(),'addr':pub_addr(),'me':curuser(),'ov':ov_on(),'hy':hy_on(),'wg':wg_on(),'dns':dns_info(),'cdn':cdn_info(),'pays':pay_load(),'pvals':pay_vals(),'h443':h_info(),
            'port':E.get('PANEL_PORT',''),'path':E.get('WEB_PATH',''),'ports':dict({k:v for k,v in E.items() if k.endswith('_PORT')},REALITY_PORT=str(P('REALITY_PORT',8444)),TROJAN_PORT=str(P('TROJAN_PORT',2096)),OVPN1_PORT=str(P('OVPN1_PORT',1194)),OVPN2_PORT=str(P('OVPN2_PORT',110)),SQUID_PORT=str(P('SQUID_PORT',3128)),HY_PORT=str(hyport()),WG_PORT=str(wgport()),HY_HOP='%d-%d'%hyhop() if hyhop() else '')}

# ---------- stats: server traffic, protocols, top users ----------
TRF=T+'/traffic.json'; TR={'days':{},'proto':{}}; TRL=threading.Lock()
PNAME={'vless-dns':'DNS V2Ray','vless-xhttp-tls':'XHTTP TLS','vless-tcp-tls':'TCP TLS','vless-xhttp':'XHTTP','trojan-tls':'Trojan','vless-reality':'Reality'}
def tr_load():
    try:
        o=json.loads(rd(TRF)); TR['days']=o.get('days') or {}; TR['proto']=o.get('proto') or {}
    except Exception: pass
def tr_save():
    with TRL:
        for k in sorted(TR['days'])[:-400]: TR['days'].pop(k,None)
        for k in sorted(TR['proto'])[:-31]: TR['proto'].pop(k,None)
        try: wjson(TRF,TR)
        except Exception as e: log('traffic save:',repr(e))
def tr_net(dr,dt):
    if dr<0 or dt<0: return
    with TRL: e=TR['days'].setdefault(today(),[0,0]); e[0]+=dr; e[1]+=dt
def tr_proto(p,up,down):
    if not (up or down): return
    with TRL: e=TR['proto'].setdefault(today(),{}).setdefault(p,[0,0]); e[0]+=up; e[1]+=down
def xstats_in():
    if not os.path.exists(XBIN): return
    r=run(XBIN,'api','statsquery','--server='+XAPI,'-pattern','inbound>>>','-reset',t=10)
    if r.returncode: return
    try: items=json.loads(r.stdout).get('stat') or []
    except Exception: items=[{'name':a,'value':b} for a,b in re.findall(r'"name":\s*"([^"]+)"[^}]*?"value":\s*"?(\d+)',r.stdout)]
    for it in items:
        p=str(it.get('name','')).split('>>>')
        if len(p)==4 and p[1].startswith('vless-reality-'): p[1]='vless-reality'
        if len(p)==4 and p[1].startswith('ib-') and p[1] not in PNAME:
            nm=next((x['name'] for x in ib_load() if 'ib-%d'%x['port']==p[1]),'')
            if nm: PNAME[p[1]]=nm[:30]
        if len(p)==4 and p[1] in PNAME:
            try: v=int(it.get('value') or 0)
            except ValueError: v=0
            tr_proto(PNAME[p[1]],v if p[3]=='uplink' else 0,v if p[3]=='downlink' else 0)
def stats():
    t=today(); ym=t[:7]; dd=datetime.date.today(); tu,mu=[],[]
    for u in uload():
        h=u.get('hist') or {}; a=sum(h.get(t,[0,0])); b=sum(sum(v) for k,v in h.items() if k.startswith(ym))
        if a: tu.append([u['name'],a])
        if b: mu.append([u['name'],b])
    with TRL:
        days=[[d,*TR['days'].get(d,[0,0])] for d in ((dd-datetime.timedelta(days=i)).isoformat() for i in range(29,-1,-1))]
        mo={}
        for k,v in TR['days'].items(): m=mo.setdefault(k[:7],[0,0]); m[0]+=v[0]; m[1]+=v[1]
        y,m=dd.year,dd.month; months=[]
        for _ in range(12): k='%04d-%02d'%(y,m); months.append([k,*mo.get(k,[0,0])]); y,m=(y,m-1) if m>1 else (y-1,12)
        pt={k:list(v) for k,v in TR['proto'].get(t,{}).items()}; p30={}
        for day in TR['proto'].values():
            for k,v in day.items(): e=p30.setdefault(k,[0,0]); e[0]+=v[0]; e[1]+=v[1]
    return {'today':sorted(tu,key=lambda x:-x[1])[:5],'month':sorted(mu,key=lambda x:-x[1])[:5],'days':days,'months':months[::-1],'ptoday':pt,'p30':p30}

# ---------- login history, activity log, sessions ----------
LOGF=T+'/logins.json'; ACTF=T+'/activity.json'; LGL=threading.Lock()
def jlist(p):
    try:
        v=json.loads(rd(p)); return v if isinstance(v,list) else []
    except Exception: return []
def jpush(p,item,n):
    with LGL: l=jlist(p); l.append(item); wjson(p,l[-n:])
def login_log(ip,user,res,ua): jpush(LOGF,{'t':int(time.time()),'ip':ip,'user':str(user)[:64],'res':res,'ua':str(ua)[:160]},100)
def activity(ip,txt): jpush(ACTF,{'t':int(time.time()),'ip':ip,'a':txt[:200]},300)
def sid(t): return hashlib.sha256(t.encode()).hexdigest()[:12]
def logs(me):
    now=time.time()
    ss=[{'id':sid(k),'ip':v['ip'],'ua':v['ua'],'t':v['t'],'me':k==me} for k,v in SESS.items() if v['exp']>now]
    return {'sessions':sorted(ss,key=lambda x:-x['t']),'logins':jlist(LOGF)[::-1],'activity':jlist(ACTF)[::-1]}
def session_kill(me,d):
    if d.get('all'):
        for k in [k for k in SESS if k!=me]: SESS.pop(k,None)
        return {'ok':1}
    k=next((k for k in SESS if sid(k)==str(d.get('id',''))),None)
    if not k: raise Err('This session has already ended')
    if k==me: raise Err('Use Log out to end your own session')
    SESS.pop(k,None); return {'ok':1}
def act_desc(r,d,res):
    n=str(d.get('name',''))
    if r.startswith('/api/user/'):
        a=r[10:]
        if a=='toggle':
            u=next((x for x in uload() if x['name']==n),None)
            return 'Enabled user '+n if u and u.get('en',True) else 'Disabled user '+n+(' ('+str(d.get('reason'))[:60]+')' if d.get('reason') else '')
        return {'newsub':'Made a new subscription link for %s','newuuid':'Made a new UUID for %s','newwg':'Made new WireGuard keys for %s','newcert':'Made a new OpenVPN certificate for %s','add':'Added user %s','edit':'Edited user %s','reset':'Reset data usage of %s','kick':'Disconnected %s','del':'Deleted user %s'}.get(a,'%s')%n if a not in ('detail','rename') else ('Renamed user %s to %s'%(n,str(d.get('new',''))[:32]) if a=='rename' else None)
    if r=='/api/bulk':
        a=d.get('action'); w={'days':'added %s days'%d.get('days'),'reset':'reset data usage','disable':'disabled','enable':'enabled','delete':'deleted','dev':'set device limit %s for'%d.get('dev')}.get(a,a)
        nm=d.get('names') if isinstance(d.get('names'),list) else None
        return 'Bulk: %s %s'%(w,', '.join(map(str,nm)) if nm and len(nm)<=5 else '%d user(s)'%res.get('count',0))
    if r=='/api/trial': return 'Created %s trial user %s'%({'v2ray':'V2Ray','ssh':'SSH','ovpn':'OpenVPN','hy2':'UDP (Hysteria2)','dns':'DNS','wg':'WireGuard'}.get(d.get('kind'),''),res.get('name',''))
    if r.startswith('/api/inbound/'):
        a=r[13:]; nm=str(d.get('name') or next((x['name'] for x in ib_load() if x['id']==d.get('id')),'') or '')
        return {'add':'Added inbound %s','edit':'Changed inbound %s','toggle':'Turned inbound %s on/off','del':'Deleted inbound %s','restore':'Added the default inbounds back%s','move':'Moved inbound %s','quick':'Added the 1-click inbounds%s','quickdel':'Removed the 1-click inbounds%s'}.get(a,'Inbound %s')%(nm if a not in ('restore','quick','quickdel') else '')
    if r=='/api/ovpn-set': return 'Changed the OpenVPN default Host'
    if r=='/api/dns-set': return 'Changed the DNS tunnel domain'
    if r=='/api/hy-set': return 'Changed the UDP speed limit to %s Mbps'%(d.get('hy_bw') or 0)
    if r=='/api/cdn-set': return 'Changed the CDN domain to %s'%(d.get('cdn_dom') or 'off')
    if r=='/api/perf-set': return 'Changed the performance mode to %s'%d.get('perf')
    if r=='/api/jsub-set': return 'Changed the JSON subscription settings'
    if r=='/api/payload/save': return 'Saved the payload %s'%str(d.get('name',''))[:40]
    if r=='/api/payload/del': return 'Deleted a payload'
    if r=='/api/payload/import': return 'Imported payloads'
    if r=='/api/check/fix': return 'Server check fix: %s'%d.get('fix')
    if r=='/api/h443': return '443 mode turned '+('on' if d.get('on') else 'off')
    if r=='/api/fw-open': return 'Opened %s/%s in the firewall'%(d.get('port'),d.get('proto'))
    if r in ('/api/payload/test','/api/check','/api/ports'): return None
    if r=='/api/csv-import': return 'Imported %d user(s) from CSV'%res.get('added',0)
    if r=='/api/restore': return 'Restored a backup (%d users)'%res.get('users',0)
    if r=='/api/svc': return 'Restarted %s'%d.get('unit','')
    return {'/api/cert':'Changed the SSL certificate','/api/settings':'Changed Xray defaults','/api/reality-keys':'Created new Reality keys',
            '/api/routing':'Changed routing','/api/warp-reset':'Removed the WARP account','/api/login-change':'Changed the panel login',
            '/api/2fa/enable':'Turned on 2FA','/api/2fa/disable':'Turned off 2FA','/api/automation':'Changed automation and alerts',
            '/api/appearance':'Changed appearance','/api/subpage':'Changed the subscription page','/api/reboot':'Changed the scheduled reboot',
            '/api/session-kill':'Logged out another session','/api/tg-backup':'Sent a backup to Telegram','/api/cleanup':'Cleaned up disk space',
            '/api/swap':'Changed the swap file' if d.get('gb') else 'Removed the swap file','/api/fsite':'Changed the fake website','/api/rdefault':'Changed the default Reality target',
            '/api/xupdate':'Started an Xray update','/api/xauto':'Changed Xray auto update','/api/ddns':'Changed DuckDNS','/api/panel-path':'Changed the panel address','/api/autoclean':'Changed automatic cleanup'}.get(r)

# ---------- health alerts, daily report, Telegram backup ----------
HEALTH={'bad':{},'svc':{},'rep':''}
def tg_doc(path,caption,s=None):
    import urllib.request
    s=s or sload()
    if not (s['tgtoken'] and s['tgchat']): raise Err('Set the Telegram bot token and chat ID first')
    b='----rexui'+secrets.token_hex(8); body=b''
    for k,v in (('chat_id',s['tgchat']),('caption',caption)):
        body+=('--%s\r\nContent-Disposition: form-data; name="%s"\r\n\r\n%s\r\n'%(b,k,v)).encode()
    with open(path,'rb') as f: data=f.read()
    body+=('--%s\r\nContent-Disposition: form-data; name="document"; filename="%s"\r\nContent-Type: application/json\r\n\r\n'%(b,os.path.basename(path))).encode()+data+('\r\n--%s--\r\n'%b).encode()
    rq=urllib.request.Request(TGAPI%(s['tgtoken'],'sendDocument'),data=body,headers={'Content-Type':'multipart/form-data; boundary='+b})
    try:
        with urllib.request.urlopen(rq,timeout=40) as r: o=json.loads(r.read().decode())
    except Exception as e: raise Err('Telegram did not accept the file: '+str(e)[:120])
    if not o.get('ok'): raise Err('Telegram error: '+str(o.get('description',''))[:120])
    return {'ok':1}
def tg_backup_now():
    p=backup_file(); tg_doc(p,'ReXUI backup %s · %d users. Keep this file private.'%(today(),len(uload()))); return {'ok':1}
def health_check():
    s=sload()
    if not s['health']: return
    m=mem(); du=shutil.disk_usage('/'); cpu=sum(H['cpu'][-12:])/max(1,len(H['cpu'][-12:]))
    vals={'cpu':(cpu,'CPU'),'ram':(100*(1-m['MemAvailable']/m['MemTotal']),'RAM'),'disk':(100*du.used/du.total,'Disk')}
    for k,(v,lab) in vals.items():
        was=HEALTH['bad'].get(k)
        if v>=90 and not was: HEALTH['bad'][k]=time.time(); tg_send('⚠️ ReXUI alert: %s is at %.0f%% on %s'%(lab,v,INFO.get('host','server')))
        elif v<80 and was: HEALTH['bad'].pop(k,None); tg_send('✅ ReXUI: %s is back to normal (%.0f%%)'%(lab,v))
    st=units()
    for name,u in (('Xray','xray'),('SSH WebSocket','ws-ssh'),('SSL (stunnel)','stunnel4'),('UDPGW','badudp'),('SSH','ssh')):
        if u=='ssh' and (st.get('ssh') or ('',))[0] in ('not-found',''): u='sshd'
        x=st.get(u)
        if not x or x[0] in ('not-found',''): continue
        if x[1]=='active':
            if HEALTH['svc'].pop(u,0)>=2: tg_send('✅ ReXUI: %s is running again'%name)
            continue
        c=HEALTH['svc'][u]=HEALTH['svc'].get(u,0)+1
        if c==2:
            run('systemctl','restart',u,t=30); ok=run('systemctl','is-active',u).stdout.strip()=='active'
            tg_send('⚠️ ReXUI alert: %s was down. Automatic restart %s.'%(name,'worked' if ok else 'failed, please check the server'))
            if ok: HEALTH['svc'].pop(u,None)
def report_text():
    us=uload(); t=today(); y=(datetime.date.today()-datetime.timedelta(days=1)).isoformat(); L=users_list()
    st={}; [st.__setitem__(x['st'],st.get(x['st'],0)+1) for x in L]
    soon=[]
    for u in us:
        if u.get('trial') or ustate(u)!='active': continue
        if u['exp']!='never':
            dl=(datetime.date.fromisoformat(u['exp'])-datetime.date.today()).days
            if dl<=3: soon.append('%s (%s)'%(u['name'],'today' if dl<=0 else '%dd'%dl)); continue
        if u.get('lim') and u['up']+u['down']>=u['lim']*GB*.9: soon.append('%s (%d%% data)'%(u['name'],100*(u['up']+u['down'])/(u['lim']*GB)))
    def fb(b):
        for x in ('B','KB','MB','GB'):
            if b<1024: return '%.1f %s'%(b,x) if x!='B' else '%d B'%b
            b/=1024
        return '%.2f TB'%b
    with TRL: ty=TR['days'].get(y,[0,0]); tt=TR['days'].get(t,[0,0])
    top=sorted(((u['name'],sum((u.get('hist') or {}).get(y,[0,0]))) for u in us),key=lambda x:-x[1])[:3]
    m=mem(); du=shutil.disk_usage('/'); c=certinfo()
    out=['📊 %s daily report · %s'%(sload()['brand'] or 'ReXUI',t),
         'Users: %d total · %d active · %d online · %d ended'%(len(L),st.get('active',0)+st.get('online',0),st.get('online',0),st.get('expired',0)+st.get('limit',0)),
         'Expiring soon: '+(', '.join(soon[:15]) if soon else 'none'),
         'Server traffic yesterday: ↓ %s ↑ %s'%(fb(ty[0]),fb(ty[1])),'Today so far: ↓ %s ↑ %s'%(fb(tt[0]),fb(tt[1]))]
    if any(x[1] for x in top): out.append('Top users yesterday: '+', '.join('%s %s'%(n,fb(b)) for n,b in top if b))
    out.append('Server: CPU %.0f%% · RAM %.0f%% · Disk %.0f%%'%(S['cpu'],100*(1-m['MemAvailable']/m['MemTotal']),100*du.used/du.total))
    if c.get('days') is not None: out.append('Certificate: %d days left'%c['days'])
    return '\n'.join(out)
def daily_jobs():
    s=sload(); now=datetime.datetime.now()
    if s['xauto'] and now.weekday()==6 and now.hour==5 and XUP.get('auto')!=today():
        XUP['auto']=today()
        def go():
            try: xupdate(auto=True)
            except Exception: pass
        threading.Thread(target=go,daemon=True).start()
    if s['report'] and now.hour==int(s['rhour']) and HEALTH['rep']!=today():
        HEALTH['rep']=today(); tg_send(report_text(),s)

# ---------- server tools: speed test, port check, scheduled reboot ----------
TOOLS={'speed':{}}
SPEEDURL=os.environ.get('REXUI_SPEEDURL','https://speed.cloudflare.com')
def speedtest():
    if TOOLS['speed'].get('run'): raise Err('A speed test is already running')
    TOOLS['speed']={'run':1,'t':int(time.time())}
    def go():
        o={'t':int(time.time())}
        try:
            pings=[]
            for _ in range(3):
                r=run('curl','-s','-o','/dev/null','-w','%{time_connect}',SPEEDURL+'/__down?bytes=0','--max-time','8',t=12)
                try: pings.append(float(r.stdout)*1000)
                except ValueError: pass
            o['ping']=round(min(pings),1) if pings else None
            f=T+'/.speed.bin'
            with open(f,'wb') as x: x.write(os.urandom(1024*1024))
            def phase(kind,secs=7,n=1):
                tot=[0]; err=['']; lk=threading.Lock(); ps=[]
                def w():
                    try:
                        if kind=='d':
                            p=sp.Popen(['curl','-s','--max-time','30']+[SPEEDURL+'/__down?bytes=25000000']*400,stdout=sp.PIPE,stderr=sp.DEVNULL); ps.append(p)
                            while True:
                                b=p.stdout.read1(1<<20)
                                if not b: break
                                with lk: tot[0]+=len(b)
                        else:
                            p=sp.Popen(['stdbuf','-oL','curl','-s','--max-time','30','-w','%{http_code} %{size_upload}\n','--data-binary','@'+f,'-H','Content-Type: application/octet-stream']+['-o','/dev/null',SPEEDURL+'/__up']*400,
                                       stdout=sp.PIPE,stderr=sp.DEVNULL,text=True); ps.append(p)
                            for ln in p.stdout:
                                try: code,b=ln.split(); b=int(float(b))
                                except ValueError: continue
                                if code=='200':
                                    with lk: tot[0]+=b
                                elif code!='000': err[0]='HTTP '+code
                    except Exception as e: err[0]=str(e)[:60]
                st=time.time(); th=[threading.Thread(target=w,daemon=True) for _ in range(n)]
                for x in th: x.start()
                time.sleep(secs); el=time.time()-st
                with lk: got=tot[0]
                for p in ps:
                    try: p.kill()
                    except Exception: pass
                for x in th: x.join(3)
                return got/el,err[0] or ('no answer' if not got else '')
            o['down'],e1=phase('d'); o['up'],e2=phase('u')
            os.remove(f)
            if e1 and not o['down']: o['err']='Download test failed ('+e1+')'
            elif e2 and not o['up']: o['err']='Upload test failed ('+e2+')'
            if not o['down'] and not o['up']: o['err']='The test server could not be reached'
        except Exception as e: o['err']=str(e)[:120]
        TOOLS['speed']=o
    threading.Thread(target=go,daemon=True).start(); return {'ok':1}
CRONF='/etc/cron.d/rexui-reboot'
def reboot_save(d):
    s=sload(); m=str(d.get('reboot','off'))
    if m not in ('off','daily','weekly'): raise Err('bad request')
    day=ival(d,'rbday',0,6,0); tm=str(d.get('rbtime','04:00')).strip()
    if not re.fullmatch(r'([01]?\d|2[0-3]):[0-5]\d',tm): raise Err('Time must be like 04:30')
    s['reboot'],s['rbday'],s['rbtime']=m,day,tm; wjson(SETF,s,0o600); cron_apply(); return {'ok':1}
def cron_apply():
    s=sload()
    if s['reboot']=='off':
        try: os.remove(CRONF)
        except OSError: pass
        return
    h,mi=s['rbtime'].split(':')
    with open(CRONF,'w') as f: f.write('# ReXUI scheduled reboot (change it in the panel)\n%d %d * * %s root /sbin/shutdown -r now\n'%(int(mi),int(h),'*' if s['reboot']=='daily' else s['rbday']))
    os.chmod(CRONF,0o644)

# ---------- subscription page and config names ----------
def subpage_save(d):
    s=sload(); a=re.sub(r'[\x00-\x09\x0b-\x1f\x7f]','',str(d.get('announce','') or '')).strip()
    if len(a)>500: raise Err('Announcement is too long (max 500 characters)')
    c=textval(d.get('cname'),80,'Config name') or '{user}-{proto}'
    if '{proto}' not in c and '{type}' not in c: raise Err('The config name must contain {proto} or {type}, so the configs have different names')
    f=str(d.get('flag','')).strip().upper()
    if f and not re.fullmatch(r'[A-Z]{2}',f): raise Err('Flag must be a 2-letter country code, like DE or US')
    s['announce'],s['cname'],s['flag']=a,c,f; wjson(SETF,s,0o600); return {'ok':1}
def cfgname(u,code,typ,s):
    f=''.join(chr(0x1F1E6+ord(c)-65) for c in s['flag']) if s['flag'] else ''
    t=s['cname'].replace('{flag}',f).replace('{brand}',s['brand'] or 'ReXUI').replace('{user}',u['name']).replace('{proto}',code).replace('{type}',typ)
    return quote(re.sub(r'\s+',' ',t).strip() or code)


# ---------- captcha (shown after 3 wrong logins) ----------
GLY={'A':[[(0,6),(2,0),(4,6)],[(1,3.6),(3,3.6)]],'C':[[(4,1),(3,0),(1,0),(0,1),(0,5),(1,6),(3,6),(4,5)]],'E':[[(4,0),(0,0),(0,6),(4,6)],[(0,3),(3,3)]],
 'F':[[(4,0),(0,0),(0,6)],[(0,3),(3,3)]],'H':[[(0,0),(0,6)],[(4,0),(4,6)],[(0,3),(4,3)]],'K':[[(0,0),(0,6)],[(4,0),(0,3.6)],[(1.4,2.5),(4,6)]],
 'M':[[(0,6),(0,0),(2,3),(4,0),(4,6)]],'N':[[(0,6),(0,0),(4,6),(4,0)]],'P':[[(0,6),(0,0),(3,0),(4,1),(4,2),(3,3),(0,3)]],'T':[[(0,0),(4,0)],[(2,0),(2,6)]],
 'U':[[(0,0),(0,5),(1,6),(3,6),(4,5),(4,0)]],'V':[[(0,0),(2,6),(4,0)]],'W':[[(0,0),(1,6),(2,2),(3,6),(4,0)]],'X':[[(0,0),(4,6)],[(4,0),(0,6)]],
 'Y':[[(0,0),(2,3),(4,0)],[(2,3),(2,6)]],'3':[[(0,0),(4,0),(2,2.5),(3,2.5),(4,3.5),(4,5),(3,6),(1,6),(0,5)]],'4':[[(3,6),(3,0),(0,4),(4,4)]],'7':[[(0,0),(4,0),(1.5,6)]]}
CAPS={}
def captcha():
    import random
    R=random.SystemRandom(); now=time.time()
    for k in [k for k,v in CAPS.items() if v[1]<now]: CAPS.pop(k,None)
    if len(CAPS)>2000: CAPS.clear()
    ch=''.join(R.choice(list(GLY)) for _ in range(5)); cid=secrets.token_hex(12); CAPS[cid]=(ch,now+300)
    o=['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 64" width="200" height="64"><rect width="200" height="64" rx="8" fill="#eef1f6"/>']
    for _ in range(5): o.append('<path d="M%.0f %.0f Q %.0f %.0f %.0f %.0f" stroke="hsl(%d,45%%,62%%)" stroke-width="%.1f" fill="none"/>'%(R.uniform(0,40),R.uniform(5,60),R.uniform(60,140),R.uniform(-20,84),R.uniform(160,200),R.uniform(5,60),R.randint(0,359),R.uniform(1,2.2)))
    for i,c in enumerate(ch):
        sc=R.uniform(6.2,7.4); d=' '.join('M'+' L'.join('%.2f %.2f'%(x+R.uniform(-.15,.15),y+R.uniform(-.15,.15)) for x,y in st) for st in GLY[c])
        o.append('<path transform="translate(%.1f %.1f) rotate(%.1f 14 21) scale(%.2f)" d="%s" stroke="hsl(%d,55%%,28%%)" stroke-width="%.2f" fill="none" stroke-linecap="round" stroke-linejoin="round"/>'%(
            12+i*37+R.uniform(-3,3),R.uniform(6,14),R.uniform(-22,22),sc,d,R.randint(200,260),R.uniform(.42,.56)))
    for _ in range(40): o.append('<circle cx="%.0f" cy="%.0f" r="%.1f" fill="hsl(%d,40%%,55%%)"/>'%(R.uniform(0,200),R.uniform(0,64),R.uniform(.6,1.6),R.randint(0,359)))
    o.append('</svg>')
    return {'id':cid,'img':'data:image/svg+xml;base64,'+base64.b64encode(''.join(o).encode()).decode()}
def captcha_ok(d):
    v=CAPS.pop(str(d.get('cid','')),None)
    return bool(v) and v[1]>time.time() and re.sub(r'\s','',str(d.get('cap',''))).upper()==v[0]

# ---------- user changes their own SSH password (sub page) ----------
SPFAIL={}
def sub_pw(tok,d,ip):
    f=SPFAIL.get(tok,[0,0])
    if time.time()>f[1]: f=[0,0]
    if f[0]>=5: raise Err('Too many wrong tries, try again in 15 minutes')
    old,new=str(d.get('old','')),str(d.get('new',''))
    with UL:
        us=uload(); u=next((x for x in us if hmac.compare_digest(x['sub'],tok)),None)
        if not u: raise Err('Account not found')
        if not hassh(u): raise Err('This account has no password')
        if not hmac.compare_digest(old.encode(),str(u.get('pw','')).encode()):
            SPFAIL[tok]=[f[0]+1,time.time()+900]; time.sleep(1); raise Err('Your current password is wrong')
        if new==old: raise Err('The new password is the same as the old one')
        pwok(new)
        if run('chpasswd',inp='%s:%s\n'%(u['name'],new)).returncode: raise Err('Could not change the password, please contact your provider')
        u['pw']=new; usave(us); n=u['name']
    SPFAIL.pop(tok,None); activity(ip,'User %s changed their own password'%n); tg_send('ReXUI: user %s changed their own password.'%n); return {'ok':1}

# ---------- maintenance: disk cleanup and swap ----------
def dsize(p):
    t=0
    for a,_,fs in os.walk(p):
        for f in fs:
            try: t+=os.lstat(os.path.join(a,f)).st_size
            except OSError: pass
    return t
def swaps():
    return [l.split() for l in rd('/proc/swaps').splitlines()[1:] if l.strip()]
def maint_info():
    m=mem(); du=shutil.disk_usage('/'); sw=swaps()
    return {'swap':{'total':m.get('SwapTotal',0),'used':m.get('SwapTotal',0)-m.get('SwapFree',0),'file':any(x[0]=='/swapfile' for x in sw),'other':[x[0] for x in sw if x[0]!='/swapfile']},
            'ram':m['MemTotal'],'disk':{'free':du.free,'total':du.total},'logs':dsize('/var/log'),'apt':dsize('/var/cache/apt'),'autoclean':sload()['autoclean']}
def cleanup(auto=False):
    import glob
    b=shutil.disk_usage('/').free
    run('journalctl','--vacuum-size=100M',t=120); run('journalctl','--vacuum-time=14d',t=120); run('apt-get','clean',t=180)
    for f in glob.glob('/var/log/**/*.gz',recursive=True)+glob.glob('/var/log/**/*.[1-9]',recursive=True)+glob.glob('/var/log/**/*.old',recursive=True):
        try: os.remove(f)
        except OSError: pass
    try:
        if os.path.getsize(XLOG)>50*1024*1024: open(XLOG,'w').close()
    except OSError: pass
    fr=max(0,shutil.disk_usage('/').free-b)
    if auto: log('auto cleanup freed %d MB'%(fr>>20))
    return {'ok':1,'freed':fr}
def autoclean_save(d):
    s=sload(); s['autoclean']=bool(d.get('autoclean')); wjson(SETF,s,0o600); return {'ok':1}
def maint_daily():
    s=sload(); du=shutil.disk_usage('/')
    if s['autoclean'] and (datetime.date.today().weekday()==0 or du.used/du.total>.85): cleanup(True)
def swap_set(d):
    gb=ival(d,'gb',0,16,0); FST='/etc/fstab'
    if any(x[0]=='/swapfile' for x in swaps()):
        r=run('swapoff','/swapfile',t=600)
        if r.returncode: raise Err('Could not turn off the old swap: '+r.stderr.strip()[-100:])
    try: os.remove('/swapfile')
    except OSError: pass
    try:
        with open(FST) as f: L=f.read().splitlines()
        with open(FST,'w') as f: f.write('\n'.join(l for l in L if not l.split()[:1]==['/swapfile'])+'\n')
    except OSError: pass
    if not gb: return {'ok':1}
    if shutil.disk_usage('/').free<(gb+1)*GB: raise Err('Not enough free disk space for %d GB swap'%gb)
    r=run('fallocate','-l','%dG'%gb,'/swapfile',t=120)
    if r.returncode: r=run('dd','if=/dev/zero','of=/swapfile','bs=1M','count=%d'%(gb*1024),t=900)
    if r.returncode: raise Err('Could not create the swap file')
    os.chmod('/swapfile',0o600); run('mkswap','/swapfile',t=120); r=run('swapon','/swapfile',t=120)
    if r.returncode:
        try: os.remove('/swapfile')
        except OSError: pass
        raise Err('This VPS does not allow swap (it is probably a container VPS)')
    with open(FST,'a') as f: f.write('/swapfile none swap sw 0 0\n')
    with open('/etc/sysctl.d/99-rexui-swap.conf','w') as f: f.write('vm.swappiness=10\n')
    run('sysctl','-w','vm.swappiness=10'); return {'ok':1}

# ---------- phone app (PWA) ----------
ICON={'192':base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAMAAABlApw1AAAAwFBMVEX////+///l8vQhkZcUj48aiZgYipUXi5UWhqkTiKkTiKgTiKcThqsQkowPkJIRkIwQjpgPj5YPj5UOk4sOkY8OkJENlIkNk4kHj4gRjZwRjJ4Ri6ASiqMSiaUSiKYOjJgkgZ0hhJoteqUofqEZe8oaes8ZfsAWgrgWgboXgL0Xf8AUha8VhLIFhZcUg7RAa7ZEaLpIZL5MYcJRXcZWWcpcVNBjTtZuReE1dKwxd6k5cLA8brMcdtkgeMkec94aecvuuHB/AAAJ/ElEQVR42tWda3ebOBBA5Xe6DQkuScBtN351m90m2MRtUxzv2f7/f7VIAvwADcxIPu3oQ0/PScBzxdVYLxTxH1j+PSl/Vcunavn8pSj/6PK3LA+yrFR50uVRlUtd3vyhy/2fsnyU5YMq77MyUcVXZazKuytdhGX8P+vi/2yM/6Ex/rcn8b8vAfy6+G/FGerfZfwq/PeTU4Ai/psbwdqfGxCA6M8Xi/q/R/oDAvz+/sj4zQAs/AEAePhjBmDiz82NJ1j7c+PVA7Dxx6sH4OOPFwTirP48nNmfWgA2/gRZ+DUArPypAeDlTxCEgrU/QXgnWPsT3h0DMPMnDO+OnwA/f46fADt/svAPAdj5IwHCfRZi6U8Ylt8DPP3ZAzD1Jyh6o1z9Cbxrwdof71oBcPVHxi8BuPrjyfj7grU/1/2+YO1PvwrAy58qADN/KgDc/DkFOIM/l2f15wSAnz/HAAz9OQLg6E+/PxSs/emPSgCe/oyGBQBPf7L4cwCu/gyHA8Han+FAAfxSfyY2/gwUwC/3Z0L2RwHQ/Vmt8uAfqP7E8TQrcTz2af5IALI/q4ddV5VEElD8iaepvkPvXUzzZzCYC7I/SVfkpbsuHgDGn2kWfnmHNH43JvgzmNcAtKv/h+zDO3nJAnhaYf2ZTo7vMLol+DOvAvxsHb/8WF2y/ykCjD8y/uM7aAKcPzUA7fxZZZ8uDkr2+Stc/omrd4jw/lQBWrbf5PjT1edfPrWNf1KNX94hjdD+nAK0/f566HZOPj77/CQjuGy5fyyu1EBmUTevfoQ/pwAt80/1ASiL15et/UlFp3oH0Yuw/sznM0Ho/6yqD0DV4DYnaPSnZ7iBcgjjz3x2ANC+/7PqVp+AagZPiqDJn2nPdH2E9Wd2CIDo/9QGoBpym/7P1Hg52p9DAEz/uT4CTdDkT00COgBA+rMHQPWfV4YQZAzxRcP+1Ri4OPKQ/uwBUP3n2kZcJFNNYPQn3gnDxbIRY/2ZzZaCMv7aCRNAp5NKArM/244Zvhdh/ZktFQB+/AU8gk7v/sI4/op7HSO76OL9WWoA7PjrYbU2hSHjuLh/a8o/vS5wYfEAEP5oAPz43dyMFcG9afweg5fJ+JH+SIBPlPH76gkMJdbhn47f4fj7Id4fA0CL8ftqCwWTxHXj95oe3EH8mUAh2p96gFbzP4+pMZ3InnFc1v/en9Qcf6cjGwDen+VyIajzP5cJFM82rtR/DyLeqQaA9me5qAK0nf95ugSN7mmCMn44AeUNGO3PogqAmD+ECUqDlD/TaVP8JH+qALj1UzgVHTUA8Fe90AtJ/lQAkPOHFw0ELeOXCYjmzykAcv758dKcijoymZbxr4X59zo6fpI/JwDo+efHeAcRpHEef68xfqI/i8VWWM0/P0JfTp0sFU2MQ+BCoLWNP4vtAQBp/eKiwe5pmwRK92d7AEBdv7gHw5tO/IYEGgYW/hwAUNcv3tw3pKIWCYjuzx6Avv51cb+AFE92YCPJGwDVn+02FdbrXxfxVnSAbpH5R3IIY+fPNtUAdutfb2UqMoVpLB3Vg7P0J9UAVuuncvgIeQ4mIFt/NIDV+qmef/hgJoASkLU/CsDF+umHj0gCOQ0nE6ilPxKgNn6MP2r8/uECRaASaGDvjwSw90eNf4EZK1MPyIE/afoqHK2/fwSGvPVzQC78SV9LABt/9Pgd6NdVv950ArX257UEsPNHj9/jls1AJqDAjT8lgJv9G+0IZPx3gRt/CgB7fxTAdNCCQM7BRYEjf15fd8KRP2r8Dkw+H05fF/F7DuKXAA73/zQm03wI6cqfnQRw5E8+/7YD+3VyoJx9AbjyRwG48kdvv5rADVn14JzGXwBY+1Nuf4MIdAJ16E8JYH1+wn7/ZxsAR+1XlrWwff/ieP9kK4Xc+bNbKwArf04ESls0Ynf+rBWAO3/aplGH8WcAbvzR/rf8Iuu78kcCOPQHmoM7GsuEzuo/B3CTf/z2nTl38SfCmT8+pjvtyJ91IgHc+OPjBjQjN/UvAdz4M8ENKVNJ4CL+RLjxB1xFrU+mIwf+lADW/rRKQMepqD9wUP8awD7/QKuoJoLByEX8ewCb/ONPKVOLU3t/kuRZOPDHJ07uxvb1//ws7P2BVlHBfl0S28efA9j4A62iNixwbIczO38KADt/wFXUBNpk010MLOtfA9j44zetokbgj5e28UsAq/wzblhFvbuDCQZW/jw/b4SdP37TKmoQRPAjmlvV/2YjrPzx4zW8ipotYngR2Ei68dIm/gKA5k82BIY2e6h9fIHXj8DNHuv5kuxPCUD1pwfFr1ZR5fi9H+0ggnROr/8cgOpPQwIKyvkTuCEvZvT4FQDRn3d+QwI6mP+5hpMp1R8NQPRn3LAPTj6AIv5RfwT+8mxBrP/NV0H0Z+w3b0M5mL8aXcO6LanxfxXE7y84gapFgKP5q2G8gDa+bmYkf74WAFh/xj68EbdXnT8cwFuPd0tS/ecABH9AIxK5Efd0/nAAO7ejxa8A8P5MGxJQUDv/DHebKP5oAHz+aUhAkWn+fAh/HRDqXwKg/Rn7kM5yFdUzzZ/PQPEWhPi/CbQ/8u33LryR1Tj/P1iaXwLK3sVE+/P1WwGA8ceXY0hS/PP5ENjqK5Ituv4LAIQ/EqBrfJdNLsCA6y/DBHgEC3z8GgDlz9i/hd8mhNdf5sDFW6w/OQDGH3X+g/l1zqh5/XFuvhpf/woA5U9Wrq6M79OGYZv1L+PlhPgzAJw/8vyNW9MLze3W72bb2jZ0DNA2/m8C7c/VVWR4o7zt+uOsdiCa3SBF138GgPNHnX8SpbWHArRfP50ltYcCbAjxfxdYf9TxG7XHMiDWf2ebumMZ8P58+54DIPypfwQ6gbaNf7FY1hyMsUnx9Z8DYPxR57dENQeLIPcPVO/wSolfAeD8Ueef9E+PdumH2P0Dp3cg1b8CQPqjDhCJ+seH62Q9UPT+h+M70OpfArzF+qNKKKc8i+ONelFI2b9xcMTShhr/d0HwR58fEgW9/ICpkLj/ZJEh6EOuXlNC/skBCP7o80O8IIqyVwDkP+T9M/kg8pVc/zkA1p/8/IqMIds/5nlO9/8g41cAaH/0AS7q/Qu3+8fw8b8Iij9eEFDfX3Zc/y8ZAM2fMAzd7X+2iP9F2PgT/mp/CgC2/uQAfP3RAIz9UQCc/ZEArP0pAbj6AwPY+zM7e/1rAL7+aADG/gAAPPxRAJz9eXn5IVj78/KjHoCNPz8UAGN/FABnfyQAa39yAL7+aADG/lQBmPkjAVj7swdg6s8JAD9/CgC2/uQAfP05BGDpjwLg7I8EYO1PCcDVnwKArT85AF9/NABjfxQAZ38kAGt/JABrf/YAZ/PnzPVfAHD1pwA4mz/nj18BEP7+zu9S/wqg9Ify9wt+dfwZwO1h/f9e618t4v/xPxtWPzGLuf1uAAAAAElFTkSuQmCC'),'512':base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAMAAADDpiTIAAAAwFBMVEX////+//9ts74Uj44WjJAYipUTiKgaiZgUhq0ThqwZh58NlIkOk4sNk4kPkowNkosPkJIPj5YRkIwOkY8RjZwQjZoQjpgPjpYRjJ4QjJwSi6ESiqMRi58SiaUteqUofqEhhJojgpwlgJ4YfcYZfMgZf7saes8Ze8sVhLMUhLEUha8WgrgVg7UXgL0WgboXf8A1dKw5cLA8brNAa7Ycdtkdc+Exd6kceNFEaLpIZL5MYcJRXcZWWcpcVNBjTtZuReFBvnRWAAAehElEQVR42u2da3vbtrKFCbi+JLbsOJbl3GXnHHfnvu2kTZM0bf7/v9okAZIAREq8DIkZzsBPv6Z8OGvWwitImORP2PVH+/XXH381rt//+r1m/Sf7c9b/Z3/u+r+69d/sr3Z9/O9Hb336+Mld7z+9r9aH7K9abz68ydbb6i9d796+c9fR0dED9y9dBw8OatbLg5fuev7yebmemfWi+Hti/p4+eZL9t3ya/13m/13atbLranV1bv6q9WhjJX/+GUkCnUpvBRAuv/r19c81UF//jeWVP1gfPmzWP1NA/t/bjfofmfWg/C+v/0HH+pcCSGtv1hNnLZdp5Zem9sug/Nk6X3nVryk/tAC6dH+f/v/PyP3/sWX/f6jqD9//z3f2/5O8/58un5YOsFn/uv7fVMAFtAP8MbT/O7T/qP3/qVX/Ww2Y/t9sf+sBD9r3/3O//x0F2P5/4RuA6f/S/bf3f50DXCTo8v93fPn/HnH+P22d/7X1jxQBnUqPNv+9/p8o/1805/+qR/9DOoDk/3T5v3xa1/+d8z/9ixIBPfL/d8n/xvxf9s7/bCXC/zz5P3eAi4sIESD8j4L/Tf9DCUDynxz/XzyCFIDwPzn+vwB0AOF/gvx/ESUChP+R8P8FoANI/pPk/xgRIPyPiP+hBCD8T5T/p48A4X9U/A8jAMl/svwP5ADC/1T5367ThDH/f+TM/7b+E0WA8D86/rf1H+AAkv+k+d/Wf5IIEP5HyP9GAf0FQJ3/P3Lnf9P/pxNEgPA/Sv43/d9XAJL/5Pn/NHeAs74OIPxPnP9t//dzAOH/GfD/6cXZBBGAnP/ff2LK/2X/n5wkvPP/PVf+z/P/7OTsJBH+58n/ef/3cIA58f+n91z5P8//rP/PRowA5PzfMv9ny/95/591dQDJ/9nwv+n/zg4g/D8X/s/yP1sJU/4PBMCN/033dxWA8P98+N9U/+RkkUj+8+T/7G+R/iXC/zz53/R/ewcQ/p8Z/1sHOE6E/xnyf9n/bR1A8n92/J9X/7i1Awj/z43/s/pnK+HM/x/Y8v+Z7f+2DiD8Pzv+z/o/rX8LAUj+z5L/Tf+3cwDh/xnyv+n/3Q4g/D9T/m/vAML/M+T/RVH/HQKQ/J8t/7d0AOH/efL/sd0BbHcA4f8Z83+hgET4nyX/2/7fJgDJ/1nzv1HAAiQChP+p8X/Z/8eNZwHC/zPnf9P/C4AIEP6nx//HRf2bTgMl/2fP/7b+Td8JFP6fO//b+tcKgAv/f+DM/6b+TQ7Ag//fMOb/ov41ApD8Z8H/tv6nifA/Q/63+Z/Wf0MAXPj/w5sR+58A/9v+f3yaMOX/N9z5P+//x6ePE8l/nvyf9f/p6eNAAML/bPjf1t8TADP+f8Oa/239e0bAXPj/LVP+L/vfFYDkPyv+P812gD0jYD78/4Yv/5v+rwQg/M+K/4v+7xMB8+D/4hMAnvxf9n8hAMl/dvxv117Cmf/fMOZ/W/9cAML/3Pi/UMBe4QD8+H/q/EfH/6b/Mwdgnf9v2fK/6f9uETAr/n/DnP9N/6cC4Mz/bxnzv+n/LhEwQ/5/x5j/9/Y6OYDk/9z4/3E3AQj/z43/uzvAzPj/LXP+t+u3hCv/v2PO/x0EIPk/R/435f+tlQMI/8+Q/zsIQPh/jvxv699CAML/s+R/W/9dApD8nyv/m/LvdgDh/5nyf0sBzJz/3crz4v+i/jsEMG/+P+LM/y0EwCH/H7Dl/zYOIPw/Y/5v5wBz5v+jjR0AK/7fLYB58/8Rd/7fIQDh/7nzv137ifA/T/7fIQAO/H/Emv9N+fcbBMCD/40CmPL/FgEI/3Pgf1P+egcQ/mfA/4UCEuF/nvxv+r9OADz4v6R/rvxfKCAR/ufJ//sNDsCM/x9w5f/fGgQg/M+F/+06TJjy/1GX/p8d/5cKOHQFwJH/D9jyv6m/7wDM+P8Ba/43/R86ADP+P2DM/6b/XQEw4/8HvfZ/8+F/W/9CABz5/4A1/9v6lw4g/M+M/239HQdgxv8HzPnf1t8KgCX/P2DM//tF/TMBCP9z5H9HAML/HPnfdwDhf3b8XwlA+J8l/9t1nQj/8+T/SgDY+f9Oq3Ql6VJa61vs/P8wfUjztOnSa7T8b8p/3SQALPx/Z16ms5TGzP81j7vGyf+2/rUCwML/txuv077TW5z8/7DpeVcI+d/Wv9kBoud/Q/nzpd/j4/+HuvFxlT5Ex/9bHAAH/28pf/5KsfH/rufFxv+m/xsdIHb+3259nbkJ3GLi/4c7n1dd4+L/68MGAaDIf73zfaZv9A4P/6/bPK9Gxf/X2xwgdv7rpM1KYwAJ/7fRa2ZaiPj/sEEAKPi/Xf2NAjDwf8v6pwpA1/91DhCd/9vWP1MABv5vXf8aBcTj/zoB4OD/9vXP3mh8/u/2vGj4v9EBYuf/neryQnMPiMr/627Pe4OF/2sEgIP/O73P9I3eDsn/g8H5/7Dr82Lh/6ZNYOzP/3XScak3uPm/OQTi8v+GAHB8/n/b+YWmCuib/weD+X/Z43EPsez/axwg/vl/ZwPIeqo//x8MPP/v9bg4+D8QAJLz/x4GkL3SSPnfq/7WApD0v+sAGM7/e73RFAX68f/BwPN/3UuuuQXE53+7bhJU3//v90YT9bV7/r8cfP6/7vu0KPjf1v8mwfT9v34G4GwEu/D/wdDzf9X3aTUG/jflzwWA5/v/vV9ppoCJ83/Z/2E1Bv53BIDn+//932m6EezG/wdDv/+v+z+rwsD/pvypABB9//82GbD0lPx/eamHPOs1iv2/FQCi7/8PeqmZAibj/+XAR0XA/zc3hQPg+f3/sLeq9HT5v1ZgAojb/zevE0S//x/2VtNzoYn4f3k99Emj83/R/69fJ4h+/zfwtaYoMAn/Xx4OflAE/G/r/zpB9Pu/oe81UVPw//Jy+HMi4H9b/wYHiPP7/2Tw0h3z/3mf3//pBEoAMfnf1r9eAJF+/6+gFADX/zW//x9efyuAuPxv698ggDi//wcQgNId+P95n9//awUlgNj7/0YBRPv9P8CrTc+FRuX/yzXIQyLg/9eNAoh3/x/Eu81QYDz+v3wI84xo+r9GABHv/9EJyNs9GiX/jQOA1D/9ICg+/zcLIN79PzACSFQb/n/e6/4/oCfUCPi/QQBR7/+5TYDe70j8D1X/5BAB/9u1TjDd/6dGVMBw/gerv8LA/7b+vgBi3/8H9YZDBYDw/3INpk8M/G/rHwgg8v1/YAJQ65b8/6z9/X/XCkyeOPb/ef1dASC4/w/sHasjYP5fHsI9Gwr+t/V3BIDh/n8wC/BQoJH/n3W4/w+s/tYAcPS/IwAU9//eAr5mUP6/BJTmHgr+f70OHADH/b9w77lQQDP/P7MSaHP/P+Rz4eD/9dpzACz3/wJagNJg/A9yAlQ81j4O/vcFgOf+f8BWU1+B+P/yRsEaAAb+9wSA6f5/wHedogAE/18ewtYfA/8HDoDp/v9bSAUc7Mj/F89a3P+/hHyiPTz7/1IAyO7/BwyBREHc/w/5QBoN/1cCQDf/D/SFb+P/F63m/8HWH1n/pwJAOP9vFAX05P9R+h8D/1cCQDj/BzJ09Zb8Lz4B2DL/bw27AcDD/w0CwDH/B3QjuB4y/+8atP6Y+N+uVwnK+X9fYVGghv/L9N86/w8SANU1Kv639fcFgGf+n4Z88335H/IEKM0iXPxv6x84AJ75f6B7r+b8f7J1/h/sBhDb/j+vvysAXPP/RlFAt/l/oI+Ajf9t/T0HwJH/9v53WBSo5/8n2/j/EjSGkPa/IwAE/O/P/wBVwKu6/n+2jf9BT4DUHjr+t/V3HADd/F9QGHxYm/8vGvkf6DdAxeWg+Pj/lS8AlPN/YVGgE//DngBdI+T/QABI8j+Y/wF6LvR84/S/mf+BN4AY+d8TAB7+D+Z/gJahLv+f1PM/cP3R8X8oAHz5/24cBfj538j/oACgse7/SwGgzP9igcJgS/4HPgHCyf+uA6Di/2D+DygMrlvxPywA7KHu/1QA6Pg/mP8Hei700M//p3n5g/0/8AkQVv6vHABt/tv7v0FhsEX+Q58AIeV/1wGw5r+9/x92I7iD/0c5AcDI/5UAEPJ/MP8DtCQ7+B/6BBAt/9cKAA3/B/P/QE25yn+n95+OdAKEl/9rBIAw/4v7/0HPhbz+D/If+AQI9f4/X18TvPnv3P8PCoM3G/lf+v8h9AkQXv639a8EgIz/g/k/oM78sIH/YU+Abij0vyMAbPwfzP8BPRfy6b/Mf/ATAMz8b+tfCABx/tv7v2FRwPb/Uzf/V7D1R87/tv6lAyDk/2D+B2h5avtfQZ8AYuZ/W38jAKT878//gYXBsv/L+q9HAADE/G/rbx0AKf/78z9AFbAO9v/AJ0D4+f9rJQD8+W/vf38FigJ+/wN/BYzC/r9yALz8H8z/AIVBr//hfwOEnf9LAeDm/2D+D+hGsKo+NADS6f/MAXDzfzD/YyQFAJ8AUuD/ygFo5H+xFGSpTPVX0CdAJPh/qwBQ8X8w/wMUBUY5AaLB/7scAA//BwsU169HOAEiwv9bBICN/4MF6teHwABwTYb/7bpLCOX/CBtBNcYJAJH9f17/TQFg5P9g+gNoyaBPAKnwv61/rQPg4/8RFcC7/zcEgJX//fkfoDAIegJEh/9t/WscAHX+2+u/jxTO+hPif1t/XwCY+d+f//EKnQLUIS3+t/XfcAC0/B/M/9HIFKA0Mf6/2xQAcv4P5n8g2whqavx/V+sAyPPfu/5fowMAYvv/QAAE+N+f//ESUQioE3L8X+cA6Pnfn/+HBwZzACDZ/6UAaPB/MP9jrbAAAEH+33QACvwfzH/5ikIB+VcAyfG/JwA6/B/M/9A4NoAU+T90ACr8H8z/0zgAgCD/OwKgxf/B/A8dv/40+d93AEr8H8z/UfEBgOj+3wqAHP8H8z8eqrj1p8r/dt0n9Pg/mP8XEwazrwCS7v9UAAT5P5j/Ee9cKPsNEFX+N+W/Tx2AIP8H8390RAAgy/+2/qkDUOT/YP5HJAVoyvxv698gAPT878//e6binQBR5f+tDkCA//35HzFQIAVAyvxv+r9eACT435//M70CUgAgvf+/v2sUAA3+D+b/TP0lwfQEiDb/3zc6ABX+D+b/6QgnQIT5/65RAHT4P5j/oyevP2n+bxIAJf4P5v9ogv2/HzX/awRAi//9+T/TwaA6pc//9QIgxv/B/J+pUCA/AaLO/7UCIMf//vyf5TTnQupwDvxv1+eENv8H8z+mOBdSehb8b+vvCoAk/wfzf/Q0JwAz4H9Tf9cBiPJ/MP9HT1H/OfC/6X/HAcjyfzD/R41/AjQL/jf9XwmAMP87/Z/e/jouCmQnQPPgf1v/QgCU+T+Y/3Otxj0Bmgn/2/pbAdDmf2/+x/JyPBjMToDmwv+f7UrmwP/B/C893iUQ8+H/e0cA9Pnf6X/ou5/9E4C58L/nAHPgf6f/l2MpQM+K/ysBzIP/vekPl2PAYHoCNCf+LwUwF/73JsCs4GEwPQGaFf9XApgJ/zv9v1pdrqBRID0Bmhf/NwiAMP87/Z9KYAV7LpSeAM2M/5scYEv8N+S/6X5T/ne1/u86QEP6B/v/lzUCqD4B8Ns/mP+dGUC+9AgnAMeFAyyK/n/cov/3I/P/fVP+p+tLsq3/P3Xs/3c79v8Pmvv/ZY/+f1Iz/7usP7AA4Pf/U/7+q7H/v/gC6L//f7tz/9+2/58HnwBWCig/AfTz35v/7dQfOgKK9LcG0Dr/Ufe/J4BPQf03dgAb9X87Sv+/3Nn/T+sIwBfADfgm0O3/E9P/j8n3v+8A3fPf6/+J8v9Fc/6vyv4/HAEDvfxf0M//L188ARDL/2Xd/O+y/qN8EHQy4ud/sfrfdQDC+R/WfzXOR8Hd8x/l+Z9T/UoA2/L/A+L8v6zL/9VYh0HHZh8wm/x3HWA+/D9a/XMYnAn/f/EdYFb8vxrzCyHz4X/fAWbE/6txvxI2G/53BDAr/l8t1di/CptP/hcOMCP+X63G/1r4fPI/F8Cs+H91Nf4PQ2bC/5UDzIn/V1P8NGwe/F85wIz4/2qaH4fOJv9DAVDnf/AToCYYnEv+f/ny7VsyH/6/OpzqgojfZtP/ngCI8//oAODCIH3+N+V3BUCc/69WU14SNZf+rwRAnv9X014TN4v89wRAnP9XU18USZ3/AwFQ5//V1HND1Jo4/3/75gqAOv+PegLUBIP0878QAHn+Xx3GuC5+n3z+lwIgzv8TAqD/cQD9/s8FQJ7/V7FGxlDm/0oA5Pn/Kt7QKPL9nwqAPP+vYo6No53/1gFo8//VTczBkTdk+b/eAejxfxQAcGGQKv/XCIAi/1+tYg+P3iec/6ED0OP/1Xn88fGE898TAEX+v4pf/1QBlPvfdQCC/I+h/pUCaPG/Xd8Twvx/vlYYBKA03f7/XgqAIP+fX6OofwaDRPM/rb8RAEn+Pz9EUv8MBunxv62/dQCC/H++QlP/7DeD5Pjf1j8TAEn+P7/SCaKlSeZ/4QAU+X+Fqv6uAqjkfyEAmvx/pRUuAShNsv8zB6DI/6sbZPXPviRIi/9LAVDk/6tDdPXPYJBO/3//7giAHv+vVgjrn8EgtfzfEAAN/r861wnKpSnxf40AqPA/aP016D9GiP83BUCF/0Hrr44XYyoAff87AqDC/6AnQNkcmGPIf0+Tyv/AAUjwP+gJQHrrW3rz5x7kv7im1f+lAKjwP2z9r83tv6D/5g0R/vcFQIX/z68U6BwYO/9Hg6qKBv/b9SOhxP+wJ0C6Gv8xwkaQQv6n9f+RUOJ/2Pq787/AFUAi/9P6ZwIgw/+gJ0Dq1Jv/A4wC+PnflD8TABn+B/0NUDoBxva/uf8fFAW+kun/VABk+P8KFgCD+Z+PQf/1NYH8//GjcAAa/A/6GyClN+f/QH7FVL0m0v+ZA9Dgf9hPgHXd/F/QHQZ2/v/xwxUAAf4frf7O/f+g/wvs/P9jwwFQ8z/wCVBt/cdSAN7833QArPwPfAJ03DD/DxQFNP78dx0ANf+fwwPAonb+3z7k/+cVav4vBUCA/0c4Aarx//z+b1AUWOPv/8wB0PP/+TksAPr8H8z/AEUB7PnvOwBW/h/hBGDb/F/Q/xn6/jd7ANz8Dw+Ai63zf0dUACb+Dx0ALf/DngCdtJj/DRo4aPnf3QNg5v9z8BOgxa7536AocIc5/ysHQMv/8CdAXv+f1s7/AkWBV4jzP11/J6j5/3wFDQA7+z9b6xEUgI3/bf3/TjDzP/wJQIv+zxbovgNt//+d1j8VAGL+H6n+LeZ/Q6MAzvz/uxAAUv4HPwHatf93FqwC0Pa/EQBS/oc9ATrt0P/Z5b+gmw+E/G/6PxcAUv6HPQHYa53/VgCgKHCHjv9t/2cCQMr/50vgE6Au/Z/d/wvqP19R5n8uAKT8D34C1K3/swWKAijz3wgAJf+DA0C3/rcKgHwEbPxfJwBE/D9O/bv0/3gKwNT/ngAQ8f858AlQ1/wv7v8eAwUQ5X9NBODgf+gToA7878//AEWBzwj7vxIAJv6H/gpg3/5P1w00DKLh/00HQMP/5+C/AeqT//b+bw0Lg3j4PxAAIv6H3gAO6P9cAZAfRyPL/yACkPD/KPXv2f/QCtC48r8QACr+j9r/tfP/xlJAXP73HQAP/8NuAE939P9em/nfsKcCuPo/FwAm/of9BHhvYP7b+79BUQBT/jsRgIT/QQNAXffm/2D+xysFHgJI+v/vnwkm/j+HHASmNEz/ZwsQBtVnHPxv6/8zQcT/sAagIfK/uP5bw1oAAv639bcOgIP/QXeAgP0Pq4B0H4gl/38aAWDhf1ADUMdD+T9QAKA00eT/z9IBMPA/KAJkJ0BD+d+f/gCHAgoF/9v6/0yw8D+oAWQnQGD5bxccCmg8/Z85ABL+BxWABs1/6G2AwpL/oQPE5H/QBNBA/D+SAhSe/jd7AAT8n68bzP2f3f8LpYAvCPh/0wGi8j9kAmj4/C/u/1bgm4Bo/P8z2APE5f98PdJQJ0Dj9H92+6saVQBT57/rAHH5H3ALkJ4AgfK/P/8DBgUUkvwvHCA+/2f9f/4I4uWmJ0Cw/B/M//iqQHeB8fjfd4DI/J8L4BGEANIToLHy397/DXEupND0v3WA2Pyflx9EAHrc/s8VMI4AYuR/4QDR+d8qAKj+4PwfzP/QMAJA0f+5A0Tn/yz/QRxAjd//2VLwApie/ysHiM//NgEGCyADgFHzv7j/Ww0XQHT+dwUQm/9t/YcKIB0EO0X/p/f/DkUBhST/rQCi87+t/8APgjIAHI3/g/kfA1FAI8l/I4D4/A8jAD1V/+cKGPhJYHz+LwWAgP+LdTO0/lPk/xpAAd/Q9H8mgPj8Xy41df/v9+v/bA14VoUl/9P1T4KA/wEEkALA6Pzvz/8YcCqg8PT/P7UCmJr/h28CsvpP2v/rISigMfC/rX+dACbn/8EWkALAlPlv150abAAR+d/Wv0YA0/P/UAtIT4C69//+sP7PQqAnDGo0+V8rgAj8X66Lfj8M0ZPxfzD/Q/f7bRia/K8TQAz+dxSg+9V/Mv4P5n/oIQYQl/9t/UMBROH/qv6PetzRrGLkf3H/t+pvACj6PxRAJP4v6p8u3R0AJt//O/f/d0cBjSj/NwQQi/9N91/kClBdT4Am5v9g/kdXFFC4+t8XQDT+L/s/Xd32geo6Zv/n2wDVJwDi83+NACLyv3EAszqFgB56/8/Q+nfcCGo0/L8pgJj8X/Z/rgDV/gOAKPwfrC7Piyv/PQFE5f+q/7t4gNKR+L+nApRGlv+uACLzv7/0aP0PxP/B/I+WCtCY+D8QQGz+9wVw2uqNDs7/Q6D6f/2qqfZ/IYD4/B8oYDcLxN//u/f/f979vF/w5X8pAAz871Q/+9thAkoPPv8/BKx/ZgKqTftj638jABT87yogX9tuatcRzv93zf+801vK/+UeG/87AkDC/07/n6WVPTs526uXgNLDv/8PX/9cAmpr96Pi/0oAaPjf6//Tk7Osx/XGO9W63/1f+6PXP7v/UeuN6ut7VOf/GwJAxP9l/p9l/Z//pZ2+p1MVKGVe5vXp4nixWODg//r5H9qINn1krfX9Pabv/zU4AB7+d/r/9MSstNaLRXbr/7FZi+PFYoGF/zHN/+tZ/9QBMPF/lf+VAxwXf8fHO+f/Tc3/6OZ/dK6/L4D4/D9S/+9H6f97TN//byMAFPzv5b/T/4uw/x8jzH9y/e8IAA3/M+j/z0jy33cAPPyfE+BI+X9Nov+/T9X///yb4OR/uP7fl/zfVv9SAPj4v1v/98z/G9b5n9bfCED4nx//2/pbB2DK/9L/lQMI/zPM/0IATPmfe/9bBxD+58n///5bOABT/r9hzv+lAIT/+ea/EYDwP9v8DwUg/M+I/zcFIPzPiv+bBSD8zyb/XQEI/zPMf88BhP958b8vAOF/dvxfLwDhf1b5XwhA+J9p/pcOIPzPj/8rAQj/s+T/TQEI/7PL/1wAwv98898RgPA/N/73BMCV/18z5n9fAML/LPPfCkD4n2v+Fw4g/M+Q/0sBcOX/18z5vxKA8D/b/HcdQPifYf6bPYDwP0v+9x1A+J8d/zt7AOF/rvlfOIDwP9P8Lx1A+J8f/1cCEP5nyf+OAwj/c81/xwGE/znmf7p+JcL/PPnf1v9XIvzPk/9t/V0HEP7nlv+/fuUOIPzPNf9zAQj/8+R/W/9fCVP+X3Pnf1v/wgGE/znmvxWA8D/X/K8cQPifHf+XAhD+58n/jgMI/3PNf+MAwv9s8984gPA/S/4PHED4nxv/lwIQ/ueb/54DCP/zy3/jAML/LPl/0wGE/1nxf+UAwv9s8790AOF/nvlfOoDwPz/+dxxA+J8j/5cCEP7nm/9GAML/bPPfOoDwP0f+bxSA8D8P/vcEIPzPM/8rBxD+Z5n/lQMI/7Pj/1oBCP/z4X9HAML/XPPfCED4n23+5wIQ/ufJ/xsCEP7nxf81DiD8zy3/HQEI/3PMf88BhP958b8nAOF/fvwfOIDwP8f8twIQ/uea/6UDCP/z4/9SAML/PPnfcQDhf675bxxA+J9t/ucCEP7nyf+BAwj/c+P/ygGE/9nmf+kAwv888984gPA/S/53HED4nyP/1zgAR/6/Z53/YQQI/zPLf08Awv+8+H9TAML/rPg/EABH/r+/457/rgMI/zPM/1IALPn/jjf/+w4g/M+O/x0BsOR/yX/HAYT/meZ/LgDhf578XwlA+J8l/28TgPA/k/yvFYDwP5/8r3cA4X82+d/kAML/DPi/SQC8+P+ed/5vCED4n1f+bzqA8D+r/K9zAOF/JvxfJwBW/H8v+e8LQPifX/77DiD8zy7/QwcQ/mfE/6EAhP8Z5n8pAOF/nvlfOUBN/W3/n1gHyKu9MDs/I4Ci/x+36P/9yPwP+/u/7/Pp/1wAW/q/3AGMsv+P9Psv8P6nXP/cATbSv37/vyjS3xpA6/yX/sdb/1//A84J2Ax1nBy7AAAAAElFTkSuQmCC')}
def manifest():
    n=sload()['brand'] or 'ReXUI'
    return json.dumps({'name':n+' panel','short_name':n,'start_url':'./','scope':'./','display':'standalone','background_color':'#0e1117','theme_color':'#1f6feb',
        'icons':[{'src':'icon-192.png','sizes':'192x192','type':'image/png','purpose':'any maskable'},{'src':'icon-512.png','sizes':'512x512','type':'image/png','purpose':'any maskable'}]}).encode()
SWJS=b"self.addEventListener('install',e=>self.skipWaiting());self.addEventListener('activate',e=>e.waitUntil(self.clients.claim()));self.addEventListener('fetch',e=>{});"

# ---------- fake website (port 80 + Xray fallback) ----------
FSD=T+'/acme-www'; FSON=T+'/fsite.on'; FBP=47880; FS={'srv':[],'err':''}
def _fpage(kind,title):
    t=html.escape(title or {'blog':'Notes from the road','company':'Northwind Studio','soon':'Coming soon'}.get(kind,'Welcome'))
    css="*{box-sizing:border-box;margin:0}body{font:16px/1.65 Georgia,'Times New Roman',serif;color:#222;background:#faf9f6}a{color:#2b5f8a}.w{max-width:760px;margin:auto;padding:28px 20px}header{border-bottom:1px solid #e5e2da;padding-bottom:18px;margin-bottom:26px}h1{font-size:30px}h2{font-size:21px;margin:26px 0 6px}small{color:#777;font:13px system-ui,sans-serif}p{margin:8px 0}footer{margin-top:40px;color:#888;font:13px system-ui,sans-serif;border-top:1px solid #e5e2da;padding-top:14px}"
    yr=datetime.date.today().year
    if kind=='company':
        css="*{box-sizing:border-box;margin:0}body{font:16px/1.6 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;color:#1f2937;background:#fff}.hero{background:linear-gradient(135deg,#0f172a,#1e3a5f);color:#fff;padding:70px 20px;text-align:center}.hero h1{font-size:38px}.hero p{opacity:.85;max-width:560px;margin:12px auto 0}.w{max-width:960px;margin:auto;padding:46px 20px;display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:22px}.c{border:1px solid #e5e7eb;border-radius:12px;padding:22px}.c h3{margin-bottom:6px}footer{text-align:center;color:#6b7280;font-size:13px;padding:26px;border-top:1px solid #e5e7eb}"
        body='<div class="hero"><h1>%s</h1><p>We design and build reliable software and cloud systems for small and medium businesses.</p></div><div class="w"><div class="c"><h3>Web development</h3><p>Fast, accessible websites and web apps built with modern tools.</p></div><div class="c"><h3>Cloud hosting</h3><p>Managed servers, backups and monitoring so your services stay online.</p></div><div class="c"><h3>Consulting</h3><p>Architecture reviews and practical advice for growing teams.</p></div></div><footer>© %d %s · contact@example.com</footer>'%(t,yr,t)
    elif kind=='soon':
        css="*{box-sizing:border-box;margin:0}body{font:16px/1.6 system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;min-height:100vh;display:grid;place-items:center;background:#111827;color:#e5e7eb;text-align:center;padding:20px}h1{font-size:40px;margin-bottom:10px}p{color:#9ca3af}.b{display:inline-block;margin-top:22px;width:46px;height:4px;border-radius:2px;background:#6366f1}"
        body='<div><h1>%s</h1><p>Our new website is under construction. Please check back soon.</p><span class="b"></span></div>'%t
    else:
        posts=[('Packing light for long trips','A short list of what actually earned its place in my bag after three months on the road.'),
               ('The best coffee I had this year','Small cafés, slow mornings and why the second cup is always better.'),
               ('Notes on learning a new language','Twenty minutes a day, a notebook, and a lot of patience.')]
        body='<div class="w"><header><h1>%s</h1><small>Travel, food and small everyday things</small></header>%s<footer>© %d %s</footer></div>'%(t,''.join('<article><h2>%s</h2><small>%s</small><p>%s</p></article>'%(a,(datetime.date.today()-datetime.timedelta(days=9*i+3)).strftime('%B %d, %Y'),b) for i,(a,b) in enumerate(posts)),yr,t)
    return ('<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>%s</title><style>%s</style></head><body>%s</body></html>'%(t,css,body)).encode()
NF404=b'<html>\r\n<head><title>404 Not Found</title></head>\r\n<body>\r\n<center><h1>404 Not Found</h1></center>\r\n<hr><center>nginx</center>\r\n</body>\r\n</html>\r\n'
class FakeH(http.server.BaseHTTPRequestHandler):
    server_version='nginx'; sys_version=''; protocol_version='HTTP/1.1'
    def version_string(self): return 'nginx'
    def log_message(self,*a): pass
    def _send(self,code,body,ct='text/html; charset=utf-8',head=False):
        self.send_response(code); self.send_header('Content-Type',ct); self.send_header('Content-Length',str(len(body))); self.end_headers()
        if not head: self.wfile.write(body)
    def do_GET(self,head=False):
        p=self.path.split('?',1)[0]
        m=re.fullmatch(r'/\.well-known/acme-challenge/([A-Za-z0-9_-]{10,200})',p)
        if m:
            f=os.path.join(FSD,'.well-known','acme-challenge',m[1])
            if os.path.isfile(f): return self._send(200,open(f,'rb').read(),'text/plain',head)
            return self._send(404,NF404,head=head)
        s=sload()
        if p in ('/','/index.html') and s['fsite']!='off': return self._send(200,_fpage(s['fsite'],s['ftitle']),head=head)
        if p=='/favicon.ico': return self._send(404,NF404,head=head)
        return self._send(404,NF404,head=head)
    def do_HEAD(self): self.do_GET(True)
    def do_POST(self): self._send(405,b'<html><body><center><h1>405 Not Allowed</h1></center><hr><center>nginx</center></body></html>')
    do_PUT=do_DELETE=do_OPTIONS=do_PATCH=do_POST
class FakeS(http.server.ThreadingHTTPServer):
    daemon_threads=True; allow_reuse_address=True
class FakeS6(FakeS):
    address_family=socket.AF_INET6
    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6,socket.IPV6_V6ONLY,0); super().server_bind()
def _acme_webroot(on):
    import glob
    for f in glob.glob('/root/.acme.sh/*/*.conf'):
        if os.path.basename(f) in ('account.conf','ca.conf'): continue
        try:
            t=open(f).read()
            if "Le_Webroot=" not in t: continue
            n=re.sub(r"Le_Webroot='[^']*'","Le_Webroot='%s'"%(FSD if on else 'no'),t)
            if n!=t: open(f,'w').write(n)
        except OSError: pass
def fsite_apply():
    s=sload(); on=s['fsite']!='off' or h_on()
    for x in FS['srv']:
        try: x.shutdown(); x.server_close()
        except Exception: pass
    FS['srv']=[]; FS['err']=''
    if not on:
        try: os.remove(FSON)
        except OSError: pass
        _acme_webroot(False); return
    os.makedirs(os.path.join(FSD,'.well-known','acme-challenge'),exist_ok=True)
    for cls,addr in (((FakeS,('127.0.0.1',FBP)),) if h_on() else ((FakeS,('127.0.0.1',FBP)),(FakeS6,('::',80)))):
        try: srv=cls(addr,FakeH)
        except OSError as e:
            if addr[1]==80:
                try: srv=FakeS(('0.0.0.0',80),FakeH)
                except OSError as e2: FS['err']='Port 80 is used by another program (%s)'%e2.strerror; continue
            else: FS['err']=str(e); continue
        FS['srv'].append(srv); threading.Thread(target=srv.serve_forever,daemon=True).start()
    open(FSON,'w').close(); _acme_webroot(True)
def fsite_save(d):
    s=sload(); k=str(d.get('fsite','off'))
    if k not in ('off','blog','company','soon'): raise Err('bad request')
    s['fsite']=k; s['ftitle']=textval(d.get('ftitle'),60,'Site title'); wjson(SETF,s,0o600); fsite_apply(); xray_apply()
    if h_on(): threading.Thread(target=h_sync,daemon=True).start()
    if FS['err']: raise Err(FS['err'])
    return {'ok':1}

# ---------- Reality target finder ----------
RCAND=['www.microsoft.com','learn.microsoft.com','www.apple.com','swdist.apple.com','www.samsung.com','www.amazon.com','aws.amazon.com','www.oracle.com',
       'www.nvidia.com','www.intel.com','www.amd.com','www.cisco.com','www.dell.com','www.hp.com','www.lenovo.com','www.asus.com','www.sony.com',
       'www.adobe.com','www.mozilla.org','addons.mozilla.org','www.wikipedia.org','discord.com','www.tesla.com','www.ikea.com','www.booking.com',
       'www.speedtest.net','dl.google.com','m.youtube.com','www.yahoo.com','www.bing.com','www.github.com','www.cloudflare.com','www.visa.com','www.unity.com']
def _probe(h):
    t0=time.time()
    try:
        c=ssl.create_default_context(); c.minimum_version=ssl.TLSVersion.TLSv1_3; c.set_alpn_protocols(['h2','http/1.1'])
        with socket.create_connection((h,443),timeout=5) as k:
            ip=k.getpeername()[0]
            with c.wrap_socket(k,server_hostname=h) as z: return {'d':h,'ok':True,'ms':round((time.time()-t0)*1000),'h2':z.selected_alpn_protocol()=='h2','ip':ip}
    except Exception as e: return {'d':h,'ok':False,'err':(str(e) or e.__class__.__name__)[:60]}
def rfind(d):
    if TOOLS.get('rfind',{}).get('run'): raise Err('The finder is already running')
    extra=[x for x in re.split(r'[\s,]+',str(d.get('extra','')).lower()) if re.fullmatch(r'[a-z0-9-]+(\.[a-z0-9-]+)+',x)][:10]
    TOOLS['rfind']={'run':1,'t':int(time.time())}
    def go():
        import concurrent.futures as cf
        with cf.ThreadPoolExecutor(10) as ex: res=list(ex.map(_probe,list(dict.fromkeys(extra+RCAND))))
        TOOLS['rfind']={'t':int(time.time()),'res':sorted(res,key=lambda r:(not r['ok'],not r.get('h2'),r.get('ms',9e9)))}
    threading.Thread(target=go,daemon=True).start(); return {'ok':1}
def rscan(d):
    """Check one site for Reality: TLS 1.3, ALPN, certificate names and expiry, latency."""
    t=str(d.get('target') or '').strip().lower()
    m=re.fullmatch(r'([a-z0-9.-]+)(?::(\d{1,5}))?',t)
    if not m or not re.search('[a-z]',m[1]): raise Err('Write a domain like www.microsoft.com:443')
    h,pt=m[1],int(m[2] or 443); sni=hostok(d.get('sni') or h,'SNI') or h
    t0=time.time(); o={'target':'%s:%d'%(h,pt),'sni':sni}
    try:
        c=ssl.create_default_context(); c.set_alpn_protocols(['h2','http/1.1'])
        with socket.create_connection((h,pt),timeout=6) as k:
            o['ip']=k.getpeername()[0]; t1=time.time()
            with c.wrap_socket(k,server_hostname=sni) as z:
                o['ms']=round((time.time()-t1)*1000); o['tls']=z.version(); o['alpn']=z.selected_alpn_protocol() or ''; o['cipher']=(z.cipher() or [''])[0]
                ce=z.getpeercert() or {}
    except ssl.SSLCertVerificationError as e: return dict(o,ok=False,err='Certificate is not valid for %s (%s)'%(sni,(e.verify_message or '')[:60]))
    except Exception as e: return dict(o,ok=False,err=(str(e) or e.__class__.__name__)[:90])
    sub=dict(x[0] for x in ce.get('subject',()) if x); iss=dict(x[0] for x in ce.get('issuer',()) if x)
    o['cn']=sub.get('commonName',''); o['issuer']=iss.get('organizationName') or iss.get('commonName','')
    o['names']=[v for k,v in ce.get('subjectAltName',()) if k=='DNS'][:30]
    try: ex=ssl.cert_time_to_seconds(ce['notAfter']); o['exp']=time.strftime('%Y-%m-%d',time.gmtime(ex)); o['days']=int((ex-time.time())//86400)
    except Exception: pass
    o['ok']=o.get('tls')=='TLSv1.3'
    if not o['ok']: o['err']='The site answers with %s, Reality needs TLS 1.3'%o.get('tls','?')
    o['h2']=o.get('alpn')=='h2'
    return o
def rtargets(d):
    """Find Targets: check a list of big sites (plus your own) and sort the good ones first."""
    extra=[x for x in re.split(r'[\s,]+',str(d.get('extra','')).lower()) if re.fullmatch(r'[a-z0-9-]+(\.[a-z0-9-]+)+',x)][:10]
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(16) as ex: res=list(ex.map(_probe,list(dict.fromkeys(extra+RCAND))))
    return {'ok':1,'res':sorted(res,key=lambda r:(not r['ok'],not r.get('h2'),r.get('ms',9e9)))}
def jsub_set(d):
    s=sload()
    for k in ('jsub','jfrag','jnoise'):
        if isinstance(d.get(k),bool): s[k]=d[k]
    pk=str(d.get('jpk',s['jpk'])).strip(); ln=str(d.get('jlen',s['jlen'])).strip(); it=str(d.get('jint',s['jint'])).strip()
    if not re.fullmatch(r'tlshello|\d{1,2}-\d{1,2}',pk): raise Err('Packets: tlshello or a range like 1-3')
    for v,t in ((ln,'Length'),(it,'Interval')):
        if not re.fullmatch(r'\d{1,4}(-\d{1,4})?',v): raise Err(t+': a number or a range like 100-200')
    s['jpk'],s['jlen'],s['jint']=pk,ln,it; wjson(SETF,s,0o600); return {'ok':1}
# ---------- Reality Watch: keep Reality inbounds working when their target site goes down ----------
RWF=T+'/rwatch.json'; RW={}; RWL=threading.Lock()
def rw_load():
    global RW
    try: RW=json.loads(rd(RWF) or '{}')
    except Exception: RW={}
def rw_save(): wjson(RWF,RW,0o600)
def rw_cur(x,s):
    """(host, port, sni) the Reality inbound uses now."""
    if x.get('b')=='reality': return s['rsni'],443,s['rsni']
    t=x.get('target') or x['sni']+':443'; h,_,p=t.rpartition(':')
    return h,int(p or 443),x['sni']
def rw_check(only=None,force=False):
    """Check every watched Reality inbound. 3 failed checks in a row (or force) -> switch to the first spare that works."""
    with RWL:
        s=sload(); L=ib_load(); ch=False; now=int(time.time())
        for x in L:
            w=x.get('rw') or {}
            if x['sec']!='reality' or not w.get('on') or (only and x['id']!=only): continue
            st=RW.setdefault(x['id'],{'fails':0,'hist':[]}); h,p,sn=rw_cur(x,s)
            ok=tls13(h,p,sn); st.update(last=now,ok=ok,cur=h)
            if ok and not force: st['fails']=0; st.pop('alerted',None); continue
            if not ok: st['fails']=st.get('fails',0)+1
            if st['fails']<3 and not force: continue
            sp=next((d for d in w.get('spares') or [] if d!=h and tls13(d)),None)
            if not sp:
                if not st.get('alerted'):
                    tg_send('⚠️ Reality Watch: "%s" — %s does not answer and no spare target works. Add more spare targets in the inbound.'%(x['name'],h),s); st['alerted']=True
                    st['hist']=(st.get('hist') or [])[-19:]+[[now,'%s failed, no spare works'%h]]
                continue
            if x.get('b')=='reality': s['rsni']=sp; wjson(SETF,s,0o600); x['sni']=sp
            else: x['target']=sp+':443'; x['sni']=sp; x['snix']=[]
            st.update(fails=0,ok=True,cur=sp); st.pop('alerted',None); ch=True
            st['hist']=(st.get('hist') or [])[-19:]+[[now,'Switched %s → %s'%(h,sp)]]
            tg_send('🔄 Reality Watch: "%s" — %s stopped working, switched to %s. Users should refresh their subscription.'%(x['name'],h,sp),s)
            log('reality watch: %s %s -> %s'%(x['name'],h,sp))
        if ch: ib_save(L)
        rw_save()
    if ch: xray_apply()
    return {'ok':1,'rw':RW}
def rw_api(d):
    i=d.get('id') or None
    if d.get('a')=='switch': return rw_check(i,True)
    if d.get('a')=='check': return rw_check(i)
    return {'ok':1,'rw':RW}
def rdefault(d):
    h=hostok(d.get('domain'),'Domain')
    if not h or not tls13(h): raise Err('%s did not answer with TLS 1.3'%h)
    s=sload(); s['rsni']=h; wjson(SETF,s,0o600); xray_apply(); return {'ok':1}

# ---------- ReXUI new version check (GitHub, every 6 hours) ----------
RXVER='2.0'; RXURL=os.environ.get('REXUI_UPURL','https://raw.githubusercontent.com/chaliraza777/ReXUI/main/install.sh'); RXUPF=T+'/rxup.json'; RXUP={'latest':'','t':0}
def vtup(v): return tuple(int(x) for x in re.findall(r'\d+',v)[:3])
def rx_check():
    import urllib.request
    try:
        rq=urllib.request.Request(RXURL,headers={'User-Agent':'ReXUI','Range':'bytes=0-2047'})
        with urllib.request.urlopen(rq,timeout=20) as r: head=r.read(4096).decode('utf-8','ignore')
        m=re.search(r'ReXUI v([\d.]+) installer',head)
        if not m: return
        RXUP['latest'],RXUP['t']=m[1],int(time.time())
        if vtup(m[1])>vtup(RXVER):
            try: told=json.loads(rd(RXUPF) or '{}').get('told','')
            except Exception: told=''
            if told!=m[1]:
                tg_send('🆕 ReXUI v%s is available (you have v%s). Update on the server: menu → 1 (Update) → 1.'%(m[1],RXVER)); wjson(RXUPF,{'told':m[1]})
    except Exception as e: log('update check:',repr(e))
def rx_info(): return {'cur':RXVER,'latest':RXUP['latest'],'new':bool(RXUP['latest'] and vtup(RXUP['latest'])>vtup(RXVER))}

# ---------- Xray core update ----------
XUP={'run':0,'msg':'','t':0,'latest':'','lt':0}
def xver():
    r=run(XBIN,'version',t=10); m=re.search(r'Xray\s+([\d.]+)',r.stdout or ''); return 'v'+m[1] if m else ''
def xlatest():
    import urllib.request
    rq=urllib.request.Request('https://api.github.com/repos/XTLS/Xray-core/releases/latest',headers={'User-Agent':'ReXUI','Accept':'application/vnd.github+json'})
    with urllib.request.urlopen(rq,timeout=15) as r: v=json.loads(r.read().decode()).get('tag_name','')
    XUP['latest'],XUP['lt']=v,int(time.time()); return v
def xupdate(force=False,auto=False):
    import urllib.request,zipfile,io,platform
    if XUP['run']: raise Err('An update is already running')
    XUP['run']=1
    try:
        a={'x86_64':'64','amd64':'64','aarch64':'arm64-v8a','arm64':'arm64-v8a'}.get(platform.machine().lower())
        if not a: raise Err('This CPU is not supported')
        cur=xver(); new=xlatest()
        if not new: raise Err('Could not check the latest version')
        if cur==new and not force: XUP['msg']='Already up to date (%s)'%cur; return {'ok':1,'msg':XUP['msg']}
        rq=urllib.request.Request('https://github.com/XTLS/Xray-core/releases/download/%s/Xray-linux-%s.zip'%(new,a),headers={'User-Agent':'ReXUI'})
        with urllib.request.urlopen(rq,timeout=180) as r: zb=r.read()
        try:
            with urllib.request.urlopen(urllib.request.Request(rq.full_url+'.dgst',headers={'User-Agent':'ReXUI'}),timeout=30) as r: dg=r.read().decode('utf-8','replace')
        except Exception: dg=''
        m=re.search(r'(?im)^SHA(?:2-)?256[^=]*=\s*([0-9a-f]{64})',dg)
        if not m or m.group(1).lower()!=hashlib.sha256(zb).hexdigest(): raise Err('The download check failed (checksum did not match). Nothing was changed.')
        z=zipfile.ZipFile(io.BytesIO(zb))
        B='/usr/local/bin'; files=[f for f in ('xray','geoip.dat','geosite.dat') if f in z.namelist()]
        if 'xray' not in files: raise Err('The download did not contain Xray')
        for f in files:
            if os.path.exists(B+'/'+f): shutil.copy2(B+'/'+f,B+'/'+f+'.old')
        def back():
            for f in files:
                if os.path.exists(B+'/'+f+'.old'): os.replace(B+'/'+f+'.old',B+'/'+f)
            run('systemctl','restart','xray',t=30)
        for f in files:
            with open(B+'/'+f+'.new','wb') as o: o.write(z.read(f))
            os.chmod(B+'/'+f+'.new',0o755 if f=='xray' else 0o644); os.replace(B+'/'+f+'.new',B+'/'+f)
        if run(XBIN,'run','-test','-c',XD+'/config.json',t=30).returncode: back(); raise Err('Xray %s did not accept the current config, the old version was put back'%new)
        run('systemctl','restart','xray',t=30); time.sleep(3)
        if run('systemctl','is-active','xray').stdout.strip()!='active': back(); raise Err('Xray %s did not start, the old version was put back'%new)
        XVER[0]=''; XUP['msg']='Updated %s → %s'%(cur or '?',new); log('xray update:',XUP['msg']); return {'ok':1,'msg':XUP['msg']}
    except Err as e: XUP['msg']=str(e); raise
    except Exception as e: XUP['msg']='Update failed: '+str(e)[:100]; raise Err(XUP['msg'])
    finally:
        XUP['run']=0; XUP['t']=int(time.time())
        if auto and XUP['msg'] and not XUP['msg'].startswith('Already'): tg_send('ReXUI: Xray auto update: '+XUP['msg'])
def xup_bg(force=False):
    if XUP['run']: raise Err('An update is already running')
    def go():
        try: xupdate(force)
        except Exception: pass
    threading.Thread(target=go,daemon=True).start(); return {'ok':1}
def xcheck():
    try: return {'ok':1,'cur':xver(),'latest':xlatest()}
    except Exception: raise Err('Could not reach GitHub')
def xauto_save(d): s=sload(); s['xauto']=bool(d.get('xauto')); wjson(SETF,s,0o600); return {'ok':1}

# ---------- DuckDNS ----------
DDNS={'t':0,'ok':None,'ip':'','msg':''}
DDAPI=os.environ.get('REXUI_DDAPI','https://www.duckdns.org/update')
def ddns_update():
    import urllib.request
    s=sload()
    if not (s['ddns_dom'] and s['ddns_tok']): return
    try:
        with urllib.request.urlopen('%s?domains=%s&token=%s&ip=&verbose=true'%(DDAPI,s['ddns_dom'],s['ddns_tok']),timeout=15) as r: t=r.read().decode().split('\n')
        ok=t[0].strip()=='OK'; DDNS.update(t=int(time.time()),ok=ok,ip=t[1].strip() if ok and len(t)>1 else '',msg='' if ok else 'DuckDNS said KO (check the subdomain and token)')
    except Exception as e: DDNS.update(t=int(time.time()),ok=False,msg='DuckDNS could not be reached: '+str(e)[:80])
def ddns_save(d):
    s=sload(); dm=str(d.get('dom','')).strip().lower()
    dm=re.sub(r'\.duckdns\.org$','',dm)
    if dm and not re.fullmatch(r'[a-z0-9-]{1,63}',dm): raise Err('Subdomain must be like myserver (or myserver.duckdns.org)')
    tk=str(d.get('tok','')).strip()
    if tk.startswith('•'): tk=s['ddns_tok']
    if tk and not re.fullmatch(r'[0-9a-f-]{36}',tk): raise Err('The token is the long code shown at the top of duckdns.org after you log in')
    if bool(dm)!=bool(tk): raise Err('Enter both the subdomain and the token, or clear both')
    s['ddns_dom'],s['ddns_tok']=dm,tk; wjson(SETF,s,0o600)
    if not dm: DDNS.update(t=0,ok=None,ip='',msg=''); return {'ok':1}
    ddns_update()
    if not DDNS['ok']: raise Err(DDNS['msg'])
    return {'ok':1,'ip':DDNS['ip']}

# ---------- panel address ----------
def panel_path(d):
    p=str(d.get('path','')).strip().strip('/')
    if not p: p=''.join(secrets.choice('ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789') for _ in range(16))
    if not re.fullmatch(r'[A-Za-z0-9_-]{6,64}',p): raise Err('Path must be 6-64 letters, numbers, - or _')
    if p in ('sub','api'): raise Err('Pick another path')
    L=rd(CONF).splitlines(); L=[l for l in L if not l.startswith('WEB_PATH=')]+['WEB_PATH='+p]
    with open(CONF+'.tmp','w') as f: f.write('\n'.join(L)+'\n')
    os.chmod(CONF+'.tmp',0o600); os.replace(CONF+'.tmp',CONF)
    def later(): time.sleep(2); run('systemctl','restart','tunnel-panel',t=20)
    threading.Thread(target=later,daemon=True).start(); return {'ok':1,'path':p}

# ---------- logs viewer ----------
LOGSRC={'xray':['xray'],'panel':['tunnel-panel'],'ws':['ws-ssh'],'ssl':['stunnel4'],'udpgw':['badudp'],'ssh':['ssh','sshd']}
def logview(d):
    src=str(d.get('src','xray')); n=ival(d,'n',20,2000,200); q=str(d.get('q','')).strip().lower()[:80]
    if src=='access':
        try:
            with open(XLOG,'rb') as f:
                f.seek(0,2); sz=f.tell(); f.seek(max(0,sz-400000)); L=f.read().decode('utf-8','replace').splitlines()[1:]
        except OSError: L=[]
    elif src in LOGSRC:
        a=['journalctl','--no-pager','-o','short-iso','-n',str(n if not q else 3000)]
        for u in LOGSRC[src]: a+=['-u',u]
        r=run(*a,t=20); L=(r.stdout or r.stderr or '').splitlines()
    else: raise Err('bad request')
    if q: L=[l for l in L if q in l.lower()]
    return {'ok':1,'lines':L[-n:]}

# ---------- http ----------
BASE='/'+E.get('WEB_PATH','panel').strip('/')+'/'
SESS={}; FAIL={}
CSP="default-src 'self'; style-src 'self' 'unsafe-inline'; script-src 'self' 'unsafe-inline'; img-src 'self' data:"
class Hd(BaseHTTPRequestHandler):
    timeout=20; server_version='nginx'; sys_version=''
    def log_message(self,*a): pass
    def out(self,code,obj=None,body=None,ct='application/json',ck=None,hdr=()):
        b=body if body is not None else json.dumps(obj,separators=(',',':')).encode(); hdr=tuple(hdr)
        if len(b)>1500 and ct.startswith(('application/json','text/')) and 'gzip' in self.headers.get('Accept-Encoding',''):
            import gzip; b=gzip.compress(b,5); hdr+=(('Content-Encoding','gzip'),('Vary','Accept-Encoding'))
        self.send_response(code)
        for k,v in (('Content-Type',ct),('Content-Length',str(len(b))),('Cache-Control','no-store'),('X-Frame-Options','DENY'),
                    ('X-Content-Type-Options','nosniff'),('Referrer-Policy','no-referrer'),('Content-Security-Policy',CSP))+tuple(hdr):
            self.send_header(k,v)
        if ck: self.send_header('Set-Cookie',ck)
        self.end_headers(); self.wfile.write(b)
    def nf(self): self.out(404,body=b'404 page not found',ct='text/plain')
    def tok(self):
        m=re.search(r'(?:^|;\s*)sid=([0-9a-f]{48})',self.headers.get('Cookie','')); return m[1] if m else None
    def authed(self):
        t=self.tok(); v=SESS.get(t) if t else None; return bool(v) and v['exp']>time.time()
    def route(self):
        p=self.path.split('?',1)[0]
        if p==BASE[:-1]: return 'redir'
        return p[len(BASE)-1:] if p.startswith(BASE) else None
    def do_GET(self):
        p=self.path.split('?',1)[0]
        if p=='/qr.js': return self.out(200,body=rd(QRJS).encode(),ct='application/javascript; charset=utf-8')
        m=re.fullmatch(r'/sub/([0-9a-f]{32})/ovpn',p)
        if m:
            u=next((x for x in uload() if hmac.compare_digest(x['sub'],m[1])),None)
            if not u or not hasov(u): return self.nf()
            return self.ovpn_out(u)
        m=re.fullmatch(r'/sub/([0-9a-f]{32})/wg',p)
        if m:
            u=next((x for x in uload() if hmac.compare_digest(x['sub'],m[1])),None)
            if not u or not haswg(u): return self.nf()
            return self.wg_out(u)
        m=re.fullmatch(r'/sub/([0-9a-f]{32})/json',p)
        if m:
            u=next((x for x in uload() if hmac.compare_digest(x['sub'],m[1])),None)
            if not u or not hasx(u) or not sload().get('jsub',True): return self.nf()
            ex=0 if u['exp']=='never' else int(datetime.datetime.fromisoformat(u['exp']+'T23:59:59').timestamp())
            return self.out(200,body=json.dumps(json_sub(u),indent=1).encode(),ct='application/json; charset=utf-8',hdr=(('Subscription-Userinfo','upload=%d; download=%d; total=%d; expire=%d'%(u['up'],u['down'],int(u['lim']*GB),ex)),
                            ('Profile-Update-Interval','12'),('Profile-Title','base64:'+base64.b64encode(((sload()['brand'] or 'ReXUI')+' '+u['name']).encode()).decode())))
        m=re.fullmatch(r'/sub/([0-9a-f]{32})',p)
        if m:
            u=next((x for x in uload() if hmac.compare_digest(x['sub'],m[1])),None)
            if not u: return self.nf()
            if 'text/html' in self.headers.get('Accept','') and 'raw' not in self.path.split('?',1)[-1]:
                d=detail(u['name']); d['links']=[{k:v for k,v in l.items() if k!='json'} for l in d['links']]; keep=('name','pw','exp','lim','used','up','down','st','sub','jsub','links','addr','whost','ports','alt','plaindomain','created','dev','hist','fdays','expts','reason','kind','ovpn','hy2','wg','dns','pays')
                data=json.dumps(dict({k:d[k] for k in keep},announce=sload()['announce'],**brand())).replace('<','\\u003c').replace('>','\\u003e').replace('&','\\u0026')
                return self.out(200,body=rd(UHTML).replace('__DATA__',data).encode(),ct='text/html; charset=utf-8')
            body=base64.b64encode('\n'.join(l[1] for l in links(u)).encode())
            ex=0 if u['exp']=='never' else int(datetime.datetime.fromisoformat(u['exp']+'T23:59:59').timestamp())
            info='upload=%d; download=%d; total=%d; expire=%d'%(u['up'],u['down'],int(u['lim']*GB),ex)
            return self.out(200,body=body,ct='text/plain; charset=utf-8',hdr=(('Subscription-Userinfo',info),('Profile-Update-Interval','12'),
                            ('Profile-Title','base64:'+base64.b64encode(((sload()['brand'] or 'ReXUI')+' '+u['name']).encode()).decode())))
        r=self.route()
        if r=='redir': return self.out(301,body=b'',hdr=(('Location',BASE),))
        if r=='/': return self.out(200,body=rd(HTML).encode(),ct='text/html; charset=utf-8')
        if r=='/api/brand': return self.out(200,brand())
        if r=='/api/captcha': return self.out(200,captcha())
        if r=='/manifest.webmanifest': return self.out(200,body=manifest(),ct='application/manifest+json')
        if r=='/sw.js': return self.out(200,body=SWJS,ct='application/javascript; charset=utf-8')
        if r in ('/icon-192.png','/icon-512.png'): return self.out(200,body=ICON[r[6:9]],ct='image/png')
        if r=='/api/users.csv':
            if not self.authed(): return self.out(401,{'e':'login'})
            return self.out(200,body=csv_export(),ct='text/csv; charset=utf-8',hdr=(('Content-Disposition','attachment; filename="rexui-users-%s.csv"'%today()),))
        if r=='/api/ovpn':
            if not self.authed(): return self.out(401,{'e':'login'})
            from urllib.parse import parse_qs
            n=(parse_qs(self.path.split('?',1)[-1] if '?' in self.path else '').get('name') or [''])[0]
            u=next((x for x in uload() if x['name']==n),None)
            if not u or not hasov(u): return self.out(404,{'e':'User not found'})
            return self.ovpn_out(u)
        if r=='/api/wg':
            if not self.authed(): return self.out(401,{'e':'login'})
            from urllib.parse import parse_qs
            n=(parse_qs(self.path.split('?',1)[-1] if '?' in self.path else '').get('name') or [''])[0]
            u=next((x for x in uload() if x['name']==n),None)
            if not u or not haswg(u): return self.out(404,{'e':'User not found'})
            return self.wg_out(u)
        if r=='/api/hist': return self.out(200,HM) if self.authed() else self.out(401,{'e':'login'})
        if r=='/api/state':
            if not self.authed(): return self.out(401,{'e':'login'})
            m=re.search(r'[?&]uh=([0-9a-f]{16})',self.path); return self.out(200,state(m[1] if m else ''))
        if r=='/api/backup':
            if not self.authed(): return self.out(401,{'e':'login'})
            b=json.dumps(backup_obj(),indent=1).encode()
            return self.out(200,body=b,ct='application/json',hdr=(('Content-Disposition','attachment; filename="rexui-backup-%s.json"'%today()),))
        self.nf()
    def wg_out(self,u):
        try:
            if ustate(u)!='active': raise Err('This account is not active')
            b=wg_text(u).encode()
        except Err as e: return self.out(400,body=str(e).encode(),ct='text/plain; charset=utf-8')
        return self.out(200,body=b,ct='text/plain; charset=utf-8',hdr=(('Content-Disposition','attachment; filename="%s.conf"'%re.sub(r'[^A-Za-z0-9_-]','_',u['name'])[:15]),))
    def ovpn_out(self,u):
        try:
            port,host,proxy=ov_args(self.path.split('?',1)[-1] if '?' in self.path else '')
            if ustate(u)!='active': raise Err('This account is not active')
            b=ov_file(u,port,host,proxy)
        except Err as e: return self.out(400,body=str(e).encode(),ct='text/plain; charset=utf-8')
        fn='%s-%d%s.ovpn'%(u['name'],port,'-proxy' if proxy else '')
        return self.out(200,body=b,ct='application/x-openvpn-profile',hdr=(('Content-Disposition','attachment; filename="%s"'%fn),))
    def do_POST(self):
        try:
            m=re.fullmatch(r'/sub/([0-9a-f]{32})/pw',self.path.split('?',1)[0])
            if m:
                if self.headers.get('X-Req')!='1': return self.out(403,{'e':'bad request'})
                n=int(self.headers.get('Content-Length',0) or 0)
                if n>4096: return self.out(413,{'e':'Request too large'})
                d=json.loads(self.rfile.read(n) or b'{}')
                if not isinstance(d,dict): raise Err('bad request')
                return self.out(200,sub_pw(m[1],d,self.client_address[0]))
            r=self.route()
            if r is None or r=='redir': return self.nf()
            if self.headers.get('X-Req')!='1': return self.out(403,{'e':'bad request'})
            n=int(self.headers.get('Content-Length',0) or 0)
            if n>(16<<20 if r in ('/api/restore','/api/csv-import') else 65536): return self.out(413,{'e':'Request too large'})
            d=json.loads(self.rfile.read(n) or b'{}')
            if not isinstance(d,dict): raise Err('bad request')
            if r=='/api/login':
                ip=self.client_address[0]; f=FAIL.get(ip,[0,0])
                if time.time()>f[1]: f=[0,0]
                if f[0]>=5: login_log(ip,d.get('u',''),'Blocked (too many tries)',self.headers.get('User-Agent','')); return self.out(429,{'e':'Too many failed attempts, try again in 10 minutes'})
                if f[0]>=3 and not captcha_ok(d):
                    return self.out(401,{'e':'Type the letters from the picture' if d.get('cap') else 'Too many wrong tries. Type the letters from the picture.','needcap':1,'captcha':captcha()})
                if not checklogin(str(d.get('u','')),str(d.get('p',''))):
                    FAIL[ip]=[f[0]+1,time.time()+600]; time.sleep(1)
                    login_log(ip,d.get('u',''),'Wrong password',self.headers.get('User-Agent',''))
                    if f[0]+1==5: tg_send('ReXUI: 5 wrong logins from %s, blocked for 10 minutes.'%ip)
                    o={'e':'Wrong username or password'}
                    if 3<=f[0]+1<5: o.update(needcap=1,captcha=captcha())
                    return self.out(401,o)
                l=lread()
                if l.get('totp'):
                    if not str(d.get('code','')).strip(): return self.out(401,{'e':'Enter the 6-digit code from your authenticator app','need2fa':1})
                    c=totp_check(l['totp'],d.get('code'),l.get('tlast',0))
                    if not c:
                        FAIL[ip]=[f[0]+1,time.time()+600]; login_log(ip,d.get('u',''),'Wrong 2FA code',self.headers.get('User-Agent','')); time.sleep(1)
                        o={'e':'Wrong code','need2fa':1}
                        if 3<=f[0]+1<5: o.update(needcap=1,captcha=captcha())
                        return self.out(401,o)
                    l['tlast']=c; wjson(LOGIN,l)
                tg_send('ReXUI panel login\nUser: %s\nIP: %s\nTime: %s'%(curuser(),ip,datetime.datetime.now().strftime('%Y-%m-%d %H:%M')))
                FAIL.pop(ip,None); t=secrets.token_hex(24); now=time.time()
                for k in [k for k,v in SESS.items() if v['exp']<now]: SESS.pop(k,None)
                SESS[t]={'exp':now+43200,'ip':ip,'ua':self.headers.get('User-Agent','')[:160],'t':int(now)}; login_log(ip,curuser(),'OK',self.headers.get('User-Agent',''))
                return self.out(200,{'ok':1},ck='sid=%s; HttpOnly; Secure; SameSite=Strict; Path=%s; Max-Age=43200'%(t,BASE))
            if not self.authed(): return self.out(401,{'e':'login'})
            if r=='/api/logout': SESS.pop(self.tok(),None); return self.out(200,{'ok':1})
            if r=='/api/user/detail': return self.out(200,detail(str(d.get('name',''))))
            res=self.api(r,d); txt=act_desc(r,d,res)
            if txt: activity(self.client_address[0],txt)
            return self.out(200,res)
        except Err as e: self.out(400,{'e':str(e)})
        except Exception as e: log('api:',repr(e)); self.out(500,{'e':'Server error'})
    def api(self,r,d):
        if r.startswith('/api/user/'): return uapi(r[10:],d)
        if r.startswith('/api/inbound/'): return ib_api(r[13:],d)
        if r=='/api/login-change':
            if not checklogin(curuser(),str(d.get('old',''))): raise Err('Old password is wrong')
            setlogin(str(d.get('u','')).strip(),str(d.get('p','')),keep2fa=True); SESS.clear(); return {'ok':1}
        f={'/api/svc':lambda:restart(str(d.get('unit',''))),'/api/cert':lambda:setcert(d),'/api/settings':lambda:ssave(d),'/api/restore':lambda:restore(d),
           '/api/reality-keys':new_reality,'/api/routing':lambda:routing_save(d),'/api/warp-reset':warp_reset,
           '/api/2fa/setup':lambda:tfa_setup(self.tok()),'/api/2fa/enable':lambda:tfa_enable(self.tok(),d.get('code')),'/api/2fa/disable':lambda:tfa_disable(d.get('code')),
           '/api/bulk':lambda:bulk(d),'/api/automation':lambda:automation_save(d),'/api/tg-test':lambda:tg_test(d),'/api/tg-chat':lambda:tg_findchat(d),
           '/api/trial':lambda:trial_new(d),'/api/csv-import':lambda:csv_import(d),'/api/appearance':lambda:appearance_save(d),
           '/api/logs':lambda:logs(self.tok()),'/api/session-kill':lambda:session_kill(self.tok(),d),'/api/tg-backup':tg_backup_now,
           '/api/fsite':lambda:fsite_save(d),'/api/rfind':lambda:rfind(d),'/api/rscan':lambda:rscan(d),'/api/geo':geo_view,'/api/rwatch':lambda:rw_api(d),'/api/rtargets':lambda:rtargets(d),'/api/jsub-set':lambda:jsub_set(d),'/api/rdefault':lambda:rdefault(d),'/api/xcheck':xcheck,'/api/xupdate':lambda:xup_bg(bool(d.get('force'))),
           '/api/xauto':lambda:xauto_save(d),'/api/ddns':lambda:ddns_save(d),'/api/panel-path':lambda:panel_path(d),'/api/logview':lambda:logview(d),
           '/api/maint':maint_info,'/api/cleanup':cleanup,'/api/swap':lambda:swap_set(d),'/api/autoclean':lambda:autoclean_save(d),
           '/api/speedtest':speedtest,'/api/reboot':lambda:reboot_save(d),'/api/subpage':lambda:subpage_save(d),'/api/ovpn-set':lambda:ov_set(d),'/api/dns-set':lambda:dns_set(d),'/api/hy-set':lambda:hy_set(d),'/api/cdn-set':lambda:cdn_set(d),'/api/perf-set':lambda:perf_set(d),
           '/api/payload/save':lambda:pay_save(d),'/api/payload/del':lambda:pay_del(d),'/api/payload/import':lambda:pay_import(d),'/api/payload/test':lambda:pay_test(d),
           '/api/check':server_check,'/api/check/fix':lambda:check_fix(d),'/api/ports':ports_view,'/api/fw-open':lambda:fw_open(d),'/api/ib-portcheck':lambda:ib_portcheck(d),'/api/h443':lambda:h_set(d)}.get(r)
        if not f: raise Err('not found')
        return f()
def ctx():
    c=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); c.minimum_version=ssl.TLSVersion.TLSv1_2
    try: c.load_cert_chain(CD+'/xray.crt',CD+'/xray.key'); return c
    except Exception: pass
    c.load_cert_chain(SELF); return c
class Srv(ThreadingHTTPServer):
    daemon_threads=True; allow_reuse_address=True
    def get_request(self):
        s,a=self.socket.accept(); return CTX.wrap_socket(s,server_side=True,do_handshake_on_connect=False),a
    def handle_error(self,*a): pass
if __name__=='__main__':
    a=sys.argv[1:]+['','','']
    if a[0]=='setlogin':
        try: setlogin(a[1],a[2])
        except Err as e: print(e); sys.exit(1)
    elif a[0]=='user': print(curuser())
    elif a[0]=='fwcheck':
        G_,Y_,R_,D_,N_='\033[1;32m','\033[1;33m','\033[1;31m','\033[2m','\033[0m'
        v=ports_view(); bad=[]; line=[]
        for x in v['ports']:
            if not isinstance(x['port'],int): continue
            lab='%d%s'%(x['port'],'/udp' if x['proto']=='udp' else '')
            if not x['listen']: line.append(Y_+'●'+lab+N_); bad.append((x,'not running'))
            elif x['fw']=='closed': line.append(R_+'●'+lab+N_); bad.append((x,'ufw'))
            else: line.append(G_+'●'+N_+lab)
        print('FIREWALL  '+D_+('ufw on' if v['fw'] else 'ufw off')+N_)
        print(' '.join(line))
        nr=[x for x,why in bad if why=='not running']
        if nr: print(Y_+'Not running: '+N_+', '.join('%s (%s)'%(x['port'],x['name']) for x in nr[:8])+(' +%d more'%(len(nr)-8) if len(nr)>8 else '')+D_+'  → check menu → 8 (Restart Services)'+N_)
        uf=[x for x,why in bad if why=='ufw']
        if uf:
            print(R_+', '.join('%s/%s'%(x['port'],x['proto']) for x in uf)+N_+' blocked by ufw on this server')
            try: y=input('Open %s now? (y/N): '%('it' if len(uf)==1 else 'them')).strip().lower()
            except EOFError: y=''
            if y=='y':
                for x in uf: fw_open({'port':x['port'],'proto':x['proto']}); print(G_+'✓'+N_+' %s/%s opened'%(x['port'],x['proto']))
        elif not [1 for _,w in bad if w=='not running']: print(G_+'Server side OK.'+N_+' All ReXUI ports are listening'+(' and allowed in ufw.' if v['fw'] else '.'))
        print(D_+'If phones still cannot connect to a port, open it in your VPS company\'s control panel (Firewall / Security group). The server cannot change that one.'+N_)
        if v['clash']: print(Y_+'Two services on one port: '+'; '.join('%s/%s (%s)'%(c['port'],c['proto'],', '.join(c['names'])) for c in v['clash'])+N_)
    elif a[0]=='purge': purge(); ov_net_purge(); hy_purge(); wg_purge(); dns_purge()
    elif a[0]=='check':
        for x in server_check()['items']: print('%-5s %-18s %s'%({'ok':'OK','warn':'WARN','fail':'FAIL'}[x['st']],x['name'],x['msg']))
    elif a[0]=='h443':
        if len(a)>1 and a[1] in ('on','off'):
            st=sload(); st['h443']=a[1]=='on'; wjson(SETF,st,0o600); run('systemctl','restart','tunnel-panel')
            print('443 mode will turn %s in a few seconds. Check it with: menu → Server check'%a[1])
        else: print('443 mode:','on' if h_on() else 'off',('(HAProxy is not installed)' if not h_has() else ''))
    elif a[0]=='perf':
        if len(a)>1:
            try: perf_set({'perf':a[1]})
            except Err as e: print(e); sys.exit(1)
        print('Performance mode:',perf_apply())
    elif a[0]=='dns-setup':
        try: dns_setup(restart=False); print('DNS tunnel ready' if dns_on() else 'DNS tunnel is not installed')
        except Exception as e: print('DNS tunnel setup failed:',e); sys.exit(1)
    elif a[0]=='wg-up':
        try: print('WireGuard ready' if wg_up() else 'WireGuard is not available on this server'); wg_sync()
        except Exception as e: print('WireGuard setup failed:',e); sys.exit(1)
    elif a[0]=='hy-setup':
        try: hy_setup(restart=False); print('Hysteria2 ready' if hy_on() else 'Hysteria2 is not installed')
        except Exception as e: print('Hysteria2 setup failed:',e); sys.exit(1)
    elif a[0]=='ovpn-setup':
        try: ov_setup(restart=False); print('OpenVPN ready' if ov_on() else 'OpenVPN is not installed')
        except Exception as e: print('OpenVPN setup failed:',e); sys.exit(1)
    elif a[0]=='backup': print(backup_file(a[1] or None))
    elif a[0]=='restore':
        try: o=json.loads(rd(a[1]))
        except ValueError: print('Restore failed: this file is not valid JSON'); sys.exit(1)
        try: r=restore(o); print('Restored %d users and the settings'%r['users'])
        except Err as e: print('Restore failed:',e); sys.exit(1)
    elif a[0]=='run':
        migrate(); upgrade(); rw_load(); static(); sample(); hm_load(); tr_load(); fsite_apply(); fetch_ips(); CTX=ctx()
        try: bans_apply(); smtp_apply(); enforce(); ssh_rules(True); xray_apply(True)
        except Exception as e: log('startup:',repr(e))
        try: ov_setup()
        except Exception as e: log('openvpn setup:',repr(e))
        threading.Thread(target=hy_auth_server,daemon=True).start()
        try: hy_setup()
        except Exception as e: log('hysteria setup:',repr(e))
        try: wg_up(); wg_sync()
        except Exception as e: log('wireguard setup:',repr(e))
        try: dns_setup()
        except Exception as e: log('dns setup:',repr(e))
        perf_apply()
        threading.Thread(target=h_apply,daemon=True).start()
        def bye(*x):
            try: collect(True)
            except Exception as e: log('save on stop:',repr(e))
            hm_save(); tr_save(); os._exit(0)
        import signal; signal.signal(signal.SIGTERM,bye)
        threading.Thread(target=monitor,daemon=True).start()
        Srv(('0.0.0.0',P('PANEL_PORT',0)),Hd).serve_forever()
    else: print('use: panel.py setlogin USER PASS | user | backup [FILE] | restore FILE | purge | run')
PANELPY
cat > /opt/tunnel-panel/index.html <<'PANELHTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="robots" content="noindex"><title>ReXUI</title><link rel="manifest" href="manifest.webmanifest"><meta name="theme-color" content="#1f6feb"><link rel="apple-touch-icon" href="icon-192.png"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="apple-mobile-web-app-status-bar-style" content="black-translucent"><link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%231f6feb'/%3E%3Cpath d='M10 9l12 14M22 9L10 23' stroke='%23fff' stroke-width='4' stroke-linecap='round'/%3E%3C/svg%3E">
<style>
:root{--bg:#eef0f5;--side:#fff;--c:#fff;--c2:#f5f6f9;--l:#e4e7ec;--t:#1d2433;--m:#6b7385;--a:#1f6feb;--a2:color-mix(in srgb,var(--a) 11%,var(--c));--g:#16a34a;--r:#dc2626;--y:#d97706;--l2:#4b5563;--sh:0 1px 2px rgba(16,24,40,.05);color-scheme:light}
@media(prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#0e1117;--side:#141821;--c:#161b24;--c2:#1d2330;--l:#262d3b;--t:#e5e9f0;--m:#8b94a5;--a:#4c8dff;--a2:color-mix(in srgb,var(--a) 20%,var(--c));--g:#3fd18b;--r:#f26b6b;--y:#f0b44c;--l2:#a3acbd;--sh:none;color-scheme:dark}}
:root[data-theme=dark]{--bg:#0e1117;--side:#141821;--c:#161b24;--c2:#1d2330;--l:#262d3b;--t:#e5e9f0;--m:#8b94a5;--a:#4c8dff;--a2:color-mix(in srgb,var(--a) 20%,var(--c));--g:#3fd18b;--r:#f26b6b;--y:#f0b44c;--l2:#a3acbd;--sh:none;color-scheme:dark}
:root[data-theme=black]{--bg:#000;--side:#000;--c:#0b0b0c;--c2:#141416;--l:#232326;--t:#ececef;--m:#8d8d96;--a:#4c8dff;--a2:color-mix(in srgb,var(--a) 22%,#000);--g:#3fd18b;--r:#f26b6b;--y:#f0b44c;--l2:#a3acbd;--sh:none;color-scheme:dark}
*{box-sizing:border-box;margin:0}
html,body{background:var(--bg);color:var(--t);font:14px/1.45 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans",sans-serif;font-variant-numeric:tabular-nums;-webkit-text-size-adjust:100%}
button,input,textarea,select{font:inherit;color:inherit}button{cursor:pointer}svg{flex:none;display:block}
.m{color:var(--m)}.ok{color:var(--g)}.bl{color:var(--a)}.bad{color:var(--r)}
aside{position:fixed;inset:0 auto 0 0;width:232px;background:var(--side);border-right:1px solid var(--l);display:flex;flex-direction:column;z-index:10}
.brand{display:flex;align-items:center;justify-content:space-between;padding:18px 16px 14px}.brand b{font-size:21px}
.logo{font-weight:800;letter-spacing:.3px;white-space:nowrap}.logo span,.logo i{font-style:normal;display:inline-block;background:linear-gradient(90deg,var(--a),#14b8a6,#8b5cf6,var(--a));background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:lgs 7s linear infinite}
.logo i{animation:lgs 7s linear infinite,lgx 6s ease-in-out infinite;padding:0 .02em}
@keyframes lgs{to{background-position:300% 0}}@keyframes lgx{0%,84%,100%{transform:none}90%{transform:translateY(-.08em) scale(1.18) rotate(-8deg)}95%{transform:scale(1.05)}}
@media(prefers-reduced-motion:reduce){.logo span,.logo i{animation:none}}
.banner{display:flex;gap:10px;align-items:flex-start;border:1px solid;border-radius:10px;padding:10px 14px;margin-bottom:14px;font-size:13.5px}.banner.w{color:var(--y);background:color-mix(in srgb,var(--y) 10%,var(--c))}.banner.e{color:var(--r);background:color-mix(in srgb,var(--r) 10%,var(--c))}.banner.i{color:var(--a);background:color-mix(in srgb,var(--a) 9%,var(--c))}.banner.i div{color:var(--t)}.banner.i code{font-size:12px;padding:1px 5px;border-radius:4px;background:var(--c2)}.banner.i a{color:var(--a);font-weight:600}.banner b{color:var(--t)}
.uch{display:flex;align-items:flex-end;gap:2px;height:120px;margin-top:10px}.uch i{flex:1;display:flex;flex-direction:column;justify-content:flex-end;height:100%;min-width:0}.uch i b{display:block;background:var(--a);border-radius:2px 2px 0 0}.uch i u{display:block;background:var(--l2);opacity:.6}
.uax{display:flex;justify-content:space-between;font-size:11.5px;color:var(--m);margin-top:6px}
.note2{white-space:pre-wrap;word-break:break-word;font-size:13.5px}
.ib{border:0;background:none;color:var(--m);padding:7px;border-radius:8px}.ib:hover{background:var(--c2);color:var(--t)}
nav{display:flex;flex-direction:column;gap:2px;padding:4px 8px;flex:1}
.nb{display:flex;align-items:center;gap:12px;width:100%;padding:10px 12px;border:0;border-radius:9px;background:none;color:var(--t);font-size:14.5px;text-align:left}
.nb:hover{background:var(--c2)}.nb.on{background:var(--a2);color:var(--a);font-weight:600}.nb svg{color:var(--m)}.nb.on svg{color:var(--a)}
main{margin-left:232px;min-height:100vh;padding:18px 22px 40px;max-width:1440px}
.hdr{display:flex;align-items:center;gap:10px;flex-wrap:wrap;margin-bottom:14px}
.chip{display:inline-flex;align-items:center;gap:7px;border:1px solid var(--l);background:var(--c);border-radius:20px;padding:4px 12px;font-size:13px}
.chip .dot{width:8px;height:8px;border-radius:50%}.ver{font:12px ui-monospace,Menlo,Consolas,monospace;color:var(--m)}
.acts{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:16px;padding-bottom:14px;border-bottom:1px solid var(--l)}
.btn{display:inline-flex;align-items:center;gap:7px;border:1px solid var(--l);background:var(--c);border-radius:8px;padding:7px 13px;font-size:13.5px}
.btn:hover{border-color:var(--a);color:var(--a)}.pri{background:var(--a);border-color:var(--a);color:#fff}.pri:hover{color:#fff;opacity:.92}.out{border-color:var(--a);color:var(--a)}.dng{color:var(--r)}.dng:hover{border-color:var(--r);color:var(--r)}
button:focus-visible,input:focus-visible,textarea:focus-visible{outline:2px solid var(--a);outline-offset:2px}
.card{background:var(--c);border:1px solid var(--l);border-radius:12px;padding:18px 20px;box-shadow:var(--sh);min-width:0;overflow:hidden}
.g2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;margin-bottom:14px}.mb{margin-bottom:14px}
.lab{display:flex;align-items:center;gap:7px;font-size:12px;font-weight:600;letter-spacing:.8px;text-transform:uppercase;color:var(--m)}
.big{font-size:34px;font-weight:700;line-height:1.1;margin:10px 0 4px}.big i{font-style:normal;font-size:14px;color:var(--m);font-weight:500;margin-left:3px}
.sub{font-size:13px;color:var(--m)}.ap{display:flex;justify-content:space-between;font-size:11.5px;letter-spacing:.6px;color:var(--m);margin-top:12px;text-transform:uppercase}
.spk{margin:6px -20px -18px}
.sh{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;flex-wrap:wrap}
.now{display:flex;gap:18px;font-size:13px;color:var(--m)}.now b{color:var(--t);margin-left:4px}.now span{display:inline-flex;align-items:center;gap:4px}
.ch{margin:12px 0 0}.tri{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--l);margin-top:12px;padding-top:12px}
.tri div{padding:0 14px}.tri div+div{border-left:1px solid var(--l)}.tri div:first-child{padding-left:0}.tri b{display:block;font-size:20px;margin-top:3px}.tri small{font-size:11.5px;letter-spacing:.6px;color:var(--m);text-transform:uppercase}
.leg{display:flex;gap:24px;font-size:13px;color:var(--m);margin-top:8px}.leg span{display:inline-flex;align-items:center;gap:6px}.leg i{width:14px;height:2px;border-radius:2px;display:inline-block}.leg b{color:var(--t)}
.kv2{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.pair{display:flex;gap:0}.pair div{padding-right:14px}.pair div+div{border-left:1px solid var(--l);padding-left:14px}
.pair small{font-size:11.5px;letter-spacing:.6px;color:var(--m);text-transform:uppercase}.pair b{display:block;font-size:22px;margin-top:3px}
.ips{display:flex;align-items:center;justify-content:space-between;margin-top:16px}.ipv{font-size:13.5px;margin-top:6px;word-break:break-all}.blur{filter:blur(6px);user-select:none}
.tiles{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:12px}button.tile{font:inherit;color:inherit;cursor:pointer}button.tile:hover{border-color:var(--a)}
.tile{background:var(--c2);border:1px solid var(--l);border-radius:10px;padding:12px 6px;text-align:center}.tile b{display:block;font-size:24px}.tl3 .tile b{font-size:19px}.tile small{font-size:11px;letter-spacing:.6px;color:var(--m)}
.svcg{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:10px;margin-top:12px}
.sv{display:flex;align-items:center;gap:9px;background:var(--c2);border:1px solid var(--l);border-radius:10px;padding:10px 12px;text-align:left;min-width:0}
.sv:hover{border-color:var(--a)}.sv[disabled]{cursor:default;opacity:.55}.sv .dot{width:9px;height:9px;border-radius:50%}
.sv b{display:block;font-size:13.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.sv small{color:var(--m);font-size:11.5px}.sv em{margin-left:auto;font-style:normal;font-size:11px;font-weight:700;letter-spacing:.4px;white-space:nowrap}
.bar{display:flex;gap:10px;align-items:center;margin-bottom:14px;flex-wrap:wrap}.bar input{flex:1;min-width:180px}
select{width:100%;background:var(--c);border:1px solid var(--l);border-radius:8px;padding:10px 12px}.ck{display:flex;align-items:center;gap:10px;color:var(--t);font-weight:500;margin:12px 0 0;cursor:pointer}.ck input{width:18px;height:18px;margin:0;accent-color:var(--a)}
input,textarea{width:100%;background:var(--c);border:1px solid var(--l);border-radius:8px;padding:10px 12px}textarea{min-height:110px;font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;resize:vertical}
label{display:block;font-size:13px;color:var(--m);font-weight:600;margin:12px 0 5px}.ovf select,.ovf input:not([type=checkbox]){display:block;margin-top:6px;font-weight:400;color:var(--t)}
.ul{display:grid;gap:12px;grid-template-columns:repeat(auto-fill,minmax(300px,1fr))}
.uc{display:flex;flex-direction:column;gap:12px;text-align:left;width:100%;cursor:pointer;font:inherit;color:inherit}.uc:hover{border-color:var(--a)}
.uh{display:flex;align-items:center;gap:11px}.uh b{font-size:15px;word-break:break-all}
.av{width:38px;height:38px;border-radius:10px;display:grid;place-items:center;font-weight:800;color:#fff;flex:none}
.pill{margin-left:auto;font-size:11px;font-weight:700;letter-spacing:.4px;padding:3px 10px;border-radius:20px;border:1px solid currentColor;text-transform:uppercase;white-space:nowrap}
.um{display:flex;gap:16px;font-size:12.5px;color:var(--m);flex-wrap:wrap;align-items:center}.um span{display:inline-flex;align-items:center;gap:5px}
.ubar{height:6px;border-radius:4px;background:var(--c2);overflow:hidden;border:1px solid var(--l)}.ubar i{display:block;height:100%}
.empty{text-align:center;padding:40px 10px;color:var(--m)}
.sg{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));align-items:start}
.kv{display:flex;align-items:baseline;gap:12px;padding:8px 0;border-bottom:1px solid var(--l);font-size:13.5px}.kv:last-child{border:0}
.kv span{color:var(--m);white-space:nowrap}.kv b{margin-left:auto;text-align:right;font-weight:600;word-break:break-all}
.ct{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:10px}
.note{font-size:13px;color:var(--m);margin:4px 0 10px}
#dt{position:fixed;inset:0;z-index:25;background:rgba(10,14,22,.45);display:flex;justify-content:flex-end}#dt[hidden],#md[hidden],#lg[hidden],#app[hidden]{display:none}
.dts{width:100%;max-width:600px;height:100%;overflow:auto;background:var(--bg);border-left:1px solid var(--l);padding:0 16px 40px}.dts .card{margin-bottom:12px}
.dth{position:sticky;top:0;z-index:2;background:var(--bg);display:flex;align-items:center;justify-content:space-between;padding:14px 0;margin-bottom:6px;border-bottom:1px solid var(--l)}
.cb{padding:10px 0;border-bottom:1px solid var(--l)}
.qrn{display:flex;gap:6px;flex-wrap:wrap;margin-top:6px}.qrn .btn{border-style:dashed;color:var(--a);border-color:color-mix(in srgb,var(--a) 55%,var(--l));padding:3px 10px;font-size:12px;font-weight:600}input.flash{box-shadow:0 0 0 3px color-mix(in srgb,var(--a) 35%,transparent)}
.mr.mrx{justify-content:space-between;flex-wrap:wrap;gap:10px}.mra{display:flex;gap:6px;flex-wrap:wrap}.mra .btn{padding:5px 10px;font-size:12.5px}.btn.red{color:var(--r);border-color:color-mix(in srgb,var(--r) 40%,var(--l));background:color-mix(in srgb,var(--r) 6%,var(--c))}
.cg2{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,300px),1fr));gap:10px;margin-top:6px}.cg2 .cb{border:1px solid var(--l)!important;border-radius:10px;padding:10px;height:100%}.cg2 .cb .code{max-height:96px;overflow-y:auto;font-size:12px;overscroll-behavior:contain;scrollbar-width:thin}.cg2>div{min-width:0}

.kg{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;margin-top:10px}.tlk{white-space:normal;display:flex;flex-direction:column;align-items:flex-start;gap:2px;text-align:left;border:1px solid var(--l);background:var(--c2);border-radius:9px;padding:8px 10px;font:inherit;color:inherit;cursor:copy;min-width:0}.tlk span{font-size:11.5px;color:var(--m)}.tlk b{white-space:normal!important;overflow:visible!important;text-overflow:clip!important;max-width:100%;font-size:13.5px!important;line-height:1.3;overflow-wrap:anywhere;word-break:break-all;font-weight:600}.tlk:hover{border-color:var(--a)}.uab0{width:28px;display:inline-block}#dtsub{scroll-margin-top:72px}
.uact{display:inline-flex;gap:2px;flex:none}.uab{width:28px;height:28px;border:0;background:none;border-radius:6px;color:var(--m);display:inline-flex;align-items:center;justify-content:center;cursor:pointer}.uab:hover{background:var(--c2);color:var(--a)}
.uqx{max-width:980px!important}.qst{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin:14px 0}.qst div{background:var(--c2);border-radius:8px;padding:8px 10px}.qst span{display:block;font-size:11.5px;color:var(--m)}.qst b{font-size:15px}
.qgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px;align-items:stretch}
.qcard{border:1px solid var(--l);border-radius:12px;padding:12px;display:flex;flex-direction:column;gap:10px;min-width:0;background:var(--c)}
.qh b{font-size:13.5px;font-weight:700;overflow-wrap:anywhere}
.qsv{background:#fff;border-radius:10px;padding:6px;display:flex;justify-content:center;border:1px solid var(--l)}.qsv svg{width:100%;height:auto;max-width:230px;aspect-ratio:1;display:block}
.qln{font:11.5px/1.45 ui-monospace,Menlo,Consolas,monospace;color:var(--m);word-break:break-all;display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden}
.qtx{margin:0;flex:1;background:var(--c2);border-radius:10px;padding:10px 12px;font:12.5px/1.6 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all;color:var(--t)}
.qbt{display:flex;gap:6px;flex-wrap:wrap;margin-top:auto}.qcard .jsb{border:1px solid var(--l);border-radius:8px;max-height:260px;margin:0}
@media (max-width:560px){.qst{grid-template-columns:1fr 1fr}.qgrid{grid-template-columns:1fr}}.jsw{margin-top:8px;border:1px solid var(--l);border-radius:8px;overflow:hidden}.jsh{display:flex;justify-content:space-between;align-items:center;gap:8px;padding:6px 8px;background:var(--c2)}.jsh small{color:var(--m)}.jsb{margin:0;padding:10px;max-height:320px;overflow:auto;font:12px/1.45 ui-monospace,Menlo,Consolas,monospace;white-space:pre;background:var(--c);color:var(--t)}
#dt .lab{color:var(--t);font-size:13px;font-weight:700}#dt .cbh small{color:var(--t);font-weight:600}.cb:last-child{border:0;padding-bottom:0}.cbh{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px}
.cbh small{font-size:12px;font-weight:700;letter-spacing:.4px;color:var(--m);text-transform:uppercase}
.code{display:block;width:100%;text-align:left;font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;color:var(--t);background:var(--c2);border:1px solid var(--l);border-radius:8px;padding:10px 12px;white-space:pre-wrap;word-break:break-all;cursor:copy}
.code:hover{border-color:var(--a)}.sm{padding:5px 11px;font-size:12.5px}
.ua{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:14px}.ua .btn{justify-content:center;padding:8px 4px;font-size:12.5px}
#qrm{position:fixed;inset:0;z-index:35;background:rgba(10,14,22,.6);display:flex;align-items:center;justify-content:center;padding:16px}#qrm[hidden]{display:none}
.qrc{width:100%;max-width:340px}#qrs{background:#fff;border-radius:10px;padding:8px;display:flex;justify-content:center}#qrs svg{width:100%;height:auto;max-width:300px}
#md{position:fixed;inset:0;z-index:30;background:rgba(10,14,22,.5);display:flex;align-items:center;justify-content:center;padding:16px}
#md .card{width:100%;max-width:420px;max-height:92vh;overflow:auto}#md h2{font-size:17px}
.mr{display:flex;gap:8px;justify-content:flex-end;margin-top:18px}.err{color:var(--r);font-size:13px;min-height:18px;margin-top:8px}
#lg{position:fixed;inset:0;z-index:40;background:var(--bg);display:flex;align-items:center;justify-content:center;padding:16px}#lg form{width:100%;max-width:370px}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--t);color:var(--bg);border-radius:10px;padding:10px 16px;z-index:50;max-width:92vw;font-size:13.5px;box-shadow:0 6px 20px rgba(0,0,0,.2)}.toast.e{background:var(--r);color:#fff}
@media(max-width:860px){.g2.st4{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.st4 .card{padding:14px 14px}.st4 .big{font-size:25px;margin-top:6px}.st4 .sub{font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.st4 .ap{font-size:10px;margin-top:8px}.st4 .spk{margin:4px -14px -14px}
aside{display:none}#app #mt{display:flex}#app #bn{display:grid}.toast{bottom:calc(92px + env(safe-area-inset-bottom))}.bar input{flex-basis:100%}
 main{margin-left:0;padding:0 12px calc(90px + env(safe-area-inset-bottom))}.g2{grid-template-columns:minmax(0,1fr)}.big{font-size:30px}.kv2{grid-template-columns:minmax(0,1fr)}.ul,.sg{grid-template-columns:minmax(0,1fr)}
 .tri{grid-template-columns:1fr 1fr;row-gap:12px}.tri div{padding:0 10px}.tri div:nth-child(3){grid-column:1/-1;border-left:0;padding-left:0;border-top:1px solid var(--l);padding-top:10px}.tri b{font-size:17px}.svcg{grid-template-columns:repeat(2,minmax(0,1fr))}.sv{flex-wrap:wrap}.sv em{margin-left:18px;width:100%}.now{flex-direction:column;gap:2px}}

.brand b{min-width:0;overflow:hidden;text-overflow:ellipsis}
#mt,#bn{display:none}
#mt{align-items:center;gap:2px;position:sticky;top:0;z-index:9;margin:0 -12px 8px;padding:10px 8px 8px 14px;background:color-mix(in srgb,var(--bg) 82%,transparent);-webkit-backdrop-filter:blur(12px);backdrop-filter:blur(12px)}
#mt .logo{font-size:21px;margin-right:auto;overflow:hidden;text-overflow:ellipsis}
#bn{grid-template-columns:repeat(5,1fr);position:fixed;left:0;right:0;bottom:0;z-index:15;background:color-mix(in srgb,var(--side) 90%,transparent);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);border-top:1px solid var(--l);padding:6px 4px calc(6px + env(safe-area-inset-bottom))}
.bnb{display:flex;flex-direction:column;align-items:center;gap:3px;border:0;background:none;color:var(--m);font-size:11.5px;font-weight:600;padding:2px 0 4px;border-radius:12px;min-width:0}
.bnb i{display:grid;place-items:center;width:50px;height:30px;border-radius:15px;transition:background .2s}.bnb.on{color:var(--a)}.bnb.on i{background:var(--a2)}
.seg{display:inline-flex;background:var(--c2);border:1px solid var(--l);border-radius:9px;padding:2px;gap:2px;flex:none}
.seg button{border:0;background:none;border-radius:7px;padding:5px 11px;font-size:12.5px;font-weight:600;color:var(--m);display:inline-flex;align-items:center;gap:5px}
.seg button.on{background:var(--c);color:var(--a);box-shadow:0 1px 3px rgba(16,24,40,.12)}
.bar select{width:auto;padding:8px 10px}
.cw{position:relative;touch-action:pan-y}
.tl{position:absolute;top:0;bottom:0;width:1px;background:var(--m);opacity:.55;pointer-events:none}
.tb{position:absolute;top:6px;background:var(--c);border:1px solid var(--l);border-radius:8px;padding:7px 10px;font-size:12px;box-shadow:0 6px 18px rgba(0,0,0,.14);pointer-events:none;white-space:nowrap;z-index:2;display:flex;flex-direction:column;gap:2px}
.tl[hidden],.tb[hidden]{display:none}.tb small{color:var(--m)}.tb span{display:flex;align-items:center;gap:6px}.tb span i{width:8px;height:8px;border-radius:2px}.tb b{margin-left:auto;padding-left:12px}
.tw{padding:0;overflow-x:auto}
.ut{width:100%;border-collapse:collapse;font-size:13.5px;min-width:660px}
.ut th{text-align:left;font-size:11.5px;letter-spacing:.6px;text-transform:uppercase;color:var(--m);font-weight:600;padding:0;border-bottom:1px solid var(--l);background:var(--c2);white-space:nowrap}
.ut th button{display:flex;align-items:center;gap:4px;width:100%;padding:11px 14px;border:0;background:none;color:inherit;font:inherit;letter-spacing:inherit;text-transform:inherit}.ut th button.on{color:var(--a)}
.ut td{padding:10px 14px;border-bottom:1px solid var(--l);vertical-align:middle;background:var(--c)}.ut tbody tr:last-child td{border:0}
.ut tbody tr{cursor:pointer}.ut tbody tr:hover td{background:var(--c2)}.ut tbody tr:focus-visible{outline:2px solid var(--a);outline-offset:-2px}
.ut th:first-child,.ut td:first-child{position:sticky;left:0;z-index:1}
.ut .av{width:30px;height:30px;border-radius:8px;font-size:13px}.ut .pill{margin:0}.ut .ubar{width:120px;margin-top:5px}
.ut{font-size:12.5px;min-width:440px}.ut th button{padding:7px 10px;font-size:10.5px}.ut td{padding:5px 10px;line-height:1.25}
.ut .av{width:24px;height:24px;border-radius:6px;font-size:11px}.ut .tu{gap:8px}.ut .tu b{font-size:13px}.ut .tu small{font-size:11px}.ut .pill{padding:2px 8px;font-size:11px}.ut .ubar{width:100px;margin-top:3px;height:4px}
.ut .sw{width:32px;height:18px;border-radius:9px;vertical-align:middle}.ut .sw i{top:2px;left:2px;width:14px;height:14px}.ut .sw.on i{left:16px}.ut .sw:disabled{opacity:.5}.avw{position:relative;display:inline-flex;flex:none}.udot{position:absolute;right:-3px;bottom:-3px;width:9px;height:9px;border-radius:50%;border:2px solid var(--c)}
.udot.on{background:var(--g)}.udot.off{background:var(--r);opacity:.75}
.ut .tu b{display:block}.ut td:first-child{white-space:normal}.ut .tu .tag{vertical-align:middle;margin:1px 4px 0 0;white-space:nowrap}.useen{display:inline-block;white-space:nowrap;margin-right:6px;font-size:10.5px;color:var(--m);line-height:1.3}.useen.on{color:var(--g);font-weight:600}
.uspd{display:flex;gap:8px;font-size:10.5px;margin-top:2px;line-height:1.3;font-variant-numeric:tabular-nums;white-space:nowrap}.uspd .d{color:var(--a)}.uspd .u{color:#8b5cf6}.uspd .td{color:var(--m)}.uspd.idle .d,.uspd.idle .u{color:var(--m)}
.ut td.exw{color:var(--y)}.ut td.exr{color:var(--r)}.ut td.exw small,.ut td.exr small{color:inherit;font-weight:600}
.udev{display:inline-flex;align-items:center;gap:5px}.udev:before{content:"";width:6px;height:6px;border-radius:50%;background:var(--l)}.udev.on:before{background:var(--g)}.ut td{white-space:nowrap}.ut .tu small{white-space:normal}@media (max-width:640px){.ut .tag{display:none}.ut td,.ut th button{padding-left:8px;padding-right:8px}}
.tu{display:flex;align-items:center;gap:10px;min-width:0;max-width:240px}.tu b{word-break:break-all}.tu small{display:block;color:var(--m);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:190px}
.sw{display:flex;gap:10px;flex-wrap:wrap;margin-top:4px}.sw button{width:36px;height:36px;border-radius:50%;border:3px solid var(--c);background:var(--sw);box-shadow:0 0 0 1px var(--l);display:grid;place-items:center;color:#fff;padding:0}.sw button[aria-checked=true]{box-shadow:0 0 0 2px var(--sw)}
.slab{display:block;font-size:13px;color:var(--m);font-weight:600;margin:14px 0 6px}
#lg{overflow:hidden}
.lbg{position:absolute;inset:0;overflow:hidden;pointer-events:none}
.lbg::after{content:"";position:absolute;inset:0;background-image:radial-gradient(color-mix(in srgb,var(--t) 10%,transparent) 1px,transparent 1.5px);background-size:22px 22px;-webkit-mask-image:radial-gradient(ellipse at center,#000 25%,transparent 72%);mask-image:radial-gradient(ellipse at center,#000 25%,transparent 72%)}
.lbg i{position:absolute;width:48vmax;height:48vmax;border-radius:50%;filter:blur(72px);opacity:.36;animation:blob 22s ease-in-out infinite alternate}
.lbg i:nth-child(1){background:var(--a);top:-20vmax;left:-14vmax}
.lbg i:nth-child(2){background:#14b8a6;bottom:-22vmax;right:-16vmax;animation-duration:27s;animation-delay:-9s}
.lbg i:nth-child(3){background:#8b5cf6;top:38%;left:42%;width:30vmax;height:30vmax;animation-duration:31s;animation-delay:-5s;opacity:.26}
@keyframes blob{0%{transform:translate(0,0) scale(1)}50%{transform:translate(9vmax,7vmax) scale(1.15)}100%{transform:translate(-7vmax,11vmax) scale(.9)}}
.lcard{position:relative;width:100%;max-width:380px;background:color-mix(in srgb,var(--c) 80%,transparent);-webkit-backdrop-filter:blur(18px);backdrop-filter:blur(18px);border:1px solid color-mix(in srgb,var(--l) 85%,transparent);border-radius:20px;padding:30px 26px 20px;box-shadow:0 24px 64px rgba(15,23,42,.18);animation:rise .5s ease-out}
@keyframes rise{from{opacity:0;transform:translateY(14px)}}
.lhead{text-align:center;margin-bottom:12px}.lhead .logo{font-size:42px;display:inline-block;max-width:100%;overflow:hidden;text-overflow:ellipsis}.lhead p{margin-top:4px;font-size:14px;color:var(--m)}
.fi{display:flex;align-items:center;gap:8px;background:var(--c);border:1px solid var(--l);border-radius:10px;padding:0 4px 0 12px;transition:border-color .15s,box-shadow .15s}
.fi:focus-within{border-color:var(--a);box-shadow:0 0 0 3px color-mix(in srgb,var(--a) 22%,transparent)}.fi>span{color:var(--m);display:flex}
.fi input{border:0;background:none;padding:11px 0;min-width:0}.fi input:focus-visible{outline:none}
.lbtn{width:100%;justify-content:center;padding:12px;margin-top:8px;font-weight:600;border-radius:10px;font-size:14.5px}
.lft{text-align:center;font-size:12px;color:var(--m);margin-top:16px}
@media(prefers-reduced-motion:reduce){.lbg i,.lcard{animation:none}}
.chips{display:flex;gap:6px;flex-wrap:wrap;margin:-4px 0 14px}.chips button{border:1px solid var(--l);background:var(--c);border-radius:20px;padding:5px 12px;font-size:12.5px;font-weight:600;color:var(--m);display:inline-flex;gap:6px;align-items:center}
.chips button b{font-weight:700;color:var(--t)}.chips button.on{background:var(--a2);border-color:var(--a);color:var(--a)}.chips button.on b{color:var(--a)}
.tag{font-size:10.5px;font-weight:700;letter-spacing:.4px;padding:1px 7px;border-radius:6px;background:var(--a2);color:var(--a);margin-left:6px;vertical-align:2px;text-transform:uppercase}
#shm{position:fixed;inset:0;z-index:35;background:rgba(10,14,22,.6);display:flex;align-items:center;justify-content:center;padding:16px}#shm[hidden]{display:none}
.shc{width:100%;max-width:420px;max-height:94vh;display:flex;flex-direction:column}.shc img{width:100%;min-height:0;flex:1;object-fit:contain;border-radius:10px;background:#0f1420}
.shc .mr{flex-wrap:wrap}
.rk{display:flex;align-items:center;gap:10px;padding:8px 0;border-bottom:1px solid var(--l);font-size:13.5px}.rk:last-child{border:0}.rk .av{width:28px;height:28px;border-radius:8px;font-size:12px}
.rk .nm{min-width:0;flex:1}.rk .nm b{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.rk .nm .ubar{display:block;margin-top:5px;height:6px}.rk em{font-style:normal;font-weight:600;white-space:nowrap}
button.rk{width:100%;border:0;border-bottom:1px solid var(--l);background:none;text-align:left;font:inherit;color:inherit}button.rk:hover b{color:var(--a)}
.lst{max-height:520px;overflow:auto;margin-top:6px}.li{display:flex;gap:10px;padding:9px 0;border-bottom:1px solid var(--l);font-size:13px;align-items:flex-start}.li:last-child{border:0}
.li .dt{color:var(--m);white-space:nowrap;min-width:74px}.li .tx{flex:1;min-width:0;word-break:break-word}.li small{display:block;color:var(--m)}
.dotc{width:8px;height:8px;border-radius:50%;margin-top:6px;flex:none}
.tl3{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:10px}
.stabs{display:flex;gap:4px;overflow-x:auto;margin:0 0 14px;padding:3px;background:var(--c);border:1px solid var(--l);border-radius:12px;scrollbar-width:none}.stabs::-webkit-scrollbar{display:none}
.stabs button{flex:1 0 auto;border:0;background:none;border-radius:9px;padding:8px 14px;font-size:13.5px;font-weight:600;color:var(--m);white-space:nowrap}.stabs button.on{background:var(--a2);color:var(--a)}
@media(max-width:600px){.stabs button{padding:8px 9px;font-size:13px}}
.gl{grid-column:1/-1}.gll{display:flex;flex-direction:column;margin-top:8px}.glr{display:flex;align-items:center;gap:12px;padding:12px 4px;border:0;border-bottom:1px solid var(--l);background:none;color:inherit;font:inherit;text-align:left;cursor:pointer}.glr:last-child{border-bottom:0}.glr:hover{background:var(--c2)}.glr>svg{flex:none;color:var(--a)}.glr span:not(.gla){flex:1;display:flex;flex-direction:column;gap:2px;min-width:0}.glr small{color:var(--m);font-size:12.5px}.gla{color:var(--m);font-size:22px;line-height:1}
.glb{grid-column:1/-1;margin-bottom:-4px}.btn.bl{background:#2563eb;border-color:#2563eb;color:#fff}.btn.bl:hover{background:#1d4ed8}
.ssub{display:flex;gap:6px;overflow-x:auto;margin:-4px 0 14px;scrollbar-width:none}.ssub::-webkit-scrollbar{display:none}.ssub[hidden]{display:none}.ssub button[hidden]{display:none}
.ssub button{flex:none;border:1px solid var(--l);background:var(--c);border-radius:999px;padding:6px 13px;font-size:13px;font-weight:600;color:var(--m);white-space:nowrap}.ssub button.on{border-color:var(--a);background:var(--a2);color:var(--a)}
.tabx{display:none!important}
#sbar{position:fixed;left:50%;transform:translateX(-50%);bottom:18px;z-index:16;display:flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:center;width:max-content;max-width:calc(100vw - 24px);background:var(--c);border:1px solid var(--a);border-radius:14px;padding:8px 10px;box-shadow:0 10px 30px rgba(0,0,0,.25)}
#sbar b{font-size:13.5px;padding:0 4px}#sbar .sbs{width:1px;height:22px;background:var(--l)}#sbar [data-sa=x] svg{transform:rotate(45deg)}
.uc{position:relative}.sck{display:grid;place-items:center;width:22px;height:22px;border-radius:7px;border:2px solid var(--l);color:transparent;flex:none;background:var(--c)}.sck.on{background:var(--a);border-color:var(--a);color:#fff}
.uc.sel{border-color:var(--a);box-shadow:0 0 0 1px var(--a)}.ut tr.sel td{background:var(--a2)}
#ul.pick{margin-bottom:90px}.ulm{display:flex;justify-content:center;margin:14px 0}.ulm:empty{display:none}
@media(max-width:860px){#sbar{bottom:calc(78px + env(safe-area-inset-bottom));flex-wrap:nowrap;overflow-x:auto;justify-content:flex-start;width:calc(100vw - 24px);scrollbar-width:none}#sbar::-webkit-scrollbar{display:none}#sbar>*{flex:none}#sbar [data-sa=x]{order:-1}#sbar .sbs{display:none}}
.lvo{margin-top:10px;max-height:60vh;min-height:160px;overflow:auto;background:var(--c2);border:1px solid var(--l);border-radius:8px;padding:10px 12px;font:11.5px/1.55 ui-monospace,Menlo,Consolas,monospace;white-space:pre-wrap;word-break:break-all;color:var(--t)}
#sxo{position:fixed;inset:0;z-index:40;background:rgba(10,14,22,.55);display:flex;justify-content:center;align-items:flex-start;padding:10vh 12px 12px}#sxo[hidden]{display:none}
.sxp{width:100%;max-width:560px;background:var(--c);border:1px solid var(--l);border-radius:14px;padding:12px;box-shadow:0 20px 50px rgba(0,0,0,.3)}
#sxr{max-height:60vh;overflow:auto;margin-top:8px}.sxi{display:flex;align-items:center;gap:10px;width:100%;border:0;background:none;text-align:left;font:inherit;color:var(--t);padding:9px 10px;border-radius:9px}
.sxi.on,.sxi:hover{background:var(--a2)}.sxi small{color:var(--m);margin-left:auto;white-space:nowrap;font-size:12px}.sxi .av{width:26px;height:26px;border-radius:7px;font-size:12px}.sxi>svg{color:var(--m);flex:none}
.sxh{font-size:11px;font-weight:700;letter-spacing:.7px;text-transform:uppercase;color:var(--m);padding:10px 10px 4px}
a.btn{text-decoration:none;color:var(--t)}a.btn.pri{color:#fff}
.hero{display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap;margin-bottom:14px;background:linear-gradient(120deg,color-mix(in srgb,var(--a) 10%,var(--c)),var(--c) 60%)}
.hero h2{font-size:21px;display:flex;align-items:center;gap:10px;margin:2px 0}.hero p{font-size:13.5px}.hdot{width:10px;height:10px;border-radius:50%;box-shadow:0 0 0 4px color-mix(in srgb,currentColor 0%,transparent);flex:none;animation:hp 2s ease-in-out infinite}
@keyframes hp{50%{opacity:.45}}.hb{display:flex;gap:8px;flex-wrap:wrap}
.kps{display:grid;grid-template-columns:repeat(5,minmax(0,1fr));gap:12px;margin-bottom:14px}
.kp{display:flex;align-items:center;gap:12px;text-align:left;font:inherit;color:inherit;cursor:pointer;padding:14px;min-width:0;margin:0}.kp:not([data-go]){cursor:default}.kp[data-go]:hover{border-color:var(--a)}
.ki{display:grid;place-items:center;width:38px;height:38px;border-radius:11px;flex:none}.kt{min-width:0;display:flex;flex-direction:column}.kt small{font-size:11.5px;color:var(--m);font-weight:600;letter-spacing:.3px;text-transform:uppercase;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.kt b{font-size:21px;line-height:1.25;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:100%}.kt em{font-style:normal;font-size:12px;color:var(--m);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.g4{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:14px}.gc{padding:14px 14px 0;overflow:hidden;margin:0}.gt{display:flex;align-items:center;gap:12px}.gi{min-width:0}.gi .lab{margin:0}
.gi .sub{font-size:12.5px;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.gc .ap{margin-top:4px;font-size:11px;gap:10px;justify-content:flex-start}.gc .spk{margin:6px -14px 0}
@media(max-width:1100px){.kps{grid-template-columns:repeat(3,minmax(0,1fr))}.g4{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:860px){.kps{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.kps .kp:last-child{grid-column:span 2}.g4{gap:10px}.hero{padding:16px}.hero h2{font-size:18px}.hb{width:100%;flex-wrap:nowrap}.hb .btn{flex:1 1 0;justify-content:center;white-space:nowrap;padding:8px 6px;font-size:13px;min-width:0}.kp{padding:11px 12px;gap:10px}.gc .ap{display:none}.gi .sub{font-size:11.5px}.ring{width:52px;height:52px}.gt{gap:9px}.kt b{font-size:18px}.ki{width:34px;height:34px}}
@media(prefers-reduced-motion:reduce){.hdot{animation:none}}
.pwr{display:block;padding:12px 18px 16px;font-size:12px;color:var(--m);text-decoration:none}.pwr:hover b{color:var(--a)}.pwm{display:none;text-align:center;font-size:12px;color:var(--m);margin:18px 0 4px;text-decoration:none}@media(max-width:860px){.pwm{display:block}}
.tri b,.pair b{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tri>div,.pair>div{min-width:0}
@media(min-width:861px) and (max-width:1100px){.kps{grid-template-columns:repeat(6,minmax(0,1fr))}.kps .kp{grid-column:span 2}.kps .kp:nth-child(n+4){grid-column:span 3}.tri b{font-size:17px}.pair b{font-size:19px}}
.khd{margin-bottom:12px}.kts{display:inline-flex;gap:4px;padding:3px;background:var(--c);border:1px solid var(--l);border-radius:12px;max-width:100%;overflow-x:auto}
.kts button{display:inline-flex;align-items:center;gap:7px;border:0;background:none;border-radius:9px;padding:8px 14px;font-size:14px;font-weight:600;color:var(--m);white-space:nowrap}.kts button b{font-size:12px;background:var(--c2);border-radius:10px;padding:1px 7px;color:var(--m)}
.kts button.on{background:var(--a2);color:var(--a)}.kts button.on b{background:var(--a);color:#fff}
.pyr{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 10px;align-items:center;padding:10px 0;border-bottom:1px solid var(--l)}
.pyn{display:flex;flex-direction:column;gap:2px;min-width:0}.pyn b{overflow-wrap:anywhere}.pyb{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end}.pyt{grid-column:1/-1}@media(max-width:600px){.pyr{grid-template-columns:minmax(0,1fr)}.pyb{justify-content:flex-start}}.pyt:empty{display:none}
.ckx{display:flex;align-items:center;gap:10px;padding:9px 0;border-bottom:1px solid var(--l)}.ckx .dot{flex:none;width:10px;height:10px;border-radius:50%;align-self:flex-start;margin-top:5px}.ckm{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px}.ckm small{color:var(--m);font-size:12.5px;overflow-wrap:anywhere}
.tw2{overflow-x:auto;margin-top:10px;border:1px solid var(--l);border-radius:10px}.pt{width:100%;border-collapse:collapse;font-size:13px}.pt th,.pt td{padding:8px 10px;border-bottom:1px solid var(--l);text-align:left;white-space:nowrap;background:none;position:static;display:table-cell}.pt th{font-size:11px;letter-spacing:.5px;text-transform:uppercase;color:var(--m);background:var(--c2)}.pt tr:last-child td{border-bottom:0}
.pfm{display:grid;gap:8px;margin-top:10px}.pfm button{display:flex;flex-direction:column;gap:2px;text-align:left;padding:10px 12px;border:1px solid var(--l);border-radius:10px;background:var(--c);color:inherit;font:inherit;cursor:pointer}.pfm button small{color:var(--m);font-size:12.5px}.pfm button[aria-checked=true]{border-color:var(--a);background:var(--a2)}.pfm button[aria-checked=true] b{color:var(--a)}
.ibg{display:grid;grid-template-columns:repeat(auto-fill,minmax(290px,1fr));gap:14px}.ibg .card{margin:0}.ibc.off{opacity:.62}
.ibchips{display:flex;flex-wrap:wrap;gap:6px;margin:0 0 6px}.ibchips span{font-size:11.5px;font-weight:600;padding:3px 9px;border-radius:6px;background:var(--a2);color:var(--a)}.ibchips span.dflt{background:var(--c2);color:var(--m)}
.ibb{display:flex;gap:6px;margin-top:12px;flex-wrap:wrap}.ibb .btn{padding:6px 10px;font-size:12.5px}.ibb .btn:disabled{opacity:.4}
.ibt{display:grid;grid-template-columns:repeat(3,1fr);gap:6px;margin:12px 0 6px}.ibt button{border:1px solid var(--l);background:var(--c2);border-radius:8px;padding:9px 4px;font-size:12.5px;font-weight:600;color:var(--m)}
.ibt button.on{background:var(--a2);color:var(--a);border-color:var(--a)}
.sqg{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:6px 0 10px}.sqg.two{grid-template-columns:repeat(2,1fr)}
.sq{border:1.5px solid var(--l);background:var(--c);border-radius:10px;padding:12px 6px;text-align:center;font-weight:700;font-size:13.5px;color:var(--t);min-height:66px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:4px}
.sq small{font-weight:500;font-size:11px;color:var(--m);line-height:1.25}.sq.on{border-color:var(--a);background:var(--a2);color:var(--a)}.sq.on small{color:var(--a)}.sq:disabled{opacity:.35;cursor:not-allowed}
.ibp{border:1px solid var(--l);border-radius:8px;padding:4px 10px;max-height:190px;overflow:auto;margin:4px 0 10px}.ibp label.ck{display:flex;gap:8px;align-items:flex-start;padding:6px 0;margin:0;font-size:13px;border-bottom:1px solid var(--l)}.ibp label.ck:last-child{border:0}.ibp .m{color:var(--m);font-size:12px}
.ibg2{display:grid;grid-template-columns:1fr 1fr;gap:0 14px}.ibg2>div{min-width:0}@media (max-width:560px){.ibg2{grid-template-columns:1fr}}.alpg{display:flex;gap:16px;flex-wrap:wrap;padding:6px 0 2px}.alpc{display:inline-flex;align-items:center;gap:6px;font-weight:500;margin:0;cursor:pointer}.alpc input{width:16px;height:16px;margin:0;accent-color:var(--a)}#ib_fp{width:100%}
.ibx{max-width:640px!important;position:relative}.ixh{display:flex;align-items:center;justify-content:space-between}.ixh h2{margin:0}.ixc{border:0;background:none;font-size:24px;line-height:1;color:var(--m);cursor:pointer;padding:2px 6px}
.ixt{display:flex;gap:18px;border-bottom:1px solid var(--l);margin:10px 0 8px;overflow-x:auto;scrollbar-width:none}.ixt button{border:0;background:none;padding:9px 0;font:inherit;font-size:13.5px;color:var(--m);border-bottom:2px solid transparent;white-space:nowrap;cursor:pointer}.ixt button.on{color:var(--a);border-color:var(--a);font-weight:600}
.ir{display:grid;grid-template-columns:150px minmax(0,1fr);gap:12px;align-items:center;margin:9px 0}.ir>label,.ir>span{text-align:right;margin:0;font-weight:500;font-size:13px;color:var(--t)}.ic{min-width:0}.ic input,.ic select{margin:0;width:100%}.ic input.sm{max-width:130px}.ir .note{margin:-4px 0 0;font-size:12px}
.q{display:inline-flex;align-items:center;justify-content:center;width:14px;height:14px;border:1px solid var(--m);border-radius:50%;font-size:10px;color:var(--m);margin-left:4px;cursor:help;vertical-align:1px}
.iseg{display:inline-flex;border:1px solid var(--l);border-radius:8px;overflow:hidden;flex-wrap:wrap}.iseg button{border:0;border-right:1px solid var(--l);background:var(--c);padding:7px 14px;font:inherit;font-size:13px;color:var(--t);cursor:pointer}.iseg button:last-child{border-right:0}.iseg button.on{background:var(--a);color:#fff}.iseg button:disabled{opacity:.4;cursor:not-allowed}
.tgs{display:flex;gap:6px;flex-wrap:wrap}.tgs button{border:1px solid var(--l);background:var(--c);border-radius:6px;padding:5px 11px;font:inherit;font-size:12.5px;color:var(--m);cursor:pointer}.tgs button.on{border-color:var(--a);background:var(--a2);color:var(--a);font-weight:600}
.chips[data-ck]{display:flex;flex-wrap:wrap;gap:5px;align-items:center;border:1px solid var(--l);border-radius:8px;padding:5px 6px;background:var(--c);min-height:38px}.chips[data-ck] input{flex:1;min-width:90px;border:0!important;padding:3px 4px!important;background:none;box-shadow:none!important;width:auto!important}
.ichip{display:inline-flex;align-items:center;gap:3px;background:var(--c2);border:1px solid var(--l);border-radius:5px;padding:1px 3px 1px 7px;font-size:12.5px}.ichip button{border:0;background:none;color:var(--m);font-size:15px;line-height:1;cursor:pointer;padding:0 3px}
.cg{border:1px solid var(--l);background:var(--c2);border-radius:6px;width:32px;height:30px;font-size:16px;cursor:pointer;color:var(--a);flex:none}
.tgt{display:flex;gap:6px;align-items:center}.tgt input{flex:1;min-width:0}.tgt .btn{flex:none;white-space:nowrap}
.two{display:grid;grid-template-columns:1fr 1fr;gap:6px}
.isub{border-top:1px solid var(--l);margin:14px 0 4px;padding-top:8px;font-size:12px;font-weight:600;color:var(--m);text-transform:uppercase;letter-spacing:.04em}
.kvl,.exl{display:flex;flex-direction:column;gap:6px}.kvr{display:grid;grid-template-columns:1fr 1.4fr 32px;gap:6px}.exr{display:grid;grid-template-columns:1.6fr 74px 1fr 32px;gap:6px}.kvr input,.exr input{margin:0;min-width:0}
.rm{border:1px solid var(--l);background:var(--c);border-radius:6px;color:var(--r);cursor:pointer;display:flex;align-items:center;justify-content:center}.addb{align-self:flex-start;display:inline-flex;align-items:center;gap:5px;border:1px dashed var(--a);color:var(--a);background:none;border-radius:6px;padding:5px 10px;font:inherit;font-size:12.5px;cursor:pointer}
.scb{border:1px solid color-mix(in srgb,var(--g) 45%,var(--l));background:color-mix(in srgb,var(--g) 8%,var(--c));border-radius:9px;padding:9px 12px;font-size:12.5px}.scb>b{color:var(--g);display:flex;align-items:center;gap:5px;margin-bottom:3px}.scb div{display:grid;grid-template-columns:96px minmax(0,1fr);gap:6px;padding:1px 0}.scb div span:first-child{color:var(--m)}.scb div span:last-child{overflow-wrap:anywhere}.scb p{margin:5px 0 0;color:var(--m)}
.scb.bad{border-color:color-mix(in srgb,var(--r) 45%,var(--l));background:color-mix(in srgb,var(--r) 7%,var(--c))}.scb.bad>b{color:var(--r)}
.fpo{position:absolute;inset:0;background:rgba(10,14,20,.45);border-radius:inherit;display:flex;align-items:flex-start;justify-content:center;padding:40px 10px;z-index:5}.fpc{background:var(--c);border:1px solid var(--l);border-radius:12px;padding:14px 16px;width:100%;max-width:560px;box-shadow:0 10px 40px rgba(0,0,0,.3);max-height:calc(100% - 40px);overflow:auto}
.fpt{border:1px solid var(--l);border-radius:8px;overflow:auto;max-height:340px}.fpt table{width:100%;border-collapse:collapse;font-size:12.5px}.fpt th{position:sticky;top:0;background:var(--c2);text-align:left;font-weight:600;padding:7px 8px}.fpt td{padding:6px 8px;border-top:1px solid var(--l);white-space:nowrap}.fpt .btn{padding:3px 10px;font-size:12px}
.fpt td b{display:block;font-weight:600}.fpt td small{display:block;font-size:11px;white-space:normal}.fok{color:var(--g);background:color-mix(in srgb,var(--g) 12%,var(--c));border-radius:4px;padding:1px 6px;font-size:11.5px}.fno{color:var(--r);font-size:11.5px}
@media (max-width:560px){.ir{grid-template-columns:104px minmax(0,1fr);gap:8px}.ir>label,.ir>span{font-size:12.5px}.exr{grid-template-columns:1fr 64px 32px}.exr input[data-er]{grid-column:1/3}.ixt{gap:14px}.tgt:not(.nw){flex-wrap:wrap}.tgt:not(.nw) input{flex-basis:100%}.fst{display:none}.scb div{grid-template-columns:78px minmax(0,1fr)}.fpc{padding:12px}}
/* 3X-UI look for inbounds (blue) */
.ibx,.ibc,.ibsc{--a:#1677ff;--a2:color-mix(in srgb,#1677ff 10%,var(--c))}
.ibx{max-width:620px!important;padding:20px 24px 18px!important;border-radius:8px!important}.ibx .ixh h2{font-size:16px;font-weight:600}
.ibx .ixt{gap:30px;margin:12px 0 16px}.ibx .ixt button{font-size:14px;padding:10px 0;font-weight:400}.ibx .ixt button.on{font-weight:400}
.ibx .ir{grid-template-columns:150px minmax(0,1fr);gap:16px;margin:0 0 14px}.ibx .ir>label,.ibx .ir>span{font-size:14px;font-weight:400}
.ibx .ic input,.ibx .ic select,.ibx .exr input,.ibx .kvr input,.ibx .fpc input{height:32px;padding:4px 11px;border-radius:6px;font-size:14px;border:1px solid var(--l);min-height:0}
.ibx .ic input:focus,.ibx .ic select:focus{border-color:var(--a);box-shadow:0 0 0 2px color-mix(in srgb,var(--a) 18%,transparent);outline:0}
.ibx .ic input.sm{max-width:120px}
.ibx .sw{width:44px;height:22px;border-radius:11px;background:rgba(0,0,0,.25)}.ibx .sw.on{background:var(--a)}.ibx .sw i{top:2px;left:2px;width:18px;height:18px}.ibx .sw.on i{left:24px}
.ibx .iseg{border-radius:6px}.ibx .iseg button{padding:4px 15px;font-size:14px;background:var(--c);color:var(--t);border-right:1px solid var(--l)}.ibx .iseg button.on{background:var(--c);color:var(--a);box-shadow:inset 0 0 0 1px var(--a)}
.ibx .tgs button{border-radius:4px;font-size:12px;padding:2px 8px}.ibx .tgs button:disabled{cursor:not-allowed;opacity:.75}.ibx .tgs button.on{background:var(--a2);border-color:color-mix(in srgb,var(--a) 45%,var(--l));color:var(--a)}
.ibx .chips[data-ck]{min-height:32px;border-radius:6px;padding:2px 4px}.ibx .ichip{border-radius:4px;font-size:12px}
.ibx .btn{border-radius:6px;padding:4px 15px;font-size:14px;height:32px}.ibx .mr{margin-top:20px}.ibx .q{width:13px;height:13px;font-size:9px}
.ibc .btn.pri,.ibx .btn.pri{background:var(--a);border-color:var(--a);border-radius:6px}
@media (max-width:560px){.ibx{padding:16px!important}.ibx .ir{grid-template-columns:108px minmax(0,1fr);gap:10px}.ibx .ir>label,.ibx .ir>span{font-size:13px}.ibx .ixt{gap:18px}}
.rws{border:1px solid var(--l);border-radius:9px;padding:8px 10px;font-size:12.5px;width:100%}.rws.ok b{color:var(--g)}.rws.no b{color:var(--r)}.rws.no.fr b{color:var(--m)}.rws small{display:block;color:var(--m);margin-top:2px}
.gmap{margin-top:10px;border-radius:10px;background:color-mix(in srgb,var(--c2) 70%,var(--bg));overflow:hidden}.gmap svg{display:block;width:100%;height:auto}.gland{fill:color-mix(in srgb,var(--m) 28%,var(--c));stroke:var(--c);stroke-width:.6;vector-effect:non-scaling-stroke}
.gd circle{fill:var(--a);stroke:#fff;stroke-width:2;filter:drop-shadow(0 0 6px color-mix(in srgb,var(--a) 60%,transparent))}.gd.w circle{fill:var(--r)}.gd text{font-weight:600;font-family:Inter,system-ui,sans-serif;fill:var(--t);text-anchor:middle;paint-order:stroke;stroke:var(--c)}
.gst{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-top:10px}.gst div{background:var(--c2);border-radius:9px;padding:8px 10px}.gst span{display:block;font-size:11.5px;color:var(--m)}.gst b{font-size:15px}
.gl{display:block;color:var(--m);font-size:11.5px;font-weight:400}.gal{margin-bottom:12px}
@media (max-width:560px){.gst{grid-template-columns:1fr 1fr}}
.pck{display:flex;gap:12px;align-items:flex-start;padding:10px 0;border-bottom:1px solid var(--l)}.pck:last-child{border:0}.pck>b{flex:none;width:24px;height:24px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:13px;color:#fff;background:var(--m)}.pck.ok>b{background:var(--g)}.pck.no>b{background:var(--r)}.pck span{display:block;font-size:14px}.pck small{display:block;color:var(--m);font-size:12.5px;margin-top:2px}
.ita{min-height:84px;font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;border-radius:6px;padding:6px 10px}.btn.cdl{color:var(--r);border-color:color-mix(in srgb,var(--r) 55%,var(--l))}
.ibsum{font-size:12.5px;background:var(--c2);border-radius:8px;padding:8px 10px;margin:6px 0 4px}
.ibs3{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}.ibs3 span{display:block;font-size:12px;color:var(--m)}.ibs3 b{font-size:20px}
.ibtop{display:flex;gap:8px;flex-wrap:wrap;align-items:center}.ibq1{margin-left:auto;display:flex;gap:8px;flex-wrap:wrap}.btn.qk{padding:6px 12px;font-size:13px;min-height:0;color:var(--r);border-color:color-mix(in srgb,var(--r) 50%,var(--l));background:color-mix(in srgb,var(--r) 6%,var(--c))}.btn.qk.on{background:var(--r);color:#fff;border-color:var(--r)}.btn.qk:disabled{opacity:.5}.ibqt{font-size:10.5px;font-weight:600;color:var(--r);border:1px solid color-mix(in srgb,var(--r) 40%,var(--l));border-radius:4px;padding:0 5px;margin-left:6px;vertical-align:1px}.ibtop input{flex:1;min-width:140px;max-width:260px;margin:0}
.ibtw{overflow-x:auto;margin-top:14px;border:1px solid var(--l);border-radius:10px}.ibtab{width:100%;border-collapse:collapse;font-size:13.5px;min-width:640px}
.ibtab th{background:var(--c2);text-align:left;font-weight:600;padding:10px 12px;white-space:nowrap;border-bottom:1px solid var(--l)}.ibtab td{padding:10px 12px;border-bottom:1px solid var(--l);vertical-align:middle}
.ibtab tr:last-child td{border:0}.ibtab tr.off td{opacity:.6}.ibtab tr.off td:nth-child(3){opacity:1}.ibtab .m{font-size:11.5px;color:var(--m)}
.ibm{display:flex;gap:2px}.ibm .ib{width:30px;height:30px;font-size:18px;line-height:1}.ibw{font-size:11.5px;color:var(--y);margin-top:3px;max-width:260px}
.ibchips span.t{background:color-mix(in srgb,var(--g) 13%,var(--c));color:var(--g)}.ibchips span.s{background:color-mix(in srgb,#7c3aed 13%,var(--c));color:#7c3aed}
.ibcl{display:inline-flex;align-items:center;gap:5px;font-weight:600}
.sw{width:42px;height:24px;border-radius:12px;border:0;background:var(--l);position:relative;padding:0;cursor:pointer;transition:background .15s}.sw i{position:absolute;top:3px;left:3px;width:18px;height:18px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25);transition:left .15s}
.sw.on{background:var(--a)}.sw.on i{left:21px}
.ibpop{position:absolute;z-index:60;background:var(--c);border:1px solid var(--l);border-radius:10px;box-shadow:0 8px 24px rgba(0,0,0,.18);padding:5px;min-width:160px}.ibpop button{display:flex;gap:8px;align-items:center;width:100%;border:0;background:none;padding:8px 10px;border-radius:7px;font-size:13.5px;color:var(--t);text-align:left}
.ibpop button:hover{background:var(--c2)}.ibpop button:disabled{opacity:.4}.ibpop .dng{color:var(--r)}
.ibban{background:color-mix(in srgb,var(--r) 12%,var(--c));color:var(--r);border:1px solid color-mix(in srgb,var(--r) 35%,var(--c));border-radius:8px;padding:8px 10px;font-size:13px;font-weight:600;margin:8px 0 0;transition:opacity .4s}.ibban.w{background:color-mix(in srgb,var(--y) 12%,var(--c));color:var(--y);border-color:color-mix(in srgb,var(--y) 35%,var(--c))}.ibban.hide{opacity:0}
#mf label .m{color:var(--m);font-weight:400;font-size:12px}
#md{align-items:flex-start;overflow:auto;padding:28px 16px}#md .card{max-height:none;overflow:visible;margin:0 auto}#md .card.wide{max-width:760px}
.fgrid{display:block}#mf.wide .fgrid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:18px}.mfi.full{grid-column:1/-1}.mfi>.ck{margin-top:34px}
#dt{align-items:flex-start;justify-content:center;overflow:auto;padding:28px 16px}.dts{max-width:760px;height:auto;overflow:visible;border:1px solid var(--l);border-radius:14px;padding:0 18px 18px;box-shadow:0 12px 40px rgba(0,0,0,.25)}.dth{border-radius:14px 14px 0 0}
.ibsb{display:flex;gap:6px;margin:0 0 8px}.ibsel{display:flex;align-items:center;gap:6px;min-height:42px;border:1px solid var(--l);border-radius:8px;padding:5px 30px 5px 8px;background:var(--c);cursor:pointer;position:relative}
.ibsel.open,.ibsel:focus{border-color:var(--a);outline:none}.ibsel .car{position:absolute;right:10px;color:var(--m)}.ibtags{display:flex;flex-wrap:wrap;gap:5px}.ibtags .ph{color:var(--m);font-size:13.5px;padding:3px 2px}
.ibtag{display:inline-flex;align-items:center;gap:4px;background:var(--a2);color:var(--a);border-radius:6px;padding:3px 4px 3px 9px;font-size:12.5px;font-weight:600}.ibtag button{border:0;background:none;color:inherit;font-size:15px;line-height:1;padding:0 4px;cursor:pointer}
.ibdrop{border:1px solid var(--l);border-radius:8px;margin-top:4px;max-height:240px;overflow:auto;background:var(--c);box-shadow:0 6px 18px rgba(0,0,0,.12)}.ibo{display:flex;align-items:center;gap:8px;padding:9px 10px;cursor:pointer;font-size:13.5px;border-bottom:1px solid var(--l)}.ibo:last-child{border:0}
.ibo:hover,.ibo:focus{background:var(--c2);outline:none}.ibo .m{color:var(--m);font-size:12px;margin-left:auto}.ibo .tk{width:16px;height:16px;border:1.5px solid var(--l);border-radius:4px;flex:none}.ibo.on .tk{background:var(--a);border-color:var(--a);box-shadow:inset 0 0 0 3px var(--c)}
@media (max-width:640px){#mf.wide .fgrid{grid-template-columns:minmax(0,1fr)}.mfi>.ck{margin-top:12px}#md,#dt{padding:12px 10px}.ibo .m{display:none}}
.sqg.four{grid-template-columns:repeat(5,1fr)}@media (max-width:900px){.sqg.four{grid-template-columns:repeat(3,1fr)}}@media (max-width:640px){.sqg.four{grid-template-columns:repeat(2,1fr)}}
.ibtab td{vertical-align:middle}.ibtab th{text-transform:uppercase;font-size:11.5px;letter-spacing:.05em;color:var(--m);padding:13px 14px}.ibtab td{padding:14px}.ibtab .r{text-align:right;white-space:nowrap}
.ibn{font-size:14.5px}.mono{font-family:ui-monospace,Menlo,Consolas,monospace}
.ibp1{display:inline-block;padding:4px 12px;border-radius:7px;border:1px solid color-mix(in srgb,var(--a) 30%,var(--c));background:var(--a2);color:var(--a);font-weight:700;font-size:12.5px;font-family:ui-monospace,Menlo,Consolas,monospace}
.ibts{display:inline-block;padding:5px 11px;border-radius:7px;background:var(--c2);font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px;white-space:nowrap}
.ibu{display:inline-block;padding:4px 12px;border-radius:20px;border:1px solid color-mix(in srgb,var(--g) 35%,var(--c));background:color-mix(in srgb,var(--g) 10%,var(--c));color:var(--g);font-weight:700;font-size:12.5px;font-family:ui-monospace,Menlo,Consolas,monospace;white-space:nowrap}
.ibst{display:inline-flex;align-items:center;gap:7px;padding:5px 13px;border-radius:20px;border:1px solid var(--l);background:var(--c2);color:var(--m);font-weight:700;font-size:12.5px;cursor:pointer}.ibst i{width:7px;height:7px;border-radius:50%;background:var(--m)}
.ibst.on{border-color:color-mix(in srgb,var(--g) 35%,var(--c));background:color-mix(in srgb,var(--g) 10%,var(--c));color:var(--g)}.ibst.on i{background:var(--g)}
.ibs3{gap:6px}.ibs3 span{font-size:11px}.ibs3 b{font-size:16px}.card.ibsc{padding:10px 14px}
.ibtw{margin-top:10px;border-radius:8px}.ibtab{font-size:12.5px;min-width:520px}
.ibtab th{padding:7px 8px;font-size:10.5px;letter-spacing:.04em}.ibtab td{padding:5px 8px;line-height:1.2}.ibn{white-space:nowrap}
.ibn{font-size:13px}.ibp1,.ibts,.ibu{padding:2px 7px;font-size:11px;border-radius:5px}.ibu{border-radius:10px}
.ibtab .sw{width:32px;height:18px;border-radius:9px;vertical-align:middle}.ibtab .sw i{top:2px;left:2px;width:14px;height:14px}.ibtab .sw.on i{left:16px}
.iba{display:inline-flex;gap:2px;justify-content:flex-end}.iba button{width:24px;height:24px;border:0;border-radius:6px;background:none;color:var(--m);display:inline-flex;align-items:center;justify-content:center;cursor:pointer}
.iba button:hover{background:var(--c2);color:var(--a)}.iba button.dng:hover{color:var(--r)}
.ibtop .btn.pri{padding:6px 12px;font-size:13px;min-height:0}.ibtop input{padding:6px 10px;font-size:13px;min-height:0;height:32px}.card.ibc{padding:12px}@media (max-width:640px){.card.ibc,.card.ibsc{padding:10px}}.ibnote{font-size:11.5px;margin:8px 0 0}
.lnk{border:0;background:none;color:var(--a);font-weight:600;font-size:13.5px;padding:6px 10px;cursor:pointer;border-radius:6px}.lnk:hover{background:var(--c2)}.lnk.dng{color:var(--r)}
.sqg,.sqg.two,.sqg.four{display:flex;flex-wrap:wrap;gap:0;margin:4px 0 12px}
.sq{min-height:0;padding:7px 15px;border-radius:0;border:1px solid var(--l);margin-left:-1px;font-size:13px;font-weight:600;flex:none;display:inline-block}.sq:first-child{border-radius:7px 0 0 7px;margin-left:0}.sq:last-child{border-radius:0 7px 7px 0}
.sq.on{position:relative;z-index:1;border-color:var(--a);background:var(--a);color:#fff}.sq:not(.on):not(:disabled):hover{color:var(--a)}
@media (max-width:640px){.sq{padding:6px 10px;font-size:12.5px}}
</style><style id="acs"></style></head><body>
<div id="lg" hidden><div class="lbg" aria-hidden="true"><i></i><i></i><i></i></div><form class="lcard" id="lf"><div class="lhead"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><p id="ltg">Sign in to the panel</p></div>
<label for="lu">Username</label><div class="fi"><span data-i="user"></span><input id="lu" autocomplete="username" autocapitalize="none" spellcheck="false"></div>
<label for="lp">Password</label><div class="fi"><span data-i="lock"></span><input id="lp" type="password" autocomplete="current-password"><button type="button" class="ib" id="lpe" aria-label="Show password"></button></div>
<div id="lcw" hidden><label for="lc">6-digit code from your authenticator app</label><div class="fi"><span data-i="shield"></span><input id="lc" inputmode="numeric" autocomplete="one-time-code" maxlength="6"></div></div>
<div id="capw" hidden><label for="lcap">Type the letters from the picture</label><div style="display:flex;align-items:center;gap:8px;margin-bottom:8px"><img id="capi" alt="Security check picture" width="200" height="64" style="border-radius:8px;max-width:100%"><button type="button" class="ib" id="capr" aria-label="Show a new picture"></button></div><div class="fi"><span data-i="shield"></span><input id="lcap" autocapitalize="characters" autocomplete="off" spellcheck="false" maxlength="8"></div></div>
<div class="err" id="le" role="alert"></div><button class="btn pri lbtn">Log in</button><p class="lft">Protected panel · ReXUI v2.0</p></form></div>
<div id="app" hidden><aside><div class="brand"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><button class="ib sxb" aria-label="Search" title="Search (/)" style="margin-left:auto"></button><button class="ib thb" id="th" aria-label="Switch theme"></button></div><nav id="nav"></nav><a class="pwr" href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener">Powered by <b>ReXUI</b> v2.0</a></aside>
<main><div id="mt"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><button class="ib sxb" aria-label="Search"></button><button class="ib thb" aria-label="Switch theme"></button><button class="ib" id="lo2" aria-label="Log out"></button></div><div id="cbn"></div><div class="hdr"><span class="chip" id="xs"></span><span class="ver">ReXUI v2.0</span><small class="m" id="upd" style="margin-left:auto"></small></div><div id="pg"></div><a class="pwm" href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener">Powered by ReXUI v2.0</a></main><nav id="bn" aria-label="Main"></nav></div>
<div id="dt" hidden><div class="dts"><div class="dth"><b>User details</b><button class="btn sm" id="dx" aria-label="Close">Close</button></div><div id="dtb"></div></div></div>
<div id="md" hidden><form class="card" id="mf"></form></div>
<div id="sxo" hidden><div class="sxp" role="dialog" aria-label="Search"><div class="fi"><span data-i="search"></span><input id="sxi" placeholder="Search users, settings, tools..." autocomplete="off" spellcheck="false" aria-label="Search"><button type="button" class="btn sm" id="sxx">Esc</button></div><div id="sxr" role="listbox"></div></div></div>
<div id="shm" hidden><div class="card shc" role="dialog" aria-label="Share account"><div class="ct"><b>Share account</b><button class="btn sm" id="shx">Close</button></div><img id="shi" alt="Account card with QR code"><div class="mr"><button type="button" class="btn" id="shc">Copy text</button><button type="button" class="btn" id="shd">Download</button><button type="button" class="btn pri" id="shs">Share</button></div></div></div>
<div id="qrm" hidden><div class="card qrc"><div class="ct"><b id="qrt"></b><button class="btn sm" id="qrx">Close</button></div><div id="qrs"></div><p class="note" id="qrn" style="margin-top:10px;text-align:center">Scan with v2rayNG, NekoBox or Hiddify</p></div></div>
<script src="/qr.js"></script>
<script>
const ls=(k,v)=>{try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v)}catch(e){return null}};
const $=s=>document.querySelector(s),X=s=>String(s??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const P={gauge:'<path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 18l4-6"/>',copy:'<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>',users:'<circle cx="9" cy="8" r="4"/><path d="M2 21c0-4 3-6 7-6s7 2 7 6M17 4a4 4 0 0 1 0 8M22 21c0-3-2-5-5-5.7"/>',user:'<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',gear:'<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>',out:'<path d="M9 4H5v16h4M16 8l4 4-4 4M20 12H9"/>',up:'<path d="M12 19V5M6 11l6-6 6 6"/>',down:'<path d="M12 5v14M6 13l6 6 6-6"/>',cpu:'<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',ram:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18"/>',swap:'<path d="M4 8h16l-4-4M20 16H4l4 4"/>',disk:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M3 14h18M7 6.5h.01"/>',clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',panel:'<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 11h8M8 15h5"/>',globe:'<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',eye:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',eyeoff:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><path d="M3 3l18 18"/>',plus:'<path d="M12 5v14M5 12h14"/>',cal:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',key:'<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3"/>',bolt:'<path d="M13 2L4 14h7l-1 8 9-12h-7z"/>',inb:'<path d="M12 3l9 5-9 5-9-5 9-5z"/><path d="M3 13l9 5 9-5"/>',pen:'<path d="M4 20h4L19 9l-4-4L4 16v4z"/><path d="M13.5 6.5l4 4"/>',qr:'<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><path d="M14 14h3v3h-3zM20 14v.01M14 20h.01M17 17h4v4h-4"/>',wg:'<path d="M3 12h4l3-7 4 14 3-7h4"/>',vpn:'<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/><rect x="9" y="11" width="6" height="5" rx="1"/><path d="M10 11V9.5a2 2 0 0 1 4 0V11"/>',lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',unlock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-2"/>',del:'<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',dev:'<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',cert:'<rect x="3" y="4" width="18" height="13" rx="2"/><circle cx="12" cy="19" r="3"/><path d="M7 9h10M7 12h6"/>',refresh:'<path d="M3 12a9 9 0 0 1 15-6.7L21 8M21 3v5h-5M21 12a9 9 0 0 1-15 6.7L3 16M3 21v-5h5"/>',sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',moon:'<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',net:'<path d="M5 12a7 7 0 0 1 14 0M8.5 12a3.5 3.5 0 0 1 7 0"/><circle cx="12" cy="16" r="1.5"/>',shield:'<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',wifi:'<path d="M2 8.5a15 15 0 0 1 20 0M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1"/>',kick:'<circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/>',save:'<path d="M12 3v12M7 10l5 5 5-5M4 19h16"/>',upl:'<path d="M12 21V9M7 14l5-5 5 5M4 5h16"/>',chart:'<path d="M4 20V11M10 20V5M16 20v-6M21 20H3"/>',search:'<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.6-3.6"/>',file:'<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',list:'<path d="M9 6h12M9 12h12M9 18h12M4 6h.01M4 12h.01M4 18h.01"/>',check:'<path d="M5 12l5 5 9-10"/>',palette:'<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-1-1.5-1-2.5 1-1.5 2-1.5h2a4 4 0 0 0 4-4c0-4.4-4-8-9-8z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10.5" cy="7" r="1"/><circle cx="15" cy="7.5" r="1"/>'};
const I=(k,s=18)=>`<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[k]}</svg>`;
const fb=(b,s='')=>{const u=['B','KB','MB','GB','TB'];let i=0;b=+b||0;while(b>=1024&&i<4){b/=1024;i++}return (i?b.toFixed(2):b.toFixed(0))+' '+u[i]+s};
const dur=s=>{s=Math.floor(s||0);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?`${d}d ${h}h`:h?`${h}h ${m}m`:m?`${m}m`:`${s}s`};
const pct=(a,b)=>b?a/b*100:0,avg=a=>a&&a.length?a.reduce((x,y)=>x+y,0)/a.length:0,peak=a=>a&&a.length?Math.max(...a):0;
const api=async(p,d)=>{const r=await fetch(p,{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify(d||{})});const j=await r.json().catch(()=>({}));if(r.status==401&&p!='api/login'){show(false);throw Error('Please log in again')}if(!r.ok)throw Error(j.e||'Error '+r.status);return j};
function toast(t,e){const o=document.createElement('div');o.className='toast'+(e?' e':'');o.setAttribute('role','status');o.textContent=t;document.body.append(o);setTimeout(()=>o.remove(),e?6000:2200)}
let D=null,pg=(()=>{try{const h=decodeURIComponent(location.hash.slice(1));return /^(ov|ib|st|on|sc|us:(v2ray|ssh|ovpn|hy2|wg|dns))$/.test(h)?h:'ov'}catch(e){return 'ov'}})(),hideIp=true,gid=0,SAC=null,RG=ls('rx-range')||'live',HMD=null,HMT=0;
async function loadHist(){try{const r=await fetch('api/hist',{cache:'no-store'});if(r.ok){HMD=await r.json();HMT=Date.now()}}catch(e){}}const show=v=>{$('#lg').hidden=v;$('#app').hidden=!v};
function theme(t){const de=document.documentElement;if(t=='auto')delete de.dataset.theme;else if(t)de.dataset.theme=t;const dk=de.dataset.theme?de.dataset.theme!='light':matchMedia('(prefers-color-scheme: dark)').matches;document.querySelectorAll('.thb').forEach(b=>{b.innerHTML=I(dk?'sun':'moon',18);b.setAttribute('aria-label',dk?'Switch to light theme':'Switch to dark theme')});return dk}
{let t='light';try{t=localStorage.getItem('rx-theme')||'light'}catch(e){}if(t!='auto')document.documentElement.dataset.theme=t}
document.querySelectorAll('.thb').forEach(b=>b.onclick=()=>{const n=theme()?'light':(ls('rx-dark')||'dark');theme(n);try{localStorage.setItem('rx-theme',n)}catch(e){}if(D&&pg=='ov')ov()});theme();
const AC={blue:['#1f6feb','#4c8dff','Blue'],teal:['#0d9488','#2dd4bf','Teal'],green:['#15803d','#4ade80','Green'],purple:['#7c3aed','#a78bfa','Purple'],pink:['#db2777','#f472b6','Pink'],orange:['#ea580c','#fb923c','Orange'],indigo:['#4f46e5','#818cf8','Indigo']};
function accent(k){const a=AC[k]||AC.teal,d1=':root:not([data-theme=light])',d2=':root[data-theme=dark],:root[data-theme=black]',pt=q=>k=='blue'?'':q.split(',').map(x=>`${x} .pri,${x} .pri:hover`).join(',')+'{color:#0b1020}';
$('#acs').textContent=`:root{--a:${a[0]}}@media(prefers-color-scheme:dark){${d1}{--a:${a[1]}}${pt(d1)}}${d2}{--a:${a[1]}}${pt(d2)}`}
const logoH=b=>!b||b=='ReXUI'?'<span>Re</span><i>X</i><span>UI</span>':`<span>${X(b)}</span>`;
let BR={brand:'',tagline:'',accent:'teal'};
function applyBrand(b){BR={brand:b.brand||'',tagline:b.tagline||'',accent:b.accent||'teal'};const n=BR.brand||'ReXUI';
document.querySelectorAll('.blogo').forEach(e=>{e.innerHTML=logoH(BR.brand);e.setAttribute('aria-label',n)});document.title=n;$('#ltg').textContent=BR.tagline||'Sign in to the panel';accent(BR.accent);ls('rx-brand',JSON.stringify(BR))}
try{const c=JSON.parse(ls('rx-brand')||'null');if(c)applyBrand(c);else accent(BR.accent)}catch(e){accent(BR.accent)}
fetch('api/brand',{cache:'no-store'}).then(r=>r.json()).then(applyBrand).catch(()=>{});
document.querySelectorAll('[data-i]').forEach(e=>e.innerHTML=I(e.dataset.i,17));$('#lo2').innerHTML=I('out',18);
$('#lpe').innerHTML=I('eye',17);$('#lpe').onclick=()=>{const t=$('#lp').type=='password';$('#lp').type=t?'text':'password';$('#lpe').innerHTML=I(t?'eyeoff':'eye',17);$('#lpe').setAttribute('aria-label',t?'Hide password':'Show password')};
const TIPS={};let HOV=null;
function tfmt(t,sec){const d=new Date(t);return d.toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',second:sec?'2-digit':undefined})}
function tipAt(el,fr){const T=TIPS[el.dataset.tip];if(!T)return;const n=Math.max(...T.s.map(x=>x.d.length));if(!n)return;const i=Math.max(0,Math.min(n-1,Math.round(fr*(n-1)))),x=n>1?i/(n-1)*100:0;
const l=el.querySelector('.tl'),b=el.querySelector('.tb');l.hidden=b.hidden=false;l.style.left=x+'%';
b.innerHTML=(T.t&&T.t[i]?`<small>${tfmt(T.t[i],T.sec)}</small>`:'')+T.s.map(z=>`<span><i style="background:${z.c}"></i>${z.n}<b>${z.f(z.d[i]??0)}</b></span>`).join('');
if(x>55){b.style.left='auto';b.style.right=`calc(${100-x}% + 10px)`}else{b.style.right='auto';b.style.left=`calc(${x}% + 10px)`}}
function tipHide(){HOV=null;document.querySelectorAll('.cw .tl,.cw .tb').forEach(e=>e.hidden=true)}
function tipMove(e){const c=e.target.closest&&e.target.closest('.cw');if(!c){if(HOV&&(e.type=='pointerdown'||e.pointerType=='mouse'))tipHide();return}const r=c.getBoundingClientRect();HOV={k:c.dataset.tip,fr:Math.max(0,Math.min(1,(e.clientX-r.left)/r.width))};tipAt(c,HOV.fr)}
document.addEventListener('pointermove',tipMove);document.addEventListener('pointerdown',tipMove);
function tipRestore(){if(!HOV)return;const c=document.querySelector(`.cw[data-tip="${HOV.k}"]`);if(c)tipAt(c,HOV.fr);else HOV=null}
function chart(series,h,o={}){const w=600,all=series.flatMap(s=>s.d),mx=o.max||Math.max(1,...all)*1.15,n=Math.max(1,...series.map(s=>s.d.length-1)),id='g'+(gid++);
const pts=d=>(d.length>1?d:[d[0]||0,d[0]||0]).map((v,i)=>`${(i/n*w).toFixed(1)},${(h-1-v/mx*(h-4)).toFixed(1)}`).join(' ');let out='';
if(o.grid)for(let k=1;k<4;k++)out+=`<line x1="0" x2="${w}" y1="${h*k/4}" y2="${h*k/4}" stroke="var(--l)" stroke-dasharray="4 4" vector-effect="non-scaling-stroke"/>`;
series.forEach((s,j)=>{const p=pts(s.d);if(j==0)out+=`<defs><linearGradient id="${id}" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${s.c}" stop-opacity=".22"/><stop offset="1" stop-color="${s.c}" stop-opacity="0"/></linearGradient></defs><polygon fill="url(#${id})" points="0,${h} ${p} ${w},${h}"/>`;
out+=`<polyline fill="none" stroke="${s.c}" stroke-width="${j?1.6:2}" vector-effect="non-scaling-stroke" points="${p}"/>`});
if(o.avg!=null){const y=(h-1-o.avg/mx*(h-4)).toFixed(1);out+=`<line x1="0" x2="${w}" y1="${y}" y2="${y}" stroke="var(--a)" stroke-dasharray="3 4" stroke-width="1.4" vector-effect="non-scaling-stroke" opacity=".8"/>`}
const svg=`<svg viewBox="0 0 ${w} ${h}" width="100%" height="${h}" preserveAspectRatio="none" aria-hidden="true">${out}</svg>`;
if(!o.tip)return svg;TIPS[o.tip]={s:series,t:o.t,sec:o.sec};return `<div class="cw" data-tip="${o.tip}">${svg}<i class="tl" hidden></i><div class="tb" hidden></div></div>`}
const NAV=[['ov','Overview','gauge'],['ib','Inbounds','inb'],['us:v2ray','V2Ray users','globe'],['us:ssh','SSH users','key'],['us:ovpn','OpenVPN users','vpn'],['us:hy2','UDP users','bolt'],['us:wg','WireGuard users','wg'],['us:dns','DNS users','net'],['on','Online','wifi'],['sc','Security','shield'],['st','Settings','gear'],['lo','Log out','out']],BNAV=[['ov','Overview','gauge'],['us','Users','users'],['on','Online','wifi'],['sc','Security','shield'],['st','Settings','gear']];
$('#nav').innerHTML=NAV.map(n=>`<button class="nb" data-p="${n[0]}" title="${n[1]}">${I(n[2],19)}<span>${n[1]}</span></button>`).join('');
$('#bn').innerHTML=BNAV.map(n=>`<button class="bnb" data-p="${n[0]}" aria-label="${n[1]}"><i>${I(n[2],21)}</i>${n[1]}</button>`).join('');
async function logout(){try{await api('api/logout')}catch(x){}show(false)}
$('#lo2').onclick=()=>{if(confirm('Log out of the panel?'))logout()};
$('#nav').onclick=$('#bn').onclick=e=>{const b=e.target.closest('[data-p]');if(!b)return;if(b.dataset.p=='lo')return logout();go(b.dataset.p)};
function navhl(){const key=pg=='us'?'us:'+UV.kind:pg;document.querySelectorAll('.nb').forEach(b=>b.classList.toggle('on',b.dataset.p==key));document.querySelectorAll('.bnb').forEach(b=>b.classList.toggle('on',b.dataset.p==pg))}
function go(p){const p0=p;if(p.startsWith('us:')){if(UV.kind!=p.slice(3))UV.sel=null;UV.kind=p.slice(3);ls('rx-kind',UV.kind);p='us'}pg=p;HOV=null;accent(BR.accent);if(p!='us'){UV.sel=null;selbar()}navhl();$('#pg').innerHTML='';render(true);window.scrollTo(0,0);hpush({p:p0})}
let HNAV=false,HFIRST=true;
function hpush(st){if(HNAV)return;try{const u='#'+encodeURIComponent(st.p||'ov');if(HFIRST){history.replaceState(st,'',u);HFIRST=false}else if(JSON.stringify(history.state)!=JSON.stringify(st))history.pushState(st,'',u)}catch(e){}}
function spush(){hpush({p:'st',t:ls('rx-stab')||'general',g:GSEL||null})}
window.addEventListener('popstate',e=>{const st=e.state;if(!st||!st.p)return;HNAV=true;try{if(!$('#md').hidden)$('#md').hidden=true;if(!$('#dt').hidden&&$('#dx'))$('#dx').click();const q=$('#qrm');if(q&&!q.hidden)q.hidden=true;
const cur=pg=='us'?'us:'+UV.kind:pg;if(cur!=st.p)go(st.p);if(st.p=='st'&&window.STAB){GSEL=st.g||null;STAB(st.t||'general');window.scrollTo(0,0)}}finally{HNAV=false}});
async function load(){try{const r=await fetch('api/state'+(D&&D.uh&&D.users?'?uh='+D.uh:''),{cache:'no-store'});if(r.status==401)return show(false);{const n=await r.json();if(!n.users&&D&&D.users)n.users=D.users;D=n}const sb=D.set;if(sb.brand!=BR.brand||sb.tagline!=BR.tagline||sb.accent!=SAC){SAC=sb.accent;applyBrand(sb)}
if(pg=='ov'&&RG!='live'&&Date.now()-HMT>60000)await loadHist();if($('#app').hidden){show(true);go(pg)}else render();hdr();$('#upd').textContent='Live · '+new Date().toLocaleTimeString()}catch(e){$('#upd').textContent='Connection lost, retrying...'}}
function hdr(){const c=D.cert,ru=D.rxup||{};$('#cbn').innerHTML=(ru.new?`<div class="banner i" role="status">${I('refresh',17)}<div><b>ReXUI v${X(ru.latest)} is available.</b> You have v${X(ru.cur)}. Update on the server: run <code>menu</code> → 1 (Update) → 1. Users and settings are kept. <a href="https://github.com/chaliraza777/ReXUI/releases" target="_blank" rel="noopener">What's new</a></div></div>`:'')+(c.days!=null&&c.days<=30?`<div class="banner ${c.days<0?'e':'w'}" role="status">${I('cert',17)}<div><b>${c.days<0?'Your SSL certificate has expired.':'Your SSL certificate expires in '+c.days+' day'+(c.days==1?'':'s')+'.'}</b> ${X(c.name)} · Renew it, then paste the new one in Settings or use menu → 7 (SSL Certificate) on the server.</div></div>`:'');
const x=D.svc.find(s=>s.unit=='xray'),on=x&&x.st=='RUNNING';$('#xs').innerHTML=`<span class="dot" style="background:${on?'var(--g)':'var(--r)'}"></span>Xray · ${on?'Running':'Stopped'} <span class="m">v${X(D.xray.ver||'?')}</span>`}
function render(first){if(!D)return;if(pg=='ov'){ov();tipRestore()}else if(pg=='us')us(first);else if(pg=='on')onl();else if(pg=='sc')secp(first);else if(pg=='ib')ibp(first);else if(first)st();else stb()}
const SC={RUNNING:'var(--g)',IDLE:'var(--a)',FAILED:'var(--r)','NOT INSTALLED':'var(--m)'};
function gauge(lab,ic,val,sub,h){const v=Math.max(0,Math.min(100,val)),r=27,C=2*Math.PI*r,col=v>=90?'var(--r)':v>=70?'var(--y)':'var(--a)';
return `<div class="card gc"><div class="gt"><svg class="ring" viewBox="0 0 64 64" width="64" height="64" aria-hidden="true"><circle cx="32" cy="32" r="${r}" fill="none" stroke="var(--c2)" stroke-width="7"/><circle cx="32" cy="32" r="${r}" fill="none" stroke="${col}" stroke-width="7" stroke-linecap="round" stroke-dasharray="${(C*v/100).toFixed(1)} ${C.toFixed(1)}" transform="rotate(-90 32 32)"/><text x="32" y="36.5" text-anchor="middle" font-size="14" font-weight="700" fill="var(--t)">${v.toFixed(0)}%</text></svg>
<div class="gi"><div class="lab">${I(ic,14)}${lab}</div><div class="sub">${sub}</div><div class="ap"><span>Avg ${avg(h).toFixed(0)}%</span><span>Peak ${peak(h).toFixed(0)}%</span></div></div></div><div class="spk">${chart([{d:h,c:col}],38,{max:Math.max(5,peak(h)*1.6)})}</div></div>`}
function kpi(lab,val,sub,col,go,f,ic){return `<button class="card kp" ${go?`data-go="${go}"`:''} ${f?`data-f="${f}"`:''}><span class="ki" style="color:${col};background:color-mix(in srgb,${col} 13%,transparent)">${I(ic,17)}</span><span class="kt"><small>${lab}</small><b>${val}</b>${sub?`<em>${sub}</em>`:''}</span></button>`}
function stat(lab,ic,val,sub,h){return `<div class="card"><div class="lab">${I(ic,15)}${lab}</div><div class="big">${val.toFixed(1)}<i>%</i></div><div class="sub">${sub}</div><div class="ap"><span>Avg ${avg(h).toFixed(1)}%</span><span>Peak ${peak(h).toFixed(0)}%</span></div><div class="spk">${chart([{d:h,c:'var(--a)'}],62,{max:Math.max(5,peak(h)*1.6),avg:avg(h)})}</div></div>`}
let TU='today',PRR='today',TRM='days';
const seg2=(k,cur,opts)=>`<div class="seg" role="group">${opts.map(o=>`<button type="button" data-${k}="${o[0]}" class="${cur==o[0]?'on':''}" aria-pressed="${cur==o[0]}">${o[1]}</button>`).join('')}</div>`;
function statsCards(st){if(!st)return '';const L=TU=='today'?st.today:st.month,mx=Math.max(1,...L.map(x=>x[1]));
const top=`<div class="card"><div class="sh"><div class="lab">${I('users',15)}Top users</div>${seg2('tu',TU,[['today','Today'],['month','This month']])}</div><div style="margin-top:8px">${L.length?L.map((x,i)=>`<button class="rk" data-open="${X(x[0])}"><span class="m" style="width:14px">${i+1}</span>${av(x[0])}<span class="nm"><b>${X(x[0])}</b><span class="ubar"><i style="width:${(x[1]/mx*100).toFixed(1)}%;background:var(--a)"></i></span></span><em>${fb(x[1])}</em></button>`).join(''):`<p class="note" style="margin-top:12px">No user traffic ${TU=='today'?'today':'this month'} yet.</p>`}</div></div>`;
const P=PRR=='today'?st.ptoday:st.p30,pl=Object.entries(P).map(([k,v])=>[k,v[0]+v[1],v]).sort((a,b)=>b[1]-a[1]),pt=pl.reduce((a,x)=>a+x[1],0)||1;
const pro=`<div class="card"><div class="sh"><div class="lab">${I('net',15)}Protocol usage</div>${seg2('pr',PRR,[['today','Today'],['d30','30 days']])}</div><div style="margin-top:8px">${pl.length?pl.map(x=>`<div class="rk" title="Upload ${fb(x[2][0])} · Download ${fb(x[2][1])}"><span class="nm"><b>${X(x[0])}</b><span class="ubar"><i style="width:${(x[1]/pt*100).toFixed(1)}%;background:var(--a)"></i></span></span><em>${fb(x[1])}</em><span class="m" style="width:44px;text-align:right">${(x[1]/pt*100).toFixed(0)}%</span></div>`).join(''):'<p class="note" style="margin-top:12px">No traffic recorded yet. Usage per protocol starts counting after this update.</p>'}</div></div>`;
const T=TRM=='days'?st.days:st.months,tm=Math.max(1,...T.map(x=>x[1]+x[2])),cur=st.months[st.months.length-1],td=st.days[st.days.length-1];
const trf=`<div class="card mb"><div class="sh"><div><div class="lab">${I('cal',15)}Server traffic</div><div class="sub" style="margin-top:4px">Everything the server received and sent</div></div>${seg2('trm',TRM,[['days','30 days'],['months','12 months']])}</div>
<div class="now" style="margin-top:10px"><span>Today<b>${fb(td[1]+td[2])}</b></span><span>This month<b>${fb(cur[1]+cur[2])}</b></span><span>${TRM=='days'?'30 days':'12 months'}<b>${fb(T.reduce((a,x)=>a+x[1]+x[2],0))}</b></span></div>
<div class="uch" role="img" aria-label="Server traffic chart">${T.map(x=>`<i title="${x[0]}: received ${fb(x[1])} · sent ${fb(x[2])}"><b style="height:${(x[2]/tm*100).toFixed(1)}%"></b><u style="height:${(x[1]/tm*100).toFixed(1)}%"></u></i>`).join('')}</div>
<div class="uax"><span>${TRM=='days'?T[0][0].slice(5):T[0][0]}</span><span><b style="color:var(--a)">■</b> Sent <b style="color:var(--l2)">■</b> Received</span><span>${TRM=='days'?'Today':'This month'}</span></div></div>`;
return `<div class="g2">${top}${pro}</div>${trf}`}
const RGN={live:'Last 5 minutes',h1:'Last hour',h24:'Last 24 hours'};
function rdata(){const h=D.hist,now=Date.now();if(RG=='live'||!HMD||!HMD.t||!HMD.t.length){const n=h.tx.length;return Object.assign({},h,{t:h.tx.map((_,i)=>now-(n-1-i)*5000),sec:1,live:1})}
const cut=RG=='h1'?now/1000-3600:0,ix=HMD.t.map((t,i)=>t>cut?i:-1).filter(i=>i>=0),K=['cpu','ram','rx','tx','tcp','udp'],o={t:ix.map(i=>HMD.t[i]*1000)};K.forEach(k=>o[k]=ix.map(i=>HMD[k][i]));
const b=Math.ceil(o.t.length/240);if(b>1){const z={};Object.keys(o).forEach(k=>{z[k]=[];for(let i=0;i<o[k].length;i+=b){const sl=o[k].slice(i,i+b);z[k].push(k=='t'?sl[0]:avg(sl))}});return z}return o}
const segR=()=>`<div class="seg" role="group" aria-label="Time range">${[['live','Live'],['h1','1H'],['h24','24H']].map(x=>`<button type="button" data-rg="${x[0]}" class="${RG==x[0]?'on':''}" aria-pressed="${RG==x[0]}">${x[1]}</button>`).join('')}</div>`;
function ov(){gid=0;const d=D,i=d.info,h=d.hist,R=rdata(),fs=v=>fb(v,'/s'),fp=v=>(+v).toFixed(1)+'%',fn=v=>Math.round(v),ax=R.t.length?`<div class="uax"><span>${tfmt(R.t[0])}</span><span>${RGN[RG]}${!R.live||RG=='live'?'':' (collecting…)'}</span><span>${R.live?'Now':tfmt(R.t[R.t.length-1])}</span></div>`:'',run=d.svc.filter(x=>x.st=='RUNNING').length,inst=d.svc.filter(x=>x.st!='NOT INSTALLED').length;
const on=d.users.filter(u=>u.st=='online').length,ended=d.users.filter(u=>['expired','limit'].includes(u.st)).length,soon=d.users.filter(expiring).length;
const pk=Math.max(peak(R.tx),peak(R.rx)),ip=v=>`<div class="ipv ${hideIp?'blur':''}">${X(v||'-')}</div>`;
const down=d.svc.filter(x=>x.st!='RUNNING'&&x.st!='NOT INSTALLED'),hr=new Date().getHours(),gr=hr<5?'Good night':hr<12?'Good morning':hr<17?'Good afternoon':'Good evening',st=d.stats,td=st?st.days[st.days.length-1]:[0,0,0],mo=st?st.months[st.months.length-1]:[0,0,0],act=d.users.filter(u=>['active','online'].includes(u.st)).length;
$('#pg').innerHTML=`<div class="card hero"><div class="hl"><small class="m">${gr}, ${X(d.me||'admin')}</small><h2><span class="hdot" style="background:${down.length?'var(--r)':'var(--g)'}"></span>${down.length?down.length+' service'+(down.length>1?'s':'')+' stopped':'Everything is running'}</h2>
<p class="m">${down.length?X(down.map(x=>x.name).join(', '))+' · tap a service below to restart it':`${run} services online · Xray v${X(d.xray.ver||'?')} · up ${dur(i.uptime)}`}</p></div>
<div class="hb"><button class="btn pri" id="add">${I('plus',15)}Add user</button><button class="btn bl" id="cdnb">${I('globe',15)}CDN Settings</button><button class="btn" data-r="xray">${I('refresh',15)}Restart Xray</button></div></div>
<div class="kps">${kpi('Online now',on,'of '+d.users.length+' users','var(--g)','us','on','wifi')}${kpi('Active',act,'V2Ray '+d.users.filter(u=>HX(u.kind)).length+' · SSH '+d.users.filter(u=>HS(u.kind)).length+(d.ov||d.users.some(u=>u.kind=='ovpn')?' · OVPN '+d.users.filter(u=>u.kind=='ovpn').length:'')+(d.hy||d.users.some(u=>u.kind=='hy2')?' · UDP '+d.users.filter(u=>u.kind=='hy2').length:'')+(d.wg||d.users.some(u=>u.kind=='wg')?' · WG '+d.users.filter(u=>u.kind=='wg').length:'')+(d.users.some(u=>u.kind=='dns')?' · DNS '+d.users.filter(u=>u.kind=='dns').length:''),  'var(--a)','us','all','users')}${kpi('Expiring soon',soon,soon?'renew them':'all good','var(--y)','us','soon','cal')}${kpi('Traffic today',fb(td[1]+td[2]),'↑ '+fb(td[2])+' ↓ '+fb(td[1]),'#8b5cf6','','','up')}${kpi('This month',fb(mo[1]+mo[2]),new Date().toLocaleString([],{month:'long'}),'#0d9488','','','chart')}</div>
<div class="g4">${gauge('CPU','cpu',d.cpu,`${i.cores} core${i.cores>1?'s':''}`,h.cpu)}${gauge('RAM','ram',pct(d.ram[0],d.ram[1]),`${fb(d.ram[0])} / ${fb(d.ram[1])}`,h.ram)}
${gauge('Swap','swap',d.swap[1]?pct(d.swap[0],d.swap[1]):0,d.swap[1]?`${fb(d.swap[0])} / ${fb(d.swap[1])}`:'No swap',h.swap)}${gauge('Disk','disk',pct(d.disk[0],d.disk[1]),`${fb(d.disk[1]-d.disk[0])} free`,h.disk)}</div>
<div class="card mb"><div class="sh"><div><div class="lab">Overall speed</div><div class="sub" style="margin-top:4px">Interface total · peak ${fs(pk)}</div></div>${segR()}</div>
<div class="now" style="margin-top:10px"><span class="bl">${I('up',14)}Upload<b>${fs(d.tx)}</b></span><span>${I('down',14)}Download<b>${fs(d.rx)}</b></span></div>
<div class="ch">${chart([{d:R.tx,c:'var(--a)',n:'Upload',f:fs},{d:R.rx,c:'var(--l2)',n:'Download',f:fs}],190,{grid:1,avg:(avg(R.tx)+avg(R.rx))/2,tip:'spd',t:R.t,sec:R.sec})}</div>${ax}
<div class="tri"><div><small>Sent</small><b>${fb(d.txt)}</b></div><div><small>Received</small><b>${fb(d.rxt)}</b></div><div><small>Average</small><b>↑ ${fs(avg(R.tx))} ↓ ${fs(avg(R.rx))}</b></div></div></div>
<div class="g2"><div class="card"><div class="sh"><div class="lab">${I('cpu',15)}CPU and RAM</div><span class="m" style="font-size:12.5px">${RGN[RG]}</span></div><div style="margin-top:8px"><span class="big" style="font-size:30px">${d.cpu.toFixed(0)}<i>% CPU</i></span> <span class="m">· ${pct(d.ram[0],d.ram[1]).toFixed(0)}% RAM</span></div>
<div class="leg"><span><i style="background:var(--a)"></i>CPU avg <b>${avg(R.cpu).toFixed(1)}%</b></span><span><i style="background:var(--l2)"></i>RAM avg <b>${avg(R.ram).toFixed(1)}%</b></span></div>
<div class="ch">${chart([{d:R.cpu,c:'var(--a)',n:'CPU',f:fp},{d:R.ram,c:'var(--l2)',n:'RAM',f:fp}],150,{grid:1,max:100,tip:'sys',t:R.t,sec:R.sec})}</div>${ax}</div>
<div class="card"><div class="sh"><div class="lab">${I('net',15)}Connection stats</div><span class="m" style="font-size:12.5px">${RGN[RG]}</span></div><div style="margin-top:8px"><span class="big" style="font-size:30px">${d.tcp+d.udp}</span> <span class="m">open sockets</span></div>
<div class="leg"><span><i style="background:var(--a)"></i>TCP <b>${d.tcp}</b></span><span><i style="background:var(--l2)"></i>UDP <b>${d.udp}</b></span></div>
<div class="ch">${chart([{d:R.tcp,c:'var(--a)',n:'TCP',f:fn},{d:R.udp,c:'var(--l2)',n:'UDP',f:fn}],150,{grid:1,avg:avg(R.tcp),tip:'con',t:R.t,sec:R.sec})}</div>${ax}</div></div>
${statsCards(d.stats)}
<div class="g2"><div class="card"><div class="kv2"><div><div class="lab">${I('clock',15)}Uptime</div><div class="pair" style="margin-top:10px"><div><small>Xray</small><b>${dur(d.xray.up)}</b></div><div><small>OS</small><b>${dur(i.uptime)}</b></div></div></div>
<div><div class="lab">${I('panel',15)}Panel</div><div class="pair" style="margin-top:10px"><div><small>RAM</small><b>${fb(d.proc.ram)}</b></div><div><small>Threads</small><b>${d.proc.threads}</b></div></div></div></div>
<div class="ips"><div class="lab">${I('globe',15)}IP addresses</div><button class="ib" id="eye" aria-label="${hideIp?'Show IP addresses':'Hide IP addresses'}">${I(hideIp?'eyeoff':'eye',17)}</button></div>${ip(d.ip.v4)}${ip(d.ip.v6||'No IPv6')}
<div class="kv" style="margin-top:12px"><span>Host</span><b>${X(i.host)} · ${X(i.os)}</b></div><div class="kv"><span>Kernel</span><b>${X(i.kernel)}</b></div><div class="kv"><span>Virtualization</span><b>${X(i.virt)}</b></div></div>
<div class="card"><div class="ct"><div class="lab">${I('cert',15)}Certificate</div><button class="btn sm" data-go="st">Change</button></div>
<div class="kv"><span>Type</span><b>${X(d.cert.src)}</b></div><div class="kv"><span>Name</span><b>${X(d.cert.name||'-')}</b></div><div class="kv"><span>Expires</span><b>${X(d.cert.exp||'-')}${d.cert.days!=null?' ('+d.cert.days+' days)':''}</b></div>
<div class="ct" style="margin-top:18px"><div class="lab">${I('users',15)}Users</div><button class="btn sm" data-go="us">Manage</button></div><div class="kv"><span>Total</span><b>${d.users.length}</b></div><div class="kv"><span>Ended or disabled</span><b>${ended+d.users.filter(u=>u.st=='disabled').length}</b></div></div></div>
<div class="card"><div class="ct"><div class="lab">${I('net',15)}Services</div><span class="m">${run} running / ${inst} installed</span></div><div class="svcg">
${d.svc.map(s=>`<button class="sv" data-u="${X(s.unit)}" data-n="${X(s.name)}" ${s.st=='NOT INSTALLED'?'disabled':''} aria-label="${X(s.name)} ${s.st}, tap to restart"><span class="dot" style="background:${SC[s.st]}"></span><span style="min-width:0"><b>${X(s.name)}</b><small>${s.port?'Port '+s.port:'&nbsp;'}</small></span><em style="color:${SC[s.st]}">${s.st}</em></button>`).join('')}</div></div>`}
async function restartUnit(u,n){if(!confirm('Restart '+n+'?'))return;try{await api('api/svc',{unit:u});toast(n+' restarted');load()}catch(x){toast(x.message,1)}}
$('#pg').onclick=e=>{if(e.target.closest('#more')){UV.lim=(UV.lim||100)+100;return us()}if(UV.sel){const o=e.target.closest('#ul [data-open]');if(o){const n=o.dataset.open;UV.sel.has(n)?UV.sel.delete(n):UV.sel.add(n);return us()}}
if(e.target.closest('#sel')){UV.sel=UV.sel?null:new Set();return us(true)}
const g=e.target.closest('[data-go]');if(g){if(g.dataset.f)UV.f=g.dataset.f;return go(g.dataset.go)}
const fl=e.target.closest('[data-f]');if(fl){UV.f=fl.dataset.f;return us()}
if(e.target.closest('#trl'))return pg=='us'?trial():kpick(k=>trial(k));
if(e.target.closest('#cdnb'))return jump('cdn','cdnf');if(e.target.closest('#ibj'))return go('ib');if(e.target.closest('#dnsj'))return jump('dns','dnsf');if(e.target.closest('#pgj'))return jump('pay','payf');
const kt=e.target.closest('[data-kind]');if(kt){UV.kind=kt.dataset.kind;ls('rx-kind',UV.kind);UV.sel=null;selbar();navhl();return us(true)}
if(e.target.closest('#eye')){hideIp=!hideIp;return ov()}
const t1=e.target.closest('[data-tu]');if(t1){TU=t1.dataset.tu;return ov()}const t2=e.target.closest('[data-pr]');if(t2){PRR=t2.dataset.pr;return ov()}const t3=e.target.closest('[data-trm]');if(t3){TRM=t3.dataset.trm;return ov()}
const sk=e.target.closest('[data-sk]');if(sk){api('api/session-kill',{id:sk.dataset.sk}).then(()=>{toast('Session logged out');secp(true)}).catch(x=>toast(x.message,1));return}
if(e.target.closest('#lgall')){if(!confirm('Log out every other device? You stay logged in here.'))return;api('api/session-kill',{all:1}).then(()=>{toast('Other devices logged out');secp(true)}).catch(x=>toast(x.message,1));return}
const rg=e.target.closest('[data-rg]');if(rg){RG=rg.dataset.rg;ls('rx-range',RG);HOV=null;if(RG!='live'&&Date.now()-HMT>60000)loadHist().then(ov);return ov()}
const ue=e.target.closest('[data-uedit]');if(ue){e.stopPropagation();api('api/user/detail',{name:ue.dataset.uedit}).then(u=>umodal(u,null,null,true)).catch(x=>toast(x.message,1));return}
const uq=e.target.closest('[data-uqr]');if(uq){e.stopPropagation();return uqr(uq.dataset.uqr)}
const ut=e.target.closest('[data-utg]');if(ut){e.stopPropagation();const n=ut.dataset.utg,on=ut.classList.contains('on');ut.disabled=true;api('api/user/toggle',{name:n}).then(()=>{toast(n+(on?' disabled':' enabled'));load()}).catch(x=>{ut.disabled=false;toast(x.message,1)});return}
const vw=e.target.closest('.seg[aria-label="View"] [data-v]');if(vw){UV.v=vw.dataset.v;ls('rx-view3',UV.v);return us(true)}
const so=e.target.closest('[data-sort]');if(so){const k=so.dataset.sort;UV.rev=UV.k==k?!UV.rev:false;UV.k=k;ls('rx-sort',k);return us(true)}
const r=e.target.closest('[data-r]');if(r)return restartUnit(r.dataset.r,r.textContent.replace('Restart ','').trim());
const s=e.target.closest('.sv');if(s&&!s.disabled)return restartUnit(s.dataset.u,s.dataset.n);
if(e.target.closest('#add'))return pg=='us'?umodal():kpick(k=>umodal(null,null,k));
if(e.target.closest('#blk'))return bulkm();
const c=e.target.closest('[data-open]');if(c)return openU(c.dataset.open);
const k=e.target.closest('[data-kick]');if(k){const n=k.dataset.kick;if(!confirm('Disconnect '+n+' from all devices now?'))return;api('api/user/kick',{name:n}).then(()=>{toast(n+' disconnected');load()}).catch(x=>toast(x.message,1));return}
if(e.target.closest('#bk')){location.href='api/backup';return}
if(e.target.closest('#rsb'))return $('#rsf').click()};
const STC={online:'var(--g)',active:'var(--a)',expired:'var(--r)',limit:'var(--r)',disabled:'var(--y)'},STN={online:'online',active:'active',expired:'expired',limit:'limit reached',disabled:'disabled'};
const ubar=(used,lim)=>{const p=lim?Math.min(100,used/(lim*1073741824)*100):0;return `<div class="ubar"><i style="width:${p}%;background:${p>90?'var(--r)':p>75?'var(--y)':'var(--a)'}"></i></div>`};
const lims=(used,lim)=>`${fb(used)} / ${lim?lim+' GB':'Unlimited'}`,hue=n=>[...n].reduce((a,c)=>a*31+c.charCodeAt(0),7)%360;
const SR={online:0,active:1,limit:2,expired:3,disabled:4},ek=u=>u.exp=='never'?9e15:Date.parse(u.exp);
const SO={name:['Name',(a,b)=>a.name.localeCompare(b.name)],used:['Most used',(a,b)=>b.used-a.used],exp:['Expires first',(a,b)=>ek(a)-ek(b)],new:['Newest',(a,b)=>(b.created||'').localeCompare(a.created||'')||a.name.localeCompare(b.name)],st:['Status',(a,b)=>SR[a.st]-SR[b.st]||a.name.localeCompare(b.name)],onl:['Online first',(a,b)=>(b.on>0)-(a.on>0)||((b.spd||[0,0])[1]+(b.spd||[0,0])[0])-((a.spd||[0,0])[1]+(a.spd||[0,0])[0])||a.name.localeCompare(b.name)],spd:['Fastest now',(a,b)=>((b.spd||[0,0])[1]+(b.spd||[0,0])[0])-((a.spd||[0,0])[1]+(a.spd||[0,0])[0])||a.name.localeCompare(b.name)]};
const fsp=b=>{const u=['B','KB','MB','GB'];let i=0;b=+b||0;while(b>=1024&&i<3){b/=1024;i++}return (i&&b<10?b.toFixed(1):b.toFixed(0))+' '+u[i]+'/s'},uon=u=>u.on>0&&u.st!='disabled',avd=u=>`<span class="avw">${av(u.name)}<i class="udot ${uon(u)?'on':'off'}" aria-hidden="true"></i></span>`,useen=u=>uon(u)?'<span class="useen on">Online</span>':`<span class="useen">${u.seen?'Seen '+tago(u.seen):'Never connected'}</span>`,uspd=u=>{const p=u.spd||[0,0],on=uon(u);return `<div class="uspd${on&&(p[0]||p[1])?'':' idle'}">${on?`<span class="d">↓ ${fsp(p[1])}</span><span class="u">↑ ${fsp(p[0])}</span>`:''}<span class="td">Today ${fb(u.today||0)}</span></div>`};
const UV={kind:['v2ray','ssh','ovpn','hy2','wg','dns'].includes(ls('rx-kind'))?ls('rx-kind'):'v2ray',v:ls('rx-view3')||'table',k:SO[ls('rx-sort')]?ls('rx-sort'):'name',rev:false,f:'all'};
const dnum=u=>u.exp=='never'?1e9:Math.ceil((Date.parse(u.exp+'T23:59:59')-Date.now())/864e5);
const dleft=u=>{if(u.fdays)return 'starts on first use';if(u.expts){const h=Math.ceil((u.expts*1000-Date.now())/36e5);return h<=0?'ended':h+'h left'}if(u.exp=='never')return '';const d=dnum(u);return d<0?'ended':d==0?'today':d+'d left'};
const expTxt=u=>u.fdays?`First use + ${u.fdays} day${u.fdays==1?'':'s'}`:u.exp=='never'?'No expiry':u.exp;
const expiring=u=>!u.trial&&['active','online'].includes(u.st)&&(dnum(u)<=3||(u.lim>0&&u.used>=u.lim*1073741824*.9));
const FL={all:['All',u=>1],on:['Online',u=>u.st=='online'],soon:['Expiring soon',expiring],end:['Ended',u=>['expired','limit'].includes(u.st)],off:['Disabled',u=>u.st=='disabled'],trial:['Trial',u=>u.trial]};
const tagT=u=>(u.trial?'<span class="tag">Trial</span>':'')+(u.kind=='both'?'<span class="tag" style="background:color-mix(in srgb,#0d9488 14%,transparent);color:#0d9488">V2Ray + SSH</span>':'');
const av=(n,s)=>`<div class="av" style="background:hsl(${hue(n)} 55% 52%)">${X(n[0]).toUpperCase()}</div>`;
function selbar(){let b=$('#sbar');if(!UV.sel||pg!='us'){if(b)b.remove();return}if(!b){b=document.createElement('div');b.id='sbar';b.setAttribute('role','toolbar');b.setAttribute('aria-label','Selected users');document.body.append(b);b.onclick=selact}
const n=UV.sel.size,all=UV.L&&UV.L.length&&UV.L.every(x=>UV.sel.has(x));b.innerHTML=`<b>${n} selected</b><button type="button" class="btn sm" data-sa="all">${all?'Clear':'Select all'}</button><span class="sbs"></span>
${[['days','cal','Add days'],['dev','dev','Device limit'],['reset','refresh','Reset usage'],['disable','lock','Disable'],['enable','unlock','Enable'],['delete','del','Delete']].map(x=>`<button type="button" class="btn sm${x[0]=='delete'?' dng':''}" data-sa="${x[0]}"${n?'':' disabled'}>${I(x[1],14)}${x[2]}</button>`).join('')}<button type="button" class="ib" data-sa="x" aria-label="Stop selecting">${I('plus',18)}</button>`}
async function selact(e){const b=e.target.closest('[data-sa]');if(!b)return;const a=b.dataset.sa,names=[...UV.sel],N=names.length+' user'+(names.length==1?'':'s');
if(a=='x'){UV.sel=null;selbar();return us(true)}if(a=='all'){const all=UV.L.every(x=>UV.sel.has(x));UV.L.forEach(x=>all?UV.sel.delete(x):UV.sel.add(x));return us()}
const done=async(o,msg)=>{try{const r=await api('api/bulk',Object.assign({names},o));toast(msg.replace('#',r.count));if(a=='delete')UV.sel.clear();await load()}catch(x){toast(x.message,1)}};
if(a=='days')return modal('Add days to '+N,[['days','Days to add','number','',30]],d=>api('api/bulk',{names,action:'days',days:d.days}).then(r=>{toast('Added '+d.days+' days to '+r.count+' user(s)');load()}),'Users without expiry are skipped.');
if(a=='dev')return modal('Device limit for '+N,[['dev','Device limit (2 recommended, 0 = unlimited)','number','',2]],d=>api('api/bulk',{names,action:'dev',dev:d.dev}).then(r=>{toast('Device limit set to '+d.dev+' for '+r.count+' user(s)');load()}));
if(a=='disable')return modal('Disable '+N,[['reason','Reason (optional, shown on their page)','text','Payment pending']],d=>api('api/bulk',{names,action:'disable',reason:d.reason}).then(r=>{toast(r.count+' user(s) disabled');load()}));
if(a=='reset'){if(confirm('Reset data usage of '+N+'?'))done({action:'reset'},'Usage reset for # user(s)');return}
if(a=='enable')return done({action:'enable'},'# user(s) enabled');
if(a=='delete'){if(confirm('Delete '+N+'? This cannot be undone.\n\n'+names.slice(0,20).join(', ')+(names.length>20?' ...':'')))done({action:'delete'},'# user(s) deleted');return}}
function us(first){if(first){$('#pg').innerHTML=`<div class="khd"><div class="kts" id="kts" role="tablist" aria-label="User type"></div></div><div id="dnsb"></div><div class="bar uacts"><button class="btn pri" id="add">${I('plus',16)}Add ${KN[UV.kind]} user</button><button class="btn" id="trl" title="1 day, 2 GB, deleted when it ends">${I('clock',16)}Trial</button>${UV.kind=='v2ray'||UV.kind=='both'?`<button class="btn bl" id="ibj">${I('inb',16)}Inbounds</button>`:''}${UV.kind=='ssh'?`<button class="btn bl" id="pgj">${I('file',16)}Payload generator</button>`:''}${UV.kind=='dns'?`<button class="btn bl" id="dnsj">${I('net',16)}DNS setup</button>`:''}<button class="btn" id="blk">${I('users',16)}Bulk / CSV</button><button class="btn${UV.sel?' pri':''}" id="sel" aria-pressed="${!!UV.sel}">${I('check',16)}${UV.sel?'Done':'Select'}</button></div><div class="bar"><input id="q" placeholder="Search users or notes" aria-label="Search users" value="${X(UV.q||'')}"><select id="srt" aria-label="Sort users">${Object.entries(SO).map(([k,v])=>`<option value="${k}"${k==UV.k?' selected':''}>Sort: ${v[0]}</option>`).join('')}</select>
<div class="seg" role="group" aria-label="View">${[['cards','grid','Card view'],['table','list','Table view']].map(x=>`<button type="button" data-v="${x[0]}" class="${UV.v==x[0]?'on':''}" aria-pressed="${UV.v==x[0]}" aria-label="${x[2]}" title="${x[2]}">${I(x[1],16)}</button>`).join('')}</div>
</div><div class="chips" id="flt" role="group" aria-label="Filter users"></div><div id="ul"></div><div id="ulm" class="ulm"></div>`;
$('#q').oninput=()=>{UV.q=$('#q').value;UV.lim=100;us()};$('#srt').onchange=()=>{UV.k=$('#srt').value;UV.rev=false;ls('rx-sort',UV.k);us(true)}}
const KU=D.users.filter(u=>inK(u,UV.kind));if($('#dnsb'))$('#dnsb').innerHTML=UV.kind=='dns'?DNSH():'';
$('#kts').innerHTML=[['v2ray','globe','V2Ray users'],['ssh','key','SSH users'],['ovpn','vpn','OpenVPN users'],['hy2','bolt','UDP users'],['wg','wg','WireGuard users'],['dns','net','DNS users']].map(x=>`<button type="button" role="tab" data-kind="${x[0]}" class="${UV.kind==x[0]?'on':''}" aria-selected="${UV.kind==x[0]}">${I(x[1],16)}${x[2]} <b>${D.users.filter(u=>inK(u,x[0])).length}</b></button>`).join('');
if(!FL[UV.f])UV.f='all';$('#flt').innerHTML=Object.entries(FL).map(([k,v])=>{const c=KU.filter(v[1]).length;return k!='all'&&k!='trial'||c||k=='all'?`<button type="button" data-f="${k}" class="${UV.f==k?'on':''}" aria-pressed="${UV.f==k}">${v[0]} <b>${c}</b></button>`:''}).join('');
const q=(UV.q||'').toLowerCase(),L=KU.filter(FL[UV.f][1]).filter(u=>u.name.toLowerCase().includes(q)||(u.note||'').toLowerCase().includes(q)).sort(SO[UV.k][1]);if(UV.rev)L.reverse();
UV.L=L.map(u=>u.name);const LT=L.length,LP=L.slice(0,UV.lim||100);$('#ulm').innerHTML=LT>LP.length?`<button type="button" class="btn" id="more">Show more · ${LT-LP.length} left</button>`:'';if(UV.sel){const all=new Set(D.users.map(u=>u.name));UV.sel.forEach(n=>{if(!all.has(n))UV.sel.delete(n)})}selbar();
const el=$('#ul');el.classList.toggle('pick',!!UV.sel);if(!L.length){el.className='';el.innerHTML=`<div class="empty card">${KU.length?(UV.f!='all'?'No users in "'+FL[UV.f][0]+'"':'No user matches your search'):'No users yet. Tap "Add user" to create one.'}</div>`;return}
if(UV.v=='table'){el.className='card tw';const th=(k,t)=>k?`<th scope="col"><button type="button" data-sort="${k}" class="${UV.k==k?'on':''}">${t}${UV.k==k?I(UV.rev?'up':'down',12):''}</button></th>`:`<th scope="col"><button type="button" tabindex="-1" style="cursor:default">${t}</button></th>`;
const ck=u=>UV.sel?`<span class="sck${UV.sel.has(u.name)?' on':''}" aria-hidden="true">${I('check',13)}</span>`:'';
el.innerHTML=`<table class="ut"><thead><tr>${th('name','User')}${th('used','Bandwidth')}${th('exp','Expiry')}${th('','Devices')}${th('','On')}</tr></thead><tbody>${LP.map(u=>{const n=X(u.name),dl=dleft(u);return `<tr data-open="${n}" class="${UV.sel&&UV.sel.has(u.name)?'sel':''}" tabindex="0" aria-label="Open ${n}">
<td><div class="tu">${ck(u)}<span class="uact"><button type="button" class="uab" data-uedit="${n}" title="Edit" aria-label="Edit ${n}">${I('pen',15)}</button>${HX(u.kind)?`<button type="button" class="uab" data-uqr="${n}" title="QR and configs" aria-label="QR and configs of ${n}">${I('qr',15)}</button>`:'<span class="uab0"></span>'}</span>${avd(u)}<div style="min-width:0"><b>${n}</b>${useen(u)}${tagT(u)}${u.note?`<small>${X(u.note)}</small>`:''}</div></div></td>
<td>${lims(u.used,u.lim)}${u.lim?ubar(u.used,u.lim):''}${uspd(u)}</td><td class="${u.st=='ended'||(dl&&dnum(u)<=1&&u.exp!='never')?'exr':expiring(u)?'exw':''}">${u.exp=='never'&&!u.fdays?'<span class="m">No expiry</span>':X(u.fdays?'First use + '+u.fdays+'d':u.exp)+(dl&&!u.fdays?`<small style="display:block">${dl}</small>`:'')}</td>
<td><span class="udev${uon(u)?' on':''}">${u.on} / ${u.dev||'∞'}</span></td><td><button type="button" class="sw${u.st=='disabled'?'':' on'}" data-utg="${n}" role="switch" aria-checked="${u.st!='disabled'}" aria-label="${n} ${u.st=='disabled'?'disabled':'enabled'}" title="${u.st=='disabled'?'Enable':'Disable'}"><i></i></button></td></tr>`}).join('')}</tbody></table>`;return}
el.className='ul'+(UV.sel?' pick':'');el.innerHTML=LP.map(u=>{const n=X(u.name),on=UV.sel&&UV.sel.has(u.name);return `<button class="card uc${on?' sel':''}" data-open="${n}" aria-label="${UV.sel?(on?'Unselect ':'Select ')+n:'Open '+n}"${UV.sel?` aria-pressed="${!!on}"`:''}><div class="uh">${UV.sel?`<span class="sck${on?' on':''}" aria-hidden="true">${I('check',13)}</span>`:''}${avd(u)}<div style="min-width:0"><b>${n}</b>${tagT(u)}<small class="m" style="display:block">${lims(u.used,u.lim)}</small></div><span class="pill" style="color:${STC[u.st]}">${STN[u.st]}</span></div>
${u.note?`<small class="m" style="display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${X(u.note)}</small>`:''}${ubar(u.used,u.lim)}<div class="um"><span${expiring(u)?' style="color:var(--y)"':''}>${I('cal',14)}${X(expTxt(u))}${dleft(u)&&!u.fdays?' · '+dleft(u):''}</span><span>${I('dev',14)}${u.on} / ${u.dev||'∞'} devices</span>${u.rday?`<span>${I('refresh',14)}Resets day ${u.rday}</span>`:''}<span style="margin-left:auto" class="bl">Details ›</span></div></button>`}).join('')}
const uaS=ua=>{ua=ua||'';const b=/Edg\//.test(ua)?'Edge':/OPR|Opera/.test(ua)?'Opera':/SamsungBrowser/.test(ua)?'Samsung Internet':/Firefox\//.test(ua)?'Firefox':/Chrome\//.test(ua)?'Chrome':/Safari\//.test(ua)?'Safari':/curl/i.test(ua)?'curl':ua?'Browser':'Unknown';
const o=/Android/.test(ua)?'Android':/iPhone|iPad|iOS/.test(ua)?'iPhone / iPad':/Windows/.test(ua)?'Windows':/Mac OS X/.test(ua)?'Mac':/Linux/.test(ua)?'Linux':'';return o?b+' on '+o:b};
const tago=t=>{const s=Date.now()/1000-t;return s<60?'just now':s<3600?Math.floor(s/60)+'m ago':s<86400?Math.floor(s/3600)+'h ago':Math.floor(s/86400)+'d ago'};
const tfull=t=>new Date(t*1000).toLocaleString([],{month:'short',day:'numeric',hour:'2-digit',minute:'2-digit'});
let LG=null,LGT=0;
async function secp(first){if(!first&&Date.now()-LGT<10000)return;try{LG=await api('api/logs');LGT=Date.now()}catch(x){if(!LG)return toast(x.message,1)}if(pg!='sc'||!LG)return;
const ok=r=>r=='OK',S=LG.sessions,L=LG.logins,A=LG.activity;
$('#pg').innerHTML=`<div class="card mb"><div class="ct"><div class="lab">${I('dev',15)}Logged-in devices</div>${S.length>1?`<button class="btn sm dng" id="lgall">${I("out",14)}Log out others</button>`:''}</div>
<p class="note">Sessions last 12 hours. Changing the panel password logs out everyone.</p>${S.map(x=>`<div class="rk"><span class="dotc" style="background:var(--g);margin:0"></span><span class="nm"><b>${X(uaS(x.ua))}${x.me?' <span class="tag">This device</span>':''}</b><small class="m">${X(x.ip)} · logged in ${tago(x.t)}</small></span>${x.me?'':`<button class="btn sm" data-sk="${X(x.id)}">Log out</button>`}</div>`).join('')}</div>
<div class="g2"><div class="card"><div class="ct"><div class="lab">${I('key',15)}Login history</div><span class="m" style="font-size:12.5px">last ${L.length}</span></div><div class="lst">${L.length?L.map(x=>`<div class="li"><span class="dotc" style="background:${ok(x.res)?'var(--g)':'var(--r)'}"></span><span class="tx"><b>${ok(x.res)?'Logged in':X(x.res)}</b> · ${X(x.user||'-')}<small>${X(x.ip)} · ${X(uaS(x.ua))}</small></span><span class="dt" title="${tfull(x.t)}">${tago(x.t)}</span></div>`).join(''):'<p class="note">No logins recorded yet.</p>'}</div></div>
<div class="card"><div class="ct"><div class="lab">${I('panel',15)}Activity log</div><span class="m" style="font-size:12.5px">last ${A.length}</span></div><div class="lst">${A.length?A.map(x=>`<div class="li"><span class="tx">${X(x.a)}<small>${X(x.ip)}</small></span><span class="dt" title="${tfull(x.t)}">${tago(x.t)}</span></div>`).join(''):'<p class="note">Changes you make in the panel are listed here.</p>'}</div></div></div>`}
const WORLD='M670 157l3 1l2 -1l1 -1l2 -1l1 -1l1 -2l2 -1l2 0l2 0l2 1l3 -1l2 -1l2 0l2 -3l1 1l0 4l2 1l2 -1l2 -1l1 0l3 0l-1 1l-1 1l-3 0l-3 1l-2 1l1 2l-1 3l-1 2l-3 0l1 2l-1 1l-2 2l1 2l-3 0l-2 1l-2 1l-2 2l0 2l-3 2l-2 -1l-2 1l-3 0l-5 -2l3 -2l-1 -3l-2 0l0 -2l-1 -3l1 -2l0 -2l1 -4zM545 291l1 3l1 2l2 2l1 0l3 0l1 -3l2 0l1 1l3 0l0 2l1 3l0 2l1 1l0 4l1 0l2 -1l2 2l0 3l0 2l-6 0l0 10l2 3l1 2l-5 1l-6 0l-2 -2l-12 0l-2 -1l-3 1l-2 -2l1 -3l1 -3l1 -4l2 -3l1 -2l0 -2l-1 -3l-1 -2l0 -2l1 -2l-1 -3l-1 -2l-1 -2l1 -2l2 0l8 0zM535 291l-2 -3l1 -1l2 1l-1 1zM557 137l0 2l1 2l-1 1l-1 2l-2 -2l0 -4l0 -3l1 -1l1 1l1 2zM643 194l3 0l2 0l4 -2l2 -2l2 -2l1 3l-2 2l-1 3l-1 1l0 2l-9 -1l-1 -4zM318 451l-3 0l-1 -1l-5 0l0 -7l1 1l2 3l3 1l4 1l-1 2zM320 344l1 2l1 -3l3 0l6 6l2 1l4 2l3 2l-3 6l3 1l3 0l2 0l3 -3l0 -3l3 2l0 2l-2 2l-2 1l-3 4l-4 4l-1 3l-1 3l1 3l-1 3l3 4l0 3l1 1l-2 6l-5 2l-5 0l-3 0l0 2l0 2l0 2l-1 1l-3 0l-3 -1l0 4l1 1l2 -1l1 2l-3 1l-2 2l0 3l-1 2l-3 0l-2 2l-1 2l3 2l3 1l-1 3l-4 2l-1 4l-3 1l-1 1l1 4l2 2l-4 -1l-7 0l-1 -2l0 -3l-2 0l-1 -1l0 -3l2 -2l1 -2l1 -4l1 -4l0 -2l1 -2l-1 -2l-1 -1l0 -4l0 -5l1 -3l1 -3l1 -1l-1 -3l0 -3l3 -2l-1 -3l2 -3l0 -3l-2 -6l2 -4l0 -3l1 -3l1 -3l2 -2l-1 -1l1 -6l3 -2l1 -3l2 -4l4 1zM621 139l4 -1l2 2l0 2l1 2l1 3l-2 -2l-2 -2l-2 0l-2 -1l0 -3zM691 430l2 1l3 0l-1 2l-4 0l0 -3zM904 404l3 1l3 -1l2 4l-1 1l0 3l-3 1l-2 0l-2 -3l0 -2l-2 -3l2 -1zM899 317l1 2l2 -1l0 1l2 2l0 4l1 1l1 4l1 4l3 1l2 2l1 1l2 3l1 3l2 1l1 3l2 2l1 1l3 3l0 3l0 3l2 3l-1 3l-1 4l0 5l-2 3l-2 1l-1 3l-1 1l0 3l-1 2l-1 2l0 2l-2 2l-3 1l-3 1l-1 1l-2 2l-2 -2l-2 0l1 -2l-2 0l-2 3l-2 -1l-2 -1l-4 -1l-2 -2l-1 -2l0 -2l-2 -1l-2 -1l1 -1l-1 -3l-1 3l-3 0l2 -1l0 -2l1 -2l0 -2l-2 2l-2 2l-1 2l-2 -1l-2 -4l-2 -1l-3 -3l-2 0l-2 -2l-5 0l-4 2l-3 1l-3 -1l-3 2l-2 1l0 2l-2 1l-2 0l-2 0l-2 0l-2 0l-2 0l-2 2l-2 1l-1 1l-2 0l-5 -2l-1 -1l1 -2l0 -2l1 -3l-1 -1l-1 -4l-1 -2l-1 -4l-1 -2l0 -2l-2 -3l0 -3l1 1l1 1l-1 -4l-1 -2l0 -2l1 -2l0 -2l1 -2l0 2l1 -2l3 -1l1 -2l2 -1l2 0l2 -1l2 0l1 -1l5 -1l1 -2l1 -1l2 -2l0 -3l2 -3l1 3l0 -2l1 -2l1 -1l2 -2l2 -2l1 -1l3 -1l2 1l2 2l3 1l-1 -2l2 -3l1 -1l1 -2l2 -1l3 -1l-2 -2l3 0l2 1l2 1l3 1l1 -1l2 0l1 1l0 2l-1 1l-1 2l-1 1l-1 2l3 2l2 2l1 1l2 2l2 0l3 2l2 -1l1 -1l1 -4l1 -2l-1 -3l0 -2l0 -2l1 -3l1 -2l1 -2l1 1l0 2l1 2l1 2l0 2zM547 116l-2 2l0 2l-3 1l-1 1l-3 -1l-4 0l-3 -1l-2 0l-3 0l1 -2l2 1l3 -1l2 0l2 0l0 -2l2 -2l2 1l1 -2l4 1l2 1zM625 143l2 1l1 3l-2 -1l-1 -1zM632 139l1 -1l2 -1l1 1l2 3l2 1l-2 0l-1 2l-1 2l-1 2l-2 -2l1 -1l-2 -1l-3 3l0 -3l-2 -1l-1 -2l-1 -3l3 1l2 0l-2 -2l4 2zM581 287l0 -4l0 -2l2 -1l2 1l0 2l-1 2l-1 2zM509 106l2 0l3 -1l2 2l1 1l0 2l-1 2l-3 -2l-3 -1l-1 -1l-2 -2l2 0zM507 252l-2 0l-1 -2l1 -7l-1 -3l-1 -1l-1 -3l2 -1l2 -2l2 -1l2 2l1 3l-1 3l-1 2l-1 3l0 2l-1 5zM492 241l-2 -1l-2 1l-2 -2l-1 -2l1 -2l2 -4l0 -2l2 0l2 -2l2 -1l3 -2l2 0l2 1l2 4l3 2l0 2l-2 2l-2 1l-2 0l-2 1l-6 0l0 4zM757 201l0 2l0 2l-1 -2l-1 -3l-1 -2l-3 0l0 3l-3 0l-1 -3l-1 -2l0 -2l-1 -1l2 -3l-2 -1l1 -3l2 2l2 2l2 1l3 0l2 0l-2 3l-2 2l2 2l0 -2l2 5zM563 129l1 1l3 0l4 1l1 -1l4 -1l2 1l-1 4l1 2l-3 0l-2 1l-3 2l-2 -2l-2 1l-2 0l0 -2l-2 -1l1 -2l1 -1l-1 -1l0 -2zM285 195l-2 -2l0 -3l2 3zM286 186l0 2l-1 -2l-1 -1l2 1zM553 127l1 2l-1 2l-1 1l0 2l-3 -1l-1 -2l-2 -2l-2 -2l1 -1l2 0l3 0l3 1zM565 97l3 0l3 -1l1 -2l2 -1l1 -2l3 -1l3 1l2 0l3 1l-1 3l2 2l1 1l2 0l-3 2l1 3l-2 1l-1 2l-4 0l-3 -1l-2 0l-3 -1l-3 0l-2 0l-1 1l-2 -1l-1 -2l2 -1l-1 -2zM252 214l2 -2l1 2l0 1l0 4l-1 1l-2 1l0 -4l0 -3zM325 343l-3 0l-1 3l-1 -2l-4 -1l-2 3l-2 0l-1 -4l-2 -4l1 -3l-2 -1l0 -3l-1 -2l1 -3l-1 -3l0 -2l1 -2l1 -3l0 -2l-2 -6l2 0l2 -1l2 -1l2 -2l4 0l-1 2l0 4l3 2l3 1l2 1l1 1l2 1l3 1l1 3l-1 1l1 4l5 0l0 2l2 2l0 2l0 3l-1 1l0 2l-3 -2l-3 0l-5 1l-1 3l-1 5zM340 370l4 -4l3 -4l2 -1l2 -2l0 -2l-1 -2l-1 -1l0 -2l-1 -3l-2 1l0 -4l-3 -2l-4 0l0 -5l-1 -2l1 -2l1 -1l0 -3l0 -2l-2 -1l0 -3l-5 0l-1 -4l1 -1l-1 -3l-2 -1l-3 -1l-1 -1l-2 -1l-3 -1l-3 -2l1 -3l0 -3l-4 0l-2 2l-2 1l-2 1l-2 0l-2 0l-1 -5l-2 2l-3 0l-1 -2l-1 0l-1 -4l-2 -3l1 -1l2 -1l0 -2l1 -3l3 -2l2 -1l3 0l1 -9l0 -3l-2 -1l1 -3l1 0l-1 -1l0 -2l5 0l1 -1l2 2l2 2l2 0l3 -2l1 -2l2 -1l-3 -1l0 -2l0 -2l-1 -1l3 0l2 1l3 -1l3 -2l1 -1l1 -1l0 2l2 2l-2 4l1 2l2 3l2 -1l2 0l2 -1l2 0l1 -2l2 0l2 1l2 -1l1 1l2 -1l1 -2l2 -3l1 1l2 6l1 0l0 3l-2 2l6 2l0 3l2 -2l4 1l4 2l2 2l-1 2l3 -1l6 2l4 -1l4 3l4 4l2 1l2 0l1 1l1 4l1 2l-2 5l-1 2l-4 5l-2 4l-2 2l-1 3l0 6l-1 5l0 2l-1 1l0 5l-3 4l-1 3l-2 2l-1 2l-3 0l-4 1l-2 1l-3 1l-3 3l-3 3l0 2l0 2l0 3l-1 2l-2 2l-3 5l-2 3l-2 2l-1 3l-2 2l-1 -2l1 -2l-1 -2l-3 -2l-2 -2l-4 -2l-2 0zM817 257l1 -1l3 -2l-1 4l-2 1l-1 -2zM755 182l1 1l0 2l-3 0l-2 0l-2 1l-2 -2l2 -3l1 -1l2 1l3 1zM571 332l2 3l3 3l1 2l1 2l2 0l2 2l-4 2l-3 2l-1 3l0 1l-2 2l-2 1l-3 0l-1 -1l-3 1l0 1l-2 1l-1 2l-2 0l0 -3l-2 -3l-1 -10l3 0l0 -12l2 0l4 -1l1 1l2 -1l3 -1l1 3zM542 248l3 0l5 -1l1 -2l2 -1l3 -1l2 -2l2 -3l2 -1l2 -1l1 3l0 3l1 2l2 1l2 2l2 3l1 1l1 2l2 1l-3 1l-2 0l-1 1l-2 0l-3 1l-3 2l-2 -1l-2 0l-2 -1l-2 -1l-1 1l-1 2l-1 2l-3 -1l-2 2l-2 3l0 -3l-1 -1l-1 -1l-2 -3l0 -3l0 -2l2 -4zM323 121l2 1l3 0l-2 1l-4 -1l0 -2l1 1zM328 113l-5 -1l-2 -1l4 0l3 1zM157 115l-6 -1l-3 -2l-4 -2l-1 -2l3 0l2 1l3 0l1 1l1 2l3 1l1 2zM344 108l-2 3l2 -1l2 0l-1 1l2 1l2 0l2 1l0 2l2 -1l0 2l1 2l-1 3l-3 -1l0 -2l-4 2l-2 -2l-3 0l-6 0l2 -2l-2 -1l3 -2l3 -5l1 -2l3 -1l-1 3zM131 97l3 0l-1 3l3 3l-3 -1l-1 -2l-2 -1l0 -2zM273 69l-4 2l-2 0l2 -3l4 0zM263 59l2 1l2 1l3 1l3 1l3 2l1 1l-2 1l-4 -1l-2 -2l-3 2l-4 2l-1 -2l-3 0l2 -1l0 -3l1 -3l2 0zM289 55l-3 0l-1 -2l2 -2l2 0l2 1l0 2l-2 1zM234 48l-1 1l-4 -1l-2 1l-4 -2l2 -1l2 -1l3 1l2 0l2 2zM248 47l0 3l4 -2l4 2l-1 2l2 2l3 -2l2 -3l0 -3l4 0l4 0l4 2l-2 3l2 2l-6 4l-3 0l-3 0l-1 1l-3 3l-1 1l-3 2l-4 1l-2 1l0 2l-3 1l-4 2l-3 4l-1 2l0 4l4 1l1 3l2 2l4 0l5 1l2 1l2 2l4 1l3 1l4 0l3 0l0 3l1 4l2 3l4 3l2 -1l2 -3l-2 -5l-2 -2l5 -1l3 -3l1 -2l0 -2l-2 -3l-3 -2l3 -4l-1 -3l-1 -5l2 -1l5 1l3 1l2 -1l2 1l4 2l1 1l5 0l0 3l1 4l2 1l2 2l4 -2l3 -4l2 -1l2 3l3 4l3 4l-1 2l4 1l3 2l4 1l2 1l1 3l2 0l1 2l0 3l-2 1l-2 2l-4 1l-4 2l-4 1l-6 -1l-5 0l-2 0l-3 3l-3 1l-4 4l-4 3l3 0l4 -4l6 -3l4 0l3 1l-3 2l1 4l1 2l4 2l4 -1l3 -3l0 2l2 1l-4 2l-6 2l-2 2l-4 2l-2 0l0 -3l5 -3l-4 0l-3 1l-2 -2l0 -4l-2 -1l-1 0l-3 2l-1 2l-1 2l-2 1l-6 0l-4 0l-4 3l-1 2l-3 0l-3 0l0 2l-4 2l-3 0l-3 2l-2 0l1 -2l1 -2l1 -2l-1 -3l0 -3l-3 -1l-2 -2l-1 -1l-1 -1l-2 -1l-2 -1l-3 -1l-2 -1l-3 1l-4 -1l-3 0l-2 -1l-3 0l-2 -1l-1 -2l-1 1l-6 0l-10 0l-9 0l-8 0l-9 0l-8 0l-8 0l-3 0l-8 0l-8 0l-6 -3l-2 -1l-5 -2l-2 -2l1 -2l-4 -2l0 -2l-4 -3l2 -3l0 -2l-5 -2l-3 -4l-1 -2l-3 -2l-2 -1l-1 -2l-3 1l-3 2l-2 -2l-2 -1l-3 -1l-3 0l0 -19l0 -12l6 1l4 2l3 0l2 -1l4 -1l4 0l4 -1l4 -1l2 1l2 -1l1 -1l2 0l5 3l3 -2l1 2l3 0l5 -1l4 1l6 2l4 0l3 0l4 2l-4 1l5 1l7 -1l3 0l3 2l3 -2l-3 -1l2 -1l3 0l2 -1l2 1l3 2l3 0l5 1l4 -1l5 1l-1 -2l3 -1l4 1l0 3l2 -2l2 0l1 -4l-3 -2l-3 -1l0 -4l4 -2l3 1l3 1l4 4l-3 1l5 1zM183 35l-2 2l7 -1l4 1l3 -1l2 1l2 3l2 -1l-2 -4l2 0l3 0l3 2l2 3l1 2l4 2l5 1l-4 2l1 1l-1 1l-5 0l-4 -1l-4 0l-5 1l-7 1l-5 0l-1 -1l-4 -1l-3 0l-3 -3l2 0l4 0l4 0l4 -1l-6 -1l-6 1l-4 0l-1 -2l6 -1l-4 0l-5 -1l3 -2l2 -1l7 -2l3 0zM210 34l-3 2l-4 -2l5 0l2 0zM288 35l-3 1l-3 0l-3 0l-4 -1l2 -2l6 1l5 1zM260 35l2 2l2 -2l7 -2l5 4l0 2l5 -1l3 -2l6 2l4 2l5 0l3 2l7 2l2 1l3 3l-5 1l6 3l5 0l4 3l4 1l-1 2l-5 4l-3 -2l-4 -3l-4 0l0 2l3 2l3 2l2 1l1 3l-1 2l-3 -1l-7 -2l4 2l3 2l-7 0l-6 -2l-4 -1l-3 -3l-4 -1l-8 1l-2 -1l2 -2l5 -1l6 0l-1 -1l1 -2l3 -3l-1 -1l-1 -1l-4 -2l-6 -1l2 -1l-3 -2l-2 0l-2 -1l-2 1l-5 0l-10 -1l-6 0l-4 -1l-3 -1l3 -2l-4 0l-1 -3l3 -3l2 -1l8 -1l-2 2zM221 33l4 1l5 -1l-2 3l4 1l-1 3l-4 1l-3 0l-2 -1l-7 -3l6 0l-3 -3l3 -1zM241 36l-3 3l-3 0l-2 -3l2 -3l2 -1l6 0l6 1l-5 3l-3 0zM165 41l-7 1l-1 -1l-7 -2l1 -1l2 -2l3 -3l-3 -2l9 0l4 1l7 0l3 1l3 1l-3 1l-7 2l-4 2zM240 29l-2 1l-4 0l-3 -1l2 -1l4 -1l2 1l1 1zM226 24l3 1l-2 4l-4 0l-3 0l-5 -2l0 -2l3 0l4 -1l4 0zM199 25l2 1l2 0l3 0l0 2l-1 1l-10 1l-7 1l-4 0l5 -2l-12 0l-4 -1l4 -3l2 -1l8 1l5 2l5 1l-4 -3l3 -2l2 1l1 1zM237 22l3 1l6 0l2 1l2 2l2 1l4 0l4 1l4 -1l6 0l5 0l3 1l-1 2l-5 1l-3 0l-8 0l-6 0l-4 0l-8 -1l-1 -2l-3 -3l-6 -1l-3 -1l1 -1l6 0zM177 21l0 2l-2 1l-3 0l-5 2l-4 0l-4 0l4 -3l6 -2l4 0l4 0zM239 21l-6 0l5 -1l2 1zM194 20l-5 1l-4 -1l2 -1l4 0l4 0zM195 17l-3 1l-5 0l3 -1l5 0zM234 19l-4 1l-3 -1l-1 -1l4 -1l5 1zM222 18l1 2l-4 -1l-5 -1l-6 0l3 -1l-4 -1l5 0l8 1l2 1zM258 14l4 1l-4 1l-5 3l-5 0l-6 -1l-3 -1l2 -2l-5 0l-3 -1l-2 -2l2 -1l2 -1l3 0l5 -1l4 2l5 0l4 1l2 2zM310 3l7 0l6 1l5 0l-7 3l-6 0l-3 1l6 0l-6 2l-5 1l-5 3l-5 0l-2 1l-9 0l4 1l-2 0l3 2l-3 1l-4 1l-2 1l-4 1l6 1l-8 2l-7 -1l-8 1l-4 0l-6 -1l5 -2l-1 -2l9 1l-4 -2l-4 -1l2 -1l5 -1l-3 -2l-1 -2l7 0l2 1l5 -2l-7 0l-9 0l-5 -1l-3 -1l-3 -1l4 -2l3 0l5 0l4 -2l4 1l3 0l2 -1l4 -1l5 0l8 0l10 -1l6 1l6 0zM527 118l1 2l1 2l-3 0l-2 1l-2 1l-3 -1l-1 -1l-1 -1l2 -2l2 -1l2 0l4 0zM309 443l0 7l3 0l1 1l-2 1l-3 0l-2 -1l-3 -1l-4 -1l-3 -2l-3 -4l2 1l4 2l3 1l2 -1l1 -2l2 -2l2 1zM311 342l1 4l2 0l-1 4l-3 2l0 5l0 2l-2 2l-1 3l-1 3l0 3l-2 4l1 5l1 4l-2 3l1 3l-3 2l0 3l1 3l-1 1l-1 3l-1 3l1 4l-1 5l1 1l0 1l1 2l-1 3l-1 4l-1 3l-1 3l-2 2l0 3l1 1l2 0l0 3l1 2l7 0l3 1l-3 0l-1 0l-3 1l0 4l-5 -1l-3 -3l-3 -2l-1 -2l1 -2l-2 -2l0 -5l1 -3l3 -3l-4 -1l3 -3l0 -5l4 1l1 -7l-2 0l-1 4l-1 -1l0 -4l1 -6l2 -3l-1 -3l0 -4l2 -5l2 -5l2 -5l-1 -5l1 -2l-1 -4l2 -4l1 -7l0 -6l1 -8l0 -5l0 -4l1 -1l1 -2l1 2l0 3l2 1l-1 3l2 4zM806 212l-2 1l-2 -1l0 -3l1 -1l3 -1l2 1l-1 2l-1 2zM855 111l4 1l4 2l1 3l4 0l2 -1l5 -1l-1 3l-1 1l-1 4l-2 3l-4 -1l-2 1l1 3l-1 4l-1 2l-2 -2l-1 2l-4 1l0 2l-2 0l-2 -1l-1 2l-4 2l-2 2l-4 1l-2 1l-3 1l2 -1l1 -4l-1 -2l-3 2l-3 2l-1 2l-3 0l-2 2l2 2l2 0l3 3l3 -3l2 2l2 1l-4 1l-1 2l-3 2l-1 2l3 2l1 3l2 3l2 2l0 3l-2 1l1 1l1 1l0 3l-1 3l-4 3l-2 5l-2 4l-4 3l-4 2l-3 1l-2 1l-1 -1l-1 2l-4 1l-3 1l-1 3l-2 -2l-4 -2l-4 -1l-1 -1l0 -2l-2 0l-1 -2l-3 2l-2 1l-3 0l-1 0l-1 5l-2 -1l-2 -1l-3 -2l0 -2l-1 -1l-1 -3l-3 1l0 -4l3 -3l0 -3l0 -2l-2 -3l-5 0l1 -1l-1 -2l-2 1l-2 -1l-4 2l-2 3l-2 0l-2 -1l-3 -1l-1 1l-2 3l-1 -3l-1 1l-3 -1l-4 0l-2 -2l-2 0l-1 -2l-2 0l-2 -2l-3 -1l-5 -2l-2 -2l-1 -4l2 1l-1 -3l0 -3l-3 -4l-4 -1l-1 -3l-2 -1l-1 -3l-2 -2l-1 -3l3 -3l2 0l3 0l1 -2l3 0l1 -2l5 -1l0 -3l2 -1l-3 -5l6 -2l1 0l2 -6l6 1l1 -2l0 -3l3 0l2 -2l1 2l3 1l4 2l2 2l-1 4l1 1l3 1l4 0l3 2l2 1l1 3l2 2l3 0l5 0l4 0l3 0l4 2l3 0l2 1l3 -1l4 -2l4 0l4 -1l2 -2l2 -1l-2 -2l2 -2l4 1l3 -2l4 -1l2 -2l2 -1l4 -1l2 1l-2 -4l-2 -1l-2 2l-3 -1l-2 -1l2 -3l1 -2l3 1l4 -2l3 -5l1 -1l-1 -3l2 -1l4 -1l3 0l4 1l3 1l2 3l1 2l1 2l1 3zM492 256l-3 -1l-5 1l-2 1l-3 1l0 -3l-1 -3l-2 -1l1 -1l0 -3l0 -1l1 -2l0 -2l-1 -3l4 0l2 -1l1 1l2 0l2 2l2 -1l2 1l1 4l-1 3l-1 4l1 3zM536 265l-2 0l-1 0l-6 0l0 -3l-1 -2l-2 -2l0 -1l0 -3l2 -3l2 -2l3 2l2 -2l1 -2l0 -2l1 -1l1 -2l1 -3l1 -2l2 -2l0 -2l-1 -1l1 -2l1 3l1 2l-1 2l2 3l-2 0l-2 1l1 2l2 2l1 2l-2 4l-1 3l0 3l2 1l1 3l1 1l0 3l-2 1l-2 -1l-4 0zM586 261l-1 4l0 2l-1 2l-1 1l0 3l-1 3l-1 3l0 2l0 2l0 4l1 3l0 3l2 2l1 4l-4 0l-2 3l1 1l-1 4l0 3l3 2l0 3l-2 0l-1 -2l-1 -1l-2 -1l-1 -1l-1 1l-2 -1l-1 -1l-2 0l-2 -1l-2 -1l-2 1l-1 0l0 -4l-1 -1l0 -2l0 -2l-1 -3l-3 0l-1 -1l-2 0l-1 2l-2 1l-2 0l-2 -1l-1 -3l-1 -3l-8 0l-2 0l-1 0l1 -2l1 -1l2 -1l1 1l3 -2l2 -1l0 -4l2 -3l1 -2l2 -1l0 -3l0 -3l1 -3l0 -2l1 -1l0 -2l1 -2l1 -2l1 -1l2 1l2 1l2 0l2 1l1 -2l5 -1l2 0l1 -1l2 0l3 0l2 3l2 0l3 -1l0 2l3 2zM536 288l-1 -2l-2 2l-2 -3l2 -2l-1 -2l3 -1l4 0l1 -1l0 -3l0 -2l-2 -2l2 -4l-3 0l-1 -2l4 -1l2 1l2 1l2 -5l2 -2l1 1l2 2l-1 1l0 2l-1 3l0 3l0 3l-2 1l-1 2l-2 3l0 3l-2 2l-1 2l-2 -1l-2 1zM291 273l-3 -2l-3 0l-1 -2l-3 -1l0 -3l3 -2l1 -2l1 -1l-1 -3l0 -3l0 -4l-1 -1l1 -2l0 -3l2 0l2 -2l1 -2l0 -2l2 -2l2 -1l2 1l2 -2l3 -2l1 1l-2 2l-1 1l-1 1l-1 1l0 3l-1 1l2 2l1 2l0 2l1 1l4 0l1 1l2 2l3 0l3 0l-1 2l0 4l0 2l1 1l-1 2l1 2l1 3l-1 -1l-7 0l0 2l2 1l-2 0l-1 3l2 1l0 2l-1 10l-2 -2l1 -3l-2 -2l-2 0l-2 1l-2 0l-2 -4l-1 -1l-1 -1l-2 -2zM270 245l-2 0l0 -2l-2 -2l-1 -1l-1 1l-2 -1l0 -2l0 -2l2 1l2 0l2 1l1 2l2 1l-1 2l0 2zM271 197l3 0l2 0l3 1l1 2l2 -1l4 3l1 1l3 1l2 1l2 1l-2 2l-2 0l-2 -1l-4 1l2 -2l-3 -1l-2 -3l-4 -1l-4 -1l-3 -1l-2 1l-1 1l-3 0l1 -1l2 -2l2 0l2 -1zM591 158l3 0l2 -1l-2 1l-2 0zM594 159l-2 1l-2 -2l2 0l2 0zM547 115l-2 -1l-3 -1l-2 2l-2 -1l-2 -2l-1 0l-1 -3l2 0l3 -2l3 0l1 1l2 0l1 1l3 0l2 1l1 2l-2 1l-1 1l-2 1zM528 94l2 2l3 1l2 -1l3 1l1 1l1 2l0 2l1 1l1 4l-2 0l-3 1l-3 1l1 3l1 0l2 2l-1 1l-1 3l-2 0l-2 0l-3 0l-2 0l-3 -1l-3 1l0 -2l1 -3l-4 0l-1 -1l0 -2l0 -2l0 -4l2 -1l1 -3l2 -2l2 -1l0 -3l2 0l2 0zM620 231l0 2l-1 1l1 1l-1 2l-3 -1l0 -2l1 -1l1 -2l2 0zM535 92l-1 3l-3 -2l3 -3l1 2zM530 89l-1 1l-2 2l1 2l-2 0l-2 0l-1 -2l-1 -3l2 -2l2 0l3 -2l-1 3l2 1zM301 208l2 0l2 1l1 1l2 1l2 1l-1 1l-1 -1l-2 0l-2 1l-2 2l-1 -1l-1 -2l1 -2l0 -2zM533 196l-9 6l-8 7l-4 1l-3 0l0 -2l-3 -1l-1 -2l-9 -7l-10 -7l-10 -8l0 -4l4 -3l3 0l2 -1l2 -2l3 -1l0 -2l3 -2l3 0l0 -2l-1 -4l0 -2l-1 -2l3 -2l3 0l1 -1l3 -1l5 -1l4 0l4 -1l3 0l3 0l0 2l0 3l0 3l-2 2l0 2l2 2l2 2l1 6l1 3l0 4l0 3l0 2l-1 2l2 2l1 3l3 1l1 2zM277 283l1 -2l0 -2l-1 2l-2 -2l0 -3l2 -3l1 -2l1 -2l2 -1l3 1l1 2l2 0l2 1l2 3l-1 2l-3 4l-3 1l-2 3l0 2l-2 1l-1 -1l-2 -1l0 -2zM597 177l-1 1l0 2l-1 2l-2 0l-1 -2l-2 -5l1 4l2 3l2 5l1 2l1 2l2 4l0 2l3 3l-11 1l-10 0l-12 0l0 -12l0 -12l0 -2l0 -2l1 -3l4 0l2 1l3 1l3 -1l2 -1l2 0l2 0l1 2l3 0l2 0l1 -1l2 6zM618 231l-2 -2l-2 -2l-3 -2l-2 -1l-2 1l-2 -1l-1 2l-3 -1l1 -6l0 -2l3 -1l2 -2l1 4l1 3l2 1l3 3l2 2l1 2l3 2l-2 0zM475 136l0 -2l-1 -1l4 -3l3 1l4 0l3 1l2 -1l5 0l1 2l5 1l4 1l3 0l0 1l-2 3l-4 0l-2 3l-1 3l1 2l-1 1l-1 2l-2 1l-2 2l-3 0l-3 0l-2 1l-1 2l-2 -2l-1 -2l-3 0l1 -2l0 -2l0 -2l-1 -2l1 -2l1 -3l1 -1l-1 -2l-2 1l-2 -2l-2 1zM568 85l0 -2l-3 -1l0 -2l3 -1l4 0l3 1l3 -1l-2 3l1 3l-1 1l-2 0l-3 -1l-3 0zM605 224l2 1l2 -1l2 1l3 1l2 3l1 1l0 3l-1 1l0 2l2 0l1 4l1 1l1 1l9 4l3 0l-8 10l-4 0l-2 2l-3 1l-3 -1l-2 2l-1 1l-2 0l-2 -1l-4 -2l-3 -1l-1 -3l-2 -3l-1 -1l-2 -3l-1 -2l2 -1l0 -3l1 -3l1 -1l2 -4l2 -2l1 -3l0 -3l3 1l1 -2zM579 48l0 3l4 2l-2 2l3 4l-2 3l3 2l-2 2l5 2l-2 2l-2 2l-6 4l-5 0l-5 2l-4 0l-2 -2l-3 -1l1 -3l-2 -3l2 -2l2 -2l7 -3l2 -1l-5 -3l-1 -1l0 -5l-4 -2l-4 -2l2 -1l3 2l4 0l3 1l2 -2l2 -2l4 -1l4 1l-2 2zM995 328l1 3l-2 0l-2 -1l2 -2l1 0zM998 327l-2 0l1 -2l3 -1l-2 3zM330 440l3 -2l3 1l1 -1l3 1l-5 2l-1 -1l-3 2l-1 -2zM527 136l-1 2l-2 -3l2 -2l1 3zM510 109l2 1l4 2l2 1l4 0l-1 3l0 2l-2 0l-2 3l1 1l1 1l1 2l-1 4l2 2l-3 1l-5 0l-4 1l-1 2l-3 0l-3 -2l-6 0l-1 -2l1 -1l1 -7l-3 -3l-2 -2l-4 -1l-1 -3l4 0l5 1l-1 -4l2 1l7 -2l1 -3l2 -1l2 2l1 1zM531 285l-3 -3l-2 -3l-2 -3l1 -2l1 -3l0 -2l5 0l0 -4l3 0l2 0l1 3l2 0l-1 4l2 2l0 2l0 3l-1 1l-3 0l-1 -2l-2 2l0 3l-2 2zM484 95l-1 3l-2 -1l-1 -2l-1 -1l2 -1l3 2zM492 82l-3 4l3 -1l3 0l-1 3l-3 3l3 0l3 4l2 1l2 3l0 2l4 0l-1 2l-1 1l1 2l-2 2l-4 0l-5 1l-3 0l-3 0l-2 1l-1 0l4 -4l3 0l-5 -1l-1 -1l3 -1l-1 -2l0 -2l4 0l1 -2l-2 -2l-3 0l0 -3l-3 1l0 -3l-1 -2l1 -3l2 -3l2 0l4 0zM615 138l0 -4l-1 -1l-3 -2l3 1l4 0l4 2l2 0l2 0l1 2l2 1l1 2l-2 0l-2 -1l-5 1l-3 -2l-3 1zM503 253l-4 2l-2 1l-2 1l-3 -1l-1 -4l1 -4l1 -3l-1 -4l0 -3l5 -2l2 0l1 1l1 2l0 2l0 3l0 4l1 4zM477 247l-2 1l-1 0l-1 -4l-2 1l-1 -2l0 -2l-3 -1l-2 0l0 2l-2 1l-1 -2l-1 -1l-1 -1l-1 -2l0 -2l2 -1l1 -1l1 -2l2 1l3 0l1 1l2 0l2 0l1 -1l2 2l1 1l-1 2l2 2l-1 1l1 4l-1 1l0 2zM453 230l4 -2l1 -1l2 1l-2 0l-2 1l-3 1zM458 236l-2 -1l-1 -1l-1 -1l1 -2l7 0l0 3l-2 1l-2 1zM526 269l1 -4l4 0l0 4l-4 0zM566 156l1 2l3 -1l2 1l1 1l-4 0l-4 -1zM574 137l-1 3l-2 0l-5 0l2 2l-3 1l-2 -2l0 3l2 1l0 2l2 1l-3 1l1 2l-2 0l1 3l-4 -1l-1 -3l0 -2l-1 -1l-2 -2l1 -3l1 -1l2 -1l3 -1l3 -1l2 -1l2 2l3 -1l1 -1zM370 4l9 -1l10 0l4 -2l10 0l22 1l17 2l-5 1l-11 1l-15 0l12 0l8 1l5 -1l3 1l-3 2l7 -1l13 -1l9 0l1 2l-11 2l-2 1l-9 0l7 1l-3 2l-3 2l0 4l4 2l-5 0l-4 1l5 2l1 2l-3 1l3 2l-6 1l3 1l-1 1l-4 1l-3 0l3 2l-5 0l-2 1l4 1l4 2l1 2l-5 1l-3 -1l-3 -2l1 2l-3 2l7 0l4 0l-8 3l-7 2l-8 1l-3 0l-3 2l-4 3l-6 2l-2 1l-4 0l-4 1l-2 2l0 2l-1 2l-5 3l1 3l-1 2l-1 3l-4 1l-5 -3l-5 0l-3 -2l-2 -3l-4 -4l-2 -2l0 -3l-4 -3l1 -2l-2 -2l3 -3l4 -2l1 -1l1 -2l-3 1l-4 1l-4 -1l0 -3l1 -1l3 0l5 1l-5 -3l-2 -1l-3 1l-2 -1l3 -3l-2 -1l-2 -2l-3 -4l-4 -1l-7 -3l-6 -1l-8 0l-6 1l-4 -1l-4 -2l7 -1l6 -1l-12 0l-7 -2l11 -3l10 -1l2 -1l-8 -1l2 -2l10 -2l4 0l-1 -2l7 -1l8 0l9 0l3 1l7 -2l7 1l4 1l5 1l-6 -2zM250 228l-3 -1l-3 -2l0 -2l1 -3l4 0l-1 -2l-2 -2l1 -2l3 0l2 0l0 3l0 4l2 0l-2 2l0 2l-2 2zM354 264l-1 1l-2 0l-1 0l-1 -2l1 -3l-1 -2l0 -2l1 -3l3 2l3 2l-1 5l-1 2zM334 245l2 1l2 2l1 2l1 2l1 1l0 3l-2 1l0 2l1 2l1 2l2 3l-2 0l-2 1l-3 1l-2 -2l-1 -3l1 -3l0 -2l-1 -2l-2 -1l-2 -2l1 -3l2 0l0 -2l2 -3zM257 230l-1 -1l-1 -2l-2 -1l-1 -1l0 -2l2 -1l1 -1l2 0l2 0l2 0l2 0l3 0l1 1l2 2l-2 0l-2 1l-2 1l-1 1l-2 1l-1 1l-2 1zM552 123l2 3l-1 1l-3 -1l-3 0l-2 0l-1 1l1 1l2 3l2 2l3 1l-3 -1l-2 -1l-3 -1l-2 -2l-1 -2l-1 -1l-1 1l-1 -2l2 0l3 0l1 -1l2 -3l3 2l2 1zM297 208l4 0l0 2l-1 2l1 2l-2 -1l-3 0l-3 0l3 -1l2 0l0 -2l-2 -2zM545 120l1 -2l1 -2l2 1l3 0l1 -1l3 0l2 -1l3 1l2 0l-2 2l-1 2l-2 2l-2 1l-4 0l-3 0l-2 -1l-2 -2zM835 305l-5 -2l3 -1l2 1l0 2zM846 305l-3 1l1 -4l3 -1l-1 4zM828 298l2 1l1 1l-3 1l-2 0l-1 -1l3 -2zM841 298l0 2l-4 1l-4 0l2 -2l2 1l2 0l2 -2zM802 294l5 0l6 1l1 2l4 0l3 2l-3 1l-3 -1l-2 0l-3 0l-3 -1l-3 -1l-2 0l-6 -1l-3 -2l2 -3l3 0l2 2l2 1zM874 292l-1 2l0 -2l1 -2l0 2zM862 282l1 3l-2 -2l-2 0l-4 0l1 -2l3 0l3 1zM873 276l0 5l3 2l3 -3l3 -2l2 0l3 1l2 1l3 1l0 10l0 11l-3 -3l-3 -1l-4 1l1 -2l2 -1l-1 -4l-1 -2l-5 -3l-3 0l-4 -3l-1 1l-1 -1l-2 -3l3 -1l2 0l-5 -1l-1 -2l-2 0l-1 -2l3 -1l2 -1l4 2zM848 268l-2 3l-2 0l-3 0l-5 0l-2 0l-1 3l3 3l1 -2l6 -1l-2 1l-1 2l-2 1l2 4l2 5l0 2l-1 1l-1 -1l1 -2l-3 1l0 -2l-2 -2l0 -3l-2 1l0 3l1 5l-2 0l-1 0l0 -3l0 -4l-2 -2l1 -2l0 -3l2 -4l3 -4l2 1l3 0l4 0l2 -2zM857 268l0 3l-2 2l2 2l-2 -2l-1 -4l0 -3l1 -1l2 2zM827 266l4 3l-4 1l-1 2l0 3l-2 2l0 3l-1 5l-4 0l-1 -2l-2 0l-1 -1l-4 1l-1 -1l-4 0l0 -5l-2 -1l-1 -2l0 -3l0 -3l2 -2l0 2l2 2l2 -1l2 0l1 -1l4 0l2 -1l2 -4l1 -1l1 -4l3 0l2 1l-1 3l2 3zM794 291l-3 0l-2 -3l-4 -2l-1 -2l-2 -3l-2 -2l-2 -5l-2 -2l-1 -3l-1 -3l-3 -2l-1 -3l-2 -1l-3 -4l1 -2l5 1l2 3l2 2l2 2l3 3l2 0l3 3l1 2l2 2l-1 2l2 2l1 2l1 2l2 0l2 2l-1 4l0 5zM716 157l3 4l0 3l1 1l-2 1l1 4l2 2l4 2l-1 2l-2 3l3 1l3 2l3 1l4 1l2 2l2 0l3 1l3 0l0 -4l1 -2l1 3l2 2l2 -1l2 0l3 0l0 -2l-1 -1l2 0l2 -3l4 -2l2 1l2 -1l1 2l-1 1l3 1l0 1l0 2l-2 0l-4 2l-1 5l-2 4l-2 -1l0 3l0 3l-2 1l-1 -5l-1 2l-2 -2l1 -2l3 -3l-2 0l-3 0l-2 -1l0 -2l-4 -2l-1 3l2 1l-2 2l1 2l0 2l1 2l0 3l-2 1l-3 0l0 3l-2 2l-4 2l-3 4l-2 2l-3 2l-1 2l-3 1l-2 3l1 4l0 3l-1 3l0 6l-3 2l-2 2l0 2l-2 1l-2 -3l-2 -4l-1 -4l-1 -1l-1 -3l-1 -4l0 -2l-3 -5l-1 -6l-1 -4l0 -4l0 -3l-4 2l-2 -1l-4 -3l1 -2l0 -1l-4 -3l2 -2l6 0l0 -3l-2 -1l0 -3l-2 -1l3 -4l3 1l3 -4l2 -3l3 -3l0 -3l2 -1l-2 -2l-1 -2l-1 -3l1 -1l4 0l4 0l2 -3zM483 98l0 2l-2 3l-5 2l-4 -1l3 -3l-2 -3l4 -3l2 -1l1 1l-1 2l4 1zM650 152l2 -1l2 -2l3 0l2 0l3 2l3 0l3 3l2 0l0 3l-1 4l-1 2l0 2l1 3l0 2l2 0l1 3l-3 2l1 2l2 2l2 2l0 2l2 2l-4 2l-1 4l-5 -1l-3 -1l-4 0l-1 -4l-3 0l-3 1l-3 -1l-3 -2l-3 -1l-2 -3l-2 -5l-1 1l-2 -1l-1 1l-2 -2l-1 -1l1 -3l-2 -2l-3 -2l-2 -3l1 -2l1 -2l0 -1l-2 -1l-2 -4l-1 -3l0 -5l1 -1l2 3l2 1l4 -3l2 1l-1 1l2 2l2 2l2 1l2 2l4 0l5 -1zM626 156l2 1l0 1l-1 2l-1 2l2 3l3 2l2 2l-1 3l1 1l2 2l-4 0l-2 3l-5 0l-8 -7l-4 -2l-3 -1l-1 -4l6 -3l1 -4l0 -3l1 0l2 -2l4 -1l2 1l2 4zM460 57l-1 2l3 2l-3 3l-8 2l-3 0l-3 0l-8 -1l3 -2l-7 -1l5 -1l-6 -1l2 -3l5 0l4 2l4 -2l4 1l4 -1l5 0zM599 166l-1 1l-1 2l1 1l-1 7l-2 -6l2 -3l0 -2l2 -1zM543 148l-1 3l0 2l-2 -1l-5 -2l0 -1l3 0l3 0l2 -1zM526 139l1 2l0 4l-3 1l-1 -5l0 -2l3 0zM534 121l4 0l1 3l-2 0l-3 1l0 3l1 1l3 2l1 3l3 2l2 0l3 3l2 1l2 1l-2 1l-2 -1l-1 2l2 1l-1 2l-2 3l-1 -2l0 -3l-1 -2l-2 -1l-2 -1l-1 -1l-2 -1l-2 -1l-3 -2l-2 -2l-1 -3l-3 -2l-3 2l-1 -1l-2 -3l0 -2l3 0l1 -1l2 0l3 -1l1 -2l2 1l3 -2zM285 212l1 1l2 0l-2 1l-2 0l-2 -1l2 -1zM599 167l3 0l6 -3l1 4l-6 2l3 3l-2 2l-2 0l-2 3l-3 -1l1 -6l1 -2zM874 161l-1 4l-1 -1l-2 0l-1 2l-1 -1l1 -3l3 -1l2 0zM892 152l-1 2l0 2l-1 2l-4 2l-5 0l-4 4l-2 -2l0 -2l-5 1l-3 1l-3 0l3 3l-2 5l-2 2l-1 -2l0 -3l-1 -1l-2 -2l3 -1l2 -2l2 -1l2 -3l6 -1l3 1l3 -6l2 2l4 -3l1 -2l2 -4l0 -3l1 -2l3 -1l1 5l0 2l-2 3l0 4zM900 129l2 1l2 -2l0 4l-4 1l-2 3l-5 -2l-1 3l-3 0l-1 -3l2 -2l3 0l1 -5l0 -2l4 3l2 1zM697 135l-1 1l-4 2l-1 2l-2 -1l-4 0l0 -3l-1 -3l-4 -3l-4 1l-4 0l-2 -3l-3 -1l-4 -2l-8 1l0 12l-3 -2l-2 -1l-3 1l-1 1l0 -2l-3 -3l-2 -3l-1 0l2 -1l1 -2l2 -1l2 0l1 -3l-1 -2l-2 0l-3 0l-3 1l-3 1l-1 -2l-2 -3l-2 1l-2 -3l2 -2l1 -4l3 2l0 -3l6 -3l4 0l6 2l4 1l3 -1l4 0l4 1l4 0l1 -2l-4 -2l2 -2l2 -2l-2 -2l2 -1l10 -1l1 -1l7 -1l3 -1l5 0l1 4l3 -1l3 1l3 2l7 -3l-1 1l3 2l6 8l2 -1l4 2l4 -1l1 0l1 2l2 1l2 1l3 0l2 2l-2 2l-3 0l0 3l-1 2l-6 -1l-2 6l-1 0l-6 2l3 5l-2 1l0 2l-2 -1l-1 -1l-4 0l-5 0l-5 -1l-1 1l-1 1l-4 -1l-2 1l-1 1zM614 275l2 3l-2 1l-1 1l-2 3l0 1l-1 2l-1 1l-4 -3l0 -2l-10 -6l-1 -4l1 -2l1 -2l1 -2l-1 -4l-2 -4l2 -2l2 -2l1 3l1 1l6 2l2 1l2 0l1 -1l2 -2l1 1l0 4l0 12zM697 135l1 -1l2 -1l4 1l1 -1l1 -1l4 1l6 0l4 0l1 1l2 1l-5 2l-1 2l-3 0l-1 2l-3 0l-2 0l-3 2l-6 2l-3 -1l-3 0l0 -2l3 1l1 -1l2 0l4 -2l-3 -2l-2 1l-2 -1l2 -2zM787 238l-1 -2l-1 -3l-1 -4l2 -3l4 -1l2 1l3 1l1 -2l2 1l1 2l0 4l-5 3l1 2l-3 0l-2 1l-3 0zM857 147l2 4l1 2l0 4l-1 1l-3 1l-2 1l-3 1l0 -2l1 -2l-2 -4l2 0l-2 -3l3 -2l2 0l2 -1zM558 136l-2 -1l1 -2l1 -1l1 1l1 1l-1 1l-1 1zM633 175l1 1l0 4l-1 0l-1 -2l-3 0l2 -3l2 0zM792 226l1 -2l0 -2l-2 -3l0 -3l-2 -3l-2 0l-3 1l-3 1l0 -3l0 -3l-2 0l0 -2l-1 -1l3 -3l2 1l-1 -4l3 2l2 3l3 0l1 3l-2 1l3 3l2 3l2 3l2 3l1 2l-1 3l-2 -1l-1 2l-3 -1zM600 164l-2 1l1 -3l1 -2l2 1l-2 2l0 1zM479 258l-4 -2l-3 -2l-2 -2l-2 -2l1 -2l1 -2l2 -1l2 1l0 2l2 -1l1 3l-1 1l2 1l1 2l0 4zM541 198l-2 1l-1 -2l-5 -1l-1 -2l-2 -1l-2 -2l-2 -3l1 -2l0 -2l0 -2l0 -4l-1 -4l2 -1l0 -3l2 -1l2 -2l0 -2l3 1l4 0l3 2l2 2l2 1l4 1l3 2l1 -1l2 -1l-1 -3l1 -1l2 -2l2 0l4 0l1 2l1 0l3 1l0 2l0 4l0 2l0 12l0 12l0 6l-3 0l-11 -5l-11 -6l-3 2zM727 248l0 3l-1 1l-3 1l-1 -3l-1 -4l2 -6l2 2l1 2l1 4zM580 366l1 2l-2 2l-2 1l-2 -2l1 -2l2 -1l2 0zM563 96l-1 -2l-3 -1l-1 -2l4 -1l4 0l3 -1l2 1l3 2l-2 2l-1 2l-3 1l-3 0l-2 -1zM558 91l1 -3l1 -2l3 -1l2 2l2 0l1 -2l2 -1l4 2l2 0l1 1l1 3l-3 1l-1 1l-3 -2l-2 -1l-3 1l-4 0l-4 1zM486 156l1 2l3 -1l3 1l2 2l0 2l1 4l0 2l-3 0l-2 1l-1 3l-3 1l-2 2l-2 1l-3 0l-4 3l0 4l0 1l-3 1l-2 0l-3 0l-1 3l-2 4l-4 3l-1 5l-1 1l-6 2l1 -3l1 -1l1 -4l1 -2l2 -2l1 -4l2 -1l2 -3l1 -2l3 0l2 -2l1 -1l2 -3l0 -4l1 -3l0 -1l2 -3l3 -1l2 -1l2 -4l1 -2l2 0zM574 116l2 -1l2 1l3 1l1 2l1 2l-2 1l-1 1l-2 2l0 -3l-1 -3l-1 -2l-2 -1zM638 313l0 1l1 2l0 4l1 1l-1 3l0 -2l0 3l-2 3l0 2l-1 4l-1 5l-2 6l-1 4l-1 4l-2 1l-3 1l-1 -1l-3 -1l0 -2l-1 -3l-1 -2l0 -2l1 -3l1 -1l1 -3l1 -2l-1 -1l-1 -3l0 -2l1 -2l0 -2l3 -1l3 -1l1 -2l3 -2l0 -1l3 -3l1 -4l1 2zM230 188l-1 3l0 2l-1 5l1 3l0 2l1 2l2 3l1 2l1 1l3 1l1 1l2 -1l2 0l2 0l2 -1l2 -1l1 -2l0 -3l2 -2l3 -1l3 1l2 0l-2 3l0 2l0 2l-1 3l-1 -1l-2 2l-3 0l-3 0l-1 2l1 1l1 2l-3 1l-1 3l0 2l-3 -3l-2 -2l-2 0l-4 1l-3 0l-2 -1l-3 -2l-2 0l-3 -2l-2 -1l-3 -1l-3 -1l-1 -2l-3 -1l-1 -3l-1 -1l2 -2l-1 -3l-2 -3l-2 -3l-3 -2l-1 -2l-3 -2l0 -3l-1 0l-2 -2l0 -2l-3 -2l-2 -2l-1 -3l-1 -3l-2 -2l-3 -1l0 3l0 2l1 2l2 2l2 2l1 2l1 2l2 2l1 3l1 1l0 2l2 2l1 1l1 1l-1 2l-1 -2l-2 -2l-2 -1l-2 -1l0 -2l0 -2l-1 -1l-2 -2l-3 -1l-2 -2l3 -1l-2 -4l-2 -1l-1 -2l-1 -2l-1 -2l-1 -3l3 -1l3 0l4 2l7 3l5 0l2 0l5 -2l1 1l2 1l1 2l1 2l1 1l1 1l3 1l1 -2l3 0l2 1l1 2l1 2l2 2l0 2l1 2l2 1l2 0zM557 137l2 -2l3 0l2 1l0 2l-3 1l-3 1l-1 -2zM466 225l2 -3l2 1l2 -1l13 0l0 -2l-2 -15l-1 -14l4 0l10 7l9 7l1 2l1 1l2 2l3 0l0 8l-2 2l0 2l-2 0l-4 0l-1 2l-4 0l-2 0l-3 1l-2 2l-2 2l-2 0l0 2l-3 3l0 3l0 2l-2 0l-1 -1l-3 1l-2 -1l-1 -2l0 -2l-1 -2l-2 1l-2 0l-2 0l-1 -1l0 -2l-2 -3l0 -2zM777 207l-2 1l-2 0l-1 4l0 3l2 3l1 2l-1 3l-1 2l2 2l1 2l1 5l-2 3l-1 3l-1 -2l1 -3l-1 -2l1 -3l-1 -2l-1 -4l-1 -4l-1 -3l-2 2l-3 2l-3 -1l1 -4l-1 -3l-2 -4l-1 -1l-2 -3l-1 -2l1 -2l2 -1l0 -3l0 -3l2 1l2 -3l1 -4l4 -4l2 0l0 -2l0 -1l3 1l1 3l0 3l-3 3l0 4l3 -1l1 3l1 1l0 2l2 2l3 -1l-2 4l-2 2zM555 134l-1 1l-3 0l1 -3l1 -1l2 1l1 1l-1 1zM744 112l3 0l5 -3l4 -1l3 1l3 0l1 1l3 0l4 1l3 -2l-1 -2l3 -3l3 1l2 0l4 1l0 2l4 2l3 -1l3 0l3 0l3 2l1 1l3 0l3 1l3 -1l4 0l4 -3l1 1l2 1l3 0l-1 2l-2 3l1 2l4 0l2 -2l2 1l3 3l-3 0l-4 1l-2 1l-2 2l-4 1l-3 2l-3 -1l-3 2l1 1l-1 2l-2 2l-4 1l-4 0l-4 2l-3 1l-2 -1l-3 0l-4 -2l-3 0l-4 0l-5 0l-3 0l-2 -2l-1 -3l-2 -1l-3 -2l-4 0l-3 -1l-1 -1l1 -4l-2 -2l-4 -2l-3 -1l0 -3zM596 309l2 0l3 1l3 0l3 -1l3 -2l2 -1l0 4l1 3l0 5l0 2l-1 2l-1 2l-1 2l-3 2l-3 1l-3 4l-3 2l-2 4l2 2l0 2l1 4l0 2l-2 2l-2 2l-3 1l-2 1l1 2l-2 2l-1 -3l1 -5l-1 -2l-1 -5l3 -3l0 -3l1 -2l0 -3l0 -3l0 -4l-1 -1l-2 -1l-4 0l0 -4l8 -3l2 2l2 0l-1 3l1 3l1 2l1 -3l1 -5l-1 -2l-1 -1l-2 -4l1 -3zM466 225l-2 -2l-1 -3l-2 -1l-1 -1l-3 1l-3 1l1 -3l0 -4l0 -3l0 -3l-1 -2l-1 -1l11 -1l0 -5l0 -1l3 -1l0 -8l9 0l0 -5l10 8l-4 0l1 14l2 14l0 3l-12 0l-3 1l-2 -1l-1 2zM596 309l-1 3l1 4l2 1l1 2l0 5l-2 3l-1 -2l-1 -3l1 -1l-1 -2l-3 -2l-1 0l1 -3l1 -2l-1 -2l1 -3l-1 -4l-1 -1l3 1l1 2l1 4zM781 252l2 1l1 -1l2 2l1 2l0 3l0 2l1 2l2 4l-2 1l-3 -2l-3 -3l-2 -4l-1 -2l-1 -2l1 -2l-1 -2l3 1zM829 258l-2 1l-2 -1l-3 0l-1 4l-1 1l-2 4l-2 1l-3 -1l-2 2l-2 0l-2 1l-2 -2l0 -2l2 1l2 -1l0 -3l5 -1l2 -3l1 -2l1 2l2 -1l1 -2l2 -4l1 -2l3 1l2 3l2 1l-2 1l0 2zM545 365l-2 -3l-1 -2l0 -3l-1 -3l-1 -5l0 -3l0 -2l-1 -2l-2 -2l-1 -4l-1 -2l-2 -3l0 -3l3 -1l3 2l12 -1l2 2l6 0l5 -1l3 -1l3 1l-2 1l-3 1l-1 -1l-4 1l-2 0l0 12l-3 0l0 9l0 12l-2 2l-3 0l-2 -2l-3 1zM960 340l3 2l1 2l-2 0l-2 -2l-2 -1l-2 -3l2 0l2 1zM506 233l0 -2l-3 -1l-2 -3l0 -3l3 -2l4 0l2 0l0 -2l2 -2l0 -8l4 -1l8 -7l9 -6l5 1l1 2l2 -1l1 5l1 2l1 1l-1 8l-1 4l-3 3l-1 5l1 1l0 2l1 1l-1 2l-2 -4l-3 2l-2 -1l-2 0l-4 1l-4 -1l-2 1l-2 -2l-3 -1l-3 1l-1 2l-1 1l0 3l-2 -2l-2 1zM524 257l-3 1l-2 0l-3 0l-1 -2l-1 -2l-2 -2l-2 0l-3 0l1 -5l0 -2l0 -2l2 -3l1 -3l-1 -2l0 -4l1 -1l0 -2l4 -1l3 1l1 2l3 -1l3 2l3 -2l3 0l3 1l2 -2l3 4l1 1l0 2l-2 2l-1 2l0 2l-2 3l-1 1l0 2l-1 2l-2 2l-2 -2l-3 2l-2 3l0 3zM262 236l-2 -2l-2 -2l-2 -2l2 0l1 -2l2 -1l2 -1l1 -2l2 0l2 0l1 2l-1 2l0 2l0 2l0 2l-1 2l-1 1l-1 -1l-3 0zM517 99l2 0l0 4l-2 1l0 4l-1 -1l-2 -2l-3 1l-2 0l2 -1l2 -5l4 -1zM578 42l9 2l-4 1l3 2l-4 1l-3 0l2 -2l-4 -1l-4 1l-2 2l-2 2l-3 -1l-4 0l-3 -2l-2 1l-2 3l-5 -1l-1 2l-2 0l-2 2l-3 4l-4 4l1 1l-1 2l-3 0l-2 3l0 4l2 2l-1 3l-2 3l-1 1l-2 -2l-6 4l-3 1l-4 -2l-1 -3l-1 -8l2 -2l8 -2l5 -4l5 -4l7 -7l5 -2l7 -4l6 -1l5 0l4 -3l5 0l5 0zM569 20l-7 1l-4 -1l1 0l-1 -1l6 -1l1 1l4 1zM551 14l9 2l-7 2l-2 2l-2 1l-1 2l-4 0l-6 -2l3 -1l-4 -1l-6 -2l-2 -3l8 -1l1 1l4 0l1 -1l4 0l4 1zM571 12l5 1l-4 2l-8 0l-8 -1l-5 -1l-3 -1l9 -1l4 1l3 -1l7 1zM745 182l0 3l-3 2l-3 -1l-2 0l-2 -2l-4 -1l-3 -1l-3 -2l-3 -1l2 -3l1 -2l4 1l2 2l2 0l1 2l2 0l2 2l4 0l3 1zM981 405l2 0l1 1l-1 3l-2 2l-1 2l1 1l-2 0l-3 1l0 3l-2 3l-2 1l-2 1l-2 0l-2 -1l-3 0l1 -4l4 -3l1 -1l2 -1l3 -1l1 -2l2 -3l1 -2l2 -2zM985 389l2 4l0 -3l1 1l1 3l2 1l2 0l1 -1l1 3l-1 2l-2 0l0 2l-2 3l-1 2l-2 1l-2 -1l2 -3l-1 -2l-3 -1l2 -2l0 -3l0 -2l-1 -2l-1 -2l-2 -3l-1 -2l2 2l2 0l1 3zM664 204l-2 2l-1 1l-1 1l1 2l-4 2l-1 2l-2 1l-2 2l-3 1l-2 -2l-3 -5l9 -4l2 -6l-2 -2l1 -3l2 -2l-1 -3l3 3l1 1l2 0l2 1l1 2l2 1l-1 3l-1 2zM709 152l2 1l1 3l4 1l-2 3l-4 0l-4 0l-1 1l1 3l1 2l2 2l-2 1l0 3l-3 3l-2 3l-3 4l-3 -1l-3 4l2 1l0 3l2 1l0 3l-6 0l-2 2l-2 0l0 -3l-3 -2l-5 0l-4 0l-4 1l1 -4l4 -2l-2 -2l0 -2l-2 -2l-2 -2l-1 -2l5 2l3 0l1 0l3 0l3 -2l0 -2l2 -2l2 0l2 -2l3 0l-1 -2l2 -2l1 -1l-1 -2l3 0l1 -2l1 -2l-1 -3l2 -1l3 -1l3 0l1 -1zM284 249l-2 -3l0 -2l-2 -1l-2 1l-1 1l1 3l-1 1l-2 -2l-2 -1l-2 -1l-1 -1l0 -3l2 1l2 2l2 -1l2 -1l2 -1l3 1l2 2l0 2l-1 1zM307 329l-1 2l-1 1l-3 -2l-6 -5l-5 -3l-2 -2l-1 -3l-2 -5l-3 -6l-3 -7l-1 -1l-1 -3l-2 -2l-2 -1l1 -1l-1 -4l1 -2l2 -2l-1 2l2 1l2 2l2 -1l0 -2l2 -3l3 -1l3 -4l1 -2l0 -2l2 1l1 1l1 1l2 4l2 0l2 -1l2 0l2 2l-1 3l2 2l-3 0l-2 1l-3 2l-1 3l0 2l-2 1l-1 1l2 3l1 2l1 2l1 2l3 0l2 -2l0 5l3 0l2 5l0 3l-1 3l-1 2l0 2l1 3l-1 3zM851 245l0 2l0 5l-1 -4l-2 2l1 3l-1 1l-3 -2l-1 -2l1 -2l-2 -1l-1 1l-3 2l1 -4l2 -1l1 -1l1 1l2 0l3 -2l-1 -3l3 2l0 3zM844 239l-1 1l0 2l-3 -1l1 -2l1 -2l1 2l2 -3l-1 3zM829 242l-4 3l2 -2l2 -2l2 -3l1 -3l0 3l-1 2l-2 2zM839 234l1 1l2 1l-1 1l-2 1l0 -3zM849 233l0 3l-2 -1l1 4l-1 0l0 -2l-2 -2l2 -1l-2 -3l3 1zM838 230l-1 3l-1 -2l-2 -3l3 1l1 1zM837 212l2 1l1 4l0 2l-2 2l0 2l0 3l3 0l3 1l0 2l1 3l-3 -2l-1 -2l-2 -1l-3 1l-1 -1l1 -2l-2 -1l-1 -5l1 1l0 -5l1 -3zM933 294l-2 -1l-1 -2l-1 -2l2 1l1 2l1 1zM922 290l-2 1l-1 1l-2 1l-3 -1l-2 -1l3 -1l2 -2l0 2l3 -1l1 -1l0 -2l2 0l-1 4zM909 296l2 2l2 4l2 1l2 0l2 2l-2 2l-3 -2l-3 0l-2 -2l-2 -2l-1 -3l-4 -1l-2 1l-2 1l0 2l-2 1l-1 0l-3 0l0 -11l0 -10l4 2l6 2l2 1l1 2l1 2l4 2l1 2l-3 0l1 2zM925 287l-1 -1l-2 -3l-1 -1l-2 -1l2 0l2 2l1 1l1 1l0 2zM542 107l-1 -3l-1 -2l-1 -2l0 -2l2 -1l4 -1l4 -2l3 1l3 1l3 0l5 0l2 1l1 3l-2 2l1 2l2 4l-2 1l-2 3l0 1l-3 -1l-2 0l-3 1l-1 -1l-3 -2l-2 0l-2 -1l-2 0l-2 -1l-1 -1zM316 212l2 1l-3 1l-2 -1l3 -1zM863 135l-2 1l-1 4l-1 0l-2 2l-2 0l-1 1l0 2l3 2l-2 1l-2 0l-1 2l-3 -1l-1 1l-2 -1l1 -2l1 -2l-2 -1l-1 -1l2 -2l4 -2l1 -2l2 1l2 0l0 -2l4 -1l1 -2l2 2zM475 136l2 -1l1 2l2 -1l2 2l-1 1l0 2l-1 2l0 3l0 2l0 2l-1 1l-1 2l-3 0l1 -3l-1 -2l-1 -1l0 -2l1 -2l1 -3l-1 -2zM326 344l1 -4l1 -4l5 -1l3 0l2 1l1 3l0 5l3 0l3 1l1 3l1 2l2 0l0 4l-1 1l0 3l-3 3l-2 0l-3 0l-3 -1l3 -5l-3 -3l-4 -2l-2 -1l-5 -5zM641 192l0 -2l1 -2l1 1l0 3l-2 0zM563 117l3 0l3 0l3 0l2 -1l2 1l1 2l1 1l0 3l2 2l2 0l-1 2l-2 4l-3 -2l-4 1l-1 1l-4 -1l-2 0l-2 -1l-1 -2l-2 0l-2 -2l-2 -2l2 -1l2 -2l1 -2l2 -1zM899 108l3 5l-4 -1l-2 5l3 3l0 3l-2 -2l-2 2l-1 -3l0 -3l0 -3l1 -3l0 -4l-2 -3l1 -5l2 -1l-1 -2l2 2l1 3l0 3l1 4zM563 96l-5 0l-3 0l0 -2l4 -1l3 1l1 1zM14 56l2 1l-1 -2l8 0l5 3l-3 2l-4 0l0 3l-4 1l-2 -1l-4 -1l0 -2l-3 0l-3 0l-2 -1l-3 0l2 1l-2 2l0 -13l7 2l7 3l0 2zM1000 43l-3 0l3 -3l0 3zM4 42l-4 1l0 -3l3 0l4 1l-3 1zM899 35l-4 0l-6 0l2 -2l4 0l4 1zM919 29l-4 1l-4 0l-5 -1l6 -1l7 1zM903 27l-2 3l-10 0l-5 0l-6 -2l2 -2l4 -1l7 1l10 1zM660 43l-11 0l-1 -2l-5 0l0 -2l3 -1l5 -4l-2 -1l6 -3l0 -1l6 -2l9 -2l9 -1l5 -1l5 0l2 1l-2 1l-9 2l-9 1l-9 3l-4 4l-4 3l1 2l5 3zM797 23l1 1l2 0l9 0l6 1l2 1l-1 2l-3 1l-7 2l-2 1l3 0l4 1l3 -1l1 3l2 -1l4 -1l9 1l1 1l11 1l0 -3l6 1l5 0l4 2l1 2l-1 1l3 2l5 2l2 -4l5 2l5 -1l5 1l2 -1l5 1l-2 -3l3 -2l25 2l3 2l7 3l11 -1l6 1l2 1l0 2l3 1l4 0l5 -1l5 1l5 0l5 3l3 -1l-2 -3l1 -1l9 1l6 0l8 1l4 2l0 13l-4 1l-3 0l2 2l2 2l1 1l0 2l-5 0l-8 2l-3 0l-4 3l-4 2l-1 1l-4 -2l-7 2l-1 -1l-3 2l-4 -1l-1 2l-3 3l3 2l0 5l-3 0l-1 3l1 1l-5 2l0 4l-5 1l0 3l-4 3l-2 -2l-1 -5l-1 -7l1 -5l2 -2l5 -2l5 -4l5 -3l5 -3l2 -5l-4 1l-1 2l-7 4l-2 -4l-8 1l-7 6l3 2l-7 0l-4 1l0 -3l-4 0l-3 1l-9 0l-9 1l-9 6l-11 8l5 0l1 2l3 1l2 -2l3 1l4 3l0 3l-2 3l-1 4l-1 5l-4 5l-1 2l-4 4l-4 4l-1 2l-4 1l-4 -1l-3 2l1 -5l-1 -3l2 -1l4 1l2 -3l1 -4l1 -1l1 -3l-5 1l-2 1l-4 0l-1 -3l-4 -2l-4 -1l-1 -3l-1 -2l-1 -2l-2 -3l-3 -1l-4 -1l-3 0l-4 1l-2 1l1 1l-1 3l-3 3l-4 4l-3 -1l-3 0l-2 -1l-1 -1l-4 3l-4 0l-3 1l-3 -1l-3 0l-1 -1l-3 -2l-3 0l-3 0l-3 1l-4 -2l0 -2l-4 -1l-2 0l-3 -1l-3 3l1 2l-3 2l-4 -1l-3 0l-1 -1l-3 0l-3 -1l-4 1l-5 3l-3 0l-3 -1l-3 0l-2 -1l-2 -1l-1 -2l-1 0l-4 1l-4 -2l-2 1l-6 -8l-3 -2l1 -1l-7 3l-3 0l-3 -3l-3 1l-1 -4l-5 0l-3 1l-7 1l-1 1l-10 1l-2 1l2 2l-2 1l-2 3l4 2l-1 2l-4 -1l-4 0l-4 0l-3 1l-4 -1l-6 -2l-4 0l-6 3l0 3l-3 -2l-2 3l-1 3l2 3l2 -1l2 3l1 2l-1 2l-3 0l-2 4l2 3l0 2l3 4l-2 1l-1 1l-2 -2l-3 -1l-1 -2l-2 0l-2 0l-4 -2l-4 0l-3 -1l-4 -2l-3 -2l-2 -1l2 -1l2 -3l-1 -1l4 -1l-3 0l2 -3l2 0l0 -3l1 -2l-4 -2l-3 -1l-2 0l-4 -1l-1 -2l-2 0l1 -2l-2 -1l-3 0l-2 0l-1 -2l2 -1l-2 -2l-1 -1l-2 -2l1 -3l-3 -1l-2 0l-3 -1l-1 -2l-1 -2l1 -1l-1 -3l2 -2l3 -2l-3 -2l6 -4l2 -2l2 -2l-5 -2l2 -2l-3 -2l2 -3l-3 -4l2 -2l-4 -2l0 -3l3 0l4 -1l3 -1l5 2l7 0l11 4l2 2l0 2l-3 1l-4 1l-13 -2l-2 0l5 3l0 4l4 1l2 1l-2 -3l2 -1l7 2l2 -1l-2 -2l7 -3l2 0l3 1l2 -2l-3 -2l2 -2l-2 -2l7 1l2 2l-3 0l2 3l4 -1l1 -2l6 -1l9 -3l2 0l-2 2l3 1l2 -2l5 0l4 -1l4 2l3 -2l-3 -2l1 -1l8 1l4 1l10 4l2 -2l-3 -2l-3 -1l1 -1l-2 -3l5 -4l2 -3l2 0l8 0l0 2l-2 3l1 1l1 2l0 5l3 2l-2 2l-5 4l3 1l1 -1l3 -1l1 -2l2 -1l-1 -2l1 -2l-3 -1l-1 -1l3 -4l-4 -2l5 -3l-1 -2l3 2l-1 3l3 1l-1 -3l4 -1l6 0l5 2l-2 -3l0 -3l4 -1l7 0l6 0l-2 -2l3 -2l3 0l6 -2l7 0l8 -2l3 1l6 -2l5 1l1 -2l2 -1l7 -2l5 1l-4 1l6 1zM792 18l-16 2l5 -5l3 0l2 0l7 2l-1 1zM642 11l-4 1l-2 0l-4 1l-3 -1l2 -1l-6 0l5 -1l4 0l2 1l3 -1l4 1zM778 17l-6 0l-8 -1l-5 -1l-2 -3l-4 0l7 -2l7 -1l5 2l6 3l0 3zM584 276l2 2l-1 2l-2 0l-1 2l-1 -2l0 -3l2 0l1 -1zM476 184l0 -1l0 5l-9 0l0 8l-3 1l0 1l0 5l-11 0l6 -1l1 -2l1 -5l4 -3l2 -4l1 -3l3 0l2 0l3 -1zM619 219l-1 -2l-2 -3l-1 -2l-1 -3l-2 -2l-3 -4l-1 -2l1 -2l-2 -4l-1 -1l-2 -1l-1 -1l0 -3l-2 -3l-2 -3l-1 -2l-1 -2l0 -2l3 1l1 -1l3 -2l2 -2l-3 -3l5 -2l4 1l4 2l8 7l5 0l3 0l1 2l1 0l2 2l1 1l2 3l0 2l1 2l1 2l2 0l0 2l1 4l9 1l2 2l-2 6l-9 4l-8 1l-2 1l-2 4l-2 -1l-4 0l-4 0l-1 -1l-1 2l-1 2zM594 241l0 -1l-2 -3l0 -2l0 -2l-3 0l1 3l-2 2l-1 2l-4 -1l-1 1l-1 1l-3 1l-3 -1l-1 0l-2 -2l-2 0l-1 1l-1 3l-2 1l-1 -1l0 -2l-1 -4l0 -2l-2 -3l-1 -1l1 -2l1 -3l0 -2l1 -3l2 1l0 -13l3 -2l0 -6l12 0l10 0l11 0l1 3l0 4l1 4l3 2l-2 2l-2 0l-1 3l-1 5l0 4l-1 3l-2 2l-1 2l-2 3l-1 3zM594 241l0 3l-2 1l0 2l3 2l1 2l2 3l-2 2l-2 2l-1 2l-4 1l-2 -1l-1 1l-3 -2l0 -2l-2 1l-2 0l-3 -3l-2 -2l-1 -2l-1 -1l-2 -2l-2 -3l-2 -1l2 -1l1 -3l1 -1l2 -1l2 3l1 0l2 0l3 1l2 -2l1 -1l3 2l2 -3l2 -2l0 -2l1 -1l1 2l0 2l2 2l0 2zM454 228l-2 -2l-1 -2l3 -2l0 -2l3 -1l1 -1l3 1l2 1l1 3l2 2l0 2l1 2l1 2l-2 1l-3 -1l-6 0l-3 1l-1 -2l3 0l2 -2l2 1l1 -2l-2 1l-2 -1l-3 1zM949 303l-2 -2l-1 -2l2 3l1 1zM944 299l-2 -1l-1 -1l-2 -1l2 1l2 1zM468 250l-3 -1l-1 -2l-1 -4l2 -1l0 -2l2 0l2 0l1 2l1 2l-1 2l-1 2l-1 2zM256 229l-2 0l-2 0l-2 -1l1 -2l2 0l1 1l2 0zM636 241l-1 2l-2 3l-3 0l-9 -4l-1 -1l-1 -1l-1 -2l2 -3l1 2l2 1l4 -1l3 0l2 -1l2 -1l2 2l0 3zM638 235l3 -2l1 1l0 2l-1 3l-1 3l-1 4l-2 4l-2 5l-2 3l-4 5l-2 2l-5 4l-2 2l-3 4l-1 2l-2 -2l0 -12l2 -4l3 -1l2 -2l4 0l8 -10l2 -3l1 -2l0 -4l1 -2zM558 125l2 1l2 2l1 1l0 2l1 1l-1 1l-1 2l-2 0l0 -2l-2 -1l-1 1l-2 -1l-1 0l0 -3l-1 -1l1 -1l-1 -2l1 -2l4 1zM341 253l4 0l2 0l3 0l-1 3l0 2l1 2l-1 3l0 2l-2 -1l-2 0l-1 2l-3 -3l0 -2l-2 -2l0 -2l2 -1l0 -3zM552 112l3 1l2 -1l3 0l3 1l-2 2l-3 0l-2 1l-3 0l-1 1l-2 0l-3 -1l1 -2l2 0l1 -2zM538 121l3 1l1 -1l2 0l2 0l-2 1l-1 2l-2 0l-3 1l0 -4zM562 59l-3 2l0 2l-4 3l-5 3l-2 4l2 3l2 1l-2 4l-3 1l-1 5l-2 3l-3 0l-2 3l-3 0l-1 -3l-2 -4l-2 -5l1 -1l2 -3l1 -3l-2 -2l0 -4l2 -3l3 0l1 -2l-1 -1l4 -4l3 -4l2 -2l2 0l1 -2l5 1l1 -3l5 2l4 2l0 5l1 1l-4 1zM547 86l-1 4l1 -4zM554 84l-2 1l-1 2l-1 -1l2 -2l2 0zM589 359l0 1l-4 -1l1 -3l1 -1l2 2zM608 164l-6 3l-3 -1l1 -2l0 -1l2 -2l-2 -1l0 -3l0 -1l2 -1l1 -2l3 0l1 0l3 0l3 -1l5 0l-2 2l-1 0l0 3l-1 4l-6 3zM540 230l-1 -1l0 -2l-1 -1l1 -5l3 -3l1 -4l1 -7l-1 -2l-1 -2l-1 -5l3 -2l11 6l11 7l0 13l-2 -1l-1 3l-1 2l0 1l-1 3l1 2l2 3l-2 2l-2 1l-2 3l-2 2l-3 0l-2 2l-1 2l-4 1l-4 0l0 -3l-2 -2l-1 -2l0 -1l2 0l0 -3l1 -2l-1 -2l-1 -3zM505 252l-2 1l-1 -3l0 -5l-1 -4l0 -2l-1 -2l2 -1l0 2l2 2l1 3l-1 7l1 2zM785 233l-3 -2l-2 0l0 -2l-2 0l0 3l-2 5l-1 3l1 2l3 3l0 3l2 2l1 0l2 2l-1 1l-2 1l-3 -3l-1 -1l-1 -2l-1 -2l-1 -1l-1 2l0 -2l0 -2l1 -3l1 -3l2 -3l-1 -3l-1 -4l-2 -2l0 -2l2 -3l-1 -2l-2 -3l-2 -3l3 -4l2 0l2 -1l1 -1l1 1l0 2l2 0l0 3l0 3l3 -2l2 1l3 -1l2 3l0 3l2 3l0 2l-1 2l-2 -1l-4 1l-2 3l1 4zM697 142l-1 1l-3 -1l0 2l3 0l3 1l6 -1l0 3l3 1l0 3l-3 0l-1 0l-2 1l-2 1l-2 -1l1 -3l-2 -2l-2 2l0 1l-3 2l-3 0l1 -3l-1 -3l-2 -1l1 -1l2 0l2 -2l1 -2l3 -1l0 2l1 1zM670 157l0 -3l-2 0l-3 -3l-3 0l-3 -2l-2 0l-3 0l-2 2l-2 1l-1 -3l1 -3l-2 -1l0 -2l-2 -1l1 -2l3 0l2 -1l-2 -1l-1 -2l-2 0l0 3l-1 -2l1 -1l3 -1l2 1l2 2l5 0l-1 -1l3 -1l2 -2l4 1l0 3l4 0l2 4l3 3l2 1l3 2l4 1l0 2l-2 -1l-3 2l-1 2l-1 1l-2 1l-1 1l-2 1l-3 -1zM847 301l3 -2l2 0l-2 3l-3 1zM329 237l1 0l1 2l-3 1l1 -3zM526 174l-1 -6l-2 -1l-2 -3l0 -2l2 -2l0 -3l0 -3l0 -2l3 -1l2 1l3 0l-2 2l1 2l0 3l-2 2l1 2l2 1l1 3l-2 1l-2 2l0 3l-2 1zM603 138l4 1l3 0l2 0l3 -1l3 -1l3 2l0 3l2 1l1 0l-1 1l0 4l1 4l-2 -1l-3 0l-5 1l-4 1l-3 0l-1 0l-3 0l-1 2l-2 1l-1 -1l1 -2l-4 0l-1 2l-5 0l-2 -2l-3 0l-3 2l-2 -2l-3 0l-2 -3l-2 -2l1 -2l-1 -2l3 -3l4 0l1 -2l6 0l3 -2l3 -1l5 0l5 2zM576 140l-3 2l-1 -1l2 -4l-1 0l2 -1l3 0l3 2l-4 1l-1 1zM838 193l-1 5l-2 3l-1 -3l0 -2l1 -3l2 -3l2 1l-1 2zM594 275l11 7l0 2l4 3l-1 4l0 2l2 1l-1 3l0 3l1 2l1 3l-1 2l-3 2l-3 1l-2 0l-4 -1l-2 0l-1 -4l-1 -1l-3 -2l-2 -1l-1 -1l-3 -1l-1 -4l-2 -2l0 -2l-1 -4l3 -2l1 -1l0 -2l0 -2l1 -2l-2 -2l5 -1l5 0zM589 275l-4 0l-2 2l-1 -3l1 -4l1 -1l1 -2l2 -2l-1 -4l1 -1l2 1l2 -1l3 -2l2 3l1 5l-1 2l-1 2l-1 2l0 3l-5 0zM588 103l2 0l4 0l2 1l-1 2l2 0l1 2l4 1l2 0l2 1l5 1l-1 3l1 2l-3 1l-2 1l-2 2l-2 1l-2 0l-3 1l0 2l2 1l2 0l-3 2l-4 1l-1 0l0 -2l-3 -1l3 -1l-5 -2l-3 -1l-1 2l-2 2l-2 0l0 -2l0 -1l3 0l-1 -2l-1 -2l-1 -2l-4 -1l-1 0l-2 1l-3 1l-2 0l-4 -1l-3 -1l2 -2l2 -4l2 -1l-2 -3l3 -1l2 0l3 0l3 1l2 0l3 0l3 1l1 -2l3 -1zM340 370l2 0l3 2l3 2l3 2l1 2l-1 2l1 2l-1 2l-4 1l-2 0l-4 -1l-3 -2l0 -2l0 -4l1 -3l1 -3zM68 210l-2 -2l1 -2l2 1l1 2l-1 1zM237 112l0 2l3 1l3 0l2 1l3 0l3 1l4 -1l2 1l3 1l2 1l2 1l1 1l1 1l2 1l3 2l0 3l1 3l-1 2l-1 2l-1 1l1 1l4 -2l3 0l4 -2l-1 -2l4 0l3 0l1 -1l3 -3l5 -1l5 0l2 -1l2 -2l1 -2l2 -3l2 1l2 1l0 4l2 2l-3 3l-3 1l-3 1l-1 2l-1 2l1 2l2 -1l-2 2l-4 0l-2 1l-3 1l4 -1l-3 1l-1 0l-1 3l-2 3l-2 -2l1 2l1 2l-1 1l-2 3l1 -3l-2 -1l0 -3l0 4l-2 -1l2 1l0 3l1 2l1 3l-2 2l-3 1l-2 2l-3 2l-3 3l-2 1l-1 2l0 3l0 2l1 3l1 2l2 5l0 2l-1 3l-2 0l-2 -2l-1 -2l-2 -3l0 -3l0 -2l-3 -3l-3 1l-2 -2l-2 0l-3 0l-3 0l-2 0l0 1l0 2l-2 1l-2 0l-3 -2l-2 0l-2 0l-4 1l-3 2l-2 1l-2 2l0 1l0 3l0 2l-3 0l-2 -1l-1 -2l0 -2l-2 -2l-1 -2l-1 -2l-2 -1l-3 0l-1 2l-3 -1l-1 -1l-1 -1l-1 -2l-1 -2l-2 -1l-1 -1l-5 0l-2 2l-5 0l-7 -3l-4 -1l-3 -1l-3 1l-1 -2l-2 -2l-1 -1l-3 -1l-2 0l-1 -3l-3 -3l-2 -5l-2 -1l-2 -3l0 -3l-2 -1l1 -3l0 -3l-1 -2l1 -3l0 -3l1 -3l-1 -5l-1 -2l0 -2l4 0l1 4l1 -4l-1 -3l8 0l8 0l3 0l8 0l8 0l9 0l8 0l9 0l10 0l6 0l1 -1zM75 87l-3 1l-1 -1l2 -2l3 0l1 1l-2 1zM40 78l-2 1l-1 -1l-2 -1l3 0l2 0zM23 65l2 1l1 0l3 1l2 0l-2 1l-2 -1l-4 0l0 -2zM69 42l2 1l6 0l4 1l3 0l6 1l5 0l2 0l4 0l4 1l3 0l0 12l0 19l3 0l3 1l2 1l2 2l3 -2l3 -1l1 2l2 1l3 2l1 2l3 4l5 2l0 2l-2 2l-1 -2l-3 -1l0 -2l-4 -3l-1 -3l-3 0l-5 0l-3 -1l-6 -4l-2 0l-5 -2l-4 1l-5 -2l-4 -1l-3 1l1 2l-5 1l-2 1l-3 0l-1 -1l1 -4l3 -1l-4 1l-2 3l-4 2l2 1l-2 3l-3 1l-3 1l-1 2l-4 1l-1 2l-3 1l-2 0l-3 1l-3 1l-2 1l-5 1l3 -2l3 -1l3 -2l3 0l1 -2l4 -2l3 -1l0 -3l2 -2l-3 1l-3 1l-2 -2l-1 0l-3 1l-2 -2l-1 -2l-4 0l-2 -1l-2 -1l-2 -3l1 -2l2 -2l1 -1l2 -1l2 1l2 -2l2 1l2 -1l-2 -3l2 -1l-4 1l-3 0l-4 0l-4 0l-1 -2l-4 -2l4 -1l6 -2l2 0l6 2l-2 -2l-4 -1l-2 -2l-2 -1l-4 -1l1 -2l5 0l4 -2l0 -1l3 -2l3 0l5 -2l3 1l4 -2l4 1zM685 151l0 -2l-4 -1l-3 -2l-2 -1l-3 -3l-1 -3l-4 0l-1 -4l-4 -1l-2 2l-3 1l1 1l-4 0l0 -12l8 -2l4 3l3 1l2 3l4 0l4 -1l4 3l-1 3l2 3l4 0l1 1l2 -2l4 -2l1 -1l-1 3l2 1l2 -1l3 2l-4 2l-2 0l-1 -1l0 -2l-3 1l-1 2l-2 2l-2 0l-1 1l2 1l1 3l-2 3l-2 -1zM302 234l-2 1l1 2l-1 3l1 3l2 -3l-1 -1l0 -2l3 -2l1 -2l1 2l2 0l1 2l3 1l3 0l2 1l2 0l1 -1l4 -1l3 0l-2 1l1 2l2 0l2 2l0 2l3 1l-2 2l1 2l-3 1l-1 3l2 2l0 2l-3 2l-2 0l-3 0l-3 0l1 3l0 2l3 0l-2 2l-1 2l-3 1l-2 1l-2 -2l-1 -3l-1 -2l1 -2l-1 -1l0 -2l0 -3l1 -3l-3 0l-2 0l-3 -2l-1 -1l-4 0l-1 -1l0 -2l-1 -2l-2 -2l1 -1l0 -3l1 -1l1 -1l1 -1l2 -1zM800 202l-4 3l-2 3l0 2l2 4l2 4l3 2l1 3l2 6l-1 5l-2 2l-3 3l-2 2l-4 3l-1 -2l1 -2l-2 -2l2 -1l3 0l-1 -2l5 -3l0 -4l-1 -2l1 -3l-1 -2l-2 -3l-2 -3l-2 -3l-3 -2l2 -2l-1 -3l-3 0l-2 -3l-1 -3l1 0l3 0l2 -1l3 -2l1 2l2 0l0 2l1 1l3 1zM648 218l-2 1l-1 3l-3 1l-4 1l-3 3l-2 0l-1 1l-2 1l-3 0l-1 1l-1 1l-2 0l-2 0l-1 -2l0 -2l-1 -3l-1 -1l1 -2l1 -3l1 -3l1 1l4 0l3 0l2 1l3 -4l2 -1l8 -1l3 5l1 2zM588 367l-2 2l-1 2l-2 2l-3 3l-2 2l-2 2l-3 1l-1 1l-2 0l-4 0l-2 0l-4 1l-3 1l-1 1l-3 -1l-2 -2l0 -2l-1 -2l1 -3l-2 -3l-2 -3l-2 -4l2 -2l1 2l3 1l4 -2l0 -12l3 4l-1 2l3 1l1 -2l2 -1l0 -1l2 -1l2 1l3 0l1 0l1 -3l2 -1l1 -3l3 -2l4 -2l2 0l3 0l1 5l1 2l-1 4l-2 0l-1 3l2 3l2 -2l2 0l0 2l-1 3l-1 1l-1 2zM591 302l1 1l1 3l-1 4l1 2l-1 2l-1 3l1 0l-8 3l0 2l-2 1l-2 1l-1 1l-2 3l-2 2l-2 0l-3 0l-1 -2l-5 1l-1 -2l-2 -3l0 -10l6 0l0 -2l-1 -2l0 -2l2 1l3 0l1 1l2 1l1 -1l1 1l2 1l1 1l1 2l2 0l0 -3l-2 -1l-1 -4l1 -4l-1 -1l1 -2l4 -1l3 1l2 1l2 1zM587 344l-3 0l-2 0l-2 -2l-2 0l-1 -2l-1 -2l-3 -3l-1 -2l-2 -3l3 0l2 0l2 -2l2 -3l1 -1l2 -1l2 -1l3 1l1 2l3 1l0 4l0 3l0 2l0 3l-1 3l-3 3z';
let GEOV=null,GEOT=0;const flag=cc=>cc&&cc.length==2?String.fromCodePoint(...[...cc.toUpperCase()].map(c=>127397+c.charCodeAt(0))):'🌐';
async function geoGet(force){if(!force&&GEOV&&Date.now()-GEOT<20000)return GEOV;try{GEOV=await api('api/geo',{});GEOT=Date.now()}catch(e){}return GEOV}
const gloc=ip=>{if(!GEOV||!ip)return null;for(const u of GEOV.users)for(const c of u.conns)if(c.ip==ip)return c;return null};
const glab=c=>!c?'':c.local?'local network':c.cdn?'☁️ Cloudflare (CDN, real place hidden)':c.cc?flag(c.cc)+' '+X(c.city||c.country)+(c.isp?' · '+X(c.isp):''):'locating…';
function geoMap(){const G=GEOV;if(!G)return '<div class="card mb"><p class="note">Loading the map…</p></div>';
const conns=G.users.flatMap(u=>u.conns.map(c=>Object.assign({u:u.name,share:!!u.share},c))),pl=conns.filter(c=>c.lat!=null&&!c.cdn);
const by={};pl.forEach(c=>{const k=(c.city||c.country)+'|'+c.cc;(by[k]=by[k]||{c,us:new Set(),share:false}).us.add(c.u);if(c.share)by[k].share=true});
const B=Object.values(by).map(b=>Object.assign(b,{x:(b.c.lon+180)/360*1000,y:(84-b.c.lat)/142*460,t:(b.c.city||b.c.country)+' · '+b.us.size}));
let vx=0,vy=0,vw=1000,vh=460;if(B.length){const xs=B.map(b=>b.x),ys=B.map(b=>b.y);vw=Math.min(1000,Math.max(320,Math.max(...xs)-Math.min(...xs)+220));vh=vw*.46;
vx=Math.max(0,Math.min(1000-vw,(Math.min(...xs)+Math.max(...xs))/2-vw/2));vy=Math.max(0,Math.min(460-vh,(Math.min(...ys)+Math.max(...ys))/2-vh/2))}
const fs=vw/1000*(innerWidth<560?30:15),cw=fs*.58;B.sort((a,b)=>a.y-b.y);const placed=[];
const pts=B.map(b=>{const w=b.t.length*cw;let ly=b.y-fs*.95;for(const p of placed)if(Math.abs(p.x-b.x)<(w+p.w)/2&&Math.abs(p.ly-ly)<fs*1.1)ly=b.y+fs*1.75;placed.push({x:b.x,ly,w});
return `<g class="gd${b.share?' w':''}"><circle cx="${b.x.toFixed(1)}" cy="${b.y.toFixed(1)}" r="${(fs*.45).toFixed(1)}" style="stroke-width:${(fs*.13).toFixed(2)}"/><text x="${b.x.toFixed(1)}" y="${ly.toFixed(1)}" style="font-size:${fs.toFixed(1)}px;stroke-width:${(fs*.3).toFixed(1)}px">${X(b.t)}</text></g>`}).join('');
const isp={};pl.forEach(c=>{if(c.isp)isp[c.isp]=(isp[c.isp]||0)+1});const top=Object.entries(isp).sort((a,b)=>b[1]-a[1])[0];
const st=(k,v,cl)=>`<div><span>${k}</span><b${cl?` style="color:${cl}"`:''}>${v}</b></div>`;
return `${G.alerts.map(a=>`<div class="banner e gal" role="alert">${I('warn',17)}<div><b>Sharing?</b> <b>${X(a.name)}</b> is connected from ${a.places.map(X).join(' and ')} at the same time (${a.km} km apart). <button class="btn sm dng" data-kick="${X(a.name)}">${I('kick',14)}Kick</button> <button class="btn sm" data-open="${X(a.name)}">Open user</button></div></div>`).join('')}
<div class="card mb"><div class="ct"><div class="lab">${I('globe',15)}Where users connect from</div><span class="m">${G.pending?'locating new IPs…':'Live'}</span></div>
<div class="gmap"><svg viewBox="${vx.toFixed(0)} ${vy.toFixed(0)} ${vw.toFixed(0)} ${vh.toFixed(0)}" role="img" aria-label="World map of online users"><path d="${WORLD}" class="gland"/>${pts}</svg></div>
<div class="gst">${st('Countries',new Set(pl.map(c=>c.cc)).size)}${st('Cities',Object.keys(by).length)}${st('Top network',top?X(top[0]):'-')}${st('Sharing alerts',G.alerts.length,G.alerts.length?'var(--r)':'')}</div></div>`}
function onl(){const L=D.online;if(!GEOV||Date.now()-GEOT>20000)geoGet().then(()=>{if(pg=='on')onl()});const tot=L.reduce((a,x)=>a+x.ssh+x.ips.length+(x.ov||[]).length+(x.hy||0)+(x.wg?1:0),0);
$('#pg').innerHTML=geoMap()+`<div class="card mb"><div class="ct"><div class="lab">${I('wifi',15)}Online users</div><span class="m">${L.length} users · ${tot} connections</span></div>
<p class="note">SSH shows active sessions. V2Ray and DNS users show while they use data (offline about 30 seconds after they stop). OpenVPN, UDP (Hysteria2) and WireGuard show connected devices ("via proxy" when OpenVPN uses the HTTP proxy). Kick disconnects the user and blocks their current Xray IPs for 1 minute. An IP shared with another user (common on mobile data) is never blocked.</p></div>
${L.length?`<div class="ul">${L.map(x=>{const n=X(x.name),over=x.dev&&(x.ssh>x.dev||x.ips.length>x.dev||(x.ov||[]).length>x.dev||(x.hy||0)>x.dev);return `<div class="card"><div class="uh"><div class="av" style="background:hsl(${hue(x.name)} 55% 52%)">${n[0].toUpperCase()}</div><div style="min-width:0"><b>${n}</b><small class="m" style="display:block">Device limit ${x.dev||'Unlimited'}${over?' · <span class="bad">over limit</span>':''}${GEOV&&(GEOV.users.find(g=>g.name==x.name)||{}).share?' · <span class="bad">⚠️ far apart</span>':''}</small></div><button class="btn sm dng" data-kick="${n}" style="margin-left:auto">${I('kick',14)}Kick</button></div>
<div style="margin-top:10px">${HS(x.kind)?`<div class="kv"><span>SSH sessions</span><b>${x.ssh}</b></div>`:''}${(x.sips||[]).map(ip=>`<div class="kv"><span>SSH ${X(ip)}<small class="gl">${glab(gloc(ip))}</small></span><b>connected</b></div>`).join('')}${x.hy?`<div class="kv"><span>Hysteria2 devices</span><b>${x.hy}</b></div>`:''}${x.wg?`<div class="kv"><span>WireGuard ${X(x.wg)}<small class="gl">${glab(gloc(x.wg))}</small></span><b>connected</b></div>`:''}${(x.ov||[]).map(o=>`<div class="kv"><span>OpenVPN ${X(o.ip=='127.0.0.1'?'via proxy':o.ip)}${o.ip=='127.0.0.1'?'':`<small class="gl">${glab(gloc(o.ip))}</small>`}</span><b>for ${ago(o.since)}</b></div>`).join('')}</div>${x.ips.map(i=>`<div class="kv"><span>Xray ${X(i.ip)}<small class="gl">${glab(gloc(i.ip))}</small></span><b>${i.ban?'<span class="bad">Blocked '+i.ban+'s</span>':i.ago+'s ago'+(i.shared?' · shared IP':'')}</b></div>`).join('')}<button class="btn sm" data-open="${n}" style="margin-top:10px">Details</button></div>`}).join('')}</div>`:'<div class="empty card">No one is connected right now.</div>'}`}
function bulkm(){modal('Bulk actions: '+KN[UV.kind]+' users',[['action','Action','select','','days',[['days','Add days to expiry'],['dev','Set device limit'],['reset','Reset data usage to 0']]],['days','Days to add (for "Add days")','number','',1],['dev','Device limit (for "Set device limit", 2 recommended)','number','',2],['scope','Apply to','select','','active',[['active','Active users only'],['all','All users']]]],
async d=>{d.kind=UV.kind;const KU=D.users.filter(u=>inK(u,UV.kind)),n=d.scope=='all'?KU.length:KU.filter(u=>['active','online'].includes(u.st)).length;if(!confirm((d.action=='days'?'Add '+d.days+' days to ':d.action=='dev'?'Set device limit '+d.dev+' for ':'Reset data usage of ')+n+' user(s)?'))throw Error('Cancelled');const r=await api('api/bulk',d);toast('Done for '+r.count+' user(s)')},
`Users without expiry are skipped when adding days.<span style="display:block;border-top:1px solid var(--l);margin-top:12px;padding-top:12px"><b style="color:var(--t)">CSV file</b> (Excel / Google Sheets): export all users, or import new ones. Columns: name, password, expiry (YYYY-MM-DD, days, never or first-use+30), data_limit_gb, devices, reset_day, sni, host, note. Export once to see the format.</span><span style="display:flex;gap:8px;margin-top:10px"><button type="button" class="btn sm" id="cxe">${I('save',14)}Export CSV</button><button type="button" class="btn sm" id="cxi">${I('upl',14)}Import CSV</button><input type="file" id="cxf" accept=".csv,text/csv" hidden></span>`);csvUI()}
const rpw=()=>{const a='abcdefghjkmnpqrstuvwxyz23456789';let r='';const v=crypto.getRandomValues(new Uint32Array(10));v.forEach(x=>r+=a[x%a.length]);return r};
const KN={v2ray:'V2Ray',ssh:'SSH',both:'V2Ray + SSH',ovpn:'OpenVPN',hy2:'UDP',wg:'WireGuard',dns:'DNS'},HX=k=>k=='v2ray'||k=='both',HS=k=>k=='ssh'||k=='both',inK=(u,k)=>u.kind==k||((k=='v2ray'||k=='ssh')&&u.kind=='both'),SUBK=k=>HX(k)||k=='hy2';
async function uqr(n){await openU(n);const t=$('#dtsub');if(t)requestAnimationFrame(()=>t.scrollIntoView({block:'start'}))}
function umodal(u,c,kd,quick){const ds=D.set,dd=D.cert.domain,def=v=>'Default: '+(v||'auto'),k=u?u.kind:c?c.kind:(kd||UV.kind),src=u||c||{},X_=HX(k),S_=HS(k);
const F=[];const RN=u&&!S_&&k!='ovpn',CUR=u?(u.fdays||(u.exp=='never'?0:Math.max(0,dnum(u)))):0;if(!u)F.push(['name','Username','text','Any name, no spaces']);else if(RN)F.push(['name','Name','text','',u.name]);
if(S_||k=='hy2')F.push(['pw',u?'New password (leave empty to keep)':'Password','text','',u?'':rpw()]);
F.push(['days',u?'Expiry: days left from today (0 = no expiry)'+(u.fdays?' · counting starts on first use':u.exp!='never'&&dnum(u)<=0?' · expired now, add days to renew':''):'Valid for days (0 = no expiry)','number','',u?CUR:c?(c.fdays||(c.exp=='never'?0:Math.max(1,dnum(c)))):30]);
if(!u)F.push(['first','Start the days on first connection (not today)','check','',c?!!c.fdays:false]);
F.push(['lim','Data limit in GB (0 = unlimited)','number','',src.lim??0]);if(k!='wg')F.push(['dev','Device limit (2 recommended, 0 = unlimited)','number','',src.dev??2]);F.push(['rday','Monthly data reset day, 1-28 (0 = off)','number','',src.rday??0]);
F.push(['note','Note (only you see this)','area','Name, phone, payment...',src.note]);
if(X_)F.push(['ibs','Attached inbounds','ibs','',u&&u.ibs==null?(D.ibs||[]).map(y=>y.id):src.ibs===undefined?null:src.ibs]);
const RI=k=='wg'?(D.wg?'WireGuard users get a .conf file and a QR code for the WireGuard app (UDP '+(D.ports.WG_PORT||51820)+'). One config works on one device at a time. They get no SSH or V2Ray access.':'WireGuard is not installed on this server yet. Run the installer again to add it. You can still create the user now.'):k=='dns'?'DNS users connect through a DNS tunnel with V2Ray inside. Real domain needed: set it in Settings → DNS. It is slow, but works where only DNS is open.':k=='hy2'?(D.hy?'UDP users connect with Hysteria2 (UDP '+D.ports.HY_PORT+(D.ports.HY_HOP?', port hopping '+D.ports.HY_HOP:'')+') in v2rayNG, NekoBox or Hiddify. They get a subscription link. They get no SSH or V2Ray access.':'Hysteria2 is not installed on this server yet. Run the installer again to add it. You can still create the user now.'):k=='ovpn'?(D.ov?'OpenVPN users get a .ovpn file (TCP '+OVP()+', with or without the HTTP proxy). They get no SSH or V2Ray access.':'OpenVPN is not installed on this server yet. Run the installer again to add it. You can still create the user now.'):X_?((D.ibs||[]).length?'Pick the inbounds this user gets at the bottom. Address, Host, Path and SNI come from each inbound.':'There are no inbounds yet: make them in Inbounds. This user gets them automatically.'):'SSH users can log in with SSH, SSL, WebSocket and UDPGW. They get no V2Ray configs.';
modal(u?'Edit '+u.name:(c?'Clone '+c.name:'Add '+KN[k]+' user'),F,d=>u?(()=>{const nn=RN?String(d.name||u.name).trim():u.name;delete d.name;const v=Math.max(0,parseInt(d.days)||0);if(v==CUR){d.expmode='add';d.days=0}else if(!v){d.expmode='never';d.days=0}else{d.expmode='set';d.days=v}
return (nn!=u.name?api('api/user/rename',{name:u.name,new:nn}):Promise.resolve()).then(()=>api('api/user/edit',Object.assign(d,{name:nn}))).then(()=>{toast('User updated');if(quick)load();else openU(nn)})})():api('api/user/add',Object.assign(d,{kind:k})).then(()=>{toast(KN[k]+' user created');openU(d.name)}),RI,true);if(u)uacts(u)}
function uacts(u){const qd=(id,vals,suf)=>{const i=$('#m_'+id);if(!i)return;const w=document.createElement('div');w.className='qrn';w.innerHTML=vals.map(v=>`<button type="button" class="btn sm" data-q="${v}">+${v}${suf}</button>`).join('');i.after(w);
w.onclick=e=>{const b=e.target.closest('[data-q]');if(!b)return;i.value=Math.round(((parseFloat(i.value)||0)+ +b.dataset.q)*1000)/1000;i.classList.add('flash');setTimeout(()=>i.classList.remove('flash'),500)}};
qd('days',[7,30,90],' days');qd('lim',[10,50,100],' GB');
const mr=$('#mf .mr');if(!mr)return;const L=document.createElement('div');L.className='mra';const dis=u.st=='disabled';
L.innerHTML=`<button type="button" class="btn sm red" data-uea="reset">${I('refresh',14)}Reset usage</button><button type="button" class="btn sm" data-uea="toggle">${I(dis?'unlock':'lock',14)}${dis?'Enable':'Disable'}</button><button type="button" class="btn sm" data-uea="clone">${I('users',14)}Clone</button><button type="button" class="btn sm" data-uea="share">${I('upl',14)}Share</button><button type="button" class="btn sm red" data-uea="del">${I('del',14)}Delete</button>`;
mr.prepend(L);mr.classList.add('mrx');
L.onclick=async e=>{const b=e.target.closest('[data-uea]');if(!b)return;const a=b.dataset.uea,n=u.name,dt=!$('#dt').hidden;
if(a=='clone')return umodal(null,u);if(a=='share'){$('#md').hidden=true;return shareCard(u)}
if(a=='toggle'&&!dis)return modal('Disable '+n,[['reason','Reason (optional, shown on the user\'s page)','text','Payment pending']],d=>api('api/user/toggle',{name:n,reason:d.reason}).then(()=>{toast(n+' disabled');load();if(dt)openU(n)}),'The user is disconnected and cannot connect until you enable them again.');
if(a=='del'&&!confirm('Delete '+n+'? All of their access will be removed.'))return;if(a=='reset'&&!confirm('Reset data usage of '+n+' to 0?'))return;
try{await api('api/user/'+a,{name:n});toast(a=='del'?n+' deleted':a=='reset'?'Usage reset':a=='toggle'?n+' enabled':'Done');$('#md').hidden=true;if(dt){if(a=='del')$('#dt').hidden=true;else openU(n)}load()}catch(x){toast(x.message,1)}}}
function kpick(fn){modal('Which type of user?',[['kind','User type','select','',UV.kind,[['v2ray','V2Ray (VLESS, Reality, XHTTP, Trojan)'],['ssh','SSH (SSH, SSL, WebSocket, UDPGW)'],['ovpn','OpenVPN (TCP, HTTP proxy)'],['hy2','UDP (Hysteria2)'],['wg','WireGuard'],['dns','DNS + V2Ray (real domain needed)']]]],d=>{setTimeout(()=>fn(d.kind),60);return Promise.resolve()})}
let DT=null,CP=[];const cp=t=>{CP.push(t);return CP.length-1};
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(e){const a=document.createElement('textarea');a.value=t;a.style.position='fixed';a.style.opacity='0';document.body.append(a);a.select();document.execCommand('copy');a.remove()}toast('Copied')}
function payloads(h,p){return [`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET wss://bug.com [protocol][crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]`,`GET /ws HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]User-Agent: Mozilla/5.0[crlf][crlf]`,`GET http://${h}/ HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]X-Online-Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Keep-Alive[crlf]Upgrade: websocket[crlf][crlf]`,`POST / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`PATCH / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`OPTIONS / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`CONNECT ${h}:${p.WS_PORT} HTTP/1.1[crlf]Host: ${h}[crlf][crlf]`,`HEAD / HTTP/1.1[crlf]Host: ${h}[crlf][crlf][split]GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf][crlf][split]GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`]}
async function openU(n){try{DT=await api('api/user/detail',{name:n})}catch(x){return toast(x.message,1)}drawU();$('#dt').hidden=false;$('#dt .dts').scrollTop=0}
function usageCard(h){if(!h||!h.length)return '';const mx=Math.max(1,...h.map(x=>x[1]+x[2])),tot=h.reduce((a,x)=>a+x[1]+x[2],0),td=h[h.length-1];
return `<div class="card"><div class="ct"><div class="lab">Daily usage (30 days)</div><b>${fb(tot)}</b></div><div class="um"><span class="bl">Today ${fb(td[1]+td[2])}</span><span>Peak ${fb(mx==1?0:mx)}</span></div>
<div class="uch" role="img" aria-label="Daily data usage for the last 30 days">${h.map(x=>`<i title="${x[0]}: ↑ ${fb(x[1])} ↓ ${fb(x[2])}"><b style="height:${(x[1]/mx*100).toFixed(1)}%"></b><u style="height:${(x[2]/mx*100).toFixed(1)}%"></u></i>`).join('')}</div>
<div class="uax"><span>${h[0][0].slice(5)}</span><span><b style="color:var(--a)">■</b> Upload <b style="color:var(--l2)">■</b> Download</span><span>Today</span></div></div>`}
const OVP=()=>(D.h443&&D.h443.on?'443 / ':'')+(D.ports&&(D.ports.OVPN1_PORT||D.ports.OVPN2_PORT)?[D.ports.OVPN1_PORT||1194,D.ports.OVPN2_PORT||110].join(' / '):'1194 / 110');
const DNSH=()=>`<div class="banner w" role="note">${I('net',17)}<div><b>DNS + V2Ray · Real domain needed.</b> DuckDNS does not work here. ${D.dns&&D.dns.ns?'Tunnel domain: <b>'+X(D.dns.ns)+'</b>.':'Set your tunnel domain in Settings → DNS first.'} It is slow (good for chat and browsing) and works where only DNS is open.</div></div>`;
function dnsCard(u,cbox){const o=u.dns;if(!o.on)return `<div class="card"><div class="lab">${I('net',15)}DNS tunnel</div><p class="note bad">The DNS tunnel is not installed on this server yet. Run the installer again to add it.</p></div>`;
const all=`DNS tunnel (DNSTT)\nNameserver: ${o.ns||'-'}\nPublic key: ${o.pub}\nDNS resolver: 8.8.8.8 (faster with DoH: https://dns.google/dns-query)\nHTTP Custom: SlowDNS, Type Auto\nV2Ray: ${(u.links[0]||{}).url||''}`;
return `${o.ns?'':DNSH()}<div class="card"><div class="ct"><div class="lab">${I('net',15)}DNS tunnel + V2Ray</div><button class="btn sm" data-cp="${cp(all)}">Copy all</button></div>
<p class="note">In a DNS tunnel app (DNSTT / SlowDNS with V2Ray) enter the nameserver and public key, pick a DNS resolver, then add the V2Ray config. <b>HTTP Custom:</b> Method SlowDNS, Type <b>Auto</b>. <b>Faster:</b> use the DoH resolver <code>https://dns.google/dns-query</code> when you have normal internet; use 8.8.8.8 or your SIM's DNS when only DNS is open.</p>
${TL([['Nameserver (NS)',o.ns||'Not set'],['DNS resolver','8.8.8.8'],['DoH','https://dns.google/dns-query'],['HTTP Custom','SlowDNS · Type Auto']])}<div class="cg2">${cbox('Public key',o.pub,false)}${u.links.map(l=>cbox(l.name,l.url)).join('')}</div>
<div class="ua" style="margin-top:10px"><button class="btn sm" data-ua="newuuid">${I('refresh',14)}New UUID</button></div></div>`}
const TL=a=>`<div class="kg">${a.map(r=>`<button type="button" class="tlk" data-cp="${cp(String(r[1]))}" title="Copy"><span>${r[0]}</span><b>${X(r[1])}</b></button>`).join('')}</div>`;
function hyCard(u,cbox){const o=u.hy2;return `${o.on?'':`<div class="banner w" role="status">${I('bolt',17)}<div><b>Hysteria2 is not installed yet.</b> Run the installer again to add it.</div></div>`}
<div class="card" id="dtsub"><div class="ct"><div class="lab">Subscription link</div><button class="btn sm" data-ua="newsub">${I('refresh',14)}New link</button></div><p class="note">Import into v2rayNG, NekoBox or Hiddify. It has the Hysteria2 configs and shows usage and expiry.</p><div class="cg2">${cbox('Subscription',u.sub)}${u.jsub?cbox('JSON subscription (v2rayNG, fragment)',u.jsub):''}</div><a class="btn sm" href="${X(u.sub)}" target="_blank" rel="noopener" style="margin-top:10px;text-decoration:none">Open user page</a></div>
<div class="card"><div class="lab">${I('bolt',15)}Hysteria2 (UDP)</div><p class="note">Tap a config to copy it. Port hopping changes the UDP port all the time, which helps when the network slows down one port. To change the password use Edit; the user then needs the new config.</p><div class="cg2">${u.links.map(l=>cbox(l.name,l.url)).join('')}</div>
${TL([['Server',u.addr],['UDP port',o.port],['Port hopping',o.hop||'Off'],['Password',u.pw||'-'],['Devices online',o.online]])}</div>`}
function wgCard(u,cbox){const o=u.wg;if(!o.on)return `<div class="card"><div class="lab">${I('wg',15)}WireGuard</div><p class="note bad">WireGuard is not installed on this server yet. Run the installer again to add it.</p></div>`;
return `<div class="card" id="wgc"><div class="ct"><div class="lab">${I('wg',15)}WireGuard config</div><button class="btn sm" data-ua="newwg">${I('refresh',14)}New keys</button></div>
<p class="note">Scan the QR in the WireGuard app (+ → Scan from QR code), or download the .conf file and import it. One config works on one device at a time.</p>
${o.conf?cbox('WireGuard config',o.conf):'<p class="note bad">The keys are made in a few seconds. Open this user again.</p>'}
<div class="ua" style="margin-top:12px"><button class="btn pri" data-ua="wgdl">${I('save',15)}Download .conf</button></div>
${TL([['Server',u.addr],['UDP port',o.port],['User address',o.ip||'-'],['Connected',o.online?'Yes, from '+(o.from||'?'):'No']])}</div>`}
function ovCard(u){const o=u.ovpn;if(!o.on)return `<div class="card"><div class="lab">${I('vpn',15)}OpenVPN</div><p class="note bad">OpenVPN is not installed on this server yet. Run the installer again to add it.</p></div>`;
return `<div class="card" id="ovc"><div class="ct"><div class="lab">${I('vpn',15)}OpenVPN file</div><button class="btn sm" data-ua="newcert">${I('refresh',14)}New certificate</button></div>
<p class="note">Make a .ovpn file and import it in OpenVPN Connect, HTTP Custom or HTTP Injector. With the HTTP proxy on, the app connects through port ${o.proxy} and sends your Host header.</p>
<div class="ovf"><label>Port<select id="ovp">${o.ports.map(p=>`<option value="${p}">TCP ${p}</option>`).join('')}</select></label>
<label>Host header (bug host)<input id="ovh" type="text" value="${X(o.host)}" placeholder="example: m.facebook.com" autocomplete="off" spellcheck="false"></label>
<label class="ck"><input id="ovx" type="checkbox" checked> Use the HTTP proxy (port ${o.proxy})</label></div>
<div class="ua" style="margin-top:12px"><button class="btn pri" data-ua="ovdl">${I('save',15)}Download .ovpn</button></div>
${o.sess.length?o.sess.map(c=>`<div class="kv"><span>OpenVPN ${X(c.ip=='127.0.0.1'?'via proxy':c.ip)}</span><b>TCP ${c.port} · ${ago(c.since)}</b></div>`).join(''):''}</div>`}
const ago=t=>{const s=Math.max(0,Date.now()/1000-t|0);return s<60?s+'s':s<3600?(s/60|0)+' min':s<86400?(s/3600|0)+' h':(s/86400|0)+' d'};
async function ovdl(url,fn){try{const r=await fetch(url,{credentials:'same-origin'});if(!r.ok)throw new Error(r.status==401?'Please log in again':(await r.text()).slice(0,200)||'Download failed');
const b=await r.blob(),a=document.createElement('a');a.href=URL.createObjectURL(b);a.download=fn;document.body.appendChild(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},1500);toast('File downloaded')}catch(x){toast(x.message,1)}}
function onlineCard(u){const any=u.ssh||u.ips.length||(u.ovpn&&u.ovpn.sess.length)||(u.hy2&&u.hy2.online)||(u.wg&&u.wg.online);return `<div class="card"><div class="ct"><div class="lab">${I('wifi',15)}Connected now</div>${any?`<button class="btn sm dng" data-ua="kick">${I('kick',14)}Kick</button>`:''}</div>
${any?`${HS(u.kind)?`<div class="kv"><span>SSH sessions</span><b>${u.ssh}</b></div>`:''}${(u.sips||[]).length?`<div class="kv"><span>SSH from</span><b>${u.sips.map(ip=>X(ip)).join(', ')}</b></div>`:''}${u.ovpn?`<div class="kv"><span>OpenVPN sessions</span><b>${u.ovpn.sess.length}</b></div>`:''}${u.hy2?`<div class="kv"><span>Hysteria2 devices</span><b>${u.hy2.online}</b></div>`:''}${u.wg&&u.wg.online?`<div class="kv"><span>WireGuard from</span><b>${X(u.wg.from||'?')}</b></div>`:''}${u.dns&&u.ips.length?`<div class="kv"><span>DNS tunnel</span><b>Connected</b></div>`:''}${u.ips.map(x=>`<div class="kv"><span>Xray ${X(x.ip)}<small class="gl">${glab(gloc(x.ip))}</small></span><b>${x.ban?'<span class="bad">Blocked '+x.ban+'s</span>':'Active '+x.ago+'s ago'+(x.shared?' · shared IP':'')}</b></div>`).join('')}`:'<p class="note">Not connected right now.</p>'}</div>`}
function drawU(){const u=DT,p=u.ports,n=X(u.name),hx=HX(u.kind),hs=HS(u.kind);CP=[];
const row=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
const cbox=(label,v,qr,js)=>{const i=cp(v),jt=js?JSON.stringify(js,null,2):'',j=js?cp(jt):0;return `<div class="cb"><div class="cbh"><small>${X(label)}</small><span style="display:flex;gap:6px">${qr===false?'':`<button class="btn sm" data-qr="${i}" data-ql="${X(label)}">QR</button>`}<button class="btn sm" data-cp="${i}">Copy</button>${js?`<button class="btn sm" data-jsn aria-expanded="false">JSON</button>`:''}</span></div><div class="code" role="button" tabindex="0" data-cp="${i}" aria-label="Copy ${X(label)}">${X(v)}</div>${js?`<div class="jsw" hidden><div class="jsh"><small>JSON config (v2rayNG → Custom config)</small><button class="btn sm pri" data-cp="${j}">Copy JSON</button></div><pre class="jsb">${X(jt)}</pre></div>`:''}</div>`};
const sshAll=`Host: ${u.addr}\nUsername: ${u.name}\nPassword: ${u.pw||'-'}\nSSH: ${p.SSH_PORT}\nSSH SSL/TLS: ${AP(u,'SSL_PORT')}\nSSH WS: ${AP(u,'WS_PORT')}\nSSH WS TLS: ${AP(u,'WSTLS_PORT')}\nUDPGW: 127.0.0.1:${p.UDPGW_PORT}\nExpires: ${u.exp=='never'?'No expiry':u.exp}`;
$('#dtb').innerHTML=`<div class="uh" style="margin-bottom:14px"><div class="av" style="background:hsl(${hue(u.name)} 55% 52%)">${n[0].toUpperCase()}</div><div style="min-width:0"><b style="font-size:18px">${n}</b>${tagT(u)}<small class="m" style="display:block">Created ${X(u.created||'-')}</small></div><span class="pill" style="color:${STC[u.st]}">${STN[u.st]}</span></div>
<div class="card"><div class="ct"><div class="lab">Data usage</div><b>${lims(u.used,u.lim)}</b></div>${ubar(u.used,u.lim)}
<div class="um" style="margin-top:10px"><span class="bl">${I('up',14)}${fb(u.up)}</span><span>${I('down',14)}${fb(u.down)}</span><span>${I('cal',14)}${u.fdays?'Starts on first connection ('+u.fdays+' days)':u.exp=='never'?'No expiry':'Expires '+X(u.exp)+(dleft(u)?' · '+dleft(u):'')}</span><span>${I('dev',14)}Device limit ${u.dev||'Unlimited'}</span><span>${I('refresh',14)}${u.rday?'Monthly reset on day '+u.rday:'No monthly reset'}</span></div>
</div>
${u.st=='disabled'?`<div class="banner w" role="status">${I('lock',17)}<div><b>Disabled.</b> ${u.reason?'Reason shown to the user: '+X(u.reason):'No reason given.'}</div></div>`:''}${u.trial?`<div class="banner w" role="status">${I('clock',17)}<div><b>Trial account.</b> It is deleted automatically when the time or data runs out.</div></div>`:''}
${u.note?`<div class="card"><div class="lab">Note</div><div class="note2">${X(u.note)}</div></div>`:''}
${usageCard(u.hist)}
${onlineCard(u)}
${hx||u.kind=='hy2'?'':`<div class="card"><div class="lab">User page</div><p class="note">Send this link to the user. ${u.kind=='dns'?'It shows their usage, expiry and the DNS tunnel details.':u.kind=='wg'?'It shows their usage, expiry, the WireGuard QR and the .conf file.':u.kind=='ovpn'?'It shows their usage, expiry and the OpenVPN file download.':'It shows their usage, expiry, SSH details and payloads.'}</p>${cbox('User page',u.sub,false)}<a class="btn sm" href="${X(u.sub)}" target="_blank" rel="noopener" style="margin-top:10px;text-decoration:none">Open user page</a></div>`}
${hx?`<div class="card" id="dtsub"><div class="ct"><div class="lab">Subscription link</div><button class="btn sm" data-ua="newsub">${I('refresh',14)}New link</button></div><p class="note">Import into v2rayNG, NekoBox or Hiddify. It contains this user's V2Ray configs (the inbounds they have) and shows usage and expiry.</p><div class="cg2">${cbox('Subscription',u.sub)}${u.jsub?cbox('JSON subscription (v2rayNG, fragment)',u.jsub):''}</div><a class="btn sm" href="${X(u.sub)}" target="_blank" rel="noopener" style="margin-top:10px;text-decoration:none">Open user page</a></div>
<div class="card"><div class="ct"><div class="lab">Xray configs</div><button class="btn sm" data-ua="newuuid">${I('refresh',14)}New UUID</button></div>${TL([['UUID / Trojan password',u.uuid],['Inbounds',(u.ibs==null?(D.ibs||[]).length:u.ibs.length)+' of '+(D.ibs||[]).length+' (change with ✏️)']])}<p class="note" style="margin-top:10px">Tap a config to copy it.</p>${'<div class="cg2">'+u.links.map(l=>'<div>'+cbox(l.name+(l.alt?' · port '+(l.url.match(/:(\d+)\?/)||[])[1]+' (or '+l.alt+')':''),l.url,undefined,l.json)+(l.name=='VLESS XHTTP (no TLS)'&&!u.plaindomain?'<p class="note bad" style="margin-top:6px">New Xray apps refuse VLESS without TLS on an IP address. Set a domain (Settings → Server address, or a domain certificate) to use this config.</p>':'')+'</div>').join('')+'</div>'}</div>
`:''}
${hs?`<div class="card"><div class="ct"><div class="lab">SSH account</div><button class="btn sm" data-cp="${cp(sshAll)}">Copy all</button></div>
${TL([['Host',u.addr],['Username',u.name],['Password',u.pw||'Unknown'],['SSH',p.SSH_PORT],['SSH SSL / TLS',AP(u,'SSL_PORT')],['SSH WS',AP(u,'WS_PORT')],['SSH WS TLS',AP(u,'WSTLS_PORT')],['UDPGW','127.0.0.1:'+p.UDPGW_PORT]])}</div>
`:''}

${hs?`<div class="card"><div class="lab">SSH WebSocket payloads</div><p class="note">Host ${X(u.whost)}. Use port ${AP(u,'WS_PORT')} for SSH WS, or ${AP(u,'WSTLS_PORT')} with TLS on for SSH WS TLS. Try them one by one.</p><div class="cg2">${payloads(u.whost,p).map((x,i)=>cbox('Payload '+(i+1),x,false)).join('')}</div></div>`:''}
${hs&&u.pays&&u.pays.length?`<div class="card"><div class="lab">Custom payloads</div><p class="note">Made in Settings → Payloads. The user sees these on their page too.</p><div class="cg2">${u.pays.map(x=>'<div>'+cbox(x.name+' · '+(PAYM[x.mode]||x.mode)+' · port '+payPort(x.mode),x.text,false)+(x.note?`<p class="note" style="margin-top:4px">${X(x.note)}</p>`:'')+'</div>').join('')}</div></div>`:''}
${u.ovpn?ovCard(u):''}${u.hy2?hyCard(u,cbox):''}${u.wg?wgCard(u,cbox):''}${u.dns?dnsCard(u,cbox):''}`}
$('#dt').onclick=async e=>{if(e.target.id=='dt'||e.target.closest('#dx'))return $('#dt').hidden=true;
const jb=e.target.closest('[data-jsn]');if(jb){const w=jb.closest('.cb').querySelector('.jsw');w.hidden=!w.hidden;jb.setAttribute('aria-expanded',!w.hidden);jb.textContent=w.hidden?'JSON':'Hide JSON';return}
const q=e.target.closest('[data-qr]');if(q)return showQR(q.dataset.ql,CP[+q.dataset.qr]);
const c=e.target.closest('[data-cp]');if(c)return copy(CP[+c.dataset.cp]);
const b=e.target.closest('[data-ua]');if(!b)return;const a=b.dataset.ua,n=DT.name;
if(a=='edit')return umodal(DT);
if(a=='clone')return umodal(null,DT);
if(a=='share')return shareCard(DT);
if(a=='wgdl')return ovdl('api/wg?name='+encodeURIComponent(n),n.replace(/[^A-Za-z0-9_-]/g,'_').slice(0,15)+'.conf');
if(a=='newwg'){if(!confirm('Make new WireGuard keys for '+n+'?\n\nThe old config stops working. Send them the new QR or file.'))return;return api('api/user/newwg',{name:n}).then(()=>{toast('New keys made');openU(n)}).catch(x=>toast(x.message,1))}
if(a=='ovdl'){const p=$('#ovp').value,h=$('#ovh').value.trim(),x=$('#ovx').checked;return ovdl('api/ovpn?name='+encodeURIComponent(n)+'&port='+p+'&host='+encodeURIComponent(h)+'&proxy='+(x?1:0),n+'-'+p+(x?'-proxy':'')+'.ovpn')}
if(a=='newcert'){if(!confirm('Make a new OpenVPN certificate for '+n+'?\n\nAll old .ovpn files of this user stop working and they are disconnected. Send them a new file.'))return;return api('api/user/newcert',{name:n}).then(()=>{toast('New certificate made');openU(n)}).catch(x=>toast(x.message,1))}
if(a=='newsub'||a=='newuuid'){if(!confirm(a=='newsub'?'Make a new subscription link for '+n+'?\n\nThe old link stops working. Send the new link to the user.':'Make a new UUID for '+n+'?\n\nAll old Xray configs of this user stop working. The user must refresh the subscription or add the new configs.'))return;
return api('api/user/'+a,{name:n}).then(()=>{toast(a=='newsub'?'New link made':'New UUID made');openU(n)}).catch(x=>toast(x.message,1))}
if(a=='toggle'&&DT.st!='disabled')return modal('Disable '+n,[['reason','Reason (optional, shown on the user\'s page)','text','Payment pending']],d=>api('api/user/toggle',{name:n,reason:d.reason}).then(()=>{toast(n+' disabled');openU(n)}),'The user is disconnected and cannot connect until you enable them again.');
if(a=='kick'&&!confirm('Disconnect '+n+' from all devices now? They can reconnect after about a minute.'))return;
if(a=='del'&&!confirm('Delete '+n+'? All of their access will be removed.'))return;if(a=='reset'&&!confirm('Reset data usage of '+n+' to 0?'))return;
try{await api('api/user/'+a,{name:n});toast(a=='del'?n+' deleted':a=='kick'?n+' disconnected':'Done');if(a=='del')$('#dt').hidden=true;else openU(n);load()}catch(x){toast(x.message,1)}};
async function trial(kd){const k=kd||UV.kind;if(!confirm('Create a '+KN[k]+' trial user? 1 day, 2 GB, 1 device. It is deleted automatically when it ends.'))return;try{const r=await api('api/trial',{kind:k});toast('Trial user '+r.name+' created');await load();openU(r.name)}catch(x){toast(x.message,1)}}
function csvUI(){$('#cxe').onclick=()=>{location.href='api/users.csv'};$('#cxi').onclick=()=>$('#cxf').click();
$('#cxf').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;const t=await f.text();if(!confirm('Import users from '+f.name+'? Users that already exist are skipped.'))return;
try{const r=await api('api/csv-import',{csv:t});toast('Added '+r.added+' user(s)');$('#me').innerHTML=r.errors.length?'Skipped:<br>'+r.errors.map(X).join('<br>'):'';load()}catch(x){$('#me').textContent=x.message}}}
let SH=null;
function shareText(u){const p=u.ports,h=`${BR.brand||'ReXUI'} account\nUsername: ${u.name}\n`+(HS(u.kind)?`Password: ${u.pw||'-'}\n`:'')+`Expires: ${u.fdays?'starts on first connection ('+u.fdays+' days)':u.exp=='never'?'No expiry':u.exp}\nData: ${u.lim?u.lim+' GB':'Unlimited'}\nDevices: ${u.dev||'Unlimited'}\n`;
return h+(!SUBK(u.kind)?`\nYour account page${u.kind=='ovpn'?' (download your .ovpn file here)':u.kind=='wg'?' (WireGuard QR and .conf file here)':''}:\n${u.sub}\n`:`\nSubscription link (v2rayNG / NekoBox / Hiddify):\n${u.sub}\n`)+(u.kind=='dns'&&u.dns?`\nDNS tunnel + V2Ray\nNameserver: ${u.dns.ns}\nPublic key: ${u.dns.pub}\nResolver: 1.1.1.1 / 8.8.8.8`:'')+(u.kind=='hy2'&&u.hy2?`\nHysteria2 (UDP)\nServer: ${u.addr}\nUDP port: ${u.hy2.port}${u.hy2.hop?'\nPort hopping: '+u.hy2.hop:''}\nPassword: ${u.pw}`:'')+(u.kind=='wg'&&u.wg?`\nWireGuard\nServer: ${u.addr}\nUDP port: ${u.wg.port}\nOpen your account page to scan the QR or download the .conf file.`:'')+(u.kind=='ovpn'&&u.ovpn?`\nOpenVPN\nServer: ${u.addr}\nTCP ports: ${u.ovpn.ports.join(', ')}\nHTTP proxy: ${u.addr}:${u.ovpn.proxy}`:'')+(!HS(u.kind)?'':`\nSSH\nHost: ${u.addr}\nSSH: ${p.SSH_PORT}  SSL: ${AP(u,'SSL_PORT')}\nWS: ${AP(u,'WS_PORT')}  WS TLS: ${AP(u,'WSTLS_PORT')}\nUDPGW: 127.0.0.1:${p.UDPGW_PORT}`)}
function shareCard(u){const W=1080,P=64,cv=document.createElement('canvas');cv.width=W;cv.height=3000;const g=cv.getContext('2d'),ac=(AC[BR.accent]||AC.teal)[1],F='system-ui,-apple-system,"Segoe UI",Roboto,sans-serif',p=u.ports;
const rr=(x,y,w,h,r,f)=>{g.beginPath();g.moveTo(x+r,y);g.arcTo(x+w,y,x+w,y+h,r);g.arcTo(x+w,y+h,x,y+h,r);g.arcTo(x,y+h,x,y,r);g.arcTo(x,y,x+w,y,r);g.closePath();g.fillStyle=f;g.fill()};
const fit=(t,max,size,w)=>{let z=size;g.font=`${w} ${z}px ${F}`;while(g.measureText(t).width>max&&z>20){z-=2;g.font=`${w} ${z}px ${F}`}if(g.measureText(t).width>max){while(t.length>3&&g.measureText(t+'…').width>max)t=t.slice(0,-1);t+='…'}return t};
g.fillStyle='#0f1420';g.fillRect(0,0,W,3000);const gr=g.createRadialGradient(W,0,0,W,0,700);gr.addColorStop(0,ac+'55');gr.addColorStop(1,'#0f142000');g.fillStyle=gr;g.fillRect(0,0,W,700);
let y=P+70;const bn=BR.brand||'ReXUI';g.font=`800 76px ${F}`;const lg=g.createLinearGradient(P,0,P+g.measureText(bn).width,0);lg.addColorStop(0,ac);lg.addColorStop(.5,'#2dd4bf');lg.addColorStop(1,'#a78bfa');g.fillStyle=lg;g.textBaseline='alphabetic';g.fillText(fit(bn,W-2*P,76,800),P,y);
if(BR.tagline){y+=50;g.fillStyle='#8b94a5';g.fillText(fit(BR.tagline,W-2*P,32,'500'),P,y)}y+=56;
const sec=(title,rows)=>{const h=40+rows.length*68+24;rr(P,y,W-2*P,h+40,28,'#171d2b');g.fillStyle='#8b94a5';g.font=`700 26px ${F}`;g.fillText(title.toUpperCase(),P+36,y+58);let yy=y+58+24;
rows.forEach((r,i)=>{yy+=68;if(i)rr(P+36,yy-68+6,W-2*P-72,2,1,'#262d3b');g.fillStyle='#8b94a5';g.font=`500 32px ${F}`;g.fillText(r[0],P+36,yy-12);const lw=g.measureText(r[0]).width;g.fillStyle=r[2]||'#e8ecf3';const v=fit(String(r[1]),W-2*P-108-lw,34,'700');g.textAlign='right';g.fillText(v,W-P-36,yy-12);g.textAlign='left'});y+=h+40+28};
sec('Account',[['Username',u.name],...(HS(u.kind)?[['Password',u.pw||'-']]:[]),['Expires',u.fdays?'First use + '+u.fdays+' days':u.exp=='never'?'No expiry':u.exp+(dleft(u)?' ('+dleft(u)+')':'')],['Data',u.lim?u.lim+' GB':'Unlimited'],['Devices',u.dev||'Unlimited']]);
const M=RXQR.make(u.sub),n=M.length,qs=600,m=Math.floor(qs/(n+8)),qw=m*(n+8),qx=(W-qw)/2;rr(P,y,W-2*P,qw+150,28,'#171d2b');rr(qx,y+36,qw,qw,20,'#fff');g.fillStyle='#000';
for(let r=0;r<n;r++)for(let c=0;c<n;c++)if(M[r][c])g.fillRect(qx+(c+4)*m,y+36+(r+4)*m,m,m);
g.fillStyle='#e8ecf3';g.font=`700 32px ${F}`;g.textAlign='center';g.fillText(!SUBK(u.kind)?'Scan to open your account page':'Scan the subscription QR',W/2,y+qw+86);g.fillStyle='#8b94a5';g.font=`500 26px ${F}`;g.fillText(u.kind=='dns'?'Usage, expiry and DNS tunnel details':u.kind=='wg'?'Usage, expiry and your WireGuard QR':u.kind=='ovpn'?'Usage, expiry and your .ovpn file':u.kind=='ssh'?'Usage, expiry, SSH details and payloads':'v2rayNG · NekoBox · Hiddify → Add subscription',W/2,y+qw+124);g.textAlign='left';y+=qw+150+28;
if(u.kind=='dns'&&u.dns)sec('DNS tunnel',[['Nameserver',u.dns.ns||'-'],['Resolver','1.1.1.1 / 8.8.8.8']]);
if(u.kind=='hy2'&&u.hy2)sec('Hysteria2 (UDP)',[['Server',u.addr],['UDP port',u.hy2.port],...(u.hy2.hop?[['Port hopping',u.hy2.hop]]:[]),['Password',u.pw]]);
if(u.kind=='wg'&&u.wg)sec('WireGuard',[['Server',u.addr],['UDP port',u.wg.port]]);
if(u.kind=='ovpn'&&u.ovpn)sec('OpenVPN',[['Server',u.addr],['TCP ports',u.ovpn.ports.join(', ')],['HTTP proxy',u.ovpn.proxy]]);
if(HS(u.kind))sec('SSH',[['Host',u.addr],['SSH',p.SSH_PORT],['SSL / TLS',p.SSL_PORT],['WebSocket',p.WS_PORT],['WebSocket TLS',p.WSTLS_PORT],['UDPGW','127.0.0.1:'+p.UDPGW_PORT]]);
g.font=`500 22px ui-monospace,Menlo,Consolas,monospace`;g.fillStyle='#8b94a5';let line='',lines=[];for(const ch of u.sub){if(g.measureText(line+ch).width>W-2*P){lines.push(line);line=''}line+=ch}lines.push(line);lines.forEach(l=>{g.fillText(l,P,y+10);y+=32});y+=P-10;
const out=document.createElement('canvas');out.width=W;out.height=y;out.getContext('2d').drawImage(cv,0,0);SH={u,c:out,url:out.toDataURL('image/png')};$('#shi').src=SH.url;
const can=!!(navigator.canShare&&window.File);$('#shs').hidden=!can;$('#shm').hidden=false}
$('#shm').onclick=async e=>{if(e.target.id=='shm'||e.target.closest('#shx'))return $('#shm').hidden=true;if(!SH)return;
if(e.target.closest('#shc'))return copy(shareText(SH.u));
if(e.target.closest('#shd')){const a=document.createElement('a');a.href=SH.url;a.download=SH.u.name+'.png';document.body.append(a);a.click();a.remove();return}
if(e.target.closest('#shs')){SH.c.toBlob(async b=>{const f=new File([b],SH.u.name+'.png',{type:'image/png'});try{if(navigator.canShare({files:[f]}))await navigator.share({files:[f],text:shareText(SH.u)});else await navigator.share({text:shareText(SH.u)})}catch(x){if(x.name!='AbortError')toast('Sharing is not available here, use Download',1)}},'image/png')}};
function modal(t,fields,fn,intro,wide){const f=$('#mf');f.className='card'+(wide?' wide':'');f.innerHTML=`<h2>${X(t)}</h2>${intro?`<p class="note" style="margin-top:6px">${intro}</p>`:''}<div class="fgrid">`+fields.map(x=>`<div class="mfi${x[2]=='area'||x[2]=='ibs'?' full':''}">`+(x[2]=='ibs'?ibpick(x):x[2]=='check'?`<label class="ck"><input type="checkbox" id="m_${x[0]}"${x[4]?' checked':''}> ${x[1]}</label>`:`<label for="m_${x[0]}">${x[1]}</label>`+(x[2]=='area'?`<textarea id="m_${x[0]}" placeholder="${X(x[3]||'')}" style="min-height:70px;font:inherit" maxlength="500">${X(x[4]??'')}</textarea>`:x[2]=='select'?`<select id="m_${x[0]}">${x[5].map(o=>`<option value="${o[0]}"${o[0]==x[4]?' selected':''}>${X(o[1])}</option>`).join('')}</select>`:`<input id="m_${x[0]}" placeholder="${X(x[3]||'')}" value="${X(x[4]??'')}" autocomplete="off" autocapitalize="none" spellcheck="false" ${x[2]=='number'?'inputmode="decimal"':''}>`))+'</div>').join('')+`</div><div class="err" id="me"></div><div class="mr"><button type="button" class="btn" id="mc">Cancel</button><button class="btn pri">Save</button></div>`;
$('#md').hidden=false;$('#md').scrollTop=0;if($('#m_ibs'))ibsync();(f.querySelector('input,select,textarea')||{focus(){}}).focus();$('#mc').onclick=()=>$('#md').hidden=true;
f.onsubmit=async e=>{e.preventDefault();const d={};fields.forEach(x=>d[x[0]]=x[2]=='ibs'?ibget():x[2]=='check'?$('#m_'+x[0]).checked:x[0]=='pw'||x[2]=='area'?$('#m_'+x[0]).value:$('#m_'+x[0]).value.trim());const b=f.querySelector('.pri');b.disabled=true;
try{await fn(d);$('#md').hidden=true;load()}catch(x){$('#me').textContent=x.message}b.disabled=false}}
let IBSEL=new Set();
function ibpick(x){const L=D.ibs||[],v=x[4];IBSEL=new Set(v==null?[]:v.filter(i=>L.some(y=>y.id==i)));
if(!L.length)return `<label>${x[1]}</label><p class="note" style="margin:0">No inbounds yet. Make one in Inbounds first, then attach it here.</p>`;
return `<label>${x[1]} <span style="color:var(--r)">*</span></label><div class="ibsb"><button type="button" class="btn sm" data-ibs="all">Select all</button><button type="button" class="btn sm" data-ibs="none">Clear all</button></div>
<div class="ibsel" id="m_ibs" tabindex="0" role="combobox" aria-haspopup="listbox" aria-expanded="false" aria-label="Attached inbounds"><div class="ibtags"></div><span class="car" aria-hidden="true">▾</span></div>
<div class="ibdrop" id="ibdrop" role="listbox" aria-multiselectable="true" hidden>${L.map(y=>`<div role="option" class="ibo" data-v="${y.id}" tabindex="0"><span class="tk" aria-hidden="true"></span><b>${X(y.name)}</b><span class="m">${y.proto} · ${NETN(y).toLowerCase()}${y.sec!='none'?' · '+y.sec:''} · ${y.port}${y.on?'':' · off'}</span></div>`).join('')}</div>
`}
function ibsync(){const L=D.ibs||[],t=document.querySelector('#m_ibs .ibtags');if(!t)return;t.innerHTML=IBSEL.size?L.filter(y=>IBSEL.has(y.id)).map(y=>`<span class="ibtag">${X(y.name)}<button type="button" data-ibx="${y.id}" aria-label="Remove ${X(y.name)}">×</button></span>`).join(''):'<span class="ph">Select one or more inbounds</span>';
document.querySelectorAll('#ibdrop .ibo').forEach(o=>{const on=IBSEL.has(o.dataset.v);o.classList.toggle('on',on);o.setAttribute('aria-selected',on)})}
function ibget(){const L=D.ibs||[];if(!L.length||!$('#m_ibs'))return undefined;return [...IBSEL]}
function ibdrop(open){const d=$('#ibdrop'),b=$('#m_ibs');if(!d)return;d.hidden=!open;b.setAttribute('aria-expanded',open);b.classList.toggle('open',open)}
document.addEventListener('click',e=>{if(!$('#m_ibs'))return;const t=e.target;
const a=t.closest('[data-ibs]');if(a){IBSEL=a.dataset.ibs=='all'?new Set((D.ibs||[]).map(y=>y.id)):new Set();ibsync();return}
const x=t.closest('[data-ibx]');if(x){IBSEL.delete(x.dataset.ibx);ibsync();e.stopPropagation();return}
const o=t.closest('.ibo');if(o){IBSEL.has(o.dataset.v)?IBSEL.delete(o.dataset.v):IBSEL.add(o.dataset.v);ibsync();return}
if(t.closest('#m_ibs')){ibdrop($('#ibdrop').hidden);return}ibdrop(false)});
document.addEventListener('keydown',e=>{if(!$('#m_ibs'))return;const t=e.target;if((e.key=='Enter'||e.key==' ')&&(t.id=='m_ibs'||t.classList.contains('ibo'))){e.preventDefault();t.click()}else if(e.key=='Escape'&&!$('#ibdrop').hidden){e.stopPropagation();ibdrop(false);$('#m_ibs').focus()}},true);
const QK=['q1','q2','q3','q4','q5','q6','q7'],SECN={none:'No TLS',tls:'TLS',reality:'Reality'},NETN=x=>({tcp:'TCP',xhttp:'XHTTP',ws:'WS',grpc:'gRPC',httpupgrade:'HTTPUpgrade'}[x.net]||x.net)+(x.cdn?' CDN':''),PRN={vless:'VLESS',vmess:'VMess',trojan:'Trojan'};let IBH='';
const ikv=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
function ibp(first){const L=D.ibs||[],h=JSON.stringify([L,D.h443&&D.h443.on]);if(!first&&h==IBH)return;IBH=h;
const miss=['xhttp-tls','tcp-tls','trojan','reality','xhttp','cdn-tls','cdn'].some(b=>!L.some(x=>x.b==b)),tot=L.reduce((a,x)=>a+x.users,0);
$('#pg').innerHTML=`<div class="card mb ibsc"><div class="ibs3"><div><span>Total inbounds</span><b>${L.length}</b></div><div><span>Turned on</span><b>${L.filter(x=>x.on).length}</b></div><div><span>Configs given to users</span><b>${tot}</b></div></div></div>
<div class="card ibc"><div class="ibtop"><button class="btn pri" id="iba">${I('plus',15)}Add Inbound</button><input id="ibq" placeholder="Search" value="${X(IBQ)}" autocomplete="off"><span class="ibq1">${L.some(x=>x.qk)&&QK.every(k=>L.some(x=>x.qk==k))?'':`<button class="btn qk" id="ibqa" title="Adds 7 inbounds (VLESS / Trojan, TLS and Reality) on free ports">${I('bolt',15)}1-click all protocols</button>`}${L.some(x=>x.qk)?`<button class="btn qk on" id="ibqd" title="Removes only the inbounds made by 1-click">${I('del',15)}Remove 1-click (${L.filter(x=>x.qk).length})</button>`:''}</span></div>
${D.h443&&D.h443.on?`<p class="note ibnote">443 mode is on: TLS inbounds also work on 443, XHTTP without TLS also on 80 (when they use the main path).</p>`:''}
<div class="ibtw"><table class="ibtab"><thead><tr><th>Inbound name</th><th>Protocol</th><th>Port</th><th>Transport</th><th>Users</th><th>On</th><th class="r">Actions</th></tr></thead><tbody>
${L.map((x,i)=>({x,i})).filter(o=>!IBQ||(o.x.name+' '+o.x.port+' '+o.x.proto+' '+NETN(o.x)+' '+o.x.sec).toLowerCase().includes(IBQ.toLowerCase())).map(({x})=>`<tr class="${x.on?'':'off'}">
<td><b class="ibn">${X(x.name)}</b>${x.qk?'<span class="ibqt">1-click</span>':''}${x.warn?`<div class="ibw">${X(x.warn)}</div>`:''}</td>
<td><span class="ibp1">${PRN[x.proto]||x.proto}</span></td>
<td><span class="mono">:${x.port}</span>${x.hp?`<div class="m">also :${x.hp}</div>`:''}</td>
<td><span class="ibts">${NETN(x)} + ${x.sec=='none'?'None':x.sec=='tls'?'TLS':'Reality'}${x.flow?' · Vision':''}${x.ech?' · ECH':''}${x.venc?' · Enc':''}${x.rw&&x.rw.on?' · Watch':''}</span>${(x.ext||[]).length?`<div class="m">+${x.ext.length} external</div>`:''}</td>
<td><span class="ibu">${x.users}</span></td>
<td><button class="sw${x.on?' on':''}" data-ib="tog" data-id="${x.id}" role="switch" aria-checked="${x.on}" aria-label="${X(x.name)} ${x.on?'on':'off'}" title="${x.on?'Turn off':'Turn on'}"><i></i></button></td>
<td class="r"><span class="iba"><button data-ib="port" data-id="${x.id}" aria-label="Check port ${x.port}" title="Check if the port is open">${I('shield',15)}</button><button data-ib="clone" data-id="${x.id}" aria-label="Clone ${X(x.name)}" title="Clone (copy with a new port)">${I('copy',15)}</button><button data-ib="edit" data-id="${x.id}" aria-label="Edit ${X(x.name)}" title="Edit">${I('pen',15)}</button><button class="dng" data-ib="del" data-id="${x.id}" aria-label="Delete ${X(x.name)}" title="Delete">${I('del',15)}</button></span></td></tr>`).join('')||`<tr><td colspan="7" class="note" style="padding:18px">${L.length?'Nothing matches the search.':'No inbounds yet. Press Add Inbound to make your first V2Ray config. V2Ray users get their configs from the inbounds you make here.'}</td></tr>`}
</tbody></table></div></div>`;
$('#iba').onclick=()=>ibmodal(null);
if($('#ibqa'))$('#ibqa').onclick=async()=>{if(!confirm('Are you sure?\n\nThis adds 7 inbounds (VLESS / Trojan · TCP Vision, WS, HTTPUpgrade, XHTTP, Reality) on free ports from 20001. Your own inbounds are not changed.\n\nOpen ports 20001-20007 in your provider firewall too.'))return;const b=$('#ibqa');b.disabled=true;toast('Adding... (checks ports and the Reality target)');
try{const r=await api('api/inbound/quick',{});IBH='';await load();alert((r.added.length?'Added:\n'+r.added.join('\n'):'Nothing added.')+(r.skipped.length?'\n\nSkipped:\n'+r.skipped.join('\n'):'')+'\n\nGive them to users in Edit user → Inbounds.')}catch(x){toast(x.message,1)}b.disabled=false};
if($('#ibqd'))$('#ibqd').onclick=async()=>{const n=(D.ibs||[]).filter(x=>x.qk);if(!confirm('Are you sure to remove all 1-click inbounds?\n\n'+n.map(x=>'• '+x.name+' :'+x.port).join('\n')+'\n\nOnly these '+n.length+' are removed. Your own inbounds stay.'))return;try{const r=await api('api/inbound/quickdel',{});toast(r.removed+' inbound(s) removed');IBH='';load()}catch(x){toast(x.message,1)}};
$('#ibq').oninput=e=>{IBQ=e.target.value;const p=e.target.selectionStart;IBH='';ibp(true);const q=$('#ibq');q.focus();q.setSelectionRange(p,p)}}
let IBQ='';
function ibmenu(b){const x=(D.ibs||[]).find(y=>y.id==b.dataset.ibm);if(!x)return;let m=$('#ibpop');if(m)m.remove();const i=(D.ibs||[]).indexOf(x);
m=document.createElement('div');m.id='ibpop';m.className='ibpop';m.setAttribute('role','menu');
m.innerHTML=`<button role="menuitem" data-ib="edit" data-id="${x.id}">${I('pen',14)}Edit</button><button role="menuitem" data-ib="up" data-id="${x.id}"${i?'':' disabled'}>${I('up',14)}Move up</button><button role="menuitem" data-ib="down" data-id="${x.id}"${i<D.ibs.length-1?'':' disabled'}>${I('down',14)}Move down</button><button role="menuitem" class="dng" data-ib="del" data-id="${x.id}">${I('del',14)}Delete</button>`;
document.body.append(m);const r=b.getBoundingClientRect();m.style.top=(window.scrollY+r.bottom+4)+'px';m.style.left=Math.max(8,Math.min(window.innerWidth-m.offsetWidth-8,r.left))+'px';m.querySelector('button').focus()}
document.addEventListener('click',e=>{const mb=e.target.closest('[data-ibm]');if(mb){e.stopPropagation();return ibmenu(mb)}const p=$('#ibpop');if(p&&!e.target.closest('#ibpop'))p.remove()},true);
document.addEventListener('click',e=>{const b=e.target.closest('[data-ib]');if(!b||pg!='ib')return;if($('#ibpop'))$('#ibpop').remove();const x=(D.ibs||[]).find(y=>y.id==b.dataset.id);if(!x)return;const a=b.dataset.ib;
if(a=='edit')return ibmodal(x);
if(a=='port')return ibPort(x.id);
if(a=='clone')return ibmodal(x,true);
if(a=='del'){if(!confirm('Delete the inbound "'+x.name+'"?\n\n'+x.users+' user(s) lose this config.'+(x.b?' You can add the default inbounds back later.':'')))return}
if(a=='tog'&&x.on&&x.users&&!confirm('Turn off "'+x.name+'"? '+x.users+' user(s) lose this config until you turn it on again.'))return;
api('api/inbound/'+({tog:'toggle',up:'move',down:'move'}[a]||a),{id:x.id,name:x.name,dir:a}).then(()=>{toast(a=='del'?'Inbound deleted':a=='tog'?(x.on?'Turned off':'Turned on'):'Saved');IBH='';load()}).catch(x=>toast(x.message,1))});
async function ibPort(id){const x=(D.ibs||[]).find(y=>y.id==id);if(!x)return;const f=$('#mf');f.className='card ibx';
const show=r=>{const L=(ok,t,h)=>`<div class="pck ${ok==null?'w':ok?'ok':'no'}"><b>${ok==null?'…':ok?'✓':'✕'}</b><div><span>${t}</span>${h?`<small>${h}</small>`:''}</div></div>`;
f.innerHTML=`<div class="ixh"><h2>Port ${x.port} · ${X(x.name)}</h2><button type="button" class="ixc" id="pcx" aria-label="Close">×</button></div><div style="margin-top:14px">${r?
L(r.listen,'Xray is listening on '+x.port,r.listen?'':'Turn the inbound on, or check Xray in the Overview page.')+
L(r.fw=='closed'?false:true,'Server firewall (ufw): '+(r.fw=='off'?'off':r.fw),r.fw=='closed'?'Press Open below.':'')+
(r.out.err?L(null,'From the internet: not checked',X(r.out.err)):L(r.out.ok>0,'From the internet: '+r.out.ok+' of '+r.out.n+' countries can connect',r.out.ok?'':'Open TCP '+x.port+' in your provider panel (for example DeluxHost → Anti-DDoS / Firewall). Use type TLS / HTTPS, not SSH or Game.'))
:L(null,'Checking from 3 countries... about 10 seconds')}</div><div class="mr">${r&&r.fw=='closed'?`<button type="button" class="btn" id="pco">Open in ufw</button>`:''}${r?`<button type="button" class="btn" id="pcr">Check again</button>`:''}<button type="button" class="btn pri" id="pcc">OK</button></div>`;
$('#pcx').onclick=$('#pcc').onclick=()=>$('#md').hidden=true;if($('#pcr'))$('#pcr').onclick=()=>ibPort(id);
if($('#pco'))$('#pco').onclick=async()=>{try{await api('api/fw-open',{port:x.port,proto:'tcp'});ibPort(id)}catch(e){toast(e.message,1)}}};
f.onsubmit=e=>e.preventDefault();show(null);$('#md').hidden=false;
try{const r=await api('api/ib-portcheck',{id});if(!$('#md').hidden&&$('#pcx'))show(r)}catch(e){toast(e.message,1);$('#md').hidden=true}}
function ibmodal(x,cl){const ed=!!x&&!cl,b=ed&&x.b,h4=D.h443&&D.h443.on;
const DEF={name:'',proto:'vless',port:'',net:'xhttp',cdn:false,sec:'tls',sni:'',target:'',addr:'',host:'',path:'',fp:'chrome',alpn:'',on:true,xmode:'auto',svc:'',multi:true,obfs:false,obhost:'',obpath:'/',hb:0,hdrs:[],tfo:false,frag:{},minv:'',maxv:'',rsni:false,ech:false,flow:'',sids:[],snix:[],spx:'',sniff:{on:false,dest:['http','tls'],ro:false},ext:[],cmode:'panel',cfile:'',kfile:'',ccrt:'',ckey:'',venc:'',lfb:{},rw:{}};
let S=JSON.parse(JSON.stringify(Object.assign({},DEF,x?Object.fromEntries(Object.keys(DEF).map(k=>[k,x[k]??DEF[k]])):{})));
if(x&&x.b=='reality')S.sni=x.sni;if(cl){const taken=new Set((D.ibs||[]).map(y=>+y.port));let p=+x.port>1024?+x.port+1:20101;while(taken.has(p)||p==80||p==443)p++;S.name=x.name+' copy';S.port=String(p);S.on=true;S.flowT=true}S.fon=!!(S.frag&&S.frag.on);S.frag=Object.assign({packets:'tlshello',lengths:'100-200',delays:'10-20'},S.frag||{});if(x&&x.addr&&!S.ext.length)S.ext=[{addr:x.addr,port:'',remark:'Address'}];if(!['tcp','xhttp','ws','httpupgrade'].includes(S.net))S.net='xhttp';if(S.proto=='vmess')S.proto='vless';S.exon=S.ext.length>0;S.lfb=Object.assign({on:false,after:1024,rate:100},S.lfb||{});S.rw=Object.assign({on:false,spares:[]},S.rw||{});S.flowT=ed;
let tab=0,USED=null,BT=null,SCAN=null,FIND=null;const f=$('#mf');f.className='card wide ibx';
api('api/inbound/ports',{}).then(r=>{USED=r.used}).catch(()=>{});
const mainp=()=>S.net=='ws'?(D.set.wspath||'/vws'):(D.set.path||'/vless'),p4=()=>+S.port==80||+S.port==443,canR=()=>!S.cdn&&!['ws','httpupgrade'].includes(S.net),canF=()=>S.proto=='vless'&&S.net=='tcp'&&!S.obfs&&S.sec!='none'&&!S.cdn;
const NETL={tcp:'TCP',xhttp:'XHTTP',ws:'WebSocket',httpupgrade:'HTTPUpgrade'},PRL={vless:'VLESS',trojan:'Trojan'};
function fix(){if(S.net=='tcp')S.cdn=false;if(S.sec=='reality'&&!canR())S.sec='tls';if(S.cdn)S.ech=false;if(!canF())S.flow='';else if(S.sec=='reality'&&!S.flowT)S.flow='vision';else if(!S.flowT)S.flow='';if(S.net!='tcp')S.obfs=false}
const hlp=t=>t?` <span class="q" title="${X(t)}" tabindex="0" aria-label="${X(t)}">?</span>`:'';
const row=(lab,ctl,h,id)=>`<div class="ir"><label${id?` for="${id}"`:''}>${lab}${hlp(h)}</label><div class="ic">${ctl}</div></div>`;
const nt=t=>`<div class="ir"><span></span><p class="note">${t}</p></div>`;
const sw=(k,on,dis)=>`<button type="button" class="sw${on?' on':''}" data-sw="${k}" role="switch" aria-checked="${!!on}"${dis?' disabled':''}><i></i></button>`;
const inp=(k,v,ph,dis,cls)=>`<input id="ib_${k}" data-k="${k}" class="${cls||''}" value="${X(v??'')}" placeholder="${X(ph||'')}" autocomplete="off" autocapitalize="none" spellcheck="false"${dis?' disabled':''}>`;
const sel=(k,opts,v)=>`<select id="ib_${k}" data-k="${k}">${opts.map(o=>{const[a,t]=Array.isArray(o)?o:[o,o];return `<option value="${X(a)}"${String(v)==String(a)?' selected':''}>${X(t)}</option>`}).join('')}</select>`;
const seg=(k,opts,v)=>`<div class="iseg" role="radiogroup">${opts.map(([a,t,dis])=>`<button type="button" data-seg="${k}" data-v="${a}" class="${v==a?'on':''}" role="radio" aria-checked="${v==a}"${dis?' disabled':''}>${t}</button>`).join('')}</div>`;
const chips=(k,L,ph,gen)=>`<div class="chips" data-ck="${k}">${L.map((v,i)=>`<span class="ichip">${X(v||'(empty)')}<button type="button" data-cdel="${k}" data-i="${i}" aria-label="Remove ${X(v)}">×</button></span>`).join('')}<input data-cadd="${k}" placeholder="${X(ph)}" autocomplete="off" autocapitalize="none" spellcheck="false">${gen?`<button type="button" class="cg" data-cgen="${k}" title="Make a new one" aria-label="Make a new one">↻</button>`:''}</div>`;
const tog=(k,opts,cur)=>`<div class="tgs">${opts.map(([a,t])=>`<button type="button" data-tg="${k}" data-v="${a}" class="${cur.includes(a)?'on':''}" aria-pressed="${cur.includes(a)}">${t}</button>`).join('')}</div>`;
const hex=n=>[...crypto.getRandomValues(new Uint8Array(n))].map(v=>v.toString(16).padStart(2,'0')).join('');
const rnd=n=>{const a='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';return [...crypto.getRandomValues(new Uint8Array(n))].map(v=>a[v%a.length]).join('')};
function alD(){return S.net=='xhttp'||S.net=='tcp'?['h2','http/1.1']:['http/1.1']}
function alOK(){return h4&&p4()?['http/1.1']:['h2','http/1.1']}
function alNeed(){return h4&&p4()||['ws','httpupgrade'].includes(S.net)?['http/1.1']:[]}
function alCur(){const ok=alOK();let a=(S.alpn?S.alpn.split(','):alD()).filter(v=>ok.includes(v));alNeed().forEach(v=>{if(!a.includes(v))a.push(v)});if(!a.length)a=ok.slice();return ['h2','http/1.1'].filter(v=>a.includes(v))}
function pnote(){const p=+S.port;if(S.cdn)return 'Cloudflare ports: '+(S.sec=='tls'?'443, 2053, 2083, 2087, 2096, 8443':'80, 8080, 8880, 2052, 2082, 2086, 2095');if(p==443||p==80)return h4?'Goes through 443 mode (HAProxy): only plain VLESS XHTTP / WS and VLESS / Trojan TCP+TLS work here.':'Ports 80 and 443 need 443 mode (Settings → Network ports).';return 'Any free port.'+(h4?' 80 / 443 work in 443 mode for plain configs.':'')}
function tBasic(){return row('Enabled',sw('on',S.on))+row('Remark',inp('name',S.name,''),'',"ib_name")+
row('Protocol',sel('proto',[['vless','vless'],['trojan','trojan']],S.proto),'','ib_proto')+
row('Port',inp('port',S.port,'','','sm'),pnote(),'ib_port')+(S.proto=='vless'&&!b?row('Encryption',seg('venc',[['','None'],['x25519','X25519'],['mlkem','ML-KEM-768']],S.venc),'VLESS Encryption: VLESS encrypts by itself, also without TLS. Needs a new app (v2rayNG 1.10+, Xray 25.9+). X25519 = short link. ML-KEM-768 = post-quantum, but a very long link. Not on 80 / 443 (443 mode).'):'')}
function tStream(){const hd=S.cdn?((D.cdn&&D.cdn.dom)||'CDN domain'):(D.set.host||D.cert.domain||D.addr||'default');let h=row('Transmission',sel('net',Object.entries(NETL),S.net),'','ib_net');
if(S.net!='tcp')h+=row('Through CDN',sw('cdn',S.cdn),'Users connect to Cloudflare, Cloudflare connects to this server. Set the CDN domain in Settings → CDN.');
const hp=(lab)=>row('Host',inp('host',S.host,'empty = '+hd),'','ib_host')+(S.net=='grpc'?'':row('Path',inp('path',p4()?'':S.path,mainp(),p4()),p4()?'On 80 / 443 (443 mode) the main path is used.':'Empty = '+mainp(),'ib_path'));
if(S.net=='tcp'){h+=row('HTTP Obfuscation',sw('obfs',S.obfs,S.sec=='reality'),'Makes TCP look like plain HTTP requests. Not with Reality.');if(S.obfs)h+=row('Host',inp('obhost',S.obhost,'Like: m.facebook.com'),'','ib_obhost')+row('Path',inp('obpath',S.obpath,'/'),'','ib_obpath')}
if(S.net=='xhttp')h+=hp()+row('Mode',sel('xmode',['auto','packet-up','stream-up','stream-one'],S.xmode),'auto is best. packet-up works through every CDN.','ib_xmode');
if(S.net=='ws')h+=hp()+row('Heartbeat Period',inp('hb',S.hb||'','0','','sm'),'Keeps idle WebSocket open. 0 = off.','ib_hb')+hdrs();
if(S.net=='httpupgrade')h+=hp()+hdrs();
h+=row('TCP Fast Open',sw('tfo',S.tfo),'Saves one round trip when connecting. Linux turns it on for the server.')+
row('Fragment',sw('fon',S.fon),'Splits the TLS hello into small pieces. Mostly a client setting: the JSON subscription has its own (Settings → Xray).');
if(S.fon)h+=row('Packets',inp('f_packets',S.frag.packets,'tlshello'),'','ib_f_packets')+row('Lengths',inp('f_lengths',S.frag.lengths,'100-200'),'','ib_f_lengths')+row('Delays',inp('f_delays',S.frag.delays,'10-20'),'','ib_f_delays');
return h}
function hdrs(){return row('Headers',`<div class="kvl">${S.hdrs.map((v,i)=>`<div class="kvr"><input data-hk="${i}" value="${X(v[0])}" placeholder="Name" autocapitalize="none"><input data-hv="${i}" value="${X(v[1])}" placeholder="Value" autocapitalize="none"><button type="button" class="rm" data-hdel="${i}" aria-label="Remove header">${I('del',14)}</button></div>`).join('')}<button type="button" class="addb" id="ibhadd">${I('plus',13)}Add header</button></div>`,'Extra HTTP headers the server sends. Host goes in the Host box.')}
function tSec(){const R=canR();let h=row('Security',seg('sec',[['none','None'],['tls','TLS'],['reality','Reality',!R]],S.sec));
const flow=canF()?row('Flow',seg('flow',[['','None'],['vision','xtls-rprx-vision']],S.flow),'Vision: fastest for VLESS TCP. Needs its own port (not 80 / 443).'):'';
const FPL=[['chrome','chrome (best)'],'firefox','safari','edge','ios','android','random','randomized'].concat(S.sec=='tls'?[['none','none (Go default)']]:[]);
if(S.sec=='tls'){const a=alCur(),ok=alOK(),nd=alNeed();
h+=row('SNI',inp('sni',S.sni,'empty = '+(S.cdn?(D.cdn&&D.cdn.dom)||'CDN domain':D.set.sni||D.cert.domain||'auto')),'','ib_sni')+
row('Min / Max Version',`<div class="two">${sel('minv',[['','Min: auto'],'1.0','1.1','1.2','1.3'],S.minv)}${sel('maxv',[['','Max: auto'],'1.0','1.1','1.2','1.3'],S.maxv)}</div>`,'TLS versions the server accepts. Auto is fine.')+
row('uTLS',sel('fp',FPL,S.fp),'How the app\'s TLS hello looks. chrome is best.','ib_fp')+
row('ALPN',`<div class="tgs">${['h2','http/1.1'].map(v=>`<button type="button" data-tg="alpn" data-v="${v}" class="${a.includes(v)?'on':''}" aria-pressed="${a.includes(v)}"${!ok.includes(v)||nd.includes(v)&&a.includes(v)||a.length==1&&a[0]==v?' disabled':''}>${v}</button>`).join('')}</div>`,h4&&p4()?'Port '+S.port+' (443 mode) works with http/1.1.':['ws','httpupgrade'].includes(S.net)?'WebSocket and HTTPUpgrade need http/1.1.':'At least one is needed.')+flow+
row('Reject Unknown SNI',sw('rsni',S.rsni),'Closes connections that ask for a name not on your certificate.')+
certRows()+row('ECH',sw('ech',S.ech,S.cdn),'Encrypted Client Hello: hides the SNI. Needs TLS 1.3 and an app with ECH (new v2rayNG, Hiddify). Keys are made by the panel.')}
if(S.sec=='reality'){const all=[S.sni,...S.snix].filter(v=>v);
h+=row('uTLS',sel('fp',FPL,S.fp),'','ib_fp')+
row('Target',`<div class="tgt">${inp('target',S.target,(S.sni||'www.microsoft.com')+':443')}<button type="button" class="btn sm" id="ibscan">${SCAN&&SCAN.run?'Scanning...':'Scan'}</button><button type="button" class="btn sm" id="ibfind">${I('search',13)}Find Targets</button></div>`,'A real big site with TLS 1.3. Scan checks it, Find Targets checks a list of sites.')+
(SCAN&&!SCAN.run?`<div class="ir"><span></span>${scanBox()}</div>`:'')+
row('SNI',chips('sni',all,all.length?'add name':'Like: www.microsoft.com'),'Names the apps can use. The first one goes in the links. Scan fills them from the site certificate.')+
row('Short IDs',chips('sids',S.sids,S.sids.length?'':'empty = panel default',1),'Up to 8, hex, even length. The first one goes in the links.')+
rwRows()+row('Limit Fallback',sw('lfb_on',S.lfb.on),'Slows down people who connect without your key (scanners, probes), so nobody can use your server as a free proxy to the target site.')+(S.lfb.on?row('After (KB)',inp('lfb_after',S.lfb.after,'1024','','sm'),'Full speed for the first KB, then slow.','ib_lfb_after')+row('Speed (KB/s)',inp('lfb_rate',S.lfb.rate,'100','','sm'),'','ib_lfb_rate'):'')+row('SpiderX',`<div class="tgt nw">${inp('spx',S.spx,'Like: /abc (optional)')}<button type="button" class="cg" id="ibspx" title="Make a new one" aria-label="Make a new SpiderX">↻</button></div>`,'Optional path the app crawls on the target site.')+flow}
return h}
function certRows(){if(S.cmode=='panel'){S.cmode='path';S.cfile=D.cpath[0];S.kfile=D.cpath[1]}const m=S.cmode;let h=row('Certificate',seg('cmode',[['path','File Path'],['content','File Content']],m),'Set Cert from Panel = your panel certificate (renews by itself). Another file only for another domain.');
if(m=='path')h+=row('Public Key',inp('cfile',S.cfile,'/root/cert/fullchain.pem'),'','ib_cfile')+row('Private Key',inp('kfile',S.kfile,'/root/cert/privkey.pem'),'','ib_kfile');
if(m=='content')h+=row('Public Key',`<textarea id="ib_ccrt" data-k="ccrt" class="ita" spellcheck="false" placeholder="-----BEGIN CERTIFICATE-----">${X(S.ccrt)}</textarea>`,'','ib_ccrt')+row('Private Key',`<textarea id="ib_ckey" data-k="ckey" class="ita" spellcheck="false" placeholder="${x&&x.ckey_set&&!S.ckey?'Saved (hidden). Paste a new key to change it.':'-----BEGIN PRIVATE KEY-----'}">${X(S.ckey)}</textarea>`,'','ib_ckey');
return h+row('',`<div style="display:flex;gap:8px;flex-wrap:wrap"><button type="button" class="btn pri" id="ibcp" style="white-space:nowrap">Set Cert from Panel</button><button type="button" class="btn cdl" id="ibcc">Clear</button></div>`)}
function rwRows(){let h=row('Reality Watch',sw('rw_on',S.rw.on),'Keep Reality working: the panel checks the target every 10 minutes. After 3 failed checks in a row it switches to the first spare target that works and sends you a Telegram message. Users then refresh their subscription.');
if(!S.rw.on)return h;h+=row('Spare targets',chips('spares',S.rw.spares,S.rw.spares.length?'add site':'Like: www.samsung.com'),'Big sites with TLS 1.3. Find Targets → "Spare" adds them here.');
const st=ed?((D.rw&&D.rw[x.id])||{fresh:1}):null;if(st){const ago=st.last?Math.max(0,Math.round((Date.now()/1000-st.last)/60)):null;
h+=`<div class="ir"><span></span><div class="rws ${st.ok?'ok':'no'}${st.fresh?' fr':''}"><b>${st.fresh?'Not checked yet':st.ok?'✓ Working':'✕ Not answering ('+(st.fails||0)+' of 3)'}</b> · ${X(st.cur||'')}${ago!=null?' · checked '+ago+' min ago':''}${(st.hist||[]).slice(-3).reverse().map(h_=>`<small>${new Date(h_[0]*1000).toLocaleString()} · ${X(h_[1])}</small>`).join('')}<div style="display:flex;gap:6px;margin-top:6px"><button type="button" class="btn sm" id="rwc">Check now</button><button type="button" class="btn sm" id="rws">Switch now</button></div></div></div>`}
return h}
function scanBox(){const r=SCAN;if(!r.ok)return `<div class="scb bad"><b>✕ Not good for Reality</b><div><span>Target</span><span>${X(r.target||'')}</span></div><p>${X(r.err||'No answer')}</p></div>`;
const kv=(k,v)=>v?`<div><span>${k}</span><span>${X(v)}</span></div>`:'';
return `<div class="scb"><b>${I('check',14)} Works for Reality</b>${kv('SNI used',r.sni)}${kv('TLS',r.tls.replace('TLSv',''))}${kv('ALPN',r.alpn||'none')}${kv('Cipher',r.cipher)}${kv('Certificate',r.cn)}${kv('Issuer',r.issuer)}${kv('Expires',r.exp?(r.exp+' ('+r.days+' days)'):'')}${kv('Latency',r.ms+' ms')}${r.h2?'':'<p>No HTTP/2. It works, but a site with h2 looks more normal.</p>'}</div>`}
function tSniff(){const sn=S.sniff;return row('Enabled',sw('sn_on',sn.on),'Reads the site name from the traffic, so routing (WARP, ad block) works by domain.')+
(sn.on?row('Sniff',tog('sn',[['http','HTTP'],['tls','TLS'],['quic','QUIC'],['fakedns','FAKEDNS']],sn.dest))+row('Route only',sw('sn_ro',sn.ro),'Use the name only for routing, connect to the original IP. Safer for some apps.'):'')}
function tAdv(){return row('External Proxy',sw('exon',S.exon),'Extra addresses for the same inbound, like Cloudflare IPs or another domain. Every line becomes its own link.')+
(S.exon?`<div class="exl">${S.ext.map((e,i)=>`<div class="exr"><input data-ea="${i}" value="${X(e.addr)}" placeholder="Address (IP or domain)" autocapitalize="none" spellcheck="false" aria-label="Address"><input data-ep="${i}" value="${X(e.port||'')}" placeholder="${X(S.port||'port')}" inputmode="numeric" aria-label="Port"><input data-er="${i}" value="${X(e.remark||'')}" placeholder="Remark" aria-label="Remark"><button type="button" class="rm" data-edel="${i}" aria-label="Remove">${I('del',14)}</button></div>`).join('')}<button type="button" class="addb" id="ibeadd">${I('plus',13)}Add</button></div>`:'')}
function draw(){fix();const T=['Basics','Stream','Security','Sniffing','Advanced'];const body=[tBasic,tStream,tSec,tSniff,tAdv][tab]();
f.innerHTML=`<div class="ixh"><h2>${ed?'Edit '+X(x.name):cl?'Clone '+X(x.name):'Add Inbound'}</h2><button type="button" class="ixc" id="mc2" aria-label="Close">×</button></div><div id="ibban" aria-live="polite"></div>
<div class="ixt" role="tablist">${T.map((t,i)=>`<button type="button" role="tab" class="${i==tab?'on':''}" aria-selected="${i==tab}" data-t="${i}">${t}</button>`).join('')}</div><div class="ixb">${body}</div>
<div class="err" id="me"></div><div class="mr"><button type="button" class="btn" id="mc">Close</button><button class="btn pri">${ed?'Save':'Create'}</button></div>${FIND?findPop():''}`;
wire()}
function findPop(){const F=FIND;return `<div class="fpo" role="dialog" aria-label="Reality Target Finder"><div class="fpc"><div class="ixh"><h2 style="font-size:16px">Reality Target Finder</h2><button type="button" class="ixc" id="fpx" aria-label="Close">×</button></div>
<div class="tgt" style="margin:8px 0"><input id="fpe" placeholder="Extra domains (optional)" value="${X(F.extra||'')}" autocapitalize="none"><button type="button" class="btn sm pri" id="fps"${F.run?' disabled':''}>${F.run?'Checking...':'Scan'}</button></div>
${F.run?'<p class="note">Checking...</p>':F.err?`<p class="err">${X(F.err)}</p>`:F.res?`<div class="fpt"><table><thead><tr><th>Target</th><th class="fst">Status</th><th>Latency</th><th></th></tr></thead><tbody>${F.res.map(r=>`<tr><td><b>${X(r.d)}</b><small class="m">${r.ok?'TLS 1.3 · '+(r.h2?'h2':'http/1.1'):X(r.err||'no TLS 1.3')}</small></td><td class="fst">${r.ok?'<span class="fok">Works</span>':'<span class="fno">No</span>'}</td><td>${r.ok?r.ms+' ms':'-'}</td><td>${r.ok?`<button type="button" class="btn sm pri" data-use="${X(r.d)}">Use</button>${S.rw.on?` <button type="button" class="btn sm" data-spare="${X(r.d)}"${S.rw.spares.includes(r.d)?' disabled':''}>Spare</button>`:''}`:''}</td></tr>`).join('')}</tbody></table></div>`:''}</div></div>`}
function wire(){const q=s=>f.querySelectorAll(s);
$('#mc').onclick=$('#mc2').onclick=()=>$('#md').hidden=true;
q('[data-t]').forEach(z=>z.onclick=()=>{rd_();tab=+z.dataset.t;draw()});
q('[data-sw]').forEach(z=>z.onclick=()=>{rd_();const k=z.dataset.sw,v=!z.classList.contains('on');if(k=='sn_on')S.sniff.on=v;else if(k=='sn_ro')S.sniff.ro=v;else if(k=='lfb_on')S.lfb.on=v;else if(k=='rw_on')S.rw.on=v;else{S[k]=v;if(k=='exon'&&v&&!S.ext.length)S.ext.push({addr:'',port:'',remark:''})}draw()});
q('[data-seg]').forEach(z=>z.onclick=()=>{rd_();const k=z.dataset.seg;S[k]=z.dataset.v;if(k=='flow')S.flowT=true;if(k=='sec'){SCAN=null;if(S.sec=='reality'&&!S.sni)S.sni=D.set.rsni||''}draw()});
q('select[data-k]').forEach(z=>z.onchange=()=>{rd_();if(z.dataset.k=='net'){S.alpn='';SCAN=null}draw()});
q('[data-tg]').forEach(z=>z.onclick=()=>{rd_();const k=z.dataset.tg,v=z.dataset.v;if(k=='alpn'){let a=alCur();a=a.includes(v)?a.filter(y=>y!=v):a.concat(v);if(!a.length)return;S.alpn=['h2','http/1.1'].filter(y=>a.includes(y)).join(',')}else{const d=S.sniff.dest;S.sniff.dest=d.includes(v)?d.filter(y=>y!=v):d.concat(v)}draw()});
q('[data-cdel]').forEach(z=>z.onclick=()=>{rd_();const k=z.dataset.cdel,i=+z.dataset.i;if(k=='sids')S.sids.splice(i,1);else if(k=='spares')S.rw.spares.splice(i,1);else{const all=[S.sni,...S.snix].filter(v=>v);all.splice(i,1);S.sni=all[0]||'';S.snix=all.slice(1)}draw()});
q('[data-cadd]').forEach(z=>{z.onkeydown=e=>{if(e.key=='Enter'||e.key==','||e.key==' '){e.preventDefault();rd_();addChip(z.dataset.cadd,z.value);draw();const n=f.querySelector(`[data-cadd="${z.dataset.cadd}"]`);n&&n.focus()}};z.onblur=()=>{if(z.value.trim()){rd_();addChip(z.dataset.cadd,z.value);draw()}}});
q('[data-cgen]').forEach(z=>z.onclick=()=>{rd_();if(S.sids.length<8)S.sids.push(hex([1,2,3,4,8][Math.floor(Math.random()*5)]));draw()});
if($('#ibspx'))$('#ibspx').onclick=()=>{rd_();S.spx='/'+rnd(12);draw()};
q('[data-hdel]').forEach(z=>z.onclick=()=>{rd_();S.hdrs.splice(+z.dataset.hdel,1);draw()});if($('#ibhadd'))$('#ibhadd').onclick=()=>{rd_();S.hdrs.push(['','']);draw()};
q('[data-edel]').forEach(z=>z.onclick=()=>{rd_();S.ext.splice(+z.dataset.edel,1);if(!S.ext.length)S.exon=false;draw()});if($('#ibeadd'))$('#ibeadd').onclick=()=>{rd_();S.ext.push({addr:'',port:'',remark:''});draw()};
if($('#ibscan'))$('#ibscan').onclick=()=>{rd_();scan()};
if($('#ibcp'))$('#ibcp').onclick=()=>{rd_();S.cmode='path';S.cfile=D.cpath[0];S.kfile=D.cpath[1];S.ccrt=S.ckey='';draw()};if($('#ibcc'))$('#ibcc').onclick=()=>{rd_();S.cfile=S.kfile=S.ccrt=S.ckey='';draw()};
if($('#ibfind'))$('#ibfind').onclick=()=>{rd_();FIND=FIND||{};draw();if(!FIND.res&&!FIND.run)find()};
if($('#fpx'))$('#fpx').onclick=()=>{FIND=null;draw()};if($('#fps'))$('#fps').onclick=()=>{FIND.extra=$('#fpe').value;find()};
q('[data-spare]').forEach(z=>z.onclick=()=>{addChip('spares',z.dataset.spare);draw()});
if($('#rwc'))$('#rwc').onclick=async()=>{rd_();try{const r=await api('api/rwatch',{a:'check',id:x.id});D.rw=r.rw;toast('Checked')}catch(e){toast(e.message,1)}draw()};
if($('#rws'))$('#rws').onclick=async()=>{if(!confirm('Switch to the first spare target that works now?'))return;rd_();try{const r=await api('api/rwatch',{a:'switch',id:x.id});D.rw=r.rw;toast('Done');await load();$('#md').hidden=true}catch(e){toast(e.message,1)}};
q('[data-use]').forEach(z=>z.onclick=()=>{const d=z.dataset.use;S.target=d+':443';S.sni=d;S.snix=[];FIND=null;scan()});
if($('#ib_port'))$('#ib_port').oninput=()=>{S.port=$('#ib_port').value.trim();clearTimeout(ibmodal.pt);ibmodal.pt=setTimeout(()=>{const u=pused();ban(u?u.t:'',u&&u.w)},350)};
const fz=f.querySelector('.ixb input:not([disabled]),.ixb select');if(tab==0&&!ed&&fz)fz.focus()}
function addChip(k,v){const L=v.split(/[\s,]+/).map(y=>y.trim().toLowerCase()).filter(y=>y);if(k=='spares'){L.forEach(y=>{y=y.replace(/:443$/,'');if(!S.rw.spares.includes(y)&&S.rw.spares.length<10)S.rw.spares.push(y)});return}if(k=='sids')L.forEach(y=>{if(!S.sids.includes(y)&&S.sids.length<8)S.sids.push(y)});else L.forEach(y=>{if(y!=S.sni&&!S.snix.includes(y)){if(!S.sni)S.sni=y;else S.snix.push(y)}})}
async function scan(){const t=S.target||(S.sni?S.sni+':443':'');if(!t){ban('Write a target first, like www.microsoft.com:443');return}SCAN={run:1};draw();
try{const r=await api('api/rscan',{target:t,sni:S.sni&&!S.target?S.sni:(S.sni||t.split(':')[0])});SCAN=r;if(r.ok){const h=t.split(':')[0];if(!S.target)S.target=r.target;if(S.sni!=h){S.sni=h;S.snix=[]}const nm=(r.names||[]).filter(n=>!n.includes('*')&&n!=S.sni&&!S.snix.includes(n));S.snix=S.snix.concat(nm).slice(0,4)}}catch(e){SCAN={ok:false,target:t,err:e.message}}draw()}
async function find(){FIND={run:1,extra:FIND&&FIND.extra||''};draw();try{const r=await api('api/rtargets',{extra:FIND.extra});FIND=Object.assign(FIND,{run:0,res:r.res})}catch(e){FIND=Object.assign(FIND,{run:0,err:e.message})}if(FIND)draw()}
function rd_(){f.querySelectorAll('input[data-k],select[data-k],textarea[data-k]').forEach(z=>{if(z.disabled)return;const k=z.dataset.k,v=k=='name'?z.value:z.value.trim();if(k.startsWith('f_'))S.frag[k.slice(2)]=v;else if(k.startsWith('lfb_'))S.lfb[k.slice(4)]=v;else if(k=='hb')S.hb=+v||0;else S[k]=v});
f.querySelectorAll('[data-hk]').forEach(z=>S.hdrs[+z.dataset.hk][0]=z.value.trim());f.querySelectorAll('[data-hv]').forEach(z=>S.hdrs[+z.dataset.hv][1]=z.value.trim());
f.querySelectorAll('[data-ea]').forEach(z=>S.ext[+z.dataset.ea].addr=z.value.trim());f.querySelectorAll('[data-ep]').forEach(z=>S.ext[+z.dataset.ep].port=z.value.trim());f.querySelectorAll('[data-er]').forEach(z=>S.ext[+z.dataset.er].remark=z.value.trim());
f.querySelectorAll('[data-cadd]').forEach(z=>{if(z.value.trim()){addChip(z.dataset.cadd,z.value);z.value=''}})}
function ban(t,w){const el=$('#ibban');if(!el)return;clearTimeout(BT);el.innerHTML=t?`<div class="ibban${w?' w':''}">${X(t)}</div>`:'';if(t)BT=setTimeout(()=>{const d=el.firstChild;if(d){d.classList.add('hide');setTimeout(()=>{if(el.firstChild===d)el.innerHTML=''},450)}},3500)}
function pused(){const p=String(+S.port);if(!USED||!/^\d+$/.test(String(S.port))||(ed&&+S.port==+x.port))return null;const o=USED[p];if(!o)return null;return o.startsWith('inbound: ')?{w:1,t:'Port '+p+' is used by the '+o+'. It works only if the new one has the same type.'}:{t:'Port '+p+' is already used by '+o+'. Pick another port.'}}
f.onsubmit=async e=>{e.preventDefault();if(FIND)return;rd_();
const bad=!String(S.name).trim()?'Give the inbound a name':!/^\d+$/.test(String(S.port))?'Type a port number':(()=>{const u=pused();return u&&!u.w?u.t:''})();
if(bad){if(tab!=0){tab=0;draw()}ban(bad);$('#me').textContent=bad;return}
const bt=f.querySelector('.pri');bt.disabled=true;const n=S.net,ph=!['tcp','grpc'].includes(n);
const d={name:S.name.trim(),proto:S.proto,port:S.port,net:n,cdn:S.cdn,sec:S.sec,sni:S.sec=='none'?'':S.sni,target:S.sec=='reality'?S.target:'',fp:S.fp,alpn:S.sec=='tls'?alCur().join(','):'',addr:'',host:n!='tcp'?S.host:'',path:ph&&!p4()?S.path:'',on:S.on,
xmode:S.xmode,svc:S.svc,multi:S.multi,obfs:S.obfs,obhost:S.obhost,obpath:S.obpath,hb:S.hb,hdrs:S.hdrs.filter(h=>h[0]||h[1]),tfo:S.tfo,frag:S.fon?Object.assign({on:true},S.frag):{},
minv:S.minv,maxv:S.maxv,rsni:S.rsni,ech:S.ech,flow:S.flow,sids:S.sids,snix:S.snix,spx:S.spx,sniff:S.sniff,venc:S.proto=='vless'?S.venc:'',lfb:S.sec=='reality'&&S.lfb.on?S.lfb:{},rw:S.sec=='reality'?S.rw:{},cmode:S.sec=='tls'?S.cmode:'panel',cfile:S.cfile,kfile:S.kfile,ccrt:S.ccrt,ckey:S.ckey,ext:S.exon?S.ext.filter(e=>e.addr):[]};
try{const rr=await api('api/inbound/'+(ed?'edit':'add'),ed?Object.assign(d,{id:x.id}):cl?Object.assign(d,{from:x.id}):d);$('#md').hidden=true;toast(ed?'Inbound saved':'Inbound created');IBH='';await load();if(!ed&&rr.id&&d.on&&+d.port!=80&&+d.port!=443)ibPort(rr.id)}catch(z){ban(z.message);$('#me').textContent=z.message}bt.disabled=false};
$('#md').hidden=false;draw()}

function showQR(t,v){$('#qrt').textContent=t;$('#qrn').textContent=/WireGuard/.test(t)?'Scan with the WireGuard app (+ → Scan from QR code)':'Scan with v2rayNG, NekoBox or Hiddify';try{$('#qrs').innerHTML=RXQR.svg(v,300)}catch(x){$('#qrs').innerHTML='<p class="note">'+X(x.message)+'</p>'}$('#qrm').hidden=false}
$('#qrm').onclick=e=>{if(e.target.id=='qrm'||e.target.closest('#qrx'))$('#qrm').hidden=true};
$('#md').onclick=e=>{if(e.target.id=='md')$('#md').hidden=true};
$('#pg').addEventListener('keydown',e=>{if(e.key=='Enter'&&e.target.matches('tr[data-open]'))openU(e.target.dataset.open)});document.addEventListener('keydown',e=>{if(e.key=='Escape'){if(!$('#sxo').hidden)$('#sxo').hidden=true;else if(!$('#shm').hidden)$('#shm').hidden=true;else if(!$('#qrm').hidden)$('#qrm').hidden=true;else $('#md').hidden?$('#dt').hidden=true:$('#md').hidden=true}});
const mbps=v=>{const m=v*8/1e6;return m>=1000?(m/1000).toFixed(2)+' Gbps':m.toFixed(m<10?2:0)+' Mbps'};
async function mload(){const kv=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;try{const m=await api('api/maint'),sw=m.swap;if(!$('#mti'))return;
$('#mti').innerHTML=kv('RAM',fb(m.ram))+kv('Swap',sw.total?fb(sw.total)+' ('+fb(sw.used)+' used)'+(sw.file?'':' · '+X(sw.other.join(', '))):'None')+kv('Free disk',fb(m.disk.free)+' of '+fb(m.disk.total))+kv('System logs',fb(m.logs))+kv('Package cache',fb(m.apt));
$('#swr').hidden=!sw.file;$('#swb').textContent=sw.file?'Change size':'Create swap'}catch(x){}}
async function lview(){const o=$('#lvo');if(!o)return;try{const r=await api('api/logview',{src:$('#lvs').value,n:+$('#lvn').value,q:$('#lvq').value}),end=o.scrollHeight-o.scrollTop-o.clientHeight<40;
o.textContent=r.lines.length?r.lines.join('\n'):'No lines'+($('#lvq').value?' match the filter':'');if(end||o.dataset.f!='1'){o.scrollTop=o.scrollHeight;o.dataset.f='1'}}catch(x){o.textContent=x.message}}
setInterval(()=>{const c=$('#lgc');if(pg=='st'&&c&&!c.classList.contains('tabx')&&$('#lva').checked&&!document.hidden)lview()},5000);
function tools2(){const s=D.set,xu=D.xup,dd=D.ddns,rf=D.tools.rfind;if(!$('#xui'))return;const kv=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
$('#xui').innerHTML=kv('Installed','v'+(D.xray.ver||'?'))+(xu.latest?kv('Latest on GitHub',xu.latest):'')+(xu.run?'<p class="note">Updating... about 30 seconds.</p>':xu.msg?`<p class="note">${X(xu.msg)}${xu.t?' · '+tago(xu.t):''}</p>`:'');$('#xun').disabled=$('#xuk').disabled=!!xu.run;
$('#ddi').innerHTML=dd.dom?(dd.t?`<p class="note" style="color:${dd.ok?'var(--g)':'var(--r)'}">${dd.ok?'Updated '+tago(dd.t)+(dd.ip?' · '+X(dd.ip):''):X(dd.msg)}</p>`:'<p class="note">Waiting for the first update...</p>'):'';
if(rf){$('#rfb').disabled=!!rf.run;const ok=(rf.res||[]).filter(r=>r.ok),bad=(rf.res||[]).filter(r=>!r.ok);
$('#rfr').innerHTML=rf.run?'<p class="note">Checking... about 15 seconds.</p>':ok.map(r=>`<div class="rk"><span class="nm"><b>${X(r.d)}</b><small class="m">${r.ms} ms${r.h2?' · HTTP/2':' · no HTTP/2'}</small></span>${r.d==s.rsni?'<span class="tag">Default</span>':`<button type="button" class="btn sm" data-rd="${X(r.d)}">Use</button>`}</div>`).join('')+(bad.length?`<p class="note" style="margin-top:8px">Not usable here: ${bad.map(r=>X(r.d)).join(', ')}</p>`:'')+(rf.t&&!rf.run?`<p class="note">Checked ${tago(rf.t)}</p>`:'')}}
function tools(){tools2();const t=D.tools,sp=t.speed;if(!$('#spr'))return;$('#stm').textContent=D.stime;
$('#spr').innerHTML=sp.run?'<p class="note">Testing... this takes about 20 seconds.</p>':sp.t?(sp.err?`<p class="err">${X(sp.err)}</p>`:`<div class="tl3"><div class="tile"><b>${mbps(sp.down)}</b><small>DOWNLOAD</small></div><div class="tile"><b>${mbps(sp.up)}</b><small>UPLOAD</small></div><div class="tile"><b>${sp.ping??'-'}</b><small>PING ms</small></div></div>${sp.srv?`<div class="kv" style="margin-top:8px"><span>Test server</span><b>${X(sp.srv)}</b></div>`:''}${sp.isp?`<div class="kv"><span>Provider</span><b>${X(sp.isp)}</b></div>`:''}${sp.jit!=null?`<div class="kv"><span>Jitter · packet loss</span><b>${sp.jit} ms · ${sp.loss!=null?(+sp.loss).toFixed(1)+' %':'-'}</b></div>`:''}${sp.note?`<p class="note" style="margin-top:6px">${X(sp.note)}</p>`:''}<p class="note" style="margin-top:6px">Tested ${tago(sp.t)}</p>`):'';
$('#spb').disabled=!!sp.run}
function stb(){tools();featTick();const b=$('#bkl');if(!b)return;const L=D.backups||[];b.innerHTML=L.length?`<p class="note" style="margin:12px 0 0">Automatic daily backups on the server (last 7): ${L.map(X).join(', ')}. Restore one with <b style="color:var(--t)">menu</b> → Backup / Restore.</p>`:''}
function st(){const d=D,c=d.cert,s=d.set,p=d.ports,url=`https://${c.domain||location.hostname}:${d.port}/${d.path}/`;
const kv=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
const SG=[['general','General',[['general','General']]],['proto','Protocols',[['xray','Xray'],['cdn','CDN'],['ovpn','OpenVPN'],['hy2','UDP'],['wg','WireGuard'],['dns','DNS']]],['users','Users',[['sub','Sub page'],['pay','Payloads']]],['net','Network ports',[['ports','Ports and 443 mode']]],['alerts','Telegram alerts',[['telegram','Telegram']]],['server','Server',[['check','Server check'],['tools','Tools'],['backup','Backup'],['logs','Logs']]]],ST=SG.flatMap(g=>g[2].map(t=>[t[0],t[1],g[0]]));
$('#pg').innerHTML=`<div class="stabs" role="tablist" aria-label="Settings sections">${SG.map(g=>`<button type="button" role="tab" data-sg="${g[0]}">${g[1]}</button>`).join('')}</div><div class="ssub" role="tablist" aria-label="Section parts">${ST.map(t=>`<button type="button" role="tab" data-stab="${t[0]}" data-g="${t[2]}">${t[1]}</button>`).join('')}</div><div class="sg"><div class="card tabx gl" id="glc"><div class="lab">${I('gear',15)}General settings</div><div class="gll">${GL.map(g=>`<button type="button" class="glr" data-gs="${g[0]}">${I(g[2],18)}<span><b>${g[1]}</b><small>${g[3]}</small></span><span class="gla" aria-hidden="true">›</span></button>`).join('')}</div></div><div class="tabx glb" id="glb"><button type="button" class="btn sm" id="glback">‹ All general settings</button></div>
<form class="card" id="cf"><div class="lab">${I('cert',15)}SSL certificate (panel + Xray)</div>${kv('Current',c.src)}${kv('Name',c.name||'-')}${kv('Expires',c.exp||'-')}
<p class="note" style="margin-top:12px">Paste the certificate (fullchain) and private key for your domain. The domain's A record must point to this server (on Cloudflare use DNS only). The panel restarts with the new certificate after saving.</p>
<label for="cc">Certificate (fullchain)</label><textarea id="cc" placeholder="-----BEGIN CERTIFICATE-----" spellcheck="false"></textarea>
<label for="ck">Private key</label><textarea id="ck" placeholder="-----BEGIN PRIVATE KEY-----" spellcheck="false"></textarea>
<div class="err" id="ce"></div><button class="btn pri">${I('cert',16)}<span>Save certificate</span></button></form>
<form class="card" id="xf"><div class="lab">${I('gear',15)}Xray defaults</div><p class="note" style="margin-top:8px">Links for every user are built from these. A user's own SNI or Host overrides them.</p>
<label for="xa">Server address (empty = domain or IP: ${X(d.addr)})</label><input id="xa" value="${X(s.addr)}" placeholder="vpn.example.com" autocapitalize="none">
<label for="xs2">Default SNI</label><input id="xs2" value="${X(s.sni)}" placeholder="${X(c.domain||'empty')}" autocapitalize="none">
<label for="xh">Default Host</label><input id="xh" value="${X(s.host)}" placeholder="${X(c.domain||d.addr)}" autocapitalize="none">
<label for="xp">XHTTP path</label><input id="xp" value="${X(s.path)}" autocapitalize="none">
<label for="xr">Default Reality target (a real website with TLS 1.3; each user can have their own in Add / Edit user)</label><input id="xr" value="${X(s.rsni)}" placeholder="www.microsoft.com" autocapitalize="none">
<div class="kv" style="margin-top:8px"><span>Reality public key</span><b>${X(s.rpub||'Created when Xray starts')}</b></div><div class="kv"><span>Reality short ID</span><b>${X(s.rsid||'-')}</b></div>
<div class="err" id="xe"></div><div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn pri">Save</button><button type="button" class="btn" id="rk">${I('refresh',15)}New Reality keys</button></div></form>
<form class="card" id="jsf"><div class="lab">${I('file',15)}JSON subscription</div><p class="note" style="margin-top:8px">A second subscription link with full configs for v2rayNG / v2rayN (Custom config). It can add TLS fragment and noise, so it works better where DPI blocks TLS.</p>
<label class="ck"><input type="checkbox" id="jsu"${s.jsub!==false?' checked':''}> Give users a JSON link</label>
<label class="ck"><input type="checkbox" id="jsfr"${s.jfrag?' checked':''}> Fragment (for TLS configs)</label>
<div class="ibg2"><div><label for="jpk">Packets</label><input id="jpk" value="${X(s.jpk||'tlshello')}" placeholder="tlshello" autocapitalize="none"></div><div><label for="jln">Length</label><input id="jln" value="${X(s.jlen||'100-200')}" placeholder="100-200"></div></div>
<label for="jin">Interval (ms)</label><input id="jin" value="${X(s.jint||'10-20')}" placeholder="10-20">
<label class="ck"><input type="checkbox" id="jsn"${s.jnoise?' checked':''}> Noises (random UDP packets before QUIC / UDP)</label>
<div class="err" id="jse"></div><button class="btn pri">Save</button></form>
<form class="card" id="hysc"><div class="lab">${I('bolt',15)}UDP (Hysteria2)</div>${d.hy?`<p class="note" style="margin-top:8px">Hysteria2 runs on UDP ${X(d.ports.HY_PORT)}${d.ports.HY_HOP?' with port hopping on '+X(d.ports.HY_HOP):''}. It uses the same certificate as Xray. Each UDP user logs in with their own username and password.</p>
${D.svc.filter(x=>x.unit=='rexui-hy2').map(x=>kv(x.name+' · '+x.port,x.st=='RUNNING'?'Running':x.st=='FAILED'?'Failed':'Idle')).join('')}
<label for="hybw">Max speed per UDP user (Mbps, 0 = no limit)</label><input id="hybw" type="number" min="0" max="10000" inputmode="numeric" value="${X(s.hy_bw||0)}">
<p class="note">Hysteria2 sends very fast. A limit stops one UDP user from taking the whole server line. Example: 30 on a 1 Gbps server with many users.</p>
<div class="err" id="hyse"></div><button class="btn pri">Save</button>
<p class="note">Change the UDP port or the port hopping range from menu → Port change on the server. Open them in your provider firewall as UDP.</p>`:`<p class="note bad" style="margin-top:8px">Hysteria2 is not installed on this server yet. Run the installer again (it keeps all users and settings) to add it.</p>`}</form>
<div class="card" id="wgsc"><div class="lab">${I('wg',15)}WireGuard</div>${d.wg?`<p class="note" style="margin-top:8px">WireGuard runs on UDP ${X(d.ports.WG_PORT||51820)}. Each WireGuard user has their own keys and address (10.66.x.x). Users scan the QR in the WireGuard app or import the .conf file.</p>
${D.svc.filter(x=>x.unit=='rexui-wg').map(x=>kv(x.name+' · '+x.port,x.st=='RUNNING'?'Running':x.st=='FAILED'?'Failed':'Idle')).join('')}${kv('WireGuard users',D.users.filter(u=>u.kind=='wg').length)}
<p class="note">Allow UDP ${X(d.ports.WG_PORT||51820)} in your provider firewall. WireGuard needs the kernel module: most KVM servers have it, OpenVZ / LXC servers often do not.</p>`:`<p class="note bad" style="margin-top:8px">WireGuard is not installed on this server yet. Run the installer again (it keeps all users and settings) to add it.</p>`}</div>
<form class="card" id="dnsf"><div class="lab">${I('net',15)}DNS tunnel + V2Ray · Real domain needed</div>${d.dns&&d.dns.on?`<p class="note" style="margin-top:8px">DuckDNS cannot do this. Buy a cheap domain (for example a .xyz) and add these records in its DNS panel:</p>
<div class="kv"><span>A record</span><b>${X(d.dns.nsh||'ns.yourdomain.com')} → ${X(d.dns.ip)}</b></div><div class="kv"><span>NS record</span><b>${X(d.dns.ns||'t.yourdomain.com')} → ${X(d.dns.nsh||'ns.yourdomain.com')}</b></div>
<label for="dnsn">Tunnel domain (the NS record name)</label><input id="dnsn" value="${X(d.dns.ns)}" placeholder="t.yourdomain.com" autocapitalize="none" spellcheck="false">
<div class="kv" style="margin-top:8px"><span>Public key</span><b style="word-break:break-all;white-space:normal;text-align:right">${X(d.dns.pub||'-')}</b></div>
${D.svc.filter(x=>x.unit=='rexui-dns').map(x=>kv('DNS tunnel · UDP 53',x.st=='RUNNING'?'Running':x.st=='FAILED'?'Failed':d.dns.ns?'Idle':'Off (no domain yet)')).join('')}
<p class="note">Allow UDP 53 in your provider firewall. If the NS record was just added, wait up to an hour before testing.</p><div class="err" id="dnse"></div><button class="btn pri">Save</button>`:`<p class="note bad" style="margin-top:8px">The DNS tunnel is not installed on this server yet. Run the installer again (it keeps all users and settings) to add it.</p>`}</form>
<form class="card" id="ovsf"><div class="lab">${I('vpn',15)}OpenVPN</div>${d.ov?`<p class="note" style="margin-top:8px">OpenVPN runs on TCP ${X(OVP())}. The HTTP proxy (Squid) on port ${X(d.ports.SQUID_PORT||3128)} only lets apps reach these OpenVPN ports on this server. Each user has their own certificate inside their .ovpn file.</p>
${D.svc.filter(x=>x.unit.startsWith('rexui-ovpn')||x.unit=='squid').map(x=>kv(x.name+(x.port?' · '+x.port:''),x.st=='RUNNING'?'Running':x.st=='NOT INSTALLED'?'Not installed':x.st=='FAILED'?'Failed':'Idle')).join('')}
<label for="ovdh">Default Host header (bug host) for new .ovpn files</label><input id="ovdh" value="${X(s.ovhost)}" placeholder="example: m.facebook.com" autocapitalize="none" spellcheck="false">
<p class="note">Users can still type another Host when they download the file. Leave empty for none.</p>
<div class="err" id="ovse"></div><button class="btn pri">Save</button>`:`<p class="note bad" style="margin-top:8px">OpenVPN is not installed on this server yet. Run the installer again (it keeps all users and settings) to add OpenVPN and the HTTP proxy.</p>`}</form>
<form class="card" id="pf"><div class="lab">${I('key',15)}Panel login</div><p class="note" style="margin-top:8px">Current username: <b style="color:var(--t)">${X(d.me)}</b></p>
<label for="po">Old password</label><input id="po" type="password" autocomplete="current-password">
<label for="pu">New username</label><input id="pu" value="${X(d.me)}" autocomplete="username" autocapitalize="none">
<label for="pn">New password</label><input id="pn" type="password" autocomplete="new-password">
<div class="err" id="pe"></div><button class="btn pri">Change login</button>
<div class="kv" style="margin-top:16px"><span>Two-factor login (2FA)</span><b class="${d.tfa?'ok':''}">${d.tfa?'On':'Off'}</b></div>
<p class="note">With 2FA on, login also asks for a 6-digit code from Google Authenticator or Aegis on your phone. Lost the phone? Run menu → 4 (Reset Username & Password) on the server to reset the login and turn 2FA off.</p>
<button type="button" class="btn ${d.tfa?'dng':''}" id="tfa">${I('shield',15)}${d.tfa?'Turn off 2FA':'Turn on 2FA'}</button></form>
<form class="card" id="apf"><div class="lab">${I('palette',15)}Appearance</div><p class="note" style="margin-top:8px">Your brand is shown on the login page, in the panel and on your users' page.</p>
<label for="apb">Brand name (empty = ReXUI)</label><input id="apb" value="${X(s.brand)}" maxlength="24" placeholder="ReXUI">
<label for="apt">Tagline (shown on the login page and users' page)</label><input id="apt" value="${X(s.tagline)}" maxlength="80" placeholder="Fast and private internet">
<span class="slab" id="apl">Accent colour</span><div class="sw" role="radiogroup" aria-labelledby="apl">${Object.entries(AC).map(([k,v])=>`<button type="button" role="radio" data-ac="${k}" aria-checked="${k==s.accent}" aria-label="${v[2]}" title="${v[2]}" style="--sw:${v[0]}">${k==s.accent?I('check',16):''}</button>`).join('')}</div>
<label for="apth">Theme on this device</label><select id="apth"><option value="auto">Auto (follow the phone)</option><option value="light">Light</option><option value="dark">Dark</option><option value="black">Black (AMOLED)</option></select>
<p class="note" style="margin-top:6px">The theme is saved in this browser only. Black saves battery on AMOLED phone screens.</p>
<div class="err" id="ape"></div><button class="btn pri">Save appearance</button></form>
<form class="card" id="rf"><div class="lab">${I('net',15)}Routing (Xray users)</div><p class="note" style="margin-top:8px">These rules apply to Xray configs. SSH traffic is not changed.</p>
<label class="ck"><input type="checkbox" id="rbt" ${s.btorrent?'checked':''}> Block torrent</label>
<label class="ck"><input type="checkbox" id="rb25" ${s.b25?'checked':''}> Block email port 25 (stops spam, for SSH and Xray)</label>
<label class="ck"><input type="checkbox" id="rba" ${s.bads?'checked':''} ${d.geo?'':'disabled'}> Block ads${d.geo?'':' (routing lists missing, run the installer again)'}</label>
<label for="rw">Send traffic through Cloudflare WARP</label><select id="rw"><option value="off">Off</option><option value="sites">Only these sites</option><option value="all">All traffic</option></select>
<label for="rs">WARP sites (comma separated)</label><input id="rs" value="${X(s.wsites)}" autocapitalize="none" spellcheck="false">
<p class="note" style="margin-top:6px">Examples: geosite:google, geosite:openai, geosite:netflix, domain:example.com. WARP gives a Cloudflare IP, useful when a site blocks your server IP.</p>
<div class="kv"><span>WARP account</span><b>${d.warp.on?'Registered · '+X(d.warp.v4):'Not registered (created when you turn WARP on)'}</b></div>
<div class="err" id="re"></div><div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn pri">Save</button>${d.warp.on?`<button type="button" class="btn dng" id="wr">Remove WARP account</button>`:''}</div></form>
<form class="card" id="af"><div class="lab">${I('clock',15)}Automation and alerts</div>
<label for="ad">Delete expired users after how many days? (0 = never)</label><input id="ad" value="${X(s.autodel)}" inputmode="numeric">
<p class="note" style="margin-top:6px">Checked once a day. The daily backup runs first, so deleted users can still be restored.</p>
<label for="at">Telegram bot token (for login alerts)</label><input id="at" value="${X(s.tgmask)}" placeholder="123456789:ABC..." autocapitalize="none" spellcheck="false">
<label for="ac">Telegram chat ID</label><div style="display:flex;gap:8px"><input id="ac" value="${X(s.tgchat)}" inputmode="numeric"><button type="button" class="btn" id="afc" style="white-space:nowrap">Find my ID</button></div>
<p class="note" style="margin-top:6px">Create a bot with @BotFather, paste its token, send /start to your bot, then tap Find my ID. You get a message on every panel login, after 5 wrong logins, and before your certificate expires.</p>
<label class="ck"><input type="checkbox" id="ah" ${s.health?'checked':''}> Health alerts (CPU, RAM or disk above 90%, or a service stops; stopped services are restarted automatically)</label>
<label class="ck"><input type="checkbox" id="ash" ${s.tgshare?'checked':''}> Sharing alerts (one account used from places far apart at the same time, see Online)</label>
<div style="display:flex;align-items:center;gap:10px;flex-wrap:wrap"><label class="ck"><input type="checkbox" id="ar" ${s.report?'checked':''}> Daily report every day at</label><select id="arh" style="width:auto;margin-top:12px;padding:6px 8px" aria-label="Report hour">${[...Array(24).keys()].map(h=>`<option value="${h}"${h==s.rhour?' selected':''}>${String(h).padStart(2,'0')}:00</option>`).join('')}</select></div>
<label class="ck"><input type="checkbox" id="abk" ${s.tgbackup?'checked':''}> Send the daily backup file to Telegram (it has passwords, keep the chat private)</label>
<div class="err" id="ae"></div><div style="display:flex;gap:8px;flex-wrap:wrap"><button class="btn pri">Save</button><button type="button" class="btn" id="aft">Send test message</button><button type="button" class="btn" id="afb">${I('save',15)}Send backup now</button></div></form>
<form class="card" id="spf"><div class="lab">${I('globe',15)}Subscription page and config names</div>
<label for="sa">Announcement (shown at the top of every user's page)</label><textarea id="sa" maxlength="500" style="min-height:70px;font:inherit" placeholder="Example: Server maintenance tonight 2-3 AM">${X(s.announce)}</textarea>
<label for="sn">Config name in the apps</label><input id="sn" value="${X(s.cname)}" maxlength="80" autocapitalize="none" spellcheck="false" placeholder="{user}-{proto}">
<p class="note" style="margin-top:6px">You can use {flag} {brand} {user} {proto} {type}. Example: <b style="color:var(--t)">{flag} {brand} {type}</b></p>
<label for="sf">Flag (2-letter country code, empty = none)</label><input id="sf" value="${X(s.flag)}" maxlength="2" autocapitalize="characters" placeholder="DE" style="max-width:120px">
<div class="kv" style="margin-top:10px"><span>Preview</span><b id="snp"></b></div>
<p class="note">Users see the new names after they refresh their subscription.</p>
<div class="err" id="spe"></div><button class="btn pri">Save</button></form>
<form class="card" id="tf"><div class="lab">${I('cpu',15)}Server tools</div>
<div class="ct" style="margin-top:12px"><b>Speed test</b><button type="button" class="btn sm" id="spb">${I('refresh',14)}Run test</button></div><p class="note">Download and upload speed of this server (Cloudflare, 1 connection, 7 seconds each). One test can use a few hundred MB of traffic on a fast server.</p><div id="spr"></div>

<div style="margin-top:18px;border-top:1px solid var(--l);padding-top:14px"><b>Scheduled reboot</b></div>
<div style="display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin-top:8px"><select id="rbm" aria-label="Reboot schedule"><option value="off">Off</option><option value="daily">Every day</option><option value="weekly">Every week</option></select>
<select id="rbd" aria-label="Day">${['Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday'].map((x,i)=>`<option value="${i}"${i==s.rbday?' selected':''}>${x}</option>`).join('')}</select><input id="rbt" value="${X(s.rbtime)}" aria-label="Time" placeholder="04:00"></div>
<p class="note" style="margin-top:6px">Server time now: <b style="color:var(--t)" id="stm">${X(d.stime)}</b>. Users are disconnected for about a minute during the reboot.</p>
<div class="err" id="tfe"></div><button class="btn pri">Save schedule</button></form>
<div class="card" id="xuc"><div class="lab">${I('refresh',15)}Xray core</div><div id="xui" style="margin-top:8px"></div>
<div class="mr" style="justify-content:flex-start;margin-top:10px"><button type="button" class="btn sm" id="xuk">Check for update</button><button type="button" class="btn sm pri" id="xun">Update now</button></div>
<label class="ck"><input type="checkbox" id="xua" ${s.xauto?'checked':''}> Update automatically every Sunday around 05:00 (server time). If the new version fails, the old one is put back. You get a Telegram message.</label><div class="err" id="xue"></div></div>
<form class="card" id="ddc"><div class="lab">${I('globe',15)}DuckDNS</div><p class="note" style="margin-top:8px">Keeps your free duckdns.org domain pointed at this server. Log in at duckdns.org, the token is at the top of the page. Leave both empty to turn it off.</p>
<label for="ddd">Subdomain</label><input id="ddd" value="${X(s.ddns_dom)}" placeholder="myserver (for myserver.duckdns.org)" autocapitalize="none" spellcheck="false">
<label for="ddt">Token</label><input id="ddt" value="${X(s.ddmask)}" placeholder="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" autocapitalize="none" spellcheck="false"><div id="ddi"></div>
<div class="err" id="dde"></div><button class="btn pri">Save and update</button></form>
<div class="card" id="mtc"><div class="lab">${I('disk',15)}Disk cleanup and swap</div><div id="mti"><p class="note" style="margin-top:8px">Loading...</p></div>
<div class="ct" style="margin-top:14px"><b>Disk cleanup</b><button type="button" class="btn sm" id="clb">${I('del',14)}Clean now</button></div><p class="note">Removes old system logs, the package cache and rotated log files. Users and settings are not touched.</p>
<label class="ck"><input type="checkbox" id="clx" ${s.autoclean?'checked':''}> Clean automatically every Monday, and when the disk is more than 85% full</label>
<div class="ct" style="margin-top:18px;border-top:1px solid var(--l);padding-top:14px"><b>Swap file</b></div><p class="note">Swap is disk space used as extra memory. It helps small VPS (1 GB RAM or less) not to run out of memory.</p>
<div style="display:flex;gap:8px;margin-top:8px"><select id="swg" aria-label="Swap size" style="flex:1"><option value="1">1 GB</option><option value="2" selected>2 GB</option><option value="4">4 GB</option><option value="8">8 GB</option></select><button type="button" class="btn pri" id="swb">Create swap</button><button type="button" class="btn dng" id="swr">Remove</button></div>
<div class="err" id="mte"></div></div>
<div class="card" id="lgc"><div class="ct"><div class="lab">${I('file',15)}Server logs</div><button type="button" class="btn sm" id="lvr">${I('refresh',14)}Refresh</button></div>
<div style="display:grid;grid-template-columns:2fr 1fr;gap:8px;margin-top:10px"><select id="lvs" aria-label="Log"><option value="xray">Xray (errors and restarts)</option><option value="access">Xray connections (access log)</option><option value="panel">Panel</option><option value="ssh">SSH logins</option><option value="ws">SSH WebSocket</option><option value="ssl">SSL (stunnel)</option><option value="udpgw">UDPGW</option></select>
<select id="lvn" aria-label="Lines"><option value="100">100 lines</option><option value="200" selected>200 lines</option><option value="500">500 lines</option><option value="1000">1000 lines</option></select></div>
<input id="lvq" placeholder="Filter, for example a username or IP" style="margin-top:8px" autocapitalize="none" spellcheck="false" aria-label="Filter">
<label class="ck"><input type="checkbox" id="lva"> Refresh every 5 seconds</label><pre id="lvo" class="lvo" tabindex="0" aria-label="Log lines">Loading...</pre></div>
<form class="card" id="fsc"><div class="lab">${I('globe',15)}Fake website</div><p class="note" style="margin-top:8px">When someone opens your server IP or domain in a browser, or a scanner probes the TLS ports (TCP TLS, Trojan), they see a normal website instead of an error. Uses port 80. Certificate renewals keep working.</p>
<label for="fss">Website</label><select id="fss"><option value="off">Off</option><option value="blog">Personal blog</option><option value="company">Company page</option><option value="soon">Under construction</option></select>
<label for="fst">Site title</label><input id="fst" value="${X(s.ftitle)}" maxlength="60" placeholder="Empty = a default title">
${D.fs?`<p class="err">${X(D.fs)}</p>`:''}<div class="mr" style="justify-content:flex-start"><button class="btn pri">Save</button>${s.fsite!='off'?`<a class="btn" href="http://${X(D.addr)}/" target="_blank" rel="noopener">Open site</a>`:''}</div><div class="err" id="fse"></div></form>
<div class="card" id="rfc"><div class="ct"><div class="lab">${I('search',15)}Reality target finder</div><button type="button" class="btn sm pri" id="rfb">Find targets</button></div>
<p class="note">Checks about 35 well known sites from this server: TLS 1.3, HTTP/2 and how fast they answer. Fast sites with HTTP/2 make the best Reality targets. Current default: <b style="color:var(--t)">${X(s.rsni)}</b></p>
<input id="rfx" placeholder="Add your own sites to test, comma separated (optional)" autocapitalize="none" spellcheck="false" aria-label="Extra sites"><div id="rfr"></div></div>
<div class="card" id="pac"><div class="lab">${I('key',15)}Panel address</div><p class="note" style="margin-top:8px">If someone found your panel address, change the secret path. The panel restarts and you log in again at the new address. Save the new address first.</p>
${kv('Current path','/'+location.pathname.split('/')[1]+'/')}<label for="pap">New path (empty = random)</label><input id="pap" placeholder="Random 16 characters" autocapitalize="none" spellcheck="false" maxlength="64">
<div class="err" id="pae"></div><button type="button" class="btn pri" id="pab">Change path</button></div>
<div class="card" id="bkc"><div class="lab">${I('save',15)}Backup and restore</div><p class="note" style="margin-top:8px">The backup file has all users (with passwords and GB usage) and the panel settings. Keep it private. Restore adds the users from the file and keeps other users. Ports, certificate and panel login are not changed.</p>
<div style="display:flex;gap:8px;flex-wrap:wrap"><button type="button" class="btn pri" id="bk">${I('save',15)}Download backup</button><button type="button" class="btn" id="rsb">${I('upl',15)}Restore from file</button><input type="file" id="rsf" accept=".json,application/json" hidden></div>
<div class="err" id="rse"></div><div id="bkl"></div></div>
<div class="card" id="pwc"><div class="lab">${I('dev',15)}Phone app</div><p class="note" style="margin-top:8px">Install the panel on your phone's home screen. It opens full screen like an app.</p>
<button type="button" class="btn pri" id="pwab" hidden style="margin-top:6px">${I('plus',15)}Install app</button>
<p class="note" id="pwan" style="margin-top:8px"></p></div>
<form class="card" id="cdnf"><div class="lab">${I('globe',15)}CDN mode (Cloudflare) · Real domain needed</div><p class="note" style="margin-top:8px">Users connect to Cloudflare, Cloudflare passes the traffic to this server. Your server IP stays hidden and many "free" or zero-rated Cloudflare hosts work as the address. Adds 2 configs to every V2Ray user.</p>
${d.cdn.dom?`<div class="kv"><span>Status</span><b class="ok">On · ${X(d.cdn.dom)}</b></div>`:`<div class="kv"><span>Status</span><b>Off</b></div>`}
<label for="cdnd">CDN domain (orange cloud on Cloudflare, empty = off)</label><input id="cdnd" value="${X(d.cdn.dom)}" placeholder="cdn.yourdomain.com" autocapitalize="none" spellcheck="false">
<label for="cdna">Address in the configs (optional)</label><input id="cdna" value="${X(d.cdn.addr)}" placeholder="Empty = the CDN domain. Or a Cloudflare IP / clean host" autocapitalize="none" spellcheck="false">
<details style="margin-top:12px"><summary><b>Cloudflare steps</b></summary><ol class="note" style="padding-left:18px;margin-top:6px;line-height:1.7">
<li>DNS → Add record: type <b style="color:var(--t)">A</b>, name <b style="color:var(--t)">cdn</b>, value your server IP, cloud <b style="color:var(--t)">orange (Proxied)</b>.</li>
<li>SSL/TLS → Overview → mode <b style="color:var(--t)">Full</b>.</li>
<li>Network → <b style="color:var(--t)">WebSockets</b> on (it is on by default).</li>
<li>Keep your panel record (vpn) and the DNS tunnel records grey.</li>
<li>Type cdn.yourdomain.com above and Save. Users refresh their subscription.</li></ol></details>
<div class="kv" style="margin-top:8px"><span>VLESS XHTTP TLS · port ${X(d.cdn.ports.xtls)}</span><b class="${d.cdn.tls?'ok':'bad'}">${d.cdn.tls?'Works with Cloudflare':'Port not allowed by Cloudflare'}</b></div>
<div class="kv"><span>VLESS XHTTP · port ${X(d.cdn.ports.x)}</span><b class="${d.cdn.http?'ok':'bad'}">${d.cdn.http?'Works with Cloudflare':'Port not allowed by Cloudflare'}</b></div>
<div class="kv"><span>SSH WebSocket · port ${X(d.cdn.ports.ws)}</span><b class="${d.cdn.wsok?'ok':'bad'}">${d.cdn.wsok?'Works with Cloudflare':'Port not allowed by Cloudflare'}</b></div>
<div class="kv"><span>SSH WebSocket TLS · port ${X(d.cdn.ports.wss)}</span><b class="${d.cdn.wssok?'ok':'bad'}">${d.cdn.wssok?'Works with Cloudflare':'Port not allowed by Cloudflare'}</b></div>
<p class="note">SSH users can use the CDN too: in the app set the SSH host to the CDN domain and use the WebSocket ports above (payload preset "Through Cloudflare CDN"). Cloudflare ports: HTTPS 443, 2053, 2083, 2087, 2096, 8443 · HTTP 80, 8080, 8880, 2052, 2082, 2086, 2095.</p>
<div class="err" id="cdne"></div><button class="btn pri">Save</button></form>
<div class="card" id="payc"><div class="ct"><div class="lab">${I('file',15)}Payloads</div><span class="mr" style="margin:0"><button type="button" class="btn sm" id="pyim">${I('upl',14)}Import</button><button type="button" class="btn sm" id="pyex">${I('save',14)}Export</button><input type="file" id="pyif" accept=".json,application/json" hidden></span></div>
<p class="note">Your own payloads for SSH users. The ones marked "shown" appear in every SSH user's details and on their page, with your server and ports already filled in.</p><div id="payl"></div></div>
<form class="card" id="payf"><div class="lab" id="pyh">New payload</div>
<select id="pyps" aria-label="Preset" style="margin-top:10px"></select>
<label for="pyn">Name</label><input id="pyn" maxlength="60" placeholder="Example: Jazz WhatsApp WS">
<div style="display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px"><div><label for="pym">Connection</label><select id="pym">${Object.entries(PAYM).map(m=>`<option value="${m[0]}">${m[1]}</option>`).join('')}</select></div>
<div><label for="pyg">Bug host (for {bug})</label><input id="pyg" placeholder="m.facebook.com" autocapitalize="none" spellcheck="false"></div></div>
<label for="pyx">Payload</label><div class="chips" id="pyc" style="margin:0 0 6px"></div><textarea id="pyx" spellcheck="false" maxlength="4000" style="min-height:96px" placeholder="GET / HTTP/1.1[crlf]Host: {bug}[crlf]Upgrade: websocket[crlf][crlf]"></textarea>
<p class="note" style="margin-top:4px">{...} are filled by the panel. [...] are kept for the app (HTTP Custom, HTTP Injector, NPV Tunnel).</p>
<span class="slab">Preview (what the user copies)</span><pre class="lvo" id="pyp" style="min-height:0;max-height:160px;margin-top:4px"></pre><p class="note" id="pyi" style="margin-top:4px"></p>
<label for="pyo">Note for users (optional)</label><input id="pyo" maxlength="200" placeholder="Example: Works on Jazz with the WhatsApp package">
<label class="ck"><input type="checkbox" id="pys" checked> Show to SSH users</label>
<div class="err" id="pye"></div><div class="mr" style="justify-content:flex-start"><button class="btn pri">Save</button><button type="button" class="btn" id="pytb">${I('bolt',15)}Test on this server</button><button type="button" class="btn" id="pyclr">Clear</button></div><div id="pyres"></div>
<p class="note">Test connects to this server like an app does and checks that SSH answers. It cannot test your mobile network or the bug host itself.</p></form>
<div class="card" id="h4c"><div class="ct"><div class="lab">${I('net',15)}443 mode (HAProxy)</div><button type="button" class="btn sm${d.h443.on?'':' pri'}" id="h4b"${d.h443.has||d.h443.on?'':' disabled'}>${d.h443.on?'Turn off':'Turn on'}</button></div>
<div class="kv"><span>Status</span><b class="${d.h443.on?'ok':d.h443.want?'bad':''}">${d.h443.on?'On':d.h443.has?'Off':'Off · HAProxy not installed'}</b></div>
${d.h443.err&&!d.h443.on?`<p class="note bad" style="margin-top:8px">${X(d.h443.err)}</p>`:''}
<p class="note" style="margin-top:8px">One port for everything, for networks that only allow 443 and 80. <b style="color:var(--t)">443</b>: SSH SSL, SSH WS TLS, VLESS XHTTP TLS, VLESS TCP TLS, Trojan, OpenVPN, with any SNI. <b style="color:var(--t)">80</b>: SSH WS, VLESS XHTTP, website. The old ports keep working, users see them as a second choice. Reality keeps its own port. Hysteria2 (UDP) and the DNS tunnel do not change.</p>
<p class="note">Turning it on checks itself (SSL, WebSocket and XHTTP through HAProxy) and goes back to the old setup if anything fails. Xray restarts once, so V2Ray users reconnect.</p></div>
<div class="card" id="prc"><div class="ct"><div class="lab">${I('net',15)}Ports</div><button type="button" class="btn sm" id="prr">${I('refresh',14)}Refresh</button></div><div id="prt"><p class="note">Loading...</p></div>
<p class="note">To change a port, run <b style="color:var(--t)">menu</b> on the server and open Port change.</p>
<p class="note"><b style="color:var(--t)">Works on the server but not from outside?</b> Check your VPS provider's firewall or Anti-DDoS rules. A rule that expects SSH on a web port (80, 8080, 8880) lets only SSH through and silently drops WebSocket and XHTTP. Set the rule's application to HTTP, or delete the rule.</p></div>
<div class="card" id="ckc"><div class="ct"><div class="lab">${I('shield',15)}Server check</div><button type="button" class="btn sm pri" id="ckb">${I('refresh',14)}Run check</button></div>
<p class="note">Checks services, Xray config, certificate, domains and DNS records, OpenVPN network, firewall, ports, time, disk and memory. Problems that the panel can fix get a Fix button.</p><div id="ckr"></div></div>
<div class="card" id="pfc"><div class="lab">${I('bolt',15)}Performance mode</div><p class="note" style="margin-top:8px">Network tuning for the whole server. Changes apply right away, nobody is disconnected.</p>
<div class="pfm" id="pfm" role="radiogroup" aria-label="Performance mode">${[['latency','Low ping','Gaming, calls, browsing. Small buffers, fast replies.'],['balanced','Balanced','Best for most servers with many users.'],['throughput','Max speed','Downloads and streaming on a fast server. Uses more memory.']].map(m=>`<button type="button" role="radio" data-pm="${m[0]}" aria-checked="${(s.perf||'balanced')==m[0]}"><b>${m[1]}</b><small>${m[2]}</small></button>`).join('')}</div></div>
<div class="card" id="ppc"><div class="lab">${I('shield',15)}Panel and ports</div>${kv('URL',url)}${kv('Secret path','/'+d.path+'/')}
${[['Panel','PANEL_PORT'],['SSH','SSH_PORT'],['SSH SSL','SSL_PORT'],['SSH WS','WS_PORT'],['SSH WS TLS','WSTLS_PORT'],['UDPGW','UDPGW_PORT'],['VLESS XHTTP TLS','VWSTLS_PORT'],['VLESS TCP TLS','VTCP_PORT'],['Trojan TLS','TROJAN_PORT'],['VLESS Reality','REALITY_PORT'],['VLESS XHTTP','VWS_PORT']].map(x=>kv(x[0],p[x[1]]||'-')).join('')}
<p class="note" style="margin-top:12px">To change a port, run <b style="color:var(--t)">menu</b> on the server and open Port change.</p></div></div>`;
const TM={cf:'general',xf:'xray',jsf:'xray',rf:'general',fsc:'general',rfc:'xray',pf:'general',ovsf:'ovpn',hysc:'hy2',wgsc:'wg',dnsf:'dns',apf:'general',pwc:'general',ppc:'general',pac:'general',af:'telegram',spf:'sub',tf:'tools',xuc:'tools',ddc:'tools',mtc:'tools',bkc:'backup',lgc:'logs',cdnf:'cdn',payc:'pay',payf:'pay',prc:'ports',h4c:'ports',ckc:'check',pfc:'general'};
const stab=t=>{const x=ST.find(x=>x[0]==t)||ST[0];t=x[0];const g=x[2],one=SG.find(y=>y[0]==g)[2].length<2;LSG[g]=t;ls('rx-stab',t);document.querySelectorAll('[data-sg]').forEach(b=>{const on=b.dataset.sg==g;b.classList.toggle('on',on);b.setAttribute('aria-selected',on)});$('.ssub').hidden=one;document.querySelectorAll('[data-stab]').forEach(b=>{const on=b.dataset.stab==t;b.hidden=b.dataset.g!=g;b.classList.toggle('on',on);b.setAttribute('aria-selected',on)});
Object.entries(TM).forEach(([id,tb])=>{const el=$('#'+id);if(el)el.classList.toggle('tabx',tb!=t||(t=='general'&&GSEL!=id))});$('#glc').classList.toggle('tabx',t!='general'||!!GSEL);$('#glb').classList.toggle('tabx',t!='general'||!GSEL);if(t=='tools')mload();if(t=='logs')lview();if(t=='ports')portsLoad();if(t=='check'&&!$('#ckr').innerHTML)checkRun()};window.STAB=stab;
$('#fss').value=s.fsite;$('#fsc').onsubmit=async e=>{e.preventDefault();try{await api('api/fsite',{fsite:$('#fss').value,ftitle:$('#fst').value});$('#fse').textContent='';toast('Saved')}catch(x){$('#fse').textContent=x.message}};
$('#rfb').onclick=()=>api('api/rfind',{extra:$('#rfx').value}).then(()=>{toast('Checking sites...');load()}).catch(x=>toast(x.message,1));
$('#rfr').onclick=async e=>{const b=e.target.closest('[data-rd]');if(!b)return;if(!confirm('Use '+b.dataset.rd+' as the default Reality target?\n\nUsers without their own target get it. They must refresh their subscription.'))return;try{await api('api/rdefault',{domain:b.dataset.rd});toast('Default target changed');load()}catch(x){toast(x.message,1)}};
$('#xuk').onclick=async()=>{const b=$('#xuk');b.disabled=true;try{const r=await api('api/xcheck');$('#xue').textContent='';toast(r.cur==r.latest?'You have the latest ('+r.latest+')':'New version: '+r.latest);load()}catch(x){$('#xue').textContent=x.message}b.disabled=false};
$('#xun').onclick=()=>{if(confirm('Update Xray now? Users are disconnected for a few seconds.'))api('api/xupdate',{force:0}).then(()=>{toast('Updating Xray...');load()}).catch(x=>$('#xue').textContent=x.message)};
$('#xua').onchange=()=>api('api/xauto',{xauto:$('#xua').checked}).then(()=>toast('Saved')).catch(x=>toast(x.message,1));
$('#ddc').onsubmit=async e=>{e.preventDefault();const b=$('#ddc .pri');b.disabled=true;try{const r=await api('api/ddns',{dom:$('#ddd').value,tok:$('#ddt').value});$('#dde').textContent='';toast(r.ip?'DuckDNS updated: '+r.ip:'DuckDNS turned off');load()}catch(x){$('#dde').textContent=x.message}b.disabled=false};
$('#pab').onclick=async()=>{if(!confirm('Change the panel address now? You will log in again at the new address.'))return;try{const r=await api('api/panel-path',{path:$('#pap').value}),u=location.origin+'/'+r.path+'/';
$('#pae').innerHTML=`<span style="color:var(--t)">New address (save it):<br><b style="word-break:break-all">${X(u)}</b><br>Opening it in a few seconds...</span>`;copy(u);setTimeout(()=>location.href=u,5000)}catch(x){$('#pae').textContent=x.message}};
$('#lvs').onchange=$('#lvn').onchange=$('#lvr').onclick=()=>lview();let lvq;$('#lvq').oninput=()=>{clearTimeout(lvq);lvq=setTimeout(lview,400)};
document.querySelector('.gll').onclick=e=>{const b=e.target.closest('[data-gs]');if(b){GSEL=b.dataset.gs;stab('general');spush();window.scrollTo({top:0})}};$('#glback').onclick=()=>{GSEL=null;stab('general');spush();window.scrollTo({top:0})};
document.querySelector('.stabs').onclick=e=>{const b=e.target.closest('[data-sg]');if(b){const g=SG.find(y=>y[0]==b.dataset.sg);if(b.dataset.sg=='general')GSEL=null;stab(LSG[g[0]]||g[2][0][0]);spush();b.scrollIntoView({block:'nearest',inline:'nearest'})}};document.querySelector('.ssub').onclick=e=>{const b=e.target.closest('[data-stab]');if(b){stab(b.dataset.stab);spush();b.scrollIntoView({block:'nearest',inline:'nearest'})}};
$('#apth').value=ls('rx-theme')||'light';$('#apth').onchange=()=>{const v=$('#apth').value;theme(v);ls('rx-theme',v);if(v!='light'&&v!='auto')ls('rx-dark',v)};
$('#pwab').hidden=!IP;$('#pwan').innerHTML=isApp()?'You are using the app now.':location.protocol!='https:'?'':`If there is no Install button: in Chrome open the ⋮ menu and tap <b style="color:var(--t)">Add to Home screen</b>. On iPhone, open the panel in Safari, tap Share and <b style="color:var(--t)">Add to Home Screen</b>.${D.cert.src=='self-signed'?' The app works best with your own domain certificate.':''}`;
$('#pwab').onclick=async()=>{if(!IP)return;IP.prompt();await IP.userChoice.catch(()=>{});IP=null;$('#pwab').hidden=true};
$('#clb').onclick=async()=>{const b=$('#clb');b.disabled=true;try{const r=await api('api/cleanup');toast('Freed '+fb(r.freed));mload()}catch(x){$('#mte').textContent=x.message}b.disabled=false};
$('#clx').onchange=()=>api('api/autoclean',{autoclean:$('#clx').checked}).then(()=>toast('Saved')).catch(x=>toast(x.message,1));
$('#swb').onclick=async()=>{const g=$('#swg').value;if(!confirm('Create a '+g+' GB swap file? This takes up to a minute.'))return;const b=$('#swb');b.disabled=true;b.textContent='Working...';try{await api('api/swap',{gb:+g});toast('Swap is on');$('#mte').textContent=''}catch(x){$('#mte').textContent=x.message}b.disabled=false;b.textContent='Create swap';mload()};
$('#swr').onclick=async()=>{if(!confirm('Remove the swap file?'))return;try{await api('api/swap',{gb:0});toast('Swap removed');$('#mte').textContent=''}catch(x){$('#mte').textContent=x.message}mload()};
featBind();stab(ls('rx-stab')||'general');
stb();$('#rsf').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;$('#rse').textContent='';let o;
try{o=JSON.parse(await f.text())}catch(x){return $('#rse').textContent='This file is not valid JSON'}
if(!confirm('Restore '+(o.users||[]).length+' users from '+f.name+'?'))return;
try{const r=await api('api/restore',o);toast('Restored '+r.users+' users'+(r.skipped?' ('+r.skipped+' bad records skipped)':'')+(r.cert?' and the certificate':''));load()}catch(x){$('#rse').textContent=x.message}};
$('#cf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri'),t=b.querySelector('span');b.disabled=true;t.textContent='Checking...';
try{const r=await api('api/cert',{crt:$('#cc').value,key:$('#ck').value});const dm=r.cert.domain;toast('Certificate saved. Panel is restarting...');
setTimeout(()=>location.href=`https://${dm||location.hostname}:${location.port}${location.pathname}`,6000)}catch(x){$('#ce').textContent=x.message}b.disabled=false;t.textContent='Save certificate'};
$('#jsf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/jsub-set',{jsub:$('#jsu').checked,jfrag:$('#jsfr').checked,jnoise:$('#jsn').checked,jpk:$('#jpk').value,jlen:$('#jln').value,jint:$('#jin').value});$('#jse').textContent='';toast('Saved');await load()}catch(x){$('#jse').textContent=x.message}b.disabled=false};
if($('#hybw'))$('#hysc').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/hy-set',{hy_bw:$('#hybw').value});$('#hyse').textContent='';toast('Saved');await load()}catch(x){$('#hyse').textContent=x.message}b.disabled=false};
if($('#dnsn'))$('#dnsf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/dns-set',{dns_ns:$('#dnsn').value});$('#dnse').textContent='';toast('Saved');await load();st()}catch(x){$('#dnse').textContent=x.message}b.disabled=false};
if($('#ovdh'))$('#ovsf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/ovpn-set',{ovhost:$('#ovdh').value});$('#ovse').textContent='';toast('Saved');await load()}catch(x){$('#ovse').textContent=x.message}b.disabled=false};
$('#xf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/settings',{addr:$('#xa').value,sni:$('#xs2').value,host:$('#xh').value,path:$('#xp').value,rsni:$('#xr').value});$('#xe').textContent='';toast('Saved. Users need to refresh their subscription.');await load();st()}catch(x){$('#xe').textContent=x.message}b.disabled=false};
$('#rw').value=s.warp;let APA=s.accent;
$('#apf').querySelector('.sw').onclick=e=>{const b=e.target.closest('[data-ac]');if(!b)return;APA=b.dataset.ac;accent(APA);$('#apf').querySelectorAll('[data-ac]').forEach(x=>{const on=x.dataset.ac==APA;x.setAttribute('aria-checked',on);x.innerHTML=on?I('check',16):''})};
$('#apf').onsubmit=async e=>{e.preventDefault();try{await api('api/appearance',{brand:$('#apb').value,tagline:$('#apt').value,accent:APA});$('#ape').textContent='';toast('Appearance saved');await load()}catch(x){$('#ape').textContent=x.message}};
$('#rf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;b.textContent='Saving...';
try{await api('api/routing',{b25:$('#rb25').checked,btorrent:$('#rbt').checked,bads:$('#rba').checked,warp:$('#rw').value,wsites:$('#rs').value});$('#re').textContent='';toast('Routing saved');await load();st()}catch(x){$('#re').textContent=x.message}b.disabled=false;b.textContent='Save'};
if($('#wr'))$('#wr').onclick=async()=>{if(!confirm('Remove the WARP account and turn WARP off?'))return;try{await api('api/warp-reset');toast('WARP removed');await load();st()}catch(x){$('#re').textContent=x.message}};
const ab=()=>({autodel:$('#ad').value,tgtoken:$('#at').value,tgchat:$('#ac').value,health:$('#ah').checked,report:$('#ar').checked,rhour:$('#arh').value,tgbackup:$('#abk').checked,tgshare:$('#ash').checked});
$('#afb').onclick=async()=>{const b=$('#afb');b.disabled=true;try{await api('api/tg-backup');$('#ae').textContent='';toast('Backup sent to Telegram')}catch(x){$('#ae').textContent=x.message}b.disabled=false};
const snp=()=>{const f=$('#sf').value.toUpperCase(),fl=/^[A-Z]{2}$/.test(f)?[...f].map(c=>String.fromCodePoint(0x1F1E6+c.charCodeAt(0)-65)).join(''):'';$('#snp').textContent=($('#sn').value||'{user}-{proto}').replace(/\{flag\}/g,fl).replace(/\{brand\}/g,BR.brand||'ReXUI').replace(/\{user\}/g,'ali').replace(/\{proto\}/g,'reality').replace(/\{type\}/g,'VLESS Reality').replace(/\s+/g,' ').trim()};
$('#sn').oninput=$('#sf').oninput=snp;snp();
$('#spf').onsubmit=async e=>{e.preventDefault();try{await api('api/subpage',{announce:$('#sa').value,cname:$('#sn').value,flag:$('#sf').value});$('#spe').textContent='';toast('Saved')}catch(x){$('#spe').textContent=x.message}};
$('#rbm').value=s.reboot;const rbv=()=>{$('#rbd').hidden=$('#rbm').value!='weekly';$('#rbt').disabled=$('#rbm').value=='off'};$('#rbm').onchange=rbv;rbv();
$('#tf').onsubmit=async e=>{e.preventDefault();try{await api('api/reboot',{reboot:$('#rbm').value,rbday:$('#rbd').value,rbtime:$('#rbt').value});$('#tfe').textContent='';toast('Schedule saved')}catch(x){$('#tfe').textContent=x.message}};
$('#spb').onclick=()=>api('api/speedtest').then(()=>{toast('Speed test started');load()}).catch(x=>toast(x.message,1));
$('#af').onsubmit=async e=>{e.preventDefault();try{await api('api/automation',ab());$('#ae').textContent='';toast('Saved');await load();st()}catch(x){$('#ae').textContent=x.message}};
$('#afc').onclick=async()=>{try{const r=await api('api/tg-chat',ab());$('#ac').value=r.chat;$('#ae').textContent='';toast('Chat ID found, now tap Save')}catch(x){$('#ae').textContent=x.message}};
$('#aft').onclick=async()=>{try{await api('api/tg-test',ab());$('#ae').textContent='';toast('Test message sent')}catch(x){$('#ae').textContent=x.message}};
$('#rk').onclick=async()=>{if(!confirm('Create new Reality keys? Every user must refresh their subscription, old Reality configs stop working.'))return;try{await api('api/reality-keys');toast('New Reality keys created');await load();st()}catch(x){$('#xe').textContent=x.message}};
$('#tfa').onclick=async()=>{if(D.tfa)return modal('Turn off 2FA',[['code','Current 6-digit code','number','']],d=>api('api/2fa/disable',d).then(()=>{toast('2FA is off');return load().then(st)}));
let r;try{r=await api('api/2fa/setup')}catch(x){return toast(x.message,1)}
modal('Turn on 2FA',[['code','Enter the 6-digit code shown in the app','number','']],d=>api('api/2fa/enable',d).then(()=>{toast('2FA is on');return load().then(st)}),
`1. Open Google Authenticator or Aegis and scan this QR.<span style="display:block;background:#fff;border-radius:10px;padding:8px;margin:10px auto;max-width:220px">${RXQR.svg(r.uri,200)}</span>Or type this key: <b style="color:var(--t);word-break:break-all">${X(r.secret)}</b><br>2. Enter the code from the app below.`)};
$('#pf').onsubmit=async e=>{e.preventDefault();try{await api('api/login-change',{old:$('#po').value,u:$('#pu').value,p:$('#pn').value});toast('Login changed, please log in again');show(false)}catch(x){$('#pe').textContent=x.message}}}
const PAYM={ws:'SSH WebSocket',wstls:'SSH WebSocket TLS',ssl:'SSH SSL / TLS',proxy:'HTTP proxy'};
const PAYV=[['{bug}','Bug host'],['{server}','Server'],['{ip}','Server IP'],['{cdn}','CDN domain'],['{ws_port}','WS port'],['{wss_port}','WS TLS port'],['{ssl_port}','SSL port'],['[crlf]','New line'],['[split]','Split'],['[host]','App host'],['[port]','App port'],['[ua]','User agent']];
const PAYP=[['Host = server (most used)','ws','GET / HTTP/1.1[crlf]Host: {server}[crlf]Upgrade: websocket[crlf][crlf]'],['wss:// bug host (most used)','ws','GET wss://{bug} [protocol][crlf]Host: {server}[crlf]Upgrade: websocket[crlf][crlf]'],['Basic WebSocket','ws','GET / HTTP/1.1[crlf]Host: {bug}[crlf]Upgrade: websocket[crlf][crlf]'],
['WebSocket + Connection header','ws','GET / HTTP/1.1[crlf]Host: {bug}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]'],
['Split: bug host first','ws','GET / HTTP/1.1[crlf]Host: {bug}[crlf][crlf][split]GET / HTTP/1.1[crlf]Host: {server}[crlf]Upgrade: websocket[crlf][crlf]'],
['X-Online-Host','ws','GET / HTTP/1.1[crlf]Host: {server}[crlf]X-Online-Host: {bug}[crlf]Upgrade: websocket[crlf][crlf]'],
['Full URL request','ws','GET http://{bug}/ HTTP/1.1[crlf]Host: {server}[crlf]Upgrade: websocket[crlf][crlf]'],
['Keep-Alive + user agent','ws','GET / HTTP/1.1[crlf]Host: {bug}[crlf]Connection: Keep-Alive[crlf]User-Agent: [ua][crlf]Upgrade: websocket[crlf][crlf]'],
['WebSocket TLS (SNI = bug host)','wstls','GET / HTTP/1.1[crlf]Host: {bug}[crlf]Upgrade: websocket[crlf][crlf]'],
['Through Cloudflare CDN','ws','GET / HTTP/1.1[crlf]Host: {cdn}[crlf]Upgrade: websocket[crlf][crlf]'],
['HTTP proxy CONNECT','proxy','CONNECT {server}:{ws_port} HTTP/1.1[crlf]Host: {bug}[crlf][crlf]']];
let PE=null;
function payRender(t,bug){const v=Object.assign({},D.pvals||{});if(bug)v['{bug}']=bug;let o=t||'';Object.keys(v).forEach(k=>{o=o.split(k).join(v[k])});return o}
function payPort(m){const p=Object.assign({},D.ports,D.h443&&D.h443.ports);return m=='wstls'?p.WSTLS_PORT:m=='ssl'?p.SSL_PORT:m=='proxy'?'proxy':p.WS_PORT}
function payList(){const el=$('#payl');if(!el)return;const L=D.pays||[];
el.innerHTML=L.length?L.map(p=>`<div class="pyr"><div class="pyn"><b>${X(p.name)}</b><small class="m">${X(PAYM[p.mode]||p.mode)} · port ${X(payPort(p.mode))}${p.bug?' · '+X(p.bug):''}${p.show?' · shown to SSH users':' · hidden'}</small>${p.note?`<small class="m">${X(p.note)}</small>`:''}</div>
<span class="pyb"><button type="button" class="btn sm" data-pt="${p.id}">Test</button><button type="button" class="btn sm" data-pc="${p.id}">Copy</button><button type="button" class="btn sm" data-pe="${p.id}">Edit</button><button type="button" class="btn sm dng" data-pd="${p.id}" aria-label="Delete ${X(p.name)}">${I('del',14)}</button></span><div class="pyt" id="pyt_${p.id}"></div></div>`).join(''):'<p class="note">No payloads yet. Write one below or start from a preset.</p>'}
function payForm(p){PE=p&&p.id?p.id:null;p=p||{};$('#pyn').value=p.name||'';$('#pym').value=p.mode||'ws';$('#pyg').value=p.bug||'';$('#pyx').value=p.text||'';$('#pyo').value=p.note||'';$('#pys').checked=p.show!==false;
$('#pyh').textContent=PE?'Edit payload':'New payload';$('#pye').textContent='';$('#pyres').innerHTML='';payPrev()}
function payPrev(){const t=$('#pyx').value,m=$('#pym').value;$('#pyp').textContent=payRender(t,$('#pyg').value.trim())||' ';
$('#pyi').innerHTML=`Port <b style="color:var(--t)">${X(payPort(m))}</b>${m=='wstls'||m=='ssl'?' with TLS / SSL on, SNI = bug host':m=='proxy'?': put your proxy IP and port in the app':''}.`}
function payData(){return {id:PE,name:$('#pyn').value.trim(),mode:$('#pym').value,bug:$('#pyg').value.trim(),text:$('#pyx').value,note:$('#pyo').value.trim(),show:$('#pys').checked}}
function payShow(el,r){el.innerHTML=`<p class="note ${r.ok?'ok':'bad'}" style="margin-top:6px">${r.ok?'✓ ':'✗ '}${X(r.msg)}</p>`}
async function payTest(d,el){el.innerHTML='<p class="note">Testing...</p>';try{payShow(el,await api('api/payload/test',d))}catch(x){payShow(el,{ok:0,msg:x.message})}}
function featBind(){
$('#pyc').innerHTML=PAYV.map(v=>`<button type="button" class="chip" data-pv="${v[0]}" title="${v[1]}">${X(v[0])}</button>`).join('');
$('#pyps').innerHTML='<option value="">Start from a preset...</option>'+PAYP.map((p,i)=>`<option value="${i}">${X(p[0])}</option>`).join('');
$('#pyps').onchange=e=>{const p=PAYP[e.target.value];if(!p)return;if($('#pyx').value.trim()&&!confirm('Replace the text in the box with this preset?')){e.target.value='';return}if(!$('#pyn').value.trim())$('#pyn').value=p[0];$('#pym').value=p[1];$('#pyx').value=p[2];e.target.value='';payPrev()};
$('#pyc').onclick=e=>{const b=e.target.closest('[data-pv]');if(!b)return;const t=$('#pyx'),s=t.selectionStart??t.value.length,v=b.dataset.pv;t.value=t.value.slice(0,s)+v+t.value.slice(t.selectionEnd??s);t.focus();t.selectionStart=t.selectionEnd=s+v.length;payPrev()};
$('#pyx').oninput=$('#pym').onchange=$('#pyg').oninput=payPrev;
$('#payf').onsubmit=async e=>{e.preventDefault();const b=$('#payf .pri');b.disabled=true;try{await api('api/payload/save',payData());toast(PE?'Payload saved':'Payload added');payForm();await load();payList()}catch(x){$('#pye').textContent=x.message}b.disabled=false};
$('#pytb').onclick=()=>payTest(payData(),$('#pyres'));$('#pyclr').onclick=()=>payForm();
$('#payl').onclick=async e=>{const b=e.target.closest('button');if(!b)return;const id=b.dataset.pt||b.dataset.pc||b.dataset.pe||b.dataset.pd,p=(D.pays||[]).find(x=>x.id==id);if(!p)return;
if(b.dataset.pt)return payTest(p,$('#pyt_'+id));if(b.dataset.pc)return copy(payRender(p.text,p.bug));
if(b.dataset.pe){payForm(p);$('#payf').scrollIntoView({block:'start',behavior:'smooth'});return}
if(confirm('Delete the payload '+p.name+'?'))try{await api('api/payload/del',{id});toast('Deleted');if(PE==id)payForm();await load();payList()}catch(x){toast(x.message,1)}};
$('#pyex').onclick=()=>{const L=(D.pays||[]).map(({id,...r})=>r);if(!L.length)return toast('No payloads to export',1);const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([JSON.stringify({rexui_payloads:1,items:L},null,1)],{type:'application/json'}));a.download='payloads.json';a.click();setTimeout(()=>URL.revokeObjectURL(a.href),2000)};
$('#pyim').onclick=()=>$('#pyif').click();
$('#pyif').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;try{const o=JSON.parse(await f.text()),items=Array.isArray(o)?o:o.items;const r=await api('api/payload/import',{items});toast('Added '+r.added+' payload'+(r.added==1?'':'s'));await load();payList()}catch(x){toast(x.message=='Nothing to import'||!(x instanceof SyntaxError)?x.message:'This file is not valid JSON',1)}};
payList();payForm();
$('#cdnf').onsubmit=async e=>{e.preventDefault();const b=$('#cdnf .pri');b.disabled=true;try{await api('api/cdn-set',{cdn_dom:$('#cdnd').value,cdn_addr:$('#cdna').value});$('#cdne').textContent='';toast($('#cdnd').value.trim()?'Saved. Users get the CDN configs after they refresh.':'CDN turned off');await load();st()}catch(x){$('#cdne').textContent=x.message}b.disabled=false};
$('#pfm').onclick=async e=>{const b=e.target.closest('[data-pm]');if(!b||b.getAttribute('aria-checked')=='true')return;try{await api('api/perf-set',{perf:b.dataset.pm});toast('Performance mode: '+b.querySelector('b').textContent);await load();$('#pfm').querySelectorAll('[data-pm]').forEach(x=>x.setAttribute('aria-checked',x.dataset.pm==b.dataset.pm))}catch(x){toast(x.message,1)}};
$('#h4b').onclick=async e=>{const b=e.target,on=!D.h443.on;if(!on&&!confirm('Turn off 443 mode? Users on port 443 / 80 configs need the old ports again.'))return;b.disabled=true;b.textContent='Working, up to 30 seconds...';try{await api('api/h443',{on});toast(on?'443 mode is on. Users get the new configs after they refresh.':'443 mode is off')}catch(x){toast(x.message,1)}await load();st();STAB('ports')};$('#prr').onclick=()=>portsLoad();
$('#prt').onclick=async e=>{const b=e.target.closest('[data-fo]');if(!b)return;const [p,pr]=b.dataset.fo.split('/');try{const r=await api('api/fw-open',{port:p,proto:pr});toast(r.msg||'Opened '+p+'/'+pr);portsLoad()}catch(x){toast(x.message,1)}};
$('#ckb').onclick=()=>checkRun();
$('#ckr').onclick=async e=>{const b=e.target.closest('[data-fx]');if(!b)return;b.disabled=true;b.textContent='Working...';try{const r=await api('api/check/fix',{fix:b.dataset.fx});toast(r.msg||'Done',!r.ok)}catch(x){toast(x.message,1)}checkRun()}}
let PV=null;
async function portsLoad(){const el=$('#prt');if(!el)return;el.innerHTML='<p class="note">Loading...</p>';try{PV=await api('api/ports');portsShow()}catch(x){el.innerHTML=`<p class="err">${X(x.message)}</p>`}}
function portsShow(){const el=$('#prt');if(!el||!PV)return;
const fwc=f=>f=='open'?'<span class="ok">Allowed</span>':f=='closed'?'<span class="bad">Blocked</span>':'<span class="m">Off</span>';
el.innerHTML=`<div class="tw2"><table class="pt"><thead><tr><th>Service</th><th>Port</th><th>Running</th><th>Server firewall</th></tr></thead><tbody>${PV.ports.map(r=>`<tr><td>${X(r.name)}</td><td><b>${X(r.port)}</b><small class="m">/${r.proto}</small></td><td>${r.listen?`<span class="ok">Yes</span> <small class="m">${X(r.prog)}</small>`:'<span class="bad">No</span>'}</td><td>${fwc(r.fw)}${r.fw=='closed'?` <button type="button" class="btn sm" data-fo="${X(r.port)}/${r.proto}">Allow</button>`:''}</td></tr>`).join('')}</tbody></table></div>
${PV.clash.length?`<p class="note bad" style="margin-top:10px">Two services use the same port: ${PV.clash.map(c=>X(c.port+'/'+c.proto+' ('+c.names.join(', ')+')')).join('; ')}. Change one from menu → Port change.</p>`:''}
${PV.other.length?`<p class="note" style="margin-top:10px">Other programs listening on this server: ${PV.other.map(o=>X(o.port+'/'+o.proto+' '+o.prog)).join(', ')}</p>`:''}
<p class="note" style="margin-top:10px">${PV.fw?'The server firewall (ufw) is on.':'The server firewall (ufw) is off, so nothing is blocked on the server itself.'} Your VPS provider may have its own firewall in their website: open the same ports there.</p>`}
async function checkRun(){const el=$('#ckr');if(!el)return;$('#ckb').disabled=true;el.innerHTML='<p class="note">Checking the server... up to 15 seconds.</p>';
try{const L=(await api('api/check')).items,n={fail:0,warn:0,ok:0};L.forEach(x=>n[x.st]++);const col={ok:'var(--g)',warn:'var(--y)',fail:'var(--r)'};
el.innerHTML=`<div class="tl3" style="margin:10px 0"><div class="tile"><b style="color:var(--r)">${n.fail}</b><small>PROBLEMS</small></div><div class="tile"><b style="color:var(--y)">${n.warn}</b><small>WARNINGS</small></div><div class="tile"><b style="color:var(--g)">${n.ok}</b><small>OK</small></div></div>`+
L.map(x=>`<div class="ckx"><span class="dot" style="background:${col[x.st]}"></span><div class="ckm"><b>${X(x.name)}</b><small>${X(x.msg)}</small></div>${x.fix?`<button type="button" class="btn sm${x.st=='fail'?' pri':''}" data-fx="${X(x.fix)}">Fix</button>`:''}</div>`).join('')+`<p class="note" style="margin-top:8px">Checked at ${new Date().toLocaleTimeString()}. The same check runs on the server with menu → Server check.</p>`}
catch(x){el.innerHTML=`<p class="err">${X(x.message)}</p>`}$('#ckb').disabled=false}
function featTick(){}
const AP=(u,k,v)=>{const p=v||u.ports[k],a=u.alt&&u.alt[k];return a?p+' (or '+a+')':p};const LSG={};let GSEL=null;
const GL=[['pf','Panel login','key','Username, password, 2FA'],['pfc','Performance mode','bolt','Low ping, balanced or max speed'],['apf','Appearance','palette','Theme, colour, brand name'],['pac','Panel address','key','Secret path and panel link'],['ppc','Panel and ports','shield','Panel URL, port, login protection'],['pwc','Phone app','dev','Install the panel as an app'],['cf','SSL certificate','cert','For the panel and V2Ray (Xray)'],['rf','Routing and WARP','net','Xray users: block, direct, WARP'],['fsc','Fake website','globe','What visitors see on your domain']],TMG=Object.fromEntries(GL.map(g=>[g[0],1]));
let CAPID='';const capShow=c=>{CAPID=c.id;$('#capi').src=c.img;$('#lcap').value='';$('#capw').hidden=false};
$('#capr').innerHTML=I('refresh',17);$('#capr').onclick=()=>fetch('api/captcha',{cache:'no-store'}).then(r=>r.json()).then(capShow).catch(()=>{});
$('#lf').onsubmit=async e=>{e.preventDefault();const r=await fetch('api/login',{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify({u:$('#lu').value.trim(),p:$('#lp').value,code:$('#lc').value,cid:CAPID,cap:$('#lcap').value})});const j=await r.json().catch(()=>({}));
if(r.ok){$('#lp').value='';$('#lc').value='';$('#lcw').hidden=true;$('#capw').hidden=true;CAPID='';$('#le').textContent='';return load()}
if(j.captcha)capShow(j.captcha);if(j.needcap&&!j.need2fa){$('#le').textContent=j.e;$('#lcap').focus();return}
if(j.need2fa){const first=$('#lcw').hidden;$('#lcw').hidden=false;$('#lc').focus();$('#le').textContent=first?'':j.e;return}$('#le').textContent=j.e||'Error '+r.status};
load();setInterval(()=>{if(!document.hidden&&!$('#app').hidden)load()},3000);
const SXS=[['Overview','page','ov','dashboard graphs cpu ram speed traffic top users protocol'],['V2Ray users','page','us:v2ray','users list vless reality'],['Inbounds','page','ib','inbound inbounds add port protocol xhttp tcp tls reality trojan cdn config'],['SSH users','page','us:ssh','users list ssh'],['OpenVPN users','page','us:ovpn','users list openvpn ovpn vpn certificate'],['UDP users','page','us:hy2','users list udp hysteria hysteria2 hy2'],['WireGuard users','page','us:wg','users list wireguard wg conf qr'],['DNS users','page','us:dns','users list dns dnstt slowdns tunnel domain'],['Online','page','on','online connected kick ip'],['Security','page','sc','sessions devices login history activity log'],['Settings','page','st','settings'],
['SSL certificate','set','xray cf','cert certificate domain lets encrypt tls'],['Xray defaults (SNI, host, path, Reality)','set','xray xf','sni host path reality xhttp keys'],['Routing (torrent, ads, WARP, port 25)','set','xray rf','routing block torrent ads warp smtp port 25'],
['Fake website','set','general fsc','fake website decoy camouflage port 80'],['Reality target finder','set','xray rfc','reality target sni finder best'],['Panel login and 2FA','set','general pf','password username login 2fa two factor'],
['Appearance (brand, colour, theme)','set','general apf','brand logo colour color accent theme dark black amoled tagline'],['Phone app','set','general pwc','pwa install app home screen'],['Panel and ports','set','general ppc','ports url'],
['Panel address (secret path)','set','general pac','path url secret address change'],['Telegram and alerts','set','telegram af','telegram bot alerts report backup auto delete health'],['Subscription page and config names','set','sub spf','announcement config name flag sub page'],
['Speed test, port check, reboot','set','tools tf','speed test speedtest port check reboot schedule'],['Xray core update','set','tools xuc','xray update version core'],['DuckDNS','set','tools ddc','duckdns ddns domain ip'],
['Disk cleanup and swap','set','tools mtc','cleanup clean disk swap memory'],['CDN mode (Cloudflare)','set','cdn cdnf','cdn cloudflare orange proxied hide ip'],['Payloads','set','pay payc','payload payloads builder bug host http custom injector'],['Payload builder','set','pay payf','new payload preset test split'],['Ports','set','ports prc','ports port manager firewall ufw listening open'],['443 mode (HAProxy)','set','ports h4c','443 80 haproxy one port mode'],['Server check','set','check ckc','server check diagnose problems fix health doctor'],['Performance mode','set','general pfc','performance speed latency ping throughput tuning'],['Backup and restore','set','backup bkc','backup restore'],['Server logs','set','logs lgc','logs journal errors access'],
['Add user','act','add','new create user'],['Trial user','act','trial','trial test'],['Bulk actions and CSV','act','bulk','bulk csv export import']];
let SXL=[],SXA=0;
function sxOpen(){if($('#app').hidden)return;$('#sxo').hidden=false;$('#sxi').value='';sxRun();setTimeout(()=>$('#sxi').focus(),10)}
function sxRun(){const q=$('#sxi').value.trim().toLowerCase(),w=q.split(/\s+/).filter(Boolean),m=t=>w.every(x=>t.includes(x));
const us=q&&D?D.users.filter(u=>m((u.name+' '+(u.note||'')).toLowerCase())).slice(0,8).map(u=>({k:'user',n:u.name,l:u.name,sub:STN[u.st]})):[];
const it=SXS.filter(x=>q?m((x[0]+' '+x[3]).toLowerCase()):x[1]!='set').map(x=>({k:x[1],t:x[2],l:x[0],sub:x[1]=='set'?'Settings':x[1]=='act'?'Action':'Page'}));
SXL=[...us,...it];SXA=0;const grp=(h,a)=>a.length?`<div class="sxh">${h}</div>`+a.map(o=>{const i=SXL.indexOf(o);return `<button type="button" class="sxi${i==0?' on':''}" data-sx="${i}" role="option">${o.k=='user'?av(o.n):I(o.k=='set'?'gear':o.k=='act'?'plus':'panel',16)}<span>${X(o.l)}</span><small>${X(o.sub)}</small></button>`}).join(''):'';
$('#sxr').innerHTML=SXL.length?grp('Users',us)+grp(q?'Settings and pages':'Go to',it):'<p class="note" style="padding:10px">Nothing found</p>'}
function sxGo(i){const o=SXL[i];if(!o)return;$('#sxo').hidden=true;
if(o.k=='user'){const uu=D.users.find(x=>x.name==o.n);if(uu&&uu.kind!='both')UV.kind=uu.kind;go('us');return openU(o.n)}if(o.k=='page')return go(o.t);
if(o.k=='act'){if(o.t=='bulk'){go('us');return bulkm()}return kpick(k=>{UV.kind=k;go('us');o.t=='add'?umodal(null,null,k):trial(k)})}
const [tb,id]=o.t.split(' ');jump(tb,id)}
function jump(tb,id){if(TMG[id])GSEL=id;go('st');if(window.STAB)STAB(TMG[id]?'general':tb);const el=$('#'+id);if(el){el.scrollIntoView({block:'start',behavior:'smooth'});el.style.boxShadow='0 0 0 2px var(--a)';setTimeout(()=>el.style.boxShadow='',1800)}}
$('#sxi').oninput=sxRun;$('#sxr').onclick=e=>{const b=e.target.closest('[data-sx]');if(b)sxGo(+b.dataset.sx)};$('#sxx').onclick=()=>$('#sxo').hidden=true;$('#sxo').onclick=e=>{if(e.target.id=='sxo')$('#sxo').hidden=true};
$('#sxi').onkeydown=e=>{const n=SXL.length;if(!n)return;if(e.key=='ArrowDown'||e.key=='ArrowUp'){e.preventDefault();SXA=(SXA+(e.key=='ArrowDown'?1:n-1))%n;document.querySelectorAll('.sxi').forEach(b=>b.classList.toggle('on',+b.dataset.sx==SXA));document.querySelector('.sxi.on').scrollIntoView({block:'nearest'})}else if(e.key=='Enter'){e.preventDefault();sxGo(SXA)}};
document.querySelectorAll('.sxb').forEach(b=>{b.innerHTML=I('search',18);b.onclick=sxOpen});
document.addEventListener('keydown',e=>{const tg=e.target.tagName;if((e.key=='/'&&!/INPUT|TEXTAREA|SELECT/.test(tg))||((e.ctrlKey||e.metaKey)&&e.key.toLowerCase()=='k')){if(!$('#app').hidden){e.preventDefault();sxOpen()}}});
let IP=null;if('serviceWorker' in navigator)navigator.serviceWorker.register('sw.js').catch(()=>{});
addEventListener('beforeinstallprompt',e=>{e.preventDefault();IP=e;const b=$('#pwab');if(b)b.hidden=false});addEventListener('appinstalled',()=>{IP=null;toast('App installed')});
const isApp=()=>matchMedia('(display-mode: standalone)').matches||navigator.standalone;
</script></body></html>
PANELHTML
cat > /opt/tunnel-panel/user.html <<'USERHTML'
<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="robots" content="noindex"><title>My account</title><link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'%3E%3Crect width='32' height='32' rx='8' fill='%231f6feb'/%3E%3Cpath d='M10 9l12 14M22 9L10 23' stroke='%23fff' stroke-width='4' stroke-linecap='round'/%3E%3C/svg%3E">
<style>
:root{--bg:#eef0f5;--c:#fff;--c2:#f5f6f9;--l:#e4e7ec;--t:#1d2433;--m:#6b7385;--a:#1f6feb;--g:#16a34a;--r:#dc2626;--y:#d97706;color-scheme:light}
@media(prefers-color-scheme:dark){:root{--bg:#0e1117;--c:#161b24;--c2:#1d2330;--l:#262d3b;--t:#e5e9f0;--m:#8b94a5;--a:#4c8dff;--g:#3fd18b;--r:#f26b6b;--y:#f0b44c;color-scheme:dark}}
*{box-sizing:border-box;margin:0}
body{background:var(--bg);color:var(--t);font:15px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,"Noto Sans",sans-serif;font-variant-numeric:tabular-nums}
.w{max-width:620px;margin:auto;padding:18px 16px 40px}
.top{display:flex;align-items:center;justify-content:space-between;margin-bottom:14px}.top b{font-size:18px;font-weight:800}
.logo{font-weight:800;letter-spacing:.3px}.logo span,.logo i{font-style:normal;display:inline-block;background:linear-gradient(90deg,var(--a),#14b8a6,#8b5cf6,var(--a));background-size:300% 100%;-webkit-background-clip:text;background-clip:text;color:transparent;animation:lgs 7s linear infinite}
.logo i{animation:lgs 7s linear infinite,lgx 6s ease-in-out infinite}@keyframes lgs{to{background-position:300% 0}}@keyframes lgx{0%,84%,100%{transform:none}90%{transform:translateY(-.08em) scale(1.18) rotate(-8deg)}95%{transform:scale(1.05)}}
@media(prefers-reduced-motion:reduce){.logo span,.logo i{animation:none}}
.uch{display:flex;align-items:flex-end;gap:2px;height:100px;margin-top:8px}.uch i{flex:1;display:flex;flex-direction:column;justify-content:flex-end;height:100%;min-width:0}.uch i b{display:block;background:var(--a);border-radius:2px 2px 0 0}.uch i u{display:block;background:var(--m);opacity:.45}
.uax{display:flex;justify-content:space-between;font-size:11.5px;color:var(--m);margin-top:6px}
.card{background:var(--c);border:1px solid var(--l);border-radius:14px;padding:18px;margin-bottom:12px}
.lab{font-size:12px;font-weight:600;letter-spacing:.8px;text-transform:uppercase;color:var(--m);margin-bottom:10px}
.hd{display:flex;align-items:center;gap:12px}.hd b{font-size:20px;word-break:break-all}
.pill{margin-left:auto;font-size:11.5px;font-weight:700;letter-spacing:.4px;padding:3px 10px;border-radius:20px;border:1px solid currentColor;text-transform:uppercase;white-space:nowrap}
.big{font-size:30px;font-weight:700;margin:14px 0 2px}.big span{font-size:15px;color:var(--m);font-weight:500}
.bar{height:10px;border-radius:6px;background:var(--c2);border:1px solid var(--l);overflow:hidden;margin:10px 0}.bar i{display:block;height:100%}
.row{display:flex;justify-content:space-between;gap:12px;padding:9px 0;border-bottom:1px solid var(--l);font-size:14px}.row:last-child{border:0}.row span{color:var(--m)}.row b{text-align:right;word-break:break-all}
.cb{padding:12px 0;border-bottom:1px solid var(--l)}.cb:last-child{border:0;padding-bottom:0}
.cbh{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px}.cbh small{font-size:12px;font-weight:700;color:var(--m);text-transform:uppercase;letter-spacing:.4px}
.code{display:block;width:100%;text-align:left;font:12.5px/1.5 ui-monospace,Menlo,Consolas,monospace;color:var(--t);background:var(--c2);border:1px solid var(--l);border-radius:8px;padding:10px 12px;white-space:pre-wrap;word-break:break-all;cursor:copy}
.btn{font:inherit;font-size:13px;color:var(--t);background:var(--c);border:1px solid var(--l);border-radius:8px;padding:6px 12px;cursor:pointer}.btn:hover{border-color:var(--a);color:var(--a)}
button:focus-visible{outline:2px solid var(--a);outline-offset:2px}
.qr{background:#fff;border-radius:12px;padding:10px;display:flex;justify-content:center;margin-top:12px}.qr svg{width:100%;height:auto;max-width:260px}
.note{font-size:13px;color:var(--m);margin:6px 0 10px}.bad{color:var(--r)}
details summary{cursor:pointer;font-weight:600;padding:4px 0}details[open] summary{margin-bottom:6px}
#qrm{position:fixed;inset:0;background:rgba(10,14,22,.6);display:flex;align-items:center;justify-content:center;padding:16px;z-index:10}#qrm[hidden]{display:none}
#qrm .card{width:100%;max-width:340px;margin:0}
.toast{position:fixed;left:50%;bottom:24px;transform:translateX(-50%);background:var(--t);color:var(--bg);border-radius:10px;padding:10px 16px;font-size:14px;z-index:20}
.warn{border:1px solid var(--y);background:color-mix(in srgb,var(--y) 10%,var(--c));color:var(--t);border-radius:14px;padding:14px 16px;margin-bottom:12px;font-size:14px}.warn b{color:var(--y)}
.ann{border:1px solid var(--a);background:color-mix(in srgb,var(--a) 9%,var(--c));border-radius:14px;padding:14px 16px;margin-bottom:12px;font-size:14px;white-space:pre-wrap;word-break:break-word}.ann b{display:block;color:var(--a);font-size:12px;letter-spacing:.8px;text-transform:uppercase;margin-bottom:4px}
.apps{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px}.apps a{display:flex;flex-direction:column;align-items:center;gap:4px;text-decoration:none;color:var(--t);background:var(--c2);border:1px solid var(--l);border-radius:10px;padding:12px 6px;font-size:13px;font-weight:600;text-align:center}.apps a:hover{border-color:var(--a)}.apps small{color:var(--m);font-weight:500;font-size:11.5px}
.wide{color:var(--a);display:block;text-align:center;margin-top:10px;text-decoration:none;font-weight:600}
.pwf{margin-top:8px}.pwf label{display:block;font-size:13px;color:var(--m);font-weight:600;margin:10px 0 5px}.pwf input[type=password],.pwf input[type=text],.pwf select{width:100%;font:inherit;color:var(--t);background:var(--c2);border:1px solid var(--l);border-radius:8px;padding:9px 11px}
.pwf input:focus-visible{outline:2px solid var(--a);outline-offset:1px}.pwf .shw{display:flex;align-items:center;gap:8px;font-weight:500}.pwf .pri{margin-top:6px;background:var(--a);color:#fff;border-color:var(--a)}
.tg{font-size:13.5px;color:var(--m);margin:-8px 0 14px}
</style><style id="acs"></style></head><body>
<div class="w" id="app"></div><p style="text-align:center;font-size:12px;color:var(--m);margin:0 0 30px">Powered by <a href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener" style="color:var(--m)">ReXUI</a></p>
<div id="qrm" hidden><div class="card"><div class="cbh"><b id="qrt"></b><button class="btn" id="qrx">Close</button></div><div class="qr" id="qrs"></div></div></div>
<script src="/qr.js"></script>
<script>
const U=__DATA__;
const AP=(u,k,v)=>{const p=v||u.ports[k],a=u.alt&&u.alt[k];return a?p+' (or '+a+')':p};const X=s=>String(s??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const fb=b=>{const u=['B','KB','MB','GB','TB'];let i=0;b=+b||0;while(b>=1024&&i<4){b/=1024;i++}return (i?b.toFixed(2):b.toFixed(0))+' '+u[i]};
const SC={active:'var(--a)',online:'var(--g)',expired:'var(--r)',limit:'var(--r)',disabled:'var(--y)'},SN={active:'Active',online:'Active',expired:'Expired',limit:'Data limit reached',disabled:'Disabled'};
const CP=[];const cp=t=>{CP.push(t);return CP.length-1};
const cbox=(l,v,qr=true)=>{const i=cp(v);return `<div class="cb"><div class="cbh"><small>${X(l)}</small><span style="display:flex;gap:6px">${qr?`<button class="btn" data-qr="${i}" data-ql="${X(l)}">QR</button>`:''}<button class="btn" data-cp="${i}">Copy</button></span></div><button class="code" data-cp="${i}" aria-label="Copy ${X(l)}">${X(v)}</button></div>`};
const row=(k,v)=>`<div class="row"><span>${k}</span><b>${X(v)}</b></div>`;
const p=U.ports,h=U.whost,pct=U.lim?Math.min(100,U.used/(U.lim*1073741824)*100):0;
let left='No expiry';if(U.fdays)left=`Starts when you first connect (${U.fdays} day${U.fdays==1?'':'s'})`;else if(U.expts){const h=Math.ceil((U.expts*1000-Date.now())/36e5);left=h>0?`${U.exp} (${h} hour${h==1?'':'s'} left)`:`${U.exp} (expired)`}else if(U.exp!='never'){const d=Math.ceil((new Date(U.exp+'T23:59:59')-new Date())/864e5);left=d>=0?`${U.exp} (${d} day${d==1?'':'s'} left)`:`${U.exp} (expired)`}
const pl=[`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET wss://bug.com [protocol][crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]User-Agent: Mozilla/5.0[crlf][crlf]`,`GET http://${h}/ HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`CONNECT ${h}:${p.WS_PORT} HTTP/1.1[crlf]Host: ${h}[crlf][crlf]`];
const AC={blue:['#1f6feb','#4c8dff'],teal:['#0d9488','#2dd4bf'],green:['#15803d','#4ade80'],purple:['#7c3aed','#a78bfa'],pink:['#db2777','#f472b6'],orange:['#ea580c','#fb923c'],indigo:['#4f46e5','#818cf8']},ac=AC[U.accent]||AC.teal;
document.getElementById('acs').textContent=`:root{--a:${ac[0]}}@media(prefers-color-scheme:dark){:root{--a:${ac[1]}}}`;if(U.brand)document.title=U.brand+' · My account';
const dl=U.fdays||U.exp=='never'?1e9:U.expts?(U.expts*1000-Date.now())/864e5:Math.ceil((new Date(U.exp+'T23:59:59')-new Date())/864e5),soon=['active','online'].includes(U.st)&&(dl<=3||(U.lim&&pct>=90));
const soonTxt=soon?(dl<=3?(dl<1?'Your account expires today.':`Your account expires in ${Math.ceil(dl)} day${Math.ceil(dl)==1?'':'s'}.`):'')+(U.lim&&pct>=90?` You have used ${pct.toFixed(0)}% of your data.`:'')+' Contact your provider to renew.':'';
const H=U.hist||[],HM=Math.max(1,...H.map(x=>x[1]+x[2]));
document.getElementById('app').innerHTML=`<div class="top"><b>My account</b><b class="logo" aria-label="${X(U.brand||'ReXUI')}">${U.brand?`<span>${X(U.brand)}</span>`:'<span>Re</span><i>X</i><span>UI</span>'}</b></div>${U.tagline?`<p class="tg">${X(U.tagline)}</p>`:''}${U.announce?`<div class="ann" role="note"><b>Announcement</b>${X(U.announce)}</div>`:''}${soon?`<div class="warn"><b>Renew soon.</b> ${X(soonTxt.trim())}</div>`:''}${U.st=='disabled'?`<div class="warn"><b>Your account is paused.</b>${U.reason?' '+X(U.reason):' Please contact your provider.'}</div>`:U.st=='expired'?'<div class="warn"><b>Your account has expired.</b> Please contact your provider to renew it.</div>':U.st=='limit'?'<div class="warn"><b>You have used all your data.</b> Please contact your provider.</div>':''}
<div class="card"><div class="hd"><b>${X(U.name)}</b><span class="pill" style="color:${SC[U.st]}">${SN[U.st]}</span></div>
<div class="big">${fb(U.used)} <span>of ${U.lim?U.lim+' GB':'unlimited'}</span></div>${U.lim?`<div class="bar"><i style="width:${pct}%;background:${pct>90?'var(--r)':pct>75?'var(--y)':'var(--a)'}"></i></div>`:''}
${row('Upload',fb(U.up))}${row('Download',fb(U.down))}${row('Expires',left)}${row('Devices allowed',U.dev||'Unlimited')}</div>
${H.length?`<div class="card"><div class="lab">Daily usage (30 days)</div><div class="uch" role="img" aria-label="Daily data usage">${H.map(x=>`<i title="${x[0]}: ${fb(x[1]+x[2])}"><b style="height:${(x[1]/HM*100).toFixed(1)}%"></b><u style="height:${(x[2]/HM*100).toFixed(1)}%"></u></i>`).join('')}</div><div class="uax"><span>${H[0][0].slice(5)}</span><span>Today ${fb(H[H.length-1][1]+H[H.length-1][2])}</span></div></div>`:''}
${U.kind=="v2ray"||U.kind=="both"||U.kind=="hy2"?`<div class="card"><div class="lab">Subscription</div><p class="note">Add this link in v2rayNG, NekoBox or Hiddify (Subscription → Add). The app updates your configs automatically.${U.kind=="hy2"?" Your account uses Hysteria2 (UDP). If it does not connect, your network may block UDP.":""}</p>${cbox('Subscription link',U.sub,false)}<div class="qr">${RXQR.svg(U.sub,260)}</div>${U.jsub?`<p class="note" style="margin-top:14px">JSON link: full configs with TLS fragment, for v2rayNG / v2rayN (Subscription → Add, it works like the normal link). Use it if the normal link is blocked.</p>${cbox('JSON subscription',U.jsub,false)}`:''}</div>
<div class="card"><div class="lab">Get the app</div><p class="note">Install one of these apps, then add the subscription link above.</p><div class="apps">
<a href="https://github.com/2dust/v2rayNG/releases/latest" target="_blank" rel="noopener">v2rayNG<small>Android</small></a><a href="https://github.com/MatsuriDayo/NekoBoxForAndroid/releases/latest" target="_blank" rel="noopener">NekoBox<small>Android</small></a><a href="https://github.com/hiddify/hiddify-app/releases/latest" target="_blank" rel="noopener">Hiddify<small>Android · iPhone · PC</small></a></div>
<a class="wide" href="hiddify://import/${encodeURI(U.sub)}#${encodeURIComponent(U.brand||'ReXUI')}">Already have Hiddify? Tap to add your subscription</a></div>
<div class="card"><div class="lab">Configs</div><p class="note">Or add one config at a time. Tap to copy, or show the QR.</p>${U.links.map(l=>cbox(l.name+(l.alt?' · port '+(l.url.match(/:(\d+)\?/)||[])[1]+' (or '+l.alt+')':''),l.url)+(l.name=='VLESS XHTTP (no TLS)'&&!U.plaindomain?'<p class="note bad">This one may not work in new apps without a domain.</p>':'')).join('')}</div>`:""}
${U.kind=="dns"&&U.dns?`<div class="card"><div class="lab">DNS tunnel + V2Ray</div><p class="note">Use a DNS tunnel app (DNSTT / SlowDNS with V2Ray). Enter the nameserver and public key, pick a DNS resolver, then add the V2Ray config. It is slow, but works where only DNS is open.</p>
${row('Nameserver (NS)',U.dns.ns||'Ask your provider')}${row('DNS resolver','8.8.8.8')}${row('Faster (DoH)','https://dns.google/dns-query')}${row('HTTP Custom','SlowDNS · Type Auto')}${cbox('Public key',U.dns.pub,false)}${U.links.map(l=>cbox(l.name,l.url)).join("")}</div>`:""}
${U.kind=="ovpn"&&U.ovpn?`<div class="card"><div class="lab">OpenVPN</div><p class="note">Download your .ovpn file and import it in OpenVPN Connect, HTTP Custom or HTTP Injector. With the HTTP proxy on, the app connects through port ${U.ovpn.proxy} and sends the Host you type here.</p>
<form id="ovf" class="pwf"><label for="ovp">Port</label><select id="ovp">${U.ovpn.ports.map(x=>`<option value="${x}">TCP ${x}</option>`).join("")}</select>
<label for="ovh">Host (bug host, optional)</label><input id="ovh" type="text" value="${X(U.ovpn.host)}" placeholder="example: m.facebook.com" autocapitalize="none" spellcheck="false">
<label class="shw"><input type="checkbox" id="ovx" checked> Use the HTTP proxy (port ${U.ovpn.proxy})</label><p class="note bad" id="ove" role="alert"></p><button class="btn pri">Download .ovpn file</button></form>
${row('Server',U.addr)}${row('TCP ports',U.ovpn.ports.join(', '))}${row('HTTP proxy',U.addr+':'+U.ovpn.proxy)}</div>
<div class="card"><div class="lab">Get the app</div><div class="apps"><a href="https://openvpn.net/client/" target="_blank" rel="noopener">OpenVPN Connect<small>Android · iPhone · PC</small></a><a href="https://play.google.com/store/apps/details?id=xyz.easypro.httpcustom" target="_blank" rel="noopener">HTTP Custom<small>Android</small></a></div></div>`:""}
${U.kind=="wg"&&U.wg&&U.wg.conf?`<div class="card"><div class="lab">WireGuard</div><p class="note">Install the WireGuard app, tap + and scan this QR code. Or download the file and import it. This config works on one device at a time.</p><div class="qr">${RXQR.svg(U.wg.conf,280)}</div>
<a class="wide" href="${X(location.pathname.replace(/\/$/,'')+'/wg')}" download="${X(U.name.replace(/[^A-Za-z0-9_-]/g,'_').slice(0,15))}.conf">Download .conf file</a>${cbox('WireGuard config',U.wg.conf,false)}
${row('Server',U.addr)}${row('UDP port',U.wg.port)}</div>
<div class="card"><div class="lab">Get the app</div><div class="apps"><a href="https://play.google.com/store/apps/details?id=com.wireguard.android" target="_blank" rel="noopener">WireGuard<small>Android</small></a><a href="https://apps.apple.com/app/wireguard/id1441195209" target="_blank" rel="noopener">WireGuard<small>iPhone</small></a><a href="https://www.wireguard.com/install/" target="_blank" rel="noopener">WireGuard<small>PC</small></a></div></div>`:""}
${U.kind=="ssh"||U.kind=="both"?`<div class="card"><div class="lab">SSH account</div>${row('Host',U.addr)}${row('Username',U.name)}${row('Password',U.pw||'Ask your provider')}${row('SSH',p.SSH_PORT)}${row('SSH SSL / TLS',AP(U,'SSL_PORT'))}${row('SSH WebSocket',AP(U,'WS_PORT'))}${row('SSH WebSocket TLS',AP(U,'WSTLS_PORT'))}${row('UDPGW','127.0.0.1:'+p.UDPGW_PORT)}
${U.pays&&U.pays.length?`<div style="margin-top:12px"><div class="lab" style="font-size:13px">Payloads from your provider</div>${U.pays.map(x=>cbox(x.name+' · '+({ws:'SSH WebSocket · port '+p.WS_PORT,wstls:'SSH WebSocket TLS · port '+p.WSTLS_PORT,ssl:'SSH SSL · port '+p.SSL_PORT,proxy:'HTTP proxy'}[x.mode]||x.mode),x.text,false)+(x.note?`<p class="note" style="margin-top:4px">${X(x.note)}</p>`:'')).join('')}</div>`:''}
<details style="margin-top:12px"><summary>More WebSocket payloads</summary>${pl.map((x,i)=>cbox('Payload '+(i+1),x,false)).join('')}</details>
${U.pw?`<details style="margin-top:6px"><summary>Change password</summary><form id="pwf" class="pwf"><p class="note">This changes your SSH password. Your V2Ray configs and subscription link stay the same. If you forgot your current password, ask your provider.</p>
<label for="po">Current password</label><input id="po" type="password" autocomplete="current-password" required>
<label for="pn">New password</label><input id="pn" type="password" autocomplete="new-password" required>
<label for="pc">New password again</label><input id="pc" type="password" autocomplete="new-password" required>
<label class="shw"><input type="checkbox" id="ps"> Show passwords</label><p class="note bad" id="pe" role="alert"></p><button class="btn pri">Change password</button></form></details>`:''}</div>`:""}`;
const of=document.getElementById('ovf');if(of)of.onsubmit=async e=>{e.preventDefault();const b=of.querySelector('.pri'),oe=document.getElementById('ove'),pt=document.getElementById('ovp').value,x=document.getElementById('ovx').checked;oe.textContent='';b.disabled=true;
try{const r=await fetch(location.pathname.replace(/\/$/,'')+'/ovpn?port='+pt+'&host='+encodeURIComponent(document.getElementById('ovh').value.trim())+'&proxy='+(x?1:0));if(!r.ok){oe.textContent=(await r.text()).slice(0,200)||'Error '+r.status}else{const bl=await r.blob(),a=document.createElement('a');a.href=URL.createObjectURL(bl);a.download=U.name+'-'+pt+(x?'-proxy':'')+'.ovpn';document.body.append(a);a.click();setTimeout(()=>{URL.revokeObjectURL(a.href);a.remove()},1500)}}catch(z){oe.textContent='Network error, try again'}b.disabled=false};
const pf=document.getElementById('pwf');if(pf){document.getElementById('ps').onchange=e=>['po','pn','pc'].forEach(i=>document.getElementById(i).type=e.target.checked?'text':'password');
pf.onsubmit=async e=>{e.preventDefault();const g=i=>document.getElementById(i).value,pe=document.getElementById('pe'),b=pf.querySelector('.pri');pe.textContent='';
if(g('pn')!==g('pc'))return pe.textContent='The new passwords do not match';b.disabled=true;
try{const r=await fetch(location.pathname.replace(/\/$/,'')+'/pw',{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify({old:g('po'),new:g('pn')})}),j=await r.json().catch(()=>({}));
if(!r.ok){pe.textContent=j.e||'Error '+r.status;b.disabled=false;return}const o=document.createElement('div');o.className='toast';o.textContent='Password changed';document.body.append(o);setTimeout(()=>location.reload(),1200)}catch(x){pe.textContent='Network error, try again';b.disabled=false}}}
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(e){const a=document.createElement('textarea');a.value=t;a.style.position='fixed';a.style.opacity='0';document.body.append(a);a.select();document.execCommand('copy');a.remove()}const o=document.createElement('div');o.className='toast';o.textContent='Copied';document.body.append(o);setTimeout(()=>o.remove(),1800)}
document.addEventListener('click',e=>{const q=e.target.closest('[data-qr]');if(q){document.getElementById('qrt').textContent=q.dataset.ql;document.getElementById('qrs').innerHTML=RXQR.svg(CP[+q.dataset.qr],300);document.getElementById('qrm').hidden=false;return}
if(e.target.id=='qrm'||e.target.closest('#qrx'))return document.getElementById('qrm').hidden=true;const c=e.target.closest('[data-cp]');if(c)copy(CP[+c.dataset.cp])});
</script></body></html>
USERHTML
cat > /opt/tunnel-panel/qr.js <<'QRJS'
/* ReXUI QR: small QR Code generator (byte mode, ECC L/M), returns SVG. Based on the QR Code spec (ISO 18004). */
var RXQR=(function(){
var ECW={L:[-1,7,10,15,20,26,18,20,24,30,18,20,24,26,30,22,24,28,30,28,28,28,28,30,30,26,28,30,30,30,30,30,30,30,30,30,30,30,30,30,30],
M:[-1,10,16,26,18,24,16,18,22,22,26,30,22,22,24,24,28,28,26,26,26,26,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28]};
var NB={L:[-1,1,1,1,1,1,2,2,2,2,4,4,4,4,4,6,6,6,6,7,8,8,9,9,10,12,12,12,13,14,15,16,17,18,19,19,20,21,22,24,25],
M:[-1,1,1,1,2,2,4,4,4,5,5,5,8,9,9,10,10,11,13,14,16,17,17,18,20,21,23,25,26,28,29,31,33,35,37,38,40,43,45,47,49]};
var FB={L:1,M:0};
function raw(v){var r=(16*v+128)*v+64;if(v>=2){var n=Math.floor(v/7)+2;r-=(25*n-10)*n-55;if(v>=7)r-=36}return r}
function dataCw(v,e){return Math.floor(raw(v)/8)-ECW[e][v]*NB[e][v]}
function mul(x,y){var z=0;for(var i=7;i>=0;i--){z=(z<<1)^((z>>>7)*0x11D);z^=((y>>>i)&1)*x}return z&255}
function rsDiv(d){var r=[];for(var i=0;i<d-1;i++)r.push(0);r.push(1);var root=1;for(i=0;i<d;i++){for(var j=0;j<r.length;j++){r[j]=mul(r[j],root);if(j+1<r.length)r[j]^=r[j+1]}root=mul(root,2)}return r}
function rsRem(data,div){var r=div.map(function(){return 0});data.forEach(function(b){var f=b^r.shift();r.push(0);div.forEach(function(c,i){r[i]^=mul(c,f)})});return r}
function utf8(s){var o=[],t=unescape(encodeURIComponent(s));for(var i=0;i<t.length;i++)o.push(t.charCodeAt(i));return o}
function align(v){if(v==1)return[];var n=Math.floor(v/7)+2,step=Math.floor((v*8+n*3+5)/(n*4-4))*2,r=[6],pos=v*4+10;var t=[];for(var i=0;i<n-1;i++){t.push(pos);pos-=step}return r.concat(t.reverse())}
function make(text,ecl){
 ecl=ecl||'M';var bytes=utf8(text),v,e=ecl;
 for(v=1;v<=40;v++){var cap=dataCw(v,e)*8,need=4+(v<=9?8:16)+bytes.length*8;if(need<=cap)break}
 if(v>40){if(e=='M')return make(text,'L');throw Error('Text too long for QR')}
 var bits=[];function put(val,len){for(var i=len-1;i>=0;i--)bits.push((val>>>i)&1)}
 put(4,4);put(bytes.length,v<=9?8:16);bytes.forEach(function(b){put(b,8)});
 var cap=dataCw(v,e)*8;put(0,Math.min(4,cap-bits.length));put(0,(8-bits.length%8)%8);
 for(var p=0xEC;bits.length<cap;p^=0xEC^0x11)put(p,8);
 var data=[];for(var i=0;i<bits.length;i+=8){var b=0;for(var j=0;j<8;j++)b=(b<<1)|bits[i+j];data.push(b)}
 var nb=NB[e][v],ecw=ECW[e][v],rawc=Math.floor(raw(v)/8),ns=nb-rawc%nb,sl=Math.floor(rawc/nb),div=rsDiv(ecw),blocks=[],k=0;
 for(i=0;i<nb;i++){var dat=data.slice(k,k+sl-ecw+(i<ns?0:1));k+=dat.length;var ec=rsRem(dat,div);if(i<ns)dat.push(0);blocks.push(dat.concat(ec))}
 var res=[];for(i=0;i<blocks[0].length;i++)for(j=0;j<blocks.length;j++)if(i!=sl-ecw||j>=ns)res.push(blocks[j][i]);
 var n=v*4+17,M=[],F=[];for(i=0;i<n;i++){M.push(new Array(n).fill(false));F.push(new Array(n).fill(false))}
 function set(x,y,d){M[y][x]=d;F[y][x]=true}
 for(i=0;i<n;i++){set(6,i,i%2==0);set(i,6,i%2==0)}
 function finder(cx,cy){for(var dy=-4;dy<=4;dy++)for(var dx=-4;dx<=4;dx++){var x=cx+dx,y=cy+dy,d=Math.max(Math.abs(dx),Math.abs(dy));if(x>=0&&x<n&&y>=0&&y<n)set(x,y,d!=2&&d!=4)}}
 finder(3,3);finder(n-4,3);finder(3,n-4);
 var ap=align(v),na=ap.length;for(i=0;i<na;i++)for(j=0;j<na;j++){if(i==0&&j==0||i==0&&j==na-1||i==na-1&&j==0)continue;for(var dy=-2;dy<=2;dy++)for(var dx=-2;dx<=2;dx++)set(ap[i]+dx,ap[j]+dy,Math.max(Math.abs(dx),Math.abs(dy))!=1)}
 function fmt(mask){var d=FB[e]<<3|mask,r=d;for(var i=0;i<10;i++)r=(r<<1)^((r>>>9)*0x537);var b=(d<<10|r)^0x5412,g=function(i){return((b>>>i)&1)!=0};
  for(i=0;i<=5;i++)set(8,i,g(i));set(8,7,g(6));set(8,8,g(7));set(7,8,g(8));for(i=9;i<15;i++)set(14-i,8,g(i));
  for(i=0;i<8;i++)set(n-1-i,8,g(i));for(i=8;i<15;i++)set(8,n-15+i,g(i));set(8,n-8,true)}
 fmt(0);
 if(v>=7){var r=v;for(i=0;i<12;i++)r=(r<<1)^((r>>>11)*0x1F25);var vb=v<<12|r;for(i=0;i<18;i++){var bt=((vb>>>i)&1)!=0,a=n-11+i%3,c=Math.floor(i/3);set(a,c,bt);set(c,a,bt)}}
 var idx=0;for(var right=n-1;right>=1;right-=2){if(right==6)right=5;for(var vert=0;vert<n;vert++)for(j=0;j<2;j++){var x=right-j,up=((right+1)&2)==0,y=up?n-1-vert:vert;
  if(!F[y][x]&&idx<res.length*8){M[y][x]=((res[idx>>>3]>>>(7-(idx&7)))&1)!=0;idx++}}}
 function mk(m,x,y){switch(m){case 0:return(x+y)%2==0;case 1:return y%2==0;case 2:return x%3==0;case 3:return(x+y)%3==0;case 4:return(Math.floor(x/3)+Math.floor(y/2))%2==0;case 5:return x*y%2+x*y%3==0;case 6:return(x*y%2+x*y%3)%2==0;default:return((x+y)%2+x*y%3)%2==0}}
 function apply(m){for(var y=0;y<n;y++)for(var x=0;x<n;x++)if(!F[y][x]&&mk(m,x,y))M[y][x]=!M[y][x]}
 function score(){var s=0,dark=0,y,x;for(y=0;y<n;y++){var run=1;for(x=0;x<n;x++){if(M[y][x])dark++;if(x>0){if(M[y][x]==M[y][x-1]){run++;if(run==5)s+=3;else if(run>5)s++}else run=1}}}
  for(x=0;x<n;x++){run=1;for(y=1;y<n;y++){if(M[y][x]==M[y-1][x]){run++;if(run==5)s+=3;else if(run>5)s++}else run=1}}
  for(y=0;y<n-1;y++)for(x=0;x<n-1;x++){var c=M[y][x];if(c==M[y][x+1]&&c==M[y+1][x]&&c==M[y+1][x+1])s+=3}
  var t=n*n;s+=Math.floor(Math.abs(dark*20-t*10)/t)*10;return s}
 var best=0,bs=1e9;for(var m=0;m<8;m++){apply(m);fmt(m);var sc=score();if(sc<bs){bs=sc;best=m}apply(m)}
 apply(best);fmt(best);return M}
function svg(text,px){var M=make(text),n=M.length,q=4,s=n+q*2,d='';for(var y=0;y<n;y++)for(var x=0;x<n;x++)if(M[y][x])d+='M'+(x+q)+','+(y+q)+'h1v1h-1z';
 return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 '+s+' '+s+'" width="'+(px||260)+'" height="'+(px||260)+'" shape-rendering="crispEdges" role="img" aria-label="QR code"><rect width="'+s+'" height="'+s+'" fill="#fff"/><path d="'+d+'" fill="#000"/></svg>'}
return {make:make,svg:svg}})();
if(typeof module!=='undefined')module.exports=RXQR;
QRJS
chmod 700 /opt/tunnel-panel/panel.py
[ -f /etc/tunnel/panel.pem ] || openssl req -new -x509 -days 3650 -nodes -subj "/CN=ReXUI" -out /etc/tunnel/panel.pem -keyout /etc/tunnel/panel.pem 2>/dev/null
chmod 600 /etc/tunnel/panel.pem
NEWPASS=""
if [ ! -f /etc/tunnel/panel.json ]; then
  NEWPASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 12)
  python3 /opt/tunnel-panel/panel.py setlogin admin "$NEWPASS"
fi
cat > /etc/systemd/system/tunnel-panel.service <<S
[Unit]
Description=ReXUI web panel
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/tunnel-panel/panel.py run
Restart=always
RestartSec=2
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
S
mkdir -p /etc/systemd/system/squid.service.d
printf '[Service]\nLimitNOFILE=65535\n' > /etc/systemd/system/squid.service.d/rexui.conf
cat > /etc/systemd/system/rexui-dns.service <<'S'
[Unit]
Description=ReXUI DNS tunnel (dnstt)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/bin/sh /etc/tunnel/dns/run.sh
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
S
cat > /etc/systemd/system/rexui-hy2.service <<'S'
[Unit]
Description=ReXUI Hysteria2 (UDP)
After=network-online.target tunnel-panel.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/hysteria server -c /etc/tunnel/hy2/config.yaml --disable-update-check
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
S
cat > /etc/systemd/system/rexui-wg.service <<'S'
[Unit]
Description=ReXUI WireGuard (UDP)
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/python3 /opt/tunnel-panel/panel.py wg-up
ExecStop=/sbin/ip link del rxwg
[Install]
WantedBy=multi-user.target
S
cat > /etc/systemd/system/rexui-ovpn@.service <<'S'
[Unit]
Description=ReXUI OpenVPN %i
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/sbin/openvpn --suppress-timestamps --config /etc/tunnel/ovpn/%i.conf
Restart=always
RestartSec=3
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
S

step 10 "Terminal menu"
cat > $LIB/cert-deploy.sh <<'DEPM'
#!/bin/bash
C=/etc/tunnel/cert
chmod 644 $C/xray.crt; chmod 600 $C/xray.key
systemctl is-active --quiet tunnel-panel 2>/dev/null && systemd-run --quiet --on-active=3 /bin/systemctl restart tunnel-panel >/dev/null 2>&1 || true
exit 0
DEPM
cat > $LIB/cert.sh <<'CERTM'
#!/bin/bash
[ "$EUID" -ne 0 ] && { echo "Please run as root"; exit 1; }
C=/etc/tunnel/cert; LIB=/usr/local/lib/tunnel; A=/root/.acme.sh/acme.sh
mkdir -p $C
myip(){ curl -4 -s --max-time 5 ifconfig.me; }
free80(){ if ss -tlnp | grep -q ':80 '; then echo "Port 80 is in use:"; ss -tlnp | grep ':80 '; return 1; fi; }
need(){
  [ -x $A ] || curl -fsSL https://get.acme.sh | sh >/dev/null 2>&1
  [ -x $A ] || { echo "acme.sh could not be installed (check internet)"; return 1; }
  $A --set-default-ca --server letsencrypt >/dev/null 2>&1
}
status(){
  [ -f $C/xray.crt ] || { echo "No certificate yet"; return; }
  SOURCE=?; NAME=?; . $C/info 2>/dev/null
  e=$(openssl x509 -in $C/xray.crt -noout -enddate | cut -d= -f2)
  echo; echo "Source : $SOURCE ($NAME)"
  echo "Expiry : $e ($(( ($(date -d "$e" +%s)-$(date +%s))/3600 )) hours left)"
  echo "Files  : $C/xray.crt , $C/xray.key"
}
inst(){
  $A --installcert -d "$1" --ecc --key-file $C/xray.key --fullchain-file $C/xray.crt --reloadcmd "$LIB/cert-deploy.sh" || { echo "Certificate install failed"; return 1; }
  printf 'SOURCE=%s\nNAME=%s\n' "$2" "$1" > $C/info
  echo "Done: $2 certificate installed"; status
}
domcert(){
  read -rp "Domain: " dm; dm=${dm,,}
  [[ $dm =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "Invalid domain"; return; }
  IP=$(myip); DI=$(getent ahostsv4 "$dm" | awk '{print $1; exit}')
  [ "$DI" = "$IP" ] || { echo "Domain points to '$DI' but this server is '$IP'. Fix the A record (Cloudflare: DNS only)"; return; }
  need || return
  if [ -f /etc/tunnel/fsite.on ]; then MODE="--webroot /etc/tunnel/acme-www"; mkdir -p /etc/tunnel/acme-www; else free80 || return; MODE="--standalone --httpport 80"; fi
  $A --issue -d "$dm" $MODE --server letsencrypt --keylength ec-256 --force \
    || { echo "Failed. Is port 80 allowed in your provider firewall?"; return; }
  inst "$dm" domain
}
own(){
  echo "1) File path  2) Paste"; read -rp "Option: " m
  case $m in
    1) read -rp "Cert (fullchain) file path: " cf; read -rp "Private key file path: " kf;;
    2) cf=/tmp/own.crt; kf=/tmp/own.key
       echo "Paste the CERTIFICATE (fullchain), then type END on a new line:"; : > $cf
       while IFS= read -r l; do [ "$l" = END ] && break; echo "$l" >> $cf; done
       echo "Paste the PRIVATE KEY, then type END on a new line:"; : > $kf
       while IFS= read -r l; do [ "$l" = END ] && break; echo "$l" >> $kf; done;;
    *) return;;
  esac
  [ -f "$cf" ] && [ -f "$kf" ] || { echo "File not found"; return; }
  openssl x509 -in "$cf" -noout 2>/dev/null || { echo "Certificate is not valid"; return; }
  openssl pkey -in "$kf" -noout 2>/dev/null || { echo "Key is not valid"; return; }
  a=$(openssl x509 -in "$cf" -noout -pubkey | sha256sum); b=$(openssl pkey -in "$kf" -pubout | sha256sum)
  [ "$a" = "$b" ] || { echo "Certificate and key do not match"; rm -f /tmp/own.crt /tmp/own.key; return; }
  [ "$cf" -ef $C/xray.crt ] || cp "$cf" $C/xray.crt; [ "$kf" -ef $C/xray.key ] || cp "$kf" $C/xray.key
  rm -f /tmp/own.crt /tmp/own.key
  n=$(openssl x509 -in $C/xray.crt -noout -subject | sed 's/.*CN *= *//')
  printf 'SOURCE=custom\nNAME=%s\n' "$n" > $C/info; $LIB/cert-deploy.sh
  echo "Your certificate is installed (it does not auto-renew)"; status
}
renew(){
  SOURCE=?; NAME=?; . $C/info 2>/dev/null
  case $SOURCE in domain) need && $A --renew -d "$NAME" --ecc --force;; *) echo "This certificate type does not auto-renew";; esac
}
while true; do
  cat <<T

===== SSL CERTIFICATE (panel + Xray) =====
1) Your own certificate (file path or paste)
2) Domain cert (Let's Encrypt, auto-renew)
3) Renew now
4) Status
0) Back
T
  read -rp "Option: " o
  case $o in 1) own;; 2) domcert;; 3) renew;; 4) status;; 0) exit;; esac
done
CERTM
cat > /usr/local/bin/menu <<'MAINM'
#!/bin/bash
[ "$EUID" -ne 0 ] && { echo "Please run as root"; exit 1; }
CF=/etc/tunnel/config; LIB=/usr/local/lib/tunnel; PY=/opt/tunnel-panel/panel.py
UPDATE_URL="https://raw.githubusercontent.com/chaliraza777/ReXUI/main/install.sh"
G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; R='\033[1;31m'; D='\033[2m'; W='\033[1;37m'; N='\033[0m'
. $CF
myip(){ curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}'; }
url(){ local H; H=$(myip); if [ -f /etc/tunnel/cert/info ]; then NAME=; . /etc/tunnel/cert/info; [[ $NAME =~ [a-z] && $NAME != \** ]] && H=$NAME; fi; echo "https://$H:$PANEL_PORT/$WEB_PATH/"; }
on(){ systemctl is-active --quiet "$1" && echo -e "${G}ON${N}" || echo -e "${Y}OFF${N}"; }
fw(){ if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "$1"/tcp >/dev/null; fi; }
fwu(){ if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "$1"/udp >/dev/null; fi; }
kv(){ printf "  ${D}%-16s${N}%b\n" "$1" "$2"; }
hr(){ echo -e "${D}  ──────────────────────────────────────────────────${N}"; }
info(){
  . $CF; local U H
  U=$(url)
  echo -e "${W}  ReXUI v2.0 · Current Settings${N}"; hr
  kv "Panel user" "$(python3 $PY user) ${D}(hash only, option 4 sets a new one)${N}"
  kv "Panel port" "$PANEL_PORT"
  kv "Web path" "/$WEB_PATH/"
  if [ -f /etc/tunnel/cert/info ]; then NAME=; SRC=; . /etc/tunnel/cert/info; kv "Certificate" "${NAME:-self-signed}"; fi
  kv "443 mode" "$([ -f /etc/tunnel/h443.on ] && echo -e "${G}ON${N}" || echo OFF)"
  echo; echo -e "${W}  Services${N}"; hr
  kv "Panel" "$(on tunnel-panel)"; kv "Xray" "$(on xray)"; kv "stunnel" "$(on stunnel4)"; kv "SSH WS" "$(on ws-ssh)"; kv "UDPGW" "$(on badudp)"
  [ -f /etc/tunnel/h443.on ] && kv "HAProxy" "$(on haproxy)"
  [ -x /usr/local/bin/hysteria ] && kv "Hysteria2" "$(on rexui-hy2)"
  command -v wg >/dev/null && kv "WireGuard" "$(on rexui-wg)"
  [ -x /usr/local/bin/dnstt-server ] && kv "DNS tunnel" "$(on rexui-dns)"
  [ -f /etc/systemd/system/rexui-ovpn@.service ] && { kv "OpenVPN" "$(on rexui-ovpn@rx1194)"; kv "Squid" "$(on squid)"; }
  local RR; RR=$(timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$WS_PORT; printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\nUpgrade: websocket\\r\\n\\r\\n' >&3; head -c 12 <&3" 2>/dev/null)
  if [ "$RR" = "HTTP/1.1 101" ]; then kv "SSH WS test" "${G}OK${N} ${D}(if phones fail, open $WS_PORT in your provider firewall)${N}"; else kv "SSH WS test" "${Y}FAILED${N} ${D}(try option 8)${N}"; fi
  echo; echo -e "${W}  Ports${N}"; hr
  kv "SSH" "$SSH_PORT"; kv "SSL" "$SSL_PORT"; kv "SSH WS" "$WS_PORT"; kv "SSH WS TLS" "$WSTLS_PORT"; kv "UDPGW" "127.0.0.1:$UDPGW_PORT"
  [ -f /etc/systemd/system/rexui-ovpn@.service ] && { kv "OpenVPN TCP" "${OVPN1_PORT:-1194}, ${OVPN2_PORT:-110}"; kv "HTTP proxy" "${SQUID_PORT:-3128}"; }
  [ -x /usr/local/bin/hysteria ] && kv "Hysteria2 UDP" "${HY_PORT:-443} (hopping ${HY_HOP:-20000-30000})"
  command -v wg >/dev/null && kv "WireGuard UDP" "${WG_PORT:-51820}"
  python3 -c 'import json;L=[x for x in json.load(open("/etc/tunnel/inbounds.json")) if x.get("on",True)]
print("\n".join("%s\t%s"%(x["port"],x["name"]) for x in L) or "-\tno inbounds yet (panel → Inbounds)")' 2>/dev/null | while IFS=$'\t' read -r p n; do kv "V2Ray $p" "$n"; done
  echo; echo -e "${W}  Access URL${N}"; hr
  echo -e "  ${C}${U}${N}"
  H=$(myip); [ -n "$H" ] && [[ $U != *"$H"* ]] && echo -e "  ${C}https://$H:$PANEL_PORT/$WEB_PATH/${N}"
}
apply(){
  . $CF
  cat > /etc/stunnel/stunnel.conf <<S
pid = /var/run/stunnel4/stunnel4.pid
cert = /etc/stunnel/stunnel.pem
sslVersionMin = TLSv1.2
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1
[ssh-ssl]
accept = $( [ -f /etc/tunnel/h443.on ] && [ "$SSL_PORT" = 443 ] && echo 127.0.0.1:10443 || echo $SSL_PORT )
connect = 127.0.0.1:$SSH_PORT
[ssh-ws-tls]
accept = $WSTLS_PORT
connect = 127.0.0.1:$WS_PORT
S
  sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/python3 /usr/local/bin/ws-ssh.py $WS_PORT $SSH_PORT|" /etc/systemd/system/ws-ssh.service
  systemctl daemon-reload
  systemctl restart stunnel4 ws-ssh tunnel-panel
}
hop(){
  read -rp "New hopping range like 20000-30000 (0 = off) [${HY_HOP:-20000-30000}]: " r
  [ -z "$r" ] && { echo "No change"; return; }
  if [ "$r" != 0 ]; then
    [[ $r =~ ^([0-9]+)-([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -ge 1 ] && [ "${BASH_REMATCH[2]}" -le 65535 ] && [ "${BASH_REMATCH[1]}" -lt "${BASH_REMATCH[2]}" ] || { echo "Invalid range"; return; }
    if [ "${HY_PORT:-443}" -ge "${BASH_REMATCH[1]}" ] && [ "${HY_PORT:-443}" -le "${BASH_REMATCH[2]}" ]; then echo "The range cannot include the Hysteria2 port ${HY_PORT:-443}"; return; fi
    fwu "${r/-/:}"
  fi
  if grep -q "^HY_HOP=" $CF; then sed -i "s/^HY_HOP=.*/HY_HOP=$r/" $CF; else echo "HY_HOP=$r" >> $CF; fi; apply
  echo -e "${G}Done:${N} port hopping = $r. UDP users need to refresh their subscription."
}
ports(){
  while true; do
    . $CF
    cat <<T

===== PORT CHANGE =====
1) Panel         : $PANEL_PORT
2) SSH SSL       : $SSL_PORT
3) SSH WS        : $WS_PORT
4) SSH WS TLS    : $WSTLS_PORT
5) OpenVPN TCP 1 : ${OVPN1_PORT:-1194}
6) OpenVPN TCP 2 : ${OVPN2_PORT:-110}
7) HTTP proxy    : ${SQUID_PORT:-3128}
8) Hysteria2 UDP : ${HY_PORT:-443}
9) UDP hopping   : ${HY_HOP:-20000-30000}  (range, 0 = off)
0) Back
(V2Ray ports: change them in the panel → Inbounds)
T
    read -rp "Option: " o
    case $o in 1) K=PANEL_PORT;; 2) K=SSL_PORT;; 3) K=WS_PORT;; 4) K=WSTLS_PORT;; 5) K=OVPN1_PORT;; 6) K=OVPN2_PORT;; 7) K=SQUID_PORT;; 8) K=HY_PORT;; 9) hop; continue;; *) return;; esac
    case $K in OVPN1_PORT) dflt=1194;; OVPN2_PORT) dflt=110;; SQUID_PORT) dflt=3128;; HY_PORT) dflt=443;; *) dflt=;; esac; cur=${!K}; cur=${cur:-$dflt}; read -rp "New port [$cur]: " np
    [ -z "$np" ] || [ "$np" = "$cur" ] && { echo "No change"; continue; }
    if ! [[ $np =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then echo "Invalid port"; continue; fi
    if [ "$K" != HY_PORT ] && grep -E "^[A-Z_]*PORT=$np$" $CF | grep -v "^HY_PORT=" | grep -qv "^$K="; then echo "Port $np is already used by another protocol"; continue; fi
    [ "$np" = 22 ] || [ "$np" = 10085 ] && { echo "Port $np is reserved"; continue; }
    if [ "$K" != HY_PORT ] && python3 -c "import json,sys;sys.exit(0 if any(int(x['port'])==$np for x in json.load(open('/etc/tunnel/inbounds.json'))) else 1)" 2>/dev/null; then echo "Port $np is used by a V2Ray inbound (panel → Inbounds)"; continue; fi
    if [ "$K" = HY_PORT ]; then
      if ss -ulnH "sport = :$np" | grep -v hysteria | grep -q .; then echo "UDP port $np is in use:"; ss -ulnp "sport = :$np"; continue; fi
    elif ss -tlnH "sport = :$np" | grep -q .; then echo "Port $np is in use:"; ss -tlnp "sport = :$np"; continue; fi
    if grep -q "^$K=" $CF; then sed -i "s/^$K=.*/$K=$np/" $CF; else echo "$K=$np" >> $CF; fi
    if [ "$K" = HY_PORT ]; then fwu "$np"; else fw "$np"; fi; apply
    echo -e "${G}Done:${N} $K = $np. Allow port $np in your provider firewall."
    [ "$K" = PANEL_PORT ] && echo "New panel URL: $(url)"
    [[ $K == OVPN* || $K == SQUID_PORT ]] && echo "OpenVPN changed: users need to download a new .ovpn file."
    [ "$K" = HY_PORT ] && echo "Hysteria2 changed: UDP users need to refresh their subscription. Allow UDP $np in your provider firewall."
  done
}
srv(){
  cat <<T

===== SERVICE RESTART =====
1) All   2) SSH   3) stunnel4 (SSL + WS TLS)   4) SSH WS
5) UDPGW   6) Xray   7) Panel   8) Fail2ban   9) OpenVPN + HTTP proxy   10) Hysteria2   11) DNS tunnel   12) WireGuard   0) Back
T
  read -rp "Option: " o
  case $o in
    1) systemctl restart ssh 2>/dev/null || systemctl restart sshd; systemctl restart stunnel4 ws-ssh badudp xray tunnel-panel fail2ban; systemctl restart 'rexui-ovpn@*' squid rexui-hy2 2>/dev/null; command -v wg >/dev/null && systemctl restart rexui-wg 2>/dev/null; systemctl is-enabled --quiet rexui-dns 2>/dev/null && systemctl restart rexui-dns;;
    2) systemctl restart ssh 2>/dev/null || systemctl restart sshd;;
    3) systemctl restart stunnel4;; 4) systemctl restart ws-ssh;; 5) systemctl restart badudp;;
    6) systemctl restart xray;; 7) systemctl restart tunnel-panel;; 8) systemctl restart fail2ban;; 9) systemctl restart 'rexui-ovpn@*' squid;; 10) systemctl restart rexui-hy2;; 11) systemctl restart rexui-dns;; 12) systemctl restart rexui-wg;;
    *) BACK=1; return;;
  esac
  echo -e "${G}Restarted${N}"
}
bkp(){
  cat <<T

===== BACKUP / RESTORE =====
1) Create backup now
2) Restore from a backup
0) Back
T
  read -rp "Option: " o
  case $o in
    1) f=/root/rexui-backup-$(date +%F-%H%M).json
       python3 $PY backup "$f" >/dev/null && chmod 600 "$f" && echo -e "${G}Backup saved:${N} $f" && echo "It contains user passwords. Keep it private.";;
    2) mapfile -t L < <(ls -1t /root/rexui-backup-*.json /etc/tunnel/backups/rexui-*.json 2>/dev/null)
       if [ ${#L[@]} -gt 0 ]; then echo; for i in "${!L[@]}"; do echo "$((i+1))) ${L[$i]}"; done; fi
       read -rp "Pick a number or type a file path: " c
       if [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#L[@]} ]; then f=${L[$((c-1))]}; else f=$c; fi
       [ -f "$f" ] || { echo "File not found"; return; }
       read -rp "Restore users from $f? Other users are kept. (y/N): " y; [ "$y" = y ] || { echo "Cancelled"; return; }
       if python3 $PY restore "$f"; then systemctl restart tunnel-panel; echo -e "${G}Restore done${N}"; fi;;
    *) BACK=1;;
  esac
}
xarch(){ case $(uname -m) in x86_64|amd64) echo 64;; aarch64|arm64) echo arm64-v8a;; *) echo "";; esac; }
xswap(){ # $1 = folder with new xray and/or geo files
  local B=/usr/local/bin f
  rm -f $B/xray.old $B/geoip.dat.old $B/geosite.dat.old
  for f in xray geoip.dat geosite.dat; do [ -f "$1/$f" ] && cp -f "$B/$f" "$B/$f.old" 2>/dev/null; done
  [ -f "$1/xray" ] && install -m 755 "$1/xray" $B/xray
  for f in geoip.dat geosite.dat; do [ -f "$1/$f" ] && install -m 644 "$1/$f" $B/$f; done
  if ! $B/xray run -test -c /usr/local/etc/xray/config.json >/dev/null 2>&1; then
    echo -e "${Y}The new files do not accept the current config. Putting the old ones back.${N}"; xback quiet; return 1; fi
  systemctl restart xray; sleep 2
  if systemctl is-active --quiet xray; then systemctl restart tunnel-panel; echo -e "${G}Done:${N} $($B/xray version | head -1 | cut -d' ' -f1-2)"
  else echo -e "${Y}Xray did not start. Putting the old version back.${N}"; xback quiet; return 1; fi
}
xback(){
  local B=/usr/local/bin f any=0
  for f in xray geoip.dat geosite.dat; do [ -f "$B/$f.old" ] && { mv -f "$B/$f.old" "$B/$f"; any=1; }; done
  [ $any = 1 ] || { echo "No previous version saved"; return; }
  systemctl restart xray tunnel-panel; [ "$1" = quiet ] || echo -e "${G}Rolled back:${N} $($B/xray version | head -1 | cut -d' ' -f1-2)"
}
xupd(){
  local A d cur new; A=$(xarch); [ -n "$A" ] || { echo "This CPU ($(uname -m)) is not supported"; return; }
  cur=$(/usr/local/bin/xray version 2>/dev/null | awk 'NR==1{print "v"$2}')
  new=$(curl -fsSL --max-time 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest 2>/dev/null | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
  echo "Installed: ${cur:-unknown}   Latest: ${new:-could not check}"
  if [ -n "$new" ] && [ "$cur" = "$new" ]; then read -rp "You already have the latest. Reinstall anyway? (y/N): " y; else read -rp "Update Xray core and geo files now? (y/N): " y; fi
  [ "$y" = y ] || { echo "Cancelled"; return; }
  d=$(mktemp -d)
  local u="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$A.zip" XS
  if curl -fsSL -o $d/x.zip "$u" && curl -fsSL -o $d/x.dgst "$u.dgst"; then
    XS=$(grep -ioE '^SHA(2-)?256[^=]*= *[0-9a-f]{64}' $d/x.dgst | grep -ioE '[0-9a-f]{64}$' | head -1 | tr 'A-F' 'a-f')
    if [ -n "$XS" ] && [ "$(sha256sum $d/x.zip | awk '{print $1}')" = "$XS" ] && unzip -qo $d/x.zip xray geoip.dat geosite.dat -d $d; then echo "Checksum OK"; xswap $d
    else echo "Checksum did not match, nothing was changed"; fi
  else echo "Download failed, nothing was changed"; fi
  rm -rf $d
}
gupd(){
  local d; d=$(mktemp -d); echo "Downloading the latest geo files..."
  if curl -fsSL -o $d/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat \
     && curl -fsSL -o $d/gs.sum https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat.sha256sum \
     && curl -fsSL -o $d/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat \
     && curl -fsSL -o $d/gi.sum https://github.com/v2fly/geoip/releases/latest/download/geoip.dat.sha256sum \
     && [ "$(sha256sum $d/geosite.dat | awk '{print $1}')" = "$(awk '{print $1}' $d/gs.sum)" ] \
     && [ "$(sha256sum $d/geoip.dat | awk '{print $1}')" = "$(awk '{print $1}' $d/gi.sum)" ] \
     && [ $(stat -c %s $d/geosite.dat) -gt 100000 ] && [ $(stat -c %s $d/geoip.dat) -gt 100000 ]; then echo "Checksums OK"; rm -f $d/*.sum; xswap $d
  else echo "Download failed, nothing was changed"; fi
  rm -rf $d
}
updm(){
  cat <<T

===== UPDATE =====
1) Update ReXUI (new install.sh)
2) Update Xray core + geo files
3) Update geo files only (ads and WARP site lists)
4) Roll back Xray to the previous version
0) Back
T
  read -rp "Option: " o
  case $o in 1) upd;; 2) xupd;; 3) gupd;; 4) xback;; *) BACK=1;; esac
}
upd(){
  local f=/root/install.sh
  if [ -n "$UPDATE_URL" ]; then
    echo "Downloading the latest installer..."
    curl -fsSL "$UPDATE_URL" -o /tmp/rexui-install.sh && f=/tmp/rexui-install.sh || { echo "Download failed"; return; }
  else
    echo "Upload the new install.sh to the server first."
    read -rp "Path to the new installer [$f]: " x; f=${x:-$f}
  fi
  [ -f "$f" ] || { echo "File not found: $f"; return; }
  head -5 "$f" | grep -q "ReXUI v[0-9.]* installer" || { echo "This is not a ReXUI installer"; return; }
  bash -n "$f" 2>/dev/null || { echo "The file is broken (maybe it was cut while pasting)"; return; }
  echo "Installed: $(grep -o 'ReXUI v[0-9.]*' /opt/tunnel-panel/index.html | head -1)   New: $(grep -o 'ReXUI v[0-9.]*' "$f" | head -1)"
  read -rp "Update now? Users, settings, ports and certificate are kept. (y/N): " y; [ "$y" = y ] || { echo "Cancelled"; return; }
  b=/root/rexui-backup-before-update-$(date +%F-%H%M).json
  python3 $PY backup "$b" >/dev/null 2>&1 && chmod 600 "$b" && echo "Backup saved: $b"
  bash "$f"; exit 0
}
spdt(){
  local d=$LIB/ookla a v=1.2.0
  if [ ! -x $d/speedtest ]; then
    case $(uname -m) in x86_64|amd64) a=x86_64;; aarch64|arm64) a=aarch64;; armv7l) a=armhf;; *) echo "This CPU ($(uname -m)) is not supported"; return;; esac
    echo "Downloading Ookla Speedtest CLI (first time only)..."
    mkdir -p $d; local t; t=$(mktemp -d)
    if curl -fsSL --max-time 60 -o $t/s.tgz "https://install.speedtest.net/app/cli/ookla-speedtest-$v-linux-$a.tgz" && tar -xzf $t/s.tgz -C $t speedtest 2>/dev/null && [ -s $t/speedtest ]; then
      install -m 755 $t/speedtest $d/speedtest; rm -rf $t
    else rm -rf $t; echo -e "${Y}Download failed.${N} Check the server's internet and try again."; return; fi
  fi
  echo -e "${C}Testing... (about 30 seconds)${N}"
  $d/speedtest --accept-license --accept-gdpr -p no 2>&1 | grep -vE '^\s*$|^==|Speedtest by Ookla' || echo -e "${Y}The test did not finish. Try again in a minute.${N}"
  echo "Tip: to test one server, run:  $d/speedtest -L  then  $d/speedtest -s ID"
}
perfm(){
  echo "Now: $(python3 $PY perf | sed 's/Performance mode: //')"
  cat <<T
1) Low ping   (gaming, calls, browsing)
2) Balanced   (best for most servers)
3) Max speed  (downloads and streaming, uses more memory)
0) Back
T
  read -rp "Option: " o
  case $o in 1) m=latency;; 2) m=balanced;; 3) m=throughput;; *) BACK=1; return;; esac
  python3 $PY perf $m && echo -e "${G}Done.${N} Nobody was disconnected."
}
h443m(){
  python3 $PY h443
  cat <<T
1) Turn on   (TLS protocols on 443, WebSocket and XHTTP on 80, old ports keep working)
2) Turn off  (back to one port per protocol)
0) Back
T
  read -rp "Option: " o
  case $o in 1) python3 $PY h443 on;; 2) python3 $PY h443 off;; *) BACK=1;; esac
}
uninst(){
  echo -e "${Y}This removes the panel, Xray, OpenVPN, Hysteria2, WireGuard, the DNS tunnel, the SSH WS/SSL tunnels and all panel users.${N}"
  read -rp "Type yes to confirm: " y; [ "$y" = yes ] || { echo "Cancelled"; return; }
  f=/root/rexui-backup-before-uninstall-$(date +%F-%H%M).json
  python3 $PY backup "$f" >/dev/null 2>&1 && chmod 600 "$f" && echo "A final backup was saved to $f"
  systemctl disable --now tunnel-panel xray ws-ssh badudp stunnel4 >/dev/null 2>&1
  for u in $(systemctl list-units --all --plain --no-legend 'rexui-ovpn@*' 2>/dev/null | awk '{print $1}') rexui-ovpn@rx1194 rexui-ovpn@rx110; do systemctl disable --now "$u" >/dev/null 2>&1; done
  systemctl disable --now rexui-hy2 rexui-wg rexui-dns >/dev/null 2>&1
  if [ -f /etc/tunnel/h443.on ]; then systemctl disable --now haproxy >/dev/null 2>&1; [ -f /etc/haproxy/haproxy.cfg.orig ] && mv -f /etc/haproxy/haproxy.cfg.orig /etc/haproxy/haproxy.cfg; rm -f /etc/haproxy/rexui.pem; fi
  python3 $PY purge 2>/dev/null
  if [ -f /etc/squid/squid.conf.orig ]; then mv -f /etc/squid/squid.conf.orig /etc/squid/squid.conf; systemctl disable --now squid >/dev/null 2>&1; fi
  rm -f /etc/systemd/system/rexui-ovpn@.service /etc/systemd/system/rexui-hy2.service /usr/local/bin/hysteria /etc/systemd/system/rexui-tuic.service /usr/local/bin/tuic-server /etc/systemd/system/rexui-wg.service /etc/sysctl.d/99-rexui-wg.conf /etc/systemd/system/rexui-dns.service /usr/local/bin/dnstt-server /etc/sysctl.d/99-rexui-ovpn.conf /etc/sysctl.d/99-zz-rexui-perf.conf
  rm -f /etc/systemd/system/{tunnel-panel,xray,ws-ssh,badudp}.service /etc/stunnel/stunnel.conf /etc/cron.d/tunnel-expire
  rm -f /etc/cron.d/rexui-reboot; rm -rf /opt/tunnel-panel /usr/local/etc/xray /usr/local/bin/xray /usr/local/bin/ws-ssh.py /usr/local/bin/badvpn-udpgw /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat /etc/tunnel /etc/tunnel-users /var/log/xray $LIB
  systemctl daemon-reload
  rm -f /usr/local/bin/menu
  echo -e "${G}Uninstalled.${N} SSH (port 22), BBR and fail2ban were kept."
  exit 0
}
dot(){ systemctl is-active --quiet "$1" && printf "${G}●${N}%s" "$2" || printf "${R}●%s${N}" "$2"; }
st(){ systemctl is-active --quiet "$1" && echo -e "${G}Running${N}" || echo -e "${R}Not running${N}"; }
status(){
  local a b c d cpu ram on
  read -r _ a b c d _ < /proc/stat; local t1=$((a+b+c+d)) i1=$d
  sleep 0.3
  read -r _ a b c d _ < /proc/stat; local t2=$((a+b+c+d)) i2=$d
  cpu=$(( t2>t1 ? 100*((t2-t1)-(i2-i1))/(t2-t1) : 0 ))
  ram=$(free -m | awk '/^Mem:/{print $2-$7"M / "$2"M"}')
  on=$(cat /run/rexui-online 2>/dev/null || echo -)
  local cc=$G; [ $cpu -ge 70 ] && cc=$Y; [ $cpu -ge 90 ] && cc=$R
  echo -e "  Panel state     : $(st tunnel-panel)"
  echo -e "  Xray state      : $(st xray)"
  [ -f /etc/tunnel/h443.on ] && echo -e "  HAProxy state   : $(st haproxy)"
  echo -e "  Start on boot   : $(systemctl is-enabled --quiet tunnel-panel && echo -e "${G}Yes${N}" || echo -e "${Y}No${N}")"
  echo -e "  CPU / RAM       : ${cc}${cpu}%${N} / ${ram}"
  echo -e "  Online users    : ${W}${on}${N}"
}
lastline(){ journalctl -u "$1" --since "24 hours ago" --no-pager -o short-iso 2>/dev/null | grep -iE "$2" | grep -viE 'PROXY protocol|deprecated|please migrate' | tail -1 | sed -E 's/^[0-9-]+T([0-9:]{5})[^ ]* [^ ]+ [^:]+: /\1 /; s#[0-9]{4}/[0-9]{2}/[0-9]{2} [0-9:.]+ ##' | cut -c1-70; }
logs(){
  echo -e "${W}LOGS${N} ${D}(last problem in 24h)${N}"
  local x
  x=$(lastline xray '\[(Warning|Error)\]|failed|panic'); printf "${C}%-8s${N}%s\n" Xray "${x:-$(echo -e "${G}no errors${N}")}"
  x=$(lastline tunnel-panel 'error|fail|traceback|refused'); printf "${C}%-8s${N}%s\n" Panel "${x:-$(echo -e "${G}no errors${N}")}"
  if [ -f /etc/tunnel/h443.on ]; then x=$(lastline haproxy 'alert|emerg|err|warn|fail'); printf "${C}%-8s${N}%s\n" HAProxy "${x:-$(echo -e "${G}no errors${N}")}"; fi
  x=$(systemctl --failed --no-legend --plain 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
  [ -n "$x" ] && echo -e "${R}Stopped:${N} $x"
  echo; echo "1) Xray log   2) Panel log   3) HAProxy log   4) Live (Ctrl+C stops)   0) Back"
  read -rp "Option: " o
  case $o in
    1) journalctl -u xray -n 40 --no-pager -o short;;
    2) journalctl -u tunnel-panel -n 40 --no-pager -o short;;
    3) journalctl -u haproxy -n 40 --no-pager -o short;;
    4) trap ':' INT; journalctl -f -n 10 -u xray -u tunnel-panel -u haproxy -o short; trap - INT;;
    *) BACK=1;;
  esac
}
pause(){ echo; read -n1 -s -r -p "$(echo -e "${C} Press any key to go back to the menu ${N}")"; echo; }
B='\033[1;34m'
mt(){ printf "${B}│${N} ${W}%-49s${N}${B}│${N}\n" "$1"; }
mi(){ printf "${B}│${N}  ${G}%2s.${N} %-44s${B}│${N}\n" "$1" "$2"; }
ms(){ echo -e "${B}├──────────────────────────────────────────────────┤${N}"; }
while true; do
  clear
  echo -e "${B}╔══════════════════════════════════════════════════╗${N}"
  printf "${B}║${N}  ${W}%-30s${N}${D}%18s${N}${B}║${N}\n" "ReXUI Panel Management Script" "v2.0 "
  echo -e "${B}╚══════════════════════════════════════════════════╝${N}"
  echo -e "${B}┌──────────────────────────────────────────────────┐${N}"
  mi 0 "Exit Script"; ms
  mt "Install & Update"; mi 1 "Update"; mi 2 "Uninstall"; ms
  mt "Panel"; mi 3 "View Current Settings"; mi 4 "Reset Username & Password"; mi 5 "Restart Panel"; mi 6 "Change Ports"; mi 7 "SSL Certificate Management"; ms
  mt "Services"; mi 8 "Restart Services"; mi 9 "Check Logs"; mi 10 "Server Check"; mi 11 "Firewall Check"; ms
  mt "Tools"; mi 12 "Backup & Restore"; mi 13 "Performance"; mi 14 "443 Mode (one port)"; mi 15 "Speed Test"
  echo -e "${B}└──────────────────────────────────────────────────┘${N}"
  echo; status; echo
  BACK=; read -rp "$(echo -e "  Please enter your selection ${W}[0-15]${N}: ")" o; clear
  case $o in
    1) updm;;
    2) uninst;;
    3) info;;
    4) read -rp "New username: " u; read -rsp "New password: " p; echo
       python3 $PY setlogin "$u" "$p" && systemctl restart tunnel-panel && echo -e "${G}Login changed${N}";;
    5) systemctl restart tunnel-panel && echo -e "${G}Panel restarted${N}";;
    6) ports; BACK=1;;
    7) $LIB/cert.sh;;
    8) srv;;
    9) logs;;
    10) python3 $PY check;;
    11) python3 $PY fwcheck;;
    12) bkp;;
    13) perfm;;
    14) h443m;;
    15) spdt;;
    0) exit 0;;
    *) BACK=1;;
  esac
  [ -z "$BACK" ] && pause
done
MAINM
chmod +x $LIB/*.sh /usr/local/bin/menu
rm -f $LIB/ssh.sh $LIB/v2ray.sh $LIB/payloads.sh $LIB/panel.sh /etc/cron.d/tunnel-expire

step 11 "Services start + firewall"
systemctl daemon-reload
systemctl enable badudp ws-ssh xray tunnel-panel >/dev/null 2>&1
python3 /opt/tunnel-panel/panel.py ovpn-setup || true
systemctl enable rexui-ovpn@rx1194 rexui-ovpn@rx110 squid >/dev/null 2>&1 || true
systemctl restart rexui-ovpn@rx1194 rexui-ovpn@rx110 squid || echo "WARNING: OpenVPN or Squid did not start, see: journalctl -u rexui-ovpn@rx1194 -u squid"
if [ -x /usr/local/bin/hysteria ]; then
  python3 /opt/tunnel-panel/panel.py hy-setup || true
  systemctl enable rexui-hy2 >/dev/null 2>&1 || true
  systemctl restart rexui-hy2 || echo "WARNING: Hysteria2 did not start, see: journalctl -u rexui-hy2"
fi
if command -v wg >/dev/null; then
  systemctl enable rexui-wg >/dev/null 2>&1 || true
  systemctl restart rexui-wg || echo "WARNING: WireGuard did not start, see: journalctl -u rexui-wg"
fi
[ -x /usr/local/bin/dnstt-server ] && { python3 /opt/tunnel-panel/panel.py dns-setup || true; }
systemctl restart badudp ws-ssh stunnel4 tunnel-panel
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $SSH_PORT $SSL_PORT $WS_PORT $WSTLS_PORT $PANEL_PORT $OVPN1_PORT $OVPN2_PORT $SQUID_PORT 80; do ufw allow $p/tcp >/dev/null; done
  ufw allow $HY_PORT/udp >/dev/null; ufw allow $WG_PORT/udp >/dev/null; ufw allow 53/udp >/dev/null; if [[ $HY_HOP =~ ^[0-9]+-[0-9]+$ ]]; then ufw allow ${HY_HOP/-/:}/udp >/dev/null; fi
fi
sleep 6
for i in $(seq 20); do systemctl is-active --quiet xray && break; sleep 1; done
R=$(timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$WS_PORT; printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3; head -c 12 <&3" 2>/dev/null || true)
PH=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
if [ -f /etc/tunnel/cert/info ]; then NAME=; . /etc/tunnel/cert/info; [[ $NAME =~ [a-z] && $NAME != \** ]] && PH=$NAME; fi
echo -e "\n\033[1;32m==============================\033[0m"
for s in ssh stunnel4 ws-ssh badudp xray fail2ban tunnel-panel rexui-ovpn@rx1194 rexui-ovpn@rx110 squid rexui-hy2 rexui-wg rexui-dns; do
  x=$(systemctl is-active $s 2>/dev/null || true); [ $s = ssh ] && [ "$x" != active ] && x=$(systemctl is-active sshd 2>/dev/null || true); printf "%-18s: %s\n" $s "$x"
done
echo "SSH $SSH_PORT | SSL $SSL_PORT | WS $WS_PORT | WS TLS $WSTLS_PORT | UDPGW 127.0.0.1:$UDPGW_PORT"
echo "V2Ray     : add your inbounds in the panel (Inbounds), then allow their ports in your provider firewall"
echo "OpenVPN TCP $OVPN1_PORT, $OVPN2_PORT | HTTP proxy $SQUID_PORT | Hysteria2 UDP $HY_PORT (hopping $HY_HOP) | WireGuard UDP $WG_PORT"
echo "WS test   : ${R:-fail}"
echo "Panel     : https://$PH:$PANEL_PORT/$WEB_PATH/"
if [ -n "$NEWPASS" ]; then echo "Login     : admin / $NEWPASS  (save this now)"; else echo "Login     : unchanged (change it with menu -> 4)"; fi
echo "Menu      : menu"
echo "Project   : https://github.com/chaliraza777/ReXUI"
echo "Allow these TCP ports in your provider firewall: $SSL_PORT $WS_PORT $WSTLS_PORT $OVPN1_PORT $OVPN2_PORT $SQUID_PORT $PANEL_PORT 80"
echo "Also allow UDP: $HY_PORT and $HY_HOP (Hysteria2), $WG_PORT (WireGuard), 53 (DNS tunnel)"
echo "If your provider has Anti-DDoS rules per port: do not set web ports (80, 8080, 8880) to SSH, use HTTP or no rule."
echo -e "\033[1;32m==============================\033[0m"
