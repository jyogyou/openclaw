# OpenClaw + ClawPanel 集成说明

## 用户目标

当前目标是把 `openclaw` 官方 Docker Compose 运行方式与 `clawpanel` 面板整合起来，要求：

- `openclaw` 和 `clawpanel` 使用同一个数据卷
- `openclaw` 和 `clawpanel` 处于同一个网络环境，面板可以无缝控制 OpenClaw
- 新机器上只依赖当前目录内的 `docker-compose.yml` 和 `Dockerfile.clawpanel`
- 执行 `docker compose up -d --build` 后即可完成首次初始化并正常使用
- 后续如果再次修改这套部署，必须同步更新本文件

## 当前实现

当前目录关键文件：

- `docker-compose.yml`
- `docker-setup.sh`
- `Dockerfile.clawpanel`
- `openclaw-compose.service`
- `install-autostart.sh`
- `readme.md`
- `patch-clawpanel-headless.sh`

服务结构：

- `openclaw-gateway`
  - 使用镜像 `ghcr.io/openclaw/openclaw:latest`
  - 使用自定义 `bridge` 网络 `openclaw-net`
  - 通过 `extra_hosts` 注入：
    - `host.docker.internal:host-gateway`
  - 首启自动安装微信 channel 插件：
    - `@tencent-weixin/openclaw-weixin@latest`
  - 共享卷：
    - `./openclaw-data:/home/node/.openclaw`
    - `./openclaw-workspace:/home/node/.openclaw/workspace`
  - 通过端口发布暴露：
    - `18789`：OpenClaw Gateway
- `clawpanel`
  - 通过 `Dockerfile.clawpanel` 构建
  - 使用同一个 `bridge` 网络 `openclaw-net`
  - 通过服务名 `openclaw-gateway` 访问 Gateway
  - 通过 `extra_hosts` 注入：
    - `host.docker.internal:host-gateway`
  - 构建时会应用 `patch-clawpanel-headless.sh`
  - 该补丁为 headless Web 模式补充：
    - 微信插件状态检测接口
    - 微信 `run_channel_action` 登录动作
    - `/__api/events` SSE 事件流
    - Web 模式下的前端事件监听适配
    - `OPENCLAW_GATEWAY_HOST` 环境变量支持
  - 共享卷：
    - `./openclaw-data:/root/.openclaw`
    - `./openclaw-workspace:/root/.openclaw/workspace`
    - `/var/run/docker.sock:/var/run/docker.sock`
  - 通过端口发布暴露：
    - `1420`：ClawPanel Web
- `openclaw-cli`
  - 仅作为可选工具容器
  - 使用 `profiles: ["cli"]`
  - 默认不会在 `docker compose up` 时启动

## GitHub 发布形态

当前已经按 GitHub 项目目录整理为独立子目录：

- `openclaw/`

预期使用方式：

```bash
git clone <repo>
cd openclaw
./docker-setup.sh
```

`docker-setup.sh` 的职责：

- 检测并安装 Docker（缺失时通过 `get.docker.com`）
- 启用并启动 Docker 服务
- 执行 `docker compose up -d --build`
- 等待 `1420` 和 `18789/healthz` 可访问
- 校验微信插件已自动安装
- 安装 `openclaw-compose.service` 到 systemd，实现开机自动启动
- 清理 Docker build cache

当前已验证：

- 新目录下可直接执行 `docker compose up -d --no-build` 独立启动
- `openclaw-data/openclaw.json` 会自动生成
- `openclaw-data/extensions/openclaw-weixin/package.json` 会自动生成
- `http://127.0.0.1:1420` 正常返回 `200`
- `http://127.0.0.1:18789/healthz` 返回 `{"ok":true,"status":"live"}`
- `GET /__api/check_weixin_plugin_status` 返回：
  - `installed: true`
  - `installedVersion: 2.1.1`
  - `compatible: true`
- `clawpanel` 容器内可解析：
  - `openclaw-gateway`
  - `host.docker.internal`
