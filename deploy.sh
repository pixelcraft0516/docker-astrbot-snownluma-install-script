#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Ubuntu 全版本通用 · AstrBot + SnowLuma 一键部署脚本
#  包含：Docker CE 安装、AstrBot 容器、SnowLuma 容器
#  自动生成管理脚本 ~/astrbot-snowluma-manage.sh
# ============================================================

# ---------- 颜色与进度条 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_STEPS=8
CURRENT_STEP=0
PROGRESS_BAR_WIDTH=40

progress_bar() {
    local percent=$1
    local filled=$(( percent * PROGRESS_BAR_WIDTH / 100 ))
    local empty=$(( PROGRESS_BAR_WIDTH - filled ))
    local bar
    bar=$(printf "%${filled}s" | tr ' ' '#')$(printf "%${empty}s" | tr ' ' '-')
    printf "\r${CYAN}[%s] %3d%%${NC}" "$bar" "$percent"
}

step() {
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    progress_bar "$percent"
    echo -e "\n${GREEN}>>> [${CURRENT_STEP}/${TOTAL_STEPS}] $1${NC}"
    echo -e "${YELLOW}    $2${NC}"
}

# ---------- 0. 检查 root ----------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}请使用 sudo 或 root 运行此脚本。${NC}"
    exit 1
fi

# ---------- 1. 询问公网访问 ----------
step "公网访问配置" "询问是否需要公网访问"
read -r -p "是否需要通过公网访问 AstrBot / SnowLuma？(y/n，默认 n): " NEED_PUBLIC
NEED_PUBLIC=${NEED_PUBLIC:-n}

ACCESS_HOST="127.0.0.1"

if [[ "$NEED_PUBLIC" =~ ^[Yy]$ ]]; then
    read -r -p "请输入公网 IP（留空则自动获取）: " PUBLIC_IP
    if [[ -z "$PUBLIC_IP" ]]; then
        echo "正在自动获取公网 IP ..."
        PUBLIC_IP=$(curl -s --max-time 10 https://ifconfig.me || curl -s --max-time 10 https://ipinfo.io/ip || true)
        if [[ -z "$PUBLIC_IP" ]]; then
            echo -e "${RED}自动获取公网 IP 失败，将回退到 127.0.0.1${NC}"
            PUBLIC_IP="127.0.0.1"
        fi
    fi
    ACCESS_HOST="$PUBLIC_IP"
    echo -e "${GREEN}将使用公网地址: ${ACCESS_HOST}${NC}"
else
    echo -e "${YELLOW}将使用本地地址: ${ACCESS_HOST}${NC}"
fi

# ---------- 2. 安装 Docker CE ----------
step "安装 Docker CE" "使用官方便捷脚本安装 Docker Engine（不含 Desktop）"
if command -v docker &>/dev/null; then
    echo -e "${YELLOW}Docker 已安装，跳过。${NC}"
else
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl gnupg lsb-release
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable docker
    systemctl start docker
fi

# 将当前用户加入 docker 组（如果非 root 用户执行）
if [[ -n "${SUDO_USER:-}" ]]; then
    usermod -aG docker "$SUDO_USER" || true
fi

# 验证 docker compose
docker compose version &>/dev/null || {
    echo -e "${RED}docker compose 不可用，请检查 Docker 安装。${NC}"
    exit 1
}

# ---------- 3. 创建数据目录 ----------
step "创建数据目录" "创建 AstrBot 与 SnowLuma 的数据持久化目录"
mkdir -p /opt/astrbot/data
mkdir -p /opt/snowluma/data

# ---------- 4. 启动 AstrBot ----------
step "启动 AstrBot 容器" "端口: 6185 (WebUI), 6199 (OneBot v11)"
docker rm -f astrbot 2>/dev/null || true

docker run -itd \
    --name astrbot \
    --restart unless-stopped \
    -p 6185:6185 \
    -p 6199:6199 \
    -v /opt/astrbot/data:/AstrBot/data \
    -v /etc/localtime:/etc/localtime:ro \
    -v /etc/timezone:/etc/timezone:ro \
    soulter/astrbot:latest

echo -e "${GREEN}AstrBot 容器已启动。${NC}"

# ---------- 5. 启动 SnowLuma ----------
step "启动 SnowLuma 容器" "端口: 5099 (WebUI), 6081 (noVNC), 3000/3001 (OneBot)"

SNOWLUMA_VNC_PASSWD=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12)
echo -e "${YELLOW}SnowLuma VNC 密码已自动生成: ${SNOWLUMA_VNC_PASSWD}${NC}"

