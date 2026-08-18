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
#     FRP_SERVER_IP=x FRP_TOKEN=x QWENPAW_REMOTE_PORT=x PASSWORD=x bash install.sh
#
# 必填:
#   -s, --server <IP>       FRP 服务端公网 IP (frp.sh 输出的 "监听IP")
#   -t, --token <TOKEN>     FRP 认证 TOKEN (frp.sh 输出的 "认证TOKEN")
#   -v, --vnc <PORT>        noVNC 公网端口 (**必填**, 基准端口)
#
# 常用可选:
#   -p/-P, --password <PASS> SSH/VNC/QwenPaw 共用密码（大小写通用）
#   -f, --frp-port <PORT>   FRP 服务端监听端口（默认 7000）
#   -S, --ssh <PORT>        SSH 公网端口 (默认 = -v+1；传 0 禁用)
#   -q, --qwenpaw <PORT>    QwenPaw 面板公网端口 (默认 = -v+2；传 0 禁用)
#   -r, --resolution <RxR>  桌面分辨率 (默认 720x1280)
#   -h, --help              显示帮助
#
# 示例:
#   bash install.sh -s 1.2.3.4 -f 7000 -t abc123 -v 10001 -p mypass
#     # noVNC=10001, SSH=10002, QwenPaw=10003, 共用密码
#   bash install.sh -s 1.2.3.4 -f 7000 -t abc123 -v 10001 -S 0 -q 0 -p mypass
#     # 只留 noVNC，关 SSH 和 QwenPaw 面板
#   旧写法兼容: -p 7000 -P mypass  # 7000 作为旧版 FRP 监听端口
#   # 服务端若改为 7100，客户端同步改为：-f 7100
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
FRP_SSH_REMOTE_PORT="${FRP_SSH_REMOTE_PORT:-}"   # SSH 公网映射端口 (留空 = 自动使用 QWENPAW_REMOTE_PORT-1)
FRP_SSH_EXPLICIT=0
[ -z "$FRP_SSH_REMOTE_PORT" ] || FRP_SSH_EXPLICIT=1
FRP_PASSWORD_FLAG=0
LEGACY_P_VALUE=""
LEGACY_P_MODE=0
# 只有命令行同时出现旧版 -p <端口> 和 -P <密码> 时，才启用旧兼容解释。
for ARG in "$@"; do
    if [ "$ARG" = "-P" ] || [ "$ARG" = "--password" ] || [ "$ARG" = "--passwd" ]; then
        LEGACY_P_MODE=1
        break
    fi
done
FRP_VNC_REMOTE_PORT="${FRP_VNC_REMOTE_PORT:-}"   # noVNC 公网映射端口 (留空 = QwenPaw 公网端口+1；0 = 禁用)
PASSWORD="${PASSWORD:-qwenpaw}"                    # SSH/VNC/QwenPaw 共用密码；默认 qwenpaw，可通过 -p/-P 或 PASSWORD 覆盖（noVNC 的 VNC 协议密码取前 8 位）
RESOLUTION="${RESOLUTION:-720x1280}"             # 桌面分辨率 (手机竖屏 720x1280 / 电脑横屏 1280x720)
LOCAL_SSH_PORT="${LOCAL_SSH_PORT:-22}"           # 本地 SSH 端口
VNC_PORT="${VNC_PORT:-8080}"                     # 本地 noVNC 端口（websockify 直连，VncAuth 认证）
VNC_DISPLAY_NUM="${VNC_DISPLAY_NUM:-2}"           # Xvnc 显示编号（QwenPaw 容器内 :1 被平台占用，默认 2）
VNC_RFB_PORT="${VNC_RFB_PORT:-5900}"              # Xvnc RFB 端口（QwenPaw 容器需 5901）
VNC_PYTHON_BIN="${VNC_PYTHON_BIN:-python3}"       # 容器内可用 Python（兼容 venv 缺包场景）
QWENPAW_PORT="${QWENPAW_PORT:-8088}"             # 本地 qwenpaw app 端口（官方默认 8088，智能体端口勿动）
QWENPAW_CADDY_PORT="${QWENPAW_CADDY_PORT:-8089}"  # Caddy qwenpaw 认证入口端口（basic_auth → 反代 8088, 8088+1）
BACKUP_INTERVAL="${BACKUP_INTERVAL:-1800}"       # 数据备份间隔(秒), 默认 30 分钟
CDP_PORT="${CDP_PORT:-9222}"                     # chromium CDP 调试端口 (browser_use 用)

# 命令行参数解析
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--server)       FRP_SERVER_IP="$2"; shift 2 ;;
        -p|-P|--password|--passwd)
            # -p/-P 统一表示密码；兼容旧版 “-p 7000 -P 密码” 写法。
            # 只有 -p 的值是纯数字且后续明确出现 -P 时，才把它当旧版 FRP 端口。
            if [ "$1" = "-p" ] && [ "$LEGACY_P_MODE" = "1" ] \
                && printf '%s' "${2:-}" | grep -qE '^[0-9]+$' \
                && [ "$FRP_PASSWORD_FLAG" = "0" ]; then
                LEGACY_P_VALUE="$2"
                shift 2
                continue
            fi
            PASSWORD="$2"
            FRP_PASSWORD_FLAG=1
            VNC_PASS="$2"
            shift 2
            ;;
        -f|--frp-port)     FRP_SERVER_PORT="$2"; shift 2 ;;
        -t|--token)        FRP_TOKEN="$2"; shift 2 ;;
        -q|--qwenpaw)      QWENPAW_REMOTE_PORT="$2"; shift 2 ;;
        -v|--vnc)          FRP_VNC_REMOTE_PORT="$2"; shift 2 ;;
        -S|--ssh)
            FRP_SSH_EXPLICIT=1
            FRP_SSH_REMOTE_PORT="$2"
            shift 2
            ;;
        -r|--resolution)   RESOLUTION="$2"; shift 2 ;;
        -h|--help)         show_help ;;
        *) red "❌ 未知参数: $1"; show_help ;;
    esac
done

# 兼容旧版 “-p <FRP端口> -P <密码>” 参数顺序。
if [ -n "$LEGACY_P_VALUE" ]; then
    if [ "$FRP_PASSWORD_FLAG" = "1" ]; then
        FRP_SERVER_PORT="$LEGACY_P_VALUE"
    else
        # 没有后续密码时，按新规则把 -p 的值还原为密码。
        PASSWORD="$LEGACY_P_VALUE"
        VNC_PASS="$LEGACY_P_VALUE"
        FRP_PASSWORD_FLAG=1
    fi
fi

# SSH/VNC/QwenPaw 共用同一个完整密码，不使用 SSH key；noVNC 由表单登录后端做 Cookie 会话认证。
# 默认 qwenpaw，可覆盖。
VNC_PASS="$PASSWORD"
CDP_HEADED="${CDP_HEADED:-0}"
CDP_START_URL="${CDP_START_URL:-about:blank}"

