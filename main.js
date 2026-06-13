const { app, BrowserWindow, ipcMain, Tray, Menu, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const https = require('https');

const GH_REPO = 'jinyangcruise/CCAllow';
const assetsDir = path.join(__dirname, 'assets');
const iconPath = path.join(assetsDir, 'icon.png');
const trayIconPath = path.join(assetsDir, 'tray-icon.png');
const DEFAULT_BUTTON_TARGETS = ["Allow once Ctrl+Enter"];

let mainWindow;
let tray;
let monitorProcess = null;
let monitorEnabled = false;
let configPath;

function getConfig() {
    try {
        if (fs.existsSync(configPath)) return JSON.parse(fs.readFileSync(configPath, 'utf-8'));
    } catch {}
    return {};
}

function saveConfig(cfg) {
    try {
        const dir = path.dirname(configPath);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
        const cur = getConfig();
        Object.assign(cur, cfg);
        fs.writeFileSync(configPath, JSON.stringify(cur, null, 2));
    } catch {}
}

function applyAutoStart() {
    const cfg = getConfig();
    const enabled = cfg.autoStart !== false;
    app.setLoginItemSettings({ openAtLogin: enabled });
}

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 480, height: 600, resizable: true,
        icon: iconPath,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            contextIsolation: true, nodeIntegration: false,
        },
    });
    mainWindow.loadFile('index.html');
    mainWindow.setMenu(null);
    mainWindow.on('close', (e) => { if (!app.isQuitting) { e.preventDefault(); mainWindow.hide(); } });
}

function createTray() {
    tray = new Tray(trayIconPath);
    tray.setToolTip('CC Allow');
    rebuildTrayMenu();
    tray.on('click', () => { mainWindow.isVisible() ? mainWindow.focus() : (mainWindow.show(), mainWindow.focus()); });
}

function normalizeButtonTargets(targets) {
    const source = Array.isArray(targets) ? targets : DEFAULT_BUTTON_TARGETS;
    const seen = new Set();
    return source
        .map((t) => String(t || '').trim())
        .filter((t) => {
            if (!t || seen.has(t)) return false;
            seen.add(t);
            return true;
        });
}

function getButtonTargets() {
    const cfg = getConfig();
    if (Array.isArray(cfg.buttonTargets)) return normalizeButtonTargets(cfg.buttonTargets);
    return DEFAULT_BUTTON_TARGETS.slice();
}

const trayLabels = {
    zh: { show: '显示 CC Allow', start: '开始监控', stop: '停止监控', bringClaude: '找回Claude窗口', exit: '退出' },
    en: { show: 'Show CC Allow', start: 'Start Monitoring', stop: 'Stop Monitoring', bringClaude: 'Bring Claude to Front', exit: 'Exit' }
};

function rebuildTrayMenu() {
    if (!tray) return;
    const lang = (getConfig().language || 'zh') === 'zh' ? 'zh' : 'en';
    const L = trayLabels[lang];
    const tmpl = [
        { label: L.show, click: () => { mainWindow.show(); mainWindow.focus(); } },
        { type: 'separator' },
        monitorEnabled
            ? { label: L.stop, click: () => mainWindow.webContents.send('tray-toggle') }
            : { label: L.start, click: () => mainWindow.webContents.send('tray-toggle') },
        { label: L.bringClaude, click: () => { bringClaudeToCenter(); } },
        { type: 'separator' },
        { label: L.exit, click: () => { app.isQuitting = true; app.quit(); } },
    ];
    tray.setContextMenu(Menu.buildFromTemplate(tmpl));
}

