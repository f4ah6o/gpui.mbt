#ifndef GPUI_UBUNTU_BACKEND_H
#define GPUI_UBUNTU_BACKEND_H
#include <stdint.h>
/* Private, versioned ABI. All buffers are borrowed only for the call. Tokens
 * are monotonic integers resolved internally, never pointers. Owner-thread
 * only. Event buffer: kind, window, sequence, scale, width, height, x, y,
 * detail, mods. Frame: viewport x/y/w/h/scale, followed by 19 doubles per quad:
 * bounds(4), RGBA(4), affine(6), opacity, intersected clip(4).
 */
#define GPUI_UBUNTU_ABI 1
#define GPUI_QUAD_STRIDE 19
enum gpui_status {
  GPUI_OK,
  GPUI_UNSUPPORTED,
  GPUI_NATIVE,
  GPUI_INVALID,
  GPUI_STALE,
  GPUI_BUSY,
  GPUI_STOPPING,
  GPUI_WRONG_THREAD,
  GPUI_RESOURCE,
  GPUI_SURFACE_LOST,
  GPUI_DEVICE_LOST
};
int32_t gpui_start(int32_t abi);
int32_t gpui_stop(int32_t host);
int32_t gpui_wake(int32_t host);
int32_t gpui_exit(int32_t host);
int32_t gpui_state(int32_t host);
int32_t gpui_create(int32_t host, int32_t width, int32_t height,
                    const uint8_t *title, int32_t length);
int32_t gpui_close(int32_t host, int32_t window);
int32_t gpui_destroy(int32_t host, int32_t window);
int32_t gpui_title(int32_t host, int32_t window, const uint8_t *title,
                   int32_t length);
int32_t gpui_size(int32_t host, int32_t window, int32_t width, int32_t height);
int32_t gpui_metrics(int32_t host, int32_t window, double *metrics);
int32_t gpui_dispatch(int32_t host, int32_t timeout_ms);
int32_t gpui_next(int32_t host, double *event);
int32_t gpui_present(int32_t host, int32_t window, const double *data,
                     int32_t length);
int32_t gpui_recover(int32_t host, int32_t window);
int32_t gpui_capability(int32_t host, int32_t capability);
int32_t gpui_read_clipboard(int32_t host);
int32_t gpui_clipboard_length(int32_t host);
int32_t gpui_clipboard_copy(int32_t host, uint8_t *bytes, int32_t capacity);
int32_t gpui_write_clipboard(int32_t host, const uint8_t *bytes,
                             int32_t length);
int32_t gpui_set_cursor(int32_t host, int32_t cursor);
#endif
