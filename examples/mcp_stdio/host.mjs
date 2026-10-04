import { once } from "node:events";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const MAX_LINE_BYTES = 1_048_576;

function usageError(message) {
  process.stderr.write(`${message}\n`);
  process.exitCode = 64;
}

function writeParseError(message) {
  return writeResponse({
    jsonrpc: "2.0",
    id: null,
    error: { code: -32700, message },
  });
}

async function writeResponse(response) {
  if (!process.stdout.write(`${JSON.stringify(response)}\n`)) {
    await once(process.stdout, "drain");
  }
}

async function main() {
  const compiledModule = process.argv[2];
  if (!compiledModule) {
    usageError("usage: node host.mjs <compiled-moonbit-js-module>");
    return;
  }

  const fixture = await import(pathToFileURL(resolve(compiledModule)).href);
  if (fixture.gpui_mcp_stdio_start() !== "started") {
    throw new Error("MoonBit MCP stdio fixture failed to start");
  }

  const utf8 = new TextDecoder("utf-8", { fatal: true });
  let lineBuffer = Buffer.allocUnsafe(0);
  let lineBytes = 0;
  let discardingOverlongLine = false;

  async function consumeLine() {
    if (discardingOverlongLine) {
      await writeParseError("Request exceeds the host line byte limit");
      return;
    }
    if (lineBytes === 0) return;

    let bytes = lineBuffer.subarray(0, lineBytes);
    if (bytes.at(-1) === 0x0d) bytes = bytes.subarray(0, -1);
    let line;
    try {
      line = utf8.decode(bytes);
    } catch {
      await writeParseError("Request is not valid UTF-8");
      return;
    }

    try {
      const response = fixture.gpui_mcp_stdio_handle_line(line);
      if (typeof response !== "string") {
        throw new Error("MoonBit protocol handler returned a non-string value");
      }
      if (response.length > 0) {
        if (!process.stdout.write(`${response}\n`)) {
          await once(process.stdout, "drain");
        }
      }
    } catch (error) {
      process.stderr.write(`MoonBit protocol handler failed: ${error?.message ?? error}\n`);
      process.exitCode = 1;
    }
  }

  function resetLine() {
    lineBytes = 0;
    discardingOverlongLine = false;
  }

  try {
    for await (const chunk of process.stdin) {
      let start = 0;
      while (start < chunk.length) {
        const newline = chunk.indexOf(0x0a, start);
        const end = newline < 0 ? chunk.length : newline;
        const part = chunk.subarray(start, end);

        if (!discardingOverlongLine) {
          if (lineBytes + part.length > MAX_LINE_BYTES) {
            lineBytes = 0;
            discardingOverlongLine = true;
          } else {
            const requiredBytes = lineBytes + part.length;
            if (requiredBytes > lineBuffer.length) {
              const capacity = Math.min(
                MAX_LINE_BYTES,
                Math.max(requiredBytes, Math.max(4096, lineBuffer.length * 2)),
              );
              const grown = Buffer.allocUnsafe(capacity);
              lineBuffer.copy(grown, 0, 0, lineBytes);
              lineBuffer = grown;
            }
            part.copy(lineBuffer, lineBytes);
            lineBytes = requiredBytes;
          }
        }

        if (newline < 0) break;
        await consumeLine();
        resetLine();
        start = newline + 1;
      }
    }

    // Like Node's readline interface, accept one final JSON line without LF.
    if (discardingOverlongLine || lineBytes > 0) await consumeLine();
  } finally {
    fixture.gpui_mcp_stdio_close();
  }
}

main().catch((error) => {
  process.stderr.write(`MCP stdio host failed: ${error?.stack ?? error}\n`);
  process.exitCode = 1;
});
