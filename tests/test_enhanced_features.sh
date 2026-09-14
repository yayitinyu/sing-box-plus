#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
main_script="$repo_root/sing-box-plus.sh"
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

command -v jq >/dev/null 2>&1 || {
  echo "jq is required" >&2
  exit 1
}

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS2_ARG_CONV_EXCL='/CN=' ;;
esac

export SBP_SKIP_DEPS=1
export SBP_SKIP_ROOT=1
export SBP_ROOT="$test_root/sbp-root"
export SBP_BIN_DIR="$test_root/bin"
export SBP_DEPS_SENTINEL="$test_root/sbp-root/.deps_ok"
export SB_DIR="$test_root/state"
export CONF_JSON="$test_root/state/config.json"
export DATA_DIR="$test_root/state/data"
export CERT_DIR="$test_root/state/cert"
export WGCF_DIR="$test_root/state/wgcf"
export DIAG_DIR="$test_root/state/diagnostics"
export ROUTE_JSON="$test_root/state/routes.json"
export SHARE_LINKS_FILE="$test_root/state/share-links.txt"
export BIN_PATH="$test_root/bin/sing-box"
export SYSTEMD_SERVICE="test-sing-box.service"
# 本套件会调用 uninstall_all，以下路径若不重定向就会删掉真实部署的组件
export DNS_HEALTH_BIN="$test_root/bin/dns-health"
export EVENT_LOG_BIN="$test_root/bin/event-log"
export WGCF_BIN="$test_root/bin/wgcf"
export SYSTEMD_UNIT_DIR="$test_root/systemd"
export DNS_HEALTH_SERVICE="test-dns-health.service"
export DNS_HEALTH_TIMER="test-dns-health.timer"

# uninstall_all 还会删除若干硬编码路径（/var/lib/sing-box、/usr/local/bin/sbp、
# /tmp/sing-box*、/tmp/sbp*），这些无法通过环境变量重定向，因此在检测到真实
# 部署时拒绝运行。确认机器可牺牲时用 SBP_ALLOW_DESTRUCTIVE_TEST=1 显式放行。
if [[ "${SBP_ALLOW_DESTRUCTIVE_TEST:-0}" != "1" ]]; then
  for probe in /opt/sing-box /usr/local/sbin/sing-box-plus-event /var/lib/sing-box; do
    if [[ -e "$probe" ]]; then
      echo "REFUSING: detected a real sing-box-plus install at $probe" >&2
      echo "This suite calls uninstall_all and removes hardcoded paths it cannot sandbox." >&2
      echo "Run it on a throwaway machine, or set SBP_ALLOW_DESTRUCTIVE_TEST=1 to override." >&2
      exit 1
    fi
  done
fi

mkdir -p "$SBP_BIN_DIR" "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$SYSTEMD_UNIT_DIR"

# shellcheck source=../sing-box-plus.sh
source "$main_script"

assert_equal(){
  local expected=$1 actual=$2 message=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

# 1. 测试 version_lt 逻辑
if ! version_lt "1.11.0" "1.12.0"; then
  echo "FAIL: 1.11.0 must be less than 1.12.0" >&2; exit 1
fi
if ! version_lt "1.12.0" "1.12.7"; then
  echo "FAIL: 1.12.0 must be less than 1.12.7" >&2; exit 1
fi
if ! version_lt "1.12.0-rc.1" "1.12.0"; then
  echo "FAIL: 1.12.0-rc.1 must be less than 1.12.0" >&2; exit 1
fi
if version_lt "1.12.7" "1.12.7"; then
  echo "FAIL: 1.12.7 must not be less than 1.12.7" >&2; exit 1
fi
if version_lt "1.13.0" "1.12.7"; then
  echo "FAIL: 1.13.0 must not be less than 1.12.7" >&2; exit 1
fi

# 2. 测试 get_singbox_local_version
cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "sing-box version 1.11.5" ;;
  check) exit 0 ;;
  generate)
    if [[ "${2:-}" == "reality-keypair" ]]; then
      echo "PrivateKey: mock-priv-key"
      echo "PublicKey: mock-pub-key"
    fi
    ;;
  *) echo "sing-box version 1.11.5" ;;
