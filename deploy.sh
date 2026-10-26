#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Ubuntu 全版本通用 AstrBot + SnowLuma Docker 部署脚本
# 官方依据：
#   AstrBot Docker 部署: https://docs.astrbot.app/deploy/astrbot/docker.html
#   SnowLuma Docker 框架: https://github.com/SnowLuma/SnowLuma.Docker.Framework
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

TOTAL_STEPS=12
CURRENT_STEP=0
PUBLIC_IP=""
USE_PUBLIC=false

# ---------- 进度条与命令显示 ----------
draw_progress() {
    local label="$1"
    local percent=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
    local filled=$(( CURRENT_STEP * 30 / TOTAL_STEPS ))
    local empty=$(( 30 - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    printf "\r${CYAN}进度${NC} [${GREEN}%s${NC}] ${YELLOW}%3d%%${NC}  %-40s" "$bar" "$percent" "$label"
}

run_step() {
    local label="$1"
    local cmd="$2"
    CURRENT_STEP=$(( CURRENT_STEP + 1 ))
    draw_progress "$label"
    # 在进度条下方单行显示即将执行的命令（先回车换行，再回到上一行重绘进度条位置）
    printf "\n${CYAN}执行:${NC} %s\n" "$cmd"
    # 将光标移回进度条所在行，便于下一轮覆盖
    printf "\033[1A"
    if ! eval "$cmd"; then
        printf "\n${RED}命令失败: %s${NC}\n" "$cmd"
        exit 1
    fi
    printf "\n"
}

# ---------- 1. 询问公网访问 ----------
ask_public_access() {
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  AstrBot + SnowLuma 部署向导${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    read -r -p "$(echo -e "${YELLOW}是否需要通过公网 IP 远程访问？[y/N]：${NC}")" answer
    if [[ "$answer" =~ ^[Yy]$ ]]; then
        USE_PUBLIC=true
        read -r -p "$(echo -e "${YELLOW}请输入公网 IP（留空则自动通过 curl ifconfig.me 获取）：${NC}")" input_ip
        if [[ -z "$input_ip" ]]; then
            echo -e "${CYAN}正在自动获取公网 IP ...${NC}"
            input_ip=$(curl -4 -sf --max-time 8 ifconfig.me 2>/dev/null || curl -4 -sf --max-time 8 icanhazip.com 2>/dev/null || true)
            if [[ -z "$input_ip" ]]; then
                echo -e "${RED}自动获取公网 IP 失败，请手动重新运行脚本并输入 IP。${NC}"
                exit 1
            fi
        fi
        PUBLIC_IP="$input_ip"
        echo -e "${GREEN}将使用公网地址: ${PUBLIC_IP}${NC}"
    else
        USE_PUBLIC=false
        PUBLIC_IP="127.0.0.1"
        echo -e "${CYAN}将使用本地地址: 127.0.0.1${NC}"
    fi
    echo ""
}

# ---------- 2. 安装系统依赖 & Docker Engine ----------
install_prerequisites() {
    run_step "更新 apt 索引" \
        "sudo apt-get update -y -qq"

    run_step "安装基础依赖 (curl, gnupg, ca-certificates)" \
        "sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release"

    run_step "创建 Docker GPG 密钥环目录" \
        "sudo install -m 0755 -d /etc/apt/keyrings"

    run_step "导入 Docker 官方 GPG 密钥" \
        "curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg && sudo chmod a+r /etc/apt/keyrings/docker.gpg"

    run_step "添加 Docker APT 源" \
        'echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null'

    run_step "更新 apt 索引（含 Docker 源）" \
        "sudo apt-get update -y -qq"

    run_step "安装 Docker Engine (仅必要组件，不含 Desktop)" \
        "sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin"
}

# ---------- 3. 验证 Docker ----------
verify_docker() {
    run_step "验证 Docker 安装" \
        "sudo docker --version"
}

# ---------- 4. 创建 Docker 网络 ----------
create_network() {
    run_step "创建 Docker 网络 (astrbot-snowluma-net)" \
        "sudo docker network inspect astrbot-snowluma-net >/dev/null 2>&1 || sudo docker network create astrbot-snowluma-net"
}

# ---------- 5. 部署 AstrBot ----------
deploy_astrbot() {
    run_step "创建 AstrBot 数据目录" \
        "mkdir -p \"\$HOME/astrbot/data\""

    run_step "拉取 AstrBot 镜像" \
        "sudo docker pull soulter/astrbot:latest"

    run_step "启动 AstrBot 容器" \
        "sudo docker run -itd \
            --name astrbot \
            --restart unless-stopped \
            --network astrbot-snowluma-net \
            -p 6185:6185 \
            -p 6199:6199 \
            -v \"\$HOME/astrbot/data:/AstrBot/data\" \
            -v /etc/localtime:/etc/localtime:ro \
            -v /etc/timezone:/etc/timezone:ro \
            soulter/astrbot:latest"
}

# ---------- 6. 部署 SnowLuma ----------
deploy_snowluma() {
    run_step "创建 SnowLuma 数据目录" \
        "mkdir -p \"\$HOME/snowluma/data\""

    run_step "拉取 SnowLuma 镜像 (motricseven7/snowluma:latest)" \
        "sudo docker pull motricseven7/snowluma:latest"

    run_step "启动 SnowLuma 容器" \
        "sudo docker run -d \
            --name snowluma \
            --restart unless-stopped \
            --network astrbot-snowluma-net \
            -e VNC_PASSWD=vncpasswd \
            -e SNOWLUMA_WEBUI_PORT=5099 \
            -p 6081:6081 \
            -p 5099:5099 \
            -p 3000:3000 \
            -p 3001:3001 \
            -v \"\$HOME/snowluma/data:/app/snowluma-data\" \
            -v /etc/localtime:/etc/localtime:ro \
            -v /etc/timezone:/etc/timezone:ro \
            motricseven7/snowluma:latest"
}

# ---------- 7. 等待并提取密码 ----------
extract_passwords() {
    echo -e "${CYAN}等待 AstrBot 生成初始密码 ...${NC}"
    local astrbot_pass=""
    for i in $(seq 1 30); do
        astrbot_pass=$(sudo docker logs astrbot 2>&1 | grep -oP 'Initial password: \K\S+' | tail -1 || true)
        if [[ -n "$astrbot_pass" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "$astrbot_pass" ]]; then
        echo -e "${YELLOW}未能自动提取 AstrBot 初始密码，请稍后手动执行：${NC}"
        echo -e "${CYAN}sudo docker logs astrbot | grep 'Initial password'${NC}"
        astrbot_pass="(请查看日志)"
    fi

    echo -e "${CYAN}等待 SnowLuma 生成 WebUI 临时密码 ...${NC}"
    local snowluma_pass=""
    for i in $(seq 1 30); do
        snowluma_pass=$(sudo docker logs snowluma 2>&1 | grep -iE 'password|临时密码|WebUI.*password' | head -1 || true)
        if [[ -n "$snowluma_pass" ]]; then
            break
        fi
        sleep 2
    done

    if [[ -z "$snowluma_pass" ]]; then
        snowluma_pass="(请执行: sudo docker logs snowluma 2>&1 | grep -i password)"
    fi

    # 保存到临时变量供最后输出
    ASTRBOT_INIT_PASS="$astrbot_pass"
    SNOWLUMA_INIT_PASS="$snowluma_pass"
}

# ---------- 8. 设置 AstrBot 密码（交互）----------
set_astrbot_password() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${YELLOW}AstrBot 初始密码已生成，现在需要你亲自设置新密码。${NC}"
    echo -e "即将执行官方密码重置命令，请按提示输入新密码："
    echo -e "${CYAN}  sudo docker exec -it astrbot astrbot password${NC}"
    echo -e "设置完成后，脚本会自动重启 AstrBot 容器使密码生效。"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    read -r -p "$(echo -e "${YELLOW}按回车键执行密码重置命令 ...${NC}")" _

    sudo docker exec -it astrbot astrbot password || true

    echo ""
    echo -e "${CYAN}正在重启 AstrBot 使新密码生效 ...${NC}"
    sudo docker restart astrbot
    echo -e "${GREEN}AstrBot 密码已更新并重启。${NC}"
}

# ---------- 9. 生成管理脚本 ----------
create_manager_script() {
    local manager_path="$HOME/manage-astrbot-snowluma.sh"
    cat > "$manager_path" <<'MANAGER_EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

ASTRBOT_WEBUI_PORT=6185
SNOWLUMA_WEBUI_PORT=5099
SNOWLUMA_NOVNC_PORT=6081
HOST_IP="${1:-127.0.0.1}"

case "${1:-}" in
    start)
        sudo docker start astrbot snowluma
        echo "AstrBot 与 SnowLuma 已启动。"
        ;;
    stop)
        sudo docker stop astrbot snowluma
        echo "AstrBot 与 SnowLuma 已停止。"
        ;;
    restart)
        sudo docker restart astrbot snowluma
        echo "AstrBot 与 SnowLuma 已重启。"
        ;;
    status)
        sudo docker ps --filter "name=astrbot" --filter "name=snowluma" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        ;;
    *)
        echo "用法: $0 {start|stop|restart|status} [公网IP]"
        echo "示例: $0 start 203.0.113.10"
        exit 1
        ;;