- `clawpanel` 容器内请求 `http://openclaw-gateway:18789/healthz` 返回 `{"ok":true,"status":"live"}`
- `ws://127.0.0.1:1420/ws` 在 bridge 模式下握手成功
- 微信扫码登录事件流在 bridge 模式下可收到真实二维码链接：
  - `https://liteapp.weixin.qq.com/q/...`

## 开机自动启动

当前要求新增：

- 宿主机开机后自动拉起这套 Docker Compose
- 自动启动 `openclaw-gateway`

结论：

- 仅靠 `docker-compose.yml` 无法直接修改新机器的宿主机开机启动配置
- Compose 只能通过 `restart: unless-stopped` 保证“容器已经创建过以后，Docker 重启时容器自动恢复”
- 如果要把“宿主机开机自启这套项目”也一起装好，最佳方式是额外提供一个宿主机脚本

当前状态：

- Docker 服务已设置为开机启动
- `openclaw-gateway` 使用 `restart: unless-stopped`
- `clawpanel` 使用 `restart: unless-stopped`

因此，在宿主机上至少执行过一次：

```bash
docker compose up -d --build
```

之后只要 Docker 在系统启动时自动启动，宿主机重启后：

- `openclaw-gateway` 会自动启动
- `clawpanel` 会自动启动

这已经满足“开机自动启动并启动 gateway”的核心需求。

另外，仓库内还提供了一个 systemd 单元模板：

- `openclaw-compose.service`

### 2026-03-30 开机自启修复

问题现象（用户反馈）：

- 机器重启后 `openclaw` 栈无法稳定自动恢复

根因分析：

- 旧版 `openclaw-compose.service` 使用：
  - `ExecStart=docker compose up -d --build`
  - `ExecStop=docker compose down`
- 关机阶段执行 `compose down` 会删除容器
- 下次开机必须重新 build/创建，启动链路对网络和构建环境敏感，失败概率高

修复方案：

- `openclaw-compose.service` 改为：
  - `ExecStart=docker compose up -d --no-build --remove-orphans`
  - 删除 `ExecStop`
  - 增加 `Restart=on-failure` 与 `RestartSec=10s`
- `install-autostart.sh` 增加安装阶段的一次性预构建：
  - `docker compose up -d --build`
  - 然后再 `systemctl restart openclaw-compose.service`

这样做的目的：

- 把“构建”放到人工安装阶段
- 把“开机恢复”简化成只拉起已有容器
- 避免关机时删容器，确保 Docker `restart: unless-stopped` 能发挥作用

更推荐的方式：

- 使用 `install-autostart.sh`

原因：

- 它会按脚本所在目录自动生成正确的 `WorkingDirectory`
- 不依赖固定路径如 `/home/user/openclaw`
- 更适合把整套文件复制到另一台新 Linux 机器后直接安装
- 会同时执行：
  - `systemctl enable docker`
  - 安装 `openclaw-compose.service`
  - `systemctl enable openclaw-compose.service`
  - `systemctl restart openclaw-compose.service`

用途：

- 让系统在开机时主动执行当前目录的 `docker compose up -d --no-build --remove-orphans`
- 在某些需要“项目级启动入口”的机器上作为补充方案使用

注意：

- 安装该 systemd 服务需要 root 权限
- 本次会话已生成模板文件，但当前环境无权限写入 `/etc/systemd/system`

如果只是依赖 Docker 自身恢复已创建容器：

```bash
docker compose up -d --build
```

如果要在新机器上连宿主机开机自启也一起装好，推荐执行：

```bash
sudo bash ./install-autostart.sh
```

脚本要求：

- Linux 使用 systemd
- 已安装 Docker 和 Docker Compose
- 以 root 身份执行

如后续在有 root 权限的机器上想手工安装，也可执行：

```bash
sudo install -m 0644 /home/user/openclaw/openclaw-compose.service /etc/systemd/system/openclaw-compose.service
sudo systemctl daemon-reload
sudo systemctl enable openclaw-compose.service
sudo systemctl start openclaw-compose.service
```

