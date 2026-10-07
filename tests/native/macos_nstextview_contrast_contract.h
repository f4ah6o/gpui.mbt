#ifndef GPUI_MACOS_NSTEXTVIEW_CONTRAST_CONTRACT_H
#define GPUI_MACOS_NSTEXTVIEW_CONTRAST_CONTRACT_H

#include <stdbool.h>
#include <stddef.h>

enum {
  GPUI_NSTEXTVIEW_CONTRAST_RECORD_LIMIT = 64,
  GPUI_NSTEXTVIEW_CONTRAST_ORDINARY_LIMIT = 55,
  GPUI_NSTEXTVIEW_CONTRAST_TERMINAL_LIMIT = 8,
  GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT = 9,
  GPUI_NSTEXTVIEW_CONTRAST_STARTUP_LIMIT = 200,
};

typedef enum {
  GPUIContrastBudgetBlocked = 0,
  GPUIContrastBudgetOrdinary = 1,
  GPUIContrastBudgetTruncation = 2,
  GPUIContrastBudgetTerminal = 3,
} GPUIContrastBudgetDecision;

typedef struct {
  unsigned int total;
  unsigned int ordinary;
  unsigned int terminal;
  bool truncation_emitted;
} GPUIContrastRecordBudget;

typedef enum {
  GPUIContrastNotComparable = 0,
  GPUIContrastCustomIntegration = 1,
  GPUIContrastCommonPathOrStandardAdapter = 2,
  GPUIContrastSourceAppLoopNotReproduced = 3,
} GPUIContrastOutcome;

typedef enum {
  GPUIContrastCharacterN = 0,
  GPUIContrastCharacterI = 1,
  GPUIContrastCharacterH = 2,
  GPUIContrastCharacterO = 3,
  GPUIContrastCharacterG = 4,
  GPUIContrastCharacterSpace = 5,
  GPUIContrastCharacterReturn = 6,
} GPUIContrastCharacter;

typedef struct {
  bool focus_owned;
  bool context_matches_client;
  bool source_selected;
  bool baseline_matches;
  bool geometry_matches;
  bool producer_available;
} GPUIContrastPreconditions;

typedef enum {
  GPUIContrastDeliveryGPView = 1,
  GPUIContrastDeliveryNSTextView = 2,
} GPUIContrastDeliveryArm;

typedef struct {
  bool down;
  bool up;
} GPUIContrastDeliveryEvidence;

typedef struct {
  bool observed;
  bool passed;
} GPUIContrastReturnFacts;

typedef enum {
  GPUIContrastStartupStop = 0,
  GPUIContrastStartupWait = 1,
  GPUIContrastStartupReady = 2,
} GPUIContrastStartupDecision;

typedef enum {
  GPUIContrastObservedUnknown = -1,
  GPUIContrastObservedFalse = 0,
  GPUIContrastObservedTrue = 1,
} GPUIContrastObservedBool;

typedef struct {
  bool evaluated;
  bool value;
} GPUIContrastObservedFact;

static inline void gpui_contrast_reset_observed_fact(GPUIContrastObservedFact *fact) {
  if (!fact) return;
  fact->evaluated = false;
  fact->value = false;
}

static inline void gpui_contrast_capture_observed_fact(GPUIContrastObservedFact *fact,
                                                       bool value) {
  if (!fact) return;
  fact->evaluated = true;
  fact->value = value;
}

static inline GPUIContrastObservedBool gpui_contrast_observed_fact_value(
    GPUIContrastObservedFact fact) {
  if (!fact.evaluated) return GPUIContrastObservedUnknown;
  return fact.value ? GPUIContrastObservedTrue : GPUIContrastObservedFalse;
}

static inline bool gpui_contrast_runtime_allowed(bool run_flag,
                                                bool dedicated_opt_in,
                                                bool legacy_dispatch_trace,
                                                bool legacy_style_trace) {
  return run_flag && dedicated_opt_in && !legacy_dispatch_trace && !legacy_style_trace;
}

static inline int gpui_contrast_key_code(size_t index) {
  static const int codes[GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT] = {
    45, 34, 4, 31, 45, 5, 31, 49, 36,
  };
  return index < GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT ? codes[index] : -1;
}

static inline GPUIContrastCharacter gpui_contrast_character(size_t index) {
  static const GPUIContrastCharacter characters[GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT] = {
    GPUIContrastCharacterN, GPUIContrastCharacterI, GPUIContrastCharacterH,
    GPUIContrastCharacterO, GPUIContrastCharacterN, GPUIContrastCharacterG,
    GPUIContrastCharacterO, GPUIContrastCharacterSpace, GPUIContrastCharacterReturn,
  };
  return index < GPUI_NSTEXTVIEW_CONTRAST_KEY_COUNT ? characters[index] : -1;
}

static inline bool gpui_contrast_preconditions_hold(GPUIContrastPreconditions facts) {
  return facts.focus_owned && facts.context_matches_client && facts.source_selected &&
    facts.baseline_matches && facts.geometry_matches && facts.producer_available;
}

static inline bool gpui_contrast_delivery_valid(bool nonce_matches,
                                               bool event_type_matches,
                                               bool key_code_matches,
                                               bool characters_match,
                                               bool ignoring_modifiers_match,
                                               unsigned int modifier_bits,
                                               bool target_window_matches) {
  return nonce_matches && event_type_matches && key_code_matches && characters_match &&
    ignoring_modifiers_match && modifier_bits == 0 && target_window_matches;
}

