#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
main_script=${SBP_TEST_SCRIPT:-$repo_root/sing-box-plus.sh}
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
if [[ -n "${SBP_TEST_JQ:-}" ]]; then
  [[ -x "$SBP_TEST_JQ" ]] || { echo 'SBP_TEST_JQ must name an executable' >&2; exit 1; }
  jq(){ "$SBP_TEST_JQ" "$@"; }
fi
command -v jq >/dev/null 2>&1 || { echo 'jq is required' >&2; exit 1; }
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) export MSYS2_ARG_CONV_EXCL='/CN=' ;;
esac

export SBP_SKIP_DEPS=1 SBP_SKIP_ROOT=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SBP_DEPS_SENTINEL="$test_root/runtime/.deps_ok"
export SB_DIR="$test_root/state" CONF_JSON="$test_root/state/config.json"
export DATA_DIR="$test_root/state/data" CERT_DIR="$test_root/state/cert"
export WGCF_DIR="$test_root/state/wgcf" ROUTE_JSON="$test_root/state/routes.json"
export SOCKS_NODES_JSON="$test_root/state/socks-nodes.json"
export SHARE_LINKS_FILE="$test_root/state/share-links.txt"
export BIN_PATH="$test_root/bin/sing-box" WGCF_BIN="$test_root/bin/wgcf"
mkdir -p "$SBP_BIN_DIR" "$CERT_DIR"
cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) printf 'sing-box version %s\n' "$MOCK_CORE_VERSION" ;;
  check) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 755 "$BIN_PATH"

reality_private=test-private-key
reality_public=test-public-key
ss2022_key=$(printf 'A%.0s' {1..43})=
if [[ -n "${SBP_REAL_SING_BOX_BIN:-}" ]]; then
  pair=$("$SBP_REAL_SING_BOX_BIN" generate reality-keypair)
  reality_private=$(awk -F': ' '$1=="PrivateKey" {print $2}' <<< "$pair" | tr -d '\r')
  reality_public=$(awk -F': ' '$1=="PublicKey" {print $2}' <<< "$pair" | tr -d '\r')
fi
openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 1 -subj '/CN=example.com' \
  -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/fullchain.pem" >/dev/null 2>&1

expected_protocols=(vless-reality vless-grpcr trojan-reality hy2 vmess-ws hy2-obfs ss2022 ss tuic-v5 anytls)
expected_tags=$(jq -cn --args '$ARGS.positional' "${expected_protocols[@]}")

generate_fixture()(
  local script="$1" backend="$2" version="$3" tls_mode="$4" variant="$5" output="$6"
  export MOCK_CORE_VERSION="$version"
  unset ENABLE_WARP
  rm -f -- "$SB_DIR/env.conf" "$SB_DIR/ports.env" "$SB_DIR/creds.env" "$SB_DIR/warp.env" "$ROUTE_JSON"
  # shellcheck source=../sing-box-plus.sh
  source "$script"
  ensure_creds(){ return 0; }
  prepare_tls_certificate(){ return 0; }
  default_ipv4_address(){ printf '%s\n' '192.0.2.10'; }
  default_ipv6_address(){ printf '%s\n' '2001:db8::10'; }
  ensure_warp_profile(){ warp_profile_ready; }
  ensure_warp_proxy(){ valid_warp_proxy_settings; }
  UUID=11111111-1111-4111-8111-111111111111
  REALITY_PRIV="$reality_private"; REALITY_PUB="$reality_public"; REALITY_SID=1234abcd
  HY2_PWD=test-hy2-password; HY2_PWD2=test-hy2-obfs-password; HY2_OBFS_PWD=test-obfs-password
  SS2022_KEY="$ss2022_key"; SS_PWD=test-ss-password
  TUIC_UUID="$UUID"; TUIC_PWD=test-tuic-password; ANYTLS_PWD=test-anytls-password
  local index=0 var
  for var in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS \
      PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS; do
    printf -v "$var" '%s' "$((21001+index))"
    printf -v "${var}_W" '%s' "$((22001+index))"
    index=$((index+1))
  done
  WARP_BACKEND="$backend"; [[ "$backend" == disabled ]] || ENABLE_WARP=true
  WARP_PRIVATE_KEY=$(printf 'A%.0s' {1..43})=; WARP_PEER_PUBLIC_KEY=$(printf 'B%.0s' {1..43})=
  WARP_ENDPOINT_HOST=engage.cloudflareclient.com; WARP_ENDPOINT_PORT=2408
  WARP_ADDRESS_V4=172.16.0.2/32; WARP_ADDRESS_V6=2606:4700:110::2/128
  WARP_RESERVED_1=0; WARP_RESERVED_2=0; WARP_RESERVED_3=0
  WARP_SOCKS_HOST=127.0.0.1; WARP_SOCKS_PORT=40000; WARP_KEEPALIVE_INTERVAL=25
  TLS_CERT_MODE="$tls_mode"; TLS_DOMAIN=example.com
  if [[ "$variant" == decimal ]]; then
    PORT_VLESSR=08001; WARP_ENDPOINT_PORT=02408; WARP_RESERVED_1=08; WARP_KEEPALIVE_INTERVAL=08
  elif [[ "$variant" == stale ]]; then
    WARP_ENDPOINT_PORT=invalid; WARP_RESERVED_1=invalid
  fi
  if ! write_config > "$test_root/generate.log" 2>&1; then cat "$test_root/generate.log" >&2; return 1; fi
  cp -- "$CONF_JSON" "$output"
)