## 已解决的问题

### 1. `clawpanel` 能启动，但 `1420` 无法访问

根因不是面板没监听，而是 `clawpanel` 复用了 `openclaw-gateway` 的网络命名空间，所以宿主机端口映射实际挂在 `openclaw-gateway` 上。之前网关因为启动失败不断重启，导致 `1420` 端口也不可用。

后续又确认了第二层问题：

- 在 Linux 上，`network_mode: service:openclaw-gateway` + bridge 端口发布 对 `1420` 表现不稳定
- 容器内 `clawpanel` 可正常返回 HTML，但宿主机访问 `1420` 会出现 `connection reset` / `empty reply`

曾经的临时处理方式是：

- `openclaw-gateway` 改为 `network_mode: "host"`
- `clawpanel` 继续共享 `openclaw-gateway` 的网络命名空间

这能绕过 Linux 上的端口发布异常，但安全边界太弱，容器会直接处于宿主机网络命名空间。

当前正式处理方式已改为：

- 使用自定义 `bridge` 网络 `openclaw-net`
- `openclaw-gateway` 单独发布 `18789:18789`
- `clawpanel` 单独发布 `1420:1420`
- `clawpanel` 通过 `OPENCLAW_GATEWAY_HOST=openclaw-gateway` 访问 Gateway
- 为容器注入 `host.docker.internal:host-gateway`

最终验证结果：

- `1420` 可正常访问
- `18789/healthz` 正常
- `clawpanel -> openclaw-gateway` 的 WebSocket 代理在 bridge 模式下仍能正常握手
- 微信插件检测与扫码登录链路保持正常

### 2. `openclaw-gateway` 首次启动缺配置直接退出

日志报错：

`Missing config. Run openclaw setup or set gateway.mode=local (or pass --allow-unconfigured).`

处理方式：

- 启动参数增加 `--allow-unconfigured`
- 在 `openclaw-gateway` 启动命令中加入首启初始化逻辑
- 若共享卷中不存在 `openclaw.json`，自动执行：
  - `openclaw config set gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback true --strict-json`

这样首次启动会自动生成最小可用配置，不再依赖交互式 setup

### 3. 共享卷权限冲突

`clawpanel` 首先以 `root` 向共享目录写入文件，而 OpenClaw 镜像默认用户写入同一目录时会触发 `EACCES`。

处理方式：

- `openclaw-gateway` 显式使用 `user: "0:0"`
- `openclaw-cli` 也显式使用 `user: "0:0"`

目标是保证混合部署场景下共享卷可写，避免因 UID 不一致导致网关反复重启

### 4. `openclaw-cli` 默认退出造成误判

之前 `openclaw-cli` 作为常驻服务启动，但实际只打印 help 后退出。

处理方式：

- 改为 `profiles: ["cli"]`
- 默认 `docker compose up -d --build` 不再启动它

如需使用：

```bash
docker compose --profile cli run --rm openclaw-cli <command>
```

### 5. 需要预装微信 channel 插件，并让 ClawPanel 发现它

已确认当前微信插件正确包名为：

- `@tencent-weixin/openclaw-weixin@latest`

OpenClaw 安装后的实际插件 ID 为：

- `openclaw-weixin`

安装路径为：

- `~/.openclaw/extensions/openclaw-weixin`

处理方式：

- 在 `openclaw-gateway` 启动命令中加入首启检查
- 若不存在 `openclaw-weixin/package.json`，则自动执行：
  - `openclaw plugins install @tencent-weixin/openclaw-weixin@latest`

安装完成后 OpenClaw 会自动写入：

- `plugins.entries.openclaw-weixin.enabled=true`
- `plugins.installs.openclaw-weixin.*`

另外，ClawPanel 的 headless Web 模式原本缺少微信插件状态检测接口，因此补充了：

- `POST /__api/check_weixin_plugin_status`

该接口会检测：

