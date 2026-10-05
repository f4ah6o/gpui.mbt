# MZed native island migration roadmap

Status: open (planning only)
Parent: [0001-product-charter-and-compatibility.md](0001-product-charter-and-compatibility.md)
Related: [0011-electron-tauri-migration.md](0011-electron-tauri-migration.md), [0019-mzed-native-coexistence-proof.md](0019-mzed-native-coexistence-proof.md)
Updated: 2026-10-05
Application repository: https://github.com/gpui-mbt/MZed

## Goal and decisions

Make gpui.mbt usable for real applications by progressively migrating useful Zed behavior into MZed, with a reproducible, versioned evidence package for each increment. Preserve a working Zed application while proving whether native MoonBit UI regions can coexist safely with Rust GPUI.

- Start with Linux qualification because the available cloud and native CI route makes it easier to verify. macOS follows once the boundary is established; this ordering is not a claim that Linux has broader production readiness.
- Prove native coexistence before committing to a renderer integration. If it fails its gates, present the evidence and a fallback decision rather than silently replacing the app architecture.
- Treat `zed-industries/zed` as read-only. Do not create issues, pull requests, comments, branches, releases, or any other upstream mutations. Upstream reading and local comparison are allowed.
- Keep source-derived Zed application work in MZed. Keep gpui.mbt framework work independently authored and consistent with its provenance policy.
- This packet records the approved plan only. It does not resume packet 0016 or implement/build/release MZed, gpui.mbt, or the supporting tools. Preserve unrelated work in progress.

## Complementary qualification: familiar cross-platform UX

MZed is the functional and practical application milestone toward gpui.mbt
production readiness: preserving real editor workflows exercises a broad set of
framework capabilities. Yami-kumo adds the complementary UX axis: a familiar,
SaaS-style GUI whose navigation, task structure and interaction outcomes remain
intuitive across applications, devices and supported platforms. Neither track
alone closes the framework's 1.0 release gates.

