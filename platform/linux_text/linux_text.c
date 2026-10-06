#define _POSIX_C_SOURCE 200809L
#include "linux_text.h"

#include <fontconfig/fontconfig.h>
#include <glib.h>
#include <math.h>
#include <pango/pangoft2.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  PangoFontMap *font_map;
  PangoContext *context;
  PangoLayout *layout;
} gpui_layout;

typedef struct {
  int32_t map;
  int32_t context;
  int32_t layout;
  int32_t references;
  GMutex mutex;
  GCond finalized;
} gpui_lifecycle_counts;

typedef struct {
  int32_t map;
  int32_t context;
  int32_t layout;
} gpui_lifecycle_totals;

static void lifecycle_retain(gpui_lifecycle_counts *counts) {
  g_mutex_lock(&counts->mutex);
  if (counts->references < INT32_MAX)
    ++counts->references;
  g_mutex_unlock(&counts->mutex);
}

static void lifecycle_release(gpui_lifecycle_counts *counts) {
  if (!counts)
    return;
  gboolean destroy = FALSE;
  g_mutex_lock(&counts->mutex);
  if (counts->references > 0)
    --counts->references;
  if (counts->references == 0)
    destroy = TRUE;
  g_mutex_unlock(&counts->mutex);
  if (destroy) {
    g_cond_clear(&counts->finalized);
    g_mutex_clear(&counts->mutex);
    g_free(counts);
  }
}

static void lifecycle_note_finalized(gpui_lifecycle_counts *counts,
                                     int32_t *counter) {
  g_mutex_lock(&counts->mutex);
  if (*counter < INT32_MAX)
    ++*counter;
  g_cond_broadcast(&counts->finalized);
  g_mutex_unlock(&counts->mutex);
  lifecycle_release(counts);
}

static void count_map_finalize(gpointer data, GObject *object) {
  (void)object;
  lifecycle_note_finalized(data, &((gpui_lifecycle_counts *)data)->map);
}

static void count_context_finalize(gpointer data, GObject *object) {
  (void)object;
  lifecycle_note_finalized(data, &((gpui_lifecycle_counts *)data)->context);
}

static void count_layout_finalize(gpointer data, GObject *object) {
  (void)object;
  lifecycle_note_finalized(data, &((gpui_lifecycle_counts *)data)->layout);
}

static gboolean lifecycle_wait_for_finalization(
    gpui_lifecycle_counts *counts, gint64 deadline, int32_t *map,
    int32_t *context, int32_t *layout) {
  g_mutex_lock(&counts->mutex);
  while (counts->map != 1 || counts->context != 1 || counts->layout != 1) {
    if (!g_cond_wait_until(&counts->finalized, &counts->mutex, deadline))
      break;
  }
  *map = counts->map;
  *context = counts->context;
  *layout = counts->layout;
  gboolean complete = counts->map == 1 && counts->context == 1 &&
                      counts->layout == 1;
  g_mutex_unlock(&counts->mutex);
  return complete;
}

static void lifecycle_snapshot(gpui_lifecycle_counts *counts, int32_t *map,
                               int32_t *context, int32_t *layout) {
  g_mutex_lock(&counts->mutex);
  *map = counts->map;
  *context = counts->context;
  *layout = counts->layout;
  g_mutex_unlock(&counts->mutex);
}

static void observe_lifecycle(gpui_layout *objects,
                              gpui_lifecycle_counts *counts) {
  if (!objects || !counts)
    return;
  if (objects->font_map) {
    lifecycle_retain(counts);
    g_object_weak_ref(G_OBJECT(objects->font_map), count_map_finalize, counts);
  }
  if (objects->context) {
    lifecycle_retain(counts);
    g_object_weak_ref(G_OBJECT(objects->context), count_context_finalize,
                      counts);
  }
  if (objects->layout) {
    lifecycle_retain(counts);
    g_object_weak_ref(G_OBJECT(objects->layout), count_layout_finalize,
                      counts);
  }
}

static void free_layout(gpui_layout *objects) {
  if (objects->layout)
    g_object_unref(objects->layout);
  if (objects->context)
    g_object_unref(objects->context);
  if (objects->font_map)
    g_object_unref(objects->font_map);
  objects->layout = NULL;
  objects->context = NULL;
  objects->font_map = NULL;
}

static int32_t validate_input(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    int32_t *scalar_count_out) {
  if (abi != GPUI_LINUX_TEXT_ABI || text_length < 0 || family_length < 0 ||
      (text_length > 0 && text == NULL) || family == NULL ||
      scalar_count_out == NULL || !isfinite(font_size_px) ||
      font_size_px <= 0.0 || font_size_px > GPUI_LINUX_TEXT_MAX_FONT_SIZE_PX)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (text_length > GPUI_LINUX_TEXT_MAX_TEXT_BYTES ||
      family_length > GPUI_LINUX_TEXT_MAX_FAMILY_BYTES)
    return GPUI_LINUX_TEXT_INPUT_TOO_LARGE;
  if (family_length == 0 || memchr(family, 0, (size_t)family_length) != NULL ||
      (text_length > 0 && memchr(text, 0, (size_t)text_length) != NULL))
    return GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
  if (!g_utf8_validate((const gchar *)family, family_length, NULL) ||
      (text_length > 0 &&
       !g_utf8_validate((const gchar *)text, text_length, NULL)))
    return GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
  gboolean family_has_non_space = FALSE;
  const gchar *family_cursor = (const gchar *)family;
  const gchar *family_end = family_cursor + family_length;
  while (family_cursor < family_end) {
    gunichar scalar = g_utf8_get_char(family_cursor);
    if (!g_unichar_isspace(scalar))
      family_has_non_space = TRUE;
    family_cursor = g_utf8_next_char(family_cursor);
  }
  if (!family_has_non_space)
    return GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;

  int32_t scalars = 0;
  if (text_length > 0) {
    const gchar *cursor = (const gchar *)text;
    const gchar *end = cursor + text_length;
    while (cursor < end) {
      const gchar *next = g_utf8_next_char(cursor);
      if (next <= cursor || next > end || scalars == INT32_MAX)
        return GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
      ++scalars;
      cursor = next;
    }
  }
  *scalar_count_out = scalars;
  return GPUI_LINUX_TEXT_OK;
}

