#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 20.04+ 通用部署脚本：Docker + AstrBot + SnowLuma
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_STEPS=14
CURRENT_STEP=0
LAST_CMD=""

# ---------- 进度条函数 ----------
progress() {
    local step="$1"
    local desc="$2"
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local bar_len=30
    local filled=$(( percent * bar_len / 100 ))
    local empty=$(( bar_len - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done

    # 第一行：进度条 + 百分比 + 描述
    printf "\r${CYAN}[%s]${NC} %3d%%  %s\n" "$bar" "$percent" "$desc"
    # 第二行：具体执行的命令（如果存在）
    if [[ -n "$LAST_CMD" ]]; then
        printf "  ${YELLOW}↳ %s${NC}\n" "$LAST_CMD"
    fi
}

# 执行命令并显示进度
run_cmd() {
    local desc="$1"
    shift
    LAST_CMD="$*"
    if ! "$@" >> /tmp/astrbot_snowluma_deploy.log 2>&1; then
        echo -e "\n${RED}命令失败：$*${NC}"
        echo -e "${RED}详细日志：/tmp/astrbot_snowluma_deploy.log${NC}"
        tail -n 30 /tmp/astrbot_snowluma_deploy.log
        exit 1
    fi
    progress 0 "$desc"
}

# ---------- 前置检查 ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 sudo 或 root 运行此脚本。${NC}"
    exit 1
fi

if ! lsb_release -si >/dev/null 2>&1; then
    echo -e "${RED}未检测到 lsb_release，请先安装 lsb-release。${NC}"
    exit 1
fi

OS_ID=$(lsb_release -si)
OS_CODENAME=$(lsb_release -cs)
OS_VERSION=$(lsb_release -rs)

if [[ "$OS_ID" != "Ubuntu" ]]; then
    echo -e "${RED}此脚本专为 Ubuntu 设计，当前系统：$OS_ID${NC}"
    exit 1
fi

echo -e "${GREEN}检测到 Ubuntu $OS_VERSION ($OS_CODENAME)${NC}"
echo -e "${CYAN}部署日志：/tmp/astrbot_snowluma_deploy.log${NC}\n"

# ---------- 1. 询问公网访问 ----------
echo -e "${YELLOW}===== 公网访问配置 =====${NC}"
read -r -p "是否需要通过公网 IP 访问 AstrBot / SnowLuma？[y/N]：" PUBLIC_ACCESS
PUBLIC_ACCESS=${PUBLIC_ACCESS:-N}

PUBLIC_IP=""
if [[ "$PUBLIC_ACCESS" =~ ^[Yy]$ ]]; then
    read -r -p "请输入公网 IP（直接回车自动获取）： " USER_IP
    if [[ -n "$USER_IP" ]]; then
        PUBLIC_IP="$USER_IP"
    else
        echo -e "${CYAN}正在自动获取公网 IP...${NC}"
        PUBLIC_IP=$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || \
                    curl -4 -fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)
        if [[ -z "$PUBLIC_IP" ]]; then
            echo -e "${YELLOW}未能自动获取公网 IP，将使用 <公网IP> 占位。${NC}"
            PUBLIC_IP="<公网IP>"
        fi
    fi
    echo -e "${GREEN}公网访问 IP：$PUBLIC_IP${NC}"
    ACCESS_HOST="$PUBLIC_IP"
else
    echo -e "${GREEN}未启用公网访问，访问地址将使用本机 IP。${NC}"
    ACCESS_HOST=$(hostname -I | awk '{print $1}')
fi
echo ""

# ---------- 2. 安装基础依赖 ----------
progress 0 "安装基础依赖"
run_cmd "安装 ca-certificates curl gnupg lsb-release" \
    apt-get update -qq
run_cmd "安装必要工具" \
    apt-get install -y -qq ca-certificates curl gnupg lsb-release

# ---------- 3. 配置 Docker 官方源 ----------
progress 0 "准备 Docker GPG 密钥"
run_cmd "创建 keyrings 目录" mkdir -p /etc/apt/keyrings
LAST_CMD="curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg >> /tmp/astrbot_snowluma_deploy.log 2>&1
progress 0 "导入 Docker GPG 密钥"

run_cmd "写入 Docker APT 源（$OS_CODENAME）" \
    bash -c "echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $OS_CODENAME stable\" > /etc/apt/sources.list.d/docker.list"

# ---------- 4. 安装 Docker CE ----------
progress 0 "更新 APT 索引（Docker 源）"
run_cmd "apt-get update" apt-get update -qq

progress 0 "安装 Docker CE（不装 Desktop）"
run_cmd "安装 docker-ce docker-ce-cli containerd.io docker-compose-plugin" \
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# ---------- 5. 启动 Docker 并验证 ----------
progress 0 "启动 Docker 服务"
run_cmd "systemctl enable --now docker" systemctl enable --now docker

progress 0 "验证 Docker"
run_cmd "docker --version" docker --version
run_cmd "docker compose version" docker compose version

# ---------- 6. 创建部署目录 ----------
DEPLOY_DIR="/opt/astrbot_snowluma"
progress 0 "创建部署目录"
run_cmd "mkdir -p $DEPLOY_DIR/astrbot/data" mkdir -p "$DEPLOY_DIR/astrbot/data"
run_cmd "mkdir -p $DEPLOY_DIR/snowluma/data" mkdir -p "$DEPLOY_DIR/snowluma/data"
cd "$DEPLOY_DIR"

# ---------- 7. 部署 AstrBot ----------
progress 0 "拉取 AstrBot 镜像"
run_cmd "docker pull soulter/astrbot:latest" docker pull soulter/astrbot:latest

progress 0 "启动 AstrBot 容器"
run_cmd "docker run AstrBot（6185/6199）" \
    docker run -itd \
    --name astrbot \
    --restart unless-stopped \
    -p 6185:6185 \
    -p 6199:6199 \
    -v "$DEPLOY_DIR/astrbot/data:/AstrBot/data" \
    -v /etc/localtime:/etc/localtime:ro \
    -e TZ=Asia/Shanghai \
    soulter/astrbot:latest

# ---------- 8. 准备 SnowLuma 环境 ----------
progress 0 "生成 SnowLuma 环境变量"
cat > "$DEPLOY_DIR/snowluma/.env" <<'ENVEOF'
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
progress 0 "写入 SnowLuma .env"

# ---------- 9. 部署 SnowLuma ----------
cd "$DEPLOY_DIR/snowluma"
progress 0 "拉取 SnowLuma 镜像"
run_cmd "docker pull motricseven7/snowluma:latest" docker pull motricseven7/snowluma:latest

progress 0 "启动 SnowLuma 容器"
run_cmd "docker compose up -d SnowLuma" \
    docker compose up -d

# 等待 SnowLuma 初始化并生成日志
echo -e "${CYAN}等待 SnowLuma 初始化（约 15 秒）...${NC}"
sleep 15

# ---------- 10. 提取 SnowLuma 凭据 ----------
VNC_PASS=""
WEBUI_PASS=""

# 从日志中提取 noVNC 密码
VNC_LOG_LINE=$(docker logs snowluma 2>&1 | grep -iE '远程桌面密码|VNC.*password|password' | tail -n 5 || true)
if echo "$VNC_LOG_LINE" | grep -qiE 'vncpasswd|随机|generated'; then
    VNC_PASS=$(echo "$VNC_LOG_LINE" | grep -oE '[A-Za-z0-9_-]{6,}' | tail -n 1 || true)
fi
# 如果日志中没有提取到，回退到 .env 中的默认值
if [[ -z "$VNC_PASS" ]]; then
    VNC_PASS="vncpasswd"
fi

# 从日志中提取 WebUI 密码
WEBUI_LOG_LINE=$(docker logs snowluma 2>&1 | grep -iE 'WebUI|web ui|admin|密码|password' | tail -n 10 || true)
WEBUI_PASS=$(echo "$WEBUI_LOG_LINE" | grep -oE '[A-Za-z0-9_-]{6,}' | tail -n 1 || true)
if [[ -z "$WEBUI_PASS" ]]; then
    WEBUI_PASS="见容器日志（docker logs snowluma）"
fi

# ---------- 11. 生成管理脚本 ----------
MANAGE_SCRIPT="$DEPLOY_DIR/manage.sh"
cat > "$MANAGE_SCRIPT" <<MANAGEEOF
#!/usr/bin/env bash
set -euo pipefail

ASTRBOT_DIR="$DEPLOY_DIR/astrbot"
SNOWLUMA_DIR="$DEPLOY_DIR/snowluma"
ACCESS_HOST="$ACCESS_HOST"

case "\${1:-}" in
    start)
        echo "启动 AstrBot..."
        docker start astrbot 2>/dev/null || docker run -itd --name astrbot --restart unless-stopped \
            -p 6185:6185 -p 6199:6199 \
            -v "\$ASTRBOT_DIR/data:/AstrBot/data" \
            -v /etc/localtime:/etc/localtime:ro \
            -e TZ=Asia/Shanghai soulter/astrbot:latest
        echo "启动 SnowLuma..."
        cd "\$SNOWLUMA_DIR" && docker compose up -d
        echo ""
        echo "AstrBot WebUI: http://\$ACCESS_HOST:6185"
        echo "SnowLuma WebUI: http://\$ACCESS_HOST:5099"
        echo "SnowLuma noVNC: http://\$ACCESS_HOST:6081"
        ;;
    stop)
        echo "停止 AstrBot..."
        docker stop astrbot 2>/dev/null || true
        echo "停止 SnowLuma..."
        cd "\$SNOWLUMA_DIR" && docker compose down
        echo "已停止。"
        ;;
    restart)
        "\$0" stop
        sleep 2
        "\$0" start
        ;;
    status)
        echo "=== AstrBot ==="
        docker ps -a --filter name=astrbot --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "=== SnowLuma ==="
        docker ps -a --filter name=snowluma --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    *)
        echo "用法：\$0 {start|stop|restart|status}"
        echo ""
        echo "AstrBot WebUI : http://\$ACCESS_HOST:6185"
        echo "SnowLuma WebUI: http://\$ACCESS_HOST:5099"
        echo "SnowLuma noVNC: http://\$ACCESS_HOST:6081"
        ;;
