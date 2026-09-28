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
export SYSTEMD_UNIT_DIR="$test_root/systemd"
export SBP_SERVICE_STABILITY_CHECKS=3 SBP_SERVICE_STABILITY_INTERVAL=0

mkdir -p "$SBP_BIN_DIR" "$SB_DIR" "$CERT_DIR" "$SYSTEMD_UNIT_DIR" "$test_root/root"

# shellcheck source=../sing-box-plus.sh
source "$main_script"

# Profile tests use a dedicated wgcf mock; binary installation and upgrades are
# covered separately by test_wgcf_install.sh.
install_wgcf(){ [[ -x "$WGCF_BIN" ]]; }

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

# Repository files must stay readable by apt's unprivileged helper even when
# repair_warp applies a restrictive umask for credential backups.
cat > "$test_root/os-release" <<'EOF'
VERSION_CODENAME=noble
EOF
WARP_OS_RELEASE="$test_root/os-release"
WARP_APT_KEYRING="$test_root/apt/keyrings/cloudflare-warp.gpg"
WARP_APT_SOURCE_LIST="$test_root/apt/sources/cloudflare-client.list"
WARP_CLI_MANAGED_MARKER="$test_root/state/warp-cli-managed"
cat > "$SBP_BIN_DIR/apt-get" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/apt-get.calls"
if [[ "$*" == *'cloudflare-warp'* ]]; then
  cat > "$TEST_ROOT/bin/warp-cli" <<'CLI'
#!/usr/bin/env bash
exit 0
CLI
  chmod 0755 "$TEST_ROOT/bin/warp-cli"
fi
EOF
cat > "$SBP_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" && $# -ge 2 ]]; then
    output="$2"
    break
  fi
  shift
done
[[ -n "$output" ]]
printf '%s\n' 'mock-cloudflare-key' > "$output"
EOF
cat > "$SBP_BIN_DIR/gpg" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--output" && $# -ge 2 ]]; then
    output="$2"
    break
  fi
  shift
done
[[ -n "$output" ]]
printf '%s\n' 'mock-dearmored-key' > "$output"
EOF
chmod 0755 "$SBP_BIN_DIR/apt-get" "$SBP_BIN_DIR/curl" "$SBP_BIN_DIR/gpg"
: > "$test_root/apt-get.calls"
(
  umask 077
  install_warp_cli
)
assert_equal 644 "$(stat -c '%a' "$WARP_APT_KEYRING")" \
  "the Cloudflare apt keyring must remain readable under a restrictive umask"
assert_equal 644 "$(stat -c '%a' "$WARP_APT_SOURCE_LIST")" \
  "the Cloudflare apt source must remain readable under a restrictive umask"
grep -Fq 'noble main' "$WARP_APT_SOURCE_LIST"
grep -Fq "signed-by=$WARP_APT_KEYRING" "$WARP_APT_SOURCE_LIST"
grep -Fq 'cloudflare-warp' "$test_root/apt-get.calls"
rm -f -- "$SBP_BIN_DIR/apt-get" "$SBP_BIN_DIR/curl" "$SBP_BIN_DIR/gpg" "$SBP_BIN_DIR/warp-cli"
hash -r

# Default auto mode must use Cloudflare's official client and never touch the
# rate-limited wgcf registration API when no legacy profile/account exists.
reset_warp_state
WARP_BACKEND=auto
cat > "$SBP_BIN_DIR/warp-cli" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/warp-cli.calls"
case "$*" in
  *'registration show'*) [[ -f "$TEST_ROOT/warp-cli.registered" ]] ;;
  *'registration new'*) : > "$TEST_ROOT/warp-cli.registered" ;;
esac
EOF
cat > "$SBP_BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_ROOT/warp-systemctl.calls"
EOF
cat > "$SBP_BIN_DIR/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 4096 127.0.0.1:40000 0.0.0.0:*'
EOF
cat > "$SBP_BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'fl=mock' 'warp=on'
EOF
chmod 0755 "$SBP_BIN_DIR/warp-cli" "$SBP_BIN_DIR/systemctl" "$SBP_BIN_DIR/ss" "$SBP_BIN_DIR/curl"
: > "$test_root/warp-cli.calls"
: > "$test_root/warp-systemctl.calls"
ensure_warp_backend > "$test_root/official-proxy.log" 2>&1
assert_equal proxy "$WARP_BACKEND" "auto mode must select the official proxy backend"
assert_equal 0 "$(wc -l < "$test_root/wgcf.calls" | tr -d ' ')" \
  "auto mode must not invoke wgcf without an imported account or profile"
