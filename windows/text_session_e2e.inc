/* Production-path, synthetic IMM staging tests. These exercise the same
 * atomic queue publication and snapshot replacement helpers used by WndProc;
 * they do not claim that a real Japanese IME has been qualified. */
static BOOL gpui_text_test_document_is(const WCHAR *expected, int32_t units) {
  return g_gpui_text_session.document &&
         g_gpui_text_session.document_units == units &&
         memcmp(g_gpui_text_session.document, expected,
                (size_t)units * sizeof(WCHAR)) == 0;
}

static BOOL gpui_text_test_set_document(const WCHAR *text, int32_t units,
                                        int32_t anchor, int32_t head) {
  WCHAR *copy = (WCHAR *)calloc((size_t)units + 1, sizeof(WCHAR));
  if (!copy)
    return FALSE;
  if (units)
    memcpy(copy, text, (size_t)units * sizeof(WCHAR));
  free(g_gpui_text_session.document);
  g_gpui_text_session.document = copy;
  g_gpui_text_session.document_units = units;
  g_gpui_text_session.anchor_utf16 = anchor;
  g_gpui_text_session.head_utf16 = head;
  return TRUE;
}

static BOOL gpui_text_test_init(gpui_windows_host *host,
                                const WCHAR *text, int32_t units,
                                int32_t anchor, int32_t head,
                                int32_t epoch, int32_t owner) {
  free(g_gpui_text_session.document);
  ZeroMemory(&g_gpui_text_session, sizeof(g_gpui_text_session));
  if (!gpui_text_test_set_document(text, units, anchor, head))
    return FALSE;
  host->state = 0;
  host->hwnd = (HWND)(uintptr_t)1;
  host->window_id = 5;
  host->scale = 1.0;
  host->logical_width = 640.0;
  host->logical_height = 240.0;
  host->sequence = 0;
  host->event_read = 0;
  host->event_count = 0;
  host->editor_payload_total = 0;
  host->editor_error = 0;
  g_gpui_text_session.epoch_counter = epoch;
  g_gpui_text_session.epoch = epoch;
  g_gpui_text_session.owner_generation = owner;
  g_gpui_text_session.window_id = 5;
  g_gpui_text_session.armed = TRUE;
  g_gpui_text_session.awaiting_fresh_start = TRUE;
  g_gpui_text_session.caret_width = 1.0;
  g_gpui_text_session.caret_height = 18.0;
  return TRUE;
}

static void gpui_text_test_clear_ring(gpui_windows_host *host) {
  for (int32_t i = 0; i < GPUI_EVENT_CAPACITY; ++i)
    gpui_text_session_clear_slot(host, i);
  host->event_read = 0;
  host->event_count = 0;
  host->editor_payload_total = 0;
  host->editor_error = 0;
  host->sequence = 0;
}

static BOOL gpui_text_test_record(gpui_windows_host *host, int32_t offset,
                                  int32_t kind, int32_t start,
                                  int32_t length, int64_t sequence) {
  int32_t slot = (host->event_read + offset) % GPUI_EVENT_CAPACITY;
  return host->editor_events[slot] &&
         (int32_t)host->events[slot][0] == kind &&
         (int64_t)host->events[slot][2] == sequence &&
         host->events[slot][4] == 0.0 &&
         host->events[slot][5] == 0.0 &&
         host->events[slot][6] == 0.0 &&
         host->events[slot][7] == 0.0 &&
         host->events[slot][8] == 0.0 &&
         host->events[slot][9] == 0.0 &&
         (int32_t)host->editor_fields[slot][0] ==
             g_gpui_text_session.owner_generation &&
         (int32_t)host->editor_fields[slot][1] == g_gpui_text_session.epoch &&
         (int32_t)host->editor_fields[slot][5] == 1 &&
         (int32_t)host->editor_fields[slot][6] == start &&
         (int32_t)host->editor_fields[slot][7] == length;
}

static MSG gpui_text_review_messages[8];
static int32_t gpui_text_review_message_count;
static HIMC gpui_text_review_associated_context;
static HWND gpui_text_review_focus_hwnd;
static int32_t gpui_text_review_failed_form;
static int32_t gpui_text_review_def_calls;
static int32_t gpui_text_review_reenter_mode;
static BOOL gpui_text_review_reentered;

static LONG_PTR WINAPI gpui_text_review_get_window_long_ptr(HWND hwnd,
                                                            int32_t index) {
  (void)hwnd;
  (void)index;
  return (LONG_PTR)&g_host;
}

static HWND WINAPI gpui_text_review_get_focus(void) {
  return gpui_text_review_focus_hwnd;
}

static SHORT WINAPI gpui_text_review_get_key_state(int key) {
  (void)key;
  return 0;
}

static LRESULT WINAPI gpui_text_review_def_window_proc(HWND hwnd, UINT message,
                                                       WPARAM wparam,
                                                       LPARAM lparam) {
  (void)hwnd;
  (void)message;
  (void)wparam;
  (void)lparam;
  gpui_text_review_def_calls++;
  return (LRESULT)0x5151;
}

static BOOL WINAPI gpui_text_review_peek_message(LPMSG output, HWND hwnd,
                                                 UINT minimum, UINT maximum,
                                                 UINT remove) {
  BOOL trigger_reentry =
      !gpui_text_review_reentered &&
      ((gpui_text_review_reenter_mode == 1 && remove == PM_NOREMOVE) ||
       (gpui_text_review_reenter_mode == 2 && remove == PM_REMOVE));
  if (trigger_reentry) {
    gpui_text_review_reentered = TRUE;
    gpui_window_proc(g_host.hwnd, WM_KEYDOWN, VK_LEFT, 0);
  }
  for (int32_t i = 0; i < gpui_text_review_message_count; ++i) {
    MSG candidate = gpui_text_review_messages[i];
    if (hwnd && candidate.hwnd != hwnd)
      continue;
    if ((minimum || maximum) &&
        (candidate.message < minimum || candidate.message > maximum))
      continue;
    if (output)
      *output = candidate;
    if (remove & PM_REMOVE) {
      for (int32_t j = i + 1; j < gpui_text_review_message_count; ++j)
        gpui_text_review_messages[j - 1] = gpui_text_review_messages[j];
      gpui_text_review_message_count--;
    }
    return TRUE;
  }
  return FALSE;
}

