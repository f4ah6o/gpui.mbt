import * as gpui from "mbt:f4ah6o/gpui/examples/browser";
import { createLegacyIsland } from "../../migration/legacy-island.js";
import { createBrowserClipboard } from "./clipboard.js";
import { createTextInputBridge } from "./text-input.js";

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
  capabilityValue: document.querySelector("#capability-value"),
  lastEvent: document.querySelector("#last-event"),
  diagnostic: document.querySelector("#diagnostic"),
  diagnosticTitle: document.querySelector("#diagnostic-title"),
  diagnosticMessage: document.querySelector("#diagnostic-message"),
  diagnosticCode: document.querySelector("#diagnostic-code"),
  capabilities: document.querySelector("#capabilities"),
  remount: document.querySelector("#remount"),
  returnFramework: document.querySelector("#return-framework"),
  hostInputOwner: document.querySelector("#host-input-owner"),
  textStart: document.querySelector("#text-input-start"),
  textStop: document.querySelector("#text-input-stop"),
  textState: document.querySelector("#text-input-state"),
  committedText: document.querySelector("#committed-text"),
  textCommitCount: document.querySelector("#text-commit-count"),
  clipboardCopy: document.querySelector("#clipboard-copy"),
  clipboardPaste: document.querySelector("#clipboard-paste"),
  clipboardValue: document.querySelector("#clipboard-value"),
  clipboardResult: document.querySelector("#clipboard-result"),
};

const capabilityRows = [
  ["Logical viewport", "logicalViewport"],
  ["Canvas quad frames", "quadFrames"],
  ["Pointer + keyboard", "pointerKeyboard"],
  ["Native window", "nativeWindow"],
  ["Clipboard", "clipboard"],
  ["Cursor control", "cursor"],
  ["Committed text", "committedTextInput"],
  ["Full text / IME", "textInputIme"],
  ["Accessibility bridge", "accessibility"],
  ["Migration ARIA fixture", "accessibilityFixture"],
  ["Renderer recovery", "rendererRecovery"],
  ["Worker commands", "crossThreadCommands"],
];

const browserCursorValues = {
  arrow: "default",
  "pointing-hand": "pointer",
  text: "text",
};

let canvas = null;
let context = null;
let resizeObserver = null;
let dprQuery = null;
let dprListener = null;
let frameRequest = 0;
let running = false;
let adapterStarted = false;
let surfaceLost = false;
let restorationPending = false;
// undefined retains the selection, null clears it, and an id selects a proxy.
let suspendedSemanticFocus;
let hostGeneration = 0;
let rendererStats = { completedFrames: 0, lossCount: 0, restoreAttempts: 0, recoveries: 0 };
let logicalWidth = 0;
let logicalHeight = 0;
let deviceScale = 0;
let listeners = [];
const activePointerButtons = new Map();
const accessibilityButtons = new Map();
let accessibilityLayer = null;
let legacySurface = null;
let legacyEditor = null;
let legacySave = null;
let legacyIsland = null;
let currentHostLayout = null;
let legacyRequestedVisible = true;
let textInputBridge = null;
let clipboardService = null;
let clipboardRequestId = 0n;
let clipboardBusy = false;

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
  const generation = hostGeneration;
  const callback = (event) => {
    if (running && generation === hostGeneration) handler(event);
  };
  target.addEventListener(type, callback, options);
  listeners.push(() => target.removeEventListener(type, callback, options));
}

function showDiagnostic(error) {
  const diagnostic = error instanceof FrameworkHostError
    ? error.diagnostic
    : {
        code: "callback_failure",
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
  if (!running || (surfaceLost && !restorationPending) || document.hidden || frameRequest !== 0) return;
  const generation = hostGeneration;
  const request = requestAnimationFrame(() => {
    // A cancelled callback from a prior mount must not clear a new request.
    if (generation !== hostGeneration || frameRequest !== request) return;
    renderFrame();
  });
  frameRequest = request;
}

function cancelFrame() {
  if (frameRequest !== 0) cancelAnimationFrame(frameRequest);
  frameRequest = 0;
}

function syncViewport() {
  if (!running || !canvas) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(3)).error);
  if (surfaceLost && !restorationPending) throw rendererError("The Canvas 2D surface is awaiting a contextrestored event.");
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

