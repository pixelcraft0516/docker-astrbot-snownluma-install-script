#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sbt-deploy.sh — 一键部署 AstrBot + SnowLuma
# 适用: Debian/Ubuntu/CentOS (Linux) 全新环境
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STEP_TOTAL=6
STEP=0

progress_bar() {
  local current=$1
  local total=$2
  local width=40
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
  local blank=$(printf '%*s' "$empty" '')
  printf "\r${BLUE}[%s%s] %d/%d${NC}" "$bar" "$blank" "$current" "$total"
}

step() {
  STEP=$((STEP + 1))
  progress_bar "$STEP" "$STEP_TOTAL"
  echo ""
  echo -e "${YELLOW}>>> $1${NC}"
  echo -e "${BLUE}    $ $2${NC}"
}

# ---------- 0. 检查 root ----------
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo 运行此脚本: sudo bash $0${NC}"
  exit 1
fi

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  AstrBot + SnowLuma 一键部署${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ---------- 交互配置 ----------
echo -e "${YELLOW}[1/3] 是否需要远程公网访问？${NC}"
read -rp "请输入 y/n (默认 n): " PUBLIC_ACCESS
PUBLIC_ACCESS=${PUBLIC_ACCESS:-n}

PUBLIC_IP=""
if [[ "$PUBLIC_ACCESS" =~ ^[Yy] ]]; then
  echo -e "请输入公网 IP（直接回车自动读取）:"
  read -rp "公网 IP: " INPUT_IP
  if [[ -z "$INPUT_IP" ]]; then
    echo -e "${BLUE}正在自动获取公网 IP...${NC}"
    PUBLIC_IP=$(curl -s --max-time 10 https://api.ipify.org || curl -s --max-time 10 https://ifconfig.me || true)
    if [[ -z "$PUBLIC_IP" ]]; then
      echo -e "${RED}自动获取失败，请手动重新运行并输入公网 IP。${NC}"
      exit 1
    fi
  else
    PUBLIC_IP="$INPUT_IP"
  fi
  echo -e "${GREEN}将使用公网地址: $PUBLIC_IP${NC}"
else
  echo -e "${GREEN}将使用本机地址进行访问。${NC}"
fi

echo ""
echo -e "${YELLOW}[2/3] 端口配置（直接回车使用默认值）${NC}"

read -rp "AstrBot WebUI 端口 (默认 6185): " ASTRBOT_WEBUI_PORT
ASTRBOT_WEBUI_PORT=${ASTRBOT_WEBUI_PORT:-6185}

read -rp "AstrBot OneBot 端口 (默认 6199): " ASTRBOT_ONEBOT_PORT
ASTRBOT_ONEBOT_PORT=${ASTRBOT_ONEBOT_PORT:-6199}

read -rp "SnowLuma WebUI 端口 (默认 5099): " SNOWLUMA_WEBUI_PORT
SNOWLUMA_WEBUI_PORT=${SNOWLUMA_WEBUI_PORT:-5099}

read -rp "SnowLuma noVNC 端口 (默认 6081): " SNOWLUMA_VNC_PORT
SNOWLUMA_VNC_PORT=${SNOWLUMA_VNC_PORT:-6081}

read -rp "SnowLuma OneBot WebSocket 端口 (默认 3001，仅容器内部使用): " SNOWLUMA_ONEBOT_WS_PORT
SNOWLUMA_ONEBOT_WS_PORT=${SNOWLUMA_ONEBOT_WS_PORT:-3001}

echo ""
echo -e "${YELLOW}[3/3] 安全设置${NC}"
read -rsp "SnowLuma VNC 密码（直接回车使用随机生成）: " VNC_PASSWD
echo ""
if [[ -z "$VNC_PASSWD" ]]; then
  VNC_PASSWD=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 12)
  echo -e "${GREEN}已随机生成 VNC 密码: ${VNC_PASSWD}${NC}"
fi

echo ""
echo -e "${GREEN}配置确认:${NC}"
echo "  公网访问: ${PUBLIC_ACCESS}  ${PUBLIC_IP:+(IP: $PUBLIC_IP)}"
echo "  AstrBot WebUI: :$ASTRBOT_WEBUI_PORT"
echo "  AstrBot OneBot: :$ASTRBOT_ONEBOT_PORT"
echo "  SnowLuma WebUI: :$SNOWLUMA_WEBUI_PORT"
echo "  SnowLuma noVNC: :$SNOWLUMA_VNC_PORT"
echo "  VNC 密码: $VNC_PASSWD"
echo ""
read -rp "确认开始部署？(y/n，默认 y): " CONFIRM
[[ "$CONFIRM" =~ ^[Nn] ]] && exit 0

# ---------- 部署目录 ----------
DEPLOY_DIR="/opt/sbt-stack"
mkdir -p "$DEPLOY_DIR"/{astrbot-data,snowluma-data,snowluma-qq-config,snowluma-qq-data}

# ---------- 1. 安装 Docker CE ----------
step "安装 Docker CE..." "curl -fsSL https://get.docker.com | bash -s docker"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | bash -s docker
fi
systemctl enable docker --now &>/dev/null || true

# 配置镜像加速（可选，国内环境）
if [[ ! -f /etc/docker/daemon.json ]]; then
  mkdir -p /etc/docker
  cat > /etc/docker/daemon.json <<'EOF'
{
  "registry-mirrors": ["https://docker.m.daocloud.io"]
}
EOF
  systemctl restart docker
fi

# ---------- 2. 生成 docker-compose.yml ----------
step "生成 docker-compose.yml..." "写入 $DEPLOY_DIR/docker-compose.yml"

cat > "$DEPLOY_DIR/docker-compose.yml" <<YAML
services:
  snowluma:
    image: motricseven7/snowluma:latest
    container_name: snowluma
    hostname: snowluma
    restart: unless-stopped
    shm_size: 1gb
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    environment:
      TZ: Asia/Shanghai
      VNC_PASSWD: "${VNC_PASSWD}"
      SNOWLUMA_UID: "1000"
      SNOWLUMA_GID: "1000"
      SNOWLUMA_WEBUI_PORT: "${SNOWLUMA_WEBUI_PORT}"
      SNOWLUMA_ACCEPT_EULA: "1"
      SNOWLUMA_ACCEPT_PRIVACY: "1"
    ports:
      - "${SNOWLUMA_VNC_PORT}:6081"
      - "${SNOWLUMA_WEBUI_PORT}:${SNOWLUMA_WEBUI_PORT}"
    volumes:
      - ./snowluma-data:/app/snowluma-data
      - ./snowluma-qq-config:/app/.config
      - ./snowluma-qq-data:/app/.local/share
    networks:
      - botnet

  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: unless-stopped
    environment:
      TZ: Asia/Shanghai
    ports:
      - "${ASTRBOT_WEBUI_PORT}:6185"
      - "${ASTRBOT_ONEBOT_PORT}:6199"
    volumes:
      - ./astrbot-data:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
    networks:
      - botnet

networks:
  botnet:
    driver: bridge
YAML

# ---------- 3. 启动容器 ----------
step "拉取镜像并启动容器..." "docker compose up -d"
cd "$DEPLOY_DIR"
docker compose up -d

# ---------- 4. 等待并提取 SnowLuma WebUI 密码 ----------
step "提取初始密码..." "docker logs snowluma 2>&1 | grep -i 'password'"
echo -e "${YELLOW}等待 SnowLuma 初始化（约 15 秒）...${NC}"
sleep 15

SNOWLUMA_WEBUI_PASSWORD=""
for i in $(seq 1 20); do
  SNOWLUMA_WEBUI_PASSWORD=$(docker logs snowluma 2>&1 | grep -iEo 'password[=:][^ ]+' | head -1 | cut -d'=' -f2- | cut -d':' -f2- | tr -d ' ' || true)
  [[ -n "$SNOWLUMA_WEBUI_PASSWORD" ]] && break
  sleep 3
done

# ---------- 5. 创建 sbt 启动脚本 ----------
step "创建 sbt 启动脚本..." "写入 /usr/local/bin/sbt"
cat > /usr/local/bin/sbt <<'SBT_EOF'
#!/usr/bin/env bash
set -euo pipefail
DEPLOY_DIR="/opt/sbt-stack"
cd "$DEPLOY_DIR"

echo "启动 AstrBot + SnowLuma ..."
docker compose up -d

# 等待服务就绪
sleep 8

# 动态读取配置中的端口
ASTRBOT_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:6185)' docker-compose.yml 2>/dev/null | head -1 || echo "6185")
SNOWLUMA_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:5099)' docker-compose.yml 2>/dev/null | head -1 || echo "5099")
SNOWLUMA_VNC_PORT=$(grep -oP '"\K[^"]+(?=:6081)' docker-compose.yml 2>/dev/null | head -1 || echo "6081")

