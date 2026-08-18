# 心得：Xvnc 动态分辨率 + 控制栏收起（v5 改造落地）

> 2026-08-14 · chromium-QwenPaw v5
> 核心一句话：**把 v4 学到的 jlesage 架构真正落地——用 TigerVNC 的 Xvnc 替换"Xvfb + x11vnc"两件套，一次解决两个老痛点：分辨率锁死 + noVNC 侧边控制栏默认展开。**

---

## 一、用户需求

1. **手机（720x1280 竖屏）**：noVNC 侧边菜单栏不要一直显示在屏幕旁边，要收起来、界面干净。
2. **电脑用户**：给横屏（1280x720）体验，能自由切换。
3. 单桌面（不要双桌面），默认手机竖屏。

## 二、根因分析（为什么之前做不到）

| 痛点 | 根因 |
|---|---|
| 分辨率锁死 720x1280 | **Xvfb 的 framebuffer 创建时固定**，`xrandr -s 1280x720` 报 `Size not found`。Xvfb 的 RANDR 扩展只支持固定尺寸查询，不支持动态改 |
| 侧边栏一直显示 | 旧入口跳 `vnc_auto.html`（精简 UI）+ 旧脚本 patch 过样式 |

### 关键验证：Xvfb vs Xvnc 动态分辨率

```bash
# Xvfb (失败 - framebuffer 锁死)
Xvfb :1 -screen 0 720x1280x24
$ DISPLAY=:1 xrandr -s 1280x720
Size 1280x720 not found in available modes   # ❌

# Xvnc TigerVNC (成功 - 自带 RANDR 动态分辨率)
Xvnc :1 -geometry 720x1280 -depth 24
$ DISPLAY=:1 xrandr -s 1280x720
# ✅ current 1280x720, 返回码 0
# 且 chromium 主窗口自动跟随: 720x1280 ↔ 1280x720
```

**结论**：jlesage 能切分辨率不是因为 noVNC 多聪明，而是底层用了 **Xvnc（TigerVNC）**，它的 RANDR 实现支持运行时改 framebuffer 尺寸。这是整个方案的灵魂。

## 三、改造方案（新旧对比）

### 旧架构（v4）
```
Xvfb :1 (720x1280 锁死)  →  x11vnc :5900  →  websockify :8080  →  vnc_auto.html (精简, 侧边栏展开)
```

### 新架构（v5）
```
Xvnc :1 (720x1280, 动态)  ──5900──  websockify :8080  →  vnc.html (完整 UI, 控制栏默认收起)
   └─ xrandr -s 1280x720 (任意时刻切横屏)
```

| 层 | 旧 | 新 | 理由 |
|---|---|---|---|
| X Server | Xvfb :1 | **Xvnc :1** | RANDR 动态分辨率 |
| VNC Server | x11vnc :5900 | **Xvnc 内置** :5900 | 少一个进程, 原生 SetDesktopSize |
| Web | websockify :8080 | websockify :8080 | 保留 (Python websockify 自研, 用户钦定) |
| UI | vnc_auto.html | **vnc.html** | 完整 UI, 控制栏默认收起 |
| 控制栏 | 展开 | **收起** | `#noVNC_control_bar { left: -100% }` 默认收起, 蓝色小手柄可展开 |

### supervisor 配置变化
```ini
# 旧: Xvfb
[program:xvfb]
command=/bin/sh -c "rm -f /tmp/.X1-lock ...; exec /usr/bin/Xvfb :1 -screen 0 720x1280x24"

# 新: Xvnc (关键参数)
[program:xvfb]
command=/bin/sh -c "rm -f /tmp/.X1-lock ...; exec /usr/bin/Xvnc :1 -geometry 720x1280 -depth 24 -SecurityTypes None -localhost -AcceptSetDesktopSize=1 -AlwaysShared -rfbport 5900"
```

### 关键坑
1. **supervisor 改了配置必须 `reread` + `update`**，直接 `start` 还是旧命令（踩过，进程显示 `/usr/bin/Xvfb` 一脸懵）。
2. **Xvnc 1.12 语法是 `-geometry WxH` 不是 `-screen 0 WxHxD`**（Xvfb 语法）。`Xvnc -help` 有完整参数。
3. **控制栏默认收起是 noVNC 自带行为**（`base.css` 里 `left: -100%`），只要用 `vnc.html` 完整 UI 就有，不用 patch。旧脚本 patch 的是 `vnc_auto.html` 才需要。

## 四、成果验证

### 手机 720x1280 竖屏
- 控制栏收起：只有左侧一条 ~15px 蓝色手柄，桌面内容完整铺满 ✅
- 点手柄展开设置菜单（Settings/Clipboard/键盘等），再点收起 ✅

### 电脑 1280x720 横屏
```bash
/mnt/envd/vnc-browser/vnc-resize.sh desktop   # 一键切横屏
/mnt/envd/vnc-browser/vnc-resize.sh phone     # 一键切回竖屏
```
- 桌面真横屏（chromium 网页重新排版宽屏）✅
- noVNC 视口 1280x720 下页面自适应 ✅

### 自动化辅助
- `vnc-resize.sh` 支持 `phone|desktop|WxH` 任意分辨率切换
- noVNC 客户端也能发 SetDesktopSize（Xvnc `AcceptSetDesktopSize=1` 原生响应）

## 五、文件清单
- `/mnt/envd/vnc-browser/vnc-browser.sh` — websockify + vnc.html 入口（Xvnc 版）
- `/mnt/envd/vnc-browser/vnc-resize.sh` — 分辨率切换工具
- `/etc/supervisor/conf.d/supervisord.conf` — xvfb 段改为 Xvnc
- `scripts/vnc-browser-xvnc.sh` + `scripts/vnc-resize.sh` — 本仓库同步版

## 六、下一步可做
- [ ] noVNC 前端加分辨率切换按钮（读 xrandr 模式列表，点击即发 SetDesktopSize）
- [ ] 开机自动检测：手机 UA 跳竖屏 / 电脑 UA 跳横屏
- [ ] 把 `vnc-resize.sh` 接入 frp 隧道外网远程切换
