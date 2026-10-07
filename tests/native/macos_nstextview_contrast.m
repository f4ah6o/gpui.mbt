// Standalone, opt-in NSTextView comparison fixture. This translation unit is
// compile-tested only in ordinary validation; do not run without the separate
// desktop authorization for a Kotoeri fixture run.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#import <AppKit/NSTextInputClient.h>
#include "macos_nstextview_contrast_contract.h"

#include <stdlib.h>
#include <string.h>

static NSString *const kExpectedComposition = @"Hello 日本語";
static NSString *const kExpectedCommit = @"日本語";
static NSString *const kKotoeriSource = @"com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese";
static NSString *const kRuntimeOptIn = @"GPUI_FIELD_MACOS_NSTEXTVIEW_CONTRAST";
static const double kPumpMilliseconds = 16.0;
static const unsigned int kPrefixIterationLimit = 200;
static const unsigned int kReturnIterationLimit = 200;

typedef enum {
  ContrastArmNone = 0,
  ContrastArmGPView = 1,
  ContrastArmNSTextView = 2,
  ContrastArmBoth = 3,
} ContrastArm;

static NSDictionary *query_summary(ContrastArm arm);
static NSDictionary *native_callback_summary(ContrastArm arm);
static NSDictionary *geometry_summary(ContrastArm arm);

typedef enum {
  ContrastPhaseStart = 0,
  ContrastPhaseBaseline = 1,
  ContrastPhaseDispatch = 2,
  ContrastPhaseComposition = 3,
  ContrastPhaseReturn = 4,
  ContrastPhaseCleanup = 5,
  ContrastPhaseResult = 6,
  ContrastPhaseRecordLimit = 7,
} ContrastPhase;

typedef enum {
  ContrastOutcomeNone = 0,
  ContrastOutcomeReady = 1,
  ContrastOutcomePassed = 2,
  ContrastOutcomeFailed = 3,
  ContrastOutcomeNotComparable = 4,
  ContrastOutcomeCustomIntegration = 5,
  ContrastOutcomeCommonPathOrStandardAdapter = 6,
  ContrastOutcomeSourceAppLoopNotReproduced = 7,
  ContrastOutcomeSetupFailed = 8,
  ContrastOutcomeCleanupFailed = 9,
  ContrastOutcomeTraceTruncated = 10,
  ContrastOutcomeStateChangeWithoutCallback = 11,
  ContrastOutcomeTimedOut = 12,
} ContrastOutcome;

typedef enum {
  ContrastCompletionNone = 0,
  ContrastCompletionAcceptedBatchCommit = 1,
  ContrastCompletionInsertText = 2,
  ContrastCompletionUnmarkText = 3,
  ContrastCompletionStateChangeWithoutCallback = 4,
  ContrastCompletionMismatch = 5,
  ContrastCompletionTimeout = 6,
} ContrastCompletion;

typedef enum {
  ContrastSourceRestoreUnknown = 0,
  ContrastSourceRestoreNoChangeNeeded = 1,
  ContrastSourceRestorePerformed = 2,
  ContrastSourceRestoreNotSaved = 3,
  ContrastSourceRestoreFailed = 4,
} ContrastSourceRestore;

typedef enum {
  ContrastStartupSnapshotBeforePump = 0,
  ContrastStartupSnapshotAfterPump = 1,
} ContrastStartupSnapshotStage;

typedef enum {
  ContrastStartupClosedNone = 0,
  ContrastStartupClosedReady = 1,
  ContrastStartupClosedOwnedPrecheck = 2,
  ContrastStartupClosedHost = 3,
  ContrastStartupClosedPump = 4,
  ContrastStartupClosedUnexpectedInput = 5,
  ContrastStartupClosedUnexpectedEvent = 6,
  ContrastStartupClosedIterationLimit = 7,
  ContrastStartupClosedOther = 8,
} ContrastStartupClosedReason;

static GPUIContrastRecordBudget gBudget;
static const GpuiApi *gApi;
static GPWindow *gOwner;
static NSWindow *gOwnedWindow;
static id gLocalMonitor;
static NSString *gStandardOriginalSource;
static BOOL gStandardSourceWasNil;
static BOOL gStandardSourceSaved;
static BOOL gWindowClosed;
static BOOL gHostStopped;
static BOOL gRecordTruncated;
static BOOL gRunIncomplete;
static BOOL gCaptureEffects;
static BOOL gCaptureNaturalQueries;
static BOOL gStartupWaiting;
static BOOL gStartupUnexpectedInput;
static BOOL gGPViewObserved;
static BOOL gGPViewPassed;
static BOOL gStandardObserved;
static BOOL gStandardPassed;
static BOOL gArmPreconditionsValid[3];
static BOOL gGPViewRestoreNeeded;
static BOOL gStandardRestoreNeeded;
static BOOL gGPViewRestoreVerified;
static BOOL gStandardRestoreVerified;
static ContrastSourceRestore gGPViewRestoreStatus;
static ContrastSourceRestore gStandardRestoreStatus;
static ContrastCompletion gCompletionKind[3];
static BOOL gGPViewOriginalSourceSaved;
static BOOL gGPViewOriginalSourceWasNil;
static NSString *gGPViewOriginalSource;
static BOOL gGPViewSourceSelectionAttempted;
static BOOL gStandardSourceSelectionAttempted;
static BOOL gGPViewCleaned;
static BOOL gStandardCleaned;
static BOOL gGPViewCleanupResult;
static BOOL gStandardCleanupResult;
static double gCommonScale;
static int64_t gContrastHostEpoch;
static unsigned int gStartupIterations[3];
static BOOL gStartupReady[3];
static NSMutableDictionary *gStartupCurrentSnapshot;
static NSDictionary *gStartupFirstSnapshot[3];
static NSDictionary *gStartupTerminalSnapshot[3];
static unsigned int gPrefixIterations[3];
static unsigned int gReturnIterations[3];
static unsigned int gCallbackPreedit[3];
static unsigned int gCallbackCommit[3];
static unsigned int gCallbackUnmark[3];
static unsigned int gCallbackForwarded[3];
static unsigned int gGPViewInsertBaseline;
static unsigned int gStandardInsertBaseline;
static unsigned int gGPViewCommandBaseline;
static unsigned int gStandardCommandBaseline;
static unsigned int gGPViewMarkBaseline;
static unsigned int gGPViewUnmarkBaseline;
static unsigned int gStandardMarkBaseline;
static unsigned int gStandardUnmarkBaseline;
static unsigned int gGPViewBatchCommitBaseline;
static unsigned int gGPViewBatchPreeditBaseline;
static unsigned int gGPViewBatchUnmarkBaseline;
static unsigned int gGPViewBatchForwardedBaseline;
static unsigned int gStandardBatchCommitBaseline;
static unsigned int gReturnInsertDelta[3];
static unsigned int gReturnMarkDelta[3];
static unsigned int gReturnUnmarkDelta[3];
static unsigned int gReturnCommandDelta[3];
static unsigned int gReturnBatchPreeditDelta[3];
static unsigned int gReturnBatchCommitDelta[3];
static unsigned int gReturnBatchUnmarkDelta[3];
static unsigned int gReturnBatchForwardedDelta[3];
static unsigned int gGPViewBaselineFrame;
static unsigned int gLastGPViewAckFrame;
static int64_t gGPViewOwnerRevisionBaseline;
static int64_t gGPViewBaselineBatch;

@class ContrastObservation;
static ContrastObservation *gObservations[3];

typedef struct {
  BOOL attempted;
  BOOL preconditions_valid;
  BOOL observed;
  BOOL passed;
  BOOL cleanup_ok;
} ContrastArmResult;

typedef struct {
  BOOL active;
  int64_t dispatch_id;
  int key_index;
  int key_code;
  NSString *characters;
  NSString *ignoring;
  BOOL monitor_down;
  BOOL monitor_up;
  BOOL monitor_down_valid;
  BOOL monitor_up_valid;
  BOOL view_down;
  BOOL view_up;
  BOOL view_down_valid;
  BOOL view_up_valid;
} ContrastPendingKey;

static ContrastPendingKey gPendingKey;

static id startup_observed_bool_value(BOOL evaluated, BOOL value) {
  GPUIContrastObservedFact fact;
  gpui_contrast_reset_observed_fact(&fact);
  if (evaluated) gpui_contrast_capture_observed_fact(&fact, value);
  GPUIContrastObservedBool observed = gpui_contrast_observed_fact_value(fact);
  if (observed == GPUIContrastObservedUnknown) return NSNull.null;
  return @(observed == GPUIContrastObservedTrue);
}

static void startup_snapshot_bool(NSString *key, BOOL evaluated, BOOL value) {
  if (gStartupCurrentSnapshot) gStartupCurrentSnapshot[key] =
    startup_observed_bool_value(evaluated, value);
}

static void startup_snapshot_number(NSString *key, BOOL evaluated, long long value) {
  if (gStartupCurrentSnapshot) gStartupCurrentSnapshot[key] =
    evaluated ? @(value) : NSNull.null;
}

static void startup_snapshot_reset(ContrastArm arm, ContrastStartupSnapshotStage stage,
                                  unsigned int iteration, int64_t expected_host_epoch) {
  gStartupCurrentSnapshot = [@{
    @"stage": @(stage), @"iteration": @(iteration),
    @"expected_host_epoch": @(expected_host_epoch),
    @"app_active": startup_observed_bool_value(NO, NO),
    @"owned_window_present": startup_observed_bool_value(NO, NO),
    @"window_visible": startup_observed_bool_value(NO, NO),
    @"window_key": startup_observed_bool_value(NO, NO),
    @"app_key_window_matches": startup_observed_bool_value(NO, NO),
    @"first_responder_is_client": startup_observed_bool_value(NO, NO),
    @"app_owns_client": startup_observed_bool_value(NO, NO),
    @"view_input_context_present": startup_observed_bool_value(NO, NO),
    @"current_context_matches": startup_observed_bool_value(NO, NO),
    @"context_client_matches": startup_observed_bool_value(NO, NO),
    @"context_matches_client": startup_observed_bool_value(NO, NO),
    @"focus_predicate": startup_observed_bool_value(NO, NO),
    @"context_predicate": startup_observed_bool_value(NO, NO),
    @"api_present": startup_observed_bool_value(NO, NO),
    @"host_state": NSNull.null, @"host_epoch": NSNull.null,
    @"activation_policy": NSApp ? @(NSApp.activationPolicy) : NSNull.null,
    @"host_epoch_matches_expected": startup_observed_bool_value(NO, NO),
    @"host_stopped": startup_observed_bool_value(NO, NO),
    @"host_running": startup_observed_bool_value(NO, NO),
    @"owned_precheck_valid": startup_observed_bool_value(NO, NO),
    @"pump_status": NSNull.null, @"event_kind": NSNull.null,
    @"event_token_owned": startup_observed_bool_value(NO, NO),
    @"owned_window_event": startup_observed_bool_value(NO, NO),
    @"unexpected_input": startup_observed_bool_value(NO, NO),
    @"event_allowed": startup_observed_bool_value(NO, NO),
    @"decision": NSNull.null,
    @"closed_reason": @(ContrastStartupClosedNone),
    @"arm": @(arm),
  } mutableCopy];
}

static const char *arm_name(ContrastArm arm) {
  switch (arm) {
    case ContrastArmGPView: return "gpview";
    case ContrastArmNSTextView: return "nstextview";
    case ContrastArmBoth: return "both";
    default: return "none";
  }
}

static const char *phase_name(ContrastPhase phase) {
  switch (phase) {
    case ContrastPhaseStart: return "arm_start";
    case ContrastPhaseBaseline: return "baseline";
    case ContrastPhaseDispatch: return "dispatch_receipt";
    case ContrastPhaseComposition: return "composition_ready";
    case ContrastPhaseReturn: return "return_outcome";
    case ContrastPhaseCleanup: return "cleanup";
    case ContrastPhaseResult: return "result";
    case ContrastPhaseRecordLimit: return "record_limit";
  }
  return "none";
}

static const char *outcome_name(ContrastOutcome outcome) {
  switch (outcome) {
    case ContrastOutcomeReady: return "ready";
    case ContrastOutcomePassed: return "passed";
    case ContrastOutcomeFailed: return "failed";
    case ContrastOutcomeNotComparable: return "not_comparable";
    case ContrastOutcomeCustomIntegration: return "custom_integration";
    case ContrastOutcomeCommonPathOrStandardAdapter: return "common_path_or_standard_adapter";
    case ContrastOutcomeSourceAppLoopNotReproduced: return "source_app_loop_not_reproduced";
    case ContrastOutcomeSetupFailed: return "setup_failed";
    case ContrastOutcomeCleanupFailed: return "cleanup_failed";
    case ContrastOutcomeTraceTruncated: return "trace_truncated";
    case ContrastOutcomeStateChangeWithoutCallback: return "state_change_without_callback";
    case ContrastOutcomeTimedOut: return "timed_out";
    default: return "none";
  }
}

static const char *completion_name(ContrastCompletion completion) {
  switch (completion) {
    case ContrastCompletionAcceptedBatchCommit: return "accepted_batch_commit";
    case ContrastCompletionInsertText: return "insert_text";
    case ContrastCompletionUnmarkText: return "unmark_text";
    case ContrastCompletionStateChangeWithoutCallback: return "state_change_without_callback";
    case ContrastCompletionMismatch: return "mismatch";
    case ContrastCompletionTimeout: return "timeout";
    default: return "none";
  }
}

static const char *source_restore_name(ContrastArm arm) {
  ContrastSourceRestore status = arm == ContrastArmGPView ? gGPViewRestoreStatus :
    arm == ContrastArmNSTextView ? gStandardRestoreStatus : ContrastSourceRestoreUnknown;
  switch (status) {
    case ContrastSourceRestoreNoChangeNeeded: return "no_change_needed";
    case ContrastSourceRestorePerformed: return "restored";
    case ContrastSourceRestoreNotSaved: return "not_saved";
    case ContrastSourceRestoreFailed: return "failed";
    default: return "unknown";
  }
}

static id nullable_number(BOOL available, long long value) {
  return available ? (id)@(value) : (id)NSNull.null;
}

