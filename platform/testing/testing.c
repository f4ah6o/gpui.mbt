#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

#define GPUI_TEST_MAX_PIXELS (16 * 1024 * 1024)
#define GPUI_TEST_MAX_PATH_BYTES 4096

static FILE *open_utf8_path(const char *path) {
#ifdef _WIN32
  int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1,
                                     NULL, 0);
  if (required <= 0 || required > GPUI_TEST_MAX_PATH_BYTES)
    return NULL;
  wchar_t *wide = malloc((size_t)required * sizeof(*wide));
  if (!wide)
    return NULL;
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide,
                           required)) {
    free(wide);
    return NULL;
  }
  FILE *file = _wfopen(wide, L"wb");
  free(wide);
  return file;
#else
  return fopen(path, "wb");
#endif
}

/* Status: 1 invalid arguments, 2 I/O/conversion failure, 3 resource limit. */
int32_t gpui_test_write_ppm_v1(const uint8_t *path, int32_t path_length,
                               const uint8_t *rgba, int32_t rgba_length,
                               int32_t width, int32_t height) {
  if (!path || path_length <= 0 || path_length > GPUI_TEST_MAX_PATH_BYTES ||
      !rgba || width <= 0 || height <= 0)
    return 1;
  int64_t pixels = (int64_t)width * height;
  if (pixels > GPUI_TEST_MAX_PIXELS || pixels * 4 != rgba_length)
    return 3;
  if (memchr(path, 0, (size_t)path_length))
    return 1;
  char *path_string = malloc((size_t)path_length + 1);
  if (!path_string)
    return 3;
  memcpy(path_string, path, (size_t)path_length);
  path_string[path_length] = '\0';
  FILE *file = open_utf8_path(path_string);
  free(path_string);
  if (!file)
    return 2;
  int failed = fprintf(file, "P6\n%d %d\n255\n", width, height) < 0;
  size_t row_bytes = (size_t)width * 3;
  uint8_t *row = failed ? NULL : malloc(row_bytes);
  if (!failed && !row)
    failed = 1;
  for (int32_t y = 0; y < height && !failed; ++y) {
    const uint8_t *source = rgba + (size_t)y * (size_t)width * 4;
    for (int32_t x = 0; x < width; ++x) {
      row[(size_t)x * 3] = source[(size_t)x * 4];
      row[(size_t)x * 3 + 1] = source[(size_t)x * 4 + 1];
      row[(size_t)x * 3 + 2] = source[(size_t)x * 4 + 2];
    }
    failed = fwrite(row, 1, row_bytes, file) != row_bytes;
  }
  free(row);
  if (fclose(file) != 0)
    failed = 1;
  return failed ? 2 : 0;
}
