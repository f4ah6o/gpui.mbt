#include <stdio.h>

void gpui_windows_palette_flush_stdout(void) {
  (void)fflush(stdout);
}
