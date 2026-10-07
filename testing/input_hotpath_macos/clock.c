#include <limits.h>
#include <mach/mach_time.h>
#include <stdint.h>

static int timebase(mach_timebase_info_data_t *value) {
  return mach_timebase_info(value) == KERN_SUCCESS && value->denom != 0;
}

static int64_t ticks_to_ns(uint64_t ticks) {
  mach_timebase_info_data_t scale;
  if (!timebase(&scale))
    return -1;
  __uint128_t value = (__uint128_t)ticks * scale.numer / scale.denom;
  if (value > INT64_MAX)
    return -1;
  return (int64_t)value;
}

int64_t gpui_hotpath_now_ns(void) {
  return ticks_to_ns(mach_absolute_time());
}

int64_t gpui_hotpath_resolution_ns(void) {
  mach_timebase_info_data_t scale;
  if (!timebase(&scale))
    return -1;
  uint64_t numerator = scale.numer;
  uint64_t denominator = scale.denom;
  uint64_t resolution = (numerator + denominator - 1) / denominator;
  return resolution == 0 || resolution > INT64_MAX ? -1 : (int64_t)resolution;
}
