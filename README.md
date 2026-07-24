# 红绿灯 (Traffic Light)

[![GitHub stars](https://img.shields.io/github/stars/head-down/traffic-light?style=flat-square&color=gold)](https://github.com/head-down/traffic-light/stargazers)
[![GitHub license](https://img.shields.io/github/license/head-down/traffic-light?style=flat-square&color=blue)](https://github.com/head-down/traffic-light/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows)](https://github.com/head-down/traffic-light)
[![Python](https://img.shields.io/badge/python-3.8%2B-blue?style=flat-square&logo=python)](https://www.python.org/)
[![Status](https://img.shields.io/badge/status-working-brightgreen?style=flat-square)](https://github.com/head-down/traffic-light)

PyQt5 透明置顶悬浮窗，通过**文件系统轮询**聚合展示 CodeBuddy / CLI agent 的运行状态。

守护进程模式，单灯聚合多会话，6 种状态霓虹发光动画。

```
┌──────────────────┐
│       mine       │   项目目录名（顶部常驻）
│  ●      ●      ● │   红灯：失败（双闪）
│  🔴     🟡     🟢 │   黄灯：运行中（呼吸）
│   SignalLight    │   绿灯：成功（脉冲）
│     THINKING     │   蓝绿霓虹跑马灯：思考中
│                  │   红黄交替警灯：等待用户确认
└──────────────────┘   三灯暗色呼吸：空闲

窗口尺寸：240 x 165 px，项目路径置顶常驻，
状态标签置底，互不遮挡。
```

## 星标趋势

[![Star History Chart](https://api.star-history.com/svg?repos=head-down/traffic-light&type=Date)](https://star-history.com/#head-down/traffic-light&Date)

## 快速开始

```bash
# 1. 克隆仓库
git clone https://github.com/head-down/traffic-light.git
cd traffic-light

# 2. 安装依赖
pip install -r requirements.txt

# 3. 配置 CodeBuddy hooks（复制模板到项目）
cp .codebuddy-hooks.json YOUR_PROJECT_DIR/.codebuddy/settings.local.json

# 4. 打开 CodeBuddy → 自动启动红绿灯（SessionStart 触发 auto-bind.sh）
```

前三步只需做一次。之后每次打开 CodeBuddy 终端，灯自动出现在右下角，`/exit` 时自动关闭。

> **注意**：`settings.local.json` 中的 `TRAFFIC_LIGHT_DIR` 需替换为实际目录路径，或把 `hooks/` 目录复制到项目 `.codebuddy/hooks/` 下。

### 自动启动机制

CodeBuddy 启动/退出时通过 hooks 自动管理守护进程生命周期：

```
SessionStart → auto-bind.sh → bind.sh → 启动守护进程（记录 PID + cbpid）
SessionEnd   → auto-stop.sh → 清理状态文件 + 杀死守护进程
```

不需要手动启动 `bind.sh`，配置文件添加 hooks 后全程自动。守护进程自带 PID 存活检测，CodeBuddy 意外关闭（Ctrl+C）后 ~10 秒自动退出。

## 原理

- PyQt5 绘制无边框透明窗口，通过 `SetWindowPos(HWND_TOPMOST)` + 2 秒循环抬升保持置顶
- QPainter 抗锯齿圆形 + QRadialGradient 三层霓虹发光（内层强光 / 中层光晕 / 外层扩散）
- 玻璃拟态（Glassmorphism）面板：半透明暗蓝背景 + 多层霓虹边框发光
- 6 态状态机（idle / thinking / running / waiting / success / failure），QPropertyAnimation 驱动动画
- **文件系统轮询**：CodeBuddy hook 写 `<项目名>.state` 到 `.traffic-light-states/`，守护进程 300ms 轮询，hook 延迟 ~115ms
- **项目隔离**：`--project <name>` 绑定到指定项目，不同项目的灯完全解耦
- **PID 文件锁**：`bind.sh` 启动前自动清理旧实例，避免多守护进程叠加
- **CodeBuddy 存活检测**：守护进程每 5 秒检查 CodeBuddy PID 是否存活，退出后约 10 秒自动关闭（兜底 Ctrl+C / 终端关闭）

## Hook 配置

仓库提供 `.codebuddy-hooks.json` 模板文件，复制到目标项目的 `.codebuddy/settings.local.json` 即可。

### 自动配置（推荐）

将模板复制到你的项目：

```bash
# 方法 1：复制模板，修改 TRAFFIC_LIGHT_DIR
cp traffic-light/.codebuddy-hooks.json my-project/.codebuddy/settings.local.json
# 然后编辑 settings.local.json，将 TRAFFIC_LIGHT_DIR 替换为实际路径

# 方法 2：复制 hooks 脚本到项目，避免依赖外部路径
cp -r traffic-light/hooks/ my-project/.codebuddy/hooks/
# 修改 settings.local.json 中的路径为 .codebuddy/hooks/traffic-light.sh
```

配置完成后，六种状态自动与 CodeBuddy 事件联动：

| Hook 事件 | 灯状态 | 动画 | 说明 |
|-----------|--------|------|------|
| SessionStart | idle | 三灯暗色呼吸 → 启动守护进程 | agent 就绪 |
| UserPromptSubmit | thinking | 红黄绿霓虹跑马灯 | 模型思考中 |
| PostToolUse | running | 黄灯呼吸 | 工具执行中 |
| Notification | waiting | 红黄交替警灯（仅权限请求） | 等待用户确认 |
| Stop | success | 绿灯脉冲（8s 后回 idle） | 本轮完成 |
| SessionEnd | end | 清除状态 + 杀死守护进程 | 会话结束 |

> **注意**：Notification hook 通过 `"matcher": "permission_prompt"` 过滤，只对权限请求写 `waiting`。60 秒无输入提醒不会触发状态变化。PostToolUse 自动检测失败（`success: false` / `exitCode != 0`），工具失败时亮红灯。

**聚合优先级：** waiting > failure > thinking > running > success > idle

**TTL 机制：** thinking 600s / running 90s / waiting 600s / success 8s / failure 30s，超时自动回 idle。thinking 延长到 600s 以支持 reasoning 模型长思考。

### 单实例锁

同一项目只允许一个守护进程，通过 `bind.sh` 启动时自动清理旧实例（PID 文件 + PowerShell fallback）。进程退出时 PID 文件被清理。

```bash
$ bash bind.sh --project mine
[SignalLight] daemon started --project mine (PID=12345)
```

### CodeBuddy 退出检测

守护进程自带 CodeBuddy 存活检测：`bind.sh` 启动时记录 CodeBuddy 进程 PID 到 `.cbpid` 文件，守护进程每 5 秒检查该 PID 是否存活。CodeBuddy 退出（包括 Ctrl+C、关闭终端）后约 10 秒自动关闭。正常退出通过 SessionEnd hook 调用 `auto-stop.sh` 即时清理。

| 退出方式 | 清理路径 | 延迟 |
|----------|----------|------|
| `/exit` 正常退出 | SessionEnd → auto-stop.sh | 即时 |
| Ctrl+C / 关闭终端 | PID 存活检测 | ~10s |
| 进程强杀 | PID 存活检测 | ~10s |

**多窗口行为：** 同一项目的多个 CodeBuddy 窗口共用一个守护进程（一盏灯），状态文件以 last-write-wins 聚合；不同项目的守护进程完全独立，互不干扰。关闭某个窗口不会影响其他窗口的灯（只要有任意 CodeBuddy 实例存活）。

> **已知限制：** CodeBuddy hook 环境不传递 `CODEBUDDY_SESSION_ID`（`$$` 每次不同、`$PPID=1`），同一项目的多个终端窗口共用同一个 `<项目名>.state` 文件，以 **last-write-wins** 聚合——灯反映最近触发 hook 的窗口状态。不同项目完全独立，互不影响。

## 手动运行 / 调试

如果不用 hook 自动启动，也可以手动控制：

```bash
cd traffic-light

# 启动守护进程（自动管理生命周期、PID 锁、cbpid 检测）
bash bind.sh --project mine

# 停止守护进程
bash bind.sh stop --project mine

# 直接启动 Python（无 cbpid 检测，CodeBuddy 退出后需手动关闭）
python traffic_light.py --project mine
```

不指定 `--project` 时聚合所有项目状态（向后兼容）。

手动更新状态（调试用途）：

```bash
# 写状态文件（第一行状态，第二行项目路径）
printf "thinking\n/d/DevelopTools/mine\n" > .traffic-light-states/mine.state
printf "running\n/d/DevelopTools/mine\n" > .traffic-light-states/mine.state
printf "success\n/d/DevelopTools/mine\n" > .traffic-light-states/mine.state

# 清除（回 idle）
rm .traffic-light-states/mine.state
```

## 依赖

```bash
pip install -r requirements.txt
```

运行时仅需 `PyQt5>=5.15`，无其他依赖。

## 配置

通过命令行参数控制：

| 配置项 | 说明 |
|--------|------|
| `--project` | 绑定到指定项目名（对应 `<project>.state` 文件），不指定则聚合所有项目 |

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
