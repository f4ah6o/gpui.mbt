# Headless Linux text measurement

`platform/linux_text/` is an experimental Linux-native text-geometry adapter.
It uses PangoFT2 with FreeType and the installed Fontconfig font set to measure
shaped text and answer copied caret/hit-test geometry queries. It runs without
GTK, a window, an X11/Wayland display server, MZed, or a renderer. The portable
`text/` value model and `primitives/` remain MoonBit-only; the native adapter
does not add Pango values or handles to that public model.

This package is a layout/measurement aid, not a text renderer or a full editor
text system. Native pointers and Pango structs stay inside the Linux boundary;
calls return copied values. The adapter retains no Pango font map, context,
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
  navigation, IME behavior, accessibility, or visual raster output.
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
and runs only the native Linux text package's MoonBit tests. The adapter's C
compiler wrapper accepts the usual `PKG_CONFIG`, `CC`, `CPPFLAGS`, `CFLAGS`, and
`LDFLAGS` overrides when a non-default toolchain is needed. This headless gate
is separate from `scripts/test_ubuntu.sh`, which tests the Wayland/EGL window
backend. Installing Pango is not needed for the Wayland demo or macOS/Windows
builds. Use the repository-pinned MoonBit 0.10.14 toolchain shown in CI to run
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
and compute metrics for an emoji sequence. It does not prove that this package
can rasterize or display color emoji. The adapter does not call a renderer;
FT2 emoji metrics, including unusually tall fixed-strike metrics, are not a
visual-rendering support claim.

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
