#!/usr/bin/env bash
# ==============================================================================
#  Ubuntu 一键部署 AstrBot + SnowLuma（Docker / Docker Compose）
#
#  设计依据（安装时请以官方最新文档为准）：
#    AstrBot Docker 部署:
#      https://docs.astrbot.app/deploy/astrbot/docker.html
#    SnowLuma Docker 框架:
#      https://github.com/SnowLuma/SnowLuma.Docker.Framework
#    SnowLuma 配置 / 反向 WebSocket 对接 AstrBot:
#      https://snowluma.github.io/zh/docs/guide/configuration
#      https://snowluma.github.io/zh/docs/guide/connect-bot
#
#  特点：
#    * 仅安装 Docker Engine（不安装 Docker Desktop）
#    * 自动检查 Ubuntu / 架构 / 内核 / 磁盘 / 内存 / 端口
#    * 终端实时进度条 + 进度条下方单行显示当前命令
#    * 自动生成强密码、Token，并自动接通 SnowLuma -> AstrBot 的反向 WS
#    * 可选公网访问；留空自动探测公网 IPv4
#    * 安装结束后生成本地管理脚本（start/stop/restart/status/logs/urls/update）
#
#  用法：
#    sudo bash install-astrbot-snowluma.sh
#    sudo bash install-astrbot-snowluma.sh --public
#    sudo bash install-astrbot-snowluma.sh --private --yes
#    sudo bash install-astrbot-snowluma.sh --dir /opt/astrbot-snowluma
#
#  注意：
#    - 脚本必须以 root（或 sudo）运行。
#    - 自动升级 Ubuntu 发行版属于高风险操作，默认不静默执行；低于 18.04 时
#      需要显式加 --allow-os-upgrade。20.04/22.04/24.04/24.10/25.04 等直接支持。
# ==============================================================================

set -Eeuo pipefail
umask 022

SCRIPT_VERSION="1.0.0"
DEFAULT_INSTALL_DIR="/opt/astrbot-snowluma"
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
ASTROBOT_IMAGE="${ASTROBOT_IMAGE:-soulter/astrbot:latest}"
SNOWLUMA_IMAGE="${SNOWLUMA_IMAGE:-motricseven7/snowluma:latest}"
SNOWLUMA_UID="${SNOWLUMA_UID:-1000}"
SNOWLUMA_GID="${SNOWLUMA_GID:-1000}"
MIN_UBUNTU="18.04"

WANT_PUBLIC="${WANT_PUBLIC:-}"
PUBLIC_IP_OPT="${PUBLIC_IP_OPT:-}"
ASSUME_YES="${ASSUME_YES:-0}"
ALLOW_OS_UPGRADE="${ALLOW_OS_UPGRADE:-0}"
DRY_RUN="${DRY_RUN:-0}"

NEW_INSTALL=0
ACCESS_MODE="private"
ACCESS_HOST="127.0.0.1"
BIND_ADDR="127.0.0.1"

ASTROBOT_WEBUI_HOST_PORT="6185"
SNOWLUMA_WEBUI_HOST_PORT="5099"
SNOWLUMA_NOVNC_HOST_PORT="6081"
SNOWLUMA_ONEBOT_HTTP_HOST_PORT="3000"
SNOWLUMA_ONEBOT_WS_HOST_PORT="3001"

ASTRBOT_DASHBOARD_PASSWORD=""
SNOWLUMA_WEBUI_PASSWORD=""
SNOWLUMA_VNC_PASSWORD=""
SNOWLUMA_HTTP_TOKEN=""
SNOWLUMA_WS_TOKEN=""
ONEBOT_REVERSE_TOKEN=""

TZ_VALUE="Asia/Shanghai"
OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
ARCH_RAW=""
ARCH_DEB=""
LOG_FILE=""
ENV_FILE=""
COMPOSE_FILE=""
UI_TTY=0
UI_STARTED=0
UI_FINISHED=0
UI_LAST_RENDER=""
CURRENT_PCT=0

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
fi

