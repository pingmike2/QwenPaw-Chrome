# EXPERIENCE.md — 实际部署踩坑与心得

> 本文记录在真实容器环境（QwenPaw / Debian 12 bookworm）中部署 `QwenPaw-Chrome`
> 时踩过的坑、排查过程和最终方案。每一条都对应过一次真实事故，不只是理论建议。
> 更新时间：2026-08

---

## 1. VNC 认证：`-SecurityTypes None` 的教训

**问题**：第一版部署用 `-SecurityTypes None`（无认证）+ Caddy 表单登录保护 noVNC。
结果在容器里 Caddy 需要完整版（含 basic_auth），而 Debian 源的精简版缺模块，
认证链经常断，且公网 30208 只要链接泄露就等于把浏览器桌面裸奔给别人。

**结论**：**Xvnc 的 VncAuth（VNC 协议密码）是最轻量、最可靠的方案** ——
不需要额外后端，noVNC 原生弹密码框，端口 30208/30209/30210 共用同一个密码。

**关键命令**：

```bash
# 生成 VNC 密码文件（vncpasswd 必须输入两次，且文件名固定在 /root/.vnc/passwd）
printf '%s\n%s\n' "$PASS8" "$PASS8" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

# Xvnc 启动参数（注意两个都缺一不可）
/usr/bin/Xvnc :2 -geometry 720x1280 -depth 24 \
  -SecurityTypes VncAuth \
  -PasswordFile /root/.vnc/passwd \
  -localhost -AlwaysShared -rfbport 5900
```

---

## 2. vncpasswd 生成的文件可能是 8 字节垃圾

**问题**：`echo 'mypass' | vncpasswd -f > /root/.vnc/passwd` 只写一次输入，
生成的文件只有 **8 字节**。Xvnc 读它时直接报：

```
SVncAuth:    neither Password nor PasswordFile params set
SConnection: AuthFailureException: Authentication failure: No password configured for VNC Auth
```

**原因**：vncpasswd 的 `-f` 需要从 stdin **连续读取两次相同密码**才算确认；
只 echo 一次会被当作"输入被中断"，产出半截文件。`[ -s file ]` 只判断非空，
8 字节文件照样通过检查，直到 Xvnc 握手才暴露。

**修复**（install.sh 已内置）：

```bash
# 必须两次输入 → 16 字节文件；并且要校验大小而不是只判断非空
if [ ! -f /root/.vnc/passwd ] || [ "$(stat -c%s /root/.vnc/passwd)" -ne 16 ]; then
  echo "❌ VNC 密码文件无效（应 16 字节）"
fi
```

**如何验证认证真的生效**（不用打开网页，一条 Python 握手即可）：

```python
import socket
s = socket.create_connection(('127.0.0.1', 5900), timeout=4)
s.recv(12); s.sendall(b'RFB 003.008\n')
cnt = s.recv(1)[0]
print("安全类型:", s.recv(cnt).hex())  # 02 = VncAuth ✅
s.sendall(b'\x02')                     # 客户端选择 VncAuth
ch = s.recv(16)                        # 必须收到 16 字节挑战
print("挑战就绪:", len(ch) == 16)
```

---

## 3. noVNC 状态栏："已链接(加密)" 去不掉

**问题**：手机/桌面打开 noVNC 后底部一直有「已连接(加密)」状态条，占空间、还容易误触。

**方案**（install.sh 已内置）：给 `vnc.html` 注入隐藏 CSS，页面加载自动隐藏：

```html
<style id="novnc-hide-status">
#noVNC_status{display:none!important;visibility:hidden!important}
#noVNC_status_bar{display:none!important}
</style>
```

---

## 4. supervisor 是容器 PID 1，socket 丢了却没法重启它

**问题**：容器里 `supervisord` 是 PID 1（`nodaemon=true`），一旦
`/var/run/supervisor.sock` 丢失（/run 是 tmpfs，某些清理或重启场景会丢），
`supervisorctl` 全部失败，但 **不能 kill PID 1 重启 supervisord**。

**排查路径**（重要）：

```bash
# 1. supervisord 在跑但 socket 不存在
ps -p 1 -o args=  # /usr/bin/python3 /usr/bin/supervisord -c /etc/supervisor/conf.d/supervisord.conf
ls /var/run/supervisor.sock  # No such file

# 2. 手动建 socket 文件没用 —— 它必须由 supervisord 进程创建
touch /var/run/supervisor.sock  # ✗ 不是真正的 unix socket

# 3. 结论：服务没法通过 supervisorctl 重启，只能绕过 supervisor 直接启动
nohup /usr/bin/Xvnc :2 ... &
nohup /usr/bin/websockify --web /usr/share/novnc 8080 localhost:5900 &
nohup /home/frp/frpc -c /home/frp/frpc.toml &
```

**install.sh 的应对**：探测 socket 失败后不再假装成功，而是
`direct_start_service()` 从 supervisor 配置段提取 `command=` / `environment=`
后用 nohup 直接拉起全部服务（见第 1187 行附近）。这样 supervisor 恢复时
autorestart 会接管，没恢复时服务也已经在跑。

