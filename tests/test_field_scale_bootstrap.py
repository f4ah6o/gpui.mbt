"""Regression tests for the hosted field scale-mapping bootstrap.

The production C helper is extracted verbatim and compiled against a fake
host, metrics API, clock, and dispatch loop. No display server or GPU is used.
"""

from __future__ import annotations

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "tests" / "ubuntu" / "field_gpu_test.c"
FRAME_BEGIN = "/* FIELD_FRAME_WAIT_BEGIN"
FRAME_END = "/* FIELD_FRAME_WAIT_END */"
BOOTSTRAP_BEGIN = "/* FIELD_SCALE_BOOTSTRAP_BEGIN"
BOOTSTRAP_END = "/* FIELD_SCALE_BOOTSTRAP_END */"


HARNESS_PREFIX = r"""
#define _POSIX_C_SOURCE 200809L
#include <assert.h>
#include <signal.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define GPUI_OK 0
#define GPUI_NATIVE 2
#define GPUI_BUSY 5
#define GPUI_ORIGIN_FRAME_ABI 3
#define GPUI_QUAD_STRIDE 19

struct fake_host {
  int frame;
  int window;
  int width;
  int height;
  int scale;
};
static struct fake_host fake_active;
static struct fake_host *active = &fake_active;

enum scenario {
  CASE_MAP_SCALE,
  CASE_BUSY_REFRESH,
  CASE_NO_SCALE,
  CASE_CLOSE,
  CASE_DESTROY,
  CASE_NATIVE_ERROR
};
static enum scenario current_case;
static int dispatch_calls;
static int present_calls;
static int successful_presents;
static int bootstrap_presents;
static int fixture_presents;
static int bootstrap_mode;
static int field_swap_count;
static int bootstrap_swap_count;
static int fixture_swap_count;
static int metrics_calls;
static int metrics_at_present[32];
static double presented_scales[32];
static double presented_widths[32];
static double successful_scales[32];
static int event_pending;
static int event_kind;
static int busy_once;
static int scale_announced;
static int frame_dispatches_remaining;
static int64_t fake_now_ns;

static sigjmp_buf abort_env;
static volatile sig_atomic_t catch_abort;

static void catch_assertion(int signal_number) {
  (void)signal_number;
  if (catch_abort)
    siglongjmp(abort_env, 1);
  _Exit(127);
}

static int fake_clock_gettime(clockid_t clock_id, struct timespec *out) {
  if (clock_id != CLOCK_MONOTONIC || !out)
    return -1;
  out->tv_sec = (time_t)(fake_now_ns / INT64_C(1000000000));
  out->tv_nsec = (long)(fake_now_ns % INT64_C(1000000000));
  return 0;
}
#define clock_gettime fake_clock_gettime

static int32_t gpui_metrics(int32_t host, int32_t window, double *metrics) {
  assert(host == 42 && window == 19 && metrics);
  ++metrics_calls;
  metrics[0] = active->width;
  metrics[1] = active->height;
  metrics[2] = active->scale;
  return GPUI_OK;
}

static int32_t gpui_present(int32_t host, int32_t window, const double *data,
                            int32_t double_count) {
  assert(host == 42 && window == 19);
  assert(data && double_count == 5 + GPUI_QUAD_STRIDE);
  int slot = present_calls++;
  if (slot < (int)(sizeof(presented_scales) / sizeof(presented_scales[0]))) {
    presented_scales[slot] = data[4];
    presented_widths[slot] = data[2];
    metrics_at_present[slot] = metrics_calls;
  }
  if (current_case == CASE_BUSY_REFRESH && busy_once) {
    busy_once = 0;
    active->frame = 1; /* A different frame is still in flight. */
    frame_dispatches_remaining = 1;
    return GPUI_BUSY;
  }
  assert(data[0] == 0.0 && data[1] == 0.0);
  assert(data[2] == active->width && data[3] == active->height);
  /* This frame is deliberately neutral: scale comes from current metrics,
   * while a fixture's expected scale is checked only after mapping settles. */
  assert(data[4] == (double)active->scale);
  const double *q = data + 5;
  assert(q[2] == active->width && q[3] == active->height);
  assert(q[4] == 255 && q[5] == 255 && q[6] == 255 && q[7] == 255);
  assert(q[8] == 1 && q[11] == 1 && q[14] == 1);
  assert(q[17] == active->width && q[18] == active->height);
  active->frame = 1;
  frame_dispatches_remaining = 2; /* Model a delayed frame callback. */
  successful_scales[successful_presents] = data[4];
  ++successful_presents;
  ++bootstrap_presents;
  if (bootstrap_mode)
    ++bootstrap_swap_count;
  else {
    ++field_swap_count;
    ++fixture_swap_count;
  }
  return GPUI_OK;
}

static int32_t gpui_next(int32_t host, double *out) {
  assert(host == 42 && out);
  if (current_case == CASE_NATIVE_ERROR)
    return -GPUI_NATIVE;
  if (current_case == CASE_CLOSE || current_case == CASE_DESTROY) {
    if (event_pending)
      return 0;
    event_pending = 1;
    memset(out, 0, 10 * sizeof(double));
    out[0] = (double)event_kind;
    out[1] = (double)active->window;
    return 1;
  }
  if (!event_pending)
    return 0;
  event_pending = 0;
  memset(out, 0, 10 * sizeof(double));
  out[0] = (double)event_kind;
  out[1] = (double)active->window;
  return 1;
}

static int32_t gpui_dispatch(int32_t host, int32_t timeout_ms) {
  assert(host == 42 && timeout_ms >= 0 && timeout_ms <= 100);
  ++dispatch_calls;
  if (timeout_ms > 0)
    fake_now_ns += (int64_t)timeout_ms * INT64_C(1000000);
  if (current_case == CASE_MAP_SCALE || current_case == CASE_BUSY_REFRESH) {
    if (!scale_announced) {
      assert(present_calls > 0);
      if (current_case == CASE_MAP_SCALE)
        assert(successful_presents > 0);
      active->scale = 2;
      if (current_case == CASE_BUSY_REFRESH)
        active->width = 800;
      scale_announced = 1;
      event_pending = 1;
      event_kind = 2; /* output/surface mapping changed the effective scale */
    }
  }
  if (active->frame && frame_dispatches_remaining > 0 &&
      --frame_dispatches_remaining == 0)
    active->frame = 0;
  return GPUI_OK;
}
"""


