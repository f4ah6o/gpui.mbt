#include "../../platform/linux_text/linux_text.h"

#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,      \
              #condition);                                                    \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static const uint8_t dejavu[] = "DejaVu Sans";
static const uint8_t generic_sans[] = "sans";
static const int32_t test_mask_budget = 4 * 1024 * 1024;

static int32_t raster_v2(const uint8_t *text, int32_t text_length,
                         const uint8_t *family, int32_t family_length,
                         double font_size_px, double origin_x,
                         double origin_y, double clip_x, double clip_y,
                         double clip_width, double clip_height,
                         int32_t pixel_budget,
                         struct gpui_linux_text_mask_v2 *output) {
  return gpui_linux_text_raster_v2(
      GPUI_LINUX_TEXT_RASTER_ABI, text, text_length, family, family_length,
      font_size_px, origin_x, origin_y, clip_x, clip_y, clip_width,
      clip_height, pixel_budget, output);
}

static int32_t raster_v1(const uint8_t *text, int32_t text_length,
                         const uint8_t *family, int32_t family_length,
                         double font_size_px, double width, double height,
                         int32_t pixel_budget,
                         struct gpui_linux_text_mask *output) {
  return gpui_linux_text_raster_v1(
      GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
      font_size_px, width, height, pixel_budget, output);
}

static int32_t admit_v2(const uint8_t *text, int32_t text_length,
                        double font_size_px, double origin_x,
                        double origin_y, double clip_x, double clip_y,
                        double clip_width, double clip_height) {
  return gpui_linux_text_admit_scene_text_run_v2(
      GPUI_LINUX_TEXT_RASTER_ABI, text, text_length, font_size_px, origin_x,
      origin_y, clip_x, clip_y, clip_width, clip_height);
}

static size_t mask_sum(const struct gpui_linux_text_mask *mask) {
  CHECK(mask->pixels != NULL);
  CHECK(mask->width > 0 && mask->height > 0);
  size_t bytes = (size_t)mask->width * (size_t)mask->height;
  size_t sum = 0;
  for (size_t i = 0; i < bytes; ++i)
    sum += mask->pixels[i];
  return sum;
}

static int nearly_equal(double actual, double expected) {
  return fabs(actual - expected) <= 1e-10;
}

static void check_empty_v2(const struct gpui_linux_text_mask_v2 *result,
                           int32_t expected_unknown) {
  CHECK(result->mask.pixels == NULL);
  CHECK(result->mask.width == 0 && result->mask.height == 0);
  CHECK(result->mask.left == 0.0 && result->mask.top == 0.0);
  CHECK(result->mask.right == 0.0 && result->mask.bottom == 0.0);
  CHECK(result->mask.unknown_glyph_count == expected_unknown);
  CHECK(result->u0 == 0.0 && result->v0 == 0.0);
  CHECK(result->u1 == 0.0 && result->v1 == 0.0);
}

/* The mask bytes cover an integer tile in unchanged Pango layout coordinates.
 * The UV endpoints therefore map exact visible geometry into that tile. */
static void check_uv_for_origin(const struct gpui_linux_text_mask_v2 *result,
                                double origin_x, double origin_y) {
  const struct gpui_linux_text_mask *mask = &result->mask;
  CHECK(mask->pixels != NULL && mask->width > 0 && mask->height > 0);
  CHECK(isfinite(result->u0) && isfinite(result->v0));
  CHECK(isfinite(result->u1) && isfinite(result->v1));
  CHECK(result->u0 >= 0.0 && result->v0 >= 0.0);
  CHECK(result->u1 <= 1.0 && result->v1 <= 1.0);
  CHECK(result->u1 > result->u0 && result->v1 > result->v0);

  double left = mask->left - origin_x;
  double top = mask->top - origin_y;
  double right = mask->right - origin_x;
  double bottom = mask->bottom - origin_y;
  /* v2 storage can include a private one-texel sampling halo. Recover its
   * integer layout-grid origin from the exact geometry/UV crop instead of
   * assuming the allocation starts at floor(visible-left/top). */
  double tile_left = left - result->u0 * mask->width;
  double tile_top = top - result->v0 * mask->height;
  double tile_right = right - result->u1 * mask->width;
  double tile_bottom = bottom - result->v1 * mask->height;
  CHECK(nearly_equal(tile_left, nearbyint(tile_left)));
  CHECK(nearly_equal(tile_top, nearbyint(tile_top)));
  CHECK(nearly_equal(tile_right, tile_left));
  CHECK(nearly_equal(tile_bottom, tile_top));
  CHECK(tile_left <= floor(left) && tile_left >= floor(left) - 1.0);
  CHECK(tile_top <= floor(top) && tile_top >= floor(top) - 1.0);
  CHECK(tile_left + mask->width >= ceil(right));
  CHECK(tile_left + mask->width <= ceil(right) + 1.0);
  CHECK(tile_top + mask->height >= ceil(bottom));
  CHECK(tile_top + mask->height <= ceil(bottom) + 1.0);
}

static void compare_v1_v2_geometry(const struct gpui_linux_text_mask *legacy,
                                   const struct gpui_linux_text_mask_v2 *versioned) {
  const struct gpui_linux_text_mask *mask = &versioned->mask;
  /* ABI v1 retains its historic allocation and filtering bytes. ABI v2 may
   * add halo texels, so only visible layout-coordinate geometry is shared. */
  CHECK(legacy->left == mask->left && legacy->top == mask->top);
  CHECK(legacy->right == mask->right && legacy->bottom == mask->bottom);
  CHECK(legacy->unknown_glyph_count == mask->unknown_glyph_count);
}

