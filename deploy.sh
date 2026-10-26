#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

TOTAL_STEPS=16
CURRENT_STEP=0
LAST_CMD=""

progress() {
    local desc="$1"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar_len=30
    local filled=$(( percent * bar_len / 100 ))
    local empty=$(( bar_len - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf "\r${CYAN}[%s]${NC} %3d%%  %s" "$bar" "$percent" "$desc"
    if [[ -n "$LAST_CMD" ]]; then
        printf "\n  ${YELLOW}↳ %s${NC}\n" "$LAST_CMD"
    else
        printf "\n"
    fi
}

run_cmd() {
    local desc="$1"; shift
    LAST_CMD="$*"
    if ! "$@" >> /tmp/astrbot_snowluma_deploy.log 2>&1; then
        echo -e "\n${RED}命令失败：$*${NC}"
        echo -e "${RED}日志：/tmp/astrbot_snowluma_deploy.log${NC}"
        tail -n 30 /tmp/astrbot_snowluma_deploy.log
        exit 1
    fi
    progress "$desc"
}

# ---------- 前置检查 ----------
[[ $EUID -ne 0 ]] && { echo -e "${RED}请使用 root 或 sudo 运行。${NC}"; exit 1; }
OS_ID=$(lsb_release -si 2>/dev/null || true)
OS_CODENAME=$(lsb_release -cs 2>/dev/null || true)
OS_VERSION=$(lsb_release -rs 2>/dev/null || true)
[[ "$OS_ID" != "Ubuntu" ]] && { echo -e "${RED}仅支持 Ubuntu。${NC}"; exit 1; }
echo -e "${GREEN}Ubuntu $OS_VERSION ($OS_CODENAME)${NC}"

# ---------- 公网访问 ----------
echo -e "\n${YELLOW}===== 公网访问配置 =====${NC}"
read -r -p "是否需要公网访问？[y/N]：" PUBLIC_ACCESS
PUBLIC_ACCESS=${PUBLIC_ACCESS:-N}
if [[ "$PUBLIC_ACCESS" =~ ^[Yy]$ ]]; then
    read -r -p "公网 IP（回车自动获取）： " USER_IP
    if [[ -n "$USER_IP" ]]; then PUBLIC_IP="$USER_IP"
    else
        PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || \
                    curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || echo "<公网IP>")
    fi
    ACCESS_HOST="$PUBLIC_IP"
    echo -e "${GREEN}公网访问 IP：$ACCESS_HOST${NC}"
else
    ACCESS_HOST=$(hostname -I | awk '{print $1}')
    echo -e "${GREEN}使用内网 IP：$ACCESS_HOST${NC}"
fi

# ---------- 基础依赖 & Docker ----------
run_cmd "更新 APT 索引" apt-get update -qq
run_cmd "安装基础工具" apt-get install -y -qq ca-certificates curl gnupg lsb-release

run_cmd "创建 keyrings 目录" mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg >> /tmp/astrbot_snowluma_deploy.log 2>&1
progress "导入 Docker GPG 密钥"

run_cmd "写入 Docker APT 源" bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $OS_CODENAME stable\" > /etc/apt/sources.list.d/docker.list"
run_cmd "更新 Docker 源索引" apt-get update -qq
run_cmd "安装 Docker CE 组件" apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
run_cmd "启动 Docker" systemctl enable --now docker
run_cmd "验证 Docker" docker --version && docker compose version

# ---------- 目录 ----------
DEPLOY_DIR="/opt/astrbot_snowluma"
run_cmd "创建部署目录" mkdir -p "$DEPLOY_DIR"/{astrbot/data,snowluma/{snowluma-data,snowluma-qq-config,snowluma-qq-data}}

# ---------- AstrBot ----------
run_cmd "拉取 AstrBot 镜像" docker pull soulter/astrbot:latest
run_cmd "启动 AstrBot" docker run -itd \
    --name astrbot --restart unless-stopped \
    -p 6185:6185 -p 6199:6199 \
    -v "$DEPLOY_DIR/astrbot/data:/AstrBot/data" \
    -v /etc/localtime:/etc/localtime:ro \
    -v /etc/timezone:/etc/timezone:ro \
    -e TZ=Asia/Shanghai \
    soulter/astrbot:latest

# ---------- SnowLuma：生成 compose + env ----------
SNOW_DIR="$DEPLOY_DIR/snowluma"
cd "$SNOW_DIR"

# 1. 生成 .env（可选，用于集中管理变量）
cat > .env <<'ENVEOF'
TZ=Asia/Shanghai
VNC_PASSWD=vncpasswd
SNOWLUMA_UID=1000
SNOWLUMA_GID=1000
SNOWLUMA_WEBUI_PORT=5099
SNOWLUMA_LOG_LEVEL=info
SNOWLUMA_SCREEN=1280x720x24
SNOWLUMA_HOOK_AUTOLOAD=1
SNOWLUMA_EXTRA_QQ_HOMES=
SNOWLUMA_QQ_FLAGS=--disable-gpu --disable-software-rasterizer --disable-gpu-compositing
ENVEOF
progress "生成 SnowLuma .env"

# 2. 生成 docker-compose.yml（关键修复）
cat > docker-compose.yml <<'COMPOSE_EOF'
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
    env_file: .env
    ports:
      - "6081:6081"
      - "5099:5099"
      - "3000:3000"
      - "3001:3001"
    volumes:
      - ./snowluma-data:/app/snowluma-data
      - ./snowluma-qq-config:/app/.config
      - ./snowluma-qq-data:/app/.local/share
COMPOSE_EOF
progress "生成 SnowLuma docker-compose.yml"

# ---------- 启动 SnowLuma ----------
run_cmd "拉取 SnowLuma 镜像" docker pull motricseven7/snowluma:latest
run_cmd "启动 SnowLuma" docker compose up -d

# 等待首次初始化并写日志
echo -e "${CYAN}等待 SnowLuma 初始化（20 秒）...${NC}"
sleep 20

# ---------- 提取凭据 ----------
SNOW_LOGS=$(docker logs snowluma 2>&1 || true)

# noVNC 密码：优先从日志中提取；若设置了固定值则使用固定值
VNC_PASS="vncpasswd"
LOG_VNC=$(echo "$SNOW_LOGS" | grep -iE '远程桌面密码|vnc.*password|password.*vnc|noVNC' | tail -n 5 || true)
if echo "$LOG_VNC" | grep -qiE '随机|generated|random'; then
    EXTRACTED=$(echo "$LOG_VNC" | grep -oE '[A-Za-z0-9_-]{6,}' | tail -n 1 || true)
    [[ -n "$EXTRACTED" ]] && VNC_PASS="$EXTRACTED"
fi

# WebUI 密码：从日志中提取，或提示查看日志
WEBUI_PASS=$(echo "$SNOW_LOGS" | grep -iE 'webui.*密码|webui.*password|admin.*密码|admin.*password' | tail -n 1 | grep -oE '[A-Za-z0-9_-]{6,}' || true)
[[ -z "$WEBUI_PASS" ]] && WEBUI_PASS="见 docker logs snowluma"

# ---------- 管理脚本 ----------
MANAGE="$DEPLOY_DIR/manage.sh"
cat > "$MANAGE" <<MANAGEEOF
#!/usr/bin/env bash
set -euo pipefail
D="$DEPLOY_DIR"
H="$ACCESS_HOST"
case "\${1:-}" in
  start)
    docker start astrbot 2>/dev/null || docker run -itd --name astrbot --restart unless-stopped \\
      -p 6185:6185 -p 6199:6199 -v "\$D/astrbot/data:/AstrBot/data" \\
      -v /etc/localtime:/etc/localtime:ro -v /etc/timezone:/etc/timezone:ro \\
      -e TZ=Asia/Shanghai soulter/astrbot:latest
    cd "\$D/snowluma" && docker compose up -d
    echo "AstrBot WebUI : http://\$H:6185"
    echo "SnowLuma WebUI: http://\$H:5099"
    echo "SnowLuma noVNC: http://\$H:6081"
    ;;
  stop)
    docker stop astrbot 2>/dev/null || true
    cd "\$D/snowluma" && docker compose down
    ;;
  restart) "\$0" stop; sleep 2; "\$0" start ;;
  status)
    docker ps -a --filter name=astrbot --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    docker ps -a --filter name=snowluma --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    ;;
  *)
    echo "用法：\$0 {start|stop|restart|status}"
    echo "AstrBot WebUI : http://\$H:6185"
    echo "SnowLuma WebUI: http://\$H:5099"
    echo "SnowLuma noVNC: http://\$H:6081"
    ;;
esac
MANAGEEOF
chmod +x "$MANAGE"
progress "生成管理脚本"

# ---------- 摘要 ----------
echo -e "\n${GREEN}========== 部署完成 ==========${NC}"
echo -e "${CYAN}【AstrBot】${NC}"
echo "  WebUI        : http://$ACCESS_HOST:6185"
echo "  WebSocket    : ws://$ACCESS_HOST:6199"
echo ""
echo -e "${CYAN}【SnowLuma】${NC}"
echo "  WebUI        : http://$ACCESS_HOST:5099"
echo "  WebUI 密码   : $WEBUI_PASS"
echo "  noVNC        : http://$ACCESS_HOST:6081"
echo "  noVNC 密码   : $VNC_PASS"
echo "  OneBot HTTP  : http://$ACCESS_HOST:3000"
echo "  OneBot WS    : ws://$ACCESS_HOST:3001"
echo ""
echo -e "${CYAN}【管理脚本】${NC}"
echo "  $MANAGE {start|stop|restart|status}"
echo ""
echo -e "${YELLOW}云服务器请放行端口：6185 6199 5099 6081 3000 3001${NC}"