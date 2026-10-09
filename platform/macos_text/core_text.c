#include "macos_text.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#ifdef __APPLE__
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <CoreText/CoreText.h>

#define GPUI_MACOS_TEXT_ABI 1
#define GPUI_MACOS_TEXT_MAX_BYTES 16384
#define GPUI_MACOS_TEXT_MAX_FAMILY_BYTES 256
#define GPUI_MACOS_TEXT_MAX_FONT_SIZE 512.0
#define GPUI_MACOS_TEXT_MAX_SCENE_SIZE 32.0
#define GPUI_MACOS_TEXT_MAX_MASK_WIDTH 16384
#define GPUI_MACOS_TEXT_MAX_MASK_HEIGHT 2048
#define GPUI_MACOS_TEXT_MAX_MASK_PIXELS (8 * 1024 * 1024)
#define GPUI_MACOS_TEXT_HEADER_DOUBLES 12
#define GPUI_MACOS_TEXT_CARET_DOUBLES 10

enum {
  GPUI_TEXT_OK = 0,
  GPUI_TEXT_BAD_ABI = 1,
  GPUI_TEXT_UNSUPPORTED_INPUT = 2,
  GPUI_TEXT_TOO_LARGE = 3,
  GPUI_TEXT_SMALL_BUFFER = 4,
  GPUI_TEXT_INVALID_RESULT = 6,
  GPUI_TEXT_COLOR_GLYPH = 8,
  GPUI_TEXT_UNSUPPORTED_PLATFORM = 9,
  GPUI_TEXT_RASTER_UNAVAILABLE = 10,
  GPUI_TEXT_BAD_FONT = 11,
  GPUI_TEXT_BAD_SIZE = 12,
  GPUI_TEXT_NATIVE_FAILURE = 13,
  GPUI_TEXT_UNSUPPORTED_BIDI = 14,
  GPUI_TEXT_UNSUPPORTED_MULTILINE = 15,
  GPUI_TEXT_UNSUPPORTED_GLYPH = 16,
  GPUI_TEXT_RESOURCE_LIMIT = 17,
};

typedef struct {
  int32_t byte_offset;
  int32_t utf16_offset;
  int cursor_position;
} TextBoundary;

typedef struct {
  CFStringRef string;
  CTFontRef font;
  CTLineRef line;
  TextBoundary *boundaries;
  int32_t boundary_count;
  int unknown_glyph_count;
} TextLayout;

static int utf8_scalar(const uint8_t *bytes, int32_t length, int32_t *at,
                       uint32_t *scalar_out) {
  if (*at >= length)
    return 0;
  const uint8_t lead = bytes[(*at)++];
  if (lead < 0x80) {
    *scalar_out = lead;
    return 1;
  }

  int continuation_count;
  uint32_t scalar;
  if (lead >= 0xC2 && lead <= 0xDF) {
    continuation_count = 1;
    scalar = lead & 0x1F;
  } else if (lead >= 0xE0 && lead <= 0xEF) {
    continuation_count = 2;
    scalar = lead & 0x0F;
  } else if (lead >= 0xF0 && lead <= 0xF4) {
    continuation_count = 3;
    scalar = lead & 0x07;
  } else {
    return -1;
  }
  if (length - *at < continuation_count)
    return -1;
  for (int index = 0; index < continuation_count; index++) {
    const uint8_t next = bytes[(*at)++];
    if ((next & 0xC0) != 0x80)
      return -1;
    if (index == 0 &&
        ((lead == 0xE0 && next < 0xA0) || (lead == 0xED && next >= 0xA0) ||
         (lead == 0xF0 && next < 0x90) || (lead == 0xF4 && next >= 0x90)))
      return -1;
    scalar = (scalar << 6) | (next & 0x3F);
  }
  if (scalar > 0x10FFFF || (scalar >= 0xD800 && scalar <= 0xDFFF))
    return -1;
  *scalar_out = scalar;
  return 1;
}

static int rejected_scalar(uint32_t scalar) {
  if (scalar == '\n' || scalar == '\r' || scalar == 0x2028 ||
      scalar == 0x2029)
    return GPUI_TEXT_UNSUPPORTED_MULTILINE;
  if ((scalar >= 0x202A && scalar <= 0x202E) ||
      (scalar >= 0x2066 && scalar <= 0x2069) || scalar == 0x061C ||
      scalar == 0x200E || scalar == 0x200F)
    return GPUI_TEXT_UNSUPPORTED_BIDI;
  if (scalar == 0 || scalar < 0x20 || (scalar >= 0x7F && scalar <= 0x9F))
    return GPUI_TEXT_UNSUPPORTED_INPUT;
  return GPUI_TEXT_OK;
}

