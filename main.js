const { app, BrowserWindow, ipcMain, Tray, Menu } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const assetsDir = path.join(__dirname, 'assets');
const iconPath = path.join(assetsDir, 'icon.png');
const trayIconPath = path.join(assetsDir, 'tray-icon.png');

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
    tray.setToolTip('CCAllow');
    rebuildTrayMenu();
    tray.on('click', () => { mainWindow.isVisible() ? mainWindow.focus() : (mainWindow.show(), mainWindow.focus()); });
}

function rebuildTrayMenu() {
    if (!tray) return;
    const tmpl = [
        { label: 'Show CCAAllow', click: () => { mainWindow.show(); mainWindow.focus(); } },
        { type: 'separator' },
        monitorEnabled
            ? { label: 'Stop Monitoring', click: () => mainWindow.webContents.send('tray-toggle') }
            : { label: 'Start Monitoring', click: () => mainWindow.webContents.send('tray-toggle') },
        { type: 'separator' },
        { label: 'Exit', click: () => { app.isQuitting = true; app.quit(); } },
    ];
    tray.setContextMenu(Menu.buildFromTemplate(tmpl));
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
}

function sendMonitorCmd(cmd) {
    if (monitorProcess && monitorProcess.stdin.writable) {
        try { monitorProcess.stdin.write(cmd + '\n'); } catch {}
    }
}

function stopMonitor() {
    if (!monitorProcess) return;
    try {
        monitorProcess.stdin.write('exit\n');
        monitorProcess.stdin.end();
        setTimeout(() => { try { monitorProcess.kill(); } catch {} }, 500);
    } catch {}
    monitorProcess = null;
    monitorEnabled = false;
    rebuildTrayMenu();
}

ipcMain.handle('toggle-monitor', () => {
    if (monitorEnabled) stopMonitor();
    else startMonitor();
    return { enabled: monitorEnabled };
});

ipcMain.handle('get-status', () => ({ enabled: monitorEnabled }));

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
    // Restart monitor to apply change
    if (monitorEnabled) { stopMonitor(); startMonitor(); }
    return { enabled };
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

app.isQuitting = false;
app.on('before-quit', () => { app.isQuitting = true; stopMonitor(); });
app.whenReady().then(() => {
    configPath = path.join(app.getPath('userData'), 'config.json');
    applyAutoStart();
    const cfg = getConfig();
    if (cfg.autoStart !== false) startMonitor();
    createWindow();
    createTray();
    if (cfg.silentStart === true) mainWindow.hide();
});
app.on('window-all-closed', () => {});
