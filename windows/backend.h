#ifndef GPUI_WINDOWS_BACKEND_H
#define GPUI_WINDOWS_BACKEND_H

#include <stdint.h>

/* Private ABI shared only by windows/backend.mbt and backend.c. Event fields
 * are kind, window, sequence, scale, logical width/height, x/y, detail, mods.
 * A frame is viewport x/y/w/h/scale followed by 19 doubles per quad:
 * bounds(4), RGBA(4), affine(6), opacity(1), clip(4). */
#define GPUI_WINDOWS_ABI 1
#define GPUI_WINDOWS_QUAD_STRIDE 19

enum gpui_windows_status {
  GPUI_WINDOWS_OK,
  GPUI_WINDOWS_UNSUPPORTED,
  GPUI_WINDOWS_NATIVE,
  GPUI_WINDOWS_INVALID,
  GPUI_WINDOWS_STALE,
  GPUI_WINDOWS_BUSY,
  GPUI_WINDOWS_STOPPING,
  GPUI_WINDOWS_WRONG_THREAD,
  GPUI_WINDOWS_RESOURCE,
  GPUI_WINDOWS_SURFACE_LOST,
  GPUI_WINDOWS_DEVICE_LOST,
  GPUI_WINDOWS_CONVERSION
};

int32_t gpui_windows_start(int32_t abi_version);
int32_t gpui_windows_stop(int32_t host);
int32_t gpui_windows_state(int32_t host);
int32_t gpui_windows_wake(int32_t host);
int32_t gpui_windows_exit(int32_t host);
int32_t gpui_windows_create(int32_t host, int32_t width, int32_t height,
                            const uint8_t *title, int32_t title_length);
int32_t gpui_windows_close(int32_t host, int32_t window);
int32_t gpui_windows_destroy(int32_t host, int32_t window);
int32_t gpui_windows_title(int32_t host, int32_t window,
                           const uint8_t *title, int32_t title_length);
int32_t gpui_windows_size(int32_t host, int32_t window, int32_t width,
                          int32_t height);
int32_t gpui_windows_metrics(int32_t host, int32_t window, double *metrics);
int32_t gpui_windows_dispatch(int32_t host, int32_t timeout_ms);
int32_t gpui_windows_next(int32_t host, double *event_data);
int32_t gpui_windows_present(int32_t host, int32_t window,
                             const double *frame_data, int32_t length);
int32_t gpui_windows_recover(int32_t host, int32_t window);
int32_t gpui_windows_cursor(int32_t host, int32_t cursor);
int32_t gpui_windows_clipboard_read(int32_t host, uint8_t *output,
                                    int32_t capacity);
int32_t gpui_windows_clipboard_write(int32_t host, const uint8_t *text,
                                     int32_t length);
int32_t gpui_windows_readback(int32_t host, int32_t window, double *rgba);
/* CI-only boundary probe; returns OK only when a worker is rejected as wrong-thread. */
int32_t gpui_windows_test_wrong_thread(int32_t host, int32_t window);
/* CI-only race probe; a worker posts wakes while the owner stops the host. */
int32_t gpui_windows_test_wake_stop_race(int32_t host);
/* CI-only pure-data probe for malformed, unterminated UTF-16 clipboard data. */
int32_t gpui_windows_test_clipboard_validation(void);

#endif
