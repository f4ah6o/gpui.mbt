"""Mechanical regression tests for the hosted field-frame wait helper.

The C helper is extracted verbatim from field_gpu_test.c and run against tiny
deterministic host/clock stubs. These tests need no compositor, GPU, socket, or
third-party Python package.
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
BEGIN_MARKER = "/* FIELD_FRAME_WAIT_BEGIN"
END_MARKER = "/* FIELD_FRAME_WAIT_END */"


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

struct fake_host {
  int frame;
  int window;
};
static struct fake_host fake_active;
static struct fake_host *active = &fake_active;

enum scenario {
  CASE_DRAIN,
  CASE_MANY_EVENTS,
  CASE_NO_FRAME,
  CASE_CLOSE,
  CASE_DESTROY,
  CASE_NEXT_ERROR,
  CASE_DISPATCH_ERROR
};
static enum scenario current_case;
static int queued_events;
static int initial_events;
static int event_kind;
static int events_consumed;
static int terminal_events_seen;
static int next_error_seen;
static int dispatch_error_seen;
static int dispatch_calls;
static int positive_dispatches;
static int positive_dispatches_while_queued;
static int positive_timeout_total_ms;
static int64_t fake_now_ns;
static int frame_due_ms;

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

static int32_t gpui_next(int32_t host, double *out) {
  (void)host;
  if (current_case == CASE_NEXT_ERROR) {
    next_error_seen = 1;
    return -77;
  }
  if (queued_events <= 0)
    return 0;
  --queued_events;
  ++events_consumed;
  out[0] = (double)event_kind;
  out[1] = (double)active->window;
  if (event_kind == 3 || event_kind == 4)
    ++terminal_events_seen;
  return 1;
}

static int32_t gpui_dispatch(int32_t host, int32_t timeout_ms) {
  (void)host;
  ++dispatch_calls;
  if (queued_events > 0 && timeout_ms > 0)
    ++positive_dispatches_while_queued;

  if (timeout_ms > 0 && queued_events == 0) {
    ++positive_dispatches;
    positive_timeout_total_ms += timeout_ms;
    if (current_case == CASE_DISPATCH_ERROR) {
      dispatch_error_seen = 1;
      return -88;
    }
    if (current_case == CASE_NO_FRAME) {
      fake_now_ns += (int64_t)timeout_ms * INT64_C(1000000);
      return GPUI_OK;
    }
    int64_t until_frame_ns = (int64_t)frame_due_ms * INT64_C(1000000) - fake_now_ns;
    int64_t requested_ns = (int64_t)timeout_ms * INT64_C(1000000);
    fake_now_ns += requested_ns < until_frame_ns ? requested_ns : until_frame_ns;
    if (fake_now_ns >= (int64_t)frame_due_ms * INT64_C(1000000))
      active->frame = 0;
    return GPUI_OK;
  }

  /* Model gpui_dispatch's nonblocking behavior when the native queue is busy. */
  fake_now_ns += INT64_C(1000000);
  return GPUI_OK;
}
"""


