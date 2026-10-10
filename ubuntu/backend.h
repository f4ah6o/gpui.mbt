#ifndef GPUI_UBUNTU_BACKEND_H
#define GPUI_UBUNTU_BACKEND_H
#include <stdint.h>
/* Private, versioned ABI. All buffers are borrowed only for the call. Tokens
 * are monotonic integers resolved internally, never pointers. Owner-thread
 * only. Event buffer: kind, window, sequence, scale, width, height, x, y,
 * detail, mods. Key tags 11/12 use slot 6 for the Unicode scalar and
 * slot 7 for repeat (press: exact 0/1, release: 0). Text tag 13 uses zero
 * slots 6/7. Physical presses are 0; client repeats are 1, with no fake
 * release. Frame: viewport x/y/w/h/scale, followed by 19 doubles per quad:
 * bounds(4), RGBA(4), affine(6), opacity, intersected clip(4).
 */
#define GPUI_UBUNTU_ABI 1
#define GPUI_QUAD_STRIDE 19
#define GPUI_MIXED_FRAME_ABI 2
#define GPUI_MIXED_STRIDE 23
#define GPUI_ORIGIN_FRAME_ABI 3
#define GPUI_ORIGIN_STRIDE 25
#define GPUI_MAX_ITEMS 100000
#define GPUI_MAX_TEXT_ITEMS 256
#define GPUI_MAX_FRAME_TEXT_BYTES (1024 * 1024)
#define GPUI_MAX_FRAME_MASK_BYTES (16 * 1024 * 1024)
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
/* Side-effect-free owner/lifetime check for UI-thread adapters. */
int32_t gpui_owner_thread_check(int32_t host);
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
/* Private copied direct-keyboard text ingress. `event` must be non-null and
 * have at least 10 doubles. Negative capacities, or NULL text with a positive
 * capacity, are invalid. NULL text with zero capacity admits non-text records;
 * a text record then returns Resource without consuming it. Text tag 13 stores
 * its 1..128 UTF-8 byte length in slot 8; only those bytes are copied (no NUL).
 * Invalid/insufficient buffers leave both outputs and the head untouched.
 * v1 next rejects active direct mode or any queued direct key/text record,
 * even after disarm, without consuming any record. */
#define GPUI_DIRECT_TEXT_ABI 2
#define GPUI_DIRECT_TEXT_MAX_BYTES 128
#define GPUI_DIRECT_KEY_CAPACITY 1024
int32_t gpui_next_v2(int32_t abi, int32_t host, double *event,
                     int32_t event_capacity, uint8_t *text,
                     int32_t text_capacity);
/* An ever-armed host with an exhausted epoch cannot fall back to editor key
 * delivery: next v1/v2 report Resource and recovery requires a fresh host. */
int32_t gpui_direct_keyboard_text_mode(int32_t host, int32_t window,
                                      int32_t enabled);
/* Positive nonwrapping epoch for a focused active target, negative status
 * otherwise. Active is 0/1 or negative status. No native handle is returned. */
int32_t gpui_direct_keyboard_text_epoch(int32_t host, int32_t window);
int32_t gpui_direct_keyboard_text_active(int32_t host);
/* Experimental, opt-in text-input-v1 editor ABI. One host-owned text target.
 * UTF8 input is borrowed only for the call and copied before returning.
 * The committed document is bounded to 4096 bytes, cannot contain NUL, and
 * cursor/anchor must be scalar boundaries. Rectangles are surface-logical
 * signed integers (never multiplied by output scale), with positive extent.
 * Begin/update/cancel return positive nonwrapping epoch or negative status.
 * An external update/cancel fences by deactivate -> leave -> activate; callers
 * must wait for Entered before considering the replacement epoch ready. */
