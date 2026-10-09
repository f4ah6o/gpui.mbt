#ifndef GPUI_MACOS_TEXT_H
#define GPUI_MACOS_TEXT_H

#include <stdint.h>

typedef struct {
  uint8_t *pixels;
  int32_t width;
  int32_t height;
  int32_t stride;
  double left;
  double top;
} GpuiMacosTextMask;

int32_t gpui_macos_text_require_raster_v1(int32_t abi);
int32_t gpui_macos_text_measure_v1(int32_t abi, const uint8_t *text,
                                  int32_t text_length,
                                  const uint8_t *font_family,
                                  int32_t font_family_length,
                                  double font_size_px, double *output,
                                  int32_t output_capacity);
int32_t gpui_macos_text_raster_v1(const uint8_t *text, int32_t text_length,
                                  double font_size_px, double scale,
                                  GpuiMacosTextMask *output);
void gpui_macos_text_raster_free(GpuiMacosTextMask *mask);

#endif
