#!/usr/bin/env bash
# Static regression checks for wdtt-install (no root / no network).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
MTU="${ROOT}/templates/wdtt-mtu-rules.sh"
README="${ROOT}/README.md"
fail=0

assert_file() {
  local f="$1"
  [[ -f "$f" ]] || { echo "FAIL: missing $f"; fail=1; }
}

assert_grep() {
  local pat="$1" file="$2" msg="${3:-pattern in $file}"
  if ! grep -qE -- "$pat" "$file"; then
    echo "FAIL: $msg"
    fail=1
  fi
}

assert_not_grep() {
  local pat="$1" file="$2" msg="${3:-must not match pattern in $file}"
  if grep -qE -- "$pat" "$file"; then
    echo "FAIL: $msg"
    fail=1
  fi
}

XRAY="${ROOT}/templates/wdtt-xray-rules.sh"
XRAY_CONFIG="${ROOT}/templates/xray-config.json"

assert_file "$INSTALL"
assert_file "$MTU"
assert_file "$XRAY"
assert_file "$XRAY_CONFIG"
assert_file "$README"

# Version / docs aligned to public WDTT line
assert_grep 'INSTALLER_VERSION="1\.5\.39"' "$INSTALL" "INSTALLER_VERSION=1.5.39"
assert_grep 'installer v1\.5\.39' "$README" "README installer version"
assert_grep '≥ v1\.5\.0' "$README" "README recommends ≥ v1.5.0"
assert_grep 'normalize_release_tag' "$INSTALL" "tag normalization for GitHub releases"
assert_grep 'WDTT_VERSION.*normalize_release_tag|normalize_release_tag "\$WDTT_VERSION"' "$INSTALL" "WDTT_VERSION bypass before tag list"

# Release asset contract unchanged
assert_grep 'wdtt-linux-\$\{ARCH\}' "$INSTALL" "asset name wdtt-linux-\${ARCH}"
assert_grep 'download_release_binary .*wdtt-linux' "$INSTALL" "download uses prefix wdtt-linux"

# CSQTT UDP default 46000 (fresh install / firewall / cleanup / systemd)
assert_grep 'WDTT_CSQTT_PORT:-46000' "$INSTALL" "CSQTT peer default 46000"
assert_grep 'CSQTT_PEER_PORT' "$INSTALL" "CSQTT_PEER_PORT used in install.sh"
assert_grep 'ensure_input_udp "\$CSQTT_PEER_PORT"|--dport "\$CSQTT_PEER_PORT"|--dport \$\{CSQTT_PEER_PORT\}' "$INSTALL" "firewall/systemd opens CSQTT peer UDP"
assert_grep '\$\{CSQTT_PEER_PORT\}:udp' "$INSTALL" "purge cleans CSQTT peer UDP"
assert_grep '46000:udp' "$INSTALL" "purge fallback cleans 46000/udp"
assert_grep 'is_valid_udp_port' "$INSTALL" "port validator present"
assert_grep 'is_private_ipv4_cidr' "$INSTALL" "CIDR validator present"
assert_grep 'WDTT_INSTALL_LIBONLY' "$INSTALL" "lib-only source guard"

# Shared RAW subnet defaults + cleanup
assert_grep 'WDTT_RAW_NET:-10\.70\.0\.0/16' "$INSTALL" "RAW subnet default"
assert_grep 'ip link del "\$RAW_IFACE"|ip link del \$RAW_IFACE' "$INSTALL" "purge removes wdtt-raw iface"
assert_grep 'RAW_IFACE="wdtt-raw"' "$INSTALL" "RAW_IFACE=wdtt-raw"
assert_grep 'WDTT_RAW_MANAGED' "$INSTALL" "purge cleans WDTT_RAW_MANAGED rules"

# Seed env for panel first boot
assert_grep 'RAW_DIRECT_PORT=\$\{RAW_DIRECT_PORT\}' "$INSTALL" "seed writes RAW_DIRECT_PORT"
assert_grep 'CSQTT_PEER_PORT=\$\{CSQTT_PEER_PORT\}' "$INSTALL" "seed writes CSQTT_PEER_PORT"
assert_grep 'RAW_SUBNET=\$\{RAW_SUBNET\}' "$INSTALL" "seed writes RAW_SUBNET"

