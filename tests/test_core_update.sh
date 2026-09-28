#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export TEST_ROOT="$test_root" SBP_SKIP_ROOT=1 SBP_SKIP_DEPS=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SB_DIR="$test_root/state" DATA_DIR="$test_root/state/data"
export CONF_JSON="$test_root/state/config.json" BIN_PATH="$test_root/bin/sing-box"
export SYSTEMD_SERVICE=test-sing-box.service
export SBP_SERVICE_STABILITY_CHECKS=2 SBP_SERVICE_STABILITY_INTERVAL=0
mkdir -p "$SBP_BIN_DIR" "$DATA_DIR"
printf '%s\n' '{}' > "$CONF_JSON"

# shellcheck source=../sing-box-plus.sh
source "$repo_root/sing-box-plus.sh"

cat > "$BIN_PATH" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo 'sing-box version 1.13.13' ;;
  check) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$BIN_PATH"

mkdir -p "$test_root/release/sing-box-1.14.2-linux-amd64"
cat > "$test_root/release/sing-box-1.14.2-linux-amd64/sing-box" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo 'sing-box version 1.14.2' ;;
  check) [[ "${MOCK_NEW_CHECK_FAIL:-0}" != 1 ]] ;;
  *) exit 1 ;;
esac
EOF
chmod 0755 "$test_root/release/sing-box-1.14.2-linux-amd64/sing-box"
tar -czf "$test_root/release.tar.gz" -C "$test_root/release" sing-box-1.14.2-linux-amd64

write_release_json(){
  local digest="$1"
  jq -n --arg digest "sha256:$digest" '{tag_name:"v1.14.2", assets:[{
    name:"sing-box-1.14.2-linux-amd64.tar.gz",
    browser_download_url:"https://example.invalid/sing-box-1.14.2-linux-amd64.tar.gz",
    digest:$digest
  }]}' > "$test_root/release.json"
}
write_release_json "$(sha256sum "$test_root/release.tar.gz" | awk '{print $1}')"

ensure_deps(){ return 0; }
arch_map(){ printf '%s\n' amd64; }
get_singbox_remote_version(){ printf '%s\n' 1.14.2; }
curl(){
  local out=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
  done
  if [[ -n "$out" ]]; then
    cp "$test_root/release.tar.gz" "$out"
  else
    cat "$test_root/release.json"
  fi
}
systemctl(){
  case "${1:-}" in
    is-active) return 0 ;;
    show) printf '%s\n' 1234 ;;
    restart)
      printf '%s\n' restart >> "$test_root/restarts"
      if [[ -f "$test_root/fail-first-restart" && $(wc -l < "$test_root/restarts") -eq 1 ]]; then
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_version(){
  [[ "$(get_singbox_local_version "$BIN_PATH")" == "$1" ]] || fail "expected sing-box $1"
}

touch "$test_root/fail-first-restart"
if update_singbox > "$test_root/restart-failure.log" 2>&1; then
  fail 'update must fail when the new service cannot restart'
fi
assert_version 1.13.13
[[ "$(wc -l < "$test_root/restarts")" -eq 2 ]] || fail 'rollback must restart the old core'

rm -f "$test_root/fail-first-restart" "$test_root/restarts"
export MOCK_NEW_CHECK_FAIL=1
if update_singbox > "$test_root/check-failure.log" 2>&1; then
  fail 'update must reject a candidate that fails config check'
fi
assert_version 1.13.13
[[ ! -f "$test_root/restarts" ]] || fail 'invalid candidate must not restart the service'
unset MOCK_NEW_CHECK_FAIL

write_release_json "$(printf '0%.0s' {1..64})"
if update_singbox > "$test_root/checksum-failure.log" 2>&1; then
  fail 'update must reject an asset with a mismatched checksum'
fi
assert_version 1.13.13
[[ ! -f "$test_root/restarts" ]] || fail 'checksum failure must not restart the service'

write_release_json "$(sha256sum "$test_root/release.tar.gz" | awk '{print $1}')"
update_singbox > "$test_root/success.log" 2>&1 || fail 'valid update must succeed'
assert_version 1.14.2
[[ "$(wc -l < "$test_root/restarts")" -eq 1 ]] || fail 'valid update must restart once'

printf '%s\n' 'Core update transaction tests passed.'
