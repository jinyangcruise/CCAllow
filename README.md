# CCAllow

通过 CDP (Chrome DevTools Protocol) 连接到 Claude Desktop，在渲染进程注入脚本，添加"Auto Allow"勾选框并自动点击 Allow 按钮。

## 功能

- **自动检测** Claude Desktop 安装位置（`%LOCALAPPDATA%`、`%ProgramFiles%\WindowsApps` 等）
- **一键启动** Claude Desktop，自动附加 `--remote-debugging-port` 参数
- **脚本注入** — 在 Claude Desktop 右下角添加浮动 "Auto Allow" 复选框
- **自动点击** — 勾选后自动监视并点击 "Allow" / "Allow for..." 按钮
- **托盘运行** — 关闭窗口自动最小化到系统托盘

## 使用

```powershell
# 安装依赖
npm install

# 启动
npm start
```

启动后界面分三步：
1. 自动检测 Claude 位置 / 手动浏览选择
2. 点击"启动"以调试模式拉起 Claude Desktop
3. 点击"Connect & Inject"注入脚本

之后在 Claude Desktop 窗口右下角勾选 **Auto Allow** 即可。

## License

MIT
