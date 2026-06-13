#!/bin/bash
# WDTT one-line installer (3x-ui style)
# Usage:
#   bash <(curl -Ls https://raw.githubusercontent.com/USER/wdtt-install/main/install.sh)
#   bash <(curl -Ls https://raw.githubusercontent.com/USER/wdtt-install/main/install.sh) install
#   bash install.sh install -p YOUR_PASSWORD   # свой пароль (опционально)
set -euo pipefail

INSTALLER_VERSION="1.3.5"
# Не перезаписывать при . /etc/os-release
readonly INSTALLER_VERSION
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

red='\033[0;31m'; green='\033[0;32m'; yellow='\033[0;33m'; blue='\033[0;34m'
cyan='\033[0;36m'; magenta='\033[0;35m'; bold='\033[1m'; dim='\033[2m'; plain='\033[0m'

ui_init_dims() {
  [[ -n "${UI_DIMS_INIT:-}" ]] && return
  UI_DIMS_INIT=1
  local cols="${COLUMNS:-80}"
  UI_W=52
  if (( cols < UI_W )); then UI_W=$(( cols > 42 ? cols : 42 )); fi
  if (( cols >= 70 )); then UI_W=58; fi
  UI_INNER=$(( UI_W - 2 ))
  UI_LABEL_W=14
  UI_VALUE_W=$(( UI_INNER - UI_LABEL_W - 3 ))
  if (( UI_VALUE_W < 12 )); then UI_VALUE_W=12; fi
}

ui_hline() {
  local w="$1"
  printf '%*s' "$w" '' | tr ' ' '─'
}

ui_pad_right() {
  local s="$1" w="$2"
  local n=${#s}
  if (( n >= w )); then
    echo "${s:0:w-1}…"
    return
  fi
  printf '%s%*s' "$s" $((w - n)) ''
}

ui_clear() { clear 2>/dev/null || printf '\033[H\033[J'; }

ui_banner() {
  ui_init_dims
  echo -e "${cyan}${bold}"
  cat <<'BANNER'
 __      __ ____ _____ _____
 \ \    / /|  _ \_   _|_   _|
  \ \/\/ / | | | || |   | |
   \    /  | |_| || |   | |
    \__/   |____/ |_|   |_|
BANNER
  echo -e "${plain}${dim}  VPN · Xray · Panel  │  installer v${INSTALLER_VERSION}${plain}"
  echo -e "${dim}  $(ui_hline "$((UI_W - 2))")${plain}"
  echo ""
}

ui_line() {
  ui_init_dims
  echo -e "${blue}$(ui_hline "$UI_W")${plain}"
}

ui_box_top() {
  ui_init_dims
  echo -e "${blue}┌$(ui_hline "$UI_INNER")┐${plain}"
}

ui_box_bot() {
  ui_init_dims
  echo -e "${blue}└$(ui_hline "$UI_INNER")┘${plain}"
}

ui_box_title() {
  ui_init_dims
  local padded
  padded="$(ui_pad_right " $1" "$UI_INNER")"
  printf "${blue}│${plain}${bold}%s${plain}${blue}│${plain}\n" "$padded"
}

ui_box_row() {
  ui_init_dims
  local label="$1" value="$2"
  local lp vp
  lp="$(ui_pad_right "$label" "$UI_LABEL_W")"
  vp="$(ui_pad_right "$value" "$UI_VALUE_W")"
  printf "${blue}│${plain}  ${dim}%s${plain} ${green}%s${plain}${blue}│${plain}\n" "$lp" "$vp"
}

ui_box_row_warn() {
  ui_init_dims
  local label="$1" value="$2"
  local lp vp
  lp="$(ui_pad_right "$label" "$UI_LABEL_W")"
  vp="$(ui_pad_right "$value" "$UI_VALUE_W")"
  printf "${blue}│${plain}  ${dim}%s${plain} ${yellow}%s${plain}${blue}│${plain}\n" "$lp" "$vp"
}

# bash <(curl ...) — stdin часто не TTY; читаем с /dev/tty
ui_attach_tty() {
  if [[ -t 0 ]]; then
    return 0
  fi
  if [[ -r /dev/tty ]]; then
    exec </dev/tty 2>/dev/null || return 1
    return 0
  fi
  return 1
}

ui_can_interactive() {
  [[ "$NO_MENU" != "1" ]] || return 1
  [[ -t 0 || -t 1 ]] && return 0
  [[ -r /dev/tty ]] && return 0
  return 1
}

ui_read_nav_key() {
  local key seq=""
  ui_attach_tty 2>/dev/null || true
  if ! IFS= read -rsn1 key 2>/dev/null; then
    echo "q"
    return
  fi
  [[ -z "$key" ]] && { echo "q"; return; }
  if [[ "$key" == $'\x1b' ]]; then
    IFS= read -rsn2 -t 0.05 seq 2>/dev/null || true
    case "$seq" in
      '[A') echo "up"; return ;;
      '[B') echo "down"; return ;;
      '[C') echo "right"; return ;;
      '[D') echo "left"; return ;;
    esac
    echo "esc"
    return
  fi
  case "$key" in
    $'\n'|$'\r') echo "enter"; return ;;
  esac
  echo "$key"
}

