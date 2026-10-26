#!/usr/bin/env bash
set -Eeuo pipefail

# ==================== 颜色与进度条 ====================
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
TOTAL_STEPS=6
CURRENT=0

progress() {
  CURRENT=$((CURRENT + 1))
  local pct=$((CURRENT * 100 / TOTAL_STEPS))
  local filled=$((pct / 5))
  local empty=$((20 - filled))
  printf "\r${BLUE}[%-20s] %3d%%${NC}  %s" \
    "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null))$(printf ' %.0s' $(seq 1 $empty 2>/dev/null))" \
    "$pct" "$1"
  if [ "$CURRENT" -eq "$TOTAL_STEPS" ]; then echo; fi
}

# ==================== 询问函数 ====================
ask() {
  local prompt="$1" default="$2" var
  read -r -p "$(printf "${YELLOW}%s${NC} [默认: %s]: " "$prompt" "$default")" var
  echo "${var:-$default}"
}

# ==================== 1. 权限与系统检查 ====================
progress "检查权限与 Ubuntu 版本"

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo 或 root 运行此脚本。${NC}"
  exit 1
fi

if ! command -v lsb_release &>/dev/null; then
  apt-get update -qq && apt-get install -y -qq lsb-release >/dev/null
fi

UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")

if [[ ! "$UBUNTU_VER" =~ ^(20\.04|24\.04|26\.04)$ ]]; then
  echo -e "${YELLOW}提示: 当前为 Ubuntu ${UBUNTU_VER}，脚本目标版本为 20.04/24.04/26.04，仍会尝试继续。${NC}"
fi

# Docker 官方文档明确支持 26.04、24.04、22.04；20.04 虽已不在主要支持列表，但 apt 源仍可用。
# 如果 lsb_release 给出的 codename 在 Docker 仓库中不存在，回退到 noble（24.04）以兼容 26.04 早期阶段。
DOCKER_CODENAME="$UBUNTU_CODENAME"
case "$UBUNTU_CODENAME" in
  focal|jammy|noble|resolute) DOCKER_CODENAME="$UBUNTU_CODENAME" ;;
  *)
    echo -e "${YELLOW}未识别的 codename '${UBUNTU_CODENAME}'，回退到 noble 源。${NC}"
    DOCKER_CODENAME="noble"
    ;;
esac

# ==================== 2. 交互配置 ====================
progress "收集配置参数（全部回车即使用默认值）"

echo -e "\n${GREEN}========== AstrBot ==========${NC}"
ASTRBOT_WEBUI_PORT=$(ask "AstrBot WebUI 端口" "6185")
ASTRBOT_WS_PORT=$(ask "AstrBot OneBot v11 反向 WebSocket 端口" "6199")

echo -e "\n${GREEN}========== SnowLuma ==========${NC}"
SNOWLUMA_WEBUI_PORT=$(ask "SnowLuma WebUI 端口" "5099")
SNOWLUMA_NOVNC_PORT=$(ask "SnowLuma noVNC 端口（扫码登录用）" "6081")
SNOWLUMA_ONEBOT_WS_PORT=$(ask "SnowLuma OneBot WebSocket 端口（AstrBot 将连接此端口）" "3001")

echo -e "\n${GREEN}========== OneBot 通信 Token ==========${NC}"
echo "说明: 该 Token 将同时用于 SnowLuma 的 OneBot WebSocket 鉴权，以及 AstrBot 反向 WS 的校验。"
DEFAULT_TOKEN=$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)
ONEBOT_TOKEN=$(ask "OneBot 通信 Token（直接回车自动生成随机值）" "$DEFAULT_TOKEN")

echo -e "\n${GREEN}========== 时区 ==========${NC}"
TZ_VALUE=$(ask "时区 (IANA 格式)" "Asia/Shanghai")

echo -e "\n${YELLOW}即将使用以下配置:${NC}"
printf "  AstrBot WebUI:          %s\n" "${ASTRBOT_WEBUI_PORT}"
printf "  AstrBot 反向 WS:        %s\n" "${ASTRBOT_WS_PORT}"
printf "  SnowLuma WebUI:         %s\n" "${SNOWLUMA_WEBUI_PORT}"
printf "  SnowLuma noVNC:         %s\n" "${SNOWLUMA_NOVNC_PORT}"
printf "  SnowLuma OneBot WS:     %s\n" "${SNOWLUMA_ONEBOT_WS_PORT}"
printf "  OneBot Token:           %s...（已设置）\n" "${ONEBOT_TOKEN:0:8}"
printf "  时区:                   %s\n" "${TZ_VALUE}"
read -r -p "$(printf "${YELLOW}确认继续? [Y/n]: ${NC}")" CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo "已取消。"; exit 0; fi

