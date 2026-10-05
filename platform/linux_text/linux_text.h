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
  GPUI_LINUX_TEXT_INVALID_COORDINATES = 7
};

int32_t gpui_linux_text_measure_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity);

int32_t gpui_linux_text_hit_test_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double x_px, double y_px, double *output, int32_t output_capacity);

/* Native-test-only observation seams; not part of the MoonBit public API. */
int32_t gpui_linux_text_test_shape_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity);
int32_t gpui_linux_text_test_lifecycle_v1(int32_t cycles, int32_t *output,
                                         int32_t output_capacity);

#endif