for version in 1.13.13 1.14.2; do
  for backend in disabled wireguard proxy; do
    for tls_mode in self_signed acme; do
      fixture="$test_root/$version-$backend-$tls_mode.json"
      generate_fixture "$main_script" "$backend" "$version" "$tls_mode" normal "$fixture"
      jq -e --argjson tags "$expected_tags" --arg backend "$backend" '
        . as $config
        | [.inbounds[] | select(.tag | endswith("-warp") | not) | .tag] == $tags
        and ([.inbounds[].listen_port] | length == (unique | length))
        and (if $backend == "disabled" then
          (.inbounds | length) == 10 and (.endpoints | length) == 0
          and all(.outbounds[]; .tag != "warp")
        else
          (.inbounds | length) == 20
          and all(.inbounds[] | select(.tag | endswith("-warp"));
            . as $warp
            | ($config.inbounds[] | select(.tag == ($warp.tag | rtrimstr("-warp"))) | del(.tag,.listen_port))
              == ($warp | del(.tag,.listen_port)))
          and (.route.rules[-1].inbound == ($tags | map(. + "-warp")))
          and .route.rules[-1].outbound == "warp"
          and (if $backend == "wireguard" then
            (.endpoints | length) == 1 and .endpoints[0].mtu == 1280
            and .endpoints[0].peers[0].persistent_keepalive_interval == 25
          else (.endpoints | length) == 0 and any(.outbounds[]; .tag == "warp" and .type == "socks") end)
        end)
      ' "$fixture" >/dev/null || { echo "FAIL: protocol contract: $version/$backend/$tls_mode" >&2; exit 1; }
      if [[ -n "${SBP_CONFIG_BASELINE_SCRIPT:-}" ]]; then
        baseline="$fixture.baseline"
        generate_fixture "$SBP_CONFIG_BASELINE_SCRIPT" "$backend" "$version" "$tls_mode" normal "$baseline"
        jq -e --slurpfile baseline "$baseline" '. == $baseline[0]' "$fixture" >/dev/null \
          || { echo "FAIL: config differs from baseline: $version/$backend/$tls_mode" >&2; exit 1; }
      fi
      if [[ -n "${SBP_REAL_SING_BOX_BIN:-}" ]] \
          && [[ "$("$SBP_REAL_SING_BOX_BIN" version | head -n1 | tr -d '\r')" == "sing-box version $version" ]]; then
        "$SBP_REAL_SING_BOX_BIN" check -c "$fixture"
      fi
    done
  done
done
printf '%s\n' 'PASS: direct/WARP templates and TLS configuration for sing-box 1.13/1.14'

case "${1:-all}" in
  compatibility) exit 0 ;;
esac

generate_fixture "$main_script" wireguard 1.14.2 self_signed decimal "$test_root/decimal.json"
jq -e '.inbounds[0].listen_port == 8001 and .endpoints[0].peers[0].port == 2408
  and .endpoints[0].peers[0].reserved[0] == 8
  and .endpoints[0].peers[0].persistent_keepalive_interval == 8' "$test_root/decimal.json" >/dev/null
generate_fixture "$main_script" disabled 1.14.2 self_signed stale "$test_root/stale.json"
jq -e '(.inbounds | length) == 10 and (.endpoints | length) == 0' "$test_root/stale.json" >/dev/null
generate_fixture "$main_script" proxy 1.14.2 self_signed stale "$test_root/proxy-stale.json"
jq -e '(.inbounds | length) == 20 and any(.outbounds[]; .tag == "warp" and .type == "socks")' \
  "$test_root/proxy-stale.json" >/dev/null
printf '%s\n' 'PASS: decimal normalization and inactive WARP credentials'

source "$main_script"
ensure_dirs
ANYTLS_PWD="password with spaces and 'quotes'"
save_creds
ANYTLS_PWD=''
load_creds
[[ "$ANYTLS_PWD" == "password with spaces and 'quotes'" ]]
save_env
original_hash=$(sha256sum "$SB_DIR/env.conf")
(
  mv(){ return 1; }
  REALITY_SERVER=changed.example.com
  if save_env; then echo 'FAIL: save_env must propagate failed file replacement' >&2; exit 1; fi
)
[[ "$(sha256sum "$SB_DIR/env.conf")" == "$original_hash" ]]
[[ -z "$(find "$SB_DIR" -maxdepth 1 -name 'env.conf.tmp.*' -print)" ]]
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) ;;
  *) [[ "$(stat -c %a "$SB_DIR/creds.env")" == 600 && "$(stat -c %a "$SB_DIR/env.conf")" == 600 ]] ;;
esac
printf '%s\n' 'PASS: quoted private state and failed atomic writes preserve existing files'
