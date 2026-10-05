import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserClipboard } from "../../examples/browser/site/clipboard.js";

const operations = ["clipboard.read_text", "clipboard.write_text"];
const request = (requestId, operation, input = null, scopeId = "1") => ({
  version: 1,
  requestId: String(requestId),
  scopeId,
  operation,
  input,
});

function createAdapter(clipboard, options = {}) {
  const adapter = createBrowserClipboard({
    clipboard,
    secureContext: true,
    allowedOperations: operations,
    ...options,
  });
  adapter.openScope("1");
  return adapter;
}

test("clipboard availability is detected without reading or assuming permission", async () => {
  let calls = 0;
  const adapter = createAdapter({
    readText() { calls += 1; return Promise.resolve(""); },
    writeText() { calls += 1; return Promise.resolve(); },
  }, { allowedOperations: [] });
  assert.deepEqual(adapter.availability(), {
    secureContext: true,
    readText: true,
    writeText: true,
    permission: "not-queried",
  });
  assert.equal(calls, 0);
  assert.deepEqual(adapter.capabilities(), []);
  const result = await adapter.dispatch(request(1, "clipboard.read_text"));
  assert.equal(result.error.code, "unsupported_capability");
  assert.equal(calls, 0);
  assert.equal("clipboard" in adapter, false);
  adapter.dispose();
});

test("clipboard round-trips Unicode through the shared scoped envelope", async () => {
  let text = "";
  const clipboard = {
    readText() { assert.equal(this, clipboard); return Promise.resolve(text); },
    writeText(value) { assert.equal(this, clipboard); text = value; return Promise.resolve(); },
  };
  const adapter = createAdapter(clipboard);
  const value = "日本語 · emoji 👩🏽‍💻 · e\u0301 · العربية\n\"quoted\"\\\u0000";
  const written = await adapter.dispatch(request("9007199254740993", "clipboard.write_text", value));
  assert.deepEqual(written, {
    version: 1,
    requestId: "9007199254740993",
    scopeId: "1",
    ok: true,
    value: null,
  });
  const read = await adapter.dispatch(request("9007199254740994", "clipboard.read_text"));
  assert.equal(read.value, value);
  assert.deepEqual(adapter.capabilities(), ["clipboard"]);
  adapter.dispose();
});

test("native read and write start synchronously within dispatch", async () => {
  const calls = [];
  const adapter = createAdapter({
    readText() { calls.push("read"); return Promise.resolve("text"); },
    writeText(value) { calls.push(value); return Promise.resolve(); },
  });
  const writing = adapter.dispatch(request(1, "clipboard.write_text", "write"));
  assert.deepEqual(calls, ["write"]);
  await writing;
  const reading = adapter.dispatch(request(2, "clipboard.read_text"));
  assert.deepEqual(calls, ["write", "read"]);
  await reading;
  adapter.dispose();
});

test("missing methods and insecure contexts report unsupported without native calls", async () => {
  for (const options of [
    { clipboard: undefined },
    { clipboard: {} },
    { clipboard: { readText: "not callable", writeText: null } },
    { secureContext: false },
  ]) {
    let invoked = false;
    const adapter = createAdapter({
      readText() { invoked = true; return Promise.resolve("private"); },
      writeText() { invoked = true; return Promise.resolve(); },
    }, options);
    assert.deepEqual(adapter.capabilities(), []);
    assert.equal(adapter.availability().readText, false);
    assert.equal(adapter.availability().writeText, false);
    assert.equal((await adapter.dispatch(request(1, "clipboard.read_text"))).error.code, "unsupported_capability");
    assert.equal((await adapter.dispatch(request(2, "clipboard.write_text", "value"))).error.code, "unsupported_capability");
    assert.equal(invoked, false);
    adapter.dispose();
  }

  const partial = createAdapter({ writeText() { return Promise.resolve(); } });
  assert.deepEqual(partial.availability(), {
    secureContext: true,
    readText: false,
    writeText: true,
    permission: "not-queried",
  });
  assert.equal((await partial.dispatch(request(1, "clipboard.read_text"))).error.code, "unsupported_capability");
  assert.equal((await partial.dispatch(request(2, "clipboard.write_text", ""))).ok, true);
  partial.dispose();
});

