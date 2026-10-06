/* Independent Win32-process clipboard probes. The child is a separately
 * compiled fixture, launched by absolute path without a shell. */
#define GPUI_CLIPBOARD_FIXTURE_TIMEOUT_MS 5000
#define GPUI_CLIPBOARD_FIXTURE_TERMINATE_MS 3000
#define GPUI_CLIPBOARD_FIXTURE_EXPIRY_MS 9000

#include <stdio.h>

typedef struct gpui_clipboard_fixture_process {
  PROCESS_INFORMATION process;
  HANDLE stdin_write;
  HANDLE stdout_read;
  HANDLE job;
  char nonce[17];
  BOOL active;
} gpui_clipboard_fixture_process;

static gpui_clipboard_fixture_process g_clipboard_fixture_process;
static volatile LONG64 g_clipboard_fixture_nonce;

static BOOL clipboard_fixture_path(WCHAR *path, DWORD capacity) {
  DWORD length = GetEnvironmentVariableW(L"GPUI_WINDOWS_CLIPBOARD_FIXTURE",
                                         path, capacity);
  if (length == 0 || length >= capacity)
    return FALSE;
  WCHAR absolute[MAX_PATH * 4];
  DWORD absolute_length =
      GetFullPathNameW(path, (DWORD)(sizeof(absolute) / sizeof(absolute[0])),
                       absolute, NULL);
  if (absolute_length == 0 ||
      absolute_length >= sizeof(absolute) / sizeof(absolute[0]))
    return FALSE;
  if (GetFileAttributesW(absolute) == INVALID_FILE_ATTRIBUTES)
    return FALSE;
  if (wcslen(absolute) + 1 > capacity)
    return FALSE;
  wcscpy_s(path, capacity, absolute);
  return TRUE;
}

static BOOL clipboard_fixture_process_image_is(HANDLE process,
                                                const WCHAR *expected_path) {
  WCHAR image[MAX_PATH * 4];
  DWORD length = (DWORD)(sizeof(image) / sizeof(image[0]));
  if (!QueryFullProcessImageNameW(process, 0, image, &length))
    return FALSE;
  image[length] = L'\0';
  return _wcsicmp(image, expected_path) == 0;
}

static BOOL clipboard_fixture_cleanup(gpui_clipboard_fixture_process *child,
                                      BOOL terminate) {
  BOOL reaped = TRUE;
  if (child->process.hProcess) {
    DWORD state = WaitForSingleObject(child->process.hProcess, 0);
    if (state == WAIT_TIMEOUT && terminate) {
      if (!TerminateProcess(child->process.hProcess, 0xe0)) {
        DWORD error = GetLastError();
        if (error != ERROR_ACCESS_DENIED)
          reaped = FALSE;
      }
      state = WaitForSingleObject(child->process.hProcess,
                                  GPUI_CLIPBOARD_FIXTURE_TERMINATE_MS);
      if (state != WAIT_OBJECT_0 && child->job) {
        TerminateJobObject(child->job, 0xe1);
        CloseHandle(child->job);
        child->job = NULL;
        state = WaitForSingleObject(child->process.hProcess,
                                    GPUI_CLIPBOARD_FIXTURE_TERMINATE_MS);
      }
    }
    if (state != WAIT_OBJECT_0)
      reaped = FALSE;
  }
  if (child->stdin_write)
    CloseHandle(child->stdin_write);
  if (child->stdout_read)
    CloseHandle(child->stdout_read);
  if (child->process.hThread)
    CloseHandle(child->process.hThread);
  if (child->process.hProcess)
    CloseHandle(child->process.hProcess);
  if (child->job)
    CloseHandle(child->job);
  memset(child, 0, sizeof(*child));
  return reaped;
}

