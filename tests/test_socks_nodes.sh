#!/usr/bin/env bash
# Sourced management functions consume the fixture settings.
# shellcheck disable=SC2034
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
main_script=${SBP_TEST_SCRIPT:-$repo_root/sing-box-plus.sh}
test_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
test_root=$(mktemp -d "$test_parent/sbp-socks-test.XXXXXX")
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    export MSYS2_ARG_CONV_EXCL='/CN=;/vm;/edge-ws'
    test_root=$(cygpath -m "$test_root")
    test_parent=$(cygpath -m "$test_parent")
    ;;
esac
cleanup(){
  local status=$? log latest=""
  if (( status != 0 )); then
    for log in "$test_root"/*.log; do
      [[ -f "$log" ]] || continue
      if [[ -z "$latest" || "$log" -nt "$latest" ]]; then latest="$log"; fi
    done
    if [[ -n "$latest" ]]; then printf '\n%s\n' "${latest##*/}" >&2; tail -20 "$latest" >&2; fi
  fi
  case "$test_root" in
    "$test_parent"/sbp-socks-test.*) rm -rf -- "$test_root" ;;
    *) echo 'Refusing to clean an unexpected test directory' >&2 ;;
  esac
}
trap cleanup EXIT
if [[ -n "${SBP_TEST_JQ:-}" ]]; then jq(){ "$SBP_TEST_JQ" "$@"; }; fi
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 1; }
export SBP_SKIP_DEPS=1 SBP_SKIP_ROOT=1 ENABLE_WARP=false
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SB_DIR="$test_root/state" CONF_JSON="$test_root/state/config.json"
export DATA_DIR="$test_root/state/data" CERT_DIR="$test_root/state/cert"
export WGCF_DIR="$test_root/state/wgcf" ROUTE_JSON="$test_root/state/routes.json"
export SHARE_LINKS_FILE="$test_root/state/share-links.txt"
export SOCKS_NODES_JSON="$test_root/state/socks-nodes.json"
export SOCKS_SHARE_LINKS_FILE="$test_root/state/socks-share-links.txt"
export BIN_PATH="${SBP_REAL_SING_BOX_BIN:-$test_root/bin/sing-box}"
export SYSTEMD_SERVICE=test-sing-box.service
export SBP_SERVICE_STABILITY_CHECKS=3 SBP_SERVICE_STABILITY_INTERVAL=0

# shellcheck source=../sing-box-plus.sh
source "$main_script"
ensure_dirs
mkdir -p "$SBP_BIN_DIR"
if [[ -z "${SBP_REAL_SING_BOX_BIN:-}" ]]; then
  cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) echo 'sing-box version 1.14.2' ;;
  check) [[ ! -f "$SB_DIR/fail-check" ]] ;;
  *) exit 1 ;;
esac
EOF
  chmod 755 "$BIN_PATH"
fi
get_ip(){ printf '%s\n' 203.0.113.10; }
default_ipv4_address(){ return 0; }
default_ipv6_address(){ return 0; }
open_firewall(){ printf '%s\n' firewall >> "$test_root/firewall.calls"; }
ufw(){
  if [[ "$1" == status ]]; then printf 'Status: active\n';
  else printf '%s\n' "$*" >> "$test_root/ufw.calls"; fi
}
systemctl(){
  case "$1" in
    is-active)
      if [[ -f "$test_root/delayed-failure" ]]; then
        rm -f "$test_root/delayed-failure"
        return 1
      fi
      [[ -f "$test_root/active" ]]
      ;;
    show) echo 4242 ;;
    restart)
      echo restart >> "$test_root/restarts"
      if [[ -f "$test_root/fail-restart-once" ]]; then
        rm -f "$test_root/fail-restart-once"; return 1
      fi
      if [[ -f "$test_root/fail-delayed-once" ]]; then
        mv "$test_root/fail-delayed-once" "$test_root/delayed-failure"
      fi
      ;;
    *) return 1 ;;
  esac
}
assert_equal(){
  [[ "$1" == "$2" ]] || { printf 'FAIL: %s (expected=%s actual=%s)\n' "$3" "$1" "$2" >&2; exit 1; }
}
assert_json(){ jq -e "$2" "$1" >/dev/null || { echo "FAIL: $3" >&2; exit 1; }; }
hash(){ sha256sum "$1" | cut -d' ' -f1; }
expect_rejected_link(){
  if socks_node_outbound_from_link "$1" sbp-socks-1234567890abcdef-out > "$test_root/rejected.json" 2>/dev/null; then
    echo 'FAIL: invalid SOCKS URL was accepted' >&2; exit 1
  fi
}