assert_equal 1 "$(grep -c 'registration new' "$test_root/warp-cli.calls")" \
  "the official client must register exactly once"
assert_equal 1 "$(grep -c 'mode proxy' "$test_root/warp-cli.calls")" \
  "the official client must enter local proxy mode"
assert_equal 1 "$(grep -c 'proxy port 40000' "$test_root/warp-cli.calls")" \
  "the official client must bind the configured proxy port"
assert_equal 1 "$(grep -c 'connect' "$test_root/warp-cli.calls")" \
  "the official client must connect once"
rm -f -- "$SBP_BIN_DIR/warp-cli" "$SBP_BIN_DIR/systemctl" "$SBP_BIN_DIR/ss" "$SBP_BIN_DIR/curl"
rm -f -- "$test_root/warp-cli.registered"
hash -r
WARP_BACKEND=wireguard

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

cat > "$CONF_JSON" <<'JSON'
{
  "dns": {"servers": [], "final": "dns-test"},
  "endpoints": [],
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "socks", "tag": "warp", "server": "127.0.0.1", "server_port": 40000}
  ]
}
JSON
: > "$test_root/sing-box.calls"
: > "$test_root/ss.calls"
: > "$test_root/curl.calls"
verify_warp_egress
assert_equal 1 "$(grep -c '^run ' "$test_root/sing-box.calls")" \
  "verification must accept the official-client SOCKS outbound"
assert_equal 1 "$(wc -l < "$test_root/curl.calls" | tr -d ' ')" \
  "official-client verification must prove WARP egress"
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
empty_route_json > "$ROUTE_JSON"
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
curl(){
  local output="" url=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-o" && $# -ge 2 ]]; then
      output="$2"
      shift 2
      continue
    fi
    [[ "$1" != http://* && "$1" != https://* ]] || url="$1"
    shift
  done
  [[ -n "$output" ]] || return 2
  [[ ! -f "$test_root/fail-ruleset-download" ]] || return 22
  [[ -z "$url" ]] || printf '%s\n' "$url" >> "$test_root/ruleset-curl.calls"
  printf '%s\n' 'mock-srs-data' > "$output"
}
systemctl(){
  case "${1:-}" in
    is-active) return 0 ;;
    show)
      if [[ -f "$test_root/delayed-restart-armed" ]]; then
        local checks=0
        [[ ! -f "$test_root/delayed-checks" ]] || checks=$(<"$test_root/delayed-checks")
        checks=$((checks + 1))
        printf '%s\n' "$checks" > "$test_root/delayed-checks"
        if (( checks >= 2 )); then
          rm -f -- "$test_root/delayed-restart-armed"
          printf '%s\n' 4343
          return 0
        fi
      fi
      printf '%s\n' 4242
      ;;
    restart)
      printf '%s\n' restart >> "$test_root/systemctl.calls"
      if [[ -f "$test_root/fail-restart-once" ]]; then
        rm -f -- "$test_root/fail-restart-once"
        return 1
      fi
      if [[ -f "$test_root/arm-delayed-restart" ]]; then
        rm -f -- "$test_root/arm-delayed-restart" "$test_root/delayed-checks"
        touch "$test_root/delayed-restart-armed"
      fi
      ;;
    daemon-reload) printf '%s\n' daemon-reload >> "$test_root/systemctl.calls" ;;
    disable) printf '%s\n' "$*" >> "$test_root/systemctl.calls" ;;
    *) return 0 ;;
  esac
}

: > "$test_root/systemctl.calls"
cat > "$ROUTE_JSON" <<'JSON'
{
  "rules": [{"rule_set": ["broken-remote"], "outbound": "direct"}],
  "rule_set": [{"type": "remote", "tag": "broken-remote", "format": "binary", "url": "https://rules.example.invalid/missing.srs"}],
  "outbounds": [],
  "default_outbound": "direct"
}
JSON
touch "$test_root/fail-ruleset-download"
if repair_warp > "$test_root/repair-ruleset-preflight.log" 2>&1; then
  echo "FAIL: WARP repair must reject an unavailable existing remote rule-set" >&2
  exit 1
