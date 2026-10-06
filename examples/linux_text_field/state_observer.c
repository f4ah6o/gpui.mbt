#include <stdio.h>

void gpui_field_state_flush_stdout(void);

void gpui_field_state_flush_stdout(void) { (void)fflush(stdout); }
