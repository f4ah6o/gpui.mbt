#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon-compose.h>

/* Only clipboard proxy calls below are mocked: unit tests must never invoke
 * Wayland protocol functions on fabricated pointers. */
static struct wl_data_device *mock_next_data_device;
static struct wl_data_offer *mock_destroyed_offers[16];
static struct wl_data_device *mock_destroyed_devices[8];
static int mock_offer_destroy_count, mock_device_destroy_count;
static int mock_device_listener_count, mock_offer_listener_count;
static int mock_get_data_device_count;
static int mock_display_flush_fail, mock_display_flush_calls;
static int mock_display_error, mock_display_error_calls;
static int mock_offer_receive_calls, mock_offer_receive_fd;

struct host;
static struct host *test_host_free_watch;
static struct xkb_compose_state *test_compose_unref_watch;
static int test_host_free_captured, test_compose_unref_count;
static int test_stopped_epoch, test_stopped_enabled, test_stopped_state;
static enum xkb_compose_status test_stopped_compose_status;
static void test_free(void *pointer);
static void test_compose_state_unref(struct xkb_compose_state *state);

static void mock_wl_data_offer_destroy(struct wl_data_offer *offer) {
  assert(mock_offer_destroy_count <
         (int)(sizeof(mock_destroyed_offers) / sizeof(mock_destroyed_offers[0])));
  mock_destroyed_offers[mock_offer_destroy_count++] = offer;
}
static void mock_wl_data_device_destroy(struct wl_data_device *device) {
  assert(mock_device_destroy_count <
         (int)(sizeof(mock_destroyed_devices) / sizeof(mock_destroyed_devices[0])));
  mock_destroyed_devices[mock_device_destroy_count++] = device;
}
static int mock_wl_data_offer_add_listener(
    struct wl_data_offer *offer, const struct wl_data_offer_listener *listener,
    void *data) {
  (void)offer;
  (void)listener;
  (void)data;
  ++mock_offer_listener_count;
  return 0;
}
static int mock_wl_data_device_add_listener(
    struct wl_data_device *device,
    const struct wl_data_device_listener *listener, void *data) {
  (void)device;
  (void)listener;
  (void)data;
  ++mock_device_listener_count;
  return 0;
}
static struct wl_data_device *mock_wl_data_device_manager_get_data_device(
    struct wl_data_device_manager *manager, struct wl_seat *seat) {
  (void)manager;
  (void)seat;
  ++mock_get_data_device_count;
  return mock_next_data_device;
}
static int mock_wl_display_flush(struct wl_display *display) {
  (void)display;
  ++mock_display_flush_calls;
  if (mock_display_flush_fail) {
    errno = EIO;
    return -1;
  }
  return 0;
}
static int mock_wl_display_get_error(struct wl_display *display) {
  (void)display;
  ++mock_display_error_calls;
  return mock_display_error;
}
static void mock_wl_data_offer_receive(struct wl_data_offer *offer,
                                       const char *mime, int32_t fd) {
  (void)offer;
  (void)mime;
  ++mock_offer_receive_calls;
  mock_offer_receive_fd = fd;
}

#define wl_data_offer_destroy mock_wl_data_offer_destroy
#define wl_data_device_destroy mock_wl_data_device_destroy
#define wl_data_offer_add_listener mock_wl_data_offer_add_listener
#define wl_data_device_add_listener mock_wl_data_device_add_listener
#define wl_data_device_manager_get_data_device \
  mock_wl_data_device_manager_get_data_device
#define wl_display_flush mock_wl_display_flush
#define wl_display_get_error mock_wl_display_get_error
#define wl_data_offer_receive mock_wl_data_offer_receive
#define free test_free
#define xkb_compose_state_unref test_compose_state_unref

/* Headless proof of the Linux callback/queue/decoder tier only. This includes
 * the private backend so the real static Wayland callbacks can be driven with
 * an owner-thread fake host and real XKB/Compose state, without a display. */
#include "../../ubuntu/backend.c"
#undef xkb_compose_state_unref
#undef free

static void test_free(void *pointer) {
  if (pointer && pointer == (void *)test_host_free_watch) {
    test_host_free_captured = 1;
    test_stopped_epoch = test_host_free_watch->direct_epoch;
    test_stopped_enabled = test_host_free_watch->direct_enabled;
    test_stopped_state = test_host_free_watch->state;
    return; /* The stop test inspects this host snapshot before real free. */
  }
  free(pointer);
}

static void test_compose_state_unref(struct xkb_compose_state *state) {
  if (state && state == test_compose_unref_watch) {
    ++test_compose_unref_count;
    test_stopped_compose_status = xkb_compose_state_get_status(state);
  }
  xkb_compose_state_unref(state);
}

enum { TEST_HOST = 731, TEST_WINDOW = 47, EVENT_CAPACITY = 10 };

static void reset_proxy_mocks(void) {
  memset(mock_destroyed_offers, 0, sizeof(mock_destroyed_offers));
  memset(mock_destroyed_devices, 0, sizeof(mock_destroyed_devices));
  mock_offer_destroy_count = 0;
  mock_device_destroy_count = 0;
  mock_device_listener_count = 0;
  mock_offer_listener_count = 0;
  mock_get_data_device_count = 0;
  mock_next_data_device = NULL;
  mock_display_flush_fail = 0;
  mock_display_flush_calls = 0;
  mock_display_error = EIO;
  mock_display_error_calls = 0;
  mock_offer_receive_calls = 0;
  mock_offer_receive_fd = -1;
}

struct fixture {
  struct host h;
  uint32_t a, q, dead_acute, escape, backspace, delete_key, left, right;
  uint32_t level3_key;
  xkb_keysym_t level3_sym;
};

static const char compose_fixture[] =
    "<dead_acute> <e> : \"é\" eacute\n"
    "<dead_acute> <space> : \"´\" acute\n";

static uint32_t key_for_sym(struct host *h, xkb_keysym_t wanted, int level) {
  xkb_keycode_t min = xkb_keymap_min_keycode(h->keymap);
  xkb_keycode_t max = xkb_keymap_max_keycode(h->keymap);
  for (xkb_keycode_t code = min; code <= max; ++code) {
    const xkb_keysym_t *syms = NULL;
    int count = xkb_keymap_key_get_syms_by_level(h->keymap, code, 0, level,
                                                 &syms);
    for (int i = 0; i < count; ++i)
      if (syms[i] == wanted)
        return code - 8;
  }
  fprintf(stderr, "test fixture missing keysym 0x%x at level %d\n",
          (unsigned)wanted, level);
  abort();
}