# SSH/VNC 始终共用同一个完整密码；SSH 和 noVNC 都使用完整值。
case "$CDP_START_URL" in
    *[[:space:]]*) red "❌ CDP_START_URL 不能包含空格"; exit 1 ;;
esac

# ============================================================
# 0. 基础检查
# ============================================================
set -e

[ "$(id -u)" != "0" ] && { red "❌ 需要 root 权限运行 (sudo bash install.sh ...)"; exit 1; }

if [ -z "$FRP_SERVER_IP" ] || [ -z "$FRP_TOKEN" ]; then
    red "❌ 缺少必填参数: FRP_SERVER_IP / FRP_TOKEN"
    echo ""
    show_help
fi

# 端口派生（以 -v 为基准）：
#   -v 必填 = noVNC 公网端口
#   SSH 自动 = -v+1（可 -S 覆盖；-S 0 禁用）
#   qwenpaw 自动 = -v+2（可 -q 覆盖；-q 0 禁用）
# 三个入口全部使用共用密码 PASSWORD 认证。
validate_port() {
    local name="$1" value="$2"
    case "$value" in
        ''|*[!0-9]*) red "❌ ${name} 必须是数字: ${value}"; exit 1 ;;
    esac
    if [ "$value" -lt 1 ] || [ "$value" -gt 65535 ]; then
        red "❌ ${name} 超出端口范围 1-65535: ${value}"
        exit 1
    fi
}
validate_port FRP_SERVER_PORT "$FRP_SERVER_PORT"

# -v 必填
if [ -z "$FRP_VNC_REMOTE_PORT" ]; then
    red "❌ 必须设置 noVNC 公网端口: -v <PORT>"
    echo ""
    show_help
fi
validate_port FRP_VNC_REMOTE_PORT "$FRP_VNC_REMOTE_PORT"

# SSH = -v+1（未显式指定时）
if [ "$FRP_SSH_EXPLICIT" != "1" ]; then
    FRP_SSH_REMOTE_PORT="$((FRP_VNC_REMOTE_PORT + 1))"
fi
# qwenpaw = -v+2（未显式指定时）
if [ -z "$QWENPAW_REMOTE_PORT" ]; then
    QWENPAW_REMOTE_PORT="$((FRP_VNC_REMOTE_PORT + 2))"
fi

# 0 = 禁用该入口
if [ "$FRP_SSH_REMOTE_PORT" = "0" ]; then
    FRP_SSH_REMOTE_PORT=""
fi
if [ "$QWENPAW_REMOTE_PORT" = "0" ]; then
    QWENPAW_REMOTE_PORT=""
fi

if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    validate_port FRP_SSH_REMOTE_PORT "$FRP_SSH_REMOTE_PORT"
fi
[ -z "$QWENPAW_REMOTE_PORT" ] || validate_port QWENPAW_REMOTE_PORT "$QWENPAW_REMOTE_PORT"

# SSH 和 noVNC 都使用完整 PASSWORD；VNC 不再走 VNC 协议密码认证，
# 而是由 Caddy 在 HTTP/noVNC/WebSocket 层认证，因此没有 8 字符限制。
VNC_PASS="$PASSWORD"

case "$RESOLUTION" in
    [0-9]*x[0-9]*) ;;
    *) red "❌ 分辨率格式应为 WIDTHxHEIGHT: $RESOLUTION"; exit 1 ;;
esac
if printf '%s' "$FRP_TOKEN" | LC_ALL=C grep -q '["[:cntrl:]]'; then
    red "❌ FRP_TOKEN 不能包含双引号或控制字符"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRP_DIR=/home/frp

green "============================================================"
green " QwenPaw + FRP + Chromium 一键部署"
green " FRP服务器: ${FRP_SERVER_IP}:${FRP_SERVER_PORT}"
green " 公网端口: novnc=${FRP_VNC_REMOTE_PORT} ssh=${FRP_SSH_REMOTE_PORT:-关} qwenpaw=${QWENPAW_REMOTE_PORT:-关} (共用密码)"
green "============================================================"

# ============================================================
# 1. 运行依赖自动安装
# ============================================================
# QwenPaw 已安装即可；Chromium/CDP 和默认 VNC/桌面依赖由本脚本补齐，传 -v 0 可关闭 VNC。
APT_UPDATED=no
APT_UPDATE_MAX_AGE="${APT_UPDATE_MAX_AGE:-21600}"  # 默认 6 小时内复用 apt 索引
apt_indexes_fresh() {
    local minutes=$((APT_UPDATE_MAX_AGE / 60))
    [ "$minutes" -ge 1 ] || minutes=1
    [ -d /var/lib/apt/lists ] || return 1
    find /var/lib/apt/lists -type f -mmin "-${minutes}" -print -quit 2>/dev/null | grep -q .
}
apt_install() {
    local packages=("$@")
    [ "${#packages[@]}" -gt 0 ] || return 0
    command -v apt-get >/dev/null 2>&1 || {
        red "❌ 缺少依赖: ${packages[*]}"
        red "❌ 当前系统没有 apt-get，请先安装这些包后重试"
        exit 1
    }
    if [ "$APT_UPDATED" != yes ]; then
        if apt_indexes_fresh; then
            yellow "📦 复用最近的 apt 软件包索引（${APT_UPDATE_MAX_AGE}s 内）"
        else
            yellow "📦 更新 apt 软件包索引..."
            apt-get update
        fi
        APT_UPDATED=yes
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
}

# 安装完整版 Caddy（含 basic_auth 模块）。
# Debian 官方源的 caddy 是精简版，缺 basic_auth/authentication 模块，
# 会导致 noVNC 密码认证完全失效。必须用 Caddy 官方稳定源。
install_caddy_full() {
    if command -v caddy >/dev/null 2>&1; then
        # 已装：检查是否含 basic_auth 模块（完整版才有）
        if caddy list-modules 2>/dev/null | grep -q 'http.handlers.authentication'; then
            return 0
        fi
        yellow "⚠️ 检测到精简版 Caddy（缺 basic_auth 模块），正在升级为完整版..."
        apt-get remove -y -qq caddy 2>/dev/null || true
    fi
    yellow "📦 安装官方完整版 Caddy（含 basic_auth）..."
    command -v gpg >/dev/null 2>&1 || apt_install gnupg
    local keyring=/usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -fsSL 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' 2>/dev/null | \
        gpg --dearmor --yes -o "$keyring" 2>/dev/null || {
            red "❌ 下载 Caddy GPG key 失败"
            exit 1
        }
    cat > /etc/apt/sources.list.d/caddy-stable.list <<LISTEOF
