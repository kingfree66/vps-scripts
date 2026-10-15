#!/usr/bin/env bash
#
# 一键关闭防火墙脚本
# 适用：新 VPS 初始化、测试环境、个人学习环境
# 支持：Ubuntu / Debian / CentOS / Rocky / AlmaLinux / openSUSE 等
#
# ⚠ 警告：请勿在生产环境直接运行！生产环境建议按需放行端口。
# 本脚本不会清空 iptables / nftables 底层规则，避免影响 Docker 网络。

set -u

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

NEED_DISABLE=0

log()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$*"; }

need_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "请使用 root 用户运行本脚本。"
        exit 1
    fi
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

service_exists() {
    command_exists systemctl || return 1
    systemctl list-unit-files 2>/dev/null | awk '{print $1}' | grep -qx "$1.service"
}

service_active() {
    command_exists systemctl || return 1
    systemctl is-active --quiet "$1" 2>/dev/null
}

check_ufw() {
    echo "---------- UFW ----------"
    if command_exists ufw; then
        local st
        st="$(ufw status 2>/dev/null || true)"
        echo "$st"
        if echo "$st" | grep -qi "Status: active"; then
            warn "UFW 正在运行"
            NEED_DISABLE=1
        else
            ok "UFW 未运行"
        fi
    else
        ok "未安装 ufw，跳过"
    fi
}

check_firewalld() {
    echo "---------- firewalld ----------"
    if service_exists firewalld || command_exists firewall-cmd; then
        if service_active firewalld; then
            warn "firewalld 正在运行"
            NEED_DISABLE=1
            if command_exists firewall-cmd; then
                echo "已放行端口：$(firewall-cmd --list-ports 2>/dev/null || echo 无)"
                echo "已放行服务：$(firewall-cmd --list-services 2>/dev/null || echo 无)"
            fi
        else
            ok "firewalld 未运行"
        fi
    else
        ok "未安装 firewalld，跳过"
    fi
}

check_nftables() {
    echo "---------- nftables ----------"
    if service_exists nftables; then
        if service_active nftables; then
            warn "nftables 服务正在运行"
            NEED_DISABLE=1
        else
            ok "nftables 服务未运行"
        fi
    else
        ok "未安装 nftables 服务，跳过"
    fi
    if command_exists nft; then
        local rules
        rules="$(nft list ruleset 2>/dev/null || true)"
        if [ -n "$rules" ]; then
            if echo "$rules" | grep -qi "docker"; then
                log "检测到 Docker 相关规则，本脚本不会清空 nftables 规则。"
            else
                warn "检测到 nftables 规则存在（本脚本不会自动清空）"
                NEED_DISABLE=1
            fi
        else
            ok "无 nftables 规则"
        fi
    fi
}

check_iptables() {
    echo "---------- iptables / ip6tables ----------"
    local cmd rules
    for cmd in iptables ip6tables; do
        if command_exists "$cmd"; then
            rules="$($cmd -L INPUT -n --line-numbers 2>/dev/null || true)"
            if [ -n "$rules" ]; then
                echo "$rules"
                if echo "$rules" | grep -Eiq "DROP|REJECT"; then
                    warn "检测到 $cmd INPUT 链存在 DROP/REJECT 规则（本脚本不会自动清空）"
                    NEED_DISABLE=1
                else
                    ok "$cmd INPUT 链无明显拦截规则"
                fi
            fi
        fi
    done
}

show_ports() {
    echo "---------- 监听端口 ----------"
    if command_exists ss; then
        ss -lntup 2>/dev/null || true
    elif command_exists netstat; then
        netstat -lntup 2>/dev/null || true
    else
        ok "无 ss / netstat，跳过"
    fi
}

disable_ufw() {
    command_exists ufw || { ok "无 ufw，跳过"; return; }
    log "正在关闭 ufw..."
    ufw disable >/dev/null 2>&1 || true
    if command_exists systemctl; then
        systemctl stop ufw >/dev/null 2>&1 || true
        systemctl disable ufw >/dev/null 2>&1 || true
    fi
    ok "ufw 已关闭"
}

disable_firewalld() {
    if ! service_exists firewalld && ! command_exists firewall-cmd; then
        ok "无 firewalld，跳过"; return
    fi
    log "正在关闭 firewalld..."
    if command_exists systemctl; then
        systemctl stop firewalld >/dev/null 2>&1 || true
        systemctl disable firewalld >/dev/null 2>&1 || true
    fi
    ok "firewalld 已关闭"
}

disable_nftables() {
    service_exists nftables || { ok "无 nftables 服务，跳过"; return; }
    log "正在关闭 nftables 服务（不清空规则）..."
    if command_exists systemctl; then
        systemctl stop nftables >/dev/null 2>&1 || true
        systemctl disable nftables >/dev/null 2>&1 || true
    fi
    ok "nftables 服务已关闭"
    warn "未执行 nft flush ruleset，Docker / 系统网络规则不受影响"
}

main() {
    need_root

    echo "============================================================"
    echo " 一键关闭防火墙脚本"
    echo " 适用：新 VPS 初始化 / 测试 / 学习环境"
    echo " ⚠ 生产环境请勿运行，建议按需放行端口"
    echo "============================================================"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        log "系统：${PRETTY_NAME:-unknown} / 内核：$(uname -r)"
    fi
    echo

    log "正在检测防火墙状态..."
    check_ufw
    check_firewalld
    check_nftables
    check_iptables
    show_ports
    echo

    if [ "$NEED_DISABLE" -eq 0 ]; then
        ok "未检测到运行中的防火墙，无需操作。"
        warn "若端口仍不通，请检查云厂商安全组 / 网络 ACL。"
        exit 0
    fi

    warn "即将关闭：ufw / firewalld / nftables 服务（不清空底层规则）"
    warn "如果正在 SSH 连接，请先确认云安全组已放行 SSH 端口！"
    read -rp "确认关闭？输入 y 继续 [y/N]: " confirm
    case "$confirm" in
        y|Y) log "开始关闭..." ;;
        *) warn "已取消。"; exit 0 ;;
    esac
    echo

    disable_ufw
    disable_firewalld
    disable_nftables

    echo
    ok "完成。云厂商安全组 / 网络 ACL 不受本脚本影响，需去控制台单独配置。"
    warn "生产环境请重新评估安全策略，不建议长期关闭防火墙。"
}

main "$@"