static double sample_axis_linear(const uint8_t *pixels, int32_t width,
                                 int32_t height, double u, double v) {
  double fx = u * width - 0.5;
  double fy = v * height - 0.5;
  int32_t x0 = (int32_t)floor(fx), y0 = (int32_t)floor(fy);
  int32_t x1 = x0 + 1, y1 = y0 + 1;
  double tx = fx - floor(fx), ty = fy - floor(fy);
  if (x0 < 0) x0 = 0;
  if (x1 < 0) x1 = 0;
  if (y0 < 0) y0 = 0;
  if (y1 < 0) y1 = 0;
  if (x0 >= width) x0 = width - 1;
  if (x1 >= width) x1 = width - 1;
  if (y0 >= height) y0 = height - 1;
  if (y1 >= height) y1 = height - 1;
  double p00 = pixels[(size_t)y0 * (size_t)width + (size_t)x0];
  double p10 = pixels[(size_t)y0 * (size_t)width + (size_t)x1];
  double p01 = pixels[(size_t)y1 * (size_t)width + (size_t)x0];
  double p11 = pixels[(size_t)y1 * (size_t)width + (size_t)x1];
  return (p00 + (p10 - p00) * tx) * (1.0 - ty) +
         (p01 + (p11 - p01) * tx) * ty;
}

/* Match the texture lookup made by a quad whose UVs interpolate over the
 * exact visible mask bounds. Layout coordinates are kept separate from the
 * user-space text origin so shifted and unshifted rasters can be compared. */
static double sample_linear_layout(
    const struct gpui_linux_text_mask_v2 *result, double origin_x,
    double origin_y, double layout_x, double layout_y) {
  const struct gpui_linux_text_mask *mask = &result->mask;
  CHECK(mask->pixels != NULL && mask->width > 0 && mask->height > 0);
  double x = origin_x + layout_x;
  double y = origin_y + layout_y;
  CHECK(x >= mask->left && x <= mask->right);
  CHECK(y >= mask->top && y <= mask->bottom);
  double u = result->u0 + (x - mask->left) /
                              (mask->right - mask->left) *
                              (result->u1 - result->u0);
  double v = result->v0 + (y - mask->top) /
                              (mask->bottom - mask->top) *
                              (result->v1 - result->v0);
  return sample_axis_linear(mask->pixels, mask->width, mask->height, u, v);
}

static void compare_v1_v2_pixel_centers(
    const struct gpui_linux_text_mask *legacy,
    const struct gpui_linux_text_mask_v2 *versioned, double origin_x,
    double origin_y) {
  CHECK(legacy->pixels != NULL && versioned->mask.pixels != NULL);
  double tile_left = floor(legacy->left - origin_x);
  double tile_top = floor(legacy->top - origin_y);
  for (int32_t y = 0; y < legacy->height; ++y) {
    for (int32_t x = 0; x < legacy->width; ++x) {
      double layout_x = tile_left + (double)x + 0.5;
      double layout_y = tile_top + (double)y + 0.5;
      double old_a8 = legacy->pixels[(size_t)y * (size_t)legacy->width +
                                     (size_t)x];
      double v2_a8 = sample_linear_layout(versioned, origin_x, origin_y,
                                          layout_x, layout_y);
      CHECK(nearly_equal(old_a8, v2_a8));
    }
  }
}

static void check_same_layout_samples(
    const struct gpui_linux_text_mask_v2 *full, double full_origin_x,
    double full_origin_y, const struct gpui_linux_text_mask_v2 *cropped,
    double cropped_origin_x, double cropped_origin_y, double left, double top,
    double right, double bottom) {
  CHECK(full->mask.pixels != NULL && cropped->mask.pixels != NULL);
  CHECK(right > left && bottom > top);

  /* Pixel-center samples are the v2 visible A8 coverage in the unchanged
   * Pango layout grid, even when the two allocations have different strides. */
  for (double y = floor(top) + 0.5; y < bottom; y += 1.0) {
    for (double x = floor(left) + 0.5; x < right; x += 1.0) {
      if (x <= left || x >= right || y <= top || y >= bottom)
        continue;
      double a = sample_linear_layout(full, full_origin_x, full_origin_y, x, y);
      double b = sample_linear_layout(cropped, cropped_origin_x,
                                      cropped_origin_y, x, y);
      CHECK(nearly_equal(a, b));
    }
  }

  /* Fractional lookups across the entire common rectangle exercise GL_LINEAR
   * interpolation, including all four corners and samples close to each
   * visible edge where an absent halo used to clamp to the wrong texel. */
  for (int32_t yi = 0; yi <= 8; ++yi) {
    double y = top + (bottom - top) * (double)yi / 8.0;
    for (int32_t xi = 0; xi <= 8; ++xi) {
      double x = left + (right - left) * (double)xi / 8.0;
      double a = sample_linear_layout(full, full_origin_x, full_origin_y, x, y);
      double b = sample_linear_layout(cropped, cropped_origin_x,
                                      cropped_origin_y, x, y);
      CHECK(nearly_equal(a, b));
    }
  }
  double epsilon_x = fmin(0.01, (right - left) / 100.0);
  double epsilon_y = fmin(0.01, (bottom - top) / 100.0);
  const double edge_x[] = {left + epsilon_x, right - epsilon_x};
  const double edge_y[] = {top + epsilon_y, bottom - epsilon_y};
  for (size_t yi = 0; yi < sizeof(edge_y) / sizeof(edge_y[0]); ++yi)
    for (size_t xi = 0; xi < sizeof(edge_x) / sizeof(edge_x[0]); ++xi) {
      double a = sample_linear_layout(full, full_origin_x, full_origin_y,
                                      edge_x[xi], edge_y[yi]);
      double b = sample_linear_layout(cropped, cropped_origin_x,
                                      cropped_origin_y, edge_x[xi], edge_y[yi]);
      CHECK(nearly_equal(a, b));
    }
}