esac
EOF
chmod 0755 "$BIN_PATH"
local_v=$(get_singbox_local_version "$BIN_PATH")
assert_equal "1.11.5" "$local_v" "must correctly extract semver from version output"

# 3. 测试 GeoFiles 模拟更新与落地路径
# 模拟 curl
cat > "$test_root/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$out" ]]; then
  printf 'mock-geo-content\n' > "$out"
  exit 0
fi
printf '{"Status":0}\n'
EOF
chmod 0755 "$test_root/bin/curl"
export PATH="$test_root/bin:$PATH"

systemctl(){
  return 0
}

update_geofiles > "$test_root/geofiles.log" 2>&1
if [[ ! -f "$DATA_DIR/geoip.db" ]]; then
  echo "FAIL: geoip.db must exist in $DATA_DIR" >&2
  exit 1
fi
if [[ ! -f "$DATA_DIR/geosite.db" ]]; then
  echo "FAIL: geosite.db must exist in $DATA_DIR" >&2
  exit 1
fi
if [[ ! -f "$DATA_DIR/geoip-cn.srs" ]]; then
  echo "FAIL: geoip-cn.srs must exist in $DATA_DIR" >&2
  exit 1
fi
if [[ ! -f "$SB_DIR/geofiles.version" ]]; then
  echo "FAIL: geofiles.version must exist in $SB_DIR" >&2
  exit 1
fi

# 4. 测试 show_service_status 输出
status_out=$(show_service_status 2>&1)
if ! echo "$status_out" | grep -q "Sing-Box-Plus 综合运行状态看板"; then
  echo "FAIL: show_service_status must render title banner" >&2
  exit 1
fi
if ! echo "$status_out" | grep -q "10 节点端口监听监控"; then
  echo "FAIL: show_service_status must render only enabled nodes" >&2
  exit 1
fi

# 5. 测试 Socks5 / Socks5H / Socks / HTTP / HTTPS / TG 节点导入解析
out_socks5=$(share_link_to_outbound "socks5://1.2.3.4:1080#my-socks" "ext-socks")
assert_equal "socks" "$(printf '%s' "$out_socks5" | jq -r '.type')" "socks5 type"
assert_equal "ext-socks" "$(printf '%s' "$out_socks5" | jq -r '.tag')" "socks5 tag"
assert_equal "1.2.3.4" "$(printf '%s' "$out_socks5" | jq -r '.server')" "socks5 server"
assert_equal "1080" "$(printf '%s' "$out_socks5" | jq -r '.server_port')" "socks5 port"
assert_equal "5" "$(printf '%s' "$out_socks5" | jq -r '.version')" "socks5 version"

out_socks5_auth=$(share_link_to_outbound "socks5://user%40test:p%40ss@198.51.100.1:1088#auth-socks" "ext-auth-socks")
assert_equal "user@test" "$(printf '%s' "$out_socks5_auth" | jq -r '.username')" "socks5 username"
assert_equal "p@ss" "$(printf '%s' "$out_socks5_auth" | jq -r '.password')" "socks5 password"

out_socks5h=$(share_link_to_outbound "socks5h://alice:secret@proxy.example.com:1080" "ext-socks5h")
assert_equal "proxy.example.com" "$(printf '%s' "$out_socks5h" | jq -r '.server')" "socks5h server"
assert_equal "alice" "$(printf '%s' "$out_socks5h" | jq -r '.username')" "socks5h username"
assert_equal "secret" "$(printf '%s' "$out_socks5h" | jq -r '.password')" "socks5h password"