say()  { printf '%s\n' "$*"; }
info() { printf '%s%s%s\n' "${C_CYAN}" "$*" "${C_RESET}"; }
warn() { printf '%s[警告]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
err()  { printf '%s[错误]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*"; }

log() {
  [[ -n "$LOG_FILE" ]] || return 0
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

die() {
  err "$*"
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '%s日志:%s %s\n' "${C_DIM}" "${C_RESET}" "$LOG_FILE" >&2
  fi
  exit 1
}

usage() {
  cat <<'EOF'
Ubuntu 一键部署 AstrBot + SnowLuma

用法:
  sudo bash install-astrbot-snowluma.sh [选项]

选项:
  --dir PATH             安装目录（默认 /opt/astrbot-snowluma）
  --public               开启公网访问（WebUI / noVNC 绑定 0.0.0.0）
  --private              仅本机访问（默认；绑定 127.0.0.1）
  --public-ip IP         公网 IP 或域名（隐含 --public；留空时自动探测）
  --yes, -y              非交互：未指定访问模式时按 --private 处理
  --allow-os-upgrade     Ubuntu < 18.04 时允许调用 do-release-upgrade（高风险）
  --dry-run              只检查并打印计划，不修改系统
  -h, --help             显示本帮助
  -v, --version          显示脚本版本

示例:
  sudo bash install-astrbot-snowluma.sh
  sudo bash install-astrbot-snowluma.sh --public
  sudo bash install-astrbot-snowluma.sh --public --public-ip 203.0.113.10
  sudo bash install-astrbot-snowluma.sh --private --yes

安装完成后:
  sudo astrbot-snowluma start
  sudo astrbot-snowluma status
  sudo astrbot-snowluma restart
  sudo astrbot-snowluma logs
  sudo astrbot-snowluma urls

默认端口:
  AstrBot WebUI       6185/tcp
  SnowLuma WebUI      5099/tcp
  SnowLuma noVNC      6081/tcp
  SnowLuma OneBot     3000/tcp (仅 127.0.0.1)
  SnowLuma OneBot WS  3001/tcp (仅 127.0.0.1)
  AstrBot OneBot WS   6199/tcp (仅 Docker 内部网络，不映射到宿主机)

说明:
  * 不安装 Docker Desktop，仅安装 Docker Engine / Compose v2。
  * 密码和 OneBot Token 在安装时生成，保存在安装目录的 credentials.txt（600）。
  * 管理脚本不会输出密码；需要查看请使用 sudo cat credentials.txt。
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --dir)
        [[ $# -ge 2 ]] || die "--dir 需要一个路径"
        INSTALL_DIR="$2"
        shift 2
        ;;
      --dir=*)
        INSTALL_DIR="${1#*=}"
        shift
        ;;
      --public)
        WANT_PUBLIC=1
        shift
        ;;
      --private)
        WANT_PUBLIC=0
        shift
        ;;
      --public-ip)
        [[ $# -ge 2 ]] || die "--public-ip 需要一个 IP 或域名"
        PUBLIC_IP_OPT="$2"
        WANT_PUBLIC=1
        shift 2
        ;;
      --public-ip=*)
        PUBLIC_IP_OPT="${1#*=}"
        WANT_PUBLIC=1
        shift
        ;;
      --yes|-y)
        ASSUME_YES=1
        shift
        ;;
      --allow-os-upgrade)
        ALLOW_OS_UPGRADE=1
        shift
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      -v|--version)
        printf '%s\n' "$SCRIPT_VERSION"
        exit 0
        ;;
      *)
        die "未知参数: $1（使用 --help 查看帮助）"
        ;;
    esac
  done

  if [[ -z "$INSTALL_DIR" || "$INSTALL_DIR" == "/" ]]; then
    die "安装目录不能为空或 /"
  fi
  case "$INSTALL_DIR" in
    /*) ;;
    *) INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
  esac
  INSTALL_DIR="$(readlink -m "$INSTALL_DIR")"
  case "$INSTALL_DIR" in
    /|/bin|/boot|/dev|/etc|/lib|/lib64|/proc|/root|/sbin|/sys|/usr|/var)
      die "拒绝把安装目录设置为系统目录: $INSTALL_DIR"
      ;;
  esac
}

require_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    return 0
  fi
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$SCRIPT_PATH" "$@"
  fi
  die "需要 root 权限，请使用 sudo 运行。"
}

ui_init() {
  if [[ -t 1 ]]; then
    UI_TTY=1
    printf '\033[?25l'
  fi
  trap ui_on_exit EXIT
}

ui_on_exit() {
  local rc=$?
  trap - EXIT
  if (( UI_TTY )); then
    if (( UI_FINISHED == 0 )); then
      printf '\n'
    fi
    printf '\033[?25h'
  fi
  exit "$rc"
}

ui_render() {
  local pct="$1"
  local desc="$2"
  local cmd="$3"
  local elapsed="${4:-0}"
  local cols width fill empty bar cmdline max desc_max

  (( pct < 0 )) && pct=0
  (( pct > 100 )) && pct=100

  cols="${COLUMNS:-0}"
  if ! [[ "$cols" =~ ^[0-9]+$ ]] || (( cols < 40 )); then
    cols="$(tput cols 2>/dev/null || printf '100')"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
  (( cols < 60 )) && cols=60
  # 中文描述按 2 列宽保守估算，避免进度条在窄终端换行。
  desc_max=$(( (cols - 44) / 2 ))
  (( desc_max < 6 )) && desc_max=6
  if (( ${#desc} > desc_max )); then
    desc="${desc:0:desc_max-1}..."
  fi
  width=32
  fill=$((pct * width / 100))
  empty=$((width - fill))

  printf -v fill_str '%*s' "$fill" ''
  printf -v empty_str '%*s' "$empty" ''
  fill_str="${fill_str// /#}"
  empty_str="${empty_str// /-}"
  bar="[${fill_str}${empty_str}] $(printf '%3d' "$pct")%  ${desc}"

  if (( ${#bar} > cols - 2 )); then
    bar="${bar:0:cols-5}..."
  fi

  cmdline="  \$ ${cmd}"
  max=$((cols - 2))
  if (( ${#cmdline} > max )); then
    cmdline="${cmdline:0:max-3}..."
  fi

  if (( UI_TTY == 0 )); then
    local key="${pct}|${desc}|${cmd}"
    if [[ "$key" != "$UI_LAST_RENDER" ]]; then
      printf '[%3d%%] %s\n  $ %s\n' "$pct" "$desc" "$cmd"
      UI_LAST_RENDER="$key"
    fi
    return 0
  fi

  if (( UI_STARTED == 0 )); then
    printf '%s\n' "$bar"
    printf '%s' "$cmdline"
    UI_STARTED=1
  else
    printf '\r\033[2K%s' "$cmdline"
    printf '\033[1A\r\033[2K%s\n' "$bar"
  fi
}

ui_finish() {
  CURRENT_PCT=100
  if (( UI_TTY )); then
    ui_render 100 "全部完成" "部署完成"
    printf '\n\033[?25h'
  else
    printf '[100%%] 全部完成\n'
  fi
  UI_FINISHED=1
}

format_cmd() {
  if [[ "${1:-}" == "bash" && "${2:-}" == "-c" && $# -ge 3 ]]; then
    printf '%s' "$3"
    return 0
  fi
  local out="" a
  for a in "$@"; do
    out+="$a "
  done
  printf '%s' "${out% }"
}

_run_cmd_impl() {
  local allow_fail="$1"
  local target="$2"
  local desc="$3"
  shift 3
  local display start_pct start_ts pid rc elapsed remain step

  display="$(format_cmd "$@")"
  log "----- ${desc} -----"
  log "CMD: ${display}"

  (( target > CURRENT_PCT )) || target=$((CURRENT_PCT + 1))
  (( target > 100 )) && target=100
  start_pct=$CURRENT_PCT
  start_ts=$SECONDS

  "$@" >>"$LOG_FILE" 2>&1 &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    elapsed=$((SECONDS - start_ts))
    remain=$((target - CURRENT_PCT))
    if (( remain > 1 )); then
      step=$((remain / 10))
      (( step < 1 )) && step=1
      CURRENT_PCT=$((CURRENT_PCT + step))
      (( CURRENT_PCT >= target )) && CURRENT_PCT=$((target - 1))
    fi
    ui_render "$CURRENT_PCT" "$desc" "$display" "$elapsed"
    sleep 0.2
  done

  rc=0
  wait "$pid" || rc=$?
  if (( rc == 0 )); then
    CURRENT_PCT=$target
    ui_render "$CURRENT_PCT" "$desc" "$display" "$((SECONDS - start_ts))"
    log "OK: ${desc}"
    return 0
  fi

  CURRENT_PCT=$start_pct
  ui_render "$CURRENT_PCT" "失败: ${desc}" "$display" "$((SECONDS - start_ts))"
  log "FAILED(${rc}): ${desc}"

  if (( allow_fail )); then
    (( UI_TTY )) && printf '\n'
    return "$rc"
  fi

  (( UI_TTY )) && printf '\n'
  if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
    printf '%s----- 最近日志 -----%s\n' "${C_DIM}" "${C_RESET}" >&2
    tail -n 40 "$LOG_FILE" >&2 || true
    printf '%s-------------------%s\n' "${C_DIM}" "${C_RESET}" >&2
  fi
  die "命令执行失败：${display}"
}

run_cmd() {
  _run_cmd_impl 0 "$@"
}

run_cmd_allow_fail() {
  _run_cmd_impl 1 "$@"
}

run_shell() {
  local target="$1"
  local desc="$2"
  local cmd="$3"
  run_cmd "$target" "$desc" bash -c "$cmd"
}

detect_tz() {
  local tz=""
  if [[ -r /etc/timezone ]]; then
    tz="$(head -n1 /etc/timezone 2>/dev/null | tr -d '[:space:]')"
  fi
  if [[ -z "$tz" ]] && command -v timedatectl >/dev/null 2>&1; then
    tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  [[ -z "$tz" ]] && tz="Asia/Shanghai"
  [[ -f "/usr/share/zoneinfo/${tz}" ]] || tz="Asia/Shanghai"
  TZ_VALUE="$tz"
}

detect_os() {
  [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release，仅支持 Ubuntu。"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
  ARCH_RAW="$(uname -m)"
  ARCH_DEB="$(dpkg --print-architecture 2>/dev/null || true)"

  [[ "$OS_ID" == "ubuntu" ]] || die "当前系统是 ${PRETTY_NAME:-$OS_ID}，本脚本仅支持 Ubuntu。"
  [[ -n "$OS_VERSION_ID" ]] || die "无法识别 Ubuntu 版本。"

  if dpkg --compare-versions "$OS_VERSION_ID" lt "$MIN_UBUNTU"; then
    warn "检测到 Ubuntu ${OS_VERSION_ID}，低于脚本安全支持的最低版本 ${MIN_UBUNTU}。"
    if (( ALLOW_OS_UPGRADE == 1 )); then
      warn "已指定 --allow-os-upgrade：即将执行 do-release-upgrade。此操作可能重启并中断 SSH。"
      if (( DRY_RUN == 1 )); then
        say "[dry-run] 将执行 do-release-upgrade -f DistUpgradeViewNonInteractive"
        exit 0
      fi
      run_cmd 2 "自动升级 Ubuntu（高风险）" bash -c \
        'export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a; apt-get update -y && apt-get install -y update-manager-core && do-release-upgrade -f DistUpgradeViewNonInteractive'
      die "系统升级流程已结束。请重启并确认版本 >= ${MIN_UBUNTU} 后重新运行本脚本。"
    fi
    die "Ubuntu ${OS_VERSION_ID} 过旧，AstrBot / SnowLuma 所需 Docker 与内核可能不受支持。请先升级到 Ubuntu 20.04+；确需脚本自动升级可加 --allow-os-upgrade（高风险）。"
  fi

  if dpkg --compare-versions "$OS_VERSION_ID" le "20.04"; then
    warn "Ubuntu ${OS_VERSION_ID} 已过标准支持期，将使用兼容模式安装；建议升级到 22.04/24.04。"
  fi

  case "$ARCH_RAW:$ARCH_DEB" in
    x86_64:amd64|amd64:amd64) ;;
    aarch64:arm64|arm64:arm64) ;;
    *) die "不支持的架构: ${ARCH_RAW} / ${ARCH_DEB}。仅支持 amd64 与 arm64。" ;;
  esac

  if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
    warn "检测到 WSL。Docker 的网络与端口映射可能受限，生产环境建议使用原生 Ubuntu 服务器。"
  fi

  detect_tz
}

kernel_major_minor() {
  local k
  k="$(uname -r)"
  printf '%s\n' "$k" | awk -F'[.-]' '{print $1"."$2}'
}

preflight() {
  local mem_kb disk_kb kernel_ver

  detect_os

  kernel_ver="$(kernel_major_minor)"
  if dpkg --compare-versions "$kernel_ver" lt "4.4"; then
    die "内核 ${kernel_ver} 过旧。Docker 需要 >= 4.4（建议 5.x）。请先升级内核。"
  fi

  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  disk_kb="$(df -Pk / | awk 'NR==2 {print $4}')"
  if (( mem_kb < 1024 * 1024 )); then
    die "内存不足 1 GiB（当前 $((mem_kb / 1024)) MiB）。SnowLuma + QQ + AstrBot 至少需要约 2 GiB。"
  elif (( mem_kb < 2 * 1024 * 1024 )); then
    warn "内存约 $((mem_kb / 1024)) MiB，低于建议的 2 GiB；QQ 扫码/运行可能不稳定。"
  fi
  if (( disk_kb < 8 * 1024 * 1024 )); then
    die "根分区剩余空间不足 8 GiB（当前 $((disk_kb / 1024 / 1024)) GiB）。镜像与数据至少需要约 8-10 GiB。"
  fi

  info "系统检查"
  say "  Ubuntu        : ${OS_VERSION_ID} (${OS_CODENAME:-unknown})"
  say "  架构          : ${ARCH_DEB} (${ARCH_RAW})"
  say "  内核          : $(uname -r)"
  say "  内存          : $((mem_kb / 1024)) MiB"
  say "  根分区可用    : $((disk_kb / 1024 / 1024)) GiB"
  say "  时区          : ${TZ_VALUE}"
  say "  安装目录      : ${INSTALL_DIR}"

  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    local name project
    for name in astrbot snowluma; do
      if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        project="$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)"
        if [[ "$project" != "astrbot-snowluma" ]]; then
          if (( DRY_RUN == 1 )); then
            warn "dry-run：检测到已有容器 ${name}，实际安装会停止以避免覆盖。"
          else
            die "检测到已存在的容器 ${name}（不属于本安装目录）。为避免破坏现有数据，请先处理该容器，或使用另一台机器。"
          fi
        elif [[ ! -f "$ENV_FILE" ]]; then
          die "检测到本项目的容器 ${name}，但缺少 ${ENV_FILE}。请恢复 .env，或先移除旧容器/数据后重装。"
        fi
      fi
    done
  fi

  if [[ ! -f "$ENV_FILE" ]] && { [[ -f "$INSTALL_DIR/astrbot/data/cmd_config.json" ]] || [[ -f "$INSTALL_DIR/snowluma/data/config/onebot.json" ]]; }; then
    die "检测到已有 AstrBot/SnowLuma 数据，但缺少 ${ENV_FILE}。为避免用新密码覆盖旧安装，请恢复 .env，或备份并移走数据目录。"
  fi

  if (( DRY_RUN == 1 )); then
    say ""
    info "dry-run 模式：系统检查通过；不会安装任何软件或写入配置。"
    exit 0
  fi
}

is_valid_ipv4() {
  local ip="$1" o
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"$ip"
  for o in "${octets[@]}"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( 10#$o >= 0 && 10#$o <= 255 )) || return 1
  done
  return 0
}

is_valid_access_host() {
  local h="$1"
  [[ -n "$h" && ${#h} -le 253 ]] || return 1
  [[ "$h" != *" "* && "$h" != *"/"* && "$h" != *":"* ]] || return 1
  if [[ "$h" =~ ^[0-9.]+$ ]]; then
    is_valid_ipv4 "$h"
    return
  fi
  [[ "$h" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || return 1
  return 0
}

detect_public_ip() {
  local url ip
  for url in \
    "https://api.ipify.org" \
    "https://ipv4.icanhazip.com" \
    "https://ifconfig.me/ip" \
    "https://www.cloudflare.com/cdn-cgi/trace"; do
    if command -v curl >/dev/null 2>&1; then
      ip="$(curl -4 -fsS --connect-timeout 5 --max-time 8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    elif command -v wget >/dev/null 2>&1; then
      ip="$(wget -4 -qO- --timeout=8 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    else
      break
    fi
    if [[ "$url" == *"cloudflare.com"* ]]; then
      ip="$(printf '%s\n' "$ip" | awk -F= '/^ip=/ {print $2; exit}')"
    fi
    if is_valid_ipv4 "$ip"; then
      printf '%s' "$ip"
      return 0
    fi
  done

  ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $0 != "127.0.0.1" {print; exit}')"
  if is_valid_ipv4 "$ip"; then
    printf '%s' "$ip"
    return 0
  fi
  return 1
}

prompt_public_access() {
  local answer ip

  if [[ -z "$WANT_PUBLIC" ]]; then
    if (( ASSUME_YES == 1 )); then
      WANT_PUBLIC=0
    elif [[ -r /dev/tty ]]; then
      printf '\n%s是否需要从公网远程访问 AstrBot / SnowLuma？%s\n' "${C_BOLD}" "${C_RESET}" >/dev/tty
      printf '  选择“是”会把 WebUI 和 noVNC 绑定到 0.0.0.0；选择“否”仅绑定 127.0.0.1。\n' >/dev/tty
      printf '  请选择 [y/N]: ' >/dev/tty
      read -r answer </dev/tty || answer=""
      case "$answer" in
        y|Y|yes|YES|是) WANT_PUBLIC=1 ;;
        *) WANT_PUBLIC=0 ;;
      esac
    else
      WANT_PUBLIC=0
      warn "非交互环境且未指定 --public，默认仅本机访问。"
    fi
  fi

  if (( WANT_PUBLIC == 1 )); then
    ACCESS_MODE="public"
    BIND_ADDR="0.0.0.0"
    if [[ -z "$PUBLIC_IP_OPT" ]]; then
      if (( ASSUME_YES == 0 )) && [[ -r /dev/tty ]]; then
        printf '公网 IP 或域名（留空自动探测）: ' >/dev/tty
        read -r PUBLIC_IP_OPT </dev/tty || PUBLIC_IP_OPT=""
      fi
    fi
    if [[ -z "$PUBLIC_IP_OPT" ]]; then
      info "正在自动探测公网 IPv4 ..."
      PUBLIC_IP_OPT="$(detect_public_ip || true)"
      if [[ -z "$PUBLIC_IP_OPT" ]]; then
        die "无法自动探测公网 IP。请重新运行并填写 --public-ip <你的公网IP或域名>。"
      fi
      warn "未能从用户输入确认，自动探测结果：${PUBLIC_IP_OPT}"
    fi

    PUBLIC_IP_OPT="$(printf '%s' "$PUBLIC_IP_OPT" | tr -d '[:space:]')"
    PUBLIC_IP_OPT="${PUBLIC_IP_OPT#http://}"
    PUBLIC_IP_OPT="${PUBLIC_IP_OPT#https://}"
    PUBLIC_IP_OPT="${PUBLIC_IP_OPT%%/}"
    if ! is_valid_access_host "$PUBLIC_IP_OPT"; then
      die "公网地址格式无效：${PUBLIC_IP_OPT}。请输入 IPv4 或域名（不支持 IPv6/端口/路径）。"
    fi
    ACCESS_HOST="$PUBLIC_IP_OPT"
    ok "公网访问已开启，访问地址将使用 ${ACCESS_HOST}"
  else
    ACCESS_MODE="private"
    BIND_ADDR="127.0.0.1"
    ACCESS_HOST="127.0.0.1"
    ok "仅本机访问；远程请使用 SSH 隧道（管理脚本会给出命令）"
  fi
}

setup_install_dir() {
  if [[ -e "$INSTALL_DIR" && ! -d "$INSTALL_DIR" ]]; then
    die "安装路径已存在且不是目录：$INSTALL_DIR"
  fi
  mkdir -p "$INSTALL_DIR/logs"
  chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/logs"
  ENV_FILE="$INSTALL_DIR/.env"
  COMPOSE_FILE="$INSTALL_DIR/compose.yaml"
  LOG_FILE="${INSTALL_DIR}/logs/install-$(date '+%Y%m%d-%H%M%S').log"
  : >"$LOG_FILE"
  chmod 600 "$LOG_FILE"
  log "AstrBot + SnowLuma installer v${SCRIPT_VERSION}"
}

fix_eol_apt_sources() {
  local codename="$1"
  [[ -f /etc/apt/sources.list ]] || return 1
  cp -a /etc/apt/sources.list "/etc/apt/sources.list.astrbot-bak-$(date +%s)" || true
  sed -i -E \
    -e 's|https?://(archive|security)\.ubuntu\.com/ubuntu/?|http://old-releases.ubuntu.com/ubuntu/|g' \
    -e 's|https?://ports\.ubuntu\.com/ubuntu-ports/?|http://old-releases.ubuntu.com/ubuntu/|g' \
    /etc/apt/sources.list || return 1
  log "已把 Ubuntu ${codename} 的 APT 源切换到 old-releases.ubuntu.com"
  return 0
}

apt_update_with_fallback() {
  if run_cmd_allow_fail 4 "更新 APT 软件源" \
      env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::Retries=3 update -y; then
    return 0
  fi
  if dpkg --compare-versions "$OS_VERSION_ID" le "20.04"; then
    warn "APT 更新失败，尝试把旧版 Ubuntu 源切换到 old-releases。"
    fix_eol_apt_sources "$OS_CODENAME" || die "APT 源修复失败，请检查 /etc/apt/sources.list。"
    run_cmd 4 "重试更新 APT 软件源" \
      env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -o Acquire::Retries=3 update -y
  else
    die "APT 更新失败。请检查网络、DNS 或 /etc/apt/sources.list 后重试。"
  fi
}

install_base_dependencies() {
  local pkgs=(
    ca-certificates
    curl
    gnupg
    lsb-release
    apt-transport-https
    jq
    openssl
    iproute2
    procps
    tar
    gzip
    coreutils
    util-linux
    python3
  )
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export APT_LISTCHANGES_FRONTEND=none

  apt_update_with_fallback
  run_cmd 9 "安装基础依赖（curl/gpg/jq/iproute2/python3 等）" \
    apt-get -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            -o Acquire::Retries=3 \
            install -y --no-install-recommends "${pkgs[@]}"
}

port_in_use() {
  local p="$1" out
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -H -ltn "sport = :${p}" 2>/dev/null || true)"
    [[ -n "$out" ]]
    return
  fi
  if command -v netstat >/dev/null 2>&1; then
    out="$(netstat -ltn 2>/dev/null | awk -v p=":${p}" '$4 ~ p"$" {print; exit}')"
    [[ -n "$out" ]]
    return
  fi
  return 1
}

pick_port() {
  local def="$1" label="$2" p="$1" n=0
  while port_in_use "$p"; do
    p=$((p + 1))
    n=$((n + 1))
    if (( p > 65535 || n > 200 )); then
      die "无法为 ${label} 找到空闲端口（从 ${def} 开始尝试了 200 个）。"
    fi
  done
  if (( p != def )); then
    warn "${label} 默认端口 ${def} 已被占用，自动改用 ${p}。"
  fi
  printf '%s' "$p"
}

choose_ports() {
  ASTROBOT_WEBUI_HOST_PORT="$(pick_port 6185 "AstrBot WebUI")"
  SNOWLUMA_WEBUI_HOST_PORT="$(pick_port 5099 "SnowLuma WebUI")"
  SNOWLUMA_NOVNC_HOST_PORT="$(pick_port 6081 "SnowLuma noVNC")"
  SNOWLUMA_ONEBOT_HTTP_HOST_PORT="$(pick_port 3000 "SnowLuma OneBot HTTP")"
  SNOWLUMA_ONEBOT_WS_HOST_PORT="$(pick_port 3001 "SnowLuma OneBot WS")"
}

gen_hex() {
  local bytes="$1"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$bytes"
  else
    od -An -N "$bytes" -tx1 /dev/urandom | tr -d ' \n'
  fi
}

generate_secrets() {
  ASTRBOT_DASHBOARD_PASSWORD="A1a$(gen_hex 12)"
  SNOWLUMA_WEBUI_PASSWORD="S1a$(gen_hex 12)"
  SNOWLUMA_VNC_PASSWORD="$(gen_hex 4)" # VNC 协议只使用前 8 个字符
  SNOWLUMA_HTTP_TOKEN="$(gen_hex 32)"
  SNOWLUMA_WS_TOKEN="$(gen_hex 32)"
  ONEBOT_REVERSE_TOKEN="$(gen_hex 32)"
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "找不到 $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  ACCESS_MODE="${ACCESS_MODE:-private}"
  BIND_ADDR="${BIND_ADDR:-127.0.0.1}"
  ACCESS_HOST="${ACCESS_HOST:-127.0.0.1}"
  ASTROBOT_WEBUI_HOST_PORT="${ASTROBOT_WEBUI_HOST_PORT:-6185}"
  SNOWLUMA_WEBUI_HOST_PORT="${SNOWLUMA_WEBUI_HOST_PORT:-5099}"
  SNOWLUMA_NOVNC_HOST_PORT="${SNOWLUMA_NOVNC_HOST_PORT:-6081}"
  SNOWLUMA_ONEBOT_HTTP_HOST_PORT="${SNOWLUMA_ONEBOT_HTTP_HOST_PORT:-3000}"
  SNOWLUMA_ONEBOT_WS_HOST_PORT="${SNOWLUMA_ONEBOT_WS_HOST_PORT:-3001}"
  TZ_VALUE="${TZ:-$TZ_VALUE}"
  if [[ "$ACCESS_MODE" == "public" ]]; then
    WANT_PUBLIC=1
  else
    WANT_PUBLIC=0
  fi
  [[ -n "${ASTRBOT_DASHBOARD_PASSWORD:-}" ]] || die ".env 缺少 ASTRBOT_DASHBOARD_PASSWORD"
  [[ -n "${SNOWLUMA_WEBUI_PASSWORD:-}" ]] || die ".env 缺少 SNOWLUMA_WEBUI_PASSWORD"
  [[ -n "${SNOWLUMA_VNC_PASSWORD:-}" ]] || die ".env 缺少 SNOWLUMA_VNC_PASSWORD"
  [[ -n "${ONEBOT_REVERSE_TOKEN:-}" ]] || die ".env 缺少 ONEBOT_REVERSE_TOKEN"
}

write_env() {
  cat >"$ENV_FILE" <<EOF
# AstrBot + SnowLuma 安装配置（自动生成，请勿公开）
# 本文件包含密码和 Token，权限必须是 600。
COMPOSE_PROJECT_NAME=astrbot-snowluma
INSTALL_VERSION=${SCRIPT_VERSION}
TZ=${TZ_VALUE}

ACCESS_MODE=${ACCESS_MODE}
ACCESS_HOST=${ACCESS_HOST}
BIND_ADDR=${BIND_ADDR}

ASTROBOT_IMAGE=${ASTROBOT_IMAGE}
SNOWLUMA_IMAGE=${SNOWLUMA_IMAGE}

ASTROBOT_WEBUI_HOST_PORT=${ASTROBOT_WEBUI_HOST_PORT}
SNOWLUMA_WEBUI_HOST_PORT=${SNOWLUMA_WEBUI_HOST_PORT}
SNOWLUMA_NOVNC_HOST_PORT=${SNOWLUMA_NOVNC_HOST_PORT}
SNOWLUMA_ONEBOT_HTTP_HOST_PORT=${SNOWLUMA_ONEBOT_HTTP_HOST_PORT}
SNOWLUMA_ONEBOT_WS_HOST_PORT=${SNOWLUMA_ONEBOT_WS_HOST_PORT}

ASTRBOT_DASHBOARD_PASSWORD=${ASTRBOT_DASHBOARD_PASSWORD}
SNOWLUMA_WEBUI_PASSWORD=${SNOWLUMA_WEBUI_PASSWORD}
SNOWLUMA_VNC_PASSWORD=${SNOWLUMA_VNC_PASSWORD}
SNOWLUMA_HTTP_TOKEN=${SNOWLUMA_HTTP_TOKEN}
SNOWLUMA_WS_TOKEN=${SNOWLUMA_WS_TOKEN}
ONEBOT_REVERSE_TOKEN=${ONEBOT_REVERSE_TOKEN}

SNOWLUMA_UID=${SNOWLUMA_UID}
SNOWLUMA_GID=${SNOWLUMA_GID}
SNOWLUMA_SCREEN=1920x1080x24
SNOWLUMA_QQ_FLAGS="--disable-gpu --disable-software-rasterizer --disable-gpu-compositing"
EOF
  chmod 600 "$ENV_FILE"
}

write_compose() {
  cat >"$COMPOSE_FILE" <<'YAML'
# 由 install-astrbot-snowluma.sh 生成。
# AstrBot：严格按官方 Docker 文档的镜像、端口、数据卷与 TZ 配置。
# SnowLuma：按官方 README 的镜像、SYS_PTRACE、seccomp、shm、ulimit 与端口配置。
name: astrbot-snowluma

services:
  astrbot:
    image: ${ASTROBOT_IMAGE:-soulter/astrbot:latest}
    container_name: astrbot
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    ports:
      - "${BIND_ADDR}:${ASTROBOT_WEBUI_HOST_PORT}:6185"
    environment:
      TZ: ${TZ}
      DASHBOARD_HOST: 0.0.0.0
      DASHBOARD_PORT: 6185
      ASTRBOT_DASHBOARD_INITIAL_PASSWORD: ${ASTRBOT_DASHBOARD_PASSWORD}
    volumes:
      - ./astrbot/data:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
    networks:
      - botnet
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:6185/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 120s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"

  snowluma:
    image: ${SNOWLUMA_IMAGE:-motricseven7/snowluma:latest}
    container_name: snowluma
    restart: unless-stopped
    depends_on:
      astrbot:
        condition: service_started
    shm_size: 1gb
    ulimits:
      nofile:
        soft: 65536
        hard: 1048576
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    ports:
      - "${BIND_ADDR}:${SNOWLUMA_WEBUI_HOST_PORT}:5099"
      - "${BIND_ADDR}:${SNOWLUMA_NOVNC_HOST_PORT}:6081"
      - "127.0.0.1:${SNOWLUMA_ONEBOT_HTTP_HOST_PORT}:3000"
      - "127.0.0.1:${SNOWLUMA_ONEBOT_WS_HOST_PORT}:3001"
    environment:
      TZ: ${TZ}
      VNC_PASSWD: ${SNOWLUMA_VNC_PASSWORD}
      SNOWLUMA_WEBUI_BOOTSTRAP_PASSWORD: ${SNOWLUMA_WEBUI_PASSWORD}
      SNOWLUMA_ONEBOT_HOST: 0.0.0.0
      SNOWLUMA_UID: ${SNOWLUMA_UID}
      SNOWLUMA_GID: ${SNOWLUMA_GID}
      SNOWLUMA_WEBUI_HOST: 0.0.0.0
      SNOWLUMA_WEBUI_PORT: 5099
      SNOWLUMA_LOG_LEVEL: info
      SNOWLUMA_SCREEN: ${SNOWLUMA_SCREEN:-1920x1080x24}
      SNOWLUMA_HOOK_AUTOLOAD: 1
      SNOWLUMA_QQ_FLAGS: "${SNOWLUMA_QQ_FLAGS}"
    volumes:
      - ./snowluma/data:/app/data
      - ./snowluma/.config:/app/.config
      - ./snowluma/.local/share:/app/.local/share
    networks:
      - botnet
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:5099/ >/dev/null 2>&1 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 5
      start_period: 180s
    logging:
      driver: json-file
      options:
        max-size: "20m"
        max-file: "3"
    stop_grace_period: 30s

networks:
  botnet:
    name: astrbot-snowluma
    driver: bridge
YAML
  chmod 600 "$COMPOSE_FILE"
}

prepare_dirs() {
  mkdir -p \
    "$INSTALL_DIR/astrbot/data" \
    "$INSTALL_DIR/snowluma/data/config" \
    "$INSTALL_DIR/snowluma/.config" \
    "$INSTALL_DIR/snowluma/.local/share"
  chmod 700 "$INSTALL_DIR" "$INSTALL_DIR/astrbot" "$INSTALL_DIR/astrbot/data"
  chmod 700 "$INSTALL_DIR/snowluma" "$INSTALL_DIR/snowluma/data" "$INSTALL_DIR/snowluma/.config" "$INSTALL_DIR/snowluma/.local"
}

write_astrbot_config() {
  local f="$INSTALL_DIR/astrbot/data/cmd_config.json"
  if [[ -f "$f" ]]; then
    log "保留已有 AstrBot 配置：$f"
    return 0
  fi
  if [[ -n "$(find "$INSTALL_DIR/astrbot/data" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]]; then
    die "检测到已有 AstrBot 数据但缺少 cmd_config.json。为避免覆盖数据/密码，请备份后移走 $INSTALL_DIR/astrbot/data。"
  fi

  cat >"$f" <<EOF
{
  "platform": [
    {
      "id": "snowluma",
      "type": "aiocqhttp",
      "enable": true,
      "ws_reverse_host": "0.0.0.0",
      "ws_reverse_port": 6199,
      "ws_reverse_token": "${ONEBOT_REVERSE_TOKEN}"
    }
  ]
}
EOF
  chmod 600 "$f"
  log "已预写 AstrBot OneBot v11 反向 WS 配置（SnowLuma -> astrbot:6199/ws）"
}

write_snowluma_config() {
  local f="$INSTALL_DIR/snowluma/data/config/onebot.json"
  if [[ -f "$f" ]]; then
    log "保留已有 SnowLuma OneBot 配置：$f"
    chown "${SNOWLUMA_UID}:${SNOWLUMA_GID}" "$f" 2>/dev/null || true
    chown "${SNOWLUMA_UID}:${SNOWLUMA_GID}" \
      "$INSTALL_DIR/snowluma/data" \
      "$INSTALL_DIR/snowluma/data/config" \
      "$INSTALL_DIR/snowluma/.config" \
      "$INSTALL_DIR/snowluma/.local/share" 2>/dev/null || true
    return 0
  fi

  cat >"$f" <<EOF
{
  "networks": {
    "httpServers": [
      {
        "name": "http-default",
        "enabled": true,
        "host": "0.0.0.0",
        "port": 3000,
        "path": "/",
        "accessToken": "${SNOWLUMA_HTTP_TOKEN}",
        "messageFormat": "array",
        "reportSelfMessage": false
      }
    ],
    "httpClients": [],
    "wsServers": [
      {
        "name": "ws-default",
        "enabled": true,
        "host": "0.0.0.0",
        "port": 3001,
        "path": "/",
        "role": "Universal",
        "accessToken": "${SNOWLUMA_WS_TOKEN}",
        "messageFormat": "array",
        "reportSelfMessage": false
      }
    ],
    "wsClients": [
      {
        "name": "astrbot-reverse",
        "enabled": true,
        "url": "ws://astrbot:6199/ws",
        "role": "Universal",
        "accessToken": "${ONEBOT_REVERSE_TOKEN}",
        "reconnectIntervalMs": 5000,
        "messageFormat": "array",
        "reportSelfMessage": false
      }
    ]
  },
  "statusCommand": {
    "enabled": true,
    "swallow": false,
    "cooldownSeconds": 5,
    "trigger": "#sl"
  },
  "historySync": {
    "enabled": false
  },
  "notifications": {
    "channelIds": []
  },
  "musicSignUrl": ""
}
EOF
  chmod 600 "$f"
  chown "${SNOWLUMA_UID}:${SNOWLUMA_GID}" "$f" 2>/dev/null || true
  chown "${SNOWLUMA_UID}:${SNOWLUMA_GID}" \
    "$INSTALL_DIR/snowluma/data" \
    "$INSTALL_DIR/snowluma/data/config" \
    "$INSTALL_DIR/snowluma/.config" \
    "$INSTALL_DIR/snowluma/.local/share" 2>/dev/null || true
  log "已预写 SnowLuma OneBot 配置：HTTP 3000 / WS 3001 / 反向 WS -> astrbot:6199/ws"
}

validate_json_file() {
  local f="$1" label="$2"
  run_cmd 37 "校验 ${label} JSON" python3 -m json.tool "$f"
}

docker_running() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

docker_is_snap() {
  local bin
  bin="$(command -v docker 2>/dev/null || true)"
  [[ "$bin" == /snap/* ]] && return 0
  docker info 2>/dev/null | grep -qi 'snap'
}

docker_server_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null || true
}

version_ge() {
  dpkg --compare-versions "$1" ge "$2"
}

try_start_docker() {
  local i=0
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
  fi
  if ! docker_running; then
    service docker start >/dev/null 2>&1 || true
  fi
  if ! docker_running && command -v dockerd >/dev/null 2>&1; then
    log "systemd/service 未启动 Docker，尝试直接启动 dockerd"
    nohup dockerd >/var/log/astrbot-dockerd.log 2>&1 &
    disown || true
  fi
  while (( i < 60 )); do
    if docker_running; then
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  return 1
}

ensure_compose_plugin() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  if run_cmd_allow_fail 31 "安装 Ubuntu docker-compose-v2 包" \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends docker-compose-v2; then
    if docker compose version >/dev/null 2>&1; then
      return 0
    fi
  fi
  if run_cmd_allow_fail 32 "安装 Docker Compose v2 插件" \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends docker-compose-plugin; then
    if docker compose version >/dev/null 2>&1; then
      return 0
    fi
  fi

  local arch url
  case "$ARCH_RAW" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "无法为架构 ${ARCH_RAW} 下载 Docker Compose。" ;;
  esac
  url="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-${arch}"
  run_shell 33 "下载 Docker Compose v2 二进制" \
    "install -d /usr/local/lib/docker/cli-plugins && curl -fL --retry 3 --retry-delay 2 --connect-timeout 10 --max-time 180 '${url}' -o /usr/local/lib/docker/cli-plugins/docker-compose && chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose"
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 安装失败。"
}

setup_docker_apt_repo() {
  local codename="$1" arch="$2" repo key_tmp=""
  local repos=(
    "https://download.docker.com/linux/ubuntu"
    "https://mirrors.aliyun.com/docker-ce/linux/ubuntu"
    "https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/ubuntu"
  )

  for repo in "${repos[@]}"; do
    if curl -fsI --connect-timeout 6 --max-time 12 "${repo}/dists/${codename}/Release" >/dev/null 2>&1; then
      key_tmp="$(mktemp)"
      if curl -fsSL --connect-timeout 8 --max-time 30 "${repo}/gpg" -o "$key_tmp" 2>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        gpg --dearmor --yes -o /etc/apt/keyrings/astrbot-docker.gpg "$key_tmp" >/dev/null 2>&1 || true
        rm -f "$key_tmp"
        if [[ -s /etc/apt/keyrings/astrbot-docker.gpg ]]; then
          printf 'deb [arch=%s signed-by=/etc/apt/keyrings/astrbot-docker.gpg] %s %s stable\n' \
            "$arch" "$repo" "$codename" >/etc/apt/sources.list.d/astrbot-docker.list
          chmod 644 /etc/apt/sources.list.d/astrbot-docker.list
          if apt-get -o Acquire::Retries=3 update -y \
              -o Dir::Etc::sourcelist="sources.list.d/astrbot-docker.list" \
              -o Dir::Etc::sourceparts="-" \
              -o APT::Get::List-Cleanup="0" >>"$LOG_FILE" 2>&1; then
            log "Docker APT 源: ${repo} (${codename})"
            return 0
          fi
        fi
      fi
      rm -f "$key_tmp"
    fi
  done
  rm -f /etc/apt/sources.list.d/astrbot-docker.list
  return 1
}

install_docker_ce() {
  local arch codename
  arch="$ARCH_DEB"
  codename="$OS_CODENAME"
  [[ -n "$codename" ]] || codename="$(. /etc/os-release; printf '%s' "${VERSION_CODENAME:-}")"

  info "准备 Docker CE 官方/国内镜像 APT 源 ..."
  if ! run_cmd_allow_fail 20 "配置 Docker APT 源" setup_docker_apt_repo "$codename" "$arch"; then
    warn "Docker CE 仓库不可用（Ubuntu ${OS_VERSION_ID}/${codename}），回退到 Ubuntu 自带的 docker.io。"
    run_cmd 24 "安装 Ubuntu 仓库 Docker Engine（兼容模式）" \
      apt-get -o Acquire::Retries=3 install -y --no-install-recommends docker.io
    return 0
  fi

  if run_cmd_allow_fail 24 "安装 Docker Engine（docker-ce）" \
      apt-get -o Dpkg::Options::=--force-confdef \
              -o Dpkg::Options::=--force-confold \
              -o Acquire::Retries=3 \
              install -y --no-install-recommends \
              docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    return 0
  fi

  warn "带 Compose 插件的 Docker CE 安装失败，尝试安装核心包后单独安装 Compose v2。"
  run_cmd 24 "安装 Docker CE 核心包" \
    apt-get -o Dpkg::Options::=--force-confdef \
            -o Dpkg::Options::=--force-confold \
            -o Acquire::Retries=3 \
            install -y --no-install-recommends docker-ce docker-ce-cli containerd.io
  ensure_compose_plugin
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker_is_snap; then
    die "检测到 snap 版 Docker。SnowLuma 需要标准 Docker Engine（SYS_PTRACE、seccomp、绑定挂载）；请先执行 sudo snap remove docker，重新运行本脚本。"
  fi

  if docker_running; then
    if docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q 'name=rootless'; then
      warn "检测到 rootless Docker。SnowLuma 的 SYS_PTRACE / ptrace 注入在 rootless 模式下可能不可用。"
    fi
    if version_ge "$(docker_server_version)" "20.10"; then
      info "检测到可用 Docker $(docker_server_version)，复用现有安装。"
      if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
        systemctl enable docker >/dev/null 2>&1 || true
      fi
      ensure_compose_plugin
      return 0
    fi
    warn "现有 Docker 版本 $(docker_server_version) 过旧，尝试升级到 20.10+。"
  elif command -v docker >/dev/null 2>&1; then
    warn "检测到 Docker 命令但守护进程未运行，尝试启动。"
    if try_start_docker && version_ge "$(docker_server_version)" "20.10"; then
      ensure_compose_plugin
      return 0
    fi
  fi

  info "开始安装 Docker Engine（不安装 Docker Desktop）..."
  if ! install_docker_ce; then
    die "Docker 安装失败。请查看日志中的 APT 错误。"
  fi

  if ! try_start_docker; then
    die "Docker 安装后仍无法启动。请执行 journalctl -u docker --no-pager 查看原因。"
  fi
  version_ge "$(docker_server_version)" "20.10" || die "Docker 版本仍低于 20.10。"
  ensure_compose_plugin

  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    usermod -aG docker "$SUDO_USER" >/dev/null 2>&1 || true
    info "已把 ${SUDO_USER} 加入 docker 组（重新登录后生效）。"
  fi
}

pull_image_with_mirrors() {
  local image="$1" target="$2" label="$3" prefix ref
  if run_cmd_allow_fail "$target" "拉取 ${label} 镜像" docker pull "$image"; then
    return 0
  fi
  for prefix in "docker.1ms.run" "docker.m.daocloud.io" "docker.xuanyuan.me"; do
    ref="${prefix}/${image}"
    warn "直连 Docker Hub 失败，尝试镜像加速：${prefix}"
    if run_cmd_allow_fail "$target" "拉取 ${label} 镜像（${prefix}）" docker pull "$ref"; then
      docker tag "$ref" "$image" >>"$LOG_FILE" 2>&1 || true
      return 0
    fi
  done
  if docker image inspect "$image" >/dev/null 2>&1; then
    warn "镜像拉取失败，但本地已有 ${image}，继续使用本地版本。"
    return 0
  fi
  return 1
}


wait_http() {
  local target="$1" timeout="$2" desc="$3" url="$4"
  local start pct step
  start=$SECONDS
  while (( SECONDS - start < timeout )); do
    if curl -fsS --connect-timeout 3 --max-time 5 "$url" >/dev/null 2>&1; then
      CURRENT_PCT=$target
      ui_render "$CURRENT_PCT" "$desc" "curl -fsS ${url}" "$((SECONDS - start))"
      return 0
    fi
    local remain=$((target - CURRENT_PCT))
    if (( remain > 1 )); then
      step=$((remain / 20))
      (( step < 1 )) && step=1
      CURRENT_PCT=$((CURRENT_PCT + step))
      (( CURRENT_PCT >= target )) && CURRENT_PCT=$((target - 1))
    fi
    ui_render "$CURRENT_PCT" "$desc" "curl -fsS ${url}" "$((SECONDS - start))"
    sleep 1
  done
  return 1
}

check_container_running() {
  local name="$1" state
  state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
  if [[ "$state" != "running" ]]; then
    docker logs --tail 80 "$name" >>"$LOG_FILE" 2>&1 || true
    die "容器 ${name} 状态为 ${state:-不存在}，启动失败。请查看日志：$LOG_FILE"
  fi
}

start_stack() {
  run_cmd 70 "启动 AstrBot 容器" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d astrbot
  if ! wait_http 79 240 "等待 AstrBot WebUI 就绪" "http://127.0.0.1:${ASTROBOT_WEBUI_HOST_PORT}/"; then
    docker logs --tail 100 astrbot >>"$LOG_FILE" 2>&1 || true
    die "AstrBot WebUI 在 240 秒内未就绪。日志：$LOG_FILE"
  fi
  check_container_running astrbot

  run_cmd 84 "启动 SnowLuma 容器" docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d snowluma
  if ! wait_http 91 300 "等待 SnowLuma WebUI 就绪" "http://127.0.0.1:${SNOWLUMA_WEBUI_HOST_PORT}/"; then
    docker logs --tail 120 snowluma >>"$LOG_FILE" 2>&1 || true
    die "SnowLuma WebUI 在 300 秒内未就绪。日志：$LOG_FILE"
  fi
  check_container_running snowluma

  wait_http 94 60 "等待 noVNC 就绪" "http://127.0.0.1:${SNOWLUMA_NOVNC_HOST_PORT}/vnc.html" || \
    warn "noVNC 暂未响应，但容器已运行；稍后可在浏览器重试。"
}

reconcile_initial_credentials_from_logs() {
  # 官方镜像支持环境变量注入初始密码；这里再做一次日志兜底，
  # 以防未来版本改了环境变量名而只把初始密码打印到日志。
  (( NEW_INSTALL == 1 )) || return 0

  local pw
  pw="$(docker logs --tail 1000 astrbot 2>&1 | sed -nE 's/.*Initial password: ([A-Za-z0-9]+).*/\1/p' | tail -n 1 | tr -d '\r')"
  if [[ -n "$pw" && "$pw" != "$ASTRBOT_DASHBOARD_PASSWORD" ]]; then
    ASTRBOT_DASHBOARD_PASSWORD="$pw"
    sed -i "s|^ASTRBOT_DASHBOARD_PASSWORD=.*|ASTRBOT_DASHBOARD_PASSWORD=${pw}|" "$ENV_FILE"
    log "AstrBot 初始密码已从启动日志校正。"
  fi

  pw="$(docker logs --tail 1000 snowluma 2>&1 | sed -nE 's/.*initial credentials: user=admin password=([A-Za-z0-9]+).*/\1/p' | tail -n 1 | tr -d '\r')"
  if [[ -n "$pw" && "$pw" != "$SNOWLUMA_WEBUI_PASSWORD" ]]; then
    SNOWLUMA_WEBUI_PASSWORD="$pw"
    sed -i "s|^SNOWLUMA_WEBUI_PASSWORD=.*|SNOWLUMA_WEBUI_PASSWORD=${pw}|" "$ENV_FILE"
    log "SnowLuma WebUI 初始密码已从启动日志校正。"
  fi

  pw="$(docker logs --tail 1000 snowluma 2>&1 | sed -nE 's/.*(远程桌面密码|remote desktop password): ([A-Za-z0-9]+).*/\2/p' | tail -n 1 | tr -d '\r')"
  if [[ -n "$pw" && "$pw" != "$SNOWLUMA_VNC_PASSWORD" ]]; then
    SNOWLUMA_VNC_PASSWORD="$pw"
    sed -i "s|^SNOWLUMA_VNC_PASSWORD=.*|SNOWLUMA_VNC_PASSWORD=${pw}|" "$ENV_FILE"
    log "SnowLuma noVNC 初始密码已从启动日志校正。"
  fi
}