esac
MANAGEEOF
chmod +x "$MANAGE_SCRIPT"
progress 0 "生成管理脚本 $MANAGE_SCRIPT"

# ---------- 12. 完成摘要 ----------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo -e "${CYAN}【AstrBot】${NC}"
echo -e "  WebUI        : http://$ACCESS_HOST:6185"
echo -e "  WebSocket    : ws://$ACCESS_HOST:6199"
echo -e "  数据目录      : $DEPLOY_DIR/astrbot/data"
echo ""
echo -e "${CYAN}【SnowLuma】${NC}"
echo -e "  WebUI        : http://$ACCESS_HOST:5099"
echo -e "  WebUI 账号   : admin"
echo -e "  WebUI 密码   : $WEBUI_PASS"
echo -e "  noVNC        : http://$ACCESS_HOST:6081"
echo -e "  VNC 密码     : $VNC_PASS"
echo -e "  OneBot HTTP  : http://$ACCESS_HOST:3000"
echo -e "  OneBot WS    : ws://$ACCESS_HOST:3001"
echo ""
echo -e "${CYAN}【本地管理脚本】${NC}"
echo -e "  $MANAGE_SCRIPT"
echo -e "  用法：$MANAGE_SCRIPT {start|stop|restart|status}"
echo ""
echo -e "${YELLOW}【提醒】${NC}"
echo -e "  如果使用云服务器，请在安全组 / 防火墙中放行："
echo -e "  6185, 6199, 5099, 6081, 3000, 3001"
echo -e "  完整部署日志：/tmp/astrbot_snowluma_deploy.log"
echo ""
echo -e "${GREEN}============================================================${NC}"