static inline bool gpui_contrast_pair_complete(bool same_dispatch_id,
                                               bool down_delivered,
                                               bool up_delivered) {
  return same_dispatch_id && down_delivered && up_delivered;
}

static inline GPUIContrastDeliveryEvidence gpui_contrast_delivery_evidence(
    GPUIContrastDeliveryArm arm,
    bool monitor_down_valid,
    bool monitor_up_valid,
    bool standard_view_down_valid,
    bool standard_view_up_valid,
    bool native_receipt_valid,
    bool native_down_dispatched,
    bool native_up_dispatched) {
  if (arm == GPUIContrastDeliveryGPView) {
    return (GPUIContrastDeliveryEvidence){
      .down = monitor_down_valid && native_receipt_valid && native_down_dispatched,
      .up = monitor_up_valid && native_receipt_valid && native_up_dispatched,
    };
  }
  if (arm == GPUIContrastDeliveryNSTextView) {
    return (GPUIContrastDeliveryEvidence){
      .down = monitor_down_valid && standard_view_down_valid,
      .up = monitor_up_valid && standard_view_up_valid,
    };
  }
  return (GPUIContrastDeliveryEvidence){false, false};
}

static inline bool gpui_contrast_return_observed(bool pair_complete,
                                                 bool owned_environment_valid,
                                                 bool queue_quiescent,
                                                 bool pump_ok) {
  return pair_complete && owned_environment_valid && queue_quiescent && pump_ok;
}

static inline GPUIContrastReturnFacts gpui_contrast_return_facts(bool observed,
                                                                 bool passed) {
  return (GPUIContrastReturnFacts){.observed = observed, .passed = observed && passed};
}

static inline bool gpui_contrast_startup_event_allowed(GPUIContrastDeliveryArm arm,
                                                       int event_kind,
                                                       bool owned_window_event) {
  if (event_kind == 0) return true;
  return arm == GPUIContrastDeliveryGPView && owned_window_event &&
    event_kind >= 1 && event_kind <= 6;
}

static inline GPUIContrastStartupDecision gpui_contrast_startup_step(
    GPUIContrastDeliveryArm arm,
    bool owned_view_and_window,
    bool host_running,
    bool pump_ok,
    bool event_allowed,
    bool focus_owned,
    bool context_matches,
    unsigned int iterations,
    unsigned int iteration_limit) {
  if ((arm != GPUIContrastDeliveryGPView && arm != GPUIContrastDeliveryNSTextView) ||
      !owned_view_and_window || !host_running || !pump_ok || !event_allowed)
    return GPUIContrastStartupStop;
  if (focus_owned && context_matches) return GPUIContrastStartupReady;
  return iterations >= iteration_limit ? GPUIContrastStartupStop : GPUIContrastStartupWait;
}

static inline bool gpui_contrast_startup_allows_input(GPUIContrastStartupDecision decision) {
  return decision == GPUIContrastStartupReady;
}

static inline GPUIContrastObservedBool gpui_contrast_observed_bool(bool evaluated,
                                                                    bool value) {
  GPUIContrastObservedFact fact = {.evaluated = evaluated, .value = value};
  return gpui_contrast_observed_fact_value(fact);
}

static inline GPUIContrastBudgetDecision gpui_contrast_claim_ordinary(
    GPUIContrastRecordBudget *budget) {
  if (!budget || budget->total >= GPUI_NSTEXTVIEW_CONTRAST_RECORD_LIMIT)
    return GPUIContrastBudgetBlocked;
  if (budget->ordinary < GPUI_NSTEXTVIEW_CONTRAST_ORDINARY_LIMIT) {
    budget->ordinary++;
    budget->total++;
    return GPUIContrastBudgetOrdinary;
  }
  if (!budget->truncation_emitted) {
    budget->truncation_emitted = true;
    budget->total++;
    return GPUIContrastBudgetTruncation;
  }
  return GPUIContrastBudgetBlocked;
}

static inline GPUIContrastBudgetDecision gpui_contrast_claim_terminal(
    GPUIContrastRecordBudget *budget) {
  if (!budget || budget->terminal >= GPUI_NSTEXTVIEW_CONTRAST_TERMINAL_LIMIT ||
      budget->total >= GPUI_NSTEXTVIEW_CONTRAST_RECORD_LIMIT)
    return GPUIContrastBudgetBlocked;
  budget->terminal++;
  budget->total++;
  return GPUIContrastBudgetTerminal;
}

static inline GPUIContrastOutcome gpui_contrast_result(bool gpview_observed,
                                                       bool standard_observed,
                                                       bool cleanup_ok,
                                                       bool gpview_passed,
                                                       bool standard_passed) {
  if (!gpview_observed || !standard_observed || !cleanup_ok)
    return GPUIContrastNotComparable;
  if (standard_passed && !gpview_passed) return GPUIContrastCustomIntegration;
  if (!standard_passed && !gpview_passed)
    return GPUIContrastCommonPathOrStandardAdapter;
  if (standard_passed && gpview_passed)
    return GPUIContrastSourceAppLoopNotReproduced;
  return GPUIContrastNotComparable;
}

#endif
