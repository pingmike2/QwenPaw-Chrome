#!/bin/bash
# ============================================================
# 无交互一键部署: QwenPaw + VNC浏览器(Chromium)
# ============================================================
# 本地直接部署 (无需 FRP 隧道): VNC 浏览器桌面 + QwenPaw 面板都在本机端口
#
# 使用:
#   bash install.sh [-P 密码] [-r 分辨率]
#
# 常用可选:
#   -P, --password <PASS>   VNC 密码 + SSH root 密码 (默认 browser123)
#   -r, --resolution <RxR>  桌面分辨率 (默认 720x1280)
#   -V, --vnc-port <PORT>   noVNC 本地端口 (默认 8080)
#   -Q, --qwenpaw-port <PORT> QwenPaw 面板端口 (默认 8088)
#   -h, --help              显示帮助
#
# 环境变量扩展 (CDP_HEADED / CDP_START_URL):
#   CDP_HEADED=1   chromium-cdp 有头模式 (默认): AI 浏览器显示在 VNC, 人机同屏
#   CDP_HEADED=0   chromium-cdp 无头模式: 省内存, VNC 桌面显示独立 chromium-gui
#   CDP_START_URL=...  有头模式的启动页 (默认 Tampermonkey 扩展商店)
#
# 示例:
#   bash install.sh                                         # 默认 720x1280, noVNC:8080, 面板:8088
#   bash install.sh -P mypass -r 1280x720                   # 改密码 + 横屏
#   CDP_HEADED=0 bash install.sh                             # 无头模式
#
# 自动完成:
#   - 检测/修复本机 chromium CDP 模式 (browser_use 依赖)
#   - 自动探测 NAS 持久化路径 (不写死, 谁都能用)
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
PASSWORD="${PASSWORD:-browser123}"               # 统一密码: VNC 密码 + SSH root 密码 (默认 browser123)
RESOLUTION="${RESOLUTION:-720x1280}"             # 桌面分辨率 (手机竖屏 720x1280 / 电脑横屏 1280x720)
VNC_PORT="${VNC_PORT:-8080}"                     # 本地 noVNC 端口
VNC_BACKEND_PORT="${VNC_BACKEND_PORT:-18080}"     # websockify 后端（Caddy 认证层后面）
VNC_PASS="${VNC_PASS:-$PASSWORD}"                # VNC 密码 (默认 = PASSWORD)
QWENPAW_PORT="${QWENPAW_PORT:-8088}"             # 本地 qwenpaw app 端口
BACKUP_INTERVAL="${BACKUP_INTERVAL:-1800}"       # 数据备份间隔(秒), 默认 30 分钟
CDP_PORT="${CDP_PORT:-9222}"                     # chromium CDP 调试端口 (browser_use 用)
CDP_HEADED="${CDP_HEADED:-1}"                    # 1=有头模式(VNC可见,默认开) 0=无头模式(省内存)
CDP_START_URL="${CDP_START_URL:-https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo}"  # chromium-cdp 启动页

# 命令行参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -P|--password)     PASSWORD="$2"; VNC_PASS="$2"; shift 2 ;;
        -r|--resolution)   RESOLUTION="$2"; shift 2 ;;
        -V|--vnc-port)     VNC_PORT="$2"; shift 2 ;;
        -Q|--qwenpaw-port) QWENPAW_PORT="$2"; shift 2 ;;
        -h|--help)         show_help ;;
        *) red "❌ 未知参数: $1"; show_help ;;
    esac
done

# ============================================================
# 0. 基础检查
# ============================================================
set -e

