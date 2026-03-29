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

- 让系统在开机时主动执行当前目录的 `docker compose up -d --build`
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
- 因使用 `network_mode: "host"`，宿主机上的 `1420/18789/18790` 不能被其他进程占用

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
- 修复后 `docker compose ps` 不再显示端口映射，这是 `host` 网络模式下的正常表现
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
