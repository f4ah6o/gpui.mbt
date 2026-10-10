#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <wayland-client-protocol.h>

static int output_destroy_calls;
static struct wl_output *last_destroyed_output;
static void test_output_destroy(struct wl_output *output) {
  ++output_destroy_calls;
  last_destroyed_output = output;
}

/* Keep global_remove on the real reset path without a compositor proxy. */
#define wl_output_destroy(output) test_output_destroy(output)
static int callback_destroy_calls;
static struct wl_callback *last_destroyed_callback;
static void test_callback_destroy(struct wl_callback *callback) {
  ++callback_destroy_calls;
  last_destroyed_callback = callback;
}
#define wl_callback_destroy(callback) test_callback_destroy(callback)
#include "../../ubuntu/backend.c"
#undef wl_callback_destroy
#undef wl_output_destroy

static struct host new_host(void) {
  struct host h = {0};
  h.width = 640;
  h.height = 480;
  h.scale = 1;
  h.wake_fd = -1;
  return h;
}

static struct wl_output *fake_output(uintptr_t value) {
  return (struct wl_output *)value;
}

static void test_batch_is_invisible_until_done_and_commits_together(void) {
  struct host h = new_host();
  struct wl_output *proxy = fake_output(0x101);
  init_output(&h.outputs[0], proxy, 11);
  h.outputs[0].entered = 1;

  output_geometry(&h, proxy, 120, -40, 600, 340, 2, "Make", "Model",
                  WL_OUTPUT_TRANSFORM_90);
  output_mode(&h, proxy, WL_OUTPUT_MODE_PREFERRED, 3840, 2160, 60000);
  output_mode(&h, proxy, WL_OUTPUT_MODE_CURRENT, 2560, 1440, 59940);
  output_mode(&h, proxy, WL_OUTPUT_MODE_PREFERRED, 4096, 2160, 60000);
  output_scale(&h, proxy, 4);

  assert(h.outputs[0].committed.scale == 1);
  assert(h.outputs[0].committed.x == 0);
  assert(h.outputs[0].pending.scale == 4);
  assert(h.outputs[0].pending.x == 120);
  assert(h.scale == 1);
  update_scale(&h);
  assert(h.scale == 1);

  output_done(&h, proxy);
  assert(h.outputs[0].committed.scale == 4);
  assert(h.outputs[0].committed.x == 120);
  assert(h.outputs[0].committed.y == -40);
  assert(h.outputs[0].committed.physical_width == 600);
  assert(h.outputs[0].committed.physical_height == 340);
  assert(h.outputs[0].committed.subpixel == 2);
  assert(h.outputs[0].committed.transform == WL_OUTPUT_TRANSFORM_90);
  assert(h.outputs[0].committed.mode_flags == WL_OUTPUT_MODE_CURRENT);
  assert(h.outputs[0].committed.mode_width == 2560);
  assert(h.outputs[0].committed.mode_height == 1440);
  assert(h.outputs[0].committed.mode_refresh == 59940);
  assert(h.scale == 4);

  /* A scale-only batch retains geometry/mode but still waits for done. */
  output_scale(&h, proxy, 2);
  assert(h.outputs[0].committed.scale == 4);
  update_scale(&h);
  assert(h.scale == 4);
  output_done(&h, proxy);
  assert(h.outputs[0].committed.scale == 2);
  assert(h.outputs[0].committed.mode_width == 2560);
  assert(h.outputs[0].committed.transform == WL_OUTPUT_TRANSFORM_90);
  assert(h.scale == 2);

  output_scale(&h, proxy, 0);
  assert(h.outputs[0].committed.scale == 2);
  assert(h.outputs[0].pending.scale == 1);
  assert(h.scale == 2);
  output_done(&h, proxy);
  assert(h.outputs[0].committed.scale == 1);
  assert(h.scale == 1);
}

static void test_scale_event_precedes_following_input_and_frame(void) {
  struct host h = new_host();
  struct wl_output *proxy = fake_output(0x181);
  struct wl_pointer *pointer = (struct wl_pointer *)(uintptr_t)0x182;
  h.window = 97; /* event() requires a live window to queue notifications. */
  h.pointer = pointer;
  init_output(&h.outputs[0], proxy, 18);
  h.outputs[0].entered = 1;

  output_scale(&h, proxy, 2);
  assert(h.outputs[0].committed.scale == 1);
  assert(h.outputs[0].pending.scale == 2);
  assert(h.scale == 1 && h.count == 0 && h.seq == 0);

  output_done(&h, proxy);
  assert(h.outputs[0].committed.scale == 2);
  assert(h.scale == 2 && h.count == 1 && h.seq == 1 && h.error == 0);
  int scale_slot = h.read;
  assert(h.queue[scale_slot][0] == 2);
  assert(h.queue[scale_slot][1] == h.window);
  assert(h.queue[scale_slot][2] == 1);
  assert(h.queue[scale_slot][3] == 2);
  assert(h.queue[scale_slot][4] == h.width);
  assert(h.queue[scale_slot][5] == h.height);

  pointer_motion(&h, pointer, 0, wl_fixed_from_double(15.5),
                 wl_fixed_from_double(25.25));
  assert(h.count == 2 && h.seq == 2);
  int input_slot = (h.read + 1) % QUEUE_CAPACITY;
  assert(h.queue[input_slot][0] == 7);
  assert(h.queue[input_slot][2] == 2);
  assert(h.queue[input_slot][3] == 2);
  assert(h.queue[input_slot][6] == 15.5);
  assert(h.queue[input_slot][7] == 25.25);

  struct wl_callback *callback = (struct wl_callback *)(uintptr_t)0x701;
  h.frame = callback;
  callback_destroy_calls = 0;
  last_destroyed_callback = NULL;
  frame_done(&h, callback, 0);
  assert(callback_destroy_calls == 1);
  assert(last_destroyed_callback == callback);
  assert(h.frame == NULL && h.count == 3 && h.seq == 3);
  int frame_slot = (h.read + 2) % QUEUE_CAPACITY;
  assert(h.queue[frame_slot][0] == 5);
  assert(h.queue[frame_slot][2] == 3);
  assert(h.queue[frame_slot][3] == 2);

  /* An unchanged commit must not emit a duplicate scale notification. */
  output_done(&h, proxy);
  assert(h.count == 3 && h.seq == 3 && h.scale == 2);
}

