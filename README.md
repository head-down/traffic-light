# 红绿灯 (Traffic Light)

[![GitHub stars](https://img.shields.io/github/stars/head-down/traffic-light?style=flat-square&color=gold)](https://github.com/head-down/traffic-light/stargazers)
[![GitHub license](https://img.shields.io/github/license/head-down/traffic-light?style=flat-square&color=blue)](https://github.com/head-down/traffic-light/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows)](https://github.com/head-down/traffic-light)
[![Python](https://img.shields.io/badge/python-3.8%2B-blue?style=flat-square&logo=python)](https://www.python.org/)
[![Status](https://img.shields.io/badge/status-working-brightgreen?style=flat-square)](https://github.com/head-down/traffic-light)

PyQt5 透明置顶悬浮窗，通过**文件系统轮询**聚合展示 CodeBuddy / CLI agent 的运行状态。

守护进程模式，单灯聚合多会话，6 种状态霓虹发光动画。

```
┌──────────────┐
│  ●   ●   ●  │      红灯：失败（双闪）
│ 🔴  🟡  🟢  │      黄灯：运行中（呼吸）
│ SignalLight  │      绿灯：成功（脉冲）
│  THINKING    │      蓝绿霓虹跑马灯：思考中（红→黄→绿追逐）
│              │      红黄交替警灯：等待用户确认
│              │      三灯暗色呼吸：空闲
└──────────────┘
```

## 星标趋势

[![Star History Chart](https://api.star-history.com/svg?repos=head-down/traffic-light&type=Date)](https://star-history.com/#head-down/traffic-light&Date)

## 原理

- PyQt5 绘制无边框透明窗口，通过 `SetWindowPos(HWND_TOPMOST)` + 2 秒循环抬升保持置顶
- QPainter 抗锯齿圆形 + QRadialGradient 三层霓虹发光（内层强光 / 中层光晕 / 外层扩散）
- 玻璃拟态（Glassmorphism）面板：半透明暗蓝背景 + 多层霓虹边框发光
- 6 态状态机（idle / thinking / running / waiting / success / failure），QPropertyAnimation 驱动动画
- **文件系统轮询**：CodeBuddy hook 用 bash 内置 `echo >` 写 `.traffic-light-states/current.state`，守护进程 QTimer 300ms 轮询，hook 延迟 ~115ms
- 可选 HTTP server（`--port N`）兼容旧 hook 脚本

## CodeBuddy 集成

守护进程自动聚合状态，所有 hook 共用 `current.state`（单文件方案）。

```bash
# 1. 启动守护进程（只需一次）
python traffic_light.py

# 2. 复制 hook 配置到 CodeBuddy 项目
#    配置已内置在 .codebuddy/settings.local.json
```

之后打开任意 CodeBuddy 终端，agent 自动更新红绿灯：

| Hook 事件 | 灯状态 | 动画 | 说明 |
|-----------|--------|------|------|
| SessionStart | idle | 三灯暗色呼吸 | agent 就绪 |
| UserPromptSubmit | thinking | 红黄绿霓虹跑马灯 | 模型思考中 |
| PostToolUse | running | 黄灯呼吸 | 工具执行中 |
| Notification | waiting | 红黄交替闪烁 | 等待用户确认 |
| Stop | success | 绿灯脉冲（8s 后回 idle） | 本轮完成 |
| SessionEnd | end | 清除状态文件 | 会话结束 |

**聚合优先级：** waiting > failure > thinking > running > success > idle

**TTL 机制：** thinking 180s / running 90s / waiting 600s / success 8s / failure 30s，超时自动回 idle。

> **已知限制：** CodeBuddy hook 环境不传递 `CODEBUDDY_SESSION_ID`（`$$` 每次不同、`$PPID=1`），无法区分同一项目的多个终端会话，多个终端会"串台"。单终端使用无影响。

## 运行

```bash
cd traffic-light

# 守护进程模式（默认文件轮询，推荐）
python traffic_light.py

# 或通过 bind.sh 启动
source bind.sh

# 启用 HTTP server（兼容旧 hook 脚本）
python traffic_light.py --port 9527
```

手动更新状态（文件系统方案）：

```bash
# 写状态文件
echo "thinking" > .traffic-light-states/current.state
echo "running" > .traffic-light-states/current.state
echo "success" > .traffic-light-states/current.state

# 清除（回 idle）
rm .traffic-light-states/current.state
```

HTTP API（兼容模式）：

```bash
curl -X POST http://127.0.0.1:9527/state \
  -d "{\"state\":\"running\",\"session_id\":\"agent-1\"}"
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
| `--port` | HTTP 起始端口，`9527` 起自动递增（默认 `0` 即禁用） |

## 参考项目

视觉与交互设计参考以下开源项目：

| 项目 | 作者 | 亮点 |
|------|------|------|
| [Chi-Frontend-Lab](https://github.com/ChiFrontEnd/Chi-Frontend-Lab) | ChiFrontEnd | Glassmorphism 玻璃拟态交通灯，色彩方案与霓虹发光参考 |
| [moss0000/claude-light](https://github.com/moss0000/claude-light) | moss0000 | Claude Code 状态灯，多态动画设计参考 |
| [weilizhe8-del/claude-code-traffic-light](https://github.com/weilizhe8-del/claude-code-traffic-light) | weilizhe8-del | 文件系统轮询方案验证（社区最主流方案） |
| [TaylorSimery/claude-traffic-light](https://github.com/TaylorSimery/claude-traffic-light) | TaylorSimery | 多状态文件轮询 + 优先级聚合设计 |
| [yhz61010/trafficlight4ai](https://github.com/yhz61010/trafficlight4ai) | yhz61010 | C++/Qt6 + named pipe IPC 方案（性能最优，<1ms） |
| [codecube0919/AI_light](https://github.com/codecube0919/AI_light) | codecube0919 | HTTP server 方案（本项目旧方案参考） |
| [setec.rs/claude-cron](https://github.com/setec-rs/claude-cron) | setec.rs | Hook 触发机制与生命周期设计 |

## 平台

仅限 Windows（依赖 `SetWindowPos`、`ctypes.windll` 等 Windows 专属 API）。

## 许可证

MIT License - 灯是自己的，Bug 是 AI 的。
