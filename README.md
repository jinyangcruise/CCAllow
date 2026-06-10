# CCAAllow

通过 Windows UI Automation 自动点击 Claude Desktop 中的 "Allow" 按钮。

无需 CDP / 调试端口 / 注入脚本，适用于所有版本（包括 Microsoft Store 版）。

## 原理

- 使用 PowerShell UIAutomation 库监控 Claude Desktop 窗口
- 发现 "Allow" / "Allow for this time" 按钮时自动点击
- 完全无侵入，不修改 Claude Desktop 任何文件或进程

## 使用

```powershell
npm install
npm start
```

打开开关 **Auto Allow** 即可。

## License

MIT