static int32_t create_layout(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    gpui_layout *objects, int32_t *scalar_count_out) {
  memset(objects, 0, sizeof(*objects));
  int32_t status = validate_input(abi, text, text_length, family,
                                  family_length, font_size_px,
                                  scalar_count_out);
  if (status != GPUI_LINUX_TEXT_OK)
    return status;
  /* Empty Bytes may use a null pointer. Pango still requires nonnull text. */
  const uint8_t *safe_text = text_length == 0 ? (const uint8_t *)"" : text;

  char *family_c = g_try_malloc((gsize)family_length + 1);
  if (!family_c)
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  memcpy(family_c, family, (size_t)family_length);
  family_c[family_length] = '\0';

  objects->font_map = pango_ft2_font_map_new();
  if (!objects->font_map) {
    g_free(family_c);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }
  pango_ft2_font_map_set_resolution(PANGO_FT2_FONT_MAP(objects->font_map),
                                    96.0, 96.0);
  objects->context = pango_font_map_create_context(objects->font_map);
  if (!objects->context) {
    g_free(family_c);
    free_layout(objects);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }

  /* A stable neutral language affects shaping/line breaking; direction remains
   * content-driven via Pango's automatic layout direction. The layout retains
   * the default no-wrap width and ordinary multiline handling. */
  pango_context_set_language(objects->context,
                             pango_language_from_string("en"));
  pango_context_set_base_dir(objects->context, PANGO_DIRECTION_LTR);
  objects->layout = pango_layout_new(objects->context);
  if (!objects->layout) {
    g_free(family_c);
    free_layout(objects);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }
  PangoFontDescription *description = pango_font_description_new();
  if (!description) {
    g_free(family_c);
    free_layout(objects);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }
  pango_font_description_set_family(description, family_c);
  /* Pango sizes use 1024 units per logical pixel. Absolute sizes avoid pt/DPI
   * conversion; range checks above bound this multiplication to 524288 units. */
  pango_font_description_set_absolute_size(description,
                                           font_size_px * PANGO_SCALE);
  pango_layout_set_font_description(objects->layout, description);
  pango_font_description_free(description);
  g_free(family_c);
  pango_layout_set_auto_dir(objects->layout, TRUE);
  pango_layout_set_text(objects->layout, (const gchar *)safe_text, text_length);
  return GPUI_LINUX_TEXT_OK;
}

static double pango_px(int value) {
  return (double)value / (double)PANGO_SCALE;
}

static gboolean valid_output_capacity(int32_t caret_count, int32_t capacity,
                                      int32_t *required_out) {
  if (caret_count < 1 || capacity < 0 || required_out == NULL)
    return FALSE;
  if (caret_count >
      (INT32_MAX - GPUI_LINUX_TEXT_HEADER_DOUBLES) /
          GPUI_LINUX_TEXT_CARET_DOUBLES)
    return FALSE;
  *required_out = GPUI_LINUX_TEXT_HEADER_DOUBLES +
                  caret_count * GPUI_LINUX_TEXT_CARET_DOUBLES;
  return TRUE;
}

static void write_rect(double *out, const PangoRectangle *rect) {
  out[0] = pango_px(rect->x);
  out[1] = pango_px(rect->y);
  out[2] = pango_px(rect->width);
  out[3] = pango_px(rect->height);
}

static gboolean get_layout_info(PangoLayout *layout, int32_t scalar_count,
                                PangoRectangle *ink,
                                PangoRectangle *logical,
                                const PangoLogAttr **attrs_out,
                                int *attrs_count_out,
                                int32_t *line_count_out,
                                int32_t *unknown_out) {
  if (!layout || !ink || !logical || !attrs_out || !attrs_count_out ||
      !line_count_out || !unknown_out)
    return FALSE;
  pango_layout_get_extents(layout, ink, logical);
  int attrs_count = 0;
  const PangoLogAttr *attrs =
      pango_layout_get_log_attrs_readonly(layout, &attrs_count);
  int line_count = pango_layout_get_line_count(layout);
  int unknown = pango_layout_get_unknown_glyphs_count(layout);
  if (!attrs || attrs_count != scalar_count + 1 || line_count < 1 ||
      unknown < 0 || logical->width < 0 || logical->height < 0 ||
      ink->width < 0 || ink->height < 0)
    return FALSE;
  *attrs_out = attrs;
  *attrs_count_out = attrs_count;
  *line_count_out = line_count;
  *unknown_out = unknown;
  return TRUE;
}

