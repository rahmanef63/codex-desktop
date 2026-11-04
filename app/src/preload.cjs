// The only bridge between the page and the main process. Four functions, no dynamic channel
// names: the renderer cannot reach ipcRenderer, so it cannot invoke a handler that is not
// listed here.
const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("byok", {
  profiles: () => ipcRenderer.invoke("profiles"),
  drift: () => ipcRenderer.invoke("drift"),
  apply: (target) => ipcRenderer.invoke("apply", target),
  recordDrift: () => ipcRenderer.invoke("record-drift"),
});
