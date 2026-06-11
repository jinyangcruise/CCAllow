const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ccallow', {
    getVersion: () => ipcRenderer.invoke('get-version'),
    getTheme: () => ipcRenderer.invoke('get-theme'),
    setTheme: (v) => ipcRenderer.invoke('set-theme', v),
    toggleMonitor: () => ipcRenderer.invoke('toggle-monitor'),
    getStatus: () => ipcRenderer.invoke('get-status'),
    getAutoStart: () => ipcRenderer.invoke('get-auto-start'),
    setAutoStart: (v) => ipcRenderer.invoke('set-auto-start', v),
    getSilentStart: () => ipcRenderer.invoke('get-silent-start'),
    setSilentStart: (v) => ipcRenderer.invoke('set-silent-start', v),
    getMinimizedPolling: () => ipcRenderer.invoke('get-minimized-polling'),
    setMinimizedPolling: (v) => ipcRenderer.invoke('set-minimized-polling', v),
    getMinimizedInterval: () => ipcRenderer.invoke('get-minimized-interval'),
    setMinimizedInterval: (v) => ipcRenderer.invoke('set-minimized-interval', v),
    getMinimizeAfterAllow: () => ipcRenderer.invoke('get-minimize-after-allow'),
    setMinimizeAfterAllow: (v) => ipcRenderer.invoke('set-minimize-after-allow', v),
    getLanguage: () => ipcRenderer.invoke('get-language'),
    setLanguage: (v) => ipcRenderer.invoke('set-language', v),
    onTrayToggle: (cb) => ipcRenderer.on('tray-toggle', () => cb()),
    onMonitorLog: (cb) => ipcRenderer.on('monitor-log', (_e, msg) => cb(msg)),
});
