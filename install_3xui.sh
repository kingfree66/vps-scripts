#!/usr/bin/env bash
#
# 3x-ui 一键安装脚本（中文）
# 功能：安装 3x-ui 面板 + xray 核心，生成随机账号，配置 systemd 自启，可选 SSL
# 用法：sudo bash install_3xui.sh
#
# 可在下方"可配置项"修改 REPO / VERSION 切换来源与版本。

set -u

# ---------------- 可配置项 ----------------
REPO="MHSanaei/3x-ui"          # 官方仓库；如需镜像可改为镜像仓库名
VERSION="v3.11.0"              # v3.x 起端口冲突检测区分 TCP/UDP，支持 VLESS(TCP 443)+Hy2(UDP 443) 面板直接共存
INSTALL_DIR="/usr/local/x-ui"
SERVICE_FILE="/etc/systemd/system/x-ui.service"
# ------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PANEL_USER=""; PANEL_PASS=""; PANEL_PORT=""; PANEL_WEBPATH=""; SERVER_IP=""

log()  { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
ok()   { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
err()  { printf "${RED}[ERROR]${NC} %s\n" "$*"; }
die()  { err "$*"; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行本脚本"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
has_systemctl() { command_exists systemctl; }

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*)         echo "armv7" ;;
        armv6*)         echo "armv6" ;;
        *) die "不支持的 CPU 架构：$(uname -m)" ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        echo "$ID"
    else
        die "无法识别系统发行版"
    fi
}

install_deps() {
    local os="$1"
    log "安装依赖包..."
    case "$os" in
        ubuntu|debian|armbian|kali)
            apt-get update && apt-get install -y -q curl tar socat ca-certificates openssl cron ;;
        centos)
            yum install -y curl tar socat ca-certificates openssl cronie 2>/dev/null || \
            dnf install -y -q curl tar socat ca-certificates openssl cronie ;;
        fedora|rhel|almalinux|rocky|ol|amzn)
            dnf install -y -q curl tar socat ca-certificates openssl cronie ;;
        arch|manjaro)
            pacman -Syu --noconfirm curl tar socat ca-certificates openssl cronie ;;
        opensuse*)
            zypper -q install -y curl tar socat ca-certificates openssl cron ;;
        alpine)
            apk add curl tar socat ca-certificates openssl dcron ;;
        *)
            warn "未知发行版 [$os]，尝试按 Debian 系安装..."
            apt-get update && apt-get install -y -q curl tar socat ca-certificates openssl cron ;;
    esac || die "依赖安装失败"
    ok "依赖安装完成"
}

rand_str() {
    openssl rand -base64 32 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$1"
}

