# Presented-state observer for Linux input E2E

The interactive example is unchanged unless `GPUI_FIELD_E2E_STATE=1` is set.
With that exact opt-in, each successful `Accepted` presentation emits one
flushed stdout line after `shown = field`:

```text
GPUI_FIELD_STATE {"version":1,"presentation":1,"text":"Hello 日本","selection":{"anchor":0,"head":0},"focused":false,"revision":0}
```

The version-1 object has exactly these fields:

- `version`: integer `1`.
- `presentation`: positive integer, incremented for each observed successful
  presentation, including redraws of an unchanged document.
- `text`: the presented field's document text, encoded as a JSON string.
- `selection`: integer `anchor` and `head` offsets in UTF-16 code units. The
  direction is retained; offsets are not UTF-8 bytes or grapheme indexes.
- `focused`: boolean field focus state.
- `revision`: the presented field's integer model revision. Navigation and
  focus changes may advance it without changing text.

This is an example-local read-only oracle, not a production debugging API or
input surface. It never injects edits, calls input callbacks, runs commands,
or writes files. Busy, rejected and failed presentations emit no state line.
The environment flag is read once at startup. The existing
`GPUI_FIELD_FIXTURES=1` synthetic fixture mode does not use this observer.

Use only non-sensitive synthetic test text: the observer deliberately puts
the entire document in stdout. Redirect stdout to a private test artifact
outside the repository. The opt-in emitter flushes stdout so live checkpoint
readers need not wait for exit. Ignore unrelated diagnostic lines, validate
the prefix and version-1 schema, and keep the full log for review.

For genuine OS-input cases, drive the real window-system input route and
compare presented text, selection and focus at checkpoints. Keep window
liveness, native-error checks, actual OS delivery evidence and retained
pixel captures as separate required oracles. A matching state line alone
does not prove successful input delivery, rendering, or visible caret and
selection geometry. In particular, callback-driven model fixtures must not
be reported as native input E2E.

Focused format, escaping, UTF-16 selection and read-only checks:

```sh
moon test examples/linux_text_field/state_observer_wbtest.mbt --target native
```

Build with the repository-pinned MoonBit 0.10.14 compiler and the Linux
development libraries described in `docs/linux-text.md`. Before executing
cases, record the source commit/tree, executable and fixture-font hashes.
