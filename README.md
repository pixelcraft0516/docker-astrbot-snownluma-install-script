# AstrBot + SnowLuma Ubuntu 一键部署

本目录包含：

| 文件 | 作用 |
| --- | --- |
| [`install-astrbot-snowluma.sh`](install-astrbot-snowluma.sh) | 主安装脚本：检查环境、安装 Docker Engine、部署 AstrBot + SnowLuma、生成凭据与管理脚本 |
| [`astrbot-snowluma.sh`](astrbot-snowluma.sh) | 独立管理脚本（安装器也会把同一份内容写到安装目录） |
| `README.md` | 使用说明 |

> 部署依据：
> [AstrBot Docker 文档](https://docs.astrbot.app/deploy/astrbot/docker.html)、
> [SnowLuma Docker Framework README](https://github.com/SnowLuma/SnowLuma.Docker.Framework)、
> [SnowLuma 配置参考](https://snowluma.github.io/zh/docs/guide/configuration)、
> [SnowLuma 对接机器人](https://snowluma.github.io/zh/docs/guide/connect-bot)。

---

## 1. 支持范围

- Ubuntu **18.04 / 20.04 / 22.04 / 24.04**，以及同代仍可用的 Ubuntu 版本；
- 架构：`amd64`（x86_64）、`arm64`（aarch64）；
- 需要 root / sudo；
- 建议 **2 GiB 以上内存**、**8–10 GiB 以上可用磁盘**；
- 仅安装 **Docker Engine + Compose v2**，不安装 Docker Desktop；
- 需要能访问 Docker Hub、Docker APT 源或国内镜像源。

脚本会优先使用 Ubuntu 自带的 `docker.io`/Docker CE 仓库；如果当前 Ubuntu 代号没有对应的
Docker CE 仓库（常见于非 LTS 版本），会自动回退到 Ubuntu 的 `docker.io`，并单独安装
Compose v2。

> Ubuntu < 18.04 的内核/用户态过旧，脚本默认拒绝静默升级发行版；如确需尝试，可加
> `--allow-os-upgrade`。发行版升级会重启并可能中断 SSH，生产环境请先做快照。

---

## 2. 安装

服务器终端执行：

```
curl -fsSL -o install-astrbot-install.sh https://raw.githubusercontent.com/pixelcraft0516/docker-astrbot-snownluma-install-script/refs/heads/main/install-astrbot-snowluma.sh
sudo bash install-astrbot-install.sh

```

脚本会先检查系统，然后询问：

```text
是否需要从公网远程访问 AstrBot / SnowLuma？ [y/N]
公网 IP 或域名（留空自动探测）:
```

- 选择 `n`（或直接回车）：WebUI 和 noVNC 只绑定 `127.0.0.1`，远程通过 SSH 隧道访问；
- 选择 `y`：绑定 `0.0.0.0`，并要求填写公网 IP；**留空会自动通过多个公共服务探测公网 IPv4**，
  探测失败时回退到本机第一个非回环 IPv4，并在终端提示；
- 公网地址支持 IPv4 或域名，不接受 IPv6/端口/路径。

非交互示例：

```bash
# 仅本机
sudo bash install-astrbot-snowluma.sh --private --yes

# 公网，自动探测公网 IP
sudo bash install-astrbot-snowluma.sh --public --yes

# 公网，手工指定
sudo bash install-astrbot-snowluma.sh --public --public-ip 203.0.113.10
```

自定义安装目录：

```bash
sudo bash install-astrbot-snowluma.sh --dir /srv/astrbot-snowluma
```

`--dry-run` 只做系统检查并打印计划，不写配置、不装软件。

默认安装目录：`/opt/astrbot-snowluma`。

> 安全保护：如果机器上已经存在**不属于本安装目录**的 `astrbot` 或 `snowluma` 容器，脚本会停止，
> 不会覆盖现有容器/数据。请换一台干净机器，或先备份并处理旧容器。

---

## 3. 安装过程中会看到什么

终端同时显示两层信息：

```text
[################----------------]  52%  拉取 SnowLuma 镜像
  $ docker pull motricseven7/snowluma:latest
```

- 上方的进度条会随步骤实时推进；
- 下方**单行**显示当前具体执行的命令（过长时按终端宽度截断，完整命令写入安装日志）；
- 每个命令的标准输出/错误都写入 `logs/install-*.log`，安装失败时会自动打印最近 40 行；
- 安装完成后会输出所有端口、地址、账号、密码和 Token。

进度条是按阶段加权的估算值；`docker pull`、`apt` 等无法逐字节精确统计的步骤会在执行期间
持续变化，但不会伪造“已完成”。

---

## 4. 部署架构与端口

```text
浏览器 ──> AstrBot WebUI        :6185
浏览器 ──> SnowLuma WebUI       :5099
浏览器 ──> SnowLuma noVNC       :6081  ──> Xvfb / x11vnc / QQ
AstrBot <── ws://astrbot:6199/ws ── SnowLuma（Docker 内部网络）
SnowLuma OneBot HTTP/WS         :3000 / :3001（仅 127.0.0.1）
```

| 服务 | 容器内端口 | 宿主机默认端口 | 暴露范围 |
| --- | ---: | ---: | --- |
| AstrBot WebUI | 6185 | 6185 | 公网模式 `0.0.0.0`，否则 `127.0.0.1` |
| SnowLuma WebUI | 5099 | 5099 | 同上 |
| SnowLuma noVNC | 6081 | 6081 | 同上 |
| SnowLuma OneBot HTTP | 3000 | 3000 | **始终仅 127.0.0.1** |
| SnowLuma OneBot WS | 3001 | 3001 | **始终仅 127.0.0.1** |
| AstrBot OneBot 反向 WS | 6199 | 不映射 | 仅 Docker 网络 `astrbot-snowluma` |

若默认宿主机端口已被占用，脚本会自动顺延到下一个空闲端口，并在安装结果中打印实际端口。
容器内部端口保持不变。

### 自动接通 AstrBot

安装器会：

1. 在 `astrbot/data/cmd_config.json` 中预置 OneBot v11 适配器：
   `ws_reverse_host=0.0.0.0`、`ws_reverse_port=6199`、随机 `ws_reverse_token`；
2. 在 `snowluma/data/config/onebot.json` 中预置 `wsClients`：
   `ws://astrbot:6199/ws`，使用同一个 Token；
3. 两个容器加入同一个 Docker 网络 `astrbot-snowluma`。

因此登录 QQ 后，SnowLuma 会作为客户端主动连接 AstrBot，不需要手工填 OneBot 地址。
如果你在 WebUI 中修改了端口或 Token，请同步修改另一侧配置并重启。

---

## 5. 安装完成后的凭据

安装器会把凭据打印到终端，并写入：

```text
/opt/astrbot-snowluma/credentials.txt   (权限 600)
```

内容包括：

- AstrBot WebUI 地址、用户名 `astrbot`、初始密码（首次登录后 AstrBot 要求修改）；
- SnowLuma WebUI 地址、用户名 `admin`、密码；
- SnowLuma noVNC 地址、密码（noVNC 没有用户名，留空即可；VNC 只使用密码前 8 位）；
- SnowLuma OneBot HTTP/WS 地址与 Token；
- SnowLuma → AstrBot 的反向 WS Token；
- 管理命令与 SSH 隧道命令。

查看：

```bash
sudo cat /opt/astrbot-snowluma/credentials.txt
```

> 安装器只在首次安装时生成并打印这些凭据；重复运行会保留已有 `.env` 和配置。
> 如果手动修改过 AstrBot/SnowLuma 密码，以实际密码为准。

---

## 6. 本地管理脚本

安装器会生成：

```text
/opt/astrbot-snowluma/astrbot-snowluma.sh
/usr/local/bin/astrbot-snowluma -> 上面的脚本
```

使用：

```bash
sudo astrbot-snowluma start     # 启动两个容器，输出 WebUI 地址，不输出密码
sudo astrbot-snowluma stop      # 停止容器，保留容器和数据
sudo astrbot-snowluma restart   # 重启
sudo astrbot-snowluma status    # 容器状态 + HTTP 检查 + 地址
sudo astrbot-snowluma logs      # 实时日志（Ctrl-C 退出）
sudo astrbot-snowluma urls      # 只显示地址
sudo astrbot-snowluma update    # 拉取最新镜像并重建（保留数据）
```

管理脚本**不会输出密码**。`start/status/urls` 只输出地址，并提示凭据文件位置。

容器使用 `restart: unless-stopped`；Docker 服务已设置开机自启，所以服务器重启后容器会自动恢复。
如果执行过 `stop`，重启后不会自动拉起，需要再执行 `start`。

---

## 7. 首次使用流程

1. 打开 SnowLuma noVNC：`http://<访问地址>:6081/vnc.html`；
2. 输入 noVNC 密码，进入远程桌面；
3. 在远程桌面中打开 QQ，用手机扫码登录；
4. 登录后 SnowLuma 会自动注入并加载账号，`wsClients` 会自动连接 AstrBot；
5. 打开 AstrBot WebUI，用 `astrbot` + 初始密码登录，按提示修改密码；
6. 在 AstrBot 中配置模型提供商，开始使用。

如需确认反向 WS 是否连接，可查看 AstrBot 日志，出现类似
`aiocqhttp(OneBot v11) 适配器已连接` 即成功。

---

## 8. 公网访问与安全

公网模式会直接把 WebUI/noVNC 绑定到 `0.0.0.0`：

- AstrBot / SnowLuma 已使用强随机密码；
- noVNC 仍使用 **HTTP 明文**传输 VNC 密码，**不适合直接暴露在不可信公网**；
- 脚本会尽量为已启用的 UFW 放行三个 Web 端口，但**不会**自动修改云厂商安全组；
- 建议至少采取一种加固：
  - 云安全组只放行自己的出口 IP；
  - 使用 SSH 隧道（`--private` 模式）；
  - 在 Nginx/Caddy 后做 TLS 与访问控制；
- OneBot 3000/3001 不随公网模式开放，仍只绑定 `127.0.0.1`；
- AstrBot 的 6199 不映射到宿主机。

私有模式远程访问示例（管理脚本也会打印）：

```bash
ssh -L 6185:127.0.0.1:6185 \
    -L 5099:127.0.0.1:5099 \
    -L 6081:127.0.0.1:6081 \
    用户名@服务器IP
```

然后在本机浏览器打开 `http://127.0.0.1:6185` 等地址。

---

## 9. 依赖、升级与旧系统

安装前会检查：

- 是否 Ubuntu、版本、架构、内核；
- 内存、根分区空间；
- 端口占用；
- 是否已存在同名容器（避免覆盖其他 AstrBot/SnowLuma）；
- Docker 是否已安装、版本是否 ≥ 20.10、Compose v2 是否可用；
- 是否 snap 版 Docker（SnowLuma 需要标准 Docker Engine，检测到会停止并提示先移除 snap Docker）。

缺失依赖会自动通过 APT 安装；Docker 过旧会自动升级；Docker CE 仓库不可用时回退到
Ubuntu 的 `docker.io` 并单独安装 Compose v2。镜像拉取失败时会依次尝试
`docker.1ms.run`、`docker.m.daocloud.io`、`docker.xuanyuan.me` 前缀，成功后重新打标签。

Ubuntu 18.04 会使用兼容模式并提示升级；**不会默认静默执行 `do-release-upgrade`**。
如明确接受风险：

```bash
sudo bash install-astrbot-snowluma.sh --allow-os-upgrade
```

---

## 10. 排障

| 现象 | 处理 |
| --- | --- |
| 端口被占用 | 脚本会自动顺延；也可先停掉占用进程，或修改 `.env` 后 `sudo astrbot-snowluma restart` |
| Docker 拉取失败 | 检查 DNS/代理；脚本会尝试国内镜像前缀；也可在 `.env` 设置 `ASTROBOT_IMAGE` / `SNOWLUMA_IMAGE` |
| AstrBot 未连接 SnowLuma | 先确认 QQ 已登录；再查 `sudo astrbot-snowluma logs`，确认 `ws://astrbot:6199/ws` 与 Token 一致 |
| noVNC 打不开 | 等 SnowLuma 启动完成（首次解压/初始化较慢）；查看 `docker logs snowluma` |
| 忘记 AstrBot 密码 | 按官方文档重置：`docker exec -it astrbot astrbot password` |
| 忘记 SnowLuma WebUI 密码 | 查看安装时 `credentials.txt`；若已修改则以其为准 |
| 想重装但保留数据 | 保留安装目录中的 `.env`、`astrbot/data`、`snowluma/data`，不要删除 |
| 安装日志 | `/opt/astrbot-snowluma/logs/install-*.log` |

常用只读检查：

```bash
sudo astrbot-snowluma status
sudo docker compose -f /opt/astrbot-snowluma/compose.yaml --env-file /opt/astrbot-snowluma/.env ps
sudo docker logs --tail 100 astrbot
sudo docker logs --tail 100 snowluma
```

---

## 11. 文件布局

```text
/opt/astrbot-snowluma/
├── .env                      # 密码、Token、端口、访问模式（600）
├── compose.yaml              # 两个服务、网络、健康检查、日志轮转
├── credentials.txt           # 安装凭据（600）
├── astrbot-snowluma.sh       # 管理脚本
├── astrbot/
│   └── data/
│       └── cmd_config.json   # 预置 OneBot 反向 WS
├── snowluma/
│   ├── data/
│   │   └── config/
│   │       ├── onebot.json   # 预置 HTTP/WS/反向 WS
│   │       ├── runtime.json  # 由 SnowLuma 首次启动生成
│   │       └── ...
│   ├── .config/
│   └── .local/share/
└── logs/
    └── install-*.log
```

SnowLuma 使用绑定目录而不是匿名卷，便于备份和检查；目录属主会按 `SNOWLUMA_UID/GID`
（默认 1000）设置。

---

## 12. 卸载/重置

本脚本不自动删除数据。需要彻底重来时：

```bash
sudo astrbot-snowluma stop
sudo docker rm -f astrbot snowluma
sudo docker network rm astrbot-snowluma
sudo rm -rf /opt/astrbot-snowluma
sudo rm -f /usr/local/bin/astrbot-snowluma
```

删除前请确认 `astrbot/data` 和 `snowluma/data` 中没有需要保留的配置、插件和登录态。
