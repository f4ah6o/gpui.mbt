/* Experimental, opt-in Win32 IMM32 text-session ingress. Include this after
 * backend.c's host/global/event helpers and before gpui_window_proc. This file
 * owns typed sidecars and IMM state; it never raises TextInput capability. */
#include <imm.h>
#include <limits.h>

/* This include sits before the ordinary event helper definitions so the
 * backend can call the sidecar hooks from emit/discard/dispatch code. */
static void emit_event(gpui_windows_host *host, int32_t kind, double x,
                       double y, int32_t detail, int32_t mods);
static int32_t modifiers_from_message(gpui_windows_host *host, WPARAM wparam);
static int32_t gpui_text_next_epoch(gpui_windows_host *host);

#define GPUI_TEXT_EVENT_STARTED 20
#define GPUI_TEXT_EVENT_MARKED 21
#define GPUI_TEXT_EVENT_INSERTED 22
#define GPUI_TEXT_EVENT_ENDED 23
#define GPUI_TEXT_EVENT_CANCELLED 24
#define GPUI_TEXT_MAX_STRING_BYTES 4096
#define GPUI_TEXT_MAX_ATTRIBUTES 4096
#define GPUI_TEXT_MAX_PENDING_BYTES (1024 * 1024)
#define GPUI_TEXT_MAX_UTF16_UNITS 4096

typedef HIMC(WINAPI *gpui_imm_get_context_fn)(HWND);
typedef BOOL(WINAPI *gpui_imm_release_context_fn)(HWND, HIMC);
typedef HIMC(WINAPI *gpui_imm_associate_context_fn)(HWND, HIMC);
typedef LONG(WINAPI *gpui_imm_get_composition_string_w_fn)(HIMC, DWORD,
                                                           LPVOID, DWORD);
typedef BOOL(WINAPI *gpui_imm_set_composition_window_fn)(HIMC,
                                                          LPCOMPOSITIONFORM);
typedef BOOL(WINAPI *gpui_imm_set_candidate_window_fn)(HIMC,
                                                       LPCANDIDATEFORM);
typedef BOOL(WINAPI *gpui_imm_notify_ime_fn)(HIMC, DWORD, DWORD, DWORD);

typedef struct gpui_imm_api {
  HMODULE module;
  gpui_imm_get_context_fn get_context;
  gpui_imm_release_context_fn release_context;
  gpui_imm_associate_context_fn associate_context;
  gpui_imm_get_composition_string_w_fn get_composition_string_w;
  gpui_imm_set_composition_window_fn set_composition_window;
  gpui_imm_set_candidate_window_fn set_candidate_window;
  gpui_imm_notify_ime_fn notify_ime;
} gpui_imm_api;

typedef struct gpui_text_session_state {
  int32_t epoch_counter;
  int32_t epoch;
  int32_t owner_generation;
  int32_t window_id;
  BOOL armed;
  BOOL awaiting_fresh_start;
  BOOL composing;
  BOOL preedit_seen;
  BOOL commit_waiting_end;
  BOOL suppress_ime_char_until_end;
  BOOL suppress_ime_messages;
  WCHAR pending_high_surrogate;
  HIMC expected_himc;
  WCHAR *document;
  int32_t document_units;
  int32_t anchor_utf16;
  int32_t head_utf16;
  int32_t target_start;
  int32_t target_length;
  double caret_x;
  double caret_y;
  double caret_width;
  double caret_height;
} gpui_text_session_state;

typedef struct gpui_text_record {
  int32_t kind;
  const uint8_t *text;
  int32_t text_bytes;
  const uint8_t *attributes;
  int32_t attribute_bytes;
  int32_t cursor_valid;
  int32_t cursor_utf16;
  int32_t range_valid;
  int32_t range_start;
  int32_t range_length;
} gpui_text_record;

static gpui_imm_api g_gpui_imm;
static gpui_text_session_state g_gpui_text_session;

static int32_t gpui_text_imm_init(void) {
  if (g_gpui_imm.module)
    return GPUI_WINDOWS_OK;
  HMODULE module = LoadLibraryW(L"imm32.dll");
  if (!module)
    return GPUI_WINDOWS_UNSUPPORTED;
  gpui_imm_api api;
  ZeroMemory(&api, sizeof(api));
  api.module = module;
#define GPUI_IMM_LOAD(field, type, name)                                      \
  do {                                                                         \
    api.field = (type)(uintptr_t)GetProcAddress(module, name);                  \
    if (!api.field) {                                                          \
      FreeLibrary(module);                                                     \
      return GPUI_WINDOWS_UNSUPPORTED;                                         \
    }                                                                          \
  } while (0)
  GPUI_IMM_LOAD(get_context, gpui_imm_get_context_fn, "ImmGetContext");
  GPUI_IMM_LOAD(release_context, gpui_imm_release_context_fn,
                "ImmReleaseContext");
  GPUI_IMM_LOAD(associate_context, gpui_imm_associate_context_fn,
                "ImmAssociateContext");
  GPUI_IMM_LOAD(get_composition_string_w,
                gpui_imm_get_composition_string_w_fn,
                "ImmGetCompositionStringW");
  GPUI_IMM_LOAD(set_composition_window,
                gpui_imm_set_composition_window_fn,
                "ImmSetCompositionWindow");
  GPUI_IMM_LOAD(set_candidate_window, gpui_imm_set_candidate_window_fn,
                "ImmSetCandidateWindow");
  GPUI_IMM_LOAD(notify_ime, gpui_imm_notify_ime_fn, "ImmNotifyIME");
#undef GPUI_IMM_LOAD
  g_gpui_imm = api;
  return GPUI_WINDOWS_OK;
}

static BOOL gpui_text_high_surrogate(WCHAR unit) {
  return unit >= 0xd800 && unit <= 0xdbff;
}

static BOOL gpui_text_low_surrogate(WCHAR unit) {
  return unit >= 0xdc00 && unit <= 0xdfff;
}

static BOOL gpui_text_wide_boundary(const WCHAR *text, int32_t length,
                                    int32_t offset) {
  if (offset < 0 || offset > length)
    return FALSE;
  if (offset == 0 || offset == length)
    return TRUE;
  return !(gpui_text_high_surrogate(text[offset - 1]) &&
           gpui_text_low_surrogate(text[offset]));
}

static int32_t gpui_text_validate_wide(const WCHAR *text, int32_t length) {
  if (length < 0 || length > GPUI_TEXT_MAX_UTF16_UNITS ||
      (length && !text))
    return GPUI_WINDOWS_INVALID;
  for (int32_t i = 0; i < length; ++i) {
    if (text[i] == 0)
      return GPUI_WINDOWS_INVALID;
    if (gpui_text_high_surrogate(text[i])) {
      if (i + 1 >= length || !gpui_text_low_surrogate(text[i + 1]))
        return GPUI_WINDOWS_CONVERSION;
      ++i;
    } else if (gpui_text_low_surrogate(text[i])) {
      return GPUI_WINDOWS_CONVERSION;
    }
  }
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_utf8_to_wide(const uint8_t *bytes, int32_t length,
                                     WCHAR **output, int32_t *units) {
  if (!output || !units || length < 0 ||
      length > GPUI_TEXT_MAX_STRING_BYTES || (length && !bytes))
    return GPUI_WINDOWS_INVALID;
  *output = NULL;
  *units = 0;
  if (length && memchr(bytes, 0, (size_t)length))
    return GPUI_WINDOWS_INVALID;
  int32_t count = 0;
  if (length) {
    count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                (LPCCH)bytes, length, NULL, 0);
    if (count <= 0)
      return GPUI_WINDOWS_CONVERSION;
  }
  if (count > GPUI_TEXT_MAX_UTF16_UNITS)
    return GPUI_WINDOWS_RESOURCE;
  WCHAR *copy = (WCHAR *)calloc((size_t)count + 1, sizeof(WCHAR));
  if (!copy)
    return GPUI_WINDOWS_RESOURCE;
  if (count && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                   (LPCCH)bytes, length, copy, count) != count) {
    free(copy);
    return GPUI_WINDOWS_CONVERSION;
  }
  int32_t status = gpui_text_validate_wide(copy, count);
  if (status != GPUI_WINDOWS_OK) {
    free(copy);
    return status;
  }
  *output = copy;
  *units = count;
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_wide_to_utf8(const WCHAR *text, int32_t units,
                                      uint8_t **output, int32_t *bytes) {
  if (!output || !bytes)
    return GPUI_WINDOWS_INVALID;
  *output = NULL;
  *bytes = 0;
  int32_t status = gpui_text_validate_wide(text, units);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (units == 0)
    return GPUI_WINDOWS_OK;
  int count = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, units,
                                  NULL, 0, NULL, NULL);
  if (count <= 0)
    return GPUI_WINDOWS_CONVERSION;
  if (count > GPUI_TEXT_MAX_STRING_BYTES)
    return GPUI_WINDOWS_RESOURCE;
  uint8_t *copy = (uint8_t *)malloc((size_t)count);
  if (!copy)
    return GPUI_WINDOWS_RESOURCE;
  if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, text, units,
                          (LPSTR)copy, count, NULL, NULL) != count) {
    free(copy);
    return GPUI_WINDOWS_CONVERSION;
  }
  *output = copy;
  *bytes = count;
  return GPUI_WINDOWS_OK;
}