static BOOL clipboard_fixture_spawn(const WCHAR *mode,
                                    gpui_clipboard_fixture_process *child) {
  ZeroMemory(child, sizeof(*child));
  WCHAR image_path[MAX_PATH * 4];
  if (!clipboard_fixture_path(image_path,
                              (DWORD)(sizeof(image_path) / sizeof(WCHAR))))
    return FALSE;

  SECURITY_ATTRIBUTES security = {sizeof(SECURITY_ATTRIBUTES), NULL, TRUE};
  HANDLE child_stdin = NULL;
  HANDLE parent_stdin = NULL;
  HANDLE parent_stdout = NULL;
  HANDLE child_stdout = NULL;
  BOOL ok = CreatePipe(&child_stdin, &parent_stdin, &security, 0) &&
            CreatePipe(&parent_stdout, &child_stdout, &security, 0);
  if (!ok)
    goto fail;
  if (!SetHandleInformation(parent_stdin, HANDLE_FLAG_INHERIT, 0) ||
      !SetHandleInformation(parent_stdout, HANDLE_FLAG_INHERIT, 0))
    goto fail;

  child->job = CreateJobObjectW(NULL, NULL);
  if (!child->job)
    goto fail;
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION job_limits;
  ZeroMemory(&job_limits, sizeof(job_limits));
  job_limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(child->job, JobObjectExtendedLimitInformation,
                               &job_limits, sizeof(job_limits)))
    goto fail;

  WCHAR nonce[17];
  ULONGLONG nonce_value =
      (GetTickCount64() << 19) ^ (ULONGLONG)GetCurrentProcessId() ^
      (ULONGLONG)InterlockedIncrement64(&g_clipboard_fixture_nonce);
  if (_snwprintf_s(nonce, sizeof(nonce) / sizeof(nonce[0]), _TRUNCATE,
                   L"%016llx", nonce_value) < 0)
    goto fail;
  for (int32_t i = 0; i < 16; ++i)
    child->nonce[i] = (char)nonce[i];
  child->nonce[16] = '\0';

  WCHAR command_line[32768];
  if (_snwprintf_s(command_line, sizeof(command_line) / sizeof(command_line[0]),
                   _TRUNCATE, L"\"%s\" %s %s", image_path, mode, nonce) < 0)
    goto fail;

  HANDLE inherited_handles[2] = {child_stdin, child_stdout};
  SIZE_T attribute_bytes = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_bytes);
  if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || attribute_bytes == 0)
    goto fail;
  LPPROC_THREAD_ATTRIBUTE_LIST attributes =
      (LPPROC_THREAD_ATTRIBUTE_LIST)HeapAlloc(GetProcessHeap(), 0,
                                               attribute_bytes);
  if (!attributes)
    goto fail;
  BOOL initialized = InitializeProcThreadAttributeList(
      attributes, 1, 0, &attribute_bytes);
  BOOL updated = initialized && UpdateProcThreadAttribute(
                                    attributes, 0,
                                    PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
                                    inherited_handles,
                                    sizeof(inherited_handles), NULL, NULL);
  if (!updated) {
    if (initialized)
      DeleteProcThreadAttributeList(attributes);
    HeapFree(GetProcessHeap(), 0, attributes);
    goto fail;
  }

  STARTUPINFOEXW startup;
  ZeroMemory(&startup, sizeof(startup));
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = child_stdin;
  startup.StartupInfo.hStdOutput = child_stdout;
  startup.StartupInfo.hStdError = child_stdout;
  startup.lpAttributeList = attributes;
  BOOL created = CreateProcessW(
      image_path, command_line, NULL, NULL, TRUE,
      CREATE_NO_WINDOW | CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
      NULL, NULL, &startup.StartupInfo, &child->process);
  DeleteProcThreadAttributeList(attributes);
  HeapFree(GetProcessHeap(), 0, attributes);
  if (!created)
    goto fail;
  CloseHandle(child_stdin);
  child_stdin = NULL;
  CloseHandle(child_stdout);
  child_stdout = NULL;
  child->stdin_write = parent_stdin;
  child->stdout_read = parent_stdout;
  parent_stdin = NULL;
  parent_stdout = NULL;

  if (!AssignProcessToJobObject(child->job, child->process.hProcess) ||
      ResumeThread(child->process.hThread) == (DWORD)-1 ||
      !clipboard_fixture_process_image_is(child->process.hProcess,
                                          image_path))
    goto fail_child;
  child->active = TRUE;
  return TRUE;

fail_child:
  clipboard_fixture_cleanup(child, TRUE);
  child_stdin = NULL;
  child_stdout = NULL;
  parent_stdin = NULL;
  parent_stdout = NULL;
  return FALSE;

