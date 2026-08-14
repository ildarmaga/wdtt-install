#!/bin/bash
# Заворот VPN-трафика в Xray (REDIRECT): wdtt0 (WG) + wdtt-raw (RAW/CSQTT).
# MTU (MSS + DF-clear): /usr/local/bin/wdtt-mtu-rules.sh — не дублировать здесь.
# Правила привязаны к имени iface и применяются даже если TUN ещё не поднят
# (гонка wdtt-xray ExecStartPost vs startRawTUN). TCP-only REDIRECT — без UDP DROP.
set +e

WG_IFACE="${WDTT_IFACE:-wdtt0}"
RAW_IFACE="${WDTT_RAW_IFACE:-wdtt-raw}"
XPORT="${WDTT_XRAY_PORT:-12345}"
DNS_IP="${WDTT_DNS_IP:-10.66.66.1}"
WG_NET="${WDTT_TUN_NET:-10.66.66.0/24}"
RAW_NET="${WDTT_RAW_NET:-10.70.0.0/16}"
PANEL_DB="${WDTT_PANEL_DB:-/etc/wdtt/panel.db}"
DEFAULT_RAW_NET="10.70.0.0/16"

# Serialize concurrent up/down (wdtt ExecStartPost + xray ExecStartPost + startRawTUN).
# Lock only under /run (or WDTT_XRAY_RULES_LOCK). Do not fall back to /tmp (symlink race).
if command -v flock >/dev/null 2>&1; then
    _lock="${WDTT_XRAY_RULES_LOCK:-/run/wdtt-xray-rules.lock}"
    if exec 9>"$_lock" 2>/dev/null; then
        flock 9 || true
    fi
fi

# RFC1918 IPv4 CIDR: octets 0-255, prefix /8-/32 (same as installer / wdtt-mtu-rules.sh).
is_private_ipv4_cidr() {
    local cidr="${1:-}"
    local o1 o2 o3 o4 prefix
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"; o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    prefix="${BASH_REMATCH[5]}"
    ((10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255)) || return 1
    ((10#$prefix >= 8 && 10#$prefix <= 32)) || return 1
    if ((10#$o1 == 10)); then return 0; fi
    if ((10#$o1 == 172 && 10#$o2 >= 16 && 10#$o2 <= 31)); then return 0; fi
    if ((10#$o1 == 192 && 10#$o2 == 168)); then return 0; fi
    return 1
}

# RAW/CSQTT subnet: RFC1918, prefix /16-/29 (panel Go policy), no leading-zero octets.
is_valid_raw_subnet() {
    local cidr="${1:-}"
    local o1 o2 o3 o4 prefix oct
    [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{1,2})$ ]] || return 1
    o1="${BASH_REMATCH[1]}"; o2="${BASH_REMATCH[2]}"; o3="${BASH_REMATCH[3]}"; o4="${BASH_REMATCH[4]}"
    prefix="${BASH_REMATCH[5]}"
    for oct in "$o1" "$o2" "$o3" "$o4" "$prefix"; do
        [[ "$oct" =~ ^0[0-9] ]] && return 1
    done
    ((10#$o1 <= 255 && 10#$o2 <= 255 && 10#$o3 <= 255 && 10#$o4 <= 255)) || return 1
    ((10#$prefix >= 16 && 10#$prefix <= 29)) || return 1
    if ((10#$o1 == 10)); then return 0; fi
    if ((10#$o1 == 172 && 10#$o2 >= 16 && 10#$o2 <= 31)); then return 0; fi
    if ((10#$o1 == 192 && 10#$o2 == 168)); then return 0; fi
    return 1
}

valid_raw_net() {
    is_valid_raw_subnet "$1"
}

load_panel_ports() {
    local db="$PANEL_DB"
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

load_raw_net() {
    local candidate="${WDTT_RAW_NET:-}"
    if [[ -z "$candidate" ]]; then
        local db="$PANEL_DB"
        local row=""
        if [[ -f "$db" ]]; then
            if command -v sqlite3 >/dev/null; then
                row="$(sqlite3 "$db" "SELECT raw_subnet FROM wdtt_inbound WHERE id=1;" 2>/dev/null || true)"
            elif command -v python3 >/dev/null; then
                row="$(python3 - "$db" <<'PY' 2>/dev/null || true
import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
r = c.execute("SELECT raw_subnet FROM wdtt_inbound WHERE id=1").fetchone()
if r and r[0]:
    print(r[0])
PY
                )"
            fi
        fi
        candidate="$(printf '%s' "$row" | tr -d '[:space:]')"
    fi
    if valid_raw_net "$candidate"; then
        RAW_NET="$candidate"
    else
        RAW_NET="${DEFAULT_RAW_NET}"
    fi
    export WDTT_RAW_NET="$RAW_NET"
}

load_panel_ports
load_raw_net

cleanup_iface() {
    local iface="$1"
    while iptables -t nat -C PREROUTING -i "$iface" -j XRAY_REDIRECT 2>/dev/null; do
        iptables -t nat -D PREROUTING -i "$iface" -j XRAY_REDIRECT 2>/dev/null || break
    done
    while iptables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null; do
        iptables -t nat -D PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null || break
    done
    while iptables -C INPUT -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null || break
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

# Цепочка REDIRECT (общая для обоих TUN). Только TCP; UDP 53 — DNAT, прочий UDP не трогаем.
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
    # Имя iface, не ifindex: правила живут после ip link del/add wdtt-raw.
    # Не пропускаем, если link ещё down — иначе CSQTT уходит в MASQUERADE мимо Xray.
    iptables -C INPUT -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null || \
        iptables -I INPUT 1 -i "$iface" -m comment --comment WDTT_XRAY -j ACCEPT
    iptables -t nat -C PREROUTING -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null || \
        iptables -t nat -I PREROUTING 1 -i "$iface" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53"
    iptables -t nat -C PREROUTING -i "$iface" -j XRAY_REDIRECT 2>/dev/null || \
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
    WDTT_RAW_NET="$RAW_NET" /usr/local/bin/wdtt-mtu-rules.sh up
fi

if [[ -z "$APPLIED" ]]; then
    echo "wdtt-xray rules: no VPN ifaces applied"
    exit 0
fi
echo "wdtt-xray rules applied (ifaces:${APPLIED} raw_net:$RAW_NET panel:$PANEL_PORT sub:$SUB_PORT TCP -> :$XPORT, DNS -> $DNS_IP:53)"
