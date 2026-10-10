from __future__ import annotations

import json
import io
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch

from scripts.compare_ubuntu_revisions import (
    COMMON_HARNESS_FILES,
    EXPECTED_BASELINE_SHA,
    EXPECTED_BRANCH,
    HEAD_LOG_BYTES,
    PlannedAttempt,
    _bounded_copy,
    _classify_attempt,
    MAX_STREAM_LOG_BYTES,
    SCALES,
    _measurement_is_valid,
    _StreamCapture,
    _install_common_harness,
    build_attempt_plan,
    execute_comparison,
    run_attempt,
    summarize_results,
    validate_invocation,
)


COMPARISON_DRIVER_FIXTURE = '''#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh scripts/prepare_ubuntu.sh
_build/ubuntu-e2e/backend-test --clipboard-unit
sh scripts/test_ubuntu_ingress.sh
runtime=$(mktemp -d)
compositor_pid=
cleanup() {
  if [ -n "$compositor_pid" ]; then kill "$compositor_pid" 2>/dev/null || true; wait "$compositor_pid" 2>/dev/null || true; fi
  rm -rf "$runtime"
}
trap cleanup EXIT HUP INT TERM
for scale in 1 2; do
  weston --backend=headless-backend.so --use-gl --shell=kiosk-shell.so &
  if ! python3 scripts/wait_wayland_ready.py; then exit 1; fi
  set +e
  GPUI_UBUNTU_E2E=1 timeout 120 moon test ubuntu --target native
  moon_status=$?
  set -e
  GPUI_UBUNTU_SMOKE=1 timeout 30 moon run examples/ubuntu
  GPUI_UBUNTU_BUTTON_SMOKE=1 timeout 30 moon run examples/ubuntu_button
  GPUI_FIELD_E2E=1 timeout 120 moon test examples/linux_text_field
  GPUI_FIELD_SMOKE=1 timeout 30 moon run examples/linux_text_field
  GPUI_FIELD_FIXTURES_DIR=fixtures GPUI_FIELD_CAPTURE=frame.ppm GPUI_EXPECT_SCALE="$scale" timeout 120 _build/ubuntu-e2e/field-gpu-test
  GPUI_UBUNTU_CAPTURE=frame.ppm GPUI_EXPECT_SCALE="$scale" timeout 120 _build/ubuntu-e2e/backend-test "$compositor_pid"
  wait "$compositor_pid" || true
  compositor_pid=
done
'''


