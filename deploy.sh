#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# AstrBot + SnowLuma 一键部署脚本 (Ubuntu 20.04+)
# 严格参照官方文档:
#   AstrBot:  https://docs.astrbot.app/deploy/astrbot/docker.html
#   SnowLuma: https://github.com/SnowLuma/SnowLuma.Docker.Framework
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${NC}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_err()   { echo -e "${RED}[ERR ]${NC}  $*" >&2; }

# ---------- 进度条 ----------
TOTAL_STEPS=10
CURRENT_STEP=0
CURRENT_CMD=""

draw_progress() {
    local step="$1"
    local cmd="$2"
    local pct=$(( step * 100 / TOTAL_STEPS ))
    local filled=$(( pct / 2 ))
    local empty=$(( 50 - filled ))
    printf "\r${CYAN}[%-50s] %3d%%${NC}" \
        "$(printf '#%.0s' $(seq 1 $filled))$(printf ' %.0s' $(seq 1 $empty))" "$pct"
    printf "\n${BOLD}>>> ${cmd}${NC}\n"
    CURRENT_STEP="$step"
    CURRENT_CMD="$cmd"
}

run_step() {
    local desc="$1"; shift
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    draw_progress "$CURRENT_STEP" "$desc"
    "$@"
}

# ---------- 环境检查 ----------
check_env() {
    if [[ $EUID -eq 0 ]]; then
        log_err "请不要直接使用 root 运行此脚本，使用 sudo 或普通用户执行。"
        exit 1
    fi
    if ! command -v lsb_release &>/dev/null; then
        log_err "缺少 lsb_release，无法识别 Ubuntu 版本。"
        exit 1
    fi
    local ver
    ver=$(lsb_release -rs)
    if [[ "$(echo "$ver >= 20.04" | bc 2>/dev/null)" != "1" ]] && [[ "$ver" < "20.04" ]]; then
        log_err "需要 Ubuntu 20.04 或更高版本，当前版本: $ver"
        exit 1
    fi
    log_ok "系统检查通过: Ubuntu $ver"
}

# ---------- 公网访问询问 ----------
ask_public_access() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  是否需要公网远程访问？${NC}"
    echo -e "${BOLD}========================================${NC}"
    read -r -p "请输入 y/n (默认 n): " PUBLIC_ACCESS
    PUBLIC_ACCESS=${PUBLIC_ACCESS:-n}
    PUBLIC_ACCESS=${PUBLIC_ACCESS,,}

    if [[ "$PUBLIC_ACCESS" == "y" ]]; then
        echo ""
        read -r -p "请输入公网 IP (留空自动获取公网地址): " PUBLIC_IP
        if [[ -z "$PUBLIC_IP" ]]; then
            log_info "正在获取公网 IP..."
            PUBLIC_IP=$(curl -s --max-time 10 ifconfig.me || curl -s --max-time 10 https://api.ipify.org || true)
            if [[ -z "$PUBLIC_IP" ]]; then
                log_warn "公网 IP 获取失败，将使用 localhost。"
                PUBLIC_IP="localhost"
            fi
        fi
        log_ok "公网访问地址将使用: $PUBLIC_IP"
        BIND_IP="0.0.0.0"
    else
        PUBLIC_IP="localhost"
        BIND_IP="127.0.0.1"
        log_info "将仅绑定本机 127.0.0.1，不对外暴露端口。"
    fi
}

# ---------- 安装 Docker CE (不安装 Desktop) ----------
install_docker() {
    log_info "安装 Docker CE (Ubuntu 20.04+ 适配)..."

    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    sudo install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    local arch
    arch=$(dpkg --print-architecture)
    local codename
    codename=$(lsb_release -cs)
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${codename} stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update -qq
    sudo apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin

    sudo systemctl enable --now docker
    if ! getent group docker >/dev/null; then
        sudo groupadd docker
    fi
    sudo usermod -aG docker "$USER" || true

    log_ok "Docker 安装完成: $(docker --version)"
}

# ---------- 部署 AstrBot ----------
deploy_astrbot() {
    log_info "部署 AstrBot (官方 Docker 方式)..."

    local astrbot_dir="$HOME/astrbot-stack/astrbot"
    mkdir -p "$astrbot_dir/data"

    cat > "$astrbot_dir/docker-compose.yml" <<EOF
services:
  astrbot:
    image: soulter/astrbot:latest
    container_name: astrbot
    restart: unless-stopped
    ports:
      - "${BIND_IP}:6185:6185"
      - "${BIND_IP}:6199:6199"
    volumes:
      - ./data:/AstrBot/data
      - /etc/localtime:/etc/localtime:ro
      - /etc/timezone:/etc/timezone:ro
EOF

    cd "$astrbot_dir"
    sudo docker compose pull
    sudo docker compose up -d
    log_ok "AstrBot 启动完成"
}

