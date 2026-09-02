#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
main_script=${SBP_TEST_SCRIPT:-$repo_root/sing-box-plus.sh}
test_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P)
test_root=$(mktemp -d "$test_parent/sbp-routing-test.XXXXXX")
cleanup(){
  case "$test_root" in
    "$test_parent"/sbp-routing-test.*) rm -rf -- "$test_root" ;;
    *) echo "Refusing to clean an unexpected test directory" >&2 ;;
  esac
}
trap cleanup EXIT

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }
export SBP_SKIP_DEPS=1 SBP_SKIP_ROOT=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SBP_DEPS_SENTINEL="$test_root/runtime/.deps_ok"
export SB_DIR="$test_root/state" CONF_JSON="$test_root/state/config.json"
export DATA_DIR="$test_root/state/data" CERT_DIR="$test_root/state/cert"
export WGCF_DIR="$test_root/state/wgcf" DIAG_DIR="$test_root/state/diagnostics"
export ROUTE_JSON="$test_root/state/routes.json" SHARE_LINKS_FILE="$test_root/state/share-links.txt"
export BIN_PATH="$test_root/bin/sing-box" WGCF_BIN="$test_root/bin/wgcf"
export DNS_HEALTH_BIN="$test_root/bin/dns-health" EVENT_LOG_BIN="$test_root/bin/event-log"
export SYSTEMD_UNIT_DIR="$test_root/systemd" SYSTEMD_SERVICE="test-sing-box.service"
export DNS_HEALTH_SERVICE="test-dns-health.service" DNS_HEALTH_TIMER="test-dns-health.timer"
export SBP_SCRIPT_PATH="$test_root/sbp.sh"

# shellcheck source=../sing-box-plus.sh
source "$main_script"
ensure_dirs
mkdir -p "$SBP_BIN_DIR"
cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "check" ]] || exit 1
[[ ! -f "$SB_DIR/fail-check" ]]
EOF
chmod 755 "$BIN_PATH"

default_ipv4_address(){ printf '%s\n' '192.0.2.10'; }
default_ipv6_address(){ printf '%s\n' '2001:db8::10'; }
prepare_tls_certificate(){ return 0; }
ensure_installed_or_hint(){ return 0; }
systemctl(){
  case "${1:-}" in
    is-active) [[ -f "$test_root/service-active" ]] ;;
    restart)
      printf '%s\n' restart >> "$test_root/restarts"
      if [[ -f "$test_root/fail-restart" && ! -f "$test_root/restart-failed" ]]; then
        touch "$test_root/restart-failed"
        return 1
      fi
      return 0
      ;;
    *) echo "Unexpected systemctl call in routing test" >&2; return 1 ;;
  esac
}

cat > "$SB_DIR/creds.env" <<'EOF'
UUID=11111111-1111-4111-8111-111111111111
HY2_PWD=test-hy2-password
REALITY_PRIV=test-private-key
REALITY_PUB=test-public-key
REALITY_SID=1234abcd
HY2_PWD2=test-hy2-obfs-password
HY2_OBFS_PWD=test-obfs-password
SS2022_KEY=test-ss-key
SS_PWD=test-ss-password
TUIC_UUID=11111111-1111-4111-8111-111111111111
TUIC_PWD=test-tuic-password
ANYTLS_PWD=test-anytls-password
EOF
port_names=(VLESSR VLESS_GRPCR TROJANR HY2 VMESS_WS HY2_OBFS SS2022 SS TUIC ANYTLS)
for i in "${!port_names[@]}"; do
  printf 'PORT_%s=%s\nPORT_%s_W=%s\n' "${port_names[$i]}" "$((11001+i))" "${port_names[$i]}" "$((12001+i))"
