# Windows reusable Button fixture

`examples/windows_button/` composes the existing Win32/D3D11 host with the
shared `controls/button` implementation and the app-owned fixture in
`examples/ubuntu_button/fixture/`. The Windows adapter translates native
window/input events and owns only Windows session state; it does not duplicate
Button, accessibility, or activation semantics. This is an experimental
fixture, not a Windows support-tier claim. Native UI Automation remains
unsupported.

The visible 640 × 240 logical-pixel window provides a bounded Stage A demo:
Tab toggles focus, Enter activates on its first key-down, Space activates on
the matching key-up, and a primary-button click activates on an in-bounds
release. The sample uses committed `WM_CHAR` text to toggle `D` enabled state,
`L` loading state, and `R` to reset the fixture-owned activation count and
session. Escape closes the window. These single-letter controls belong to this
example; the shared model remains platform-neutral.

Run the Windows matrix from x64 PowerShell with the pinned MoonBit
`0.10.14+7d59c7ec9` toolchain and Visual Studio x64 C++ tools:

```powershell
pwsh -NoProfile -File scripts/test_windows.ps1 -PortableOnly
pwsh -NoProfile -File scripts/test_windows.ps1
pwsh -NoProfile -File scripts/run_windows_button_e2e.ps1
```

The portable command checks the Win32 package and shared Button model tests.
The full native script builds the Windows C boundary, runs the deterministic
Windows and shared-fixture tests, and launches the visible Button smoke with
opt-in D3D11 staging readback. The smoke requires both `GPUI_NATIVE_E2E=1` and
`GPUI_WINDOWS_READBACK=1`; it fails if it cannot copy and validate the
completed frame. The separate E2E runner sends real keyboard and mouse input
only after checking x64 `INPUT` layout, owned HWND identity, foreground, and the
active `Default` input desktop. Its records are saved under
`_build/windows-button/e2e/`.

## Current evidence and limits

On 2026-10-10 the native smoke completed one D3D11 frame at scale 1.0 with a
640 × 240 readback. It measured background `[24,28,36,255]`, the enabled Button
fill `[42,71,101,255]`, 183 bright label pixels, and 279 status-text pixels.
The observed host was Windows 11 Pro build 26200, x64, MSVC 19.44.35214.0,
MoonBit compiler `0.10.14+7d59c7ec9`, a 3440 × 1440 desktop, and an NVIDIA
GeForce RTX 2060 SUPER (driver 32.0.15.6614). The fixture uses Segoe UI; the
observed `segoeui.ttf` SHA-256 was
`8134dbcd09e7b123c9a7f229d49cffbcb01352cc72ea5e1076b65d0dca9f73cd`.
The backend's hardware-versus-WARP choice was not recorded, so this is a
completed-frame pixel check on that host, not a GPU-driver matrix result.

The visible SendInput run recorded `BLOCKED`: this session could not open the
active input desktop (`OpenInputDesktop`, Win32 error 5) and had no foreground
HWND. Physical keyboard/pointer interaction and GUI close/reopen are therefore
`UNRUN`; the runner does not substitute posted messages or model tests for
physical input. `scripts/run_windows_button_e2e.ps1` preserves that status in
`result.json` and can be rerun from an interactive session with access to the
Default input desktop. The six Windows session adapter tests and 16 shared
Button fixture tests cover model-level repeat suppression, activation counts,
enabled/loading/reset transitions, semantic snapshot freshness, close/blur,
resize cancellation and stale releases. They do not qualify physical input or
all state-specific native pixels.

The D3D11 sample validates a few pixels from the completed frame; it does not
qualify clipping at arbitrary dimensions, high-DPI transitions, monitor
moves, all fonts, UI Automation, Japanese IME, broad Windows compatibility, or
production support. See [issue 0025](../issues/open/0025-windows-button-integration.md)
for the remaining acceptance gates.