# Рисует только список пунктов (без clear — для обновления на месте)
ui_menu_draw_items() {
  local i hint
  for i in "${!UI_MENU_ITEMS[@]}"; do
    hint="${UI_MENU_HINTS[$i]:-}"
    if [[ "$i" -eq "$UI_MENU_SELECTED" ]]; then
      printf "  ${cyan}${bold}▶ [%d] %-24s${plain}" "$i" "${UI_MENU_ITEMS[$i]}"
    else
      printf "    ${dim}[%d]${plain} %-24s" "$i" "${UI_MENU_ITEMS[$i]}"
    fi
    [[ -n "$hint" ]] && printf " ${dim}%s${plain}" "$hint"
    printf '\033[K\n'
  done
  echo ""
  echo -e "  ${dim}↑↓ / WASD · Enter · 0-9 · q — выход${plain}\033[K"
  echo ""
}

# Интерактивное меню: ↑↓ / WASD, Enter, цифры, q — выход
# UI_MENU_ITEMS[], UI_MENU_HINTS[], UI_MENU_SELECTED, UI_MENU_RESULT
ui_menu_interact() {
  local count=${#UI_MENU_ITEMS[@]}
  (( count > 0 )) || return 1
  UI_MENU_SELECTED=0
  UI_MENU_RESULT=""
  # строк на блок меню: пункты + пустая + подсказка + пустая
  local menu_block_lines=$(( count + 3 ))

  ui_menu_draw_items

  while true; do
    local nav
    nav="$(ui_read_nav_key)"
    case "$nav" in
      up|w|W|k|K)
        if (( UI_MENU_SELECTED > 0 )); then
          ((UI_MENU_SELECTED--))
          printf '\033[%dA' "$menu_block_lines"
          ui_menu_draw_items
        fi
        ;;
      down|s|S|j|J)
        if (( UI_MENU_SELECTED < count - 1 )); then
          ((UI_MENU_SELECTED++))
          printf '\033[%dA' "$menu_block_lines"
          ui_menu_draw_items
        fi
        ;;
      enter)
        UI_MENU_RESULT="$UI_MENU_SELECTED"
        return 0
        ;;
      q|Q|esc)
        return 255
        ;;
      [0-9])
        if (( nav < count )); then
          UI_MENU_RESULT="$nav"
          return 0
        fi
        ;;
    esac
  done
}

ui_draw_menu_header() {
  local os_name ver
  os_name="${PRETTY_NAME:-Linux}"
  ver="—"
  is_wdtt_installed && ver="$(get_installed_version)"
  ui_box_top
  ui_box_title "Главное меню WDTT"
  if is_wdtt_installed; then
    ui_box_row "Статус" "Установлен"
    ui_box_row "Версия" "$ver"
  else
    ui_box_row_warn "Статус" "Не установлен"
  fi
  ui_box_row "Система" "$os_name"
  ui_box_row "Архитектура" "$ARCH"
  ui_box_bot
  echo ""
  ui_line
  echo ""
}

ui_show_help() {
  ui_clear
  ui_banner
  ui_box_top
  ui_box_title "Справка"
  ui_box_bot
  echo ""
  ui_kv "Установка" "bash <(curl -Ls .../install.sh)"
  ui_kv "Меню" "bash .../install.sh menu  или  wdtt menu"
  ui_kv "Обновление" "wdtt update"
  ui_kv "Статус" "wdtt status"
  ui_kv "Логи" "wdtt log"
  ui_kv "CLI" "wdtt restart | stop | start | uninstall"
  echo ""
  ui_kv "Опции" "--password, --direct, --no-panel"
  ui_kv "Версия" "install update --version v1.2.4"
  ui_kv "Авто" "install --no-menu"
  echo ""
  ui_press_enter
}

cmd_restart_services() {
  step "Перезапуск сервисов..."
  systemctl restart wdtt.service 2>/dev/null || warn "wdtt не запущен"
  sleep 1
  systemctl restart wdtt-xray.service 2>/dev/null || true
  systemctl restart wdtt-panel.service 2>/dev/null || true
  info "Сервисы перезапущены"
}

cmd_logs_tail() {
  ui_box_top
  ui_box_title "Последние логи (25 строк)"
  ui_box_bot
  echo ""
  journalctl -u wdtt -u wdtt-xray -u wdtt-panel -n 25 --no-pager 2>/dev/null || warn "journalctl недоступен"
  echo ""
  ui_press_enter
}