PUBLIC_IP=""
if [[ -f /opt/sbt-stack/.public_ip ]]; then
  PUBLIC_IP=$(cat /opt/sbt-stack/.public_ip)
fi
HOST="${PUBLIC_IP:-127.0.0.1}"

echo ""
echo "=============================="
echo "  AstrBot  WebUI : http://$HOST:$ASTRBOT_WEBUI_PORT"
echo "  SnowLuma WebUI : http://$HOST:$SNOWLUMA_WEBUI_PORT"
echo "  SnowLuma VNC   : http://$HOST:$SNOWLUMA_VNC_PORT"
echo "=============================="

# 提取 WebUI 密码
PASS=$(docker logs snowluma 2>&1 | grep -iEo 'password[=:][^ ]+' | head -1 | cut -d'=' -f2- | cut -d':' -f2- | tr -d ' ' || true)
[[ -n "$PASS" ]] && echo "  SnowLuma WebUI 密码: $PASS"
echo "  VNC 密码: 请查看部署时设置（或 SnowLuma 日志）"
echo "=============================="
SBT_EOF
chmod +x /usr/local/bin/sbt

# 记录公网 IP 供 sbt 使用
if [[ -n "$PUBLIC_IP" ]]; then
  echo "$PUBLIC_IP" > "$DEPLOY_DIR/.public_ip"
