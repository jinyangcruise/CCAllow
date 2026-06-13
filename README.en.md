# CC Allow

Automatically click the "Allow once Ctrl+Enter" button in Claude Desktop via Windows UI Automation.

[中文](README.md)

## Features

- **Auto Allow** — Automatically clicks Allow buttons when detected
- **Custom button text** — Add, remove, or restore default exact-match button texts
- **List current buttons** — Scan button texts in the current Claude window for easier configuration
- **Poll when minimized** — Periodically checks for Allow when Claude is minimized (toggleable)
- **InvokePattern click** — Uses UIA InvokePattern by default, no focus stealing, no typing interruption
- **Window restore** — Restores window position after clicking Allow (optional auto-minimize)
- **Multi-language** — Chinese / English UI
- **Dark/Light theme** — ☀️/🌙 toggle
- **Auto start** — Launch on system startup
- **Silent start** — Start minimized to tray
- **System tray** — Close window to minimize to tray
- **Auto update** — Checks for new version on startup, one-click download & install

## How it works

Uses PowerShell UIAutomation to monitor the Claude Desktop window. When the default "Allow once Ctrl+Enter" button text is detected, it's clicked automatically. Priority is given to UIA InvokePattern (no window activation needed), falling back to focus activation + SendKeys Ctrl+Enter.

All operations are local. Does not modify any Claude Desktop files or processes.

## Download

Get the latest installer from the [Releases](https://github.com/jinyangcruise/CCAllow/releases) page.

## Development

```powershell
npm install
npm start
```

## License

MIT
