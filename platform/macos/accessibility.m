#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "accessibility_abi.h"

/*
 * Narrow AppKit projection for the macOS Button example. The only values
 * crossing this boundary are copied attributes and an opaque revocable
 * binding token. MoonBit NodeIds and callbacks never enter this file.
 */
#define GPUI_AX_QUEUE_CAPACITY 64
#define GPUI_AX_PAYLOAD_LIMIT 65536

@interface GPWindow : NSObject
@property int64_t token;
@end

@interface GPView : NSView
@end

static char gpui_ax_child_key;
static int64_t gpui_ax_next_binding_token;
static NSMutableArray<NSDictionary *> *gpui_ax_pending_requests;
static id gpui_ax_close_observer;
static id gpui_ax_resize_observer;

@interface GPUIAXButtonElement : NSAccessibilityElement <NSAccessibilityButton>
@property(nonatomic, weak) NSWindow *ownerWindow;
@property(nonatomic, weak) NSView *ownerView;
@property(nonatomic, copy) NSString *label;
@property(nonatomic, copy) NSString *help;
@property(nonatomic) NSRect logicalFrame;
@property(nonatomic) int64_t windowToken;
@property(nonatomic) int64_t bindingToken;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL loading;
@property(nonatomic) BOOL focused;
@property(nonatomic) BOOL revoked;
- (BOOL)isLive;
- (void)revoke;
@end

@implementation GPView (GPUIAXChildren)
- (NSArray *)accessibilityChildren {
  GPUIAXButtonElement *child = objc_getAssociatedObject(self, &gpui_ax_child_key);
  if (child && [child isLive]) return @[child];
  return [super accessibilityChildren];
}
@end

static int64_t gpui_ax_window_token(NSWindow *window) {
  id delegate = window.delegate;
  if (!delegate ||
      ![NSStringFromClass([delegate class]) isEqualToString:@"GPWindow"] ||
      ![delegate respondsToSelector:@selector(token)])
    return 0;
  int64_t (*read_token)(id, SEL) =
      (int64_t (*)(id, SEL))[delegate methodForSelector:@selector(token)];
  return read_token ? read_token(delegate, @selector(token)) : 0;
}

static NSWindow *gpui_ax_find_window(int64_t token) {
  if (token <= 0 || !NSApp) return nil;
  for (NSWindow *window in NSApp.windows) {
    if (gpui_ax_window_token(window) == token && window.contentView)
      return window;
  }
  return nil;
}

static GPUIAXButtonElement *gpui_ax_current_element(int64_t window_token) {
  NSWindow *window = gpui_ax_find_window(window_token);
  if (!window) return nil;
  id child = objc_getAssociatedObject(window.contentView, &gpui_ax_child_key);
  if (![child isKindOfClass:GPUIAXButtonElement.class]) return nil;
  GPUIAXButtonElement *element = child;
  return element.windowToken == window_token && !element.revoked ? element : nil;
}

static void gpui_ax_remove_requests(int64_t window_token, int64_t binding_token) {
  if (!gpui_ax_pending_requests) return;
  NSIndexSet *indexes = [gpui_ax_pending_requests indexesOfObjectsPassingTest:
      ^BOOL(NSDictionary *request, NSUInteger index, BOOL *stop) {
        (void)index;
        (void)stop;
        return [request[@"window"] longLongValue] == window_token &&
            (binding_token == 0 ||
             [request[@"binding"] longLongValue] == binding_token);
      }];
  [gpui_ax_pending_requests removeObjectsAtIndexes:indexes];
}