static uint32_t modifier_bit(struct host *h, const char *name) {
  xkb_mod_index_t index = xkb_keymap_mod_get_index(h->keymap, name);
  assert(index != XKB_MOD_INVALID && index < 32);
  return UINT32_C(1) << index;
}

static void fixture_init(struct fixture *f) {
  memset(f, 0, sizeof(*f));
  assert(setlocale(LC_ALL, "C.UTF-8") != NULL);
  f->h.token = TEST_HOST;
  f->h.window = TEST_WINDOW;
  f->h.wake_fd = -1;
  f->h.owner = pthread_self();
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    f->h.transfers[i].fd = -1;
  f->h.width = 640;
  f->h.height = 480;
  f->h.scale = 1;
  f->h.keyboard = (struct wl_keyboard *)(uintptr_t)0x1234;
  f->h.seat_name = 1;
  f->h.surface = (struct wl_surface *)(uintptr_t)0x2345;
  f->h.keyboard_focus_current = 1;
  f->h.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  assert(f->h.xkb);
  struct xkb_rule_names names = {.layout = "us",
                                 .variant = "intl",
                                 .options = "lv3:ralt_switch"};
  f->h.keymap = xkb_keymap_new_from_names(
      f->h.xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  assert(f->h.keymap);
  f->h.keys = xkb_state_new(f->h.keymap);
  assert(f->h.keys);
  f->h.direct_keymap_valid = 1;
  f->h.compose_table = xkb_compose_table_new_from_buffer(
      f->h.xkb, compose_fixture, sizeof(compose_fixture) - 1, "C.UTF-8",
      XKB_COMPOSE_FORMAT_TEXT_V1, XKB_COMPOSE_COMPILE_NO_FLAGS);
  assert(f->h.compose_table);
  f->h.compose = xkb_compose_state_new(f->h.compose_table,
                                      XKB_COMPOSE_STATE_NO_FLAGS);
  assert(f->h.compose);
  f->h.compose_attempted = 1;
  f->a = key_for_sym(&f->h, XKB_KEY_a, 0);
  f->q = key_for_sym(&f->h, XKB_KEY_q, 0);
  f->dead_acute = key_for_sym(&f->h, XKB_KEY_dead_acute, 0);
  f->escape = key_for_sym(&f->h, XKB_KEY_Escape, 0);
  f->backspace = key_for_sym(&f->h, XKB_KEY_BackSpace, 0);
  f->delete_key = key_for_sym(&f->h, XKB_KEY_Delete, 0);
  f->left = key_for_sym(&f->h, XKB_KEY_Left, 0);
  f->right = key_for_sym(&f->h, XKB_KEY_Right, 0);
  xkb_keycode_t min = xkb_keymap_min_keycode(f->h.keymap);
  xkb_keycode_t max = xkb_keymap_max_keycode(f->h.keymap);
  for (xkb_keycode_t code = min; code <= max && !f->level3_key; ++code) {
    const xkb_keysym_t *syms = NULL;
    int count = xkb_keymap_key_get_syms_by_level(f->h.keymap, code, 0, 2,
                                                 &syms);
    for (int i = 0; i < count; ++i) {
      uint32_t scalar = xkb_keysym_to_utf32(syms[i]);
      if (syms[i] != XKB_KEY_NoSymbol && scalar >= 0x20 && scalar != 0x7f) {
        f->level3_key = code - 8;
        f->level3_sym = syms[i];
        break;
      }
    }
  }
  assert(f->level3_key && f->level3_sym != XKB_KEY_NoSymbol);
  active = &f->h;
}

static void fixture_drop(struct fixture *f) {
  assert(active == &f->h);
  active = NULL;
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i) {
    if (f->h.transfers[i].fd >= 0)
      close(f->h.transfers[i].fd);
    f->h.transfers[i].fd = -1;
  }
  if (f->h.wake_fd >= 0)
    close(f->h.wake_fd);
  f->h.wake_fd = -1;
  while (f->h.sources) {
    struct clipboard_source *source = f->h.sources;
    f->h.sources = source->next;
    source->proxy = NULL; /* Test proxies are mocked; no real destroy call. */
    free(source->bytes);
    free(source);
  }
  free(f->h.clipboard_result);
  f->h.clipboard_result = NULL;
  release_compose(&f->h);
  xkb_state_unref(f->h.keys);
  xkb_keymap_unref(f->h.keymap);
  xkb_context_unref(f->h.xkb);
  f->h.keys = NULL;
  f->h.keymap = NULL;
  f->h.xkb = NULL;
}

static void arm(struct fixture *f) {
  UNUSED(f);
  int capability = gpui_capability(TEST_HOST, 3);
  if (capability != GPUI_OK)
    fprintf(stderr, "direct capability status=%d seat=%u keyboard=%p valid=%d max=%u\n",
            capability, f->h.seat_name, (void *)f->h.keyboard,
            f->h.direct_keymap_valid,
            (unsigned)xkb_keymap_max_keycode(f->h.keymap));
  assert(capability == GPUI_OK);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) == GPUI_OK);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 1);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) > 0);
}

static void set_modifiers(struct host *h, uint32_t depressed,
                          uint32_t latched, uint32_t locked) {
  keyboard_modifiers(h, h->keyboard, 0, depressed, latched, locked, 0);
}

static void press(struct host *h, uint32_t key) {
  xkb_state_update_key(h->keys, key + 8, XKB_KEY_DOWN);
  keyboard_key(h, h->keyboard, 1, 0, key, WL_KEYBOARD_KEY_STATE_PRESSED);
}

static void release_key(struct host *h, uint32_t key) {
  keyboard_key(h, h->keyboard, 2, 0, key, WL_KEYBOARD_KEY_STATE_RELEASED);
  xkb_state_update_key(h->keys, key + 8, XKB_KEY_UP);
}

static int next_v2(double out[EVENT_CAPACITY], uint8_t *text, int capacity) {
  return gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, EVENT_CAPACITY,
                      text, capacity);
}

static int next_kind(double out[EVENT_CAPACITY], uint8_t *text, int capacity,
                     int kind) {
  int result = next_v2(out, text, capacity);
  assert(result == 1);
  assert(out[0] == kind);
  return result;
}