static int32_t measure_layout_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity,
    gpui_lifecycle_counts *lifecycle) {
  int32_t scalar_count = 0;
  int32_t status = validate_input(abi, text, text_length, family,
                                  family_length, font_size_px,
                                  &scalar_count);
  if (status != GPUI_LINUX_TEXT_OK)
    return status;
  int32_t caret_count = scalar_count + 1;
  int32_t required = 0;
  if (!valid_output_capacity(caret_count, output_capacity, &required))
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (output_capacity < required)
    return GPUI_LINUX_TEXT_CAPACITY_TOO_SMALL;
  if (!output)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;

  gpui_layout objects = {0};
  status = create_layout(abi, text, text_length, family, family_length,
                         font_size_px, &objects, &scalar_count);
  if (status != GPUI_LINUX_TEXT_OK) {
    free_layout(&objects);
    return status;
  }
  observe_lifecycle(&objects, lifecycle);
  PangoRectangle ink, logical;
  const PangoLogAttr *attrs = NULL;
  int attrs_count = 0;
  int32_t line_count = 0, unknown = 0;
  if (!get_layout_info(objects.layout, scalar_count, &ink, &logical, &attrs,
                       &attrs_count, &line_count, &unknown)) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
  }

  /* All input, capacity, and layout invariants are checked before the first
   * write, so errors never expose a partial result. */
  write_rect(output, &logical);
  write_rect(output + 4, &ink);
  output[8] = pango_px(pango_layout_get_baseline(objects.layout));
  output[9] = (double)line_count;
  output[10] = (double)unknown;
  output[11] = (double)caret_count;
  const gchar *safe_text = text_length == 0 ? "" : (const gchar *)text;
  const gchar *cursor = safe_text;
  int32_t byte_offset = 0;
  for (int32_t scalar_index = 0; scalar_index < caret_count;
       ++scalar_index) {
    PangoRectangle strong, weak;
    pango_layout_get_cursor_pos(objects.layout, byte_offset, &strong, &weak);
    double *record = output + GPUI_LINUX_TEXT_HEADER_DOUBLES +
                     scalar_index * GPUI_LINUX_TEXT_CARET_DOUBLES;
    record[0] = (double)byte_offset;
    record[1] = attrs[scalar_index].is_cursor_position ? 1.0 : 0.0;
    write_rect(record + 2, &strong);
    write_rect(record + 6, &weak);
    if (scalar_index < scalar_count) {
      cursor = g_utf8_next_char(cursor);
      byte_offset = (int32_t)(cursor - safe_text);
    }
  }
  free_layout(&objects);
  return GPUI_LINUX_TEXT_OK;
}

int32_t gpui_linux_text_measure_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity) {
  return measure_layout_v1(abi, text, text_length, family, family_length,
                           font_size_px, output, output_capacity, NULL);
}

static int32_t px_to_pango_units(double px, int32_t *out) {
  if (!isfinite(px) || !out)
    return 0;
  const double min_px = ((double)INT32_MIN - 0.5) / (double)PANGO_SCALE;
  const double max_px = ((double)INT32_MAX + 0.5) / (double)PANGO_SCALE;
  if (px < min_px || px > max_px)
    return 0;
  double scaled = px * (double)PANGO_SCALE;
  /* llround is the documented deterministic conversion: nearest unit, ties
   * away from zero. Check the integer range before rounding/casting. */
  if (!isfinite(scaled) || scaled < (double)INT32_MIN - 0.5 ||
      scaled > (double)INT32_MAX + 0.5)
    return 0;
  long long rounded = llround(scaled);
  if (rounded < INT32_MIN || rounded > INT32_MAX)
    return 0;
  *out = (int32_t)rounded;
  return 1;
}

static int32_t byte_boundary_index(const uint8_t *text, int32_t text_length,
                                  int32_t target) {
  if (target < 0 || target > text_length)
    return -1;
  const gchar *cursor = (const gchar *)text;
  int32_t byte_offset = 0;
  int32_t scalar_index = 0;
  for (;;) {
    if (byte_offset == target)
      return scalar_index;
    if (byte_offset >= text_length)
      return -1;
    cursor = g_utf8_next_char(cursor);
    byte_offset = (int32_t)(cursor - (const gchar *)text);
    ++scalar_index;
  }
}