static void test_v1_compatibility_and_uv(void) {
  static const uint8_t upper_accent[] = "Á";
  static const uint8_t composed_lower[] = "á";
  static const uint8_t decomposed_upper[] = {'A', 0xcc, 0x81};
  static const uint8_t decomposed_lower[] = {'a', 0xcc, 0x81};
  static const struct {
    const uint8_t *bytes;
    int32_t length;
  } samples[] = {
      {(const uint8_t *)"H", 1},
      {(const uint8_t *)"j", 1},
      {(const uint8_t *)"J", 1},
      {upper_accent, (int32_t)(sizeof(upper_accent) - 1)},
      {composed_lower, (int32_t)(sizeof(composed_lower) - 1)},
      {decomposed_upper, (int32_t)sizeof(decomposed_upper)},
      {decomposed_lower, (int32_t)sizeof(decomposed_lower)},
  };

  for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i) {
    struct gpui_linux_text_mask old_mask = {0};
    struct gpui_linux_text_mask_v2 new_mask = {0};
    CHECK(raster_v1(samples[i].bytes, samples[i].length, dejavu,
                    (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0,
                    test_mask_budget, &old_mask) == GPUI_LINUX_TEXT_OK);
    CHECK(raster_v2(samples[i].bytes, samples[i].length, dejavu,
                    (int32_t)(sizeof(dejavu) - 1), 32.0, 0.0, 0.0, 0.0,
                    0.0, 512.0, 128.0, test_mask_budget, &new_mask) ==
          GPUI_LINUX_TEXT_OK);
    compare_v1_v2_geometry(&old_mask, &new_mask);
    CHECK(old_mask.pixels != NULL && new_mask.mask.pixels != NULL);
    CHECK(mask_sum(&old_mask) > 0);
    if (new_mask.mask.pixels)
      CHECK(mask_sum(&new_mask.mask) > 0);
    check_uv_for_origin(&new_mask, 0.0, 0.0);
    compare_v1_v2_pixel_centers(&old_mask, &new_mask, 0.0, 0.0);
    gpui_linux_text_mask_release_v1(&old_mask);
    gpui_linux_text_mask_release_v2(&new_mask);
    check_empty_v2(&new_mask, 0);
  }
}

static void expect_raster_v2_failure(
    int32_t expected_status, int32_t abi, const uint8_t *text,
    int32_t text_length, const uint8_t *family, int32_t family_length,
    double font_size_px, double origin_x, double origin_y, double clip_x,
    double clip_y, double clip_width, double clip_height,
    int32_t pixel_budget);

static void get_ink_bounds(const uint8_t *text, int32_t text_length,
                           const uint8_t *family, int32_t family_length,
                           double font_size_px, double *left, double *top,
                           double *right, double *bottom) {
  double metrics[64] = {0};
  CHECK(gpui_linux_text_measure_v1(
            GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
            font_size_px, metrics, 64) ==
        GPUI_LINUX_TEXT_OK);
  *left = metrics[4];
  *top = metrics[5];
  *right = metrics[4] + metrics[6];
  *bottom = metrics[5] + metrics[7];
  CHECK(isfinite(*left) && isfinite(*top));
  CHECK(isfinite(*right) && isfinite(*bottom));
  CHECK(*right > *left && *bottom > *top);
}