static void gpui_text_session_clear_slot(gpui_windows_host *host,
                                         int32_t slot) {
  if (!host || slot < 0 || slot >= GPUI_EVENT_CAPACITY)
    return;
  if (host->editor_payloads[slot]) {
    int32_t bytes = host->editor_payload_bytes[slot];
    if (bytes > 0 && host->editor_payload_total >= bytes)
      host->editor_payload_total -= bytes;
    free(host->editor_payloads[slot]);
  }
  host->editor_events[slot] = FALSE;
  ZeroMemory(host->editor_fields[slot], sizeof(host->editor_fields[slot]));
  host->editor_payloads[slot] = NULL;
  host->editor_payload_bytes[slot] = 0;
}

/* Shared-ring compaction hooks. `events[src]` is moved by backend.c; this
 * moves only its editor sidecar, freeing payloads for removed records. */
static void gpui_text_session_discard_slot(gpui_windows_host *host,
                                           int32_t slot) {
  gpui_text_session_clear_slot(host, slot);
}

static void gpui_text_session_move_slot(gpui_windows_host *host,
                                        int32_t source, int32_t destination) {
  if (!host || source == destination)
    return;
  gpui_text_session_clear_slot(host, destination);
  host->editor_events[destination] = host->editor_events[source];
  memcpy(host->editor_fields[destination], host->editor_fields[source],
         sizeof(host->editor_fields[source]));
  host->editor_payloads[destination] = host->editor_payloads[source];
  host->editor_payload_bytes[destination] =
      host->editor_payload_bytes[source];
  host->editor_events[source] = FALSE;
  ZeroMemory(host->editor_fields[source], sizeof(host->editor_fields[source]));
  host->editor_payloads[source] = NULL;
  host->editor_payload_bytes[source] = 0;
}

static BOOL gpui_text_session_is_editor_slot(gpui_windows_host *host,
                                             int32_t slot) {
  return host && slot >= 0 && slot < GPUI_EVENT_CAPACITY &&
         host->editor_events[slot];
}

static BOOL gpui_text_session_head_is_editor(gpui_windows_host *host) {
  return host && host->event_count > 0 &&
         gpui_text_session_is_editor_slot(host, host->event_read);
}

static int32_t gpui_text_session_fail(gpui_windows_host *host,
                                      int32_t status) {
  if (host && status != GPUI_WINDOWS_OK) {
    if (!host->editor_error)
      InterlockedExchange(&host->editor_error, status);
    g_gpui_text_session.armed = FALSE;
    g_gpui_text_session.awaiting_fresh_start = FALSE;
    g_gpui_text_session.composing = FALSE;
    g_gpui_text_session.pending_high_surrogate = 0;
    g_gpui_text_session.suppress_ime_messages = TRUE;
  }
  return status;
}

static int32_t gpui_text_session_emit_batch(gpui_windows_host *host,
                                            const gpui_text_record *records,
                                            int32_t count) {
  if (!host || !records || count <= 0 || count > 3)
    return GPUI_WINDOWS_INVALID;
  if (host->state != 0)
    return GPUI_WINDOWS_STOPPING;
  if (host->editor_error)
    return host->editor_error;
  if (host->event_count > GPUI_EVENT_CAPACITY - count)
    return gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
  if (host->sequence < 0 ||
      host->sequence > INT64_C(9007199254740991) - count)
    return gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
  if (g_gpui_text_session.owner_generation <= 0 ||
      g_gpui_text_session.epoch <= 0)
    return GPUI_WINDOWS_STALE;

  int32_t total_bytes = 0;
  for (int32_t i = 0; i < count; ++i) {
    const gpui_text_record *record = &records[i];
    if (record->kind < GPUI_TEXT_EVENT_STARTED ||
        record->kind > GPUI_TEXT_EVENT_CANCELLED ||
        record->text_bytes < 0 ||
        record->text_bytes > GPUI_TEXT_MAX_STRING_BYTES ||
        record->attribute_bytes < 0 ||
        record->attribute_bytes > GPUI_TEXT_MAX_ATTRIBUTES ||
        record->text_bytes > INT32_MAX - record->attribute_bytes ||
        (record->text_bytes && !record->text) ||
        (record->attribute_bytes && !record->attributes) ||
        record->cursor_valid < 0 || record->cursor_valid > 1 ||
        record->range_valid < 0 || record->range_valid > 1 ||
        record->range_start < 0 || record->range_length < 0 ||
        (record->kind == GPUI_TEXT_EVENT_MARKED && !record->range_valid) ||
        (record->kind == GPUI_TEXT_EVENT_INSERTED && !record->range_valid) ||
        (record->kind == GPUI_TEXT_EVENT_STARTED && !record->range_valid))
      return GPUI_WINDOWS_INVALID;
    int32_t bytes = record->text_bytes + record->attribute_bytes;
    if (bytes > INT32_MAX - total_bytes)
      return gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
    total_bytes += bytes;
  }
  if (total_bytes > GPUI_TEXT_MAX_PENDING_BYTES - host->editor_payload_total)
    return gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);

  uint8_t *copies[3] = {NULL, NULL, NULL};
  for (int32_t i = 0; i < count; ++i) {
    int32_t bytes = records[i].text_bytes + records[i].attribute_bytes;
    if (!bytes)
      continue;
    copies[i] = (uint8_t *)malloc((size_t)bytes);
    if (!copies[i]) {
      for (int32_t j = 0; j < count; ++j)
        free(copies[j]);
      return gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
    }
    if (records[i].text_bytes)
      memcpy(copies[i], records[i].text, (size_t)records[i].text_bytes);
    if (records[i].attribute_bytes)
      memcpy(copies[i] + records[i].text_bytes, records[i].attributes,
             (size_t)records[i].attribute_bytes);
  }

  for (int32_t i = 0; i < count; ++i) {
    int32_t slot = (host->event_read + host->event_count) %
                   GPUI_EVENT_CAPACITY;
    double *event = host->events[slot];
    event[0] = records[i].kind;
    event[1] = host->window_id;
    event[2] = (double)++host->sequence;
    event[3] = host->scale > 0.0 ? host->scale : 1.0;
    event[4] = host->logical_width;
    event[5] = host->logical_height;
    event[6] = 0.0;
    event[7] = 0.0;
    event[8] = 0.0;
    event[9] = 0.0;
    host->editor_events[slot] = TRUE;
    host->editor_fields[slot][0] = g_gpui_text_session.owner_generation;
    host->editor_fields[slot][1] = g_gpui_text_session.epoch;
    host->editor_fields[slot][2] = records[i].text_bytes;
    host->editor_fields[slot][3] = records[i].cursor_valid;
    host->editor_fields[slot][4] = records[i].cursor_utf16;
    host->editor_fields[slot][5] = records[i].range_valid;
    host->editor_fields[slot][6] = records[i].range_start;
    host->editor_fields[slot][7] = records[i].range_length;
    host->editor_fields[slot][8] = records[i].attribute_bytes;
    host->editor_fields[slot][9] = 0.0;
    host->editor_payloads[slot] = copies[i];
    host->editor_payload_bytes[slot] =
        records[i].text_bytes + records[i].attribute_bytes;
    host->editor_payload_total += host->editor_payload_bytes[slot];
    host->event_count++;
  }
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_session_pop(gpui_windows_host *host,
                                     double *event_data,
                                     uint8_t *payload,
                                     int32_t payload_capacity) {
  if (!host || !event_data || payload_capacity < 0 ||
      (payload_capacity && !payload))
    return -GPUI_WINDOWS_INVALID;
  if (host->editor_error)
    return -host->editor_error;
  if (host->event_count == 0)
    return 0;
  int32_t slot = host->event_read;
  int32_t payload_bytes = host->editor_payload_bytes[slot];
  if (payload_bytes > payload_capacity)
    return -GPUI_WINDOWS_RESOURCE;
  memcpy(event_data, host->events[slot], sizeof(host->events[slot]));
  for (int32_t i = 0; i < 10; ++i)
    event_data[10 + i] = host->editor_fields[slot][i];
  if (payload_bytes)
    memcpy(payload, host->editor_payloads[slot], (size_t)payload_bytes);
  gpui_text_session_clear_slot(host, slot);
  host->event_read = (host->event_read + 1) % GPUI_EVENT_CAPACITY;
  host->event_count--;
  return 1;
}