fail:
  if (child_stdin)
    CloseHandle(child_stdin);
  if (parent_stdin)
    CloseHandle(parent_stdin);
  if (parent_stdout)
    CloseHandle(parent_stdout);
  if (child_stdout)
    CloseHandle(child_stdout);
  if (child->job)
    CloseHandle(child->job);
  memset(child, 0, sizeof(*child));
  return FALSE;
}

static BOOL clipboard_fixture_read_line(
    gpui_clipboard_fixture_process *child, char *line, size_t capacity,
    DWORD timeout_ms) {
  size_t used = 0;
  ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    /* EmptyClipboard can synchronously notify this thread's current clipboard
     * owner. Service sent messages while waiting so that independent writer
     * processes cannot deadlock against the test's HWND thread. PM_NOREMOVE
     * leaves ordinary queued application input for the normal host pump. */
    MSG message;
    g_host.api.peek_message_w(&message, NULL, 0, 0, PM_NOREMOVE);
    DWORD available = 0;
    if (!PeekNamedPipe(child->stdout_read, NULL, 0, NULL, &available, NULL))
      return FALSE;
    if (available > 0) {
      char byte = '\0';
      DWORD read = 0;
      if (!ReadFile(child->stdout_read, &byte, 1, &read, NULL) || read != 1)
        return FALSE;
      if (byte == '\n') {
        line[used] = '\0';
        return TRUE;
      }
      if (byte == '\r' || used + 1 >= capacity)
        return FALSE;
      line[used++] = byte;
      continue;
    }
    if (WaitForSingleObject(child->process.hProcess, 0) == WAIT_OBJECT_0 ||
        GetTickCount64() >= deadline)
      return FALSE;
    Sleep(1);
  }
}

static BOOL clipboard_fixture_handshake(
    gpui_clipboard_fixture_process *child, const char *mode) {
  char line[160];
  char expected[160];
  if (!clipboard_fixture_read_line(child, line, sizeof(line),
                                   GPUI_CLIPBOARD_FIXTURE_TIMEOUT_MS))
    return FALSE;
  int count = _snprintf_s(expected, sizeof(expected), _TRUNCATE,
                          "READY %s %lu %s", mode,
                          (unsigned long)child->process.dwProcessId,
                          child->nonce);
  return count >= 0 && strcmp(line, expected) == 0;
}

static BOOL clipboard_fixture_wait_success(
    gpui_clipboard_fixture_process *child) {
  if (WaitForSingleObject(child->process.hProcess,
                          GPUI_CLIPBOARD_FIXTURE_TIMEOUT_MS) != WAIT_OBJECT_0)
    return FALSE;
  DWORD exit_code = 0;
  return GetExitCodeProcess(child->process.hProcess, &exit_code) &&
         exit_code == 0;
}

static BOOL clipboard_fixture_wait_exit_code(
    gpui_clipboard_fixture_process *child, DWORD timeout_ms,
    DWORD expected_exit_code) {
  ULONGLONG deadline = GetTickCount64() + timeout_ms;
  for (;;) {
    DWORD state = WaitForSingleObject(child->process.hProcess, 0);
    if (state == WAIT_OBJECT_0) {
      DWORD exit_code = 0;
      return GetExitCodeProcess(child->process.hProcess, &exit_code) &&
             exit_code == expected_exit_code;
    }
    if (state == WAIT_FAILED || GetTickCount64() >= deadline)
      return FALSE;
    MSG message;
    g_host.api.peek_message_w(&message, NULL, 0, 0, PM_NOREMOVE);
    Sleep(1);
  }
}

