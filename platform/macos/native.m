#import <AppKit/AppKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <limits.h>
#include <stdio.h>
#include "abi.h"
#include "../macos_text/macos_text.h"

#define GPUI_JSON_EXACT_MAX INT64_C(9007199254740991)
#define GPUI_TEXT_BYTES_MAX 16384
#define GPUI_TEXT_EVENT_BYTES_MAX 16384

#ifdef GPUI_TESTING
#include "ime_timing.h"
#endif

@interface GPWindow : NSObject <NSWindowDelegate>
@property NSWindow *window;
@property CAMetalLayer *surface;
@property int64_t token, sequence;
@property double scale;
@property BOOL closing;
@property BOOL reportedKeyFocus;
@property BOOL directText;
@property int directEpoch;
@property BOOL sessionActive;
@property BOOL sessionAwaitingAck;
@property BOOL batchDelivered;
@property int sessionEpoch;
@property int64_t ownerRevision, lastBatchSequence;
@property int64_t awaitingSequence;
@property NSString *baseText, *visibleText;
@property NSString *acceptedText;
@property NSString *acceptedGeometryText;
@property NSRange selectionRange, markedRange;
@property NSRange sessionBaseSelection, sessionMarkedBaseRange;
@property NSRange acceptedSelection;
@property NSUInteger caretHead, acceptedCaretHead;
@property NSUInteger acceptedGeometryHead;
@property NSRect acceptedCaretRect;
@property BOOL caretRectMatchesVisible;
@property BOOL hasMarkedText;
@property BOOL textDispatchActive, textDispatchCommitted, pendingUnmark;
@property NSString *pendingUnmarkText;
@property NSMutableArray<NSDictionary *> *textCallbacks;
@property NSMutableSet<NSNumber *> *sessionForwardedKeyUps;
@property int deferredTextError;
@property NSRect lastCandidateRect;
@property int64_t completedFrameRevision;
@property NSString *completedFrameSHA256;
@property int64_t lastPresentedBatchSequence, lastPresentedOwnerRevision;
@property NSMutableArray<NSMutableDictionary *> *testingPostedKeys;
@property NSMutableArray<NSMutableDictionary *> *testingReceipts;
@property NSMutableDictionary *testingDispatchReceipt;
@property int64_t testingDispatchId;
@property NSString *testingOriginalInputSource;
@property BOOL testingInputSourceSaved;
@property BOOL testingTextFocusOverride;
@property BOOL testingFocusOverrideEnabled, testingFocusOverride;
#ifdef GPUI_TESTING
@property NSUInteger testingImeDispatchTraceRecordCount;
@property NSUInteger testingImeDispatchTraceRouteRecordCount;
@property int testingImeDispatchTraceSessionEpoch;
@property BOOL testingImeDispatchTraceTruncated;
@property NSUInteger testingImeCallbackObservationId;
#endif
@end
@interface GPView : NSView <NSTextInputClient>
@property(weak) GPWindow *owner;
@property BOOL suppressTextCallbacks;
@property NSEvent *dispatchKeyEvent;
- (void)dispatchKeyDown:(NSEvent *)event testingDispatchId:(int64_t)dispatch_id;
- (void)flushPendingUnmark;
@end

typedef NS_ENUM(NSInteger, GPUIImeCallbackKind) {
  GPUIImeCallbackInsertText = 1,
  GPUIImeCallbackSetMarkedText = 2,
  GPUIImeCallbackUnmarkText = 3,
  GPUIImeCallbackDoCommand = 4,
};
typedef NS_ENUM(NSInteger, GPUIImeCallbackGuard) {
  GPUIImeCallbackGuardNone = 0,
  GPUIImeCallbackGuardNoOwner = 1,
  GPUIImeCallbackGuardClosing = 2,
  GPUIImeCallbackGuardSuppressed = 3,
  GPUIImeCallbackGuardInactiveSession = 4,
  GPUIImeCallbackGuardNoMarkedText = 5,
  GPUIImeCallbackGuardInactiveDispatch = 6,
  GPUIImeCallbackGuardNoDispatchKey = 7,
};
typedef NS_ENUM(NSInteger, GPUIImeCallbackResult) {
  GPUIImeCallbackResultGuardRejected = 1,
  GPUIImeCallbackResultInvalidText = 2,
  GPUIImeCallbackResultInvalidRange = 3,
  GPUIImeCallbackResultInvalidUpdatedText = 4,
  GPUIImeCallbackResultAppendRejected = 5,
  GPUIImeCallbackResultAcceptedCommit = 6,
  GPUIImeCallbackResultAcceptedDirectText = 7,
  GPUIImeCallbackResultAcceptedMarkedText = 8,
  GPUIImeCallbackResultAcceptedEmptyMark = 9,
  GPUIImeCallbackResultQueuedUnmark = 10,
  GPUIImeCallbackResultNoTextTarget = 11,
  GPUIImeCallbackResultForwardedKey = 12,
  GPUIImeCallbackResultForwardUnavailable = 13,
};
#ifdef GPUI_TESTING
typedef NS_ENUM(NSInteger, GPUIImeCommandKind) {
  GPUIImeCommandKindNone = 0,
  GPUIImeCommandKindInsertNewline = 1,
  GPUIImeCommandKindInsertNewlineIgnoringFieldEditor = 2,
  GPUIImeCommandKindNoop = 3,
  GPUIImeCommandKindOther = 4,
};
#endif
typedef struct {
  BOOL owner_present;
  BOOL closing;
  BOOL suppress_callbacks;
  BOOL session_active;
  BOOL direct_text;
  BOOL has_marked_text;
  BOOL text_dispatch_active;
  BOOL session_awaiting_ack;
  BOOL dispatch_key_available;
} GPUIImeCallbackFacts;

static GPUIImeCallbackGuard macos_ime_callback_guard(GPUIImeCallbackKind kind,
                                                     GPUIImeCallbackFacts facts) {
  if (!facts.owner_present) return GPUIImeCallbackGuardNoOwner;
  switch (kind) {
    case GPUIImeCallbackInsertText:
      if (facts.closing) return GPUIImeCallbackGuardClosing;
      if (facts.suppress_callbacks) return GPUIImeCallbackGuardSuppressed;
      return GPUIImeCallbackGuardNone;
    case GPUIImeCallbackSetMarkedText:
      if (facts.closing) return GPUIImeCallbackGuardClosing;
      if (facts.suppress_callbacks) return GPUIImeCallbackGuardSuppressed;
      if (!facts.session_active && !facts.direct_text)
        return GPUIImeCallbackGuardInactiveSession;
      return GPUIImeCallbackGuardNone;
    case GPUIImeCallbackUnmarkText:
      if (facts.suppress_callbacks) return GPUIImeCallbackGuardSuppressed;
      if (!facts.session_active && !facts.direct_text)
        return GPUIImeCallbackGuardInactiveSession;
      if (!facts.has_marked_text) return GPUIImeCallbackGuardNoMarkedText;
      return GPUIImeCallbackGuardNone;
    case GPUIImeCallbackDoCommand:
      if (!facts.session_active) return GPUIImeCallbackGuardInactiveSession;
      if (!facts.text_dispatch_active) return GPUIImeCallbackGuardInactiveDispatch;
      if (!facts.dispatch_key_available) return GPUIImeCallbackGuardNoDispatchKey;
      return GPUIImeCallbackGuardNone;
  }
  return GPUIImeCallbackGuardNoOwner;
}

#ifdef GPUI_TESTING
static GPUIImeCommandKind macos_ime_command_kind(SEL selector) {
  if (!selector) return GPUIImeCommandKindNone;
  if (selector == @selector(insertNewline:)) return GPUIImeCommandKindInsertNewline;
  if (selector == @selector(insertNewlineIgnoringFieldEditor:))
    return GPUIImeCommandKindInsertNewlineIgnoringFieldEditor;
  if (selector == @selector(noop:)) return GPUIImeCommandKindNoop;
  return GPUIImeCommandKindOther;
}
#endif
static GPUIImeCallbackFacts macos_ime_callback_facts(GPView *view, GPWindow *owner) {
  return (GPUIImeCallbackFacts){
    .owner_present = owner != nil,
    .closing = owner && owner.closing,
    .suppress_callbacks = view && view.suppressTextCallbacks,
    .session_active = owner && owner.sessionActive,
    .direct_text = owner && owner.directText,
    .has_marked_text = owner && owner.hasMarkedText,
    .text_dispatch_active = owner && owner.textDispatchActive,
    .session_awaiting_ack = owner && owner.sessionAwaitingAck,
    .dispatch_key_available = view && view.dispatchKeyEvent != nil,
  };
}
static NSMutableDictionary<NSNumber *, GPWindow *> *windows;
static NSMutableArray<NSDictionary *> *events;
static NSDictionary *current;
static id<MTLDevice> device;
static id<MTLCommandQueue> queue;
static id<MTLRenderPipelineState> pipeline;
static id<MTLTexture> white_mask_texture;
static int64_t next_token, result_token, host_epoch;
static NSData *text_result;
static int state; // 0 uninitialized/stopped, 1 running, 2 quiescing
static BOOL overflow;
#ifdef GPUI_TESTING
static NSData *frame_pixels;
static NSUInteger frame_width, frame_height, frame_stride;
static double test_scale_override;

static BOOL macos_ime_style_trace_enabled(GPView *view, GPWindow *owner) {
  id value = NSProcessInfo.processInfo.environment[@"GPUI_FIELD_MACOS_IME_STYLE_TRACE"];
  return view && owner && view.owner == owner && owner.sessionActive && !owner.closing &&
    [value isKindOfClass:NSString.class] && [value isEqualToString:@"1"];
}

