#!/bin/bash
# WDTT MTU rules: TCP MSS clamp + DF-clear for WG (10.66.66.0/24) and RAW (10.70.0.0/16).
# Единый источник — wdtt-install, deploy.sh, wdtt-xray-rules.sh (только вызывает up).
set +e

IFACE="${WDTT_IFACE:-wdtt0}"
RAW_IFACE="${WDTT_RAW_IFACE:-wdtt-raw}"
WG_NET="${WDTT_TUN_NET:-10.66.66.0/24}"
RAW_NET="${WDTT_RAW_NET:-10.70.0.0/16}"
IPT_COMMENT="${WDTT_IPT_COMMENT:-WDTT_MANAGED}"
DEFAULT_MTU="${WDTT_DEFAULT_MTU:-1280}"

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

# Reject shell/nft metacharacters — only validated private CIDR may enter nft heredocs.
sanitize_nets() {
    if ! is_private_ipv4_cidr "$WG_NET"; then
        WG_NET="10.66.66.0/24"
    fi
    if ! is_private_ipv4_cidr "$RAW_NET"; then
        echo "wdtt-mtu: invalid RAW_NET=${RAW_NET} — fallback 10.70.0.0/16" >&2
        RAW_NET="10.70.0.0/16"
    fi
}

detect_wan() {
    ip route get 8.8.8.8 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1
}

iface_mtu() {
    local iface="$1" m
    m="$(cat "/sys/class/net/${iface}/mtu" 2>/dev/null)"
    [[ -n "$m" ]] && echo "$m" || echo "$DEFAULT_MTU"
}

apply_mss_iptables() {
    local subnet="$1"
    if command -v iptables >/dev/null 2>&1; then
        iptables -t mangle -C FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
        iptables -t mangle -C FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || \
            iptables -t mangle -I FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
    fi
}

remove_mss_iptables() {
    local subnet="$1"
    if command -v iptables >/dev/null 2>&1; then
        while iptables -t mangle -D FORWARD -s "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
        while iptables -t mangle -D FORWARD -d "$subnet" -p tcp -m tcp --tcp-flags SYN,RST SYN -m comment --comment "$IPT_COMMENT" -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
    fi
}

remove_all_managed_mss_iptables() {
    local rule
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi
    while IFS= read -r rule; do
        [[ "$rule" == *"--comment ${IPT_COMMENT}"* ]] || continue
        [[ "$rule" == *"-j TCPMSS"* ]] || continue
        read -r -a args <<<"$rule"
        [[ "${args[0]:-}" == "-A" ]] || continue
        args[0]="-D"
        iptables -t mangle "${args[@]}" 2>/dev/null || true
    done < <(iptables -t mangle -S FORWARD 2>/dev/null)
}

apply_nft_rules() {
    local wan="$1" wg_mtu="$2" raw_mtu="$3"
    if ! command -v nft >/dev/null 2>&1; then
        return 0
    fi
    sanitize_nets
    nft delete table inet wdtt_mangle 2>/dev/null
    nft -f - <<NFT
table inet wdtt_mangle {
    chain forward {
        type filter hook forward priority -150; policy accept;
        ip saddr ${WG_NET} tcp flags syn tcp option maxseg size set rt mtu
        ip daddr ${WG_NET} tcp flags syn tcp option maxseg size set rt mtu
        ip saddr ${RAW_NET} tcp flags syn tcp option maxseg size set rt mtu
        ip daddr ${RAW_NET} tcp flags syn tcp option maxseg size set rt mtu
    }
}
NFT
    nft delete table ip wdtt_mtu 2>/dev/null
    if [[ -n "$wan" ]]; then
        nft -f - <<NFT
table ip wdtt_mtu {
    chain clampdf {
        type filter hook prerouting priority -90; policy accept;
        iifname "${wan}" ip daddr ${WG_NET} ip length gt ${wg_mtu} ip frag-off & 0x4000 == 0x4000 ip frag-off set 0
        iifname "${wan}" ip daddr ${RAW_NET} ip length gt ${raw_mtu} ip frag-off & 0x4000 == 0x4000 ip frag-off set 0
    }
}
NFT
    fi
}

cleanup_mtu_rules() {
    sanitize_nets
    remove_all_managed_mss_iptables
    remove_mss_iptables "$WG_NET"
    remove_mss_iptables "$RAW_NET"
    # legacy single-subnet RAW /24 if ever installed
    remove_mss_iptables "10.70.66.0/24"
    nft delete table inet wdtt_mangle 2>/dev/null
    nft delete table ip wdtt_mtu 2>/dev/null
}

case "${1:-up}" in
down)
    cleanup_mtu_rules
    echo "wdtt-mtu rules removed"
    exit 0
    ;;
up)
    sanitize_nets
    WAN="$(detect_wan)"
    WG_MTU="$(iface_mtu "$IFACE")"
    RAW_MTU="$(iface_mtu "$RAW_IFACE")"
    apply_mss_iptables "$WG_NET"
    apply_mss_iptables "$RAW_NET"
    apply_nft_rules "$WAN" "$WG_MTU" "$RAW_MTU"
    echo "wdtt-mtu rules applied (MSS ${WG_NET}+${RAW_NET}, DF-clear ${WAN:-?} mtu wg=${WG_MTU} raw=${RAW_MTU})"
    exit 0
    ;;
*)
    echo "Usage: $0 up|down" >&2
    exit 1
    ;;
esac
