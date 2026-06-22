# 红绿灯 (Traffic Light)

[![GitHub stars](https://img.shields.io/github/stars/head-down/traffic-light?style=flat-square&color=gold)](https://github.com/head-down/traffic-light/stargazers)
[![GitHub license](https://img.shields.io/github/license/head-down/traffic-light?style=flat-square&color=blue)](https://github.com/head-down/traffic-light/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows)](https://github.com/head-down/traffic-light)
[![Python](https://img.shields.io/badge/python-3.8%2B-blue?style=flat-square&logo=python)](https://www.python.org/)
[![Status](https://img.shields.io/badge/status-working-brightgreen?style=flat-square)](https://github.com/head-down/traffic-light)

PyQt5 透明置顶悬浮窗，通过 HTTP 接口聚合展示多个 CLI / Agent 的运行状态。

守护进程模式，自动聚合多会话：红灯 > 黄灯 > 绿灯 > 空闲。

```
┌──────────────┐
│  ●   ●   ●  │      红灯：失败（闪烁）
│ 🔴  🟡  🟢  │      黄灯：运行中（呼吸）
│ SignalLight  │      绿灯：成功（常亮）
└──────────────┘
```

## 星标趋势

[![Star History Chart](https://api.star-history.com/svg?repos=head-down/traffic-light&type=Date)](https://star-history.com/#head-down/traffic-light&Date)

## 原理

- PyQt5 绘制无边框透明窗口，通过 `SetWindowPos(HWND_TOPMOST)` + 2 秒循环抬升保持置顶
- QPainter 抗锯齿圆形 + QRadialGradient 径向渐变模拟外发光效果
- 四态状态机（idle → running → success/failure → idle），黄灯呼吸动画、红灯闪烁
- stdlib `http.server` 运行于 QThread，HTTP API 零额外依赖，支持多实例端口自动递增

## CodeBuddy 集成

守护进程自动聚合多个 agent 状态，无需手动绑定。

```bash
# 1. 启动守护进程（只需一次）
python traffic_light.py

# 2. 复制 hook 配置到 CodeBuddy 项目
cp .codebuddy-hooks.json /path/to/your-project/.codebuddy/settings.local.json

# 3. 调整路径：编辑 settings.local.json，把 traffic-light 路径改为实际路径
#    sed -i 's|$CODEBUDDY_PROJECT_DIR/traffic-light|/d/DevelopTools/mine/traffic-light|g' \
#      /path/to/your-project/.codebuddy/settings.local.json
```

之后打开任意 CodeBuddy 终端，agent 自动更新红绿灯：

| Hook 事件 | 灯状态 | 说明 |
|-----------|--------|------|
| SessionStart | idle | agent 就绪 |
| PostToolUse | running | 黄灯呼吸，agent 工作中 |
| Stop | success | 绿灯，本轮完成 |
| SessionEnd | end | 移除会话，聚合更新 |

多 agent 并行时按优先级聚合：红灯 > 黄灯 > 绿灯 > 空闲

## 运行

```bash
cd traffic-light

# 守护进程模式（推荐）
python traffic_light.py

# 或通过 bind.sh 启动
source bind.sh
```

更新状态（带 session_id 多会话聚合）：

```bash
export SID="my-agent-$$"
curl -X POST http://127.0.0.1:9527/state \
  -d "{\"state\":\"running\",\"session_id\":\"$SID\"}"
curl -X POST http://127.0.0.1:9527/state \
  -d "{\"state\":\"success\",\"session_id\":\"$SID\"}"
```

## HTTP API

| 方法 | 路径 | 说明 |
|------|------|------|
| `POST` | `/state` | 更新会话状态 `{"state":"running","session_id":"agent-1"}` |
| `GET` | `/state` | 查询聚合状态 + 活跃会话数 |
| `POST` | `/session/end` | 结束会话 `{"session_id":"agent-1"}` |
| `GET` | `/health` | 健康检查 |

## 依赖

```bash
pip install PyQt5
```

## 配置

通过命令行参数控制：

| 配置项 | 说明 |
|--------|------|
| `--name` | 实例名称，显示在灯下方（默认 `agent`） |
| `--port` | HTTP 起始端口，`9527` 起自动递增（默认 `9527`） |

## 平台

仅限 Windows（依赖 `SetWindowPos`、`ctypes.windll` 等 Windows 专属 API）。

## 许可证

MIT License - 灯是自己的，Bug 是 AI 的。
