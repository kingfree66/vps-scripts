#!/bin/bash
#
# VPS 一键优化脚本
# 内容：
#   1. 开启 BBR + FQ
#   2. DNS 改为 1.1.1.1 / 8.8.8.8 并锁定
#   3. 开启 TCP Fast Open
#   4. 安装 curl（如缺失）
#   5. 检查防火墙并放行端口（调用 disable_firewall.sh）
#
# 用法：sudo bash vps_optimize.sh

set -e

# 必须 root 运行
if [ "$(id -u)" -ne 0 ]; then
    echo "请使用 root 用户运行本脚本"
    exit 1
fi

echo "========== 1/4 开启 BBR+FQ =========="
echo -e "net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr" > /etc/sysctl.d/99-bbr.conf
sysctl --system >/dev/null 2>&1
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc

echo ""
echo "========== 2/4 修改 DNS 为 1.1.1.1 和 8.8.8.8 并锁定 =========="
if [ -L /etc/resolv.conf ]; then
    # systemd-resolved 接管（软链接），用 resolved 配置（持久化，无需 chattr）
    mkdir -p /etc/systemd/resolved.conf.d
    printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\n' > /etc/systemd/resolved.conf.d/dns.conf
    systemctl restart systemd-resolved 2>/dev/null || true
    echo "已通过 systemd-resolved 设置 DNS"
else
    # 传统 /etc/resolv.conf，直接写入并锁定
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
    if chattr +i /etc/resolv.conf 2>/dev/null; then
        echo "已锁定 /etc/resolv.conf（chattr +i）"
    else
        echo "chattr 不可用，跳过锁定"
    fi
fi
echo "当前 DNS："
cat /etc/resolv.conf

echo ""
echo "========== 3/4 开启 TCP Fast Open =========="
if ! grep -q "^net.ipv4.tcp_fastopen=3" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null 2>&1
sysctl net.ipv4.tcp_fastopen

echo ""
echo "========== 4/4 安装 curl（如缺失） =========="
if ! command -v curl >/dev/null 2>&1; then
    echo "未检测到 curl，正在安装..."
    apt update && apt install -y curl
else
    echo "curl 已安装，跳过"
fi

echo ""
echo "========== 5/5 检查防火墙并放行端口 =========="
if command -v curl >/dev/null 2>&1; then
    bash <(curl -fsSL https://raw.githubusercontent.com/kingfree66/vps-scripts/main/disable_firewall.sh)
else
    echo "curl 不可用，跳过防火墙检查"
fi

echo ""
echo "========== 优化完成 =========="
