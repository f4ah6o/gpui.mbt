// Fixture-free unit coverage for the opt-in callback trace predicates.
#define GPUI_TESTING 1
#import "../../platform/macos/native.m"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static GPUIImeCallbackFacts facts(void) {
  return (GPUIImeCallbackFacts){
    .owner_present = YES,
    .closing = NO,
    .suppress_callbacks = NO,
    .session_active = YES,
    .direct_text = NO,
    .has_marked_text = YES,
    .text_dispatch_active = YES,
    .session_awaiting_ack = YES,
    .dispatch_key_available = YES,
  };
}

static GPUIImeCallbackTraceGateFacts gate_facts(void) {
  return (GPUIImeCallbackTraceGateFacts){
    .opt_in = YES,
    .has_view = YES,
    .has_owner = YES,
    .view_owns_owner = YES,
    .content_view_matches = YES,
    .fixture_source_saved = YES,
    .matching_synthetic_receipt = YES,
    .trace_session_initialized = YES,
    .owner_closing = NO,
    .session_active = YES,
  };
}

static void test_callback_trace_gate(void) {
  GPUIImeCallbackTraceGateFacts gate = gate_facts();
  assert(macos_ime_callback_trace_gate_allows(gate));
  gate.opt_in = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.has_view = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.has_owner = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.view_owns_owner = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.content_view_matches = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.fixture_source_saved = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.matching_synthetic_receipt = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.trace_session_initialized = NO;
  assert(!macos_ime_callback_trace_gate_allows(gate));
  gate = gate_facts(); gate.owner_closing = YES; gate.session_active = NO;
  assert(macos_ime_callback_trace_gate_allows(gate));
}

static void test_real_callback_guard_classifier(void) {
  GPUIImeCallbackFacts f = facts();
  assert(macos_ime_callback_guard(GPUIImeCallbackInsertText, f) == GPUIImeCallbackGuardNone);
  f.owner_present = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackInsertText, f) == GPUIImeCallbackGuardNoOwner);
  f = facts(); f.closing = YES;
  assert(macos_ime_callback_guard(GPUIImeCallbackInsertText, f) == GPUIImeCallbackGuardClosing);
  f = facts(); f.suppress_callbacks = YES;
  assert(macos_ime_callback_guard(GPUIImeCallbackSetMarkedText, f) == GPUIImeCallbackGuardSuppressed);
  f = facts(); f.session_active = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackSetMarkedText, f) == GPUIImeCallbackGuardInactiveSession);
  f.direct_text = YES;
  assert(macos_ime_callback_guard(GPUIImeCallbackSetMarkedText, f) == GPUIImeCallbackGuardNone);
  f = facts(); f.has_marked_text = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackUnmarkText, f) == GPUIImeCallbackGuardNoMarkedText);
  f = facts(); f.closing = YES;
  assert(macos_ime_callback_guard(GPUIImeCallbackUnmarkText, f) == GPUIImeCallbackGuardNone);
  f = facts(); f.session_active = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackDoCommand, f) == GPUIImeCallbackGuardInactiveSession);
  f = facts(); f.text_dispatch_active = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackDoCommand, f) == GPUIImeCallbackGuardInactiveDispatch);
  f = facts(); f.dispatch_key_available = NO;
  assert(macos_ime_callback_guard(GPUIImeCallbackDoCommand, f) == GPUIImeCallbackGuardNoDispatchKey);
  f = facts(); f.closing = YES; f.suppress_callbacks = YES;
  assert(macos_ime_callback_guard(GPUIImeCallbackDoCommand, f) == GPUIImeCallbackGuardNone);
}

static void test_fixed_selector_classification(void) {
  assert(macos_ime_command_kind(NULL) == GPUIImeCommandKindNone);
  assert(macos_ime_command_kind(@selector(insertNewline:)) == GPUIImeCommandKindInsertNewline);
  assert(macos_ime_command_kind(@selector(insertNewlineIgnoringFieldEditor:)) ==
    GPUIImeCommandKindInsertNewlineIgnoringFieldEditor);
  assert(macos_ime_command_kind(@selector(noop:)) == GPUIImeCommandKindNoop);
  assert(macos_ime_command_kind(sel_registerName("arbitraryPrivateCommand:")) ==
    GPUIImeCommandKindOther);
  assert(strcmp(macos_ime_command_kind_name(GPUIImeCommandKindOther), "other") == 0);
}

