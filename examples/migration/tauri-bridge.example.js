import { invoke } from "@tauri-apps/api/core";
import { createTauriHostServices } from "./host-services.js";

// Keep this empty until the Rust command and its input validation are ready.
// Each operation maps to one fixed command; renderer input cannot choose names.
export const gpuiHostServices = createTauriHostServices(invoke, {
  commands: {},
});