static void test_order_modifiers_and_compose(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  assert(f.h.direct_epoch == 1);

  double out[EVENT_CAPACITY];
  uint8_t text[16];
  press(&f.h, f.a);
  release_key(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'a');
  next_kind(out, text, sizeof(text), 12);

  set_modifiers(&f.h, modifier_bit(&f.h, XKB_MOD_NAME_SHIFT), 0, 0);
  press(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'A');
  release_key(&f.h, f.a);
  next_kind(out, text, sizeof(text), 12);

  set_modifiers(&f.h, 0, 0, 0);
  set_modifiers(&f.h, 0, 0, modifier_bit(&f.h, XKB_MOD_NAME_CAPS));
  press(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'A');
  release_key(&f.h, f.a);
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);

  set_modifiers(&f.h, modifier_bit(&f.h, XKB_MOD_NAME_CTRL), 0, 0);
  press(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, f.a);
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);

  uint32_t logo = modifier_bit(&f.h, XKB_MOD_NAME_LOGO);
  set_modifiers(&f.h, logo, 0, 0);
  press(&f.h, f.q);
  next_kind(out, text, sizeof(text), 11);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, f.q);
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);

  set_modifiers(&f.h, modifier_bit(&f.h, XKB_MOD_NAME_ALT), 0, 0);
  press(&f.h, f.q);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'q');
  release_key(&f.h, f.q);
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);

  uint32_t mod5 = modifier_bit(&f.h, "Mod5");
  set_modifiers(&f.h, mod5, 0, 0);
  press(&f.h, f.level3_key);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  char expected[8];
  int expected_length = xkb_keysym_to_utf8(f.level3_sym, expected,
                                           sizeof(expected));
  assert(expected_length > 0);
  expected_length = (int)strlen(expected);
  assert((int)out[8] == expected_length);
  assert(memcmp(text, expected, (size_t)expected_length) == 0);
  release_key(&f.h, f.level3_key);
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);

  press(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0); /* Compose prefix is consumed. */
  release_key(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0); /* Its paired release too. */
  uint32_t e = key_for_sym(&f.h, XKB_KEY_e, 0);
  press(&f.h, e);
  next_kind(out, text, sizeof(text), 13); /* Exactly one composed commit. */
  assert(out[8] == 2 && text[0] == 0xc3 && text[1] == 0xa9);
  release_key(&f.h, e);
  assert(next_v2(out, text, sizeof(text)) == 0);

  press(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, f.escape);
  assert(next_v2(out, text, sizeof(text)) == 0); /* No editor Escape action. */
  release_key(&f.h, f.escape);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, f.backspace);
  assert(next_v2(out, text, sizeof(text)) == 0); /* No editor Backspace action. */
  release_key(&f.h, f.backspace);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'a'); /* Cancellation reset the prefix. */
  fixture_drop(&f);
}

static void enqueue_text(struct host *h, const uint8_t *bytes, int length,
                         int epoch) {
  assert(length >= 0 && length <= GPUI_DIRECT_TEXT_MAX_BYTES + 1);
  int before = h->count;
  event(h, 13, length, 0, 0);
  assert(h->count == before + 1);
  int slot = (h->read + before) % QUEUE_CAPACITY;
  struct direct_event_meta *meta = &h->direct_queue[slot];
  meta->epoch = epoch;
  meta->direct_origin = 1;
  meta->text_length = length;
  memcpy(meta->text, bytes, (size_t)length);
  if (length <= GPUI_DIRECT_TEXT_MAX_BYTES)
    meta->text[length] = 0;
}

static void test_v2_validation_copy_and_v1_guard(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  double out[EVENT_CAPACITY + 1];
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES + 2];
  uint8_t sample[] = {'x'};
  memset(out, 0x5a, sizeof(out));
  memset(text, 0xa5, sizeof(text));
  unsigned char out_before[sizeof(out)];
  unsigned char text_before[sizeof(text)];
  memcpy(out_before, out, sizeof(out));
  memcpy(text_before, text, sizeof(text));
  enqueue_text(&f.h, sample, sizeof(sample), f.h.direct_epoch);
  int queued = f.h.count;

  assert(gpui_next_v2(1, TEST_HOST, out, EVENT_CAPACITY, text, sizeof(text)) < 0);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, NULL, EVENT_CAPACITY,
                      text, sizeof(text)) < 0);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, 9, text,
                      sizeof(text)) < 0);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, -1, text,
                      sizeof(text)) < 0);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, EVENT_CAPACITY,
                      NULL, 1) < 0);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, EVENT_CAPACITY,
                      text, -1) < 0);
  assert(f.h.count == queued && memcmp(out, out_before, sizeof(out)) == 0 &&
         memcmp(text, text_before, sizeof(text)) == 0);

  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, TEST_HOST, out, EVENT_CAPACITY,
                      NULL, 0) == -GPUI_RESOURCE);
  assert(f.h.count == queued && memcmp(out, out_before, sizeof(out)) == 0);
  assert(next_v2(out, text, 0) == -GPUI_RESOURCE);
  assert(f.h.count == queued && memcmp(text, text_before, sizeof(text)) == 0);

  double legacy[EVENT_CAPACITY];
  unsigned char legacy_before[sizeof(legacy)];
  for (int i = 0; i < EVENT_CAPACITY; ++i)
    legacy[i] = -777;
  memcpy(legacy_before, legacy, sizeof(legacy));
  assert(gpui_next(TEST_HOST, legacy) == -GPUI_UNSUPPORTED);
  assert(memcmp(legacy, legacy_before, sizeof(legacy)) == 0);
  assert(f.h.count == queued);

  assert(next_v2(out, text, 1) == 1);
  assert(out[0] == 13 && out[8] == 1 && text[0] == 'x');
  assert(memcmp(&out[10], out_before + EVENT_CAPACITY * sizeof(double),
                sizeof(out[10])) == 0);
  assert(text[1] == 0xa5);

  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 0) == GPUI_OK);
  memset(legacy, 0x6b, sizeof(legacy));
  memcpy(legacy_before, legacy, sizeof(legacy));
  enqueue_text(&f.h, sample, sizeof(sample), f.h.direct_epoch);
  assert(gpui_next(TEST_HOST, legacy) == -GPUI_UNSUPPORTED);
  assert(memcmp(legacy, legacy_before, sizeof(legacy)) == 0);
  assert(f.h.count == 1);
  fixture_drop(&f);
}

