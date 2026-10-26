#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sbt-deploy.sh — 一键部署 AstrBot + SnowLuma
# 密码由 SnowLuma 自动生成，脚本负责提取并展示
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STEP_TOTAL=7
STEP=0

progress_bar() {
  local current=$1 total=$2 width=40
  local filled=$(( current * width / total ))
  local empty=$(( width - filled ))
  local bar blank
  bar=$(printf '%*s' "$filled" '' | tr ' ' '█')
  blank=$(printf '%*s' "$empty" '')
  printf "\r${BLUE}[%s%s] %d/%d${NC}" "$bar" "$blank" "$current" "$total"
}

step() {
  STEP=$((STEP + 1))
  progress_bar "$STEP" "$STEP_TOTAL"
  echo ""
  echo -e "${YELLOW}>>> $1${NC}"
  echo -e "${BLUE}    $ $2${NC}"
}

if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}请使用 sudo 运行此脚本: sudo bash $0${NC}"
  exit 1
fi

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  AstrBot + SnowLuma 一键部署${NC}"
echo -e "${GREEN}  （密码由 SnowLuma 自动生成）${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ---------- 交互配置 ----------
echo -e "${YELLOW}[1/2] 是否需要远程公网访问？${NC}"
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
echo -e "${YELLOW}[2/2] 端口配置（直接回车使用默认值）${NC}"

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
echo -e "${GREEN}配置确认:${NC}"
echo "  公网访问: ${PUBLIC_ACCESS}  ${PUBLIC_IP:+(IP: $PUBLIC_IP)}"
echo "  AstrBot WebUI: :$ASTRBOT_WEBUI_PORT"
echo "  AstrBot OneBot: :$ASTRBOT_ONEBOT_PORT"
echo "  SnowLuma WebUI: :$SNOWLUMA_WEBUI_PORT"
echo "  SnowLuma noVNC: :$SNOWLUMA_VNC_PORT"
echo "  SnowLuma WebUI 与 VNC 密码: 由 SnowLuma 首次启动自动生成"
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

# ---------- 3. 清理旧容器（保留数据） ----------
step "清理旧的同名容器..." "docker compose down --remove-orphans && docker rm -f snowluma astrbot"

cd "$DEPLOY_DIR"
docker compose down --remove-orphans 2>/dev/null || true
docker rm -f snowluma astrbot 2>/dev/null || true

# ---------- 4. 启动容器 ----------
step "拉取镜像并启动容器..." "docker compose up -d"
docker compose up -d

# ---------- 5. 提取自动生成的密码 ----------
step "提取 SnowLuma 自动生成的密码..." "docker logs snowluma | grep ..."

echo -e "${YELLOW}等待 SnowLuma 初始化（约 20 秒）...${NC}"
sleep 20

SNOWLUMA_WEBUI_PASSWORD=""
SNOWLUMA_VNC_PASSWORD=""

for i in $(seq 1 20); do
  LOG_OUTPUT=$(docker logs snowluma 2>&1 || true)

  SNOWLUMA_WEBUI_PASSWORD=$(echo "$LOG_OUTPUT" | grep -iEo 'password[=:][^ ]+' | sed -n '1p' | cut -d'=' -f2- | cut -d':' -f2- | tr -d ' ' || true)
  SNOWLUMA_VNC_PASSWORD=$(echo "$LOG_OUTPUT" \
  | grep -iE '远程桌面密码|remote desktop password' \
  | sed -E 's/.*[:：][[:space:]]*//' \
  | sed -n '1p' \
  | tr -d ' \r' || true)

  if [[ -n "$SNOWLUMA_WEBUI_PASSWORD" && -n "$SNOWLUMA_VNC_PASSWORD" ]]; then
    break
  fi
  sleep 5
done

# ---------- 6. 创建 sbt 启动脚本 ----------
step "创建 sbt 启动脚本..." "写入 /usr/local/bin/sbt"
cat > /usr/local/bin/sbt <<'SBT_EOF'
#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="/opt/sbt-stack"
cd "$DEPLOY_DIR"

# ---------- 读取配置 ----------
get_ports_and_host() {
  ASTRBOT_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:6185)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "6185")
  SNOWLUMA_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:5099)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "5099")
  SNOWLUMA_VNC_PORT=$(grep -oP '"\K[^"]+(?=:6081)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "6081")

  PUBLIC_IP=""
  if [[ -f "$DEPLOY_DIR/.public_ip" ]]; then
    PUBLIC_IP=$(cat "$DEPLOY_DIR/.public_ip")
  fi
  HOST="${PUBLIC_IP:-127.0.0.1}"
}

