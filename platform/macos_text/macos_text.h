#ifndef GPUI_MACOS_TEXT_H
#define GPUI_MACOS_TEXT_H
#include <stdint.h>

typedef struct {
  uint8_t *pixels;
  int32_t width, height, stride;
  double left, top;
} GpuiMacTextMask;

int32_t gpui_macos_text_require_raster_v1(int32_t abi);
int32_t gpui_macos_text_measure_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, double *out, int32_t cap);
int32_t gpui_macos_text_hit_test_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, double x, double y,
  double *out, int32_t cap);
int32_t gpui_macos_text_admit_v1(int32_t abi, const uint8_t *text, int32_t text_len,
  double size, double x, double y, double clip_x, double clip_y,
  double clip_width, double clip_height);
int32_t gpui_macos_text_raster_v1(const uint8_t *text, int32_t text_len, double size,
  double scale, GpuiMacTextMask *out);
void gpui_macos_text_raster_free(GpuiMacTextMask *mask);
int32_t gpui_macos_text_fonts_json_v1(const uint8_t *text, int32_t text_len,
  const uint8_t *family, int32_t family_len, double size, uint8_t *out, int32_t cap);

#endif
