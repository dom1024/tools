#!/usr/bin/env bash
#
# ssd_nvme_tune.sh
# 通用 SSD / NVMe / NVMe RAID0 磁盘优化脚本（Linux）
#
# 只做这些事：
#   - 调整块设备队列参数：scheduler / nr_requests / read_ahead_kb / rq_affinity
#   - 调整 NVMe 控制器电源策略（偏性能）
#   - 可选：启用 fstrim.timer（如果是 systemd）
#
# 不做这些事：
#   - 不分区、不格式化、不修改 RAID 结构
#
# 用法：
#   sudo ./ssd_nvme_tune.sh                 # 自动检测所有 SSD/NVMe 并优化
#   sudo ./ssd_nvme_tune.sh nvme0n1 md0     # 只优化指定设备
#   sudo ./ssd_nvme_tune.sh --dry-run       # 只打印将要修改的内容，不真正写入
#

set -uo pipefail    # 不用 -e，避免某个 echo 失败就退出整个脚本

DRY_RUN=0

log()  { echo -e "[INFO ] $*"; }
warn() { echo -e "[WARN ] $*" >&2; }
err()  { echo -e "[ERROR] $*" >&2; }

usage() {
  cat <<EOF
通用 SSD / NVMe 优化脚本

用法：
  sudo $0                    自动检测所有 SSD/NVMe 并优化
  sudo $0 <dev1> <dev2> ...  只优化指定块设备（例如：nvme0n1 sda md0）
  sudo $0 --dry-run          只展示将要修改的内容（不实际修改）

说明：
  - 只针对 ROTA=0（非旋转介质）的块设备做调整
  - 不会创建/删除分区、不改文件系统、不改 RAID 结构
  - 仅调整 /sys/block/... 的内核参数和 NVMe 电源策略
EOF
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    err "请使用 root 运行：sudo $0 ..."
    exit 1
  fi
}

# 安全写 sysfs（失败则 warning，不中断整体执行）
write_sysfs() {
  local val="$1"
  local path="$2"

  if [[ ! -e "$path" ]]; then
    warn "$path 不存在，跳过。"
    return
  fi

  if [[ ! -w "$path" ]]; then
    warn "$path 不可写（只读或权限问题），跳过。"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: echo $val > $path"
    return
  fi

  # 捕获 echo 失败，不让它触发 set -e（我们本来就没开 -e，但以防你以后加）
  if ! echo "$val" > "$path" 2>/dev/null; then
    warn "写入失败（可能内核不支持或参数非法）：echo $val > $path"
    return
  fi

  log "设置：$path = $val"
}

# 自动检测所有 SSD / NVMe 设备（ROTA=0 & TYPE=disk）
detect_ssd_devices() {
  local list
  list=$(lsblk -ndo NAME,ROTA,TYPE 2>/dev/null | awk '$2==0 && $3=="disk"{print $1}' || true)

  if [[ -z "$list" ]]; then
    err "未检测到 SSD/NVMe 磁盘（ROTA=0 & TYPE=disk），请检查 lsblk 输出。"
    exit 1
  fi

  echo "$list"
}

# 对单个块设备进行优化
tune_block_device() {
  local dev="$1"     # 不带 /dev/ 前缀
  local sys_path="/sys/block/$dev"

  if [[ ! -d "$sys_path" ]]; then
    warn "设备 $dev 对应的 $sys_path 不存在，跳过。"
    return
  fi

  # 检查是否为 SSD（ROTA=0）
  local rota="1"
  if [[ -f "$sys_path/queue/rotational" ]]; then
    rota=$(cat "$sys_path/queue/rotational" 2>/dev/null || echo 1)
  fi
  if [[ "$rota" != "0" ]]; then
    warn "/dev/$dev 是旋转盘（HDD），默认不做 SSD 优化，跳过。"
    return
  fi

  log "开始优化块设备：/dev/$dev"

  # 1. I/O 调度器：优先 none，其次 mq-deadline
  local sched_path="$sys_path/queue/scheduler"
  if [[ -f "$sched_path" ]]; then
    local avail
    avail=$(cat "$sched_path")
    local target=""

    if echo "$avail" | grep -qw "none"; then
      target="none"
    elif echo "$avail" | grep -qw "mq-deadline"; then
      target="mq-deadline"
    fi

    if [[ -n "$target" ]]; then
      write_sysfs "$target" "$sched_path"
    else
      warn "调度器中未发现 none/mq-deadline，可用列表：$avail"
    fi
  else
    warn "$sched_path 不存在，系统可能强制使用多队列调度。"
  fi

  # 2. 队列深度 nr_requests（不同内核可接受范围不一样，写失败会自动跳过）
  local nr_path="$sys_path/queue/nr_requests"
  if [[ -f "$nr_path" ]]; then
    write_sysfs 1024 "$nr_path"
  fi

  # 3. 预读大小 read_ahead_kb
  local ra_path="$sys_path/queue/read_ahead_kb"
  if [[ -f "$ra_path" ]]; then
    write_sysfs 128 "$ra_path"
  fi

  # 4. rq_affinity（2 = 更智能地亲和 I/O CPU）
  local rq_path="$sys_path/queue/rq_affinity"
  if [[ -f "$rq_path" ]]; then
    write_sysfs 2 "$rq_path"
  fi

  log "块设备 /dev/$dev 优化完成。"
}