[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限运行 (sudo bash install.sh ...)"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

green "============================================================"
green " QwenPaw + VNC浏览器(Chromium) 一键部署"
green " 本地端口: noVNC=${VNC_PORT} qwenpaw面板=${QWENPAW_PORT}"
green " 分辨率: ${RESOLUTION}  密码: ${VNC_PASS}"
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

    # chromium-cdp 启动命令 (有头/无头二选一)
    #   有头 (CDP_HEADED=1): 显示在 VNC 桌面, 能直接看到 AI 在浏览器里干什么
    #   无头 (CDP_HEADED=0): 后台运行, 省内存, 适合纯自动化不关心界面
    if [ "${CDP_HEADED:-1}" = "1" ]; then
        CDP_CMD="${CHROMIUM_BIN} --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile --window-size=${RESOLUTION} --window-position=0,0 --lang=zh-CN --accept-lang=zh-CN,zh ${CDP_START_URL}"
        CDP_ENV='environment=DISPLAY=":1"'
        CDP_GUI_AUTOSTART=false   # cdp 有头已占 VNC 桌面, 不再自动起独立的 chromium-gui
    else
        CDP_CMD="${CHROMIUM_BIN} --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=/tmp/chromium-cdp-profile about:blank"
        CDP_ENV=""
        CDP_GUI_AUTOSTART=true    # cdp 无头时, VNC 桌面显示独立 chromium-gui (Bing)
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
command=${CDP_CMD}
${CDP_ENV}
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
            nohup $CDP_CMD \
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
# 2.5 Xvnc (TigerVNC) 检测安装 —— v5 动态分辨率架构依赖
# ============================================================
# v5 用 Xvnc 替代 Xvfb+x11vnc: Xvnc 自带 RandR 动态分辨率 + 内置 VNC server
# 新机器若只有 Xvfb 没有 Xvnc, 自动 apt 安装 tigervnc-standalone-server
if ! command -v Xvnc >/dev/null 2>&1; then
    yellow "🔧 未找到 Xvnc (TigerVNC), 自动安装 tigervnc-standalone-server..."
    apt-get update -qq && apt-get install -y -qq tigervnc-standalone-server x11-apps
    command -v Xvnc >/dev/null 2>&1 && green "✅ Xvnc 安装完成: $(Xvnc -version 2>&1 | head -1)" \
        || { red "❌ Xvnc 安装失败, 请手动 apt install tigervnc-standalone-server"; exit 1; }
else
    green "✅ Xvnc 已就绪: $(Xvnc -version 2>&1 | head -1)"
fi

# Openbox 窗口管理器（轻量，替代 xfce4，启动更稳不黑屏）
if ! command -v openbox >/dev/null 2>&1; then
    yellow "🔧 未找到 openbox, 自动安装..."
    apt-get update -qq && apt-get install -y -qq openbox 2>/dev/null \
        && command -v openbox >/dev/null 2>&1 && green "✅ openbox 安装完成" \
        || { red "❌ openbox 安装失败"; exit 1; }
else
    green "✅ openbox 已就绪"
fi

# Caddy Web 服务器（noVNC 认证层，必须完整版才有 basic_auth 模块）
install_caddy_full() {
    if command -v caddy >/dev/null 2>&1; then
        if caddy list-modules 2>/dev/null | grep -q 'http.handlers.authentication'; then
            green "✅ Caddy 完整版已就绪（含 basic_auth）"
            return 0
        fi
        yellow "⚠️ 检测到精简版 Caddy（缺 basic_auth 模块），正在升级..."
        apt-get remove -y -qq caddy 2>/dev/null || true
    fi
    yellow "📦 安装官方完整版 Caddy（含 basic_auth）..."
    command -v gpg >/dev/null 2>&1 || apt-get install -y -qq gnupg 2>/dev/null
    local keyring=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | \
        gpg --dearmor --yes -o "$keyring" 2>/dev/null || { red "❌ Caddy GPG key 下载失败"; exit 1; }
    cat > /etc/apt/sources.list.d/caddy-stable.list <<LISTEOF
deb [signed-by=${keyring}] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
LISTEOF
    apt-get update -qq 2>/dev/null || apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends caddy || { red "❌ Caddy 安装失败"; exit 1; }
    caddy list-modules 2>/dev/null | grep -q 'http.handlers.authentication' \
        && green "✅ 完整版 Caddy 安装完成（含 basic_auth）" \
        || yellow "⚠️ Caddy 缺少 basic_auth 模块"
}
install_caddy_full

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

# VNC 浏览器桌面服务 (noVNC 本地端口 ${VNC_PORT})
VNC_DIR=/mnt/envd/vnc-browser
mkdir -p "$VNC_DIR"

    cat > "$VNC_DIR/chromium-gui.sh" <<EOF
#!/bin/bash
# chromium-gui.sh - 在 DISPLAY :1 (openbox 桌面) 上启动带窗口的 chromium
# 注意: 必须用 exec 前台直启 (不要 & 后台 + 守护循环), 否则 supervisorctl stop
#       只杀脚本壳, chromium 变孤儿进程继续占桌面 → 白屏/抢屏 (2026-08-15 教训)
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
  --window-position=0,0 \\
  --user-data-dir="\$NAS_DIR" \\
  --disable-dev-shm-usage \\
  --disable-gpu \\
  --disable-software-rasterizer \\
  --disable-background-networking \\
  --hide-crash-restore-bubble \\
  --disable-session-crashed-bubble \\
  --disable-infobars \\
  --no-first-run \\
  --disable-features=Translate,BackForwardCache \\
  --js-flags=--max-old-space-size=1024 \\
  ${CDP_START_URL}
EOF

    cat > "$VNC_DIR/vnc-browser.sh" <<EOF
#!/bin/bash
# vnc-browser.sh - 暴露 Xvnc 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
# 架构: Xvnc (TigerVNC, 自带动态分辨率) + websockify + noVNC vnc.html
set -u
VNC_PORT="\${VNC_PORT:-${VNC_PORT}}"
VNC_BACKEND_PORT="\${VNC_BACKEND_PORT:-${VNC_BACKEND_PORT:-18080}}"
VNC_DISPLAY="\${VNC_DISPLAY:-:1}"
VNC_PASS="\${VNC_PASS:-${VNC_PASS}}"
RFB_PORT=5900
LOG_DIR=/var/log
PASS_FILE=/root/.vnc/passwdfile
mkdir -p /root/.vnc
# 写密码文件 (Xvnc 用 -SecurityTypes None 时不需要; 保留以备后续改 VncAuth)
printf '%s\n' "\${VNC_PASS}" > "\${PASS_FILE}"
chmod 600 "\${PASS_FILE}"
echo "=== vnc-browser 启动 (port \${VNC_PORT}, display \${VNC_DISPLAY}) ==="
for old in \$(pgrep -f "websockify.*\${VNC_PORT}"); do
  [ -n "\$old" ] && kill "\$old" 2>/dev/null
done
sleep 1
for i in \$(seq 1 50); do
  [ -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ ! -S "/tmp/.X11-unix/X\${VNC_DISPLAY#:}" ] && { echo "❌ DISPLAY \${VNC_DISPLAY} 不存在"; exit 1; }
rm -f /tmp/.X\${VNC_DISPLAY#:}-lock 2>/dev/null || true
# 生成入口页: 根路径 / 自动跳转 vnc.html (完整 UI, 控制栏默认收起, autoconnect)
cat > /usr/share/novnc/index.html <<'INDEXEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VNC Browser</title>
<script>
// 自动跳转到 vnc.html (完整 UI, 控制栏默认收起, 支持缩放切换)
var base = location.pathname.replace(/index\.html$/, '');
var target = base + 'vnc.html?autoconnect=1&resize=scale&show_dot=0';
if (location.search) target += '&' + location.search.replace(/^\?/, '');
location.replace(target);
</script></head><body>
<p>Redirecting to <a href="vnc.html?autoconnect=1&amp;resize=scale&amp;show_dot=0">VNC Browser...</a></p>
</body></html>
INDEXEOF
# noVNC chrome.sh 风格补丁: 侧边工具栏保持展开 + 状态栏隐藏 + resize=scale (幂等)
python3 "\$VNC_DIR/novnc-chromesh-patch.py" 2>/dev/null || echo "⚠️ noVNC patch 失败"
# websockify: 只监听回环后端端口 (Caddy 在前面做认证，不直接暴露)
websockify 127.0.0.1:\${VNC_BACKEND_PORT} localhost:\${RFB_PORT} > "\${LOG_DIR}/novnc.log" 2>&1 &
WEB_PID=\$!
sleep 2
echo "✅ websockify 后端: 127.0.0.1:\${VNC_BACKEND_PORT} (Caddy 认证前端)"
echo "✅ noVNC: http://localhost:\${VNC_PORT}/vnc.html?autoconnect=1 (控制栏默认收起)"
echo "✅ 切分辨率: /mnt/envd/vnc-browser/vnc-resize.sh phone|desktop|WxH"
wait "\${WEB_PID}" 2>/dev/null
EOF

    # 生成一次性认证 token（登录页 JS 与 Caddy 共享；等价于"第二个密码"）
    AUTH_TOKEN="${AUTH_TOKEN:-$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
    CADDY_HASH="$(caddy hash-password --plaintext "$VNC_PASS" 2>/dev/null || echo '$2y$10$invalidhash')"

    # Caddy 认证前端（登录页 + token 方案，CF 回源也安全）
    cat > "$VNC_DIR/Caddyfile" <<EOF
:${VNC_PORT} {
    # 认证检查端点：登录页 JS 用 fetch + Basic 头探测
    @auth_check path /__auth_check
    handle @auth_check {
        basicauth {
            qwenpaw ${CADDY_HASH}
        }
        respond "OK" 200
    }

    # 登录页（公开 HTML，认证在提交时校验）
    handle /__login {
        root * ${VNC_DIR}
        try_files vnc-login.html
        file_server
    }

    # 无凭据的 noVNC 请求 → 重定向登录页（带 token/Authorization 或 websockify 的放行）
    @need_login {
        not path /__login /__auth_check* /websockify*
        not query token=${AUTH_TOKEN}
        not header Authorization *
    }
    redir @need_login /__login 307

    # WebSocket：必须带 token 才反代 websockify
    @ws_ok {
        path /websockify*
        query token=${AUTH_TOKEN}
    }
    handle @ws_ok {
        reverse_proxy 127.0.0.1:${VNC_BACKEND_PORT}
    }
    @ws_deny path /websockify*
    handle @ws_deny {
        respond "Forbidden" 403
    }

    root * /usr/share/novnc
    file_server
}
EOF

    # 登录页：本地优先，无则从 GitHub raw 下载，替换 token 占位符
    if [ -f "${SCRIPT_DIR}/vnc-login.html" ]; then
        cp "${SCRIPT_DIR}/vnc-login.html" "$VNC_DIR/vnc-login.html"
    else
        curl -fsSL --max-time 30 "https://raw.githubusercontent.com/pingmike2/QwenPaw-Chrome/main/vnc-login.html" -o "$VNC_DIR/vnc-login.html" 2>/dev/null \
            || { red "❌ vnc-login.html 获取失败"; rm -f "$VNC_DIR/vnc-login.html"; }
    fi
    [ -f "$VNC_DIR/vnc-login.html" ] && sed -i "s/__AUTH_TOKEN__/${AUTH_TOKEN}/g" "$VNC_DIR/vnc-login.html"
    chmod 600 "$VNC_DIR"/Caddyfile 2>/dev/null

    cat > "$VNC_DIR/novnc-chromesh-patch.py" <<'PYEOF'
#!/usr/bin/env python3
"""noVNC chrome.sh 风格补丁 (幂等):
1. ui.js: 连接后侧边控制栏保持展开 (去掉 2 秒自动收起)
2. base.css: 底部状态栏常显 (参考 chrome.sh 底部工具栏)
3. ui.js: resize 默认 scale (iOS Safari 铺满)
4. vnc.html: 锁定 viewport (iOS Safari 修复 2026-08-18)
    iOS Safari 对 noVNC 整体放大后, 页面缩放机制会把桌面缩小到整页, 造成"缩放不正常"
    (安卓 Chrome 不放大整体页面故正常). 锁定 viewport 后 resize=scale 的 canvas 按
    视口铺满, 不受 Safari 缩放影响.
用法: python3 /mnt/envd/vnc-browser/novnc-chromesh-patch.py
"""
import re
import sys
import os

NOVNC = "/usr/share/novnc"
UJS = os.path.join(NOVNC, "app/ui.js")
CSS = os.path.join(NOVNC, "app/styles/base.css")
VNC_HTML = os.path.join(NOVNC, "vnc.html")

changed = []

def patch_file(path, marker, old, new):
    """如果 marker 不存在就做替换 (幂等)"""
    if not os.path.isfile(path):
        print(f"  ⚠️ 不存在: {path}")
        return
    with open(path, "r", encoding="utf-8") as f:
        content = f.read()
    if marker in content:
        print(f"  ⏭️ 已打过补丁 (跳过): {os.path.basename(path)}")
        return
    if old in content:
        content = content.replace(old, new, 1)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        changed.append(path)
        print(f"  ✅ patched: {path}")
    else:
        print(f"  ❌ 找不到 old 内容: {os.path.basename(path)}")

print("=== noVNC chrome.sh 风格补丁 ===")

# 1. ui.js: resize 默认 scale
patch_file(
    UJS,
    marker="initSetting('resize', 'scale')",
    old="UI.initSetting('resize', 'off');",
    new="UI.initSetting('resize', 'scale');",
)

# 2. ui.js: 连接后不自动收起侧边栏
patch_file(
    UJS,
    marker="参考 chrome.sh, 侧边工具栏保持展开",
    old="            // Hide the controlbar after 2 seconds\n            UI.closeControlbarTimeout = setTimeout(UI.closeControlbar, 2000);",
    new="            // 2026-08-18: 侧边工具栏默认收起 (手机单网页不占屏, 点手柄才展开)\n            UI.closeControlbarTimeout = setTimeout(UI.closeControlbar, 2000);",
)

# 3. base.css: 状态栏彻底隐藏（治"已连接提醒挡住底部/左右滑动"）
patch_file(
    CSS,
    marker="hide noVNC status bar",
    old="""#noVNC_status {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  z-index: 100;
  transform: translateY(-100%);

  cursor: pointer;

  transition: 0.5s ease-in-out;

  visibility: hidden;
  opacity: 0;""",
    new="""#noVNC_status {
  position: fixed;
  top: 0;
  left: 0;
  width: 100%;
  z-index: 100;
  /* 2026-08-18: 隐藏状态栏（不再显示"已连接"提醒，避免遮挡底部/左右滑动） */
  transform: none;

  cursor: pointer;

  transition: 0.5s ease-in-out;

  visibility: hidden !important;
  opacity: 0 !important;
  display: none !important;""",
)

# 4. vnc.html: 锁定 viewport (iOS Safari 修复)
_VIEWPORT_OLD = [
    '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0">',
    '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">',
]
_VIEWPORT_NEW = '<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">'
if os.path.isfile(VNC_HTML):
    content = open(VNC_HTML, encoding="utf-8").read()
    if _VIEWPORT_NEW in content:
        print("  ⏭️ 已打过补丁 (跳过): vnc.html viewport")
    else:
        changed_vp = False
        for old_vp in _VIEWPORT_OLD:
            if old_vp in content:
                content = content.replace(old_vp, _VIEWPORT_NEW, 1)
                changed_vp = True
                break
        if changed_vp:
            open(VNC_HTML, "w", encoding="utf-8").write(content)
            changed.append(VNC_HTML)
            print("  ✅ patched: vnc.html viewport 锁定")
        else:
            print("  ❌ 找不到 vnc.html 旧 viewport 内容")

print(f"=== 完成: {len(changed)} 个文件被修改 ===")
sys.exit(0)
PYEOF
    chmod +x "$VNC_DIR/novnc-chromesh-patch.py"

    cat > "$VNC_DIR/vnc-resize.sh" <<'EOF'
#!/bin/bash
# vnc-resize.sh - 动态切换虚拟桌面分辨率 (Xvnc TigerVNC 原生支持 RandR)
# 用法: vnc-resize.sh phone|desktop|WxH|status
set -u
DISPLAY="${DISPLAY:-:1}"
export DISPLAY

get_size() {
  xrandr --query | grep -oP '\d+x\d+(?=\s)' | head -1
}

case "${1:-}" in
  phone|mobile|竖屏)
    xrandr -s 720x1280 2>&1 ;;
  desktop|pc|横屏)
    xrandr -s 1280x720 2>&1 ;;
  ''|status|current)
    echo "当前分辨率: $(get_size)" ;;
  *)
    if echo "$1" | grep -qE '^[0-9]+x[0-9]+$'; then
      xrandr -s "$1" 2>&1
    else
      echo "用法: $0 [phone|desktop|WxH]"
      exit 1
    fi ;;
