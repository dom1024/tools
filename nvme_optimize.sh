#!/usr/bin/env bash
# nvme_optimize.sh
# 适用于：单块 NVMe、NVMe 组建的 RAID0（mdadm / LVM 等）
# 主要优化项：
#   - I/O 调度器设置为 none / mq-deadline
#   - 提高队列深度 nr_requests
#   - 调整 read_ahead_kb
#   - 绑定中断亲和 rq_affinity=2
#   - 打开 NVMe 设备的性能电源策略
#   - 启用 fstrim.timer （按周自动 TRIM）

set -e

# ========== 工具函数 ==========
log() { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*"; }
err() { echo -e "[\e[31mERR \e[0m] $*" >&2; }

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请用 root 权限运行此脚本：sudo $0"
    exit 1
  fi
}

pause_confirm() {
  echo
  read -r -p "继续执行优化？(y/N) " ans
  case "$ans" in
    y|Y) ;;
    *) err "用户取消。"; exit 1 ;;
  esac
}

# ========== 检测候选设备 ==========
detect_candidates() {
  log "扫描 NVMe / 非旋转磁盘 以及 RAID0 阵列设备 ..."
  echo

  # 非旋转磁盘 (ROTA=0)
  lsblk -ndo NAME,ROTA,TYPE | awk '$2==0 && $3=="disk"{print $1}' | sort -u > /tmp/nvme_candidates.tmp || true

  # RAID0（md设备可能显示为 disk 或 raid0）
  awk '$4=="raid0"{print $1}' /proc/mdstat 2>/dev/null | sed 's/^md//' >> /tmp/nvme_candidates.tmp || true

  if [[ ! -s /tmp/nvme_candidates.tmp ]]; then
    err "未发现候选的 NVMe / RAID0 设备，请手动检查 lsblk。"
    rm -f /tmp/nvme_candidates.tmp
    exit 1
  fi

  CANDIDATES=($(sort -u /tmp/nvme_candidates.tmp))
  rm -f /tmp/nvme_candidates.tmp

  log "发现如下候选块设备（仅列出块名，不带 /dev/ 前缀）："
  for d in "${CANDIDATES[@]}"; do
    lsblk -dno NAME,MODEL,SIZE,ROTA /dev/"$d" 2>/dev/null || echo "$d"
  done

  echo
  read -r -p "请输入要优化的设备（空格分隔，如：nvme0n1 md0），或输入 all 代表全部候选设备: " choose

  if [[ -z "$choose" ]]; then
    err "未选择任何设备，退出。"
    exit 1
  fi

  if [[ "$choose" == "all" ]]; then
    SELECTED=("${CANDIDATES[@]}")
  else
    SELECTED=($choose)
  fi

  log "将对以下设备进行优化：${SELECTED[*]}"
}

# ========== 针对块设备的参数优化 ==========
tune_block_device() {
  local dev="$1"
  local sys_path="/sys/block/$dev"

  if [[ ! -d "$sys_path" ]]; then
    warn "设备 $dev 的 sysfs 不存在，跳过。"
    return
  fi

  log "正在优化块设备：/dev/$dev"

  # 1. I/O 调度器
  if [[ -f "$sys_path/queue/scheduler" ]]; then
    local sched
    sched=$(cat "$sys_path/queue/scheduler")
    # 例如："[none] mq-deadline kyber"
    if echo "$sched" | grep -qw "none"; then
      echo none > "$sys_path/queue/scheduler"
      log "  - 调度器设置: none"
    elif echo "$sched" | grep -qw "mq-deadline"; then
      echo mq-deadline > "$sys_path/queue/scheduler"
      log "  - 调度器设置: mq-deadline"
    else
      warn "  - 未找到合适的调度器，当前: $sched"
    fi
  else
    warn "  - $sys_path/queue/scheduler 不存在，可能已强制使用多队列。"
  fi

  # 2. 队列深度 nr_requests
  if [[ -f "$sys_path/queue/nr_requests" ]]; then
    echo 1024 > "$sys_path/queue/nr_requests"
    log "  - nr_requests 设置为 1024"
  fi

  # 3. 预读 read_ahead_kb
  if [[ -f "$sys_path/queue/read_ahead_kb" ]]; then
    echo 128 > "$sys_path/queue/read_ahead_kb"
    log "  - read_ahead_kb 设置为 128"
  fi

  # 4. rq_affinity（将中断尽量绑到发起 I/O 的 CPU 上）
  if [[ -f "$sys_path/queue/rq_affinity" ]]; then
    echo 2 > "$sys_path/queue/rq_affinity"
    log "  - rq_affinity 设置为 2"
  fi
}

# ========== NVMe 电源策略 ==========
tune_nvme_power() {
  log "调整 NVMe 电源策略（performance 或 on）..."

  for n in /sys/class/nvme/nvme*; do
    [[ -d "$n" ]] || continue
    local ctrl
    ctrl=$(basename "$n")

    # 某些内核是 power/control，某些有 power_policy；做兼容处理
    if [[ -f "$n/power/control" ]]; then
      echo on > "$n/power/control"
      log "  - $ctrl: power/control 设置为 on"
    fi

    if [[ -f "$n/power/ps_max_latency_us" ]]; then
      # 这个值越小，省电越多；我们给一个中等偏低的值，偏性能
      echo 0 > "$n/power/ps_max_latency_us" 2>/dev/null || true
      log "  - $ctrl: ps_max_latency_us 尝试设置为 0（锁定高性能电源状态）"
    fi
  done
}

# ========== 启用 fstrim.timer ==========
enable_fstrim_timer() {
  if command -v systemctl >/dev/null 2>&1; then
    log "启用周期性 fstrim.timer（按周自动对所有支持的挂载点做 TRIM）..."
    systemctl enable --now fstrim.timer || warn "  - 启用 fstrim.timer 失败，请手动检查 systemd 状态。"
  else
    warn "未检测到 systemctl，无法自动启用 fstrim.timer，请手动配置 fstrim cron。"
  fi
}

# ========== 建议 fstab 挂载参数 ==========
show_fstab_tips() {
  echo
  log "fstab 挂载参数优化建议（需手动编辑 /etc/fstab）："
  echo "  - 对 SSD/NVMe 建议增加: noatime,nodiratime"
  echo "  - 如果不追求极致实时 TRIM，优先使用 fstrim.timer，而不是挂载 discard"
  echo
  echo "示例（ext4）："
  echo "  UUID=xxxx-xxxx  /data  ext4  defaults,noatime,nodiratime  0  2"
  echo
  echo "示例（xfs）："
  echo "  UUID=xxxx-xxxx  /data  xfs   defaults,noatime,nodiratime  0  0"
  echo
  warn "注意：修改 /etc/fstab 前务必备份，并确保写法正确，否则可能导致系统无法启动！"
}

# ========== 主流程 ==========
main() {
  require_root

  echo "==============================================="
  echo " NVMe / RAID0 磁盘优化脚本"
  echo " - 适用于 Linux 服务器（ext4 / xfs 等文件系统）"
  echo " - 不会分区/格式化/重建 RAID，只做内核参数与调度器优化"
  echo "==============================================="
  echo

  detect_candidates
  pause_confirm

  for dev in "${SELECTED[@]}"; do
    tune_block_device "$dev"
  done

  tune_nvme_power
  enable_fstrim_timer
  show_fstab_tips

  echo
  log "优化完成。建议重启后再用如下命令验证："
  echo "  lsblk -d -o NAME,SIZE,ROTA,SCHED"
  echo "  cat /sys/block/<dev>/queue/read_ahead_kb"
  echo "  systemctl status fstrim.timer"
}

main "$@"