done > "$SB_DIR/ports.env"

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_json(){ jq -e "$1" "$2" >/dev/null || fail "$3"; }
file_hash(){ sha256sum "$1" | awk '{print $1}'; }
assert_unchanged(){ [[ "$(file_hash "$2")" == "$1" ]] || fail "$3"; }
assert_same_json(){
  jq -en --slurpfile first "$1" --slurpfile second "$2" '$first[0] == $second[0]' >/dev/null || fail "$3"
}
reset_state(){
  rm -f -- "$SB_DIR/fail-check" "$test_root/fail-restart" "$test_root/restart-failed"
  : > "$test_root/restarts"
  touch "$test_root/service-active"
  printf 'ENABLE_WARP=false\n' > "$SB_DIR/env.conf"
  empty_route_json > "$ROUTE_JSON"
  write_config > "$test_root/setup.log" 2>&1
}
write_bundle_fixture(){
  cat > "$ROUTE_JSON" <<'EOF'
{
  "rules": [
    {"name":"Allow exception", "domain":["allowed.example"], "outbound":"direct"},
    {"name":"屏蔽广告 桜", "rule_set":["ads"], "action":"reject"},
    {"name":"Remote exit", "domain_suffix":["example.org"], "outbound":"remote-vps"}
  ],
  "rule_set": [{"type":"inline", "tag":"ads", "rules":[{"domain_suffix":["ads.example"]}]}],
  "outbounds": [{"type":"socks", "tag":"remote-vps", "server":"192.0.2.20", "server_port":1080, "username":"test-user", "password":"test-only-password"}],
  "default_outbound":"remote-vps"
}
EOF
}
check_with_core(){
  [[ -n "${SBP_TEST_SING_BOX:-}" ]] || return 0
  # These tests exercise generated routing without starting listeners or requiring TLS fixtures.
  jq '.inbounds = [] | .endpoints = []' "$CONF_JSON" > "$test_root/core-check.json"
  "$SBP_TEST_SING_BOX" check -c "$test_root/core-check.json" > "$test_root/core-check.log" 2>&1 || {
    cat "$test_root/core-check.log" >&2
    fail "generated routes must pass the real sing-box check"
  }
}

test_block(){
  reset_state
  printf '%s\n' '{"rules":[{"action":"reject","domain_suffix":["ads.example"]}]}' > "$ROUTE_JSON"
  write_config > "$test_root/block-config.log" 2>&1
  assert_json '.route.rules[0].action == "reject" and (.route.rules[0] | has("outbound") | not)' "$CONF_JSON" "block must render as reject without an outbound"
  assert_json 'all(.outbounds[]; .type != "block")' "$CONF_JSON" "block must not generate a deprecated outbound"
  empty_route_json > "$ROUTE_JSON"
  add_custom_route_rule <<< $'5\nsuffix:ads.example, domain:tracker.example\n屏蔽广告\n' > "$test_root/add-block.log" 2>&1
  assert_json '.rules[0].action == "reject" and .rules[0].name == "屏蔽广告" and (.rules[0] | has("outbound") | not)' "$ROUTE_JSON" "adding block must persist its action and name"
  print_custom_routes > "$test_root/display.log"
  grep -q 'block（阻断）' "$test_root/display.log" || fail "block must have a readable menu label"
  check_with_core
  add_custom_route_rule <<< $'2\nsuffix:allowed.example\nAllow\n' > "$test_root/add-direct.log" 2>&1
  assert_json '.route.rules[0].action == "reject" and .route.rules[1].outbound == "direct"' "$CONF_JSON" "adding a route after block must preserve ordering and reset the selected action"
  remove_custom_route_rule <<< '1' > "$test_root/remove-block.log" 2>&1
  assert_json '.rules | length == 1 and .[0].outbound == "direct"' "$ROUTE_JSON" "block must remain removable through the existing menu"
  add_custom_route_rule <<< $'5\ngeosite:category-ads-all\nGeosite block\n' > "$test_root/geosite-block.log" 2>&1
  assert_json '.rules[-1].action == "reject" and .rules[-1].rule_set == ["geosite-category-ads-all"] and .rule_set[0].type == "remote"' "$ROUTE_JSON" "geosite block must retain its remote rule-set dependency"
  check_with_core
  write_bundle_fixture
  select_route_outbound <<< '6' > "$test_root/select-remote.log"
  [[ "$SBP_SELECTED_OUTBOUND" == "remote-vps" && "$SBP_SELECTED_ACTION" == "route" ]] || fail "remote outlet numbering must follow block"
}

test_round_trip(){
  reset_state
  write_bundle_fixture
  cp "$ROUTE_JSON" "$test_root/expected.json"
  export_custom_route_rules "$test_root/route export.json" > "$test_root/export.log" 2>&1
  assert_json '.format == "sing-box-plus-routes" and .version == 1' "$test_root/route export.json" "exports must identify their format and version"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) [[ "$(stat -c '%a' "$test_root/route export.json")" == 600 ]] || fail "exports must protect node credentials" ;;
  esac
  empty_route_json > "$ROUTE_JSON"
  import_custom_route_rules "$test_root/route export.json" <<< $'2\ny\n' > "$test_root/import.log" 2>&1
  assert_same_json "$test_root/expected.json" "$ROUTE_JSON" "replacement import must preserve rules, order, Unicode, rule sets, outbounds and default"
  assert_json '.route.rules[1].action == "reject" and .route.final == "remote-vps"' "$CONF_JSON" "restored routes must reach the runtime config"
  check_with_core
  [[ -n "$(find "$SB_DIR/backups" -type f -name 'routes-import-*' -print -quit)" ]] || fail "import must keep a backup"
  local before_route before_conf before_restarts
  before_route=$(file_hash "$ROUTE_JSON")
  before_conf=$(file_hash "$CONF_JSON")
  before_restarts=$(file_hash "$test_root/restarts")
  import_custom_route_rules "$test_root/route export.json" <<< '1' > "$test_root/reimport.log" 2>&1
  assert_unchanged "$before_route" "$ROUTE_JSON" "duplicate imports must not rewrite routes"
  assert_unchanged "$before_conf" "$CONF_JSON" "duplicate imports must not rewrite runtime config"
  assert_unchanged "$before_restarts" "$test_root/restarts" "duplicate imports must not restart the service"
}