**给脚本作者的提示**：不要在容器里 `service supervisor restart` 或
`kill -HUP 1` —— 会直接搞挂整个容器。用 `supervisorctl reread && update`
是唯一安全的配置热加载方式。

---

## 5. frpc 有两个实例会抢占公网端口

**问题**：容器之前遗留了一个老的 `./frpc -c ./frpc.toml`（相对路径从 /home/frp 起），
部署脚本又启动了新的 `/home/frp/frpc -c /home/frp/frpc.toml`。两个 frpc 同时
连接 frps 会抢 `remotePort`，公网端口时通时不通。

**排查**：

```bash
ps aux | grep "[f]rpc"            # 看到两个进程
ls -la /proc/<pid>/cwd            # 老进程 cwd = /home/frp
```

**修复**：先停光再起一个。install.sh 启动前会 `pkill -f "frpc"` 清理旧实例。

---

## 6. Chromium 会被 Xvnc 重启"带走"

**问题**：Chromium 跑在 Xvnc 的显示上，一旦 Xvnc 重启（比如换认证参数），
Chromium 进程会收到 X connection error 退出，CDP 9222 端口就没了，
`qwenpaw` 的主服务连不上浏览器。

**现象**：

```
[ERROR:ui/gfx/x/connection.cc:66] X connection error received.
```

**处理**：重启顺序必须是 **Xvnc 先起来 → 等 X socket → 再启动 Chromium**
（install.sh 的 `chromium-gui.sh` 启动时循环等待 `/tmp/.X11-unix/X${N}` 存在）。
如果服务已被 supervisor 托底，`autorestart=true` 会自动拉起；手动启动时
按 `Xvnc → openbox → websockify → frpc → chromium → qwenpaw` 顺序执行。

**验证 CDP 恢复**：

```bash
curl -s http://127.0.0.1:9222/json/version | grep -o '"Browser": "[^"]*"'
# => "Browser": "Chrome/151.0.7922.137"
```

---

## 7. Caddyfile 的 bcrypt hash 可能被截断

**问题**：旧版脚本在 Caddyfile 里硬编码了一段 hash，其中包含 `...`，
Caddy 启动直接失败 —— 登录认证形同虚设但不报错。

**修复**（install.sh 已内置）：运行时生成，绝不硬编码：

```bash
CADDY_HASH="$(caddy hash-password --plaintext "$PASSWORD")"
[ -n "$CADDY_HASH" ] || { echo "❌ Caddy hash 生成失败"; exit 1; }
```

---

## 8. 端口分工：本地端口不要跟公网端口混用

| 本地端口 | 用途 | 公网端口 | 说明 |
|---------|------|---------|------|
| `8080` (VNC_PORT) | Caddy noVNC 入口 | `30208` | Caddy `reverse_proxy 127.0.0.1:18080` |
| `18080` (VNC_BACKEND_PORT) | websockify 内部端口 | — | 不直接对公网 |
| `5900` (VNC_RFB_PORT) | Xvnc RFB | — | 只监听 localhost |
| `8089` (QWENPAW_CADDY_PORT) | Caddy basic_auth 入口 | `30210` | 反代到 8088 |
| `8088` (QWENPAW_PORT) | qwenpaw 主服务 | — | 只走 Caddy |
| `9222` (CDP_PORT) | Chromium DevTools | — | 只监听 127.0.0.1 |
| `22` | SSH | `30209` (= -v+1) | 与 VNC 共用密码 |

**关键点**：`websockify` 不该直接占公网映射的端口，让 Caddy 在前面做
转发/认证收口更干净；frpc 隧道只暴露 Caddy 的 8080/8089 和 SSH 22。

---

## 9. 一键安装脚本参数速查

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/install.sh) \
  -s <FRP_SERVER_IP> -f <FRP_PORT> -t <TOKEN> -v <VNC_PUBLIC_PORT> -p <PASSWORD>
```

| 参数 | 含义 |
|------|------|
| `-s` | frps 服务器地址 |
| `-f` | frps 监听端口 |
| `-t` | frp token |
| `-v` | noVNC 公网端口；SSH 自动=`-v+1`，QwenPaw 面板自动=`-v+2` |
| `-p` / `-P` | 共用密码（SSH 全量 / VNC 前 8 位 / QwenPaw basic_auth 全量） |
| `-S 0` | 关闭 SSH |
| `-q 0` | 关闭 QwenPaw 面板 |
| `-r WxH` | 分辨率，如 `-r 1280x720` |

---

## 10. 部署后必做的 3 个安全检查

1. **VNC 必须是 VncAuth**：Xvnc 启动参数含 `-SecurityTypes VncAuth -PasswordFile`，
   且浏览器打开 noVNC 会弹密码框（不是直接进桌面）。
2. **公网端口访问要有认证**：`curl -s -o /dev/null -w '%{http_code}'` 
   未带凭据访问 30210 应返回 `401`；带 `-u qwenpaw:密码` 返回 `200`。
3. **CDP 只监本机**：`curl 127.0.0.1:9222/json/version` 有响应；
   且 frpc 配置里没有把 9222 映射出去（否则等于把浏览器控制权公开）。