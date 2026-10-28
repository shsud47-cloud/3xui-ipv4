#!/usr/bin/env bash
# One-click 3x-ui + VLESS Reality, IPv4-only (no IPv6).
# Safe defaults for Dee Panel rental CTs: forbid 22/8443; Reality MAY use 443.
# Ports: interactive prompt via /dev/tty (curl|bash safe); env/flags = non-interactive override.
# Downloads: curl -4 + retries + GitHub/jsDelivr/ghfast mirrors; ensure_dns if resolve broken.
# Install one-liner (CDN, GitHub-backed): see README.
# rev: 2026-10-28-reality-443
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
die()  { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }

# ---------- defaults / flags ----------
# Explicit env/flags skip the interactive prompt (non-interactive override).
# curl|bash: stdin is the script; prompts MUST use /dev/tty.
PANEL_EXPLICIT=0
REALITY_EXPLICIT=0
if [[ -n "${PANEL_PORT+x}" ]]; then PANEL_EXPLICIT=1; fi
if [[ -n "${REALITY_PORT+x}" ]]; then REALITY_EXPLICIT=1; fi
PANEL_PORT="${PANEL_PORT:-2096}"
REALITY_PORT="${REALITY_PORT:-2087}"
SNI="${SNI:-www.apple.com}"
XRAY_VER="${XRAY_VER:-26.3.27}"
XUI_TAG="${XUI_TAG:-v3.11.0}"
PANEL_PATH="${PANEL_PATH:-}"          # empty = random
PUBLIC_IP="${PUBLIC_IP:-}"           # empty = auto-detect IPv4
CLIENT_EMAIL="${CLIENT_EMAIL:-tenant-reality}"
SKIP_INSTALL=0
DRY_RUN=0
FORCE=0

# System reserved on rental CTs (SSH / host proxy). Reality MAY bind 443.
FORBIDDEN_PORTS=(22 8443)

is_forbidden_port() {
  local p="$1" r
  for r in "${FORBIDDEN_PORTS[@]}"; do
    [[ "$p" -eq "$r" ]] && return 0
  done
  return 1
}

usage() {
  cat <<EOF
Usage: $0 [options]

一键安装（推荐）会经 /dev/tty 询问面板/Reality 端口；直接回车用默认 2096 / 2087。
无终端时自动用默认。也可用环境变量或参数跳过询问（非交互覆盖）。

  --panel-port N     面板端口 (default: 2096; env PANEL_PORT；设了则不再询问)
  --reality-port N   Reality 入站端口 (default: 2087; env REALITY_PORT)
                     禁止 22/8443；可用 443（推荐入站）
  --sni HOST         Reality 伪装目标 (default: ${SNI})
  --xray-ver VER     Xray 版本号，无 v 前缀 (default: ${XRAY_VER})
  --xui-tag TAG      3x-ui 发行标签 (default: ${XUI_TAG})
  --panel-path PATH  面板 webBasePath (default: 随机 16 位)
  --public-ip IP     强制使用的公网 IPv4（链接里用）
  --email EMAIL      客户端 email (default: ${CLIENT_EMAIL})
  --skip-install     已装过 3x-ui，只做 IPv4 + Reality + 降级 Xray
  --force            已有同端口 Reality 时覆盖重建
  --dry-run          只打印将要执行的步骤，不改系统
  -h, --help         帮助

全程纯 IPv4：关 sysctl IPv6、gai 优先 v4、xray UseIPv4、链接只用 IPv4 字面量。
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panel-port) PANEL_PORT="$2"; PANEL_EXPLICIT=1; shift 2 ;;
    --reality-port) REALITY_PORT="$2"; REALITY_EXPLICIT=1; shift 2 ;;
    --sni) SNI="$2"; shift 2 ;;
    --xray-ver) XRAY_VER="${2#v}"; shift 2 ;;
    --xui-tag) XUI_TAG="$2"; shift 2 ;;
    --panel-path) PANEL_PATH="$2"; shift 2 ;;
    --public-ip) PUBLIC_IP="$2"; shift 2 ;;
    --email) CLIENT_EMAIL="$2"; shift 2 ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（用 --help）" ;;
  esac
done

if [[ "$DRY_RUN" -ne 1 ]]; then
  [[ $EUID -eq 0 ]] || die "请用 root 运行"
fi

# Validate one port; print reason to stdout on failure (caller decides tty vs die).
port_validate_msg() {
  local p="$1" label="$2"
  if ! [[ "$p" =~ ^[0-9]+$ ]]; then
    echo "${label}须为数字"
    return 1
  fi
  if (( p < 1 || p > 65535 )); then
    echo "${label}超出范围 1-65535"
    return 1
  fi
  if is_forbidden_port "$p"; then
    echo "${label}不能使用 ${p}（禁止: 22 / 8443；Reality 可用 443）"
    return 1
  fi
  return 0
}