static void gpui_ax_revoke_view(NSView *view, int64_t window_token) {
  if (!view) return;
  GPUIAXButtonElement *element =
      objc_getAssociatedObject(view, &gpui_ax_child_key);
  if (element) {
    int64_t binding_token = element.bindingToken;
    [element revoke];
    gpui_ax_remove_requests(window_token, binding_token);
    objc_setAssociatedObject(view, &gpui_ax_child_key, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSAccessibilityPostNotification(view, NSAccessibilityLayoutChangedNotification);
  }
}

static void gpui_ax_install_observers(void) {
  if (!gpui_ax_close_observer) {
    gpui_ax_close_observer =
        [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowWillCloseNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *note) {
                      NSWindow *window = note.object;
                      int64_t token = gpui_ax_window_token(window);
                      if (token <= 0) {
                        id child = objc_getAssociatedObject(
                            window.contentView, &gpui_ax_child_key);
                        if ([child isKindOfClass:GPUIAXButtonElement.class])
                          token = ((GPUIAXButtonElement *)child).windowToken;
                      }
                      if (token > 0) {
                        gpui_ax_revoke_view(window.contentView, token);
                        gpui_ax_remove_requests(token, 0);
                      }
                    }];
  }
  if (!gpui_ax_resize_observer) {
    gpui_ax_resize_observer =
        [NSNotificationCenter.defaultCenter
            addObserverForName:NSWindowDidResizeNotification
                        object:nil
                         queue:nil
            usingBlock:^(NSNotification *note) {
                      NSWindow *window = note.object;
                      int64_t token = gpui_ax_window_token(window);
                      /* The frame is computed from the live view/window.
                       * Drop accepted work at resize; the MoonBit owner
                       * revokes the binding if its semantic generation or
                       * bounds changed while consuming the resize event. */
                      if (token > 0) gpui_ax_remove_requests(token, 0);
                    }];
  }
}

@implementation GPUIAXButtonElement
- (BOOL)isLive {
  if (self.revoked || !self.ownerWindow || !self.ownerView ||
      self.ownerView.window != self.ownerWindow ||
      gpui_ax_find_window(self.windowToken) != self.ownerWindow)
    return NO;
  return objc_getAssociatedObject(self.ownerView, &gpui_ax_child_key) == self;
}

- (BOOL)isAccessibilityElement { return [self isLive]; }

- (NSAccessibilityRole)accessibilityRole {
  return [self isLive] ? NSAccessibilityButtonRole : nil;
}

- (NSString *)accessibilityLabel {
  return [self isLive] ? self.label : nil;
}

- (NSString *)accessibilityTitle {
  return [self isLive] ? self.label : nil;
}

- (NSRect)accessibilityFrame {
  if (![self isLive] || !self.ownerWindow.isVisible) return NSZeroRect;
  NSView *view = self.ownerView;
  NSRect bounds = view.bounds;
  if (!NSContainsRect(bounds, self.logicalFrame)) return NSZeroRect;
  NSRect in_window = [view convertRect:self.logicalFrame toView:nil];
  return [self.ownerWindow convertRectToScreen:in_window];
}

- (id)accessibilityParent { return [self isLive] ? self.ownerView : nil; }

- (id)accessibilityTopLevelUIElement {
  return [self isLive] ? self.ownerWindow : nil;
}

- (id)accessibilityWindow { return [self isLive] ? self.ownerWindow : nil; }

- (NSPoint)accessibilityActivationPoint {
  NSRect frame = [self accessibilityFrame];
  return NSIsEmptyRect(frame) ? NSZeroPoint
                              : NSMakePoint(NSMidX(frame), NSMidY(frame));
}

- (BOOL)isAccessibilityFocused { return [self isLive] && self.focused; }

- (BOOL)isAccessibilityEnabled { return [self isLive] && self.enabled; }

- (NSString *)accessibilityHelp { return [self isLive] ? self.help : nil; }

- (NSString *)accessibilityIdentifier {
  return [self isLive] ? @"gpui.mbt.macos-button.run-action" : nil;
}

- (BOOL)accessibilityPerformPress {
  if (![NSThread isMainThread] || ![self isLive] ||
      !self.ownerWindow.isVisible || !self.enabled ||
      self.loading || self.bindingToken <= 0)
    return NO;
  if (!gpui_ax_pending_requests)
    gpui_ax_pending_requests = [NSMutableArray new];
  if (gpui_ax_pending_requests.count >= GPUI_AX_QUEUE_CAPACITY) return NO;
  [gpui_ax_pending_requests addObject:@{
    @"window" : @(self.windowToken),
    @"binding" : @(self.bindingToken),
  }];
  return YES;
}

- (void)revoke {
  self.revoked = YES;
  self.label = nil;
  self.help = nil;
  self.ownerWindow = nil;
  self.ownerView = nil;
}
@end

static BOOL gpui_ax_boolean(NSDictionary *dictionary, NSString *key,
                            BOOL *value) {
  id candidate = dictionary[key];
  if (![candidate isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)candidate) != CFBooleanGetTypeID())
    return NO;
  *value = [candidate boolValue];
  return YES;
}

