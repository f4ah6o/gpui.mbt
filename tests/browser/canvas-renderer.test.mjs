import assert from "node:assert/strict";
import test from "node:test";
import { CanvasSceneError, drawSceneSnapshot } from "../../examples/browser/site/canvas-renderer.js";

const viewport = { x: 0, y: 0, width: 320, height: 180 };
const dimensions = { width: 320, height: 180, scale: 2 };
const identity = { a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0 };
const ink = { red: 12, green: 34, blue: 56, alpha: 128 };
const quad = (id, extra = {}) => ({
  kind: "quad", id, bounds: { x: 10, y: 20, width: 80, height: 24 },
  color: ink, transform: identity, opacity: 1, clip_chain_id: null, ...extra,
});
const text = (id, extra = {}) => ({
  ...quad(id), kind: "text", text: "Review 日本語 😀", font_size: 16, ...extra,
});
const scene = (items, extra = {}) => ({
  schema_version: 1, viewport, scale: 2, resources: [], clip_chains: [], items, ...extra,
});

// State capture makes the tests verify actual drawing parameters and balanced
// save/restore behavior, independently of browser rasterization/font metrics.
function recordingContext() {
  const calls = [];
  const stack = [];
  let state = { globalAlpha: 0.35, font: "9px serif", textAlign: "right", textBaseline: "bottom", direction: "rtl" };
  const methods = {
    calls,
    depth: () => stack.length,
    state: () => ({ ...state }),
    save() { calls.push(["save"]); stack.push({ ...state }); },
    restore() { calls.push(["restore"]); assert.ok(stack.length); state = stack.pop(); },
    setTransform(...values) { calls.push(["setTransform", ...values]); },
    transform(...values) { calls.push(["transform", ...values]); },
    beginPath() { calls.push(["beginPath"]); },
    rect(...values) { calls.push(["rect", ...values]); },
    clip() { calls.push(["clip"]); },
    clearRect(...values) { calls.push(["clearRect", ...values]); },
    fillRect(...values) { calls.push(["fillRect", ...values, { ...state }]); },
    fillText(...values) { calls.push(["fillText", ...values, { ...state }]); },
  };
  return new Proxy(methods, {
    get(target, key) { return key in target ? target[key] : state[key]; },
    set(_target, key, value) { state[key] = value; return true; },
  });
}

test("mixed quad/text scenes retain paint order and host-font parameters", () => {
  const context = recordingContext();
  const before = context.state();
  drawSceneSnapshot(context, scene([quad(1), text(2, { opacity: 0.5 }), quad(3)]), dimensions);
  const paints = context.calls.filter(([name]) => name === "fillRect" || name === "fillText");
  assert.deepEqual(paints.map(([name]) => name), ["fillRect", "fillText", "fillRect"]);
  assert.deepEqual(context.calls[1], ["setTransform", 2, 0, 0, 2, 0, 0]);
  assert.deepEqual(context.calls[2], ["clearRect", 0, 0, 320, 180]);
  const run = paints[1];
  assert.deepEqual(run.slice(0, -1), ["fillText", "Review 日本語 😀", 10, 20]);
  assert.equal(run.at(-1).font, "16px system-ui, sans-serif");
  assert.equal(run.at(-1).textAlign, "left");
  assert.equal(run.at(-1).textBaseline, "top");
  assert.equal(run.at(-1).direction, "ltr");
  assert.equal(run.at(-1).globalAlpha, 0.5);
  assert.equal(run.at(-1).fillStyle, `rgba(12, 34, 56, ${128 / 255})`);
  assert.equal(paints[2].at(-1).globalAlpha, 1);
  assert.equal(context.depth(), 0);
  assert.deepEqual(context.state(), before);
});

test("viewport and chain clips precede transform; bounded text clip follows it", () => {
  const context = recordingContext();
  const bounds = { x: 2, y: 3, width: 40, height: 18 };
  const firstClip = { x: 5, y: 6, width: 70, height: 60 };
  const secondClip = { x: 8, y: 9, width: 50, height: 40 };
  const transform = { a: 0, b: 1, c: -1, d: 0, tx: 120, ty: 30 };
  drawSceneSnapshot(context, scene([text(7, { bounds, transform, clip_chain_id: 4 })], {
    clip_chains: [{ id: 4, rects: [firstClip, secondClip] }],
  }), dimensions);
  const geometry = context.calls.filter(([name]) => ["rect", "clip", "transform", "fillText"].includes(name));
  assert.deepEqual(geometry.map((call) => call[0] === "fillText" ? call.slice(0, -1) : call), [
    ["rect", 0, 0, 320, 180], ["clip"],
    ["rect", 5, 6, 70, 60], ["clip"],
    ["rect", 8, 9, 50, 40], ["clip"],
    ["transform", 0, 1, -1, 0, 120, 30],
    ["rect", 2, 3, 40, 18], ["clip"],
    ["fillText", "Review 日本語 😀", 2, 3],
  ]);
});

