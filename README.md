# chromium-QwenPaw — frp 一键部署 QwenPaw + 云端 Chromium 浏览器

在一台已经安装 QwenPaw 的 **Debian/Ubuntu Linux 机器**（包括 NAT 内网 / 无公网 IP 的机器）上，用 **frp 内网穿透**把以下服务安全暴露到公网：

- 🤖 **QwenPaw**：你的 AI 助手（面板 Web 界面）
- 🖥 **Chromium 云端浏览器**：xfce4 桌面 + 全屏 Chromium，通过 **noVNC 网页**远程操作，**手机/电脑都能用**
- 🔑 **SSH**（可选）：远程登录

> 只需传 3 个参数（`-s` 服务器IP / `-t` TOKEN / `-q` 公网端口）。目标机器只要已经安装 QwenPaw，`install.sh` 会自动补齐 Chromium、CDP 以及可选的 Xvfb/xfce4/noVNC 运行依赖，再完成 FRP、supervisor 托管和数据备份。

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

按菜单选 **1 安装 FRP 服务端 (公网服务器)**，脚本会输出 3 个信息（后面要用）：
- `监听IP`（服务器公网 IP）
- `监听端口`（默认 `7000`）
- `认证TOKEN`（随机生成的一串）

> frp.sh 由 [@eooce](https://github.com/eooce) 维护，一键装 frps/frpc，感谢！

### 第 1 步（唯一一步）：一键部署（一条命令，无需手动下载）

直接把这行命令输入终端 / 交给 QwenPaw AI 助手执行，自动下载 `install.sh` 并运行：

**极简版**（只用 3 个必填值）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) -s 你的VPS公网IP -t 你的TOKEN -q 10000
```

**完整版**（带 noVNC 桌面 / SSH / 分辨率选项）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) \
  -s 你的VPS公网IP \
  -t 你的TOKEN \
  -q 10000 \
  -v 20000 \
  -S 20022 \
  -r 720x1280
```

> 💡 `bash <(curl -fsSL ...)` 会边下载边执行，不留临时文件；等价于手动 `curl -o install.sh` + `bash install.sh` 两步。

| 参数 | 环境变量 | 对应 frp.sh 输出 | 说明 |
|------|---------|-----------------|------|
| `-s` | `FRP_SERVER_IP` | 「监听IP」 | frp 服务端公网 IP (**必填**) |
| `-t` | `FRP_TOKEN` | 「认证TOKEN」 | 与服务端一致的 token (**必填**) |
| `-q` | `QWENPAW_REMOTE_PORT` | 自己定 | QwenPaw 面板公网端口 (**必填**) |
| `-p` | `FRP_SERVER_PORT` | 「监听端口」 | frp 服务端监听端口 (默认 `7000`) |
| `-v` | `FRP_VNC_REMOTE_PORT` | 自己定 | noVNC 公网映射端口 (默认空=不建 VNC 隧道) |
| `-S` | `FRP_SSH_REMOTE_PORT` | 自己定 | SSH 公网映射端口 (默认空=不建 SSH 隧道) |
| `-r` | `RESOLUTION` | — | 桌面分辨率 (默认 `720x1280` / 电脑 `1280x720`) |
| `-h` | — | — | 查看全部帮助 |

> 💡 脚本完全**无交互**：参数或环境变量传完就跑，不会卡住等输入。适合脚本/CI 自动化调用。

脚本自动完成：

| 步骤 | 说明 |
|------|------|
| 📥 自动下载 frpc | 从 fatedier/frp 官方 Release 下载，自动匹配 Linux 架构（amd64/arm64/arm...） |
| 🔍 chromium CDP 检测修复 | browser_use 依赖（默认 9222 端口），有问题先修好 |
| 📂 NAS 路径自动探测 | 自动找持久化路径，找不到就 fallback 本地 |
| 📝 生成 frpc.toml | 按你填的变量生成隧道配置 |
| ⚙️ supervisor 托管 | 全部服务开机自启、崩溃自动拉起 |
| 💾 数据定时备份 | qwenpaw 数据每 30 分钟同步到 NAS，重启自动恢复 |

### 部署完成后访问

```
🌐 QwenPaw 面板: http://FRP_SERVER_IP:QWENPAW_REMOTE_PORT
🖥  noVNC 浏览器: http://FRP_SERVER_IP:FRP_VNC_REMOTE_PORT/vnc.html   (配了 FRP_VNC_REMOTE_PORT 才有, 自适应缩放)
🔑 SSH:          ssh -p FRP_SSH_REMOTE_PORT root@FRP_SERVER_IP (配了 FRP_SSH_REMOTE_PORT 才有)
```

> 💡 noVNC 访问根路径 `/` 会自动跳转到 **Local Scaling 自适应缩放**模式——电脑/手机窗口拉多大，桌面自动缩放填满。也可以直接访问 `/vnc.html`。

### 验证部署成功（3 个检查）

| 检查 | 命令 | 期望结果 |
|------|------|---------|
| ① 服务状态 | `supervisorctl status` | 7 个服务全部 `RUNNING`：`frpc xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup` |
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
| **Destination Port** | `你的QWENPAW_REMOTE_PORT`（如 10000） |

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
- **面板能开但 noVNC 白屏？** 检查 `FRP_VNC_REMOTE_PORT` 是否部署时配了（没配 `-v` 就没有 noVNC 隧道）。
- **CF 缓存奇怪内容？** QwenPaw/noVNC 这种动态服务建议在 Origin Rule 对应页面的 Cache Rules 里设为 **Bypass**（不缓存）。
- **想要 www/根域名？** 在 Cloudflare `Redirect Rules` 加一条 301 跳转到子域名即可。