- 插件是否已安装
- 当前已安装版本
- npm 最新版本
- 是否存在更新
- 与当前 OpenClaw 版本是否兼容

### 6. 点击“扫码登录”只显示 `channels.downloadingPlugin`

现象：

- 点击微信的“扫码登录”后，面板下方一直显示 `channels.downloadingPlugin`
- 不会继续出现“正在启动微信扫码登录...”
- 也不会渲染二维码

根因：

- 运行中的 headless Web 版 ClawPanel 只有 `check_weixin_plugin_status`
- 缺少 `run_channel_action`
- 缺少 Web 模式的事件通道，前端收不到 `channel-action-log` / `channel-action-progress`
- 因此前端只能停留在默认占位提示
- 另外，`src/pages/channels.js` 内实际有两套“渠道动作弹窗”逻辑
- 第一轮补丁只覆盖了其中一套
- 页面实际走到另一套分支时，虽然后端已经开始执行微信登录，但前端没有把二维码日志和二维码链接渲染出来

处理方式：

- 在 `patch-clawpanel-headless.sh` 中补充：
  - `POST /__api/run_channel_action`
  - `GET /__api/events`（SSE）
  - `channels.js` 的 `listenPanelEvent()`，在非 Tauri 环境下改用 `EventSource('/__api/events')`
- 将 `channels.js` 中所有 `@tauri-apps/api/event` 的 `listen` 动态导入统一替换为 `listenPanelEvent`
- 将第二套“渠道动作弹窗”逻辑也补齐：
  - 进度事件监听
  - 微信二维码字符块转图片
  - 微信 `liteapp.weixin.qq.com/q/...` 链接转二维码图片
  - `action-loading-hint` 占位文案自动移除
- `run_channel_action` 中支持：
  - `weixin/login`
  - `weixin/install`
- 执行登录时实时转发 stdout/stderr 到前端

验证结果：

- `GET /__api/events` 能持续收到：
  - `channel-action-progress`
  - `channel-action-log`
- `POST /__api/run_channel_action` 不再返回“未实现的命令”
- 在容器内执行：

```bash
HOME=/root openclaw channels login --channel openclaw-weixin
```

已确认会输出：

- `正在启动微信扫码登录...`
- 终端二维码
- 微信二维码链接，例如：
  - `https://liteapp.weixin.qq.com/q/...`

因此当前修复结果是：

- 前端不再卡在 `channels.downloadingPlugin`
- 扫码登录链路已具备拿到二维码并展示的能力
- 当前已再次验证，SSE 中能收到真实微信二维码链接，例如：
  - `https://liteapp.weixin.qq.com/q/7GiQu1?qrcode=...&bot_type=3`
- 若浏览器标签页是旧的，需强制刷新一次页面，以加载新的 `index-CzzH5wkr.js`

### 6.1 进入面板后网关状态显示“关闭”，并在 `clawpanel` 容器内误启动本地网关

现象：

- Docker 双容器部署下，`openclaw-gateway` 实际在运行，但面板偶发显示 Gateway 关闭
- 触发自动重启后，会在 `clawpanel` 容器内额外拉起一个本地 `openclaw-gateway`
- 导致“状态显示”和“真实对外网关”不一致，且有双进程竞争共享卷风险

根因：

- `get_services_status` 的 Linux 分支优先按本机端口检测
- Docker 场景真实网关在 `OPENCLAW_GATEWAY_HOST=openclaw-gateway`，不是 `clawpanel` 容器本机
- `start_service/restart_gateway/reload_gateway` 也默认操作本机进程，导致误拉起

处理方式（`patch-clawpanel-headless.sh`）：

- 新增远端网关运行时判定：当 `OPENCLAW_GATEWAY_HOST` 不是 loopback，走远端模式
- `get_services_status`：
  - 优先通过 Docker Socket 查询 `openclaw-gateway` 容器状态与 PID
  - 兜底用 `OPENCLAW_GATEWAY_HOST:gateway.port` 做 TCP 连通探测
