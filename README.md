# CCAAllow

通过 Windows UI Automation 自动点击 Claude Desktop 中的 "Allow" / "Allow once" 按钮。


## 原理

- 通过 PowerShell UIAutomation 库监控 Claude Desktop 窗口
- 检测到 "Allow once" / "Allow for this time" 按钮时自动触发点击
- 优先使用 UIA InvokePattern，失败则降级为 AppActivate + SendKeys 发送 Ctrl+Enter
- 点击后自动恢复之前的前台窗口，不干扰用户操作
- 完全无侵入，不修改 Claude Desktop 任何文件或进程

## 使用

```powershell
npm install
npm start
```

打开 **Auto Allow** 开关即可。

## 功能

- 系统托盘运行，关闭窗口自动最小化到托盘
- 点击日志可复制
- 窗口可拖拽调整大小

## License

MIT
