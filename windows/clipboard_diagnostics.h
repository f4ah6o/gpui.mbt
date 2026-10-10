#ifndef GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_H
#define GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct gpui_clipboard_diag_record {
  const char *role;
  const char *event;
  const char *stage;
  const char *api;
  const char *result;
  uint64_t tick_ms;
  int error_valid;
  uint32_t error;
  uint64_t caller_hwnd;
  uint32_t caller_pid;
  uint32_t caller_tid;
  uint64_t open_hwnd;
  int open_snapshot_valid;
  int open_identity_valid;
  uint32_t open_pid;
  uint32_t open_tid;
  uint32_t child_pid;
  uint32_t child_tid;
  int exit_code_valid;
  uint32_t exit_code;
} gpui_clipboard_diag_record;

typedef uint32_t (*gpui_clipboard_diag_get_error_fn)(void *context);
typedef void (*gpui_clipboard_diag_capture_metadata_fn)(void *context);

/* Keep the failed OpenClipboard error before metadata callbacks can call APIs
 * that overwrite the thread's last-error value. This helper is also exercised
 * by a fake callback regression; it never calls a clipboard API itself. */
static uint32_t gpui_clipboard_diag_after_open(
    int opened, gpui_clipboard_diag_get_error_fn get_error,
    void *error_context,
    gpui_clipboard_diag_capture_metadata_fn capture_metadata,
    void *metadata_context) {
  uint32_t saved_error = 0;
  if (!opened) {
    if (get_error)
      saved_error = get_error(error_context);
    if (capture_metadata)
      capture_metadata(metadata_context);
  }
  return saved_error;
}

static int gpui_clipboard_diag_label_valid(const char *label) {
  if (!label)
    return 1;
  for (const unsigned char *cursor = (const unsigned char *)label; *cursor;
       ++cursor) {
    unsigned char ch = *cursor;
    if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
          (ch >= '0' && ch <= '9') || ch == '_'))
      return 0;
  }
  return 1;
}

static int gpui_clipboard_diag_format(char *output, size_t capacity,
                                      const gpui_clipboard_diag_record *record) {
  if (!output || !record || capacity == 0 ||
      !gpui_clipboard_diag_label_valid(record->role) ||
      !gpui_clipboard_diag_label_valid(record->event) ||
      !gpui_clipboard_diag_label_valid(record->stage) ||
      !gpui_clipboard_diag_label_valid(record->api) ||
      !gpui_clipboard_diag_label_valid(record->result))
    return -1;
  int count = snprintf(
      output, capacity,
      "{\"schema\":1,\"role\":\"%s\",\"event\":\"%s\","
      "\"tick_ms\":%llu,\"stage\":\"%s\",\"api\":\"%s\","
      "\"result\":\"%s\",\"error_valid\":%s,\"error\":%u,"
      "\"caller_hwnd\":\"0x%llx\",\"caller_pid\":%u,"
      "\"caller_tid\":%u,\"open_hwnd\":\"0x%llx\","
      "\"open_snapshot_valid\":%s,\"open_identity_valid\":%s,"
      "\"open_pid\":%u,\"open_tid\":%u,\"child_pid\":%u,"
      "\"child_tid\":%u,\"exit_code_valid\":%s,\"exit_code\":%u}",
      record->role ? record->role : "", record->event ? record->event : "",
      (unsigned long long)record->tick_ms,
      record->stage ? record->stage : "", record->api ? record->api : "",
      record->result ? record->result : "",
      record->error_valid ? "true" : "false", record->error,
      (unsigned long long)record->caller_hwnd, record->caller_pid,
      record->caller_tid, (unsigned long long)record->open_hwnd,
      record->open_snapshot_valid ? "true" : "false",
      record->open_identity_valid ? "true" : "false", record->open_pid,
      record->open_tid, record->child_pid,
      record->child_tid, record->exit_code_valid ? "true" : "false",
      record->exit_code);
  if (count < 0 || (size_t)count >= capacity)
    return -1;
  return count;
}

#ifndef GPUI_CLIPBOARD_DIAGNOSTICS_FIXTURE
typedef struct gpui_clipboard_diag_fake_error_state {
  uint32_t last_error;
  uint32_t saved_error;
  uint32_t get_error_calls;
  uint32_t metadata_calls;
} gpui_clipboard_diag_fake_error_state;

