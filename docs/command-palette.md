# Experimental reusable Linux command palette

This is the first bounded application slice for [0020](../issues/open/0020-usable-command-palette-integration-milestone.md). It composes the existing TextField, ElementTree, ScrollState, SceneSnapshot and capability GuiBinding contracts. It is not a production widget library or a new command framework.

## Reusable component boundary

`controls/command_palette` owns copied command metadata, exact case-sensitive substring filtering, enabled selection and an eight-row visible window. Commands keep the existing GuiBinding availability/policy checks; copied disabled state is advisory and trigger rechecks live availability. IDs are unique and nonempty.

Limits are 128 commands, 64 UTF-8 bytes per ID, 128 UTF-8 bytes per label, and 256 UTF-8 bytes per query/preview. Malformed text, controls and line separators are rejected. The bounded input provider may prepare at most the existing TextField's 4096-byte value before palette admission, but rejected values never enter filtering or presentation. Filtering is linear over copied bounded labels. No fuzzy matching or broad Unicode/bidi support is claimed.

A changed committed text value refilters. Caret/selection/revision changes and provisional preedit preserve the current filter and active command. A changed query retains the selected command if it remains matched/enabled, otherwise it chooses the first enabled match. Empty or all-disabled results have no active command. Up/Down skip disabled matches and clamp; Home/End stay text-field caret keys. ScrollState ensures the active row is visible and the shared list painter prepares at most eight labels/sixteen list items.

The mutable CommandPalette controller publishes a closed terminal state before exposing an activation effect. The owner fences its native session, then calls finish_close. That consumes the one-shot terminal before invoking GuiBinding, preventing double or reentrant activation. Stale epoch close requests cannot consume newer actions. Closing and composition-cancelling keys remain quarantined through release, including blur and synchronous reopening. A native host may retire a closed epoch’s quarantine only after successful teardown plus a verified fresh keyboard generation has synchronously revoked old-owner press/release records. retire_key_guard checks the exact closed epoch and completed terminal; it emits no release, action or focus change. Native synchronous callback-reopen retirement remains unqualified in this fixture.

## Focus and native ownership

ElementTree's opaque FocusOwner compares live tree lineage and individual focus acquisition, rather than bare numeric IDs. Immutable successors retain surviving owners; a rebuilt tree intentionally starts a new lineage. Restore only acts while the captured modal acquisition still owns focus. A callback's deliberate focus acquisition/clear is preserved; removed or reused prior IDs are not restored.

A host must retain its live tree during ordinary modal edits instead of constructing a new tree every event. If it reconstructs the tree, old focus tokens deliberately become stale. Asynchronous/native edits capture open_epoch and use install_field_at; the epoch is checked before installing the candidate. Synchronous install_field assumes the caller has just prepared the candidate from the current field.

The Linux application stays inside examples/linux_text_field and reuses its existing qualified ime_owner bridge. Native window/epoch/seat/proxy/sequence checks are joined with the palette open epoch. Search ownership is activated only when logically and natively focused. Explicit text/caret/selection edits are fenced before consuming another native record. Rejected native edits cancel the original transaction before rearming. Actual close fences native ownership before invoking/restoring; unexpected fence failures skip the action and stop the fixture. Direct background keyboard ownership waits for native leave and current window focus. Shutdown disarms only.

Enter while composing belongs to the engine and never activates; native Commit only installs text. Escape cancels composition first, and a later press dismisses. Window focus loss cancels/dismisses, and reopen starts empty under fresh logical and native epochs. Busy presentation retains the entire prepared component state. Fatal presentation rejection fails closed and stops, rather than replaying input against a partial prior field/picker snapshot.

## Fixture and qualification

Set GPUI_COMMAND_PALETTE=1 on the existing native Linux field executable. The fixture shows a click/Ctrl+K opener, Japanese/English commands including a disabled option, a bounded list, command count and separate background press/release counters. Its native harness is shared with the field suite; `--palette` selects the application flow. A new reviewed .desktop launcher starts one bounded private authenticated Xvfb/Weston/IBus/Mozc run and preserves failed runs. No inherited desktop input or shell display-access bypass is used.

Native assertions cover actual Japanese preedit/conversion/commit, committed-only filtering, skip-disabled navigation, scrolling, one-shot activation, restoring background focus without the closing press/release, a fresh background key, cancel/dismiss, blur and fresh-owner reopening. Held-repeat/duplicate key variants, empty/all-disabled cases, removed/reused focus owners and epoch exhaustion are separately model/component regressions unless a native report explicitly records them. Render readiness correlates accepted observer IDs to actual native frame callbacks and retained pixels. Portable semantic assertions are separate from protocol and pixels.

Portable semantics expose dialog ownership/name, search name/value/focus, listbox collection, option names/indexes/selected/disabled states and active command. Linux AT-SPI transport is UNSUPPORTED. Candidate-window contents/highlight are UNRUN and excluded. macOS, Windows, broader IMEs/compositors, physical hardware input and production accessibility are unqualified. MZed is not built or changed by this standalone slice; it still requires reviewed pins and an explicit 0019 admission go decision.

See [palette quality workflow](../infra/linux-desktop/PALETTE-QUALITY.md) for focused property/mutation and observe-only performance evidence. Passing that workflow does not substitute for actual native application acceptance. Source/build/runtime/font manifests and run reports are retained outside the source checkout and must be pinned in any publication report.
