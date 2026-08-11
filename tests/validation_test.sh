#!/usr/bin/env bash
# Behavioral tests for install.sh validation helpers + contract assertions.
# Sources install.sh in lib-only mode (no install side effects).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${ROOT}/install.sh"
fail=0

pass() { echo "  PASS: $*"; }
fail_msg() { echo "  FAIL: $*"; fail=1; }

assert_eq() {
  local got="$1" want="$2" msg="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$msg"
  else
    fail_msg "$msg (got='$got' want='$want')"
  fi
}

assert_true() {
  local msg="$1"
  shift
  if "$@"; then
    pass "$msg"
  else
    fail_msg "$msg"
  fi
}

assert_false() {
  local msg="$1"
  shift
  if "$@"; then
    fail_msg "$msg (expected failure)"
  else
    pass "$msg"
  fi
}

# --- Contract checks (systemd / update) without executing install ---
echo "== contract: systemd ExecStartPre includes CSQTT =="
if awk '
  /ipt_pre=\$\(cat <<IPT/ {inside=1}
  inside && /CSQTT_PEER_PORT/ {found=1}
  inside && /^IPT$/ {exit}
  END {exit found?0:1}
' "$INSTALL"; then
  pass "ExecStartPre ipt_pre embeds CSQTT_PEER_PORT"
else
  fail_msg "ExecStartPre ipt_pre missing CSQTT UDP"
fi

echo "== contract: cmd_update calls setup_firewall =="
if awk '
  /^cmd_update\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /setup_firewall/ {found=1}
  END {exit found?0:1}
' "$INSTALL"; then
  pass "cmd_update invokes setup_firewall"
else
  fail_msg "cmd_update does not call setup_firewall"
fi

echo "== contract: release asset name preserved =="
if grep -qE 'wdtt-linux-\$\{ARCH\}' "$INSTALL" \
  && grep -qE 'download_release_binary .* "wdtt-linux"' "$INSTALL"; then
  pass "wdtt-linux-\${ARCH} contract intact"
else
  fail_msg "release asset contract broken"
fi

echo "== contract: old DB 3-col fallback preserved =="
if grep -q 'SELECT dtls_port, wg_port, COALESCE(raw_direct_port,0) FROM wdtt_inbound' "$INSTALL"; then
  pass "3-column wdtt_inbound fallback present"
else
  fail_msg "old DB fallback missing"
fi

echo "== contract: UTF-8 MTU 'для' =="
if python3 - "$INSTALL" <<'PY'
import pathlib, sys
data = pathlib.Path(sys.argv[1]).read_bytes()
# MTU: MSS clamp + DF-clear <для UTF-8> 
needle = b"MTU: MSS clamp + DF-clear \xd0\xb4\xd0\xbb\xd1\x8f "
sys.exit(0 if needle in data else 1)
PY
then
  pass "MTU info line has valid UTF-8 для"
else
  fail_msg "MTU info line missing/corrupted UTF-8 для"
fi

# --- Source helpers ---
echo "== source install.sh (lib-only) =="
export WDTT_INSTALL_LIBONLY=1
export LOG_FILE="/dev/null"
# shellcheck disable=SC1090
if ! source "$INSTALL"; then
  fail_msg "sourcing install.sh with WDTT_INSTALL_LIBONLY=1 failed"
  echo "validation_test: FAILED"
  exit 1
fi
pass "sourced lib-only"

echo "== is_valid_udp_port =="
assert_true "46000 valid" is_valid_udp_port 46000
assert_true "1 valid" is_valid_udp_port 1
assert_true "65535 valid" is_valid_udp_port 65535
assert_false "0 invalid" is_valid_udp_port 0
assert_false "65536 invalid" is_valid_udp_port 65536
assert_false "abc invalid" is_valid_udp_port abc
assert_false "multi-token invalid" is_valid_udp_port "46000 -s 1.2.3.4"
assert_false "empty invalid" is_valid_udp_port ""

echo "== is_private_ipv4_cidr =="
assert_true "10.70.0.0/16" is_private_ipv4_cidr "10.70.0.0/16"
assert_true "192.168.1.0/24" is_private_ipv4_cidr "192.168.1.0/24"
assert_true "172.16.0.0/12" is_private_ipv4_cidr "172.16.0.0/12"
assert_false "public 8.8.8.0/24" is_private_ipv4_cidr "8.8.8.0/24"
assert_false "0.0.0.0/0" is_private_ipv4_cidr "0.0.0.0/0"
assert_false "metachar" is_private_ipv4_cidr '10.70.0.0/16;nft'
assert_false "spaces" is_private_ipv4_cidr "10.70.0.0/16 "
assert_false "ipv6" is_private_ipv4_cidr "fd00::/64"
assert_false "empty" is_private_ipv4_cidr ""

echo "== normalize_csqtt_peer_port =="
CSQTT_PEER_PORT=46000
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "46000" "keeps valid 46000"

CSQTT_PEER_PORT=abc
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "46000" "abc -> 46000"

CSQTT_PEER_PORT="46000 -j DROP"
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "46000" "injection -> 46000"

CSQTT_PEER_PORT=0
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "46000" "0 -> 46000"

CSQTT_PEER_PORT=70000
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "46000" "70000 -> 46000"

CSQTT_PEER_PORT=12345
normalize_csqtt_peer_port
assert_eq "$CSQTT_PEER_PORT" "12345" "keeps 12345"

echo "== normalize_raw_subnet =="
RAW_SUBNET="10.70.0.0/16"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "keeps default"

RAW_SUBNET="0.0.0.0/0"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "0.0.0.0/0 -> default"

RAW_SUBNET='10.70.0.0/16"; malicious'
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "nft injection -> default"

RAW_SUBNET="8.8.8.0/24"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "public -> default"

RAW_SUBNET="192.168.100.0/24"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "192.168.100.0/24" "keeps private /24"

if [[ "$fail" -ne 0 ]]; then
  echo "validation_test: FAILED"
  exit 1
fi
echo "validation_test: OK"
