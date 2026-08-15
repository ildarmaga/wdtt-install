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

echo "== contract: wdtt.service ExecStartPost applies xray + MTU =="
if awk '
  /^wdtt_service_routing_posts\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /wdtt-xray-rules\.sh up/ {xray=1}
  inside && /wdtt-mtu-rules\.sh up/ {mtu=1}
  END {exit (xray && mtu)?0:1}
' "$INSTALL"; then
  pass "xray-mode routing posts include xray-rules and mtu-rules"
else
  fail_msg "wdtt_service_routing_posts must apply both xray-rules and mtu-rules in xray mode"
fi

echo "== contract: wdtt.service ExecStopPost tears down xray + MTU =="
if awk '
  /^wdtt_service_routing_posts\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /wdtt-xray-rules\.sh down/ {xray=1}
  inside && /wdtt-mtu-rules\.sh down/ {mtu=1}
  END {exit (xray && mtu)?0:1}
' "$INSTALL"; then
  pass "xray-mode routing posts down xray + mtu"
else
  fail_msg "wdtt_service_routing_posts must down both xray-rules and mtu-rules in xray mode"
fi

echo "== contract: xray unit has no sleep-1 / wdtt-raw wait race =="
if awk '
  /^install_xray_rules\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /sleep 1; \/usr\/local\/bin\/wdtt-xray-rules\.sh up/ {bad=1}
  inside && /seq 1 40/ {bad=1}
  inside && /ip link show/ && /wdtt-raw/ {bad=1}
  inside && /wdtt-xray-rules\.sh up/ {up=1}
  END {exit (up && !bad)?0:1}
' "$INSTALL"; then
  pass "install_xray_rules applies helper without sleep-1 or wdtt-raw wait"
else
  fail_msg "xray ExecStartPost must apply rules immediately (no sleep 1 / seq 1 40 wdtt-raw wait)"
fi

echo "== contract: cmd_update refreshes helper and units =="
if awk '
  /^cmd_update\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /install_xray_rules_script|install -m 0755 .*wdtt-xray-rules\.sh/ {helper=1}
  inside && /install_xray_config/ {config=1}
  inside && /install_xray_rules$/ {xray=1}
  inside && /install_wdtt_service/ {unit=1}
  inside && /WDTT_RAW_NET=.*wdtt-xray-rules\.sh up/ {early_up=1}
  END {exit (helper && config && xray && unit && !early_up)?0:1}
' "$INSTALL"; then
  pass "cmd_update patches config before service-managed rules and refreshes both units"
else
  fail_msg "cmd_update must patch config, refresh helper/units, and avoid applying TPROXY before config"
fi

echo "== contract: cmd_update xray helper only when WITH_XRAY=1 =="
if awk '
  /^cmd_update\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /WITH_XRAY" == "1"/ {gated=1}
  inside && !gated && /install_xray_rules_script/ {bad=1}
  inside && !gated && /wdtt-xray-rules\.sh up/ {bad=1}
  END {exit (gated && !bad)?0:1}
' "$INSTALL"; then
  pass "cmd_update installs/invokes xray-rules up only inside WITH_XRAY=1"
else
  fail_msg "cmd_update must not install or invoke wdtt-xray-rules.sh up when WITH_XRAY=0"
fi

echo "== contract: cmd_update --direct tears down leftover xray =="
if awk '
  /^cmd_update\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /teardown_xray_routing_leftovers/ {tear=1}
  END {exit tear?0:1}
' "$INSTALL"; then
  pass "cmd_update calls teardown_xray_routing_leftovers"
else
  fail_msg "cmd_update --direct must teardown leftover xray helper/unit"
fi

echo "== contract: teardown downs helper then disable --now then rm =="
if awk '
  /^teardown_xray_routing_leftovers\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /wdtt-xray-rules\.sh down|helper.*down|"\$helper" down/ {down=1}
  inside && /disable --now wdtt-xray.service/ {dis=1}
  inside && /rm -f/ && /wdtt-xray-rules/ {rmh=1}
  END {exit (down && dis && rmh)?0:1}
' "$INSTALL"; then
  pass "teardown order: helper down, disable --now, rm helper"
else
  fail_msg "teardown_xray_routing_leftovers must down helper, disable --now xray, remove leftover binary"
fi

