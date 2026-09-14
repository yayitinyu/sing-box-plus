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

export TEST_ROOT="$test_root"
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
export WGCF_BIN="$test_root/bin/wgcf"
export SBP_SCRIPT_PATH="$test_root/root/sbp.sh"
export SYSTEMD_SERVICE="test-sing-box.service"

mkdir -p "$SBP_BIN_DIR" "$SB_DIR" "$CERT_DIR" "$test_root/root"

# shellcheck source=../sing-box-plus.sh
source "$main_script"

assert_equal(){
  local expected="$1" actual="$2" message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

test_private_key="$(printf 'A%.0s' {1..43})="
test_peer_key="$(printf 'B%.0s' {1..43})="
export TEST_PRIVATE_KEY="$test_private_key"
export TEST_PEER_KEY="$test_peer_key"
export MOCK_WGCF_MODE=rate_limited
export MOCK_PROFILE_MODE=v4

cat > "$WGCF_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/wgcf.calls"

find_arg(){
  local wanted="$1"
  shift
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "$wanted" && $# -ge 2 ]]; then
      printf '%s\n' "$2"
      return 0
    fi
    shift
  done
  return 1
}

case "${1:-}" in
  register)
    if [[ "$MOCK_WGCF_MODE" == rate_limited ]]; then
      printf '%s\n' '429 Too Many Requests' '(mock stack trace)' >&2
      exit 1
    fi
    config_file="$(find_arg --config "$@")"
    cat > "$config_file" <<ACCOUNT
device_id = "device-id"
access_token = "access-token"
private_key = "$TEST_PRIVATE_KEY"
license_key = "license-key"
ACCOUNT
    ;;
  generate)
    if [[ "$MOCK_WGCF_MODE" == generate_failure ]]; then
      printf '%s\n' 'mock generate failure' >&2
      exit 1
    fi
    profile_file="$(find_arg --profile "$@")"
    if [[ "$MOCK_PROFILE_MODE" == dual ]]; then
      address='172.16.0.2/32, 2606:4700:110:8765::2/128'
    else
      address='172.16.0.2/32'
    fi
    cat > "$profile_file" <<PROFILE
[Interface]
PrivateKey = $TEST_PRIVATE_KEY
Address = $address

[Peer]
PublicKey = $TEST_PEER_KEY
Endpoint = engage.cloudflareclient.com:2408
Reserved = 1, 2, 3
PROFILE
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod 0755 "$WGCF_BIN"

reset_warp_state(){
  rm -rf -- "$WGCF_DIR"
  mkdir -p "$WGCF_DIR"
  rm -f -- "$SB_DIR/warp.env"
  : > "$test_root/wgcf.calls"
  ENABLE_WARP=true
  WARP_PRIVATE_KEY=""
  WARP_PEER_PUBLIC_KEY=""
  WARP_ENDPOINT_HOST=""
  WARP_ENDPOINT_PORT=""
  WARP_ADDRESS_V4=""
  WARP_ADDRESS_V6=""
  WARP_RESERVED_1=0
  WARP_RESERVED_2=0
  WARP_RESERVED_3=0
}

# A 429 must stop after one registration request and must not emit the wgcf stack.
reset_warp_state
MOCK_WGCF_MODE=rate_limited
if ensure_warp_profile > "$test_root/rate-limit.log" 2>&1; then
  echo "FAIL: rate-limited registration must fail" >&2
  exit 1
fi
assert_equal 1 "$(grep -c '^register ' "$test_root/wgcf.calls")" \
  "rate-limited registration must run once"
assert_equal 0 "$(grep -c '^generate ' "$test_root/wgcf.calls" || true)" \
  "profile generation must not run after registration failure"
grep -Fq 'HTTP 429' "$test_root/rate-limit.log"
if grep -Fq 'stack trace' "$test_root/rate-limit.log"; then
  echo "FAIL: the primary output must not dump the wgcf stack" >&2
  exit 1
fi
grep -Fq '429 Too Many Requests' "$WGCF_DIR/wgcf-last-error.log"

# A valid imported profile is self-contained and must not hit the registration API.
reset_warp_state
cat > "$WGCF_DIR/wgcf-profile.conf" <<PROFILE
[Interface]
PrivateKey = $TEST_PRIVATE_KEY
Address = 172.16.0.2/32

