# QwenPaw SSH 隧道替代方案（frp DPI 拦截的 fallback，VPS 零新增组件）

> 原理：**容器 ssh -R 回传 → VPS 本机 127.0.0.1:<SSH_RETURN_PORT> → VPS 上一个 frpc 连本地 frps 暴露到 0.0.0.0:<FRP_EXPOSE_PORT>**
> VPS 不装 gost！frp 包里自带 frpc 二进制，直接复用现有 frps。

---

## 环境事实（已确认）
- VPS: `<FRP_SERVER_IP>`，SSH 端口 `<SSH_PORT>`
- VPS sshd_config 中若禁用了 `AllowTcpForwarding`，需改为 `yes`；`GatewayPorts` 通常不用动
- frps 通信端口：`<FRP_SERVER_PORT>`
- frp 二进制目录：frps 所在目录同时有 **frpc**（同一个 frp 发行包）
- 容器本地 Caddy noVNC 在 **127.0.0.1:8080**（未认证 → 307 登录页）
- 容器 SSH 密钥：`<SSH_KEY>`
- 容器 supervisor：`/etc/supervisor/conf.d/`

---

## 数据流

```
浏览器 → VPS:0.0.0.0:<FRP_EXPOSE_PORT> (frps 监听)
              ↑ frp 隧道 (VPS frpc → 本地 frps)
        VPS 127.0.0.1:<SSH_RETURN_PORT> (ssh -R 回传端口)
              ↑ ssh -R 隧道
        容器 127.0.0.1:8080 (Caddy noVNC)
```

**frp 隧道段在 VPS 内部完成**（frpc 连 frps 都是 127.0.0.1），不经过公网 → 不触发 DPI！只有 SSH 管理端口走公网。

---

## 第一步：VPS 侧 — 开 AllowTcpForwarding + 热重载（零锁死风险）

```bash
# 1. 备份
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M)

# 2. 允许 TCP 转发（全部替换）
sed -i 's/^AllowTcpForwarding[[:space:]]*no/AllowTcpForwarding yes/' /etc/ssh/sshd_config

# 3. 确认
grep -n 'AllowTcpForwarding' /etc/ssh/sshd_config

# 4. 语法校验
sshd -t && echo "✔ sshd 配置语法 OK"

# 5. SIGHUP 热重载（不断任何现有连接）
kill -HUP $(pgrep -x sshd | head -1) && echo "✔ sshd 已热重载"
```

> ⚠️ 不用 `pkill sshd`！SIGHUP 重载足够，零锁死风险。

---

## 第二步：VPS 侧 — frpc 连本地 frps，暴露 <FRP_EXPOSE_PORT>

找到 frps 所在目录（`which frps` 或 ps 查），同目录有 frpc：

```bash
FRP_DIR=$(dirname $(readlink -f $(which frps 2>/dev/null || pgrep -f frps | head -1 2>/dev/null || echo /home/frp/frps)))
ls "$FRP_DIR"   # 应看到 frps frpc

# 1. 写 frpc 配置（连本地 frps:<FRP_SERVER_PORT>，把 127.0.0.1:<SSH_RETURN_PORT> 暴露为 0.0.0.0:<FRP_EXPOSE_PORT>）
cat > "$FRP_DIR/frpc-local.toml" <<'EOF'
serverAddr = "127.0.0.1"
serverPort = <FRP_SERVER_PORT>
auth.method = "token"
auth.token = "<FRP_TOKEN>"

[[proxies]]
name = "ssh-local-novnc"
type = "tcp"
localIP = "127.0.0.1"
localPort = <SSH_RETURN_PORT>
remotePort = <FRP_EXPOSE_PORT>
EOF

# 2. 启动（后台）
nohup "$FRP_DIR/frpc" -c "$FRP_DIR/frpc-local.toml" > /var/log/frpc-local.log 2>&1 &
sleep 2
ss -ltn | grep <FRP_EXPOSE_PORT> && echo "✔ frps 已监听 0.0.0.0:<FRP_EXPOSE_PORT>"
```

> <FRP_EXPOSE_PORT> 若被旧 frps 占用——之前的公网映射 <FRP_EXPOSE_PORT> 是容器 frpc 建的，容器 frpc 现在连不上（DPI），frps 应该已释放。若仍占用，`pkill -f frps` 重启 frps 即可（frps 主配置不丢）。

---

## 第三步：容器侧 — 手动起 SSH 隧道并验证

```bash
# 手动起隧道
ssh -i <SSH_KEY> \
  -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no \
  -N -R 127.0.0.1:<SSH_RETURN_PORT>:127.0.0.1:8080 \
  -p <SSH_PORT> root@<FRP_SERVER_IP> &
echo $! > /tmp/ssh-tunnel.pid
sleep 3

# 验证 1：VPS 本机（应 307 登录页重定向）
ssh -i <SSH_KEY> -p <SSH_PORT> root@<FRP_SERVER_IP> \
  'curl -sS -o /dev/null -w "VPS本机HTTP:%{http_code}\n" http://127.0.0.1:<SSH_RETURN_PORT>/'

# 验证 2：公网（应 307）
curl -sS -o /dev/null -w "公网HTTP:%{http_code}\n" http://<FRP_SERVER_IP>:<FRP_EXPOSE_PORT>/

# 验证 3：登录页内容
curl -sS -L http://<FRP_SERVER_IP>:<FRP_EXPOSE_PORT>/ | grep -o '<title>[^<]*</title>'
# 应输出: <title>QwenPaw 访问认证</title>
```

**三个都过 → 进第四步托管。**

---

## 第四步：容器侧 — supervisor 托管 SSH 隧道（替换 frpc 段）

编辑 `/etc/supervisor/conf.d/frp-extra.conf`，删掉 `[program:frpc]` 段，加：

```ini
[program:ssh-tunnel]
command=/usr/bin/ssh -i <SSH_KEY> -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=no -N -R 127.0.0.1:<SSH_RETURN_PORT>:127.0.0.1:8080 -p <SSH_PORT> root@<FRP_SERVER_IP>
autostart=true
autorestart=true
startsecs=3
priority=55
stderr_logfile=/var/log/ssh-tunnel.err.log
stdout_logfile=/var/log/ssh-tunnel.out.log
```

```bash
supervisorctl reread
supervisorctl update
supervisorctl restart ssh-tunnel
supervisorctl status    # ssh-tunnel RUNNING
```

> frpc 段必须删（autorestart=true 会反复拉起失败的 frpc）。

---

## 第五步：公网最终验证

浏览器打开 `http://<FRP_SERVER_IP>:<FRP_EXPOSE_PORT>/` → 登录页 → 输入部署时的账号密码 → Chromium 桌面。

---

## 回滚 / 注意事项

- **回滚**：删 supervisor ssh-tunnel 段 + VPS `pkill -f frpc-local` + sshd_config 恢复备份（SIGHUP 重载）
- **VPS 重启后**：frpc-local 不自动起。加 cron @reboot：
  ```bash
  echo "@reboot root <FRP_DIR>/frpc -c <FRP_DIR>/frpc-local.toml >> /var/log/frpc-local.log 2>&1" > /etc/cron.d/frpc-local
  ```
- **frp 主链路保留**：容器 frpc（公网直连）只是暂停，DPI 缓解后可恢复，两套互不影响
- sshd SIGHUP 重载不断任何连接，全程无锁死风险