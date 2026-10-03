#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <dirent.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
static int verify_pixels;
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
int main(int argc, char **argv) {
  assert(gpui_start(999) == -GPUI_INVALID);
  int host = gpui_start(GPUI_UBUNTU_ABI);
  assert(host > 0);
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
    int w = active->width, h = active->height;
    double frame[5 + 2 * GPUI_QUAD_STRIDE] = {0,   0,   w,   h,   active->scale,
                                              0,   0,   w,   h,   255,
                                              0,   0,   255, 1,   0,
                                              0,   1,   0,   0,   1,
                                              0,   0,   w,   h,   0,
                                              0,   40,  40,  0,   0,
                                              255, 255, 1,   0,   0,
                                              1,   10,  10,  0.5, 20,
                                              20,  20,  20};
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
    release_gpu(active); /* fault: native surface/device resources disappear */
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_SURFACE_LOST);
    assert(gpui_recover(host, window) == GPUI_OK);
    assert(gpui_present(host, window, frame, sizeof(frame) / sizeof(double)) ==
           GPUI_OK);
    await_frame(host);
    drain(host);
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
  puts("Wayland native lifecycle, readback, input order, scale, recovery and "
       "resource checks passed.");
  return 0;
}