test_merge(){
  reset_state
  write_bundle_fixture
  export_custom_route_rules "$test_root/merge-source.json" > "$test_root/merge-export.log" 2>&1
  printf '%s\n' '{"rules":[{"name":"Existing first","domain":["first.example"],"outbound":"direct"}],"default_outbound":"direct-ipv4"}' > "$ROUTE_JSON"
  import_custom_route_rules "$test_root/merge-source.json" <<< '' > "$test_root/merge.log" 2>&1
  assert_json '.rules | length == 4 and .[0].name == "Existing first" and .[2].action == "reject"' "$ROUTE_JSON" "merge must retain existing priority and append incoming rules in order"
  assert_json '.default_outbound == "direct-ipv4" and (.rule_set | length) == 1 and (.outbounds | length) == 1' "$ROUTE_JSON" "merge must add dependencies and preserve the current default"
  printf '%s\n' '{"rules":[{"domain":["another.example"],"outbound":"remote-vps"}]}' > "$test_root/rules-only.json"
  import_custom_route_rules "$test_root/rules-only.json" <<< '1' > "$test_root/rules-only.log" 2>&1
  assert_json '.rules[-1].outbound == "remote-vps"' "$ROUTE_JSON" "merged rules may reference existing outbounds"
  local before_route before_conf conflict
  before_route=$(file_hash "$ROUTE_JSON")
  before_conf=$(file_hash "$CONF_JSON")
  for conflict in '.outbounds[0].server_port = 1081' '.rule_set[0].rules[0].domain_suffix = ["different.example"]'; do
    jq "$conflict" "$test_root/merge-source.json" > "$test_root/conflict.json"
    if import_custom_route_rules "$test_root/conflict.json" <<< '1' > "$test_root/conflict.log" 2>&1; then
      fail "conflicting definitions must not be silently overwritten"
    fi
    assert_unchanged "$before_route" "$ROUTE_JSON" "a merge conflict must keep current routes"
    assert_unchanged "$before_conf" "$CONF_JSON" "a merge conflict must keep runtime config"
  done
}

test_invalid_imports(){
  reset_state
  local before_route before_conf invalid
  before_route=$(file_hash "$ROUTE_JSON")
  before_conf=$(file_hash "$CONF_JSON")
  local -a invalid_inputs=(
    'not json'
    '{} {}'
    '[]'
    '{"rules":{}}'
    '{"format":"sing-box-plus-routes","version":2,"rules":[]}'
    '{"rules":[],"outbounds":null}'
    '{"rules":[{"action":"reject"}]}'
    '{"rules":[{"action":"reject","domain_suffix":"example.com"}]}'
    '{"rules":[{"action":"reject","domain":[""]}]}'
    '{"rules":[{"action":"reject","domain":["example.com"],"source_ip_cidr":["192.0.2.0/24"]}]}'
    '{"rules":[{"action":"reject","domain":["example.com"],"outbound":"direct"}]}'
    '{"rules":[{"action":"unknown","domain":["example.com"],"outbound":"direct"}]}'
    '{"rules":[{"domain":["example.com"],"outbound":"missing"}]}'
    '{"rules":[{"action":"reject","rule_set":["missing"]}]}'
    '{"rules":[],"default_outbound":"missing"}'
    '{"rules":[],"default_outbound":"block"}'
    '{"rules":[],"default_outbound":"warp"}'
    '{"rules":[],"outbounds":[{"tag":"direct","type":"socks"}]}'
    '{"rules":[],"outbounds":[{"tag":"duplicate","type":"socks"},{"tag":"duplicate","type":"http"}]}'
    '{"rules":[],"rule_set":[{"tag":"bad","type":"inline","rules":[],"download_detour":"missing"}]}'
  )
  for invalid in "${invalid_inputs[@]}"; do
    printf '%s\n' "$invalid" > "$test_root/invalid.json"
    if import_custom_route_rules "$test_root/invalid.json" <<< $'2\ny\n' > "$test_root/invalid.log" 2>&1; then
      fail "an invalid import was accepted"
    fi
    assert_unchanged "$before_route" "$ROUTE_JSON" "invalid imports must not change routes"
    assert_unchanged "$before_conf" "$CONF_JSON" "invalid imports must not change runtime config"
  done
  [[ ! -s "$test_root/restarts" ]] || fail "invalid imports must not restart services"
}

