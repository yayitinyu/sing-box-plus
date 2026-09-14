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
export SBP_SKIP_ROOT=1

# shellcheck source=../sing-box-plus.sh
source "$main_script"

mkdir -p "$CERT_DIR"

curl(){
  printf '%s\n' '203.0.113.10'
}

assert_equal(){
  local expected=$1 actual=$2 message=$3
  if [[ "$expected" != "$actual" ]]; then
    printf 'FAIL: %s (expected=%s actual=%s)\n' "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_file_unchanged(){
  local expected_hash=$1 file=$2 message=$3 actual_hash
  actual_hash=$(sha256sum "$file" | awk '{print $1}')
  assert_equal "$expected_hash" "$actual_hash" "$message"
}

cat > "$SB_DIR/creds.env" <<'EOF'
UUID=11111111-1111-4111-8111-111111111111
HY2_PWD=hy2-password
REALITY_PRIV=reality-private
REALITY_PUB=reality-public
REALITY_SID=1234abcd
HY2_PWD2=hy2-obfs-password
HY2_OBFS_PWD=obfs-password
SS2022_KEY=ss2022-key
SS_PWD=ss-password
TUIC_UUID=11111111-1111-4111-8111-111111111111
TUIC_PWD=11111111-1111-4111-8111-111111111111
ANYTLS_PWD=anytls-password
EOF

cat > "$SB_DIR/ports.env" <<'EOF'
PORT_VLESSR=11001
PORT_VLESS_GRPCR=11002
PORT_TROJANR=11003
PORT_HY2=11004
PORT_VMESS_WS=11005
PORT_HY2_OBFS=11006
PORT_SS2022=11007
PORT_SS=11008
PORT_TUIC=11009
PORT_ANYTLS=11010
PORT_VLESSR_W=12001
PORT_VLESS_GRPCR_W=12002
PORT_TROJANR_W=12003
PORT_HY2_W=12004
PORT_VMESS_WS_W=12005
PORT_HY2_OBFS_W=12006
PORT_SS2022_W=12007
PORT_SS_W=12008
PORT_TUIC_W=12009
PORT_ANYTLS_W=12010
EOF

TLS_CERT_MODE=self_signed
TLS_DOMAIN=""
TLS_CERT_PATH="$CERT_DIR/fullchain.pem"
TLS_KEY_PATH="$CERT_DIR/key.pem"
REALITY_SERVER=www.lovelive-anime.jp
WARP_PRIVATE_KEY="$(printf 'A%.0s' {1..43})="
WARP_PEER_PUBLIC_KEY="$(printf 'B%.0s' {1..43})="
WARP_ENDPOINT_HOST=engage.cloudflareclient.com
WARP_ENDPOINT_PORT=2408
WARP_ADDRESS_V4=172.16.0.2/32
WARP_ADDRESS_V6=2606:4700:110:8765::2/128
WARP_RESERVED_1=0
WARP_RESERVED_2=0
WARP_RESERVED_3=0
save_warp
save_env

print_links_grouped > "$test_root/self-signed-links.log"
assert_equal 20 "$(wc -l < "$SHARE_LINKS_FILE" | tr -d ' ')" \
  "the persisted import file must contain all links"
assert_equal 8 "$(grep -c 'insecure=1' "$SHARE_LINKS_FILE")" \
  "all self-signed certificate-backed links must enable insecure mode (skip cert verification)"
if grep -Fq 'allowInsecure' "$SHARE_LINKS_FILE"; then
  echo "FAIL: import links must not contain the deprecated allowInsecure parameter" >&2
  exit 1
fi
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *)
    assert_equal 600 "$(stat -c '%a' "$SHARE_LINKS_FILE")" \
      "the import file contains credentials and must be root-only"
    ;;
esac

prepare_tls_certificate
old_cert_hash=$(sha256sum "$TLS_CERT_PATH" | awk '{print $1}')
cert_matches_host "$TLS_CERT_PATH" www.lovelive-anime.jp \
  || { echo "FAIL: managed cert must match the current SNI" >&2; exit 1; }
# openssl -checkhost 恒以 0 退出，负向用例确保判定读的是输出而不是退出码
if cert_matches_host "$TLS_CERT_PATH" edge.example.com; then
  echo "FAIL: cert_matches_host must reject a hostname absent from the certificate" >&2
  exit 1
fi

configure_reality_sni <<< 'Edge.Example.COM.'
assert_equal edge.example.com "$REALITY_SERVER" \
  "the SNI editor must normalize domain input"
save_env
prepare_tls_certificate
new_cert_hash=$(sha256sum "$TLS_CERT_PATH" | awk '{print $1}')
if [[ "$old_cert_hash" == "$new_cert_hash" ]]; then
  echo "FAIL: changing Reality SNI must regenerate the managed self-signed certificate" >&2
  exit 1
fi
cert_matches_host "$TLS_CERT_PATH" edge.example.com \
  || { echo "FAIL: regenerated cert must match the updated SNI" >&2; exit 1; }

# 自签证书落后于 SNI 时必须被检出，并可通过重签修复
REALITY_SERVER=stale.example.com
save_env
if ! managed_cert_sni_mismatch; then
  echo "FAIL: a managed cert left on the old SNI must be reported as mismatched" >&2
  exit 1
fi
(reissue_managed_certificate) > "$test_root/reissue.log" 2>&1 \
  || { echo "FAIL: reissue must succeed for a self-signed deployment" >&2; cat "$test_root/reissue.log" >&2; exit 1; }
