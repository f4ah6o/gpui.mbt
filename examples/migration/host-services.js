const SERVICE_FOR_OPERATION = new Map([
  ["clipboard.read_text", "clipboard"],
  ["clipboard.write_text", "clipboard"],
  ["file_dialog.open", "file_dialog"],
  ["file_dialog.save", "file_dialog"],
  ["file_system.read_text", "file_system"],
  ["file_system.write_text", "file_system"],
  ["notifications.show", "notifications"],
  ["shell.open_external_url", "shell"],
  ["storage.read", "persistent_storage"],
  ["storage.write", "persistent_storage"],
  ["storage.remove", "persistent_storage"],
  ["window.minimize", "window_controls"],
  ["window.toggle_maximize", "window_controls"],
  ["window.close", "window_controls"],
  ["application.metadata_read", "application_metadata"],
  ["process.environment_read", "process_environment"],
  ["updates.check", "updates"],
  ["updates.install", "updates"],
  ["lifecycle.quit", "lifecycle"],
]);

const ERROR_CODES = new Set([
  "unsupported_capability",
  "permission_denied",
  "invalid_input",
  "resource_exhausted",
  "native_failure",
  "host_stopping",
  "stale_handle",
]);

const MAX_VALUE_NODES = 10_000;
const MAX_VALUE_DEPTH = 32;
const MAX_VALUE_BYTES = 1_048_576;
const MAX_PENDING_REQUESTS = 256;
const MAX_ACTIVE_SCOPES = 1024;
const MAX_REQUEST_ID = 0xffff_ffff_ffff_ffffn;

export class HostBridgeError extends Error {
  constructor(code, message, operation = "host_service.dispatch") {
    super(message);
    this.name = "HostBridgeError";
    this.code = code;
    this.operation = operation;
  }
}

function isPlainObject(value) {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return false;
  const prototype = Object.getPrototypeOf(value);
  return prototype === Object.prototype || prototype === null;
}

function freezeValue(value) {
  if (Array.isArray(value)) {
    for (const child of value) freezeValue(child);
    return Object.freeze(value);
  }
  if (isPlainObject(value)) {
    for (const child of Object.values(value)) freezeValue(child);
    return Object.freeze(value);
  }
  return value;
}

function addValueBytes(state, bytes) {
  state.bytes += bytes;
  if (state.bytes > MAX_VALUE_BYTES) {
    throw new HostBridgeError("resource_exhausted", "host-service value exceeds the transport size limit");
  }
}

