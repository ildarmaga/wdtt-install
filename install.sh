#!/bin/bash
# WDTT one-line installer (3x-ui style)
# Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/USER/wdtt-install/main/install.sh)
#   bash install.sh install -p YOUR_PASSWORD --panel --xray
set -euo pipefail

VERSION="1.0.0"
LOG_FILE="/var/log/wdtt-install.log"
INSTALL_DIR="${WDTT_INSTALL_DIR:-/usr/local/wdtt}"
BUILD_DIR="${INSTALL_DIR}/src"
CONFIG_DIR="/etc/wdtt"
XRAY_CONFIG_DIR="/etc/wdtt-xray"
XRAY_BIN_DIR="/usr/local/wdtt-xray/bin"
XRAY_LOG_DIR="/var/log/wdtt-xray"
PANEL_PORT="${WDTT_PANEL_PORT:-2860}"
PANEL_BASE="${WDTT_PANEL_BASE:-/wdtt/}"

# Override before curl|bash to use your GitHub org/user
GITHUB_USER="${WDTT_GITHUB_USER:-ildarmaga}"
REPO_WDTT="${WDTT_REPO:-https://github.com/${GITHUB_USER}/wdtt.git}"
REPO_INSTALL="${WDTT_REPO_INSTALL:-https://github.com/${GITHUB_USER}/wdtt-install.git}"
BRANCH="${WDTT_BRANCH:-main}"

DTLS_PORT="${WDTT_DTLS_PORT:-56000}"
WG_PORT="${WDTT_WG_PORT:-56001}"
SSH_PORT="${WDTT_SSH_PORT:-22}"
IFACE="wdtt0"
IPT_COMMENT="WDTT_MANAGED"

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;34m'; plain='\033[0m'
info()  { echo -e "${green}[✓]${plain} $*"; echo "[OK] $*" >> "$LOG_FILE"; }
warn()  { echo -e "${yellow}[!]${plain} $*"; echo "[WARN] $*" >> "$LOG_FILE"; }
err()   { echo -e "${red}[✗]${plain} $*"; echo "[ERR] $*" >> "$LOG_FILE"; }
step()  { echo -e "${blue}[►]${plain} $*"; }

[[ $EUID -eq 0 ]] || { err "Запустите от root"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== WDTT install v${VERSION} $(date) ===" >> "$LOG_FILE"

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    *) err "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
  esac
}

ARCH="$(arch)"
GOARCH="$ARCH"
[[ "$ARCH" == "armv7" ]] && GOARCH=arm

detect_os() {
  if [[ -f /etc/os-release ]]; then . /etc/os-release; else err "Не удалось определить ОС"; exit 1; fi
  case "${ID:-}" in
    ubuntu|debian|linuxmint|pop) PKG_MGR=apt ;;
    centos|rhel|rocky|almalinux|fedora|oracle) PKG_MGR=dnf; command -v dnf >/dev/null || PKG_MGR=yum ;;
    arch|manjaro) PKG_MGR=pacman ;;
    *) err "Неподдерживаемый дистрибутив: ${ID:-unknown}"; exit 1 ;;
  esac
  info "ОС: ${PRETTY_NAME:-$ID} | arch: $ARCH"
}

pkg_install() {
  case "$PKG_MGR" in
    apt)  DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf)  dnf install -y "$@" ;;
    yum)  yum install -y "$@" ;;
    pacman) pacman -Sy --noconfirm --needed "$@" ;;
  esac
}

install_deps() {
  step "Установка зависимостей..."
  case "$PKG_MGR" in
    apt) pkg_install ca-certificates curl git iproute2 iptables procps psmisc unzip wget ;;
    dnf|yum) pkg_install ca-certificates curl git iproute iptables procps-ng psmisc unzip wget ;;
    pacman) pkg_install ca-certificates curl git iproute2 iptables procps-ng psmisc unzip wget ;;
  esac
  if command -v tc >/dev/null 2>&1; then
    info "tc (iproute2) — лимиты скорости VPN доступны"
  else
    warn "tc не найден — лимиты скорости пользователей работать не будут"
  fi
  if ! command -v go >/dev/null 2>&1; then
    case "$PKG_MGR" in
      apt) pkg_install golang-go 2>/dev/null || true ;;
      dnf|yum) pkg_install golang 2>/dev/null || true ;;
    esac
  fi
}

script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

TEMPLATES_DIR="$(script_dir)/templates"

detect_wan() {
  ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -1
}

setup_sysctl() {
  step "Настройка ip_forward..."
  mkdir -p /etc/sysctl.d
  cat > /etc/sysctl.d/99-wdtt.conf <<'EOF'
net.ipv4.ip_forward = 1
EOF
  sysctl -p /etc/sysctl.d/99-wdtt.conf >/dev/null 2>&1 || true
}