static void test_negative_ink_reference_and_integer_inset(void) {
  static const uint8_t upper_accent[] = "Á";
  static const uint8_t composed_lower[] = "á";
  static const uint8_t decomposed_upper[] = {'A', 0xcc, 0x81};
  static const uint8_t decomposed_lower[] = {'a', 0xcc, 0x81};
  static const struct {
    const uint8_t *bytes;
    int32_t length;
    int expect_negative_left;
    int expect_negative_top;
  } samples[] = {
      {(const uint8_t *)"j", 1, 1, 0},
      {(const uint8_t *)"J", 1, 1, 0},
      {upper_accent, (int32_t)(sizeof(upper_accent) - 1), 1, 1},
      {composed_lower, (int32_t)(sizeof(composed_lower) - 1), 0, 1},
      {decomposed_upper, (int32_t)sizeof(decomposed_upper), 1, 1},
      {decomposed_lower, (int32_t)sizeof(decomposed_lower), 0, 1},
  };

  for (size_t i = 0; i < sizeof(samples) / sizeof(samples[0]); ++i) {
    double ink_left, ink_top, ink_right, ink_bottom;
    get_ink_bounds(samples[i].bytes, samples[i].length, generic_sans,
                   (int32_t)(sizeof(generic_sans) - 1), 32.0, &ink_left,
                   &ink_top, &ink_right, &ink_bottom);
    double pixel_left = floor(ink_left);
    double pixel_top = floor(ink_top);
    double pixel_right = ceil(ink_right);
    double pixel_bottom = ceil(ink_bottom);
    if (samples[i].expect_negative_left)
      CHECK(pixel_left < 0.0);
    if (samples[i].expect_negative_top)
      CHECK(pixel_top < 0.0);

    struct gpui_linux_text_mask_v2 full_reference = {0};
    struct gpui_linux_text_mask_v2 inset = {0};
    /* The reference starts well inside a large item-local clip, so even a
     * negative layout bearing is fully rasterized instead of clipped away. */
    CHECK(raster_v2(samples[i].bytes, samples[i].length, generic_sans,
                    (int32_t)(sizeof(generic_sans) - 1), 32.0, 32.0, 32.0, 0.0,
                    0.0, 512.0, 128.0, test_mask_budget,
                    &full_reference) == GPUI_LINUX_TEXT_OK);
    CHECK(full_reference.mask.pixels != NULL);
    CHECK(full_reference.mask.left < full_reference.mask.right);
    CHECK(full_reference.mask.top < full_reference.mask.bottom);

    /* The checked integral origin is the least nonnegative integer x/y which
     * contains the entire ink box. It intentionally does not duplicate the
     * text-field's logical/ink union policy. */
    double inset_x = ceil(fmax(0.0, -fmin(0.0, pixel_left)));
    double inset_y = ceil(fmax(0.0, -fmin(0.0, pixel_top)));
    CHECK(inset_x >= 0.0 && inset_y >= 0.0);
    CHECK(inset_x + pixel_left >= 0.0);
    CHECK(inset_y + pixel_top >= 0.0);
    CHECK(inset_x + pixel_right <= 2048.0);
    CHECK(inset_y + pixel_bottom <= 128.0);
    CHECK(raster_v2(samples[i].bytes, samples[i].length, generic_sans,
                    (int32_t)(sizeof(generic_sans) - 1), 32.0, inset_x, inset_y,
                    0.0, 0.0, 2048.0, 128.0, test_mask_budget,
                    &inset) == GPUI_LINUX_TEXT_OK);
    CHECK(inset.mask.pixels != NULL);
    CHECK(inset.mask.width == full_reference.mask.width);
    CHECK(inset.mask.height == full_reference.mask.height);
    CHECK(memcmp(inset.mask.pixels, full_reference.mask.pixels,
                 (size_t)inset.mask.width * (size_t)inset.mask.height) == 0);
    CHECK(nearly_equal(inset.mask.left - inset_x,
                       full_reference.mask.left - 32.0));
    CHECK(nearly_equal(inset.mask.top - inset_y,
                       full_reference.mask.top - 32.0));
    CHECK(inset.mask.left >= 0.0 && inset.mask.top >= 0.0);
    CHECK(inset.mask.right <= 2048.0 && inset.mask.bottom <= 128.0);
    CHECK(nearly_equal(inset.mask.left, inset_x + pixel_left));
    CHECK(nearly_equal(inset.mask.right, inset_x + pixel_right));
    CHECK(nearly_equal(inset.mask.top, inset_y + pixel_top));
    CHECK(nearly_equal(inset.mask.bottom, inset_y + pixel_bottom));
    check_uv_for_origin(&full_reference, 32.0, 32.0);
    check_uv_for_origin(&inset, inset_x, inset_y);

    /* Keep a fractional clip just inside all four real Pango ink edges. The
     * halo must remain clipped to that full-ink pixel tile while its visible
     * edge samples still match the uncut v2 reference. */
    struct gpui_linux_text_mask_v2 near_ink_edge = {0};
    const double edge_inset = 0.125;
    double edge_clip_x = full_reference.mask.left + edge_inset;
    double edge_clip_y = full_reference.mask.top + edge_inset;
    double edge_clip_right = full_reference.mask.right - edge_inset;
    double edge_clip_bottom = full_reference.mask.bottom - edge_inset;
    CHECK(edge_clip_right > edge_clip_x && edge_clip_bottom > edge_clip_y);
    CHECK(raster_v2(samples[i].bytes, samples[i].length, generic_sans,
                    (int32_t)(sizeof(generic_sans) - 1), 32.0, 32.0, 32.0,
                    edge_clip_x, edge_clip_y,
                    edge_clip_right - edge_clip_x,
                    edge_clip_bottom - edge_clip_y, test_mask_budget,
                    &near_ink_edge) == GPUI_LINUX_TEXT_OK);
    CHECK(near_ink_edge.mask.pixels != NULL);
    CHECK(near_ink_edge.mask.width == full_reference.mask.width);
    CHECK(near_ink_edge.mask.height == full_reference.mask.height);
    check_uv_for_origin(&near_ink_edge, 32.0, 32.0);
    check_same_layout_samples(
        &full_reference, 32.0, 32.0, &near_ink_edge, 32.0, 32.0,
        near_ink_edge.mask.left - 32.0, near_ink_edge.mask.top - 32.0,
        near_ink_edge.mask.right - 32.0, near_ink_edge.mask.bottom - 32.0);

    gpui_linux_text_mask_release_v2(&full_reference);
    gpui_linux_text_mask_release_v2(&inset);
    gpui_linux_text_mask_release_v2(&near_ink_edge);
  }
}

static void test_fractional_origin_clip_and_pixel_tile(void) {
  static const uint8_t text[] = "H";
  const double font_size = 64.0;
  struct gpui_linux_text_mask_v2 full = {0};
  struct gpui_linux_text_mask_v2 cropped = {0};
  CHECK(raster_v2(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1),
                  font_size, 0.0, 0.0, 0.0, 0.0, 512.0, 256.0,
                  test_mask_budget, &full) == GPUI_LINUX_TEXT_OK);
  CHECK(full.mask.pixels != NULL && mask_sum(&full.mask) > 0);

  const double origin_x = 13.25;
  const double origin_y = 7.5;
  const double layout_left = full.mask.left + 1.375;
  const double layout_top = full.mask.top + 1.625;
  const double layout_right = full.mask.right - 1.25;
  const double layout_bottom = full.mask.bottom - 1.125;
  const double clip_x = origin_x + layout_left;
  const double clip_y = origin_y + layout_top;
  const double clip_right = origin_x + layout_right;
  const double clip_bottom = origin_y + layout_bottom;
  CHECK(layout_right > layout_left && layout_bottom > layout_top);
  CHECK(raster_v2(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1),
                  font_size, origin_x, origin_y, clip_x, clip_y,
                  clip_right - clip_x, clip_bottom - clip_y,
                  test_mask_budget, &cropped) == GPUI_LINUX_TEXT_OK);
  CHECK(cropped.mask.pixels != NULL && mask_sum(&cropped.mask) > 0);
  CHECK(nearly_equal(cropped.mask.left, clip_x));
  CHECK(nearly_equal(cropped.mask.top, clip_y));
  CHECK(nearly_equal(cropped.mask.right, clip_right));
  CHECK(nearly_equal(cropped.mask.bottom, clip_bottom));
  CHECK(cropped.mask.width <= full.mask.width);
  CHECK(cropped.mask.height <= full.mask.height);
  check_uv_for_origin(&cropped, origin_x, origin_y);

  check_same_layout_samples(&full, 0.0, 0.0, &cropped, origin_x, origin_y,
                            layout_left, layout_top, layout_right,
                            layout_bottom);

  /* The old visible-only tile would fit this budget. v2 must account for the
   * complete halo tile before allocation and reject without touching output. */
  int32_t visible_width =
      (int32_t)(ceil(layout_right) - floor(layout_left));
  int32_t visible_height =
      (int32_t)(ceil(layout_bottom) - floor(layout_top));
  int32_t visible_budget = visible_width * visible_height;
  int32_t halo_pixels = cropped.mask.width * cropped.mask.height;
  CHECK(visible_width > 0 && visible_height > 0);
  CHECK(visible_budget < halo_pixels);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_RESOURCE_LIMIT, GPUI_LINUX_TEXT_RASTER_ABI, text, 1,
      dejavu, (int32_t)(sizeof(dejavu) - 1), font_size, origin_x, origin_y,
      clip_x, clip_y, clip_right - clip_x, clip_bottom - clip_y,
      visible_budget);
  gpui_linux_text_mask_release_v2(&full);
  gpui_linux_text_mask_release_v2(&cropped);
}

