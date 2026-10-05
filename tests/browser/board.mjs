import assert from "node:assert/strict";
import { createReadStream, existsSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const siteRoot = join(repoRoot, "_build/browser-site");
const output = (name) => join(repoRoot, `_build/browser-board-${name}`);
assert.ok(
  existsSync(join(siteRoot, "index.html")),
  "build Weekboard before running this smoke test",
);
assert.ok(
  existsSync(join(siteRoot, "proof.html")),
  "the production build retains the interaction lab",
);

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".wasm": "application/wasm",
};
const server = createServer((request, response) => {
  let pathname;
  try {
    pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  } catch {
    response.writeHead(400).end("bad request");
    return;
  }
  const filename = normalize(join(siteRoot, pathname === "/" ? "index.html" : pathname));
  if (!filename.startsWith(`${siteRoot}/`)) {
    response.writeHead(403).end("forbidden");
    return;
  }
  if (!existsSync(filename) || !statSync(filename).isFile()) {
    response.writeHead(404).end("not found");
    return;
  }
  response.writeHead(200, {
    "content-type": mimeTypes[extname(filename)] || "application/octet-stream",
  });
  createReadStream(filename).pipe(response);
});

let browser;
let page;
let stage = "start production server";
const pageErrors = [];
const consoleMessages = [];
const passed = [];
const focusPaintChecks = [];

function attachDiagnostics(target, label) {
  target.on("pageerror", (error) => pageErrors.push({ page: label, message: error.message }));
  target.on("console", (message) =>
    consoleMessages.push({ page: label, type: message.type(), text: message.text() }),
  );
}

async function readBoard() {
  return page.evaluate(() => ({
    status: window.__gpuiBoardStatus?.() ?? null,
    layout: window.__gpuiBoardLayout?.() ?? null,
    host: window.__gpuiBoardHost?.() ?? null,
    focusedId: document.activeElement?.getAttribute("data-canvas-node-id") ?? null,
  }));
}

async function coherentViewport(expectedScale, expectedMobile) {
  await page.waitForFunction(
    ({ expectedScale, expectedMobile }) => {
      const canvas = document.querySelector("#board-canvas");
      const host = window.__gpuiBoardHost?.();
      const status = window.__gpuiBoardStatus?.();
      const layout = window.__gpuiBoardLayout?.();
      const bounds = canvas?.getBoundingClientRect();
      return (
        host?.running &&
        !host.lost &&
        !host.restoring &&
        !host.pendingFrame &&
        host.completedFrames > 0 &&
        status?.active &&
        layout?.mobile === expectedMobile &&
        window.devicePixelRatio === expectedScale &&
        host.scale === expectedScale &&
        status.scale === expectedScale &&
        bounds.width > 1 &&
        bounds.height > 1 &&
        Math.abs(status.logicalWidth - bounds.width) < 0.1 &&
        Math.abs(status.logicalHeight - bounds.height) < 0.1 &&
        canvas.width === Math.round(bounds.width * expectedScale) &&
        canvas.height === Math.round(bounds.height * expectedScale)
      );
    },
    { expectedScale, expectedMobile },
    { timeout: 10_000 },
  );
}

async function assertAccessibleCards() {
  const { layout } = await readBoard();
  const buttons = await page.locator("#board-accessibility button").evaluateAll((elements) =>
    elements.map((element) => ({
      id: Number(element.dataset.canvasNodeId),
      name: element.getAttribute("aria-label"),
      selected: element.getAttribute("aria-pressed") === "true",
      disabled: element.disabled,
    })),
  );
  assert.deepEqual(
    buttons.map((button) => button.id),
    layout.nodes.map((node) => node.id),
    "the projected reading order matches visible MoonBit nodes",
  );
  for (const node of layout.nodes) {
    const button = buttons.find((item) => item.id === node.id);
    assert.equal(button.name, node.name, "canvas text supplies the exact accessible task name");
    assert.equal(button.selected, node.selected);
    assert.equal(button.disabled, false);
    const lane = layout.lanes.find((item) => item.id === node.lane);
    assert.ok(lane.visible);
    assert.ok(node.bounds.x >= lane.viewport.x - 0.01 && node.bounds.y >= lane.viewport.y - 0.01);
    assert.ok(node.bounds.x + node.bounds.width <= lane.viewport.x + lane.viewport.width + 0.01);
    assert.ok(
      node.bounds.y + node.bounds.height <= lane.viewport.y + lane.viewport.height + 0.01,
      "visible semantic card bounds stay inside the lane clip",
    );
  }
}

async function waitForState(fields) {
  await page.waitForFunction(
    (expected) => {
      const host = window.__gpuiBoardHost();
      const status = window.__gpuiBoardStatus();
      return (
        !host.lost &&
        !host.pendingFrame &&
        Object.entries(expected).every(
          ([key, value]) => JSON.stringify(status[key]) === JSON.stringify(value),
        )
      );
    },
    fields,
    { timeout: 10_000 },
  );
}

async function waitForTaskLane(id, lane) {
  await page.waitForFunction(
    ({ id, lane }) =>
      !window.__gpuiBoardHost().pendingFrame &&
      window.__gpuiBoardStatus().tasks.some((task) => task.id === id && task.lane === lane),
    { id, lane },
    { timeout: 10_000 },
  );
}

