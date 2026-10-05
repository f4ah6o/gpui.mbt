const MAX_TEXT_UNITS = 65_536;
const MAX_FONT_SIZE = 1024;

export class CanvasSceneError extends Error {
  constructor(message, code = "conversion_failed") {
    super(message);
    this.name = "CanvasSceneError";
    this.code = code;
    this.operation = "BrowserBackend::present";
  }
}

function invalid(message) {
  throw new CanvasSceneError(message);
}

function record(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function rect(value, label) {
  if (!record(value)) invalid(`${label} must be a rectangle.`);
  const { x, y, width, height } = value;
  if (![x, y, width, height, x + width, y + height].every(Number.isFinite)
    || width < 0 || height < 0
    || (width > 0 && x + width <= x) || (height > 0 && y + height <= y)) {
    invalid(`${label} must have finite, non-negative, representable bounds.`);
  }
}

function color(value) {
  if (!record(value)
    || ![value.red, value.green, value.blue, value.alpha]
      .every((channel) => Number.isInteger(channel) && channel >= 0 && channel <= 255)) {
    invalid("Scene color channels must be integers in [0, 255].");
  }
}

function clipId(value) {
  return Number.isInteger(value) && value >= -2_147_483_648 && value <= 2_147_483_647;
}

function validate(snapshot, width, height, scale) {
  if (![width, height, scale].every(Number.isFinite) || width <= 0 || height <= 0 || scale <= 0) {
    invalid("Canvas dimensions and device scale must be finite and positive.");
  }
  if (!record(snapshot) || snapshot.schema_version !== 1
    || !Array.isArray(snapshot.resources) || !Array.isArray(snapshot.items)
    || !Array.isArray(snapshot.clip_chains)) {
    invalid("Expected a SceneSnapshot v1 envelope.");
  }
  if (snapshot.resources.length !== 0) {
    throw new CanvasSceneError("Canvas resource-backed paint is not supported.", "unsupported_capability");
  }
  rect(snapshot.viewport, "Scene viewport");
  if (!Number.isFinite(snapshot.scale) || snapshot.scale <= 0) invalid("Scene scale must be finite and positive.");

  const chains = new Map();
  for (const chain of snapshot.clip_chains) {
    if (!record(chain) || !clipId(chain.id) || !Array.isArray(chain.rects)) invalid("Invalid scene clip chain.");
    if (chains.has(chain.id)) invalid(`Duplicate scene clip chain ${chain.id}.`);
    for (const bounds of chain.rects) rect(bounds, "Clip rectangle");
    chains.set(chain.id, chain.rects);
  }
  for (const item of snapshot.items) {
    if (!record(item)) invalid("Scene items must be objects.");
    if (item.kind !== "quad" && item.kind !== "text") {
      throw new CanvasSceneError(`Unsupported Canvas scene item: ${String(item.kind)}.`, "unsupported_capability");
    }
    // IDs are not used as JS map keys: the v1 JSON envelope can carry UInt64
    // values beyond JS's exact integer range, without changing paint order.
    if (!Number.isInteger(item.id) || item.id < 0) invalid("Scene item IDs must be non-negative integers.");
    rect(item.bounds, "Item bounds");
    color(item.color);
    const transform = item.transform;
    if (!record(transform)
      || ![transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty].every(Number.isFinite)) {
      invalid("Scene item transforms must be finite.");
    }
    if (!Number.isFinite(item.opacity) || item.opacity < 0 || item.opacity > 1) invalid("Scene item opacity must be in [0, 1].");
    if (item.clip_chain_id !== null
      && (!clipId(item.clip_chain_id) || !chains.has(item.clip_chain_id))) {
      invalid("Scene item references an unknown clip chain.");
    }
    if (item.kind === "text") {
      if (typeof item.text !== "string" || item.text.length > MAX_TEXT_UNITS) invalid("Text must be at most 65,536 UTF-16 code units.");
      if (!Number.isFinite(item.font_size) || item.font_size <= 0 || item.font_size > MAX_FONT_SIZE) {
        invalid("Text font size must be in (0, 1024] logical pixels.");
      }
    }
  }
  return chains;
}

function clip(context, bounds) {
  context.beginPath();
  context.rect(bounds.x, bounds.y, bounds.width, bounds.height);
  context.clip();
}

/**
 * Draw the supported v1 quad/text subset into a caller-owned Canvas2D context.
 * Text is one host-font run: system sans, left/top aligned, clipped to bounds.
 * Font metrics, shaping and bidi behavior are supplied by the browser; this is
 * not portable text layout, wrapping, selection, caret geometry, or an IME.
 * Validate the complete scene before touching the canvas, including unused
 * clip chains, so unsupported or malformed frames never partially present.
 */
export function drawSceneSnapshot(context, snapshot, { width, height, scale } = {}) {
  const chains = validate(snapshot, width, height, scale);
  if (!context || (typeof context.isContextLost === "function" && context.isContextLost())) {
    throw new CanvasSceneError("The browser Canvas 2D context is unavailable.", "surface_lost");
  }
  context.save();
  try {
    context.setTransform(scale, 0, 0, scale, 0, 0);
    context.clearRect(0, 0, width, height);
    context.globalCompositeOperation = "source-over";
    context.filter = "none";
    context.shadowBlur = 0;
    context.shadowColor = "rgba(0, 0, 0, 0)";
    clip(context, snapshot.viewport);
    for (const item of snapshot.items) {
      context.save();
      try {
        // Clip chains are viewport-space, applied before the item transform.
        for (const bounds of chains.get(item.clip_chain_id) || []) clip(context, bounds);
        const { a, b, c, d, tx, ty } = item.transform;
        context.transform(a, b, c, d, tx, ty);
        context.globalAlpha = item.opacity;
        const { red, green, blue, alpha } = item.color;
        context.fillStyle = `rgba(${red}, ${green}, ${blue}, ${alpha / 255})`;
        const { x, y, width: itemWidth, height: itemHeight } = item.bounds;
        if (item.kind === "quad") {
          context.fillRect(x, y, itemWidth, itemHeight);
        } else {
          // Text bounds are local to the transformed item, unlike clip chains.
          clip(context, item.bounds);
          context.font = `${item.font_size}px system-ui, sans-serif`;
          context.textAlign = "left";
          context.textBaseline = "top";
          context.direction = "ltr";
          context.fillText(item.text, x, y);
        }
      } finally {
        context.restore();
      }
    }
  } finally {
    context.restore();
  }
}