function jsonStringByteLength(value) {
  if (value.length > MAX_VALUE_BYTES) {
    throw new HostBridgeError("resource_exhausted", "host-service string exceeds the transport size limit");
  }
  let bytes = 2;
  for (const character of value) {
    const codePoint = character.codePointAt(0);
    if (character === '"' || character === "\\" || codePoint === 0x08 || codePoint === 0x09 || codePoint === 0x0a || codePoint === 0x0c || codePoint === 0x0d) {
      bytes += 2;
    } else if (codePoint < 0x20 || (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      bytes += 6;
    } else if (codePoint < 0x80) {
      bytes += 1;
    } else if (codePoint < 0x800) {
      bytes += 2;
    } else if (codePoint < 0x10000) {
      bytes += 3;
    } else {
      bytes += 4;
    }
    if (bytes > MAX_VALUE_BYTES) {
      throw new HostBridgeError("resource_exhausted", "host-service string exceeds the transport size limit");
    }
  }
  return bytes;
}

function objectByteLength(fields) {
  let bytes = 2 + Math.max(0, fields.length - 1);
  for (const [key, valueBytes] of fields) {
    bytes += jsonStringByteLength(key) + 1 + valueBytes;
    if (bytes > MAX_VALUE_BYTES) {
      throw new HostBridgeError("resource_exhausted", "host-service envelope exceeds the transport size limit");
    }
  }
  return bytes;
}

function validateValue(value, state = { nodes: 0, bytes: 0 }, depth = 0) {
  state.nodes += 1;
  if (state.nodes > MAX_VALUE_NODES || depth > MAX_VALUE_DEPTH) {
    throw new HostBridgeError("invalid_input", "host-service value exceeds the transport limits");
  }
  if (value === null) {
    addValueBytes(state, 4);
    return value;
  }
  if (typeof value === "string") {
    addValueBytes(state, jsonStringByteLength(value));
    return value;
  }
  if (typeof value === "boolean") {
    addValueBytes(state, value ? 4 : 5);
    return value;
  }
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new HostBridgeError("invalid_input", "host-service numbers must be finite");
    addValueBytes(state, JSON.stringify(value).length);
    return value;
  }
  if (Array.isArray(value)) {
    if (value.length > 9_999) throw new HostBridgeError("invalid_input", "host-service arrays exceed the portable value limit");
    if (Object.keys(value).length !== value.length) {
      throw new HostBridgeError("invalid_input", "host-service arrays must be dense and have no extra properties");
    }
    addValueBytes(state, 2);
    const copied = [];
    for (let index = 0; index < value.length; index += 1) {
      if (!Object.hasOwn(value, index)) throw new HostBridgeError("invalid_input", "host-service arrays must not contain holes");
      if (index > 0) addValueBytes(state, 1);
      copied.push(validateValue(value[index], state, depth + 1));
    }
    return copied;
  }
  if (!isPlainObject(value)) throw new HostBridgeError("invalid_input", "host-service objects must be plain JSON records");
  const keys = Object.keys(value);
  if (keys.length > 1_024) throw new HostBridgeError("invalid_input", "host-service objects exceed the portable field limit");
  addValueBytes(state, 2);
  const result = Object.create(null);
  for (let index = 0; index < keys.length; index += 1) {
    const key = keys[index];
    if (["__proto__", "constructor", "prototype"].includes(key)) {
      throw new HostBridgeError("invalid_input", "host-service object contains a reserved property");
    }
    if (index > 0) addValueBytes(state, 1);
    addValueBytes(state, jsonStringByteLength(key) + 1);
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !("value" in descriptor)) {
      throw new HostBridgeError("invalid_input", "host-service objects must contain data properties only");
    }
    const child = descriptor.value;
    result[key] = validateValue(child, state, depth + 1);
  }
  return result;
}

function exactKeys(value, expected, label) {
  if (!isPlainObject(value)) throw new HostBridgeError("invalid_input", `${label} must be a plain object`);
  const actual = Object.keys(value).sort();
  const sortedExpected = [...expected].sort();
  if (actual.length !== sortedExpected.length || actual.some((key, index) => key !== sortedExpected[index])) {
    throw new HostBridgeError("invalid_input", `${label} has an invalid field set`);
  }
}

function decimalId(value, label) {
  if (typeof value !== "string" || !/^[1-9][0-9]{0,19}$/.test(value)) {
    throw new HostBridgeError("invalid_input", `${label} must be a positive UInt64 decimal string`);
  }
  const integer = BigInt(value);
  if (integer > MAX_REQUEST_ID) throw new HostBridgeError("invalid_input", `${label} exceeds UInt64`);
  return value;
}

export function validateHostRequest(request) {
  exactKeys(request, ["version", "requestId", "scopeId", "operation", "input"], "host-service request");
  if (request.version !== 1) throw new HostBridgeError("invalid_input", "unsupported host-service protocol version");
  const requestId = decimalId(request.requestId, "requestId");
  const scopeId = decimalId(request.scopeId, "scopeId");
  if (!SERVICE_FOR_OPERATION.has(request.operation)) {
    throw new HostBridgeError("unsupported_capability", "host-service operation is not in the portable contract");
  }
  const valueState = { nodes: 0, bytes: 0 };
  const input = freezeValue(validateValue(request.input, valueState));
  const envelopeBytes = objectByteLength([
    ["version", 1],
    ["requestId", jsonStringByteLength(requestId)],
    ["scopeId", jsonStringByteLength(scopeId)],
    ["operation", jsonStringByteLength(request.operation)],
    ["input", valueState.bytes],
  ]);
  if (envelopeBytes > MAX_VALUE_BYTES) {
    throw new HostBridgeError("resource_exhausted", "host-service request exceeds the transport size limit");
  }
  return Object.freeze({ version: 1, requestId, scopeId, operation: request.operation, input });
}

