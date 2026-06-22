# 红绿灯 (Traffic Light)

[![GitHub stars](https://img.shields.io/github/stars/head-down/traffic-light?style=flat-square&color=gold)](https://github.com/head-down/traffic-light/stargazers)
[![GitHub license](https://img.shields.io/github/license/head-down/traffic-light?style=flat-square&color=blue)](https://github.com/head-down/traffic-light/blob/master/LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows)](https://github.com/head-down/traffic-light)
[![Python](https://img.shields.io/badge/python-3.8%2B-blue?style=flat-square&logo=python)](https://www.python.org/)
[![Status](https://img.shields.io/badge/status-working-brightgreen?style=flat-square)](https://github.com/head-down/traffic-light)

PyQt5 透明置顶悬浮窗，通过 HTTP 接口实时展示 CLI / Agent 运行状态。余光感知，无需切换窗口。

```
┌──────────────┐
│  ●   ●   ●  │      红灯：失败（闪烁）
│ 🔴  🟡  🟢  │      黄灯：运行中（呼吸）
│   agent      │      绿灯：成功（常亮）
└──────────────┘
```

## 星标趋势

[![Star History Chart](https://api.star-history.com/svg?repos=head-down/traffic-light&type=Date)](https://star-history.com/#head-down/traffic-light&Date)

## 原理

- PyQt5 绘制无边框透明窗口，通过 `SetWindowPos(HWND_TOPMOST)` + 2 秒循环抬升保持置顶
- QPainter 抗锯齿圆形 + QRadialGradient 径向渐变模拟外发光效果
- 四态状态机（idle → running → success/failure → idle），黄灯呼吸动画、红灯闪烁
- stdlib `http.server` 运行于 QThread，HTTP API 零额外依赖，支持多实例端口自动递增

## 运行

```bash
cd traffic-light
python traffic_light.py --name build
```

更新状态：

```bash
curl -X POST http://127.0.0.1:9527/state -d '{"state":"running"}'
curl -X POST http://127.0.0.1:9527/state -d '{"state":"success"}'
curl -X POST http://127.0.0.1:9527/state -d '{"state":"failure"}'
```

## 依赖

```bash
pip install PyQt5
```

## 配置

通过命令行参数控制：

| 配置项 | 说明 |
|--------|------|
| `--name` | 实例名称，显示在灯下方（默认 `agent`） |
| `--port` | HTTP 端口，`0` = 从 9527 开始自动检测 |

## 平台

仅限 Windows（依赖 `SetWindowPos`、`ctypes.windll` 等 Windows 专属 API）。

## 许可证

MIT License - 灯是自己的，Bug 是 AI 的。