# MTU template: comment-wide MSS cleanup for subnet changes + CIDR guard
assert_grep 'remove_all_managed_mss_iptables' "$MTU" "mtu template cleans all managed MSS"
assert_grep 'WDTT_RAW_NET:-10\.70\.0\.0/16' "$MTU" "mtu default RAW /16"
assert_grep 'is_private_ipv4_cidr|private IPv4|10\.70\.0\.0/16' "$MTU" "mtu validates or defaults RAW_NET"

# Issue #40: Xray REDIRECT for wdtt0 + wdtt-raw (name-scoped, even if TUN is down)
assert_grep 'RAW_IFACE="\$\{WDTT_RAW_IFACE:-wdtt-raw\}"' "$XRAY" "xray-rules RAW iface wdtt-raw"
assert_grep 'WG_IFACE="\$\{WDTT_IFACE:-wdtt0\}"' "$XRAY" "xray-rules WG iface wdtt0"
assert_grep 'apply_iface "\$WG_IFACE"' "$XRAY" "xray-rules apply wdtt0"
assert_grep 'apply_iface "\$RAW_IFACE"' "$XRAY" "xray-rules apply wdtt-raw"
assert_grep '-p tcp -j REDIRECT --to-ports' "$XRAY" "TCP REDIRECT to xray"
assert_grep '-p udp --dport 53' "$XRAY" "DNS DNAT udp/53"
assert_grep 'TPROXY_PORT="\$\{WDTT_TPROXY_PORT:-12346\}"' "$XRAY" "inner UDP TPROXY port"
assert_grep 'iptables -t mangle -N XRAY_TPROXY' "$XRAY" "XRAY_TPROXY chain"
assert_grep 'PREROUTING -i "\$iface" -p udp -j XRAY_TPROXY' "$XRAY" "TPROXY scoped to inner VPN iface"
assert_grep '-j TPROXY' "$XRAY" "TPROXY target exists"
assert_grep '--on-port "\$TPROXY_PORT" --on-ip 127\.0\.0\.1' "$XRAY" "TPROXY redirects to loopback listener"
assert_grep 'rule add fwmark.*table "\$TPROXY_TABLE"' "$XRAY" "TPROXY fwmark policy rule"
assert_grep 'route replace local 0\.0\.0\.0/0 dev lo table "\$TPROXY_TABLE"' "$XRAY" "TPROXY local route"
assert_grep 'probe_tproxy_target' "$XRAY" "TPROXY capability is checked before replacing live rules"
assert_grep 'TPROXY target or policy route verification failed' "$XRAY" "TPROXY activation failure is reported"
assert_grep '"tag"[[:space:]]*:[[:space:]]*"tproxy-in"' "$XRAY_CONFIG" "fresh Xray config has tproxy-in"
assert_grep '"listen"[[:space:]]*:[[:space:]]*"127\.0\.0\.1"' "$XRAY_CONFIG" "tproxy-in is loopback-only"
assert_grep '"port"[[:space:]]*:[[:space:]]*12346' "$XRAY_CONFIG" "tproxy-in port 12346"
assert_grep '"tproxy"[[:space:]]*:[[:space:]]*"tproxy"' "$XRAY_CONFIG" "tproxy socket option"
assert_grep 'ensure_xray_tproxy_in' "$INSTALL" "installer patches existing Xray config"
assert_grep 'install_xray_config' "$INSTALL" "update path normalizes existing Xray config"
assert_grep 'python3' "$INSTALL" "installer provides JSON-safe tproxy config migration"
assert_not_grep 'systemctl restart wdtt-xray\.service \|\| warn' "$INSTALL" "installer must fail when wdtt-xray/TPROXY cannot start"
assert_grep 'SELECT raw_subnet FROM wdtt_inbound' "$XRAY" "load custom raw_subnet from panel.db"
assert_grep 'valid_raw_net' "$XRAY" "raw_subnet validator"
assert_grep 'is_valid_raw_subnet' "$XRAY" "raw-specific validator in helper"
assert_grep 'is_valid_raw_subnet' "$INSTALL" "raw-specific validator in installer"
assert_grep '10#\$prefix >= 16 && 10#\$prefix <= 29' "$XRAY" "valid_raw_net prefix /16-/29"
assert_grep '10#\$prefix >= 16 && 10#\$prefix <= 29' "$INSTALL" "installer raw subnet /16-/29"
assert_grep '10#\$prefix >= 8 && 10#\$prefix <= 32' "$INSTALL" "general private CIDR stays /8-/32"
assert_not_grep '/tmp/wdtt-xray-rules.lock' "$XRAY" "no /tmp flock fallback (symlink)"
assert_grep '/run/wdtt-xray-rules.lock' "$XRAY" "flock uses /run lock"
assert_grep 'load_raw_net' "$XRAY" "load_raw_net helper"
assert_grep 'export WDTT_RAW_NET=' "$XRAY" "export WDTT_RAW_NET for mtu"
assert_grep 'WDTT_RAW_NET="\$RAW_NET" /usr/local/bin/wdtt-mtu-rules.sh up' "$XRAY" "pass custom RAW_NET into mtu up"
assert_grep 'while iptables -t nat -C PREROUTING -i "\$iface" -j XRAY_REDIRECT' "$XRAY" "idempotent loop-delete PREROUTING jump"
assert_grep 'iptables -t nat -C PREROUTING -i "\$iface" -j XRAY_REDIRECT 2>/dev/null \|\|' "$XRAY" "idempotent add PREROUTING jump"
assert_grep 'iptables -C INPUT -i "\$iface" -m comment --comment WDTT_XRAY' "$XRAY" "idempotent INPUT ACCEPT"
assert_not_grep 'ip link show' "$XRAY" "must not gate REDIRECT on ip link show (wdtt-raw race)"
assert_not_grep '-p udp -j DROP' "$XRAY" "no broad UDP DROP"
assert_not_grep '-p udp -j REJECT' "$XRAY" "no broad UDP REJECT"

