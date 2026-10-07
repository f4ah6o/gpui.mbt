#include "macos_nstextview_contrast_contract.h"

#include <assert.h>
#include <stdio.h>

static void test_runtime_gate(void) {
  assert(!gpui_contrast_runtime_allowed(false, true, false, false));
  assert(!gpui_contrast_runtime_allowed(true, false, false, false));
  assert(!gpui_contrast_runtime_allowed(true, true, true, false));
  assert(!gpui_contrast_runtime_allowed(true, true, false, true));
  assert(gpui_contrast_runtime_allowed(true, true, false, false));
}

static void test_preconditions_and_delivery(void) {
  GPUIContrastPreconditions facts = {true, true, true, true, true, true};
  assert(gpui_contrast_preconditions_hold(facts));
  facts.focus_owned = false;
  assert(!gpui_contrast_preconditions_hold(facts));
  facts.focus_owned = true; facts.context_matches_client = false;
  assert(!gpui_contrast_preconditions_hold(facts));
  facts.context_matches_client = true; facts.source_selected = false;
  assert(!gpui_contrast_preconditions_hold(facts));
  facts.source_selected = true; facts.baseline_matches = false;
  assert(!gpui_contrast_preconditions_hold(facts));
  facts.baseline_matches = true; facts.geometry_matches = false;
  assert(!gpui_contrast_preconditions_hold(facts));
  facts.geometry_matches = true; facts.producer_available = false;
  assert(!gpui_contrast_preconditions_hold(facts));

  assert(gpui_contrast_delivery_valid(true, true, true, true, true, 0, true));
  assert(!gpui_contrast_delivery_valid(false, true, true, true, true, 0, true));
  assert(!gpui_contrast_delivery_valid(true, false, true, true, true, 0, true));
  assert(!gpui_contrast_delivery_valid(true, true, false, true, true, 0, true));
  assert(!gpui_contrast_delivery_valid(true, true, true, false, true, 0, true));
  assert(!gpui_contrast_delivery_valid(true, true, true, true, false, 0, true));
  assert(!gpui_contrast_delivery_valid(true, true, true, true, true, 1, true));
  assert(!gpui_contrast_delivery_valid(true, true, true, true, true, 0, false));
  assert(gpui_contrast_pair_complete(true, true, true));
  assert(!gpui_contrast_pair_complete(false, true, true));
  assert(!gpui_contrast_pair_complete(true, false, true));
  assert(!gpui_contrast_pair_complete(true, true, false));
  assert(gpui_contrast_return_observed(true, true, true, true));
  assert(!gpui_contrast_return_observed(false, true, true, true));
  assert(!gpui_contrast_return_observed(true, false, true, true));
  assert(!gpui_contrast_return_observed(true, true, false, true));
  assert(!gpui_contrast_return_observed(true, true, true, false));
}

static void test_arm_specific_delivery_evidence(void) {
  GPUIContrastDeliveryEvidence gp_full = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryGPView, true, true, false, false, true, true, true);
  assert(gp_full.down && gp_full.up);
  GPUIContrastDeliveryEvidence gp_partial = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryGPView, true, false, false, false, true, true, false);
  assert(gp_partial.down && !gp_partial.up);
  GPUIContrastDeliveryEvidence gp_missing_receipt = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryGPView, true, true, false, false, false, true, true);
  assert(!gp_missing_receipt.down && !gp_missing_receipt.up);
  GPUIContrastDeliveryEvidence gp_missing_monitor = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryGPView, false, true, false, false, true, true, true);
  assert(!gp_missing_monitor.down && gp_missing_monitor.up);

  GPUIContrastDeliveryEvidence standard_full = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryNSTextView, true, true, true, true, false, false, false);
  assert(standard_full.down && standard_full.up);
  GPUIContrastDeliveryEvidence standard_partial = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryNSTextView, true, false, true, false, false, false, false);
  assert(standard_partial.down && !standard_partial.up);
  GPUIContrastDeliveryEvidence standard_missing_view = gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryNSTextView, true, true, false, true, false, false, false);
  assert(!standard_missing_view.down && standard_missing_view.up);
  GPUIContrastDeliveryEvidence unknown_arm = gpui_contrast_delivery_evidence(
    0, true, true, true, true, true, true, true);
  assert(!unknown_arm.down && !unknown_arm.up);
}

static void test_return_record_facts(void) {
  GPUIContrastReturnFacts success = gpui_contrast_return_facts(true, true);
  assert(success.observed && success.passed);
  GPUIContrastReturnFacts observed_timeout = gpui_contrast_return_facts(true, false);
  assert(observed_timeout.observed && !observed_timeout.passed);
  GPUIContrastReturnFacts invalid_observation = gpui_contrast_return_facts(false, false);
  assert(!invalid_observation.observed && !invalid_observation.passed);
  GPUIContrastReturnFacts invalid_cannot_pass = gpui_contrast_return_facts(false, true);
  assert(!invalid_cannot_pass.observed && !invalid_cannot_pass.passed);
}

