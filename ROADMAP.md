# QwenPaw-Chrome 开发计划（Roadmap）

> 现状基线：VncAuth 原生密码认证 + FRP 公网隧道 + supervisor 托管 + NAS 三层备份自愈。

## P0 ✅ 已完成

- VNC 协议密码认证（VncAuth，16 字节密码文件校验，noVNC 原生弹密码框）
- 多入口共用密码（SSH 完整密码 / VNC 前 8 位 / QwenPaw 面板 basic_auth）
- supervisor 全托管（xvnc2 / openbox / websockify / chromium-gui / frpc / qwenpaw）+ socket 自动拉起兜底 + direct-start 兜底
- NAS 三层备份自愈（vnc-backup / panel-backup / frp-backup），容器重建自动恢复

---

## P1 🔜 SSH 隧道访问 noVNC（公网只留 SSH 一个口）

**动机**：公网 FRP 端口一旦泄露 = 桌面裸奔给别人；SSH 隧道方案公网只暴露 SSH 端口，noVNC 和 QwenPaw 面板都走加密隧道本地访问。

**设计**：

1. 新增部署模式开关 `--tunnel-only`（或 `-tun 1`）：
   - FRP **只映射 SSH 端口**（`-v 0` 语义自动生效：noVNC/QwenPaw 不建公网隧道）
   - 本地 noVNC（8080）/ QwenPaw 面板（8089）照常监听 127.0.0.1
2. 安装成功后自动输出**隧道命令模板**：
   ```bash
   # 电脑（一条命令全进）：
   ssh -L 8080:127.0.0.1:8080 -L 8089:127.0.0.1:8089 -p <SSH端口> root@<VPS>
   # 然后浏览器开 http://localhost:8080/vnc.html（VncAuth 密码框照常）
   # 手机：Termius → 端口转发配置同上
   ```
3. 配合免密：
   - 部署时可选生成 SSH key（`ssh-keygen` + `authorized_keys` 注入），隧道连接免输密码
   - `ServerAliveInterval=30 ServerAliveCountMax=3 ExitOnForwardFailure=yes` 保活参数进模板
4. 输出示例写进安装完成提示 + README「隧道访问」小节

**验收**：手机 Termius 配好转发 → 打开 localhost:8080 → VncAuth 密码框 → 桌面；公网 `nmap` 只能看到 SSH 端口。

---

## P2 🔜 哪吒探针（nezha）监控

**动机**：容器/VPS 资源（CPU/内存/磁盘/流量）和在线状态可视化，异常告警第一时间知道。

**设计**：

1. 新增可选参数（全部可省，不传就不装）：
   ```bash
   --nezha-server <面板地址:端口>   # 或 NEZHA_SERVER
   --nezha-key <agent 密钥>         # 或 NEZHA_KEY
   ```
2. 部署流程：
   - 下载官方 agent（GitHub Release + 备用镜像，参考 frpc 下载的多镜像策略）
   - supervisor 托管 `[program:nezha-agent]`（autorestart 崩溃自愈）+ 开机自启
   - 版本/连接参数写入 `/etc/nezha/`，重建自愈时一并备份到 NAS（纳入 `panel-backup`）
3. 面板侧建议：CPU/内存/在线率看板、离线 5 分钟告警、阈值告警（CPU>80%、磁盘>90%）
4. 与 tunnel-only 模式兼容：探针走独立出站连接，不影响 SSH 单口收敛

**验收**：面板能看到 VPS 在线 + 资源曲线；kill 掉 agent 进程，supervisor 10 秒内拉起，面板无感知。

---

## P3 🔮 远期

- **白屏自愈**：noVNC 断线自动重连 + chromium-gui watchdog（白屏超时自动 reload 页面）
- **多容器编排**：同一 VPS 多套独立 profile（隔离 cookie/数据），`--instance <name>` 参数
- **WebDAV 数据同步**：NAS 备份改走 WebDAV（跨网络，不依赖 NFS 挂载环境）
- **VNC 端口收敛**：websockify 支持 TLS（WSS），浏览器地址栏 https:// 直接访问

---

## 开发顺序建议

1. P1 tunnel-only（改动集中在 install.sh 参数解析 + 完成提示，风险低，收益大）
2. P2 nezha-agent（独立功能，不碰现有链路，随时可并入）
3. P3 按需排期

> 每项落地前先本地验证（测试鸡），再推 main 并打 Release。