const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('ccallow', {
    getVersion: () => ipcRenderer.invoke('get-version'),
    detectClaude: () => ipcRenderer.invoke('detect-claude'),
    selectClaude: () => ipcRenderer.invoke('select-claude'),
    launchClaude: (claudePath, port) => ipcRenderer.invoke('launch-claude', claudePath, port),
    connect: (port) => ipcRenderer.invoke('connect', port),
    disconnect: () => ipcRenderer.invoke('disconnect'),
    setConnected: (v) => ipcRenderer.invoke('set-connected', v),
    onLaunchError: (cb) => ipcRenderer.on('launch-error', (_e, msg) => cb(msg)),
    onLaunchExit: (cb) => ipcRenderer.on('launch-exit', (_e, code) => cb(code)),
    onLaunchLog: (cb) => ipcRenderer.on('launch-log', (_e, msg) => cb(msg)),
    onTrayConnect: (cb) => ipcRenderer.on('tray-connect', () => cb()),
    onTrayDisconnect: (cb) => ipcRenderer.on('tray-disconnect', () => cb()),
});