static void test_startup_readiness_transition(void) {
  GPUIContrastDeliveryArm arms[] = {
    GPUIContrastDeliveryGPView, GPUIContrastDeliveryNSTextView,
  };
  for (size_t i = 0; i < sizeof(arms) / sizeof(arms[0]); i++) {
    GPUIContrastDeliveryArm arm = arms[i];
    GPUIContrastStartupDecision waiting = gpui_contrast_startup_step(
      arm, true, true, true, true, false, false, 0,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
    assert(waiting == GPUIContrastStartupWait);
    assert(!gpui_contrast_startup_allows_input(waiting));
    GPUIContrastStartupDecision ready_after_pump = gpui_contrast_startup_step(
      arm, true, true, true, true, true, true, 1,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
    assert(ready_after_pump == GPUIContrastStartupReady);
    assert(gpui_contrast_startup_allows_input(ready_after_pump));
    GPUIContrastStartupDecision timed_out = gpui_contrast_startup_step(
      arm, true, true, true, true, false, false,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
    assert(timed_out == GPUIContrastStartupStop);
    assert(!gpui_contrast_startup_allows_input(timed_out));
    GPUIContrastStartupDecision ready_on_limit = gpui_contrast_startup_step(
      arm, true, true, true, true, true, true,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT,
      GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT);
    assert(ready_on_limit == GPUIContrastStartupReady);
    assert(gpui_contrast_startup_allows_input(ready_on_limit));
    assert(gpui_contrast_startup_step(arm, true, true, true, true,
      true, false, 1, GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) ==
      GPUIContrastStartupWait);
    assert(gpui_contrast_startup_step(arm, true, true, true, true,
      false, true, 1, GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) ==
      GPUIContrastStartupWait);
  }

  assert(gpui_contrast_startup_event_allowed(GPUIContrastDeliveryGPView, 0, false));
  assert(gpui_contrast_startup_event_allowed(GPUIContrastDeliveryNSTextView, 0, false));
  for (int kind = 1; kind <= 6; kind++) {
    assert(gpui_contrast_startup_event_allowed(GPUIContrastDeliveryGPView, kind, true));
    assert(!gpui_contrast_startup_event_allowed(GPUIContrastDeliveryGPView, kind, false));
    assert(!gpui_contrast_startup_event_allowed(GPUIContrastDeliveryNSTextView, kind, true));
  }
  assert(!gpui_contrast_startup_event_allowed(GPUIContrastDeliveryGPView, 16, true));
  assert(!gpui_contrast_startup_event_allowed(GPUIContrastDeliveryGPView, 18, true));

  assert(gpui_contrast_startup_step(GPUIContrastDeliveryGPView,
    false, true, true, true, false, false, 0,
    GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) == GPUIContrastStartupStop);
  assert(gpui_contrast_startup_step(GPUIContrastDeliveryNSTextView,
    true, false, true, true, false, false, 0,
    GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) == GPUIContrastStartupStop);
  assert(gpui_contrast_startup_step(GPUIContrastDeliveryGPView,
    true, true, false, true, false, false, 0,
    GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) == GPUIContrastStartupStop);
  assert(gpui_contrast_startup_step(GPUIContrastDeliveryGPView,
    true, true, true, false, false, false, 0,
    GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) == GPUIContrastStartupStop);
  assert(gpui_contrast_startup_step(0,
    true, true, true, true, true, true, 0,
    GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT) == GPUIContrastStartupStop);
}

static bool mock_startup_getter(bool *called, bool value) {
  *called = true;
  return value;
}

static void test_startup_observation_tristate(void) {
  GPUIContrastObservedFact first = {0};
  GPUIContrastObservedFact later = {0};
  gpui_contrast_reset_observed_fact(&first);
  gpui_contrast_reset_observed_fact(&later);
  bool first_getter_called = false;
  bool later_getter_called = false;
  /* A failed earlier component short-circuits the later getter. */
  bool first_value = mock_startup_getter(&first_getter_called, false);
  gpui_contrast_capture_observed_fact(&first, first_value);
  if (first_value) {
    bool later_value = mock_startup_getter(&later_getter_called, true);
    gpui_contrast_capture_observed_fact(&later, later_value);
  }
  assert(first_getter_called && !first.value);
  assert(!later_getter_called);
  assert(gpui_contrast_observed_fact_value(first) == GPUIContrastObservedFalse);
  assert(gpui_contrast_observed_fact_value(later) == GPUIContrastObservedUnknown);

  /* A new snapshot cannot reuse either result from the prior snapshot. */
  gpui_contrast_capture_observed_fact(&first, true);
  gpui_contrast_capture_observed_fact(&later, true);
  assert(gpui_contrast_observed_fact_value(first) == GPUIContrastObservedTrue);
  assert(gpui_contrast_observed_fact_value(later) == GPUIContrastObservedTrue);
  gpui_contrast_reset_observed_fact(&first);
  gpui_contrast_reset_observed_fact(&later);
  assert(gpui_contrast_observed_fact_value(first) == GPUIContrastObservedUnknown);
  assert(gpui_contrast_observed_fact_value(later) == GPUIContrastObservedUnknown);
  assert(gpui_contrast_observed_bool(false, false) == GPUIContrastObservedUnknown);
  assert(gpui_contrast_observed_bool(false, true) == GPUIContrastObservedUnknown);
  assert(gpui_contrast_observed_bool(true, false) == GPUIContrastObservedFalse);
  assert(gpui_contrast_observed_bool(true, true) == GPUIContrastObservedTrue);
}

static void test_fixed_sequence_and_result_matrix(void) {
  static const int expected_codes[GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT] = {
    45, 34, 4, 31, 45, 5, 31, 49, 36,
  };
  static const GPUIContrastCharacter expected_chars[GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT] = {
    GPUIContrastCharacterN, GPUIContrastCharacterI, GPUIContrastCharacterH,
    GPUIContrastCharacterO, GPUIContrastCharacterN, GPUIContrastCharacterG,
    GPUIContrastCharacterO, GPUIContrastCharacterSpace, GPUIContrastCharacterReturn,
  };
  for (size_t i = 0; i < GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT; i++) {
    assert(gpui_contrast_key_code(i) == expected_codes[i]);
    assert(gpui_contrast_character(i) == expected_chars[i]);
  }
  assert(gpui_contrast_key_code(GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT) == -1);

  assert(gpui_contrast_result(false, true, true, false, true) == GPUIContrastNotComparable);
  assert(gpui_contrast_result(true, false, true, false, true) == GPUIContrastNotComparable);
  assert(gpui_contrast_result(true, true, false, false, true) == GPUIContrastNotComparable);
  assert(gpui_contrast_result(true, true, true, false, true) == GPUIContrastCustomIntegration);
  assert(gpui_contrast_result(true, true, true, false, false) ==
    GPUIContrastCommonPathOrStandardAdapter);
  assert(gpui_contrast_result(true, true, true, true, true) ==
    GPUIContrastSourceAppLoopNotReproduced);
  assert(gpui_contrast_result(true, true, true, true, false) == GPUIContrastNotComparable);
}

static void test_record_budget_boundaries(void) {
  GPUIContrastRecordBudget budget = {0};
  for (unsigned int i = 0; i < GPUI_NSTEXTVIEW_CONTRAST_ORDINARY_LIMIT; i++)
    assert(gpui_contrast_claim_ordinary(&budget) == GPUIContrastBudgetOrdinary);
  assert(budget.total == 55 && budget.ordinary == 55 && !budget.truncation_emitted);
  assert(gpui_contrast_claim_ordinary(&budget) == GPUIContrastBudgetTruncation);
  assert(budget.total == 56 && budget.truncation_emitted);
  assert(gpui_contrast_claim_ordinary(&budget) == GPUIContrastBudgetBlocked);

  for (unsigned int i = 0; i < GPUI_NSTEXTVIEW_CONTRAST_TERMINAL_LIMIT; i++)
    assert(gpui_contrast_claim_terminal(&budget) == GPUIContrastBudgetTerminal);
  assert(budget.total == GPUI_NSTEXTVIEW_CONTRAST_RECORD_LIMIT);
  assert(gpui_contrast_claim_terminal(&budget) == GPUIContrastBudgetBlocked);
  assert(gpui_contrast_claim_ordinary(&budget) == GPUIContrastBudgetBlocked);

  GPUIContrastRecordBudget no_overflow = {0};
  assert(gpui_contrast_claim_ordinary(&no_overflow) == GPUIContrastBudgetOrdinary);
  for (unsigned int i = 0; i < GPUI_NSTEXTVIEW_CONTRAST_TERMINAL_LIMIT; i++)
    assert(gpui_contrast_claim_terminal(&no_overflow) == GPUIContrastBudgetTerminal);
  assert(no_overflow.total == 9);
}

int main(void) {
  test_runtime_gate();
  test_preconditions_and_delivery();
  test_arm_specific_delivery_evidence();
  test_return_record_facts();
  test_startup_readiness_transition();
  test_startup_observation_tristate();
  test_fixed_sequence_and_result_matrix();
  test_record_budget_boundaries();
  puts("NSTextView contrast contract tests passed (pure C; no AppKit startup)");
  return 0;
}