function rendererError(message, operation = "BrowserBackend::present") {
  return new FrameworkHostError({
    ...JSON.parse(gpui.gpui_browser_host_error(5)).error,
    operation,
    message,
  });
}

function checkRenderer() {
  if (!context || (typeof context.isContextLost === "function" && context.isContextLost())) {
    throw rendererError("The browser Canvas 2D context is lost.");
  }
}

function releasePointerCaptures() {
  const pointers = [...activePointerButtons.keys()];
  activePointerButtons.clear();
  for (const id of pointers) {
    try {
      if (canvas?.hasPointerCapture(id)) canvas.releasePointerCapture(id);
    } catch { /* The browser may already have cancelled a lost pointer stream. */ }
  }
}

function loseRenderer(error) {
  if (!surfaceLost || restorationPending) rendererStats.lossCount += 1;
  surfaceLost = true;
  restorationPending = false;
  textInputBridge?.stop();
  context = null;
  cancelFrame();
  releasePointerCaptures();
  showDiagnostic(error);
}

function restoreRenderer() {
  if (!running || !surfaceLost || restorationPending || !canvas) return;
  rendererStats.restoreAttempts += 1;
  try {
    context = canvas.getContext("2d", { alpha: false, desynchronized: true });
    checkRenderer();
  } catch (error) {
    // Restoration is event driven: one acquisition attempt, with no timer or
    // animation-frame retry loop. Another browser restore event may retry it.
    loseRenderer(rendererError(
      `Canvas 2D restoration failed: ${error instanceof Error ? error.message : String(error)}`,
      "BrowserBackend::restore_renderer",
    ));
    return;
  }
  restorationPending = true;
  try {
    syncViewport();
    trackDpr();
    scheduleFrame();
  } catch (error) {
    restorationPending = false;
    context = null;
    showDiagnostic(error);
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

function syncCursor(status) {
  if (!canvas) return;
  const value = browserCursorValues[status.cursor];
  if (!value) {
    throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(6)).error);
  }
  canvas.style.cursor = value;
}

function refreshStatus() {
  const status = JSON.parse(gpui.gpui_browser_status());
  syncCursor(status);
  elements.events.textContent = String(status.events ?? 0);
  elements.sequence.textContent = String(status.lastSequence ?? 0);
  elements.target.textContent = status.target == null ? "—" : `#${status.target}`;
  elements.focus.textContent = status.focus == null ? "—" : `#${status.focus}`;
  elements.activations.textContent = String(status.clicks ?? 0);
  elements.capabilityValue.textContent = String(status.capabilityValue ?? 0);
  elements.committedText.textContent = status.lastCommittedText || "No committed text yet.";
  elements.textCommitCount.textContent = String(status.textCommitCount ?? 0);
  elements.lastEvent.textContent = status.lastEvent || "Viewport ready";
}

function refreshInputOwner() {
  const owner = textInputBridge?.status().focused ? "text-input"
    : legacySurface?.contains(document.activeElement) ? "legacy-island" : "framework";
  elements.frame.dataset.inputOwner = owner;
  elements.hostInputOwner.textContent = owner === "text-input" ? "Committed text input"
    : owner === "legacy-island" ? "Legacy web island" : "gpui.mbt canvas";
}

function refreshTextInputState(state) {
  elements.textStart.disabled = !running || surfaceLost;
  elements.textStop.disabled = !state.active;
  elements.textState.textContent = !state.active ? "Text input is off."
    : state.composing ? "Composing — provisional text stays in the browser."
      : state.focused ? "Ready for committed text."
        : "Text input is paused. Start text input to focus it again.";
  refreshInputOwner();
}

function refreshClipboardControls() {
  const availability = clipboardService?.availability();
  elements.clipboardCopy.disabled = !running || clipboardBusy || !availability?.writeText;
  elements.clipboardPaste.disabled = !running || clipboardBusy || !availability?.readText;
}

