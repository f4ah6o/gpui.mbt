from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

import scripts.capture_wayland_client_trace as trace_capture
from scripts.capture_wayland_client_trace import run_with_trace, sanitize_protocol_line
from scripts.run_ubuntu_benchmark_with_trace import (
    DIAGNOSTIC_TIMEOUT_SECONDS,
    BENCHMARK_TIMEOUT_SECONDS,
    main as benchmark_main,
    run_benchmark_with_failure_trace,
)


class WaylandTraceCaptureTests(unittest.TestCase):
    def test_trace_is_off_by_default_and_does_not_set_wayland_debug(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            trace = Path(temp) / "trace.log"
            env = os.environ.copy()
            env.pop("GPUI_WAYLAND_TRACE", None)
            env["WAYLAND_DEBUG"] = "client"
            code = run_with_trace(
                [
                    sys.executable,
                    "-c",
                    "import os, sys; "
                    "sys.exit(0 if os.getenv('WAYLAND_DEBUG') is None else 3)",
                ],
                trace,
                env=env,
            )
            self.assertEqual(code, 0)
            self.assertFalse(trace.exists())

    def test_sanitizer_keeps_lifecycle_headers_but_no_arguments_or_input_interfaces(self) -> None:
        surface = sanitize_protocol_line(
            b'[10.250] -> xdg_toplevel@7.set_title("not user input")\n'
        )
        self.assertEqual(surface, b"[10.250] -> xdg_toplevel@7.set_title\n")
        padded = sanitize_protocol_line(
            b"[  934.846]  -> wl_display@1.get_registry(new id wl_registry@2)\n"
        )
        self.assertEqual(padded, b"[  934.846] -> wl_display@1.get_registry\n")
        self.assertIsNone(sanitize_protocol_line(b"[10.260] wl_keyboard@4.key(1, 2, 3, 4)\n"))
        self.assertIsNone(
            sanitize_protocol_line(b'[10.270] wl_data_offer@8.offer("text/plain")\n')
        )

    def test_trace_file_is_byte_bounded_and_stdout_is_not_captured(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            trace = Path(temp) / "trace.log"
            code = run_with_trace(
                [
                    sys.executable,
                    "-c",
                    "import sys; "
                    "assert __import__('os').getenv('WAYLAND_DEBUG') == 'client'; "
                    "print('SYNTHETIC_CLIENT_STDOUT_ONLY'); "
                    "[print(f'[1.{i:03d}] -> wl_surface@7.commit()', file=sys.stderr) "
                    "for i in range(40)]; "
                    "sys.exit(23)",
                ],
                trace,
                max_bytes=64,
                env={"GPUI_WAYLAND_TRACE": "1"},
            )
            self.assertEqual(code, 23)
            data = trace.read_bytes()
            self.assertLessEqual(len(data), 64)
            self.assertNotIn(b"SYNTHETIC_CLIENT_STDOUT_ONLY", data)
            self.assertNotIn(b"not user input", data)
            self.assertTrue(data.endswith(b"wl_surface@7.commit\n"))

    def test_oversized_raw_line_is_discarded_with_fixed_size_pipe_reads(self) -> None:
        class FakePipe:
            def __init__(self, data: bytes):
                self.data = data
                self.offset = 0
                self.read_sizes: list[int] = []

            def read1(self, size: int) -> bytes:
                self.read_sizes.append(size)
                chunk = self.data[self.offset : self.offset + size]
                self.offset += len(chunk)
                return chunk

            def __enter__(self) -> FakePipe:
                return self

            def __exit__(self, *_: object) -> None:
                return None

        class FakeProcess:
            def __init__(self, stderr: FakePipe):
                self.stderr = stderr

            def wait(self) -> int:
                return 23

        long_line = b"x" * (trace_capture.MAX_PROTOCOL_LINE_BYTES * 4) + b"\n"
        valid_line = b"[1.234] -> wl_surface@7.commit()\n"
        pipe = FakePipe(long_line + valid_line)
        process = FakeProcess(pipe)
        with tempfile.TemporaryDirectory() as temp:
            trace = Path(temp) / "trace.log"
            original_sanitizer = trace_capture.sanitize_protocol_line
            with (
                patch("scripts.capture_wayland_client_trace.subprocess.Popen", return_value=process),
                patch(
                    "scripts.capture_wayland_client_trace.sanitize_protocol_line",
                    wraps=original_sanitizer,
                ) as sanitizer,
            ):
                code = run_with_trace(
                    ["synthetic-client"],
                    trace,
                    max_bytes=64,
                    env={"GPUI_WAYLAND_TRACE": "1"},
                )

            self.assertEqual(code, 23)
            self.assertTrue(pipe.read_sizes)
            self.assertEqual(set(pipe.read_sizes), {trace_capture.READ_CHUNK_BYTES})
            self.assertTrue(sanitizer.call_args_list)
            self.assertLessEqual(
                max(len(call.args[0]) for call in sanitizer.call_args_list),
                trace_capture.MAX_PROTOCOL_LINE_BYTES,
            )
            self.assertEqual(trace.read_bytes(), b"[1.234] -> wl_surface@7.commit\n")

    def test_trace_write_failure_does_not_replace_test_status(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            parent_file = Path(temp) / "not-a-directory"
            parent_file.write_text("occupied", encoding="utf-8")
            trace = parent_file / "trace.log"
            code = run_with_trace(
                [sys.executable, "-c", "import sys; sys.exit(29)"],
                trace,
                env={"GPUI_WAYLAND_TRACE": "1"},
            )
            self.assertEqual(code, 29)


class FailureDiagnosticRunnerTests(unittest.TestCase):
    def test_successful_benchmark_skips_trace_and_unsets_instrumentation(self) -> None:
        run = Mock(return_value=subprocess.CompletedProcess([], 0))
        status = run_benchmark_with_failure_trace(
            ["benchmark"], ["diagnostic"], env={"GPUI_WAYLAND_TRACE": "1", "WAYLAND_DEBUG": "1"},
            run_process=run,
        )
        self.assertEqual(status, 0)
        run.assert_called_once()
        self.assertNotIn("GPUI_WAYLAND_TRACE", run.call_args.kwargs["env"])
        self.assertNotIn("GPUI_UBUNTU_E2E_STAGE_TRACE", run.call_args.kwargs["env"])
        self.assertNotIn("WAYLAND_DEBUG", run.call_args.kwargs["env"])

    def test_one_failing_trace_cannot_mask_primary_benchmark_status(self) -> None:
        run = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 17),
                subprocess.CompletedProcess([], 91),
            ]
        )
        status = run_benchmark_with_failure_trace(
            ["benchmark"], ["diagnostic"], env={"PATH": "/bin"}, run_process=run
        )
        self.assertEqual(status, 17)
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0].args[0], ["benchmark"])
        self.assertEqual(run.call_args_list[1].args[0], ["diagnostic"])
        self.assertEqual(run.call_args_list[1].kwargs["env"]["GPUI_WAYLAND_TRACE"], "1")

    def test_trace_launch_error_cannot_mask_primary_benchmark_status(self) -> None:
        run = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 31),
                FileNotFoundError("synthetic diagnostic launch failure"),
            ]
        )
        status = run_benchmark_with_failure_trace(
            ["benchmark"], ["diagnostic"], env={}, run_process=run
        )
        self.assertEqual(status, 31)
        self.assertEqual(run.call_count, 2)

    def test_signal_terminated_benchmark_uses_shell_exit_code(self) -> None:
        run = Mock(
            side_effect=[
                subprocess.CompletedProcess([], -11),
                subprocess.CompletedProcess([], 0),
            ]
        )
        status = run_benchmark_with_failure_trace(
            ["benchmark"], ["diagnostic"], env={}, run_process=run
        )
        self.assertEqual(status, 139)


