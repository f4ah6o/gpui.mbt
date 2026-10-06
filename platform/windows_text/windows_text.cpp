#include "windows_text.h"

#if defined(_WIN32)

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <dwrite.h>
#include <dwrite_2.h>
#include <dwrite_3.h>
#include <wrl/client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <cwctype>
#include <limits>
#include <new>
#include <string>
#include <vector>

#pragma comment(lib, "dwrite.lib")

using Microsoft::WRL::ComPtr;

namespace {

struct Boundary {
  int32_t byte_offset;
  uint32_t utf16_offset;
  uint32_t weak_utf16_offset;
  bool cursor;
};

struct Layout {
  ComPtr<IDWriteFactory> factory;
  ComPtr<IDWriteFactory2> factory2;
  ComPtr<IDWriteTextFormat> format;
  ComPtr<IDWriteTextLayout> layout;
  std::wstring text;
  DWRITE_TEXT_METRICS metrics{};
  DWRITE_OVERHANG_METRICS overhang{};
  DWRITE_LINE_METRICS first_line{};
  std::vector<Boundary> boundaries;
  float layout_width = 0.0f;
  float layout_height = 0.0f;
  double ink_left = 0.0;
  double ink_top = 0.0;
  double ink_right = 0.0;
  double ink_bottom = 0.0;
  int32_t unknown_glyph_count = 0;
  bool has_color_glyphs = false;
  bool has_color_metadata = true;
};

struct RasterContext {
  IDWriteFactory2 *factory;
  const RECT *tile;
  uint8_t *pixels;
  int32_t width;
  int32_t height;
  int32_t status;
  int32_t unknown_glyph_count;
  bool has_color_glyphs;
  bool has_color_metadata;
  bool rasterize;
  FLOAT pixels_per_dip = 1.0f;
};

static const UINT32 GPUI_UNSUPPORTED_COLOR_GLYPH_FORMATS =
    DWRITE_GLYPH_IMAGE_FORMATS_COLR | DWRITE_GLYPH_IMAGE_FORMATS_SVG |
    DWRITE_GLYPH_IMAGE_FORMATS_PNG | DWRITE_GLYPH_IMAGE_FORMATS_JPEG |
    DWRITE_GLYPH_IMAGE_FORMATS_TIFF |
    DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8 |
    DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE;

static bool has_unsupported_color_format(DWRITE_GLYPH_IMAGE_FORMATS formats) {
  return (static_cast<UINT32>(formats) &
          GPUI_UNSUPPORTED_COLOR_GLYPH_FORMATS) != 0;
}

static bool finite_bounded(double value, double bound = 1.0e20) {
  return std::isfinite(value) && std::abs(value) <= bound;
}

static bool utf8_to_wide(const uint8_t *bytes, int32_t length,
                         std::wstring *output) {
  if (!output || length < 0 || (length > 0 && !bytes) ||
      (length > 0 && std::memchr(bytes, 0, static_cast<size_t>(length))))
    return false;
  output->clear();
  if (length == 0)
    return true;
  int32_t units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                      reinterpret_cast<LPCCH>(bytes), length,
                                      nullptr, 0);
  if (units <= 0)
    return false;
  try {
    output->resize(static_cast<size_t>(units));
  } catch (const std::bad_alloc &) {
    return false;
  }
  // std::wstring::data() is const before C++17. MoonBit's native-stub
  // compiler currently uses the default MSVC language mode, so write through
  // the guaranteed contiguous mutable element storage instead.
  return MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                             reinterpret_cast<LPCCH>(bytes), length,
                             &(*output)[0], units) == units;
}

static int32_t decode_scalar(const uint8_t *bytes, int32_t length,
                             int32_t offset, uint32_t *scalar,
                             int32_t *width) {
  if (!bytes || !scalar || !width || offset < 0 || offset >= length)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  uint8_t first = bytes[offset];
  if (first < 0x80) {
    *scalar = first;
    *width = 1;
    return GPUI_WINDOWS_TEXT_OK;
  }
  int32_t count = first >= 0xc2 && first <= 0xdf ? 2
                  : first >= 0xe0 && first <= 0xef ? 3
                  : first >= 0xf0 && first <= 0xf4 ? 4
                                                   : 0;
  if (!count || offset > length - count)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  uint32_t value = first & (count == 2 ? 0x1f : count == 3 ? 0x0f : 0x07);
  for (int32_t i = 1; i < count; ++i) {
    uint8_t continuation = bytes[offset + i];
    if ((continuation & 0xc0) != 0x80)
      return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
    value = (value << 6) | (continuation & 0x3f);
  }
  if ((count == 2 && value < 0x80) || (count == 3 && value < 0x800) ||
      (count == 4 && value < 0x10000) || value > 0x10ffff ||
      (value >= 0xd800 && value <= 0xdfff))
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  *scalar = value;
  *width = count;
  return GPUI_WINDOWS_TEXT_OK;
}

static bool forbidden_single_line_scalar(uint32_t scalar) {
  return scalar == 0 || scalar == 0x0a || scalar == 0x0d ||
         scalar == 0x2028 || scalar == 0x2029;
}