esac

# 仅在 start/restart 时输出地址
if [[ "${1:-}" == "start" || "${1:-}" == "restart" ]]; then
    echo ""
    echo "AstrBot WebUI : http://${HOST_IP}:${ASTRBOT_WEBUI_PORT}"
    echo "SnowLuma WebUI: http://${HOST_IP}:${SNOWLUMA_WEBUI_PORT}"
    echo "SnowLuma noVNC: http://${HOST_IP}:${SNOWLUMA_NOVNC_PORT}"
    echo "(密码未在此输出，请查看部署时记录或执行 docker logs 获取)"
fi
MANAGER_EOF

    chmod +x "$manager_path"
    echo -e "${GREEN}管理脚本已生成: ${manager_path}${NC}"
    echo -e "用法: ${manager_path} {start|stop|restart|status} [公网IP]"
}

# ---------- 10. 打印最终信息 ----------
print_final_info() {
    local host_display="$PUBLIC_IP"
    if [[ "$USE_PUBLIC" != true ]]; then
        host_display="127.0.0.1"
    fi

    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${GREEN}  部署完成${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
    echo -e "${YELLOW}AstrBot:${NC}"
    echo -e "  容器名      : astrbot"
    echo -e "  WebUI 端口  : 6185"
    echo -e "  OneBot 端口 : 6199"
    echo -e "  数据目录    : $HOME/astrbot/data"
    echo -e "  访问地址    : http://${host_display}:6185"
    echo -e "  初始用户名  : astrbot"
    echo -e "  初始密码    : ${ASTRBOT_INIT_PASS}  （如已通过命令行重置，请使用新密码）"
    echo ""
    echo -e "${YELLOW}SnowLuma:${NC}"
    echo -e "  容器名        : snowluma"
    echo -e "  WebUI 端口    : 5099"
    echo -e "  noVNC 端口    : 6081"
    echo -e "  OneBot HTTP   : 3000"
    echo -e "  OneBot WS     : 3001"
    echo -e "  数据目录      : $HOME/snowluma/data"
    echo -e "  WebUI 地址    : http://${host_display}:5099"
    echo -e "  noVNC 地址    : http://${host_display}:6081/vnc.html"
    echo -e "  VNC 密码      : vncpasswd  （由 VNC_PASSWD 环境变量固定）"
    echo -e "  WebUI 临时密码: ${SNOWLUMA_INIT_PASS}"
    echo ""

    if [[ "$USE_PUBLIC" == true ]]; then
        echo -e "${RED}公网访问提醒:${NC} 如果服务器位于云厂商（阿里云/腾讯云/AWS 等），"
        echo -e "请在安全组/防火墙中放行 TCP 端口: ${YELLOW}6185, 6199, 6081, 5099, 3000, 3001${NC}"
        echo -e "AstrBot 官方文档也明确提示云服务器需要放行 6180-6200 及 11451 端口[reference:2]。"
    else
        echo -e "${CYAN}当前使用本地地址，如需公网访问请重新运行脚本并选择公网 IP。${NC}"
    fi

    echo ""
    echo -e "${CYAN}管理脚本: $HOME/manage-astrbot-snowluma.sh${NC}"
    echo -e "${CYAN}示例: $HOME/manage-astrbot-snowluma.sh start ${host_display}${NC}"
}

# ============================================================
# 主流程
# ============================================================
main() {
    ask_public_access
    install_prerequisites
    verify_docker
    create_network
    deploy_astrbot
    deploy_snowluma

    # 等待容器就绪
    sleep 5
    extract_passwords
    set_astrbot_password
    create_manager_script
    print_final_info
}

main "$@"