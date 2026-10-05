import assert from "node:assert/strict";
import test from "node:test";
import { createCanvasAccessibility } from "../../examples/browser/site/canvas-accessibility.js";

// This small DOM double deliberately blurs moved/removed focused elements.
// nativeKey models button defaults; real-browser checks belong in smoke tests.
class Element extends EventTarget {
  constructor(document, tagName) {
    super();
    this.ownerDocument = document;
    this.tagName = tagName;
    this.style = {};
    this.attributes = new Map();
    this.children = [];
    this.parentNode = null;
    this.listeners = new Map();
    this.focusCalls = 0;
    this._disabled = false;
  }
  setAttribute(name, value) { this.attributes.set(name, String(value)); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  get nextSibling() {
    if (!this.parentNode) return null;
    return this.parentNode.children[this.parentNode.children.indexOf(this) + 1] ?? null;
  }
  get disabled() { return this._disabled; }
  set disabled(value) {
    this._disabled = value;
    if (value) this.blur();
  }
  get isConnected() {
    return this === this.ownerDocument.body || Boolean(this.parentNode?.isConnected);
  }
  addEventListener(type, handler, options) {
    super.addEventListener(type, handler, options);
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(handler);
  }
  removeEventListener(type, handler, options) {
    super.removeEventListener(type, handler, options);
    this.listeners.get(type)?.delete(handler);
  }
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  append(...nodes) { for (const node of nodes) this.insertBefore(node, null); }
  insertBefore(node, following) {
    if (following === node) return node;
    if (following !== null && following.parentNode !== this) throw new Error("Invalid insertion reference.");
    node.remove();
    const index = following === null ? this.children.length : this.children.indexOf(following);
    this.children.splice(index, 0, node);
    node.parentNode = this;
    return node;
  }
  remove() {
    if (!this.parentNode) return;
    if (this.contains(this.ownerDocument.activeElement)) this.ownerDocument.activeElement.blur();
    this.parentNode.children.splice(this.parentNode.children.indexOf(this), 1);
    this.parentNode = null;
  }
  focus(options) {
    this.focusCalls += 1;
    this.lastFocusOptions = options;
    if (this.disabled || !this.isConnected || this.ownerDocument.activeElement === this) return;
    this.ownerDocument.activeElement?.blur();
    this.ownerDocument.activeElement = this;
    this.dispatchEvent(new Event("focus"));
  }
  blur() {
    if (this.ownerDocument.activeElement !== this || this === this.ownerDocument.body) return;
    this.ownerDocument.activeElement = this.ownerDocument.body;
    this.dispatchEvent(new Event("blur"));
  }
}

function fixture() {
  const document = { hidden: false, created: 0 };
  document.createElement = (tagName) => {
    document.created += 1;
    return new Element(document, tagName);
  };
  document.body = document.createElement("body");
  document.activeElement = document.body;
  const container = document.createElement("div");
  const canvas = document.createElement("canvas");
  const other = document.createElement("input");
  document.body.append(canvas, container, other);
  const focused = [];
  const activated = [];
  const keys = [];
  const bridge = createCanvasAccessibility({
    container, canvas,
    onFocus: (id) => focused.push(id),
    onActivate: (id) => activated.push(id),
    onKey: (key) => keys.push(key),
  });
  const button = (id) => container.children.find((child) => child.getAttribute("data-canvas-node-id") === String(id));
  const event = (target, type, detail = {}) => {
    const value = new Event(type, { cancelable: true });
    for (const [key, data] of Object.entries(detail)) Object.defineProperty(value, key, { value: data });
    target.dispatchEvent(value);
    return value;
  };
  const nativeKey = (target, key, modifiers = {}) => {
    const down = event(target, "keydown", { key, ...modifiers });
    if (key === "Enter" && !down.defaultPrevented && !target.disabled) event(target, "click", { detail: 0 });
    const up = event(target, "keyup", { key, ...modifiers });
    if (key === " " && !down.defaultPrevented && !up.defaultPrevented && !target.disabled && document.activeElement === target) {
      event(target, "click", { detail: 0 });
    }
    return { down, up };
  };
  return { document, container, canvas, other, bridge, button, event, nativeKey, focused, activated, keys };
}

function node(id, values = {}) {
  return {
    id, name: `Task ${id}, Backlog`, selected: false, lane: 0,
    bounds: { x: 12, y: 24 + id * 40, width: 160, height: 36 },
    ...values,
  };
}

function tabStops(f) { return f.container.children.filter((button) => button.tabIndex === 0); }
function listenerCount(button) { return [...button.listeners.values()].reduce((sum, listeners) => sum + listeners.size, 0); }

test("stable ids preserve buttons, listeners, DOM focus, and reading order through updates", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true }), node(2), node(3)]);
  const [one, two, three] = [f.button(1), f.button(2), f.button(3)];
  two.focus();
  const created = f.document.created;
  const listeners = listenerCount(two);
  const changed = node(2, {
    name: "Review <draft> & release, In progress", selected: true, lane: 1,
    bounds: { x: -8, y: 10, width: 188.5, height: 42 },
  });
  f.bridge.sync([node(3), changed, node(1)]);
  assert.deepEqual(f.container.children, [three, two, one]);
  assert.equal(f.button(2), two);
  assert.equal(f.document.activeElement, two);
  assert.equal(f.document.created, created);
  assert.equal(listenerCount(two), listeners);
  assert.deepEqual(f.focused, [2]);
  assert.equal(two.getAttribute("aria-label"), changed.name);
  assert.equal(two.textContent, changed.name);
  assert.equal(two.getAttribute("aria-pressed"), "true");
  assert.equal(one.getAttribute("aria-pressed"), "false");
  assert.equal(two.getAttribute("data-lane"), "1");
  assert.equal(two.style.left, "-8px");
  assert.equal(two.style.width, "188.5px");
  assert.equal(two.style.opacity, "0");
  assert.equal(two.style.pointerEvents, "none");
  assert.equal(two.type, "button");
  assert.deepEqual(tabStops(f), [two]);
  // Snapshots remain independent of later caller-owned DTO mutations.
  changed.disabled = true;
  f.event(two, "click");
  assert.deepEqual(f.activated, [2]);
  f.bridge.dispose();
});

