#!/usr/bin/env bash
set -Eeuo pipefail

# ==================== 前置：必须交互执行 ====================
if [ ! -t 0 ]; then
  echo "错误：脚本必须从终端交互执行，不能用 curl | bash。"
  echo "请先下载再执行："
  echo "  curl -fsSL -o /tmp/deploy.sh https://raw.githubusercontent.com/pixelcraft0516/docker-astrbot-snownluma-install-script/main/deploy.sh"
  echo "  sudo bash /tmp/deploy.sh"
  exit 1
fi

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; NC=$'\033[0m'
TOTAL_STEPS=6
CURRENT_STEP=0
BAR_WIDTH=24
STEP_START=0
STEP_END=0
STEP_LABEL=""
ANIM_PID=""
LOG_FILE="/tmp/deploy-astrbot-snowluma.log"

term_cols() { tput cols 2>/dev/null || echo 80; }

build_bar() {
  local pct=$1
  local filled=$((pct * BAR_WIDTH / 100))
  local empty=$((BAR_WIDTH - filled))
  local f="" e="" i
  for ((i=0;i<filled;i++)); do f+="#"; done
  for ((i=0;i<empty;i++)); do e+=" "; done
  printf '%s%s' "$f" "$e"
}

fit_cmd() {
  local cmd="${1//$'\n'/ }"
  local cols max
  cols=$(term_cols)
  max=$((cols - 8))
  [ "$max" -lt 20 ] && max=20
  if [ "${#cmd}" -gt "$max" ]; then
    printf '%s…' "${cmd:0:$((max-1))}"
  else
    printf '%s' "$cmd"
  fi
}

render_pair() {
  local pct="$1" label="$2" spin="$3" cmd="$4"
  local bar
  bar=$(build_bar "$pct")
  printf "\r\033[2K${BLUE}[%s] %3d%%${NC}  %s ${CYAN}%s${NC}" "$bar" "$pct" "$label" "$spin"
  printf "\n\033[2K${YELLOW}  ▶ %s${NC}" "$(fit_cmd "$cmd")"
  printf "\033[1A\r"
}

clear_pair() {
  printf "\r\033[2K"
  printf "\n\r\033[2K"
  printf "\033[1A\r"
}

start_anim() {
  local label="$1" cmd="$2"
  (
    local pct=$STEP_START
    local spin=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local i=0
    while true; do
      i=$(( (i + 1) % 10 ))
      [ "$pct" -lt $((STEP_END - 2)) ] && pct=$((pct + 1))
      render_pair "$pct" "$label" "${spin[$i]}" "$cmd"
      sleep 0.1
    done
  ) &
  ANIM_PID=$!
}

stop_anim() {
  if [ -n "${ANIM_PID:-}" ]; then
    kill "$ANIM_PID" 2>/dev/null || true
    wait "$ANIM_PID" 2>/dev/null || true
    ANIM_PID=""
  fi
}

run_with_anim() {
  local label="$1" cmd_desc="$2"; shift 2
  local start_ts=$(( $(date +%s%N) / 1000000 ))
  start_anim "$label" "$cmd_desc"
  local rc=0
  "$@" >>"$LOG_FILE" 2>&1 || rc=$?
  local elapsed=$(( $(date +%s%N) / 1000000 - start_ts ))
  [ "$elapsed" -lt 300 ] && sleep "0.$(( 300 - elapsed ))"
  stop_anim
  clear_pair
  if [ $rc -ne 0 ]; then
    echo -e "${RED}命令失败 (退出码 $rc): $cmd_desc${NC}"
    echo -e "${YELLOW}日志末尾:${NC}"
    tail -n 20 "$LOG_FILE"
    return $rc
  fi
  return 0
}

begin_step() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  STEP_LABEL="$1"
  STEP_START=$(((CURRENT_STEP - 1) * 100 / TOTAL_STEPS))
  STEP_END=$((CURRENT_STEP * 100 / TOTAL_STEPS))
  echo
  echo -e "${BLUE}▶ 步骤 ${CURRENT_STEP}/${TOTAL_STEPS}: ${STEP_LABEL}${NC}"
}

end_step() {
  local bar
  bar=$(build_bar "$STEP_END")
  printf "${BLUE}[%s] %3d%%${NC}  ${GREEN}✓ %s${NC}\n" "$bar" "$STEP_END" "$STEP_LABEL"
}

ask() {
  local prompt="$1" default="$2" var
  read -r -p "$(printf "${YELLOW}%s${NC} [默认: %s]: " "$prompt" "$default")" var
  echo "${var:-$default}"
}

trap 'stop_anim' EXIT
: > "$LOG_FILE"

# ==================== 1. 检查环境 ====================
begin_step "检查权限与 Ubuntu 版本"
[[ $EUID -eq 0 ]] || { echo -e "${RED}请使用 sudo 或 root 运行${NC}"; exit 1; }
if ! command -v lsb_release &>/dev/null; then
  run_with_anim "安装 lsb-release" "apt-get update && apt-get install -y lsb-release" \
    bash -c 'apt-get update -qq && apt-get install -y -qq lsb-release'
