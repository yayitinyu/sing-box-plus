#!/usr/bin/env bash
# ============================================================
#  Sing-Box-Plus 管理脚本（20 节点：直连 10 + WARP 10）
#  Version: v3.2.3
# ============================================================

set -Eeuo pipefail

[[ -t 0 ]] && stty erase ^H 2>/dev/null || true # 让退格键在终端里正常工作（仅交互模式）
# ===== [BEGIN] SBP 引导模块 v2.2.0+（包管理器优先 + 二进制回退） =====
# 模式与哨兵
: "${SBP_SOFT:=0}"                               # 1=宽松模式（失败尽量继续），默认 0=严格
: "${SBP_SKIP_DEPS:=0}"                          # 1=启动跳过依赖检查（只在菜单 1) 再装）
: "${SBP_FORCE_DEPS:=0}"                         # 1=强制重新安装依赖
: "${SBP_BIN_ONLY:=0}"                           # 1=强制走二进制模式，不用包管理器
: "${SBP_ROOT:=/var/lib/sing-box-plus}"
: "${SBP_BIN_DIR:=${SBP_ROOT}/bin}"
: "${SBP_DEPS_SENTINEL:=/var/lib/sing-box-plus/.deps_ok}"

mkdir -p "$SBP_BIN_DIR" 2>/dev/null || true
export PATH="$SBP_BIN_DIR:$PATH"

# 工具：下载器 + 轻量重试
dl() { # 用法：dl <URL> <OUT_PATH>
  local url="$1" out="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 2 --connect-timeout 5 -o "$out" "$url"
  elif command -v wget >/dev/null 2>&1; then
    timeout 15 wget -qO "$out" --tries=2 "$url"
  else
    echo "[ERROR] 缺少 curl/wget：无法下载 $url"; return 1
  fi
}
with_retry() { local n=${1:-3}; shift; local i=1; until "$@"; do [ $i -ge "$n" ] && return 1; sleep $((i*2)); i=$((i+1)); done; }

# 工具：架构探测 + jq 静态兜底
detect_goarch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armv7) echo armv7 ;;
    i386|i686)    echo 386   ;;
    *)            echo amd64 ;;
  esac
}
ensure_jq_static() {
  command -v jq >/dev/null 2>&1 && return 0
  local arch out="$SBP_BIN_DIR/jq" url alt
  arch="$(detect_goarch)"
  url="https://github.com/jqlang/jq/releases/latest/download/jq-linux-${arch}"
  alt="https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64"
  dl "$url" "$out" || { [ "$arch" = amd64 ] && dl "$alt" "$out" || true; }
  chmod +x "$out" 2>/dev/null || true
  command -v jq >/dev/null 2>&1
}

# 工具：核心命令自检
sbp_core_ok() {
  local need=(curl jq tar unzip openssl)
  local b; for b in "${need[@]}"; do command -v "$b" >/dev/null 2>&1 || return 1; done
  return 0
}

# —— 包管理器路径 —— #
sbp_detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then PM=apt
  elif command -v dnf      >/dev/null 2>&1; then PM=dnf
  elif command -v yum      >/dev/null 2>&1; then PM=yum
  elif command -v pacman   >/dev/null 2>&1; then PM=pacman
  elif command -v zypper   >/dev/null 2>&1; then PM=zypper
  else PM=unknown; fi
  [ "$PM" = unknown ] && return 1 || return 0
}

# apt 允许发行信息变化（stable→oldstable / Version 变化）
apt_allow_release_change() {
  cat >/etc/apt/apt.conf.d/99allow-releaseinfo-change <<'CONF'
Acquire::AllowReleaseInfoChange::Suite "true";
Acquire::AllowReleaseInfoChange::Version "true";
CONF
}

# 刷新软件仓（含各系兜底）
sbp_pm_refresh() {
  case "$PM" in
    apt)
      apt_allow_release_change
      sed -i 's#^deb http://#deb https://#' /etc/apt/sources.list 2>/dev/null || true
      # 修正 bullseye 的 security 行：bullseye/updates → debian-security bullseye-security
      sed -i -E 's#^(deb\s+https?://security\.debian\.org)(/debian-security)?\s+bullseye/updates(.*)$#\1/debian-security bullseye-security\3#' /etc/apt/sources.list

      local AOPT=""
      curl -6 -fsS --connect-timeout 2 https://deb.debian.org >/dev/null 2>&1 || AOPT='-o Acquire::ForceIPv4=true'

      if ! with_retry 3 apt-get update -y $AOPT; then
        # backports 404 临时注释再试
        sed -i 's#^\([[:space:]]*deb .* bullseye-backports.*\)#\# \1#' /etc/apt/sources.list 2>/dev/null || true
        with_retry 2 apt-get update -y $AOPT -o Acquire::Check-Valid-Until=false || [ "$SBP_SOFT" = 1 ]
      fi
      ;;
    dnf)
      dnf clean metadata || true
      with_retry 3 dnf makecache || [ "$SBP_SOFT" = 1 ]
      ;;
    yum)
      yum clean all || true
      with_retry 3 yum makecache fast || true
      yum install -y epel-release || true   # EL7/老环境便于装 jq 等
      ;;
    pacman)
      pacman-key --init >/dev/null 2>&1 || true
      pacman-key --populate archlinux >/dev/null 2>&1 || true
      with_retry 3 pacman -Syy --noconfirm || [ "$SBP_SOFT" = 1 ]
      ;;
    zypper)
      zypper -n ref || zypper -n ref --force || true
      ;;
  esac
}

# 逐包安装（单个失败不拖累整体）
sbp_pm_install() {
  case "$PM" in
    apt)
      local p; apt-get update -y >/dev/null 2>&1 || true
      for p in "$@"; do apt-get install -y --no-install-recommends "$p" || true; done
      ;;
    dnf)
      local p; for p in "$@"; do dnf install -y "$p" || true; done
      ;;
    yum)
      yum install -y epel-release || true
      local p; for p in "$@"; do yum install -y "$p" || true; done
      ;;
    pacman)
      pacman -Sy --noconfirm || [ "$SBP_SOFT" = 1 ]
      local p; for p in "$@"; do pacman -S --noconfirm --needed "$p" || true; done
      ;;
    zypper)
      zypper -n ref || true
      local p; for p in "$@"; do zypper --non-interactive install "$p" || true; done
      ;;
  esac
}

# 用包管理器装一轮依赖
sbp_install_prereqs_pm() {
  sbp_detect_pm || return 1
  sbp_pm_refresh

  case "$PM" in
    apt)    CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz-utils uuid-runtime iproute2 iptables ufw) ;;
    dnf|yum)CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute iptables iptables-nft firewalld) ;;
    pacman) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables) ;;
    zypper) CORE=(curl jq tar unzip openssl); EXTRA=(ca-certificates xz util-linux iproute2 iptables firewalld) ;;
    *) return 1 ;;
  esac

  sbp_pm_install "${CORE[@]}" "${EXTRA[@]}"

  # jq 兜底：安装失败时下载静态 jq
  if ! command -v jq >/dev/null 2>&1; then
    echo "[INFO] 通过包管理器安装 jq 失败，尝试下载静态 jq ..."
    ensure_jq_static || { echo "[ERROR] 无法获取 jq"; return 1; }
  fi

  # 严格模式：核心仍缺则失败
  if ! sbp_core_ok; then
    [ "$SBP_SOFT" = 1 ] || return 1
    echo "[WARN] 核心依赖未就绪（宽松模式继续）"
  fi
  return 0
}

# —— 二进制模式：直接获取 sing-box 可执行文件 —— #
install_singbox_binary() {
  local arch goarch pkg tmp json url fn
  goarch="$(detect_goarch)"
  tmp="$(mktemp -d)" || return 1

  ensure_jq_static || { echo "[ERROR] 无法获取 jq，二进制模式失败"; rm -rf "$tmp"; return 1; }

  json="$(with_retry 3 curl -fsSL https://api.github.com/repos/SagerNet/sing-box/releases/latest)" || { rm -rf "$tmp"; return 1; }
  url="$(printf '%s' "$json" | jq -r --arg a "$goarch" '
    .assets[] | select(.name|test("linux-" + $a + "\\.(tar\\.(xz|gz)|zip)$")) | .browser_download_url
  ' | head -n1)"

  if [ -z "$url" ] || [ "$url" = "null" ]; then
    echo "[ERROR] 未找到匹配架构($goarch)的 sing-box 资产"; rm -rf "$tmp"; return 1
  fi

  pkg="$tmp/pkg"
  with_retry 3 dl "$url" "$pkg" || { rm -rf "$tmp"; return 1; }

  case "$url" in
    *.tar.xz)  if command -v xz >/dev/null 2>&1; then tar -xJf "$pkg" -C "$tmp"; else echo "[ERROR] 缺少 xz；请安装 xz/xz-utils 或换 .tar.gz/.zip"; rm -rf "$tmp"; return 1; fi ;;
    *.tar.gz)  tar -xzf "$pkg" -C "$tmp" ;;
    *.zip)     unzip -q "$pkg" -d "$tmp" || { echo "[ERROR] 缺少 unzip"; rm -rf "$tmp"; return 1; } ;;
    *)         echo "[ERROR] 未知包格式：$url"; rm -rf "$tmp"; return 1 ;;
  esac

  fn="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  [ -n "$fn" ] || { echo "[ERROR] 包内未找到 sing-box"; rm -rf "$tmp"; return 1; }

  local target="${BIN_PATH:-/usr/local/bin/sing-box}"
  mkdir -p "$(dirname "$target")" "$SBP_BIN_DIR" 2>/dev/null || true
  install -m 0755 "$fn" "$target" || { rm -rf "$tmp"; return 1; }
  ln -sf "$target" "$SBP_BIN_DIR/sing-box" 2>/dev/null || true
  rm -rf "$tmp"
  echo "[OK] 已安装 sing-box 到 $target"
}

# 证书兜底（有 openssl 就生成；没有就先跳过，由业务决定是否强制）
ensure_tls_cert() {
  local dir="$SBP_ROOT"
  mkdir -p "$dir"
  if command -v openssl >/dev/null 2>&1; then
    [[ -f "$dir/private.key" ]] || openssl ecparam -genkey -name prime256v1 -out "$dir/private.key" >/dev/null 2>&1
    [[ -f "$dir/cert.pem"    ]] || openssl req -new -x509 -days 36500 -key "$dir/private.key" -out "$dir/cert.pem" -subj "/CN=www.bing.com" >/dev/null 2>&1
  fi
}

# 标记哨兵
sbp_mark_deps_ok() {
  if sbp_core_ok; then
    mkdir -p "$(dirname "$SBP_DEPS_SENTINEL")" && : > "$SBP_DEPS_SENTINEL" || true
  fi
}

# 入口：装依赖 / 二进制回退
sbp_bootstrap() {
  [ "$EUID" -eq 0 ] || [ "${SBP_SKIP_ROOT:-0}" = 1 ] || [ -n "${TEST_ROOT:-}" ] || { echo "请以 root 运行（或 sudo）"; exit 1; }

  if [ "$SBP_SKIP_DEPS" = 1 ]; then
    echo "[INFO] 已跳过启动时依赖检查（SBP_SKIP_DEPS=1）"
    return 0
  fi

  # 已就绪则跳过
  if [ "$SBP_FORCE_DEPS" != 1 ] && sbp_core_ok && [ -f "$SBP_DEPS_SENTINEL" ] && [ "$SBP_BIN_ONLY" != 1 ]; then
    echo "依赖已安装"
    return 0
  fi

  # 强制二进制模式
  if [ "$SBP_BIN_ONLY" = 1 ]; then
    echo "[INFO] 二进制模式（SBP_BIN_ONLY=1）"
    install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
    ensure_tls_cert
    return 0
  fi

  # 包管理器优先
  if sbp_install_prereqs_pm; then
    sbp_mark_deps_ok
    return 0
  fi

  # 回退到二进制模式
  echo "[WARN] 包管理器依赖安装失败，切换到二进制模式"
  install_singbox_binary || { echo "[ERROR] 二进制模式安装 sing-box 失败"; exit 1; }
  ensure_tls_cert
}
# ===== [END] SBP 引导模块 v2.2.0+ =====


# ===== 提前设默认，避免 set -u 早期引用未定义变量导致脚本直接退出 =====
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DATA_DIR=${DATA_DIR:-$SB_DIR/data}
CERT_DIR=${CERT_DIR:-$SB_DIR/cert}
WGCF_DIR=${WGCF_DIR:-$SB_DIR/wgcf}
DIAG_DIR=${DIAG_DIR:-$SB_DIR/diagnostics}
RESTART_LOG=${RESTART_LOG:-$SB_DIR/restart.log}
DNS_HEALTH_LOG=${DNS_HEALTH_LOG:-$SB_DIR/dns-health.log}
DNS_HEALTH_BIN=${DNS_HEALTH_BIN:-/usr/local/sbin/sing-box-plus-dns-health}
EVENT_LOG_BIN=${EVENT_LOG_BIN:-/usr/local/sbin/sing-box-plus-event}
DNS_HEALTH_SERVICE=${DNS_HEALTH_SERVICE:-sing-box-plus-dns-health.service}
DNS_HEALTH_TIMER=${DNS_HEALTH_TIMER:-sing-box-plus-dns-health.timer}
SYSTEMD_UNIT_DIR=${SYSTEMD_UNIT_DIR:-/etc/systemd/system}
SBP_SCRIPT_PATH=${SBP_SCRIPT_PATH:-/root/sbp.sh}
SBP_REPO=${SBP_REPO:-yayitinyu/sing-box-plus}
SBP_BRANCH=${SBP_BRANCH:-main}
ROUTE_JSON=${ROUTE_JSON:-$SB_DIR/routes.json}
SHARE_LINKS_FILE=${SHARE_LINKS_FILE:-$SB_DIR/share-links.txt}

# 功能开关（保持稳定默认）
ENABLE_WARP=${ENABLE_WARP:-true}
ENABLE_VLESS_REALITY=${ENABLE_VLESS_REALITY:-true}
ENABLE_VLESS_GRPCR=${ENABLE_VLESS_GRPCR:-true}
ENABLE_TROJAN_REALITY=${ENABLE_TROJAN_REALITY:-true}
ENABLE_HYSTERIA2=${ENABLE_HYSTERIA2:-true}
ENABLE_VMESS_WS=${ENABLE_VMESS_WS:-true}
ENABLE_HY2_OBFS=${ENABLE_HY2_OBFS:-true}
ENABLE_SS2022=${ENABLE_SS2022:-true}
ENABLE_SS=${ENABLE_SS:-true}
ENABLE_TUIC=${ENABLE_TUIC:-true}
ENABLE_ANYTLS=${ENABLE_ANYTLS:-true}

# TLS 证书模式：self_signed（默认）/ manual（手动证书）/ acme（自动申请）
TLS_CERT_MODE=${TLS_CERT_MODE:-self_signed}
TLS_DOMAIN=${TLS_DOMAIN:-}
TLS_CERT_PATH=${TLS_CERT_PATH:-$CERT_DIR/fullchain.pem}
TLS_KEY_PATH=${TLS_KEY_PATH:-$CERT_DIR/key.pem}
TLS_ACME_EMAIL=${TLS_ACME_EMAIL:-}
TLS_ACME_PROVIDER=${TLS_ACME_PROVIDER:-letsencrypt}
TLS_ACME_DATA_DIR=${TLS_ACME_DATA_DIR:-$CERT_DIR/acme}
TLS_ACME_DISABLE_HTTP_CHALLENGE=${TLS_ACME_DISABLE_HTTP_CHALLENGE:-false}
TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE=${TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE:-true}

# 连接稳定性参数（均可在运行脚本前通过环境变量覆盖）
SBP_TCP_KEEP_ALIVE_OVERRIDE=${TCP_KEEP_ALIVE-}
SBP_TCP_KEEP_ALIVE_INTERVAL_OVERRIDE=${TCP_KEEP_ALIVE_INTERVAL-}
SBP_UDP_TIMEOUT_OVERRIDE=${UDP_TIMEOUT-}
SBP_WARP_KEEPALIVE_INTERVAL_OVERRIDE=${WARP_KEEPALIVE_INTERVAL-}
SBP_DNS_HEALTH_INTERVAL_OVERRIDE=${DNS_HEALTH_INTERVAL-}
SBP_DNS_FAILURE_THRESHOLD_OVERRIDE=${DNS_FAILURE_THRESHOLD-}
SBP_DNS_RECOVERY_THRESHOLD_OVERRIDE=${DNS_RECOVERY_THRESHOLD-}
SBP_DNS_SWITCH_COOLDOWN_OVERRIDE=${DNS_SWITCH_COOLDOWN-}
TCP_KEEP_ALIVE=${TCP_KEEP_ALIVE:-30s}
TCP_KEEP_ALIVE_INTERVAL=${TCP_KEEP_ALIVE_INTERVAL:-30s}
UDP_TIMEOUT=${UDP_TIMEOUT:-10m}
WARP_KEEPALIVE_INTERVAL=${WARP_KEEPALIVE_INTERVAL:-25}
DNS_HEALTH_INTERVAL=${DNS_HEALTH_INTERVAL:-2m}
DNS_FAILURE_THRESHOLD=${DNS_FAILURE_THRESHOLD:-3}
DNS_RECOVERY_THRESHOLD=${DNS_RECOVERY_THRESHOLD:-5}
DNS_SWITCH_COOLDOWN=${DNS_SWITCH_COOLDOWN:-600}

# 常量
SCRIPT_NAME="Sing-Box-Plus 管理脚本"
SCRIPT_VERSION="v3.2.3"
REALITY_SERVER=${REALITY_SERVER:-www.lovelive-anime.jp}
REALITY_SERVER_PORT=${REALITY_SERVER_PORT:-443}
GRPC_SERVICE=${GRPC_SERVICE:-grpc}
VMESS_WS_PATH=${VMESS_WS_PATH:-/vm}

# ===== 颜色 =====
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_RED="\033[31m";  C_GREEN="\033[32m"; C_YELLOW="\033[33m"
C_BLUE="\033[34m"; C_CYAN="\033[36m"; C_MAGENTA="\033[35m"
hr(){ printf "${C_DIM}=============================================================${C_RESET}\n"; }

# ===== 基础工具 =====
info(){ echo -e "[${C_CYAN}信息${C_RESET}] $*"; }
warn(){ echo -e "[${C_YELLOW}警告${C_RESET}] $*"; }
die(){  echo -e "[${C_RED}错误${C_RESET}] $*" >&2; exit 1; }

valid_duration(){
  [[ "${1:-}" =~ ^([0-9]+(ms|s|m|h))+$ ]]
}

apply_runtime_overrides(){
  [[ -n "$SBP_TCP_KEEP_ALIVE_OVERRIDE" ]] && TCP_KEEP_ALIVE=$SBP_TCP_KEEP_ALIVE_OVERRIDE
  [[ -n "$SBP_TCP_KEEP_ALIVE_INTERVAL_OVERRIDE" ]] && TCP_KEEP_ALIVE_INTERVAL=$SBP_TCP_KEEP_ALIVE_INTERVAL_OVERRIDE
  [[ -n "$SBP_UDP_TIMEOUT_OVERRIDE" ]] && UDP_TIMEOUT=$SBP_UDP_TIMEOUT_OVERRIDE
  [[ -n "$SBP_WARP_KEEPALIVE_INTERVAL_OVERRIDE" ]] && WARP_KEEPALIVE_INTERVAL=$SBP_WARP_KEEPALIVE_INTERVAL_OVERRIDE
  [[ -n "$SBP_DNS_HEALTH_INTERVAL_OVERRIDE" ]] && DNS_HEALTH_INTERVAL=$SBP_DNS_HEALTH_INTERVAL_OVERRIDE
  [[ -n "$SBP_DNS_FAILURE_THRESHOLD_OVERRIDE" ]] && DNS_FAILURE_THRESHOLD=$SBP_DNS_FAILURE_THRESHOLD_OVERRIDE
  [[ -n "$SBP_DNS_RECOVERY_THRESHOLD_OVERRIDE" ]] && DNS_RECOVERY_THRESHOLD=$SBP_DNS_RECOVERY_THRESHOLD_OVERRIDE
  [[ -n "$SBP_DNS_SWITCH_COOLDOWN_OVERRIDE" ]] && DNS_SWITCH_COOLDOWN=$SBP_DNS_SWITCH_COOLDOWN_OVERRIDE
  return 0
}

normalize_runtime_settings(){
  valid_duration "$TCP_KEEP_ALIVE" || { warn "TCP_KEEP_ALIVE 无效，已恢复为 30s"; TCP_KEEP_ALIVE=30s; }
  valid_duration "$TCP_KEEP_ALIVE_INTERVAL" || { warn "TCP_KEEP_ALIVE_INTERVAL 无效，已恢复为 30s"; TCP_KEEP_ALIVE_INTERVAL=30s; }
  valid_duration "$UDP_TIMEOUT" || { warn "UDP_TIMEOUT 无效，已恢复为 10m"; UDP_TIMEOUT=10m; }
  valid_duration "$DNS_HEALTH_INTERVAL" || { warn "DNS_HEALTH_INTERVAL 无效，已恢复为 2m"; DNS_HEALTH_INTERVAL=2m; }
  if [[ ! "$WARP_KEEPALIVE_INTERVAL" =~ ^[0-9]+$ ]] ||
     (( WARP_KEEPALIVE_INTERVAL < 1 || WARP_KEEPALIVE_INTERVAL > 65535 )); then
    warn "WARP_KEEPALIVE_INTERVAL 无效，已恢复为 25"
    WARP_KEEPALIVE_INTERVAL=25
  fi
  if [[ ! "$DNS_FAILURE_THRESHOLD" =~ ^[0-9]+$ ]] ||
     (( DNS_FAILURE_THRESHOLD < 1 || DNS_FAILURE_THRESHOLD > 100 )); then
    warn "DNS_FAILURE_THRESHOLD 无效，已恢复为 3"
    DNS_FAILURE_THRESHOLD=3
  fi
  if [[ ! "$DNS_RECOVERY_THRESHOLD" =~ ^[0-9]+$ ]] ||
     (( DNS_RECOVERY_THRESHOLD < 1 || DNS_RECOVERY_THRESHOLD > 100 )); then
    warn "DNS_RECOVERY_THRESHOLD 无效，已恢复为 5"
    DNS_RECOVERY_THRESHOLD=5
  fi
  if [[ ! "$DNS_SWITCH_COOLDOWN" =~ ^[0-9]+$ ]] ||
     (( DNS_SWITCH_COOLDOWN < 0 || DNS_SWITCH_COOLDOWN > 86400 )); then
    warn "DNS_SWITCH_COOLDOWN 无效，已恢复为 600"
    DNS_SWITCH_COOLDOWN=600
  fi
}

# --- 架构映射：uname -m -> 发行资产名 ---
arch_map() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    armv6l)       echo "armv7" ;;   # 上游无 armv6，回退 armv7
    i386|i686)    echo "386"  ;;
    *)            echo "amd64" ;;
  esac
}

