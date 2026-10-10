#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <limits.h>
#include <stdint.h>
#include <string.h>
#include <wayland-client.h>

#include "../../ubuntu/backend.c"

enum { TEST_TOKEN = 811, TEST_WINDOW = 97 };

static struct wl_pointer *fake_pointer(uintptr_t value) {
  return (struct wl_pointer *)value;
}

static void init_host(struct host *h, int window) {
  memset(h, 0, sizeof(*h));
  h->token = TEST_TOKEN;
  h->window = window;
  h->owner = pthread_self();
  h->width = 640;
  h->height = 480;
  h->scale = 2;
  h->px = 12.5;
  h->py = 24.25;
  h->pointer = fake_pointer(0x101);
  active = h;
}

static void finish_host(void) { active = NULL; }

static void seed_event(struct host *h, int slot, int kind, int sequence) {
  double record[10] = {kind, h->window, sequence, h->scale, h->width,
                       h->height, 31.5, 42.25, 6.0, 3.0};
  memcpy(h->queue[slot], record, sizeof(record));
}

static void seed_metadata(struct host *h, int slot) {
  struct direct_event_meta *meta = &h->direct_queue[slot];
  memset(meta, 0, sizeof(*meta));
  meta->epoch = 19;
  meta->direct_origin = 1;
  meta->text_length = 2;
  meta->revoked = 0;
  meta->text[0] = 'o';
  meta->text[1] = 'k';
  meta->text[2] = 0;
  h->ime_queue[slot] = (struct ime_payload *)(uintptr_t)0xdead;
  h->ime_queue_bytes = 37;
}

static void assert_tail_unchanged(struct host *h, int slot,
                                  const double before[10],
                                  const struct direct_event_meta *meta_before,
                                  struct ime_payload *ime_before,
                                  size_t ime_bytes_before) {
  assert(memcmp(h->queue[slot], before, sizeof(h->queue[slot])) == 0);
  assert(memcmp(&h->direct_queue[slot], meta_before,
                sizeof(h->direct_queue[slot])) == 0);
  assert(h->ime_queue[slot] == ime_before);
  assert(h->ime_queue_bytes == ime_bytes_before);
}

static void test_accepted_axes_wrap_and_keep_v1_v2_order(void) {
  struct host h;
  init_host(&h, TEST_WINDOW);
  h.read = QUEUE_CAPACITY - 1;
  h.count = 1;
  h.seq = 40;
  seed_event(&h, h.read, 7, 40);

  pointer_axis(&h, h.pointer, 1, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
               wl_fixed_from_double(-3.25));
  assert(h.count == 2 && h.seq == 41 && h.error == 0);
  int axis_slot = 0; /* The second enqueue wraps from the last slot to zero. */
  assert(h.queue[axis_slot][0] == 10);
  assert(h.queue[axis_slot][2] == 41);
  assert(h.queue[axis_slot][3] == 2);
  assert(h.queue[axis_slot][4] == -3.25);
  assert(h.queue[axis_slot][5] == 480);
  assert(h.queue[axis_slot][6] == 12.5 && h.queue[axis_slot][7] == 24.25);
  assert(h.queue[axis_slot][8] == WL_POINTER_AXIS_HORIZONTAL_SCROLL);

  double out[10];
  assert(gpui_next(h.token, out) == 1);
  assert(out[0] == 7 && out[2] == 40);
  assert(gpui_next(h.token, out) == 1);
  assert(out[0] == 10 && out[2] == 41 && out[4] == -3.25);
  assert(gpui_next(h.token, out) == 0);

  pointer_axis(&h, h.pointer, 2, WL_POINTER_AXIS_VERTICAL_SCROLL,
               wl_fixed_from_double(4.5));
  uint8_t text[1];
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, h.token, out, 10, text,
                      sizeof(text)) == 1);
  assert(out[0] == 10 && out[2] == 42 && out[4] == 4.5);
  assert(out[8] == WL_POINTER_AXIS_VERTICAL_SCROLL);
  assert(gpui_next_v2(GPUI_DIRECT_TEXT_ABI, h.token, out, 10, text,
                      sizeof(text)) == 0);
  finish_host();
}

static void test_full_wrapped_queue_rejection_preserves_tail_and_metadata(void) {
  struct host h;
  init_host(&h, TEST_WINDOW);
  h.read = QUEUE_CAPACITY - 8;
  h.count = QUEUE_CAPACITY;
  h.seq = QUEUE_CAPACITY;
  for (int i = 0; i < QUEUE_CAPACITY; ++i) {
    int slot = (h.read + i) % QUEUE_CAPACITY;
    seed_event(&h, slot, 7, i + 1);
  }
  int tail = (h.read + h.count - 1) % QUEUE_CAPACITY;
  seed_metadata(&h, tail);
  double before[10];
  struct direct_event_meta meta_before = h.direct_queue[tail];
  struct ime_payload *ime_before = h.ime_queue[tail];
  size_t ime_bytes_before = h.ime_queue_bytes;
  memcpy(before, h.queue[tail], sizeof(before));

  pointer_axis(&h, h.pointer, 3, WL_POINTER_AXIS_VERTICAL_SCROLL,
               wl_fixed_from_double(7.0));
  assert(h.error == GPUI_RESOURCE && h.count == QUEUE_CAPACITY);
  assert(h.seq == QUEUE_CAPACITY);
  assert_tail_unchanged(&h, tail, before, &meta_before, ime_before,
                        ime_bytes_before);
  finish_host();
}

