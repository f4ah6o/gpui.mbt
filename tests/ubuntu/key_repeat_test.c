#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <stdint.h>
#include <time.h>
#include <wayland-client.h>

/* Extend the existing real-XKB fixture. Every additional display/proxy call
 * reached by these pump tests is mocked before including the private backend. */
struct host;
static int clock_enabled, clock_failed, poll_advance, poll_error;
static int64_t clock_ms;
static int poll_timeout, poll_calls, cancel_calls;
static short poll_events;
static void (*pending_action)(struct host *);
static void (*incoming_action)(struct host *);
static struct host *pump_host;
static uint32_t bound_version;
static int keyboard_released, keyboard_destroyed;
static int pointer_released, pointer_destroyed, seat_destroyed;

static int repeat_clock_gettime(clockid_t kind, struct timespec *out) {
  if (!clock_enabled)
    return clock_gettime(kind, out);
  assert(kind == CLOCK_MONOTONIC);
  if (clock_failed) {
    errno = EIO;
    return -1;
  }
  out->tv_sec = (time_t)(clock_ms / 1000);
  out->tv_nsec = (long)(clock_ms % 1000) * 1000000;
  return 0;
}
static int repeat_prepare_read(struct wl_display *display) {
  (void)display;
  return pending_action ? -1 : 0;
}
static int repeat_dispatch_pending(struct wl_display *display) {
  (void)display;
  void (*action)(struct host *) = pending_action ? pending_action : incoming_action;
  if (pending_action)
    pending_action = NULL;
  else
    incoming_action = NULL;
  if (action)
    action(pump_host);
  return 0;
}
static int repeat_display_fd(struct wl_display *display) {
  (void)display;
  return 123;
}
static void repeat_cancel_read(struct wl_display *display) {
  (void)display;
  ++cancel_calls;
}
static int repeat_read_events(struct wl_display *display) {
  (void)display;
  assert(poll_events & POLLIN);
  return 0;
}
static int repeat_poll(struct pollfd *fds, nfds_t count, int timeout) {
  assert(count == 2 && pump_host);
  ++poll_calls;
  poll_timeout = timeout;
  if (poll_error) {
    errno = poll_error;
    return -1;
  }
  if (poll_advance)
    clock_ms += timeout;
  fds[0].revents = poll_events;
  fds[1].revents = 0;
  return poll_events != 0;
}
static void *repeat_registry_bind(struct wl_registry *registry, uint32_t name,
                                 const struct wl_interface *interface,
                                 uint32_t version) {
  (void)registry;
  (void)name;
  assert(interface == &wl_seat_interface);
  bound_version = version;
  return (void *)(uintptr_t)0x9001;
}
static int repeat_seat_listener(struct wl_seat *seat,
                                const struct wl_seat_listener *listener, void *data) {
  (void)seat;
  (void)data;
  assert(listener->capabilities && listener->name);
  return 0;
}
static struct wl_keyboard *repeat_get_keyboard(struct wl_seat *seat) {
  (void)seat;
  return (struct wl_keyboard *)(uintptr_t)0x9002;
}
static struct wl_pointer *repeat_get_pointer(struct wl_seat *seat) {
  (void)seat;
  return (struct wl_pointer *)(uintptr_t)0x9003;
}
static int repeat_keyboard_listener(struct wl_keyboard *keyboard,
                                    const struct wl_keyboard_listener *listener,
                                    void *data) {
  (void)keyboard;
  (void)data;
  assert(listener->repeat_info);
  return 0;
}
static int repeat_pointer_listener(struct wl_pointer *pointer,
                                   const struct wl_pointer_listener *listener,
                                   void *data) {
  (void)pointer;
  (void)data;
  assert(listener->axis && !listener->frame);
  return 0;
}
static void repeat_keyboard_release(struct wl_keyboard *keyboard) {
  (void)keyboard;
  ++keyboard_released;
}
static void repeat_keyboard_destroy(struct wl_keyboard *keyboard) {
  (void)keyboard;
  ++keyboard_destroyed;
}
static void repeat_pointer_release(struct wl_pointer *pointer) {
  (void)pointer;
  ++pointer_released;
}
static void repeat_pointer_destroy(struct wl_pointer *pointer) {
  (void)pointer;
  ++pointer_destroyed;
}
static void repeat_seat_destroy(struct wl_seat *seat) {
  (void)seat;
  ++seat_destroyed;
}
#define clock_gettime repeat_clock_gettime
#define poll repeat_poll
#define wl_display_prepare_read repeat_prepare_read
#define wl_display_dispatch_pending repeat_dispatch_pending
#define wl_display_get_fd repeat_display_fd
#define wl_display_cancel_read repeat_cancel_read
#define wl_display_read_events repeat_read_events
#define wl_registry_bind repeat_registry_bind
#define wl_seat_add_listener repeat_seat_listener
#define wl_seat_get_keyboard repeat_get_keyboard
#define wl_seat_get_pointer repeat_get_pointer
#define wl_keyboard_add_listener repeat_keyboard_listener
#define wl_pointer_add_listener repeat_pointer_listener
#define wl_keyboard_release repeat_keyboard_release
#define wl_keyboard_destroy repeat_keyboard_destroy
#define wl_pointer_release repeat_pointer_release
#define wl_pointer_destroy repeat_pointer_destroy
#define wl_seat_destroy repeat_seat_destroy
#define main direct_text_existing_main
#include "direct_text_test.c"
#undef main