static void trace_macos_ime_styles(GPView *view, NSUInteger text_utf16_length,
                                  NSArray<NSDictionary *> *runs, BOOL truncated) {
  id key_code = view.dispatchKeyEvent ? @(view.dispatchKeyEvent.keyCode) : NSNull.null;
  NSDictionary *record = @{
    @"text_utf16_length": @(text_utf16_length),
    @"dispatch_key_code": key_code,
    @"underline_runs": runs,
    @"underline_runs_truncated": @(truncated),
  };
  NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingFragmentsAllowed
                                                    error:nil];
  if (!json || !json.length) return;
  fputs("GPUI_MACOS_IME_STYLE_TRACE ", stderr);
  (void)fwrite(json.bytes, 1, json.length, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

#define GPUI_IME_DISPATCH_TRACE_LIMIT 64
#define GPUI_IME_DISPATCH_TRACE_ROUTE_RESERVE 2
#define GPUI_IME_DISPATCH_TRACE_TRUNCATION_RESERVE 1
#define GPUI_IME_DISPATCH_TRACE_ORDINARY_LIMIT \
  (GPUI_IME_DISPATCH_TRACE_LIMIT - GPUI_IME_DISPATCH_TRACE_ROUTE_RESERVE - \
   GPUI_IME_DISPATCH_TRACE_TRUNCATION_RESERVE)
#ifdef GPUI_TESTING
typedef struct {
  BOOL opt_in;
  BOOL has_view;
  BOOL has_owner;
  BOOL view_owns_owner;
  BOOL content_view_matches;
  BOOL fixture_source_saved;
  BOOL matching_synthetic_receipt;
  BOOL trace_session_initialized;
  BOOL owner_closing;
  BOOL session_active;
} GPUIImeCallbackTraceGateFacts;

static BOOL macos_ime_callback_trace_gate_allows(GPUIImeCallbackTraceGateFacts facts) {
  // Session-active and closing are deliberately absent: those are body guard
  // facts to observe, not diagnostic ownership conditions.
  return facts.opt_in && facts.has_view && facts.has_owner && facts.view_owns_owner &&
    facts.content_view_matches && facts.fixture_source_saved &&
    facts.matching_synthetic_receipt && facts.trace_session_initialized;
}

static const char *macos_ime_callback_kind_name(GPUIImeCallbackKind kind) {
  switch (kind) {
    case GPUIImeCallbackInsertText: return "insert_text";
    case GPUIImeCallbackSetMarkedText: return "set_marked_text";
    case GPUIImeCallbackUnmarkText: return "unmark_text";
    case GPUIImeCallbackDoCommand: return "do_command_by_selector";
  }
  return "unknown";
}

static const char *macos_ime_callback_guard_name(GPUIImeCallbackGuard guard) {
  switch (guard) {
    case GPUIImeCallbackGuardNone: return "none";
    case GPUIImeCallbackGuardNoOwner: return "no_owner";
    case GPUIImeCallbackGuardClosing: return "owner_closing";
    case GPUIImeCallbackGuardSuppressed: return "callbacks_suppressed";
    case GPUIImeCallbackGuardInactiveSession: return "session_inactive";
    case GPUIImeCallbackGuardNoMarkedText: return "no_marked_text";
    case GPUIImeCallbackGuardInactiveDispatch: return "text_dispatch_inactive";
    case GPUIImeCallbackGuardNoDispatchKey: return "dispatch_key_unavailable";
  }
  return "unknown";
}

static const char *macos_ime_callback_result_name(GPUIImeCallbackResult result) {
  switch (result) {
    case GPUIImeCallbackResultGuardRejected: return "guard_rejected";
    case GPUIImeCallbackResultInvalidText: return "invalid_text";
    case GPUIImeCallbackResultInvalidRange: return "invalid_range";
    case GPUIImeCallbackResultInvalidUpdatedText: return "invalid_updated_text";
    case GPUIImeCallbackResultAppendRejected: return "append_rejected";
    case GPUIImeCallbackResultAcceptedCommit: return "accepted_commit";
    case GPUIImeCallbackResultAcceptedDirectText: return "accepted_direct_text";
    case GPUIImeCallbackResultAcceptedMarkedText: return "accepted_marked_text";
    case GPUIImeCallbackResultAcceptedEmptyMark: return "accepted_empty_mark";
    case GPUIImeCallbackResultQueuedUnmark: return "queued_unmark";
    case GPUIImeCallbackResultNoTextTarget: return "no_text_target";
    case GPUIImeCallbackResultForwardedKey: return "forwarded_key";
    case GPUIImeCallbackResultForwardUnavailable: return "forward_unavailable";
  }
  return "unknown";
}

static const char *macos_ime_command_kind_name(GPUIImeCommandKind kind) {
  switch (kind) {
    case GPUIImeCommandKindNone: return "none";
    case GPUIImeCommandKindInsertNewline: return "insert_newline";
    case GPUIImeCommandKindInsertNewlineIgnoringFieldEditor:
      return "insert_newline_ignoring_field_editor";
    case GPUIImeCommandKindNoop: return "noop";
    case GPUIImeCommandKindOther: return "other";
  }
  return "other";
}
#endif

static BOOL macos_ime_dispatch_trace_enabled(GPView *view, GPWindow *owner) {
  id value = NSProcessInfo.processInfo.environment[@"GPUI_FIELD_MACOS_IME_DISPATCH_TRACE"];
  if (!view || !owner || view.owner != owner || !owner.sessionActive || owner.closing ||
      ![value isKindOfClass:NSString.class] || ![value isEqualToString:@"1"]) return NO;
  if (owner.testingImeDispatchTraceSessionEpoch != owner.sessionEpoch) {
    owner.testingImeDispatchTraceSessionEpoch = owner.sessionEpoch;
    owner.testingImeDispatchTraceRecordCount = 0;
    owner.testingImeDispatchTraceRouteRecordCount = 0;
    owner.testingImeDispatchTraceTruncated = NO;
    owner.testingImeCallbackObservationId = 0;
  }
  return YES;
}

static BOOL macos_ime_dispatch_trace_record_is_bounded(NSDictionary *record) {
  NSSet *phases = [NSSet setWithArray:@[@"dispatch", @"callback", @"batch", @"truncated"]];
  NSSet *kinds = [NSSet setWithArray:@[@"down", @"up", @"commit", @"text_session", @"record_limit"]];
  NSSet *keys = [NSSet setWithArray:@[
    @"phase", @"kind", @"session_epoch", @"dispatch_id", @"key_code",
    @"down_dispatched", @"up_dispatched", @"batch_sequence", @"window_sequence",
    @"text_utf16_length", @"text_dispatch_active", @"session_awaiting_ack",
    @"commit_callback_count", @"record_limit",
  ]];
  for (id key in record) {
    if (![keys containsObject:key]) return NO;
    id value = record[key];
    if ([key isEqual:@"phase"]) {
      if (![value isKindOfClass:NSString.class] || ![phases containsObject:value]) return NO;
    } else if ([key isEqual:@"kind"]) {
      if (![value isKindOfClass:NSString.class] || ![kinds containsObject:value]) return NO;
    } else if (value != NSNull.null && ![value isKindOfClass:NSNumber.class]) {
      return NO;
    }
  }
  return YES;
}

static void emit_macos_ime_dispatch_trace_line(NSDictionary *record) {
  if (!macos_ime_dispatch_trace_record_is_bounded(record)) return;
  NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingFragmentsAllowed
                                                    error:nil];
  if (!json || !json.length) return;
  fputs("GPUI_MACOS_IME_DISPATCH_TRACE ", stderr);
  (void)fwrite(json.bytes, 1, json.length, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

#ifdef GPUI_TESTING
typedef NS_ENUM(NSInteger, GPUIImeTraceSlotDecision) {
  GPUIImeTraceSlotBlocked = 0,
  GPUIImeTraceSlotGranted = 1,
  GPUIImeTraceSlotTruncated = 2,
};
static GPUIImeTraceSlotDecision macos_ime_dispatch_trace_claim_slot(NSUInteger *count,
                                                                    BOOL *truncated) {
  if (!count || !truncated) return GPUIImeTraceSlotBlocked;
  if (*count < GPUI_IME_DISPATCH_TRACE_ORDINARY_LIMIT) {
    (*count)++;
    return GPUIImeTraceSlotGranted;
  }
  if (!*truncated && *count < GPUI_IME_DISPATCH_TRACE_LIMIT) {
    (*count)++;
    *truncated = YES;
    return GPUIImeTraceSlotTruncated;
  }
  return GPUIImeTraceSlotBlocked;
}
static BOOL macos_ime_dispatch_trace_route_slot_available(NSUInteger route_count,
                                                          NSUInteger record_count) {
  return route_count < GPUI_IME_DISPATCH_TRACE_ROUTE_RESERVE &&
    record_count < GPUI_IME_DISPATCH_TRACE_LIMIT;
}

static BOOL macos_ime_callback_trace_record_is_bounded(NSDictionary *record) {
  NSSet *stages = [NSSet setWithArray:@[@"scope", @"entry", @"result"]];
  NSSet *callbacks = [NSSet setWithArray:@[
    @"scope", @"insert_text", @"set_marked_text", @"unmark_text", @"do_command_by_selector",
  ]];
  NSSet *guards = [NSSet setWithArray:@[
    @"none", @"no_owner", @"owner_closing", @"callbacks_suppressed",
          @"session_inactive", @"no_marked_text", @"text_dispatch_inactive",
    @"dispatch_key_unavailable",
  ]];
  NSSet *results = [NSSet setWithArray:@[
    @"guard_rejected", @"invalid_text", @"invalid_range", @"invalid_updated_text",
    @"append_rejected", @"accepted_commit", @"accepted_direct_text",
    @"accepted_marked_text", @"accepted_empty_mark", @"queued_unmark",
    @"no_text_target", @"forwarded_key", @"forward_unavailable",
  ]];
  NSSet *commands = [NSSet setWithArray:@[
    @"none", @"insert_newline", @"insert_newline_ignoring_field_editor", @"noop", @"other",
  ]];
  NSSet *keys = [NSSet setWithArray:@[
    @"schema_version", @"stage", @"callback_kind", @"observation_id",
    @"route_dispatch_id", @"host_epoch", @"session_epoch", @"current_key_code",
    @"scope_armed", @"scope_reason", @"fixture_source_saved", @"receipt_matches",
    @"owner_closing", @"session_active", @"direct_text", @"suppress_callbacks",
    @"text_dispatch_active", @"session_awaiting_ack", @"has_marked_text",
    @"guard_reason", @"result", @"selector_kind",
  ]];
  for (id key in record) {
    if (![keys containsObject:key]) return NO;
    id value = record[key];
    if ([key isEqual:@"stage"]) {
      if (![value isKindOfClass:NSString.class] || ![stages containsObject:value]) return NO;
    } else if ([key isEqual:@"callback_kind"]) {
      if (![value isKindOfClass:NSString.class] || ![callbacks containsObject:value]) return NO;
    } else if ([key isEqual:@"scope_reason"]) {
      if (value != NSNull.null && (![value isKindOfClass:NSString.class] ||
          ![@[@"ready", @"fixture_source_not_saved", @"receipt_not_matching",
               @"trace_session_uninitialized", @"ownership_unavailable", @"trace_disabled"]
            containsObject:value])) return NO;
    } else if ([key isEqual:@"guard_reason"]) {
      if (value != NSNull.null && (![value isKindOfClass:NSString.class] ||
          ![guards containsObject:value])) return NO;
    } else if ([key isEqual:@"result"]) {
      if (value != NSNull.null && (![value isKindOfClass:NSString.class] || ![results containsObject:value])) return NO;
    } else if ([key isEqual:@"selector_kind"]) {
      if (![value isKindOfClass:NSString.class] || ![commands containsObject:value]) return NO;
    } else if (value != NSNull.null && ![value isKindOfClass:NSNumber.class]) {
      return NO;
    }
  }
  return record.count == keys.count;
}

static void emit_macos_ime_callback_trace_line(NSDictionary *record) {
  if (!macos_ime_callback_trace_record_is_bounded(record)) return;
  NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingFragmentsAllowed
                                                    error:nil];
  if (!json || !json.length) return;
  fputs("GPUI_MACOS_IME_CALLBACK_DIAGNOSTIC_TRACE ", stderr);
  (void)fwrite(json.bytes, 1, json.length, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

static BOOL macos_ime_callback_receipt_matches(GPWindow *owner) {
  NSDictionary *receipt = owner.testingDispatchReceipt;
  if (![receipt isKindOfClass:NSDictionary.class]) return NO;
  return [receipt[@"dispatch_id"] longLongValue] > 0 &&
    [receipt[@"host_epoch"] longLongValue] == host_epoch &&
    [receipt[@"session_epoch"] intValue] == owner.sessionEpoch &&
    [receipt[@"down_posted"] boolValue] && [receipt[@"up_posted"] boolValue];
}

static GPUIImeCallbackTraceGateFacts macos_ime_callback_trace_gate_facts(GPView *view,
                                                                        GPWindow *owner) {
  id opt_in = NSProcessInfo.processInfo.environment[@"GPUI_FIELD_MACOS_IME_DISPATCH_TRACE"];
  BOOL trace_opted_in = [opt_in isKindOfClass:NSString.class] && [opt_in isEqualToString:@"1"];
  BOOL owns_view = view && owner && view.owner == owner;
  BOOL content_matches = owns_view && owner.window.contentView == view;
  BOOL saved_source = owner && owner.testingInputSourceSaved;
  BOOL receipt_matches = owner && macos_ime_callback_receipt_matches(owner);

  // Initialize the existing per-session budget only while the real session is
  // active. A later inactive/closing callback can use its already established
  // marker, but cannot create a fresh attribution context after teardown.
  if (trace_opted_in && owns_view && content_matches && saved_source && receipt_matches &&
      owner.sessionActive && !owner.closing &&
      owner.testingImeDispatchTraceSessionEpoch != owner.sessionEpoch) {
    (void)macos_ime_dispatch_trace_enabled(view, owner);
  }
  return (GPUIImeCallbackTraceGateFacts){
    .opt_in = trace_opted_in,
    .has_view = view != nil,
    .has_owner = owner != nil,
    .view_owns_owner = owns_view,
    .content_view_matches = content_matches,
    .fixture_source_saved = saved_source,
    .matching_synthetic_receipt = receipt_matches,
    .trace_session_initialized = owner &&
      owner.testingImeDispatchTraceSessionEpoch == owner.sessionEpoch,
    .owner_closing = owner && owner.closing,
    .session_active = owner && owner.sessionActive,
  };
}

static const char *macos_ime_callback_trace_gate_reason(GPUIImeCallbackTraceGateFacts facts) {
  if (!facts.opt_in) return "trace_disabled";
  if (!facts.has_view || !facts.has_owner || !facts.view_owns_owner || !facts.content_view_matches)
    return "ownership_unavailable";
  if (!facts.fixture_source_saved) return "fixture_source_not_saved";
  if (!facts.matching_synthetic_receipt) return "receipt_not_matching";
  if (!facts.trace_session_initialized) return "trace_session_uninitialized";
  return "ready";
}

static BOOL macos_ime_callback_trace_gate_ready(GPUIImeCallbackTraceGateFacts facts) {
  return macos_ime_callback_trace_gate_allows(facts);
}

static NSDictionary *macos_ime_callback_trace_scope_record(
    GPUIImeCallbackTraceGateFacts gate, int64_t route_dispatch_id,
    int64_t event_host_epoch, int session_epoch, GPUIImeCallbackFacts facts) {
  return @{
    @"schema_version": @1,
    @"stage": @"scope",
    @"callback_kind": @"scope",
    @"observation_id": NSNull.null,
    @"route_dispatch_id": @(route_dispatch_id),
    @"host_epoch": @(event_host_epoch),
    @"session_epoch": @(session_epoch),
    @"current_key_code": @36,
    @"scope_armed": @(macos_ime_callback_trace_gate_ready(gate)),
    @"scope_reason": [NSString stringWithUTF8String:macos_ime_callback_trace_gate_reason(gate)],
    @"fixture_source_saved": @(gate.fixture_source_saved),
    @"receipt_matches": @(gate.matching_synthetic_receipt),
    @"owner_closing": @(facts.closing),
    @"session_active": @(facts.session_active),
    @"direct_text": @(facts.direct_text),
    @"suppress_callbacks": @(facts.suppress_callbacks),
    @"text_dispatch_active": @(facts.text_dispatch_active),
    @"session_awaiting_ack": @(facts.session_awaiting_ack),
    @"has_marked_text": @(facts.has_marked_text),
    @"guard_reason": @"none",
    @"result": NSNull.null,
    @"selector_kind": @"none",
  };
}

static NSDictionary *macos_ime_callback_trace_entry_record(
    GPUIImeCallbackKind kind, GPUIImeCommandKind selector_kind,
    NSUInteger observation_id, NSNumber *current_key_code,
    int64_t event_host_epoch, int session_epoch,
    GPUIImeCallbackTraceGateFacts gate, GPUIImeCallbackFacts facts) {
  return @{
    @"schema_version": @1,
    @"stage": @"entry",
    @"callback_kind": [NSString stringWithUTF8String:macos_ime_callback_kind_name(kind)],
    @"observation_id": @(observation_id),
    @"route_dispatch_id": NSNull.null,
    @"host_epoch": @(event_host_epoch),
    @"session_epoch": @(session_epoch),
    @"current_key_code": current_key_code ?: NSNull.null,
    @"scope_armed": @(macos_ime_callback_trace_gate_ready(gate)),
    @"scope_reason": [NSString stringWithUTF8String:macos_ime_callback_trace_gate_reason(gate)],
    @"fixture_source_saved": @(gate.fixture_source_saved),
    @"receipt_matches": @(gate.matching_synthetic_receipt),
    @"owner_closing": @(facts.closing),
    @"session_active": @(facts.session_active),
    @"direct_text": @(facts.direct_text),
    @"suppress_callbacks": @(facts.suppress_callbacks),
    @"text_dispatch_active": @(facts.text_dispatch_active),
    @"session_awaiting_ack": @(facts.session_awaiting_ack),
    @"has_marked_text": @(facts.has_marked_text),
    @"guard_reason": NSNull.null,
    @"result": NSNull.null,
    @"selector_kind": [NSString stringWithUTF8String:macos_ime_command_kind_name(selector_kind)],
  };
}

static BOOL macos_ime_dispatch_trace_claim_ordinary_slot(GPWindow *owner) {
  NSUInteger record_count = owner.testingImeDispatchTraceRecordCount;
  BOOL truncated = owner.testingImeDispatchTraceTruncated;
  GPUIImeTraceSlotDecision decision = macos_ime_dispatch_trace_claim_slot(
    &record_count, &truncated);
  owner.testingImeDispatchTraceRecordCount = record_count;
  owner.testingImeDispatchTraceTruncated = truncated;
  if (decision == GPUIImeTraceSlotGranted) return YES;
  if (decision == GPUIImeTraceSlotTruncated) {
    emit_macos_ime_dispatch_trace_line(@{
      @"phase": @"truncated", @"kind": @"record_limit",
      @"session_epoch": @(owner.sessionEpoch),
      @"record_limit": @(GPUI_IME_DISPATCH_TRACE_LIMIT),
    });
  }
  return NO;
}

static NSDictionary *macos_ime_callback_trace_begin(GPView *view, GPWindow *owner,
                                                    GPUIImeCallbackKind kind,
                                                    GPUIImeCommandKind selector_kind) {
  ime_timing_record([NSString stringWithUTF8String:macos_ime_callback_kind_name(kind)]);
  GPUIImeCallbackTraceGateFacts gate = macos_ime_callback_trace_gate_facts(view, owner);
  if (!macos_ime_callback_trace_gate_ready(gate) ||
      !macos_ime_dispatch_trace_claim_ordinary_slot(owner)) return nil;
  owner.testingImeCallbackObservationId++;
  GPUIImeCallbackFacts facts = macos_ime_callback_facts(view, owner);
  NSDictionary *snapshot = macos_ime_callback_trace_entry_record(
    kind, selector_kind, owner.testingImeCallbackObservationId,
    view.dispatchKeyEvent ? @(view.dispatchKeyEvent.keyCode) : nil,
    host_epoch, owner.sessionEpoch, gate, facts);
  NSMutableDictionary *entry = [snapshot mutableCopy];
  entry[@"result"] = NSNull.null;
  if (!macos_ime_callback_trace_record_is_bounded(entry)) return nil;
  emit_macos_ime_callback_trace_line(entry);
  return snapshot;
}

static NSDictionary *macos_ime_callback_trace_result_record(NSDictionary *snapshot,
                                                           GPUIImeCallbackGuard guard,
                                                           GPUIImeCallbackResult result) {
  if (!snapshot) return nil;
  NSMutableDictionary *record = [snapshot mutableCopy];
  record[@"stage"] = @"result";
  record[@"guard_reason"] = [NSString stringWithUTF8String:macos_ime_callback_guard_name(guard)];
  record[@"result"] = [NSString stringWithUTF8String:macos_ime_callback_result_name(result)];
  return macos_ime_callback_trace_record_is_bounded(record) ? [record copy] : nil;
}

static void macos_ime_callback_trace_result(GPWindow *owner, NSDictionary *snapshot,
                                            GPUIImeCallbackGuard guard,
                                            GPUIImeCallbackResult result) {
  if (!owner || !snapshot) return;
  NSDictionary *record = macos_ime_callback_trace_result_record(snapshot, guard, result);
  if (!record) return;
  if (!macos_ime_dispatch_trace_claim_ordinary_slot(owner)) return;
  emit_macos_ime_callback_trace_line(record);
}

static void trace_macos_ime_callback_scope(GPView *view, GPWindow *owner,
                                           int64_t route_dispatch_id) {
  if (!view || !owner || route_dispatch_id <= 0 ||
      !macos_ime_dispatch_trace_enabled(view, owner)) return;
  GPUIImeCallbackTraceGateFacts gate = macos_ime_callback_trace_gate_facts(view, owner);
  NSDictionary *record = macos_ime_callback_trace_scope_record(
    gate, route_dispatch_id, host_epoch, owner.sessionEpoch,
    macos_ime_callback_facts(view, owner));
  if (!macos_ime_callback_trace_record_is_bounded(record) ||
      !macos_ime_dispatch_trace_claim_ordinary_slot(owner)) return;
  emit_macos_ime_callback_trace_line(record);
}
#endif

static BOOL macos_ime_return_route_trace_record_is_bounded(NSDictionary *record) {
  NSSet *phases = [NSSet setWithArray:@[@"return_route_begin", @"return_route_result"]];
  NSSet *keys = [NSSet setWithArray:@[
    @"schema_version", @"phase", @"session_epoch", @"dispatch_id", @"key_code",
    @"input_context_available", @"input_context_handled", @"interpret_fallback_invoked", @"last_batch_sequence",
    @"window_sequence", @"awaiting_sequence", @"last_presented_batch_sequence",
    @"session_awaiting_ack", @"batch_delivered", @"text_dispatch_active",
    @"deferred_text_error",
  ]];
  for (id key in record) {
    if (![keys containsObject:key]) return NO;
    id value = record[key];
    if ([key isEqual:@"phase"]) {
      if (![value isKindOfClass:NSString.class] || ![phases containsObject:value]) return NO;
    } else if (value != NSNull.null && ![value isKindOfClass:NSNumber.class]) {
      return NO;
    }
  }
  return record.count == keys.count;
}

// Keep the Return route markers in the two trace slots reserved above. The
// dispatch trace and this opt-in diagnostic share one per-session 64-record
// budget; no callback contents or user text are included.
static void trace_macos_ime_return_route(GPView *view, GPWindow *owner,
                                        NSString *phase, int64_t dispatch_id,
                                        NSNumber *input_context_available,
                                        NSNumber *input_context_handled,
                                        NSNumber *interpret_fallback_invoked) {
  if (!macos_ime_dispatch_trace_enabled(view, owner) ||
      dispatch_id <= 0 ||
      !macos_ime_dispatch_trace_route_slot_available(
        owner.testingImeDispatchTraceRouteRecordCount, owner.testingImeDispatchTraceRecordCount)) return;
  NSDictionary *record = @{
    @"schema_version": @1,
    @"phase": phase,
    @"session_epoch": @(owner.sessionEpoch),
    @"dispatch_id": @(dispatch_id),
    @"key_code": @36,
    @"input_context_available": input_context_available ?: NSNull.null,
    @"input_context_handled": input_context_handled ?: NSNull.null,
    @"interpret_fallback_invoked": interpret_fallback_invoked ?: NSNull.null,
    @"last_batch_sequence": @(owner.lastBatchSequence),
    @"window_sequence": @(owner.sequence),
    @"awaiting_sequence": @(owner.awaitingSequence),
    @"last_presented_batch_sequence": @(owner.lastPresentedBatchSequence),
    @"session_awaiting_ack": @(owner.sessionAwaitingAck),
    @"batch_delivered": @(owner.batchDelivered),
    @"text_dispatch_active": @(owner.textDispatchActive),
    @"deferred_text_error": @(owner.deferredTextError),
  };
  if (!macos_ime_return_route_trace_record_is_bounded(record)) return;
  owner.testingImeDispatchTraceRouteRecordCount++;
  owner.testingImeDispatchTraceRecordCount++;
  NSData *json = [NSJSONSerialization dataWithJSONObject:record
                                                  options:NSJSONWritingFragmentsAllowed
                                                    error:nil];
  if (!json || !json.length) return;
  fputs("GPUI_MACOS_IME_DIAGNOSTIC_TRACE ", stderr);
  (void)fwrite(json.bytes, 1, json.length, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

// Phase and kind are fixed literals; every other emitted value is numeric,
// boolean, or null. This trace deliberately excludes callback contents.
static void trace_macos_ime_dispatch(GPView *view, GPWindow *owner,
                                     NSString *phase, NSString *kind,
                                     NSNumber *dispatch_id, NSNumber *key_code,
                                     NSNumber *down_dispatched, NSNumber *up_dispatched,
                                     NSNumber *batch_sequence, NSNumber *window_sequence,
                                     NSNumber *text_utf16_length,
                                     NSNumber *text_dispatch_active,
                                     NSNumber *session_awaiting_ack,
                                     NSNumber *commit_callback_count) {
  if (!macos_ime_dispatch_trace_enabled(view, owner)) return;
  if (!macos_ime_dispatch_trace_claim_ordinary_slot(owner)) return;
  emit_macos_ime_dispatch_trace_line(@{
    @"phase": phase, @"kind": kind,
    @"session_epoch": @(owner.sessionEpoch),
    @"dispatch_id": dispatch_id ?: NSNull.null,
    @"key_code": key_code ?: NSNull.null,
    @"down_dispatched": down_dispatched ?: NSNull.null,
    @"up_dispatched": up_dispatched ?: NSNull.null,
    @"batch_sequence": batch_sequence ?: NSNull.null,
    @"window_sequence": window_sequence ?: NSNull.null,
    @"text_utf16_length": text_utf16_length ?: NSNull.null,
    @"text_dispatch_active": text_dispatch_active ?: NSNull.null,
    @"session_awaiting_ack": session_awaiting_ack ?: NSNull.null,
    @"commit_callback_count": commit_callback_count ?: NSNull.null,
  });
}
#endif
static BOOL key_window_owns_view(GPWindow *w);
static void request_application_activation(void) {
  if (@available(macOS 14.0, *)) {
    [NSApp activate];
    return;
  }
  NSRunningApplication *application = [NSRunningApplication currentApplication];
  if (application) (void)[application activateWithOptions:NSApplicationActivateAllWindows];
}
static BOOL valid_text_string(NSString *text, NSData **utf8_out) {
  if (![text isKindOfClass:NSString.class] || text.length > GPUI_TEXT_BYTES_MAX) return NO;
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    if (c == 0 || c == '\n' || c == '\r' || c == 0x2028 || c == 0x2029 ||
        c < 0x20 || (c >= 0x7f && c <= 0x9f)) return NO;
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= text.length) return NO;
      unichar low = [text characterAtIndex:++i];
      if (low < 0xDC00 || low > 0xDFFF) return NO;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return NO;
    }
  }
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  if (!data || data.length > GPUI_TEXT_BYTES_MAX) return NO;
  if (utf8_out) *utf8_out = data;
  return YES;
}
static BOOL scalar_boundary(NSString *text, NSUInteger offset) {
  if (offset > text.length) return NO;
  if (offset == 0 || offset == text.length) return YES;
  unichar previous = [text characterAtIndex:offset - 1];
  unichar next = [text characterAtIndex:offset];
  return !(previous >= 0xD800 && previous <= 0xDBFF && next >= 0xDC00 && next <= 0xDFFF);
}
static BOOL grapheme_boundary(NSString *text, NSUInteger offset) {
  if (offset > text.length) return NO;
  CFStringRef value = (__bridge CFStringRef)text;
  if (offset > 0) {
    CFRange previous = CFStringGetRangeOfComposedCharactersAtIndex(value, (CFIndex)offset - 1);
    if (previous.location + previous.length != (CFIndex)offset) return NO;
  }
  if (offset < text.length) {
    CFRange next = CFStringGetRangeOfComposedCharactersAtIndex(value, (CFIndex)offset);
    if (next.location != (CFIndex)offset) return NO;
  }
  return YES;
}
static BOOL valid_range_for_text(NSRange range, NSString *text) {
  return range.location != NSNotFound && range.location <= text.length &&
    range.length <= text.length - range.location && scalar_boundary(text, range.location) &&
    scalar_boundary(text, NSMaxRange(range)) && grapheme_boundary(text, range.location) &&
    grapheme_boundary(text, NSMaxRange(range));
}
static id json_range(NSRange range, BOOL present) {
  return present ? @[@(range.location), @(NSMaxRange(range))] : NSNull.null;
}
static void purge_window_events(GPWindow *w, int kind) {
  if (!events || !w) return;
  NSIndexSet *indices = [events indexesOfObjectsPassingTest:^BOOL(NSDictionary *event, NSUInteger index, BOOL *stop) {
    (void)index; (void)stop;
    return [event[@"token"] longLongValue] == w.token &&
      (kind < 0 || [event[@"kind"] intValue] == kind);
  }];
  [events removeObjectsAtIndexes:indices];
}
static void emit_event(GPWindow *w, int kind, double x, double y, int mods,
                       int code, int repeat, NSData *text, int direct_epoch) {
  if (w.closing && kind != 13) return;
  if (events.count >= 4096) { overflow = YES; return; }
  if (w && (w.sequence >= GPUI_JSON_EXACT_MAX || w.sequence < 0)) {
    overflow = YES;
    w.deferredTextError = 13;
    return;
  }
  int64_t sequence = w ? ++w.sequence : 0;
  NSMutableDictionary *record = [@{@"kind":@(kind), @"token":@(w ? w.token : 0), @"seq":@(sequence),
    @"scale":@(w ? w.scale : 1), @"x":@(x), @"y":@(y), @"mods":@(mods), @"code":@(code), @"repeat":@(repeat),
    @"width":@(w ? w.window.contentView.bounds.size.width : 0), @"height":@(w ? w.window.contentView.bounds.size.height : 0)} mutableCopy];
  if (text) record[@"text"] = text;
  if (kind == 16) record[@"direct_epoch"] = @(direct_epoch);
  else if (w && w.directText && (kind == 10 || kind == 11)) record[@"direct_epoch"] = @(w.directEpoch);
  [events addObject:record];
}
static void emit(GPWindow *w, int kind, double x, double y, int mods, int code, int repeat) {
  emit_event(w, kind, x, y, mods, code, repeat, nil, 0);
}
static void invalidate_direct_text(GPWindow *w) {
  w.directText = NO;
  if (w.directEpoch < INT_MAX) w.directEpoch++;
  else w.deferredTextError = 13;
  purge_window_events(w, 16);
  purge_window_events(w, 10);
  purge_window_events(w, 11);
}
static void discard_marked_input_state(GPWindow *w) {
  GPView *view = w ? (GPView *)w.window.contentView : nil;
  if (!view) return;
  view.suppressTextCallbacks = YES;
  [view.inputContext discardMarkedText];
  view.suppressTextCallbacks = NO;
}
static void fail_text_session(GPWindow *w, int error) {
  w.deferredTextError = error ? error : 17;
  w.sessionActive = NO;
  w.sessionAwaitingAck = NO;
  w.batchDelivered = NO;
  w.hasMarkedText = NO;
  w.markedRange = NSMakeRange(NSNotFound, 0);
  w.pendingUnmark = NO;
  w.textDispatchActive = NO;
  w.textCallbacks = nil;
  purge_window_events(w, 18);
  discard_marked_input_state(w);
  if (w.acceptedText) {
    w.baseText = w.acceptedText;
    w.visibleText = w.acceptedText;
    w.selectionRange = w.acceptedSelection;
    w.sessionBaseSelection = w.acceptedSelection;
    w.caretHead = w.acceptedCaretHead;
    w.acceptedGeometryText = w.acceptedText;
    w.acceptedGeometryHead = w.acceptedCaretHead;
    w.caretRectMatchesVisible = YES;
  }
}
static BOOL append_text_callback(GPWindow *w, NSDictionary *callback) {
  if (!w.sessionActive || w.closing || ![callback isKindOfClass:NSDictionary.class]) return NO;
  // AppKit may deliver delayed NSTextInputClient callbacks outside the key
  // dispatch that produced the previous batch. Never let one overwrite an
  // outstanding sequence: the owner must present and ACK before another
  // native input dispatch can advance the mirror.
  if (w.sessionAwaitingAck) {
    fail_text_session(w, 12);
    return NO;
  }
  if (!w.textDispatchActive) {
    w.textDispatchActive = YES;
    w.textDispatchCommitted = NO;
    w.textCallbacks = [NSMutableArray new];
  }
  if (w.textCallbacks.count >= 64) {
    fail_text_session(w, 13);
    return NO;
  }
  [w.textCallbacks addObject:[callback copy]];
  return YES;
}
static void flush_text_batch(GPWindow *w) {
  if (!w.textDispatchActive) return;
  NSArray *callbacks = [w.textCallbacks copy] ?: @[];
  w.textDispatchActive = NO;
  w.textCallbacks = nil;
  if (!w.sessionActive || w.closing || !callbacks.count) return;
  if (w.sequence >= GPUI_JSON_EXACT_MAX || w.lastBatchSequence >= GPUI_JSON_EXACT_MAX) {
    fail_text_session(w, 13);
    return;
  }
  int64_t sequence = w.sequence + 1;
  NSDictionary *batch = @{
    @"window": @(w.token), @"host_epoch": @(host_epoch), @"epoch": @(w.sessionEpoch),
    @"sequence": @(sequence), @"owner_revision": @(w.ownerRevision), @"events": callbacks,
  };
  NSError *error = nil;
  NSData *payload = [NSJSONSerialization dataWithJSONObject:batch options:NSJSONWritingFragmentsAllowed error:&error];
  if (!payload || payload.length > GPUI_TEXT_EVENT_BYTES_MAX || error) {
    fail_text_session(w, 13);
    return;
  }
  if (events.count >= 4096) {
    fail_text_session(w, 13);
    overflow = YES;
    return;
  }
  emit_event(w, 18, 0, 0, 0, 0, 0, payload, 0);
  if (overflow) {
    fail_text_session(w, 13);
    return;
  }
  w.lastBatchSequence = sequence;
  w.awaitingSequence = sequence;
  w.sessionAwaitingAck = YES;
  w.batchDelivered = NO;
#ifdef GPUI_TESTING
  GPView *trace_view = (GPView *)w.window.contentView;
  if (macos_ime_dispatch_trace_enabled(trace_view, w)) {
    NSUInteger commit_callback_count = 0;
    for (NSDictionary *callback in callbacks) {
      if ([callback[@"kind"] isEqual:@"commit"]) commit_callback_count++;
    }
    trace_macos_ime_dispatch(trace_view, w, @"batch", @"text_session",
      nil, nil, nil, nil, @(w.lastBatchSequence), @(w.sequence), nil,
      @(w.textDispatchActive), @(w.sessionAwaitingAck), @(commit_callback_count));
  }
#endif
}
static void flush_async_text_transactions(void) {
  if (!windows) return;
  for (GPWindow *w in windows.allValues) {
    GPView *view = (GPView *)w.window.contentView;
    if (!w.sessionActive || !w.textDispatchActive || !view || view.dispatchKeyEvent) continue;
    [view flushPendingUnmark];
    if (w.sessionActive && w.textDispatchActive) flush_text_batch(w);
  }
}
static void fence_session(GPWindow *w, BOOL close_session, int error) {
  if (!w) return;
  if (error) w.deferredTextError = error;
  w.sessionAwaitingAck = NO;
  w.awaitingSequence = 0;
  w.hasMarkedText = NO;
  w.markedRange = NSMakeRange(NSNotFound, 0);
  w.pendingUnmark = NO;
  w.textDispatchActive = NO;
  w.textCallbacks = nil;
  discard_marked_input_state(w);
  purge_window_events(w, 18);
  if (close_session) w.sessionActive = NO;
  if (w.acceptedText) {
    w.baseText = w.acceptedText;
    w.visibleText = w.acceptedText;
    w.selectionRange = w.acceptedSelection;
    w.sessionBaseSelection = w.acceptedSelection;
    w.caretHead = w.acceptedCaretHead;
    w.acceptedGeometryText = w.acceptedText;
    w.acceptedGeometryHead = w.acceptedCaretHead;
    w.caretRectMatchesVisible = YES;
  }
}
static BOOL native_window_has_active_key_focus(GPWindow *w, BOOL app_active) {
  return app_active && w && !w.closing && w.window && w.window.isKeyWindow &&
    NSApp.keyWindow == w.window;
}
static BOOL native_window_owns_text_view_in_active_app(GPWindow *w, BOOL app_active) {
  return native_window_has_active_key_focus(w, app_active) &&
    w.window.firstResponder == w.window.contentView;
}
static void reconcile_window_focus_for_activity(GPWindow *w, BOOL app_active) {
  if (!w) return;
  BOOL focused = native_window_has_active_key_focus(w, app_active);
#ifdef GPUI_TESTING
  if (w.testingFocusOverrideEnabled) focused = w.testingFocusOverride;
#endif
  if (focused == w.reportedKeyFocus) return;
  w.reportedKeyFocus = focused;
  if (focused) {
    emit(w, 5, 0, 0, 0, 0, 0);
  } else {
    invalidate_direct_text(w);
    fence_session(w, YES, 0);
    emit(w, 6, 0, 0, 0, 0, 0);
  }
}
static void reconcile_window_focus(GPWindow *w) {
  reconcile_window_focus_for_activity(w, NSApp.isActive);
}
static void reconcile_all_window_focus(void) {
  if (!windows) return;
  for (GPWindow *w in windows.allValues) reconcile_window_focus(w);
}
static NSRange normalized_range(NSRange value) {
  return value.location == NSNotFound ? value : NSMakeRange(value.location, value.length);
}
static int exact_json_integer(id value, int64_t *out) {
  if (![value isKindOfClass:NSNumber.class]) return 0;
  if (CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()) return 0;
  double d = [value doubleValue];
  if (!isfinite(d) || d < 0 || d > (double)GPUI_JSON_EXACT_MAX || floor(d) != d) return 0;
  int64_t result = [value longLongValue];
  if ((double)result != d) return 0;
  *out = result;
  return 1;
}
static BOOL load_session_payload(GPWindow *w, NSData *payload, BOOL preserve_marked,
                                 BOOL external_edit, int64_t ack_sequence) {
  if (!payload || payload.length > 32768) return NO;
  NSError *error = nil;
  id root = [NSJSONSerialization JSONObjectWithData:payload options:NSJSONReadingFragmentsAllowed error:&error];
  if (error || ![root isKindOfClass:NSDictionary.class]) return NO;
  NSDictionary *object = root;
  NSString *text = object[@"text"];
  NSData *utf8 = nil;
  int64_t cursor = 0, anchor = 0, utf16_length = 0, revision = 0;
  if (!valid_text_string(text, &utf8) || utf8.length > GPUI_TEXT_BYTES_MAX ||
      !exact_json_integer(object[@"cursor"], &cursor) ||
      !exact_json_integer(object[@"anchor"], &anchor) ||
      !exact_json_integer(object[@"utf16_length"], &utf16_length) ||
      !exact_json_integer(object[@"owner_revision"], &revision) ||
      utf16_length != (int64_t)text.length || cursor > utf16_length || anchor > utf16_length ||
      !scalar_boundary(text, (NSUInteger)cursor) || !scalar_boundary(text, (NSUInteger)anchor)) return NO;
  NSDictionary *rect = object[@"rect"];
  if (![rect isKindOfClass:NSDictionary.class]) return NO;
  for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
    if (![rect[key] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)rect[key]) == CFBooleanGetTypeID() ||
        !isfinite([rect[key] doubleValue])) return NO;
  }
  double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return NO;
  NSRect caret = NSMakeRect([rect[@"x"] doubleValue], [rect[@"y"] doubleValue], width, height);
  if (!isfinite(NSMinX(caret)) || !isfinite(NSMinY(caret)) || fabs(NSMinX(caret)) > 1e9 ||
      fabs(NSMinY(caret)) > 1e9) return NO;
  NSRange model_selection = NSMakeRange((NSUInteger)MIN(anchor, cursor), (NSUInteger)llabs(cursor-anchor));
  if (!valid_range_for_text(model_selection, text)) return NO;
  BOOL accepted_ack = ack_sequence > 0 && ack_sequence == w.awaitingSequence;
  if (ack_sequence > 0 && !accepted_ack) return NO;
  if (preserve_marked && !external_edit && w.hasMarkedText && [text isEqualToString:w.baseText]) {
    w.acceptedText = [text copy];
    w.acceptedSelection = model_selection;
    w.acceptedCaretHead = (NSUInteger)cursor;
    w.acceptedCaretRect = caret;
    // The owner provides the committed document for mutation validation but
    // computes this rect from the visible field, including marked text.
    w.acceptedGeometryText = [w.visibleText copy];
    w.acceptedGeometryHead = w.caretHead;
    w.caretRectMatchesVisible = YES;
    w.ownerRevision = revision;
    w.sessionBaseSelection = model_selection;
    if (accepted_ack) {
      w.sessionAwaitingAck = NO;
      w.awaitingSequence = 0;
    }
    return YES;
  }
  if (preserve_marked && !external_edit && w.sessionAwaitingAck && !accepted_ack &&
      ![text isEqualToString:w.visibleText]) return NO;
  w.baseText = [text copy];
  w.visibleText = [text copy];
  w.acceptedText = [text copy];
  w.acceptedGeometryText = [text copy];
  w.acceptedSelection = model_selection;
  w.acceptedCaretHead = (NSUInteger)cursor;
  w.acceptedGeometryHead = (NSUInteger)cursor;
  w.acceptedCaretRect = caret;
  w.caretRectMatchesVisible = YES;
  w.selectionRange = model_selection;
  w.sessionBaseSelection = model_selection;
  w.caretHead = (NSUInteger)cursor;
  w.sessionMarkedBaseRange = NSMakeRange(NSNotFound, 0);
  w.markedRange = NSMakeRange(NSNotFound, 0);
  w.hasMarkedText = NO;
  w.ownerRevision = revision;
  if (accepted_ack) {
    w.sessionAwaitingAck = NO;
    w.awaitingSequence = 0;
  }
  return YES;
}
static int load_direct_payload(GPWindow *w, NSData *payload, double epoch_value) {
  if (!w.directText || !isfinite(epoch_value) || epoch_value <= 0 || epoch_value > INT_MAX ||
      floor(epoch_value) != epoch_value || (int)epoch_value != w.directEpoch) return 10;
  if (!key_window_owns_view(w)) return 12;
  if (!payload) return 5;
  if (payload.length > 32768) return 13;
  NSError *error = nil;
  id root = [NSJSONSerialization JSONObjectWithData:payload options:NSJSONReadingFragmentsAllowed error:&error];
  if (error || ![root isKindOfClass:NSDictionary.class]) return 5;
  NSDictionary *object = root;
  NSString *text = object[@"text"];
  if (!valid_text_string(text, NULL)) return 5;
  int64_t cursor = 0, anchor = 0, utf16_length = 0;
  if (!exact_json_integer(object[@"cursor"], &cursor) ||
      !exact_json_integer(object[@"anchor"], &anchor) ||
      !exact_json_integer(object[@"utf16_length"], &utf16_length) ||
      utf16_length != (int64_t)text.length || cursor > utf16_length || anchor > utf16_length ||
      !scalar_boundary(text, (NSUInteger)cursor) || !scalar_boundary(text, (NSUInteger)anchor)) return 5;
  NSDictionary *rect = object[@"rect"];
  if (![rect isKindOfClass:NSDictionary.class]) return 5;
  for (NSString *key in @[@"x", @"y", @"width", @"height"]) {
    if (![rect[key] isKindOfClass:NSNumber.class] ||
        CFGetTypeID((__bridge CFTypeRef)rect[key]) == CFBooleanGetTypeID() ||
        !isfinite([rect[key] doubleValue])) return 5;
  }
  double width = [rect[@"width"] doubleValue], height = [rect[@"height"] doubleValue];
  if (width <= 0 || height <= 0 || width > 4096 || height > 4096) return 5;
  NSRect caret = NSMakeRect([rect[@"x"] doubleValue], [rect[@"y"] doubleValue], width, height);
  if (!isfinite(NSMinX(caret)) || !isfinite(NSMinY(caret)) || fabs(NSMinX(caret)) > 1e9 ||
      fabs(NSMinY(caret)) > 1e9) return 5;
  NSRange selection = NSMakeRange((NSUInteger)MIN(anchor, cursor), (NSUInteger)llabs(cursor - anchor));
  if (!valid_range_for_text(selection, text)) return 5;
  w.baseText = [text copy];
  w.visibleText = [text copy];
  w.acceptedText = [text copy];
  w.acceptedGeometryText = [text copy];
  w.selectionRange = selection;
  w.acceptedSelection = selection;
  w.caretHead = (NSUInteger)cursor;
  w.acceptedCaretHead = (NSUInteger)cursor;
  w.acceptedGeometryHead = (NSUInteger)cursor;
  w.acceptedCaretRect = caret;
  w.caretRectMatchesVisible = YES;
  w.hasMarkedText = NO;
  w.markedRange = NSMakeRange(NSNotFound, 0);
  return 0;
}
static BOOL emit_direct_text(GPWindow *w, NSString *text) {
  NSData *utf8 = nil;
  if (!valid_text_string(text, &utf8) || !w.directText || w.directEpoch <= 0) {
    w.deferredTextError = 5;
    return NO;
  }
  NSUInteger count_before = events.count;
  emit_event(w, 16, 0, 0, 0, 0, 0, utf8, w.directEpoch);
  if (events.count != count_before + 1) {
    w.deferredTextError = 13;
    return NO;
  }
  return YES;
}
static void resize_surface(GPWindow *w) {
  double scale = w.window.backingScaleFactor;
#ifdef GPUI_TESTING
  if (test_scale_override > 0) scale = test_scale_override;
#endif
  BOOL changed = scale != w.scale;
  w.scale = scale;
  w.surface.contentsScale = scale;
  NSSize size = w.window.contentView.bounds.size;
  w.surface.drawableSize = CGSizeMake(MAX(1, ceil(size.width * scale)), MAX(1, ceil(size.height * scale)));
  if (changed) emit(w, 4, 0, 0, 0, 0, 0);
}
@implementation GPWindow
- (BOOL)windowShouldClose:(NSWindow *)sender { (void)sender; emit(self, 12, 0, 0, 0, 0, 0); return NO; }
- (void)windowDidResize:(NSNotification *)note { (void)note; resize_surface(self); emit(self, 2, 0, 0, 0, 0, 0); }
- (void)windowDidMove:(NSNotification *)note { (void)note; resize_surface(self); emit(self, 3, self.window.frame.origin.x, self.window.frame.origin.y, 0, 0, 0); }
- (void)windowDidChangeBackingProperties:(NSNotification *)note { (void)note; resize_surface(self); }
- (void)windowDidBecomeKey:(NSNotification *)note { (void)note; reconcile_window_focus(self); }
- (void)windowDidResignKey:(NSNotification *)note {
  (void)note;
  reconcile_window_focus(self);
}
@end
static int modifiers(NSEvent *event) {
  NSUInteger f = event.modifierFlags;
  return ((f & NSEventModifierFlagShift) ? 1 : 0) | ((f & NSEventModifierFlagControl) ? 2 : 0) |
    ((f & NSEventModifierFlagOption) ? 4 : 0) | ((f & NSEventModifierFlagCommand) ? 8 : 0);
}
static BOOL measure_line_caret(NSString *text, NSUInteger utf16_offset, double *x, double *y, double *height) {
  NSData *utf8 = nil;
  if (!valid_text_string(text, &utf8) || utf16_offset > text.length) return NO;
  NSUInteger capacity = 12 + 10 * (text.length + 1);
  double *output = calloc(capacity, sizeof(double));
  if (!output) return NO;
  static const uint8_t family[] = "sans";
  int status = gpui_macos_text_measure_v1(1, utf8.bytes, (int32_t)utf8.length, family, 4, 18.0,
    output, (int32_t)capacity);
  if (status) { free(output); return NO; }
  NSUInteger byte_offset = 0, unit_offset = 0;
  BOOL found = NO;
  for (NSUInteger i = 0; i < (NSUInteger)output[11]; i++) {
    NSUInteger target_byte = (NSUInteger)output[12 + i * 10];
    while (byte_offset < target_byte && unit_offset < text.length) {
      unichar c = [text characterAtIndex:unit_offset];
      if (c >= 0xD800 && c <= 0xDBFF && unit_offset + 1 < text.length) {
        byte_offset += 4; unit_offset += 2;
      } else {
        byte_offset += c <= 0x7F ? 1 : (c <= 0x7FF ? 2 : 3);
        unit_offset++;
      }
    }
    if (byte_offset == target_byte && unit_offset == utf16_offset && output[13 + i * 10] == 1.0) {
      *x = output[14 + i * 10];
      *y = output[15 + i * 10];
      *height = output[17 + i * 10];
      found = YES;
      break;
    }
  }
  free(output);
  return found;
}
static BOOL current_text_origin(GPWindow *owner, double *x, double *y) {
  NSString *reference = owner.caretRectMatchesVisible ? owner.visibleText : owner.acceptedGeometryText;
  NSUInteger offset = owner.caretRectMatchesVisible ? owner.caretHead : owner.acceptedGeometryHead;
  double caret_x = 0, caret_y = 0, caret_height = 0;
  if (!reference || !measure_line_caret(reference, offset, &caret_x, &caret_y, &caret_height)) return NO;
  *x = NSMinX(owner.acceptedCaretRect) - caret_x;
  *y = NSMinY(owner.acceptedCaretRect) - caret_y;
  return isfinite(*x) && isfinite(*y);
}
#ifdef GPUI_TESTING
static NSArray<NSEvent *> *create_app_local_key_events(unsigned short key_code,
                                                       NSUInteger modifier_flags,
                                                       int64_t dispatch_id,
                                                       NSString *expected_characters,
                                                       NSString *expected_ignoring,
                                                       int *status) {
  if (status) *status = 5;
  if (!expected_characters || !expected_ignoring || !status || dispatch_id <= 0 ||
      dispatch_id > UINT32_MAX) return nil;
  NSEventType types[] = {NSEventTypeKeyDown, NSEventTypeKeyUp};
  NSEvent *created[2] = {nil, nil};
  const CGEventFlags allowed_cg_modifiers = kCGEventFlagMaskShift | kCGEventFlagMaskControl |
    kCGEventFlagMaskAlternate | kCGEventFlagMaskCommand;
  const NSUInteger allowed_ns_modifiers = NSEventModifierFlagShift | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagCommand;
  CGEventFlags requested_cg_modifiers = (CGEventFlags)(modifier_flags & allowed_ns_modifiers);
  int64_t event_nonce = INT64_C(0x4750554900000000) | dispatch_id;
  for (NSUInteger i = 0; i < 2; i++) {
    CGEventRef cg_event = CGEventCreateKeyboardEvent(NULL, (CGKeyCode)key_code, i == 0);
    if (!cg_event) { *status = 13; return nil; }
    // Keep runtime metadata such as the non-coalescing marker, but replace the
    // four requested modifier bits so the current physical modifier state can
    // never leak into this deterministic app-local event.
    CGEventFlags event_flags = CGEventGetFlags(cg_event) & ~allowed_cg_modifiers;
    CGEventSetFlags(cg_event, event_flags | requested_cg_modifiers);
    CGEventSetIntegerValueField(cg_event, kCGEventSourceUserData, event_nonce);
    NSEvent *event = [NSEvent eventWithCGEvent:cg_event];
    CGEventRef wrapped_cg_event = event.CGEvent;
    BOOL valid = event && event.CGEvent && event.eventRef && event.type == types[i] &&
      event.keyCode == key_code &&
      ((((NSUInteger)event.modifierFlags) & allowed_ns_modifiers) ==
        (((NSUInteger)modifier_flags) & allowed_ns_modifiers)) &&
      [(event.characters ?: @"") isEqualToString:expected_characters] &&
      [(event.charactersIgnoringModifiers ?: @"") isEqualToString:expected_ignoring] &&
      CGEventGetIntegerValueField(wrapped_cg_event, kCGEventSourceUserData) == event_nonce;
    CFRelease(cg_event);
    if (!valid) { *status = 5; return nil; }
    created[i] = event;
  }
  ime_timing_end();
  if (key_code == 36) ime_timing_begin(dispatch_id);
  *status = 0;
  return @[created[0], created[1]];
}
static NSMutableDictionary *testing_key_dispatch_record(int64_t dispatch_id,
                                                       int key_code,
                                                       NSString *phase,
                                                       int64_t event_host_epoch,
                                                       int session_epoch,
                                                       int direct_epoch,
                                                       BOOL session_active,
                                                       BOOL direct_text) {
  return [@{
    @"dispatch_id": @(dispatch_id), @"key_code": @(key_code), @"phase": phase,
    @"host_epoch": @(event_host_epoch), @"session_epoch": @(session_epoch),
    @"direct_epoch": @(direct_epoch), @"session_active": @(session_active),
    @"direct_text": @(direct_text),
  } mutableCopy];
}
#include "testing_hid.h"
static int64_t take_testing_key_dispatch_with_cg(GPWindow *w, NSEvent *event,
                                                 CGEventRef cg_event, NSString *phase) {
  if (testing_hid_enabled()) return take_testing_hid_dispatch(w, event, cg_event, phase);
  if (!cg_event) return 0;
  int64_t event_nonce = CGEventGetIntegerValueField(cg_event, kCGEventSourceUserData);
  uint64_t nonce_bits = (uint64_t)event_nonce;
  if ((nonce_bits & UINT64_C(0xFFFFFFFF00000000)) != UINT64_C(0x4750554900000000)) return 0;
  int64_t dispatch_id = (int64_t)(nonce_bits & UINT64_C(0x00000000FFFFFFFF));
  if (!w || !event || !w.testingPostedKeys) return -1;
  for (NSUInteger i = 0; i < w.testingPostedKeys.count; i++) {
    NSMutableDictionary *pending = w.testingPostedKeys[i];
    if ([pending[@"phase"] isEqual:phase] &&
        [pending[@"key_code"] intValue] == event.keyCode &&
        [pending[@"dispatch_id"] longLongValue] == dispatch_id) {
      [w.testingPostedKeys removeObjectAtIndex:i];
      BOOL current_owner = key_window_owns_view(w) && event.window == w.window &&
        event.windowNumber == w.window.windowNumber &&
        [pending[@"host_epoch"] longLongValue] == host_epoch &&
        [pending[@"session_epoch"] intValue] == w.sessionEpoch &&
        [pending[@"direct_epoch"] intValue] == w.directEpoch &&
        [pending[@"session_active"] boolValue] == w.sessionActive &&
        [pending[@"direct_text"] boolValue] == w.directText;
      return current_owner ? dispatch_id : -1;
    }
  }
  return -1;
}
static int64_t take_testing_key_dispatch(GPWindow *w, NSEvent *event, NSString *phase) {
  return take_testing_key_dispatch_with_cg(w, event, event.CGEvent, phase);
}
static void complete_testing_key_dispatch(GPWindow *w, int64_t dispatch_id, NSString *phase) {
  if (!w || dispatch_id <= 0) return;
  for (NSMutableDictionary *receipt in w.testingReceipts) {
    if ([receipt[@"dispatch_id"] longLongValue] != dispatch_id) continue;
    receipt[[phase isEqual:@"down"] ? @"down_dispatched" : @"up_dispatched"] = @YES;
    receipt[@"host_epoch"] = @(host_epoch);
    receipt[@"session_epoch"] = @(w.sessionEpoch);
    receipt[@"batch_sequence"] = @(w.lastBatchSequence);
    receipt[@"window_sequence"] = @(w.sequence);
#ifdef GPUI_TESTING
    if ([receipt[@"key_code"] intValue] == 36) {
      GPView *view = (GPView *)w.window.contentView;
      NSString *kind = [phase isEqualToString:@"down"] ? @"down" : @"up";
      trace_macos_ime_dispatch(view, w, @"dispatch", kind,
        receipt[@"dispatch_id"], receipt[@"key_code"],
        receipt[@"down_dispatched"], receipt[@"up_dispatched"],
        receipt[@"batch_sequence"], receipt[@"window_sequence"], nil,
        @(w.textDispatchActive), @(w.sessionAwaitingAck), nil);
    }
#endif
    return;
  }
}
#endif
@implementation GPView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)updateTrackingAreas {
  for (NSTrackingArea *area in self.trackingAreas) [self removeTrackingArea:area];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect options:NSTrackingMouseMoved | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
  [super updateTrackingAreas];
}
- (void)pointer:(NSEvent *)event kind:(int)kind {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  emit(owner, kind, p.x, p.y, modifiers(event), (int)event.buttonNumber, 0);
}
- (void)scrollWheel:(NSEvent *)event {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
  NSUInteger count_before = events.count;
  emit(owner, 17, p.x, p.y, modifiers(event), 0, 0);
  if (events.count == count_before + 1) {
    NSMutableDictionary *record = [events.lastObject mutableCopy];
    record[@"x"] = @(p.x); record[@"y"] = @(p.y);
    record[@"width"] = @(event.scrollingDeltaX); record[@"height"] = @(event.scrollingDeltaY);
    events[events.count - 1] = record;
  }
}
- (void)mouseMoved:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)mouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)rightMouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)otherMouseDragged:(NSEvent *)e { [self pointer:e kind:7]; }
- (void)mouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)rightMouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)otherMouseDown:(NSEvent *)e { [self pointer:e kind:8]; }
- (void)mouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)rightMouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)otherMouseUp:(NSEvent *)e { [self pointer:e kind:9]; }
- (void)keyDown:(NSEvent *)e {
#ifdef GPUI_TESTING
  ime_timing_key(e);
  int64_t dispatch_id = take_testing_key_dispatch(self.owner, e, @"down");
  if (dispatch_id < 0) return;
  [self dispatchKeyDown:e testingDispatchId:dispatch_id];
#else
  [self dispatchKeyDown:e testingDispatchId:0];
#endif
#ifdef GPUI_TESTING
  complete_testing_key_dispatch(self.owner, dispatch_id, @"down");
#endif
}
- (void)keyUp:(NSEvent *)e {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
#ifdef GPUI_TESTING
  ime_timing_key(e);
  int64_t dispatch_id = take_testing_key_dispatch(owner, e, @"up");
  if (dispatch_id < 0) return;
#endif
  resize_surface(owner);
  if (owner.sessionActive) {
    NSNumber *key_code = @(e.keyCode);
    if ([owner.sessionForwardedKeyUps containsObject:key_code] && !owner.sessionAwaitingAck && !owner.textDispatchActive) {
      owner.textDispatchActive = YES; owner.textDispatchCommitted = NO; owner.textCallbacks = [NSMutableArray new];
      NSDictionary *forwarded = [self forwardedKey:e kind:@"forwarded_released"];
      if (forwarded && append_text_callback(owner, forwarded)) [owner.sessionForwardedKeyUps removeObject:key_code];
      flush_text_batch(owner);
    } else if ([owner.sessionForwardedKeyUps containsObject:key_code]) {
      owner.deferredTextError = 12;
    }
  } else {
    NSData *characters = [e.charactersIgnoringModifiers dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
    emit_event(owner, 11, 0, 0, modifiers(e), e.keyCode, e.isARepeat, characters, 0);
  }
#ifdef GPUI_TESTING
  complete_testing_key_dispatch(owner, dispatch_id, @"up");
#endif
}
- (void)key:(NSEvent *)e kind:(int)kind {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  NSData *characters = [e.charactersIgnoringModifiers dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  emit_event(owner, kind, 0, 0, modifiers(e), e.keyCode, e.isARepeat, characters, 0);
}
- (NSDictionary *)forwardedKey:(NSEvent *)event kind:(NSString *)kind {
  NSString *key = nil;
  switch (event.keyCode) {
    case 36: case 76: key = @"enter"; break;
    case 53: key = @"escape"; break;
    case 51: key = @"backspace"; break;
    case 117: key = @"delete"; break;
    case 48: key = @"tab"; break;
    case 49: key = @"space"; break;
    case 123: key = @"left"; break;
    case 124: key = @"right"; break;
    case 125: key = @"down"; break;
    case 126: key = @"up"; break;
    case 115: key = @"home"; break;
    case 119: key = @"end"; break;
    case 116: key = @"page_up"; break;
    case 121: key = @"page_down"; break;
    default: break;
  }
  int mods = modifiers(event);
  BOOL command = (mods & (2 | 8)) != 0;
  if (!key && command) {
    NSString *characters = event.charactersIgnoringModifiers ?: @"";
    if (characters.length == 1) key = [characters lowercaseString];
  }
  if (!key) return nil;
  return @{@"kind":kind, @"key_code":@(event.keyCode), @"key":key,
    @"modifiers":@(mods)};
}
- (void)dispatchKeyDown:(NSEvent *)event testingDispatchId:(int64_t)dispatch_id {
  GPWindow *owner = self.owner;
  if (!owner || owner.closing) return;
  resize_surface(owner);
  if (owner.sessionActive) {
    if (owner.sessionAwaitingAck) { owner.deferredTextError = 12; return; }
    owner.textDispatchActive = YES;
    owner.textDispatchCommitted = NO;
    owner.pendingUnmark = NO;
    owner.textCallbacks = [NSMutableArray new];
    self.dispatchKeyEvent = event;
    if (event.keyCode == 53) {
      NSDictionary *forwarded = [self forwardedKey:event kind:@"forwarded_pressed"];
      if (forwarded && append_text_callback(owner, forwarded))
        [owner.sessionForwardedKeyUps addObject:@(event.keyCode)];
      if (owner.hasMarkedText) {
        append_text_callback(owner, @{@"kind":@"cancelled"});
        owner.visibleText = owner.baseText;
        owner.selectionRange = owner.sessionBaseSelection;
        owner.caretHead = owner.sessionBaseSelection.location;
        owner.hasMarkedText = NO;
        owner.markedRange = NSMakeRange(NSNotFound, 0);
        discard_marked_input_state(owner);
      }
    } else {
      NSTextInputContext *input_context = self.inputContext;
      if (event.keyCode == 36) {
#ifdef GPUI_TESTING
        trace_macos_ime_return_route((GPView *)owner.window.contentView, owner,
          @"return_route_begin", dispatch_id, @(input_context != nil), nil, nil);
        trace_macos_ime_callback_scope((GPView *)owner.window.contentView, owner, dispatch_id);
#endif
      }
      BOOL handled = [input_context handleEvent:event];
      BOOL fallback_invoked = !handled;
      if (fallback_invoked) [self interpretKeyEvents:@[event]];
#ifdef GPUI_TESTING
      if (event.keyCode == 36) {
        trace_macos_ime_return_route((GPView *)owner.window.contentView, owner,
          @"return_route_result", dispatch_id, @(input_context != nil), @(handled), @(fallback_invoked));
      }
#endif
    }
    self.dispatchKeyEvent = nil;
    [self flushPendingUnmark];
    flush_text_batch(owner);
    return;
  }

  NSData *characters = [event.charactersIgnoringModifiers dataUsingEncoding:NSUTF8StringEncoding] ?: [NSData data];
  emit_event(owner, 10, 0, 0, modifiers(event), event.keyCode, event.isARepeat, characters, 0);
  if (!owner.directText) return;
  if (owner.textDispatchActive) return;
  owner.textDispatchActive = YES;
  owner.textDispatchCommitted = NO;
  owner.pendingUnmark = NO;
  BOOL handled = [self.inputContext handleEvent:event];
  if (!handled) [self interpretKeyEvents:@[event]];
  [self flushPendingUnmark];
  owner.textDispatchActive = NO;
  owner.textDispatchCommitted = NO;
}
- (void)flushPendingUnmark {
  GPWindow *owner = self.owner;
  if (!owner || !owner.pendingUnmark) return;
  owner.pendingUnmark = NO;
  NSString *preview = owner.pendingUnmarkText ?: @"";
  owner.pendingUnmarkText = nil;
  NSRange marked = owner.markedRange;
  owner.hasMarkedText = NO;
  owner.markedRange = NSMakeRange(NSNotFound, 0);
  if (owner.textDispatchCommitted) return;
  if (!owner.sessionActive) {
    if (owner.directText) {
      if (valid_range_for_text(marked, owner.visibleText)) {
        NSMutableString *updated = [owner.visibleText mutableCopy];
        [updated replaceCharactersInRange:marked withString:preview];
        if (!valid_text_string(updated, NULL)) { owner.deferredTextError = 13; return; }
        if (!emit_direct_text(owner, preview)) return;
        owner.visibleText = [updated copy];
        owner.selectionRange = NSMakeRange(marked.location + preview.length, 0);
        owner.caretHead = owner.selectionRange.location;
        owner.caretRectMatchesVisible = NO;
      } else {
        if (!emit_direct_text(owner, preview)) return;
      }
      owner.textDispatchCommitted = YES;
    }
    return;
  }
  NSRange target = owner.sessionMarkedBaseRange;
  if (!valid_range_for_text(target, owner.baseText)) {
    fail_text_session(owner, 5); return;
  }
  NSDictionary *commit = @{@"kind":@"commit", @"text":preview, @"replacement_range":NSNull.null};
  if (!valid_text_string(preview, NULL)) { fail_text_session(owner, 5); return; }
  if (!append_text_callback(owner, commit)) return;
  NSMutableString *updated = [owner.baseText mutableCopy];
  [updated replaceCharactersInRange:target withString:preview];
  if (!valid_text_string(updated, NULL)) { fail_text_session(owner, 13); return; }
  owner.visibleText = [updated copy];
  owner.selectionRange = NSMakeRange(target.location + preview.length, 0);
  owner.baseText = owner.visibleText;
  owner.caretRectMatchesVisible = NO;
  owner.textDispatchCommitted = YES;
}

// NSTextInputClient mirror. All values returned here are copies derived from
// the last accepted field state plus callbacks in the current AppKit dispatch.
- (void)insertText:(id)value replacementRange:(NSRange)replacementRange {
  GPWindow *owner = self.owner;
  GPUIImeCallbackFacts callback_facts = macos_ime_callback_facts(self, owner);
#ifdef GPUI_TESTING
  NSDictionary *callback_trace = macos_ime_callback_trace_begin(
    self, owner, GPUIImeCallbackInsertText, GPUIImeCommandKindNone);
#endif
  GPUIImeCallbackGuard callback_guard = macos_ime_callback_guard(
    GPUIImeCallbackInsertText, callback_facts);
  if (callback_guard != GPUIImeCallbackGuardNone) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultGuardRejected);
#endif
    return;
  }
  NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] :
    ([value isKindOfClass:NSString.class] ? value : nil);
  NSData *utf8 = nil;
  if (!valid_text_string(text, &utf8)) {
    if (owner.sessionActive) fail_text_session(owner, 5);
    else owner.deferredTextError = 5;
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultInvalidText);
#endif
    return;
  }