int32_t gpui_linux_text_hit_test_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double x_px, double y_px, double *output, int32_t output_capacity) {
  if (output_capacity < 5)
    return GPUI_LINUX_TEXT_CAPACITY_TOO_SMALL;
  if (!output)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  int32_t x_units = 0, y_units = 0;
  if (!px_to_pango_units(x_px, &x_units) ||
      !px_to_pango_units(y_px, &y_units))
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;

  int32_t scalar_count = 0;
  gpui_layout objects = {0};
  int32_t status = create_layout(abi, text, text_length, family, family_length,
                                 font_size_px, &objects, &scalar_count);
  if (status != GPUI_LINUX_TEXT_OK) {
    free_layout(&objects);
    return status;
  }
  const PangoLogAttr *attrs = NULL;
  int attrs_count = 0;
  PangoRectangle ink, logical;
  int32_t line_count = 0, unknown = 0;
  if (!get_layout_info(objects.layout, scalar_count, &ink, &logical, &attrs,
                       &attrs_count, &line_count, &unknown)) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
  }
  int byte_index = -1;
  int trailing = -1;
  gboolean inside = pango_layout_xy_to_index(objects.layout, x_units, y_units,
                                             &byte_index, &trailing);
  const uint8_t *safe_text = text_length == 0 ? (const uint8_t *)"" : text;
  int32_t start_scalar = byte_boundary_index(safe_text, text_length, byte_index);
  if (start_scalar < 0 || trailing < 0 || trailing > scalar_count - start_scalar ||
      start_scalar + trailing >= attrs_count) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
  }
  int32_t resolved_byte = byte_index;
  const gchar *cursor = (const gchar *)safe_text + byte_index;
  for (int i = 0; i < trailing; ++i) {
    cursor = g_utf8_next_char(cursor);
    resolved_byte = (int32_t)(cursor - (const gchar *)safe_text);
  }
  int32_t resolved_scalar = start_scalar + trailing;
  /* The converted boundary must agree with the same scalar count used for the
   * log-attribute index before anything is exposed to MoonBit. */
  if (resolved_byte < byte_index || resolved_byte > text_length ||
      resolved_scalar >= attrs_count) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
  }
  output[0] = (double)byte_index;
  output[1] = (double)trailing;
  output[2] = (double)resolved_byte;
  output[3] = inside ? 1.0 : 0.0;
  output[4] = attrs[resolved_scalar].is_cursor_position ? 1.0 : 0.0;
  free_layout(&objects);
  return GPUI_LINUX_TEXT_OK;
}


static int32_t raster_admission(int32_t abi, int32_t runtime_version) {
  if (abi != GPUI_LINUX_TEXT_ABI || runtime_version < 0)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (runtime_version < PANGO_VERSION_ENCODE(1, 50, 0))
    return GPUI_LINUX_TEXT_UNSUPPORTED_RASTER;
  return GPUI_LINUX_TEXT_OK;
}

int32_t gpui_linux_text_require_raster_v1(int32_t abi) {
  return raster_admission(abi, pango_version());
}

int32_t gpui_linux_text_test_raster_admission_v1(int32_t abi,
                                                int32_t runtime_version) {
  return raster_admission(abi, runtime_version);
}

void gpui_linux_text_mask_release_v1(struct gpui_linux_text_mask *mask) {
  if (!mask)
    return;
  g_free(mask->pixels);
  memset(mask, 0, sizeof(*mask));
}

enum raster_tile_mode { RASTER_LEGACY_TILE, RASTER_FILTER_HALO };