cert_matches_host "$TLS_CERT_PATH" stale.example.com \
  || { echo "FAIL: reissued cert must match the current SNI" >&2; exit 1; }
if managed_cert_sni_mismatch; then
  echo "FAIL: mismatch must be cleared after reissuing" >&2
  exit 1
fi

# 手动 / ACME 证书不由脚本签发，不应被报成不匹配
TLS_CERT_MODE=manual
if managed_cert_sni_mismatch; then
  echo "FAIL: non self-signed modes must never be reported as SNI mismatched" >&2
  exit 1
fi
TLS_CERT_MODE=self_signed

REALITY_SERVER=edge.example.com
save_env
prepare_tls_certificate
print_links_grouped > "$test_root/updated-sni-links.log"
assert_equal 8 "$(grep -c 'insecure=1&sni=edge.example.com' "$SHARE_LINKS_FILE")" \
  "certificate-backed links must follow the updated self-signed SNI and allow insecure"
assert_equal 6 "$(grep -c 'security=reality&sni=edge.example.com' "$SHARE_LINKS_FILE")" \
  "Reality links must follow the updated SNI"

ENABLE_WARP=false
save_env
write_config
assert_equal 3 "$(jq '[.inbounds[] | select(.tls.reality.enabled == true and .tls.server_name == "edge.example.com" and .tls.reality.handshake.server == "edge.example.com")] | length' "$CONF_JSON")" \
  "the service config must follow the updated Reality SNI"

TLS_CERT_MODE=manual
TLS_DOMAIN=vpn.example.com
save_env
print_links_grouped > "$test_root/domain-links.log"
assert_equal 4 "$(grep -c '@vpn.example.com:' "$SHARE_LINKS_FILE")" \
  "certificate-backed links must follow the configured certificate domain"
assert_equal 4 "$(grep -c 'sni=vpn.example.com' "$SHARE_LINKS_FILE")" \
  "certificate-backed links must use the certificate domain as SNI"
assert_equal 4 "$(grep -c 'insecure=0&sni=vpn.example.com' "$SHARE_LINKS_FILE")" \
  "public certificate-backed links must enforce certificate verification (insecure=0)"
if grep -Eq '(^|[?&])(insecure|allowInsecure)=1([&#]|$)' "$SHARE_LINKS_FILE"; then
  echo "FAIL: invalid public certificate state must not downgrade link security" >&2
  exit 1
fi

TLS_CERT_MODE=self_signed
TLS_DOMAIN=""
REALITY_SERVER=edge.example.com
save_env
printf '%s\n' old-config > "$CONF_JSON"

write_config(){
  printf 'generated-for=%s\n' "$REALITY_SERVER" > "$CONF_JSON"
  save_env
}
open_firewall(){ :; }
print_links_grouped(){
  printf '%s\n' "$REALITY_SERVER" >> "$test_root/link-refreshes"
}
systemctl(){
  case "${1:-}" in
    is-active) return 0 ;;
    restart)
      printf '%s\n' "$REALITY_SERVER" >> "$test_root/restarts"
      if [[ -f "$test_root/fail-restart-once" ]]; then
        rm -f "$test_root/fail-restart-once"
        return 1
      fi
      return 0
      ;;
    *) return 1 ;;
  esac
}

: > "$test_root/link-refreshes"
: > "$test_root/restarts"
REALITY_SERVER=applied.example.com
apply_connection_settings > "$test_root/apply-success.log"
grep -Fqx 'REALITY_SERVER=applied.example.com' "$SB_DIR/env.conf"
grep -Fqx 'generated-for=applied.example.com' "$CONF_JSON"
assert_equal 1 "$(wc -l < "$test_root/link-refreshes" | tr -d ' ')" \
  "successful settings changes must refresh import links"

env_hash=$(sha256sum "$SB_DIR/env.conf" | awk '{print $1}')
config_hash=$(sha256sum "$CONF_JSON" | awk '{print $1}')
cert_hash=$(sha256sum "$CERT_DIR/fullchain.pem" | awk '{print $1}')
key_hash=$(sha256sum "$CERT_DIR/key.pem" | awk '{print $1}')
: > "$test_root/fail-restart-once"
REALITY_SERVER=rollback.example.com
if apply_connection_settings > "$test_root/apply-rollback.log" 2>&1; then
  echo "FAIL: a failed service restart must fail the settings update" >&2
  exit 1
fi
assert_file_unchanged "$env_hash" "$SB_DIR/env.conf" "failed restart must restore env.conf"
assert_file_unchanged "$config_hash" "$CONF_JSON" "failed restart must restore config.json"
assert_file_unchanged "$cert_hash" "$CERT_DIR/fullchain.pem" "failed restart must restore the certificate"
assert_file_unchanged "$key_hash" "$CERT_DIR/key.pem" "failed restart must restore the private key"
assert_equal applied.example.com "$REALITY_SERVER" \
  "failed restart must restore in-memory settings"
assert_equal 1 "$(wc -l < "$test_root/link-refreshes" | tr -d ' ')" \
  "rolled-back settings must not refresh import links"

if declare -f deploy_native | grep -Fq configure_tls_certificate; then
  echo "FAIL: one-click deployment must not open the certificate wizard" >&2
  exit 1
fi
if declare -f menu | grep -Fq configure_tls_certificate; then
  echo "FAIL: default deployment must not open the certificate wizard" >&2
  exit 1
fi

printf '%s\n' "PASS: connection settings are secure, refresh links, and roll back safely"
