import * as gpui from "mbt:f4ah6o/gpui/examples/browser_board";
import { drawSceneSnapshot } from "./canvas-renderer.js";
import { createCanvasAccessibility } from "./canvas-accessibility.js";
import { createBrowserClipboard } from "./clipboard.js";

const byId = (id) => document.getElementById(id);
const canvas = byId("board-canvas");
const frame = byId("board-frame");
const search = byId("board-search");
const dialog = byId("task-dialog");
const laneNames = ["Backlog", "In progress", "Done"];
const laneButtons = [...document.querySelectorAll("[data-lane]")];
const moveButtons = [...document.querySelectorAll("[data-move-lane]")];
let running = false;
let context = null;
let frameRequest = 0;
let width = 0;
let height = 0;
let scale = 0;
let lost = false;
let restoring = false;
let completedFrames = 0;
let activePointer = null;
let currentStatus = null;
let currentLayout = null;
let followKeyboardFocus = false;
let pendingAdd = null;
let searchComposing = false;
let lastSearchRequest = "";
let clipboardBusy = false;
let clipboardRequestId = 0n;
let lifecycleGeneration = 0;
let resizeObserver = null;
let dprQuery = null;
let removeDprListener = null;
let accessibility = null;
let clipboard = null;
const removers = [];

function call(name, ...args) {
  const response = JSON.parse(gpui[`gpui_board_${name}`](...args));
  if (!response?.ok) {
    const error = new Error(response?.error?.message || "The board rejected this operation.");
    Object.assign(error, response?.error || { code: "conversion_failed", operation: name });
    throw error;
  }
  return response.value;
}

function text(id, value) {
  const element = byId(id);
  const next = String(value);
  if (element.textContent !== next) element.textContent = next;
}

function listen(target, type, callback, options) {
  const listener = (event) => {
    if (running) callback(event);
  };
  target.addEventListener(type, listener, options);
  removers.push(() => target.removeEventListener(type, listener, options));
}

function controlsEnabled() {
  return running && !lost && !document.hidden;
}

function updateControls() {
  const enabled = controlsEnabled();
  byId("new-task").disabled = !enabled;
  byId("undo").disabled = !enabled || !currentStatus?.canUndo;
  byId("submit-task").disabled = !enabled || pendingAdd !== null;
  search.disabled = !enabled;
  byId("clear-search").disabled = !enabled;
  byId("move-controls").disabled = !enabled || currentStatus?.selectedId == null;
  const selected = currentStatus?.tasks.find((task) => task.id === currentStatus.selectedId);
  for (const button of moveButtons) {
    const sameLane = selected?.lane === Number(button.dataset.moveLane);
    button.disabled = !enabled || !selected || sameLane;
    button.setAttribute("aria-pressed", String(sameLane));
  }
  for (const button of laneButtons) button.disabled = !enabled;
  byId("copy-task").disabled =
    !enabled || !selected || clipboardBusy || !clipboard?.availability().writeText;
  const visibleLane = currentLayout?.lanes.find((lane) => lane.visible);
  byId("scroll-back").disabled = !enabled || !visibleLane || visibleLane.scrollY <= 0;
  byId("scroll-forward").disabled =
    !enabled || !visibleLane || visibleLane.scrollY >= visibleLane.maxScrollY;
  accessibility?.setEnabled(enabled);
}

function inputError(error) {
  text("board-message", error.message || "This action could not be completed.");
}

function cancelFrame() {
  if (frameRequest) cancelAnimationFrame(frameRequest);
  frameRequest = 0;
}

function scheduleFrame() {
  if (!running || document.hidden || (lost && !restoring) || frameRequest) return;
  const generation = lifecycleGeneration;
  frameRequest = requestAnimationFrame(() => {
    frameRequest = 0;
    if (running && generation === lifecycleGeneration) renderFrame();
  });
}

