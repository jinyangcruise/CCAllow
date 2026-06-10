const { app, BrowserWindow, ipcMain, dialog, Tray, Menu, nativeImage } = require('electron');
const puppeteer = require('puppeteer-core');
const path = require('path');
const fs = require('fs');
const { spawn } = require('child_process');
const zlib = require('zlib');

let mainWindow;
let tray;
let cdpBrowser = null;
let claudeProcess = null;
let isConnected = false;

// ── generate a 16×16 purple circle PNG in memory ──
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

    function pngCrc(data) {
        let c = 0xFFFFFFFF >>> 0;
        for (let i = 0; i < data.length; i++) c = (crcTable[(c ^ data[i]) & 0xFF] ^ (c >>> 8)) >>> 0;
        return (c ^ 0xFFFFFFFF) >>> 0;
    }

    function pngChunk(type, data) {
        const t = Buffer.from(type, 'ascii');
        const len = Buffer.alloc(4); len.writeUInt32BE(data.length, 0);
        const crc = Buffer.alloc(4); crc.writeUInt32BE(pngCrc(Buffer.concat([t, data])), 0);
        return Buffer.concat([len, t, data, crc]);
    }

    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(S, 0); ihdr.writeUInt32BE(S, 4);
    ihdr[8] = 8; ihdr[9] = 2;

    return nativeImage.createFromBuffer(Buffer.concat([
        Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
        pngChunk('IHDR', ihdr),
        pngChunk('IDAT', deflated),
        pngChunk('IEND', Buffer.alloc(0)),
    ]));
}

// ── window ──
function createWindow() {
    mainWindow = new BrowserWindow({
        width: 540, height: 520, resizable: false,
        webPreferences: {
            preload: path.join(__dirname, 'preload.js'),
            contextIsolation: true, nodeIntegration: false,
        },
    });
    mainWindow.loadFile('index.html');
    mainWindow.setMenu(null);
    mainWindow.on('close', (e) => {
        if (!app.isQuitting) { e.preventDefault(); mainWindow.hide(); }
    });
}

// ── tray ──
function createTray() {
    tray = new Tray(makeTrayIcon());
    tray.setToolTip('CCAllow');
    rebuildTrayMenu();
    tray.on('click', () => {
        if (mainWindow.isVisible()) { mainWindow.focus(); }
        else { mainWindow.show(); mainWindow.focus(); }
    });
}

function rebuildTrayMenu() {
    const tmpl = [
        { label: 'Show CCAllow', click: () => { mainWindow.show(); mainWindow.focus(); } },
        { type: 'separator' },
        isConnected
            ? { label: 'Disconnect', click: () => mainWindow.webContents.send('tray-disconnect') }
            : { label: 'Connect & Inject', click: () => mainWindow.webContents.send('tray-connect') },
        { type: 'separator' },
        { label: 'Exit', click: () => { app.isQuitting = true; app.quit(); } },
    ];
    tray.setContextMenu(Menu.buildFromTemplate(tmpl));
}

ipcMain.handle('get-version', () => require('./package.json').version);

// swap connect state from renderer
ipcMain.handle('set-connected', (_e, v) => { isConnected = v; rebuildTrayMenu(); return true; });

// ── Claude detection / selection / launch ──
function detectClaudePath() {
    if (process.platform === 'win32') {
        const localAppData = process.env.LOCALAPPDATA || '';
        const progFiles = process.env.ProgramFiles || '';
        const progFilesX86 = process.env['ProgramFiles(x86)'] || '';

        const candidates = [
            path.join(localAppData, 'Programs', 'Claude', 'Claude.exe'),
            path.join(localAppData, 'Claude', 'Claude.exe'),
            path.join(progFiles, 'Claude', 'Claude.exe'),
            path.join(progFilesX86, 'Claude', 'Claude.exe'),
            path.join(localAppData, 'Microsoft', 'WindowsApps', 'claude.exe'),
            path.join(localAppData, 'Programs', 'claude', 'Claude.exe'),
            path.join(localAppData, 'claude', 'Claude.exe'),
        ];

        for (const p of candidates) {
            try { if (fs.existsSync(p)) return p; } catch {}
        }

        const winApps = path.join(progFiles, 'WindowsApps');
        try {
            if (fs.existsSync(winApps)) {
                const entries = fs.readdirSync(winApps, { withFileTypes: true });
                for (const entry of entries) {
                    if (!entry.isDirectory() || !entry.name.startsWith('Claude_')) continue;
                    const fp = path.join(winApps, entry.name, 'app', 'claude.exe');
                    try { if (fs.existsSync(fp)) return fp; } catch {}
                }
            }
        } catch {}
        return null;
    }

    if (process.platform === 'darwin') {
        const p = '/Applications/Claude.app/Contents/MacOS/Claude';
        try { if (fs.existsSync(p)) return p; } catch {}
        return null;
    }

    for (const p of ['/usr/bin/claude', '/usr/local/bin/claude']) {
        try { if (fs.existsSync(p)) return p; } catch {}
    }
    return null;
}

