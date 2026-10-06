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
static int verify_mixed_pixels;
static int swap_count;
struct expected_pixel {
  int x, y;
  unsigned char rgba[4];
};
static struct expected_pixel mixed_expected[4];
static int mixed_expected_count;
static int captured_once;
static int capture_next_mixed;
static int benchmark;
static EGLBoolean verified_swap(EGLDisplay display, EGLSurface surface);
static void verify_mixed_readback(void);
static void capture_mixed_readback(void);
enum { TEST_CAPABILITY_CLIPBOARD = 1, TEST_CAPABILITY_CURSOR = 2 };
/* Inspect pixels before swap without introducing readback into the runtime. */
#define eglSwapBuffers verified_swap
#include "../../ubuntu/backend.c"
#undef eglSwapBuffers
static void record_optional_capability(int host, int capability,
                                       const char *service) {
  int status = gpui_capability(host, capability);
  if (status == GPUI_OK) {
    printf("GPUI_UBUNTU_E2E service=%s status=available\n", service);
    return;
  }
  assert(status == GPUI_UNSUPPORTED);
  printf("GPUI_UBUNTU_E2E service=%s status=unsupported "
         "error=unsupported_capability\n",
         service);
}
static EGLBoolean verified_swap(EGLDisplay display, EGLSurface surface) {
  ++swap_count;
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
  if (verify_mixed_pixels)
    verify_mixed_readback();
  if (capture_next_mixed) {
    capture_mixed_readback();
    capture_next_mixed = 0;
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

static void read_top_pixel(int x, int y, unsigned char pixel[4]) {
  int device_height = active->height * active->scale;
  assert(x >= 0 && x < active->width * active->scale);
  assert(y >= 0 && y < device_height);
  glReadPixels(x, device_height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE,
               pixel);
}

static void expect_pixel(int index, int x, int y, int r, int g, int b, int a) {
  assert(index >= 0 && index < (int)(sizeof(mixed_expected) /
                                    sizeof(mixed_expected[0])));
  mixed_expected[index].x = x;
  mixed_expected[index].y = y;
  mixed_expected[index].rgba[0] = (unsigned char)r;
  mixed_expected[index].rgba[1] = (unsigned char)g;
  mixed_expected[index].rgba[2] = (unsigned char)b;
  mixed_expected[index].rgba[3] = (unsigned char)a;
  if (mixed_expected_count <= index)
    mixed_expected_count = index + 1;
}

static void capture_mixed_readback(void) {
  const char *path = getenv("GPUI_UBUNTU_CAPTURE");
  if (captured_once || !path || !*path)
    return;
  int width = active->width * active->scale;
  int height = active->height * active->scale;
  size_t bytes = (size_t)width * (size_t)height * 4;
  unsigned char *rgba = malloc(bytes);
  assert(rgba);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  char head[80] = "unknown";
  FILE *git = popen("git rev-parse HEAD 2>/dev/null", "r");
  if (git) {
    if (fgets(head, sizeof(head), git)) {
      size_t n = strlen(head);
      while (n && (head[n - 1] == '\n' || head[n - 1] == '\r'))
        head[--n] = 0;
    }
    (void)pclose(git);
  }
  const char *renderer = (const char *)glGetString(GL_RENDERER);
  if (!renderer)
    renderer = "unknown";
  FILE *file = fopen(path, "wb");
  assert(file);
  assert(fprintf(file, "P6\n# head=%s scale=%d renderer=%s\n%d %d\n255\n",
                 head, active->scale, renderer, width, height) > 0);
  /* Readback rows start at GL's bottom edge; PPM rows are top-down here. */
  for (int row = height - 1; row >= 0; --row)
    for (int col = 0; col < width; ++col) {
      const unsigned char *pixel = rgba + ((size_t)row * width + col) * 4;
      assert(fwrite(pixel, 1, 3, file) == 3);
    }
  assert(fclose(file) == 0);
  free(rgba);
  captured_once = 1;
  printf("GPUI_UBUNTU_CAPTURE path=%s head=%s scale=%d renderer=%s width=%d "
         "height=%d format=ppm\n",
         path, head, active->scale, renderer, width, height);
}

static void verify_mixed_readback(void) {
  for (int i = 0; i < mixed_expected_count; ++i) {
    unsigned char actual[4];
    read_top_pixel(mixed_expected[i].x, mixed_expected[i].y, actual);
    for (int channel = 0; channel < 4; ++channel) {
      int delta = (int)actual[channel] - mixed_expected[i].rgba[channel];
      if (delta < 0)
        delta = -delta;
      assert(delta <= 5);
    }
  }
}

static double mask_linear_sample(const struct gpui_linux_text_mask *mask,
                                 double u, double v) {
  double fx = u * mask->width - 0.5;
  double fy = v * mask->height - 0.5;
  double tx = fx - floor(fx), ty = fy - floor(fy);
  int x0 = (int)floor(fx), y0 = (int)floor(fy);
  int x1 = x0 + 1, y1 = y0 + 1;
  if (x0 < 0) x0 = 0;
  if (y0 < 0) y0 = 0;
  if (x1 >= mask->width) x1 = mask->width - 1;
  if (y1 >= mask->height) y1 = mask->height - 1;
  if (x0 >= mask->width) x0 = mask->width - 1;
  if (y0 >= mask->height) y0 = mask->height - 1;
  double a = mask->pixels[(size_t)y0 * mask->width + x0];
  double b = mask->pixels[(size_t)y0 * mask->width + x1];
  double c = mask->pixels[(size_t)y1 * mask->width + x0];
  double d = mask->pixels[(size_t)y1 * mask->width + x1];
  return ((a * (1.0 - tx) + b * tx) * (1.0 - ty) +
          (c * (1.0 - tx) + d * tx) * ty) /
         255.0;
}

static double expected_text_coverage(const struct gpui_linux_text_mask *mask,
                                     const double *q, double sx, double sy) {
  if (sx < q[15] || sy < q[16] || sx >= q[15] + q[17] ||
      sy >= q[16] + q[18])
    return 0.0;
  double a = q[8], b = q[9], c = q[10], d = q[11];
  double determinant = a * d - b * c;
  assert(fabs(determinant) > 1e-9);
  double dx = sx - q[12], dy = sy - q[13];
  double px = (d * dx - c * dy) / determinant;
  double py = (-b * dx + a * dy) / determinant;
  if (px < q[0] + mask->left || py < q[1] + mask->top ||
      px >= q[0] + mask->right || py >= q[1] + mask->bottom)
    return 0.0;
  double u = (px - q[0] - mask->left) / mask->width;
  double v = (py - q[1] - mask->top) / mask->height;
  return mask_linear_sample(mask, u, v);
}

static void projected_mask_point(const struct gpui_linux_text_mask *mask,
                                 const double *q, int x, int y, double *sx,
                                 double *sy) {
  /* A8 texels stay at logical pixel centers. Fractional ink bounds and local
   * item bounds crop the quad/UV range; they do not stretch the mask. */
  double local_x = mask->left + x + 0.5;
  double local_y = mask->top + y + 0.5;
  double px = q[0] + local_x, py = q[1] + local_y;
  *sx = q[8] * px + q[10] * py + q[12];
  *sy = q[9] * px + q[11] * py + q[13];
}

static void set_mixed_common(double *record, double x, double y, double w,
                             double h, double r, double g, double b, double a,
                             double ta, double tb, double tc, double td,
                             double tx, double ty, double opacity,
                             double clip_x, double clip_y, double clip_w,
                             double clip_h) {
  double *q = record + 1;
  record[0] = 0;
  q[0] = x;
  q[1] = y;
  q[2] = w;
  q[3] = h;
  q[4] = r;
  q[5] = g;
  q[6] = b;
  q[7] = a;
  q[8] = ta;
  q[9] = tb;
  q[10] = tc;
  q[11] = td;
  q[12] = tx;
  q[13] = ty;
  q[14] = opacity;
  q[15] = clip_x;
  q[16] = clip_y;
  q[17] = clip_w;
  q[18] = clip_h;
  record[20] = record[21] = record[22] = 0;
}

static void set_full_red_quad(double *record, double width, double height) {
  set_mixed_common(record, 0, 0, width, height, 255, 0, 0, 255, 1, 0, 0, 1,
                   0, 0, 1, 0, 0, width, height);
}

static void set_text_record(double *record, double x, double y, double w,
                            double h, double opacity, double clip_x,
                            double clip_y, double clip_w, double clip_h,
                            double tx, double ty, int text_length,
                            double font_size) {
  set_mixed_common(record, x, y, w, h, 0, 0, 255, 255, 0.91, 0.27, -0.18,
                   0.97, tx, ty, opacity, clip_x, clip_y, clip_w, clip_h);
  record[0] = 1;
  record[20] = 0;
  record[21] = text_length;
  record[22] = font_size;
}

static void init_mixed_frame(double *data, int count, int width, int height,
                             int scale) {
  memset(data, 0, (size_t)(5 + count * GPUI_MIXED_STRIDE) * sizeof(double));
  data[0] = data[1] = 0;
  data[2] = width;
  data[3] = height;
  data[4] = scale;
}

static void present_mixed_pixel_fixture(int host, int window, int *saved_x,
                                        int *saved_y) {
  static const uint8_t text[] = "MMMM";
  static const uint8_t sans[] = "sans";
  int width = active->width, height = active->height, scale = active->scale;
  struct gpui_linux_text_mask mask = {0};
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, text, (int32_t)sizeof(text) - 1, sans, 4,
             18.0, 44.25, 25.5, 4 * 1024 * 1024, &mask) ==
         GPUI_LINUX_TEXT_OK);
  assert(mask.pixels && mask.width > 0 && mask.height > 0);

  double data[5 + 3 * GPUI_MIXED_STRIDE];
  init_mixed_frame(data, 3, width, height, scale);
  double *backdrop = data + 5;
  double *text_record = data + 5 + GPUI_MIXED_STRIDE;
  double *overlay = data + 5 + 2 * GPUI_MIXED_STRIDE;
  set_full_red_quad(backdrop, width, height);
  set_text_record(text_record, 5.25, 10.5, 44.25, 25.5, 0.5, 0, 0, width,
                  height, 0, 0, (int)sizeof(text) - 1, 18.0);
  double *q = text_record + 1;

  int ax = 0, ay = 0;
  unsigned int greatest = 0;
  for (int y = 0; y < mask.height; ++y)
    for (int x = 0; x < mask.width; ++x) {
      unsigned int value = mask.pixels[(size_t)y * mask.width + x];
      if (value > greatest) {
        greatest = value;
        ax = x;
        ay = y;
      }
    }
  assert(greatest >= 200);
  double raw_ax, raw_ay;
  projected_mask_point(&mask, q, ax, ay, &raw_ax, &raw_ay);
  int target_x = 20 * scale, target_y = (height / 3) * scale;
  double target_sx = (target_x + 0.5) / scale;
  double target_sy = (target_y + 0.5) / scale;
  q[12] = target_sx - raw_ax;
  q[13] = target_sy - raw_ay;

  int bx = -1, by = -1, target_bx = -1, target_by = -1;
  double best_score = 1e30;
  for (int y = 0; y < mask.height; ++y)
    for (int x = 0; x < mask.width; ++x) {
      unsigned int value = mask.pixels[(size_t)y * mask.width + x];
      if (value < 180 || (x == ax && y == ay))
        continue;
      double sx, sy;
      projected_mask_point(&mask, q, x, y, &sx, &sy);
      int px = (int)floor(sx * scale), py = (int)floor(sy * scale);
      if (px < 0 || py < 0 || px >= width * scale || py >= height * scale ||
          (px == target_x && py == target_y))
        continue;
      double cx = (px + 0.5) / scale, cy = (py + 0.5) / scale;
      double coverage = expected_text_coverage(&mask, q, cx, cy);
      if (coverage < 0.35)
        continue;
      double dx = cx - target_sx, dy = cy - target_sy;
      double score = dx * dx + dy * dy;
      if (score < best_score) {
        best_score = score;
        bx = x;
        by = y;
        target_bx = px;
        target_by = py;
      }
    }
  assert(bx >= 0 && by >= 0);
  double center_bx = (target_bx + 0.5) / scale;
  double center_by = (target_by + 0.5) / scale;
  double clip_x = fmin(target_sx, center_bx) - 0.63;
  double clip_y = fmin(target_sy, center_by) - 0.71;
  double clip_right = fmax(target_sx, center_bx) + 0.68;
  double clip_bottom = fmax(target_sy, center_by) + 0.73;
  q[15] = clip_x;
  q[16] = clip_y;
  q[17] = clip_right - clip_x;
  q[18] = clip_bottom - clip_y;
  double coverage_b = expected_text_coverage(&mask, q, center_bx, center_by);
  assert(coverage_b > 0.35);

  int cx = -1, cy = -1;
  for (int y = 0; y < mask.height && cx < 0; ++y)
    for (int x = 0; x < mask.width && cx < 0; ++x) {
      unsigned int value = mask.pixels[(size_t)y * mask.width + x];
      if (value < 160 || (x == ax && y == ay) || (x == bx && y == by))
        continue;
      double sx, sy;
      projected_mask_point(&mask, q, x, y, &sx, &sy);
      int px = (int)floor(sx * scale), py = (int)floor(sy * scale);
      if (px < 0 || py < 0 || px >= width * scale || py >= height * scale ||
          (px == target_x && py == target_y) ||
          (px == target_bx && py == target_by))
        continue;
      double cx_center = (px + 0.5) / scale;
      double cy_center = (py + 0.5) / scale;
      if (cx_center >= q[15] && cx_center < q[15] + q[17] &&
          cy_center >= q[16] && cy_center < q[16] + q[18])
        continue;
      double q_full[19];
      memcpy(q_full, q, sizeof(q_full));
      q_full[15] = q_full[16] = 0;
      q_full[17] = width;
      q_full[18] = height;
      if (expected_text_coverage(&mask, q_full, cx_center, cy_center) < 0.25)
        continue;
      cx = px;
      cy = py;
    }
  assert(cx >= 0 && cy >= 0);

  double overlay_side = 0.36 / scale;
  set_mixed_common(overlay, target_sx - overlay_side / 2,
                   target_sy - overlay_side / 2, overlay_side, overlay_side,
                   0, 255, 0, 255, 1, 0, 0, 1, 0, 0, 1, 0, 0, width, height);
  double alpha = 0.5 * coverage_b;
  expect_pixel(0, target_x, target_y, 0, 255, 0, 255);
  expect_pixel(1, target_bx, target_by,
               (int)lround(255.0 * (1.0 - alpha)), 0,
               (int)lround(255.0 * alpha), 255);
  expect_pixel(2, cx, cy, 255, 0, 0, 255);

  int previous_verify = verify_pixels;
  verify_pixels = 0;
  mixed_expected_count = 3;
  verify_mixed_pixels = 1;
  int swaps_before = swap_count;
  assert(gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, data,
                         (int32_t)(sizeof(data) / sizeof(data[0])), text,
                         (int32_t)sizeof(text) - 1) == GPUI_OK);
  assert(swap_count == swaps_before + 1);
  verify_mixed_pixels = 0;
  await_frame(host);
  verify_pixels = previous_verify;
  *saved_x = target_x;
  *saved_y = target_y;
  gpui_linux_text_mask_release_v1(&mask);
}