test("text limits use UTF-16 units; empty and exactly bounded text remain valid", () => {
  for (const value of ["", "😀".repeat(32_768)]) {
    const context = recordingContext();
    drawSceneSnapshot(context, scene([text(1, { text: value, font_size: 1024 })]), dimensions);
    assert.equal(context.calls.find(([name]) => name === "fillText")[1], value);
  }
  for (const size of [0, -1, 1024.01, Infinity, -Infinity, NaN, "16", null]) {
    assert.throws(() => drawSceneSnapshot(recordingContext(), scene([text(1, { font_size: size })]), dimensions), CanvasSceneError);
  }
  for (const value of [null, 123, "😀".repeat(32_768) + "x"]) {
    assert.throws(() => drawSceneSnapshot(recordingContext(), scene([text(1, { text: value })]), dimensions), CanvasSceneError);
  }
});

test("unsupported variants/resources and invalid later items fail before canvas mutation", () => {
  const invalidScenes = [
    [scene([quad(1), { ...text(2), kind: "image" }]), "unsupported_capability"],
    [scene([quad(1)], { resources: [{ id: 1 }] }), "unsupported_capability"],
    [scene([quad(1), text(2, { font_size: 0 })]), "conversion_failed"],
    [scene([text(1, { opacity: NaN })]), "conversion_failed"],
    [scene([quad(1, { transform: { ...identity, tx: Infinity } })]), "conversion_failed"],
    [scene([text(1, { color: { ...ink, red: 256 } })]), "conversion_failed"],
    [scene([text(1, { clip_chain_id: 7 })]), "conversion_failed"],
    [scene([text(1, { bounds: { ...viewport, width: -1 } })]), "conversion_failed"],
    [scene([text(1, { bounds: { x: 1e308, y: 0, width: 1e308, height: 1 } })]), "conversion_failed"],
    [scene([text(1, { transform: null })]), "conversion_failed"],
    [scene([text(1)], { schema_version: 2 }), "conversion_failed"],
    [scene([quad(1)], { scale: 0 }), "conversion_failed"],
    [scene([quad(1)], { resources: null }), "conversion_failed"],
    [null, "conversion_failed"],
  ];
  for (const [snapshot, expected] of invalidScenes) {
    const context = recordingContext();
    assert.throws(() => drawSceneSnapshot(context, snapshot, dimensions), (error) => error instanceof CanvasSceneError && error.code === expected);
    assert.deepEqual(context.calls, []);
  }
});

test("unused malformed clips and duplicate IDs are rejected, with zero extents allowed", () => {
  for (const chains of [
    [{ id: 1, rects: [] }, { id: 1, rects: [] }],
    [{ id: 1, rects: [{ ...viewport, height: -1 }] }],
    [{ id: 1, rects: null }],
    [{ id: "1", rects: [] }],
  ]) {
    const context = recordingContext();
    assert.throws(() => drawSceneSnapshot(context, scene([quad(1)], { clip_chains: chains }), dimensions), CanvasSceneError);
    assert.deepEqual(context.calls, []);
  }
  const context = recordingContext();
  drawSceneSnapshot(context, scene([text(1, {
    bounds: { x: 1, y: 1, width: 0, height: 0 }, clip_chain_id: -1,
  })], { clip_chains: [{ id: -1, rects: [{ x: 0, y: 0, width: 0, height: 1 }] }] }), dimensions);
  assert.equal(context.depth(), 0);
});

test("draw failures restore context state; unavailable contexts are explicit", () => {
  const context = recordingContext();
  const before = context.state();
  const failure = new Error("native fillText failure");
  // The recording proxy owns state properties; define a method to simulate
  // native drawing failure without changing its saved style state.
  Object.defineProperty(context, "fillText", { value() { throw failure; } });
  assert.throws(() => drawSceneSnapshot(context, scene([text(1)]), dimensions), (error) => error === failure);
  assert.equal(context.depth(), 0);
  assert.deepEqual(context.state(), before);
  for (const unavailable of [null, { isContextLost: () => true }]) {
    assert.throws(() => drawSceneSnapshot(unavailable, scene([]), dimensions), (error) => error.code === "surface_lost");
  }
});

test("invalid output dimensions fail without touching the context", () => {
  for (const overrides of [{ width: 0 }, { height: -1 }, { scale: NaN }, { width: Infinity }]) {
    const context = recordingContext();
    assert.throws(() => drawSceneSnapshot(context, scene([]), { ...dimensions, ...overrides }), CanvasSceneError);
    assert.deepEqual(context.calls, []);
  }
});