test("clipboard maps browser denial and native failure to typed recoverable errors", async () => {
  for (const [name, expectedCode] of [
    ["NotAllowedError", "permission_denied"],
    ["SecurityError", "permission_denied"],
    ["NotSupportedError", "unsupported_capability"],
    ["UnknownError", "native_failure"],
  ]) {
    let denied = true;
    const adapter = createAdapter({
      readText() {
        return denied ? Promise.reject(new DOMException("native message", name)) : Promise.resolve("recovered");
      },
      writeText() { throw new DOMException("native message", name); },
    });
    const read = await adapter.dispatch(request(1, "clipboard.read_text"));
    assert.equal(read.error.code, expectedCode);
    assert.equal(read.error.operation, "clipboard.read_text");
    const write = await adapter.dispatch(request(2, "clipboard.write_text", "text"));
    assert.equal(write.error.code, expectedCode);
    denied = false;
    assert.equal((await adapter.dispatch(request(3, "clipboard.read_text"))).value, "recovered");
    adapter.dispose();
  }
});

test("clipboard validates operation payloads before invoking the browser", async () => {
  let invoked = false;
  const adapter = createAdapter({
    readText() { invoked = true; return Promise.resolve(""); },
    writeText() { invoked = true; return Promise.resolve(); },
  });
  let id = 0;
  for (const value of [null, false, 42, {}, [], { text: "value" }]) {
    const result = await adapter.dispatch(request(++id, "clipboard.write_text", value));
    assert.equal(result.error.code, "invalid_input");
  }
  for (const value of ["", true, 0, {}, []]) {
    const result = await adapter.dispatch(request(++id, "clipboard.read_text", value));
    assert.equal(result.error.code, "invalid_input");
  }
  assert.equal(invoked, false);
  await assert.rejects(adapter.dispatch(request(++id, "clipboard.write_text", "x".repeat(1_048_577))), (error) => error.code === "resource_exhausted");
  assert.equal(invoked, false);
  assert.throws(() => createBrowserClipboard({ allowedOperations: ["storage.read"] }), (error) => error.code === "invalid_input");
  adapter.dispose();
});

test("clipboard results are bounded and must contain plain text", async () => {
  for (const [value, code] of [[{}, "native_failure"], ["x".repeat(1_048_577), "resource_exhausted"]]) {
    const adapter = createAdapter({ readText() { return Promise.resolve(value); } });
    const result = await adapter.dispatch(request(1, "clipboard.read_text"));
    assert.equal(result.ok, false);
    assert.equal(result.error.code, code);
    adapter.dispose();
  }
});

test("cancelled scopes and disposed adapters suppress stale async completions", async () => {
  for (const dispose of [false, true]) {
    for (const reject of [false, true]) {
      let resolvePending;
      let rejectPending;
      const adapter = createAdapter({
        readText() { return new Promise((resolve, rejectResult) => { resolvePending = resolve; rejectPending = rejectResult; }); },
      });
      const result = adapter.dispatch(request(1, "clipboard.read_text"));
      if (dispose) adapter.dispose();
      else adapter.cancelScope("1");
      if (reject) rejectPending(new DOMException("denied after teardown", "NotAllowedError"));
      else resolvePending("data from destroyed viewport");
      assert.equal(await result, null);
      if (dispose) {
        await assert.rejects(adapter.dispatch(request(2, "clipboard.read_text")), (error) => error.code === "host_stopping");
      } else {
        assert.equal((await adapter.dispatch(request(2, "clipboard.read_text"))).error.code, "stale_handle");
      }
      adapter.dispose();
      adapter.dispose();
    }
  }
});

test("clipboard dispatch inherits duplicate ID and in-flight bounds", async () => {
  const completions = [];
  const adapter = createAdapter({
    readText() { return new Promise((resolve) => { completions.push(resolve); }); },
  });
  const pending = [];
  for (let id = 1; id <= 256; id += 1) pending.push(adapter.dispatch(request(id, "clipboard.read_text")));
  assert.equal((await adapter.dispatch(request(257, "clipboard.read_text"))).error.code, "resource_exhausted");
  assert.equal((await adapter.dispatch(request(256, "clipboard.read_text"))).error.code, "stale_handle");
  assert.equal(completions.length, 256);
  adapter.cancelScope("1");
  for (const complete of completions) complete("stale");
  assert.deepEqual(await Promise.all(pending), Array(256).fill(null));
  adapter.dispose();
});