static void repeat_fixture(struct fixture *f, int rate, int delay) {
  clock_enabled = 1;
  clock_failed = poll_advance = poll_error = 0;
  clock_ms = 1000;
  poll_timeout = -1;
  poll_calls = cancel_calls = 0;
  poll_events = 0;
  pending_action = incoming_action = NULL;
  reset_proxy_mocks();
  fixture_init(f);
  f->h.seat_version = 4;
  pump_host = &f->h;
  if (rate >= 0)
    keyboard_repeat_info(&f->h, f->h.keyboard, rate, delay);
  arm(f);
}
static void drain_initial(struct fixture *f, uint32_t key, int text_length) {
  double out[EVENT_CAPACITY];
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES];
  press(&f->h, key);
  next_kind(out, text, sizeof(text), 11);
  assert(out[7] == 0);
  if (text_length) {
    next_kind(out, text, sizeof(text), 13);
    assert(out[8] == text_length && out[7] == 0);
  }
  assert(next_v2(out, text, sizeof(text)) == 0);
}
static void expect_repeat(struct fixture *f, const uint8_t *expected, int length) {
  double out[EVENT_CAPACITY];
  uint8_t text[GPUI_DIRECT_TEXT_MAX_BYTES];
  assert(f->h.count == 1 + (length > 0));
  next_kind(out, text, sizeof(text), 11);
  assert(out[7] == 1 && out[9] == f->h.repeat.modifiers);
  if (length) {
    next_kind(out, text, sizeof(text), 13);
    assert(out[7] == 0 && out[8] == length);
    assert(memcmp(text, expected, (size_t)length) == 0);
  }
  assert(next_v2(out, text, sizeof(text)) == 0);
}
static void pending_press(struct host *h) {
  press(h, key_for_sym(h, XKB_KEY_a, 0));
}
static void incoming_release(struct host *h) {
  release_key(h, key_for_sym(h, XKB_KEY_a, 0));
}
static void incoming_blur(struct host *h) {
  keyboard_leave(h, h->keyboard, 0, h->surface);
}
static void test_repeat_dispatch_timing(void) {
  struct fixture f;
  repeat_fixture(&f, 25, 600);
  pending_action = pending_press;
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK);
  assert(poll_timeout == 0 && f.h.count == 2 && f.h.repeat.deadline == 1600);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  next_kind(out, text, sizeof(text), 11);
  assert(out[7] == 0);
  next_kind(out, text, sizeof(text), 13);
  clock_ms = 1599;
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK);
  assert(poll_timeout == 1 && f.h.count == 0);
  poll_advance = 1;
  uint32_t serial = f.h.input_serial;
  int serial_window = f.h.input_serial_window;
  enum input_serial_origin serial_origin = f.h.input_serial_origin;
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK);
  assert(poll_timeout == 1 && clock_ms == 1600);
  assert(f.h.input_serial == serial && f.h.input_serial_window == serial_window &&
         f.h.input_serial_origin == serial_origin);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  poll_advance = 0;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  clock_ms = 100000;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  assert(f.h.repeat.deadline == 100040);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  clock_ms = 100040;
  poll_events = POLLIN;
  incoming_action = incoming_release;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && !f.h.repeat.armed);
  next_kind(out, text, sizeof(text), 12);
  assert(out[7] == 0 && next_v2(out, text, sizeof(text)) == 0);
  fixture_drop(&f);

  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  clock_ms = 2000;
  pending_action = incoming_release;
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK);
  assert(poll_timeout == 0 && !f.h.repeat.armed && f.h.count == 1);
  fixture_drop(&f);

  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  poll_events = POLLIN;
  incoming_action = incoming_blur;
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK && !f.h.repeat.armed);
  next_kind(out, text, sizeof(text), 6);
  assert(next_v2(out, text, sizeof(text)) == 0);
  fixture_drop(&f);
}
static void test_repeat_backpressure_and_atomicity(void) {
  struct fixture f;
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  event(&f.h, 7, 0, 1, 2);
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK);
  assert(poll_timeout == 0 && f.h.count == 1 && f.h.repeat.deadline == 1040);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  next_kind(out, text, sizeof(text), 7);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  /* A stalled reader cannot accumulate repeats, even near queue capacity. */
  for (int i = 0; i < QUEUE_CAPACITY - 1; ++i)
    event(&f.h, 7, 0, 1, 2);
  clock_ms = 5000;
  int seq = f.h.seq;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  assert(f.h.count == QUEUE_CAPACITY - 1 && f.h.seq == seq);
  while (next_v2(out, text, sizeof(text)) == 1) {}
  /* The real dispatch emitter must reserve both sequences before either half. */
  f.h.seq = INT_MAX - 1;
  clock_ms = 5040;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_RESOURCE);
  assert(f.h.count == 0 && f.h.seq == INT_MAX - 1 && !f.h.repeat.armed);
  assert(f.h.state == 1 && !f.h.direct_enabled);
  fixture_drop(&f);
}
static void test_repeat_policy_limits_and_clock(void) {
  struct fixture f;
  repeat_fixture(&f, INT_MAX, 0);
  drain_initial(&f, f.a, 1);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  assert(f.h.repeat.deadline == 1001);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  clock_ms = 1001;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  keyboard_repeat_info(&f.h, f.h.keyboard, INT_MAX, 0);
  assert(f.h.repeat.armed);
  keyboard_repeat_info(&f.h, f.h.keyboard, 25, 0);
  assert(!f.h.repeat.armed);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  drain_initial(&f, f.a, 1);
  keyboard_repeat_info(&f.h, f.h.keyboard, 0, INT_MAX);
  assert(!f.h.repeat.armed);
  drain_initial(&f, f.a, 1);
  assert(!f.h.repeat.armed);
  fixture_drop(&f);

  repeat_fixture(&f, 60, 0);
  drain_initial(&f, f.a, 1);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  assert(f.h.repeat.deadline == 1017);
  fixture_drop(&f);

  repeat_fixture(&f, 1, INT_MAX);
  drain_initial(&f, f.a, 1);
  assert(f.h.repeat.deadline == 1000LL + INT_MAX);
  assert(gpui_dispatch(TEST_HOST, 60000) == GPUI_OK && poll_timeout == 60000);
  fixture_drop(&f);
  for (int negative = 0; negative < 2; ++negative) {
    repeat_fixture(&f, 25, 0);
    drain_initial(&f, f.a, 1);
    keyboard_repeat_info(&f.h, f.h.keyboard, negative ? 25 : -1, negative ? -1 : 0);
    assert(!f.h.repeat.armed && gpui_dispatch(TEST_HOST, 0) == GPUI_INVALID);
    assert(f.h.state == 1);
    fixture_drop(&f);
  }
  for (int failure = 0; failure < 3; ++failure) {
    repeat_fixture(&f, 25, 0);
    drain_initial(&f, f.a, 1);
    if (failure == 0)
      clock_failed = 1;
    else if (failure == 1)
      clock_ms = 999;
    else
      clock_ms = INT64_MAX;
    int expected = failure == 2 ? GPUI_RESOURCE : GPUI_NATIVE;
    assert(gpui_dispatch(TEST_HOST, 0) == expected);
    assert(!f.h.repeat.armed && f.h.count == 0 && f.h.state == 1);
    fixture_drop(&f);
  }
  repeat_fixture(&f, 25, 1);
  clock_ms = INT64_MAX;
  press(&f.h, f.a);
  assert(!f.h.repeat.armed && f.h.error == GPUI_RESOURCE);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_RESOURCE);
  fixture_drop(&f);
}
static void test_repeat_compose_modifiers_and_copy(void) {
  struct fixture f;
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.q, 1);
  drain_initial(&f, f.a, 1);
  set_modifiers(&f.h, 0, 0, 0);
  assert(f.h.repeat.armed);
  set_modifiers(&f.h, modifier_bit(&f.h, XKB_MOD_NAME_SHIFT), 0, 0);
  assert(!f.h.repeat.armed);
  drain_initial(&f, f.a, 1);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"A", 1);
  release_key(&f.h, f.q); /* Unrelated release does not stop the active key. */
  assert(f.h.repeat.armed);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  next_kind(out, text, sizeof(text), 12);
  set_modifiers(&f.h, 0, 0, 0);
  press(&f.h, f.dead_acute);
  assert(!f.h.repeat.armed && f.h.count == 0);
  release_key(&f.h, f.dead_acute);
  uint32_t e = key_for_sym(&f.h, XKB_KEY_e, 0);
  press(&f.h, e);
  next_kind(out, text, sizeof(text), 13);
  assert(out[8] == 2 && text[0] == 0xc3 && text[1] == 0xa9);
  assert(!f.h.repeat.armed && gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  /* Real XKB AltGr text is cached and independently copied into queue slots. */
  set_modifiers(&f.h, modifier_bit(&f.h, "Mod5"), 0, 0);
  int length = xkb_state_key_get_utf8(f.h.keys, f.level3_key + 8,
                                    (char *)text, sizeof(text));
  assert(length > 0);
  uint8_t expected[16];
  memcpy(expected, text, (size_t)length);
  drain_initial(&f, f.level3_key, length);
  assert(f.h.repeat.armed);
  f.h.read = QUEUE_CAPACITY - 1; /* Exercise key/text wrapping independently. */
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 2);
  f.h.repeat.text[0] ^= 1;
  expect_repeat(&f, expected, length);
  f.h.repeat.text[0] ^= 1;
  set_modifiers(&f.h, 0, 0, 0);
  drain_initial(&f, f.left, 0);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, NULL, 0);
  press(&f.h, key_for_sym(&f.h, XKB_KEY_Shift_L, 0));
  assert(!f.h.repeat.armed);
  fixture_drop(&f);
}
static void test_repeat_extra_freshness(void) {
  struct fixture f;
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.q, 1);
  drain_initial(&f, f.a, 1);
  release_key(&f.h, f.a);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  next_kind(out, text, sizeof(text), 12);
  clock_ms = 9000;
  assert(f.h.direct_keys[f.q].pressed && !f.h.repeat.armed);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  drain_initial(&f, f.a, 1);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  next_kind(out, text, sizeof(text), 11);
  assert(out[7] == 1 && f.h.count == 1);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) == GPUI_OK);
  assert(next_v2(out, text, sizeof(text)) == 0 && !f.h.repeat.armed);
  clock_ms = 10000;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  drain_initial(&f, f.a, 1);
  int portable_modifiers = f.h.modifiers;
  set_modifiers(&f.h, modifier_bit(&f.h, "Mod5"), 0, 0);
  assert(f.h.modifiers == portable_modifiers && !f.h.repeat.armed);
  set_modifiers(&f.h, 0, 0, 0);
  struct xkb_rule_names names = {.layout = "us,de"};
  struct xkb_keymap *map = xkb_keymap_new_from_names(
      f.h.xkb, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  assert(map && xkb_keymap_num_layouts(map) == 2);
  uint32_t size;
  int fd = keymap_fd(map, &size);
  keyboard_keymap(&f.h, f.h.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
  xkb_keymap_unref(map);
  f.a = key_for_sym(&f.h, XKB_KEY_a, 0);
  drain_initial(&f, f.a, 1);
  assert(f.h.repeat.armed);
  keyboard_modifiers(&f.h, f.h.keyboard, 0, 0, 0, 0, 1);
  assert(xkb_state_serialize_layout(f.h.keys, XKB_STATE_LAYOUT_EFFECTIVE) == 1);
  assert(f.h.modifiers == 0 && !f.h.repeat.armed);
  fixture_drop(&f);

  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  keyboard_key(&f.h, f.h.keyboard, 1, 0, GPUI_DIRECT_KEY_CAPACITY,
               WL_KEYBOARD_KEY_STATE_PRESSED);
  assert(f.h.error == GPUI_INVALID && !f.h.repeat.armed);
  fixture_drop(&f);

  /* An independently authored single Unicode key exercises four-byte replay. */
  repeat_fixture(&f, 25, 0);
  const char unicode_map[] =
      "xkb_keymap {"
      "xkb_keycodes { minimum=8; maximum=16; <TEST>=8; };"
      "xkb_types { type \"ONE_LEVEL\" { modifiers=None; level_name[Level1]=\"Base\"; }; };"
      "xkb_compatibility {};"
      "xkb_symbols { key <TEST> { type=\"ONE_LEVEL\", repeat=Yes, [ U1F44B ] }; };"
      "};";
  map = xkb_keymap_new_from_string(f.h.xkb, unicode_map, XKB_KEYMAP_FORMAT_TEXT_V1, 0);
  assert(map);
  fd = keymap_fd(map, &size);
  keyboard_keymap(&f.h, f.h.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
  xkb_keymap_unref(map);
  f.a = key_for_sym(&f.h, xkb_utf32_to_keysym(0x1f44b), 0);
  drain_initial(&f, f.a, 4);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  const uint8_t wave[] = {0xf0, 0x9f, 0x91, 0x8b};
  expect_repeat(&f, wave, sizeof(wave));
  fixture_drop(&f);

  struct fixture *heap = calloc(1, sizeof(*heap));
  assert(heap);
  repeat_fixture(heap, 25, 0);
  drain_initial(heap, heap->a, 1);
  heap->h.surface = NULL;
  test_host_free_watch = &heap->h;
  test_host_free_captured = 0;
  assert(gpui_stop(TEST_HOST) == GPUI_OK);
  assert(active == NULL && test_host_free_captured && !heap->h.repeat.armed);
  test_host_free_watch = NULL;
  free(heap);
}
static void test_repeat_lifecycle_and_non_dispatch(void) {
  struct fixture f;
  for (int action = 0; action < 8; ++action) {
    repeat_fixture(&f, 25, 0);
    drain_initial(&f, f.a, 1);
    switch (action) {
    case 0:
      assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 0) == GPUI_OK);
      arm(&f); /* Re-arm cannot resurrect a still-held candidate. */
      break;
    case 1:
      assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 1) == GPUI_OK);
      break;
    case 2: {
      uint32_t held_key = f.a;
      struct wl_array held = {.size = sizeof(held_key), .data = &held_key};
      keyboard_leave(&f.h, f.h.keyboard, 0, f.h.surface);
      keyboard_enter(&f.h, f.h.keyboard, 0, f.h.surface, &held);
      arm(&f);
      break;
    }
    case 3: {
      uint32_t size;
      int fd = keymap_fd(f.h.keymap, &size);
      keyboard_keymap(&f.h, f.h.keyboard, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
      break;
    }
    case 4:
      seat_caps(&f.h, f.h.seat, 0);
      assert(f.h.repeat_rate == 0);
      break;
    case 5:
      global_remove(&f.h, NULL, f.h.seat_name);
      assert(f.h.repeat_rate == 0 && f.h.seat_version == 0);
      break;
    case 6:
      assert(gpui_close(TEST_HOST, TEST_WINDOW) == GPUI_OK);
      break;
    case 7:
      toplevel_close(&f.h, NULL);
      break;
    }
    assert(!f.h.repeat.armed);
    assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && !f.h.repeat.armed);
    for (int i = 0; i < f.h.count; ++i)
      assert(f.h.queue[(f.h.read + i) % QUEUE_CAPACITY][0] != 13);
    fixture_drop(&f);
  }
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  clock_ms = 10000;
  assert(pump(&f.h, 100) == GPUI_OK && poll_timeout == 100 && f.h.count == 0);
  assert(f.h.repeat.armed); /* Internal pumps do not synthesize or owe ticks. */
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
  expect_repeat(&f, (const uint8_t *)"a", 1);
  f.h.surface = NULL;
  release_window(&f.h);
  assert(!f.h.repeat.armed);
  fixture_drop(&f);

  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  poll_error = EIO;
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_NATIVE && !f.h.repeat.armed);
  fixture_drop(&f);
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  f.h.count = QUEUE_CAPACITY;
  event(&f.h, 7, 0, 0, 0);
  assert(f.h.error == GPUI_RESOURCE && !f.h.repeat.armed);
  fixture_drop(&f);
}
static void test_repeat_versions_and_legacy(void) {
  for (uint32_t version = 1; version <= 9; ++version) {
    struct fixture f;
    repeat_fixture(&f, 25, 0);
    f.h.keyboard = NULL;
    f.h.seat = NULL;
    keyboard_released = keyboard_destroyed = pointer_released = pointer_destroyed = 0;
    global(&f.h, NULL, 42, "wl_seat", version);
    assert(bound_version == (version < 4 ? version : 4));
    assert(f.h.seat_version == bound_version);
    seat_caps(&f.h, f.h.seat, WL_SEAT_CAPABILITY_KEYBOARD | WL_SEAT_CAPABILITY_POINTER);
    seat_name(&f.h, f.h.seat, "fixture-seat");
    seat_caps(&f.h, f.h.seat, 0);
    assert(keyboard_released == (version >= 3));
    assert(pointer_released == (version >= 3));
    assert(keyboard_destroyed == (version < 3));
    assert(pointer_destroyed == (version < 3));
    global_remove(&f.h, NULL, 42);
    fixture_drop(&f);
  }
  struct fixture f;
  repeat_fixture(&f, 25, 0);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 0) == GPUI_OK);
  press(&f.h, f.a);
  assert(!f.h.repeat.armed);
  double out[EVENT_CAPACITY];
  assert(gpui_next(TEST_HOST, out) == 1 && out[0] == 11 && out[7] == 0);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  fixture_drop(&f);
  repeat_fixture(&f, -1, 0); /* No repeat_info callback at all. */
  drain_initial(&f, f.a, 1);
  clock_ms = 9000;
  assert(!f.h.repeat.armed && gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 0);
  fixture_drop(&f);
  repeat_fixture(&f, 0, 0);
  drain_initial(&f, f.a, 1);
  assert(!f.h.repeat.armed);
  f.h.seat_version = 3;
  keyboard_repeat_info(&f.h, f.h.keyboard, 25, 0);
  drain_initial(&f, f.a, 1);
  assert(!f.h.repeat.armed && f.h.repeat_rate == 0);
  fixture_drop(&f);
}
static void test_repeat_command_keys_and_v1_guard(void) {
  const char *mods[] = {XKB_MOD_NAME_CTRL, XKB_MOD_NAME_LOGO};
  for (int i = 0; i < 2; ++i) {
    struct fixture f;
    repeat_fixture(&f, 25, 0);
    set_modifiers(&f.h, modifier_bit(&f.h, mods[i]), 0, 0);
    drain_initial(&f, f.a, 0);
    assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK);
    expect_repeat(&f, NULL, 0);
    fixture_drop(&f);
  }
  struct fixture f;
  repeat_fixture(&f, 25, 0);
  drain_initial(&f, f.a, 1);
  assert(gpui_dispatch(TEST_HOST, 0) == GPUI_OK && f.h.count == 2);
  double out[EVENT_CAPACITY];
  uint8_t text[16];
  assert(gpui_next(TEST_HOST, out) == -GPUI_UNSUPPORTED);
  assert(gpui_direct_keyboard_text_mode(TEST_HOST, TEST_WINDOW, 0) == GPUI_OK);
  assert(gpui_next(TEST_HOST, out) == -GPUI_UNSUPPORTED && f.h.count == 2);
  assert(next_v2(out, text, sizeof(text)) == 0 && f.h.count == 0);
  fixture_drop(&f);
}
int main(void) {
  assert(direct_text_existing_main() == 0);
  fprintf(stderr, "repeat case: dispatch_timing\n");
  test_repeat_dispatch_timing();
  fprintf(stderr, "repeat case: backpressure_and_atomicity\n");
  test_repeat_backpressure_and_atomicity();
  fprintf(stderr, "repeat case: policy_limits_and_clock\n");
  test_repeat_policy_limits_and_clock();
  fprintf(stderr, "repeat case: compose_modifiers_and_copy\n");
  test_repeat_compose_modifiers_and_copy();
  fprintf(stderr, "repeat case: extra_freshness\n");
  test_repeat_extra_freshness();
  fprintf(stderr, "repeat case: lifecycle_and_non_dispatch\n");
  test_repeat_lifecycle_and_non_dispatch();
  fprintf(stderr, "repeat case: versions_and_legacy\n");
  test_repeat_versions_and_legacy();
  fprintf(stderr, "repeat case: command_keys_and_v1_guard\n");
  test_repeat_command_keys_and_v1_guard();
  puts("GPUI_KEY_REPEAT_HEADLESS status=passed tiers=callback,queue,dispatch-clock");
  return 0;
}
