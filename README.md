# chromium-QwenPaw — QwenPaw + VNC 云端 Chromium 浏览器（本地直连部署）

在一台 Linux 机器（NAS / 云主机 / 内网机器）上，一键部署 **QwenPaw AI 助手** + **云端 Chromium 浏览器**（xfce4 桌面 + noVNC 网页远程操作，手机/电脑都能用），**无需 FRP 隧道**，服务直接跑在本机端口。

- 🤖 **QwenPaw**：你的 AI 助手（面板 Web 界面，默认 `8088`）
- 🖥 **Chromium 云端浏览器**：xfce4 桌面 + 全屏 Chromium，通过 **noVNC 网页**（默认 `8080`）远程操作
- 🎯 **人机同屏**：AI 自动化用的 chromium（CDP 9222）直接显示在 VNC 桌面——AI 在浏览器里做什么，你实时看得到

> 一条命令 `bash install.sh` 即完成：chromium CDP 修复、NAS 持久化探测、supervisor 托管、开机自启、数据定时备份。

---

## 🚀 快速开始

```bash
# 1. 下载 install.sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/yanyumm1/chromium-QwenPaw/main/install.sh

# 2. 一键部署（无交互，默认 720x1280 竖屏）
bash install.sh

# 可选参数
bash install.sh -P mypass -r 1280x720    # 改密码 + 电脑横屏
CDP_HEADED=0 bash install.sh             # chromium-cdp 无头模式（省内存）
```

| 参数 | 环境变量 | 默认值 | 说明 |
|------|---------|--------|------|
| `-P` | `PASSWORD` | `browser123` | VNC 密码 + SSH root 密码（统一） |
| `-r` | `RESOLUTION` | `720x1280` | 桌面分辨率（手机竖屏 720x1280 / 电脑横屏 1280x720） |
| `-V` | `VNC_PORT` | `8080` | 本地 noVNC 端口 |
| `-Q` | `QWENPAW_PORT` | `8088` | 本地 qwenpaw 面板端口 |
| `-h` | — | — | 查看帮助 |

### 部署完成后访问

```
🖥  noVNC 浏览器桌面: http://localhost:8080/vnc.html   (密码 = PASSWORD)
🌐 QwenPaw 面板:      http://localhost:8088
🌐 chromium CDP:      ws://localhost:9222 (browser_use 自动化用)
```

> 💡 noVNC 访问根路径 `/` 会自动跳转到 **Local Scaling 自适应缩放**模式——窗口拉多大，桌面自动缩放填满。也可以直接访问 `/vnc.html`。

### 需要公网访问？

本项目不包含隧道——如果机器有公网 IP / 已做端口映射，直接访问 `http://机器IP:8080` 即可；如果是内网机器，可自行套 **frp / Cloudflare Tunnel / tailscale** 等任一方案把 `8080`/`8088` 暴露出去（本项目只管本地服务）。

---

## 脚本自动完成

| 步骤 | 说明 |
|------|------|
| 🔍 chromium CDP 检测修复 | browser_use 依赖（默认 9222 端口），有问题先修好 |
| 🔧 Xvnc 检测安装 | 缺 tigervnc 自动 apt 安装（动态分辨率架构） |
| 📂 NAS 路径自动探测 | 自动找持久化路径（`/run/csi/mount-root/nas/*`、`/mnt/nas` 等），找不到 fallback 本地 |
| ⚙️ supervisor 托管 | 全部服务开机自启、崩溃自动拉起 |
| 💾 数据定时备份 | qwenpaw 数据每 30 分钟同步到 NAS，重启自动恢复 |

### 验证部署成功（3 个检查）

| 检查 | 命令 | 期望结果 |
|------|------|---------|
| ① 服务状态 | `supervisorctl status` | 6 个服务全部 `RUNNING`：`xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup` |
| ② noVNC 本地 | `curl -s http://127.0.0.1:8080/` | 返回 noVNC 页面 HTML |
| ③ 面板本地 | `curl -s http://127.0.0.1:8088/` | QwenPaw 面板能打开 |

### 一键卸载 / 清理

```bash
supervisorctl stop all && supervisorctl shutdown   # 停止全部服务
rm -rf /etc/supervisor/conf.d/*.conf              # 删 supervisor 托管
# 可选: 删除本地服务数据 (默认路径 /app/working, 按实际调整)
rm -rf /app/working /app/working.secret
```

> ⚠️ 删除前确认数据已备份到 NAS（`NAS_BASE_DIR/qwenpaw-data`），卸载不会动 NAS 备份，重装后自动恢复。

---

## 🔧 常见问题排查

| 现象 | 原因 & 解决 |
|------|------------|
| `supervisorctl status` 里某服务 `FATAL` | 看日志：`tail -50 /var/log/<服务名>.err.log`（如 `xvfb.err.log`、`vnc-browser.err.log`） |
| noVNC 打不开 / 白屏 | 先 `curl -s http://127.0.0.1:8080/` 看本地是否通；再确认 `xvfb` / `xfce4` / `vnc-browser` 服务都在 RUNNING；浏览器开不了 WebSocket（公司网络/代理）换手机流量试 |
| noVNC 打开是**纯白**（桌面啥都没有） | 多半是**孤儿 chromium 抢屏**：`supervisorctl stop chromium-gui` 只杀脚本壳，`&` 后台起的 chromium 变孤儿继续占桌面。用 `DISPLAY=:1 xdotool search --onlyvisible --name ".*"` 看有几个窗口，`pkill -f "chromium-gui-profile"` 精准清理。有头模式正常只该有 chromium-cdp 窗口 |
| 手机打开 noVNC 但桌面是 1280x720 | 部署时没用 `-r 720x1280`，改分辨率需重新执行 `bash install.sh`（幂等，会自动更新配置） |
| 重跑 install.sh 会不会搞坏？ | **不会**。脚本幂等：已有配置自动跳过、服务已在跑就跳过启动，放心重复执行 |
| 刚才还能打开 Chrome 应用商店，现在跳到 unsupported | 商店只支持桌面浏览器访问。若 chromium 挂了手机 UA（旧版曾加 `--user-agent` 伪装），移除该参数即可；本版本默认不带 UA 伪装 |