static void test_utf8_lengths_and_canaries(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  uint8_t boundary[GPUI_DIRECT_TEXT_MAX_BYTES];
  memset(boundary, 'b', sizeof(boundary));
  enqueue_text(&f.h, boundary, sizeof(boundary), f.h.direct_epoch);
  double out[EVENT_CAPACITY + 1];
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES + 1];
  memset(out, 0x31, sizeof(out));
  memset(text, 0xcc, sizeof(text));
  unsigned char canary[sizeof(out[10])];
  memcpy(canary, &out[10], sizeof(canary));
  assert(next_v2(out, text, GPUI_DIRECT_TEXT_MAX_BYTES) == 1);
  assert(out[0] == 13 && out[8] == GPUI_DIRECT_TEXT_MAX_BYTES);
  assert(memcmp(text, boundary, sizeof(boundary)) == 0);
  assert(text[GPUI_DIRECT_TEXT_MAX_BYTES] == 0xcc);
  assert(memcmp(&out[10], canary, sizeof(canary)) == 0);

  uint8_t too_long[GPUI_DIRECT_TEXT_MAX_BYTES + 1];
  memset(too_long, 'z', sizeof(too_long));
  enqueue_text(&f.h, too_long, sizeof(too_long), f.h.direct_epoch);
  memset(out, 0x42, sizeof(out));
  memset(text, 0xdd, sizeof(text));
  unsigned char unchanged_event[sizeof(out[0])];
  unsigned char unchanged_text[sizeof(text[0])];
  memcpy(unchanged_event, out, sizeof(unchanged_event));
  memcpy(unchanged_text, text, sizeof(unchanged_text));
  assert(next_v2(out, text, sizeof(text)) == -GPUI_INVALID);
  assert(f.h.count == 1 &&
         memcmp(out, unchanged_event, sizeof(unchanged_event)) == 0 &&
         memcmp(text, unchanged_text, sizeof(unchanged_text)) == 0);
  f.h.direct_queue[f.h.read].text_length = 1;
  f.h.direct_queue[f.h.read].text[0] = 0xc0; /* Illegal UTF-8 lead byte. */
  f.h.queue[f.h.read][8] = 1;
  assert(next_v2(out, text, sizeof(text)) == -GPUI_INVALID);
  assert(f.h.count == 1 &&
         memcmp(out, unchanged_event, sizeof(unchanged_event)) == 0 &&
         memcmp(text, unchanged_text, sizeof(unchanged_text)) == 0);
  f.h.direct_queue[f.h.read].text[0] = 'z';
  assert(next_v2(out, text, sizeof(text)) == 1);
  assert(out[0] == 13 && out[8] == 1 && text[0] == 'z');

  uint8_t empty = 0;
  enqueue_text(&f.h, &empty, 0, f.h.direct_epoch);
  assert(next_v2(out, text, sizeof(text)) == -GPUI_INVALID);
  assert(f.h.count == 1);
  fixture_drop(&f);
}

static void test_atomic_capacity_and_legacy_mode_off(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  f.h.count = QUEUE_CAPACITY - 1;
  int prior_seq = f.h.seq;
  press(&f.h, f.a);
  assert(f.h.count == QUEUE_CAPACITY - 1 && f.h.seq == prior_seq);
  assert(f.h.error == GPUI_RESOURCE);

  f.h.count = 0;
  f.h.read = 0;
  f.h.seq = INT_MAX - 1;
  f.h.error = 0;
  press(&f.h, f.q);
  assert(f.h.count == 0 && f.h.seq == INT_MAX - 1);
  assert(f.h.error == GPUI_RESOURCE);
  fixture_drop(&f);

  fixture_init(&f);
  press(&f.h, f.a); /* Legacy keyboard behavior is still key-only. */
  double out[EVENT_CAPACITY];
  assert(gpui_next(TEST_HOST, out) == 1 && out[0] == 11);
  assert(gpui_next(TEST_HOST, out) == 0);
  fixture_drop(&f);
}

static void test_stale_filtering_and_reset_epochs(void) {
  struct fixture f;
  fixture_init(&f);
  /* A legacy keyboard record queued before arming is stale once v2 is active. */
  press(&f.h, f.a);
  assert(f.h.count == 1);
  arm(&f);
  int first_epoch = f.h.direct_epoch;
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  assert(next_v2(out, text, sizeof(text)) == 0);

  /* Re-arm after the key half was popped. The later text/release halves still
   * carry the press epoch and cannot be attached to the new editor target. */
  press(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  int popped_press_epoch = f.h.direct_epoch;
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) == GPUI_OK);
  assert(f.h.direct_epoch > popped_press_epoch);
  release_key(&f.h, f.a);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, f.q);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'q');
  release_key(&f.h, f.q);
  next_kind(out, text, sizeof(text), 12);

  press(&f.h, f.backspace);
  release_key(&f.h, f.backspace);
  press(&f.h, f.delete_key);
  release_key(&f.h, f.delete_key);
  press(&f.h, f.left);
  release_key(&f.h, f.left);
  press(&f.h, f.right);
  release_key(&f.h, f.right);
  press(&f.h, f.q);
  release_key(&f.h, f.q);
  event(&f.h, 7, 0, 12.5, 20.0); /* Non-key records survive target re-arm. */
  event(&f.h, 2, 0, 0, 0);       /* Window-size record. */
  event(&f.h, 3, 0, 0, 0);       /* Frame record. */
  int prior_count = f.h.count;
  assert(prior_count > 8);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) == GPUI_OK);
  assert(f.h.direct_epoch > first_epoch);
  next_kind(out, text, sizeof(text), 7);
  assert(out[6] == 12.5 && out[7] == 20.0);
  next_kind(out, text, sizeof(text), 2);
  next_kind(out, text, sizeof(text), 3);
  assert(next_v2(out, text, sizeof(text)) == 0);

  /* Native blur/re-enter resets Compose and re-arms with a new generation.
   * The epoch comparison is also the native side of paste-pump invalidation. */
  press(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  uint32_t a = key_for_sym(&f.h, XKB_KEY_a, 0);
  press(&f.h, a); /* Non-consumed presses retain their originating epoch. */
  int before_blur = f.h.direct_epoch;
  int stale_paste_epoch = gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW);
  keyboard_leave(&f.h, f.h.keyboard, 0, f.h.surface);
  assert(!f.h.direct_enabled && f.h.direct_epoch > before_blur);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) < 0);
  keyboard_enter(&f.h, f.h.keyboard, 0, f.h.surface, NULL);
  arm(&f);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) !=
         stale_paste_epoch);
  int result;
  while ((result = next_v2(out, text, sizeof(text))) == 1)
    assert(out[0] == 6); /* Focus notifications remain ordered. */
  assert(result == 0);
  release_key(&f.h, f.dead_acute); /* Same physical keyboard: stay swallowed. */
  release_key(&f.h, a); /* Old-generation release is discarded too. */
  assert(next_v2(out, text, sizeof(text)) == 0);
  uint32_t e = key_for_sym(&f.h, XKB_KEY_e, 0);
  press(&f.h, e);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'e'); /* Blur cancelled the pending compose. */
  fixture_drop(&f);
}

static int keymap_fd(struct xkb_keymap *keymap, uint32_t *size_out) {
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  assert(text);
  size_t n = strlen(text) + 1;
  assert(n <= UINT32_MAX);
  int fd = memfd_create("gpui-direct-keymap-test", MFD_CLOEXEC);
  assert(fd >= 0);
  size_t offset = 0;
  while (offset < n) {
    ssize_t written = write(fd, text + offset, n - offset);
    assert(written > 0);
    offset += (size_t)written;
  }
  free(text);
  assert(lseek(fd, 0, SEEK_SET) == 0);
  *size_out = (uint32_t)n;
  return fd;
}

