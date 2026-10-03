import assert from "node:assert/strict";
import { createReadStream, existsSync, statSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const siteRoot = join(repoRoot, "_build/browser-site");
assert.ok(existsSync(join(siteRoot, "index.html")), "build the browser demo before running this test");

const mimeTypes = {
  ".css": "text/css; charset=utf-8",
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
};
const server = createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
  const filename = normalize(join(siteRoot, pathname === "/" ? "index.html" : pathname));
  if (!filename.startsWith(`${siteRoot}/`) && filename !== join(siteRoot, "index.html")) {
    response.writeHead(403).end("forbidden");
    return;
  }
  if (!existsSync(filename) || !statSync(filename).isFile()) {
    response.writeHead(404).end("not found");
    return;
  }
  response.writeHead(200, { "content-type": mimeTypes[extname(filename)] || "application/octet-stream" });
  createReadStream(filename).pipe(response);
});

await new Promise((resolveListen) => server.listen(0, "127.0.0.1", resolveListen));
const address = server.address();
let browser;
let page;
const pageErrors = [];
const consoleMessages = [];
try {
  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 1360, height: 960 },
    deviceScaleFactor: 1.5,
  });
  page = await context.newPage();
  page.on("pageerror", (error) => pageErrors.push(error.message));
  page.on("console", (message) => consoleMessages.push(`${message.type()}: ${message.text()}`));
  await page.addInitScript(() => {
    const nativeRequestAnimationFrame = window.requestAnimationFrame.bind(window);
    window.__rafCalls = 0;
    window.requestAnimationFrame = (callback) => {
      window.__rafCalls += 1;
      return nativeRequestAnimationFrame(callback);
    };
  });

  await page.goto(`http://127.0.0.1:${address.port}/`, { waitUntil: "load" });
  const canvas = page.locator("#gpui-viewport");
  const readViewport = () => page.evaluate(async () => {
    const gpui = await import("./gpui-browser.js");
    const canvas = document.querySelector("#gpui-viewport");
    const bounds = canvas.getBoundingClientRect();
    const status = JSON.parse(gpui.gpui_browser_status());
    return {
      cssWidth: bounds.width,
      cssHeight: bounds.height,
      backingWidth: canvas.width,
      backingHeight: canvas.height,
      devicePixelRatio: window.devicePixelRatio,
      status,
      logicalLabel: document.querySelector("#logical-size")?.textContent,
      backingLabel: document.querySelector("#backing-size")?.textContent,
      scaleLabel: document.querySelector("#device-scale")?.textContent,
      frameState: document.querySelector("#frame-state")?.textContent,
    };
  });
  const waitForCoherentViewport = (expectedScale) => page.waitForFunction(async (scale) => {
    const gpui = await import("./gpui-browser.js");
    const measure = () => {
      const canvas = document.querySelector("#gpui-viewport");
      if (!canvas) return null;
      const bounds = canvas.getBoundingClientRect();
      const status = JSON.parse(gpui.gpui_browser_status());
      return {
        cssWidth: bounds.width,
        cssHeight: bounds.height,
        backingWidth: canvas.width,
        backingHeight: canvas.height,
        devicePixelRatio: window.devicePixelRatio,
        logicalWidth: status.logicalWidth,
        logicalHeight: status.logicalHeight,
        statusDpr: status.dpr,
        logicalLabel: document.querySelector("#logical-size")?.textContent,
        backingLabel: document.querySelector("#backing-size")?.textContent,
        scaleLabel: document.querySelector("#device-scale")?.textContent,
        frameState: document.querySelector("#frame-state")?.textContent,
      };
    };
    const isCoherent = (state) => state !== null &&
      state.frameState === "RUNNING" &&
      state.devicePixelRatio === scale && state.statusDpr === scale &&
      Math.abs(state.logicalWidth - state.cssWidth) < 0.1 &&
      Math.abs(state.logicalHeight - state.cssHeight) < 0.1 &&
      state.backingWidth === Math.round(state.cssWidth * scale) &&
      state.backingHeight === Math.round(state.cssHeight * scale) &&
      state.scaleLabel === `${scale.toFixed(2)}×` &&
      state.backingLabel === `${state.backingWidth} × ${state.backingHeight} px` &&
      state.logicalLabel === `${Math.round(state.cssWidth)} × ${Math.round(state.cssHeight)} CSS px`;
    const first = measure();
    await new Promise(requestAnimationFrame);
    const second = measure();
    return isCoherent(first) && isCoherent(second) &&
      first.cssWidth === second.cssWidth && first.cssHeight === second.cssHeight &&
      first.backingWidth === second.backingWidth && first.backingHeight === second.backingHeight &&
      first.devicePixelRatio === second.devicePixelRatio &&
      first.logicalWidth === second.logicalWidth && first.logicalHeight === second.logicalHeight &&
      first.statusDpr === second.statusDpr;
  }, expectedScale);
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  await waitForCoherentViewport(1.5);
  const initialViewport = await readViewport();
  const initialPixel = await page.evaluate(() => {
    const canvas = document.querySelector("#gpui-viewport");
    const context = canvas.getContext("2d");
    const pixels = context.getImageData(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
    return Array.from(pixels);
  });
  assert.ok(initialPixel[0] !== 0 || initialPixel[1] !== 0 || initialPixel[2] !== 0, "the shared SceneSnapshot paints visible Canvas2D pixels");
  assert.ok(initialViewport.status.logicalWidth > 1 && initialViewport.status.logicalHeight > 1);
  assert.ok((await page.locator("#capabilities li").count()) >= 8);
  // One idle host should finish its requested frame instead of polling continuously.
  const idleRafCount = await page.evaluate(() => window.__rafCalls);
  await page.waitForTimeout(250);
  assert.ok((await page.evaluate(() => window.__rafCalls)) - idleRafCount < 8, "idle viewport does not run a continuous animation loop");

  await canvas.focus();
  await page.keyboard.press("Tab");
  await page.waitForFunction(() => document.querySelector("#focus-target")?.textContent === "#4");
  await page.keyboard.press("Shift+Tab");
  await page.waitForFunction(() => document.querySelector("#focus-target")?.textContent === "#7");
  await page.keyboard.press("Enter");
  await page.waitForFunction(() => Number(document.querySelector("#activation-count")?.textContent) === 1);

  // Use a deterministic CSS-pixel location that the portable fixture maps to tile #4.
  const canvasBounds = await canvas.boundingBox();
  const targetPoint = { x: 120, y: 238 };
  await page.mouse.move(canvasBounds.x + targetPoint.x, canvasBounds.y + targetPoint.y);
  await page.waitForFunction(async () => [4, 5, 6, 7].includes(JSON.parse((await import("./gpui-browser.js")).gpui_browser_status()).hover));
  await page.mouse.click(canvasBounds.x + targetPoint.x, canvasBounds.y + targetPoint.y);
  await page.waitForFunction(() => Number(document.querySelector("#activation-count")?.textContent) >= 2);

  // Resize CSS layout, then change DPR live through Chromium's emulation boundary.
  await page.setViewportSize({ width: 1200, height: 880 });
  await waitForCoherentViewport(1.5);
  const cdp = await context.newCDPSession(page);
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 1200,
    height: 880,
    deviceScaleFactor: 2,
    mobile: false,
  });
  await waitForCoherentViewport(2);
  const resized = await readViewport();
  assert.equal(resized.devicePixelRatio, 2);
  assert.equal(resized.status.dpr, 2);
  assert.equal(resized.backingWidth, Math.round(resized.cssWidth * resized.devicePixelRatio));
  assert.equal(resized.backingHeight, Math.round(resized.cssHeight * resized.devicePixelRatio));

  // Headless Chromium cannot switch the tab strip's active tab. Override the
  // standards-backed Document state and deliver its real visibilitychange event.
  await page.evaluate(() => {
    Object.defineProperty(document, "hidden", { configurable: true, value: true });
    Object.defineProperty(document, "visibilityState", { configurable: true, value: "hidden" });
    document.dispatchEvent(new Event("visibilitychange"));
  });
  const hiddenRafCount = await page.evaluate(() => window.__rafCalls);
  await page.waitForTimeout(160);
  assert.equal(await page.evaluate(() => window.__rafCalls), hiddenRafCount, "hidden viewport does not schedule frames");
  await page.evaluate(() => {
    delete document.hidden;
    delete document.visibilityState;
    document.dispatchEvent(new Event("visibilitychange"));
  });
  await page.waitForFunction(() => document.querySelector("#last-event")?.textContent === "page visible");
  await waitForCoherentViewport(2);

  // Context loss is surfaced as a typed renderer diagnostic; remount creates a fresh logical app.
  await canvas.evaluate((element) => element.dispatchEvent(new Event("contextlost", { cancelable: true })));
  await page.waitForFunction(() => document.querySelector("#diagnostic-code")?.textContent.startsWith("surface_lost"));
  await page.getByRole("button", { name: "Remount viewport" }).click();
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  await waitForCoherentViewport(2);
  assert.equal(await page.locator("#gpui-viewport").count(), 1);
  let remounted = await readViewport();
  assert.equal(remounted.devicePixelRatio, 2);
  assert.equal(remounted.status.dpr, 2);
  assert.ok(Math.abs(remounted.status.logicalWidth - remounted.cssWidth) < 0.1);
  assert.ok(Math.abs(remounted.status.logicalHeight - remounted.cssHeight) < 0.1);
  assert.equal(remounted.backingWidth, Math.round(remounted.cssWidth * 2));
  assert.equal(remounted.backingHeight, Math.round(remounted.cssHeight * 2));

  await page.getByRole("button", { name: "Remount viewport" }).click();
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  await waitForCoherentViewport(2);
  assert.equal(await page.locator("#gpui-viewport").count(), 1);
  remounted = await readViewport();
  assert.equal(remounted.devicePixelRatio, 2);
  assert.equal(remounted.status.dpr, 2);
  assert.ok(Math.abs(remounted.status.logicalWidth - remounted.cssWidth) < 0.1);
  assert.ok(Math.abs(remounted.status.logicalHeight - remounted.cssHeight) < 0.1);
  assert.equal(remounted.backingWidth, Math.round(remounted.cssWidth * 2), "remount reapplies the measured viewport instead of stale model defaults");
  assert.equal(remounted.backingHeight, Math.round(remounted.cssHeight * 2));
  assert.deepEqual(pageErrors, [], "browser callbacks and renderer complete without uncaught errors");
  await context.close();
  console.log("Browser smoke passed: Canvas2D snapshot, DPR, input/focus, resize/lifecycle, hidden-tab scheduling, context loss, and repeated teardown.");
} catch (error) {
  console.error("Browser smoke failed:", error);
  if (page) {
    try {
      writeFileSync(join(repoRoot, "_build/browser-smoke-status.json"), JSON.stringify({
        title: await page.title(),
        diagnostic: await page.locator("#diagnostic").textContent().catch(() => "unavailable"),
        body: await page.locator("body").innerText().catch(() => "unavailable"),
        viewport: await page.evaluate(async () => {
          const gpui = await import("./gpui-browser.js");
          const canvas = document.querySelector("#gpui-viewport");
          const bounds = canvas?.getBoundingClientRect();
          return {
            devicePixelRatio: window.devicePixelRatio,
            cssWidth: bounds?.width,
            cssHeight: bounds?.height,
            backingWidth: canvas?.width,
            backingHeight: canvas?.height,
            framework: JSON.parse(gpui.gpui_browser_status()),
            logicalLabel: document.querySelector("#logical-size")?.textContent,
            backingLabel: document.querySelector("#backing-size")?.textContent,
            scaleLabel: document.querySelector("#device-scale")?.textContent,
          };
        }).catch(() => null),
        pageErrors,
        consoleMessages,
      }, null, 2));
      await page.screenshot({ path: join(repoRoot, "_build/browser-smoke-failure.png"), fullPage: true });
    } catch (captureError) {
      console.error("Could not retain browser failure details:", captureError);
    }
  }
  throw error;
} finally {
  await browser?.close();
  await new Promise((resolveClose, rejectClose) => server.close((error) => error ? rejectClose(error) : resolveClose()));
}
