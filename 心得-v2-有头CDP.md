# 心得：chromium-cdp 有头化 — 让人机同屏（v2 改造记录）

> 2026-08-14 · chromium-QwenPaw v2
> 核心一句话：**把 AI 自动化用的那个 Chromium（CDP 9222）从无头改成有头，直接显示在 VNC 桌面上，AI 操作浏览器时用户实时可见。**

---

## 一、为什么做这次改造

v1 架构里有两个浏览器各干各的：

```
VNC 桌面 (Xvfb :1)
  ├── chromium-gui   ← 用户看到/操作的全屏浏览器 (Bing 首页)
  └── chromium-cdp   ← AI 自动化用的 (--headless=new, 9222 端口) ← 用户看不见
```

痛点：

1. **用户不知道 AI 在浏览器里干什么**。chromium-cdp 是无头模式，AI 打开网页、点按钮、填表单，全部在黑盒里进行，VNC 上只有 Bing 页面干瞪眼。
2. **两个浏览器两个 profile，互不相通**。用户在 VNC 里登录的网站，AI 那边没有登录态；AI 打开的页面用户也看不到。
3. 用户明确说"**打开 vnc 应该就是 chromium-cdp 有头界面**"——要的是**人机同屏**：AI 点哪里，我都能看到。

## 二、核心改动

### 1. chromium-cdp 去 `--headless=new`，加 `DISPLAY=:1`

```bash
# 改前 (无头)
/usr/bin/chromium --headless=new --no-sandbox ... --remote-debugging-port=9222 ... about:blank

# 改后 (有头, 显示在 VNC)
/usr/bin/chromium --no-sandbox ... --remote-debugging-port=9222 --user-data-dir=/tmp/chromium-cdp-profile \
  --window-size=720,1280 https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo
# supervisor 段加:
environment=DISPLAY=":1"
```

要点：
- **CDP 不受影响**：`--remote-debugging-port=9222` 在有头模式下照样工作，`browser_use connect_cdp` 无缝接管。
- **去掉 `--kiosk`**：之前为了盖住 xfce4 任务栏加了 kiosk，结果把浏览器自己的标签栏/地址栏也藏了。用户要的是**完整浏览器 UI**（标签栏+地址栏+正常窗口），所以去掉 kiosk。
- **启动页自定义**：用户不要 Bing 启动页，改为 Tampermonkey 扩展商店页（用户要装油猴）。

### 2. install.sh 加 CDP_HEADED / CDP_START_URL 开关

```bash
CDP_HEADED="${CDP_HEADED:-1}"   # 1=有头(VNC可见,默认) 0=无头(省内存)
CDP_START_URL="${CDP_START_URL:-https://chromewebstore.google.com/detail/tampermonkey/dhdgffkkebhmkfjojejmpbldmpobfkfo}"
```

- 有头时：`command=... --window-size=${RESOLUTION} ${CDP_START_URL}` + `environment=DISPLAY=":1"`
- 无头时：保持原 `--headless=new about:blank`
- 有头时 `chromium-gui` 的 autostart 自动设 `false`（避免两个浏览器抢 VNC 桌面）；无头时才自动起 chromium-gui

### 3. README 更新架构说明

- "两个浏览器各司其职" → "浏览器架构（v2 有头合一模式，默认）"
- 表格更新：chromium-cdp = 有头（可视化，默认）＋ 人机同屏说明
- 可配置项表加 `CDP_HEADED` / `CDP_START_URL`

## 三、踩坑记录

| 坑 | 现象 | 解决 |
|----|------|------|
| `--kiosk` 藏了浏览器 UI | VNC 里只有裸网页，没有标签栏/地址栏 | 去掉 `--kiosk`，用正常窗口模式 |
| 无头改有头后 CDP 失效担心 | — | 实测 `connect_cdp` 正常接管 9222，有头模式 CDP 完全兼容 |
| 两个 chromium 抢桌面 | chromium-gui (Bing) 和 chromium-cdp 同时显示在 VNC | 有头模式时 chromium-gui autostart=false |
| supervisor template 不同步 | 只改 conf 不改 template，容器重建后配置回滚 | conf + template 两处都改（项目铁律） |

## 四、最终效果

```
VNC 桌面 (Xvfb :1)
  └── chromium-cdp (有头)  ← AI 操作的这个, 用户也看得到!
        ├── CDP 9222 (browser_use 接管)
        └── 完整浏览器 UI (标签栏 + 地址栏)
             └── Tampermonkey 商店页 (可装油猴脚本)
```

**人机同屏**：AI 打开什么网页、点什么按钮，用户通过 noVNC 实时看到。用户也可以手动操作（点链接、滚动、输入），AI 与用户共享同一个浏览器实例。

## 五、心得

1. **用户要的"浏览器"是 AI 在用的那个**。之前一直把"用户看的浏览器"和"AI 用的浏览器"分开设计，但用户真正想要的是一体的——你帮我干活，我得看着你干。
2. **kiosk 全屏不是万能的**。盖住任务栏的同时会牺牲浏览器原生 UI，用户要完整浏览器界面时别用。
3. **CDP 与有头模式天然兼容**。`--remote-debugging-port` 不要求无头，有头 + CDP 是"可观察自动化"的正确姿势。
4. **配置双写是铁律**：supervisor conf 和 template 必须同步，否则容器一重建就回滚。