static void gpui_text_session_reset_host(gpui_windows_host *host) {
  if (!host)
    return;
  free(g_gpui_text_session.document);
  g_gpui_text_session.document = NULL;
  ZeroMemory(&g_gpui_text_session, sizeof(g_gpui_text_session));
  if (g_gpui_imm.module)
    FreeLibrary(g_gpui_imm.module);
  ZeroMemory(&g_gpui_imm, sizeof(g_gpui_imm));
  host->editor_payload_total = 0;
  host->editor_error = 0;
}

static void gpui_text_session_shutdown(gpui_windows_host *host) {
  if (!host)
    return;
  g_gpui_text_session.armed = FALSE;
  g_gpui_text_session.suppress_ime_messages = TRUE;
  g_gpui_text_session.composing = FALSE;
  free(g_gpui_text_session.document);
  g_gpui_text_session.document = NULL;
  g_gpui_text_session.document_units = 0;
  if (host->hwnd && g_gpui_imm.module && g_gpui_text_session.expected_himc) {
    HIMC detached = g_gpui_imm.associate_context(host->hwnd, NULL);
    if (detached)
      g_gpui_imm.notify_ime(detached, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
    g_gpui_imm.associate_context(host->hwnd, detached);
  }
  for (int32_t i = 0; i < GPUI_EVENT_CAPACITY; ++i)
    gpui_text_session_clear_slot(host, i);
  ZeroMemory(&g_gpui_text_session, sizeof(g_gpui_text_session));
  if (g_gpui_imm.module)
    FreeLibrary(g_gpui_imm.module);
  ZeroMemory(&g_gpui_imm, sizeof(g_gpui_imm));
  host->editor_payload_total = 0;
}

static void gpui_text_session_prune_epoch(gpui_windows_host *host,
                                          int32_t window,
                                          int32_t owner_generation,
                                          int32_t epoch) {
  if (!host || host->event_count == 0)
    return;
  int32_t read = host->event_read;
  int32_t kept = 0;
  int32_t original_count = host->event_count;
  for (int32_t i = 0; i < original_count; ++i) {
    int32_t source = (read + i) % GPUI_EVENT_CAPACITY;
    BOOL remove = host->editor_events[source] &&
                  (int32_t)host->events[source][1] == window &&
                  (int32_t)host->editor_fields[source][0] ==
                      owner_generation &&
                  (int32_t)host->editor_fields[source][1] == epoch;
    if (remove) {
      gpui_text_session_discard_slot(host, source);
      continue;
    }
    int32_t destination = (read + kept) % GPUI_EVENT_CAPACITY;
    if (destination != source) {
      memcpy(host->events[destination], host->events[source],
             sizeof(host->events[source]));
      gpui_text_session_move_slot(host, source, destination);
    }
    kept++;
  }
  host->event_read = read;
  host->event_count = kept;
}

static void gpui_text_session_prune_window(gpui_windows_host *host,
                                           int32_t window) {
  if (!host || host->event_count == 0)
    return;
  int32_t read = host->event_read;
  int32_t kept = 0;
  int32_t original_count = host->event_count;
  for (int32_t i = 0; i < original_count; ++i) {
    int32_t source = (read + i) % GPUI_EVENT_CAPACITY;
    BOOL remove = host->editor_events[source] &&
                  (int32_t)host->events[source][1] == window;
    if (remove) {
      gpui_text_session_discard_slot(host, source);
      continue;
    }
    int32_t destination = (read + kept) % GPUI_EVENT_CAPACITY;
    if (destination != source) {
      memcpy(host->events[destination], host->events[source],
             sizeof(host->events[source]));
      gpui_text_session_move_slot(host, source, destination);
    }
    kept++;
  }
  host->event_read = read;
  host->event_count = kept;
}

/* Reserve before pruning so epoch exhaustion leaves the shared FIFO intact. */
static int32_t gpui_text_session_reserve_cancel_epoch(
    gpui_windows_host *host, int32_t window, int32_t owner_generation,
    int32_t epoch) {
  int32_t next = gpui_text_next_epoch(host);
  if (next <= 0)
    return next;
  gpui_text_session_prune_epoch(host, window, owner_generation, epoch);
  return next;
}

/* The native snapshot can run ahead while several result messages wait in
 * the shared FIFO. Acknowledging an earlier Inserted record must not roll
 * that snapshot back before the next IMM callback captures its range. */
static BOOL gpui_text_session_has_pending_insert(gpui_windows_host *host,
                                                int32_t window,
                                                int32_t owner_generation,
                                                int32_t epoch) {
  if (!host)
    return FALSE;
  for (int32_t i = 0; i < host->event_count; ++i) {
    int32_t slot = (host->event_read + i) % GPUI_EVENT_CAPACITY;
    if (host->editor_events[slot] &&
        (int32_t)host->events[slot][0] == GPUI_TEXT_EVENT_INSERTED &&
        (int32_t)host->events[slot][1] == window &&
        (int32_t)host->editor_fields[slot][0] == owner_generation &&
        (int32_t)host->editor_fields[slot][1] == epoch)
      return TRUE;
  }
  return FALSE;
}

/* Takes ownership of `copy`. Return true when the acknowledgement was
 * deferred because a later commit is still queued. */
static BOOL gpui_text_session_ack_snapshot(gpui_windows_host *host,
                                           int32_t window,
                                           int32_t owner_generation,
                                           int32_t epoch, WCHAR *copy,
                                           int32_t units, int32_t anchor,
                                           int32_t head, double x, double y,
                                           double width, double height) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (gpui_text_session_has_pending_insert(host, window, owner_generation,
                                           epoch)) {
    free(copy);
    session->caret_x = x;
    session->caret_y = y;
    session->caret_width = width;
    session->caret_height = height;
    return TRUE;
  }
  free(session->document);
  session->document = copy;
  session->document_units = units;
  session->anchor_utf16 = anchor;
  session->head_utf16 = head;
  session->caret_x = x;
  session->caret_y = y;
  session->caret_width = width;
  session->caret_height = height;
  if (!session->composing) {
    session->target_start = 0;
    session->target_length = 0;
  }
  return FALSE;
}

static int32_t gpui_text_next_epoch(gpui_windows_host *host) {
  if (g_gpui_text_session.epoch_counter >= INT32_MAX)
    return -gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
  g_gpui_text_session.epoch_counter++;
  if (g_gpui_text_session.epoch_counter <= 0)
    return -gpui_text_session_fail(host, GPUI_WINDOWS_RESOURCE);
  return g_gpui_text_session.epoch_counter;
}

static BOOL gpui_text_rect_valid(double x, double y, double width,
                                 double height) {
  return isfinite(x) && isfinite(y) && isfinite(width) && isfinite(height) &&
         fabs(x) <= 10000000.0 && fabs(y) <= 10000000.0 &&
         width >= 0.0 && height >= 0.0 && width <= 10000000.0 &&
         height <= 10000000.0 && x + width <= 10000000.0 &&
         y + height <= 10000000.0;
}

static int32_t gpui_text_session_set_ime_rect(HIMC context, double scale,
                                              double x, double y,
                                              double width, double height) {
  if (!context || scale <= 0.0 || !isfinite(scale) ||
      !gpui_text_rect_valid(x, y, width, height))
    return GPUI_WINDOWS_INVALID;
  double physical_x = floor(x * scale + 0.5);
  double physical_y = floor(y * scale + 0.5);
  double physical_bottom = floor((y + height) * scale + 0.5);
  if (!isfinite(physical_x) || !isfinite(physical_y) ||
      !isfinite(physical_bottom) || physical_x < INT_MIN ||
      physical_x > INT_MAX || physical_y < INT_MIN ||
      physical_y > INT_MAX || physical_bottom < INT_MIN ||
      physical_bottom > INT_MAX)
    return GPUI_WINDOWS_INVALID;
  COMPOSITIONFORM composition;
  ZeroMemory(&composition, sizeof(composition));
  composition.dwStyle = CFS_FORCE_POSITION;
  composition.ptCurrentPos.x = (LONG)physical_x;
  composition.ptCurrentPos.y = (LONG)physical_y;
  if (!g_gpui_imm.set_composition_window(context, &composition))
    return GPUI_WINDOWS_NATIVE;
  CANDIDATEFORM candidate;
  ZeroMemory(&candidate, sizeof(candidate));
  candidate.dwIndex = 0;
  candidate.dwStyle = CFS_CANDIDATEPOS;
  candidate.ptCurrentPos.x = (LONG)physical_x;
  candidate.ptCurrentPos.y = (LONG)physical_bottom;
  if (!g_gpui_imm.set_candidate_window(context, &candidate))
    return GPUI_WINDOWS_NATIVE;
  return GPUI_WINDOWS_OK;
}