static int32_t clipboard_fixture_run(const WCHAR *mode_wide,
                                     const char *mode_ascii) {
  gpui_clipboard_fixture_process child;
  if (!clipboard_fixture_spawn(mode_wide, &child)) {
    fprintf(stderr, "clipboard fixture %s failed to launch (%lu).\n",
            mode_ascii, (unsigned long)GetLastError());
    return GPUI_WINDOWS_RESOURCE;
  }
  char line[160];
  BOOL has_handshake = clipboard_fixture_read_line(
      &child, line, sizeof(line), GPUI_CLIPBOARD_FIXTURE_TIMEOUT_MS);
  char expected[160];
  int expected_length = _snprintf_s(
      expected, sizeof(expected), _TRUNCATE, "READY %s %lu %s", mode_ascii,
      (unsigned long)child.process.dwProcessId, child.nonce);
  BOOL handshake_matches = has_handshake && expected_length >= 0 &&
                           strcmp(line, expected) == 0;
  BOOL exited_successfully =
      handshake_matches && clipboard_fixture_wait_success(&child);
  if (!handshake_matches) {
    DWORD exit_code = STILL_ACTIVE;
    GetExitCodeProcess(child.process.hProcess, &exit_code);
    fprintf(stderr, "clipboard fixture %s handshake failed: %s\n", mode_ascii,
            has_handshake ? line : "timeout or closed pipe");
    fprintf(stderr, "clipboard fixture %s process exit status: %lu.\n",
            mode_ascii, (unsigned long)exit_code);
  } else if (!exited_successfully) {
    DWORD exit_code = 0;
    GetExitCodeProcess(child.process.hProcess, &exit_code);
    fprintf(stderr, "clipboard fixture %s did not exit successfully (%lu).\n",
            mode_ascii, (unsigned long)exit_code);
  }
  BOOL ok = handshake_matches && exited_successfully;
  BOOL reaped = clipboard_fixture_cleanup(&child, !ok);
  if (!reaped)
    return GPUI_WINDOWS_NATIVE;
  if (!handshake_matches)
    return GPUI_WINDOWS_CONVERSION;
  if (!exited_successfully)
    return GPUI_WINDOWS_INVALID;
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_test_clipboard_fixture_read(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return clipboard_fixture_run(L"read-gpui", "read-gpui");
}

int32_t gpui_windows_test_clipboard_fixture_write(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  return clipboard_fixture_run(L"write-fixture", "write-fixture");
}

int32_t gpui_windows_test_clipboard_fixture_lock_start(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  if (g_clipboard_fixture_process.active)
    return GPUI_WINDOWS_BUSY;
  if (!clipboard_fixture_spawn(L"hold-lock", &g_clipboard_fixture_process))
    return GPUI_WINDOWS_NATIVE;
  if (!clipboard_fixture_handshake(&g_clipboard_fixture_process, "hold-lock")) {
    clipboard_fixture_cleanup(&g_clipboard_fixture_process, TRUE);
    return GPUI_WINDOWS_NATIVE;
  }
  return GPUI_WINDOWS_OK;
}

int32_t gpui_windows_test_clipboard_fixture_lock_stop(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  gpui_clipboard_fixture_process *child = &g_clipboard_fixture_process;
  if (!child->active)
    return GPUI_WINDOWS_STALE;
  char release[32];
  int release_length = _snprintf_s(release, sizeof(release), _TRUNCATE,
                                   "RELEASE %s\n", child->nonce);
  DWORD written = 0;
  BOOL sent = release_length >= 0 &&
              WriteFile(child->stdin_write, release, (DWORD)release_length,
                        &written, NULL) &&
              written == (DWORD)release_length;
  char line[160];
  char expected[160];
  int expected_length = _snprintf_s(
      expected, sizeof(expected), _TRUNCATE, "DONE hold-lock %lu %s",
      (unsigned long)child->process.dwProcessId, child->nonce);
  BOOL completed = sent && expected_length >= 0 &&
                   clipboard_fixture_read_line(
                       child, line, sizeof(line),
                       GPUI_CLIPBOARD_FIXTURE_TIMEOUT_MS) &&
                   strcmp(line, expected) == 0 &&
                   clipboard_fixture_wait_success(child);
  if (!clipboard_fixture_cleanup(child, !completed))
    completed = FALSE;
  return completed ? GPUI_WINDOWS_OK : GPUI_WINDOWS_NATIVE;
}

int32_t gpui_windows_test_clipboard_fixture_expiry(int32_t token) {
  int32_t status = check_host(token, TRUE);
  if (status != GPUI_WINDOWS_OK)
    return status;
  gpui_clipboard_fixture_process child;
  if (!clipboard_fixture_spawn(L"hold-lock", &child))
    return GPUI_WINDOWS_NATIVE;
  BOOL handshake = clipboard_fixture_handshake(&child, "hold-lock");
  BOOL expired = handshake && clipboard_fixture_wait_exit_code(
                                  &child, GPUI_CLIPBOARD_FIXTURE_EXPIRY_MS, 6);
  BOOL reaped = clipboard_fixture_cleanup(&child, !expired);
  return handshake && expired && reaped ? GPUI_WINDOWS_OK
                                         : GPUI_WINDOWS_NATIVE;
}