b64_ui=$(printf '%s' "foo:bar" | b64enc)
out_socks_b64=$(share_link_to_outbound "socks://${b64_ui}@10.0.0.1:1080" "ext-socks-b64")
assert_equal "foo" "$(printf '%s' "$out_socks_b64" | jq -r '.username')" "socks base64 username"
assert_equal "bar" "$(printf '%s' "$out_socks_b64" | jq -r '.password')" "socks base64 password"

out_http=$(share_link_to_outbound "http://admin:pass123@1.2.3.4:8080#http-node" "ext-http")
assert_equal "http" "$(printf '%s' "$out_http" | jq -r '.type')" "http type"
assert_equal "1.2.3.4" "$(printf '%s' "$out_http" | jq -r '.server')" "http server"
assert_equal "8080" "$(printf '%s' "$out_http" | jq -r '.server_port')" "http port"
assert_equal "admin" "$(printf '%s' "$out_http" | jq -r '.username')" "http username"
assert_equal "pass123" "$(printf '%s' "$out_http" | jq -r '.password')" "http password"

out_https=$(share_link_to_outbound "https://admin:pass123@proxy.example.com:8443?sni=secure.example.com&insecure=1" "ext-https")
assert_equal "http" "$(printf '%s' "$out_https" | jq -r '.type')" "https type"
assert_equal "true" "$(printf '%s' "$out_https" | jq -r '.tls.enabled')" "https tls enabled"
assert_equal "secure.example.com" "$(printf '%s' "$out_https" | jq -r '.tls.server_name')" "https tls sni"
assert_equal "true" "$(printf '%s' "$out_https" | jq -r '.tls.insecure')" "https tls insecure"

out_tg_socks=$(share_link_to_outbound "tg://socks?server=198.51.100.2&port=1080&user=tguser&pass=tgpass" "tg-socks")
assert_equal "socks" "$(printf '%s' "$out_tg_socks" | jq -r '.type')" "tg socks type"
assert_equal "tguser" "$(printf '%s' "$out_tg_socks" | jq -r '.username')" "tg socks username"

out_tg_http=$(share_link_to_outbound "tg://http-proxy?server=198.51.100.3&port=8080&user=tghttp&pass=tghttppass" "tg-http")
assert_equal "http" "$(printf '%s' "$out_tg_http" | jq -r '.type')" "tg http type"
assert_equal "tghttp" "$(printf '%s' "$out_tg_http" | jq -r '.username')" "tg http username"

# 6. 测试非 Warp 节点默认出口设置、配置生成与删除防护
ensure_route_file
assert_equal "direct" "$(load_route_json | jq -r '.default_outbound')" "default outbound must default to direct"

# 导入节点并设为 default_outbound
jq --argjson ob "$out_socks5" '.outbounds += [$ob] | .default_outbound = "ext-socks"' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
write_config
assert_equal "ext-socks" "$(jq -r '.route.final' "$CONF_JSON")" "route.final must use configured default_outbound"
assert_equal "socks" "$(jq -r '.outbounds[] | select(.tag == "ext-socks") | .type' "$CONF_JSON")" "outbounds must contain imported default exit"

# 当节点被设为默认出口时，禁止直接删除
remove_log="$test_root/remove_blocked.log"
(echo "ext-socks" | remove_custom_route_outbound) > "$remove_log" 2>&1 || true
if ! grep -q "该出口当前正作为非 Warp 节点的默认出口使用" "$remove_log"; then
  echo "FAIL: remove_custom_route_outbound must block deleting active default outbound" >&2
  exit 1
fi
assert_equal "ext-socks" "$(jq -r '.outbounds[] | select(.tag == "ext-socks") | .tag' "$ROUTE_JSON")" "blocked outbound must remain in routes.json"

# 切换为 direct-ipv4
jq '.default_outbound = "direct-ipv4"' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
write_config
assert_equal "direct-ipv4" "$(jq -r '.route.final' "$CONF_JSON")" "route.final must be direct-ipv4"
assert_equal "direct" "$(jq -r '.outbounds[] | select(.tag == "direct-ipv4") | .type' "$CONF_JSON")" "outbounds must include direct-ipv4 outbound"

