// Minimal standard-control diagnostic. Opt-in, app-owned input, no direct text callbacks.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#include <unistd.h>
@interface KotoeriControl : NSTextView
@property unsigned int downs, ups, inserts, unmarks, marks;
@end
@implementation KotoeriControl
- (void)keyDown:(NSEvent *)event { self.downs++; ime_timing_key(event); [super keyDown:event]; }
- (void)keyUp:(NSEvent *)event { self.ups++; ime_timing_key(event); [super keyUp:event]; }
- (void)insertText:(id)value replacementRange:(NSRange)range {
  self.inserts++; ime_timing_record(@"insert_text"); [super insertText:value replacementRange:range];
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selection replacementRange:(NSRange)range {
  self.marks++; ime_timing_record(@"set_marked_text");
  [super setMarkedText:value selectedRange:selection replacementRange:range];
}
- (void)unmarkText { self.unmarks++; ime_timing_record(@"unmark_text"); [super unmarkText]; }
@end
static BOOL pump_control(void) { return pump_native_event(16) == 0; }
int main(int argc, const char **argv) {
  const char *opt = getenv("GPUI_FIELD_MACOS_KOTOERI_CONTROL");
  BOOL local = argc == 2 && strcmp(argv[1], "--local") == 0;
  if (!opt || strcmp(opt, "1") || !local) return 2;
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
    NSString *original = [context.selectedKeyboardInputSource copy];
    NSString *target = @"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
    BOOL source = [context.keyboardInputSources containsObject:target];
    BOOL prefix = startup_ok && NSApp.active && window.keyWindow && window.firstResponder == view && context != nil && source;
    BOOL passed = NO, down = NO, up = NO;
    unsigned int iterations = 0, insert_baseline = 0, unmark_baseline = 0;
    @try {
      if (prefix) {
        context.selectedKeyboardInputSource = target;
        prefix = [context.selectedKeyboardInputSource isEqual:target] &&
          NSTextInputContext.currentInputContext == context;
      }
      int codes[]={45,34,4,31,45,5,31,49,36};
      NSString *chars[]={@"n",@"i",@"h",@"o",@"n",@"g",@"o",@" ",@"\r"};
      for (int k=0; prefix && k<9; k++) {
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
      NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
      fwrite(data.bytes,1,data.length,stdout); fputc('\n',stdout);
      if (!restored || !closed) passed=NO;
    }
    return passed?0:1;
  }
}
