import * as gpui from "./gpui-browser.js";

const elements = {
  frame: document.querySelector("#canvas-frame"),
  badge: document.querySelector("#frame-state"),
  logical: document.querySelector("#logical-size"),
  backing: document.querySelector("#backing-size"),
  scale: document.querySelector("#device-scale"),
  events: document.querySelector("#event-count"),
  sequence: document.querySelector("#sequence"),
  target: document.querySelector("#hit-target"),
  focus: document.querySelector("#focus-target"),
  activations: document.querySelector("#activation-count"),
  lastEvent: document.querySelector("#last-event"),
  diagnostic: document.querySelector("#diagnostic"),
  diagnosticTitle: document.querySelector("#diagnostic-title"),
  diagnosticMessage: document.querySelector("#diagnostic-message"),
  diagnosticCode: document.querySelector("#diagnostic-code"),
  capabilities: document.querySelector("#capabilities"),
  remount: document.querySelector("#remount"),
};

const capabilityRows = [
  ["Logical viewport", "logicalViewport"],
  ["Canvas quad frames", "quadFrames"],
  ["Pointer + keyboard", "pointerKeyboard"],
  ["Native window", "nativeWindow"],
  ["Clipboard", "clipboard"],
  ["Cursor control", "cursor"],
  ["IME bridge", "textInputIme"],
  ["Accessibility bridge", "accessibility"],
  ["Renderer recovery", "rendererRecovery"],
  ["Worker commands", "crossThreadCommands"],
];

let canvas = null;
let context = null;
let resizeObserver = null;
let dprQuery = null;
let frameRequest = 0;
let running = false;
let adapterStarted = false;
let surfaceLost = false;
let logicalWidth = 0;
let logicalHeight = 0;
let deviceScale = 0;
let listeners = [];

class FrameworkHostError extends Error {
  constructor(diagnostic) {
    super(diagnostic.message || diagnostic.operation || "Browser host failure");
    this.name = "FrameworkHostError";
    this.diagnostic = diagnostic;
  }
}

function call(name, ...args) {
  let response;
  try {
    response = JSON.parse(gpui[name](...args));
  } catch (error) {
    throw new FrameworkHostError({
      code: "conversion_failed",
      operation: `BrowserBackend::${name}`,
      message: error instanceof Error ? error.message : String(error),
    });
  }
  if (!response?.ok) throw new FrameworkHostError(response?.error || {
    code: "conversion_failed",
    operation: `BrowserBackend::${name}`,
    message: "The framework returned an invalid response envelope.",
  });
  return response.value;
}

function listen(target, type, handler, options) {
  target.addEventListener(type, handler, options);
  listeners.push(() => target.removeEventListener(type, handler, options));
}

function showDiagnostic(error) {
  const diagnostic = error instanceof FrameworkHostError
    ? error.diagnostic
    : {
        code: "surface_lost",
        operation: "BrowserBackend::host_callback",
        message: error instanceof Error ? error.message : String(error),
      };
  elements.badge.textContent = "ERROR";
  elements.badge.dataset.state = "error";
  elements.diagnosticTitle.textContent = diagnostic.operation || "Browser host error";
  elements.diagnosticMessage.textContent = diagnostic.message || "The browser host could not continue.";
  elements.diagnosticCode.textContent = `${diagnostic.code || "unknown"} · ${diagnostic.subsystem || "browser"} · ${diagnostic.backend || "js/canvas-2d"}`;
  elements.diagnostic.hidden = false;
}

function clearDiagnostic() {
  elements.diagnostic.hidden = true;
  elements.badge.dataset.state = "running";
  elements.badge.textContent = "RUNNING";
}

function scheduleFrame() {
  if (!running || surfaceLost || document.hidden || frameRequest !== 0) return;
  frameRequest = requestAnimationFrame(renderFrame);
}

function cancelFrame() {
  if (frameRequest !== 0) cancelAnimationFrame(frameRequest);
  frameRequest = 0;
}

function syncViewport() {
  if (!running || surfaceLost || !canvas) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(3)).error);
  const bounds = canvas.getBoundingClientRect();
  const width = bounds.width;
  const height = bounds.height;
  const scale = window.devicePixelRatio || 1;
  if (!Number.isFinite(width) || !Number.isFinite(height) || width < 1 || height < 1 || !Number.isFinite(scale) || scale <= 0) {
    throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(2)).error);
  }
  const pixelWidth = Math.max(1, Math.round(width * scale));
  const pixelHeight = Math.max(1, Math.round(height * scale));
  if (canvas.width !== pixelWidth) canvas.width = pixelWidth;
  if (canvas.height !== pixelHeight) canvas.height = pixelHeight;
  if (width !== logicalWidth || height !== logicalHeight || scale !== deviceScale) {
    // Accept the new scale/size before any later pointer or key callback enters the queue.
    call("gpui_browser_set_viewport", width, height, scale);
    logicalWidth = width;
    logicalHeight = height;
    deviceScale = scale;
    elements.logical.textContent = `${Math.round(width)} × ${Math.round(height)} CSS px`;
    elements.backing.textContent = `${canvas.width} × ${canvas.height} px`;
    elements.scale.textContent = `${scale.toFixed(2)}×`;
  }
}

