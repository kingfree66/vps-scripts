#!/usr/bin/env bash
#
# VPS 一键优化脚本
# 内容：
#   1. DNS 改为 1.1.1.1 / 8.8.8.8
#   2. 系统更新 + 安装常用工具
#   3. 设置时区
#   4. 开启 BBR + 内核网络参数优化
#   5. 提高文件描述符上限
#   6. NTP 时间同步
#   7. IPv6 处理（默认禁用，可配置）
#
# 用法：sudo bash vps_optimize.sh
# 可在下方"可配置项"修改 DNS、时区与 IPv6 策略

set -u

# ---------------- 可配置项 ----------------
DNS1="1.1.1.1"
DNS2="8.8.8.8"
TIMEZONE="Asia/Shanghai"   # 可改为 Asia/Taipei、UTC 等
DISABLE_IPV6="yes"         # 是否禁用 IPv6（yes/no）
# ------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行本脚本"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
has_systemctl() { command_exists systemctl; }

set_dns() {
    echo "---------- DNS ----------"
    log "目标 DNS：$DNS1 / $DNS2"
    if has_systemctl && systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log "检测到 systemd-resolved，使用 resolved.conf.d 配置"
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/vps-dns.conf <<EOF
[Resolve]
DNS=${DNS1} ${DNS2}
FallbackDNS=1.0.0.1 8.8.4.4
EOF
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf 2>/dev/null || true
        ok "systemd-resolved DNS 已更新"
    else
        if [ -f /etc/resolv.conf ]; then
            cp -f /etc/resolv.conf /etc/resolv.conf.bak
            log "已备份原 resolv.conf → /etc/resolv.conf.bak"
        fi
        chattr -i /etc/resolv.conf 2>/dev/null || true
        cat > /etc/resolv.conf <<EOF
# 由 vps_optimize.sh 生成
nameserver ${DNS1}
nameserver ${DNS2}
EOF
        ok "/etc/resolv.conf 已写入"
        warn "部分云厂商会通过 DHCP 覆盖 resolv.conf，若重启后被改回请检查"
    fi
    if command_exists getent; then
        if getent hosts one.one.one.one >/dev/null 2>&1; then
            ok "DNS 解析验证通过"
        else
            warn "DNS 验证未通过，请检查网络"
        fi
    fi
}

update_system() {
    echo "---------- 系统更新 + 常用工具 ----------"
    local os="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="$ID"
    fi
    case "$os" in
        ubuntu|debian|armbian|kali)
            apt-get update && apt-get upgrade -y -q && \
            apt-get install -y -q curl wget vim git htop net-tools dnsutils unzip ca-certificates ;;
        centos)
            (yum update -y -q && yum install -y -q curl wget vim git htop net-tools bind-utils unzip ca-certificates) 2>/dev/null || \
            (dnf update -y -q && dnf install -y -q curl wget vim git htop net-tools bind-utils unzip ca-certificates) ;;
        fedora|rhel|almalinux|rocky|ol|amzn)
            dnf update -y -q && dnf install -y -q curl wget vim git htop net-tools bind-utils unzip ca-certificates ;;
        arch|manjaro)
            pacman -Syu --noconfirm curl wget vim git htop net-tools dnsutils unzip ca-certificates ;;
        *)
            warn "未知发行版 [$os]，跳过更新" ;;
    esac
    ok "系统更新与工具安装完成"
}

set_timezone() {
    echo "---------- 时区 ----------"
    if command_exists timedatectl; then
        if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
            ok "时区已设为 $TIMEZONE（当前：$(date '+%Y-%m-%d %H:%M %Z')）"
        else
            warn "时区设置失败"
        fi
    else
        warn "无 timedatectl，跳过"
    fi
}

