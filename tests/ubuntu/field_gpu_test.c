#define _POSIX_C_SOURCE 200809L
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <glib.h>
#include <assert.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

struct gpui_host;
static EGLBoolean field_verified_swap(EGLDisplay display, EGLSurface surface);
#define eglSwapBuffers field_verified_swap
#include "../../ubuntu/backend.c"
#undef eglSwapBuffers
static double expected_mask_coverage(
    const struct gpui_linux_text_mask_v2 *reference, const double *record,
    const double *q, double sx, double sy);

enum {
  FIELD_DOUBLE_LIMIT = 5 + 25 * 100000,
  FIELD_STRIDE_LEGACY = 23,
  FIELD_STRIDE_ORIGIN = 25,
  FIELD_FIXTURE_CAPACITY = 11,
  FIELD_TEXT_LIMIT = 1024 * 1024,
  FIELD_FILE_LIMIT = 20 * 1024 * 1024
};
_Static_assert(sizeof(double) == 8 && DBL_MANT_DIG == 53 && FLT_RADIX == 2,
               "GPF1/GPF2 require IEEE-compatible binary64 storage");
static const char *fixture_labels[] = {
    "end", "selected", "edited", "rejected_newline", "rejected_bidi",
    "scroll_end", "blurred", "j_start", "accent_start", "j_scroll",
    "accent_scroll"};
static int field_swap_count;
static int fixture_swap_count;
static int fixture_count = 7;
static int fixture_stride = FIELD_STRIDE_LEGACY;
static int fixture_abi = GPUI_MIXED_FRAME_ABI;
static char fixture_source_head[80];
static char *fixture_manifest;

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
  int text_kind;
  int caret_record;
};