static int make_boundaries(const uint8_t *bytes, int32_t length,
                           TextBoundary **boundaries_out,
                           int32_t *count_out) {
  if (length < 0 || length > GPUI_MACOS_TEXT_MAX_BYTES ||
      (length > 0 && !bytes))
    return GPUI_TEXT_TOO_LARGE;
  TextBoundary *boundaries =
      calloc((size_t)length + 1, sizeof(*boundaries));
  if (!boundaries)
    return GPUI_TEXT_RESOURCE_LIMIT;
  int32_t at = 0;
  int32_t count = 1;
  int32_t utf16_offset = 0;
  boundaries[0] = (TextBoundary){0, 0, 1};
  while (at < length) {
    uint32_t scalar = 0;
    if (utf8_scalar(bytes, length, &at, &scalar) < 0) {
      free(boundaries);
      return GPUI_TEXT_UNSUPPORTED_INPUT;
    }
    const int error = rejected_scalar(scalar);
    if (error) {
      free(boundaries);
      return error;
    }
    utf16_offset += scalar > 0xFFFF ? 2 : 1;
    boundaries[count++] = (TextBoundary){at, utf16_offset, 0};
  }
  boundaries[count - 1].cursor_position = 1;
  *boundaries_out = boundaries;
  *count_out = count;
  return GPUI_TEXT_OK;
}

static CFStringRef create_cf_string(const uint8_t *bytes, int32_t length) {
  const uint8_t *safe_bytes = length == 0 ? (const uint8_t *)"" : bytes;
  return CFStringCreateWithBytes(kCFAllocatorDefault, safe_bytes,
                                 (CFIndex)length, kCFStringEncodingUTF8,
                                 false);
}

static CTFontRef create_font(const uint8_t *family, int32_t family_length,
                             double font_size_px) {
  CFStringRef family_name = create_cf_string(family, family_length);
  if (!family_name)
    return NULL;
  CTFontRef font = NULL;
  if (family_length == 4 && memcmp(family, "sans", 4) == 0) {
    font = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem,
                                         (CGFloat)font_size_px, NULL);
  } else {
    font = CTFontCreateWithName(family_name, (CGFloat)font_size_px, NULL);
  }
  CFRelease(family_name);
  return font;
}

static int inspect_line_glyphs(CTLineRef line, int *unknown_glyph_count_out) {
  CFArrayRef runs = CTLineGetGlyphRuns(line);
  int unknown_glyph_count = 0;
  for (CFIndex run_index = 0; run_index < CFArrayGetCount(runs);
       run_index++) {
    CTRunRef run = (CTRunRef)CFArrayGetValueAtIndex(runs, run_index);
    if (CTRunGetStatus(run) & kCTRunStatusRightToLeft)
      return GPUI_TEXT_UNSUPPORTED_BIDI;
    CFDictionaryRef attributes = CTRunGetAttributes(run);
    CTFontRef font =
        (CTFontRef)CFDictionaryGetValue(attributes, kCTFontAttributeName);
    if (font && (CTFontGetSymbolicTraits(font) & kCTFontTraitColorGlyphs))
      return GPUI_TEXT_COLOR_GLYPH;
    const CFIndex glyph_count = CTRunGetGlyphCount(run);
    if (glyph_count > GPUI_MACOS_TEXT_MAX_BYTES)
      return GPUI_TEXT_RESOURCE_LIMIT;
    int last_resort = 0;
    if (font) {
      CFStringRef postscript_name = CTFontCopyPostScriptName(font);
      if (postscript_name &&
          CFStringCompare(postscript_name, CFSTR("LastResort"), 0) ==
              kCFCompareEqualTo)
        last_resort = 1;
      if (postscript_name)
        CFRelease(postscript_name);
    }
    CGGlyph *glyphs =
        glyph_count ? malloc((size_t)glyph_count * sizeof(*glyphs)) : NULL;
    if (glyph_count && !glyphs)
      return GPUI_TEXT_RESOURCE_LIMIT;
    if (glyph_count)
      CTRunGetGlyphs(run, CFRangeMake(0, 0), glyphs);
    for (CFIndex index = 0; index < glyph_count; index++) {
      if (last_resort || glyphs[index] == 0)
        unknown_glyph_count++;
    }
    free(glyphs);
  }
  *unknown_glyph_count_out = unknown_glyph_count;
  return GPUI_TEXT_OK;
}