function bringClaudeToCenter() {
    const ps = spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', `
$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'claude' -and $_.MainWindowHandle -ne 0 }
if (-not $p) { exit }
$h = $p[0].MainWindowHandle
Add-Type @"
using System; using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr ha, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
}
"@
$sw = [W]::GetSystemMetrics(0); $sh = [W]::GetSystemMetrics(1)
$x = [Math]::Max(0, [int](($sw - 1200) / 2))
$y = [Math]::Max(0, [int](($sh - 800) / 2))
[W]::ShowWindow($h, 9)
[W]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 1200, 800, 0x0040)
[W]::SetForegroundWindow($h)
`], { stdio: 'ignore' });
    ps.unref();
}

function listClaudeButtons() {
    return new Promise((resolve) => {
        const script = `
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
$p = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match 'claude' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { Write-Output '{"ok":false,"error":"claude_not_found","buttons":[]}'; exit }
try {
    $root = [System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElementIdentifiers]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::Button)
    $items = @()
    $buttons = $root.FindAll([System.Windows.Automation.TreeScope]::Subtree, $cond)
    for ($i = 0; $i -lt $buttons.Count; $i++) {
        $name = $buttons[$i].Current.Name.Trim()
        if ($name -and -not ($items -ccontains $name)) { $items += $name }
    }
    [pscustomobject]@{ ok = $true; buttons = $items } | ConvertTo-Json -Compress
} catch {
    [pscustomobject]@{ ok = $false; error = $_.Exception.Message; buttons = @() } | ConvertTo-Json -Compress
}
`;
        const ps = spawn('powershell', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', script], { stdio: ['ignore', 'pipe', 'pipe'] });
        let stdout = '';
        let stderr = '';
        ps.stdout.on('data', (d) => { stdout += d.toString(); });
        ps.stderr.on('data', (d) => { stderr += d.toString(); });
        ps.on('error', (err) => resolve({ ok: false, error: err.message, buttons: [] }));
        ps.on('exit', () => {
            try {
                const data = JSON.parse(stdout.trim());
                resolve({ ok: data.ok === true, error: data.error || '', buttons: Array.isArray(data.buttons) ? data.buttons : [] });
            } catch {
                resolve({ ok: false, error: stderr.trim() || 'parse_failed', buttons: [] });
            }
        });
    });
}

function startMonitor() {
    if (monitorProcess) return;
    const psPath = path.join(__dirname, 'monitor.ps1');
    if (!fs.existsSync(psPath)) { return; }

    const proc = spawn('powershell', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', psPath,
    ], { stdio: ['pipe', 'pipe', 'pipe'] });

    const pid = proc.pid;
    proc.stdout.on('data', (d) => {
        if (mainWindow) mainWindow.webContents.send('monitor-log', d.toString().trim());
    });
    proc.stderr.on('data', (d) => {
        if (mainWindow) mainWindow.webContents.send('monitor-log', '[err] ' + d.toString().trim());
    });
    proc.on('error', () => { if (monitorProcess && monitorProcess.pid === pid) { monitorProcess = null; monitorEnabled = false; rebuildTrayMenu(); } });
    proc.on('exit', () => { if (monitorProcess && monitorProcess.pid === pid) { monitorProcess = null; monitorEnabled = false; rebuildTrayMenu(); } });
    monitorProcess = proc;
    monitorEnabled = true;
    rebuildTrayMenu();
    // Send config
    const cfg = getConfig();
    sendMonitorCmd(cfg.minimizedPolling === true ? 'polling:on' : 'polling:off');
    const interval = cfg.minimizedInterval || 2500;
    sendMonitorCmd(`interval:${interval}`);
    sendMonitorCmd(cfg.minimizeAfterAllow === true ? 'minimize-after-allow:on' : 'minimize-after-allow:off');
    sendMonitorCmd(`targets:${JSON.stringify(getButtonTargets())}`);
}

function sendMonitorCmd(cmd) {
    if (monitorProcess && monitorProcess.stdin.writable) {
        try { monitorProcess.stdin.write(cmd + '\n'); } catch {}
    }
}

function stopMonitor() {
    if (!monitorProcess) return;
    const oldProc = monitorProcess;
    try {
        oldProc.stdin.write('exit\n');
        oldProc.stdin.end();
        setTimeout(() => { try { oldProc.kill(); } catch {} }, 500);
    } catch {}
    monitorProcess = null;
    monitorEnabled = false;
    rebuildTrayMenu();
}

ipcMain.handle('get-version', () => require('./package.json').version);

ipcMain.handle('get-theme', () => {
    const cfg = getConfig();
    return { theme: cfg.theme || 'light' };
});

ipcMain.handle('set-theme', (_e, theme) => {
    saveConfig({ theme });
    return { theme };
});

ipcMain.handle('toggle-monitor', () => {
    if (monitorEnabled) stopMonitor();
    else startMonitor();
    saveConfig({ autoAllow: monitorEnabled });
    return { enabled: monitorEnabled };
});

ipcMain.handle('get-status', () => ({ enabled: monitorEnabled }));

ipcMain.handle('get-button-targets', () => ({ targets: getButtonTargets() }));

ipcMain.handle('set-button-targets', (_e, targets) => {
    const normalized = normalizeButtonTargets(targets);
    saveConfig({ buttonTargets: normalized });
    sendMonitorCmd(`targets:${JSON.stringify(normalized)}`);
    return { targets: normalized };
});

ipcMain.handle('reset-button-targets', () => {
    const targets = DEFAULT_BUTTON_TARGETS.slice();
    saveConfig({ buttonTargets: targets });
    sendMonitorCmd(`targets:${JSON.stringify(targets)}`);
    return { targets };
});

ipcMain.handle('list-claude-buttons', () => listClaudeButtons());

ipcMain.handle('get-auto-start', () => {
    const cfg = getConfig();
    return { enabled: cfg.autoStart !== false };
});

ipcMain.handle('set-auto-start', (_e, enabled) => {
    saveConfig({ autoStart: enabled });
    app.setLoginItemSettings({ openAtLogin: enabled });
    return { enabled };
});

ipcMain.handle('get-silent-start', () => {
    const cfg = getConfig();
    return { enabled: cfg.silentStart === true };
});

ipcMain.handle('set-silent-start', (_e, enabled) => {
    saveConfig({ silentStart: enabled });
    return { enabled };
});

ipcMain.handle('get-minimized-polling', () => {
    const cfg = getConfig();
    return { enabled: cfg.minimizedPolling === true };
});

ipcMain.handle('set-minimized-polling', (_e, enabled) => {
    saveConfig({ minimizedPolling: enabled });
    if (monitorEnabled) { stopMonitor(); startMonitor(); }
    return { enabled };
});

ipcMain.handle('get-minimize-after-allow', () => {
    const cfg = getConfig();
    return { enabled: cfg.minimizeAfterAllow === true };
});

ipcMain.handle('set-minimize-after-allow', (_e, enabled) => {
    saveConfig({ minimizeAfterAllow: enabled });
    sendMonitorCmd(enabled ? 'minimize-after-allow:on' : 'minimize-after-allow:off');
    return { enabled };
});

ipcMain.handle('get-language', () => {
    const cfg = getConfig();
    return { lang: cfg.language || 'zh' };
});

ipcMain.handle('set-language', (_e, lang) => {
    saveConfig({ language: lang });
    tray && rebuildTrayMenu();
    return { lang };
});

ipcMain.handle('get-minimized-interval', () => {
    const cfg = getConfig();
    return { interval: cfg.minimizedInterval || 2500 };
});

ipcMain.handle('set-minimized-interval', (_e, interval) => {
    saveConfig({ minimizedInterval: interval });
    sendMonitorCmd(`interval:${interval}`);
    return { interval };
});

ipcMain.handle('open-url', (_e, url) => { shell.openExternal(url); return true; });

// ── update ──
const currentVersion = require('./package.json').version;
let downloadPath = null;

function parseVersion(v) {
    const parts = v.replace(/^v/, '').split('.').map(Number);
    return parts[0] * 10000 + parts[1] * 100 + parts[2];
}

function getLatestRelease() {
    return new Promise((resolve, reject) => {
        const options = {
            hostname: 'api.github.com',
            path: `/repos/${GH_REPO}/releases/latest`,
            headers: { 'User-Agent': 'CCAllow' },
            rejectUnauthorized: false,
        };
        https.get(options, (res) => {
            let data = '';
            res.on('data', (chunk) => data += chunk);
            res.on('end', () => {
                try {
                    const j = JSON.parse(data);
                    const tag = j.tag_name || '';
                    const assets = j.assets || [];
                    const exe = assets.find(a => a.name.endsWith('.exe') && !a.name.endsWith('.exe.blockmap'));
                    resolve({ tag, downloadUrl: exe ? exe.browser_download_url : null, name: exe ? exe.name : null });
                } catch { reject(new Error('parse failed')); }
            });
        }).on('error', reject);
    });
}

ipcMain.handle('check-update', async () => {
    try {
        const release = await getLatestRelease();
        const latestVer = release.tag.replace(/^v/, '');
        const hasUpdate = parseVersion(latestVer) > parseVersion(currentVersion);
        return { hasUpdate, latestVer: release.tag, downloadUrl: release.downloadUrl, exeName: release.name };
    } catch (err) {
        return { hasUpdate: false, latestVer: '', downloadUrl: null, error: err.message };
    }
});

ipcMain.handle('get-check-updates', () => {
    const cfg = getConfig();
    return { enabled: cfg.checkUpdates !== false };
});

ipcMain.handle('set-check-updates', (_e, enabled) => {
    saveConfig({ checkUpdates: enabled });
    return { enabled };
});

ipcMain.handle('download-update', async (_e, url) => {
    const dest = path.join(app.getPath('temp'), path.basename(url));
    downloadPath = dest;
    const file = fs.createWriteStream(dest);
    await new Promise((resolve, reject) => {
        const u = new URL(url);
        https.get({ hostname: u.hostname, path: u.pathname, rejectUnauthorized: false }, (res) => {
            res.on('error', reject);
            res.pipe(file);
            file.on('finish', () => resolve());
            file.on('error', reject);
        }).on('error', reject);
    });
    return { path: dest };
});

ipcMain.handle('install-update', () => {
    if (downloadPath && fs.existsSync(downloadPath)) {
        shell.openPath(downloadPath);
        app.quit();
        return { success: true };
    }
    return { success: false, error: 'no downloaded file' };
});

app.isQuitting = false;
app.on('before-quit', () => { app.isQuitting = true; stopMonitor(); });
app.whenReady().then(() => {
    configPath = path.join(app.getPath('userData'), 'config.json');
    applyAutoStart();
    const cfg = getConfig();
    if (cfg.autoAllow === true) startMonitor();
    createWindow();
    createTray();
    if (cfg.silentStart === true) mainWindow.hide();
    // Auto-check updates
    if (cfg.checkUpdates !== false) {
        getLatestRelease().then(release => {
            const latestVer = release.tag.replace(/^v/, '');
            if (parseVersion(latestVer) > parseVersion(currentVersion) && mainWindow) {
                mainWindow.webContents.send('update-available', { hasUpdate: true, latestVer: release.tag, downloadUrl: release.downloadUrl, exeName: release.name });
            }
        }).catch(() => {});
    }
});
app.on('window-all-closed', () => {});
