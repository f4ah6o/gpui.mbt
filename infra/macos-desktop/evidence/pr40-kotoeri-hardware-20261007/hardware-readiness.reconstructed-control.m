// Minimal standard-control diagnostic. Opt-in, app-owned input, no direct text callbacks.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#include <unistd.h>
// Fixture-only observability. No keyboard events or IME callbacks are generated
// by --physical. A human must confirm hardware provenance separately.
static struct {
  BOOL enabled, physical, valid, return_seen;
  unsigned int records, next_down, next_up, return_downs, return_ups;
  unsigned int native_pumps, appkit_pumps, start_native, start_appkit;
  unsigned int insert_baseline, unmark_baseline;
  double start_ms, down_ms, up_ms;
} control_trace;
static NSTextInputContext *control_expected_context;
@interface KotoeriControl : NSTextView
@property unsigned int downs, ups, inserts, unmarks, marks;
@end
static void control_record(KotoeriControl *view, NSString *phase, NSEvent *event) {
  if (!control_trace.enabled || control_trace.records >= 192) return;
  double now = ime_monotonic_ms();
  NSTextInputContext *context = view.inputContext;
  NSRange marked = view.markedRange;
  NSString *text = view.string;
  NSString *committed = text;
  if (view.hasMarkedText && marked.location != NSNotFound && NSMaxRange(marked) <= text.length)
    committed = [text stringByReplacingCharactersInRange:marked withString:@""];
  NSMutableDictionary *record = [@{
    @"schema_version":@1, @"phase":phase, @"pid":@(getpid()),
    @"window_number":@(view.window.windowNumber), @"window_title":view.window.title ?: @"",
    @"executable":NSProcessInfo.processInfo.arguments.firstObject ?: @"",
    @"producer":control_trace.physical ? @"human_keyboard_requested" : @"app_local",
    @"hardware_provenance_verified":@NO,
    @"monotonic_ms":@(now), @"elapsed_ms":@(now-control_trace.start_ms),
    @"return_down_elapsed_ms":control_trace.down_ms ? @(now-control_trace.down_ms) : NSNull.null,
    @"return_up_elapsed_ms":control_trace.up_ms ? @(now-control_trace.up_ms) : NSNull.null,
    @"native_event_pumps":@(control_trace.native_pumps),
    @"appkit_event_pumps":@(control_trace.appkit_pumps),
    @"selected_input_source":context.selectedKeyboardInputSource ?: NSNull.null,
    @"application_active":@(NSApp.active), @"key_window":@(view.window.keyWindow),
    @"first_responder_is_view":@(view.window.firstResponder == view),
    @"first_responder_class":NSStringFromClass([view.window.firstResponder class]) ?: @"",
    @"current_input_context_is_view":@(NSTextInputContext.currentInputContext == context),
    @"input_context_unchanged":@(context == control_expected_context),
    @"frontmost_pid":@(NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier),
    @"has_marked_text":@(view.hasMarkedText), @"marked_range":NSStringFromRange(marked),
    @"selected_range":NSStringFromRange(view.selectedRange),
    @"text":[text substringToIndex:MIN(text.length,64)],
    @"committed_text":[committed substringToIndex:MIN(committed.length,64)],
    @"insert_text_count":@(view.inserts), @"set_marked_text_count":@(view.marks),
    @"unmark_text_count":@(view.unmarks),
  } mutableCopy];
  if (event) {
    record[@"event_type"]=@(event.type); record[@"key_code"]=@(event.keyCode);
    record[@"event_timestamp_seconds"]=@(event.timestamp);
    record[@"modifier_flags"]=@(event.modifierFlags);
    record[@"event_window_number"]=@(event.windowNumber);
    record[@"is_repeat"]=@(event.type == NSEventTypeKeyDown && event.isARepeat);
    if (event.CGEvent) {
      record[@"cg_timestamp_ns"]=@(CGEventGetTimestamp(event.CGEvent));
      record[@"cg_source_pid"]=@(CGEventGetIntegerValueField(event.CGEvent,kCGEventSourceUnixProcessID));
      record[@"cg_source_state"]=@(CGEventGetIntegerValueField(event.CGEvent,kCGEventSourceStateID));
      record[@"cg_user_data"]=@(CGEventGetIntegerValueField(event.CGEvent,kCGEventSourceUserData));
      record[@"cg_keyboard_type"]=@(CGEventGetIntegerValueField(event.CGEvent,kCGKeyboardEventKeyboardType));
    }
  }
  NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  if (!data) return;
  control_trace.records++;
  fputs("GPUI_KOTOERI_CONTROL ",stderr); fwrite(data.bytes,1,data.length,stderr);
  fputc('\n',stderr); fflush(stderr);
}
@implementation KotoeriControl
- (void)keyDown:(NSEvent *)event {
  self.downs++; ime_timing_key(event); control_record(self,@"view_key_down",event);
  [super keyDown:event]; control_record(self,@"view_key_down_complete",event);
}
- (void)keyUp:(NSEvent *)event {
  self.ups++; ime_timing_key(event); control_record(self,@"view_key_up",event);
  [super keyUp:event]; control_record(self,@"view_key_up_complete",event);
}
- (void)insertText:(id)value replacementRange:(NSRange)range {
  self.inserts++; ime_timing_record(@"insert_text"); control_record(self,@"insert_text",nil);
  [super insertText:value replacementRange:range]; control_record(self,@"insert_text_complete",nil);
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)range {
  self.marks++; ime_timing_record(@"set_marked_text");
  control_record(self,@"set_marked_text",nil);
  [super setMarkedText:value selectedRange:selection replacementRange:range];
  control_record(self,@"set_marked_text_complete",nil);
}
- (void)unmarkText {
  self.unmarks++; ime_timing_record(@"unmark_text"); control_record(self,@"unmark_text",nil);
  [super unmarkText]; control_record(self,@"unmark_text_complete",nil);
}
- (void)doCommandBySelector:(SEL)selector {
  control_record(self,[@"do_command:" stringByAppendingString:NSStringFromSelector(selector)],nil);
  [super doCommandBySelector:selector];
}
@end
static BOOL pump_control(void) {
  control_trace.native_pumps++;
  if (!events.count) control_trace.appkit_pumps++;
  return pump_native_event(16) == 0;
}
int main(int argc, const char **argv) {
  const char *opt = getenv("GPUI_FIELD_MACOS_KOTOERI_CONTROL");
  BOOL local = argc == 2 && strcmp(argv[1], "--local") == 0;
  BOOL physical = argc == 2 && strcmp(argv[1], "--physical") == 0;
  const char *trace = getenv("GPUI_FIELD_MACOS_KOTOERI_CONTROL_TRACE");
  control_trace.enabled = trace && strcmp(trace,"1") == 0;
  control_trace.physical = physical; control_trace.valid = YES;
  control_trace.start_ms = ime_monotonic_ms();
  if (!opt || strcmp(opt, "1") || (!local && !physical) || (physical && !control_trace.enabled)) return 2;
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    [NSApp finishLaunching];
    events = [NSMutableArray new];
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(200,200,640,240)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    window.releasedWhenClosed = NO; window.title = @"GPUI Kotoeri standard control";
    KotoeriControl *view = [[KotoeriControl alloc] initWithFrame:NSMakeRect(0,0,640,240)];
    view.richText = NO; view.font = [NSFont systemFontOfSize:18];
    view.string = @"Hello "; view.selectedRange = NSMakeRange(6,0);
    window.contentView = view; [window makeFirstResponder:view];
    [window makeKeyAndOrderFront:nil]; request_application_activation();
    BOOL startup_ok=YES;
    for (int i=0; i<200 && (!NSApp.active || !window.keyWindow); i++) {
      if (!pump_control()) { startup_ok=NO; break; }
    }
    NSTextInputContext *context = view.inputContext;
    control_expected_context = context;
    NSString *original = [context.selectedKeyboardInputSource copy];
    NSString *target = @"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
    BOOL source = [context.keyboardInputSources containsObject:target];
    BOOL prefix = startup_ok && NSApp.active && window.keyWindow && window.firstResponder == view && context != nil && source;
    BOOL passed = NO, down = NO, up = NO;
    unsigned int iterations = 0, insert_baseline = 0, unmark_baseline = 0;
    id monitor = nil;
    @try {
      if (prefix) {
        context.selectedKeyboardInputSource = target;
        prefix = [context.selectedKeyboardInputSource isEqual:target] &&
          NSTextInputContext.currentInputContext == context;
      }
      int codes[]={45,34,4,31,45,5,31,49,36};
      NSString *chars[]={@"n",@"i",@"h",@"o",@"n",@"g",@"o",@" ",@"\r"};
      // Observes only this application. Return baselines are captured before
      // AppKit dispatch. Metadata alone cannot establish physical provenance.
      if (control_trace.enabled) monitor = [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskKeyDown|NSEventMaskKeyUp handler:^NSEvent *(NSEvent *event) {
          if (physical && (event.window != window || !NSApp.active || !window.keyWindow ||
              window.firstResponder!=view || view.inputContext!=context ||
              NSTextInputContext.currentInputContext!=context ||
              ![context.selectedKeyboardInputSource isEqual:target])) control_trace.valid=NO;
          unsigned int position=event.type==NSEventTypeKeyDown ? control_trace.next_down : control_trace.next_up;
          int expected_codes[]={45,34,4,31,45,5,31,49,36};
          if (position>=9 || event.keyCode!=expected_codes[position] ||
              (event.type==NSEventTypeKeyDown && event.isARepeat)) control_trace.valid=NO;
          if (event.type==NSEventTypeKeyDown) control_trace.next_down++;
          else control_trace.next_up++;
          if (event.keyCode==36 && event.type==NSEventTypeKeyDown) {
            control_trace.return_downs++;
            if (!control_trace.return_seen) {
              control_trace.return_seen=YES; control_trace.down_ms=ime_monotonic_ms();
              control_trace.start_native=control_trace.native_pumps;
              control_trace.start_appkit=control_trace.appkit_pumps;
              control_trace.insert_baseline=view.inserts; control_trace.unmark_baseline=view.unmarks;
              if (physical && (!view.hasMarkedText || ![view.string isEqual:@"Hello 日本語"] ||
                  control_trace.next_up!=8)) control_trace.valid=NO;
            }
            control_record(view,@"before_return",event);
          } else if(event.keyCode==36 && event.type==NSEventTypeKeyUp) {
            control_trace.return_ups++; control_trace.up_ms=ime_monotonic_ms();
          }
          control_record(view,event.type==NSEventTypeKeyDown ? @"app_key_down" : @"app_key_up",event);
          return event;
        }];
      control_record(view,prefix ? @"ready" : @"startup_invalid",nil);
      if (physical && prefix) {
        // Human readiness is separate from the unchanged 200-pump Return
        // observation. Never block the main thread waiting for stdin.
        double deadline=ime_monotonic_ms()+180000;
        while (prefix && control_trace.valid && !passed && iterations<200) {
          if (!control_trace.return_seen && ime_monotonic_ms()>=deadline) break;
          if (!pump_control()) { prefix=NO; break; }
          // Permit reading the instructions in another app before the first
          // key. All input and the Return observation still require ownership.
          if (!control_trace.next_down && (!NSApp.active || !window.keyWindow)) continue;
          if (!NSApp.active || !window.keyWindow ||
              window.firstResponder!=view || NSTextInputContext.currentInputContext!=context ||
              ![context.selectedKeyboardInputSource isEqual:target]) { prefix=NO; break; }
          if (!control_trace.return_seen) continue;
          iterations++; // Includes the pump delivering the single Return down.
          insert_baseline=control_trace.insert_baseline; unmark_baseline=control_trace.unmark_baseline;
          down=control_trace.return_downs==1 && view.downs==9;
          up=control_trace.return_ups==1 && view.ups==9;
          if (down && up && [view.string isEqual:@"Hello 日本語"] && !view.hasMarkedText &&
              (view.inserts-insert_baseline==1 || view.unmarks-unmark_baseline==1)) passed=YES;
        }
        prefix=prefix && control_trace.valid && control_trace.return_seen;
      }
      for (int k=0; local && prefix && k<9; k++) {
        if (k==8) {
          prefix = [view.string isEqual:@"Hello 日本語"] && view.hasMarkedText;
          if (!prefix) break;
          insert_baseline=view.inserts; unmark_baseline=view.unmarks;
        }
        int status=0; NSArray<NSEvent *> *pair=create_app_local_key_events(codes[k],0,k+1,chars[k],chars[k],&status);
        if (status || pair.count != 2) { prefix=NO; break; }
        unsigned int before_down=view.downs, before_up=view.ups;
        if (!NSApp.active || !window.keyWindow || window.firstResponder != view) { prefix=NO; break; }
        for(NSEvent *event in pair) {
          [NSApp postEvent:event atStart:NO];
        }
        unsigned int budget=200;
        for(unsigned int i=0;i<budget;i++) {
          if (!pump_control() || !NSApp.active || !window.keyWindow ||
              window.firstResponder != view || NSTextInputContext.currentInputContext != context ||
              ![context.selectedKeyboardInputSource isEqual:target]) { prefix=NO; break; }
          if(k==8) iterations++;
          down=view.downs==before_down+1; up=view.ups==before_up+1;
          if (down && up && k<8) break;
          if (k==8 && down && up && [view.string isEqual:@"Hello 日本語"] && !view.hasMarkedText &&
              (view.inserts-insert_baseline==1 || view.unmarks-unmark_baseline==1)) { passed=YES; break; }
        }
        if(k<8 && (!down || !up)) prefix=NO;
      }
    } @finally {
      control_record(view,@"observation_end",nil);
      if (monitor) [NSEvent removeMonitor:monitor];
      BOOL marked=view.hasMarkedText, expected=[view.string isEqual:@"Hello 日本語"];
      unsigned int inserts=view.inserts-insert_baseline, unmarks=view.unmarks-unmark_baseline;
      ime_timing_end();
      context.selectedKeyboardInputSource=original;
      BOOL restored = original ? [context.selectedKeyboardInputSource isEqual:original] : context.selectedKeyboardInputSource==nil;
      [window makeFirstResponder:nil]; [window close];
      BOOL closed=!window.visible;
      NSDictionary *record=@{@"schema_version":@1,@"producer":@"app_local",
        @"prefix_valid":@(prefix),@"passed":@(passed),@"down_delivered":@(down),@"up_delivered":@(up),
        @"return_iterations":@(iterations),@"insert_delta":@(inserts),
        @"unmark_delta":@(unmarks),@"marked":@(marked),
        @"expected_text":@(expected),@"source_restored":@(restored), @"window_closed":@(closed), @"cleanup_ok":@(restored && closed)};
      if (physical) {
        NSMutableDictionary *result=[record mutableCopy];
        result[@"producer"]=@"human_keyboard_requested";
        result[@"hardware_provenance_verified"]=@NO;
        result[@"return_observed"]=@(control_trace.return_seen);
        result[@"sequence_valid"]=@(control_trace.valid);
        result[@"return_down_count"]=@(control_trace.return_downs);
        result[@"return_up_count"]=@(control_trace.return_ups);
        result[@"return_elapsed_ms"]=control_trace.down_ms ? @(ime_monotonic_ms()-control_trace.down_ms) : NSNull.null;
        result[@"return_native_pumps"]=@(control_trace.return_seen ? control_trace.native_pumps-control_trace.start_native+1 : 0);
        result[@"return_appkit_pumps"]=@(control_trace.return_seen ? control_trace.appkit_pumps-control_trace.start_appkit+1 : 0);
        result[@"status"]=!control_trace.return_seen ? @"NOT_RUN" : (!prefix ? @"INVALID" : (passed ? @"PASS" : @"FAIL"));
        record=result;
      }
      NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
      fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
      if (!restored || !closed) passed=NO;
    }
    return passed?0:1;
  }
}
