#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

enum { AX_CLIENT_UNSUPPORTED = 77, AX_MAX_DEPTH = 10, AX_MAX_NODES = 4096 };

static void fail(const char *message) {
  fprintf(stderr, "FAIL: %s\n", message);
  exit(1);
}

static CFTypeRef attribute(AXUIElementRef element, CFStringRef name) {
  CFTypeRef value = NULL;
  AXError error = AXUIElementCopyAttributeValue(element, name, &value);
  return error == kAXErrorSuccess ? value : NULL;
}

static bool string_equals(CFTypeRef value, CFStringRef expected) {
  return value && CFGetTypeID(value) == CFStringGetTypeID() &&
         CFStringCompare((CFStringRef)value, expected, 0) ==
             kCFCompareEqualTo;
}

static bool has_role(AXUIElementRef element, CFStringRef expected) {
  CFTypeRef role = attribute(element, kAXRoleAttribute);
  bool matches = string_equals(role, expected);
  if (role) CFRelease(role);
  return matches;
}

static AXUIElementRef find_button(AXUIElementRef root, int depth,
                                  int *visited,
                                  AXUIElementRef current_window,
                                  AXUIElementRef *found_window) {
  if (!root || depth > AX_MAX_DEPTH || *visited >= AX_MAX_NODES) return NULL;
  *visited += 1;
  CFTypeRef role = attribute(root, kAXRoleAttribute);
  CFTypeRef title = attribute(root, kAXTitleAttribute);
  if (string_equals(role, kAXWindowRole)) current_window = root;
  bool found = string_equals(role, kAXButtonRole) &&
               string_equals(title, CFSTR("Run action"));
  if (role) CFRelease(role);
  if (title) CFRelease(title);
  if (found) {
    if (current_window) *found_window = (AXUIElementRef)CFRetain(current_window);
    return (AXUIElementRef)CFRetain(root);
  }

  CFTypeRef children = attribute(root, kAXChildrenAttribute);
  if (!children || CFGetTypeID(children) != CFArrayGetTypeID()) {
    if (children) CFRelease(children);
    return NULL;
  }
  AXUIElementRef result = NULL;
  CFArrayRef array = (CFArrayRef)children;
  for (CFIndex index = 0; index < CFArrayGetCount(array) && !result; index++) {
    CFTypeRef child = CFArrayGetValueAtIndex(array, index);
    if (child && CFGetTypeID(child) == AXUIElementGetTypeID())
      result = find_button((AXUIElementRef)child, depth + 1, visited,
                           current_window, found_window);
  }
  CFRelease(children);
  return result;
}

static AXUIElementRef search_windows(CFArrayRef windows, pid_t pid,
                                     AXUIElementRef *found_window,
                                     bool *window_seen) {
  AXUIElementRef result = NULL;
  int visited = 0;
  for (CFIndex index = 0; index < CFArrayGetCount(windows) && !result; index++) {
    CFTypeRef window = CFArrayGetValueAtIndex(windows, index);
    pid_t owner = 0;
    if (!window || CFGetTypeID(window) != AXUIElementGetTypeID() ||
        AXUIElementGetPid((AXUIElementRef)window, &owner) != kAXErrorSuccess ||
        owner != pid ||
        !has_role((AXUIElementRef)window, kAXWindowRole))
      continue;
    *window_seen = true;
    result = find_button((AXUIElementRef)window, 0, &visited, NULL,
                         found_window);
  }
  return result;
}

static AXUIElementRef named_button(pid_t pid, AXUIElementRef *found_window,
                                   bool *window_seen) {
  AXUIElementRef application = AXUIElementCreateApplication(pid);
  if (!application) fail("AXUIElementCreateApplication returned null");
  CFTypeRef windows = attribute(application, kAXWindowsAttribute);
  if (!windows || CFGetTypeID(windows) != CFArrayGetTypeID()) {
    if (windows) CFRelease(windows);
    CFRelease(application);
    return NULL;
  }
  AXUIElementRef result = NULL;
  CFArrayRef array = (CFArrayRef)windows;
  result = search_windows(array, pid, found_window, window_seen);
  CFRelease(windows);
  CFRelease(application);
  if (result) return result;

  /* Some AppKit applications omit windows from their per-app AX list. Search
   * the system-wide list, filtering every candidate back to the requested pid. */
  AXUIElementRef system = AXUIElementCreateSystemWide();
  if (!system) return NULL;
  CFTypeRef all_windows = attribute(system, kAXWindowsAttribute);
  if (all_windows && CFGetTypeID(all_windows) == CFArrayGetTypeID())
    result = search_windows((CFArrayRef)all_windows, pid, found_window,
                            window_seen);
  if (all_windows) CFRelease(all_windows);
  CFRelease(system);
  return result;
}