configure_firewall() {
  (( WANT_PUBLIC == 1 )) || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    local p
    for p in "$ASTROBOT_WEBUI_HOST_PORT" "$SNOWLUMA_WEBUI_HOST_PORT" "$SNOWLUMA_NOVNC_HOST_PORT"; do
      ufw allow "${p}/tcp" >/dev/null 2>&1 || true
    done
    ufw reload >/dev/null 2>&1 || true
    ok "UFW 已放行 WebUI/noVNC 端口（OneBot 3000/3001 未放行，仍仅本机）。"
  else
    info "UFW 未启用；如使用云服务器，请在安全组放行："
    say "  ${ASTROBOT_WEBUI_HOST_PORT}/tcp, ${SNOWLUMA_WEBUI_HOST_PORT}/tcp, ${SNOWLUMA_NOVNC_HOST_PORT}/tcp"
  fi
}

write_credentials() {
  local f="$INSTALL_DIR/credentials.txt"
  {
    printf 'AstrBot + SnowLuma 安装凭据\n'
    printf '生成时间: %s\n' "$(date '+%F %T %Z')"
    printf '安装目录: %s\n' "$INSTALL_DIR"
    printf '访问模式: %s\n' "$ACCESS_MODE"
    printf '\n'
    printf '=== 配置摘要 ===\n'
    printf 'AstrBot 镜像: %s\n' "$ASTROBOT_IMAGE"
    printf 'SnowLuma 镜像: %s\n' "$SNOWLUMA_IMAGE"
    printf '时区: %s\n' "$TZ_VALUE"
    printf '宿主机绑定地址: %s\n' "$BIND_ADDR"
    printf 'SnowLuma UID/GID: %s/%s\n' "$SNOWLUMA_UID" "$SNOWLUMA_GID"
    printf 'SnowLuma 远程桌面分辨率: 1920x1080x24\n'
    printf 'AstrBot 内部 OneBot 反向 WS: 6199 (仅 Docker 网络)\n'
    printf 'SnowLuma 内部 OneBot: 3000/3001 (宿主机仅 127.0.0.1)\n'
    printf '\n'
    printf '=== AstrBot WebUI ===\n'
    printf '地址: http://%s:%s\n' "$ACCESS_HOST" "$ASTROBOT_WEBUI_HOST_PORT"
    printf '用户名: astrbot\n'
    printf '初始密码: %s\n' "$ASTRBOT_DASHBOARD_PASSWORD"
    printf '说明: 首次登录后 AstrBot 会要求修改密码。\n'
    printf '\n'
    printf '=== SnowLuma WebUI ===\n'
    printf '地址: http://%s:%s\n' "$ACCESS_HOST" "$SNOWLUMA_WEBUI_HOST_PORT"
    printf '用户名: admin\n'
    printf '密码: %s\n' "$SNOWLUMA_WEBUI_PASSWORD"
    printf '\n'
    printf '=== SnowLuma noVNC（浏览器 VNC / 扫码登录 QQ）===\n'
    printf '地址: http://%s:%s/vnc.html\n' "$ACCESS_HOST" "$SNOWLUMA_NOVNC_HOST_PORT"
    printf '用户名: （无需，留空）\n'
    printf '密码: %s\n' "$SNOWLUMA_VNC_PASSWORD"
    printf '提示: VNC 协议只使用密码的前 8 个字符。\n'
    printf '\n'
    printf '=== SnowLuma OneBot（仅宿主机 127.0.0.1）===\n'
    printf 'HTTP: http://127.0.0.1:%s/  Token: %s\n' "$SNOWLUMA_ONEBOT_HTTP_HOST_PORT" "$SNOWLUMA_HTTP_TOKEN"
    printf 'WS:   ws://127.0.0.1:%s/    Token: %s\n' "$SNOWLUMA_ONEBOT_WS_HOST_PORT" "$SNOWLUMA_WS_TOKEN"
    printf '\n'
    printf '=== 自动接通关系 ===\n'
    printf 'SnowLuma -> AstrBot: ws://astrbot:6199/ws（Docker 内部网络）\n'
    printf '反向 WS Token: %s\n' "$ONEBOT_REVERSE_TOKEN"
    printf 'AstrBot OneBot 6199 未映射到宿主机，仅容器网络可达。\n'
    printf '\n'
    printf '=== 管理命令 ===\n'
    printf 'sudo astrbot-snowluma start\n'
    printf 'sudo astrbot-snowluma status\n'
    printf 'sudo astrbot-snowluma restart\n'
    printf 'sudo astrbot-snowluma logs\n'
    printf 'sudo astrbot-snowluma urls\n'
    if [[ "$ACCESS_MODE" == "private" ]]; then
      printf '\n=== 远程访问（SSH 隧道）===\n'
      printf 'ssh -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s <用户>@<服务器IP>\n' \
        "$ASTROBOT_WEBUI_HOST_PORT" "$ASTROBOT_WEBUI_HOST_PORT" \
        "$SNOWLUMA_WEBUI_HOST_PORT" "$SNOWLUMA_WEBUI_HOST_PORT" \
        "$SNOWLUMA_NOVNC_HOST_PORT" "$SNOWLUMA_NOVNC_HOST_PORT"
    fi
  } >"$f"
  chmod 600 "$f"
  log "凭据写入 $f"
}