static void emit_record(ContrastPhase phase, ContrastArm arm, ContrastOutcome outcome,
                        int index, int key_index, int key_code, unsigned int iterations,
                        BOOL expected_text, BOOL has_marked, BOOL focus_ok,
                        BOOL context_ok, BOOL source_ok, BOOL down_ok, BOOL up_ok,
                        NSUInteger text_length, NSRange selection, NSRange marked,
                        unsigned int preedit_count, unsigned int commit_count,
                        unsigned int unmark_count, BOOL cleanup_ok, BOOL terminal) {
  GPUIContrastBudgetDecision decision = terminal ?
    gpui_contrast_claim_terminal(&gBudget) : gpui_contrast_claim_ordinary(&gBudget);
  if (decision == GPUIContrastBudgetTruncation) {
    gRecordTruncated = YES;
    gRunIncomplete = YES;
    NSDictionary *record = @{
      @"schema_version": @1, @"phase": @"record_limit", @"arm": @"both",
      @"outcome": @"trace_truncated", @"record_count": @(gBudget.total),
    };
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (json) {
      fputs("GPUI_MACOS_NSTEXTVIEW_CONTRAST ", stderr);
      (void)fwrite(json.bytes, 1, json.length, stderr);
      fputc('\n', stderr);
      fflush(stderr);
    }
    return;
  }
  if (decision == GPUIContrastBudgetBlocked) {
    gRunIncomplete = YES;
    return;
  }
  id startup_observation = NSNull.null;
  if (phase == ContrastPhaseBaseline &&
      (arm == ContrastArmGPView || arm == ContrastArmNSTextView)) {
    startup_observation = @{
      @"first": gStartupFirstSnapshot[arm] ?: NSNull.null,
      @"terminal": gStartupTerminalSnapshot[arm] ?: NSNull.null,
    };
  }
  NSMutableDictionary *record = [@{
    @"schema_version": @1,
    @"phase": @(phase_name(phase)),
    @"arm": @(arm_name(arm)),
    @"outcome": @(outcome_name(outcome)),
    @"index": @(index),
    @"key_index": nullable_number(key_index >= 0, key_index),
    @"key_code": nullable_number(key_code >= 0, key_code),
    @"loop_iterations": @(iterations),
    @"startup_wait_iterations": @(arm == ContrastArmBoth ?
      gStartupIterations[ContrastArmGPView] + gStartupIterations[ContrastArmNSTextView] :
      ((arm == ContrastArmGPView || arm == ContrastArmNSTextView) ? gStartupIterations[arm] : 0)),
    @"startup_ready": @(arm == ContrastArmBoth ?
      gStartupReady[ContrastArmGPView] && gStartupReady[ContrastArmNSTextView] :
      ((arm == ContrastArmGPView || arm == ContrastArmNSTextView) && gStartupReady[arm])),
    @"prefix_loop_iterations": @(arm == ContrastArmBoth ?
      gPrefixIterations[ContrastArmGPView] + gPrefixIterations[ContrastArmNSTextView] :
      (arm == ContrastArmGPView || arm == ContrastArmNSTextView ? gPrefixIterations[arm] : 0)),
    @"return_loop_iterations": @(arm == ContrastArmBoth ?
      gReturnIterations[ContrastArmGPView] + gReturnIterations[ContrastArmNSTextView] :
      (arm == ContrastArmGPView || arm == ContrastArmNSTextView ? gReturnIterations[arm] : 0)),
    @"preconditions_valid": @(arm == ContrastArmBoth ?
      gArmPreconditionsValid[ContrastArmGPView] && gArmPreconditionsValid[ContrastArmNSTextView] :
      ((arm == ContrastArmGPView || arm == ContrastArmNSTextView) ? gArmPreconditionsValid[arm] : NO)),
    @"return_observed": @(arm == ContrastArmBoth ?
      gGPViewObserved && gStandardObserved :
      (arm == ContrastArmGPView ? gGPViewObserved :
        (arm == ContrastArmNSTextView ? gStandardObserved : NO))),
    @"return_passed": @(arm == ContrastArmBoth ?
      gGPViewPassed && gStandardPassed :
      (arm == ContrastArmGPView ? gGPViewPassed :
        (arm == ContrastArmNSTextView ? gStandardPassed : NO))),
    @"completion_kind": @(arm == ContrastArmBoth ? "both" :
      completion_name((arm == ContrastArmGPView || arm == ContrastArmNSTextView) ?
        gCompletionKind[arm] : ContrastCompletionNone)),
    @"source_restore_status": @(source_restore_name(arm)),
    @"source_restore_needed": @(arm == ContrastArmGPView ? gGPViewRestoreNeeded :
      (arm == ContrastArmNSTextView ? gStandardRestoreNeeded : NO)),
    @"source_restore_verified": @(arm == ContrastArmGPView ? gGPViewRestoreVerified :
      (arm == ContrastArmNSTextView ? gStandardRestoreVerified :
        (gGPViewRestoreVerified && gStandardRestoreVerified))),
    @"expected_text": @(expected_text),
    @"has_marked_text": @(has_marked),
    @"focus_owned": @(focus_ok),
    @"context_matches_client": @(context_ok),
    @"source_selected": @(source_ok),
    @"down_delivered": @(down_ok),
    @"up_delivered": @(up_ok),
    @"text_utf16_length": @(text_length),
    @"selection_start": nullable_number(selection.location != NSNotFound, (long long)selection.location),
    @"selection_length": nullable_number(selection.location != NSNotFound, (long long)selection.length),
    @"marked_start": nullable_number(marked.location != NSNotFound, (long long)marked.location),
    @"marked_length": nullable_number(marked.location != NSNotFound, (long long)marked.length),
    @"preedit_callback_count": @(preedit_count),
    @"commit_callback_count": @(commit_count),
    @"unmark_callback_count": @(unmark_count),
    @"forwarded_callback_count": @(arm >= ContrastArmGPView && arm <= ContrastArmNSTextView ?
      gCallbackForwarded[arm] : gCallbackForwarded[ContrastArmGPView] +
        gCallbackForwarded[ContrastArmNSTextView]),
    @"accepted_batch_callbacks": @{
      @"preedit": @(preedit_count), @"commit": @(commit_count),
      @"cancelled": @(unmark_count),
    },
    @"accepted_batch_return_delta": @{
      @"preedit": @(arm == ContrastArmGPView || arm == ContrastArmNSTextView ?
        gReturnBatchPreeditDelta[arm] : gReturnBatchPreeditDelta[ContrastArmGPView] +
          gReturnBatchPreeditDelta[ContrastArmNSTextView]),
      @"commit": @(arm == ContrastArmGPView || arm == ContrastArmNSTextView ?
        gReturnBatchCommitDelta[arm] : gReturnBatchCommitDelta[ContrastArmGPView] +
          gReturnBatchCommitDelta[ContrastArmNSTextView]),
      @"cancelled": @(arm == ContrastArmGPView || arm == ContrastArmNSTextView ?
        gReturnBatchUnmarkDelta[arm] : gReturnBatchUnmarkDelta[ContrastArmGPView] +
          gReturnBatchUnmarkDelta[ContrastArmNSTextView]),
      @"forwarded": @(arm == ContrastArmGPView || arm == ContrastArmNSTextView ?
        gReturnBatchForwardedDelta[arm] : gReturnBatchForwardedDelta[ContrastArmGPView] +
          gReturnBatchForwardedDelta[ContrastArmNSTextView]),
    },
    @"native_client_callbacks": native_callback_summary(arm) ?: @{},
    @"natural_client_queries": query_summary(arm) ?: @{},
    @"geometry": geometry_summary(arm) ?: @{},
    @"cleanup_ok": @(cleanup_ok),
  } mutableCopy];
  if (startup_observation != NSNull.null)
    record[@"startup_observation"] = startup_observation;
  if (decision != GPUIContrastBudgetOrdinary && decision != GPUIContrastBudgetTerminal) {
    gRunIncomplete = YES;
    return;
  }
  NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
  if (!json || !json.length) { gRunIncomplete = YES; return; }
  fputs("GPUI_MACOS_NSTEXTVIEW_CONTRAST ", stderr);
  (void)fwrite(json.bytes, 1, json.length, stderr);
  fputc('\n', stderr);
  fflush(stderr);
}

static NSString *contrast_characters(GPUIContrastCharacter character) {
  switch (character) {
    case GPUIContrastCharacterN: return @"n";
    case GPUIContrastCharacterI: return @"i";
    case GPUIContrastCharacterH: return @"h";
    case GPUIContrastCharacterO: return @"o";
    case GPUIContrastCharacterG: return @"g";
    case GPUIContrastCharacterSpace: return @" ";
    case GPUIContrastCharacterReturn: return @"\r";
  }
  return nil;
}

static unsigned int contrast_modifier_bits(NSEventModifierFlags flags) {
  const NSUInteger mask = NSEventModifierFlagShift | NSEventModifierFlagControl |
    NSEventModifierFlagOption | NSEventModifierFlagCommand;
  NSUInteger value = flags & mask;
  return ((value & NSEventModifierFlagShift) ? 1u : 0u) |
    ((value & NSEventModifierFlagControl) ? 2u : 0u) |
    ((value & NSEventModifierFlagOption) ? 4u : 0u) |
    ((value & NSEventModifierFlagCommand) ? 8u : 0u);
}

static BOOL contrast_event_valid(NSEvent *event, BOOL down, BOOL require_window) {
  if (!gPendingKey.active || !event) return NO;
  CGEventRef cg_event = event.CGEvent;
  if (!cg_event) return NO;
  int64_t event_nonce = CGEventGetIntegerValueField(cg_event, kCGEventSourceUserData);
  int64_t expected_nonce = INT64_C(0x4750554900000000) | gPendingKey.dispatch_id;
  BOOL type_matches = event.type == (down ? NSEventTypeKeyDown : NSEventTypeKeyUp);
  BOOL target_matches = require_window && gOwnedWindow && event.window == gOwnedWindow &&
    event.windowNumber == gOwnedWindow.windowNumber;
  BOOL valid = gpui_contrast_delivery_valid(
    event_nonce == expected_nonce,
    type_matches,
    event.keyCode == (unsigned short)gPendingKey.key_code,
    [(event.characters ?: @"") isEqualToString:gPendingKey.characters],
    [(event.charactersIgnoringModifiers ?: @"") isEqualToString:gPendingKey.ignoring],
    contrast_modifier_bits(event.modifierFlags), target_matches);
  if (down) {
    gPendingKey.monitor_down = YES;
    gPendingKey.monitor_down_valid = valid;
  } else {
    gPendingKey.monitor_up = YES;
    gPendingKey.monitor_up_valid = valid;
  }
  return valid;
}

static void note_standard_view_event(NSEvent *event, BOOL down) {
  if (!gPendingKey.active || !event) return;
  BOOL valid = contrast_event_valid(event, down, YES);
  if (down) {
    gPendingKey.view_down = YES;
    gPendingKey.view_down_valid = valid;
  } else {
    gPendingKey.view_up = YES;
    gPendingKey.view_up_valid = valid;
  }
}

@interface ContrastObservation : NSObject
@property(nonatomic) unsigned int insertCount;
@property(nonatomic) unsigned int markCount;
@property(nonatomic) unsigned int unmarkCount;
@property(nonatomic) unsigned int commandCount;
@property(nonatomic) unsigned int callbackDepth;
@property(nonatomic) NSUInteger lastCallbackLength;
@property(nonatomic) BOOL lastCallbackWasExpected;
@property(nonatomic) NSUInteger lastInsertLength;
@property(nonatomic) BOOL lastInsertWasExpected;
@property(nonatomic) NSUInteger substringCount;
@property(nonatomic) NSUInteger firstRectCount;
@property(nonatomic) NSUInteger characterIndexCount;
@property(nonatomic) NSUInteger hasMarkedCount;
@property(nonatomic) NSUInteger selectedRangeCount;
@property(nonatomic) NSUInteger markedRangeCount;
@property(nonatomic) NSUInteger attributesCount;
@property(nonatomic) NSRange firstSubstringRequest;
@property(nonatomic) NSRange firstSubstringActual;
@property(nonatomic) NSUInteger firstSubstringLength;
@property(nonatomic) BOOL firstSubstringWasNil;
@property(nonatomic) BOOL firstSubstringActualKnown;
@property(nonatomic) NSRange firstRectRequest;
@property(nonatomic) NSRange firstRectActual;
@property(nonatomic) NSRect firstRectValue;
@property(nonatomic) BOOL firstRectActualKnown;
@property(nonatomic) BOOL hasFirstSubstring;
@property(nonatomic) BOOL hasFirstRect;
@property(nonatomic) BOOL hasFirstCharacterIndex;
@property(nonatomic) NSUInteger firstCharacterIndex;
@property(nonatomic) uint64_t attributeBits;
@end
@implementation ContrastObservation
@end

static void observe_insert(ContrastObservation *observation, id value) {
  if (!gCaptureEffects || !observation) return;
  if (observation.callbackDepth == 0) {
    observation.insertCount++;
    NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] :
      ([value isKindOfClass:NSString.class] ? value : nil);
    observation.lastInsertLength = text.length;
    observation.lastInsertWasExpected = [text isEqualToString:kExpectedCommit];
  }
}

static void observe_mark(ContrastObservation *observation, id value) {
  if (!gCaptureEffects || !observation || observation.callbackDepth > 0) return;
  observation.markCount++;
  NSString *text = [value isKindOfClass:NSAttributedString.class] ? [value string] :
    ([value isKindOfClass:NSString.class] ? value : nil);
  observation.lastCallbackLength = text.length;
  observation.lastCallbackWasExpected = [text isEqualToString:kExpectedComposition];
}

static void observe_unmark(ContrastObservation *observation) {
  if (gCaptureEffects && observation && observation.callbackDepth == 0) observation.unmarkCount++;
}

static void observe_command(ContrastObservation *observation) {
  if (gCaptureEffects && observation) observation.commandCount++;
}

static uint64_t known_attribute_bits(NSArray<NSAttributedStringKey> *attributes) {
  static NSArray<NSString *> *known;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    known = @[
      NSUnderlineStyleAttributeName, NSMarkedClauseSegmentAttributeName,
      NSFontAttributeName, NSForegroundColorAttributeName,
      NSBackgroundColorAttributeName, NSLinkAttributeName, NSAttachmentAttributeName,
    ];
  });
  uint64_t bits = 0;
  for (NSUInteger i = 0; i < known.count; i++)
    if ([attributes containsObject:known[i]]) bits |= (UINT64_C(1) << i);
  return bits;
}

static void observe_attributes(ContrastObservation *observation,
                              NSArray<NSAttributedStringKey> *attributes) {
  if (!gCaptureNaturalQueries || !observation) return;
  observation.attributesCount++;
  observation.attributeBits = known_attribute_bits(attributes);
}

