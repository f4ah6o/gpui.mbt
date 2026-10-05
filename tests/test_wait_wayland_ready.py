"""Deterministic tests for the bounded Weston readiness probe.

These tests inject every operating-system interaction and use a fake monotonic
clock. They never launch Weston, connect to a Wayland socket, or sleep in real
time.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path
import contextlib
import io
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
HELPER_PATH = ROOT / "scripts" / "wait_wayland_ready.py"
SPEC = importlib.util.spec_from_file_location("wait_wayland_ready", HELPER_PATH)
assert SPEC is not None and SPEC.loader is not None
helper = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(helper)


class FakeClock:
    def __init__(self) -> None:
        self.now = 0.0
        self.sleeps: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.sleeps.append(seconds)
        self.now += seconds


class WaylandReadinessTests(unittest.TestCase):
    def wait(
        self,
        fake: FakeClock,
        *,
        timeout: float = 30.0,
        alive=None,
        socket_ready=None,
        roundtrip=None,
        diagnostic=None,
    ) -> bool:
        return helper.wait_for_ready(
            123,
            Path("/fake/runtime/wayland-0"),
            timeout,
            clock=fake.monotonic,
            sleep=fake.sleep,
            is_alive=alive or (lambda _pid: True),
            socket_ready=socket_ready or (lambda _path: True),
            roundtrip=roundtrip or (lambda _timeout: True),
            diagnostic=diagnostic,
        )

    def test_socket_created_at_eleven_seconds_is_admitted_only_after_protocol_roundtrip(self) -> None:
        fake = FakeClock()
        probes: list[float] = []

        def socket_ready(_path: Path) -> bool:
            return fake.now >= 11.0

        def roundtrip(timeout: float) -> bool:
            probes.append(timeout)
            return True

        self.assertTrue(self.wait(fake, socket_ready=socket_ready, roundtrip=roundtrip))
        self.assertAlmostEqual(fake.now, 11.0)
        self.assertEqual(len(probes), 1)
        self.assertEqual(probes[0], 1.0)

    def test_socket_can_exist_while_protocol_initialization_retries_until_eleven_seconds(self) -> None:
        fake = FakeClock()
        attempts = 0

        def roundtrip(_timeout: float) -> bool:
            nonlocal attempts
            attempts += 1
            return fake.now >= 11.0

        self.assertTrue(self.wait(fake, roundtrip=roundtrip))
        self.assertAlmostEqual(fake.now, 11.0)
        self.assertGreater(attempts, 200)

    def test_failed_probes_can_later_succeed(self) -> None:
        fake = FakeClock()
        outcomes = iter([False, False, True])
        timeouts: list[float] = []

        def roundtrip(timeout: float) -> bool:
            timeouts.append(timeout)
            return next(outcomes)

        self.assertTrue(self.wait(fake, timeout=1.0, roundtrip=roundtrip))
        self.assertEqual(len(timeouts), 3)
        self.assertTrue(all(timeout <= 1.0 for timeout in timeouts))
        self.assertAlmostEqual(fake.now, 0.1)

    def test_dead_process_is_rejected_before_socket_or_protocol_probes(self) -> None:
        fake = FakeClock()
        calls: list[str] = []

        def record(name: str):
            def call(*_args):
                calls.append(name)
                return True

            return call

        self.assertFalse(
            self.wait(
                fake,
                alive=lambda _pid: False,
                socket_ready=record("socket"),
                roundtrip=record("roundtrip"),
            )
        )
        self.assertEqual(calls, [])

    def test_missing_socket_expires_at_deadline_without_protocol_probe(self) -> None:
        fake = FakeClock()
        probes: list[float] = []
        self.assertFalse(
            self.wait(
                fake,
                timeout=0.2,
                socket_ready=lambda _path: False,
                roundtrip=lambda timeout: probes.append(timeout) or True,
            )
        )
        self.assertEqual(probes, [])
        self.assertAlmostEqual(fake.now, 0.2)
        self.assertTrue(all(0.0 <= duration <= 0.05 for duration in fake.sleeps))

    def test_repeated_protocol_failures_expire_at_deadline(self) -> None:
        fake = FakeClock()
        probes: list[float] = []
        self.assertFalse(
            self.wait(
                fake,
                timeout=0.2,
                roundtrip=lambda timeout: probes.append(timeout) or False,
            )
        )
        self.assertEqual(len(probes), 4)
        self.assertAlmostEqual(fake.now, 0.2)
        for actual, expected in zip(probes, [0.2, 0.15, 0.1, 0.05]):
            self.assertAlmostEqual(actual, expected)

    def test_slow_probe_uses_only_remaining_deadline_budget(self) -> None:
        fake = FakeClock()
        timeouts: list[float] = []

        def roundtrip(timeout: float) -> bool:
            timeouts.append(timeout)
            fake.now += 0.09
            return False

        self.assertFalse(self.wait(fake, timeout=0.12, roundtrip=roundtrip))
        self.assertAlmostEqual(timeouts[0], 0.12)
        self.assertEqual(len(timeouts), 1)
        self.assertEqual(len(fake.sleeps), 1)
        self.assertAlmostEqual(fake.sleeps[0], 0.03)
        self.assertAlmostEqual(fake.now, 0.12)

    def test_successful_probe_finishing_at_deadline_is_rejected(self) -> None:
        fake = FakeClock()

        def roundtrip(_timeout: float) -> bool:
            fake.now = 0.11
            return True

        self.assertFalse(self.wait(fake, timeout=0.1, roundtrip=roundtrip))

    def test_process_exiting_during_successful_protocol_probe_is_rejected(self) -> None:
        fake = FakeClock()
        alive_calls = 0

        def alive(_pid: int) -> bool:
            nonlocal alive_calls
            alive_calls += 1
            return alive_calls == 1

        self.assertFalse(self.wait(fake, alive=alive, roundtrip=lambda _timeout: True))
        self.assertEqual(alive_calls, 2)

    def test_non_monotonic_or_non_finite_clock_is_rejected(self) -> None:
        for values in ([0.0, 0.05, 0.04], [0.0, float("inf")]):
            with self.subTest(values=values):
                instants = iter(values)
                result = helper.wait_for_ready(
                    123,
                    Path("/fake/runtime/wayland-0"),
                    1.0,
                    clock=lambda: next(instants),
                    sleep=lambda _seconds: None,
                    is_alive=lambda _pid: True,
                    socket_ready=lambda _path: False,
                    roundtrip=lambda _timeout: self.fail("no socket probe expected"),
                )
                self.assertFalse(result)

    def test_failure_diagnostics_distinguish_observed_exit_and_timeout_stage(self) -> None:
        for kwargs, expected in (
            ({"alive": lambda _pid: False}, "compositor exited"),
            ({"socket_ready": lambda _path: False}, "timeout: socket unavailable"),
            ({"roundtrip": lambda _timeout: False}, "timeout: protocol roundtrip failed"),
        ):
            with self.subTest(expected=expected):
                diagnostics: list[str] = []
                self.assertFalse(self.wait(
                    FakeClock(), timeout=0.1, diagnostic=diagnostics.append, **kwargs,
                ))
                self.assertEqual(len(diagnostics), 1)
                self.assertIn(expected, diagnostics[0])

    def test_invalid_pid_or_deadline_is_rejected(self) -> None:
        for pid, timeout in ((0, 1.0), (123, 0.0), (123, float("inf"))):
            with self.subTest(pid=pid, timeout=timeout):
                with self.assertRaises(ValueError):
                    helper.wait_for_ready(pid, Path("/fake/socket"), timeout)


class ReadinessIntegrationGuardTests(unittest.TestCase):
    def test_ubuntu_script_uses_bounded_helper_instead_of_a_fixed_poll_loop(self) -> None:
        source = (ROOT / "scripts" / "test_ubuntu.sh").read_text(encoding="utf-8")
        self.assertIn("wait_wayland_ready.py", source)
        self.assertRegex(source, r"python3\s+scripts/wait_wayland_ready\.py")
        self.assertNotRegex(source, r"seq\s+1\s+200|_attempt[^\n]*200")
        self.assertNotIn("sleep .25", source)

    def test_missing_protocol_probe_fails_cli_without_starting_wait(self) -> None:
        stderr = io.StringIO()
        with mock.patch.object(helper.shutil, "which", return_value=None), \
                mock.patch.object(helper, "wait_for_ready") as wait, \
                mock.patch.object(helper.sys, "argv", [
                    "wait_wayland_ready.py", "--pid", "123", "--socket", "/fake/socket",
                ]), contextlib.redirect_stderr(stderr):
            self.assertEqual(helper.main(), 1)
        wait.assert_not_called()
        self.assertIn("requires wayland-info protocol probe", stderr.getvalue())

    def test_protocol_probe_adapter_preserves_exit_and_timeout_failure(self) -> None:
        with mock.patch.object(helper.subprocess, "run") as run:
            run.return_value.returncode = 0
            self.assertTrue(helper.protocol_roundtrip(0.75))
            self.assertEqual(run.call_args.kwargs["timeout"], 0.75)
            run.return_value.returncode = 1
            self.assertFalse(helper.protocol_roundtrip(0.75))
            run.side_effect = helper.subprocess.TimeoutExpired("wayland-info", 0.75)
            self.assertFalse(helper.protocol_roundtrip(0.75))

    def test_cli_requires_wayland_info_by_default(self) -> None:
        source = HELPER_PATH.read_text(encoding="utf-8")
        self.assertIn("shutil.which(\"wayland-info\")", source)
        self.assertRegex(source, r"requires wayland-info protocol probe")


if __name__ == "__main__":
    unittest.main()