# Ask one port on /dev/tty (empty = keep default). Echoes chosen value on stdout.
ask_one_port() {
  local label="$1" current="$2" ans msg
  while true; do
    printf '%s [%s]: ' "$label" "$current" >/dev/tty
    IFS= read -r ans </dev/tty || ans=""
    # trim whitespace
    ans="${ans#"${ans%%[![:space:]]*}"}"
    ans="${ans%"${ans##*[![:space:]]}"}"
    if [[ -z "$ans" ]]; then
      printf '%s\n' "$current"
      return 0
    fi
    if msg=$(port_validate_msg "$ans" "$label"); then
      printf '%s\n' "$ans"
      return 0
    fi
    printf '%s；请重试（直接回车用默认）\n' "$msg" >/dev/tty
  done
}

have_tty() {
  # inode -r/-w on /dev/tty can look writable even with no controlling tty;
  # actually open it (ENXIO when none).
  { : </dev/tty; } 2>/dev/null && { : >/dev/tty; } 2>/dev/null
}

prompt_ports_interactive() {
  # Skip entirely if both ports already set via env/flags.
  if [[ "$PANEL_EXPLICIT" -eq 1 && "$REALITY_EXPLICIT" -eq 1 ]]; then
    return 0
  fi
  if ! have_tty; then
    warn "无 /dev/tty（非交互），使用默认端口 panel=${PANEL_PORT} reality=${REALITY_PORT}"
    return 0
  fi
  {
    echo
    echo "======== 端口设置（直接回车 = 默认）========"
    echo "禁止占用: 22 / 8443（SSH/宿主机保留）；Reality 可用 443"
    echo "=========================================="
  } >/dev/tty

  if [[ "$PANEL_EXPLICIT" -eq 0 ]]; then
    PANEL_PORT="$(ask_one_port "面板端口" "$PANEL_PORT")"
  fi
  if [[ "$REALITY_EXPLICIT" -eq 0 ]]; then
    REALITY_PORT="$(ask_one_port "Reality端口" "$REALITY_PORT")"
  fi

  # Duplicate: re-ask the non-explicit side; if both explicit, die later in validate.
  while [[ "$PANEL_PORT" -eq "$REALITY_PORT" ]]; do
    if [[ "$PANEL_EXPLICIT" -eq 1 && "$REALITY_EXPLICIT" -eq 1 ]]; then
      break
    fi
    printf '面板与 Reality 端口不能相同（当前都是 %s）\n' "$PANEL_PORT" >/dev/tty
    if [[ "$REALITY_EXPLICIT" -eq 0 ]]; then
      REALITY_PORT="$(ask_one_port "Reality端口" "2087")"
    elif [[ "$PANEL_EXPLICIT" -eq 0 ]]; then
      PANEL_PORT="$(ask_one_port "面板端口" "2096")"
    else
      break
    fi
  done
  printf '将使用: 面板=%s  Reality=%s\n\n' "$PANEL_PORT" "$REALITY_PORT" >/dev/tty
}

validate_ports_final() {
  local msg
  if ! msg=$(port_validate_msg "$PANEL_PORT" "面板端口"); then
    die "$msg（默认 2096）"
  fi
  if ! msg=$(port_validate_msg "$REALITY_PORT" "Reality端口"); then
    die "$msg（默认 2087）"
  fi
  if [[ "$PANEL_PORT" -eq "$REALITY_PORT" ]]; then
    die "面板端口与 Reality 端口不能相同"
  fi
}

prompt_ports_interactive
validate_ports_final
if [[ "$SNI" == *:* ]]; then
  die "SNI 不要带端口，例如 www.apple.com"
fi

rand_alnum() {
  local n="${1:-16}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((n * 2)) | tr -dc 'a-zA-Z0-9' | head -c "$n"
  else
    tr -dc 'a-zA-Z0-9' </dev/urandom | head -c "$n"
  fi
}

is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# Reality dest is dialed by the inbound itself (not freedom outbound), so force A/IPv4.
resolve_sni_ipv4() {
  local host="$1" ip=""
  if is_ipv4 "$host"; then
    echo "$host"
    return
  fi
  if command -v getent >/dev/null 2>&1; then
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
  fi
  if ! is_ipv4 "${ip:-}"; then
    ip=$(dig +short A "$host" 2>/dev/null | awk '/^[0-9]+\./{print; exit}')
  fi
  if ! is_ipv4 "${ip:-}"; then
    ip=$(python3 - "$host" <<'PYDNS' 2>/dev/null || true
import socket, sys
host = sys.argv[1]
try:
    for info in socket.getaddrinfo(host, 443, socket.AF_INET, socket.SOCK_STREAM):
        print(info[4][0])
        break
except Exception:
    pass
PYDNS
)
  fi
  if is_ipv4 "${ip:-}"; then
    echo "$ip"
  else
    return 1
  fi
}

detect_public_ipv4() {
  local ip="" u
  if [[ -n "$PUBLIC_IP" ]]; then
    is_ipv4 "$PUBLIC_IP" || die "--public-ip 不是合法 IPv4: $PUBLIC_IP"
    echo "$PUBLIC_IP"
    return
  fi
  for u in \
    "https://api4.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://v4.ident.me" \
    "https://ipv4.myexternalip.com/raw"; do
    ip=$(curl -4 -fsS --max-time 5 "$u" 2>/dev/null | tr -d '[:space:]"') || true
    if is_ipv4 "$ip"; then
      echo "$ip"
      return
    fi
  done
  # fallback: first global IPv4 on host
  ip=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
  is_ipv4 "$ip" || die "无法探测公网 IPv4，请传 --public-ip"
  echo "$ip"
}

arch_xray_zip() {
  case "$(uname -m)" in
    x86_64|amd64) echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7) echo "Xray-linux-arm32-v7a.zip" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