# NVMe 控制器电源策略调优（偏性能）
tune_nvme_power() {
  local found=0
  for n in /sys/class/nvme/nvme*; do
    [[ -d "$n" ]] || continue
    found=1
    local ctrl
    ctrl=$(basename "$n")

    log "调整 NVMe 控制器电源策略：$ctrl"

    # power/control: on = 不自动进入 runtime suspend
    if [[ -f "$n/power/control" ]]; then
      write_sysfs "on" "$n/power/control"
    fi

    # ps_max_latency_us: 尽可能降低延迟；部分平台写 0 会报错，没关系，会 warning 并跳过
    if [[ -f "$n/power/ps_max_latency_us" ]]; then
      write_sysfs 0 "$n/power/ps_max_latency_us"
    fi
  done

  if [[ $found -eq 0 ]]; then
    warn "未检测到 /sys/class/nvme/nvme*，可能系统无 NVMe 控制器。"
  fi
}

# 启用 fstrim.timer（如果是 systemd）
enable_fstrim_timer() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "未检测到 systemctl，跳过 fstrim.timer 配置。"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "DRY-RUN: systemctl enable --now fstrim.timer"
    return
  fi

  log "启用 fstrim.timer（按周自动对所有挂载点 TRIM）..."
  if systemctl enable --now fstrim.timer >/dev/null 2>&1; then
    log "fstrim.timer 已启用。"
  else
    warn "启用 fstrim.timer 失败，请手动执行：systemctl enable --now fstrim.timer"
  fi
}

show_fstab_hint() {
  cat <<'EOF'

[提示] 如需进一步优化挂载参数，请手动编辑 /etc/fstab，示例：

  # ext4 示例（SSD/NVMe）
  UUID=xxxx-xxxx   /data  ext4  defaults,noatime,nodiratime  0  2

  # xfs 示例（SSD/NVMe）
  UUID=yyyy-yyyy   /data  xfs   defaults,noatime,nodiratime  0  0

说明：
  - noatime,nodiratime 能减少小文件随机写
  - 一般推荐通过 fstrim.timer 做周期性 TRIM，而不是挂载参数中加 discard

修改 fstab 前务必备份，并确认语法正确，否则可能导致系统无法启动。
EOF
}

main() {
  require_root

  # 参数解析
  if [[ $# -ge 1 ]]; then
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
      usage
    fi
    if [[ "$1" == "--dry-run" ]]; then
      DRY_RUN=1
      shift || true
    fi
  fi

  local devs=()

  if [[ $# -gt 0 ]]; then
    # 用户明确指定设备名
    devs=("$@")
  else
    # 自动检测所有 SSD/NVMe
    log "自动检测 SSD/NVMe 设备（ROTA=0 & TYPE=disk）..."
    mapfile -t devs < <(detect_ssd_devices)
  fi

  log "将对以下块设备进行 SSD 优化（仅限 ROTA=0）：${devs[*]}"

  for d in "${devs[@]}"; do
    tune_block_device "$d"
  done

  tune_nvme_power
  enable_fstrim_timer
  show_fstab_hint

  log "全部完成。可用如下命令查看结果："
  echo "  lsblk -d -o NAME,ROTA,SCHED,RA | column -t"
  echo "  systemctl status fstrim.timer  # 如果使用 systemd"
}

main "$@"