static BOOL gpui_ax_number(NSDictionary *dictionary, NSString *key,
                          double *value) {
  id candidate = dictionary[key];
  if (![candidate isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)candidate) == CFBooleanGetTypeID())
    return NO;
  double number = [candidate doubleValue];
  if (!isfinite(number)) return NO;
  *value = number;
  return YES;
}

static NSDictionary *gpui_ax_decode_payload(const uint8_t *bytes,
                                            int32_t length) {
  if (!bytes || length <= 0 || length > GPUI_AX_PAYLOAD_LIMIT) return nil;
  NSData *data = [NSData dataWithBytes:bytes length:(NSUInteger)length];
  NSError *error = nil;
  id value = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingFragmentsAllowed
                                               error:&error];
  if (error || ![value isKindOfClass:NSDictionary.class]) return nil;
  NSDictionary *dictionary = value;
  NSSet *expected = [NSSet setWithArray:@[
    @"version", @"role", @"name", @"left", @"top", @"width", @"height",
    @"enabled", @"loading", @"focused", @"activations", @"actions",
  ]];
  if (![[NSSet setWithArray:dictionary.allKeys] isEqualToSet:expected]) return nil;
  NSNumber *version = dictionary[@"version"];
  NSNumber *activations = dictionary[@"activations"];
  NSString *role = dictionary[@"role"];
  NSString *name = dictionary[@"name"];
  NSArray *actions = dictionary[@"actions"];
  if (![version isKindOfClass:NSNumber.class] || version.intValue != 1 ||
      CFGetTypeID((__bridge CFTypeRef)version) == CFBooleanGetTypeID() ||
      ![role isKindOfClass:NSString.class] || ![role isEqualToString:@"button"] ||
      ![name isKindOfClass:NSString.class] || name.length > 4096 ||
      ![activations isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)activations) == CFBooleanGetTypeID() ||
      activations.longLongValue < 0 || activations.longLongValue > INT32_MAX ||
      ![actions isKindOfClass:NSArray.class] || actions.count != 1 ||
      ![actions[0] isKindOfClass:NSString.class] ||
      ![actions[0] isEqualToString:@"Invoke"])
    return nil;
  double left = 0, top = 0, width = 0, height = 0;
  BOOL enabled = NO, loading = NO, focused = NO;
  if (!gpui_ax_number(dictionary, @"left", &left) ||
      !gpui_ax_number(dictionary, @"top", &top) ||
      !gpui_ax_number(dictionary, @"width", &width) ||
      !gpui_ax_number(dictionary, @"height", &height) ||
      !gpui_ax_boolean(dictionary, @"enabled", &enabled) ||
      !gpui_ax_boolean(dictionary, @"loading", &loading) ||
      !gpui_ax_boolean(dictionary, @"focused", &focused) ||
      left < 0 || top < 0 || width <= 0 || height <= 0 ||
      left > 8192 || top > 8192 || width > 8192 || height > 8192 ||
      left + width > 8192 || top + height > 8192 || (focused && !enabled))
    return nil;
  return dictionary;
}