static void dump_element(AXUIElementRef element, int depth, int *visited) {
  if (!element || depth > 8 || *visited >= 128) return;
  *visited += 1;
  CFTypeRef role = attribute(element, kAXRoleAttribute);
  CFTypeRef title = attribute(element, kAXTitleAttribute);
  char role_text[128] = "?";
  char title_text[256] = "";
  if (role && CFGetTypeID(role) == CFStringGetTypeID())
    CFStringGetCString((CFStringRef)role, role_text, sizeof(role_text),
                       kCFStringEncodingUTF8);
  if (title && CFGetTypeID(title) == CFStringGetTypeID())
    CFStringGetCString((CFStringRef)title, title_text, sizeof(title_text),
                       kCFStringEncodingUTF8);
  fprintf(stderr, "%*s%s: %s\n", depth * 2, "", role_text, title_text);
  if (!string_equals(role, kAXWindowRole)) {
    if (role) CFRelease(role);
    if (title) CFRelease(title);
    return;
  }
  if (role) CFRelease(role);
  if (title) CFRelease(title);
  CFTypeRef children = attribute(element, kAXChildrenAttribute);
  if (!children || CFGetTypeID(children) != CFArrayGetTypeID()) {
    if (children) CFRelease(children);
    return;
  }
  CFArrayRef array = (CFArrayRef)children;
  for (CFIndex index = 0; index < CFArrayGetCount(array); index++) {
    CFTypeRef child = CFArrayGetValueAtIndex(array, index);
    if (child && CFGetTypeID(child) == AXUIElementGetTypeID())
      dump_element((AXUIElementRef)child, depth + 1, visited);
  }
  CFRelease(children);
}

static void dump_application(pid_t pid) {
  AXUIElementRef application = AXUIElementCreateApplication(pid);
  if (!application) {
    fprintf(stderr, "AX tree unavailable: no application element for pid %d\n",
            pid);
    return;
  }
  CFTypeRef windows = NULL;
  AXError window_error =
      AXUIElementCopyAttributeValue(application, kAXWindowsAttribute, &windows);
  fprintf(stderr, "AXWindows query status=%d", (int)window_error);
  if (!windows || CFGetTypeID(windows) != CFArrayGetTypeID()) {
    fprintf(stderr, "; AX tree unavailable: app windows attribute missing\n");
    if (windows) CFRelease(windows);
    CFRelease(application);
    return;
  }
  CFArrayRef array = (CFArrayRef)windows;
  fprintf(stderr, "; window array count=%ld\n", (long)CFArrayGetCount(array));
  int visited = 0;
  for (CFIndex index = 0; index < CFArrayGetCount(array); index++) {
    CFTypeRef window = CFArrayGetValueAtIndex(array, index);
    if (window && CFGetTypeID(window) == AXUIElementGetTypeID())
      dump_element((AXUIElementRef)window, 0, &visited);
  }
  CFRelease(windows);
  CFRelease(application);
}

static bool has_action(AXUIElementRef element) {
  CFArrayRef actions = NULL;
  if (AXUIElementCopyActionNames(element, &actions) != kAXErrorSuccess ||
      !actions)
    return false;
  bool found = false;
  for (CFIndex index = 0; index < CFArrayGetCount(actions); index++) {
    CFTypeRef action = CFArrayGetValueAtIndex(actions, index);
    if (string_equals(action, kAXPressAction)) found = true;
  }
  CFRelease(actions);
  return found;
}