HARNESS_MAIN = r"""
static int failed_case_valid(void) {
  if (current_case == CASE_NO_SCALE)
    return fake_now_ns >= INT64_C(5000000000) && dispatch_calls > 0 ? 0 : 31;
  if (current_case == CASE_CLOSE || current_case == CASE_DESTROY)
    return dispatch_calls == 0 && successful_presents == 0 ? 0 : 32;
  if (current_case == CASE_NATIVE_ERROR)
    return dispatch_calls == 0 && successful_presents == 0 ? 0 : 33;
  return 34;
}

int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  if (!strcmp(argv[1], "map")) {
    current_case = CASE_MAP_SCALE;
  } else if (!strcmp(argv[1], "busy")) {
    current_case = CASE_BUSY_REFRESH;
    busy_once = 1;
  } else if (!strcmp(argv[1], "no-scale")) {
    current_case = CASE_NO_SCALE;
  } else if (!strcmp(argv[1], "close")) {
    current_case = CASE_CLOSE;
    event_kind = 3;
  } else if (!strcmp(argv[1], "destroy")) {
    current_case = CASE_DESTROY;
    event_kind = 4;
  } else if (!strcmp(argv[1], "native-error")) {
    current_case = CASE_NATIVE_ERROR;
  } else {
    return 3;
  }

  active->window = 19;
  active->width = 640;
  active->height = 240;
  active->scale = 1;
  signal(SIGABRT, catch_assertion);
  if (sigsetjmp(abort_env, 1) != 0) {
    catch_abort = 0;
    return failed_case_valid();
  }
  catch_abort = 1;
  bootstrap_field_scale(42, 19, 2);
  /* Keep the complete marked frame-wait block part of this strict harness. */
  await_field_frame(42);
  catch_abort = 0;

  if (current_case != CASE_MAP_SCALE && current_case != CASE_BUSY_REFRESH)
    return 41; /* The helper should have rejected terminal/timeout cases. */
  if (active->scale != 2 || !scale_announced)
    return 42;
  if (current_case == CASE_MAP_SCALE && dispatch_calls < 2)
    return 46; /* A scale event alone cannot satisfy an outstanding frame. */
  if (present_calls < 1 || successful_presents < 1 || fixture_presents != 0)
    return 43;
  /* The first successful frame is a neutral bootstrap frame based on actual
   * current metrics; it is never counted as an accepted fixture replay. */
  if (presented_scales[0] != 1.0 || bootstrap_presents != successful_presents ||
      bootstrap_swap_count != successful_presents || field_swap_count != 0 ||
      fixture_swap_count != 0)
    return 44;
  if (current_case == CASE_BUSY_REFRESH) {
    if (present_calls < 2 || metrics_calls < 2 || presented_scales[1] != 2.0 ||
        successful_scales[0] != 2.0 ||
        presented_widths[0] != 640 || presented_widths[1] != 800 ||
        metrics_at_present[1] <= metrics_at_present[0])
      return 45;
  } else if (successful_scales[0] != 1.0) {
    return 47; /* The neutral first frame uses actual pre-map metrics. */
  }
  return 0;
}
"""


