#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <sys/select.h>
#include <unistd.h>

void gpui_macos_field_flush_stdout(void);
int32_t gpui_macos_field_wait_command(void);

void gpui_macos_field_flush_stdout(void) { (void)fflush(stdout); }

int32_t gpui_macos_field_wait_command(void) {
  char line[32];
  if (!fgets(line, sizeof(line), stdin)) return 0;
  if (strcmp(line, "begin\n") == 0 || strcmp(line, "begin\r\n") == 0) return 1;
  if (strcmp(line, "quit\n") == 0 || strcmp(line, "quit\r\n") == 0) return 2;
  if (strcmp(line, "preview\n") == 0 || strcmp(line, "preview\r\n") == 0) return 3;
  if (strcmp(line, "abort\n") == 0 || strcmp(line, "abort\r\n") == 0) return 4;
  return -1;
}

int32_t gpui_macos_field_poll_abort(void) {
  fd_set readable;
  FD_ZERO(&readable);
  FD_SET(STDIN_FILENO, &readable);
  struct timeval timeout = {0, 0};
  int ready = select(STDIN_FILENO + 1, &readable, NULL, NULL, &timeout);
  if (ready <= 0 || !FD_ISSET(STDIN_FILENO, &readable)) return 0;
  char line[32];
  if (!fgets(line, sizeof(line), stdin)) return 0;
  return strcmp(line, "abort\n") == 0 || strcmp(line, "abort\r\n") == 0;
}
