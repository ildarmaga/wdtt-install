#!/bin/bash
# Заворот трафика wdtt0 -> xray (REDIRECT режим, по рецепту issue #146)
set +e
IFACE="wdtt0"
XPORT="12345"
DNS_IP="10.66.66.1"

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
iptables -t nat -A XRAY_REDIRECT -p udp --dport 53 -j RETURN
iptables -t nat -A XRAY_REDIRECT -p tcp -j REDIRECT --to-ports "$XPORT"
iptables -t nat -A PREROUTING -i "$IFACE" -j XRAY_REDIRECT

echo "wdtt-xray rules applied (TCP -> :$XPORT, DNS -> $DNS_IP:53)"