function showClipboardError(error) {
  const code = error?.code || "native_failure";
  elements.clipboardResult.dataset.state = "error";
  elements.clipboardResult.dataset.code = code;
  elements.clipboardResult.textContent = `${code} · ${error?.message || "Clipboard request failed."}`;
}

async function requestClipboard(operation) {
  if (!running || !clipboardService || clipboardBusy) return;
  const service = clipboardService;
  const generation = hostGeneration;
  clipboardBusy = true;
  refreshClipboardControls();
  elements.clipboardResult.dataset.state = "pending";
  delete elements.clipboardResult.dataset.code;
  elements.clipboardResult.textContent = operation === "clipboard.read_text" ? "Reading clipboard…" : "Copying text…";
  try {
    // Dispatch in the original button callback: permission/user activation
    // belongs to the browser, and no async step may precede the native call.
    const response = await service.dispatch({
      version: 1,
      requestId: String(++clipboardRequestId),
      scopeId: "1",
      operation,
      input: operation === "clipboard.read_text" ? null : elements.clipboardValue.value,
    });
    if (!running || generation !== hostGeneration || service !== clipboardService || !response) return;
    if (!response.ok) {
      showClipboardError(response.error);
      return;
    }
    if (operation === "clipboard.read_text") elements.clipboardValue.value = response.value;
    elements.clipboardResult.dataset.state = "success";
    elements.clipboardResult.textContent = operation === "clipboard.read_text" ? "Text pasted." : "Text copied.";
  } catch (error) {
    if (running && generation === hostGeneration && service === clipboardService) showClipboardError(error);
  } finally {
    if (running && generation === hostGeneration && service === clipboardService) {
      clipboardBusy = false;
      refreshClipboardControls();
    }
  }
}

function createBrowserServices() {
  clipboardService = createBrowserClipboard({ allowedOperations: ["clipboard.read_text", "clipboard.write_text"] });
  clipboardService.openScope("1");
  clipboardRequestId = 0n;
  clipboardBusy = false;
  const availability = clipboardService.availability();
  gpuiCapabilities.clipboard = availability.readText && availability.writeText;
  delete elements.clipboardResult.dataset.code;
  delete elements.clipboardResult.dataset.state;
  elements.clipboardResult.textContent = availability.readText || availability.writeText
    ? "The browser may ask for clipboard permission."
    : "Clipboard text is unavailable in this browser context.";
  refreshClipboardControls();
  listen(elements.clipboardCopy, "click", () => { void requestClipboard("clipboard.write_text"); });
  listen(elements.clipboardPaste, "click", () => { void requestClipboard("clipboard.read_text"); });

  textInputBridge = createTextInputBridge({
    frame: elements.frame,
    canvas,
    onText: (text) => queueInput("gpui_browser_text_input", text),
    onFocusChange: (focused) => queueInput("gpui_browser_focus", focused),
    onStateChange: refreshTextInputState,
    onError: (error) => showDiagnostic(error?.diagnostic ? new FrameworkHostError(error.diagnostic) : error),
  });
  refreshTextInputState(textInputBridge.status());
  listen(elements.textStart, "click", () => { if (!surfaceLost) textInputBridge.start(); });
  listen(elements.textStop, "click", () => {
    textInputBridge.stop();
    if (!surfaceLost) canvas.focus({ preventScroll: true });
  });
}

function currentFocusedSemanticId() {
  const active = document.activeElement;
  if (active?.dataset?.semanticNode) return Number(active.dataset.semanticNode);
  const status = JSON.parse(gpui.gpui_browser_status());
  return status.focus == null ? null : Number(status.focus);
}

