// Included inside native.m only under GPUI_TESTING. The default producer and
// the production NSTextInputClient remain unchanged.
#include "testing_hid_wire.h"
static int testing_hid_fd = -1;
static BOOL testing_hid_failed;
static NSMutableData *testing_hid_buffer;
static NSString *testing_hid_nonce;
static BOOL testing_hid_enabled(void) {
  return getenv("GPUI_TEST_HID_SOCKET") != NULL;
}
static void testing_hid_fail(GPWindow *w, NSString *reason) {
  BOOL first = !testing_hid_failed;
  testing_hid_failed = YES;
  if (w) w.deferredTextError = 5;
  if (first) {
    fprintf(stderr, "GPUI_TEST_HID_INVALID %s\n", reason.UTF8String);
    fflush(stderr);
  }
}
static BOOL testing_hid_connect(void) {
  if (testing_hid_failed) return NO;
  if (testing_hid_fd >= 0) return YES;
  const char *path = getenv("GPUI_TEST_HID_SOCKET");
  const char *pid_text = getenv("GPUI_TEST_HID_PRODUCER_PID");
  char *end = NULL; long pid = pid_text ? strtol(pid_text, &end, 10) : 0;
  struct sockaddr_un address = {0}; struct stat info;
  if (!path || strlen(path) >= sizeof(address.sun_path) || !pid_text || !end || *end ||
      pid <= 0 || pid > INT_MAX || lstat(path, &info) || !S_ISSOCK(info.st_mode) || info.st_uid != 0)
    return NO;
  address.sun_family = AF_UNIX;
  strlcpy(address.sun_path, path, sizeof(address.sun_path));
  int fd = socket(AF_UNIX, SOCK_STREAM, 0), no_sigpipe = 1;
  if (fd < 0) return NO;
  setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &no_sigpipe, sizeof(no_sigpipe));
  if (connect(fd, (struct sockaddr *)&address, sizeof(address)) || !hid_peer(fd, 0, (pid_t)pid) ||
      fcntl(fd, F_SETFL, O_NONBLOCK) || fcntl(fd, F_SETFD, FD_CLOEXEC)) { close(fd); return NO; }
  testing_hid_fd = fd;
  testing_hid_buffer = [NSMutableData new];
  return YES;
}
static BOOL testing_hid_report(GPWindow *w, NSDictionary *report) {
  if (![report[@"kind"] isEqual:@"report"] || ![report[@"nonce"] isEqual:testing_hid_nonce]) return NO;
  for (NSMutableDictionary *pending in w.testingPostedKeys) {
    if ([pending[@"dispatch_id"] isEqual:report[@"dispatch_id"]] &&
        [pending[@"phase"] isEqual:report[@"phase"]] && [pending[@"hid"] boolValue]) {
      double ms = [report[@"monotonic_ms"] doubleValue];
      if (pending[@"report_ms"] || ms <= 0 || !isfinite(ms) || hid_now_ms() - ms > 1000 ||
          hid_now_ms() < ms || [report[@"key_code"] intValue] != [pending[@"key_code"] intValue]) return NO;
      double uptime = [report[@"uptime_ms"] doubleValue];
      if (!isfinite(uptime) || uptime <= 0 || hid_uptime_ms() < uptime || hid_uptime_ms() - uptime > 1000) return NO;
      pending[@"report_ms"] = @(ms);
      pending[@"report_uptime_ms"] = @(uptime);
      return YES;
    }
  }
  return NO;
}
static void testing_hid_poll(GPWindow *w) {
  if (testing_hid_fd < 0 || testing_hid_failed) return;
  for (int i = 0; i < 4; i++) {
    BOOL valid = YES;
    NSDictionary *message = hid_read(testing_hid_fd, testing_hid_buffer, &valid);
    if (!valid || (message && !testing_hid_report(w, message))) {
      testing_hid_fail(w, @"unexpected producer report"); return;
    }
    if (!message) return;
  }
}
static BOOL testing_hid_queue(GPWindow *w, int key_code, NSUInteger flags,
                              int64_t dispatch_id, NSString *characters, NSString *ignoring) {
  GPView *view = (GPView *)w.window.contentView;
  if (flags || w.testingPostedKeys.count || !testing_hid_connect() ||
      ![view.inputContext.selectedKeyboardInputSource isEqual:@"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"] ||
      NSTextInputContext.currentInputContext != view.inputContext) return NO;
  NSString *nonce = NSUUID.UUID.UUIDString;
  NSDictionary *request = @{
    @"kind": @"pair", @"nonce": nonce, @"pid": @(getpid()),
    @"window": @(w.window.windowNumber), @"dispatch_id": @(dispatch_id),
    @"key_code": @(key_code), @"characters": characters, @"ignoring": ignoring,
    @"monotonic_ms": @(hid_now_ms()), @"host_epoch": @(host_epoch),
    @"session_epoch": @(w.sessionEpoch), @"direct_epoch": @(w.directEpoch),
    @"session_active": @(w.sessionActive), @"direct_text": @(w.directText),
    @"key_window": @(key_window_owns_view(w)), @"input_source": view.inputContext.selectedKeyboardInputSource,
  };
  if (!hid_write(testing_hid_fd, request)) return NO;
  // Only wait for enqueue acknowledgement, before input is scheduled. No
  // recursive event pumping, callback execution or waiting for a GPUI ACK.
  double deadline = hid_now_ms() + 1000;
  while (hid_now_ms() < deadline) {
    BOOL valid = YES;
    NSDictionary *reply = hid_read(testing_hid_fd, testing_hid_buffer, &valid);
    if (!valid) return NO;
    if (reply) {
      if (![reply[@"kind"] isEqual:@"queued"] || ![reply[@"nonce"] isEqual:nonce] ||
          ![reply[@"dispatch_id"] isEqual:@(dispatch_id)] || [reply[@"report_count"] intValue] != 2) return NO;
      testing_hid_nonce = nonce;
      return YES;
    }
    struct pollfd poll_fd = {testing_hid_fd, POLLIN, 0};
    if (poll(&poll_fd, 1, 10) < 0) return NO;
  }
  return NO;
}
static BOOL testing_hid_event_matches(NSDictionary *pending, NSEvent *event, CGEventRef cg) {
  double report_ms = [pending[@"report_uptime_ms"] doubleValue];
  double event_ms = event.timestamp * 1000.0;
  return report_ms > 0 && event_ms >= report_ms - 1 && event_ms <= report_ms + 500 &&
    hid_uptime_ms() - event_ms >= -1 && hid_uptime_ms() - event_ms <= 500 &&
    event.keyCode == [pending[@"key_code"] intValue] && !event.isARepeat &&
    event.type == ([pending[@"phase"] isEqual:@"down"] ? NSEventTypeKeyDown : NSEventTypeKeyUp) &&
    event.modifierFlags == 256 &&
    [event.characters isEqual:pending[@"characters"]] &&
    [event.charactersIgnoringModifiers isEqual:pending[@"ignoring"]] && cg &&
    CGEventGetIntegerValueField(cg, kCGEventSourceUserData) == 0 &&
    CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID) == 0 &&
    CGEventGetIntegerValueField(cg, kCGEventSourceStateID) == kCGEventSourceStateHIDSystemState &&
    CGEventGetIntegerValueField(cg, kCGKeyboardEventKeyboardType) == 40;
}
static BOOL testing_hid_owner_matches(GPWindow *w, NSEvent *event, NSDictionary *pending,
                                      BOOL key_owner, BOOL context_current, NSString *source) {
  return key_owner && context_current && event.window == w.window &&
    event.windowNumber == w.window.windowNumber &&
    [pending[@"host_epoch"] longLongValue] == host_epoch &&
    [pending[@"session_epoch"] intValue] == w.sessionEpoch &&
    [pending[@"direct_epoch"] intValue] == w.directEpoch &&
    [pending[@"session_active"] boolValue] == w.sessionActive &&
    [pending[@"direct_text"] boolValue] == w.directText &&
    [source isEqual:@"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"];
}
static int64_t take_testing_hid_dispatch(GPWindow *w, NSEvent *event, CGEventRef cg, NSString *phase) {
  testing_hid_poll(w);
  if (testing_hid_failed || !w || !event || !cg || !w.testingPostedKeys.count) {
    testing_hid_fail(w, @"unregistered input"); return -1;
  }
  NSMutableDictionary *pending = w.testingPostedKeys[0];
  GPView *view = (GPView *)w.window.contentView;
  BOOL owner = testing_hid_owner_matches(w, event, pending, key_window_owns_view(w),
    NSTextInputContext.currentInputContext == view.inputContext, view.inputContext.selectedKeyboardInputSource);
  if (!owner || ![pending[@"phase"] isEqual:phase] || !testing_hid_event_matches(pending, event, cg)) {
    testing_hid_fail(w, @"owner/order/source/timestamp/characters mismatch"); return -1;
  }
  int64_t dispatch_id = [pending[@"dispatch_id"] longLongValue];
  NSDictionary *observed = @{
    @"kind": @"received", @"nonce": testing_hid_nonce, @"dispatch_id": @(dispatch_id),
    @"phase": phase, @"key_code": @(event.keyCode), @"monotonic_ms": @(hid_now_ms()),
    @"event_uptime_ms": @(event.timestamp * 1000), @"report_ms": pending[@"report_ms"],
    @"report_uptime_ms": pending[@"report_uptime_ms"],
    @"characters": event.characters, @"ignoring": event.charactersIgnoringModifiers,
    @"flags": @(event.modifierFlags), @"source_pid": @0, @"source_state": @1,
    @"keyboard_type": @40, @"user_data": @0,
  };
  if (!hid_write(testing_hid_fd, observed)) { testing_hid_fail(w, @"receipt transport failed"); return -1; }
  [w.testingPostedKeys removeObjectAtIndex:0];
  if (event.keyCode == 36 && ime_timing.active) {
    if ([phase isEqual:@"down"]) ime_timing.down_ms = ime_monotonic_ms();
    else ime_timing.up_ms = ime_monotonic_ms();
    ime_timing_record([phase isEqual:@"down"] ? @"return_down" : @"return_up");
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:observed options:0 error:nil];
  fprintf(stderr, "GPUI_TEST_HID_RECEIVED %.*s\n", (int)json.length, (const char *)json.bytes);
  return dispatch_id;
}