static BOOL WINAPI gpui_text_review_translate_message(const MSG *message) {
  (void)message;
  return TRUE;
}

static LRESULT WINAPI gpui_text_review_dispatch_message(const MSG *message) {
  return gpui_window_proc(message->hwnd, message->message,
                          message->wParam, message->lParam);
}

static DWORD WINAPI gpui_text_review_wait(DWORD count, const HANDLE *handles,
                                          BOOL wait_all, DWORD timeout,
                                          DWORD wake_mask) {
  (void)count;
  (void)handles;
  (void)wait_all;
  (void)timeout;
  (void)wake_mask;
  return WAIT_TIMEOUT;
}

static HIMC WINAPI gpui_text_review_get_context(HWND hwnd) {
  (void)hwnd;
  return gpui_text_review_associated_context;
}

static BOOL WINAPI gpui_text_review_release_context(HWND hwnd, HIMC context) {
  (void)hwnd;
  (void)context;
  return TRUE;
}

static HIMC WINAPI gpui_text_review_associate_context(HWND hwnd,
                                                      HIMC context) {
  (void)hwnd;
  HIMC prior = gpui_text_review_associated_context;
  gpui_text_review_associated_context = context;
  return prior;
}

static LONG WINAPI gpui_text_review_get_composition_string(
    HIMC context, DWORD index, LPVOID buffer, DWORD bytes) {
  (void)context;
  (void)index;
  (void)buffer;
  (void)bytes;
  return 0;
}

static BOOL WINAPI gpui_text_review_set_composition_window(
    HIMC context, LPCOMPOSITIONFORM form) {
  (void)context;
  return gpui_text_review_failed_form != 1 &&
         form->dwStyle == CFS_FORCE_POSITION;
}

static BOOL WINAPI gpui_text_review_set_candidate_window(
    HIMC context, LPCANDIDATEFORM form) {
  (void)context;
  return gpui_text_review_failed_form != 2 &&
         form->dwStyle == CFS_CANDIDATEPOS;
}

static BOOL WINAPI gpui_text_review_notify_ime(HIMC context, DWORD action,
                                                DWORD index, DWORD value) {
  (void)context;
  (void)action;
  (void)index;
  (void)value;
  return TRUE;
}

static void gpui_text_review_setup_host(void) {
  ZeroMemory(&g_host, sizeof(g_host));
  g_host.token = 77;
  g_host.window_id = 5;
  g_host.owner_thread = GetCurrentThreadId();
  g_host.state = 0;
  g_host.hwnd = (HWND)(uintptr_t)1;
  gpui_text_review_focus_hwnd = g_host.hwnd;
  g_host.scale = 1.0;
  g_host.logical_width = 640.0;
  g_host.logical_height = 240.0;
  g_host.api.get_window_long_ptr_w = gpui_text_review_get_window_long_ptr;
  g_host.api.get_focus = gpui_text_review_get_focus;
  g_host.api.get_key_state = gpui_text_review_get_key_state;
  g_host.api.def_window_proc_w = gpui_text_review_def_window_proc;
  g_host.api.peek_message_w = gpui_text_review_peek_message;
  g_host.api.translate_message = gpui_text_review_translate_message;
  g_host.api.dispatch_message_w = gpui_text_review_dispatch_message;
  g_host.api.msg_wait_for_multiple_objects = gpui_text_review_wait;
  gpui_text_review_message_count = 0;
  gpui_text_review_reenter_mode = 0;
  gpui_text_review_reentered = FALSE;
  gpui_text_review_associated_context = (HIMC)(uintptr_t)0x1234;
  gpui_text_review_failed_form = 0;
  gpui_text_review_def_calls = 0;
}

static BOOL gpui_text_review_queue(UINT message, WPARAM wparam) {
  if (gpui_text_review_message_count >=
      (int32_t)(sizeof(gpui_text_review_messages) /
                sizeof(gpui_text_review_messages[0])))
    return FALSE;
  int32_t at = gpui_text_review_message_count++;
  ZeroMemory(&gpui_text_review_messages[at],
             sizeof(gpui_text_review_messages[at]));
  gpui_text_review_messages[at].hwnd = g_host.hwnd;
  gpui_text_review_messages[at].message = message;
  gpui_text_review_messages[at].wParam = wparam;
  return TRUE;
}

/* mode 1 reenters during PM_NOREMOVE; mode 2 reenters during PM_REMOVE after
 * which the fake queue returns its already-removed WM_CHAR. */