arch_xui() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7) echo "armv7" ;;
    *) die "不支持的架构: $(uname -m)" ;;
  esac
}

xray_bin_name() {
  case "$(uname -m)" in
    x86_64|amd64) echo "xray-linux-amd64" ;;
    aarch64|arm64) echo "xray-linux-arm64" ;;
    armv7l|armv7) echo "xray-linux-arm32" ;;
    *) die "不支持的架构" ;;
  esac
}

run_or_echo() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: $*"
  else
    "$@"
  fi
}

# ---------- DNS + resilient fetch (IPv4) ----------
# Rental CTs sometimes have a dangling /etc/resolv.conf → systemd-resolved stub.
# Without working DNS, even GitHub/jsDelivr one-liners fail with "Could not resolve host".
ensure_dns() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: ensure_dns (skip)"
    return 0
  fi
  local ok=0
  if getent ahostsv4 github.com >/dev/null 2>&1 \
    || getent ahostsv4 cdn.jsdelivr.net >/dev/null 2>&1 \
    || getent ahostsv4 one.one.one.one >/dev/null 2>&1; then
    ok=1
  fi
  # dangling resolv.conf symlink counts as broken
  if [[ -L /etc/resolv.conf && ! -e /etc/resolv.conf ]]; then
    ok=0
  fi
  if [[ "$ok" -eq 1 ]]; then
    return 0
  fi
  warn "DNS 不可用（无法解析 GitHub/CDN），写入公共 DNS 1.1.1.1 / 8.8.8.8"
  rm -f /etc/resolv.conf
  printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\noptions timeout:2 attempts:3\n' >/etc/resolv.conf
  if getent ahostsv4 github.com >/dev/null 2>&1 \
    || getent ahostsv4 cdn.jsdelivr.net >/dev/null 2>&1; then
    log "DNS 已恢复"
    return 0
  fi
  die "DNS 仍不可用。请检查容器网络/resolv.conf，或手动: printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\n' >/etc/resolv.conf"
}