setup_firewall() {
  step "Настройка firewall и NAT..."
  command -v iptables >/dev/null || { warn "iptables не найден — NAT вручную"; return; }
  local wan; wan="$(detect_wan)"
  [[ -n "$wan" ]] || { warn "WAN не определён"; return; }
  for rule in \
    "INPUT -p udp --dport $DTLS_PORT" \
    "INPUT -p udp --dport $WG_PORT" \
    "INPUT -p tcp --dport $SSH_PORT"; do
    iptables -C $rule -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
      iptables -I $rule -m comment --comment "$IPT_COMMENT" -j ACCEPT
  done
  iptables -C FORWARD -i "$IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i "$IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
  iptables -C FORWARD -o "$IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -o "$IFACE" -m comment --comment "$IPT_COMMENT" -j ACCEPT
  iptables -t nat -C POSTROUTING -s 10.66.66.0/24 -o "$wan" -m comment --comment "$IPT_COMMENT" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 10.66.66.0/24 -o "$wan" -m comment --comment "$IPT_COMMENT" -j MASQUERADE
  info "NAT на $wan для 10.66.66.0/24"
}

clone_or_update() {
  local url="$1" dest="$2" local_fallback="${3:-}"
  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" fetch --depth 1 origin "$BRANCH" 2>>"$LOG_FILE" || true
    git -C "$dest" checkout -f "$BRANCH" 2>>"$LOG_FILE" || true
    git -C "$dest" pull --ff-only origin "$BRANCH" 2>>"$LOG_FILE" || true
    return 0
  fi
  rm -rf "$dest"
  if git clone --depth 1 -b "$BRANCH" "$url" "$dest" >>"$LOG_FILE" 2>&1; then
    return 0
  fi
  if [[ -n "$local_fallback" && -d "$local_fallback" ]]; then
    warn "Git clone не удался — использую локальные исходники: $local_fallback"
    cp -a "$local_fallback/." "$dest/"
    return 0
  fi
  err "Не удалось клонировать $url (создайте репозиторий на GitHub или укажите локальный путь)"
  return 1
}

download_release_binary() {
  local repo="$1" name="$2" dest="$3"
  local api url
  api="https://api.github.com/repos/${repo}/releases/latest"
  url="$(curl -fsSL "$api" | grep -oE "https://[^\"]+${name}[^\"]*linux-${ARCH}[^\"]*" | head -1 || true)"
  [[ -n "$url" ]] || return 1
  curl -fsSL "$url" -o "$dest"
  chmod +x "$dest"
}

build_server() {
  step "Установка wdtt-server..."
  local src="${BUILD_DIR}/wdtt"
  clone_or_update "$REPO_WDTT" "$src" "/root/wdtt"
  if download_release_binary "${GITHUB_USER}/wdtt" "wdtt-server" "/tmp/wdtt-server-dl" 2>/dev/null; then
    install -m 0755 /tmp/wdtt-server-dl /usr/local/bin/wdtt-server
    rm -f /tmp/wdtt-server-dl
    info "wdtt-server скачан из GitHub Releases"
    return
  fi
  command -v go >/dev/null || { err "Нет Go и нет release-бинарника. Установите golang или создайте Release"; exit 1; }
  CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags="-s -w" -o /usr/local/bin/wdtt-server "${src}/server.go"
  info "wdtt-server собран из исходников"
}

build_panel() {
  step "Установка wdtt-panel..."
  local src="${BUILD_DIR}/wdtt"
  clone_or_update "$REPO_WDTT" "$src" "/root/wdtt"
  local panel_src="${src}/panel"
  [[ -d "$panel_src" ]] || { err "Папка panel/ не найдена в репозитории wdtt"; exit 1; }
  if download_release_binary "${GITHUB_USER}/wdtt" "wdtt-panel" "/tmp/wdtt-panel-dl" 2>/dev/null; then
    install -m 0755 /tmp/wdtt-panel-dl /usr/local/bin/wdtt-panel
    rm -f /tmp/wdtt-panel-dl
    info "wdtt-panel скачан из GitHub Releases"
    return
  fi
  command -v go >/dev/null || { err "Нет Go для сборки панели"; exit 1; }
  (cd "$panel_src" && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/wdtt-panel .)
  info "wdtt-panel собран из исходников (panel/)"
}

write_passwords_json() {
  local pass="$1"
  mkdir -p "$CONFIG_DIR"
  if [[ -f "${CONFIG_DIR}/passwords.json" ]]; then
    warn "passwords.json уже есть — не перезаписываю"
    return
  fi
  cat > "${CONFIG_DIR}/passwords.json" <<EOF
{
  "main_password": "${pass}",
  "passwords": {},
  "devices": {}
}
EOF
  chmod 600 "${CONFIG_DIR}/passwords.json"
}