static void release_layout(TextLayout *layout) {
  if (layout->line)
    CFRelease(layout->line);
  if (layout->font)
    CFRelease(layout->font);
  if (layout->string)
    CFRelease(layout->string);
  free(layout->boundaries);
  memset(layout, 0, sizeof(*layout));
}

static int create_layout(const uint8_t *text, int32_t text_length,
                         const uint8_t *font_family,
                         int32_t font_family_length, double font_size_px,
                         TextLayout *layout_out) {
  memset(layout_out, 0, sizeof(*layout_out));
  if (!isfinite(font_size_px) || font_size_px <= 0.0 ||
      font_size_px > GPUI_MACOS_TEXT_MAX_FONT_SIZE)
    return GPUI_TEXT_BAD_SIZE;
  if (!font_family || font_family_length <= 0 ||
      font_family_length > GPUI_MACOS_TEXT_MAX_FAMILY_BYTES)
    return GPUI_TEXT_BAD_FONT;

  int32_t boundary_count = 0;
  int status = make_boundaries(text, text_length, &layout_out->boundaries,
                               &boundary_count);
  if (status)
    return status;
  layout_out->boundary_count = boundary_count;
  layout_out->string = create_cf_string(text, text_length);
  layout_out->font = create_font(font_family, font_family_length, font_size_px);
  if (!layout_out->string || !layout_out->font) {
    release_layout(layout_out);
    return GPUI_TEXT_BAD_FONT;
  }

  const void *keys[] = {kCTFontAttributeName,
                        kCTForegroundColorFromContextAttributeName};
  const void *values[] = {layout_out->font, kCFBooleanTrue};
  CFDictionaryRef attributes =
      CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                         &kCFTypeDictionaryKeyCallBacks,
                         &kCFTypeDictionaryValueCallBacks);
  CFAttributedStringRef attributed =
      attributes ? CFAttributedStringCreate(kCFAllocatorDefault,
                                            layout_out->string, attributes)
                 : NULL;
  if (attributes)
    CFRelease(attributes);
  layout_out->line = attributed ? CTLineCreateWithAttributedString(attributed)
                                : NULL;
  if (attributed)
    CFRelease(attributed);
  if (!layout_out->line) {
    release_layout(layout_out);
    return GPUI_TEXT_NATIVE_FAILURE;
  }
  status = inspect_line_glyphs(layout_out->line,
                               &layout_out->unknown_glyph_count);
  if (status) {
    release_layout(layout_out);
    return status;
  }

  for (int32_t index = 1; index < boundary_count - 1; index++) {
    const CFRange grapheme = CFStringGetRangeOfComposedCharactersAtIndex(
        layout_out->string,
        (CFIndex)layout_out->boundaries[index].utf16_offset);
    layout_out->boundaries[index].cursor_position =
        grapheme.location ==
        (CFIndex)layout_out->boundaries[index].utf16_offset;
  }
  return GPUI_TEXT_OK;
}

static void layout_metrics(TextLayout *layout, double *width_out,
                           double *ascent_out, double *descent_out,
                           double *leading_out, CGRect *ink_rect_out) {
  *width_out = CTLineGetTypographicBounds(
      layout->line, ascent_out, descent_out, leading_out);
  *ink_rect_out = CTLineGetImageBounds(layout->line, NULL);
  if (*ascent_out + *descent_out + *leading_out <= 0.0) {
    *ascent_out = CTFontGetAscent(layout->font);
    *descent_out = CTFontGetDescent(layout->font);
    *leading_out = CTFontGetLeading(layout->font);
  }
  if (*ascent_out + *descent_out + *leading_out <= 0.0)
    *ascent_out = 1.0;
  if (CGRectIsNull(*ink_rect_out))
    *ink_rect_out = CGRectMake(0, 0, 0, 0);
}

int32_t gpui_macos_text_require_raster_v1(int32_t abi) {
  if (abi != GPUI_MACOS_TEXT_ABI)
    return GPUI_TEXT_BAD_ABI;
  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceGray();
  if (!color_space)
    return GPUI_TEXT_RASTER_UNAVAILABLE;
  uint8_t pixel = 0;
  CGContextRef context =
      CGBitmapContextCreate(&pixel, 1, 1, 8, 1, color_space, kCGImageAlphaNone);
  CGColorSpaceRelease(color_space);
  if (!context)
    return GPUI_TEXT_RASTER_UNAVAILABLE;
  CGContextRelease(context);
  CTFontRef font =
      CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, 12.0, NULL);
  if (!font)
    return GPUI_TEXT_RASTER_UNAVAILABLE;
  CFRelease(font);
  return GPUI_TEXT_OK;
}

