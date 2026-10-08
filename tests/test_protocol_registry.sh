#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
if [[ -n "${SBP_TEST_JQ:-}" ]]; then
  [[ -x "$SBP_TEST_JQ" ]] || { echo 'SBP_TEST_JQ must name an executable' >&2; exit 1; }
  jq(){ "$SBP_TEST_JQ" "$@"; }
fi
export SBP_SKIP_DEPS=1 SBP_SKIP_ROOT=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SBP_DEPS_SENTINEL="$test_root/runtime/.deps_ok" SB_DIR="$test_root/state"
export SOCKS_NODES_JSON="$test_root/state/socks-nodes.json"
export WGCF_DIR="$test_root/state/wgcf" BIN_PATH="$test_root/bin/sing-box"
unset ENABLE_WARP
# shellcheck source=../sing-box-plus.sh
source "$repo_root/sing-box-plus.sh"
ensure_dirs

for value in 1 08 08001 65535; do valid_port "$value"; done
for value in '' 0 -1 65536 123456 1e2 '1+1' 0x1; do
  if valid_port "$value"; then echo "FAIL: invalid port accepted: $value" >&2; exit 1; fi
done
[[ "${#SBP_PORT_VARS[@]}" == 10 && "${#SBP_PROTOCOL_NETWORKS[@]}" == 10 ]]
[[ "${#SBP_PROTOCOL_LABELS[@]}" == 10 && "${#SBP_LINK_NAMES[@]}" == 10 ]]
[[ "${#SBP_PROTOCOLS[@]}" == 10 && "${#SBP_ALL_PORT_VARS[@]}" == 20 ]]
if protocol_network unsupported; then echo 'FAIL: unknown protocol accepted' >&2; exit 1; fi

index=0
for var in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS \
    PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS; do
  printf -v "$var" '%s' "$((21001+index))"
  printf -v "${var}_W" '%s' "$((22001+index))"
  index=$((index+1))
done
cat > "$test_root/direct.expected" <<'EOF'
21001/tcp
21002/tcp
21003/tcp
21004/udp
21005/tcp
21006/udp
21007/tcp
21007/udp
21008/tcp
21008/udp
21009/udp
21010/tcp
EOF
ufw(){
  case "${1:-}" in
    status) printf '%s\n' 'Status: active' ;;
    allow) printf '%s\n' "$2" >> "$test_root/firewall.actual" ;;
    reload) return 0 ;;
    *) return 1 ;;
  esac
}
assert_rules(){
  if ! diff -u <(sort "$1") <(sort "$2"); then echo 'FAIL: firewall rule contract' >&2; exit 1; fi
}

ENABLE_WARP=false; TLS_CERT_MODE=self_signed
open_firewall
assert_rules "$test_root/direct.expected" "$test_root/firewall.actual"
: > "$test_root/firewall.actual"
ENABLE_WARP=true; WARP_BACKEND=proxy; WARP_SOCKS_HOST=127.0.0.1; WARP_SOCKS_PORT=40000
open_firewall
cat "$test_root/direct.expected" > "$test_root/warp.expected"
sed 's/^21/22/' "$test_root/direct.expected" >> "$test_root/warp.expected"
assert_rules "$test_root/warp.expected" "$test_root/firewall.actual"
: > "$test_root/firewall.actual"
ENABLE_WARP=false; TLS_CERT_MODE=acme
TLS_ACME_DISABLE_HTTP_CHALLENGE=false; TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE=false
open_firewall
cat "$test_root/direct.expected" > "$test_root/acme.expected"
printf '%s\n' 80/tcp 443/tcp >> "$test_root/acme.expected"
assert_rules "$test_root/acme.expected" "$test_root/firewall.actual"

cat > "$test_root/node.json" <<'EOF'
{"nodes":[{"id":"sbp-socks-0000000000000001","name":"test","protocol":"hy2","port":23004,"dns_mode":"local","outbound":{"type":"socks","tag":"sbp-socks-0000000000000001-out","server":"192.0.2.50","server_port":1080,"version":"5","domain_resolver":"dns-doh-primary"}}]}
EOF
validate_socks_nodes "$test_root/node.json" >/dev/null
for value in '["hy2"]' 'null' '4' '{"id":"hy2"}' '"unsupported"'; do
  jq --argjson value "$value" '.nodes[0].protocol = $value' "$test_root/node.json" > "$test_root/invalid-node.json"
  if validate_socks_nodes "$test_root/invalid-node.json" > /dev/null 2>&1; then
    echo "FAIL: invalid protocol value accepted: $value" >&2
    exit 1
  fi
done

node_protocols='["vless-reality","vless-grpcr","trojan-reality","hy2","vmess-ws","hy2-obfs","ss2022","ss","tuic-v5","anytls"]'
registry_test_nodes=$(jq -cn --argjson protocols "$node_protocols" \
  '{nodes:[range(0;10) as $i | {protocol:$protocols[$i],port:(23001+$i)}]}')
load_socks_nodes(){ printf '%s\n' "$registry_test_nodes"; }
socks_node_firewall_rules > "$test_root/socks.actual"
sed 's/^21/23/' "$test_root/direct.expected" > "$test_root/socks.expected"
assert_rules "$test_root/socks.expected" "$test_root/socks.actual"
printf '%s\n' 'PASS: all protocol firewall rules, WARP activation, ACME ports and SOCKS protocols'