# ---------- 部署 SnowLuma ----------
deploy_snowluma() {
    log_info "部署 SnowLuma (官方 Docker Framework)..."

    local snowluma_dir="$HOME/astrbot-stack/snowluma"
    mkdir -p "$snowluma_dir"

    cat > "$snowluma_dir/docker-compose.yml" <<EOF
services:
  snowluma:
    image: motricseven7/snowluma:latest
    container_name: snowluma
    restart: unless-stopped
    shm_size: 1gb
    cap_add:
      - SYS_PTRACE
    security_opt:
      - seccomp=unconfined
    environment:
      VNC_PASSWD: "vncpasswd"
      SNOWLUMA_UID: "1000"
      SNOWLUMA_GID: "1000"
      SNOWLUMA_WEBUI_PORT: "5099"
      SNOWLUMA_LOG_LEVEL: "info"
      SNOWLUMA_SCREEN: "1920x1080x24"
      SNOWLUMA_HOOK_AUTOLOAD: "1"
      SNOWLUMA_QQ_FLAGS: "--disable-gpu --disable-software-rasterizer --disable-gpu-compositing"
    ports:
      - "${BIND_IP}:6081:6081"
      - "${BIND_IP}:5099:5099"
      - "${BIND_IP}:3000:3000"
      - "${BIND_IP}:3001:3001"
    volumes:
      - snowluma-data:/app/snowluma-data
      - snowluma-qq-config:/app/.config
      - snowluma-qq-data:/app/.local/share

volumes:
  snowluma-data:
  snowluma-qq-config:
  snowluma-qq-data:
EOF

    cd "$snowluma_dir"
    sudo docker compose pull
    sudo docker compose up -d
    log_ok "SnowLuma 启动完成"
}

# ---------- 收集并打印配置信息 ----------
collect_and_print_info() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  部署配置信息 (全部自动默认)${NC}"
    echo -e "${BOLD}========================================${NC}"

    local astrbot_url="http://${PUBLIC_IP}:6185"
    local snowluma_webui_url="http://${PUBLIC_IP}:5099"
    local snowluma_novnc_url="http://${PUBLIC_IP}:6081"

    echo -e "${GREEN}AstrBot WebUI${NC}       : ${astrbot_url}"
    echo -e "${GREEN}AstrBot OneBot WS${NC}   : ws://${PUBLIC_IP}:6199/ws"
    echo ""
    echo -e "${GREEN}SnowLuma WebUI${NC}      : ${snowluma_webui_url}"
    echo -e "${GREEN}SnowLuma noVNC${NC}      : ${snowluma_novnc_url}"
    echo -e "${GREEN}SnowLuma OneBot HTTP${NC}: http://${PUBLIC_IP}:3000"
    echo -e "${GREEN}SnowLuma OneBot WS${NC}  : ws://${PUBLIC_IP}:3001"
    echo ""

    # 等待日志输出并提取密码
    log_info "正在从容器日志中提取首次登录密码 (最多等待 30 秒)..."
    sleep 5

    local astrbot_log astrbot_pwd
    astrbot_log=$(sudo docker logs astrbot 2>&1 || true)
    astrbot_pwd=$(echo "$astrbot_log" | grep -oP '密码[：:]\s*\K\S+' | head -1 || true)
    if [[ -z "$astrbot_pwd" ]]; then
        astrbot_pwd=$(echo "$astrbot_log" | grep -oP 'password[：:]\s*\K\S+' | head -1 || true)
    fi
    if [[ -n "$astrbot_pwd" ]]; then
        echo -e "${YELLOW}AstrBot 首次登录密码: ${astrbot_pwd}${NC} (用户名: astrbot)"
    else
        log_warn "未能自动提取 AstrBot 密码，请手动查看: sudo docker logs astrbot"
    fi

    local snowluma_log snowluma_pwd vnc_pwd
    snowluma_log=$(sudo docker logs snowluma 2>&1 || true)
    snowluma_pwd=$(echo "$snowluma_log" | grep -oP 'password[：:]\s*\K\S+' | head -1 || true)
    vnc_pwd=$(echo "$snowluma_log" | grep -oP 'VNC[ ]*password[：:]\s*\K\S+' | head -1 || true)
    if [[ -n "$snowluma_pwd" ]]; then
        echo -e "${YELLOW}SnowLuma WebUI 初始密码: ${snowluma_pwd}${NC} (用户名: admin)"
    else
        log_warn "未能自动提取 SnowLuma WebUI 密码，请手动查看: sudo docker logs snowluma"
    fi
    if [[ -n "$vnc_pwd" ]]; then
        echo -e "${YELLOW}SnowLuma noVNC 密码: ${vnc_pwd}${NC}"
    else
        log_warn "未能自动提取 noVNC 密码，请手动查看: sudo docker logs snowluma"
    fi

    # 保存到文件
    local info_file="$HOME/astrbot-stack/DEPLOY_INFO.txt"
    {
        echo "AstrBot WebUI       : $astrbot_url"
        echo "AstrBot 用户名/密码 : astrbot / ${astrbot_pwd:-见日志}"
        echo "SnowLuma WebUI      : $snowluma_webui_url"
        echo "SnowLuma noVNC      : $snowluma_novnc_url"
        echo "SnowLuma 用户名     : admin"
        echo "SnowLuma 密码       : ${snowluma_pwd:-见日志}"
        echo "noVNC 密码          : ${vnc_pwd:-见日志}"
        echo "OneBot 反向 WS 地址 : ws://astrbot:6199/ws (容器内部通信)"
    } > "$info_file"
    log_ok "配置信息已保存至: $info_file"
}