static void test_callback_permutations_and_unknown_proxy(void) {
  struct host h = new_host();
  struct wl_output *proxy = fake_output(0x202);
  struct wl_output *unknown = fake_output(0x303);
  init_output(&h.outputs[0], proxy, 21);

  output_scale(&h, proxy, 3);
  output_mode(&h, proxy, WL_OUTPUT_MODE_CURRENT, 1920, 1080, 60000);
  output_geometry(&h, proxy, -1920, 0, 520, 290, 1, "A", "B",
                  WL_OUTPUT_TRANSFORM_NORMAL);
  output_done(&h, proxy);
  assert(h.outputs[0].committed.scale == 3);
  assert(h.outputs[0].committed.mode_width == 1920);
  assert(h.outputs[0].committed.mode_height == 1080);
  assert(h.outputs[0].committed.x == -1920);
  assert(h.outputs[0].committed.physical_width == 520);
  assert(h.outputs[0].committed.transform == WL_OUTPUT_TRANSFORM_NORMAL);

  output_scale(&h, unknown, 8);
  output_mode(&h, unknown, WL_OUTPUT_MODE_CURRENT, 7680, 4320, 60000);
  output_geometry(&h, unknown, 0, 0, 0, 0, 0, "X", "Y",
                  WL_OUTPUT_TRANSFORM_180);
  output_done(&h, unknown);
  output_scale(&h, NULL, 9);
  output_mode(&h, NULL, WL_OUTPUT_MODE_CURRENT, 9000, 9000, 90000);
  output_geometry(&h, NULL, 1, 2, 3, 4, 5, "N", "M",
                  WL_OUTPUT_TRANSFORM_270);
  output_done(&h, NULL);
  assert(h.outputs[0].committed.scale == 3);
  assert(h.outputs[0].committed.mode_width == 1920);
  assert(h.outputs[0].committed.x == -1920);
}

static void test_enter_leave_uses_only_committed_scale(void) {
  struct host h = new_host();
  struct wl_output *first = fake_output(0x401);
  struct wl_output *second = fake_output(0x402);
  struct wl_surface *surface = (struct wl_surface *)(uintptr_t)0x501;
  init_output(&h.outputs[0], first, 31);
  init_output(&h.outputs[1], second, 32);

  output_scale(&h, first, 2);
  output_done(&h, first);
  surface_enter(&h, surface, first);
  assert(h.scale == 2);

  output_scale(&h, second, 3);
  surface_enter(&h, surface, second);
  assert(h.scale == 2);
  assert(h.outputs[1].committed.scale == 1);
  output_done(&h, second);
  assert(h.scale == 3);

  surface_leave(&h, surface, second);
  assert(h.scale == 2);
  surface_leave(&h, surface, first);
  assert(h.scale == 1);
}

static void test_global_remove_resets_slot_before_reuse(void) {
  struct host h = new_host();
  struct wl_output *removed = fake_output(0x601);
  struct wl_output *replacement = fake_output(0x602);
  init_output(&h.outputs[0], removed, 41);
  h.outputs[0].entered = 1;
  h.outputs[0].committed.x = -1280;
  h.outputs[0].committed.mode_width = 2560;
  h.outputs[0].pending.scale = 2;
  h.scale = 2;
  output_destroy_calls = 0;
  last_destroyed_output = NULL;

  global_remove(&h, NULL, 41);
  assert(output_destroy_calls == 1);
  assert(last_destroyed_output == removed);
  assert(h.outputs[0].proxy == NULL);
  assert(h.outputs[0].name == 0);
  assert(h.outputs[0].entered == 0);
  assert(h.outputs[0].committed.x == 0);
  assert(h.outputs[0].committed.mode_width == 0);
  assert(h.outputs[0].pending.scale == 0);
  assert(h.scale == 1);

  /* The real registry bind path reinitializes all staged and committed state. */
  init_output(&h.outputs[0], replacement, 42);
  assert(h.outputs[0].proxy == replacement);
  assert(h.outputs[0].name == 42);
  assert(h.outputs[0].entered == 0);
  assert(h.outputs[0].committed.scale == 1);
  assert(h.outputs[0].pending.scale == 1);
  assert(h.outputs[0].committed.x == 0);
  assert(h.outputs[0].pending.mode_width == 0);
}

