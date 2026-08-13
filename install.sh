#!/bin/bash
# ============================================================
# 无交互一键部署: QwenPaw + FRP + Chromium
# ============================================================
# 用法 (参数与环境变量二选一, 参数优先):
#
#   方式一 (推荐): 命令行参数
#     bash install.sh -s <FRP服务器IP> -t <TOKEN> -q <公网端口> [选项...]
#
#   方式二: 环境变量
#     FRP_SERVER_IP=x FRP_TOKEN=x QWENPAW_REMOTE_PORT=x bash install.sh
#
# 必填:
#   -s, --server <IP>       FRP 服务端公网 IP (frp.sh 输出的 "监听IP")
#   -t, --token <TOKEN>     FRP 认证 TOKEN (frp.sh 输出的 "认证TOKEN")
#   -q, --qwenpaw <PORT>    QwenPaw 面板公网端口 (自己定, 如 10000)
#
# 常用可选:
#   -p, --frp-port <PORT>   FRP 服务端监听端口 (默认 7000)
#   -v, --vnc <PORT>        noVNC 公网映射端口 (默认空=不建 VNC 隧道)
#   -S, --ssh <PORT>        SSH 公网映射端口 (默认空=不建 SSH 隧道)
#   -r, --resolution <RxR>  桌面分辨率 (默认 720x1280)
#   -h, --help              显示帮助
#
# 示例:
#   bash install.sh -s 1.2.3.4 -t abc123 -q 10000
#   bash install.sh -s 1.2.3.4 -t abc123 -q 10000 -v 20000 -S 20022 -r 1280x720
#   FRP_SERVER_IP=1.2.3.4 FRP_TOKEN=abc123 QWENPAW_REMOTE_PORT=10000 bash install.sh
#
# 自动完成:
#   - 自动下载 frpc (fatedier/frp 官方 Release, 自动匹配架构)
#   - 检测/修复本机 chromium CDP 模式 (browser_use 依赖, 有问题先修好)
#   - 自动探测 NAS 持久化路径 (不写死, 谁都能用)
#   - 生成 frpc.toml 并托管到 supervisor
#   - supervisor 托管全部服务 + 开机自启 + 数据定时备份到 NAS
#
# 幂等: 可重复执行, 已有配置自动跳过
# ============================================================

# 颜色/工具函数
red()   { echo -e "\e[1;91m$1\033[0m"; }
green() { echo -e "\e[1;32m$1\033[0m"; }
yellow(){ echo -e "\e[1;33m$1\033[0m"; }

# 显示帮助 (打印本文件头部注释, 去掉 # 前缀)
show_help() {
    awk 'NR>=2 && /^#/ { print substr($0, 3) } NR>=2 && !/^#/ { exit }' "$0"
    exit 0
}

# 默认配置 (环境变量优先, 命令行参数覆盖)
FRP_SERVER_IP="${FRP_SERVER_IP:-}"
FRP_SERVER_PORT="${FRP_SERVER_PORT:-7000}"
FRP_TOKEN="${FRP_TOKEN:-}"
QWENPAW_REMOTE_PORT="${QWENPAW_REMOTE_PORT:-}"
FRP_SSH_REMOTE_PORT="${FRP_SSH_REMOTE_PORT:-}"   # SSH 公网映射端口 (留空 = 不建 SSH 隧道)
FRP_VNC_REMOTE_PORT="${FRP_VNC_REMOTE_PORT:-}"   # noVNC 公网映射端口 (留空 = 不建 VNC 隧道)
RESOLUTION="${RESOLUTION:-720x1280}"             # 桌面分辨率 (手机竖屏 720x1280 / 电脑横屏 1280x720)
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"           # 本地 SSH 端口
VNC_PORT="${VNC_PORT:-8080}"                     # 本地 noVNC 端口
QWENPAW_PORT="${QWENPAW_PORT:-8088}"             # 本地 qwenpaw app 端口
BACKUP_INTERVAL="${BACKUP_INTERVAL:-1800}"       # 数据备份间隔(秒), 默认 30 分钟
CDP_PORT="${CDP_PORT:-9222}"                     # chromium CDP 调试端口 (browser_use 用)