# ---------- 生成本地管理脚本 ----------
generate_manager_script() {
    log_info "生成本地管理脚本: $HOME/astrbot-stack/manage.sh"

    local manager="$HOME/astrbot-stack/manage.sh"
    cat > "$manager" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ASTRBOT_DIR="$STACK_DIR/astrbot"
SNOWLUMA_DIR="$STACK_DIR/snowluma"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

usage() {
    echo "用法: $0 {start|stop|restart|status|logs|info}"
    echo ""
    echo "  start   启动 AstrBot 和 SnowLuma"
    echo "  stop    停止 AstrBot 和 SnowLuma"
    echo "  restart 重启 AstrBot 和 SnowLuma"
    echo "  status  查看容器状态"
    echo "  logs    查看日志 (可指定 astrbot 或 snowluma)"
    echo "  info    显示访问地址 (不显示密码)"
    exit 0
}

require_dir() {
    [[ -d "$1" ]] || { echo -e "${RED}目录不存在: $1${NC}" >&2; exit 1; }
}

do_start() {
    require_dir "$ASTRBOT_DIR"; require_dir "$SNOWLUMA_DIR"
    echo -e "${CYAN}启动 AstrBot...${NC}"
    (cd "$ASTRBOT_DIR" && sudo docker compose start)
    echo -e "${CYAN}启动 SnowLuma...${NC}"
    (cd "$SNOWLUMA_DIR" && sudo docker compose start)
    do_info
}

do_stop() {
    require_dir "$ASTRBOT_DIR"; require_dir "$SNOWLUMA_DIR"
    echo -e "${CYAN}停止 SnowLuma...${NC}"
    (cd "$SNOWLUMA_DIR" && sudo docker compose stop) || true
    echo -e "${CYAN}停止 AstrBot...${NC}"
    (cd "$ASTRBOT_DIR" && sudo docker compose stop) || true
    echo -e "${GREEN}已停止。${NC}"
}

do_restart() {
    do_stop
    sleep 1
    do_start
}

do_status() {
    echo -e "${BOLD}AstrBot:${NC}"
    sudo docker ps -a --filter name=^/astrbot$ --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
    echo ""
    echo -e "${BOLD}SnowLuma:${NC}"
    sudo docker ps -a --filter name=^/snowluma$ --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" || true
}

do_logs() {
    local target="${1:-}"
    case "$target" in
        astrbot)  sudo docker logs -f --tail=100 astrbot ;;
        snowluma) sudo docker logs -f --tail=100 snowluma ;;
        *)        echo "请指定 astrbot 或 snowluma"; exit 1 ;;
    esac
}

do_info() {
    local info_file="$STACK_DIR/DEPLOY_INFO.txt"
    if [[ -f "$info_file" ]]; then
        echo -e "${BOLD}=== 访问地址 (密码请查看 DEPLOY_INFO.txt 或容器日志) ===${NC}"
        grep -E 'WebUI|noVNC|OneBot' "$info_file" | grep -v '密码' || true
    else
        echo -e "${YELLOW}DEPLOY_INFO.txt 不存在，请查看容器日志获取地址和密码。${NC}"
    fi
}

case "${1:-}" in
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    status)  do_status ;;
    logs)    do_logs "${2:-}" ;;
    info)    do_info ;;
    *)       usage ;;
esac
MANAGER_EOF

    chmod +x "$manager"
    log_ok "管理脚本已生成: $manager"
    echo ""
    echo -e "${BOLD}使用方法:${NC}"
    echo "  $manager start    # 启动"
    echo "  $manager stop     # 停止"
    echo "  $manager restart  # 重启"
    echo "  $manager status   # 状态"
    echo "  $manager info     # 查看访问地址 (不显示密码)"
}

# ================= 主流程 =================
main() {
    echo ""
    echo -e "${BOLD}========================================${NC}"
    echo -e "${BOLD}  AstrBot + SnowLuma 一键部署${NC}"
    echo -e "${BOLD}  Ubuntu 20.04+ 通用脚本${NC}"
    echo -e "${BOLD}========================================${NC}"
    echo ""

    check_env
    ask_public_access

    # 步骤进度 (总计 10 步，这里合并一些计数)
    run_step "更新软件包列表" sudo apt-get update -qq
    run_step "安装基础依赖"   sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

    run_step "安装 Docker CE" install_docker
    run_step "部署 AstrBot"    deploy_astrbot
    run_step "部署 SnowLuma"   deploy_snowluma

    run_step "收集配置信息" collect_and_print_info
    run_step "生成管理脚本" generate_manager_script

    echo ""
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo -e "${GREEN}${BOLD}  部署完成！${NC}"
    echo -e "${GREEN}${BOLD}========================================${NC}"
    echo ""
}

main "$@"