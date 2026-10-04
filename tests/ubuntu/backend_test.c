#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <ctype.h>
#include <dirent.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
static int verify_pixels;
static int benchmark;
static EGLBoolean verified_swap(EGLDisplay display, EGLSurface surface);
/* Inspect pixels before swap without introducing readback into the runtime. */
#define eglSwapBuffers verified_swap
#include "../../ubuntu/backend.c"
#undef eglSwapBuffers
static EGLBoolean verified_swap(EGLDisplay display, EGLSurface surface) {
  if (verify_pixels) {
    unsigned char pixel[4];
    glReadPixels(5 * active->scale, (active->height - 5) * active->scale, 1, 1,
                 GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    assert(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0);
    /* Translated blue quad with 50% opacity over red, clipped at logical x=20.
     */
    glReadPixels(25 * active->scale, (active->height - 25) * active->scale, 1,
                 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    assert(pixel[0] >= 126 && pixel[0] <= 129 && pixel[1] == 0 &&
           pixel[2] >= 126 && pixel[2] <= 129);
    glReadPixels(15 * active->scale, (active->height - 25) * active->scale, 1,
                 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    assert(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0);
    /* Fractional clip [60.2, 61.2): one covered sample at 1x, two at 2x. */
    int base = 60 * active->scale;
    int row = (active->height - 15) * active->scale;
    glReadPixels(base, row, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    assert(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0);
    if (active->scale == 2) {
      glReadPixels(base + 1, row, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(pixel[0] == 0 && pixel[1] == 255 && pixel[2] == 0);
    }
    glReadPixels(base + active->scale, row, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
                 pixel);
    assert(pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0);
  }
  return eglSwapBuffers(display, surface);
}
static int fd_count(void) {
  DIR *dir = opendir("/proc/self/fd");
  assert(dir);
  int n = 0;
  while (readdir(dir))
    ++n;
  closedir(dir);
  return n;
}
static void *wrong_thread(void *unused) {
  UNUSED(unused);
  assert(gpui_dispatch(active->token, 0) == GPUI_WRONG_THREAD);
  return NULL;
}
static void drain(int host) {
  double e[10];
  while (gpui_next(host, e) == 1) {
  }
}
static void await_frame(int host) {
  for (int i = 0; i < 50 && active->frame; ++i) {
    assert(gpui_dispatch(host, 100) == GPUI_OK);
    drain(host);
  }
  assert(!active->frame);
}
static uint64_t monotonic_ns(void) {
  struct timespec now;
  assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
  return (uint64_t)now.tv_sec * 1000000000ULL + (uint64_t)now.tv_nsec;
}
static void safe_renderer_name(char *out, size_t capacity) {
  const char *name = (const char *)glGetString(GL_RENDERER);
  if (!name || !*name) {
    snprintf(out, capacity, "unknown");
    return;
  }
  size_t i = 0;
  int separator = 0;
  while (*name && i + 1 < capacity) {
    unsigned char c = (unsigned char)*name++;
    if (isalnum(c) || c == '-' || c == '_' || c == '.') {
      out[i++] = (char)c;
      separator = 0;
    } else if (i && !separator) {
      out[i++] = '_';
      separator = 1;
    }
  }
  while (i && out[i - 1] == '_')
    --i;
  out[i] = 0;
  if (!i)
    snprintf(out, capacity, "unknown");
}
static void test_clipboard_transfer_writer(void) {
  struct host host = {0};
  for (int i = 0; i < SOURCE_TRANSFER_CAPACITY; ++i)
    host.transfers[i].fd = -1;
  size_t length = 512 * 1024;
  uint8_t *payload = malloc(length);
  uint8_t *received = malloc(length);
  assert(payload && received);
  for (size_t i = 0; i < length; ++i)
    payload[i] = (uint8_t)(i * 31u + 7u);
  struct clipboard_source source = {
      .host = &host, .bytes = payload, .length = length};
  int descriptors[2];
  assert(pipe(descriptors) == 0);
  int flags = fcntl(descriptors[0], F_GETFL);
  assert(flags >= 0 && fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) == 0);
  source_send(&source, NULL, "text/plain;charset=utf-8", descriptors[1]);
  size_t offset = 0;
  for (int attempt = 0; offset < length && attempt < 100000; ++attempt) {
    for (;;) {
      if (offset == length)
        break;
      ssize_t count = read(descriptors[0], received + offset, length - offset);
      if (count > 0) {
        offset += (size_t)count;
        continue;
      }
      assert(count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK));
      break;
    }
    flush_transfers(&host);
  }
  assert(offset == length && host.transfers[0].fd == -1);
  assert(memcmp(payload, received, length) == 0);
  close(descriptors[0]);
  free(payload);
  free(received);

  /* A clipboard consumer may close its pipe early; this must not deliver
   * SIGPIPE to the whole application. */
  uint8_t one = 'x';
  source.bytes = &one;
  source.length = 1;
  assert(pipe(descriptors) == 0);
  close(descriptors[0]);
  source_send(&source, NULL, "text/plain", descriptors[1]);
  assert(host.transfers[0].fd == -1);
}
static void test_clipboard_mime_staging(void) {
  struct host host = {0};
  note_pending_mime_type(&host, "text/plain;charset=utf-8");
  note_pending_mime_type(&host, "text/plain");
  commit_pending_mime_types(&host);
  assert(host.clipboard_has_utf8 && host.clipboard_has_plain);

  /* A drag offer shares the data-device event stream, but must not replace
   * the currently selected clipboard MIME types until selection confirms it. */
  reset_pending_mime_types(&host);
  note_pending_mime_type(&host, "text/plain");
  assert(host.clipboard_has_utf8 && host.clipboard_has_plain);
  commit_pending_mime_types(&host);
  assert(!host.clipboard_has_utf8 && host.clipboard_has_plain);
  clear_selection_mime_types(&host);
  assert(!host.clipboard_has_utf8 && !host.clipboard_has_plain);
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--clipboard-unit")) {
    test_clipboard_transfer_writer();
    test_clipboard_mime_staging();
    puts("Wayland clipboard transfer and MIME helper checks passed.");
    return 0;
  }
  assert(gpui_start(999) == -GPUI_INVALID);
  int host = gpui_start(GPUI_UBUNTU_ABI);
  assert(host > 0);
  test_clipboard_transfer_writer();
  benchmark = getenv("GPUI_BENCH_UBUNTU") &&
              !strcmp(getenv("GPUI_BENCH_UBUNTU"), "1");
  assert(gpui_start(GPUI_UBUNTU_ABI) == -GPUI_BUSY);
  pthread_t thread;
  assert(!pthread_create(&thread, NULL, wrong_thread, NULL));
  pthread_join(thread, NULL);
  assert(gpui_create(host, 0, 10, (const uint8_t *)"bad", 3) == -GPUI_INVALID);
  assert(!active->window);
  int stable_fds = -1;
  for (int run = 0; run < 40; ++run) {
    int window = gpui_create(host, 100, 80, (const uint8_t *)"fixture", 7);
    assert(window > 0);
    if (run == 0) {
      assert(gpui_capability(host, 1) == GPUI_OK);
      assert(gpui_capability(host, 2) == GPUI_OK);
      assert(gpui_write_clipboard(host, (const uint8_t *)"before input", 12) ==
             GPUI_UNSUPPORTED);
      assert(gpui_read_clipboard(host) == GPUI_UNSUPPORTED);
      assert(gpui_set_cursor(host, 0) == GPUI_UNSUPPORTED);
    }
    int w = active->width, h = active->height;
    double frame[5 + 3 * GPUI_QUAD_STRIDE] = {0,   0,   w,   h,   active->scale,
                                              0,   0,   w,   h,   255,
                                              0,   0,   255, 1,   0,
                                              0,   1,   0,   0,   1,
                                              0,   0,   w,   h,   0,
                                              0,   40,  40,  0,   0,
                                              255, 255, 1,   0,   0,
                                              1,   10,  10,  0.5, 20,
                                              20,  20,  20};
    double *fractional = frame + 5 + 2 * GPUI_QUAD_STRIDE;
    fractional[0] = 60; fractional[1] = 10;
    fractional[2] = 4; fractional[3] = 10;
    fractional[4] = 0; fractional[5] = 255;
    fractional[6] = 0; fractional[7] = 255;
    fractional[8] = 1; fractional[11] = 1; fractional[14] = 1;
    fractional[15] = 60.2; fractional[16] = 10;
    fractional[17] = 1.0; fractional[18] = 10;
    assert(gpui_present(host, window, frame, 4) == GPUI_INVALID);
    verify_pixels = 1;
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_OK);
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_BUSY);
    await_frame(host);
    /* The compositor advertises integer output scale after the first mapping.
     */
    if (getenv("GPUI_EXPECT_SCALE"))
      assert(active->scale == atoi(getenv("GPUI_EXPECT_SCALE")));
    frame[4] = active->scale;
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_OK);
    await_frame(host);
    drain(host);
    int seq = active->seq;
    pointer_motion(active, NULL, 0, wl_fixed_from_double(12.5),
                   wl_fixed_from_double(8.25));
    keyboard_enter(active, NULL, 0, active->surface, NULL);
    double e[10];
    assert(gpui_next(host, e) == 1 && e[0] == 7 && e[2] == seq + 1 &&
           e[6] == 12.5 && e[7] == 8.25);
    assert(gpui_next(host, e) == 1 && e[0] == 6 && e[2] == seq + 2);
    assert(gpui_size(host, window, 120, 90) == GPUI_OK);
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_BUSY);
    frame[2] = 120;
    frame[3] = 90;
    frame[7] = 120;
    frame[8] = 90;
    /* Consume the resize event before the recovery/teardown assertions below;
     * run 0 intentionally leaves only the recovered frame outstanding. */
    drain(host);
    release_gpu(active); /* fault: native surface/device resources disappear */
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_SURFACE_LOST);
    assert(gpui_recover(host, window) == GPUI_OK);
    uint64_t sample_start = benchmark ? monotonic_ns() : 0;
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_OK);
    /* Benchmark samples exclude setup and the warmup cycles. They measure
     * submission through the compositor frame callback on this llvmpipe path. */
    if (run != 0 || benchmark) {
      await_frame(host);
      drain(host);
      if (benchmark && run >= 5 && run < 35) {
        char renderer[128];
        safe_renderer_name(renderer, sizeof(renderer));
        uint64_t elapsed = monotonic_ns() - sample_start;
        printf("GPUI_BENCH_SAMPLE "
               "scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
               "platform=ubuntu-wayland renderer=%s scale=%d sample=%d "
               "duration_ns=%llu\n",
               renderer, active->scale, run - 5,
               (unsigned long long)elapsed);
      }
    }
    assert(gpui_close(host, window) == GPUI_OK);
    assert(gpui_next(host, e) == 1 && e[0] == 3);
    assert(active->window == window);
    assert(gpui_destroy(host, window) == GPUI_OK);
    assert(gpui_destroy(host, window) == GPUI_OK);
    assert(gpui_next(host, e) == 1 && e[0] == 4 && e[1] == window);
    assert(gpui_next(host, e) == 0);
    assert(gpui_title(host, window, (const uint8_t *)"stale", 5) == GPUI_STALE);
    assert(!active->surface && !active->egl_window && !active->frame &&
           !active->window);
    int fds = fd_count();
    if (run == 4)
      stable_fds = fds;
    if (run > 4)
      assert(fds <= stable_fds);
  }
  /* Input storms fail observably and cannot grow the event queue. */
  int storm_window = gpui_create(host, 100, 80, (const uint8_t *)"storm", 5);
  assert(storm_window > 0);
  drain(host);
  for (int i = 0; i < QUEUE_CAPACITY + 16; ++i)
    pointer_motion(active, NULL, 0, 0, 0);
  assert(active->count == QUEUE_CAPACITY);
  assert(gpui_dispatch(host, 0) == GPUI_RESOURCE && gpui_state(host) == 1);
  assert(gpui_stop(host) == GPUI_OK);
  host = gpui_start(GPUI_UBUNTU_ABI);
  assert(host > 0);
  if (argc == 2) {
    /* Called only by the isolated test runner, with its own compositor PID. */
    assert(kill((pid_t)strtol(argv[1], NULL, 10), SIGTERM) == 0);
    int status = GPUI_OK;
    for (int i = 0; i < 40 && !status; ++i)
      status = gpui_dispatch(host, 100);
    assert(status == GPUI_NATIVE && gpui_state(host) == 1);
  }
  assert(gpui_wake(host) == GPUI_OK);
  assert(gpui_exit(host) == GPUI_OK);
  assert(gpui_create(host, 10, 10, (const uint8_t *)"late", 4) ==
         -GPUI_STOPPING);
  assert(gpui_stop(host) == GPUI_OK && gpui_stop(host) == GPUI_OK);
  if (benchmark)
    puts("GPUI_BENCH_COMPLETE "
         "scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
         "samples_per_scale=30");
  puts("Wayland native lifecycle, readback, input order, scale, recovery and "
       "resource checks passed.");
  return 0;
}