static void test_h18_fractional_crop_linear_halo(void) {
  static const uint8_t text[] = "H";
  const double origin_x = 1.25, origin_y = 0.0;
  const double clip_x = 3.35, clip_y = 0.0;
  struct gpui_linux_text_mask_v2 full = {0};
  struct gpui_linux_text_mask_v2 cropped = {0};
  CHECK(raster_v2(text, 1, generic_sans,
                  (int32_t)(sizeof(generic_sans) - 1), 18.0, origin_x,
                  origin_y, -100.0, -100.0, 200.0, 200.0,
                  test_mask_budget, &full) == GPUI_LINUX_TEXT_OK);
  CHECK(raster_v2(text, 1, generic_sans,
                  (int32_t)(sizeof(generic_sans) - 1), 18.0, origin_x,
                  origin_y, clip_x, clip_y, 20.0, 30.0,
                  test_mask_budget, &cropped) == GPUI_LINUX_TEXT_OK);
  CHECK(full.mask.pixels != NULL && cropped.mask.pixels != NULL);
  CHECK(nearly_equal(cropped.mask.left, clip_x));
  CHECK(nearly_equal(full.mask.left, origin_x));
  CHECK(nearly_equal(cropped.mask.right, full.mask.right));
  check_uv_for_origin(&full, origin_x, origin_y);
  check_uv_for_origin(&cropped, origin_x, origin_y);

  /* This exact layout was the regression: before the halo, the full A8
   * reference sampled 66 at (3.5, 3.5) while the cropped texture sampled 88. */
  const double sample_world_x = 3.5, sample_world_y = 3.5;
  double sample_layout_x = sample_world_x - origin_x;
  double sample_layout_y = sample_world_y - origin_y;
  double full_a8 = sample_linear_layout(&full, origin_x, origin_y,
                                        sample_layout_x, sample_layout_y);
  double cropped_a8 = sample_linear_layout(&cropped, origin_x, origin_y,
                                           sample_layout_x, sample_layout_y);
  CHECK(nearly_equal(full_a8, 66.0));
  CHECK(nearly_equal(cropped_a8, full_a8));

  double visible_left = cropped.mask.left - origin_x;
  double visible_top = cropped.mask.top - origin_y;
  double visible_right = cropped.mask.right - origin_x;
  double visible_bottom = cropped.mask.bottom - origin_y;
  check_same_layout_samples(&full, origin_x, origin_y, &cropped, origin_x,
                            origin_y, visible_left, visible_top,
                            visible_right, visible_bottom);
  gpui_linux_text_mask_release_v2(&full);
  gpui_linux_text_mask_release_v2(&cropped);
}

struct guarded_v2 {
  uint64_t before;
  struct gpui_linux_text_mask_v2 result;
  uint64_t after;
};

static void guarded_v2_init(struct guarded_v2 *guarded) {
  memset(guarded, 0, sizeof(*guarded));
  guarded->before = UINT64_C(0x19a3c74d5e6082bf);
  guarded->after = UINT64_C(0xe48206e5d47c3a91);
}

static void guarded_v2_bad_output(struct guarded_v2 *guarded) {
  guarded_v2_init(guarded);
  guarded->result.mask.pixels = (uint8_t *)(uintptr_t)UINT64_C(0x13579);
  guarded->result.mask.width = 0x1234567;
  guarded->result.mask.height = 0x2345678;
  guarded->result.mask.left = 11.25;
  guarded->result.mask.top = -12.5;
  guarded->result.mask.right = 13.75;
  guarded->result.mask.bottom = -14.875;
  guarded->result.mask.unknown_glyph_count = 0x3456789;
  guarded->result.u0 = 0.125;
  guarded->result.v0 = 0.25;
  guarded->result.u1 = 0.75;
  guarded->result.v1 = 0.875;
}

static void guarded_v2_check(const struct guarded_v2 *guarded) {
  CHECK(guarded->before == UINT64_C(0x19a3c74d5e6082bf));
  CHECK(guarded->after == UINT64_C(0xe48206e5d47c3a91));
}

static void expect_raster_v2_failure(
    int32_t expected_status, int32_t abi, const uint8_t *text,
    int32_t text_length, const uint8_t *family, int32_t family_length,
    double font_size_px, double origin_x, double origin_y, double clip_x,
    double clip_y, double clip_width, double clip_height,
    int32_t pixel_budget) {
  struct guarded_v2 guarded;
  guarded_v2_bad_output(&guarded);
  struct gpui_linux_text_mask_v2 before = guarded.result;
  CHECK(gpui_linux_text_raster_v2(
            abi, text, text_length, family, family_length, font_size_px,
            origin_x, origin_y, clip_x, clip_y, clip_width, clip_height,
            pixel_budget, &guarded.result) == expected_status);
  guarded_v2_check(&guarded);
  CHECK(memcmp(&guarded.result, &before, sizeof(before)) == 0);
}

