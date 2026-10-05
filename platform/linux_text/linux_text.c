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
} gpui_lifecycle_counts;

static void lifecycle_retain(gpui_lifecycle_counts *counts) {
  if (counts->references < INT32_MAX)
    ++counts->references;
}

static void lifecycle_release(gpui_lifecycle_counts *counts) {
  if (!counts)
    return;
  if (counts->references > 0)
    --counts->references;
  if (counts->references == 0)
    g_free(counts);
}

static void count_map_finalize(gpointer data, GObject *object) {
  (void)object;
  gpui_lifecycle_counts *counts = data;
  if (counts->map < INT32_MAX)
    ++counts->map;
  lifecycle_release(counts);
}

static void count_context_finalize(gpointer data, GObject *object) {
  (void)object;
  gpui_lifecycle_counts *counts = data;
  if (counts->context < INT32_MAX)
    ++counts->context;
  lifecycle_release(counts);
}

static void count_layout_finalize(gpointer data, GObject *object) {
  (void)object;
  gpui_lifecycle_counts *counts = data;
  if (counts->layout < INT32_MAX)
    ++counts->layout;
  lifecycle_release(counts);
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

int32_t gpui_linux_text_test_lifecycle_v1(int32_t cycles, int32_t *output,
                                          int32_t output_capacity) {
  if (cycles < 1 || cycles > 1024 || !output || output_capacity < 3)
    return GPUI_LINUX_TEXT_INVALID_ARGUMENT;

  static const uint8_t text[] = {'A'};
  static const uint8_t family[] = "DejaVu Sans";
  gpui_lifecycle_counts totals = {0, 0, 0, 0};
  for (int32_t i = 0; i < cycles; ++i) {
    gpui_lifecycle_counts *counts = g_try_new0(gpui_lifecycle_counts, 1);
    if (!counts)
      return GPUI_LINUX_TEXT_NATIVE_FAILURE;
    counts->references = 1; /* The test call holds a reference through reads. */
    double metrics[GPUI_LINUX_TEXT_HEADER_DOUBLES +
                   2 * GPUI_LINUX_TEXT_CARET_DOUBLES] = {0};
    int32_t status = measure_layout_v1(
        GPUI_LINUX_TEXT_ABI, text, 1, family,
        (int32_t)(sizeof(family) - 1), 16.0, metrics,
        (int32_t)(sizeof(metrics) / sizeof(metrics[0])), counts);
    if (status != GPUI_LINUX_TEXT_OK) {
      lifecycle_release(counts);
      return status;
    }
    if (counts->map != 1 || counts->context != 1 || counts->layout != 1) {
      lifecycle_release(counts);
      return GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT;
    }
    totals.map += counts->map;
    totals.context += counts->context;
    totals.layout += counts->layout;
    /* If a Pango object is unexpectedly retained, its weak callback still has
     * a live heap state reference and cannot dereference a dead stack frame. */
    lifecycle_release(counts);
  }
  output[0] = totals.map;
  output[1] = totals.context;
  output[2] = totals.layout;
  return GPUI_LINUX_TEXT_OK;
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