ui_confirm() {
  local prompt="$1"
  local c
  ui_attach_tty 2>/dev/null || true
  read -rp "$(echo -e "  ${yellow}⚠${plain} ${prompt} ${dim}[y/N]${plain}: ")" c
  [[ "${c,,}" == "y" || "${c,,}" == "yes" || "${c,,}" == "д" || "${c,,}" == "да" ]]
}

ui_prompt_password() {
  echo ""
  ui_attach_tty 2>/dev/null || true
  read -rsp "$(echo -e "  ${cyan}▸${plain} VPN пароль: ")" WDTT_PASSWORD
  echo ""
  [[ -n "$WDTT_PASSWORD" ]]
}

ui_menu_opt() {
  local n="$1" label="$2" hint="${3:-}"
  if [[ -n "$hint" ]]; then
    printf "  ${cyan}${bold}[%s]${plain} %-20s ${dim}%s${plain}\n" "$n" "$label" "$hint"
  else
    printf "  ${cyan}${bold}[%s]${plain} %s\n" "$n" "$label"
  fi
}

ui_spinner_step() {
  local n="$1" total="$2" msg="$3"
  echo -e "  ${blue}[${n}/${total}]${plain} ${msg}"
}

ui_success_box() {
  local title="$1"
  echo ""
  ui_box_top
  ui_box_title "$title"
  ui_box_bot
}

ui_kv() {
  printf "  ${dim}%-14s${plain} ${bold}%s${plain}\n" "$1" "$2"
}

ui_press_enter() {
  echo ""
  ui_attach_tty 2>/dev/null || true
  read -rp "$(echo -e "${dim}  Нажмите Enter для продолжения...${plain}")" _
}

info()  { echo -e "  ${green}✔${plain} $*"; echo "[OK] $*" >> "$LOG_FILE"; }
warn()  { echo -e "  ${yellow}⚠${plain} $*"; echo "[WARN] $*" >> "$LOG_FILE"; }
err()   { echo -e "  ${red}✗${plain} $*"; echo "[ERR] $*" >> "$LOG_FILE"; }
step()  { echo -e "  ${blue}▶${plain} $*"; }

INSTALL_TOTAL_STEPS=8
INSTALL_STEP=0
step_progress() {
  ((INSTALL_STEP++)) || true
  ui_spinner_step "$INSTALL_STEP" "$INSTALL_TOTAL_STEPS" "$1"
}