manager_script_content() {
  cat <<'MANAGER_EOF'
#!/usr/bin/env bash
# AstrBot + SnowLuma 本地管理脚本（由安装器生成）
# 只输出访问地址，不输出密码。
set -Eeuo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]:-$0}")"
DIR="$(cd "$(dirname "$SELF")" && pwd)"
ENV_FILE="$DIR/.env"
COMPOSE_FILE="$DIR/compose.yaml"

die() { printf '[错误] %s\n' "$*" >&2; exit 1; }

print_help() {
  cat <<'EOF'
AstrBot + SnowLuma 管理脚本

用法:
  sudo astrbot-snowluma <命令>

命令:
  start      启动 AstrBot + SnowLuma，并显示 WebUI 地址（不显示密码）
  stop       停止两个容器（保留容器和数据）
  restart    重启两个容器
  status     查看容器状态、HTTP 检查与访问地址
  logs       实时查看两个容器日志
  urls       只显示访问地址
  update     拉取最新镜像并重建容器（保留 data 卷/目录）
  help       显示帮助

说明:
  * 本脚本不会输出密码；密码在安装时输出并保存在 credentials.txt (600)。
  * 容器使用 restart: unless-stopped，Docker 开机自启后会自动恢复。
  * OneBot 3000/3001 始终只绑定 127.0.0.1。
EOF
}