static int32_t build_boundaries(const uint8_t *bytes, int32_t byte_length,
                                const std::wstring &wide,
                                IDWriteTextLayout *text_layout,
                                std::vector<Boundary> *output) {
  if (!output || !text_layout)
    return GPUI_WINDOWS_TEXT_INVALID_ARGUMENT;
  std::vector<Boundary> boundaries;
  try {
    boundaries.reserve(static_cast<size_t>(byte_length) + 1);
    boundaries.push_back({0, 0, 0, true});
  } catch (const std::bad_alloc &) {
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  }
  int32_t byte_offset = 0;
  uint32_t utf16_offset = 0;
  while (byte_offset < byte_length) {
    uint32_t scalar = 0;
    int32_t width = 0;
    int32_t status = decode_scalar(bytes, byte_length, byte_offset, &scalar,
                                   &width);
    if (status != GPUI_WINDOWS_TEXT_OK)
      return status;
    if (forbidden_single_line_scalar(scalar))
      return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
    byte_offset += width;
    utf16_offset += scalar > 0xffff ? 2u : 1u;
    try {
      boundaries.push_back({byte_offset, utf16_offset, utf16_offset, false});
    } catch (const std::bad_alloc &) {
      return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
    }
  }
  if (utf16_offset != wide.size())
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;

  UINT32 cluster_count = 0;
  HRESULT hr = text_layout->GetClusterMetrics(nullptr, 0, &cluster_count);
  if (FAILED(hr) && hr != E_NOT_SUFFICIENT_BUFFER)
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  if (cluster_count > utf16_offset)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  std::vector<DWRITE_CLUSTER_METRICS> clusters;
  try {
    clusters.resize(cluster_count);
  } catch (const std::bad_alloc &) {
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  }
  if (cluster_count > 0) {
    UINT32 actual = 0;
    hr = text_layout->GetClusterMetrics(clusters.data(), cluster_count,
                                        &actual);
    if (FAILED(hr) || actual != cluster_count)
      return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  }
  std::vector<uint32_t> cluster_boundaries;
  try {
    cluster_boundaries.reserve(static_cast<size_t>(cluster_count) + 1);
    cluster_boundaries.push_back(0);
  } catch (const std::bad_alloc &) {
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  }
  uint32_t cumulative = 0;
  for (const DWRITE_CLUSTER_METRICS &cluster : clusters) {
    if (cluster.length == 0 || cumulative > UINT32_MAX - cluster.length)
      return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
    // The portable caret contract exposes strong and weak positions for a
    // logical boundary. This adapter intentionally qualifies only LTR text;
    // returning the same location for a bidi boundary would fabricate weak
    // caret geometry. Callers can still use unsupported text on other APIs.
    if (cluster.isRightToLeft)
      return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
    cumulative += cluster.length;
    cluster_boundaries.push_back(cumulative);
  }
  if (cumulative != utf16_offset)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  size_t cluster_index = 0;
  for (Boundary &boundary : boundaries) {
    while (cluster_index < cluster_boundaries.size() &&
           cluster_boundaries[cluster_index] < boundary.utf16_offset)
      ++cluster_index;
    boundary.cursor = cluster_index < cluster_boundaries.size() &&
                      cluster_boundaries[cluster_index] ==
                          boundary.utf16_offset;
  }
  *output = std::move(boundaries);
  return GPUI_WINDOWS_TEXT_OK;
}

static int32_t create_layout(int32_t abi, const uint8_t *text,
                             int32_t text_length, const uint8_t *family,
                             int32_t family_length, double font_size,
                             Layout *result) {
  if (!result || abi != GPUI_WINDOWS_TEXT_ABI || text_length < 0 ||
      family_length < 0 || (text_length > 0 && !text) || !family)
    return GPUI_WINDOWS_TEXT_INVALID_ARGUMENT;
  if (text_length > GPUI_WINDOWS_TEXT_MAX_TEXT_BYTES ||
      family_length > GPUI_WINDOWS_TEXT_MAX_FAMILY_BYTES)
    return GPUI_WINDOWS_TEXT_INPUT_TOO_LARGE;
  if (!std::isfinite(font_size) || font_size <= 0.0 ||
      font_size > GPUI_WINDOWS_TEXT_MAX_FONT_SIZE)
    return GPUI_WINDOWS_TEXT_INVALID_FONT_SIZE;
  if (family_length == 0 || std::memchr(family, 0, (size_t)family_length))
    return GPUI_WINDOWS_TEXT_INVALID_FONT_FAMILY;

  std::wstring wide_family;
  if (!utf8_to_wide(family, family_length, &wide_family))
    return GPUI_WINDOWS_TEXT_INVALID_FONT_FAMILY;
  bool has_family_scalar = false;
  for (wchar_t value : wide_family)
    if (!iswspace(value))
      has_family_scalar = true;
  if (!has_family_scalar)
    return GPUI_WINDOWS_TEXT_INVALID_FONT_FAMILY;
  if (!utf8_to_wide(text, text_length, &result->text))
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  for (wchar_t value : result->text) {
    uint32_t scalar = static_cast<uint16_t>(value);
    if (scalar == 0 || scalar == 0x0a || scalar == 0x0d ||
        scalar == 0x2028 || scalar == 0x2029)
      return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  }

  HRESULT hr = DWriteCreateFactory(
      DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
      reinterpret_cast<IUnknown **>(result->factory.GetAddressOf()));
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  hr = result->factory.As(&result->factory2);
  if (FAILED(hr))
    result->factory2.Reset();
  hr = result->factory->CreateTextFormat(
      wide_family.c_str(), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
      static_cast<FLOAT>(font_size), L"en-us", &result->format);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_INVALID_FONT_FAMILY;
  hr = result->format->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  const FLOAT layout_limit = 10000000.0f;
  const WCHAR *layout_text = result->text.empty() ? L"" : result->text.data();
  hr = result->factory->CreateTextLayout(
      layout_text, static_cast<UINT32>(result->text.size()),
      result->format.Get(), layout_limit, layout_limit, &result->layout);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  hr = result->layout->GetMetrics(&result->metrics);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  // Overhangs are measured from the layout box, not from the text metrics.
  // The initial box is intentionally generous to avoid wrapping; shrink it
  // around the measured run before asking DirectWrite for ink overhangs. This
  // also keeps the layout's float coordinates well conditioned.
  result->layout_width = std::max(
      1.0f, result->metrics.widthIncludingTrailingWhitespace);
  result->layout_height = std::max(1.0f, result->metrics.height);
  hr = result->layout->SetMaxWidth(result->layout_width);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  hr = result->layout->SetMaxHeight(result->layout_height);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  hr = result->layout->GetMetrics(&result->metrics);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  UINT32 line_count = 0;
  hr = result->layout->GetLineMetrics(nullptr, 0, &line_count);
  if (FAILED(hr) && hr != E_NOT_SUFFICIENT_BUFFER)
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  if (line_count != 1)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT;
  std::vector<DWRITE_LINE_METRICS> lines;
  try {
    lines.resize(line_count);
  } catch (const std::bad_alloc &) {
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  }
  UINT32 actual_lines = 0;
  hr = result->layout->GetLineMetrics(lines.data(), line_count,
                                      &actual_lines);
  if (FAILED(hr) || actual_lines != line_count)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  result->first_line = lines[0];
  hr = result->layout->GetOverhangMetrics(&result->overhang);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  result->ink_left = result->metrics.left - result->overhang.left;
  result->ink_top = result->metrics.top - result->overhang.top;
  result->ink_right = result->metrics.left + result->layout_width +
                      result->overhang.right;
  result->ink_bottom = result->metrics.top + result->layout_height +
                       result->overhang.bottom;
  if (!finite_bounded(result->metrics.widthIncludingTrailingWhitespace) ||
      !finite_bounded(result->metrics.height) ||
      !finite_bounded(result->first_line.baseline) ||
      !finite_bounded(result->ink_left) || !finite_bounded(result->ink_top) ||
      !finite_bounded(result->ink_right) ||
      !finite_bounded(result->ink_bottom) ||
      result->metrics.widthIncludingTrailingWhitespace < 0.0f ||
      result->metrics.height <= 0.0f || result->first_line.baseline < 0.0f ||
      result->ink_right < result->ink_left ||
      result->ink_bottom < result->ink_top)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  int32_t status = build_boundaries(text, text_length, result->text,
                                    result->layout.Get(),
                                    &result->boundaries);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  return GPUI_WINDOWS_TEXT_OK;
}

