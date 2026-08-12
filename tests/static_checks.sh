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

assert_file "$INSTALL"
assert_file "$MTU"
assert_file "$README"

# Version / docs aligned to public WDTT line
assert_grep 'INSTALLER_VERSION="1\.5\.1"' "$INSTALL" "INSTALLER_VERSION=1.5.1"
assert_grep 'installer v1\.5\.1' "$README" "README installer version"
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