function navigateSemanticFocus(from, backwards) {
  if (!running || surfaceLost) return;
  const current = from ?? currentFocusedSemanticId();
  let target;
  if (current == null) target = backwards ? 7 : 4;
  else if (backwards) target = current <= 4 ? 7 : current - 1;
  else target = current >= 7 ? 4 : current + 1;
  const button = accessibilityButtons.get(target);
  if (!button) {
    queueInput("gpui_browser_key", "Tab", true, false, backwards, false, false, false);
    return;
  }
  call("gpui_browser_accessibility_focus", target, backwards);
  scheduleFrame();
  button.focus({ preventScroll: true });
}

function createAccessibilityLayer() {
  accessibilityLayer = document.createElement("div");
  accessibilityLayer.id = "gpui-accessibility-bridge";
  accessibilityLayer.className = "accessibility-bridge";
  accessibilityLayer.setAttribute("role", "group");
  accessibilityLayer.setAttribute("aria-label", "Canvas actions");
  elements.frame.appendChild(accessibilityLayer);
  listen(accessibilityLayer, "focusout", (event) => {
    if (legacySurface?.contains(event.relatedTarget)) {
      if (surfaceLost) {
        suspendedSemanticFocus = null;
        return;
      }
      queueInput("gpui_browser_key", "Escape", true, false, false, false, false, false);
    }
  });
}

function ensureAccessibilityButton(node) {
  const id = Number(node.id);
  let button = accessibilityButtons.get(id);
  if (button) return button;
  button = document.createElement("button");
  button.type = "button";
  button.className = "accessibility-proxy";
  button.id = `gpui-accessibility-node-${id}`;
  button.dataset.semanticNode = String(id);
  button.setAttribute("role", node.role);
  listen(button, "focus", () => {
    if (surfaceLost) {
      // Track native DOM focus transitions, not synthetic input notifications.
      if (document.activeElement === button) suspendedSemanticFocus = id;
      return;
    }
    queueInput("gpui_browser_accessibility_focus", id, false);
  });
  listen(button, "click", (event) => {
    event.preventDefault();
    queueInput("gpui_browser_accessibility_activate", id);
  });
  listen(button, "keydown", (event) => {
    if (event.key === "Tab") {
      event.preventDefault();
      navigateSemanticFocus(id, event.shiftKey);
      return;
    }
    if (event.key === "Enter" || event.key === " ") event.preventDefault();
    queueInput("gpui_browser_key", event.key, true, event.repeat, ...modifiers(event));
  });
  listen(button, "keyup", (event) => {
    if (event.key === "Enter" || event.key === " ") event.preventDefault();
    queueInput("gpui_browser_key", event.key, false, false, ...modifiers(event));
  });
  accessibilityLayer.appendChild(button);
  accessibilityButtons.set(id, button);
  return button;
}

function createLegacyIslandSurface() {
  legacyRequestedVisible = true;
  legacySurface = document.createElement("section");
  legacySurface.id = "legacy-island";
  legacySurface.className = "legacy-island";
  legacySurface.setAttribute("role", "group");
  legacySurface.setAttribute("aria-label", "Legacy web notes editor");

  const title = document.createElement("span");
  title.className = "legacy-island-title";
  title.textContent = "LEGACY WEB EDITOR";
  legacyEditor = document.createElement("textarea");
  legacyEditor.rows = 1;
  legacyEditor.value = "Notes remain in the existing web surface.";
  legacyEditor.setAttribute("aria-label", "Legacy note text");
  legacySave = document.createElement("button");
  legacySave.type = "button";
  legacySave.className = "legacy-island-save";
  legacySave.textContent = "Save";
  legacySave.setAttribute("aria-label", "Save legacy note");
  legacySurface.append(title, legacyEditor, legacySave);
  elements.frame.appendChild(legacySurface);
  legacyIsland = createLegacyIsland({
    frame: elements.frame,
    surface: legacySurface,
    canvas,
    onOwnerChange: refreshInputOwner,
  });
  listen(legacySave, "click", () => {
    elements.lastEvent.textContent = `legacy note saved (${legacyEditor.value.length} chars)`;
  });
  listen(elements.returnFramework, "click", () => legacyIsland?.returnToFramework());
}