static void gpui_text_session_flush_ime_messages(gpui_windows_host *host,
                                                 HWND hwnd) {
  const UINT messages[] = {
      WM_IME_STARTCOMPOSITION, WM_IME_ENDCOMPOSITION, WM_IME_COMPOSITION,
      WM_IME_SETCONTEXT,       WM_IME_NOTIFY,         WM_IME_CONTROL,
      WM_IME_COMPOSITIONFULL,  WM_IME_SELECT,         WM_IME_CHAR,
      WM_IME_REQUEST,          WM_IME_KEYDOWN,         WM_IME_KEYUP};
  MSG message;
  for (size_t i = 0; i < sizeof(messages) / sizeof(messages[0]); ++i) {
    while (host->api.peek_message_w(&message, hwnd, messages[i], messages[i],
                                    PM_REMOVE)) {
      /* Old-window/old-composition notifications are intentionally consumed
       * while the HWND has no associated HIMC. Never remove WM_CHAR here. */
    }
  }
}

static int32_t gpui_text_session_reassociate(gpui_windows_host *host,
                                              HWND hwnd,
                                              BOOL cancel_composition) {
  if (!host || !hwnd || !g_gpui_imm.module)
    return GPUI_WINDOWS_UNSUPPORTED;
  g_gpui_text_session.suppress_ime_messages = TRUE;
  HIMC prior = g_gpui_imm.associate_context(hwnd, NULL);
  if (!prior)
    return GPUI_WINDOWS_UNSUPPORTED;
  if (g_gpui_text_session.expected_himc &&
      prior != g_gpui_text_session.expected_himc) {
    g_gpui_imm.associate_context(hwnd, prior);
    return GPUI_WINDOWS_STALE;
  }
  if (cancel_composition)
    g_gpui_imm.notify_ime(prior, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
  gpui_text_session_flush_ime_messages(host, hwnd);
  HIMC detached = g_gpui_imm.associate_context(hwnd, prior);
  if (detached != NULL) {
    g_gpui_imm.associate_context(hwnd, detached);
    return GPUI_WINDOWS_STALE;
  }
  HIMC current = g_gpui_imm.get_context(hwnd);
  if (!current)
    return GPUI_WINDOWS_STALE;
  BOOL same = current == prior;
  g_gpui_imm.release_context(hwnd, current);
  if (!same)
    return GPUI_WINDOWS_STALE;
  g_gpui_text_session.expected_himc = prior;
  return GPUI_WINDOWS_OK;
}

static HIMC gpui_text_session_acquire_context(gpui_windows_host *host,
                                              HWND hwnd) {
  if (!g_gpui_text_session.armed || !g_gpui_imm.module || !host ||
      !hwnd || !host->api.get_focus || host->api.get_focus() != hwnd)
    return NULL;
  HIMC context = g_gpui_imm.get_context(hwnd);
  if (!context)
    return NULL;
  if (context != g_gpui_text_session.expected_himc) {
    g_gpui_imm.release_context(hwnd, context);
    gpui_text_session_fail(host, GPUI_WINDOWS_STALE);
    return NULL;
  }
  return context;
}

static WCHAR *gpui_text_snapshot_replace(const WCHAR *document,
                                         int32_t document_units,
                                         int32_t range_start,
                                         int32_t range_length,
                                         const WCHAR *insert,
                                         int32_t insert_units,
                                         int32_t *out_units,
                                         int32_t *out_caret) {
  if (!document || !out_units || !out_caret || range_start < 0 ||
      range_length < 0 || range_start > document_units ||
      range_length > document_units - range_start || insert_units < 0 ||
      (insert_units && !insert) ||
      !gpui_text_wide_boundary(document, document_units, range_start) ||
      !gpui_text_wide_boundary(document, document_units,
                               range_start + range_length))
    return NULL;
  int64_t new_length = (int64_t)document_units - range_length + insert_units;
  if (new_length < 0 || new_length > GPUI_TEXT_MAX_UTF16_UNITS)
    return NULL;
  int32_t result_units = (int32_t)new_length;
  WCHAR *result = (WCHAR *)calloc((size_t)result_units + 1, sizeof(WCHAR));
  if (!result)
    return NULL;
  if (range_start)
    memcpy(result, document, (size_t)range_start * sizeof(WCHAR));
  if (insert_units)
    memcpy(result + range_start, insert,
           (size_t)insert_units * sizeof(WCHAR));
  int32_t suffix_start = range_start + range_length;
  int32_t suffix_units = document_units - suffix_start;
  if (suffix_units)
    memcpy(result + range_start + insert_units, document + suffix_start,
           (size_t)suffix_units * sizeof(WCHAR));
  if (gpui_text_validate_wide(result, result_units) != GPUI_WINDOWS_OK) {
    free(result);
    return NULL;
  }
  uint8_t *utf8 = NULL;
  int32_t utf8_bytes = 0;
  int32_t status = gpui_text_wide_to_utf8(result, result_units, &utf8,
                                          &utf8_bytes);
  free(utf8);
  if (status != GPUI_WINDOWS_OK) {
    free(result);
    return NULL;
  }
  *out_units = result_units;
  *out_caret = range_start + insert_units;
  return result;
}

static int32_t gpui_text_session_publish_cancel(gpui_windows_host *host) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->composing)
    return GPUI_WINDOWS_OK;
  gpui_text_record record;
  ZeroMemory(&record, sizeof(record));
  record.kind = GPUI_TEXT_EVENT_CANCELLED;
  int32_t status = gpui_text_session_emit_batch(host, &record, 1);
  if (status == GPUI_WINDOWS_OK) {
    session->composing = FALSE;
    session->preedit_seen = FALSE;
    session->awaiting_fresh_start = TRUE;
    session->pending_high_surrogate = 0;
  }
  return status;
}