static bool observable_state(AXUIElementRef button, AXUIElementRef window,
                             int activations) {
  CFTypeRef role = attribute(button, kAXRoleAttribute);
  CFTypeRef title = attribute(button, kAXTitleAttribute);
  CFTypeRef help = attribute(button, kAXHelpAttribute);
  CFTypeRef enabled = attribute(button, kAXEnabledAttribute);
  CFTypeRef focused = attribute(button, kAXFocusedAttribute);
  CFTypeRef position = attribute(button, kAXPositionAttribute);
  CFTypeRef size = attribute(button, kAXSizeAttribute);
  CFTypeRef window_position = attribute(window, kAXPositionAttribute);
  CFTypeRef window_size = attribute(window, kAXSizeAttribute);
  bool valid = string_equals(role, kAXButtonRole) &&
               string_equals(title, CFSTR("Run action")) &&
               help && CFGetTypeID(help) == CFStringGetTypeID() &&
               enabled && CFGetTypeID(enabled) == CFBooleanGetTypeID() &&
               CFBooleanGetValue((CFBooleanRef)enabled) &&
               focused && CFGetTypeID(focused) == CFBooleanGetTypeID() &&
               position && AXValueGetTypeID() == CFGetTypeID(position) &&
               size && AXValueGetTypeID() == CFGetTypeID(size) &&
               window_position &&
               AXValueGetTypeID() == CFGetTypeID(window_position) &&
               window_size && AXValueGetTypeID() == CFGetTypeID(window_size) &&
               has_action(button);
  if (valid) {
    CGPoint origin = CGPointZero;
    CGSize dimensions = CGSizeZero;
    CGPoint window_origin = CGPointZero;
    CGSize window_dimensions = CGSizeZero;
    valid = AXValueGetValue((AXValueRef)position, kAXValueCGPointType,
                            &origin) &&
            AXValueGetValue((AXValueRef)size, kAXValueCGSizeType,
                            &dimensions) &&
            AXValueGetValue((AXValueRef)window_position, kAXValueCGPointType,
                            &window_origin) &&
            AXValueGetValue((AXValueRef)window_size, kAXValueCGSizeType,
                            &window_dimensions) &&
            isfinite(origin.x) && isfinite(origin.y) &&
            isfinite(dimensions.width) && isfinite(dimensions.height) &&
            isfinite(window_origin.x) && isfinite(window_origin.y) &&
            isfinite(window_dimensions.height) &&
            fabs((origin.x - window_origin.x) - 24.0) <= 2.0 &&
            fabs((origin.y - window_origin.y) -
                 (window_dimensions.height - 240.0 + 20.0)) <= 2.0 &&
            fabs(dimensions.width - 240.0) <= 2.0 &&
            fabs(dimensions.height - 48.0) <= 2.0;
    CFStringRef expected_help = CFStringCreateWithFormat(
        kCFAllocatorDefault, NULL,
        CFSTR("Activations: %d; Enabled; Ready"), activations);
    valid = valid && expected_help &&
            CFStringCompare((CFStringRef)help, expected_help, 0) ==
                kCFCompareEqualTo &&
            !CFBooleanGetValue((CFBooleanRef)focused);
    if (expected_help) CFRelease(expected_help);
  }
  if (role) CFRelease(role);
  if (title) CFRelease(title);
  if (help) CFRelease(help);
  if (enabled) CFRelease(enabled);
  if (focused) CFRelease(focused);
  if (position) CFRelease(position);
  if (size) CFRelease(size);
  if (window_position) CFRelease(window_position);
  if (window_size) CFRelease(window_size);
  return valid;
}

int main(int argc, char **argv) {
  if (argc != 5 || strcmp(argv[1], "--pid") != 0 ||
      strcmp(argv[3], "--bundle-id") != 0) {
    fprintf(stderr,
            "usage: macos_button_ax_client --pid APP_PID --bundle-id ID\n");
    return 2;
  }
  char *end = NULL;
  long parsed = strtol(argv[2], &end, 10);
  if (!end || *end || parsed <= 0 || parsed > INT32_MAX) {
    fprintf(stderr, "invalid application pid\n");
    return 2;
  }
  NSString *expected_bundle_id = [NSString stringWithUTF8String:argv[4]];
  NSRunningApplication *running =
      [NSRunningApplication runningApplicationWithProcessIdentifier:
                                (pid_t)parsed];
  if (!expected_bundle_id || !running ||
      ![running.bundleIdentifier isEqualToString:expected_bundle_id]) {
    fprintf(stderr,
            "FAIL: launched pid did not register the expected unique bundle id\n");
    return 1;
  }
  printf("AX client target pid=%ld bundle_id=%s\n", parsed, argv[4]);
  if (!AXIsProcessTrusted()) {
    fprintf(stderr,
            "UNSUPPORTED: this client is not authorized for AX observation; "
            "no permission prompt or setting was changed\n");
    return AX_CLIENT_UNSUPPORTED;
  }

  pid_t pid = (pid_t)parsed;
  AXUIElementRef button = NULL;
  AXUIElementRef window = NULL;
  bool window_seen = false;
  for (int attempt = 0; attempt < 150 && !button; attempt++) {
    button = named_button(pid, &window, &window_seen);
    if (!button) usleep(100000);
  }
  if (!button) {
    dump_application(pid);
    if (!window_seen)
      fail("native AX client did not observe an AXWindow within 15 seconds");
    fail("native AX client did not find the named Run action button in AXWindow");
  }
  if (!window || !observable_state(button, window, 0))
    fail("role, name, exact screen bounds, enabled/focus state, action, or initial help failed");

  AXError first = AXUIElementPerformAction(button, kAXPressAction);
  AXError second = AXUIElementPerformAction(button, kAXPressAction);
  if (first != kAXErrorSuccess || second != kAXErrorSuccess)
    fail("two separate AXPress requests were not accepted");

  bool observed_two = false;
  for (int attempt = 0; attempt < 80 && !observed_two; attempt++) {
    observed_two = observable_state(button, window, 2);
    if (!observed_two) usleep(100000);
  }
  if (!observed_two)
    fail("two accepted AX requests did not produce exactly two owner activations");
  puts("PASS: separate AX client observed bounds/state/action and two owner activations");
  CFRelease(button);
  CFRelease(window);
  return 0;
}
