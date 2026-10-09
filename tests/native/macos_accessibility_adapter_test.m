#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../platform/macos/accessibility_abi.h"

@interface GPWindow : NSObject <NSWindowDelegate>
@property int64_t token;
@end
@implementation GPWindow
@end

@interface GPView : NSView
@end
@implementation GPView
@end

@interface NSView (AXChildTest)
- (NSArray *)accessibilityChildren;
@end

static void fail(const char *message) {
  fprintf(stderr, "FAIL: %s\n", message);
  exit(1);
}

static void require(BOOL condition, const char *message) {
  if (!condition) fail(message);
}

static NSWindow *make_window(int64_t token) {
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(40, 60, 360, 200)
                styleMask:NSWindowStyleMaskTitled
                  backing:NSBackingStoreBuffered
                    defer:NO];
  GPView *view = [[GPView alloc] initWithFrame:NSMakeRect(0, 0, 360, 200)];
  GPWindow *delegate = [GPWindow new];
  delegate.token = token;
  window.contentView = view;
  window.delegate = delegate;
  objc_setAssociatedObject(window, @selector(make_window), delegate,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [window orderFront:nil];
  return window;
}

static const char *payload(BOOL enabled, BOOL loading, BOOL focused,
                           int activations) {
  static char bytes[512];
  snprintf(bytes, sizeof(bytes),
           "{\"version\":1,\"role\":\"button\","
           "\"name\":\"Run action\",\"left\":20,\"top\":30,"
           "\"width\":180,\"height\":48,\"enabled\":%s,"
           "\"loading\":%s,\"focused\":%s,\"activations\":%d,"
           "\"actions\":[\"Invoke\"]}",
           enabled ? "true" : "false", loading ? "true" : "false",
           focused ? "true" : "false", activations);
  return bytes;
}

static int64_t publish(NSWindow *window, int64_t existing, BOOL enabled,
                       BOOL loading, BOOL focused, int activations) {
  id delegate = window.delegate;
  int64_t token = 0;
  if ([delegate respondsToSelector:@selector(token)])
    token = ((int64_t (*)(id, SEL))[delegate methodForSelector:@selector(token)])(
        delegate, @selector(token));
  const char *bytes = payload(enabled, loading, focused, activations);
  int64_t binding = 0;
  int32_t result = gpui_macos_ax_publish_v1(
      token, existing, (const uint8_t *)bytes, (int32_t)strlen(bytes), &binding);
  if (result != 0 || binding <= 0) {
    fprintf(stderr, "publish failed: status=%d window=%lld binding=%lld\n",
            result, (long long)token, (long long)binding);
    fail("publish should return a binding");
  }
  return binding;
}

static id child(NSWindow *window) {
  return [((GPView *)window.contentView).accessibilityChildren firstObject];
}

static void test_projection_and_press(NSWindow *window, int64_t *binding_out) {
  int64_t binding = publish(window, 0, YES, NO, YES, 0);
  id button = child(window);
  require(button != nil, "the AppKit view should expose one AX child");
  require([button isAccessibilityElement], "published child should be live");
  require([[button accessibilityRole] isEqualToString:NSAccessibilityButtonRole],
          "role should be AX button");
  require([[button accessibilityLabel] isEqualToString:@"Run action"],
          "name should come from the shared snapshot");
  require([[button accessibilityTitle] isEqualToString:@"Run action"],
          "visible button name should also be the AX title");
  require([button accessibilityTopLevelUIElement] == window,
          "custom control should identify its owning top-level window");
  require([button isAccessibilityEnabled], "enabled should be projected");
  require([button isAccessibilityFocused], "focus should be projected");
  require([[button accessibilityHelp] containsString:@"Activations: 0"],
          "owner activation count should be observable");
  require([[button accessibilityHelp] containsString:@"Ready"],
          "loading state should be observable");
  NSRect frame = [button accessibilityFrame];
  require(!NSIsEmptyRect(frame), "AX frame should be in screen coordinates");
  require(fabs(frame.size.width - 180) < 1.0 &&
              fabs(frame.size.height - 48) < 1.0,
          "AX frame should preserve logical button dimensions");

  require([button accessibilityPerformPress], "enabled Invoke should enqueue");
  int64_t returned = 0;
  require(gpui_macos_ax_take_request_v1(401, &returned) == 1 &&
              returned == binding,
          "the owner should receive only the opaque binding token");
  require(gpui_macos_ax_take_request_v1(401, &returned) == 0,
          "one semantic request should be consumed once by the queue");
  *binding_out = binding;
}