UUID=11111111-1111-4111-8111-111111111111
HY2_PWD=hy2-password HY2_PWD2=hy2-obfs-password HY2_OBFS_PWD=obfs-password
REALITY_PRIV=reality-private REALITY_PUB=reality-public REALITY_SID=1234abcd
SS2022_KEY=ss2022-key SS_PWD=ss-password ANYTLS_PWD=anytls-password
TUIC_UUID="$UUID" TUIC_PWD="$UUID"
if [[ -n "${SBP_REAL_SING_BOX_BIN:-}" ]]; then
  pair="$($BIN_PATH generate reality-keypair)"
  REALITY_PRIV="$(awk -F': ' '$1=="PrivateKey" {print $2; exit}' <<< "$pair")"
  REALITY_PUB="$(awk -F': ' '$1=="PublicKey" {print $2; exit}' <<< "$pair")"
  SS2022_KEY="$($BIN_PATH generate rand --base64 32)"
fi
save_creds
port=11001
for var in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
    PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
  printf -v "$var" '%s' "$port"; port=$((port+1))
done
save_ports
save_env
write_config > "$test_root/initial.log" 2>&1 || { cat "$test_root/initial.log" >&2; exit 1; }
print_links_grouped > "$test_root/initial-links.log"
assert_json "$CONF_JSON" '(.inbounds | length) == 10' 'feature must be opt-in'
[[ ! -e "$SOCKS_NODES_JSON" && ! -e "$SOCKS_SHARE_LINKS_FILE" ]] || { echo 'FAIL: default deployment creates SOCKS state' >&2; exit 1; }
main_links_hash=$(hash "$SHARE_LINKS_FILE")

# Preserve URI userinfo literally, including plus signs, backslashes and UTF-8.
socks_node_outbound_from_link 'socks5h://user+name:p%40ss%3A%5C%25%E6%A1%9C@[2001:db8::1]:01080/#edge' \
  sbp-socks-1234567890abcdef-out > "$test_root/parsed.json"
assert_json "$test_root/parsed.json" '.server == "2001:db8::1" and .server_port == 1080 and .username == "user+name" and .password == "p@ss:\\%桜"' \
  'IPv6 and encoded credentials must round-trip'
socks_node_outbound_from_link "socks5://$(printf 'user:pass' | b64enc)@proxy.example.com:1080" sbp-socks-1234567890abcdef-out > "$test_root/parsed.json"
assert_json "$test_root/parsed.json" '.username == "user" and .password == "pass"' 'base64 credentials'
socks_node_outbound_from_link "socks5h://$(printf 'user:pass@proxy.example.com:1080' | b64enc)" sbp-socks-1234567890abcdef-out > "$test_root/parsed.json"
assert_json "$test_root/parsed.json" '.server == "proxy.example.com"' 'base64 authority'
socks_node_outbound_from_link 'socks5://proxy.example.com:1080?user=a%2Bb&pass=c%26d' sbp-socks-1234567890abcdef-out > "$test_root/parsed.json"
assert_json "$test_root/parsed.json" '.username == "a+b" and .password == "c&d"' 'query credentials'
for invalid in 'http://proxy.example.com:1080' 'socks4://proxy.example.com:1080' 'socks5://proxy.example.com:0' \
    'socks5://proxy.example.com:65536' 'socks5://proxy.example.com:99999999999999999' 'socks5://proxy.example.com:abc' \
    'socks5://u:p%ZZ@proxy.example.com:1080' 'socks5://u:p%00@proxy.example.com:1080' \
    'socks5://u:p%0A@proxy.example.com:1080' 'socks5://proxy.example.com:1080?version=4'; do expect_rejected_link "$invalid"; done