#ifdef GPUI_TESTING
  if (owner.sessionActive) {
    NSNumber *key_code = self.dispatchKeyEvent ? @(self.dispatchKeyEvent.keyCode) : nil;
    trace_macos_ime_dispatch((GPView *)owner.window.contentView, owner,
      @"callback", @"commit", nil, key_code, nil, nil,
      @(owner.lastBatchSequence), @(owner.sequence), @(text.length),
      @(owner.textDispatchActive), @(owner.sessionAwaitingAck), nil);
  }
#endif
  if (owner.sessionActive) {
    NSRange target = replacementRange.location == NSNotFound ?
      (owner.hasMarkedText ? owner.markedRange : owner.selectionRange) : replacementRange;
    if (!valid_range_for_text(target, owner.visibleText) ||
        (replacementRange.location != NSNotFound &&
         !(owner.hasMarkedText && NSEqualRanges(target, owner.markedRange)) &&
         !(!owner.hasMarkedText && NSEqualRanges(target, normalized_range(owner.selectionRange))))) {
      fail_text_session(owner, 9);
#ifdef GPUI_TESTING
      macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
        GPUIImeCallbackResultInvalidRange);
#endif
      return;
    }
    NSMutableString *updated = [owner.visibleText mutableCopy];
    [updated replaceCharactersInRange:target withString:text];
    if (!valid_text_string(updated, NULL)) {
      fail_text_session(owner, 13);
#ifdef GPUI_TESTING
      macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
        GPUIImeCallbackResultInvalidUpdatedText);