function syncViewport() {
  const bounds = canvas.getBoundingClientRect();
  const nextScale = window.devicePixelRatio || 1;
  if (
    ![bounds.width, bounds.height, nextScale].every(Number.isFinite) ||
    bounds.width < 1 ||
    bounds.height < 1
  ) {
    throw Object.assign(new Error("The browser reported an invalid canvas size."), {
      code: "invalid_input",
    });
  }
  if (width !== bounds.width || height !== bounds.height || scale !== nextScale) {
    // Queue resize ahead of input. Only a frame drains the portable application.
    call("set_viewport", bounds.width, bounds.height, nextScale);
    width = bounds.width;
    height = bounds.height;
    scale = nextScale;
  }
  const backingWidth = Math.round(width * scale);
  const backingHeight = Math.round(height * scale);
  if (canvas.width !== backingWidth) canvas.width = backingWidth;
  if (canvas.height !== backingHeight) canvas.height = backingHeight;
}

function enqueue(name, ...args) {
  if (!controlsEnabled()) return false;
  syncViewport();
  call(name, ...args);
  scheduleFrame();
  return true;
}

function command(kind, id = 0, value = "") {
  try {
    return enqueue("command", kind, id, value);
  } catch (error) {
    inputError(error);
    return false;
  }
}

function selectedTask() {
  return currentStatus?.tasks.find((task) => task.id === currentStatus.selectedId) || null;
}

function projectState(status, layout) {
  currentStatus = status;
  currentLayout = layout;
  const selected = selectedTask();
  const percent = status.total ? Math.round((100 * status.done) / status.total) : 0;
  text("sidebar-total", status.total);
  text("total-count", status.total);
  text("completed-count", status.done);
  text("progress-percent", `${percent}%`);
  byId("project-progress").max = Math.max(1, status.total);
  byId("project-progress").value = status.done;
  text("result-count", `${status.filteredIds.length} tasks`);
  text("detail-id", selected ? `TASK ${String(selected.id).padStart(2, "0")}` : "—");
  text("detail-heading", selected?.title || "Choose a task");
  text(
    "detail-description",
    selected?.detail || "Select any card to see its details and move it to the next stage.",
  );
  text("detail-priority", selected?.priority || "—");
  byId("detail-priority").dataset.priority = selected?.priority || "";
  text("detail-lane", selected ? laneNames[selected.lane] : "—");
  text("board-message", status.message);
  if (document.activeElement !== search && !searchComposing && search.value !== status.query) {
    search.value = status.query;
    lastSearchRequest = status.query;
  }
  byId("board-empty").hidden = status.filteredIds.length !== 0;
  byId("mobile-lanes").hidden = !layout.mobile;
  byId("mobile-scroll").hidden = !layout.mobile;
  // Single-column touch layouts use explicit move controls and permit native
  // vertical page scrolling; pointercancel retires the interrupted gesture.
  canvas.style.touchAction = layout.mobile ? "pan-y" : "none";
  text(
    "board-hint",
    layout.mobile
      ? "Tap a card. Move it with the controls below."
      : "Drag cards to move them. Scroll inside a column.",
  );
  for (const button of laneButtons) {
    const id = Number(button.dataset.lane);
    button.setAttribute("aria-pressed", String(status.activeLane === id));
    button.textContent = `${laneNames[id]} · ${layout.lanes.find((lane) => lane.id === id)?.count ?? 0}`;
  }
  canvas.style.cursor = status.dragging
    ? "grabbing"
    : status.cursor === "pointing-hand"
      ? "grab"
      : "default";
  accessibility.sync(layout.nodes);
  if (followKeyboardFocus) {
    followKeyboardFocus = false;
    if (frame.contains(document.activeElement) && status.selectedId != null)
      accessibility.focus(status.selectedId);
  }
  if (pendingAdd) {
    // render_frame drains the complete accepted queue. Settle a submission on
    // this frame even when the domain rejects it (for example the task cap).
    const added = status.total > pendingAdd.total;
    pendingAdd = null;
    if (added) {
      dialog.close();
      byId("task-title").value = "";
    } else {
      text("form-error", status.message || "The task could not be added.");
    }
  }
  text(
    "render-facts",
    `${Math.round(width)} × ${Math.round(height)} logical pixels · ${scale.toFixed(2)}× device scale · ${status.events} accepted events · ${completedFrames} frames`,
  );
  updateControls();
}

function canvasFocused() {
  return frame.contains(document.activeElement);
}