static void test_keymap_and_device_resets(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  press(&f.h, f.dead_acute);
  assert(next_v2((double[EVENT_CAPACITY]){0}, NULL, 0) == 0);
  uint32_t old_dead_key = f.dead_acute;
  int before_map = f.h.direct_epoch;

  struct xkb_rule_names names = {.layout = "us", .variant = "intl"};
  struct xkb_keymap *replacement =
      xkb_keymap_new_from_names(f.h.xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  assert(replacement);
  uint32_t size = 0;
  int fd = keymap_fd(replacement, &size);
  keyboard_keymap(&f.h, f.h.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd,
                  size);
  xkb_keymap_unref(replacement);
  assert(f.h.direct_keymap_valid && f.h.direct_enabled);
  assert(f.h.direct_epoch > before_map);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  release_key(&f.h, old_dead_key); /* Keymap reset keeps same-device swallow. */
  assert(next_v2(out, text, sizeof(text)) == 0);
  uint32_t e = key_for_sym(&f.h, XKB_KEY_e, 0);
  press(&f.h, e);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 1 && text[0] == 'e');

  uint32_t a = key_for_sym(&f.h, XKB_KEY_a, 0);
  press(&f.h, a); /* Physical press pending when old device disappears. */
  uint32_t dead_acute = key_for_sym(&f.h, XKB_KEY_dead_acute, 0);
  press(&f.h, dead_acute); /* And one consumed Compose press. */
  assert(f.h.direct_keys[dead_acute].swallowed);
  int before_loss = f.h.direct_epoch;
  f.h.keyboard = NULL; /* Old-proxy callbacks are now excluded. */
  seat_caps(&f.h, NULL, 0);
  assert(!f.h.direct_enabled && !f.h.direct_keymap_valid);
  assert(f.h.direct_epoch > before_loss);
  assert(!f.h.direct_keys[a].pressed && !f.h.direct_keys[a].swallowed);
  assert(!f.h.direct_keys[dead_acute].pressed &&
         !f.h.direct_keys[dead_acute].swallowed);

  f.h.keyboard = (struct wl_keyboard *)(uintptr_t)0x3456; /* New seat device. */
  struct xkb_rule_names rebound_names = {.layout = "us", .variant = "intl"};
  struct xkb_keymap *rebound = xkb_keymap_new_from_names(
      f.h.xkb, &rebound_names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  assert(rebound);
  size = 0;
  fd = keymap_fd(rebound, &size);
  keyboard_keymap(&f.h, f.h.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd,
                  size);
  xkb_keymap_unref(rebound);
  keyboard_enter(&f.h, f.h.keyboard, 0, f.h.surface, NULL);
  arm(&f);
  assert(next_v2(out, text, sizeof(text)) == 1 && out[0] == 6);
  press(&f.h, a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  release_key(&f.h, a);
  next_kind(out, text, sizeof(text), 12);
  fixture_drop(&f);
}

static void test_global_seat_remove_rejects_old_keyboard(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  struct wl_keyboard *old_keyboard = f.h.keyboard;
  press(&f.h, f.a);
  assert(f.h.count == 2);
  int old_epoch = f.h.direct_epoch;

  /* The registry removal excludes the old proxy before callbacks are probed.
   * Keep the saved pointer only as an identity token; no Wayland call sees it. */
  f.h.keyboard = NULL;
  f.h.seat = NULL;
  f.h.pointer = NULL;
  global_remove(&f.h, NULL, f.h.seat_name);
  assert(f.h.seat_name == 0 && !f.h.direct_enabled &&
         !f.h.direct_keymap_valid && f.h.direct_epoch > old_epoch);
  assert(!f.h.direct_keys[f.a].pressed);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  int count = f.h.count;
  keyboard_key(&f.h, old_keyboard, 1, 0, f.a,
               WL_KEYBOARD_KEY_STATE_PRESSED);
  keyboard_enter(&f.h, old_keyboard, 0, f.h.surface, NULL);
  keyboard_modifiers(&f.h, old_keyboard, 0, 1, 0, 0, 0);
  assert(f.h.count == count && !f.h.keyboard_focus_current);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) ==
         GPUI_UNSUPPORTED);
  assert(next_v2(out, text, sizeof(text)) == 0); /* Old stamped pair is stale. */
  fixture_drop(&f);
}