static bool int32_from_double(double value, int32_t *output) {
  if (!output || !finite_bounded(value, 2147483000.0))
    return false;
  double rounded = std::floor(value);
  if (rounded < static_cast<double>(std::numeric_limits<int32_t>::min()) ||
      rounded > static_cast<double>(std::numeric_limits<int32_t>::max()))
    return false;
  *output = static_cast<int32_t>(rounded);
  return true;
}

static size_t boundary_index(const std::vector<Boundary> &boundaries,
                             uint32_t utf16_offset) {
  for (size_t i = 0; i < boundaries.size(); ++i)
    if (boundaries[i].utf16_offset == utf16_offset)
      return i;
  return boundaries.size();
}

static int32_t inspect_glyph_run(const DWRITE_GLYPH_RUN *glyph_run,
                                FLOAT baseline_x, FLOAT baseline_y,
                                RasterContext *context) {
  if (!glyph_run || !context)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  if (glyph_run->glyphCount && !glyph_run->glyphIndices)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  for (UINT32 i = 0; i < glyph_run->glyphCount; ++i) {
    if (glyph_run->glyphIndices[i] == 0) {
      if (context->unknown_glyph_count == INT32_MAX)
        return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
      ++context->unknown_glyph_count;
    }
  }
  if (glyph_run->glyphCount == 0)
    return GPUI_WINDOWS_TEXT_OK;

  ComPtr<IDWriteFontFace4> face4;
  HRESULT hr = glyph_run->fontFace->QueryInterface(IID_PPV_ARGS(&face4));
  if (FAILED(hr)) {
    context->has_color_metadata = false;
    return context->rasterize ? GPUI_WINDOWS_TEXT_UNSUPPORTED_RASTER
                              : GPUI_WINDOWS_TEXT_OK;
  }
  double physical_em_size =
      static_cast<double>(glyph_run->fontEmSize) * context->pixels_per_dip;
  if (!std::isfinite(physical_em_size) || physical_em_size <= 0.0 ||
      physical_em_size > static_cast<double>(UINT32_MAX))
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  const UINT32 pixels_per_em = static_cast<UINT32>(
      std::max(1.0, std::ceil(physical_em_size)));
  for (UINT32 i = 0; i < glyph_run->glyphCount; ++i) {
    DWRITE_GLYPH_IMAGE_FORMATS formats = DWRITE_GLYPH_IMAGE_FORMATS_NONE;
    hr = face4->GetGlyphImageFormats(glyph_run->glyphIndices[i], pixels_per_em,
                                     pixels_per_em, &formats);
    if (FAILED(hr)) {
      context->has_color_metadata = false;
      return context->rasterize ? GPUI_WINDOWS_TEXT_UNSUPPORTED_RASTER
                                : GPUI_WINDOWS_TEXT_OK;
    }
    if (has_unsupported_color_format(formats))
      context->has_color_glyphs = true;
  }
  if (!context->rasterize)
    return GPUI_WINDOWS_TEXT_OK;
  if (context->unknown_glyph_count > 0)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_GLYPH;
  if (context->has_color_glyphs)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_COLOR;

  ComPtr<IDWriteGlyphRunAnalysis> analysis;
  // Layout and baseline coordinates are DIPs. The Factory2 transform is
  // applied after DirectWrite's em-size scaling, so this single matrix maps
  // the copied glyph run into the physical-pixel mask without changing the
  // logical geometry consumed by hit testing or the scene renderer.
  const DWRITE_MATRIX physical_transform = {
      context->pixels_per_dip, 0.0f, 0.0f, context->pixels_per_dip, 0.0f, 0.0f};
  hr = context->factory->CreateGlyphRunAnalysis(
      glyph_run, &physical_transform, DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
      DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_ENABLED,
      DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, baseline_x, baseline_y, &analysis);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  RECT bounds{};
  // Factory2's grayscale mode returns one coverage value per pixel through
  // the historical ALIASED_1x1 texture slot. The ClearType slot contains
  // three subpixel samples and cannot be averaged without losing color safety.
  hr = analysis->GetAlphaTextureBounds(DWRITE_TEXTURE_ALIASED_1x1, &bounds);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  RECT clipped{std::max(bounds.left, context->tile->left),
               std::max(bounds.top, context->tile->top),
               std::min(bounds.right, context->tile->right),
               std::min(bounds.bottom, context->tile->bottom)};
  if (clipped.right <= clipped.left || clipped.bottom <= clipped.top)
    return GPUI_WINDOWS_TEXT_OK;
  uint64_t width = static_cast<uint64_t>(clipped.right - clipped.left);
  uint64_t height = static_cast<uint64_t>(clipped.bottom - clipped.top);
  if (width > GPUI_WINDOWS_TEXT_MAX_MASK_DIMENSION ||
      height > GPUI_WINDOWS_TEXT_MAX_MASK_DIMENSION ||
      width * height > GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS ||
      width * height > std::numeric_limits<UINT32>::max())
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  size_t area = static_cast<size_t>(width * height);
  uint8_t *alpha = static_cast<uint8_t *>(std::malloc(area));
  if (!alpha)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  hr = analysis->CreateAlphaTexture(DWRITE_TEXTURE_ALIASED_1x1, &clipped,
                                    alpha, static_cast<UINT32>(area));
  if (FAILED(hr)) {
    std::free(alpha);
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  }
  for (int32_t y = clipped.top; y < clipped.bottom; ++y) {
    for (int32_t x = clipped.left; x < clipped.right; ++x) {
      size_t source = static_cast<size_t>(y - clipped.top) * width +
                      static_cast<size_t>(x - clipped.left);
      uint8_t coverage = alpha[source];
      size_t destination = static_cast<size_t>(y - context->tile->top) *
                               static_cast<size_t>(context->width) +
                           static_cast<size_t>(x - context->tile->left);
      uint32_t old_alpha = context->pixels[destination];
      context->pixels[destination] = static_cast<uint8_t>(
          coverage + (old_alpha * (255u - coverage) + 127u) / 255u);
    }
  }
  std::free(alpha);
  return GPUI_WINDOWS_TEXT_OK;
}