static uint32_t gpui_clipboard_diag_fake_get_error(void *context) {
  gpui_clipboard_diag_fake_error_state *state =
      (gpui_clipboard_diag_fake_error_state *)context;
  ++state->get_error_calls;
  state->saved_error = state->last_error;
  return state->saved_error;
}

static void gpui_clipboard_diag_fake_capture_metadata(void *context) {
  gpui_clipboard_diag_fake_error_state *state =
      (gpui_clipboard_diag_fake_error_state *)context;
  ++state->metadata_calls;
  state->last_error = 1234; /* Simulate a metadata API clobbering last error. */
}

static int gpui_clipboard_diag_regression(void) {
  gpui_clipboard_diag_fake_error_state error_state = {5, 0, 0, 0};
  uint32_t captured = gpui_clipboard_diag_after_open(
      0, gpui_clipboard_diag_fake_get_error, &error_state,
      gpui_clipboard_diag_fake_capture_metadata, &error_state);
  if (captured != 5 || error_state.saved_error != 5 ||
      error_state.last_error != 1234 || error_state.get_error_calls != 1 ||
      error_state.metadata_calls != 1)
    return 0;

  gpui_clipboard_diag_fake_error_state disabled_error_state = {8, 0, 0, 0};
  captured = gpui_clipboard_diag_after_open(
      0, gpui_clipboard_diag_fake_get_error, &disabled_error_state, NULL, NULL);
  if (captured != 8 || disabled_error_state.get_error_calls != 1 ||
      disabled_error_state.metadata_calls != 0)
    return 0;
  gpui_clipboard_diag_fake_error_state successful_state = {9, 0, 0, 0};
  captured = gpui_clipboard_diag_after_open(
      1, gpui_clipboard_diag_fake_get_error, &successful_state,
      gpui_clipboard_diag_fake_capture_metadata, &successful_state);
  if (captured != 0 || successful_state.get_error_calls != 0 ||
      successful_state.metadata_calls != 0)
    return 0;

  gpui_clipboard_diag_record record = {0};
  record.role = "host";
  record.event = "clipboard_open";
  record.stage = "read_size";
  record.api = "OpenClipboard";
  record.result = "failure";
  record.tick_ms = 123;
  record.error_valid = 1;
  record.error = error_state.saved_error;
  record.caller_hwnd = 0x1234;
  record.caller_pid = 12;
  record.caller_tid = 34;
  record.open_hwnd = 0xabcd;
  record.open_snapshot_valid = 1;
  record.open_identity_valid = 1;
  record.open_pid = 56;
  record.open_tid = 78;
  char line[768];
  int count = gpui_clipboard_diag_format(line, sizeof(line), &record);
  const char expected[] =
      "{\"schema\":1,\"role\":\"host\",\"event\":\"clipboard_open\","
      "\"tick_ms\":123,\"stage\":\"read_size\","
      "\"api\":\"OpenClipboard\",\"result\":\"failure\","
      "\"error_valid\":true,\"error\":5,\"caller_hwnd\":\"0x1234\","
      "\"caller_pid\":12,\"caller_tid\":34,"
      "\"open_hwnd\":\"0xabcd\",\"open_snapshot_valid\":true,"
      "\"open_identity_valid\":true,\"open_pid\":56,\"open_tid\":78,"
      "\"child_pid\":0,\"child_tid\":0,"
      "\"exit_code_valid\":false,\"exit_code\":0}";
  if (count != (int)(sizeof(expected) - 1) || strcmp(line, expected) != 0 ||
      strstr(line, "READY") || strstr(line, "DONE"))
    return 0;
  record.stage = "read_data";
  count = gpui_clipboard_diag_format(line, sizeof(line), &record);
  if (count < 0 || !strstr(line, "\"stage\":\"read_data\""))
    return 0;
  record.role = "host";
  record.event = "fixture_child_exit";
  record.stage = "lock_stop";
  record.api = "GetExitCodeProcess";
  record.result = "success";
  record.child_pid = 123;
  record.child_tid = 456;
  record.exit_code_valid = 1;
  record.exit_code = 0;
  count = gpui_clipboard_diag_format(line, sizeof(line), &record);
  if (count < 0 || !strstr(line, "\"child_pid\":123") ||
      !strstr(line, "\"child_tid\":456") ||
      !strstr(line, "\"exit_code_valid\":true,\"exit_code\":0"))
    return 0;
  record.event = "bad\"event";
  return gpui_clipboard_diag_format(line, sizeof(line), &record) < 0;
}
#endif

#endif