[Peer]
PublicKey = $TEST_PEER_KEY
Endpoint = engage.cloudflareclient.com:2408
Reserved = 1, 2, 3
PROFILE
MOCK_WGCF_MODE=rate_limited
ensure_warp_profile > "$test_root/imported-profile.log" 2>&1
assert_equal 0 "$(wc -l < "$test_root/wgcf.calls" | tr -d ' ')" \
  "an imported profile must avoid every wgcf API request"
assert_equal "172.16.0.2/32" "$WARP_ADDRESS_V4" "imported profile IPv4 address"
grep -Fq '无需重新注册' "$test_root/imported-profile.log"

# A successful IPv4-only profile is valid and remains idempotent on the next run.
reset_warp_state
MOCK_WGCF_MODE=success
MOCK_PROFILE_MODE=v4
ensure_warp_profile > "$test_root/v4-success.log" 2>&1
assert_equal "172.16.0.2/32" "$WARP_ADDRESS_V4" "IPv4 address must be parsed"
assert_equal "" "$WARP_ADDRESS_V6" "IPv4-only profiles must not duplicate IPv4 into IPv6"
assert_equal "engage.cloudflareclient.com" "$WARP_ENDPOINT_HOST" "endpoint host"
assert_equal "2408" "$WARP_ENDPOINT_PORT" "endpoint port"
assert_equal 2 "$(wc -l < "$test_root/wgcf.calls" | tr -d ' ')" \
  "initial preparation must register and generate once"
ensure_warp_profile > "$test_root/idempotent.log" 2>&1
assert_equal 2 "$(wc -l < "$test_root/wgcf.calls" | tr -d ' ')" \
  "a complete warp.env must avoid another wgcf request"

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    assert_equal 600 "$(stat -c '%a' "$SB_DIR/warp.env")" "warp.env must be root-only"
    assert_equal 600 "$(stat -c '%a' "$WGCF_DIR/wgcf-account.toml")" "wgcf account must be root-only"
    assert_equal 600 "$(stat -c '%a' "$WGCF_DIR/wgcf-profile.conf")" "wgcf profile must be root-only"
    ;;
esac

# Dual-stack parsing must preserve both addresses and IPv6 endpoint brackets.
cat > "$test_root/dual-profile.conf" <<PROFILE
[Interface]
PrivateKey = $TEST_PRIVATE_KEY
Address = 172.16.0.2/32
Address = 2606:4700:110:8765::2/128
[Peer]
PublicKey = $TEST_PEER_KEY
Endpoint = [2606:4700:d0::a29f:c001]:2408
PROFILE
ENABLE_WARP=true
parse_warp_profile "$test_root/dual-profile.conf"
assert_equal "172.16.0.2/32" "$WARP_ADDRESS_V4" "dual-stack IPv4 address"
assert_equal "2606:4700:110:8765::2/128" "$WARP_ADDRESS_V6" "dual-stack IPv6 address"
assert_equal "2606:4700:d0::a29f:c001" "$WARP_ENDPOINT_HOST" "bracketed IPv6 endpoint"

# Egress verification must keep one sing-box process alive until WireGuard is ready.
cat > "$CONF_JSON" <<'JSON'
{
  "dns": {"servers": [], "final": "dns-test"},
  "endpoints": [{"type": "wireguard", "tag": "warp"}],
  "outbounds": [{"type": "direct", "tag": "direct"}]
}
JSON
cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/sing-box.calls"
case "${1:-}" in
  check) exit 0 ;;
  run)
    trap 'exit 0' TERM INT
    while :; do sleep 0.1; done
    ;;
  *) exit 2 ;;
esac
EOF
cat > "$SBP_BIN_DIR/ss" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/ss.calls"
if [[ "$(wc -l < "$TEST_ROOT/ss.calls" | tr -d ' ')" -gt 1 ]]; then
  printf '%s\n' 'LISTEN 0 4096 127.0.0.1:29400 0.0.0.0:*'
fi
EOF
cat > "$SBP_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/curl.calls"
printf '%s\n' 'fl=mock' 'warp=on'
EOF
chmod 0755 "$BIN_PATH" "$SBP_BIN_DIR/ss" "$SBP_BIN_DIR/curl"
: > "$test_root/sing-box.calls"
: > "$test_root/ss.calls"
: > "$test_root/curl.calls"
verify_warp_egress
assert_equal 1 "$(grep -c '^run ' "$test_root/sing-box.calls")" \
  "verification must start one persistent sing-box process"
