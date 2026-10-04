import { resolve } from "node:path";
import { pathToFileURL } from "node:url";

const compiledModule = process.argv[2];
if (!compiledModule) {
  process.stderr.write("usage: node inventory.mjs <compiled-moonbit-js-module>\n");
  process.exitCode = 64;
} else {
  try {
    const fixture = await import(pathToFileURL(resolve(compiledModule)).href);
    if (fixture.gpui_mcp_stdio_start() !== "started") {
      throw new Error("MoonBit MCP stdio fixture failed to start");
    }
    try {
      const inventory = JSON.parse(fixture.gpui_mcp_stdio_tools_inventory_json());
      process.stdout.write(`${JSON.stringify(inventory, null, 2)}\n`);
    } finally {
      fixture.gpui_mcp_stdio_close();
    }
  } catch (error) {
    process.stderr.write(`Could not generate tools inventory: ${error?.stack ?? error}\n`);
    process.exitCode = 1;
  }
}