ipcMain.handle('detect-claude', async () => ({ path: detectClaudePath() }));

ipcMain.handle('select-claude', async () => {
    const filters = process.platform === 'win32'
        ? [{ name: 'Executable', extensions: ['exe'] }]
        : process.platform === 'darwin'
            ? [{ name: 'Application', extensions: ['app'] }]
            : [];
    const result = await dialog.showOpenDialog(mainWindow, { title: '选择 Claude Desktop', properties: ['openFile'], filters });
    return { path: (result.canceled || !result.filePaths.length) ? null : result.filePaths[0] };
});

ipcMain.handle('launch-claude', async (_event, claudePath, port) => {
    if (claudeProcess) return { success: false, error: 'Claude is already running from this launcher' };

    if (!fs.existsSync(claudePath)) {
        return { success: false, error: `File not found: ${claudePath}` };
    }

    const exeDir = path.dirname(claudePath);
    const isStoreApp = claudePath.includes('WindowsApps');

    let attempts = [claudePath];

    // For Store Apps, also try the execution alias
    if (isStoreApp) {
        const alias = path.join(process.env.LOCALAPPDATA || '', 'Microsoft', 'WindowsApps', 'claude.exe');
        if (fs.existsSync(alias)) attempts.push(alias);
    }

    for (const exe of attempts) {
        let stderrBuf = '';
        let launchOk = false;

        const code = await new Promise((resolve) => {
            const proc = spawn(exe, [`--remote-debugging-port=${port}`], {
                cwd: exeDir, detached: true, stdio: ['ignore', 'pipe', 'pipe'],
            });
            proc.on('error', (err) => { resolve('err:' + err.message); });
            proc.stdout.on('data', (d) => { if (mainWindow) mainWindow.webContents.send('launch-log', d.toString().trim()); });
            proc.stderr.on('data', (d) => {
                stderrBuf += d.toString();
                if (mainWindow) mainWindow.webContents.send('launch-log', d.toString().trim());
            });
            proc.on('exit', (code) => { resolve(code); });
            // If still running after 800ms, consider it a success
            setTimeout(() => {
                if (proc.exitCode === null) {
                    launchOk = true;
                    claudeProcess = proc;
                    resolve(null);
                }
            }, 800);
        });

        if (launchOk) {
            if (mainWindow) mainWindow.webContents.send('launch-log', `Launched: ${exe}`);
            return { success: true };
        }

        if (typeof code === 'string' && code.startsWith('err:')) {
            if (mainWindow) mainWindow.webContents.send('launch-log', `[${path.basename(exe)}] ${code}`);
            continue;
        }

        if (stderrBuf.trim()) {
            if (mainWindow) mainWindow.webContents.send('launch-log', `[${path.basename(exe)}] exit:${code} stderr:\n${stderrBuf.trim()}`);
        }

        if (exe === attempts[attempts.length - 1]) {
            return { success: false, error: `All launch attempts failed (last exit: ${code})` };
        }
    }

    return { success: false, error: 'Unknown error' };
});

// ── CDP connect / inject ──
ipcMain.handle('connect', async (_event, port) => {
    try {
        const browserURL = `http://127.0.0.1:${port}`;
        cdpBrowser = await puppeteer.connect({ browserURL, defaultViewport: null });
        const pages = await cdpBrowser.pages();
        let targetPages = pages.filter(p => { const u = p.url().toLowerCase(); return u.includes('claude') || u.includes('claude.ai'); });
        if (!targetPages.length) targetPages = pages.filter(p => { const u = p.url(); return u && u !== 'about:blank' && !u.startsWith('devtools://') && !u.startsWith('chrome-extension://'); });
        if (!targetPages.length) { await cdpBrowser.disconnect(); cdpBrowser = null; return { success: false, error: 'No renderer page found' }; }

        const injectCode = fs.readFileSync(path.join(__dirname, 'inject.js'), 'utf-8');
        for (const page of targetPages) { try { await page.evaluate(injectCode); } catch (e) { return { success: false, error: 'Inject failed: ' + e.message }; } }

        isConnected = true;
        rebuildTrayMenu();
        return { success: true, pages: targetPages.length };
    } catch (err) {
        if (cdpBrowser) { try { await cdpBrowser.disconnect(); } catch {} cdpBrowser = null; }
        return { success: false, error: err.message };
    }
});

ipcMain.handle('disconnect', async () => {
    if (cdpBrowser) { try { await cdpBrowser.disconnect(); } catch {} cdpBrowser = null; }
    isConnected = false;
    rebuildTrayMenu();
    return { success: true };
});

// ── lifecycle ──
app.isQuitting = false;

app.on('before-quit', () => { app.isQuitting = true;
    if (cdpBrowser) { try { cdpBrowser.disconnect(); } catch {} }
    if (claudeProcess) { try { claudeProcess.kill(); } catch {} claudeProcess = null; }
});

app.whenReady().then(() => { createWindow(); createTray(); });

app.on('window-all-closed', () => {});
