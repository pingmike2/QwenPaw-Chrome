#!/bin/bash
# vnc-resize.sh - 动态切换虚拟桌面分辨率 (Xvnc TigerVNC 原生支持 RandR)
# 用法:
#   vnc-resize.sh          # 显示当前分辨率
#   vnc-resize.sh phone    # 720x1280 竖屏 (手机)
#   vnc-resize.sh desktop  # 1280x720 横屏 (电脑)
#   vnc-resize.sh 1920x1080 # 任意分辨率
set -u
DISPLAY="${DISPLAY:-:1}"
export DISPLAY

get_size() {
  xrandr --query | grep -oP '\d+x\d+(?=\s)' | head -1
}

case "${1:-}" in
  phone|mobile|竖屏)
    xrandr -s 720x1280 2>&1
    ;;
  desktop|pc|横屏)
    xrandr -s 1280x720 2>&1
    ;;
  ''|status|current)
    echo "当前分辨率: $(get_size)"
    ;;
  *)
    if echo "$1" | grep -qE '^[0-9]+x[0-9]+$'; then
      xrandr -s "$1" 2>&1
    else
      echo "用法: $0 [phone|desktop|WxH]"
      exit 1
    fi
    ;;
esac
echo "当前分辨率: $(get_size)"