echo "== contract: install_wdtt_service helper gated on WITH_XRAY =="
if awk '
  /^install_wdtt_service\(\)/ {inside=1}
  inside && /^}/ {exit}
  inside && /WITH_XRAY/ && /== "1"/ {gated=1}
  inside && /install_xray_rules_script/ {helper=1}
  inside && !gated && /install_xray_rules_script/ {bad=1}
  END {exit (gated && helper && !bad)?0:1}
' "$INSTALL"; then
  pass "install_wdtt_service installs xray helper only when WITH_XRAY=1"
else
  fail_msg "install_wdtt_service must not install wdtt-xray-rules.sh in --direct"
fi

echo "== contract: UTF-8 MTU 'для' =="
py=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c "import sys" >/dev/null 2>&1; then
    py="$c"
    break
  fi
done
if [[ -n "$py" ]] && "$py" - "$INSTALL" <<'PY'
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

echo "== ensure_xray_tproxy_in =="
tproxy_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-tproxy-config.XXXXXX")"
XRAY_CONFIG_DIR="$tproxy_dir"
cat > "${XRAY_CONFIG_DIR}/config.json" <<'JSON'
{
  "inbounds": [
    {
      "tag": "tproxy-in",
      "listen": "0.0.0.0",
      "port": 9999,
      "protocol": "socks",
      "settings": {"customSetting": "kept"},
      "streamSettings": {"sockopt": {"mark": 7}}
    },
    {"tag": "tproxy-in", "listen": "0.0.0.0", "port": 12346}
  ],
  "outbounds": [
    {"tag": "custom-proxy", "protocol": "freedom"}
  ]
}
JSON
if ensure_xray_tproxy_in >/dev/null && python3 - "${XRAY_CONFIG_DIR}/config.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1], encoding="utf-8"))
items = [x for x in cfg["inbounds"] if x.get("tag") == "tproxy-in"]
assert len(items) == 1
item = items[0]
assert item["listen"] == "127.0.0.1"
assert item["port"] == 12346
assert item["protocol"] == "dokodemo-door"
assert item["settings"]["network"] == "udp"
assert item["settings"]["followRedirect"] is True
assert item["settings"]["customSetting"] == "kept"
assert item["streamSettings"]["sockopt"]["tproxy"] == "tproxy"
assert item["streamSettings"]["sockopt"]["mark"] == 7
assert cfg["outbounds"][0]["tag"] == "custom-proxy"
PY
then
  pass "existing Xray config gets safe tproxy-in without losing custom outbounds"
else
  fail_msg "ensure_xray_tproxy_in did not normalize existing config"
fi
rm -rf "$tproxy_dir"

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
assert_true "general /8 still valid for non-raw CIDR" is_private_ipv4_cidr "10.0.0.0/8"
assert_true "general /32 still valid for non-raw CIDR" is_private_ipv4_cidr "192.168.1.1/32"

echo "== is_valid_raw_subnet (panel /16-/29, no leading zeros) =="
assert_true "default /16" is_valid_raw_subnet "10.70.0.0/16"
assert_true "custom /16" is_valid_raw_subnet "10.80.0.0/16"
assert_true "private /24" is_valid_raw_subnet "192.168.100.0/24"
assert_true "private /29" is_valid_raw_subnet "10.80.0.0/29"
assert_false "raw /8 rejected" is_valid_raw_subnet "10.0.0.0/8"
assert_false "raw /32 rejected" is_valid_raw_subnet "192.168.1.1/32"
assert_false "raw /30 rejected" is_valid_raw_subnet "10.80.0.0/30"
assert_false "leading-zero octet" is_valid_raw_subnet "010.0.0.0/16"
assert_false "leading-zero second octet" is_valid_raw_subnet "10.070.0.0/16"
assert_false "public" is_valid_raw_subnet "8.8.8.0/16"
assert_false "empty raw" is_valid_raw_subnet ""

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

RAW_SUBNET="10.0.0.0/8"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "raw /8 -> default"

RAW_SUBNET="192.168.1.1/32"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "raw /32 -> default"

RAW_SUBNET="010.0.0.0/16"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.70.0.0/16" "leading-zero octet -> default"

RAW_SUBNET="10.80.0.0/29"
normalize_raw_subnet
assert_eq "$RAW_SUBNET" "10.80.0.0/29" "keeps private /29"

echo "== wdtt_service_routing_posts: xray vs --direct =="
if ! declare -F wdtt_service_routing_posts >/dev/null; then
  fail_msg "wdtt_service_routing_posts missing"
