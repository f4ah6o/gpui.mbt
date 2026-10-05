#include "../../platform/linux_text/linux_text.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(condition)                                                       \
  do {                                                                         \
    if (!(condition)) {                                                        \
      fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__,       \
              #condition);                                                    \
      exit(1);                                                                 \
    }                                                                          \
  } while (0)

static int32_t admit(const uint8_t *text, int32_t text_length,
                     double font_size_px, double bounds_width,
                     double bounds_height) {
  return gpui_linux_text_admit_scene_text_run_v1(
      GPUI_LINUX_TEXT_ABI, text, text_length, font_size_px, bounds_width,
      bounds_height);
}

static int32_t direct_sans_raster(const uint8_t *text, int32_t text_length,
                                  double font_size_px, double bounds_width,
                                  double bounds_height) {
  static const uint8_t sans[] = "sans";
  struct gpui_linux_text_mask mask = {0};
  int32_t status = gpui_linux_text_raster_v1(
      GPUI_LINUX_TEXT_ABI, text, text_length, sans,
      (int32_t)(sizeof(sans) - 1), font_size_px, bounds_width, bounds_height,
      GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS, &mask);
  if (status == GPUI_LINUX_TEXT_OK && mask.unknown_glyph_count != 0)
    status = GPUI_LINUX_TEXT_UNSUPPORTED_INPUT;
  gpui_linux_text_mask_release_v1(&mask);
  return status;
}

static void test_supported_runs(void) {
  static const uint8_t latin[] = "office affine";
  static const uint8_t japanese[] = "日本語かな";
  static const uint8_t combining[] = "a\xcc\x81";
  static const uint8_t zwj[] = "a\xe2\x80\x8d" "b";
  static const uint8_t text_presentation_vs[] = {
      0xe2, 0x9c, 0x88, 0xef, 0xb8, 0x8e}; /* U+2708 U+FE0E */
  CHECK(admit(latin, (int32_t)(sizeof(latin) - 1), 16.0, 256.0, 48.0) ==
        direct_sans_raster(latin, (int32_t)(sizeof(latin) - 1), 16.0, 256.0,
                           48.0));
  CHECK(admit(japanese, (int32_t)(sizeof(japanese) - 1), 16.0, 256.0,
              48.0) == direct_sans_raster(
                           japanese, (int32_t)(sizeof(japanese) - 1), 16.0,
                           256.0, 48.0));
  CHECK(admit(combining, (int32_t)sizeof(combining) - 1, 16.0, 96.0,
              48.0) == direct_sans_raster(combining,
                                          (int32_t)sizeof(combining) - 1,
                                          16.0, 96.0, 48.0));
  CHECK(admit(zwj, (int32_t)(sizeof(zwj) - 1), 16.0, 96.0, 48.0) ==
        direct_sans_raster(zwj, (int32_t)(sizeof(zwj) - 1), 16.0, 96.0,
                           48.0));
  CHECK(admit(text_presentation_vs, (int32_t)sizeof(text_presentation_vs),
              16.0, 96.0, 48.0) ==
        direct_sans_raster(text_presentation_vs,
                           (int32_t)sizeof(text_presentation_vs), 16.0, 96.0,
                           48.0));
}

static void test_empty_and_whitespace(void) {
  static const uint8_t whitespace[] = " \t";
  CHECK(admit(NULL, 0, 16.0, 0.0, 0.0) == GPUI_LINUX_TEXT_OK);
  CHECK(admit(whitespace, (int32_t)(sizeof(whitespace) - 1), 16.0, 64.0,
              32.0) == GPUI_LINUX_TEXT_OK);
}

static void test_color_and_malformed_utf8(void) {
  /* The fixture requires generic sans to resolve the actual Noto Color Emoji
   * glyph. The zero-area bounds prove color detection precedes raster crop. */
  static const uint8_t color_zwj[] = {
      0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d,
      0xf0, 0x9f, 0x92, 0xbb};
  static const uint8_t malformed[] = {0xf0, 0x28, 0x8c, 0x28};
  static const uint8_t unknown[] = {0xcd, 0xb8}; /* Unassigned U+0378. */
  CHECK(admit(color_zwj, (int32_t)sizeof(color_zwj), 16.0, 0.0, 0.0) ==
        GPUI_LINUX_TEXT_UNSUPPORTED_COLOR);
  CHECK(admit(color_zwj, (int32_t)sizeof(color_zwj), 16.0, 0.0, 0.0) ==
        direct_sans_raster(color_zwj, (int32_t)sizeof(color_zwj), 16.0, 0.0,
                           0.0));
  CHECK(admit(malformed, (int32_t)sizeof(malformed), 16.0, 128.0, 48.0) ==
        GPUI_LINUX_TEXT_UNSUPPORTED_INPUT);
  CHECK(admit(unknown, (int32_t)sizeof(unknown), 16.0, 128.0, 48.0) ==
        GPUI_LINUX_TEXT_UNSUPPORTED_INPUT);
}

