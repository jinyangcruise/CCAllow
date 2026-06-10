const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ccallow', {
    toggleMonitor: () => ipcRenderer.invoke('toggle-monitor'),
    getStatus: () => ipcRenderer.invoke('get-status'),
    onTrayToggle: (cb) => ipcRenderer.on('tray-toggle', () => cb()),
});