test_cancel_and_export_protection(){
  reset_state
  write_bundle_fixture
  export_custom_route_rules "$test_root/cancel-source.json" > "$test_root/cancel-export.log" 2>&1
  empty_route_json > "$ROUTE_JSON"
  local before_route before_export
  before_route=$(file_hash "$ROUTE_JSON")
  import_custom_route_rules "$test_root/cancel-source.json" <<< $'2\nn\n' > "$test_root/cancel.log" 2>&1
  assert_unchanged "$before_route" "$ROUTE_JSON" "canceling replacement must leave routes untouched"
  before_export=$(file_hash "$test_root/cancel-source.json")
  export_custom_route_rules "$test_root/cancel-source.json" <<< 'n' > "$test_root/cancel-overwrite.log" 2>&1
  assert_unchanged "$before_export" "$test_root/cancel-source.json" "canceling overwrite must preserve the existing export"
  if export_custom_route_rules "$ROUTE_JSON" <<< 'y' > "$test_root/protected-export.log" 2>&1; then
    fail "export must not replace the active routing file"
  fi
  assert_unchanged "$before_route" "$ROUTE_JSON" "export must leave active routing unchanged"
  printf '%s\n' '{"rules":[]}' > "$test_root/empty-rules.json"
  write_bundle_fixture
  import_custom_route_rules "$test_root/empty-rules.json" <<< $'2\ny\n' > "$test_root/empty-import.log" 2>&1
  assert_json '.rules == [] and .outbounds == [] and .rule_set == [] and .default_outbound == "direct"' "$ROUTE_JSON" "confirmed empty replacement must restore empty routing defaults"
}

test_rollback(){
  reset_state
  local before_route before_conf
  before_route=$(file_hash "$ROUTE_JSON")
  before_conf=$(file_hash "$CONF_JSON")
  cp "$ROUTE_JSON" "$test_root/route-backup.json"
  printf '%s\n' '{"rules":[{"domain":["new.example"],"outbound":"direct"}]}' > "$ROUTE_JSON"
  touch "$test_root/fail-restart"
  if apply_custom_routing "$test_root/route-backup.json" > "$test_root/restart-rollback.log" 2>&1; then
    fail "failed service restart must report failure"
  fi
  assert_unchanged "$before_route" "$ROUTE_JSON" "failed restart must restore saved routing rules"
  assert_unchanged "$before_conf" "$CONF_JSON" "failed restart must restore runtime config"
  [[ "$(wc -l < "$test_root/restarts" | tr -d '[:space:]')" == 2 ]] || fail "rollback must attempt to restart with the original config"
}

test_import_check_failure(){
  reset_state
  local before_route before_conf
  before_route=$(file_hash "$ROUTE_JSON")
  before_conf=$(file_hash "$CONF_JSON")
  printf '%s\n' '{"rules":[{"action":"reject","domain":["new.example"]}]}' > "$test_root/check-failure.json"
  touch "$SB_DIR/fail-check"
  if import_custom_route_rules "$test_root/check-failure.json" <<< '1' > "$test_root/check-failure.log" 2>&1; then
    fail "core config validation failure must fail the import"
  fi
  assert_unchanged "$before_route" "$ROUTE_JSON" "failed core check must restore routes"
  assert_unchanged "$before_conf" "$CONF_JSON" "failed core check must preserve runtime config"
  [[ ! -s "$test_root/restarts" ]] || fail "failed config check must not restart the service"
}

test_menu(){
  reset_state
  custom_route_menu <<< $'7\n/nonexistent/rules.json\n\n8\n'"$test_root/menu-export.json"$'\n\n0\n' > "$test_root/menu.log" 2>&1
  [[ -s "$test_root/menu-export.json" ]] || fail "routing menu must remain usable after a failed import"
}

case "${1:-all}" in
  block) test_block ;;
  rollback) test_rollback ;;
  all)
    for test_name in test_block test_round_trip test_merge test_invalid_imports test_cancel_and_export_protection test_rollback test_import_check_failure test_menu; do
      "$test_name"
      printf 'PASS: %s\n' "$test_name"
    done
    ;;
  *) fail "unknown test selection" ;;
esac
printf '%s\n' 'PASS: custom routing tests'
