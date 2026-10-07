#ifndef GPUI_MACOS_IME_TIMING_H
#define GPUI_MACOS_IME_TIMING_H
// Included only by GPUI_TESTING builds. No event pumping or input mutation.
#include <time.h>
static struct {
  BOOL active;
  unsigned int records, native_pumps, appkit_pumps;
  int64_t dispatch_id;
  double start_ms, down_ms, up_ms, last_pump_ms;
} ime_timing;
static double ime_monotonic_ms(void) {
  struct timespec now;
  if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return 0;
  return now.tv_sec * 1000.0 + now.tv_nsec / 1000000.0;
}
static BOOL ime_timing_enabled(void) {
  const char *value = getenv("GPUI_FIELD_MACOS_IME_TIMING_TRACE");
  return value && strcmp(value, "1") == 0;
}
static void ime_timing_record(NSString *phase) {
  if (!ime_timing.active || ime_timing.records >= 64) return;
  double now = ime_monotonic_ms();
  NSDictionary *record = @{
    @"schema_version": @1, @"phase": phase,
    @"dispatch_id": @(ime_timing.dispatch_id),
    @"monotonic_ms": @(now), @"elapsed_ms": @(now - ime_timing.start_ms),
    @"native_event_pumps": @(ime_timing.native_pumps),
    @"appkit_event_pumps": @(ime_timing.appkit_pumps),
    @"last_pump_elapsed_ms": @(ime_timing.last_pump_ms - ime_timing.start_ms),
    @"return_down_elapsed_ms": ime_timing.down_ms ? @(now - ime_timing.down_ms) : NSNull.null,
    @"return_up_elapsed_ms": ime_timing.up_ms ? @(now - ime_timing.up_ms) : NSNull.null,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  if (!data) return;
  ime_timing.records++;
  fputs("GPUI_MACOS_IME_TIMING ", stderr);
  fwrite(data.bytes, 1, data.length, stderr);
  fputc('\n', stderr); fflush(stderr);
}
static void ime_timing_end(void) {
  ime_timing_record(@"observation_end");
  ime_timing.active = NO;
}
static void ime_timing_begin(int64_t dispatch_id) {
  if (!ime_timing_enabled() || ime_timing.records >= 64) return;
  ime_timing.active = YES;
  ime_timing.dispatch_id = dispatch_id;
  ime_timing.native_pumps = ime_timing.appkit_pumps = 0;
  ime_timing.down_ms = ime_timing.up_ms = 0;
  ime_timing.start_ms = ime_timing.last_pump_ms = ime_monotonic_ms();
  ime_timing_record(@"return_created");
}
static void ime_timing_key(NSEvent *event) {
  if (!ime_timing.active || event.keyCode != 36 || !event.CGEvent ||
      CGEventGetIntegerValueField(event.CGEvent, kCGEventSourceUserData) !=
        (INT64_C(0x4750554900000000) | ime_timing.dispatch_id)) return;
  if (event.type == NSEventTypeKeyDown) {
    ime_timing.down_ms = ime_monotonic_ms();
    ime_timing_record(@"return_down");
  } else if (event.type == NSEventTypeKeyUp) {
    ime_timing.up_ms = ime_monotonic_ms();
    ime_timing_record(@"return_up");
  }
}
#endif
