#!/bin/bash
# ReXUI v1.0 installer
# Self-hosted SSH + Xray panel: SSH, SSL, SSH WebSocket (+TLS), UDPGW, Xray (VLESS XHTTP TLS / TCP TLS / Reality / XHTTP, Trojan),
# web panel with users, subscriptions, data and device limits, Telegram alerts, backups, 2FA, and a terminal menu.
# Run as root on Ubuntu or Debian:  bash install.sh   (running it again updates ReXUI and keeps users and settings)
# https://github.com/chaliraza777/ReXUI · License: GPL-3.0 · (c) 2026 Ali (chaliraza777)
set -e
trap 'echo -e "\n\033[1;31mERROR: failed at line $LINENO\033[0m"' ERR
[ "$EUID" -ne 0 ] && { echo "Please run as root"; exit 1; }
SSH_PORT_DEF=22
SSL_PORT=443; WS_PORT=8880; WSTLS_PORT=2083; UDPGW_PORT=7300; VWSTLS_PORT=8443; VTCP_PORT=2053; VWS_PORT=8080; REALITY_PORT=8444; TROJAN_PORT=2096
LIB=/usr/local/lib/tunnel
step(){ echo -e "\n\033[1;36m[$1/11]\033[0m $2"; }
busy(){ if ss -tlnp | grep ":$1 " | grep -qv -e stunnel -e python3 -e xray; then echo "Port $1 is already in use:"; ss -tlnp | grep ":$1 "; exit 1; fi; }
[ -f /etc/tunnel/config ] && . /etc/tunnel/config
if [ -z "$PANEL_PORT" ]; then
  PANEL_PORT=$(shuf -i 20000-59999 -n1)
  while ss -tln | grep -q ":$PANEL_PORT "; do PANEL_PORT=$(shuf -i 20000-59999 -n1); done
fi
[ -n "$WEB_PATH" ] || WEB_PATH=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
for p in $SSL_PORT $WS_PORT $WSTLS_PORT $PANEL_PORT $VWSTLS_PORT $VTCP_PORT $VWS_PORT $REALITY_PORT $TROJAN_PORT; do busy $p; done
export DEBIAN_FRONTEND=noninteractive
mkdir -p /etc/tunnel/cert $LIB

step 1 "Packages"
apt-get update -qq
apt-get install -y -qq openssh-server stunnel4 fail2ban cmake build-essential git openssl curl cron python3 socat unzip iptables >/dev/null

step 2 "SSH tuning"
mkdir -p /etc/ssh/sshd_config.d
grep -q '^Include' /etc/ssh/sshd_config || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
cat > /etc/ssh/sshd_config.d/00-tunnel.conf <<S
PasswordAuthentication yes
UseDNS no
TCPKeepAlive yes
ClientAliveInterval 30
ClientAliveCountMax 3
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
accept = $SSL_PORT
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
import asyncio,sys,socket,re,base64,hashlib
LP=int(sys.argv[1]); SSH=('127.0.0.1',int(sys.argv[2]))
G=b'258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
M=(b'GET ',b'POST ',b'HEAD ',b'PUT ',b'CONNECT ',b'OPTIONS ',b'PATCH ',b'DELETE ',b'HTTP/')
def log(*a): print(*a,flush=True)
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
    p=w.get_extra_info('peername')
    try:
        nd(w)
        d=await asyncio.wait_for(r.read(65536),20)
        if not d: return w.close()
        log(p,'payload',repr(d[:150]))
        if d.startswith(M):
            while b'\r\n\r\n' not in d:
                x=await asyncio.wait_for(r.read(65536),20)
                if not x: return w.close()
                d+=x
            b,d=d.split(b'\r\n\r\n',1); w.write(resp(b)); await w.drain()
        sr,sw=await asyncio.open_connection(*SSH); nd(sw)
        await asyncio.gather(up(r,w,sw,d),pipe(sr,w))
    except Exception as e: log(p,'error',repr(e)); w.close()
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
fs.file-max=1048576
S
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
  unzip -qo /tmp/xr/x.zip xray geoip.dat geosite.dat -d /tmp/xr && install -m 755 /tmp/xr/xray /usr/local/bin/xray
  install -m 644 /tmp/xr/geoip.dat /tmp/xr/geosite.dat /usr/local/bin/ && rm -rf /tmp/xr
fi
/usr/local/bin/xray version | head -1
mkdir -p /usr/local/etc/xray /var/log/xray
touch /var/log/xray/access.log
chown -R nobody:nogroup /var/log/xray; chmod 750 /var/log/xray; chmod 640 /var/log/xray/access.log
[ -f /etc/tunnel/xray-self.crt ] || openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=rexui" \
  -keyout /etc/tunnel/xray-self.key -out /etc/tunnel/xray-self.crt 2>/dev/null
chmod 600 /etc/tunnel/xray-self.key
cat > /etc/systemd/system/xray.service <<S
[Unit]
Description=Xray (ReXUI)
After=network.target
[Service]
User=nobody
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

step 9 "Web panel"
mkdir -p /opt/tunnel-panel
cat > /opt/tunnel-panel/panel.py <<'PANELPY'
#!/usr/bin/env python3
# ReXUI panel: one user = SSH + Xray (VLESS), subscription, GB limit, device limit, monthly reset, online/kick, backup/restore
import os,sys,re,json,time,hmac,hashlib,secrets,ssl,shutil,socket,subprocess as sp,threading,datetime,pwd,platform,uuid,base64,html,http.server
from urllib.parse import quote
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
    s={'addr':'','sni':'','host':'','path':'/vless','rsni':'www.microsoft.com','rpriv':'','rpub':'','rsid':'',
       'btorrent':True,'bads':False,'warp':'off','wsites':'geosite:google,geosite:openai,geosite:netflix',
       'b25':True,'autodel':0,'tgtoken':'','tgchat':'','brand':'','tagline':'','accent':'blue',
       'health':True,'report':False,'rhour':9,'tgbackup':False,'reboot':'off','rbday':0,'rbtime':'04:00','announce':'','cname':'{user}-{proto}','flag':'','autoclean':True,'rports':{},'fsite':'off','ftitle':'','xauto':False,'ddns_dom':'','ddns_tok':''}
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
        used={int(v) for k,v in E.items() if k.endswith('_PORT') and str(v).isdigit()}|{P('REALITY_PORT',8444),P('TROJAN_PORT',2096)}|set(m.values())
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
    s['rhour']=ival(d,'rhour',0,23,s['rhour']); wjson(SETF,s,0o600); return {'ok':1}
ACCENTS=('blue','teal','green','purple','pink','orange','indigo')
def textval(v,n,what):
    t=re.sub(r'[\x00-\x1f\x7f<>]','',str(v or '')).strip()
    if len(t)>n: raise Err('%s is too long (max %d characters)'%(what,n))
    return t
def appearance_save(d):
    s=sload(); s['brand']=textval(d.get('brand'),24,'Brand name'); s['tagline']=textval(d.get('tagline'),80,'Tagline')
    a=str(d.get('accent','blue'))
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
    a=str(d.get('action','')); sc=str(d.get('scope','active')); names=d.get('names')
    if a not in ('days','reset','disable','enable','delete') or sc not in ('active','all'): raise Err('bad request')
    if names is not None:
        if not isinstance(names,list) or not names or len(names)>5000: raise Err('Select at least one user')
        names={str(x) for x in names}
    elif a not in ('days','reset'): raise Err('bad request')
    days=ival(d,'days',1,3650,1) if a=='days' else 0; why=textval(d.get('reason'),200,'Reason') if a=='disable' else ''; n=0; gone=[]
    with UL:
        us=uload()
        for u in us:
            if names is not None:
                if u['name'] not in names: continue
            elif sc=='active' and ustate(u)!='active': continue
            if a=='days':
                if u['exp']=='never' and not u.get('fdays'): continue
                add_days(u,days)
            elif a=='reset': u['up']=u['down']=0
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
def usave(us): wjson(UDB,us)
def newu(n,pw,e,lim=0.0,sni='',host='',dev=1,rday=0):
    return {'name':n,'pw':pw,'uuid':str(uuid.uuid4()),'exp':e,'lim':lim,'up':0,'down':0,'sni':sni,'host':host,
            'en':True,'lk':False,'sub':secrets.token_hex(16),'created':today(),'dev':dev,'rday':rday,'lreset':today()[:7],'note':'','hist':{},'trial':False,'expts':0,'fdays':0,'reason':'','rtarget':'','rsni':''}
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
def add_days(u,days):
    if u.get('fdays'): u['fdays']=min(3650,u['fdays']+days); return
    if u['exp']=='never': raise Err('This user has no expiry, days cannot be added')
    if u.get('expts'):
        u['expts']=max(time.time(),u['expts'])+days*86400; u['exp']=datetime.date.fromtimestamp(u['expts']).isoformat()
    else:
        b=max(today(),u['exp']); u['exp']=(datetime.date.fromisoformat(b)+datetime.timedelta(days=days)).isoformat()
    setexp(u['name'],u['exp'])
def mkuser(us,n,p,e,lim=0.0,sni='',host='',dev=1,rday=0,note='',**kw):
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
    run('chpasswd',inp='%s:%s\n'%(n,p))
    b=newu(n,p,e,lim,sni,host,dev,rday); b['note']=note; b.update(kw); us.append(b); setexp(n,e); return b
def rmuser(n):
    run('pkill','-KILL','-u',n); time.sleep(.3); run('userdel','-r',n); IPSEEN.pop(n,None)
