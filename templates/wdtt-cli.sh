#!/bin/bash
# wdtt — управление как x-ui
set -euo pipefail
case "${1:-}" in
  status)  systemctl status wdtt wdtt-xray wdtt-panel --no-pager 2>/dev/null || systemctl status wdtt --no-pager ;;
  restart) systemctl restart wdtt; systemctl restart wdtt-xray 2>/dev/null || true; systemctl restart wdtt-panel 2>/dev/null || true; echo "restarted" ;;
  stop)    systemctl stop wdtt-xray wdtt-panel wdtt 2>/dev/null || true ;;
  start)   systemctl start wdtt; systemctl start wdtt-xray 2>/dev/null || true; systemctl start wdtt-panel 2>/dev/null || true ;;
  log)     journalctl -u wdtt -u wdtt-xray -u wdtt-panel -f ;;
  update)  bash /usr/local/wdtt/install.sh update ;;
  uninstall) bash /usr/local/wdtt/install.sh uninstall ;;
  *) echo "Usage: wdtt {status|restart|stop|start|log|update|uninstall}"; exit 1 ;;
esac