fi
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo unknown)
UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo noble)
end_step

# ==================== 2. 交互配置 ====================
begin_step "收集配置参数"
echo
echo -e "${GREEN}========== AstrBot ==========${NC}"
ASTRBOT_WEBUI_PORT=$(ask "AstrBot WebUI 端口" "6185")
ASTRBOT_WS_PORT=$(ask "AstrBot OneBot v11 反向 WebSocket 端口" "6199")
echo
echo -e "${GREEN}========== SnowLuma ==========${NC}"
SNOWLUMA_WEBUI_PORT=$(ask "SnowLuma WebUI 端口" "5099")
SNOWLUMA_NOVNC_PORT=$(ask "SnowLuma noVNC 端口（扫码登录用）" "6081")
SNOWLUMA_ONEBOT_WS_PORT=$(ask "SnowLuma OneBot WebSocket 端口" "3001")
echo
echo -e "${GREEN}========== OneBot Token ==========${NC}"
DEFAULT_TOKEN=$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)
ONEBOT_TOKEN=$(ask "OneBot Token（回车自动生成随机值）" "$DEFAULT_TOKEN")
echo
echo -e "${GREEN}========== 时区 ==========${NC}"
TZ_VALUE=$(ask "时区 (IANA)" "Asia/Shanghai")
echo
# ========== 新增：公网远程访问 ==========
echo -e "${GREEN}========== 公网远程访问 ==========${NC}"
read -r -p "$(printf "${YELLOW}是否需要公网远程访问? [y/N]: ${NC}")" ENABLE_PUBLIC
ENABLE_PUBLIC=${ENABLE_PUBLIC:-N}
PUBLIC_IP=""
if [[ "$ENABLE_PUBLIC" =~ ^[Yy]$ ]]; then
  AUTO_IP=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || curl -fsSL --max-time 5 https://ifconfig.me 2>/dev/null || echo "")
  read -r -p "$(printf "${YELLOW}请输入公网地址/IP${AUTO_IP:+ (回车自动使用 $AUTO_IP)}: ${NC}")" PUBLIC_IP
  PUBLIC_IP=${PUBLIC_IP:-$AUTO_IP}
  if [ -z "$PUBLIC_IP" ]; then
    echo -e "${RED}未获取到公网 IP，将回退为仅本地访问。${NC}"
    ENABLE_PUBLIC="N"
  fi
fi

if [[ "$ENABLE_PUBLIC" =~ ^[Yy]$ ]] && [ -n "$PUBLIC_IP" ]; then
  BIND_ADDR="0.0.0.0"
  ACCESS_BASE="http://${PUBLIC_IP}"
else
  BIND_ADDR="127.0.0.1"
  ACCESS_BASE="http://127.0.0.1"
fi
# ====================================

echo
echo -e "${YELLOW}配置确认:${NC}"
echo "  AstrBot WebUI:      ${ASTRBOT_WEBUI_PORT}"
echo "  AstrBot 反向 WS:    ${ASTRBOT_WS_PORT}"
echo "  SnowLuma WebUI:     ${SNOWLUMA_WEBUI_PORT}"
echo "  SnowLuma noVNC:     ${SNOWLUMA_NOVNC_PORT}"
echo "  SnowLuma OneBot WS: ${SNOWLUMA_ONEBOT_WS_PORT}"
echo "  OneBot Token:       ${ONEBOT_TOKEN:0:8}..."
echo "  时区:               ${TZ_VALUE}"
if [[ "$ENABLE_PUBLIC" =~ ^[Yy]$ ]] && [ -n "$PUBLIC_IP" ]; then
  echo "  公网访问:            是 (${PUBLIC_IP})"
else
  echo "  公网访问:            否（仅本地）"
fi
read -r -p "$(printf "${YELLOW}确认继续? [Y/n]: ${NC}")" CONFIRM
CONFIRM=${CONFIRM:-Y}
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "已取消"; exit 0; }
end_step

# ==================== 3. 安装 Docker CE ====================
begin_step "安装 Docker CE"
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  echo -e "${GREEN}Docker 与 Compose 插件已安装，跳过。${NC}"
else
  case "$UBUNTU_CODENAME" in
    focal|jammy|noble|resolute) DOCKER_CODENAME="$UBUNTU_CODENAME" ;;
    *) DOCKER_CODENAME="noble" ;;
  esac
  export DOCKER_CODENAME

  run_with_anim "清理旧版 Docker 包" \
    "apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc" \
    bash -c 'apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc || true'

  run_with_anim "更新软件源" "apt-get update" apt-get update -qq

  run_with_anim "安装依赖" "apt-get install -y ca-certificates curl gnupg" \
    apt-get install -y -qq ca-certificates curl gnupg

  run_with_anim "添加 Docker GPG 密钥" \
    "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg" \
    bash -c 'install -m 0755 -d /etc/apt/keyrings && rm -f /etc/apt/keyrings/docker.gpg && curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && chmod a+r /etc/apt/keyrings/docker.gpg'

  run_with_anim "添加 Docker APT 源" \
    "echo 'deb [arch=...] ... ${DOCKER_CODENAME} stable' > /etc/apt/sources.list.d/docker.list" \
    bash -c 'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${DOCKER_CODENAME} stable" > /etc/apt/sources.list.d/docker.list'

  run_with_anim "更新源" "apt-get update" apt-get update -qq

  run_with_anim "安装 Docker CE 与 Compose 插件" \
    "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" \
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  run_with_anim "启动并启用 Docker 服务" "systemctl enable --now docker" \
    systemctl enable --now docker
