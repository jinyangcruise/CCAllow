const { app, BrowserWindow, ipcMain, Tray, Menu, nativeImage } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');
const zlib = require('zlib');

let mainWindow;
let tray;
let monitorProcess = null;
let monitorEnabled = false;

// ── generate tray icon ──
function makeTrayIcon() {
    const S = 16, R = 79, G = 70, B = 229;
    const raw = Buffer.alloc(S * (S * 3 + 1));
    for (let y = 0; y < S; y++) {
        raw[y * (S * 3 + 1)] = 0;
        for (let x = 0; x < S; x++) {
            const off = y * (S * 3 + 1) + 1 + x * 3;
            const d = Math.hypot(x - 7.5, y - 7.5);
            if (d < 6.5) { raw[off] = R; raw[off + 1] = G; raw[off + 2] = B; }
            else         { raw[off] = 0; raw[off + 1] = 0; raw[off + 2] = 0; }
        }
    }
    const deflated = zlib.deflateSync(raw);
    const crcTable = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
        let c = i;
        for (let j = 0; j < 8; j++) c = (c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
        crcTable[i] = c;
    }
    function pngCrc(d) { let c = 0xFFFFFFFF >>> 0; for (let i = 0; i < d.length; i++) c = (crcTable[(c ^ d[i]) & 0xFF] ^ (c >>> 8)) >>> 0; return (c ^ 0xFFFFFFFF) >>> 0; }
    function pngChunk(typ, data) { const t = Buffer.from(typ, 'ascii'); const len = Buffer.alloc(4); len.writeUInt32BE(data.length); const crc = Buffer.alloc(4); crc.writeUInt32BE(pngCrc(Buffer.concat([t, data]))); return Buffer.concat([len, t, data, crc]); }
    const ihdr = Buffer.alloc(13); ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4); ihdr[8] = 8; ihdr[9] = 2;
    return nativeImage.createFromBuffer(Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), pngChunk('IHDR', ihdr), pngChunk('IDAT', deflated), pngChunk('IEND', Buffer.alloc(0))]));
}

function createWindow() {
    mainWindow = new BrowserWindow({
        width: 480, height: 320, resizable: false,
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
    tray = new Tray(makeTrayIcon());
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