static int32_t gpui_text_session_read_imm_string(HIMC context, DWORD index,
                                                  WCHAR **output,
                                                  int32_t *units) {
  *output = NULL;
  *units = 0;
  LONG byte_count = g_gpui_imm.get_composition_string_w(context, index,
                                                        NULL, 0);
  if (byte_count < 0 || (byte_count & 1) != 0 ||
      byte_count > GPUI_TEXT_MAX_UTF16_UNITS * (LONG)sizeof(WCHAR))
    return GPUI_WINDOWS_INVALID;
  int32_t count = byte_count / (LONG)sizeof(WCHAR);
  WCHAR *buffer = (WCHAR *)calloc((size_t)count + 1, sizeof(WCHAR));
  if (!buffer)
    return GPUI_WINDOWS_RESOURCE;
  if (byte_count) {
    LONG copied = g_gpui_imm.get_composition_string_w(
        context, index, buffer, (DWORD)byte_count);
    if (copied != byte_count) {
      free(buffer);
      return copied < 0 ? GPUI_WINDOWS_NATIVE : GPUI_WINDOWS_STALE;
    }
  }
  int32_t status = gpui_text_validate_wide(buffer, count);
  if (status != GPUI_WINDOWS_OK) {
    free(buffer);
    return status;
  }
  *output = buffer;
  *units = count;
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_session_process_composition(
    gpui_windows_host *host, BOOL result_present, const WCHAR *result,
    int32_t result_units, BOOL marked_present, const WCHAR *marked,
    int32_t marked_units, BOOL cursor_valid, int32_t cursor_utf16,
    const uint8_t *attributes, int32_t attribute_bytes) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->armed || !host->hwnd)
    return GPUI_WINDOWS_STALE;
  if ((result_present && gpui_text_validate_wide(result, result_units) !=
                             GPUI_WINDOWS_OK) ||
      (marked_present && gpui_text_validate_wide(marked, marked_units) !=
                             GPUI_WINDOWS_OK))
    return GPUI_WINDOWS_CONVERSION;
  if (!result_present && !marked_present)
    return GPUI_WINDOWS_INVALID;

  uint8_t *result_utf8 = NULL;
  int32_t result_bytes = 0;
  uint8_t *marked_utf8 = NULL;
  int32_t marked_bytes = 0;
  if (result_present) {
    int32_t status = gpui_text_wide_to_utf8(result, result_units,
                                            &result_utf8, &result_bytes);
    if (status != GPUI_WINDOWS_OK)
      return status;
  }
  if (marked_present) {
    int32_t status = gpui_text_wide_to_utf8(marked, marked_units,
                                            &marked_utf8, &marked_bytes);
    if (status != GPUI_WINDOWS_OK) {
      free(result_utf8);
      return status;
    }
  }
  if (marked_present && attribute_bytes != marked_units) {
    attributes = NULL;
    attribute_bytes = 0;
  }
  if (!marked_present) {
    attributes = NULL;
    attribute_bytes = 0;
    cursor_valid = FALSE;
    cursor_utf16 = 0;
  } else if (cursor_valid &&
             (cursor_utf16 < 0 || cursor_utf16 > marked_units ||
              !gpui_text_wide_boundary(marked, marked_units, cursor_utf16))) {
    cursor_valid = FALSE;
    cursor_utf16 = 0;
  }

  BOOL starting_after_result = !session->composing &&
                               session->commit_waiting_end && marked_present;
  if (!session->composing && !starting_after_result) {
    free(result_utf8);
    free(marked_utf8);
    return GPUI_WINDOWS_STALE;
  }
  int32_t target_start = session->composing ? session->target_start
                                            : session->anchor_utf16;
  int32_t target_length = session->composing ? session->target_length : 0;
  int32_t new_units = session->document_units;
  int32_t new_caret = session->anchor_utf16;
  WCHAR *new_document = NULL;
  if (result_present) {
    new_document = gpui_text_snapshot_replace(
        session->document, session->document_units, target_start,
        target_length, result, result_units, &new_units, &new_caret);
    if (!new_document) {
      free(result_utf8);
      free(marked_utf8);
      return GPUI_WINDOWS_RESOURCE;
    }
  }

  gpui_text_record records[3];
  ZeroMemory(records, sizeof(records));
  int32_t count = 0;
  if (result_present) {
    gpui_text_record *record = &records[count++];
    record->kind = GPUI_TEXT_EVENT_INSERTED;
    record->text = result_utf8;
    record->text_bytes = result_bytes;
    record->range_valid = TRUE;
    record->range_start = target_start;
    record->range_length = target_length;
  }
  if (marked_present) {
    if (result_present || starting_after_result) {
      gpui_text_record *started = &records[count++];
      started->kind = GPUI_TEXT_EVENT_STARTED;
      started->range_valid = TRUE;
      started->range_start = new_caret;
      started->range_length = 0;
    }
    gpui_text_record *record = &records[count++];
    record->kind = GPUI_TEXT_EVENT_MARKED;
    record->text = marked_utf8;
    record->text_bytes = marked_bytes;
    record->attributes = attributes;
    record->attribute_bytes = attribute_bytes;
    record->cursor_valid = cursor_valid;
    record->cursor_utf16 = cursor_utf16;
    record->range_valid = TRUE;
    record->range_start = (result_present || starting_after_result)
                              ? new_caret
                              : target_start;
    record->range_length = (result_present || starting_after_result)
                               ? 0
                               : target_length;
  }

  int32_t status = gpui_text_session_emit_batch(host, records, count);
  free(result_utf8);
  free(marked_utf8);
  if (status != GPUI_WINDOWS_OK) {
    free(new_document);
    return status;
  }

  if (result_present) {
    free(session->document);
    session->document = new_document;
    session->document_units = new_units;
    session->anchor_utf16 = new_caret;
    session->head_utf16 = new_caret;
    session->commit_waiting_end = TRUE;
    session->suppress_ime_char_until_end = TRUE;
    session->composing = FALSE;
    session->preedit_seen = FALSE;
    if (marked_present) {
      session->target_start = new_caret;
      session->target_length = 0;
      session->composing = TRUE;
      session->preedit_seen = TRUE;
      session->commit_waiting_end = FALSE;
    }
  } else {
    free(new_document);
    if (starting_after_result) {
      session->target_start = session->anchor_utf16;
      session->target_length = 0;
      session->composing = TRUE;
      session->commit_waiting_end = FALSE;
    }
    session->preedit_seen = TRUE;
  }
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_session_end_composition(gpui_windows_host *host) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (session->composing) {
    int32_t status = gpui_text_session_publish_cancel(host);
    if (status != GPUI_WINDOWS_OK)
      return status;
  } else if (session->commit_waiting_end) {
    gpui_text_record record;
    ZeroMemory(&record, sizeof(record));
    record.kind = GPUI_TEXT_EVENT_ENDED;
    int32_t status = gpui_text_session_emit_batch(host, &record, 1);
    if (status != GPUI_WINDOWS_OK)
      return status;
    session->commit_waiting_end = FALSE;
  }
  session->suppress_ime_char_until_end = FALSE;
  session->awaiting_fresh_start = TRUE;
  session->pending_high_surrogate = 0;
  return GPUI_WINDOWS_OK;
}

static int32_t gpui_text_session_insert_scalar(gpui_windows_host *host,
                                                uint32_t scalar) {
  if (scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff))
    return GPUI_WINDOWS_INVALID;
  WCHAR units[2];
  int32_t unit_count;
  if (scalar <= 0xffff) {
    units[0] = (WCHAR)scalar;
    unit_count = 1;
  } else {
    scalar -= 0x10000;
    units[0] = (WCHAR)(0xd800 + (scalar >> 10));
    units[1] = (WCHAR)(0xdc00 + (scalar & 0x3ff));
    unit_count = 2;
  }
  uint8_t *utf8 = NULL;
  int32_t utf8_bytes = 0;
  int32_t status = gpui_text_wide_to_utf8(units, unit_count, &utf8,
                                          &utf8_bytes);
  if (status != GPUI_WINDOWS_OK)
    return status;

  gpui_text_record records[2];
  ZeroMemory(records, sizeof(records));
  int32_t count = 0;
  if (g_gpui_text_session.composing) {
    records[count++].kind = GPUI_TEXT_EVENT_CANCELLED;
  }
  int32_t start = g_gpui_text_session.anchor_utf16;
  int32_t end = g_gpui_text_session.head_utf16;
  if (start > end) {
    int32_t swap = start;
    start = end;
    end = swap;
  }
  int32_t new_units = 0;
  int32_t new_caret = 0;
  WCHAR *new_document = gpui_text_snapshot_replace(
      g_gpui_text_session.document, g_gpui_text_session.document_units,
      start, end - start, units, unit_count, &new_units, &new_caret);
  if (!new_document) {
    free(utf8);
    return GPUI_WINDOWS_RESOURCE;
  }
  gpui_text_record *record = &records[count++];
  record->kind = GPUI_TEXT_EVENT_INSERTED;
  record->text = utf8;
  record->text_bytes = utf8_bytes;
  record->range_valid = TRUE;
  record->range_start = start;
  record->range_length = end - start;
  status = gpui_text_session_emit_batch(host, records, count);
  free(utf8);
  if (status != GPUI_WINDOWS_OK) {
    free(new_document);
    return status;
  }
  free(g_gpui_text_session.document);
  g_gpui_text_session.document = new_document;
  g_gpui_text_session.document_units = new_units;
  g_gpui_text_session.anchor_utf16 = new_caret;
  g_gpui_text_session.head_utf16 = new_caret;
  g_gpui_text_session.composing = FALSE;
  g_gpui_text_session.preedit_seen = FALSE;
  g_gpui_text_session.commit_waiting_end = FALSE;
  return GPUI_WINDOWS_OK;
}

static BOOL gpui_text_suppress_control_unit(WCHAR unit, int32_t modifiers) {
  return unit >= 1 && unit <= 26 && (modifiers & 2) != 0 &&
         (modifiers & 4) == 0;
}

static BOOL gpui_text_session_handle_char(gpui_windows_host *host,
                                           HWND hwnd, WCHAR unit,
                                           int32_t modifiers) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (gpui_text_suppress_control_unit(unit, modifiers))
    return TRUE;
  if (!session->armed || session->window_id != host->window_id)
    return FALSE;
  if (session->composing)
    return TRUE;
  HIMC context = gpui_text_session_acquire_context(host, hwnd);
  if (!context)
    return TRUE;
  g_gpui_imm.release_context(hwnd, context);
  if (gpui_text_high_surrogate(unit)) {
    session->pending_high_surrogate = unit;
    return TRUE;
  }
  if (gpui_text_low_surrogate(unit)) {
    WCHAR high = session->pending_high_surrogate;
    session->pending_high_surrogate = 0;
    if (!high)
      return TRUE;
    uint32_t scalar = 0x10000u +
                      (((uint32_t)high - 0xd800u) << 10) +
                      ((uint32_t)unit - 0xdc00u);
    int32_t status = gpui_text_session_insert_scalar(host, scalar);
    if (status != GPUI_WINDOWS_OK)
      gpui_text_session_fail(host, status);
    return TRUE;
  }
  session->pending_high_surrogate = 0;
  if (unit < 0x20)
    return TRUE;
  int32_t status = gpui_text_session_insert_scalar(host, unit);
  if (status != GPUI_WINDOWS_OK)
    gpui_text_session_fail(host, status);
  return TRUE;
}

