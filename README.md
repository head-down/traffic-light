# Traffic Light

Windows 桌面红绿灯状态指示器 — PyQt5 透明置顶悬浮窗，通过 HTTP 接口实时展示 CLI/Agent 运行状态。

```
┌──────────────┐
│  ●   ●   ●  │
│ 🔴  🟡  🟢  │
│   agent      │
└──────────────┘
```

## 安装

```bash
pip install PyQt5
git clone https://github.com/head-down/traffic-light.git
cd traffic-light
```

## 使用

### 启动红绿灯

```bash
python traffic-light.py --name build
# [traffic-light] build 已启动, HTTP → http://127.0.0.1:9527
```

### 更新状态

```bash
# 运行中
curl -X POST http://127.0.0.1:9527/state -d '{"state":"running"}'

# 成功
curl -X POST http://127.0.0.1:9527/state -d '{"state":"success"}'

# 失败
curl -X POST http://127.0.0.1:9527/state -d '{"state":"failure"}'

# 重置
curl -X POST http://127.0.0.1:9527/state -d '{"state":"idle"}'
```

### 查询状态

```bash
curl http://127.0.0.1:9527/state
# {"state":"idle","name":"build"}
```

### 多终端支持

每个终端启动独立红绿灯实例，端口自动递增：

```bash
# 终端1
python traffic-light.py --name build
# → http://127.0.0.1:9527

# 终端2
python traffic-light.py --name test
# → http://127.0.0.1:9528

# 终端3
python traffic-light.py --name deploy
# → http://127.0.0.1:9529
```

## API

| 方法 | 路径 | 描述 |
|------|------|------|
| `POST` | `/state` | 更新状态 `{"state":"running\|success\|failure\|idle"}` |
| `GET` | `/state` | 查询当前状态 |
| `GET` | `/health` | 健康检查 |

## 视觉效果

- **黄灯** — 运行中，呼吸动画（大小 14→22px）
- **绿灯** — 成功，5 秒后自动回 idle
- **红灯** — 失败，闪烁动画，5 秒后自动回 idle
- **所有不亮** — idle（空闲）

## 命令行参数

```
--name NAME      实例名称 (默认: agent)
--port PORT      HTTP 端口 (默认: 0=自动检测)
```

## 技术栈

- PyQt5 — 透明窗口 + 抗锯齿绘制 + 动画
- stdlib http.server — HTTP API（零额外依赖）
- SetWindowPos(HWND_TOPMOST) — Windows 强制置顶

## 许可

MIT