static int32_t gpui_text_review_reentrant_case(int32_t mode,
                                               int32_t stage_base) {
  const uint8_t ab_text[] = {'a', 'b'};
  WCHAR expected_axb[] = {L'a', L'X', L'b'};
  double event[20];
  uint8_t payload[GPUI_TEXT_MAX_STRING_BYTES + GPUI_TEXT_MAX_ATTRIBUTES];
  int32_t result = 0;
  int32_t epoch = 0;
  int32_t updated_epoch = 0;

#define GPUI_REENTRANT_REQUIRE(condition, offset)                            \
  do {                                                                         \
    if (!(condition)) {                                                        \
      result = stage_base + (offset);                                          \
      goto reentrant_cleanup;                                                  \
    }                                                                          \
  } while (0)

  gpui_text_test_clear_ring(&g_host);
  gpui_text_review_message_count = 0;
  gpui_text_review_reenter_mode = 0;
  gpui_text_review_reentered = FALSE;
  epoch = gpui_windows_session_begin(
      77, 5, 800 + mode, ab_text, sizeof(ab_text), 2, 2,
      8.0, 9.0, 1.0, 18.0);
  GPUI_REENTRANT_REQUIRE(epoch > 0 && g_gpui_text_session.armed, 1);
  GPUI_REENTRANT_REQUIRE(gpui_text_review_queue(WM_CHAR, 'X'), 2);
  gpui_text_review_reenter_mode = mode;
  GPUI_REENTRANT_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                              gpui_text_review_reentered &&
                              g_host.event_count == 1 &&
                              !g_host.editor_events[g_host.event_read] &&
                              (int32_t)g_host.events[g_host.event_read][0] ==
                                  11 &&
                              (int32_t)g_host.events[g_host.event_read][8] ==
                                  0xff51,
                          3);
  if (mode == 1) {
    GPUI_REENTRANT_REQUIRE(gpui_text_review_message_count == 1 &&
                                !g_host.deferred_message_pending &&
                                gpui_text_review_messages[0].message ==
                                    WM_CHAR &&
                                gpui_text_review_messages[0].wParam == 'X',
                            4);
  } else {
    GPUI_REENTRANT_REQUIRE(gpui_text_review_message_count == 0 &&
                                g_host.deferred_message_pending &&
                                g_host.deferred_message.hwnd == g_host.hwnd &&
                                g_host.deferred_message.message == WM_CHAR &&
                                g_host.deferred_message.wParam == 'X',
                            4);
  }
  GPUI_REENTRANT_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                              g_host.event_count == 1 &&
                              ((mode == 1 &&
                                gpui_text_review_message_count == 1 &&
                                !g_host.deferred_message_pending) ||
                               (mode == 2 &&
                                gpui_text_review_message_count == 0 &&
                                g_host.deferred_message_pending)),
                          5);
  GPUI_REENTRANT_REQUIRE(gpui_text_session_pop(&g_host, event, payload,
                                                sizeof(payload)) == 1 &&
                              (int32_t)event[0] == 11 &&
                              (int64_t)event[2] == 1,
                          6);
  updated_epoch = gpui_windows_session_update(
      77, 5, epoch, 800 + mode, ab_text, sizeof(ab_text), 1, 1,
      8.0, 9.0, 1.0, 18.0, 1);
  GPUI_REENTRANT_REQUIRE(updated_epoch > epoch &&
                              ((mode == 1 &&
                                gpui_text_review_message_count == 1 &&
                                !g_host.deferred_message_pending) ||
                               (mode == 2 &&
                                gpui_text_review_message_count == 0 &&
                                g_host.deferred_message_pending)),
                          7);
  GPUI_REENTRANT_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                              gpui_text_review_message_count == 0 &&
                              !g_host.deferred_message_pending &&
                              g_host.event_count == 1 &&
                              g_host.editor_events[g_host.event_read] &&
                              (int32_t)g_host.events[g_host.event_read][0] ==
                                  GPUI_TEXT_EVENT_INSERTED &&
                              (int64_t)g_host.events[g_host.event_read][2] == 2 &&
                              (int32_t)g_host.editor_fields[g_host.event_read][1] ==
                                  updated_epoch &&
                              (int32_t)g_host.editor_fields[g_host.event_read][6] ==
                                  1 &&
                              (int32_t)g_host.editor_fields[g_host.event_read][7] ==
                                  0 &&
                              gpui_text_test_document_is(expected_axb, 3) &&
                              g_gpui_text_session.anchor_utf16 == 2 &&
                              g_gpui_text_session.head_utf16 == 2,
                          8);
  GPUI_REENTRANT_REQUIRE(gpui_text_session_pop(
                             &g_host, event, payload, sizeof(payload)) == 1 &&
                              (int32_t)event[0] == GPUI_TEXT_EVENT_INSERTED &&
                              (int32_t)event[10] == 800 + mode &&
                              payload[0] == 'X',
                          9);
  GPUI_REENTRANT_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                              g_host.event_count == 0 &&
                              gpui_text_review_message_count == 0 &&
                              !g_host.deferred_message_pending &&
                              gpui_text_test_document_is(expected_axb, 3),
                          10);
  GPUI_REENTRANT_REQUIRE(gpui_windows_session_end(
                             77, 5, updated_epoch, 800 + mode) ==
                              GPUI_WINDOWS_OK,
                          11);

reentrant_cleanup:
  gpui_text_review_reenter_mode = 0;
  gpui_text_review_reentered = FALSE;
#undef GPUI_REENTRANT_REQUIRE
  return result;
}

/* Exercise begin failures and the mixed platform/text pump through the real
 * host entry points and WndProc. The fake APIs replace only OS boundaries. */