- `start_service/stop_service/restart_service/reload_gateway/restart_gateway`：
  - 远端模式下改为直接操作网关容器（Docker API 的 start/stop/restart）
  - 本机模式仍保持原来的 Linux/Mac/Windows 行为

验证结果：

- `docker top clawpanel` 不再出现本地 `openclaw-gateway` 进程
- `POST /__api/get_services_status` 返回：
  - `running: true`
  - `pid` 为 `openclaw-gateway` 容器主进程 PID
- `POST /__api/restart_gateway` 会重启 `openclaw-gateway` 容器本身，不会在 `clawpanel` 容器新起网关

### 6.2 `channels.downloadingPlugin` 文案在旧分支仍可能直接显示 key 名

现象：

- `channels.js` 内存在两套渠道动作弹窗逻辑
- 第一套分支仍使用 `t('channels.downloadingPlugin') || ...`，当 key 缺失时会显示 `channels.downloadingPlugin`

处理方式：

- 两套分支都增加“缺失 key 名回退判断”
- 当 `t(...)` 返回 `channels.xxx` 原始 key 时，统一显示中文兜底文案

验证结果：

- 运行中代码已确认两处都包含 fallback 判断
- 不再直接向用户展示 `channels.downloadingPlugin` / `channels.weixinOpenInBrowser` key 名

### 6.3 微信扫码登录报 `duplicate plugin id` / `Cannot find module 'zod'`

现象（2026-03-30 新反馈）：

- 手动执行 `openclaw channels login --channel openclaw-weixin` 时失败
- 日志出现：
  - `duplicate plugin id detected`
  - `Cannot find module 'zod'`
  - 路径包含 `.openclaw-install-stage-*`

根因：

- 微信插件安装中断后，`~/.openclaw/extensions/.openclaw-install-stage-*` 临时目录残留
- OpenClaw 在 `plugins.allow` 为空时会扫描非内置插件目录
- 残留目录会被当成候选插件参与加载，触发重复 ID 或缺依赖报错，最终导致扫码流程卡死

修复：

- `docker-compose.yml` 的 `openclaw-gateway` 启动命令新增自愈逻辑：
  - 每次启动先清理 `.openclaw-install-stage-*`
  - 若 `openclaw-weixin` 缺少 `package.json`，先在临时 HOME 完成安装，再覆盖到共享卷
  - 若 `node_modules/zod/package.json` 缺失，执行 `plugins update openclaw-weixin` 修复依赖
- `docker-setup.sh` 的 `ensure_weixin_plugin` 增强为：
  - 先清理残留 stage 目录
  - 校验插件主文件 + `zod` 依赖完整性
  - 不完整时走“临时 HOME 安装 -> 回填共享卷 -> 再校验”的非破坏式修复流程

验证结果：

- 人工注入 `.openclaw-install-stage-*` 异常目录后，CLI 登录命令会失败（已复现）
- 重启 `openclaw-gateway` 后，stage 目录会被自动清除
- 再次执行微信登录命令可恢复输出二维码与 `liteapp.weixin.qq.com/q/...` 登录链接

### 7. 镜像体积与磁盘优化

为减少重建时磁盘占用，`Dockerfile.clawpanel` 已做两点优化：

- `apt-get install` 改为 `--no-install-recommends`
- 移除了不必要的 `docker.io`

原因：

- ClawPanel 当前通过 `/var/run/docker.sock` 和内置 HTTP 逻辑访问 Docker
- 并不依赖容器内完整的 Docker daemon / CLI 套件
- 该改动可明显减少镜像层体积与构建临时占用

## 首次部署行为

在新机器、空目录、只有这两个文件时，执行：

```bash
docker compose up -d --build
```

预期行为：

1. 自动构建 `clawpanel` 镜像
2. 自动创建 `openclaw-data` 和 `openclaw-workspace`
3. 自动生成 `openclaw-data/openclaw.json`
4. 自动生成 `openclaw-data/clawpanel.json`
5. 自动生成 OpenClaw Gateway token
6. 自动安装 `openclaw-weixin` 插件
7. ClawPanel 可检测到微信插件已安装
8. `1420` 可访问
9. `18789/healthz` 返回健康状态