HARNESS_MAIN = r"""
static int validate_expected_failure(void) {
  switch (current_case) {
  case CASE_NO_FRAME:
    return fake_now_ns >= INT64_C(5000000000) &&
                   positive_timeout_total_ms >= 5000 && positive_dispatches >= 50
               ? 0
               : 31;
  case CASE_CLOSE:
  case CASE_DESTROY:
    return terminal_events_seen == 1 && queued_events == 0 && dispatch_calls == 0
               ? 0
               : 32;
  case CASE_NEXT_ERROR:
    return next_error_seen && dispatch_calls == 0 ? 0 : 33;
  case CASE_DISPATCH_ERROR:
    return dispatch_error_seen && dispatch_calls == 1 && positive_dispatches == 1
               ? 0
               : 34;
  default:
    return 35;
  }
}

int main(int argc, char **argv) {
  if (argc != 2)
    return 2;
  if (strcmp(argv[1], "drain") == 0) {
    current_case = CASE_DRAIN;
    initial_events = queued_events = 7;
    event_kind = 2;
    frame_due_ms = 25;
  } else if (strcmp(argv[1], "many") == 0) {
    current_case = CASE_MANY_EVENTS;
    initial_events = queued_events = 96;
    event_kind = 2;
    frame_due_ms = 250;
  } else if (strcmp(argv[1], "timeout") == 0) {
    current_case = CASE_NO_FRAME;
  } else if (strcmp(argv[1], "close") == 0) {
    current_case = CASE_CLOSE;
    initial_events = queued_events = 1;
    event_kind = 3;
  } else if (strcmp(argv[1], "destroy") == 0) {
    current_case = CASE_DESTROY;
    initial_events = queued_events = 1;
    event_kind = 4;
  } else if (strcmp(argv[1], "next-error") == 0) {
    current_case = CASE_NEXT_ERROR;
  } else if (strcmp(argv[1], "dispatch-error") == 0) {
    current_case = CASE_DISPATCH_ERROR;
  } else {
    return 3;
  }

  active->frame = 1;
  active->window = 19;
  signal(SIGABRT, catch_assertion);
  if (sigsetjmp(abort_env, 1) != 0) {
    catch_abort = 0;
    return validate_expected_failure();
  }
  catch_abort = 1;
  await_field_frame(42);
  catch_abort = 0;

  if (current_case != CASE_DRAIN && current_case != CASE_MANY_EVENTS)
    return 41; /* Failure cases must reject the unexpected condition. */
  if (active->frame || queued_events != 0 || events_consumed != initial_events)
    return 42;
  if (positive_dispatches_while_queued != 0 || positive_dispatches < 1)
    return 43;
  if (current_case == CASE_DRAIN && initial_events != 7)
    return 44;
  if (current_case == CASE_MANY_EVENTS &&
      (initial_events <= 50 || dispatch_calls > 4 || fake_now_ns < INT64_C(250000000)))
    return 45;
  return 0;
}
"""


def extract_helper() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(BEGIN_MARKER) != 1 or source.count(END_MARKER) != 1:
        raise AssertionError("field-frame helper markers must each appear exactly once")
    begin = source.index(BEGIN_MARKER)
    end = source.index(END_MARKER, begin)
    if end <= begin:
        raise AssertionError("field-frame helper markers are out of order")
    block = source[begin:end + len(END_MARKER)]
    if "await_field_frame" not in block or "drain_field_events" not in block:
        raise AssertionError("marked block does not contain the complete wait helper")
    return block


class FieldFrameWaitTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        compiler = os.environ.get("CC", "cc")
        if not shutil.which(compiler):
            raise RuntimeError(f"C compiler not found: {compiler}")
        cls._build_root = REPO.parent / "tmp"
        cls._build_root.mkdir(parents=True, exist_ok=True)
        cls._temporary = tempfile.TemporaryDirectory(
            prefix="field-frame-wait-", dir=cls._build_root
        )
        build_dir = Path(cls._temporary.name)
        harness = build_dir / "field_frame_wait_harness.c"
        executable = build_dir / "field_frame_wait_harness"
        harness.write_text(
            HARNESS_PREFIX + "\n" + extract_helper() + "\n" + HARNESS_MAIN,
            encoding="utf-8",
        )
        result = subprocess.run(
            [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O0", str(harness), "-o", str(executable)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                "failed to compile extracted field-frame helper:\n" + result.stderr
            )
        cls._executable = executable

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temporary"):
            cls._temporary.cleanup()

    def run_case(self, name: str) -> None:
        result = subprocess.run(
            [str(self._executable), name], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(
            result.returncode,
            0,
            f"scenario {name!r} failed with {result.returncode}:\n{result.stderr}",
        )

    def test_queued_events_are_drained_before_blocking_dispatch(self) -> None:
        self.run_case("drain")

    def test_delayed_frame_completes_after_more_than_fifty_queued_events(self) -> None:
        self.run_case("many")

    def test_missing_frame_obeys_five_second_monotonic_deadline(self) -> None:
        self.run_case("timeout")

    def test_unexpected_close_and_destroy_fail(self) -> None:
        for name in ("close", "destroy"):
            with self.subTest(event=name):
                self.run_case(name)

    def test_negative_next_and_dispatch_errors_fail(self) -> None:
        for name in ("next-error", "dispatch-error"):
            with self.subTest(error=name):
                self.run_case(name)


if __name__ == "__main__":
    unittest.main()
