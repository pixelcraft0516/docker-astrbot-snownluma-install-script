#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# sbt-deploy.sh — 一键部署 AstrBot + SnowLuma
# 密码由两个服务首次启动随机生成，脚本自动提取并展示
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

STEP_TOTAL=8
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
echo -e "${GREEN}  （初始密码由服务自动生成，脚本提取）${NC}"
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
echo "  初始密码: 由 AstrBot / SnowLuma 首次启动随机生成，脚本会读取并展示"
echo ""
read -rp "确认开始部署？(y/n，默认 y): " CONFIRM
[[ "$CONFIRM" =~ ^[Nn] ]] && exit 0

# ---------- 部署目录 ----------
DEPLOY_DIR="/opt/sbt-stack"
mkdir -p "$DEPLOY_DIR"/{astrbot-data,snowluma-data,snowluma-qq-config,snowluma-qq-data}

# ---------- 1. 安装 Docker CE ----------
# ---------- 1. 安装 Docker CE (兼容 Ubuntu 20.04 手动安装) ----------
step "安装 Docker CE..." "手动添加源并安装 docker-ce (跳过不兼容的 model-plugin)"

if ! command -v docker &>/dev/null; then
  # 安装基础依赖
  apt-get update
  apt-get install -y ca-certificates curl gnupg

  # 添加 Docker 官方 GPG 密钥和源
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  # 更新源并只安装必需组件（不包含 docker-model-plugin）
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
fi

systemctl enable docker --now &>/dev/null || true

# 配置镜像加速（保留你原有的逻辑）
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

# ---------- 5. 等待初始化并提取初始密码 ----------
step "等待服务初始化并提取初始密码..." "docker logs astrbot / snowluma | grep ..."

echo -e "${YELLOW}等待 AstrBot / SnowLuma 初始化（约 25 秒）...${NC}"

ASTRBOT_PASSWORD=""
SNOWLUMA_WEBUI_PASSWORD=""
SNOWLUMA_VNC_PASSWORD=""

for i in $(seq 1 30); do
  ASTRBOT_LOG=$(docker logs astrbot 2>&1 || true)
  SNOWLUMA_LOG=$(docker logs snowluma 2>&1 || true)

  # AstrBot 初始密码: ➜  Initial password: xxxxx
  ASTRBOT_PASSWORD=$(echo "$ASTRBOT_LOG" \
    | grep -i 'Initial password' \
    | sed -E 's/.*Initial password:[[:space:]]*//' \
    | sed -n '1p' \
    | tr -d ' \r' || true)

  # SnowLuma WebUI 初始密码: initial credentials: user=admin password=xxxxx
  SNOWLUMA_WEBUI_PASSWORD=$(echo "$SNOWLUMA_LOG" \
    | grep -i 'initial credentials' \
    | sed -E 's/.*password=([^ ]+).*/\1/' \
    | sed -n '1p' \
    | tr -d ' \r' || true)

  # SnowLuma VNC 密码: 远程桌面密码: xxxxx
  SNOWLUMA_VNC_PASSWORD=$(echo "$SNOWLUMA_LOG" \
    | grep -iE '远程桌面密码|remote desktop password' \
    | sed -E 's/.*[:：][[:space:]]*//' \
    | sed -n '1p' \
    | tr -d ' \r' || true)

  if [[ -n "$ASTRBOT_PASSWORD" && -n "$SNOWLUMA_WEBUI_PASSWORD" && -n "$SNOWLUMA_VNC_PASSWORD" ]]; then
    break
  fi
  sleep 5
done

# ---------- 6. 公网访问时放开 AstrBot dashboard.host ----------
step "配置 AstrBot 远程访问..." "修改 data/cmd_config.json 中 dashboard.host"

if [[ "$PUBLIC_ACCESS" =~ ^[Yy] ]]; then
  # 等配置文件出现（首次启动才生成）
  for i in $(seq 1 20); do
    [[ -f "$DEPLOY_DIR/astrbot-data/cmd_config.json" ]] && break
    sleep 2
  done

  if [[ -f "$DEPLOY_DIR/astrbot-data/cmd_config.json" ]]; then
    # 用 Python 安全修改 JSON（改动 dashboard.host 为 0.0.0.0）
    python3 - "$DEPLOY_DIR/astrbot-data/cmd_config.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    cfg = json.load(f)
