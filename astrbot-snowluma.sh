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
