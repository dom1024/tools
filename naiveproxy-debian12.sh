#!/bin/bash
# Debian 12 amd64 only. No remote shell scripts, source builds, or automatic upgrades.
# Release provenance: https://github.com/klzgrad/forwardproxy/releases/tag/v2.11.7-naive2
# Run a saved, reviewed copy: sudo bash naiveproxy-debian12.sh install
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

readonly VERSION='v2.11.7-naive2'
readonly ARCHIVE_SHA='c273dc07dd79c5919f97639cbdcb559d40ce90475dbd8aac80641b0a8c8065ff'
readonly BINARY_SHA='ee571de2ed6d68dd29c1f83e5dbc62d043982c65d73ea230b78389253743527c'
readonly DOWNLOAD="https://github.com/klzgrad/forwardproxy/releases/download/${VERSION}/caddy-forwardproxy-naive.tar.xz"
readonly ACCOUNT='naiveproxy'
readonly APP='/opt/naiveproxy'
readonly CONF='/etc/naiveproxy'
readonly DATA='/var/lib/naiveproxy'
readonly UNIT='/etc/systemd/system/naiveproxy.service'
readonly SERVICE='naiveproxy.service'
readonly MARKER='naiveproxy-debian12-v1'
DOMAIN='' EMAIL='' PUBLIC_IP='' YES=0 PURGE=0
WORK='' TRANSACTION=0 COMMITTED=0 NEW_ACCOUNT=0 NEW_GROUP=0 NEW_UNIT=0
NEW_APP=0 NEW_CONF=0 NEW_DATA=0

say() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'HELP'
用法：
  sudo bash naiveproxy-debian12.sh install
  sudo bash naiveproxy-debian12.sh install --domain proxy.example.com --email you@example.com --yes
  sudo bash naiveproxy-debian12.sh status
  sudo bash naiveproxy-debian12.sh check
  sudo bash naiveproxy-debian12.sh credentials
  sudo bash naiveproxy-debian12.sh uninstall
  sudo bash naiveproxy-debian12.sh uninstall --purge --yes

install       安装；已安装时不覆盖；卸载保留的数据可以原样恢复。
status        只读查看服务状态。
check         检查本机 TLS、静态首页及认证代理连通性，不输出密码。
credentials   明确打印客户端配置及 URI（含密码，请勿公开输出）。
uninstall     停止、取消自启并移除服务文件，保留程序、证书和凭据。
--purge       仅搭配 uninstall，永久删除本脚本的三个专用目录和专用账户。
--public-ip   仅搭配 install，手动指定 VPS 公网 IPv4，替代外部 IP 查询。
--yes         跳过最终确认；非交互安装须同时提供 --domain 和 --email。

要求：原生 Debian 12 amd64、systemd、独享 TCP 80/443、公网 IPv4。
域名所有 A 记录必须指向本机；AAAA 如存在必须属于本机全局 IPv6。
请预先放行 TCP 80/443，并将域名设为 DNS-only。脚本不修改防火墙或 SSH。
HELP
}