else
  IFACE="wdtt0"
  RAW_SUBNET="10.80.0.0/16"
  WITH_XRAY=1
  wdtt_service_routing_posts
  if [[ "${WDTT_EXEC_START_POST}" == *"wdtt-xray-rules.sh up"* && "${WDTT_EXEC_START_POST}" == *"wdtt-mtu-rules.sh up"* ]]; then
    pass "xray mode ExecStartPost keeps xray + MTU hooks"
  else
    fail_msg "xray mode must retain xray-rules and mtu up hooks"
  fi
  if [[ "${WDTT_EXEC_STOP_POST}" == *"wdtt-xray-rules.sh down"* && "${WDTT_EXEC_STOP_POST}" == *"wdtt-mtu-rules.sh down"* ]]; then
    pass "xray mode ExecStopPost keeps xray + MTU down"
  else
    fail_msg "xray mode must retain xray-rules and mtu down hooks"
  fi

  WITH_XRAY=0
  wdtt_service_routing_posts
  if [[ "${WDTT_EXEC_START_POST}" == *"wdtt-xray-rules.sh"* || "${WDTT_EXEC_STOP_POST}" == *"wdtt-xray-rules.sh"* ]]; then
    fail_msg "--direct unit must omit xray-rules hooks even if leftover helper exists"
  else
    pass "--direct omits xray-rules up/down (leftover helper ignored)"
  fi
  if [[ "${WDTT_EXEC_START_POST}" == *"wdtt-mtu-rules.sh up"* && "${WDTT_EXEC_STOP_POST}" == *"wdtt-mtu-rules.sh down"* ]]; then
    pass "--direct still applies MTU up/down"
  else
    fail_msg "--direct must still apply MTU rules"
  fi

  unit_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-unit.XXXXXX")"
  WDTT_SYSTEMD_DIR="$unit_dir"
  install_xray_rules_script() { XRAY_HELPER_INSTALLED=1; }
  install_mtu_rules_script() { :; }
  disable_legacy_panel_service() { :; }
  systemctl() { :; }
  write_install_inbound_env() { :; }
  info() { :; }

  WITH_PANEL=1
  WITH_XRAY=0
  XRAY_HELPER_INSTALLED=0
  install_wdtt_service "secret"
  unit=""
  [[ -f "${unit_dir}/wdtt.service" ]] && unit="$(cat "${unit_dir}/wdtt.service")"
  if [[ "$unit" == *"wdtt-xray-rules.sh"* ]]; then
    fail_msg "--direct generated unit still has xray-rules hooks"
  else
    pass "--direct generated wdtt.service omits xray-rules"
  fi
  if [[ "$XRAY_HELPER_INSTALLED" == "0" ]]; then
    pass "--direct does not install xray helper"
  else
    fail_msg "--direct must not install wdtt-xray-rules.sh"
  fi
  if [[ "$unit" == *"wdtt-mtu-rules.sh"* ]]; then
    pass "--direct generated unit still has MTU hooks"
  else
    fail_msg "--direct unit missing MTU hooks"
  fi

  WITH_XRAY=1
  XRAY_HELPER_INSTALLED=0
  install_wdtt_service "secret"
  unit="$(cat "${unit_dir}/wdtt.service")"
  if [[ "$unit" == *"wdtt-xray-rules.sh up"* && "$unit" == *"wdtt-xray-rules.sh down"* ]]; then
    pass "xray mode generated unit retains xray up/down hooks"
  else
    fail_msg "xray mode unit must include xray-rules up and down"
  fi
  if [[ "$XRAY_HELPER_INSTALLED" == "1" ]]; then
    pass "xray mode installs refreshed helper"
  else
    fail_msg "xray mode must install wdtt-xray-rules.sh"
  fi
  rm -rf "$unit_dir"
  unset WDTT_SYSTEMD_DIR
fi

echo "== teardown_xray_routing_leftovers: xray→direct upgrade =="
if ! declare -F teardown_xray_routing_leftovers >/dev/null; then
  fail_msg "teardown_xray_routing_leftovers missing"
else
  td_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-teardown.XXXXXX")"
  helper="${td_dir}/wdtt-xray-rules.sh"
  unit_dir="${td_dir}/systemd"
  mkdir -p "$unit_dir"
  printf '%s\n' "$unit_dir/wdtt-xray.service" > "${unit_dir}/wdtt-xray.service"
  write_exec() { printf '%s\n' "$2" > "$1"; chmod +x "$1"; }
  cat > "$helper" <<'EOF'