补充说明：

- 当前方案默认面向 Linux
- 当前采用自定义 `bridge` 网络 `openclaw-net`，宿主机发布端口为 `1420`（面板）和 `18789`（Gateway）

## 首次登录信息

- ClawPanel 访问地址：`http://<host>:1420`
- OpenClaw Health：`http://<host>:18789/healthz`
- ClawPanel 默认密码：`123456`
- 首次登录后 ClawPanel 会强制修改密码

## 已验证结果

本次已完成两轮验证：

### 1. 当前工作目录验证

目录：

- `/home/user/openclaw`

验证结果：

- `docker compose ps` 显示 `openclaw-gateway` 为 `healthy`
- `curl http://127.0.0.1:1420` 返回 `HTTP/1.1 200 OK`
- `curl http://127.0.0.1:18789/healthz` 返回 `{"ok":true,"status":"live"}`
- `docker compose ps` 显示 `0.0.0.0:1420->1420/tcp` 与 `0.0.0.0:18789->18789/tcp`，这是 `bridge` 网络端口发布的正常表现
- `POST /__api/check_weixin_plugin_status`（登录后）返回：
  - `installed: true`
  - `installedVersion: 2.1.1`
  - `latestVersion: 2.1.1`
  - `compatible: true`

### 2. 新机器冷启动模拟验证

使用全新临时目录，仅复制：

- `docker-compose.yml`
- `Dockerfile.clawpanel`

验证结果：

- 首启自动生成 `openclaw.json`
- 首启自动生成 `clawpanel.json`
- `1420` 可访问
- `18789/healthz` 返回健康状态
- 当前部署逻辑包含微信插件首启自动安装

### 3. 当前机器自动启动条件验证

验证结果：

- `systemctl is-enabled docker` 返回 `enabled`
- `systemctl is-active docker` 返回 `active`
- 结合 compose 内的 `restart: unless-stopped`，当前机器重启后会自动拉起 `openclaw-gateway` 和 `clawpanel`
- 已生成 `openclaw-compose.service` 模板文件，供后续具备 root 权限时安装
- 已新增 `install-autostart.sh`，用于在其他新机器上一键安装宿主机级开机自启动

## 当前配置中的安全说明

为了让 `--bind lan` 在新机器上开箱即用，当前自动写入了：

`gateway.controlUi.dangerouslyAllowHostHeaderOriginFallback=true`

这能解决新版 OpenClaw 在非回环地址下的 Control UI 来源校验问题，但也会降低来源校验强度。

如果未来需要公网暴露或更严格的安全配置，建议改为：

- 使用明确的 `gateway.controlUi.allowedOrigins`
- 不再依赖 `dangerouslyAllowHostHeaderOriginFallback`

## 后续维护约定

后续只要对这套 OpenClaw + ClawPanel 集成做了任何修改，都必须同步更新本文件，包括但不限于：

- 端口变化
- 卷挂载变化
- 网络模式变化
- Linux host 网络依赖变化
- 开机启动策略变化
- 自动安装脚本变化
- 微信插件自动安装逻辑变化
- ClawPanel headless 补丁变化
- 首启初始化逻辑变化
- 默认密码/认证方式变化
- 镜像来源变化
- 故障处理结论
- 新增限制和注意事项

## 未来排障时优先检查

如果后续再次出现问题，优先检查：

1. `docker compose ps`
2. `docker compose logs --tail=100 openclaw-gateway clawpanel`
3. `curl -i http://127.0.0.1:1420`
4. `curl -i http://127.0.0.1:18789/healthz`
5. `openclaw-data/openclaw.json` 是否存在
6. `openclaw-data/clawpanel.json` 是否存在
7. 共享卷文件权限是否被其他运行方式破坏

## 文档位置

本说明文件路径：

- `/home/user/openclaw/OPENCLAW_CLAWPANEL_SETUP.md`
