#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wayland-client.h>
#include "../../ubuntu/text-input-v1-client-protocol.h"
/* Protocol requests are mocked, never invoked on the fixture's fake handles.
 * Actual callback/staging/queue/serial logic below is the production code. */
static int calls[256], call_count, sent_serial, sent_cursor, sent_anchor;
static int sent_rectangle[4], destroyed_proxies;
static char sent_document[4097];
static struct zwp_text_input_v1 *new_proxy;
static void call(int operation) { assert(call_count < 256); calls[call_count++] = operation; }
static void mock_activate(struct zwp_text_input_v1 *p, struct wl_seat *s,
                          struct wl_surface *surface) { assert(p && s && surface); call(1); }
static void mock_deactivate(struct zwp_text_input_v1 *p, struct wl_seat *s) { assert(p && s); call(2); }
static void mock_show(struct zwp_text_input_v1 *p) { assert(p); call(3); }
static void mock_hide(struct zwp_text_input_v1 *p) { assert(p); call(4); }
static void mock_surrounding(struct zwp_text_input_v1 *p, const char *text,
                             uint32_t cursor, uint32_t anchor) {
  assert(p); strcpy(sent_document, text); sent_cursor = (int)cursor;
  sent_anchor = (int)anchor; call(5);
}
static void mock_rectangle(struct zwp_text_input_v1 *p, int32_t x, int32_t y,
                           int32_t w, int32_t h) {
  assert(p); sent_rectangle[0] = x; sent_rectangle[1] = y;
  sent_rectangle[2] = w; sent_rectangle[3] = h; call(6);
}
static void mock_content(struct zwp_text_input_v1 *p, uint32_t hint, uint32_t purpose) {
  assert(p); assert(!hint && !purpose); call(7);
}
static void mock_commit(struct zwp_text_input_v1 *p, uint32_t serial) { assert(p); sent_serial = (int)serial; call(8); }
static void mock_destroy(struct zwp_text_input_v1 *p) { assert(p); ++destroyed_proxies; call(9); }
static struct zwp_text_input_v1 *mock_create(struct zwp_text_input_manager_v1 *p) { assert(p); call(10); return new_proxy; }
static int mock_listener(struct zwp_text_input_v1 *p,
                          const struct zwp_text_input_v1_listener *listener,
                          void *data) { assert(p && listener && data); call(11); return 0; }
static void mock_manager_destroy(struct zwp_text_input_manager_v1 *p) { assert(p); call(12); }
static void mock_keyboard_release(struct wl_keyboard *p) { assert(p); call(13); }
static void mock_keyboard_destroy(struct wl_keyboard *p) { assert(p); call(14); }
static void mock_seat_destroy(struct wl_seat *p) { assert(p); call(15); }
static void mock_surface_destroy(struct wl_surface *p) { assert(p); call(16); }
#define zwp_text_input_v1_activate mock_activate
#define zwp_text_input_v1_deactivate mock_deactivate
#define zwp_text_input_v1_show_input_panel mock_show
#define zwp_text_input_v1_hide_input_panel mock_hide
#define zwp_text_input_v1_set_surrounding_text mock_surrounding
#define zwp_text_input_v1_set_cursor_rectangle mock_rectangle
#define zwp_text_input_v1_set_content_type mock_content
#define zwp_text_input_v1_commit_state mock_commit
#define zwp_text_input_v1_destroy mock_destroy
#define zwp_text_input_manager_v1_create_text_input mock_create
#define zwp_text_input_v1_add_listener mock_listener
#define zwp_text_input_manager_v1_destroy mock_manager_destroy
#define wl_keyboard_release mock_keyboard_release
#define wl_keyboard_destroy mock_keyboard_destroy
#define wl_seat_destroy mock_seat_destroy
#define wl_surface_destroy mock_surface_destroy
#include "../../ubuntu/backend.c"