static BOOL gpui_text_session_handle_ime_char(gpui_windows_host *host,
                                                HWND hwnd, WCHAR unit) {
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->armed || session->window_id != host->window_id)
    return FALSE;
  if (session->composing || session->suppress_ime_char_until_end)
    return TRUE;
  HIMC context = gpui_text_session_acquire_context(host, hwnd);
  if (!context)
    return TRUE;
  g_gpui_imm.release_context(hwnd, context);
  if (gpui_text_high_surrogate(unit)) {
    session->pending_high_surrogate = unit;
    return TRUE;
  }
  if (gpui_text_low_surrogate(unit)) {
    WCHAR high = session->pending_high_surrogate;
    session->pending_high_surrogate = 0;
    if (!high)
      return TRUE;
    uint32_t scalar = 0x10000u +
                      (((uint32_t)high - 0xd800u) << 10) +
                      ((uint32_t)unit - 0xdc00u);
    int32_t status = gpui_text_session_insert_scalar(host, scalar);
    if (status != GPUI_WINDOWS_OK)
      gpui_text_session_fail(host, status);
    return TRUE;
  }
  session->pending_high_surrogate = 0;
  if (unit < 0x20)
    return TRUE;
  int32_t status = gpui_text_session_insert_scalar(host, unit);
  if (status != GPUI_WINDOWS_OK)
    gpui_text_session_fail(host, status);
  return TRUE;
}

static void gpui_text_session_keydown(gpui_windows_host *host,
                                      WPARAM virtual_key, LPARAM lparam) {
  if (!host || virtual_key < 'A' || virtual_key > 'Z')
    return;
  int32_t mods = modifiers_from_message(host, 0);
  if (!(mods & (2 | 4 | 8)) || ((mods & 2) && (mods & 4)))
    return; /* Ctrl+Alt is AltGr: let WM_CHAR carry text. */
  BOOL repeat = (((uintptr_t)lparam >> 30) & 1u) != 0;
  emit_event(host, 15, (double)(virtual_key + ('a' - 'A')),
             repeat ? 1.0 : 0.0, 0, mods);
}

static int32_t gpui_text_session_start_record(gpui_windows_host *host) {
  gpui_text_session_state *session = &g_gpui_text_session;
  int32_t start = session->anchor_utf16;
  int32_t end = session->head_utf16;
  if (start > end) {
    int32_t swap = start;
    start = end;
    end = swap;
  }
  gpui_text_record record;
  ZeroMemory(&record, sizeof(record));
  record.kind = GPUI_TEXT_EVENT_STARTED;
  record.range_valid = TRUE;
  record.range_start = start;
  record.range_length = end - start;
  int32_t status = gpui_text_session_emit_batch(host, &record, 1);
  if (status == GPUI_WINDOWS_OK) {
    session->target_start = start;
    session->target_length = end - start;
    session->composing = TRUE;
    session->preedit_seen = FALSE;
    session->awaiting_fresh_start = FALSE;
    session->commit_waiting_end = FALSE;
    session->pending_high_surrogate = 0;
  }
  return status;
}

static BOOL gpui_text_session_lparam_has_no_gcs_flags(DWORD flags) {
  DWORD gcs_flags = GCS_COMPREADSTR | GCS_COMPREADATTR | GCS_COMPREADCLAUSE |
                    GCS_COMPSTR | GCS_COMPATTR | GCS_COMPCLAUSE |
                    GCS_CURSORPOS | GCS_DELTASTART | GCS_RESULTREADSTR |
                    GCS_RESULTREADCLAUSE | GCS_RESULTSTR | GCS_RESULTCLAUSE;
  return (flags & gcs_flags) == 0;
}

static int32_t gpui_text_session_compose_message(gpui_windows_host *host,
                                                  HWND hwnd,
                                                  LPARAM flags) {
  gpui_text_session_state *session = &g_gpui_text_session;
  DWORD composition_flags = (DWORD)flags;
  BOOL result_present = (composition_flags & GCS_RESULTSTR) != 0;
  DWORD marked_metadata = GCS_COMPATTR | GCS_COMPCLAUSE | GCS_CURSORPOS;
  BOOL marked_present =
      (composition_flags & (GCS_COMPSTR | marked_metadata)) != 0;
  if (gpui_text_session_lparam_has_no_gcs_flags(composition_flags)) {
    if (session->composing)
      return gpui_text_session_publish_cancel(host);
    if (session->commit_waiting_end) {
      gpui_text_record ended;
      ZeroMemory(&ended, sizeof(ended));
      ended.kind = GPUI_TEXT_EVENT_ENDED;
      int32_t status = gpui_text_session_emit_batch(host, &ended, 1);
      if (status == GPUI_WINDOWS_OK)
        session->commit_waiting_end = FALSE;
      return status;
    }
    return GPUI_WINDOWS_OK;
  }
  /* Result-read and clause metadata with no current composition snapshot do
   * not end an active transaction. Cancellation is defined by absence of all
   * GCS flags, even if a CS_INSERTCHAR/CS_NOMOVECARET bit is also present. */
  if (!result_present && !marked_present)
    return GPUI_WINDOWS_OK;
  HIMC context = gpui_text_session_acquire_context(host, hwnd);
  if (!context)
    return host->editor_error ? host->editor_error : GPUI_WINDOWS_STALE;
  if (!session->composing && !session->commit_waiting_end) {
    g_gpui_imm.release_context(hwnd, context);
    return GPUI_WINDOWS_STALE;
  }
  int32_t status = gpui_text_session_set_ime_rect(
      context, host->scale, session->caret_x, session->caret_y,
      session->caret_width, session->caret_height);
  WCHAR *result = NULL;
  WCHAR *marked = NULL;
  int32_t result_units = 0;
  int32_t marked_units = 0;
  uint8_t *attributes = NULL;
  int32_t attribute_bytes = 0;
  BOOL cursor_valid = FALSE;
  int32_t cursor = 0;
  if (status == GPUI_WINDOWS_OK && result_present)
    status = gpui_text_session_read_imm_string(context, GCS_RESULTSTR,
                                               &result, &result_units);
  if (status == GPUI_WINDOWS_OK && marked_present)
    status = gpui_text_session_read_imm_string(context, GCS_COMPSTR,
                                               &marked, &marked_units);
  if (status == GPUI_WINDOWS_OK && marked_present) {
    LONG attribute_count = g_gpui_imm.get_composition_string_w(
        context, GCS_COMPATTR, NULL, 0);
    if (attribute_count >= 0 && attribute_count <= GPUI_TEXT_MAX_ATTRIBUTES &&
        attribute_count == marked_units) {
      if (attribute_count > 0) {
        attributes = (uint8_t *)malloc((size_t)attribute_count);
        if (!attributes) {
          status = GPUI_WINDOWS_RESOURCE;
        } else {
          LONG copied = g_gpui_imm.get_composition_string_w(
              context, GCS_COMPATTR, attributes, (DWORD)attribute_count);
          if (copied != attribute_count) {
            free(attributes);
            attributes = NULL;
          } else {
            attribute_bytes = (int32_t)attribute_count;
          }
        }
      }
    }
  }
  if (status == GPUI_WINDOWS_OK && marked_present) {
    LONG cursor_position = g_gpui_imm.get_composition_string_w(
        context, GCS_CURSORPOS, NULL, 0);
    if (cursor_position >= 0 && cursor_position <= marked_units &&
        gpui_text_wide_boundary(marked, marked_units,
                                (int32_t)cursor_position)) {
      cursor_valid = TRUE;
      cursor = (int32_t)cursor_position;
    }
  }
  g_gpui_imm.release_context(hwnd, context);
  if (status == GPUI_WINDOWS_OK)
    status = gpui_text_session_process_composition(
        host, result_present, result, result_units, marked_present, marked,
        marked_units, cursor_valid, cursor, attributes, attribute_bytes);
  free(result);
  free(marked);
  free(attributes);
  return status;
}