#endif
      return;
    }
    NSDictionary *commit = @{@"kind":@"commit", @"text":text,
      @"replacement_range":json_range(replacementRange, replacementRange.location != NSNotFound)};
    if (!append_text_callback(owner, commit)) {
#ifdef GPUI_TESTING
      macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
        GPUIImeCallbackResultAppendRejected);
#endif
      return;
    }
    owner.visibleText = [updated copy];
    owner.baseText = owner.visibleText;
    owner.sessionBaseSelection = NSMakeRange(target.location + text.length, 0);
    owner.selectionRange = owner.sessionBaseSelection;
    owner.caretHead = owner.sessionBaseSelection.location;
    owner.caretRectMatchesVisible = NO;
    owner.hasMarkedText = NO;
    owner.markedRange = NSMakeRange(NSNotFound, 0);
    owner.pendingUnmark = NO;
    owner.textDispatchCommitted = YES;
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultAcceptedCommit);
#endif
    return;
  }
  if (owner.directText) {
    if (owner.hasMarkedText && valid_range_for_text(owner.markedRange, owner.visibleText)) {
      NSMutableString *updated = [owner.visibleText mutableCopy];
      [updated replaceCharactersInRange:owner.markedRange withString:text];
      if (!valid_text_string(updated, NULL)) {
        owner.deferredTextError = 13;
#ifdef GPUI_TESTING
        macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
          GPUIImeCallbackResultInvalidUpdatedText);
#endif
        return;
      }
      if (!emit_direct_text(owner, text)) {
#ifdef GPUI_TESTING
        macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
          GPUIImeCallbackResultAppendRejected);
#endif
        return;
      }
      owner.visibleText = [updated copy];
      owner.selectionRange = NSMakeRange(owner.markedRange.location + text.length, 0);
      owner.caretHead = owner.selectionRange.location;
      owner.caretRectMatchesVisible = NO;
    } else {
      if (!emit_direct_text(owner, text)) {
#ifdef GPUI_TESTING
        macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
          GPUIImeCallbackResultAppendRejected);
#endif
        return;
      }
    }
    owner.hasMarkedText = NO;
    owner.markedRange = NSMakeRange(NSNotFound, 0);
    owner.pendingUnmark = NO;
    owner.textDispatchCommitted = YES;
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultAcceptedDirectText);
#endif
    return;
  }