static void test_zero_coverage_crop_release(void) {
  static const uint8_t spaced[] = "H H";
  struct gpui_linux_text_mask_v2 full = {0};
  CHECK(raster_v2(spaced, (int32_t)(sizeof(spaced) - 1), dejavu,
                  (int32_t)(sizeof(dejavu) - 1), 64.0, 0.0, 0.0, 0.0,
                  0.0, 512.0, 128.0, test_mask_budget, &full) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(full.mask.pixels != NULL && mask_sum(&full.mask) > 0);

  double tile_left = full.mask.left - full.u0 * full.mask.width;
  int32_t blank_column = -1;
  /* Find a three-texel all-zero run inside actual ink extents. A fractional
   * clip within its middle column gives v2 an allocated halo tile, but no
   * coverage; this reaches the render-then-release success path. */
  for (int32_t x = 1; x + 1 < full.mask.width && blank_column < 0; ++x) {
    int blank = 1;
    for (int32_t column = x - 1; column <= x + 1 && blank; ++column)
      for (int32_t y = 0; y < full.mask.height; ++y)
        if (full.mask.pixels[(size_t)y * (size_t)full.mask.width +
                             (size_t)column] != 0) {
          blank = 0;
          break;
        }
    double sample_left = tile_left + (double)x + 0.25;
    double sample_right = tile_left + (double)x + 0.75;
    if (blank && sample_left > full.mask.left &&
        sample_right < full.mask.right)
      blank_column = x;
  }
  CHECK(blank_column >= 0);
  double clip_x = tile_left + (double)blank_column + 0.25;
  double clip_y = full.mask.top;
  double clip_bottom = full.mask.bottom;
  struct guarded_v2 no_coverage;
  guarded_v2_init(&no_coverage);
  CHECK(raster_v2(spaced, (int32_t)(sizeof(spaced) - 1), dejavu,
                  (int32_t)(sizeof(dejavu) - 1), 64.0, 0.0, 0.0, clip_x,
                  clip_y, 0.5, clip_bottom - clip_y, test_mask_budget,
                  &no_coverage.result) == GPUI_LINUX_TEXT_OK);
  guarded_v2_check(&no_coverage);
  check_empty_v2(&no_coverage.result, 0);
  gpui_linux_text_mask_release_v2(&no_coverage.result);
  gpui_linux_text_mask_release_v2(&no_coverage.result);
  guarded_v2_check(&no_coverage);
  check_empty_v2(&no_coverage.result, 0);
  gpui_linux_text_mask_release_v2(&full);
}

static void test_far_origin_preflight_and_checked_coordinates(void) {
  static const uint8_t ordinary[] = "A";
  static const uint8_t malformed[] = {0xf0, 0x28, 0x8c, 0x28};
  static const uint8_t color_zwj[] = {
      0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d,
      0xf0, 0x9f, 0x92, 0xbb};
  static const uint8_t unknown[] = {0xcd, 0xb8};
  CHECK(gpui_linux_text_require_raster_v1(GPUI_LINUX_TEXT_ABI) ==
        GPUI_LINUX_TEXT_OK);

  struct gpui_linux_text_mask_v2 far_empty = {0};
  CHECK(raster_v2(ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0,
                  1000000.0, -1000000.0, 0.0, 0.0, 64.0, 32.0,
                  test_mask_budget, &far_empty) == GPUI_LINUX_TEXT_OK);
  check_empty_v2(&far_empty, 0);
  gpui_linux_text_mask_release_v2(&far_empty);

  struct guarded_v2 clipped_out;
  guarded_v2_init(&clipped_out);
  CHECK(raster_v2(ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0,
                  0.0, 0.0, 1000.0, 1000.0, 64.0, 32.0,
                  test_mask_budget, &clipped_out.result) ==
        GPUI_LINUX_TEXT_OK);
  guarded_v2_check(&clipped_out);
  check_empty_v2(&clipped_out.result, 0);
  gpui_linux_text_mask_release_v2(&clipped_out.result);
  guarded_v2_check(&clipped_out);
  check_empty_v2(&clipped_out.result, 0);

  /* A successful raster with no actual glyph ink produces the same fully
   * zero mask state; releasing that state repeatedly is safe. */
  static const uint8_t whitespace[] = " \t";
  struct guarded_v2 no_glyph_ink;
  guarded_v2_init(&no_glyph_ink);
  CHECK(raster_v2(whitespace, (int32_t)(sizeof(whitespace) - 1), dejavu,
                  (int32_t)(sizeof(dejavu) - 1), 24.0, 0.0, 0.0, 0.0,
                  0.0, 64.0, 32.0, test_mask_budget,
                  &no_glyph_ink.result) == GPUI_LINUX_TEXT_OK);
  guarded_v2_check(&no_glyph_ink);
  check_empty_v2(&no_glyph_ink.result, 0);
  gpui_linux_text_mask_release_v2(&no_glyph_ink.result);
  gpui_linux_text_mask_release_v2(&no_glyph_ink.result);
  guarded_v2_check(&no_glyph_ink);
  check_empty_v2(&no_glyph_ink.result, 0);

  /* An offscreen clip cannot bypass full-input/runtime/color preflight. */
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_UNSUPPORTED_INPUT, GPUI_LINUX_TEXT_RASTER_ABI,
      malformed, (int32_t)sizeof(malformed), dejavu,
      (int32_t)(sizeof(dejavu) - 1), 24.0, 1000000.0, -1000000.0,
      0.0, 0.0, 64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INPUT_TOO_LARGE, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, GPUI_LINUX_TEXT_MAX_TEXT_BYTES + 1, dejavu,
      (int32_t)(sizeof(dejavu) - 1), 24.0, 1000000.0, -1000000.0,
      0.0, 0.0, 64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_UNSUPPORTED_COLOR, GPUI_LINUX_TEXT_RASTER_ABI,
      color_zwj, (int32_t)sizeof(color_zwj), generic_sans,
      (int32_t)(sizeof(generic_sans) - 1), 24.0, 1000000.0, -1000000.0,
      0.0, 0.0, 64.0, 32.0, test_mask_budget);

  struct gpui_linux_text_mask_v2 missing = {0};
  CHECK(raster_v2(unknown, (int32_t)sizeof(unknown), dejavu,
                  (int32_t)(sizeof(dejavu) - 1), 24.0, 1000000.0,
                  -1000000.0, 0.0, 0.0, 64.0, 32.0, test_mask_budget,
                  &missing) == GPUI_LINUX_TEXT_OK);
  check_empty_v2(&missing, 1);
  gpui_linux_text_mask_release_v2(&missing);

  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI, ordinary, 1,
      dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, 0.0, 0.0, 0.0, 0.0,
      64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_COORDINATES, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, NAN,
      0.0, 0.0, 0.0, 64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_COORDINATES, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, 0.0,
      0.0, 1.0e20, 0.0, 64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_COORDINATES, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, DBL_MAX,
      0.0, 0.0, 0.0, 64.0, 32.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_COORDINATES, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, 0.0,
      0.0, 0.0, INFINITY, 64.0, 32.0, test_mask_budget);
  /* At this magnitude adding a positive clip extent would round back to the
   * same edge; checked rectangle arithmetic must reject it before Pango. */
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_COORDINATES, GPUI_LINUX_TEXT_RASTER_ABI,
      ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0, 0.0,
      0.0, 1.0e20, 0.0, 64.0, 32.0, test_mask_budget);
}

