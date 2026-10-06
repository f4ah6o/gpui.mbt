# Linux text measurement and Ubuntu grayscale drawing

`platform/linux_text/` is an experimental Linux-native text adapter. Its
measurement API uses PangoFT2 with FreeType and the installed Fontconfig font
set to measure shaped text and answer copied caret/hit-test geometry queries.
Its private raster boundary produces grayscale A8 glyph masks for the Ubuntu
GLES renderer. Measurement still runs without GTK, a window, an X11/Wayland
display server, MZed, or a renderer. The portable `text/` value model and
`primitives/` remain MoonBit-only; Pango values and handles do not enter the
public model.

Measured-text [PR #27](https://github.com/f4ah6o/gpui.mbt/pull/27) is merged
into main as `d0335f65f6758b5ecaf91353500ad6978f9ae13e`. It adds copied
PangoFT2 measurement/caret/hit values; it does not add a general editable
control. The Ubuntu-only renderer now has an origin-aware plain `TextRunItem`
scene variant alongside legacy `TextItem`. This extension does not change
`TextItem`'s meaning or canonical JSON, add portable shaping/editor semantics,
or change non-Linux rendering behavior.

`require_grayscale_raster()` checks that the linked private raster ABI is
available and that the runtime Pango library is at least 1.50, which provides
the glyph-color metadata needed for safe whole-frame rejection. It returns
`UnsupportedRaster` on ABI/runtime mismatch. Ubuntu checks this before
advertising or using `GrayscaleTextFrames`; a supported host still applies
per-frame validation and limits.

Native pointers and Pango structs stay inside the Linux boundary; measurement
calls return copied values. Raster requests use a private versioned ABI over
borrowed input bytes, and the native mask allocation is released at the end of
the frame. The adapter retains no Pango font map, context,
layout, or other Pango object between calls. Each operation creates the
required objects, uses them for that request, and unreferences them on success
and failure. This
avoids cross-call mutable native state and stale font-map/session ownership.
The C boundary drops its own references before returning, but Pango may retain
backend worker references and finalize internal objects asynchronously. This
does not expose a handle or delay the geometry result; the adapter does not
wait for Pango's internal workers.
Each call currently pays for a new font map, context, and layout. Measurement
also allocates a bounded copy buffer sized for one record per Unicode scalar
boundary plus a fixed header; it queries both caret positions at each
boundary. Hit testing similarly creates its own layout. There is no cache yet;
these per-call allocations are the cost of avoiding persistent native-handle
ownership in this slice. The lifecycle test waits on thread-safe finalizer
notifications with a bounded post-measurement deadline; it does not change
production cleanup behavior.

The origin-aware presentation path is explicitly versioned. Private raster ABI
v2 returns the existing v1 mask plus `u0/v0/u1/v1` crop coordinates in a
separate `gpui_linux_text_mask_v2`; the v1 mask struct and v1 raster entry
semantics remain unchanged. Ubuntu's private mixed-frame ABI3 uses 25 doubles
per item, preserving the ABI2 23-field prefix and appending independent text
origin x/y. ABI3 tag 2 selects an origin-aware plain run; quad and legacy-text
tags must keep the appended fields zero.

Raster v2 retains one layout-grid sampling texel at each interior crop edge,
clipped to the full pixel ink tile, so linear filtering inside the local clip
agrees with the full uncut mask. The visible rectangle stays exact and the UV
coordinates map into this halo-backed allocation. Tile dimensions, per-call
pixel budget and total frame A8 budget include the halo before allocation;
an otherwise fitting visible tile may therefore return `ResourceLimit`.
Empty results have zero geometry/UVs and no pixels; unknown-glyph count may
remain nonzero. Success transfers owned pixels to the caller, failures leave
the entire output unchanged, and `mask_release_v2` clears all fields safely on
repeat. Raster v1 explicitly uses the unchanged legacy no-halo mode, preserving
its pixel storage and filtering.

V2 admits clip/layout/translated visible endpoints and extents only when their
roundtrip error is at most 1/4096 logical pixel, a fixed tolerance below one
Pango unit (1/1024 px). Positive-but-distorted geometry at huge finite origins
returns `InvalidCoordinates` before mask allocation, even when a later affine
translation could bring it onscreen. Ordinary fractional origins remain valid.
This does not extend the legacy v1 coordinate/storage contract.

## Coordinates and query semantics

- The adapter fixes PangoFT2 resolution at 96 DPI and accepts absolute pixel
  font sizes. It does not interpret a supplied size as points and does not
  apply a window/device scale. Pango fixed-point values use 1024 units per
  logical pixel; returned geometry is converted to absolute pixel values.
- Pango consumes UTF-8. Public document and selection offsets remain UTF-16
  code units in `text/`; the native boundary converts at Unicode-scalar
  boundaries and rejects offsets that split a UTF-8 scalar or UTF-16 surrogate
  pair. Invalid UTF-8 and embedded NUL in either text or family names are
  rejected before calling the native library.
- The returned table contains every Unicode scalar boundary. Its
  `is_cursor_position` flag reports which boundaries Pango considers legal
  caret stops; a combining mark can be inside a shaped cluster and not be one.
  Bidi queries preserve both strong and weak caret rectangles where they differ.
- Hit results identify a UTF-8 byte boundary plus Pango's trailing count of
  Unicode characters/scalars; the trailing count is not a byte count. The
  portable adapter maps the result back to the text model's UTF-16 coordinate
  space. XY-to-offset results are layout observations, not a unique inverse of
  caret placement.
- Measurement can report ink/logical extents, baselines, lines, and missing
  glyphs. Exact pixel metrics depend on Pango, Fontconfig, FreeType, the chosen
  font files, and their versions; cross-distribution pixel goldens are not a
  contract. This does not define word-wrapping/editor policy, grapheme
  navigation, IME behavior, accessibility, or selection geometry.
- Each native request rejects inputs exceeding 16,384 UTF-8 text bytes, a
  256-byte font-family name, or 512 logical pixels of font size. Inputs are
  rejected rather than truncated; embedded NUL is unsupported by Pango's
  string-based family API, while portable `TextDocument` values may contain it.

## Headless build and test

The configured CI target is Ubuntu 24.04 x86-64. Install the C compiler,
pkg-config, PangoFT2 and Fontconfig development files, plus the test fonts:

```sh
sudo apt-get update
sudo apt-get install -y build-essential pkg-config libpango1.0-dev \
  libfontconfig1-dev fontconfig fonts-dejavu-core fonts-noto-cjk \
  fonts-noto-color-emoji
pkg-config --modversion pangoft2 fontconfig
pkg-config --cflags --libs pangoft2 fontconfig
sh scripts/test_linux_text.sh
```

On Debian 13, use `libfontconfig-dev` in place of Ubuntu's `libfontconfig1-dev`.
The native tests were also run locally on Debian 13 with Pango 1.56.3 and
Fontconfig 2.15.0. `scripts/test_linux_text.sh` checks
that both pkg-config modules and the fixture font faces resolve, supplies a
restricted Fontconfig configuration, clears `DISPLAY` and `WAYLAND_DISPLAY`,
and runs a standalone C consumer of the private mask ABI plus the native Linux
text package's MoonBit tests. This exercises headless measurement and mask
rasterization, not GLES frame presentation. The adapter's C
compiler wrapper accepts the usual `PKG_CONFIG`, `CC`, `CPPFLAGS`, `CFLAGS`, and
`LDFLAGS` overrides when a non-default toolchain is needed. This headless gate
is separate from `scripts/test_ubuntu.sh`, which tests the Wayland/EGL window
backend and grayscale text renderer. PangoFT2 and Fontconfig are now needed to
build Ubuntu text drawing, but do not affect macOS/Windows builds. Use the
repository-pinned MoonBit 0.10.14 toolchain shown in CI to run
the MoonBit package tests.

On Fedora, the corresponding development packages are `pango-devel`,
`fontconfig-devel`, and `pkgconf-pkg-config`; test fixtures are provided by
`dejavu-sans-fonts`, `google-noto-sans-cjk-fonts`, and
`google-noto-color-emoji-fonts`. Fedora installs fonts in different locations,
so set `GPUI_LINUX_TEXT_FONTCONFIG_FILE` to a Fontconfig XML file that points to
those installed font directories before invoking the test script.

CI runs this as an isolated headless job on Ubuntu 24.04. It records the
resolved Pango, Fontconfig, and font package versions rather than asserting
cross-machine metric constants. Ubuntu 24.04's package baseline is Pango 1.52.1
and Fontconfig 2.15.0; CI logs the resolved values in case archive updates
change them. A separate headless geometry probe, run on
Debian 13 with Pango 1.56.3 and Fontconfig 2.15.0, observed DejaVu Sans Book
(Fontconfig font version 155320), Noto Sans CJK JP Regular (131334), and Noto
Color Emoji Regular (134414). These are fixture identities for the local probe, not
universal versions guaranteed by every distro archive. Tests must match the
actual family/run where relevant rather than relying on a particular pixel
width from those observations.

The Noto Color Emoji fixture proves that a PangoFT2 layout can select the font
and compute metrics for an emoji sequence. It does not prove that grayscale
mask rendering supports color emoji: Ubuntu preflights shaped glyphs and
rejects the entire frame with `UnsupportedCapability` if any text item uses a
color glyph. Missing-glyph boxes may follow Pango fallback behavior and do not
prove that the requested glyph was available.

## Ubuntu grayscale scene text

The Ubuntu Wayland/GLES host can draw existing `SceneSnapshot` v1 plain-text
items interleaved with quads in their original paint order. The renderer uses
the same Pango layout implementation and defaults the v1 item to the generic
`sans` family with the item's font size, then rasterizes grayscale A8 masks at
logical resolution. A separate measurement request matches this rendered
geometry only when it uses the same `sans` family, font size, and context; the
measurement API's family-specific queries for other fonts (such as the Noto
test fixtures) do not promise caret/drawing parity. The public scene has no
font-family field. GLES uses `GL_LINEAR` filtering to
transform and smoothly scale those masks to the output; it does not change
Pango's context matrix or request device-resolution hinting. Enlarging or otherwise
scaling a logical-resolution mask can therefore look softer than freshly
rasterized device-resolution text. This is an explicit quality limit of this
slice; filtering does not rerasterize at device scale.

