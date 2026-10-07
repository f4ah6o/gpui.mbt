// Headless test: timing must be opt-in, fenced to the tagged Return, and bounded.
#import <AppKit/AppKit.h>
#include <stdint.h>
#include <assert.h>
#include "../../platform/macos/ime_timing.h"
int main(void) {
  @autoreleasepool {
    unsetenv("GPUI_FIELD_MACOS_IME_TIMING_TRACE");
    ime_timing_begin(9);
    assert(!ime_timing.active && ime_timing.records == 0);
    setenv("GPUI_FIELD_MACOS_IME_TIMING_TRACE", "1", 1);
    ime_timing_begin(9);
    assert(ime_timing.active && ime_timing.records == 1);
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, 36, true);
    assert(down);
    // An ordinary key must not masquerade as the tagged Return in the trace.
    ime_timing_key([NSEvent eventWithCGEvent:down]);
    assert(ime_timing.down_ms == 0 && ime_timing.records == 1);
    CGEventSetIntegerValueField(down, kCGEventSourceUserData, INT64_C(0x4750554900000009));
    ime_timing_key([NSEvent eventWithCGEvent:down]);
    assert(ime_timing.down_ms >= ime_timing.start_ms && ime_timing.records == 2);
    CGEventSetType(down, kCGEventKeyUp);
    ime_timing_key([NSEvent eventWithCGEvent:down]);
    assert(ime_timing.up_ms >= ime_timing.down_ms && ime_timing.records == 3);
    CFRelease(down);
    for (int i=0; i<100; i++) ime_timing_record(@"insert_text");
    assert(ime_timing.records == 64);
    ime_timing_end();
    assert(!ime_timing.active && ime_timing.records == 64);
    ime_timing_begin(10);
    assert(!ime_timing.active && ime_timing.records == 64);
  }
  return 0;
}