static int32_t raster_layout_core(
    const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double text_origin_x, double text_origin_y,
    double clip_x, double clip_y, double bounds_width, double bounds_height,
    int32_t pixel_budget, enum raster_tile_mode tile_mode,
    struct gpui_linux_text_mask_v2 *output, gpui_lifecycle_counts *counts) {
  if (!output || pixel_budget < 0 || !isfinite(bounds_width) || !isfinite(bounds_height) ||
      bounds_width < 0 || bounds_height < 0 || bounds_width > 1e20 ||
      bounds_height > 1e20)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (!isfinite(text_origin_x) || !isfinite(text_origin_y) ||
      !isfinite(clip_x) || !isfinite(clip_y) ||
      fabs(text_origin_x) > 1e20 || fabs(text_origin_y) > 1e20 ||
      fabs(clip_x) > 1e20 || fabs(clip_y) > 1e20)
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  double clip_right = clip_x + bounds_width;
  double clip_bottom = clip_y + bounds_height;
  double layout_left = clip_x - text_origin_x;
  double layout_top = clip_y - text_origin_y;
  double layout_right = clip_right - text_origin_x;
  double layout_bottom = clip_bottom - text_origin_y;
  /* Inputs are <=1e20; addition/subtraction is bounded by3e20. Reject
   * unrepresentable input rectangles before shaping. Far translated empty
   * clips with representable extents exit before any tile/int conversion,
   * after text/color preflight. Precision-lost translated extents reject. */
  if (!isfinite(clip_right) || !isfinite(clip_bottom) ||
      (bounds_width > 0 && clip_right <= clip_x) ||
      (bounds_height > 0 && clip_bottom <= clip_y) ||
      !isfinite(layout_left) || !isfinite(layout_top) ||
      !isfinite(layout_right) || !isfinite(layout_bottom) ||
      (bounds_width > 0 && layout_right <= layout_left) ||
      (bounds_height > 0 && layout_bottom <= layout_top) ||
      fabs(layout_left) > 3e20 || fabs(layout_top) > 3e20 ||
      fabs(layout_right) > 3e20 || fabs(layout_bottom) > 3e20)
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  if (tile_mode == RASTER_FILTER_HALO) {
    /* Positive extents alone do not admit catastrophic cancellation: even a
     * representable huge origin can distort a small clip/ink rectangle by
     * whole pixels. Permit only a fixed sub-Pango-quantum logical error. */
    const double tolerance = GPUI_LINUX_TEXT_COORDINATE_TOLERANCE;
    if (fabs((clip_right - clip_x) - bounds_width) > tolerance ||
        fabs((clip_bottom - clip_y) - bounds_height) > tolerance ||
        fabs((layout_right - layout_left) - bounds_width) > tolerance ||
        fabs((layout_bottom - layout_top) - bounds_height) > tolerance ||
        fabs((layout_left + text_origin_x) - clip_x) > tolerance ||
        fabs((layout_top + text_origin_y) - clip_y) > tolerance ||
        fabs((layout_right + text_origin_x) - clip_right) > tolerance ||
        fabs((layout_bottom + text_origin_y) - clip_bottom) > tolerance)
      return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  }
  int32_t admission = gpui_linux_text_require_raster_v1(GPUI_LINUX_TEXT_ABI);
  if (admission != GPUI_LINUX_TEXT_OK)
    return admission;
  gpui_layout objects;
  int32_t scalars = 0;
  int32_t status = create_layout(GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
                                font_size_px, &objects, &scalars);
  if (status != GPUI_LINUX_TEXT_OK)
    return status;
  observe_lifecycle(&objects, counts);
  /* Bound unusually large combined requests before Pango materializes integer
   * layout geometry. This is a resource rejection, never text truncation. */
  if ((double)(scalars + 1) * font_size_px > 1048576.0) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;
  }
  PangoLayoutIter *iter = pango_layout_get_iter(objects.layout);
  if (!iter) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }
  gboolean color = FALSE, has_ink = FALSE;
  do {
    PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
    if (!run)
      continue;
    for (int i = 0; i < run->glyphs->num_glyphs; ++i) {
      PangoGlyphInfo *glyph = run->glyphs->glyphs + i;
      if (glyph->attr.is_color)
        color = TRUE;
      if (glyph->glyph != PANGO_GLYPH_EMPTY) {
        PangoRectangle glyph_ink;
        pango_font_get_glyph_extents(run->item->analysis.font, glyph->glyph,
                                     &glyph_ink, NULL);
        if (glyph_ink.width > 0 && glyph_ink.height > 0)
          has_ink = TRUE;
      }
    }
  } while (pango_layout_iter_next_run(iter));
  pango_layout_iter_free(iter);
  if (color) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_UNSUPPORTED_COLOR;
  }
  PangoRectangle ink, logical;
  pango_layout_get_pixel_extents(objects.layout, &ink, &logical);
  int unknown = pango_layout_get_unknown_glyphs_count(objects.layout);
  if (ink.width < 0 || ink.height < 0 || logical.width < 0 ||
      logical.height < 0 || unknown < 0) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
  }
  struct gpui_linux_text_mask_v2 result = {0};
  result.mask.unknown_glyph_count = unknown;
  double left = fmax(layout_left, ink.x), top = fmax(layout_top, ink.y);
  double right = fmin(layout_right, (double)ink.x + ink.width);
  double bottom = fmin(layout_bottom, (double)ink.y + ink.height);
  /* PANGO_GLYPH_EMPTY (e.g. tabs) can contribute a synthetic layout ink box
   * although the FT2 renderer draws nothing. Inspect actual nonempty glyph
   * ink before allocating, so whitespace needs neither budget nor texture. */
  if (!has_ink || right <= left || bottom <= top || !text_length) {
    free_layout(&objects);
    *output = result;
    return GPUI_LINUX_TEXT_OK;
  }
  double tile_left = floor(left), tile_top = floor(top);
  double tile_right = ceil(right), tile_bottom = ceil(bottom);
  if (tile_mode == RASTER_FILTER_HALO) {
    /* Linear filtering needs the adjacent layout-grid texel even when its
     * center lies beyond the exact visible clip. Keep one checked texel of
     * halo at interior crop edges, bounded by the full pixel ink tile.
     * Geometry stays exact; UVs below crop into this larger allocation. */
    if (tile_left > ink.x) tile_left -= 1.0;
    if (tile_top > ink.y) tile_top -= 1.0;
    if (tile_right < (double)ink.x + ink.width) tile_right += 1.0;
    if (tile_bottom < (double)ink.y + ink.height) tile_bottom += 1.0;
  }
  double width = tile_right - tile_left, height = tile_bottom - tile_top;
  if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 ||
      width > GPUI_LINUX_TEXT_MAX_MASK_DIMENSION ||
      height > GPUI_LINUX_TEXT_MAX_MASK_DIMENSION) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;
  }
  double origin_x = -tile_left * PANGO_SCALE;
  double origin_y = -tile_top * PANGO_SCALE;
  if (!isfinite(origin_x) || !isfinite(origin_y) ||
      origin_x < INT32_MIN || origin_x > INT32_MAX ||
      origin_y < INT32_MIN || origin_y > INT32_MAX) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  }
  result.mask.left = text_origin_x + left;
  result.mask.top = text_origin_y + top;
  result.mask.right = text_origin_x + right;
  result.mask.bottom = text_origin_y + bottom;
  result.u0 = (left - tile_left) / width;
  result.v0 = (top - tile_top) / height;
  result.u1 = (right - tile_left) / width;
  result.v1 = (bottom - tile_top) / height;
  if (!isfinite(result.mask.left) || !isfinite(result.mask.top) ||
      !isfinite(result.mask.right) || !isfinite(result.mask.bottom) ||
      fabs(result.mask.left) > 3e20 || fabs(result.mask.top) > 3e20 ||
      fabs(result.mask.right) > 3e20 || fabs(result.mask.bottom) > 3e20 ||
      result.mask.right <= result.mask.left ||
      result.mask.bottom <= result.mask.top ||
      !isfinite(result.u0) || !isfinite(result.v0) ||
      !isfinite(result.u1) || !isfinite(result.v1) ||
      result.u0 < 0 || result.v0 < 0 || result.u1 > 1 || result.v1 > 1 ||
      result.u1 <= result.u0 || result.v1 <= result.v0) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  }
  if (tile_mode == RASTER_FILTER_HALO) {
    const double tolerance = GPUI_LINUX_TEXT_COORDINATE_TOLERANCE;
    if (fabs((result.mask.left - text_origin_x) - left) > tolerance ||
        fabs((result.mask.top - text_origin_y) - top) > tolerance ||
        fabs((result.mask.right - text_origin_x) - right) > tolerance ||
        fabs((result.mask.bottom - text_origin_y) - bottom) > tolerance ||
        fabs((result.mask.right - result.mask.left) - (right - left)) > tolerance ||
        fabs((result.mask.bottom - result.mask.top) - (bottom - top)) > tolerance) {
      free_layout(&objects);
      return GPUI_LINUX_TEXT_INVALID_COORDINATES;
    }
  }
  result.mask.width = (int32_t)width;
  result.mask.height = (int32_t)height;
  size_t bytes = (size_t)result.mask.width * (size_t)result.mask.height;
  if (bytes / (size_t)result.mask.width != (size_t)result.mask.height ||
      bytes > (size_t)pixel_budget) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;
  }
  result.mask.pixels = g_try_malloc0(bytes);
  if (!result.mask.pixels) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;
  }
  FT_Bitmap bitmap = {0};
  bitmap.width = (unsigned int)result.mask.width;
  bitmap.rows = (unsigned int)result.mask.height;
  bitmap.pitch = result.mask.width;
  bitmap.buffer = result.mask.pixels;
  bitmap.num_grays = 256;
  bitmap.pixel_mode = FT_PIXEL_MODE_GRAY;
  /* No context matrix: layout and masks remain at logical resolution. */
  pango_ft2_render_layout_subpixel(&bitmap, objects.layout, (int)origin_x,
                                  (int)origin_y);
  gboolean covered = FALSE;
  for (size_t i = 0; i < bytes && !covered; ++i)
    covered = result.mask.pixels[i] != 0;
  if (!covered) {
    gpui_linux_text_mask_release_v2(&result);
    result.mask.unknown_glyph_count = unknown;
    free_layout(&objects);
    *output = result;
    return GPUI_LINUX_TEXT_OK;
  }
  free_layout(&objects);
  *output = result;
  return GPUI_LINUX_TEXT_OK;
}

