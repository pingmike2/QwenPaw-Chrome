# 心得：学 jlesage/docker-chromium 的 VNC/HTML 架构（v4 学习记录）

> 2026-08-14 · chromium-QwenPaw v4
> 核心一句话：**把 jlesage 的 docker-chromium（GitHub 30★ 的 Chromium Docker 容器）源码拆开学习，它是"Xvnc + nginx + noVNC"一体架构，跟我们的"Xvfb + x11vnc + websockify"是两条不同路线，学完收获 5 个可借鉴点。**

---

## 一、为什么学它

用户甩来两个参考：

1. **SAP-Auto-deploy-Firefox**（我们的前身仓库）—— 回忆里已确认它的处置：改造为 Chromium 版演变成现在的 chromium-QwenPaw；隧道机制不搞 Release.yml，改 `start_cloudflared.py` 直连 pingmike2 的 `so-files-latest` Release（commit `c57d450`，最终 7 文件零 workflow）。
2. **Pterodactyl-Browser 的 chrome.sh** —— 当时为排查"链接被拒绝/密码不对/鉴权问题"拿来做参照，它用 `-SecurityTypes None` 无密码直进；我们没照搬，后来升级为真密码认证（`x11vnc -passwdfile`，commit `b659a5b`）。

而 **jlesage/docker-chromium** 是 Docker 生态里最成熟的 Chromium 容器方案之一，用户点名要学习它的 VNC/HTML 是怎么做的。

## 二、它的完整架构（源码拆解）

### 1. 分层：docker-chromium 只负责 Chromium，底层是 baseimage-gui

```
jlesage/docker-chromium          ← 薄薄一层: 装 chromium + startapp.sh + socat
        └─ jlesage/baseimage-gui ← 真正的 VNC/HTML 全家桶 (Xvnc/nginx/noVNC/openbox/s6)
```

docker-chromium 自己的 `Dockerfile` 只有 3 件事：装 chromium、拷 `rootfs/startapp.sh`、加 socat。**所有 VNC 逻辑都在 baseimage-gui 里**——学 VNC 方案要看 `docker-baseimage-gui`，它才是核心。

### 2. 进程链路（对比我们）

```
jlesage 方案:
浏览器 ──▶ :5800 nginx ──websockify_pass──▶ unix:/tmp/vnc.sock ──▶ Xvnc (:0)
                 │                                                       │
                 └─ 定制 noVNC 前端(控制面板/剪贴板/缩放/文件管理/终端)     └─ TigerVNC 一体: X server + VNC server

我们的方案:
浏览器 ──▶ :8080 websockify(Python) ──▶ :5900 x11vnc ──▶ :1 Xvfb ── xfce4 桌面
```

关键差异：**jlesage 用 Xvnc 一个进程同时当 X server 和 VNC server**（省 2 个进程），我们用 Xvfb + x11vnc 两个进程（但桌面能力更强，是完整 xfce4）。

### 3. Xvnc 参数（`rootfs/etc/services.d/xvnc/params`）

```bash
echo "-rfbunixpath=/tmp/vnc.sock"      # 只监听 unix socket, 不直接开 TCP
echo "-rfbunixmode=0660"
echo "-rfbport=${VNC_LISTENING_PORT:-5900}"   # 5900 端口按需开
echo "-SecurityTypes=VncAuth"           # 有密码: VncAuth; 无密码: None
echo "-rfbauth=${PASSWORD_FILE}"        # /config/.vncpass 或 /tmp/.vncpass
echo "-geometry ${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"   # 1920x1080 默认
echo "${DISPLAY}"                       # :0
```

亮点：**VNC 默认走 unix socket，TCP 5900 按需开**。nginx 通过 websockify 模块读 unix socket，比我们"websockify 转发到 TCP 5900"少一跳、更安全。

### 4. nginx 做 WebSocket 桥（零额外进程）

```nginx
# rootfs/opt/base/etc/nginx/include/vnc.conf
location ~ /websockify$ {
    websockify_pass unix:/tmp/vnc.sock;
    websockify_read_timeout 5d;
    websockify_send_timeout 5d;
}
```

nginx 内置 websockify 模块直接把 HTTP 升级请求转发到 VNC unix socket。**没有独立的 websockify Python 进程**，省内存还少一个故障点。前端 noVNC 从 `rootfs/opt/noVNC/` 提供。

### 5. 密码机制（`cont-init.d/10-vnc-password.sh`）

