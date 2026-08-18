#!/bin/bash
# frp 一键恢复脚本
# 用法: bash recover-frp.sh
# 作用: 把持久化备份里的 frpc 恢复到 /home/frp 并启动 SSH + VNC 两条隧道
# 说明: frp 二进制放在 NAS 持久卷，容器重建后跑这个脚本即可恢复
# 包含:
#   1. 检查/安装/启动 sshd (容器重建后常缺失, frpc 转发 127.0.0.1:22 会 connection refused)
#   2. 解锁 root + 设置 SSH 密码 + 允许 root 密码登录
#   3. frpc 优先走 supervisor 管理 (若 supervisor 已配置), 否则 nohup 兜底
#   4. 清理重复 frpc 进程, 避免抢同一 remotePort
#
# 可配置 (环境变量覆盖, 默认即当前线上值):
#   REMOTE_PORT=30208     公网主端口: VNC = REMOTE_PORT, SSH = REMOTE_PORT-1 (与 install.sh -q 一致)
#   SSH_REMOTE_PORT       单独覆盖 SSH 公网端口 (设空 = 不建 SSH 隧道)
#   VNC_REMOTE_PORT       单独覆盖 noVNC 公网端口 (设空 = 不建 VNC 隧道)
#   SSH_LOCAL_PORT=22     本地 SSH 端口
#   VNC_LOCAL_PORT=8080   本地 noVNC/websockify 端口
#   PASSWORD / VNC_PASS   统一密码 (VNC 密码, 默认 browser123)
#   SSH_PASSWORD          SSH root 密码 (默认复用 VNC_PASS/PASSWORD)
# 示例:
#   REMOTE_PORT=30208 bash recover-frp.sh          # VNC=30208 SSH=30207
#   SSH_REMOTE_PORT=30209 VNC_REMOTE_PORT=30210 bash recover-frp.sh

set -e

BK_DIR="$(cd "$(dirname "$0")" && pwd)"   # frp-backup 目录
FRP_DIR="/home/frp"
SERVER="165.1.122.72"
SERVER_PORT="30205"
TOKEN="7bKJ73XW7HeNymI7"
# 主端口推导 (与 install.sh -q 一致): VNC=主端口, SSH=主端口-1
REMOTE_PORT="${REMOTE_PORT:-30208}"                 # 公网主端口 (默认 30208 = 线上 VNC 端口)
# SSH 隧道: 本地 sshd → 公网
SSH_LOCAL_PORT="${SSH_LOCAL_PORT:-22}"              # 本地 SSH 端口
SSH_REMOTE_PORT="${SSH_REMOTE_PORT:-$((REMOTE_PORT - 1))}"   # SSH 公网映射端口 (设空 = 不建 SSH 隧道)
SSH_PROXY_NAME="ssh_qwenpaw"
# VNC/noVNC 隧道: 本地 websockify → 公网
VNC_LOCAL_PORT="${VNC_LOCAL_PORT:-8080}"            # 本地 noVNC/websockify 端口
VNC_REMOTE_PORT="${VNC_REMOTE_PORT:-$REMOTE_PORT}"  # noVNC 公网映射端口 (设空 = 不建 VNC 隧道)
VNC_PROXY_NAME="novnc_qwenpaw"
SUPERVISOR_CONF="/etc/supervisor/conf.d/frpc.conf"
# 统一密码: VNC 密码 + SSH root 密码 (SSH 不单独设置就复用 VNC 密码)
VNC_PASS="${VNC_PASS:-${PASSWORD:-browser123}}"     # VNC 密码 (默认 browser123)
ROOT_PASSWORD="${SSH_PASSWORD:-$VNC_PASS}"          # SSH 登录密码 (默认复用 VNC 密码)
SSHD_OVERRIDE="/etc/ssh/sshd_config.d/99-frp-tunnel.conf"

echo "=== frp 恢复脚本 ==="

# ========== 0. 确保本地 SSH 服务 (sshd) 可用 + root 密码登录 ==========
echo "[0/5] 检查 sshd..."
if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
    echo "  sshd 已安装"
else
    echo "  sshd 未安装, 正在安装 openssh-server (容器重建后常缺失)..."
    apt-get update -qq && apt-get install -y -qq openssh-server
    echo "  ✅ openssh-server 安装完成"
fi

# 确保 /run/sshd 存在 (否则 sshd 拒绝启动)
[ -d /run/sshd ] || mkdir -p /run/sshd

# 设置 root 密码 (解锁 + 改密; 容器重建后 root 常为锁定状态 L)
if printf 'root:%s\n' "$ROOT_PASSWORD" | chpasswd 2>/dev/null; then
    echo "  ✅ root 密码已设置为指定密码"