docker rm -f snowluma 2>/dev/null || true

docker run -itd \
    --name snowluma \
    --restart unless-stopped \
    --shm-size=1gb \
    --cap-add=SYS_PTRACE \
    --security-opt seccomp=unconfined \
    -p 5099:5099 \
    -p 6081:6081 \
    -p 3000:3000 \
    -p 3001:3001 \
    -e SNOWLUMA_ACCEPT_EULA=1 \
    -e SNOWLUMA_ACCEPT_PRIVACY=1 \
    -e VNC_PASSWD="${SNOWLUMA_VNC_PASSWD}" \
    -e TZ=Asia/Shanghai \
    -v /opt/snowluma/data:/app/snowluma-data \
    motricseven7/snowluma:latest

echo -e "${GREEN}SnowLuma 容器已启动。${NC}"

# ---------- 6. 等待并提取密码 ----------
step "等待服务启动并提取密码" "从容器日志中提取 AstrBot WebUI 密码与 SnowLuma WebUI 密码"

echo "等待 AstrBot 生成初始密码 ..."
ASTRBOT_PASSWORD=""
for i in $(seq 1 30); do
    LOG=$(docker logs astrbot 2>&1 || true)
    if echo "$LOG" | grep -qi "password"; then
        ASTRBOT_PASSWORD=$(echo "$LOG" | grep -iE 'password|密码' | grep -oE '[A-Za-z0-9]{8,}' | tail -n 1 || true)
        if [[ -n "$ASTRBOT_PASSWORD" ]]; then break; fi
    fi
    sleep 2
done

if [[ -z "$ASTRBOT_PASSWORD" ]]; then
    ASTRBOT_PASSWORD="(请手动执行 docker logs astrbot 查看初始密码)"
fi

echo "等待 SnowLuma WebUI 生成初始密码 ..."
SNOWLUMA_WEBUI_PASSWORD=""
for i in $(seq 1 30); do
    LOG=$(docker logs snowluma 2>&1 || true)
    if echo "$LOG" | grep -qiE 'password|临时密码|initial credentials'; then
        SNOWLUMA_WEBUI_PASSWORD=$(echo "$LOG" | sed -nE 's/.*(临时密码: |initial credentials: user=admin password=)([^[:space:]]+).*/\2/p' | tail -n 1 || true)
        if [[ -n "$SNOWLUMA_WEBUI_PASSWORD" ]]; then break; fi
    fi
    sleep 2
done

if [[ -z "$SNOWLUMA_WEBUI_PASSWORD" ]]; then
    SNOWLUMA_WEBUI_PASSWORD="(请手动执行 docker logs snowluma 查看初始密码)"
fi

# ---------- 7. 打印全部配置信息 ----------
step "部署完成 · 配置信息" "以下地址与账号密码请妥善保存"

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${GREEN}              部署完成！${NC}"
echo -e "${CYAN}============================================================${NC}"

echo -e "\n${YELLOW}【AstrBot】${NC}"
echo -e "  WebUI 地址 : ${GREEN}http://${ACCESS_HOST}:6185${NC}"
echo -e "  WebUI 账号 : ${GREEN}astrbot${NC}"
echo -e "  WebUI 密码 : ${GREEN}${ASTRBOT_PASSWORD}${NC}"
echo -e "  OneBot v11 : ${ACCESS_HOST}:6199"