static void test_sequence_exhaustion_preserves_pending_tail(void) {
  struct host h;
  init_host(&h, TEST_WINDOW);
  h.read = QUEUE_CAPACITY - 1;
  h.count = 2;
  h.seq = INT_MAX;
  seed_event(&h, h.read, 7, 90);
  int tail = (h.read + h.count - 1) % QUEUE_CAPACITY;
  seed_event(&h, tail, 8, 91);
  seed_metadata(&h, tail);
  double before[10];
  struct direct_event_meta meta_before = h.direct_queue[tail];
  struct ime_payload *ime_before = h.ime_queue[tail];
  size_t ime_bytes_before = h.ime_queue_bytes;
  memcpy(before, h.queue[tail], sizeof(before));

  pointer_axis(&h, h.pointer, 4, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
               wl_fixed_from_double(-11.0));
  assert(h.error == GPUI_RESOURCE && h.count == 2 && h.seq == INT_MAX);
  assert_tail_unchanged(&h, tail, before, &meta_before, ime_before,
                        ime_bytes_before);
  finish_host();
}

static void test_absent_window_and_wrong_proxy_leave_residual_queue_untouched(void) {
  struct host h;
  init_host(&h, 0);
  h.read = QUEUE_CAPACITY - 1;
  h.count = 1;
  h.seq = 12;
  seed_event(&h, h.read, 7, 12);
  seed_metadata(&h, h.read);
  double before[10];
  struct direct_event_meta meta_before = h.direct_queue[h.read];
  struct ime_payload *ime_before = h.ime_queue[h.read];
  size_t ime_bytes_before = h.ime_queue_bytes;
  memcpy(before, h.queue[h.read], sizeof(before));

  pointer_axis(&h, h.pointer, 5, WL_POINTER_AXIS_HORIZONTAL_SCROLL,
               wl_fixed_from_double(13.0));
  assert(h.count == 1 && h.seq == 12 && h.error == 0);
  assert_tail_unchanged(&h, h.read, before, &meta_before, ime_before,
                        ime_bytes_before);

  h.window = TEST_WINDOW;
  pointer_axis(&h, fake_pointer(0x202), 6, WL_POINTER_AXIS_VERTICAL_SCROLL,
               wl_fixed_from_double(15.0));
  assert(h.count == 1 && h.seq == 12 && h.error == 0);
  assert_tail_unchanged(&h, h.read, before, &meta_before, ime_before,
                        ime_bytes_before);
  finish_host();
}

static void test_rejected_axis_then_pointer_motion_drains_without_stale_payload(void) {
  struct host h;
  init_host(&h, TEST_WINDOW);
  h.read = QUEUE_CAPACITY - 2;
  h.count = QUEUE_CAPACITY;
  h.seq = QUEUE_CAPACITY;
  for (int i = 0; i < QUEUE_CAPACITY; ++i) {
    int slot = (h.read + i) % QUEUE_CAPACITY;
    seed_event(&h, slot, 7, i + 1);
  }
  int tail = (h.read + h.count - 1) % QUEUE_CAPACITY;
  double tail_before[10];
  memcpy(tail_before, h.queue[tail], sizeof(tail_before));

  pointer_axis(&h, h.pointer, 7, WL_POINTER_AXIS_VERTICAL_SCROLL,
               wl_fixed_from_double(7.0));
  assert(h.error == GPUI_RESOURCE && h.count == QUEUE_CAPACITY);
  assert(h.seq == QUEUE_CAPACITY);
  assert(memcmp(h.queue[tail], tail_before, sizeof(tail_before)) == 0);

  /* A later pointer callback must also fail closed without adding stale data. */
  pointer_motion(&h, h.pointer, 8, wl_fixed_from_double(99.0),
                 wl_fixed_from_double(101.0));
  assert(h.error == GPUI_RESOURCE && h.count == QUEUE_CAPACITY);
  assert(h.seq == QUEUE_CAPACITY);
  assert(memcmp(h.queue[tail], tail_before, sizeof(tail_before)) == 0);

  double out[10];
  for (int i = 0; i < QUEUE_CAPACITY; ++i) {
    assert(gpui_next(h.token, out) == 1);
    assert(out[2] == i + 1);
    if (i == QUEUE_CAPACITY - 1)
      assert(memcmp(out, tail_before, sizeof(tail_before)) == 0);
  }
  assert(gpui_next(h.token, out) == 0);
  assert(h.error == GPUI_RESOURCE);
  finish_host();
}

int main(void) {
  test_accepted_axes_wrap_and_keep_v1_v2_order();
  test_full_wrapped_queue_rejection_preserves_tail_and_metadata();
  test_rejected_axis_then_pointer_motion_drains_without_stale_payload();
  test_sequence_exhaustion_preserves_pending_tail();
  test_absent_window_and_wrong_proxy_leave_residual_queue_untouched();
  puts("Ubuntu pointer ingress tests passed");
  return 0;
}
