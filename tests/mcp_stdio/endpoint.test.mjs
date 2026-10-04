import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import test from "node:test";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { once } from "node:events";
import { pathToFileURL, fileURLToPath } from "node:url";

const repoRoot = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const hostPath = resolve(repoRoot, "examples/mcp_stdio/host.mjs");
const modulePath = resolve(
  repoRoot,
  "_build/js/release/build/examples/mcp_stdio/mcp_stdio.js",
);
const inventoryPath = resolve(
  repoRoot,
  "examples/mcp_stdio/fixtures/tools-list.json",
);
const protocolVersion = "2026-07-28";
const serverInfo = {
  name: "gpui-mbt-stdio-fixture",
  version: "0.1.0",
};
const requestMetadata = {
  "io.modelcontextprotocol/protocolVersion": protocolVersion,
  "io.modelcontextprotocol/clientCapabilities": {},
};
const resourceUri = "gpui://capability/counter_read";

function request(id, method, params = {}) {
  return {
    jsonrpc: "2.0",
    id,
    method,
    params: { ...params, _meta: requestMetadata },
  };
}

function notification(method, params = {}) {
  return { jsonrpc: "2.0", method, params };
}

function mcpLine(message) {
  return JSON.stringify(message) + "\n";
}

function assertServerInfo(result) {
  assert.deepEqual(result?._meta?.["io.modelcontextprotocol/serverInfo"], serverInfo);
}

function resourceValue(response) {
  const [content] = response.result.contents;
  assert.ok(content, "resource read returns one JSON text content");
  assert.equal(content.mimeType, "application/json");
  return JSON.parse(content.text);
}

async function runHost(inputChunks) {
  const child = spawn(process.execPath, [hostPath, modulePath], {
    cwd: repoRoot,
    stdio: ["pipe", "pipe", "pipe"],
  });
  const stdout = [];
  const stderr = [];
  child.stdout.on("data", (chunk) => stdout.push(chunk));
  child.stderr.on("data", (chunk) => stderr.push(chunk));

  const closed = once(child, "close");
  const watchdog = setTimeout(() => child.kill("SIGKILL"), 15_000);
  try {
    for (const chunk of inputChunks) child.stdin.write(chunk);
    child.stdin.end();
    const [code, signal] = await closed;
    const outputText = Buffer.concat(stdout).toString("utf8");
    const errorText = Buffer.concat(stderr).toString("utf8");
    const lines = outputText.split("\n").filter((line) => line.length > 0);
    return {
      code,
      signal,
      stdout: outputText,
      stderr: errorText,
      responses: lines.map((line) => JSON.parse(line)),
    };
  } finally {
    clearTimeout(watchdog);
    if (child.exitCode === null) child.kill("SIGKILL");
  }
}

test("compiled MoonBit capability shares state across GUI, direct, and MCP lanes", async () => {
  const fixture = await import(pathToFileURL(modulePath).href);
  const expectedInventory = JSON.parse(await readFile(inventoryPath, "utf8"));

  assert.equal(fixture.gpui_mcp_stdio_start(), "started");
  try {
    assert.deepEqual(JSON.parse(fixture.gpui_mcp_stdio_direct_read()), {
      ok: true,
      value: 0,
    });
    assert.deepEqual(JSON.parse(fixture.gpui_mcp_stdio_gui_add(2)), {
      ok: true,
      value: 2,
    });
    assert.deepEqual(JSON.parse(fixture.gpui_mcp_stdio_direct_add(3)), {
      ok: true,
      value: 5,
    });
    assert.deepEqual(JSON.parse(fixture.gpui_mcp_stdio_direct_read()), {
      ok: true,
      value: 5,
    });
    assert.deepEqual(
      JSON.parse(fixture.gpui_mcp_stdio_tools_inventory_json()),
      expectedInventory,
    );

    fixture.gpui_mcp_stdio_close();
    const closedProtocol = JSON.parse(
      fixture.gpui_mcp_stdio_handle_line(
        JSON.stringify(request(9, "server/discover")),
      ),
    );
    assert.equal(closedProtocol.error.message, "Server is closed");
    assert.equal(
      JSON.parse(fixture.gpui_mcp_stdio_direct_add(1)).code,
      "host_stopping",
    );

    // Only an explicit start begins a new fixture lifetime.
    assert.equal(fixture.gpui_mcp_stdio_start(), "started");
    assert.deepEqual(JSON.parse(fixture.gpui_mcp_stdio_direct_read()), {
      ok: true,
      value: 0,
    });
  } finally {
    fixture.gpui_mcp_stdio_close();
  }
});