static NSDictionary *range_summary(NSRange range, BOOL known) {
  return @{
    @"known": @(known),
    @"start": nullable_number(known && range.location != NSNotFound,
      range.location == NSNotFound ? 0 : (long long)range.location),
    @"length": nullable_number(known && range.location != NSNotFound,
      range.location == NSNotFound ? 0 : (long long)range.length),
  };
}

static id nullable_milli(BOOL available, double value) {
  if (!available || !isfinite(value) || fabs(value) > (double)LLONG_MAX / 1000.0) return NSNull.null;
  return @((long long)llround(value * 1000.0));
}

static NSDictionary *native_callback_summary(ContrastArm arm) {
  if (arm < ContrastArmGPView || arm > ContrastArmNSTextView) return @{};
  ContrastObservation *observation = gObservations[arm];
  return @{
    @"insert_text": @(observation.insertCount),
    @"set_marked_text": @(observation.markCount),
    @"unmark_text": @(observation.unmarkCount),
    @"do_command_by_selector": @(observation.commandCount),
    @"last_insert_utf16_length": nullable_number(observation.insertCount > 0,
      (long long)observation.lastInsertLength),
    @"last_insert_matches_expected": nullable_number(observation.insertCount > 0,
      observation.lastInsertWasExpected),
    @"return_delta": @{
      @"insert_text": @(gReturnInsertDelta[arm]),
      @"set_marked_text": @(gReturnMarkDelta[arm]),
      @"unmark_text": @(gReturnUnmarkDelta[arm]),
      @"do_command_by_selector": @(gReturnCommandDelta[arm]),
    },
  };
}

static NSDictionary *query_summary(ContrastArm arm) {
  if (arm < ContrastArmGPView || arm > ContrastArmNSTextView) return @{};
  ContrastObservation *observation = gObservations[arm];
  NSRect rect = observation.firstRectValue;
  BOOL rect_finite = observation.hasFirstRect && isfinite(NSMinX(rect)) &&
    isfinite(NSMinY(rect)) && isfinite(NSWidth(rect)) && isfinite(NSHeight(rect));
  return @{
    @"has_marked_text": @(observation.hasMarkedCount),
    @"marked_range": @(observation.markedRangeCount),
    @"selected_range": @(observation.selectedRangeCount),
    @"attributed_substring": @{
      @"count": @(observation.substringCount),
      @"request": range_summary(observation.firstSubstringRequest, observation.hasFirstSubstring),
      @"actual": range_summary(observation.firstSubstringActual,
        observation.hasFirstSubstring && observation.firstSubstringActualKnown),
      @"result_was_nil": nullable_number(observation.hasFirstSubstring,
        observation.firstSubstringWasNil),
      @"result_utf16_length": nullable_number(observation.hasFirstSubstring,
        (long long)observation.firstSubstringLength),
    },
    @"first_rect": @{
      @"count": @(observation.firstRectCount),
      @"request": range_summary(observation.firstRectRequest, observation.hasFirstRect),
      @"actual": range_summary(observation.firstRectActual,
        observation.hasFirstRect && observation.firstRectActualKnown),
      @"finite": nullable_number(observation.hasFirstRect, rect_finite),
      @"x": nullable_milli(rect_finite, NSMinX(rect)),
      @"y": nullable_milli(rect_finite, NSMinY(rect)),
      @"width": nullable_milli(rect_finite, NSWidth(rect)),
      @"height": nullable_milli(rect_finite, NSHeight(rect)),
    },
    @"character_index_for_point": @{
      @"count": @(observation.characterIndexCount),
      @"first_result": nullable_number(observation.hasFirstCharacterIndex,
        (long long)observation.firstCharacterIndex),
    },
    @"valid_attributes_for_marked_text": @{
      @"count": @(observation.attributesCount),
      @"known_bits": nullable_number(observation.attributesCount > 0,
        (long long)observation.attributeBits),
    },
  };
}

static void reset_query_observation(ContrastObservation *observation) {
  if (!observation) return;
  observation.hasMarkedCount = 0;
  observation.markedRangeCount = 0;
  observation.selectedRangeCount = 0;
  observation.substringCount = 0;
  observation.firstRectCount = 0;
  observation.characterIndexCount = 0;
  observation.attributesCount = 0;
  observation.hasFirstSubstring = NO;
  observation.hasFirstRect = NO;
  observation.hasFirstCharacterIndex = NO;
  observation.attributeBits = 0;
}

@interface ContrastGPView : GPView
@property(nonatomic) ContrastObservation *observation;
@end
@implementation ContrastGPView
- (void)insertText:(id)value {
  ContrastObservation *observation = self.observation;
  observe_insert(observation, value);
  observation.callbackDepth++;
  @try { [super insertText:value]; }
  @finally { observation.callbackDepth--; }
}
- (void)insertText:(id)value replacementRange:(NSRange)replacementRange {
  ContrastObservation *observation = self.observation;
  observe_insert(observation, value);
  observation.callbackDepth++;
  @try { [super insertText:value replacementRange:replacementRange]; }
  @finally { observation.callbackDepth--; }
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
  ContrastObservation *observation = self.observation;
  observe_mark(observation, value);
  observation.callbackDepth++;
  @try { [super setMarkedText:value selectedRange:selectedRange replacementRange:replacementRange]; }
  @finally { observation.callbackDepth--; }
}
- (void)unmarkText {
  ContrastObservation *observation = self.observation;
  observe_unmark(observation);
  observation.callbackDepth++;
  @try { [super unmarkText]; }
  @finally { observation.callbackDepth--; }
}
- (void)doCommandBySelector:(SEL)selector {
  observe_command(self.observation);
  [super doCommandBySelector:selector];
}
- (BOOL)hasMarkedText {
  if (gCaptureNaturalQueries) self.observation.hasMarkedCount++;
  return [super hasMarkedText];
}
- (NSRange)markedRange {
  if (gCaptureNaturalQueries) self.observation.markedRangeCount++;
  return [super markedRange];
}
- (NSRange)selectedRange {
  if (gCaptureNaturalQueries) self.observation.selectedRangeCount++;
  return [super selectedRange];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  NSAttributedString *value = [super attributedSubstringForProposedRange:range actualRange:actualRange];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.substringCount++;
    if (!observation.hasFirstSubstring) {
      observation.hasFirstSubstring = YES;
      observation.firstSubstringRequest = range;
      observation.firstSubstringActualKnown = actualRange != NULL && value != nil;
      observation.firstSubstringActual = observation.firstSubstringActualKnown ?
        *actualRange : NSMakeRange(NSNotFound, 0);
      observation.firstSubstringLength = value.length;
      observation.firstSubstringWasNil = value == nil;
    }
  }
  return value;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  NSRect value = [super firstRectForCharacterRange:range actualRange:actualRange];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.firstRectCount++;
    if (!observation.hasFirstRect) {
      observation.hasFirstRect = YES;
      observation.firstRectRequest = range;
      observation.firstRectActualKnown = actualRange != NULL && !NSIsEmptyRect(value) &&
        isfinite(NSMinX(value)) && isfinite(NSMinY(value)) && isfinite(NSWidth(value)) &&
        isfinite(NSHeight(value));
      observation.firstRectActual = observation.firstRectActualKnown ?
        *actualRange : NSMakeRange(NSNotFound, 0);
      observation.firstRectValue = value;
    }
  }
  return value;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  NSUInteger value = [super characterIndexForPoint:point];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.characterIndexCount++;
    if (!observation.hasFirstCharacterIndex) {
      observation.hasFirstCharacterIndex = YES;
      observation.firstCharacterIndex = value;
    }
  }
  return value;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
  NSArray<NSAttributedStringKey> *value = [super validAttributesForMarkedText];
  observe_attributes(self.observation, value);
  return value;
}
@end

static ContrastGPView *install_gpview_observer(GPWindow *owner) {
  if (!owner || !owner.window || windows[@(owner.token)] != owner) return nil;
  GPView *original = [owner.window.contentView isKindOfClass:GPView.class] ?
    (GPView *)owner.window.contentView : nil;
  CAMetalLayer *surface = owner.surface;
  if (!original || !surface || original.layer != surface || original.owner != owner) return nil;
  ContrastGPView *observer = [[ContrastGPView alloc] initWithFrame:original.frame];
  if (!observer) return nil;
  observer.observation = gObservations[ContrastArmGPView];
  observer.autoresizingMask = original.autoresizingMask;
  observer.wantsLayer = YES;
  observer.owner = owner;
  observer.layer = surface;
  if (observer.layer != surface) return nil;
  original.owner = nil;
  original.layer = nil;
  owner.window.contentView = observer;
  if (owner.window.contentView != observer || observer.owner != owner || owner.surface != surface)
    return nil;
  if (![owner.window makeFirstResponder:observer]) return nil;
  return observer;
}

@interface ContrastTextView : NSTextView
@property(nonatomic) ContrastObservation *observation;
@property(nonatomic) unsigned int keyDownCount;
@property(nonatomic) unsigned int keyUpCount;
@end
@implementation ContrastTextView
- (void)keyDown:(NSEvent *)event {
  self.keyDownCount++;
  note_standard_view_event(event, YES);
  [super keyDown:event];
}
- (void)keyUp:(NSEvent *)event {
  self.keyUpCount++;
  note_standard_view_event(event, NO);
  [super keyUp:event];
}
- (void)insertText:(id)value {
  ContrastObservation *observation = self.observation;
  observe_insert(observation, value);
  observation.callbackDepth++;
  @try { [super insertText:value]; }
  @finally { observation.callbackDepth--; }
}
- (void)insertText:(id)value replacementRange:(NSRange)replacementRange {
  ContrastObservation *observation = self.observation;
  observe_insert(observation, value);
  observation.callbackDepth++;
  @try { [super insertText:value replacementRange:replacementRange]; }
  @finally { observation.callbackDepth--; }
}
- (void)setMarkedText:(id)value selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
  ContrastObservation *observation = self.observation;
  observe_mark(observation, value);
  observation.callbackDepth++;
  @try { [super setMarkedText:value selectedRange:selectedRange replacementRange:replacementRange]; }
  @finally { observation.callbackDepth--; }
}
- (void)unmarkText {
  ContrastObservation *observation = self.observation;
  observe_unmark(observation);
  observation.callbackDepth++;
  @try { [super unmarkText]; }
  @finally { observation.callbackDepth--; }
}
- (void)doCommandBySelector:(SEL)selector {
  observe_command(self.observation);
  [super doCommandBySelector:selector];
}
- (BOOL)hasMarkedText {
  if (gCaptureNaturalQueries) self.observation.hasMarkedCount++;
  return [super hasMarkedText];
}
- (NSRange)markedRange {
  if (gCaptureNaturalQueries) self.observation.markedRangeCount++;
  return [super markedRange];
}
- (NSRange)selectedRange {
  if (gCaptureNaturalQueries) self.observation.selectedRangeCount++;
  return [super selectedRange];
}
- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  NSAttributedString *value = [super attributedSubstringForProposedRange:range actualRange:actualRange];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.substringCount++;
    if (!observation.hasFirstSubstring) {
      observation.hasFirstSubstring = YES;
      observation.firstSubstringRequest = range;
      observation.firstSubstringActualKnown = actualRange != NULL && value != nil;
      observation.firstSubstringActual = observation.firstSubstringActualKnown ?
        *actualRange : NSMakeRange(NSNotFound, 0);
      observation.firstSubstringLength = value.length;
      observation.firstSubstringWasNil = value == nil;
    }
  }
  return value;
}
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
  NSRect value = [super firstRectForCharacterRange:range actualRange:actualRange];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.firstRectCount++;
    if (!observation.hasFirstRect) {
      observation.hasFirstRect = YES;
      observation.firstRectRequest = range;
      observation.firstRectActualKnown = actualRange != NULL && !NSIsEmptyRect(value) &&
        isfinite(NSMinX(value)) && isfinite(NSMinY(value)) && isfinite(NSWidth(value)) &&
        isfinite(NSHeight(value));
      observation.firstRectActual = observation.firstRectActualKnown ?
        *actualRange : NSMakeRange(NSNotFound, 0);
      observation.firstRectValue = value;
    }
  }
  return value;
}
- (NSUInteger)characterIndexForPoint:(NSPoint)point {
  NSUInteger value = [super characterIndexForPoint:point];
  if (gCaptureNaturalQueries) {
    ContrastObservation *observation = self.observation;
    observation.characterIndexCount++;
    if (!observation.hasFirstCharacterIndex) {
      observation.hasFirstCharacterIndex = YES;
      observation.firstCharacterIndex = value;
    }
  }
  return value;
}
- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
  NSArray<NSAttributedStringKey> *value = [super validAttributesForMarkedText];
  observe_attributes(self.observation, value);
  return value;
}
@end

static void contrast_local_event_monitor(void) {
  gLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:
    (NSEventMaskKeyDown | NSEventMaskKeyUp) handler:^NSEvent *(NSEvent *event) {
      if (gStartupWaiting && event.window == gOwnedWindow) gStartupUnexpectedInput = YES;
      if (gPendingKey.active && event.window == gOwnedWindow) {
        (void)contrast_event_valid(event, event.type == NSEventTypeKeyDown, YES);
      }
      return event;
    }];
}