static void test_direct_bounds_and_abi(void) {
  static const uint8_t latin[] = "A";
  uint8_t max_text[GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES];
  for (size_t i = 0; i < sizeof(max_text); ++i)
    max_text[i] = ' ';
  CHECK(gpui_linux_text_admit_scene_text_run_v1(
            99, latin, 1, 16.0, 64.0, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(gpui_linux_text_admit_scene_text_run_v1(
            GPUI_LINUX_TEXT_ABI, NULL, 1, 16.0, 64.0, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(admit(latin, 1, 16.0, -1.0, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit(latin, 1, 16.0, NAN, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit(latin, 1, 16.0, 64.0, INFINITY) ==
        GPUI_LINUX_TEXT_INVALID_COORDINATES);
  CHECK(admit(latin, 1, 16.0, 2049.0, 32.0) ==
        GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit(latin, 1, 16.0, 64.0, 129.0) ==
        GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit(latin, 1, 33.0, 64.0, 32.0) ==
        GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit(latin, 1, 0.0, 64.0, 32.0) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  /* The native field entry point enforces its byte cap before inspecting the
   * borrowed bytes. The pointer deliberately covers only the first byte. */
  CHECK(admit(latin, GPUI_LINUX_TEXT_MAX_SCENE_TEXT_BYTES + 1, 16.0, 64.0,
              32.0) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(admit(latin, 1, 16.0, GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_WIDTH,
              GPUI_LINUX_TEXT_MAX_SCENE_BOUNDS_HEIGHT) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(admit(max_text, (int32_t)sizeof(max_text), 32.0, 0.0, 0.0) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(admit(latin, 1, GPUI_LINUX_TEXT_MAX_SCENE_FONT_SIZE_PX, 64.0,
              32.0) == GPUI_LINUX_TEXT_OK);
}

static void test_runtime_admission_and_budget(void) {
  static const uint8_t text[] = "H";
  int32_t released = -1;
  CHECK(gpui_linux_text_require_raster_v1(GPUI_LINUX_TEXT_ABI) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(gpui_linux_text_require_raster_v1(99) ==
        GPUI_LINUX_TEXT_INVALID_ARGUMENT);
  CHECK(gpui_linux_text_test_raster_admission_v1(GPUI_LINUX_TEXT_ABI,
                                                 14999) ==
        GPUI_LINUX_TEXT_UNSUPPORTED_RASTER);
  CHECK(gpui_linux_text_test_raster_admission_v1(GPUI_LINUX_TEXT_ABI,
                                                 15000) ==
        GPUI_LINUX_TEXT_OK);
  CHECK(gpui_linux_text_test_admit_scene_text_run_v1(
            GPUI_LINUX_TEXT_ABI, text, 1, 32.0, 128.0, 64.0, 0,
            &released) == GPUI_LINUX_TEXT_RESOURCE_LIMIT);
  CHECK(released == 1);
}

static void test_temporary_mask_cleanup(void) {
  static const uint8_t text[] = "Release";
  for (int i = 0; i < 64; ++i) {
    int32_t released = -1;
    CHECK(gpui_linux_text_test_admit_scene_text_run_v1(
              GPUI_LINUX_TEXT_ABI, text, (int32_t)(sizeof(text) - 1), 24.0,
              256.0, 64.0, GPUI_LINUX_TEXT_MAX_SCENE_MASK_PIXELS,
              &released) == GPUI_LINUX_TEXT_OK);
    CHECK(released == 1);
  }
}

int main(void) {
  test_supported_runs();
  test_empty_and_whitespace();
  test_color_and_malformed_utf8();
  test_direct_bounds_and_abi();
  test_runtime_admission_and_budget();
  test_temporary_mask_cleanup();
  puts("linux_text field admission tests passed");
  return 0;
}