deb [signed-by=${keyring}] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main
LISTEOF
    apt-get update -qq 2>/dev/null || apt-get update 2>/dev/null || apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends caddy || {
        red "❌ 安装官方 Caddy 失败"
        exit 1
    }
    if caddy list-modules 2>/dev/null | grep -q 'http.handlers.authentication'; then
        green "✅ 完整版 Caddy 安装完成（含 basic_auth）"
    else
        red "⚠️ Caddy 安装完成但缺少 basic_auth 模块，noVNC 密码认证可能不生效"
    fi
}

ensure_runtime_dependencies() {
    local packages=()
    local chromium_package=chromium

    command -v curl >/dev/null 2>&1 || packages+=(curl)
    command -v tar >/dev/null 2>&1 || packages+=(tar)
    command -v supervisorctl >/dev/null 2>&1 || packages+=(supervisor)

    if ! command -v chromium >/dev/null 2>&1 \
        && ! command -v chromium-browser >/dev/null 2>&1 \
        && ! command -v google-chrome >/dev/null 2>&1; then
        if command -v apt-cache >/dev/null 2>&1 && apt-cache show chromium >/dev/null 2>&1; then
            chromium_package=chromium
        elif command -v apt-cache >/dev/null 2>&1 && apt-cache show chromium-browser >/dev/null 2>&1; then
            chromium_package=chromium-browser
        else
            # 新装系统可能还没有 apt 索引；先选择 Debian 常用包名，
            # 由 apt_install() 完成 update，失败时再给出真实的软件源错误。
            chromium_package=chromium
        fi
        packages+=("$chromium_package")
    fi

    # 只有用户指定 -v 时才安装完整的可视化浏览器桌面依赖。
    if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
        command -v Xvnc >/dev/null 2>&1 || packages+=(tigervnc-standalone-server)
        command -v vncpasswd >/dev/null 2>&1 || packages+=(tigervnc-common)
        command -v openbox >/dev/null 2>&1 || packages+=(openbox)
        command -v websockify >/dev/null 2>&1 || packages+=(websockify)
        # caddy 不在这里装：必须用完整版（含 basic_auth），见 install_caddy_full
        command -v xrandr >/dev/null 2>&1 || packages+=(x11-xserver-utils)
        [ -d /usr/share/novnc ] || packages+=(novnc)
    fi

    if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
        command -v sshd >/dev/null 2>&1 || packages+=(openssh-server)
    fi
    if [ "${#packages[@]}" -gt 0 ]; then
        yellow "📦 自动安装运行依赖: ${packages[*]}"
        apt_install "${packages[@]}"
    fi
}

ensure_runtime_dependencies
# noVNC 启用时必须用完整版 Caddy（basic_auth 模块），Debian 精简版缺模块
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    install_caddy_full
fi
CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)"

# ============================================================
# 2. NAS 路径自动探测 (不写死, 任意机器可用)
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

QWENPAW_DATA_DIR="${QWENPAW_DATA_DIR:-${QWENPAW_WORKING_DIR:-${HOME:-/root}/.qwenpaw}}"
QWENPAW_SECRET_DIR="${QWENPAW_SECRET_DIR:-${QWENPAW_WORKING_DIR:-${HOME:-/root}/.qwenpaw}.secret}"
CHROMIUM_PROFILE_DIR="${CHROMIUM_PROFILE_DIR:-${NAS_BASE_DIR}/browser/chromium-gui-profile}"
# CDP 浏览器单独使用持久化 profile，不能与 chromium-gui 共用（两个 Chromium 会互相锁 profile）。
CHROMIUM_CDP_PROFILE_DIR="${CHROMIUM_CDP_PROFILE_DIR:-${NAS_BASE_DIR}/browser/chromium-cdp-profile}"
QWENPAW_CONFIG_FILE="${QWENPAW_CONFIG_FILE:-${QWENPAW_WORKING_DIR:-${HOME:-/root}/.qwenpaw}/config.json}"
mkdir -p "$NAS_BASE_DIR"/{qwenpaw-data,browser}
mkdir -p "$CHROMIUM_PROFILE_DIR" "$CHROMIUM_CDP_PROFILE_DIR"

# 兼容旧版本：把尚未重启前仍留在 /tmp 的 CDP profile 迁移到 NAS。
# 仅在目标目录为空时迁移，避免覆盖已经持久化的新 profile。
if [ -d /tmp/chromium-cdp-profile ] && [ -z "$(find "$CHROMIUM_CDP_PROFILE_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
    if cp -a /tmp/chromium-cdp-profile/. "$CHROMIUM_CDP_PROFILE_DIR/" 2>/dev/null; then
        green "✅ 已迁移旧 CDP profile → $CHROMIUM_CDP_PROFILE_DIR"
    else
        yellow "⚠️ 旧 CDP profile 迁移失败，将使用新的持久化目录"
    fi
fi

# ============================================================
# 1.5 supervisor 控制端点探测
# ============================================================
# 不同基础镜像可能使用 /run/supervisor.sock、/var/run/supervisor.sock，
# 或额外的 frp-supervisor.sock；不能把控制 socket 写死。
SUPERVISOR_SOCKET="${SUPERVISOR_SOCKET:-}"

detect_supervisor_socket() {
    [ -n "$SUPERVISOR_SOCKET" ] && [ -S "$SUPERVISOR_SOCKET" ] && return 0
    local candidate cfg socket
    local candidates=(
        /run/supervisor.sock
        /var/run/supervisor.sock
        /run/frp-supervisor.sock
        /var/run/frp-supervisor.sock
    )
    for cfg in \
        /etc/supervisor/supervisord.conf \
        /etc/supervisord.conf \
        /etc/supervisor/conf.d/*.conf; do
        [ -f "$cfg" ] || continue
        while IFS= read -r socket; do
            [ -n "$socket" ] && candidates+=("$socket")
        done < <(awk -F= '/^[[:space:]]*file[[:space:]]*=/{gsub(/[[:space:];].*/, "", $2); print $2}' "$cfg")
    done
    for candidate in "${candidates[@]}"; do
        [ -S "$candidate" ] || continue
        if supervisorctl -s "unix://${candidate}" version >/dev/null 2>&1; then
            SUPERVISOR_SOCKET="$candidate"
            green "✅ supervisor socket: $SUPERVISOR_SOCKET"
            return 0
        fi
    done
    # 兜底：supervisord 未运行时 socket 不存在（socket 由进程运行时创建）。
    # 尝试拉起 supervisord 后再探测一轮，避免部署卡在 supervisorctl 连不上。
    if command -v supervisord >/dev/null 2>&1; then
      yellow "⚙️ supervisor socket 未找到，尝试启动 supervisord 后重试..."
      service supervisor start >/dev/null 2>&1 || \
        systemctl start supervisor >/dev/null 2>&1 || \
        supervisord -c /etc/supervisord.conf >/dev/null 2>&1 || \
        supervisord -c /etc/supervisor/supervisord.conf >/dev/null 2>&1 || \
        supervisord >/dev/null 2>&1 || true
      sleep 2
      for candidate in "${candidates[@]}"; do
        [ -S "$candidate" ] || continue
        if supervisorctl -s "unix://${candidate}" version >/dev/null 2>&1; then
          SUPERVISOR_SOCKET="$candidate"
          green "✅ supervisor socket: $SUPERVISOR_SOCKET（已自动拉起 supervisord）"
          return 0
        fi
      done
    fi
    yellow "⚠️ 未找到可用 supervisor socket（已检查 /run、/var/run 和配置文件）"
    return 1
}