# 命令行参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--server)       FRP_SERVER_IP="$2"; shift 2 ;;
        -p|--frp-port)     FRP_SERVER_PORT="$2"; shift 2 ;;
        -t|--token)        FRP_TOKEN="$2"; shift 2 ;;
        -q|--qwenpaw)      QWENPAW_REMOTE_PORT="$2"; shift 2 ;;
        -v|--vnc)          FRP_VNC_REMOTE_PORT="$2"; shift 2 ;;
        -S|--ssh)          FRP_SSH_REMOTE_PORT="$2"; shift 2 ;;
        -r|--resolution)   RESOLUTION="$2"; shift 2 ;;
        -h|--help)         show_help ;;
        *) red "❌ 未知参数: $1"; show_help ;;
    esac
done

# ============================================================
# 0. 基础检查
# ============================================================
set -e

[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限运行 (sudo bash install.sh ...)"; exit 1; }

if [ -z "$FRP_SERVER_IP" ] || [ -z "$FRP_TOKEN" ] || [ -z "$QWENPAW_REMOTE_PORT" ]; then
    red "❌ 缺少必填参数: FRP_SERVER_IP / FRP_TOKEN / QWENPAW_REMOTE_PORT"
    echo ""
    show_help
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRP_DIR=/home/frp

green "============================================================"
green " QwenPaw + FRP + Chromium 一键部署"
green " FRP服务器: ${FRP_SERVER_IP}:${FRP_SERVER_PORT}"
green " 公网端口: qwenpaw=${QWENPAW_REMOTE_PORT} vnc=${FRP_VNC_REMOTE_PORT:-无} ssh=${FRP_SSH_REMOTE_PORT:-无}"
green "============================================================"

# ============================================================
# 1. NAS 路径自动探测 (不写死, 任意机器可用)
# ============================================================
detect_nas() {
    [ -n "${NAS_BASE_DIR:-}" ] && { echo "$NAS_BASE_DIR"; return; }
    local candidate=""
    case "$PWD" in
        /run/csi/mount-root/nas/*|/mnt/nas/*|/nas/*|/data/nas/*)
            candidate="$PWD"
            ;;
    esac
    if [ -z "$candidate" ]; then
        for base in /run/csi/mount-root/nas /mnt/nas /nas /data/nas; do
            [ -d "$base" ] || continue
            local found
            found=$(find "$base" -maxdepth 3 -type d -name workspaces 2>/dev/null | head -1)
            if [ -n "$found" ]; then
                candidate="$found/$(ls -t "$found" 2>/dev/null | head -1)"
                break
            fi
        done
    fi
    if [ -n "$candidate" ] && [ -d "$candidate" ] && touch "$candidate/.write_test" 2>/dev/null; then
        rm -f "$candidate/.write_test"
        echo "$candidate"
        return
    fi
    echo "/data/persist"
}

yellow "📂 探测 NAS 持久化路径..."
NAS_BASE_DIR="$(detect_nas)"
mkdir -p "$NAS_BASE_DIR" 2>/dev/null || true
if touch "$NAS_BASE_DIR/.write_test" 2>/dev/null; then
    rm -f "$NAS_BASE_DIR/.write_test"
    green "✅ NAS 可写: $NAS_BASE_DIR"
else
    yellow "⚠ NAS 不可写, 使用本地持久化: /data/persist"
    NAS_BASE_DIR=/data/persist
    mkdir -p "$NAS_BASE_DIR"
fi

QWENPAW_DATA_DIR="${QWENPAW_DATA_DIR:-/app/working}"
QWENPAW_SECRET_DIR="${QWENPAW_SECRET_DIR:-/app/working.secret}"
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-${NAS_BASE_DIR}/browser/chromium-gui-profile}"
mkdir -p "$NAS_BASE_DIR"/{qwenpaw-data,browser}
mkdir -p "$CHROMIUM_PROFILE_DIR"

# ============================================================
# 2. chromium CDP 模式检测与修复 (browser_use 依赖)
# ============================================================
check_cdp() {
    yellow "🔍 检查 chromium CDP 模式..."

    CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || echo /usr/bin/chromium)"
    if [ ! -x "$CHROMIUM_BIN" ]; then
        red "❌ 未找到 chromium, 请先安装 (apt install chromium)"
        exit 1
    fi
    green "✅ chromium: $CHROMIUM_BIN"

    cdp_ok() {
        curl -s --max-time 3 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q "webSocketDebuggerUrl"
    }

    SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
    [ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
    local has_sup=no
    if [ -f "$SUP_CONF" ] && grep -q "\[program:chromium-cdp\]" "$SUP_CONF" 2>/dev/null; then
        has_sup=yes
    fi

    if cdp_ok; then
        green "✅ CDP 端口 ${CDP_PORT} 正常响应 (chromium 已就绪)"
        [ "$has_sup" = "yes" ] && green "✅ chromium-cdp 已由 supervisor 托管 (开机自启)" || has_sup=no
    else
        red "❌ CDP 端口 ${CDP_PORT} 无响应, 需要启动/修复 chromium"
        has_sup=no
    fi

    if [ "$has_sup" != "yes" ]; then
        yellow "🔧 配置 supervisor 托管 chromium-cdp..."
        mkdir -p "$(dirname "$SUP_CONF")"
        if [ ! -f "$SUP_CONF" ]; then
            cat > "$SUP_CONF" <<'EOF'
[supervisord]
user=root
logfile=/var/log/supervisord.log
pidfile=/var/log/supervisord.pid
nodaemon=true

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
EOF
        fi

        if ! grep -q "\[program:chromium-cdp\]" "$SUP_CONF" 2>/dev/null; then
            cat >> "$SUP_CONF" <<EOF

[program:chromium-cdp]
command=${CHROMIUM_BIN} --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank
autostart=true
autorestart=true
priority=60
startsecs=5
stderr_logfile=/var/log/chromium-cdp.err.log
stdout_logfile=/var/log/chromium-cdp.out.log
EOF
            green "✅ chromium-cdp program 已添加"
        fi

        supervisorctl reread 2>/dev/null || true
        supervisorctl update 2>/dev/null || true
        supervisorctl start chromium-cdp 2>/dev/null || true
        sleep 3

        if cdp_ok; then
            green "✅ chromium CDP 修复成功 (端口 ${CDP_PORT})"
        else
            yellow "⚠ supervisor 启动失败, 手动启动兜底..."
            nohup "$CHROMIUM_BIN" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank \
                >/var/log/chromium-cdp.out.log 2>&1 &
            sleep 3
            if cdp_ok; then
                green "✅ chromium CDP 手动启动成功 (端口 ${CDP_PORT})"
            else
                red "❌ chromium CDP 启动失败, 请检查 /var/log/chromium-cdp.err.log"
                exit 1
            fi
        fi
    fi

    if cdp_ok; then
        green "✅ CDP 检测通过: http://127.0.0.1:${CDP_PORT}/json/version"
    else
        red "❌ CDP 最终验证失败, browser_use 将无法工作"
        exit 1
    fi
}

# ============================================================
# 3. frpc 自动下载/检查 + 写 frpc.toml
# ============================================================
# 自动下载 frpc (fatedier/frp 官方 Release), 支持任意 Linux 架构,
# 无需手动安装——NAT 内网机器也能一键部署
FRPC_BIN="${FRPC_BIN:-/home/frp/frpc}"
if [ ! -x "$FRPC_BIN" ] || ! "$FRPC_BIN" -v >/dev/null 2>&1; then
    yellow "🌐 未找到可用 frpc, 自动下载..."
    mkdir -p "$FRP_DIR"

    # 探测架构
    ARCH="$(uname -m)"
    case "$ARCH" in
        x86_64|amd64)        FRP_ARCH="amd64" ;;
        aarch64|arm64)       FRP_ARCH="arm64" ;;
        armv7l|armv6l|armhf) FRP_ARCH="arm" ;;
        loongarch64)         FRP_ARCH="loong64" ;;
        mips|mips64)         FRP_ARCH="${ARCH}" ;;
        *) red "❌ 不支持的架构: $ARCH"; exit 1 ;;
    esac

    FRP_VERSION="0.70.1"
    FRP_TAR="frp_${FRP_VERSION}_linux_${FRP_ARCH}.tar.gz"
    FRP_URL="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"
    TMP_DIR="/tmp/frp-download-$$"

    green "📥 下载 frp ${FRP_VERSION} (${FRP_ARCH}): ${FRP_URL}"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 15 -o "$TMP_DIR.tgz" "$FRP_URL" || { red "❌ 下载失败: $FRP_URL"; exit 1; }
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 15 -O "$TMP_DIR.tgz" "$FRP_URL" || { red "❌ 下载失败: $FRP_URL"; exit 1; }
    else
        red "❌ 需要 curl 或 wget 来下载 frpc"; exit 1
    fi

    mkdir -p "$TMP_DIR"
    tar -xzf "$TMP_DIR.tgz" -C "$TMP_DIR" 2>/dev/null || { red "❌ 解压失败"; exit 1; }
    find "$TMP_DIR" -name frpc -type f | head -1 | xargs -I{} install -m 0755 {} "$FRP_BIN"
    rm -rf "$TMP_DIR" "$TMP_DIR.tgz"
    if [ -x "$FRPC_BIN" ] && "$FRPC_BIN" -v >/dev/null 2>&1; then
        green "✅ frpc 下载完成: $FRPC_BIN ($("$FRPC_BIN" -v 2>&1))"
    else
        red "❌ frpc 安装失败, 请手动下载: https://github.com/fatedier/frp/releases"
        exit 1
    fi
fi
if [ ! -x "$FRPC_BIN" ]; then
    red "❌ 未找到可用 frpc 二进制 ($FRPC_BIN)"
    exit 1
fi
green "✅ frpc: $FRPC_BIN"

mkdir -p "$FRP_DIR"
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER_IP}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "error"
log.maxDays = 3

[[proxies]]
name = "qwenpaw_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${QWENPAW_PORT}
remotePort = ${QWENPAW_REMOTE_PORT}
EOF

if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "ssh_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${LOCAL_SSH_PORT}
remotePort = ${FRP_SSH_REMOTE_PORT}
EOF
fi

if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "novnc_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${VNC_PORT}
remotePort = ${FRP_VNC_REMOTE_PORT}
EOF
fi
green "✅ frpc.toml 已生成: $FRP_DIR/frpc.toml"

# ============================================================
# 4. supervisor 配置 (托管全部服务 + 内联备份循环)
# ============================================================
SUP_CONF=/etc/supervisor/conf.d/supervisord.conf
[ -d /etc/supervisor/conf.d ] || SUP_CONF=/etc/supervisor/supervisord.conf
mkdir -p "$(dirname "$SUP_CONF")"

if [ ! -f "$SUP_CONF" ]; then
    cat > "$SUP_CONF" <<'EOF'
[supervisord]
user=root
logfile=/var/log/supervisord.log
pidfile=/var/log/supervisord.pid
nodaemon=true

[unix_http_server]
file=/var/run/supervisor.sock
chmod=0700

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/supervisor.sock
EOF
fi

append_program() {
    local name="$1" body="$2"
    if grep -q "\[program:${name}\]" "$SUP_CONF" 2>/dev/null; then
        yellow "⏭ [program:${name}] 已存在, 跳过"
        return 0
    fi
    cat >> "$SUP_CONF" <<EOF

[program:${name}]
${body}
EOF
    green "✅ [program:${name}] 已添加"
}

append_program frpc "command=${FRPC_BIN} -c ${FRP_DIR}/frpc.toml
autostart=true
autorestart=true
stderr_logfile=/var/log/frpc.err.log
stdout_logfile=/var/log/frpc.out.log"

# 仅当配了 VNC 端口才托管桌面服务
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    VNC_DIR=/mnt/envd/vnc-browser
    mkdir -p "$VNC_DIR"

    cat > "$VNC_DIR/chromium-gui.sh" <<EOF
#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :1 (xfce4 桌面) 上启动带窗口的 chromium
set -u
NAS_DIR="${CHROMIUM_PROFILE_DIR}"
mkdir -p "\$NAS_DIR"
for i in \$(seq 1 30); do
  [ -S "/tmp/.X11-unix/X1" ] && break
  sleep 0.5
done
export DISPLAY=:1
exec /usr/bin/chromium \\
  --no-sandbox \\
  --test-type \\
  --window-size=${RESOLUTION/x/,} \\
  --start-fullscreen \\
  --user-data-dir="\$NAS_DIR" \\
  --disable-dev-shm-usage \\
  --disable-gpu \\
  --disable-software-rasterizer \\
  --disable-background-networking \\
  --restore-last-session \\
  --hide-crash-restore-bubble \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --no-first-run \\
  --disable-features=Translate,BackForwardCache \\
  --js-flags=--max-old-space-size=1024 \\
  about:blank
EOF

    cat > "$VNC_DIR/vnc-browser.sh" <<EOF
#!/bin/bash
# vnc-browser.sh - 暴露 xfce4 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
set -u
VNC_PORT="\${VNC_PORT:-${VNC_PORT}}"
VNC_DISPLAY="\${VNC_DISPLAY:-:1}"
RFB_PORT=5900
LOG_DIR=/var/log
echo "=== vnc-browser 启动 (port \${VNC_PORT}, display \${VNC_DISPLAY}) ==="
for old in \$(pgrep -f "x11vnc -display \${VNC_DISPLAY}") \$(pgrep -f "websockify.*\${VNC_PORT}"); do
  [ -n "\$old" ] && kill "\$old" 2>/dev/null
done
sleep 1
for i in \$(seq 1 50); do
  [ -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY \${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X\${VNC_DISPLAY#:}-lock 2>/dev/null || true
x11vnc -display "\${VNC_DISPLAY}" -forever -shared -rfbport \${RFB_PORT} -nopw -noxdamage -repeat -listen 0.0.0.0 -geometry ${RESOLUTION} -pointer_mode 1 -wait 5 -defer 5 > "\${LOG_DIR}/x11vnc.log" 2>&1 &
X11_PID=\$!
# 生成自适应入口页: 根路径 / 自动跳转 vnc_auto.html?resize=scale (任何设备自动缩放填满窗口)
cat > /usr/share/novnc/index.html <<'INDEXEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VNC Browser</title>
<script>
// 自动跳转到 vnc_auto.html 并带 resize=scale (本地缩放) + autoconnect
var base = location.pathname.replace(/index\.html$/, '');
var target = base + 'vnc_auto.html?autoconnect=1&resize=scale';
if (location.search) target += '&' + location.search.replace(/^\?/, '');
location.replace(target);
</script></head><body>
<p>Redirecting to <a href="vnc_auto.html?autoconnect=1&amp;resize=scale">VNC Browser (auto scale)...</a></p>
</body></html>
INDEXEOF
websockify --web /usr/share/novnc \${VNC_PORT} localhost:\${RFB_PORT} > "\${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=\$!
sleep 2
echo "✅ noVNC: http://localhost:\${VNC_PORT}/ (自适应缩放) 或 /vnc.html?resize=scale"
wait -n "\${X11_PID}" "\${WEB_PID}" 2>/dev/null || wait "\${X11_PID}" "\${WEB_PID}"
EOF

    chmod +x "$VNC_DIR"/chromium-gui.sh "$VNC_DIR"/vnc-browser.sh
    green "✅ VNC/Chromium 脚本已生成: $VNC_DIR"

    append_program xvfb "command=/bin/sh -c \"rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix; exec /usr/bin/Xvfb :1 -screen 0 ${RESOLUTION}x24\"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xvfb.err.log
stdout_logfile=/var/log/xvfb.out.log"

    append_program xfce4 "command=/bin/sh -c 'export DISPLAY=:1; for i in \$(seq 1 200); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done; exec dbus-run-session startxfce4'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xfce4.err.log
stdout_logfile=/var/log/xfce4.out.log"

    append_program vnc-browser "command=${VNC_DIR}/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

    append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
autostart=true
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"
fi

append_program qwenpaw "command=qwenpaw app --host 0.0.0.0 --port ${QWENPAW_PORT}
autostart=true
autorestart=unexpected
startretries=5
startsecs=10
priority=30
stopwaitsecs=30
environment=DISPLAY=\":1\",PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=\"/usr/bin/chromium\",QWENPAW_RUNNING_IN_CONTAINER=\"1\"
stderr_logfile=/var/log/app.err.log
stdout_logfile=/var/log/app.out.log"

# 内联备份循环 (每 BACKUP_INTERVAL 秒同步 qwenpaw 数据到 NAS, 重启自动恢复)
append_program qwenpaw-backup "command=/bin/sh -c 'while true; do
  mkdir -p ${NAS_BASE_DIR}/qwenpaw-data/working ${NAS_BASE_DIR}/qwenpaw-data/working.secret
  [ -d ${QWENPAW_DATA_DIR} ] && tar cf - -C ${QWENPAW_DATA_DIR} --exclude=\"*.pyc\" --exclude=__pycache__ . 2>/dev/null | tar xf - -C ${NAS_BASE_DIR}/qwenpaw-data/working 2>/dev/null
  [ -d ${QWENPAW_SECRET_DIR} ] && tar cf - -C ${QWENPAW_SECRET_DIR} . 2>/dev/null | tar xf - -C ${NAS_BASE_DIR}/qwenpaw-data/working.secret 2>/dev/null
  sleep ${BACKUP_INTERVAL}
done'
autostart=true
autorestart=true
priority=70
startsecs=5
stderr_logfile=/var/log/qwenpaw-backup.err.log
stdout_logfile=/var/log/qwenpaw-backup.out.log"

green "✅ supervisor 配置完成"

# ============================================================
# 5. 启动前恢复 NAS 数据
# ============================================================
yellow "♻️  从 NAS 恢复数据..."
QB="${NAS_BASE_DIR}/qwenpaw-data"
if [ -d "$QB/working" ] && [ -n "$(ls -A "$QB/working" 2>/dev/null)" ]; then
    mkdir -p "$QWENPAW_DATA_DIR"
    tar cf - -C "$QB/working" . 2>/dev/null | tar xf - -C "$QWENPAW_DATA_DIR" 2>/dev/null
    green "✅ 恢复 qwenpaw 数据 → $QWENPAW_DATA_DIR"
fi
if [ -d "$QB/working.secret" ] && [ -n "$(ls -A "$QB/working.secret" 2>/dev/null)" ]; then
    mkdir -p "$QWENPAW_SECRET_DIR"
    tar cf - -C "$QB/working.secret" . 2>/dev/null | tar xf - -C "$QWENPAW_SECRET_DIR" 2>/dev/null
    green "✅ 恢复 secret → $QWENPAW_SECRET_DIR"
fi

# ============================================================
# 6. 启动全部服务 + 输出
# ============================================================
green "🚀 启动服务..."
supervisorctl reread 2>/dev/null || true
supervisorctl update 2>/dev/null || true
for svc in frpc xvfb xfce4 vnc-browser chromium-gui qwenpaw qwenpaw-backup; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 1
done
sleep 3

clear
green "============================================================"
green "✅ QwenPaw 一键部署完成!"
green ""
green " 🌐 QwenPaw 面板:"
green "    http://${FRP_SERVER_IP}:${QWENPAW_REMOTE_PORT}"
green ""
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    green " 🖥  noVNC 浏览器桌面:"
    green "    http://${FRP_SERVER_IP}:${FRP_VNC_REMOTE_PORT}/vnc.html"
fi
green ""
if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    green " 🔑 SSH:"
    green "    ssh -p ${FRP_SSH_REMOTE_PORT} root@${FRP_SERVER_IP}"
fi
green ""
green " 💾 数据持久化:"
green "    NAS: ${NAS_BASE_DIR}"
green "    每 ${BACKUP_INTERVAL}s 自动备份, 重启自动恢复"
green ""
green " 🌐 chromium CDP: ${CDP_PORT} (browser_use 用)"
green "============================================================"
echo ""
yellow "服务状态:"
supervisorctl status 2>/dev/null || true
echo ""
green "✅ 全部完成! 如服务未启动请检查: supervisorctl status"