import assert from "node:assert/strict";
import test from "node:test";
import { createTextInputBridge, MAX_COMMITTED_TEXT_CODE_UNITS } from "../../examples/browser/site/text-input.js";

// The DOM double exercises event ordering and lifecycle deterministically.
// tests/browser/text-input.mjs separately uses real Chromium input and CDP IME.
class Element extends EventTarget {
  constructor(document) {
    super();
    this.ownerDocument = document;
    this.style = {};
    this.value = "";
    this.attributes = new Map();
    this.disabled = false;
  }
  setAttribute(name, value) { this.attributes.set(name, value); }
  append(element) { element.parent = this; this.child = element; }
  remove() { if (this.parent?.child === this) this.parent.child = null; }
  focus() {
    if (this.disabled || this.ownerDocument.activeElement === this) return;
    this.ownerDocument.activeElement?.blur();
    this.ownerDocument.activeElement = this;
    this.dispatchEvent(new Event("focus"));
  }
  blur() {
    if (this.ownerDocument.activeElement !== this) return;
    this.ownerDocument.activeElement = null;
    this.dispatchEvent(new Event("blur"));
  }
}

function fixture() {
  const document = new EventTarget();
  document.hidden = false;
  document.activeElement = null;
  document.defaultView = new EventTarget();
  document.createElement = () => new Element(document);
  const frame = new Element(document);
  const canvas = new Element(document);
  const other = new Element(document);
  const commits = [];
  const errors = [];
  const focusChanges = [];
  const bridge = createTextInputBridge({
    frame, canvas,
    onText: (text) => commits.push(text),
    onFocusChange: (focused) => focusChanges.push(focused),
    onError: (error) => errors.push(error),
  });
  const textarea = frame.child;
  const event = (type, detail = {}, target = textarea) => {
    const value = new Event(type, { cancelable: true });
    for (const [key, data] of Object.entries(detail)) Object.defineProperty(value, key, { value: data });
    target.dispatchEvent(value);
    return value;
  };
  const input = (text, inputType = "insertText", isComposing = false) => {
    event("beforeinput", { data: text, inputType, isComposing });
    textarea.value = text ?? "";
    event("input", { data: text, inputType, isComposing });
  };
  const composition = (text) => {
    event("compositionstart", { data: "" });
    event("compositionupdate", { data: text });
    input(text, "insertCompositionText", true);
  };
  return { document, frame, canvas, other, textarea, commits, errors, focusChanges, bridge, event, input, composition };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test("text input is opt-in and never takes focus from the canvas or legacy controls", () => {
  const f = fixture();
  f.canvas.focus();
  assert.deepEqual(f.bridge.status(), { active: false, focused: false, composing: false, disposed: false });
  f.bridge.focus();
  f.input("inactive");
  assert.equal(f.document.activeElement, f.canvas);
  assert.deepEqual(f.commits, []);
  f.bridge.start();
  assert.equal(f.document.activeElement, f.textarea);
  assert.equal(f.bridge.status().focused, true);
  f.other.focus();
  assert.equal(f.bridge.status().focused, false);
  assert.equal(f.bridge.status().active, true);
  f.bridge.stop();
  assert.equal(f.document.activeElement, f.other);
  assert.deepEqual(f.focusChanges, [true, false]);
  f.bridge.dispose();
});

test("only insert events commit exact Unicode text; keydown never synthesizes text", () => {
  const f = fixture();
  f.bridge.start();
  f.event("keydown", { key: "a", isComposing: false });
  assert.deepEqual(f.commits, []);
  for (const text of ["Latin", "日本語", "👩🏽‍💻", "e\u0301", "שלום العربية", "\u0000\b\f\u001f"]) {
    const before = f.commits.length;
    f.event("beforeinput", { data: text, inputType: "insertText", isComposing: false });
    assert.equal(f.commits.length, before);
    f.textarea.value = text;
    f.event("input", { data: text, inputType: "insertText", isComposing: false });
    assert.equal(f.commits.at(-1), text);
    assert.equal(f.textarea.value, "");
  }
  assert.equal(f.commits.length, 6);
  for (const type of ["deleteContentBackward", "historyUndo", "insertReplacementText"]) f.input("not an insert", type);
  assert.equal(f.commits.length, 6);
  f.bridge.dispose();
});

test("composition final input before compositionend commits once", async () => {
  const f = fixture();
  f.bridge.start();
  f.composition("にほん");
  f.event("compositionupdate", { data: "日本語" });
  f.input("日本語", "insertCompositionText", true);
  assert.deepEqual(f.commits, []);
  f.event("compositionend", { data: "日本語" });
  assert.deepEqual(f.commits, []);
  await settle();
  assert.deepEqual(f.commits, ["日本語"]);
  assert.equal(f.textarea.value, "");
  assert.equal(f.bridge.status().composing, false);
  f.bridge.dispose();
});

test("compositionend followed by trailing beforeinput/input commits once in common orders", async () => {
  for (const type of ["insertText", "insertFromComposition", "insertCompositionText"]) {
    const f = fixture();
    f.bridge.start();
    f.composition("かんじ");
    f.event("compositionend", { data: "漢字" });
    // A browser can checkpoint microtasks between native event dispatches.
    await Promise.resolve();
    f.input("漢字", type, false);
    await settle();
    assert.deepEqual(f.commits, ["漢字"], type);
    // A later, identical ordinary insert is a separate commit.
    f.input("漢字");
    assert.deepEqual(f.commits, ["漢字", "漢字"], type);
    f.bridge.dispose();
  }
});

test("cancelled composition drops provisional and trailing insert values", async () => {
  const f = fixture();
  f.bridge.start();
  f.composition("discard me");
  f.event("compositionend", { data: "" });
  f.input("discard me", "insertText", false);
  await settle();
  assert.deepEqual(f.commits, []);
  assert.equal(f.textarea.value, "");
  f.input("next");
  assert.deepEqual(f.commits, ["next"]);
  f.bridge.dispose();
});

test("blur hidden stop and dispose cancel even a pending compositionend commit", async () => {
  for (const lifecycle of ["blur", "hidden", "window-blur", "stop", "dispose"]) {
    const f = fixture();
    f.bridge.start();
    f.composition("provisional");
    f.event("compositionend", { data: "must be discarded" });
    await Promise.resolve();
    if (lifecycle === "hidden") {
      f.document.hidden = true;
      f.document.dispatchEvent(new Event("visibilitychange"));
    } else if (lifecycle === "window-blur") {
      f.document.defaultView.dispatchEvent(new Event("blur"));
    } else f.bridge[lifecycle]();
    await settle();
    f.event("compositionend", { data: "late composition" });
    f.input("late input");
    assert.deepEqual(f.commits, [], lifecycle);
    assert.equal(f.bridge.status().focused, false, lifecycle);
    assert.equal(f.bridge.status().composing, false, lifecycle);
    if (lifecycle !== "dispose") {
      f.document.hidden = false;
      f.bridge.start();
      f.input("new focus session");
      assert.deepEqual(f.commits, ["new focus session"], lifecycle);
    }
    f.bridge.dispose();
    f.bridge.dispose();
    assert.equal(f.frame.child, null);
    assert.equal(f.bridge.start().disposed, true);
  }
});

test("an explicit outside pointer cancels composition without taking the new focus", async () => {
  const f = fixture();
  f.bridge.start();
  f.composition("cancel on click");
  f.event("pointerdown", { target: f.other }, f.document);
  f.event("compositionend", { data: "must not commit" });
  f.other.focus();
  await settle();
  assert.deepEqual(f.commits, []);
  assert.equal(f.document.activeElement, f.other);
  f.bridge.dispose();
});

test("paste without input.data preserves captured plain text, and line breaks insert newline", () => {
  const f = fixture();
  f.bridge.start();
  const pasted = "paste\r\n日本語";
  f.event("paste", { clipboardData: { getData: () => pasted } });
  f.event("beforeinput", { data: null, inputType: "insertFromPaste", isComposing: false });
  f.textarea.value = "paste\n日本語";
  f.event("input", { data: null, inputType: "insertFromPaste", isComposing: false });
  f.input(null, "insertLineBreak");
  assert.deepEqual(f.commits, [pasted, "\n"]);
  f.bridge.dispose();
});

test("empty and oversized inserts never enqueue a truncated commit", () => {
  const f = fixture();
  f.bridge.start();
  f.input("");
  const boundary = "😀".repeat(MAX_COMMITTED_TEXT_CODE_UNITS / 2);
  f.input(`${boundary}x`);
  assert.deepEqual(f.commits, []);
  assert.equal(f.errors.length, 1);
  assert.equal(f.errors[0].diagnostic.code, "invalid_input");
  f.input(boundary);
  assert.deepEqual(f.commits, [boundary]);
  f.bridge.dispose();
});