supervisorctl_cmd() {
    command -v supervisorctl >/dev/null 2>&1 || return 1
    [ -n "$SUPERVISOR_SOCKET" ] || detect_supervisor_socket || return 1
    supervisorctl -s "unix://${SUPERVISOR_SOCKET}" "$@"
}

# ============================================================
# 2. chromium CDP 模式检测与修复 (browser_use 依赖)
# ============================================================
configure_qwenpaw_cdp() {
    command -v python3 >/dev/null 2>&1 || {
        red "❌ 原生有头 CDP 模式需要 python3 来更新 QwenPaw 配置"
        exit 1
    }
    mkdir -p "$(dirname "$QWENPAW_CONFIG_FILE")"
    if [ -f "$QWENPAW_CONFIG_FILE" ]; then
        cp -p "$QWENPAW_CONFIG_FILE" "${QWENPAW_CONFIG_FILE}.before-frp-cdp.bak"
    fi
    QWENPAW_CONFIG_FILE="$QWENPAW_CONFIG_FILE" CDP_PORT="$CDP_PORT" CHROMIUM_BIN="$CHROMIUM_BIN" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["QWENPAW_CONFIG_FILE"])
try:
    data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
except Exception as exc:
    raise SystemExit(f"QwenPaw config is not valid JSON: {path}: {exc}")
if not isinstance(data, dict):
    raise SystemExit(f"QwenPaw config root must be an object: {path}")
browser = data.get("browser")
if not isinstance(browser, dict):
    browser = {}
# Official QwenPaw connect_cdp path: attach to the already-running headed Chrome.
browser.update({
    "experimental": True,
    "backend": "connect_cdp",
    "cdp_url": f"http://127.0.0.1:{os.environ['CDP_PORT']}",
    "headless": "false",
    "executable_path": os.environ["CHROMIUM_BIN"],
})
data["browser"] = browser
tmp = path.with_name(path.name + ".tmp")
tmp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
tmp.replace(path)
PY
    chmod 600 "$QWENPAW_CONFIG_FILE" 2>/dev/null || true
    green "✅ QwenPaw 已配置为连接有头 Chromium CDP: 127.0.0.1:${CDP_PORT}"
}

