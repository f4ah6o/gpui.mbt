#ifndef GPUI_WINDOWS_TEXT_H
#define GPUI_WINDOWS_TEXT_H

#include <stdint.h>

/* Private synchronous DirectWrite ABI. All text/results are copied during a
 * call; no COM interface or caller buffer is retained. */
#define GPUI_WINDOWS_TEXT_ABI 1
#define GPUI_WINDOWS_TEXT_RASTER_ABI 2
#define GPUI_WINDOWS_TEXT_HEADER_DOUBLES 12
#define GPUI_WINDOWS_TEXT_CARET_DOUBLES 10
#define GPUI_WINDOWS_TEXT_MAX_TEXT_BYTES 16384
#define GPUI_WINDOWS_TEXT_MAX_FAMILY_BYTES 256
#define GPUI_WINDOWS_TEXT_MAX_FONT_SIZE 512.0
#define GPUI_WINDOWS_TEXT_MAX_SCENE_BYTES 4096
#define GPUI_WINDOWS_TEXT_MAX_SCENE_FONT_SIZE 32.0
#define GPUI_WINDOWS_TEXT_MAX_SCENE_WIDTH 2048.0
#define GPUI_WINDOWS_TEXT_MAX_SCENE_HEIGHT 128.0
#define GPUI_WINDOWS_TEXT_MAX_MASK_DIMENSION 2048
#define GPUI_WINDOWS_TEXT_MAX_MASK_PIXELS 262144
#define GPUI_WINDOWS_TEXT_MIN_PIXELS_PER_DIP 0.25
#define GPUI_WINDOWS_TEXT_MAX_PIXELS_PER_DIP 8.0

enum gpui_windows_text_status {
  GPUI_WINDOWS_TEXT_OK = 0,
  GPUI_WINDOWS_TEXT_INVALID_ARGUMENT = 1,
  GPUI_WINDOWS_TEXT_INVALID_FONT_SIZE = 2,
  GPUI_WINDOWS_TEXT_INVALID_COORDINATES = 3,
  GPUI_WINDOWS_TEXT_UNSUPPORTED_INPUT = 4,
  GPUI_WINDOWS_TEXT_UNSUPPORTED_COLOR = 5,
  GPUI_WINDOWS_TEXT_UNSUPPORTED_RASTER = 6,
  GPUI_WINDOWS_TEXT_RESOURCE_LIMIT = 7,
  GPUI_WINDOWS_TEXT_INPUT_TOO_LARGE = 8,
  GPUI_WINDOWS_TEXT_BUFFER_TOO_SMALL = 9,
  GPUI_WINDOWS_TEXT_NATIVE_FAILURE = 10,
  GPUI_WINDOWS_TEXT_INVALID_NATIVE_OUTPUT = 11,
  GPUI_WINDOWS_TEXT_UNSUPPORTED_GLYPH = 12,
  GPUI_WINDOWS_TEXT_INVALID_FONT_FAMILY = 13,
  GPUI_WINDOWS_TEXT_UNSUPPORTED_PLATFORM = 14,
  GPUI_WINDOWS_TEXT_INVALID_SCALE = 15
};

typedef struct gpui_windows_text_mask {
  uint8_t *pixels;
  int32_t width, height;
  double left, top, right, bottom;
  double u0, v0, u1, v1;
  int32_t unknown_glyph_count;
} GpuiWindowsTextMask;

#ifdef __cplusplus
extern "C" {
#endif

int32_t gpui_windows_text_measure_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double *output, int32_t output_capacity);
int32_t gpui_windows_text_hit_test_v1(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double font_size_px,
    double x_px, double y_px, double *output, int32_t output_capacity);
/* Raster ABI v2 receives physical pixels per DIP. Returned mask dimensions and
 * budgets are physical pixels; normalized UVs derive from physical tile bounds
 * while returned quad bounds stay DIPs. */
int32_t gpui_windows_text_raster_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double pixels_per_dip,
    double font_size_px,
    double text_origin_x, double text_origin_y,
    double clip_x, double clip_y, double clip_width, double clip_height,
    int32_t pixel_budget, GpuiWindowsTextMask *output);
void gpui_windows_text_mask_release_v1(GpuiWindowsTextMask *mask);
int32_t gpui_windows_text_admit_scene_run_v2(
    int32_t abi, const uint8_t *text, int32_t text_length,
    const uint8_t *family, int32_t family_length, double pixels_per_dip,
    double font_size_px,
    double origin_x, double origin_y, double clip_x, double clip_y,
    double clip_width, double clip_height);
int32_t gpui_windows_text_test_supported_v1(void);
int32_t gpui_windows_text_test_color_policy_v1(void);
/* Native qualification probe: width, height, nonzero/partial pixel counts,
 * top/bottom occupied rows, and top/bottom half pixel counts. */
int32_t gpui_windows_text_test_raster_v1(double *output, int32_t capacity);
/* Density probe: 1x/2x logical bounds, physical masks/coverage, invalid-scale
 * statuses, and the physical-pixel budget boundary. */
int32_t gpui_windows_text_test_density_v2(double *output, int32_t capacity);

#ifdef __cplusplus
}
#endif

#endif