# 切换后允许删除该导入节点
(echo "ext-socks" | remove_custom_route_outbound) > "$test_root/remove_ok.log" 2>&1 || true
assert_equal "0" "$(jq '[.outbounds[] | select(.tag == "ext-socks")] | length' "$ROUTE_JSON")" "unlinked outbound must be successfully removed"

# 测试非法/未知 default_outbound 安全回退为 direct
jq '.default_outbound = "invalid-ghost-outbound"' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
write_config
assert_equal "direct" "$(jq -r '.route.final' "$CONF_JSON")" "invalid default_outbound must safely fallback to direct"

# 测试 clear_custom_route_rules 保留 default_outbound
jq '.default_outbound = "direct-ipv6" | .rules = [{outbound:"direct-ipv6",domain:["test.com"]}]' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
(echo "y" | clear_custom_route_rules) > "$test_root/clear_rules.log" 2>&1 || true
assert_equal "0" "$(jq '(.rules // []) | length' "$ROUTE_JSON")" "rules must be cleared"
assert_equal "direct-ipv6" "$(jq -r '.default_outbound' "$ROUTE_JSON")" "clear_custom_route_rules must preserve default_outbound"

# 7. 测试导入出口的 legacy domain_strategy 归一化
jq --argjson ob "$out_socks5" '.outbounds += [($ob + {tag: "node-strat", domain_strategy: "prefer_ipv4"})]' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
write_config
assert_equal "null" "$(jq -r '.outbounds[] | select(.tag == "node-strat") | .domain_strategy // "null"' "$CONF_JSON")" "config.json must not have deprecated domain_strategy"
assert_equal "null" "$(jq -r '.outbounds[] | select(.tag == "direct") | .domain_strategy // "null"' "$CONF_JSON")" "direct outbound must not have deprecated domain_strategy"

# 验证 print_custom_routes 无 jq 编译/关键字错误
print_custom_routes > "$test_root/print_routes.log" 2>&1
assert_equal "0" "$?" "print_custom_routes must execute cleanly without jq errors"

# 回归：default_outbound 键缺失时，选择 direct 必须落盘而不是被当成“未发生变化”
jq 'del(.default_outbound)' "$ROUTE_JSON" > "$ROUTE_JSON.tmp" && mv "$ROUTE_JSON.tmp" "$ROUTE_JSON"
(echo "1" | set_custom_default_outbound) > "$test_root/default_direct.log" 2>&1 || true
assert_equal "direct" "$(jq -r '.default_outbound // "missing"' "$ROUTE_JSON")" "missing default_outbound must be persisted when direct is selected"

# 键已存在且值相同时应视为未变化，不重复写入
(echo "1" | set_custom_default_outbound) > "$test_root/default_noop.log" 2>&1 || true
assert_equal "direct" "$(jq -r '.default_outbound' "$ROUTE_JSON")" "selecting the current outbound again must keep it unchanged"

# 8. 测试 uninstall_all 交互取消与确认
(echo "n" | uninstall_all) > "$test_root/uninstall_cancel.log" 2>&1 || true
if [[ ! -d "$SB_DIR" ]]; then
  echo "FAIL: canceling uninstall must keep $SB_DIR intact" >&2
  exit 1
fi

(echo "y" | uninstall_all) > "$test_root/uninstall_exec.log" 2>&1 || true
if [[ -d "$SB_DIR" ]]; then
  echo "FAIL: confirming uninstall must remove $SB_DIR" >&2
  exit 1
fi
if [[ -f "$BIN_PATH" ]]; then
  echo "FAIL: confirming uninstall must remove $BIN_PATH" >&2
  exit 1
fi

printf '%s\n' "PASS: enhanced features (version compare, geofiles update, status viewer, socks/http import, default outbound, uninstall) work correctly"