# help 不依赖 .env / compose / root，方便首次安装前查看。
if [[ "${1:-}" == "help" || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  print_help
  exit 0
fi


[[ -f "$ENV_FILE" ]] || die "找不到 $ENV_FILE"
[[ -f "$COMPOSE_FILE" ]] || die "找不到 $COMPOSE_FILE"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$SELF" "$@"
  fi
  die "请使用 root 或 sudo 运行。"
fi

# .env 含密码，只在本进程内使用，不打印。
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")
HOST="${ACCESS_HOST:-127.0.0.1}"
if [[ "${ACCESS_MODE:-private}" == "private" ]]; then
  HOST="127.0.0.1"
fi

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    systemctl start docker >/dev/null 2>&1 || true
  fi
  if ! docker info >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi
  if ! docker info >/dev/null 2>&1; then
    die "Docker 未运行。请执行: sudo systemctl start docker"
  fi
}

show_urls() {
  printf '\n'
  printf 'AstrBot WebUI   : http://%s:%s\n' "$HOST" "${ASTROBOT_WEBUI_HOST_PORT}"
  printf 'SnowLuma WebUI  : http://%s:%s\n' "$HOST" "${SNOWLUMA_WEBUI_HOST_PORT}"
  printf 'SnowLuma noVNC  : http://%s:%s/vnc.html\n' "$HOST" "${SNOWLUMA_NOVNC_HOST_PORT}"
  printf 'OneBot HTTP     : http://127.0.0.1:%s/\n' "${SNOWLUMA_ONEBOT_HTTP_HOST_PORT}"
  printf 'OneBot WS       : ws://127.0.0.1:%s/\n' "${SNOWLUMA_ONEBOT_WS_HOST_PORT}"
  printf '\n密码未由本脚本输出；安装凭据保存在: %s/credentials.txt\n' "$DIR"
  if [[ "${ACCESS_MODE:-private}" == "private" ]]; then
    printf '\n远程访问（SSH 隧道）:\n'
    printf 'ssh -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s <用户>@<服务器IP>\n' \
      "${ASTROBOT_WEBUI_HOST_PORT}" "${ASTROBOT_WEBUI_HOST_PORT}" \
      "${SNOWLUMA_WEBUI_HOST_PORT}" "${SNOWLUMA_WEBUI_HOST_PORT}" \
      "${SNOWLUMA_NOVNC_HOST_PORT}" "${SNOWLUMA_NOVNC_HOST_PORT}"
  fi
}

cmd_start() {
  ensure_docker
  "${COMPOSE[@]}" up -d
  sleep 2
  "${COMPOSE[@]}" ps
  show_urls
}

cmd_stop() {
  ensure_docker
  "${COMPOSE[@]}" stop
  printf '已停止 AstrBot 和 SnowLuma（容器与数据保留）。\n'
}

cmd_restart() {
  ensure_docker
  "${COMPOSE[@]}" up -d
  "${COMPOSE[@]}" restart
  sleep 2
  "${COMPOSE[@]}" ps
  show_urls
}

cmd_status() {
  ensure_docker
  "${COMPOSE[@]}" ps
  printf '\nHTTP 检查:\n'
  local url code
  for url in \
    "http://127.0.0.1:${ASTROBOT_WEBUI_HOST_PORT}/" \
    "http://127.0.0.1:${SNOWLUMA_WEBUI_HOST_PORT}/" \
    "http://127.0.0.1:${SNOWLUMA_NOVNC_HOST_PORT}/vnc.html"; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null || true)"
    printf '  %-48s %s\n' "$url" "${code:-未响应}"
  done
  show_urls
}

