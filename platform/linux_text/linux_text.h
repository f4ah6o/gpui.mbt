#ifndef GPUI_LINUX_TEXT_H
#define GPUI_LINUX_TEXT_H

#include <stdint.h>

/* Synchronous, borrowed-buffer-only private ABI. Pango objects never escape. */
#define GPUI_LINUX_TEXT_ABI 1
#define GPUI_LINUX_TEXT_MAX_TEXT_BYTES 16384
#define GPUI_LINUX_TEXT_MAX_FAMILY_BYTES 256
#define GPUI_LINUX_TEXT_MAX_FONT_SIZE_PX 512.0
#define GPUI_LINUX_TEXT_HEADER_DOUBLES 12
#define GPUI_LINUX_TEXT_CARET_DOUBLES 10

enum gpui_linux_text_status {
  GPUI_LINUX_TEXT_OK = 0,
  GPUI_LINUX_TEXT_INVALID_ARGUMENT = 1,
  GPUI_LINUX_TEXT_UNSUPPORTED_INPUT = 2,
  GPUI_LINUX_TEXT_INPUT_TOO_LARGE = 3,
  GPUI_LINUX_TEXT_CAPACITY_TOO_SMALL = 4,
  GPUI_LINUX_TEXT_NATIVE_FAILURE = 5,
  GPUI_LINUX_TEXT_INVALID_NATIVE_RESULT = 6,
  GPUI_LINUX_TEXT_INVALID_COORDINATES = 7,
  GPUI_LINUX_TEXT_UNSUPPORTED_COLOR = 8,
  GPUI_LINUX_TEXT_RESOURCE_LIMIT = 9,
  GPUI_LINUX_TEXT_UNSUPPORTED_RASTER = 10
};

int32_t gpui_linux_text_measure_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity);

int32_t gpui_linux_text_hit_test_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double x_px, double y_px, double *output, int32_t output_capacity);

/* Private C-to-C raster result. No Pango handles cross this boundary. Pixels
 * are packed, top-down logical-resolution A8, owned by the successful caller.
 * left/top/right/bottom are the exact visible item-local rectangle. Failure
 * leaves output unchanged. pixel_budget caps the allocation before it occurs. Release is idempotent and clears the result. */
#define GPUI_LINUX_TEXT_MAX_MASK_DIMENSION 2048
struct gpui_linux_text_mask {
  uint8_t *pixels;
  int32_t width, height;
  double left, top, right, bottom;
  int32_t unknown_glyph_count;
};
/* Real linked ABI/runtime admission; grayscale glyph-color metadata requires
 * Pango >=1.50. No native handles or runtime version number are exposed. */
int32_t gpui_linux_text_require_raster_v1(int32_t abi);
int32_t gpui_linux_text_raster_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double bounds_width, double bounds_height, int32_t pixel_budget,
    struct gpui_linux_text_mask *output);
void gpui_linux_text_mask_release_v1(struct gpui_linux_text_mask *mask);

int32_t gpui_linux_text_test_raster_admission_v1(int32_t abi,
                                                int32_t runtime_version);

/* Native-test-only observation seams; not part of the MoonBit public API. */
int32_t gpui_linux_text_test_shape_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity);
int32_t gpui_linux_text_test_lifecycle_v1(int32_t cycles, int32_t *output,
                                         int32_t output_capacity);
int32_t gpui_linux_text_test_raster_lifecycle_v1(int32_t cycles, int32_t *output,
                                                int32_t output_capacity);

#endif