assert_equal '%E6%A1%9C%20%2B' "$(urlenc '桜 +')" 'node names must use UTF-8 URI encoding'

# Exercise the interactive creation path and keep its links out of the normal file.
touch "$test_root/active"
add_socks_node > "$test_root/add.log" 2>&1 <<'EOF' || { cat "$test_root/add.log" >&2; exit 1; }
socks5h://test:secret@proxy.example.com:1080#%E6%A1%9C
1

13001
n
EOF
assert_json "$SOCKS_NODES_JSON" '.nodes | length == 1' 'interactive creation persists one node'
assert_json "$SOCKS_NODES_JSON" '.nodes[0].name == "桜" and .nodes[0].dns_mode == "remote" and .nodes[0].protocol == "vless-reality"' 'protocol and SOCKS5H import'
assert_json "$SOCKS_NODES_JSON" '.nodes[0].system_ipv6 == false' 'system IPv6 is opt-in'
assert_equal "$main_links_hash" "$(hash "$SHARE_LINKS_FILE")" 'extra nodes must not modify the normal link file'
assert_equal 1 "$(wc -l < "$SOCKS_SHARE_LINKS_FILE" | tr -d ' ')" 'separate link file'
grep -Fq '#%E6%A1%9C' "$SOCKS_SHARE_LINKS_FILE"
if socks_node_port_available 11001 || socks_node_port_available 13001 || socks_node_port_available 40000; then
  echo 'FAIL: existing node and WARP proxy ports must be reserved' >&2; exit 1
fi

# Build one extra node for every protocol; global rules must not steal their egress.
current=$(load_socks_nodes)
printf '%s\n' "$current" > "$test_root/candidate.json"
index=1
for protocol in vless-grpcr trojan-reality hy2 vmess-ws hy2-obfs ss2022 ss tuic-v5 anytls; do
  printf -v suffix '%016x' "$index"
  id="sbp-socks-$suffix"
  outbound=$(socks_node_outbound_from_link 'socks5://test:secret@127.0.0.1:1080' "$id-out")
  jq -c --arg id "$id" --arg protocol "$protocol" --argjson port "$((13001+index))" --argjson outbound "$outbound" \
    '.nodes += [{id:$id,name:$protocol,protocol:$protocol,port:$port,dns_mode:"local",outbound:$outbound}]' \
    "$test_root/candidate.json" > "$test_root/next.json"
  mv "$test_root/next.json" "$test_root/candidate.json"
  index=$((index+1))
done
printf '%s\n' '{"rules":[{"domain_suffix":["example.com"],"outbound":"direct"}],"rule_set":[],"outbounds":[],"default_outbound":"direct"}' > "$ROUTE_JSON"
apply_socks_nodes "$test_root/candidate.json" "$current" > "$test_root/all-protocols.log" 2>&1 \
  || { cat "$test_root/all-protocols.log" >&2; exit 1; }
assert_json "$CONF_JSON" '(.inbounds | length) == 20 and (.outbounds | length) == 11' 'all extra protocols and outbounds'
assert_json "$CONF_JSON" '.route.rules[0].action == "route" and .route.rules[0].inbound[0] == (.inbounds[10].tag)' 'remote DNS node must route first'
assert_json "$CONF_JSON" '.route.rules[1].action == "resolve" and .route.rules[2].action == "route" and .route.rules[-1].outbound == "direct"' 'local DNS resolves before routing and before global rules'
jq -en --slurpfile config "$CONF_JSON" --slurpfile nodes "$SOCKS_NODES_JSON" '
  all($nodes[0].nodes[]; . as $node |
    ($config[0].inbounds[] | select(.tag == $node.id)) as $extra |
    ($config[0].inbounds[] | select(.tag == $node.protocol)) as $base |
    ($extra | del(.tag,.listen_port)) == ($base | del(.tag,.listen_port)))' >/dev/null
