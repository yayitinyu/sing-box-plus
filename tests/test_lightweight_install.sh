#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

export TEST_ROOT="$test_root" SBP_SKIP_ROOT=1 SBP_SKIP_DEPS=1
export SBP_ROOT="$test_root/runtime" SBP_BIN_DIR="$test_root/bin"
export SB_DIR="$test_root/state"
mkdir -p "$SBP_BIN_DIR" "$SB_DIR"
unset ENABLE_WARP

# shellcheck source=../sing-box-plus.sh
source "$repo_root/sing-box-plus.sh"

fail(){ printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[[ "$ENABLE_WARP" == false ]] || fail 'a new installation must leave WARP disabled by default'

printf 'ENABLE_WARP=true\n' > "$SB_DIR/env.conf"
load_env
[[ "$ENABLE_WARP" == true ]] || fail 'existing WARP state must survive an upgrade'

ENABLE_WARP=false SB_DIR="$SB_DIR" bash -c '
  source "$1"
  load_env
  [[ "$ENABLE_WARP" == false ]]
' bash "$repo_root/sing-box-plus.sh" || fail 'an explicit WARP override must take precedence'

# No package manager refresh or install is needed when the core tools exist.
for tool in curl jq tar openssl sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || fail "test prerequisite missing: $tool"
done
SBP_FORCE_DEPS=0
sbp_detect_pm(){ PM=apt; }
sbp_pm_refresh(){ printf 'refresh\n' >> "$test_root/packages.log"; }
sbp_pm_install(){ printf '%s\n' "$@" >> "$test_root/packages.log"; }
sbp_install_prereqs_pm
[[ ! -e "$test_root/packages.log" ]] || fail 'available tools must not trigger package operations'

# A missing command should install its package alone.
(
  mock_missing_jq=true
  command(){
    if [[ "$1" == -v && "$2" == jq && "$mock_missing_jq" == true ]]; then
      return 1
    fi
    builtin command "$@"
  }
  sbp_pm_install(){
    printf '%s\n' "$@" > "$test_root/packages.log"
    mock_missing_jq=false
  }
  sbp_install_prereqs_pm
)
[[ "$(cat "$test_root/packages.log")" == jq ]] || fail 'only the missing jq package should be installed'

# Install a firewall tool only if no usable backend is present at deployment.
(
  mock_iptables_ready=false
  command(){
    if [[ "$1" == -v ]]; then
      case "$2" in
        ufw|firewall-cmd|netfilter-persistent) return 1 ;;
        iptables) [[ "$mock_iptables_ready" == true ]]; return ;;
      esac
    fi
    builtin command "$@"
  }
  ensure_deps(){
    [[ "$1" == iptables ]] || return 1
    printf '%s\n' "$1" > "$test_root/firewall-package.log"
    mock_iptables_ready=true
  }
  iptables(){ return 0; }
  open_firewall
)
[[ "$(cat "$test_root/firewall-package.log")" == iptables ]] || \
  fail 'the firewall path must request only iptables when no backend exists'

printf '%s\n' 'Lightweight installation tests passed.'