export function completionFor(request, value) {
  const input = validateHostRequest(request);
  const valueState = { nodes: 0, bytes: 0 };
  const copiedValue = freezeValue(validateValue(value, valueState));
  objectByteLength([
    ["version", 1],
    ["requestId", jsonStringByteLength(input.requestId)],
    ["scopeId", jsonStringByteLength(input.scopeId)],
    ["ok", 4],
    ["value", valueState.bytes],
  ]);
  return Object.freeze({
    version: 1,
    requestId: input.requestId,
    scopeId: input.scopeId,
    ok: true,
    value: copiedValue,
  });
}

function failureFor(request, error) {
  const input = validateHostRequest(request);
  const code = ERROR_CODES.has(error?.code) ? error.code : "native_failure";
  const message = typeof error?.message === "string" ? error.message.slice(0, 256) : "host service failed";
  return Object.freeze({
    version: 1,
    requestId: input.requestId,
    scopeId: input.scopeId,
    ok: false,
    error: Object.freeze({ code, operation: input.operation, message }),
  });
}

function validateReply(request, reply) {
  const input = validateHostRequest(request);
  if (!isPlainObject(reply) || reply.version !== 1 || reply.requestId !== input.requestId || reply.scopeId !== input.scopeId || typeof reply.ok !== "boolean") {
    throw new HostBridgeError("stale_handle", "host-service response does not match the active request", input.operation);
  }
  if (reply.ok) {
    exactKeys(reply, ["version", "requestId", "scopeId", "ok", "value"], "host-service response");
    return completionFor(input, reply.value);
  }
  exactKeys(reply, ["version", "requestId", "scopeId", "ok", "error"], "host-service response");
  exactKeys(reply.error, ["code", "operation", "message"], "host-service error");
  if (!isPlainObject(reply.error) || reply.error.operation !== input.operation || typeof reply.error.message !== "string" || !ERROR_CODES.has(reply.error.code)) {
    throw new HostBridgeError("invalid_input", "host-service error response is invalid", input.operation);
  }
  return failureFor(input, reply.error);
}

function operationAllowlist(operations) {
  const allowed = new Set();
  for (const operation of operations) {
    if (!SERVICE_FOR_OPERATION.has(operation)) {
      throw new HostBridgeError("invalid_input", `unknown host-service operation: ${String(operation)}`);
    }
    allowed.add(operation);
  }
  return allowed;
}

