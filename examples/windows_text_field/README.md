# Windows single-line text field

This executable demonstrates the portable `TextField` control in the
experimental one-window Win32/D3D11 host. It opens one visible field, places a
caret from DirectWrite hit testing, and paints the admitted `TextRunItem` with
the Windows text adapter. The supported text slice is single-line and
left-to-right; text is measured and raster-admitted as a whole, so unsupported
layout, missing glyphs, and color glyphs leave the last field value intact.

Run it from a Visual Studio native tools PowerShell with the repository-pinned
MoonBit toolchain:

```powershell
./scripts/run_windows_text_field.ps1 -Mode Smoke
./scripts/run_windows_text_field.ps1 -Mode Run
```

Click to focus and place the caret. The host sends committed characters through
`TextInput`; physical key labels never supply inserted text. Left/Right, Home,
End, Backspace, Delete, Ctrl+A/C/X/V/Z/Y, Ctrl+Shift+Z, Enter, and Escape use
the shared `TextField` command path. Undo history uses the control's
64-entry and 64 KiB bounds. Clipboard paste snapshots field revision and the
active native text-session epoch, reads the clipboard, and applies only if both
are still current. Cut changes the field only after the clipboard write
succeeds.

AltGr text uses committed `WM_CHAR` input when no IME preedit is active. While
an IMM composition is active, candidate/navigation ownership takes precedence;
the example does not claim AltGr behavior inside an active composition.

Set `GPUI_WINDOWS_FIELD_IME=1` to opt into the private experimental IMM32 text
session. The session starts only after the focused field has an accepted
frame. Ordered records drive preview and lifecycle through the portable field
model. Empty preedit remains an active native transaction without deleting the
original selection. Each `Inserted` result commits immediately as one undoable
edit; if the same native message also has preedit, a new transaction starts at
the post-result caret. Escape, blur, cancellation, or composition end discards
only the current unconfirmed preview, preserving results already committed.
Ordinary navigation and Enter remain owned by IMM while a preedit is active;
the sample resolves a preedit for explicit app shortcuts or pointer edits.
Session owner generation stays stable for the field lifetime; window,
generation, epoch, and shared FIFO sequence checks fence stale records. This
does not advertise the public `TextInput` capability or qualify Japanese IME
behavior. Synthetic owner/controller tests use fake geometry and are kept
separate from any real Windows Japanese-session qualification.

The smoke mode sets `GPUI_WINDOWS_FIELD_SMOKE=1` and exits after an accepted
field frame reaches `FrameCompleted`. That is a window/render-lifecycle check.
`GPUI_WINDOWS_FIELD_STATE=1` optionally records the accepted field's committed
text, preview, selection, caret, revision, and history flags for semantic test
automation. Neither hook proves text or caret pixels; use native readback
oracles in the Windows test harness for visual acceptance.

The runner verifies the pinned MoonBit compiler and saves revision, compiler,
format, check, test, build, and app transcripts under
`_build/windows-text-field/`. Its MSVC compile log covers the Win32 shim; the
adapter and renderer are compiled by the Moon native build and tested by their
own package/backend checks.
