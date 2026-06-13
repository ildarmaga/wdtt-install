#!/bin/bash
# Заворот трафика wdtt0 -> xray (REDIRECT режим, по рецепту issue #146)
set +e
IFACE="wdtt0"
XPORT="12345"
DNS_IP="10.66.66.1"
TUN_NET="10.66.66.0/24"
PANEL_PORT="${PANEL_PORT:-2860}"
SUB_PORT="${SUB_PORT:-2096}"
WAN_IFACE="$(ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)"
[ -z "$WAN_IFACE" ] && WAN_IFACE="eth0"
TUN_MTU="$(cat /sys/class/net/${IFACE}/mtu 2>/dev/null)"
[ -z "$TUN_MTU" ] && TUN_MTU="1280"

cleanup() {
    iptables -t nat -D PREROUTING -i "$IFACE" -j XRAY_REDIRECT 2>/dev/null
    iptables -t nat -F XRAY_REDIRECT 2>/dev/null
    iptables -t nat -X XRAY_REDIRECT 2>/dev/null
    iptables -t nat -D PREROUTING -i "$IFACE" -p udp --dport 53 -j DNAT --to-destination "${DNS_IP}:53" 2>/dev/null
    while iptables -C INPUT -i "$IFACE" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null; do
        iptables -D INPUT -i "$IFACE" -m comment --comment WDTT_XRAY -j ACCEPT 2>/dev/null
    done
    # Снять правило сброса DF (см. ниже)
    nft delete table ip wdtt_mtu 2>/dev/null
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
# Панель и подписка — напрямую на сервер, не через xray (иначе таймаут при VPN)
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$PANEL_PORT" -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp --dport "$SUB_PORT" -j RETURN
# Трафик к локальным адресам сервера (SSH, сервисы на loopback после DNAT)
iptables -t nat -A XRAY_REDIRECT -m addrtype --dst-type LOCAL -j RETURN
iptables -t nat -A XRAY_REDIRECT -p udp --dport 53 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp -j REDIRECT --to-ports "$XPORT"
iptables -t nat -A PREROUTING -i "$IFACE" -j XRAY_REDIRECT

# --- Фикс MTU для игр/Steam Datagram Relay ---
# Ответы релеев приходят пакетами ~1328 байт с флагом DF и не влезают в MTU туннеля.
# Ядро (ip_forward) дропает их с DF ДО цепочки FORWARD, поэтому пинг в играх не считается.
# Сбрасываем DF в PREROUTING (после reverse-NAT) на крупных пакетах, идущих клиентам,
# чтобы ядро само фрагментировало их под MTU туннеля, а клиент собрал обратно.
if command -v nft >/dev/null 2>&1; then
    nft delete table ip wdtt_mtu 2>/dev/null
    nft -f - <<NFT
table ip wdtt_mtu {
    chain clampdf {
        type filter hook prerouting priority -90; policy accept;
        iifname "${WAN_IFACE}" ip daddr ${TUN_NET} ip length gt ${TUN_MTU} ip frag-off & 0x4000 == 0x4000 ip frag-off set 0
    }
}
NFT
    echo "wdtt-xray rules applied (TCP -> :$XPORT, DNS -> $DNS_IP:53, DF-clear ${WAN_IFACE}->${TUN_NET} >${TUN_MTU}B)"
else
    echo "wdtt-xray rules applied (TCP -> :$XPORT, DNS -> $DNS_IP:53; nft missing, DF-clear skipped)"
fi