class RevisionComparisonPlanTests(unittest.TestCase):
    def test_pair_with_one_not_run_attempt_is_incomplete_not_attributed(self) -> None:
        summary = summarize_results(
            [
                {"pair": 1, "scale": 1, "revision": "baseline", "status": "passed"},
                {
                    "pair": 1,
                    "scale": 1,
                    "revision": "candidate",
                    "status": "not_run_budget_exhausted",
                },
            ]
        )
        pair = next(
            row
            for row in summary["pairs"]
            if row["pair"] == 1 and row["scale"] == 1
        )
        self.assertEqual(pair["outcome"], "incomplete")
        self.assertEqual(pair["baseline"], "passed")
        self.assertEqual(pair["candidate"], "not_run_budget_exhausted")

    def test_pair_with_both_not_run_attempts_is_incomplete_not_double_failure(self) -> None:
        summary = summarize_results(
            [
                {
                    "pair": 1,
                    "scale": 2,
                    "revision": revision,
                    "status": "not_run_setup_failed",
                }
                for revision in ("baseline", "candidate")
            ]
        )
        pair = next(
            row
            for row in summary["pairs"]
            if row["pair"] == 1 and row["scale"] == 2
        )
        self.assertEqual(pair["outcome"], "incomplete")
        self.assertEqual(pair["baseline"], "not_run_setup_failed")
        self.assertEqual(pair["candidate"], "not_run_setup_failed")

    @unittest.skipUnless(
        os.name == "posix" and sys.platform.startswith("linux") and shutil.which("timeout"),
        "the process-group timeout regression uses Linux /proc and GNU timeout",
    )
    def test_attempt_timeout_kills_foreground_timeout_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            script = root / "scripts/test_ubuntu.sh"
            script.parent.mkdir(parents=True)
            leader_file = root / "leader-pid"
            child_file = root / "child-pids"
            script.write_text(
                f'''#!/bin/sh
printf '%s\\n' "$$" > "{leader_file}"
timeout --foreground --kill-after=1s 30s sh -c 'sleep 30 & child=$!; pgid=$(ps -o pgid= -p "$child" | tr -d " "); printf "%s %s\\n" "$child" "$pgid" > "{child_file}"; wait'
''',
                encoding="utf-8",
            )
            script.chmod(0o755)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            subprocess.run(
                ["git", "-C", str(root), "config", "user.name", "Comparison Test"],
                check=True,
            )
            subprocess.run(
                ["git", "-C", str(root), "config", "user.email", "comparison@example.invalid"],
                check=True,
            )
            subprocess.run(["git", "-C", str(root), "add", "scripts/test_ubuntu.sh"], check=True)
            subprocess.run(
                ["git", "-C", str(root), "commit", "-qm", "test comparison timeout cleanup"],
                check=True,
            )
            attempt_dir = root / "attempt"
            child_pid = child_process_group = None
            try:
                with (
                    patch("scripts.compare_ubuntu_revisions.ATTEMPT_TIMEOUT_SECONDS", 1),
                    patch("scripts.compare_ubuntu_revisions.KILL_GRACE_SECONDS", 0.2),
                ):
                    result = run_attempt(
                        PlannedAttempt(1, 1, 1, "baseline"),
                        root,
                        attempt_dir,
                        deadline=time.monotonic() + 5,
                    )
                self.assertEqual(result["status"], "timed_out")
                leader_pid = int(leader_file.read_text(encoding="utf-8"))
                child_pid, child_process_group = map(
                    int, child_file.read_text(encoding="utf-8").split()
                )
                self.assertEqual(child_process_group, leader_pid)

                def alive_non_zombie(pid: int) -> bool:
                    try:
                        stat_text = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
                    except OSError:
                        return False
                    fields_after_comm = stat_text.rsplit(")", 1)[1].split()
                    return bool(fields_after_comm) and fields_after_comm[0] != "Z"

                cleanup_deadline = time.monotonic() + 2
                while alive_non_zombie(child_pid) and time.monotonic() < cleanup_deadline:
                    time.sleep(0.02)
                self.assertFalse(
                    alive_non_zombie(child_pid),
                    "nested timeout child survived attempt cleanup",
                )
            finally:
                if (
                    child_process_group is not None
                    and child_process_group > 1
                    and child_process_group != os.getpgrp()
                ):
                    try:
                        os.killpg(child_process_group, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_workflow_is_scoped_to_initial_open_or_exact_head_dispatch(self) -> None:
        root = Path(__file__).resolve().parents[1]
        workflow = (root / ".github/workflows/ubuntu-native.yml").read_text(encoding="utf-8")
        comparison = workflow.split("  paired-weston-comparison:", maxsplit=1)[1]
        self.assertIn("github.event.action == 'opened'", comparison)
        self.assertIn("github.event.pull_request.head.repo.full_name == 'gpui-mbt/gpui.mbt'", comparison)
        self.assertIn("github.event.pull_request.head.ref == 'codex/linux-six-pr-integration-20261011'", comparison)
        self.assertIn("github.event_name == 'workflow_dispatch'", comparison)
        self.assertIn("github.ref_name == 'codex/linux-six-pr-integration-20261011'", comparison)
        self.assertIn("ref: ${{ github.event.pull_request.head.sha || github.sha }}", comparison)
        self.assertIn("BASELINE_SHA: 9c70225ddcee70385b64ee24f207ec0755b2b49f", comparison)
        self.assertIn("timeout-minutes: 70", comparison)
        self.assertIn("compare_ubuntu_revisions.py", comparison)
        self.assertIn("if: always()", comparison)
        self.assertIn("ubuntu-weston-paired-comparison", comparison)
        self.assertNotIn("inputs.candidate_sha", workflow)
        headless_job = workflow.split("  linux-text-headless:", maxsplit=1)[1].split(
            "  wayland-gles:", maxsplit=1
        )[0]
        wayland_job = workflow.split("  wayland-gles:", maxsplit=1)[1].split(
            "  paired-weston-comparison:", maxsplit=1
        )[0]
        self.assertIn("github.event_name != 'workflow_dispatch'", headless_job)
        self.assertIn("github.event_name != 'workflow_dispatch'", wayland_job)

    def test_six_fixed_pairs_cover_each_scale_and_alternate_order(self) -> None:
        plan = build_attempt_plan()
        self.assertEqual(len(plan), 24)
        for scale in SCALES:
            self.assertEqual(
                sum(row.scale == scale and row.revision == "baseline" for row in plan), 6
            )
            self.assertEqual(
                sum(row.scale == scale and row.revision == "candidate" for row in plan), 6
            )
            first_revisions = []
            for pair in range(1, 7):
                pair_rows = [row for row in plan if row.pair == pair and row.scale == scale]
                self.assertEqual(len(pair_rows), 2)
                self.assertEqual({row.revision for row in pair_rows}, {"baseline", "candidate"})
                first_revisions.append(pair_rows[0].revision)
            for before, after in zip(first_revisions, first_revisions[1:]):
                self.assertNotEqual(before, after)

    def test_initial_open_and_exact_manual_dispatch_are_the_only_supported_triggers(self) -> None:
        candidate = "a" * 40
        validate_invocation(
            event_name="pull_request",
            event_action="opened",
            ref_name="123/merge",
            github_sha=candidate,
            candidate_sha=candidate,
            baseline_sha=EXPECTED_BASELINE_SHA,
            pull_request_head_ref=EXPECTED_BRANCH,
            pull_request_head_repo="gpui-mbt/gpui.mbt",
        )
        validate_invocation(
            event_name="workflow_dispatch",
            event_action="",
            ref_name=EXPECTED_BRANCH,
            github_sha=candidate,
            candidate_sha=candidate,
            baseline_sha=EXPECTED_BASELINE_SHA,
        )
        invalid = [
            {"event_name": "pull_request", "event_action": "synchronize", "pull_request_head_ref": EXPECTED_BRANCH},
            {"event_name": "pull_request", "event_action": "opened", "pull_request_head_ref": "other-branch"},
            {"event_name": "pull_request", "event_action": "opened", "pull_request_head_repo": "untrusted-fork/gpui.mbt"},
            {"event_name": "workflow_dispatch", "event_action": "", "ref_name": "main"},
        ]
        for changes in invalid:
            args = {
                "event_name": "pull_request",
                "event_action": "opened",
                "ref_name": EXPECTED_BRANCH,
                "github_sha": candidate,
                "candidate_sha": candidate,
                "baseline_sha": EXPECTED_BASELINE_SHA,
                "pull_request_head_ref": EXPECTED_BRANCH,
                "pull_request_head_repo": "gpui-mbt/gpui.mbt",
            }
            args.update(changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                validate_invocation(**args)
        with self.assertRaises(ValueError):
            validate_invocation(
                event_name="workflow_dispatch",
                event_action="",
                ref_name=EXPECTED_BRANCH,
                github_sha=candidate,
                candidate_sha="b" * 40,
                baseline_sha=EXPECTED_BASELINE_SHA,
            )

    def test_stream_capture_is_bounded_and_counts_samples_before_truncation(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            target = Path(temp) / "stdout.log"
            capture = _StreamCapture(target)
            capture.append(
                b"GPUI_COMPARISON_STAGE id=ubuntu_native_tests scale=1\n"
                b"GPUI_WESTON_STATUS stage=backend_disconnect exit=139\n"
                b"GPUI_BENCH_SAMPLE scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
                b"platform=ubuntu-wayland scale=1 sample=0 duration_ns=1 renderer=llvmpipe\n"
                b"GPUI_BENCH_COMPLETE "
                b"scenario=ubuntu.wayland.recovered_present_to_frame.v1 samples_per_scale=30\n"
            )
            capture.append(b"z" * (MAX_STREAM_LOG_BYTES + HEAD_LOG_BYTES))
            result = capture.finish()
            self.assertTrue(result["truncated"])
            self.assertLessEqual(result["bytes_retained"], MAX_STREAM_LOG_BYTES)
            self.assertEqual(result["sample_counts_by_scale"], {"1": 1})
            self.assertIn(b"comparison log truncated", target.read_bytes())
            self.assertEqual(
                result["last_stage"], {"id": "ubuntu_native_tests", "scale": 1}
            )
            self.assertEqual(
                result["weston_exit_observations"],
                [{"stage": "backend_disconnect", "exit": 139}],
            )

    def test_measurement_requires_one_complete_unique_thirty_sample_scale(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            capture = _StreamCapture(Path(temp) / "stdout.log")
            for sample in range(30):
                capture.append(
                    (
                        "GPUI_BENCH_SAMPLE "
                        "scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
                        f"platform=ubuntu-wayland scale=2 sample={sample} "
                        "duration_ns=1000 renderer=llvmpipe\n"
                    ).encode()
                )
            capture.append(
                b"GPUI_BENCH_COMPLETE "
                b"scenario=ubuntu.wayland.recovered_present_to_frame.v1 samples_per_scale=30\n"
            )
            metadata = capture.finish()
            self.assertTrue(_measurement_is_valid(metadata, 2))
            self.assertFalse(_measurement_is_valid(metadata, 1))

            duplicate = _StreamCapture(Path(temp) / "duplicate.log")
            for sample in range(30):
                duplicate.append(
                    (
                        "GPUI_BENCH_SAMPLE "
                        "scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
                        f"platform=ubuntu-wayland scale=2 sample={sample} "
                        "duration_ns=1000 renderer=llvmpipe\n"
                    ).encode()
                )
            duplicate.append(
                b"GPUI_BENCH_SAMPLE scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
                b"platform=ubuntu-wayland scale=2 sample=0 duration_ns=1000 renderer=llvmpipe\n"
            )
            duplicate.append(
                b"GPUI_BENCH_COMPLETE "
                b"scenario=ubuntu.wayland.recovered_present_to_frame.v1 samples_per_scale=30\n"
            )
            self.assertFalse(_measurement_is_valid(duplicate.finish(), 2))

    def test_weston_log_copy_keeps_both_ends_and_full_source_digest_under_cap(self) -> None:
        import hashlib

        with tempfile.TemporaryDirectory() as temp:
            source = Path(temp) / "source.log"
            target = Path(temp) / "artifact/weston.log"
            source_bytes = b"A" * 512 + b"FAILURE_TAIL" * 20
            source.write_bytes(source_bytes)
            metadata = _bounded_copy(source, target, 128)
            self.assertTrue(metadata["truncated"])
            self.assertLessEqual(metadata["retained_bytes"], 128)
            self.assertEqual(metadata["source_sha256"], hashlib.sha256(source_bytes).hexdigest())
            self.assertIn(b"[Weston log truncated", target.read_bytes())
            self.assertIn(b"FAILURE_TAIL", target.read_bytes())

    def test_crash_status_is_not_hidden_by_zero_driver_exit_or_expected_sigterm(self) -> None:
        common = {
            "timed_out": False,
            "spawn_error": None,
            "returncode": 0,
            "measurement_valid": True,
        }
        self.assertEqual(
            _classify_attempt(**common, weston_exit_statuses=[143]), "passed"
        )
        self.assertEqual(
            _classify_attempt(**common, weston_exit_statuses=[139]), "failed"
        )
        self.assertEqual(
            _classify_attempt(**{**common, "measurement_valid": False}, weston_exit_statuses=[]),
            "invalid_measurement",
        )

    def test_harness_overlay_is_byte_identical_for_both_revisions(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            baseline = Path(temp) / "baseline"
            candidate = Path(temp) / "candidate"
            for root in (baseline, candidate):
                for relative in COMMON_HARNESS_FILES:
                    path = root / relative
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text("common fixture\n", encoding="utf-8")
            (baseline / "scripts/test_ubuntu.sh").write_text(
                COMPARISON_DRIVER_FIXTURE, encoding="utf-8"
            )
            (baseline / "ubuntu").mkdir(parents=True)
            (candidate / "ubuntu").mkdir(parents=True)
            (baseline / "ubuntu/backend_wbtest.mbt").write_text("baseline test\n", encoding="utf-8")
            (candidate / "ubuntu/output_snapshot_wbtest.mbt").write_text(
                "candidate-only test\n", encoding="utf-8"
            )
            (baseline / "examples/ubuntu_button").mkdir(parents=True)
            (candidate / "examples/ubuntu_button").mkdir(parents=True)
            (baseline / "examples/ubuntu_button/accessibility_adapter_wbtest.mbt").write_text(
                "baseline button test\n", encoding="utf-8"
            )
            (candidate / "examples/ubuntu_button/new_adapter_wbtest.mbt").write_text(
                "candidate-only button test\n", encoding="utf-8"
            )
            (baseline / "examples/ubuntu_button/fixture").mkdir(parents=True)
            (candidate / "examples/ubuntu_button/fixture").mkdir(parents=True)
            (baseline / "examples/ubuntu_button/fixture/fixture_wbtest.mbt").write_text(
                "baseline fixture test\n", encoding="utf-8"
            )
            (candidate / "examples/ubuntu_button/fixture/new_fixture_wbtest.mbt").write_text(
                "candidate-only fixture test\n", encoding="utf-8"
            )
            digest = _install_common_harness(baseline, candidate)
            baseline_bytes = (baseline / "scripts/test_ubuntu.sh").read_bytes()
            candidate_bytes = (candidate / "scripts/test_ubuntu.sh").read_bytes()
            self.assertEqual(baseline_bytes, candidate_bytes)
            self.assertEqual(len(digest["comparison_driver_instrumentation_sha256"]), 64)
            self.assertEqual(digest["timeout_commands_foregrounded"], 7)
            syntax = subprocess.run(
                ["sh", "-n"], input=baseline_bytes, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, check=False,
            )
            self.assertEqual(syntax.returncode, 0, syntax.stderr.decode(errors="replace"))
            self.assertIn(b"GPUI_UBUNTU_ONLY_SCALE", baseline_bytes)
            self.assertIn(b"for scale in $ubuntu_scales; do", baseline_bytes)
            self.assertIn(b"comparison_stage backend_disconnect", baseline_bytes)
            self.assertIn(b"GPUI_WESTON_STATUS stage=backend_disconnect exit=%s", baseline_bytes)
            self.assertIn(b"GPUI_WESTON_CLEANUP_STATUS", baseline_bytes)
            self.assertEqual(
                baseline_bytes.count(b"timeout --foreground --kill-after=5s"), 7
            )
            self.assertNotRegex(
                baseline_bytes.decode("utf-8"), r"(?<!\S)timeout [0-9]"
            )
            self.assertEqual(
                (candidate / "ubuntu/backend_wbtest.mbt").read_text(encoding="utf-8"),
                "baseline test\n",
            )
            self.assertFalse((candidate / "ubuntu/output_snapshot_wbtest.mbt").exists())
            self.assertEqual(
                (candidate / "examples/ubuntu_button/accessibility_adapter_wbtest.mbt").read_text(
                    encoding="utf-8"
                ),
                "baseline button test\n",
            )
            self.assertFalse((candidate / "examples/ubuntu_button/new_adapter_wbtest.mbt").exists())
            self.assertEqual(
                (candidate / "examples/ubuntu_button/fixture/fixture_wbtest.mbt").read_text(
                    encoding="utf-8"
                ),
                "baseline fixture test\n",
            )
            self.assertFalse(
                (candidate / "examples/ubuntu_button/fixture/new_fixture_wbtest.mbt").exists()
            )

    def test_fixed_plan_continues_after_mocked_failure_without_any_extra_attempt(self) -> None:
        baseline_sha = "b" * 40
        candidate_sha = "c" * 40
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "output"
            calls = []

            def fake_git(args, *, cwd):
                if args[:2] == ["rev-parse", "--verify"]:
                    return args[2].split("^{", 1)[0]
                if len(args) == 2 and args[0] == "rev-parse" and args[1].endswith("^{tree}"):
                    return "d" * 40
                if args == ["rev-parse", "HEAD"]:
                    return baseline_sha if cwd.name == "baseline" else candidate_sha
                raise AssertionError(f"unexpected git call: {args}")

            def fake_add(path, sha):
                path.mkdir(parents=True)
                for relative in COMMON_HARNESS_FILES:
                    driver = path / relative
                    driver.parent.mkdir(parents=True, exist_ok=True)
                    driver.write_text("common fixture\n", encoding="utf-8")
                driver = path / "scripts/test_ubuntu.sh"
                driver.write_text(
                    COMPARISON_DRIVER_FIXTURE,
                    encoding="utf-8",
                )

            def fake_run(attempt, worktree, attempt_dir, *, deadline):
                calls.append(attempt)
                failed = attempt.revision == "candidate" and attempt.pair == 1 and attempt.scale == 1
                return {
                    "ordinal": attempt.ordinal,
                    "pair": attempt.pair,
                    "scale": attempt.scale,
                    "revision": attempt.revision,
                    "status": "failed" if failed else "passed",
                    "weston_exit_statuses": [139] if failed else [],
                    "measurement_valid": not failed,
                }

            with (
                patch("scripts.compare_ubuntu_revisions._git", side_effect=fake_git),
                patch("scripts.compare_ubuntu_revisions._git_is_ancestor", return_value=True),
                patch("scripts.compare_ubuntu_revisions._worktree_add", side_effect=fake_add),
                patch("scripts.compare_ubuntu_revisions._worktree_remove"),
                patch("scripts.compare_ubuntu_revisions.collect_environment_metadata", return_value={}),
                redirect_stdout(io.StringIO()),
            ):
                status = execute_comparison(
                    baseline_sha=baseline_sha,
                    candidate_sha=candidate_sha,
                    output_dir=output,
                    budget_seconds=100,
                    attempt_runner=fake_run,
                )
            self.assertEqual(status, 1)
            self.assertEqual(len(calls), 24)
            summary = json.loads((output / "comparison.json").read_text(encoding="utf-8"))
            self.assertEqual(summary["diagnostic_replays"], 0)
            self.assertEqual(summary["attempts_completed"], 24)
            self.assertEqual(summary["attempts_incomplete"], 0)
            self.assertEqual(
                summary["comparison"]["by_revision_and_scale"]["candidate-scale-1"][
                    "weston_exit_139_observations"
                ],
                1,
            )
            self.assertEqual(
                summary["comparison"]["pairs"][0]["outcome"], "candidate_failed_only"
            )

            def no_budget_run(attempt, worktree, attempt_dir, *, deadline):
                return {
                    "ordinal": attempt.ordinal,
                    "pair": attempt.pair,
                    "scale": attempt.scale,
                    "revision": attempt.revision,
                    "status": "not_run_budget_exhausted",
                }

            no_budget_output = Path(temp) / "no-budget"
            with (
                patch("scripts.compare_ubuntu_revisions._git", side_effect=fake_git),
                patch("scripts.compare_ubuntu_revisions._git_is_ancestor", return_value=True),
                patch("scripts.compare_ubuntu_revisions._worktree_add", side_effect=fake_add),
                patch("scripts.compare_ubuntu_revisions._worktree_remove"),
                patch("scripts.compare_ubuntu_revisions.collect_environment_metadata", return_value={}),
                redirect_stdout(io.StringIO()),
            ):
                no_budget_status = execute_comparison(
                    baseline_sha=baseline_sha,
                    candidate_sha=candidate_sha,
                    output_dir=no_budget_output,
                    budget_seconds=0,
                    attempt_runner=no_budget_run,
                )
            no_budget_summary = json.loads(
                (no_budget_output / "comparison.json").read_text(encoding="utf-8")
            )
            self.assertEqual(no_budget_status, 1)
            self.assertEqual(no_budget_summary["status"], "incomplete")
            self.assertEqual(no_budget_summary["attempts_completed"], 0)
            self.assertEqual(no_budget_summary["attempts_incomplete"], 24)
            self.assertTrue(
                all(
                    result["status"] == "not_run_budget_exhausted"
                    for result in no_budget_summary["results"]
                )
            )


if __name__ == "__main__":
    unittest.main()