---

## 🔧 常见问题排查

| 现象 | 原因 & 解决 |
|------|------------|
| `supervisorctl status` 里某服务 `FATAL` | 看日志：`tail -50 /var/log/<服务名>.err.log`（如 `frpc.err.log`）。最常见是 frpc 连不上 VPS：核对 `-s`/`-t` 与 frp.sh 输出是否一致；VPS 防火墙/安全组是否放行 7000 |
| qwenpaw 面板打不开 | 先 `curl -s http://127.0.0.1:8088/` 看本地是否正常 → 本地通但公网不通，检查 `-q` 端口是否被占用、VPS 是否放行该端口 |
| noVNC 连不上 / 白屏 | 确认部署时加了 `-v`（没配就没有 VNC 隧道）；浏览器开不了 WebSocket（公司网络/代理）换手机流量试；xfce4 桌面没起来看 `xvfb`/`xfce4` 服务状态 |
| 手机打开 noVNC 但桌面是 1280x720 | 部署时没用 `-r 720x1280`，改分辨率需重新执行一键命令并换 `-r` 参数（幂等，会自动更新配置） |
| 重跑部署命令会不会搞坏？ | **不会**。脚本幂等：已有配置自动跳过、服务已在跑就跳过启动，放心重复执行 |
| 想换 VPS / 换 token | 重新执行部署的一键命令并换成新 IP / 新 TOKEN / 新端口即可，frpc 配置会自动重建 |

### ⚠️ 安全提示

- **noVNC 默认无密码**（`x11vnc -nopw`），公网端口暴露后**任何人都能打开你的桌面**。建议：
  1. 只把 noVNC 端口暴露给可信网络，或
  2. 用 Cloudflare Access（Zero Trust 免费版）在域名前加一道登录认证，或
  3. 部署后手动 `export DISPLAY=:1 && x11vnc -storepasswd` 给 VNC 加密码
- frp token 相当于你内网的所有钥匙，**别提交到公开仓库 / 别截图发群里**。
- SSH 隧道（`-S`）公网开放 root 登录风险高，建议只在你需要远程管理时才开，并优先改用密钥登录。

---

## ⚙️ 可配置项（命令行参数 / 环境变量）

| 参数 | 环境变量 | 默认值 | 说明 |
|------|---------|--------|------|
| `-S` | `FRP_SSH_REMOTE_PORT` | 空 | SSH 公网映射端口（留空 = 不建 SSH 隧道） |
| `-v` | `FRP_VNC_REMOTE_PORT` | 空 | noVNC 公网映射端口（留空 = 不建 VNC 隧道） |
| `-r` | `RESOLUTION` | `720x1280` | 桌面分辨率（手机竖屏 720x1280 / 电脑横屏 1280x720） |
| — | `VNC_PORT` | `8080` | 本地 noVNC 端口 |
| — | `QWENPAW_PORT` | `8088` | 本地 qwenpaw app 端口 |
| — | `BACKUP_INTERVAL` | `1800` | 数据备份间隔（秒） |
| — | `CDP_PORT` | `9222` | chromium CDP 调试端口 |

---

## 🏗️ 架构

```
你的手机/电脑 (noVNC 网页)
        │
        ▼
公网 VPS: frps 服务端 (端口 7000)
        │  frp 隧道
        ▼
本机 frpc ──▶ websockify :8080 (noVNC 网页)
                 │
                 ▼
             x11vnc :5900
                 │
                 ▼
             Xvfb :1 (720x1280 虚拟屏幕)
                 ├── xfce4 桌面
                 └── chromium-gui (全屏浏览器, 数据存 NAS)
```

所有进程由 **supervisor** 托管，开机自启、崩溃自动拉起。qwenpaw 数据每 30 分钟自动备份到 NAS，重启自动恢复。

**两个浏览器各司其职：**

| 浏览器 | 端口 | 用途 | 模式 |
|--------|------|------|------|
| `chromium-gui` | Xvfb 虚拟屏 | 你在 noVNC 里看到/操作的全屏浏览器，数据存 NAS | 有头（可视化） |
| `chromium-cdp` | `9222` | QwenPaw 里 browser_use 自动化用的调试浏览器 | 无头 headless |

> 💡 两者独立：你在 noVNC 里手动点的页面，和 AI 自动化打开的页面互不干扰。

---

## 📜 致谢

- [fatedier/frp](https://github.com/fatedier/frp) — 内网穿透核心工具，AGPL-3.0 开源
- [@eooce](https://github.com/eooce) — frp 一键安装脚本 `frp.sh`，让服务端/客户端安装变成一行命令，感谢！

---

## ⚠️ 免责声明

本项目为**个人学习交流**用途，按现状提供（AS-IS），不附带任何明示或暗示的担保。

**请务必保护好自己的浏览器与会话环境：**

- 浏览器（尤其是 noVNC 暴露的桌面）被他人进入后，**可能被窃取登录态、Cookie 与各类 token**（包括 QwenPaw / AI 服务 / 其他网站的凭据）；
- noVNC 默认**无密码**，只要暴露公网端口就有被任意人打开的风险；
- 建议：部署后立即给 VNC 设置访问密码（`x11vnc -storepasswd`）、通过 Cloudflare Access 加一层认证、或仅暴露在可信网络内；
- frp token 等同于内网钥匙，不要提交到公开仓库，也不要截图或转发；
- 使用本脚本造成的任何直接或间接损失（账号被盗、数据丢失、服务被滥用等），作者概不负责。

> 本项目定位是**学习与实验**，非商用。请在理解风险后再使用。

---

## 📄 License

[MIT](LICENSE)