valid_domain() {
    local value="$1" label
    [[ ${#value} -le 253 && "$value" == *.* && "$value" != *..* ]] || return 1
    [[ "$value" =~ ^[a-zA-Z0-9.-]+$ && "$value" != *. ]] || return 1
    [[ ! "$value" =~ ^[0-9.]+$ ]] || return 1
    local IFS='.'
    for label in $value; do
        [[ ${#label} -ge 1 && ${#label} -le 63 && "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]] || return 1
    done
    case "$value" in *.local|*.localhost|*.internal|*.home.arpa|*.invalid|*.test|*.example) return 1;; esac
}

valid_email() {
    # Deliberately narrow syntax, safe to embed as a single Caddyfile token.
    [[ ${#1} -le 254 && "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9._%+-]*@[a-zA-Z0-9.-]+$ ]] || return 1
    valid_domain "${1##*@}"
}

confirm_action() {
    [[ "$YES" == 1 ]] && return 0
    [[ -t 0 ]] || die '非交互运行需要 --yes；先阅读上面的操作范围。'
    local answer
    read -r -p '确认执行？输入 yes：' answer
    [[ "$answer" == yes ]] || die '未确认，未开始安装或卸载。'
}

platform_check() {
    [[ "$EUID" -eq 0 ]] || die '请使用 sudo bash 运行。'
    [[ -r /etc/os-release ]] || die '缺少 /etc/os-release。'
    local os version
    os="$(sed -n 's/^ID=//p' /etc/os-release | tr -d '\"')"
    version="$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '\"')"
    [[ "$os" == debian && "$version" == 12 ]] || die '仅支持 Debian 12。'
    [[ "$(uname -m)" == x86_64 ]] || die '仅支持 x86_64/amd64。'
    [[ -d /run/systemd/system ]] || die '需要运行中的 systemd；不支持普通 Docker 容器或 chroot。'
    for cmd in systemctl systemd-analyze flock getent runuser sha256sum install useradd groupadd userdel groupdel; do
        command -v "$cmd" >/dev/null || die "缺少系统基础命令：$cmd"
    done
}

reject_symlinks() {
    local p
    for p in /opt /etc /var /var/lib "$APP" "$CONF" "$DATA" "$UNIT"; do
        [[ ! -L "$p" ]] || die "拒绝使用符号链接路径：$p"
    done
}

check_dropins() {
    local extra
    extra="$(systemctl show "$SERVICE" -p DropInPaths --value)"
    [[ -z "$extra" ]] || die '发现额外的 naiveproxy.service 配置覆盖，请人工检查后再操作。'
    local p
    for p in /etc/systemd/system/naiveproxy.service.d /run/systemd/system/naiveproxy.service.d; do
        [[ ! -e "$p" ]] || die "发现服务覆盖目录：$p"
    done
}

assert_owned() {
    [[ -f "$CONF/owner" && ! -L "$CONF/owner" ]] || die '没有找到本脚本的安装标识。'
    [[ "$(cat "$CONF/owner")" == "$MARKER" ]] || die '安装标识不匹配，拒绝操作。'
    [[ "$(stat -c %u "$CONF")" == 0 && "$(stat -c %a "$CONF")" == 750 ]] || die '配置目录所有者或权限异常。'
    [[ -f "$CONF/state.json" && ! -L "$CONF/state.json" ]] || die '缺少安装状态。'
    python3 - "$CONF/state.json" "$VERSION" <<'PY'
import json,sys,os,stat
p,version=sys.argv[1:]
s=os.stat(p)
if s.st_uid != 0 or stat.S_IMODE(s.st_mode) != 0o600:
    raise SystemExit('状态文件权限异常')
d=json.load(open(p))
if d.get('version') != version:
    raise SystemExit('安装版本与本脚本不同；拒绝自动升级或降级')
PY
    [[ "$(getent passwd "$ACCOUNT" | cut -d: -f6-7)" == "$DATA:/usr/sbin/nologin" ]] || die '服务账户属性异常。'
    [[ "$(id -u "$ACCOUNT")" -ne 0 && "$(id -gn "$ACCOUNT")" == "$ACCOUNT" ]] || die '服务账户权限异常。'
    [[ -f "$APP/naiveproxy.service" && ! -L "$APP/naiveproxy.service" ]] || die '缺少服务模板。'
    if [[ -e "$UNIT" ]]; then
        cmp -s "$APP/naiveproxy.service" "$UNIT" || die '服务文件已被修改；拒绝自动接管或删除。'
    fi
    check_dropins
}

preflight_fresh() {
    local p fragment
    for p in "$APP" "$CONF" "$DATA" "$UNIT"; do
        [[ ! -e "$p" ]] || die "已有文件或目录，拒绝覆盖：$p"
    done
    fragment="$(systemctl show "$SERVICE" -p FragmentPath --value)"
    [[ -z "$fragment" ]] || die "已存在同名服务：$fragment"
    getent passwd "$ACCOUNT" >/dev/null && die '已有同名账户，拒绝接管。'
    getent group "$ACCOUNT" >/dev/null && die '已有同名用户组，拒绝接管。'
    check_dropins
    return 0
}

install_packages() {
    local pkg missing=()
    for pkg in ca-certificates curl python3 iproute2 procps tar xz-utils; do
        if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" != 'install ok installed' ]]; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} )); then
        say "安装缺少的 Debian 软件包：${missing[*]}（失败时不自动卸载这些包）"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}

check_ports() {
    local port listeners
    for port in 80 443; do
        listeners="$(ss -H -ltn "sport = :$port")"
        [[ -z "$listeners" ]] || die "TCP $port 已被占用；不会停止现有进程。请换独立 VPS 或人工安排端口。"
    done
}

check_dns() {
    if [[ -z "$PUBLIC_IP" ]]; then
        PUBLIC_IP="$(curl -q --fail --silent --show-error --noproxy '*' --proto '=https' --tlsv1.2 \
            --connect-timeout 5 --max-time 12 -4 https://api.ipify.org)" || die '公网 IP 查询失败，可用 --public-ip 指定。'
    fi
    ip -j -6 address show scope global > "$WORK/ipv6.json"
    python3 - "$DOMAIN" "$PUBLIC_IP" "$WORK/ipv6.json" <<'PY'
import sys,socket,ipaddress,json
domain,public,path=sys.argv[1:]
try:
    v4=ipaddress.IPv4Address(public)
    if not v4.is_global: raise ValueError('不是公网 IPv4')
    answers=socket.getaddrinfo(domain,443,type=socket.SOCK_STREAM)
    a={ipaddress.ip_address(x[4][0]) for x in answers if x[0]==socket.AF_INET}
    aaaa={ipaddress.ip_address(x[4][0]) for x in answers if x[0]==socket.AF_INET6}
    # Incomplete address records have no local address; a peer is not a substitute.
    local6={ipaddress.ip_address(y['local']) for x in json.load(open(path))
            for y in x.get('addr_info',[]) if y.get('local')}
    if a != {v4}: raise ValueError('全部 A 记录必须且只能指向指定的公网 IPv4；检查 CDN、DNS 和 /etc/hosts')
    if not aaaa.issubset(local6) or any(not x.is_global for x in aaaa):
        raise ValueError('AAAA 记录不属于本机全局 IPv6，请修正或删除无效 AAAA')
except (ValueError,OSError) as e: raise SystemExit('DNS 检查失败：'+str(e))
print('DNS 检查通过（使用本机系统解析器；公网传播仍需外部验证）。')
PY
}

download_binary() {
    say "下载固定版本 $VERSION 并校验 SHA-256……"
    curl -q --fail --location --silent --show-error --noproxy '*' --proto '=https' --proto-redir '=https' \
        --tlsv1.2 --connect-timeout 15 --max-time 180 --retry 2 --output "$WORK/package.tar.xz" "$DOWNLOAD"
    printf '%s  %s\n' "$ARCHIVE_SHA" "$WORK/package.tar.xz" | sha256sum --check --status || die '发布包哈希不匹配，停止。'
    # Extract just the expected member to stdout; never unpack arbitrary archive paths.
    tar -xJOf "$WORK/package.tar.xz" caddy-forwardproxy-naive/caddy > "$WORK/caddy"
    printf '%s  %s\n' "$BINARY_SHA" "$WORK/caddy" | sha256sum --check --status || die '二进制哈希不匹配，停止。'
    python3 - "$WORK/caddy" <<'PY'
import sys,struct
with open(sys.argv[1],'rb') as f: h=f.read(20)
if h[:6] != b'\x7fELF\x02\x01' or struct.unpack('<H',h[18:20])[0] != 62:
    raise SystemExit('发布包不是 Linux amd64 ELF')
PY
}

render_bundle() {
    # Destination is a new private staging directory. No real account secrets in argv.
    local target="$1" domain="$2" email="$3"
    python3 - "$target" "$domain" "$email" "$VERSION" "$MARKER" <<'PY'
import sys,pathlib,json,secrets,string,os
dest,domain,email,version,marker=sys.argv[1:]
p=pathlib.Path(dest)
alphabet=string.ascii_letters+string.digits
user=''.join(secrets.choice(alphabet) for _ in range(20))
password=''.join(secrets.choice(alphabet) for _ in range(32))
state=dict(version=version,domain=domain,email=email,username=user,password=password)
def write(name,text):
    with open(p/name,'x',encoding='utf-8') as f: f.write(text)
    os.chmod(p/name,0o600)
write('state.json',json.dumps(state,indent=2)+'\n')
write('owner',marker+'\n')
write('client.json',json.dumps({'listen':'socks://127.0.0.1:10808','proxy':f'https://{user}:{password}@{domain}:443'},indent=2)+'\n')
write('sing-box-outbound.json',json.dumps({'type':'naive','tag':'naive','server':domain,'server_port':443,'username':user,'password':password,'tls':{'enabled':True,'server_name':domain}},indent=2)+'\n')
write('client-uri.txt',f'naive+https://{user}:{password}@{domain}:443?padding=1#NaiveProxy\n')
write('Caddyfile',f'''{{
    admin unix//run/naiveproxy/admin.sock
    persist_config off
    email {email}
    servers {{
        protocols h1 h2
    }}
    log {{
        exclude http.log.error
    }}
}}

:443, {domain} {{
    route {{
        forward_proxy {{
            basic_auth {user} {password}
            hide_ip
            hide_via
            probe_resistance
            acl {{
                deny 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
                deny 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16
                deny 192.0.0.0/24 192.0.2.0/24 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
                deny 224.0.0.0/4 240.0.0.0/4
                deny ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
                deny 64:ff9b::/96 64:ff9b:1::/48 2001:db8::/32 2002::/16
            }}
        }}
        root * /opt/naiveproxy/site
        file_server
    }}
}}
''')
write('index.html','<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Welcome</title><body><main><h1>Welcome</h1><p>This website is ready.</p></main></body></html>\n')
PY
    cat > "$target/naiveproxy.service" <<'UNIT'
# Managed by naiveproxy-debian12-v1
[Unit]
Description=NaiveProxy Caddy server
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=notify
User=naiveproxy
Group=naiveproxy
Environment=HOME=/var/lib/naiveproxy
Environment=XDG_DATA_HOME=/var/lib/naiveproxy/data
Environment=XDG_CONFIG_HOME=/var/lib/naiveproxy/config
WorkingDirectory=/var/lib/naiveproxy
ExecStart=/opt/naiveproxy/caddy run --config /etc/naiveproxy/Caddyfile --adapter caddyfile
ExecReload=/opt/naiveproxy/caddy reload --address unix//run/naiveproxy/admin.sock --config /etc/naiveproxy/Caddyfile --adapter caddyfile
RuntimeDirectory=naiveproxy
RuntimeDirectoryMode=0700
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/naiveproxy /run/naiveproxy
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK
LimitNOFILE=65536
Restart=on-failure
RestartSec=5s
TimeoutStartSec=60s
TimeoutStopSec=30s

[Install]
WantedBy=multi-user.target
UNIT
}

as_service() {
    runuser -u "$ACCOUNT" -- env -i PATH="$PATH" HOME="$DATA" XDG_DATA_HOME="$DATA/data" \
        XDG_CONFIG_HOME="$DATA/config" "$@"
}

validate_install() {
    printf '%s  %s\n' "$BINARY_SHA" "$APP/caddy" | sha256sum --check --status || die '已安装二进制的哈希不匹配。'
    as_service "$APP/caddy" list-modules > "$WORK/modules.txt"
    grep -Fxq http.handlers.forward_proxy "$WORK/modules.txt" || die '缺少 forward_proxy 模块。'
    # Keep diagnostics private: configuration error messages may contain credentials.
    as_service "$APP/caddy" validate --config "$CONF/Caddyfile" --adapter caddyfile > "$WORK/validate.log" 2>&1 \
        || die "Caddy 配置验证失败，私有诊断：$WORK/validate.log"
    systemd-analyze verify "$APP/naiveproxy.service" > "$WORK/unit.log" 2>&1 \
        || die "systemd 验证失败，私有诊断：$WORK/unit.log"
}

health_check() {
    local domain deadline
    domain="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["domain"])' "$CONF/state.json")"
    valid_domain "$domain" || die '状态中的域名无效。'
    deadline=$((SECONDS + 240))
    say '等待本机 HTTPS 证书及静态首页，最长约 240 秒……'
    while (( SECONDS < deadline )); do
        if systemctl is-active --quiet "$SERVICE" &&
           curl -q --fail --silent --show-error --noproxy '*' --proto '=https' --connect-timeout 3 --max-time 5 \
                --resolve "$domain:443:127.0.0.1" "https://$domain/" -o "$WORK/home.html" 2>/dev/null &&
           cmp -s "$APP/site/index.html" "$WORK/home.html"; then
            break
        fi
        sleep 3
    done
    if [[ ! -f "$WORK/home.html" ]] || ! cmp -s "$APP/site/index.html" "$WORK/home.html"; then
        die '证书或首页检查失败。请检查 DNS、公网 TCP 80/443、CAA 和系统时间。'
    fi
    # Credentials are read from a private file, never exposed in curl's argv.
    python3 - "$CONF/state.json" "$WORK/proxy.curl" "$WORK/wrong-proxy.curl" <<'PY'
import json,sys,os,secrets
d=json.load(open(sys.argv[1]))
with open(sys.argv[2],'x') as f:
    f.write('proxy = "https://{username}:{password}@{domain}:443"\n'.format(**d))
os.chmod(sys.argv[2],0o600)
d['password']=secrets.token_hex(32)
with open(sys.argv[3],'x') as f:
    f.write('proxy = "https://{username}:{password}@{domain}:443"\n'.format(**d))
os.chmod(sys.argv[3],0o600)
PY
    say '验证认证 HTTPS CONNECT（测试目标 example.com）……'
    env -i PATH="$PATH" curl -q --config "$WORK/proxy.curl" --noproxy '' --fail --silent --show-error \
        --proto '=https' --connect-timeout 8 --max-time 25 --resolve "$domain:443:127.0.0.1" \
        https://example.com/ -o /dev/null 2> "$WORK/proxy.log" \
        || die "认证代理检查失败，私有诊断：$WORK/proxy.log"
    if env -i PATH="$PATH" curl -q --config "$WORK/wrong-proxy.curl" --noproxy '' --fail --silent \
        --proto '=https' --connect-timeout 8 --max-time 15 --resolve "$domain:443:127.0.0.1" \
        https://example.com/ -o /dev/null; then
        die '错误密码仍能通过代理访问目标，拒绝启用服务。'
    fi
    rm -f -- "$WORK/proxy.curl" "$WORK/wrong-proxy.curl"
    say '本机可信 TLS、静态首页、认证 CONNECT 和错误密码拒绝检查通过。仍需外部 Naive 客户端验收。'
}

rollback() {
    local failed=0
    say '安装未完成，正在撤销本次创建的服务和文件……' >&2
    if (( NEW_UNIT )); then
        systemctl stop "$SERVICE" || failed=1
        systemctl disable "$SERVICE" >/dev/null 2>&1 || failed=1
        if (( failed )); then
            say '停止或取消自启失败；保留全部文件，请人工检查服务状态。' >&2
            return 1
        fi
        rm -f -- "$UNIT" || return 1
        systemctl daemon-reload || return 1
    fi
    # Flags are set only after exclusive creation; no pre-existing directory is removed.
    if (( NEW_APP )); then rm -rf -- "$APP" || failed=1; fi
    if (( NEW_CONF )); then rm -rf -- "$CONF" || failed=1; fi
    if (( NEW_DATA )); then rm -rf -- "$DATA" || failed=1; fi
    if (( NEW_ACCOUNT )); then userdel "$ACCOUNT" || failed=1; fi
    if (( NEW_GROUP )) && getent group "$ACCOUNT" >/dev/null; then groupdel "$ACCOUNT" || failed=1; fi
    return "$failed"
}

on_exit() {
    local code=$?
    trap - EXIT ERR INT TERM HUP
    set +e
    if (( TRANSACTION && ! COMMITTED )); then
        rollback || say '回滚未完整完成；请检查上面的错误，不要重复覆盖安装。' >&2
    fi
    if [[ -n "$WORK" && -d "$WORK" ]]; then
        rm -f -- "$WORK/proxy.curl" "$WORK/wrong-proxy.curl" "$WORK/state.json" "$WORK/Caddyfile" "$WORK/client.json" "$WORK/client-uri.txt" "$WORK/sing-box-outbound.json"
        if (( code == 0 )); then
            rm -rf -- "$WORK"
        else
            say "本次私有诊断目录（root 可读）：$WORK" >&2
        fi
    fi
    exit "$code"
}

new_workdir() { WORK="$(mktemp -d /var/tmp/naiveproxy-setup.XXXXXXXX)"; chmod 700 "$WORK"; }

install_fresh() {
    preflight_fresh
    if [[ -z "$DOMAIN" ]]; then
        [[ -t 0 ]] || die '缺少 --domain。'
        read -r -p '已指向 VPS 的域名：' DOMAIN
    fi
    DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
    valid_domain "$DOMAIN" || die '域名格式无效；不接受 IP、协议、端口、路径或配置字符。'
    if [[ -z "$EMAIL" ]]; then
        [[ -t 0 ]] || die '缺少 --email。'
        read -r -p '你可接收邮件的 ACME 联系邮箱：' EMAIL
    fi
    valid_email "$EMAIL" || die '邮箱格式不支持。'
    say "将为 $DOMAIN 安装 $VERSION；使用专用账户/目录，启用开机自启，并向公共 CA 申请证书。"
    say '将安装缺少的 Debian 依赖；不会修改 SSH、防火墙、BBR 或现有 Caddy。'
    confirm_action
    new_workdir
    install_packages
    check_ports
    check_dns
    download_binary
    render_bundle "$WORK" "$DOMAIN" "$EMAIL"
    TRANSACTION=1
    groupadd --system "$ACCOUNT"; NEW_GROUP=1
    useradd --system --gid "$ACCOUNT" --home-dir "$DATA" --no-create-home --shell /usr/sbin/nologin "$ACCOUNT"; NEW_ACCOUNT=1
    mkdir "$APP"; NEW_APP=1
    mkdir "$CONF"; NEW_CONF=1
    mkdir "$DATA"; NEW_DATA=1
    chmod 755 "$APP"
    chown root:"$ACCOUNT" "$CONF"; chmod 750 "$CONF"
    chown "$ACCOUNT:$ACCOUNT" "$DATA"; chmod 700 "$DATA"
    install -o root -g root -m 0755 "$WORK/caddy" "$APP/caddy"
    install -d -o root -g root -m 0755 "$APP/site"
    install -o root -g root -m 0644 "$WORK/index.html" "$APP/site/index.html"
    install -o root -g "$ACCOUNT" -m 0640 "$WORK/Caddyfile" "$CONF/Caddyfile"
    local f
    for f in owner state.json client.json client-uri.txt sing-box-outbound.json; do
        install -o root -g root -m 0600 "$WORK/$f" "$CONF/$f"
    done
    # systemd-analyze requires a filename with a recognized unit suffix.
    install -o root -g root -m 0644 "$WORK/naiveproxy.service" "$APP/naiveproxy.service"
    validate_install
    check_ports
    install -o root -g root -m 0644 "$APP/naiveproxy.service" "$UNIT"; NEW_UNIT=1
    systemctl daemon-reload
    systemctl start "$SERVICE"
    health_check
    systemctl enable "$SERVICE" >/dev/null
    COMMITTED=1
    say "安装完成。客户端配置：$CONF/client.json（root 0600）。"
    say '查看 URI：sudo bash naiveproxy-debian12.sh credentials'
}

restore_retained() {
    assert_owned
    [[ -z "$DOMAIN" && -z "$EMAIL" && -z "$PUBLIC_IP" ]] || die '已有安装不接受新参数；不会自动更换域名或凭据。'
    if [[ -f "$UNIT" ]]; then
        say '已有安装，未修改任何配置或凭据。使用 status/check 查看状态。'
        return 0
    fi
    say '将恢复保留的原服务、域名、证书和凭据，不下载新版本。'
    confirm_action
    new_workdir
    check_ports
    validate_install
    TRANSACTION=1
    install -o root -g root -m 0644 "$APP/naiveproxy.service" "$UNIT"; NEW_UNIT=1
    systemctl daemon-reload
    systemctl start "$SERVICE"
    health_check
    systemctl enable "$SERVICE" >/dev/null
    COMMITTED=1
    say '原安装已恢复，凭据保持不变。'
}

uninstall_managed() {
    assert_owned
    say '将停止、取消自启并移除本脚本的 naiveproxy.service。'
    if (( PURGE )); then
        say "同时永久删除 $APP、$CONF、$DATA，包括证书、密码及专用账户；不会卸载 APT 包。"
    else
        say '程序、配置、证书和凭据均保留，之后运行 install 可恢复。'
    fi
    confirm_action
    if [[ -f "$UNIT" ]]; then
        systemctl stop "$SERVICE"
        systemctl disable "$SERVICE" >/dev/null
        rm -f -- "$UNIT"
        systemctl daemon-reload
    fi
    if (( PURGE )); then
        systemctl is-active --quiet "$SERVICE" && die '服务仍活动，拒绝删除目录。'
        if pgrep -u "$ACCOUNT" >/dev/null; then die '专用账户仍有进程，拒绝删除账户或目录。'; fi
        [[ "$(id -G "$ACCOUNT")" == "$(id -g "$ACCOUNT")" ]] || die '账户存在额外用户组，请人工处理。'
        [[ -z "$(getent group "$ACCOUNT" | cut -d: -f4)" ]] || die '专用用户组有额外成员，请人工处理。'
        userdel "$ACCOUNT"
        if getent group "$ACCOUNT" >/dev/null; then groupdel "$ACCOUNT"; fi
        rm -rf -- "$APP" "$CONF" "$DATA"
        say '专用目录和账户已删除；APT 包及私有诊断目录不会自动删除。'
    else
        say '服务已卸载，数据保留。'
    fi
}

main() {
    local action="${1:-install}" opt
    (( $# == 0 )) || shift
    case "$action" in -h|--help|help) usage; return 0;; install|status|check|credentials|uninstall) ;; *) usage; die '未知操作。';; esac
    while (( $# )); do
        opt="$1"; shift
        case "$opt" in
            --domain|--email|--public-ip)
                [[ "$action" == install && $# -ge 1 && "$1" != --* ]] || die "$opt 参数无效。"
                case "$opt" in --domain) DOMAIN="$1";; --email) EMAIL="$1";; --public-ip) PUBLIC_IP="$1";; esac
                shift;;
            --yes) YES=1;;
            --purge) [[ "$action" == uninstall ]] || die '--purge 仅用于 uninstall。'; PURGE=1;;
            *) die "未知选项：$opt";;
        esac
    done
    platform_check
    reject_symlinks
    # /run is root-writable; do not place the lock in the shared /run/lock.
    [[ ! -L /run/naiveproxy-setup.lock ]] || die '锁文件是符号链接。'
    exec 9>/run/naiveproxy-setup.lock
    flock -n 9 || die '已有安装器在运行。'
    trap on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    case "$action" in
        install)
            if [[ -e "$CONF/owner" ]]; then restore_retained; else install_fresh; fi;;
        status)
            assert_owned
            systemctl show "$SERVICE" -p LoadState -p ActiveState -p SubState -p UnitFileState -p ExecMainStatus;;
        check)
            assert_owned
            [[ -f "$UNIT" ]] || die '服务已卸载；先执行 install 恢复。'
            new_workdir; health_check;;
        credentials)
            assert_owned
            say '以下内容含密码，请勿贴入公开日志或群聊：'
            cat "$CONF/client-uri.txt" "$CONF/client.json"
            say "sing-box outbound 片段：$CONF/sing-box-outbound.json";;
        uninstall) uninstall_managed;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