static int32_t gpui_text_review_regressions(int32_t *failed_stage) {
  gpui_windows_host *saved_host =
      (gpui_windows_host *)malloc(sizeof(gpui_windows_host));
  if (!saved_host)
    return GPUI_WINDOWS_RESOURCE;
  memcpy(saved_host, &g_host, sizeof(g_host));
  gpui_text_session_state saved_session = g_gpui_text_session;
  gpui_imm_api saved_imm = g_gpui_imm;
  HWND saved_focus_hwnd = gpui_text_review_focus_hwnd;
  LONG saved_claimed = InterlockedCompareExchange(&g_host_claimed, 0, 0);
  InterlockedExchange(&g_host_claimed, 1);
  ZeroMemory(&g_gpui_text_session, sizeof(g_gpui_text_session));
  ZeroMemory(&g_gpui_imm, sizeof(g_gpui_imm));
  gpui_text_review_setup_host();
  g_gpui_imm.module = (HMODULE)(uintptr_t)1;
  g_gpui_imm.get_context = gpui_text_review_get_context;
  g_gpui_imm.release_context = gpui_text_review_release_context;
  g_gpui_imm.associate_context = gpui_text_review_associate_context;
  g_gpui_imm.get_composition_string_w =
      gpui_text_review_get_composition_string;
  g_gpui_imm.set_composition_window =
      gpui_text_review_set_composition_window;
  g_gpui_imm.set_candidate_window = gpui_text_review_set_candidate_window;
  g_gpui_imm.notify_ime = gpui_text_review_notify_ime;
  g_gpui_text_session.epoch_counter = 200;
  int32_t result = GPUI_WINDOWS_OK;
  double event[20];
  uint8_t payload[GPUI_TEXT_MAX_STRING_BYTES + GPUI_TEXT_MAX_ATTRIBUTES];
  const uint8_t ab_text[] = {'a', 'b'};

#define GPUI_REVIEW_REQUIRE(condition, stage)                                \
  do {                                                                         \
    if (!(condition)) {                                                        \
      *failed_stage = (stage);                                                 \
      result = GPUI_WINDOWS_NATIVE;                                            \
      goto review_cleanup;                                                     \
    }                                                                          \
  } while (0)

  for (int32_t failure = 1; failure <= 2; ++failure) {
    gpui_text_review_failed_form = failure;
    int32_t prior_counter = g_gpui_text_session.epoch_counter;
    int32_t begin = gpui_windows_session_begin(
        77, 5, 600 + failure, ab_text, sizeof(ab_text), 2, 2,
        8.0, 9.0, 1.0, 18.0);
    GPUI_REVIEW_REQUIRE(begin == -GPUI_WINDOWS_NATIVE, failure);
    GPUI_REVIEW_REQUIRE(!g_gpui_text_session.armed &&
                            !g_gpui_text_session.suppress_ime_messages &&
                            g_gpui_text_session.window_id == 0 &&
                            g_gpui_text_session.owner_generation == 0 &&
                            g_gpui_text_session.epoch == 0 &&
                            g_gpui_text_session.epoch_counter ==
                                prior_counter + 1 &&
                            g_gpui_text_session.expected_himc == NULL &&
                            g_gpui_text_session.document == NULL,
                        2 + failure);
    int64_t expected_sequence = g_host.sequence + 1;
    gpui_window_proc(g_host.hwnd, WM_CHAR, 'X', 0);
    GPUI_REVIEW_REQUIRE(g_host.event_count == 1 &&
                            !g_host.editor_events[g_host.event_read] &&
                            (int32_t)g_host.events[g_host.event_read][0] ==
                                16 &&
                            (int64_t)g_host.events[g_host.event_read][2] ==
                                expected_sequence,
                        4 + failure);
    gpui_text_test_clear_ring(&g_host);
    gpui_window_proc(g_host.hwnd, WM_UNICHAR, 'Y', 0);
    GPUI_REVIEW_REQUIRE(g_host.event_count == 1 &&
                            !g_host.editor_events[g_host.event_read] &&
                            (int32_t)g_host.events[g_host.event_read][0] ==
                                16,
                        6 + failure);
    gpui_text_test_clear_ring(&g_host);
    LRESULT ime_result = gpui_window_proc(g_host.hwnd, WM_IME_COMPOSITION,
                                          0, GCS_RESULTSTR);
    GPUI_REVIEW_REQUIRE(ime_result == (LRESULT)0x5151 &&
                            gpui_text_review_def_calls == failure,
                        8 + failure);
  }

  gpui_text_review_failed_form = 0;
  int32_t epoch = gpui_windows_session_begin(
      77, 5, 700, ab_text, sizeof(ab_text), 2, 2,
      8.0, 9.0, 1.0, 18.0);
  GPUI_REVIEW_REQUIRE(epoch > 0 && g_gpui_text_session.armed, 11);
  ZeroMemory(&gpui_text_review_messages[0], sizeof(gpui_text_review_messages[0]));
  gpui_text_review_messages[0].hwnd = g_host.hwnd;
  gpui_text_review_messages[0].message = WM_KEYDOWN;
  gpui_text_review_messages[0].wParam = VK_LEFT;
  ZeroMemory(&gpui_text_review_messages[1], sizeof(gpui_text_review_messages[1]));
  gpui_text_review_messages[1].hwnd = g_host.hwnd;
  gpui_text_review_messages[1].message = WM_CHAR;
  gpui_text_review_messages[1].wParam = 'X';
  gpui_text_review_message_count = 2;
  GPUI_REVIEW_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                          g_host.event_count == 1 &&
                          gpui_text_review_message_count == 1 &&
                          !g_host.editor_events[g_host.event_read] &&
                          (int32_t)g_host.events[g_host.event_read][0] == 11 &&
                          (int32_t)g_host.events[g_host.event_read][8] ==
                              0xff51,
                      12);
  GPUI_REVIEW_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                          g_host.event_count == 1 &&
                          gpui_text_review_message_count == 1,
                      13);
  GPUI_REVIEW_REQUIRE(gpui_text_session_pop(&g_host, event, payload,
                                            sizeof(payload)) == 1 &&
                          (int32_t)event[0] == 11 &&
                          (int64_t)event[2] == 1,
                      14);
  int32_t updated_epoch = gpui_windows_session_update(
      77, 5, epoch, 700, ab_text, sizeof(ab_text), 1, 1,
      8.0, 9.0, 1.0, 18.0, 1);
  GPUI_REVIEW_REQUIRE(updated_epoch > epoch &&
                          gpui_text_review_message_count == 1,
                      15);
  WCHAR expected_axb[] = {L'a', L'X', L'b'};
  GPUI_REVIEW_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                          gpui_text_review_message_count == 0 &&
                          g_host.event_count == 1 &&
                          g_host.editor_events[g_host.event_read] &&
                          (int32_t)g_host.events[g_host.event_read][0] ==
                              GPUI_TEXT_EVENT_INSERTED &&
                          (int64_t)g_host.events[g_host.event_read][2] == 2 &&
                          (int32_t)g_host.editor_fields[g_host.event_read][1] ==
                              updated_epoch &&
                          (int32_t)g_host.editor_fields[g_host.event_read][6] ==
                              1 &&
                          (int32_t)g_host.editor_fields[g_host.event_read][7] ==
                              0 &&
                          gpui_text_test_document_is(expected_axb, 3) &&
                          g_gpui_text_session.anchor_utf16 == 2 &&
                          g_gpui_text_session.head_utf16 == 2,
                      16);
  GPUI_REVIEW_REQUIRE(gpui_text_session_pop(&g_host, event, payload,
                                            sizeof(payload)) == 1 &&
                          (int32_t)event[0] == GPUI_TEXT_EVENT_INSERTED &&
                          (int32_t)event[10] == 700 && payload[0] == 'X',
                      17);
  GPUI_REVIEW_REQUIRE(gpui_windows_session_end(77, 5, updated_epoch, 700) ==
                          GPUI_WINDOWS_OK,
                      18);
  ZeroMemory(&gpui_text_review_messages[0], sizeof(gpui_text_review_messages[0]));
  gpui_text_review_messages[0].hwnd = g_host.hwnd;
  gpui_text_review_messages[0].message = WM_KEYDOWN;
  gpui_text_review_messages[0].wParam = VK_LEFT;
  ZeroMemory(&gpui_text_review_messages[1], sizeof(gpui_text_review_messages[1]));
  gpui_text_review_messages[1].hwnd = g_host.hwnd;
  gpui_text_review_messages[1].message = WM_CHAR;
  gpui_text_review_messages[1].wParam = 'Y';
  gpui_text_review_message_count = 2;
  GPUI_REVIEW_REQUIRE(dispatch_messages(&g_host, 0) == GPUI_WINDOWS_OK &&
                          gpui_text_review_message_count == 0 &&
                          g_host.event_count == 2 &&
                          (int32_t)g_host.events[g_host.event_read][0] == 11 &&
                          (int32_t)g_host.events[(g_host.event_read + 1) %
                                                GPUI_EVENT_CAPACITY][0] == 16,
                      19);
  for (int32_t mode = 1; mode <= 2; ++mode) {
    int32_t reentrant_stage =
        gpui_text_review_reentrant_case(mode, mode == 1 ? 20 : 40);
    if (reentrant_stage != 0) {
      *failed_stage = reentrant_stage;
      result = GPUI_WINDOWS_NATIVE;
      goto review_cleanup;
    }
  }

  {
    const uint8_t original[] = {'a', 'b'};
    WCHAR rejected_result[] = {L'X'};
    WCHAR next_result[] = {L'Y'};
    WCHAR rejected_snapshot[] = {L'X'};
    WCHAR restored_snapshot[] = {L'a', L'b'};
    WCHAR next_snapshot[] = {L'Y'};
    gpui_text_test_clear_ring(&g_host);
    int32_t initial_epoch = gpui_windows_session_begin(
        77, 5, 705, original, sizeof(original), 2, 0,
        8.0, 9.0, 1.0, 18.0);
    GPUI_REVIEW_REQUIRE(initial_epoch > 0 &&
                            gpui_text_test_document_is(restored_snapshot, 2) &&
                            g_gpui_text_session.anchor_utf16 == 2 &&
                            g_gpui_text_session.head_utf16 == 0,
                        60);
    GPUI_REVIEW_REQUIRE(gpui_text_session_start_record(&g_host) ==
                            GPUI_WINDOWS_OK &&
                            gpui_text_session_process_composition(
                                &g_host, TRUE, rejected_result, 1, FALSE,
                                NULL, 0, FALSE, 0, NULL, 0) ==
                                GPUI_WINDOWS_OK &&
                            gpui_text_test_document_is(rejected_snapshot, 1) &&
                            g_gpui_text_session.anchor_utf16 == 1 &&
                            g_gpui_text_session.head_utf16 == 1,
                        61);
    GPUI_REVIEW_REQUIRE(gpui_text_session_pop(
                            &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_STARTED &&
                            gpui_text_session_pop(
                                &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_INSERTED &&
                            (int32_t)event[16] == 0 &&
                            (int32_t)event[17] == 2 && payload[0] == 'X',
                        62);

    int32_t cancelled_epoch = gpui_windows_session_cancel(
        77, 5, initial_epoch, 705);
    GPUI_REVIEW_REQUIRE(cancelled_epoch > initial_epoch &&
                            g_gpui_text_session.armed &&
                            gpui_text_test_document_is(rejected_snapshot, 1) &&
                            g_gpui_text_session.anchor_utf16 == 1 &&
                            g_gpui_text_session.head_utf16 == 1,
                        63);

    int32_t rebased_epoch = gpui_windows_session_update(
        77, 5, cancelled_epoch, 705, original, sizeof(original), 2, 0,
        8.0, 9.0, 1.0, 18.0, 1);
    GPUI_REVIEW_REQUIRE(rebased_epoch > cancelled_epoch &&
                            g_gpui_text_session.armed &&
                            g_gpui_text_session.awaiting_fresh_start &&
                            gpui_text_test_document_is(restored_snapshot, 2) &&
                            g_gpui_text_session.anchor_utf16 == 2 &&
                            g_gpui_text_session.head_utf16 == 0,
                        64);
    int32_t next_start_status = gpui_text_session_start_record(&g_host);
    if (next_start_status != GPUI_WINDOWS_OK) {
      *failed_stage = 700 + next_start_status;
      result = GPUI_WINDOWS_NATIVE;
      goto review_cleanup;
    }
    GPUI_REVIEW_REQUIRE(gpui_text_test_record(
                            &g_host, 0, GPUI_TEXT_EVENT_STARTED, 0, 2, 3),
                        651);
    GPUI_REVIEW_REQUIRE((int32_t)g_host.editor_fields[
                            g_host.event_read][1] == rebased_epoch,
                        652);
    GPUI_REVIEW_REQUIRE(gpui_text_session_process_composition(
                            &g_host, TRUE, next_result, 1, FALSE,
                            NULL, 0, FALSE, 0, NULL, 0) == GPUI_WINDOWS_OK &&
                            gpui_text_test_document_is(next_snapshot, 1) &&
                            g_gpui_text_session.anchor_utf16 == 1 &&
                            g_gpui_text_session.head_utf16 == 1 &&
                            gpui_text_test_record(
                                &g_host, 1, GPUI_TEXT_EVENT_INSERTED, 0, 2, 4) &&
                            (int32_t)g_host.editor_fields[
                                (g_host.event_read + 1) % GPUI_EVENT_CAPACITY][1] ==
                                rebased_epoch,
                        66);
    GPUI_REVIEW_REQUIRE(gpui_text_session_pop(
                            &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_STARTED &&
                            gpui_text_session_pop(
                                &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_INSERTED &&
                            (int32_t)event[16] == 0 &&
                            (int32_t)event[17] == 2 && payload[0] == 'Y',
                        67);
    GPUI_REVIEW_REQUIRE(gpui_windows_session_end(
                            77, 5, rebased_epoch, 705) == GPUI_WINDOWS_OK,
                        68);
  }

  {
    const uint8_t original[] = {'a', 'b'};
    WCHAR marked_text[] = {L'X'};
    gpui_text_test_clear_ring(&g_host);
    int32_t focus_epoch = gpui_windows_session_begin(
        77, 5, 706, original, sizeof(original), 1, 2,
        8.0, 9.0, 1.0, 18.0);
    GPUI_REVIEW_REQUIRE(focus_epoch > 0 &&
                            gpui_windows_window_has_keyboard_focus(77, 5) == 1 &&
                            gpui_windows_session_is_current(
                                77, 5, focus_epoch, 706) == 1,
                        70);
    GPUI_REVIEW_REQUIRE(gpui_text_session_start_record(&g_host) ==
                            GPUI_WINDOWS_OK &&
                            gpui_text_session_process_composition(
                                &g_host, FALSE, NULL, 0, TRUE,
                                marked_text, 1, TRUE, 1, NULL, 0) ==
                                GPUI_WINDOWS_OK &&
                            g_gpui_text_session.composing,
                        71);
    GPUI_REVIEW_REQUIRE(gpui_text_session_pop(
                            &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_STARTED &&
                            gpui_text_session_pop(
                                &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_MARKED &&
                            payload[0] == 'X',
                        72);

    /* WM_KILLFOCUS emits the old-epoch Cancelled record before the platform
     * focus event, while GetFocus already reports the new owner. */
    gpui_text_review_focus_hwnd = (HWND)(uintptr_t)2;
    gpui_window_proc(g_host.hwnd, WM_KILLFOCUS, 0, 0);
    int32_t cancel_slot = g_host.event_read;
    int32_t focus_slot = (cancel_slot + 1) % GPUI_EVENT_CAPACITY;
    GPUI_REVIEW_REQUIRE(g_host.event_count == 2 &&
                            gpui_text_session_head_is_editor(&g_host) &&
                            (int32_t)g_host.events[cancel_slot][0] ==
                                GPUI_TEXT_EVENT_CANCELLED &&
                            (int32_t)g_host.editor_fields[cancel_slot][0] ==
                                706 &&
                            (int32_t)g_host.editor_fields[cancel_slot][1] ==
                                focus_epoch &&
                            !g_host.editor_events[focus_slot] &&
                            (int32_t)g_host.events[focus_slot][0] == 6 &&
                            (int32_t)g_host.events[focus_slot][8] == 0,
                        73);
    GPUI_REVIEW_REQUIRE(!g_gpui_text_session.armed &&
                            !g_gpui_text_session.composing &&
                            g_gpui_text_session.epoch > focus_epoch &&
                            gpui_windows_window_has_keyboard_focus(77, 5) == 0 &&
                            gpui_windows_session_is_current(
                                77, 5, focus_epoch, 706) == 0,
                        74);
    GPUI_REVIEW_REQUIRE(gpui_windows_session_update(
                            77, 5, focus_epoch, 706, original,
                            sizeof(original), 1, 2,
                            8.0, 9.0, 1.0, 18.0, 0) ==
                            -GPUI_WINDOWS_STALE,
                        75);
    gpui_text_review_focus_hwnd = g_host.hwnd;
    gpui_window_proc(g_host.hwnd, WM_SETFOCUS, 0, 0);
    GPUI_REVIEW_REQUIRE(
        gpui_windows_window_has_keyboard_focus(77, 5) == 1 &&
            gpui_windows_session_is_current(77, 5, focus_epoch, 706) == 0 &&
            g_host.event_count == 3,
        78);
    GPUI_REVIEW_REQUIRE(gpui_windows_session_end(
                            77, 5, focus_epoch, 706) == GPUI_WINDOWS_OK,
                        79);
    GPUI_REVIEW_REQUIRE(gpui_text_session_pop(
                            &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == GPUI_TEXT_EVENT_CANCELLED &&
                            (int32_t)event[11] == focus_epoch &&
                            gpui_text_session_pop(
                                &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == 6 &&
                            (int32_t)event[8] == 0 &&
                            gpui_text_session_pop(
                                &g_host, event, payload, sizeof(payload)) == 1 &&
                            (int32_t)event[0] == 6 &&
                            (int32_t)event[8] == 1,
                        77);
  }

review_cleanup:
  gpui_text_test_clear_ring(&g_host);
  gpui_text_review_message_count = 0;
  gpui_text_review_reenter_mode = 0;
  gpui_text_review_reentered = FALSE;
  gpui_text_review_focus_hwnd = saved_focus_hwnd;
  free(g_gpui_text_session.document);
  g_gpui_text_session = saved_session;
  g_gpui_imm = saved_imm;
  memcpy(&g_host, saved_host, sizeof(g_host));
  InterlockedExchange(&g_host_claimed, saved_claimed);
  free(saved_host);
#undef GPUI_REVIEW_REQUIRE
  return result;
}

/* Returns OK on pass and writes the numbered failing stage for CI logs. */
int32_t gpui_windows_test_text_session_staging(int32_t *failed_stage) {
  if (!failed_stage)
    return GPUI_WINDOWS_INVALID;
  *failed_stage = 0;
  if (InterlockedCompareExchange(&g_host_claimed, 0, 0) != 0)
    return GPUI_WINDOWS_BUSY;
  gpui_windows_host *host =
      (gpui_windows_host *)calloc(1, sizeof(gpui_windows_host));
  if (!host)
    return GPUI_WINDOWS_RESOURCE;
  gpui_text_session_state saved = g_gpui_text_session;
  gpui_imm_api saved_imm = g_gpui_imm;
  ZeroMemory(&g_gpui_text_session, sizeof(g_gpui_text_session));
  ZeroMemory(&g_gpui_imm, sizeof(g_gpui_imm));
  int32_t result = GPUI_WINDOWS_OK;
  WCHAR empty[] = {0};
  WCHAR original[] = {L'a', L'b', L'X', L'Y', L'c', L'd'};
  WCHAR committed[] = {0x6f22};
  WCHAR marked[] = {0x304b, 0x306a};
  uint8_t attributes[] = {1, 2};
  uint8_t payload[GPUI_TEXT_MAX_STRING_BYTES + GPUI_TEXT_MAX_ATTRIBUTES];
  double event[20];

#define GPUI_TEXT_TEST_REQUIRE(condition, stage)                              \
  do {                                                                         \
    if (!(condition)) {                                                        \
      *failed_stage = (stage);                                                 \
      result = GPUI_WINDOWS_NATIVE;                                            \
      goto cleanup;                                                            \
    }                                                                          \
  } while (0)

  if (!gpui_text_test_init(host, original, 6, 2, 4, 13, 77)) {
    result = GPUI_WINDOWS_RESOURCE;
    goto cleanup;
  }
  host->sequence = 40;
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         1);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, committed, 1, TRUE, marked, 2,
                             TRUE, 1, attributes, 2) == GPUI_WINDOWS_OK,
                         2);
  WCHAR combined_expected[] = {L'a', L'b', 0x6f22, L'c', L'd'};
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_document_is(combined_expected, 5), 3);
  GPUI_TEXT_TEST_REQUIRE(g_gpui_text_session.composing, 4);
  GPUI_TEXT_TEST_REQUIRE(host->event_count == 4 && host->sequence == 44, 5);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_record(
                             host, 0, GPUI_TEXT_EVENT_STARTED, 2, 2, 41),
                         6);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_record(
                             host, 1, GPUI_TEXT_EVENT_INSERTED, 2, 2, 42),
                         7);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_record(
                             host, 2, GPUI_TEXT_EVENT_STARTED, 3, 0, 43),
                         8);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_record(
                             host, 3, GPUI_TEXT_EVENT_MARKED, 3, 0, 44),
                         9);
  GPUI_TEXT_TEST_REQUIRE(host->editor_fields[3][3] == 1.0 &&
                             host->editor_fields[3][4] == 1.0 &&
                             host->editor_fields[3][8] == 2.0,
                         10);
  for (int32_t i = 0; i < 4; ++i) {
    GPUI_TEXT_TEST_REQUIRE(gpui_text_session_pop(host, event, payload,
                                                sizeof(payload)) == 1,
                           11);
    GPUI_TEXT_TEST_REQUIRE((int32_t)event[0] ==
                               (i == 0 ? GPUI_TEXT_EVENT_STARTED
                                : i == 1 ? GPUI_TEXT_EVENT_INSERTED
                                : i == 2 ? GPUI_TEXT_EVENT_STARTED
                                         : GPUI_TEXT_EVENT_MARKED) &&
                               (int64_t)event[2] == 41 + i,
                           12);
  }
  GPUI_TEXT_TEST_REQUIRE(host->event_count == 0, 13);

  WCHAR short_document[] = {L'a', L'b'};
  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, short_document, 2, 1, 1,
                                            21, 88),
                         14);
  g_gpui_text_session.composing = TRUE;
  g_gpui_text_session.awaiting_fresh_start = FALSE;
  g_gpui_text_session.target_start = 1;
  g_gpui_text_session.target_length = 0;
  host->event_count = GPUI_EVENT_CAPACITY - 2;
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, committed, 1, TRUE, marked, 2,
                             TRUE, 1, attributes, 2) == GPUI_WINDOWS_RESOURCE,
                         15);
  GPUI_TEXT_TEST_REQUIRE(host->event_count == GPUI_EVENT_CAPACITY - 2 &&
                             host->sequence == 0 &&
                             host->editor_error == GPUI_WINDOWS_RESOURCE &&
                             gpui_text_test_document_is(short_document, 2),
                         16);

  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, short_document, 2, 1, 1,
                                            31, 89),
                         17);
  g_gpui_text_session.composing = TRUE;
  g_gpui_text_session.awaiting_fresh_start = FALSE;
  g_gpui_text_session.target_start = 1;
  g_gpui_text_session.target_length = 0;
  host->editor_payload_total = GPUI_TEXT_MAX_PENDING_BYTES - 1;
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, committed, 1, TRUE, marked, 2,
                             TRUE, 1, attributes, 2) == GPUI_WINDOWS_RESOURCE,
                         18);
  GPUI_TEXT_TEST_REQUIRE(host->event_count == 0 && host->sequence == 0 &&
                             host->editor_payload_total ==
                                 GPUI_TEXT_MAX_PENDING_BYTES - 1 &&
                             gpui_text_test_document_is(short_document, 2),
                         19);

  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, short_document, 2, 1, 1,
                                            41, 90),
                         20);
  g_gpui_text_session.composing = TRUE;
  g_gpui_text_session.awaiting_fresh_start = FALSE;
  g_gpui_text_session.target_start = 1;
  host->sequence = INT64_C(9007199254740990);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, committed, 1, TRUE, marked, 2,
                             TRUE, 1, attributes, 2) == GPUI_WINDOWS_RESOURCE,
                         21);
  GPUI_TEXT_TEST_REQUIRE(host->event_count == 0 &&
                             host->sequence == INT64_C(9007199254740990) &&
                             gpui_text_test_document_is(short_document, 2),
                         22);

  WCHAR one[] = {L'a'};
  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, one, 1, 1, 1, 91, 92),
                         23);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         23);
  g_gpui_text_session.epoch_counter = INT32_MAX;
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_reserve_cancel_epoch(
                             host, 5, 92, 91) == -GPUI_WINDOWS_RESOURCE &&
                             host->event_count == 1 && host->sequence == 1 &&
                             host->editor_error == GPUI_WINDOWS_RESOURCE &&
                             gpui_text_test_record(
                                 host, 0, GPUI_TEXT_EVENT_STARTED, 1, 0, 1) &&
                             gpui_text_test_document_is(one, 1),
                         23);

  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, one, 1, 1, 1, 51, 91),
                         24);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         25);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, committed, 1, FALSE,
                             NULL, 0, FALSE, 0, NULL, 0) == GPUI_WINDOWS_OK,
                         26);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_end_composition(host) ==
                             GPUI_WINDOWS_OK,
                         27);
  WCHAR result_only_expected[] = {L'a', L'\u6f22'};
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_document_is(result_only_expected, 2) &&
                             !g_gpui_text_session.composing &&
                             host->events[(host->event_read +
                                           host->event_count - 1) %
                                          GPUI_EVENT_CAPACITY][0] ==
                                 GPUI_TEXT_EVENT_ENDED,
                         28);

  WCHAR a[] = {L'a'};
  WCHAR x[] = {L'X'};
  WCHAR y[] = {L'Y'};
  WCHAR z[] = {L'Z'};
  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, a, 1, 1, 1, 61, 92), 29);
  for (int32_t commit = 0; commit < 2; ++commit) {
    GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                               GPUI_WINDOWS_OK,
                           30);
    const WCHAR *text = commit == 0 ? x : y;
    GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                               host, TRUE, text, 1, FALSE, NULL, 0,
                               FALSE, 0, NULL, 0) == GPUI_WINDOWS_OK,
                           31);
    GPUI_TEXT_TEST_REQUIRE(gpui_text_session_end_composition(host) ==
                               GPUI_WINDOWS_OK,
                           32);
  }
  int32_t queued_commits = 0;
  for (int32_t i = 0; i < host->event_count; ++i) {
    int32_t slot = (host->event_read + i) % GPUI_EVENT_CAPACITY;
    queued_commits += host->editor_events[slot] &&
                              (int32_t)host->events[slot][0] ==
                                  GPUI_TEXT_EVENT_INSERTED
                          ? 1
                          : 0;
  }
  GPUI_TEXT_TEST_REQUIRE(queued_commits == 2, 33);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_head_is_editor(host) &&
                             host->event_count > 0,
                         34);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_pop(host, event, payload,
                                              sizeof(payload)) == 1 &&
                             (int32_t)event[0] == GPUI_TEXT_EVENT_STARTED,
                         35);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_pop(host, event, payload,
                                              sizeof(payload)) == 1 &&
                             (int32_t)event[0] == GPUI_TEXT_EVENT_INSERTED &&
                             (int32_t)event[16] == 1 &&
                             (int32_t)event[17] == 0 && payload[0] == 'X',
                         36);
  WCHAR owner_after_first[] = {L'a', L'X'};
  WCHAR expected_after_ack[] = {L'a', L'X', L'Y'};
  WCHAR *owner_snapshot = (WCHAR *)calloc(3, sizeof(WCHAR));
  GPUI_TEXT_TEST_REQUIRE(owner_snapshot != NULL, 37);
  memcpy(owner_snapshot, owner_after_first, sizeof(owner_after_first));
  BOOL deferred = gpui_text_session_ack_snapshot(
      host, 5, 92, 61, owner_snapshot, 2, 2, 2,
      8.0, 9.0, 1.0, 18.0);
  GPUI_TEXT_TEST_REQUIRE(deferred &&
                             gpui_text_test_document_is(
                                 expected_after_ack, 3) &&
                             g_gpui_text_session.anchor_utf16 == 3,
                         38);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         39);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, z, 1, FALSE, NULL, 0,
                             FALSE, 0, NULL, 0) == GPUI_WINDOWS_OK,
                         40);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_end_composition(host) ==
                             GPUI_WINDOWS_OK,
                         41);
  WCHAR axyz[] = {L'a', L'X', L'Y', L'Z'};
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_document_is(axyz, 4), 42);
  int32_t inserted_index = 0;
  int32_t expected_starts[] = {2, 3};
  for (int32_t i = 0; i < host->event_count; ++i) {
    int32_t slot = (host->event_read + i) % GPUI_EVENT_CAPACITY;
    if (host->editor_events[slot] &&
        (int32_t)host->events[slot][0] == GPUI_TEXT_EVENT_INSERTED) {
      GPUI_TEXT_TEST_REQUIRE(inserted_index < 2 &&
                                 (int32_t)host->editor_fields[slot][6] ==
                                     expected_starts[inserted_index] &&
                                 (int32_t)host->editor_fields[slot][7] == 0,
                             43);
      inserted_index++;
    }
  }
  GPUI_TEXT_TEST_REQUIRE(inserted_index == 2, 44);
  while (host->event_count > 0) {
    GPUI_TEXT_TEST_REQUIRE(gpui_text_session_pop(host, event, payload,
                                                sizeof(payload)) == 1,
                           45);
  }

  WCHAR ab[] = {L'a', L'b'};
  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, ab, 2, 1, 2, 71, 93), 46);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         47);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, TRUE, empty, 0, TRUE, empty, 0,
                             TRUE, 0, NULL, 0) == GPUI_WINDOWS_OK,
                         48);
  WCHAR a_only[] = {L'a'};
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_document_is(a_only, 1) &&
                             g_gpui_text_session.composing &&
                             host->event_count == 4 &&
                             gpui_text_test_record(
                                 host, 1, GPUI_TEXT_EVENT_INSERTED, 1, 1, 2) &&
                             (int32_t)host->events[2][0] ==
                                 GPUI_TEXT_EVENT_STARTED &&
                             (int32_t)host->editor_fields[3][2] == 0,
                         49);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_end_composition(host) ==
                             GPUI_WINDOWS_OK &&
                             gpui_text_test_document_is(a_only, 1) &&
                             (int32_t)host->events[4][0] ==
                                 GPUI_TEXT_EVENT_CANCELLED,
                         50);

  WCHAR smile[] = {0xd83d, 0xde00};
  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, one, 1, 1, 1, 81, 94),
                         51);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_start_record(host) ==
                             GPUI_WINDOWS_OK,
                         52);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_process_composition(
                             host, FALSE, NULL, 0, TRUE, smile, 2,
                             TRUE, 1, NULL, 0) == GPUI_WINDOWS_OK &&
                             host->editor_fields[1][3] == 0.0 &&
                             host->editor_fields[1][4] == 0.0,
                         53);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_session_end_composition(host) ==
                             GPUI_WINDOWS_OK,
                         54);

  gpui_text_test_clear_ring(host);
  GPUI_TEXT_TEST_REQUIRE(gpui_text_test_init(host, one, 1, 1, 1, 91, 95),
                         55);
  gpui_text_session_shutdown(host);
  GPUI_TEXT_TEST_REQUIRE(g_gpui_text_session.document == NULL &&
                             g_gpui_text_session.document_units == 0,
                         56);
  GPUI_TEXT_TEST_REQUIRE(
      gpui_text_session_lparam_has_no_gcs_flags(0) &&
          gpui_text_session_lparam_has_no_gcs_flags(CS_INSERTCHAR) &&
          !gpui_text_session_lparam_has_no_gcs_flags(GCS_COMPREADSTR) &&
          !gpui_text_session_lparam_has_no_gcs_flags(GCS_COMPATTR) &&
          !gpui_text_session_lparam_has_no_gcs_flags(GCS_RESULTSTR),
      57);

  {
    int32_t review_stage = 0;
    int32_t review_status = gpui_text_review_regressions(&review_stage);
    if (review_status != GPUI_WINDOWS_OK) {
      *failed_stage = 100 + review_stage;
      result = review_status;
      goto cleanup;
    }
  }

cleanup:
  gpui_text_test_clear_ring(host);
  free(g_gpui_text_session.document);
  g_gpui_text_session = saved;
  g_gpui_imm = saved_imm;
  free(host);
#undef GPUI_TEXT_TEST_REQUIRE
  return result;
}