cfg.setdefault("dashboard", {})
cfg["dashboard"]["host"] = "0.0.0.0"
# 如果配置里存在端口字段，与 compose 映射保持一致
if "port" in cfg["dashboard"]:
    pass  # 保持原值，用户端口由 compose 映射处理
with open(path, "w", encoding="utf-8") as f:
    json.dump(cfg, f, ensure_ascii=False, indent=2)
print("dashboard.host -> 0.0.0.0")
PY
    docker restart astrbot >/dev/null
    echo -e "${GREEN}已放开 AstrBot dashboard.host，正在重启容器...${NC}"
    sleep 8
    # 重启后 AstrBot 如果尚未改密，仍会重新打印 Initial password，重新提取一次
    ASTRBOT_LOG=$(docker logs astrbot 2>&1 || true)
    NEW_PASS=$(echo "$ASTRBOT_LOG" \
      | grep -i 'Initial password' \
      | sed -E 's/.*Initial password:[[:space:]]*//' \
      | sed -n '1p' \
      | tr -d ' \r' || true)
    [[ -n "$NEW_PASS" ]] && ASTRBOT_PASSWORD="$NEW_PASS"
  else
    echo -e "${YELLOW}未找到 cmd_config.json，跳过（可稍后手动修改）${NC}"
  fi
else
  echo -e "${BLUE}未开启公网访问，跳过 dashboard.host 修改${NC}"
fi

# ---------- 7. 创建 sbt 启动脚本 ----------
step "创建 sbt 启动脚本..." "写入 /usr/local/bin/sbt"

cat > /usr/local/bin/sbt <<'SBT_EOF'
#!/usr/bin/env bash
set -euo pipefail

DEPLOY_DIR="/opt/sbt-stack"
cd "$DEPLOY_DIR"

get_ports_and_host() {
  ASTRBOT_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:6185)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "6185")
  SNOWLUMA_WEBUI_PORT=$(grep -oP '"\K[^"]+(?=:5099)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "5099")
  SNOWLUMA_VNC_PORT=$(grep -oP '"\K[^"]+(?=:6081)' docker-compose.yml 2>/dev/null | sed -n '1p' || echo "6081")
  PUBLIC_IP=""
  [[ -f "$DEPLOY_DIR/.public_ip" ]] && PUBLIC_IP=$(cat "$DEPLOY_DIR/.public_ip")
  HOST="${PUBLIC_IP:-127.0.0.1}"
}

show_info() {
  get_ports_and_host

  ASTRBOT_LOG=$(docker logs astrbot 2>&1 || true)
  ASTRBOT_PASS=$(echo "$ASTRBOT_LOG" \
    | grep -i 'Initial password' \
    | sed -E 's/.*Initial password:[[:space:]]*//' \
    | sed -n '1p' \
    | tr -d ' \r' || true)

  SNOWLUMA_LOG=$(docker logs snowluma 2>&1 || true)
  WEBUI_PASS=$(echo "$SNOWLUMA_LOG" \
    | grep -i 'initial credentials' \
    | sed -E 's/.*password=([^ ]+).*/\1/' \
    | sed -n '1p' \
    | tr -d ' \r' || true)
  VNC_PASS=$(echo "$SNOWLUMA_LOG" \
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
  echo "  AstrBot WebUI  : 用户名 astrbot / 密码 ${ASTRBOT_PASS:-已在首次登录后修改，无法从日志恢复}"
  echo "  SnowLuma WebUI : 用户名 admin    / 密码 ${WEBUI_PASS:-已在首次登录后修改，无法从日志恢复}"
  echo "  SnowLuma VNC   : 密码 ${VNC_PASS:-未在日志中找到}"
  echo ""
  echo "============================================================"
}

CMD="${1:-start}"

case "$CMD" in
  start|up)
    echo "启动 AstrBot + SnowLuma ..."
    docker compose up -d
    sleep 12
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
    sleep 12
    show_info
    ;;
  status|ps)
    docker compose ps
    ;;
  logs)
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
    echo "  sbt                启动服务并显示地址与密码（默认）"
    echo "  sbt start          同上"
    echo "  sbt stop           停止服务（保留数据）"
    echo "  sbt restart        重启服务并显示地址与密码"
    echo "  sbt status         查看容器状态"
    echo "  sbt logs           实时查看全部日志"
    echo "  sbt logs astrbot   只看 AstrBot 日志"
    echo "  sbt logs snowluma  只看 SnowLuma 日志"
    exit 1
    ;;
