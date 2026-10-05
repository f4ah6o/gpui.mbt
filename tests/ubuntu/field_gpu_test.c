#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

struct gpui_host;
static EGLBoolean field_verified_swap(EGLDisplay display, EGLSurface surface);
#define eglSwapBuffers field_verified_swap
#include "../../ubuntu/backend.c"
#undef eglSwapBuffers

enum {
  FIELD_DOUBLE_LIMIT = 5 + 23 * 100000,
  FIELD_TEXT_LIMIT = 1024 * 1024,
  FIELD_FILE_LIMIT = 20 * 1024 * 1024
};
_Static_assert(sizeof(double) == 8 && DBL_MANT_DIG == 53 && FLT_RADIX == 2,
               "GPF1 requires IEEE-compatible binary64 storage");
static const char *fixture_labels[] = {
    "end", "selected", "edited", "rejected_newline", "rejected_bidi",
    "scroll_end", "blurred"};
static int field_swap_count;

struct field_fixture {
  const char *label;
  uint8_t *file_bytes;
  size_t file_length;
  uint8_t *original_line;
  size_t original_length;
  uint32_t double_count, text_length;
  double *data;
  const uint8_t *text;
  int revision, anchor, head, rejected;
  int text_record;
  int caret_record;
};

static struct field_fixture fixtures[7];
static struct field_fixture *swapping_fixture;
static const char *capture_path;

static void *read_file(const char *path, size_t *length_out) {
  FILE *file = fopen(path, "rb");
  assert(file);
  assert(fseek(file, 0, SEEK_END) == 0);
  long length = ftell(file);
  assert(length >= 0 && length <= FIELD_FILE_LIMIT);
  assert(fseek(file, 0, SEEK_SET) == 0);
  void *buffer = malloc((size_t)length + 1);
  assert(buffer);
  assert(fread(buffer, 1, (size_t)length, file) == (size_t)length);
  assert(fclose(file) == 0);
  ((uint8_t *)buffer)[length] = 0;
  *length_out = (size_t)length;
  return buffer;
}

