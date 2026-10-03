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
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  const initial = await page.evaluate(() => {
    const canvas = document.querySelector("#gpui-viewport");
    const bounds = canvas.getBoundingClientRect();
    const context = canvas.getContext("2d");
    const pixels = context.getImageData(Math.floor(canvas.width / 2), Math.floor(canvas.height / 2), 1, 1).data;
    const status = {
      logicalWidth: Number(document.querySelector("#logical-size").textContent.split(" × ")[0]),
      logicalHeight: Number(document.querySelector("#logical-size").textContent.split(" × ")[1].split(" ")[0]),
      scale: Number(document.querySelector("#device-scale").textContent.replace("×", "")),
    };
    return {
      width: canvas.width,
      height: canvas.height,
      cssWidth: bounds.width,
      cssHeight: bounds.height,
      pixel: Array.from(pixels),
      status,
    };
  });
  assert.equal(initial.width, Math.round(initial.cssWidth * 1.5));
  assert.equal(initial.height, Math.round(initial.cssHeight * 1.5));
  assert.ok(initial.pixel[0] !== 0 || initial.pixel[1] !== 0 || initial.pixel[2] !== 0, "the shared SceneSnapshot paints visible Canvas2D pixels");
  assert.equal(initial.status.scale, 1.5);
  assert.ok(initial.status.logicalWidth > 1 && initial.status.logicalHeight > 1);
  assert.ok((await page.locator("#capabilities li").count()) >= 8);
  const readFramework = () => page.evaluate(async () => JSON.parse((await import("./gpui-browser.js")).gpui_browser_status()));

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

  // Probe the shared layout by finding one of its focusable tile hit regions.
  const canvasBounds = await canvas.boundingBox();
  const targetPoint = { x: 120, y: 238 };
  await page.mouse.move(canvasBounds.x + targetPoint.x, canvasBounds.y + targetPoint.y);
  await page.waitForFunction(async () => [4, 5, 6, 7].includes(JSON.parse((await import("./gpui-browser.js")).gpui_browser_status()).hover));
  await page.mouse.click(canvasBounds.x + targetPoint.x, canvasBounds.y + targetPoint.y);
  await page.waitForFunction(() => Number(document.querySelector("#activation-count")?.textContent) >= 2);

  // Resize CSS layout, then change DPR live through Chromium's emulation boundary.
  await page.setViewportSize({ width: 1200, height: 880 });
  await page.waitForFunction(async () => {
    const status = JSON.parse((await import("./gpui-browser.js")).gpui_browser_status());
    const bounds = document.querySelector("#gpui-viewport").getBoundingClientRect();
    return Math.abs(status.logicalWidth - bounds.width) < 0.1 && Math.abs(status.logicalHeight - bounds.height) < 0.1;
  });
  const cdp = await context.newCDPSession(page);
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: 1200,
    height: 880,
    deviceScaleFactor: 2,
    mobile: false,
  });
  await page.waitForFunction(async () => {
    const status = JSON.parse((await import("./gpui-browser.js")).gpui_browser_status());
    return status.dpr === 2 && window.devicePixelRatio === 2;
  });
  const resized = await page.locator("#gpui-viewport").evaluate((element) => ({
    width: element.width,
    height: element.height,
    cssWidth: element.getBoundingClientRect().width,
    cssHeight: element.getBoundingClientRect().height,
  }));
  assert.equal(resized.width, Math.round(resized.cssWidth * 2));
  assert.equal(resized.height, Math.round(resized.cssHeight * 2));

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

  // Context loss is surfaced as a typed renderer diagnostic; remount creates a fresh logical app.
  await canvas.evaluate((element) => element.dispatchEvent(new Event("contextlost", { cancelable: true })));
  await page.waitForFunction(() => document.querySelector("#diagnostic-code")?.textContent.startsWith("surface_lost"));
  await page.getByRole("button", { name: "Remount viewport" }).click();
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  assert.equal(await page.locator("#gpui-viewport").count(), 1);
  let remounted = await page.locator("#gpui-viewport").evaluate((element) => ({
    width: element.width,
    height: element.height,
    cssWidth: element.getBoundingClientRect().width,
    cssHeight: element.getBoundingClientRect().height,
  }));
  let remountedStatus = await readFramework();
  assert.equal(remounted.width, Math.round(remounted.cssWidth * 2));
  assert.equal(remounted.height, Math.round(remounted.cssHeight * 2));
  assert.ok(Math.abs(remountedStatus.logicalWidth - remounted.cssWidth) < 0.1);
  assert.ok(Math.abs(remountedStatus.logicalHeight - remounted.cssHeight) < 0.1);
  assert.equal(remountedStatus.dpr, 2);

  await page.getByRole("button", { name: "Remount viewport" }).click();
  await page.waitForFunction(() => document.querySelector("#frame-state")?.textContent === "RUNNING");
  await page.waitForFunction(() => Number(document.querySelector("#sequence")?.textContent) >= 3);
  assert.equal(await page.locator("#gpui-viewport").count(), 1);
  remounted = await page.locator("#gpui-viewport").evaluate((element) => ({
    width: element.width,
    height: element.height,
    cssWidth: element.getBoundingClientRect().width,
    cssHeight: element.getBoundingClientRect().height,
  }));
  remountedStatus = await readFramework();
  assert.equal(remounted.width, Math.round(remounted.cssWidth * 2), "remount reapplies the measured viewport instead of stale model defaults");
  assert.equal(remounted.height, Math.round(remounted.cssHeight * 2));
  assert.ok(Math.abs(remountedStatus.logicalWidth - remounted.cssWidth) < 0.1);
  assert.ok(Math.abs(remountedStatus.logicalHeight - remounted.cssHeight) < 0.1);
  assert.equal(remountedStatus.dpr, 2);
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
        framework: await page.evaluate(async () => JSON.parse((await import("./gpui-browser.js")).gpui_browser_status())).catch(() => null),
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