/* Returns 0 on success. The input is a copied, versioned UTF-8 JSON payload. */
int32_t gpui_macos_ax_publish_v1(int64_t window_token,
                                 int64_t existing_binding_token,
                                 const uint8_t *bytes, int32_t length,
                                 int64_t *out_binding_token) {
  if (![NSThread isMainThread]) return 18;
  if (!out_binding_token || existing_binding_token < 0) return 5;
  @autoreleasepool {
    NSWindow *window = gpui_ax_find_window(window_token);
    if (!window || !window.contentView) return 10;
    NSDictionary *payload = gpui_ax_decode_payload(bytes, length);
    if (!payload) return 5;
    GPView *view = (GPView *)window.contentView;
    GPUIAXButtonElement *current =
        objc_getAssociatedObject(view, &gpui_ax_child_key);
    if (current && current.revoked) current = nil;

    if (existing_binding_token != 0 && current &&
        current.bindingToken != existing_binding_token)
      return 10;
    if (existing_binding_token == 0 && current) return 12;
    BOOL enabled = [payload[@"enabled"] boolValue];
    BOOL loading = [payload[@"loading"] boolValue];
    BOOL focused = [payload[@"focused"] boolValue];
    double left = [payload[@"left"] doubleValue];
    double top = [payload[@"top"] doubleValue];
    double width = [payload[@"width"] doubleValue];
    double height = [payload[@"height"] doubleValue];
    NSString *name = payload[@"name"];
    int64_t activations = [payload[@"activations"] longLongValue];
    NSString *help = [NSString stringWithFormat:
        @"Activations: %lld; %@; %@", activations,
        enabled ? @"Enabled" : @"Disabled", loading ? @"Loading" : @"Ready"];

    if (current && ((current.enabled != enabled) ||
                    (current.loading != loading) ||
                    !NSEqualRects(current.logicalFrame,
                                  NSMakeRect(left, top, width, height)))) {
      int64_t old_token = current.bindingToken;
      [current revoke];
      gpui_ax_remove_requests(window_token, old_token);
      objc_setAssociatedObject(view, &gpui_ax_child_key, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      current = nil;
    }

    BOOL created = NO;
    if (!current) {
      if (gpui_ax_next_binding_token == INT64_MAX) return 13;
      current = [GPUIAXButtonElement new];
      current.windowToken = window_token;
      current.bindingToken = ++gpui_ax_next_binding_token;
      current.ownerWindow = window;
      current.ownerView = view;
      objc_setAssociatedObject(view, &gpui_ax_child_key, current,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
      created = YES;
    }
    current.label = name;
    current.help = help;
    current.logicalFrame = NSMakeRect(left, top, width, height);
    current.enabled = enabled;
    current.loading = loading;
    current.focused = focused;
    current.revoked = NO;
    *out_binding_token = current.bindingToken;
    gpui_ax_install_observers();
    if (created)
      NSAccessibilityPostNotification(view,
                                      NSAccessibilityLayoutChangedNotification);
    else
      NSAccessibilityPostNotification(current,
                                      NSAccessibilityValueChangedNotification);
    return 0;
  }
}

int32_t gpui_macos_ax_revoke_v1(int64_t window_token,
                                int64_t binding_token) {
  if (![NSThread isMainThread]) return 18;
  if (binding_token < 0) return 5;
  @autoreleasepool {
    NSWindow *window = gpui_ax_find_window(window_token);
    if (!window) {
      gpui_ax_remove_requests(window_token, 0);
      return 0;
    }
    GPUIAXButtonElement *current =
        objc_getAssociatedObject(window.contentView, &gpui_ax_child_key);
    if (!current) {
      gpui_ax_remove_requests(window_token, 0);
      return 0;
    }
    if (binding_token != 0 && current.bindingToken != binding_token) return 10;
    gpui_ax_revoke_view(window.contentView, window_token);
    return 0;
  }
}

/* Returns 0 for no request, 1 for one live request, or an ErrorCode ordinal. */
int32_t gpui_macos_ax_take_request_v1(int64_t window_token,
                                     int64_t *out_binding_token) {
  if (![NSThread isMainThread]) return 18;
  if (!out_binding_token) return 5;
  @autoreleasepool {
    *out_binding_token = 0;
    if (!gpui_ax_pending_requests) return 0;
    NSWindow *window = gpui_ax_find_window(window_token);
    for (NSUInteger index = 0; index < gpui_ax_pending_requests.count;) {
      NSDictionary *request = gpui_ax_pending_requests[index];
      int64_t request_window = [request[@"window"] longLongValue];
      if (request_window != window_token) {
        /* Closed windows are pruned even if the owner no longer polls them. */
        if (!gpui_ax_find_window(request_window)) {
          [gpui_ax_pending_requests removeObjectAtIndex:index];
          continue;
        }
        index += 1;
        continue;
      }
      int64_t binding = [request[@"binding"] longLongValue];
      [gpui_ax_pending_requests removeObjectAtIndex:index];
      GPUIAXButtonElement *current = gpui_ax_current_element(window_token);
      if (!window || !current || current.bindingToken != binding ||
          !current.enabled || current.loading)
        continue;
      *out_binding_token = binding;
      return 1;
    }
    return 0;
  }
}

#ifdef GPUI_TESTING
int32_t gpui_macos_ax_test_press_v1(int64_t window_token) {
  if (![NSThread isMainThread]) return 18;
  GPUIAXButtonElement *element = gpui_ax_current_element(window_token);
  return element && [element accessibilityPerformPress] ? 0 : 12;
}

int32_t gpui_macos_ax_test_child_count_v1(int64_t window_token) {
  if (![NSThread isMainThread]) return -18;
  NSWindow *window = gpui_ax_find_window(window_token);
  if (!window) return -10;
  return (int32_t)[((GPView *)window.contentView).accessibilityChildren count];
}
#endif