class TextRenderer final : public IDWriteTextRenderer {
 public:
  explicit TextRenderer(RasterContext *context) : context_(context) {}

  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **object) override {
    if (!object)
      return E_POINTER;
    *object = nullptr;
    if (riid == __uuidof(IUnknown) || riid == __uuidof(IDWritePixelSnapping) ||
        riid == __uuidof(IDWriteTextRenderer)) {
      *object = static_cast<IDWriteTextRenderer *>(this);
      AddRef();
      return S_OK;
    }
    return E_NOINTERFACE;
  }

  ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

  ULONG STDMETHODCALLTYPE Release() override {
    ULONG remaining = --references_;
    if (remaining == 0)
      delete this;
    return remaining;
  }

  HRESULT STDMETHODCALLTYPE IsPixelSnappingDisabled(void *, BOOL *disabled) override {
    if (!disabled)
      return E_POINTER;
    *disabled = FALSE;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetCurrentTransform(void *, DWRITE_MATRIX *matrix) override {
    if (!matrix)
      return E_POINTER;
    *matrix = {1.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f};
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE GetPixelsPerDip(void *, FLOAT *pixels_per_dip) override {
    if (!pixels_per_dip)
      return E_POINTER;
    *pixels_per_dip = context_ ? context_->pixels_per_dip : 1.0f;
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DrawGlyphRun(
    void *, FLOAT baseline_x, FLOAT baseline_y, DWRITE_MEASURING_MODE,
      const DWRITE_GLYPH_RUN *glyph_run,
      const DWRITE_GLYPH_RUN_DESCRIPTION *, IUnknown *) override {
    if (!context_)
      return E_POINTER;
    if (context_->status != GPUI_WINDOWS_TEXT_OK)
      return E_FAIL;
    int32_t status = inspect_glyph_run(glyph_run, baseline_x, baseline_y,
                                       context_);
    if (status != GPUI_WINDOWS_TEXT_OK) {
      context_->status = status;
      return E_FAIL;
    }
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DrawUnderline(
      void *, FLOAT, FLOAT, const DWRITE_UNDERLINE *, IUnknown *) override {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DrawStrikethrough(
      void *, FLOAT, FLOAT, const DWRITE_STRIKETHROUGH *, IUnknown *) override {
    return S_OK;
  }

  HRESULT STDMETHODCALLTYPE DrawInlineObject(
      void *, FLOAT, FLOAT, IDWriteInlineObject *, BOOL, BOOL,
      IUnknown *) override {
    if (context_)
      context_->status = GPUI_WINDOWS_TEXT_UNSUPPORTED_RASTER;
    return E_NOTIMPL;
  }

 private:
  volatile ULONG references_ = 1;
  RasterContext *context_;
};

static int32_t inspect_layout(Layout *layout) {
  if (!layout || !layout->layout)
    return GPUI_WINDOWS_TEXT_INVALID_ARGUMENT;
  RasterContext context{};
  context.status = GPUI_WINDOWS_TEXT_OK;
  context.has_color_metadata = true;
  context.rasterize = false;
  context.pixels_per_dip = 1.0f;
  TextRenderer *renderer = new (std::nothrow) TextRenderer(&context);
  if (!renderer)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  HRESULT hr = layout->layout->Draw(nullptr, renderer, 0.0f, 0.0f);
  renderer->Release();
  if (context.status != GPUI_WINDOWS_TEXT_OK)
    return context.status;
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  layout->unknown_glyph_count = context.unknown_glyph_count;
  layout->has_color_glyphs = context.has_color_glyphs;
  layout->has_color_metadata = context.has_color_metadata;
  return GPUI_WINDOWS_TEXT_OK;
}

static void write_rect(double *output, double x, double y, double width,
                       double height) {
  output[0] = x;
  output[1] = y;
  output[2] = width;
  output[3] = height;
}

static int32_t native_measure(int32_t abi, const uint8_t *text,
                              int32_t text_length, const uint8_t *family,
                              int32_t family_length, double font_size,
                              double *output, int32_t capacity) {
  if (!output || capacity < GPUI_WINDOWS_TEXT_HEADER_DOUBLES)
    return GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL;
  Layout layout;
  int32_t status = create_layout(abi, text, text_length, family, family_length,
                                 font_size, &layout);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  status = inspect_layout(&layout);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  const size_t count = layout.boundaries.size();
  if (count > static_cast<size_t>(
                  (INT32_MAX - GPUI_WINDOWS_TEXT_HEADER_DOUBLES) /
                  GPUI_WINDOWS_TEXT_CARET_DOUBLES))
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  const int32_t required = GPUI_WINDOWS_TEXT_HEADER_DOUBLES +
      GPUI_WINDOWS_TEXT_CARET_DOUBLES * static_cast<int32_t>(count);
  if (capacity < required)
    return GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL;
  double *scratch = static_cast<double *>(
      std::calloc(static_cast<size_t>(required), sizeof(double)));
  if (!scratch)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  write_rect(scratch, layout.metrics.left, layout.metrics.top,
             layout.metrics.widthIncludingTrailingWhitespace,
             layout.metrics.height);
  double ink_width = std::max(0.0, layout.ink_right - layout.ink_left);
  double ink_height = std::max(0.0, layout.ink_bottom - layout.ink_top);
  write_rect(scratch + 4, layout.ink_left, layout.ink_top, ink_width,
             ink_height);
  scratch[8] = layout.first_line.baseline;
  scratch[9] = 1.0;
  scratch[10] = layout.unknown_glyph_count;
  scratch[11] = static_cast<double>(count);
  for (size_t i = 0; i < count; ++i) {
    const Boundary &boundary = layout.boundaries[i];
    FLOAT leading_x = 0.0f, leading_y = 0.0f;
    DWRITE_HIT_TEST_METRICS leading_metrics{};
    HRESULT hr = layout.layout->HitTestTextPosition(
        boundary.utf16_offset, FALSE, &leading_x, &leading_y,
        &leading_metrics);
    if (FAILED(hr)) {
      std::free(scratch);
      return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
    }
    double *caret = scratch + GPUI_WINDOWS_TEXT_HEADER_DOUBLES +
                    i * GPUI_WINDOWS_TEXT_CARET_DOUBLES;
    caret[0] = boundary.byte_offset;
    caret[1] = boundary.cursor ? 1.0 : 0.0;
    write_rect(caret + 2, leading_x, leading_y, 0.0, layout.first_line.height);
    FLOAT weak_x = leading_x, weak_y = leading_y;
    if (boundary.cursor && boundary.weak_utf16_offset != boundary.utf16_offset) {
      DWRITE_HIT_TEST_METRICS weak_metrics{};
      hr = layout.layout->HitTestTextPosition(
          boundary.weak_utf16_offset, TRUE, &weak_x, &weak_y, &weak_metrics);
      if (FAILED(hr)) {
        std::free(scratch);
        return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
      }
    }
    write_rect(caret + 6, weak_x, weak_y, 0.0, layout.first_line.height);
    for (int32_t j = 2; j < GPUI_WINDOWS_TEXT_CARET_DOUBLES; ++j) {
      if (!finite_bounded(caret[j])) {
        std::free(scratch);
        return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
      }
    }
  }
  std::memcpy(output, scratch, static_cast<size_t>(required) * sizeof(double));
  std::free(scratch);
  return GPUI_WINDOWS_TEXT_OK;
}

static int32_t native_hit_test(int32_t abi, const uint8_t *text,
                               int32_t text_length, const uint8_t *family,
                               int32_t family_length, double font_size,
                               double x, double y, double *output,
                               int32_t capacity) {
  if (!output || capacity < 5)
    return GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL;
  if (!finite_bounded(x) || !finite_bounded(y))
    return GPUI_WINDOWS_TEXT_INVALID_COORDINATES;
  Layout layout;
  int32_t status = create_layout(abi, text, text_length, family, family_length,
                                 font_size, &layout);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  status = inspect_layout(&layout);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  BOOL inside = FALSE, trailing = FALSE;
  DWRITE_HIT_TEST_METRICS metrics{};
  HRESULT hr = layout.layout->HitTestPoint(static_cast<FLOAT>(x),
                                            static_cast<FLOAT>(y), &trailing,
                                            &inside, &metrics);
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  uint64_t end64 = static_cast<uint64_t>(metrics.textPosition) + metrics.length;
  if (metrics.textPosition > layout.text.size() || end64 > layout.text.size())
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  size_t start = boundary_index(layout.boundaries, metrics.textPosition);
  size_t end = boundary_index(layout.boundaries, static_cast<uint32_t>(end64));
  if (start == layout.boundaries.size() || end == layout.boundaries.size() ||
      end < start)
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  size_t resolved = trailing ? end : start;
  output[0] = layout.boundaries[start].byte_offset;
  output[1] = static_cast<double>(resolved - start);
  output[2] = layout.boundaries[resolved].byte_offset;
  output[3] = inside ? 1.0 : 0.0;
  output[4] = layout.boundaries[resolved].cursor ? 1.0 : 0.0;
  return GPUI_WINDOWS_TEXT_OK;
}

static int32_t native_raster(int32_t abi, const uint8_t *text,
                             int32_t text_length, const uint8_t *family,
                             int32_t family_length, double pixels_per_dip,
                             double font_size,
                             double origin_x, double origin_y, double clip_x,
                             double clip_y, double clip_width,
                             double clip_height, int32_t pixel_budget,
                             GpuiWindowsTextMask *output) {
  if (abi != GPUI_WINDOWS_TEXT_RASTER_ABI)
    return GPUI_WINDOWS_TEXT_INVALID_ARGUMENT;
  if (!output || pixel_budget < 0 || !finite_bounded(origin_x) ||
      !finite_bounded(origin_y) || !finite_bounded(clip_x) ||
      !finite_bounded(clip_y) || !finite_bounded(clip_width) ||
      !finite_bounded(clip_height) || clip_width < 0.0 || clip_height < 0.0 ||
      clip_width > GPUI_WINDOWS_TEXT_MAX_SCENE_WIDTH ||
      clip_height > GPUI_WINDOWS_TEXT_MAX_SCENE_HEIGHT)
    return GPUI_WINDOWS_TEXT_INVALID_COORDINATES;
  if (!std::isfinite(pixels_per_dip) ||
      pixels_per_dip < GPUI_WINDOWS_TEXT_MIN_PIXELS_PER_DIP ||
      pixels_per_dip > GPUI_WINDOWS_TEXT_MAX_PIXELS_PER_DIP)
    return GPUI_WINDOWS_TEXT_INVALID_SCALE;
  if (text_length > GPUI_WINDOWS_TEXT_MAX_SCENE_BYTES)
    return GPUI_WINDOWS_TEXT_INPUT_TOO_LARGE;
  if (!std::isfinite(font_size) || font_size <= 0.0 ||
      font_size > GPUI_WINDOWS_TEXT_MAX_SCENE_FONT_SIZE)
    return GPUI_WINDOWS_TEXT_INVALID_FONT_SIZE;
  double clip_right = clip_x + clip_width;
  double clip_bottom = clip_y + clip_height;
  double local_clip_left = clip_x - origin_x;
  double local_clip_top = clip_y - origin_y;
  double local_clip_right = clip_right - origin_x;
  double local_clip_bottom = clip_bottom - origin_y;
  if (!finite_bounded(clip_right) || !finite_bounded(clip_bottom) ||
      !finite_bounded(local_clip_left) || !finite_bounded(local_clip_top) ||
      !finite_bounded(local_clip_right) || !finite_bounded(local_clip_bottom))
    return GPUI_WINDOWS_TEXT_INVALID_COORDINATES;
  Layout layout;
  int32_t status = create_layout(GPUI_WINDOWS_TEXT_ABI, text, text_length,
                                 family, family_length, font_size, &layout);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  RasterContext inspect{};
  inspect.status = GPUI_WINDOWS_TEXT_OK;
  inspect.has_color_metadata = true;
  inspect.rasterize = false;
  inspect.pixels_per_dip = static_cast<FLOAT>(pixels_per_dip);
  TextRenderer *scanner = new (std::nothrow) TextRenderer(&inspect);
  if (!scanner)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  HRESULT hr = layout.layout->Draw(nullptr, scanner, 0.0f, 0.0f);
  scanner->Release();
  if (inspect.status != GPUI_WINDOWS_TEXT_OK)
    return inspect.status;
  if (FAILED(hr))
    return GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  if (inspect.unknown_glyph_count > 0)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_GLYPH;
  if (inspect.has_color_glyphs)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_COLOR;
  if (!inspect.has_color_metadata || !layout.factory2)
    return GPUI_WINDOWS_TEXT_UNSUPPORTED_RASTER;

  double left = std::max(local_clip_left, layout.ink_left);
  double top = std::max(local_clip_top, layout.ink_top);
  double right = std::min(local_clip_right, layout.ink_right);
  double bottom = std::min(local_clip_bottom, layout.ink_bottom);
  GpuiWindowsTextMask result{};
  if (text_length == 0 || right <= left || bottom <= top) {
    *output = result;
    return GPUI_WINDOWS_TEXT_OK;
  }
  if (std::abs(left) > 1.0e7 || std::abs(top) > 1.0e7 ||
      std::abs(right) > 1.0e7 || std::abs(bottom) > 1.0e7)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  double physical_left = left * pixels_per_dip;
  double physical_top = top * pixels_per_dip;
  double physical_right = right * pixels_per_dip;
  double physical_bottom = bottom * pixels_per_dip;
  if (!finite_bounded(physical_left) || !finite_bounded(physical_top) ||
      !finite_bounded(physical_right) || !finite_bounded(physical_bottom) ||
      std::abs(physical_left) > 1.0e7 ||
      std::abs(physical_top) > 1.0e7 ||
      std::abs(physical_right) > 1.0e7 ||
      std::abs(physical_bottom) > 1.0e7)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  int32_t tile_left = 0, tile_top = 0, tile_right = 0, tile_bottom = 0;
  if (!int32_from_double(std::floor(physical_left) - 1.0, &tile_left) ||
      !int32_from_double(std::floor(physical_top) - 1.0, &tile_top) ||
      !int32_from_double(std::ceil(physical_right) + 1.0, &tile_right) ||
      !int32_from_double(std::ceil(physical_bottom) + 1.0, &tile_bottom))
    return GPUI_WINDOWS_TEXT_INVALID_COORDINATES;
  int64_t width64 = static_cast<int64_t>(tile_right) - tile_left;
  int64_t height64 = static_cast<int64_t>(tile_bottom) - tile_top;
  if (width64 <= 0 || height64 <= 0 ||
      width64 > GPUI_WINDOWS_TEXT_MAX_MASK_DIMENSION ||
      height64 > GPUI_WINDOWS_TEXT_MAX_MASK_DIMENSION ||
      width64 * height64 > pixel_budget ||
      width64 * height64 > GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  size_t area = static_cast<size_t>(width64 * height64);
  uint8_t *pixels = static_cast<uint8_t *>(std::calloc(area, 1));
  if (!pixels)
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  RECT tile{tile_left, tile_top, tile_right, tile_bottom};
  RasterContext raster{};
  raster.factory = layout.factory2.Get();
  raster.tile = &tile;
  raster.pixels = pixels;
  raster.width = static_cast<int32_t>(width64);
  raster.height = static_cast<int32_t>(height64);
  raster.status = GPUI_WINDOWS_TEXT_OK;
  raster.has_color_metadata = true;
  raster.rasterize = true;
  raster.pixels_per_dip = static_cast<FLOAT>(pixels_per_dip);
  TextRenderer *renderer = new (std::nothrow) TextRenderer(&raster);
  if (!renderer) {
    std::free(pixels);
    return GPUI_WINDOWS_TEXT_RESOURCE_LIMIT;
  }
  hr = layout.layout->Draw(nullptr, renderer, 0.0f, 0.0f);
  renderer->Release();
  if (raster.status != GPUI_WINDOWS_TEXT_OK || FAILED(hr)) {
    std::free(pixels);
    return raster.status != GPUI_WINDOWS_TEXT_OK
               ? raster.status
               : GPUI_WINDOWS_TEXT_NATIVE_FAILURE;
  }
  bool has_ink = false;
  for (size_t i = 0; i < area; ++i) {
    if (pixels[i]) {
      has_ink = true;
      break;
    }
  }
  if (!has_ink) {
    std::free(pixels);
    *output = result;
    return GPUI_WINDOWS_TEXT_OK;
  }
  result.pixels = pixels;
  result.width = static_cast<int32_t>(width64);
  result.height = static_cast<int32_t>(height64);
  result.left = origin_x + left;
  result.top = origin_y + top;
  result.right = origin_x + right;
  result.bottom = origin_y + bottom;
  result.u0 = (physical_left - tile_left) / static_cast<double>(width64);
  result.v0 = (physical_top - tile_top) / static_cast<double>(height64);
  result.u1 = (physical_right - tile_left) / static_cast<double>(width64);
  result.v1 = (physical_bottom - tile_top) / static_cast<double>(height64);
  if (!finite_bounded(result.left) || !finite_bounded(result.top) ||
      !finite_bounded(result.right) || !finite_bounded(result.bottom) ||
      result.right <= result.left || result.bottom <= result.top ||
      !std::isfinite(result.u0) || !std::isfinite(result.v0) ||
      !std::isfinite(result.u1) || !std::isfinite(result.v1) ||
      result.u0 < 0.0 || result.v0 < 0.0 || result.u1 > 1.0 ||
      result.v1 > 1.0 || result.u1 <= result.u0 || result.v1 <= result.v0) {
    gpui_windows_text_mask_release_v1(&result);
    return GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT;
  }
  *output = result;
  return GPUI_WINDOWS_TEXT_OK;
}

}  // namespace

extern "C" int32_t gpui_windows_text_measure_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity) {
  return native_measure(abi, text, text_length, family, family_length,
                       font_size_px, output, output_capacity);
}

extern "C" int32_t gpui_windows_text_hit_test_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double x_px, double y_px, double *output, int32_t output_capacity) {
  return native_hit_test(abi, text, text_length, family, family_length,
                        font_size_px, x_px, y_px, output, output_capacity);
}

extern "C" int32_t gpui_windows_text_raster_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double pixels_per_dip,
    double font_size_px,
    double text_origin_x, double text_origin_y, double clip_x, double clip_y,
    double clip_width, double clip_height, int32_t pixel_budget,
    GpuiWindowsTextMask *output) {
  return native_raster(abi, text, text_length, family, family_length,
                       pixels_per_dip, font_size_px, text_origin_x,
                       text_origin_y, clip_x, clip_y, clip_width, clip_height,
                       pixel_budget, output);
}

extern "C" void gpui_windows_text_mask_release_v1(
    GpuiWindowsTextMask *mask) {
  if (!mask)
    return;
  std::free(mask->pixels);
  std::memset(mask, 0, sizeof(*mask));
}

extern "C" int32_t gpui_windows_text_admit_scene_run_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double pixels_per_dip,
    double font_size_px,
    double origin_x, double origin_y, double clip_x, double clip_y,
    double clip_width, double clip_height) {
  GpuiWindowsTextMask mask{};
  int32_t status = gpui_windows_text_raster_v2(
      abi, text, text_length, family, family_length, pixels_per_dip,
      font_size_px, origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &mask);
  gpui_windows_text_mask_release_v1(&mask);
  return status;
}