test("one roving stop prefers current focus, selected enabled node, then first enabled node", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true, disabled: true }), node(2), node(3, { selected: true })]);
  assert.deepEqual(tabStops(f), [f.button(3)]);
  f.button(2).focus();
  f.bridge.sync([node(1, { disabled: true }), node(2), node(3, { selected: true })]);
  assert.deepEqual(tabStops(f), [f.button(2)]);
  f.other.focus();
  assert.deepEqual(tabStops(f), [f.button(3)]);
  f.bridge.sync([node(1, { disabled: true }), node(2), node(3)]);
  assert.deepEqual(tabStops(f), [f.button(2)]);
  assert.equal(f.document.activeElement, f.other);
  f.bridge.sync([node(1, { disabled: true })]);
  assert.deepEqual(tabStops(f), []);
  f.bridge.dispose();
});

test("explicit focus follows a requested enabled id once and refuses absent or unavailable nodes", () => {
  const f = fixture();
  f.bridge.sync([node(1), node(2, { disabled: true })]);
  f.other.focus();
  assert.equal(f.bridge.focus(1), true);
  assert.equal(f.document.activeElement, f.button(1));
  assert.deepEqual(f.button(1).lastFocusOptions, { preventScroll: true });
  assert.equal(f.bridge.focus(1), true);
  assert.deepEqual(f.focused, [1]);
  for (const id of [2, 0, 99, "1", NaN, null]) assert.equal(f.bridge.focus(id), false);
  f.document.hidden = true;
  assert.equal(f.bridge.focus(1), false);
  f.document.hidden = false;
  f.bridge.setEnabled(false);
  assert.equal(f.bridge.focus(1), false);
  f.bridge.dispose();
  assert.equal(f.bridge.focus(1), false);
});

test("removing a focused visible node returns focus to the canvas and retires stale callbacks", () => {
  const f = fixture();
  f.bridge.sync([node(1), node(2, { selected: true })]);
  const removed = f.button(1);
  const oldClick = [...removed.listeners.get("click")][0];
  removed.focus();
  f.bridge.sync([node(2, { selected: true })]);
  assert.equal(f.document.activeElement, f.canvas);
  assert.equal(removed.parentNode, null);
  assert.equal(listenerCount(removed), 0);
  assert.deepEqual(tabStops(f), [f.button(2)]);
  f.event(removed, "click");
  oldClick(new Event("click", { cancelable: true }));
  f.bridge.sync([node(1), node(2, { selected: true })]);
  assert.notEqual(f.button(1), removed);
  oldClick(new Event("click", { cancelable: true }));
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.focused, [1]);
  f.bridge.dispose();
});