fi

# ---------- 6. 输出连接指引 ----------
step "完成！生成连接指引..." "输出 AstrBot OneBot 连接说明"

cat > "$DEPLOY_DIR/连接指引.txt" <<GUIDE
============================================================
  AstrBot + SnowLuma 部署完成
============================================================

【WebUI 地址】
  AstrBot  : http://${PUBLIC_IP:-127.0.0.1}:${ASTRBOT_WEBUI_PORT}
  SnowLuma : http://${PUBLIC_IP:-127.0.0.1}:${SNOWLUMA_WEBUI_PORT}
  VNC      : http://${PUBLIC_IP:-127.0.0.1}:${SNOWLUMA_VNC_PORT}

【密码】
  SnowLuma WebUI 初始账号: admin
  SnowLuma WebUI 初始密码: ${SNOWLUMA_WEBUI_PASSWORD:-请查看 docker logs snowluma}
  VNC 密码: ${VNC_PASSWD}

【下一步：在 AstrBot WebUI 中连接 SnowLuma】
AstrBot 的 OneBot 连接需在 WebUI 中手动完成（官方未提供环境变量注入方式）：

1. 打开 AstrBot WebUI: http://${PUBLIC_IP:-127.0.0.1}:${ASTRBOT_WEBUI_PORT}
2. 左侧菜单 → 消息平台 → 新增适配器
3. 选择 “aiocqhttp (OneBot v11)”
4. 连接方式选择 “正向 WebSocket”（AstrBot 主动连接 SnowLuma）
5. 地址填写: ws://snowluma:${SNOWLUMA_ONEBOT_WS_PORT}
   （AstrBot 容器内可通过服务名 snowluma 访问 SnowLuma）
6. Token 留空（除非你在 SnowLuma WebUI 中设置了 OneBot access token）
7. 保存并启用

【SnowLuma 登录 QQ】
1. 打开 SnowLuma WebUI，使用 admin + 上述密码登录
2. 在 WebUI 中启动 QQ 实例，用手机扫码登录
3. 确保 OneBot WebSocket 服务端已开启（默认端口 ${SNOWLUMA_ONEBOT_WS_PORT}）

【日常启动】
输入 sbt 即可启动全部服务，并自动输出地址和密码。

【配置文件位置】
  $DEPLOY_DIR/docker-compose.yml
  数据目录: $DEPLOY_DIR/*-data
============================================================
GUIDE

echo ""
progress_bar "$STEP_TOTAL" "$STEP_TOTAL"
echo ""
echo -e "${GREEN}部署完成！连接指引已保存至: $DEPLOY_DIR/连接指引.txt${NC}"
echo ""
cat "$DEPLOY_DIR/连接指引.txt"