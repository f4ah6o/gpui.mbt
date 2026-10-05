#include "../../platform/linux_text/linux_text.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,       \
              #condition);                                                    \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static const uint8_t dejavu[] = "DejaVu Sans";
static const int32_t test_mask_budget = 4 * 1024 * 1024;

static int32_t raster(const uint8_t *text, int32_t text_length,
                      const uint8_t *family, int32_t family_length,
                      double font_size_px, double bounds_width,
                      double bounds_height,
                      struct gpui_linux_text_mask *output) {
  return gpui_linux_text_raster_v1(
      GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
      font_size_px, bounds_width, bounds_height, test_mask_budget, output);
}

static int32_t raster_budget(const uint8_t *text, int32_t text_length,
                             const uint8_t *family, int32_t family_length,
                             double font_size_px, double bounds_width,
                             double bounds_height, int32_t pixel_budget,
                             struct gpui_linux_text_mask *output) {
  return gpui_linux_text_raster_v1(
      GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
      font_size_px, bounds_width, bounds_height, pixel_budget, output);
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

static void check_empty_mask(const struct gpui_linux_text_mask *mask) {
  CHECK(mask->pixels == NULL);
  CHECK(mask->width == 0 && mask->height == 0);
  CHECK(mask->left == 0.0 && mask->top == 0.0);
  CHECK(mask->right == 0.0 && mask->bottom == 0.0);
}

struct guarded_mask {
  uint64_t before;
  struct gpui_linux_text_mask mask;
  uint64_t after;
};

static void guarded_init(struct guarded_mask *guarded) {
  memset(guarded, 0, sizeof(*guarded));
  guarded->before = UINT64_C(0x1539a4f0d2c76b81);
  guarded->after = UINT64_C(0xe6c05b2f713894ad);
}

static void guarded_check(const struct guarded_mask *guarded) {
  CHECK(guarded->before == UINT64_C(0x1539a4f0d2c76b81));
  CHECK(guarded->after == UINT64_C(0xe6c05b2f713894ad));
}

static void check_mask_success(const uint8_t *text, int32_t text_length,
                               const uint8_t *family, int32_t family_length,
                               double font_size_px, double bounds_width,
                               double bounds_height,
                               int32_t expected_unknown_glyph_count) {
  struct guarded_mask guarded;
  guarded_init(&guarded);
  CHECK(raster(text, text_length, family, family_length, font_size_px,
               bounds_width, bounds_height, &guarded.mask) ==
        GPUI_LINUX_TEXT_OK);
  guarded_check(&guarded);
  CHECK(guarded.mask.unknown_glyph_count == expected_unknown_glyph_count);
  if (guarded.mask.pixels) {
    CHECK(guarded.mask.width <= GPUI_LINUX_TEXT_MAX_MASK_DIMENSION);
    CHECK(guarded.mask.height <= GPUI_LINUX_TEXT_MAX_MASK_DIMENSION);
    CHECK(isfinite(guarded.mask.left) && isfinite(guarded.mask.top));
    CHECK(isfinite(guarded.mask.right) && isfinite(guarded.mask.bottom));
    CHECK(guarded.mask.left >= 0.0 && guarded.mask.top >= 0.0);
    CHECK(guarded.mask.right <= bounds_width);
    CHECK(guarded.mask.bottom <= bounds_height);
    CHECK(guarded.mask.right > guarded.mask.left);
    CHECK(guarded.mask.bottom > guarded.mask.top);
    CHECK(mask_sum(&guarded.mask) > 0);
  } else {
    check_empty_mask(&guarded.mask);
  }
  gpui_linux_text_mask_release_v1(&guarded.mask);
  guarded_check(&guarded);
  check_empty_mask(&guarded.mask);
}

static void check_no_pixels_success(const uint8_t *text, int32_t text_length,
                                    double font_size_px,
                                    double bounds_width,
                                    double bounds_height) {
  struct guarded_mask guarded;
  guarded_init(&guarded);
  CHECK(raster(text, text_length, dejavu, (int32_t)(sizeof(dejavu) - 1),
               font_size_px, bounds_width, bounds_height,
               &guarded.mask) == GPUI_LINUX_TEXT_OK);
  guarded_check(&guarded);
  CHECK(guarded.mask.unknown_glyph_count == 0);
  check_empty_mask(&guarded.mask);
  gpui_linux_text_mask_release_v1(&guarded.mask);
  guarded_check(&guarded);
  check_empty_mask(&guarded.mask);
}

static void expect_failure_budget(int32_t expected_status, int32_t abi,
                                  const uint8_t *text, int32_t text_length,
                                  const uint8_t *family,
                                  int32_t family_length, double font_size_px,
                                  double bounds_width, double bounds_height,
                                  int32_t pixel_budget) {
  struct guarded_mask guarded;
  guarded_init(&guarded);
  /* If the implementation accidentally releases or otherwise follows this
   * pointer on an error path, ASan catches it. The value itself is only
   * compared; it is never dereferenced by the test. */
  guarded.mask.pixels = (uint8_t *)(uintptr_t)UINT64_C(0x13579);
  guarded.mask.width = 0x1234567;
  guarded.mask.height = 0x2345678;
  guarded.mask.left = 11.25;
  guarded.mask.top = -12.5;
  guarded.mask.right = 13.75;
  guarded.mask.bottom = -14.875;
  guarded.mask.unknown_glyph_count = 0x3456789;
  struct gpui_linux_text_mask before = guarded.mask;
  CHECK(gpui_linux_text_raster_v1(abi, text, text_length, family,
                                  family_length, font_size_px, bounds_width,
                                  bounds_height, pixel_budget, &guarded.mask) ==
        expected_status);
  guarded_check(&guarded);
  CHECK(memcmp(&guarded.mask, &before, sizeof(before)) == 0);
}

static void expect_failure(int32_t expected_status, int32_t abi,
                           const uint8_t *text, int32_t text_length,
                           const uint8_t *family, int32_t family_length,
                           double font_size_px, double bounds_width,
                           double bounds_height) {
  expect_failure_budget(expected_status, abi, text, text_length, family,
                        family_length, font_size_px, bounds_width,
                        bounds_height, test_mask_budget);
}

static void check_shape(const uint8_t *text, int32_t text_length,
                        const uint8_t *family, int32_t family_length,
                        double output[7]) {
  output[6] = 9273645.125;
  CHECK(gpui_linux_text_test_shape_v1(
            GPUI_LINUX_TEXT_ABI, text, text_length, family, family_length,
            32.0, output, 6) == GPUI_LINUX_TEXT_OK);
  CHECK(output[6] == 9273645.125);
}

static void test_raster_runtime_admission(void) {
  /* This direct call is also the C-level link proof for the production
   * capability probe: it uses Pango's actual linked runtime version. */
  CHECK(gpui_linux_text_require_raster_v1(GPUI_LINUX_TEXT_ABI) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(gpui_linux_text_require_raster_v1(99) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);

  /* Keep the threshold test deterministic independently of the installed
   * Pango version; the helper shares the production admission predicate. */
  CHECK(gpui_linux_text_test_raster_admission_v1(GPUI_LINUX_TEXT_ABI,
                                                 14999) ==
        GPUI_LINUX_TEXT_UNSUPPORTED_RASTER);
  CHECK(gpui_linux_text_test_raster_admission_v1(GPUI_LINUX_TEXT_ABI,
                                                 15000) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(gpui_linux_text_test_raster_admission_v1(99, 15000) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(gpui_linux_text_test_raster_admission_v1(GPUI_LINUX_TEXT_ABI, -1) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
}

static void test_text_coverage(void) {
  static const uint8_t ligature[] = "office affine";
  struct gpui_linux_text_mask mask = {0};
  check_mask_success(ligature, (int32_t)(sizeof(ligature) - 1), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0, 0);
  double shape[7] = {0};
  check_shape(ligature, (int32_t)(sizeof(ligature) - 1), dejavu,
              (int32_t)(sizeof(dejavu) - 1), shape);
  CHECK(shape[0] == 13.0);
  CHECK(shape[1] < shape[0]);
  CHECK(shape[2] < shape[0]);

  /* Ask for Japanese through a family that does not cover it. The shape seam
   * confirms that Fontconfig selected an actual fallback face, not a fake
   * fixture substitution or a .notdef box. */
  static const uint8_t japanese[] = "日本語かな";
  check_mask_success(japanese, (int32_t)(sizeof(japanese) - 1), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0, 0);
  memset(shape, 0, sizeof(shape));
  check_shape(japanese, (int32_t)(sizeof(japanese) - 1), dejavu,
              (int32_t)(sizeof(dejavu) - 1), shape);
  CHECK(shape[0] == 5.0);
  CHECK(shape[1] > 0.0 && shape[3] > 0.0);
  CHECK(shape[4] > 0.0);
  CHECK(shape[5] == 0.0);

  static const uint8_t combining[] = {'a', 0xcc, 0x81};
  check_mask_success(combining, (int32_t)sizeof(combining), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0, 0);
  memset(shape, 0, sizeof(shape));
  check_shape(combining, (int32_t)sizeof(combining), dejavu,
              (int32_t)(sizeof(dejavu) - 1), shape);
  CHECK(shape[0] == 2.0 && shape[1] == 1.0 && shape[2] == 1.0);

  static const uint8_t bidi[] = "abc אבג 123";
  check_mask_success(bidi, (int32_t)(sizeof(bidi) - 1), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0, 0);
  memset(shape, 0, sizeof(shape));
  check_shape(bidi, (int32_t)(sizeof(bidi) - 1), dejavu,
              (int32_t)(sizeof(dejavu) - 1), shape);
  CHECK(shape[1] > 0.0 && shape[3] > 0.0);
  CHECK(shape[5] == 0.0);

  /* U+0378 is unassigned and absent from the declared fixture faces. Pango's
   * unknown-glyph tofu box is observable, but is not claimed as support. */
  static const uint8_t missing[] = {0xcd, 0xb8};
  check_mask_success(missing, (int32_t)sizeof(missing), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0, 1);
  mask = (struct gpui_linux_text_mask){0};
  CHECK(raster(missing, (int32_t)sizeof(missing), dejavu,
               (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0,
               &mask) == GPUI_LINUX_TEXT_OK);
  CHECK(mask.unknown_glyph_count == 1);
  CHECK(mask_sum(&mask) > 0);
  gpui_linux_text_mask_release_v1(&mask);
}

static void test_empty_and_multiline(void) {
  static const uint8_t whitespace[] = " \t\n";
  static const uint8_t newline[] = "\n";
  static const uint8_t line[] = "A";
  static const uint8_t multiline[] = "A\nB";
  check_no_pixels_success(NULL, 0, 32.0, 512.0, 128.0);
  check_no_pixels_success(whitespace, (int32_t)(sizeof(whitespace) - 1),
                          32.0, 512.0, 128.0);
  check_no_pixels_success(newline, (int32_t)(sizeof(newline) - 1), 32.0,
                          512.0, 128.0);
  check_mask_success(line, (int32_t)(sizeof(line) - 1), dejavu,
                     (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0, 0);
  struct gpui_linux_text_mask one = {0}, two = {0}, zero_bounds = {0};
  CHECK(raster(line, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
               512.0, 128.0, &one) == GPUI_LINUX_TEXT_OK);
  CHECK(raster(multiline, (int32_t)(sizeof(multiline) - 1), dejavu,
               (int32_t)(sizeof(dejavu) - 1), 32.0, 512.0, 128.0,
               &two) == GPUI_LINUX_TEXT_OK);
  CHECK(one.pixels && two.pixels && mask_sum(&one) > 0 && mask_sum(&two) > 0);
  CHECK(two.height > one.height);
  CHECK(raster(line, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
               0.0, 128.0, &zero_bounds) == GPUI_LINUX_TEXT_OK);
  check_empty_mask(&zero_bounds);
  gpui_linux_text_mask_release_v1(&one);
  gpui_linux_text_mask_release_v1(&two);
  gpui_linux_text_mask_release_v1(&zero_bounds);
}

static void test_fractional_crop(void) {
  static const uint8_t text[] = "H";
  struct gpui_linux_text_mask full = {0}, cropped = {0};
  CHECK(raster(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
               512.0, 256.0, &full) == GPUI_LINUX_TEXT_OK);
  CHECK(full.pixels && mask_sum(&full) > 0);
  CHECK(full.right - full.left > 4.0 && full.bottom - full.top > 4.0);

  /* Crop one whole tile column/row plus a fractional remainder. The returned
   * rectangle is exact local geometry; it deliberately need not zero the
   * fractional boundary pixel in the A8 bytes. */
  double crop_width = full.right - 1.375;
  double crop_height = full.bottom - 1.625;
  CHECK(crop_width > full.left && crop_height > full.top);
  CHECK(raster(text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
               crop_width, crop_height, &cropped) == GPUI_LINUX_TEXT_OK);
  CHECK(cropped.pixels && mask_sum(&cropped) > 0);
  CHECK(cropped.left == full.left && cropped.top == full.top);
  CHECK(cropped.right == crop_width);
  CHECK(cropped.bottom == crop_height);
  CHECK(cropped.width == (int32_t)(ceil(cropped.right) - floor(cropped.left)));
  CHECK(cropped.height == (int32_t)(ceil(cropped.bottom) - floor(cropped.top)));
  CHECK(cropped.width == full.width - 1);
  CHECK(cropped.height == full.height - 1);
  gpui_linux_text_mask_release_v1(&full);
  gpui_linux_text_mask_release_v1(&cropped);
}

static void test_rejections_preserve_output(void) {
  static const uint8_t ordinary[] = "A";
  static const uint8_t nul_text[] = {'A', 0, 'B'};
  static const uint8_t malformed_utf8[] = {0xf0, 0x28, 0x8c, 0x28};
  static const uint8_t color_zwj[] = {
      0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d,
      0xf0, 0x9f, 0x92, 0xbb};
  static const uint8_t unknown[] = {0xcd, 0xb8};
  static const uint8_t empty_family[] = "";
  static const uint8_t color_family[] = "Noto Color Emoji";
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, 99, ordinary, 1, dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI, NULL,
                 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0,
                 96.0);
  expect_failure(GPUI_LINUX_TEXT_UNSUPPORTED_INPUT, GPUI_LINUX_TEXT_ABI,
                 nul_text, (int32_t)sizeof(nul_text), dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_UNSUPPORTED_INPUT, GPUI_LINUX_TEXT_ABI,
                 malformed_utf8, (int32_t)sizeof(malformed_utf8), dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_UNSUPPORTED_INPUT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, empty_family, 0, 32.0, 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 513.0,
                 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
                 -1.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
                 NAN, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
                 128.0, INFINITY);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 0.0,
                 128.0, 96.0);
  expect_failure(GPUI_LINUX_TEXT_INVALID_ARGUMENT, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 32.0,
                 1.0e21, 96.0);
  expect_failure_budget(GPUI_LINUX_TEXT_INVALID_ARGUMENT,
                        GPUI_LINUX_TEXT_ABI, ordinary, 1, dejavu,
                        (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0,
                        -1);

  /* PangoFT2 may provide only a monochrome missing-glyph box for a color
   * sequence; the ABI must reject the actual is_color run before zero-bounds
   * early-out and leave the caller's result bytes untouched. */
  expect_failure_budget(GPUI_LINUX_TEXT_UNSUPPORTED_COLOR,
                        GPUI_LINUX_TEXT_ABI, color_zwj,
                        (int32_t)sizeof(color_zwj), color_family,
                        (int32_t)(sizeof(color_family) - 1), 32.0, 0.0, 0.0,
                        0);
  /* The declared headless and GPU font profile must select a color glyph
   * through the renderer's actual generic sans request as well. */
  static const uint8_t sans[] = "sans";
  expect_failure_budget(GPUI_LINUX_TEXT_UNSUPPORTED_COLOR,
                        GPUI_LINUX_TEXT_ABI, color_zwj,
                        (int32_t)sizeof(color_zwj), sans, 4, 32.0,
                        128.0, 128.0, test_mask_budget);
  expect_failure_budget(GPUI_LINUX_TEXT_UNSUPPORTED_COLOR,
                        GPUI_LINUX_TEXT_ABI, color_zwj,
                        (int32_t)sizeof(color_zwj), sans, 4, 16.0,
                        32.0, 24.0, test_mask_budget);

  /* A nonempty mask has at least one byte; caller budget rejection must occur
   * before output allocation and preserve every result byte. */
  static const uint8_t budget_text[] = "H";
  struct gpui_linux_text_mask budget_mask = {0};
  CHECK(raster(budget_text, 1, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
               512.0, 256.0, &budget_mask) == GPUI_LINUX_TEXT_OK);
  CHECK(budget_mask.pixels && budget_mask.width > 0 && budget_mask.height > 0);
  int32_t budget_bytes = budget_mask.width * budget_mask.height;
  CHECK(budget_bytes > 1);
  gpui_linux_text_mask_release_v1(&budget_mask);
  expect_failure_budget(GPUI_LINUX_TEXT_RESOURCE_LIMIT,
                        GPUI_LINUX_TEXT_ABI, budget_text, 1, dejavu,
                        (int32_t)(sizeof(dejavu) - 1), 64.0, 512.0, 256.0,
                        budget_bytes - 1);
  expect_failure_budget(GPUI_LINUX_TEXT_RESOURCE_LIMIT,
                        GPUI_LINUX_TEXT_ABI, budget_text, 1, dejavu,
                        (int32_t)(sizeof(dejavu) - 1), 64.0, 512.0, 256.0,
                        0);
  struct gpui_linux_text_mask empty_with_zero_budget = {0};
  CHECK(raster_budget(NULL, 0, dejavu, (int32_t)(sizeof(dejavu) - 1), 64.0,
                      512.0, 256.0, 0, &empty_with_zero_budget) ==
        GPUI_LINUX_TEXT_OK);
  check_empty_mask(&empty_with_zero_budget);
  gpui_linux_text_mask_release_v1(&empty_with_zero_budget);

  size_t too_long_length = GPUI_LINUX_TEXT_MAX_TEXT_BYTES + 1u;
  uint8_t *too_long = (uint8_t *)malloc(too_long_length);
  CHECK(too_long != NULL);
  memset(too_long, 'A', too_long_length);
  expect_failure(GPUI_LINUX_TEXT_INPUT_TOO_LARGE, GPUI_LINUX_TEXT_ABI,
                 too_long, (int32_t)too_long_length, dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 32.0, 1.0e6, 96.0);
  free(too_long);

  size_t too_long_family_length = GPUI_LINUX_TEXT_MAX_FAMILY_BYTES + 1u;
  uint8_t *too_long_family = (uint8_t *)malloc(too_long_family_length);
  CHECK(too_long_family != NULL);
  memset(too_long_family, 'A', too_long_family_length);
  expect_failure(GPUI_LINUX_TEXT_INPUT_TOO_LARGE, GPUI_LINUX_TEXT_ABI,
                 ordinary, 1, too_long_family,
                 (int32_t)too_long_family_length, 32.0, 128.0, 96.0);
  free(too_long_family);

  /* A wide ink run exceeds the 2048 tile cap although each input dimension
   * is valid. This path should reject before allocating a partial result. */
  static const uint8_t wide_run[] = "WWWWWWWWWWWWWWWW";
  expect_failure(GPUI_LINUX_TEXT_RESOURCE_LIMIT, GPUI_LINUX_TEXT_ABI,
                 wide_run, (int32_t)(sizeof(wide_run) - 1), dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 512.0, 1.0e6, 1024.0);

  /* The combined scalar/font guard rejects a valid UTF-8 request before
   * materializing huge Pango geometry or a mask. */
  const size_t combined_count = 2048;
  uint8_t *combined = (uint8_t *)malloc(combined_count);
  CHECK(combined != NULL);
  memset(combined, 'A', combined_count);
  struct gpui_linux_text_mask at_combined_limit = {0};
  /* (2047 scalars + 1) * 512 is exactly the 1 MiB guard and is allowed; the
   * empty local bounds ensure this boundary case does not later need a tile. */
  CHECK(raster_budget(combined, (int32_t)combined_count - 1, dejavu,
                      (int32_t)(sizeof(dejavu) - 1), 512.0, 0.0, 0.0, 0,
                      &at_combined_limit) == GPUI_LINUX_TEXT_OK);
  check_empty_mask(&at_combined_limit);
  gpui_linux_text_mask_release_v1(&at_combined_limit);
  expect_failure_budget(GPUI_LINUX_TEXT_RESOURCE_LIMIT,
                        GPUI_LINUX_TEXT_ABI, combined,
                        (int32_t)combined_count, dejavu,
                        (int32_t)(sizeof(dejavu) - 1), 512.0, 0.0, 0.0, 0);
  free(combined);

  /* There is no output object to mutate or inspect on a null-result call. */
  CHECK(gpui_linux_text_raster_v1(
            GPUI_LINUX_TEXT_ABI, ordinary, 1, dejavu,
            (int32_t)(sizeof(dejavu) - 1), 32.0, 128.0, 96.0,
            test_mask_budget, NULL) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);

  /* U+0378 is missing, not a color glyph, and should remain a successful tofu
   * mask even when its clipped region is empty. */
  struct gpui_linux_text_mask no_bounds = {0};
  CHECK(raster(unknown, (int32_t)sizeof(unknown), dejavu,
               (int32_t)(sizeof(dejavu) - 1), 32.0, 0.0, 0.0,
               &no_bounds) == GPUI_LINUX_TEXT_OK);
  CHECK(no_bounds.unknown_glyph_count == 1);
  check_empty_mask(&no_bounds);
}

static void test_release_and_repeat_lifecycle(void) {
  static const uint8_t text[] = "Raster";
  for (int i = 0; i < 64; ++i) {
    struct guarded_mask guarded;
    guarded_init(&guarded);
    CHECK(raster(text, (int32_t)(sizeof(text) - 1), dejavu,
                 (int32_t)(sizeof(dejavu) - 1), 24.0, 256.0, 96.0,
                 &guarded.mask) == GPUI_LINUX_TEXT_OK);
    guarded_check(&guarded);
    CHECK(mask_sum(&guarded.mask) > 0);
    gpui_linux_text_mask_release_v1(&guarded.mask);
    guarded_check(&guarded);
    check_empty_mask(&guarded.mask);
    /* Release of the already cleared result is explicitly idempotent. */
    gpui_linux_text_mask_release_v1(&guarded.mask);
    guarded_check(&guarded);
    check_empty_mask(&guarded.mask);
  }
}

static void test_raster_lifecycle_observation(void) {
  const int32_t cycles = 64;
  int32_t output[4] = {-1, -1, -1, 761239};
  CHECK(gpui_linux_text_test_raster_lifecycle_v1(cycles, output, 3) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(output[0] == cycles);
  CHECK(output[1] == cycles);
  CHECK(output[2] == cycles);
  CHECK(output[3] == 761239);

  int32_t canary_output[4] = {451, 452, 453, 454};
  int32_t before[4];
  memcpy(before, canary_output, sizeof(before));
  CHECK(gpui_linux_text_test_raster_lifecycle_v1(0, canary_output, 3) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(memcmp(before, canary_output, sizeof(before)) == 0);
  CHECK(gpui_linux_text_test_raster_lifecycle_v1(1, canary_output, 2) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(memcmp(before, canary_output, sizeof(before)) == 0);
}

int main(void) {
  test_raster_runtime_admission();
  test_text_coverage();
  test_empty_and_multiline();
  test_fractional_crop();
  test_rejections_preserve_output();
  test_release_and_repeat_lifecycle();
  test_raster_lifecycle_observation();
  puts("linux_text raster tests passed");
  return 0;
}