test("offscreen removals and selection changes never steal unrelated input focus", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true }), node(2), node(3)]);
  f.other.focus();
  f.bridge.sync([node(3, { selected: true }), node(4)]);
  assert.equal(f.document.activeElement, f.other);
  assert.equal(f.canvas.focusCalls, 0);
  assert.deepEqual(tabStops(f), [f.button(3)]);
  f.button(3).focus();
  f.bridge.sync([node(3)]);
  assert.equal(f.document.activeElement, f.button(3));
  assert.equal(f.canvas.focusCalls, 0);
  f.other.focus();
  f.bridge.sync([]);
  assert.equal(f.document.activeElement, f.other);
  f.bridge.dispose();
});

test("a removal listener that already moved focus to an input is respected", () => {
  const f = fixture();
  f.bridge.sync([node(1)]);
  const removed = f.button(1);
  removed.focus();
  removed.addEventListener("blur", () => f.other.focus());
  f.bridge.sync([]);
  assert.equal(f.document.activeElement, f.other);
  assert.equal(f.canvas.focusCalls, 0);
  f.bridge.dispose();
});

test("native click, Enter, and Space activate exactly once without a second key action", () => {
  const f = fixture();
  f.bridge.sync([node(1)]);
  const button = f.button(1);
  button.focus();
  assert.equal(f.event(button, "click").defaultPrevented, true);
  assert.deepEqual(f.activated, [1]);
  const enter = f.nativeKey(button, "Enter");
  assert.equal(enter.down.defaultPrevented, false);
  assert.deepEqual(f.activated, [1, 1]);
  const space = f.nativeKey(button, " ");
  assert.equal(space.up.defaultPrevented, false);
  assert.deepEqual(f.activated, [1, 1, 1]);
  assert.deepEqual(f.keys, []);
  // A dispatched key alone has no browser default in this double: the bridge
  // must not fabricate an extra activation ahead of the native click.
  f.event(button, "keydown", { key: "Enter" });
  f.event(button, "keyup", { key: "Enter" });
  assert.deepEqual(f.activated, [1, 1, 1]);
  f.bridge.dispose();
});

test("navigation forwards a single keydown with modifiers while Tab remains native", () => {
  const f = fixture();
  f.bridge.sync([node(1)]);
  const button = f.button(1);
  button.focus();
  for (const key of ["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Home", "End", "Escape"]) {
    const { down } = f.nativeKey(button, key, { altKey: true, shiftKey: true, ctrlKey: true, metaKey: true });
    assert.equal(down.defaultPrevented, true, key);
    assert.deepEqual(f.keys.at(-1), { key, shift: true, control: true, alt: true, meta: true });
  }
  assert.equal(f.keys.length, 7);
  for (const key of ["Tab", "a", "Delete"]) {
    const { down, up } = f.nativeKey(button, key);
    assert.equal(down.defaultPrevented, false, key);
    assert.equal(up.defaultPrevented, false, key);
  }
  f.event(button, "keydown", { key: "ArrowRight", isComposing: true });
  f.event(button, "keydown", { key: "ArrowLeft", keyCode: 229 });
  f.other.focus();
  f.event(button, "keydown", { key: "Home" });
  assert.equal(f.keys.length, 7);
  assert.deepEqual(f.activated, []);
  f.bridge.dispose();
});