test("actual Node stdio process serves the checked tools list and shared counter trace", async () => {
  const expectedInventory = JSON.parse(await readFile(inventoryPath, "utf8"));
  const messages = [
    request(1, "server/discover"),
    notification("notifications/initialized"),
    request(2, "tools/list"),
    request(3, "resources/list"),
    request(4, "resources/read", { uri: resourceUri }),
    request(5, "tools/call", {
      name: "counter_add",
      arguments: { value: 2 },
    }),
    notification("notifications/cancelled", { requestId: 5, reason: "late" }),
    request(6, "tools/call", {
      name: "counter_add",
      arguments: { value: 3 },
    }),
    request(7, "resources/read", { uri: resourceUri }),
    notification("notifications/cancelled", { requestId: 999, reason: "unknown" }),
    request(8, "resources/read", { uri: resourceUri }),
  ];

  // Use CRLF for delimited requests, then leave the final request unterminated.
  const terminated = messages
    .slice(0, -1)
    .map((message) => JSON.stringify(message))
    .join("\r\n") + "\r\n";
  const input = Buffer.from(
    terminated + JSON.stringify(messages[messages.length - 1]),
    "utf8",
  );
  const splitAt = Math.min(13, input.length);
  const outcome = await runHost([
    input.subarray(0, splitAt),
    input.subarray(splitAt, splitAt + 7),
    input.subarray(splitAt + 7),
  ]);

  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal(outcome.signal, null);
  assert.equal(outcome.stderr, "", "host diagnostics stay off protocol stdout");
  assert.equal(outcome.stdout.endsWith("\n"), true);
  const responses = outcome.responses;
  assert.deepEqual(
    responses.map((response) => response.id),
    [1, 2, 3, 4, 5, 6, 7, 8],
  );

  const byId = new Map(responses.map((response) => [response.id, response]));
  assert.deepEqual(byId.get(1).result.supportedVersions, [protocolVersion]);
  assertServerInfo(byId.get(1).result);
  assert.deepEqual(byId.get(2).result, expectedInventory);
  assertServerInfo(byId.get(2).result);
  assert.deepEqual(
    byId.get(3).result.resources.map((resource) => resource.uri),
    [resourceUri],
  );
  assertServerInfo(byId.get(3).result);

  // Same trace as the compiled GUI/direct fixture: 0, add 2 -> 2, add 3 -> 5.
  assert.equal(resourceValue(byId.get(4)), 0);
  assert.equal(byId.get(5).result.structuredContent, 2);
  assert.equal(byId.get(6).result.structuredContent, 5);
  assert.equal(resourceValue(byId.get(7)), 5);
  assert.equal(resourceValue(byId.get(8)), 5);
  for (const id of [4, 5, 6, 7, 8]) assertServerInfo(byId.get(id).result);
});

test("host bounds input by UTF-8 line bytes and resumes at the next newline", async () => {
  const overLimitByBytes = Buffer.from("é".repeat(524_289), "utf8");
  assert.ok(overLimitByBytes.length > 1_048_576);
  const nextRequest = Buffer.from(mcpLine(request(10, "server/discover")), "utf8");
  const outcome = await runHost([
    overLimitByBytes,
    Buffer.from("\n", "ascii"),
    nextRequest,
  ]);

  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal(outcome.stderr, "");
  assert.equal(outcome.responses.length, 2);
  assert.deepEqual(outcome.responses[0], {
    jsonrpc: "2.0",
    id: null,
    error: {
      code: -32700,
      message: "Request exceeds the host line byte limit",
    },
  });
  assert.equal(outcome.responses[1].id, 10);
  assertServerInfo(outcome.responses[1].result);
});

test("host rejects malformed UTF-8 without logging it to stdout", async () => {
  const outcome = await runHost([
    Buffer.from([0xc3, 0x28, 0x0a]),
    Buffer.from(mcpLine(request(11, "server/discover")), "utf8"),
  ]);

  assert.equal(outcome.code, 0, outcome.stderr);
  assert.equal(outcome.stderr, "");
  assert.equal(outcome.responses.length, 2);
  assert.equal(outcome.responses[0].error.code, -32700);
  assert.equal(outcome.responses[0].error.message, "Request is not valid UTF-8");
  assert.equal(outcome.responses[1].id, 11);
});