function rgba(color) {
  for (const channel of [color.red, color.green, color.blue, color.alpha]) {
    if (!Number.isInteger(channel) || channel < 0 || channel > 255) {
      throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
    }
  }
  return `rgba(${color.red}, ${color.green}, ${color.blue}, ${color.alpha / 255})`;
}

function drawSnapshot(snapshot) {
  if (snapshot.schema_version !== 1 || snapshot.resources.length !== 0 || !Array.isArray(snapshot.items) || !Array.isArray(snapshot.clip_chains)) {
    throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
  }
  const viewport = snapshot.viewport;
  if (![viewport.x, viewport.y, viewport.width, viewport.height, snapshot.scale].every(Number.isFinite) || viewport.width <= 0 || viewport.height <= 0 || snapshot.scale <= 0) {
    throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
  }

  context.setTransform(deviceScale, 0, 0, deviceScale, 0, 0);
  context.clearRect(0, 0, logicalWidth, logicalHeight);
  for (const item of snapshot.items) {
    if (item.kind !== "quad" || !Number.isFinite(item.opacity) || item.opacity < 0 || item.opacity > 1) {
      throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
    }
    const { x, y, width, height } = item.bounds;
    const transform = item.transform;
    if (![x, y, width, height, transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].every(Number.isFinite)) {
      throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
    }
    context.save();
    try {
      // Clip rectangles are viewport-space and are applied before each item's transform.
      if (item.clip_chain_id !== null) {
        const chain = snapshot.clip_chains.find((candidate) => candidate.id === item.clip_chain_id);
        if (!chain) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
        for (const clip of chain.rects) {
          if (![clip.x, clip.y, clip.width, clip.height].every(Number.isFinite)) {
            throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(4)).error);
          }
          context.beginPath();
          context.rect(clip.x, clip.y, clip.width, clip.height);
          context.clip();
        }
      }
      context.transform(transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty);
      context.globalAlpha = item.opacity;
      context.fillStyle = rgba(item.color);
      context.fillRect(x, y, width, height);
    } finally {
      context.restore();
    }
  }
  context.globalAlpha = 1;
}

function refreshStatus() {
  const status = JSON.parse(gpui.gpui_browser_status());
  elements.events.textContent = String(status.events ?? 0);
  elements.sequence.textContent = String(status.lastSequence ?? 0);
  elements.target.textContent = status.target == null ? "—" : `#${status.target}`;
  elements.focus.textContent = status.focus == null ? "—" : `#${status.focus}`;
  elements.activations.textContent = String(status.clicks ?? 0);
  elements.lastEvent.textContent = status.lastEvent || "Viewport ready";
}

function renderFrame() {
  frameRequest = 0;
  if (!running || surfaceLost || document.hidden) return;
  try {
    syncViewport();
    const snapshot = call("gpui_browser_render_frame");
    drawSnapshot(snapshot);
    refreshStatus();
    clearDiagnostic();
  } catch (error) {
    showDiagnostic(error);
  }
}

function queueInput(callback, ...args) {
  if (!running || surfaceLost) return;
  try {
    syncViewport();
    call(callback, ...args);
    scheduleFrame();
  } catch (error) {
    showDiagnostic(error);
  }
}

function modifiers(event) {
  return [event.shiftKey, event.ctrlKey, event.altKey, event.metaKey];
}

function trackDpr() {
  if (dprQuery) {
    if (dprQuery.removeEventListener) dprQuery.removeEventListener("change", onDprChange);
    else dprQuery.removeListener(onDprChange);
  }
  dprQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
  if (dprQuery.addEventListener) dprQuery.addEventListener("change", onDprChange, { once: true });
  else dprQuery.addListener(onDprChange);
}

function onDprChange() {
  if (!running || surfaceLost) return;
  try {
    syncViewport();
    trackDpr();
    scheduleFrame();
  } catch (error) {
    showDiagnostic(error);
  }
}