echo -e "\n${YELLOW}【SnowLuma】${NC}"
echo -e "  WebUI 地址 : ${GREEN}http://${ACCESS_HOST}:5099${NC}"
echo -e "  WebUI 账号 : ${GREEN}admin${NC}"
echo -e "  WebUI 密码 : ${GREEN}${SNOWLUMA_WEBUI_PASSWORD}${NC}"
echo -e "  noVNC 地址 : ${GREEN}http://${ACCESS_HOST}:6081${NC}"
echo -e "  noVNC 密码 : ${GREEN}${SNOWLUMA_VNC_PASSWD}${NC}"
echo -e "  OneBot HTTP: ${ACCESS_HOST}:3000"
echo -e "  OneBot WS  : ${ACCESS_HOST}:3001"

echo -e "\n${CYAN}============================================================${NC}"
echo -e "${YELLOW}提示: 若使用公网访问，请确保防火墙 / 安全组已放行以下端口：${NC}"
echo -e "  6185, 6199, 5099, 6081, 3000, 3001"
echo -e "${CYAN}============================================================${NC}\n"

# ---------- 8. 生成本地管理脚本 ----------
step "生成本地管理脚本" "创建 ~/astrbot-snowluma-manage.sh"

MANAGE_SCRIPT="$HOME/astrbot-snowluma-manage.sh"

cat > "$MANAGE_SCRIPT" <<'MANAGE_EOF'
#!/usr/bin/env bash
# AstrBot + SnowLuma 本地管理脚本
# 用法: ./astrbot-snowluma-manage.sh {start|stop|restart|status|info}

set -euo pipefail

ACCESS_HOST_PLACEHOLDER="{{ACCESS_HOST}}"

case "${1:-}" in
    start)
        echo "启动 AstrBot ..."
        docker start astrbot 2>/dev/null || echo "AstrBot 容器不存在，请先运行部署脚本。"
        echo "启动 SnowLuma ..."
        docker start snowluma 2>/dev/null || echo "SnowLuma 容器不存在，请先运行部署脚本。"
        echo "已启动。"
        ;;
    stop)
        echo "停止 AstrBot ..."
        docker stop astrbot 2>/dev/null || true
        echo "停止 SnowLuma ..."
        docker stop snowluma 2>/dev/null || true
        echo "已停止。"
        ;;
    restart)
        "$0" stop
        sleep 1
        "$0" start
        ;;
    status)
        echo "===== 容器状态 ====="
        docker ps -a --filter "name=astrbot" --filter "name=snowluma" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    info)
        echo ""
        echo "===== 访问地址 ====="
        echo "AstrBot WebUI : http://${ACCESS_HOST_PLACEHOLDER}:6185"
        echo "SnowLuma WebUI: http://${ACCESS_HOST_PLACEHOLDER}:5099"
        echo "SnowLuma noVNC: http://${ACCESS_HOST_PLACEHOLDER}:6081"
        echo ""
        echo "账号密码请查看部署时的输出，或执行："
        echo "  docker logs astrbot 2>&1 | grep -i password"
        echo "  docker logs snowluma 2>&1 | grep -iE 'password|临时密码'"
        echo ""
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status|info}"
        exit 1
        ;;
esac
MANAGE_EOF

# 替换占位符
sed -i "s|{{ACCESS_HOST}}|${ACCESS_HOST}|g" "$MANAGE_SCRIPT"
chmod +x "$MANAGE_SCRIPT"

echo -e "${GREEN}管理脚本已生成: ${MANAGE_SCRIPT}${NC}"
echo -e "${YELLOW}用法: ${MANAGE_SCRIPT} {start|stop|restart|status|info}${NC}"

progress_bar 100
echo -e "\n${GREEN}全部完成！${NC}"