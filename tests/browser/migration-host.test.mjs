import assert from "node:assert/strict";
import test from "node:test";
import {
  createElectronHostServices,
  createTauriHostServices,
  completionFor,
  validateHostRequest,
} from "../../examples/migration/host-services.js";

const request = (requestId, scopeId, operation, input = null) => ({
  version: 1,
  requestId: String(requestId),
  scopeId: String(scopeId),
  operation,
  input,
});

const reply = (source, value) => ({
  version: 1,
  requestId: source.requestId,
  scopeId: source.scopeId,
  ok: true,
  value,
});

test("Electron service bridge is default-deny and exposes no renderer IPC handle", async () => {
  let invoked = false;
  const adapter = createElectronHostServices({
    invoke: async () => { invoked = true; },
  });

  adapter.openScope("1");
  assert.deepEqual(adapter.capabilities(), []);
  const result = await adapter.dispatch(request(1, 1, "file_system.read_text", { path: "/private/data" }));
  assert.equal(invoked, false);
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "unsupported_capability");
  assert.equal("ipcRenderer" in adapter, false);
  assert.equal("send" in adapter, false);
  adapter.cancelScope("1");
  const stale = await adapter.dispatch(request(2, 1, "clipboard.read_text"));
  assert.equal(stale.error.code, "stale_handle");
});

test("Electron service bridge allowlists one operation and preserves UInt64 IDs", async () => {
  const calls = [];
  const adapter = createElectronHostServices({
    invoke: async (...args) => {
      calls.push(args);
      return reply(args[1], "clipboard text");
    },
  }, { allowedOperations: ["clipboard.read_text"] });
  const source = request("9007199254740993", "9007199254740995", "clipboard.read_text");
  adapter.openScope(source.scopeId);
  const result = await adapter.dispatch(source);

  assert.deepEqual(adapter.capabilities(), ["clipboard"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "gpui:host-service:v1");
  assert.equal(calls[0][1].requestId, "9007199254740993");
  assert.deepEqual(result, {
    version: 1,
    requestId: "9007199254740993",
    scopeId: "9007199254740995",
    ok: true,
    value: "clipboard text",
  });
});

test("Electron service bridge rejects duplicate or out-of-order IDs", async () => {
  const adapter = createElectronHostServices({
    invoke: async (_channel, source) => reply(source, true),
  }, { allowedOperations: ["storage.read"] });

  adapter.openScope("1");
  assert.equal((await adapter.dispatch(request(2, 1, "storage.read"))).ok, true);
  const duplicate = await adapter.dispatch(request(2, 1, "storage.read"));
  const older = await adapter.dispatch(request(1, 1, "storage.read"));
  assert.equal(duplicate.error.code, "stale_handle");
  assert.equal(older.error.code, "stale_handle");
});

test("late async completion is dropped after logical scope cancellation", async () => {
  let resolveInvoke;
  const adapter = createElectronHostServices({
    invoke: () => new Promise((resolve) => { resolveInvoke = resolve; }),
  }, { allowedOperations: ["clipboard.read_text"] });
  const source = request(1, 18, "clipboard.read_text");
  adapter.openScope(source.scopeId);
  const dispatched = adapter.dispatch(source);
  await Promise.resolve();
  adapter.cancelScope("18");
  resolveInvoke(reply(source, "stale clipboard data"));

  assert.equal(await dispatched, null);
});

test("Tauri bridge binds portable operations to fixed commands", async () => {
  const calls = [];
  const adapter = createTauriHostServices(async (...args) => {
    calls.push(args);
    return reply(args[1].request, { selected: true });
  }, { commands: { "file_dialog.open": "open_import_file" } });

  adapter.openScope("4");
  const allowed = await adapter.dispatch(request(1, 4, "file_dialog.open", { multiple: false }));
  const denied = await adapter.dispatch(request(2, 4, "file_dialog.save", { suggestedName: "x.txt" }));
  assert.deepEqual(adapter.capabilities(), ["file_dialog"]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0][0], "open_import_file");
  assert.equal(allowed.value.selected, true);
  assert.equal(denied.error.code, "unsupported_capability");
});

test("bridge validation rejects non-JSON values, reserved keys, and bad envelopes", () => {
  assert.throws(() => validateHostRequest(request(1, 1, "storage.read", { value: Number.NaN })), /finite/);
  const unsafe = JSON.parse('{"__proto__":{"polluted":true}}');
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", unsafe)), /reserved property/);
  assert.throws(() => validateHostRequest({ ...request(1, 1, "storage.read"), extra: true }), /field set/);
  assert.throws(() => validateHostRequest(request(1, 1, "renderer.execute", "anything")), /not in the portable contract/);
  const sparse = [];
  sparse.length = 1;
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", sparse)), /dense/);
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", [undefined])), /plain JSON records/);
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", "x".repeat(1_048_577))), /transport size limit/);
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", { ["k".repeat(1_048_577)]: 1 })), /transport size limit/);
  const tooManyFields = Object.fromEntries(Array.from({ length: 1_025 }, (_, index) => [`field${index}`, index]));
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", tooManyFields)), /field limit/);
  assert.throws(() => validateHostRequest(request(1, 1, "storage.write", "x".repeat(1_048_500))), /envelope exceeds the transport size limit/);
  assert.throws(() => completionFor(request(1, 1, "storage.read"), "x".repeat(1_048_577)), /transport size limit/);
  assert.throws(() => completionFor(request(1, 1, "storage.read"), "x".repeat(1_048_520)), /envelope exceeds the transport size limit/);
});

test("validated request and completion payloads are owned and immutable copies", () => {
  const source = request(1, 1, "storage.write", { nested: ["before"] });
  const checked = validateHostRequest(source);
  source.input.nested[0] = "changed";
  assert.equal(checked.input.nested[0], "before");
  assert.throws(() => { checked.input.nested[0] = "mutated"; }, TypeError);

  const output = { nested: ["before"] };
  const completion = completionFor(request(1, 1, "storage.read"), output);
  output.nested[0] = "changed";
  assert.equal(completion.value.nested[0], "before");
  assert.throws(() => { completion.value.nested[0] = "mutated"; }, TypeError);
});

test("oversized host replies are rejected before they reach the portable caller", async () => {
  const large = "x".repeat(1_048_577);
  const adapter = createElectronHostServices({
    invoke: async (_channel, source) => reply(source, large),
  }, { allowedOperations: ["storage.read"] });
  adapter.openScope("1");
  const result = await adapter.dispatch(request(1, 1, "storage.read"));
  assert.equal(result.ok, false);
  assert.equal(result.error.code, "resource_exhausted");
});

test("host adapters bound in-flight work and active scopes", async () => {
  const completions = [];
  const adapter = createElectronHostServices({
    invoke: () => new Promise((resolve) => { completions.push(resolve); }),
  }, { allowedOperations: ["storage.read"] });
  adapter.openScope("1");
  const requests = [];
  for (let id = 1; id <= 256; id += 1) {
    requests.push(adapter.dispatch(request(id, 1, "storage.read")));
  }
  const rejected = await adapter.dispatch(request(257, 1, "storage.read"));
  assert.equal(rejected.error.code, "resource_exhausted");
  adapter.cancelScope("1");
  for (const complete of completions) complete(null);
  await Promise.all(requests);

  const scopeAdapter = createElectronHostServices({ invoke: async () => null });
  for (let scope = 1; scope <= 1024; scope += 1) scopeAdapter.openScope(String(scope));
  assert.throws(() => scopeAdapter.openScope("1025"), /live scope limit/);
});