```bash
# 支持两种来源
VNC_PASSWORD 环境变量 → echo | vncpasswd -f > /tmp/.vncpass
/config/.vncpass_clear 明文文件 → vncpasswd -f 混淆成 /config/.vncpass

# 最后 chmod 400 + chown USER_ID:GROUP_ID
```

跟我们 `x11vnc -passwdfile`（明文第一行）本质等价，但它是**用 vncpasswd 加密成 DES 混淆格式**，且权限 400 更严格。

### 6. 安全矩阵（比我们完整）

| 特性 | 说明 |
|---|---|
| `VNC_PASSWORD` | 基础 VNC 密码（VncAuth） |
| `SECURE_CONNECTION=1` | HTTPS + VNC 可走 TLS/SSL（`-SecurityTypes=X509Vnc,TLSVnc`） |
| `WEB_AUTHENTICATION=1` | **nginx 层加登录页** + 24h token（bcrypt htpasswd，支持多用户） |
| `VNC_LOCALHOST_ONLY` / `WEB_LOCALHOST_ONLY` | 只允许 localhost |
| 证书 | `/config/certs/` 自动生成 self-signed，可替换 |

### 7. 其他亮点

- **openbox** 当窗口管理器（比 xfce4 轻得多，适合"单窗口应用"场景）
- **CDP 用 socat 桥**：chromium 开 9223，`socat TCP-LISTEN:9222,fork TCP:127.0.0.1:9223` 暴露，多一层隔离
- **noVNC 前端增强**：控制面板带缩放三档（None / Local Scaling / **Remote Scaling**——远端自动改 Xvnc 分辨率适配窗口）、剪贴板同步、音频（pulseaudio→WebRTC）、文件管理器、Web 终端
- **s6 服务托管**（类似我们的 supervisor），每个服务有 `run/params/is_ready/respawn` 四件套

## 三、跟我们的方案对比总结

| 维度 | jlesage (Xvnc+nginx) | 我们 (Xvfb+x11vnc+websockify) |
|---|---|---|
| X server + VNC | Xvnc 一体，省进程 | Xvfb + x11vnc 两个进程 |
| WebSocket 桥 | nginx 内置模块，零进程 | **自带 Python websockify 进程**（已跑稳，保持现状） |
| 窗口管理 | openbox（轻） | xfce4（完整桌面） |
| 密码 | vncpasswd DES 混淆，chmod 400 | passwdfile 明文，chmod 600 |
| 网页登录层 | ✅ `WEB_AUTHENTICATION` 登录页+token | ❌ 无（只有 VNC 密码） |
| HTTPS/VNC 加密 | ✅ `SECURE_CONNECTION` | ❌ 无（frp 裸 HTTP） |
| CDP 暴露 | socat 桥隔离 | chromium 直监听 9222 |
| 缩放 | 三档含 Remote Scaling | 固定 local scale |
| 持久化 | /config 卷 | NAS 目录 |
| 服务托管 | s6 | supervisor |

## 四、4 个可借鉴点（按价值排序）

1. **`WEB_AUTHENTICATION` 网页登录层** ⭐⭐⭐ —— 我们 frp 把 noVNC 暴露公网，目前只有 VNC 密码、网页入口无鉴权。jlesage 在 nginx 层加登录页 + 24h token，正好补上这块短板。
2. **Remote Scaling 远端缩放** ⭐⭐⭐ —— noVNC 控制面板可切换"远端缩放"（自动改 Xvnc 分辨率适配浏览器窗口），比固定 local scale 灵活，手机/电脑切换更舒服。
3. **Xvnc 一体架构** ⭐⭐ —— 场景是"单窗口应用"时更省；但我们跑完整 xfce4 桌面，Xvfb+x11vnc 是合理选择，不必迁移。
4. **socat CDP 桥 + 证书/HTTPS** ⭐ —— CDP 多一层隔离、公网入口可上 HTTPS，都是后续可加的安全项。

> **不采纳：nginx websockify 模块** —— jlesage 用 nginx 内置模块做 WebSocket 桥（省一个 Python websockify 进程），但我们**自带 Python websockify** 且已跑稳，没必要为了省一个进程去装带该模块的 nginx，保持现状。

## 五、结论

- **架构选型没有对错**：jlesage 为"一个单窗口应用"优化（轻、省、安全），我们为"完整 Linux 桌面 + AI 自动化"优化（强、全、可控），各自场景合理。
- **最值得动手**：网页登录层（WEB_AUTHENTICATION 思路）—— 直接提升公网 noVNC 的安全性，且实现不复杂（nginx 或 frp 前置加一道）。
- 参考资料：github.com/jlesage/docker-chromium（30★）· github.com/jlesage/docker-baseimage-gui
