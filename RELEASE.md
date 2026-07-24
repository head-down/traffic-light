# SignalLight v1.0.0 发布说明

## 这是什么

SignalLight（红绿灯）是一个 Windows 桌面悬浮窗，通过三色霓虹灯实时显示 CodeBuddy / CLI agent 的运行状态。

**一句话：CodeBuddy 在工作时自动亮灯，你不用盯着终端看。**

亮灯效果：
- 红黄绿跑马灯 = 模型在思考
- 黄灯呼吸 = 工具在运行
- 红灯双闪 = 执行失败
- 红黄警灯 = 等待你确认权限
- 绿灯脉冲 = 本轮完成

## 系统要求

| 项目 | 要求 |
|------|------|
| 操作系统 | Windows 10 / 11 |
| CodeBuddy | 任意版本 |
| Git Bash | 需要（CodeBuddy 自带） |
| Python | **不需要**（EXE 版已包含所有依赖） |

## 安装（三步完成）

### 第一步：下载

从 [GitHub Releases](https://github.com/head-down/traffic-light/releases) 下载 `SignalLight-v1.0.0.zip`，解压到任意目录（建议 `D:\tools\SignalLight\`）。

### 第二步：一键安装

打开解压后的 `SignalLight` 文件夹，**双击 `install.bat`** 或终端运行：

```bash
# 全局安装（推荐）：一次配置，所有 CodeBuddy 项目自动亮灯
bash install.sh --global

# 或项目级安装：仅指定项目亮灯
bash install.sh <你的CodeBuddy项目路径>
```

脚本会自动：
1. **全局模式**：合并 hooks 到 `~/.codebuddy/settings.json`
2. **项目级模式**：在项目下创建 `.codebuddy/settings.local.json`
3. 智能合并：保留用户已有的环境变量、其他 hooks 配置，只追加 SignalLight 相关项
4. 命令级去重：重复安装不会产生双重执行的 hooks

### 第三步：打开 CodeBuddy

打开任意 CodeBuddy 终端（全局安装时任意项目均可），灯自动出现在屏幕右下角。

## 工作原理

```
你发消息 → UserPromptSubmit → 跑马灯亮起（模型思考中）
模型调用工具 → PostToolUse → 黄灯呼吸
等待你确认 → Notification → 红黄警灯
本轮完成 → Stop → 绿灯脉冲 → 8 秒后灭灯
关闭 CodeBuddy → SessionEnd → 自动清理退出
```

全程无需手动操作，CodeBuddy 启动灯就来，退出灯就走。

## 常见问题

### Q: 灯不亮怎么办？

1. 确认 `.codebuddy/settings.local.json` 已正确配置（用 install.bat 重装）
2. 确认 bash 可用（打开 Git Bash 测试 `bash --version`）
3. 重启 CodeBuddy 终端

### Q: 灯位置不对？

灯会自动跟随终端窗口。如果灯跑到别处了，关闭 CodeBuddy 终端重新打开即可。

### Q: 能同时监控多个项目吗？

可以。**推荐使用全局安装**（`bash install.sh --global`），所有 CodeBuddy 项目自动亮灯，不同项目的灯独立运行互不影响。也可以对每个项目单独运行 `bash install.sh <项目路径>`。

### Q: 需要一直开着终端吗？

需要。灯通过检测 CodeBuddy 进程存活来判断，终端关了灯也会退出。

### Q: 怎么卸载？

- **全局安装**：编辑 `~/.codebuddy/settings.json`，删除 hooks 中 SignalLight 相关配置
- **项目级安装**：删除项目下的 `.codebuddy/settings.local.json`

SignalLight 目录可直接删除，无残留。

## 从源码运行

如果你更喜欢从源码运行：

```bash
git clone https://github.com/head-down/traffic-light.git
cd traffic-light
pip install -r requirements.txt

# 配置 hooks
bash install.sh --global        # 全局安装（推荐）
# 或 bash install.sh <项目路径>  # 项目级安装

# 手动启动（不用 hooks 自动启动时）
bash bind.sh --project <项目名>
```

## 技术细节

- **通信方式**：文件系统轮询（hook 写文件 → 守护进程 300ms 轮询），延迟约 115ms
- **跨项目隔离**：按项目目录名命名状态文件，不同项目完全解耦
- **单实例保护**：PID 文件锁 + PowerShell 进程清理，不会多开
- **异常退出兜底**：守护进程每 5 秒检测 CodeBuddy 是否存活，Ctrl+C 关闭后约 10 秒自动退出
- **TTL 机制**：各状态有过期时间（thinking 600s / running 90s / success 8s），防止残留

## 反馈

- GitHub Issues: https://github.com/head-down/traffic-light/issues
- 觉得好用请点个 Star ⭐