class UnifiedFailureDiagnosticTests(unittest.TestCase):
    def test_mocked_failure_runs_one_bounded_both_scale_diagnostic_and_keeps_original_exit(self) -> None:
        run = Mock(
            side_effect=[
                subprocess.CompletedProcess([], 17),
                subprocess.CompletedProcess([], 91),
            ]
        )
        def invoke_bounded_commands(benchmark_command, diagnostic_command, *, cwd):
            return run_benchmark_with_failure_trace(
                benchmark_command,
                diagnostic_command,
                cwd=cwd,
                env={"PATH": "/usr/bin"},
                run_process=run,
            )

        with patch(
            "scripts.run_ubuntu_benchmark_with_trace.run_benchmark_with_failure_trace",
            side_effect=invoke_bounded_commands,
        ):
            status = benchmark_main()

        self.assertEqual(status, 17)
        self.assertEqual(run.call_count, 2)
        benchmark_command = run.call_args_list[0].args[0]
        diagnostic_command = run.call_args_list[1].args[0]
        timeout_prefix = ["timeout", "--kill-after=10s"]
        self.assertEqual(benchmark_command[:2], timeout_prefix)
        self.assertEqual(benchmark_command[2], f"{BENCHMARK_TIMEOUT_SECONDS}s")
        self.assertTrue(any(str(part).endswith("scripts/benchmark_ubuntu.py") for part in benchmark_command))
        self.assertEqual(diagnostic_command[:2], timeout_prefix)
        self.assertEqual(diagnostic_command[2], f"{DIAGNOSTIC_TIMEOUT_SECONDS}s")
        self.assertTrue(any(str(part).endswith("scripts/capture_ubuntu_wayland_trace.sh") for part in diagnostic_command))
        self.assertEqual(run.call_args_list[1].kwargs["env"]["GPUI_WAYLAND_TRACE"], "1")
        self.assertEqual(
            run.call_args_list[1].kwargs["env"]["GPUI_UBUNTU_E2E_STAGE_TRACE"], "1"
        )
        self.assertNotIn("GPUI_WAYLAND_TRACE", run.call_args_list[0].kwargs["env"])
        self.assertNotIn("GPUI_UBUNTU_E2E_STAGE_TRACE", run.call_args_list[0].kwargs["env"])

    def test_workflow_has_one_diagnostic_orchestrator_and_unconditional_artifact_upload(self) -> None:
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ubuntu-native.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.count("scripts/run_ubuntu_benchmark_with_trace.py"), 1)
        self.assertNotIn("Capture bounded first-frame trace after E2E failure", workflow)
        self.assertNotIn("steps.native-e2e-timing.outcome", workflow)
        self.assertEqual(workflow.count("actions/upload-artifact@"), 1)
        artifact = workflow[workflow.index("actions/upload-artifact@"):]
        self.assertIn("if: always()", artifact)
        self.assertIn("_build/ubuntu-e2e/", artifact)
        self.assertIn("_build/ubuntu-bench/", artifact)

    def test_one_diagnostic_script_traces_both_scales_with_finite_limits_and_filtered_records(self) -> None:
        root = Path(__file__).resolve().parents[1]
        script = (root / "scripts/capture_ubuntu_wayland_trace.sh").read_text(encoding="utf-8")
        self.assertIn("for scale in 1 2; do", script)
        self.assertIn('--scale="$scale"', script)
        self.assertIn("timeout --kill-after=5s 120s moon test ubuntu", script)
        self.assertIn("timeout --kill-after=5s 170s", script)
        self.assertIn("--max-bytes 262144", script)
        self.assertIn("first-frame-stage-trace-scale-$scale.log", script)
        self.assertIn("diagnostic-status-scale-$scale.txt", script)
        self.assertIn("GPUI_UBUNTU_E2E_STAGE_TRACE=1", script)
        self.assertIn("GPUI_WAYLAND_TRACE_FILE=.* bytes=[0-9]+", script)



if __name__ == "__main__":
    unittest.main()