void gpui_linux_text_mask_release_v2(struct gpui_linux_text_mask_v2 *mask) {
  if (!mask)
    return;
  gpui_linux_text_mask_release_v1(&mask->mask);
  memset(mask, 0, sizeof(*mask));
}

static int32_t raster_layout_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double bounds_width, double bounds_height, int32_t pixel_budget,
    struct gpui_linux_text_mask *output, gpui_lifecycle_counts *counts) {
  /* Preserve old buffer layout, failure priority and origin-zero clipping. */
  if (!output || pixel_budget < 0 || !isfinite(bounds_width) ||
      !isfinite(bounds_height) || bounds_width < 0 || bounds_height < 0 ||
      bounds_width > 1e20 || bounds_height > 1e20)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  int32_t status = gpui_linux_text_require_raster_v1(abi);
  if (status != GPUI_LINUX_TEXT_OK)
    return status;
  struct gpui_linux_text_mask_v2 result = {0};
  status = raster_layout_core(text, text_length, family, family_length,
      font_size_px, 0, 0, 0, 0, bounds_width, bounds_height, pixel_budget,
      RASTER_LEGACY_TILE, &result, counts);
  if (status == GPUI_LINUX_TEXT_OK)
    *output = result.mask;
  return status;
}

int32_t gpui_linux_text_raster_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double origin_x, double origin_y, double clip_x, double clip_y,
    double clip_width, double clip_height, int32_t pixel_budget,
    struct gpui_linux_text_mask_v2 *output) {
  if (abi != GPUI_LINUX_TEXT_RASTER_ABI)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  return raster_layout_core(text, text_length, family, family_length,
      font_size_px, origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
      pixel_budget, RASTER_FILTER_HALO, output, NULL);
}

int32_t gpui_linux_text_raster_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double bounds_width, double bounds_height, int32_t pixel_budget,
    struct gpui_linux_text_mask *output) {
  return raster_layout_v1(abi, text, text_length, family, family_length,
                           font_size_px, bounds_width, bounds_height,
                           pixel_budget, output, NULL);
}

/* Field admission deliberately delegates shaping, color-glyph detection and
 * grayscale rasterization to the same implementation used by Ubuntu frame
 * presentation. Its temporary mask is always released before this call
 * returns, including empty and unsupported-glyph successes. */