static void test_seat_clipboard_lifetime_and_rebind(void) {
  struct fixture f;
  fixture_init(&f);
  reset_proxy_mocks();
  struct wl_data_device *old_device =
      (struct wl_data_device *)(uintptr_t)0x4001;
  struct wl_data_offer *same_offer =
      (struct wl_data_offer *)(uintptr_t)0x5001;
  struct wl_data_offer *orphan_offer =
      (struct wl_data_offer *)(uintptr_t)0x5002;
  f.h.seat_name = 19;
  f.h.seat = NULL;
  f.h.keyboard = NULL;
  f.h.pointer = NULL;
  f.h.data_manager = (struct wl_data_device_manager *)(uintptr_t)0x6001;
  f.h.data_device = old_device;
  f.h.selection_offer = same_offer;
  f.h.pending_offer = same_offer;
  f.h.clipboard_has_utf8 = 1;
  f.h.clipboard_has_plain = 1;
  f.h.pending_has_utf8 = 1;
  f.h.pending_has_plain = 1;

  struct clipboard_source *source = calloc(1, sizeof(*source));
  assert(source);
  source->host = &f.h;
  source->bytes = malloc(6);
  assert(source->bytes);
  memcpy(source->bytes, "owned\0", 6);
  source->length = 5;
  source->proxy = (struct wl_data_source *)(uintptr_t)0x7001;
  source->transfers = 1;
  f.h.sources = source;
  int pipe_fds[2];
  assert(pipe(pipe_fds) == 0);
  f.h.transfers[0].source = source;
  f.h.transfers[0].fd = pipe_fds[0];
  f.h.transfers[0].offset = 2;
  f.h.clipboard_result = malloc(4);
  assert(f.h.clipboard_result);
  memcpy(f.h.clipboard_result, "read", 4);
  f.h.clipboard_result_length = 4;
  uint8_t *result_snapshot = f.h.clipboard_result;
  int old_epoch = f.h.direct_epoch;

  /* Alias case: the selected and pending offer share one proxy. */
  global_remove(&f.h, NULL, 19);
  assert(f.h.seat_name == 0 && f.h.data_device == NULL &&
         f.h.selection_offer == NULL && f.h.pending_offer == NULL);
  assert(mock_offer_destroy_count == 1 &&
         mock_destroyed_offers[0] == same_offer);
  assert(mock_device_destroy_count == 1 &&
         mock_destroyed_devices[0] == old_device);
  assert(f.h.direct_epoch > old_epoch && !f.h.direct_enabled &&
         !f.h.direct_keymap_valid);
  assert(!f.h.clipboard_has_utf8 && !f.h.clipboard_has_plain &&
         !f.h.pending_has_utf8 && !f.h.pending_has_plain);

  /* Seat detachment keeps source ownership, an active fd/refcount, and the
   * read-result lifetime intact. The fd is a real pipe; proxy calls stay mocked. */
  assert(f.h.sources == source && source->proxy ==
             (struct wl_data_source *)(uintptr_t)0x7001 &&
         source->transfers == 1 && source->length == 5 &&
         memcmp(source->bytes, "owned", 5) == 0);
  assert(f.h.transfers[0].source == source &&
         f.h.transfers[0].fd == pipe_fds[0] &&
         f.h.transfers[0].offset == 2 && fcntl(pipe_fds[0], F_GETFD) >= 0);
  assert(f.h.clipboard_result == result_snapshot &&
         f.h.clipboard_result_length == 4 &&
         memcmp(f.h.clipboard_result, "read", 4) == 0);

  /* Late old-device callbacks cannot republish a retired offer. A new offer
   * event naming an old device is an orphan and is destroyed exactly once. */
  offer_mime(&f.h, same_offer, "text/plain;charset=utf-8");
  data_selection(&f.h, old_device, same_offer);
  assert(!f.h.pending_has_utf8 && !f.h.clipboard_has_utf8);
  data_offer(&f.h, old_device, orphan_offer);
  assert(mock_offer_destroy_count == 2 &&
         mock_destroyed_offers[1] == orphan_offer);
  assert(f.h.pending_offer == NULL && f.h.data_device == NULL);

  /* Mock a new seat and its manager-owned device, without making a protocol
   * request. The returned proxy receives a listener and fresh offers work. */
  struct wl_seat *new_seat = (struct wl_seat *)(uintptr_t)0x8001;
  struct wl_data_device *new_device =
      (struct wl_data_device *)(uintptr_t)0x4002;
  struct wl_data_offer *new_selection =
      (struct wl_data_offer *)(uintptr_t)0x5003;
  struct wl_data_offer *distinct_pending =
      (struct wl_data_offer *)(uintptr_t)0x5004;
  f.h.seat = new_seat;
  f.h.seat_name = 20;
  mock_next_data_device = new_device;
  maybe_create_data_device(&f.h);
  assert(mock_get_data_device_count == 1 &&
         mock_device_listener_count == 1 && f.h.data_device == new_device);
  data_offer(&f.h, new_device, new_selection);
  assert(mock_offer_listener_count == 1 && f.h.pending_offer == new_selection);
  offer_mime(&f.h, new_selection, "text/plain;charset=utf-8");
  data_selection(&f.h, new_device, new_selection);
  assert(f.h.selection_offer == new_selection &&
         f.h.pending_offer == new_selection && f.h.clipboard_has_utf8);

  /* Distinct selected/pending proxies are each detached once. */
  data_offer(&f.h, new_device, distinct_pending);
  offer_mime(&f.h, distinct_pending, "text/plain");
  f.h.seat = NULL; /* Test proxy is not sent to a real destructor. */
  global_remove(&f.h, NULL, 20);
  assert(mock_offer_destroy_count == 4);
  assert(mock_destroyed_offers[2] == new_selection &&
         mock_destroyed_offers[3] == distinct_pending);
  assert(mock_device_destroy_count == 2 &&
         mock_destroyed_devices[1] == new_device);
  assert(f.h.selection_offer == NULL && f.h.pending_offer == NULL &&
         !f.h.clipboard_has_utf8 && !f.h.pending_has_plain);

  /* A stale old offer/device is ignored after the fresh seat was detached. */
  offer_mime(&f.h, new_selection, "text/plain");
  data_selection(&f.h, new_device, new_selection);
  struct wl_data_offer *orphan_after_remove =
      (struct wl_data_offer *)(uintptr_t)0x5005;
  data_offer(&f.h, new_device, orphan_after_remove);
  assert(mock_offer_destroy_count == 5 &&
         mock_destroyed_offers[4] == orphan_after_remove);
  assert(f.h.pending_offer == NULL && !f.h.clipboard_has_plain);

  /* Normal transfer completion drops the retained source ref; cancellation
   * then runs its ordinary collection path. */
  close(pipe_fds[1]);
  finish_transfer(&f.h.transfers[0]);
  assert(f.h.transfers[0].source == NULL && f.h.transfers[0].fd == -1 &&
         source->transfers == 0 && f.h.sources == source);
  source->proxy = NULL; /* Fake source proxy is not destroyed in this test. */
  source->cancelled = 1;
  collect_source(source);
  assert(f.h.sources == NULL);
  fixture_drop(&f);
}

static void test_epoch_exhaustion_fails_closed(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  press(&f.h, f.a);
  press(&f.h, f.left); /* Hold an editor key across exhaustion. */
  assert(f.h.count == 3);
  int queued = f.h.count;
  int sequence = f.h.seq;
  f.h.direct_epoch = INT_MAX;
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) ==
         GPUI_RESOURCE);
  assert(f.h.direct_exhausted && !f.h.direct_enabled);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 0);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) ==
         GPUI_RESOURCE);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 0) ==
         GPUI_RESOURCE); /* No off/on recovery after generation exhaustion. */

  memset(out, 0x47, sizeof(out));
  memset(text, 0x58, sizeof(text));
  unsigned char out_before[sizeof(out)];
  unsigned char text_before[sizeof(text)];
  memcpy(out_before, out, sizeof(out));
  memcpy(text_before, text, sizeof(text));
  assert(gpui_next(TEST_HOST, out) == -GPUI_RESOURCE);
  assert(memcmp(out, out_before, sizeof(out)) == 0 && f.h.count == queued);
  assert(next_v2(out, text, sizeof(text)) == -GPUI_RESOURCE);
  assert(memcmp(out, out_before, sizeof(out)) == 0 &&
         memcmp(text, text_before, sizeof(text)) == 0 && f.h.count == queued);

  release_key(&f.h, f.left); /* The held pre-exhaustion release is withheld. */
  assert(f.h.count == queued && f.h.error == GPUI_RESOURCE);
  press(&f.h, f.backspace); /* Fresh destructive key is withheld. */
  press(&f.h, f.right);     /* Fresh navigation key is withheld. */
  assert(f.h.count == queued && f.h.seq == sequence &&
         f.h.error == GPUI_RESOURCE);
  keyboard_leave(&f.h, f.h.keyboard, 0, f.h.surface);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) ==
         GPUI_RESOURCE); /* Exhaustion dominates blur/focus admission. */
  fixture_drop(&f);
}

