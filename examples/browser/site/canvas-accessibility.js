// A dynamic button projection for the task-board canvas, not a general
// accessibility tree or a substitute for assistive-technology acceptance.
const navigationKeys = new Set([
  "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "Escape",
]);
const activationKeys = new Set(["Enter", " "]);

function validateNodes(nodes) {
  if (!Array.isArray(nodes)) throw new TypeError("Canvas accessibility nodes must be an array.");
  const ids = new Set();
  return nodes.map((node, index) => {
    const label = `Canvas accessibility node ${index}`;
    if (!node || typeof node !== "object" || Array.isArray(node)) {
      throw new TypeError(`${label} must be an object.`);
    }
    if (!Number.isSafeInteger(node.id) || node.id <= 0 || ids.has(node.id)) {
      throw new TypeError(`${label} requires a unique positive safe integer id.`);
    }
    ids.add(node.id);
    if (typeof node.name !== "string" || node.name.trim().length === 0) {
      throw new TypeError(`${label} requires a nonempty accessible name.`);
    }
    if (typeof node.selected !== "boolean" ||
        (node.disabled !== undefined && typeof node.disabled !== "boolean")) {
      throw new TypeError(`${label} requires boolean selected and optional disabled values.`);
    }
    if (!Number.isSafeInteger(node.lane) || node.lane < 0) {
      throw new TypeError(`${label} requires a nonnegative safe integer lane.`);
    }
    const bounds = node.bounds;
    if (!bounds || typeof bounds !== "object" || Array.isArray(bounds) ||
        ![bounds.x, bounds.y, bounds.width, bounds.height].every(Number.isFinite) ||
        bounds.width <= 0 || bounds.height <= 0 ||
        !Number.isFinite(bounds.x + bounds.width) || !Number.isFinite(bounds.y + bounds.height)) {
      throw new TypeError(`${label} requires finite bounds with positive width and height.`);
    }
    // Copy the allowlisted DTO fields; callers cannot mutate a live record and
    // no DTO value becomes HTML, a selector, a role, or an arbitrary CSS rule.
    return {
      id: node.id, name: node.name, selected: node.selected,
      disabled: node.disabled ?? false, lane: node.lane,
      bounds: { x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height },
    };
  });
}