extern "C" int32_t gpui_windows_text_test_supported_v1(void) {
  return 1;
}

extern "C" int32_t gpui_windows_text_test_color_policy_v1(void) {
  const DWRITE_GLYPH_IMAGE_FORMATS samples[] = {
      DWRITE_GLYPH_IMAGE_FORMATS_COLR,
      DWRITE_GLYPH_IMAGE_FORMATS_SVG,
      DWRITE_GLYPH_IMAGE_FORMATS_PNG,
      DWRITE_GLYPH_IMAGE_FORMATS_JPEG,
      DWRITE_GLYPH_IMAGE_FORMATS_TIFF,
      DWRITE_GLYPH_IMAGE_FORMATS_PREMULTIPLIED_B8G8R8A8,
      DWRITE_GLYPH_IMAGE_FORMATS_COLR_PAINT_TREE,
  };
  for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i)
    if (!has_unsupported_color_format(samples[i]))
      return 0;
  return has_unsupported_color_format(DWRITE_GLYPH_IMAGE_FORMATS_NONE) ? 0 : 1;
}

extern "C" int32_t gpui_windows_text_test_raster_v1(double *output,
                                                       int32_t capacity) {
  if (!output || capacity < 8)
    return GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL;
  static const uint8_t text[] = {'j'};
  static const uint8_t family[] = {'S', 'e', 'g', 'o', 'e', ' ', 'U', 'I'};
  GpuiWindowsTextMask mask{};
  int32_t status = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 1.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 128.0, 64.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &mask);
  if (status != GPUI_WINDOWS_TEXT_OK)
    return status;
  size_t nonzero = 0;
  size_t partial = 0;
  size_t top_half = 0;
  size_t bottom_half = 0;
  int32_t first_ink_row = mask.height;
  int32_t last_ink_row = -1;
  for (int32_t y = 0; y < mask.height; ++y) {
    for (int32_t x = 0; x < mask.width; ++x) {
      uint8_t alpha = mask.pixels[static_cast<size_t>(y) * mask.width + x];
      if (alpha == 0)
        continue;
      ++nonzero;
      if (alpha != 255)
        ++partial;
      if (y < mask.height / 2)
        ++top_half;
      else
        ++bottom_half;
      first_ink_row = std::min(first_ink_row, y);
      last_ink_row = std::max(last_ink_row, y);
    }
  }
  double result[8] = {
      static_cast<double>(mask.width),
      static_cast<double>(mask.height),
      static_cast<double>(nonzero),
      static_cast<double>(partial),
      static_cast<double>(first_ink_row),
      static_cast<double>(last_ink_row),
      static_cast<double>(top_half),
      static_cast<double>(bottom_half),
  };
  gpui_windows_text_mask_release_v1(&mask);
  std::memcpy(output, result, sizeof(result));
  return GPUI_WINDOWS_TEXT_OK;
}