[Yami-kumo PR 3](https://github.com/f4ah6o/Yami-kumo/pull/3) was verified on
2026-10-05 as an open draft at `b78a32ed9e129dfc4d2d1a6433fadddc6cb953d8`.
Its [shared UX plan](https://github.com/f4ah6o/Yami-kumo/blob/b78a32ed9e129dfc4d2d1a6433fadddc6cb953d8/issues/open/20261005-kumo-gpui-shared-ux.md)
is documentation only: extraction/generation, native adapters and native UX
qualification are not implemented. Its successful
[web CI run](https://github.com/f4ah6o/Yami-kumo/actions/runs/37254976357)
does not establish native conformance. Recheck the plan and actual dependencies
before implementation; the referenced PR is not an adopted release dependency.

### Ownership and sequence

- Cloudflare Kumo supplies upstream web components, tokens and variant facts.
  Yami-kumo owns the shared UX contract, shell policy, extraction/generation,
  maintained native component adapters and web/native conformance fixtures.
- gpui.mbt owns reusable rendering, layout, text, input/IME, focus, accessibility
  and platform primitives. Kumo-specific policy stays outside framework core;
  its public API must not acquire a React or Kumo dependency. Applications own
  domain state/actions, content, labels and optional shell regions.
- First pin package integrity/source correspondence and toolchain/framework
  revisions, then qualify the existing web shell against the contract. The
  current Yami-kumo `latest` dependency and region-list tests are not a
  reproducible interaction reference.
- Next build deterministic token/variant generation with explicit unsupported
  mappings and headless fixtures. Keep generated facts separate from reviewed,
  hand-maintained behavior adapters; upstream updates must not silently rewrite
  interaction expectations or overwrite manual work. Preserve theme/token
  namespaces, conversion rules and source/style/dependency provenance.
- Qualify a usable native shell on one declared target, then text/IME and
  compound controls, followed by a real upstream-update qualification cycle.
  Start with actual starter needs: Button, Input, LayerCard and shell controls.
  Keep ordinary web template development independent of native setup.

Standalone native Yami-kumo does not depend on MZed's same-window island proof.
Use [0004](0004-platform-rendering-and-native-boundaries.md) for framework
capability gaps; [0009](0009-browser-backend.md) and
[0011](0011-electron-tauri-migration.md) apply only to paths that use those hosts.
Do not expand [0019](0019-mzed-native-coexistence-proof.md)'s first proof to
implement a design system. Sequence Yami-kumo work after the current MZed/vlmkit
checkpoint while preserving unrelated work and the platform priorities below.

### Shared UX and admission gates

- Preserve navigation versus contextual support, optional shell regions, task
  state and selection across compact/docked layouts. Required task controls
  remain in the main task. Specify keyboard/pointer activation, disabled,
  loading, error, retry and success outcomes rather than screenshot similarity.
- Verify modal focus containment, background-action suppression, dismissal
  without click-through and focus restoration. Docked panels remain nonmodal;
  hidden or removed controls must not retain keyboard interaction. Tab focus
  and selection follow an explicit activation policy.
- Require visible usable text, real input and native accessible names, roles,
  values and state feedback. Qualify Japanese IME composition, selection,
  commit and cancellation separately from submit/dismiss. A quad placeholder,
  compiled component or headless pass is not a usable native Button/Input.
- Document intentional OS differences in primary shortcut modifiers, fonts,
  window chrome and display scale. Test viewport/input-device adaptation,
  reduced motion and theme changes without losing task discoverability or
  understandable state. Familiar UX is not identical pixels on every platform.
- Record coverage by target, component/part, variant/state and scenario, with
  exact pins and PASS/FAIL/UNRUN/BLOCKED/UNSUPPORTED results. Separate generated
  definitions, compilation, headless checks, rendering, physical input and
  semantic accessibility. A DOM island running original Kumo qualifies only
  that web path. vlmkit visual evidence supplements deterministic focus/action/
  IME assertions and requires a verified driver profile for the actual target.
- Preserve upstream notices and inspect each redistributed dependency/asset.
  [Kumo's inspected license](https://github.com/cloudflare/kumo/blob/3d9331280781bf9ea67bb6c38321a7c6b98b0cee/LICENSE)
  is MIT; retain required copyright/permission notices with copied or derived
  material. Confirm Yami-kumo's own distribution license and generated-output
  provenance before distributing a reusable native package; acknowledgements
  alone do not establish licensing. The separate Zed provenance rules still
  apply to MZed.

An unsupported required interaction prevents that target's qualification.
Cross-device familiarity is the goal, not a new support claim. Existing Windows
checks stay intact; new Windows work remains deferred under the priorities below.

## Platform priorities

The long-term goal for every application and tool in this effort is macOS,
Linux and Windows support. Near-term work prioritizes macOS and Linux. Linux
native vlmkit is a first-class formal support initiative, not a temporary
manual-testing workaround for MZed.

New Windows-specific work has the lowest priority: begin only after no
macOS/Linux work remains and the user supplies a Windows work environment.
Preserve existing working Windows implementation and CI; do not disable or
remove them. Running existing CI is not initiation of new Windows feature work.

The direction was explicitly confirmed on 2026-10-05:

> ok, f4ah6o/vlmkit の nativeはLinuxに正式対応する勢いで進めて。
> 最終的にはどのアプリ、ツールもMac/Linux/Windows対応するのがゴールです。ただWindows対応は優先度はすごく低いです。それしかやることがなくなったら着手します。その時はWindows作業環境を提供します。

Formal support remains an evidence-backed state. The goal does not mark any
currently missing backend as supported, and a shared API does not erase host
permission or capability differences.

## Verified starting point

MZed `main` was inspected at `6752e76a24a64b24d28b6baba0f46994a635c747`: only a six-byte README exists, and the releases collection was empty. There is no existing application implementation to extend. The first implementation must establish a pinned working Zed-derived baseline before claiming to preserve one.

The inspected gpui.mbt revision is `35aae36e79588c47c030093bf64eaf54b15f715a`. Its native hosts use platform APIs directly and do not carry a Rust GPUI runtime. Rust source compatibility and binary compatibility are explicitly outside the current contract.

Packet 0011 supplies a browser DOM-island example and bounded host-service envelopes. Its fake Electron/Tauri adapters do not demonstrate a native Rust GPUI/MoonBit embedding boundary. Reuse its principles of explicit ownership, copied values, cancellation and versioning; do not call the new native work an already-supported 0011 integration.

Portable scene rendering remains quad/clip-first, with bounded browser text
snapshot items; native text renderers reject those items explicitly. The text value model
foundation has UTF-16 ranges, directional selection and immutable replacement;
this source tree adds pure composition/commit/cancel transitions and strict
UTF-16/UTF-8 scalar-boundary conversion. The conversion has no grapheme or
shaped-geometry semantics. It does not draw text or provide an editable UI.
Host sequencing, actual Japanese IME, text layout, candidate-window placement,
rich text, production shaping, caret geometry, undo, multi-cursor editing,
general accessibility and sustained performance evidence remain incomplete.
A project tree or palette requires usable framework text capability before it
can count as migrated UI.

### Foundation-first text gap and current slice

See the source-grounded [codebase gap analysis](../../docs/codebase-gap-analysis.md)
for the implementation order and evidence boundaries. The current `text/`
package is a portable data model only. It does not implement a text field,
grapheme navigation, rendering, caret mapping, a host input adapter, or actual
OS input-method behavior. The MZed application
milestones and their platform admission gates remain unchanged. See the
[portable text model](../../docs/text-model.md) for the value-level contract.

### Upstream pin selection gate

Before implementation, record and review one MZed source baseline:

- gpui.mbt's current GPUI comparison pin is `d9afb21688e04f89d9e94d96d33eb530aef90886`.
- Zed's moving main was observed at `a84689073d296dfd39987bc7dd478e43ef76d83a` during research. Observation does not select it as the migration baseline.
- Select a suitable fixed Zed commit or release, verify its Linux build and licensing at the selected paths, and record its exact SHA and toolchain. Keep the gpui.mbt behavioral comparison pin separate unless a reviewed pin update is needed.
- Preserve all unrelated local branches and changes. Use an isolated implementation worktree/directory when implementation is approved.

## First increment

The first detailed packet is [0019 native coexistence proof](0019-mzed-native-coexistence-proof.md).
It establishes a pinned working Zed baseline and a reversible same-window
MoonBit region before expanding into product features. A logic-only bridge may
be a prerequisite, but does not count as a completed native visual island.

## Later increments

Keep these as behavior-level slices. Write detailed implementation packets only after the preceding evidence establishes the boundary.

### Read-only project tree

- Product behavior: display a bounded project tree, expand/collapse, select a file and request that the existing Rust editor opens it. Rust remains authoritative for filesystem/worktree/editor state.
- Framework capabilities: text drawing, layout and clipping, scrolling, stable row identity, focus/keyboard selection and an accessibility representation appropriate to the declared target.
- Tool gaps: native targeted interaction and scalable tree fixtures; do not rely on global input injection or unqualified screenshots.
- Evidence: deterministic tree/selection fixtures plus real file-open flow, Unicode filenames, large-tree bounds, cancellation and regression of the original editor.
- Scope limit: `project_panel` depends on editor/project/worktree/workspace and more. Do not translate its complete dependency graph to claim one small slice.

### Command palette

- Product behavior: search input, result navigation, activation, cancellation and restoration of the previous focus. Existing Rust commands execute initially.
- Framework capabilities: editable text, shaping/caret mapping, keyboard and composition ownership, asynchronous result cancellation, accessible names and selection.
- Tool gaps: reliable native text/IME exercise and versioned command/result fixtures.
- Evidence: query/navigation/cancel/action workflows, stale-query rejection, repeated open/close, mixed scripts and Japanese IME on the declared platform.

### Single-buffer editor

- Product behavior: open one document, edit, select, undo/redo, track dirty state, save, reload and handle external-change conflicts.
- Framework capabilities: robust text layout, grapheme/selection/caret semantics, clipboard, IME, rendering invalidation and sustained interaction performance.
- Tool gaps: repeatable edit workloads, text correctness oracle/fixtures and environment-qualified frame/resource measurements.
- Evidence: round-trip content integrity, undo sequences, Unicode and mixed-script cases, composition/cancellation, save/conflict behavior and sustained bounded workloads.
- Scope limit: keep language services and other Rust domains behind contracts initially. Multi-buffer, collaboration and full workspace parity are later decisions.

## Supporting tool adoption

Tool work belongs in a slice only when it closes a named verification gap. It should not become a separate speculative rewrite.

- **turtles:** target-aware schema 3 support exists on its main line, while gpui.mbt currently uses the 0.3/schema 2 adoption path. Select and pin the tool revision, migrate configuration deliberately, and prove the selected target actually runs. Do not mix old configuration with new target claims.
- **hotpath:** explicit timing is suitable for the first workload. Define representative operations, environment, warmup/sample method and baseline first. Automatic instrumentation is not required for the first island proof.
- **vlmkit:** establish a formally supported Linux native observer and safe-input route with explicit platform capability profiles, as described below. Native input work in PR 2 needs exact-window targeting and verification; global/PID routing is insufficient for safe deterministic action. Manual evidence may unblock an experiment temporarily, but does not complete the Linux support initiative or its automated qualification gates.
- Keep deterministic framework and contract assertions authoritative. Visual or model-assisted judgment supplements them.

Research pins for supporting tools:

- turtles.mbt `4d9baaa258c695e803a487283076e979e2c260ba`: [parser/target documentation](https://github.com/gpui-mbt/turtles.mbt/blob/4d9baaa258c695e803a487283076e979e2c260ba/docs/moonbit-parser.md), [plan implementation](https://github.com/gpui-mbt/turtles.mbt/blob/4d9baaa258c695e803a487283076e979e2c260ba/cmd/turtles/plan.mbt), [reported CI run](https://github.com/gpui-mbt/turtles.mbt/actions/runs/36927393466).
- hotpath.mbt `be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce`: [explicit timing implementation](https://github.com/gpui-mbt/hotpath.mbt/blob/be4cb98a3eb61bd5ab176c9e5e6bd921b74d1dce/src/hotpath.mbt), [reported CI run](https://github.com/gpui-mbt/hotpath.mbt/actions/runs/37207563678).
- vlmkit `4be3177a62d8a3304e1cb09958dc5deab92d7eff`: [native observer report](https://github.com/f4ah6o/vlmkit/blob/4be3177a62d8a3304e1cb09958dc5deab92d7eff/docs/reports/2026-10-03-native-observer-p0.md). PR 2 head `9893e13234cf222d7fcf606d02d9944094d3cb31`: [macOS interaction implementation](https://github.com/f4ah6o/vlmkit/blob/9893e13234cf222d7fcf606d02d9944094d3cb31/native/macos/Sources/VLMKitNativeAgent/Interaction.swift), [exact-window blocker](https://github.com/f4ah6o/vlmkit/pull/2#issuecomment-5985711120).

These are inspected research references, not adopted release dependencies. Confirm tool applicability to the selected Linux environment separately; a macOS native observer or input implementation does not prove Linux automation support. Enter selected revisions in the candidate manifest and verify exact-SHA CI coverage before adoption. An unmerged PR is not a completed dependency.

## Linux native vlmkit support initiative

At vlmkit `4be3177a62d8a3304e1cb09958dc5deab92d7eff`, the native sidecar is
macOS-only. Ubuntu-hosted Node/browser jobs do not qualify Linux native support.
Implement a Linux sidecar and platform-neutral dispatch/validation while reusing
the versioned accessibility tree, PNG evidence and bounded stdio protocol where
appropriate. Keep native OS objects out of the portable judge/test API. The
[existing native dispatch](https://github.com/f4ah6o/vlmkit/blob/4be3177a62d8a3304e1cb09958dc5deab92d7eff/packages/vlmkit-markup/src/a11y-tree/native-agent.ts)
rejects non-Darwin and validates macOS trees; the
[portable tree contract](https://github.com/f4ah6o/vlmkit/blob/4be3177a62d8a3304e1cb09958dc5deab92d7eff/packages/vlmkit-judge/src/a11y-tree.ts)
can be reused. A later vlmkit implementation packet must update its current
macOS-first milestone and native CLI dispatch as part of Linux admission.

### Profiles and capability boundaries

Admit explicit profiles rather than a universal Linux support flag:

| Profile | Observer and semantics | Safe input qualification |
| --- | --- | --- |
| X11 session | Target-window capture and AT-SPI where the app exports it | Stable window identity, focus and coordinate checks; reject stale/reused targets and verify actual recipient |
| Named Wayland compositor and portal backend | User-authorized window capture only when the backend advertises it; AT-SPI where exported | Authorized RemoteDesktop/libei or another reviewed path; admit physical input only when target binding is demonstrated |
| XWayland app within Wayland | Record both app protocol and session/compositor; test separately | Do not infer access to native Wayland windows from X11/XWayland success |

Pin distribution, compositor/display-server, portal/backend and relevant library
versions in the support matrix. Initially qualify a small explicit matrix; add
profiles only with evidence. X11 and Wayland are separate capabilities even on
the same distribution. A vlmkit X11 driver does not imply a gpui.mbt X11 backend.

Wayland ScreenCast source selection is mediated by the portal/user and window
sources are a backend capability. Window streams do not promise global desktop
coordinates. RemoteDesktop input authorization is not proof that input is bound
to the selected application window. Do not infer safe click coordinates or
recipient identity from a capture stream. Define surface-local coordinates,
frame inclusion and transform provenance rather than requiring a global origin
and one scale. Version or negotiate changes to the existing capture contract.
Associate AT-SPI windows with capture streams using verified identity evidence;
reject ambiguous associations. Do not silently replace window capture with a
monitor crop. No global/PID-only injection fallback
may bypass failed target verification.

AT-SPI supplies semantic access only when the target application exposes the
required tree/actions. A custom GPU-rendered app may lack those semantics;
report that gap and retain pixel evidence without fabricating AX data or calling
pixel-only capture accessibility support. Semantic actions must verify target
identity, action availability and postcondition too.

### Implementation and admission gates

- Define capability results for capture, semantic tree, semantic action,
  pointer, key/text input and coordinate mapping, including typed unsupported,
  permission-denied, revoked and stale-target outcomes.
- Add a Linux collector/sidecar and remove macOS-only dispatch/tree validation
  assumptions without weakening macOS tests or creating a second semantic schema.
- Bind a session to the selected target; revalidate at each action and after
  focus/window changes. Test unrelated windows, same-PID windows, target exit,
  reuse/remount, scale changes and permission revocation. Fail closed when
  recipient binding cannot be established.
- Implement observer and safe input as explicit milestones. An observer profile
  may be released as observer-only with missing input stated; formal automation
  support requires both observer and safely admitted actions for that profile.
- Separate discoverable, permitted and verified capabilities. Expose safe
  enumeration as unsupported when the backend cannot provide it. Do not bypass
  restrictions through root/uinput, xhost access relaxation or hidden persistent
  grants.
- Test AT-SPI support and absence on actual applications. Include MZed/gpui.mbt
  once available plus GTK and Qt fixtures; do not substitute
  browser-only Playwright results for the native app path.
- Run real application workflows in an isolated display session: launch, select
  target, capture/tree, targeted action, postcondition, teardown and repeated
  sessions. Exercise permission denial/revocation and focus theft as negative
  cases. Portal authorization must be obtained through the supported flow,
  never bypassed to make CI green.
- Retain exact candidate/tool SHAs, environment versions, app identity, protocol
  transcript, permission/capability results, screenshots/tree artifacts, action
  results and failure logs. Classify mocked contracts, nested/software-rendered
  CI and real desktop runs separately.
- Verify package/install smoke on advertised Linux architectures and documented
  dependencies. Keep X11 virtual-display and Wayland compositor lanes separate;
  Xvfb evidence does not establish Wayland behavior. Test 1x, 2x and fractional
  scale, decorations/popups/modal transitions and unavailable semantic interfaces.
- Publish a profile matrix that records observer, semantics, input, limitations,
  last verified commit/run and evidence. Hardware performance claims require
  representative hardware evidence; deterministic software CI is a correctness
  lane. Declare maintenance owners and rerun the profile suite for releases.

Linux support is complete only for the declared profiles and capabilities whose
checks pass. Lack of a portal/input capability should create an explicit blocked
or observer-only profile, not a silent manual-only endpoint for the initiative.

Primary platform contracts: [ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html),
[RemoteDesktop portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.RemoteDesktop.html),
[libei API](https://libinput.pages.freedesktop.org/libei/api/index.html),
[AT-SPI Component coordinates](https://gnome.pages.gitlab.gnome.org/at-spi2-core/devel-docs/doc-org.a11y.atspi.Component.html),
[XTEST device simulation](https://xorg.freedesktop.org/archive/X11R7.5/doc/Xext/xtestlib.html),
[XWayland architecture](https://wayland.freedesktop.org/docs/book/Xwayland.html).

## Provenance and release evidence

Zed application crates inspected, including editor, workspace, project_panel, command_palette and text, declare GPL-3.0-or-later. GPUI itself declares Apache-2.0. Package and asset licensing must be checked at the selected MZed pin; GPUI's license does not license application translations.

Keep Zed-derived source, adaptations and fixtures in MZed with exact upstream paths/SHA, method, destination, deviations and required notices. Independently author generic gpui.mbt capabilities and their fixtures. Do not move GPL-derived implementation or test material into gpui.mbt under an Apache label. A repository/process boundary alone is not a complete license analysis; audit the actual distributed composition and corresponding-source/notice requirements before release.

Each increment produces a candidate with:

- MZed and gpui.mbt SHAs, upstream source pin, dependency/tool lock versions and applied patch provenance.
- Reproducible build/test commands, target/OS/compositor/GPU or software renderer, toolchain and configuration.
- Exact workflow/CI links, exit results, deterministic test reports, interaction evidence and workload measurements.
- Checksummed source/build/output artifacts, applicable license/notice inventory and known limitations.
- Migrated behavior, remaining Rust-owned domains/islands and an explicit pass/blocked/not-run matrix.
- A clean-consumer/install smoke and rollback instructions when claiming an installable application release.

Release notes must distinguish a source-only experiment from an installable app, and experimental platform qualification from production support. Every release uses evidence for its exact candidate; do not roll prior-SHA passes forward without revalidation. The gpui.mbt 1.0 readiness ledger remains a separate gate and must not be marked ready merely because an MZed increment works.

## Primary source references

- [MZed initial commit](https://github.com/gpui-mbt/MZed/commit/6752e76a24a64b24d28b6baba0f46994a635c747)
- [gpui.mbt relationship to GPUI and current runtime](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/README.mbt.md)
- [0011 browser and Electron/Tauri migration packet](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/issues/open/0011-electron-tauri-migration.md)
- [Implemented migration boundary](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/docs/electron-tauri-migration.md)
- [Current capability limits](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/docs/status.md)
- [Provenance policy](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/docs/provenance.md)
- [Pinned GPUI reference](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/docs/upstream.json)
- [Release evidence requirements](https://github.com/gpui-mbt/gpui.mbt/blob/35aae36e79588c47c030093bf64eaf54b15f715a/docs/release.md)
- [Zed project panel dependencies and license](https://github.com/zed-industries/zed/blob/a84689073d296dfd39987bc7dd478e43ef76d83a/crates/project_panel/Cargo.toml)
- [Zed command palette dependencies and license](https://github.com/zed-industries/zed/blob/a84689073d296dfd39987bc7dd478e43ef76d83a/crates/command_palette/Cargo.toml)
- [Zed editor dependencies and license](https://github.com/zed-industries/zed/blob/a84689073d296dfd39987bc7dd478e43ef76d83a/crates/editor/Cargo.toml)
- [GPUI package license](https://github.com/zed-industries/zed/blob/a84689073d296dfd39987bc7dd478e43ef76d83a/crates/gpui/Cargo.toml)

The linked Zed revision documents the research basis. Recheck affected paths and license context when selecting a different implementation pin.