static struct host *fixture(void) {
  struct host *h = calloc(1, sizeof(*h)); assert(h);
  h->token = 741; h->window = 51; h->owner = pthread_self();
  h->width = 640; h->height = 480; h->scale = 2; h->wake_fd = -1;
  h->seat = (struct wl_seat *)(uintptr_t)101;
  h->keyboard = (struct wl_keyboard *)(uintptr_t)102;
  h->surface = (struct wl_surface *)(uintptr_t)103;
  h->seat_name = 117; h->seat_version = 4; h->keyboard_focus_current = 1;
  h->ime.manager = (struct zwp_text_input_manager_v1 *)(uintptr_t)104;
  h->ime.manager_name = 118;
  new_proxy = (struct zwp_text_input_v1 *)(uintptr_t)105;
  call_count = destroyed_proxies = 0; sent_serial = 0;
  memset(calls, 0, sizeof(calls)); active = h;
  return h;
}
static void finish(struct host *h) {
  for (int i = 0; i < QUEUE_CAPACITY; ++i) ime_free_slot(h, i);
  assert(h->ime_queue_bytes == 0); active = NULL; free(h);
}
static int begin(struct host *h) {
  const uint8_t doc[] = "A日本Z";
  int epoch = gpui_text_session_begin(h->token, h->window, doc, 8, 7, 1, -3, 17, 2, 23);
  assert(epoch == 1); assert(h->ime.phase == IME_ACTIVATING);
  assert(sent_serial == 1 && h->ime.serial_floor == 1);
  assert(sent_cursor == 7 && sent_anchor == 1 && !strcmp(sent_document, "A日本Z"));
  /* Logical x/y/w/h are unchanged despite scale2. */
  assert(sent_rectangle[0] == -3 && sent_rectangle[1] == 17 && sent_rectangle[2] == 2 && sent_rectangle[3] == 23);
  assert(calls[2] == 1 && calls[3] == 3);
  ime_enter(h, h->ime.proxy, h->surface);
  assert(h->ime.phase == IME_ACTIVE && h->count == 1);
  return epoch;
}
static int read_editor(struct host *h, double *data, uint8_t *bytes) {
  return gpui_next_editor(3, h->token, data, GPUI_EDITOR_EVENT_FIELDS,
                          bytes, GPUI_EDITOR_MAX_PAYLOAD);
}
static void drain_enter(struct host *h) {
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  assert(read_editor(h, data, bytes) == 1 && data[0] == 22 && data[10] == 1);
  assert(data[4] == 0 && data[5] == 0 && data[9] == 0);
  assert(h->count == 0);
}
static void copies_staging_order_and_shared_serial(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  ime_preedit_styling(h, h->ime.proxy, 0, 6, 5);
  ime_preedit_cursor(h, h->ime.proxy, 3);
  ime_delete_surrounding(h, h->ime.proxy, -6, 6);
  ime_cursor_position(h, h->ime.proxy, -3, -6);
  assert(h->count == 0);
  char preedit[] = "日本", fallback[] = "にほん";
  ime_preedit_string(h, h->ime.proxy, 1, preedit, fallback);
  memset(preedit, 'x', 6); memset(fallback, 'x', 9);
  assert(h->count == 1 && h->ime.stage.delete_present);
  char commit[] = "日本";
  ime_commit_string(h, h->ime.proxy, 1, commit); memset(commit, 'y', 6);
  ime_commit_string(h, h->ime.proxy, 1, "");
  assert(h->count == 3);
  /* Later issued state must not reject an earlier still-valid serial. */
  assert(gpui_text_session_update(h->token, h->window, epoch,
      (const uint8_t *)"A日本Z", 8, 7, 1, 0, 1, 1, 1, 0) == epoch);
  assert(h->ime.latest_serial == 2 && h->ime.serial_floor == 1);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 20 && data[13] == 1);
  assert(data[14] == 6 && data[15] == 9 && data[16] == 1 && data[17] == 3 && data[24] == 1);
  assert(data[25] == 0 && data[26] == 6 && data[27] == 5);
  assert(!memcmp(bytes, "日本にほん", 15));
  assert(read_editor(h, data, bytes) == 1 && data[0] == 21 && data[14] == 6);
  assert(data[18] == 1 && data[19] == -6 && data[20] == 6 && data[21] == 1 && data[22] == -3 && data[23] == -6);
  assert(!memcmp(bytes, "日本", 6));
  assert(read_editor(h, data, bytes) == 1 && data[0] == 21 && data[14] == 0 && data[18] == 0);
  assert(h->ime_queue_bytes == 0); finish(h);
}
static void independent_staging_survives_stale_peer_event(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  ime_delete_surrounding(h, h->ime.proxy, -1, 1);
  ime_cursor_position(h, h->ime.proxy, -3, -6);
  ime_preedit_cursor(h, h->ime.proxy, 0);
  ime_preedit_string(h, h->ime.proxy, 0, "stale", "");
  assert(!h->ime.stage.cursor_present && h->ime.stage.delete_present && h->ime.stage.position_present);
  ime_commit_string(h, h->ime.proxy, 1, "");
  assert(read_editor(h, data, bytes) == 1 && data[18] == 1 && data[19] == -1 && data[21] == 1 && data[22] == -3 && data[23] == -6);
  ime_preedit_cursor(h, h->ime.proxy, 3);
  ime_preedit_styling(h, h->ime.proxy, 0, 3, 5);
  ime_delete_surrounding(h, h->ime.proxy, -1, 1);
  ime_commit_string(h, h->ime.proxy, 0, "stale");
  assert(!h->ime.stage.delete_present && h->ime.stage.cursor_present && h->ime.stage.style_count == 1);
  ime_preedit_string(h, h->ime.proxy, 1, "日", "fallback");
  assert(read_editor(h, data, bytes) == 1 && data[0] == 20 && data[17] == 3 && data[24] == 1);
  finish(h);
}
static void buffers_and_legacy_are_atomic(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  ime_preedit_string(h, h->ime.proxy, 1, "日本", "にほん");
  double data[GPUI_EDITOR_EVENT_FIELDS], before[GPUI_EDITOR_EVENT_FIELDS];
  uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD], prior[GPUI_EDITOR_MAX_PAYLOAD];
  memset(data, 0xa5, sizeof(data)); memcpy(before, data, sizeof(data));
  memset(bytes, 0x67, sizeof(bytes)); memcpy(prior, bytes, sizeof(bytes));
  assert(gpui_next(h->token, data) == -GPUI_UNSUPPORTED);
  assert(gpui_next_v2(2, h->token, data, 10, bytes, sizeof(bytes)) == -GPUI_UNSUPPORTED);
  assert(h->count == 1 && !memcmp(data, before, sizeof(data)) && !memcmp(bytes, prior, sizeof(bytes)));
  assert(gpui_next_editor(3, h->token, data, GPUI_EDITOR_EVENT_FIELDS, bytes, 14) == -GPUI_RESOURCE);
  assert(gpui_next_editor(3, h->token, data, GPUI_EDITOR_EVENT_FIELDS - 1, bytes, sizeof(bytes)) == -GPUI_RESOURCE);
  assert(gpui_next_editor(3, h->token, data, GPUI_EDITOR_EVENT_FIELDS, NULL, 1) == -GPUI_INVALID);
  assert(gpui_next_editor(2, h->token, data, GPUI_EDITOR_EVENT_FIELDS, bytes, sizeof(bytes)) == -GPUI_UNSUPPORTED);
  assert(h->count == 1 && !memcmp(data, before, sizeof(data)) && !memcmp(bytes, prior, sizeof(bytes)));
  h->ime_queue[h->read]->styles[0] = (struct ime_style){1, 1, 5};
  h->ime_queue[h->read]->style_count = 1;
  assert(read_editor(h, data, bytes) == -GPUI_INVALID);
  assert(h->count == 1 && !memcmp(data, before, sizeof(data)) && !memcmp(bytes, prior, sizeof(bytes)));
  h->ime_queue[h->read]->style_count = 0;
  h->ime_queue[h->read]->cursor = 1;
  assert(read_editor(h, data, bytes) == -GPUI_INVALID && h->count == 1);
  h->ime_queue[h->read]->cursor = 0;
  h->queue[h->read][2] = NAN;
  assert(read_editor(h, data, bytes) == -GPUI_INVALID && h->count == 1);
  h->queue[h->read][2] = 2;
  assert(read_editor(h, data, bytes) == 1); finish(h);
}
static void serial_epoch_and_reactivation_fences(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  ime_commit_string(h, h->ime.proxy, 0, "bad");
  ime_commit_string(h, h->ime.proxy, 2, "unissued"); assert(h->count == 0);
  ime_preedit_string(h, h->ime.proxy, 1, "old", "fallback");
  int prior_calls = call_count;
  int replacement = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(replacement == 2 && h->ime.phase == IME_DEACTIVATING);
  assert(calls[prior_calls] == 2 && calls[prior_calls + 1] == 4);
  assert(gpui_text_session_update(h->token, h->window, 1,
      (const uint8_t *)"", 0, 0, 0, 0, 0, 1, 1, 0) == -GPUI_STALE);
  ime_commit_string(h, h->ime.proxy, 1, "stale");
  ime_enter(h, h->ime.proxy, h->surface); assert(h->ime.phase == IME_DEACTIVATING);
  assert(call_count == prior_calls + 2);
  /* Reader discards old preedit only when the following Left is admitted. */
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == 1);
  assert(h->count == 0);
  ime_leave(h, h->ime.proxy);
  assert(h->ime.phase == IME_ACTIVATING && h->ime.wire_epoch == 2 && h->ime.serial_floor == 2);
  assert(calls[prior_calls + 2] == 1);
  ime_enter(h, h->ime.proxy, h->surface);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 22 && data[10] == 2);
  ime_commit_string(h, h->ime.proxy, 1, "old-serial"); assert(h->count == 0);
  ime_commit_string(h, h->ime.proxy, 2, "new");
  assert(read_editor(h, data, bytes) == 1 && data[0] == 21 && data[10] == 2);
  /* End + immediate begin must wait for old leave. */
  assert(gpui_text_session_end(h->token, h->window, 2) == 0);
  prior_calls = call_count;
  int next = gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 2, 2, 1, 1);
  assert(next > 2 && call_count == prior_calls && h->ime.phase == IME_DEACTIVATING);
  ime_leave(h, h->ime.proxy); assert(h->ime.phase == IME_ACTIVATING && h->ime.wire_epoch == next);
  ime_enter(h, h->ime.proxy, h->surface);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == 2);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 22 && data[10] == next);
  finish(h);
}
static void lifecycle_and_removed_proxies(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  ime_preedit_cursor(h, h->ime.proxy, 0);
  keyboard_leave(h, h->keyboard, 99, h->surface);
  assert(!h->ime.stage.cursor_present && !h->ime.requested);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 6 && data[8] == 0);
  ime_leave(h, h->ime.proxy);
  keyboard_enter(h, h->keyboard, 100, h->surface, NULL);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 6);
  int epoch = gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1); assert(epoch > 1);
  ime_enter(h, h->ime.proxy, h->surface); assert(read_editor(h, data, bytes) == 1);
  struct zwp_text_input_v1 *old = h->ime.proxy;
  h->scale = 1; /* No output transition in this seat-removal fixture. */
  global_remove(h, NULL, h->seat_name);
  assert(h->ime.proxy == NULL && !h->ime.requested && !h->seat && !h->keyboard);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 6);
  h->seat = (struct wl_seat *)(uintptr_t)201; h->keyboard = (struct wl_keyboard *)(uintptr_t)202;
  h->seat_name = 217; h->keyboard_focus_current = 1;
  new_proxy = (struct zwp_text_input_v1 *)(uintptr_t)205;
  epoch = gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1); assert(epoch > 1);
  ime_enter(h, h->ime.proxy, h->surface); assert(read_editor(h, data, bytes) == 1 && data[12] == 2 && data[11] == 217);
  ime_preedit_cursor(h, h->ime.proxy, 0);
  ime_commit_string(h, old, (uint32_t)h->ime.latest_serial, "removed");
  ime_leave(h, old); assert(h->ime.stage.cursor_present && h->ime.phase == IME_ACTIVE && h->count == 0);
  finish(h);
}
static void destroy_and_manager_removal_revoke_owned_payloads(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  ime_preedit_string(h, h->ime.proxy, 1, "日本", "にほん");
  ime_commit_string(h, h->ime.proxy, 1, "日本");
  ime_preedit_cursor(h, h->ime.proxy, 0);
  assert(h->ime_queue_bytes == 2 * sizeof(struct ime_payload));
  assert(gpui_destroy(h->token, h->window) == GPUI_OK);
  assert(h->window == 0 && h->surface == NULL && !h->ime.requested && !h->ime.stage.cursor_present);
  assert(h->count == 2 && h->ime_queue_bytes == sizeof(struct ime_payload));
  ime_commit_string(h, h->ime.proxy, 1, "destroyed"); assert(h->count == 2);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 4);
  assert(!h->count && !h->ime_queue_bytes);
  finish(h);
  h = fixture(); begin(h); drain_enter(h); h->scale = 1;
  struct zwp_text_input_v1 *old = h->ime.proxy;
  ime_preedit_cursor(h, old, 0);
  global_remove(h, NULL, h->ime.manager_name);
  assert(!h->ime.manager && !h->ime.manager_name && !h->ime.proxy && !h->ime.requested && !h->ime.stage.cursor_present);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && h->ime_queue_bytes == 0);
  assert(gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1) == -GPUI_UNSUPPORTED);
  ime_enter(h, old, h->surface); ime_leave(h, old);
  ime_preedit_string(h, old, 1, "removed", ""); assert(!h->count);
  finish(h);
}
static void destroy_reports_terminal_sequence_exhaustion(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  h->seq = INT_MAX - 1;
  assert(gpui_destroy(h->token, h->window) == GPUI_RESOURCE);
  assert(h->window == 0 && h->surface == NULL && h->error == GPUI_RESOURCE);
  assert(!h->ime.requested && h->count == 1);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[2] == INT_MAX);
  assert(!h->count && !h->ime_queue_bytes);
  finish(h);
}
static void keys_modifiers_and_text_suppression(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  char map[] = "Control\0Mod4\0Shift\0Mod1\0";
  struct wl_array names = {.size = sizeof(map) - 1, .data = map};
  ime_modifiers_map(h, h->ime.proxy, &names);
  h->direct_enabled = 1; h->repeat.armed = 1;
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  assert(h->count == 1 && !h->repeat.armed);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 24 && data[8] == XKB_KEY_a && data[6] == 0 && data[7] == 0);
  assert(h->count == 0);
  assert(gpui_direct_keyboard_text_mode(h->token, h->window, 1) == GPUI_BUSY);
  ime_keysym(h, h->ime.proxy, 1, 0, XKB_KEY_Return, WL_KEYBOARD_KEY_STATE_PRESSED, 5);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 24 && data[8] == XKB_KEY_Return && data[9] == 3 && data[6] == 0 && data[7] == 0);
  assert(h->count == 0); /* no synthetic release */
  ime_keysym(h, h->ime.proxy, 1, 0, XKB_KEY_Return, WL_KEYBOARD_KEY_STATE_RELEASED, 1);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 25 && data[9] == 2);
  finish(h);
}
static void quiescing_and_latched_errors_fail_closed(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  assert(!h->direct_ever_enabled && h->ime.ever_enabled);
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  quiesce_host(h); ime_leave(h, h->ime.proxy);
  assert(h->state == 1 && h->ime.phase == IME_INACTIVE);
  int count = h->count;
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_a);
  assert(h->count == count);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23);
  assert(h->count == 0); finish(h);
  h = fixture(); begin(h); drain_enter(h);
  ime_preedit_string(h, h->ime.proxy, 1, "\xc0\x80", "");
  assert(h->error == GPUI_INVALID);
  int before = call_count;
  assert(gpui_text_session_update(h->token, h->window, 1, NULL, 0, 0, 0, 0, 0, 1, 1, 0) == -GPUI_INVALID);
  assert(gpui_text_session_cancel(h->token, h->window, 1) == -GPUI_INVALID);
  assert(gpui_text_session_panel(h->token, h->window, 1, 0) == GPUI_INVALID);
  assert(call_count == before && h->count == 0);
  ime_leave(h, h->ime.proxy);
  int after_leave = h->count;
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  assert(h->count == after_leave); finish(h);
}
static void opt_in_rejects_closed_direct_host_and_revokes_prior_keys(void) {
  struct host *h = fixture();
  h->direct_exhausted = h->direct_ever_enabled = 1;
  assert(gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1) == -GPUI_RESOURCE);
  assert(!h->ime.proxy && !h->ime.epoch && !call_count); finish(h);
  h = fixture();
  direct_key_record(h, 11, XKB_KEY_a, 'a', 0, 0, 0);
  assert(h->count == 1 && !h->direct_queue[h->read].revoked);
  int epoch = gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1); assert(epoch == 1);
  ime_enter(h, h->ime.proxy, h->surface);
  assert(h->count == 2 && h->direct_queue[h->read].revoked);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  assert(gpui_next(h->token, data) == -GPUI_UNSUPPORTED && h->count == 2);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 22 && h->count == 0);
  finish(h);
  h = fixture(); direct_key_record(h, 11, XKB_KEY_a, 'a', 0, 0, 0);
  epoch = gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1); assert(epoch == 1);
  ime_enter(h, h->ime.proxy, h->surface);
  assert(gpui_text_session_end(h->token, h->window, epoch) == 0);
  ime_leave(h, h->ime.proxy);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && h->count == 0);
  finish(h);
}
static void exhaustion_closes_all_editor_ingress(void) {
  struct host *h = fixture(); begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS], before[GPUI_EDITOR_EVENT_FIELDS];
  uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  memset(data, 0xa5, sizeof(data)); memcpy(before, data, sizeof(data));
  h->ime.latest_serial = INT_MAX;
  assert(gpui_text_session_update(h->token, h->window, 1, NULL, 0, 0, 0,
      0, 0, 1, 1, 0) == -GPUI_RESOURCE);
  assert(h->ime.exhausted && !h->ime.requested);
  ime_leave(h, h->ime.proxy); assert(h->ime.phase == IME_INACTIVE);
  assert(gpui_next(h->token, data) == -GPUI_RESOURCE);
  assert(gpui_next_v2(2, h->token, data, 10, bytes, sizeof(bytes)) == -GPUI_RESOURCE);
  assert(read_editor(h, data, bytes) == -GPUI_RESOURCE);
  assert(!memcmp(data, before, sizeof(data)));
  assert(gpui_direct_keyboard_text_mode(h->token, h->window, 1) == GPUI_RESOURCE);
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  assert(h->count == 0 && h->error == GPUI_RESOURCE);
  finish(h);
}
static void owner_panel_requests_are_epoch_fenced(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  int before = call_count;
  assert(gpui_text_session_panel(h->token, h->window, 0, 0) == GPUI_STALE);
  assert(gpui_text_session_panel(h->token, h->window, epoch, 2) == GPUI_INVALID);
  assert(call_count == before);
  assert(gpui_text_session_panel(h->token, h->window, epoch, 0) == GPUI_OK);
  assert(calls[call_count - 1] == 4);
  int replacement = gpui_text_session_cancel(h->token, h->window, epoch); assert(replacement > epoch);
  before = call_count;
  assert(gpui_text_session_panel(h->token, h->window, replacement, 0) == GPUI_OK);
  assert(call_count == before);
  ime_leave(h, h->ime.proxy);
  assert(calls[before] == 1 && calls[before + 1] == 4);
  finish(h);
}
static int request_count(int operation) {
  int count = 0;
  for (int i = 0; i < call_count; ++i)
    count += calls[i] == operation;
  return count;
}
static void control_modifier_map(struct host *h) {
  char map[] = "Control\0Shift\0Mod1\0Mod4\0";
  struct wl_array names = {.size = sizeof(map) - 1, .data = map};
  ime_modifiers_map(h, h->ime.proxy, &names);
}
static void modifier_drain_keeps_old_grab_and_fences_text(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  control_modifier_map(h);
  /* This mask arrives from the real current keyboard callback. XKB's bit
   * indices need not equal the separate v1 modifiers-map indices. */
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  ime_preedit_cursor(h, h->ime.proxy, 0);
  int deactivates = request_count(2), activates = request_count(1);
  int replacement = gpui_text_session_update(h->token, h->window, epoch,
      (const uint8_t *)"new", 3, 3, 0, 1, 2, 1, 20, 1);
  assert(replacement == 2 && h->ime.phase == IME_DRAINING_MODIFIERS);
  assert(h->ime.serial_floor == 0 && !h->ime.stage.cursor_present);
  assert(request_count(2) == deactivates && request_count(1) == activates);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == epoch);
  ime_preedit_string(h, h->ime.proxy, 1, "old", "old");
  ime_commit_string(h, h->ime.proxy, 1, "old");
  ime_keysym(h, h->ime.proxy, 1, 0, XKB_KEY_a, WL_KEYBOARD_KEY_STATE_RELEASED, 1);
  direct_keyboard_key(h, 30, WL_KEYBOARD_KEY_STATE_PRESSED, XKB_KEY_a);
  assert(!h->count && !h->ime.drain_release_seen);
  /* A stalled modifier never triggers a timed or old-target activation. */
  for (int i = 0; i < 4; ++i) {
    keyboard_modifiers(h, h->keyboard, 11 + i, 4, 0, 0, 0);
    assert(h->ime.phase == IME_DRAINING_MODIFIERS && request_count(2) == deactivates);
  }
  /* Removed keyboard/proxy callbacks and an unissued serial cannot clear it. */
  keyboard_modifiers(h, (struct wl_keyboard *)(uintptr_t)999, 99, 0, 0, 0, 0);
  ime_keysym(h, (struct zwp_text_input_v1 *)(uintptr_t)998, 1, 0,
      XKB_KEY_Control_L, WL_KEYBOARD_KEY_STATE_RELEASED, 0);
  ime_keysym(h, h->ime.proxy, 0, 0, XKB_KEY_Control_L, WL_KEYBOARD_KEY_STATE_RELEASED, 0);
  ime_keysym(h, h->ime.proxy, 2, 0, XKB_KEY_Control_L, WL_KEYBOARD_KEY_STATE_RELEASED, 0);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS && !h->ime.drain_release_seen);
  direct_keyboard_key(h, 29, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Control_L);
  assert(h->ime.drain_release_seen && !h->count && request_count(2) == deactivates);
  keyboard_modifiers(h, h->keyboard, 20, 4, 0, 0, 0);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS);
  /* A locked modifier/group may remain. Only depressed/latched state drains. */
  keyboard_modifiers(h, h->keyboard, 21, 0, 0, 2, 1);
  assert(h->ime.phase == IME_DEACTIVATING && request_count(2) == deactivates + 1);
  assert(request_count(1) == activates && !h->count);
  keyboard_modifiers(h, h->keyboard, 22, 0, 0, 2, 1);
  assert(request_count(2) == deactivates + 1);
  ime_leave(h, h->ime.proxy);
  assert(h->ime.phase == IME_ACTIVATING && request_count(1) == activates + 1);
  assert(sent_serial == 2 && h->ime.serial_floor == 2 && !strcmp(sent_document, "new"));
  ime_enter(h, h->ime.proxy, h->surface);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 22 && data[10] == replacement);
  finish(h);
}
static void forwarded_mask_drain_needs_fresh_release_and_clear(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
  control_modifier_map(h);
  keyboard_modifiers(h, h->keyboard, 10, 0, 0, 0, 0);
  ime_keysym(h, h->ime.proxy, 1, 0, XKB_KEY_a, WL_KEYBOARD_KEY_STATE_PRESSED, 1);
  assert(h->ime.forwarded_modifiers == 2);
  assert(read_editor(h, data, bytes) == 1 && data[0] == 24);
  int deactivates = request_count(2);
  int replacement = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(replacement == 2 && h->ime.phase == IME_DRAINING_MODIFIERS);
  /* The cached zero from before the shortcut, or clear without a genuine
   * post-fence release, cannot complete the drain. */
  keyboard_modifiers(h, h->keyboard, 11, 0, 0, 0, 0);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS && request_count(2) == deactivates);
  ime_keysym(h, h->ime.proxy, 1, 0, XKB_KEY_Control_L,
      WL_KEYBOARD_KEY_STATE_RELEASED, 1);
  assert(h->ime.drain_release_seen && request_count(2) == deactivates);
  keyboard_modifiers(h, h->keyboard, 12, 0, 1, 0, 0);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS);
  keyboard_modifiers(h, h->keyboard, 13, 0, 0, 0, 0);
  assert(h->ime.phase == IME_DEACTIVATING && request_count(2) == deactivates + 1);
  assert(h->count == 1); /* only the old Left, never a drained key */
  assert(read_editor(h, data, bytes) == 1 && data[0] == 23);
  finish(h);
}
static void replacement_updates_coalesce_and_teardown_supersedes_drain(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS);
  int barrier = h->ime.drain_modifiers_sequence, activates = request_count(1);
  epoch = gpui_text_session_update(h->token, h->window, epoch,
      (const uint8_t *)"latest", 6, 6, 1, 3, 4, 1, 20, 1);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(epoch == 4 && h->ime.drain_modifiers_sequence == barrier && h->count == 1);
  direct_keyboard_key(h, 29, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Control_L);
  keyboard_modifiers(h, h->keyboard, 11, 0, 0, 0, 0);
  ime_leave(h, h->ime.proxy);
  assert(h->ime.phase == IME_ACTIVATING && h->ime.wire_epoch == 4 && !strcmp(sent_document, "latest"));
  assert(request_count(1) == activates + 1);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  activates = request_count(1);
  keyboard_leave(h, h->keyboard, 11, h->surface);
  assert(!h->ime.requested && h->ime.phase == IME_DEACTIVATING && !h->ime.drain_release_seen);
  ime_leave(h, h->ime.proxy);
  keyboard_modifiers(h, h->keyboard, 12, 0, 0, 0, 0);
  assert(h->ime.phase == IME_INACTIVE && request_count(1) == activates);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  activates = request_count(1);
  assert(gpui_close(h->token, h->window) == GPUI_OK);
  assert(!h->ime.requested && h->ime.phase == IME_DEACTIVATING);
  ime_leave(h, h->ime.proxy);
  assert(request_count(1) == activates);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  activates = request_count(1);
  assert(gpui_destroy(h->token, h->window) == GPUI_OK);
  assert(!h->ime.requested && h->ime.phase == IME_DEACTIVATING && !h->window);
  ime_leave(h, h->ime.proxy);
  assert(request_count(1) == activates);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h); h->scale = 1;
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  struct zwp_text_input_v1 *old = h->ime.proxy;
  activates = request_count(1);
  global_remove(h, NULL, h->seat_name);
  assert(!h->ime.requested && !h->ime.proxy && !h->ime.keyboard_modifiers_known);
  ime_leave(h, old);
  keyboard_modifiers(h, (struct wl_keyboard *)(uintptr_t)102, 12, 0, 0, 0, 0);
  assert(h->ime.phase == IME_INACTIVE && request_count(1) == activates);
  finish(h);
}
static void draining_failure_end_and_locks_fail_closed(void) {
  struct host *h = fixture(); int epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS);
  int activates = request_count(1);
  assert(gpui_text_session_end(h->token, h->window, epoch) == GPUI_OK);
  assert(!h->ime.requested && h->ime.phase == IME_DEACTIVATING);
  direct_keyboard_key(h, 29, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Control_L);
  keyboard_modifiers(h, h->keyboard, 11, 0, 0, 0, 0);
  ime_leave(h, h->ime.proxy);
  assert(h->ime.phase == IME_INACTIVE && request_count(1) == activates);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  activates = request_count(1);
  h->ime.keyboard_modifiers_sequence = INT_MAX;
  direct_keyboard_key(h, 29, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Control_L);
  keyboard_modifiers(h, h->keyboard, 11, 0, 0, 0, 0);
  assert(h->error == GPUI_RESOURCE && h->ime.phase == IME_DRAINING_MODIFIERS);
  assert(request_count(1) == activates);
  quiesce_host(h);
  assert(!h->ime.requested && h->ime.phase == IME_DEACTIVATING);
  ime_leave(h, h->ime.proxy);
  assert(request_count(1) == activates);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  h->ime.latest_serial = INT_MAX;
  assert(gpui_text_session_cancel(h->token, h->window, epoch) == -GPUI_RESOURCE);
  assert(h->ime.exhausted && !h->ime.requested && h->ime.phase == IME_DEACTIVATING);
  finish(h);
  h = fixture(); epoch = begin(h); drain_enter(h);
  /* Locked state persists after the actual lock-key release and must not
   * hold the grab indefinitely; its depressed bit still needs a release. */
  keyboard_modifiers(h, h->keyboard, 10, 2, 0, 2, 0);
  epoch = gpui_text_session_cancel(h->token, h->window, epoch);
  assert(h->ime.phase == IME_DRAINING_MODIFIERS);
  direct_keyboard_key(h, 58, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Caps_Lock);
  keyboard_modifiers(h, h->keyboard, 11, 0, 0, 2, 0);
  assert(h->ime.phase == IME_DEACTIVATING);
  finish(h);
  h = fixture(); /* Never opted in: new bookkeeping cannot fail old input. */
  h->ime.keyboard_modifiers_sequence = INT_MAX;
  keyboard_modifiers(h, h->keyboard, 10, 0, 0, 0, 0);
  assert(!h->error && h->ime.keyboard_modifiers_known);
  finish(h);
}
static void native_revocation_notifies_the_pending_epoch(void) {
  for (int reason = 0; reason < 3; ++reason) {
    struct host *h = fixture(); int epoch = begin(h); drain_enter(h); h->scale = 1;
    keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
    epoch = gpui_text_session_cancel(h->token, h->window, epoch);
    assert(epoch == 2 && h->ime.phase == IME_DRAINING_MODIFIERS);
    int activates = request_count(1);
    if (reason == 0)
      ime_leave(h, h->ime.proxy);
    else if (reason == 1) {
      int fd = open("/dev/null", O_RDONLY); assert(fd >= 0);
      keyboard_keymap(h, h->keyboard, 0, fd, 0);
    } else
      global_remove(h, NULL, h->ime.manager_name);
    assert(!h->ime.requested && request_count(1) == activates);
    double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
    assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == 1);
    /* The field owner already adopted epoch2. It must learn that pending
     * target was revoked, instead of waiting indefinitely for its Entered. */
    assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == epoch);
    assert(!h->count);
    finish(h);
  }
}
static void manager_revocation_during_physical_leave_notifies_pending_epoch(void) {
  for (int held = 0; held < 2; ++held) {
    struct host *h = fixture(); int epoch = begin(h); drain_enter(h); h->scale = 1;
    if (held)
      keyboard_modifiers(h, h->keyboard, 10, 4, 0, 0, 0);
    epoch = gpui_text_session_cancel(h->token, h->window, epoch);
    if (held) {
      assert(h->ime.phase == IME_DRAINING_MODIFIERS);
      direct_keyboard_key(h, 29, WL_KEYBOARD_KEY_STATE_RELEASED, XKB_KEY_Control_L);
      keyboard_modifiers(h, h->keyboard, 11, 0, 0, 0, 0);
    }
    assert(epoch == 2 && h->ime.phase == IME_DEACTIVATING && h->ime.requested);
    int activates = request_count(1);
    struct zwp_text_input_v1 *old = h->ime.proxy;
    global_remove(h, NULL, h->ime.manager_name);
    assert(!h->ime.requested && !h->ime.proxy && request_count(1) == activates);
    ime_leave(h, old);
    double data[GPUI_EDITOR_EVENT_FIELDS]; uint8_t bytes[GPUI_EDITOR_MAX_PAYLOAD];
    assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == 1);
    assert(read_editor(h, data, bytes) == 1 && data[0] == 23 && data[10] == epoch);
    assert(!h->count && request_count(1) == activates);
    finish(h);
  }
}
static void bounds_exhaustion_and_validation(void) {
  struct host *h = fixture();
  const uint8_t doc[] = "日";
  assert(gpui_text_session_begin(h->token, h->window, doc, 3, 1, 0, 0, 0, 1, 1) == -GPUI_INVALID);
  assert(!h->ime.proxy && h->ime.epoch == 0);
  begin(h); drain_enter(h);
  char over[GPUI_IME_MAX_BYTES + 2]; memset(over, 'x', sizeof(over)); over[sizeof(over) - 1] = 0;
  ime_preedit_string(h, h->ime.proxy, 1, over, "");
  assert(h->error == GPUI_RESOURCE && h->count == 0); h->error = 0;
  for (int i = 0; i < GPUI_IME_MAX_STYLES + 1; ++i) ime_preedit_styling(h, h->ime.proxy, 0, 0, 0);
  assert(h->error == GPUI_INVALID && h->ime.stage.style_count == 0); h->error = 0;
  h->seq = INT_MAX; ime_commit_string(h, h->ime.proxy, 1, "x");
  assert(h->error == GPUI_RESOURCE && h->count == 0); h->error = 0; h->seq = 0;
  size_t fake_bytes = h->ime_queue_bytes; h->ime_queue_bytes = GPUI_IME_QUEUE_BYTES;
  ime_commit_string(h, h->ime.proxy, 1, "x"); assert(h->error == GPUI_RESOURCE && h->count == 0);
  h->ime_queue_bytes = fake_bytes; h->error = 0;
  h->ime.epoch = INT_MAX;
  assert(gpui_text_session_cancel(h->token, h->window, INT_MAX) == -GPUI_RESOURCE);
  finish(h);
  h = fixture(); h->ime.epoch = INT_MAX;
  assert(gpui_text_session_begin(h->token, h->window, NULL, 0, 0, 0, 0, 0, 1, 1) == -GPUI_RESOURCE);
  assert(h->ime.exhausted && !h->ime.requested);
  finish(h);
}
int main(void) {
  copies_staging_order_and_shared_serial(); independent_staging_survives_stale_peer_event();
  buffers_and_legacy_are_atomic();
  serial_epoch_and_reactivation_fences(); lifecycle_and_removed_proxies();
  destroy_and_manager_removal_revoke_owned_payloads();
  destroy_reports_terminal_sequence_exhaustion();
  keys_modifiers_and_text_suppression(); owner_panel_requests_are_epoch_fenced();
  bounds_exhaustion_and_validation(); quiescing_and_latched_errors_fail_closed();
  exhaustion_closes_all_editor_ingress();
  opt_in_rejects_closed_direct_host_and_revokes_prior_keys();
  modifier_drain_keeps_old_grab_and_fences_text();
  forwarded_mask_drain_needs_fresh_release_and_clear();
  replacement_updates_coalesce_and_teardown_supersedes_drain();
  draining_failure_end_and_locks_fail_closed();
  native_revocation_notifies_the_pending_epoch();
  manager_revocation_during_physical_leave_notifies_pending_epoch();
  puts("experimental IME native transport unit tests passed"); return 0;
}
