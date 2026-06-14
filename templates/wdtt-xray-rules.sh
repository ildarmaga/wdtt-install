#!/bin/bash
# Заворот трафика wdtt0 -> xray (REDIRECT режим, по рецепту issue #146)
# MTU (MSS + DF-clear): /usr/local/bin/wdtt-mtu-rules.sh — не дублировать здесь.
set +e
IFACE="wdtt0"
XPORT="12345"
DNS_IP="10.66.66.1"
TUN_NET="10.66.66.0/24"

load_panel_ports() {
    local db="/etc/wdtt/panel.db"
    PANEL_PORT="${PANEL_PORT:-}"
    SUB_PORT="${SUB_PORT:-}"
    if [[ -f "$db" ]]; then
        local row=""
        if command -v sqlite3 >/dev/null; then
            row="$(sqlite3 "$db" "SELECT port, sub_port FROM panel_config WHERE id=1;" 2>/dev/null || true)"
        elif command -v python3 >/dev/null; then
            row="$(python3 - "$db" <<'PY' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("SELECT port, sub_port FROM panel_config WHERE id=1").fetchone()
if r:
    print(f"{r[0]}|{r[1]}")
PY
            )"
        fi
        if [[ -n "$row" ]]; then
            IFS='|' read -r db_panel db_sub <<< "$row"
            [[ -n "$db_panel" && "$db_panel" -gt 0 ]] && PANEL_PORT="$db_panel"
            [[ -n "$db_sub" && "$db_sub" -gt 0 ]] && SUB_PORT="$db_sub"
        fi
    fi
    PANEL_PORT="${PANEL_PORT:-${WDTT_PANEL_PORT:-2860}}"
    SUB_PORT="${SUB_PORT:-${WDTT_SUB_PORT:-2096}}"
}

load_panel_ports

cleanup() {
    iptables -t nat -D PREROUTING -i "$IFACE" -j XRAY_REDIRECT 2>/dev/null
    iptables -t nat -F XRAY_REDIRECT 2>/dev/null
    iptables -t nat -X XRAY_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null
    while iptables -C INPUT -i "$IFACE" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$IFACE" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null
    done
}

if [ "${1:-}" = "down" ]; then
    cleanup
    echo "wdtt-xray rules removed"
    exit 0
fi

cleanup

# INPUT: разрешаем трафик с туннеля к локальному xray (REDIRECT отдаёт на 10.66.66.1:12345 -> INPUT)
iptables -I INPUT 1 -i "$IFACE" -m comment --comment WDTT_XRAY -j ACCEPT

# DNS -> локальный xray dns-in
iptables -t nat -I PREROUTING 1 -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53"

# Цепочка REDIRECT
iptables -t nat -N XRAY_REDIRECT
iptables -t nat -A XRAY_REDIRECT -d 10.66.66.0/24 -j RETURN
iptables -t nat -A XRAY_REDIRECT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A XRAY_REDIRECT -d 255.255.255.255/32 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$PANEL_PORT" -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$SUB_PORT" -j RETURN
iptables -t nat -A XRAY_REDIRECT -m addrtype --dst-type LOCAL -j RETURN
iptables -t nat -A XRAY_REDIRECT -p udp --dport 53 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp -j REDIRECT --to-ports "$XPORT"
iptables -t nat -A PREROUTING -i "$IFACE" -j XRAY_REDIRECT

if [[ -x /usr/local/bin/wdtt-mtu-rules.sh ]]; then
    /usr/local/bin/wdtt-mtu-rules.sh up
fi

echo "wdtt-xray rules applied (panel:$PANEL_PORT sub:$SUB_PORT TCP -> :$XPORT, DNS -> $DNS_IP:53)"