# fetch_file DEST URL [URL2 ...] — curl -4, retries per URL, then next mirror
fetch_file() {
  local dest="$1"; shift
  local url attempt rc
  [[ $# -gt 0 ]] || die "fetch_file: 缺少 URL"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: fetch_file $dest <- $*"
    return 0
  fi
  rm -f "$dest"
  for url in "$@"; do
    for attempt in 1 2 3; do
      echo "  · try ${attempt}/3  ${url}"
      set +e
      curl -4 -fL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 180 \
        -A "3xui-ipv4-installer/1.0" -o "$dest" "$url" 2>/tmp/3xui-fetch.err
      rc=$?
      set -e
      if [[ $rc -eq 0 && -s "$dest" ]]; then
        return 0
      fi
      warn "下载失败 rc=${rc}（$(tr '\n' ' ' </tmp/3xui-fetch.err 2>/dev/null | head -c 160)）"
      rm -f "$dest"
      sleep "$attempt"
    done
  done
  die "所有镜像均失败，无法下载: ${dest}
已尝试:
$(printf '  - %s\n' "$@")
排查: getent ahostsv4 github.com; cat /etc/resolv.conf; curl -4 -I https://cdn.jsdelivr.net/"
}



# ---------- sqlite helpers (stop x-ui first; retry on SQLITE_BUSY) ----------
stop_xui() {
  # 3x-ui 3.11.x has no "stop"/"restart" subcommands (prints "Invalid subcommands").
  # Prefer systemd/OpenRC; never call bare `x-ui stop`.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop x-ui 2>/dev/null || true
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service x-ui stop 2>/dev/null || true
  fi
  # wait until panel releases /etc/x-ui/x-ui.db
  local i
  for i in $(seq 1 30); do
    if ! pgrep -x x-ui >/dev/null 2>&1 && ! pgrep -f '/usr/local/x-ui/bin/xray' >/dev/null 2>&1; then
      break
    fi
    sleep 0.2
  done
  sleep 0.3
}

# Run sqlite3 with busy_timeout + retries. Stops x-ui before write attempts.
# Usage: sqlite_write DB SQL...   OR  sqlite_write DB <<'SQL' ... SQL
sqlite_write() {
  local db="$1"; shift
  local attempt out rc sql
  stop_xui
  if [[ $# -gt 0 ]]; then
    sql="$*"
  else
    sql=$(cat)
  fi
  for attempt in 1 2 3 4 5 6 7 8; do
    stop_xui
    set +e
    # .timeout does not print a value (unlike PRAGMA busy_timeout=N which echoes N)
    out=$(sqlite3 -cmd ".timeout 8000" "$db" "$sql" 2>&1)
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
      [[ -n "$out" ]] && printf '%s\n' "$out"
      return 0
    fi
    if printf '%s' "$out" | grep -qiE 'database is locked|locked \(5\)|SQLITE_BUSY'; then
      warn "sqlite busy (attempt ${attempt}/8)，停 x-ui 后重试…"
      sleep $((attempt))
      continue
    fi
    printf '%s\n' "$out" >&2
    return "$rc"
  done
  die "sqlite 写入失败（database is locked）: $db"
}

# Read-only sqlite (no stop). Still sets busy_timeout.
sqlite_read() {
  local db="$1"; shift
  # IMPORTANT: do NOT use `PRAGMA busy_timeout=N` via -cmd — sqlite3 prints N and
  # pollutes command substitutions (e.g. inbound_id becomes "5000\n1", or bare "5000"
  # is mistaken for an existing inbound id and aborts setup without --force).
  sqlite3 -cmd ".timeout 5000" "$db" "$@"
}

# ---------- step: disable IPv6 ----------
disable_ipv6() {
  log "关闭 IPv6（sysctl 持久化 + gai 优先 IPv4）"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: write /etc/sysctl.d/99-disable-ipv6.conf + apply + gai.conf"
    return
  fi
  cat >/etc/sysctl.d/99-disable-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
  # also pin common NICs if present
  local iface
  for iface in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -f "$iface" ]] || continue
    echo 1 >"$iface" 2>/dev/null || true
  done
  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >/dev/null 2>&1 || true

  # Prefer IPv4 in getaddrinfo
  if [[ -f /etc/gai.conf ]]; then
    grep -q '^precedence ::ffff:0:0/96  100' /etc/gai.conf 2>/dev/null \
      || echo 'precedence ::ffff:0:0/96  100' >>/etc/gai.conf
  else
    echo 'precedence ::ffff:0:0/96  100' >/etc/gai.conf
  fi
}

# ---------- step: deps ----------
ensure_deps() {
  log "安装依赖"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: apt/dnf install curl tar unzip sqlite3 ca-certificates openssl jq"
    return
  fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl tar unzip ca-certificates openssl sqlite3 jq >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl tar unzip ca-certificates openssl sqlite jq >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl tar unzip ca-certificates openssl sqlite jq >/dev/null
  else
    warn "未知包管理器，请自行确保 curl/tar/unzip/openssl/sqlite3/jq 可用"
  fi
}

# ---------- step: install 3x-ui ----------
install_3xui() {
  if [[ "$SKIP_INSTALL" -eq 1 ]]; then
    [[ -x /usr/local/x-ui/x-ui ]] || die "--skip-install 但未找到 /usr/local/x-ui/x-ui"
    log "跳过 3x-ui 安装"
    return
  fi
  if [[ -x /usr/local/x-ui/x-ui ]] && [[ "$FORCE" -ne 1 ]]; then
    warn "已检测到 3x-ui，跳过安装（可用 --force 强制重装面板配置侧；或 --skip-install）"
    return
  fi
  log "安装 3x-ui ${XUI_TAG}（非交互，HTTP，无 SSL，纯 IPv4）"
  [[ -n "$PANEL_PATH" ]] || PANEL_PATH="$(rand_alnum 16)"
  local user pass
  user="xui$(rand_alnum 6)"
  pass="$(rand_alnum 18)"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: curl install.sh | XUI_NONINTERACTIVE=1 ... bash ${XUI_TAG}"
    echo "DRY-RUN: user=$user port=$PANEL_PORT path=$PANEL_PATH"
    return
  fi
  export XUI_NONINTERACTIVE=1
  export XUI_SSL_MODE=none
  export XUI_DB_TYPE=sqlite
  export XUI_PANEL_PORT="$PANEL_PORT"
  export XUI_WEB_BASE_PATH="$PANEL_PATH"
  export XUI_USERNAME="$user"
  export XUI_PASSWORD="$pass"
  export XUI_ENABLE_FAIL2BAN=false
  # Official installer; pin tag. Prefer CDN / mirrors when raw.githubusercontent.com DNS fails.
  log "拉取 3x-ui 官方 install.sh（多镜像）"
  fetch_file /tmp/3xui-official-install.sh \
    "https://cdn.jsdelivr.net/gh/MHSanaei/3x-ui@${XUI_TAG}/install.sh" \
    "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_TAG}/install.sh" \
    "https://ghfast.top/https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_TAG}/install.sh"
  bash /tmp/3xui-official-install.sh "$XUI_TAG"
  # ensure listen on IPv4 only if setting exists
  /usr/local/x-ui/x-ui setting -listenIP "0.0.0.0" >/dev/null 2>&1 || true
  /usr/local/x-ui/x-ui setting -port "$PANEL_PORT" -webBasePath "$PANEL_PATH" \
    -username "$user" -password "$pass" >/dev/null 2>&1 || true
  # Avoid panel/sub both binding PANEL_PORT (3x-ui default → crash loop)
  # Must stop x-ui first — installer just started it and holds the DB lock.
  stop_xui
  python3 - "$PANEL_PORT" <<'PYSUB' 2>/dev/null || true
import sqlite3, sys, time
port = int(sys.argv[1])
db = "/etc/x-ui/x-ui.db"
last = None
for attempt in range(8):
    try:
        c = sqlite3.connect(db, timeout=8)
        c.execute("PRAGMA busy_timeout=8000")
        for k, v in [("subEnable", "false"), ("subPort", str(port + 1)), ("subListen", "")]:
            if c.execute("select 1 from settings where key=?", (k,)).fetchone():
                c.execute("update settings set value=? where key=?", (v, k))
            else:
                c.execute("insert into settings(key,value) values(?,?)", (k, v))
        c.commit()
        c.close()
        last = None
        break
    except sqlite3.OperationalError as e:
        last = e
        time.sleep(attempt + 1)
if last:
    raise SystemExit(f"sub settings write failed: {last}")
PYSUB
}

# ---------- step: pin xray ----------
pin_xray() {
  local zip name bin dest tmp
  zip="$(arch_xray_zip)"
  name="$(xray_bin_name)"
  dest="/usr/local/x-ui/bin/${name}"
  tmp=$(mktemp -d)
  log "降级/固定 Xray 到 ${XRAY_VER} → ${dest}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: download Xray v${XRAY_VER}/${zip} (github + mirrors)"
    rm -rf "$tmp"
    return
  fi
  fetch_file "${tmp}/${zip}" \
    "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${zip}" \
    "https://ghfast.top/https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/${zip}"
  unzip -qo "${tmp}/${zip}" -d "$tmp"
  [[ -x "${tmp}/xray" ]] || die "解压后未找到 xray 二进制"
  mkdir -p /usr/local/x-ui/bin
  if [[ -f "$dest" ]]; then
    cp -a "$dest" "${dest}.bak-before-${XRAY_VER}" 2>/dev/null || true
  fi
  stop_xui
  install -m 755 "${tmp}/xray" "$dest"
  # keep geo files if present in zip
  [[ -f "${tmp}/geoip.dat" ]] && cp -f "${tmp}/geoip.dat" /usr/local/x-ui/bin/ || true
  [[ -f "${tmp}/geosite.dat" ]] && cp -f "${tmp}/geosite.dat" /usr/local/x-ui/bin/ || true
  rm -rf "$tmp"
  "$dest" version || true
}

# ---------- xray template (26.3.x compatible, UseIPv4) ----------
XRAY_TEMPLATE='{
  "api": {
    "services": ["HandlerService", "LoggerService", "StatsService"],
    "tag": "api"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": 62789,
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"},
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIPv4"}
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  },
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["api"],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "stats": {},
  "log": {
    "loglevel": "warning",
    "access": "none"
  }
}'

apply_xray_template() {
  local db="/etc/x-ui/x-ui.db"
  log "写入 xrayTemplateConfig（domainStrategy/queryStrategy=UseIPv4）"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: upsert settings.xrayTemplateConfig"
    return
  fi
  [[ -f "$db" ]] || die "找不到 $db（面板未装好？）"
  # escape for SQL: single quotes doubled
  local esc
  esc=$(printf '%s' "$XRAY_TEMPLATE" | sed "s/'/''/g")
  # Official installer leaves x-ui running → SQLITE_BUSY without stop
  sqlite_write "$db" "DELETE FROM settings WHERE key='xrayTemplateConfig';
INSERT INTO settings(key,value) VALUES('xrayTemplateConfig','${esc}');"
}

# ---------- Reality keys + inbound via sqlite (compatible with 3.x clients table) ----------
setup_reality() {
  local db="/etc/x-ui/x-ui.db"
  local bin="/usr/local/x-ui/bin/$(xray_bin_name)"
  local tag="in-${REALITY_PORT}-tcp"
  local uuid sid priv pub subid
  local existing

  log "配置 VLESS+Reality :${REALITY_PORT} SNI=${SNI}"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: generate x25519 + insert inbound/clients/client_inbounds tag=$tag"
    return
  fi
  [[ -x "$bin" ]] || die "找不到 xray: $bin"
  [[ -f "$db" ]] || die "找不到 $db"

  stop_xui
  existing=$(sqlite_read "$db" "SELECT id FROM inbounds WHERE port=${REALITY_PORT} OR tag='${tag}' LIMIT 1;" 2>/dev/null || true)
  if [[ -n "$existing" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
      warn "覆盖已有入站 id=$existing（port/tag 冲突）"
      local cid
      for cid in $(sqlite_read "$db" "SELECT client_id FROM client_inbounds WHERE inbound_id=${existing};" 2>/dev/null); do
        sqlite_write "$db" "DELETE FROM client_inbounds WHERE client_id=${cid}; DELETE FROM clients WHERE id=${cid};" 2>/dev/null || true
      done
      sqlite_write "$db" "DELETE FROM client_traffics WHERE inbound_id=${existing}; DELETE FROM inbounds WHERE id=${existing};" 2>/dev/null || true
    else
      die "已存在 port=${REALITY_PORT} 或 tag=${tag} 的入站（id=$existing）。加 --force 覆盖，或换 --reality-port"
    fi
  fi

  # xray 26.3.x: PrivateKey / Password (PublicKey); older: Private key / Public key
  local keyout
  keyout=$("$bin" x25519)
  priv=$(printf '%s\n' "$keyout" | sed -n 's/^PrivateKey:[[:space:]]*//p; s/^Private key:[[:space:]]*//p' | head -1 | tr -d '\r')
  pub=$(printf '%s\n' "$keyout" | sed -n 's/^Password (PublicKey):[[:space:]]*//p; s/^Password:[[:space:]]*//p; s/^Public key:[[:space:]]*//p; s/^PublicKey:[[:space:]]*//p' | head -1 | tr -d '\r')
  [[ -n "$priv" && -n "$pub" ]] || die "x25519 密钥生成失败:\n$keyout"

  uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || "$bin" uuid)
  sid=$(openssl rand -hex 4)
  subid=$(rand_alnum 16)

  local dest_host dest_ip
  dest_host="$SNI"
  if dest_ip=$(resolve_sni_ipv4 "$SNI"); then
    log "Reality dest 解析为 IPv4: ${dest_ip}:443（serverNames 仍用 ${SNI}）"
    dest_host="$dest_ip"
  else
    warn "无法解析 ${SNI} 的 A 记录，dest 仍用域名（可能走 v6 失败）"
  fi

  local settings stream sniffing
  settings=$(jq -nc \
    --arg id "$uuid" \
    --arg email "$CLIENT_EMAIL" \
    --arg sub "$subid" \
    '{clients:[{id:$id,flow:"xtls-rprx-vision",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,comment:"",reset:0}],decryption:"none",fallbacks:[]}')

  stream=$(jq -nc \
    --arg dest "${dest_host}:443" \
    --arg sni "$SNI" \
    --arg priv "$priv" \
    --arg pub "$pub" \
    --arg sid "$sid" \
    '{network:"tcp",security:"reality",externalProxy:[],realitySettings:{show:false,xver:0,dest:$dest,serverNames:[$sni],privateKey:$priv,minClientVer:"",maxClientVer:"",maxTimediff:0,shortIds:[$sid],settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}},tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}')

  sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false,"routeOnly":false}'

  local remark="VLESS-Reality-${REALITY_PORT}"
  sqlite_write "$db" <<SQL
INSERT INTO inbounds(
  user_id, up, down, total, remark, enable, expiry_time,
  listen, port, protocol, settings, stream_settings, tag, sniffing
) VALUES (
  1, 0, 0, 0, '${remark}', 1, 0,
  '0.0.0.0', ${REALITY_PORT}, 'vless',
  '$(printf '%s' "$settings" | sed "s/'/''/g")',
  '$(printf '%s' "$stream" | sed "s/'/''/g")',
  '${tag}',
  '$(printf '%s' "$sniffing" | sed "s/'/''/g")'
);
SQL

  local inbound_id
  inbound_id=$(sqlite_read "$db" "SELECT id FROM inbounds WHERE tag='${tag}';")
  [[ -n "$inbound_id" ]] || die "写入 inbounds 失败"

  # 3.x clients table + link
  local has_clients
  has_clients=$(sqlite_read "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='clients';")
  if [[ -n "$has_clients" ]]; then
    # Prefer full schema; fall back if optional columns missing
    if ! sqlite_write "$db" "INSERT INTO clients(email, sub_id, uuid, flow, enable, limit_ip, total_gb, expiry_time, comment, traffic_reset, created_at, updated_at)
      VALUES('${CLIENT_EMAIL}','${subid}','${uuid}','xtls-rprx-vision',1,0,0,0,'','never',
      CAST(strftime('%s','now') AS INTEGER)*1000, CAST(strftime('%s','now') AS INTEGER)*1000);" 2>/dev/null; then
      sqlite_write "$db" "INSERT INTO clients(email, sub_id, uuid, flow, enable, limit_ip, total_gb, expiry_time, comment, created_at, updated_at)
        VALUES('${CLIENT_EMAIL}','${subid}','${uuid}','xtls-rprx-vision',1,0,0,0,'',
        CAST(strftime('%s','now') AS INTEGER)*1000, CAST(strftime('%s','now') AS INTEGER)*1000);"
    fi
    local client_id
    client_id=$(sqlite_read "$db" "SELECT id FROM clients WHERE email='${CLIENT_EMAIL}' ORDER BY id DESC LIMIT 1;")
    [[ -n "$client_id" ]] || die "写入 clients 表失败（3x-ui 会清空 settings.clients 导致节点不可用）"
    local has_ci
    has_ci=$(sqlite_read "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='client_inbounds';")
    if [[ -n "$has_ci" ]]; then
      # 3x-ui ListForInbound 用 flow_override 覆盖 clients.flow；空字符串会丢掉 Vision → 客户端超时
      sqlite_write "$db" "INSERT OR REPLACE INTO client_inbounds(client_id,inbound_id,flow_override,created_at)
        VALUES(${client_id},${inbound_id},'xtls-rprx-vision',CAST(strftime('%s','now') AS INTEGER)*1000);"
      local fov
      fov=$(sqlite_read "$db" "SELECT flow_override FROM client_inbounds WHERE client_id=${client_id} AND inbound_id=${inbound_id};")
      [[ "$fov" == "xtls-rprx-vision" ]] || die "flow_override 写入失败（当前='$fov'），节点会超时"
      log "clients#${client_id} ↔ inbound#${inbound_id} flow_override=xtls-rprx-vision"
    fi
  fi

  # client_traffics row (older + newer panels)
  sqlite_write "$db" "INSERT OR IGNORE INTO client_traffics(inbound_id,enable,email,up,down,expiry_time,total,reset)
    VALUES(${inbound_id},1,'${CLIENT_EMAIL}',0,0,0,0,0);" 2>/dev/null || true

  # persist share facts for reprint
  install -d -m 700 /etc/x-ui
  umask 077
  cat >/etc/x-ui/reality-ipv4.env <<EOF
REALITY_PORT=${REALITY_PORT}
SNI=${SNI}
UUID=${uuid}
PUBLIC_KEY=${pub}
SHORT_ID=${sid}
PRIVATE_KEY=${priv}
CLIENT_EMAIL=${CLIENT_EMAIL}
SUB_ID=${subid}
INBOUND_TAG=${tag}
XRAY_VER=${XRAY_VER}
EOF
  chmod 600 /etc/x-ui/reality-ipv4.env
}

restart_panel() {
  log "重启 x-ui"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: systemctl restart x-ui"
    return
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl restart x-ui
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service x-ui restart
  else
    # 3.11.x: no "restart" subcommand — start via systemd unit ExecStart=x-ui run
    /usr/local/x-ui/x-ui run >/dev/null 2>&1 &
    sleep 1
  fi
  sleep 3
}

# After panel restart: ensure pinned Xray sticks, Vision flow present, listen IPv4-only.
verify_and_fix() {
  local bin="/usr/local/x-ui/bin/$(xray_bin_name)"
  local cfg="/usr/local/x-ui/bin/config.json"
  local db="/etc/x-ui/x-ui.db"
  local tag="in-${REALITY_PORT}-tcp"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "DRY-RUN: verify xray ${XRAY_VER} + Vision flow + 0.0.0.0:${REALITY_PORT}"
    return
  fi

  # Re-pin if panel overwrote binary on start
  local ver
  ver=$("$bin" version 2>/dev/null | head -1 || true)
  if [[ "$ver" != *"${XRAY_VER}"* ]]; then
    warn "Xray 版本被面板改回（$ver），重新固定到 ${XRAY_VER}"
    pin_xray
    restart_panel
  else
    log "Xray 版本确认: ${ver}"
  fi

  # Ensure flow_override still Vision (panel may rewrite rows)
  if [[ -f "$db" ]]; then
    stop_xui
    sqlite_write "$db" "UPDATE client_inbounds SET flow_override='xtls-rprx-vision'
      WHERE inbound_id IN (SELECT id FROM inbounds WHERE tag='${tag}')
        AND (flow_override IS NULL OR flow_override='');" 2>/dev/null || true
    sqlite_write "$db" "UPDATE clients SET flow='xtls-rprx-vision'
      WHERE id IN (SELECT client_id FROM client_inbounds
        WHERE inbound_id IN (SELECT id FROM inbounds WHERE tag='${tag}'))
        AND (flow IS NULL OR flow='');" 2>/dev/null || true
    # Force listen IPv4
    sqlite_write "$db" "UPDATE inbounds SET listen='0.0.0.0' WHERE tag='${tag}' AND (listen IS NULL OR listen='' OR listen='::');" 2>/dev/null || true
  fi

  # Restart once more if we fixed DB after first boot
  restart_panel

  # Validate generated config.json has Vision flow + no [::] listen on Reality port
  if [[ -f "$cfg" ]]; then
    python3 - "$cfg" "$REALITY_PORT" <<'PYCHK' || warn "config.json 校验未通过，请检查面板入站"
import json, sys
cfg, port = sys.argv[1], int(sys.argv[2])
with open(cfg) as f:
    data = json.load(f)
found = False
for ib in data.get("inbounds", []):
    if ib.get("port") != port:
        continue
    found = True
    listen = ib.get("listen") or ""
    if listen in ("::", "[::]", "::0"):
        print("LISTEN_V6", listen)
        sys.exit(2)
    clients = (ib.get("settings") or {}).get("clients") or []
    if not clients:
        print("NO_CLIENTS")
        sys.exit(3)
    flows = [c.get("flow") for c in clients]
    if "xtls-rprx-vision" not in flows:
        print("NO_VISION", flows)
        sys.exit(4)
    print("OK", listen or "0.0.0.0", len(clients))
    break
if not found:
    print("NO_INBOUND")
    sys.exit(5)
PYCHK
  fi

  # Port must be listening on IPv4
  if command -v ss >/dev/null 2>&1; then
    if ss -lntp 2>/dev/null | grep -E "[:.]${REALITY_PORT} " | grep -q .; then
      log "已监听 :${REALITY_PORT}"
      ss -lntp 2>/dev/null | grep -E "[:.]${REALITY_PORT} " || true
    else
      warn "未看到 :${REALITY_PORT} 监听，xray/面板可能未起来"
    fi
  fi
}

print_result() {
  local ip panel_url user pass path port
  ip=$(detect_public_ipv4)
  if [[ "$DRY_RUN" -eq 1 ]]; then
    cat <<EOF

DRY-RUN 摘要
  公网 IPv4:     ${ip}
  面板端口:      ${PANEL_PORT}
  Reality 端口:  ${REALITY_PORT}
  SNI:           ${SNI}
  Xray:          ${XRAY_VER}
  3x-ui:         ${XUI_TAG}
  IPv6:          关闭
EOF
    return
  fi

  path=$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null | awk -F': ' '/webBasePath/{gsub(/^\//,"",$2); print $2; exit}')
  port=$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null | awk -F': ' '/^port:/{print $2; exit}')
  port="${port:-$PANEL_PORT}"
  # credentials from install-result if present
  if [[ -f /etc/x-ui/install-result.env ]]; then
    # shellcheck disable=SC1091
    source /etc/x-ui/install-result.env
    user="${XUI_USERNAME:-}"
    pass="${XUI_PASSWORD:-}"
    path="${XUI_WEB_BASE_PATH:-$path}"
    port="${XUI_PANEL_PORT:-$port}"
  fi
  panel_url="http://${ip}:${port}/${path}"

  # shellcheck disable=SC1091
  source /etc/x-ui/reality-ipv4.env

  local link
  link="vless://${UUID}@${ip}:${REALITY_PORT}?type=tcp&encryption=none&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${SNI}&sid=${SHORT_ID}&spx=%2F&flow=xtls-rprx-vision#VLESS-Reality-${REALITY_PORT}"

  umask 077
  cat >/etc/x-ui/reality-share.txt <<EOF