static int32_t admit_scene_text_run_impl(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double bounds_width, double bounds_height,
    int32_t pixel_budget, int32_t *released_output) {
  static const uint8_t sans[] = "sans";
  if (abi != GPUI_LINUX_TEXT_ABI || text_length < 0 ||
      (text_length > 0 && text == NULL) || !isfinite(font_size_px) ||
      font_size_px <= 0.0 || pixel_budget < 0 ||
      pixel_budget > GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (!isfinite(bounds_width) || !isfinite(bounds_height) ||
      bounds_width < 0.0 || bounds_height < 0.0)
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  if (text_length > GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES ||
      font_size_px > GPUI_LINUX_TEXT_MAX_SCENE_FONT_SIZE_PX ||
      bounds_width > GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_WIDTH ||
      bounds_height > GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_HEIGHT)
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;

  if (released_output)
    *released_output = 0;
  struct gpui_linux_text_mask mask = {0};
  int32_t status = raster_layout_v1(
      abi, text, text_length, sans, (int32_t)(sizeof(sans) - 1),
      font_size_px, bounds_width, bounds_height,
      pixel_budget, &mask, NULL);
  if (status == GPUI_LINUX_TEXT_OK && mask.unknown_glyph_count != 0)
    status = GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
  gpui_linux_text_mask_release_v1(&mask);
  if (released_output)
    *released_output = mask.pixels == NULL && mask.width == 0 &&
                       mask.height == 0 && mask.left == 0.0 &&
                       mask.top == 0.0 && mask.right == 0.0 &&
                       mask.bottom == 0.0 &&
                       mask.unknown_glyph_count == 0;
  return status;
}

int32_t gpui_linux_text_admit_scene_text_run_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double bounds_width, double bounds_height) {
  return admit_scene_text_run_impl(
      abi, text, text_length, font_size_px, bounds_width, bounds_height,
      GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS, NULL);
}

int32_t gpui_linux_text_test_admit_scene_text_run_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double bounds_width, double bounds_height,
    int32_t pixel_budget, int32_t *released_output) {
  if (!released_output)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  return admit_scene_text_run_impl(
      abi, text, text_length, font_size_px, bounds_width, bounds_height,
      pixel_budget, released_output);
}

static int32_t admit_scene_text_run_at_impl(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double origin_x, double origin_y,
    double clip_x, double clip_y, double clip_width, double clip_height,
    int32_t pixel_budget, int32_t *released_output) {
  static const uint8_t sans[] = "sans";
  if (abi != GPUI_LINUX_TEXT_RASTER_ABI || text_length < 0 ||
      (text_length > 0 && !text) || !isfinite(font_size_px) ||
      font_size_px <= 0 || pixel_budget < 0 ||
      pixel_budget > GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  if (!isfinite(origin_x) || !isfinite(origin_y) ||
      !isfinite(clip_x) || !isfinite(clip_y) ||
      !isfinite(clip_width) || !isfinite(clip_height) ||
      clip_width < 0 || clip_height < 0)
    return GPUI_LINUX_TEXT_INVALID_COORDINATES;
  if (text_length > GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES ||
      font_size_px > GPUI_LINUX_TEXT_MAX_SCENE_FONT_SIZE_PX ||
      clip_width > GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_WIDTH ||
      clip_height > GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_HEIGHT)
    return GPUI_LINUX_TEXT_RESOURCE_LIMIT;
  if (released_output)
    *released_output = 0;
  struct gpui_linux_text_mask_v2 mask = {0};
  int32_t status = gpui_linux_text_raster_v2(
      abi, text, text_length, sans, 4, font_size_px,
      origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
      pixel_budget, &mask);
  if (status == GPUI_LINUX_TEXT_OK && mask.mask.unknown_glyph_count != 0)
    status = GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
  gpui_linux_text_mask_release_v2(&mask);
  if (released_output)
    *released_output = !mask.mask.pixels && !mask.mask.width &&
        !mask.mask.height && !mask.mask.unknown_glyph_count &&
        mask.mask.left == 0 && mask.mask.top == 0 &&
        mask.mask.right == 0 && mask.mask.bottom == 0 &&
        mask.u0 == 0 && mask.v0 == 0 && mask.u1 == 0 && mask.v1 == 0;
  return status;
}

int32_t gpui_linux_text_admit_scene_text_run_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double origin_x, double origin_y,
    double clip_x, double clip_y, double clip_width, double clip_height) {
  return admit_scene_text_run_at_impl(abi, text, text_length, font_size_px,
      origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
      GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS, NULL);
}

int32_t gpui_linux_text_test_admit_scene_text_run_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    double font_size_px, double origin_x, double origin_y,
    double clip_x, double clip_y, double clip_width, double clip_height,
    int32_t pixel_budget, int32_t *released_output) {
  if (!released_output)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  return admit_scene_text_run_at_impl(abi, text, text_length, font_size_px,
      origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
      pixel_budget, released_output);
}

