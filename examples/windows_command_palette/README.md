# Windows command palette fixture

This is a bounded single-window fixture for the shared command palette and the
Windows DirectWrite/IMM32 adapters. It opens with **Ctrl+K** or the on-screen
button, searches committed text by exact substring, moves through enabled rows
with the arrow keys, activates the selected command with Enter, and dismisses
with Escape. Clicking outside the dialog blurs it; reopen starts with an empty
query. Escape cancels an active composition first, then a later Escape closes
the palette.

From a Windows PowerShell session with the repository's pinned MoonBit tools
available, build and launch the fixture with:

```powershell
pwsh -NoProfile -File scripts/run_windows_command_palette.ps1 -Mode Build
pwsh -NoProfile -File scripts/run_windows_command_palette.ps1 -Mode Run -ExperimentalIme
```

The interactive launch prints its PID and creates flushed live logs under
`_build/windows-command-palette/logs/`. Use the printed `Stop` command when the
GUI run is complete. The smoke mode launches hidden, opens the palette, waits
for a correlated `FrameCompleted` event and D3D11 staging readback, then exits
automatically:

```powershell
pwsh -NoProfile -File scripts/run_windows_command_palette.ps1 -Mode Smoke
```

`-ExperimentalIme` opts into the private IMM32 session; it is off by default.
Use physical key presses to compose and commit Japanese text. The observer log
records the visible field text, committed text, composition flag, selection,
palette query/semantics,
owner generation, native session epoch and sequence, native event counters,
accepted presentation number, matching completion-event sequence, and GPU
readback samples. The logged caret rectangle is the geometry supplied to the
native candidate-window adapter.

The runner retains a source/tool/font/OS/GPU manifest and the matching stdout,
stderr, and smoke logs under `_build/windows-command-palette/`. The staging
readback samples are diagnostic points, not full-frame pixel qualification;
capture the matching final GUI frames separately when checking search/caret,
active and disabled rows, scrolling, and clipping. Candidate-window contents
and highlight remain unqualified, as does any broader Windows or UI Automation
support claim.