#ifdef GPUI_TESTING
  macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
    GPUIImeCallbackResultNoTextTarget);
#endif
}
- (void)insertText:(id)value { [self insertText:value replacementRange:NSMakeRange(NSNotFound, 0)]; }
- (void)setMarkedText:(id)value selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
  GPWindow *owner = self.owner;
  GPUIImeCallbackFacts callback_facts = macos_ime_callback_facts(self, owner);
#ifdef GPUI_TESTING
  NSDictionary *callback_trace = macos_ime_callback_trace_begin(
    self, owner, GPUIImeCallbackSetMarkedText, GPUIImeCommandKindNone);
#endif
  GPUIImeCallbackGuard callback_guard = macos_ime_callback_guard(
    GPUIImeCallbackSetMarkedText, callback_facts);
  if (callback_guard != GPUIImeCallbackGuardNone) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultGuardRejected);
#endif
    return;
  }
  NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] :
    ([value isKindOfClass:NSString.class] ? value : nil);
  if (!valid_text_string(text, NULL)) {
    fail_text_session(owner, 5);
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultInvalidText);
#endif
    return;
  }
  NSRange target = replacementRange.location == NSNotFound ?
    (owner.hasMarkedText ? owner.markedRange : owner.selectionRange) : replacementRange;
  if (!valid_range_for_text(target, owner.visibleText) ||
      (replacementRange.location != NSNotFound &&
       !(owner.hasMarkedText && NSEqualRanges(target, owner.markedRange)) &&
       !(!owner.hasMarkedText && NSEqualRanges(target, normalized_range(owner.selectionRange))))) {
    fail_text_session(owner, 9);
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultInvalidRange);
#endif
    return;
  }
  if (text.length == 0) {
    if (owner.sessionActive) {
      NSDictionary *preedit = @{@"kind":@"preedit", @"text":@"", @"fallback":@"",
        @"cursor_utf16":NSNull.null, @"styles":@[],
        @"replacement_range":json_range(replacementRange, replacementRange.location != NSNotFound)};
      if (!append_text_callback(owner, preedit)) {
#ifdef GPUI_TESTING
        macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
          GPUIImeCallbackResultAppendRejected);
#endif
        return;
      }
    }
    owner.visibleText = owner.baseText ?: @"";
    owner.selectionRange = owner.sessionBaseSelection;
    owner.hasMarkedText = NO;
    owner.markedRange = NSMakeRange(NSNotFound, 0);
    owner.caretHead = owner.sessionBaseSelection.location;
    owner.caretRectMatchesVisible = NO;
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultAcceptedEmptyMark);
#endif
    return;
  }
  if (!owner.hasMarkedText) owner.sessionMarkedBaseRange = target;
  NSMutableString *updated = [owner.visibleText mutableCopy];
  [updated replaceCharactersInRange:target withString:text];
  NSString *newVisible = [updated copy];
  if (!valid_text_string(newVisible, NULL)) {
    fail_text_session(owner, 13);
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultInvalidUpdatedText);
#endif
    return;
  }
  NSRange marked = NSMakeRange(target.location, text.length);
  id cursor = NSNull.null;
  if (selectedRange.location != NSNotFound && selectedRange.location <= text.length &&
      selectedRange.length <= text.length - selectedRange.location &&
      valid_range_for_text(selectedRange, text)) {
    cursor = @(selectedRange.location + selectedRange.length);
    owner.selectionRange = NSMakeRange(marked.location + selectedRange.location, selectedRange.length);
    owner.caretHead = owner.selectionRange.location;
    owner.caretHead += selectedRange.length;
  } else {
    owner.selectionRange = NSMakeRange(NSNotFound, 0);
  }
  NSMutableArray *styles = [NSMutableArray new];
#ifdef GPUI_TESTING
  BOOL trace_styles = macos_ime_style_trace_enabled(self, owner);
  NSMutableArray<NSDictionary *> *trace_runs = trace_styles ? [NSMutableArray new] : nil;
  __block BOOL trace_runs_truncated = NO;
#endif
  if ([value isKindOfClass:NSAttributedString.class]) {
    NSAttributedString *attributed = value;
    [attributed enumerateAttribute:NSUnderlineStyleAttributeName inRange:NSMakeRange(0, attributed.length)
      options:0 usingBlock:^(id attr, NSRange range, BOOL *stop) {
        (void)stop;
        if (!attr || range.length == 0) return;
        NSInteger raw = [attr respondsToSelector:@selector(integerValue)] ? [attr integerValue] : -1;
        // The bounded field renders both hints with one generic full-marked-range marker.
        int style = (raw == NSUnderlineStyleSingle || raw == NSUnderlineStyleThick) ? 5 : 255;
        [styles addObject:@{@"start":@(range.location), @"end":@(NSMaxRange(range)), @"style":@(style)}];
#ifdef GPUI_TESTING
        if (trace_styles) {
          if (trace_runs.count < 64) {
            [trace_runs addObject:@{
              @"start": @(range.location),
              @"end": @(NSMaxRange(range)),
              @"length": @(range.length),
              @"raw_style": @(raw),
              @"mapped_style": @(style),
            }];
          } else {
            trace_runs_truncated = YES;
          }
        }
#endif
      }];
  }
#ifdef GPUI_TESTING
  if (trace_styles) {
    trace_macos_ime_styles(self, text.length, trace_runs, trace_runs_truncated);
  }
#endif
  NSDictionary *preedit = @{@"kind":@"preedit", @"text":text, @"fallback":@"",
    @"cursor_utf16":cursor, @"styles":styles,
    @"replacement_range":json_range(replacementRange, replacementRange.location != NSNotFound)};
  if (owner.sessionActive && !append_text_callback(owner, preedit)) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultAppendRejected);
#endif
    return;
  }
  owner.visibleText = newVisible;
  owner.markedRange = marked;
  owner.hasMarkedText = YES;
  owner.caretRectMatchesVisible = NO;
#ifdef GPUI_TESTING
  macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
    GPUIImeCallbackResultAcceptedMarkedText);
#endif
}
- (void)unmarkText {
  GPWindow *owner = self.owner;
  GPUIImeCallbackFacts callback_facts = macos_ime_callback_facts(self, owner);
#ifdef GPUI_TESTING
  NSDictionary *callback_trace = macos_ime_callback_trace_begin(
    self, owner, GPUIImeCallbackUnmarkText, GPUIImeCommandKindNone);
#endif
  GPUIImeCallbackGuard callback_guard = macos_ime_callback_guard(
    GPUIImeCallbackUnmarkText, callback_facts);
  if (callback_guard != GPUIImeCallbackGuardNone) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultGuardRejected);
#endif
    return;
  }
  owner.pendingUnmarkText = [owner.visibleText substringWithRange:owner.markedRange];
  owner.pendingUnmark = YES;
  if (!owner.textDispatchActive) {
    owner.textDispatchActive = YES; owner.textDispatchCommitted = NO; owner.textCallbacks = [NSMutableArray new];
    [self flushPendingUnmark];
    flush_text_batch(owner);
  }