esac
SBT_EOF

chmod +x /usr/local/bin/sbt

# 记录公网 IP 供 sbt 使用
if [[ -n "$PUBLIC_IP" ]]; then
  echo "$PUBLIC_IP" > "$DEPLOY_DIR/.public_ip"
fi

# ---------- 8. 完成 ----------
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

【登录凭据（首次启动随机生成）】
  AstrBot WebUI  : 用户名 astrbot / 密码 ${ASTRBOT_PASSWORD:-已在首次登录后修改，无法从日志恢复}
  SnowLuma WebUI : 用户名 admin    / 密码 ${SNOWLUMA_WEBUI_PASSWORD:-已在首次登录后修改，无法从日志恢复}
  SnowLuma VNC   : 密码 ${SNOWLUMA_VNC_PASSWORD:-未在日志中找到}

  ⚠️ 重要：
  - AstrBot 和 SnowLuma 的初始密码仅在首次启动时打印一次，且首次登录后必须修改。
  - 若跳过修改，下次启动会自动生成新的随机密码，旧密码失效。
  - 请现在立即登录并保存好你的新密码。

【下一步：在 AstrBot WebUI 中连接 SnowLuma】
1. 打开 AstrBot WebUI: http://${HOST_DISPLAY}:${ASTRBOT_WEBUI_PORT}
2. 左侧菜单 → 消息平台 → 新增适配器
3. 选择 “aiocqhttp (OneBot v11)”
4. 连接方式选择 “正向 WebSocket”
5. 地址填写: ws://snowluma:${SNOWLUMA_ONEBOT_WS_PORT}
6. Token 留空（除非你在 SnowLuma WebUI 中设置了 OneBot access token）
7. 保存并启用

【SnowLuma 登录 QQ】
1. 打开 SnowLuma WebUI，使用 admin + 初始密码登录
2. 在 WebUI 中启动 QQ 实例，用手机扫码登录
3. 确保 OneBot WebSocket 服务端已开启（默认端口 ${SNOWLUMA_ONEBOT_WS_PORT}）

【日常启动】
  sbt            启动并显示地址与密码
  sbt stop       停止（保留数据）
  sbt restart    重启并显示地址与密码
  sbt status     查看容器状态
  sbt logs       实时日志

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
echo -e "  AstrBot WebUI  : 用户名 ${GREEN}astrbot${NC} / 密码 ${GREEN}${ASTRBOT_PASSWORD:-已在首次登录后修改，无法从日志恢复}${NC}"
echo -e "  SnowLuma WebUI : 用户名 ${GREEN}admin${NC}    / 密码 ${GREEN}${SNOWLUMA_WEBUI_PASSWORD:-已在首次登录后修改，无法从日志恢复}${NC}"
echo -e "  SnowLuma VNC   : 密码 ${GREEN}${SNOWLUMA_VNC_PASSWORD:-未在日志中找到}${NC}"
echo ""
echo -e "${RED}⚠️ 初始密码仅在首次启动打印一次；首次登录后必须修改；若跳过修改，下次启动会重新生成新密码。${NC}"
echo -e "${RED}   请现在立即登录并保存好你的新密码。${NC}"
echo ""
echo -e "${GREEN}连接指引已保存至: $DEPLOY_DIR/连接指引.txt${NC}"
echo -e "${GREEN}日常启动: 输入 ${YELLOW}sbt${GREEN}${NC}"
echo -e "${GREEN}============================================================${NC}"