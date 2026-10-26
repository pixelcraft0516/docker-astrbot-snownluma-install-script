#!/usr/bin/env bash
# =============================================================================
# Ubuntu 全版本通用：AstrBot + SnowLuma 一键 Docker 部署脚本
# 包含：依赖安装、Docker 安装、交互式公网配置、进度条+命令回显、管理脚本生成
# =============================================================================

set -uo pipefail

# ---------- 全局配置 ----------
INSTALL_DIR="/opt/astrbot-snowluma"
COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
MANAGE_SCRIPT="${INSTALL_DIR}/manage.sh"
LOG_DIR="${INSTALL_DIR}/logs"
TOTAL_STEPS=12
CURRENT_STEP=0
PUBLIC_ACCESS=false
PUBLIC_IP=""

# ---------- 颜色 ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ---------- 工具函数 ----------
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }

# ---------- 进度条 + 命令回显 ----------
print_progress() {
  local step="$1" desc="$2" cmd="$3"
  local pct=$(( step * 100 / TOTAL_STEPS ))
  local filled=$(( pct / 4 ))
  local empty=$(( 25 - filled ))
  local bar
  bar="$(printf '%0.s█' $(seq 1 "$filled"))$(printf '%0.s░' $(seq 1 "$empty"))"
  printf '\r%s[%s]%s %3d%%  步骤: %s' "${CYAN}" "${bar}" "${NC}" "$pct" "$desc"
  printf '\n%s  执行: %s%s\n' "${YELLOW}" "$cmd" "${NC}"
}

# 在后台执行命令并显示旋转指示器，保持进度条区域“活着”
run_with_spinner() {
  local desc="$1" cmd="$2"
  local logfile="${LOG_DIR}/$(echo "$desc" | tr ' ' '_').log"
  eval "$cmd" >"$logfile" 2>&1 &
  local pid=$!
  local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$(( (i + 1) % 10 ))
    printf '\r%s  正在执行... %s%s   ' "${YELLOW}" "${spin:$i:1}" "${NC}"
    sleep 0.1
  done
  wait "$pid"
  local rc=$?
  printf '\r\033[K' # 清除旋转行
  if [ $rc -ne 0 ]; then
    fail "步骤失败：${desc}。查看日志：${logfile}"
  fi
  return 0
}

# 统一执行一个步骤：更新进度 → 回显命令 → 执行
step() {
  CURRENT_STEP=$(( CURRENT_STEP + 1 ))
  local desc="$1" cmd="$2"
  print_progress "$CURRENT_STEP" "$desc" "$cmd"
  run_with_spinner "$desc" "$cmd"
  ok "$desc 完成"
}

