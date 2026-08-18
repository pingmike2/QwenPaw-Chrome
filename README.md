# chromium-QwenPaw — frp 一键部署 QwenPaw + 云端 Chromium 浏览器

在一台已经安装 QwenPaw 的 **Debian/Ubuntu Linux 机器**（包括 NAT 内网 / 无公网 IP 的机器）上，用 **frp 内网穿透**把以下服务安全暴露到公网：

- 🤖 **QwenPaw**：你的 AI 助手（面板 Web 界面）
- 🖥 **Chromium 云端浏览器**：Openbox 桌面 + 全屏 Chromium，通过 **noVNC 网页**远程操作，**手机/电脑都能用**
- 🔑 **SSH**：默认开启，远程登录；传 `-S 0` 才关闭

> 精简部署需要 4 个必填参数（`-s` FRP服务器IP / `-f` FRP监听端口 / `-t` TOKEN / `-v` noVNC公网端口；`-p/-P` 密码可选，默认 `qwenpaw`）。端口自动派生：`-v` = noVNC 公网端口，SSH = `-v+1`，QwenPaw 面板 = `-v+2`；三个入口**共用同一个密码**认证（noVNC 和 QwenPaw 面板走 Caddy basic_auth，SSH 走系统密码，默认均为 `qwenpaw`）。传 `-S 0` 关 SSH、`-q 0` 关 QwenPaw 面板。

---

## 🌐 FRP 是什么？NAT 机器也能部署？

