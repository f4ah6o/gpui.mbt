#ifndef GPUI_WINDOWS_BACKEND_H
#define GPUI_WINDOWS_BACKEND_H

#include <stdint.h>

/* Private ABI shared only by windows/backend.mbt and backend.c. Event fields
 * are kind, window, sequence, scale, logical width/height, x/y, detail, mods.
 * Legacy frames use viewport x/y/w/h/scale followed by 19 doubles per quad.
 * Private ABI2 mixed frames use 25-double records and a borrowed UTF-8
 * sidecar; bounded text runs render as Segoe UI grayscale masks. */
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
/* Experimental private Win32 IMM32 editor-session ingress. The typed reader
 * pops either platform or text records from the same FIFO. */
int32_t gpui_windows_session_begin(int32_t host, int32_t window,
                                   int32_t owner_generation,
                                   const uint8_t *text, int32_t text_length,
                                   int32_t anchor_utf16, int32_t head_utf16,
                                   double x, double y, double width,
                                   double height);
int32_t gpui_windows_session_update(int32_t host, int32_t window,
                                    int32_t epoch,
                                    int32_t owner_generation,
                                    const uint8_t *text, int32_t text_length,
                                    int32_t anchor_utf16, int32_t head_utf16,
                                    double x, double y, double width,
                                    double height, int32_t external_edit);
int32_t gpui_windows_session_cancel(int32_t host, int32_t window,
                                    int32_t epoch,
                                    int32_t owner_generation);
int32_t gpui_windows_session_end(int32_t host, int32_t window,
                                 int32_t epoch,
                                 int32_t owner_generation);
/* Exact native IMM32 owner check; false after focus loss even if focus returns. */
int32_t gpui_windows_session_is_current(int32_t host, int32_t window,
                                        int32_t epoch,
                                        int32_t owner_generation);
int32_t gpui_windows_next_editor(int32_t host, double *event_data,
                                 uint8_t *payload, int32_t payload_capacity);
/* Synchronous owner-thread native focus query (1=true, 0=false, negative error). */
int32_t gpui_windows_window_has_keyboard_focus(int32_t host, int32_t window);
int32_t gpui_windows_present(int32_t host, int32_t window,
                             const double *frame_data, int32_t length);
int32_t gpui_windows_present_text(int32_t abi, int32_t host, int32_t window,
                                  const double *frame_data, int32_t length,
                                  const uint8_t *text, int32_t text_length);
int32_t gpui_windows_recover(int32_t host, int32_t window);
int32_t gpui_windows_cursor(int32_t host, int32_t cursor);
int32_t gpui_windows_clipboard_read(int32_t host, uint8_t *output,
                                    int32_t capacity);
int32_t gpui_windows_clipboard_write(int32_t host, const uint8_t *text,
                                     int32_t length);
int32_t gpui_windows_readback(int32_t host, int32_t window, double *rgba);
/* Opt-in GPUI_NATIVE_E2E capture of the last completed native frame. */
int32_t gpui_windows_frame_metrics_v1(int32_t host, int32_t window,
                                      double *output);
int32_t gpui_windows_frame_copy_v1(int32_t host, int32_t window,
                                   uint8_t *output, int32_t capacity);
/* CI-only scan of a logical region in the most recent staged GPU frame. */
int32_t gpui_windows_test_readback_region(int32_t host, int32_t window,
                                          double x, double y, double width,
                                          double height,
                                          const double *expected_rgba,
                                          double *output);
/* CI-only deterministic 2x text presentation. Output contains 1x/2x adapter
 * mask dimensions, the production-staged 2x dimensions, and GPU readback
 * coverage counts. */
int32_t gpui_windows_test_text_density2(int32_t host, int32_t window,
                                        double *output);
/* Counts actual GPU clear/draw/present calls; used to qualify atomic reject. */
int32_t gpui_windows_test_renderer_counts(int32_t host, int32_t window,
                                          int64_t *counts);
/* CI-only boundary probe; returns OK only when a worker is rejected as wrong-thread. */
int32_t gpui_windows_test_wrong_thread(int32_t host, int32_t window);
/* CI-only check of the initial CreateWindowExW caption via GetWindowTextW. */
int32_t gpui_windows_test_window_title(int32_t host, int32_t window,
                                      const uint8_t *title, int32_t length);
/* CI-only race probe; a worker posts wakes while the owner stops the host. */
int32_t gpui_windows_test_wake_stop_race(int32_t host);
/* CI-only pure-data probe for malformed, unterminated UTF-16 clipboard data. */
int32_t gpui_windows_test_clipboard_validation(void);
/* Opt-in native E2E against the separately compiled Win32 clipboard fixture. */
int32_t gpui_windows_test_clipboard_fixture_read(int32_t host);
int32_t gpui_windows_test_clipboard_fixture_write(int32_t host);
int32_t gpui_windows_test_clipboard_fixture_read_line(int32_t host);
int32_t gpui_windows_test_clipboard_fixture_lock_start(int32_t host);
int32_t gpui_windows_test_clipboard_fixture_lock_stop(int32_t host);
int32_t gpui_windows_test_clipboard_fixture_expiry(int32_t host);
/* CI-only direct-message probes: size phases are minimize, zero-size, restore. */
int32_t gpui_windows_test_size_message(int32_t host, int32_t window,
                                       int32_t phase);
/* diagnostics has ten int32 fields on failure: stage, expected/actual button
 * masks, expected capture (-1 means unchecked), actual capture (0 none, 1
 * this window, 2 another), message, wParam words, capture-change count, and
 * last new-capture target (0 none, 1 this window, 2 another). */
int32_t gpui_windows_test_mouse_capture(int32_t host, int32_t window,
                                        int32_t *diagnostics);
int32_t gpui_windows_test_mouse_arm_destroy(int32_t host, int32_t window);
int32_t gpui_windows_test_mouse_destroy_reset(int32_t host, int32_t window);
/* CI-only synthetic staging through the production IMM composition helpers. */
int32_t gpui_windows_test_text_session_staging(int32_t *failed_stage);

#endif