def trial_new():
    with UL:
        us=uload(); names={x['name'] for x in us}
        for _ in range(50):
            n='trial%04d'%secrets.randbelow(10000)
            if n in names: continue
            try: pwd.getpwnam(n); continue
            except KeyError: break
        ts=time.time()+86400
        b=mkuser(us,n,secrets.token_urlsafe(6),datetime.date.fromtimestamp(ts).isoformat(),2.0,dev=1,note='Trial account',trial=True,expts=ts)
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
CSVF=['name','password','expiry','data_limit_gb','used_gb','devices','reset_day','sni','host','note','created','status','reality_target','reality_sni']
def csv_export():
    import csv,io
    o=io.StringIO(); w=csv.writer(o); w.writerow(CSVF)
    for u in uload():
        w.writerow([u['name'],u['pw'],('first-use+%d'%u['fdays']) if u.get('fdays') else u['exp'],u['lim'] or 0,round((u['up']+u['down'])/GB,3),u.get('dev',0),u.get('rday',0),
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
                b=mkuser(us,n,r.get('password') or secrets.token_urlsafe(8),e,lim,hostok(r.get('sni'),'SNI'),hostok(r.get('host'),'Host'),dev,rday,noteval(r),fdays=fd,rtarget=rtc(r.get('reality_target','')),rsni=rsni_val(r.get('reality_sni')))
                b['down']=int(used*GB); ok.append(n)
            except Err as x: bad.append('Row %d (%s): %s'%(i,n or 'no name',x))
        usave(us)
    enforce(); xray_apply(); ssh_rules(True); return {'ok':1,'added':len(ok),'errors':bad[:50]}
def uapi(a,d):
    n=str(d.get('name','')).strip()
    with UL:
        us=uload(); u=next((x for x in us if x['name']==n),None)
        if a=='add':
            p=str(d.get('pw','')); pwok(p); days=ival(d,'days',0,3650); lim=fval(d,'lim',0,100000)
            dev=ival(d,'dev',0,100,1); rday=ival(d,'rday',0,28,0); first=bool(d.get('first')) and days>0
            sni=hostok(d.get('sni'),'SNI'); host=hostok(d.get('host'),'Host'); note=noteval(d); rt=rtarget_val(d.get('rtarget')); rs=rsni_val(d.get('rsni'))
            e='never' if days==0 or first else (datetime.date.today()+datetime.timedelta(days=days)).isoformat()
            mkuser(us,n,p,e,lim,sni,host,dev,rday,note,fdays=days if first else 0,rtarget=rt,rsni=rs); usave(us)
        elif not u: raise Err('User not found')
        elif a=='edit':
            p=str(d.get('pw','')); days=ival(d,'days',0,3650,0); lim=fval(d,'lim',0,100000)
            dev=ival(d,'dev',0,100,u.get('dev',0)); rday=ival(d,'rday',0,28,u.get('rday',0))
            if p: pwok(p)
            sni=hostok(d.get('sni'),'SNI'); host=hostok(d.get('host'),'Host')
            if 'rtarget' in d: u['rtarget']=rtarget_val(d.get('rtarget'),u.get('rtarget',''))
            if 'rsni' in d: u['rsni']=rsni_val(d.get('rsni'))
            if days: add_days(u,days)
            if p: run('chpasswd',inp='%s:%s\n'%(n,p)); u['pw']=p
            if rday!=u.get('rday',0): u['lreset']=today()[:7]
            u['lim'],u['sni'],u['host'],u['dev'],u['rday']=lim,sni,host,dev,rday
            if 'note' in d: u['note']=noteval(d)
            usave(us)
        elif a=='newsub': u['sub']=secrets.token_hex(16); usave(us)
        elif a=='newuuid': u['uuid']=str(uuid.uuid4()); usave(us)
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
    s=sload(); ci=certinfo(); a=pub_addr(s); cn=ci['name'] if ci['src']!='self-signed' else ''
    sni=u.get('sni') or s['sni'] or ci['domain']; host=u.get('host') or s['host'] or ci['domain'] or a
    ok=bool(cn) and bool(sni) and (sni==cn or (cn.startswith('*.') and sni.endswith(cn[1:])))
    A='['+a+']' if ':' in a else a; pth=quote(s['path'],safe='')
    fp=cert_fp(); tls='security=tls'+('&sni='+quote(sni) if sni else '')+('' if ok else '&allowInsecure=1'+('&pcs='+fp if fp else ''))
    base='vless://%s@%s:%%d?encryption=none&'%(u['uuid'],A)
    xh='&type=xhttp&host=%s&path=%s&mode=auto'%(quote(host),pth)
    pa=s['addr'] if s['addr'] and re.search('[a-z]',s['addr']) else ci['domain'] or a; PA='['+pa+']' if ':' in pa else pa
    N=lambda c,t:cfgname(u,c,t,s)
    out=[('VLESS XHTTP TLS',(base%P('VWSTLS_PORT',8443))+tls+'&alpn=h2%2Chttp%2F1.1'+xh+'#'+N('xhttp-tls','VLESS XHTTP TLS')),
         ('VLESS TCP TLS',(base%P('VTCP_PORT',2053))+tls+'&type=tcp#'+N('tcp-tls','VLESS TCP TLS')),
         ('Trojan TLS','trojan://%s@%s:%d?'%(u['uuid'],A,P('TROJAN_PORT',2096))+tls+'&type=tcp#'+N('trojan','Trojan TLS'))]
    if s['rpub']:
        rt,rs=ureal(u,s)
        out.append(('VLESS Reality','vless://%s@%s:%d?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s'%(
            u['uuid'],A,rport(rt,s),quote(rs),s['rpub'],s['rsid'],N('reality','VLESS Reality'))))
    out.append(('VLESS XHTTP (no TLS)','vless://%s@%s:%d?encryption=none&security=none'%(u['uuid'],PA,P('VWS_PORT',8080))+xh+'#'+N('xhttp','VLESS XHTTP')))
    return out
def sub_url(u): return 'https://%s:%s/sub/%s'%(certinfo()['domain'] or pub_addr(),E.get('PANEL_PORT',''),u['sub'])
def detail(n):
    u=next((x for x in uload() if x['name']==n),None)
    if not u: raise Err('User not found')
    s=sload(); ci=certinfo(); a=pub_addr(s)
    return {'name':u['name'],'pw':u['pw'],'uuid':u['uuid'],'exp':u['exp'],'lim':u['lim'],'used':u['up']+u['down'],'up':u['up'],'down':u['down'],
            'sni':u['sni'],'host':u['host'],'rtarget':u.get('rtarget',''),'rsni_u':u.get('rsni',''),'rt':ureal(u,s)[0],'rport':rport(ureal(u,s)[0],s),'st':ustate(u),'created':u.get('created',''),'dev':u.get('dev',0),'rday':u.get('rday',0),
            'note':u.get('note',''),'hist':hist30(u),'fdays':u.get('fdays',0),'trial':u.get('trial',False),'expts':u.get('expts',0),'reason':u.get('reason',''),
            'ssh':sessions().get(u['name'],0),'ips':xips(u['name']),'sub':sub_url(u),'links':[{'name':k,'url':v} for k,v in links(u)],
            'addr':a,'whost':u['host'] or s['host'] or ci['domain'] or a,'path':s['path'],'rsni':s['rsni'],
            'plaindomain':bool((s['addr'] and re.search('[a-z]',s['addr'])) or ci['domain']),
            'ports':{k:str(P(k,d)) for k,d in (('SSH_PORT',22),('SSL_PORT',443),('WS_PORT',8880),('WSTLS_PORT',2083),('UDPGW_PORT',7300),
                     ('VWSTLS_PORT',8443),('VTCP_PORT',2053),('VWS_PORT',8080),('REALITY_PORT',8444),('TROJAN_PORT',2096))}}

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
XLOCK=threading.Lock(); XHASH=['']; XBAD=['','']; XACT={}
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
        s=reality_keys(); act=[u for u in uload() if ustate(u)=='active']; cl=[{'id':u['uuid'],'email':u['name'],'level':0} for u in act]
        c,k=CD+'/xray.crt',CD+'/xray.key'
        if not (os.path.exists(c) and os.path.exists(k)): c,k=XSC,XSK
        cert={'certificates':[{'certificateFile':XD+'/cert.crt','keyFile':XD+'/key.key'}]}
        def ib(tag,port,net,tls,alpn=None):
            st={'network':net,'security':'tls' if tls else 'none'}
            if tls: st['tlsSettings']=dict(cert,**({'alpn':alpn} if alpn else {}))
            if net=='xhttp': st['xhttpSettings']={'path':s['path'],'mode':'auto'}
            vs={'clients':cl,'decryption':'none'}
            if net=='tcp' and tls and s['fsite']!='off': vs['fallbacks']=[{'dest':FBP}]
            return {'tag':tag,'listen':'0.0.0.0','port':port,'protocol':'vless','settings':vs,
                    'streamSettings':st,'sniffing':{'enabled':True,'destOverride':['http','tls']}}
        sn={'enabled':True,'destOverride':['http','tls']}
        ibs=[ib('vless-xhttp-tls',P('VWSTLS_PORT',8443),'xhttp',True,['h2','http/1.1']),ib('vless-tcp-tls',P('VTCP_PORT',2053),'tcp',True,['http/1.1'] if s['fsite']!='off' else None),
             ib('vless-xhttp',P('VWS_PORT',8080),'xhttp',False),
             {'tag':'trojan-tls','listen':'0.0.0.0','port':P('TROJAN_PORT',2096),'protocol':'trojan','settings':dict({'clients':[{'password':u['uuid'],'email':u['name'],'level':0} for u in act]},**({'fallbacks':[{'dest':FBP}]} if s['fsite']!='off' else {})),
              'streamSettings':{'network':'tcp','security':'tls','tlsSettings':dict(cert,**({'alpn':['http/1.1']} if s['fsite']!='off' else {}))},'sniffing':sn}]
        if s['rpriv']:
            dt=s['rsni']+':443'; grp={dt:[]}
            for u in act:
                t,sn_=ureal(u,s); grp.setdefault(t,[]).append((u,sn_))
            for t,L in grp.items():
                pt=rport(t,s); names=sorted({x[1] for x in L}|{t.rsplit(':',1)[0]})
                ibs.append({'tag':'vless-reality' if t==dt else 'vless-reality-%d'%pt,'listen':'0.0.0.0','port':pt,'protocol':'vless',
                            'settings':{'clients':[{'id':u['uuid'],'email':u['name'],'level':0,'flow':'xtls-rprx-vision'} for u,_ in L],'decryption':'none'},
                            'streamSettings':{'network':'tcp','security':'reality','realitySettings':{'target':t,'serverNames':names,'privateKey':s['rpriv'],'shortIds':[s['rsid']]}},
                            'sniffing':sn})
        obs=[{'protocol':'freedom','tag':'direct'},{'protocol':'blackhole','tag':'block'}]; rules=[]
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
        cfg={'log':{'loglevel':'warning','access':XLOG},'api':{'tag':'api','listen':XAPI,'services':['StatsService']},'stats':{},
             'policy':{'levels':{'0':{'statsUserUplink':True,'statsUserDownlink':True}},'system':{'statsInboundUplink':True,'statsInboundDownlink':True}},
             'inbounds':ibs,'outbounds':obs,'routing':{'domainStrategy':'AsIs','rules':rules}}
        txt=json.dumps(cfg,indent=1); h=hashlib.sha256((txt+rd(c)+rd(k)).encode()).hexdigest()
        if h==XHASH[0] and not force: return
        if h==XBAD[0] and not force: return XBAD[1]
        os.makedirs(XD,exist_ok=True)
        try: g=pwd.getpwnam('nobody').pw_gid; nu=pwd.getpwnam('nobody').pw_uid
        except KeyError: g=nu=0
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
        collect(); os.replace(tmp,XD+'/config.json'); run('systemctl','restart','xray'); XHASH[0]=h
        log('xray config updated, active users:',len(cl))

# ---------- collect + enforce ----------
def hist30(u):
    h=u.get('hist') or {}; t=datetime.date.today()
    return [[d,h.get(d,[0,0])[0],h.get(d,[0,0])[1]] for d in ((t-datetime.timedelta(days=i)).isoformat() for i in range(29,-1,-1))]
def collect():
    ssh_collect(); xs=xstats(); xstats_in(); now=time.time()
    tr_proto('SSH',sum(v['up'] for v in PEND.values()),sum(v['down'] for v in PEND.values()))
    for n,v in xs.items():
        if v['up'] or v['down']: XACT[n]=now
    if not (xs or PEND): return
    with UL:
        us=uload(); ch=False
        for u in us:
            x=xs.get(u['name']); uid=uidof(u['name']); y=PEND.pop(uid,None) if uid else None
            for z in (x,y):
                if z and (z['up'] or z['down']):
                    u['up']+=z['up']; u['down']+=z['down']; ch=True
                    if u.get('fdays'):
                        u['exp']=(datetime.date.today()+datetime.timedelta(days=u['fdays'])).isoformat(); u['fdays']=0; setexp(u['name'],u['exp']); log('first use, expiry starts:',u['name'],u['exp'])
                    h=u.setdefault('hist',{}); e=h.setdefault(today(),[0,0]); e[0]+=z['up']; e[1]+=z['down']
                    if len(h)>31:
                        for k in sorted(h)[:-31]: h.pop(k)
        PEND.clear()
        if ch: usave(us)
def enforce():
    with UL:
        us=uload(); t=today(); ss=None; ch=False; ym=t[:7]
        for u in us:
            rd_=int(u.get('rday',0) or 0)
            if rd_ and int(t[8:10])>=rd_ and u.get('lreset')!=ym:
                u['up']=u['down']=0; u['lreset']=ym; ch=True; log('monthly reset:',u['name'])
            act=ustate(u,t)=='active'
            if not act and not u.get('lk'):
                run('usermod','-L',u['name']); run('pkill','-KILL','-u',u['name']); u['lk']=True; ch=True
            elif act and u.get('lk'):
                run('usermod','-U',u['name']); u['lk']=False; ch=True
            elif not act:
                ss=ss if ss is not None else sessions()
                if ss.get(u['name']): run('pkill','-KILL','-u',u['name'])
        if ch: usave(us)
# ---------- Xray access log: online IPs, device limit ----------
IPSEEN={}; XOFF=[None]; WIN=120; BANS={}; BANSET=[None]; BANT=120
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
def xips(n):
    now=time.time(); return [{'ip':ip,'ago':int(now-v[1]),'ban':int(max(0,BANS.get(ip,0)-now)),'shared':shared(ip,n)} for ip,v in sorted(IPSEEN.get(n,{}).items(),key=lambda x:x[1][0])]
def bans_apply():
    now=time.time()
    for ip in [ip for ip,t in BANS.items() if t<=now]: BANS.pop(ip)
    cur=tuple(sorted(BANS))
    if cur==BANSET[0] or not shutil.which('iptables'): return
    ports=','.join(str(P(k,d)) for k,d in (('VWSTLS_PORT',8443),('VTCP_PORT',2053),('VWS_PORT',8080),('REALITY_PORT',8444),('TROJAN_PORT',2096)))
    for f in FAM:
        run(f,'-w','-N','REXUI_BAN'); run(f,'-w','-F','REXUI_BAN')
        if run(f,'-w','-C','INPUT','-j','REXUI_BAN').returncode: run(f,'-w','-I','INPUT','1','-j','REXUI_BAN')
        for ip in cur:
            if (':' in ip)==(f=='ip6tables'):
                run(f,'-w','-A','REXUI_BAN','-s',ip,'-p','tcp','-m','multiport','--dports',ports,'-j','REJECT','--reject-with','tcp-reset')
    BANSET[0]=cur
def shared(ip,n): return any(ip in v for m,v in IPSEEN.items() if m!=n)
def kick(n):
    run('pkill','-KILL','-u',n); now=time.time()
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
def online():
    ss=sessions(); out=[]
    for u in uload():
        n=u['name']; ips=xips(n); s=ss.get(n,0)
        if s or ips: out.append({'name':n,'ssh':s,'ips':ips,'dev':u.get('dev',0)})
    return out

# ---------- backup / restore ----------
def backup_obj():
    return {'app':'rexui','ver':2,'date':datetime.datetime.now().isoformat(timespec='seconds'),'users':uload(),'settings':sload()}
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
    good=[]
    for x in o['users']:
        if not isinstance(x,dict): continue
        n=str(x.get('name',''))
        if not NAME.fullmatch(n) or n.isdigit() or not re.fullmatch(r'[0-9a-f-]{36}',str(x.get('uuid',''))): continue
        b=newu(n,'','never'); b.update({k:x[k] for k in b if k in x}); b['lk']=False; b['dev']=x.get('dev',0); good.append(b)
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
            run('chpasswd',inp='%s:%s\n'%(n,b['pw'] or secrets.token_urlsafe(12))); run('usermod','-U',n); setexp(n,b['exp'])
            us[n]=b
        usave(list(us.values()))
    enforce(); ssh_rules(True); xray_apply(True)
    return {'ok':1,'users':len(good)}
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

def users_list():
    on=sessions(); now=time.time(); out=[]
    for u in uload():
        st=ustate(u); nip=len(IPSEEN.get(u['name'],{})); o=on.get(u['name'],0)+(nip or (1 if now-XACT.get(u['name'],0)<30 else 0))
        out.append({'name':u['name'],'exp':u['exp'],'lim':u['lim'],'used':u['up']+u['down'],'on':o,'dev':u.get('dev',0),'rday':u.get('rday',0),'note':u.get('note','')[:80],'created':u.get('created',''),'fdays':u.get('fdays',0),'trial':u.get('trial',False),'expts':u.get('expts',0),
                    'st':'online' if st=='active' and o else st})
    return out

# ---------- services ----------
def listening():
    s=set()
    for f in ('/proc/net/tcp','/proc/net/tcp6'):
        for l in rd(f).splitlines()[1:]:
            p=l.split()
            if len(p)>3 and p[3]=='0A': s.add(int(p[1].rsplit(':',1)[1],16))
    return s
UNITS=['ssh','sshd','stunnel4','ws-ssh','badudp','fail2ban','xray']
RESTART={'ssh','stunnel4','ws-ssh','badudp','fail2ban','xray'}
def units():
    st={}
    for blk in run('systemctl','show','-p','Id,LoadState,ActiveState',*[u+'.service' for u in UNITS]).stdout.strip().split('\n\n'):
        kv=dict(x.split('=',1) for x in blk.splitlines() if '=' in x)
        i=kv.get('Id','').replace('.service','')
        if i: st[i]=(kv.get('LoadState',''),kv.get('ActiveState',''))
    return st
def services():
    st=units(); ls=listening()
    def s(u):
        for x in (['ssh','sshd'] if u=='ssh' else [u]):
            if x in st and st[x][0] not in ('not-found',''): return st[x]
        return ('not-found','inactive')
    out=[]
    for name,u,port in [('SSH','ssh',P('SSH_PORT',22)),('SSL','stunnel4',P('SSL_PORT',443)),('SSH WS','ws-ssh',P('WS_PORT',8880)),
                        ('SSH WS TLS','stunnel4',P('WSTLS_PORT',2083)),('UDPGW','badudp',P('UDPGW_PORT',7300)),('Fail2ban','fail2ban',0),
                        ('VLESS XHTTP TLS','xray',P('VWSTLS_PORT',8443)),('VLESS TCP TLS','xray',P('VTCP_PORT',2053)),('VLESS XHTTP','xray',P('VWS_PORT',8080)),
                        ('VLESS Reality','xray',P('REALITY_PORT',8444)),('Trojan TLS','xray',P('TROJAN_PORT',2096))]:
        l,a=s(u)
        v='NOT INSTALLED' if l=='not-found' else 'RUNNING' if a=='active' and (not port or port in ls) else 'FAILED' if a=='failed' else 'IDLE'
        out.append({'name':name,'unit':u,'port':port,'st':v})
    return out
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
            if i%12==0: hm_tick(); health_check(); daily_jobs()
            if i%120==0: hm_save(); tr_save()
            if i%360==1: threading.Thread(target=ddns_update,daemon=True).start()
            if i%2==0: collect(); enforce(); trial_cleanup(); xray_apply(); ssh_rules(); devices(); auto_backup()
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
def state():
    m=mem(); du=shutil.disk_usage('/'); tc,uc=conn()
    return {'info':dict(INFO,uptime=float(rd('/proc/uptime','0').split()[0]),puptime=time.time()-START),
            'cpu':S['cpu'],'ram':[m['MemTotal']-m['MemAvailable'],m['MemTotal']],'swap':[m.get('SwapTotal',0)-m.get('SwapFree',0),m.get('SwapTotal',0)],
            'disk':[du.used,du.total],'rx':S['rx'],'tx':S['tx'],'rxt':S['rxt'],'txt':S['txt'],'hist':H,'tcp':tc,'udp':uc,
            'ip':IPS,'stats':stats(),'tools':TOOLS,'fs':FS['err'],'xup':XUP,'ddns':dict(DDNS,dom=sload()['ddns_dom']),'stime':time.strftime('%H:%M %Z'),'svc':services(),'xray':xinfo(),'proc':procinfo(),'online':online(),'backups':sorted(os.listdir(BKD))[::-1] if os.path.isdir(BKD) else [],'users':users_list(),'cert':certinfo(),'set':dict({k:v for k,v in sload().items() if k not in ('rpriv','tgtoken','ddns_tok')},tgmask=mask(sload()['tgtoken']),ddmask=mask(sload()['ddns_tok'])),'tfa':bool(lread().get('totp')),'warp':warp_info(),'geo':geo_ok(),'addr':pub_addr(),'me':curuser(),
            'port':E.get('PANEL_PORT',''),'path':E.get('WEB_PATH',''),'ports':dict({k:v for k,v in E.items() if k.endswith('_PORT')},REALITY_PORT=str(P('REALITY_PORT',8444)),TROJAN_PORT=str(P('TROJAN_PORT',2096)))}

# ---------- stats: server traffic, protocols, top users ----------
TRF=T+'/traffic.json'; TR={'days':{},'proto':{}}; TRL=threading.Lock()
PNAME={'vless-xhttp-tls':'XHTTP TLS','vless-tcp-tls':'TCP TLS','vless-xhttp':'XHTTP','trojan-tls':'Trojan','vless-reality':'Reality'}
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
        return {'newsub':'Made a new subscription link for %s','newuuid':'Made a new UUID for %s','add':'Added user %s','edit':'Edited user %s','reset':'Reset data usage of %s','kick':'Disconnected %s','del':'Deleted user %s'}.get(a,'')%n if a!='detail' else None
    if r=='/api/bulk':
        a=d.get('action'); w={'days':'added %s days'%d.get('days'),'reset':'reset data usage','disable':'disabled','enable':'enabled','delete':'deleted'}.get(a,a)
        nm=d.get('names') if isinstance(d.get('names'),list) else None
        return 'Bulk: %s %s'%(w,', '.join(map(str,nm)) if nm and len(nm)<=5 else '%d user(s)'%res.get('count',0))
    if r=='/api/trial': return 'Created trial user %s'%res.get('name','')
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
TOOLS={'speed':{},'ports':{}}
SPEEDURL=os.environ.get('REXUI_SPEEDURL','https://speed.cloudflare.com')
CHAPI=os.environ.get('REXUI_CHAPI','https://check-host.net')
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
            def phase(kind,secs=7,n=4):
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
def portcheck():
    import urllib.request
    if TOOLS['ports'].get('run'): raise Err('A port check is already running')
    ip=IPS['v4'] or pub_addr()
    if not ip: raise Err('The server IP is not known yet')
    pl=[('Panel','PANEL_PORT',0),('SSH','SSH_PORT',22),('SSH SSL','SSL_PORT',443),('SSH WS','WS_PORT',8880),('SSH WS TLS','WSTLS_PORT',2083),
        ('VLESS XHTTP TLS','VWSTLS_PORT',8443),('VLESS TCP TLS','VTCP_PORT',2053),('Trojan TLS','TROJAN_PORT',2096),('VLESS XHTTP','VWS_PORT',8080)]
    s_=sload()
    if s_['rpriv']: pl.append(('VLESS Reality','REALITY_PORT',8444))
    xp=[('Reality '+t,p) for t,p in (s_.get('rports') or {}).items() if any(ureal(u,s_)[0]==t for u in uload())]
    TOOLS['ports']={'run':1,'t':int(time.time()),'res':[]}
    def get(url):
        rq=urllib.request.Request(url,headers={'Accept':'application/json','User-Agent':'ReXUI'})
        with urllib.request.urlopen(rq,timeout=15) as r: return json.loads(r.read().decode())
    def go():
        res=[]; err=''
        try:
            jobs=[]
            for name,k,dft in pl+[(n_,None,p_) for n_,p_ in xp]:
                p=P(k,dft) if k else dft; o=get('%s/check-tcp?host=%s:%d&max_nodes=3'%(CHAPI,ip,p)); jobs.append((name,p,o['request_id']))
            time.sleep(6)
            for name,p,rid in jobs:
                r={}
                for _ in range(5):
                    r=get('%s/check-result/%s'%(CHAPI,rid))
                    if all(v is not None for v in r.values()): break
                    time.sleep(2)
                ok=sum(1 for v in r.values() if v and isinstance(v,list) and v[0] and 'error' not in v[0] and v[0].get('time') is not None)
                res.append({'name':name,'port':p,'ok':ok,'n':len(r)})
        except Exception as e: err='The online port checker could not be reached: '+str(e)[:80]
        TOOLS['ports']={'t':int(time.time()),'res':res,'err':err,'ip':ip}
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
ICON={'192':base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAMAAAADACAMAAABlApw1AAAAwFBMVEX////+///l8vQhkZcUj48aiZgYipUXi5UWhqkTiKkTiKgTiKcThqsQkowPkJIRkIwQjpgPj5YPj5UOk4sOkY8OkJENlIkNk4kHj4gRjZwRjJ4Ri6ASiqMSiaUSiKYOjJgkgZ0hhJoteqUofqEZe8oaes8ZfsAWgrgWgboXgL0Xf8AUha8VhLIFhZcUg7RAa7ZEaLpIZL5MYcJRXcZWWcpcVNBjTtZuReE1dKwxd6k5cLA8brMcdtkgeMkec94aecvuuHB/AAAJ/ElEQVR42tWda3ebOBBA5Xe6DQkuScBtN351m90m2MRtUxzv2f7/f7VIAvwADcxIPu3oQ0/PScBzxdVYLxTxH1j+PSl/Vcunavn8pSj/6PK3LA+yrFR50uVRlUtd3vyhy/2fsnyU5YMq77MyUcVXZazKuytdhGX8P+vi/2yM/6Ex/rcn8b8vAfy6+G/FGerfZfwq/PeTU4Ai/psbwdqfGxCA6M8Xi/q/R/oDAvz+/sj4zQAs/AEAePhjBmDiz82NJ1j7c+PVA7Dxx6sH4OOPFwTirP48nNmfWgA2/gRZ+DUArPypAeDlTxCEgrU/QXgnWPsT3h0DMPMnDO+OnwA/f46fADt/svAPAdj5IwHCfRZi6U8Ylt8DPP3ZAzD1Jyh6o1z9Cbxrwdof71oBcPVHxi8BuPrjyfj7grU/1/2+YO1PvwrAy58qADN/KgDc/DkFOIM/l2f15wSAnz/HAAz9OQLg6E+/PxSs/emPSgCe/oyGBQBPf7L4cwCu/gyHA8Han+FAAfxSfyY2/gwUwC/3Z0L2RwHQ/Vmt8uAfqP7E8TQrcTz2af5IALI/q4ddV5VEElD8iaepvkPvXUzzZzCYC7I/SVfkpbsuHgDGn2kWfnmHNH43JvgzmNcAtKv/h+zDO3nJAnhaYf2ZTo7vMLol+DOvAvxsHb/8WF2y/ykCjD8y/uM7aAKcPzUA7fxZZZ8uDkr2+Stc/omrd4jw/lQBWrbf5PjT1edfPrWNf1KNX94hjdD+nAK0/f566HZOPj77/CQjuGy5fyyu1EBmUTevfoQ/pwAt80/1ASiL15et/UlFp3oH0Yuw/sznM0Ho/6yqD0DV4DYnaPSnZ7iBcgjjz3x2ANC+/7PqVp+AagZPiqDJn2nPdH2E9Wd2CIDo/9QGoBpym/7P1Hg52p9DAEz/uT4CTdDkT00COgBA+rMHQPWfV4YQZAzxRcP+1Ri4OPKQ/uwBUP3n2kZcJFNNYPQn3gnDxbIRY/2ZzZaCMv7aCRNAp5NKArM/244Zvhdh/ZktFQB+/AU8gk7v/sI4/op7HSO76OL9WWoA7PjrYbU2hSHjuLh/a8o/vS5wYfEAEP5oAPz43dyMFcG9afweg5fJ+JH+SIBPlPH76gkMJdbhn47f4fj7Id4fA0CL8ftqCwWTxHXj95oe3EH8mUAh2p96gFbzP4+pMZ3InnFc1v/en9Qcf6cjGwDen+VyIajzP5cJFM82rtR/DyLeqQaA9me5qAK0nf95ugSN7mmCMn44AeUNGO3PogqAmD+ECUqDlD/TaVP8JH+qALj1UzgVHTUA8Fe90AtJ/lQAkPOHFw0ELeOXCYjmzykAcv758dKcijoymZbxr4X59zo6fpI/JwDo+efHeAcRpHEef68xfqI/i8VWWM0/P0JfTp0sFU2MQ+BCoLWNP4vtAQBp/eKiwe5pmwRK92d7AEBdv7gHw5tO/IYEGgYW/hwAUNcv3tw3pKIWCYjuzx6Avv51cb+AFE92YCPJGwDVn+02FdbrXxfxVnSAbpH5R3IIY+fPNtUAdutfb2UqMoVpLB3Vg7P0J9UAVuuncvgIeQ4mIFt/NIDV+qmef/hgJoASkLU/CsDF+umHj0gCOQ0nE6ilPxKgNn6MP2r8/uECRaASaGDvjwSw90eNf4EZK1MPyIE/afoqHK2/fwSGvPVzQC78SV9LABt/9Pgd6NdVv950ArX257UEsPNHj9/jls1AJqDAjT8lgJv9G+0IZPx3gRt/CgB7fxTAdNCCQM7BRYEjf15fd8KRP2r8Dkw+H05fF/F7DuKXAA73/zQm03wI6cqfnQRw5E8+/7YD+3VyoJx9AbjyRwG48kdvv5rADVn14JzGXwBY+1Nuf4MIdAJ16E8JYH1+wn7/ZxsAR+1XlrWwff/ieP9kK4Xc+bNbKwArf04ESls0Ynf+rBWAO3/aplGH8WcAbvzR/rf8Iuu78kcCOPQHmoM7GsuEzuo/B3CTf/z2nTl38SfCmT8+pjvtyJ91IgHc+OPjBjQjN/UvAdz4M8ENKVNJ4CL+RLjxB1xFrU+mIwf+lADW/rRKQMepqD9wUP8awD7/QKuoJoLByEX8ewCb/ONPKVOLU3t/kuRZOPDHJ07uxvb1//ws7P2BVlHBfl0S28efA9j4A62iNixwbIczO38KADt/wFXUBNpk010MLOtfA9j44zetokbgj5e28UsAq/wzblhFvbuDCQZW/jw/b4SdP37TKmoQRPAjmlvV/2YjrPzx4zW8ipotYngR2Ei68dIm/gKA5k82BIY2e6h9fIHXj8DNHuv5kuxPCUD1pwfFr1ZR5fi9H+0ggnROr/8cgOpPQwIKyvkTuCEvZvT4FQDRn3d+QwI6mP+5hpMp1R8NQPRn3LAPTj6AIv5RfwT+8mxBrP/NV0H0Z+w3b0M5mL8aXcO6LanxfxXE7y84gapFgKP5q2G8gDa+bmYkf74WAFh/xj68EbdXnT8cwFuPd0tS/ecABH9AIxK5Efd0/nAAO7ejxa8A8P5MGxJQUDv/DHebKP5oAHz+aUhAkWn+fAh/HRDqXwKg/Rn7kM5yFdUzzZ/PQPEWhPi/CbQ/8u33LryR1Tj/P1iaXwLK3sVE+/P1WwGA8ceXY0hS/PP5ENjqK5Ituv4LAIQ/EqBrfJdNLsCA6y/DBHgEC3z8GgDlz9i/hd8mhNdf5sDFW6w/OQDGH3X+g/l1zqh5/XFuvhpf/woA5U9Wrq6M79OGYZv1L+PlhPgzAJw/8vyNW9MLze3W72bb2jZ0DNA2/m8C7c/VVWR4o7zt+uOsdiCa3SBF138GgPNHnX8SpbWHArRfP50ltYcCbAjxfxdYf9TxG7XHMiDWf2ebumMZ8P58+54DIPypfwQ6gbaNf7FY1hyMsUnx9Z8DYPxR57dENQeLIPcPVO/wSolfAeD8Ueef9E+PdumH2P0Dp3cg1b8CQPqjDhCJ+seH62Q9UPT+h+M70OpfArzF+qNKKKc8i+ONelFI2b9xcMTShhr/d0HwR58fEgW9/ICpkLj/ZJEh6EOuXlNC/skBCP7o80O8IIqyVwDkP+T9M/kg8pVc/zkA1p/8/IqMIds/5nlO9/8g41cAaH/0AS7q/Qu3+8fw8b8Iij9eEFDfX3Zc/y8ZAM2fMAzd7X+2iP9F2PgT/mp/CgC2/uQAfP3RAIz9UQCc/ZEArP0pAbj6AwPY+zM7e/1rAL7+aADG/gAAPPxRAJz9eXn5IVj78/KjHoCNPz8UAGN/FABnfyQAa39yAL7+aADG/lQBmPkjAVj7swdg6s8JAD9/CgC2/uQAfP05BGDpjwLg7I8EYO1PCcDVnwKArT85AF9/NABjfxQAZ38kAGt/JABrf/YAZ/PnzPVfAHD1pwA4mz/nj18BEP7+zu9S/wqg9Ify9wt+dfwZwO1h/f9e618t4v/xPxtWPzGLuf1uAAAAAElFTkSuQmCC'),'512':base64.b64decode('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')}
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
        if p in ('/','/index.html'): return self._send(200,_fpage(s['fsite'],s['ftitle']),head=head)
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
    s=sload(); on=s['fsite']!='off'
    for x in FS['srv']:
        try: x.shutdown(); x.server_close()
        except Exception: pass
    FS['srv']=[]; FS['err']=''
    if not on:
        try: os.remove(FSON)
        except OSError: pass
        _acme_webroot(False); return
    os.makedirs(os.path.join(FSD,'.well-known','acme-challenge'),exist_ok=True)
    for cls,addr in ((FakeS,('127.0.0.1',FBP)),(FakeS6,('::',80))):
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
def rdefault(d):
    h=hostok(d.get('domain'),'Domain')
    if not h or not tls13(h): raise Err('%s did not answer with TLS 1.3'%h)
    s=sload(); s['rsni']=h; wjson(SETF,s,0o600); xray_apply(); return {'ok':1}

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
        with urllib.request.urlopen(rq,timeout=180) as r: z=zipfile.ZipFile(io.BytesIO(r.read()))
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
        b=body if body is not None else json.dumps(obj).encode()
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
        m=re.fullmatch(r'/sub/([0-9a-f]{32})',p)
        if m:
            u=next((x for x in uload() if hmac.compare_digest(x['sub'],m[1])),None)
            if not u: return self.nf()
            if 'text/html' in self.headers.get('Accept','') and 'raw' not in self.path.split('?',1)[-1]:
                d=detail(u['name']); keep=('name','pw','exp','lim','used','up','down','st','sub','links','addr','whost','ports','plaindomain','created','dev','hist','fdays','expts','reason')
                data=json.dumps(dict({k:d[k] for k in keep},announce=sload()['announce'],**brand())).replace('<','\\u003c').replace('>','\\u003e').replace('&','\\u0026')
                return self.out(200,body=rd(UHTML).replace('__DATA__',data).encode(),ct='text/html; charset=utf-8')
            body=base64.b64encode('\n'.join(v for _,v in links(u)).encode())
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
        if r=='/api/hist': return self.out(200,HM) if self.authed() else self.out(401,{'e':'login'})
        if r=='/api/state': return self.out(200,state()) if self.authed() else self.out(401,{'e':'login'})
        if r=='/api/backup':
            if not self.authed(): return self.out(401,{'e':'login'})
            b=json.dumps(backup_obj(),indent=1).encode()
            return self.out(200,body=b,ct='application/json',hdr=(('Content-Disposition','attachment; filename="rexui-backup-%s.json"'%today()),))
        self.nf()
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
        if r=='/api/login-change':
            if not checklogin(curuser(),str(d.get('old',''))): raise Err('Old password is wrong')
            setlogin(str(d.get('u','')).strip(),str(d.get('p','')),keep2fa=True); SESS.clear(); return {'ok':1}
        f={'/api/svc':lambda:restart(str(d.get('unit',''))),'/api/cert':lambda:setcert(d),'/api/settings':lambda:ssave(d),'/api/restore':lambda:restore(d),
           '/api/reality-keys':new_reality,'/api/routing':lambda:routing_save(d),'/api/warp-reset':warp_reset,
           '/api/2fa/setup':lambda:tfa_setup(self.tok()),'/api/2fa/enable':lambda:tfa_enable(self.tok(),d.get('code')),'/api/2fa/disable':lambda:tfa_disable(d.get('code')),
           '/api/bulk':lambda:bulk(d),'/api/automation':lambda:automation_save(d),'/api/tg-test':lambda:tg_test(d),'/api/tg-chat':lambda:tg_findchat(d),
           '/api/trial':trial_new,'/api/csv-import':lambda:csv_import(d),'/api/appearance':lambda:appearance_save(d),
           '/api/logs':lambda:logs(self.tok()),'/api/session-kill':lambda:session_kill(self.tok(),d),'/api/tg-backup':tg_backup_now,
           '/api/fsite':lambda:fsite_save(d),'/api/rfind':lambda:rfind(d),'/api/rdefault':lambda:rdefault(d),'/api/xcheck':xcheck,'/api/xupdate':lambda:xup_bg(bool(d.get('force'))),
           '/api/xauto':lambda:xauto_save(d),'/api/ddns':lambda:ddns_save(d),'/api/panel-path':lambda:panel_path(d),'/api/logview':lambda:logview(d),
           '/api/maint':maint_info,'/api/cleanup':cleanup,'/api/swap':lambda:swap_set(d),'/api/autoclean':lambda:autoclean_save(d),
           '/api/speedtest':speedtest,'/api/portcheck':portcheck,'/api/reboot':lambda:reboot_save(d),'/api/subpage':lambda:subpage_save(d)}.get(r)
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
    elif a[0]=='purge': purge()
    elif a[0]=='backup': print(backup_file(a[1] or None))
    elif a[0]=='restore':
        try: o=json.loads(rd(a[1]))
        except ValueError: print('Restore failed: this file is not valid JSON'); sys.exit(1)
        try: r=restore(o); print('Restored %d users and the settings'%r['users'])
        except Err as e: print('Restore failed:',e); sys.exit(1)
    elif a[0]=='run':
        migrate(); static(); sample(); hm_load(); tr_load(); fsite_apply(); fetch_ips(); CTX=ctx()
        try: bans_apply(); smtp_apply(); enforce(); ssh_rules(True); xray_apply(True)
        except Exception as e: log('startup:',repr(e))
        import signal; signal.signal(signal.SIGTERM,lambda *x:(hm_save(),tr_save(),os._exit(0)))
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
.banner{display:flex;gap:10px;align-items:flex-start;border:1px solid;border-radius:10px;padding:10px 14px;margin-bottom:14px;font-size:13.5px}.banner.w{color:var(--y);background:color-mix(in srgb,var(--y) 10%,var(--c))}.banner.e{color:var(--r);background:color-mix(in srgb,var(--r) 10%,var(--c))}.banner b{color:var(--t)}
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
label{display:block;font-size:13px;color:var(--m);font-weight:600;margin:12px 0 5px}
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
.cb{padding:10px 0;border-bottom:1px solid var(--l)}.cb:last-child{border:0;padding-bottom:0}.cbh{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:6px}
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
.tabx{display:none!important}
#sbar{position:fixed;left:50%;transform:translateX(-50%);bottom:18px;z-index:16;display:flex;align-items:center;gap:6px;flex-wrap:wrap;justify-content:center;width:max-content;max-width:calc(100vw - 24px);background:var(--c);border:1px solid var(--a);border-radius:14px;padding:8px 10px;box-shadow:0 10px 30px rgba(0,0,0,.25)}
#sbar b{font-size:13.5px;padding:0 4px}#sbar .sbs{width:1px;height:22px;background:var(--l)}#sbar [data-sa=x] svg{transform:rotate(45deg)}
.uc{position:relative}.sck{display:grid;place-items:center;width:22px;height:22px;border-radius:7px;border:2px solid var(--l);color:transparent;flex:none;background:var(--c)}.sck.on{background:var(--a);border-color:var(--a);color:#fff}
.uc.sel{border-color:var(--a);box-shadow:0 0 0 1px var(--a)}.ut tr.sel td{background:var(--a2)}
#ul.pick{margin-bottom:90px}
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
.kt b{font-size:21px;line-height:1.25;white-space:nowrap}.kt em{font-style:normal;font-size:12px;color:var(--m);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.g4{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-bottom:14px}.gc{padding:14px 14px 0;overflow:hidden;margin:0}.gt{display:flex;align-items:center;gap:12px}.gi{min-width:0}.gi .lab{margin:0}
.gi .sub{font-size:12.5px;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.gc .ap{margin-top:4px;font-size:11px;gap:10px;justify-content:flex-start}.gc .spk{margin:6px -14px 0}
@media(max-width:1100px){.kps{grid-template-columns:repeat(3,minmax(0,1fr))}.g4{grid-template-columns:repeat(2,minmax(0,1fr))}}
@media(max-width:860px){.kps{grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}.kps .kp:last-child{grid-column:span 2}.g4{gap:10px}.hero{padding:16px}.hero h2{font-size:18px}.hb{width:100%;flex-wrap:nowrap}.hb .btn{flex:1 1 0;justify-content:center;white-space:nowrap;padding:8px 6px;font-size:13px;min-width:0}.kp{padding:11px 12px;gap:10px}.gc .ap{display:none}.gi .sub{font-size:11.5px}.ring{width:52px;height:52px}.gt{gap:9px}.kt b{font-size:18px}.ki{width:34px;height:34px}}
@media(prefers-reduced-motion:reduce){.hdot{animation:none}}
.pwr{display:block;padding:12px 18px 16px;font-size:12px;color:var(--m);text-decoration:none}.pwr:hover b{color:var(--a)}.pwm{display:none;text-align:center;font-size:12px;color:var(--m);margin:18px 0 4px;text-decoration:none}@media(max-width:860px){.pwm{display:block}}
.tri b,.pair b{white-space:nowrap;overflow:hidden;text-overflow:ellipsis}.tri>div,.pair>div{min-width:0}
@media(min-width:861px) and (max-width:1100px){.kps{grid-template-columns:repeat(6,minmax(0,1fr))}.kps .kp{grid-column:span 2}.kps .kp:nth-child(n+4){grid-column:span 3}.tri b{font-size:17px}.pair b{font-size:19px}}
</style><style id="acs"></style></head><body>
<div id="lg" hidden><div class="lbg" aria-hidden="true"><i></i><i></i><i></i></div><form class="lcard" id="lf"><div class="lhead"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><p id="ltg">Sign in to the panel</p></div>
<label for="lu">Username</label><div class="fi"><span data-i="user"></span><input id="lu" autocomplete="username" autocapitalize="none" spellcheck="false"></div>
<label for="lp">Password</label><div class="fi"><span data-i="lock"></span><input id="lp" type="password" autocomplete="current-password"><button type="button" class="ib" id="lpe" aria-label="Show password"></button></div>
<div id="lcw" hidden><label for="lc">6-digit code from your authenticator app</label><div class="fi"><span data-i="shield"></span><input id="lc" inputmode="numeric" autocomplete="one-time-code" maxlength="6"></div></div>
<div id="capw" hidden><label for="lcap">Type the letters from the picture</label><div style="display:flex;align-items:center;gap:8px;margin-bottom:8px"><img id="capi" alt="Security check picture" width="200" height="64" style="border-radius:8px;max-width:100%"><button type="button" class="ib" id="capr" aria-label="Show a new picture"></button></div><div class="fi"><span data-i="shield"></span><input id="lcap" autocapitalize="characters" autocomplete="off" spellcheck="false" maxlength="8"></div></div>
<div class="err" id="le" role="alert"></div><button class="btn pri lbtn">Log in</button><p class="lft">Protected panel · ReXUI v1.0</p></form></div>
<div id="app" hidden><aside><div class="brand"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><button class="ib sxb" aria-label="Search" title="Search (/)" style="margin-left:auto"></button><button class="ib thb" id="th" aria-label="Switch theme"></button></div><nav id="nav"></nav><a class="pwr" href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener">Powered by <b>ReXUI</b> v1.0</a></aside>
<main><div id="mt"><b class="logo blogo" aria-label="ReXUI"><span>Re</span><i>X</i><span>UI</span></b><button class="ib sxb" aria-label="Search"></button><button class="ib thb" aria-label="Switch theme"></button><button class="ib" id="lo2" aria-label="Log out"></button></div><div id="cbn"></div><div class="hdr"><span class="chip" id="xs"></span><span class="ver">ReXUI v1.0</span><small class="m" id="upd" style="margin-left:auto"></small></div><div id="pg"></div><a class="pwm" href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener">Powered by ReXUI v1.0</a></main><nav id="bn" aria-label="Main"></nav></div>
<div id="dt" hidden><div class="dts"><div class="dth"><b>User details</b><button class="btn sm" id="dx" aria-label="Close">Close</button></div><div id="dtb"></div></div></div>
<div id="md" hidden><form class="card" id="mf"></form></div>
<div id="sxo" hidden><div class="sxp" role="dialog" aria-label="Search"><div class="fi"><span data-i="search"></span><input id="sxi" placeholder="Search users, settings, tools..." autocomplete="off" spellcheck="false" aria-label="Search"><button type="button" class="btn sm" id="sxx">Esc</button></div><div id="sxr" role="listbox"></div></div></div>
<div id="shm" hidden><div class="card shc" role="dialog" aria-label="Share account"><div class="ct"><b>Share account</b><button class="btn sm" id="shx">Close</button></div><img id="shi" alt="Account card with QR code"><div class="mr"><button type="button" class="btn" id="shc">Copy text</button><button type="button" class="btn" id="shd">Download</button><button type="button" class="btn pri" id="shs">Share</button></div></div></div>
<div id="qrm" hidden><div class="card qrc"><div class="ct"><b id="qrt"></b><button class="btn sm" id="qrx">Close</button></div><div id="qrs"></div><p class="note" style="margin-top:10px;text-align:center">Scan with v2rayNG, NekoBox or Hiddify</p></div></div>
<script src="/qr.js"></script>
<script>
const ls=(k,v)=>{try{if(v===undefined)return localStorage.getItem(k);localStorage.setItem(k,v)}catch(e){return null}};
const $=s=>document.querySelector(s),X=s=>String(s??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const P={gauge:'<path d="M4 18a8 8 0 1 1 16 0"/><path d="M12 18l4-6"/>',users:'<circle cx="9" cy="8" r="4"/><path d="M2 21c0-4 3-6 7-6s7 2 7 6M17 4a4 4 0 0 1 0 8M22 21c0-3-2-5-5-5.7"/>',user:'<circle cx="12" cy="8" r="4"/><path d="M4 21c0-4 4-6 8-6s8 2 8 6"/>',gear:'<circle cx="12" cy="12" r="3"/><path d="M12 2v3M12 19v3M2 12h3M19 12h3M5 5l2 2M17 17l2 2M5 19l2-2M17 7l2-2"/>',out:'<path d="M9 4H5v16h4M16 8l4 4-4 4M20 12H9"/>',up:'<path d="M12 19V5M6 11l6-6 6 6"/>',down:'<path d="M12 5v14M6 13l6 6 6-6"/>',cpu:'<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',ram:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 10h18M3 15h18"/>',swap:'<path d="M4 8h16l-4-4M20 16H4l4 4"/>',disk:'<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 9h18M3 14h18M7 6.5h.01"/>',clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',panel:'<rect x="4" y="3" width="16" height="18" rx="2"/><path d="M8 7h8M8 11h8M8 15h5"/>',globe:'<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3a14 14 0 0 1 0 18M12 3a14 14 0 0 0 0 18"/>',eye:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',eyeoff:'<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><path d="M3 3l18 18"/>',plus:'<path d="M12 5v14M5 12h14"/>',cal:'<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',key:'<circle cx="8" cy="15" r="4"/><path d="M11 12l9-9M17 6l3 3"/>',lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',unlock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 7.5-2"/>',del:'<path d="M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13"/>',dev:'<rect x="7" y="2" width="10" height="20" rx="2"/><path d="M11 18h2"/>',cert:'<rect x="3" y="4" width="18" height="13" rx="2"/><circle cx="12" cy="19" r="3"/><path d="M7 9h10M7 12h6"/>',refresh:'<path d="M3 12a9 9 0 0 1 15-6.7L21 8M21 3v5h-5M21 12a9 9 0 0 1-15 6.7L3 16M3 21v-5h5"/>',sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',moon:'<path d="M20 14.5A8 8 0 1 1 9.5 4a6.5 6.5 0 0 0 10.5 10.5z"/>',net:'<path d="M5 12a7 7 0 0 1 14 0M8.5 12a3.5 3.5 0 0 1 7 0"/><circle cx="12" cy="16" r="1.5"/>',shield:'<path d="M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z"/>',wifi:'<path d="M2 8.5a15 15 0 0 1 20 0M5 12a10 10 0 0 1 14 0M8.5 15.5a5 5 0 0 1 7 0"/><circle cx="12" cy="19" r="1"/>',kick:'<circle cx="12" cy="12" r="9"/><path d="M15 9l-6 6M9 9l6 6"/>',save:'<path d="M12 3v12M7 10l5 5 5-5M4 19h16"/>',upl:'<path d="M12 21V9M7 14l5-5 5 5M4 5h16"/>',chart:'<path d="M4 20V11M10 20V5M16 20v-6M21 20H3"/>',search:'<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.6-3.6"/>',file:'<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5M9 13h6M9 17h6"/>',grid:'<rect x="3" y="3" width="7" height="7" rx="1.5"/><rect x="14" y="3" width="7" height="7" rx="1.5"/><rect x="3" y="14" width="7" height="7" rx="1.5"/><rect x="14" y="14" width="7" height="7" rx="1.5"/>',list:'<path d="M9 6h12M9 12h12M9 18h12M4 6h.01M4 12h.01M4 18h.01"/>',check:'<path d="M5 12l5 5 9-10"/>',palette:'<path d="M12 3a9 9 0 1 0 0 18c1.5 0 2-1 2-2s-1-1.5-1-2.5 1-1.5 2-1.5h2a4 4 0 0 0 4-4c0-4.4-4-8-9-8z"/><circle cx="7.5" cy="11" r="1"/><circle cx="10.5" cy="7" r="1"/><circle cx="15" cy="7.5" r="1"/>'};
const I=(k,s=18)=>`<svg width="${s}" height="${s}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${P[k]}</svg>`;
const fb=(b,s='')=>{const u=['B','KB','MB','GB','TB'];let i=0;b=+b||0;while(b>=1024&&i<4){b/=1024;i++}return (i?b.toFixed(2):b.toFixed(0))+' '+u[i]+s};
const dur=s=>{s=Math.floor(s||0);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return d?`${d}d ${h}h`:h?`${h}h ${m}m`:m?`${m}m`:`${s}s`};
const pct=(a,b)=>b?a/b*100:0,avg=a=>a&&a.length?a.reduce((x,y)=>x+y,0)/a.length:0,peak=a=>a&&a.length?Math.max(...a):0;
const api=async(p,d)=>{const r=await fetch(p,{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify(d||{})});const j=await r.json().catch(()=>({}));if(r.status==401&&p!='api/login'){show(false);throw Error('Please log in again')}if(!r.ok)throw Error(j.e||'Error '+r.status);return j};
function toast(t,e){const o=document.createElement('div');o.className='toast'+(e?' e':'');o.setAttribute('role','status');o.textContent=t;document.body.append(o);setTimeout(()=>o.remove(),e?6000:2200)}
let D=null,pg='ov',hideIp=true,gid=0,SAC=null,RG=ls('rx-range')||'live',HMD=null,HMT=0;
async function loadHist(){try{const r=await fetch('api/hist',{cache:'no-store'});if(r.ok){HMD=await r.json();HMT=Date.now()}}catch(e){}}const show=v=>{$('#lg').hidden=v;$('#app').hidden=!v};
function theme(t){const de=document.documentElement;if(t=='auto')delete de.dataset.theme;else if(t)de.dataset.theme=t;const dk=de.dataset.theme?de.dataset.theme!='light':matchMedia('(prefers-color-scheme: dark)').matches;document.querySelectorAll('.thb').forEach(b=>{b.innerHTML=I(dk?'sun':'moon',18);b.setAttribute('aria-label',dk?'Switch to light theme':'Switch to dark theme')});return dk}
try{const t=localStorage.getItem('rx-theme');if(t)document.documentElement.dataset.theme=t}catch(e){}
document.querySelectorAll('.thb').forEach(b=>b.onclick=()=>{const n=theme()?'light':(ls('rx-dark')||'dark');theme(n);try{localStorage.setItem('rx-theme',n)}catch(e){}if(D&&pg=='ov')ov()});theme();
const AC={blue:['#1f6feb','#4c8dff','Blue'],teal:['#0d9488','#2dd4bf','Teal'],green:['#15803d','#4ade80','Green'],purple:['#7c3aed','#a78bfa','Purple'],pink:['#db2777','#f472b6','Pink'],orange:['#ea580c','#fb923c','Orange'],indigo:['#4f46e5','#818cf8','Indigo']};
function accent(k){const a=AC[k]||AC.blue,d1=':root:not([data-theme=light])',d2=':root[data-theme=dark],:root[data-theme=black]',pt=q=>k=='blue'?'':q.split(',').map(x=>`${x} .pri,${x} .pri:hover`).join(',')+'{color:#0b1020}';
$('#acs').textContent=`:root{--a:${a[0]}}@media(prefers-color-scheme:dark){${d1}{--a:${a[1]}}${pt(d1)}}${d2}{--a:${a[1]}}${pt(d2)}`}
const logoH=b=>!b||b=='ReXUI'?'<span>Re</span><i>X</i><span>UI</span>':`<span>${X(b)}</span>`;
let BR={brand:'',tagline:'',accent:'blue'};
function applyBrand(b){BR={brand:b.brand||'',tagline:b.tagline||'',accent:b.accent||'blue'};const n=BR.brand||'ReXUI';
document.querySelectorAll('.blogo').forEach(e=>{e.innerHTML=logoH(BR.brand);e.setAttribute('aria-label',n)});document.title=n;$('#ltg').textContent=BR.tagline||'Sign in to the panel';accent(BR.accent);ls('rx-brand',JSON.stringify(BR))}
try{const c=JSON.parse(ls('rx-brand')||'null');if(c)applyBrand(c)}catch(e){}
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
const NAV=[['ov','Overview','gauge'],['us','Users','users'],['on','Online','wifi'],['sc','Security','shield'],['st','Settings','gear'],['lo','Log out','out']];
$('#nav').innerHTML=NAV.map(n=>`<button class="nb" data-p="${n[0]}" title="${n[1]}">${I(n[2],19)}<span>${n[1]}</span></button>`).join('');
$('#bn').innerHTML=NAV.filter(n=>n[0]!='lo').map(n=>`<button class="bnb" data-p="${n[0]}" aria-label="${n[1]}"><i>${I(n[2],21)}</i>${n[1]}</button>`).join('');
async function logout(){try{await api('api/logout')}catch(x){}show(false)}
$('#lo2').onclick=()=>{if(confirm('Log out of the panel?'))logout()};
$('#nav').onclick=$('#bn').onclick=e=>{const b=e.target.closest('[data-p]');if(!b)return;if(b.dataset.p=='lo')return logout();go(b.dataset.p)};
function go(p){pg=p;HOV=null;accent(BR.accent);if(p!='us'){UV.sel=null;selbar()}document.querySelectorAll('.nb,.bnb').forEach(b=>b.classList.toggle('on',b.dataset.p==p));$('#pg').innerHTML='';render(true);window.scrollTo(0,0)}
async function load(){try{const r=await fetch('api/state',{cache:'no-store'});if(r.status==401)return show(false);D=await r.json();const sb=D.set;if(sb.brand!=BR.brand||sb.tagline!=BR.tagline||sb.accent!=SAC){SAC=sb.accent;applyBrand(sb)}
if(pg=='ov'&&RG!='live'&&Date.now()-HMT>60000)await loadHist();if($('#app').hidden){show(true);go(pg)}else render();hdr();$('#upd').textContent='Live · '+new Date().toLocaleTimeString()}catch(e){$('#upd').textContent='Connection lost, retrying...'}}
function hdr(){const c=D.cert;$('#cbn').innerHTML=c.days!=null&&c.days<=30?`<div class="banner ${c.days<0?'e':'w'}" role="status">${I('cert',17)}<div><b>${c.days<0?'Your SSL certificate has expired.':'Your SSL certificate expires in '+c.days+' day'+(c.days==1?'':'s')+'.'}</b> ${X(c.name)} · Renew it, then paste the new one in Settings or use menu → 7 on the server.</div></div>`:'';
const x=D.svc.find(s=>s.unit=='xray'),on=x&&x.st=='RUNNING';$('#xs').innerHTML=`<span class="dot" style="background:${on?'var(--g)':'var(--r)'}"></span>Xray · ${on?'Running':'Stopped'} <span class="m">v${X(D.xray.ver||'?')}</span>`}
function render(first){if(!D)return;if(pg=='ov'){ov();tipRestore()}else if(pg=='us')us(first);else if(pg=='on')onl();else if(pg=='sc')secp(first);else if(first)st();else stb()}
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
<div class="hb"><button class="btn pri" id="add">${I('plus',15)}Add user</button><button class="btn" id="trl">${I('clock',15)}Trial</button><button class="btn" data-r="xray">${I('refresh',15)}Restart Xray</button></div></div>
<div class="kps">${kpi('Online now',on,'of '+d.users.length+' users','var(--g)','us','on','wifi')}${kpi('Active',act,ended?ended+' ended':'',  'var(--a)','us','all','users')}${kpi('Expiring soon',soon,soon?'renew them':'all good','var(--y)','us','soon','cal')}${kpi('Traffic today',fb(td[1]+td[2]),'↑ '+fb(td[2])+' ↓ '+fb(td[1]),'#8b5cf6','','','up')}${kpi('This month',fb(mo[1]+mo[2]),new Date().toLocaleString([],{month:'long'}),'#0d9488','','','chart')}</div>
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
$('#pg').onclick=e=>{if(UV.sel){const o=e.target.closest('#ul [data-open]');if(o){const n=o.dataset.open;UV.sel.has(n)?UV.sel.delete(n):UV.sel.add(n);return us()}}
if(e.target.closest('#sel')){UV.sel=UV.sel?null:new Set();return us(true)}
const g=e.target.closest('[data-go]');if(g){if(g.dataset.f)UV.f=g.dataset.f;return go(g.dataset.go)}
const fl=e.target.closest('[data-f]');if(fl){UV.f=fl.dataset.f;return us()}
if(e.target.closest('#trl'))return trial();
if(e.target.closest('#eye')){hideIp=!hideIp;return ov()}
const t1=e.target.closest('[data-tu]');if(t1){TU=t1.dataset.tu;return ov()}const t2=e.target.closest('[data-pr]');if(t2){PRR=t2.dataset.pr;return ov()}const t3=e.target.closest('[data-trm]');if(t3){TRM=t3.dataset.trm;return ov()}
const sk=e.target.closest('[data-sk]');if(sk){api('api/session-kill',{id:sk.dataset.sk}).then(()=>{toast('Session logged out');secp(true)}).catch(x=>toast(x.message,1));return}
if(e.target.closest('#lgall')){if(!confirm('Log out every other device? You stay logged in here.'))return;api('api/session-kill',{all:1}).then(()=>{toast('Other devices logged out');secp(true)}).catch(x=>toast(x.message,1));return}
const rg=e.target.closest('[data-rg]');if(rg){RG=rg.dataset.rg;ls('rx-range',RG);HOV=null;if(RG!='live'&&Date.now()-HMT>60000)loadHist().then(ov);return ov()}
const vw=e.target.closest('[data-v]');if(vw){UV.v=vw.dataset.v;ls('rx-view',UV.v);return us(true)}
const so=e.target.closest('[data-sort]');if(so){const k=so.dataset.sort;UV.rev=UV.k==k?!UV.rev:false;UV.k=k;ls('rx-sort',k);return us(true)}
const r=e.target.closest('[data-r]');if(r)return restartUnit(r.dataset.r,r.textContent.replace('Restart ','').trim());
const s=e.target.closest('.sv');if(s&&!s.disabled)return restartUnit(s.dataset.u,s.dataset.n);
if(e.target.closest('#add'))return umodal();
if(e.target.closest('#blk'))return bulkm();
const c=e.target.closest('[data-open]');if(c)return openU(c.dataset.open);
const k=e.target.closest('[data-kick]');if(k){const n=k.dataset.kick;if(!confirm('Disconnect '+n+' from all devices now?'))return;api('api/user/kick',{name:n}).then(()=>{toast(n+' disconnected');load()}).catch(x=>toast(x.message,1));return}
if(e.target.closest('#bk')){location.href='api/backup';return}
if(e.target.closest('#rsb'))return $('#rsf').click()};
const STC={online:'var(--g)',active:'var(--a)',expired:'var(--r)',limit:'var(--r)',disabled:'var(--y)'},STN={online:'online',active:'active',expired:'expired',limit:'limit reached',disabled:'disabled'};
const ubar=(used,lim)=>{const p=lim?Math.min(100,used/(lim*1073741824)*100):0;return `<div class="ubar"><i style="width:${p}%;background:${p>90?'var(--r)':p>75?'var(--y)':'var(--a)'}"></i></div>`};
const lims=(used,lim)=>`${fb(used)} / ${lim?lim+' GB':'Unlimited'}`,hue=n=>[...n].reduce((a,c)=>a*31+c.charCodeAt(0),7)%360;
const SR={online:0,active:1,limit:2,expired:3,disabled:4},ek=u=>u.exp=='never'?9e15:Date.parse(u.exp);
const SO={name:['Name',(a,b)=>a.name.localeCompare(b.name)],used:['Most used',(a,b)=>b.used-a.used],exp:['Expires first',(a,b)=>ek(a)-ek(b)],new:['Newest',(a,b)=>(b.created||'').localeCompare(a.created||'')||a.name.localeCompare(b.name)],st:['Status',(a,b)=>SR[a.st]-SR[b.st]||a.name.localeCompare(b.name)]};
const UV={v:ls('rx-view')||'cards',k:SO[ls('rx-sort')]?ls('rx-sort'):'name',rev:false,f:'all'};
const dnum=u=>u.exp=='never'?1e9:Math.ceil((Date.parse(u.exp+'T23:59:59')-Date.now())/864e5);
const dleft=u=>{if(u.fdays)return 'starts on first use';if(u.expts){const h=Math.ceil((u.expts*1000-Date.now())/36e5);return h<=0?'ended':h+'h left'}if(u.exp=='never')return '';const d=dnum(u);return d<0?'ended':d==0?'today':d+'d left'};
const expTxt=u=>u.fdays?`First use + ${u.fdays} day${u.fdays==1?'':'s'}`:u.exp=='never'?'No expiry':u.exp;
const expiring=u=>!u.trial&&['active','online'].includes(u.st)&&(dnum(u)<=3||(u.lim>0&&u.used>=u.lim*1073741824*.9));
const FL={all:['All',u=>1],on:['Online',u=>u.st=='online'],soon:['Expiring soon',expiring],end:['Ended',u=>['expired','limit'].includes(u.st)],off:['Disabled',u=>u.st=='disabled'],trial:['Trial',u=>u.trial]};
const tagT=u=>u.trial?'<span class="tag">Trial</span>':'';
const av=(n,s)=>`<div class="av" style="background:hsl(${hue(n)} 55% 52%)">${X(n[0]).toUpperCase()}</div>`;
function selbar(){let b=$('#sbar');if(!UV.sel||pg!='us'){if(b)b.remove();return}if(!b){b=document.createElement('div');b.id='sbar';b.setAttribute('role','toolbar');b.setAttribute('aria-label','Selected users');document.body.append(b);b.onclick=selact}
const n=UV.sel.size,all=UV.L&&UV.L.length&&UV.L.every(x=>UV.sel.has(x));b.innerHTML=`<b>${n} selected</b><button type="button" class="btn sm" data-sa="all">${all?'Clear':'Select all'}</button><span class="sbs"></span>
${[['days','cal','Add days'],['reset','refresh','Reset usage'],['disable','lock','Disable'],['enable','unlock','Enable'],['delete','del','Delete']].map(x=>`<button type="button" class="btn sm${x[0]=='delete'?' dng':''}" data-sa="${x[0]}"${n?'':' disabled'}>${I(x[1],14)}${x[2]}</button>`).join('')}<button type="button" class="ib" data-sa="x" aria-label="Stop selecting">${I('plus',18)}</button>`}
async function selact(e){const b=e.target.closest('[data-sa]');if(!b)return;const a=b.dataset.sa,names=[...UV.sel],N=names.length+' user'+(names.length==1?'':'s');
if(a=='x'){UV.sel=null;selbar();return us(true)}if(a=='all'){const all=UV.L.every(x=>UV.sel.has(x));UV.L.forEach(x=>all?UV.sel.delete(x):UV.sel.add(x));return us()}
const done=async(o,msg)=>{try{const r=await api('api/bulk',Object.assign({names},o));toast(msg.replace('#',r.count));if(a=='delete')UV.sel.clear();await load()}catch(x){toast(x.message,1)}};
if(a=='days')return modal('Add days to '+N,[['days','Days to add','number','',30]],d=>api('api/bulk',{names,action:'days',days:d.days}).then(r=>{toast('Added '+d.days+' days to '+r.count+' user(s)');load()}),'Users without expiry are skipped.');
if(a=='disable')return modal('Disable '+N,[['reason','Reason (optional, shown on their page)','text','Payment pending']],d=>api('api/bulk',{names,action:'disable',reason:d.reason}).then(r=>{toast(r.count+' user(s) disabled');load()}));
if(a=='reset'){if(confirm('Reset data usage of '+N+'?'))done({action:'reset'},'Usage reset for # user(s)');return}
if(a=='enable')return done({action:'enable'},'# user(s) enabled');
if(a=='delete'){if(confirm('Delete '+N+'? This cannot be undone.\n\n'+names.slice(0,20).join(', ')+(names.length>20?' ...':'')))done({action:'delete'},'# user(s) deleted');return}}
function us(first){if(first){$('#pg').innerHTML=`<div class="bar"><input id="q" placeholder="Search users or notes" aria-label="Search users" value="${X(UV.q||'')}"><select id="srt" aria-label="Sort users">${Object.entries(SO).map(([k,v])=>`<option value="${k}"${k==UV.k?' selected':''}>Sort: ${v[0]}</option>`).join('')}</select>
<div class="seg" role="group" aria-label="View">${[['cards','grid','Card view'],['table','list','Table view']].map(x=>`<button type="button" data-v="${x[0]}" class="${UV.v==x[0]?'on':''}" aria-pressed="${UV.v==x[0]}" aria-label="${x[2]}" title="${x[2]}">${I(x[1],16)}</button>`).join('')}</div>
<button class="btn${UV.sel?' pri':''}" id="sel" aria-pressed="${!!UV.sel}">${I('check',16)}${UV.sel?'Done':'Select'}</button><button class="btn" id="blk">${I('users',16)}Bulk / CSV</button><button class="btn" id="trl" title="1 day, 2 GB, deleted when it ends">${I('clock',16)}Trial</button><button class="btn pri" id="add">${I('plus',16)}Add user</button></div><div class="chips" id="flt" role="group" aria-label="Filter users"></div><div id="ul"></div>`;
$('#q').oninput=()=>{UV.q=$('#q').value;us()};$('#srt').onchange=()=>{UV.k=$('#srt').value;UV.rev=false;ls('rx-sort',UV.k);us(true)}}
if(!FL[UV.f])UV.f='all';$('#flt').innerHTML=Object.entries(FL).map(([k,v])=>{const c=D.users.filter(v[1]).length;return k!='all'&&k!='trial'||c||k=='all'?`<button type="button" data-f="${k}" class="${UV.f==k?'on':''}" aria-pressed="${UV.f==k}">${v[0]} <b>${c}</b></button>`:''}).join('');
const q=(UV.q||'').toLowerCase(),L=D.users.filter(FL[UV.f][1]).filter(u=>u.name.toLowerCase().includes(q)||(u.note||'').toLowerCase().includes(q)).sort(SO[UV.k][1]);if(UV.rev)L.reverse();
UV.L=L.map(u=>u.name);if(UV.sel){const all=new Set(D.users.map(u=>u.name));UV.sel.forEach(n=>{if(!all.has(n))UV.sel.delete(n)})}selbar();
const el=$('#ul');el.classList.toggle('pick',!!UV.sel);if(!L.length){el.className='';el.innerHTML=`<div class="empty card">${D.users.length?(UV.f!='all'?'No users in "'+FL[UV.f][0]+'"':'No user matches your search'):'No users yet. Tap "Add user" to create one.'}</div>`;return}
if(UV.v=='table'){el.className='card tw';const th=(k,t)=>k?`<th scope="col"><button type="button" data-sort="${k}" class="${UV.k==k?'on':''}">${t}${UV.k==k?I(UV.rev?'up':'down',12):''}</button></th>`:`<th scope="col"><button type="button" tabindex="-1" style="cursor:default">${t}</button></th>`;
const ck=u=>UV.sel?`<span class="sck${UV.sel.has(u.name)?' on':''}" aria-hidden="true">${I('check',13)}</span>`:'';
el.innerHTML=`<table class="ut"><thead><tr>${th('name','User')}${th('st','Status')}${th('used','Usage')}${th('exp','Expiry')}${th('','Devices')}${th('new','Created')}</tr></thead><tbody>${L.map(u=>{const n=X(u.name),dl=dleft(u);return `<tr data-open="${n}" class="${UV.sel&&UV.sel.has(u.name)?'sel':''}" tabindex="0" aria-label="Open ${n}">
<td><div class="tu">${ck(u)}${av(u.name)}<div style="min-width:0"><b>${n}</b>${tagT(u)}${u.note?`<small>${X(u.note)}</small>`:''}</div></div></td><td><span class="pill" style="color:${STC[u.st]}">${STN[u.st]}</span></td>
<td>${lims(u.used,u.lim)}${u.lim?ubar(u.used,u.lim):''}</td><td>${u.exp=='never'&&!u.fdays?'<span class="m">No expiry</span>':X(u.fdays?'First use + '+u.fdays+'d':u.exp)+(dl&&!u.fdays?`<small class="${dl=='ended'?'bad':expiring(u)?'':'m'}" style="display:block${expiring(u)?';color:var(--y)':''}">${dl}</small>`:'')}</td>
<td>${u.on} / ${u.dev||'∞'}</td><td class="m">${X(u.created||'-')}</td></tr>`}).join('')}</tbody></table>`;return}
el.className='ul'+(UV.sel?' pick':'');el.innerHTML=L.map(u=>{const n=X(u.name),on=UV.sel&&UV.sel.has(u.name);return `<button class="card uc${on?' sel':''}" data-open="${n}" aria-label="${UV.sel?(on?'Unselect ':'Select ')+n:'Open '+n}"${UV.sel?` aria-pressed="${!!on}"`:''}><div class="uh">${UV.sel?`<span class="sck${on?' on':''}" aria-hidden="true">${I('check',13)}</span>`:''}${av(u.name)}<div style="min-width:0"><b>${n}</b>${tagT(u)}<small class="m" style="display:block">${lims(u.used,u.lim)}</small></div><span class="pill" style="color:${STC[u.st]}">${STN[u.st]}</span></div>
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
function onl(){const L=D.online;const tot=L.reduce((a,x)=>a+x.ssh+x.ips.length,0);
$('#pg').innerHTML=`<div class="card mb"><div class="ct"><div class="lab">${I('wifi',15)}Online users</div><span class="m">${L.length} users · ${tot} connections</span></div>
<p class="note">SSH shows active sessions. Xray shows the IPs seen in the last 2 minutes. Kick disconnects the user and blocks their current Xray IPs for 1 minute. An IP shared with another user (common on mobile data) is never blocked.</p></div>
${L.length?`<div class="ul">${L.map(x=>{const n=X(x.name),over=x.dev&&(x.ssh>x.dev||x.ips.length>x.dev);return `<div class="card"><div class="uh"><div class="av" style="background:hsl(${hue(x.name)} 55% 52%)">${n[0].toUpperCase()}</div><div style="min-width:0"><b>${n}</b><small class="m" style="display:block">Device limit ${x.dev||'Unlimited'}${over?' · <span class="bad">over limit</span>':''}</small></div><button class="btn sm dng" data-kick="${n}" style="margin-left:auto">${I('kick',14)}Kick</button></div>
<div class="kv" style="margin-top:10px"><span>SSH sessions</span><b>${x.ssh}</b></div>${x.ips.map(i=>`<div class="kv"><span>Xray ${X(i.ip)}</span><b>${i.ban?'<span class="bad">Blocked '+i.ban+'s</span>':i.ago+'s ago'+(i.shared?' · shared IP':'')}</b></div>`).join('')}<button class="btn sm" data-open="${n}" style="margin-top:10px">Details</button></div>`}).join('')}</div>`:'<div class="empty card">No one is connected right now.</div>'}`}
function bulkm(){modal('Bulk actions and CSV',[['action','Action','select','','days',[['days','Add days to expiry'],['reset','Reset data usage to 0']]],['days','Days to add (for "Add days")','number','',1],['scope','Apply to','select','','active',[['active','Active users only'],['all','All users']]]],
async d=>{const n=d.scope=='all'?D.users.length:D.users.filter(u=>['active','online'].includes(u.st)).length;if(!confirm((d.action=='days'?'Add '+d.days+' days to ':'Reset data usage of ')+n+' user(s)?'))throw Error('Cancelled');const r=await api('api/bulk',d);toast('Done for '+r.count+' user(s)')},
`Users without expiry are skipped when adding days.<span style="display:block;border-top:1px solid var(--l);margin-top:12px;padding-top:12px"><b style="color:var(--t)">CSV file</b> (Excel / Google Sheets): export all users, or import new ones. Columns: name, password, expiry (YYYY-MM-DD, days, never or first-use+30), data_limit_gb, devices, reset_day, sni, host, note. Export once to see the format.</span><span style="display:flex;gap:8px;margin-top:10px"><button type="button" class="btn sm" id="cxe">${I('save',14)}Export CSV</button><button type="button" class="btn sm" id="cxi">${I('upl',14)}Import CSV</button><input type="file" id="cxf" accept=".csv,text/csv" hidden></span>`);csvUI()}
const rpw=()=>{const a='abcdefghjkmnpqrstuvwxyz23456789';let r='';const v=crypto.getRandomValues(new Uint32Array(10));v.forEach(x=>r+=a[x%a.length]);return r};
function umodal(u,c){const ds=D.set,dd=D.cert.domain,def=v=>'Default: '+(v||'auto');
const F=u?[['pw','New password (leave empty to keep)','text',''],['days',u&&u.fdays?'Add days (counting has not started yet)':'Add days (0 = no change)','number','',0],['lim','Data limit in GB (0 = unlimited)','number','',u.lim],['dev','Device limit (0 = unlimited)','number','',u.dev],['rday','Monthly data reset day, 1-28 (0 = off)','number','',u.rday],['sni','SNI for TLS configs (empty = default)','text',def(ds.sni||dd),u.sni],['host','Host (empty = default)','text',def(ds.host||dd||D.addr),u.host],['rtarget','Reality target (empty = default)','text',def(ds.rsni+':443'),u.rtarget],['rsni','Reality SNI (empty = same as target)','text',def((u.rtarget||ds.rsni+':443').split(':')[0]),u.rsni_u],['note','Note (only you see this)','area','Name, phone, payment...',u.note]]
:[['name','Username','text','Any name, no spaces'],['pw','Password','text',''],['days','Valid for days (0 = no expiry)','number','',30],['lim','Data limit in GB (0 = unlimited)','number','',0],['dev','Device limit (0 = unlimited)','number','',1],['rday','Monthly data reset day, 1-28 (0 = off)','number','',0],['sni','SNI for TLS configs (empty = default)','text',def(ds.sni||dd)],['host','Host (empty = default)','text',def(ds.host||dd||D.addr)],['rtarget','Reality target (empty = default)','text',def(ds.rsni+':443')],['rsni','Reality SNI (empty = same as target)','text','Default: same as target'],['note','Note (only you see this)','area','Name, phone, payment...']];
if(!u){F.splice(3,0,['first','Start the days on first connection (not today)','check']);F[1][4]=rpw();if(c){const dl=c.fdays||(c.exp=='never'?0:Math.max(1,dnum(c)));Object.assign(F[2],{4:dl});F[3][4]=!!c.fdays;F[4][4]=c.lim;F[5][4]=c.dev;F[6][4]=c.rday;F[7][4]=c.sni;F[8][4]=c.host;F[9][4]=c.rtarget;F[10][4]=c.rsni_u;F[11][4]=c.note}}
const RI='Reality target is a real website with TLS 1.3, like www.microsoft.com:443. SNI must be a name that website answers for. Users with a different target get their own Reality port automatically.';
modal(u?'Edit '+u.name:c?'Clone '+c.name:'Add user',F,d=>u?api('api/user/edit',Object.assign(d,{name:u.name})).then(()=>{toast('User updated');openU(u.name)}):api('api/user/add',d).then(()=>{toast('User created');openU(d.name)}),RI)}
let DT=null,CP=[];const cp=t=>{CP.push(t);return CP.length-1};
async function copy(t){try{await navigator.clipboard.writeText(t)}catch(e){const a=document.createElement('textarea');a.value=t;a.style.position='fixed';a.style.opacity='0';document.body.append(a);a.select();document.execCommand('copy');a.remove()}toast('Copied')}
function payloads(h,p){return [`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]`,`GET /ws HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==[crlf]Sec-WebSocket-Version: 13[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]User-Agent: Mozilla/5.0[crlf][crlf]`,`GET http://${h}/ HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]X-Online-Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Keep-Alive[crlf]Upgrade: websocket[crlf][crlf]`,`POST / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`PATCH / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`OPTIONS / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`CONNECT ${h}:${p.WS_PORT} HTTP/1.1[crlf]Host: ${h}[crlf][crlf]`,`HEAD / HTTP/1.1[crlf]Host: ${h}[crlf][crlf][split]GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf][crlf][split]GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`]}
async function openU(n){try{DT=await api('api/user/detail',{name:n})}catch(x){return toast(x.message,1)}drawU();$('#dt').hidden=false;$('#dt .dts').scrollTop=0}
function usageCard(h){if(!h||!h.length)return '';const mx=Math.max(1,...h.map(x=>x[1]+x[2])),tot=h.reduce((a,x)=>a+x[1]+x[2],0),td=h[h.length-1];
return `<div class="card"><div class="ct"><div class="lab">Daily usage (30 days)</div><b>${fb(tot)}</b></div><div class="um"><span class="bl">Today ${fb(td[1]+td[2])}</span><span>Peak ${fb(mx==1?0:mx)}</span></div>
<div class="uch" role="img" aria-label="Daily data usage for the last 30 days">${h.map(x=>`<i title="${x[0]}: ↑ ${fb(x[1])} ↓ ${fb(x[2])}"><b style="height:${(x[1]/mx*100).toFixed(1)}%"></b><u style="height:${(x[2]/mx*100).toFixed(1)}%"></u></i>`).join('')}</div>
<div class="uax"><span>${h[0][0].slice(5)}</span><span><b style="color:var(--a)">■</b> Upload <b style="color:var(--l2)">■</b> Download</span><span>Today</span></div></div>`}
function onlineCard(u){const any=u.ssh||u.ips.length;return `<div class="card"><div class="ct"><div class="lab">${I('wifi',15)}Connected now</div>${any?`<button class="btn sm dng" data-ua="kick">${I('kick',14)}Kick</button>`:''}</div>
${any?`<div class="kv"><span>SSH sessions</span><b>${u.ssh}</b></div>${u.ips.map(x=>`<div class="kv"><span>Xray ${X(x.ip)}</span><b>${x.ban?'<span class="bad">Blocked '+x.ban+'s</span>':'Active '+x.ago+'s ago'+(x.shared?' · shared IP':'')}</b></div>`).join('')}`:'<p class="note">Not connected right now.</p>'}</div>`}
function drawU(){const u=DT,p=u.ports,n=X(u.name);CP=[];
const row=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
const cbox=(label,v,qr)=>{const i=cp(v);return `<div class="cb"><div class="cbh"><small>${X(label)}</small><span style="display:flex;gap:6px">${qr===false?'':`<button class="btn sm" data-qr="${i}" data-ql="${X(label)}">QR</button>`}<button class="btn sm" data-cp="${i}">Copy</button></span></div><button class="code" data-cp="${i}" aria-label="Copy ${X(label)}">${X(v)}</button></div>`};
const sshAll=`Host: ${u.addr}\nUsername: ${u.name}\nPassword: ${u.pw||'-'}\nSSH: ${p.SSH_PORT}\nSSH SSL/TLS: ${p.SSL_PORT}\nSSH WS: ${p.WS_PORT}\nSSH WS TLS: ${p.WSTLS_PORT}\nUDPGW: 127.0.0.1:${p.UDPGW_PORT}\nExpires: ${u.exp=='never'?'No expiry':u.exp}`;
$('#dtb').innerHTML=`<div class="uh" style="margin-bottom:14px"><div class="av" style="background:hsl(${hue(u.name)} 55% 52%)">${n[0].toUpperCase()}</div><div style="min-width:0"><b style="font-size:18px">${n}</b>${tagT(u)}<small class="m" style="display:block">Created ${X(u.created||'-')}</small></div><span class="pill" style="color:${STC[u.st]}">${STN[u.st]}</span></div>
<div class="card"><div class="ct"><div class="lab">Data usage</div><b>${lims(u.used,u.lim)}</b></div>${ubar(u.used,u.lim)}
<div class="um" style="margin-top:10px"><span class="bl">${I('up',14)}${fb(u.up)}</span><span>${I('down',14)}${fb(u.down)}</span><span>${I('cal',14)}${u.fdays?'Starts on first connection ('+u.fdays+' days)':u.exp=='never'?'No expiry':'Expires '+X(u.exp)+(dleft(u)?' · '+dleft(u):'')}</span><span>${I('dev',14)}Device limit ${u.dev||'Unlimited'}</span><span>${I('refresh',14)}${u.rday?'Monthly reset on day '+u.rday:'No monthly reset'}</span></div>
<div class="ua"><button class="btn" data-ua="edit">${I('key',15)}Edit</button><button class="btn" data-ua="share">${I('upl',15)}Share</button><button class="btn" data-ua="clone">${I('users',15)}Clone</button><button class="btn" data-ua="reset">${I('refresh',15)}Reset usage</button><button class="btn" data-ua="toggle">${I(u.st=='disabled'?'unlock':'lock',15)}${u.st=='disabled'?'Enable':'Disable'}</button><button class="btn dng" data-ua="del">${I('del',15)}Delete</button></div></div>
${u.st=='disabled'?`<div class="banner w" role="status">${I('lock',17)}<div><b>Disabled.</b> ${u.reason?'Reason shown to the user: '+X(u.reason):'No reason given.'}</div></div>`:''}${u.trial?`<div class="banner w" role="status">${I('clock',17)}<div><b>Trial account.</b> It is deleted automatically when the time or data runs out.</div></div>`:''}
${u.note?`<div class="card"><div class="lab">Note</div><div class="note2">${X(u.note)}</div></div>`:''}
${usageCard(u.hist)}
${onlineCard(u)}
<div class="card"><div class="ct"><div class="lab">Subscription link</div><button class="btn sm" data-ua="newsub">${I('refresh',14)}New link</button></div><p class="note">Import into v2rayNG, NekoBox or Hiddify. It contains all Xray configs (XHTTP TLS, TCP TLS, Trojan, Reality, XHTTP) and shows usage and expiry.</p>${cbox('Subscription',u.sub)}<a class="btn sm" href="${X(u.sub)}" target="_blank" rel="noopener" style="margin-top:10px;text-decoration:none">Open user page</a></div>
<div class="card"><div class="ct"><div class="lab">Xray configs</div><button class="btn sm" data-ua="newuuid">${I('refresh',14)}New UUID</button></div><p class="note">Tap a config to copy it. XHTTP needs a recent app (v2rayNG 1.9.30+, Hiddify, NekoBox with Xray core).</p>${u.links.map(l=>cbox(l.name,l.url)+(l.name=='VLESS XHTTP (no TLS)'&&!u.plaindomain?'<p class="note bad" style="margin-top:6px">New Xray apps refuse VLESS without TLS on an IP address. Set a domain (Settings → Server address, or a domain certificate) to use this config.</p>':'')).join('')}</div>
<div class="card"><div class="ct"><div class="lab">SSH account</div><button class="btn sm" data-cp="${cp(sshAll)}">Copy all</button></div>
${row('Host',u.addr)}${row('Username',u.name)}${row('Password',u.pw||'Unknown (set a new one with Edit)')}${row('SSH',p.SSH_PORT)}${row('SSH SSL / TLS',p.SSL_PORT)}${row('SSH WS',p.WS_PORT)}${row('SSH WS TLS',p.WSTLS_PORT)}${row('UDPGW','127.0.0.1:'+p.UDPGW_PORT)}</div>
<div class="card"><div class="lab">Xray details</div>${row('VLESS XHTTP TLS port',p.VWSTLS_PORT)}${row('VLESS TCP TLS port',p.VTCP_PORT)}${row('Trojan TLS port',p.TROJAN_PORT)}${row('VLESS Reality port',u.rport||p.REALITY_PORT)}${row('VLESS XHTTP port',p.VWS_PORT)}${row('XHTTP path',u.path)}${row('SNI (TLS configs)',u.sni||'Default')}${row('Host',u.whost)}${row('Reality target',u.rt+(u.rtarget?'':' (default)'))}${row('Reality SNI',u.rsni_u||(u.rt||'').split(':')[0])}${row('UUID / Trojan password',u.uuid)}</div>
<div class="card"><div class="lab">SSH WebSocket payloads</div><p class="note">Host ${X(u.whost)}. Use port ${p.WS_PORT} for SSH WS, or ${p.WSTLS_PORT} with TLS on for SSH WS TLS. Try them one by one.</p>${payloads(u.whost,p).map((x,i)=>cbox('Payload '+(i+1),x,false)).join('')}</div>`}
$('#dt').onclick=async e=>{if(e.target.id=='dt'||e.target.closest('#dx'))return $('#dt').hidden=true;
const q=e.target.closest('[data-qr]');if(q)return showQR(q.dataset.ql,CP[+q.dataset.qr]);
const c=e.target.closest('[data-cp]');if(c)return copy(CP[+c.dataset.cp]);
const b=e.target.closest('[data-ua]');if(!b)return;const a=b.dataset.ua,n=DT.name;
if(a=='edit')return umodal(DT);
if(a=='clone')return umodal(null,DT);
if(a=='share')return shareCard(DT);
if(a=='newsub'||a=='newuuid'){if(!confirm(a=='newsub'?'Make a new subscription link for '+n+'?\n\nThe old link stops working. Send the new link to the user.':'Make a new UUID for '+n+'?\n\nAll old Xray configs of this user stop working. The user must refresh the subscription or add the new configs.'))return;
return api('api/user/'+a,{name:n}).then(()=>{toast(a=='newsub'?'New link made':'New UUID made');openU(n)}).catch(x=>toast(x.message,1))}
if(a=='toggle'&&DT.st!='disabled')return modal('Disable '+n,[['reason','Reason (optional, shown on the user\'s page)','text','Payment pending']],d=>api('api/user/toggle',{name:n,reason:d.reason}).then(()=>{toast(n+' disabled');openU(n)}),'The user is disconnected and cannot connect until you enable them again.');
if(a=='kick'&&!confirm('Disconnect '+n+' from all devices now? They can reconnect after about a minute.'))return;
if(a=='del'&&!confirm('Delete '+n+'? Both SSH and Xray access will be removed.'))return;if(a=='reset'&&!confirm('Reset data usage of '+n+' to 0?'))return;
try{await api('api/user/'+a,{name:n});toast(a=='del'?n+' deleted':a=='kick'?n+' disconnected':'Done');if(a=='del')$('#dt').hidden=true;else openU(n);load()}catch(x){toast(x.message,1)}};
async function trial(){if(!confirm('Create a trial user? 1 day, 2 GB, 1 device. It is deleted automatically when it ends.'))return;try{const r=await api('api/trial');toast('Trial user '+r.name+' created');await load();openU(r.name)}catch(x){toast(x.message,1)}}
function csvUI(){$('#cxe').onclick=()=>{location.href='api/users.csv'};$('#cxi').onclick=()=>$('#cxf').click();
$('#cxf').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;const t=await f.text();if(!confirm('Import users from '+f.name+'? Users that already exist are skipped.'))return;
try{const r=await api('api/csv-import',{csv:t});toast('Added '+r.added+' user(s)');$('#me').innerHTML=r.errors.length?'Skipped:<br>'+r.errors.map(X).join('<br>'):'';load()}catch(x){$('#me').textContent=x.message}}}
let SH=null;
function shareText(u){const p=u.ports;return `${BR.brand||'ReXUI'} account\nUsername: ${u.name}\nPassword: ${u.pw||'-'}\nExpires: ${u.fdays?'starts on first connection ('+u.fdays+' days)':u.exp=='never'?'No expiry':u.exp}\nData: ${u.lim?u.lim+' GB':'Unlimited'}\nDevices: ${u.dev||'Unlimited'}\n\nSubscription link (v2rayNG / NekoBox / Hiddify):\n${u.sub}\n\nSSH\nHost: ${u.addr}\nSSH: ${p.SSH_PORT}  SSL: ${p.SSL_PORT}\nWS: ${p.WS_PORT}  WS TLS: ${p.WSTLS_PORT}\nUDPGW: 127.0.0.1:${p.UDPGW_PORT}`}
function shareCard(u){const W=1080,P=64,cv=document.createElement('canvas');cv.width=W;cv.height=3000;const g=cv.getContext('2d'),ac=(AC[BR.accent]||AC.blue)[1],F='system-ui,-apple-system,"Segoe UI",Roboto,sans-serif',p=u.ports;
const rr=(x,y,w,h,r,f)=>{g.beginPath();g.moveTo(x+r,y);g.arcTo(x+w,y,x+w,y+h,r);g.arcTo(x+w,y+h,x,y+h,r);g.arcTo(x,y+h,x,y,r);g.arcTo(x,y,x+w,y,r);g.closePath();g.fillStyle=f;g.fill()};
const fit=(t,max,size,w)=>{let z=size;g.font=`${w} ${z}px ${F}`;while(g.measureText(t).width>max&&z>20){z-=2;g.font=`${w} ${z}px ${F}`}if(g.measureText(t).width>max){while(t.length>3&&g.measureText(t+'…').width>max)t=t.slice(0,-1);t+='…'}return t};
g.fillStyle='#0f1420';g.fillRect(0,0,W,3000);const gr=g.createRadialGradient(W,0,0,W,0,700);gr.addColorStop(0,ac+'55');gr.addColorStop(1,'#0f142000');g.fillStyle=gr;g.fillRect(0,0,W,700);
let y=P+70;const bn=BR.brand||'ReXUI';g.font=`800 76px ${F}`;const lg=g.createLinearGradient(P,0,P+g.measureText(bn).width,0);lg.addColorStop(0,ac);lg.addColorStop(.5,'#2dd4bf');lg.addColorStop(1,'#a78bfa');g.fillStyle=lg;g.textBaseline='alphabetic';g.fillText(fit(bn,W-2*P,76,800),P,y);
if(BR.tagline){y+=50;g.fillStyle='#8b94a5';g.fillText(fit(BR.tagline,W-2*P,32,'500'),P,y)}y+=56;
const sec=(title,rows)=>{const h=40+rows.length*68+24;rr(P,y,W-2*P,h+40,28,'#171d2b');g.fillStyle='#8b94a5';g.font=`700 26px ${F}`;g.fillText(title.toUpperCase(),P+36,y+58);let yy=y+58+24;
rows.forEach((r,i)=>{yy+=68;if(i)rr(P+36,yy-68+6,W-2*P-72,2,1,'#262d3b');g.fillStyle='#8b94a5';g.font=`500 32px ${F}`;g.fillText(r[0],P+36,yy-12);const lw=g.measureText(r[0]).width;g.fillStyle=r[2]||'#e8ecf3';const v=fit(String(r[1]),W-2*P-108-lw,34,'700');g.textAlign='right';g.fillText(v,W-P-36,yy-12);g.textAlign='left'});y+=h+40+28};
sec('Account',[['Username',u.name],['Password',u.pw||'-'],['Expires',u.fdays?'First use + '+u.fdays+' days':u.exp=='never'?'No expiry':u.exp+(dleft(u)?' ('+dleft(u)+')':'')],['Data',u.lim?u.lim+' GB':'Unlimited'],['Devices',u.dev||'Unlimited']]);
const M=RXQR.make(u.sub),n=M.length,qs=600,m=Math.floor(qs/(n+8)),qw=m*(n+8),qx=(W-qw)/2;rr(P,y,W-2*P,qw+150,28,'#171d2b');rr(qx,y+36,qw,qw,20,'#fff');g.fillStyle='#000';
for(let r=0;r<n;r++)for(let c=0;c<n;c++)if(M[r][c])g.fillRect(qx+(c+4)*m,y+36+(r+4)*m,m,m);
g.fillStyle='#e8ecf3';g.font=`700 32px ${F}`;g.textAlign='center';g.fillText('Scan the subscription QR',W/2,y+qw+86);g.fillStyle='#8b94a5';g.font=`500 26px ${F}`;g.fillText('v2rayNG · NekoBox · Hiddify → Add subscription',W/2,y+qw+124);g.textAlign='left';y+=qw+150+28;
sec('SSH',[['Host',u.addr],['SSH',p.SSH_PORT],['SSL / TLS',p.SSL_PORT],['WebSocket',p.WS_PORT],['WebSocket TLS',p.WSTLS_PORT],['UDPGW','127.0.0.1:'+p.UDPGW_PORT]]);
g.font=`500 22px ui-monospace,Menlo,Consolas,monospace`;g.fillStyle='#8b94a5';let line='',lines=[];for(const ch of u.sub){if(g.measureText(line+ch).width>W-2*P){lines.push(line);line=''}line+=ch}lines.push(line);lines.forEach(l=>{g.fillText(l,P,y+10);y+=32});y+=P-10;
const out=document.createElement('canvas');out.width=W;out.height=y;out.getContext('2d').drawImage(cv,0,0);SH={u,c:out,url:out.toDataURL('image/png')};$('#shi').src=SH.url;
const can=!!(navigator.canShare&&window.File);$('#shs').hidden=!can;$('#shm').hidden=false}
$('#shm').onclick=async e=>{if(e.target.id=='shm'||e.target.closest('#shx'))return $('#shm').hidden=true;if(!SH)return;
if(e.target.closest('#shc'))return copy(shareText(SH.u));
if(e.target.closest('#shd')){const a=document.createElement('a');a.href=SH.url;a.download=SH.u.name+'.png';document.body.append(a);a.click();a.remove();return}
if(e.target.closest('#shs')){SH.c.toBlob(async b=>{const f=new File([b],SH.u.name+'.png',{type:'image/png'});try{if(navigator.canShare({files:[f]}))await navigator.share({files:[f],text:shareText(SH.u)});else await navigator.share({text:shareText(SH.u)})}catch(x){if(x.name!='AbortError')toast('Sharing is not available here, use Download',1)}},'image/png')}};
function modal(t,fields,fn,intro){const f=$('#mf');f.innerHTML=`<h2>${X(t)}</h2>${intro?`<p class="note" style="margin-top:6px">${intro}</p>`:''}`+fields.map(x=>x[2]=='check'?`<label class="ck"><input type="checkbox" id="m_${x[0]}"${x[4]?' checked':''}> ${x[1]}</label>`:`<label for="m_${x[0]}">${x[1]}</label>`+(x[2]=='area'?`<textarea id="m_${x[0]}" placeholder="${X(x[3]||'')}" style="min-height:70px;font:inherit" maxlength="500">${X(x[4]??'')}</textarea>`:x[2]=='select'?`<select id="m_${x[0]}">${x[5].map(o=>`<option value="${o[0]}"${o[0]==x[4]?' selected':''}>${X(o[1])}</option>`).join('')}</select>`:`<input id="m_${x[0]}" placeholder="${X(x[3]||'')}" value="${X(x[4]??'')}" autocomplete="off" autocapitalize="none" spellcheck="false" ${x[2]=='number'?'inputmode="decimal"':''}>`)).join('')+`<div class="err" id="me"></div><div class="mr"><button type="button" class="btn" id="mc">Cancel</button><button class="btn pri">Save</button></div>`;
$('#md').hidden=false;(f.querySelector('input,select,textarea')||{focus(){}}).focus();$('#mc').onclick=()=>$('#md').hidden=true;
f.onsubmit=async e=>{e.preventDefault();const d={};fields.forEach(x=>d[x[0]]=x[2]=='check'?$('#m_'+x[0]).checked:x[0]=='pw'||x[2]=='area'?$('#m_'+x[0]).value:$('#m_'+x[0]).value.trim());const b=f.querySelector('.pri');b.disabled=true;
try{await fn(d);$('#md').hidden=true;load()}catch(x){$('#me').textContent=x.message}b.disabled=false}}
function showQR(t,v){$('#qrt').textContent=t;try{$('#qrs').innerHTML=RXQR.svg(v,300)}catch(x){$('#qrs').innerHTML='<p class="note">'+X(x.message)+'</p>'}$('#qrm').hidden=false}
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
function tools(){tools2();const t=D.tools,sp=t.speed,pc=t.ports;if(!$('#spr'))return;$('#stm').textContent=D.stime;
$('#spr').innerHTML=sp.run?'<p class="note">Testing... this takes about 20 seconds.</p>':sp.t?(sp.err?`<p class="err">${X(sp.err)}</p>`:`<div class="tl3"><div class="tile"><b>${mbps(sp.down)}</b><small>DOWNLOAD</small></div><div class="tile"><b>${mbps(sp.up)}</b><small>UPLOAD</small></div><div class="tile"><b>${sp.ping??'-'}</b><small>PING ms</small></div></div><p class="note" style="margin-top:6px">Tested ${tago(sp.t)}</p>`):'';
$('#spb').disabled=!!sp.run;$('#pcb').disabled=!!pc.run;
$('#pcr').innerHTML=pc.run?'<p class="note">Checking... this takes about 20 seconds.</p>':pc.t?(pc.err?`<p class="err">${X(pc.err)}</p>`:'')+(pc.res||[]).map(r=>`<div class="kv"><span>${X(r.name)} · ${r.port}</span><b style="color:${r.ok==r.n&&r.n?'var(--g)':r.ok?'var(--y)':'var(--r)'}">${r.ok==r.n&&r.n?'Open':r.ok?'Partly open':'Closed'} (${r.ok}/${r.n})</b></div>`).join('')+(pc.res&&pc.res.length?`<p class="note" style="margin-top:6px">Checked ${tago(pc.t)} for ${X(pc.ip)}</p>`:''):''}
function stb(){tools();const b=$('#bkl');if(!b)return;const L=D.backups||[];b.innerHTML=L.length?`<p class="note" style="margin:12px 0 0">Automatic daily backups on the server (last 7): ${L.map(X).join(', ')}. Restore one with <b style="color:var(--t)">menu</b> → Backup / Restore.</p>`:''}
function st(){const d=D,c=d.cert,s=d.set,p=d.ports,url=`https://${c.domain||location.hostname}:${d.port}/${d.path}/`;
const kv=(k,v)=>`<div class="kv"><span>${k}</span><b>${X(v)}</b></div>`;
const ST=[['general','General'],['xray','Xray'],['telegram','Telegram'],['sub','Sub page'],['tools','Tools'],['backup','Backup'],['logs','Logs']];
$('#pg').innerHTML=`<div class="stabs" role="tablist" aria-label="Settings sections">${ST.map(t=>`<button type="button" role="tab" data-stab="${t[0]}">${t[1]}</button>`).join('')}</div><div class="sg">
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
<form class="card" id="pf"><div class="lab">${I('key',15)}Panel login</div><p class="note" style="margin-top:8px">Current username: <b style="color:var(--t)">${X(d.me)}</b></p>
<label for="po">Old password</label><input id="po" type="password" autocomplete="current-password">
<label for="pu">New username</label><input id="pu" value="${X(d.me)}" autocomplete="username" autocapitalize="none">
<label for="pn">New password</label><input id="pn" type="password" autocomplete="new-password">
<div class="err" id="pe"></div><button class="btn pri">Change login</button>
<div class="kv" style="margin-top:16px"><span>Two-factor login (2FA)</span><b class="${d.tfa?'ok':''}">${d.tfa?'On':'Off'}</b></div>
<p class="note">With 2FA on, login also asks for a 6-digit code from Google Authenticator or Aegis on your phone. Lost the phone? Run menu → 3 on the server to reset the login and turn 2FA off.</p>
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
<div class="ct" style="margin-top:12px"><b>Speed test</b><button type="button" class="btn sm" id="spb">${I('refresh',14)}Run test</button></div><p class="note">Download and upload speed of this server (Cloudflare, 4 connections, 7 seconds each). On a fast server one test can use 1-2 GB of traffic.</p><div id="spr"></div>
<div class="ct" style="margin-top:18px;border-top:1px solid var(--l);padding-top:14px"><b>Port check</b><button type="button" class="btn sm" id="pcb">${I('net',14)}Check ports</button></div><p class="note">Asks 3 servers on the internet (check-host.net) if each port can be reached from outside. A closed port is usually blocked by your provider's firewall.</p><div id="pcr"></div>
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
<div class="card" id="ppc"><div class="lab">${I('shield',15)}Panel and ports</div>${kv('URL',url)}${kv('Secret path','/'+d.path+'/')}
${[['Panel','PANEL_PORT'],['SSH','SSH_PORT'],['SSH SSL','SSL_PORT'],['SSH WS','WS_PORT'],['SSH WS TLS','WSTLS_PORT'],['UDPGW','UDPGW_PORT'],['VLESS XHTTP TLS','VWSTLS_PORT'],['VLESS TCP TLS','VTCP_PORT'],['Trojan TLS','TROJAN_PORT'],['VLESS Reality','REALITY_PORT'],['VLESS XHTTP','VWS_PORT']].map(x=>kv(x[0],p[x[1]]||'-')).join('')}
<p class="note" style="margin-top:12px">To change a port, run <b style="color:var(--t)">menu</b> on the server and open Port change.</p></div></div>`;
const TM={cf:'xray',xf:'xray',rf:'xray',fsc:'xray',rfc:'xray',pf:'general',apf:'general',pwc:'general',ppc:'general',pac:'general',af:'telegram',spf:'sub',tf:'tools',xuc:'tools',ddc:'tools',mtc:'tools',bkc:'backup',lgc:'logs'};
const stab=t=>{if(!ST.some(x=>x[0]==t))t='general';ls('rx-stab',t);document.querySelectorAll('[data-stab]').forEach(b=>{const on=b.dataset.stab==t;b.classList.toggle('on',on);b.setAttribute('aria-selected',on)});
Object.entries(TM).forEach(([id,tb])=>{const el=$('#'+id);if(el)el.classList.toggle('tabx',tb!=t)});if(t=='tools')mload();if(t=='logs')lview()};window.STAB=stab;
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
document.querySelector('.stabs').onclick=e=>{const b=e.target.closest('[data-stab]');if(b){stab(b.dataset.stab);b.scrollIntoView({block:'nearest',inline:'nearest'})}};
$('#apth').value=ls('rx-theme')||'auto';$('#apth').onchange=()=>{const v=$('#apth').value;theme(v);if(v=='auto')try{localStorage.removeItem('rx-theme')}catch(e){}else{ls('rx-theme',v);if(v!='light')ls('rx-dark',v)}};
$('#pwab').hidden=!IP;$('#pwan').innerHTML=isApp()?'You are using the app now.':location.protocol!='https:'?'':`If there is no Install button: in Chrome open the ⋮ menu and tap <b style="color:var(--t)">Add to Home screen</b>. On iPhone, open the panel in Safari, tap Share and <b style="color:var(--t)">Add to Home Screen</b>.${D.cert.src=='self-signed'?' The app works best with your own domain certificate.':''}`;
$('#pwab').onclick=async()=>{if(!IP)return;IP.prompt();await IP.userChoice.catch(()=>{});IP=null;$('#pwab').hidden=true};
$('#clb').onclick=async()=>{const b=$('#clb');b.disabled=true;try{const r=await api('api/cleanup');toast('Freed '+fb(r.freed));mload()}catch(x){$('#mte').textContent=x.message}b.disabled=false};
$('#clx').onchange=()=>api('api/autoclean',{autoclean:$('#clx').checked}).then(()=>toast('Saved')).catch(x=>toast(x.message,1));
$('#swb').onclick=async()=>{const g=$('#swg').value;if(!confirm('Create a '+g+' GB swap file? This takes up to a minute.'))return;const b=$('#swb');b.disabled=true;b.textContent='Working...';try{await api('api/swap',{gb:+g});toast('Swap is on');$('#mte').textContent=''}catch(x){$('#mte').textContent=x.message}b.disabled=false;b.textContent='Create swap';mload()};
$('#swr').onclick=async()=>{if(!confirm('Remove the swap file?'))return;try{await api('api/swap',{gb:0});toast('Swap removed');$('#mte').textContent=''}catch(x){$('#mte').textContent=x.message}mload()};
stab(ls('rx-stab')||'general');
stb();$('#rsf').onchange=async e=>{const f=e.target.files[0];e.target.value='';if(!f)return;$('#rse').textContent='';let o;
try{o=JSON.parse(await f.text())}catch(x){return $('#rse').textContent='This file is not valid JSON'}
if(!confirm('Restore '+(o.users||[]).length+' users from '+f.name+'?'))return;
try{const r=await api('api/restore',o);toast('Restored '+r.users+' users'+(r.cert?' and the certificate':''));load()}catch(x){$('#rse').textContent=x.message}};
$('#cf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri'),t=b.querySelector('span');b.disabled=true;t.textContent='Checking...';
try{const r=await api('api/cert',{crt:$('#cc').value,key:$('#ck').value});const dm=r.cert.domain;toast('Certificate saved. Panel is restarting...');
setTimeout(()=>location.href=`https://${dm||location.hostname}:${location.port}${location.pathname}`,6000)}catch(x){$('#ce').textContent=x.message}b.disabled=false;t.textContent='Save certificate'};
$('#xf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;try{await api('api/settings',{addr:$('#xa').value,sni:$('#xs2').value,host:$('#xh').value,path:$('#xp').value,rsni:$('#xr').value});$('#xe').textContent='';toast('Saved. Users need to refresh their subscription.');await load();st()}catch(x){$('#xe').textContent=x.message}b.disabled=false};
$('#rw').value=s.warp;let APA=s.accent;
$('#apf').querySelector('.sw').onclick=e=>{const b=e.target.closest('[data-ac]');if(!b)return;APA=b.dataset.ac;accent(APA);$('#apf').querySelectorAll('[data-ac]').forEach(x=>{const on=x.dataset.ac==APA;x.setAttribute('aria-checked',on);x.innerHTML=on?I('check',16):''})};
$('#apf').onsubmit=async e=>{e.preventDefault();try{await api('api/appearance',{brand:$('#apb').value,tagline:$('#apt').value,accent:APA});$('#ape').textContent='';toast('Appearance saved');await load()}catch(x){$('#ape').textContent=x.message}};
$('#rf').onsubmit=async e=>{e.preventDefault();const b=e.target.querySelector('.pri');b.disabled=true;b.textContent='Saving...';
try{await api('api/routing',{b25:$('#rb25').checked,btorrent:$('#rbt').checked,bads:$('#rba').checked,warp:$('#rw').value,wsites:$('#rs').value});$('#re').textContent='';toast('Routing saved');await load();st()}catch(x){$('#re').textContent=x.message}b.disabled=false;b.textContent='Save'};
if($('#wr'))$('#wr').onclick=async()=>{if(!confirm('Remove the WARP account and turn WARP off?'))return;try{await api('api/warp-reset');toast('WARP removed');await load();st()}catch(x){$('#re').textContent=x.message}};
const ab=()=>({autodel:$('#ad').value,tgtoken:$('#at').value,tgchat:$('#ac').value,health:$('#ah').checked,report:$('#ar').checked,rhour:$('#arh').value,tgbackup:$('#abk').checked});
$('#afb').onclick=async()=>{const b=$('#afb');b.disabled=true;try{await api('api/tg-backup');$('#ae').textContent='';toast('Backup sent to Telegram')}catch(x){$('#ae').textContent=x.message}b.disabled=false};
const snp=()=>{const f=$('#sf').value.toUpperCase(),fl=/^[A-Z]{2}$/.test(f)?[...f].map(c=>String.fromCodePoint(0x1F1E6+c.charCodeAt(0)-65)).join(''):'';$('#snp').textContent=($('#sn').value||'{user}-{proto}').replace(/\{flag\}/g,fl).replace(/\{brand\}/g,BR.brand||'ReXUI').replace(/\{user\}/g,'ali').replace(/\{proto\}/g,'reality').replace(/\{type\}/g,'VLESS Reality').replace(/\s+/g,' ').trim()};
$('#sn').oninput=$('#sf').oninput=snp;snp();
$('#spf').onsubmit=async e=>{e.preventDefault();try{await api('api/subpage',{announce:$('#sa').value,cname:$('#sn').value,flag:$('#sf').value});$('#spe').textContent='';toast('Saved')}catch(x){$('#spe').textContent=x.message}};
$('#rbm').value=s.reboot;const rbv=()=>{$('#rbd').hidden=$('#rbm').value!='weekly';$('#rbt').disabled=$('#rbm').value=='off'};$('#rbm').onchange=rbv;rbv();
$('#tf').onsubmit=async e=>{e.preventDefault();try{await api('api/reboot',{reboot:$('#rbm').value,rbday:$('#rbd').value,rbtime:$('#rbt').value});$('#tfe').textContent='';toast('Schedule saved')}catch(x){$('#tfe').textContent=x.message}};
$('#spb').onclick=()=>api('api/speedtest').then(()=>{toast('Speed test started');load()}).catch(x=>toast(x.message,1));
$('#pcb').onclick=()=>api('api/portcheck').then(()=>{toast('Port check started');load()}).catch(x=>toast(x.message,1));
$('#af').onsubmit=async e=>{e.preventDefault();try{await api('api/automation',ab());$('#ae').textContent='';toast('Saved');await load();st()}catch(x){$('#ae').textContent=x.message}};
$('#afc').onclick=async()=>{try{const r=await api('api/tg-chat',ab());$('#ac').value=r.chat;$('#ae').textContent='';toast('Chat ID found, now tap Save')}catch(x){$('#ae').textContent=x.message}};
$('#aft').onclick=async()=>{try{await api('api/tg-test',ab());$('#ae').textContent='';toast('Test message sent')}catch(x){$('#ae').textContent=x.message}};
$('#rk').onclick=async()=>{if(!confirm('Create new Reality keys? Every user must refresh their subscription, old Reality configs stop working.'))return;try{await api('api/reality-keys');toast('New Reality keys created');await load();st()}catch(x){$('#xe').textContent=x.message}};
$('#tfa').onclick=async()=>{if(D.tfa)return modal('Turn off 2FA',[['code','Current 6-digit code','number','']],d=>api('api/2fa/disable',d).then(()=>{toast('2FA is off');return load().then(st)}));
let r;try{r=await api('api/2fa/setup')}catch(x){return toast(x.message,1)}
modal('Turn on 2FA',[['code','Enter the 6-digit code shown in the app','number','']],d=>api('api/2fa/enable',d).then(()=>{toast('2FA is on');return load().then(st)}),
`1. Open Google Authenticator or Aegis and scan this QR.<span style="display:block;background:#fff;border-radius:10px;padding:8px;margin:10px auto;max-width:220px">${RXQR.svg(r.uri,200)}</span>Or type this key: <b style="color:var(--t);word-break:break-all">${X(r.secret)}</b><br>2. Enter the code from the app below.`)};
$('#pf').onsubmit=async e=>{e.preventDefault();try{await api('api/login-change',{old:$('#po').value,u:$('#pu').value,p:$('#pn').value});toast('Login changed, please log in again');show(false)}catch(x){$('#pe').textContent=x.message}}}
let CAPID='';const capShow=c=>{CAPID=c.id;$('#capi').src=c.img;$('#lcap').value='';$('#capw').hidden=false};
$('#capr').innerHTML=I('refresh',17);$('#capr').onclick=()=>fetch('api/captcha',{cache:'no-store'}).then(r=>r.json()).then(capShow).catch(()=>{});
$('#lf').onsubmit=async e=>{e.preventDefault();const r=await fetch('api/login',{method:'POST',headers:{'X-Req':'1','Content-Type':'application/json'},body:JSON.stringify({u:$('#lu').value.trim(),p:$('#lp').value,code:$('#lc').value,cid:CAPID,cap:$('#lcap').value})});const j=await r.json().catch(()=>({}));
if(r.ok){$('#lp').value='';$('#lc').value='';$('#lcw').hidden=true;$('#capw').hidden=true;CAPID='';$('#le').textContent='';return load()}
if(j.captcha)capShow(j.captcha);if(j.needcap&&!j.need2fa){$('#le').textContent=j.e;$('#lcap').focus();return}
if(j.need2fa){const first=$('#lcw').hidden;$('#lcw').hidden=false;$('#lc').focus();$('#le').textContent=first?'':j.e;return}$('#le').textContent=j.e||'Error '+r.status};
load();setInterval(()=>{if(!document.hidden&&!$('#app').hidden)load()},3000);
const SXS=[['Overview','page','ov','dashboard graphs cpu ram speed traffic top users protocol'],['Users','page','us','users list'],['Online','page','on','online connected kick ip'],['Security','page','sc','sessions devices login history activity log'],['Settings','page','st','settings'],
['SSL certificate','set','xray cf','cert certificate domain lets encrypt tls'],['Xray defaults (SNI, host, path, Reality)','set','xray xf','sni host path reality xhttp keys'],['Routing (torrent, ads, WARP, port 25)','set','xray rf','routing block torrent ads warp smtp port 25'],
['Fake website','set','xray fsc','fake website decoy camouflage port 80'],['Reality target finder','set','xray rfc','reality target sni finder best'],['Panel login and 2FA','set','general pf','password username login 2fa two factor'],
['Appearance (brand, colour, theme)','set','general apf','brand logo colour color accent theme dark black amoled tagline'],['Phone app','set','general pwc','pwa install app home screen'],['Panel and ports','set','general ppc','ports url'],
['Panel address (secret path)','set','general pac','path url secret address change'],['Telegram and alerts','set','telegram af','telegram bot alerts report backup auto delete health'],['Subscription page and config names','set','sub spf','announcement config name flag sub page'],
['Speed test, port check, reboot','set','tools tf','speed test speedtest port check reboot schedule'],['Xray core update','set','tools xuc','xray update version core'],['DuckDNS','set','tools ddc','duckdns ddns domain ip'],
['Disk cleanup and swap','set','tools mtc','cleanup clean disk swap memory'],['Backup and restore','set','backup bkc','backup restore'],['Server logs','set','logs lgc','logs journal errors access'],
['Add user','act','add','new create user'],['Trial user','act','trial','trial test'],['Bulk actions and CSV','act','bulk','bulk csv export import']];
let SXL=[],SXA=0;
function sxOpen(){if($('#app').hidden)return;$('#sxo').hidden=false;$('#sxi').value='';sxRun();setTimeout(()=>$('#sxi').focus(),10)}
function sxRun(){const q=$('#sxi').value.trim().toLowerCase(),w=q.split(/\s+/).filter(Boolean),m=t=>w.every(x=>t.includes(x));
const us=q&&D?D.users.filter(u=>m((u.name+' '+(u.note||'')).toLowerCase())).slice(0,8).map(u=>({k:'user',n:u.name,l:u.name,sub:STN[u.st]})):[];
const it=SXS.filter(x=>q?m((x[0]+' '+x[3]).toLowerCase()):x[1]!='set').map(x=>({k:x[1],t:x[2],l:x[0],sub:x[1]=='set'?'Settings':x[1]=='act'?'Action':'Page'}));
SXL=[...us,...it];SXA=0;const grp=(h,a)=>a.length?`<div class="sxh">${h}</div>`+a.map(o=>{const i=SXL.indexOf(o);return `<button type="button" class="sxi${i==0?' on':''}" data-sx="${i}" role="option">${o.k=='user'?av(o.n):I(o.k=='set'?'gear':o.k=='act'?'plus':'panel',16)}<span>${X(o.l)}</span><small>${X(o.sub)}</small></button>`}).join(''):'';
$('#sxr').innerHTML=SXL.length?grp('Users',us)+grp(q?'Settings and pages':'Go to',it):'<p class="note" style="padding:10px">Nothing found</p>'}
function sxGo(i){const o=SXL[i];if(!o)return;$('#sxo').hidden=true;
if(o.k=='user'){go('us');return openU(o.n)}if(o.k=='page')return go(o.t);
if(o.k=='act'){go('us');return o.t=='add'?umodal():o.t=='trial'?trial():bulkm()}
const [tb,id]=o.t.split(' ');go('st');if(window.STAB)STAB(tb);const el=$('#'+id);if(el){el.scrollIntoView({block:'start',behavior:'smooth'});el.style.boxShadow='0 0 0 2px var(--a)';setTimeout(()=>el.style.boxShadow='',1800)}}
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
.pwf{margin-top:8px}.pwf label{display:block;font-size:13px;color:var(--m);font-weight:600;margin:10px 0 5px}.pwf input[type=password],.pwf input[type=text]{width:100%;font:inherit;color:var(--t);background:var(--c2);border:1px solid var(--l);border-radius:8px;padding:9px 11px}
.pwf input:focus-visible{outline:2px solid var(--a);outline-offset:1px}.pwf .shw{display:flex;align-items:center;gap:8px;font-weight:500}.pwf .pri{margin-top:6px;background:var(--a);color:#fff;border-color:var(--a)}
.tg{font-size:13.5px;color:var(--m);margin:-8px 0 14px}
</style><style id="acs"></style></head><body>
<div class="w" id="app"></div><p style="text-align:center;font-size:12px;color:var(--m);margin:0 0 30px">Powered by <a href="https://github.com/chaliraza777/ReXUI" target="_blank" rel="noopener" style="color:var(--m)">ReXUI</a></p>
<div id="qrm" hidden><div class="card"><div class="cbh"><b id="qrt"></b><button class="btn" id="qrx">Close</button></div><div class="qr" id="qrs"></div></div></div>
<script src="/qr.js"></script>
<script>
const U=__DATA__;
const X=s=>String(s??'').replace(/[&<>"']/g,c=>'&#'+c.charCodeAt(0)+';');
const fb=b=>{const u=['B','KB','MB','GB','TB'];let i=0;b=+b||0;while(b>=1024&&i<4){b/=1024;i++}return (i?b.toFixed(2):b.toFixed(0))+' '+u[i]};
const SC={active:'var(--a)',online:'var(--g)',expired:'var(--r)',limit:'var(--r)',disabled:'var(--y)'},SN={active:'Active',online:'Active',expired:'Expired',limit:'Data limit reached',disabled:'Disabled'};
const CP=[];const cp=t=>{CP.push(t);return CP.length-1};
const cbox=(l,v,qr=true)=>{const i=cp(v);return `<div class="cb"><div class="cbh"><small>${X(l)}</small><span style="display:flex;gap:6px">${qr?`<button class="btn" data-qr="${i}" data-ql="${X(l)}">QR</button>`:''}<button class="btn" data-cp="${i}">Copy</button></span></div><button class="code" data-cp="${i}" aria-label="Copy ${X(l)}">${X(v)}</button></div>`};
const row=(k,v)=>`<div class="row"><span>${k}</span><b>${X(v)}</b></div>`;
const p=U.ports,h=U.whost,pct=U.lim?Math.min(100,U.used/(U.lim*1073741824)*100):0;
let left='No expiry';if(U.fdays)left=`Starts when you first connect (${U.fdays} day${U.fdays==1?'':'s'})`;else if(U.expts){const h=Math.ceil((U.expts*1000-Date.now())/36e5);left=h>0?`${U.exp} (${h} hour${h==1?'':'s'} left)`:`${U.exp} (expired)`}else if(U.exp!='never'){const d=Math.ceil((new Date(U.exp+'T23:59:59')-new Date())/864e5);left=d>=0?`${U.exp} (${d} day${d==1?'':'s'} left)`:`${U.exp} (expired)`}
const pl=[`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Connection: Upgrade[crlf]Upgrade: websocket[crlf][crlf]`,`GET / HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf]User-Agent: Mozilla/5.0[crlf][crlf]`,`GET http://${h}/ HTTP/1.1[crlf]Host: ${h}[crlf]Upgrade: websocket[crlf][crlf]`,`CONNECT ${h}:${p.WS_PORT} HTTP/1.1[crlf]Host: ${h}[crlf][crlf]`];
const AC={blue:['#1f6feb','#4c8dff'],teal:['#0d9488','#2dd4bf'],green:['#15803d','#4ade80'],purple:['#7c3aed','#a78bfa'],pink:['#db2777','#f472b6'],orange:['#ea580c','#fb923c'],indigo:['#4f46e5','#818cf8']},ac=AC[U.accent]||AC.blue;
document.getElementById('acs').textContent=`:root{--a:${ac[0]}}@media(prefers-color-scheme:dark){:root{--a:${ac[1]}}}`;if(U.brand)document.title=U.brand+' · My account';
const dl=U.fdays||U.exp=='never'?1e9:U.expts?(U.expts*1000-Date.now())/864e5:Math.ceil((new Date(U.exp+'T23:59:59')-new Date())/864e5),soon=['active','online'].includes(U.st)&&(dl<=3||(U.lim&&pct>=90));
const soonTxt=soon?(dl<=3?(dl<1?'Your account expires today.':`Your account expires in ${Math.ceil(dl)} day${Math.ceil(dl)==1?'':'s'}.`):'')+(U.lim&&pct>=90?` You have used ${pct.toFixed(0)}% of your data.`:'')+' Contact your provider to renew.':'';
const H=U.hist||[],HM=Math.max(1,...H.map(x=>x[1]+x[2]));
document.getElementById('app').innerHTML=`<div class="top"><b>My account</b><b class="logo" aria-label="${X(U.brand||'ReXUI')}">${U.brand?`<span>${X(U.brand)}</span>`:'<span>Re</span><i>X</i><span>UI</span>'}</b></div>${U.tagline?`<p class="tg">${X(U.tagline)}</p>`:''}${U.announce?`<div class="ann" role="note"><b>Announcement</b>${X(U.announce)}</div>`:''}${soon?`<div class="warn"><b>Renew soon.</b> ${X(soonTxt.trim())}</div>`:''}${U.st=='disabled'?`<div class="warn"><b>Your account is paused.</b>${U.reason?' '+X(U.reason):' Please contact your provider.'}</div>`:U.st=='expired'?'<div class="warn"><b>Your account has expired.</b> Please contact your provider to renew it.</div>':U.st=='limit'?'<div class="warn"><b>You have used all your data.</b> Please contact your provider.</div>':''}
<div class="card"><div class="hd"><b>${X(U.name)}</b><span class="pill" style="color:${SC[U.st]}">${SN[U.st]}</span></div>
<div class="big">${fb(U.used)} <span>of ${U.lim?U.lim+' GB':'unlimited'}</span></div>${U.lim?`<div class="bar"><i style="width:${pct}%;background:${pct>90?'var(--r)':pct>75?'var(--y)':'var(--a)'}"></i></div>`:''}
${row('Upload',fb(U.up))}${row('Download',fb(U.down))}${row('Expires',left)}${row('Devices allowed',U.dev||'Unlimited')}</div>
${H.length?`<div class="card"><div class="lab">Daily usage (30 days)</div><div class="uch" role="img" aria-label="Daily data usage">${H.map(x=>`<i title="${x[0]}: ${fb(x[1]+x[2])}"><b style="height:${(x[1]/HM*100).toFixed(1)}%"></b><u style="height:${(x[2]/HM*100).toFixed(1)}%"></u></i>`).join('')}</div><div class="uax"><span>${H[0][0].slice(5)}</span><span>Today ${fb(H[H.length-1][1]+H[H.length-1][2])}</span></div></div>`:''}
<div class="card"><div class="lab">Subscription</div><p class="note">Add this link in v2rayNG, NekoBox or Hiddify (Subscription → Add). The app updates your configs automatically.</p>${cbox('Subscription link',U.sub,false)}<div class="qr">${RXQR.svg(U.sub,260)}</div></div>
<div class="card"><div class="lab">Get the app</div><p class="note">Install one of these apps, then add the subscription link above.</p><div class="apps">
<a href="https://github.com/2dust/v2rayNG/releases/latest" target="_blank" rel="noopener">v2rayNG<small>Android</small></a><a href="https://github.com/MatsuriDayo/NekoBoxForAndroid/releases/latest" target="_blank" rel="noopener">NekoBox<small>Android</small></a><a href="https://github.com/hiddify/hiddify-app/releases/latest" target="_blank" rel="noopener">Hiddify<small>Android · iPhone · PC</small></a></div>
<a class="wide" href="hiddify://import/${encodeURI(U.sub)}#${encodeURIComponent(U.brand||'ReXUI')}">Already have Hiddify? Tap to add your subscription</a></div>
<div class="card"><div class="lab">Configs</div><p class="note">Or add one config at a time. Tap to copy, or show the QR.</p>${U.links.map(l=>cbox(l.name,l.url)+(l.name=='VLESS XHTTP (no TLS)'&&!U.plaindomain?'<p class="note bad">This one may not work in new apps without a domain.</p>':'')).join('')}</div>
<div class="card"><div class="lab">SSH account</div>${row('Host',U.addr)}${row('Username',U.name)}${row('Password',U.pw||'Ask your provider')}${row('SSH',p.SSH_PORT)}${row('SSH SSL / TLS',p.SSL_PORT)}${row('SSH WebSocket',p.WS_PORT)}${row('SSH WebSocket TLS',p.WSTLS_PORT)}${row('UDPGW','127.0.0.1:'+p.UDPGW_PORT)}
<details style="margin-top:12px"><summary>WebSocket payloads</summary>${pl.map((x,i)=>cbox('Payload '+(i+1),x,false)).join('')}</details>
${U.pw?`<details style="margin-top:6px"><summary>Change password</summary><form id="pwf" class="pwf"><p class="note">This changes your SSH password. Your V2Ray configs and subscription link stay the same. If you forgot your current password, ask your provider.</p>
<label for="po">Current password</label><input id="po" type="password" autocomplete="current-password" required>
<label for="pn">New password</label><input id="pn" type="password" autocomplete="new-password" required>
<label for="pc">New password again</label><input id="pc" type="password" autocomplete="new-password" required>
<label class="shw"><input type="checkbox" id="ps"> Show passwords</label><p class="note bad" id="pe" role="alert"></p><button class="btn pri">Change password</button></form></details>`:''}</div>`;
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
G='\033[1;32m'; Y='\033[1;33m'; C='\033[1;36m'; N='\033[0m'
. $CF
myip(){ curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}'; }
url(){ local H; H=$(myip); if [ -f /etc/tunnel/cert/info ]; then NAME=; . /etc/tunnel/cert/info; [[ $NAME =~ [a-z] && $NAME != \** ]] && H=$NAME; fi; echo "https://$H:$PANEL_PORT/$WEB_PATH/"; }
on(){ systemctl is-active --quiet "$1" && echo -e "${G}ON${N}" || echo -e "${Y}OFF${N}"; }
fw(){ if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then ufw allow "$1"/tcp >/dev/null; fi; }
info(){
  . $CF; echo
  echo -e "Panel URL  : ${C}$(url)${N}"
  echo    "Panel user : $(python3 $PY user)  (password is stored as a hash, use option 3 to set a new one)"
  echo -e "Services   : Panel $(on tunnel-panel) | Xray $(on xray) | stunnel $(on stunnel4) | WS $(on ws-ssh) | UDPGW $(on badudp)"
  R=$(timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$WS_PORT; printf 'GET / HTTP/1.1\\r\\nHost: x\\r\\nUpgrade: websocket\\r\\n\\r\\n' >&3; head -c 12 <&3" 2>/dev/null)
  if [ "$R" = "HTTP/1.1 101" ]; then echo -e "SSH WS test : ${G}OK on this server${N} (if phones still cannot connect to $WS_PORT, open it in your provider firewall)"; else echo -e "SSH WS test : ${Y}FAILED${N} (try: systemctl restart ws-ssh)"; fi
  printf "%-14s: %s\n" "SSH" $SSH_PORT "SSL" $SSL_PORT "SSH WS" $WS_PORT "SSH WS TLS" $WSTLS_PORT "UDPGW" "127.0.0.1:$UDPGW_PORT" \
    "VLESS XHTTP TLS" $VWSTLS_PORT "VLESS TCP TLS" $VTCP_PORT "Trojan TLS" ${TROJAN_PORT:-2096} "VLESS Reality" ${REALITY_PORT:-8444} "VLESS XHTTP" $VWS_PORT "Panel" $PANEL_PORT
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
accept = $SSL_PORT
connect = 127.0.0.1:$SSH_PORT
[ssh-ws-tls]
accept = $WSTLS_PORT
connect = 127.0.0.1:$WS_PORT
S
  sed -i "s|^ExecStart=.*|ExecStart=/usr/bin/python3 /usr/local/bin/ws-ssh.py $WS_PORT $SSH_PORT|" /etc/systemd/system/ws-ssh.service
  systemctl daemon-reload
  systemctl restart stunnel4 ws-ssh tunnel-panel
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
5) VLESS XHTTP TLS : $VWSTLS_PORT
6) VLESS TCP TLS   : $VTCP_PORT
7) VLESS XHTTP     : $VWS_PORT
8) VLESS Reality   : $REALITY_PORT
9) Trojan TLS      : $TROJAN_PORT
0) Back
T
    read -rp "Option: " o
    case $o in 1) K=PANEL_PORT;; 2) K=SSL_PORT;; 3) K=WS_PORT;; 4) K=WSTLS_PORT;; 5) K=VWSTLS_PORT;; 6) K=VTCP_PORT;; 7) K=VWS_PORT;; 8) K=REALITY_PORT;; 9) K=TROJAN_PORT;; *) return;; esac
    cur=${!K}; read -rp "New port [$cur]: " np
    [ -z "$np" ] || [ "$np" = "$cur" ] && { echo "No change"; continue; }
    if ! [[ $np =~ ^[0-9]+$ ]] || [ "$np" -lt 1 ] || [ "$np" -gt 65535 ]; then echo "Invalid port"; continue; fi
    if grep -E "^[A-Z_]*PORT=$np$" $CF | grep -qv "^$K="; then echo "Port $np is already used by another protocol"; continue; fi
    [ "$np" = 22 ] || [ "$np" = 10085 ] && { echo "Port $np is reserved"; continue; }
    if ss -tlnH "sport = :$np" | grep -q .; then echo "Port $np is in use:"; ss -tlnp "sport = :$np"; continue; fi
    if grep -q "^$K=" $CF; then sed -i "s/^$K=.*/$K=$np/" $CF; else echo "$K=$np" >> $CF; fi; fw "$np"; apply
    echo -e "${G}Done:${N} $K = $np. Allow port $np in your provider firewall."
    [ "$K" = PANEL_PORT ] && echo "New panel URL: $(url)"
    [[ $K == V* || $K == REALITY_PORT || $K == TROJAN_PORT ]] && echo "Xray links changed: users need to refresh their subscription."
  done
}
srv(){
  cat <<T

===== SERVICE RESTART =====
1) Sab   2) SSH   3) stunnel4 (SSL + WS TLS)   4) SSH WS
5) UDPGW   6) Xray   7) Panel   8) Fail2ban   0) Back
T
  read -rp "Option: " o
  case $o in
    1) systemctl restart ssh 2>/dev/null || systemctl restart sshd; systemctl restart stunnel4 ws-ssh badudp xray tunnel-panel fail2ban;;
    2) systemctl restart ssh 2>/dev/null || systemctl restart sshd;;
    3) systemctl restart stunnel4;; 4) systemctl restart ws-ssh;; 5) systemctl restart badudp;;
    6) systemctl restart xray;; 7) systemctl restart tunnel-panel;; 8) systemctl restart fail2ban;;
    *) return;;
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
  if curl -fsSL -o $d/x.zip "https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$A.zip" && unzip -qo $d/x.zip xray geoip.dat geosite.dat -d $d; then xswap $d
  else echo "Download failed, nothing was changed"; fi
  rm -rf $d
}
gupd(){
  local d; d=$(mktemp -d); echo "Downloading the latest geo files..."
  if curl -fsSL -o $d/geosite.dat https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat \
     && curl -fsSL -o $d/geoip.dat https://github.com/v2fly/geoip/releases/latest/download/geoip.dat \
     && [ $(stat -c %s $d/geosite.dat) -gt 100000 ] && [ $(stat -c %s $d/geoip.dat) -gt 100000 ]; then xswap $d
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
  case $o in 1) upd;; 2) xupd;; 3) gupd;; 4) xback;; esac
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
uninst(){
  echo -e "${Y}This removes the panel, Xray, the SSH WS/SSL tunnels and all panel users.${N}"
  read -rp "Type yes to confirm: " y; [ "$y" = yes ] || { echo "Cancelled"; return; }
  f=/root/rexui-backup-before-uninstall-$(date +%F-%H%M).json
  python3 $PY backup "$f" >/dev/null 2>&1 && chmod 600 "$f" && echo "A final backup was saved to $f"
  systemctl disable --now tunnel-panel xray ws-ssh badudp stunnel4 >/dev/null 2>&1
  python3 $PY purge 2>/dev/null
  rm -f /etc/systemd/system/{tunnel-panel,xray,ws-ssh,badudp}.service /etc/stunnel/stunnel.conf /etc/cron.d/tunnel-expire
  rm -f /etc/cron.d/rexui-reboot; rm -rf /opt/tunnel-panel /usr/local/etc/xray /usr/local/bin/xray /usr/local/bin/ws-ssh.py /usr/local/bin/badvpn-udpgw /usr/local/bin/geoip.dat /usr/local/bin/geosite.dat /etc/tunnel /etc/tunnel-users /var/log/xray $LIB
  systemctl daemon-reload
  rm -f /usr/local/bin/menu
  echo -e "${G}Uninstalled.${N} SSH (port 22), BBR and fail2ban were kept."
  exit 0
}
while true; do
  cat <<T