install_wdtt_service() {
  local pass="$1"
  cat > /etc/systemd/system/wdtt.service <<EOF
[Unit]
Description=WDTT VPN Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStartPre=-/usr/bin/env bash -c "ip link show ${IFACE} >/dev/null 2>&1 && ip link del ${IFACE} 2>/dev/null || true"
ExecStart=/usr/local/bin/wdtt-server -listen 0.0.0.0:${DTLS_PORT} -wg-port ${WG_PORT} -config-dir ${CONFIG_DIR} -password ${pass}
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable wdtt.service
}

install_xray_binary() {
  step "Установка Xray-core..."
  mkdir -p "$XRAY_BIN_DIR" "$XRAY_LOG_DIR" "$XRAY_CONFIG_DIR"
  local zip arch_zip url tmp
  case "$ARCH" in
    amd64) arch_zip="Xray-linux-64.zip" ;;
    arm64) arch_zip="Xray-linux-arm64-v8a.zip" ;;
    armv7) arch_zip="Xray-linux-arm32-v7a.zip" ;;
  esac
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)"
  [[ -n "$tag" ]] || tag="v26.4.25"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${arch_zip}"
  tmp="$(mktemp)"
  curl -fsSL "$url" -o "${tmp}.zip"
  unzip -oq "${tmp}.zip" -d "$tmp"
  install -m 0755 "$(find "$tmp" -name xray -type f | head -1)" "${XRAY_BIN_DIR}/xray-linux-amd64"
  rm -rf "$tmp" "${tmp}.zip"
  curl -fsSL -o "${XRAY_BIN_DIR}/geoip.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
  curl -fsSL -o "${XRAY_BIN_DIR}/geosite.dat" "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
  info "Xray ${tag} установлен"
}

install_xray_config() {
  if [[ -f "${XRAY_CONFIG_DIR}/config.json" ]]; then
    warn "config.json уже есть — пропускаю"
  else
    install -m 0644 "${TEMPLATES_DIR}/xray-config.json" "${XRAY_CONFIG_DIR}/config.json"
  fi
  mkdir -p "${XRAY_LOG_DIR}"
  touch "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log"
  chmod 644 "${XRAY_LOG_DIR}/access.log" "${XRAY_LOG_DIR}/error.log" 2>/dev/null || true
}

install_xray_rules() {
  install -m 0755 "${TEMPLATES_DIR}/wdtt-xray-rules.sh" /usr/local/bin/wdtt-xray-rules.sh
  cat > /etc/systemd/system/wdtt-xray.service <<EOF
[Unit]
Description=WDTT Xray routing (wdtt0 -> xray)
After=wdtt.service network-online.target
Requires=wdtt.service
BindsTo=wdtt.service

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${XRAY_BIN_DIR}
ExecStartPre=/usr/bin/env bash -c 'for i in \$(seq 1 30); do ip addr show ${IFACE} 2>/dev/null | grep -q "10.66.66.1" && exit 0; sleep 0.5; done; exit 1'
ExecStart=${XRAY_BIN_DIR}/xray-linux-amd64 run -c ${XRAY_CONFIG_DIR}/config.json
ExecStartPost=/usr/bin/env bash -c 'sleep 1; /usr/local/bin/wdtt-xray-rules.sh up'
ExecStopPost=-/usr/local/bin/wdtt-xray-rules.sh down
Restart=always
RestartSec=5
LimitNOFILE=65535
WorkingDirectory=${XRAY_LOG_DIR}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable wdtt-xray.service
}

install_panel_service() {
  cat > /etc/systemd/system/wdtt-panel.service <<EOF
[Unit]
Description=WDTT Web Panel
After=network-online.target wdtt.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/wdtt-panel
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable wdtt-panel.service
}

start_services() {
  step "Запуск сервисов..."
  systemctl restart wdtt.service
  sleep 2
  if [[ "$WITH_XRAY" == "1" ]]; then
    systemctl restart wdtt-xray.service || warn "wdtt-xray не запустился — настройте outbound в панели"
  fi
  if [[ "$WITH_PANEL" == "1" ]]; then
    systemctl restart wdtt-panel.service || true
  fi
}

print_summary() {
  local ip; ip="$(curl -4fsS ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  echo ""
  echo -e "${green}════════════════════════════════════════${plain}"
  echo -e "${green} WDTT установлен успешно${plain}"
  echo -e "${green}════════════════════════════════════════${plain}"
  echo "  DTLS : ${DTLS_PORT}/udp"
  echo "  WG   : ${WG_PORT}/udp"
  echo "  Пароль: ${WDTT_PASSWORD}"
  if [[ "$WITH_PANEL" == "1" ]]; then
    echo ""
    echo "  Панель: http://${ip}:${PANEL_PORT}${PANEL_BASE}"
    echo "  Логин : admin"
    echo "  Пароль: wdtt  (смените в настройках)"
  fi
  if [[ "$WITH_XRAY" == "1" ]]; then
    echo ""
    echo "  Xray: настройте outbounds в панели → Настройки Xray"
  fi
  echo ""
  echo "  Команды:"
  echo "    wdtt status"
  echo "    wdtt restart"
  echo "    wdtt uninstall"
  echo -e "${green}════════════════════════════════════════${plain}"
}

