#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef char gpui_owner_id_requires_u64[(sizeof(uint64_t) == 8) ? 1 : -1];

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

typedef volatile LONG64 owner_counter_t;
#define OWNER_COUNTER_ALIGN __declspec(align(8))
typedef char gpui_owner_id_requires_long64[(sizeof(LONG64) == 8) ? 1 : -1];

static LONG64 owner_id_as_long64(uint64_t value) {
  LONG64 result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

static uint64_t owner_id_as_uint64(LONG64 value) {
  uint64_t result;
  memcpy(&result, &value, sizeof(result));
  return result;
}

static uint64_t owner_counter_load(owner_counter_t *counter) {
  const LONG64 observed = InterlockedCompareExchange64(counter, 0, 0);
  return owner_id_as_uint64(observed);
}

static bool owner_counter_compare_exchange(
    owner_counter_t *counter,
    uint64_t *expected,
    uint64_t desired) {
  const LONG64 observed = InterlockedCompareExchange64(
      counter, owner_id_as_long64(desired), owner_id_as_long64(*expected));
  const uint64_t actual = owner_id_as_uint64(observed);
  if (actual == *expected) {
    return true;
  }
  *expected = actual;
  return false;
}

#else
#include <stdatomic.h>

typedef _Atomic(uint64_t) owner_counter_t;
#define OWNER_COUNTER_ALIGN _Alignas(8)

static uint64_t owner_counter_load(owner_counter_t *counter) {
  return atomic_load_explicit(counter, memory_order_relaxed);
}

static bool owner_counter_compare_exchange(
    owner_counter_t *counter,
    uint64_t *expected,
    uint64_t desired) {
  return atomic_compare_exchange_weak_explicit(
      counter, expected, desired, memory_order_relaxed, memory_order_relaxed);
}
#endif

static OWNER_COUNTER_ALIGN owner_counter_t owner_id_counter = 1;

static uint64_t owner_counter_next(owner_counter_t *counter) {
  uint64_t current = owner_counter_load(counter);
  for (;;) {
    if (current == 0) {
      return 0;
    }

    const uint64_t next = current == UINT64_MAX ? 0 : current + 1;
    uint64_t expected = current;
    if (owner_counter_compare_exchange(counter, &expected, next)) {
      return current;
    }
    current = expected;
  }
}

uint64_t gpui_accessibility_next_owner_id(void) {
  return owner_counter_next(&owner_id_counter);
}

#if defined(GPUI_ACCESSIBILITY_OWNER_ID_TEST)
void gpui_accessibility_owner_id_test_init_counter(
    owner_counter_t *counter, uint64_t value) {
#if defined(_WIN32)
  *counter = owner_id_as_long64(value);
#else
  atomic_init(counter, value);
#endif
}

uint64_t gpui_accessibility_owner_id_test_next_counter(
    owner_counter_t *counter) {
  return owner_counter_next(counter);
}
#endif
