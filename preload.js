const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ccallow', {
    toggleMonitor: () => ipcRenderer.invoke('toggle-monitor'),
    getStatus: () => ipcRenderer.invoke('get-status'),
    getAutoStart: () => ipcRenderer.invoke('get-auto-start'),
    setAutoStart: (v) => ipcRenderer.invoke('set-auto-start', v),
    getSilentStart: () => ipcRenderer.invoke('get-silent-start'),
    setSilentStart: (v) => ipcRenderer.invoke('set-silent-start', v),
    onTrayToggle: (cb) => ipcRenderer.on('tray-toggle', () => cb()),
    onMonitorLog: (cb) => ipcRenderer.on('monitor-log', (_e, msg) => cb(msg)),
});