function syncHostLayout() {
  if (!running) return;
  currentHostLayout = JSON.parse(gpui.gpui_browser_host_layout());
  const currentIds = new Set();
  for (const node of currentHostLayout.nodes || []) {
    const id = Number(node.id);
    currentIds.add(id);
    const button = ensureAccessibilityButton(node);
    const bounds = node.bounds;
    button.setAttribute("aria-label", node.name);
    button.setAttribute("aria-disabled", String(Boolean(node.disabled)));
    button.setAttribute("aria-current", String(Boolean(node.focused)));
    button.dataset.semanticValue = node.value == null ? "" : String(node.value);
    button.style.left = `${bounds.x}px`;
    button.style.top = `${bounds.y}px`;
    button.style.width = `${bounds.width}px`;
    button.style.height = `${bounds.height}px`;
  }
  for (const [id, button] of accessibilityButtons) {
    if (!currentIds.has(id)) {
      button.remove();
      accessibilityButtons.delete(id);
    }
  }
  const region = currentHostLayout.regions?.find((value) => value.id === 8);
  if (region && legacyIsland) {
    legacyIsland.sync(region.bounds, legacyRequestedVisible && !document.hidden);
  }
}

function renderFrame() {
  frameRequest = 0;
  if (!running || (surfaceLost && !restorationPending) || document.hidden) return;
  try {
    checkRenderer();
    syncViewport();
    if (restorationPending) {
      // Focus can move while restoration waits for this frame (or a hidden
      // page to become visible). Read lifecycle state just before the drain.
      const active = document.activeElement;
      const semanticFocused = Boolean(accessibilityLayer?.contains(active));
      const frameworkFocused = active === canvas || semanticFocused
        || Boolean(textInputBridge?.status().focused);
      call("gpui_browser_visibility", !document.hidden);
      // Canvas focus retains the last semantic lifecycle intent. Apply one
      // final target (or clear), not Escape followed by relative Tab traversal.
      const semanticTarget = semanticFocused ? Number(active.dataset.semanticNode) : suspendedSemanticFocus;
      if (semanticTarget === null) {
        call("gpui_browser_key", "Escape", true, false, false, false, false, false);
      } else if (semanticTarget !== undefined) {
        call("gpui_browser_accessibility_focus", semanticTarget, false);
      }
      call("gpui_browser_focus", frameworkFocused);
    }
    const snapshot = call("gpui_browser_render_frame");
    drawSnapshot(snapshot);
    checkRenderer();
    syncHostLayout();
    refreshStatus();
    rendererStats.completedFrames += 1;
    if (restorationPending) {
      restorationPending = false;
      surfaceLost = false;
      suspendedSemanticFocus = undefined;
      rendererStats.recoveries += 1;
      if (textInputBridge) refreshTextInputState(textInputBridge.status());
    }
    clearDiagnostic();
  } catch (error) {
    if (error instanceof FrameworkHostError && error.diagnostic.code === "surface_lost") {
      loseRenderer(error);
    } else {
      // Snapshot/conversion and ordinary callback errors are distinct from
      // context loss, including an error during the first restored frame.
      if (restorationPending) {
        restorationPending = false;
        context = null;
      }
      showDiagnostic(error);
    }
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
    if (dprQuery.removeEventListener) dprQuery.removeEventListener("change", dprListener);
    else dprQuery.removeListener(dprListener);
  }
  const query = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
  const generation = hostGeneration;
  dprQuery = query;
  dprListener = () => {
    if (running && generation === hostGeneration && dprQuery === query) onDprChange();
  };
  if (dprQuery.addEventListener) dprQuery.addEventListener("change", dprListener, { once: true });
  else dprQuery.addListener(dprListener);
}