# --- 依赖安装：兼容 apt / yum / dnf / apk / pacman / zypper ---
ensure_deps() {
  local pkgs=("$@") miss=()
  for p in "${pkgs[@]}"; do command -v "$p" >/dev/null 2>&1 || miss+=("$p"); done
  ((${#miss[@]}==0)) && return 0

  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y "${miss[@]}" || apt-get install -y --no-install-recommends "${miss[@]}"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "${miss[@]}"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "${miss[@]}"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "${miss[@]}"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm "${miss[@]}"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install "${miss[@]}"
  else
    die "无法自动安装依赖：${miss[*]}，请手动安装后重试"
    return 1
  fi
}

b64enc(){ base64 -w 0 2>/dev/null || base64; }
urlenc(){ # 纯 bash urlencode（不依赖 python）
  local s="$1" out="" c
  for ((i=0; i<${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
      [a-zA-Z0-9._~-]) out+="$c" ;;
      ' ') out+="%20" ;;
      *) printf -v out "%s%%%02X" "$out" "'$c" ;;
    esac
  done
  printf "%s" "$out"
}
urldec(){
  local s="${1//+/ }"
  printf '%b' "${s//%/\\x}"
}
b64dec(){
  local s="$1" pad
  s="${s//-/+}"; s="${s//_/\/}"
  pad=$(( (4 - ${#s} % 4) % 4 ))
  while (( pad > 0 )); do s+="="; pad=$((pad-1)); done
  printf '%s' "$s" | base64 -d 2>/dev/null || printf '%s' "$s" | base64 --decode 2>/dev/null
}
query_get(){
  local query="$1" key="$2" pair k v
  local -a pairs
  [[ -n "$query" ]] || return 0
  IFS='&' read -r -a pairs <<< "$query"
  for pair in "${pairs[@]}"; do
    k="${pair%%=*}"
    v="${pair#*=}"
    [[ "$(urldec "$k")" == "$key" ]] || continue
    urldec "$v"
    return 0
  done
  return 0
}
split_hostport(){
  local hostport="$1"
  SBP_PARSED_HOST=""; SBP_PARSED_PORT=""
  if [[ "$hostport" =~ ^\[(.*)\]:([0-9]+)$ ]]; then
    SBP_PARSED_HOST="${BASH_REMATCH[1]}"
    SBP_PARSED_PORT="${BASH_REMATCH[2]}"
  elif [[ "$hostport" == *:* ]]; then
    SBP_PARSED_HOST="${hostport%:*}"
    SBP_PARSED_PORT="${hostport##*:}"
  else
    return 1
  fi
  [[ "$SBP_PARSED_PORT" =~ ^[0-9]+$ ]]
}
alpn_to_json(){
  printf '%s' "${1:-}" | jq -R 'split(",") | map(select(length > 0))'
}
tls_enabled_json(){
  local sni="${1:-}" insecure="${2:-false}" alpn_json="${3:-[]}" fp="${4:-}"
  jq -n \
    --arg sni "$sni" --arg fp "$fp" \
    --argjson insecure "$insecure" --argjson alpn "$alpn_json" \
    '{enabled:true}
    | if $sni != "" then .server_name = $sni else . end
    | if $insecure then .insecure = true else . end
    | if ($alpn | length) > 0 then .alpn = $alpn else . end
    | if $fp != "" then .utls = {enabled:true, fingerprint:$fp} else . end'
}

safe_source_env(){ # 安全 source，忽略不存在文件
  local f="$1"; [[ -f "$f" ]] || return 1
  set +u; # 避免未定义变量报错
  # shellcheck disable=SC1090
  source "$f"
  set -u
}

get_ip(){ # 多源获取公网IP
  local ip
  ip=$(curl -fsSL ipv4.icanhazip.com || true)
  [[ -z "$ip" ]] && ip=$(curl -fsSL ifconfig.me || true)
  [[ -z "$ip" ]] && ip=$(curl -fsSL ip.sb || true)
  echo "${ip:-127.0.0.1}"
}

is_uuid(){ [[ "$1" =~ ^[0-9a-fA-F-]{36}$ ]]; }

ensure_dirs(){ mkdir -p "$SB_DIR" "$DATA_DIR" "$CERT_DIR" "$WGCF_DIR"; }

# ===== 端口（20 个互不重复） =====
PORTS=()
gen_port() {
  while :; do
    p=$(( ( RANDOM % 55536 ) + 10000 ))
    [[ $p -le 65535 ]] || continue
    [[ " ${PORTS[*]-} " != *" $p "* ]] && { PORTS+=("$p"); echo "$p"; return; }
  done
}
rand_ports_reset(){ PORTS=(); }

PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

save_ports(){ cat > "$SB_DIR/ports.env" <<EOF
PORT_VLESSR=$PORT_VLESSR
PORT_VLESS_GRPCR=$PORT_VLESS_GRPCR
PORT_TROJANR=$PORT_TROJANR
PORT_HY2=$PORT_HY2
PORT_VMESS_WS=$PORT_VMESS_WS
PORT_HY2_OBFS=$PORT_HY2_OBFS
PORT_SS2022=$PORT_SS2022
PORT_SS=$PORT_SS
PORT_TUIC=$PORT_TUIC
PORT_ANYTLS=$PORT_ANYTLS
PORT_VLESSR_W=$PORT_VLESSR_W
PORT_VLESS_GRPCR_W=$PORT_VLESS_GRPCR_W
PORT_TROJANR_W=$PORT_TROJANR_W
PORT_HY2_W=$PORT_HY2_W
PORT_VMESS_WS_W=$PORT_VMESS_WS_W
PORT_HY2_OBFS_W=$PORT_HY2_OBFS_W
PORT_SS2022_W=$PORT_SS2022_W
PORT_SS_W=$PORT_SS_W
PORT_TUIC_W=$PORT_TUIC_W
PORT_ANYTLS_W=$PORT_ANYTLS_W
EOF
}
load_ports(){ safe_source_env "$SB_DIR/ports.env" || return 1; }

save_all_ports(){
  rand_ports_reset
  for v in PORT_VLESSR PORT_VLESS_GRPCR PORT_TROJANR PORT_HY2 PORT_VMESS_WS PORT_HY2_OBFS PORT_SS2022 PORT_SS PORT_TUIC PORT_ANYTLS \
           PORT_VLESSR_W PORT_VLESS_GRPCR_W PORT_TROJANR_W PORT_HY2_W PORT_VMESS_WS_W PORT_HY2_OBFS_W PORT_SS2022_W PORT_SS_W PORT_TUIC_W PORT_ANYTLS_W; do
    [[ -n "${!v:-}" ]] && PORTS+=("${!v}")
  done
  [[ -z "${PORT_VLESSR:-}" ]] && PORT_VLESSR=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR:-}" ]] && PORT_VLESS_GRPCR=$(gen_port)
  [[ -z "${PORT_TROJANR:-}" ]] && PORT_TROJANR=$(gen_port)
  [[ -z "${PORT_HY2:-}" ]] && PORT_HY2=$(gen_port)
  [[ -z "${PORT_VMESS_WS:-}" ]] && PORT_VMESS_WS=$(gen_port)
  [[ -z "${PORT_HY2_OBFS:-}" ]] && PORT_HY2_OBFS=$(gen_port)
  [[ -z "${PORT_SS2022:-}" ]] && PORT_SS2022=$(gen_port)
  [[ -z "${PORT_SS:-}" ]] && PORT_SS=$(gen_port)
  [[ -z "${PORT_TUIC:-}" ]] && PORT_TUIC=$(gen_port)
  [[ -z "${PORT_ANYTLS:-}" ]] && PORT_ANYTLS=$(gen_port)
  [[ -z "${PORT_VLESSR_W:-}" ]] && PORT_VLESSR_W=$(gen_port)
  [[ -z "${PORT_VLESS_GRPCR_W:-}" ]] && PORT_VLESS_GRPCR_W=$(gen_port)
  [[ -z "${PORT_TROJANR_W:-}" ]] && PORT_TROJANR_W=$(gen_port)
  [[ -z "${PORT_HY2_W:-}" ]] && PORT_HY2_W=$(gen_port)
  [[ -z "${PORT_VMESS_WS_W:-}" ]] && PORT_VMESS_WS_W=$(gen_port)
  [[ -z "${PORT_HY2_OBFS_W:-}" ]] && PORT_HY2_OBFS_W=$(gen_port) || true
  [[ -z "${PORT_SS2022_W:-}" ]] && PORT_SS2022_W=$(gen_port)
  [[ -z "${PORT_SS_W:-}" ]] && PORT_SS_W=$(gen_port)
  [[ -z "${PORT_TUIC_W:-}" ]] && PORT_TUIC_W=$(gen_port)
  [[ -z "${PORT_ANYTLS_W:-}" ]] && PORT_ANYTLS_W=$(gen_port)
  save_ports
}

# ===== env / creds / warp =====
save_env(){ cat > "$SB_DIR/env.conf" <<EOF
BIN_PATH=$BIN_PATH
SYSTEMD_SERVICE=$SYSTEMD_SERVICE
CONF_JSON=$CONF_JSON
DATA_DIR=$DATA_DIR
ROUTE_JSON=$ROUTE_JSON
ENABLE_VLESS_REALITY=$ENABLE_VLESS_REALITY
ENABLE_VLESS_GRPCR=$ENABLE_VLESS_GRPCR
ENABLE_TROJAN_REALITY=$ENABLE_TROJAN_REALITY
ENABLE_HYSTERIA2=$ENABLE_HYSTERIA2
ENABLE_VMESS_WS=$ENABLE_VMESS_WS
ENABLE_HY2_OBFS=$ENABLE_HY2_OBFS
ENABLE_SS2022=$ENABLE_SS2022
ENABLE_SS=$ENABLE_SS
ENABLE_TUIC=$ENABLE_TUIC
ENABLE_ANYTLS=$ENABLE_ANYTLS
ENABLE_WARP=$ENABLE_WARP
REALITY_SERVER=$REALITY_SERVER
REALITY_SERVER_PORT=$REALITY_SERVER_PORT
GRPC_SERVICE=$GRPC_SERVICE
VMESS_WS_PATH=$VMESS_WS_PATH
TCP_KEEP_ALIVE=$TCP_KEEP_ALIVE
TCP_KEEP_ALIVE_INTERVAL=$TCP_KEEP_ALIVE_INTERVAL
UDP_TIMEOUT=$UDP_TIMEOUT
WARP_KEEPALIVE_INTERVAL=$WARP_KEEPALIVE_INTERVAL
DNS_HEALTH_INTERVAL=$DNS_HEALTH_INTERVAL
DNS_FAILURE_THRESHOLD=$DNS_FAILURE_THRESHOLD
DNS_RECOVERY_THRESHOLD=$DNS_RECOVERY_THRESHOLD
DNS_SWITCH_COOLDOWN=$DNS_SWITCH_COOLDOWN
EOF
  # 用户输入的域名、邮箱和路径使用 shell 转义，避免 env.conf 被特殊字符破坏。
  printf 'TLS_CERT_MODE=%q\n' "$TLS_CERT_MODE" >> "$SB_DIR/env.conf"
  printf 'TLS_DOMAIN=%q\n' "$TLS_DOMAIN" >> "$SB_DIR/env.conf"
  printf 'TLS_CERT_PATH=%q\n' "$TLS_CERT_PATH" >> "$SB_DIR/env.conf"
  printf 'TLS_KEY_PATH=%q\n' "$TLS_KEY_PATH" >> "$SB_DIR/env.conf"
  printf 'TLS_ACME_EMAIL=%q\n' "$TLS_ACME_EMAIL" >> "$SB_DIR/env.conf"
  printf 'TLS_ACME_PROVIDER=%q\n' "$TLS_ACME_PROVIDER" >> "$SB_DIR/env.conf"
  printf 'TLS_ACME_DATA_DIR=%q\n' "$TLS_ACME_DATA_DIR" >> "$SB_DIR/env.conf"
  printf 'TLS_ACME_DISABLE_HTTP_CHALLENGE=%q\n' "$TLS_ACME_DISABLE_HTTP_CHALLENGE" >> "$SB_DIR/env.conf"
  printf 'TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE=%q\n' "$TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE" >> "$SB_DIR/env.conf"
}
load_env(){ safe_source_env "$SB_DIR/env.conf" || true; }

save_creds(){ cat > "$SB_DIR/creds.env" <<EOF
UUID=$UUID
HY2_PWD=$HY2_PWD
REALITY_PRIV=$REALITY_PRIV
REALITY_PUB=$REALITY_PUB
REALITY_SID=$REALITY_SID
HY2_PWD2=$HY2_PWD2
HY2_OBFS_PWD=$HY2_OBFS_PWD
SS2022_KEY=$SS2022_KEY
SS_PWD=$SS_PWD
TUIC_UUID=$TUIC_UUID
TUIC_PWD=$TUIC_PWD
ANYTLS_PWD=$ANYTLS_PWD
EOF
}
load_creds(){ safe_source_env "$SB_DIR/creds.env" || return 1; }

save_warp(){ cat > "$SB_DIR/warp.env" <<EOF
WARP_PRIVATE_KEY=$WARP_PRIVATE_KEY
WARP_PEER_PUBLIC_KEY=$WARP_PEER_PUBLIC_KEY
WARP_ENDPOINT_HOST=$WARP_ENDPOINT_HOST
WARP_ENDPOINT_PORT=$WARP_ENDPOINT_PORT
WARP_ADDRESS_V4=$WARP_ADDRESS_V4
WARP_ADDRESS_V6=$WARP_ADDRESS_V6
WARP_RESERVED_1=$WARP_RESERVED_1
WARP_RESERVED_2=$WARP_RESERVED_2
WARP_RESERVED_3=$WARP_RESERVED_3
EOF
}
load_warp(){ safe_source_env "$SB_DIR/warp.env" || return 1; }

# ===== 自定义路由 =====
empty_route_json(){ printf '%s\n' '{"rules":[],"rule_set":[],"outbounds":[],"default_outbound":"direct"}'; }

default_ipv4_address(){
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

default_ipv6_address(){
  ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
}

valid_route_tag(){
  [[ "${1:-}" =~ ^[A-Za-z0-9._@!-]+$ ]]
}

ensure_route_file(){
  ensure_dirs
  if [[ ! -s "$ROUTE_JSON" ]]; then
    empty_route_json > "$ROUTE_JSON"
    return 0
  fi
  if ! jq -e 'type == "object"' "$ROUTE_JSON" >/dev/null 2>&1; then
    local bad="${ROUTE_JSON}.bad.$(date +%Y%m%d-%H%M%S)"
    mv "$ROUTE_JSON" "$bad"
    warn "自定义路由文件格式无效，已备份到：$bad"
    empty_route_json > "$ROUTE_JSON"
  fi
}

load_route_json(){
  if [[ -s "$ROUTE_JSON" ]] && jq -e 'type == "object"' "$ROUTE_JSON" >/dev/null 2>&1; then
    jq -c '.rules = (.rules // []) | .rule_set = (.rule_set // []) | .outbounds = (.outbounds // []) | .default_outbound = (.default_outbound // "direct")' "$ROUTE_JSON"
  else
    empty_route_json
  fi
}

normalize_route_file(){
  jq -ces '
    def nonempty_string:
      if type == "string" then length > 0 and (test("[[:cntrl:]]") | not) else false end;
    def valid_tag:
      if type == "string" then test("^[A-Za-z0-9._@!-]+$") else false end;
    def string_list:
      if type == "array" then all(.[]; nonempty_string) else false end;
    def normalize_match_rule:
      ["domain", "domain_suffix", "domain_keyword", "domain_regex", "rule_set"] as $match_keys
      | if type != "object" then error("每个匹配分支必须是对象") else . end
      | if has("name") and (.name | type) != "string" then error("规则名称必须是字符串")
        else . end
      | if .type == "logical" then
          if ((keys - ["name", "type", "mode", "rules"]) | length) > 0 then
            error("逻辑分支含有不支持的字段")
          elif .mode != "or" then error("整理规则只支持 or 逻辑")
          elif (.rules | type) != "array" or (.rules | length) < 2 then error("逻辑规则至少需要两个匹配分支")
          else . end
          | .rules |= map(normalize_match_rule)
        else
          if ((keys - ($match_keys + ["name"])) | length) > 0 then error("匹配分支含有不支持的字段") else . end
          | . as $rule
          | if all($match_keys[]; . as $key | ($rule | has($key) | not) or ($rule[$key] | string_list)) then .
            else error("匹配项必须是非空字符串组成的数组") end
          | if ([$match_keys[] as $key | ($rule[$key] // []) | length] | add) == 0 then
              error("分流规则至少需要一个匹配项")
            else . end
        end;
    def normalize_target:
      if .action == "reject" then
        if has("outbound") then error("block 规则不能同时指定出口") else . end
      elif has("action") and .action != "route" then error("只支持 route 或 reject 动作")
      elif (.outbound | valid_tag | not) then error("路由规则缺少有效出口")
      else . end;
    ["direct", "direct-ipv4", "direct-ipv6", "warp"] as $builtins
    | if length != 1 or (.[0] | type) != "object" then
        error("分流文件必须包含一个 JSON 对象")
      else .[0] end
    | if ((keys - ["format", "version", "rules", "rule_set", "outbounds", "default_outbound"]) | length) > 0 then
        error("只支持本脚本导出的分流文件或 routes.json")
      elif (has("format") or has("version")) and (.format != "sing-box-plus-routes" or .version != 1) then
        error("不支持的分流文件格式或版本")
      elif (.rules | type) != "array" then error("rules 必须是数组")
      else . end
    | .rule_set = (if has("rule_set") then .rule_set else [] end)
    | .outbounds = (if has("outbounds") then .outbounds else [] end)
    | .default_outbound = (if has("default_outbound") then .default_outbound else "direct" end)
    | if (.rule_set | type) != "array" or (.outbounds | type) != "array" then
        error("rule_set 和 outbounds 必须是数组")
      elif (.default_outbound | valid_tag | not) then error("默认出口 tag 无效")
      else . end
    | .rules |= map(
        if type != "object" then error("每条分流规则必须是对象") else . end
        | . as $rule
        | del(.action, .outbound) | normalize_match_rule
        | $rule | normalize_target)
    | .outbounds |= map(
        if type != "object" then error("每个远程出口必须是对象") else . end
        | .tag as $tag
        | if (.tag | valid_tag | not) or (.type | nonempty_string | not) then
            error("远程出口缺少有效的 tag 或 type")
          elif ($builtins | index($tag)) != null then error("远程出口 tag 与内置出口冲突")
          else . end)
    | .rule_set |= map(
        if type != "object" then error("每个规则集必须是对象") else . end
        | if (.tag | valid_tag | not) then error("规则集 tag 无效")
          elif .type == "remote" then
            if (.url | nonempty_string) then . else error("远程规则集缺少 URL") end
          elif .type == "local" then
            if (.path | nonempty_string) then . else error("本地规则集缺少路径") end
          elif .type == "inline" then
            if (.rules | type) == "array" then . else error("内联规则集缺少 rules 数组") end
          else error("不支持的规则集类型") end)
    | if ([.outbounds[].tag] | length != (unique | length)) then error("远程出口 tag 重复")
      elif ([.rule_set[].tag] | length != (unique | length)) then error("规则集 tag 重复")
      else del(.format, .version) end
  ' "$1"
}

validate_route_references(){
  jq -e '
    (["direct", "direct-ipv4", "direct-ipv6", "warp"] + [.outbounds[].tag]) as $outbounds
    | [.rule_set[].tag] as $rule_sets
    | [.rules[] | recurse(if .type == "logical" then .rules[] else empty end)] as $match_rules
    | if all(.rules[] | select(.action != "reject"); .outbound as $tag | ($outbounds | index($tag)) != null)
        and (.default_outbound as $tag | ($outbounds | index($tag)) != null) then .
      else error("分流配置引用了不存在的出口") end
    | if all($match_rules[]; all(.rule_set[]?; . as $tag | ($rule_sets | index($tag)) != null)) then .
      else error("分流配置引用了不存在的规则集") end
    | if all(.rule_set[] | select(has("download_detour")); .download_detour as $tag | ($outbounds | index($tag)) != null) then .
      else error("规则集下载引用了不存在的出口") end
  ' "$1" >/dev/null
}

merge_route_files(){
  jq -cen --slurpfile current "$1" --slurpfile incoming "$2" '
    def merge_tags($old; $new; $kind):
      reduce $new[] as $item ($old;
        ([.[] | select(.tag == $item.tag)] | first) as $existing
        | if $existing == null then . + [$item]
          elif $existing == $item then .
          else error($kind + "存在同名配置冲突：" + $item.tag) end);
    $current[0] as $old | $incoming[0] as $new
    | $old + {
        rules: (reduce $new.rules[] as $rule ($old.rules;
          if index($rule) == null then . + [$rule] else . end)),
        rule_set: merge_tags($old.rule_set; $new.rule_set; "规则集"),
        outbounds: merge_tags($old.outbounds; $new.outbounds; "远程出口")
      }
  '
}

consolidate_route_rules(){
  local source_file="$1" target="$2" mode="$3"
  # Keep original predicates as OR branches; flattening domain and rule-set fields can change their meaning.
  jq -c --arg target "$target" --arg mode "$mode" '
    def target_key:
      if .action == "reject" then "reject:" else "route:" + .outbound end;
    def target_fields($key):
      if $key == "reject:" then {action:"reject"}
      else {outbound:($key | ltrimstr("route:"))} end;
    def branches:
      if .type == "logical" and .mode == "or" and ((.name // "") == "") then .rules[]
      else del(.action, .outbound) end;
    def combined($items; $key):
      if ($items | length) == 1 then $items[0]
      else
        (reduce ($items[] | branches) as $branch ([];
          if index($branch) == null then . + [$branch] else . end)) as $branches
        | if ($branches | length) == 1 then $branches[0] + target_fields($key)
          else {type:"logical", mode:"or", rules:$branches} + target_fields($key) end
      end;
    def flush($state; $key):
      if ($state.pending | length) == 0 then $state
      else $state | .output += [combined(.pending; $key)] | .pending = [] end;
    . as $document
    | if $mode == "adjacent" then
        (reduce .rules[] as $rule ({output:[], pending:[]};
          if ($rule | target_key) == $target then .pending += [$rule]
          else flush(.; $target) | .output += [$rule] end)
          | flush(.; $target)) as $state
        | $document | .rules = $state.output
      elif $mode == "all" then
        [.rules[] | select((. | target_key) == $target)] as $selected
        | combined($selected; $target) as $merged
        | (reduce .rules[] as $rule ({output:[], inserted:false};
            if ($rule | target_key) == $target then
              if .inserted then . else .output += [$merged] | .inserted = true end
            else .output += [$rule] end)) as $state
        | $document | .rules = $state.output
      else error("不支持的整理方式") end
  ' "$source_file"
}

parse_route_match_json(){
  local raw="$1" token key value code tag url json
  json='{"domain":[],"domain_suffix":[],"domain_keyword":[],"domain_regex":[],"rule_set":[],"rule_set_defs":[]}'
  raw="${raw//$'\r'/ }"
  raw="${raw//$'\n'/ }"
  raw="${raw//,/ }"
  for token in $raw; do
    [[ -n "$token" ]] || continue
    key=""
    value="$token"
    case "$token" in
      geosite:*|site:*) key="geosite"; value="${token#*:}" ;;
      domain:*) key="domain"; value="${token#*:}" ;;
      suffix:*) key="suffix"; value="${token#*:}" ;;
      keyword:*) key="keyword"; value="${token#*:}" ;;
      regex:*) key="regex"; value="${token#*:}" ;;
      *.*) key="suffix" ;;
      *) key="geosite" ;;
    esac
    [[ -n "$value" ]] || continue
    case "$key" in
      geosite)
        code="$value"
        if ! valid_route_tag "$code"; then
          warn "跳过无效 geosite：$code"
          continue
        fi
        tag="geosite-${code}"
        url="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/${tag}.srs"
        json=$(printf '%s' "$json" | jq -c \
          --arg tag "$tag" --arg url "$url" '
          .rule_set += [$tag]
          | .rule_set = (.rule_set | unique)
          | .rule_set_defs += [{type:"remote", tag:$tag, format:"binary", url:$url, download_detour:"direct", update_interval:"1d"}]
          | .rule_set_defs = (.rule_set_defs | unique_by(.tag))')
        ;;
      domain)
        json=$(printf '%s' "$json" | jq -c --arg v "$value" '.domain += [$v] | .domain = (.domain | unique)')
        ;;
      suffix)
        json=$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_suffix += [$v] | .domain_suffix = (.domain_suffix | unique)')
        ;;
      keyword)
        json=$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_keyword += [$v] | .domain_keyword = (.domain_keyword | unique)')
        ;;
      regex)
        json=$(printf '%s' "$json" | jq -c --arg v "$value" '.domain_regex += [$v] | .domain_regex = (.domain_regex | unique)')
        ;;
    esac
  done
  printf '%s' "$json" | jq -c '
    with_entries(select(
      (.key == "rule_set_defs") or
      ((.value | type) != "array") or
      ((.value | length) > 0)
    ))'
}

share_link_to_outbound(){
  local link="$1" tag="$2" scheme rest body query userinfo hostport server port
  local sni fp insecure allow alpn alpn_json tls_json transport_type
  link="${link//$'\r'/}"
  link="${link//$'\n'/}"
  scheme="${link%%://*}"
  [[ "$scheme" != "$link" ]] || return 1
  rest="${link#*://}"
  body="${rest%%\#*}"
  query=""
  if [[ "$body" == *"?"* ]]; then
    query="${body#*\?}"
    body="${body%%\?*}"
  fi

  case "$scheme" in
    vless|trojan|hy2|hysteria2|tuic|anytls)
      [[ "$body" == *"@"* ]] || return 1
      userinfo="${body%@*}"
      hostport="${body##*@}"
      split_hostport "$hostport" || return 1
      server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
      ;;
  esac

  case "$scheme" in
    vless)
      local uuid flow security pbk sid grpc_service ws_path ws_host
      uuid="$(urldec "$userinfo")"
      flow="$(query_get "$query" flow)"
      security="$(query_get "$query" security)"
      sni="$(query_get "$query" sni)"
      fp="$(query_get "$query" fp)"
      pbk="$(query_get "$query" pbk)"
      sid="$(query_get "$query" sid)"
      transport_type="$(query_get "$query" type)"
      grpc_service="$(query_get "$query" serviceName)"
      ws_path="$(query_get "$query" path)"
      ws_host="$(query_get "$query" host)"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg uuid "$uuid" \
        --arg flow "$flow" --arg security "$security" --arg sni "$sni" --arg fp "${fp:-chrome}" \
        --arg pbk "$pbk" --arg sid "$sid" --arg transport "$transport_type" \
        --arg grpc "$grpc_service" --arg path "$ws_path" --arg host "$ws_host" '
        {type:"vless", tag:$tag, server:$server, server_port:$port, uuid:$uuid, domain_resolver:"dns-doh-primary"}
        | if $flow != "" then .flow = $flow else . end
        | if $security == "reality" then
            .tls = {enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp}, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
          elif $security == "tls" then
            .tls = ({enabled:true} | if $sni != "" then .server_name = $sni else . end | if $fp != "" then .utls = {enabled:true, fingerprint:$fp} else . end)
          else . end
        | if $transport == "grpc" then
            .transport = {type:"grpc", service_name:$grpc}
          elif $transport == "ws" then
            .transport = ({type:"ws", path:$path} | if $host != "" then .headers = {Host:$host} else . end)
          else . end'
      ;;
    trojan)
      local password security pbk sid grpc_service ws_path ws_host
      password="$(urldec "$userinfo")"
      security="$(query_get "$query" security)"
      sni="$(query_get "$query" sni)"
      fp="$(query_get "$query" fp)"
      pbk="$(query_get "$query" pbk)"
      sid="$(query_get "$query" sid)"
      transport_type="$(query_get "$query" type)"
      grpc_service="$(query_get "$query" serviceName)"
      ws_path="$(query_get "$query" path)"
      ws_host="$(query_get "$query" host)"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" \
        --arg security "$security" --arg sni "$sni" --arg fp "${fp:-chrome}" \
        --arg pbk "$pbk" --arg sid "$sid" --arg transport "$transport_type" \
        --arg grpc "$grpc_service" --arg path "$ws_path" --arg host "$ws_host" '
        {type:"trojan", tag:$tag, server:$server, server_port:$port, password:$password, domain_resolver:"dns-doh-primary"}
        | if $security == "reality" then
            .tls = {enabled:true, server_name:$sni, utls:{enabled:true, fingerprint:$fp}, reality:{enabled:true, public_key:$pbk, short_id:$sid}}
          elif $security == "tls" then
            .tls = ({enabled:true} | if $sni != "" then .server_name = $sni else . end | if $fp != "" then .utls = {enabled:true, fingerprint:$fp} else . end)
          else . end
        | if $transport == "grpc" then
            .transport = {type:"grpc", service_name:$grpc}
          elif $transport == "ws" then
            .transport = ({type:"ws", path:$path} | if $host != "" then .headers = {Host:$host} else . end)
          else . end'
      ;;
    hy2|hysteria2)
      local password obfs obfs_pwd
      password="$(urldec "$userinfo")"
      sni="$(query_get "$query" sni)"
      insecure="$(query_get "$query" insecure)"
      allow="$(query_get "$query" allowInsecure)"
      alpn="$(query_get "$query" alpn)"
      obfs="$(query_get "$query" obfs)"
      obfs_pwd="$(query_get "$query" obfs-password)"
      [[ "$insecure" == "1" || "$allow" == "1" ]] && insecure=true || insecure=false
      alpn_json="$(alpn_to_json "$alpn")"
      tls_json="$(tls_enabled_json "$sni" "$insecure" "$alpn_json" "")"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" --arg password "$password" \
        --arg obfs "$obfs" --arg obfs_pwd "$obfs_pwd" --argjson tls "$tls_json" '
        {type:"hysteria2", tag:$tag, server:$server, server_port:$port, password:$password, tls:$tls, domain_resolver:"dns-doh-primary"}
        | if $obfs == "salamander" and $obfs_pwd != "" then .obfs = {type:"salamander", password:$obfs_pwd} else . end'
      ;;
    vmess)
      local payload decoded
      payload="${rest%%\#*}"
      decoded="$(b64dec "$payload")" || return 1
      printf '%s' "$decoded" | jq -c --arg tag "$tag" '
        . as $v
        | {type:"vmess", tag:$tag, server:$v.add, server_port:($v.port | tonumber), uuid:$v.id,
           security:($v.scy // "auto"), alter_id:(($v.aid // "0") | tonumber), domain_resolver:"dns-doh-primary"}
        | if ($v.net // "") == "ws" then
            .transport = ({type:"ws", path:($v.path // "")} | if (($v.host // "") != "") then .headers = {Host:$v.host} else . end)
          else . end
        | if ($v.tls // "") == "tls" then
            .tls = ({enabled:true} | if (($v.sni // $v.host // "") != "") then .server_name = ($v.sni // $v.host) else . end)
          else . end'
      ;;
    ss)
      local ss_body decoded methodpass method password
      ss_body="$body"
      if [[ "$ss_body" == *"@"* ]]; then
        userinfo="${ss_body%@*}"
        hostport="${ss_body##*@}"
        methodpass="$(b64dec "$userinfo" 2>/dev/null || printf '%s' "$userinfo")"
      else
        decoded="$(b64dec "$ss_body")" || return 1
        methodpass="${decoded%@*}"
        hostport="${decoded##*@}"
      fi
      split_hostport "$hostport" || return 1
      server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"
      [[ "$methodpass" == *:* ]] || return 1
      method="${methodpass%%:*}"
      password="${methodpass#*:}"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" \
        --arg method "$method" --arg password "$password" \
        '{type:"shadowsocks", tag:$tag, server:$server, server_port:$port, method:$method, password:$password, domain_resolver:"dns-doh-primary"}'
      ;;
    tuic)
      local uuid password cc
      userinfo="$(urldec "$userinfo")"
      [[ "$userinfo" == *:* ]] || return 1
      uuid="${userinfo%%:*}"
      password="${userinfo#*:}"
      cc="$(query_get "$query" congestion_control)"
      sni="$(query_get "$query" sni)"
      insecure="$(query_get "$query" insecure)"
      allow="$(query_get "$query" allowInsecure)"
      alpn="$(query_get "$query" alpn)"
      fp="$(query_get "$query" fp)"
      [[ "$insecure" == "1" || "$allow" == "1" ]] && insecure=true || insecure=false
      alpn_json="$(alpn_to_json "$alpn")"
      tls_json="$(tls_enabled_json "$sni" "$insecure" "$alpn_json" "$fp")"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" \
        --arg uuid "$uuid" --arg password "$password" --arg cc "${cc:-bbr}" --argjson tls "$tls_json" \
        '{type:"tuic", tag:$tag, server:$server, server_port:$port, uuid:$uuid, password:$password,
          congestion_control:$cc, tls:$tls, domain_resolver:"dns-doh-primary"}'
      ;;
    anytls)
      local password
      password="$(urldec "$userinfo")"
      sni="$(query_get "$query" sni)"
      insecure="$(query_get "$query" insecure)"
      allow="$(query_get "$query" allowInsecure)"
      alpn="$(query_get "$query" alpn)"
      fp="$(query_get "$query" fp)"
      [[ "$insecure" == "1" || "$allow" == "1" ]] && insecure=true || insecure=false
      alpn_json="$(alpn_to_json "$alpn")"
      tls_json="$(tls_enabled_json "$sni" "$insecure" "$alpn_json" "$fp")"
      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" \
        --arg password "$password" --argjson tls "$tls_json" \
        '{type:"anytls", tag:$tag, server:$server, server_port:$port, password:$password,
          tls:$tls, domain_resolver:"dns-doh-primary"}'
      ;;
    socks|socks5|socks5h|socks4|socks4a)
      local username="" password="" ver="5"
      [[ "$scheme" == "socks4" || "$scheme" == "socks4a" ]] && ver="4"
      local s_body="$body"
      if [[ "$s_body" != *"@"* && "$s_body" != *:* ]]; then
        local dec
        dec="$(b64dec "$s_body" 2>/dev/null || true)"
        [[ -n "$dec" ]] && s_body="${dec%/}"
      fi

      if [[ "$s_body" == *"@"* ]]; then
        userinfo="${s_body%@*}"
        hostport="${s_body##*@}"
        local dec_ui
        dec_ui="$(b64dec "$userinfo" 2>/dev/null || true)"
        if [[ -n "$dec_ui" && "$dec_ui" == *:* ]]; then
          userinfo="$dec_ui"
        fi
        if [[ "$userinfo" == *:* ]]; then
          username="$(urldec "${userinfo%%:*}")"
          password="$(urldec "${userinfo#*:}")"
        else
          username="$(urldec "$userinfo")"
          password=""
        fi
      else
        hostport="$s_body"
      fi

      split_hostport "$hostport" || return 1
      server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"

      local q_user q_pass q_ver
      q_user="$(query_get "$query" user)"
      [[ -z "$q_user" ]] && q_user="$(query_get "$query" username)"
      q_pass="$(query_get "$query" pass)"
      [[ -z "$q_pass" ]] && q_pass="$(query_get "$query" password)"
      q_ver="$(query_get "$query" version)"
      [[ -n "$q_user" ]] && username="$q_user"
      [[ -n "$q_pass" ]] && password="$q_pass"
      [[ -n "$q_ver" ]] && ver="$q_ver"

      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" \
        --arg user "$username" --arg pass "$password" --arg ver "$ver" '
        {type:"socks", tag:$tag, server:$server, server_port:$port, version:$ver, domain_resolver:"dns-doh-primary"}
        | if $user != "" then .username = $user else . end
        | if $pass != "" then .password = $pass else . end'
      ;;
    http|https)
      local username="" password="" is_https=false
      [[ "$scheme" == "https" ]] && is_https=true
      local h_body="$body"
      if [[ "$h_body" != *"@"* && "$h_body" != *:* ]]; then
        local dec
        dec="$(b64dec "$h_body" 2>/dev/null || true)"
        [[ -n "$dec" ]] && h_body="${dec%/}"
      fi

      if [[ "$h_body" == *"@"* ]]; then
        userinfo="${h_body%@*}"
        hostport="${h_body##*@}"
        local dec_ui
        dec_ui="$(b64dec "$userinfo" 2>/dev/null || true)"
        if [[ -n "$dec_ui" && "$dec_ui" == *:* ]]; then
          userinfo="$dec_ui"
        fi
        if [[ "$userinfo" == *:* ]]; then
          username="$(urldec "${userinfo%%:*}")"
          password="$(urldec "${userinfo#*:}")"
        else
          username="$(urldec "$userinfo")"
          password=""
        fi
      else
        hostport="$h_body"
      fi

      split_hostport "$hostport" || return 1
      server="$SBP_PARSED_HOST"; port="$SBP_PARSED_PORT"

      local q_user q_pass q_tls
      q_user="$(query_get "$query" user)"
      [[ -z "$q_user" ]] && q_user="$(query_get "$query" username)"
      q_pass="$(query_get "$query" pass)"
      [[ -z "$q_pass" ]] && q_pass="$(query_get "$query" password)"
      q_tls="$(query_get "$query" tls)"
      [[ -n "$q_user" ]] && username="$q_user"
      [[ -n "$q_pass" ]] && password="$q_pass"
      [[ "$q_tls" == "1" || "$q_tls" == "true" ]] && is_https=true

      sni="$(query_get "$query" sni)"
      [[ -z "$sni" ]] && sni="$(query_get "$query" host)"
      [[ -z "$sni" && "$is_https" == true ]] && sni="$server"
      insecure="$(query_get "$query" insecure)"
      allow="$(query_get "$query" allowInsecure)"
      [[ "$insecure" == "1" || "$allow" == "1" ]] && insecure=true || insecure=false

      jq -n -c \
        --arg tag "$tag" --arg server "$server" --argjson port "$port" \
        --arg user "$username" --arg pass "$password" \
        --argjson is_https "$is_https" --arg sni "$sni" --argjson insecure "$insecure" '
        {type:"http", tag:$tag, server:$server, server_port:$port, domain_resolver:"dns-doh-primary"}
        | if $user != "" then .username = $user else . end
        | if $pass != "" then .password = $pass else . end
        | if $is_https then
            .tls = ({enabled:true}
                    | if $sni != "" then .server_name = $sni else . end
                    | if $insecure then .insecure = true else . end)
          else . end'
      ;;
    tg)
      local tg_server tg_port tg_user tg_pass
      tg_server="$(query_get "$query" server)"
      tg_port="$(query_get "$query" port)"
      tg_user="$(query_get "$query" user)"
      tg_pass="$(query_get "$query" pass)"
      [[ -z "$tg_server" || -z "$tg_port" ]] && return 1
      [[ "$tg_port" =~ ^[0-9]+$ ]] || return 1

      if [[ "$body" == "http-proxy" || "$body" == "http" ]]; then
        jq -n -c \
          --arg tag "$tag" --arg server "$tg_server" --argjson port "$tg_port" \
          --arg user "$tg_user" --arg pass "$tg_pass" '
          {type:"http", tag:$tag, server:$server, server_port:$port, domain_resolver:"dns-doh-primary"}
          | if $user != "" then .username = $user else . end
          | if $pass != "" then .password = $pass else . end'
      else
        jq -n -c \
          --arg tag "$tag" --arg server "$tg_server" --argjson port "$tg_port" \
          --arg user "$tg_user" --arg pass "$tg_pass" '
          {type:"socks", tag:$tag, server:$server, server_port:$port, version:"5", domain_resolver:"dns-doh-primary"}
          | if $user != "" then .username = $user else . end
          | if $pass != "" then .password = $pass else . end'
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

# 生成 8 字节十六进制（16 个 hex 字符）
rand_hex8(){
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 8 | tr -d "\n"
  else
    # 兜底：没有 openssl 时用 hexdump
    hexdump -v -n 8 -e '1/1 "%02x"' /dev/urandom
  fi
}
rand_b64_32(){ openssl rand -base64 32 | tr -d "\n"; }

gen_uuid(){
  local u=""
  if [[ -x "$BIN_PATH" ]]; then u=$("$BIN_PATH" generate uuid 2>/dev/null | head -n1); fi
  if [[ -z "$u" ]] && command -v uuidgen >/dev/null 2>&1; then u=$(uuidgen | head -n1); fi
  if [[ -z "$u" ]]; then u=$(cat /proc/sys/kernel/random/uuid | head -n1); fi
  printf '%s' "$u" | tr -d '\r\n'
}
gen_reality(){ "$BIN_PATH" generate reality-keypair; }

valid_tls_domain(){
  local domain="${1%.}"
  (( ${#domain} <= 253 )) || return 1
  [[ "$domain" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$ ]]
}

tls_ca_bundle(){
  local bundle
  for bundle in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    [[ -s "$bundle" ]] && { printf '%s' "$bundle"; return 0; }
  done
  return 1
}

# openssl x509 -checkhost 无论主机名是否匹配都以 0 退出，判定结果只写到 stdout，
# 因此必须解析输出而不能依赖退出码。
cert_matches_host(){
  local crt=$1 host=$2 out
  [[ -s "$crt" && -n "$host" ]] || return 1
  out="$(openssl x509 -in "$crt" -noout -checkhost "$host" 2>/dev/null)" || return 1
  [[ "$out" == *"does match certificate"* && "$out" != *"NOT match"* ]]
}

validate_manual_certificate(){
  local quiet="${1:-false}" cert_pub key_pub bundle
  local fail_prefix="手动证书校验失败："

  if ! valid_tls_domain "$TLS_DOMAIN"; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}域名格式无效"
    return 1
  fi
  if [[ "$TLS_CERT_PATH" != /* || ! -r "$TLS_CERT_PATH" || ! -s "$TLS_CERT_PATH" ]]; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}证书路径必须是可读的绝对路径：$TLS_CERT_PATH"
    return 1
  fi
  if [[ "$TLS_KEY_PATH" != /* || ! -r "$TLS_KEY_PATH" || ! -s "$TLS_KEY_PATH" ]]; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}私钥路径必须是可读的绝对路径：$TLS_KEY_PATH"
    return 1
  fi
  if ! openssl x509 -in "$TLS_CERT_PATH" -noout >/dev/null 2>&1; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}证书不是有效的 PEM X.509 文件"
    return 1
  fi
  if ! openssl pkey -in "$TLS_KEY_PATH" -noout >/dev/null 2>&1; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}私钥不是可直接读取的 PEM 文件（不支持带密码私钥）"
    return 1
  fi
  if ! openssl x509 -in "$TLS_CERT_PATH" -noout -checkend 0 >/dev/null 2>&1; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}证书已经过期或尚未生效"
    return 1
  fi
  if ! cert_matches_host "$TLS_CERT_PATH" "$TLS_DOMAIN"; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}证书不包含域名 $TLS_DOMAIN"
    return 1
  fi

  cert_pub="$(openssl x509 -in "$TLS_CERT_PATH" -pubkey -noout 2>/dev/null \
    | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
  key_pub="$(openssl pkey -in "$TLS_KEY_PATH" -pubout -outform DER 2>/dev/null \
    | openssl dgst -sha256 2>/dev/null)"
  if [[ -z "$cert_pub" || "$cert_pub" != "$key_pub" ]]; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}证书与私钥不匹配"
    return 1
  fi

  bundle="$(tls_ca_bundle || true)"
  if [[ -z "$bundle" ]] || ! openssl verify -purpose sslserver -CAfile "$bundle" \
      -untrusted "$TLS_CERT_PATH" "$TLS_CERT_PATH" >/dev/null 2>&1; then
    [[ "$quiet" == true ]] || warn "${fail_prefix}无法验证到系统信任的公开 CA，请提供包含中间证书的 fullchain"
    return 1
  fi
  return 0
}

tcp_port_is_listening(){
  local port="$1"
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
}

tls_domain_points_to_server(){
  local domain="$1" public_ip
  public_ip="$(get_ip)"
  [[ "$public_ip" != "127.0.0.1" ]] || return 1
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | grep -Fqx "$public_ip"
}

configure_tls_certificate(){
  local choice default_choice domain cert_path key_path email
  ensure_dirs
  load_env || true
  case "$TLS_CERT_MODE" in
    manual) default_choice=2 ;;
    acme) default_choice=3 ;;
    *) default_choice=1 ;;
  esac

  echo
  echo -e "${C_CYAN}${C_BOLD}TLS 证书配置${C_RESET}（用于 Hysteria2 / TUIC / AnyTLS）"
  echo "  1) 自签证书（默认；导入链接仍强制证书校验）"
  echo "  2) 使用已上传的公开有效证书"
  echo "  3) 使用 ACME 自动申请和续期"
  read -rp "选择 [${default_choice}]: " choice || return 1
  choice="${choice:-$default_choice}"

  case "$choice" in
    1)
      TLS_CERT_MODE=self_signed
      TLS_DOMAIN=""
      TLS_CERT_PATH="$CERT_DIR/fullchain.pem"
      TLS_KEY_PATH="$CERT_DIR/key.pem"
      TLS_ACME_EMAIL=""
      ;;
    2)
      read -rp "证书域名（例如 vpn.example.com）: " domain || return 1
      domain="${domain%.}"; domain="${domain,,}"
      read -erp "fullchain.pem 绝对路径: " cert_path || return 1
      read -erp "私钥绝对路径: " key_path || return 1
      TLS_CERT_MODE=manual
      TLS_DOMAIN="$domain"
      TLS_CERT_PATH="$cert_path"
      TLS_KEY_PATH="$key_path"
      validate_manual_certificate || return 1
      if ! tls_domain_points_to_server "$domain"; then
        warn "未检测到 $domain 的 IPv4 A 记录指向本机公网 IPv4，生成的域名节点可能无法连接。"
        read -rp "确认 DNS 已正确配置并继续？[y/N]: " choice || return 1
        [[ "$choice" =~ ^[yY]$ ]] || return 1
      fi
      ;;
    3)
      read -rp "申请证书的域名（需已解析到本机，且关闭 CDN 代理）: " domain || return 1
      domain="${domain%.}"; domain="${domain,,}"
      valid_tls_domain "$domain" || { warn "域名格式无效：$domain"; return 1; }
      read -rp "ACME 联系邮箱（可留空）: " email || return 1
      if [[ -n "$email" && ! "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
        warn "邮箱格式无效"
        return 1
      fi
      if ! tls_domain_points_to_server "$domain"; then
        warn "未检测到 $domain 的 IPv4 A 记录指向本机公网 IPv4，ACME 申请或节点连接可能失败。"
        read -rp "确认 DNS 已正确配置并继续？[y/N]: " choice || return 1
        [[ "$choice" =~ ^[yY]$ ]] || return 1
      fi

      # 优先只使用 HTTP-01；80 被占用时再回退到 TLS-ALPN-01，避免挑战端口冲突。
      if ! tcp_port_is_listening 80; then
        TLS_ACME_DISABLE_HTTP_CHALLENGE=false
        TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE=true
      elif ! tcp_port_is_listening 443; then
        TLS_ACME_DISABLE_HTTP_CHALLENGE=true
        TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE=false
      else
        warn "80 和 443 TCP 端口均被占用，内置 ACME 无法启动验证监听器"
        return 1
      fi
      TLS_CERT_MODE=acme
      TLS_DOMAIN="$domain"
      TLS_CERT_PATH=""
      TLS_KEY_PATH=""
      TLS_ACME_EMAIL="$email"
      TLS_ACME_PROVIDER=letsencrypt
      TLS_ACME_DATA_DIR="$CERT_DIR/acme"
      ;;
    *)
      warn "无效的证书模式"
      return 1
      ;;
  esac

  return 0
}

mk_cert(){
  local crt="$TLS_CERT_PATH" key="$TLS_KEY_PATH" tmp_dir cert_pub key_pub
  local cert_name="$REALITY_SERVER"

  if [[ -s "$crt" && -s "$key" ]] \
      && cert_matches_host "$crt" "$cert_name" \
      && openssl pkey -in "$key" -noout >/dev/null 2>&1; then
    cert_pub="$(openssl x509 -in "$crt" -pubkey -noout 2>/dev/null \
      | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256 2>/dev/null)"
    key_pub="$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null \
      | openssl dgst -sha256 2>/dev/null)"
    if [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]]; then
      chmod 600 "$key" 2>/dev/null || true
      return 0
    fi
  fi

  tmp_dir="$(mktemp -d "$CERT_DIR/.self-signed.XXXXXX")" || return 1
  if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout "$tmp_dir/key.pem" -out "$tmp_dir/fullchain.pem" -subj "/CN=$cert_name" \
      -addext "subjectAltName=DNS:$cert_name" >/dev/null 2>&1 \
      || ! cert_matches_host "$tmp_dir/fullchain.pem" "$cert_name" \
      || ! openssl pkey -in "$tmp_dir/key.pem" -noout >/dev/null 2>&1; then
    rm -rf "$tmp_dir"
    warn "生成自签证书失败"
    return 1
  fi

  chmod 600 "$tmp_dir/key.pem"
  chmod 644 "$tmp_dir/fullchain.pem"
  if ! mv -f "$tmp_dir/key.pem" "$key" || ! mv -f "$tmp_dir/fullchain.pem" "$crt"; then
    rm -rf "$tmp_dir"
    warn "写入自签证书失败：$crt / $key"
    return 1
  fi
  rmdir "$tmp_dir" 2>/dev/null || true
}

prepare_tls_certificate(){
  case "$TLS_CERT_MODE" in
    self_signed)
      TLS_CERT_PATH="$CERT_DIR/fullchain.pem"
      TLS_KEY_PATH="$CERT_DIR/key.pem"
      mk_cert
      ;;
    manual)
      validate_manual_certificate || return 1
      ;;
    acme)
      valid_tls_domain "$TLS_DOMAIN" || { warn "ACME 域名无效：$TLS_DOMAIN"; return 1; }
      mkdir -p "$TLS_ACME_DATA_DIR"
      chmod 700 "$TLS_ACME_DATA_DIR" 2>/dev/null || true
      ;;
    *)
      warn "未知 TLS 证书模式：$TLS_CERT_MODE"
      return 1
      ;;
  esac
}

# 仅自签模式的证书由脚本托管；手动 / ACME 证书由用户或 CA 签发，重签无意义
managed_cert_sni_mismatch(){
  [[ "${TLS_CERT_MODE:-self_signed}" == "self_signed" ]] || return 1
  [[ -n "${REALITY_SERVER:-}" ]] || return 1
  local crt="${CERT_DIR}/fullchain.pem"
  # 尚未部署过证书时不算不匹配，避免全新机器上误报
  [[ -s "$crt" ]] || return 1
  ! cert_matches_host "$crt" "$REALITY_SERVER"
}

warn_if_cert_sni_mismatch(){
  managed_cert_sni_mismatch || return 0
  warn "托管自签证书与当前 Reality SNI (${REALITY_SERVER}) 不匹配，证书仍是旧域名。"
  warn "运行 sudo ${SBP_SCRIPT_PATH} --reissue-cert 重新签发（会重启 sing-box）。"
}

reissue_managed_certificate(){
  [[ "$EUID" -eq 0 || "${SBP_SKIP_ROOT:-0}" -eq 1 || -n "${TEST_ROOT:-}" ]] \
    || die "重新签发证书需要 root 权限，请使用 sudo 运行"
  load_env || true
  apply_runtime_overrides
  normalize_runtime_settings

  if [[ "${TLS_CERT_MODE:-self_signed}" != "self_signed" ]]; then
    info "当前证书模式为 $(tls_mode_label)，证书不由脚本签发，无需重签。"
    return 0
  fi

  local backup rc=0
  backup="$(mktemp -d)" || die "无法创建证书备份目录"
  mkdir -p "$CERT_DIR"
  cp -a "$CERT_DIR/." "$backup/" 2>/dev/null || true

  local failure=""
  if ! prepare_tls_certificate; then
    failure="重新签发自签证书失败"
  elif ! cert_matches_host "$TLS_CERT_PATH" "$REALITY_SERVER"; then
    failure="新证书仍不匹配 SNI ${REALITY_SERVER}"
  elif [[ -x "$BIN_PATH" && -s "$CONF_JSON" ]] && ! "$BIN_PATH" check -c "$CONF_JSON"; then
    failure="配置检查失败"
  fi
  if [[ -n "$failure" ]]; then
    cp -a "$backup/." "$CERT_DIR/" 2>/dev/null || true
    rm -rf "$backup"
    die "${failure}，已恢复原证书"
  fi

  info "自签证书已重新签发：CN=${REALITY_SERVER}"
  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
    if systemctl restart "$SYSTEMD_SERVICE"; then
      info "sing-box 已重启，新证书生效。"
    else
      warn "证书已更新，但服务重启失败，请手动检查。"
      rc=1
    fi
  else
    info "sing-box 未在运行，证书已更新，下次启动时生效。"
  fi
  rm -rf "$backup"
  return "$rc"
}

tls_uses_public_certificate(){
  case "$TLS_CERT_MODE" in
    acme) valid_tls_domain "$TLS_DOMAIN" ;;
    manual) validate_manual_certificate true ;;
    *) return 1 ;;
  esac
}

ensure_creds(){
  [[ -z "${UUID:-}" ]] && UUID=$(gen_uuid)
  is_uuid "$UUID" || UUID=$(gen_uuid)
  [[ -z "${HY2_PWD:-}" ]] && HY2_PWD=$(rand_b64_32)
  if [[ -z "${REALITY_PRIV:-}" || -z "${REALITY_PUB:-}" || -z "${REALITY_SID:-}" ]]; then
    readarray -t RKP < <(gen_reality)
    REALITY_PRIV=$(printf "%s\n" "${RKP[@]}" | awk '/PrivateKey/{print $2}')
    REALITY_PUB=$(printf "%s\n" "${RKP[@]}" | awk '/PublicKey/{print $2}')
    REALITY_SID=$(rand_hex8)
  fi
  [[ -z "${HY2_PWD2:-}" ]] && HY2_PWD2=$(rand_b64_32)
  [[ -z "${HY2_OBFS_PWD:-}" ]] && HY2_OBFS_PWD=$(openssl rand -base64 16 | tr -d "\n")
  [[ -z "${SS2022_KEY:-}" ]] && SS2022_KEY=$(rand_b64_32)
  [[ -z "${SS_PWD:-}" ]] && SS_PWD=$(openssl rand -base64 24 | tr -d "=\n" | tr "+/" "-_")
  TUIC_UUID="$UUID"; TUIC_PWD="$UUID"
  [[ -z "${ANYTLS_PWD:-}" ]] && ANYTLS_PWD=$(rand_b64_32)
  save_creds
}

# ===== WARP（wgcf） =====
WGCF_BIN=${WGCF_BIN:-/usr/local/bin/wgcf}
install_wgcf(){
  [[ -x "$WGCF_BIN" ]] && return 0
  local GOA url tmp
  case "$(arch_map)" in
    amd64) GOA=amd64;; arm64) GOA=arm64;; armv7) GOA=armv7;; 386) GOA=386;; *) GOA=amd64;;
  esac
  url=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
        | jq -r ".assets[] | select(.name|test(\"linux_${GOA}$\")) | .browser_download_url" | head -n1)
  [[ -n "$url" ]] || { warn "获取 wgcf 下载地址失败"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "$url" -o "$tmp/wgcf"
  install -m0755 "$tmp/wgcf" "$WGCF_BIN"
  rm -rf "$tmp"
}

# —— Base64 清理 + 补齐：去掉引号/空白，长度 %4==2 补“==”，%4==3 补“=” ——
pad_b64(){
  local s="${1:-}"
  # 去引号/空格/回车
  s="$(printf '%s' "$s" | tr -d '\r\n\" ')"
  # 去掉已有尾随 =，按需重加
  s="${s%%=*}"
  local rem=$(( ${#s} % 4 ))
  if   (( rem == 2 )); then s="${s}=="
  elif (( rem == 3 )); then s="${s}="
  fi
  printf '%s' "$s"
}


# ===== WARP（wgcf）配置生成/修复 =====
ensure_warp_profile(){
  [[ "${ENABLE_WARP:-true}" == "true" ]] || return 0

  # 先尝试读取旧 env，并做一次规范化补齐
  if load_warp 2>/dev/null; then
    WARP_PRIVATE_KEY="$(pad_b64 "${WARP_PRIVATE_KEY:-}")"
    WARP_PEER_PUBLIC_KEY="$(pad_b64 "${WARP_PEER_PUBLIC_KEY:-}")"
    # 允许之前没写 reserved，给默认 0
    : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"
    save_warp
    # 如果关键字段都在，就直接用旧的（已经补齐），无需重建
    if [[ -n "$WARP_PRIVATE_KEY" && -n "$WARP_PEER_PUBLIC_KEY" && -n "${WARP_ENDPOINT_HOST:-}" && -n "${WARP_ENDPOINT_PORT:-}" ]]; then
      return 0
    fi
  fi

  # 走到这里说明旧 env 不完整；开始用 wgcf 重建
  install_wgcf || { warn "wgcf 安装失败，禁用 WARP 节点"; ENABLE_WARP=false; save_env; return 0; }

  local wd="$SB_DIR/wgcf"; mkdir -p "$wd"
  if [[ ! -f "$wd/wgcf-account.toml" ]]; then
    "$WGCF_BIN" register --accept-tos --config "$wd/wgcf-account.toml" >/dev/null
  fi
  "$WGCF_BIN" generate --config "$wd/wgcf-account.toml" --profile "$wd/wgcf-profile.conf" >/dev/null

  local prof="$wd/wgcf-profile.conf"
  # 提取并规范化
  WARP_PRIVATE_KEY="$(pad_b64 "$(awk -F'= *' '/^PrivateKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"
  WARP_PEER_PUBLIC_KEY="$(pad_b64 "$(awk -F'= *' '/^PublicKey/{gsub(/\r/,"");print $2; exit}' "$prof")")"

  # Endpoint 可能是域名或 [IPv6]:port
  local ep host port
  ep="$(awk -F'= *' '/^Endpoint/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  if [[ "$ep" =~ ^\[(.+)\]:(.+)$ ]]; then host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"; else host="${ep%:*}"; port="${ep##*:}"; fi
  WARP_ENDPOINT_HOST="$host"
  WARP_ENDPOINT_PORT="$port"

  # 内网地址与 reserved
  local ad rs
  ad="$(awk -F'= *' '/^Address/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_ADDRESS_V4="${ad%%,*}"
  WARP_ADDRESS_V6="${ad##*,}"
  rs="$(awk -F'= *' '/^Reserved/{gsub(/\r/,"");print $2; exit}' "$prof" | tr -d '" ')"
  WARP_RESERVED_1="${rs%%,*}"; rs="${rs#*,}"
  WARP_RESERVED_2="${rs%%,*}"; WARP_RESERVED_3="${rs##*,}"
  : "${WARP_RESERVED_1:=0}" "${WARP_RESERVED_2:=0}" "${WARP_RESERVED_3:=0}"

  save_warp
}

# ===== 版本探测与比对 =====
get_singbox_local_version() {
  local bin="${1:-$BIN_PATH}"
  if [[ -x "$bin" ]] || command -v "$bin" >/dev/null 2>&1; then
    local v_str
    v_str="$("$bin" version 2>/dev/null | head -n1)" || return 1
    if [[ "$v_str" =~ ([0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)*) ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  fi
  return 1
}

get_singbox_remote_version() {
  local tag="${SINGBOX_TAG:-latest}"
  local repo="SagerNet/sing-box"
  local ver=""

  if [[ "$tag" != "latest" ]]; then
    echo "${tag#v}"
    return 0
  fi

  # 1. 优先通过 GitHub Releases API 获取
  local json
  json="$(curl -fsSL --connect-timeout 5 -m 10 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null || true)"
  if [[ -n "$json" ]] && command -v jq >/dev/null 2>&1; then
    ver="$(printf '%s' "$json" | jq -r '.tag_name // empty' 2>/dev/null || true)"
  fi

  # 2. API 限流或无 jq 时通过 HTTP Redirect Header 探测
  if [[ -z "$ver" || "$ver" == "null" ]]; then
    local loc
    loc="$(curl -fsSI --connect-timeout 5 -m 10 "https://github.com/${repo}/releases/latest" 2>/dev/null | grep -i '^location:' | tr -d '\r\n' || true)"
    if [[ "$loc" =~ /tag/v?([0-9]+\.[0-9]+(\.[0-9]+)?(-[a-zA-Z0-9.]+)*) ]]; then
      ver="${BASH_REMATCH[1]}"
    fi
  fi

  ver="${ver#v}"
  if [[ -n "$ver" && "$ver" != "null" ]]; then
    echo "$ver"
    return 0
  fi
  return 1
}

version_lt() {
  local v1="$1" v2="$2"
  [[ "$v1" == "$v2" ]] && return 1

  # 分离主版本号与预发布后缀 (例如 1.12.0-rc.1 -> core="1.12.0", pre="rc.1")
  local core1="${v1%%-*}" pre1=""
  [[ "$v1" == *-* ]] && pre1="${v1#*-}"

  local core2="${v2%%-*}" pre2=""
  [[ "$v2" == *-* ]] && pre2="${v2#*-}"

  local IFS=.
  local -a i1=($core1) i2=($core2)
  local max=${#i1[@]}
  (( ${#i2[@]} > max )) && max=${#i2[@]}

  for ((i=0; i<max; i++)); do
    local n1=${i1[i]:-0} n2=${i2[i]:-0}
    [[ "$n1" =~ ^[0-9]+$ ]] || n1=0
    [[ "$n2" =~ ^[0-9]+$ ]] || n2=0
    if (( n1 < n2 )); then
      return 0
    elif (( n1 > n2 )); then
      return 1
    fi
  done

  # 核心版本相同时：有预发布后缀的版本 < 无预发布后缀的正式版
  if [[ -n "$pre1" && -z "$pre2" ]]; then
    return 0
  elif [[ -z "$pre1" && -n "$pre2" ]]; then
    return 1
  elif [[ -n "$pre1" && -n "$pre2" ]]; then
    [[ "$pre1" < "$pre2" ]] && return 0 || return 1
  fi

  return 1
}

# ===== 依赖与安装 =====
install_deps(){
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null 2>&1 || true
    apt-get install -y ca-certificates curl wget jq tar iproute2 openssl coreutils uuid-runtime >/dev/null 2>&1 || true
  else
    ensure_deps curl jq tar openssl || true
  fi
}

# ===== 安装 / 智能升级 sing-box =====
install_singbox() {
  local force="${1:-0}"
  local local_ver="" remote_ver="" needs_install=1

  # 基础依赖
  ensure_deps curl jq tar || return 1
  command -v xz >/dev/null 2>&1 || ensure_deps xz-utils >/dev/null 2>&1 || true
  command -v unzip >/dev/null 2>&1 || ensure_deps unzip >/dev/null 2>&1 || true

  remote_ver="$(get_singbox_remote_version 2>/dev/null || true)"

  if local_ver="$(get_singbox_local_version "$BIN_PATH")"; then
    info "检测到已安装 sing-box: v${local_ver}"
    if [[ -n "$remote_ver" ]]; then
      if version_lt "$local_ver" "$remote_ver"; then
        info "发现新版本 sing-box: v${remote_ver}（当前版本: v${local_ver}），准备自动升级..."
        needs_install=1
      else
        if [[ "$force" -eq 1 ]]; then
          info "当前已是最新版本 (v${local_ver})，按指令重新下载安装..."
          needs_install=1
        else
          info "sing-box 当前已是最新版本 (v${local_ver})，无需重复下载"
          needs_install=0
        fi
      fi
    else
      if [[ "$force" -eq 1 ]]; then
        info "未能获取远端最新版本，强制重新安装..."
        needs_install=1
      else
        info "未能获取远端版本信息，保留现有已安装版本 (v${local_ver})"
        needs_install=0
      fi
    fi
  else
    info "未检测到已安装的 sing-box，准备开始全新安装..."
    needs_install=1
  fi

  if [[ "$needs_install" -eq 0 ]]; then
    return 0
  fi

  local repo="SagerNet/sing-box"
  local tag="${SINGBOX_TAG:-latest}"
  local arch; arch="$(arch_map)"
  local rel_url re url tmp pkg bin

  info "下载 sing-box (${arch}) ..."
  if [[ "$tag" == "latest" ]]; then
    rel_url="https://api.github.com/repos/${repo}/releases/latest"
  else
    rel_url="https://api.github.com/repos/${repo}/releases/tags/${tag}"
  fi

  re="^sing-box-.*-linux-${arch}\\.(tar\\.(gz|xz)|zip)$"
  url="$(curl -fsSL --connect-timeout 5 -m 15 "$rel_url" 2>/dev/null | jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' 2>/dev/null | head -n1 || true)"
  if [[ -z "$url" || "$url" == "null" ]]; then
    url="$(curl -fsSL --connect-timeout 5 -m 15 "https://api.github.com/repos/${repo}/releases" 2>/dev/null \
           | jq -r --arg re "$re" '[ .[] | .assets[] | select(.name | test($re)) | .browser_download_url ][0]' 2>/dev/null || true)"
  fi
  if [[ -z "$url" || "$url" == "null" ]]; then
    if [[ -n "$remote_ver" ]]; then
      url="https://github.com/${repo}/releases/download/v${remote_ver}/sing-box-${remote_ver}-linux-${arch}.tar.gz"
    else
      die "下载 sing-box 失败：未匹配到发行包（arch=${arch} tag=${tag})"
      return 1
    fi
  fi

  tmp="$(mktemp -d)" || return 1
  pkg="${tmp}/pkg"

  # 多节点/镜像加速下载
  local dl_ok=0
  local urls_to_try=("$url")
  [[ "$url" == https://github.com/* ]] && urls_to_try+=("https://ghproxy.net/$url" "https://raw.gitmirror.com/$url")

  for try_url in "${urls_to_try[@]}"; do
    if curl -fL --connect-timeout 10 -m 60 "$try_url" -o "$pkg" 2>/dev/null; then
      dl_ok=1
      break
    fi
  done

  if [[ "$dl_ok" -ne 1 ]]; then
    rm -rf "$tmp"
    die "下载 sing-box 失败：$url"
    return 1
  fi

  # 解压
  if echo "$url" | grep -qE '\.tar\.gz$|\.tgz$'; then
    tar -xzf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.tar\.xz$'; then
    tar -xJf "$pkg" -C "$tmp"
  elif echo "$url" | grep -qE '\.zip$'; then
    unzip -q "$pkg" -d "$tmp"
  else
    rm -rf "$tmp"
    die "未知包格式：$url"
    return 1
  fi

  bin="$(find "$tmp" -type f -name 'sing-box' | head -n1)"
  if [[ -z "$bin" || ! -f "$bin" ]]; then
    rm -rf "$tmp"
    die "解压失败：未在安装包中找到 sing-box 可执行文件"
    return 1
  fi

  chmod 0755 "$bin"
  if ! "$bin" version >/dev/null 2>&1; then
    rm -rf "$tmp"
    die "下载的 sing-box 无法正常执行，请检查系统架构兼容性"
    return 1
  fi

  mkdir -p "$(dirname "$BIN_PATH")" "$SBP_BIN_DIR" 2>/dev/null || true
  if [[ -f "$BIN_PATH" ]]; then
    cp -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
  fi

  if install -m 0755 "$bin" "$BIN_PATH"; then
    ln -sf "$BIN_PATH" "$SBP_BIN_DIR/sing-box" 2>/dev/null || true
    rm -f "${BIN_PATH}.bak" 2>/dev/null || true
    rm -rf "$tmp"
    local new_installed_ver
    new_installed_ver="$(get_singbox_local_version "$BIN_PATH" || echo "最新")"
    info "sing-box 安装/升级完成：v${new_installed_ver}"
    return 0
  else
    [[ -f "${BIN_PATH}.bak" ]] && mv -f "${BIN_PATH}.bak" "$BIN_PATH" 2>/dev/null || true
    rm -rf "$tmp"
    die "写入 sing-box 二进制到 $BIN_PATH 失败"
    return 1
  fi
}

# ===== GeoFiles 规则文件更新模块 =====
update_geofiles() {
  ensure_dirs
  ensure_deps curl jq || return 1

  info "正在准备更新 GeoFiles (GeoIP / GeoSite / 规则集)..."

  local tmp_geo
  tmp_geo="$(mktemp -d)" || return 1

  fetch_geofile() {
    local filename="$1"
    shift
    local target="$tmp_geo/$filename"
    local success=0

    for u in "$@"; do
      echo -ne "  [下载] $filename <- $u ... "
      if curl -fsSL --connect-timeout 10 -m 60 -o "$target" "$u" 2>/dev/null && [[ -s "$target" ]]; then
        local sz
        sz="$(wc -c < "$target" 2>/dev/null | awk '{printf "%.2f MB", $1/1048576}')"
        echo -e "${C_GREEN}成功 (${sz})${C_RESET}"
        success=1
        break
      else
        echo -e "${C_YELLOW}失败，尝试备用节点${C_RESET}"
      fi
    done

    if [[ "$success" -eq 1 ]]; then
      return 0
    else
      warn "未能下载 $filename，将跳过该文件"
      return 1
    fi
  }

  echo -e "${C_CYAN}--- 开始下载最新 GeoIP / GeoSite 规则文件 ---${C_RESET}"

  # 1. geoip.db
  fetch_geofile "geoip.db" \
    "https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db" \
    "https://ghproxy.net/https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip.db" \
    "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.db" \
    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geoip.db" || true

  # 2. geosite.db
  fetch_geofile "geosite.db" \
    "https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db" \
    "https://ghproxy.net/https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite.db" \
    "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.db" \
    "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/geosite.db" || true

  # 3. 常用 SRS 规则集
  fetch_geofile "geoip-cn.srs" \
    "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" \
    "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" \
    "https://raw.gitmirror.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs" || true

  fetch_geofile "geosite-cn.srs" \
    "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" \
    "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" \
    "https://raw.gitmirror.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs" || true

  fetch_geofile "geosite-geolocation-!cn.srs" \
    "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs" \
    "https://ghproxy.net/https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs" \
    "https://raw.gitmirror.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs" || true

  # 4. 自定义路由中定义的 remote rule-sets
  if [[ -s "$ROUTE_JSON" ]] && command -v jq >/dev/null 2>&1; then
    local custom_tags=() custom_urls=()
    while IFS=$'\t' read -r tag url; do
      [[ -n "$tag" && -n "$url" ]] || continue
      custom_tags+=("$tag")
      custom_urls+=("$url")
    done < <(jq -r '(.rule_set // [])[] | select(.type=="remote" and .tag != null and .url != null) | [.tag, .url] | @tsv' "$ROUTE_JSON" 2>/dev/null || true)

    for ((i=0; i<${#custom_tags[@]}; i++)); do
      local tag="${custom_tags[i]}"
      local url="${custom_urls[i]}"
      fetch_geofile "${tag}.srs" "$url" "https://ghproxy.net/$url" "https://raw.gitmirror.com/${url#*raw.githubusercontent.com/}" || true
    done
  fi

  local target_dirs=("$DATA_DIR" "$SB_DIR")
  [[ -d "/var/lib/sing-box" ]] && target_dirs+=("/var/lib/sing-box")

  local installed_files=0
  for f in "$tmp_geo"/*; do
    [[ -f "$f" ]] || continue
    local fname; fname="$(basename "$f")"
    for tdir in "${target_dirs[@]}"; do
      mkdir -p "$tdir" 2>/dev/null || true
      cp -f "$f" "$tdir/$fname" 2>/dev/null || true
    done
    ((installed_files++)) || true
  done

  rm -rf "$tmp_geo"

  if [[ "$installed_files" -gt 0 ]]; then
    local update_time
    update_time="$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'LAST_UPDATE="%s"\nFILES_COUNT=%d\n' "$update_time" "$installed_files" > "$SB_DIR/geofiles.version"
    info "GeoFiles 规则文件更新完成！共更新 ${installed_files} 个规则文件 (时间: ${update_time})"

    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
      info "正在重启 sing-box 服务以应用最新规则..."
      systemctl restart "${SYSTEMD_SERVICE}" || warn "重启服务失败，请稍后手动重启"
    fi
    return 0
  else
    warn "GeoFiles 更新失败：所有规则文件均未成功下载，请检查网络连接"
    return 1
  fi
}

# ===== 运行时辅助：DNS 健康切换与服务事件记录 =====
write_runtime_helpers(){
  mkdir -p "$(dirname "$DNS_HEALTH_BIN")" "$(dirname "$EVENT_LOG_BIN")" "$SYSTEMD_UNIT_DIR" || return 1

  cat > "$DNS_HEALTH_BIN" <<'EOF' || return 1
#!/usr/bin/env bash
set -uo pipefail

SB_DIR=${SB_DIR:-/opt/sing-box}
CONF_JSON=${CONF_JSON:-$SB_DIR/config.json}
DNS_HEALTH_LOG=${DNS_HEALTH_LOG:-$SB_DIR/dns-health.log}
BIN_PATH=${BIN_PATH:-/usr/local/bin/sing-box}
SYSTEMD_SERVICE=${SYSTEMD_SERVICE:-sing-box.service}
MODE=${1:-check}

[[ -f "$SB_DIR/env.conf" ]] && source "$SB_DIR/env.conf"
[[ -s "$CONF_JSON" ]] || exit 0
mkdir -p "$SB_DIR"
DNS_HEALTH_STATE=${DNS_HEALTH_STATE:-$SB_DIR/dns-health.state}
DNS_FAILURE_THRESHOLD=${DNS_FAILURE_THRESHOLD:-3}
DNS_RECOVERY_THRESHOLD=${DNS_RECOVERY_THRESHOLD:-5}
DNS_SWITCH_COOLDOWN=${DNS_SWITCH_COOLDOWN:-600}
if [[ ! "$DNS_FAILURE_THRESHOLD" =~ ^[0-9]+$ ]] ||
   (( DNS_FAILURE_THRESHOLD < 1 || DNS_FAILURE_THRESHOLD > 100 )); then
  DNS_FAILURE_THRESHOLD=3
fi
if [[ ! "$DNS_RECOVERY_THRESHOLD" =~ ^[0-9]+$ ]] ||
   (( DNS_RECOVERY_THRESHOLD < 1 || DNS_RECOVERY_THRESHOLD > 100 )); then
  DNS_RECOVERY_THRESHOLD=5
fi
if [[ ! "$DNS_SWITCH_COOLDOWN" =~ ^[0-9]+$ ]] ||
   (( DNS_SWITCH_COOLDOWN < 0 || DNS_SWITCH_COOLDOWN > 86400 )); then
  DNS_SWITCH_COOLDOWN=600
fi
umask 077

log_event(){
  printf '%s %s\n' "$(date '+%F %T %z')" "$*" >> "$DNS_HEALTH_LOG"
  local lines
  lines=$(wc -l < "$DNS_HEALTH_LOG" 2>/dev/null || echo 0)
  if (( lines > 2000 )); then
    tail -n 1000 "$DNS_HEALTH_LOG" > "${DNS_HEALTH_LOG}.tmp" &&
      mv "${DNS_HEALTH_LOG}.tmp" "$DNS_HEALTH_LOG"
  fi
}

read_state(){
  STATE_PENDING_DNS=""
  STATE_PENDING_COUNT=0
  STATE_LAST_SWITCH=0
  [[ -s "$DNS_HEALTH_STATE" ]] || return 0

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      pending_dns)
        case "$value" in
          dns-doh-primary|dns-doh-backup|dns-udp-fallback) STATE_PENDING_DNS=$value ;;
        esac
        ;;
      pending_count)
        [[ "$value" =~ ^[0-9]+$ ]] && STATE_PENDING_COUNT=$value
        ;;
      last_switch)
        [[ "$value" =~ ^[0-9]+$ ]] && STATE_LAST_SWITCH=$value
        ;;
    esac
  done < "$DNS_HEALTH_STATE"
}

write_state(){
  local tmp="${DNS_HEALTH_STATE}.$$"
  if ! printf 'pending_dns=%s\npending_count=%s\nlast_switch=%s\n' \
      "$STATE_PENDING_DNS" "$STATE_PENDING_COUNT" "$STATE_LAST_SWITCH" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  chmod 600 "$tmp"
  mv "$tmp" "$DNS_HEALTH_STATE"
}

dns_rank(){
  case "$1" in
    dns-doh-primary) echo 0 ;;
    dns-doh-backup) echo 1 ;;
    dns-udp-fallback) echo 2 ;;
    *) echo 99 ;;
  esac
}

probe_cloudflare(){
  curl -4 -fsS --connect-timeout 3 --max-time 6 \
    --resolve cloudflare-dns.com:443:1.1.1.1 \
    -H 'accept: application/dns-json' \
    'https://cloudflare-dns.com/dns-query?name=example.com&type=A' |
    grep -Eq '"Status"[[:space:]]*:[[:space:]]*0'
}

probe_google(){
  curl -4 -fsS --connect-timeout 3 --max-time 6 \
    --resolve dns.google:443:8.8.8.8 \
    -H 'accept: application/dns-json' \
    'https://dns.google/resolve?name=example.com&type=A' |
    grep -Eq '"Status"[[:space:]]*:[[:space:]]*0'
}

probe_retry(){
  "$1" >/dev/null 2>&1 || { sleep 1; "$1" >/dev/null 2>&1; }
}

if [[ "$MODE" == "--probe" ]]; then
  if probe_cloudflare >/dev/null 2>&1; then echo "Cloudflare DoH: 正常"; else echo "Cloudflare DoH: 失败"; fi
  if probe_google >/dev/null 2>&1; then echo "Google DoH: 正常"; else echo "Google DoH: 失败"; fi
  echo "UDP 备用 DNS: 1.0.0.1:53（仅在两个 DoH 均失败时启用）"
  echo "当前 DNS: $(jq -r '.dns.final // "未知"' "$CONF_JSON" 2>/dev/null)"
  exit 0
fi

if command -v flock >/dev/null 2>&1; then
  exec 9>"$SB_DIR/.dns-health.lock"
  flock -n 9 || exit 0
fi

if probe_retry probe_cloudflare; then
  selected="dns-doh-primary"
elif probe_retry probe_google; then
  selected="dns-doh-backup"
else
  selected="dns-udp-fallback"
fi

current=$(jq -r '.dns.final // "dns-doh-primary"' "$CONF_JSON" 2>/dev/null)
read_state

if [[ "$current" == "$selected" ]]; then
  if [[ -n "$STATE_PENDING_DNS" || "$STATE_PENDING_COUNT" -ne 0 ]]; then
    STATE_PENDING_DNS=""
    STATE_PENDING_COUNT=0
    write_state || log_event "DNS 状态保存失败：无法清除待切换状态"
  fi
  exit 0
fi

current_rank=$(dns_rank "$current")
selected_rank=$(dns_rank "$selected")
if (( selected_rank < current_rank )); then
  transition="恢复"
  threshold=$DNS_RECOVERY_THRESHOLD
else
  transition="故障转移"
  threshold=$DNS_FAILURE_THRESHOLD
fi

if [[ "$STATE_PENDING_DNS" == "$selected" ]]; then
  (( STATE_PENDING_COUNT += 1 ))
else
  STATE_PENDING_DNS=$selected
  STATE_PENDING_COUNT=1
fi

if (( STATE_PENDING_COUNT < threshold )); then
  write_state || log_event "DNS 状态保存失败：无法记录待切换状态"
  log_event "DNS ${transition}待确认：$current -> $selected（${STATE_PENDING_COUNT}/${threshold}）"
  exit 0
fi

now=$(date +%s)
if [[ "$transition" == "恢复" ]] && (( STATE_LAST_SWITCH > 0 )); then
  elapsed=$(( now - STATE_LAST_SWITCH ))
  if (( elapsed < DNS_SWITCH_COOLDOWN )); then
    remaining=$(( DNS_SWITCH_COOLDOWN - elapsed ))
    write_state || log_event "DNS 状态保存失败：无法记录冷却状态"
    log_event "DNS 恢复等待冷却：$current -> $selected（剩余 ${remaining}s）"
    exit 0
  fi
fi

tmp="${CONF_JSON}.dns-health.$$"
if ! jq --arg dns "$selected" '
  .dns.final = $dns
  | .route.default_domain_resolver = $dns
  | .outbounds = ((.outbounds // []) | map(
      if .tag == "direct-ipv4" then .domain_resolver = {server:$dns, strategy:"ipv4_only"} | del(.domain_strategy)
      elif .tag == "direct-ipv6" then .domain_resolver = {server:$dns, strategy:"ipv6_only"} | del(.domain_strategy)
      elif (.domain_resolver | type == "object" and .domain_resolver.strategy != null) then .domain_resolver.server = $dns | del(.domain_strategy)
      elif .type == "direct" then .domain_resolver = $dns | del(.domain_strategy)
      elif (.domain_resolver | type == "string") then .domain_resolver = $dns | del(.domain_strategy)
      else . | del(.domain_strategy) end
    ))
  | .endpoints = ((.endpoints // []) | map(if .tag == "warp" then .domain_resolver = $dns else . end))
' "$CONF_JSON" > "$tmp"; then
  rm -f "$tmp"
  log_event "DNS 配置切换失败：无法更新 JSON"
  exit 1
fi

if ! "$BIN_PATH" check -c "$tmp" >/dev/null 2>&1; then
  rm -f "$tmp"
  log_event "DNS 配置切换失败：sing-box 配置检查未通过"
  exit 1
fi

chmod 600 "$tmp"
mv "$tmp" "$CONF_JSON"
STATE_PENDING_DNS=""
STATE_PENDING_COUNT=0
STATE_LAST_SWITCH=$now
write_state || log_event "DNS 状态保存失败：配置已切换但无法记录状态"
log_event "DNS 切换：$current -> $selected（${transition}，阈值 ${threshold}）"

if [[ "$MODE" != "--no-restart" ]] && systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
  systemctl restart "$SYSTEMD_SERVICE"
fi
EOF

  cat > "$EVENT_LOG_BIN" <<'EOF' || return 1
#!/usr/bin/env bash
set -uo pipefail

SB_DIR=${SB_DIR:-/opt/sing-box}
RESTART_LOG=${RESTART_LOG:-$SB_DIR/restart.log}
action=${1:-event}
mkdir -p "$SB_DIR"

printf '%s action=%s result=%s exit_code=%s exit_status=%s invocation=%s\n' \
  "$(date '+%F %T %z')" "$action" "${SERVICE_RESULT:-unknown}" \
  "${EXIT_CODE:-unknown}" "${EXIT_STATUS:-unknown}" "${INVOCATION_ID:-unknown}" >> "$RESTART_LOG"

lines=$(wc -l < "$RESTART_LOG" 2>/dev/null || echo 0)
if (( lines > 2000 )); then
  tail -n 1000 "$RESTART_LOG" > "${RESTART_LOG}.tmp" &&
    mv "${RESTART_LOG}.tmp" "$RESTART_LOG"
fi
EOF

  chmod 0755 "$DNS_HEALTH_BIN" "$EVENT_LOG_BIN" || return 1

  cat > "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_SERVICE}" <<EOF || return 1
[Unit]
Description=Sing-Box-Plus DNS health check
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment=SB_DIR=${SB_DIR}
Environment=SYSTEMD_SERVICE=${SYSTEMD_SERVICE}
ExecStart=${DNS_HEALTH_BIN}
EOF

  cat > "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_TIMER}" <<EOF || return 1
[Unit]
Description=Run Sing-Box-Plus DNS health check periodically

[Timer]
OnBootSec=1m
OnUnitActiveSec=${DNS_HEALTH_INTERVAL}
RandomizedDelaySec=15s
Persistent=true
Unit=${DNS_HEALTH_SERVICE}

[Install]
WantedBy=timers.target
EOF
  chmod 0644 "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_SERVICE}" "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_TIMER}" || return 1
  return 0
}

# ===== systemd =====
write_systemd(){
write_runtime_helpers
cat > "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}" <<EOF
[Unit]
Description=Sing-Box (Native 20 nodes)
After=network-online.target
Requires=network-online.target

[Service]
Type=simple
Environment=SB_DIR=${SB_DIR}
Environment=SYSTEMD_SERVICE=${SYSTEMD_SERVICE}
ExecStartPre=-${DNS_HEALTH_BIN} --no-restart
ExecStart=${BIN_PATH} run -c ${CONF_JSON} -D ${DATA_DIR}
ExecStartPost=${EVENT_LOG_BIN} start
ExecStopPost=${EVENT_LOG_BIN} stop
Restart=on-failure
RestartSec=3
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
systemctl enable --now "${DNS_HEALTH_TIMER}" >/dev/null 2>&1 || true
}

# ===== 写 config.json（使用你提供的稳定配置逻辑） =====
write_config(){
  ensure_dirs; load_env || true; load_creds || true; load_ports || true
  apply_runtime_overrides
  normalize_runtime_settings
  ensure_creds; save_all_ports; prepare_tls_certificate || return 1
  [[ "$ENABLE_WARP" == "true" ]] && ensure_warp_profile || true

  local CRT="$TLS_CERT_PATH" KEY="$TLS_KEY_PATH"
  local ROUTING_JSON BIND4 BIND6 TMP_CONF
  ROUTING_JSON="$(load_route_json)"
  BIND4="$(default_ipv4_address || true)"
  BIND6="$(default_ipv6_address || true)"
  TMP_CONF="$(mktemp "$SB_DIR/config.json.tmp.XXXXXX")" || return 1
  if ! jq -n \
  --arg RS "$REALITY_SERVER" --argjson RSP "${REALITY_SERVER_PORT:-443}" --arg UID "$UUID" \
  --arg RPR "$REALITY_PRIV" --arg RPB "$REALITY_PUB" --arg SID "$REALITY_SID" \
  --arg HY2 "$HY2_PWD" --arg HY22 "$HY2_PWD2" --arg HY2O "$HY2_OBFS_PWD" \
  --arg GRPC "$GRPC_SERVICE" --arg VMWS "$VMESS_WS_PATH" --arg CRT "$CRT" --arg KEY "$KEY" \
  --arg TLSMODE "$TLS_CERT_MODE" --arg TLSDOMAIN "$TLS_DOMAIN" \
  --arg ACMEEMAIL "$TLS_ACME_EMAIL" --arg ACMEPROVIDER "$TLS_ACME_PROVIDER" --arg ACMEDATA "$TLS_ACME_DATA_DIR" \
  --argjson ACMEDISABLEHTTP "$TLS_ACME_DISABLE_HTTP_CHALLENGE" \
  --argjson ACMEDISABLETLS "$TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE" \
  --arg SS2022 "$SS2022_KEY" --arg SSPWD "$SS_PWD" --arg TUICUUID "$TUIC_UUID" --arg TUICPWD "$TUIC_PWD" \
  --arg ANYTLS "$ANYTLS_PWD" \
  --arg TCPKA "$TCP_KEEP_ALIVE" --arg TCPKAI "$TCP_KEEP_ALIVE_INTERVAL" --arg UDPT "$UDP_TIMEOUT" \
  --argjson WARP_KEEPALIVE "$WARP_KEEPALIVE_INTERVAL" \
  --argjson P1 "$PORT_VLESSR" --argjson P2 "$PORT_VLESS_GRPCR" --argjson P3 "$PORT_TROJANR" \
  --argjson P4 "$PORT_HY2" --argjson P5 "$PORT_VMESS_WS" --argjson P6 "$PORT_HY2_OBFS" \
  --argjson P7 "$PORT_SS2022" --argjson P8 "$PORT_SS" --argjson P9 "$PORT_TUIC" --argjson P10 "$PORT_ANYTLS" \
  --argjson PW1 "$PORT_VLESSR_W" --argjson PW2 "$PORT_VLESS_GRPCR_W" --argjson PW3 "$PORT_TROJANR_W" \
  --argjson PW4 "$PORT_HY2_W" --argjson PW5 "$PORT_VMESS_WS_W" --argjson PW6 "$PORT_HY2_OBFS_W" \
  --argjson PW7 "$PORT_SS2022_W" --argjson PW8 "$PORT_SS_W" --argjson PW9 "$PORT_TUIC_W" --argjson PW10 "$PORT_ANYTLS_W" \
  --arg ENABLE_WARP "$ENABLE_WARP" \
  --arg WPRIV "${WARP_PRIVATE_KEY:-}" --arg WPPUB "${WARP_PEER_PUBLIC_KEY:-}" \
  --arg WHOST "${WARP_ENDPOINT_HOST:-}" --argjson WPORT "${WARP_ENDPOINT_PORT:-0}" \
  --arg W4 "${WARP_ADDRESS_V4:-}" --arg W6 "${WARP_ADDRESS_V6:-}" \
  --argjson WR1 "${WARP_RESERVED_1:-0}" --argjson WR2 "${WARP_RESERVED_2:-0}" --argjson WR3 "${WARP_RESERVED_3:-0}" \
  --arg BIND4 "$BIND4" --arg BIND6 "$BIND6" --argjson CUSTOM_ROUTES "$ROUTING_JSON" \
  '
  def listen_tuning: {tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI, udp_timeout:$UDPT};
  def inbound_tls($alpn):
    ({enabled:true}
      + (if $TLSDOMAIN != "" then {server_name:$TLSDOMAIN} else {} end)
      + (if ($alpn | length) > 0 then {alpn:$alpn} else {} end)
      + (if $TLSMODE == "acme" then
          {acme:{
            domain:[$TLSDOMAIN], data_directory:$ACMEDATA, default_server_name:$TLSDOMAIN,
            email:$ACMEEMAIL, provider:$ACMEPROVIDER,
            disable_http_challenge:$ACMEDISABLEHTTP,
            disable_tls_alpn_challenge:$ACMEDISABLETLS
          }}
        else {certificate_path:$CRT, key_path:$KEY} end));
  def inbound_vless($port): ({type:"vless", listen:"0.0.0.0", listen_port:$port, users:[{uuid:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}} + listen_tuning);
  def inbound_vless_flow($port): ({type:"vless", listen:"0.0.0.0", listen_port:$port, users:[{uuid:$UID, flow:"xtls-rprx-vision"}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}} + listen_tuning);
  def inbound_trojan($port): ({type:"trojan", listen:"0.0.0.0", listen_port:$port, users:[{password:$UID}], tls:{enabled:true, server_name:$RS, reality:{enabled:true, handshake:{server:$RS, server_port:$RSP}, private_key:$RPR, short_id:[$SID]}}} + listen_tuning);
  def inbound_hy2($port): ({type:"hysteria2", listen:"0.0.0.0", listen_port:$port, users:[{name:"hy2", password:$HY2}], tls:inbound_tls([])} + listen_tuning);
  def inbound_vmess_ws($port): ({type:"vmess", listen:"0.0.0.0", listen_port:$port, users:[{uuid:$UID}], transport:{type:"ws", path:$VMWS}} + listen_tuning);
  def inbound_hy2_obfs($port): ({type:"hysteria2", listen:"0.0.0.0", listen_port:$port, users:[{name:"hy2", password:$HY22}], obfs:{type:"salamander", password:$HY2O}, tls:inbound_tls(["h3"])} + listen_tuning);
  def inbound_ss2022($port): ({type:"shadowsocks", listen:"0.0.0.0", listen_port:$port, method:"2022-blake3-aes-256-gcm", password:$SS2022} + listen_tuning);
  def inbound_ss($port): ({type:"shadowsocks", listen:"0.0.0.0", listen_port:$port, method:"aes-256-gcm", password:$SSPWD} + listen_tuning);
  def inbound_tuic($port): ({type:"tuic", listen:"0.0.0.0", listen_port:$port, users:[{uuid:$TUICUUID, password:$TUICPWD}], congestion_control:"bbr", tls:inbound_tls(["h3"])} + listen_tuning);
  def inbound_anytls($port): ({type:"anytls", listen:"0.0.0.0", listen_port:$port, users:[{name:"anytls", password:$ANYTLS}], tls:inbound_tls(["h2","http/1.1"])} + listen_tuning);

  def warp_ready:
    $ENABLE_WARP=="true" and ($WPRIV|length)>0 and ($WPPUB|length)>0 and ($WHOST|length)>0 and ($WPORT>0) and (([$W4, $W6] | map(select(. != "")) | length)>0);

  def warp_endpoint:
    {type:"wireguard", tag:"warp",
      system: false,
      address: ( [ $W4, $W6 ] | map(select(. != "")) ),
      private_key:$WPRIV,
      peers: [ {
        address:$WHOST, port:$WPORT, public_key:$WPPUB,
        reserved: [ $WR1, $WR2, $WR3 ],
        allowed_ips: ["0.0.0.0/0","::/0"],
        persistent_keepalive_interval: $WARP_KEEPALIVE
      } ],
      mtu:1280,
      udp_timeout:$UDPT,
      domain_resolver:"dns-doh-primary"
    };

  def custom_rule_sets:
    (($CUSTOM_ROUTES.rule_set // []) | map(select((.tag // "") != "")));

  def normalize_outbound_ip_strategy:
    . as $ob
    | (($ob.domain_resolver | objects | .server) // ($ob.domain_resolver | strings) // "dns-doh-primary") as $server
    | ($ob.domain_strategy // ($ob.domain_resolver | objects | .strategy) // "") as $strat
    | ($ob | del(.domain_strategy)) as $clean_ob
    | if $strat == "ipv4_only" then
        $clean_ob + {domain_resolver:{server:$server, strategy:"ipv4_only"}}
      elif $strat == "ipv6_only" then
        $clean_ob + {domain_resolver:{server:$server, strategy:"ipv6_only"}}
      elif $strat == "prefer_ipv6" then
        $clean_ob + {domain_resolver:{server:$server, strategy:"prefer_ipv6"}}
      elif $strat == "prefer_ipv4" then
        $clean_ob + {domain_resolver:$server}
      else
        if ($clean_ob.domain_resolver == null or $clean_ob.domain_resolver == "") then
          $clean_ob + {domain_resolver:$server}
        else $clean_ob end
      end;

  def custom_outbounds:
    (($CUSTOM_ROUTES.outbounds // [])
      | map(select((.tag // "") != "" and (.type // "") != ""))
      | map(normalize_outbound_ip_strategy));

  def custom_uses_outbound($tag):
    ((($CUSTOM_ROUTES.rules // []) | map(select((.outbound // "") == $tag)) | length) > 0)
    or (($CUSTOM_ROUTES.default_outbound // "direct") == $tag);

  def custom_route_match($rule):
    ({}
      + (if (($rule.domain // []) | length) > 0 then {domain:$rule.domain} else {} end)
      + (if (($rule.domain_suffix // []) | length) > 0 then {domain_suffix:$rule.domain_suffix} else {} end)
      + (if (($rule.domain_keyword // []) | length) > 0 then {domain_keyword:$rule.domain_keyword} else {} end)
      + (if (($rule.domain_regex // []) | length) > 0 then {domain_regex:$rule.domain_regex} else {} end)
      + (if (($rule.rule_set // []) | length) > 0 then {rule_set:$rule.rule_set} else {} end));

  def custom_route_match_tree($rule):
    if $rule.type == "logical" then
      {type:"logical", mode:"or", rules:(($rule.rules // []) | map(custom_route_match_tree(.)))}
    else custom_route_match($rule) end;

  def custom_route_rule($rule):
    (custom_route_match_tree($rule)
      + (if $rule.action == "reject" then {action:"reject"} else {action:"route", outbound:$rule.outbound} end));

  def custom_route_rules:
    (($CUSTOM_ROUTES.rules // [])
      | map(select(.action == "reject" or (.outbound // "") != ""))
      | map(custom_route_rule(.))
      | map(select((keys - ["action","outbound"]) | length > 0)));

  def warp_inbound_rule:
    { inbound: ["vless-reality-warp","vless-grpcr-warp","trojan-reality-warp","hy2-warp","vmess-ws-warp","hy2-obfs-warp","ss2022-warp","ss-warp","tuic-v5-warp","anytls-warp"], action:"route", outbound:"warp" };

  def route_rules:
    custom_route_rules + (if warp_ready then [warp_inbound_rule] else [] end);

  def direct_outbound:
    {type:"direct", tag:"direct", tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI, domain_resolver:"dns-doh-primary"};

  def direct_ipv4_outbound:
    ({type:"direct", tag:"direct-ipv4", tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI,
      domain_resolver:{server:"dns-doh-primary", strategy:"ipv4_only"}}
      + (if $BIND4 != "" then {inet4_bind_address:$BIND4, bind_address_no_port:true} else {} end));

  def direct_ipv6_outbound:
    ({type:"direct", tag:"direct-ipv6", tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI,
      domain_resolver:{server:"dns-doh-primary", strategy:"ipv6_only"}}
      + (if $BIND6 != "" then {inet6_bind_address:$BIND6, bind_address_no_port:true} else {} end));

  def resolved_final_outbound:
    ($CUSTOM_ROUTES.default_outbound // "direct") as $target
    | if ($target == "direct" or $target == "direct-ipv4" or $target == "direct-ipv6" or ($target == "warp" and warp_ready) or ((custom_outbounds | map(.tag) | index($target)) != null))
      then $target
      else "direct"
      end;

  def route_config:
    ({default_domain_resolver:"dns-doh-primary", final:resolved_final_outbound}
      + (if (route_rules | length) > 0 then {rules:route_rules} else {} end)
      + (if (custom_rule_sets | length) > 0 then {rule_set:custom_rule_sets} else {} end));

  {
    log:{level:"info", timestamp:true},
    dns:{
      servers:[
        {type:"https", tag:"dns-doh-primary", server:"1.1.1.1", path:"/dns-query", tls:{enabled:true, server_name:"cloudflare-dns.com"}, tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI},
        {type:"https", tag:"dns-doh-backup", server:"8.8.8.8", path:"/dns-query", tls:{enabled:true, server_name:"dns.google"}, tcp_keep_alive:$TCPKA, tcp_keep_alive_interval:$TCPKAI},
        {type:"udp", tag:"dns-udp-fallback", server:"1.0.0.1"}
      ],
      final:"dns-doh-primary",
      strategy:"prefer_ipv4",
      cache_capacity:4096
    },
    endpoints: (if warp_ready then [warp_endpoint] else [] end),
    inbounds:[
      (inbound_vless_flow($P1) + {tag:"vless-reality"}),
      (inbound_vless($P2) + {tag:"vless-grpcr", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($P3) + {tag:"trojan-reality"}),
      (inbound_hy2($P4) + {tag:"hy2"}),
      (inbound_vmess_ws($P5) + {tag:"vmess-ws"}),
      (inbound_hy2_obfs($P6) + {tag:"hy2-obfs"}),
      (inbound_ss2022($P7) + {tag:"ss2022"}),
      (inbound_ss($P8) + {tag:"ss"}),
      (inbound_tuic($P9) + {tag:"tuic-v5"}),
      (inbound_anytls($P10) + {tag:"anytls"}),

      (inbound_vless_flow($PW1) + {tag:"vless-reality-warp"}),
      (inbound_vless($PW2) + {tag:"vless-grpcr-warp", transport:{type:"grpc", service_name:$GRPC}}),
      (inbound_trojan($PW3) + {tag:"trojan-reality-warp"}),
      (inbound_hy2($PW4) + {tag:"hy2-warp"}),
      (inbound_vmess_ws($PW5) + {tag:"vmess-ws-warp"}),
      (inbound_hy2_obfs($PW6) + {tag:"hy2-obfs-warp"}),
      (inbound_ss2022($PW7) + {tag:"ss2022-warp"}),
      (inbound_ss($PW8) + {tag:"ss-warp"}),
      (inbound_tuic($PW9) + {tag:"tuic-v5-warp"}),
      (inbound_anytls($PW10) + {tag:"anytls-warp"})
    ],
    outbounds: ([direct_outbound]
      + (if custom_uses_outbound("direct-ipv4") then [direct_ipv4_outbound] else [] end)
      + (if custom_uses_outbound("direct-ipv6") then [direct_ipv6_outbound] else [] end)
      + custom_outbounds),
    route: route_config
  }' > "$TMP_CONF"; then
    rm -f "$TMP_CONF"
    warn "生成 sing-box JSON 配置失败，已保留原配置"
    return 1
  fi
  if [[ -x "$BIN_PATH" ]] && ! "$BIN_PATH" check -c "$TMP_CONF"; then
    rm -f "$TMP_CONF"
    warn "sing-box 配置校验失败，已保留原配置"
    return 1
  fi
  if ! mv -f "$TMP_CONF" "$CONF_JSON"; then
    rm -f "$TMP_CONF"
    warn "替换 sing-box 配置失败，已保留原配置"
    return 1
  fi
  save_env
}

# ===== 防火墙 =====
open_firewall(){
  local rules=()
  rules+=("${PORT_VLESSR}/tcp" "${PORT_VLESS_GRPCR}/tcp" "${PORT_TROJANR}/tcp" "${PORT_VMESS_WS}/tcp")
  rules+=("${PORT_HY2}/udp" "${PORT_HY2_OBFS}/udp" "${PORT_TUIC}/udp" "${PORT_ANYTLS}/tcp")
  rules+=("${PORT_SS2022}/tcp" "${PORT_SS2022}/udp" "${PORT_SS}/tcp" "${PORT_SS}/udp")
  rules+=("${PORT_VLESSR_W}/tcp" "${PORT_VLESS_GRPCR_W}/tcp" "${PORT_TROJANR_W}/tcp" "${PORT_VMESS_WS_W}/tcp")
  rules+=("${PORT_HY2_W}/udp" "${PORT_HY2_OBFS_W}/udp" "${PORT_TUIC_W}/udp" "${PORT_ANYTLS_W}/tcp")
  rules+=("${PORT_SS2022_W}/tcp" "${PORT_SS2022_W}/udp" "${PORT_SS_W}/tcp" "${PORT_SS_W}/udp")
  if [[ "$TLS_CERT_MODE" == acme ]]; then
    [[ "$TLS_ACME_DISABLE_HTTP_CHALLENGE" == false ]] && rules+=("80/tcp")
    [[ "$TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE" == false ]] && rules+=("443/tcp")
  fi
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q -E "active|活跃"; then
    for r in "${rules[@]}"; do ufw allow "$r" >/dev/null 2>&1 || true; done; ufw reload >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    systemctl enable --now firewalld >/dev/null 2>&1 || true
    for r in "${rules[@]}"; do firewall-cmd --permanent --add-port="$r" >/dev/null 2>&1 || true; done; firewall-cmd --reload >/dev/null 2>&1 || true
  else
    local p proto
    for r in "${rules[@]}"; do p="${r%/*}"; proto="${r#*/}";
      if [[ "$proto" == tcp ]]; then iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT; fi
      if [[ "$proto" == udp ]]; then iptables -C INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p udp --dport "$p" -j ACCEPT; fi
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi
}

# ===== 分享链接（分组输出 + 提示） =====
print_links_grouped(){
  load_env; load_creds; load_ports
  local ip; ip=$(get_ip)
  local tls_host tls_security_query tls_tip links_tmp l
  local links_direct=() links_warp=()
  if [[ "$TLS_CERT_MODE" != "self_signed" && -n "$TLS_DOMAIN" ]]; then
    tls_host="$TLS_DOMAIN"
    tls_security_query="insecure=0&sni=$(urlenc "$TLS_DOMAIN")"
    if tls_uses_public_certificate; then
      tls_tip="Hysteria2 / TUIC / AnyTLS 已使用公开有效证书并校验证书"
    else
      tls_tip="证书当前无法通过公开 CA 校验；导入链接仍保持安全校验，修复证书前连接会失败"
    fi
  else
    tls_host="$ip"
    tls_security_query="insecure=1&sni=$(urlenc "$REALITY_SERVER")"
    tls_tip="Hysteria2 / TUIC / AnyTLS 使用自签证书并已允许跳过证书验证"
  fi
  # 直连10
  links_direct+=("vless://${UUID}@${ip}:${PORT_VLESSR}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality")
  links_direct+=("vless://${UUID}@${ip}:${PORT_VLESS_GRPCR}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality")
  links_direct+=("trojan://${UUID}@${ip}:${PORT_TROJANR}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality")
  links_direct+=("hy2://$(urlenc "${HY2_PWD}")@${tls_host}:${PORT_HY2}?${tls_security_query}#hysteria2")
  local VMESS_JSON; VMESS_JSON=$(cat <<JSON
{"v":"2","ps":"vmess-ws","add":"${ip}","port":"${PORT_VMESS_WS}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_direct+=("vmess://$(printf "%s" "$VMESS_JSON" | b64enc)")
  links_direct+=("hy2://$(urlenc "${HY2_PWD2}")@${tls_host}:${PORT_HY2_OBFS}?${tls_security_query}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs")
  links_direct+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${ip}:${PORT_SS2022}#ss2022")
  links_direct+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${ip}:${PORT_SS}#ss")
  links_direct+=("tuic://${UUID}:$(urlenc "${UUID}")@${tls_host}:${PORT_TUIC}?congestion_control=bbr&alpn=h3&${tls_security_query}#tuic-v5")
  links_direct+=("anytls://$(urlenc "${ANYTLS_PWD}")@${tls_host}:${PORT_ANYTLS}?${tls_security_query}&alpn=h2,http/1.1&fp=chrome#anytls")

  # WARP 10
  links_warp+=("vless://${UUID}@${ip}:${PORT_VLESSR_W}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#vless-reality-warp")
  links_warp+=("vless://${UUID}@${ip}:${PORT_VLESS_GRPCR_W}?encryption=none&security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=grpc&serviceName=${GRPC_SERVICE}#vless-grpc-reality-warp")
  links_warp+=("trojan://${UUID}@${ip}:${PORT_TROJANR_W}?security=reality&sni=${REALITY_SERVER}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}&type=tcp#trojan-reality-warp")
  links_warp+=("hy2://$(urlenc "${HY2_PWD}")@${tls_host}:${PORT_HY2_W}?${tls_security_query}#hysteria2-warp")
  local VMESS_JSON_W; VMESS_JSON_W=$(cat <<JSON
{"v":"2","ps":"vmess-ws-warp","add":"${ip}","port":"${PORT_VMESS_WS_W}","id":"${UUID}","aid":"0","net":"ws","type":"none","host":"","path":"${VMESS_WS_PATH}","tls":""}
JSON
  )
  links_warp+=("vmess://$(printf "%s" "$VMESS_JSON_W" | b64enc)")
  links_warp+=("hy2://$(urlenc "${HY2_PWD2}")@${tls_host}:${PORT_HY2_OBFS_W}?${tls_security_query}&alpn=h3&obfs=salamander&obfs-password=$(urlenc "${HY2_OBFS_PWD}")#hysteria2-obfs-warp")
  links_warp+=("ss://$(printf "%s" "2022-blake3-aes-256-gcm:${SS2022_KEY}" | b64enc)@${ip}:${PORT_SS2022_W}#ss2022-warp")
  links_warp+=("ss://$(printf "%s" "aes-256-gcm:${SS_PWD}" | b64enc)@${ip}:${PORT_SS_W}#ss-warp")
  links_warp+=("tuic://${UUID}:$(urlenc "${UUID}")@${tls_host}:${PORT_TUIC_W}?congestion_control=bbr&alpn=h3&${tls_security_query}#tuic-v5-warp")
  links_warp+=("anytls://$(urlenc "${ANYTLS_PWD}")@${tls_host}:${PORT_ANYTLS_W}?${tls_security_query}&alpn=h2,http/1.1&fp=chrome#anytls-warp")

  mkdir -p "$(dirname "$SHARE_LINKS_FILE")"
  links_tmp="$(mktemp "${SHARE_LINKS_FILE}.tmp.XXXXXX")" || {
    warn "无法创建导入链接临时文件"
    return 1
  }
  {
    printf '%s\n' "${links_direct[@]}"
    printf '%s\n' "${links_warp[@]}"
  } > "$links_tmp"
  chmod 600 "$links_tmp"
  if ! mv -f "$links_tmp" "$SHARE_LINKS_FILE"; then
    rm -f "$links_tmp"
    warn "无法更新导入链接文件：$SHARE_LINKS_FILE"
    return 1
  fi

  echo -e "${C_BLUE}${C_BOLD}分享链接（20 个）${C_RESET}"
  hr
  echo -e "${C_CYAN}${C_BOLD}【直连节点（10）】${C_RESET}（vless-reality / vless-grpc-reality / trojan-reality / vmess-ws / hy2 / hy2-obfs / ss2022 / ss / tuic / anytls）"
  for l in "${links_direct[@]}"; do echo "  $l"; done
  hr
  echo -e "${C_CYAN}${C_BOLD}【WARP 节点（10）】${C_RESET}（同上 10 种，带 -warp）"
  echo -e "${C_DIM}说明：带 -warp 的 10 个节点走 Cloudflare WARP 出口，流媒体解锁更友好${C_RESET}"
  echo -e "${C_DIM}提示：${tls_tip}；客户端如不识别 AnyTLS 链接，可手动按域名、端口、SNI 和密码添加${C_RESET}"
  for l in "${links_warp[@]}"; do echo "  $l"; done
  hr
  info "导入链接已更新：$SHARE_LINKS_FILE"
}

# ===== 自定义路由菜单 =====
apply_custom_routing(){
  local route_bak="${1:-}" conf_bak rollback_failed=0
  if ! normalize_route_file "$ROUTE_JSON" | validate_route_references -; then
    if [[ -n "$route_bak" && -f "$route_bak" ]] && ! cp "$route_bak" "$ROUTE_JSON"; then
      warn "分流引用校验失败，且无法恢复原分流配置。"
      return 1
    fi
    warn "分流引用校验失败，已回滚自定义路由。"
    return 1
  fi
  conf_bak="$(mktemp)" || return 1
  if [[ -f "$CONF_JSON" ]] && ! cp "$CONF_JSON" "$conf_bak"; then
    [[ -n "$route_bak" && -f "$route_bak" ]] && cp "$route_bak" "$ROUTE_JSON"
    rm -f "$conf_bak"
    warn "备份运行配置失败，已取消应用。"
    return 1
  fi

  if ! write_config; then
    [[ -n "$route_bak" && -f "$route_bak" ]] && cp "$route_bak" "$ROUTE_JSON"
    [[ -s "$conf_bak" ]] && cp "$conf_bak" "$CONF_JSON"
    rm -f "$conf_bak"
    warn "生成配置失败，已回滚自定义路由。"
    return 1
  fi

  if [[ -x "$BIN_PATH" ]] && ! "$BIN_PATH" check -c "$CONF_JSON"; then
    [[ -n "$route_bak" && -f "$route_bak" ]] && cp "$route_bak" "$ROUTE_JSON"
    [[ -s "$conf_bak" ]] && cp "$conf_bak" "$CONF_JSON"
    rm -f "$conf_bak"
    warn "sing-box 配置检查失败，已回滚自定义路由。"
    return 1
  fi

  if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
    if ! { systemctl restart "${SYSTEMD_SERVICE}" && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; }; then
      if [[ -n "$route_bak" && -f "$route_bak" ]]; then
        cp "$route_bak" "$ROUTE_JSON" || rollback_failed=1
      fi
      if [[ -s "$conf_bak" ]]; then
        cp "$conf_bak" "$CONF_JSON" || rollback_failed=1
      fi
      if (( rollback_failed != 0 )); then
        warn "服务重启失败，恢复配置时出错；运行配置备份：$conf_bak"
        return 1
      fi
      rm -f "$conf_bak"
      if systemctl restart "${SYSTEMD_SERVICE}" && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
        warn "服务重启失败，已回滚分流配置并恢复服务。"
      else
        warn "已回滚分流配置，但服务仍无法启动，请检查服务日志。"
      fi
      return 1
    fi
    info "自定义路由已应用并重启服务。"
  else
    info "自定义路由已写入配置；服务未运行，未自动重启。"
  fi
  rm -f "$conf_bak"
}

print_custom_routes(){
  ensure_route_file
  local ip4 ip6 def_outbound
  ip4="$(default_ipv4_address || true)"
  ip6="$(default_ipv6_address || true)"
  def_outbound="$(jq -r '.default_outbound // "direct"' "$ROUTE_JSON" 2>/dev/null || echo "direct")"
  echo -e "${C_CYAN}当前本机出口:${C_RESET} IPv4=${ip4:-未检测到} IPv6=${ip6:-未检测到}"
  echo -e "${C_CYAN}非 Warp 节点默认出口:${C_RESET} ${def_outbound}"
  echo
  jq -r --arg cur_default "$def_outbound" '
    def simple_match_text:
      [(.domain // [] | map("domain:" + .))[],
       (.domain_suffix // [] | map("suffix:" + .))[],
       (.domain_keyword // [] | map("keyword:" + .))[],
       (.domain_regex // [] | map("regex:" + .))[],
       (.rule_set // [] | map("rule-set:" + .))[]] | join(", ");
    def match_text:
      if .type == "logical" then
        [.rules[] | ((.name // "") as $name
          | (if $name == "" then "" else $name + ": " end) + (. | match_text))]
        | "OR [" + join("；") + "]"
      else simple_match_text end;
    def display_name:
      if (.name // "") != "" then .name
      elif .type == "logical" then "合并规则（\(.rules | length) 个分支）"
      else "未命名" end;
    "自定义路由规则:",
    (if ((.rules // []) | length) == 0 then
      "  （无）"
    else
      (.rules // [] | to_entries[] | "  \(.key + 1)) \(.value | display_name) -> \(if .value.action == "reject" then "block（阻断）" else .value.outbound end) | \(.value | match_text)")
    end),
    "",
    "导入的远程出口:",
    (if ((.outbounds // []) | length) == 0 then
      "  （无）"
    else
      (.outbounds // [] | to_entries[] | "  \(.key + 1)) \(.value.tag) [\(.value.type)]" + (if .value.tag == $cur_default then " (当前默认出口)" else "" end))
    end)
  ' "$ROUTE_JSON"
}

select_route_outbound(){
  local ip4 ip6 choice idx tag
  local -a imported
  SBP_SELECTED_OUTBOUND=""
  SBP_SELECTED_ACTION="route"
  ip4="$(default_ipv4_address || true)"
  ip6="$(default_ipv6_address || true)"
  mapfile -t imported < <(jq -r '.outbounds[]?.tag' "$ROUTE_JSON" | tr -d '\r')

  echo "选择规则目标："
  echo "  1) 本机 WARP 出口（warp：Cloudflare WARP 双栈）"
  echo "  2) 本机双栈出口（direct：IPv4 + IPv6 双栈直连，当前 IPv4=${ip4:-未检测到} IPv6=${ip6:-未检测到}）"
  echo "  3) 本机 IPv4 出口（direct-ipv4：仅 IPv4 直连，当前 ${ip4:-未检测到}）"
  echo "  4) 本机 IPv6 出口（direct-ipv6：仅 IPv6 直连，当前 ${ip6:-未检测到}）"
  echo "  5) block（阻断连接）"
  idx=6
  for tag in "${imported[@]}"; do
    echo "  ${idx}) 导入出口：${tag}"
    idx=$((idx+1))
  done
  read -rp "选择目标: " choice || return 1
  choice="${choice//$'\r'/}"
  case "$choice" in
    1)
      if ! load_warp >/dev/null 2>&1; then
        warn "尚未检测到 WARP 配置；应用时会尝试生成，失败则该规则无法通过检查。"
      fi
      SBP_SELECTED_OUTBOUND="warp"
      ;;
    2)
      SBP_SELECTED_OUTBOUND="direct"
      ;;
    3)
      [[ -n "$ip4" ]] || warn "未检测到本机 IPv4，该出口将无法建立连接。"
      SBP_SELECTED_OUTBOUND="direct-ipv4"
      ;;
    4)
      [[ -n "$ip6" ]] || warn "未检测到本机 IPv6，该出口将无法建立连接。"
      warn "仅 IPv6 出口无法访问没有 AAAA 记录的站点；客户端直接以 IPv4 地址（而非域名）发起的连接也不受此设置约束。"
      SBP_SELECTED_OUTBOUND="direct-ipv6"
      ;;
    5)
      SBP_SELECTED_ACTION="reject"
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((10#$choice-6))
        if (( idx >= 0 && idx < ${#imported[@]} )); then
          SBP_SELECTED_OUTBOUND="${imported[$idx]}"
        fi
      fi
      ;;
  esac
  [[ "$SBP_SELECTED_ACTION" == "reject" || -n "$SBP_SELECTED_OUTBOUND" ]] || { warn "无效目标选择"; return 1; }
}

add_custom_route_rule(){
  ensure_route_file
  select_route_outbound || return 1
  echo
  echo "输入匹配项，逗号或空格分隔。"
  echo "示例：geosite:netflix, suffix:openai.com, domain:example.com, keyword:google"
  echo "简写：netflix 会按 geosite 处理；example.com 会按域名后缀处理。"
  local matches name match_json route_bak tmp status=0
  read -rp "匹配项: " matches || return 1
  matches="${matches//$'\r'/}"
  match_json="$(parse_route_match_json "$matches")"
  if ! printf '%s' "$match_json" | jq -e '
    (((.domain // []) | length)
    + ((.domain_suffix // []) | length)
    + ((.domain_keyword // []) | length)
    + ((.domain_regex // []) | length)
    + ((.rule_set // []) | length)) > 0
  ' >/dev/null; then
    warn "没有可用匹配项，已取消。"
    return 1
  fi
  read -rp "规则名称（可留空）: " name || true
  name="${name//$'\r'/}"

  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c --argjson match "$match_json" --arg outbound "$SBP_SELECTED_OUTBOUND" --arg action "$SBP_SELECTED_ACTION" --arg name "$name" '
    .rules = (.rules // [])
    | .rule_set = (.rule_set // [])
    | .outbounds = (.outbounds // [])
    | .rules += [($match | del(.rule_set_defs)
        + (if $action == "reject" then {action:"reject"} else {outbound:$outbound} end)
        + (if $name != "" then {name:$name} else {} end))]
    | .rule_set = ((.rule_set + ($match.rule_set_defs // [])) | unique_by(.tag))
  ' "$ROUTE_JSON" > "$tmp"; then
    if mv "$tmp" "$ROUTE_JSON"; then
      apply_custom_routing "$route_bak" || status=$?
    else
      rm -f "$tmp"
      warn "保存路由规则失败。"
      status=1
    fi
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "写入路由规则失败。"
    status=1
  fi
  rm -f "$route_bak"
  return "$status"
}

import_custom_route_outbound(){
  ensure_route_file
  local tag raw outbound src_tag route_bak tmp
  read -rp "给这个远程出口起一个 tag（例如 hk-vps）: " tag || return 1
  tag="${tag//$'\r'/}"
  if ! valid_route_tag "$tag"; then
    warn "tag 只能包含字母、数字、点、下划线、短横线、@、!。"
    return 1
  fi
  case "$tag" in
    direct|direct-ipv4|direct-ipv6|warp)
      warn "该 tag 是内置出口，请换一个名称。"
      return 1
      ;;
  esac
  if jq -e --arg tag "$tag" 'any(.outbounds[]?; .tag == $tag)' "$ROUTE_JSON" >/dev/null; then
    read -rp "已存在同名出口，是否覆盖？[y/N] " yn || return 1
    yn="${yn//$'\r'/}"
    [[ "$yn" =~ ^[Yy]$ ]] || return 1
  fi

  echo "粘贴分享链接（支持 VLESS / Trojan / Hysteria2 / VMess / SS / TUIC / AnyTLS / Socks5 / HTTP 等）、sing-box outbound JSON，或输入包含 sing-box 配置的文件路径。"
  read -r -p "节点配置: " raw || return 1
  raw="${raw//$'\r'/}"
  [[ -f "$raw" ]] && raw="$(cat "$raw")"

  if printf '%s' "$raw" | jq -e 'type == "object" and ((.outbounds // empty) | type == "array")' >/dev/null 2>&1; then
    echo "文件内可用 outbounds："
    printf '%s' "$raw" | jq -r '.outbounds[]?.tag' | sed 's/^/  - /'
    read -rp "选择要导入的源 tag: " src_tag || return 1
    src_tag="${src_tag//$'\r'/}"
    outbound="$(printf '%s' "$raw" | jq -c --arg src "$src_tag" --arg tag "$tag" '
      .outbounds[] | select(.tag == $src) | .tag = $tag
      | if (has("server") and (has("domain_resolver") | not)) then .domain_resolver = "dns-doh-primary" else . end
      | del(.domain_strategy)
    ' | head -n1)"
  elif printf '%s' "$raw" | jq -e 'type == "object" and (.type | type == "string")' >/dev/null 2>&1; then
    outbound="$(printf '%s' "$raw" | jq -c --arg tag "$tag" '
      .tag = $tag
      | if (has("server") and (has("domain_resolver") | not)) then .domain_resolver = "dns-doh-primary" else . end
      | del(.domain_strategy)
    ')"
  else
    outbound="$(share_link_to_outbound "$raw" "$tag" 2>/dev/null || true)"
  fi

  if [[ -z "${outbound:-}" ]] || ! printf '%s' "$outbound" | jq -e 'type == "object" and (.type | type == "string") and (.tag | type == "string")' >/dev/null; then
    warn "无法识别该节点配置。建议粘贴 sing-box outbound JSON，或使用标准分享链接（VLESS / Trojan / Hysteria2 / VMess / SS / TUIC / AnyTLS / Socks5 / HTTP 等）。"
    return 1
  fi

  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c --argjson outbound "$outbound" '
    .rules = (.rules // [])
    | .rule_set = (.rule_set // [])
    | .outbounds = (((.outbounds // []) | map(select(.tag != $outbound.tag))) + [$outbound])
  ' "$ROUTE_JSON" > "$tmp"; then
    mv "$tmp" "$ROUTE_JSON"
    apply_custom_routing "$route_bak"
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "导入远程出口失败。"
  fi
  rm -f "$route_bak"
}

set_custom_default_outbound(){
  ensure_route_file
  local current_outbound choice target route_bak tmp ip4 ip6 idx tag
  local -a imported
  current_outbound="$(jq -r '.default_outbound // "direct"' "$ROUTE_JSON" 2>/dev/null || echo "direct")"
  ip4="$(default_ipv4_address || true)"
  ip6="$(default_ipv6_address || true)"
  mapfile -t imported < <(jq -r '.outbounds[]?.tag' "$ROUTE_JSON" | tr -d '\r')

  echo -e "当前非 Warp 节点出口: ${C_GREEN}${current_outbound}${C_RESET}"
  echo "请选择要作为非 Warp 节点默认出口的目标（支持 V4 / V6 / 双栈 / 远程节点）："
  echo "  1) 本机双栈出口（direct：IPv4 + IPv6 双栈，当前 IPv4=${ip4:-未检测到} IPv6=${ip6:-未检测到}）"
  echo "  2) 本机 IPv4 出口（direct-ipv4：仅 IPv4，当前 ${ip4:-未检测到}）"
  echo "  3) 本机 IPv6 出口（direct-ipv6：仅 IPv6，当前 ${ip6:-未检测到}）"
  echo "  4) 本机 WARP 出口（warp：Cloudflare WARP 双栈）"
  idx=5
  for tag in "${imported[@]}"; do
    if [[ "$tag" == "$current_outbound" ]]; then
      echo "  ${idx}) 导入出口：${tag} (当前选中)"
    else
      echo "  ${idx}) 导入出口：${tag}"
    fi
    idx=$((idx+1))
  done
  read -rp "选择出口 [当前: ${current_outbound}]: " choice || return 1
  choice="${choice//$'\r'/}"
  [[ -z "$choice" ]] && { info "未更改出口设置"; return 0; }

  case "$choice" in
    1) target="direct" ;;
    2)
      [[ -n "$ip4" ]] || warn "未检测到本机 IPv4，该出口将无法建立连接。"
      target="direct-ipv4"
      ;;
    3)
      [[ -n "$ip6" ]] || warn "未检测到本机 IPv6，该出口将无法建立连接。"
      warn "仅 IPv6 出口无法访问没有 AAAA 记录的站点；客户端直接以 IPv4 地址（而非域名）发起的连接也不受此设置约束。"
      target="direct-ipv6"
      ;;
    4)
      if ! load_warp >/dev/null 2>&1; then
        warn "尚未检测到 WARP 配置；应用时会尝试生成，失败则无法生效。"
      fi
      target="warp"
      ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]]; then
        idx=$((choice-5))
        if (( idx >= 0 && idx < ${#imported[@]} )); then
          target="${imported[$idx]}"
        fi
      fi
      ;;
  esac

  if [[ -z "${target:-}" ]]; then
    warn "无效出口选择"
    return 1
  fi

  # current_outbound 在键缺失时是回落值 direct，此时即使选中 direct 也必须落盘，
  # 否则设置看似成功却从未写入 routes.json。
  if [[ "$target" == "$current_outbound" ]] \
     && jq -e 'has("default_outbound")' "$ROUTE_JSON" >/dev/null 2>&1; then
    info "出口未发生变化：${target}"
    return 0
  fi

  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c --arg target "$target" '.default_outbound = $target' "$ROUTE_JSON" > "$tmp"; then
    mv "$tmp" "$ROUTE_JSON"
    if apply_custom_routing "$route_bak"; then
      info "非 Warp 节点默认出口已成功切换为：${target}"
    fi
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "保存出口配置失败。"
  fi
  rm -f "$route_bak"
}

remove_custom_route_rule(){
  ensure_route_file
  local idx route_bak tmp
  print_custom_routes
  read -rp "输入要删除的规则编号: " idx || return 1
  [[ "$idx" =~ ^[0-9]+$ ]] || { warn "编号无效"; return 1; }
  idx=$((idx-1))
  if ! jq -e --argjson idx "$idx" '(.rules // [])[$idx] != null' "$ROUTE_JSON" >/dev/null; then
    warn "规则不存在。"
    return 1
  fi
  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c --argjson idx "$idx" '
    .rules = ((.rules // []) | del(.[$idx]))
    | ([.rules[] | recurse(if .type == "logical" then .rules[] else empty end) | .rule_set[]?] | unique) as $used
    | .rule_set = ((.rule_set // []) | map(. as $rs | select($used | index($rs.tag))))
  ' "$ROUTE_JSON" > "$tmp"; then
    mv "$tmp" "$ROUTE_JSON"
    apply_custom_routing "$route_bak"
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "删除规则失败。"
  fi
  rm -f "$route_bak"
}

remove_custom_route_outbound(){
  ensure_route_file
  local tag route_bak tmp
  print_custom_routes
  read -rp "输入要删除的远程出口 tag: " tag || return 1
  if jq -e --arg tag "$tag" 'any(.rules[]?; .outbound == $tag)' "$ROUTE_JSON" >/dev/null; then
    warn "该出口仍被路由规则使用，请先删除对应规则。"
    return 1
  fi
  if jq -e --arg tag "$tag" '(.default_outbound // "direct") == $tag' "$ROUTE_JSON" >/dev/null; then
    warn "该出口当前正作为非 Warp 节点的默认出口使用，请先将其切换为其他出口。"
    return 1
  fi
  if ! jq -e --arg tag "$tag" 'any(.outbounds[]?; .tag == $tag)' "$ROUTE_JSON" >/dev/null; then
    warn "远程出口不存在。"
    return 1
  fi
  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c --arg tag "$tag" '.outbounds = ((.outbounds // []) | map(select(.tag != $tag)))' "$ROUTE_JSON" > "$tmp"; then
    mv "$tmp" "$ROUTE_JSON"
    apply_custom_routing "$route_bak"
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "删除远程出口失败。"
  fi
  rm -f "$route_bak"
}

clear_custom_route_rules(){
  ensure_route_file
  local route_bak tmp yn
  read -rp "确认清空所有自定义路由规则？导入出口与默认出口设置会保留。[y/N] " yn || return 1
  [[ "$yn" =~ ^[Yy]$ ]] || return 1
  route_bak="$(mktemp)"
  cp "$ROUTE_JSON" "$route_bak"
  tmp="$(mktemp)"
  if jq -c '.rules = [] | .rule_set = [] | .outbounds = (.outbounds // []) | .default_outbound = (.default_outbound // "direct")' "$ROUTE_JSON" > "$tmp"; then
    mv "$tmp" "$ROUTE_JSON"
    apply_custom_routing "$route_bak"
  else
    rm -f "$tmp"
    cp "$route_bak" "$ROUTE_JSON"
    warn "清空规则失败。"
  fi
  rm -f "$route_bak"
}

organize_custom_route_rules()(
  local work_dir choice target count segments mode=adjacent idx line label route_bak yn candidate_rows
  local -a candidates
  [[ -s "$ROUTE_JSON" ]] || { info "没有可整理的分流规则。"; return 0; }
  ensure_dirs || return 1
  work_dir=$(mktemp -d "$SB_DIR/.routes-organize.XXXXXX") || return 1
  trap 'rm -f -- "$work_dir/original.json" "$work_dir/current.json" "$work_dir/candidate.json"; rmdir -- "$work_dir"' EXIT
  cp "$ROUTE_JSON" "$work_dir/original.json" || { warn "读取分流配置失败。"; return 1; }
  if ! normalize_route_file "$work_dir/original.json" > "$work_dir/current.json" \
      || ! validate_route_references "$work_dir/current.json"; then
    warn "当前分流配置无效，未修改任何规则。"
    return 1
  fi
  candidate_rows=$(jq -r '
    [.rules[] | if .action == "reject" then "reject:" else "route:" + .outbound end] as $targets
    | (reduce $targets[] as $target ([]; if index($target) == null then . + [$target] else . end))[] as $target
    | ([$targets[] | select(. == $target)] | length) as $count
    | select($count > 1) | [$target, $count] | @tsv
  ' "$work_dir/current.json" | tr -d '\r') || { warn "读取整理目标失败。"; return 1; }
  candidates=()
  if [[ -n "$candidate_rows" ]]; then mapfile -t candidates <<< "$candidate_rows"; fi
  if (( ${#candidates[@]} == 0 )); then
    info "没有相同出口或 block 的重复规则需要合并。"
    return 0
  fi
  echo "选择要整理的目标："
  for idx in "${!candidates[@]}"; do
    line="${candidates[$idx]}"
    target="${line%%$'\t'*}"
    count="${line#*$'\t'}"
    label="${target#route:}"
    [[ "$target" == "reject:" ]] && label="block（阻断）"
    printf '  %s) %s（%s 条规则）\n' "$((idx+1))" "$label" "$count"
  done
  echo "  0) 取消"
  read -rp "选择目标 [0]: " choice || return 1
  choice="${choice//$'\r'/}"
  case "${choice:-0}" in 0|q|Q) return 0 ;; esac
  if [[ ! "$choice" =~ ^[0-9]{1,6}$ ]]; then warn "无效目标选择。"; return 1; fi
  idx=$((10#$choice-1))
  if (( idx < 0 || idx >= ${#candidates[@]} )); then warn "无效目标选择。"; return 1; fi
  line="${candidates[$idx]}"
  target="${line%%$'\t'*}"
  label="${target#route:}"
  [[ "$target" == "reject:" ]] && label="block（阻断）"
  segments=$(jq -r --arg target "$target" '
    reduce .rules[] as $rule ({count:0, previous:false};
      ($rule | if .action == "reject" then "reject:" else "route:" + .outbound end) as $key
      | if $key == $target then
          .count += (if .previous then 0 else 1 end) | .previous = true
        else .previous = false end)
    | .count
  ' "$work_dir/current.json" | tr -d '\r') || return 1
  if (( segments > 1 )); then
    echo "  1) 仅合并相邻规则（保持优先级）"
    echo "  2) 合并该目标的全部规则（可能改变优先级）"
    echo "  0) 取消"
    read -rp "整理方式 [1]: " choice || return 1
    choice="${choice//$'\r'/}"
    case "${choice:-1}" in
      1) mode=adjacent ;;
      2) mode=all ;;
      0|q|Q) return 0 ;;
      *) warn "无效整理方式。"; return 1 ;;
    esac
  fi
  if ! consolidate_route_rules "$work_dir/current.json" "$target" "$mode" > "$work_dir/candidate.json"; then
    warn "整理失败，未修改现有规则。"
    return 1
  fi
  if ! normalize_route_file "$work_dir/candidate.json" >/dev/null \
      || ! validate_route_references "$work_dir/candidate.json"; then
    warn "整理结果校验失败，未修改现有规则。"
    return 1
  fi
  if jq -en --slurpfile current "$work_dir/current.json" --slurpfile candidate "$work_dir/candidate.json" \
      '$current[0] == $candidate[0]' >/dev/null; then
    info "该目标没有相邻规则可合并，配置保持不变。"
    return 0
  fi
  # jq 1.6 rejects reserved keywords such as "label" even as variable names.
  jq -nr --arg target_label "$label" --slurpfile current "$work_dir/current.json" --slurpfile candidate "$work_dir/candidate.json" \
    '"整理目标：\($target_label)；总规则数：\($current[0].rules | length) → \($candidate[0].rules | length)"' || return 1
  if [[ "$mode" == "all" ]]; then
    warn "合并结果放在该目标第一条规则的位置；跨过的其他出口或 block 规则若有重叠匹配，优先级会改变。"
  fi
  read -rp "确认整理并应用（服务运行时会重启）？[y/N] " yn || return 1
  [[ "${yn//$'\r'/}" =~ ^[Yy]$ ]] || return 0
  if ! jq -en --slurpfile original "$work_dir/original.json" --slurpfile current "$ROUTE_JSON" \
      '$original[0] == $current[0]' >/dev/null; then
    warn "分流配置已被其他操作修改，请重新整理。"
    return 1
  fi
  (umask 077; mkdir -p "$SB_DIR/backups") || return 1
  route_bak=$(mktemp "$SB_DIR/backups/routes-organize-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
  if ! cp "$ROUTE_JSON" "$route_bak"; then
    warn "备份分流配置失败，已取消整理。"
    return 1
  fi
  if ! chmod 600 "$work_dir/candidate.json" || ! mv -f -- "$work_dir/candidate.json" "$ROUTE_JSON"; then
    warn "保存整理结果失败。"
    return 1
  fi
  info "原分流配置已备份：$route_bak"
  apply_custom_routing "$route_bak"
)

export_custom_route_rules()(
  local destination="${1:-}" default_path tmp export_dir yn
  [[ -s "$ROUTE_JSON" ]] || { warn "没有可导出的分流配置。"; return 1; }
  default_path="$SB_DIR/routes-export-$(date +%Y%m%d-%H%M%S).json"
  if [[ -z "$destination" ]]; then
    read -rp "导出文件路径 [$default_path]: " destination || return 1
    destination="${destination//$'\r'/}"
    destination="${destination:-$default_path}"
  fi
  if [[ -L "$destination" || -d "$destination" ]] || { [[ -e "$destination" ]] && [[ ! -f "$destination" ]]; }; then
    warn "导出目标必须是普通文件路径。"
    return 1
  fi
  if [[ "$destination" -ef "$ROUTE_JSON" || "$destination" -ef "$CONF_JSON" ]]; then
    warn "请使用独立的导出文件，不能覆盖当前分流或运行配置。"
    return 1
  fi
  export_dir=$(dirname -- "$destination")
  [[ -d "$export_dir" ]] || { warn "导出目录不存在：$export_dir"; return 1; }
  tmp=$(mktemp "$export_dir/.routes-export.XXXXXX") || { warn "无法创建导出文件。"; return 1; }
  trap 'rm -f -- "$tmp"' EXIT
  if ! normalize_route_file "$ROUTE_JSON" | jq '{format:"sing-box-plus-routes", version:1} + .' > "$tmp" \
      || ! validate_route_references "$tmp"; then
    warn "当前分流配置无效，导出已取消。"
    return 1
  fi
  if [[ -f "$destination" ]]; then
    read -rp "导出文件已存在，确认覆盖？[y/N] " yn || return 1
    [[ "${yn//$'\r'/}" =~ ^[Yy]$ ]] || return 0
  fi
  if ! chmod 600 "$tmp" || ! mv -f -- "$tmp" "$destination"; then
    warn "保存导出文件失败。"
    return 1
  fi
  info "分流配置已导出：$destination"
  if jq -e '.outbounds | length > 0' "$ROUTE_JSON" >/dev/null; then
    warn "导出文件包含远程出口配置及其凭据，请妥善保管。"
  fi
)

import_custom_route_rules()(
  local source_file="${1:-}" source_dir mode work_dir route_bak yn
  if [[ -z "$source_file" ]]; then
    read -rp "分流规则文件路径: " source_file || return 1
    source_file="${source_file//$'\r'/}"
  fi
  [[ -f "$source_file" && -r "$source_file" ]] || { warn "分流文件不存在或不可读。"; return 1; }
  # Resolve relative paths before passing the filename to jq, including names beginning with a dash.
  source_dir=$(cd -- "$(dirname -- "$source_file")" && pwd) || return 1
  source_file="$source_dir/$(basename -- "$source_file")"
  ensure_dirs || return 1
  work_dir=$(mktemp -d "$SB_DIR/.routes-import.XXXXXX") || return 1
  trap 'rm -f -- "$work_dir/incoming.json" "$work_dir/current.json" "$work_dir/candidate.json"; rmdir -- "$work_dir"' EXIT
  if ! normalize_route_file "$source_file" > "$work_dir/incoming.json"; then
    warn "分流文件校验失败，未修改现有配置。"
    return 1
  fi
  if [[ -s "$ROUTE_JSON" ]]; then
    normalize_route_file "$ROUTE_JSON" > "$work_dir/current.json" || { warn "当前分流配置无效，导入已取消。"; return 1; }
  else
    empty_route_json > "$work_dir/current.json" || return 1
  fi
  echo "  1) 合并（保留现有规则顺序和默认出口）"
  echo "  2) 替换（包含远程出口及默认出口）"
  echo "  0) 取消"
  read -rp "导入方式 [1]: " mode || return 1
  mode="${mode//$'\r'/}"
  case "${mode:-1}" in
    1)
      mode=1
      if ! merge_route_files "$work_dir/current.json" "$work_dir/incoming.json" > "$work_dir/candidate.json"; then
        warn "合并失败；同名出口或规则集的配置必须一致，未修改现有配置。"
        return 1
      fi
      ;;
    2) cp "$work_dir/incoming.json" "$work_dir/candidate.json" || return 1 ;;
    0|q|Q) return 0 ;;
    *) warn "无效导入方式。"; return 1 ;;
  esac
  validate_route_references "$work_dir/candidate.json" || { warn "导入配置的引用不完整，未修改现有配置。"; return 1; }
  load_env
  if [[ "$ENABLE_WARP" != "true" ]] && jq -e '
    .default_outbound == "warp" or any(.rules[]; .outbound == "warp")
    or any(.rule_set[]; .download_detour == "warp")
    or any(.outbounds[]; .detour == "warp")
  ' "$work_dir/candidate.json" >/dev/null; then
    warn "导入配置使用 WARP，请先开启 WARP。"
    return 1
  fi
  if jq -en --slurpfile current "$work_dir/current.json" --slurpfile candidate "$work_dir/candidate.json" \
      '$current[0] == $candidate[0]' >/dev/null; then
    info "分流配置未发生变化，无需重复导入。"
    return 0
  fi
  jq -r '"导入后：\(.rules | length) 条规则，\(.outbounds | length) 个远程出口，默认出口 \(.default_outbound)"' "$work_dir/candidate.json"
  if [[ "$mode" == "2" ]]; then
    read -rp "确认替换现有规则、规则集、远程出口和默认出口？[y/N] " yn || return 1
    [[ "${yn//$'\r'/}" =~ ^[Yy]$ ]] || return 0
  fi
  (umask 077; mkdir -p "$SB_DIR/backups") || return 1
  route_bak=$(mktemp "$SB_DIR/backups/routes-import-$(date +%Y%m%d-%H%M%S)-XXXXXX") || return 1
  if [[ -f "$ROUTE_JSON" ]]; then
    cp "$ROUTE_JSON" "$route_bak" || { warn "备份分流配置失败，已取消导入。"; return 1; }
  else
    cp "$work_dir/current.json" "$route_bak" || return 1
  fi
  if ! chmod 600 "$work_dir/candidate.json" || ! mv -f -- "$work_dir/candidate.json" "$ROUTE_JSON"; then
    warn "保存分流配置失败。"
    return 1
  fi
  info "原分流配置已备份：$route_bak"
  apply_custom_routing "$route_bak"
)

custom_route_menu(){
  ensure_installed_or_hint || { read -rp "回车返回..." _ || true; return 0; }
  ensure_route_file
  while :; do
    clear >/dev/null 2>&1 || true
    hr
    echo -e " ${C_CYAN}自定义路由配置${C_RESET}"
    hr
    print_custom_routes
    hr
    echo -e "  ${C_GREEN}1)${C_RESET} 添加分流规则（含 block）"
    echo -e "  ${C_GREEN}2)${C_RESET} 导入其他 VPS 出口节点"
    echo -e "  ${C_GREEN}3)${C_RESET} 设置非 Warp 节点默认出口 (V4 / V6 / 双栈 / 导入节点)"
    echo -e "  ${C_YELLOW}4)${C_RESET} 删除路由规则"
    echo -e "  ${C_YELLOW}5)${C_RESET} 删除导入出口"
    echo -e "  ${C_RED}6)${C_RESET} 清空自定义路由规则"
    echo -e "  ${C_GREEN}7)${C_RESET} 导入分流规则"
    echo -e "  ${C_GREEN}8)${C_RESET} 导出分流规则"
    echo -e "  ${C_GREEN}9)${C_RESET} 整理分流规则（合并相同出口）"
    echo -e "  ${C_RED}0)${C_RESET} 返回主菜单"
    hr
    read -rp "选择: " op || return 0
    case "${op:-}" in
      1) add_custom_route_rule || true; read -rp "回车继续..." _ || true ;;
      2) import_custom_route_outbound || true; read -rp "回车继续..." _ || true ;;
      3) set_custom_default_outbound || true; read -rp "回车继续..." _ || true ;;
      4) remove_custom_route_rule || true; read -rp "回车继续..." _ || true ;;
      5) remove_custom_route_outbound || true; read -rp "回车继续..." _ || true ;;
      6) clear_custom_route_rules || true; read -rp "回车继续..." _ || true ;;
      7) import_custom_route_rules || true; read -rp "回车继续..." _ || true ;;
      8) export_custom_route_rules || true; read -rp "回车继续..." _ || true ;;
      9) organize_custom_route_rules || true; read -rp "回车继续..." _ || true ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

# ===== 域名、证书与 SNI =====
tls_mode_label(){
  case "$TLS_CERT_MODE" in
    self_signed) echo "自签证书" ;;
    manual) echo "手动证书" ;;
    acme) echo "ACME 自动证书" ;;
    *) echo "未知（$TLS_CERT_MODE）" ;;
  esac
}

configure_reality_sni(){
  local domain
  load_env || true
  read -rp "Reality SNI 域名 [${REALITY_SERVER}]: " domain || return 1
  domain="${domain:-$REALITY_SERVER}"
  domain="${domain%.}"
  domain="${domain,,}"
  valid_tls_domain "$domain" || {
    warn "SNI 域名格式无效：$domain"
    return 1
  }
  REALITY_SERVER="$domain"
}

restore_connection_files(){
  local backup_dir="$1" had_env="$2" had_config="$3" had_cert="$4" had_key="$5"

  if [[ "$had_env" == true ]]; then
    cp -f "$backup_dir/env.conf" "$SB_DIR/env.conf"
  else
    rm -f "$SB_DIR/env.conf"
  fi
  if [[ "$had_config" == true ]]; then
    cp -f "$backup_dir/config.json" "$CONF_JSON"
  else
    rm -f "$CONF_JSON"
  fi
  if [[ "$had_cert" == true ]]; then
    cp -f "$backup_dir/fullchain.pem" "$CERT_DIR/fullchain.pem"
  else
    rm -f "$CERT_DIR/fullchain.pem"
  fi
  if [[ "$had_key" == true ]]; then
    cp -f "$backup_dir/key.pem" "$CERT_DIR/key.pem"
  else
    rm -f "$CERT_DIR/key.pem"
  fi
}

remove_connection_backup(){
  local backup_dir="$1"
  rm -f "$backup_dir/env.conf" "$backup_dir/config.json" \
    "$backup_dir/fullchain.pem" "$backup_dir/key.pem"
  rmdir "$backup_dir" 2>/dev/null || true
}

apply_connection_settings(){
  local backup_dir had_env=false had_config=false had_cert=false had_key=false
  local service_active=false
  ensure_dirs
  backup_dir="$(mktemp -d "$SB_DIR/.connection-settings.XXXXXX")" || return 1

  if [[ -f "$SB_DIR/env.conf" ]]; then
    cp -f "$SB_DIR/env.conf" "$backup_dir/env.conf" || { remove_connection_backup "$backup_dir"; return 1; }
    had_env=true
  fi
  if [[ -f "$CONF_JSON" ]]; then
    cp -f "$CONF_JSON" "$backup_dir/config.json" || { remove_connection_backup "$backup_dir"; return 1; }
    had_config=true
  fi
  if [[ -f "$CERT_DIR/fullchain.pem" ]]; then
    cp -f "$CERT_DIR/fullchain.pem" "$backup_dir/fullchain.pem" || { remove_connection_backup "$backup_dir"; return 1; }
    had_cert=true
  fi
  if [[ -f "$CERT_DIR/key.pem" ]]; then
    cp -f "$CERT_DIR/key.pem" "$backup_dir/key.pem" || { remove_connection_backup "$backup_dir"; return 1; }
    had_key=true
  fi

  if ! save_env; then
    restore_connection_files "$backup_dir" "$had_env" "$had_config" "$had_cert" "$had_key"
    remove_connection_backup "$backup_dir"
    warn "保存连接设置失败，已恢复原设置"
    return 1
  fi

  if [[ "$had_config" != true ]]; then
    remove_connection_backup "$backup_dir"
    info "设置已保存，首次部署时会自动生效"
    return 0
  fi

  if ! write_config; then
    restore_connection_files "$backup_dir" "$had_env" "$had_config" "$had_cert" "$had_key"
    remove_connection_backup "$backup_dir"
    load_env || true
    warn "更新服务配置失败，已恢复原设置"
    return 1
  fi

  open_firewall || warn "防火墙规则更新失败，请手动检查端口"
  if command -v systemctl >/dev/null 2>&1 \
      && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
    service_active=true
  fi
  if [[ "$service_active" == true ]] && ! systemctl restart "${SYSTEMD_SERVICE}"; then
    restore_connection_files "$backup_dir" "$had_env" "$had_config" "$had_cert" "$had_key"
    load_env || true
    systemctl restart "${SYSTEMD_SERVICE}" >/dev/null 2>&1 \
      || warn "原配置已恢复，但服务恢复启动失败"
    remove_connection_backup "$backup_dir"
    warn "服务重启失败，域名、证书与 SNI 设置已回滚"
    return 1
  fi

  remove_connection_backup "$backup_dir"
  if [[ "$service_active" == true ]]; then
    info "连接设置已应用并重启服务"
  else
    info "连接设置已写入；服务当前未运行"
  fi
  print_links_grouped || warn "配置已生效，但导入链接文件更新失败"
}

edit_tls_certificate_settings(){
  load_env || true
  local old_mode="$TLS_CERT_MODE" old_domain="$TLS_DOMAIN"
  local old_cert="$TLS_CERT_PATH" old_key="$TLS_KEY_PATH" old_email="$TLS_ACME_EMAIL"
  local old_provider="$TLS_ACME_PROVIDER" old_data="$TLS_ACME_DATA_DIR"
  local old_http="$TLS_ACME_DISABLE_HTTP_CHALLENGE" old_tls="$TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE"

  if ! configure_tls_certificate || ! apply_connection_settings; then
    TLS_CERT_MODE="$old_mode"
    TLS_DOMAIN="$old_domain"
    TLS_CERT_PATH="$old_cert"
    TLS_KEY_PATH="$old_key"
    TLS_ACME_EMAIL="$old_email"
    TLS_ACME_PROVIDER="$old_provider"
    TLS_ACME_DATA_DIR="$old_data"
    TLS_ACME_DISABLE_HTTP_CHALLENGE="$old_http"
    TLS_ACME_DISABLE_TLS_ALPN_CHALLENGE="$old_tls"
    return 1
  fi
}

edit_reality_sni_setting(){
  load_env || true
  local old_server="$REALITY_SERVER"
  if ! configure_reality_sni || ! apply_connection_settings; then
    REALITY_SERVER="$old_server"
    return 1
  fi
}

connection_settings_menu(){
  local op domain_text
  while true; do
    load_env || true
    domain_text="${TLS_DOMAIN:-未设置}"
    clear >/dev/null 2>&1 || true
    hr
    echo -e " ${C_CYAN}${C_BOLD}域名、证书与 SNI${C_RESET}"
    hr
    echo "  TLS 证书：$(tls_mode_label)"
    echo "  证书域名：$domain_text"
    echo "  Reality SNI：$REALITY_SERVER"
    echo "  导入安全：强制证书校验"
    if managed_cert_sni_mismatch; then
      echo -e "  ${C_YELLOW}托管证书仍是旧域名，与当前 SNI 不匹配${C_RESET}"
    fi
    hr
    echo -e "  ${C_GREEN}1)${C_RESET} 设置 TLS 域名与证书"
    echo -e "  ${C_GREEN}2)${C_RESET} 修改 Reality SNI 域名"
    echo -e "  ${C_GREEN}3)${C_RESET} 重新签发自签证书（匹配当前 SNI，会重启服务）"
    echo -e "  ${C_RED}0)${C_RESET} 返回主菜单"
    hr
    read -rp "选择: " op || return 0
    case "${op:-}" in
      1) edit_tls_certificate_settings || true; read -rp "回车继续..." _ || true ;;
      2) edit_reality_sni_setting || true; read -rp "回车继续..." _ || true ;;
      3) reissue_managed_certificate || true; read -rp "回车继续..." _ || true ;;
      0|q|Q) return 0 ;;
      *) warn "无效选项"; sleep 1 ;;
    esac
  done
}

# ===== BBR =====
enable_bbr(){
  if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    info "BBR 已启用"
  else
    echo "net.core.default_qdisc=fq" >/etc/sysctl.d/99-bbr.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >>/etc/sysctl.d/99-bbr.conf
    sysctl --system >/dev/null 2>&1 || true
    info "已尝试开启 BBR（如内核不支持需自行升级）"
  fi
}

# ===== 显示状态与看板 =====
sb_service_state(){
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "${SYSTEMD_SERVICE:-sing-box.service}"; then
      echo -e "${C_GREEN}运行中 (Active)${C_RESET}"
    else
      echo -e "${C_RED}未运行 (Inactive)${C_RESET}"
    fi
  else
    echo -e "${C_YELLOW}未检测到 systemd${C_RESET}"
  fi
}

bbr_state(){
  sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr && echo -e "${C_GREEN}已启用 BBR${C_RESET}" || echo -e "${C_RED}未启用 BBR${C_RESET}"
}

show_service_status(){
  load_env || true
  load_creds || true
  load_ports || true

  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}${C_BOLD}📊 Sing-Box-Plus 综合运行状态看板 📊${C_RESET}"
  echo -e " ${C_DIM}检测时间: $(date '+%Y-%m-%d %H:%M:%S %z')${C_RESET}"
  hr

  # 1. 服务核心状态
  echo -e "${C_BOLD}【1. sing-box 服务状态】${C_RESET}"
  local svc_active="inactive" svc_pid="-" svc_mem="-" svc_uptime="-" restarts="0"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
      svc_active="active"
      svc_pid="$(systemctl show "$SYSTEMD_SERVICE" --property MainPID --value 2>/dev/null || echo "-")"
      restarts="$(systemctl show "$SYSTEMD_SERVICE" --property NRestarts --value 2>/dev/null || echo "0")"
      local enter_ts
      enter_ts="$(systemctl show "$SYSTEMD_SERVICE" --property ActiveEnterTimestamp --value 2>/dev/null || true)"
      [[ -n "$enter_ts" ]] && svc_uptime="$enter_ts" || svc_uptime="运行中"
      if [[ "$svc_pid" =~ ^[0-9]+$ && "$svc_pid" -gt 0 && -f "/proc/$svc_pid/status" ]]; then
        local rss_kb
        rss_kb="$(awk '/VmRSS/{print $2}' "/proc/$svc_pid/status" 2>/dev/null || true)"
        if [[ -n "$rss_kb" && "$rss_kb" =~ ^[0-9]+$ ]]; then
          svc_mem="$(awk "BEGIN {printf \"%.2f MB\", $rss_kb/1024}")"
        fi
      fi
    fi
  fi

  if [[ "$svc_active" == "active" ]]; then
    echo -e "  服务状态:    ${C_GREEN}● 运行中 (Active)${C_RESET}"
    echo -e "  主进程PID:   ${svc_pid}  |  内存占用: ${svc_mem}  |  异常重启: ${restarts} 次"
    echo -e "  启动时间:    ${svc_uptime}"
  else
    echo -e "  服务状态:    ${C_RED}● 未运行 / 已停止 (Inactive)${C_RESET}"
  fi

  # 2. 版本与规则信息
  echo
  echo -e "${C_BOLD}【2. 核心版本与规则】${C_RESET}"
  local cur_ver rem_ver
  cur_ver="$(get_singbox_local_version "$BIN_PATH" 2>/dev/null || echo "未安装")"
  rem_ver="$(get_singbox_remote_version 2>/dev/null || echo "检测中...")"
  if [[ "$cur_ver" != "未安装" ]]; then
    if [[ "$rem_ver" != "检测中..." && "$rem_ver" != "$cur_ver" && -n "$rem_ver" ]]; then
      echo -e "  sing-box 核心: v${cur_ver} ${C_YELLOW}(可升级至最新 v${rem_ver})${C_RESET}"
    else
      echo -e "  sing-box 核心: v${cur_ver} ${C_GREEN}(最新版)${C_RESET}"
    fi
  else
    echo -e "  sing-box 核心: ${C_RED}未安装${C_RESET}"
  fi

  local geo_ver="未记录" geo_geoip="未找到" geo_geosite="未找到"
  [[ -f "$SB_DIR/geofiles.version" ]] && geo_ver="$(awk -F'=' '/LAST_UPDATE/{gsub(/"/,""); print $2}' "$SB_DIR/geofiles.version" 2>/dev/null || echo "已记录")"
  if [[ -f "$DATA_DIR/geoip.db" ]]; then
    geo_geoip="$(wc -c < "$DATA_DIR/geoip.db" 2>/dev/null | awk '{printf "%.2f MB", $1/1048576}')"
  elif [[ -f "$SB_DIR/geoip.db" ]]; then
    geo_geoip="$(wc -c < "$SB_DIR/geoip.db" 2>/dev/null | awk '{printf "%.2f MB", $1/1048576}')"
  fi
  if [[ -f "$DATA_DIR/geosite.db" ]]; then
    geo_geosite="$(wc -c < "$DATA_DIR/geosite.db" 2>/dev/null | awk '{printf "%.2f MB", $1/1048576}')"
  elif [[ -f "$SB_DIR/geosite.db" ]]; then
    geo_geosite="$(wc -c < "$SB_DIR/geosite.db" 2>/dev/null | awk '{printf "%.2f MB", $1/1048576}')"
  fi
  echo -e "  GeoFiles 规则: 上次更新 [${geo_ver}] | geoip.db (${geo_geoip}) | geosite.db (${geo_geosite})"

  # 3. 20 节点监听状态探测
  echo
  echo -e "${C_BOLD}【3. 20 节点端口监听监控】${C_RESET}"
  local listening_ports=""
  if command -v ss >/dev/null 2>&1; then
    listening_ports="$(ss -tulpn 2>/dev/null || true)"
  elif command -v netstat >/dev/null 2>&1; then
    listening_ports="$(netstat -tulpn 2>/dev/null || true)"
  fi

  check_port_status() {
    local port="$1" proto="$2"
    [[ -n "$port" ]] || { echo -e "${C_DIM}未分配${C_RESET}"; return; }
    if [[ -z "$listening_ports" ]]; then
      echo -e "${C_CYAN}${port}/${proto}${C_RESET}"
      return
    fi
    if echo "$listening_ports" | grep -qE ":${port}\b"; then
      echo -e "${C_GREEN}${port}/${proto} ● 监听正常${C_RESET}"
    else
      echo -e "${C_RED}${port}/${proto} ○ 未监听${C_RESET}"
    fi
  }

  local cur_def_outbound="direct"
  if [[ -s "$ROUTE_JSON" ]] && command -v jq >/dev/null 2>&1; then
    cur_def_outbound="$(jq -r '.default_outbound // "direct"' "$ROUTE_JSON" 2>/dev/null || echo "direct")"
  fi
  local def_label="直连 10 节点"
  if [[ "$cur_def_outbound" != "direct" ]]; then
    def_label="默认出口 10 节点 (当前出口: ${cur_def_outbound})"
  fi
  echo -e "  ${C_CYAN}[${def_label}]${C_RESET}"
  printf "    %-18s : %b\n" "1. VLESS-Reality" "$(check_port_status "${PORT_VLESSR:-}" "tcp")"
  printf "    %-18s : %b\n" "2. VLESS-gRPC-Real" "$(check_port_status "${PORT_VLESS_GRPCR:-}" "tcp")"
  printf "    %-18s : %b\n" "3. Trojan-Reality" "$(check_port_status "${PORT_TROJANR:-}" "tcp")"
  printf "    %-18s : %b\n" "4. Hysteria2" "$(check_port_status "${PORT_HY2:-}" "udp")"
  printf "    %-18s : %b\n" "5. VMess-WS" "$(check_port_status "${PORT_VMESS_WS:-}" "tcp")"
  printf "    %-18s : %b\n" "6. Hysteria2-Obfs" "$(check_port_status "${PORT_HY2_OBFS:-}" "udp")"
  printf "    %-18s : %b\n" "7. SS-2022" "$(check_port_status "${PORT_SS2022:-}" "tcp/udp")"
  printf "    %-18s : %b\n" "8. Shadowsocks" "$(check_port_status "${PORT_SS:-}" "tcp/udp")"
  printf "    %-18s : %b\n" "9. TUIC v5" "$(check_port_status "${PORT_TUIC:-}" "udp")"
  printf "    %-18s : %b\n" "10. AnyTLS" "$(check_port_status "${PORT_ANYTLS:-}" "tcp")"

  echo -e "  ${C_CYAN}[WARP 10 节点]${C_RESET}"
  printf "    %-18s : %b\n" "11. VLESS-Reality-W" "$(check_port_status "${PORT_VLESSR_W:-}" "tcp")"
  printf "    %-18s : %b\n" "12. VLESS-gRPC-W" "$(check_port_status "${PORT_VLESS_GRPCR_W:-}" "tcp")"
  printf "    %-18s : %b\n" "13. Trojan-Real-W" "$(check_port_status "${PORT_TROJANR_W:-}" "tcp")"
  printf "    %-18s : %b\n" "14. Hysteria2-W" "$(check_port_status "${PORT_HY2_W:-}" "udp")"
  printf "    %-18s : %b\n" "15. VMess-WS-W" "$(check_port_status "${PORT_VMESS_WS_W:-}" "tcp")"
  printf "    %-18s : %b\n" "16. Hy2-Obfs-W" "$(check_port_status "${PORT_HY2_OBFS_W:-}" "udp")"
  printf "    %-18s : %b\n" "17. SS-2022-W" "$(check_port_status "${PORT_SS2022_W:-}" "tcp/udp")"
  printf "    %-18s : %b\n" "18. Shadowsocks-W" "$(check_port_status "${PORT_SS_W:-}" "tcp/udp")"
  printf "    %-18s : %b\n" "19. TUIC-v5-W" "$(check_port_status "${PORT_TUIC_W:-}" "udp")"
  printf "    %-18s : %b\n" "20. AnyTLS-W" "$(check_port_status "${PORT_ANYTLS_W:-}" "tcp")"

  # 4. DNS 与健康检查
  echo
  echo -e "${C_BOLD}【4. DNS 与健康检查】${C_RESET}"
  local cur_dns="未知" timer_state="未启用"
  if [[ -s "$CONF_JSON" ]] && command -v jq >/dev/null 2>&1; then
    cur_dns="$(jq -r '.dns.final // "未配置"' "$CONF_JSON" 2>/dev/null || echo "未知")"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet "$DNS_HEALTH_TIMER" 2>/dev/null; then
      timer_state="${C_GREEN}运行中 (周期: ${DNS_HEALTH_INTERVAL})${C_RESET}"
    else
      timer_state="${C_YELLOW}未激活${C_RESET}"
    fi
  fi
  echo -e "  当前主 DNS:    ${cur_dns}"
  echo -e "  健康定时器:    ${timer_state}"
  if [[ -s "$DNS_HEALTH_LOG" ]]; then
    local last_dns_event
    last_dns_event="$(tail -n1 "$DNS_HEALTH_LOG" 2>/dev/null || true)"
    echo -e "  最新切换记录:  ${C_DIM}${last_dns_event}${C_RESET}"
  fi

  # 5. TLS 证书与 SNI
  echo
  echo -e "${C_BOLD}【5. TLS 证书与 SNI】${C_RESET}"
  echo -e "  证书模式:      $(tls_mode_label)"
  echo -e "  Reality SNI:   ${REALITY_SERVER:-未配置}"
  if [[ -n "${TLS_DOMAIN:-}" ]]; then
    echo -e "  证书域名:      ${TLS_DOMAIN}"
  fi
  if [[ -f "$TLS_CERT_PATH" ]] && command -v openssl >/dev/null 2>&1; then
    local end_date exp_days
    end_date="$(openssl x509 -enddate -noout -in "$TLS_CERT_PATH" 2>/dev/null | cut -d= -f2- || echo "未知")"
    local end_epoch now_epoch
    end_epoch="$(date -d "$end_date" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date +%s)"
    if (( end_epoch > now_epoch )); then
      exp_days=$(( (end_epoch - now_epoch) / 86400 ))
      echo -e "  证书到期时间:  ${end_date} ${C_GREEN}(剩余 ${exp_days} 天)${C_RESET}"
    else
      echo -e "  证书到期时间:  ${end_date} ${C_RED}(已过期)${C_RESET}"
    fi
  fi

  # 6. 系统加速与网络
  echo
  echo -e "${C_BOLD}【6. 系统网络与加速】${C_RESET}"
  echo -e "  BBR 加速状态:  $(bbr_state)"
  local cc ct_cur ct_max
  cc="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")"
  ct_cur="$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")"
  ct_max="$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")"
  echo -e "  TCP 拥塞算法:  ${cc}  |  连接跟踪: ${ct_cur}/${ct_max}"

  # 7. 最近服务日志
  if command -v journalctl >/dev/null 2>&1; then
    echo
    echo -e "${C_BOLD}【7. 最近运行日志 (最新 8 条)】${C_RESET}"
    journalctl -u "$SYSTEMD_SERVICE" -n 8 --no-pager 2>/dev/null | sed 's/^/  /' || echo "  暂无日志"
  fi

  hr
}

banner(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_CYAN}🚀 ${SCRIPT_NAME} ${SCRIPT_VERSION} 🚀${C_RESET}"
  echo -e "${C_CYAN} 脚本更新地址: https://github.com/yayitinyu/sing-box-plus${C_RESET}"
  hr

  local quick_svc quick_ver quick_bbr quick_tls
  quick_svc="$(sb_service_state)"
  quick_bbr="$(bbr_state)"
  local cur_v; cur_v="$(get_singbox_local_version "$BIN_PATH" 2>/dev/null || echo "")"
  if [[ -n "$cur_v" ]]; then
    quick_ver="sing-box v${cur_v}"
  else
    quick_ver="未安装"
  fi
  quick_tls="$(tls_mode_label)"

  echo -e "  服务状态: ${quick_svc}  |  核心版本: ${quick_ver}"
  echo -e "  系统加速: ${quick_bbr}  |  证书模式: ${quick_tls}"
  hr
  echo -e "  ${C_BOLD}【核心部署与运行】${C_RESET}"
  echo -e "    ${C_BLUE}1)${C_RESET} 安装 / 部署（20 节点，含旧版自动升级）"
  echo -e "    ${C_GREEN}2)${C_RESET} 查看服务运行状态"
  echo -e "    ${C_GREEN}3)${C_RESET} 查看节点分享链接"
  echo -e "    ${C_GREEN}4)${C_RESET} 重启 sing-box 服务"
  echo
  echo -e "  ${C_BOLD}【配置与网络管理】${C_RESET}"
  echo -e "    ${C_GREEN}5)${C_RESET} 一键更换所有端口"
  echo -e "    ${C_GREEN}6)${C_RESET} 域名、证书与 SNI 设置"
  echo -e "    ${C_GREEN}7)${C_RESET} 自定义路由与分流规则"
  echo -e "    ${C_GREEN}8)${C_RESET} 一键开启 BBR 加速"
  echo
  echo -e "  ${C_BOLD}【核心与规则维护】${C_RESET}"
  echo -e "    ${C_YELLOW}9)${C_RESET} 更新 sing-box 核心版本"
  echo -e "   ${C_YELLOW}10)${C_RESET} 更新 GeoFiles 规则文件 (GeoIP/GeoSite/规则集)"
  echo -e "   ${C_YELLOW}11)${C_RESET} 从 GitHub 更新管理脚本"
  echo -e "   ${C_YELLOW}12)${C_RESET} 一键系统网络诊断"
  echo -e "   ${C_RED}13)${C_RESET} 彻底卸载 Sing-Box-Plus"
  echo
  echo -e "    ${C_RED}0)${C_RESET} 退出管理脚本"
  hr
}

# ===== 业务流程 =====
restart_service(){
  systemctl restart "${SYSTEMD_SERVICE}" || die "重启失败"
  systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,6p' || true
}

run_diagnostics(){
  ensure_installed_or_hint || return 0
  local stamp report conntrack_count conntrack_max
  load_env || true
  apply_runtime_overrides
  normalize_runtime_settings
  stamp=$(date '+%Y%m%d-%H%M%S')
  mkdir -p "$DIAG_DIR"
  report="$DIAG_DIR/diagnostic-${stamp}.log"

  set +e
  {
    echo "Sing-Box-Plus 网络诊断"
    echo "时间: $(date '+%F %T %z')"
    echo "主机: $(hostname 2>/dev/null)"
    echo "内核: $(uname -srmo 2>/dev/null)"
    echo "sing-box: $("$BIN_PATH" version 2>/dev/null | head -n1)"
    echo

    echo "== 服务状态 =="
    systemctl show "$SYSTEMD_SERVICE" --no-pager \
      -p ActiveState -p SubState -p Result -p NRestarts \
      -p ExecMainStatus -p ActiveEnterTimestamp
    systemctl is-enabled "$DNS_HEALTH_TIMER" 2>/dev/null | sed 's/^/DNS 健康定时器: /'
    systemctl is-active "$DNS_HEALTH_TIMER" 2>/dev/null | sed 's/^/DNS 健康定时器状态: /'
    echo

    echo "== 当前 DNS 与健康检查 =="
    jq -r '"dns.final=" + (.dns.final // "未设置"),
      "route.default_domain_resolver=" + (.route.default_domain_resolver // "未设置")' "$CONF_JSON"
    if [[ -x "$DNS_HEALTH_BIN" ]]; then
      "$DNS_HEALTH_BIN" --probe
    else
      echo "DNS 健康检查脚本尚未安装，请重新执行部署。"
    fi
    echo

    echo "== 自定义路由 =="
    if [[ -s "$ROUTE_JSON" ]]; then
      jq -r '
        "default_outbound=" + (.default_outbound // "direct"),
        "rules=" + (((.rules // []) | length) | tostring),
        "rule_set=" + (((.rule_set // []) | length) | tostring),
        "imported_outbounds=" + (((.outbounds // []) | length) | tostring)
      ' "$ROUTE_JSON" 2>/dev/null || echo "自定义路由文件无法解析。"
    else
      echo "未配置自定义路由。"
    fi
    echo

    echo "== 网络与资源 =="
    ip -brief address 2>/dev/null
    echo
    ip route show default 2>/dev/null
    ip -6 route show default 2>/dev/null
    echo
    ss -s 2>/dev/null
    free -h 2>/dev/null
    df -h "$SB_DIR" 2>/dev/null
    echo "TCP 拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "TCP keepalive: ${TCP_KEEP_ALIVE}/${TCP_KEEP_ALIVE_INTERVAL}"
    echo "UDP timeout: ${UDP_TIMEOUT}"
    echo "WARP keepalive: ${WARP_KEEPALIVE_INTERVAL}s"
    echo "DNS 切换阈值: 故障 ${DNS_FAILURE_THRESHOLD} 次 / 恢复 ${DNS_RECOVERY_THRESHOLD} 次"
    echo "DNS 恢复冷却: ${DNS_SWITCH_COOLDOWN}s"
    conntrack_count=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
    conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null)
    echo "Conntrack: ${conntrack_count:-未知}/${conntrack_max:-未知}"
    echo

    echo "== IPv4 外网测试 =="
    curl -4 -fsS --connect-timeout 3 --max-time 8 \
      https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null |
      awk -F= '/^(ip|loc|warp)=/{print}'
    echo

    echo "== 重启记录（最近 30 条） =="
    if [[ -s "$RESTART_LOG" ]]; then tail -n 30 "$RESTART_LOG"; else echo "暂无记录"; fi
    echo

    echo "== DNS 切换记录（最近 30 条） =="
    if [[ -s "$DNS_HEALTH_LOG" ]]; then tail -n 30 "$DNS_HEALTH_LOG"; else echo "暂无记录"; fi
    echo

    echo "== sing-box 近期异常（最近 2 小时） =="
    journalctl -u "$SYSTEMD_SERVICE" --since "2 hours ago" --no-pager 2>/dev/null |
      grep -Ei 'error|warn|timeout|failed|closed|wireguard|warp|dns' |
      tail -n 100
    echo

    echo "== 内核近期异常（最近 2 小时） =="
    journalctl -k --since "2 hours ago" --no-pager 2>/dev/null |
      grep -Ei 'oom|killed process|conntrack|network|tcp|udp' |
      tail -n 80
  } 2>&1 | tee "$report"
  set -e

  echo
  info "诊断完成，报告已保存到：$report"
}

# 更新 sing-box 核心
update_singbox(){
  ensure_installed_or_hint || return 0
  info "正在检查 sing-box 核心版本..."
  if install_singbox 1; then
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
      info "正在重启 sing-box 服务..."
      systemctl restart "${SYSTEMD_SERVICE}" || warn "重启服务失败"
    fi
  else
    warn "更新 sing-box 失败"
  fi
}

rotate_ports(){
  ensure_installed_or_hint || return 0
  load_ports || true
  rand_ports_reset

  # 清空 20 项端口变量，触发重新分配不重复端口
  PORT_VLESSR=""; PORT_VLESS_GRPCR=""; PORT_TROJANR=""; PORT_HY2=""; PORT_VMESS_WS=""
  PORT_HY2_OBFS=""; PORT_SS2022=""; PORT_SS=""; PORT_TUIC=""; PORT_ANYTLS=""
  PORT_VLESSR_W=""; PORT_VLESS_GRPCR_W=""; PORT_TROJANR_W=""; PORT_HY2_W=""; PORT_VMESS_WS_W=""
  PORT_HY2_OBFS_W=""; PORT_SS2022_W=""; PORT_SS_W=""; PORT_TUIC_W=""; PORT_ANYTLS_W=""

  save_all_ports          # 重新生成并保存 20 个不重复端口
  write_config            # 用新端口重写 /opt/sing-box/config.json
  open_firewall           # 把“当前配置中的端口”全部放行
  systemctl restart "${SYSTEMD_SERVICE}"

  info "已更换端口并重启。"
  print_links_grouped || warn "端口已更新，但导入链接文件更新失败"
  read -p "回车返回..." _ || true
}

# ===== 一键彻底卸载与深度清理 =====
uninstall_all(){
  clear >/dev/null 2>&1 || true
  hr
  echo -e " ${C_RED}${C_BOLD}⚠️  Sing-Box-Plus 一键彻底卸载 ⚠️${C_RESET}"
  hr
  echo -e "此操作将执行以下清理："
  echo -e "  1. 停止并注销 sing-box 及 DNS 健康检查所有 systemd 服务与定时器"
  echo -e "  2. 终止所有运行中的 sing-box、wgcf 残留进程"
  echo -e "  3. 清理防火墙中放行的全部 20 个节点端口规则 (UFW / Firewalld / iptables)"
  echo -e "  4. 清理所有安装目录、配置文件、凭证、证书与日志 ($SB_DIR, $SBP_ROOT, /var/lib/sing-box)"
  echo -e "  5. 清理 sing-box、wgcf 及所有辅助脚本二进制文件"
  hr
  read -rp "确定要彻底卸载 Sing-Box-Plus 吗？(y/N): " confirm_uninstall
  if [[ "${confirm_uninstall,,}" != "y" && "${confirm_uninstall,,}" != "yes" ]]; then
    info "已取消卸载操作。"
    return 0
  fi

  echo
  info "正在停止并注销服务与定时器..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable "${SYSTEMD_SERVICE}" >/dev/null 2>&1 || true
    systemctl stop "${DNS_HEALTH_TIMER}" >/dev/null 2>&1 || true
    systemctl disable --now "${DNS_HEALTH_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${DNS_HEALTH_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable "${DNS_HEALTH_SERVICE}" >/dev/null 2>&1 || true
  fi

  rm -f "${SYSTEMD_UNIT_DIR}/${SYSTEMD_SERVICE}" 2>/dev/null || true
  rm -f "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_SERVICE}" "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_TIMER}" 2>/dev/null || true
  rm -f /etc/systemd/system/multi-user.target.wants/"${SYSTEMD_SERVICE}" 2>/dev/null || true
  rm -f /etc/systemd/system/timers.target.wants/"${DNS_HEALTH_TIMER}" 2>/dev/null || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed >/dev/null 2>&1 || true
  fi

  info "正在终止残留进程..."
  killall -9 sing-box wgcf 2>/dev/null || true
  pkill -9 -f "sing-box" 2>/dev/null || true
  pkill -9 -f "wgcf" 2>/dev/null || true
  pkill -9 -f "sing-box-plus" 2>/dev/null || true

  info "正在清理防火墙端口规则..."
  load_ports || true
  local rules=()
  for p in "${PORT_VLESSR:-}" "${PORT_VLESS_GRPCR:-}" "${PORT_TROJANR:-}" "${PORT_VMESS_WS:-}" "${PORT_ANYTLS:-}" \
           "${PORT_VLESSR_W:-}" "${PORT_VLESS_GRPCR_W:-}" "${PORT_TROJANR_W:-}" "${PORT_VMESS_WS_W:-}" "${PORT_ANYTLS_W:-}"; do
    [[ -n "$p" ]] && rules+=("${p}/tcp")
  done
  for p in "${PORT_HY2:-}" "${PORT_HY2_OBFS:-}" "${PORT_TUIC:-}" \
           "${PORT_HY2_W:-}" "${PORT_HY2_OBFS_W:-}" "${PORT_TUIC_W:-}"; do
    [[ -n "$p" ]] && rules+=("${p}/udp")
  done
  for p in "${PORT_SS2022:-}" "${PORT_SS:-}" "${PORT_SS2022_W:-}" "${PORT_SS_W:-}"; do
    [[ -n "$p" ]] && rules+=("${p}/tcp" "${p}/udp")
  done

  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q -E "active|活跃"; then
    for r in "${rules[@]}"; do ufw delete allow "$r" >/dev/null 2>&1 || true; done
    ufw reload >/dev/null 2>&1 || true
  elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    for r in "${rules[@]}"; do firewall-cmd --permanent --remove-port="$r" >/dev/null 2>&1 || true; done
    firewall-cmd --reload >/dev/null 2>&1 || true
  else
    for r in "${rules[@]}"; do
      local p="${r%/*}" proto="${r#*/}"
      iptables -D INPUT -p "$proto" --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
    done
    command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
  fi

  info "正在删除二进制与运行脚本..."
  rm -f "$BIN_PATH" "${BIN_PATH}.bak" 2>/dev/null || true
  rm -f "${WGCF_BIN:-/usr/local/bin/wgcf}" 2>/dev/null || true
  rm -f "$DNS_HEALTH_BIN" "$EVENT_LOG_BIN" 2>/dev/null || true
  rm -f /usr/local/bin/sbp /usr/bin/sbp 2>/dev/null || true

  info "正在清理数据目录与缓存..."
  rm -rf "$SB_DIR" 2>/dev/null || true
  rm -rf "$SBP_ROOT" 2>/dev/null || true
  rm -rf /var/lib/sing-box 2>/dev/null || true
  rm -rf /tmp/sing-box* /tmp/sbp* 2>/dev/null || true

  echo
  hr
  echo -e " ${C_GREEN}${C_BOLD}✓ Sing-Box-Plus 已彻底卸载并清理完成！${C_RESET}"
  hr
  exit 0
}

deploy_native(){
  install_deps
  install_singbox
  write_config
  info "检查配置 ..."
  "$BIN_PATH" check -c "$CONF_JSON"
  info "写入并启用 systemd 服务 ..."
  write_systemd
  open_firewall
  systemctl restart "${SYSTEMD_SERVICE}" || die "sing-box 启动失败"
  echo; echo -e "${C_BOLD}${C_GREEN}★ 部署完成（20 节点）${C_RESET}"; echo
  print_links_grouped
  exit 0
}

ensure_installed_or_hint(){
  if [[ ! -f "$CONF_JSON" ]]; then
    warn "尚未安装，请先选择 1) 安装/部署（20 节点）"
    return 1
  fi
  return 0
}

# ===== 已有节点轻量更新 =====
backup_runtime_file(){
  local source_path=$1 backup_name=$2 backup_dir=$3
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$backup_dir/$backup_name" || return 1
  else
    : > "$backup_dir/${backup_name}.missing" || return 1
  fi
}

restore_runtime_file(){
  local backup_dir=$1 backup_name=$2 target_path=$3
  if [[ -e "$backup_dir/$backup_name" || -L "$backup_dir/$backup_name" ]]; then
    mkdir -p "$(dirname "$target_path")" || return 1
    cp -a -- "$backup_dir/$backup_name" "$target_path" || return 1
  elif [[ -f "$backup_dir/${backup_name}.missing" ]]; then
    rm -f -- "$target_path" || return 1
  fi
}

backup_runtime_update(){
  local backup_dir=$1
  backup_runtime_file "$SBP_SCRIPT_PATH" management-script "$backup_dir" || return 1
  backup_runtime_file "$DNS_HEALTH_BIN" dns-health-helper "$backup_dir" || return 1
  backup_runtime_file "$EVENT_LOG_BIN" event-log-helper "$backup_dir" || return 1
  backup_runtime_file "$SB_DIR/env.conf" env.conf "$backup_dir" || return 1
  backup_runtime_file "$CONF_JSON" config.json "$backup_dir" || return 1
  backup_runtime_file "$SB_DIR/creds.env" creds.env "$backup_dir" || return 1
  backup_runtime_file "$SB_DIR/ports.env" ports.env "$backup_dir" || return 1
  backup_runtime_file "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_SERVICE}" dns-health.service "$backup_dir" || return 1
  backup_runtime_file "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_TIMER}" dns-health.timer "$backup_dir" || return 1
}

restore_runtime_update(){
  local backup_dir=$1 timer_was_active=$2 restore_failed=0

  systemctl stop "$DNS_HEALTH_TIMER" >/dev/null 2>&1 || true
  systemctl stop "$DNS_HEALTH_SERVICE" >/dev/null 2>&1 || true
  restore_runtime_file "$backup_dir" management-script "$SBP_SCRIPT_PATH" || restore_failed=1
  restore_runtime_file "$backup_dir" dns-health-helper "$DNS_HEALTH_BIN" || restore_failed=1
  restore_runtime_file "$backup_dir" event-log-helper "$EVENT_LOG_BIN" || restore_failed=1
  restore_runtime_file "$backup_dir" env.conf "$SB_DIR/env.conf" || restore_failed=1
  restore_runtime_file "$backup_dir" dns-health.service "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_SERVICE}" || restore_failed=1
  restore_runtime_file "$backup_dir" dns-health.timer "${SYSTEMD_UNIT_DIR}/${DNS_HEALTH_TIMER}" || restore_failed=1
  systemctl daemon-reload >/dev/null 2>&1 || restore_failed=1

  if [[ "$timer_was_active" == true ]]; then
    systemctl start "$DNS_HEALTH_TIMER" >/dev/null 2>&1 || restore_failed=1
  else
    systemctl stop "$DNS_HEALTH_TIMER" >/dev/null 2>&1 || true
  fi
  return "$restore_failed"
}

update_runtime_env(){
  local env_file="$SB_DIR/env.conf" tmp_file
  tmp_file=$(mktemp "${env_file}.tmp.XXXXXX") || return 1

  if [[ -f "$env_file" ]]; then
    awk '
      !/^[[:space:]]*(export[[:space:]]+)?DNS_FAILURE_THRESHOLD=/ &&
      !/^[[:space:]]*(export[[:space:]]+)?DNS_RECOVERY_THRESHOLD=/ &&
      !/^[[:space:]]*(export[[:space:]]+)?DNS_SWITCH_COOLDOWN=/ { print }
    ' "$env_file" > "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  fi

  printf 'DNS_FAILURE_THRESHOLD=%s\nDNS_RECOVERY_THRESHOLD=%s\nDNS_SWITCH_COOLDOWN=%s\n' \
    "$DNS_FAILURE_THRESHOLD" "$DNS_RECOVERY_THRESHOLD" "$DNS_SWITCH_COOLDOWN" >> "$tmp_file" || {
      rm -f "$tmp_file"
      return 1
    }

  if [[ -f "$env_file" ]]; then
    chmod --reference="$env_file" "$tmp_file" || { rm -f "$tmp_file"; return 1; }
    chown --reference="$env_file" "$tmp_file" 2>/dev/null || true
  else
    chmod 0600 "$tmp_file" || { rm -f "$tmp_file"; return 1; }
  fi
  mv -f -- "$tmp_file" "$env_file" || { rm -f "$tmp_file"; return 1; }
}

singbox_main_pid(){
  local pid
  pid=$(systemctl show "$SYSTEMD_SERVICE" --property MainPID --value 2>/dev/null) || pid=unknown
  [[ "$pid" =~ ^[0-9]+$ ]] || pid=unknown
  printf '%s\n' "$pid"
}

apply_runtime_update(){
  local script_source=$1 timer_was_active=$2 pid_before=$3 script_tmp pid_after

  mkdir -p "$SB_DIR" "$(dirname "$SBP_SCRIPT_PATH")" "$SYSTEMD_UNIT_DIR" || return 1
  script_tmp=$(mktemp "${SBP_SCRIPT_PATH}.tmp.XXXXXX") || return 1
  if ! install -m 0755 "$script_source" "$script_tmp"; then
    rm -f "$script_tmp"
    return 1
  fi
  if ! mv -f -- "$script_tmp" "$SBP_SCRIPT_PATH"; then
    rm -f "$script_tmp"
    return 1
  fi

  update_runtime_env || return 1
  write_runtime_helpers || return 1
  bash -n "$DNS_HEALTH_BIN" || return 1
  bash -n "$EVENT_LOG_BIN" || return 1
  systemctl daemon-reload || return 1
  "$DNS_HEALTH_BIN" --probe || return 1

  pid_after=$(singbox_main_pid)
  if [[ "$pid_before" != unknown && "$pid_after" != "$pid_before" ]]; then
    echo "[ERROR] 更新过程中 sing-box MainPID 发生变化：${pid_before} -> ${pid_after}" >&2
    return 1
  fi

  if [[ "$timer_was_active" == true ]]; then
    systemctl start "$DNS_HEALTH_TIMER" || return 1
  fi

  pid_after=$(singbox_main_pid)
  if [[ "$pid_before" != unknown && "$pid_after" != "$pid_before" ]]; then
    echo "[ERROR] 恢复 DNS 定时器后 sing-box MainPID 发生变化：${pid_before} -> ${pid_after}" >&2
    return 1
  fi
  return 0
}

update_runtime_components(){
  [[ "$EUID" -eq 0 || "${SBP_SKIP_ROOT:-0}" -eq 1 || -n "${TEST_ROOT:-}" ]] || die "轻量更新需要 root 权限，请使用 sudo 运行"
  [[ "$SBP_SCRIPT_PATH" == /* ]] || die "SBP_SCRIPT_PATH 必须是绝对路径"
  [[ "$SYSTEMD_UNIT_DIR" == /* ]] || die "SYSTEMD_UNIT_DIR 必须是绝对路径"
  [[ -s "$CONF_JSON" ]] || die "未发现已有节点配置：$CONF_JSON"

  local script_source=${BASH_SOURCE[0]} backup_root backup_dir timestamp
  local timer_was_active=false timer_was_enabled=false pid_before old_umask
  if command -v readlink >/dev/null 2>&1; then
    script_source=$(readlink -f "$script_source") || die "无法解析当前脚本路径"
  else
    script_source="$(cd "$(dirname "$script_source")" && pwd)/$(basename "$script_source")"
  fi
  bash -n "$script_source" || die "当前脚本语法检查失败，未执行更新"

  load_env
  apply_runtime_overrides
  normalize_runtime_settings
  [[ -s "$CONF_JSON" ]] || die "env.conf 指向的节点配置不存在：$CONF_JSON"

  mkdir -p "$SB_DIR" || die "无法访问安装目录：$SB_DIR"
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$SB_DIR/.runtime-update.lock"
    flock -n 8 || die "另一个轻量更新正在进行，请稍后重试"
  fi

  old_umask=$(umask)
  umask 077
  backup_root="$SB_DIR/backups"
  mkdir -p "$backup_root" || die "无法创建备份目录：$backup_root"
  timestamp=$(date +%Y%m%d-%H%M%S)
  backup_dir=$(mktemp -d "$backup_root/runtime-update-${timestamp}.XXXXXX") || die "无法创建更新备份"
  chmod 0700 "$backup_dir" || die "无法保护更新备份目录"

  systemctl is-active --quiet "$DNS_HEALTH_TIMER" && timer_was_active=true
  systemctl is-enabled --quiet "$DNS_HEALTH_TIMER" && timer_was_enabled=true
  pid_before=$(singbox_main_pid)

  if ! backup_runtime_update "$backup_dir"; then
    umask "$old_umask"
    die "运行时文件备份失败：$backup_dir"
  fi

  if [[ "$timer_was_active" == true ]]; then
    systemctl stop "$DNS_HEALTH_TIMER" || {
      systemctl start "$DNS_HEALTH_TIMER" >/dev/null 2>&1 || true
      umask "$old_umask"
      die "无法暂停 DNS 健康检查定时器，未执行更新"
    }
  fi
  systemctl stop "$DNS_HEALTH_SERVICE" >/dev/null 2>&1 || true

  if ! apply_runtime_update "$script_source" "$timer_was_active" "$pid_before"; then
    warn "轻量更新失败，正在恢复备份"
    if restore_runtime_update "$backup_dir" "$timer_was_active"; then
      warn "已恢复更新前的运行时文件"
    else
      warn "自动恢复不完整，请从以下目录手动恢复：$backup_dir"
    fi
    umask "$old_umask"
    return 1
  fi

  umask "$old_umask"
  info "轻量更新完成：${SCRIPT_VERSION}"
  info "管理脚本：$SBP_SCRIPT_PATH"
  info "备份目录：$backup_dir"
  if [[ "$pid_before" == unknown ]]; then
    warn "systemd 未返回 sing-box MainPID，无法自动核对主服务进程"
  else
    info "sing-box MainPID 未变化：$pid_before"
  fi
  if [[ "$timer_was_active" == true ]]; then
    info "DNS 健康检查定时器已恢复运行（启用状态：${timer_was_enabled}）"
  else
    info "DNS 健康检查定时器原本未运行，已保持不运行（启用状态：${timer_was_enabled}）"
  fi
  # 轻量更新不改配置也不重启服务，因此只提示，不自动重签
  warn_if_cert_sni_mismatch
}

# 按内容而非 HTTP 状态码判定，避免把 404 页面或被劫持的响应当成脚本装上去
validate_script_file(){
  local f=$1
  [[ -s "$f" ]] || return 1
  head -n1 "$f" | grep -q '^#!.*bash' || return 1
  grep -q '^SCRIPT_VERSION=' "$f" || return 1
  grep -q '^update_runtime_components()' "$f" || return 1
  bash -n "$f" 2>/dev/null || return 1
}

remote_script_version(){
  sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "$1" | head -n1
}

fetch_remote_script(){
  local dest=$1 base url
  base="https://raw.githubusercontent.com/${SBP_REPO}/${SBP_BRANCH}/sing-box-plus.sh"
  for url in \
    "$base" \
    "https://ghproxy.net/${base}" \
    "https://raw.gitmirror.com/${SBP_REPO}/${SBP_BRANCH}/sing-box-plus.sh"
  do
    if curl -fsSL --connect-timeout 10 -m 120 -o "$dest" "$url" 2>/dev/null \
       && validate_script_file "$dest"; then
      info "已下载：${url}"
      return 0
    fi
    rm -f "$dest"
  done
  return 1
}

update_script_from_remote(){
  [[ "$EUID" -eq 0 || "${SBP_SKIP_ROOT:-0}" -eq 1 || -n "${TEST_ROOT:-}" ]] \
    || die "更新管理脚本需要 root 权限，请使用 sudo 运行"
  command -v curl >/dev/null 2>&1 || die "缺少 curl，无法下载更新"

  local tmp_dir tmp remote_ver rc=0
  tmp_dir=$(mktemp -d) || die "无法创建临时目录"
  tmp="$tmp_dir/sing-box-plus.sh"

  info "正在从 ${SBP_REPO}@${SBP_BRANCH} 获取最新管理脚本..."
  if ! fetch_remote_script "$tmp"; then
    rm -rf "$tmp_dir"
    die "下载或校验管理脚本失败，请检查网络后重试"
  fi

  remote_ver="$(remote_script_version "$tmp")"
  if [[ -z "$remote_ver" ]]; then
    rm -rf "$tmp_dir"
    die "无法识别远程脚本版本"
  fi

  info "当前版本：${SCRIPT_VERSION}    远程版本：${remote_ver}"
  if [[ "$remote_ver" == "$SCRIPT_VERSION" && "${SBP_FORCE_UPDATE:-0}" != "1" ]]; then
    rm -rf "$tmp_dir"
    info "已是最新版本，无需更新。如需强制覆盖：SBP_FORCE_UPDATE=1"
    return 0
  fi

  # 交给新脚本自己执行轻量更新，直接复用其备份 / 回滚 / MainPID 校验流程
  chmod 0755 "$tmp"
  info "正在应用更新（含自动备份与失败回滚）..."
  bash "$tmp" --update-runtime || rc=$?
  rm -rf "$tmp_dir"
  if [[ "$rc" -eq 0 ]]; then
    info "管理脚本已更新到 ${remote_ver}，请重新运行 ${SBP_SCRIPT_PATH} 以使用新版本。"
  fi
  return "$rc"
}

usage(){
  cat <<EOF
用法：
  bash sbp.sh                    打开交互式管理菜单
  sudo bash sbp.sh --status      查看当前服务运行状态
  sudo bash sbp.sh --update-core 检查并更新 sing-box 核心版本
  sudo bash sbp.sh --update-geofiles
                                 更新 GeoFiles 规则文件 (GeoIP/GeoSite/规则集)
  sudo bash sbp.sh --update-runtime
                                 轻量更新管理脚本与 DNS 运行时组件
  sudo bash sbp.sh --update-script
                                 从 GitHub 拉取最新管理脚本并应用轻量更新
  sudo bash sbp.sh --reissue-cert
                                 重新签发自签证书使其匹配当前 Reality SNI（会重启 sing-box）
  sudo bash sbp.sh --uninstall   彻底卸载 Sing-Box-Plus
  bash sbp.sh --help             显示本帮助

轻量更新不会改写节点配置、凭证或端口，也不会主动重启 sing-box。

--update-script 可用以下环境变量覆盖来源与行为：
  SBP_REPO=用户名/仓库名   （默认 ${SBP_REPO}）
  SBP_BRANCH=分支名        （默认 ${SBP_BRANCH}）
  SBP_FORCE_UPDATE=1       版本号相同时也强制覆盖
EOF
}

# ===== 菜单 =====
menu(){
  # 检测是否为交互模式
  if [[ ! -t 0 ]]; then
    echo -e "${C_RED}[错误] 请以交互模式运行脚本${C_RESET}"
    echo -e "${C_YELLOW}用法: wget -O sbp.sh https://raw.githubusercontent.com/yayitinyu/sing-box-plus/main/sing-box-plus.sh && bash sbp.sh${C_RESET}"
    exit 1
  fi
  
  banner
  read -rp "选择: " op || { echo; exit 0; }
  case "${op:-}" in
    1)
      sbp_bootstrap                                     # 依赖/二进制回退
      set +e
      info "正在检查并部署 sing-box..."
      if ! install_singbox; then
        warn "sing-box 安装/升级失败"
        exit 1
      fi
      ensure_warp_profile || true
      if ! write_config; then
        warn "生成配置失败"
        exit 1
      fi
      if ! "$BIN_PATH" check -c "$CONF_JSON"; then
        warn "配置检查失败，未重启服务"
        exit 1
      fi
      write_systemd || { warn "systemd 服务写入失败"; exit 1; }
      open_firewall || true
      if ! systemctl restart "${SYSTEMD_SERVICE}"; then
        systemctl --no-pager status "${SYSTEMD_SERVICE}" | sed -n '1,12p' || true
        warn "sing-box 启动失败，请运行 11) 一键网络诊断"
        exit 1
      fi
      set -e
      print_links_grouped
      exit 0
      ;;
    
    2) show_service_status; read -rp "回车返回..." _ || true; menu ;;
    3) if ensure_installed_or_hint; then print_links_grouped; exit 0; fi ;;
    4) if ensure_installed_or_hint; then restart_service; fi; read -rp "回车返回..." _ || true; menu ;;
    5) if ensure_installed_or_hint; then rotate_ports; fi; menu ;;
    6) sbp_bootstrap; connection_settings_menu; menu ;;
    7) custom_route_menu; menu ;;
    8) enable_bbr; read -rp "回车返回..." _ || true; menu ;;
    9) update_singbox; read -rp "回车返回..." _ || true; menu ;;
    10) update_geofiles; read -rp "回车返回..." _ || true; menu ;;
    11) update_script_from_remote; read -rp "回车返回..." _ || true; menu ;;
    12) run_diagnostics; read -rp "回车返回..." _ || true; menu ;;
    13) uninstall_all ;;
    0|q|Q) exit 0 ;;
    *) echo -e "${C_YELLOW}无效选项，请重新选择${C_RESET}"; sleep 1; menu ;;
  esac
}

# ===== 入口 =====
main(){
  case "${1:-}" in
    "") menu ;;
    --status) show_service_status ;;
    --update-core) update_singbox ;;
    --update-geofiles) update_geofiles ;;
    --update-runtime) update_runtime_components ;;
    --update-script) update_script_from_remote ;;
    --reissue-cert) reissue_managed_certificate ;;
    --uninstall) uninstall_all ;;
    -h|--help) usage ;;
    *)
      echo "未知参数：$1" >&2
      usage >&2
      return 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