PANEL_URL=${panel_url}
PANEL_USER=${user:-}
PANEL_PASS=${pass:-}
VLESS_LINK=${link}
PUBLIC_IP=${ip}
EOF
  chmod 600 /etc/x-ui/reality-share.txt

  echo
  echo "========== 安装完成（纯 IPv4）=========="
  echo "面板:     ${panel_url}"
  [[ -n "${user:-}" ]] && echo "用户名:   ${user}"
  [[ -n "${pass:-}" ]] && echo "密码:     ${pass}"
  echo "Xray:     ${XRAY_VER}"
  echo "Reality:  ${ip}:${REALITY_PORT}  SNI=${SNI}"
  echo
  echo "分享链接（仅 IPv4 字面量）:"
  echo "${link}"
  echo
  echo "密钥已写入 /etc/x-ui/reality-ipv4.env（权限 600），请自行保管；本脚本只打印一次。"
  echo
  echo "【重要】若装在 Incus/LXC 容器里：宿主机必须把 ${port}（面板）和 ${REALITY_PORT}（节点）"
  echo "  DNAT/proxy 进容器，否则外网必超时。22/8443 为系统保留口，不要占用。"
  echo "  换伪装可用: bash $0 --skip-install --force --sni dl.google.com --public-ip ${ip}"
  echo "======================================"
}

# ---------- main ----------
main() {
  log "3x-ui IPv4 Reality 一键安装"
  echo "  panel=${PANEL_PORT}  reality=${REALITY_PORT}  sni=${SNI}  xray=${XRAY_VER}  dry_run=${DRY_RUN}"
  ensure_dns
  disable_ipv6
  ensure_deps
  install_3xui
  pin_xray
  apply_xray_template
  setup_reality
  restart_panel
  verify_and_fix
  print_result
}

main