cmd_logs() {
  ensure_docker
  "${COMPOSE[@]}" logs -f --tail=100
}

cmd_urls() {
  show_urls
}

cmd_update() {
  ensure_docker
  "${COMPOSE[@]}" pull
  "${COMPOSE[@]}" up -d
  sleep 2
  "${COMPOSE[@]}" ps
  show_urls
}

case "${1:-}" in
  start) cmd_start ;;
  stop) cmd_stop ;;
  restart) cmd_restart ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  urls) cmd_urls ;;
  update) cmd_update ;;
  help|-h|--help) print_help ;;
  *) print_help; exit 1 ;;
esac
MANAGER_EOF
}

write_manager_script() {
  local manager="$INSTALL_DIR/astrbot-snowluma.sh"
  manager_script_content >"$manager"
  chmod 755 "$manager"
  run_cmd 96 "校验管理脚本" bash -n "$manager"
  ln -sfn "$manager" /usr/local/bin/astrbot-snowluma
  log "管理脚本: $manager；软链接: /usr/local/bin/astrbot-snowluma"
}

print_final_summary() {
  local f="$INSTALL_DIR/credentials.txt"
  say ""
  info "================ 安装完成 ================"
  if [[ -f "$f" ]]; then
    cat "$f"
  else
    warn "未找到凭据文件 $f"
  fi
  say ""
  info "下一步："
  say "  1. 打开 SnowLuma noVNC，用 QQ 扫码登录；登录后 SnowLuma 会自动连上 AstrBot。"
  say "  2. 打开 AstrBot WebUI，首次登录后按提示修改密码并配置模型。"
  say "  3. 常用管理：sudo astrbot-snowluma start|stop|restart|status|logs|urls"
  say ""
  info "文件位置："
  say "  安装目录 : $INSTALL_DIR"
  say "  凭据文件 : $f (600，含密码/Token)"
  say "  安装日志 : $LOG_FILE"
  say "  管理脚本 : $INSTALL_DIR/astrbot-snowluma.sh"
  if (( WANT_PUBLIC == 1 )); then
    say ""
    warn "公网模式已开启：noVNC 使用 HTTP 明文传输密码，强烈建议限制来源 IP、使用防火墙/安全组，或改用 SSH 隧道/反向代理 TLS。"
  fi
}

