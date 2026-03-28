# OpenClaw + ClawPanel One-Click Docker Deploy

这个目录用于在一台全新的 Linux 机器上，一次性部署：

- `openclaw` 官方 gateway
- `clawpanel` Web 面板
- 微信 channel 插件 `@tencent-weixin/openclaw-weixin`
- 开机自动启动的 Docker Compose systemd 服务

部署目标：

- `clawpanel` 和 `openclaw` 共用同一份数据目录
- `clawpanel` 能直接控制 `openclaw gateway`
- 首次启动自动完成 OpenClaw 最小初始化
- 首次启动自动安装微信插件
- 面板中可识别微信插件，并可直接执行微信扫码登录

## 使用方式

```bash
git clone <your-repo-url>
cd openclaw
chmod +x docker-setup.sh install-autostart.sh patch-clawpanel-headless.sh
./docker-setup.sh
```

脚本会自动完成：

- 缺少 Docker 时，使用官方 `get.docker.com` 安装 Docker
- 启动并启用 Docker 服务
- `docker compose up -d --build`
- 等待 `openclaw-gateway` 和 `clawpanel` 可访问
- 校验并确保微信插件已安装
- 安装 `openclaw-compose.service`，实现开机自动启动
- 清理 build cache，减少磁盘占用

## 部署完成后

访问：

- ClawPanel: `http://127.0.0.1:1420`
- Gateway health: `http://127.0.0.1:18789/healthz`

局域网访问：

- `http://你的服务器IP:1420`

默认信息：

- ClawPanel 默认密码：`123456`
- 首次登录后建议立即修改密码

## 目录说明

- `docker-compose.yml`
  - OpenClaw 官方 gateway + ClawPanel 集成编排
- `Dockerfile.clawpanel`
  - 构建 Web headless 版 ClawPanel
- `patch-clawpanel-headless.sh`
  - 给 headless Web 版补微信插件检测、扫码登录动作和 SSE 事件流
- `docker-setup.sh`
  - 一键部署入口
- `install-autostart.sh`
  - 单独安装 systemd 开机自启
- `openclaw-compose.service`
  - systemd 模板文件
- `OPENCLAW_CLAWPANEL_SETUP.md`
  - 详细维护说明和问题修复记录

## 持久化数据

运行后会在当前目录生成：

- `openclaw-data/`
- `openclaw-workspace/`

这两个目录存放实际数据，不建议提交到 GitHub。

## 常用命令

```bash
docker compose ps
docker compose logs -f openclaw-gateway
docker compose logs -f clawpanel
docker compose restart
sudo systemctl status openclaw-compose.service
```

## 注意事项

- 该方案面向 Linux
- `openclaw-gateway` 使用 `host` 网络模式
- `clawpanel` 复用 `openclaw-gateway` 的网络命名空间
- 不会自动做“内网穿透”，但服务默认对局域网可见
- 如果要长期公网暴露，建议后续自行增加防火墙限制和来源白名单