else
    echo "  ❌ root 密码设置失败"
    exit 1
fi
passwd -u root >/dev/null 2>&1 || true
echo "  ✅ root 已解锁"

# 允许 root 密码登录 (sshd 默认 prohibit-password, 只允许密钥)
printf '%s\n' '# 允许 root 通过密码登录 (frp 隧道恢复用)' 'PermitRootLogin yes' 'PasswordAuthentication yes' > "$SSHD_OVERRIDE"

# 启动 sshd (容器无 systemd, 手动拉起; 已在跑则跳过)
if ! pgrep -x sshd >/dev/null 2>&1; then
    /usr/sbin/sshd
    sleep 1
    echo "  ✅ sshd 已启动"
else
    # 配置可能刚更新过, 重载使生效
    pkill -x sshd 2>/dev/null || true
    sleep 1
    /usr/sbin/sshd
    echo "  ✅ sshd 已重启 (pid $(pgrep -x sshd | head -1))"
fi

# 验证 22 端口真的在监听
if ! timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$SSH_LOCAL_PORT" 2>/dev/null; then
    echo "  ❌ sshd 启动异常: 127.0.0.1:$SSH_LOCAL_PORT 无法连接"
    exit 1
fi
echo "  ✅ 本地 $SSH_LOCAL_PORT 端口可连"

# ========== 0.5 恢复 SSH 公钥 (authorized_keys) ==========
# 容器重建后 /root/.ssh 是 overlay 会丢; 从 NAS 备份恢复, 保证密钥登录可用
SSH_BAK_DIR="$BK_DIR/ssh-conf"
if [ -f "$SSH_BAK_DIR/authorized_keys" ]; then
    mkdir -p /root/.ssh
    cp "$SSH_BAK_DIR/authorized_keys" /root/.ssh/authorized_keys
    chmod 700 /root/.ssh
    chmod 600 /root/.ssh/authorized_keys
    echo "✅ 已从备份恢复 SSH 公钥 (authorized_keys)"
else
    echo "⚠️ 未找到公钥备份: $SSH_BAK_DIR/authorized_keys (密钥登录将不可用, 仅密码登录)"
fi
# 恢复 sshd 覆盖配置 (PermitRootLogin yes 等在容器重建后丢失)
if [ -f "$SSH_BAK_DIR/99-frp-tunnel.conf" ]; then
    cp "$SSH_BAK_DIR/99-frp-tunnel.conf" /etc/ssh/sshd_config.d/99-frp-tunnel.conf
    chmod 644 /etc/ssh/sshd_config.d/99-frp-tunnel.conf
    echo "✅ 已恢复 sshd 覆盖配置 99-frp-tunnel.conf"
fi
# 若 frpc.toml 有备份且不存在, 顺便恢复 (防止 0-2 步的 heredoc 覆盖手改内容前有更全的版本)
if [ -f "$SSH_BAK_DIR/frpc.toml" ] && [ ! -f "$FRP_DIR/frpc.toml" ]; then
    cp "$SSH_BAK_DIR/frpc.toml" "$FRP_DIR/frpc.toml"
    echo "✅ 已恢复 frpc.toml"
fi

# ========== 1. 准备 frpc 目录 ==========
mkdir -p "$FRP_DIR"
if [ ! -f "$FRP_DIR/frpc" ]; then
    echo "[1/5] 复制 frpc 二进制..."
    cp "$BK_DIR/frpc" "$FRP_DIR/frpc"
else
    echo "[1/5] frpc 二进制已存在, 跳过"
fi
chmod +x "$FRP_DIR/frpc"

# ========== 2. 写配置 ==========
echo "[2/5] 写入 frpc.toml..."
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "$SERVER"
serverPort = $SERVER_PORT

auth.method = "token"
auth.token = "$TOKEN"

log.to = "/var/log/frpc.log"
log.level = "error"
log.maxDays = 3
EOF

# SSH 隧道 (SSH_REMOTE_PORT 留空则跳过)
if [ -n "$SSH_REMOTE_PORT" ]; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "$SSH_PROXY_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $SSH_LOCAL_PORT
remotePort = $SSH_REMOTE_PORT
EOF
fi

# VNC/noVNC 隧道 (VNC_REMOTE_PORT 留空则跳过)
if [ -n "$VNC_REMOTE_PORT" ]; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "$VNC_PROXY_NAME"
type = "tcp"
localIP = "127.0.0.1"
localPort = $VNC_LOCAL_PORT
remotePort = $VNC_REMOTE_PORT
EOF
fi

# ========== 3. 启动 frpc (优先 supervisor, 避免重复进程) ==========
echo "[3/5] 启动 frpc..."