test("disabled nodes and a suspended renderer reject admission and restore only eligible tab stops", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true }), node(2, { disabled: true })]);
  const one = f.button(1);
  const two = f.button(2);
  f.event(two, "click");
  f.event(two, "focus");
  f.event(two, "keydown", { key: "ArrowRight" });
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.focused, []);
  assert.deepEqual(f.keys, []);
  f.other.focus();
  f.bridge.setEnabled(false);
  for (const button of [one, two]) {
    assert.equal(button.getAttribute("aria-disabled"), "true");
    f.event(button, "click");
    f.event(button, "focus");
    f.event(button, "keydown", { key: "ArrowRight" });
  }
  assert.equal(one.disabled, false);
  assert.equal(two.disabled, true);
  assert.deepEqual(tabStops(f), []);
  f.bridge.sync([node(1, { selected: true }), node(2, { disabled: true }), node(3)]);
  assert.equal(f.button(3).disabled, false);
  assert.equal(f.button(3).getAttribute("aria-disabled"), "true");
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.focused, []);
  assert.deepEqual(f.keys, []);
  f.bridge.setEnabled(true);
  assert.equal(one.disabled, false);
  assert.equal(two.disabled, true);
  assert.equal(one.getAttribute("aria-disabled"), "false");
  assert.deepEqual(tabStops(f), [one]);
  assert.equal(f.document.activeElement, f.other);
  assert.throws(() => f.bridge.setEnabled("false"), /boolean/);
  assert.equal(one.disabled, false);
  f.bridge.dispose();
});

test("renderer suspension retains the focused proxy while gating activation and navigation", () => {
  const f = fixture();
  f.bridge.sync([node(1), node(2, { selected: true })]);
  const one = f.button(1);
  one.focus();
  f.document.hidden = true;
  f.bridge.setEnabled(false);
  f.bridge.sync([node(2, { selected: true }), node(1, { name: "Suspended task" })]);
  assert.equal(f.document.activeElement, one);
  assert.equal(one.disabled, false);
  assert.equal(one.getAttribute("aria-disabled"), "true");
  assert.deepEqual(tabStops(f), []);
  assert.equal(f.bridge.focus(2), false);
  f.nativeKey(one, "Enter");
  f.nativeKey(one, " ");
  f.nativeKey(one, "ArrowRight");
  f.event(one, "focus");
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.keys, []);
  assert.deepEqual(f.focused, [1]);
  // The bridge-wide gate also rejects events after the document is visible
  // but before the renderer has explicitly resumed.
  f.document.hidden = false;
  f.nativeKey(one, "Enter");
  f.nativeKey(one, "ArrowRight");
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.keys, []);
  f.bridge.setEnabled(true);
  assert.equal(f.document.activeElement, one);
  assert.deepEqual(tabStops(f), [one]);
  assert.equal(one.getAttribute("aria-disabled"), "false");
  assert.deepEqual(f.focused, [1]);
  f.nativeKey(one, "Enter");
  f.nativeKey(one, "ArrowRight");
  assert.deepEqual(f.activated, [1]);
  assert.deepEqual(f.keys, [{ key: "ArrowRight", shift: false, control: false, alt: false, meta: false }]);
  f.bridge.dispose();
});

test("resuming after focus moved to an external input never reclaims the old proxy focus", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true }), node(2)]);
  f.bridge.focus(1);
  f.bridge.setEnabled(false);
  f.other.focus();
  f.bridge.sync([node(1), node(2, { selected: true })]);
  assert.equal(f.document.activeElement, f.other);
  assert.deepEqual(tabStops(f), []);
  f.bridge.setEnabled(true);
  assert.equal(f.document.activeElement, f.other);
  assert.deepEqual(tabStops(f), [f.button(2)]);
  assert.deepEqual(f.focused, [1]);
  assert.equal(f.canvas.focusCalls, 0);
  f.bridge.dispose();
});

test("Space presses crossing suspension are cancelled without blocking the next deliberate press", () => {
  for (const startedBeforeSuspension of [false, true]) {
    const f = fixture();
    f.bridge.sync([node(1)]);
    const button = f.button(1);
    button.focus();
    if (!startedBeforeSuspension) f.bridge.setEnabled(false);
    const down = f.event(button, "keydown", { key: " " });
    if (startedBeforeSuspension) f.bridge.setEnabled(false);
    f.bridge.setEnabled(true);
    const repeat = f.event(button, "keydown", { key: " ", repeat: true });
    const up = f.event(button, "keyup", { key: " " });
    assert.equal(repeat.defaultPrevented, true);
    assert.equal(up.defaultPrevented, true);
    if (!down.defaultPrevented && !up.defaultPrevented) f.event(button, "click");
    assert.deepEqual(f.activated, []);
    assert.equal(f.document.activeElement, button);
    f.nativeKey(button, " ");
    assert.deepEqual(f.activated, [1]);
    f.bridge.dispose();
  }
});