static void assert_preflight_preserves(int host, int window, const double *data,
                                       int32_t length, const uint8_t *text,
                                       int32_t text_length, int expected_status,
                                       int x, int y) {
  unsigned char before[4], after[4];
  read_top_pixel(x, y, before);
  int swaps_before = swap_count;
  assert(gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, data, length, text,
                         text_length) == expected_status);
  assert(swap_count == swaps_before);
  read_top_pixel(x, y, after);
  assert(memcmp(before, after, sizeof(before)) == 0);
}

static void test_v2_preflight_preservation(int host, int window, int x, int y) {
  int width = active->width, height = active->height, scale = active->scale;
  static const uint8_t one[] = "A";
  double invalid[5 + 3 * GPUI_MIXED_STRIDE];
  init_mixed_frame(invalid, 3, width, height, scale);
  set_full_red_quad(invalid + 5, width, height);
  set_text_record(invalid + 5 + GPUI_MIXED_STRIDE, 8, 8, 20, 20, 1, 0, 0,
                  width, height, 0, 0, 1, 16);
  set_text_record(invalid + 5 + 2 * GPUI_MIXED_STRIDE, 20, 20, 12, 12, 1, 0,
                  0, width, height, 0, 0, 1, 16);
  invalid[5 + 2 * GPUI_MIXED_STRIDE + 20] = 0;
  invalid[5 + 2 * GPUI_MIXED_STRIDE + 21] = 2; /* invalid late UTF-8 span */
  assert_preflight_preserves(host, window, invalid,
                             (int32_t)(sizeof(invalid) / sizeof(invalid[0])),
                             one, 1, GPUI_INVALID, x, y);

  /* A valid first run allocates a mask, then a bounded no-wrap run exceeds
   * the 2048px tile dimension. The whole frame must still leave the displayed
   * pixels and swap count alone. */
  uint8_t large_text[2048], large_blob[1 + sizeof(large_text)];
  memset(large_text, 'M', sizeof(large_text));
  large_blob[0] = 'H';
  memcpy(large_blob + 1, large_text, sizeof(large_text));
  double resource[5 + 3 * GPUI_MIXED_STRIDE];
  init_mixed_frame(resource, 3, width, height, scale);
  set_full_red_quad(resource + 5, width, height);
  set_text_record(resource + 5 + GPUI_MIXED_STRIDE, 8, 8, 20, 20, 1, 0, 0,
                  width, height, 0, 0, 1, 18);
  set_text_record(resource + 5 + 2 * GPUI_MIXED_STRIDE, 20, 20, 50000, 24, 1,
                  0, 0, width, height, 0, 0, (int)sizeof(large_text), 18);
  resource[5 + 2 * GPUI_MIXED_STRIDE + 20] = 1;
  assert_preflight_preserves(
      host, window, resource,
      (int32_t)(sizeof(resource) / sizeof(resource[0])), large_blob,
      (int32_t)sizeof(large_blob), GPUI_RESOURCE, x, y);

  static const uint8_t emoji[] = {0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80,
                                  0x8d, 0xf0, 0x9f, 0x92, 0xbb};
  static const uint8_t sans[] = "sans";
  struct gpui_linux_text_mask color_probe = {0};
  int color_status = gpui_linux_text_raster_v1(
      GPUI_LINUX_TEXT_ABI, emoji, (int32_t)sizeof(emoji), sans, 4, 16, 32, 24,
      4 * 1024 * 1024, &color_probe);
  assert(color_status == GPUI_LINUX_TEXT_UNSUPPORTED_COLOR);
  {
    double color_frame[5 + 3 * GPUI_MIXED_STRIDE];
    uint8_t blob[1 + sizeof(emoji)];
    blob[0] = 'H';
    memcpy(blob + 1, emoji, sizeof(emoji));
    init_mixed_frame(color_frame, 3, width, height, scale);
    set_full_red_quad(color_frame + 5, width, height);
    set_text_record(color_frame + 5 + GPUI_MIXED_STRIDE, 8, 8, 20, 20, 1, 0,
                    0, width, height, 0, 0, 1, 16);
    set_text_record(color_frame + 5 + 2 * GPUI_MIXED_STRIDE, 30, 20, 32, 24,
                    1, 0, 0, width, height, 0, 0,
                    (int32_t)sizeof(emoji), 16);
    color_frame[5 + 2 * GPUI_MIXED_STRIDE + 20] = 1;
    assert_preflight_preserves(
        host, window, color_frame,
        (int32_t)(sizeof(color_frame) / sizeof(color_frame[0])), blob,
        (int32_t)sizeof(blob), GPUI_UNSUPPORTED, x, y);
  }
  gpui_linux_text_mask_release_v1(&color_probe);
}