# ==================== 3. 安装 Docker CE ====================
progress "安装 Docker CE 与 Compose 插件"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  echo -e "\n${GREEN}Docker 与 Compose 插件已安装，跳过。${NC}"
else
  # 卸载可能冲突的旧包（Docker 官方文档步骤）
  apt-get remove -y docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc >/dev/null 2>&1 || true

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg >/dev/null

  # 添加 Docker 官方 GPG key（Docker 官方文档步骤）
  install -m 0755 -d /etc/apt/keyrings
  rm -f /etc/apt/keyrings/docker.gpg
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  # 添加 Docker 官方 APT 仓库（Docker 官方文档步骤）
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    ${DOCKER_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null

  systemctl enable --now docker >/dev/null 2>&1
fi

if ! docker compose version &>/dev/null; then
  echo -e "${RED}Docker Compose 插件安装失败，请检查网络或手动安装。${NC}"
  exit 1
fi

# ==================== 4. 生成 docker-compose.yml ====================
progress "生成 docker-compose.yml（严格遵循官方镜像与端口）"

DEPLOY_DIR="/opt/astrbot-snowluma"
mkdir -p "${DEPLOY_DIR}/data-astrbot" "${DEPLOY_DIR}/data-snowluma"
cd "${DEPLOY_DIR}"

# AstrBot 官方文档: 镜像 soulter/astrbot:latest, 端口 6185(WebUI) / 6199(OneBot v11 反向WS),
# 数据卷 /AstrBot/data, 时区通过 /etc/localtime 与 /etc/timezone 挂载。
# SnowLuma 官方 Docker 框架文档: 端口 6081(noVNC) / 5099(WebUI) / 3001(OneBot WebSocket)。
# 中国大陆网络若拉取缓慢，可将 astrbot 镜像替换为:
#   m.daocloud.io/docker.io/soulter/astrbot:latest

cat > docker-compose.yml <<EOF
services:
  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: unless-stopped
    ports:
      - "127.0.0.1:${ASTRBOT_WEBUI_PORT}:6185"
      - "127.0.0.1:${ASTRBOT_WS_PORT}:6199"
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
      - "127.0.0.1:${SNOWLUMA_WEBUI_PORT}:5099"
      - "127.0.0.1:${SNOWLUMA_NOVNC_PORT}:6081"
      - "127.0.0.1:${SNOWLUMA_ONEBOT_WS_PORT}:3001"
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

echo -e "\n${GREEN}已写入: ${DEPLOY_DIR}/docker-compose.yml${NC}"

# ==================== 5. 拉取镜像并启动 ====================
progress "拉取镜像并启动容器"

docker compose pull 2>&1 | tail -1
docker compose up -d

# ==================== 6. 完成信息 ====================
progress "部署完成"

echo -e "\n${GREEN}==================== 部署成功 ====================${NC}"
echo -e "AstrBot WebUI:        ${BLUE}http://127.0.0.1:${ASTRBOT_WEBUI_PORT}${NC}"
echo -e "SnowLuma WebUI:       ${BLUE}http://127.0.0.1:${SNOWLUMA_WEBUI_PORT}${NC}"
echo -e "SnowLuma noVNC:       ${BLUE}http://127.0.0.1:${SNOWLUMA_NOVNC_PORT}${NC}"
echo -e "OneBot Token:         ${YELLOW}${ONEBOT_TOKEN:0:12}...${NC}"

echo -e "\n${YELLOW}安全提示: 所有端口均已绑定 127.0.0.1，公网无法直接访问。${NC}"
echo -e "请通过 SSH 隧道从本机访问，例如:"
echo -e "  ssh -L ${ASTRBOT_WEBUI_PORT}:127.0.0.1:${ASTRBOT_WEBUI_PORT} \\"
echo -e "      -L ${SNOWLUMA_WEBUI_PORT}:127.0.0.1:${SNOWLUMA_WEBUI_PORT} \\"
echo -e "      -L ${SNOWLUMA_NOVNC_PORT}:127.0.0.1:${SNOWLUMA_NOVNC_PORT} user@服务器IP"

echo -e "\n${YELLOW}接下来需要手动完成的连接步骤:${NC}"
echo "1. 查看 SnowLuma noVNC 初始密码:"
echo "   docker logs snowluma 2>&1 | grep -i password"
echo ""
echo "2. 浏览器打开 SnowLuma noVNC，用上述密码登录并扫码登录 QQ。"
echo ""
echo "3. 在 SnowLuma WebUI 中配置 OneBot:"
echo "   开启 WebSocket 服务端，端口保持 3001，"
echo "   Access Token 填写: ${ONEBOT_TOKEN}"
echo ""
echo "4. 在 AstrBot WebUI 中接入 OneBot v11:"
echo "   反向 WebSocket 端口: ${ASTRBOT_WS_PORT}"
echo "   Token 填写: ${ONEBOT_TOKEN}"
echo "   SnowLuma 将连接到 ws://astrbot:${ASTRBOT_WS_PORT}/ws"
echo ""
echo -e "${GREEN}完成。${NC}"