#ifdef GPUI_TESTING
  macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
    GPUIImeCallbackResultQueuedUnmark);
#endif
}
- (BOOL)hasMarkedText { return self.owner && self.owner.hasMarkedText; }
- (NSRange)markedRange { return self.owner && self.owner.hasMarkedText ? self.owner.markedRange : NSMakeRange(NSNotFound, 0); }
- (NSRange)selectedRange { return self.owner ? self.owner.selectionRange : NSMakeRange(NSNotFound, 0); }
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText { return @[NSUnderlineStyleAttributeName]; }
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  GPWindow *owner = self.owner;
  if (!owner || (!owner.sessionActive && !owner.directText) || !valid_range_for_text(range, owner.visibleText)) return nil;
  if (actualRange) *actualRange = range;
  return [[NSAttributedString alloc] initWithString:[owner.visibleText substringWithRange:range]];
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  GPWindow *owner = self.owner;
  if (!owner || (!owner.sessionActive && !owner.directText)) return NSZeroRect;
  if (range.location == NSNotFound) range = NSMakeRange(owner.caretHead, 0);
  if (!valid_range_for_text(range, owner.visibleText)) return NSZeroRect;
  double origin_x = 0, origin_y = 0;
  double caret_x = 0, caret_y = 0, caret_height = 0;
  if (!current_text_origin(owner, &origin_x, &origin_y) ||
      !measure_line_caret(owner.visibleText, NSMaxRange(range), &caret_x, &caret_y, &caret_height)) return NSZeroRect;
  NSRect local = NSMakeRect(origin_x + caret_x, origin_y + caret_y, 1.0, MAX(1.0, caret_height));
  NSRect screen = [self.window convertRectToScreen:[self convertRect:local toView:nil]];
  owner.lastCandidateRect = screen;
  if (actualRange) *actualRange = range;
  return screen;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  GPWindow *owner = self.owner;
  if (!owner || (!owner.sessionActive && !owner.directText)) return NSNotFound;
  NSPoint windowPoint = [self.window convertPointFromScreen:point];
  NSPoint local = [self convertPoint:windowPoint fromView:nil];
  double origin_x = 0, origin_y = 0;
  if (!current_text_origin(owner, &origin_x, &origin_y)) return NSNotFound;
  NSData *text = [owner.visibleText dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
  static const uint8_t family[] = "sans";
  double output[6];
  int status = gpui_macos_text_hit_test_v1(1, text.bytes, (int32_t)text.length,
    family, 4, 18.0, local.x - origin_x, local.y - origin_y, output, 5);
  if (status) return NSNotFound;
  NSUInteger utf8 = (NSUInteger)output[0], utf16 = 0, bytes = 0;
  for (NSUInteger i = 0; i < owner.visibleText.length && bytes < utf8; i++) {
    unichar c = [owner.visibleText characterAtIndex:i];
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < owner.visibleText.length) { bytes += 4; utf16 += 2; i++; }
    else { bytes += c <= 0x7F ? 1 : (c <= 0x7FF ? 2 : 3); utf16++; }
  }
  return utf16;
}
- (void)doCommandBySelector:(SEL)selector {
  GPWindow *owner = self.owner;
  GPUIImeCallbackFacts callback_facts = macos_ime_callback_facts(self, owner);
#ifdef GPUI_TESTING
  GPUIImeCommandKind selector_kind = macos_ime_command_kind(selector);
  NSDictionary *callback_trace = macos_ime_callback_trace_begin(
    self, owner, GPUIImeCallbackDoCommand, selector_kind);
#endif
  GPUIImeCallbackGuard callback_guard = macos_ime_callback_guard(
    GPUIImeCallbackDoCommand, callback_facts);
  if (callback_guard != GPUIImeCallbackGuardNone) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultGuardRejected);
#endif
    return;
  }
  NSDictionary *forwarded = [self forwardedKey:self.dispatchKeyEvent kind:@"forwarded_pressed"];
  if (!forwarded) {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultForwardUnavailable);