#!/bin/bash
echo "helper $*" >> "$(dirname "$0")/helper.log"
exit 0
EOF
  chmod +x "$helper"
  SYSTEMCTL_LOG="${td_dir}/systemctl.log"
  : > "$SYSTEMCTL_LOG"
  systemctl() { printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"; }
  WDTT_XRAY_RULES_BIN="$helper"
  WDTT_SYSTEMD_DIR="$unit_dir"
  teardown_xray_routing_leftovers
  if [[ -f "${td_dir}/helper.log" ]] && grep -q 'helper down' "${td_dir}/helper.log"; then
    pass "existing helper down before removal"
  else
    fail_msg "must invoke leftover helper down before rm"
  fi
  if grep -q 'disable --now wdtt-xray.service' "$SYSTEMCTL_LOG"; then
    pass "disable --now leftover wdtt-xray.service"
  else
    fail_msg "must systemctl disable --now wdtt-xray.service"
  fi
  if [[ ! -e "$helper" ]]; then
    pass "leftover helper binary removed"
  else
    fail_msg "must remove /usr/local/bin/wdtt-xray-rules.sh leftover"
  fi
  rm -rf "$td_dir"
  unset WDTT_XRAY_RULES_BIN WDTT_SYSTEMD_DIR
fi

# --- Issue #40: xray-rules template behaviour with mocked iptables/ip ---
XRAY_RULES="${ROOT}/templates/wdtt-xray-rules.sh"

write_exec() {
  local path="$1" body="$2"
  printf '%s\n' "$body" > "$path"
  chmod +x "$path"
}

run_xray_rules_up() {
  local mock_bin="$1" extra_raw_net="$2"
  env -i \
    PATH="${mock_bin}:/usr/bin:/bin" \
    HOME="$HOME" \
    WDTT_RAW_NET="$extra_raw_net" \
    WDTT_PANEL_PORT=2860 \
    WDTT_SUB_PORT=2096 \
    WDTT_PANEL_DB="${mock_bin}/../missing.db" \
    WDTT_XRAY_RULES_LOCK="${mock_bin}/../xray.lock" \
    bash "$XRAY_RULES" up
}

echo "== xray-rules: REDIRECT both ifaces even if wdtt-raw is down =="
if [[ ! -f "$XRAY_RULES" ]]; then
  fail_msg "missing $XRAY_RULES"
else
  mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-xray-rules.XXXXXX")"
  mock_bin="${mock_dir}/bin"
  mkdir -p "$mock_bin"
  log_file="${mock_dir}/iptables.log"
  write_exec "${mock_bin}/ip" "$(cat <<'EOF'
#!/bin/bash
if [[ "$*" == "-4 rule show" ]]; then
  echo "10066: from all fwmark 0x66/0xff lookup 166"
  exit 0
fi
if [[ "$*" == "-4 route show table 166" ]]; then
  echo "local default dev lo scope host"
  exit 0
fi
if [[ "$1" == "link" && "$2" == "show" ]]; then
  case "$3" in
    wdtt0) exit 0 ;;
    *) exit 1 ;;
  esac
fi
exit 0
EOF
)"
  write_exec "${mock_bin}/iptables" "$(cat <<EOF
#!/bin/bash
printf 'iptables' >> "${log_file}"
for a in "\$@"; do printf ' %s' "\$a" >> "${log_file}"; done
printf '\n' >> "${log_file}"
if [[ " \$* " == *" -C XRAY_TPROXY -p udp -j TPROXY "* ]]; then
  exit 0
fi
for a in "\$@"; do
  if [[ "\$a" == "-C" ]]; then
    exit 1
  fi