check_cdp() {
    yellow "🔍 检查 chromium CDP 模式..."

    CHROMIUM_BIN="$(command -v chromium || command -v chromium-browser || command -v google-chrome || echo /usr/bin/chromium)"
    if [ ! -x "$CHROMIUM_BIN" ]; then
        red "❌ 未找到 chromium, 请先安装 (apt install chromium)"
        exit 1
    fi

    if [ "${CDP_HEADED:-0}" = "1" ] && [ -n "${FRP_VNC_REMOTE_PORT:-}" ]; then
        CDP_CMD="${CHROMIUM_BIN} --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=${CHROMIUM_CDP_PROFILE_DIR} --window-size=${RESOLUTION} ${CDP_START_URL:-about:blank}"
        CDP_ENV='environment=DISPLAY=":1"'
    else
        CDP_CMD="${CHROMIUM_BIN} --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --disable-setuid-sandbox --remote-debugging-port=${CDP_PORT} --remote-debugging-address=127.0.0.1 --user-data-dir=${CHROMIUM_CDP_PROFILE_DIR} about:blank"
        CDP_ENV=""
    fi
    green "✅ chromium: $CHROMIUM_BIN"

    cdp_ok() {
        curl -s --max-time 2 "http://127.0.0.1:${CDP_PORT}/json/version" 2>/dev/null | grep -q "webSocketDebuggerUrl"
    }
    wait_for_cdp() {
        local attempts="${1:-12}"
        local i
        for i in $(seq 1 "$attempts"); do
            cdp_ok && return 0
            sleep 0.5
        done
        return 1
    }

    # VNC 模式中 chromium-gui 是唯一浏览器，并由它提供 CDP；
    # 绝不再创建第二个无头 chromium-cdp 实例。
    if [ -n "${FRP_VNC_REMOTE_PORT:-}" ]; then
        if wait_for_cdp 30; then
            green "✅ 有头 Chromium CDP 已就绪 (端口 ${CDP_PORT})"
            return 0
        fi
        red "❌ 有头 Chromium CDP 未就绪，请检查 /var/log/chromium-gui.err.log"
        exit 1
    fi

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

    # 每次重跑都刷新 chromium-cdp 的命令，避免旧版配置永久保留。
    if [ "$has_sup" = "yes" ]; then
        awk -v name="chromium-cdp" '
            $0 == "[program:" name "]" { skip=1; next }
            /^\[program:/ { skip=0 }
            !skip { print }
        ' "$SUP_CONF" > "${SUP_CONF}.tmp"
        mv "${SUP_CONF}.tmp" "$SUP_CONF"
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

        if supervisorctl_cmd reread 2>/dev/null && supervisorctl_cmd update 2>/dev/null; then
            supervisorctl_cmd start chromium-cdp 2>/dev/null || true
        else
            yellow "⚠️ supervisor 控制端不可用，跳过 supervisor 启动，改用直接启动 CDP"
        fi

        if wait_for_cdp 12; then
            green "✅ chromium CDP 修复成功 (端口 ${CDP_PORT})"
        else
            yellow "⚠ supervisor 启动失败, 手动启动兜底..."
            nohup $CDP_CMD \
                >/var/log/chromium-cdp.out.log 2>&1 &
            if wait_for_cdp 12; then
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
    TMP_TGZ="${TMP_DIR}.tgz"

    # GitHub Release 可能先跳转到 release-assets.githubusercontent.com；
    # 某些网络对 GitHub 主站、对象存储或 curl 代理支持不同，因此按
    # “官方直链 → 常用镜像”顺序，并分别尝试 curl/wget。
    FRP_URLS=(
        "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"
        "https://gh-proxy.com/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"
        "https://github.moeyy.xyz/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"
        "https://mirror.ghproxy.com/https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${FRP_TAR}"
    )
    DOWNLOAD_OK=no
    for FRP_URL in "${FRP_URLS[@]}"; do
        for DOWNLOADER in curl wget; do
            command -v "$DOWNLOADER" >/dev/null 2>&1 || continue
            rm -f "$TMP_TGZ"
            yellow "📥 尝试下载 frp (${DOWNLOADER}): ${FRP_URL}"
            if [ "$DOWNLOADER" = curl ]; then
                curl -fL --retry 2 --retry-delay 1 --connect-timeout 15 --max-time 180 \
                    -o "$TMP_TGZ" "$FRP_URL" >/dev/null 2>&1 || continue
            else
                wget -q --tries=2 --timeout=20 --max-redirect=10 \
                    -O "$TMP_TGZ" "$FRP_URL" >/dev/null 2>&1 || continue
            fi

            # 镜像偶尔会返回 HTML 错误页；解压并确认包内确有 frpc，
            # 避免把错误页面当作下载成功继续执行。
            if tar -tzf "$TMP_TGZ" >/dev/null 2>&1 \
                && tar -tzf "$TMP_TGZ" | grep -Eq '(^|/)frpc$'; then
                DOWNLOAD_OK=yes
                green "✅ frp 下载成功: ${FRP_URL}"
                break 2
            fi
        done
    done

    if [ "$DOWNLOAD_OK" != yes ]; then
        red "❌ frpc 下载失败：官方 Release、备用镜像及 curl/wget 均未成功"
        yellow "可检查 github.com、objects.githubusercontent.com、release-assets.githubusercontent.com 是否可达"
        rm -f "$TMP_TGZ"
        exit 1
    fi

    mkdir -p "$TMP_DIR"
    tar -xzf "$TMP_TGZ" -C "$TMP_DIR" 2>/dev/null || { red "❌ 解压失败"; rm -rf "$TMP_DIR" "$TMP_TGZ"; exit 1; }
    FRPC_SOURCE="$(find "$TMP_DIR" -name frpc -type f -print -quit)"
    if [ -z "$FRPC_SOURCE" ]; then
        red "❌ 下载包内没有找到 frpc 二进制"
        rm -rf "$TMP_DIR" "$TMP_TGZ"
        exit 1
    fi
    install -m 0755 "$FRPC_SOURCE" "$FRPC_BIN"
    rm -rf "$TMP_DIR" "$TMP_TGZ"
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

# ============================================================
# 3.5 SSH 密码配置（与 VNC 共用 PASSWORD，不使用 SSH key）
# ============================================================
# 容器环境中 bash /dev/tcp 可能误报；优先检查真实 LISTEN 状态，再用连接探测兜底。
port_is_listening() {
    local host="$1" port="$2"
    if command -v ss >/dev/null 2>&1 \
        && ss -ltnH 2>/dev/null | awk -v wanted=":${port}" '$1 == "LISTEN" && $4 ~ (wanted "$") { found=1 } END { exit !found }'; then
        return 0
    fi
    if command -v nc >/dev/null 2>&1 && nc -z -w 2 "$host" "$port" >/dev/null 2>&1; then
        return 0
    fi
    if command -v python3 >/dev/null 2>&1 \
        && python3 - "$host" "$port" <<'PY'
import socket
import sys
try:
    with socket.create_connection((sys.argv[1], int(sys.argv[2])), timeout=2):
        pass
except OSError:
    raise SystemExit(1)
PY
    then
        return 0
    fi
    return 1
}

if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    if [ -z "$PASSWORD" ]; then
        red "❌ 启用 SSH 时必须设置密码: -p <PASS> / -P <PASS> 或 PASSWORD=<PASS>"
        exit 1
    fi
    mkdir -p /run/sshd /etc/ssh/sshd_config.d
    printf 'root:%s\n' "$PASSWORD" | chpasswd
    passwd -u root >/dev/null 2>&1 || true
    printf '%s\n' '# QwenPaw FRP SSH tunnel' 'PermitRootLogin yes' 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/99-frp-tunnel.conf
    if ! /usr/sbin/sshd -t 2>/dev/null; then
        red "❌ sshd 配置检查失败"
        exit 1
    fi
    if pgrep -x sshd >/dev/null 2>&1; then
        pkill -HUP -x sshd 2>/dev/null || true
    else
        /usr/sbin/sshd
    fi
    if ! port_is_listening 127.0.0.1 "$LOCAL_SSH_PORT"; then
        red "❌ sshd 启动异常: 127.0.0.1:${LOCAL_SSH_PORT} 未监听"
        if command -v ss >/dev/null 2>&1; then
            ss -ltnp 2>/dev/null | head -20 || true
        fi
        exit 1
    fi
    green "✅ SSH 已启动并验证（与 VNC 共用密码）"
fi

mkdir -p "$FRP_DIR"
cat > "$FRP_DIR/frpc.toml" <<EOF
serverAddr = "${FRP_SERVER_IP}"
serverPort = ${FRP_SERVER_PORT}

auth.method = "token"
auth.token = "${FRP_TOKEN}"

log.to = "/var/log/frpc.log"
log.level = "error"
log.maxDays = 3
EOF

# qwenpaw 面板映射：走 Caddy 认证端口（basic_auth），暴露到 -v+2
if [ -n "$QWENPAW_REMOTE_PORT" ]; then
    cat >> "$FRP_DIR/frpc.toml" <<EOF

[[proxies]]
name = "qwenpaw_$(hostname)"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${QWENPAW_CADDY_PORT}
remotePort = ${QWENPAW_REMOTE_PORT}
EOF
fi

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

remove_program() {
    local name="$1"
    if grep -q "\[program:${name}\]" "$SUP_CONF" 2>/dev/null; then
        awk -v name="$name" '
            $0 == "[program:" name "]" { skip=1; next }
            /^\[program:/ { skip=0 }
            !skip { print }
        ' "$SUP_CONF" > "${SUP_CONF}.tmp"
        mv "${SUP_CONF}.tmp" "$SUP_CONF"
        yellow "🧹 已移除旧的 [program:${name}] 配置"
    fi
}

append_program() {
    local name="$1" body="$2"
    if grep -q "\[program:${name}\]" "$SUP_CONF" 2>/dev/null; then
        yellow "🔄 [program:${name}] 已存在, 更新配置"
        awk -v name="$name" '
            $0 == "[program:" name "]" { skip=1; next }
            /^\[program:/ { skip=0 }
            !skip { print }
        ' "$SUP_CONF" > "${SUP_CONF}.tmp"
        mv "${SUP_CONF}.tmp" "$SUP_CONF"
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
# chromium-gui.sh - 在 DISPLAY :${VNC_DISPLAY_NUM} (openbox 桌面) 上启动带窗口的 chromium
# 使用 exec 前台运行，确保 supervisor stop 时不会留下孤儿 Chromium。
set -u
NAS_DIR="${CHROMIUM_PROFILE_DIR}"
mkdir -p "\$NAS_DIR"
for i in \$(seq 1 30); do
  [ -S "/tmp/.X11-unix/X${VNC_DISPLAY_NUM}" ] && break
  sleep 0.5
done
export DISPLAY=:${VNC_DISPLAY_NUM}
exec ${CHROMIUM_BIN} \\
  --no-sandbox \\
  --test-type \\
  --remote-debugging-port=${CDP_PORT} \\
  --remote-debugging-address=127.0.0.1 \\
  --remote-allow-origins=http://127.0.0.1:* \\
  --no-first-run \\
  --no-default-browser-check \\
  --disable-sync \\
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
  ${CDP_START_URL:-about:blank}
EOF

    cat > "$VNC_DIR/vnc-browser.sh" <<EOF
#!/bin/bash
# vnc-browser.sh - 暴露 Xvnc 桌面 (DISPLAY :1) 为 noVNC 网页浏览器
set -u
VNC_PORT="\${VNC_PORT:-${VNC_PORT}}"
VNC_DISPLAY="\${VNC_DISPLAY:-:${VNC_DISPLAY_NUM}}"
RFB_PORT=${VNC_RFB_PORT}
VNC_DIR=/mnt/envd/vnc-browser
LOG_DIR=/var/log
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
rm -f /tmp/.X${VNC_DISPLAY#:}-lock 2>/dev/null || true
# 认证方式：VNC 协议密码（VncAuth）。Xvnc 用 ~/.vnc/passwd 校验；
# noVNC 打开时原生弹出密码框，手机/桌面浏览器都无需额外登录页。
cat > /usr/share/novnc/index.html <<'INDEXEOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>VNC Browser</title>
<script>
var base = location.pathname.replace(/index\.html$/, '');
var target = base + 'vnc.html?autoconnect=1&resize=scale&show_dot=0';
if (location.search) target += '&' + location.search.replace(/^\?/, '');
location.replace(target);
</script></head><body>
<p>Redirecting to <a href="vnc.html?autoconnect=1&amp;resize=scale&amp;show_dot=0">VNC Browser...</a></p>
</body></html>
INDEXEOF
AUTO="/usr/share/novnc/vnc.html"
if [ -f "\$AUTO" ]; then
  # 1. iOS Safari 适配：锁定 viewport，防页面级自动放大导致缩放错乱
  if ! grep -q 'novnc-vp-fix' "\$AUTO"; then
    sed -i 's|<meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">|<meta name="viewport" id="novnc-vp-fix" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">|' "\$AUTO" 2>/dev/null || true
    grep -q 'novnc-vp-fix' "\$AUTO" || sed -i 's|<meta name="viewport" content="[^"]*">|<meta name="viewport" id="novnc-vp-fix" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, minimum-scale=1.0, user-scalable=no, viewport-fit=cover">|' "\$AUTO" 2>/dev/null || true
  fi

  # 2. 默认 resize=scale（双保险：URL 参数 + ui.js 默认值）
  if ! grep -q "initSetting('resize','scale')" "\$AUTO"; then
    sed -i "s|UI.initSetting('resize', 'off')|UI.initSetting('resize','scale')|g" "\$AUTO" 2>/dev/null || true
    sed -i "s|UI.initSetting(\"resize\", 'off')|UI.initSetting('resize','scale')|g" "\$AUTO" 2>/dev/null || true
  fi

  # 3. 隐藏连接状态条（"已连接"提醒彻底移除），保留工具栏（设置/剪贴板/缩放可用）
  if ! grep -q 'novnc-hide-status' "\$AUTO"; then
    sed -i 's|</head>|<style id="novnc-hide-status">#noVNC_status{display:none!important;visibility:hidden!important}</style></head>|' "\$AUTO" 2>/dev/null || true
  fi
fi
# websockify 由 supervisor 托管（[program:websockify]），脚本只做 noVNC 页面/认证契约就绪检查。
# 密码在 VNC 协议层校验（VncAuth），noVNC 打开时原生弹密码框，无表单后端。
RFB_PORT=${VNC_RFB_PORT}
for i in $(seq 1 50); do
  if curl -sf -o /dev/null --max-time 2 "http://127.0.0.1:${VNC_PORT}/vnc.html" 2>/dev/null; then
    echo "✅ noVNC 就绪: http://127.0.0.1:${VNC_PORT}/vnc.html (VNC 密码认证)"
    exit 0
  fi
  sleep 0.2
done
echo "⚠️ noVNC 页面未就绪（websockify 可能仍由 supervisor 拉起中），脚本退出由 supervisor 决定重启"
exit 0
EOF

    # noVNC 已切 VNC 协议密码（VncAuth，取共用密码前 8 位）；
    # QwenPaw 面板入口仍用完整密码做 basic_auth（三入口共用密码契约）。
    CADDY_HASH="$(caddy hash-password --plaintext "$PASSWORD")"
    [ -n "$CADDY_HASH" ] || { red "❌ Caddy 无法生成 noVNC 密码哈希"; exit 1; }

    # noVNC 端口由 websockify 直连（VncAuth 协议层认证），Caddy 只做 QwenPaw 面板 basic_auth 入口。
    # 手机浏览器打开 noVNC 端口 → 原生弹密码框 → 直接进桌面，无表单依赖。
    cat > "$VNC_DIR/Caddyfile" <<EOF
:${QWENPAW_CADDY_PORT} {
    basic_auth {
        qwenpaw ${CADDY_HASH}
    }
    reverse_proxy 127.0.0.1:${QWENPAW_PORT}
}
EOF

    chmod 600 "$VNC_DIR/Caddyfile"
    chmod +x "$VNC_DIR"/chromium-gui.sh "$VNC_DIR"/vnc-browser.sh
    cat > "$VNC_DIR/vnc-resize.sh" <<'EOF'
#!/bin/bash
set -u
DISPLAY="${DISPLAY:-:1}"
export DISPLAY
get_size() { xrandr --query | grep -oP '\d+x\d+(?=\s)' | head -1; }
case "${1:-}" in
  phone|mobile|竖屏) xrandr -s 720x1280 2>&1 ;;
  desktop|pc|横屏) xrandr -s 1280x720 2>&1 ;;
  ''|status|current) ;;
  *)
    echo "$1" | grep -qE '^[0-9]+x[0-9]+$' || { echo "用法: $0 [phone|desktop|WxH]"; exit 1; }
    xrandr -s "$1" 2>&1 ;;
esac
echo "当前分辨率: $(get_size)"
EOF
    chmod +x "$VNC_DIR/vnc-resize.sh"
    green "✅ VNC/Chromium 脚本已生成: $VNC_DIR"

# VNC 协议密码（VncAuth）：密码文件用 vncpasswd 生成，密码取共用密码前 8 位
    # （VNC 协议密码最长 8 字符）；Xvnc 用 -PasswordFile 校验，noVNC 原生弹密码框。
    mkdir -p /root/.vnc
    VNC8="${VNC_PASS:0:8}"
    if command -v vncpasswd >/dev/null 2>&1; then
      printf '%s\n%s\n' "$VNC8" "$VNC8" | vncpasswd -f > /root/.vnc/passwd 2>/dev/null && chmod 600 /root/.vnc/passwd
    fi
    # VNC 密码文件固定 16 字节（8 字节加密密码 + 8 字节 padding）。
    # 只判断 -s 非空会放过 8 字节的无效文件，导致 Xvnc 报
    # "SVncAuth: neither Password nor PasswordFile params set" / "No password configured"。
    if [ ! -f /root/.vnc/passwd ] || [ "$(stat -c%s /root/.vnc/passwd 2>/dev/null || echo 0)" -ne 16 ]; then
      red "❌ 无法生成有效的 VNC 密码文件（应 16 字节，实际 $(stat -c%s /root/.vnc/passwd 2>/dev/null || echo 0) 字节；需要 vncpasswd，请安装 tigervnc-common）"
      exit 1
    fi
    green "✅ VNC 密码文件已生成（16 字节，VncAuth 协议层认证）"

    append_program xvnc2 "command=/bin/sh -c \"rm -f /tmp/.X${VNC_DISPLAY_NUM}-lock /tmp/.X11-unix/X${VNC_DISPLAY_NUM}; mkdir -p /tmp/.X11-unix; exec /usr/bin/Xvnc :${VNC_DISPLAY_NUM} -geometry ${RESOLUTION} -depth 24 -SecurityTypes VncAuth -PasswordFile /root/.vnc/passwd -localhost -AcceptSetDesktopSize=1 -AlwaysShared -rfbport ${VNC_RFB_PORT}\"
autostart=true
autorestart=true
priority=10
environment=DISPLAY=\":${VNC_DISPLAY_NUM}\"
stderr_logfile=/var/log/xvnc2.err.log
stdout_logfile=/var/log/xvnc2.out.log"

    # websockify 由 supervisor 托管（不再依赖 vnc-browser.sh 手动后台），崩溃自愈
    append_program websockify "command=/usr/bin/websockify --web /usr/share/novnc ${VNC_PORT} localhost:${VNC_RFB_PORT}
autostart=true
autorestart=true
priority=61
startsecs=5
stderr_logfile=/var/log/websockify.err.log
stdout_logfile=/var/log/websockify.out.log"

    append_program openbox "command=/bin/sh -c 'export DISPLAY=:${VNC_DISPLAY_NUM}; for i in \$(seq 1 200); do [ -S /tmp/.X11-unix/X${VNC_DISPLAY_NUM} ] && break; sleep 0.1; done; exec openbox'
autostart=true
autorestart=true
priority=20
environment=DISPLAY=\":${VNC_DISPLAY_NUM}\"
stderr_logfile=/var/log/openbox.err.log
stdout_logfile=/var/log/openbox.out.log"

    append_program vnc-browser "command=${VNC_DIR}/vnc-browser.sh
autostart=true
autorestart=true
priority=58
startsecs=5
environment=VNC_PORT=\"${VNC_PORT}\",VNC_PASS=\"${VNC_PASS}\"
stderr_logfile=/var/log/vnc-browser.err.log
stdout_logfile=/var/log/vnc-browser.out.log"

    append_program caddy-vnc "command=/usr/bin/caddy run --config ${VNC_DIR}/Caddyfile --adapter caddyfile
autostart=true
autorestart=true
priority=59
startsecs=3
stderr_logfile=/var/log/caddy-vnc.err.log
stdout_logfile=/var/log/caddy-vnc.out.log"

    append_program chromium-gui "command=${VNC_DIR}/chromium-gui.sh
# 有头模式（CDP_HEADED=1）下 chromium-cdp 占桌面，chromium-gui 不自动启动（避免两个浏览器抢桌面）
autostart=$([ "${CDP_HEADED:-0}" = "1" ] && echo false || echo true)
autorestart=true
priority=65
startsecs=10
stderr_logfile=/var/log/chromium-gui.err.log
stdout_logfile=/var/log/chromium-gui.out.log"
fi

# qwenpaw 主服务段: 先移除平台默认的 [program:app]（同名 8088 服务, 避免双实例抢端口）
remove_program app
append_program qwenpaw "command=qwenpaw app --host 0.0.0.0 --port ${QWENPAW_PORT}
autostart=true
autorestart=unexpected
startretries=5
startsecs=10
priority=30
stopwaitsecs=30
environment=PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=\"${CHROMIUM_BIN}\"
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
# NAS/NFS/CSI 挂载异常时，tar 可能长期阻塞；恢复失败不能拖死整次部署。
NAS_RESTORE_TIMEOUT="${NAS_RESTORE_TIMEOUT:-120}"
restore_from_nas() {
    local source="$1" target="$2" label="$3"
    [ -d "$source" ] || return 0
    [ -n "$(ls -A "$source" 2>/dev/null)" ] || return 0
    mkdir -p "$target"
    if timeout --foreground "$NAS_RESTORE_TIMEOUT" \
        sh -c 'tar cf - -C "$1" . 2>/dev/null | tar xf - -C "$2" 2>/dev/null' \
        restore-from-nas "$source" "$target"; then
        green "✅ 恢复 ${label} → $target"
    else
        yellow "⚠️ ${label} 恢复失败或超时（${NAS_RESTORE_TIMEOUT}s），跳过，不影响后续部署"
    fi
}

if [ "${SKIP_NAS_RESTORE:-0}" = "1" ]; then
    yellow "⏭️ SKIP_NAS_RESTORE=1，跳过 NAS 数据恢复"
else
    yellow "♻️ 从 NAS 恢复数据（超时 ${NAS_RESTORE_TIMEOUT}s）..."
    QB="${NAS_BASE_DIR}/qwenpaw-data"
    restore_from_nas "$QB/working" "$QWENPAW_DATA_DIR" "qwenpaw 数据"
    restore_from_nas "$QB/working.secret" "$QWENPAW_SECRET_DIR" "secret"
fi

# ============================================================
# 5.5 部署产物备份到 NAS（scope-panel 范式三层保障之一）
# ============================================================
# 容器重建后 overlay 会清空 /mnt/envd、/home/frp、/etc/supervisor；
# 部署脚本/配置必须同步进 NAS，配合 entrypoint 自愈恢复。
# 备份目录:
#   vnc-backup/scripts/   → VNC 网关脚本（重建后恢复 ${VNC_DIR}）
#   panel-backup/         → supervisor 模板 + entrypoint（重建后恢复 /etc/supervisor）
#   frp-backup/           → frpc 二进制 + recover-frp.sh（重建后恢复 /home/frp）
mkdir -p "${NAS_BASE_DIR}/vnc-backup/scripts" "${NAS_BASE_DIR}/panel-backup" "${NAS_BASE_DIR}/frp-backup" 2>/dev/null
if [ -n "${VNC_DIR:-}" ] && [ -d "${VNC_DIR}" ]; then
    cp -f "${VNC_DIR}/"*.sh "${VNC_DIR}/"*.py "${NAS_BASE_DIR}/vnc-backup/scripts/" 2>/dev/null || true
    [ -f "${VNC_DIR}/Caddyfile" ] && cp -f "${VNC_DIR}/Caddyfile" "${NAS_BASE_DIR}/vnc-backup/scripts/Caddyfile" 2>/dev/null || true
    green "✅ VNC 脚本已备份 → NAS vnc-backup/scripts/ ($(ls "${NAS_BASE_DIR}/vnc-backup/scripts/" | wc -l) 文件)"
fi
if [ -f "${SUP_CONF}" ]; then
    cp -f "${SUP_CONF}" "${NAS_BASE_DIR}/panel-backup/supervisord.conf.new" 2>/dev/null || true
    # 保留占位符规范: 把 8088/实际端口恢复为 ${QWENPAW_PORT}（entrypoint envsubst 需要）
    sed "s/--port ${QWENPAW_PORT}/--port \${QWENPAW_PORT}/" "${SUP_CONF}" > "${NAS_BASE_DIR}/panel-backup/supervisord.conf.template" 2>/dev/null || true
    green "✅ supervisor 模板已备份 → NAS panel-backup/supervisord.conf.template"
fi
if [ -x "${FRPC_BIN:-}" ]; then
    cp -f "${FRPC_BIN}" "${NAS_BASE_DIR}/frp-backup/frpc" 2>/dev/null || true
    green "✅ frpc 二进制已备份 → NAS frp-backup/frpc"
fi

# ============================================================
# 6. 启动全部服务 + 输出
# ============================================================
green "🚀 启动服务..."
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    # VNC 模式只保留 chromium-gui 这一条浏览器进程，避免无头/有头双开。
    supervisorctl_cmd stop chromium-cdp 2>/dev/null || true
    supervisorctl_cmd stop chromium-gui 2>/dev/null || true
    supervisorctl_cmd stop qwenpaw 2>/dev/null || true
    pkill -f "[c]hromium.*--remote-debugging-port=${CDP_PORT}.*--user-data-dir=${CHROMIUM_CDP_PROFILE_DIR}" 2>/dev/null || true
    remove_program chromium-cdp
    configure_qwenpaw_cdp
fi
if supervisorctl_cmd reread 2>/dev/null && supervisorctl_cmd update 2>/dev/null; then
    green "✅ supervisor 配置已重新加载"
else
    yellow "⚠️ supervisor 控制端不可用，服务将由现有入口或直接启动逻辑接管"
fi
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    START_SERVICES=(frpc xvfb openbox vnc-browser caddy-vnc qwenpaw qwenpaw-backup)
    # 无头模式（CDP_HEADED=0）才启动 chromium-gui；有头模式 chromium-cdp 占桌面
    if [ "${CDP_HEADED:-0}" != "1" ]; then
        START_SERVICES+=(chromium-gui)
    fi
else
    START_SERVICES=(frpc qwenpaw qwenpaw-backup)
fi
# supervisorctl 不可用时，从 supervisor 配置段提取 command 并用 nohup 直接拉起，
# 避免 socket 丢失但 supervisord 是 PID 1 无法重启的场景下服务全部没起来。
direct_start_service() {
    local name="$1" conf="/etc/supervisor/conf.d/supervisord.conf" cmd envs bin
    [ -f "$conf" ] || conf="/etc/supervisor/supervisord.conf"
    [ -f "$conf" ] || return 1
    cmd="$(awk -v n="$name" '
        $0 ~ "^\\[program:" n "\\]$" {inp=1; next}
        inp && /^\[/ {exit}
        inp && /^command=/ {sub(/^command=/,""); print; exit}
    ' "$conf")"
    [ -n "$cmd" ] || return 1
    envs="$(awk -v n="$name" '
        $0 ~ "^\\[program:" n "\\]$" {inp=1; next}
        inp && /^\[/ {exit}
        inp && /^environment=/ {sub(/^environment=/,""); gsub(/"/,"",$0); print; exit}
    ' "$conf")"
    bin="$(printf '%s' "$cmd" | awk '{print $1}')"
    command -v "$bin" >/dev/null 2>&1 || return 1
    yellow "⚙️ 直接启动 ${name}: ${cmd%% *}..."
    if [ -n "$envs" ]; then
        ( export $(echo "$envs" | tr ',' ' ') ; nohup bash -c "$cmd" >>/var/log/${name}.direct.log 2>&1 < /dev/null & )
    else
        ( nohup bash -c "$cmd" >>/var/log/${name}.direct.log 2>&1 < /dev/null & )
    fi
    sleep 1
}

# supervisor 自身按传入顺序启动；各桌面脚本内部负责等待显示 socket。
if supervisorctl_cmd start "${START_SERVICES[@]}" 2>/dev/null; then
    green "✅ 服务已交给 supervisor 启动"
else
    yellow "⚠️ supervisor 控制端不可用，改用直接启动方式拉起服务"
    if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
        # xvfb 必须先于 openbox/vnc-browser/chromium 就绪；各脚本内部也会等待 X socket。
        direct_start_service xvfb || true
        sleep 2
        for svc in openbox vnc-browser caddy-vnc frpc qwenpaw qwenpaw-backup chromium-gui; do
            direct_start_service "$svc" || yellow "⚠️ 直接启动 ${svc} 失败（可能未配置）"
            sleep 1
        done
    else
        for svc in frpc qwenpaw qwenpaw-backup; do
            direct_start_service "$svc" || yellow "⚠️ 直接启动 ${svc} 失败（可能未配置）"
            sleep 1
        done
    fi
    green "✅ 直接启动完成，服务已通过 nohup 运行"
fi
check_cdp

clear
green "============================================================"
green "✅ QwenPaw 一键部署完成!"
green ""
if [ -n "$QWENPAW_REMOTE_PORT" ]; then
    green " 🌐 QwenPaw 面板 (密码认证):"
    green "    http://${FRP_SERVER_IP}:${QWENPAW_REMOTE_PORT}   (用户: qwenpaw / 密码: $PASSWORD)"
    green ""
fi
if [ -n "$FRP_VNC_REMOTE_PORT" ]; then
    green " 🖥  noVNC 浏览器桌面:"
    green "    http://${FRP_SERVER_IP}:${FRP_VNC_REMOTE_PORT}/vnc.html"
fi
green ""
if [ -n "$FRP_SSH_REMOTE_PORT" ]; then
    green " 🔑 SSH:"
    green "    ssh -p ${FRP_SSH_REMOTE_PORT} root@${FRP_SERVER_IP}"
    green "    (SSH/VNC 共用密码，密码不会在日志中打印)"
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
supervisorctl_cmd status 2>/dev/null || true
echo ""
green "✅ 全部完成! 如服务未启动请检查: supervisorctl status"