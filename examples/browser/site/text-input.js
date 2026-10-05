// This opt-in textarea transports committed inserts into the portable input
// queue. It is not a document, selection model, text renderer, or full IME API.
export const MAX_COMMITTED_TEXT_CODE_UNITS = 65_536;

const insertionTypes = new Set([
  "insertText", "insertFromPaste", "insertFromDrop", "insertLineBreak", "insertParagraph",
]);
const compositionTypes = new Set(["insertCompositionText", "insertFromComposition", "deleteCompositionText"]);

export function createTextInputBridge({
  frame,
  canvas,
  onText,
  onFocusChange = () => {},
  onStateChange = () => {},
  onError = () => {},
}) {
  const document = frame?.ownerDocument;
  if (!document || canvas?.ownerDocument !== document || typeof onText !== "function") {
    throw new TypeError("The text input bridge requires one document, frame, canvas, and text callback.");
  }
  const textarea = document.createElement("textarea");
  textarea.id = "gpui-text-input";
  textarea.setAttribute("aria-label", "Committed text input bridge");
  textarea.setAttribute("autocomplete", "off");
  textarea.setAttribute("autocapitalize", "off");
  textarea.setAttribute("autocorrect", "off");
  textarea.setAttribute("inputmode", "text");
  textarea.setAttribute("dir", "auto");
  textarea.spellcheck = false;
  textarea.tabIndex = -1;
  textarea.disabled = true;
  // display:none / hidden would prevent a real browser composition session.
  // Keep a focusable native input without covering the canvas or legacy island.
  Object.assign(textarea.style, {
    position: "absolute", left: "0", top: "0", width: "1px", height: "1px",
    margin: "0", padding: "0", border: "0", opacity: "0", overflow: "hidden",
    pointerEvents: "none", fontSize: "16px",
  });
  frame.append(textarea);

  let active = false;
  let focused = false;
  let composing = false;
  let disposed = false;
  let generation = 0;
  let pendingComposition = null;
  let compositionTimer = null;
  let compositionTail = null;
  let pendingInput = null;
  let transferText = null;
  const listeners = [];
  const status = () => Object.freeze({ active, focused, composing, disposed });
  const notify = () => onStateChange(status());
  const canReceive = () => active && focused && !disposed && !document.hidden && document.activeElement === textarea;

  function listen(target, type, handler, options) {
    if (!target?.addEventListener) return;
    target.addEventListener(type, handler, options);
    listeners.push(() => target.removeEventListener(type, handler, options));
  }

  function setFocused(value) {
    if (focused === value) return;
    focused = value;
    onFocusChange(value);
    notify();
  }

  function discard() {
    generation += 1;
    if (compositionTimer !== null) clearTimeout(compositionTimer);
    compositionTimer = null;
    composing = false;
    pendingComposition = null;
    compositionTail = null;
    pendingInput = null;
    transferText = null;
    textarea.value = "";
  }

  function commit(text) {
    if (!canReceive() || typeof text !== "string" || text.length === 0) return;
    if (text.length > MAX_COMMITTED_TEXT_CODE_UNITS) {
      const error = new RangeError("A committed insert exceeds 65536 UTF-16 code units.");
      error.diagnostic = {
        code: "invalid_input", operation: "BrowserBackend::text_input",
        subsystem: "browser", backend: "js/canvas-2d", message: error.message,
      };
      onError(error);
      return;
    }
    try {
      onText(text);
    } catch (error) {
      onError(error);
    }
  }

  function flushComposition() {
    if (compositionTimer !== null) clearTimeout(compositionTimer);
    compositionTimer = null;
    const pending = pendingComposition;
    pendingComposition = null;
    if (pending?.generation === generation) commit(pending.text);
  }

  function isCompositionTail(event) {
    if (!compositionTail) return false;
    return compositionTypes.has(event.inputType) ||
      (insertionTypes.has(event.inputType) &&
        (compositionTail.text === "" || event.data === compositionTail.text));
  }

  listen(textarea, "focus", () => {
    if (!active || disposed || document.hidden) {
      textarea.blur();
      return;
    }
    setFocused(true);
  });
  listen(textarea, "blur", () => {
    discard();
    setFocused(false);
    notify();
  });
  listen(textarea, "compositionstart", () => {
    if (!canReceive()) return;
    flushComposition();
    compositionTail = null;
    pendingInput = null;
    transferText = null;
    composing = true;
    notify();
  });
  listen(textarea, "compositionupdate", () => {
    // Provisional values stay in the browser-owned textarea; no model update.
    if (!canReceive() || !composing) textarea.value = "";
  });
  listen(textarea, "compositionend", (event) => {
    if (!canReceive() || !composing) {
      textarea.value = "";
      return;
    }
    composing = false;
    pendingInput = null;
    const pending = { text: typeof event.data === "string" ? event.data : "", generation };
    pendingComposition = pending;
    compositionTail = pending;
    // Some engines emit the final input before compositionend, others after.
    // Settle in the next task: native event listeners can have intervening
    // microtask checkpoints. This also lets the rest of a native blur/hidden
    // transition cancel provisional text before it enters the app queue.
    compositionTimer = setTimeout(() => {
      compositionTimer = null;
      if (pendingComposition === pending) flushComposition();
      if (compositionTail === pending) compositionTail = null;
      if (generation === pending.generation && !composing) textarea.value = "";
    }, 0);
    notify();
  });
  listen(textarea, "keydown", (event) => {
    // A new physical key is a transaction boundary, never a source of text.
    if (!event.isComposing && event.keyCode !== 229 && !composing) {
      flushComposition();
      compositionTail = null;
      pendingInput = null;
      transferText = null;
    }
  });
  listen(textarea, "paste", (event) => {
    if (canReceive() && !composing) transferText = event.clipboardData?.getData("text/plain") ?? null;
  });
  listen(textarea, "beforeinput", (event) => {
    if (!canReceive()) {
      if (event.cancelable) event.preventDefault();
      return;
    }
    if (composing || event.isComposing) return;
    if (isCompositionTail(event)) {
      if (event.cancelable) event.preventDefault();
      return;
    }
    if (!insertionTypes.has(event.inputType)) {
      // Deletion, undo, and replacement require an editor model we do not have.
      if (event.cancelable) event.preventDefault();
      pendingInput = null;
      transferText = null;
      return;
    }
    pendingInput = {
      type: event.inputType,
      data: event.inputType === "insertFromPaste" && transferText !== null
        ? transferText
        : typeof event.data === "string" ? event.data : null,
    };
    transferText = null;
  });
  listen(textarea, "input", (event) => {
    if (!canReceive()) {
      textarea.value = "";
      return;
    }
    if (composing) return;
    if (event.isComposing || isCompositionTail(event) || compositionTypes.has(event.inputType)) {
      textarea.value = "";
      pendingInput = null;
      return;
    }
    flushComposition();
    compositionTail = null;
    if (insertionTypes.has(event.inputType)) {
      const previous = pendingInput?.type === event.inputType ? pendingInput.data : null;
      const text = previous ?? (typeof event.data === "string" ? event.data
        : ["insertLineBreak", "insertParagraph"].includes(event.inputType) ? "\n" : textarea.value);
      commit(text);
    }
    pendingInput = null;
    transferText = null;
    textarea.value = "";
  });

  function blur() {
    discard();
    textarea.blur();
    setFocused(false);
    notify();
    return status();
  }

  listen(document, "visibilitychange", () => { if (document.hidden) blur(); });
  listen(document.defaultView, "blur", blur);
  listen(document, "pointerdown", (event) => {
    if (focused && event.target !== textarea && (composing || pendingComposition)) {
      discard();
      notify();
    }
  }, true);

  function focus() {
    if (active && !disposed && !document.hidden) textarea.focus({ preventScroll: true });
    return status();
  }

  function start() {
    if (disposed) return status();
    active = true;
    textarea.disabled = false;
    notify();
    return focus();
  }

  function stop() {
    active = false;
    blur();
    textarea.disabled = true;
    notify();
    return status();
  }

  function dispose() {
    if (disposed) return status();
    disposed = true;
    stop();
    for (const removeListener of listeners) removeListener();
    textarea.remove();
    return status();
  }

  return Object.freeze({ start, stop, focus, blur, dispose, status });
}