static NSString *session_payload(NSString *text, NSUInteger cursor,
                                 NSString *geometry_text, NSUInteger geometry_cursor,
                                 int64_t revision, int64_t ack_sequence) {
  double caret_x = 0, caret_y = 0, caret_height = 0;
  if (!measure_line_caret(geometry_text ?: text, geometry_cursor, &caret_x, &caret_y, &caret_height))
    return nil;
  NSDictionary *payload = @{
    @"text": text,
    @"cursor": @(cursor),
    @"anchor": @(cursor),
    @"utf16_length": @(text.length),
    @"owner_revision": @(revision),
    @"rect": @{
      @"x": @(14.0 + caret_x), @"y": @(14.0 + caret_y),
      @"width": @1.0, @"height": @(MAX(1.0, caret_height)),
    },
    @"external_edit": @NO,
    @"acknowledged_sequence": ack_sequence > 0 ? @(ack_sequence) : NSNull.null,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static NSString *scene_payload(NSString *visible_text) {
  NSDictionary *scene = @{
    @"schema_version": @1,
    @"viewport": @{@"x": @0, @"y": @0, @"width": @640, @"height": @240},
    @"scale": @(gOwner.scale),
    @"resources": @[],
    @"clip_chains": @[],
    @"items": @[@{
      @"kind": @"text", @"text": visible_text ?: @"", @"font_size": @18,
      @"bounds": @{@"x": @14, @"y": @14, @"width": @612, @"height": @32},
      @"transform": @{@"a": @1, @"b": @0, @"c": @0, @"d": @1, @"tx": @0, @"ty": @0},
      @"color": @{@"red": @255, @"green": @255, @"blue": @255, @"alpha": @255},
      @"opacity": @1, @"clip_chain_id": NSNull.null,
    }],
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:scene options:0 error:nil];
  return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}

static int call_text(int operation, int64_t token, double x, NSString *text) {
  NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
  if (!data || data.length > INT32_MAX) return 13;
  return gApi->call(operation, token, x, 0, data.bytes, (int32_t)data.length);
}

static BOOL app_owns_client(NSView *view) {
  BOOL app_active = NSApp.isActive;
  startup_snapshot_bool(@"app_active", YES, app_active);
  if (!app_active) {
    startup_snapshot_bool(@"app_owns_client", YES, NO);
    return NO;
  }
  BOOL window_present = gOwnedWindow != nil;
  startup_snapshot_bool(@"owned_window_present", YES, window_present);
  if (!window_present) {
    startup_snapshot_bool(@"app_owns_client", YES, NO);
    return NO;
  }
  BOOL window_visible = gOwnedWindow.isVisible;
  startup_snapshot_bool(@"window_visible", YES, window_visible);
  if (!window_visible) {
    startup_snapshot_bool(@"app_owns_client", YES, NO);
    return NO;
  }
  BOOL window_key = gOwnedWindow.isKeyWindow;
  startup_snapshot_bool(@"window_key", YES, window_key);
  if (!window_key) {
    startup_snapshot_bool(@"app_owns_client", YES, NO);
    return NO;
  }
  BOOL app_key_matches = NSApp.keyWindow == gOwnedWindow;
  startup_snapshot_bool(@"app_key_window_matches", YES, app_key_matches);
  if (!app_key_matches) {
    startup_snapshot_bool(@"app_owns_client", YES, NO);
    return NO;
  }
  BOOL first_responder_matches = gOwnedWindow.firstResponder == view;
  startup_snapshot_bool(@"first_responder_is_client", YES, first_responder_matches);
  startup_snapshot_bool(@"app_owns_client", YES, first_responder_matches);
  return first_responder_matches;
}

static BOOL context_matches_client(id<NSTextInputClient> client) {
  NSTextInputContext *context = [(NSView *)client inputContext];
  BOOL context_present = context != nil;
  startup_snapshot_bool(@"view_input_context_present", client != nil, context_present);
  if (!context_present) {
    startup_snapshot_bool(@"context_matches_client", YES, NO);
    return NO;
  }
  BOOL current_matches = NSTextInputContext.currentInputContext == context;
  startup_snapshot_bool(@"current_context_matches", YES, current_matches);
  if (!current_matches) {
    startup_snapshot_bool(@"context_matches_client", YES, NO);
    return NO;
  }
  BOOL context_client_matches = context.client == client;
  startup_snapshot_bool(@"context_client_matches", YES, context_client_matches);
  startup_snapshot_bool(@"context_matches_client", YES, context_client_matches);
  return context_client_matches;
}

static BOOL startup_identity_valid(ContrastArm arm, NSView *view,
                                   int64_t expected_host_epoch) {
  if (!view || !gApi || state != 1 || host_epoch <= 0 ||
      host_epoch != expected_host_epoch || gHostStopped ||
      !gOwnedWindow || !gOwnedWindow.isVisible ||
      !NSEqualSizes(gOwnedWindow.contentView.bounds.size, NSMakeSize(640, 240))) return NO;
  if (arm == ContrastArmGPView) {
    return gOwner && gOwner.window == gOwnedWindow && windows[@(gOwner.token)] == gOwner &&
      !gOwner.closing && gOwnedWindow.contentView == view &&
      [view isKindOfClass:ContrastGPView.class] && ((ContrastGPView *)view).owner == gOwner &&
      isfinite(gOwner.scale) && gOwner.scale > 0;
  }
  if (arm == ContrastArmNSTextView) {
    return gOwner && gOwner.window == gOwnedWindow && gOwner.closing &&
      windows.count == 0 && windows[@(gOwner.token)] != gOwner &&
      gOwnedWindow.contentView == view &&
      [view isKindOfClass:ContrastTextView.class] &&
      fabs(((ContrastTextView *)view).font.pointSize - 18.0) < 0.001 &&
      NSEqualSizes(((ContrastTextView *)view).textContainerInset, NSMakeSize(14, 14)) &&
      fabs(((ContrastTextView *)view).textContainer.lineFragmentPadding) < 0.001 &&
      fabs(gOwnedWindow.backingScaleFactor - gCommonScale) < 0.001;
  }
  return NO;
}

static BOOL startup_host_running(int64_t expected_host_epoch) {
  BOOL api_present = gApi != NULL;
  startup_snapshot_bool(@"api_present", YES, api_present);
  if (!api_present) {
    startup_snapshot_bool(@"host_running", YES, NO);
    return NO;
  }
  int host_state = state;
  startup_snapshot_number(@"host_state", YES, host_state);
  if (host_state != 1) {
    startup_snapshot_bool(@"host_running", YES, NO);
    return NO;
  }
  int64_t current_host_epoch = host_epoch;
  startup_snapshot_number(@"host_epoch", YES, current_host_epoch);
  if (current_host_epoch <= 0) {
    startup_snapshot_bool(@"host_running", YES, NO);
    return NO;
  }
  BOOL epoch_matches = current_host_epoch == expected_host_epoch;
  startup_snapshot_bool(@"host_epoch_matches_expected", YES, epoch_matches);
  if (!epoch_matches) {
    startup_snapshot_bool(@"host_running", YES, NO);
    return NO;
  }
  BOOL stopped = gHostStopped;
  startup_snapshot_bool(@"host_stopped", YES, stopped);
  startup_snapshot_bool(@"host_running", YES, !stopped);
  return !stopped;
}

static BOOL startup_event_belongs_to_arm(ContrastArm arm, int event_kind,
                                         int64_t event_token,
                                         BOOL event_facts_available) {
  if (event_kind == 0) {
    startup_snapshot_bool(@"owned_window_event", event_facts_available, YES);
    return YES;
  }
  if (arm != ContrastArmGPView) {
    startup_snapshot_bool(@"owned_window_event", event_facts_available, NO);
    return NO;
  }
  if (!gOwner) {
    startup_snapshot_bool(@"owned_window_event", event_facts_available, NO);
    return NO;
  }
  BOOL token_owned = event_token == gOwner.token;
  startup_snapshot_bool(@"event_token_owned", event_facts_available, token_owned);
  startup_snapshot_bool(@"owned_window_event", event_facts_available, token_owned);
  return token_owned;
}

static BOOL startup_no_unexpected_input(void) {
  BOOL unexpected = gStartupUnexpectedInput;
  startup_snapshot_bool(@"unexpected_input", YES, unexpected);
  return !unexpected;
}

static ContrastStartupClosedReason startup_closed_reason(
    ContrastStartupSnapshotStage stage, GPUIContrastStartupDecision decision,
    BOOL owned, BOOL host_running, int pump_status, BOOL event_allowed,
    BOOL unexpected_input, BOOL unexpected_was_evaluated, unsigned int iterations) {
  if (decision == GPUIContrastStartupReady) return ContrastStartupClosedReady;
  if (!owned) return ContrastStartupClosedOwnedPrecheck;
  if (!host_running) return ContrastStartupClosedHost;
  if (stage == ContrastStartupSnapshotAfterPump && pump_status != 0)
    return ContrastStartupClosedPump;
  if (unexpected_was_evaluated && unexpected_input)
    return ContrastStartupClosedUnexpectedInput;
  if (stage == ContrastStartupSnapshotAfterPump && !event_allowed)
    return ContrastStartupClosedUnexpectedEvent;
  if (iterations >= GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT)
    return ContrastStartupClosedIterationLimit;
  return ContrastStartupClosedOther;
}

static BOOL wait_for_startup_readiness(ContrastArm arm, NSView *view) {
  if (arm != ContrastArmGPView && arm != ContrastArmNSTextView) return NO;
  unsigned int *iterations = &gStartupIterations[arm];
  *iterations = 0;
  gStartupReady[arm] = NO;
  if (gContrastHostEpoch == 0 && state == 1 && host_epoch > 0)
    gContrastHostEpoch = host_epoch;
  int64_t expected_host_epoch = gContrastHostEpoch;
  gStartupUnexpectedInput = NO;
  gStartupFirstSnapshot[arm] = nil;
  gStartupTerminalSnapshot[arm] = nil;
  BOOL ready = NO;
  gStartupWaiting = YES;
  @try {
    for (;;) {
      startup_snapshot_reset(arm, ContrastStartupSnapshotBeforePump, *iterations,
                             expected_host_epoch);
      BOOL owned = startup_identity_valid(arm, view, expected_host_epoch);
      startup_snapshot_bool(@"owned_precheck_valid", YES, owned);
      BOOL host_running = startup_host_running(expected_host_epoch);
      BOOL focus = owned && app_owns_client(view);
      startup_snapshot_bool(@"focus_predicate", YES, focus);
      BOOL context = owned && context_matches_client((id<NSTextInputClient>)view);
      startup_snapshot_bool(@"context_predicate", YES, context);
      BOOL unexpected_input = gStartupUnexpectedInput;
      startup_snapshot_bool(@"unexpected_input", YES, unexpected_input);
      GPUIContrastStartupDecision decision = gpui_contrast_startup_step(
        (GPUIContrastDeliveryArm)arm, owned, host_running, YES,
        !unexpected_input, focus, context, *iterations,
        GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
      startup_snapshot_number(@"decision", YES, decision);
      if (!gStartupFirstSnapshot[arm])
        gStartupFirstSnapshot[arm] = [gStartupCurrentSnapshot copy];
      if (decision == GPUIContrastStartupReady) {
        ready = YES;
        startup_snapshot_number(@"closed_reason", YES, ContrastStartupClosedReady);
        gStartupTerminalSnapshot[arm] = [gStartupCurrentSnapshot copy];
        break;
      }
      if (decision != GPUIContrastStartupWait) {
        startup_snapshot_number(@"closed_reason", YES,
          startup_closed_reason(ContrastStartupSnapshotBeforePump, decision,
            owned, host_running, 0, YES, unexpected_input, YES, *iterations));
        gStartupTerminalSnapshot[arm] = [gStartupCurrentSnapshot copy];
        break;
      }

      if (*iterations >= GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) {
        startup_snapshot_number(@"closed_reason", YES, ContrastStartupClosedIterationLimit);
        gStartupTerminalSnapshot[arm] = [gStartupCurrentSnapshot copy];
        break;
      }
      (*iterations)++;
      int status = gApi->call(23, 0, kPumpMilliseconds, 0, NULL, 0);
      int event_kind = status == 0 ? (int)gApi->integer(1) : -1;
      int64_t event_token = status == 0 && event_kind != 0 ? gApi->integer(2) : 0;
      startup_snapshot_reset(arm, ContrastStartupSnapshotAfterPump, *iterations,
                             expected_host_epoch);
      startup_snapshot_number(@"pump_status", YES, status);
      startup_snapshot_number(@"event_kind", status == 0, event_kind);
      BOOL owned_window_event = startup_event_belongs_to_arm(
        arm, event_kind, event_token, status == 0);
      BOOL event_allowed = status == 0 && startup_no_unexpected_input() &&
        gpui_contrast_startup_event_allowed((GPUIContrastDeliveryArm)arm,
          event_kind, owned_window_event);
      startup_snapshot_bool(@"event_allowed", YES, event_allowed);
      owned = startup_identity_valid(arm, view, expected_host_epoch);
      startup_snapshot_bool(@"owned_precheck_valid", YES, owned);
      host_running = startup_host_running(expected_host_epoch);
      focus = owned && app_owns_client(view);
      startup_snapshot_bool(@"focus_predicate", YES, focus);
      context = owned && context_matches_client((id<NSTextInputClient>)view);
      startup_snapshot_bool(@"context_predicate", YES, context);
      BOOL pump_ok = status == 0 && startup_no_unexpected_input();
      BOOL post_unexpected_input = status == 0 && !pump_ok;
      BOOL post_unexpected_evaluated = status == 0;
      if (!post_unexpected_evaluated)
        startup_snapshot_bool(@"unexpected_input", NO, NO);
      decision = gpui_contrast_startup_step((GPUIContrastDeliveryArm)arm,
        owned, host_running, pump_ok, event_allowed,
        focus, context, *iterations, GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
      startup_snapshot_number(@"decision", YES, decision);
      if (decision == GPUIContrastStartupReady) {
        ready = YES;
        startup_snapshot_number(@"closed_reason", YES, ContrastStartupClosedReady);
        gStartupTerminalSnapshot[arm] = [gStartupCurrentSnapshot copy];
        break;
      }
      if (decision != GPUIContrastStartupWait) {
        startup_snapshot_number(@"closed_reason", YES,
          startup_closed_reason(ContrastStartupSnapshotAfterPump, decision,
            owned, host_running, status, event_allowed, post_unexpected_input,
            post_unexpected_evaluated, *iterations));
        gStartupTerminalSnapshot[arm] = [gStartupCurrentSnapshot copy];
        break;
      }
    }
  } @finally {
    gStartupCurrentSnapshot = nil;
    gStartupWaiting = NO;
  }
  gStartupReady[arm] = ready;
  if (ready && arm == ContrastArmGPView) gCommonScale = gOwner.scale;
  return ready && gpui_contrast_startup_allows_input(
    ready ? GPUIContrastStartupReady : GPUIContrastStartupStop);
}

static NSDictionary *geometry_summary(ContrastArm arm) {
  NSView *view = nil;
  double scale = 0, font_size = 0, origin_x = 0, origin_y = 0, padding = 0;
  if (arm == ContrastArmGPView && gOwner && gOwner.window) {
    view = gOwner.window.contentView;
    scale = gOwner.scale;
    font_size = 18.0;
    origin_x = 14.0;
    origin_y = 14.0;
  } else if (arm == ContrastArmNSTextView && gOwnedWindow &&
      [gOwnedWindow.contentView isKindOfClass:ContrastTextView.class]) {
    ContrastTextView *text_view = (ContrastTextView *)gOwnedWindow.contentView;
    view = text_view;
    scale = gOwnedWindow.backingScaleFactor;
    font_size = text_view.font.pointSize;
    origin_x = text_view.textContainerInset.width;
    origin_y = text_view.textContainerInset.height;
    padding = text_view.textContainer.lineFragmentPadding;
  }
  if (!view) return @{};
  NSSize size = view.bounds.size;
  return @{
    @"width": @((long long)llround(size.width)),
    @"height": @((long long)llround(size.height)),
    @"scale_milli": @((long long)llround(scale * 1000.0)),
    @"font_points_milli": @((long long)llround(font_size * 1000.0)),
    @"text_origin_x_milli": @((long long)llround(origin_x * 1000.0)),
    @"text_origin_y_milli": @((long long)llround(origin_y * 1000.0)),
    @"line_fragment_padding_milli": @((long long)llround(padding * 1000.0)),
  };
}

static BOOL source_select_and_save(NSTextInputContext *context) {
  if (!context) return NO;
  gStandardSourceSelectionAttempted = YES;
  gStandardSourceWasNil = context.selectedKeyboardInputSource == nil;
  gStandardOriginalSource = [context.selectedKeyboardInputSource copy];
  gStandardSourceSaved = YES;
  if (![context.keyboardInputSources containsObject:kKotoeriSource]) return NO;
  context.selectedKeyboardInputSource = kKotoeriSource;
  BOOL selected = [context.selectedKeyboardInputSource isEqualToString:kKotoeriSource];
  gStandardRestoreNeeded = !gStandardSourceWasNil &&
    [gStandardOriginalSource isEqualToString:kKotoeriSource] ? NO : selected;
  return selected;
}

static BOOL source_restore_and_verify(NSTextInputContext *context) {
  if (!gStandardSourceSaved) {
    gStandardRestoreStatus = ContrastSourceRestoreNotSaved;
    gStandardRestoreVerified = NO;
    return NO;
  }
  if (!context) {
    gStandardRestoreStatus = ContrastSourceRestoreFailed;
    gStandardRestoreVerified = NO;
    return NO;
  }
  BOOL already_original = gStandardSourceWasNil ? context.selectedKeyboardInputSource == nil :
    [context.selectedKeyboardInputSource isEqualToString:gStandardOriginalSource];
  if (!already_original) {
    if (gStandardSourceWasNil) context.selectedKeyboardInputSource = nil;
    else context.selectedKeyboardInputSource = gStandardOriginalSource;
  }
  BOOL restored = gStandardSourceWasNil ? context.selectedKeyboardInputSource == nil :
    [context.selectedKeyboardInputSource isEqualToString:gStandardOriginalSource];
  gStandardRestoreVerified = restored;
  gStandardRestoreStatus = restored ? (already_original ? ContrastSourceRestoreNoChangeNeeded :
    ContrastSourceRestorePerformed) : ContrastSourceRestoreFailed;
  if (restored) {
    gStandardSourceSaved = NO;
  }
  return restored;
}

static NSDictionary *current_json(void) {
  NSData *data = current[@"text"];
  if (![data isKindOfClass:NSData.class] || !data.length) return nil;
  id value = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:nil];
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSMutableDictionary *gpview_receipt_for_dispatch(int64_t dispatch_id) {
  for (NSMutableDictionary *receipt in gOwner.testingReceipts) {
    if ([receipt[@"dispatch_id"] longLongValue] == dispatch_id) return receipt;
  }
  return nil;
}

static GPUIContrastDeliveryEvidence pending_delivery_evidence(ContrastArm arm,
                                                               int64_t dispatch_id) {
  BOOL monitor_down = gPendingKey.monitor_down && gPendingKey.monitor_down_valid;
  BOOL monitor_up = gPendingKey.monitor_up && gPendingKey.monitor_up_valid;
  if (arm == ContrastArmGPView) {
    NSMutableDictionary *receipt = gpview_receipt_for_dispatch(dispatch_id);
    BOOL receipt_valid = receipt && gOwner &&
      [receipt[@"dispatch_id"] longLongValue] == dispatch_id &&
      [receipt[@"key_code"] intValue] == gPendingKey.key_code &&
      [receipt[@"host_epoch"] longLongValue] == host_epoch &&
      [receipt[@"session_epoch"] intValue] == gOwner.sessionEpoch &&
      [receipt[@"down_posted"] boolValue] && [receipt[@"up_posted"] boolValue];
    return gpui_contrast_delivery_evidence(GPUIContrastDeliveryGPView,
      monitor_down, monitor_up, NO, NO, receipt_valid,
      receipt_valid && [receipt[@"down_dispatched"] boolValue],
      receipt_valid && [receipt[@"up_dispatched"] boolValue]);
  }
  if (arm == ContrastArmNSTextView) {
    return gpui_contrast_delivery_evidence(GPUIContrastDeliveryNSTextView,
      monitor_down, monitor_up,
      gPendingKey.view_down && gPendingKey.view_down_valid,
      gPendingKey.view_up && gPendingKey.view_up_valid, NO, NO, NO);
  }
  return gpui_contrast_delivery_evidence(0, monitor_down, monitor_up,
    NO, NO, NO, NO, NO);
}

typedef enum {
  ContrastLoopPrefix = 0,
  ContrastLoopReturn = 1,
} ContrastLoopPhase;

static BOOL accept_gpview_batch(void);

static unsigned int *loop_counter(ContrastArm arm, ContrastLoopPhase phase) {
  return phase == ContrastLoopPrefix ? &gPrefixIterations[arm] : &gReturnIterations[arm];
}

static unsigned int loop_limit(ContrastLoopPhase phase) {
  return phase == ContrastLoopPrefix ? kPrefixIterationLimit : kReturnIterationLimit;
}

static BOOL arm_environment_valid(ContrastArm arm, ContrastTextView *standard_view) {
  if (arm == ContrastArmGPView) {
    NSView *view = gOwner.window.contentView;
    return gOwner && gOwner.window == gOwnedWindow && windows[@(gOwner.token)] == gOwner &&
      gOwner.sessionActive && !gOwner.closing && [view isKindOfClass:GPView.class] &&
      ((GPView *)view).owner == gOwner && app_owns_client(view) &&
      context_matches_client((id<NSTextInputClient>)view) &&
      [((GPView *)view).inputContext.selectedKeyboardInputSource isEqualToString:kKotoeriSource] &&
      NSEqualSizes(view.bounds.size, NSMakeSize(640, 240)) && isfinite(gOwner.scale) &&
      fabs(gOwner.scale - gCommonScale) < 0.001;
  }
  if (arm == ContrastArmNSTextView) {
    return standard_view && gOwnedWindow && gOwnedWindow.contentView == standard_view &&
      app_owns_client(standard_view) &&
      context_matches_client((id<NSTextInputClient>)standard_view) &&
      gStandardSourceSaved &&
      [standard_view.inputContext.selectedKeyboardInputSource isEqualToString:kKotoeriSource] &&
      NSEqualSizes(standard_view.bounds.size, NSMakeSize(640, 240)) &&
      fabs(standard_view.font.pointSize - 18.0) < 0.001 &&
      NSEqualSizes(standard_view.textContainerInset, NSMakeSize(14, 14)) &&
      fabs(standard_view.textContainer.lineFragmentPadding) < 0.001 &&
      fabs(gOwnedWindow.backingScaleFactor - gCommonScale) < 0.001;
  }
  return NO;
}

static BOOL gpview_tick(ContrastLoopPhase phase) {
  unsigned int *iterations = loop_counter(ContrastArmGPView, phase);
  if (*iterations >= loop_limit(phase) ||
      !arm_environment_valid(ContrastArmGPView, nil)) return NO;
  (*iterations)++;
  gCaptureNaturalQueries = phase == ContrastLoopReturn;
  int status = gApi->call(23, 0, kPumpMilliseconds, 0, NULL, 0);
  gCaptureNaturalQueries = NO;
  if (status != 0) return NO;
  if ((int)gApi->integer(1) == 18 && !accept_gpview_batch()) return NO;
  return arm_environment_valid(ContrastArmGPView, nil);
}

static BOOL standard_tick(ContrastLoopPhase phase, ContrastTextView *view) {
  unsigned int *iterations = loop_counter(ContrastArmNSTextView, phase);
  if (*iterations >= loop_limit(phase) ||
      !arm_environment_valid(ContrastArmNSTextView, view)) return NO;
  (*iterations)++;
  gCaptureNaturalQueries = phase == ContrastLoopReturn;
  int status = pump_native_event(kPumpMilliseconds);
  gCaptureNaturalQueries = NO;
  return status == 0 && arm_environment_valid(ContrastArmNSTextView, view);
}

static BOOL dispatch_pair_complete(ContrastArm arm, int64_t dispatch_id) {
  GPUIContrastDeliveryEvidence evidence = pending_delivery_evidence(arm, dispatch_id);
  return gpui_contrast_pair_complete(
    gPendingKey.dispatch_id == dispatch_id, evidence.down, evidence.up);
}

static BOOL post_key(ContrastArm arm, int key_index, int64_t dispatch_id) {
  int key_code = gpui_contrast_key_code((size_t)key_index);
  NSString *characters = contrast_characters(gpui_contrast_character((size_t)key_index));
  if (key_code < 0 || !characters || gPendingKey.active || dispatch_id <= 0) return NO;
  gPendingKey = (ContrastPendingKey){
    .active = YES, .dispatch_id = dispatch_id, .key_index = key_index,
    .key_code = key_code, .characters = characters, .ignoring = characters,
  };
  if (arm == ContrastArmGPView) {
    if (!gOwner || gOwner.testingDispatchId + 1 != dispatch_id) {
      gPendingKey.active = NO;
      return NO;
    }
    NSDictionary *input = @{@"characters": characters, @"ignoring": characters};
    NSData *json = [NSJSONSerialization dataWithJSONObject:input options:0 error:nil];
    if (!json || gApi->call(24, gOwner.token, key_code, 0, json.bytes,
        (int32_t)json.length) != 0 || gOwner.testingDispatchId != dispatch_id) {
      gPendingKey.active = NO;
      return NO;
    }
  } else {
    int status = 0;
    NSArray<NSEvent *> *pair = create_app_local_key_events((unsigned short)key_code, 0,
      dispatch_id, characters, characters, &status);
    if (status || pair.count != 2) {
      gPendingKey.active = NO;
      return NO;
    }
    [NSApp postEvent:pair[0] atStart:NO];
    [NSApp postEvent:pair[1] atStart:NO];
  }
  return YES;
}

static unsigned int arm_pending_event_count(ContrastArm arm) {
  if (arm == ContrastArmGPView) {
    return (unsigned int)events.count + (gOwner.sessionAwaitingAck ? 1u : 0u) +
      (gOwner.textDispatchActive ? 1u : 0u) + (gOwner.deferredTextError ? 1u : 0u);
  }
  return 0;
}

static unsigned int arm_effect_counter(ContrastArm arm) {
  ContrastObservation *observation = gObservations[arm];
  return observation.insertCount + observation.markCount + observation.unmarkCount +
    observation.commandCount + gCallbackPreedit[arm] + gCallbackCommit[arm] +
    gCallbackUnmark[arm] + gCallbackForwarded[arm];
}

static BOOL run_one_prefix_key(ContrastArm arm, int key_index, int64_t dispatch_id,
                               ContrastTextView *standard_view) {
  if (!arm_environment_valid(arm, standard_view) ||
      !post_key(arm, key_index, dispatch_id)) return NO;
  unsigned int quiet = 0;
  while (*loop_counter(arm, ContrastLoopPrefix) < kPrefixIterationLimit) {
    BOOL step_ok = arm == ContrastArmGPView ? gpview_tick(ContrastLoopPrefix) :
      standard_tick(ContrastLoopPrefix, standard_view);
    if (!step_ok) break;
    BOOL pair = dispatch_pair_complete(arm, dispatch_id);
    BOOL pending = arm_pending_event_count(arm) != 0;
    if (pair && !pending) {
      if (quiet < 2) quiet++;
      if (quiet >= 2) break;
    } else {
      quiet = 0;
    }
  }
  BOOL pair = dispatch_pair_complete(arm, dispatch_id);
  BOOL ready = pair && arm_pending_event_count(arm) == 0 &&
    arm_environment_valid(arm, standard_view);
  if (arm == ContrastArmNSTextView && standard_view)
    ready = ready && gPendingKey.view_down_valid && gPendingKey.view_up_valid;
  GPUIContrastDeliveryEvidence delivery = pending_delivery_evidence(arm, dispatch_id);
  NSView *view = arm == ContrastArmGPView ? (NSView *)gOwner.window.contentView :
    (NSView *)standard_view;
  id<NSTextInputClient> client = (id<NSTextInputClient>)view;
  BOOL context_ok = context_matches_client(client);
  BOOL source_ok = arm == ContrastArmGPView ?
    [((GPView *)view).inputContext.selectedKeyboardInputSource isEqualToString:kKotoeriSource] :
    gStandardSourceSaved && [((NSView *)view).inputContext.selectedKeyboardInputSource
      isEqualToString:kKotoeriSource];
  NSString *text = arm == ContrastArmGPView ? gOwner.visibleText : standard_view.string;
  NSRange selection = arm == ContrastArmGPView ? gOwner.selectionRange : standard_view.selectedRange;
  NSRange marked = arm == ContrastArmGPView ? gOwner.markedRange : standard_view.markedRange;
  emit_record(ContrastPhaseDispatch, arm, ready ? ContrastOutcomePassed : ContrastOutcomeFailed,
    (int)arm, key_index, gPendingKey.key_code,
    gPrefixIterations[arm], [text isEqualToString:kExpectedComposition],
    arm == ContrastArmGPView ? gOwner.hasMarkedText : [standard_view hasMarkedText],
    app_owns_client(view), context_ok, source_ok,
    delivery.down, delivery.up,
    text.length, selection, marked, gCallbackPreedit[arm], gCallbackCommit[arm],
    gCallbackUnmark[arm], NO, NO);
  gPendingKey.active = NO;
  return ready;
}

static void set_standard_baseline(ContrastTextView *view) {
  view.frame = NSMakeRect(0, 0, 640, 240);
  [view setString:@"Hello "];
  [view setSelectedRange:NSMakeRange(6, 0)];
  view.font = [NSFont systemFontOfSize:18.0];
  view.textColor = NSColor.whiteColor;
  view.backgroundColor = [NSColor colorWithSRGBRed:0.035 green:0.05 blue:0.075 alpha:1.0];
  view.drawsBackground = YES;
  view.editable = YES;
  view.selectable = YES;
  view.richText = NO;
  view.fieldEditor = NO;
  view.textContainerInset = NSMakeSize(14, 14);
  view.textContainer.lineFragmentPadding = 0;
  view.textContainer.containerSize = NSMakeSize(612, CGFLOAT_MAX);
  view.textContainer.widthTracksTextView = YES;
}

static GPUIContrastPreconditions contrast_preconditions(NSView *view,
                                                        id<NSTextInputClient> client,
                                                        BOOL source_ok, BOOL baseline_ok,
                                                        BOOL geometry_ok) {
  return (GPUIContrastPreconditions){
    .focus_owned = app_owns_client(view),
    .context_matches_client = context_matches_client(client),
    .source_selected = source_ok,
    .baseline_matches = baseline_ok,
    .geometry_matches = geometry_ok,
    .producer_available = YES,
  };
}

static NSDictionary *gpview_frame_identity(void) {
  if (gApi->call(26, gOwner.token, 0, 0, NULL, 0) != 0) return nil;
  NSDictionary *identity = current_json();
  if (![identity isKindOfClass:NSDictionary.class] ||
      [identity[@"window_id"] longLongValue] != gOwner.token ||
      [identity[@"host_epoch"] longLongValue] != host_epoch ||
      [identity[@"session_epoch"] intValue] != gOwner.sessionEpoch) return nil;
  return identity;
}

static BOOL accept_gpview_batch(void) {
  NSDictionary *batch = current_json();
  if (!batch || ![batch[@"events"] isKindOfClass:NSArray.class] ||
      [batch[@"window"] longLongValue] != gOwner.token ||
      [batch[@"host_epoch"] longLongValue] != host_epoch ||
      [batch[@"epoch"] intValue] != gOwner.sessionEpoch) return NO;
  int64_t sequence = [batch[@"sequence"] longLongValue];
  if (sequence <= 0 || !gOwner.sessionActive || !gOwner.sessionAwaitingAck ||
      !gOwner.batchDelivered || sequence != gOwner.awaitingSequence ||
      sequence <= gOwner.lastPresentedBatchSequence) return NO;
  NSArray *callbacks = batch[@"events"];
  if (callbacks.count == 0 || callbacks.count > 64) return NO;
  unsigned int preedit = 0, commit = 0, cancelled = 0, forwarded = 0;
  for (id value in callbacks) {
    if (![value isKindOfClass:NSDictionary.class]) return NO;
    NSString *kind = value[@"kind"];
    if ([kind isEqualToString:@"preedit"]) preedit++;
    else if ([kind isEqualToString:@"commit"]) commit++;
    else if ([kind isEqualToString:@"cancelled"]) cancelled++;
    else if ([kind isEqualToString:@"forwarded_pressed"] ||
             [kind isEqualToString:@"forwarded_released"]) forwarded++;
    else return NO;
  }

  NSUInteger cursor = gOwner.hasMarkedText ? gOwner.sessionBaseSelection.location :
    gOwner.selectionRange.location;
  int64_t revision = gOwner.ownerRevision + 1;
  NSString *scene = scene_payload(gOwner.visibleText);
  NSString *payload = session_payload(gOwner.baseText ?: @"", cursor,
    gOwner.visibleText ?: gOwner.baseText ?: @"", gOwner.caretHead,
    revision, sequence);
  if (!scene || !payload || call_text(9, gOwner.token, 0, scene) != 0 ||
      call_text(20, gOwner.token, (double)gOwner.sessionEpoch, payload) != 0) return NO;
  if (gOwner.sessionAwaitingAck || gOwner.batchDelivered ||
      gOwner.lastPresentedBatchSequence != sequence || gOwner.ownerRevision != revision ||
      gOwner.lastPresentedOwnerRevision != revision) return NO;
  NSDictionary *identity = gpview_frame_identity();
  if (!identity || [identity[@"batch_sequence"] longLongValue] != sequence ||
      [identity[@"accepted_revision"] longLongValue] != revision ||
      [identity[@"text"] isEqualToString:gOwner.visibleText] == NO) return NO;
  int64_t frame_revision = [identity[@"frame_revision"] longLongValue];
  if (frame_revision <= 0) return NO;
  gLastGPViewAckFrame = (unsigned int)frame_revision;
  gCallbackPreedit[ContrastArmGPView] += preedit;
  gCallbackCommit[ContrastArmGPView] += commit;
  gCallbackUnmark[ContrastArmGPView] += cancelled;
  gCallbackForwarded[ContrastArmGPView] += forwarded;
  return YES;
}

static BOOL gpview_pending(void) {
  return gOwner && (gOwner.sessionAwaitingAck || gOwner.textDispatchActive ||
    gOwner.deferredTextError != 0 || events.count != 0);
}

static ContrastCompletion gpview_return_completion(void) {
  ContrastObservation *observation = gObservations[ContrastArmGPView];
  unsigned int insert_delta = observation.insertCount - gGPViewInsertBaseline;
  unsigned int mark_delta = observation.markCount - gGPViewMarkBaseline;
  unsigned int unmark_delta = observation.unmarkCount - gGPViewUnmarkBaseline;
  unsigned int commit_delta = gCallbackCommit[ContrastArmGPView] - gGPViewBatchCommitBaseline;
  if ([gOwner.baseText isEqualToString:kExpectedComposition] &&
      [gOwner.visibleText isEqualToString:kExpectedComposition] && !gOwner.hasMarkedText &&
      gOwner.markedRange.location == NSNotFound && insert_delta == 1 &&
      observation.lastInsertWasExpected && commit_delta == 1 && mark_delta == 0 &&
      unmark_delta <= 1 && gOwner.sessionForwardedKeyUps.count == 0 && !gpview_pending() &&
      gOwner.lastPresentedBatchSequence > gGPViewBaselineBatch &&
      gOwner.lastPresentedOwnerRevision > gGPViewOwnerRevisionBaseline &&
      gLastGPViewAckFrame > gGPViewBaselineFrame)
    return ContrastCompletionAcceptedBatchCommit;
  if (insert_delta > 1 || commit_delta > 1 || mark_delta > 1 || unmark_delta > 1 ||
      (insert_delta == 1 && !observation.lastInsertWasExpected) ||
      (commit_delta == 1 && insert_delta != 1)) return ContrastCompletionMismatch;
  if ([gOwner.baseText isEqualToString:kExpectedComposition] && !gOwner.hasMarkedText &&
      insert_delta == 0 && commit_delta == 0 && unmark_delta == 0)
    return ContrastCompletionStateChangeWithoutCallback;
  return ContrastCompletionNone;
}

static ContrastCompletion standard_return_completion(ContrastTextView *view) {
  ContrastObservation *observation = view.observation;
  unsigned int insert_delta = observation.insertCount - gStandardInsertBaseline;
  unsigned int mark_delta = observation.markCount - gStandardMarkBaseline;
  unsigned int unmark_delta = observation.unmarkCount - gStandardUnmarkBaseline;
  BOOL final_document = [view.string isEqualToString:kExpectedComposition] &&
    ![view hasMarkedText] && [view markedRange].location == NSNotFound;
  if (final_document && insert_delta == 1 && observation.lastInsertWasExpected &&
      unmark_delta <= 1 && mark_delta <= 1)
    return ContrastCompletionInsertText;
  if (final_document && insert_delta == 0 && unmark_delta == 1 && mark_delta <= 1)
    return ContrastCompletionUnmarkText;
  if (final_document && insert_delta == 0 && unmark_delta == 0 && mark_delta == 0)
    return ContrastCompletionStateChangeWithoutCallback;
  if (insert_delta > 1 || mark_delta > 1 || unmark_delta > 1 ||
      (insert_delta == 1 && !observation.lastInsertWasExpected))
    return ContrastCompletionMismatch;
  return ContrastCompletionNone;
}

static BOOL run_return_key(ContrastArm arm, int64_t dispatch_id,
                           ContrastTextView *standard_view, BOOL *observed_out) {
  int key_index = GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT - 1;
  if (observed_out) *observed_out = NO;
  if (!arm_environment_valid(arm, standard_view) ||
      !post_key(arm, key_index, dispatch_id)) {
    gCompletionKind[arm] = ContrastCompletionMismatch;
    return NO;
  }
  BOOL stable = NO;
  BOOL pump_failed = NO;
  unsigned int quiet_after_effect = 0;
  while (*loop_counter(arm, ContrastLoopReturn) < kReturnIterationLimit) {
    unsigned int before_effects = arm_effect_counter(arm);
    int64_t before_batch_sequence = arm == ContrastArmGPView ? gOwner.lastBatchSequence : 0;
    BOOL step_ok = arm == ContrastArmGPView ? gpview_tick(ContrastLoopReturn) :
      standard_tick(ContrastLoopReturn, standard_view);
    if (!step_ok) { pump_failed = YES; break; }
    BOOL pair = dispatch_pair_complete(arm, dispatch_id);
    BOOL pending = arm_pending_event_count(arm) != 0;
    ContrastCompletion completion = arm == ContrastArmGPView ?
      gpview_return_completion() : standard_return_completion(standard_view);
    BOOL exact_effect = completion == ContrastCompletionAcceptedBatchCommit ||
      completion == ContrastCompletionInsertText || completion == ContrastCompletionUnmarkText;
    BOOL activity = arm_effect_counter(arm) != before_effects ||
      (arm == ContrastArmGPView && gOwner.lastBatchSequence != before_batch_sequence);
    if (pair && !pending && exact_effect) {
      if (activity) quiet_after_effect = 0;
      else if (quiet_after_effect < 2) quiet_after_effect++;
      if (quiet_after_effect >= 2) {
        stable = YES;
        gCompletionKind[arm] = completion;
        break;
      }
    } else {
      quiet_after_effect = 0;
      if (completion == ContrastCompletionMismatch) {
        gCompletionKind[arm] = completion;
        break;
      }
    }
  }
  BOOL pair = dispatch_pair_complete(arm, dispatch_id);
  BOOL owned = arm_environment_valid(arm, standard_view);
  BOOL queue_quiescent = arm_pending_event_count(arm) == 0;
  BOOL ready_to_observe = gpui_contrast_return_observed(
    pair, owned, queue_quiescent, !pump_failed);
  if (observed_out) *observed_out = ready_to_observe;
  ContrastCompletion final_completion = arm == ContrastArmGPView ?
    gpview_return_completion() : standard_return_completion(standard_view);
  if (!stable) {
    if (final_completion == ContrastCompletionStateChangeWithoutCallback)
      gCompletionKind[arm] = final_completion;
    else if (final_completion == ContrastCompletionMismatch)
      gCompletionKind[arm] = final_completion;
    else if (gReturnIterations[arm] >= kReturnIterationLimit)
      gCompletionKind[arm] = ContrastCompletionTimeout;
    else if (gCompletionKind[arm] == ContrastCompletionNone)
      gCompletionKind[arm] = ContrastCompletionTimeout;
  }
  BOOL focus = arm == ContrastArmGPView ? app_owns_client((NSView *)gOwner.window.contentView) :
    app_owns_client(standard_view);
  BOOL context = arm == ContrastArmGPView ?
    context_matches_client((id<NSTextInputClient>)gOwner.window.contentView) :
    context_matches_client((id<NSTextInputClient>)standard_view);
  BOOL source = arm == ContrastArmGPView ?
    [((GPView *)gOwner.window.contentView).inputContext.selectedKeyboardInputSource
      isEqualToString:kKotoeriSource] :
    [standard_view.inputContext.selectedKeyboardInputSource isEqualToString:kKotoeriSource];
  BOOL expected = arm == ContrastArmGPView ?
    [gOwner.baseText isEqualToString:kExpectedComposition] :
    [standard_view.string isEqualToString:kExpectedComposition];
  BOOL marked = arm == ContrastArmGPView ? gOwner.hasMarkedText : [standard_view hasMarkedText];
  NSRange selection = arm == ContrastArmGPView ? gOwner.selectionRange : standard_view.selectedRange;
  NSRange marked_range = arm == ContrastArmGPView ? gOwner.markedRange : standard_view.markedRange;
  unsigned int commits = gCallbackCommit[arm];
  unsigned int cancellations = gCallbackUnmark[arm];
  BOOL passed = stable && ready_to_observe && focus && context && source && expected && !marked;
  if (arm == ContrastArmGPView)
    passed = passed && final_completion == ContrastCompletionAcceptedBatchCommit;
  else
    passed = passed && (final_completion == ContrastCompletionInsertText ||
      final_completion == ContrastCompletionUnmarkText);
  GPUIContrastReturnFacts return_facts = gpui_contrast_return_facts(
    ready_to_observe, passed);
  passed = return_facts.passed;
  gReturnInsertDelta[arm] = gObservations[arm].insertCount -
    (arm == ContrastArmGPView ? gGPViewInsertBaseline : gStandardInsertBaseline);
  gReturnMarkDelta[arm] = gObservations[arm].markCount -
    (arm == ContrastArmGPView ? gGPViewMarkBaseline : gStandardMarkBaseline);
  gReturnUnmarkDelta[arm] = gObservations[arm].unmarkCount -
    (arm == ContrastArmGPView ? gGPViewUnmarkBaseline : gStandardUnmarkBaseline);
  gReturnCommandDelta[arm] = gObservations[arm].commandCount -
    (arm == ContrastArmGPView ? gGPViewCommandBaseline : gStandardCommandBaseline);
  gReturnBatchPreeditDelta[arm] = gCallbackPreedit[arm] -
    (arm == ContrastArmGPView ? gGPViewBatchPreeditBaseline : 0);
  gReturnBatchCommitDelta[arm] = gCallbackCommit[arm] -
    (arm == ContrastArmGPView ? gGPViewBatchCommitBaseline : gStandardBatchCommitBaseline);
  gReturnBatchUnmarkDelta[arm] = gCallbackUnmark[arm] -
    (arm == ContrastArmGPView ? gGPViewBatchUnmarkBaseline : 0);
  gReturnBatchForwardedDelta[arm] = gCallbackForwarded[arm] -
    (arm == ContrastArmGPView ? gGPViewBatchForwardedBaseline : 0);
  gCompletionKind[arm] = passed ? final_completion : gCompletionKind[arm];
  if (!passed && gCompletionKind[arm] == ContrastCompletionNone)
    gCompletionKind[arm] = final_completion == ContrastCompletionStateChangeWithoutCallback ?
      ContrastCompletionStateChangeWithoutCallback :
      (gReturnIterations[arm] >= kReturnIterationLimit ? ContrastCompletionTimeout :
        ContrastCompletionMismatch);
  if (arm == ContrastArmGPView) {
    gGPViewObserved = return_facts.observed;
    gGPViewPassed = return_facts.passed;
  } else {
    gStandardObserved = return_facts.observed;
    gStandardPassed = return_facts.passed;
  }
  if (observed_out) *observed_out = return_facts.observed;
  GPUIContrastDeliveryEvidence delivery = pending_delivery_evidence(arm, dispatch_id);
  emit_record(ContrastPhaseReturn, arm,
    passed ? ContrastOutcomePassed :
      (gCompletionKind[arm] == ContrastCompletionStateChangeWithoutCallback ?
        ContrastOutcomeStateChangeWithoutCallback :
        (gCompletionKind[arm] == ContrastCompletionTimeout ? ContrastOutcomeTimedOut :
          ContrastOutcomeFailed)),
    (int)arm, key_index, 36, gReturnIterations[arm], expected, marked, focus, context, source,
    delivery.down, delivery.up,
    arm == ContrastArmGPView ? gOwner.visibleText.length : standard_view.string.length,
    selection, marked_range, gCallbackPreedit[arm], commits, cancellations, NO, NO);
  gPendingKey.active = NO;
  gCaptureNaturalQueries = NO;
  gCaptureEffects = NO;
  return passed;
}

static BOOL save_gpview_source_baseline(ContrastGPView *view) {
  if (!view || !view.inputContext) return NO;
  gGPViewSourceSelectionAttempted = YES;
  gGPViewOriginalSourceWasNil = view.inputContext.selectedKeyboardInputSource == nil;
  gGPViewOriginalSource = [view.inputContext.selectedKeyboardInputSource copy];
  gGPViewOriginalSourceSaved = YES;
  return YES;
}

static ContrastArmResult run_gpview_arm(void) {
  ContrastArmResult result = {.attempted = YES};
  emit_record(ContrastPhaseStart, ContrastArmGPView, ContrastOutcomeReady,
    ContrastArmGPView, -1, -1, 0, NO, NO, NO, NO, NO, NO, NO, 0,
    NSMakeRange(NSNotFound, 0), NSMakeRange(NSNotFound, 0), 0, 0, 0, NO, NO);
  NSString *title = @"GPUI NSTextView contrast fixture";
  NSData *title_data = [title dataUsingEncoding:NSUTF8StringEncoding];
  if (gApi->call(1, 0, 0, 0, NULL, 0) != 0 ||
      gApi->call(3, 0, 640, 240, title_data.bytes, (int32_t)title_data.length) != 0) return result;
  int64_t token = gApi->integer(0);
  gOwner = windows[@(token)];
  if (!gOwner || !gOwner.window) return result;
  gOwnedWindow = gOwner.window;
  gCommonScale = gOwner.scale;
  ContrastGPView *view = install_gpview_observer(gOwner);
  if (!view) return result;
  contrast_local_event_monitor();

  BOOL startup_ready = wait_for_startup_readiness(ContrastArmGPView, view);
  BOOL focus = startup_ready && app_owns_client(view);
  BOOL context = startup_ready && context_matches_client(view);
  BOOL saved_source = startup_ready && save_gpview_source_baseline(view);
  BOOL selected = startup_ready && saved_source && focus && context &&
    gApi->call(31, gOwner.token, 0, 0, NULL, 0) == 0 &&
    [view.inputContext.selectedKeyboardInputSource isEqualToString:kKotoeriSource];
  NSString *begin = session_payload(@"Hello ", 6, @"Hello ", 6, 1, 0);
  BOOL started = selected && begin && call_text(19, gOwner.token, 0, begin) == 0;
  BOOL baseline_frame = started && call_text(9, gOwner.token, 0,
    scene_payload(gOwner.visibleText ?: @"Hello ")) == 0;
  NSDictionary *initial_frame = baseline_frame ? gpview_frame_identity() : nil;
  if (initial_frame) {
    gGPViewBaselineFrame = (unsigned int)[initial_frame[@"frame_revision"] unsignedIntValue];
    gGPViewBaselineBatch = [initial_frame[@"batch_sequence"] longLongValue];
    gGPViewOwnerRevisionBaseline = gOwner.ownerRevision;
    gCommonScale = gOwner.scale;
  }
  BOOL baseline_text = gOwner && [gOwner.visibleText isEqualToString:@"Hello "] &&
    NSEqualRanges(gOwner.selectionRange, NSMakeRange(6, 0));
  BOOL geometry_ok = startup_ready && gOwner.window == gOwnedWindow &&
    NSEqualSizes(view.bounds.size, NSMakeSize(640, 240)) &&
    gOwner.scale > 0 && isfinite(gOwner.scale);
  GPUIContrastPreconditions pre = contrast_preconditions(startup_ready ? view : nil,
    startup_ready ? view : nil,
    selected, started && baseline_text, geometry_ok && initial_frame != nil);
  BOOL arm_ready = gpui_contrast_preconditions_hold(pre);
  result.preconditions_valid = arm_ready;
  gArmPreconditionsValid[ContrastArmGPView] = arm_ready;
  emit_record(ContrastPhaseBaseline, ContrastArmGPView,
    arm_ready ? ContrastOutcomeReady : ContrastOutcomeSetupFailed,
    ContrastArmGPView, -1, -1, 0, baseline_text, gOwner.hasMarkedText, focus,
    context, selected, NO, NO, gOwner.visibleText.length, gOwner.selectionRange,
    gOwner.markedRange, 0, 0, 0, NO, NO);
  if (!arm_ready) return result;

  gCaptureEffects = YES;
  BOOL prefix_ready = YES;
  for (int key_index = 0; key_index < GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT - 1; key_index++) {
    if (!run_one_prefix_key(ContrastArmGPView, key_index, key_index + 1, nil)) {
      prefix_ready = NO;
      break;
    }
    if (key_index == GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT - 2) {
      BOOL composing = gOwner.hasMarkedText &&
        [gOwner.visibleText isEqualToString:kExpectedComposition] &&
        gCallbackPreedit[ContrastArmGPView] > 0 && !gpview_pending();
      BOOL current_focus = app_owns_client(view);
      BOOL current_context = context_matches_client(view);
      BOOL current_source = [view.inputContext.selectedKeyboardInputSource
        isEqualToString:kKotoeriSource];
      BOOL geometry = gOwner.scale == gCommonScale &&
        NSEqualSizes(view.bounds.size, NSMakeSize(640, 240));
      GPUIContrastDeliveryEvidence delivery = pending_delivery_evidence(
        ContrastArmGPView, gPendingKey.dispatch_id);
      emit_record(ContrastPhaseComposition, ContrastArmGPView,
        composing && current_focus && current_context && current_source && geometry ?
          ContrastOutcomeReady : ContrastOutcomeFailed,
        ContrastArmGPView, key_index, gpui_contrast_key_code((size_t)key_index),
        gPrefixIterations[ContrastArmGPView], composing, gOwner.hasMarkedText,
        current_focus, current_context, current_source,
        delivery.down, delivery.up,
        gOwner.visibleText.length, gOwner.selectionRange, gOwner.markedRange,
        gCallbackPreedit[ContrastArmGPView], gCallbackCommit[ContrastArmGPView],
        gCallbackUnmark[ContrastArmGPView], NO, NO);
      prefix_ready = prefix_ready && composing && current_focus && current_context &&
        current_source && geometry;
    }
  }
  result.preconditions_valid = result.preconditions_valid && prefix_ready;
  gArmPreconditionsValid[ContrastArmGPView] = result.preconditions_valid;
  if (!result.preconditions_valid) return result;

  gGPViewInsertBaseline = gObservations[ContrastArmGPView].insertCount;
  gGPViewCommandBaseline = gObservations[ContrastArmGPView].commandCount;
  gGPViewMarkBaseline = gObservations[ContrastArmGPView].markCount;
  gGPViewBatchCommitBaseline = gCallbackCommit[ContrastArmGPView];
  gGPViewBatchPreeditBaseline = gCallbackPreedit[ContrastArmGPView];
  gGPViewBatchUnmarkBaseline = gCallbackUnmark[ContrastArmGPView];
  gGPViewBatchForwardedBaseline = gCallbackForwarded[ContrastArmGPView];
  gGPViewUnmarkBaseline = gObservations[ContrastArmGPView].unmarkCount;
  reset_query_observation(gObservations[ContrastArmGPView]);
  BOOL return_observed = NO;
  result.passed = run_return_key(ContrastArmGPView, 9, nil, &return_observed);
  result.observed = return_observed;
  result.cleanup_ok = NO;
  gGPViewObserved = result.observed;
  gGPViewPassed = result.passed;
  return result;
}

static ContrastArmResult run_standard_arm(void) {
  ContrastArmResult result = {.attempted = YES};
  emit_record(ContrastPhaseStart, ContrastArmNSTextView, ContrastOutcomeReady,
    ContrastArmNSTextView, -1, -1, 0, NO, NO, NO, NO, NO, NO, NO, 0,
    NSMakeRange(NSNotFound, 0), NSMakeRange(NSNotFound, 0), 0, 0, 0, NO, NO);
  if (!gOwnedWindow || !gGPViewRestoreVerified || windows.count != 0 || !gGPViewCleaned)
    return result;
  [events removeAllObjects];
  ContrastTextView *view = [[ContrastTextView alloc] initWithFrame:NSMakeRect(0, 0, 640, 240)];
  if (!view) return result;
  view.observation = gObservations[ContrastArmNSTextView];
  set_standard_baseline(view);
  gOwnedWindow.delegate = nil;
  gOwnedWindow.contentView = view;
  [gOwnedWindow makeKeyAndOrderFront:nil];
  BOOL responder = [gOwnedWindow makeFirstResponder:view];
  BOOL startup_ready = responder && wait_for_startup_readiness(ContrastArmNSTextView, view);
  NSTextInputContext *context = startup_ready ? view.inputContext : nil;
  BOOL focus = startup_ready && app_owns_client(view);
  BOOL context_ok = startup_ready && context_matches_client(view);
  BOOL source_ok = startup_ready && focus && context_ok && source_select_and_save(context) &&
    [context.selectedKeyboardInputSource isEqualToString:kKotoeriSource];
  BOOL baseline_ok = [view.string isEqualToString:@"Hello "] &&
    NSEqualRanges(view.selectedRange, NSMakeRange(6, 0));
  BOOL geometry_ok = NSEqualSizes(gOwnedWindow.contentView.bounds.size, NSMakeSize(640, 240)) &&
    fabs(view.font.pointSize - 18.0) < 0.001 &&
    NSEqualSizes(view.textContainerInset, NSMakeSize(14, 14)) &&
    fabs(view.textContainer.lineFragmentPadding) < 0.001 &&
    fabs(gOwnedWindow.backingScaleFactor - gCommonScale) < 0.001;
  GPUIContrastPreconditions pre = contrast_preconditions(startup_ready ? view : nil,
    startup_ready ? view : nil, source_ok,
    baseline_ok, geometry_ok);
  BOOL ready = gpui_contrast_preconditions_hold(pre);
  result.preconditions_valid = ready;
  gArmPreconditionsValid[ContrastArmNSTextView] = ready;
  emit_record(ContrastPhaseBaseline, ContrastArmNSTextView,
    ready ? ContrastOutcomeReady : ContrastOutcomeSetupFailed,
    ContrastArmNSTextView, -1, -1, 0, baseline_ok, [view hasMarkedText], focus,
    context_ok, source_ok, NO, NO, view.string.length, view.selectedRange,
    [view markedRange], 0, 0, 0, NO, NO);
  if (!ready) return result;

  gCaptureEffects = YES;
  BOOL prefix_ready = YES;
  int64_t dispatch_id = 10;
  for (int key_index = 0; key_index < GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT - 1;
       key_index++, dispatch_id++) {
    if (!run_one_prefix_key(ContrastArmNSTextView, key_index, dispatch_id, view)) {
      prefix_ready = NO;
      break;
    }
    if (key_index == GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT - 2) {
      BOOL composing = [view hasMarkedText] &&
        [view.string isEqualToString:kExpectedComposition] && view.observation.markCount > 0;
      BOOL current_focus = app_owns_client(view);
      BOOL current_context = context_matches_client(view);
      BOOL current_source = [context.selectedKeyboardInputSource isEqualToString:kKotoeriSource];
      NSDictionary *geometry = geometry_summary(ContrastArmNSTextView);
      BOOL same_geometry = [geometry[@"width"] intValue] == 640 &&
        [geometry[@"height"] intValue] == 240 &&
        [geometry[@"scale_milli"] intValue] == (int)llround(gCommonScale * 1000.0) &&
        [geometry[@"font_points_milli"] intValue] == 18000 &&
        [geometry[@"text_origin_x_milli"] intValue] == 14000 &&
        [geometry[@"text_origin_y_milli"] intValue] == 14000 &&
        [geometry[@"line_fragment_padding_milli"] intValue] == 0;
      GPUIContrastDeliveryEvidence delivery = pending_delivery_evidence(
        ContrastArmNSTextView, gPendingKey.dispatch_id);
      emit_record(ContrastPhaseComposition, ContrastArmNSTextView,
        composing && current_focus && current_context && current_source && same_geometry ?
          ContrastOutcomeReady : ContrastOutcomeFailed,
        ContrastArmNSTextView, key_index, gpui_contrast_key_code((size_t)key_index),
        gPrefixIterations[ContrastArmNSTextView], composing, [view hasMarkedText],
        current_focus, current_context, current_source,
        delivery.down, delivery.up,
        view.string.length, view.selectedRange, [view markedRange], view.observation.markCount,
        view.observation.insertCount, view.observation.unmarkCount, NO, NO);
      prefix_ready = prefix_ready && composing && current_focus && current_context &&
        current_source && same_geometry;
    }
  }
  result.preconditions_valid = result.preconditions_valid && prefix_ready;
  gArmPreconditionsValid[ContrastArmNSTextView] = result.preconditions_valid;
  if (!result.preconditions_valid) return result;

  gStandardInsertBaseline = view.observation.insertCount;
  gStandardCommandBaseline = view.observation.commandCount;
  gStandardMarkBaseline = view.observation.markCount;
  gStandardUnmarkBaseline = view.observation.unmarkCount;
  gStandardBatchCommitBaseline = 0;
  reset_query_observation(view.observation);
  BOOL return_observed = NO;
  result.passed = run_return_key(ContrastArmNSTextView, dispatch_id, view, &return_observed);
  result.observed = return_observed;
  result.cleanup_ok = NO;
  gStandardObserved = result.observed;
  gStandardPassed = result.passed;
  return result;
}

static BOOL finish_gpview_arm(void) {
  if (gGPViewCleaned) return gGPViewCleanupResult;
  gCaptureEffects = NO;
  gCaptureNaturalQueries = NO;
  BOOL session_closed = YES;
  if (gOwner && gOwner.window && gOwner.sessionActive) {
    int status = gApi->call(22, gOwner.token, gOwner.sessionEpoch, 0, NULL, 0);
    session_closed = status == 0 && !gOwner.sessionActive;
  }
  BOOL source_restored = YES;
  if (gOwner && gOwner.window && gOwner.testingInputSourceSaved) {
    GPView *view = (GPView *)gOwner.window.contentView;
    BOOL current_was_original = gGPViewOriginalSourceSaved &&
      (gGPViewOriginalSourceWasNil ? view.inputContext.selectedKeyboardInputSource == nil :
        [view.inputContext.selectedKeyboardInputSource isEqualToString:gGPViewOriginalSource]);
    gGPViewRestoreNeeded = gGPViewOriginalSourceSaved && !current_was_original;
    int status = gApi->call(32, gOwner.token, 0, 0, NULL, 0);
    BOOL readback = gGPViewOriginalSourceSaved &&
      (gGPViewOriginalSourceWasNil ? view.inputContext.selectedKeyboardInputSource == nil :
        [view.inputContext.selectedKeyboardInputSource isEqualToString:gGPViewOriginalSource]);
    source_restored = status == 0 && readback;
    gGPViewRestoreVerified = source_restored;
    gGPViewRestoreStatus = source_restored ? (gGPViewRestoreNeeded ?
      ContrastSourceRestorePerformed : ContrastSourceRestoreNoChangeNeeded) :
      ContrastSourceRestoreFailed;
  } else if (gGPViewOriginalSourceSaved && gOwner && gOwner.window) {
    GPView *view = (GPView *)gOwner.window.contentView;
    BOOL readback = gGPViewOriginalSourceWasNil ? view.inputContext.selectedKeyboardInputSource == nil :
      [view.inputContext.selectedKeyboardInputSource isEqualToString:gGPViewOriginalSource];
    source_restored = readback;
    gGPViewRestoreNeeded = NO;
    gGPViewRestoreVerified = readback;
    gGPViewRestoreStatus = readback ? ContrastSourceRestoreNoChangeNeeded :
      ContrastSourceRestoreFailed;
  } else if (!gGPViewSourceSelectionAttempted) {
    gGPViewRestoreNeeded = NO;
    gGPViewRestoreVerified = YES;
    gGPViewRestoreStatus = ContrastSourceRestoreNoChangeNeeded;
  } else {
    gGPViewRestoreStatus = ContrastSourceRestoreNotSaved;
    gGPViewRestoreVerified = NO;
    source_restored = NO;
  }
  BOOL detached = !gOwner || !gOwner.window;
  if (session_closed && source_restored && gOwner && gOwner.window &&
      [gOwner.window.contentView isKindOfClass:GPView.class]) {
    GPView *view = (GPView *)gOwner.window.contentView;
    view.owner = nil;
    view.layer = nil;
    gOwner.surface = nil;
    gOwner.window.delegate = nil;
    gOwner.closing = YES;
    [events removeAllObjects];
    [windows removeObjectForKey:@(gOwner.token)];
    gOwner.window.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 240)];
    detached = windows.count == 0 && gOwner.window.contentView != view;
  } else if (gOwner && gOwner.window) {
    detached = NO;
  }
  session_closed = session_closed && (!gOwner || !gOwner.sessionActive);
  gGPViewCleanupResult = session_closed && source_restored && detached;
  // Keep a failed owner registered and its GPView alive so native host
  // shutdown can make its existing final source-restore attempt safely.
  gGPViewCleaned = detached;
  return gGPViewCleanupResult;
}

static BOOL finish_standard_arm(void) {
  if (gStandardCleaned) return gStandardCleanupResult;
  gCaptureEffects = NO;
  gCaptureNaturalQueries = NO;
  BOOL restored = YES;
  ContrastTextView *view = gOwnedWindow &&
    [gOwnedWindow.contentView isKindOfClass:ContrastTextView.class] ?
      (ContrastTextView *)gOwnedWindow.contentView : nil;
  if (view) {
    NSTextInputContext *context = view.inputContext;
    if ([view hasMarkedText] && context) [context discardMarkedText];
    if (gStandardSourceSaved) restored = source_restore_and_verify(context);
    else if (!gStandardSourceSelectionAttempted) {
      gStandardRestoreStatus = ContrastSourceRestoreNoChangeNeeded;
      gStandardRestoreNeeded = NO;
      gStandardRestoreVerified = YES;
    } else {
      gStandardRestoreStatus = ContrastSourceRestoreNotSaved;
      gStandardRestoreVerified = NO;
      restored = NO;
    }
    if (!restored || !gStandardRestoreVerified) {
      gStandardCleanupResult = NO;
      gStandardCleaned = NO;
      return NO;
    }
    (void)[gOwnedWindow makeFirstResponder:nil];
    gOwnedWindow.delegate = nil;
    gOwnedWindow.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 240)];
  } else if (!gStandardSourceSelectionAttempted) {
    gStandardRestoreStatus = ContrastSourceRestoreNoChangeNeeded;
    gStandardRestoreNeeded = NO;
    gStandardRestoreVerified = YES;
  } else if (gStandardSourceSaved) {
    gStandardRestoreStatus = ContrastSourceRestoreFailed;
    gStandardRestoreVerified = NO;
    restored = NO;
  }
  if (gLocalMonitor) { [NSEvent removeMonitor:gLocalMonitor]; gLocalMonitor = nil; }
  if (gOwnedWindow) {
    gOwnedWindow.delegate = nil;
    [gOwnedWindow close];
    gWindowClosed = !gOwnedWindow.isVisible && !gOwnedWindow.isKeyWindow;
  }
  gStandardCleanupResult = restored && gStandardRestoreVerified && gWindowClosed;
  gStandardCleaned = YES;
  return gStandardCleanupResult;
}