static void test_public_snapshot_readiness_copy_enter_remove_and_reuse(void) {
  struct host h = new_host();
  struct wl_output *first = fake_output(0x801);
  struct wl_output *second = fake_output(0x802);
  struct wl_output *replacement = fake_output(0x803);
  struct wl_surface *surface = (struct wl_surface *)(uintptr_t)0x804;
  h.token = 701;
  h.owner = pthread_self();
  h.window = 97;
  active = &h;
  init_output(&h.outputs[0], first, 71);
  init_output(&h.outputs[1], second, 72);

  double early[GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS] = {0};
  double pending[GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS] = {0};
  double committed[GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS] = {0};
  double changed[GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS] = {0};
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, early,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(early[0] == 0 && early[1] == 0 && early[2] == 0);
  assert(early[3] == 1 && early[11] == 0);
  assert(early[GPUI_OUTPUT_INFO_FIELDS] == 0);

  output_geometry(&h, first, 0, 0, 600, 340, 2, "Make", "Model",
                  WL_OUTPUT_TRANSFORM_90);
  output_mode(&h, first, WL_OUTPUT_MODE_PREFERRED, 3840, 2160, 60000);
  output_scale(&h, first, 2);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, pending,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(pending[0] == 0 && pending[1] == 0 && pending[2] == 0);
  assert(pending[3] == 1 && pending[4] == 0 && pending[8] == 0);

  output_mode(&h, first, WL_OUTPUT_MODE_CURRENT, 2560, 1440, 59940);
  output_done(&h, first);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, committed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(committed[0] == 1 && committed[1] == 1 && committed[2] == 1);
  assert(committed[3] == 2 && committed[4] == 600 && committed[5] == 340);
  assert(committed[6] == 2 && committed[7] == WL_OUTPUT_TRANSFORM_90);
  assert(committed[8] == 2560 && committed[9] == 1440);
  assert(committed[10] == 59940 && committed[11] == 0);
  assert(committed[GPUI_OUTPUT_INFO_FIELDS] == 0);
  assert(committed[GPUI_OUTPUT_INFO_FIELDS + 3] == 1);
  /* Earlier call-owned arrays remain unchanged after later native updates. */
  assert(early[0] == 0 && early[3] == 1);
  assert(pending[0] == 0 && pending[3] == 1);

  surface_enter(&h, surface, first);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[0] == 1 && changed[3] == 2 && changed[11] == 1);
  surface_leave(&h, surface, first);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[11] == 0);

  output_scale(&h, first, 4);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[3] == 2); /* pending scale is not public before done */
  output_done(&h, first);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[3] == 4);
  assert(committed[3] == 2); /* copied data does not alias native state */

  double untouched[GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS];
  for (int i = 0; i < GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS; ++i)
    untouched[i] = 99.0;
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, untouched,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS - 1) ==
         -GPUI_INVALID);
  for (int i = 0; i < GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS; ++i)
    assert(untouched[i] == 99.0);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, NULL,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) ==
         -GPUI_INVALID);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI + 1, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) ==
         -GPUI_UNSUPPORTED);
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token + 1, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) ==
         -GPUI_STALE);

  global_remove(&h, NULL, 71);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 1);
  assert(changed[0] == 0 && changed[3] == 1);
  assert(changed[4] == 0 && changed[8] == 0);

  init_output(&h.outputs[0], replacement, 73);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[0] == 0 && changed[1] == 0 && changed[2] == 0);
  assert(changed[3] == 1 && changed[4] == 0 && changed[8] == 0);
  output_geometry(&h, replacement, 0, 0, 500, 300, 1, "New", "Display",
                  WL_OUTPUT_TRANSFORM_NORMAL);
  output_mode(&h, replacement, WL_OUTPUT_MODE_CURRENT, 1920, 1080, 60000);
  output_done(&h, replacement);
  memset(changed, 0, sizeof(changed));
  assert(gpui_output_snapshot_v1(
             GPUI_OUTPUT_SNAPSHOT_ABI, h.token, changed,
             GPUI_OUTPUT_CAPACITY * GPUI_OUTPUT_INFO_FIELDS) == 2);
  assert(changed[0] == 1 && changed[4] == 500 && changed[8] == 1920);
  active = NULL;
}

int main(void) {
  test_batch_is_invisible_until_done_and_commits_together();
  test_scale_event_precedes_following_input_and_frame();
  test_callback_permutations_and_unknown_proxy();
  test_enter_leave_uses_only_committed_scale();
  test_global_remove_resets_slot_before_reuse();
  test_public_snapshot_readiness_copy_enter_remove_and_reuse();
  puts("Ubuntu output metadata tests passed");
  return 0;
}