static void test_fractional_local_bounds(int host, int window) {
  static const uint8_t text[] = "MMMMMMMM";
  static const uint8_t sans[] = "sans";
  int width = active->width, height = active->height, scale = active->scale;
  struct gpui_linux_text_mask full = {0}, bounded = {0};
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, text, (int32_t)sizeof(text) - 1, sans, 4,
             18.0, 150.0, 30.5, 4 * 1024 * 1024, &full) ==
         GPUI_LINUX_TEXT_OK);
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, text, (int32_t)sizeof(text) - 1, sans, 4,
             18.0, 30.25, 30.5, 4 * 1024 * 1024, &bounded) ==
         GPUI_LINUX_TEXT_OK);
  assert(full.pixels && bounded.pixels && bounded.right <= 30.25);
  int ix = 0, iy = 0;
  unsigned int best = 0;
  for (int y = 0; y < bounded.height; ++y)
    for (int x = 0; x < bounded.width; ++x) {
      unsigned int value = bounded.pixels[(size_t)y * bounded.width + x];
      if (value > best) {
        best = value;
        ix = x;
        iy = y;
      }
    }
  assert(best >= 200);
  int ox = -1, oy = -1;
  for (int y = 0; y < full.height && ox < 0; ++y)
    for (int x = 0; x < full.width && ox < 0; ++x) {
      unsigned int value = full.pixels[(size_t)y * full.width + x];
      double local_x = full.left +
                       ((x + 0.5) * (full.right - full.left) / full.width);
      if (value >= 160 && local_x > 32.0) {
        ox = x;
        oy = y;
      }
    }
  assert(ox >= 0 && oy >= 0);

  double data[5 + 2 * GPUI_MIXED_STRIDE];
  init_mixed_frame(data, 2, width, height, scale);
  set_full_red_quad(data + 5, width, height);
  double *text_record = data + 5 + GPUI_MIXED_STRIDE;
  set_text_record(text_record, 4.25, 12.25, 30.25, 30.5, 0.5, 0, 0, width,
                  height, 0, 0, (int32_t)sizeof(text) - 1, 18.0);
  double *q = text_record + 1;
  double raw_x, raw_y;
  projected_mask_point(&bounded, q, ix, iy, &raw_x, &raw_y);
  int target_x = 26 * scale, target_y = (height / 3) * scale;
  double target_sx = (target_x + 0.5) / scale;
  double target_sy = (target_y + 0.5) / scale;
  q[12] = target_sx - raw_x;
  q[13] = target_sy - raw_y;
  double outside_sx, outside_sy;
  projected_mask_point(&full, q, ox, oy, &outside_sx, &outside_sy);
  int outside_x = (int)floor(outside_sx * scale);
  int outside_y = (int)floor(outside_sy * scale);
  assert(outside_x >= 0 && outside_y >= 0 && outside_x < width * scale &&
         outside_y < height * scale);
  double inside_coverage = expected_text_coverage(
      &bounded, q, target_sx, target_sy);
  assert(inside_coverage > 0.5);
  double outside_cx = (outside_x + 0.5) / scale;
  double outside_cy = (outside_y + 0.5) / scale;
  assert(expected_text_coverage(&bounded, q, outside_cx, outside_cy) == 0.0);
  double text_alpha = 0.5 * inside_coverage;
  expect_pixel(0, target_x, target_y,
               (int)lround(255.0 * (1.0 - text_alpha)), 0,
               (int)lround(255.0 * text_alpha), 255);
  expect_pixel(1, outside_x, outside_y, 255, 0, 0, 255);

  int previous_verify = verify_pixels;
  verify_pixels = 0;
  mixed_expected_count = 2;
  verify_mixed_pixels = 1;
  int swaps_before = swap_count;
  assert(gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, data,
                         (int32_t)(sizeof(data) / sizeof(data[0])), text,
                         (int32_t)sizeof(text) - 1) == GPUI_OK);
  assert(swap_count == swaps_before + 1);
  verify_mixed_pixels = 0;
  await_frame(host);
  verify_pixels = previous_verify;
  gpui_linux_text_mask_release_v1(&full);
  gpui_linux_text_mask_release_v1(&bounded);
}