assert_equal 1 "$(wc -l < "$test_root/curl.calls" | tr -d ' ')" \
  "verification must stop after the first successful WARP trace"
if find "$SB_DIR" -maxdepth 1 -type d -name '.warp-verify.*' -print -quit | grep -q .; then
  echo "FAIL: WARP verification temporary directory was not cleaned" >&2
  exit 1
fi
rm -f -- "$BIN_PATH" "$SBP_BIN_DIR/ss" "$SBP_BIN_DIR/curl"

# Repair backups must restore account and profile credentials byte-for-byte.
credential_backup="$test_root/credential-backup"
mkdir -p "$credential_backup"
account_hash_before="$(sha256sum "$WGCF_DIR/wgcf-account.toml" | awk '{print $1}')"
profile_hash_before="$(sha256sum "$WGCF_DIR/wgcf-profile.conf" | awk '{print $1}')"
backup_warp_repair "$credential_backup"
printf '%s\n' 'corrupted account' > "$WGCF_DIR/wgcf-account.toml"
printf '%s\n' 'corrupted profile' > "$WGCF_DIR/wgcf-profile.conf"
restore_warp_repair "$credential_backup"
assert_equal "$account_hash_before" "$(sha256sum "$WGCF_DIR/wgcf-account.toml" | awk '{print $1}')" \
  "repair rollback must restore the WARP account"
assert_equal "$profile_hash_before" "$(sha256sum "$WGCF_DIR/wgcf-profile.conf" | awk '{print $1}')" \
  "repair rollback must restore the WARP profile"

# The menu must delegate WARP preparation only through write_config, preventing a duplicate request.
if declare -f menu | grep -Fq 'ensure_warp_profile'; then
  echo "FAIL: the deployment menu must not invoke ensure_warp_profile twice" >&2
  exit 1
fi

# The repair command must restart only after a valid endpoint is written, with rollback on failure.
printf '%s\n' '{"endpoints":[],"marker":"before-repair"}' > "$CONF_JSON"
ENABLE_WARP=false
save_env

write_config(){
  load_env
  load_warp
  warp_profile_ready || return 1
  printf '%s\n' '{"endpoints":[{"type":"wireguard","tag":"warp"}],"marker":"after-repair"}' > "$CONF_JSON"
  save_env
}
open_firewall(){ printf '%s\n' called >> "$test_root/firewall.calls"; }
print_links_grouped(){ printf '%s\n' called >> "$test_root/link.calls"; }
verify_warp_egress(){ return 0; }
systemctl(){
  case "${1:-}" in
    is-active) return 0 ;;
    restart)
      printf '%s\n' restart >> "$test_root/systemctl.calls"
      if [[ -f "$test_root/fail-restart-once" ]]; then
        rm -f -- "$test_root/fail-restart-once"
        return 1
      fi
      ;;
    *) return 0 ;;
  esac
}

: > "$test_root/systemctl.calls"
: > "$test_root/firewall.calls"
: > "$test_root/link.calls"
repair_warp > "$test_root/repair-success.log" 2>&1
grep -Fqx 'ENABLE_WARP=true' "$SB_DIR/env.conf"
assert_equal after-repair "$(jq -r '.marker' "$CONF_JSON")" "repair must install a WARP endpoint"
assert_equal 1 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" "successful repair restart count"
assert_equal 1 "$(wc -l < "$test_root/firewall.calls" | tr -d ' ')" "firewall update after restart"
assert_equal 1 "$(wc -l < "$test_root/link.calls" | tr -d ' ')" "link refresh after restart"

printf '%s\n' '{"endpoints":[],"marker":"rollback-baseline"}' > "$CONF_JSON"
ENABLE_WARP=false
save_env
: > "$test_root/fail-restart-once"
: > "$test_root/systemctl.calls"
: > "$test_root/firewall.calls"
if repair_warp > "$test_root/repair-rollback.log" 2>&1; then
  echo "FAIL: a failed service restart must fail WARP repair" >&2
  exit 1
fi
assert_equal rollback-baseline "$(jq -r '.marker' "$CONF_JSON")" "failed repair must restore config"
grep -Fqx 'ENABLE_WARP=false' "$SB_DIR/env.conf"
assert_equal 2 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" \
  "failed repair must restart once for apply and once for rollback"
assert_equal 0 "$(wc -l < "$test_root/firewall.calls" | tr -d ' ')" \
  "firewall must not change before a successful restart"

printf '%s\n' 'All WARP profile regression tests passed.'
