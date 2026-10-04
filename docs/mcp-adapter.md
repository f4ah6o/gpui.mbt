# MCP adapter and stdio fixture

`mcp/` is an optional transport layer over the typed capability registry. An
application opts in by registering capabilities with `External` exposure and
constructing an `Adapter` and `ProtocolServer`. Calls still enter the same
registry and invoke the registered typed handler; the protocol layer does not
own application state or duplicate domain behavior.

For app-owned operations, create the semantic registry with
`Registry::new_owned(app)` or adopt it with `registry.attach_owner(app)` before
exposing the adapter. App stop invalidates direct/GUI calls, tool/resource calls,
request-ID replays, and late completions without a separate registry teardown.
The adapter reports `Stale` after owner shutdown; calls before app start report
`Unavailable`. See the [owner lifecycle contract](capability-lifecycle.md).

The router implements the stateless modern MCP revision `2026-07-28`: every
request supplies `_meta["io.modelcontextprotocol/protocolVersion"]` and
`_meta["io.modelcontextprotocol/clientCapabilities"]`. `clientInfo` is optional.
The server exposes `server/discover`, `tools/list`, `tools/call`,
`resources/list`, and `resources/read`. It reports only those capabilities,
returns structured tool results matching the registered output schema, and
places its identity in each result's
`_meta["io.modelcontextprotocol/serverInfo"]`. Discovery and inventory/read
results use `ttlMs: 0` and `cacheScope: "private"` because application data can
change between requests. Unsupported protocol versions return `-32022` with
the supported version list. This router does not implement legacy `initialize`
handshake behavior.

MCP requires every tool `inputSchema` to be an object. Record inputs are
projected directly; scalar inputs use an object with a required `value`
property; unit inputs use a closed empty object. The dispatcher unwraps those
shapes and decodes values using the registered schema, so JSON integer-looking
numbers remain `NumberValue` for `number` schemas while `integer` inputs become
bounded `IntValue`s. Nested records, arrays, optional fields, and tagged
variants follow the same recursive mapping. Domain validation errors are
returned as complete tool results with `isError: true`; malformed calls and
unknown tools use JSON-RPC errors.

The checked headless host in `examples/mcp_stdio/` compiles MoonBit handlers to
JavaScript and runs them behind a Node stdio process. Each input line is one
UTF-8 JSON-RPC message; each response is one JSON line on stdout. The host keeps
logs on stderr and closes the adapter on EOF. The transport boundary rejects
frames larger than 1 MiB, JSON deeper than 32 levels, more than 10,000 JSON
nodes, and duplicate object keys before request dispatch. Generated tool
inventory is checked against its fixture so schema drift is reviewable.

Run the endpoint regression and generated-inventory drift check with:

```sh
sh scripts/test_mcp_stdio.sh
```

The `ProtocolServer` handlers are synchronous. `notifications/cancelled` is
accepted as a no-response notification, but it cannot interrupt an already
running handler. Closing the adapter prevents later dispatch; it cannot undo a
handler that has already committed. EOF ends the host process cleanly and does
not imply cancellation or rollback of completed effects. A native or browser
endpoint and true asynchronous cancellation require a separate host lifecycle
implementation.

The protocol behavior follows the pinned official MCP references:

- [Versioning and compatibility, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning)
- [Stdio transport, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/stdio)
- [Discovery, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/server/discover)
- [Tools, 2026-07-28](https://modelcontextprotocol.io/specification/2026-07-28/server/tools)