static void test_empty_text_frame(int host, int window) {
  static const uint8_t spaces[] = "   ";
  static const uint8_t glyph[] = "H";
  static const uint8_t sans[] = "sans";
  struct gpui_linux_text_mask empty = {0}, whitespace = {0}, zero_area = {0};
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, NULL, 0, sans, 4, 18, 20, 20,
             4 * 1024 * 1024, &empty) == GPUI_LINUX_TEXT_OK);
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, spaces, (int32_t)sizeof(spaces) - 1, sans,
             4, 18, 20, 20, 4 * 1024 * 1024, &whitespace) ==
         GPUI_LINUX_TEXT_OK);
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI, glyph, 1, sans, 4, 18, 0, 20,
             4 * 1024 * 1024, &zero_area) == GPUI_LINUX_TEXT_OK);
  assert(!empty.pixels && !empty.width && !empty.height);
  assert(!whitespace.pixels && !whitespace.width && !whitespace.height);
  assert(!zero_area.pixels && !zero_area.width && !zero_area.height);

  int width = active->width, height = active->height, scale = active->scale;
  double data[5 + 3 * GPUI_MIXED_STRIDE];
  uint8_t blob[sizeof(spaces)];
  memcpy(blob, spaces, sizeof(spaces) - 1);
  blob[sizeof(spaces) - 1] = glyph[0];
  init_mixed_frame(data, 3, width, height, scale);
  set_full_red_quad(data + 5, width, height);
  double *space_record = data + 5 + GPUI_MIXED_STRIDE;
  set_text_record(space_record, 20, 20, 24, 20, 1, 0, 0, width, height, 0,
                  0, (int32_t)sizeof(spaces) - 1, 18);
  double *zero_record = data + 5 + 2 * GPUI_MIXED_STRIDE;
  set_text_record(zero_record, 60, 20, 0, 20, 1, 0, 0, width, height, 0, 0,
                  1, 18);
  zero_record[20] = (int32_t)sizeof(spaces) - 1;
  mixed_expected_count = 0;
  expect_pixel(0, 25 * scale, 22 * scale, 255, 0, 0, 255);
  expect_pixel(1, 60 * scale, 22 * scale, 255, 0, 0, 255);
  int previous_verify = verify_pixels;
  verify_pixels = 0;
  verify_mixed_pixels = 1;
  int swaps_before = swap_count;
  assert(gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, data,
                         (int32_t)(sizeof(data) / sizeof(data[0])), blob,
                         (int32_t)sizeof(blob)) == GPUI_OK);
  assert(swap_count == swaps_before + 1);
  verify_mixed_pixels = 0;
  await_frame(host);
  verify_pixels = previous_verify;
  gpui_linux_text_mask_release_v1(&empty);
  gpui_linux_text_mask_release_v1(&whitespace);
  gpui_linux_text_mask_release_v1(&zero_area);
}

