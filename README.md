# CC Allow

通过 Windows UI Automation 自动点击 Claude Desktop 中的 "Allow" / "Allow once" 按钮。

[English](README.en.md)

## 功能

- **Auto Allow** — 检测到 Allow 按钮时自动点击，无需手动操作
- **最小化轮询** — Claude 最小化后定期唤醒检查，发现 Allow 后自动点击（可开关）
- **InvokePattern 点击** — 优先使用 UIA InvokePattern 点击，不抢焦点、不打断打字
- **窗口还原** — 点击 Allow 后自动恢复窗口位置（可设置 Allow 后自动最小化）
- **多语言** — 中文 / English 界面切换
- **深色/浅色主题** — ☀️/🌙 一键切换
- **开机自启** — 系统启动时自动运行
- **静默启动** — 启动不显示窗口，仅在托盘运行
- **托盘运行** — 关闭窗口自动最小化到系统托盘
- **自动更新** — 启动时自动检查新版本，一键下载安装

## 原理

使用 PowerShell UIAutomation 库监控 Claude Desktop 窗口，检测到 "Allow once" / "Allow for this time" 按钮时自动触发点击。优先使用 UIA InvokePattern（无需激活窗口），失败则降级为激活窗口 + SendKeys Ctrl+Enter。

所有操作在本地完成，不修改 Claude Desktop 任何文件或进程。

## 下载

从 [Releases](https://github.com/jinyangcruise/CCAllow/releases) 页面下载最新安装包。

## 开发

```powershell
npm install
npm start
```

## License

MIT
