import {
  HostBridgeError,
  completionFor,
  createHostServices,
} from "../../migration/host-services.js";

const READ_TEXT = "clipboard.read_text";
const WRITE_TEXT = "clipboard.write_text";

function clipboardError(error, operation) {
  if (error instanceof HostBridgeError) return error;
  if (error?.name === "NotAllowedError" || error?.name === "SecurityError") {
    return new HostBridgeError(
      "permission_denied",
      "Browser clipboard access requires permission and may require a user gesture.",
      operation,
    );
  }
  if (error?.name === "NotSupportedError") {
    return new HostBridgeError(
      "unsupported_capability",
      "The browser does not support this plain-text clipboard operation.",
      operation,
    );
  }
  return new HostBridgeError(
    "native_failure",
    "The browser could not complete the plain-text clipboard operation.",
    operation,
  );
}

/// A browser implementation of the existing versioned host-service contract.
/// Availability is only API detection: it never requests or assumes permission.
/// Call dispatch directly from the user's event handler, before awaiting other
/// work, so the native clipboard call keeps the current user activation.
export function createBrowserClipboard({
  allowedOperations = [],
  clipboard = globalThis.navigator?.clipboard,
  secureContext = globalThis.isSecureContext,
} = {}) {
  const availability = Object.freeze({
    secureContext: secureContext === true,
    readText: secureContext === true && typeof clipboard?.readText === "function",
    writeText: secureContext === true && typeof clipboard?.writeText === "function",
    permission: "not-queried",
  });
  const readText = availability.readText ? clipboard.readText.bind(clipboard) : null;
  const writeText = availability.writeText ? clipboard.writeText.bind(clipboard) : null;
  const allowed = [];
  for (const operation of allowedOperations) {
    if (operation !== READ_TEXT && operation !== WRITE_TEXT) {
      throw new HostBridgeError(
        "invalid_input",
        "The browser clipboard adapter grants only plain-text clipboard operations.",
      );
    }
    if ((operation === READ_TEXT && readText) || (operation === WRITE_TEXT && writeText)) {
      allowed.push(operation);
    }
  }

  const services = createHostServices((request) => {
    const { operation, input } = request;
    if ((operation === READ_TEXT && input !== null) ||
        (operation === WRITE_TEXT && typeof input !== "string")) {
      throw new HostBridgeError(
        "invalid_input",
        operation === READ_TEXT
          ? "clipboard.read_text requires null input."
          : "clipboard.write_text requires a plain string.",
        operation,
      );
    }

    let pending;
    try {
      // Do not await permission queries or schedule a microtask before this call.
      // The shared dispatcher also invokes this closure before its first await.
      pending = operation === READ_TEXT ? readText() : writeText(input);
    } catch (error) {
      throw clipboardError(error, operation);
    }
    return Promise.resolve(pending).then(
      (value) => {
        if (operation === READ_TEXT && typeof value !== "string") {
          throw new HostBridgeError(
            "native_failure",
            "The browser returned a non-text clipboard value.",
            operation,
          );
        }
        // The common encoder also enforces the bounded result/envelope size.
        return completionFor(request, operation === READ_TEXT ? value : null);
      },
      (error) => { throw clipboardError(error, operation); },
    );
  }, { allowedOperations: allowed });

  return Object.freeze({
    availability: () => availability,
    capabilities: services.capabilities,
    openScope: services.openScope,
    cancelScope: services.cancelScope,
    dispatch: services.dispatch,
    dispose: services.close,
  });
}