static void test_queue_capacity_and_resize(NSWindow *window, int64_t binding) {
  id button = child(window);
  for (int index = 0; index < 64; index++)
    require([button accessibilityPerformPress], "queue should accept 64 items");
  require(![button accessibilityPerformPress], "65th item should fail closed");

  [window setFrame:NSMakeRect(40, 60, 340, 190) display:YES];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:NSWindowDidResizeNotification
                    object:window];
  int64_t returned = 0;
  require(gpui_macos_ax_take_request_v1(401, &returned) == 0,
          "resize should discard queued semantic work");
  require([button isAccessibilityElement],
          "a still-current semantic target should remain live after resize");
  require(fabs([button accessibilityFrame].size.width - 180) < 1.0,
          "the element frame should continue to track the owner view");
  require(gpui_macos_ax_revoke_v1(401, binding) == 0,
          "current binding should revoke cleanly");
  require(![button accessibilityPerformPress],
          "revoked object references should reject further Invoke");
  require(gpui_macos_ax_take_request_v1(401, &returned) == 0,
          "revocation should leave no queued request");
}

static void test_availability_update_purges_queue(NSWindow *window) {
  int64_t enabled_binding = publish(window, 0, YES, NO, NO, 0);
  id enabled = child(window);
  require([enabled accessibilityPerformPress],
          "enabled element should accept an event before state transition");

  int64_t disabled_binding =
      publish(window, enabled_binding, NO, NO, NO, 0);
  id disabled = child(window);
  require(disabled_binding != enabled_binding,
          "enabled state transition should replace the revocable binding");
  require(![enabled accessibilityPerformPress],
          "old element must reject after disabling");
  require(![disabled isAccessibilityEnabled],
          "disabled state should be observable");
  require(![disabled accessibilityPerformPress],
          "disabled semantic action should not enter the queue");
  int64_t returned = 0;
  require(gpui_macos_ax_take_request_v1(401, &returned) == 0,
          "availability transition should purge the earlier request");

  int64_t loading_binding =
      publish(window, disabled_binding, YES, YES, NO, 0);
  id loading = child(window);
  require(loading_binding != disabled_binding,
          "loading state transition should replace the binding");
  require(![loading accessibilityPerformPress],
          "loading semantic action should not enter the queue");
  require([[loading accessibilityHelp] containsString:@"Loading"],
          "loading state should be observable");
}

static void test_close_and_reopen(NSWindow *window) {
  require(gpui_macos_ax_revoke_v1(401, 0) == 0,
          "previous native test binding should be retired");
  int64_t binding = publish(window, 0, YES, NO, NO, 0);
  id stale = child(window);
  require([stale accessibilityPerformPress], "close test should queue a request");
  window.delegate = nil;
  [window close];
  require(![stale isAccessibilityElement],
          "closed window should revoke the retained native element");
  require(![stale accessibilityPerformPress],
          "closed window element should reject Invoke");
  int64_t returned = 0;
  require(gpui_macos_ax_take_request_v1(401, &returned) == 0,
          "closed window should leave no queued work");
  require(gpui_macos_ax_revoke_v1(401, binding) == 0,
          "revoking after close should be idempotent");

  NSWindow *reopened = make_window(402);
  int64_t new_binding = publish(reopened, 0, YES, NO, NO, 0);
  require(new_binding != binding,
          "reopened window should receive a distinct transport binding");
  require([child(reopened) isAccessibilityElement],
          "reopened window should expose its new live element");
  [reopened close];
}

int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSWindow *window = make_window(401);
    int64_t binding = 0;
    test_projection_and_press(window, &binding);
    test_queue_capacity_and_resize(window, binding);
    test_availability_update_purges_queue(window);
    test_close_and_reopen(window);
    puts("PASS: macOS AX adapter queue, projection, revocation, and lifecycle");
  }
  return 0;
}
