#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

/* Keep these values in sync with the production-path E2E fixture in
 * windows/backend_wbtest.mbt. This executable has its own process and HWND. */
static const char expected_gpui_text[] =
    "gpui clipboard 日本語 😀 👩🏽‍💻 é\nsecond line\r\n終わり";
static const char fixture_text[] =
    "fixture clipboard 日本語 😀 👩🏽‍💻\nsecond line\r\n終わり";
static const char lock_text[] = "clipboard lock marker 日本語 🔒\nleave intact";

static WCHAR *utf8_to_wide(const char *text, int *units) {
  int length = (int)strlen(text);
  int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text,
                                     length, NULL, 0);
  if (required <= 0)
    return NULL;
  WCHAR *wide = (WCHAR *)calloc((size_t)required + 1, sizeof(WCHAR));
  if (!wide)
    return NULL;
  if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, length, wide,
                          required) != required) {
    free(wide);
    return NULL;
  }
  *units = required;
  return wide;
}

static BOOL clipboard_open(HWND owner) {
  ULONGLONG deadline = GetTickCount64() + 2000;
  do {
    if (OpenClipboard(owner))
      return TRUE;
    Sleep(1);
  } while (GetTickCount64() < deadline);
  return FALSE;
}

static BOOL clipboard_publish(HWND owner, const char *text,
                              BOOL leave_open) {
  int units = 0;
  WCHAR *wide = utf8_to_wide(text, &units);
  if (!wide)
    return FALSE;
  SIZE_T bytes = ((SIZE_T)units + 1) * sizeof(WCHAR);
  HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
  if (!memory) {
    free(wide);
    return FALSE;
  }
  WCHAR *target = (WCHAR *)GlobalLock(memory);
  if (!target) {
    GlobalFree(memory);
    free(wide);
    return FALSE;
  }
  memcpy(target, wide, bytes);
  GlobalUnlock(memory);
  free(wide);

  if (!clipboard_open(owner)) {
    GlobalFree(memory);
    return FALSE;
  }
  if (!EmptyClipboard()) {
    CloseClipboard();
    GlobalFree(memory);
    return FALSE;
  }
  if (!SetClipboardData(CF_UNICODETEXT, memory)) {
    CloseClipboard();
    GlobalFree(memory);
    return FALSE;
  }
  if (!leave_open)
    CloseClipboard();
  return TRUE;
}

static BOOL clipboard_matches(HWND owner, const char *expected) {
  if (!clipboard_open(owner))
    return FALSE;
  HANDLE handle = GetClipboardData(CF_UNICODETEXT);
  if (!handle) {
    CloseClipboard();
    return FALSE;
  }
  SIZE_T bytes = GlobalSize(handle);
  WCHAR *actual = (WCHAR *)GlobalLock(handle);
  int expected_units = 0;
  WCHAR *wide_expected = utf8_to_wide(expected, &expected_units);
  BOOL matches = FALSE;
  if (actual && wide_expected && bytes >= sizeof(WCHAR) &&
      bytes % sizeof(WCHAR) == 0) {
    SIZE_T capacity = bytes / sizeof(WCHAR);
    SIZE_T actual_units = 0;
    while (actual_units < capacity && actual_units <= 16u * 1024u * 1024u &&
           actual[actual_units] != 0)
      ++actual_units;
    matches = actual_units == (SIZE_T)expected_units &&
              actual_units < capacity &&
              memcmp(actual, wide_expected,
                     actual_units * sizeof(WCHAR)) == 0;
  }
  free(wide_expected);
  if (actual)
    GlobalUnlock(handle);
  CloseClipboard();
  return matches;
}

static BOOL write_line(const char *line) {
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  DWORD written = 0;
  DWORD length = (DWORD)strlen(line);
  return output != INVALID_HANDLE_VALUE &&
         WriteFile(output, line, length, &written, NULL) && written == length;
}

static BOOL read_release(const char *nonce) {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  char line[96];
  size_t used = 0;
  ULONGLONG deadline = GetTickCount64() + 6000;
  for (;;) {
    if (GetTickCount64() >= deadline)
      return FALSE;
    DWORD available = 0;
    if (!PeekNamedPipe(input, NULL, 0, NULL, &available, NULL))
      return FALSE;
    if (available == 0) {
      Sleep(1);
      continue;
    }
    char byte = 0;
    DWORD read = 0;
    if (!ReadFile(input, &byte, 1, &read, NULL) || read != 1)
      return FALSE;
    if (byte == '\n') {
      line[used] = '\0';
      char expected[96];
      _snprintf_s(expected, sizeof(expected), _TRUNCATE, "RELEASE %s", nonce);
      return strcmp(line, expected) == 0;
    }
    if (byte == '\r' || used + 1 >= sizeof(line))
      return FALSE;
    line[used++] = byte;
  }
}

static BOOL nonce_is_valid(const char *nonce) {
  if (!nonce || strlen(nonce) != 16)
    return FALSE;
  for (size_t i = 0; i < 16; ++i) {
    char c = nonce[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
      return FALSE;
  }
  return TRUE;
}

int main(int argc, char **argv) {
  if (argc != 3 || !nonce_is_valid(argv[2]))
    return 2;
  const char *mode = argv[1];
  HWND owner = CreateWindowExW(0, L"STATIC", L"gpui clipboard fixture", 0,
                               0, 0, 0, 0, NULL, NULL,
                               GetModuleHandleW(NULL), NULL);
  if (!owner)
    return 3;

  BOOL hold = strcmp(mode, "hold-lock") == 0;
  BOOL ok = FALSE;
  if (strcmp(mode, "read-gpui") == 0) {
    ok = clipboard_matches(owner, expected_gpui_text);
  } else if (strcmp(mode, "write-fixture") == 0) {
    ok = clipboard_publish(owner, fixture_text, FALSE);
  } else if (hold) {
    ok = clipboard_publish(owner, lock_text, TRUE);
  }
  if (!ok) {
    char failure[96];
    _snprintf_s(failure, sizeof(failure), _TRUNCATE,
                "ERROR %s %lu\n", mode, (unsigned long)GetLastError());
    write_line(failure);
    DestroyWindow(owner);
    return 4;
  }

  char line[128];
  _snprintf_s(line, sizeof(line), _TRUNCATE, "READY %s %lu %s\n", mode,
              (unsigned long)GetCurrentProcessId(), argv[2]);
  if (!write_line(line)) {
    if (hold)
      CloseClipboard();
    DestroyWindow(owner);
    return 5;
  }

  int result = 0;
  if (hold) {
    BOOL released = read_release(argv[2]);
    BOOL closed = CloseClipboard();
    if (!closed) {
      result = 8;
    } else if (!released) {
      result = 6;
    } else {
      _snprintf_s(line, sizeof(line), _TRUNCATE, "DONE hold-lock %lu %s\n",
                  (unsigned long)GetCurrentProcessId(), argv[2]);
      if (!write_line(line))
        result = 7;
    }
  }
  DestroyWindow(owner);
  return result;
}