static void test_raster_budget_caps_and_release(void) {
  static const uint8_t text[] = "H";
  static const uint8_t too_wide[] = "WWWWWWWWWWWWWWWW";
  struct gpui_linux_text_mask_v2 measured = {0};
  CHECK(raster_v2(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
                  0.0, 0.0, 0.0, 0.0, 512.0, 256.0,
                  test_mask_budget, &measured) == GPUI_LINUX_TEXT_OK);
  CHECK(measured.mask.pixels != NULL);
  int32_t exact_budget = measured.mask.width * measured.mask.height;
  CHECK(exact_budget > 1);
  gpui_linux_text_mask_release_v2(&measured);
  check_empty_v2(&measured, 0);

  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_RESOURCE_LIMIT, GPUI_LINUX_TEXT_RASTER_ABI, text, 1,
      dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0, 0.0, 0.0, 0.0, 0.0,
      512.0, 256.0, exact_budget - 1);
  struct gpui_linux_text_mask_v2 at_budget = {0};
  CHECK(raster_v2(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
                  0.0, 0.0, 0.0, 0.0, 512.0, 256.0, exact_budget,
                  &at_budget) == GPUI_LINUX_TEXT_OK);
  CHECK(at_budget.mask.width * at_budget.mask.height == exact_budget);
  gpui_linux_text_mask_release_v2(&at_budget);
  gpui_linux_text_mask_release_v2(&at_budget);
  check_empty_v2(&at_budget, 0);

  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_RESOURCE_LIMIT, GPUI_LINUX_TEXT_RASTER_ABI,
      too_wide, (int32_t)(sizeof(too_wide) - 1), dejavu,
      (int32_t)(sizeof(dejavu) - 1), 512.0, 0.0, 0.0, 0.0, 0.0,
      1.0e6, 1024.0, test_mask_budget);
  expect_raster_v2_failure(
      GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_RASTER_ABI, text, 1,
      dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0, 0.0, 0.0, 0.0, 0.0,
      512.0, 256.0, -1);

  for (int i = 0; i < 64; ++i) {
    struct guarded_v2 guarded;
    guarded_v2_init(&guarded);
    CHECK(raster_v2(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 24.0,
                    2.25, 1.5, 0.0, 0.0, 128.0, 48.0,
                    test_mask_budget, &guarded.result) == GPUI_LINUX_TEXT_OK);
    guarded_v2_check(&guarded);
    CHECK(guarded.result.mask.pixels != NULL);
    gpui_linux_text_mask_release_v2(&guarded.result);
    guarded_v2_check(&guarded);
    check_empty_v2(&guarded.result, 0);
    gpui_linux_text_mask_release_v2(&guarded.result);
    guarded_v2_check(&guarded);
    check_empty_v2(&guarded.result, 0);
  }
}