assert_equal 10 "$(wc -l < "$SOCKS_SHARE_LINKS_FILE" | tr -d ' ')" 'all protocols have separate links'
assert_equal "$main_links_hash" "$(hash "$SHARE_LINKS_FILE")" 'normal links remain separate'
main --socks-links > "$test_root/socks-only.log"
grep -Fq 'SOCKS 出口节点' "$test_root/socks-only.log"
if grep -Eq '直连节点|WARP 节点' "$test_root/socks-only.log"; then
  echo 'FAIL: standalone SOCKS link command mixed in normal nodes' >&2; exit 1
fi
main --socks-nodes > "$test_root/menu.log" <<'EOF'
0
EOF
grep -Fq '1) 导入链接并创建节点' "$test_root/menu.log"
socks_node_firewall_rules > "$test_root/firewall.rules"
assert_equal 12 "$(wc -l < "$test_root/firewall.rules" | tr -d ' ')" 'TCP/UDP firewall rules follow protocols'
grep -Fxq '13005/tcp' "$test_root/firewall.rules"
grep -Fxq '13004/udp' "$test_root/firewall.rules"

# Existing files without the new field stay valid. Enabling IPv6 changes only one exit.
(
  cp "$SOCKS_NODES_JSON" "$test_root/ipv6-original-nodes.json"
  cp "$CONF_JSON" "$test_root/ipv6-original-config.json"
  trap 'cp "$test_root/ipv6-original-nodes.json" "$SOCKS_NODES_JSON"; cp "$test_root/ipv6-original-config.json" "$CONF_JSON"' EXIT
  default_ipv6_address(){ printf '%s\n' '2001:db8::2'; }
  links_hash=$(hash "$SOCKS_SHARE_LINKS_FILE")
  configure_socks_node_ipv6 > "$test_root/ipv6-enable.log" 2>&1 <<'EOF'
1
2
EOF
  assert_json "$SOCKS_NODES_JSON" '.nodes[0].system_ipv6 == true and .nodes[0].dns_mode == "remote" and all(.nodes[1:][]; .system_ipv6 != true)' 'enable IPv6 for only the selected legacy node'
  assert_json "$CONF_JSON" '[.route.rules[] | select(.inbound == ["'"$(jq -r '.nodes[0].id' "$SOCKS_NODES_JSON")"'"])] |
    length == 5 and .[0].action == "resolve" and .[0].strategy == "prefer_ipv4"
    and .[1].action == "resolve" and .[1].strategy == "ipv4_only"
    and .[2].ip_cidr == ["0.0.0.0/0"] and .[2].outbound != "sbp-socks-ipv6"
    and .[3].ip_cidr == ["::/0"] and .[3].outbound == "sbp-socks-ipv6"' 'resolve SOCKS5H locally and select IPv4 before IPv6'
  assert_json "$CONF_JSON" 'any(.outbounds[]; .tag == "sbp-socks-ipv6" and .inet6_bind_address == "2001:db8::2" and .domain_resolver.strategy == "ipv6_only")' 'bind the system IPv6 route source, including tunnels'
  assert_equal "$links_hash" "$(hash "$SOCKS_SHARE_LINKS_FILE")" 'IPv6 mode retains credentials, endpoint and port'
  enabled_state=$(load_socks_nodes) enabled_hash=$(hash "$SOCKS_NODES_JSON") enabled_config_hash=$(hash "$CONF_JSON")
  jq '.nodes[0].system_ipv6 = false' "$SOCKS_NODES_JSON" > "$test_root/ipv6-disable.json"
  touch "$test_root/fail-restart-once"
  if apply_socks_nodes "$test_root/ipv6-disable.json" "$enabled_state" > "$test_root/ipv6-rollback.log" 2>&1; then
    echo 'FAIL: IPv6 mode change must roll back on restart failure' >&2; exit 1
  fi
  assert_equal "$enabled_hash" "$(hash "$SOCKS_NODES_JSON")" 'failed mode change restores the IPv6 switch'
  assert_equal "$enabled_config_hash" "$(hash "$CONF_JSON")" 'failed mode change restores IPv6 routing'
  configure_socks_node_ipv6 > "$test_root/ipv6-disable.log" 2>&1 <<'EOF'
1
1
EOF
  assert_json "$CONF_JSON" '.route.rules[0].action == "route" and all(.outbounds[]; .tag != "sbp-socks-ipv6")' 'disabling restores SOCKS5H DNS and removes unused IPv6 outbound'
  current=$(load_socks_nodes) previous_hash=$(hash "$SOCKS_NODES_JSON") previous_config_hash=$(hash "$CONF_JSON")
  default_ipv6_address(){ :; }
  jq '.nodes[0].system_ipv6 = true' "$SOCKS_NODES_JSON" > "$test_root/ipv6-unavailable.json"
  if apply_socks_nodes "$test_root/ipv6-unavailable.json" "$current" > "$test_root/ipv6-unavailable.log" 2>&1; then
    echo 'FAIL: missing system IPv6 route must reject activation' >&2; exit 1
  fi
  assert_equal "$previous_hash" "$(hash "$SOCKS_NODES_JSON")" 'missing IPv6 route preserves node state'
  assert_equal "$previous_config_hash" "$(hash "$CONF_JSON")" 'missing IPv6 route preserves active config'
)