# ---------- 0. 交互式公网询问 ----------
echo -e "${CYAN}===========================================================${NC}"
echo -e "${CYAN}  AstrBot + SnowLuma Docker 部署向导${NC}"
echo -e "${CYAN}===========================================================${NC}"
read -r -p "是否启用公网远程访问？(y/N): " pub_choice
if [[ "$pub_choice" =~ ^[Yy]$ ]]; then
  PUBLIC_ACCESS=true
  read -r -p "请输入公网 IP（留空自动检测）: " PUBLIC_IP
  if [ -z "$PUBLIC_IP" ]; then
    info "正在检测公网 IP ..."
    PUBLIC_IP=$(curl -fsSL --connect-timeout 5 https://ifconfig.me 2>/dev/null || curl -fsSL --connect-timeout 5 https://api.ipify.org 2>/dev/null || true)
    if [ -z "$PUBLIC_IP" ]; then
      warn "自动检测失败，将使用 0.0.0.0 绑定地址；后续请用实际公网 IP 访问。"
      PUBLIC_IP="0.0.0.0"
    fi
  fi
  ok "公网访问已启用，公网 IP：${PUBLIC_IP}"
else
  PUBLIC_ACCESS=false
  info "仅本地访问模式，相关端口将绑定到 127.0.0.1。"
fi

# ---------- 1. 基础依赖 ----------
step "更新软件包索引" "apt-get update -y"
step "安装基础依赖" "apt-get install -y curl ca-certificates gnupg lsb-release jq"

# ---------- 2. 安装 Docker（全版本兼容策略） ----------
DOCKER_INSTALLED=false
if command -v docker &>/dev/null; then
  ok "检测到 Docker 已安装，跳过。"
  DOCKER_INSTALLED=true
else
  # 首选 get.docker.com
  if curl -fsSL https://get.docker.com -o /tmp/get-docker.sh 2>/dev/null; then
    step "安装 Docker（官方脚本）" "sh /tmp/get-docker.sh"
    DOCKER_INSTALLED=true
  else
    warn "get.docker.com 不可达，尝试系统包管理器（适用于 Ubuntu 20.04 等 EOL 版本）..."
    step "安装 Docker（apt docker.io）" "apt-get install -y docker.io docker-compose"
    DOCKER_INSTALLED=true
  fi
fi

if [ "$DOCKER_INSTALLED" = false ]; then
  fail "Docker 安装失败，请手动检查网络后重试。"
fi

# 启动并启用 Docker
systemctl enable --now docker &>/dev/null || true

# 检测 compose 命令
if docker compose version &>/dev/null; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose &>/dev/null; then
  COMPOSE_CMD="docker-compose"
else
  step "安装 Docker Compose 插件" "apt-get install -y docker-compose-plugin"
  COMPOSE_CMD="docker compose"
fi
ok "Compose 命令：${COMPOSE_CMD}"

# ---------- 3. 创建目录 ----------
step "创建安装目录与日志目录" "mkdir -p ${INSTALL_DIR} ${LOG_DIR}"

# ---------- 4. 生成 docker-compose.yml ----------
# 根据公网访问决定绑定地址
BIND_ASTRBOT_WEBUI="127.0.0.1:6185:6185"
BIND_ASTRBOT_ONEBOT="127.0.0.1:6199:6199"
BIND_SNOWLUMA_NOVNC="127.0.0.1:6081:6081"
BIND_SNOWLUMA_WEBUI="127.0.0.1:5099:5099"
BIND_SNOWLUMA_HTTP="127.0.0.1:3000:3000"
BIND_SNOWLUMA_WS="127.0.0.1:3001:3001"

if [ "$PUBLIC_ACCESS" = true ]; then
  BIND_ASTRBOT_WEBUI="0.0.0.0:6185:6185"
  BIND_ASTRBOT_ONEBOT="0.0.0.0:6199:6199"
  BIND_SNOWLUMA_NOVNC="0.0.0.0:6081:6081"
  BIND_SNOWLUMA_WEBUI="0.0.0.0:5099:5099"
  BIND_SNOWLUMA_HTTP="0.0.0.0:3000:3000"
  BIND_SNOWLUMA_WS="0.0.0.0:3001:3001"
fi

cat > "${COMPOSE_FILE}" <<EOF
services:
  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: unless-stopped
    environment:
      - TZ=Asia/Shanghai
    ports:
      - "${BIND_ASTRBOT_WEBUI}"      # AstrBot WebUI
      - "${BIND_ASTRBOT_ONEBOT}"     # OneBot v11 WebSocket（可选）
    volumes:
      - ./astrbot-data:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro

  snowluma:
    image: motricseven7/snowluma:latest
    container_name: snowluma
    restart: unless-stopped
    shm_size: "1g"
    ulimits:
      nofile:
        soft: 65536
        hard: 1048576
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    environment:
      - SNOWLUMA_WEBUI_HOST=0.0.0.0
      - SNOWLUMA_WEBUI_PORT=5099
      - SNOWLUMA_QQ_FLAGS=--disable-gpu --disable-software-rasterizer --disable-gpu-compositing
      - TZ=Asia/Shanghai
    ports:
      - "${BIND_SNOWLUMA_NOVNC}"     # noVNC 浏览器远程桌面
      - "${BIND_SNOWLUMA_WEBUI}"     # SnowLuma WebUI
      - "${BIND_SNOWLUMA_HTTP}"      # OneBot HTTP
      - "${BIND_SNOWLUMA_WS}"        # OneBot WebSocket
    volumes:
      - snowluma-gateway-data:/app/data
      - snowluma-client-config:/app/.config
      - snowluma-client-data:/app/.local/share

volumes:
  snowluma-gateway-data:
    name: qq-gateway-data
  snowluma-client-config:
    name: qq-client-config
  snowluma-client-data:
    name: qq-client-data
EOF

step "生成 docker-compose.yml" "cat > ${COMPOSE_FILE}"

# ---------- 5. 启动容器 ----------
cd "${INSTALL_DIR}"
step "拉取镜像（AstrBot）" "${COMPOSE_CMD} pull astrbot"
step "拉取镜像（SnowLuma）" "${COMPOSE_CMD} pull snowluma"
step "启动所有容器" "${COMPOSE_CMD} up -d"

# ---------- 6. 等待容器就绪并提取凭据 ----------
info "等待容器初始化（约 15 秒）..."
sleep 15

ASTRBOT_PASSWORD=$(docker logs astrbot 2>&1 | grep -Eio 'Initial password:[[:space:]]*[^[:space:]]+' | tail -n1 | sed 's/Initial password:[[:space:]]*//I' || true)
SNOWLUMA_WEBUI_PASSWORD=$(docker logs snowluma 2>&1 | sed -nE 's/.*(临时密码: |initial credentials: user=admin password=)([^[:space:]]+).*/\2/p' | tail -n1 || true)
SNOWLUMA_NOVNC_PASSWORD=$(docker logs snowluma 2>&1 | grep -Eio '(远程桌面密码:|remote desktop password:)[[:space:]]*[^[:space:]]+' | tail -n1 | sed -E 's/.*(密码:|password:)[[:space:]]*//I' || true)

# ---------- 7. 生成管理脚本 manage.sh ----------
cat > "${MANAGE_SCRIPT}" <<'MANAGE_EOF'
#!/usr/bin/env bash
# AstrBot + SnowLuma 管理脚本
set -uo pipefail
INSTALL_DIR="/opt/astrbot-snowluma"
cd "$INSTALL_DIR" || exit 1

COMPOSE_CMD="docker compose"
command -v docker compose &>/dev/null || COMPOSE_CMD="docker-compose"

case "${1:-}" in
  start)      $COMPOSE_CMD up -d ;;
  stop)       $COMPOSE_CMD down ;;
  restart)    $COMPOSE_CMD restart ;;
  status)     $COMPOSE_CMD ps ;;
  logs)       $COMPOSE_CMD logs --tail=100 -f ;;
  url)
    echo "AstrBot WebUI: http://<IP>:6185"
    echo "SnowLuma WebUI: http://<IP>:5099"
    echo "SnowLuma noVNC: http://<IP>:6081"
    echo "（将 <IP> 替换为服务器实际 IP）"
    ;;
  credentials)
    echo "=== AstrBot WebUI 凭据 ==="
    echo "用户名: astrbot"
    p=$(docker logs astrbot 2>&1 | grep -Eio 'Initial password:[[:space:]]*[^[:space:]]+' | tail -n1 | sed 's/Initial password:[[:space:]]*//I' || true)
    echo "密码: ${p:-未找到，请手动执行 docker logs astrbot 查看}"
    echo ""
    echo "=== SnowLuma WebUI 凭据 ==="
    echo "用户名: admin"
    p=$(docker logs snowluma 2>&1 | sed -nE 's/.*(临时密码: |initial credentials: user=admin password=)([^[:space:]]+).*/\2/p' | tail -n1 || true)
    echo "密码: ${p:-未找到，请手动执行 docker logs snowluma 查看}"
    echo ""
    echo "=== SnowLuma noVNC 密码 ==="
    p=$(docker logs snowluma 2>&1 | grep -Eio '(远程桌面密码:|remote desktop password:)[[:space:]]*[^[:space:]]+' | tail -n1 | sed -E 's/.*(密码:|password:)[[:space:]]*//I' || true)
    echo "密码: ${p:-未找到，请手动执行 docker logs snowluma 查看}"
    ;;
  *)
    echo "用法: $0 {start|stop|restart|status|logs|url|credentials}"
    exit 1
    ;;
