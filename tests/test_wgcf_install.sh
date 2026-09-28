#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export TEST_ROOT="$test_root" SBP_SKIP_ROOT=1 SBP_SKIP_DEPS=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SB_DIR="$test_root/state" WGCF_BIN="$test_root/bin/wgcf"
mkdir -p "$SBP_BIN_DIR" "$SB_DIR"

# shellcheck source=../sing-box-plus.sh
source "$repo_root/sing-box-plus.sh"

cat > "$WGCF_BIN" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --help ]]
EOF
chmod 0755 "$WGCF_BIN"
old_hash=$(sha256sum "$WGCF_BIN" | awk '{print $1}')

cat > "$test_root/wgcf-new" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == --help ]]
EOF
printf '%s\n' '# release v2.3.0' >> "$test_root/wgcf-new"
chmod 0755 "$test_root/wgcf-new"
new_hash=$(sha256sum "$test_root/wgcf-new" | awk '{print $1}')

write_release_json(){
  local digest="$1"
  jq -n --arg digest "sha256:$digest" '{tag_name:"v2.3.0", assets:[{
    name:"wgcf_2.3.0_linux_amd64",
    browser_download_url:"https://example.invalid/wgcf_2.3.0_linux_amd64",
    digest:$digest
  }]}' > "$test_root/release.json"
}
write_release_json "$new_hash"

arch_map(){ printf '%s\n' amd64; }
curl(){
  local out=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
  done
  if [[ -n "$out" ]]; then
    [[ ! -f "$test_root/fail-download" ]] || return 1
    cp "$test_root/wgcf-new" "$out"
  else
    cat "$test_root/release.json"
  fi
}
fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }
assert_hash(){
  [[ "$(sha256sum "$WGCF_BIN" | awk '{print $1}')" == "$1" ]] || fail 'wgcf binary hash changed unexpectedly'
}

touch "$test_root/fail-download"
if install_wgcf > "$test_root/download-failure.log" 2>&1; then
  fail 'a stale installed wgcf must not hide a failed update'
fi
assert_hash "$old_hash"
rm -f "$test_root/fail-download"

write_release_json "$(printf '0%.0s' {1..64})"
if install_wgcf > "$test_root/checksum-failure.log" 2>&1; then
  fail 'wgcf must reject a mismatched release digest'
fi
assert_hash "$old_hash"

write_release_json "$new_hash"
install_wgcf > "$test_root/success.log" 2>&1 || fail 'wgcf update must succeed'
assert_hash "$new_hash"

install_wgcf > "$test_root/unchanged.log" 2>&1 || fail 'current wgcf must remain usable'
assert_hash "$new_hash"

printf '%s\n' 'wgcf installation tests passed.'