fi

if ! docker compose version &>/dev/null; then
  echo -e "${RED}Docker Compose 插件不可用，请检查安装日志。${NC}"
  exit 1
fi
end_step

# ==================== 4. 生成 compose ====================
begin_step "生成 docker-compose.yml"
DEPLOY_DIR="/opt/astrbot-snowluma"
mkdir -p "${DEPLOY_DIR}/data-astrbot" "${DEPLOY_DIR}/data-snowluma"
cd "${DEPLOY_DIR}"
cat > docker-compose.yml <<EOF
services:
  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}:${ASTRBOT_WEBUI_PORT}:6185"
      - "${BIND_ADDR}:${ASTRBOT_WS_PORT}:6199"
    volumes:
      - ./data-astrbot:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    environment:
      - TZ=${TZ_VALUE}
    networks:
      - botnet

  snowluma:
    image: motricseven7/snowluma:latest
    container_name: snowluma
    restart: unless-stopped
    ports:
      - "${BIND_ADDR}:${SNOWLUMA_WEBUI_PORT}:5099"
      - "${BIND_ADDR}:${SNOWLUMA_NOVNC_PORT}:6081"
      - "${BIND_ADDR}:${SNOWLUMA_ONEBOT_WS_PORT}:3001"
    volumes:
      - ./data-snowluma:/app/data
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
    environment:
      - TZ=${TZ_VALUE}
      - SNOWLUMA_ACCESS_TOKEN=${ONEBOT_TOKEN}
    networks:
      - botnet

networks:
  botnet:
    driver: bridge
EOF
end_step

# ==================== 5. 拉取镜像 ====================
begin_step "拉取镜像"
run_with_anim "拉取 AstrBot 与 SnowLuma 镜像" "docker compose pull" docker compose pull
end_step

# ==================== 6. 启动容器 ====================
begin_step "启动容器"
run_with_anim "启动容器" "docker compose up -d" docker compose up -d
end_step

# ==================== 完成 ====================
echo
echo -e "${GREEN}==================== 部署成功 ====================${NC}"
echo -e "AstrBot WebUI:   ${BLUE}${ACCESS_BASE}:${ASTRBOT_WEBUI_PORT}${NC}"
echo -e "SnowLuma WebUI:  ${BLUE}${ACCESS_BASE}:${SNOWLUMA_WEBUI_PORT}${NC}"
echo -e "SnowLuma noVNC:  ${BLUE}${ACCESS_BASE}:${SNOWLUMA_NOVNC_PORT}${NC}"
echo -e "OneBot Token:    ${YELLOW}${ONEBOT_TOKEN:0:12}...${NC}"
echo
if [[ "$BIND_ADDR" == "127.0.0.1" ]]; then
  echo -e "${YELLOW}安全提示: 端口已绑定 127.0.0.1，请通过 SSH 隧道访问:${NC}"
  echo "  ssh -L ${ASTRBOT_WEBUI_PORT}:127.0.0.1:${ASTRBOT_WEBUI_PORT} \\"
  echo "      -L ${SNOWLUMA_WEBUI_PORT}:127.0.0.1:${SNOWLUMA_WEBUI_PORT} \\"
  echo "      -L ${SNOWLUMA_NOVNC_PORT}:127.0.0.1:${SNOWLUMA_NOVNC_PORT} user@服务器IP"
else
  echo -e "${YELLOW}安全提示: 端口已绑定 0.0.0.0，请确保云安全组/防火墙已放行 ${ASTRBOT_WEBUI_PORT}, ${SNOWLUMA_WEBUI_PORT}, ${SNOWLUMA_NOVNC_PORT} 等端口。${NC}"
fi
echo
echo -e "${YELLOW}后续连接步骤:${NC}"
echo "1. 查看 SnowLuma WebUI 初始密码（账号 admin）:"
echo "   docker logs snowluma 2>&1 | grep -E '初始密码|initial credentials|password=' | tail -n 3"
echo "2. 查看 SnowLuma noVNC / VNC 初始密码:"
echo "   docker logs snowluma 2>&1 | grep -iE 'vnc.*password|password.*vnc|VNC_PASSWD' | tail -n 3"
echo "3. 打开 noVNC 地址，用查到的 VNC 密码登录并扫码登录 QQ。"
echo "4. SnowLuma WebUI 开启 OneBot WebSocket 服务端，端口 3001，Token: ${ONEBOT_TOKEN}"
echo "5. AstrBot WebUI 接入 OneBot v11 反向 WS，端口 ${ASTRBOT_WS_PORT}，Token 同上。"
echo "   连接地址: ws://astrbot:${ASTRBOT_WS_PORT}/ws"
echo
echo -e "完整安装日志: ${LOG_FILE}"