esac
echo "当前分辨率: $(get_size)"
EOF

    chmod +x "$VNC_DIR"/chromium-gui.sh "$VNC_DIR"/vnc-browser.sh "$VNC_DIR"/vnc-resize.sh
    green "✅ VNC/Chromium 脚本已生成: $VNC_DIR"

    append_program xvfb "command=/bin/sh -c \"rm -f /tmp/.X1-lock /tmp/.X11-unix/X1; mkdir -p /tmp/.X11-unix /root/.vnc; exec /usr/bin/Xvnc :1 -geometry ${RESOLUTION} -depth 24 -SecurityTypes None -localhost -AcceptSetDesktopSize=1 -AlwaysShared -rfbport 5900\"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/xvfb.err.log
stdout_logfile=/var/log/xvfb.out.log"

    append_program openbox "command=/bin/sh -c 'export DISPLAY=:1; for i in \$(seq 1 200); do [ -S /tmp/.X11-unix/X1 ] && break; sleep 0.1; done; exec openbox'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=\":1\"
stderr_logfile=/var/log/openbox.err.log
stdout_logfile=/var/log/openbox.out.log"

    append_program vnc-browser "command=${VNC_DIR}/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT}\",VNC_PASS=\"${VNC_PASS}\",VNC_BACKEND_PORT=\"${VNC_BACKEND_PORT}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

    append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
autostart=${CDP_GUI_AUTOSTART}
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"

    append_program caddy-vnc "command=/usr/bin/caddy run --config ${VNC_DIR}/Caddyfile --adapter caddyfile
autostart=true
autorestart=true
priority=59
startsecs=3
stderr_logfile=/var/log/caddy-vnc.err.log
stdout_logfile=/var/log/caddy-vnc.out.log"

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
for svc in xvfb openbox vnc-browser caddy-vnc chromium-gui qwenpaw qwenpaw-backup; do
    supervisorctl start "$svc" 2>/dev/null || true
    sleep 1
done
sleep 3

clear
green "============================================================"
green "✅ QwenPaw 一键部署完成!"
green ""
green " 🖥  noVNC 浏览器桌面 (本地):"
green "    http://localhost:${VNC_PORT}/vnc.html   (密码 = ${VNC_PASS})"
green ""
green " 🌐 QwenPaw 面板 (本地):"
green "    http://localhost:${QWENPAW_PORT}"
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