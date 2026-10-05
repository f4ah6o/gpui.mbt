#define _POSIX_C_SOURCE 200809L

#include <stdint.h>
#include <time.h>

int64_t gpui_field_test_monotonic_ns(void);

int64_t gpui_field_test_monotonic_ns(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) != 0 || value.tv_sec < 0 ||
      value.tv_nsec < 0 || value.tv_nsec >= 1000000000L) {
    return -1;
  }

  const uint64_t seconds = (uint64_t)value.tv_sec;
  const uint64_t nanoseconds = (uint64_t)value.tv_nsec;
  const uint64_t maximum = (uint64_t)INT64_MAX;
  if (seconds > (maximum - nanoseconds) / 1000000000ULL) {
    return -1;
  }
  return (int64_t)(seconds * 1000000000ULL + nanoseconds);
}