function makeAdapter(invoke, operations) {
  if (typeof invoke !== "function") throw new TypeError("host-service adapter requires an invoke function");
  const allowed = operationAllowlist(operations);
  let lastRequestId = 0n;
  let lastScopeId = 0n;
  let closed = false;
  const pending = new Map();
  const activeScopes = new Set();

  const adapter = {
    capabilities() {
      const families = new Set([...allowed].map((operation) => SERVICE_FOR_OPERATION.get(operation)));
      return Object.freeze([...families].sort());
    },

    openScope(scopeId) {
      if (closed) throw new HostBridgeError("host_stopping", "host-service adapter is closed");
      const canonical = decimalId(scopeId, "scopeId");
      const scopeNumber = BigInt(canonical);
      if (scopeNumber <= lastScopeId || activeScopes.has(canonical)) {
        throw new HostBridgeError("stale_handle", "logical service scope id is duplicate or out of order");
      }
      if (activeScopes.size >= MAX_ACTIVE_SCOPES) {
        throw new HostBridgeError("resource_exhausted", "host-service adapter reached the live scope limit");
      }
      lastScopeId = scopeNumber;
      activeScopes.add(canonical);
      return true;
    },

    cancelScope(scopeId) {
      const canonical = decimalId(scopeId, "scopeId");
      activeScopes.delete(canonical);
      for (const [requestId, request] of pending) {
        if (request.scopeId === canonical) pending.delete(requestId);
      }
    },

    async dispatch(rawRequest) {
      let request;
      try {
        if (closed) throw new HostBridgeError("host_stopping", "host-service adapter is closed");
        request = validateHostRequest(rawRequest);
        const requestNumber = BigInt(request.requestId);
        if (requestNumber <= lastRequestId || pending.has(request.requestId)) {
          throw new HostBridgeError("stale_handle", "host-service request id is duplicate or out of order", request.operation);
        }
        lastRequestId = requestNumber;
        if (!activeScopes.has(request.scopeId)) {
          return failureFor(request, new HostBridgeError("stale_handle", "logical service scope has been destroyed", request.operation));
        }
        if (!allowed.has(request.operation)) {
          return failureFor(request, new HostBridgeError("unsupported_capability", "host adapter did not grant this operation", request.operation));
        }
        if (pending.size >= MAX_PENDING_REQUESTS) {
          return failureFor(request, new HostBridgeError("resource_exhausted", "host adapter reached the in-flight request limit", request.operation));
        }
        pending.set(request.requestId, request);
        let rawReply;
        try {
          rawReply = await invoke(request);
        } catch (error) {
          if (pending.get(request.requestId) !== request) return null;
          pending.delete(request.requestId);
          return failureFor(request, error);
        }
        if (pending.get(request.requestId) !== request) return null;
        pending.delete(request.requestId);
        return validateReply(request, rawReply);
      } catch (error) {
        if (request) return failureFor(request, error);
        throw error;
      }
    },

    close() {
      closed = true;
      pending.clear();
      activeScopes.clear();
    },
  };
  return Object.freeze(adapter);
}

/// Shared scoped dispatcher for repository-owned host adapters. Operation
/// grants remain explicit; browser/native handles stay inside the invoke closure.
export function createHostServices(invoke, { allowedOperations = [] } = {}) {
  return makeAdapter(invoke, allowedOperations);
}

/// Electron renderer APIs are exposed only through contextBridge. The channel
/// is fixed and each portable operation still needs an explicit allowlist.
export function createElectronHostServices(ipcRenderer, { allowedOperations = [] } = {}) {
  if (!ipcRenderer || typeof ipcRenderer.invoke !== "function") {
    throw new TypeError("Electron host services require ipcRenderer.invoke");
  }
  return makeAdapter(
    (request) => ipcRenderer.invoke("gpui:host-service:v1", request),
    allowedOperations,
  );
}

/// Tauri command names are host-owned and bound one-by-one. An empty mapping
/// exposes no command, and renderer input can never select an arbitrary command.
export function createTauriHostServices(invoke, { commands = {} } = {}) {
  const entries = Object.entries(commands);
  const byOperation = new Map();
  for (const [operation, command] of entries) {
    if (!SERVICE_FOR_OPERATION.has(operation) || typeof command !== "string" || command.length === 0) {
      throw new HostBridgeError("invalid_input", "Tauri host command mapping is invalid");
    }
    byOperation.set(operation, command);
  }
  return makeAdapter(
    (request) => {
      const command = byOperation.get(request.operation);
      if (!command) throw new HostBridgeError("unsupported_capability", "Tauri command is not allowlisted", request.operation);
      return invoke(command, { request });
    },
    byOperation.keys(),
  );
}

/// Example preload installer. Applications must pass their explicit operation
/// grants and should mirror that allowlist in the main-process handler.
export function installElectronContextBridge({ contextBridge, ipcRenderer, allowedOperations = [] }) {
  if (!contextBridge || typeof contextBridge.exposeInMainWorld !== "function") {
    throw new TypeError("Electron host services require contextBridge.exposeInMainWorld");
  }
  const services = createElectronHostServices(ipcRenderer, { allowedOperations });
  contextBridge.exposeInMainWorld("gpuiHostServices", services);
  return services;
}