static uint32_t read_u32le(const uint8_t *bytes) {
  return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
         ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static double read_f64le(const uint8_t *bytes) {
  uint64_t bits = 0;
  for (int i = 7; i >= 0; --i)
    bits = (bits << 8) | bytes[i];
  double value;
  memcpy(&value, &bits, sizeof(value));
  return value;
}

static void join_path(char *out, size_t capacity, const char *directory,
                      const char *subdirectory, const char *name,
                      const char *suffix) {
  int count = snprintf(out, capacity, "%s/%s/%s%s", directory, subdirectory,
                       name, suffix);
  assert(count > 0 && (size_t)count < capacity);
}

static int utf8_scalar_units(const uint8_t *text, size_t length, size_t *bytes,
                             int *utf16_units) {
  if (*bytes >= length)
    return 0;
  uint8_t lead = text[*bytes];
  uint32_t scalar;
  size_t count;
  if (lead < 0x80) {
    scalar = lead;
    count = 1;
  } else if ((lead & 0xe0) == 0xc0) {
    assert(*bytes + 1 < length && (text[*bytes + 1] & 0xc0) == 0x80);
    scalar = ((uint32_t)(lead & 0x1f) << 6) | (text[*bytes + 1] & 0x3f);
    count = 2;
    assert(scalar >= 0x80);
  } else if ((lead & 0xf0) == 0xe0) {
    assert(*bytes + 2 < length && (text[*bytes + 1] & 0xc0) == 0x80 &&
           (text[*bytes + 2] & 0xc0) == 0x80);
    scalar = ((uint32_t)(lead & 0x0f) << 12) |
             ((uint32_t)(text[*bytes + 1] & 0x3f) << 6) |
             (text[*bytes + 2] & 0x3f);
    count = 3;
    assert(scalar >= 0x800 && !(scalar >= 0xd800 && scalar <= 0xdfff));
  } else {
    assert((lead & 0xf8) == 0xf0 && *bytes + 3 < length &&
           (text[*bytes + 1] & 0xc0) == 0x80 &&
           (text[*bytes + 2] & 0xc0) == 0x80 &&
           (text[*bytes + 3] & 0xc0) == 0x80);
    scalar = ((uint32_t)(lead & 0x07) << 18) |
             ((uint32_t)(text[*bytes + 1] & 0x3f) << 12) |
             ((uint32_t)(text[*bytes + 2] & 0x3f) << 6) |
             (text[*bytes + 3] & 0x3f);
    count = 4;
    assert(scalar >= 0x10000 && scalar <= 0x10ffff);
  }
  *bytes += count;
  *utf16_units = scalar > 0xffff ? 2 : 1;
  return 1;
}

static size_t utf16_offset_to_byte(const uint8_t *text, size_t length,
                                   int target_units) {
  assert(target_units >= 0);
  size_t bytes = 0;
  int units = 0;
  while (bytes < length) {
    if (units == target_units)
      return bytes;
    int scalar_units = 0;
    size_t before = bytes;
    assert(utf8_scalar_units(text, length, &bytes, &scalar_units));
    assert(bytes > before);
    units += scalar_units;
  }
  assert(units == target_units);
  return length;
}

static int utf8_scalar_count(const uint8_t *text, size_t length) {
  size_t bytes = 0;
  int count = 0;
  while (bytes < length) {
    int units = 0;
    assert(utf8_scalar_units(text, length, &bytes, &units));
    ++count;
  }
  return count;
}

static struct field_fixture *load_fixture(const char *directory, int index) {
  struct field_fixture *fixture = &fixtures[index];
  fixture->label = fixture_labels[index];
  char path[4096];
  join_path(path, sizeof(path), directory, "frames", fixture->label, ".gpf");
  fixture->file_bytes = read_file(path, &fixture->file_length);
  assert(fixture->file_length >= 12);
  assert(!memcmp(fixture->file_bytes, "GPF1", 4));
  fixture->double_count = read_u32le(fixture->file_bytes + 4);
  fixture->text_length = read_u32le(fixture->file_bytes + 8);
  assert(fixture->double_count >= 5 && fixture->double_count <= FIELD_DOUBLE_LIMIT);
  assert((fixture->double_count - 5) % 23 == 0);
  assert(fixture->text_length <= FIELD_TEXT_LIMIT);
  size_t expected_length = 12 + (size_t)fixture->double_count * sizeof(double) +
                           fixture->text_length;
  assert(expected_length == fixture->file_length);
  fixture->data = malloc((size_t)fixture->double_count * sizeof(double));
  assert(fixture->data);
  for (uint32_t i = 0; i < fixture->double_count; ++i)
    fixture->data[i] = read_f64le(fixture->file_bytes + 12 + i * sizeof(double));
  fixture->text = fixture->file_bytes + 12 +
                  (size_t)fixture->double_count * sizeof(double);
  for (uint32_t i = 0; i < fixture->double_count; ++i)
    assert(isfinite(fixture->data[i]));
  uint32_t item_count = (fixture->double_count - 5) / 23;
  int expected_items = index == 1 ? 9 : (index == 6 ? 7 : 8);
  assert(item_count == (uint32_t)expected_items);
  fixture->text_record = -1;
  fixture->caret_record = -1;
  int text_records = 0;
  for (uint32_t i = 0; i < item_count; ++i) {
    double *record = fixture->data + 5 + i * 23;
    assert(record[0] == 0 || record[0] == 1);
    if (record[0] == 1) {
      ++text_records;
      fixture->text_record = (int)i;
      assert(record[20] >= 0 && record[21] > 0 && record[22] == 18);
      assert(floor(record[20]) == record[20] && floor(record[21]) == record[21]);
      assert(record[20] + record[21] <= fixture->text_length);
    } else {
      assert(record[20] == 0 && record[21] == 0 && record[22] == 0);
    }
  }
  assert(text_records == 1 && fixture->text_record >= 0);
  if (index == 6)
    assert(fixture->caret_record == -1);
  else
    fixture->caret_record = (int)item_count - 1;
  return fixture;
}

static void parse_source_header(struct field_fixture *fixture,
                                const char *directory) {
  char path[4096], label[64], rejected[8];
  join_path(path, sizeof(path), directory, "originals", fixture->label,
            ".jsonl");
  fixture->original_line = read_file(path, &fixture->original_length);
  assert(fixture->original_length > 2 &&
         fixture->original_line[fixture->original_length - 1] == '\n');
  int consumed = 0;
  int fields = sscanf((char *)fixture->original_line,
      "{\"label\":\"%63[^\"]\",\"rejected\":%7[^,],\"revision\":%d,\"anchor\":%d,\"head\":%d,\"scene\":%n",
      label, rejected, &fixture->revision, &fixture->anchor, &fixture->head,
      &consumed);
  assert(fields == 5 && consumed > 0 && !strcmp(label, fixture->label));
  assert(!strcmp(rejected, "true") || !strcmp(rejected, "false"));
  fixture->rejected = !strcmp(rejected, "true");
  const char *scene_marker = strstr((char *)fixture->original_line,
                                   ",\"scene\":");
  assert(scene_marker && scene_marker + 9 ==
                             (char *)fixture->original_line + consumed);
  assert(fixture->original_line[fixture->original_length - 2] == '}');
  assert(fixture->anchor >= 0 && fixture->head >= 0);
  assert(fixture->rejected == (strstr(fixture->label, "rejected_") == fixture->label));
}

static size_t scene_json_length(const struct field_fixture *fixture,
                               const uint8_t **scene_out) {
  const char *marker = strstr((const char *)fixture->original_line,
                              ",\"scene\":");
  assert(marker);
  const uint8_t *scene = (const uint8_t *)marker + strlen(",\"scene\":");
  size_t length = (size_t)((const uint8_t *)fixture->original_line +
                           fixture->original_length - 2 - scene);
  *scene_out = scene;
  return length;
}

static void check_manifest_head(const char *directory) {
  char path[4096], expected[80] = "";
  join_path(path, sizeof(path), directory, "", "manifest", ".json");
  size_t length = 0;
  char *manifest = read_file(path, &length);
  (void)length;
  const char *key = "\"source_head\":\"";
  char *found = strstr(manifest, key);
  assert(found);
  found += strlen(key);
  char *end = strchr(found, '"');
  assert(end && (size_t)(end - found) < sizeof(expected));
  memcpy(expected, found, (size_t)(end - found));
  expected[end - found] = 0;
  assert(strstr(manifest, "\"font_family\":\"sans\""));
  assert(strstr(manifest, "\"font_size\":18"));
  free(manifest);
  FILE *git = popen("git rev-parse HEAD 2>/dev/null", "r");
  assert(git);
  char executed_head[80] = "";
  assert(fgets(executed_head, sizeof(executed_head), git));
  int status = pclose(git);
  assert(status == 0);
  size_t n = strlen(executed_head);
  while (n && (executed_head[n - 1] == '\n' || executed_head[n - 1] == '\r'))
    executed_head[--n] = 0;
  assert(!strcmp(expected, executed_head));
}

static void verify_fixture_set(const char *directory) {
  check_manifest_head(directory);
  for (int i = 0; i < 7; ++i) {
    load_fixture(directory, i);
    parse_source_header(&fixtures[i], directory);
    struct field_fixture *fixture = &fixtures[i];
    assert(fixture->data[0] == 0 && fixture->data[1] == 0 &&
           fixture->data[2] == 640 && fixture->data[3] == 240 &&
           fixture->data[4] == 1);
    double *background = fixture->data + 6; /* first record common fields */
    assert(background[0] == 0 && background[1] == 0 &&
           background[2] == 640 && background[3] == 240);
    assert(background[4] == 24 && background[5] == 28 &&
           background[6] == 36 && background[7] == 255);
    double *field = fixture->data + 5 + 23 + 1;
    assert(field[0] == 32 && field[1] == 28 && field[2] == 180 &&
           field[3] == 44 && field[4] == 255 && field[5] == 255 &&
           field[6] == 255 && field[7] == 255);
    double *text_record = fixture->data + 5 + fixture->text_record * 23;
    double *text = text_record + 1;
    assert(text[15] == 36 && text[16] == 32 && text[17] == 172 &&
           text[18] == 36);
    assert(text_record[20] == 0 && text_record[21] > 0 &&
           text_record[22] == 18);
    int rejected = i == 3 || i == 4;
    assert(fixture->rejected == rejected);
    if (i == 5) {
      double *caret = fixture->data + 5 + fixture->caret_record * 23 + 1;
      assert(text[12] < 36 && fabs(caret[0] - 207.0) < 1e-8 &&
             fabs(caret[2] - 1.0) < 1e-8);
    }
  }

  static const uint8_t short_text[] = "Hi \xe6\x97\xa5\xe6\x9c\xac";
  static const uint8_t edited_text[] = "Edited \xe6\x97\xa5\xe6\x9c\xac";
  static const uint8_t long_text[] = "Wide \xe6\x97\xa5\xe6\x9c\xac ";
  for (int i = 0; i < 7; ++i) {
    struct field_fixture *fixture = &fixtures[i];
    double *text_record = fixture->data + 5 + fixture->text_record * 23;
    size_t offset = (size_t)text_record[20], bytes = (size_t)text_record[21];
    const uint8_t *expected = NULL;
    size_t expected_length = 0;
    if (i <= 1) {
      expected = short_text;
      expected_length = sizeof(short_text) - 1;
    } else if (i <= 4) {
      expected = edited_text;
      expected_length = sizeof(edited_text) - 1;
    } else {
      expected = long_text;
      expected_length = sizeof(long_text) - 1;
    }
    if (i <= 4) {
      assert(bytes == expected_length);
      assert(!memcmp(fixture->text + offset, expected, expected_length));
    } else {
      assert(bytes == expected_length * 8);
      for (int repeat = 0; repeat < 8; ++repeat)
        assert(!memcmp(fixture->text + offset + (size_t)repeat * expected_length,
                       expected, expected_length));
    }
  }

  struct field_fixture *edited = &fixtures[2];
  const uint8_t *edited_scene = NULL;
  size_t edited_scene_length = scene_json_length(edited, &edited_scene);
  for (int i = 3; i <= 4; ++i) {
    struct field_fixture *rejected = &fixtures[i];
    assert(rejected->revision == edited->revision &&
           rejected->anchor == edited->anchor && rejected->head == edited->head);
    const uint8_t *rejected_scene = NULL;
    size_t rejected_scene_length = scene_json_length(rejected, &rejected_scene);
    assert(rejected_scene_length == edited_scene_length);
    assert(!memcmp(rejected_scene, edited_scene, edited_scene_length));
    assert(rejected->file_length == edited->file_length);
    assert(!memcmp(rejected->file_bytes, edited->file_bytes, edited->file_length));
  }
}

static double *item_record(struct field_fixture *fixture, int index) {
  uint32_t count = (fixture->double_count - 5) / 23;
  assert(index >= 0 && (uint32_t)index < count);
  return fixture->data + 5 + index * 23;
}

static void get_logical_pixel(double x, double y, unsigned char pixel[4]) {
  int device_x = (int)floor(x * active->scale);
  int device_y = (int)floor(y * active->scale);
  int height = active->height * active->scale;
  assert(device_x >= 0 && device_x < active->width * active->scale &&
         device_y >= 0 && device_y < height);
  glReadPixels(device_x, height - 1 - device_y, 1, 1, GL_RGBA,
               GL_UNSIGNED_BYTE, pixel);
  assert(glGetError() == GL_NO_ERROR);
}

static void expect_rgb_at(double x, double y, int r, int g, int b,
                          int tolerance) {
  unsigned char pixel[4];
  get_logical_pixel(x, y, pixel);
  assert(abs((int)pixel[0] - r) <= tolerance &&
         abs((int)pixel[1] - g) <= tolerance &&
         abs((int)pixel[2] - b) <= tolerance && pixel[3] >= 250);
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
  return ((a * (1 - tx) + b * tx) * (1 - ty) +
          (c * (1 - tx) + d * tx) * ty) / 255.0;
}

static double expected_mask_coverage(const struct gpui_linux_text_mask *mask,
                                     const double *q, double sx, double sy) {
  if (sx < q[15] || sy < q[16] || sx >= q[15] + q[17] ||
      sy >= q[16] + q[18])
    return 0.0;
  double determinant = q[8] * q[11] - q[9] * q[10];
  assert(fabs(determinant) > 1e-9);
  double dx = sx - q[12], dy = sy - q[13];
  double px = (q[11] * dx - q[10] * dy) / determinant;
  double py = (-q[9] * dx + q[8] * dy) / determinant;
  if (px < q[0] + mask->left || py < q[1] + mask->top ||
      px >= q[0] + mask->right || py >= q[1] + mask->bottom)
    return 0.0;
  double u = (px - q[0] - mask->left) / mask->width;
  double v = (py - q[1] - mask->top) / mask->height;
  return mask_linear_sample(mask, u, v);
}

static int caret_geometry(const struct field_fixture *fixture, int utf16_offset,
                          double rect[4]) {
  static const uint8_t sans[] = "sans";
  double *text_record = fixture->data + 5 + fixture->text_record * 23;
  size_t text_offset = (size_t)text_record[21 - 1];
  size_t text_length = (size_t)text_record[22 - 1];
  const uint8_t *text = fixture->text + text_offset;
  size_t byte_offset = utf16_offset_to_byte(text, text_length, utf16_offset);
  int scalars = utf8_scalar_count(text, text_length);
  int capacity = GPUI_LINUX_TEXT_HEADER_DOUBLES +
                 (scalars + 1) * GPUI_LINUX_TEXT_CARET_DOUBLES;
  double *measurement = calloc((size_t)capacity, sizeof(double));
  assert(measurement);
  assert(gpui_linux_text_measure_v1(GPUI_LINUX_TEXT_ABI, text,
                                    (int32_t)text_length, sans, 4, 18.0,
                                    measurement, capacity) == GPUI_LINUX_TEXT_OK);
  int found = 0;
  for (int i = 0; i < (int)measurement[11]; ++i) {
    double *caret = measurement + GPUI_LINUX_TEXT_HEADER_DOUBLES +
                    i * GPUI_LINUX_TEXT_CARET_DOUBLES;
    if (caret[0] == (double)byte_offset && caret[1] == 1.0) {
      for (int c = 0; c < 4; ++c)
        rect[c] = caret[2 + c];
      found = 1;
      break;
    }
  }
  free(measurement);
  return found;
}

static struct gpui_linux_text_mask make_mask(struct field_fixture *fixture) {
  static const uint8_t sans[] = "sans";
  struct gpui_linux_text_mask mask = {0};
  double *text_record = fixture->data + 5 + fixture->text_record * 23;
  assert(gpui_linux_text_raster_v1(
             GPUI_LINUX_TEXT_ABI,
             fixture->text + (size_t)text_record[20],
             (int32_t)text_record[21], sans, 4, text_record[22],
             (text_record + 1)[2], (text_record + 1)[3],
             4 * 1024 * 1024, &mask) == GPUI_LINUX_TEXT_OK);
  assert(mask.pixels && mask.width > 0 && mask.height > 0);
  return mask;
}

static void assert_text_coverage(struct field_fixture *fixture,
                                 const struct gpui_linux_text_mask *mask) {
  double *record = fixture->data + 5 + fixture->text_record * 23;
  double *q = record + 1;
  int height = active->height * active->scale;
  int found = 0;
  for (int y = (int)(32 * active->scale); y < (int)(68 * active->scale) && !found; ++y) {
    for (int x = (int)(36 * active->scale); x < (int)(208 * active->scale); ++x) {
      double sx = (x + 0.5) / active->scale;
      double sy = (y + 0.5) / active->scale;
      if (fixture->caret_record >= 0) {
        double *caret = item_record(fixture, fixture->caret_record) + 1;
        if (sx >= caret[0] && sx < caret[0] + caret[2] &&
            sy >= caret[1] && sy < caret[1] + caret[3])
          continue;
      }
      if (expected_mask_coverage(mask, q, sx, sy) < 0.82)
        continue;
      unsigned char pixel[4];
      glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(glGetError() == GL_NO_ERROR);
      /* Independent A8 coverage samples must show the field's dark ink. */
      assert(pixel[0] < 105 && pixel[1] < 110 && pixel[2] < 120);
      found = 1;
      break;
    }
  }
  assert(found);
  /* All four logical padding regions stay white. This catches text escaping
   * the viewport-space content clip, including in the horizontally scrolled
   * fixture, without treating a captured frame as its own oracle. */
  expect_rgb_at(34.5, 45.5, 255, 255, 255, 2);
  expect_rgb_at(209.5, 45.5, 255, 255, 255, 2);
  expect_rgb_at(100.5, 31.5, 255, 255, 255, 2);
  expect_rgb_at(100.5, 69.5, 255, 255, 255, 2);
}

static void assert_selection_coverage(struct field_fixture *fixture,
                                      const struct gpui_linux_text_mask *mask) {
  assert(!strcmp(fixture->label, "selected"));
  int selection_record = 6;
  double *selection_q = item_record(fixture, selection_record) + 1;
  double *text_record = fixture->data + 5 + fixture->text_record * 23;
  double *text_q = text_record + 1;
  double anchor[4], head[4];
  assert(caret_geometry(fixture, fixture->anchor, anchor));
  assert(caret_geometry(fixture, fixture->head, head));
  double left = text_q[12] + fmin(anchor[0], head[0]);
  double right = text_q[12] + fmax(anchor[0], head[0]);
  size_t text_offset = (size_t)text_record[20];
  size_t text_length = (size_t)text_record[21];
  const uint8_t *text = fixture->text + text_offset;
  static const uint8_t sans[] = "sans";
  int capacity = GPUI_LINUX_TEXT_HEADER_DOUBLES +
                 (utf8_scalar_count(text, text_length) + 1) *
                     GPUI_LINUX_TEXT_CARET_DOUBLES;
  double *measurement = calloc((size_t)capacity, sizeof(double));
  assert(measurement);
  assert(gpui_linux_text_measure_v1(GPUI_LINUX_TEXT_ABI, text,
                                    (int32_t)text_length, sans, 4, 18.0,
                                    measurement, capacity) == GPUI_LINUX_TEXT_OK);
  /* Selection paint follows the full logical line; the caret below keeps the
   * selected head's mixed-font strong-caret metrics. */
  double top = text_q[13] + measurement[1];
  double bottom = top + measurement[3];
  free(measurement);
  assert(fabs(selection_q[0] - left) < 0.02 &&
         fabs(selection_q[1] - top) < 0.02 &&
         fabs(selection_q[2] - (right - left)) < 0.02 &&
         fabs(selection_q[3] - (bottom - top)) < 0.02);

  int height = active->height * active->scale;
  int found = 0;
  for (int y = (int)ceil((top + 1) * active->scale - 0.5);
       y < (int)floor((bottom - 1) * active->scale + 0.5) && !found; ++y) {
    for (int x = (int)ceil((left + 1) * active->scale - 0.5);
         x < (int)floor((right - 1) * active->scale + 0.5); ++x) {
      double sx = (x + 0.5) / active->scale;
      double sy = (y + 0.5) / active->scale;
      if (expected_mask_coverage(mask, text_q, sx, sy) > 0.04)
        continue;
      unsigned char pixel[4];
      glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(glGetError() == GL_NO_ERROR);
      /* 80/255-alpha blue selection over the independently known white fill. */
      if (abs((int)pixel[0] - 195) <= 8 &&
          abs((int)pixel[1] - 208) <= 8 &&
          abs((int)pixel[2] - 246) <= 8) {
        found = 1;
        break;
      }
    }
  }
  assert(found);
}

static void verify_field_pixels(struct field_fixture *fixture) {
  assert(fixture && active && active->egl_surface != EGL_NO_SURFACE);
  unsigned char pixel[4];
  int focused = strcmp(fixture->label, "blurred") != 0;
  expect_rgb_at(10.5, 10.5, 24, 28, 36, 3);
  expect_rgb_at((double)active->width - 5.5,
                (double)active->height - 5.5, 24, 28, 36, 3);
  expect_rgb_at(45.5, 28.5,
                focused ? 55 : 130, focused ? 105 : 140,
                focused ? 220 : 150, 3);
  expect_rgb_at(100.5, 71.5,
                focused ? 55 : 130, focused ? 105 : 140,
                focused ? 220 : 150, 3);
  expect_rgb_at(32.5, 50.5,
                focused ? 55 : 130, focused ? 105 : 140,
                focused ? 220 : 150, 3);
  expect_rgb_at(211.5, 50.5,
                focused ? 55 : 130, focused ? 105 : 140,
                focused ? 220 : 150, 3);
  expect_rgb_at(100.5, 70.5, 255, 255, 255, 2);

  struct gpui_linux_text_mask mask = make_mask(fixture);
  assert_text_coverage(fixture, &mask);
  if (!strcmp(fixture->label, "selected"))
    assert_selection_coverage(fixture, &mask);

  if (focused) {
    double caret[4];
    assert(caret_geometry(fixture, fixture->head, caret));
    double *text_record = fixture->data + 5 + fixture->text_record * 23;
    double *text_q = text_record + 1;
    double expected_x = text_q[12] + caret[0];
    double expected_y = text_q[13] + caret[1];
    double *caret_q = item_record(fixture, fixture->caret_record) + 1;
    assert(fabs(caret_q[0] - expected_x) < 0.02 &&
           fabs(caret_q[1] - expected_y) < 0.02 &&
           fabs(caret_q[2] - 1.0) < 1e-9 &&
           fabs(caret_q[3] - caret[3]) < 0.02);
    if (!strcmp(fixture->label, "scroll_end"))
      assert(fabs(expected_x - 207.0) < 0.02);
    get_logical_pixel(expected_x + 0.5, expected_y + caret[3] / 2,
                      pixel);
    assert(pixel[0] < 105 && pixel[1] < 110 && pixel[2] < 120);
  } else {
    assert(fixture->caret_record == -1);
    /* The long fixture ends in a space, so this exact right-edge sample is
     * clear in the independent A8 oracle. Blur must remove its former caret. */
    double *text_record = fixture->data + 5 + fixture->text_record * 23;
    double *text_q = text_record + 1;
    double caret[4];
    assert(caret_geometry(fixture, fixture->head, caret));
    double x = text_q[12] + caret[0];
    double y = text_q[13] + caret[1] + caret[3] / 2;
    assert(fabs(x - 207.0) < 0.02);
    assert(expected_mask_coverage(&mask, text_q, x + 0.5, y) < 0.05);
    expect_rgb_at(x + 0.5, y, 255, 255, 255, 2);
  }
  gpui_linux_text_mask_release_v1(&mask);
}

static void capture_field_ppm(const char *path) {
  if (!path || !*path)
    return;
  int width = active->width * active->scale;
  int height = active->height * active->scale;
  size_t bytes = (size_t)width * height * 4;
  unsigned char *rgba = malloc(bytes);
  assert(rgba);
  glPixelStorei(GL_PACK_ALIGNMENT, 1);
  glReadPixels(0, 0, width, height, GL_RGBA, GL_UNSIGNED_BYTE, rgba);
  assert(glGetError() == GL_NO_ERROR);
  char head[80] = "unknown";
  FILE *git = popen("git rev-parse HEAD 2>/dev/null", "r");
  if (git) {
    if (fgets(head, sizeof(head), git)) {
      size_t length = strlen(head);
      while (length && (head[length - 1] == '\n' || head[length - 1] == '\r'))
        head[--length] = 0;
    }
    (void)pclose(git);
  }
  const char *renderer = (const char *)glGetString(GL_RENDERER);
  if (!renderer) renderer = "unknown";
  FILE *file = fopen(path, "wb");
  assert(file);
  assert(fprintf(file, "P6\n# head=%s scale=%d renderer=%s fixture=%s\n%d %d\n255\n",
                 head, active->scale, renderer,
                 swapping_fixture ? swapping_fixture->label : "unknown",
                 width, height) > 0);
  for (int row = height - 1; row >= 0; --row) {
    for (int column = 0; column < width; ++column) {
      const unsigned char *pixel = rgba + ((size_t)row * width + column) * 4;
      assert(fwrite(pixel, 1, 3, file) == 3);
    }
  }
  assert(fclose(file) == 0);
  free(rgba);
}

static EGLBoolean field_verified_swap(EGLDisplay display, EGLSurface surface) {
  ++field_swap_count;
  verify_field_pixels(swapping_fixture);
  if (capture_path && swapping_fixture &&
      !strcmp(swapping_fixture->label, "scroll_end"))
    capture_field_ppm(capture_path);
  return eglSwapBuffers(display, surface);
}

/* FIELD_FRAME_WAIT_BEGIN: shared test-only deadline/queue contract. */
static uint64_t field_monotonic_ns(void) {
  struct timespec now;
  assert(clock_gettime(CLOCK_MONOTONIC, &now) == 0);
  assert(now.tv_sec >= 0 && now.tv_nsec >= 0 && now.tv_nsec < 1000000000L);
  uint64_t seconds = (uint64_t)now.tv_sec, nanos = (uint64_t)now.tv_nsec;
  assert(seconds <= (UINT64_MAX - nanos) / UINT64_C(1000000000));
  return seconds * UINT64_C(1000000000) + nanos;
}

static void drain_field_events(int host) {
  double event[10];
  int result;
  while ((result = gpui_next(host, event)) == 1) {
    /* This renderer-only fixture never arms direct text. Close/destroy are
     * unexpected, and native/transport errors must not masquerade as empty. */
    assert(event[0] != 3.0 && event[0] != 4.0);
  }
  assert(result == 0);
}

static void await_field_frame(int host) {
  const uint64_t timeout_ns = UINT64_C(5000000000);
  uint64_t start = field_monotonic_ns();
  for (;;) {
    /* Dispatch deliberately uses timeout0 while framework events are queued.
     * Consume those events first so a pending frame can actually block/pump. */
    drain_field_events(host);
    if (!active->frame)
      break;
    uint64_t now = field_monotonic_ns();
    assert(now >= start && now - start < timeout_ns);
    uint64_t remaining = timeout_ns - (now - start);
    int timeout_ms = (int)((remaining + UINT64_C(999999)) / UINT64_C(1000000));
    if (timeout_ms > 100) timeout_ms = 100;
    assert(gpui_dispatch(host, timeout_ms) == GPUI_OK);
  }
  assert(!active->frame);
}
/* FIELD_FRAME_WAIT_END */

static void normalize_viewport(struct field_fixture *fixture,
                               double *normalized, int width, int height,
                               int scale) {
  memcpy(normalized, fixture->data,
         (size_t)fixture->double_count * sizeof(double));
  normalized[0] = normalized[1] = 0;
  normalized[2] = width;
  normalized[3] = height;
  normalized[4] = scale;
  /* Only the viewport header and first full-viewport background record are
   * normalized. Field geometry, clips, transforms, text and order are retained. */
  double *background = normalized + 5;
  assert(background[0] == 0);
  background[3] = width;
  background[4] = height;
  background[16] = 0;
  background[17] = 0;
  background[18] = width;
  background[19] = height;
}

static void present_fixture(int host, int window, struct field_fixture *fixture) {
  double *normalized = malloc((size_t)fixture->double_count * sizeof(double));
  assert(normalized);
  normalize_viewport(fixture, normalized, active->width, active->height,
                     active->scale);
  int swaps_before = field_swap_count;
  swapping_fixture = fixture;
  int status = gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, normalized,
                               (int32_t)fixture->double_count, fixture->text,
                               (int32_t)fixture->text_length);
  assert(status == GPUI_OK);
  assert(field_swap_count == swaps_before + 1);
  await_field_frame(host);
  swapping_fixture = NULL;
  free(normalized);
}