[[ $EUID -eq 0 ]] || { err "Запустите от root"; exit 1; }
mkdir -p "$(dirname "$LOG_FILE")"
echo "=== WDTT install v${INSTALLER_VERSION} $(date) ===" >> "$LOG_FILE"

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
  local id pretty
  if [[ -f /etc/os-release ]]; then
    pretty="$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')"
    id="$(grep -E '^ID=' /etc/os-release 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"')"
    PRETTY_NAME="${pretty:-Linux}"
    ID="${id:-unknown}"
  else
    err "Не удалось определить ОС"
    exit 1
  fi
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
  case "$src" in
    /dev/fd/*|/proc/*/fd/*)
      echo "$INSTALL_DIR"
      return 0
      ;;
  esac
  while [ -L "$src" ]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ $src != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

is_piped_install() {
  case "${BASH_SOURCE[0]}" in
    /dev/fd/*|/proc/*/fd/*) return 0 ;;
  esac
  return 1
}

TEMPLATES_DIR="${INSTALL_DIR}/templates"

ensure_install_tree() {
  mkdir -p "$INSTALL_DIR" "$BUILD_DIR"
  if [[ -f "${TEMPLATES_DIR}/xray-config.json" && -f "${TEMPLATES_DIR}/wdtt-cli.sh" ]]; then
    return 0
  fi
  if is_piped_install; then
    step "Загрузка wdtt-install (шаблоны)..."
    clone_or_update "$REPO_INSTALL" "$INSTALL_DIR" ""
  else
    local dir; dir="$(script_dir)"
    cp -a "${dir}/." "$INSTALL_DIR/"
  fi
  [[ -f "${TEMPLATES_DIR}/xray-config.json" ]] || { err "Шаблоны не найдены в ${TEMPLATES_DIR}"; exit 1; }
}

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

# Последний GitHub Release (не привязан к версии install.sh — всегда releases/latest).
WDTT_RELEASE_TAG=""
SELECTED_TAG=""

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 2>/dev/null | tr -dc 'A-Za-z0-9' | head -c 16
    return 0
  fi
  echo "wdtt$(date +%s | tail -c 8)"
}

read_existing_password() {
  if [[ -f /etc/systemd/system/wdtt.service ]]; then
    grep -oP '(?<=-password )\S+' /etc/systemd/system/wdtt.service 2>/dev/null | head -1
  fi
}

get_installed_version() {
  if [[ -x /usr/local/bin/wdtt-panel ]]; then
    local v; v="$(/usr/local/bin/wdtt-panel -version 2>/dev/null || true)"
    [[ -n "$v" && "$v" != "dev" ]] && echo "$v" && return 0
  fi
  echo "unknown"
}

is_wdtt_installed() {
  [[ -x /usr/local/bin/wdtt-server || -x /usr/local/bin/wdtt-panel ]] && \
    systemctl list-unit-files wdtt.service 2>/dev/null | grep -q '^wdtt\.service'
}

fetch_release_tags() {
  local limit="${1:-20}"
  curl -fsSL "https://api.github.com/repos/${GITHUB_USER}/wdtt/releases?per_page=${limit}" 2>/dev/null | \
    grep -oP '"tag_name":\s*"\K[^"]+' || true
}

pick_release_version() {
  local -a tags=()
  local tag current i choice mark label

  mapfile -t tags < <(fetch_release_tags 20)
  if [[ ${#tags[@]} -eq 0 ]]; then
    err "Не удалось получить список версий с GitHub (${GITHUB_USER}/wdtt)"
    exit 1
  fi

  current="$(get_installed_version)"

  if [[ -n "${WDTT_VERSION:-}" ]]; then
    for tag in "${tags[@]}"; do
      if [[ "$tag" == "${WDTT_VERSION}" || "$tag" == "v${WDTT_VERSION}" ]]; then
        SELECTED_TAG="$tag"
        info "Версия из WDTT_VERSION: ${SELECTED_TAG}"
        return 0
      fi
    done
    SELECTED_TAG="${WDTT_VERSION}"
    info "Версия из WDTT_VERSION: ${SELECTED_TAG}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    SELECTED_TAG="${tags[0]}"
    info "Неинтерактивный режим — выбрана latest: ${SELECTED_TAG}"
    return 0
  fi

  local pick=0
  while true; do
    ui_clear
    ui_banner
    ui_box_top
    ui_box_title "Обновление WDTT"
    ui_box_bot
    echo ""
    ui_kv "Текущая" "${current}"
    ui_kv "Latest" "${tags[0]}"
    echo ""
    ui_line
    echo -e "  ${bold}Выберите версию:${plain}"
    echo ""

    local i mark label
    i=0
    for tag in "${tags[@]}"; do
      mark=""
      label="$tag"
      [[ "$tag" == "$current" || "$tag" == "v${current}" ]] && mark="${green}● установлена${plain}"
      [[ "$i" -eq 0 ]] && mark="${mark}${mark:+ · }${cyan}latest${plain}"
      if [[ "$i" -eq "$pick" ]]; then
        printf "  ${cyan}${bold}▶ %2d)${plain} %-14s %b\n" "$((i+1))" "$label" "$mark"
      else
        printf "    ${dim}%2d)${plain} %-14s %b\n" "$((i+1))" "$label" "$mark"
      fi
      ((i++)) || true
    done
    echo ""
    if [[ "$pick" -eq -1 ]]; then
      printf "  ${cyan}${bold}▶ [0]${plain} Отмена\n"
    else
      ui_menu_opt "0" "Отмена"
    fi
    echo ""
    ui_line
    echo -e "  ${dim}↑↓ / WASD · Enter · цифра · q — назад${plain}"
    echo ""

    local nav
    nav="$(ui_read_nav_key)"
    case "$nav" in
      up|w|W|k|K)
        if (( pick < 0 )); then pick=$((${#tags[@]}-1))
        elif (( pick > 0 )); then ((pick--))
        else pick=-1
        fi
        continue
        ;;
      down|s|S|j|J)
        if (( pick < 0 )); then pick=0
        elif (( pick < ${#tags[@]}-1 )); then ((pick++))
        else pick=-1
        fi
        continue
        ;;
      enter)
        if (( pick < 0 )); then echo -e "  ${dim}Отменено.${plain}"; exit 0; fi
        SELECTED_TAG="${tags[$pick]}"
        info "Выбрано: ${SELECTED_TAG}"
        sleep 0.3
        return 0
        ;;
      q|Q|esc)
        echo -e "  ${dim}Отменено.${plain}"
        exit 0
        ;;
      0)
        echo -e "  ${dim}Отменено.${plain}"
        exit 0
        ;;
      [1-9])
        if (( nav >= 1 && nav <= ${#tags[@]} )); then
          SELECTED_TAG="${tags[$((nav-1))]}"
          info "Выбрано: ${SELECTED_TAG}"
          sleep 0.3
          return 0
        fi
        ;;
    esac
  done
}

show_main_menu() {
  ui_clear
  ui_banner
  ui_draw_menu_header
}

run_interactive_menu() {
  ui_attach_tty || { err "Нужен интерактивный терминал (SSH)"; exit 1; }
  detect_os 2>/dev/null || true
  # /etc/os-release может содержать VERSION= — не даём затереть INSTALLER_VERSION
  while true; do
    UI_MENU_ITEMS=()
    UI_MENU_HINTS=()

    if is_wdtt_installed; then
      UI_MENU_ITEMS=(
        "Обновить"
        "Переустановить"
        "Перезапустить сервисы"
        "Статус сервисов"
        "Последние логи"
        "Удалить WDTT"
        "Справка"
        "Выход"
      )
      UI_MENU_HINTS=(
        "выбор версии GitHub"
        "новый пароль, xray + panel"
        "wdtt restart"
        ""
        "journalctl -n 25"
        "конфиги /etc/wdtt сохранятся"
        ""
        ""
      )
    else
      UI_MENU_ITEMS=(
        "Установить"
        "Установить со своим паролем"
        "Установить без Xray"
        "Установить без панели"
        "Статус сервисов"
        "Справка"
        "Выход"
      )
      UI_MENU_HINTS=(
        "xray + panel + auto password"
        "ввести VPN пароль"
        "только NAT, --direct"
        "только VPN + server"
        ""
        ""
        ""
      )
    fi

    show_main_menu
    ui_menu_interact || { echo -e "  ${dim}Выход.${plain}"; exit 0; }
    choice="$UI_MENU_RESULT"

    if is_wdtt_installed; then
      case "$choice" in
        0) CMD=update; return 0 ;;
        1) CMD=install; FORCE_INSTALL=1; return 0 ;;
        2) ui_clear; ui_banner; cmd_restart_services; ui_press_enter; continue ;;
        3) ui_clear; ui_banner; cmd_status_pretty; ui_press_enter; continue ;;
        4) ui_clear; ui_banner; cmd_logs_tail; continue ;;
        5)
          ui_confirm "Удалить WDTT?" && { cmd_uninstall; ui_press_enter; }
          continue
          ;;
        6) ui_show_help; continue ;;
        7) echo -e "  ${dim}Выход.${plain}"; exit 0 ;;
      esac
    else
      case "$choice" in
        0) CMD=install; return 0 ;;
        1)
          ui_prompt_password || { warn "Пароль не задан"; ui_press_enter; continue; }
          CMD=install
          return 0
          ;;
        2) WITH_XRAY=0; XRAY_MODE_SET=1; CMD=install; return 0 ;;
        3) WITH_PANEL=0; PANEL_MODE_SET=1; CMD=install; return 0 ;;
        4) ui_clear; ui_banner; cmd_status_pretty; ui_press_enter; continue ;;
        5) ui_show_help; continue ;;
        6) echo -e "  ${dim}Выход.${plain}"; exit 0 ;;
      esac
    fi
  done
}

download_release_binary() {
  local repo="$1" name="$2" dest="$3" tag="${4:-latest}"
  local api json url
  if [[ "$tag" == "latest" ]]; then
    api="https://api.github.com/repos/${repo}/releases/latest"
  else
    api="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi
  json="$(curl -fsSL "$api" 2>/dev/null)" || return 1
  tag="$(echo "$json" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || true)"
  url="$(echo "$json" | grep -oE "https://[^\"]+${name}[^\"]*linux-${ARCH}[^\"]*" | head -1 || true)"
  [[ -n "$url" ]] || return 1
  curl -fsSL "$url" -o "$dest"
  chmod +x "$dest"
  [[ -n "$tag" ]] && WDTT_RELEASE_TAG="$tag"
  return 0
}

build_server() {
  local tag="${1:-latest}"
  step "Установка wdtt-server${tag:+ (${tag})}..."
  local src="${BUILD_DIR}/wdtt"
  clone_or_update "$REPO_WDTT" "$src" "/root/wdtt"
  if download_release_binary "${GITHUB_USER}/wdtt" "wdtt-server" "/tmp/wdtt-server-dl" "$tag" 2>/dev/null; then
    install -m 0755 /tmp/wdtt-server-dl /usr/local/bin/wdtt-server
    rm -f /tmp/wdtt-server-dl
    info "wdtt-server скачан из GitHub Releases (${WDTT_RELEASE_TAG:-latest})"
    return
  fi
  command -v go >/dev/null || { err "Нет Go и нет release-бинарника. Установите golang или создайте Release"; exit 1; }
  (cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags="-s -w" -o /usr/local/bin/wdtt-server .)
  info "wdtt-server собран из исходников (fallback)"
}

build_panel() {
  local tag="${1:-latest}"
  step "Установка wdtt-panel${tag:+ (${tag})}..."
  local src="${BUILD_DIR}/wdtt"
  clone_or_update "$REPO_WDTT" "$src" "/root/wdtt"
  local panel_src="${src}/panel"
  [[ -d "$panel_src" ]] || { err "Папка panel/ не найдена в репозитории wdtt"; exit 1; }
  if download_release_binary "${GITHUB_USER}/wdtt" "wdtt-panel" "/tmp/wdtt-panel-dl" "$tag" 2>/dev/null; then
    install -m 0755 /tmp/wdtt-panel-dl /usr/local/bin/wdtt-panel
    rm -f /tmp/wdtt-panel-dl
    info "wdtt-panel скачан из GitHub Releases (${WDTT_RELEASE_TAG:-latest})"
    return
  fi
  command -v go >/dev/null || { err "Нет Go для сборки панели"; exit 1; }
  (cd "$panel_src" && CGO_ENABLED=0 GOOS=linux GOARCH="$GOARCH" go build -trimpath -ldflags="-s -w" -o /usr/local/bin/wdtt-panel .)
  info "wdtt-panel собран из исходников (fallback)"
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
  local zip arch_zip url tmpdir zipfile xray_bin
  case "$ARCH" in
    amd64) arch_zip="Xray-linux-64.zip" ;;
    arm64) arch_zip="Xray-linux-arm64-v8a.zip" ;;
    armv7) arch_zip="Xray-linux-arm32-v7a.zip" ;;
  esac
  local tag
  tag="$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+' | head -1)"
  [[ -n "$tag" ]] || tag="v26.4.25"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${arch_zip}"
  tmpdir="$(mktemp -d /tmp/wdtt-xray.XXXXXX)" || { err "не удалось создать временный каталог"; return 1; }
  zipfile="${tmpdir}/xray.zip"
  extract="${tmpdir}/extract"
  trap 'rm -rf "$tmpdir"' RETURN
  curl -fsSL "$url" -o "$zipfile"
  mkdir -p "$extract"
  unzip -oq "$zipfile" -d "$extract" || { err "распаковка ${arch_zip} не удалась (проверьте unzip и место в /tmp)"; return 1; }
  xray_bin="$(find "$extract" -name xray -type f | head -1)"
  [[ -n "$xray_bin" ]] || { err "xray binary not found in ${arch_zip}"; return 1; }
  install -m 0755 "$xray_bin" "${XRAY_BIN_DIR}/xray-linux-amd64"
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
Environment=HOME=/root
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
  local ip svc
  ip="$(curl -4fsS ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  ui_clear
  ui_banner
  ui_success_box "Установка завершена успешно"
  echo ""
  ui_kv "DTLS порт" "${DTLS_PORT}/udp"
  ui_kv "WG порт" "${WG_PORT}/udp"
  ui_kv "VPN пароль" "${WDTT_PASSWORD}"
  if [[ "$WITH_PANEL" == "1" ]]; then
    echo ""
    ui_kv "Панель" "http://${ip}:${PANEL_PORT}${PANEL_BASE}"
    ui_kv "Логин" "admin"
    ui_kv "Пароль" "wdtt  ${dim}(смените в настройках)${plain}"
  fi
  if [[ "$WITH_XRAY" == "1" ]]; then
    echo ""
    ui_kv "Xray" "настройте outbounds в панели"
  fi
  echo ""
  ui_line
  echo -e "  ${bold}Сервисы:${plain}"
  for svc in wdtt wdtt-xray wdtt-panel; do
    local st; st="$(systemctl is-active "${svc}.service" 2>/dev/null || echo inactive)"
    if [[ "$st" == "active" ]]; then
      printf "    ${green}●${plain} %-12s ${green}running${plain}\n" "$svc"
    else
      printf "    ${dim}○${plain} %-12s ${dim}%s${plain}\n" "$svc" "$st"
    fi
  done
  echo ""
  ui_line
  echo -e "  ${dim}Команды:${plain}  ${cyan}wdtt status${plain} · ${cyan}wdtt update${plain} · ${cyan}wdtt restart${plain}"
  echo ""
}

print_update_summary() {
  local ip ver svc
  ip="$(curl -4fsS ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
  ver="$(get_installed_version)"
  ui_clear
  ui_banner
  ui_success_box "Обновление завершено"
  echo ""
  ui_kv "Версия" "${WDTT_RELEASE_TAG:-$SELECTED_TAG}"
  ui_kv "Panel" "${ver}"
  if [[ -n "${WDTT_PASSWORD:-}" ]]; then
    ui_kv "VPN пароль" "${WDTT_PASSWORD} ${dim}(без изменений)${plain}"
  fi
  if [[ "$WITH_PANEL" == "1" ]]; then
    ui_kv "Панель" "http://${ip}:${PANEL_PORT}${PANEL_BASE}"
  fi
  echo ""
  ui_line
  echo -e "  ${bold}Сервисы:${plain}"
  for svc in wdtt wdtt-xray wdtt-panel; do
    local st; st="$(systemctl is-active "${svc}.service" 2>/dev/null || echo inactive)"
    if [[ "$st" == "active" ]]; then
      printf "    ${green}●${plain} %-12s ${green}running${plain}\n" "$svc"
    else
      printf "    ${dim}○${plain} %-12s ${dim}%s${plain}\n" "$svc" "$st"
    fi
  done
  echo ""
  ui_line
  echo -e "  ${dim}Команды:${plain}  ${cyan}wdtt status${plain} · ${cyan}wdtt update${plain} · ${cyan}wdtt restart${plain}"
  echo ""
}

cmd_update() {
  ui_clear
  ui_banner
  ui_box_top
  ui_box_title "Обновление компонентов"
  ui_box_bot
  echo ""
  WDTT_PASSWORD="$(read_existing_password)"
  [[ -n "$WDTT_PASSWORD" ]] || WDTT_PASSWORD="$(gen_password)"

  pick_release_version

  ui_clear
  ui_banner
  ui_box_top
  ui_box_title "Загрузка ${SELECTED_TAG}"
  ui_box_bot
  echo ""

  build_server "$SELECTED_TAG"
  if [[ "$WITH_PANEL" == "1" ]]; then
    build_panel "$SELECTED_TAG"
    install_panel_service
  fi

  if [[ -f "${TEMPLATES_DIR}/wdtt-xray-rules.sh" ]]; then
    step "Обновление правил xray..."
    install -m 0755 "${TEMPLATES_DIR}/wdtt-xray-rules.sh" /usr/local/bin/wdtt-xray-rules.sh
    /usr/local/bin/wdtt-xray-rules.sh up 2>/dev/null || true
    info "Правила xray обновлены"
  fi

  if [[ "$WITH_XRAY" == "1" ]]; then
    if [[ ! -x "${XRAY_BIN_DIR}/xray-linux-amd64" ]]; then
      install_xray_binary
      install_xray_config
    fi
    install_xray_rules
  fi

  ensure_install_tree
  chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/templates/wdtt-cli.sh" 2>/dev/null || true
  install -m 0755 "$INSTALL_DIR/templates/wdtt-cli.sh" /usr/local/bin/wdtt

  step "Перезапуск сервисов..."
  start_services
  print_update_summary
}

cmd_uninstall() {
  ui_clear
  ui_banner
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

cmd_status_pretty() {
  local u st
  ui_box_top
  ui_box_title "Статус сервисов"
  ui_box_bot
  echo ""
  for u in wdtt wdtt-xray wdtt-panel; do
    st="$(systemctl is-active "${u}.service" 2>/dev/null || echo "не установлен")"
    if [[ "$st" == "active" ]]; then
      printf "    ${green}●${plain} %-14s ${green}%s${plain}\n" "$u" "$st"
    elif [[ "$st" == "не установлен" ]]; then
      printf "    ${dim}○${plain} %-14s ${dim}%s${plain}\n" "$u" "$st"
    else
      printf "    ${yellow}●${plain} %-14s ${yellow}%s${plain}\n" "$u" "$st"
    fi
  done
  echo ""
  if is_wdtt_installed; then
    ui_kv "Версия" "$(get_installed_version)"
  fi
  echo ""
}

cmd_status() {
  ui_clear
  ui_banner
  cmd_status_pretty
}

# ── parse args ──
ORIG_ARGC=$#
WITH_PANEL=""
WITH_XRAY=""
WDTT_PASSWORD=""
CMD="install"
FORCE_INSTALL=0
NO_MENU=0
XRAY_MODE_SET=0
PANEL_MODE_SET=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    install) CMD=install ;;
    update) CMD=update ;;
    menu) CMD=menu ;;
    uninstall|remove) CMD=uninstall ;;
    status) CMD=status ;;
    -p|--password) WDTT_PASSWORD="$2"; shift ;;
    --panel) WITH_PANEL=1; PANEL_MODE_SET=1 ;;
    --xray) WITH_XRAY=1; XRAY_MODE_SET=1 ;;
    --direct) WITH_XRAY=0; XRAY_MODE_SET=1 ;;
    --no-panel) WITH_PANEL=0; PANEL_MODE_SET=1 ;;
    --force) FORCE_INSTALL=1 ;;
    --no-menu) NO_MENU=1 ;;
    --version) WDTT_VERSION="$2"; shift ;;
    --port) PANEL_PORT="$2"; shift ;;
    --github-user) GITHUB_USER="$2"; REPO_WDTT="https://github.com/${GITHUB_USER}/wdtt.git"; shift ;;
    -h|--help)
      cat <<EOF
WDTT Installer v${INSTALLER_VERSION}

Установка (SHA обходит CDN-кэш GitHub):
  SHA=\$(curl -fsSL https://api.github.com/repos/${GITHUB_USER}/wdtt-install/commits/main | sed -n 's/.*"sha": "\\([0-9a-f]\\{40\\}\\)".*/\\1/p' | head -1)
  bash <(curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/wdtt-install/\${SHA}/install.sh")

Меню: wdtt menu  (всегда свежий скрипт с GitHub)

По умолчанию: пароль генерируется автоматически, xray + panel включаются сами.
Если WDTT уже установлен — запускается обновление с выбором версии.

Опции:
  -p, --password PASS   Свой пароль VPN
  --version TAG         Версия для обновления (v1.2.4)
  --no-menu             Без интерактивного меню
  --force               Переустановка
  menu | update | status | uninstall

Переменные: WDTT_GITHUB_USER, WDTT_VERSION, WDTT_NO_MENU=1
EOF
      exit 0
      ;;
  esac
  shift
done

[[ "$NO_MENU" == "1" || "${WDTT_NO_MENU:-0}" == "1" ]] && NO_MENU=1

# Интерактивное меню: без аргументов + терминал, или явно "menu"
if [[ "$CMD" == "menu" ]] || { [[ "$ORIG_ARGC" -eq 0 ]] && ui_can_interactive && [[ "$CMD" != "uninstall" && "$CMD" != "status" ]]; }; then
  run_interactive_menu
fi

# xray / panel по умолчанию (после меню и флагов CLI)
if [[ "$CMD" == "install" || "$CMD" == "update" ]]; then
  if [[ "$XRAY_MODE_SET" != "1" && "${WDTT_DIRECT:-0}" != "1" ]]; then
    WITH_XRAY=1
  elif [[ -z "$WITH_XRAY" ]]; then
    WITH_XRAY=1
  fi
  [[ "$XRAY_MODE_SET" != "1" && "${WDTT_DIRECT:-0}" == "1" ]] && WITH_XRAY=0
  if [[ "$PANEL_MODE_SET" != "1" && "${WDTT_NO_PANEL:-0}" != "1" ]]; then
    WITH_PANEL=1
  elif [[ -z "$WITH_PANEL" ]]; then
    WITH_PANEL=1
  fi
  [[ "$PANEL_MODE_SET" != "1" && "${WDTT_NO_PANEL:-0}" == "1" ]] && WITH_PANEL=0
fi
[[ -z "$WITH_XRAY" ]] && WITH_XRAY=0
[[ -z "$WITH_PANEL" ]] && WITH_PANEL=0

case "$CMD" in
  status) cmd_status; exit 0 ;;
  uninstall) cmd_uninstall; exit 0 ;;