#endif
    return;
  }
  if (append_text_callback(owner, forwarded)) {
    [owner.sessionForwardedKeyUps addObject:@(self.dispatchKeyEvent.keyCode)];
 #ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultForwardedKey);
 #endif
  } else {
#ifdef GPUI_TESTING
    macos_ime_callback_trace_result(owner, callback_trace, callback_guard,
      GPUIImeCallbackResultAppendRejected);
#endif
  }
}
@end
@interface GPApplicationDelegate : NSObject <NSApplicationDelegate>
@end
@implementation GPApplicationDelegate
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
  (void)sender;
  if (state == 1) { state = 2; emit(nil, 15, 0, 0, 0, 0, 0); }
  return NSTerminateCancel;
}
@end
static GPApplicationDelegate *app_delegate;
static void destroy(GPWindow *w) {
  w.closing = YES;
  // Drop queued callbacks for this generation before the terminal notification.
  NSIndexSet *indices = [events indexesOfObjectsPassingTest:^BOOL(NSDictionary *e, NSUInteger i, BOOL *stop) {
    (void)i; (void)stop; return [e[@"token"] longLongValue] == w.token;
  }];
  [events removeObjectsAtIndexes:indices];
  w.window.delegate = nil;
  GPView *view = (GPView *)w.window.contentView;
#ifdef GPUI_TESTING
  // Acceptance mode changes only this view's NSTextInputContext. Restore that
  // context even when app-side cleanup unwinds through window destruction.
  if (w.testingInputSourceSaved) {
    view.inputContext.selectedKeyboardInputSource = w.testingOriginalInputSource;
    w.testingInputSourceSaved = NO;
    w.testingOriginalInputSource = nil;
  }
#endif
  view.owner = nil;
  w.window.contentView.layer = nil;
  w.surface = nil;
  [w.window close];
  emit(w, 13, 0, 0, 0, 0, 0);
  [windows removeObjectForKey:@(w.token)];
  w.window = nil;
}
static int setup_gpu(void) {
  /* Reinitialization starts from an empty shared renderer graph. The white
   * mask is device-owned just like the pipeline and queue, so never retain it
   * across a failed startup or host stop. */
  white_mask_texture = nil;
  device = MTLCreateSystemDefaultDevice();
  if (!device) return 16;
  queue = [device newCommandQueue];
  NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p; float4 c; float2 uv; uint textured; uint padding; };\nstruct O { float4 p [[position]]; float4 c; float2 uv; uint textured [[flat]]; };\nvertex O vmain(const device V *v [[buffer(0)]], uint i [[vertex_id]]) { O o; o.p=v[i].p; o.c=v[i].c; o.uv=v[i].uv; o.textured=v[i].textured; return o; }\nfragment float4 fmain(O o [[stage_in]], texture2d<float> mask [[texture(0)]]) { constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear); float coverage=o.textured ? mask.sample(s,o.uv).r : 1.0; return float4(o.c.rgb,o.c.a*coverage); }";
  NSError *error = nil;
  id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
  if (!library || !queue) return 16;
  MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
  desc.vertexFunction = [library newFunctionWithName:@"vmain"];
  desc.fragmentFunction = [library newFunctionWithName:@"fmain"];
  MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
  color.pixelFormat = MTLPixelFormatBGRA8Unorm;
  color.blendingEnabled = YES;
  color.sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
  color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  color.sourceAlphaBlendFactor = MTLBlendFactorOne;
  color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
  pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
  if (!pipeline) return 16;
  MTLTextureDescriptor *white_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
    width:1 height:1 mipmapped:NO];
  white_desc.usage = MTLTextureUsageShaderRead;
  white_desc.storageMode = MTLStorageModeShared;
  white_mask_texture = [device newTextureWithDescriptor:white_desc];
  if (!white_mask_texture) return 16;
  const uint8_t white = 255;
  [white_mask_texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:&white bytesPerRow:1];
  return 0;
}
static int recover_renderer(void) {
  /* Frames are submitted synchronously, so no command buffer retains a layer
   * or drawable when this operation begins. Replace the shared device graph,
   * then attach the new device to every live window before publishing success. */
  pipeline = nil;
  queue = nil;
  device = nil;
  white_mask_texture = nil;
  int status = setup_gpu();
  if (status) {
    pipeline = nil;
    queue = nil;
    device = nil;
    white_mask_texture = nil;
    return status;
  }
  for (GPWindow *window in windows.allValues) {
    window.surface.device = device;
    resize_surface(window);
  }
  return 0;
}
typedef struct { float position[4], color[4], uv[2]; uint32_t textured, padding; } Vertex;
_Static_assert(sizeof(Vertex) == 48, "Metal V layout must be 48 bytes");
typedef struct { Vertex v[6]; MTLScissorRect clip; NSUInteger texture_index; } Draw;
static double n(NSDictionary *d, NSString *key) { return [d[key] doubleValue]; }
static CGRect rect(NSDictionary *d) { return CGRectMake(n(d,@"x"), n(d,@"y"), n(d,@"width"), n(d,@"height")); }
static BOOL valid_json_number(id value) {
  return [value isKindOfClass:NSNumber.class] &&
    CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() && isfinite([value doubleValue]);
}
static BOOL valid_json_integer(id value, double maximum) {
  if (!valid_json_number(value)) return NO;
  double number = [value doubleValue];
  return number >= 0 && number <= maximum && floor(number) == number;
}
static BOOL valid_json_signed_integer(id value, double minimum, double maximum) {
  if (!valid_json_number(value)) return NO;
  double number = [value doubleValue];
  return number >= minimum && number <= maximum && floor(number) == number;
}
static BOOL valid_json_numeric_fields(NSDictionary *object, NSArray<NSString *> *keys) {
  if (![object isKindOfClass:NSDictionary.class]) return NO;
  for (NSString *key in keys) if (!valid_json_number(object[key])) return NO;
  return YES;
}
static BOOL valid_scene_rect(NSDictionary *object) {
  if (!valid_json_numeric_fields(object, @[@"x", @"y", @"width", @"height"])) return NO;
  double x = n(object,@"x"), y = n(object,@"y"), width = n(object,@"width"), height = n(object,@"height");
  return width >= 0 && height >= 0 && width <= 1e9 && height <= 1e9 &&
    fabs(x) <= 1e9 && fabs(y) <= 1e9 && fabs(x + width) <= 1e9 && fabs(y + height) <= 1e9;
}
static int text_native_status(int status) {
  if (status == 3 || status == 17) return 13;
  if (status == 7 || status == 11 || status == 12 || status == 15 || status == 16) return 5;
  if (status == 14 || status == 8 || status == 10) return 9;
  return status ? 16 : 0;
}
static id<MTLTexture> text_mask_texture(NSString *text, double font_size, double scale,
                                        CGRect bounds, NSPoint origin, CGRect *draw_bounds,
                                        float uv[4], BOOL *empty, int *error) {
  NSData *utf8 = nil;
  *empty = NO;
  *error = 0;
  if (!valid_text_string(text, &utf8) || !isfinite(font_size) || font_size <= 0 || font_size > 32 ||
      !isfinite(scale) || scale < 1 || scale > 2) {
    *error = 5; return nil;
  }
  GpuiMacTextMask mask = {0};
  int native_status = gpui_macos_text_raster_v1(utf8.bytes, (int32_t)utf8.length, font_size, scale, &mask);
  if (native_status) { *error = text_native_status(native_status); gpui_macos_text_raster_free(&mask); return nil; }
  if (!mask.width || !mask.height || !mask.pixels) {
    *empty = YES; gpui_macos_text_raster_free(&mask); return nil;
  }
  if (mask.width > 16384 || mask.height > 2048 || (int64_t)mask.width * mask.height > 8 * 1024 * 1024 ||
      mask.stride < mask.width) {
    *error = 13; gpui_macos_text_raster_free(&mask); return nil;
  }
  double left = origin.x + mask.left, top = origin.y + mask.top;
  double logical_width = (double)mask.width / scale, logical_height = (double)mask.height / scale;
  double right = left + logical_width, bottom = top + logical_height;
  if (!isfinite(left) || !isfinite(top) || !isfinite(right) || !isfinite(bottom)) {
    *error = 5; gpui_macos_text_raster_free(&mask); return nil;
  }
  double crop_left = MAX(0, ceil((CGRectGetMinX(bounds) - left) * scale - 0.5));
  double crop_top = MAX(0, ceil((CGRectGetMinY(bounds) - top) * scale - 0.5));
  double crop_right = MIN(mask.width, ceil((CGRectGetMaxX(bounds) - left) * scale - 0.5));
  double crop_bottom = MIN(mask.height, ceil((CGRectGetMaxY(bounds) - top) * scale - 0.5));
  if (crop_right <= crop_left || crop_bottom <= crop_top) {
    *empty = YES; gpui_macos_text_raster_free(&mask); return nil;
  }
  NSUInteger x0 = (NSUInteger)crop_left, y0 = (NSUInteger)crop_top;
  NSUInteger width = (NSUInteger)(crop_right - crop_left), height = (NSUInteger)(crop_bottom - crop_top);
  if ((int64_t)width * height > 8 * 1024 * 1024) {
    *error = 13; gpui_macos_text_raster_free(&mask); return nil;
  }
  NSMutableData *cropped = [NSMutableData dataWithLength:width * height];
  if (!cropped) { *error = 13; gpui_macos_text_raster_free(&mask); return nil; }
  const uint8_t *source = mask.pixels;
  uint8_t *destination = cropped.mutableBytes;
  for (NSUInteger y = 0; y < height; y++)
    memcpy(destination + y * width, source + (y0 + y) * (NSUInteger)mask.stride + x0, width);
  MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
    width:width height:height mipmapped:NO];
  descriptor.usage = MTLTextureUsageShaderRead;
  descriptor.storageMode = MTLStorageModeShared;
  id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
  if (!texture) { *error = 13; gpui_macos_text_raster_free(&mask); return nil; }
  [texture replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0
    withBytes:cropped.bytes bytesPerRow:width];
  double clipped_left = left + (double)x0 / scale;
  double clipped_top = top + (double)y0 / scale;
  double clipped_right = clipped_left + (double)width / scale;
  double clipped_bottom = clipped_top + (double)height / scale;
  *draw_bounds = CGRectMake(clipped_left, clipped_top, clipped_right-clipped_left, clipped_bottom-clipped_top);
  // This texture contains only the crop, so its complete texel extent maps to
  // the quad. Scaling these coordinates against the original mask sampled
  // outside the cropped texture and could erase the visible glyphs.
  uv[0] = 0; uv[1] = 0; uv[2] = 1; uv[3] = 1;
  gpui_macos_text_raster_free(&mask);
  return texture;
}
static int present(GPWindow *w, const uint8_t *bytes, int32_t len) {
  if (!device || !queue || !pipeline) return 16;
  NSDictionary *scene = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:len] options:0 error:nil];
  if (len > 16 * 1024 * 1024 || ![scene isKindOfClass:NSDictionary.class] ||
      !valid_json_integer(scene[@"schema_version"], 1) || [scene[@"schema_version"] intValue] != 1) return 5;
  id resources_value = scene[@"resources"], items_value = scene[@"items"], chains_value = scene[@"clip_chains"];
  if (![resources_value isKindOfClass:NSArray.class] || ![items_value isKindOfClass:NSArray.class] ||
      ![chains_value isKindOfClass:NSArray.class]) return 5;
  NSArray *items = items_value, *chains = chains_value;
  if ([resources_value count] != 0) return 9;
  if (items.count > 65536 || chains.count > 4096) return 13;
  NSMutableSet<NSNumber *> *chain_ids = [NSMutableSet new];
  for (id value in chains) {
    if (![value isKindOfClass:NSDictionary.class]) return 5;
    NSDictionary *chain = value;
    id chain_id = chain[@"id"], rects_value = chain[@"rects"];
    if (!valid_json_signed_integer(chain_id, -2147483648.0, 2147483647.0) ||
        ![rects_value isKindOfClass:NSArray.class]) return 5;
    if ([chain_ids containsObject:chain_id]) return 5;
    [chain_ids addObject:chain_id];
    NSArray *rects = rects_value;
    if (rects.count > 64) return 13;
    for (id clip_rect in rects) if (![clip_rect isKindOfClass:NSDictionary.class] || !valid_scene_rect(clip_rect)) return 5;
  }
  NSDictionary *viewport_value = scene[@"viewport"];
  if (!valid_scene_rect(viewport_value) || n(viewport_value,@"width") <= 0 || n(viewport_value,@"height") <= 0 ||
      !valid_json_number(scene[@"scale"])) return 5;
  resize_surface(w);
  CGRect viewport = rect(viewport_value);
  if (viewport.origin.x != 0 || viewport.origin.y != 0 || viewport.size.width <= 0 || viewport.size.height <= 0 ||
      viewport.size.width != w.window.contentView.bounds.size.width || viewport.size.height != w.window.contentView.bounds.size.height ||
      n(scene,@"scale") != w.scale) return 5;
  NSMutableData *data = [NSMutableData dataWithLength:sizeof(Draw) * items.count];
  if (!data) return 13;
  Draw *draws = data.mutableBytes;
  NSMutableArray<id<MTLTexture>> *textures = [NSMutableArray new];
  if (!white_mask_texture) return 16;
  [textures addObject:white_mask_texture];
  NSUInteger count = 0;
  NSUInteger text_allocation = 0;
  for (NSDictionary *item in items) {
    if (![item isKindOfClass:NSDictionary.class]) return 5;
    NSString *kind = item[@"kind"];
    if (![kind isKindOfClass:NSString.class]) return 5;
    BOOL is_text_run = [kind isEqual:@"text_run"];
    BOOL is_text = is_text_run || [kind isEqual:@"text"];
    if (!is_text && ![kind isEqual:@"quad"]) return 9;
    NSDictionary *bounds_value = item[@"bounds"], *transform = item[@"transform"], *color = item[@"color"];
    if (!valid_scene_rect(bounds_value) || !valid_json_numeric_fields(transform, @[@"a",@"b",@"c",@"d",@"tx",@"ty"]) ||
        !valid_json_numeric_fields(color, @[@"red",@"green",@"blue",@"alpha"]) ||
        !valid_json_number(item[@"opacity"])) return 5;
    id clip_id = item[@"clip_chain_id"];
    if (!clip_id || (clip_id != NSNull.null &&
        (!valid_json_signed_integer(clip_id, -2147483648.0, 2147483647.0) ||
         ![chain_ids containsObject:clip_id]))) return 5;
    CGRect item_bounds = rect(bounds_value), bounds = item_bounds, clip = viewport;
    if (!isfinite(CGRectGetMinX(bounds)) || !isfinite(CGRectGetMinY(bounds)) ||
        !isfinite(CGRectGetWidth(bounds)) || !isfinite(CGRectGetHeight(bounds)) ||
        CGRectGetWidth(bounds) < 0 || CGRectGetHeight(bounds) < 0 ||
        fabs(CGRectGetMinX(bounds)) > 1e9 || fabs(CGRectGetMinY(bounds)) > 1e9 ||
        CGRectGetWidth(bounds) > 1e9 || CGRectGetHeight(bounds) > 1e9) return 5;
    float uv[4] = {0,0,1,1};
    if (is_text) {
      NSDictionary *origin = is_text_run ? item[@"text_origin"] : nil;
      if ((is_text_run && !valid_json_numeric_fields(origin, @[@"x",@"y"])) ||
          ![item[@"text"] isKindOfClass:NSString.class] || !valid_json_number(item[@"font_size"])) return 5;
      double origin_x = is_text_run ? n(origin,@"x") : CGRectGetMinX(item_bounds);
      double origin_y = is_text_run ? n(origin,@"y") : CGRectGetMinY(item_bounds);
      NSData *text_bytes = nil;
      if (!isfinite(origin_x) || !isfinite(origin_y) || fabs(origin_x) > 1e9 || fabs(origin_y) > 1e9 ||
          !valid_text_string(item[@"text"], &text_bytes) || text_bytes.length > 4096 ||
          CGRectGetWidth(item_bounds) > 2048 || CGRectGetHeight(item_bounds) > 128) return 13;
      double font_size = n(item,@"font_size");
      if (font_size <= 0 || font_size > 32) return 5;
      BOOL empty = NO; int text_error = 0;
      id<MTLTexture> text_texture = text_mask_texture(item[@"text"],font_size,w.scale,
        item_bounds,NSMakePoint(origin_x,origin_y),&bounds,uv,&empty,&text_error);
      if (text_error) return text_error;
      if (empty) continue;
      NSUInteger allocation = (NSUInteger)text_texture.width * text_texture.height;
      if (allocation > 8 * 1024 * 1024 - text_allocation) return 13;
      text_allocation += allocation;
      [textures addObject:text_texture];
    }
    if (clip_id != NSNull.null) {
      BOOL found = NO;
      for (NSDictionary *chain in chains) {
        if ([chain[@"id"] isEqual:clip_id]) {
          found = YES;
          for (NSDictionary *r in chain[@"rects"]) clip = CGRectIntersection(clip, rect(r));
          break;
        }
      }
      if (!found) return 5;
    }
    if (CGRectIsEmpty(clip) || CGRectIsNull(clip)) continue;
    double s = w.scale;
    // A scissor pixel is covered when its sample center (i + 0.5) lies in the
    // logical half-open clip. Convert both edges against that sample lattice.
    long long left_i = (long long)ceil(CGRectGetMinX(clip)*s - 0.5);
    long long top_i = (long long)ceil(CGRectGetMinY(clip)*s - 0.5);
    long long right_i = (long long)ceil(CGRectGetMaxX(clip)*s - 0.5);
    long long bottom_i = (long long)ceil(CGRectGetMaxY(clip)*s - 0.5);
    long long width_i = (long long)w.surface.drawableSize.width;
    long long height_i = (long long)w.surface.drawableSize.height;
    if (left_i < 0) left_i = 0; if (top_i < 0) top_i = 0;
    if (right_i < 0) right_i = 0; if (bottom_i < 0) bottom_i = 0;
    if (left_i > width_i) left_i = width_i; if (right_i > width_i) right_i = width_i;
    if (top_i > height_i) top_i = height_i; if (bottom_i > height_i) bottom_i = height_i;
    if (right_i <= left_i || bottom_i <= top_i) continue;
    NSUInteger left = (NSUInteger)left_i, top = (NSUInteger)top_i;
    NSUInteger right = (NSUInteger)right_i, bottom = (NSUInteger)bottom_i;
    Draw *draw = &draws[count++];
    draw->clip = (MTLScissorRect){left,top,right-left,bottom-top};
    draw->texture_index = is_text ? textures.count - 1 : 0;
    NSDictionary *t = transform, *c = color;
    double opacity = n(item,@"opacity");
    double color_red=n(c,@"red"), color_green=n(c,@"green"), color_blue=n(c,@"blue"), color_alpha=n(c,@"alpha");
    if (!isfinite(opacity) || opacity < 0 || opacity > 1 ||
        color_red < 0 || color_red > 255 || color_green < 0 || color_green > 255 ||
        color_blue < 0 || color_blue > 255 || color_alpha < 0 || color_alpha > 255) return 5;
    double xs[] = {CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMinX(bounds),CGRectGetMinX(bounds),CGRectGetMaxX(bounds),CGRectGetMaxX(bounds)};
    double ys[] = {CGRectGetMinY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds),CGRectGetMaxY(bounds),CGRectGetMinY(bounds),CGRectGetMaxY(bounds)};
    float us[] = {uv[0],uv[2],uv[0],uv[0],uv[2],uv[2]};
    float vs[] = {uv[1],uv[1],uv[3],uv[3],uv[1],uv[3]};
    for (int i = 0; i < 6; i++) {
      double x = n(t,@"a")*xs[i] + n(t,@"c")*ys[i] + n(t,@"tx");
      double y = n(t,@"b")*xs[i] + n(t,@"d")*ys[i] + n(t,@"ty");
      double px = 2*x/viewport.size.width-1, py = 1-2*y/viewport.size.height;
      if (!isfinite(px) || !isfinite(py) || fabs(px)>1e20 || fabs(py)>1e20) return 5;
      draw->v[i] = (Vertex){{(float)px,(float)py,0,1},
        {(float)(color_red/255),(float)(color_green/255),(float)(color_blue/255),(float)(color_alpha/255*opacity)},
        {us[i],vs[i]},is_text?1u:0u,0};
    }
  }
  id<CAMetalDrawable> drawable = [w.surface nextDrawable];
  if (!drawable) return 15;
  MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
  pass.colorAttachments[0].texture = drawable.texture;
  pass.colorAttachments[0].loadAction = MTLLoadActionClear;
  pass.colorAttachments[0].storeAction = MTLStoreActionStore;
  pass.colorAttachments[0].clearColor = MTLClearColorMake(0.035,0.05,0.075,1);
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
  if (!command || !encoder) return 13;
  [encoder setRenderPipelineState:pipeline];
  for (NSUInteger i = 0; i < count; i++) {
    [encoder setScissorRect:draws[i].clip];
    [encoder setVertexBytes:draws[i].v length:sizeof(draws[i].v) atIndex:0];
    [encoder setFragmentTexture:textures[draws[i].texture_index] atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
  }
  [encoder endEncoding];
#ifdef GPUI_TESTING
  frame_width=drawable.texture.width; frame_height=drawable.texture.height;
  frame_stride=((frame_width*4+255)/256)*256;
  id<MTLBuffer> readback=[device newBufferWithLength:frame_stride*frame_height options:MTLResourceStorageModeShared];
  if (!readback) return 13;
  id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
  [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
    sourceSize:MTLSizeMake(frame_width,frame_height,1) toBuffer:readback destinationOffset:0
    destinationBytesPerRow:frame_stride destinationBytesPerImage:frame_stride*frame_height];
  [blit endEncoding];
#endif
  [command presentDrawable:drawable];
  [command commit];
  // First slice deliberately keeps one synchronous in-flight frame. No closure
  // retains MoonBit memory; teardown cannot race frame completion.
  [command waitUntilCompleted];
#ifdef GPUI_TESTING
  frame_pixels=[NSData dataWithBytes:readback.contents length:frame_stride*frame_height];
#endif
  if (command.status != MTLCommandBufferStatusCompleted) return 16;
#ifdef GPUI_TESTING
  if (w.completedFrameRevision >= GPUI_JSON_EXACT_MAX) return 13;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(frame_pixels.bytes, (CC_LONG)frame_pixels.length, digest);
  NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
  for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
  w.completedFrameSHA256 = [hex copy];
  w.completedFrameRevision++;
#endif
  return 0;
}
static BOOL key_window_owns_view(GPWindow *w) {
#ifdef GPUI_TESTING
  if (w && w.testingTextFocusOverride) return YES;
#endif
  return native_window_owns_text_view_in_active_app(w, NSApp.isActive);
}
static int begin_text_session(GPWindow *w, const uint8_t *bytes, int32_t length) {
  if (!key_window_owns_view(w)) return 12;
  if (w.sessionActive) return 12;
  if (w.sessionEpoch >= INT_MAX) return 13;
  NSData *payload = [NSData dataWithBytes:bytes length:length];
  GPWindow *probe = [GPWindow new];
  if (!load_session_payload(probe, payload, NO, YES, 0)) return 5;
  invalidate_direct_text(w);
  discard_marked_input_state(w);
  w.sessionEpoch++;
  w.sessionActive = YES;
  w.sessionAwaitingAck = NO;
  w.batchDelivered = NO;
  w.lastBatchSequence = 0;
  w.lastPresentedBatchSequence = 0;
  w.awaitingSequence = 0;
  w.deferredTextError = 0;
  w.sessionForwardedKeyUps = [NSMutableSet new];
  w.hasMarkedText = NO;
  w.markedRange = NSMakeRange(NSNotFound, 0);
  if (!load_session_payload(w, payload, NO, YES, 0)) {
    w.sessionActive = NO;
    return 5;
  }
  w.lastPresentedOwnerRevision = w.ownerRevision;
  result_token = w.sessionEpoch;
  return 0;
}
static int update_text_session(GPWindow *w, double epoch_value, const uint8_t *bytes,
                               int32_t length) {
  if (!isfinite(epoch_value) || epoch_value <= 0 || epoch_value > INT_MAX || floor(epoch_value) != epoch_value ||
      (int)epoch_value != w.sessionEpoch || !w.sessionActive) return 10;
  if (!key_window_owns_view(w)) return 12;
  NSData *payload = [NSData dataWithBytes:bytes length:length];
  NSError *error = nil;
  id root = [NSJSONSerialization JSONObjectWithData:payload options:NSJSONReadingFragmentsAllowed error:&error];
  if (error || ![root isKindOfClass:NSDictionary.class]) return 5;
  NSDictionary *object = root;
  id external_value = object[@"external_edit"];
  if (![external_value isKindOfClass:NSNumber.class] ||
      CFGetTypeID((__bridge CFTypeRef)external_value) != CFBooleanGetTypeID()) return 5;
  BOOL external = [external_value boolValue];
  id ack_value = object[@"acknowledged_sequence"];
  int64_t ack = 0;
  if (ack_value != NSNull.null) {
    if (!exact_json_integer(ack_value, &ack) || ack == 0) return 5;
  }
  if (external) {
    if (ack || w.sessionEpoch >= INT_MAX) return 5;
    GPWindow *probe = [GPWindow new];
    if (!load_session_payload(probe, payload, NO, YES, 0)) return 5;
    int64_t new_revision = 0;
    if (!exact_json_integer(object[@"owner_revision"], &new_revision) || new_revision < w.ownerRevision) return 5;
    fence_session(w, NO, 0);
    w.sessionEpoch++;
    w.sessionAwaitingAck = NO;
    w.batchDelivered = NO;
    if (!load_session_payload(w, payload, NO, YES, 0)) return 5;
  } else {
    if (w.sessionAwaitingAck) {
      if (!w.batchDelivered || !ack || ack != w.awaitingSequence) return 12;
    } else if (ack) {
      return 10;
    }
    int64_t new_revision = 0;
    if (!exact_json_integer(object[@"owner_revision"], &new_revision) || new_revision < w.ownerRevision) return 5;
    if (!load_session_payload(w, payload, YES, NO, ack)) return 5;
    if (ack) {
      w.lastPresentedBatchSequence = ack;
      w.lastPresentedOwnerRevision = w.ownerRevision;
    }
  }
  result_token = w.sessionEpoch;
  return 0;
}
static int cancel_text_session(GPWindow *w, double epoch_value) {
  if (!isfinite(epoch_value) || epoch_value <= 0 || epoch_value > INT_MAX || floor(epoch_value) != epoch_value ||
      (int)epoch_value != w.sessionEpoch || !w.sessionActive) return 10;
  if (w.sessionEpoch >= INT_MAX) return 13;
  fence_session(w, NO, 0);
  w.sessionEpoch++;
  w.sessionAwaitingAck = NO;
  w.batchDelivered = NO;
  result_token = w.sessionEpoch;
  return 0;
}
static int end_text_session(GPWindow *w, double epoch_value) {
  if (!isfinite(epoch_value) || epoch_value <= 0 || epoch_value > INT_MAX || floor(epoch_value) != epoch_value ||
      (int)epoch_value != w.sessionEpoch || !w.sessionActive) return 10;
  fence_session(w, YES, 0);
  return 0;
}
static int set_direct_text(GPWindow *w, BOOL enabled) {
  if (w.sessionActive && enabled) return 12;
  if (w.directText == enabled) return 0;
  if (w.directEpoch >= INT_MAX) return 13;
  w.directEpoch++;
  w.directText = enabled;
  purge_window_events(w, 10);
  purge_window_events(w, 11);
  purge_window_events(w, 16);
  if (enabled && !w.visibleText) {
    w.baseText = @""; w.visibleText = @"";
    w.selectionRange = NSMakeRange(0,0); w.sessionBaseSelection = NSMakeRange(0,0);
  }
  if (enabled && !w.acceptedText) {
    w.acceptedText = [w.visibleText copy] ?: @"";
    w.acceptedSelection = w.selectionRange;
    w.acceptedCaretHead = w.caretHead;
    w.acceptedGeometryText = [w.visibleText copy] ?: @"";
    w.acceptedGeometryHead = w.caretHead;
    w.caretRectMatchesVisible = YES;
  }
  if (!enabled) {
    discard_marked_input_state(w);
    w.hasMarkedText = NO;
    w.markedRange = NSMakeRange(NSNotFound, 0);
    w.pendingUnmark = NO;
    w.pendingUnmarkText = nil;
    w.textDispatchActive = NO;
    w.textDispatchCommitted = NO;
    w.textCallbacks = nil;
    if (w.acceptedText) {
      w.baseText = w.acceptedText;
      w.visibleText = w.acceptedText;
      w.selectionRange = w.acceptedSelection;
      w.sessionBaseSelection = w.acceptedSelection;
      w.caretHead = w.acceptedCaretHead;
      w.acceptedGeometryText = [w.acceptedText copy];
      w.acceptedGeometryHead = w.acceptedCaretHead;
      w.caretRectMatchesVisible = YES;
    }
  }
  return 0;
}
static void discard_stale_direct_head(void) {
  while (events.count) {
    NSDictionary *event = events[0];
    int kind = [event[@"kind"] intValue];
    if (kind != 10 && kind != 11 && kind != 16) return;
    if (kind != 16 && !event[@"direct_epoch"]) return;
    GPWindow *w = windows[event[@"token"]];
    int64_t epoch = [event[@"direct_epoch"] longLongValue];
    if (w && w.directText && epoch == w.directEpoch) return;
    [events removeObjectAtIndex:0];
  }
}
static int pump_native_event(double timeout_ms) {
  if (!isfinite(timeout_ms) || timeout_ms < 0 || timeout_ms > 250) return 5;
#ifdef GPUI_TESTING
  if (ime_timing.active) ime_timing.native_pumps++;
#endif
  if (!events.count) {
#ifdef GPUI_TESTING
    if (ime_timing.active) ime_timing.appkit_pumps++;
#endif
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:timeout_ms/1000];
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:until
      inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
  }
#ifdef GPUI_TESTING
  if (ime_timing.active) ime_timing.last_pump_ms = ime_monotonic_ms();
