import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import {
  existsSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const fixturePath = join(
  repoRoot,
  "tests/browser/dev_watch_fixture/dev_watch_fixture.mbt",
);
const compiledJsPath = join(
  repoRoot,
  "_build/js/debug/build/tests/browser/dev_watch_fixture/dev_watch_fixture.js",
);
const sourceMapPath = `${compiledJsPath}.map`;
const originalSource = readFileSync(fixturePath, "utf8");
const initialMarker = "watch-v1";
const updatedMarker = "watch-v2";
const watchdog = setTimeout(() => {
  console.error("Vite+ dev-watch watchdog expired.");
  process.exit(124);
}, 90_000);

assert.equal(
  originalSource.split(initialMarker).length - 1,
  1,
  "dev-watch fixture must contain the initial marker exactly once",
);

const initialBuild = spawnSync(
  process.env.MOON_BIN || "moon",
  [
    "build",
    "tests/browser/dev_watch_fixture",
    "--target",
    "js",
    "--debug",
    "--deny-warn",
  ],
  {
    cwd: repoRoot,
    encoding: "utf8",
  },
);
if (initialBuild.status !== 0) {
  process.stderr.write(initialBuild.stdout || "");
  process.stderr.write(initialBuild.stderr || "");
  throw new Error("initial MoonBit dev-watch fixture build failed");
}

assert.ok(existsSync(sourceMapPath), "MoonBit JS build must emit a source map");
const initialSourceMap = JSON.parse(readFileSync(sourceMapPath, "utf8"));
console.log("dev-watch: initial debug source map exists");
assert.ok(
  Array.isArray(initialSourceMap.sources) &&
    initialSourceMap.sources.some(
      (source) =>
        typeof source === "string" &&
        source.replaceAll("\\", "/").endsWith(
          "tests/browser/dev_watch_fixture/dev_watch_fixture.mbt",
        ),
    ),
  "MoonBit source map must reference the .mbt fixture source",
);

const serverLog = [];
const server = spawn(
  "vp",
  ["dev", "--host", "127.0.0.1", "--port", "5173", "--strictPort"],
  {
    cwd: repoRoot,
    env: process.env,
    stdio: ["ignore", "pipe", "pipe"],
    detached: process.platform !== "win32",
  },
);
server.stdout.on("data", (chunk) => serverLog.push(chunk.toString()));
server.stderr.on("data", (chunk) => serverLog.push(chunk.toString()));
const serverExit = new Promise((resolveExit) => {
  server.once("exit", (code, signal) => resolveExit({ code, signal }));
});

async function waitForServer() {
  const deadline = Date.now() + 30_000;
  let lastError;
  while (Date.now() < deadline) {
    if (server.exitCode !== null) {
      throw new Error(
        `Vite+ dev server exited before readiness:\n${serverLog.join("")}`,
      );
    }
    try {
      const response = await fetch("http://127.0.0.1:5173/dev-watch.html");
      if (response.ok) return;
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 250));
  }
  throw new Error(
    `Vite+ dev server did not become ready: ${lastError}\n${serverLog.join("")}`,
  );
}

async function waitForCompiledMarker(expected) {
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    if (
      existsSync(compiledJsPath) &&
      readFileSync(compiledJsPath, "utf8").includes(expected)
    ) {
      return;
    }
    if (server.exitCode !== null) {
      throw new Error(
        `Vite+ dev server exited while waiting for MoonBit rebuild:\n${serverLog.join("")}`,
      );
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
  }
  throw new Error(
    `MoonBit watch build did not emit ${JSON.stringify(expected)}:\n${serverLog.join("")}`,
  );
}

function signalServer(signal) {
  if (server.exitCode !== null) return;
  if (process.platform === "win32") {
    server.kill(signal);
    return;
  }
  try {
    process.kill(-server.pid, signal);
  } catch {
    server.kill(signal);
  }
}

async function stopServer() {
  if (server.exitCode !== null) return;
  signalServer("SIGTERM");
  const stopped = await Promise.race([
    serverExit.then(() => true),
    new Promise((resolveDelay) => setTimeout(() => resolveDelay(false), 5_000)),
  ]);
  if (!stopped && server.exitCode === null) {
    signalServer("SIGKILL");
    await Promise.race([
      serverExit,
      new Promise((resolveDelay) => setTimeout(resolveDelay, 5_000)),
    ]);
  }
}

let browser;
let fixtureChanged = false;
try {
  await waitForServer();
  console.log("dev-watch: Vite+ server ready");

  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.goto("http://127.0.0.1:5173/dev-watch.html", {
    waitUntil: "networkidle",
  });
  await page.waitForFunction(
    (expected) => document.body.dataset.devWatchMarker === expected,
    initialMarker,
  );
  assert.equal(
    await page.locator("#dev-watch-marker").textContent(),
    initialMarker,
  );
  console.log("dev-watch: Chromium observed watch-v1");

  writeFileSync(
    fixturePath,
    originalSource.replace(initialMarker, updatedMarker),
    "utf8",
  );
  fixtureChanged = true;
  console.log("dev-watch: MoonBit source changed to watch-v2");

  await waitForCompiledMarker(updatedMarker);
  console.log("dev-watch: plugin watch emitted watch-v2 JS");

  const refreshDeadline = Date.now() + 30_000;
  let observedMarker;
  while (Date.now() < refreshDeadline) {
    try {
      observedMarker = await page.evaluate(
        () => document.body.dataset.devWatchMarker,
      );
      if (observedMarker === updatedMarker) break;
    } catch {
      // A Vite full reload may temporarily destroy the execution context.
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
  }

  assert.equal(
    observedMarker,
    updatedMarker,
    "the already-open Vite page must refresh to the rebuilt MoonBit module",
  );
  assert.equal(
    await page.locator("#dev-watch-marker").textContent(),
    updatedMarker,
    "same-page refresh must render the updated MoonBit value",
  );
  assert.deepEqual(pageErrors, [], "dev-watch browser page must stay error-free");
  console.log("dev-watch: same Vite page refreshed to watch-v2");

  const rebuiltSourceMap = JSON.parse(readFileSync(sourceMapPath, "utf8"));
  assert.ok(
    rebuiltSourceMap.sources.some(
      (source) =>
        typeof source === "string" &&
        source.replaceAll("\\", "/").endsWith(
          "tests/browser/dev_watch_fixture/dev_watch_fixture.mbt",
        ),
    ),
    "rebuilt source map must retain the MoonBit source reference",
  );

  console.log("dev-watch: rebuilt source map retains .mbt reference");
  console.log(
    "Vite+ dev-watch passed: MoonBit edit rebuilt through vite-plugin-moonbit, the already-open Vite page refreshed to watch-v2, and the source map references the .mbt fixture.",
  );
} catch (error) {
  console.error("Vite+ dev-watch failed:", error);
  console.error("--- vp dev log ---");
  console.error(serverLog.join(""));
  throw error;
} finally {
  await browser?.close();
  await stopServer();
  if (fixtureChanged) writeFileSync(fixturePath, originalSource, "utf8");
  clearTimeout(watchdog);
}
