import { contextBridge, ipcRenderer } from "electron";
import { installElectronContextBridge } from "./host-services.js";

// Add only operations that the Electron main process independently validates.
installElectronContextBridge({
  contextBridge,
  ipcRenderer,
  allowedOperations: [],
});