static void test_capture_fixture(int host, int window) {
  const char *path = getenv("GPUI_UBUNTU_CAPTURE");
  if (!path || !*path)
    return;
  static const uint8_t text[] = "Hi 日本";
  int width = active->width, height = active->height, scale = active->scale;
  double data[5 + 3 * GPUI_MIXED_STRIDE];
  init_mixed_frame(data, 3, width, height, scale);
  set_full_red_quad(data + 5, width, height);
  double *text_record = data + 5 + GPUI_MIXED_STRIDE;
  set_text_record(text_record, 7.25, 13.5, 61.5, 28.25, 0.82, 12.25, 14.25,
                  50.25, 27.5, 0.0, 0.0, (int32_t)sizeof(text) - 1, 20.0);
  double *text_common = text_record + 1;
  text_common[8] = 1.0;
  text_common[9] = 0.0;
  text_common[10] = 0.0;
  text_common[11] = 1.0;
  double *overlay = data + 5 + 2 * GPUI_MIXED_STRIDE;
  set_mixed_common(overlay, 34.0, 21.0, 14.0, 10.0, 20, 225, 55, 255, 1, 0,
                   0, 1, 0, 0, 1, 0, 0, width, height);
  int previous_verify = verify_pixels;
  verify_pixels = 0;
  verify_mixed_pixels = 0;
  capture_next_mixed = 1;
  assert(gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, data,
                         (int32_t)(sizeof(data) / sizeof(data[0])), text,
                         (int32_t)sizeof(text) - 1) == GPUI_OK);
  assert(!capture_next_mixed);
  await_frame(host);
  verify_pixels = previous_verify;
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
static void test_input_serial_lifetime(void) {
  struct host host = {0};
  host.seat_name = 5;
  host.window = 7;
  host.surface = (struct wl_surface *)(uintptr_t)1;

  pointer_enter(&host, NULL, 1, host.surface, 0, 0);
  pointer_button(&host, NULL, 11, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  assert(has_input_serial(&host));
  pointer_leave(&host, NULL, 12, host.surface);
  assert(!has_input_serial(&host));

  keyboard_enter(&host, NULL, 20, host.surface, NULL);
  keyboard_key(&host, NULL, 21, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
  assert(has_input_serial(&host));
  /* Losing pointer focus keeps a keyboard-origin serial usable. */
  pointer_enter(&host, NULL, 22, host.surface, 0, 0);
  pointer_leave(&host, NULL, 23, host.surface);
  assert(has_input_serial(&host));
  keyboard_leave(&host, NULL, 24, host.surface);
  assert(!has_input_serial(&host));

  pointer_enter(&host, NULL, 25, host.surface, 0, 0);
  pointer_button(&host, NULL, 26, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  host.keyboard = (struct wl_keyboard *)(uintptr_t)1;
  seat_caps(&host, NULL, WL_SEAT_CAPABILITY_KEYBOARD);
  assert(!has_input_serial(&host));
  host.keyboard = NULL;

  /* Capability loss invalidates its own provenance, even if the proxy is
   * already absent, while retaining a serial from the unrelated device. */
  keyboard_enter(&host, NULL, 30, host.surface, NULL);
  keyboard_key(&host, NULL, 31, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
  host.keyboard = (struct wl_keyboard *)(uintptr_t)1;
  seat_caps(&host, NULL, WL_SEAT_CAPABILITY_KEYBOARD);
  assert(has_input_serial(&host));
  host.keyboard = NULL;
  keyboard_leave(&host, NULL, 32, host.surface);
  assert(!has_input_serial(&host));
  keyboard_enter(&host, NULL, 33, host.surface, NULL);
  keyboard_key(&host, NULL, 34, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
  seat_caps(&host, NULL, 0);
  assert(!has_input_serial(&host));

  /* A serial observed before gpui_create assigns its window id stays tied to
   * that zero id and cannot become valid for the newly created window. */
  host.window = 0;
  host.pointer_focus_current = 1;
  remember_input_serial(&host, 40, INPUT_SERIAL_POINTER);
  host.window = 8;
  assert(!has_input_serial(&host));

  host.window = 8;
  keyboard_enter(&host, NULL, 41, host.surface, NULL);
  keyboard_key(&host, NULL, 42, 0, 30, WL_KEYBOARD_KEY_STATE_PRESSED);
  assert(has_input_serial(&host));
  host.surface = NULL;
  release_window(&host);
  host.window = 9;
  host.surface = (struct wl_surface *)(uintptr_t)2;
  assert(!has_input_serial(&host));
  pointer_enter(&host, NULL, 42, host.surface, 0, 0);
  pointer_button(&host, NULL, 43, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  assert(has_input_serial(&host));

  /* Entering another surface invalidates the old pointer serial, and a later
   * return to this surface cannot make it valid again without a fresh press. */
  struct wl_surface *other_surface = (struct wl_surface *)(uintptr_t)3;
  pointer_enter(&host, NULL, 44, other_surface, 0, 0);
  pointer_button(&host, NULL, 45, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  pointer_enter(&host, NULL, 46, host.surface, 0, 0);
  assert(!has_input_serial(&host));
  pointer_button(&host, NULL, 47, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  assert(has_input_serial(&host));

  /* Exercise the public write entry point with fake native proxies: an
   * invalidated serial must return Unsupported before touching either one. */
  pointer_leave(&host, NULL, 48, host.surface);
  uint8_t fake_proxy_storage = 0;
  host.token = 91;
  host.owner = pthread_self();
  host.data_device = (struct wl_data_device *)&fake_proxy_storage;
  host.data_manager = (struct wl_data_device_manager *)&fake_proxy_storage;
  struct host *saved_active = active;
  active = &host;
  assert(gpui_write_clipboard(host.token, (const uint8_t *)"stale", 5) ==
         GPUI_UNSUPPORTED);
  active = saved_active;

  /* Removing the seat global leaves late events from its bound proxies unable
   * to restore a writable serial. */
  /* The prior write test used dummy service proxies, not owned Wayland objects. */
  host.data_device = NULL;
  host.data_manager = NULL;
  host.scale = 1;
  host.width = 100;
  host.height = 80;
  pointer_enter(&host, NULL, 50, host.surface, 0, 0);
  pointer_button(&host, NULL, 51, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  assert(has_input_serial(&host));
  global_remove(&host, NULL, host.seat_name);
  pointer_enter(&host, NULL, 52, host.surface, 0, 0);
  pointer_button(&host, NULL, 53, 0, 0x110,
                 WL_POINTER_BUTTON_STATE_PRESSED);
  assert(!has_input_serial(&host));
}
int main(int argc, char **argv) {
  if (argc == 2 && !strcmp(argv[1], "--clipboard-unit")) {
    test_clipboard_transfer_writer();
    test_clipboard_mime_staging();
    test_input_serial_lifetime();
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
      /* Headless Weston may have no seat. Validate the optional capabilities
       * without making them a prerequisite for the rendering/recovery suite. */
      record_optional_capability(host, TEST_CAPABILITY_CLIPBOARD, "clipboard");
      record_optional_capability(host, TEST_CAPABILITY_CURSOR, "cursor");
      /* These calls are intentionally unsupported in this no-input fixture:
       * clipboard writes need a real seat serial, reads need a selection offer,
       * and cursor application needs a pointer-enter serial. */
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
    if (run == 0) {
      int preserved_x, preserved_y;
      present_mixed_pixel_fixture(host, window, &preserved_x, &preserved_y);
      test_v2_preflight_preservation(host, window, preserved_x, preserved_y);
      /* A fresh ordered frame after late invalid/color input proves that the
       * rejected transaction left the renderer usable. */
      present_mixed_pixel_fixture(host, window, &preserved_x, &preserved_y);
      test_fractional_local_bounds(host, window);
      test_empty_text_frame(host, window);
      test_capture_fixture(host, window);
    }
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
    if (run == 0 && !benchmark) {
      int recovered_x, recovered_y;
      /* Exercise the same borrowed text/mask/texture path after GPU recovery
       * and before the existing create-close cleanup check. */
      present_mixed_pixel_fixture(host, window, &recovered_x, &recovered_y);
    }
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