static BOOL gpui_text_session_wndproc(gpui_windows_host *host, HWND hwnd,
                                      UINT message, WPARAM wparam,
                                      LPARAM lparam, LRESULT *result) {
  if (!host || !result)
    return FALSE;
  BOOL ime_message = message == WM_IME_STARTCOMPOSITION ||
                     message == WM_IME_ENDCOMPOSITION ||
                     message == WM_IME_COMPOSITION ||
                     message == WM_IME_CHAR ||
                     message == WM_IME_SETCONTEXT ||
                     message == WM_IME_NOTIFY ||
                     message == WM_IME_CONTROL ||
                     message == WM_IME_COMPOSITIONFULL ||
                     message == WM_IME_SELECT ||
                     message == WM_IME_REQUEST ||
                     message == WM_IME_KEYDOWN || message == WM_IME_KEYUP;
  if (g_gpui_text_session.suppress_ime_messages &&
      (ime_message || message == WM_CHAR || message == WM_UNICHAR) &&
      g_gpui_text_session.window_id == host->window_id) {
    *result = 0;
    return TRUE;
  }
  if (host->editor_error &&
      g_gpui_text_session.window_id == host->window_id &&
      (ime_message || message == WM_CHAR || message == WM_UNICHAR)) {
    *result = 0;
    return TRUE;
  }
  int32_t mods = modifiers_from_message(host, 0);
  if (message == WM_CHAR &&
      gpui_text_suppress_control_unit((WCHAR)wparam, mods)) {
    *result = 0;
    return TRUE;
  }
  if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN)
    gpui_text_session_keydown(host, wparam, lparam);
  if (!g_gpui_text_session.armed || g_gpui_text_session.window_id !=
                                         host->window_id)
    return FALSE;
  if (g_gpui_text_session.composing &&
      (message == WM_KEYDOWN || message == WM_SYSKEYDOWN ||
       message == WM_KEYUP || message == WM_SYSKEYUP)) {
    BOOL command_shortcut =
        (wparam >= 'A' && wparam <= 'Z') && (mods & (2 | 4 | 8)) &&
        !((mods & 2) && (mods & 4));
    if (command_shortcut || wparam == VK_ESCAPE)
      return FALSE;
    *result = host->api.def_window_proc_w(hwnd, message, wparam, lparam);
    return TRUE;
  }
  int32_t status = GPUI_WINDOWS_OK;
  switch (message) {
  case WM_CHAR:
    *result = 0;
    return gpui_text_session_handle_char(host, hwnd, (WCHAR)wparam, mods);
  case WM_UNICHAR:
    if (wparam == UNICODE_NOCHAR)
      return FALSE;
    *result = 0;
    if (g_gpui_text_session.composing ||
        g_gpui_text_session.suppress_ime_char_until_end)
      return TRUE;
    if (wparam > 0x10ffff) {
      gpui_text_session_fail(host, GPUI_WINDOWS_INVALID);
      return TRUE;
    }
    {
      HIMC context = gpui_text_session_acquire_context(host, hwnd);
      if (!context)
        return TRUE;
      g_gpui_imm.release_context(hwnd, context);
      status = gpui_text_session_insert_scalar(host, (uint32_t)wparam);
      if (status != GPUI_WINDOWS_OK)
        gpui_text_session_fail(host, status);
    }
    return TRUE;
  case WM_IME_STARTCOMPOSITION: {
    *result = 0;
    if (g_gpui_text_session.composing)
      return TRUE; /* duplicate START cannot replace the captured target */
    if (!g_gpui_text_session.awaiting_fresh_start)
      return TRUE;
    HIMC context = gpui_text_session_acquire_context(host, hwnd);
    if (!context)
      return TRUE;
    status = gpui_text_session_set_ime_rect(
        context, host->scale, g_gpui_text_session.caret_x,
        g_gpui_text_session.caret_y, g_gpui_text_session.caret_width,
        g_gpui_text_session.caret_height);
    g_gpui_imm.release_context(hwnd, context);
    if (status == GPUI_WINDOWS_OK)
      status = gpui_text_session_start_record(host);
    if (status != GPUI_WINDOWS_OK)
      gpui_text_session_fail(host, status);
    return TRUE;
  }
  case WM_IME_COMPOSITION:
    *result = 0; /* suppress DefWindowProc's duplicate WM_IME_CHAR/WM_CHAR */
    status = gpui_text_session_compose_message(host, hwnd, lparam);
    if (status != GPUI_WINDOWS_OK && status != GPUI_WINDOWS_STALE)
      gpui_text_session_fail(host, status);
    return TRUE;
  case WM_IME_ENDCOMPOSITION:
    *result = 0;
    {
      HIMC context = gpui_text_session_acquire_context(host, hwnd);
      if (!context)
        return TRUE;
      g_gpui_imm.release_context(hwnd, context);
    }
    status = gpui_text_session_end_composition(host);
    if (status != GPUI_WINDOWS_OK)
      gpui_text_session_fail(host, status);
    return TRUE;
  case WM_IME_CHAR:
    *result = 0;
    return gpui_text_session_handle_ime_char(host, hwnd, (WCHAR)wparam);
  default:
    return FALSE;
  }
}

static void gpui_text_session_focus_lost(gpui_windows_host *host) {
  if (!host || !g_gpui_text_session.armed)
    return;
  int32_t next = gpui_text_next_epoch(host);
  if (next <= 0)
    return;
  if (g_gpui_text_session.composing)
    gpui_text_session_publish_cancel(host);
  else if (g_gpui_text_session.commit_waiting_end) {
    gpui_text_record ended;
    ZeroMemory(&ended, sizeof(ended));
    ended.kind = GPUI_TEXT_EVENT_ENDED;
    gpui_text_session_emit_batch(host, &ended, 1);
  }
  g_gpui_text_session.armed = FALSE;
  g_gpui_text_session.suppress_ime_messages = TRUE;
  g_gpui_text_session.awaiting_fresh_start = FALSE;
  g_gpui_text_session.composing = FALSE;
  g_gpui_text_session.commit_waiting_end = FALSE;
  g_gpui_text_session.pending_high_surrogate = 0;
  g_gpui_text_session.epoch = next;
  if (host->hwnd && g_gpui_imm.module &&
      g_gpui_text_session.expected_himc) {
    HIMC context = g_gpui_imm.get_context(host->hwnd);
    if (context) {
      if (context == g_gpui_text_session.expected_himc)
        g_gpui_imm.notify_ime(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
      g_gpui_imm.release_context(host->hwnd, context);
    }
  }
}

static void gpui_text_session_forget_window(gpui_windows_host *host,
                                             int32_t window) {
  if (!host)
    return;
  if (g_gpui_text_session.window_id == window) {
    g_gpui_text_session.armed = FALSE;
    g_gpui_text_session.suppress_ime_messages = TRUE;
    g_gpui_text_session.awaiting_fresh_start = FALSE;
    g_gpui_text_session.composing = FALSE;
    g_gpui_text_session.commit_waiting_end = FALSE;
    g_gpui_text_session.pending_high_surrogate = 0;
    int32_t next = gpui_text_next_epoch(host);
    if (next > 0)
      g_gpui_text_session.epoch = next;
    if (host->hwnd && g_gpui_imm.module &&
        g_gpui_text_session.expected_himc) {
      HIMC context = g_gpui_imm.get_context(host->hwnd);
      if (context) {
        if (context == g_gpui_text_session.expected_himc)
          g_gpui_imm.notify_ime(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
        g_gpui_imm.release_context(host->hwnd, context);
      }
    }
    free(g_gpui_text_session.document);
    g_gpui_text_session.document = NULL;
    g_gpui_text_session.document_units = 0;
    g_gpui_text_session.window_id = 0;
  }
}

static void gpui_text_session_set_platform_slot(gpui_windows_host *host,
                                                 int32_t slot) {
  if (!host || slot < 0 || slot >= GPUI_EVENT_CAPACITY)
    return;
  gpui_text_session_clear_slot(host, slot);
}

int32_t gpui_windows_session_begin(int32_t token, int32_t window,
                                   int32_t owner_generation,
                                   const uint8_t *text, int32_t text_length,
                                   int32_t anchor_utf16, int32_t head_utf16,
                                   double x, double y, double width,
                                   double height) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (owner_generation <= 0 || !gpui_text_rect_valid(x, y, width, height))
    return -GPUI_WINDOWS_INVALID;
  if (g_host.editor_error)
    return -g_host.editor_error;
  if (g_gpui_text_session.armed)
    return -GPUI_WINDOWS_BUSY;
  if (!g_host.api.get_focus || g_host.api.get_focus() != g_host.hwnd)
    return -GPUI_WINDOWS_BUSY;
  WCHAR *copy = NULL;
  int32_t units = 0;
  status = gpui_text_utf8_to_wide(text, text_length, &copy, &units);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (anchor_utf16 < 0 || head_utf16 < 0 || anchor_utf16 > units ||
      head_utf16 > units || !gpui_text_wide_boundary(copy, units, anchor_utf16) ||
      !gpui_text_wide_boundary(copy, units, head_utf16)) {
    free(copy);
    return -GPUI_WINDOWS_INVALID;
  }
  status = gpui_text_imm_init();
  if (status != GPUI_WINDOWS_OK) {
    free(copy);
    return -status;
  }
  int32_t epoch = gpui_text_next_epoch(&g_host);
  if (epoch <= 0) {
    free(copy);
    return epoch;
  }
  if (g_gpui_text_session.window_id)
    gpui_text_session_prune_window(&g_host,
                                   g_gpui_text_session.window_id);
  g_gpui_text_session.epoch = epoch;
  g_gpui_text_session.owner_generation = owner_generation;
  g_gpui_text_session.window_id = window;
  g_gpui_text_session.expected_himc = NULL;
  status = gpui_text_session_reassociate(&g_host, g_host.hwnd, TRUE);
  if (status != GPUI_WINDOWS_OK) {
    free(copy);
    g_gpui_text_session.armed = FALSE;
    return -status;
  }
  HIMC context = g_gpui_imm.get_context(g_host.hwnd);
  if (!context) {
    free(copy);
    g_gpui_text_session.armed = FALSE;
    return -GPUI_WINDOWS_UNSUPPORTED;
  }
  status = gpui_text_session_set_ime_rect(context, g_host.scale, x, y,
                                          width, height);
  g_gpui_imm.release_context(g_host.hwnd, context);
  if (status != GPUI_WINDOWS_OK) {
    free(copy);
    g_gpui_text_session.armed = FALSE;
    return -status;
  }
  free(g_gpui_text_session.document);
  g_gpui_text_session.document = copy;
  g_gpui_text_session.document_units = units;
  g_gpui_text_session.anchor_utf16 = anchor_utf16;
  g_gpui_text_session.head_utf16 = head_utf16;
  g_gpui_text_session.caret_x = x;
  g_gpui_text_session.caret_y = y;
  g_gpui_text_session.caret_width = width;
  g_gpui_text_session.caret_height = height;
  g_gpui_text_session.composing = FALSE;
  g_gpui_text_session.preedit_seen = FALSE;
  g_gpui_text_session.commit_waiting_end = FALSE;
  g_gpui_text_session.suppress_ime_char_until_end = FALSE;
  g_gpui_text_session.pending_high_surrogate = 0;
  g_gpui_text_session.awaiting_fresh_start = TRUE;
  g_gpui_text_session.armed = TRUE;
  g_gpui_text_session.suppress_ime_messages = FALSE;
  return epoch;
}

int32_t gpui_windows_session_update(int32_t token, int32_t window,
                                    int32_t epoch,
                                    int32_t owner_generation,
                                    const uint8_t *text, int32_t text_length,
                                    int32_t anchor_utf16, int32_t head_utf16,
                                    double x, double y, double width,
                                    double height, int32_t external_edit) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->armed || session->epoch != epoch ||
      session->owner_generation != owner_generation ||
      session->window_id != window)
    return -GPUI_WINDOWS_STALE;
  if (external_edit != 0 && external_edit != 1)
    return -GPUI_WINDOWS_INVALID;
  if (g_host.editor_error)
    return -g_host.editor_error;
  if (!g_host.api.get_focus || g_host.api.get_focus() != g_host.hwnd)
    return -GPUI_WINDOWS_BUSY;
  if (!gpui_text_rect_valid(x, y, width, height))
    return -GPUI_WINDOWS_INVALID;
  WCHAR *copy = NULL;
  int32_t units = 0;
  status = gpui_text_utf8_to_wide(text, text_length, &copy, &units);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (anchor_utf16 < 0 || head_utf16 < 0 || anchor_utf16 > units ||
      head_utf16 > units || !gpui_text_wide_boundary(copy, units, anchor_utf16) ||
      !gpui_text_wide_boundary(copy, units, head_utf16)) {
    free(copy);
    return -GPUI_WINDOWS_INVALID;
  }
  int32_t next = 0;
  if (external_edit) {
    next = gpui_text_next_epoch(&g_host);
    if (next <= 0) {
      free(copy);
      return next;
    }
  }
  HIMC context = gpui_text_session_acquire_context(&g_host, g_host.hwnd);
  if (!context) {
    free(copy);
    return -(g_host.editor_error ? g_host.editor_error : GPUI_WINDOWS_STALE);
  }
  status = gpui_text_session_set_ime_rect(context, g_host.scale, x, y,
                                          width, height);
  g_gpui_imm.release_context(g_host.hwnd, context);
  if (status != GPUI_WINDOWS_OK) {
    free(copy);
    return -status;
  }
  if (!external_edit) {
    /* A popped Inserted is already reflected in the caller's document, but a
     * later queued result may have advanced the native range even further. */
    gpui_text_session_ack_snapshot(&g_host, window, owner_generation, epoch,
                                   copy, units, anchor_utf16, head_utf16,
                                   x, y, width, height);
    return session->epoch;
  }
  if (external_edit) {
    gpui_text_session_prune_epoch(&g_host, window, owner_generation, epoch);
    /* Invalidate before ImmNotifyIME can synchronously reenter the WndProc. */
    session->armed = FALSE;
    session->suppress_ime_messages = TRUE;
    session->awaiting_fresh_start = FALSE;
    session->composing = FALSE;
    session->preedit_seen = FALSE;
    session->epoch = next;
    session->pending_high_surrogate = 0;
    status = gpui_text_session_reassociate(&g_host, g_host.hwnd, TRUE);
    if (status != GPUI_WINDOWS_OK) {
      free(copy);
      return -gpui_text_session_fail(&g_host, status);
    }
    session->awaiting_fresh_start = TRUE;
    session->commit_waiting_end = FALSE;
    session->suppress_ime_char_until_end = FALSE;
  }
  free(session->document);
  session->document = copy;
  session->document_units = units;
  session->anchor_utf16 = anchor_utf16;
  session->head_utf16 = head_utf16;
  session->caret_x = x;
  session->caret_y = y;
  session->caret_width = width;
  session->caret_height = height;
  if (!session->composing) {
    session->target_start = 0;
    session->target_length = 0;
  }
  if (external_edit) {
    session->armed = TRUE;
    session->suppress_ime_messages = FALSE;
  }
  return session->epoch;
}

