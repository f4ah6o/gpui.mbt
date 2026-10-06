# New strict Gio parser for recovery

This is newly authored recovery source. It is not byte recovery of the missing
historical `transport_diagnostics.py` and must never be assigned its old
`5bd5b0…` hash. The retained original lines80–180 are partial source evidence
only. New hashes and static tests are in `parser-manifest.json`; native
qualification remains pending for the newly constructed profile.

## API and scope

`parse_transport_log(text)` returns complete structured frame dictionaries.
It performs no bus connection, process launch, input, signal, warning filtering
or malformed-tail repair. Empty whitespace returns an empty list; the calling
qualification must require a nonzero exact expected event/message sequence.

Inputs must be the dedicated `G_DBUS_DEBUG=message` stdout channel with LF
framing. The existing evidence layer may demultiplex whole official Wayland
lines first; unexpected/unframed diagnostics still fail. Preserve the separate
Wayland/Gdk stderr stream and its diagnostics. A missing final LF, incomplete
header/body/descriptor section, extra tail, unknown header, duplicate header,
nested duplicate dictionary key, bad type/signature or invalid D-Bus name fails
closed. This bounded profile rejects all file descriptors and typed handles.

Actual GLib/Gio2.84.4 parses the headers and bodies. Type inference is checked
before parsing with the declared definite type: supplying an expected `u` can
otherwise coerce an explicit `int32`/`uint64` annotation under this version.
No Python evaluation is used. Raw and canonical body text are not interpreted
as instructions. Serial/byte-count lexical bounds, log/body/message-count and
variant-tree depth/node limits bound resource use. The logger-reported byte
count is positive/bounded metadata, not independently verified wire bytes.

Records retain direction, message type, flags, serial, frame ordinal, headers,
signature, canonical body and descriptor status. Exact sent InputContext
ProcessKeyEvent calls expose typed uint32 `keyval`, `keycode`, `state` and
`category=sent_process_key_event`. Received CommitText/UpdatePreeditText/
UpdatePreeditTextWithMode signals require their exact signatures and serialized
IBusText shape; they expose text, cursor/visibility/mode as applicable. Other
complete typed messages remain `category=other`, not synthetic key events.

## Static validation

From this helper directory:

```sh
PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest test_transport_diagnostics -v
```

The28 tests generate actual `Gio.DBusMessage.print(2)` / `to_blob` fixtures in
memory. They include typed keys, replies, context/focus, errors and IBusText
signals, plus adversarial type coercion, duplicate keys/headers, frame markers,
all incomplete EOF cuts, required final LF, unsupported descriptors/handles,
semantic names, uint boundaries, resource limits and quoted member lookalikes.
No bus, native desktop services or input are launched. Initial failed test logs
are retained; their type-coercion failures prompted the two-stage type check.

## Primary API references

- [GLib.Variant.parse](https://docs.gtk.org/glib/type_func.Variant.parse.html):
  definite type parsing and strict end-of-input when endptr is null.
- [GLib.Variant.is_signature](https://docs.gtk.org/glib/type_func.Variant.is_signature.html):
  validate D-Bus type signatures before constructing their types.
- [Gio.DBusMessage.print](https://docs.gtk.org/gio/method.DBusMessage.print.html):
  diagnostic formatting has no stable ABI guarantee. Future format changes
  require separate review and must not silently pass this parser.
- [Gio.dbus_is_name](https://docs.gtk.org/gio/func.dbus_is_name.html):
  semantic bus-name validation.

The new profile must pin this source, tests and its actual dependencies, then
receive independent review and fresh native qualification. Do not modify the
historical deployment lock to conceal missing original dependencies.