# Reallocation must reserve existing extras and every newly generated base port.
(
  cp "$SB_DIR/ports.env" "$test_root/original-ports.env"
  trap 'cp "$test_root/original-ports.env" "$SB_DIR/ports.env"' EXIT
  for var in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
      PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
    printf -v "$var" '%s' ''
  done
  gen_port(){
    local candidate=13001
    while [[ " ${PORTS[*]} " == *" $candidate "* ]]; do candidate=$((candidate+1)); done
    printf '%s\n' "$candidate"
  }
  save_all_ports
  assert_equal 20 "$(cut -d= -f2 "$SB_DIR/ports.env" | sort -u | wc -l | tr -d ' ')" \
    'newly allocated ports must be distinct'
  [[ "$PORT_VLESSR" == 13011 ]] || { echo 'FAIL: extra ports must be reserved during rotation' >&2; exit 1; }
)

# System connection changes propagate to extra config and links without replacing ports.
REALITY_SERVER=edge.example.com TCP_KEEP_ALIVE=45s TCP_KEEP_ALIVE_INTERVAL=20s
GRPC_SERVICE=edge-grpc VMESS_WS_PATH=/edge-ws
save_env
write_config > "$test_root/settings.log" 2>&1
print_links_grouped > "$test_root/grouped-links.log"
grep -Fq 'sni=edge.example.com' "$SOCKS_SHARE_LINKS_FILE"
assert_json "$CONF_JSON" 'all(.inbounds[]; .tcp_keep_alive == "45s" and .tcp_keep_alive_interval == "20s")' 'extra nodes inherit tuning'
assert_json "$CONF_JSON" 'all(.outbounds[] | select(.tag | startswith("sbp-socks-")); .tcp_keep_alive == "45s")' 'SOCKS dialers inherit tuning'
assert_equal 10 "$(wc -l < "$SHARE_LINKS_FILE" | tr -d ' ')" 'grouped printing still keeps normal file separate'
last_group=$(grep -E '^【|【直连|【SOCKS' "$test_root/grouped-links.log" | tail -1)
[[ "$last_group" == *'SOCKS 出口节点'* ]] || { echo 'FAIL: extra links must print last' >&2; exit 1; }
(
  TLS_CERT_MODE=manual TLS_DOMAIN=public.example.com
  node_share_link anytls 13010 'TLS node' 203.0.113.10
) > "$test_root/public-link.txt"
grep -Fq '@public.example.com:13010?insecure=0&sni=public.example.com' "$test_root/public-link.txt"

