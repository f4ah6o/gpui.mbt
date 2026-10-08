#import <AppKit/AppKit.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc != 3) return 2;
    char *end = NULL;
    errno = 0;
    long pid = strtol(argv[1], &end, 10);
    if (errno || !end || *end || pid <= 0 || pid > INT_MAX) return 2;
    NSString *expected = [[NSString stringWithUTF8String:argv[2]] stringByResolvingSymlinksInPath];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.0];
    NSRunningApplication *app = nil;
    do {
      app = [NSRunningApplication runningApplicationWithProcessIdentifier:(pid_t)pid];
      if (app && app.executableURL) break;
      [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    } while ([deadline timeIntervalSinceNow] > 0);
    BOOL identity = app && !app.terminated &&
      [[app.executableURL.path stringByResolvingSymlinksInPath] isEqualToString:expected];
    BOOL requested = identity && [app activateWithOptions:0];
    NSDictionary *record = @{@"pid": @(pid), @"executable_matches": @(identity),
      @"activation_request_sent": @(requested), @"active_when_sampled": @(identity && app.active),
      @"scope": @"only the exact spawned application PID and executable"};
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!json) return 2;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return requested ? 0 : 1;
  }
}