static void test_callback_trace_record_contract(void) {
  GPUIImeCallbackTraceGateFacts gate = gate_facts();
  GPUIImeCallbackFacts callback = facts();
  NSDictionary *scope = macos_ime_callback_trace_scope_record(gate, 45, 3, 9, callback);
  assert(macos_ime_callback_trace_record_is_bounded(scope));
  assert([scope[@"scope_armed"] boolValue]);
  assert([scope[@"route_dispatch_id"] longLongValue] == 45);
  assert(scope[@"observation_id"] == NSNull.null);
  assert([scope[@"session_awaiting_ack"] boolValue]);
  gate.matching_synthetic_receipt = NO;
  NSDictionary *unarmed_scope = macos_ime_callback_trace_scope_record(gate, 45, 3, 9, callback);
  assert(macos_ime_callback_trace_record_is_bounded(unarmed_scope));
  assert(![unarmed_scope[@"scope_armed"] boolValue]);
  assert([unarmed_scope[@"scope_reason"] isEqual:@"receipt_not_matching"]);

  gate = gate_facts();
  NSDictionary *entry = macos_ime_callback_trace_entry_record(
    GPUIImeCallbackDoCommand, GPUIImeCommandKindInsertNewline, 7, nil, 3, 9, gate, callback);
  assert(macos_ime_callback_trace_record_is_bounded(entry));
  assert([entry[@"callback_kind"] isEqual:@"do_command_by_selector"]);
  assert(entry[@"route_dispatch_id"] == NSNull.null);
  assert(entry[@"current_key_code"] == NSNull.null);
  assert([entry[@"selector_kind"] isEqual:@"insert_newline"]);
  NSDictionary *result = macos_ime_callback_trace_result_record(
    entry, GPUIImeCallbackGuardNone, GPUIImeCallbackResultInvalidText);
  assert(macos_ime_callback_trace_record_is_bounded(result));
  assert([result[@"observation_id"] unsignedIntegerValue] == 7);
  assert([result[@"session_active"] boolValue]);
  assert([result[@"owner_closing"] boolValue] == NO);
  assert([result[@"guard_reason"] isEqual:@"none"]);
  assert([result[@"result"] isEqual:@"invalid_text"]);

  NSMutableDictionary *leaks_text = [entry mutableCopy];
  leaks_text[@"text"] = @"must never be emitted";
  assert(!macos_ime_callback_trace_record_is_bounded(leaks_text));
  NSMutableDictionary *leaks_selector = [entry mutableCopy];
  leaks_selector[@"selector_kind"] = @"arbitraryPrivateCommand:";
  assert(!macos_ime_callback_trace_record_is_bounded(leaks_selector));
}

static void test_shared_native_trace_budget(void) {
  NSUInteger count = 0;
  BOOL truncated = NO;
  for (NSUInteger i = 0; i < GPUI_IME_DISPATCH_TRACE_ORDINARY_LIMIT; i++) {
    assert(macos_ime_dispatch_trace_claim_slot(&count, &truncated) == GPUIImeTraceSlotGranted);
  }
  assert(count == 61 && !truncated);
  assert(macos_ime_dispatch_trace_claim_slot(&count, &truncated) == GPUIImeTraceSlotTruncated);
  assert(count == 62 && truncated);
  assert(macos_ime_dispatch_trace_claim_slot(&count, &truncated) == GPUIImeTraceSlotBlocked);
  assert(count == 62);
  NSUInteger route_count = 0;
  assert(macos_ime_dispatch_trace_route_slot_available(route_count, count));
  route_count++;
  assert(macos_ime_dispatch_trace_route_slot_available(route_count, count));
  route_count++;
  count++;
  assert(count == 63 && !macos_ime_dispatch_trace_route_slot_available(route_count, count));
  count++;
  assert(count == GPUI_IME_DISPATCH_TRACE_LIMIT);
}

int main(void) {
  test_callback_trace_gate();
  test_real_callback_guard_classifier();
  test_fixed_selector_classification();
  test_callback_trace_record_contract();
  test_shared_native_trace_budget();
  fputs("fixture-free callback trace tests passed (no NSApp/NSWindow/API startup)\n", stdout);
  return 0;
}