**FRP（Fast Reverse Proxy）** 是一个开源内网穿透工具，由 [fatedier](https://github.com/fatedier) 开发（[GitHub](https://github.com/fatedier/frp)）。它的核心能力是：**把内网（NAT 后面）的服务映射到一台有公网 IP 的服务器上**，让外网能直接访问。

```
无公网 IP 的内网机器 (NAT)              公网服务器 (有公网 IP)
┌────────────────────────────┐        ┌──────────────────────┐
│  qwenpaw :8088             │        │  frps :7000 (服务端)  │
│  noVNC   :8080   ──frpc──▶ │──隧道──▶│                      │
│  SSH     :22               │        │  公网端口 10000 → qwenpaw
└────────────────────────────┘        │  公网端口 20000 → noVNC
                                      └──────────────────────┘
用户手机/电脑 ──▶ http://公网IP:10000 ──▶ 你的内网服务
```

**为什么 NAT 机器也能部署？**
- FRP 是**反向代理**：由内网机器（frpc）**主动向外**连接公网服务器（frps），所以**不需要公网 IP、不需要路由器端口映射、不需要改防火墙**
- 你家 NAS、公司内网机器、云上没公网 IP 的容器……只要**能出网**（能访问 github），就能用本项目部署
- 全程只需一个**有公网 IP 的 VPS**（甚至 1 核 512M 的小鸡都够当 frps 服务端）

---

## 🚀 快速开始

### 第 0 步：准备一台公网 VPS 装 FRP 服务端

```bash
bash <(curl -Ls https://main.ssss.nyc.mn/frp.sh)
```

按菜单选 **1 安装 FRP 服务端 (公网服务器)**。建议先把服务端监听端口定为默认的 **7000**；如果你在菜单里改成其他端口，必须把同一个端口同步给下面客户端命令的 `-f`。

需要记录这 3 个值：
- `监听IP`：服务器公网 IP；
- `监听端口`：默认 `7000`，也可以自定义；
- `认证TOKEN`：随机生成的一串。

> frp.sh 由 [@eooce](https://github.com/eooce) 维护，一键装 frps/frpc，感谢！精简版客户端固定填写 `-f 7000`；服务端如果不是 7000，必须同步修改 `-f` 的值。

### 第 1 步（唯一一步）：一键部署（一条命令，无需手动下载）

直接把这行命令输入终端 / 交给 QwenPaw AI 助手执行，自动下载 `install.sh` 并运行：

**精简版**（`-v` 必填，SSH/QwenPaw 自动派生，共用密码）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) -s 你的VPS公网IP -f 7000 -t 你的TOKEN -v 10001 -p 自定义密码
# noVNC=10001, SSH=10002, QwenPaw 面板=10003（都用一个密码）
```

**完整版**（带 noVNC 桌面 / SSH / 分辨率选项）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) \
  -s 你的VPS公网IP \
  -f 7000 \
  -t 你的TOKEN \
  -v 20000 \
  -S 20022 \
  -q 20003 \
  -P mypass \
  -r 720x1280
```

> 💡 `bash <(curl -fsSL ...)` 会边下载边执行，不留临时文件；等价于手动 `curl -o install.sh` + `bash install.sh` 两步。
>
> **端口必须和 frps 一致：** 服务端菜单使用默认 `7000` 时，客户端填写 `-f 7000`；如果服务端监听端口改为 `7100`，客户端改成 `-f 7100`，例如：
> ```bash
> bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) -s 你的VPS公网IP -f 7100 -t 你的TOKEN -q 10000 -p 自定义密码
> ```

| 参数 | 环境变量 | 对应 frp.sh 输出 | 说明 |
|------|---------|-----------------|------|
| `-s` | `FRP_SERVER_IP` | 「监听IP」 | FRP 服务端公网 IP (**必填**) |
| `-f` | `FRP_SERVER_PORT` | 「监听端口」 | FRPS/FRPC 通信端口，默认 `7000` (**必填**) |
| `-t` | `FRP_TOKEN` | 「认证TOKEN」 | 与服务端一致的 token (**必填**) |
| `-v` | `FRP_VNC_REMOTE_PORT` | 自己定 | noVNC 公网端口 (**必填**, 基准：SSH=-v+1, qwenpaw=-v+2) |
| `-p/-P` | `PASSWORD` | 自定义 | SSH/VNC/QwenPaw 共用密码（默认 `qwenpaw`） |
| `-S` | `FRP_SSH_REMOTE_PORT` | `-v+1` | SSH 公网端口；默认自动 = -v+1，传 `-S 0` 禁用 |
| `-q` | `QWENPAW_REMOTE_PORT` | `-v+2` | QwenPaw 面板公网端口（Caddy basic_auth）；默认自动 = -v+2，传 `-q 0` 禁用 |
| `-r` | `RESOLUTION` | `720x1280` | 桌面分辨率；不传时回退到 `720x1280` |
| `-h` | — | — | 查看全部帮助 |

> 💡 脚本完全**无交互**：参数或环境变量传完就跑，不会卡住等输入。适合脚本/CI 自动化调用。
>
> ⚠️ 新版中 `-p` 和 `-P` 都表示同一个 SSH/VNC 共用密码，不区分大小写；FRP 服务端监听端口使用 `-f/--frp-port`；`FRP_SERVER_PORT` 仅作为环境变量兼容写法。为兼容旧命令，`-p 7000 -P mypass` 仍会识别为 FRP 端口 `7000` + 密码 `mypass`。`-q 10000` 未指定 `-S` 时，SSH 公网端口自动回退为 `9999`；传 `-S 0` 才会禁用 SSH。VNC 默认创建公网隧道；传 `-v 0` 才会明确禁用。SSH 同样默认创建，传 `-S 0` 才会禁用。

脚本自动完成：

| 步骤 | 说明 |
|------|------|
| 📥 自动下载 frpc | 自动匹配 Linux 架构（amd64/arm64/arm...），按“GitHub 官方 Release → gh-proxy.com → github.moeyy.xyz → mirror.ghproxy.com”顺序尝试，并分别兼容 curl/wget |
| 🔍 Chromium CDP 修复 | VNC 模式下将有头 Chromium 配置为 QwenPaw 的 `connect_cdp` 端点；无 VNC 时使用无头 CDP 兜底 |
| 🖥️ Xvnc 桌面 | 使用 TigerVNC 的 Xvnc + websockify + noVNC，支持动态分辨率；Caddy 在 Web 层做完整密码认证 |
| 📂 NAS 路径自动探测 | 自动找持久化路径，找不到就 fallback 本地 |
| 📝 生成 frpc.toml | 按你填的变量生成隧道配置 |
| ⚙️ supervisor 托管 | 全部服务开机自启、崩溃自动拉起 |
| 💾 数据定时备份 | qwenpaw 数据每 30 分钟同步到 NAS，重启自动恢复 |

### 部署完成后访问

```
🌐 QwenPaw 面板: http://FRP_SERVER_IP:QWENPAW_REMOTE_PORT   (默认 = -v+2)
    用户名: qwenpaw；密码: -p/-P 传入的完整密码
🖥  noVNC 浏览器: http://FRP_SERVER_IP:FRP_VNC_REMOTE_PORT/vnc.html   (默认开启；-v 必填)
    用户名: qwenpaw；密码: -p/-P 传入的完整密码
🔑 SSH:          ssh -p FRP_SSH_REMOTE_PORT root@FRP_SERVER_IP (默认 = -v+1；传 -S 0 关闭)
```

> 💡 noVNC 访问根路径 `/` 会自动跳转到 `vnc.html?resize=scale` 自适应缩放模式——电脑/手机窗口拉多大，桌面自动缩放填满。也可以直接访问 `/vnc.html`。默认会启用 noVNC 和桌面依赖，传 `-v 0` 才关闭，SSH 和 noVNC 都使用 `-P`/`PASSWORD` 的完整密码，不限制长度。

### 验证部署成功（3 个检查）

| 检查 | 命令 | 期望结果 |
|------|------|---------|
| ① 服务状态 | `supervisorctl status` | 启用 VNC 时应看到 `frpc xvfb openbox vnc-browser caddy-vnc chromium-gui qwenpaw qwenpaw-backup` 均为 `RUNNING`；`chromium-gui` 同时提供有头窗口和 CDP |
| ② 隧道连通 | `curl -s http://127.0.0.1:8080/` | 返回 noVNC 页面 HTML（本地端口 8080） |
| ③ 公网访问 | 手机流量打开 `http://FRP_SERVER_IP:QWENPAW_REMOTE_PORT` | QwenPaw 面板能打开 |

> 💡 手机开**飞行模式 / 关 Wi-Fi** 用流量测试最准，能确认公网隧道真的通了（避免"其实在局域网里"的假阳性）。

### 一键卸载 / 清理

```bash
supervisorctl stop all && supervisorctl shutdown   # 停止全部服务
rm -rf /home/frp /etc/supervisor/conf.d/*.conf     # 删 frp 配置与 supervisor 托管
# 可选: 删除本地服务数据 (默认路径 /app/working, 按实际调整)
rm -rf /app/working /app/working.secret
```

> ⚠️ 删除前确认数据已备份到 NAS（`NAS_BASE_DIR/qwenpaw-data`），卸载不会动 NAS 备份，重装后自动恢复。

---

## 🌐 套自定义域名（Cloudflare 回源）

不想记 IP:端口？给 QwenPaw / noVNC 套个自己的域名，用 **Cloudflare 回源端口**（Origin Port）转发到 frp 映射的公网端口。步骤：

### 1. 域名接入 Cloudflare

把域名托管到 Cloudflare（免费），保证有 A 记录指向你的 **frps 公网 IP**：

```
类型: A      名称: qwenpaw（子域名）   内容: <你的VPS公网IP>   代理状态: 打开(橙色云朵)
类型: A      名称: vnc（子域名）       内容: <你的VPS公网IP>   代理状态: 打开(橙色云朵)
```

> 需要**先**在 Cloudflare 开启 **DNS 记录代理（Proxied）**，才能在「规则」里配回源端口。刚接入的域名如果还没生效，可以先用 `cloudflare-dns.com` 测试。

### 2. 配置回源端口（Origin Rules）

Cloudflare 控制台 → 你的域名 → **规则 Rules → Origin Rules** → Create rule：

| 字段 | 值 |
|------|-----|
| **Field** | `Hostname` |
| **Operator** | `equals` |
| **Value** | `qwenpaw.你的域名.com`（面板子域名） |
| **Destination Port** | `你的QWENPAW_REMOTE_PORT`（默认 = -v+2） |

再建一条 Origin Rule 给 noVNC：

| 字段 | 值 |
|------|-----|
| **Field** | `Hostname` |
| **Operator** | `equals` |
| **Value** | `vnc.你的域名.com` |
| **Destination Port** | `你的FRP_VNC_REMOTE_PORT`（如 20000） |

**原理**：CF 收到 `https://qwenpaw.你的域名` 请求后，按 Hostname 规则把流量转发到**源站（你的 VPS）的指定端口**——这个端口正是 frps 监听的公网端口（如 10000），frps 再通过 frp 隧道送回你内网机器的 qwenpaw。

### 3. 访问

```
🌐 QwenPaw 面板: https://qwenpaw.你的域名.com    (CF 自动给 TLS 证书, 免费)
🖥  noVNC 浏览器: https://vnc.你的域名.com
```

### 常见问题

- **noVNC 连不上？** noVNC 走 WebSocket，CF 需要确保代理开启（橙色云朵）。如果仍失败，在 Cloudflare → `SSL/TLS` → 把模式设为 **Full (strict)**，并在 `Network` 里开启 **WebSockets**。
- **面板能开但 noVNC 白屏？** 默认会创建 noVNC 隧道；只有传 `-v 0` 才关闭。
- **CF 缓存奇怪内容？** QwenPaw/noVNC 这种动态服务建议在 Origin Rule 对应页面的 Cache Rules 里设为 **Bypass**（不缓存）。
- **想要 www/根域名？** 在 Cloudflare `Redirect Rules` 加一条 301 跳转到子域名即可。

---

## 🔧 常见问题排查

| 现象 | 原因 & 解决 |
|------|------------|
| `supervisorctl status` 里某服务 `FATAL` | 看日志：`tail -50 /var/log/<服务名>.err.log`（如 `frpc.err.log`）。最常见是 frpc 连不上 VPS：核对 `-s`/`-t` 和 `FRP_SERVER_PORT` 与 frp.sh 输出是否一致；VPS 防火墙/安全组是否放行对应端口 |
| `frpc` 显示 connection refused | 先在公网 VPS 确认 `frps` 正在监听服务端端口；客户端默认连 `7000`，如果 frps 菜单里改过端口，必须同步设置 `-f 实际端口`、`FRP_SERVER_PORT=实际端口` 或 `--frp-port 实际端口` |

| qwenpaw 面板打不开 | 先 `curl -s http://127.0.0.1:8088/` 看本地是否正常 → 本地通但公网不通，检查 `-q` 端口是否被占用、VPS 是否放行该端口 |
| `frpc` 下载失败 / `apt-cache policy frp` 没有输出 | `frp` 通常不是 Debian/Ubuntu 的 apt 软件包；脚本会从 GitHub Release 下载官方二进制，并自动尝试备用镜像及 curl/wget。若仍失败，检查 `github.com`、`objects.githubusercontent.com`、`release-assets.githubusercontent.com` 是否可达，以及 DNS/代理是否正常 |
| noVNC 连不上 / 白屏 | 默认应有 VNC 隧道；若传了 `-v 0` 则不会创建。否则检查 `frpc`、`xvfb`、`openbox`、`vnc-browser` 服务状态及公网端口 |
| 重跑时卡在“从 NAS 恢复数据” | NAS/NFS/CSI 挂载可能发生 I/O 阻塞；脚本默认最多等待 `NAS_RESTORE_TIMEOUT=120` 秒，超时会跳过并继续部署。也可以直接使用 `SKIP_NAS_RESTORE=1` 跳过恢复 |
| 手机打开 noVNC 但桌面是 1280x720 | 使用 `-r 720x1280`，或用 `/mnt/envd/vnc-browser/vnc-resize.sh phone` 临时切换；电脑可用 `desktop` |
| 重跑部署命令会不会搞坏？ | **不会**。脚本会刷新 frpc、CDP 和 supervisor 程序配置，随后重新加载服务；可重复执行 |
| 想换 VPS / 换 token | 重新执行部署的一键命令并换成新 IP / 新 TOKEN / 新端口即可，frpc 配置会自动重建 |

### ⚠️ 安全提示

- **密码没有独立默认值**：脚本只使用 `-p/-P <PASS>` 或 `PASSWORD=<PASS>` 提供的完整密码；不传就直接退出。SSH 和 noVNC 都使用完整密码，不限制长度。
- **noVNC 使用 Caddy HTTP Basic Auth**：Xvnc 使用 `SecurityTypes None`，不再经过 VNC 8 字符密码限制；Caddy 保护 noVNC 页面和 WebSocket，SSH 和 noVNC 都使用同一个完整密码。例如密码为 `pingmikeAs123` 时，SSH 和 noVNC 都使用完整的 `pingmikeAs123`。
- noVNC 仍建议只暴露给可信网络，或在域名前增加 Cloudflare Access（Zero Trust 免费版）等认证层。
- frp token 相当于你内网的所有钥匙，**别提交到公开仓库 / 别截图发群里**。
- SSH 隧道默认会通过 `-v+1` 开启并开放 root 密码登录，风险较高；如不需要 SSH，请传 `-S 0` 明确关闭，并务必设置自定义共用密码。
- **frp 被运营商 DPI 拦截（frpc 连不上 / EOF）？** 见 [SSH-TUNNEL.md](SSH-TUNNEL.md) —— 用 `ssh -R` 回传 + VPS 本地 frpc 的备用方案，VPS 零新增组件。

---

## ⚙️ 可配置项（命令行参数 / 环境变量）

### 公网端口与回退行为

精简版只填 `-s -f -t -v -p` 五个必填参数时，默认端口：noVNC=`-v`、SSH=`-v+1`、QwenPaw=`-v+2`。公网端口的回退规则如下；脚本不会随机猜测公网端口：

| 参数 | 环境变量 | 不传时的回退行为 | 说明 |
|------|---------|------------------|------|
| `-v` | `FRP_VNC_REMOTE_PORT` | **必填** | noVNC 公网端口；同时作为 SSH/qwenpaw 自动派生端口的基准 |
| `-S` | `FRP_SSH_REMOTE_PORT` | `-v+1` | SSH 公网端口；默认自动 = -v+1，`-S 0` 禁用 |
| `-q` | `QWENPAW_REMOTE_PORT` | `-v+2` | QwenPaw 面板公网端口（Caddy basic_auth）；默认自动 = -v+2，`-q 0` 禁用 |
| `-f/--frp-port` | `FRP_SERVER_PORT` | `7000` | FRPS/FRPC 通信监听端口；必须与公网服务器上的 frps 监听端口一致 |

### 本机服务端口与其他配置

以下是内网机器上的本地监听端口；公网访问时使用上面的 FRP 映射端口：

| 参数 | 环境变量 | 默认回退值 | 说明 |
|------|---------|------------|------|
| `-p/-P` | `PASSWORD` | `qwenpaw` | SSH/VNC/QwenPaw 共用密码；大小写参数通用。SSH 和 noVNC 都使用完整密码，不限制长度 |
| `-r` | `RESOLUTION` | `720x1280` | 桌面分辨率（手机竖屏 720x1280 / 电脑横屏 1280x720） |
| — | `VNC_PORT` | `8080` | 本地 noVNC/Caddy 认证入口端口 |
| — | `VNC_BACKEND_PORT` | `18080` | 本地 websockify 后端端口，仅监听回环地址 |
| — | `LOCAL_SSH_PORT` | `22` | 本地 SSH 端口 |
| — | `QWENPAW_PORT` | `8088` | 本地 QwenPaw 面板端口 |
| — | `CDP_PORT` | `9222` | 本地 Chromium CDP 调试端口 |
| — | `BACKUP_INTERVAL` | `1800` | 数据备份间隔（秒） |
| — | `NAS_RESTORE_TIMEOUT` | `120` | NAS 恢复单次最大等待秒数，超时跳过并继续部署 |
| — | `SKIP_NAS_RESTORE` | `0` | 设为 `1` 跳过 NAS 恢复 |

> ⚠️ `-p` 和 `-P` 都是共用密码，大小写通用；FRP 监听端口使用 `-f/--frp-port`，默认 `7000`。`-q` 是 QwenPaw 公网端口，并会默认推导 SSH 公网端口为 `-q` 减 1；`-S 0` 可关闭 SSH，VNC 默认开启，传 `-v 0` 才关闭。

---

## 🏗️ 架构

```
你的手机/电脑 (noVNC 网页)
        │
        ▼
公网 VPS: frps 服务端 (端口 7000)
        │  frp 隧道
        ▼
本机 frpc ──▶ Caddy :8080 (完整密码认证)
                 │
                 ▼
          websockify :18080 (仅回环)
                 │
                 ▼
          Xvnc :5900 (SecurityTypes None)
                 │
                 ▼
             Xvnc :1 (720x1280 虚拟屏幕)
                 ├── openbox 桌面
                 └── chromium-gui (全屏浏览器, 数据存 NAS)
```

所有进程由 **supervisor** 托管，开机自启、崩溃自动拉起。qwenpaw 数据每 30 分钟自动备份到 NAS，重启自动恢复。

**浏览器工作模式：**

| 模式 | 端口 | 用途 | 浏览器进程 |
|--------|------|------|------|
| 启用 `-v` | noVNC + `9222` | 手机/电脑通过 noVNC 操作；QwenPaw browser-use 通过 `connect_cdp` 控制同一个窗口 | 只有一个有头 `chromium-gui` |
| 未启用 `-v` | `9222`（本机） | 没有远程桌面时给 browser-use 使用 | 一个独立的无头 Chromium |

> 💡 启用 VNC 时，手动操作和 AI 操作作用于同一个 Chromium 会话，不会再额外启动第二个无头浏览器。脚本会备份并更新 QwenPaw 的 `browser` 配置为 `backend=connect_cdp`、`cdp_url=http://127.0.0.1:9222`；手机/电脑布局由 Xvnc 分辨率和 `/mnt/envd/vnc-browser/vnc-resize.sh` 控制。若 QwenPaw 配置不在默认位置，可通过 `QWENPAW_CONFIG_FILE` 指定。

---

## 📜 致谢

- [fatedier/frp](https://github.com/fatedier/frp) — 内网穿透核心工具，AGPL-3.0 开源
- [@eooce](https://github.com/eooce) — frp 一键安装脚本 `frp.sh`，让服务端/客户端安装变成一行命令，感谢！
- **SAP-Auto-deploy-Firefox** — 容器化部署 Firefox + VNC 的自动部署参考项目（未公开），本项目 noVNC/Xvnc 布局与 supervisor 管理方式借鉴自它，感谢！

---

## ⚠️ 免责声明

本项目为**个人学习交流**用途，按现状提供（AS-IS），不附带任何明示或暗示的担保。

**安装与运行提醒：**

- 首次安装会自动检查并补齐 Chromium、FRP、Xvnc、桌面环境及 supervisor 等依赖，整个过程可能持续较长时间，通常约 **30 分钟**；不同机器的网络、磁盘和软件源速度可能导致实际时间更长，请耐心等待；
- 安装过程中可能长时间停留在下载、解包或系统软件包配置阶段，请耐心等待，不要中途强制终止、断电或同时启动第二个安装进程，以免留下未完成的服务配置；
- 脚本会修改系统软件包、SSH、supervisor、桌面和网络转发配置，存在环境冲突、服务异常，甚至俗称“炸机”的风险。请在可恢复、可备份的环境中使用，并自行承担由此产生的风险；
- 本项目与 **redene** 项目无关。遇到本项目的安装或运行问题，请在本项目仓库反馈，不要误向 redene 项目寻求支持，也不要将两个项目混为一谈。

**请务必保护好自己的浏览器与会话环境：**

- 浏览器（尤其是 noVNC 暴露的桌面）被他人进入后，**可能被窃取登录态、Cookie 与各类 token**（包括 QwenPaw / AI 服务 / 其他网站的凭据）；
- noVNC 使用 VNC 密码认证，但公网暴露仍有风险；
- 建议：使用 `-p` 或 `-P` 设置必填的 SSH/VNC 共用密码、通过 Cloudflare Access 加一层认证、或仅暴露在可信网络内；
- frp token 等同于内网钥匙，不要提交到公开仓库，也不要截图或转发；
- 使用本脚本造成的任何直接或间接损失（账号被盗、数据丢失、服务被滥用、系统异常或俗称“炸机”等），作者概不负责。

> 本项目定位是**学习与实验**，非商用。请在理解风险后再使用。

---

## 📄 License

[MIT](LICENSE)