fi
assert_equal before-repair "$(jq -r '.marker' "$CONF_JSON")" \
  "rule-set preflight failure must preserve the runtime config"
grep -Fqx 'ENABLE_WARP=false' "$SB_DIR/env.conf"
assert_equal 0 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" \
  "rule-set preflight failure must not restart the service"
rm -f -- "$test_root/fail-ruleset-download"
cat > "$ROUTE_JSON" <<'JSON'
{
  "rules": [{"rule_set": ["geosite-geosite-category-ads"], "action": "reject"}],
  "rule_set": [{
    "type": "remote",
    "tag": "geosite-geosite-category-ads",
    "format": "binary",
    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geosite-category-ads.srs",
    "download_detour": "direct",
    "update_interval": "1d"
  }],
  "outbounds": [],
  "default_outbound": "direct"
}
JSON
: > "$test_root/ruleset-curl.calls"

: > "$test_root/systemctl.calls"
: > "$test_root/firewall.calls"
: > "$test_root/link.calls"
repair_warp > "$test_root/repair-success.log" 2>&1
grep -Fqx 'ENABLE_WARP=true' "$SB_DIR/env.conf"
assert_equal after-repair "$(jq -r '.marker' "$CONF_JSON")" "repair must install a WARP endpoint"
assert_equal 1 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" "successful repair restart count"
assert_equal 1 "$(wc -l < "$test_root/firewall.calls" | tr -d ' ')" "firewall update after restart"
assert_equal 1 "$(wc -l < "$test_root/link.calls" | tr -d ' ')" "link refresh after restart"
assert_equal geosite-category-ads "$(jq -r '.rule_set[0].tag' "$ROUTE_JSON")" \
  "successful repair must persist the normalized legacy rule-set"
grep -Fqx 'https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ads.srs' \
  "$test_root/ruleset-curl.calls"
if grep -Fq 'geosite-geosite-' "$test_root/ruleset-curl.calls"; then
  echo "FAIL: WARP repair must normalize legacy generated geosite URLs before preflight" >&2
  exit 1
fi

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

printf '%s\n' '{"endpoints":[],"marker":"delayed-rollback-baseline"}' > "$CONF_JSON"
ENABLE_WARP=false
save_env
: > "$test_root/arm-delayed-restart"
: > "$test_root/systemctl.calls"
: > "$test_root/firewall.calls"
if repair_warp > "$test_root/repair-delayed-rollback.log" 2>&1; then
  echo "FAIL: a delayed post-restart crash must fail WARP repair" >&2
  exit 1
fi
assert_equal delayed-rollback-baseline "$(jq -r '.marker' "$CONF_JSON")" \
  "delayed restart failure must restore config"
grep -Fqx 'ENABLE_WARP=false' "$SB_DIR/env.conf"
assert_equal 2 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" \
  "delayed failure must restart once for apply and once for rollback"
assert_equal 0 "$(wc -l < "$test_root/firewall.calls" | tr -d ' ')" \
  "delayed restart failure must not update the firewall"

# An imported native profile must replace the proxy backend before releasing its daemon.
import_profile="$test_root/import-warp.conf"
cat > "$import_profile" <<PROFILE
[Interface]
PrivateKey = $test_private_key
Address = 172.16.0.3/32
[Peer]
PublicKey = $test_peer_key
Endpoint = engage.cloudflareclient.com:2408
PROFILE
printf '%s\n' '{"outbounds":[{"type":"socks","tag":"warp"}],"marker":"proxy-baseline"}' > "$CONF_JSON"
ENABLE_WARP=true
WARP_BACKEND=proxy
save_env
write_singbox_unit
grep -Fq 'Wants=warp-svc.service' "$SYSTEMD_UNIT_DIR/$SYSTEMD_SERVICE"
: > "$WARP_CLI_MANAGED_MARKER"
: > "$test_root/systemctl.calls"
: > "$test_root/firewall.calls"
: > "$test_root/link.calls"
repair_warp "$import_profile" > "$test_root/migrate-success.log" 2>&1
grep -Fqx 'WARP_BACKEND=wireguard' "$SB_DIR/env.conf"
if grep -Fq 'warp-svc.service' "$SYSTEMD_UNIT_DIR/$SYSTEMD_SERVICE"; then
  echo "FAIL: native WARP migration must remove the proxy service dependency" >&2
  exit 1