int32_t gpui_macos_text_measure_v1(int32_t abi, const uint8_t *text,
                                   int32_t text_length,
                                   const uint8_t *font_family,
                                   int32_t font_family_length,
                                   double font_size_px, double *output,
                                   int32_t output_capacity) {
  if (abi != GPUI_MACOS_TEXT_ABI)
    return GPUI_TEXT_BAD_ABI;
  if (!output || output_capacity < GPUI_MACOS_TEXT_HEADER_DOUBLES)
    return GPUI_TEXT_INVALID_RESULT;
  TextLayout layout = {0};
  const int status = create_layout(text, text_length, font_family,
                                   font_family_length, font_size_px, &layout);
  if (status)
    return status;
  const int64_t required_capacity =
      (int64_t)GPUI_MACOS_TEXT_HEADER_DOUBLES +
      (int64_t)GPUI_MACOS_TEXT_CARET_DOUBLES * layout.boundary_count;
  if (required_capacity > output_capacity) {
    release_layout(&layout);
    return GPUI_TEXT_SMALL_BUFFER;
  }

  double width = 0.0;
  double ascent = 0.0;
  double descent = 0.0;
  double leading = 0.0;
  CGRect ink_rect = CGRectZero;
  layout_metrics(&layout, &width, &ascent, &descent, &leading, &ink_rect);
  const double height = ascent + descent + leading;
  if (!isfinite(width) || !isfinite(height) || width < 0.0 || height < 0.0 ||
      height > 1000000.0) {
    release_layout(&layout);
    return GPUI_TEXT_INVALID_RESULT;
  }
  output[0] = 0.0;
  output[1] = 0.0;
  output[2] = width;
  output[3] = height;
  output[4] = CGRectGetMinX(ink_rect);
  output[5] = ascent - CGRectGetMaxY(ink_rect);
  output[6] = CGRectGetWidth(ink_rect);
  output[7] = CGRectGetHeight(ink_rect);
  output[8] = ascent;
  output[9] = 1.0;
  output[10] = layout.unknown_glyph_count;
  output[11] = layout.boundary_count;
  for (int32_t index = 0; index < layout.boundary_count; index++) {
    double secondary_offset = 0.0;
    const double x = CTLineGetOffsetForStringIndex(
        layout.line, (CFIndex)layout.boundaries[index].utf16_offset,
        &secondary_offset);
    if (!isfinite(x) || !isfinite(secondary_offset) ||
        fabs(x - secondary_offset) > 1.0 / 1024.0) {
      release_layout(&layout);
      return GPUI_TEXT_UNSUPPORTED_BIDI;
    }
    const int32_t at = GPUI_MACOS_TEXT_HEADER_DOUBLES +
                       index * GPUI_MACOS_TEXT_CARET_DOUBLES;
    output[at] = (double)layout.boundaries[index].byte_offset;
    output[at + 1] = layout.boundaries[index].cursor_position ? 1.0 : 0.0;
    output[at + 2] = x;
    output[at + 3] = 0.0;
    output[at + 4] = 0.0;
    output[at + 5] = height;
    output[at + 6] = x;
    output[at + 7] = 0.0;
    output[at + 8] = 0.0;
    output[at + 9] = height;
  }
  release_layout(&layout);
  return GPUI_TEXT_OK;
}