main() {
  SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)"
  parse_args "$@"
  [[ -n "${SCRIPT_PATH:-}" && -f "$SCRIPT_PATH" ]] || die "无法定位脚本自身，请下载后以文件方式运行。"
  require_root "$@"

  info "AstrBot + SnowLuma 一键部署 v${SCRIPT_VERSION}"

  if (( DRY_RUN == 0 )); then
    setup_install_dir
  fi

  preflight

  log "args: $*"
  log "Ubuntu ${OS_VERSION_ID}, ${ARCH_DEB}, kernel $(uname -r)"

  if [[ -f "$ENV_FILE" ]]; then
    load_env
    info "检测到已有安装配置，将保留现有密码、Token 和端口。"
  else
    prompt_public_access
  fi

  if (( DRY_RUN == 1 )); then
    say "[dry-run] 将安装 Docker、创建 ${INSTALL_DIR}、部署 AstrBot + SnowLuma。"
    exit 0
  fi

  ui_init
  install_base_dependencies

  if [[ ! -f "$ENV_FILE" ]]; then
    choose_ports
    generate_secrets
    write_env
    NEW_INSTALL=1
  fi

  prepare_dirs
  ensure_docker

  write_astrbot_config
  write_snowluma_config
  validate_json_file "$INSTALL_DIR/astrbot/data/cmd_config.json" "AstrBot 配置"
  validate_json_file "$INSTALL_DIR/snowluma/data/config/onebot.json" "SnowLuma 配置"
  write_compose

  run_cmd 39 "校验 .env / Compose 配置" \
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet

  if ! pull_image_with_mirrors "$ASTROBOT_IMAGE" 50 "AstrBot"; then
    die "AstrBot 镜像拉取失败。请检查外网/Docker Hub，或在 .env 中设置可用的 ASTROBOT_IMAGE。"
  fi
  if ! pull_image_with_mirrors "$SNOWLUMA_IMAGE" 64 "SnowLuma"; then
    die "SnowLuma 镜像拉取失败。请检查外网/Docker Hub，或在 .env 中设置可用的 SNOWLUMA_IMAGE。"
  fi

  start_stack
  reconcile_initial_credentials_from_logs
  configure_firewall
  write_manager_script
  if (( NEW_INSTALL == 1 )) || [[ ! -f "$INSTALL_DIR/credentials.txt" ]]; then
    write_credentials
  else
    log "保留已有凭据文件：$INSTALL_DIR/credentials.txt"
  fi
  ui_finish
  print_final_summary
}

if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  main "$@"
fi
