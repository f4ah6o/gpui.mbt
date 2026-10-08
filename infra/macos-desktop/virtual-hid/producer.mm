// Opt-in test producer. Fixed sequence only; no arbitrary input or IME calls.
#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <libproc.h>
#include <atomic>
#include <chrono>
#include <csignal>
#include <thread>
#include <spawn.h>
#include <sys/wait.h>
#include <pqrs/karabiner/driverkit/virtual_hid_device_service.hpp>
#include "../../../platform/macos/testing_hid_wire.h"
extern char **environ;
namespace service = pqrs::karabiner::driverkit::virtual_hid_device_service;
namespace report = pqrs::karabiner::driverkit::virtual_hid_device_driver::hid_report;
using namespace std::chrono_literals;
static std::atomic<bool> cancelled(false);
static constexpr int codes[] = {45,34,4,31,45,5,31,49,36,45,53};
static constexpr uint16_t usages[] = {17,12,11,18,17,10,18,44,40,17,41};
static NSArray *texts(void) { return @[@"n",@"i",@"h",@"o",@"n",@"g",@"o",@" ",@"\r",@"n",@"\x1b"]; }
static void log_value(NSDictionary *value) {
  NSMutableDictionary *entry = [value mutableCopy]; if (!entry[@"monotonic_ms"]) entry[@"monotonic_ms"] = @(hid_now_ms());
  NSData *json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
  printf("%.*s\n", (int)json.length, (const char *)json.bytes); fflush(stdout);
}
static BOOL console_matches(uid_t expected, BOOL gui) {
  uid_t uid = (uid_t)-1; gid_t gid;
  NSString *name = CFBridgingRelease(SCDynamicStoreCopyConsoleUser(NULL, &uid, &gid));
  NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
  return name && ![name isEqual:@"loginwindow"] && uid == expected &&
    (!gui || ([session[(__bridge NSString *)kCGSessionUserIDKey] unsignedIntValue] == uid &&
      [session[(__bridge NSString *)kCGSessionOnConsoleKey] boolValue] &&
      [session[(__bridge NSString *)kCGSessionLoginDoneKey] boolValue]));
}
static BOOL owned_path(pid_t pid, NSString *expected) {
  char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
  return proc_pidpath(pid, path, sizeof(path)) > 0 && [expected isEqual:@(path)];
}
static BOOL front_window(pid_t pid, int window) {
  NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
    kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  for (NSDictionary *w in windows) {
    if ([w[(__bridge NSString *)kCGWindowLayer] intValue] != 0) continue;
    return [w[(__bridge NSString *)kCGWindowOwnerPID] intValue] == pid &&
      [w[(__bridge NSString *)kCGWindowNumber] intValue] == window;
  }
  return NO;
}
static int probe(uid_t uid, pid_t pid, int window, NSString *exe) {
  TISInputSourceRef input = TISCopyCurrentKeyboardInputSource();
  NSString *source = input ? (__bridge NSString *)TISGetInputSourceProperty(input,kTISPropertyInputSourceID) : nil;
  BOOL source_ok = [source isEqual:@"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"];
  BOOL ok = geteuid() == uid && console_matches(uid, YES) && owned_path(pid, exe) &&
    NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == pid && front_window(pid, window) && source_ok;
  log_value(@{@"kind":@"target_probe",@"ok":@(ok),@"uid":@(geteuid()),@"pid":@(pid),@"window":@(window),
    @"input_source":source ?: NSNull.null});
  if (input) CFRelease(input); return ok ? 0 : 3;
}
// Source selection is per GUI session; root's TIS selection is not evidence.
static BOOL gui_probe(NSString *self, uid_t uid, pid_t pid, int window, NSString *exe) {
  int pipes[2]; if (pipe(pipes)) return NO;
  posix_spawn_file_actions_t actions; posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipes[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&actions,pipes[0]); posix_spawn_file_actions_addclose(&actions,pipes[1]);
  NSString *user = [NSString stringWithFormat:@"#%u",uid];
  NSString *uid_string = [NSString stringWithFormat:@"%u",uid], *pid_string = @(pid).stringValue, *window_string = @(window).stringValue;
  const char *args[] = {"/bin/launchctl","asuser",uid_string.UTF8String,"/usr/bin/sudo","-n","-u",user.UTF8String,
    self.UTF8String,"--probe",uid_string.UTF8String,pid_string.UTF8String,window_string.UTF8String,exe.UTF8String,NULL};
  posix_spawnattr_t attributes;posix_spawnattr_init(&attributes);
  posix_spawnattr_setflags(&attributes,POSIX_SPAWN_CLOEXEC_DEFAULT);
  posix_spawn_file_actions_addinherit_np(&actions,STDIN_FILENO);
  posix_spawn_file_actions_addinherit_np(&actions,STDERR_FILENO);
  pid_t child=0; int result = posix_spawn(&child,args[0],&actions,&attributes,(char *const *)args,environ);
  posix_spawnattr_destroy(&attributes);
  posix_spawn_file_actions_destroy(&actions); close(pipes[1]);
  if (result) { close(pipes[0]); return NO; }
  fcntl(pipes[0], F_SETFL, O_NONBLOCK); NSMutableData *bytes=[NSMutableData new];
  double end = hid_now_ms()+1000; int status=0; BOOL complete=NO;
  while (hid_now_ms()<end) {
    uint8_t buffer[1024]; ssize_t count;
    while ((count=read(pipes[0],buffer,sizeof(buffer)))>0 && bytes.length<4096) [bytes appendBytes:buffer length:(NSUInteger)count];
    if (bytes.length>=4096) break;
    if (waitpid(child,&status,WNOHANG)==child) { complete=YES; break; }
    std::this_thread::sleep_for(5ms);
  }
  if (!complete) { kill(child,SIGKILL); waitpid(child,&status,0); }
  uint8_t tail[1024]; ssize_t count=read(pipes[0],tail,sizeof(tail));
  if (count>0) [bytes appendBytes:tail length:(NSUInteger)count]; close(pipes[0]);
  id value=bytes.length<=4096 ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
  BOOL ok=complete && WIFEXITED(status) && WEXITSTATUS(status)==0 && [value isKindOfClass:NSDictionary.class] &&
    [value[@"ok"] boolValue] && [value[@"uid"] unsignedIntValue]==uid && [value[@"pid"] intValue]==pid &&
    [value[@"window"] intValue]==window && hid_now_ms()-[value[@"monotonic_ms"] doubleValue]<500;
  log_value(@{@"kind":@"gui_probe",@"ok":@(ok),@"probe":value ?: NSNull.null}); return ok;
}
int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc==2 && !strcmp(argv[1],"--dry-run")) {
      for (int i=0;i<11;i++) log_value(@{@"kind":@"planned_pair",@"dispatch_id":@(i+1),@"key_code":@(codes[i]),@"usage":@(usages[i])});
      return 0;
    }
    if (argc==3 && !strcmp(argv[1],"--source")) {
      uid_t uid=(uid_t)atoi(argv[2]);if(geteuid()!=uid || !console_matches(uid,YES))return 3;
      TISInputSourceRef input=TISCopyCurrentKeyboardInputSource();
      NSString *source=input ? (__bridge NSString *)TISGetInputSourceProperty(input,kTISPropertyInputSourceID) : nil;
      log_value(@{@"kind":@"source_snapshot",@"uid":@(uid),@"input_source":source ?: NSNull.null});
      if(input)CFRelease(input);return source ? 0 : 3;
    }
    if (argc==6 && !strcmp(argv[1],"--probe")) return probe((uid_t)atoi(argv[2]),atoi(argv[3]),atoi(argv[4]),@(argv[5]));
    if (argc!=5 || geteuid()!=0) { fprintf(stderr,"Usage (root): producer SOCKET CONSOLE_UID EXACT_APP_EXECUTABLE COLLECTOR_PID_FILE\n");return 2; }
    NSString *path=@(argv[1]), *exe=@(argv[3]); uid_t uid=(uid_t)atoi(argv[2]);
    char self_path[PROC_PIDPATHINFO_MAXSIZE]={0}; proc_pidpath(getpid(),self_path,sizeof(self_path)); NSString *self=@(self_path);
    struct sockaddr_un address={}; address.sun_family=AF_UNIX;
    if (uid==0 || !console_matches(uid,NO) || path.length>=sizeof(address.sun_path) || ![exe isAbsolutePath]) return 3;
    strlcpy(address.sun_path,path.fileSystemRepresentation,sizeof(address.sun_path));
    int listener=socket(AF_UNIX,SOCK_STREAM,0);
    if (listener<0 || bind(listener,(struct sockaddr *)&address,sizeof(address)) || chmod(path.fileSystemRepresentation,0666) || listen(listener,1)) return 3;
    fcntl(listener,F_SETFL,O_NONBLOCK);fcntl(listener,F_SETFD,FD_CLOEXEC);
    std::signal(SIGINT,[](int){cancelled=true;}); std::signal(SIGTERM,[](int){cancelled=true;});
    pqrs::dispatcher::extra::initialize_shared_dispatcher();
    auto client=std::make_unique<service::client>(); std::atomic<bool> ready(false),failed(false);
    client->connected.connect([&] {service::virtual_hid_keyboard_parameters p;p.set_country_code(pqrs::hid::country_code::us);client->async_virtual_hid_keyboard_initialize(p);});
    client->virtual_hid_keyboard_ready.connect([&](bool value){ready=value;});
    client->closed.connect([&]{failed=true;});client->connect_failed.connect([&](auto&&){failed=true;});
    client->error_occurred.connect([&](auto&&){failed=true;});client->warning_reported.connect([&](auto&&){failed=true;});
    client->driver_version_mismatched.connect([&](bool value){if(value)failed=true;});client->async_start();
    double setup_deadline=hid_now_ms()+15000;
    while(!ready && !failed && !cancelled && hid_now_ms()<setup_deadline) std::this_thread::sleep_for(20ms);
    BOOL ok=ready && !failed && !cancelled;
    if(ok) log_value(@{@"kind":@"ready",@"pid":@(getpid()),@"socket":path});
    int connection=-1, peer_pid=0, window=0, requested=0, reports=0, received=0;
    NSMutableData *buffer=[NSMutableData new]; NSDictionary *pair=nil,*initial_owner=nil;NSMutableSet *nonces=[NSMutableSet new];
    double down_due=0,up_due=0,last_up=0; BOOL down_sent=NO,up_sent=NO;
    while(ok && !failed && !cancelled) {
      @autoreleasepool {
        if(!console_matches(uid,NO)) {ok=NO;break;}
        if(connection<0) {
          connection=accept(listener,NULL,NULL);
          if(connection<0) { if(errno!=EAGAIN && errno!=EWOULDBLOCK)ok=NO; std::this_thread::sleep_for(10ms);continue; }
          socklen_t size=sizeof(peer_pid);getsockopt(connection,SOL_LOCAL,LOCAL_PEERPID,&peer_pid,&size);
          int no_sigpipe=1;setsockopt(connection,SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof(no_sigpipe));
          fcntl(connection,F_SETFL,O_NONBLOCK);fcntl(connection,F_SETFD,FD_CLOEXEC);
          int pid_fd=open(argv[4],O_RDONLY|O_NOFOLLOW|O_NONBLOCK);struct stat pid_info={};char pid_bytes[32]={};
          BOOL pid_file=pid_fd>=0 && !fstat(pid_fd,&pid_info) && S_ISREG(pid_info.st_mode) &&
            pid_info.st_uid==uid && (pid_info.st_mode&0777)==0600 && pid_info.st_size>0 && pid_info.st_size<31;
          ssize_t pid_count=pid_file ? read(pid_fd,pid_bytes,31) : -1;if(pid_fd>=0)close(pid_fd);
          char *pid_end=NULL;long collected_pid=pid_count>0 ? strtol(pid_bytes,&pid_end,10) : 0;
          if(!pid_file || !pid_end || *pid_end || collected_pid!=peer_pid ||
            !hid_peer(connection,uid,peer_pid) || !owned_path(peer_pid,exe)) {ok=NO;break;}
          close(listener);listener=-1;
          log_value(@{@"kind":@"peer",@"pid":@(peer_pid),@"uid":@(uid),@"executable":exe});
        }
        // This independent scheduler releases after 50ms even without any receipt
        // or GPUI ACK. The receipt cannot defer or accelerate a release.
        double now=hid_now_ms();
        if(pair && ((!down_sent && now>=down_due) || (down_sent && !up_sent && now>=up_due))) {
          BOOL down=!down_sent;
          NSDictionary *message=@{@"kind":@"report",@"nonce":pair[@"nonce"],@"dispatch_id":pair[@"dispatch_id"],
            @"key_code":pair[@"key_code"],@"phase":down ? @"down" : @"up",@"monotonic_ms":@(now),@"uptime_ms":@(hid_uptime_ms())};
          if(!hid_write(connection,message)) {ok=NO;break;}
          report::keyboard_input value;if(down)value.keys.insert(usages[requested-1]);client->async_post_report(value);
          log_value(message);reports++;
          if(down) {down_sent=YES;up_due=hid_now_ms()+50;} else {up_sent=YES;last_up=hid_now_ms();}
        }
        BOOL valid=YES;NSDictionary *message=hid_read(connection,buffer,&valid);
        if(!valid) {ok=requested==11 && received==22 && reports==22;break;}
        if(message) {
          if([message[@"kind"] isEqual:@"pair"]) {
            double age=hid_now_ms()-[message[@"monotonic_ms"] doubleValue];
            BOOL valid_pair=requested<11 && received==requested*2 && reports==requested*2 &&
              [message[@"pid"] intValue]==peer_pid && [message[@"dispatch_id"] intValue]==requested+1 &&
              [message[@"key_code"] intValue]==codes[requested] &&
              [message[@"characters"] isEqual:texts()[requested]] && [message[@"ignoring"] isEqual:texts()[requested]] &&
              [message[@"nonce"] isKindOfClass:NSString.class] && [message[@"nonce"] length]==36 && ![nonces containsObject:message[@"nonce"]] &&
              [message[@"host_epoch"] longLongValue]>0 && [message[@"session_epoch"] intValue]>0 &&
              (!initial_owner || ([message[@"host_epoch"] isEqual:initial_owner[@"host_epoch"]] &&
                [message[@"session_epoch"] isEqual:initial_owner[@"session_epoch"]] &&
                [message[@"direct_epoch"] isEqual:initial_owner[@"direct_epoch"]])) &&
              [message[@"key_window"] boolValue] && [message[@"session_active"] boolValue] && ![message[@"direct_text"] boolValue] &&
              [message[@"input_source"] isEqual:@"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"] &&
              [message[@"window"] intValue]>0 && (!window || window==[message[@"window"] intValue]) && age>=0 && age<1000;
            if(!valid_pair || !gui_probe(self,uid,peer_pid,[message[@"window"] intValue],exe)) {ok=NO;log_value(@{@"kind":@"pair_rejected",@"request":message});break;}
            if(!initial_owner)initial_owner=message;[nonces addObject:message[@"nonce"]];
            window=[message[@"window"] intValue];pair=message;requested++;down_sent=up_sent=NO;
            down_due=MAX(hid_now_ms()+20,last_up+150);
            // Both actual fixed report records enter our scheduler before the
            // queue receipt. This is enqueue proof, not OS delivery proof.
            log_value(@{@"kind":@"pair_queued",@"request":pair,@"down_due_ms":@(down_due),@"hold_ms":@50,@"report_count":@2});
            if(!hid_write(connection,@{@"kind":@"queued",@"nonce":pair[@"nonce"],@"dispatch_id":pair[@"dispatch_id"],@"report_count":@2})) {ok=NO;break;}
          } else if([message[@"kind"] isEqual:@"received"]) {
            NSString *phase=received%2 ? @"up" : @"down";
            if(!pair || received>=reports || [message[@"dispatch_id"] intValue]!=(received/2)+1 ||
              ![message[@"nonce"] isEqual:pair[@"nonce"]] || ![message[@"phase"] isEqual:phase] ||
              [message[@"key_code"] intValue]!=codes[received/2]) {ok=NO;break;}
            received++;log_value(message);
          } else {ok=NO;break;}
        }
        std::this_thread::sleep_for(1ms);
      }
    }
    // Always release on exceptional exit; this is cleanup, not an extra key.
    client->async_post_report(report::keyboard_input{});std::this_thread::sleep_for(100ms);
    client->async_virtual_hid_keyboard_terminate();std::this_thread::sleep_for(100ms);
    client.reset();pqrs::dispatcher::extra::terminate_shared_dispatcher();
    if(connection>=0)close(connection);if(listener>=0)close(listener);
    log_value(@{@"kind":@"ended",@"ok":@(ok && !failed && !cancelled),@"pairs_queued":@(requested),@"reports":@(reports),@"received":@(received)});
    return ok && !failed && !cancelled ? 0 : 4;
  }
}