esac
MANAGE_EOF
chmod +x "${MANAGE_SCRIPT}"
ok "管理脚本已生成：${MANAGE_SCRIPT}"

# ---------- 8. 最终输出 ----------
# 确定用于显示的 IP
DISPLAY_IP="${PUBLIC_IP}"
if [ "$PUBLIC_ACCESS" = false ]; then
  DISPLAY_IP="127.0.0.1"
fi
if [ "$DISPLAY_IP" = "0.0.0.0" ]; then
  DISPLAY_IP="<你的公网IP>"
fi

echo ""
echo -e "${GREEN}===========================================================${NC}"
echo -e "${GREEN}  部署完成！${NC}"
echo -e "${GREEN}===========================================================${NC}"
echo ""
echo -e "${CYAN}【AstrBot】${NC}"
echo "  WebUI:   http://${DISPLAY_IP}:6185"
echo "  用户名:  astrbot"
echo "  初始密码: ${ASTRBOT_PASSWORD:-未能自动提取，请执行：docker logs astrbot | grep -i 'Initial password'}"
echo ""
echo -e "${CYAN}【SnowLuma】${NC}"
echo "  WebUI:   http://${DISPLAY_IP}:5099"
echo "  noVNC:   http://${DISPLAY_IP}:6081"
echo "  WebUI 用户名: admin"
echo "  WebUI 密码:   ${SNOWLUMA_WEBUI_PASSWORD:-未能自动提取，请执行：docker logs snowluma 2>&1 | grep -E '临时密码|initial credentials'}"
echo "  noVNC 密码:   ${SNOWLUMA_NOVNC_PASSWORD:-未能自动提取，请执行：docker logs snowluma 2>&1 | grep -E '远程桌面密码|remote desktop password'}"
echo ""
echo -e "${YELLOW}-----------------------------------------------------------${NC}"
echo "  管理脚本: ${MANAGE_SCRIPT}"
echo "  常用命令:"
echo "    bash ${MANAGE_SCRIPT} start        # 启动"
echo "    bash ${MANAGE_SCRIPT} stop         # 停止"
echo "    bash ${MANAGE_SCRIPT} restart      # 重启"
echo "    bash ${MANAGE_SCRIPT} status       # 状态"
echo "    bash ${MANAGE_SCRIPT} url          # 仅显示访问地址"
echo "    bash ${MANAGE_SCRIPT} credentials  # 查询账号密码"
echo -e "${YELLOW}-----------------------------------------------------------${NC}"
echo "  安全提醒：若已启用公网访问，请确保云厂商安全组/防火墙放行"
echo "  6185、6199、6081、5099、3000、3001 端口，并尽快修改初始密码。"
echo -e "${GREEN}===========================================================${NC}"