static BOOL close_owned_window_after_gp_failure(void) {
  if (!gOwnedWindow || gWindowClosed) return YES;
  if (gOwner && !gGPViewCleaned && !finish_gpview_arm()) return NO;
  if (gOwner && gOwner.window && windows[@(gOwner.token)] == gOwner) return NO;
  if (gOwnedWindow.delegate) gOwnedWindow.delegate = nil;
  [gOwnedWindow makeFirstResponder:nil];
  gOwnedWindow.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 240)];
  [gOwnedWindow close];
  gWindowClosed = !gOwnedWindow.isVisible && !gOwnedWindow.isKeyWindow;
  return gWindowClosed;
}

int main(int argc, char **argv) {
  BOOL run_flag = argc == 2 && strcmp(argv[1], "--run") == 0;
  const char *opt_in_value = getenv(kRuntimeOptIn.UTF8String);
  BOOL opt_in = opt_in_value && strcmp(opt_in_value, "1") == 0;
  const char *old_dispatch_value = getenv("GPUI_FIELD_MACOS_IME_DISPATCH_TRACE");
  const char *old_style_value = getenv("GPUI_FIELD_MACOS_IME_STYLE_TRACE");
  BOOL old_dispatch = old_dispatch_value && strcmp(old_dispatch_value, "1") == 0;
  BOOL old_style = old_style_value && strcmp(old_style_value, "1") == 0;
  if (!gpui_contrast_runtime_allowed(run_flag, opt_in, old_dispatch, old_style)) {
    fputs("NSTEXTVIEW_CONTRAST_NOT_STARTED\n", stderr);
    return 2;
  }

  int exit_code = 1;
  ContrastArmResult gp_result = {0};
  ContrastArmResult standard_result = {0};
  @autoreleasepool {
    gObservations[ContrastArmGPView] = [ContrastObservation new];
    gObservations[ContrastArmNSTextView] = [ContrastObservation new];
    gApi = gpui_macos_api_v1();
    @try {
      gp_result = run_gpview_arm();
      gGPViewObserved = gp_result.observed;
      gGPViewPassed = gp_result.passed;
      if (finish_gpview_arm()) {
        gp_result.cleanup_ok = YES;
        emit_record(ContrastPhaseCleanup, ContrastArmGPView, ContrastOutcomePassed,
          ContrastArmGPView, -1, -1, gPrefixIterations[ContrastArmGPView] +
            gReturnIterations[ContrastArmGPView], NO, NO, NO, NO,
          gGPViewRestoreVerified, NO, NO, 0, NSMakeRange(NSNotFound, 0),
          NSMakeRange(NSNotFound, 0), gCallbackPreedit[ContrastArmGPView],
          gCallbackCommit[ContrastArmGPView], gCallbackUnmark[ContrastArmGPView], YES, YES);
      } else {
        emit_record(ContrastPhaseCleanup, ContrastArmGPView, ContrastOutcomeCleanupFailed,
          ContrastArmGPView, -1, -1, gPrefixIterations[ContrastArmGPView] +
            gReturnIterations[ContrastArmGPView], NO, NO, NO, NO,
          gGPViewRestoreVerified, NO, NO, 0, NSMakeRange(NSNotFound, 0),
          NSMakeRange(NSNotFound, 0), gCallbackPreedit[ContrastArmGPView],
          gCallbackCommit[ContrastArmGPView], gCallbackUnmark[ContrastArmGPView], NO, YES);
      }

      if (gGPViewCleanupResult && gOwnedWindow && !gWindowClosed) {
        standard_result = run_standard_arm();
        gStandardObserved = standard_result.observed;
        gStandardPassed = standard_result.passed;
        if (finish_standard_arm()) {
          standard_result.cleanup_ok = YES;
          emit_record(ContrastPhaseCleanup, ContrastArmNSTextView, ContrastOutcomePassed,
            ContrastArmNSTextView, -1, -1, gPrefixIterations[ContrastArmNSTextView] +
              gReturnIterations[ContrastArmNSTextView], NO, NO, NO, NO,
            gStandardRestoreVerified, NO, NO, 0, NSMakeRange(NSNotFound, 0),
            NSMakeRange(NSNotFound, 0), gCallbackPreedit[ContrastArmNSTextView],
            gCallbackCommit[ContrastArmNSTextView], gCallbackUnmark[ContrastArmNSTextView], YES, YES);
        } else {
          emit_record(ContrastPhaseCleanup, ContrastArmNSTextView, ContrastOutcomeCleanupFailed,
            ContrastArmNSTextView, -1, -1, gPrefixIterations[ContrastArmNSTextView] +
              gReturnIterations[ContrastArmNSTextView], NO, NO, NO, NO,
            gStandardRestoreVerified, NO, NO, 0, NSMakeRange(NSNotFound, 0),
            NSMakeRange(NSNotFound, 0), gCallbackPreedit[ContrastArmNSTextView],
            gCallbackCommit[ContrastArmNSTextView], gCallbackUnmark[ContrastArmNSTextView], NO, YES);
        }
      }
      exit_code = 0;
    } @catch (__unused NSException *exception) {
      fputs("NSTEXTVIEW_CONTRAST_EXCEPTION\n", stderr);
      gRunIncomplete = YES;
      exit_code = 1;
    } @finally {
      gCaptureEffects = NO;
      gCaptureNaturalQueries = NO;
      @try { if (!gGPViewCleaned) (void)finish_gpview_arm(); }
      @catch (__unused NSException *exception) { gRunIncomplete = YES; }
      @try {
        if (gOwnedWindow && [gOwnedWindow.contentView isKindOfClass:ContrastTextView.class] &&
            !gStandardCleaned) (void)finish_standard_arm();
        else if (gOwnedWindow && !gWindowClosed) (void)close_owned_window_after_gp_failure();
      } @catch (__unused NSException *exception) { gRunIncomplete = YES; }
      if (gLocalMonitor) { [NSEvent removeMonitor:gLocalMonitor]; gLocalMonitor = nil; }
      if (state == 1 && !gHostStopped) {
        @try { gHostStopped = gApi->call(2, 0, 0, 0, NULL, 0) == 0; }
        @catch (__unused NSException *exception) { gHostStopped = NO; }
      }
      if (gOwnedWindow && !gOwnedWindow.isVisible && !gOwnedWindow.isKeyWindow)
        gWindowClosed = YES;
      if (gOwnedWindow && !gWindowClosed &&
          [gOwnedWindow.contentView isKindOfClass:ContrastTextView.class]) {
        // Restoration was attempted with the client alive above. If it could
        // not be verified, keep the run non-comparable but still close the
        // owned standard-control window after the last restoration attempt.
        (void)[gOwnedWindow makeFirstResponder:nil];
        gOwnedWindow.delegate = nil;
        gOwnedWindow.contentView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 240)];
        [gOwnedWindow close];
        gWindowClosed = !gOwnedWindow.isVisible && !gOwnedWindow.isKeyWindow;
        gStandardCleanupResult = NO;
      }
    }
    BOOL cleanup_ok = gp_result.cleanup_ok && standard_result.cleanup_ok &&
      gGPViewCleanupResult && gStandardCleanupResult && gHostStopped && gWindowClosed &&
      !gRunIncomplete;
    GPUIContrastOutcome matrix = gpui_contrast_result(
      gp_result.observed && gp_result.preconditions_valid,
      standard_result.observed && standard_result.preconditions_valid,
      cleanup_ok, gp_result.passed, standard_result.passed);
    ContrastOutcome output = ContrastOutcomeNotComparable;
    switch (matrix) {
      case GPUIContrastCustomIntegration: output = ContrastOutcomeCustomIntegration; break;
      case GPUIContrastCommonPathOrStandardAdapter:
        output = ContrastOutcomeCommonPathOrStandardAdapter; break;
      case GPUIContrastSourceAppLoopNotReproduced:
        output = ContrastOutcomeSourceAppLoopNotReproduced; break;
      default: output = ContrastOutcomeNotComparable; break;
    }
    emit_record(ContrastPhaseResult, ContrastArmBoth, output, ContrastArmBoth, -1, -1,
      gPrefixIterations[ContrastArmGPView] + gReturnIterations[ContrastArmGPView] +
        gPrefixIterations[ContrastArmNSTextView] + gReturnIterations[ContrastArmNSTextView],
      gp_result.passed && standard_result.passed, NO, NO, NO,
      gGPViewRestoreVerified && gStandardRestoreVerified, NO, NO, 0,
      NSMakeRange(NSNotFound, 0), NSMakeRange(NSNotFound, 0),
      gCallbackPreedit[ContrastArmGPView] + gCallbackPreedit[ContrastArmNSTextView],
      gCallbackCommit[ContrastArmGPView] + gCallbackCommit[ContrastArmNSTextView],
      gCallbackUnmark[ContrastArmGPView] + gCallbackUnmark[ContrastArmNSTextView],
      cleanup_ok, YES);
    if (exit_code == 0 && (matrix == GPUIContrastNotComparable || !cleanup_ok)) exit_code = 1;
  }
  return exit_code;
}