extern "C" int32_t gpui_windows_text_test_density_v2(double *output,
                                                      int32_t capacity) {
  if (!output || capacity < 32)
    return GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL;
  static const uint8_t text[] = {'j'};
  static const uint8_t family[] = {'S', 'e', 'g', 'o', 'e', ' ', 'U', 'I'};
  GpuiWindowsTextMask one{}, one_half{}, two{};
  const int32_t one_status = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 1.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &one);
  const int32_t one_half_status = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 1.5, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &one_half);
  const int32_t two_status = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 2.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &two);
  if (one_status != GPUI_WINDOWS_TEXT_OK ||
      one_half_status != GPUI_WINDOWS_TEXT_OK ||
      two_status != GPUI_WINDOWS_TEXT_OK) {
    gpui_windows_text_mask_release_v1(&one);
    gpui_windows_text_mask_release_v1(&one_half);
    gpui_windows_text_mask_release_v1(&two);
    return one_status != GPUI_WINDOWS_TEXT_OK
               ? one_status
               : one_half_status != GPUI_WINDOWS_TEXT_OK ? one_half_status
                                                         : two_status;
  }

  size_t one_nonzero = 0, one_partial = 0;
  size_t two_nonzero = 0, two_partial = 0;
  int32_t one_ink_left = one.width, one_ink_top = one.height;
  int32_t one_ink_right = -1, one_ink_bottom = -1;
  for (int32_t y = 0; y < one.height; ++y) {
    for (int32_t x = 0; x < one.width; ++x) {
      uint8_t alpha = one.pixels[(size_t)y * one.width + x];
      if (alpha) {
        ++one_nonzero;
        if (alpha != 255)
          ++one_partial;
        one_ink_left = std::min(one_ink_left, x);
        one_ink_top = std::min(one_ink_top, y);
        one_ink_right = std::max(one_ink_right, x);
        one_ink_bottom = std::max(one_ink_bottom, y);
      }
    }
  }
  int32_t two_ink_left = two.width, two_ink_top = two.height;
  int32_t two_ink_right = -1, two_ink_bottom = -1;
  size_t two_edge_coverage = 0;
  for (int32_t y = 0; y < two.height; ++y) {
    for (int32_t x = 0; x < two.width; ++x) {
      uint8_t alpha = two.pixels[(size_t)y * two.width + x];
      if (alpha) {
        ++two_nonzero;
        if (alpha != 255)
          ++two_partial;
        two_ink_left = std::min(two_ink_left, x);
        two_ink_top = std::min(two_ink_top, y);
        two_ink_right = std::max(two_ink_right, x);
        two_ink_bottom = std::max(two_ink_bottom, y);
        if (x == 0 || y == 0 || x == two.width - 1 || y == two.height - 1)
          ++two_edge_coverage;
      }
    }
  }

  // A 2x mask must contain coverage newly sampled at physical resolution,
  // rather than only a larger allocation containing the original 1x pixels.
  double tile_two_left = two.left * 2.0 - two.u0 * two.width;
  double tile_two_top = two.top * 2.0 - two.v0 * two.height;
  double tile_one_left = one.left - one.u0 * one.width;
  double tile_one_top = one.top - one.v0 * one.height;
  size_t differs_from_nearest_1x = 0;
  for (int32_t y = 0; y < two.height; ++y) {
    int32_t source_y = static_cast<int32_t>(std::floor(
        (tile_two_top + y + 0.5) / 2.0 - tile_one_top));
    if (source_y < 0 || source_y >= one.height)
      continue;
    for (int32_t x = 0; x < two.width; ++x) {
      int32_t source_x = static_cast<int32_t>(std::floor(
          (tile_two_left + x + 0.5) / 2.0 - tile_one_left));
      if (source_x < 0 || source_x >= one.width)
        continue;
      uint8_t one_alpha = one.pixels[(size_t)source_y * one.width + source_x];
      uint8_t two_alpha = two.pixels[(size_t)y * two.width + x];
      if (one_alpha != two_alpha)
        ++differs_from_nearest_1x;
    }
  }

  GpuiWindowsTextMask invalid{};
  const int32_t invalid_zero = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 0.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &invalid);
  const int32_t invalid_negative = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), -1.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &invalid);
  const int32_t invalid_nan = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family),
      std::numeric_limits<double>::quiet_NaN(), 18.0, 0.0, 0.0, 0.0, 0.0,
      64.0, 32.0, GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &invalid);
  const int32_t invalid_high = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 8.01, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0,
      GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS, &invalid);
  int32_t one_area = one.width * one.height;
  int32_t two_area = two.width * two.height;
  const int32_t one_density_budget = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 2.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0, one_area, &invalid);
  const int32_t exact_two_density_budget = native_raster(
      GPUI_WINDOWS_TEXT_RASTER_ABI, text, 1, family, sizeof(family), 2.0, 18.0,
      0.0, 0.0, 0.0, 0.0, 64.0, 32.0, two_area, &invalid);

  const double result[32] = {
      static_cast<double>(one.width),
      static_cast<double>(one.height),
      static_cast<double>(one_half.width),
      static_cast<double>(one_half.height),
      static_cast<double>(two.width),
      static_cast<double>(two.height),
      one.left, one.top, one.right, one.bottom,
      two.left, two.top, two.right, two.bottom,
      static_cast<double>(one_nonzero),
      static_cast<double>(one_partial),
      static_cast<double>(two_nonzero),
      static_cast<double>(two_partial),
      static_cast<double>(differs_from_nearest_1x),
      static_cast<double>(invalid_zero),
      static_cast<double>(invalid_negative),
      static_cast<double>(invalid_nan),
      static_cast<double>(invalid_high),
      static_cast<double>(one_area),
      static_cast<double>(one_density_budget),
      static_cast<double>(two_area),
      static_cast<double>(exact_two_density_budget),
      static_cast<double>(one_ink_right - one_ink_left + 1),
      static_cast<double>(one_ink_bottom - one_ink_top + 1),
      static_cast<double>(two_ink_right - two_ink_left + 1),
      static_cast<double>(two_ink_bottom - two_ink_top + 1),
      static_cast<double>(two_edge_coverage),
  };
  gpui_windows_text_mask_release_v1(&one);
  gpui_windows_text_mask_release_v1(&one_half);
  gpui_windows_text_mask_release_v1(&two);
  gpui_windows_text_mask_release_v1(&invalid);
  std::memcpy(output, result, sizeof(result));
  return GPUI_WINDOWS_TEXT_OK;
}

#else
extern "C" int32_t gpui_windows_text_test_supported_v1(void) { return 0; }
extern "C" int32_t gpui_windows_text_test_color_policy_v1(void) { return 0; }
extern "C" int32_t gpui_windows_text_test_raster_v1(double *, int32_t) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
extern "C" int32_t gpui_windows_text_test_density_v2(double *, int32_t) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
extern "C" int32_t gpui_windows_text_measure_v1(
    int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t, double,
    double *, int32_t) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
extern "C" int32_t gpui_windows_text_hit_test_v1(
    int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t, double,
    double, double, double *, int32_t) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
extern "C" int32_t gpui_windows_text_raster_v2(
    int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t, double,
    double, double, double, double, double, double, double, int32_t,
    GpuiWindowsTextMask *) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
extern "C" int32_t gpui_windows_text_admit_scene_run_v2(
    int32_t, const uint8_t *, int32_t, const uint8_t *, int32_t, double,
    double, double, double, double, double, double, double) {
  return GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM;
}
#endif