int32_t gpui_windows_session_cancel(int32_t token, int32_t window,
                                    int32_t epoch,
                                    int32_t owner_generation) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->armed || session->epoch != epoch ||
      session->owner_generation != owner_generation ||
      session->window_id != window)
    return -GPUI_WINDOWS_STALE;
  if (g_host.editor_error)
    return -g_host.editor_error;
  int32_t next = gpui_text_session_reserve_cancel_epoch(
      &g_host, window, owner_generation, epoch);
  if (next <= 0)
    return next;
  /* The app initiated cancel; old typed records are pruned and no callback
   * from the old composition may be published while IMM is synchronously reset. */
  session->armed = FALSE;
  session->suppress_ime_messages = TRUE;
  session->awaiting_fresh_start = FALSE;
  session->composing = FALSE;
  session->preedit_seen = FALSE;
  session->epoch = next;
  session->pending_high_surrogate = 0;
  status = gpui_text_session_reassociate(&g_host, g_host.hwnd, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return -gpui_text_session_fail(&g_host, status);
  session->epoch = next;
  session->awaiting_fresh_start = TRUE;
  session->armed = TRUE;
  session->suppress_ime_messages = FALSE;
  session->composing = FALSE;
  session->preedit_seen = FALSE;
  session->commit_waiting_end = FALSE;
  session->suppress_ime_char_until_end = FALSE;
  session->pending_high_surrogate = 0;
  return next;
}

int32_t gpui_windows_session_end(int32_t token, int32_t window,
                                 int32_t epoch,
                                 int32_t owner_generation) {
  int32_t status = check_window(token, window);
  if (status != GPUI_WINDOWS_OK)
    return status;
  gpui_text_session_state *session = &g_gpui_text_session;
  if (!session->armed) {
    if (session->window_id != window ||
        session->owner_generation != owner_generation)
      return GPUI_WINDOWS_STALE;
    free(session->document);
    session->document = NULL;
    session->document_units = 0;
    return GPUI_WINDOWS_OK;
  }
  if (session->epoch != epoch || session->owner_generation != owner_generation ||
      session->window_id != window)
    return GPUI_WINDOWS_STALE;
  if (g_host.editor_error)
    return g_host.editor_error;
  int32_t next = gpui_text_next_epoch(&g_host);
  if (next <= 0)
    return -next;
  if (session->composing) {
    status = gpui_text_session_publish_cancel(&g_host);
    if (status != GPUI_WINDOWS_OK)
      return status;
  } else if (session->commit_waiting_end) {
    gpui_text_record ended;
    ZeroMemory(&ended, sizeof(ended));
    ended.kind = GPUI_TEXT_EVENT_ENDED;
    status = gpui_text_session_emit_batch(&g_host, &ended, 1);
    if (status != GPUI_WINDOWS_OK)
      return status;
  }
  session->armed = FALSE;
  session->suppress_ime_messages = TRUE;
  session->awaiting_fresh_start = FALSE;
  session->composing = FALSE;
  session->commit_waiting_end = FALSE;
  session->epoch = next;
  session->pending_high_surrogate = 0;
  status = gpui_text_session_reassociate(&g_host, g_host.hwnd, TRUE);
  if (status != GPUI_WINDOWS_OK)
    gpui_text_session_fail(&g_host, status);
  else
    session->suppress_ime_messages = FALSE;
  session->armed = FALSE;
  session->awaiting_fresh_start = FALSE;
  session->composing = FALSE;
  session->suppress_ime_char_until_end = FALSE;
  session->pending_high_surrogate = 0;
  free(session->document);
  session->document = NULL;
  session->document_units = 0;
  return status;
}

int32_t gpui_windows_window_has_keyboard_focus(int32_t token,
                                               int32_t window) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return -status;
  if (window != g_host.window_id || !g_host.hwnd)
    return -GPUI_WINDOWS_STALE;
  if (!g_host.api.get_focus)
    return -GPUI_WINDOWS_UNSUPPORTED;
  return g_host.api.get_focus() == g_host.hwnd ? 1 : 0;
}
