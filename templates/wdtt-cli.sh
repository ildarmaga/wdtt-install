#!/bin/bash
# wdtt — управление как x-ui
set -euo pipefail

GITHUB_USER="${WDTT_GITHUB_USER:-ildarmaga}"
INSTALLER_RAW="https://raw.githubusercontent.com/${GITHUB_USER}/wdtt-install/main/install.sh"
LOCAL_INSTALLER="/usr/local/wdtt/install.sh"

_run_installer() {
  local cmd="$1"
  shift || true
  local tmp
  tmp="$(mktemp /tmp/wdtt-install.XXXXXX.sh)"
  if curl -fsSL -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
      "${INSTALLER_RAW}?t=${RANDOM}" -o "$tmp" 2>/dev/null; then
    chmod +x "$tmp"
    exec bash "$tmp" "$cmd" "$@"
  fi
  if [[ -f "$LOCAL_INSTALLER" ]]; then
    exec bash "$LOCAL_INSTALLER" "$cmd" "$@"
  fi
  echo "Не удалось загрузить установщик с GitHub и нет ${LOCAL_INSTALLER}" >&2
  exit 1
}

case "${1:-}" in
  status)  systemctl status wdtt wdtt-xray wdtt-panel --no-pager 2>/dev/null || systemctl status wdtt --no-pager ;;
  restart) systemctl restart wdtt; systemctl restart wdtt-xray 2>/dev/null || true; systemctl restart wdtt-panel 2>/dev/null || true; echo "restarted" ;;
  stop)    systemctl stop wdtt-xray wdtt-panel wdtt 2>/dev/null || true ;;
  start)   systemctl start wdtt; systemctl start wdtt-xray 2>/dev/null || true; systemctl start wdtt-panel 2>/dev/null || true ;;
  log)     journalctl -u wdtt -u wdtt-xray -u wdtt-panel -f ;;
  menu)    _run_installer menu ;;
  update)  _run_installer update "${@:2}" ;;
  uninstall) _run_installer uninstall ;;
  *) echo "Usage: wdtt {status|restart|stop|start|log|menu|update|uninstall}"; exit 1 ;;
esac