def extract_block(source: str, begin_marker: str, end_marker: str, label: str) -> str:
    if source.count(begin_marker) != 1 or source.count(end_marker) != 1:
        raise AssertionError(f"{label} markers must each appear exactly once")
    begin = source.index(begin_marker)
    end = source.index(end_marker, begin)
    if end <= begin:
        raise AssertionError(f"{label} markers are out of order")
    return source[begin:end + len(end_marker)]


def extract_helpers() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    frame = extract_block(source, FRAME_BEGIN, FRAME_END, "frame-wait")
    bootstrap = extract_block(source, BOOTSTRAP_BEGIN, BOOTSTRAP_END, "scale-bootstrap")
    if "await_field_frame" not in frame or "drain_field_events" not in frame:
        raise AssertionError("marked frame-wait block is incomplete")
    if ("bootstrap_field_scale" not in bootstrap or
            "field_monotonic_ns" not in bootstrap or "drain_field_events" not in bootstrap):
        raise AssertionError("marked scale bootstrap block is incomplete")
    return frame + "\n" + bootstrap


def assert_source_separates_bootstrap_from_fixture_replay() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    main = source[source.index("int main(void)"):]
    bootstrap_at = main.index("bootstrap_field_scale(host, window, target_scale);")
    fixture_loop_at = main.index("for (int i = 0; i < ")
    assert bootstrap_at < fixture_loop_at, "bootstrap must precede fixture replay"
    assert "assert(bootstrap_swap_count == 1);" in main[:fixture_loop_at]
    helper = extract_block(source, BOOTSTRAP_BEGIN, BOOTSTRAP_END, "scale-bootstrap")
    assert "field_swap_count" not in helper and "fixture_swap_count" not in helper
    swap_start = source.index(
        "static EGLBoolean field_verified_swap(EGLDisplay display, EGLSurface surface) {"
    )
    swap_end = source.index("\nstatic ", swap_start + len("static EGLBoolean "))
    swap = source[swap_start:swap_end]
    assert "if (bootstrap_mode)" in swap
    assert "++bootstrap_swap_count;" in swap
    assert swap.index("if (bootstrap_mode)") < swap.index("++field_swap_count;")


class FieldScaleBootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        compiler = os.environ.get("CC", "cc")
        if not shutil.which(compiler):
            raise RuntimeError(f"C compiler not found: {compiler}")
        cls._build_root = REPO.parent / "tmp"
        cls._build_root.mkdir(parents=True, exist_ok=True)
        cls._temporary = tempfile.TemporaryDirectory(
            prefix="field-scale-bootstrap-", dir=cls._build_root
        )
        build_dir = Path(cls._temporary.name)
        harness = build_dir / "field_scale_bootstrap_harness.c"
        executable = build_dir / "field_scale_bootstrap_harness"
        harness.write_text(
            HARNESS_PREFIX + "\n" + extract_helpers() + "\n" + HARNESS_MAIN,
            encoding="utf-8",
        )
        result = subprocess.run(
            [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O0",
             str(harness), "-o", str(executable)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                "failed to compile extracted field-scale helper:\n" + result.stderr
            )
        cls._executable = executable

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temporary"):
            cls._temporary.cleanup()

    def run_case(self, name: str) -> None:
        result = subprocess.run(
            [str(self._executable), name], capture_output=True, text=True, timeout=7
        )
        self.assertEqual(
            result.returncode,
            0,
            f"scenario {name!r} failed with {result.returncode}:\n{result.stderr}",
        )

    def test_scale_mapping_bootstraps_before_fixture_scale_assertion(self) -> None:
        self.run_case("map")

    def test_bootstrap_is_not_counted_as_fixture_qualification(self) -> None:
        assert_source_separates_bootstrap_from_fixture_replay()

    def test_busy_present_rebuilds_buffer_from_fresh_metrics(self) -> None:
        self.run_case("busy")

    def test_missing_scale_obeys_five_second_deadline(self) -> None:
        self.run_case("no-scale")

    def test_close_destroy_and_native_errors_fail(self) -> None:
        for name in ("close", "destroy", "native-error"):
            with self.subTest(event=name):
                self.run_case(name)


if __name__ == "__main__":
    unittest.main()