done
exit 0
EOF
)"
  if out="$(run_xray_rules_up "$mock_bin" "10.80.0.0/16" 2>&1)"; then
    pass "xray-rules up exits 0 with mocked iptables"
  else
    fail_msg "xray-rules up failed: $out"
  fi
  log=""
  [[ -f "$log_file" ]] && log="$(cat "$log_file")"
  if [[ "$log" == *"-A PREROUTING -i wdtt0 -j XRAY_REDIRECT"* ]]; then
    pass "wdtt0 REDIRECT jump applied"
  else
    fail_msg "missing wdtt0 REDIRECT jump"
  fi
  if [[ "$log" == *"-A PREROUTING -i wdtt-raw -j XRAY_REDIRECT"* ]] || [[ "$log" == *"-I INPUT 1 -i wdtt-raw"* ]]; then
    pass "wdtt-raw REDIRECT applied while link is down"
  else
    fail_msg "issue #40: wdtt-raw skipped when iface is down"
  fi
  if [[ "$log" == *"-d 10.80.0.0/16"* ]]; then
    pass "custom raw_subnet excluded in XRAY_REDIRECT"
  else
    fail_msg "custom raw_subnet 10.80.0.0/16 not in chain"
  fi
  if [[ "$log" == *"--dport 2860"* && "$log" == *"--dport 2096"* ]]; then
    pass "panel/sub ports excluded"
  else
    fail_msg "panel/sub ports must be excluded from REDIRECT"
  fi
  if [[ "$log" == *"-j REDIRECT"* && "$log" == *"--to-ports 12345"* ]]; then
    pass "TCP REDIRECT to xray :12345"
  else
    fail_msg "TCP REDIRECT to xray port missing"
  fi
  if [[ "$log" == *"-t mangle -N XRAY_TPROXY"* &&
        "$log" == *"-t mangle -A PREROUTING -i wdtt0 -p udp -j XRAY_TPROXY"* &&
        "$log" == *"-t mangle -A PREROUTING -i wdtt-raw -p udp -j XRAY_TPROXY"* ]]; then
    pass "inner UDP from wdtt0/wdtt-raw enters XRAY_TPROXY"
  else
    fail_msg "missing iface-scoped inner UDP TPROXY jumps"
  fi
  if [[ "$log" == *"-j TPROXY --on-port 12346 --on-ip 127.0.0.1 --tproxy-mark 0x66/0xff"* ]]; then
    pass "WebRTC/game UDP redirects to loopback tproxy-in"
  else
    fail_msg "missing UDP TPROXY target/mark"
  fi
  if [[ "$log" == *"-j DROP"* ]]; then
    fail_msg "must not DROP packets"
  else
    pass "no DROP in xray-rules"
  fi
  rm -rf "$mock_dir"
fi

echo "== xray-rules: TPROXY target failure is loud and adds no inner UDP jump =="
if [[ -f "$XRAY_RULES" ]]; then
  mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-xray-rules-fail.XXXXXX")"
  mock_bin="${mock_dir}/bin"
  mkdir -p "$mock_bin"
  log_file="${mock_dir}/iptables.log"
  write_exec "${mock_bin}/ip" $'#!/bin/bash\nexit 0\n'
  write_exec "${mock_bin}/iptables" "$(cat <<EOF
#!/bin/bash
printf 'iptables %s\n' "\$*" >> "${log_file}"
if [[ " \$* " == *" -j TPROXY "* ]]; then exit 1; fi
for a in "\$@"; do
  if [[ "\$a" == "-C" ]]; then exit 1; fi
done
exit 0
EOF
)"
  if run_xray_rules_up "$mock_bin" "10.80.0.0/16" >/dev/null 2>&1; then
    fail_msg "helper must fail when the kernel rejects the TPROXY target"
  else
    pass "helper returns non-zero when TPROXY target is unavailable"
  fi
  log=""
  [[ -f "$log_file" ]] && log="$(cat "$log_file")"
  if [[ "$log" == *"-A PREROUTING -i wdtt0 -p udp -j XRAY_TPROXY"* ||
        "$log" == *"-A PREROUTING -i wdtt-raw -p udp -j XRAY_TPROXY"* ]]; then
    fail_msg "failed TPROXY target must not receive live PREROUTING jumps"
  else
    pass "no live inner UDP jump is added after TPROXY setup failure"
  fi
  rm -rf "$mock_dir"
fi

echo "== xray-rules: invalid RAW_NET falls back to 10.70.0.0/16 =="
if [[ -f "$XRAY_RULES" ]]; then
  mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-xray-rules.XXXXXX")"
  mock_bin="${mock_dir}/bin"
  mkdir -p "$mock_bin"
  log_file="${mock_dir}/iptables.log"
  write_exec "${mock_bin}/ip" $'#!/bin/bash\nexit 0\n'
  write_exec "${mock_bin}/iptables" "$(cat <<EOF
#!/bin/bash
printf 'iptables' >> "${log_file}"
for a in "\$@"; do printf ' %s' "\$a" >> "${log_file}"; done
printf '\n' >> "${log_file}"
for a in "\$@"; do
  if [[ "\$a" == "-C" ]]; then
    exit 1
  fi
