// Test-only bounded transport. This file never enters a production build.
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <arpa/inet.h>
#include <errno.h>
#include <time.h>
#include <mach/mach_time.h>

static double hid_now_ms(void) {
  struct timespec ts;
  if (clock_gettime(CLOCK_MONOTONIC, &ts)) return 0;
  return ts.tv_sec * 1000.0 + ts.tv_nsec / 1000000.0;
}
// NSEvent/CGEvent timestamps use the awake uptime clock, whereas Darwin's
// CLOCK_MONOTONIC includes accumulated sleep. Never subtract the two domains.
static double hid_uptime_ms(void) {
  mach_timebase_info_data_t info; mach_timebase_info(&info);
  return (double)mach_absolute_time() * info.numer / info.denom / 1000000.0;
}
static BOOL hid_peer(int fd, uid_t uid, pid_t pid) {
  uid_t actual_uid; gid_t actual_gid; pid_t actual_pid = 0;
  socklen_t size = sizeof(actual_pid);
  return getpeereid(fd, &actual_uid, &actual_gid) == 0 && actual_uid == uid &&
    getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &actual_pid, &size) == 0 && actual_pid == pid;
}
static BOOL hid_write(int fd, NSDictionary *value) {
  NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  if (!json || !json.length || json.length > 4096) return NO;
  uint32_t length = htonl((uint32_t)json.length);
  NSMutableData *packet = [NSMutableData dataWithBytes:&length length:sizeof(length)];
  [packet appendData:json];
  // Packets are tiny; partial/would-block writes invalidate the connection.
  return send(fd, packet.bytes, packet.length, 0) == (ssize_t)packet.length;
}
// nil with valid=YES means no complete packet yet, not transport failure.
static NSDictionary *hid_read(int fd, NSMutableData *buffer, BOOL *valid) {
  *valid = YES;
  if (buffer.length < 4) {
    uint8_t bytes[4096]; ssize_t count = recv(fd, bytes, sizeof(bytes), MSG_DONTWAIT);
    if (count > 0) [buffer appendBytes:bytes length:(NSUInteger)count];
    else if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) *valid = NO;
  }
  if (!*valid || buffer.length < 4) return nil;
  uint32_t length; memcpy(&length, buffer.bytes, 4); length = ntohl(length);
  if (!length || length > 4096 || buffer.length > 8192) { *valid = NO; return nil; }
  if (buffer.length < length + 4) {
    uint8_t bytes[4096]; ssize_t count = recv(fd, bytes, sizeof(bytes), MSG_DONTWAIT);
    if (count > 0) [buffer appendBytes:bytes length:(NSUInteger)count];
    else if (count == 0 || (errno != EAGAIN && errno != EWOULDBLOCK)) *valid = NO;
  }
  if (!*valid || buffer.length < length + 4) return nil;
  NSData *json = [buffer subdataWithRange:NSMakeRange(4, length)];
  id value = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  [buffer replaceBytesInRange:NSMakeRange(0, length + 4) withBytes:NULL length:0];
  if (![value isKindOfClass:NSDictionary.class]) { *valid = NO; return nil; }
  return value;
}
