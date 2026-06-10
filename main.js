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

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 480, height: 340, resizable: true,
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

    monitorProcess = spawn('powershell', [
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', psPath,
    ], { stdio: ['pipe', 'pipe', 'pipe'] });

    monitorProcess.stdout.on('data', (d) => {
        if (mainWindow) mainWindow.webContents.send('monitor-log', d.toString().trim());
    });
    monitorProcess.stderr.on('data', (d) => {
        if (mainWindow) mainWindow.webContents.send('monitor-log', '[err] ' + d.toString().trim());
    });
    monitorProcess.on('error', () => { monitorProcess = null; monitorEnabled = false; rebuildTrayMenu(); });
    monitorProcess.on('exit', () => { monitorProcess = null; monitorEnabled = false; rebuildTrayMenu(); });
    monitorEnabled = true;
    rebuildTrayMenu();
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

app.isQuitting = false;
app.on('before-quit', () => { app.isQuitting = true; stopMonitor(); });
app.whenReady().then(() => { createWindow(); createTray(); });
app.on('window-all-closed', () => {});