get_public_ip() {
    local ip url
    for url in https://api4.ipify.org https://ipv4.icanhazip.com https://4.ident.me; do
        ip="$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')"
        if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

install_acme() {
    if [ -x "$HOME/.acme.sh/acme.sh" ]; then
        log "acme.sh 已安装"
        return 0
    fi
    log "安装 acme.sh（用于 SSL 证书）..."
    cd "$HOME" || return 1
    if curl -s https://get.acme.sh | sh >/dev/null 2>&1; then
        ok "acme.sh 安装成功"
        return 0
    else
        warn "acme.sh 安装失败，将跳过 SSL 配置"
        return 1
    fi
}

install_xui() {
    local arch="$1"
    local url="https://github.com/${REPO}/releases/download/${VERSION}/x-ui-linux-${arch}.tar.gz"
    local tmpdir
    tmpdir="$(mktemp -d)"
    cd "$tmpdir" || die "无法进入临时目录"

    log "下载 3x-ui ${VERSION}（${arch}）..."
    log "地址：$url"
    curl -fL -o x-ui.tar.gz "$url" || die "下载失败，请检查版本号/仓库名/网络"

    has_systemctl && systemctl stop x-ui >/dev/null 2>&1 || true
    rm -rf "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR"
    tar zxf x-ui.tar.gz -C "$INSTALL_DIR" --strip-components=1
    # 兼容 tar 包内带 x-ui/ 子目录的情况
    if [ ! -x "$INSTALL_DIR/x-ui" ] && [ -d "$INSTALL_DIR/x-ui" ]; then
        mv "$INSTALL_DIR/x-ui"/* "$INSTALL_DIR"/
        rmdir "$INSTALL_DIR/x-ui" 2>/dev/null || true
    fi
    [ -x "$INSTALL_DIR/x-ui" ] || die "解压后未找到 x-ui 可执行文件"
    chmod +x "$INSTALL_DIR/x-ui" "$INSTALL_DIR/bin"/xray-linux-* 2>/dev/null || true
    mkdir -p /var/log/x-ui
    cd / && rm -rf "$tmpdir"
    ok "3x-ui 文件安装完成：$INSTALL_DIR"
}

install_mgmt_script() {
    log "安装 x-ui 管理脚本..."
    if curl -fsSL -o /usr/bin/x-ui "https://raw.githubusercontent.com/MHSanaei/3x-ui/main/x-ui.sh"; then
        chmod +x /usr/bin/x-ui
        ok "管理脚本已安装（命令：x-ui，支持 start/stop/restart/status/settings/update 等）"
    else
        warn "管理脚本下载失败，跳过（不影响面板运行）"
    fi
}

write_service() {
    if ! has_systemctl; then
        warn "未检测到 systemd，跳过服务安装（需手动启动 $INSTALL_DIR/x-ui）"
        return 1
    fi
    log "写入 systemd 服务..."
    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=x-ui Panel Service
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/x-ui
ExecStart=/usr/local/x-ui/x-ui
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_FILE"
    systemctl daemon-reload
    systemctl enable x-ui >/dev/null 2>&1
    ok "systemd 服务已安装并设为开机自启"
}

setup_credentials() {
    PANEL_USER="$(rand_str 10)"
    PANEL_PASS="$(rand_str 16)"
    PANEL_WEBPATH="$(rand_str 18)"
    local port_input
    read -rp "自定义面板端口？直接回车则随机 [1024-62000]: " port_input
    if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1 ] && [ "$port_input" -le 65535 ]; then
        PANEL_PORT="$port_input"
    else
        PANEL_PORT="$(shuf -i 1024-62000 -n 1)"
        log "使用随机端口：$PANEL_PORT"
    fi
    "$INSTALL_DIR/x-ui" setting -username "$PANEL_USER" -password "$PANEL_PASS" \
        -port "$PANEL_PORT" -webBasePath "$PANEL_WEBPATH" >/dev/null 2>&1
    ok "面板账号已设置为随机强密码"
}

ssl_domain() {
    local domain certdir
    read -rp "请输入已解析到本机的域名: " domain
    domain="$(echo "$domain" | tr -d ' ')"
    [ -z "$domain" ] && { warn "域名为空，跳过"; return; }
    install_acme || return
    has_systemctl && systemctl stop x-ui >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    if "$HOME/.acme.sh/acme.sh" --issue -d "$domain" --standalone --httpport 80 --force; then
        certdir="/root/cert/${domain}"
        mkdir -p "$certdir"
        "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
            --key-file "$certdir/privkey.pem" \
            --fullchain-file "$certdir/fullchain.pem" \
            --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
        chmod 600 "$certdir/privkey.pem" 2>/dev/null
        chmod 644 "$certdir/fullchain.pem" 2>/dev/null
        "$INSTALL_DIR/x-ui" cert -webCert "$certdir/fullchain.pem" \
            -webCertKey "$certdir/privkey.pem" >/dev/null 2>&1
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
        ok "域名证书配置成功（acme.sh 定时任务自动续期）"
    else
        warn "证书签发失败：请确认域名已解析到本机且 80 端口开放"
    fi
}

ssl_ip() {
    local ip="$1" certdir
    [ -z "$ip" ] && { warn "未获取到公网 IP，跳过"; return; }
    install_acme || return
    has_systemctl && systemctl stop x-ui >/dev/null 2>&1 || true
    "$HOME/.acme.sh/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1
    log "正在为 IP $ip 签发证书（约 6 天有效期，自动续期）..."
    if "$HOME/.acme.sh/acme.sh" --issue -d "$ip" --standalone \
        --server letsencrypt --certificate-profile shortlived --days 6 --force; then
        certdir="/root/cert/ip"
        mkdir -p "$certdir"
        "$HOME/.acme.sh/acme.sh" --installcert -d "$ip" \
            --key-file "$certdir/privkey.pem" \
            --fullchain-file "$certdir/fullchain.pem" \
            --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
        chmod 600 "$certdir/privkey.pem" 2>/dev/null
        chmod 644 "$certdir/fullchain.pem" 2>/dev/null
        "$INSTALL_DIR/x-ui" cert -webCert "$certdir/fullchain.pem" \
            -webCertKey "$certdir/privkey.pem" >/dev/null 2>&1
        "$HOME/.acme.sh/acme.sh" --upgrade --auto-upgrade >/dev/null 2>&1
        ok "IP 证书配置成功（acme.sh 定时任务自动续期）"
    else
        warn "证书签发失败：请确认 80 端口开放且可从公网访问（IP 证书走 shortlived 通道，需 acme.sh 为最新版）"
    fi
}

setup_ssl() {
    echo
    echo "---------- SSL 证书 ----------"
    echo "1) 跳过（稍后手动配置）"
    echo "2) Let's Encrypt 域名证书（需域名解析到本机，开放 80 端口）"
    echo "3) Let's Encrypt IP 证书（约 6 天有效期，自动续期，需开放 80 端口）"
    local choice
    read -rp "请选择 [1/2/3，默认 1]: " choice
    case "${choice:-1}" in
        2) ssl_domain ;;
        3) ssl_ip "$SERVER_IP" ;;
        *) log "跳过 SSL 配置" ;;
    esac
}

main() {
    need_root

    echo "============================================================"
    echo " 3x-ui 一键安装脚本"
    echo " 来源：${REPO}  版本：${VERSION}（可在脚本顶部修改）"
    echo "============================================================"

    local arch os
    arch="$(detect_arch)"
    os="$(detect_os)"
    log "系统：$os / 架构：$arch"

    install_deps "$os"
    install_xui "$arch"
    install_mgmt_script
    write_service || true
    setup_credentials

    SERVER_IP="$(get_public_ip || true)"
    [ -n "$SERVER_IP" ] && log "公网 IP：$SERVER_IP"

    setup_ssl

    "$INSTALL_DIR/x-ui" migrate >/dev/null 2>&1 || true

    if has_systemctl; then
        systemctl restart x-ui
        sleep 2
    else
        warn "无 systemd，请手动运行：$INSTALL_DIR/x-ui"
    fi

    echo
    echo "================ 面板安装完成 ================"
    echo "用户名：  $PANEL_USER"
    echo "密码：    $PANEL_PASS"
    echo "端口：    $PANEL_PORT"
    echo "入口路径：$PANEL_WEBPATH"
    echo "访问地址：https://${SERVER_IP:-<服务器IP>}:${PANEL_PORT}/${PANEL_WEBPATH}"
    echo "=============================================="
    echo "⚠ 请妥善保存以上登录信息！"
    if has_systemctl; then
        if systemctl is-active --quiet x-ui; then
            ok "x-ui 运行中"
        else
            warn "x-ui 未运行，可用 journalctl -u x-ui 查看日志"
        fi
    fi
}

main "$@"