static void test_repeated_press_and_modifier_compose_policy(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  double out[EVENT_CAPACITY];
  uint8_t text[16];

  /* Two repeated raw press callbacks produce two ordered key/text pairs and
   * one release record; this tests bookkeeping, not an OS repeat timer. */
  press(&f.h, f.a);
  press(&f.h, f.a);
  release_key(&f.h, f.a);
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(text[0] == 'a');
  next_kind(out, text, sizeof(text), 11);
  next_kind(out, text, sizeof(text), 13);
  assert(text[0] == 'a');
  next_kind(out, text, sizeof(text), 12);
  assert(next_v2(out, text, sizeof(text)) == 0);

  uint32_t shift_key = key_for_sym(&f.h, XKB_KEY_Shift_L, 0);
  uint32_t alt_key = key_for_sym(&f.h, XKB_KEY_Alt_L, 0);
  uint32_t e = key_for_sym(&f.h, XKB_KEY_e, 0);
  press(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, f.dead_acute);
  assert(next_v2(out, text, sizeof(text)) == 0);
  press(&f.h, shift_key); /* Modifier passes through; Compose stays pending. */
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  next_kind(out, text, sizeof(text), 11);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, shift_key);
  next_kind(out, text, sizeof(text), 12);
  press(&f.h, alt_key);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  next_kind(out, text, sizeof(text), 11);
  assert(next_v2(out, text, sizeof(text)) == 0);
  release_key(&f.h, alt_key);
  next_kind(out, text, sizeof(text), 12);
  press(&f.h, e);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 2 && text[0] == 0xc3 && text[1] == 0xa9);
  release_key(&f.h, e);
  assert(next_v2(out, text, sizeof(text)) == 0);

  /* Ctrl and Meta shortcuts cancel a pending Compose prefix without inserting
   * a control character. The following ordinary letter is not composed. */
  const char *reset_mods[] = {XKB_MOD_NAME_CTRL, XKB_MOD_NAME_LOGO};
  for (size_t i = 0; i < sizeof(reset_mods) / sizeof(reset_mods[0]); ++i) {
    press(&f.h, f.dead_acute);
    assert(next_v2(out, text, sizeof(text)) == 0);
    release_key(&f.h, f.dead_acute);
    assert(next_v2(out, text, sizeof(text)) == 0);
    set_modifiers(&f.h, modifier_bit(&f.h, reset_mods[i]), 0, 0);
    press(&f.h, e);
    assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
    next_kind(out, text, sizeof(text), 11);
    assert(next_v2(out, text, sizeof(text)) == 0);
    release_key(&f.h, e);
    next_kind(out, text, sizeof(text), 12);
    set_modifiers(&f.h, 0, 0, 0);
    press(&f.h, e);
    next_kind(out, text, sizeof(text), 11);
    next_kind(out, text, sizeof(text), 13);
    assert(out[8] == 1 && text[0] == 'e');
    release_key(&f.h, e);
    next_kind(out, text, sizeof(text), 12);
  }
  fixture_drop(&f);
}

static void test_window_release_resets_text_target(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  press(&f.h, f.a);
  press(&f.h, f.dead_acute);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  int old_epoch = f.h.direct_epoch;
  /* release_window must not dereference a fake native proxy. */
  f.h.surface = NULL;
  release_window(&f.h);
  assert(f.h.window == 0 && !f.h.direct_enabled &&
         f.h.direct_epoch == old_epoch + 1);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 0);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) ==
         -GPUI_STALE);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  assert(next_v2(out, text, sizeof(text)) == 0); /* Old-window pair is stale. */
  fixture_drop(&f);
}

static void test_pump_error_exit_and_clean_stop_quiesce(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  press(&f.h, f.a); /* Key+text records stay queued. */
  press(&f.h, f.dead_acute); /* A pending Compose prefix is also reset. */
  assert(f.h.count == 2 &&
         xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  int before_error = f.h.direct_epoch;
  f.h.wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  assert(f.h.wake_fd >= 0);
  f.h.error = GPUI_NATIVE; /* pump() returns before any display access. */
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_NATIVE);
  assert(f.h.state == 1 && !f.h.direct_enabled &&
         f.h.direct_epoch == before_error + 1);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
  int stopped_epoch = f.h.direct_epoch;
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) ==
         -GPUI_STOPPING);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 0);
  assert(gpui_exit(TEST_HOST) == GPUI_OK); /* Valid eventfd avoids wake failure. */
  assert(f.h.state == 1 && f.h.direct_epoch == stopped_epoch);

  double out[EVENT_CAPACITY];
  uint8_t text[16];
  memset(out, 0x29, sizeof(out));
  unsigned char out_before[sizeof(out)];
  memcpy(out_before, out, sizeof(out));
  assert(gpui_next(TEST_HOST, out) == -GPUI_UNSUPPORTED);
  assert(memcmp(out, out_before, sizeof(out)) == 0 && f.h.count == 2);
  assert(next_v2(out, text, sizeof(text)) == 0 && f.h.count == 0);
  uint32_t old_backspace = f.backspace;
  int before_key = f.h.count;
  press(&f.h, old_backspace);
  release_key(&f.h, old_backspace);
  assert(f.h.count == before_key && next_v2(out, text, sizeof(text)) == 0);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) ==
         GPUI_STOPPING);
  fixture_drop(&f);

  /* Stop a heap host so release_host can own/free its storage. A narrow test
   * free hook snapshots just that host; all other allocations use real free. */
  struct fixture *heap = calloc(1, sizeof(*heap));
  assert(heap);
  fixture_init(heap);
  arm(heap);
  press(&heap->h, heap->a);
  press(&heap->h, heap->dead_acute);
  int before_stop = heap->h.direct_epoch;
  struct xkb_compose_state *compose = heap->h.compose;
  heap->h.wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  assert(heap->h.wake_fd >= 0);
  heap->h.keyboard = NULL;
  heap->h.surface = NULL;
  test_host_free_watch = &heap->h;
  test_compose_unref_watch = compose;
  test_host_free_captured = 0;
  test_compose_unref_count = 0;
  test_stopped_compose_status = XKB_COMPOSE_CANCELLED;
  assert(gpui_stop(TEST_HOST) == GPUI_OK);
  assert(active == NULL && test_host_free_captured);
  assert(test_stopped_state == 1 && test_stopped_enabled == 0 &&
         test_stopped_epoch == before_stop + 1);
  assert(test_compose_unref_count == 1 &&
         test_stopped_compose_status == XKB_COMPOSE_NOTHING);
  test_host_free_watch = NULL;
  test_compose_unref_watch = NULL;
  free(heap); /* The test free hook deliberately retained only this host. */
}