function renderFrame() {
  if (!running || document.hidden || (lost && !restoring)) return;
  try {
    if (!context || context.isContextLost?.())
      throw Object.assign(new Error("The canvas is waiting for its drawing surface."), {
        code: "surface_lost",
      });
    syncViewport();
    if (restoring) {
      call("focus", canvasFocused());
      call("visible", !document.hidden);
    }
    const snapshot = call("render_frame");
    drawSceneSnapshot(context, snapshot, { width, height, scale });
    completedFrames += 1;
    // Enable input only after the retained application has successfully painted.
    lost = false;
    restoring = false;
    byId("board-diagnostic").hidden = true;
    byId("status-dot").dataset.state = "ready";
    text("runtime-state", "All changes in this session");
    projectState(JSON.parse(gpui.gpui_board_status()), JSON.parse(gpui.gpui_board_host_layout()));
  } catch (error) {
    loseRenderer(error);
  }
}

function releasePointer() {
  const pointer = activePointer;
  activePointer = null;
  if (pointer !== null && canvas.hasPointerCapture(pointer)) canvas.releasePointerCapture(pointer);
}

function cancelGesture() {
  if (!running) return;
  try {
    call("cancel");
  } catch (error) {
    inputError(error);
  }
  releasePointer();
  scheduleFrame();
}

function loseRenderer(error) {
  cancelFrame();
  lost = true;
  restoring = false;
  context = null;
  cancelGesture();
  followKeyboardFocus = false;
  text("runtime-state", "Canvas unavailable");
  byId("status-dot").dataset.state = "error";
  byId("board-diagnostic").hidden = false;
  text(
    "diagnostic-message",
    error.message || "The browser could not draw the board. Its task state has been retained.",
  );
  text(
    "diagnostic-code",
    `${error.code || "surface_lost"} · ${error.operation || "BrowserBackend::present"}`,
  );
  updateControls();
}

function restoreRenderer() {
  if (!running || !lost || restoring) return;
  try {
    context = canvas.getContext("2d", { alpha: false });
    if (!context || context.isContextLost?.())
      throw Object.assign(
        new Error("The browser has not restored the canvas yet. Try again when it is available."),
        { code: "surface_lost" },
      );
    restoring = true;
    text("runtime-state", "Restoring canvas…");
    scheduleFrame();
  } catch (error) {
    loseRenderer(error);
  }
}

function point(event) {
  const bounds = canvas.getBoundingClientRect();
  return [event.clientX - bounds.left, event.clientY - bounds.top];
}

function safeInput(callback) {
  try {
    callback();
  } catch (error) {
    inputError(error);
    cancelGesture();
  }
}

function keyInput({ key, shift = false, control = false, alt = false, meta = false }) {
  if (!controlsEnabled()) return;
  if ((control || meta) && key.toLowerCase() === "z" && !shift) {
    command("undo");
    followKeyboardFocus = true;
  } else {
    safeInput(() => enqueue("key", key, shift, control, alt, meta));
  }
  if (
    ["ArrowUp", "ArrowDown", "Home", "End"].includes(key) ||
    (alt && ["ArrowLeft", "ArrowRight"].includes(key))
  )
    followKeyboardFocus = true;
  if (key === "Escape") releasePointer();
}

function searchInput() {
  if (searchComposing || search.value === lastSearchRequest) return;
  if (command("query", 0, search.value)) lastSearchRequest = search.value;
}

async function copyTask() {
  const task = selectedTask();
  if (!controlsEnabled() || !task || clipboardBusy || !clipboard?.availability().writeText) return;
  const service = clipboard;
  const generation = lifecycleGeneration;
  clipboardBusy = true;
  updateControls();
  text("clipboard-status", "Copying task…");
  try {
    // Dispatch within the click's user activation, before the first await.
    const result = await service.dispatch({
      version: 1,
      requestId: String(++clipboardRequestId),
      scopeId: "1",
      operation: "clipboard.write_text",
      input: `${task.title}\n${laneNames[task.lane]} · ${task.priority} priority\n${task.detail}`,
    });
    if (!running || generation !== lifecycleGeneration || service !== clipboard) return;
    text(
      "clipboard-status",
      result?.ok
        ? "Task summary copied."
        : `${result?.error?.code || "cancelled"} · The task could not be copied.`,
    );
  } catch (error) {
    if (running && generation === lifecycleGeneration)
      text("clipboard-status", `${error.code || "native_failure"} · ${error.message}`);
  } finally {
    if (running && generation === lifecycleGeneration) {
      clipboardBusy = false;
      updateControls();
    }
  }
}