async function waitForTasks(tasks) {
  await page.waitForFunction(
    (expected) =>
      !window.__gpuiBoardHost().pendingFrame &&
      JSON.stringify(window.__gpuiBoardStatus().tasks) === JSON.stringify(expected),
    tasks,
    { timeout: 10_000 },
  );
}

async function afterInputFrames() {
  // Observe two browser rendering opportunities before asserting an action
  // was ignored. This catches queued input without an arbitrary fixed sleep.
  await page.evaluate(
    () =>
      new Promise((resolveFrames, rejectFrames) => {
        const timeout = setTimeout(
          () => rejectFrames(new Error("two browser frames did not arrive")),
          2_000,
        );
        requestAnimationFrame(() =>
          requestAnimationFrame(() => {
            clearTimeout(timeout);
            resolveFrames();
          }),
        );
      }),
  );
}

async function canvasPoint(x, y) {
  const canvas = page.locator("#board-canvas");
  await canvas.scrollIntoViewIfNeeded();
  const bounds = await canvas.boundingBox();
  assert.ok(bounds);
  return { x: bounds.x + x, y: bounds.y + y };
}

async function cardPoint(id) {
  const { layout } = await readBoard();
  const node = layout.nodes.find((item) => item.id === id);
  assert.ok(node, `task ${id} must have a visible card before physical input`);
  return canvasPoint(node.bounds.x + node.bounds.width / 2, node.bounds.y + node.bounds.height / 2);
}

async function clickCard(id, touch = false) {
  const point = await cardPoint(id);
  if (touch) await page.touchscreen.tap(point.x, point.y);
  else await page.mouse.click(point.x, point.y);
  await waitForState({ selectedId: id, dragging: false, dragPending: false });
}

async function focusProxy(id) {
  await clickCard(id);
  await page.keyboard.press("Tab");
  await page.waitForFunction(
    (id) =>
      document.activeElement?.getAttribute("data-canvas-node-id") === String(id) &&
      !window.__gpuiBoardHost().pendingFrame,
    id,
    { timeout: 10_000 },
  );
}

async function startDrag(id, laneId) {
  const source = await cardPoint(id);
  await page.mouse.move(source.x, source.y);
  await page.mouse.down();
  await waitForState({ selectedId: id, dragPending: true, dragging: false, dragSource: id });
  const { layout } = await readBoard();
  const lane = layout.lanes.find((item) => item.id === laneId);
  assert.ok(lane?.visible);
  const target = await canvasPoint(lane.viewport.x + lane.viewport.width / 2, lane.viewport.y + 40);
  await page.mouse.move(target.x, target.y, { steps: 8 });
  await waitForState({ dragging: true, dragPending: false, dropLane: laneId });
}

async function wheelLane(id, amount) {
  const { layout } = await readBoard();
  const lane = layout.lanes.find((item) => item.id === id);
  assert.ok(lane?.visible);
  const point = await canvasPoint(lane.viewport.x + lane.viewport.width / 2, lane.viewport.y + 30);
  await page.mouse.move(point.x, point.y);
  await page.mouse.wheel(0, amount);
}

async function frameScreenshot(name, clip) {
  await afterInputFrames();
  const bounds = await page.locator("#board-frame").boundingBox();
  assert.ok(bounds);
  const area = clip || {
    x: Math.floor(bounds.x - 8),
    y: Math.floor(bounds.y - 8),
    width: Math.ceil(bounds.width + 17),
    height: Math.ceil(bounds.height + 17),
  };
  const png = await page.screenshot({
    path: output(`focus-${name}.png`),
    clip: area,
    scale: "css",
    animations: "disabled",
  });
  return {
    png: png.toString("base64"),
    clip: area,
    frame: {
      x: bounds.x - area.x,
      y: bounds.y - area.y,
      width: bounds.width,
      height: bounds.height,
    },
  };
}

async function compareFramePaint(before, after) {
  assert.deepEqual(after.clip, before.clip, "focus comparisons use the same screenshot region");
  assert.deepEqual(after.frame, before.frame, "focus indication must not shift the board layout");
  return page.evaluate(
    async ({ before, after }) => {
      const decode = async (png) => {
        const bitmap = await createImageBitmap(
          await (await fetch(`data:image/png;base64,${png}`)).blob(),
        );
        const surface = new OffscreenCanvas(bitmap.width, bitmap.height);
        const context = surface.getContext("2d");
        context.drawImage(bitmap, 0, 0);
        bitmap.close();
        return context.getImageData(0, 0, surface.width, surface.height);
      };
      const previous = await decode(before.png);
      const next = await decode(after.png);
      if (previous.width !== next.width || previous.height !== next.height) {
        throw new Error("focus screenshot dimensions changed");
      }
      const frame = before.frame;
      const scaleX = previous.width / before.clip.width;
      const scaleY = previous.height / before.clip.height;
      const changed = (logicalX, logicalY) => {
        const x = Math.floor(logicalX * scaleX);
        const y = Math.floor(logicalY * scaleY);
        const index = (y * previous.width + x) * 4;
        return (
          Math.max(
            Math.abs(previous.data[index] - next.data[index]),
            Math.abs(previous.data[index + 1] - next.data[index + 1]),
            Math.abs(previous.data[index + 2] - next.data[index + 2]),
          ) >= 40
        );
      };
      // Sample only narrow strips around the frame, outside all card content.
      // A selected card or text redraw cannot satisfy this perimeter assertion.
      // Long painted edges are required; no exact color or CSS property is assumed.
      const coverage = (length, point) => {
        let rows = 0;
        let changedRows = 0;
        for (let along = 16; along < length - 16; along += 1) {
          rows += 1;
          let any = false;
          for (let across = -7; across <= 3; across += 0.5) {
            const [x, y] = point(along, across);
            if (changed(x, y)) any = true;
          }
          if (any) changedRows += 1;
        }
        return changedRows / rows;
      };
      return {
        left: coverage(frame.height, (along, across) => [frame.x + across, frame.y + along]),
        right: coverage(frame.height, (along, across) => [
          frame.x + frame.width - across,
          frame.y + along,
        ]),
        top: coverage(frame.width, (along, across) => [frame.x + along, frame.y + across]),
        bottom: coverage(frame.width, (along, across) => [
          frame.x + along,
          frame.y + frame.height - across,
        ]),
      };
    },
    { before, after },
  );
}