function onDprChange() {
  if (!running) return;
  try {
    trackDpr();
    if (surfaceLost && !restorationPending) return;
    syncViewport();
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
  const pointerButton = (event, button, pressed) => {
    if (pressed) canvas.focus({ preventScroll: true });
    const bounds = canvas.getBoundingClientRect();
    queueInput("gpui_browser_pointer_button", event.clientX - bounds.left, event.clientY - bounds.top, button, pressed, ...modifiers(event));
  };
  listen(canvas, "pointerdown", (event) => {
    if (surfaceLost) return;
    if (event.button >= 0 && event.button <= 4) {
      const buttons = activePointerButtons.get(event.pointerId) || new Set();
      buttons.add(event.button);
      activePointerButtons.set(event.pointerId, buttons);
      pointerButton(event, event.button, true);
    }
    try { canvas.setPointerCapture(event.pointerId); } catch { /* Some synthetic events cannot be captured. */ }
  });
  listen(canvas, "pointerup", (event) => {
    if (surfaceLost) return;
    if (event.button < 0 || event.button > 4) return;
    const buttons = activePointerButtons.get(event.pointerId);
    buttons?.delete(event.button);
    if (buttons?.size === 0) activePointerButtons.delete(event.pointerId);
    pointerButton(event, event.button, false);
  });
  listen(canvas, "pointercancel", (event) => {
    const buttons = activePointerButtons.get(event.pointerId);
    activePointerButtons.delete(event.pointerId);
    if (!buttons) return;
    for (const button of buttons) pointerButton(event, button, false);
  });
  listen(canvas, "lostpointercapture", (event) => {
    const buttons = activePointerButtons.get(event.pointerId);
    activePointerButtons.delete(event.pointerId);
    if (!buttons) return;
    for (const button of buttons) pointerButton(event, button, false);
  });
  listen(canvas, "wheel", (event) => {
    event.preventDefault();
    const bounds = canvas.getBoundingClientRect();
    const unit = event.deltaMode === WheelEvent.DOM_DELTA_LINE
      ? 16
      : event.deltaMode === WheelEvent.DOM_DELTA_PAGE ? bounds.height : 1;
    queueInput(
      "gpui_browser_scroll",
      event.clientX - bounds.left,
      event.clientY - bounds.top,
      event.deltaX * unit,
      event.deltaY * unit,
      ...modifiers(event),
    );
  }, { passive: false });
  listen(canvas, "keydown", (event) => {
    if (event.key === "Tab" && accessibilityButtons.size > 0) {
      event.preventDefault();
      navigateSemanticFocus(null, event.shiftKey);
      return;
    }
    if (["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", " "].includes(event.key)) event.preventDefault();
    queueInput("gpui_browser_key", event.key, true, event.repeat, ...modifiers(event));
  });
  listen(canvas, "keyup", (event) => queueInput("gpui_browser_key", event.key, false, false, ...modifiers(event)));
  listen(canvas, "focus", () => queueInput("gpui_browser_focus", true));
  listen(canvas, "blur", () => queueInput("gpui_browser_focus", false));
  listen(canvas, "contextlost", () => {
    // Canvas 2D restores only when contextlost is NOT cancelled (HTML's
    // context lost steps). Cancelling this event would suppress restoration.
    if (surfaceLost && !restorationPending) return;
    loseRenderer(rendererError("The browser Canvas 2D context was lost; waiting for restoration."));
  });
  listen(canvas, "contextrestored", restoreRenderer);
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
  restorationPending = false;
  suspendedSemanticFocus = undefined;
  hostGeneration += 1;
  cancelFrame();
  if (resizeObserver) resizeObserver.disconnect();
  resizeObserver = null;
  if (dprQuery) {
    if (dprQuery.removeEventListener) dprQuery.removeEventListener("change", dprListener);
    else dprQuery.removeListener(dprListener);
  }
  dprQuery = null;
  dprListener = null;
  for (const remove of listeners.splice(0)) remove();
  clipboardService?.dispose();
  clipboardService = null;
  clipboardBusy = false;
  textInputBridge?.dispose();
  textInputBridge = null;
  refreshClipboardControls();
  legacyIsland?.dispose();
  legacyIsland = null;
  legacySurface = null;
  legacyEditor = null;
  legacySave = null;
  accessibilityLayer?.remove();
  accessibilityLayer = null;
  accessibilityButtons.clear();
  currentHostLayout = null;
  releasePointerCaptures();
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
  hostGeneration += 1;
  rendererStats = { completedFrames: 0, lossCount: 0, restoreAttempts: 0, recoveries: 0 };
  try {
    if (!elements.frame) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(0)).error);
    canvas = elements.frame.querySelector("#gpui-viewport");
    if (!canvas) resetCanvas();
    context = canvas.getContext("2d", { alpha: false, desynchronized: true });
    if (!context) throw new FrameworkHostError(JSON.parse(gpui.gpui_browser_host_error(1)).error);
    call("gpui_browser_start");
    adapterStarted = true;
    running = true;
    createAccessibilityLayer();
    createLegacyIslandSurface();
    attachCanvasEvents();
    createBrowserServices();
    call("gpui_browser_visibility", !document.hidden);
    listen(window, "resize", () => queueInput("gpui_browser_set_viewport", canvas.getBoundingClientRect().width, canvas.getBoundingClientRect().height, window.devicePixelRatio || 1));
    listen(document, "visibilitychange", () => {
      if (document.hidden) {
        cancelFrame();
        try { call("gpui_browser_visibility", false); } catch (error) { showDiagnostic(error); }
      } else {
        try {
          if (!surfaceLost || restorationPending) syncViewport();
          call("gpui_browser_visibility", true);
          scheduleFrame();
        } catch (error) { showDiagnostic(error); }
      }
    });
    const generation = hostGeneration;
    resizeObserver = new ResizeObserver(() => {
      if (!running || generation !== hostGeneration || (surfaceLost && !restorationPending)) return;
      try { syncViewport(); scheduleFrame(); } catch (error) { showDiagnostic(error); }
    });
    try {
      resizeObserver.observe(canvas, { box: "device-pixel-content-box" });
    } catch {
      resizeObserver.observe(canvas);
    }
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

window.__gpuiSmokeStatus = () => ({
  ...JSON.parse(gpui.gpui_browser_status()),
  renderer: {
    state: !running ? "stopped" : restorationPending ? "restoring" : surfaceLost ? "lost" : "ready",
    framePending: frameRequest !== 0,
    generation: hostGeneration,
    ...rendererStats,
  },
  hostInputOwner: elements.frame?.dataset.inputOwner || "framework",
  legacyVisible: legacySurface ? legacySurface.isConnected && !legacySurface.hidden : false,
  textInput: textInputBridge?.status() || { active: false, focused: false, composing: false, disposed: true },
  capabilities: { ...gpuiCapabilities },
});
window.__gpuiTextInput = (action) => {
  if (action === "status") return textInputBridge?.status();
  if (!running || surfaceLost || !textInputBridge) return null;
  switch (action) {
    case "start": return textInputBridge.start();
    case "stop": return textInputBridge.stop();
    case "blur": return textInputBridge.blur();
    case "focus": return textInputBridge.focus();
    default: throw new TypeError("Unknown text-input action.");
  }
};
window.__gpuiHostLayout = () => currentHostLayout;
window.__gpuiSetLegacyIslandVisible = (visible) => {
  const region = currentHostLayout?.regions?.find((value) => value.id === 8);
  legacyRequestedVisible = Boolean(visible);
  return region ? legacyIsland?.sync(region.bounds, legacyRequestedVisible && !document.hidden) : false;
};
window.__gpuiDirectCounter = (delta) => {
  const value = call("gpui_browser_direct_counter", delta);
  scheduleFrame();
  return value;
};
window.__gpuiMcpCounter = (delta) => {
  const value = call("gpui_browser_mcp_counter", delta);
  scheduleFrame();
  return value;
};
window.__gpuiReadCounter = () => call("gpui_browser_query_counter");
window.__gpuiDisposeLegacyIsland = () => legacyIsland?.dispose();

const gpuiCapabilities = JSON.parse(gpui.gpui_browser_capabilities());
elements.remount.addEventListener("click", () => start());
window.addEventListener("pagehide", stop);
window.addEventListener("pageshow", (event) => { if (event.persisted || !running) start(); });
start();
