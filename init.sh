
#!/usr/bin/env bash
set -euo pipefail

### ========= 可调参数 =========
SSH_PORT=12306
TZ="Asia/Shanghai"
LIMIT_NOFILE=262144
LIMIT_MEMLOCK=262144
TM_TOKEN="6Oex+ziyUIz/FGRZq07Wcns1+dmA5xgDm7CCCWG7Mzk="          # 从环境变量注入，不在脚本里写死
### ==========================

echo "[0] APT 基础设置与更新"
export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y htop sudo wget curl chrony vnstat fail2ban

echo "[1] 时间与时区配置"
if command -v timedatectl >/dev/null 2>&1; then
  timedatectl set-timezone "$TZ" || true
fi
ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime || true
systemctl enable --now chronyd 2>/dev/null || systemctl enable --now chrony 2>/dev/null || true

echo "[2] Docker 安装与配置"
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
fi

# 备份已有 daemon.json
if [ -f /etc/docker/daemon.json ]; then
  cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%s) || true
fi

cat >/etc/docker/daemon.json <<EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "200m",
    "max-file": "5"
  }
}
EOF

systemctl enable --now docker

echo "[3] Traffmonetizer 容器（如需）"
if [ -n "$TM_TOKEN" ]; then
  # 如果已存在则先停止删除
  if docker ps -a --format '{{.Names}}' | grep -q '^tm$'; then
    docker rm -f tm || true
  fi
  docker run -d --name tm --restart=always \
    traffmonetizer/cli_v2 start accept --token "$TM_TOKEN" || true
else
  echo "  TM_TOKEN 未设置，跳过 Traffmonetizer 启动（如需请 export TM_TOKEN=... 再运行）"
fi

echo "[4] Fail2Ban 配置"
rm -f /etc/fail2ban/jail.d/defaults-debian.conf || true

cat >/etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8
bantime  = 600
findtime = 600
maxretry = 3

[ssh]
enabled  = true
port     = ${SSH_PORT}
filter   = sshd
backend  = systemd
maxretry = 6
EOF

systemctl enable --now fail2ban

echo "[5] 文件句柄与 memlock 限制"
mkdir -p /etc/security

cat >/etc/security/limits.d/99-custom.conf <<EOF
*       soft    nofile  ${LIMIT_NOFILE}
*       hard    nofile  ${LIMIT_NOFILE}
root    soft    nofile  ${LIMIT_NOFILE}
root    hard    nofile  ${LIMIT_NOFILE}

*       soft    memlock ${LIMIT_MEMLOCK}
*       hard    memlock ${LIMIT_MEMLOCK}
root    soft    memlock ${LIMIT_MEMLOCK}
root    hard    memlock ${LIMIT_MEMLOCK}
EOF

# systemd 级别的 NOFILE
if [ -f /etc/systemd/system.conf ]; then
  sed -i 's/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE='"${LIMIT_NOFILE}"'/' /etc/systemd/system.conf
fi
if [ -f /etc/systemd/user.conf ]; then
  sed -i 's/^#\?DefaultLimitNOFILE=.*/DefaultLimitNOFILE='"${LIMIT_NOFILE}"'/' /etc/systemd/user.conf
fi

systemctl daemon-reload

echo "[6] sysctl 网络与内核参数"
cat >/etc/sysctl.d/99-custom.conf <<EOF
# 优化网络与文件句柄

fs.file-max = 1000000
fs.inotify.max_user_instances = 8192

net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768

net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.tcp_syncookies = 1

# TIME_WAIT 优化（保持相对保守）
net.ipv4.tcp_fin_timeout = 30

# 拥塞控制与队列算法
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer（保持与内核默认兼容的范围）
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# 如需更激进可再按需开启：
# net.ipv4.tcp_timestamps = 0
# net.ipv4.tcp_tw_reuse = 1
EOF

sysctl --system || sysctl -p /etc/sysctl.d/99-custom.conf || true

echo "[7] vnstat 启用"
systemctl enable --now vnstat || true