async function focusExternalToolbar() {
  await page.locator("#board-search").click();
  // The Undo button can be disabled; walk the actual browser tab order to
  // the last toolbar control instead of assigning focus to the canvas.
  for (let step = 0; step < 3; step += 1) {
    if (await page.locator("#new-task").evaluate((button) => document.activeElement === button))
      break;
    await page.keyboard.press("Tab");
  }
  assert.equal(
    await page.locator("#new-task").evaluate((button) => document.activeElement === button),
    true,
  );
  await waitForState({ focused: false });
}

async function assertPaintedKeyboardFocus(scale) {
  const checks = [];
  const sample = async (label, before, after, visible) => {
    const edges = await compareFramePaint(before, after);
    checks.push({ scale, label, visible, edges });
  };
  await clickCard(1);
  await wheelLane(0, 2_000);
  await page.waitForFunction(
    () =>
      !window.__gpuiBoardLayout().nodes.some((node) => node.id === 1) &&
      !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  await focusExternalToolbar();
  const offscreen = await readBoard();
  assert.equal(offscreen.status.selectedId, 1);
  assert.equal(
    offscreen.layout.nodes.some((node) => node.selected),
    false,
    "no selected card is painted in the viewport",
  );
  const external = await frameScreenshot(`${scale}-offscreen-external`);
  await page.keyboard.press("Tab");
  await page.waitForFunction(
    () =>
      document.activeElement?.id === "board-canvas" &&
      window.__gpuiBoardStatus().focused &&
      !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  assert.equal(
    (await readBoard()).layout.nodes.some((node) => node.id === 1),
    false,
  );
  await sample(
    "toolbar Tab to canvas with selected task offscreen",
    external,
    await frameScreenshot(`${scale}-offscreen-canvas`, external.clip),
    true,
  );
  await assertAccessibleCards();
  await page.keyboard.press("Shift+Tab");
  await waitForState({ focused: false });
  await sample(
    "canvas indicator clears on focus exit",
    external,
    await frameScreenshot(`${scale}-offscreen-exited`, external.clip),
    false,
  );

  await wheelLane(0, -2_000);
  await page.waitForFunction(
    () =>
      window.__gpuiBoardLayout().lanes[0].scrollY === 0 && !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  await focusExternalToolbar();
  const beforeProxy = await frameScreenshot(`${scale}-proxy-external`, external.clip);
  await page.keyboard.press("Tab");
  await page.waitForFunction(() => document.activeElement?.id === "board-canvas", null, {
    timeout: 10_000,
  });
  await page.keyboard.press("Tab");
  await page.waitForFunction(
    () =>
      document.activeElement?.dataset.canvasNodeId === "1" &&
      !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  await sample(
    "visible task proxy paints a frame indicator",
    beforeProxy,
    await frameScreenshot(`${scale}-proxy-focused`, external.clip),
    true,
  );
  await wheelLane(0, 2_000);
  await page.waitForFunction(
    () =>
      document.activeElement?.id === "board-canvas" &&
      !window.__gpuiBoardLayout().nodes.some((node) => node.id === 1) &&
      !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  assert.equal(await page.locator("[data-canvas-node-id='1']").count(), 0);
  assert.equal((await readBoard()).status.selectedId, 1);
  await sample(
    "removed offscreen proxy transfers visible focus to canvas",
    external,
    await frameScreenshot(`${scale}-proxy-removed`, external.clip),
    true,
  );
  await assertAccessibleCards();
  await page.keyboard.press("Shift+Tab");
  await waitForState({ focused: false });
  await sample(
    "transferred indicator clears on focus exit",
    external,
    await frameScreenshot(`${scale}-proxy-exited`, external.clip),
    false,
  );
  await wheelLane(0, -2_000);
  await page.waitForFunction(
    () =>
      window.__gpuiBoardLayout().lanes[0].scrollY === 0 && !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  focusPaintChecks.push(...checks);
  writeFileSync(output("focus-paint.json"), JSON.stringify(focusPaintChecks, null, 2));
  for (const check of checks) {
    assert.ok(
      Object.values(check.edges).every((coverage) =>
        check.visible ? coverage >= 0.7 : coverage <= 0.05,
      ),
      `${check.label}: expected ${check.visible ? "painted" : "cleared"} frame edges, observed ${JSON.stringify(check.edges)}`,
    );
  }
}

async function suspend(kind) {
  if (kind === "hidden") {
    // Synthetic document visibility covers host scheduling and input gates;
    // it does not claim real OS tab suspension or compositor lifecycle.
    await page.evaluate(() => {
      Object.defineProperty(document, "hidden", { configurable: true, value: true });
      Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
      document.dispatchEvent(new Event("visibilitychange"));
    });
  } else {
    const prevented = await page.locator("#board-canvas").evaluate((canvas) => {
      const event = new Event("contextlost", { cancelable: true });
      canvas.dispatchEvent(event);
      return event.defaultPrevented;
    });
    assert.equal(
      prevented,
      false,
      "Canvas 2D contextlost remains uncanceled so restoration is allowed",
    );
    await page.waitForFunction(() => window.__gpuiBoardHost().lost, null, { timeout: 10_000 });
    assert.equal(await page.locator("#board-diagnostic").isVisible(), true);
  }
  assert.equal(await page.locator("#new-task").isDisabled(), true);
  assert.equal((await readBoard()).host.activePointer, null);
  assert.equal((await readBoard()).host.pendingFrame, false);
}

async function resume(kind, expectedScale = 1.5) {
  if (kind === "hidden") {
    await page.evaluate(() => {
      delete document.hidden;
      delete document.visibilityState;
      document.dispatchEvent(new Event("visibilitychange"));
    });
  } else {
    await page
      .locator("#board-canvas")
      .evaluate((canvas) => canvas.dispatchEvent(new Event("contextrestored")));
  }
  await coherentViewport(expectedScale, false);
  await waitForState({ visible: true, dragging: false, dragPending: false, dragSource: null });
  assert.equal(await page.locator("#new-task").isEnabled(), true);
}

function complete(label) {
  passed.push(label);
  console.log(`Weekboard smoke PASS: ${label}`);
}

try {
  await new Promise((resolveListen, rejectListen) => {
    server.once("error", rejectListen);
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  browser = await chromium.launch({ headless: true });
  const desktop = await browser.newContext({
    viewport: { width: 1560, height: 1060 },
    deviceScaleFactor: 1.5,
  });
  page = await desktop.newPage();
  page.setDefaultTimeout(10_000);
  attachDiagnostics(page, "desktop");
  stage = "initial canvas text and accessible task cards";
  await page.goto(baseUrl, { waitUntil: "load" });
  await coherentViewport(1.5, false);
  const initial = await readBoard();
  assert.equal(initial.status.total, 12);
  assert.equal(initial.status.done, 2);
  assert.equal(initial.status.canUndo, false);
  assert.equal(initial.layout.lanes.filter((lane) => lane.visible).length, 3);
  await assertAccessibleCards();
  const textPixels = await page.evaluate(() => {
    const canvas = document.querySelector("#board-canvas");
    const node = window.__gpuiBoardLayout().nodes.find((item) => item.id === 1);
    const scale = window.devicePixelRatio;
    // The title is an interior text-only region, excluding card borders and badges.
    const pixels = canvas
      .getContext("2d")
      .getImageData(
        Math.ceil((node.bounds.x + 12) * scale),
        Math.ceil((node.bounds.y + 29) * scale),
        Math.floor((node.bounds.width - 24) * scale),
        Math.floor(22 * scale),
      ).data;
    let dark = 0;
    for (let index = 0; index < pixels.length; index += 4) {
      if (
        pixels[index] < 100 &&
        pixels[index + 1] < 115 &&
        pixels[index + 2] < 135 &&
        pixels[index + 3] > 0
      )
        dark += 1;
    }
    return dark;
  });
  assert.ok(textPixels > 40, "the task title is painted as visible text inside the canvas card");
  writeFileSync(output("initial-status.json"), JSON.stringify({ ...initial, textPixels }, null, 2));
  await page.screenshot({ path: output("desktop.png"), fullPage: true });
  complete(stage);

  stage = "visible keyboard focus with offscreen selection and removed focus proxy at DPR 1.5";
  await assertPaintedKeyboardFocus(1.5);
  complete(stage);

  stage = "physical selection, threshold click, keyboard navigation and proxy undo";
  await clickCard(2);
  assert.equal(
    await page.locator("#detail-heading").textContent(),
    initial.status.tasks.find((task) => task.id === 2).title,
  );
  assert.equal(await page.locator("#detail-lane").textContent(), "Backlog");
  const click = await cardPoint(2);
  await page.mouse.move(click.x, click.y);
  await page.mouse.down();
  await waitForState({ dragPending: true, dragging: false });
  await page.mouse.move(click.x + 2, click.y + 2);
  await waitForState({ dragPending: true, dragging: false });
  await page.mouse.up();
  await waitForState({ dragging: false, dragPending: false, canUndo: false });
  await waitForTasks(initial.status.tasks);
  await clickCard(1);
  await page.keyboard.press("ArrowDown");
  await waitForState({ selectedId: 2 });
  await page.waitForFunction(() => document.activeElement?.dataset.canvasNodeId === "2", null, {
    timeout: 10_000,
  });
  await page.keyboard.press("Alt+ArrowRight");
  await waitForTaskLane(2, 1);
  assert.equal(
    (await readBoard()).focusedId,
    "2",
    "keyboard movement retains the matching ARIA proxy focus",
  );
  await page.keyboard.press("Control+z");
  await waitForTaskLane(2, 0);
  await waitForState({ canUndo: false });
  assert.equal(
    (await readBoard()).focusedId,
    "2",
    "Ctrl+Z works while the card's ARIA proxy owns focus",
  );
  await page.keyboard.press("Alt+ArrowRight");
  await waitForTaskLane(2, 1);
  await page.locator("#undo").click();
  await waitForTasks(initial.status.tasks);
  await clickCard(1);
  await page.keyboard.press("Alt+ArrowRight");
  await waitForTaskLane(1, 1);
  await focusProxy(8);
  await page.keyboard.press("Control+z");
  await waitForTasks(initial.status.tasks);
  await waitForState({ selectedId: 1 });
  await page.waitForFunction(() => document.activeElement?.dataset.canvasNodeId === "1", null, {
    timeout: 10_000,
  });
  assert.equal(
    (await readBoard()).status.selectedId,
    1,
    "undo restores its prior selection even after another proxy was focused",
  );
  complete(stage);

  stage = "Japanese search, zero results and clear search";
  await page.locator("#board-search").fill("日本語");
  await waitForState({ query: "日本語", filteredIds: [3], selectedId: 3 });
  assert.deepEqual(
    (await readBoard()).layout.nodes.map((node) => node.id),
    [3],
  );
  await assertAccessibleCards();
  await page.locator("#board-search").fill("no-matching-weekboard-task-938");
  await waitForState({
    query: "no-matching-weekboard-task-938",
    filteredIds: [],
    selectedId: null,
  });
  assert.equal(await page.locator("#board-empty").isVisible(), true);
  assert.equal(await page.locator("#board-accessibility button").count(), 0);
  for (const lane of [0, 1, 2])
    assert.equal(await page.locator(`[data-move-lane='${lane}']`).isDisabled(), true);
  await page.locator("#clear-search").click();
  await waitForState({ query: "", total: 12 });
  assert.equal((await readBoard()).status.filteredIds.length, 12);
  assert.equal(await page.locator("#board-empty").isVisible(), false);
  assert.equal(
    await page.locator("#board-search").evaluate((input) => input === document.activeElement),
    true,
  );
  complete(stage);

  stage = "add-dialog required and trimmed-title validation, success, undo and cancel";
  await page.locator("#new-task").click();
  await page.locator("#submit-task").click();
  assert.equal(
    await page.locator("#task-title").evaluate((input) => input.validity.valueMissing),
    true,
  );
  assert.equal(await page.locator("#task-dialog").isVisible(), true);
  await page.locator("#task-title").fill("   ");
  await page.locator("#submit-task").click();
  await page.waitForFunction(
    () => document.querySelector("#form-error").textContent.length > 0,
    null,
    { timeout: 10_000 },
  );
  assert.equal((await readBoard()).status.total, 12);
  assert.equal(await page.locator("#submit-task").isEnabled(), true);
  await page.locator("#task-title").fill("  Verify the release 演習  ");
  await page.locator("#submit-task").click();
  await waitForState({ total: 13, query: "" });
  await page.locator("#task-dialog").waitFor({ state: "hidden" });
  const added = (await readBoard()).status;
  const addedTask = added.tasks.find((task) => task.title === "Verify the release 演習");
  assert.ok(addedTask);
  assert.equal(addedTask.lane, 0);
  assert.equal(added.selectedId, addedTask.id);
  assert.equal(await page.locator("#detail-heading").textContent(), addedTask.title);
  await page.locator("#undo").click();
  await waitForTasks(initial.status.tasks);
  await page.locator("#new-task").click();
  await page.locator("#cancel-task").click();
  await page.locator("#task-dialog").waitFor({ state: "hidden" });
  await afterInputFrames();
  assert.deepEqual((await readBoard()).status.tasks, initial.status.tasks);
  complete(stage);

  stage = "physical card drag and Escape, pointercancel and blur cancellation";
  await clickCard(1);
  await startDrag(1, 1);
  await page.mouse.up();
  await waitForTaskLane(1, 1);
  await waitForState({ dragging: false, dragPending: false, dragSource: null });
  assert.equal((await readBoard()).host.activePointer, null);
  await page.locator("#undo").click();
  await waitForTasks(initial.status.tasks);
  for (const kind of ["Escape", "pointercancel", "blur"]) {
    stage = `physical drag cancellation: ${kind}`;
    await clickCard(1);
    await startDrag(1, 1);
    if (kind === "Escape") {
      await page.keyboard.press("Escape");
    } else if (kind === "pointercancel") {
      // Chromium delivers the drag itself; only the interruption is synthetic.
      await page.locator("#board-canvas").evaluate((canvas) =>
        canvas.dispatchEvent(
          new PointerEvent("pointercancel", {
            bubbles: true,
            pointerId: window.__gpuiBoardHost().activePointer,
            pointerType: "mouse",
            isPrimary: true,
          }),
        ),
      );
    } else {
      await page.evaluate(() => window.dispatchEvent(new Event("blur")));
    }
    await waitForState({ dragging: false, dragPending: false, dragSource: null, canUndo: false });
    assert.equal((await readBoard()).host.activePointer, null);
    await page.mouse.up();
    await afterInputFrames();
    assert.deepEqual(
      (await readBoard()).status.tasks,
      initial.status.tasks,
      `${kind} prevents a later pointerup from moving a card`,
    );
    if (kind === "blur") await page.evaluate(() => window.dispatchEvent(new Event("focus")));
  }
  complete("physical card drag and Escape, pointercancel and synthetic blur cancellation");

  stage = "independent lane wheel state, clipped card semantics and no offscreen ghost hit";
  // Two real moves make both first lanes overflow, exposing shared-offset bugs.
  for (const id of [1, 2]) {
    await clickCard(id);
    await page.locator("[data-move-lane='1']").click();
    await waitForTaskLane(id, 1);
  }
  const scrollStart = (await readBoard()).layout;
  assert.ok(scrollStart.lanes[0].maxScrollY > 0 && scrollStart.lanes[1].maxScrollY > 0);
  await wheelLane(0, 2_000);
  await page.waitForFunction(
    () => {
      const lane = window.__gpuiBoardLayout().lanes[0];
      return lane.scrollY === lane.maxScrollY && !window.__gpuiBoardHost().pendingFrame;
    },
    null,
    { timeout: 10_000 },
  );
  const firstScrolled = (await readBoard()).layout;
  assert.equal(firstScrolled.lanes[1].scrollY, scrollStart.lanes[1].scrollY);
  assert.equal(firstScrolled.lanes[2].scrollY, scrollStart.lanes[2].scrollY);
  await wheelLane(1, 2_000);
  await page.waitForFunction(
    () => {
      const lane = window.__gpuiBoardLayout().lanes[1];
      return lane.scrollY === lane.maxScrollY && !window.__gpuiBoardHost().pendingFrame;
    },
    null,
    { timeout: 10_000 },
  );
  assert.equal((await readBoard()).layout.lanes[0].scrollY, firstScrolled.lanes[0].scrollY);
  await assertAccessibleCards();
  await page.locator("#undo").click();
  await waitForTaskLane(2, 0);
  await page.locator("#undo").click();
  await waitForTasks(initial.status.tasks);
  await clickCard(1);
  const oldCard = (await readBoard()).layout.nodes.find((node) => node.id === 1).bounds;
  await wheelLane(0, 2_000);
  await page.waitForFunction(
    () =>
      !window.__gpuiBoardLayout().nodes.some((node) => node.id === 1) &&
      !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  assert.equal(
    await page.locator("[data-canvas-node-id='1']").count(),
    0,
    "a wholly clipped task has no focus proxy",
  );
  const scrolled = (await readBoard()).layout;
  const logicalOldPoint = { x: oldCard.x + oldCard.width / 2, y: oldCard.y + oldCard.height / 2 };
  const currentCard = [...scrolled.nodes]
    .reverse()
    .find(
      ({ bounds }) =>
        logicalOldPoint.x >= bounds.x &&
        logicalOldPoint.x <= bounds.x + bounds.width &&
        logicalOldPoint.y >= bounds.y &&
        logicalOldPoint.y <= bounds.y + bounds.height,
    );
  assert.ok(currentCard && currentCard.id !== 1);
  const oldPoint = await canvasPoint(logicalOldPoint.x, logicalOldPoint.y);
  await page.mouse.click(oldPoint.x, oldPoint.y);
  await waitForState({ selectedId: currentCard.id });
  const headerPoint = await canvasPoint(
    scrolled.lanes[0].viewport.x + 20,
    scrolled.lanes[0].viewport.y - 8,
  );
  await page.mouse.move(headerPoint.x, headerPoint.y);
  await waitForState({ hoverId: null });
  await page.mouse.click(headerPoint.x, headerPoint.y);
  await afterInputFrames();
  assert.equal(
    (await readBoard()).status.selectedId,
    currentCard.id,
    "a card clipped behind the lane header cannot receive a ghost click",
  );
  assert.equal((await readBoard()).status.dragSource, null);
  await wheelLane(0, -2_000);
  await page.waitForFunction(
    () =>
      window.__gpuiBoardLayout().lanes[0].scrollY === 0 && !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  await assertAccessibleCards();
  complete(stage);

  for (const kind of ["contextlost", "hidden"]) {
    stage = `synthetic ${kind}: cancel captured drag, retain tasks and resume input`;
    await clickCard(1);
    await startDrag(1, 1);
    await suspend(kind);
    const suspendedFrames = (await readBoard()).host.completedFrames;
    await page.mouse.up();
    await page.keyboard.press("Alt+ArrowRight");
    await afterInputFrames();
    assert.equal(
      (await readBoard()).host.completedFrames,
      suspendedFrames,
      "suspended input does not schedule painting",
    );
    assert.deepEqual((await readBoard()).status.tasks, initial.status.tasks);
    await resume(kind);
    await waitForTasks(initial.status.tasks);
    await clickCard(2);
    await page.keyboard.press("Alt+ArrowRight");
    await waitForTaskLane(2, 1);
    await page.locator("#undo").click();
    await waitForTasks(initial.status.tasks);
    complete(stage);

    stage = `synthetic ${kind}: retain card proxy focus and honor external focus`;
    await focusProxy(1);
    const proxy = await page.locator("[data-canvas-node-id='1']").elementHandle();
    await suspend(kind);
    assert.equal(
      await page.evaluate((element) => document.activeElement === element, proxy),
      true,
      "suspension keeps the same focused proxy alive",
    );
    assert.equal(
      await page.locator("[data-canvas-node-id='1']").getAttribute("aria-disabled"),
      "true",
    );
    await page.keyboard.press("Alt+ArrowRight");
    await page.keyboard.press("Control+z");
    await afterInputFrames();
    assert.deepEqual((await readBoard()).status.tasks, initial.status.tasks);
    await resume(kind);
    assert.equal(
      await page.evaluate((element) => document.activeElement === element, proxy),
      true,
      "restoration preserves proxy identity and focus",
    );
    await assertAccessibleCards();
    await proxy.dispose();
    await suspend(kind);
    await page.locator(".keyboard-help summary").click();
    assert.equal(
      await page
        .locator(".keyboard-help summary")
        .evaluate((element) => document.activeElement === element),
      true,
    );
    await resume(kind);
    assert.equal(
      await page
        .locator(".keyboard-help summary")
        .evaluate((element) => document.activeElement === element),
      true,
      "restoration does not steal focus from an external control",
    );
    await waitForTasks(initial.status.tasks);
    complete(stage);
  }

  stage = "desktop resize and device scale 1.5 to 2 preserve task state";
  await page.setViewportSize({ width: 1280, height: 900 });
  await coherentViewport(1.5, false);
  assert.notEqual((await readBoard()).status.logicalWidth, initial.status.logicalWidth);
  const cdp = await desktop.newCDPSession(page);
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 1180,
    height: 880,
    deviceScaleFactor: 2,
    mobile: false,
  });
  await coherentViewport(2, false);
  await waitForTasks(initial.status.tasks);
  await assertAccessibleCards();
  await clickCard(1);
  await page.keyboard.press("ArrowDown");
  await waitForState({ selectedId: 2 });
  complete(stage);

  stage = "visible keyboard focus remains painted and clears correctly at DPR 2";
  // Screenshot capture can restore Playwright's configured metrics after an
  // out-of-band CDP override. Keep the live resize check above, but configure
  // this pixel-verification context at its intended DPR from creation.
  const focusAtTwo = await browser.newContext({
    viewport: { width: 1180, height: 880 },
    deviceScaleFactor: 2,
  });
  page = await focusAtTwo.newPage();
  page.setDefaultTimeout(10_000);
  attachDiagnostics(page, "desktop-2x-focus");
  await page.goto(baseUrl, { waitUntil: "load" });
  await coherentViewport(2, false);
  await assertPaintedKeyboardFocus(2);
  await coherentViewport(2, false);
  complete(stage);

  stage = "mobile single-lane tabs, touch move buttons and Earlier/Later scrolling";
  const mobile = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 2,
    isMobile: true,
    hasTouch: true,
  });
  page = await mobile.newPage();
  page.setDefaultTimeout(10_000);
  attachDiagnostics(page, "mobile");
  await page.goto(baseUrl, { waitUntil: "load" });
  await coherentViewport(2, true);
  assert.equal(await page.locator("#mobile-lanes").isVisible(), true);
  assert.equal(await page.locator("#mobile-scroll").isVisible(), true);
  assert.deepEqual(
    (await readBoard()).layout.lanes.filter((lane) => lane.visible).map((lane) => lane.id),
    [0],
  );
  assert.equal(
    await page.locator("#board-canvas").evaluate((canvas) => getComputedStyle(canvas).touchAction),
    "pan-y",
  );
  await page.locator("#board-canvas").scrollIntoViewIfNeeded();
  const touchBounds = await page.locator("#board-canvas").boundingBox();
  const swipeX = touchBounds.x + touchBounds.width / 2;
  const swipeY = touchBounds.y + touchBounds.height / 2;
  const scrollBeforeSwipe = await page.evaluate(() => window.scrollY);
  const mobileCdp = await mobile.newCDPSession(page);
  // Dispatch at Chromium's input boundary, not DOM TouchEvent handlers, so
  // the browser must arbitrate native page panning against canvas dragging.
  await mobileCdp.send("Input.dispatchTouchEvent", {
    type: "touchStart",
    touchPoints: [{ x: swipeX, y: swipeY, id: 1 }],
  });
  for (let step = 1; step <= 6; step += 1) {
    await mobileCdp.send("Input.dispatchTouchEvent", {
      type: "touchMove",
      touchPoints: [{ x: swipeX, y: swipeY - step * 25, id: 1 }],
    });
    await afterInputFrames();
  }
  await mobileCdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] });
  await page.waitForFunction((before) => window.scrollY > before + 40, scrollBeforeSwipe, {
    timeout: 10_000,
  });
  await waitForState({ dragging: false, dragPending: false, dragSource: null, canUndo: false });
  assert.equal(
    (await readBoard()).host.activePointer,
    null,
    "native mobile panning cancels canvas pointer capture",
  );
  await waitForTasks(initial.status.tasks);
  complete("mobile Chromium touch swipe pans the page from inside the canvas without moving tasks");
  await page.locator("#mobile-lanes button[data-lane='1']").tap();
  await waitForState({ activeLane: 1, selectedId: 8 });
  assert.deepEqual(
    (await readBoard()).layout.lanes.filter((lane) => lane.visible).map((lane) => lane.id),
    [1],
  );
  assert.equal(
    await page.locator("#mobile-lanes button[data-lane='1']").getAttribute("aria-pressed"),
    "true",
  );
  await clickCard(8, true);
  await page.locator("[data-move-lane='2']").tap();
  await waitForTaskLane(8, 2);
  await waitForState({ activeLane: 2 });
  assert.equal(await page.locator("#detail-lane").textContent(), "Done");
  await page.locator("[data-move-lane='0']").tap();
  await waitForTaskLane(8, 0);
  await waitForState({ activeLane: 0 });
  await page.locator("#undo").tap();
  await waitForTaskLane(8, 2);
  await page.locator("#undo").tap();
  await waitForTasks(initial.status.tasks);
  await page.locator("#mobile-lanes button[data-lane='0']").tap();
  await waitForState({ activeLane: 0 });
  assert.equal(await page.locator("#scroll-back").isDisabled(), true);
  assert.equal(await page.locator("#scroll-forward").isEnabled(), true);
  await page.locator("#scroll-forward").tap();
  await page.waitForFunction(
    () => window.__gpuiBoardLayout().lanes[0].scrollY > 0 && !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  assert.equal(
    (await readBoard()).layout.nodes.some((node) => node.id === 1),
    false,
  );
  assert.equal(await page.locator("#scroll-back").isEnabled(), true);
  await assertAccessibleCards();
  await page.locator("#scroll-back").tap();
  await page.waitForFunction(
    () =>
      window.__gpuiBoardLayout().lanes[0].scrollY === 0 && !window.__gpuiBoardHost().pendingFrame,
    null,
    { timeout: 10_000 },
  );
  assert.equal(
    (await readBoard()).layout.nodes.some((node) => node.id === 1),
    true,
  );
  await assertAccessibleCards();
  await page.screenshot({ path: output("mobile.png"), fullPage: true });
  complete(stage);

  stage = "interaction lab navigation and return to Weekboard";
  await page.locator(".about-demo summary").tap();
  await Promise.all([
    page.waitForURL("**/proof.html"),
    page.getByRole("link", { name: "interaction lab", exact: true }).tap(),
  ]);
  assert.match(await page.title(), /Browser viewport proof/);
  await page.locator("#gpui-viewport").waitFor({ state: "visible" });
  await page.goBack({ waitUntil: "load" });
  await coherentViewport(2, true);
  assert.equal((await readBoard()).status.total, 12);
  complete(stage);

  stage = "task-cap rejection settles the dialog and permits recovery";
  const capacityContext = await browser.newContext({ viewport: { width: 1280, height: 900 } });
  page = await capacityContext.newPage();
  page.setDefaultTimeout(10_000);
  attachDiagnostics(page, "capacity");
  await page.goto(baseUrl, { waitUntil: "load" });
  await coherentViewport(1, false);
  // Populate through real dialogs so this exercises host pendingAdd settlement,
  // not only the MoonBit model's independently tested 100-task limit.
  for (let total = 13; total <= 100; total += 1) {
    await page.locator("#new-task").click();
    await page.locator("#task-title").fill(`Capacity task ${total}`);
    await page.locator("#submit-task").click();
    await waitForState({ total });
    await page.locator("#task-dialog").waitFor({ state: "hidden" });
    if (total % 20 === 0) console.log(`Weekboard capacity setup: ${total}/100 tasks via dialog`);
  }
  await page.locator("#new-task").click();
  await page.locator("#task-title").fill("One task too many");
  await page.locator("#submit-task").click();
  await page.waitForFunction(
    () =>
      document.querySelector("#form-error").textContent.includes("100 tasks") &&
      !document.querySelector("#submit-task").disabled,
    null,
    { timeout: 10_000 },
  );
  assert.equal((await readBoard()).status.total, 100);
  assert.equal(await page.locator("#task-dialog").isVisible(), true);
  assert.equal(
    (await readBoard()).status.tasks.some((task) => task.title === "One task too many"),
    false,
  );
  await page.locator("#cancel-task").click();
  await page.locator("#undo").click();
  await waitForState({ total: 99 });
  await page.locator("#new-task").click();
  await page.locator("#task-title").fill("A task after capacity recovery");
  await page.locator("#submit-task").click();
  await waitForState({ total: 100 });
  await page.locator("#task-dialog").waitFor({ state: "hidden" });
  assert.equal(
    (await readBoard()).status.tasks.some(
      (task) => task.title === "A task after capacity recovery",
    ),
    true,
  );
  complete(stage);

  assert.deepEqual(pageErrors, [], "the production board has no uncaught page errors");
  console.log(
    `Weekboard smoke passed: ${passed.length} checks. Pointercancel, blur, hidden document and Canvas loss/restoration are synthetic Chromium lifecycle coverage, not OS/IME or cross-browser qualification.`,
  );
} catch (error) {
  console.error(`Weekboard smoke failed at ${stage}:`, error);
  if (page) {
    try {
      writeFileSync(
        output("status.json"),
        JSON.stringify(
          {
            stage,
            passed,
            error: { message: error.message, stack: error.stack },
            title: await page.title(),
            body: await page
              .locator("body")
              .innerText()
              .catch(() => "unavailable"),
            board: await readBoard().catch(() => null),
            pageErrors,
            consoleMessages,
            focusPaintChecks,
          },
          null,
          2,
        ),
      );
      await page.screenshot({ path: output("failure.png"), fullPage: true });
    } catch (captureError) {
      console.error("Could not retain Weekboard failure details:", captureError);
    }
  }
  throw error;
} finally {
  await browser?.close();
  if (server.listening)
    await new Promise((resolveClose, rejectClose) =>
      server.close((error) => (error ? rejectClose(error) : resolveClose())),
    );
}