function trackDpr() {
  removeDprListener?.();
  dprQuery = window.matchMedia(`(resolution: ${window.devicePixelRatio || 1}dppx)`);
  const changed = () => {
    if (running) {
      trackDpr();
      scheduleFrame();
    }
  };
  dprQuery.addEventListener("change", changed);
  removeDprListener = () => dprQuery?.removeEventListener("change", changed);
}

function attachEvents() {
  listen(canvas, "pointerdown", (event) => {
    if (
      !controlsEnabled() ||
      event.button !== 0 ||
      event.isPrimary === false ||
      activePointer !== null
    )
      return;
    event.preventDefault();
    safeInput(() => {
      canvas.focus({ preventScroll: true });
      if (enqueue("pointer_button", ...point(event), true)) {
        activePointer = event.pointerId;
        canvas.setPointerCapture(event.pointerId);
      }
    });
  });
  listen(canvas, "pointermove", (event) => {
    if (
      !controlsEnabled() ||
      event.isPrimary === false ||
      (activePointer !== null && activePointer !== event.pointerId)
    )
      return;
    safeInput(() => enqueue("pointer_move", ...point(event)));
  });
  listen(canvas, "pointerup", (event) => {
    if (activePointer !== event.pointerId || event.button !== 0) return;
    safeInput(() => {
      if (controlsEnabled()) enqueue("pointer_button", ...point(event), false);
      else call("cancel");
      releasePointer();
    });
  });
  listen(canvas, "pointercancel", (event) => {
    if (activePointer === event.pointerId) cancelGesture();
  });
  listen(canvas, "lostpointercapture", (event) => {
    if (activePointer === event.pointerId) cancelGesture();
  });
  listen(canvas, "pointerleave", () => {
    if (activePointer === null && controlsEnabled())
      safeInput(() => enqueue("pointer_move", -1, -1));
  });
  listen(
    canvas,
    "wheel",
    (event) => {
      if (!controlsEnabled() || event.ctrlKey) return;
      event.preventDefault();
      const unit = event.deltaMode === 1 ? 16 : event.deltaMode === 2 ? height : 1;
      safeInput(() => enqueue("scroll", ...point(event), event.deltaX * unit, event.deltaY * unit));
    },
    { passive: false },
  );
  listen(canvas, "keydown", (event) => {
    if (event.isComposing || event.key === "Tab") return;
    const handled =
      [
        "ArrowUp",
        "ArrowDown",
        "ArrowLeft",
        "ArrowRight",
        "Home",
        "End",
        "Escape",
        "Enter",
        " ",
      ].includes(event.key) ||
      ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "z");
    if (!handled) return;
    event.preventDefault();
    keyInput({
      key: event.key,
      shift: event.shiftKey,
      control: event.ctrlKey,
      alt: event.altKey,
      meta: event.metaKey,
    });
  });
  listen(frame, "keydown", (event) => {
    if (
      event.defaultPrevented ||
      event.isComposing ||
      !(event.ctrlKey || event.metaKey) ||
      event.shiftKey ||
      event.key.toLowerCase() !== "z"
    )
      return;
    if (event.target !== canvas && !event.target.matches("[data-canvas-node-id]")) return;
    event.preventDefault();
    keyInput({ key: event.key, control: event.ctrlKey, meta: event.metaKey });
  });
  listen(frame, "focusin", () => {
    if (controlsEnabled()) safeInput(() => enqueue("focus", true));
  });
  listen(frame, "focusout", () => {
    const generation = lifecycleGeneration;
    queueMicrotask(() => {
      if (!running || generation !== lifecycleGeneration || canvasFocused()) return;
      safeInput(() => {
        call("focus", false);
        cancelGesture();
      });
      followKeyboardFocus = false;
    });
  });
  listen(window, "blur", () => {
    safeInput(() => call("focus", false));
    cancelGesture();
  });
  listen(window, "focus", () => {
    if (controlsEnabled()) safeInput(() => enqueue("focus", canvasFocused()));
  });
  listen(document, "visibilitychange", () => {
    safeInput(() => call("visible", !document.hidden));
    if (document.hidden) {
      cancelFrame();
      cancelGesture();
      followKeyboardFocus = false;
    } else scheduleFrame();
    updateControls();
  });
  // Canvas 2D restoration requires leaving contextlost uncancelled.
  listen(canvas, "contextlost", () =>
    loseRenderer(
      Object.assign(
        new Error(
          "The canvas surface was lost. Your tasks are retained while the browser restores it.",
        ),
        { code: "surface_lost" },
      ),
    ),
  );
  listen(canvas, "contextrestored", restoreRenderer);
  listen(byId("retry-renderer"), "click", restoreRenderer);
  listen(window, "resize", scheduleFrame);
  listen(search, "compositionstart", () => {
    searchComposing = true;
  });
  listen(search, "compositionend", () => {
    searchComposing = false;
    searchInput();
  });
  listen(search, "input", (event) => {
    if (!event.isComposing) searchInput();
  });
  listen(byId("clear-search"), "click", () => {
    search.value = "";
    searchInput();
    search.focus();
  });
  listen(byId("undo"), "click", () => command("undo"));
  for (const button of laneButtons)
    listen(button, "click", () => command("lane", Number(button.dataset.lane)));
  for (const button of moveButtons)
    listen(button, "click", () => {
      const task = selectedTask();
      if (task) command("move", task.id, button.dataset.moveLane);
    });
  for (const [id, direction] of [
    ["scroll-back", -1],
    ["scroll-forward", 1],
  ]) {
    listen(byId(id), "click", () => {
      const lane = currentLayout?.lanes.find((item) => item.visible);
      if (lane)
        safeInput(() =>
          enqueue(
            "scroll",
            lane.bounds.x + lane.bounds.width / 2,
            lane.bounds.y + lane.bounds.height / 2,
            0,
            direction * Math.max(80, lane.bounds.height - 60),
          ),
        );
    });
  }
  listen(byId("copy-task"), "click", () => {
    void copyTask();
  });
  listen(byId("new-task"), "click", () => {
    if (!controlsEnabled()) return;
    cancelGesture();
    text("form-error", "");
    dialog.showModal();
    byId("task-title").focus();
  });
  listen(byId("cancel-task"), "click", () => dialog.close());
  listen(byId("new-task-form"), "submit", (event) => {
    event.preventDefault();
    if (!controlsEnabled() || pendingAdd) return;
    try {
      if (enqueue("command", "add", 0, byId("task-title").value))
        pendingAdd = { total: currentStatus.total };
      updateControls();
    } catch (error) {
      text("form-error", error.message);
    }
  });
  listen(window, "pagehide", (event) => {
    if (event.persisted) {
      cancelFrame();
      cancelGesture();
    } else stop();
  });
  listen(window, "pageshow", (event) => {
    if (event.persisted) {
      safeInput(() => call("visible", !document.hidden));
      scheduleFrame();
    }
  });
}