static void test_scene_admission_v2(void) {
  static const uint8_t latin[] = "office affine";
  static const uint8_t japanese[] = "日本語かな";
  static const uint8_t combining[] = {'a', 0xcc, 0x81};
  static const uint8_t text_presentation[] = {0xe2, 0x9c, 0x88,
                                               0xef, 0xb8, 0x8e};
  static const uint8_t color_zwj[] = {
      0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d,
      0xf0, 0x9f, 0x92, 0xbb};
  static const uint8_t malformed[] = {0xf0, 0x28, 0x8c, 0x28};
  static const uint8_t unknown[] = {0xcd, 0xb8};
  static const uint8_t one[] = "A";
  const struct {
    const uint8_t *bytes;
    int32_t length;
  } supported[] = {
      {latin, (int32_t)(sizeof(latin) - 1)},
      {japanese, (int32_t)(sizeof(japanese) - 1)},
      {combining, (int32_t)sizeof(combining)},
      {text_presentation, (int32_t)sizeof(text_presentation)},
  };

  for (size_t i = 0; i < sizeof(supported) / sizeof(supported[0]); ++i) {
    int32_t direct = gpui_linux_text_admit_scene_text_run_v1(
        GPUI_LINUX_TEXT_ABI, supported[i].bytes, supported[i].length, 16.0,
        256.0, 48.0);
    CHECK(admit_v2(supported[i].bytes, supported[i].length, 16.0, 0.0, 0.0,
                   0.0, 0.0, 256.0, 48.0) == direct);
    CHECK(admit_v2(supported[i].bytes, supported[i].length, 16.0, 2.25,
                   3.5, 0.0, 0.0, 256.0, 48.0) == direct);
  }

  CHECK(admit_v2(NULL, 0, 16.0, 1000000.0, -1000000.0, 0.0, 0.0,
                 0.0, 0.0) == GPUI_LINUX_TEXT_OK);
  CHECK(admit_v2(one, 1, 16.0, 1000000.0, -1000000.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_OK);
  CHECK(admit_v2((const uint8_t *)" \t", 2, 16.0, 0.0, 0.0, 0.0,
                 0.0, 64.0, 32.0) == GPUI_LINUX_TEXT_OK);

  CHECK(admit_v2(color_zwj, (int32_t)sizeof(color_zwj), 16.0, 1000000.0,
                 -1000000.0, 0.0, 0.0, 0.0,
                 0.0) == GPUI_LINUX_TEXT_UNSUPPORTED_COLOR);
  CHECK(admit_v2(malformed, (int32_t)sizeof(malformed), 16.0, 1000000.0,
                 -1000000.0, 0.0, 0.0, 0.0,
                 0.0) == GPUI_LINUX_TEXT_UNSUPPORTED_INPUT);
  CHECK(admit_v2(unknown, (int32_t)sizeof(unknown), 16.0, 1000000.0,
                 -1000000.0, 0.0, 0.0, 0.0,
                 0.0) == GPUI_LINUX_TEXT_UNSUPPORTED_INPUT);

  int32_t released = -1;
  CHECK(gpui_linux_text_test_admit_scene_text_run_v2(
            GPUI_LINUX_TEXT_RASTER_ABI, one, 1, 16.0, 0.0, 0.0,
            0.0, 0.0, 64.0, 32.0, 0, &released) ==
        GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(released == 1);
  released = -1;
  CHECK(gpui_linux_text_test_admit_scene_text_run_v2(
            GPUI_LINUX_TEXT_RASTER_ABI, one, 1, 16.0, 1000000.0,
            -1000000.0, 0.0, 0.0, 64.0, 32.0,
            GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS, &released) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(released == 1);
  for (int i = 0; i < 64; ++i) {
    released = -1;
    CHECK(gpui_linux_text_test_admit_scene_text_run_v2(
              GPUI_LINUX_TEXT_RASTER_ABI, latin,
              (int32_t)(sizeof(latin) - 1), 24.0, 2.25, 1.5,
              0.0, 0.0, 256.0, 64.0,
              GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS, &released) ==
          GPUI_LINUX_TEXT_OK);
    CHECK(released == 1);
  }
}

static void test_scene_admission_v2_validation(void) {
  static const uint8_t one[] = "A";
  uint8_t max_text[GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES];
  memset(max_text, ' ', sizeof(max_text));
  int32_t released = 73;

  CHECK(gpui_linux_text_admit_scene_text_run_v2(
            99, one, 1, 16.0, 0.0, 0.0, 0.0, 0.0, 64.0, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(gpui_linux_text_admit_scene_text_run_v2(
            GPUI_LINUX_TEXT_RASTER_ABI, NULL, 1, 16.0, 0.0, 0.0,
            0.0, 0.0, 64.0, 32.0) == GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(gpui_linux_text_test_admit_scene_text_run_v2(
            GPUI_LINUX_TEXT_RASTER_ABI, one, 1, 16.0, 0.0, 0.0,
            0.0, 0.0, 64.0, 32.0, -1, &released) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(released == 73);
  CHECK(admit_v2(one, 1, 16.0, NAN, 0.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit_v2(one, 1, 16.0, 0.0, 0.0, 0.0, 0.0,
                 -1.0, 32.0) == GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit_v2(one, 1, 16.0, 1.0e20, 0.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit_v2(one, 1, 16.0, 0.0, 0.0, 0.0, 0.0,
                 2048.01, 32.0) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit_v2(one, 1, 16.0, 0.0, 0.0, 0.0, 0.0,
                 64.0, 128.01) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit_v2(one, 1, 32.01, 0.0, 0.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit_v2(one, 1, 0.0, 0.0, 0.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(admit_v2(one, GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES + 1, 16.0,
                 1000000.0, -1000000.0, 0.0, 0.0,
                 64.0, 32.0) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit_v2(max_text, (int32_t)sizeof(max_text), 32.0, 0.0, 0.0,
                 0.0, 0.0, 0.0, 0.0) == GPUI_LINUX_TEXT_OK);
  CHECK(admit_v2(one, 1, GPUI_LINUX_TEXT_MAX_SCENE_FONT_SIZE_PX,
                 0.0, 0.0, 0.0, 0.0,
                 GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_WIDTH,
                 GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_HEIGHT) ==
        GPUI_LINUX_TEXT_OK);
}

int main(void) {
  test_v1_compatibility_and_uv();
  test_negative_ink_reference_and_integer_inset();
  test_fractional_origin_clip_and_pixel_tile();
  test_h18_fractional_crop_linear_halo();
  test_zero_coverage_crop_release();
  test_far_origin_preflight_and_checked_coordinates();
  test_raster_budget_caps_and_release();
  test_scene_admission_v2();
  test_scene_admission_v2_validation();
  puts("linux_text origin raster and admission tests passed");
  return 0;
}