Legacy `TextItem` remains positioned at the bounds' top-left. The new
`TextRunItem` carries an independent item-local `text_origin`; its `bounds`
remain the exact item-local clip for the rasterized ink before the affine
transform. Viewport clip chains remain independent viewport-space scissor
rectangles. The v1 scene envelope permits this item-variant extension without
changing the existing `TextItem` JSON. Consumers that do not know
`TextRunItem` must reject it, and public exhaustive matches need an explicit
arm for it. Frame preflight checks all items and
resources before clearing or submitting; unsupported, invalid, and
resource-limit failures preserve the previously displayed frame. All mask
textures are staged before drawing and released on every exit. This guarantee
covers preflight/presentation of an otherwise live surface; device or surface
loss follows the existing typed recovery behavior and is not a promise that the
last image survives a failed device.

This is a bounded subset, not unrestricted text input. In addition to the
existing total SceneSnapshot item cap, a frame accepts at most 256 text runs,
16,384 UTF-8 bytes per run, 1 MiB total text bytes per frame, and 512 logical
pixels per font size. Each A8 tile is at most 2,048 by 2,048 pixels, total mask
storage is at most 16 MiB per frame, and actual `GL_MAX_TEXTURE_SIZE` is also
enforced. A private resource guard also rejects with `ResourceExhausted` if
`(Unicode scalar count + 1) * font_size_px` exceeds 1,048,576 before
rasterization, bounding combined text/font layout geometry. Values are
rejected, never truncated; arithmetic and size conversions are checked.
Empty/whitespace runs still undergo input and
unsupported-feature validation even if they need no mask. A color glyph
rejects the whole frame before presentation, even when other text is grayscale.