#define GPUI_EDITOR_ABI 3
#define GPUI_IME_MAX_BYTES 4096
#define GPUI_IME_MAX_STYLES 64
#define GPUI_EDITOR_EVENT_FIELDS (25 + 3 * GPUI_IME_MAX_STYLES)
#define GPUI_EDITOR_MAX_PAYLOAD (2 * GPUI_IME_MAX_BYTES)
#define GPUI_IME_QUEUE_BYTES (1024 * 1024)
int32_t gpui_text_session_begin(int32_t host, int32_t window,
    const uint8_t *text, int32_t length, int32_t cursor, int32_t anchor,
    int32_t x, int32_t y, int32_t width, int32_t height);
int32_t gpui_text_session_update(int32_t host, int32_t window, int32_t epoch,
    const uint8_t *text, int32_t length, int32_t cursor, int32_t anchor,
    int32_t x, int32_t y, int32_t width, int32_t height,
    int32_t external_edit);
int32_t gpui_text_session_cancel(int32_t host, int32_t window, int32_t epoch);
int32_t gpui_text_session_end(int32_t host, int32_t window, int32_t epoch);
/* Explicit candidate/input panel request; popup timing remains compositor/IME
 * owned and is not qualified by transport acceptance. */
int32_t gpui_text_session_panel(int32_t host, int32_t window, int32_t epoch,
    int32_t visible);
/* One ordered queue. Kinds 20 preedit, 21 atomic commit, 22 entered, 23 left,
 * 24/25 forwarded keys. Ordinary ABI2 fields retain their existing meanings.
 * Editor records canonicalize slots4/5 and unused key fields to zero.
 * Editor slots: epoch10, seat11, proxy-generation12, issued serial13,
 * text-length14, fallback-length15, preedit-cursor-present16/index17,
 * deletion-present18/index19/length20, postinsert-position-present21,
 * signed-index22/signed-anchor23, style-count24, then index/length/style
 * triples. UTF8 payload is exact text bytes followed by fallback bytes, no
 * NUL. Zero length commit remains meaningful. No serial deduplication.
 * All invalid/insufficient outputs leave queue and both outputs unchanged.
 * ABI1/2 readers reject an editor head without consuming it. */
int32_t gpui_next_editor(int32_t abi, int32_t host, double *event,
    int32_t event_capacity, uint8_t *text, int32_t text_capacity);
int32_t gpui_present(int32_t host, int32_t window, const double *data,
                     int32_t length);
/* v2 records: kind(0=quad,1=text), the same19 common fields as v1,
 * then UTF8 blob offset/length/font_size. Quad text fields are zero. Both
 * buffers are borrowed for this synchronous call; no pointers are retained. */
int32_t gpui_present_v2(int32_t abi, int32_t host, int32_t window,
                        const double *data, int32_t length,
                        const uint8_t *text, int32_t text_length);
/* ABI3 keeps all23 existing fields and appends independent origin_x/y.
 * Kinds0quad/1legacyText require zero origin fields; kind2 is a plain run
 * clipped to common local bounds, with independent item-local text origin. */
int32_t gpui_present_v3(int32_t abi, int32_t host, int32_t window,
                        const double *data, int32_t length,
                        const uint8_t *text, int32_t text_length);
/* Opt-in GPUI_NATIVE_E2E capture of the last completed native frame. */
int32_t gpui_test_frame_metrics_v1(int32_t host, int32_t window,
                                   double *output);
int32_t gpui_test_frame_copy_v1(int32_t host, int32_t window,
                                uint8_t *output, int32_t capacity);
int32_t gpui_recover(int32_t host, int32_t window);
int32_t gpui_capability(int32_t host, int32_t capability);
int32_t gpui_read_clipboard(int32_t host);
int32_t gpui_clipboard_length(int32_t host);
int32_t gpui_clipboard_copy(int32_t host, uint8_t *bytes, int32_t capacity);
int32_t gpui_write_clipboard(int32_t host, const uint8_t *bytes,
                             int32_t length);
int32_t gpui_set_cursor(int32_t host, int32_t cursor);
#endif