int32_t gpui_macos_text_raster_v1(const uint8_t *text, int32_t text_length,
                                  double font_size_px, double scale,
                                  GpuiMacosTextMask *output) {
  if (!output)
    return GPUI_TEXT_INVALID_RESULT;
  memset(output, 0, sizeof(*output));
  if (!isfinite(scale) || scale <= 0.0 || scale > 8.0)
    return GPUI_TEXT_INVALID_RESULT;
  const uint8_t system_sans[] = "sans";
  TextLayout layout = {0};
  int status = create_layout(text, text_length, system_sans, 4,
                             font_size_px, &layout);
  if (status)
    return status;
  if (font_size_px > GPUI_MACOS_TEXT_MAX_SCENE_SIZE) {
    release_layout(&layout);
    return GPUI_TEXT_RESOURCE_LIMIT;
  }
  if (layout.unknown_glyph_count) {
    release_layout(&layout);
    return GPUI_TEXT_UNSUPPORTED_GLYPH;
  }
  double width = 0.0;
  double ascent = 0.0;
  double descent = 0.0;
  double leading = 0.0;
  CGRect ink_rect = CGRectZero;
  layout_metrics(&layout, &width, &ascent, &descent, &leading, &ink_rect);
  if (CGRectIsEmpty(ink_rect)) {
    release_layout(&layout);
    return GPUI_TEXT_OK;
  }

  const double left = floor(CGRectGetMinX(ink_rect) * scale) / scale;
  const double top =
      floor((ascent - CGRectGetMaxY(ink_rect)) * scale) / scale;
  const double right = ceil(CGRectGetMaxX(ink_rect) * scale) / scale;
  const double bottom =
      ceil((ascent - CGRectGetMinY(ink_rect)) * scale) / scale;
  const int32_t pixel_width = (int32_t)ceil((right - left) * scale);
  const int32_t pixel_height = (int32_t)ceil((bottom - top) * scale);
  if (pixel_width <= 0 || pixel_height <= 0 ||
      pixel_width > GPUI_MACOS_TEXT_MAX_MASK_WIDTH ||
      pixel_height > GPUI_MACOS_TEXT_MAX_MASK_HEIGHT ||
      (int64_t)pixel_width * pixel_height >
          GPUI_MACOS_TEXT_MAX_MASK_PIXELS) {
    release_layout(&layout);
    return GPUI_TEXT_RESOURCE_LIMIT;
  }
  uint8_t *pixels = calloc((size_t)pixel_width, (size_t)pixel_height);
  CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
  CGContextRef context =
      gray ? CGBitmapContextCreate(pixels, pixel_width, pixel_height, 8,
                                   pixel_width, gray, kCGImageAlphaNone)
           : NULL;
  if (gray)
    CGColorSpaceRelease(gray);
  if (!pixels || !context) {
    free(pixels);
    if (context)
      CGContextRelease(context);
    release_layout(&layout);
    return GPUI_TEXT_RASTER_UNAVAILABLE;
  }
  CGContextSetAllowsAntialiasing(context, true);
  CGContextSetShouldAntialias(context, true);
  CGContextSetGrayFillColor(context, 1.0, 1.0);
  CGContextTranslateCTM(context, 0.0, pixel_height);
  CGContextScaleCTM(context, scale, -scale);
  CGContextTranslateCTM(context, -left, -top);
  CGContextSetTextMatrix(context, CGAffineTransformMakeScale(1.0, -1.0));
  CGContextSetTextPosition(context, 0.0, ascent);
  CTLineDraw(layout.line, context);
  CGContextRelease(context);
  output->pixels = pixels;
  output->width = pixel_width;
  output->height = pixel_height;
  output->stride = pixel_width;
  output->left = left;
  output->top = top;
  release_layout(&layout);
  return GPUI_TEXT_OK;
}

void gpui_macos_text_raster_free(GpuiMacosTextMask *mask) {
  if (!mask)
    return;
  free(mask->pixels);
  memset(mask, 0, sizeof(*mask));
}

#else

enum { GPUI_TEXT_UNSUPPORTED_PLATFORM = 9 };

int32_t gpui_macos_text_require_raster_v1(int32_t abi) {
  (void)abi;
  return GPUI_TEXT_UNSUPPORTED_PLATFORM;
}

int32_t gpui_macos_text_measure_v1(int32_t abi, const uint8_t *text,
                                   int32_t text_length,
                                   const uint8_t *font_family,
                                   int32_t font_family_length,
                                   double font_size_px, double *output,
                                   int32_t output_capacity) {
  (void)abi;
  (void)text;
  (void)text_length;
  (void)font_family;
  (void)font_family_length;
  (void)font_size_px;
  (void)output;
  (void)output_capacity;
  return GPUI_TEXT_UNSUPPORTED_PLATFORM;
}

int32_t gpui_macos_text_raster_v1(const uint8_t *text, int32_t text_length,
                                  double font_size_px, double scale,
                                  GpuiMacosTextMask *output) {
  (void)text;
  (void)text_length;
  (void)font_size_px;
  (void)scale;
  if (output)
    memset(output, 0, sizeof(*output));
  return GPUI_TEXT_UNSUPPORTED_PLATFORM;
}

void gpui_macos_text_raster_free(GpuiMacosTextMask *mask) {
  (void)mask;
}

#endif