function attachCanvasEvents() {
  listen(canvas, "pointermove", (event) => {
    const bounds = canvas.getBoundingClientRect();
    queueInput("gpui_browser_pointer_move", event.clientX - bounds.left, event.clientY - bounds.top);
  });
  const pointerButton = (event, pressed) => {
    if (pressed) canvas.focus({ preventScroll: true });
    const bounds = canvas.getBoundingClientRect();
    queueInput("gpui_browser_pointer_button", event.clientX - bounds.left, event.clientY - bounds.top, event.button, pressed, ...modifiers(event));
  };
  listen(canvas, "pointerdown", (event) => {
    pointerButton(event, true);
    try { canvas.setPointerCapture(event.pointerId); } catch { /* Some synthetic events cannot be captured. */ }
  });
  listen(canvas, "pointerup", (event) => pointerButton(event, false));
  listen(canvas, "pointercancel", (event) => pointerButton(event, false));
  listen(canvas, "keydown", (event) => {
    if (["Tab", "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", " "].includes(event.key)) event.preventDefault();
    queueInput("gpui_browser_key", event.key, true, event.repeat, ...modifiers(event));
  });
  listen(canvas, "keyup", (event) => queueInput("gpui_browser_key", event.key, false, false, ...modifiers(event)));
  listen(canvas, "focus", () => queueInput("gpui_browser_focus", true));
  listen(canvas, "blur", () => queueInput("gpui_browser_focus", false));
  listen(canvas, "contextlost", (event) => {
    event.preventDefault();
    surfaceLost = true;
    cancelFrame();
    showDiagnostic(new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(5)).error));
  });
}

function resetCanvas() {
  const replacement = document.createElement("canvas");
  replacement.id = "gpui-viewport";
  replacement.tabIndex = 0;
  replacement.setAttribute("aria-label", "gpui.mbt canvas viewport. Use Tab and arrow keys to move focus, then Enter or Space to activate.");
  elements.frame.insertBefore(replacement, elements.frame.firstChild);
  canvas = replacement;
}

function stop() {
  const hadAdapter = adapterStarted;
  running = false;
  adapterStarted = false;
  surfaceLost = false;
  cancelFrame();
  if (resizeObserver) resizeObserver.disconnect();
  resizeObserver = null;
  if (dprQuery) {
    if (dprQuery.removeEventListener) dprQuery.removeEventListener("change", onDprChange);
    else dprQuery.removeListener(onDprChange);
  }
  dprQuery = null;
  for (const remove of listeners.splice(0)) remove();
  if (hadAdapter) gpui.gpui_browser_destroy();
  context = null;
  if (canvas?.isConnected) canvas.remove();
  canvas = null;
  logicalWidth = 0;
  logicalHeight = 0;
  deviceScale = 0;
}

function start() {
  if (running) stop();
  try {
    if (!elements.frame) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(0)).error);
    canvas = elements.frame.querySelector("#gpui-viewport");
    if (!canvas) resetCanvas();
    context = canvas.getContext("2d", { alpha: false, desynchronized: true });
    if (!context) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(1)).error);
    call("gpui_browser_start");
    adapterStarted = true;
    running = true;
    attachCanvasEvents();
    call("gpui_browser_visibility", !document.hidden);
    listen(window, "resize", () => queueInput("gpui_browser_set_viewport", canvas.getBoundingClientRect().width, canvas.getBoundingClientRect().height, window.devicePixelRatio || 1));
    listen(document, "visibilitychange", () => {
      if (document.hidden) {
        cancelFrame();
        try { call("gpui_browser_visibility", false); } catch (error) { showDiagnostic(error); }
      } else {
        try {
          syncViewport();
          call("gpui_browser_visibility", true);
          scheduleFrame();
        } catch (error) { showDiagnostic(error); }
      }
    });
    resizeObserver = new ResizeObserver(() => {
      try { syncViewport(); scheduleFrame(); } catch (error) { showDiagnostic(error); }
    });
    resizeObserver.observe(canvas);
    trackDpr();
    syncViewport();
    scheduleFrame();
    elements.capabilities.replaceChildren(...capabilityRows.map(([label, key]) => {
      const item = document.createElement("li");
      item.className = gpuiCapabilities[key] ? "yes" : "no";
      item.textContent = label;
      return item;
    }));
    clearDiagnostic();
  } catch (error) {
    stop();
    showDiagnostic(error);
  }
}

const gpuiCapabilities = JSON.parse(gpui.gpui_browser_capabilities());
elements.remount.addEventListener("click", () => start());
window.addEventListener("pagehide", stop);
window.addEventListener("pageshow", (event) => { if (event.persisted || !running) start(); });
start();