/* These rejected records were produced by actual headless control handling.
 * Identity is a source/fixture assertion, not a live GPU rejection oracle. */
static void assert_rejected_fixture_identity(struct field_fixture *fixture) {
  assert(fixture->rejected);
  struct field_fixture *edited = &fixtures[2];
  assert(fixture->revision == edited->revision &&
         fixture->anchor == edited->anchor && fixture->head == edited->head);
  assert(fixture->file_length == edited->file_length &&
         !memcmp(fixture->file_bytes, edited->file_bytes, fixture->file_length));
  const uint8_t *left = NULL, *right = NULL;
  size_t left_length = scene_json_length(fixture, &left);
  size_t right_length = scene_json_length(edited, &right);
  assert(left_length == right_length && !memcmp(left, right, left_length));
  puts("GPUI_FIELD_REJECTION tier=headless_control_and_fixture_identity gpu_rejection=unrun");
}

int main(void) {
  const char *directory = getenv("GPUI_FIELD_FIXTURES_DIR");
  assert(directory && *directory);
  capture_path = getenv("GPUI_FIELD_CAPTURE");
  verify_fixture_set(directory);

  int host = gpui_start(GPUI_UBUNTU_ABI);
  assert(host > 0);
  static const uint8_t title[] = "TextField GPU fixture";
  int window = gpui_create(host, 640, 240, title, (int32_t)sizeof(title) - 1);
  assert(window > 0);
  for (int attempt = 0; attempt < 50 && !active->configured; ++attempt)
    assert(gpui_dispatch(host, 100) == GPUI_OK);
  assert(active->configured && active->width >= 220 && active->height >= 80);
  double metrics[3] = {0};
  assert(gpui_metrics(host, window, metrics) == GPUI_OK);
  assert(metrics[0] == active->width && metrics[1] == active->height &&
         metrics[2] == active->scale);
  const char *expected_scale = getenv("GPUI_EXPECT_SCALE");
  if (expected_scale) {
    assert(!strcmp(expected_scale, "1") || !strcmp(expected_scale, "2"));
    assert(metrics[2] == (double)(expected_scale[0] - '0'));
  }

  for (int i = 0; i < 7; ++i) {
    if (i == 3 || i == 4) {
      assert_rejected_fixture_identity(&fixtures[i]);
      continue;
    }
    present_fixture(host, window, &fixtures[i]);
  }

  assert(gpui_close(host, window) == GPUI_OK);
  assert(gpui_destroy(host, window) == GPUI_OK);
  assert(gpui_stop(host) == GPUI_OK);
  assert(field_swap_count == 5);
  for (int i = 0; i < 7; ++i) {
    free(fixtures[i].file_bytes);
    free(fixtures[i].original_line);
    free(fixtures[i].data);
  }
  puts("Linux TextField injected accepted-frame GPU pixel oracle passed.");
  return 0;
}