esac

# Уже установлен → обновление (если не --force)
if [[ "$CMD" == "install" && "$FORCE_INSTALL" != "1" ]] && is_wdtt_installed; then
  CMD=update
fi

case "$CMD" in
  update)
    detect_os
    install_deps
    ensure_install_tree
    cmd_update
    exit 0
    ;;
esac

# ── Свежая установка ──
ui_clear
ui_banner
ui_box_top
ui_box_title "Установка WDTT"
ui_box_row "Компоненты" "server + panel + xray"
ui_box_row "Пароль VPN" "генерируется автоматически"
ui_box_bot
echo ""
ui_line
echo ""

if [[ -z "$WDTT_PASSWORD" ]]; then
  WDTT_PASSWORD="$(gen_password)"
  info "Сгенерирован пароль VPN: ${bold}${WDTT_PASSWORD}${plain}  ${dim}(сохраните!)${plain}"
  echo ""
fi

detect_os
install_deps
ensure_install_tree
setup_sysctl
setup_firewall
build_server
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ "$WITH_PANEL" == "1" ]]; then
  build_panel
  install_panel_service
  systemctl start wdtt-panel.service 2>/dev/null || true
  sleep 2
fi

install_wdtt_service "$WDTT_PASSWORD"

if [[ "$WITH_XRAY" == "1" ]]; then
  install_xray_binary
  install_xray_config
  install_xray_rules
fi

if [[ "$WITH_PANEL" != "1" ]]; then
  warn "Без панели конфиги не создаются — рекомендуется panel"
fi

ensure_install_tree
chmod +x "$INSTALL_DIR/install.sh" "$INSTALL_DIR/templates/wdtt-cli.sh" 2>/dev/null || true
install -m 0755 "$INSTALL_DIR/templates/wdtt-cli.sh" /usr/local/bin/wdtt

step "Запуск сервисов..."
start_services
print_summary
