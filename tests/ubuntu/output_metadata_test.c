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
#include "../../ubuntu/backend.c"
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

int main(void) {
  test_batch_is_invisible_until_done_and_commits_together();
  test_callback_permutations_and_unknown_proxy();
  test_enter_leave_uses_only_committed_scale();
  test_global_remove_resets_slot_before_reuse();
  puts("Ubuntu output metadata tests passed");
  return 0;
}