# Issue #40: wdtt.service up/down applies both xray + MTU; xray unit has no sleep-1 race
assert_grep 'install_wdtt_service' "$INSTALL" "install_wdtt_service present"
assert_grep 'wdtt-xray-rules.sh up' "$INSTALL" "installer applies xray-rules up"
assert_grep 'wdtt-xray-rules.sh down' "$INSTALL" "installer applies xray-rules down"
assert_not_grep 'sleep 1; /usr/local/bin/wdtt-xray-rules.sh up' "$INSTALL" "no fixed 1s sleep before xray-rules (wdtt-raw race)"
assert_not_grep 'seq 1 40' "$INSTALL" "no leftover wdtt-raw wait loop"
assert_grep 'install -m 0755 "\$\{TEMPLATES_DIR\}/wdtt-xray-rules.sh"' "$INSTALL" "upgrade installs refreshed helper"
assert_grep 'wdtt_service_routing_posts' "$INSTALL" "routing posts helper for --direct vs xray"
assert_grep 'teardown_xray_routing_leftovers' "$INSTALL" "xray leftover teardown helper"
assert_grep 'disable --now wdtt-xray.service' "$INSTALL" "direct mode disable --now leftover xray unit"

# No real tokens / secrets embedded
assert_not_grep 'ghp_[A-Za-z0-9]{20,}' "$INSTALL" "no GitHub PAT in install.sh"
assert_not_grep 'ghp_[A-Za-z0-9]{20,}' "$README" "no GitHub PAT in README"
assert_not_grep 'sk-[A-Za-z0-9]{20,}' "$INSTALL" "no sk- tokens in install.sh"

# bash -n on all shell scripts
while IFS= read -r -d '' sh; do
  if ! bash -n "$sh"; then
    echo "FAIL: bash -n $sh"
    fail=1
  fi
done < <(find "$ROOT" -type f -name '*.sh' ! -path '*/.git/*' -print0)

if [[ "$fail" -ne 0 ]]; then
  echo "static_checks: FAILED"
  exit 1
fi
echo "static_checks: OK"