# ---------- 输出地址与密码 ----------
show_info() {
  get_ports_and_host

  LOG_OUTPUT=$(docker logs snowluma 2>&1 || true)
  WEBUI_PASS=$(echo "$LOG_OUTPUT" | grep -iEo 'password[=:][^ ]+' | sed -n '1p' | cut -d'=' -f2- | cut -d':' -f2- | tr -d ' ' || true)
  VNC_PASS=$(echo "$LOG_OUTPUT" \
  | grep -iE '远程桌面密码|remote desktop password' \
  | sed -E 's/.*[:：][[:space:]]*//' \
  | sed -n '1p' \
  | tr -d ' \r' || true)
  
  echo ""
  echo "============================================================"
  echo "  AstrBot + SnowLuma"
  echo "============================================================"
  echo ""
  echo "【访问地址】"
  echo "  AstrBot  WebUI : http://$HOST:$ASTRBOT_WEBUI_PORT"
  echo "  SnowLuma WebUI : http://$HOST:$SNOWLUMA_WEBUI_PORT"
  echo "  SnowLuma VNC   : http://$HOST:$SNOWLUMA_VNC_PORT"
  echo ""
  echo "【登录凭据】"
  echo "  AstrBot WebUI  : 用户名 astrbot / 密码 astrbot（首次登录请修改）"
  echo "  SnowLuma WebUI : 用户名 admin / 密码 ${WEBUI_PASS:-请执行 sbt logs 查看}"
  echo "  SnowLuma VNC   : 密码 ${VNC_PASS:-请执行 sbt logs 查看}"
  echo ""
  echo "============================================================"
}

# ---------- 子命令 ----------
CMD="${1:-start}"

case "$CMD" in
  start|up)
    echo "启动 AstrBot + SnowLuma ..."
    docker compose up -d
    sleep 10
    show_info
    ;;

  stop|down)
    echo "停止 AstrBot + SnowLuma ..."
    docker compose down
    echo "已停止（数据保留在 $DEPLOY_DIR/*-data）"
    ;;

  restart)
    echo "重启 AstrBot + SnowLuma ..."
    docker compose down
    docker compose up -d
    sleep 10
    show_info
    ;;

  status|ps)
    docker compose ps
    ;;

  logs)
    # 可选：sbt logs astrbot / sbt logs snowluma
    SERVICE="${2:-}"
    if [[ -n "$SERVICE" ]]; then
      docker compose logs -f --tail=100 "$SERVICE"
    else
      docker compose logs -f --tail=100
    fi
    ;;

  *)
    echo "用法: sbt [start|stop|restart|status|logs]"
    echo ""
    echo "  sbt            启动服务并显示地址与密码（默认）"
    echo "  sbt start      同上"
    echo "  sbt stop       停止服务（保留数据）"
    echo "  sbt restart    重启服务并显示地址与密码"
    echo "  sbt status     查看容器状态"
    echo "  sbt logs       实时查看全部日志"
    echo "  sbt logs astrbot   只看 AstrBot 日志"
    echo "  sbt logs snowluma  只看 SnowLuma 日志"
    exit 1
    ;;
esac
SBT_EOF
chmod +x /usr/local/bin/sbt

if [[ -n "$PUBLIC_IP" ]]; then
  echo "$PUBLIC_IP" > "$DEPLOY_DIR/.public_ip"
fi

# ---------- 7. 完成 ----------
step "完成！" "输出访问地址与密码"

HOST_DISPLAY="${PUBLIC_IP:-127.0.0.1}"

cat > "$DEPLOY_DIR/连接指引.txt" <<GUIDE
============================================================
  AstrBot + SnowLuma 部署完成
============================================================

【访问地址】
  AstrBot  WebUI : http://${HOST_DISPLAY}:${ASTRBOT_WEBUI_PORT}
  SnowLuma WebUI : http://${HOST_DISPLAY}:${SNOWLUMA_WEBUI_PORT}
  SnowLuma VNC   : http://${HOST_DISPLAY}:${SNOWLUMA_VNC_PORT}

【登录凭据】
  AstrBot WebUI  : 用户名 astrbot / 密码 astrbot（首次登录请修改）
  SnowLuma WebUI : 用户名 admin / 密码 ${SNOWLUMA_WEBUI_PASSWORD:-请执行 docker logs snowluma 查看}
  SnowLuma VNC   : 密码 ${SNOWLUMA_VNC_PASSWORD:-请执行 docker logs snowluma 查看}
  （SnowLuma 密码仅在首次启动时打印一次，之后保存在数据卷中）



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
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${YELLOW}【访问地址】${NC}"
echo -e "  AstrBot  WebUI : ${GREEN}http://${HOST_DISPLAY}:${ASTRBOT_WEBUI_PORT}${NC}"
echo -e "  SnowLuma WebUI : ${GREEN}http://${HOST_DISPLAY}:${SNOWLUMA_WEBUI_PORT}${NC}"
echo -e "  SnowLuma VNC   : ${GREEN}http://${HOST_DISPLAY}:${SNOWLUMA_VNC_PORT}${NC}"
echo ""
echo -e "${YELLOW}【登录凭据】${NC}"
echo -e "  AstrBot WebUI  : 用户名 ${GREEN}astrbot${NC} / 密码 ${GREEN}astrbot${NC}（首次登录请修改）"
echo -e "  SnowLuma WebUI : 用户名 ${GREEN}admin${NC} / 密码 ${GREEN}${SNOWLUMA_WEBUI_PASSWORD:-请执行 docker logs snowluma 查看}${NC}"
echo -e "  SnowLuma VNC   : 密码 ${GREEN}${SNOWLUMA_VNC_PASSWORD:-请执行 docker logs snowluma 查看}${NC}"
echo ""
echo -e "${GREEN}连接指引已保存至: $DEPLOY_DIR/连接指引.txt${NC}"
echo -e "${GREEN}日常启动: 输入 ${YELLOW}sbt${GREEN}${NC}"
echo -e "${GREEN}============================================================${NC}"