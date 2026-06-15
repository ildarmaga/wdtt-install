#!/bin/bash
# wdtt — управление как x-ui (menu, update, purge, status…)
set -euo pipefail

WDTT_APP="${WDTT_APP:-/usr/local/bin/wdtt-app}"
GITHUB_USER="${WDTT_GITHUB_USER:-ildarmaga}"
REPO="https://github.com/${GITHUB_USER}/wdtt-install.git"
LOCAL_INSTALLER="/usr/local/wdtt/install.sh"

_fetch_installer_path() {
  local dir tmp
  dir="$(mktemp -d /tmp/wdtt-install.XXXXXX)"
  if git clone --depth 1 --branch main "$REPO" "$dir" 2>/dev/null; then
    echo "$dir/install.sh"
    return 0
  fi
  rm -rf "$dir"
  local sha
  sha="$(curl -fsSL "https://api.github.com/repos/${GITHUB_USER}/wdtt-install/commits/main" 2>/dev/null \
    | sed -n 's/.*"sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)"
  if [[ -n "$sha" ]]; then
    tmp="$(mktemp /tmp/wdtt-install.XXXXXX.sh)"
    if curl -fsSL "https://raw.githubusercontent.com/${GITHUB_USER}/wdtt-install/${sha}/install.sh" -o "$tmp" 2>/dev/null; then
      chmod +x "$tmp"
      echo "$tmp"
      return 0
    fi
    rm -f "$tmp"
  fi
  if [[ -f "$LOCAL_INSTALLER" ]]; then
    echo "$LOCAL_INSTALLER"
    return 0
  fi
  return 1
}

_run_installer() {
  local cmd="$1"
  shift || true
  local script
  script="$(_fetch_installer_path)" || {
    echo "Не удалось загрузить установщик с GitHub" >&2
    exit 1
  }
  exec bash "$script" "$cmd" "$@"
}

case "${1:-}" in
  status)    systemctl status wdtt wdtt-xray wdtt-panel --no-pager 2>/dev/null || systemctl status wdtt --no-pager ;;
  restart)   systemctl restart wdtt; systemctl restart wdtt-xray 2>/dev/null || true; systemctl restart wdtt-panel 2>/dev/null || true; echo "restarted" ;;
  stop)      systemctl stop wdtt-xray wdtt-panel wdtt 2>/dev/null || true ;;
  start)     systemctl start wdtt; systemctl start wdtt-xray 2>/dev/null || true; systemctl start wdtt-panel 2>/dev/null || true ;;
  log)       journalctl -u wdtt -u wdtt-xray -u wdtt-panel -f ;;
  menu)      _run_installer menu ;;
  update)    _run_installer update "${@:2}" ;;
  uninstall) _run_installer uninstall ;;
  purge)     _run_installer purge ;;
  -version|--version)
    exec "$WDTT_APP" "$@"
    ;;
  "")
    echo "Usage: wdtt {menu|status|update|purge|restart|stop|start|log|uninstall}"
    exit 1
    ;;
  *)
    echo "Usage: wdtt {menu|status|update|purge|restart|stop|start|log|uninstall}" >&2
    exit 1
    ;;
esac