tune_kernel() {
    echo "---------- BBR + 内核网络优化 ----------"
    cat > /etc/sysctl.d/99-vps-optimize.conf <<'EOF'
# 由 vps_optimize.sh 生成
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_slow_start_after_idle = 0
fs.file-max = 1000000
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-vps-optimize.conf >/dev/null 2>&1 || true
    if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
        ok "BBR 已启用"
    else
        warn "BBR 未生效（内核需 ≥ 4.9，或当前环境不支持）"
    fi
    ok "内核网络参数已应用"
}

raise_limits() {
    echo "---------- 文件描述符上限 ----------"
    cat > /etc/security/limits.d/99-vps.conf <<'EOF'
# 由 vps_optimize.sh 生成
* soft nofile 1000000
* hard nofile 1000000
root soft nofile 1000000
root hard nofile 1000000
EOF
    ok "nofile 上限已设为 1000000（重新登录后生效）"
}

setup_ntp() {
    echo "---------- NTP 时间同步 ----------"
    local os="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os="$ID"
    fi
    if ! command_exists chronyd && ! command_exists chronyc; then
        log "安装 chrony..."
        case "$os" in
            ubuntu|debian|armbian|kali)
                apt-get update -qq && apt-get install -y -q chrony ;;
            centos)
                (yum install -y -q chrony) 2>/dev/null || dnf install -y -q chrony ;;
            fedora|rhel|almalinux|rocky|ol|amzn)
                dnf install -y -q chrony ;;
            arch|manjaro)
                pacman -S --noconfirm -q chrony ;;
            *)
                warn "未知发行版 [$os]，将尝试 systemd-timesyncd" ;;
        esac
    fi
    if command_exists chronyd; then
        if has_systemctl; then
            systemctl enable --now chronyd >/dev/null 2>&1 || \
            systemctl enable --now chrony >/dev/null 2>&1 || true
        fi
        sleep 2
        if command_exists chronyc && chronyc tracking >/dev/null 2>&1; then
            ok "chrony 运行中"
            chronyc tracking 2>/dev/null | grep -E "System time|Leap status" || true
        else
            ok "chrony 已启动"
        fi
    elif has_systemctl && systemctl list-unit-files 2>/dev/null | grep -q "systemd-timesyncd"; then
        systemctl enable --now systemd-timesyncd >/dev/null 2>&1 || true
        timedatectl set-ntp true >/dev/null 2>&1 || true
        ok "已启用 systemd-timesyncd"
    else
        warn "未找到可用的 NTP 方案，请手动配置"
    fi
}

handle_ipv6() {
    echo "---------- IPv6 ----------"
    if [ "$DISABLE_IPV6" = "yes" ]; then
        log "按配置禁用 IPv6..."
        cat > /etc/sysctl.d/99-vps-ipv6.conf <<'EOF'
# 由 vps_optimize.sh 生成
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        sysctl --system >/dev/null 2>&1 || true
        if [ ! -f /proc/net/if_inet6 ]; then
            ok "IPv6 已禁用"
        else
            warn "IPv6 未完全禁用，可能需要重启后生效"
        fi
    else
        rm -f /etc/sysctl.d/99-vps-ipv6.conf
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        ok "保持 IPv6 启用"
    fi
}

main() {
    need_root
    echo "============================================================"
    echo " VPS 一键优化脚本"
    echo " 1. DNS → ${DNS1} / ${DNS2}"
    echo " 2. 系统更新 + 常用工具"
    echo " 3. 时区 → ${TIMEZONE}"
    echo " 4. BBR + 内核网络优化"
    echo " 5. 文件描述符上限"
    echo " 6. NTP 时间同步"
    echo " 7. IPv6 处理（当前：$([ "$DISABLE_IPV6" = "yes" ] && echo 禁用 || echo 保持)）"
    echo "============================================================"
    read -rp "确认执行？输入 y 继续 [y/N]: " confirm
    case "$confirm" in
        y|Y) ;;
        *) warn "已取消。"; exit 0 ;;
    esac
    echo
    set_dns
    update_system
    set_timezone
    tune_kernel
    raise_limits
    setup_ntp
    handle_ipv6
    echo
    ok "全部完成！建议重启一次使所有优化完全生效。"
}

main "$@"