static int32_t test_lifecycle_v1(int32_t cycles, int32_t *output,
                                  int32_t output_capacity, int raster) {
  if (cycles < 1 || cycles > 1024 || !output || output_capacity < 3)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;

  static const uint8_t text[] = {'A'};
  static const uint8_t family[] = "DejaVu Sans";
  gpui_lifecycle_counts *states[1024] = {0};
  int32_t state_count = 0;
  gpui_lifecycle_totals totals = {0, 0, 0};
  for (int32_t i = 0; i < cycles; ++i) {
    gpui_lifecycle_counts *counts = g_try_new0(gpui_lifecycle_counts, 1);
    if (!counts)
      goto allocation_failure;
    g_mutex_init(&counts->mutex);
    g_cond_init(&counts->finalized);
    counts->references = 1; /* The test call holds a reference through reads. */
    double metrics[GPUI_LINUX_TEXT_HEADER_DOUBLES +
                   2 * GPUI_LINUX_TEXT_CARET_DOUBLES] = {0};
    int32_t status;
    if (raster) {
      struct gpui_linux_text_mask mask = {0};
      status = raster_layout_v1(
          GPUI_LINUX_TEXT_ABI, text, 1, family,
          (int32_t)(sizeof(family) - 1), 16.0, 64.0, 64.0, 4096, &mask, counts);
      gpui_linux_text_mask_release_v1(&mask);
    } else {
      status = measure_layout_v1(
          GPUI_LINUX_TEXT_ABI, text, 1, family,
          (int32_t)(sizeof(family) - 1), 16.0, metrics,
          (int32_t)(sizeof(metrics) / sizeof(metrics[0])), counts);
    }
    if (status != GPUI_LINUX_TEXT_OK) {
      int32_t map = 0, context = 0, layout = 0;
      lifecycle_snapshot(counts, &map, &context, &layout);
      g_printerr("lifecycle test stage=measure cycle=%d status=%d "
                 "map_finalized=%d context_finalized=%d "
                 "layout_finalized=%d\n",
                 i, status, map, context, layout);
      lifecycle_release(counts);
      for (int32_t j = 0; j < state_count; ++j)
        lifecycle_release(states[j]);
      return status;
    }
    states[state_count++] = counts;
  }

  /* Pango may release backend worker references after the synchronous API
   * returns. Use one shared post-measurement observation deadline for this
   * finalization loop, rather than assuming teardown is immediate. */
  gint64 deadline = g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND;
  int32_t failure = GPUI_LINUX_TEXT_OK;
  for (int32_t i = 0; i < state_count; ++i) {
    int32_t map = 0, context = 0, layout = 0;
    gboolean complete = lifecycle_wait_for_finalization(
        states[i], deadline, &map, &context, &layout);
    totals.map += map;
    totals.context += context;
    totals.layout += layout;
    if (!complete || map != 1 || context != 1 || layout != 1) {
      g_printerr("lifecycle test stage=finalize cycle=%d "
                 "map_finalized=%d context_finalized=%d "
                 "layout_finalized=%d deadline_reached=%d\n",
                 i, map, context, layout, complete ? 0 : 1);
      failure = GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
    }
  }
  /* Each weak callback owns a reference to its heap state. If the deadline
   * expires, releasing the test reference leaves that state alive until the
   * corresponding callback eventually runs. */
  for (int32_t i = 0; i < state_count; ++i)
    lifecycle_release(states[i]);
  if (failure != GPUI_LINUX_TEXT_OK)
    return failure;
  output[0] = totals.map;
  output[1] = totals.context;
  output[2] = totals.layout;
  return GPUI_LINUX_TEXT_OK;

allocation_failure:
  for (int32_t i = 0; i < state_count; ++i)
    lifecycle_release(states[i]);
  return GPUI_LINUX_TEXT_NATIVE_FAILURE;
}

int32_t gpui_linux_text_test_lifecycle_v1(int32_t cycles, int32_t *output,
                                          int32_t output_capacity) {
  return test_lifecycle_v1(cycles, output, output_capacity, 0);
}

int32_t gpui_linux_text_test_raster_lifecycle_v1(int32_t cycles, int32_t *output,
                                                 int32_t output_capacity) {
  return test_lifecycle_v1(cycles, output, output_capacity, 1);
}

static void observe_shape(PangoLayout *layout, const char *requested_family,
                          int32_t *glyphs, int32_t *clusters,
                          int32_t *runs, int32_t *fallback_runs) {
  PangoLayoutIter *iter = pango_layout_get_iter(layout);
  if (!iter)
    return;
  do {
    PangoLayoutRun *run = pango_layout_iter_get_run_readonly(iter);
    if (!run)
      continue;
    ++*runs;
    *glyphs += run->glyphs->num_glyphs;
    for (int i = 0; i < run->glyphs->num_glyphs; ++i)
      if (run->glyphs->glyphs[i].attr.is_cluster_start)
        ++*clusters;
    PangoFontDescription *description = pango_font_describe(run->item->analysis.font);
    const char *family = description
                             ? pango_font_description_get_family(description)
                             : NULL;
    if (!family || g_ascii_strcasecmp(family, requested_family) != 0)
      ++*fallback_runs;
    if (description)
      pango_font_description_free(description);
  } while (pango_layout_iter_next_run(iter));
  pango_layout_iter_free(iter);
}

int32_t gpui_linux_text_test_shape_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity) {
  if (output_capacity < 6)
    return GPUI_LINUX_TEXT_CAPACITY_TOO_SMALL;
  if (!output)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;
  int32_t scalar_count = 0;
  gpui_layout objects = {0};
  int32_t status = create_layout(abi, text, text_length, family, family_length,
                                 font_size_px, &objects, &scalar_count);
  if (status != GPUI_LINUX_TEXT_OK) {
    free_layout(&objects);
    return status;
  }
  char *family_c = g_try_malloc((gsize)family_length + 1);
  if (!family_c) {
    free_layout(&objects);
    return GPUI_LINUX_TEXT_NATIVE_FAILURE;
  }
  memcpy(family_c, family, (size_t)family_length);
  family_c[family_length] = '\0';
  int32_t glyphs = 0, clusters = 0, runs = 0, fallback_runs = 0;
  observe_shape(objects.layout, family_c, &glyphs, &clusters, &runs,
                &fallback_runs);
  g_free(family_c);
  int32_t unknown = pango_layout_get_unknown_glyphs_count(objects.layout);
  output[0] = (double)scalar_count;
  output[1] = (double)glyphs;
  output[2] = (double)clusters;
  output[3] = (double)runs;
  output[4] = (double)fallback_runs;
  output[5] = (double)unknown;
  free_layout(&objects);
  return GPUI_LINUX_TEXT_OK;
}
