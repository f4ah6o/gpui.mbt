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
         (int32_t)host->editor_fields[slot][0] ==
             g_gpui_text_session.owner_generation &&
         (int32_t)host->editor_fields[slot][1] == g_gpui_text_session.epoch &&
         (int32_t)host->editor_fields[slot][5] == 1 &&
         (int32_t)host->editor_fields[slot][6] == start &&
         (int32_t)host->editor_fields[slot][7] == length;
}

/* Returns OK on pass and writes the numbered failing stage for CI logs. */
int32_t gpui_windows_test_text_session_staging(int32_t *failed_stage) {
  if (!failed_stage)
    return GPUI_WINDOWS_INVALID;
  *failed_stage = 0;
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

cleanup:
  gpui_text_test_clear_ring(host);
  free(g_gpui_text_session.document);
  g_gpui_text_session = saved;
  g_gpui_imm = saved_imm;
  free(host);
#undef GPUI_TEXT_TEST_REQUIRE
  return result;
}