# Duplicate ports, malformed state, and conflicting outbound tags fail before activation.
current=$(load_socks_nodes)
state_hash=$(hash "$SOCKS_NODES_JSON") config_hash=$(hash "$CONF_JSON")
jq '.nodes[1].port = .nodes[0].port' "$SOCKS_NODES_JSON" > "$test_root/invalid.json"
if apply_socks_nodes "$test_root/invalid.json" "$current" > "$test_root/invalid.log" 2>&1; then echo 'FAIL: duplicate port accepted' >&2; exit 1; fi
assert_equal "$state_hash" "$(hash "$SOCKS_NODES_JSON")" 'invalid candidates preserve state'
assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'invalid candidates preserve config'
for invalid_filter in '.nodes[0].outbound.server = ""' '.nodes[0].outbound.password = ("a" * 256)' \
    '.nodes[0].name = "bad\u000aname"' '.nodes[0].protocol = "unknown"' \
    '.nodes[0].system_ipv6 = "true"' '.nodes[0].system_ipv6 = null'; do
  jq "$invalid_filter" "$SOCKS_NODES_JSON" > "$test_root/invalid.json"
  if validate_socks_nodes "$test_root/invalid.json" >/dev/null 2>&1; then echo 'FAIL: malformed node accepted' >&2; exit 1; fi
done
(
  cp "$SOCKS_NODES_JSON" "$test_root/valid-nodes.json"
  trap 'cp "$test_root/valid-nodes.json" "$SOCKS_NODES_JSON"' EXIT
  printf '{' > "$SOCKS_NODES_JSON"
  if write_config > "$test_root/malformed-state.log" 2>&1; then echo 'FAIL: malformed state must fail closed' >&2; exit 1; fi
  assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'malformed state preserves active config'
)
(
  cp "$ROUTE_JSON" "$test_root/valid-routes.json"
  trap 'cp "$test_root/valid-routes.json" "$ROUTE_JSON"' EXIT
  jq --slurpfile nodes "$SOCKS_NODES_JSON" '.outbounds += [$nodes[0].nodes[0].outbound]' "$ROUTE_JSON" > "$test_root/conflicting-routes.json"
  cp "$test_root/conflicting-routes.json" "$ROUTE_JSON"
  if write_config > "$test_root/tag-conflict.log" 2>&1; then echo 'FAIL: conflicting outbound tag accepted' >&2; exit 1; fi
  assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'outbound collision preserves active config'
)
jq '.nodes[0].port = 11001' "$SOCKS_NODES_JSON" > "$test_root/conflict.json"
if apply_socks_nodes "$test_root/conflict.json" "$current" > "$test_root/conflict.log" 2>&1; then echo 'FAIL: base port conflict accepted' >&2; exit 1; fi
assert_equal "$state_hash" "$(hash "$SOCKS_NODES_JSON")" 'base port conflict rolls back'
jq '.nodes[0].name = "changed"' "$SOCKS_NODES_JSON" > "$test_root/candidate.json"
for failure in fail-restart-once fail-delayed-once; do
  touch "$test_root/$failure"
  if apply_socks_nodes "$test_root/candidate.json" "$current" > "$test_root/$failure.log" 2>&1; then echo "FAIL: $failure must roll back" >&2; exit 1; fi
  assert_equal "$state_hash" "$(hash "$SOCKS_NODES_JSON")" 'restart failure rolls back state'
  assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'restart failure rolls back config'
done
if [[ -z "${SBP_REAL_SING_BOX_BIN:-}" ]]; then
  touch "$SB_DIR/fail-check"
  if apply_socks_nodes "$test_root/candidate.json" "$current" > "$test_root/fail-check.log" 2>&1; then echo 'FAIL: core failure must roll back' >&2; exit 1; fi
  rm -f "$SB_DIR/fail-check"
  assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'core rejection preserves config'