===== ReXUI v1.0 MENU =====
   github.com/chaliraza777/ReXUI
1) Uninstall
2) Panel info
3) Panel login reset (also turns off 2FA)
4) Panel restart
5) Port change (panel + protocols)
6) Service restart
7) SSL certificate (your domain)
8) Backup / Restore
9) Update
0) Exit
T
  read -rp "Option: " o
  case $o in
    1) uninst;;
    2) info;;
    3) read -rp "New username: " u; read -rsp "New password: " p; echo
       python3 $PY setlogin "$u" "$p" && systemctl restart tunnel-panel && echo -e "${G}Login changed${N}";;
    4) systemctl restart tunnel-panel && echo -e "${G}Panel restarted${N}";;
    5) ports;;
    6) srv;;
    7) $LIB/cert.sh;;
    8) bkp;;
    9) updm;;
    0) exit 0;;
  esac
done
MAINM
chmod +x $LIB/*.sh /usr/local/bin/menu
rm -f $LIB/ssh.sh $LIB/v2ray.sh $LIB/payloads.sh $LIB/panel.sh /etc/cron.d/tunnel-expire

step 11 "Services start + firewall"
systemctl daemon-reload
systemctl enable badudp ws-ssh xray tunnel-panel >/dev/null 2>&1
systemctl restart badudp ws-ssh stunnel4 tunnel-panel
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  for p in $SSH_PORT $SSL_PORT $WS_PORT $WSTLS_PORT $PANEL_PORT $VWSTLS_PORT $VTCP_PORT $VWS_PORT $REALITY_PORT $TROJAN_PORT 80; do ufw allow $p/tcp >/dev/null; done
fi
sleep 6
R=$(timeout 4 bash -c "exec 3<>/dev/tcp/127.0.0.1/$WS_PORT; printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' >&3; head -c 12 <&3" 2>/dev/null || true)
PH=$(curl -4 -s --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')
if [ -f /etc/tunnel/cert/info ]; then NAME=; . /etc/tunnel/cert/info; [[ $NAME =~ [a-z] && $NAME != \** ]] && PH=$NAME; fi
echo -e "\n\033[1;32m==============================\033[0m"
for s in ssh stunnel4 ws-ssh badudp xray fail2ban tunnel-panel; do
  x=$(systemctl is-active $s 2>/dev/null || true); [ $s = ssh ] && [ "$x" != active ] && x=$(systemctl is-active sshd 2>/dev/null || true); printf "%-12s: %s\n" $s "$x"
done
echo "SSH $SSH_PORT | SSL $SSL_PORT | WS $WS_PORT | WS TLS $WSTLS_PORT | UDPGW 127.0.0.1:$UDPGW_PORT"
echo "VLESS XHTTP TLS $VWSTLS_PORT | VLESS TCP TLS $VTCP_PORT | Trojan $TROJAN_PORT | Reality $REALITY_PORT | VLESS XHTTP $VWS_PORT"
echo "WS test   : ${R:-fail}"
echo "Panel     : https://$PH:$PANEL_PORT/$WEB_PATH/"
if [ -n "$NEWPASS" ]; then echo "Login     : admin / $NEWPASS  (save this now)"; else echo "Login     : unchanged (change it with menu -> 3)"; fi
echo "Menu      : menu"
echo "Project   : https://github.com/chaliraza777/ReXUI"
echo "Allow these ports in your provider firewall: $SSL_PORT $WS_PORT $WSTLS_PORT $VWSTLS_PORT $VTCP_PORT $VWS_PORT $REALITY_PORT $TROJAN_PORT $PANEL_PORT 80"
echo -e "\033[1;32m==============================\033[0m"
