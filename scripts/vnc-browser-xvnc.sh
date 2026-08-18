#!/bin/bash
# vnc-browser-xvnc.sh - noVNC 表单登录网关
# 架构: Xvnc :1 -> login_frontend.py :18080 -> Caddy :8080
set -u
VNC_PORT="${VNC_PORT:-8080}"
VNC_BACKEND_PORT="${VNC_BACKEND_PORT:-18080}"
VNC_DISPLAY="${VNC_DISPLAY:-:1}"
RFB_PORT="${RFB_PORT:-5900}"
VNC_USER="${VNC_USER:-qwenpaw}"
VNC_PASS="${VNC_PASS:-${PASSWORD:-qwenpaw}}"
VNC_DIR="${VNC_DIR:-$(cd "$(dirname "$0")" && pwd)}"
LOG_DIR="${LOG_DIR:-/var/log}"

for i in $(seq 1 50); do
  [ -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] && break
  sleep 0.2
done
[ -S "/tmp/.X11-unix/X${VNC_DISPLAY#:}" ] || {
  echo "❌ DISPLAY ${VNC_DISPLAY} 不存在" >&2
  exit 1
}

export VNC_PORT="$VNC_BACKEND_PORT" VNC_WEB_DIR="${VNC_WEB_DIR:-/usr/share/novnc}"
export RFB_PORT VNC_AUTH_USER="$VNC_USER" VNC_AUTH_PASS="$VNC_PASS"
exec python3 "$VNC_DIR/login_frontend.py" \
  >"$LOG_DIR/novnc.log" 2>&1