test("disabling the focused node during a snapshot can admit new nodes without a transient invalid roving state", () => {
  const f = fixture();
  f.bridge.sync([node(1)]);
  f.button(1).focus();
  f.bridge.sync([node(1, { disabled: true }), node(2, { selected: true })]);
  assert.equal(f.button(1).disabled, true);
  assert.equal(f.button(2).disabled, false);
  assert.deepEqual(tabStops(f), [f.button(2)]);
  assert.equal(f.canvas.focusCalls, 0);
  f.bridge.dispose();
});

test("complete snapshot validation fails atomically on invalid DTOs, ids, and bounds", () => {
  const f = fixture();
  f.bridge.sync([node(1, { selected: true })]);
  const original = f.button(1);
  original.focus();
  const created = f.document.created;
  const invalid = [
    null, {}, [null], ["node"], [node(0)], [node(-1)], [node(1.5)], [node("1")],
    [node(Number.MAX_SAFE_INTEGER + 1)], [node(2), node(2)],
    [node(2, { name: null })], [node(2, { name: " \n " })],
    [node(2, { selected: 1 })], [node(2, { disabled: "false" })],
    [node(2, { lane: -1 })], [node(2, { lane: 0.5 })], [node(2, { lane: undefined })],
    [node(2, { bounds: null })], [node(2, { bounds: [] })],
    [node(2, { bounds: { x: 0, y: 0, width: 0, height: 1 } })],
    [node(2, { bounds: { x: 0, y: 0, width: 1, height: -1 } })],
    [node(2, { bounds: { x: Infinity, y: 0, width: 1, height: 1 } })],
    [node(2, { bounds: { x: 0, y: NaN, width: 1, height: 1 } })],
    [node(2, { bounds: { x: "0; color: red", y: 0, width: 1, height: 1 } })],
    [node(2, { bounds: { x: Number.MAX_VALUE, y: 0, width: Number.MAX_VALUE, height: 1 } })],
    [node(2), node(3, { selected: undefined })],
  ];
  for (const snapshot of invalid) {
    assert.throws(() => f.bridge.sync(snapshot), TypeError);
    assert.deepEqual(f.container.children, [original]);
    assert.equal(f.document.activeElement, original);
    assert.equal(f.document.created, created);
    assert.equal(original.getAttribute("aria-label"), "Task 1, Backlog");
  }
  assert.deepEqual(f.focused, [1]);
  f.bridge.dispose();
});

test("dispose removes only owned nodes and listeners and makes late calls inert", () => {
  const f = fixture();
  const unrelated = f.document.createElement("span");
  f.container.append(unrelated);
  f.bridge.sync([node(1)]);
  const button = f.button(1);
  const oldFocus = [...button.listeners.get("focus")][0];
  button.focus();
  f.bridge.dispose();
  assert.deepEqual(f.container.children, [unrelated]);
  assert.equal(f.document.activeElement, f.canvas);
  assert.equal(listenerCount(button), 0);
  const created = f.document.created;
  f.other.focus();
  f.bridge.dispose();
  f.bridge.sync([node(2)]);
  f.bridge.sync(null);
  f.bridge.setEnabled(true);
  f.event(button, "click");
  f.event(button, "keydown", { key: "ArrowDown" });
  oldFocus();
  assert.equal(f.bridge.focus(1), false);
  assert.equal(f.document.activeElement, f.other);
  assert.equal(f.document.created, created);
  assert.deepEqual(f.focused, [1]);
  assert.deepEqual(f.activated, []);
  assert.deepEqual(f.keys, []);
});

test("construction rejects mismatched documents or invalid callbacks", () => {
  const f = fixture();
  assert.throws(() => createCanvasAccessibility({ container: f.container, canvas: fixture().canvas }), TypeError);
  assert.throws(() => createCanvasAccessibility({ container: f.container, canvas: f.canvas, onKey: "run" }), TypeError);
  assert.throws(() => createCanvasAccessibility({ container: {}, canvas: f.canvas }), TypeError);
  f.bridge.dispose();
});