fi
(
  cp "$SB_DIR/env.conf" "$test_root/previous-env.conf"
  trap 'cp "$test_root/previous-env.conf" "$SB_DIR/env.conf"' EXIT
  ENABLE_WARP=true WARP_BACKEND=proxy
  SBP_ENABLE_WARP_OVERRIDE=""
  save_env
  ensure_warp_backend(){ return 1; }
  if apply_socks_nodes "$test_root/candidate.json" "$current" > "$test_root/warp-unavailable.log" 2>&1; then
    echo 'FAIL: SOCKS node edits must not disable an existing WARP configuration' >&2; exit 1
  fi
  assert_equal "$state_hash" "$(hash "$SOCKS_NODES_JSON")" 'unavailable WARP preserves SOCKS state'
  assert_equal "$config_hash" "$(hash "$CONF_JSON")" 'unavailable WARP preserves existing nodes'
  assert_equal true "$(bash -c 'source "$1"; echo "$ENABLE_WARP"' _ "$SB_DIR/env.conf")" 'existing WARP switch must be retained'
)
if apply_socks_nodes "$test_root/candidate.json" '{"nodes":[]}' > "$test_root/stale.log" 2>&1; then echo 'FAIL: stale edit must fail' >&2; exit 1; fi
mkdir "$SB_DIR/.socks-nodes.lock"
if apply_socks_nodes "$test_root/candidate.json" "$current" > "$test_root/locked.log" 2>&1; then echo 'FAIL: concurrent edit must fail' >&2; exit 1; fi
rmdir "$SB_DIR/.socks-nodes.lock"

if [[ -n "${SBP_REAL_SING_BOX_BIN:-}" ]]; then
  "$BIN_PATH" check -c "$CONF_JSON"
  probe_python=${SBP_TEST_PYTHON:-python3}
  (
    cp "$SOCKS_NODES_JSON" "$test_root/probe-original-nodes.json"
    cp "$CONF_JSON" "$test_root/probe-original-config.json"
    trap 'cp "$test_root/probe-original-nodes.json" "$SOCKS_NODES_JSON"; cp "$test_root/probe-original-config.json" "$CONF_JSON"' EXIT
    default_ipv6_address(){ printf '%s\n' '::1'; }
    jq '(.nodes[] | select(.protocol == "ss")) as $node |
      .nodes += [($node | .id = "sbp-socks-eeeeeeeeeeeeeeee" | .port = 13999 | .dns_mode = "remote"),
        ($node | .id = "sbp-socks-dddddddddddddddd" | .port = 13998 | .system_ipv6 = true),
        ($node | .id = "sbp-socks-cccccccccccccccc" | .port = 13997 | .dns_mode = "remote" | .system_ipv6 = true)] |
      .nodes |= map(.outbound.tag = (.id + "-out"))' "$SOCKS_NODES_JSON" > "$test_root/probe-nodes.json"
    cp "$test_root/probe-nodes.json" "$SOCKS_NODES_JSON"
    write_config
    "$probe_python" "$repo_root/tests/socks_node_probe.py" "$BIN_PATH" "$CONF_JSON" "$test_root"
  )
fi

# Cancellation and deletion do not affect normal nodes or leave stale shares.
remove_socks_node > "$test_root/cancel.log" <<'EOF'
1
n
EOF
assert_equal "$state_hash" "$(hash "$SOCKS_NODES_JSON")" 'delete cancellation preserves nodes'
remove_socks_node > "$test_root/delete.log" <<'EOF'
1
y
EOF
assert_json "$SOCKS_NODES_JSON" '.nodes | length == 9' 'delete removes only the selected node'
grep -Fxq 'delete allow 13001/tcp' "$test_root/ufw.calls"
current=$(load_socks_nodes)
printf '%s\n' '{"nodes":[]}' > "$test_root/empty.json"
apply_socks_nodes "$test_root/empty.json" "$current" > "$test_root/delete-all.log" 2>&1
assert_json "$CONF_JSON" '.inbounds | length == 10' 'removing extras keeps normal nodes'
assert_equal 0 "$(wc -l < "$SOCKS_SHARE_LINKS_FILE" | tr -d ' ')" 'last deletion clears stale links'
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    assert_equal 600 "$(stat -c '%a' "$SOCKS_NODES_JSON")" 'upstream credentials must be root-only'
    assert_equal 600 "$(stat -c '%a' "$SOCKS_SHARE_LINKS_FILE")" 'extra links must be root-only'
    ;;
esac
printf 'PASS: optional SOCKS nodes, system IPv6, protocol inheritance, separate shares, validation and rollback\n'