fi
assert_equal '172.16.0.3/32' "$(grep '^WARP_ADDRESS_V4=' "$SB_DIR/warp.env" | cut -d= -f2-)" \
  "migration must use the imported profile"
assert_equal 'daemon-reload' "$(sed -n '1p' "$test_root/systemctl.calls")" \
  "migration must reload the updated unit before restarting"
assert_equal 'restart' "$(sed -n '2p' "$test_root/systemctl.calls")" \
  "migration must restart sing-box before releasing warp-svc"
assert_equal 'disable --now warp-svc.service' "$(sed -n '3p' "$test_root/systemctl.calls")" \
  "migration must stop the script-managed daemon after a stable restart"
assert_equal 0 "$(wc -l < "$test_root/firewall.calls" | tr -d ' ')" \
  "migration from a working proxy must not update the firewall"
assert_equal 0 "$(wc -l < "$test_root/link.calls" | tr -d ' ')" \
  "migration from a working proxy must not rewrite share links"

# Re-importing a native profile must use the new key, not reload the old warp.env.
sed 's/172\.16\.0\.3\/32/172.16.0.4\/32/' "$import_profile" > "$test_root/second-import.conf"
: > "$test_root/systemctl.calls"
repair_warp "$test_root/second-import.conf" > "$test_root/migrate-reimport.log" 2>&1
assert_equal '172.16.0.4/32' "$(grep '^WARP_ADDRESS_V4=' "$SB_DIR/warp.env" | cut -d= -f2-)" \
  "re-import must use the newly supplied profile"
assert_equal 2 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" \
  "re-import must not stop the already unused warp-svc"

# A failed native switch restores the proxy unit, profile, and service state.
printf '%s\n' '{"outbounds":[{"type":"socks","tag":"warp"}],"marker":"proxy-rollback"}' > "$CONF_JSON"
WARP_BACKEND=proxy
save_env
write_singbox_unit
profile_hash_before="$(sha256sum "$WGCF_DIR/wgcf-profile.conf" | awk '{print $1}')"
sed 's/172\.16\.0\.3\/32/172.16.0.5\/32/' "$import_profile" > "$test_root/third-import.conf"
: > "$test_root/fail-restart-once"
: > "$test_root/systemctl.calls"
if repair_warp "$test_root/third-import.conf" > "$test_root/migrate-rollback.log" 2>&1; then
  echo "FAIL: a failed migration restart must roll back" >&2
  exit 1
fi
grep -Fqx 'WARP_BACKEND=proxy' "$SB_DIR/env.conf"
grep -Fq 'Wants=warp-svc.service' "$SYSTEMD_UNIT_DIR/$SYSTEMD_SERVICE"
assert_equal "$profile_hash_before" "$(sha256sum "$WGCF_DIR/wgcf-profile.conf" | awk '{print $1}')" \
  "failed migration must restore the prior profile"
assert_equal proxy-rollback "$(jq -r '.marker' "$CONF_JSON")" \
  "failed migration must restore the prior runtime config"
if grep -Fq 'disable ' "$test_root/systemctl.calls"; then
  echo "FAIL: failed migration must leave warp-svc available" >&2
  exit 1
fi

printf '%s\n' invalid > "$test_root/invalid-warp.conf"
: > "$test_root/systemctl.calls"
if repair_warp "$test_root/invalid-warp.conf" > "$test_root/migrate-invalid.log" 2>&1; then
  echo "FAIL: invalid imported profile must be rejected" >&2
  exit 1
fi
assert_equal 0 "$(wc -l < "$test_root/systemctl.calls" | tr -d ' ')" \
  "invalid profile must not touch services"

printf '%s\n' 'All WARP profile regression tests passed.'