function stop() {
  if (!running) return;
  running = false;
  lifecycleGeneration += 1;
  cancelFrame();
  releasePointer();
  resizeObserver?.disconnect();
  removeDprListener?.();
  for (const remove of removers.splice(0)) remove();
  accessibility?.dispose();
  clipboard?.dispose();
  clipboard = null;
  call("dispose");
  context = null;
}

function start() {
  try {
    call("start");
    running = true;
    context = canvas.getContext("2d", { alpha: false });
    accessibility = createCanvasAccessibility({
      container: byId("board-accessibility"),
      canvas,
      onFocus: (id) => command("select", id),
      onActivate: (id) => command("select", id),
      onKey: keyInput,
    });
    clipboard = createBrowserClipboard({ allowedOperations: ["clipboard.write_text"] });
    clipboard.openScope("1");
    attachEvents();
    trackDpr();
    resizeObserver = new ResizeObserver(scheduleFrame);
    resizeObserver.observe(canvas);
    call("visible", !document.hidden);
    call("focus", canvasFocused());
    scheduleFrame();
  } catch (error) {
    loseRenderer(error);
  }
}

// Read-only observations for production-artifact browser verification.
window.__gpuiBoardStatus = () => JSON.parse(gpui.gpui_board_status());
window.__gpuiBoardLayout = () => JSON.parse(gpui.gpui_board_host_layout());
window.__gpuiBoardHost = () => ({
  running,
  lost,
  restoring,
  completedFrames,
  width,
  height,
  scale,
  activePointer,
  pendingFrame: frameRequest !== 0,
});
start();
