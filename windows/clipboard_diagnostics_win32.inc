#ifndef GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_WIN32_INC
#define GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_WIN32_INC

/* Set GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_PATH before starting the Moon test
 * process to an absolute, fresh file stem. Events append to <stem>.host.jsonl
 * and <stem>.fixture.jsonl. An absent variable disables diagnostics. */
#define GPUI_CLIPBOARD_DIAG_PATH_CAPACITY 32768
#define GPUI_CLIPBOARD_DIAG_ROLE_HOST 1
#define GPUI_CLIPBOARD_DIAG_ROLE_FIXTURE 2

typedef HWND(WINAPI *gpui_clipboard_diag_get_open_window_fn)(void);
typedef DWORD(WINAPI *gpui_clipboard_diag_get_window_process_fn)(HWND,
                                                                 LPDWORD);

static volatile LONG g_gpui_clipboard_diag_init_state;
static BOOL g_gpui_clipboard_diag_enabled;
static WCHAR g_gpui_clipboard_diag_base[GPUI_CLIPBOARD_DIAG_PATH_CAPACITY];

static BOOL gpui_clipboard_diag_initialize(void) {
  LONG state = InterlockedCompareExchange(&g_gpui_clipboard_diag_init_state, 1,
                                          0);
  if (state == 0) {
    WCHAR configured[GPUI_CLIPBOARD_DIAG_PATH_CAPACITY];
    DWORD length = GetEnvironmentVariableW(
        L"GPUI_WINDOWS_CLIPBOARD_DIAGNOSTICS_PATH", configured,
        (DWORD)(sizeof(configured) / sizeof(configured[0])));
    if (length > 0 &&
        length < sizeof(configured) / sizeof(configured[0])) {
      WCHAR absolute[GPUI_CLIPBOARD_DIAG_PATH_CAPACITY];
      DWORD absolute_length = GetFullPathNameW(
          configured, (DWORD)(sizeof(absolute) / sizeof(absolute[0])),
          absolute, NULL);
      if (absolute_length > 0 &&
          absolute_length < sizeof(absolute) / sizeof(absolute[0]) &&
          absolute_length + 16 <
              sizeof(g_gpui_clipboard_diag_base) /
                  sizeof(g_gpui_clipboard_diag_base[0]) &&
          wcscpy_s(g_gpui_clipboard_diag_base,
                   sizeof(g_gpui_clipboard_diag_base) /
                       sizeof(g_gpui_clipboard_diag_base[0]),
                   absolute) == 0)
        g_gpui_clipboard_diag_enabled = TRUE;
    }
    InterlockedExchange(&g_gpui_clipboard_diag_init_state, 2);
    return g_gpui_clipboard_diag_enabled;
  }
  while (state == 1) {
    SwitchToThread();
    state = InterlockedCompareExchange(&g_gpui_clipboard_diag_init_state, 2,
                                       2);
  }
  return g_gpui_clipboard_diag_enabled;
}

static BOOL gpui_clipboard_diag_is_enabled(void) {
  if (InterlockedCompareExchange(&g_gpui_clipboard_diag_init_state, 2, 2) != 2)
    return gpui_clipboard_diag_initialize();
  return g_gpui_clipboard_diag_enabled;
}

static void gpui_clipboard_diag_emit(int role,
                                     gpui_clipboard_diag_record *record) {
  if (!gpui_clipboard_diag_is_enabled() || !record)
    return;
  const WCHAR *suffix = role == GPUI_CLIPBOARD_DIAG_ROLE_HOST
                            ? L".host.jsonl"
                            : L".fixture.jsonl";
  WCHAR path[GPUI_CLIPBOARD_DIAG_PATH_CAPACITY];
  if (_snwprintf_s(path, sizeof(path) / sizeof(path[0]), _TRUNCATE, L"%s%s",
                   g_gpui_clipboard_diag_base, suffix) < 0)
    return;
  char line[1024];
  int count = gpui_clipboard_diag_format(line, sizeof(line), record);
  if (count < 0 || (size_t)count + 2 >= sizeof(line))
    return;
  line[count++] = '\r';
  line[count++] = '\n';
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, NULL,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
  if (file == INVALID_HANDLE_VALUE)
    return;
  DWORD written = 0;
  WriteFile(file, line, (DWORD)count, &written, NULL);
  CloseHandle(file);
}

static uint32_t gpui_clipboard_diag_get_last_error(void *context) {
  (void)context;
  return (uint32_t)GetLastError();
}

static void gpui_clipboard_diag_fill_actor(gpui_clipboard_diag_record *record,
                                           HWND caller) {
  record->tick_ms = (uint64_t)GetTickCount64();
  record->caller_hwnd = (uint64_t)(uintptr_t)caller;
  record->caller_pid = (uint32_t)GetCurrentProcessId();
  record->caller_tid = (uint32_t)GetCurrentThreadId();
}

static void gpui_clipboard_diag_fill_opener(
    gpui_clipboard_diag_record *record,
    gpui_clipboard_diag_get_open_window_fn get_open_window,
    gpui_clipboard_diag_get_window_process_fn get_window_process) {
  if (!get_open_window)
    return;
  HWND opener = get_open_window();
  record->open_snapshot_valid = TRUE;
  record->open_hwnd = (uint64_t)(uintptr_t)opener;
  if (opener && get_window_process) {
    DWORD process_id = 0;
    record->open_tid = (uint32_t)get_window_process(opener, &process_id);
    record->open_pid = (uint32_t)process_id;
    record->open_identity_valid = record->open_tid != 0;
  }
}

static void gpui_clipboard_diag_set_close_record(
    gpui_clipboard_diag_record *record, const char *role,
    const char *stage, HWND caller, BOOL closed, DWORD error) {
  record->role = role;
  record->event = "clipboard_close";
  record->stage = stage;
  record->api = "CloseClipboard";
  record->result = closed ? "success" : "failure";
  record->error_valid = !closed;
  record->error = error;
  gpui_clipboard_diag_fill_actor(record, caller);
}

#endif
