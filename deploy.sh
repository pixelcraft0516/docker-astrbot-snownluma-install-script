#!/usr/bin/env bash
set -Eeuo pipefail

# ---------- 颜色与进度条 ----------
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; NC=$'\033[0m'
TOTAL_STEPS=7
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

# ---------- 询问函数 ----------
ask() {
  local prompt="$1" default="$2" var
  read -r -p "$(printf "${YELLOW}%s${NC} [默认: %s]: " "$prompt" "$default")" var
  echo "${var:-$default}"
}

# ---------- 1. 系统检查 ----------
progress "检查 Ubuntu 版本与权限"
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请以 root 或 sudo 运行此脚本。${NC}"; exit 1
fi

UBUNTU_VER=$(lsb_release -rs 2>/dev/null || echo "unknown")
if [[ ! "$UBUNTU_VER" =~ ^(20\.04|24\.04|26\.04)$ ]]; then
  echo -e "${YELLOW}警告: 检测到 Ubuntu $UBUNTU_VER，脚本主要面向 20.04/24.04/26.04，将继续尝试。${NC}"
fi

# ---------- 2. 交互配置 ----------
progress "收集配置参数（回车使用默认值）"
echo -e "\n${GREEN}===== 配置 AstrBot =====${NC}"
ASTRBOT_WEBUI_PORT=$(ask "AstrBot WebUI 端口" "6185")
ASTRBOT_WS_PORT=$(ask "AstrBot OneBot v11 反向 WebSocket 端口" "6199")

echo -e "\n${GREEN}===== 配置 SnowLuma =====${NC}"
SNOWLUMA_WEBUI_PORT=$(ask "SnowLuma WebUI 端口" "5099")
SNOWLUMA_NOVNC_PORT=$(ask "SnowLuma noVNC 端口（扫码登录用）" "6081")
SNOWLUMA_ONEBOT_PORT=$(ask "SnowLuma OneBot WebSocket 端口（供 AstrBot 反向连接）" "3001")

echo -e "\n${GREEN}===== OneBot 通信 Token =====${NC}"
echo "说明: 该 Token 将同时用于 SnowLuma 的 OneBot 鉴权，以及 AstrBot 反向 WS 的校验。"
ONEBOT_TOKEN=$(ask "OneBot 通信 Token（留空则自动生成随机值）" "$(openssl rand -hex 16 2>/dev/null || date +%s%N | sha256sum | cut -c1-32)")

echo -e "\n${GREEN}===== 时区 =====${NC}"
TZ_VALUE=$(ask "时区 (IANA 格式)" "Asia/Shanghai")

# 确认
echo -e "\n${YELLOW}即将使用以下配置:${NC}"
echo "  AstrBot WebUI:          ${ASTRBOT_WEBUI_PORT}"
echo "  AstrBot 反向 WS:        ${ASTRBOT_WS_PORT}"
echo "  SnowLuma WebUI:         ${SNOWLUMA_WEBUI_PORT}"
echo "  SnowLuma noVNC:         ${SNOWLUMA_NOVNC_PORT}"
echo "  SnowLuma OneBot WS:     ${SNOWLUMA_ONEBOT_PORT}"
echo "  OneBot Token:           ${ONEBOT_TOKEN:0:8}...（已设置）"
echo "  时区:                   ${TZ_VALUE}"
read -r -p "$(printf "${YELLOW}确认继续? [Y/n]: ${NC}")" CONFIRM
CONFIRM=${CONFIRM:-Y}
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then echo "已取消。"; exit 0; fi

# ---------- 3. 安装 Docker ----------
progress "安装 Docker CE 与 Compose 插件"
if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  echo -e "\n${GREEN}Docker 与 Compose 插件已安装，跳过。${NC}"
else
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release openssl >/dev/null
  curl -fsSL https://get.docker.com | bash -s -- >/dev/null 2>&1 || {
    echo -e "${RED}Docker 安装脚本执行失败，请检查网络或手动安装 Docker。${NC}"; exit 1
  }
  systemctl enable --now docker >/dev/null 2>&1
fi
docker compose version >/dev/null 2>&1 || { echo -e "${RED}Docker Compose 插件不可用。${NC}"; exit 1; }

# ---------- 4. 生成 compose 文件 ----------
progress "生成 docker-compose.yml"
DEPLOY_DIR="/opt/astrbot-snowluma"
mkdir -p "$DEPLOY_DIR/data-astrbot" "$DEPLOY_DIR/data-snowluma"
cd "$DEPLOY_DIR"

# 中国大陆网络环境提示：如需镜像加速，可手动替换 image 前缀为 m.daocloud.io/docker.io/
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
      - "127.0.0.1:${SNOWLUMA_ONEBOT_PORT}:3001"
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

echo -e "\n${GREEN}compose 文件已写入: ${DEPLOY_DIR}/docker-compose.yml${NC}"

# ---------- 5. 拉取镜像 ----------
progress "拉取 AstrBot 与 SnowLuma 镜像"
docker compose pull 2>&1 | while IFS= read -r line; do
  printf "\r  %s" "$line" | cut -c1-100
done
echo

# ---------- 6. 启动服务 ----------
progress "启动容器"
docker compose up -d

# ---------- 7. 完成信息 ----------
progress "部署完成"
echo -e "\n${GREEN}========== 部署成功 ==========${NC}"
echo -e "AstrBot WebUI:        ${BLUE}http://127.0.0.1:${ASTRBOT_WEBUI_PORT}${NC}"
echo -e "SnowLuma WebUI:       ${BLUE}http://127.0.0.1:${SNOWLUMA_WEBUI_PORT}${NC}"
echo -e "SnowLuma noVNC:       ${BLUE}http://127.0.0.1:${SNOWLUMA_NOVNC_PORT}${NC}  (首次启动密码在容器日志中)"
echo -e "OneBot Token:         ${YELLOW}${ONEBOT_TOKEN:0:12}...${NC}"
echo -e "\n${YELLOW}安全提示: 所有端口已绑定 127.0.0.1，公网无法直接访问。${NC}"
echo -e "${YELLOW}请通过 SSH 隧道从本机访问，例如:${NC}"
echo -e "  ssh -L ${ASTRBOT_WEBUI_PORT}:127.0.0.1:${ASTRBOT_WEBUI_PORT} -L ${SNOWLUMA_WEBUI_PORT}:127.0.0.1:${SNOWLUMA_WEBUI_PORT} -L ${SNOWLUMA_NOVNC_PORT}:127.0.0.1:${SNOWLUMA_NOVNC_PORT} user@your-server-ip"

echo -e "\n${YELLOW}后续步骤:${NC}"
echo "1. 浏览器打开 SnowLuma noVNC 地址，使用容器日志中的随机密码登录，扫码登录 QQ。"
echo "  查看密码: docker logs snowluma 2>&1 | grep -i password"
echo "2. 在 AstrBot WebUI 中配置消息平台 -> OneBot v11 -> 反向 WebSocket。"
echo "   端口填 ${ASTRBOT_WS_PORT}，Token 填上面显示的 OneBot Token。"
echo "3. 在 SnowLuma WebUI 中确认 OneBot WebSocket 已监听 ${SNOWLUMA_ONEBOT_PORT}，"
echo "   并将反向 WS 地址指向 AstrBot (ws://astrbot:${ASTRBOT_WS_PORT}/ws) 并填入相同 Token。"
echo -e "\n${GREEN}祝使用愉快。${NC}"