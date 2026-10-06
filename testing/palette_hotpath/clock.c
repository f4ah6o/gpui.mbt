#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <limits.h>
#include <time.h>

static int64_t checked_ns(struct timespec value) {
  if (value.tv_sec < 0 || value.tv_nsec < 0 || value.tv_nsec >= 1000000000L ||
      (uint64_t)value.tv_sec > (uint64_t)(INT64_MAX - value.tv_nsec) / 1000000000ULL)
    return -1;
  return (int64_t)value.tv_sec * 1000000000LL + value.tv_nsec;
}

int64_t gpui_hotpath_now_ns(void) {
  struct timespec value;
  return clock_gettime(CLOCK_MONOTONIC, &value) == 0 ? checked_ns(value) : -1;
}

int64_t gpui_hotpath_resolution_ns(void) {
  struct timespec value;
  return clock_getres(CLOCK_MONOTONIC, &value) == 0 ? checked_ns(value) : -1;
}
