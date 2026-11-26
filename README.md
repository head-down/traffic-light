# 红绿灯 (Traffic Light)

[![GitHub stars](https://img.shields.io/github/stars/head-down/traffic-light?style=flat-square&color=gold)](https://github.com/head-down/traffic-light/stargazers)
[![GitHub license](https://img.shields.io/github/license/head-down/traffic-light?style=flat-square&color=blue)](https://github.com/head-down/traffic-light/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows)](https://github.com/head-down/traffic-light)
[![Python](https://img.shields.io/badge/python-3.8%2B-blue?style=flat-square&logo=python)](https://www.python.org/)
[![Status](https://img.shields.io/badge/status-working-brightgreen?style=flat-square)](https://github.com/head-down/traffic-light)

PyQt5 透明置顶悬浮窗，通过**文件系统轮询**聚合展示 CodeBuddy / CLI agent 的运行状态。

**一个终端窗口一盏灯**：灯贴在该窗口下方，只反映这个窗口里的会话；同项目开多个终端互不干扰，关掉一个不影响另一个。

```
┌──────────────────┐
│       mine       │   主标签：优先级最高会话的项目名
│  ●      ●      ● │   红灯：失败（双闪）
│  🔴     🟡     🟢 │   黄灯：运行中（呼吸）
│   SignalLight ·2 │   角标 ·N：本窗不同会话数（N=1 不显示）
│     THINKING     │   蓝绿霓虹跑马灯：思考中
└──────────────────┘   红黄交替警灯：等待用户确认
                       三灯暗色呼吸：空闲
```

窗口尺寸 240 x 165 px。灯不抢焦点、不点亮任务栏图标；终端最小化时灯隐藏，还原时灯回来。

## 支持矩阵

| 终端 | 支持 | 行为 |
|------|------|------|
| Windows Terminal（ConPTY） | ✅ | 一窗一灯，标签页合并为 `·N` |
| 经典控制台 conhost | ✅ | 一窗一灯 |
| Git Bash / mintty | ❌ | 解析不到窗口 → 机器级**降级灯**，标 `?` |
| VSCode 集成终端 | ❌ | 解析不到窗口 → 机器级**降级灯**，标 `?` |

> 不支持 ≠ 没有灯。任何解析不出窗口的会话都落到一台机器一个的降级灯上，标签为 `<项目> ?`；会话恢复可解析后，降级灯自动消失。降级灯自由置顶、不抢焦点。
>
> 同一个窗口里的多个标签页共享窗口句柄，物理上只有一块屏，因此合并成一盏灯并显示 `·N`（N = 不同会话数）。Windows Terminal 把标签页拖成新窗口后，灯在下一条提示时跟到新窗口。

## 下载

| 方式 | 适合 | 要求 |
|------|------|------|
| **发布版 EXE**（推荐） | 不想装 Python 的用户 | 无，解压即用 |
| 源码运行 | 开发者、想自己修改的用户 | Python 3.8+ |

### 发布版（EXE）

从 [GitHub Releases](https://github.com/head-down/traffic-light/releases) 下载 `SignalLight-v1.0.0.zip`，解压后运行安装脚本：

```bat
:: 全局安装（推荐）—— 一次安装，所有项目生效
install.bat --global

:: 或项目级安装 —— 只对某个项目生效
install.bat D:\DevelopTools\my-project
```

发布包已包含 `resolve.ps1`、`probe.ps1`、`hooks/` 与 hook 模板，不需要安装 Python，也不需要额外下载脚本。

### 源码版

```bash
git clone https://github.com/head-down/traffic-light.git
cd traffic-light
pip install -r requirements.txt

# 全局安装（推荐）或项目级安装
bash install.sh --global
# bash install.sh /d/DevelopTools/my-project
```

安装 = 把 hooks 合并进 settings + 跑一次 GC。配置完成后打开 CodeBuddy 终端，每个终端窗口自动出现自己的灯。

## 升级（破坏式）

本次升级不保留项目级键，也没有新旧并存：

- 旧计划任务 `traffic-light-<项目>` 会被删除；新格式 `traffic-light-w<hwnd>` 是否存活只看锚文件。
- 旧状态文件 `.state`（后缀非纯数字）、`.pid`、`.cbpid` 一律清理。
- 旧版两个 hook 入口已删除，重新安装时对应 hook 会被整组替换为无窗口启动器（`traffic_light.exe --hook`，源码安装为 `pythonw hooks/run-hidden.pyw`）。
- `.win` 锚超过阈值未刷新视为孤儿灯，一并删除。

GC 在安装脚本与每次 SessionStart 各跑一次，幂等，旧任务 / 状态文件 / 孤儿锚**自动清理**，无需手工干预。重复安装/升级只会更新 hooks，不会出现第二盏灯。

## 快速开始

EXE 与源码两种方式都只需配一次 hooks，之后每次打开 CodeBuddy 终端，灯自动出现在该终端窗口下方。

### 自动启动机制

CodeBuddy 的六个事件统一走 `hooks/traffic-light.sh <event>`，由 GUI 子系统宿主
（`traffic_light.exe --hook` 或 `pythonw hooks/run-hidden.pyw`）拉起，里面的 bash 用
`CREATE_NO_WINDOW` 启动，所以**每次事件不会弹控制台黑框**。窗口来源也只用桌面 API：
优先当前前台终端窗口，其次桌面上唯一的一个；已有绑定且窗口仍然有效时直接复用——
不走 `AttachConsole`，因为对 ConPTY 控制台 attach 会让 Windows 临时新建一个终端窗口。

```
SessionStart      → 解析会话进程/窗口 → 写绑定 → 抢窗/拉灯 → GC
UserPromptSubmit  → thinking（顺带 TTL 检查与自愈）
PostToolUse       → running / failure（只写状态，零额外进程）
Notification      → waiting（仅 permission_prompt）
Stop              → success
SessionEnd        → ended（不删文件、不杀灯）
```

- **身份层**键 = CodeBuddy 进程 PID，值 = `<pid>.state`；PID 复用靠进程创建时间识别。
- **绑定层**键 = `session_id`，值 = `<session_id>.bind`，记录 pid / 窗口句柄 / 项目标签。
- **显示层**键 = 窗口句柄 hwnd，值 = `w<hwnd>.win` 锚 + `traffic-light-w<hwnd>` 计划任务 + 一个 drawer 进程。一个 hwnd 恒等于一盏灯。

项目名只是标签（取主工作区根目录名，worktree 回退到主仓库名），不参与做键。

### `/clear` 与最小化

- `/clear` 时灯**不闪、不重建、不换位**，只是回到空闲：SessionEnd 把状态置 `ended`，新会话立即写 `idle`，旧一轮迟到的 `success` 会被忽略。
- 终端最小化时灯隐藏，还原时灯显示；灯不抢焦点，也不点亮任务栏图标。
- 强杀终端（任务管理器结束进程/直接关窗口）后，灯在一个 tick 内自检退出并注销自己的计划任务，不留孤儿灯。

## Hook 配置

仓库提供 `.codebuddy-hooks.json` 模板，安装脚本会自动合并到目标配置（智能追加，不覆盖已有 hooks，重复执行幂等）。

### 方式 1：一键安装（推荐）

```bash
# 全局安装 —— 所有项目生效
install.bat --global            # Windows
bash install.sh --global        # Git Bash

# 项目级安装 —— 只对某个项目生效
install.bat <项目路径>
bash install.sh <项目路径>
```

安装脚本会自动替换路径、清理旧格式资产，不需要手动编辑 JSON。

### 方式 2：手动配置

把模板复制到对应位置，然后将 `TRAFFIC_LIGHT_DIR` 替换为 SignalLight 解压目录：

```bash
# 全局（所有项目）：~/.codebuddy/settings.json
# 项目级：<项目根>/.codebuddy/settings.local.json
cp traffic-light/.codebuddy-hooks.json ~/.codebuddy/settings.json
```

> 全局安装的 hooks 会与项目级 `settings.local.json` **合并执行**（非覆盖）。安装脚本按完整命令去重，不会产生双重执行。

六种状态与 CodeBuddy 事件联动：

| Hook 事件 | 灯状态 | 动画 | 说明 |
|-----------|--------|------|------|
| SessionStart | idle | 三灯暗色呼吸 | 解析归窗、拉起该窗的灯 |
| UserPromptSubmit | thinking | 红黄绿霓虹跑马灯 | 模型思考中 |
| PostToolUse | running | 黄灯呼吸 | 工具执行中，失败亮红灯 |
| Notification | waiting | 红黄交替警灯（仅权限请求） | 等待用户确认 |
| Stop | success | 绿灯脉冲 | 本轮完成 |
| SessionEnd | ended | 按 idle 渲染 | 不删文件、不杀灯 |

**聚合优先级：** waiting > failure > thinking > running > success > idle

**TTL 机制：** thinking 600s / running 90s / waiting 600s / success 8s / failure 30s，超时自动回 idle。

## 原理

- PyQt5 绘制无边框透明窗口，`SetWindowPos(HWND_TOPMOST)` + 循环抬升保持置顶，`WS_EX_NOACTIVATE` 不抢焦点
- QPainter 抗锯齿圆形 + QRadialGradient 三层霓虹发光，玻璃拟态面板
- PowerShell 解析器（`resolve.ps1`）是 hwnd 的唯一来源：短命进程内 `FreeConsole → AttachConsole` 取窗口，失败则写 `degraded=1` 进降级灯
- 所有文件写入都是"同目录临时文件 + 重命名"原子替换，不需要文件锁
- drawer 每 tick 刷新锚文件心跳，按 nonce 识别"被判死的旧 drawer 醒来"，避免双灯
- 窗口尺寸/位置取 `GetWindowPlacement` 的还原矩形（最小化窗口的 `GetWindowRect` 只有 159×27 桩尺寸，会误判）
- 所有 ps1 调用统一 `-NoProfile -ExecutionPolicy Bypass`，避免 Restricted 执行策略下静默失效

## 调试

探针（不写状态、不拉灯）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File probe.ps1
```

在两个终端各跑一次，`VERDICT` 里的 hwnd 应不同；相同则说明命中了同窗聚合（同一窗口的多个标签页）。

手动查看状态（只读）：

```bash
ls .traffic-light-states/           # <pid>.state / <session_id>.bind / w<hwnd>.win
cat .traffic-light-states/12345.state   # 三行：state / cwd / creation_ft
```

只跑一次 GC（幂等，不解析、不拉灯）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File resolve.ps1 -GcOnly
```

## 依赖

**源码版安装：**
```bash
pip install -r requirements.txt
```

**EXE 发布版**已包含所有依赖，无需额外安装。运行时仅需 `PyQt5>=5.15`。

## 配置

灯由 hooks 自动管理，没有需要手工指定的项目参数。窗口键来自解析器，状态目录默认是 `<SignalLight 目录>/.traffic-light-states`。

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

仅限 Windows（依赖 `SetWindowPos`、`ctypes.windll` 等 Windows 专属 API）。支持矩阵见上。

## 许可证

MIT License - 灯是自己的，Bug 是 AI 的。