`platform.Capability::GrayscaleTextFrames` is a subset-discovery flag for this
Ubuntu drawing capability. It does not promise that every frame is accepted,
and it does not advertise keyboard text input, an editable control, caret or
selection UI, composition, or IME. Per-frame unsupported checks remain active;
macOS and Windows retain their existing text rejection behavior. The public
`SceneSnapshot` envelope version remains v1, and browser behavior is unchanged.
No atlas, retained
raster cache, or persistent Pango raster handle is introduced.

The local origin-aware field uses one shared checked geometry: logical and ink
extents are unioned; cursor-stop rectangles must stay in the logical line.
Minimums are rounded down and
maximums up to whole logical pixels, and the inset becomes the run origin with
a zero-based clip rectangle. The same mapping feeds admission, caret and
selection painting, hit testing, and horizontal scroll. Headless actual-font
control and negative-mask tests now pass, including composed/decomposed accent
cases and scroll. The source is unpublished local progress based on reviewed
[PR #30](https://github.com/gpui-mbt/gpui.mbt/pull/30) tree `5ac17e9`; PR #30
remains draft. Windows, macOS, docs, and headless Pango jobs passed, while GPU,
core, browser, and mutation jobs remain unqualified. A bounded Ubuntu failed-job
retry was again cancelled before runner start; no source or billing cause is
established. New encoder/GPU acceptance cases compile; hosted execution
is pending, and no GPU execution is claimed. See the [field status guide](linux-text-field.md)
for the complete remaining limits and evidence tiers.

The renderer is an implementation slice whose acceptance checks are tracked in
[issue 0007](../issues/open/0007-ubuntu-native-backend.md). On Debian 13 with
PangoFT2 1.56.3, Fontconfig 2.15.0, and the declared DejaVu/Noto fixtures, the
headless C mask consumer passes normally and under ASan+UBSan with leak
detection disabled. The leak-enabled LeakSanitizer run reports that it does
not work under ptrace in this environment; that is neither a leak pass nor a
product leak failure. Local Weston/GLES execution remains unrun because
AF_UNIX stream socket creation returns `EPERM`. The [PR28 Ubuntu run](https://github.com/gpui-mbt/gpui.mbt/actions/runs/37346110201)
passed the headless adapter and real Weston/llvmpipe mixed-scene checks at 1x/2x
on head `2686fbf15d4c05aeaa373c5eeed401cdcb3b146f`, reviewed tree
`14b8ce67796bcb08e08b60d8fcdb495afb7257b4`. It retains Latin/Japanese clipped/
overlapped PPM readbacks with executed commit, scale and renderer metadata.
PR28 merged as `3cc72f548dc6138e17f949efad8eae92c70a1cb0`, with that same tree.
This bounded software-rendered acceptance does not establish a platform support
tier, hardware performance, editable control or IME.

The separate [experimental Linux text field](linux-text-field.md) guide
documents a bounded single-line LTR field built on merged PR29. It combines
copied text/renderer foundations with a private
opt-in direct XKB/Compose route and an owner-integrated control, but its code is
not part of the merged PR28 renderer and has no reviewed hosted field-CI
result. Actual compositor-delivered typing is unrun. `GrayscaleTextFrames`
still describes drawing only; neither it nor that experimental route qualifies
general text input, IME, desktop support, or a reusable framework field.

## Direct native dependency and license inventory

The Linux-only FFI boundary is the owner of these system libraries. They are
not MoonBit runtime packages and do not enter the macOS or Windows link setup.
The CI job captures exact distro package versions on each run; distribution
updates are not pinned to a specific patch release here.

| Direct build module / API | Purpose | License and Ubuntu packages |
| --- | --- | --- |
| PangoFT2 / Pango (`pangoft2`, `pango`) | Font map, shaping, line/glyph metrics, cursor attributes, caret and hit-test geometry over FreeType | LGPL-2.1-or-later; `libpango1.0-dev` for headers/pkg-config and the linked system runtime |
| Fontconfig (`fontconfig`) | Font discovery/configuration used by the FreeType-backed layout and controlled test font set | MIT-style permissive license; `libfontconfig1-dev` for headers/pkg-config and the linked system runtime |

`pkg-config --cflags --libs pangoft2 fontconfig` is the authoritative local
compiler/linker discovery query used by the test/build wrapper. The runtime
closure is supplied by the distribution and includes Pango's GLib/GObject,
HarfBuzz, FreeType and Fontconfig integrations. It must be re-audited with
resolved versions and license metadata for a release; the concise direct list
above is not a complete transitive SBOM. PangoFT2 and Fontconfig are described
in their [upstream API documentation](https://docs.gtk.org/PangoFT2/) and
[Fontconfig project documentation](https://wiki.freedesktop.org/www/Software/fontconfig/).
The corresponding license texts are in [Pango's COPYING file](https://github.com/GNOME/pango/blob/main/COPYING)
and [Fontconfig's COPYING file](https://sources.debian.org/src/fontconfig/2.15.0-2.3/COPYING/).