done
exit 0
EOF
)"
  run_xray_rules_up "$mock_bin" '10.80.0.0/16; nft add table inet pwn' >/dev/null 2>&1 || true
  log=""
  [[ -f "$log_file" ]] && log="$(cat "$log_file")"
  if [[ "$log" == *"nft add table"* || "$log" == *"10.80.0.0/16;"* ]]; then
    fail_msg "invalid RAW_NET must not reach iptables"
  else
    pass "invalid RAW_NET not interpolated into iptables"
  fi
  if [[ "$log" == *"-d 10.70.0.0/16"* ]]; then
    pass "invalid RAW_NET falls back to 10.70.0.0/16"
  else
    fail_msg "invalid RAW_NET must fall back to default exclusion"
  fi
  rm -rf "$mock_dir"
fi

xray_rules_log_for_net() {
  local net="$1"
  local mock_dir mock_bin log_file
  mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/wdtt-xray-rules.XXXXXX")"
  mock_bin="${mock_dir}/bin"
  mkdir -p "$mock_bin"
  log_file="${mock_dir}/iptables.log"
  write_exec "${mock_bin}/ip" $'#!/bin/bash\nexit 0\n'
  write_exec "${mock_bin}/iptables" "$(cat <<EOF
#!/bin/bash
printf 'iptables' >> "${log_file}"
for a in "\$@"; do printf ' %s' "\$a" >> "${log_file}"; done
printf '\n' >> "${log_file}"
for a in "\$@"; do
  if [[ "\$a" == "-C" ]]; then
    exit 1
  fi
done
exit 0
EOF
)"
  run_xray_rules_up "$mock_bin" "$net" >/dev/null 2>&1 || true
  [[ -f "$log_file" ]] && cat "$log_file"
  rm -rf "$mock_dir"
}

echo "== xray-rules: RFC1918 / octets / public bypass =="
if [[ -f "$XRAY_RULES" ]]; then
  log="$(xray_rules_log_for_net '8.8.8.0/16')"
  if [[ "$log" == *"-d 8.8.8.0/16"* ]]; then
    fail_msg "public 8.8.8.0/16 must not reach XRAY_REDIRECT"
  else
    pass "public CIDR rejected"
  fi
  if [[ "$log" == *"-d 10.70.0.0/16"* ]]; then
    pass "public CIDR falls back to 10.70.0.0/16"
  else
    fail_msg "public CIDR must fall back to default"
  fi

  log="$(xray_rules_log_for_net '10.256.0.0/16')"
  if [[ "$log" == *"-d 10.256.0.0/16"* ]]; then
    fail_msg "invalid octet 256 must not reach iptables"
  else
    pass "invalid octet rejected"
  fi

  log="$(xray_rules_log_for_net '10.0.0.0/8')"
  if [[ "$log" == *"-d 10.0.0.0/8"* ]]; then
    fail_msg "raw /8 must not reach XRAY_REDIRECT"
  else
    pass "raw /8 rejected"
  fi
  if [[ "$log" == *"-d 10.70.0.0/16"* ]]; then
    pass "raw /8 falls back to 10.70.0.0/16"
  else
    fail_msg "raw /8 must fall back to default"
  fi

  log="$(xray_rules_log_for_net '192.168.1.1/32')"
  if [[ "$log" == *"-d 192.168.1.1/32"* ]]; then
    fail_msg "raw /32 must not reach XRAY_REDIRECT"
  else
    pass "raw /32 rejected"
  fi
  if [[ "$log" == *"-d 10.70.0.0/16"* ]]; then
    pass "raw /32 falls back to 10.70.0.0/16"
  else
    fail_msg "raw /32 must fall back to default"
  fi

  log="$(xray_rules_log_for_net '010.0.0.0/16')"
  if [[ "$log" == *"-d 010.0.0.0/16"* || "$log" == *"-d 8.0.0.0/16"* ]]; then
    fail_msg "leading-zero octet must not reach iptables"
  else
    pass "leading-zero octet rejected"
  fi
  if [[ "$log" == *"-d 10.70.0.0/16"* ]]; then
    pass "leading-zero octet falls back to default"
  else
    fail_msg "leading-zero octet must fall back to default"
  fi

  log="$(xray_rules_log_for_net '10.80.0.0/29')"
  if [[ "$log" == *"-d 10.80.0.0/29"* ]]; then
    pass "raw /29 accepted"
  else
    fail_msg "10.80.0.0/29 must be accepted"
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "validation_test: FAILED"
  exit 1
fi
echo "validation_test: OK"
