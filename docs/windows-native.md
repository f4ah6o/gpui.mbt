# Windows native backend

Issue [0008](../issues/open/0008-windows-native-backend.md) now has an
experimental first-window implementation. `windows/` adapts the shared host,
window, event, and `SceneSnapshot` contracts to Win32 and D3D11. The C boundary
owns HWND, DXGI, and D3D11 objects; MoonBit callers exchange framework values.
The backend is not a Windows support-tier claim.

## Build and run

Use the pinned MoonBit `0.10.14+7d59c7ec9` toolchain and a Visual Studio native
tools environment. From PowerShell:

```powershell
./scripts/test_windows.ps1
moon run examples/windows --target native
```

The runner records its toolchain output under `_build/windows-native/`. It
checks formatting and types, runs deterministic tests that work on any native
host, then on Windows runs the HWND/D3D11 tests and a real executable smoke.
`./scripts/test_windows.ps1 -PortableOnly` runs only the portable checks on
Linux or macOS; those tests verify translation, snapshot serialization, error
mapping, and the explicit non-Windows `UnsupportedCapability` stub. They do
not simulate a Windows window or GPU.

The Windows workflow initializes the MSVC environment and pins MoonBit and its
core library. MoonBit selects the Windows native compiler from that environment.
The script also compiles the C shim against the installed Windows SDK. The
workflow retains logs as an artifact. The opt-in native E2E and shared backend
conformance checks run sequentially in separate test processes because both
exercise the process-wide host. Wake and exit messages carry the host token, so
messages queued during teardown cannot affect a later host generation. The
hosted attempts built the shim and passed portable tests. The first native run
found an ordering error in the smoke's one-window assertion, now checked after
the primary HWND is created. The next run progressed through readback,
clipboard, and resize, then exposed a message-pump bug: its availability probe
removed the first queued message before dispatch. The probe now uses
`PM_NOREMOVE`, leaving the close event for the normal dispatch loop. The latest
run reached teardown and found an off-by-one in duplicate destruction of the
most recently destroyed window. The backend now tracks that tombstone per host,
so only that repeated destroy is idempotent; older same-host and prior-host
handles remain stale. A successful hosted run is still required before this
counts as Windows runtime evidence.

The example opens one visible 640 by 400 logical-pixel window and paints a dark
background with a blue quad. Press Escape or use the system close button to
exit. The CI smoke sets `GPUI_WINDOWS_SMOKE=1` and exits after a completed GPU
frame. D3D11 first tries the hardware driver and falls back to Microsoft's
WARP software driver when hardware device creation fails.

## Implemented slice

- One process-wide host and at most one live HWND at a time. Window IDs are
  monotonic; repeating destruction of the most recently destroyed window in
  the same host generation is harmless, while other stale handles remain
  invalid. Later host starts are supported when the process already has the
  required per-monitor-v2 DPI context.
- An owner-thread message pump, posted wake and exit messages, typed errors,
  close-request versus destroy events, title changes, client-size changes, and
  idempotent stop. Wake and exit posting remain safe while stop releases the
  host; HWND and GPU operations reject calls from the wrong thread.
- A DXGI swap chain and D3D11 renderer. The v1 subset draws ordered solid-color
  quads with affine transforms, opacity, premultiplied-alpha blending, and
  intersected rectangle clips. Nonzero viewport origins and unsupported scene
  resources return typed errors. D3D11 event-query completion of submitted
  draw work produces `FrameCompleted` (not a display-scanout timestamp); a
  second frame is rejected while one remains pending.
- Per-monitor-v2 DPI awareness and logical viewport metrics. A DPI transition
  updates and queues the scale event before later resize/input events. Pointer
  coordinates are reported in logical units. The opt-in native test exercises
  ordinary resize; visual movement between physical monitors at different DPI
  is still pending.
- Basic pointer movement, mouse buttons, vertical/horizontal wheel, focus,
  common navigation keys and committed `WM_CHAR` text, plus arrow/hand/text
  cursors. Japanese IME composition, candidate placement, key repeat fidelity,
  and richer text services are not implemented.
- Native Unicode plain-text clipboard read/write. The Windows E2E round-trips
  Japanese and emoji through `CF_UNICODETEXT`; invalid UTF-8, invalid UTF-16,
  unterminated clipboard buffers, and embedded NUL input are rejected instead
  of being silently truncated. Titles and clipboard writes are capped at 1 MiB
  of UTF-8 input. Clipboard reads bound their UTF-16 scan to the HGLOBAL and
  16 Mi code units; the MoonBit wrapper caps the converted UTF-8 result at 16
  MiB.
- Opt-in native E2E readback copies the swap-chain target to a staging texture
  and checks known background/accent/background pixels before presentation.
  The test also checks GPU completion, resize rejection for an old viewport,
  Unicode title/clipboard handling, wrong-thread rejection, stale handles,
  close/destroy ordering, cross-thread wake during stop, and repeated
  create/destroy plus host restarts.

The public capability handshake reports native windows, logical viewports,
quad frames, frame scheduling, pointer/keyboard input, clipboard, and cursors.
Text/IME, accessibility, menus, cross-thread command submission, and renderer
recovery are not advertised. An explicit renderer-recreation method exists for
experimentation, but no loss-injection or automatic recovery state-machine
evidence exists.

## Remaining support gates

This is a one-window development slice. Multi-window behavior, IME, UI
Automation accessibility, menus, broad DPI/display coverage, automated
physical-GPU coverage, fault-injected renderer recovery, sustained
resource-lifetime testing, and performance evidence remain open. The planned
native readback test checks a deterministic D3D11 render target if the Windows
workflow passes; no hosted result has been observed yet. WARP fallback does not
establish physical GPU coverage or desktop performance. Clipboard verification
is an in-process Unicode round trip, not an external application
interoperability test. Only the Windows GitHub Actions runner is configured;
supported Windows versions, GPUs, and driver combinations have not been
established. Do not infer Tier 1 support from a successful build or smoke.

| Evidence | State |
| --- | --- |
| Portable MoonBit formatting, type checks, and headless tests | Locally verified |
| MinGW Windows-header syntax and link check | Locally verified; compile-only, not the MoonBit Windows toolchain |
| MSVC/Windows SDK build, native readback, clipboard and lifecycle E2E | Workflow configured; hosted result pending |
| Physical multi-monitor DPI, IME, accessibility, multi-window and fault recovery | Pending |