#endif
  reconcile_all_window_focus();
  flush_async_text_transactions();
  if (overflow) { overflow=NO; return 13; }
  return 0;
}
#ifdef GPUI_TESTING
static BOOL testing_select_input_source(GPWindow *w, NSString *target) {
  GPView *view = w ? (GPView *)w.window.contentView : nil;
  NSTextInputContext *context = view.inputContext;
  NSArray<NSString *> *sources = context.keyboardInputSources;
  if (!context || ![sources containsObject:target]) return NO;
  if (!w.testingInputSourceSaved) {
    w.testingOriginalInputSource = [context.selectedKeyboardInputSource copy];
    w.testingInputSourceSaved = YES;
  }
  context.selectedKeyboardInputSource = target;
  if ([context.selectedKeyboardInputSource isEqualToString:target]) return YES;

  // A source bundle identifier may be listed by AppKit but rejected as a
  // selected source when the input method exposes explicit mode identifiers.
  // Restore the exact per-context selection before reporting failure. Keep the
  // saved state if that restoration cannot be verified so teardown can retry.
  NSString *original = w.testingOriginalInputSource;
  context.selectedKeyboardInputSource = original;
  BOOL restored = original ? [context.selectedKeyboardInputSource isEqualToString:original] :
    context.selectedKeyboardInputSource == nil;
  if (restored) {
    w.testingOriginalInputSource = nil;
    w.testingInputSourceSaved = NO;
  }
  return NO;
}
#endif
static int32_t native_call(int32_t op, int64_t token, double x, double y, const uint8_t *bytes, int32_t len) {
  if (![NSThread isMainThread]) return 18;
  if (len < 0 || len > 16*1024*1024 || (len && !bytes)) return 5;
  @autoreleasepool {
    if (op == 1) {
      if (state) return state == 2 ? 19 : 12;
      if (host_epoch >= GPUI_JSON_EXACT_MAX) return 13;
      int status = setup_gpu();
      if (status) { white_mask_texture=nil; pipeline=nil; queue=nil; device=nil; return status; }
      [NSApplication sharedApplication];
      NSInteger activation_policy_before_start = NSApp.activationPolicy;
      // AppKit can report no change when the process already has the desired
      // policy (for example, after this host has been stopped and restarted).
      // Treat an already-Regular policy as established, but verify the final
      // state after any requested transition.
      BOOL activation_policy_set_succeeded = activation_policy_before_start == NSApplicationActivationPolicyRegular ||
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
      if (!activation_policy_set_succeeded || NSApp.activationPolicy != NSApplicationActivationPolicyRegular) {
        white_mask_texture=nil; pipeline=nil; queue=nil; device=nil;
        return 14;
      }
      app_delegate = [GPApplicationDelegate new]; NSApp.delegate = app_delegate;
      windows = [NSMutableDictionary new]; events = [NSMutableArray new]; current=nil; overflow=NO;
      [NSApp finishLaunching]; state = 1; host_epoch++;
      return 0;
    }
    if (op == 0) return token == host_epoch ? 0 : 10;
    if (op == 2) {
      if (!state) return 0;
      for (GPWindow *w in windows.allValues) destroy(w);
      events=nil; current=nil; text_result=nil; windows=nil; white_mask_texture=nil; pipeline=nil; queue=nil; device=nil;
      NSApp.delegate=nil; app_delegate=nil; state=0;
      return 0;
    }
    if (!state) return 1;
    // The renderer's text path consumes monochrome A8 masks. The CoreText
    // provider lives in a separate package; keep the general Mac backend
    // package portable while reporting this capability from the native host.
    if (op == 30) return device && pipeline ? 0 : 9;
    if (op == 3) {
      if (state == 2) return 19;
      if (!isfinite(x) || !isfinite(y) || x < 1 || y < 1 || x > 8192 || y > 8192) return 5;
      if (next_token >= GPUI_JSON_EXACT_MAX || windows.count >= 64) return 13;
      NSString *title = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
      if (!title) return 17;
      GPWindow *w = [GPWindow new];
#ifdef GPUI_TESTING
      w.testingPostedKeys = [NSMutableArray new];
      w.testingReceipts = [NSMutableArray new];
#endif
      w.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,x,y) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
      if (!w.window) return 14;
      w.window.releasedWhenClosed = NO;
      w.window.animationBehavior = NSWindowAnimationBehaviorNone;
      w.window.contentMinSize = NSMakeSize(128,128);
      w.token = ++next_token; w.scale = w.window.backingScaleFactor;
      GPView *view = [[GPView alloc] initWithFrame:NSMakeRect(0,0,x,y)];
      view.owner=w; view.wantsLayer=YES;
      w.surface=[CAMetalLayer layer]; w.surface.device=device; w.surface.pixelFormat=MTLPixelFormatBGRA8Unorm;
      w.surface.allowsNextDrawableTimeout=YES;
#ifdef GPUI_TESTING
      w.surface.framebufferOnly=NO;
#endif
      view.layer=w.surface;
      w.window.contentView=view; w.window.delegate=w; w.window.title=title;
      windows[@(w.token)]=w; result_token=w.token;
      resize_surface(w); emit(w,1,0,0,0,0,0);
      [w.window center]; [w.window makeKeyAndOrderFront:nil]; [w.window makeFirstResponder:view];
      request_application_activation();
      reconcile_window_focus(w);
      return 0;
    }
    if (op == 6) {
      current=nil;
      flush_async_text_transactions();
      discard_stale_direct_head();
      if (events.count && [events[0][@"kind"] intValue] == 18) return 9;
      for (GPWindow *window in windows.allValues)
        if (window.sessionActive && window.sessionAwaitingAck && window.batchDelivered) return 12;
      int pump = pump_native_event(x);
      if (pump) return pump;
      discard_stale_direct_head();
      if (events.count && [events[0][@"kind"] intValue] == 18) return 9;
      if (events.count) { current=events[0]; [events removeObjectAtIndex:0]; }
      return 0;
    }
    if (op == 23) {
      current = nil;
      flush_async_text_transactions();
      for (GPWindow *window in windows.allValues) {
        if (window.deferredTextError) {
          int deferred = window.deferredTextError;
          window.deferredTextError = 0;
          if (window.sessionActive) fail_text_session(window, deferred);
          return deferred;
        }
        if (window.sessionAwaitingAck && window.batchDelivered) return 12;
      }
      discard_stale_direct_head();
      int pump = events.count ? 0 : pump_native_event(x);
      if (pump) return pump;
      discard_stale_direct_head();
      if (events.count) {
        current = events[0]; [events removeObjectAtIndex:0];
        if ([current[@"kind"] intValue] == 18) {
          GPWindow *window = windows[current[@"token"]];
          if (!window || !window.sessionActive ||
              [current[@"seq"] longLongValue] != window.awaitingSequence ||
              window.sessionEpoch <= 0) {
            current = nil;
            return 10;
          }
          window.batchDelivered = YES;
        }
      }
      return 0;
    }
    if (op == 10) { emit(nil,14,0,0,0,0,0); return 0; }
    if (op == 12) {
      switch ((int)x) { case 0: [[NSCursor arrowCursor] set]; break; case 1: [[NSCursor pointingHandCursor] set]; break; case 2: [[NSCursor IBeamCursor] set]; break; default: return 9; }
      return 0;
    }
    if (op == 13) {
      current=nil;
      NSString *text = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] ?: @"";
      text_result = [text dataUsingEncoding:NSUTF8StringEncoding];
      return text_result.length <= 16*1024*1024 ? 0 : 13;
    }
    if (op == 14) {
      NSString *text = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
      if (!text) return 17;
      [NSPasteboard.generalPasteboard clearContents];
      return [NSPasteboard.generalPasteboard setString:text forType:NSPasteboardTypeString] ? 0 : 12;
    }
    if (op == 11) { if (state == 1) { state=2; emit(nil,15,0,0,0,0,0); } return 0; }
    GPWindow *w=windows[@(token)];
    if (!w) return op == 8 && token > 0 && token <= next_token ? 0 : 10;
    switch (op) {
      case 4: {
        NSString *title=[[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
        if (!title) return 17; w.window.title=title; return 0;
      }
      case 5:
        if (!isfinite(x) || !isfinite(y) || x < 1 || y < 1 || x > 8192 || y > 8192) return 5;
        [w.window setContentSize:NSMakeSize(x,y)]; return 0;
      case 7: [w.window performClose:nil]; return 0;
      case 8:
        // Keep the window live if its terminal event cannot be queued. Events
        // for this token will be removed during destruction, freeing a slot.
        if (events.count >= 4096) {
          BOOL frees_slot = NO;
          for (NSDictionary *event in events) {
            if ([event[@"token"] longLongValue] == token) { frees_slot = YES; break; }
          }
          if (!frees_slot) return 13;
        }
        destroy(w); return 0;
      case 9: return present(w,bytes,len);
      case 16: return recover_renderer();
      case 15: resize_surface(w); current=@{@"width":@(w.window.contentView.bounds.size.width), @"height":@(w.window.contentView.bounds.size.height), @"scale":@(w.scale)}; return 0;
      case 17: return set_direct_text(w, x != 0.0);
      case 18: result_token = w.directEpoch; return w.directEpoch > 0 ? 0 : 5;
      case 19: return begin_text_session(w, bytes, len);
      case 20: return update_text_session(w, x, bytes, len);
      case 21: return cancel_text_session(w, x);
      case 22: return end_text_session(w, x);
      case 28: return load_direct_payload(w, [NSData dataWithBytes:bytes length:len], x);
#ifdef GPUI_TESTING
      case 24: {
        if (!isfinite(x) || x < 0 || x > 65535 || floor(x) != x ||
            !isfinite(y) || y < 0 || y > 15 || floor(y) != y) return 5;
        if (!key_window_owns_view(w)) return 12;
        NSError *json_error = nil;
        id input = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:len]
          options:NSJSONReadingFragmentsAllowed error:&json_error];
        if (json_error || ![input isKindOfClass:NSDictionary.class]) return 5;
        NSString *characters = input[@"characters"];
        NSString *ignoring = input[@"ignoring"];
        if (![characters isKindOfClass:NSString.class] || ![ignoring isKindOfClass:NSString.class] ||
            characters.length > 16 || ignoring.length > 16) return 5;
        if (w.testingDispatchId >= GPUI_JSON_EXACT_MAX || w.testingReceipts.count >= 4096) return 13;
        NSUInteger flags = ((int)y & 1 ? NSEventModifierFlagShift : 0) |
          ((int)y & 2 ? NSEventModifierFlagControl : 0) |
          ((int)y & 4 ? NSEventModifierFlagOption : 0) |
          ((int)y & 8 ? NSEventModifierFlagCommand : 0);
        int64_t dispatch_id = w.testingDispatchId + 1;
        int event_status = 0;
        BOOL hid = testing_hid_enabled();
        NSArray<NSEvent *> *events_to_post = nil;
        if (hid) {
          if (!testing_hid_queue(w, (int)x, flags, dispatch_id, characters, ignoring)) {
            testing_hid_fail(w, @"producer could not queue key pair"); return 5;
          }
          ime_timing_end();
          if ((int)x == 36) ime_timing_begin(dispatch_id);
        } else {
          events_to_post = create_app_local_key_events((unsigned short)x,
            flags, dispatch_id, characters, ignoring, &event_status);
        }
        if (event_status) return event_status;
        w.testingDispatchId = dispatch_id;
        NSMutableDictionary *receipt = [@{
          @"schema_version": @1, @"dispatch_id": @(dispatch_id), @"key_code": @((int)x),
          @"down_posted": @YES, @"up_posted": @YES, @"down_dispatched": @NO,
          @"up_dispatched": @NO, @"host_epoch": @(host_epoch),
          @"session_epoch": @(w.sessionEpoch), @"batch_sequence": @(w.lastBatchSequence),
          @"window_sequence": @(w.sequence),
        } mutableCopy];
        w.testingDispatchReceipt = receipt;
        [w.testingReceipts addObject:receipt];
        [w.testingPostedKeys addObject:testing_key_dispatch_record(dispatch_id, (int)x,
          @"down", host_epoch, w.sessionEpoch, w.directEpoch, w.sessionActive, w.directText)];
        [w.testingPostedKeys addObject:testing_key_dispatch_record(dispatch_id, (int)x,
          @"up", host_epoch, w.sessionEpoch, w.directEpoch, w.sessionActive, w.directText)];
        if (hid) {
          for (NSMutableDictionary *pending in w.testingPostedKeys) {
            pending[@"hid"] = @YES;
            pending[@"characters"] = characters;
            pending[@"ignoring"] = ignoring;
          }
        } else {
          [NSApp postEvent:events_to_post[0] atStart:NO];
          [NSApp postEvent:events_to_post[1] atStart:NO];
        }
        return 0;
      }
      case 25: {
        if (!key_window_owns_view(w)) return 12;
        NSString *source = ((GPView *)w.window.contentView).inputContext.selectedKeyboardInputSource ?: @"";
        text_result = [source dataUsingEncoding:NSUTF8StringEncoding];
        current = @{@"text":text_result ?: [NSData data]};
        return 0;
      }
      case 31: {
        if (!key_window_owns_view(w)) return 12;
        NSString *target = @"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
        return testing_select_input_source(w, target) ? 0 : 9;
      }
      case 32: {
        ime_timing_end();
        if (!w.testingInputSourceSaved) return 0;
        GPView *view = (GPView *)w.window.contentView;
        NSString *source = w.testingOriginalInputSource;
        if (source && ![view.inputContext.keyboardInputSources containsObject:source]) return 9;
        view.inputContext.selectedKeyboardInputSource = source;
        BOOL restored = source ? [view.inputContext.selectedKeyboardInputSource isEqualToString:source] :
          view.inputContext.selectedKeyboardInputSource == nil;
        if (!restored) return 9;
        w.testingOriginalInputSource = nil;
        w.testingInputSourceSaved = NO;
        return 0;
      }
      case 26: {
        if (!w.completedFrameSHA256 || w.completedFrameRevision <= 0) return 15;
        NSDictionary *identity = @{
          @"schema_version": @1, @"window_id": @(w.token), @"host_epoch": @(host_epoch),
          @"session_epoch": @(w.sessionEpoch), @"batch_sequence": @(w.lastPresentedBatchSequence),
          @"accepted_revision": @(w.lastPresentedOwnerRevision),
          @"frame_revision": @(w.completedFrameRevision), @"frame_sha256": w.completedFrameSHA256,
          @"text": w.visibleText ?: @"",
        };
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:identity options:NSJSONWritingFragmentsAllowed error:nil];
        current = @{@"text":encoded ?: [NSData data]};
        return encoded ? 0 : 13;
      }
      case 27: {
          if (!key_window_owns_view(w)) return 12;
          (void)[(GPView *)w.window.contentView firstRectForCharacterRange:NSMakeRange(w.caretHead, 0) actualRange:NULL];
          if (NSIsEmptyRect(w.lastCandidateRect)) return 15;
        current = @{@"x":@(NSMinX(w.lastCandidateRect)), @"y":@(NSMinY(w.lastCandidateRect)),
          @"width":@(NSWidth(w.lastCandidateRect)), @"height":@(NSHeight(w.lastCandidateRect))};
        return 0;
      }
      case 29: {
        if (!w.testingDispatchReceipt) return 15;
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:w.testingDispatchReceipt
          options:NSJSONWritingFragmentsAllowed error:nil];
        current = @{ @"text":encoded ?: [NSData data] };
        return encoded ? 0 : 13;
      }
      case 33: {
        ime_timing_record(@"window_state_snapshot");
        id responder = w.window.firstResponder;
        GPView *view = (GPView *)w.window.contentView;
        NSRect frame = w.window.frame;
        NSRect content_window = [view convertRect:view.bounds toView:nil];
        NSRect content_screen = [w.window convertRectToScreen:content_window];
        double content_x = NSMinX(content_screen) - NSMinX(frame);
        double content_y = NSMaxY(frame) - NSMaxY(content_screen);
        if (!isfinite(content_x) || !isfinite(content_y) ||
            !isfinite(NSWidth(frame)) || !isfinite(NSHeight(frame)) ||
            !isfinite(NSWidth(content_screen)) || !isfinite(NSHeight(content_screen))) return 5;
        NSDictionary *state_info = @{
          @"schema_version": @1, @"window_key": @(w.window.isKeyWindow),
          @"app_key_matches": (NSApp.keyWindow == w.window) ? @YES : @NO,
          @"window_id": @(w.token), @"host_epoch": @(host_epoch),
          @"native_window_id": @(w.window.windowNumber),
          @"first_responder_is_content_view": (responder == w.window.contentView) ? @YES : @NO,
          @"first_responder_class": responder ? NSStringFromClass([responder class]) : @"nil",
          @"content_view_class": NSStringFromClass([view class]),
          @"window_visible": @(w.window.isVisible), @"session_active": @(w.sessionActive),
          @"direct_text": @(w.directText), @"session_epoch": @(w.sessionEpoch),
          @"selected_input_source": view.inputContext.selectedKeyboardInputSource ?: @"",
          @"coordinate_space": @"top_left_window_points",
          @"content_origin_in_window": @{@"x":@(content_x), @"y":@(content_y)},
          @"content_size": @{@"width":@(NSWidth(content_screen)), @"height":@(NSHeight(content_screen))},
          @"window_size": @{@"width":@(NSWidth(frame)), @"height":@(NSHeight(frame))},
        };
        NSData *encoded = [NSJSONSerialization dataWithJSONObject:state_info
          options:NSJSONWritingFragmentsAllowed error:nil];
        current = @{ @"text":encoded ?: [NSData data] };
        return encoded ? 0 : 13;
      }
#else
      case 24: case 25: case 26: case 27: case 29: case 31: case 32: case 33: return 9;
#endif
      default: return 9;
    }
  }
}
static int64_t native_integer(int32_t field) {
  if (![NSThread isMainThread]) return 0;
  if (field >= 100) { NSData *text = current[@"text"] ?: text_result; return field-100 < (int)text.length ? ((const uint8_t *)text.bytes)[field-100] : 0; }
  switch(field) {
    case 0:return result_token; case 1:return [current[@"kind"] longLongValue];
    case 2:return [current[@"token"] longLongValue]; case 3:return [current[@"seq"] longLongValue];
    case 4:return [current[@"mods"] longLongValue]; case 5:return [current[@"code"] longLongValue];
    case 6:return [current[@"repeat"] longLongValue]; case 7:return 1;
    case 8:return [(current[@"text"] ?: text_result) length]; case 9:return host_epoch; default:return 0;
  }
}
static double native_number(int32_t field) {
  if (![NSThread isMainThread]) return 0;
  NSArray *keys=@[@"scale",@"x",@"y",@"width",@"height"];
  return field >= 0 && field < 5 ? [current[keys[field]] doubleValue] : 0;
}
const GpuiApi *gpui_macos_api_v1(void) {
  static const GpuiApi api={1,sizeof(GpuiApi),native_call,native_integer,native_number};
  return &api;
}