static void test_non_dispatch_pump_error_quiesces(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  press(&f.h, f.a);
  press(&f.h, f.dead_acute);
  assert(f.h.count == 2 &&
         xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  int before = f.h.direct_epoch;
  f.h.frame = (struct wl_callback *)(uintptr_t)0x9012;
  f.h.error = GPUI_NATIVE;
  assert(settle_frame(&f.h) == GPUI_NATIVE); /* pump() returns before display. */
  assert(f.h.state == 1 && !f.h.direct_enabled &&
         f.h.direct_epoch == before + 1);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) ==
         -GPUI_STOPPING);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 0);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  assert(gpui_next(TEST_HOST, out) == -GPUI_UNSUPPORTED);
  assert(next_v2(out, text, sizeof(text)) == 0 && f.h.count == 0);
  int count = f.h.count;
  press(&f.h, f.backspace);
  release_key(&f.h, f.backspace);
  assert(f.h.count == count && next_v2(out, text, sizeof(text)) == 0);
  f.h.frame = NULL; /* Never pass the fake callback to release/Wayland code. */
  fixture_drop(&f);
}

static void test_healthy_clipboard_unsupported_preserves_target(void) {
  struct fixture f;
  fixture_init(&f);
  arm(&f);
  int epoch = f.h.direct_epoch;
  f.h.state = 0;
  /* These proxy identities exercise only early Unsupported branches; no
   * Wayland method is called because MIME is absent and input serial is zero. */
  f.h.data_device = (struct wl_data_device *)(uintptr_t)0xa001;
  f.h.data_manager = (struct wl_data_device_manager *)(uintptr_t)0xa002;
  f.h.selection_offer = (struct wl_data_offer *)(uintptr_t)0xa003;
  f.h.clipboard_has_utf8 = 0;
  f.h.clipboard_has_plain = 0;
  uint8_t bytes[] = {'x'};
  assert(gpui_read_clipboard(TEST_HOST) == GPUI_UNSUPPORTED);
  assert(gpui_write_clipboard(TEST_HOST, bytes, sizeof(bytes)) ==
         GPUI_UNSUPPORTED);
  assert(f.h.state == 0 && f.h.direct_enabled &&
         f.h.direct_epoch == epoch);
  f.h.data_device = NULL;
  f.h.data_manager = NULL;
  f.h.selection_offer = NULL;
  fixture_drop(&f);
}

static void test_clipboard_flush_display_failure_quiesces(void) {
  struct fixture f;
  fixture_init(&f);
  reset_proxy_mocks();
  arm(&f);
  press(&f.h, f.a);
  press(&f.h, f.dead_acute);
  assert(f.h.count == 2 &&
         xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_COMPOSING);
  int old_epoch = f.h.direct_epoch;
  f.h.wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
  assert(f.h.wake_fd >= 0);
  /* Clipboard receive/flush/error are test mocks: no fake proxy reaches a real
   * Wayland method, and the flush failure happens before pump/socket access. */
  f.h.data_device = (struct wl_data_device *)(uintptr_t)0xb001;
  f.h.selection_offer = (struct wl_data_offer *)(uintptr_t)0xb002;
  f.h.clipboard_has_utf8 = 1;
  mock_display_flush_fail = 1;
  mock_display_error = EIO; /* Avoid the protocol-error query on fake display. */
  assert(gpui_read_clipboard(TEST_HOST) == GPUI_NATIVE);
  assert(mock_offer_receive_calls == 1 && mock_display_flush_calls == 1 &&
         mock_display_error_calls == 1 && mock_offer_receive_fd >= 0);
  errno = 0;
  assert(fcntl(mock_offer_receive_fd, F_GETFD) == -1 && errno == EBADF);
  assert(f.h.error == GPUI_NATIVE && f.h.state == 1 &&
         !f.h.direct_enabled && f.h.direct_epoch == old_epoch + 1);
  assert(xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
  assert(gpui_direct_keyboard_text_epoch(TEST_HOST, TEST_WINDOW) ==
         -GPUI_STOPPING);
  assert(gpui_direct_keyboard_text_active(TEST_HOST) == 0);

  double out[EVENT_CAPACITY];
  uint8_t text[16];
  memset(out, 0x3a, sizeof(out));
  unsigned char out_before[sizeof(out)];
  memcpy(out_before, out, sizeof(out));
  assert(gpui_next(TEST_HOST, out) == -GPUI_UNSUPPORTED);
  assert(memcmp(out, out_before, sizeof(out)) == 0 && f.h.count == 2);
  assert(next_v2(out, text, sizeof(text)) == 0 && f.h.count == 0);

  /* A later display failure preserves the first recorded native status and
   * cannot consume another target epoch or resurrect Compose state. */
  mock_display_error = ENOTCONN;
  errno = EIO;
  assert(display_failure(&f.h, "second clipboard failure") == GPUI_NATIVE);
  assert(mock_display_error_calls == 2 && f.h.error == GPUI_NATIVE &&
         f.h.direct_epoch == old_epoch + 1 &&
         xkb_compose_state_get_status(f.h.compose) == XKB_COMPOSE_NOTHING);
  assert(gpui_exit(TEST_HOST) == GPUI_OK);
  assert(f.h.direct_epoch == old_epoch + 1 && f.h.state == 1);

  int count = f.h.count;
  press(&f.h, f.backspace);
  release_key(&f.h, f.backspace);
  assert(f.h.count == count && next_v2(out, text, sizeof(text)) == 0);
  f.h.data_device = NULL;
  f.h.selection_offer = NULL;
  fixture_drop(&f);
}

int main(void) {
  test_order_modifiers_and_compose();
  test_v2_validation_copy_and_v1_guard();
  test_utf8_lengths_and_canaries();
  test_atomic_capacity_and_legacy_mode_off();
  test_stale_filtering_and_reset_epochs();
  test_keymap_and_device_resets();
  test_global_seat_remove_rejects_old_keyboard();
  test_seat_clipboard_lifetime_and_rebind();
  test_epoch_exhaustion_fails_closed();
  test_repeated_press_and_modifier_compose_policy();
  test_window_release_resets_text_target();
  test_pump_error_exit_and_clean_stop_quiesce();
  test_non_dispatch_pump_error_quiesces();
  test_healthy_clipboard_unsupported_preserves_target();
  test_clipboard_flush_display_failure_quiesces();
  puts("GPUI_DIRECT_TEXT_HEADLESS status=passed tiers=callback,queue,decoder");
  return 0;
}