static struct field_fixture fixtures[FIELD_FIXTURE_CAPACITY];
static struct field_fixture *swapping_fixture;
static const char *capture_path;
static int diagnostic_mode;
static double *diagnostic_record;

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
  assert(!memcmp(fixture->file_bytes, fixture_abi == GPUI_ORIGIN_FRAME_ABI
                                      ? "GPF2" : "GPF1", 4));
  fixture->double_count = read_u32le(fixture->file_bytes + 4);
  fixture->text_length = read_u32le(fixture->file_bytes + 8);
  assert(fixture->double_count >= 5 && fixture->double_count <= FIELD_DOUBLE_LIMIT);
  assert((fixture->double_count - 5) % fixture_stride == 0);
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
  uint32_t item_count = (fixture->double_count - 5) / fixture_stride;
  int expected_items = index == 1 ? 9 : (index == 6 ? 7 : 8);
  assert(item_count == (uint32_t)expected_items);
  fixture->text_record = -1;
  fixture->caret_record = -1;
  int text_records = 0;
  for (uint32_t i = 0; i < item_count; ++i) {
    double *record = fixture->data + 5 + i * fixture_stride;
    assert(record[0] == 0 || record[0] == 1 ||
           (fixture_abi == GPUI_ORIGIN_FRAME_ABI && record[0] == 2));
    if (fixture_abi == GPUI_ORIGIN_FRAME_ABI && record[0] != 2)
      assert(record[23] == 0 && record[24] == 0);
    if (record[0] == 1 || record[0] == 2) {
      ++text_records;
      fixture->text_record = (int)i;
      fixture->text_kind = (int)record[0];
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

static char *manifest_value(const char *manifest, const char *label,
                           const char *field) {
  char label_key[128], field_key[128];
  const char *start = manifest;
  const char *end_object = manifest + strlen(manifest);
  if (label) {
    int n = snprintf(label_key, sizeof(label_key), "\"label\":\"%s\"", label);
    assert(n > 0 && (size_t)n < sizeof(label_key));
    start = strstr(manifest, label_key);
    assert(start);
    while (start > manifest && *start != '{')
      --start;
    end_object = strchr(start, '}');
    assert(end_object);
  }
  int n = snprintf(field_key, sizeof(field_key), "\"%s\":\"", field);
  assert(n > 0 && (size_t)n < sizeof(field_key));
  const char *value = strstr(start, field_key);
  assert(value && value < end_object);
  value += strlen(field_key);
  const char *end_value = strchr(value, '\"');
  assert(end_value && end_value <= end_object);
  return g_strndup(value, (gsize)(end_value - value));
}

static char *sha256_hex(const void *bytes, size_t length) {
  return g_compute_checksum_for_data(G_CHECKSUM_SHA256, bytes, (gsize)length);
}

static int profile_has_sha256_file_line(const char *profile) {
  const char *line = profile;
  while (*line) {
    const char *end = strchr(line, '\n');
    if (!end)
      end = line + strlen(line);
    if ((size_t)(end - line) > 66) {
      int valid = 1;
      for (int i = 0; i < 64; ++i)
        if (!((line[i] >= '0' && line[i] <= '9') ||
              (line[i] >= 'a' && line[i] <= 'f') ||
              (line[i] >= 'A' && line[i] <= 'F'))) {
          valid = 0;
          break;
        }
      if (valid && line[64] == ' ' && line[65] == ' ')
        return 1;
    }
    line = *end ? end + 1 : end;
  }
  return 0;
}

static void check_manifest_head(const char *directory) {
  char path[4096];
  join_path(path, sizeof(path), directory, "", "manifest", ".json");
  size_t length = 0;
  fixture_manifest = read_file(path, &length);
  assert(length > 0);
  const char *format = strstr(fixture_manifest, "\"format\":\"");
  assert(format);
  if (strstr(format, "\"format\":\"GPF2\"")) {
    fixture_abi = GPUI_ORIGIN_FRAME_ABI;
    fixture_stride = FIELD_STRIDE_ORIGIN;
    fixture_count = 11;
    assert(strstr(fixture_manifest, "\"abi\":3"));
    assert(strstr(fixture_manifest, "\"stride_doubles\":25"));
  } else {
    fixture_abi = GPUI_MIXED_FRAME_ABI;
    fixture_stride = FIELD_STRIDE_LEGACY;
    fixture_count = 7;
    assert(strstr(fixture_manifest, "\"format\":\"GPF1\""));
    assert(strstr(fixture_manifest, "\"abi\":2"));
    assert(strstr(fixture_manifest, "\"stride_doubles\":23"));
  }
  char *expected = manifest_value(fixture_manifest, NULL, "source_head");
  snprintf(fixture_source_head, sizeof(fixture_source_head), "%s", expected);
  g_free(expected);
  assert(strstr(fixture_manifest, "\"font_family\":\"sans\""));
  assert(strstr(fixture_manifest, "\"font_size\":18"));
  if (fixture_abi == GPUI_ORIGIN_FRAME_ABI) {
    const char *profile_sha_key = "\"font_profile\":{\"path\":\"../font-profile.txt\",\"sha256\":\"";
    const char *profile_sha = strstr(fixture_manifest, profile_sha_key);
    assert(profile_sha);
    profile_sha += strlen(profile_sha_key);
    const char *profile_sha_end = strchr(profile_sha, '\"');
    assert(profile_sha_end && (size_t)(profile_sha_end - profile_sha) == 64);
    char expected_profile_sha[65];
    memcpy(expected_profile_sha, profile_sha, 64);
    expected_profile_sha[64] = 0;
    char profile_path[4096];
    join_path(profile_path, sizeof(profile_path), directory, "..", "font-profile", ".txt");
    size_t profile_length = 0;
    char *profile = read_file(profile_path, &profile_length);
    char *actual_profile_sha = sha256_hex(profile, profile_length);
    assert(!strcmp(expected_profile_sha, actual_profile_sha));
    char expected_head_line[96];
    snprintf(expected_head_line, sizeof(expected_head_line), "source_head=%s", fixture_source_head);
    assert(strstr(profile, expected_head_line));
    assert(strstr(profile, "fc_match_request=sans\n"));
    assert(strstr(profile, "fc_match_request=sans:charset=65e5\n"));
    assert(strstr(profile, "fontconfig="));
    assert(profile_has_sha256_file_line(profile));
    g_free(actual_profile_sha);
    free(profile);
  }
  FILE *git = popen("git rev-parse HEAD 2>/dev/null", "r");
  assert(git);
  char executed_head[80] = "";
  assert(fgets(executed_head, sizeof(executed_head), git));
  int status = pclose(git);
  assert(status == 0);
  size_t n = strlen(executed_head);
  while (n && (executed_head[n - 1] == '\n' || executed_head[n - 1] == '\r'))
    executed_head[--n] = 0;
  assert(!strcmp(fixture_source_head, executed_head));
}

static void verify_fixture_set(const char *directory) {
  check_manifest_head(directory);
  for (int i = 0; i < fixture_count; ++i) {
    load_fixture(directory, i);
    parse_source_header(&fixtures[i], directory);
    struct field_fixture *fixture = &fixtures[i];
    char *expected_line_sha = manifest_value(fixture_manifest, fixture->label,
                                             "original_line_sha256");
    char *actual_line_sha = sha256_hex(fixture->original_line,
                                       fixture->original_length);
    assert(!strcmp(expected_line_sha, actual_line_sha));
    g_free(expected_line_sha);
    g_free(actual_line_sha);
    char *expected_frame_sha = manifest_value(fixture_manifest, fixture->label,
                                              "frame_sha256");
    char *actual_frame_sha = sha256_hex(fixture->file_bytes,
                                        fixture->file_length);
    assert(!strcmp(expected_frame_sha, actual_frame_sha));
    g_free(expected_frame_sha);
    g_free(actual_frame_sha);
    assert(fixture->data[0] == 0 && fixture->data[1] == 0 &&
           fixture->data[2] == 640 && fixture->data[3] == 240 &&
           fixture->data[4] == 1);
    double *background = fixture->data + 6;
    assert(background[0] == 0 && background[1] == 0 &&
           background[2] == 640 && background[3] == 240);
    assert(background[4] == 24 && background[5] == 28 &&
           background[6] == 36 && background[7] == 255);
    double *field = fixture->data + 5 + fixture_stride + 1;
    assert(field[0] == 32 && field[1] == 28 && field[2] == 180 &&
           field[3] == 44 && field[4] == 255 && field[5] == 255 &&
           field[6] == 255 && field[7] == 255);
    double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
    double *text = text_record + 1;
    assert(text[15] == 36 && text[16] == 32 && text[17] == 172 &&
           text[18] == 36);
    assert(text_record[20] == 0 && text_record[21] > 0 &&
           text_record[22] == 18);
    int rejected = i == 3 || i == 4;
    assert(fixture->rejected == rejected);
    if (fixture_abi == GPUI_ORIGIN_FRAME_ABI)
      assert(fixture->text_kind == 2);
    else
      assert(fixture->text_kind == 1);
    if (i == 5 || i == 9 || i == 10) {
      double *caret = fixture->data + 5 + fixture->caret_record * fixture_stride + 1;
      assert(text[12] < 36 && fabs(caret[0] - 207.0) < 1e-8 &&
             fabs(caret[2] - 1.0) < 1e-8);
    }
    if (i == 7 || i == 8)
      assert(fixture->anchor == 0 && fixture->head == 0);
  }

  static const uint8_t short_text[] = "Hi \xe6\x97\xa5\xe6\x9c\xac";
  static const uint8_t edited_text[] = "Edited \xe6\x97\xa5\xe6\x9c\xac";
  static const uint8_t long_text[] = "Wide \xe6\x97\xa5\xe6\x9c\xac ";
  static const uint8_t j_text[] = "jJ";
  static const uint8_t accent_text[] = "\xc3\x81" "A" "\xcc\x81";
  for (int i = 0; i < fixture_count; ++i) {
    struct field_fixture *fixture = &fixtures[i];
    double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
    size_t offset = (size_t)text_record[20], bytes = (size_t)text_record[21];
    const uint8_t *expected = NULL;
    size_t expected_length = 0;
    if (i <= 1) {
      expected = short_text;
      expected_length = sizeof(short_text) - 1;
    } else if (i <= 4) {
      expected = edited_text;
      expected_length = sizeof(edited_text) - 1;
    } else if (i <= 6 || i == 9) {
      expected = long_text;
      expected_length = sizeof(long_text) - 1;
    } else if (i == 7) {
      expected = j_text;
      expected_length = sizeof(j_text) - 1;
    } else if (i == 8) {
      expected = accent_text;
      expected_length = sizeof(accent_text) - 1;
    } else {
      expected = (const uint8_t *)"Wide ";
      expected_length = 5;
    }
    if (i <= 4 || i == 7 || i == 8) {
      assert(bytes == expected_length);
      assert(!memcmp(fixture->text + offset, expected, expected_length));
    } else if (i == 9) {
      assert(bytes == expected_length * 8 + sizeof(j_text) - 1);
      for (int repeat = 0; repeat < 8; ++repeat)
        assert(!memcmp(fixture->text + offset + (size_t)repeat * expected_length,
                       expected, expected_length));
      assert(!memcmp(fixture->text + offset + expected_length * 8,
                     j_text, sizeof(j_text) - 1));
    } else if (i == 10) {
      assert(bytes == expected_length * 20 + sizeof(accent_text) - 1);
      for (int repeat = 0; repeat < 20; ++repeat)
        assert(!memcmp(fixture->text + offset + (size_t)repeat * expected_length,
                       expected, expected_length));
      assert(!memcmp(fixture->text + offset + expected_length * 20,
                     accent_text, sizeof(accent_text) - 1));
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
  uint32_t count = (fixture->double_count - 5) / fixture_stride;
  assert(index >= 0 && (uint32_t)index < count);
  return fixture->data + 5 + index * fixture_stride;
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

static double expected_mask_coverage(
    const struct gpui_linux_text_mask_v2 *reference, const double *record,
    const double *q, double sx, double sy) {
  const struct gpui_linux_text_mask *mask = &reference->mask;
  if (sx < q[15] || sy < q[16] || sx >= q[15] + q[17] ||
      sy >= q[16] + q[18])
    return 0.0;
  double determinant = q[8] * q[11] - q[9] * q[10];
  assert(fabs(determinant) > 1e-9);
  double dx = sx - q[12], dy = sy - q[13];
  double px = (q[11] * dx - q[10] * dy) / determinant;
  double py = (-q[9] * dx + q[8] * dy) / determinant;
  double offset_x = record[0] == 1 ? q[0] : 0.0;
  double offset_y = record[0] == 1 ? q[1] : 0.0;
  if (px < q[0] || py < q[1] || px >= q[0] + q[2] || py >= q[1] + q[3] ||
      px < offset_x + mask->left || py < offset_y + mask->top ||
      px >= offset_x + mask->right || py >= offset_y + mask->bottom)
    return 0.0;
  double visible_width = mask->right - mask->left;
  double visible_height = mask->bottom - mask->top;
  double u = reference->u0 +
      (px - offset_x - mask->left) / visible_width * (reference->u1 - reference->u0);
  double v = reference->v0 +
      (py - offset_y - mask->top) / visible_height * (reference->v1 - reference->v0);
  return mask_linear_sample(mask, u, v);
}

static int caret_geometry(const struct field_fixture *fixture, int utf16_offset,
                          double rect[4]) {
  static const uint8_t sans[] = "sans";
  double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
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

static void assert_recorded_run_geometry(const struct field_fixture *fixture,
                                         const double *measurement) {
  if (fixture->text_kind != 2)
    return;
  const double *record = fixture->data + 5 + fixture->text_record * fixture_stride;
  const double *q = record + 1;
  double min_x = fmin(0.0, fmin(measurement[0], measurement[4]));
  double min_y = fmin(0.0, fmin(measurement[1], measurement[5]));
  double max_x = fmax(measurement[0] + measurement[2],
                      measurement[4] + measurement[6]);
  double max_y = fmax(measurement[1] + measurement[3],
                      measurement[5] + measurement[7]);
  double previous_x = -INFINITY;
  for (int i = 0; i < (int)measurement[11]; ++i) {
    const double *caret = measurement + GPUI_LINUX_TEXT_HEADER_DOUBLES +
        i * GPUI_LINUX_TEXT_CARET_DOUBLES;
    if (caret[1] != 1.0)
      continue;
    const double *strong = caret + 2, *weak = caret + 6;
    assert(strong[0] >= measurement[0] &&
           strong[0] + strong[2] <= measurement[0] + measurement[2] &&
           strong[1] >= measurement[1] &&
           strong[1] + strong[3] <= measurement[1] + measurement[3] &&
           strong[3] > 0.0 && strong[0] >= previous_x);
    for (int c = 0; c < 4; ++c) assert(strong[c] == weak[c]);
    previous_x = strong[0];
  }
  double rounded_min_x = floor(min_x), rounded_min_y = floor(min_y);
  double rounded_max_x = ceil(max_x), rounded_max_y = ceil(max_y);
  double expected_width = fmax(1.0, rounded_max_x - rounded_min_x);
  double expected_height = fmax(1.0, rounded_max_y - rounded_min_y);
  assert(fabs(record[23] + rounded_min_x) < 1e-8 &&
         fabs(record[24] + rounded_min_y) < 1e-8);
  assert(fabs(q[0]) < 1e-8 && fabs(q[1]) < 1e-8 &&
         fabs(q[2] - expected_width) < 1e-8 &&
         fabs(q[3] - expected_height) < 1e-8);
}

static struct gpui_linux_text_mask_v2 make_reference_mask(
    struct field_fixture *fixture) {
  static const uint8_t sans[] = "sans";
  struct gpui_linux_text_mask_v2 reference = {0};
  double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
  const uint8_t *text = fixture->text + (size_t)text_record[20];
  int32_t text_length = (int32_t)text_record[21];
  int capacity = GPUI_LINUX_TEXT_HEADER_DOUBLES +
      (utf8_scalar_count(text, (size_t)text_length) + 1) *
          GPUI_LINUX_TEXT_CARET_DOUBLES;
  double *measurement = calloc((size_t)capacity, sizeof(double));
  assert(measurement);
  assert(gpui_linux_text_measure_v1(GPUI_LINUX_TEXT_ABI, text, text_length,
                                    sans, 4, text_record[22], measurement,
                                    capacity) == GPUI_LINUX_TEXT_OK);
  double origin_x = fixture->text_kind == 2 ? text_record[23] : 0.0;
  double origin_y = fixture->text_kind == 2 ? text_record[24] : 0.0;
  double ink_x = measurement[4], ink_y = measurement[5];
  double ink_width = measurement[6], ink_height = measurement[7];
  free(measurement);
  assert(ink_width > 0 && ink_height > 0);
  assert(gpui_linux_text_raster_v2(
             GPUI_LINUX_TEXT_RASTER_ABI, text, text_length, sans, 4,
             text_record[22], origin_x, origin_y,
             origin_x + ink_x - 1.0, origin_y + ink_y - 1.0,
             ink_width + 2.0, ink_height + 2.0,
             4 * 1024 * 1024, &reference) == GPUI_LINUX_TEXT_OK);
  assert(reference.mask.pixels && reference.mask.width > 0 &&
         reference.mask.height > 0);
  return reference;
}

static void assert_text_coverage(struct field_fixture *fixture,
                                 const struct gpui_linux_text_mask_v2 *reference) {
  double *record = fixture->data + 5 + fixture->text_record * fixture_stride;
  double *q = record + 1;
  int height = active->height * active->scale;
  int found = 0;
  int compared = 0;
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
      if (fixture->label && !strcmp(fixture->label, "selected")) {
        double *selection = item_record(fixture, 6) + 1;
        if (sx >= selection[0] && sx < selection[0] + selection[2] &&
            sy >= selection[1] && sy < selection[1] + selection[3])
          continue;
      }
      double coverage = expected_mask_coverage(reference, record, q, sx, sy);
      if (coverage < 0.82)
        continue;
      unsigned char pixel[4];
      glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(glGetError() == GL_NO_ERROR);
      assert(pixel[0] < 105 && pixel[1] < 110 && pixel[2] < 120);
      found = 1;
      break;
    }
  }
  assert(found);
  /* Compare sampled device pixels against a full-ink reference raster made
   * with an uncut local clip. The production raster still uses the recorded
   * item clip; this checks coverage without rerasterizing that clipped rect. */
  for (int y = (int)(32 * active->scale); y < (int)(68 * active->scale); y += 2) {
    for (int x = (int)(36 * active->scale); x < (int)(208 * active->scale); x += 2) {
      double sx = (x + 0.5) / active->scale;
      double sy = (y + 0.5) / active->scale;
      if (fixture->caret_record >= 0) {
        double *caret = item_record(fixture, fixture->caret_record) + 1;
        if (sx >= caret[0] && sx < caret[0] + caret[2] &&
            sy >= caret[1] && sy < caret[1] + caret[3])
          continue;
      }
      if (!strcmp(fixture->label, "selected")) {
        double *selection = item_record(fixture, 6) + 1;
        if (sx >= selection[0] && sx < selection[0] + selection[2] &&
            sy >= selection[1] && sy < selection[1] + selection[3])
          continue;
      }
      double coverage = expected_mask_coverage(reference, record, q, sx, sy);
      if (coverage < 0.08)
        continue;
      unsigned char pixel[4];
      glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(glGetError() == GL_NO_ERROR);
      int expected_r = (int)lround(255.0 * (1.0 - coverage) + 20.0 * coverage);
      int expected_g = (int)lround(255.0 * (1.0 - coverage) + 24.0 * coverage);
      int expected_b = (int)lround(255.0 * (1.0 - coverage) + 30.0 * coverage);
      assert(abs((int)pixel[0] - expected_r) <= 10 &&
             abs((int)pixel[1] - expected_g) <= 10 &&
             abs((int)pixel[2] - expected_b) <= 10);
      ++compared;
    }
  }
  assert(compared > 0);
  /* All four logical padding regions stay white. This catches text escaping
   * the viewport-space content clip, including in the horizontally scrolled
   * fixture, without treating a captured frame as its own oracle. */
  expect_rgb_at(34.5, 45.5, 255, 255, 255, 2);
  expect_rgb_at(209.5, 45.5, 255, 255, 255, 2);
  expect_rgb_at(100.5, 31.5, 255, 255, 255, 2);
  expect_rgb_at(100.5, 69.5, 255, 255, 255, 2);
}

static void assert_bearing_overhang_pixels(
    const struct field_fixture *fixture,
    const struct gpui_linux_text_mask_v2 *reference) {
  assert(!strcmp(fixture->label, "j_start") ||
         !strcmp(fixture->label, "accent_start"));
  const double *record = fixture->data + 5 + fixture->text_record * fixture_stride;
  const double *q = record + 1;
  double origin_x = record[23], origin_y = record[24];
  int check_left = !strcmp(fixture->label, "j_start");
  assert(check_left ? origin_x > 0.0 : origin_y > 0.0);
  int height = active->height * active->scale;
  int found = 0;
  for (int y = (int)(32 * active->scale); y < (int)(68 * active->scale) && !found; ++y) {
    for (int x = (int)(36 * active->scale); x < (int)(208 * active->scale); ++x) {
      double sx = (x + 0.5) / active->scale;
      double sy = (y + 0.5) / active->scale;
      double determinant = q[8] * q[11] - q[9] * q[10];
      double dx = sx - q[12], dy = sy - q[13];
      double px = (q[11] * dx - q[10] * dy) / determinant;
      double py = (-q[9] * dx + q[8] * dy) / determinant;
      if (check_left ? px >= origin_x : py >= origin_y)
        continue;
      double coverage = expected_mask_coverage(reference, record, q, sx, sy);
      if (coverage < 0.45)
        continue;
      unsigned char pixel[4];
      glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
      assert(glGetError() == GL_NO_ERROR);
      int expected_r = (int)lround(255.0 * (1.0 - coverage) + 20.0 * coverage);
      int expected_g = (int)lround(255.0 * (1.0 - coverage) + 24.0 * coverage);
      int expected_b = (int)lround(255.0 * (1.0 - coverage) + 30.0 * coverage);
      assert(abs((int)pixel[0] - expected_r) <= 10 &&
             abs((int)pixel[1] - expected_g) <= 10 &&
             abs((int)pixel[2] - expected_b) <= 10);
      found = 1;
      break;
    }
  }
  assert(found);
}

static void assert_selection_coverage(
    struct field_fixture *fixture,
    const struct gpui_linux_text_mask_v2 *reference) {
  assert(!strcmp(fixture->label, "selected"));
  int selection_record = 6;
  double *selection_q = item_record(fixture, selection_record) + 1;
  double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
  double *text_q = text_record + 1;
  double anchor[4], head[4];
  assert(caret_geometry(fixture, fixture->anchor, anchor));
  assert(caret_geometry(fixture, fixture->head, head));
  double run_x = fixture->text_kind == 2 ? text_record[23] : 0.0;
  double run_y = fixture->text_kind == 2 ? text_record[24] : 0.0;
  double left = text_q[12] + run_x + fmin(anchor[0], head[0]);
  double right = text_q[12] + run_x + fmax(anchor[0], head[0]);
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
  double top = text_q[13] + run_y + measurement[1];
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
      if (expected_mask_coverage(reference, text_record, text_q, sx, sy) > 0.04)
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

  struct gpui_linux_text_mask_v2 reference = make_reference_mask(fixture);
  assert_text_coverage(fixture, &reference);
  if (!strcmp(fixture->label, "j_start") ||
      !strcmp(fixture->label, "accent_start"))
    assert_bearing_overhang_pixels(fixture, &reference);
  if (!strcmp(fixture->label, "selected"))
    assert_selection_coverage(fixture, &reference);
  double *text_record = fixture->data + 5 + fixture->text_record * fixture_stride;
  int text_capacity = GPUI_LINUX_TEXT_HEADER_DOUBLES +
      (utf8_scalar_count(fixture->text + (size_t)text_record[20],
                         (size_t)text_record[21]) + 1) *
          GPUI_LINUX_TEXT_CARET_DOUBLES;
  double *text_measurement = calloc((size_t)text_capacity, sizeof(double));
  assert(text_measurement);
  assert(gpui_linux_text_measure_v1(
             GPUI_LINUX_TEXT_ABI, fixture->text + (size_t)text_record[20],
             (int32_t)text_record[21], (const uint8_t *)"sans", 4,
             text_record[22], text_measurement, text_capacity) ==
         GPUI_LINUX_TEXT_OK);
  assert_recorded_run_geometry(fixture, text_measurement);
  free(text_measurement);

  if (focused) {
    double caret[4];
    assert(caret_geometry(fixture, fixture->head, caret));
    double *text_q = text_record + 1;
    double run_x = fixture->text_kind == 2 ? text_record[23] : 0.0;
    double run_y = fixture->text_kind == 2 ? text_record[24] : 0.0;
    double expected_x = text_q[12] + run_x + caret[0];
    double expected_y = text_q[13] + run_y + caret[1];
    double *caret_q = item_record(fixture, fixture->caret_record) + 1;
    assert(fabs(caret_q[0] - expected_x) < 0.02 &&
           fabs(caret_q[1] - expected_y) < 0.02 &&
           fabs(caret_q[2] - 1.0) < 1e-9 &&
           fabs(caret_q[3] - caret[3]) < 0.02);
    if (!strcmp(fixture->label, "scroll_end") ||
        !strcmp(fixture->label, "j_scroll") ||
        !strcmp(fixture->label, "accent_scroll"))
      assert(fabs(expected_x - 207.0) < 0.02);
    get_logical_pixel(expected_x + 0.5, expected_y + caret[3] / 2,
                      pixel);
    assert(pixel[0] < 105 && pixel[1] < 110 && pixel[2] < 120);
  } else {
    assert(fixture->caret_record == -1);
    /* The long fixture ends in a space, so this exact right-edge sample is
     * clear in the independent A8 oracle. Blur must remove its former caret. */
    double *text_q = text_record + 1;
    double caret[4];
    assert(caret_geometry(fixture, fixture->head, caret));
    double run_x = fixture->text_kind == 2 ? text_record[23] : 0.0;
    double run_y = fixture->text_kind == 2 ? text_record[24] : 0.0;
    double x = text_q[12] + run_x + caret[0];
    double y = text_q[13] + run_y + caret[1] + caret[3] / 2;
    assert(fabs(x - 207.0) < 0.02);
    assert(expected_mask_coverage(&reference, text_record, text_q,
                                  x + 0.5, y) < 0.05);
    expect_rgb_at(x + 0.5, y, 255, 255, 255, 2);
  }
  gpui_linux_text_mask_release_v2(&reference);
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
  if (diagnostic_mode) {
    assert(swapping_fixture == NULL);
    assert(diagnostic_record);
    static const uint8_t sans[] = "sans";
    static const uint8_t text[] = "jJ";
    double measurement[GPUI_LINUX_TEXT_HEADER_DOUBLES +
                       3 * GPUI_LINUX_TEXT_CARET_DOUBLES] = {0};
    assert(gpui_linux_text_measure_v1(GPUI_LINUX_TEXT_ABI, text, 2, sans, 4,
                                      18.0, measurement,
                                      (int)(sizeof(measurement) / sizeof(double))) ==
           GPUI_LINUX_TEXT_OK);
    double *record = diagnostic_record;
    double *q = record + 1;
    double ox = record[23], oy = record[24];
    struct gpui_linux_text_mask_v2 full = {0};
    assert(gpui_linux_text_raster_v2(
               GPUI_LINUX_TEXT_RASTER_ABI, text, 2, sans, 4, 18.0,
               ox, oy, ox + measurement[4] - 1.0,
               oy + measurement[5] - 1.0,
               measurement[6] + 2.0, measurement[7] + 2.0,
               4 * 1024 * 1024, &full) == GPUI_LINUX_TEXT_OK);
    int height = active->height * active->scale;
    int found = 0;
    for (int y = 0; y < active->height * active->scale && !found; ++y) {
      for (int x = 0; x < active->width * active->scale; ++x) {
        double sx = (x + 0.5) / active->scale;
        double sy = (y + 0.5) / active->scale;
        double coverage = expected_mask_coverage(&full, record, q, sx, sy);
        if (coverage < 0.80)
          continue;
        unsigned char pixel[4];
        glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        assert(glGetError() == GL_NO_ERROR);
        int expected_r = (int)lround(255.0 * (1.0 - coverage) + 20.0 * coverage);
        int expected_g = (int)lround(255.0 * (1.0 - coverage) + 24.0 * coverage);
        int expected_b = (int)lround(255.0 * (1.0 - coverage) + 30.0 * coverage);
        assert(abs((int)pixel[0] - expected_r) <= 10 &&
               abs((int)pixel[1] - expected_g) <= 10 &&
               abs((int)pixel[2] - expected_b) <= 10);
        found = 1;
        break;
      }
    }
    assert(found);
    /* The viewport scissor covers the full jJ reference, while the nonzero
     * local bounds intentionally stop inside the following J. Prove that an
     * uncut reference glyph sample beyond that local right edge stays white. */
    double broad_record[FIELD_STRIDE_ORIGIN];
    memcpy(broad_record, record, sizeof(broad_record));
    broad_record[1] = -16.0;
    broad_record[2] = -16.0;
    broad_record[3] = 80.0;
    broad_record[4] = 80.0;
    double *broad_q = broad_record + 1;
    int found_local_clip = 0;
    for (int y = 0; y < active->height * active->scale && !found_local_clip; ++y) {
      for (int x = 0; x < active->width * active->scale; ++x) {
        double sx = (x + 0.5) / active->scale;
        double sy = (y + 0.5) / active->scale;
        double full_coverage = expected_mask_coverage(
            &full, broad_record, broad_q, sx, sy);
        if (full_coverage < 0.45)
          continue;
        double determinant = q[8] * q[11] - q[9] * q[10];
        double dx = sx - q[12], dy = sy - q[13];
        double px = (q[11] * dx - q[10] * dy) / determinant;
        double py = (-q[9] * dx + q[8] * dy) / determinant;
        int outside_clipped_right = px >= q[0] + q[2] &&
                                    py >= q[1] && py < q[1] + q[3];
        if (!outside_clipped_right)
          continue;
        unsigned char pixel[4];
        glReadPixels(x, height - 1 - y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
        assert(glGetError() == GL_NO_ERROR);
        assert(abs((int)pixel[0] - 255) <= 2 &&
               abs((int)pixel[1] - 255) <= 2 &&
               abs((int)pixel[2] - 255) <= 2 && pixel[3] >= 250);
        found_local_clip = 1;
        break;
      }
    }
    assert(found_local_clip);
    expect_rgb_at(10.5, 10.5, 255, 255, 255, 2);
    expect_rgb_at(276.5, 102.5, 255, 255, 255, 2);
    gpui_linux_text_mask_release_v2(&full);
  } else {
    verify_field_pixels(swapping_fixture);
  }
  if (capture_path && swapping_fixture) {
    const char *label = swapping_fixture->label;
    if (!strcmp(label, "scroll_end")) {
      capture_field_ppm(capture_path);
    } else if (!strcmp(label, "j_start") || !strcmp(label, "accent_start") ||
               !strcmp(label, "j_scroll") || !strcmp(label, "accent_scroll")) {
      char bearing_path[4096];
      size_t prefix = strlen(capture_path);
      if (prefix >= 4 && !strcmp(capture_path + prefix - 4, ".ppm")) prefix -= 4;
      assert(prefix < sizeof(bearing_path));
      int length = snprintf(bearing_path, sizeof(bearing_path), "%.*s-%s.ppm",
                             (int)prefix, capture_path, label);
      assert(length > 0 && (size_t)length < sizeof(bearing_path));
      capture_field_ppm(bearing_path);
    }
  }
  return eglSwapBuffers(display, surface);
}

static void await_field_frame(int host) {
  for (int i = 0; i < 50 && active->frame; ++i)
    assert(gpui_dispatch(host, 100) == GPUI_OK);
  assert(!active->frame);
}

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
  int status = fixture_abi == GPUI_ORIGIN_FRAME_ABI
      ? gpui_present_v3(GPUI_ORIGIN_FRAME_ABI, host, window, normalized,
                        (int32_t)fixture->double_count, fixture->text,
                        (int32_t)fixture->text_length)
      : gpui_present_v2(GPUI_MIXED_FRAME_ABI, host, window, normalized,
                        (int32_t)fixture->double_count, fixture->text,
                        (int32_t)fixture->text_length);
  assert(status == GPUI_OK);
  assert(field_swap_count == swaps_before + 1);
  ++fixture_swap_count;
  await_field_frame(host);
  swapping_fixture = NULL;
  free(normalized);
}

static void init_origin_frame(double *data, int width, int height, int scale) {
  data[0] = data[1] = 0.0;
  data[2] = width;
  data[3] = height;
  data[4] = scale;
}

static void set_origin_quad(double *record, double width, double height,
                            int red, int green, int blue, int alpha) {
  memset(record, 0, FIELD_STRIDE_ORIGIN * sizeof(double));
  record[0] = 0.0;
  record[1] = record[2] = 0.0;
  record[3] = width;
  record[4] = height;
  record[5] = red;
  record[6] = green;
  record[7] = blue;
  record[8] = alpha;
  record[9] = record[12] = 1.0;
  record[15] = 1.0;
  record[16] = record[17] = 0.0;
  record[18] = width;
  record[19] = height;
}

static void set_origin_text(double *record, double x, double y,
                            double width, double height,
                            double scissor_x, double scissor_y,
                            double scissor_width, double scissor_height,
                            double offset, double length, double font_size,
                            double origin_x, double origin_y) {
  memset(record, 0, FIELD_STRIDE_ORIGIN * sizeof(double));
  record[0] = 2.0;
  record[1] = x;
  record[2] = y;
  record[3] = width;
  record[4] = height;
  record[5] = 20;
  record[6] = 24;
  record[7] = 30;
  record[8] = 255;
  record[9] = record[12] = 1.0;
  record[10] = 0.2;
  record[11] = -0.25;
  record[13] = 280.0;
  record[14] = 100.0;
  record[15] = 1.0;
  record[16] = scissor_x;
  record[17] = scissor_y;
  record[18] = scissor_width;
  record[19] = scissor_height;
  record[20] = offset;
  record[21] = length;
  record[22] = font_size;
  record[23] = origin_x;
  record[24] = origin_y;
}

static void assert_origin_preflight_preserves(
    int host, int window, double *data, int32_t double_count,
    const uint8_t *text, int32_t text_length, int expected_status) {
  unsigned char before[4], after[4];
  get_logical_pixel(10.5, 10.5, before);
  int swaps_before = field_swap_count;
  assert(gpui_present_v3(GPUI_ORIGIN_FRAME_ABI, host, window, data,
                         double_count, text, text_length) == expected_status);
  assert(field_swap_count == swaps_before);
  get_logical_pixel(10.5, 10.5, after);
  assert(memcmp(before, after, sizeof(before)) == 0);
}

static void test_origin_gpu_diagnostic_and_late_preservation(int host,
                                                              int window) {
  int width = active->width, height = active->height, scale = active->scale;
  static const uint8_t diagnostic_text[] = "jJ";
  double diagnostic[5 + 2 * FIELD_STRIDE_ORIGIN] = {0};
  init_origin_frame(diagnostic, width, height, scale);
  set_origin_quad(diagnostic + 5, width, height, 255, 255, 255, 255);
  double *diagnostic_text_record = diagnostic + 5 + FIELD_STRIDE_ORIGIN;
  set_origin_text(diagnostic_text_record, 2.25, 1.25, 8.0, 23.75,
                  279.0, 98.0, 30.0, 30.0, 0.0, 2.0, 18.0,
                  1.25, 0.5);
  diagnostic_text_record[9] = 1.0;
  diagnostic_text_record[10] = 0.2;
  diagnostic_text_record[11] = -0.25;
  diagnostic_text_record[12] = 1.0;
  diagnostic_text_record[13] = 280.0;
  diagnostic_text_record[14] = 100.0;
  diagnostic_mode = 1;
  diagnostic_record = diagnostic_text_record;
  swapping_fixture = NULL;
  int swaps_before = field_swap_count;
  assert(gpui_present_v3(GPUI_ORIGIN_FRAME_ABI, host, window, diagnostic,
                         (int32_t)(sizeof(diagnostic) / sizeof(double)),
                         diagnostic_text, 2) == GPUI_OK);
  assert(field_swap_count == swaps_before + 1);
  await_field_frame(host);
  diagnostic_mode = 0;
  diagnostic_record = NULL;

  /* A valid first quad and run precede each late failure. Failed frames must
   * not swap the red/other staged scene over the currently displayed frame. */
  static const uint8_t one[] = "H";
  double invalid[5 + 3 * FIELD_STRIDE_ORIGIN] = {0};
  init_origin_frame(invalid, width, height, scale);
  set_origin_quad(invalid + 5, width, height, 255, 0, 0, 255);
  set_origin_text(invalid + 5 + FIELD_STRIDE_ORIGIN, 8, 8, 40, 24,
                  0, 0, width, height, 0, 1, 18, 0, 0);
  set_origin_text(invalid + 5 + 2 * FIELD_STRIDE_ORIGIN, 40, 8, 40, 24,
                  0, 0, width, height, 0, 1, 18, 1.0e20, 0);
  /* Finite common fields pass; translated clip precision fails only after
   * the preceding ordinary run has staged its mask. */
  assert_origin_preflight_preserves(host, window, invalid,
      (int32_t)(sizeof(invalid) / sizeof(double)), one, 1, GPUI_INVALID);
  double legacy_origin[5 + FIELD_STRIDE_ORIGIN] = {0};
  init_origin_frame(legacy_origin, width, height, scale);
  set_origin_quad(legacy_origin + 5, width, height, 255, 0, 0, 255);
  legacy_origin[5 + 23] = 0.25;
  assert_origin_preflight_preserves(host, window, legacy_origin,
      (int32_t)(sizeof(legacy_origin) / sizeof(double)), NULL, 0, GPUI_INVALID);

  static const uint8_t color_emoji[] = {
      0xf0, 0x9f, 0x91, 0xa9, 0xe2, 0x80, 0x8d,
      0xf0, 0x9f, 0x92, 0xbb};
  uint8_t color_blob[1 + sizeof(color_emoji)];
  color_blob[0] = 'H';
  memcpy(color_blob + 1, color_emoji, sizeof(color_emoji));
  double color[5 + 3 * FIELD_STRIDE_ORIGIN] = {0};
  init_origin_frame(color, width, height, scale);
  set_origin_quad(color + 5, width, height, 255, 0, 0, 255);
  set_origin_text(color + 5 + FIELD_STRIDE_ORIGIN, 8, 8, 40, 24,
                  0, 0, width, height, 0, 1, 18, 0, 0);
  set_origin_text(color + 5 + 2 * FIELD_STRIDE_ORIGIN, 40, 8, 40, 24,
                  0, 0, width, height, 1, sizeof(color_emoji), 18, 0, 0);
  assert_origin_preflight_preserves(host, window, color,
      (int32_t)(sizeof(color) / sizeof(double)), color_blob,
      (int32_t)sizeof(color_blob), GPUI_UNSUPPORTED);

  uint8_t large_text[2048], large_blob[1 + sizeof(large_text)];
  memset(large_text, 'M', sizeof(large_text));
  large_blob[0] = 'H';
  memcpy(large_blob + 1, large_text, sizeof(large_text));
  double resource[5 + 3 * FIELD_STRIDE_ORIGIN] = {0};
  init_origin_frame(resource, width, height, scale);
  set_origin_quad(resource + 5, width, height, 255, 0, 0, 255);
  set_origin_text(resource + 5 + FIELD_STRIDE_ORIGIN, 8, 8, 40, 24,
                  0, 0, width, height, 0, 1, 18, 0, 0);
  set_origin_text(resource + 5 + 2 * FIELD_STRIDE_ORIGIN, 40, 8, 50000, 24,
                  0, 0, width, height, 1, sizeof(large_text), 18, 0, 0);
  assert_origin_preflight_preserves(host, window, resource,
      (int32_t)(sizeof(resource) / sizeof(double)), large_blob,
      (int32_t)sizeof(large_blob), GPUI_RESOURCE);
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

  for (int i = 0; i < fixture_count; ++i) {
    if (i == 3 || i == 4) {
      assert_rejected_fixture_identity(&fixtures[i]);
      continue;
    }
    present_fixture(host, window, &fixtures[i]);
  }
  if (fixture_abi == GPUI_ORIGIN_FRAME_ABI)
    test_origin_gpu_diagnostic_and_late_preservation(host, window);

  assert(gpui_close(host, window) == GPUI_OK);
  assert(gpui_destroy(host, window) == GPUI_OK);
  assert(gpui_stop(host) == GPUI_OK);
  assert(fixture_swap_count == fixture_count - 2);
  assert(field_swap_count == fixture_count - 2 +
         (fixture_abi == GPUI_ORIGIN_FRAME_ABI ? 1 : 0));
  for (int i = 0; i < fixture_count; ++i) {
    free(fixtures[i].file_bytes);
    free(fixtures[i].original_line);
    free(fixtures[i].data);
  }
  free(fixture_manifest);
  puts("Linux TextField injected accepted-frame GPU pixel oracle passed.");
  return 0;
}