export function createCanvasAccessibility({
  container,
  canvas,
  onFocus = () => {},
  onActivate = () => {},
  onKey = () => {},
}) {
  const document = container?.ownerDocument;
  if (!document || canvas?.ownerDocument !== document ||
      typeof document.createElement !== "function" ||
      typeof container.insertBefore !== "function" || typeof container.contains !== "function" ||
      typeof canvas.focus !== "function" ||
      ![onFocus, onActivate, onKey].every((callback) => typeof callback === "function")) {
    throw new TypeError("Canvas accessibility requires one document, a container, a canvas, and function callbacks.");
  }

  const records = new Map();
  let order = [];
  let enabled = true;
  let disposed = false;

  function canReceive(record) {
    return !disposed && enabled && !document.hidden && !record.node.disabled &&
      records.get(record.node.id) === record && container.contains(record.button);
  }

  function updateTabStops() {
    const available = enabled && !disposed
      ? order.map((id) => records.get(id)).filter((record) => record && !record.node.disabled)
      : [];
    const target = available.find((record) => record.button === document.activeElement) ??
      available.find((record) => record.node.selected) ?? available[0];
    for (const record of records.values()) record.button.tabIndex = record === target ? 0 : -1;
  }

  function createRecord(node) {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "canvas-accessibility-node";
    button.setAttribute("data-canvas-node-id", String(node.id));
    // Keep real buttons in the accessibility tree, at the matching canvas
    // bounds, without painting over the canvas or intercepting pointer input.
    Object.assign(button.style, {
      position: "absolute", margin: "0", padding: "0", border: "0",
      opacity: "0", overflow: "hidden", whiteSpace: "nowrap", pointerEvents: "none",
    });
    const record = { node, button, listeners: [], cancelSpaceRelease: false };
    const listen = (type, handler) => {
      button.addEventListener(type, handler);
      record.listeners.push(() => button.removeEventListener(type, handler));
    };
    listen("focus", () => {
      if (!canReceive(record) || document.activeElement !== button) return;
      updateTabStops();
      onFocus(record.node.id);
    });
    listen("blur", () => {
      record.cancelSpaceRelease = true;
      if (!disposed && records.get(record.node.id) === record) updateTabStops();
    });
    listen("click", (event) => {
      if (!canReceive(record)) return;
      event.preventDefault();
      event.stopPropagation();
      onActivate(record.node.id);
    });
    listen("keydown", (event) => {
      if (!canReceive(record) || document.activeElement !== button) {
        if (activationKeys.has(event.key)) {
          // With DOM focus retained, an unavailable Space press must not arm
          // a native click that would arrive after the renderer resumes.
          if (event.key === " ") record.cancelSpaceRelease = true;
          event.preventDefault();
          event.stopPropagation();
        }
        return;
      }
      if (event.isComposing || event.keyCode === 229) return;
      if (activationKeys.has(event.key) || event.key === "Tab") {
        // Native buttons own fresh Enter/Space activation and Tab traversal.
        // Only a Space repeat from a cancelled press loses its default action.
        if (event.key === " ") {
          if (!event.repeat) record.cancelSpaceRelease = false;
          else if (record.cancelSpaceRelease) event.preventDefault();
        }
        event.stopPropagation();
        return;
      }
      if (!navigationKeys.has(event.key)) return;
      event.preventDefault();
      event.stopPropagation();
      onKey({
        key: event.key, shift: Boolean(event.shiftKey), control: Boolean(event.ctrlKey),
        alt: Boolean(event.altKey), meta: Boolean(event.metaKey),
      });
    });
    listen("keyup", (event) => {
      if (!activationKeys.has(event.key)) return;
      if (!canReceive(record) || (event.key === " " && record.cancelSpaceRelease)) event.preventDefault();
      if (event.key === " ") record.cancelSpaceRelease = false;
      event.stopPropagation();
    });
    return record;
  }

  function updateRecord(record, node) {
    record.node = node;
    const button = record.button;
    button.textContent = node.name;
    button.setAttribute("aria-label", node.name);
    button.setAttribute("aria-pressed", String(node.selected));
    button.setAttribute("aria-disabled", String(!enabled || node.disabled));
    button.setAttribute("data-lane", String(node.lane));
    // Native disabled blurs a focused button. Suspension instead removes the
    // group's tab stops and gates callbacks, so resume can retain DOM focus.
    button.disabled = node.disabled;
    if (!enabled) record.cancelSpaceRelease = true;
    button.style.left = `${node.bounds.x}px`;
    button.style.top = `${node.bounds.y}px`;
    button.style.width = `${node.bounds.width}px`;
    button.style.height = `${node.bounds.height}px`;
  }

  function removeRecord(record) {
    records.delete(record.node.id);
    for (const removeListener of record.listeners) removeListener();
    record.listeners.length = 0;
    record.button.remove();
  }

  function returnRemovedFocus(button) {
    if (!button) return;
    const active = document.activeElement;
    // Removing a focused node normally leaves body focused. An application
    // listener may already have focused an input; do not override that choice.
    if (active === button || active == null || active === document.body || active === document.documentElement) {
      canvas.focus({ preventScroll: true });
    }
  }

  function sync(nodes) {
    if (disposed) return;
    // Reject an invalid complete snapshot before making any DOM changes.
    const next = validateNodes(nodes);
    const ids = new Set(next.map((node) => node.id));
    let removedFocus = null;
    for (const [id, record] of records) {
      if (!ids.has(id)) {
        if (document.activeElement === record.button) removedFocus = record.button;
        removeRecord(record);
      }
    }
    order = next.map((node) => node.id);
    for (const node of next) {
      let record = records.get(node.id);
      if (!record) {
        record = createRecord(node);
        records.set(node.id, record);
      }
      updateRecord(record, node);
    }
    // Reconcile reading order without ever detaching the focused button:
    // ordinary DOM moves can otherwise blur it even though its id survives.
    let following = null;
    for (let index = order.length - 1; index >= 0; index -= 1) {
      const button = records.get(order[index]).button;
      if (document.activeElement !== button &&
          (button.parentNode !== container || button.nextSibling !== following)) {
        container.insertBefore(button, following);
      }
      following = button;
    }
    updateTabStops();
    returnRemovedFocus(removedFocus);
  }

  function setEnabled(value) {
    if (disposed) return;
    if (typeof value !== "boolean") throw new TypeError("Canvas accessibility enabled must be a boolean.");
    enabled = value;
    for (const record of records.values()) updateRecord(record, record.node);
    updateTabStops();
  }

  function focus(id) {
    const record = records.get(id);
    if (!record || !canReceive(record)) return false;
    record.button.focus({ preventScroll: true });
    return !disposed && document.activeElement === record.button;
  }

  function dispose() {
    if (disposed) return;
    disposed = true;
    const focused = [...records.values()].find((record) => document.activeElement === record.button)?.button;
    for (const record of records.values()) removeRecord(record);
    order = [];
    returnRemovedFocus(focused);
  }

  return { sync, setEnabled, focus, dispose };
}
