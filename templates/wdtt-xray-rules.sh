#!/bin/bash
# Заворот VPN-трафика в Xray (REDIRECT): wdtt0 (WG) + wdtt-raw (RAW/CSQTT).
# MTU (MSS + DF-clear): /usr/local/bin/wdtt-mtu-rules.sh — не дублировать здесь.
set +e

WG_IFACE="${WDTT_IFACE:-wdtt0}"
RAW_IFACE="${WDTT_RAW_IFACE:-wdtt-raw}"
XPORT="${WDTT_XRAY_PORT:-12345}"
DNS_IP="${WDTT_DNS_IP:-10.66.66.1}"
WG_NET="${WDTT_TUN_NET:-10.66.66.0/24}"
RAW_NET="${WDTT_RAW_NET:-10.70.0.0/16}"

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

cleanup_iface() {
    local iface="$1"
    iptables -t nat -D PREROUTING -i "$iface" -j XRAY_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null
    while iptables -C INPUT -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null
    done
}

cleanup() {
    cleanup_iface "$WG_IFACE"
    cleanup_iface "$RAW_IFACE"
    iptables -t nat -F XRAY_REDIRECT 2>/dev/null
    iptables -t nat -X XRAY_REDIRECT 2>/dev/null
}

if [ "${1:-}" = "down" ]; then
    cleanup
    echo "wdtt-xray rules removed"
    exit 0
fi

cleanup

# Цепочка REDIRECT (общая для обоих TUN)
iptables -t nat -N XRAY_REDIRECT
iptables -t nat -A XRAY_REDIRECT -d "$WG_NET" -j RETURN
iptables -t nat -A XRAY_REDIRECT -d "$RAW_NET" -j RETURN
iptables -t nat -A XRAY_REDIRECT -d 127.0.0.0/8 -j RETURN
iptables -t nat -A XRAY_REDIRECT -d 255.255.255.255/32 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$PANEL_PORT" -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$SUB_PORT" -j RETURN
iptables -t nat -A XRAY_REDIRECT -m addrtype --dst-type LOCAL -j RETURN
iptables -t nat -A XRAY_REDIRECT -p udp --dport 53 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp -j REDIRECT --to-ports "$XPORT"

APPLIED=""
apply_iface() {
    local iface="$1"
    if ! ip link show "$iface" >/dev/null 2>&1; then
        return 1
    fi
    # INPUT: REDIRECT отдаёт на gateway:12345 → нужен ACCEPT с туннеля
    iptables -I INPUT 1 -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT
    # DNS → локальный xray dns-in (10.66.66.1:53)
    iptables -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53"
    iptables -t nat -A PREROUTING -i "$iface" -j XRAY_REDIRECT
    if [[ -n "$APPLIED" ]]; then
        APPLIED="${APPLIED}+${iface}"
    else
        APPLIED="$iface"
    fi
    return 0
}

apply_iface "$WG_IFACE" || true
apply_iface "$RAW_IFACE" || true

if [[ -x /usr/local/bin/wdtt-mtu-rules.sh ]]; then
    /usr/local/bin/wdtt-mtu-rules.sh up
fi

if [[ -z "$APPLIED" ]]; then
    echo "wdtt-xray rules: no VPN ifaces up yet (wait for wdtt0/wdtt-raw)"
    exit 0
fi
echo "wdtt-xray rules applied (ifaces:${APPLIED} panel:$PANEL_PORT sub:$SUB_PORT TCP -> :$XPORT, DNS -> $DNS_IP:53)"