# 清理所有现存 frpc (除 supervisor 子进程外), 避免抢 remotePort
pkill -f "frpc -c.*frpc.toml" 2>/dev/null || true
sleep 1

# 若 supervisor 已配置 frpc, 交给它管理 (容器重建后 supervisor 配置会丢失, 需要重建)
if command -v supervisorctl >/dev/null 2>&1; then
    if [ -f "$SUPERVISOR_CONF" ]; then
        echo "  检测到 supervisor 配置, 通过 supervisor 启动"
        supervisorctl reread >/dev/null 2>&1 || true
        supervisorctl update >/dev/null 2>&1 || true
        supervisorctl start frpc >/dev/null 2>&1 || supervisorctl restart frpc >/dev/null 2>&1 || true
    else
        echo "  supervisor 未配置 frpc, 写入配置..."
        cat > "$SUPERVISOR_CONF" <<EOF
[program:frpc]
command=$FRP_DIR/frpc -c $FRP_DIR/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log
EOF
        supervisorctl reread >/dev/null 2>&1 || true
        supervisorctl update >/dev/null 2>&1 || true
        supervisorctl start frpc >/dev/null 2>&1 || true
        echo "  ✅ supervisor 配置已写入并启动"
    fi
else
    echo "  无 supervisor, nohup 兜底启动"
    cd "$FRP_DIR"
    setsid nohup ./frpc -c ./frpc.toml >/dev/null 2>&1 &
    sleep 3
fi

# ========== 4. 验证 ==========
echo "[4/5] 验证..."
if ps aux | grep -q "[f]rpc -c"; then
    echo "✅ frpc 已启动"
else
    echo "❌ frpc 启动失败"
    exit 1
fi
if [ -n "$SSH_REMOTE_PORT" ]; then
    if timeout 8 bash -c "echo > /dev/tcp/$SERVER/$SSH_REMOTE_PORT" 2>/dev/null; then
        echo "✅ SSH 隧道 $SERVER:$SSH_REMOTE_PORT 可达"
    else
        echo "⚠️ SSH 隧道暂时不可达（可能服务端未就绪）"
    fi
    # 端到端 SSH banner 测试 (更强验证)
    BANNER=$(timeout 8 bash -c 'exec 3<>/dev/tcp/'"$SERVER"'/'"$SSH_REMOTE_PORT"'; sleep 1; head -c 20 <&3' 2>/dev/null | strings | head -1)
    if [ -n "$BANNER" ] && [[ "$BANNER" == SSH-* ]]; then
        echo "✅ 端到端 SSH 隧道正常: $BANNER"
    else
        echo "⚠️ SSH 隧道端口可达但未拿到 SSH banner"
    fi
fi
if [ -n "$VNC_REMOTE_PORT" ]; then
    if timeout 8 bash -c "echo > /dev/tcp/$SERVER/$VNC_REMOTE_PORT" 2>/dev/null; then
        echo "✅ VNC 隧道 $SERVER:$VNC_REMOTE_PORT 可达"
        VNC_HTTP=$(timeout 8 curl -s -o /dev/null -w "%{http_code}" "http://$SERVER:$VNC_REMOTE_PORT/vnc.html" 2>/dev/null || true)
        if [ -n "$VNC_HTTP" ] && [ "$VNC_HTTP" = "200" ]; then
            echo "✅ noVNC 公网可访问: http://$SERVER:$VNC_REMOTE_PORT/vnc.html (HTTP $VNC_HTTP)"
        else
            echo "⚠️ noVNC 公网 HTTP 非 200 (当前: $VNC_HTTP, 可能 vnc-browser 未就绪)"
        fi
    else
        echo "⚠️ VNC 隧道暂时不可达（可能服务端未就绪）"
    fi
fi

# ========== 5. root 密码登录端到端测试 ==========
echo "[5/5] root 密码登录测试..."
if [ -z "$SSH_REMOTE_PORT" ]; then
    echo "  SSH 隧道未启用 (SSH_REMOTE_PORT 为空), 跳过"
elif command -v sshpass >/dev/null 2>&1; then
    if timeout 15 sshpass -p "$ROOT_PASSWORD" ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -p "$SSH_REMOTE_PORT" "root@$SERVER" "echo OK" 2>/dev/null | grep -q OK; then
        echo "✅ root 密码登录成功: root@$SERVER:$SSH_REMOTE_PORT"
    else
        echo "⚠️ root 密码登录失败（请手动检查）"
    fi
else
    echo "  未安装 sshpass, 跳过密码登录测试 (隧道 banner 已验证)"
fi
echo "=== 完成 ==="
