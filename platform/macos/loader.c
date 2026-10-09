#include "abi.h"
#ifdef __APPLE__
#include <dlfcn.h>
#include <stdlib.h>
#include <pthread.h>
#include <mach-o/dyld.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>
static const GpuiApi *api;
static void *library;
static int load(void) {
  if (!pthread_main_np()) return 18;
  if (api) return 0;
  const char *path = getenv("GPUI_MACOS_LIBRARY");
  char bundled[PATH_MAX];
  if (!path || !*path) {
    uint32_t size = sizeof(bundled);
    if (_NSGetExecutablePath(bundled, &size)) return 14;
    char *slash = strrchr(bundled, '/');
    if (!slash) return 14;
    *slash = '\0';
    size_t used = strlen(bundled);
    if (snprintf(bundled + used, sizeof(bundled)-used, "/../Frameworks/libgpui_macos.dylib") >= (int)(sizeof(bundled)-used)) return 14;
    path = bundled;
  }
  library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!library) return 14;
  const GpuiApi *(*get_api)(void) = dlsym(library, "gpui_macos_api_v1");
  const GpuiApi *candidate = get_api ? get_api() : NULL;
  if (!candidate || candidate->abi_version != 1 || candidate->struct_size != sizeof(GpuiApi)) {
    dlclose(library); library = NULL; return 20;
  }
  api = candidate;
  return 0;
}
int32_t gpui_call(int32_t op, int64_t token, double x, double y, const uint8_t *bytes, int32_t length) {
  int status = load();
  return status ? status : api->call(op, token, x, y, bytes, length);
}
int64_t gpui_integer(int32_t field) { return api && pthread_main_np() ? api->integer(field) : 0; }
double gpui_number(int32_t field) { return api && pthread_main_np() ? api->number(field) : 0; }
int32_t gpui_macos_frame_metrics(int64_t window, double *output) {
  int status = load();
  if (status) return status;
  int32_t (*read)(int64_t, double *) = dlsym(library, "gpui_macos_test_frame_meta_v1");
  return read ? read(window, output) : 9;
}
int32_t gpui_macos_frame_copy(int64_t window, uint8_t *output, int32_t capacity) {
  int status = load();
  if (status) return status;
  int32_t (*read)(int64_t, uint8_t *, int32_t) = dlsym(library, "gpui_macos_test_frame_copy_v1");
  return read ? read(window, output, capacity) : 9;
}
int32_t gpui_macos_test_post_click(int64_t window, double x, double y) {
  int status = load();
  if (status) return status;
  int32_t (*post)(int64_t, double, double) = dlsym(library, "gpui_macos_test_post_click_v1");
  return post ? post(window, x, y) : 9;
}
int32_t gpui_macos_test_post_escape(int64_t window) {
  int status = load();
  if (status) return status;
  int32_t (*post)(int64_t) = dlsym(library, "gpui_macos_test_post_escape_v1");
  return post ? post(window) : 9;
}
#else
int32_t gpui_call(int32_t op, int64_t token, double x, double y, const uint8_t *bytes, int32_t length) {
  (void)op; (void)token; (void)x; (void)y; (void)bytes; (void)length; return 9;
}
int64_t gpui_integer(int32_t field) { (void)field; return 0; }
double gpui_number(int32_t field) { (void)field; return 0; }
int32_t gpui_macos_frame_metrics(int64_t window, double *output) { (void)window; (void)output; return 9; }
int32_t gpui_macos_frame_copy(int64_t window, uint8_t *output, int32_t capacity) { (void)window; (void)output; (void)capacity; return 9; }
int32_t gpui_macos_test_post_click(int64_t window, double x, double y) { (void)window; (void)x; (void)y; return 9; }
int32_t gpui_macos_test_post_escape(int64_t window) { (void)window; return 9; }
#endif