### ⚠️ 安全提示

- **noVNC 默认带密码**（默认 `browser123`，可用 `-P` 修改）。如果端口暴露到公网，**任何人知道密码都能打开你的桌面**，建议：
  1. 用 `-P` 设强密码，别用默认的，或
  2. 只把 noVNC 端口暴露给可信网络，或
  3. 用 Cloudflare Access / tailscale 等在前面加一道认证
- QwenPaw 面板（8088）同样建议设强密码 / 加访问控制后再暴露公网。

---

## ⚙️ 可配置项（命令行参数 / 环境变量）

| 参数 | 环境变量 | 默认值 | 说明 |
|------|---------|--------|------|
| `-P` | `PASSWORD` | `browser123` | 统一密码：VNC 密码 + SSH root 密码 |
| `-r` | `RESOLUTION` | `720x1280` | 桌面分辨率（手机竖屏 720x1280 / 电脑横屏 1280x720） |
| `-V` | `VNC_PORT` | `8080` | 本地 noVNC 端口 |
| `-Q` | `QWENPAW_PORT` | `8088` | 本地 qwenpaw app 端口 |
| — | `BACKUP_INTERVAL` | `1800` | 数据备份间隔（秒） |
| — | `CDP_PORT` | `9222` | chromium CDP 调试端口 |
| — | `CDP_HEADED` | `1` | chromium-cdp 模式：`1`=有头（VNC 可见，人机同屏）`0`=无头（省内存） |
| — | `CDP_START_URL` | Tampermonkey 商店 | chromium-cdp 有头模式的启动页 |

---

## 🏗️ 架构

```
你的手机/电脑 (noVNC 网页)
        │
        ▼
本机 websockify :8080 (noVNC 网页)
        │
        ▼
本机 Xvnc :5900 (TigerVNC, 720x1280 虚拟桌面, 支持动态分辨率)
        │
        ├── xfce4 桌面
        └── chromium-cdp (有头, CDP 9222, 人机同屏)
             └── QwenPaw browser_use 自动化操作同一个浏览器
```

所有进程由 **supervisor** 托管，开机自启、崩溃自动拉起。qwenpaw 数据每 30 分钟自动备份到 NAS，重启自动恢复。

**浏览器架构（v2 有头合一模式，默认）：**

| 浏览器 | 端口 | 用途 | 模式 |
|--------|------|------|------|
| `chromium-cdp` | `9222` | QwenPaw 里 browser_use 自动化用的调试浏览器，**同时显示在 noVNC 桌面**——AI 在浏览器里做什么，你实时看得到 | 有头（可视化，默认） |
| `chromium-gui` | Xvnc 虚拟屏 | 独立展示浏览器（默认 Tampermonkey 商店，`exec` 前台直启防孤儿进程），仅当 `CDP_HEADED=0` 时才自动启动 | 有头（可选） |

> ✨ **核心体验**：默认 `CDP_HEADED=1`，AI 自动化用的 chromium 直接以**完整浏览器界面**（标签栏+地址栏）显示在 VNC 桌面上，启动页默认 **Tampermonkey 扩展商店**（可 `CDP_START_URL` 自定义）。你在 noVNC 里看到的，就是 AI 正在操作的同一个浏览器——**人机同屏**，AI 点哪你都能看到。
>
> 💡 想省内存纯后台自动化？`CDP_HEADED=0 bash install.sh` 切回无头模式，VNC 桌面显示独立的 chromium-gui。

---

## 💡 关于 Tampermonkey 油猴脚本

默认启动页就是 **Tampermonkey 扩展商店**（`https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo`），在 noVNC 里打开后点「添加至 Chrome」即可安装。安装后浏览器地址栏右侧会出现油猴图标，再安装其他用户脚本（如从脚本网站点安装、或者用管理面板导入 .user.js）。

> ⚠️ Chrome 应用商店只支持**桌面浏览器**访问，所以在 VNC 浏览器（原生桌面 Chromium）里能正常打开、安装；请不要给 chromium 配手机 UA 伪装，否则商店会跳到 unsupported。

---

## 📓 心得合集

把这个仓库从 v1 到 v7 的全部改造过程、踩坑、架构演进整理成了一份完整文档：

- [`心得合集-v2到v7.md`](心得合集-v2到v7.md) —— 人机同屏（CDP 有头化）→ 一端口三服务 → jlesage 方案学习 → Xvnc 动态分辨率 → 白屏/孤儿进程排查 → 移动端适配（iOS Safari / 商店 UA / 去隧道 / 状态栏优化）→ 考古

---

## 📜 License

[MIT](LICENSE)