cmd_uninstall() {
  step "Удаление WDTT..."
  for u in wdtt-panel wdtt-xray wdtt; do
    systemctl stop "$u.service" 2>/dev/null || true
    systemctl disable "$u.service" 2>/dev/null || true
    rm -f "/etc/systemd/system/${u}.service"
  done
  systemctl daemon-reload
  pkill -x wdtt-server 2>/dev/null || true
  pkill -x wdtt-panel 2>/dev/null || true
  ip link del "$IFACE" 2>/dev/null || true
  rm -f /usr/local/bin/wdtt-server /usr/local/bin/wdtt-panel /usr/local/bin/wdtt-xray-rules.sh
  rm -rf /usr/local/wdtt-xray "$INSTALL_DIR"
  info "WDTT удалён (конфиги в /etc/wdtt сохранены)"
}

cmd_status() {
  for u in wdtt wdtt-xray wdtt-panel; do
    printf "  %-14s " "$u:"
    systemctl is-active "$u.service" 2>/dev/null || echo "не установлен"
  done
}

# ── parse args ──
WITH_PANEL=0
WITH_XRAY=0
WDTT_PASSWORD=""
CMD="install"

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) CMD=install ;;
    uninstall|remove) CMD=uninstall ;;
    status) CMD=status ;;
    -p|--password) WDTT_PASSWORD="$2"; shift ;;
    --panel) WITH_PANEL=1 ;;
    --xray) WITH_XRAY=1 ;;
    --direct) WITH_XRAY=0 ;;
    --port) PANEL_PORT="$2"; shift ;;
    --github-user) GITHUB_USER="$2"; REPO_WDTT="https://github.com/${GITHUB_USER}/wdtt.git"; shift ;;
    -h|--help)
      cat <<EOF
WDTT Installer v${VERSION}

Установка в одну строку (как 3x-ui):
  bash <(curl -Ls https://raw.githubusercontent.com/USER/wdtt-install/main/install.sh)

С опциями:
  bash install.sh install -p SECRET --xray --panel

Опции:
  -p, --password PASS   Главный пароль VPN (обязательно)
  --xray                Xray routing (по умолчанию включён)
  --direct              Без Xray, только прямой NAT
  --panel               Веб-панель (порт ${PANEL_PORT})
  --github-user USER    Ваш GitHub (репозиторий wdtt, по умолчанию: ${GITHUB_USER})
  status | uninstall

Переменные окружения:
  WDTT_GITHUB_USER, WDTT_REPO, WDTT_DTLS_PORT, WDTT_WG_PORT, WDTT_PANEL_PORT
EOF
      exit 0
      ;;
  esac
  shift
done

# xray по умолчанию (если не --direct)
[[ "$CMD" == "install" && "$WITH_XRAY" == "0" && "${WDTT_DIRECT:-0}" != "1" ]] && WITH_XRAY=1
# panel по умолчанию
[[ "$CMD" == "install" && "$WITH_PANEL" == "0" && "${WDTT_NO_PANEL:-0}" != "1" ]] && WITH_PANEL=1

case "$CMD" in
  status) cmd_status; exit 0 ;;
  uninstall) cmd_uninstall; exit 0 ;;
esac

if [[ -z "$WDTT_PASSWORD" ]]; then
  if [[ -t 0 ]]; then
    read -rsp "Главный пароль VPN: " WDTT_PASSWORD; echo
  else
    WDTT_PASSWORD="wdtt$(openssl rand -hex 4 2>/dev/null || echo 1234)"
    warn "Пароль не задан — сгенерирован: $WDTT_PASSWORD"
  fi
fi

detect_os
install_deps
mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
setup_sysctl
setup_firewall
build_server
write_passwords_json "$WDTT_PASSWORD"
install_wdtt_service "$WDTT_PASSWORD"

if [[ "$WITH_XRAY" == "1" ]]; then
  install_xray_binary
  install_xray_config
  install_xray_rules
fi

if [[ "$WITH_PANEL" == "1" ]]; then
  build_panel
  install_panel_service
fi

# Сохраняем установщик для wdtt uninstall / update
mkdir -p "$INSTALL_DIR"
cp -a "$(script_dir)/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/templates/wdtt-cli.sh" 2>/dev/null || true
install -m 0755 "$INSTALL_DIR/templates/wdtt-cli.sh" /usr/local/bin/wdtt

start_services
print_summary
