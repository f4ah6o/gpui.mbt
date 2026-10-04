from __future__ import annotations

import importlib.util
import sys
import tempfile
import unittest
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "benchmark_ubuntu", ROOT / "scripts" / "benchmark_ubuntu.py"
)
assert SPEC is not None and SPEC.loader is not None
benchmark = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(benchmark)


def sample_line(scale: int, index: int, duration: int, renderer: str = "llvmpipe") -> str:
    return (
        "GPUI_BENCH_SAMPLE scenario=ubuntu.wayland.recovered_present_to_frame.v1 "
        f"platform=ubuntu-wayland scale={scale} sample={index} "
        f"duration_ns={duration} renderer={renderer}"
    )


def report(p50: int, p95: int, runner: str = "runner-a") -> dict:
    return {
        "schema_version": 1,
        "kind": "gpui-native-performance-report",
        "measurement_status": "complete",
        "measurement_provenance": "captured_live",
        "run_id": str(uuid.uuid4()),
        "revision": "a" * 40,
        "worktree_sha256": "b" * 64,
        "worktree_dirty": True,
        "target": "native",
        "environment": {
            "runner_class": runner,
            "os": "Ubuntu-24.04",
            "machine": "x86_64",
            "cpu_model": "Example CPU",
            "renderer": "llvmpipe",
            "compiler": "cc 1.0",
            "moon": "moon 0.10.14",
        },
        "workload": {
            "scenario": benchmark.SCENARIO,
            "timer": "CLOCK_MONOTONIC; renderer recovery through the next Wayland frame callback",
            "scale_factors": [1, 2],
            "samples_per_scale": 30,
            "fixture_sha256": "a" * 64,
        },
        "measurements": [
            {
                "scale": scale,
                "unit": "ns",
                "sample_count": 30,
                "p50": p50,
                "p95": p95,
                "min": p50,
                "max": p95,
                "raw_samples": [p50] * 28 + [p95, p95],
            }
            for scale in (1, 2)
        ],
    }


class BenchmarkParserTests(unittest.TestCase):
    def test_parses_machine_record_and_ignores_regular_log_lines(self) -> None:
        self.assertIsNone(benchmark.parse_sample_line("all tests passed"))
        parsed = benchmark.parse_sample_line(sample_line(2, 4, 987654))
        self.assertEqual(
            parsed,
            {
                "scenario": benchmark.SCENARIO,
                "platform": "ubuntu-wayland",
                "scale": 2,
                "sample": 4,
                "duration_ns": 987654,
                "renderer": "llvmpipe",
            },
        )

    def test_rejects_missing_or_invalid_measurement_fields(self) -> None:
        with self.assertRaisesRegex(ValueError, "missing fields"):
            benchmark.parse_sample_line(
                "GPUI_BENCH_SAMPLE scenario=ubuntu.wayland.present_to_frame.v1 "
                "platform=ubuntu-wayland scale=1 sample=0 duration_ns=1"
            )
        with self.assertRaisesRegex(ValueError, "duration must be positive"):
            benchmark.parse_sample_line(sample_line(1, 0, 0))
        with self.assertRaisesRegex(ValueError, "unexpected scale"):
            benchmark.parse_sample_line(sample_line(3, 0, 1))

    def test_summary_requires_thirty_contiguous_samples_and_reports_nearest_rank_p95(self) -> None:
        rows = [
            benchmark.parse_sample_line(sample_line(scale, index, index + 1))
            for scale in (1, 2)
            for index in range(30)
        ]
        summaries = benchmark.summarize_samples(rows)
        self.assertEqual([item["scale"] for item in summaries], [1, 2])
        self.assertEqual(summaries[0]["sample_count"], 30)
        self.assertEqual(summaries[0]["p95"], 29)
        with self.assertRaisesRegex(ValueError, "at least 30"):
            benchmark.summarize_samples(rows[:-1])

    def test_summary_rejects_duplicate_indices_and_renderer_changes(self) -> None:
        rows = [
            benchmark.parse_sample_line(sample_line(scale, index, 100 + index))
            for scale in (1, 2)
            for index in range(30)
        ]
        with self.assertRaisesRegex(ValueError, "duplicate sample"):
            benchmark.summarize_samples(rows + [rows[0]])
        changed = list(rows)
        changed[0] = benchmark.parse_sample_line(sample_line(1, 0, 100, renderer="softpipe"))
        with self.assertRaisesRegex(ValueError, "renderer changed"):
            benchmark.summarize_samples(changed)

    def test_summary_checks_renderer_consistency_for_one_shot_iterables(self) -> None:
        rows = [
            benchmark.parse_sample_line(
                sample_line(scale, index, 100 + index, renderer="softpipe" if index == 0 else "llvmpipe")
            )
            for scale in (1, 2)
            for index in range(30)
        ]
        with self.assertRaisesRegex(ValueError, "renderer changed"):
            benchmark.summarize_samples(iter(rows))


class BenchmarkCollectorTests(unittest.TestCase):
    def test_stderr_cannot_splice_diagnostics_into_sample_stdout(self) -> None:
        # Reproduce the hosted failure at the file-descriptor level: stderr is
        # written while stdout holds a partial machine record. The collector
        # must parse only stdout and retain diagnostics in its sidecar log.
        child = f"""
import os
for scale in (1, 2):
    for sample in range(30):
        record = (
            "GPUI_BENCH_SAMPLE scenario={benchmark.SCENARIO} "
            f"platform=ubuntu-wayland renderer=llvmpipe scale={{scale}} "
            f"sample={{sample}} duration_ns={{1000 + sample}}\\n"
        ).encode()
        if scale == 2 and sample == 22:
            split = record.index(b"scale=") + 3
            os.write(1, record[:split])
            os.write(2, b"gpui-wayland: read after revents=0x19 failed\\n")
            os.write(1, record[split:])
        else:
            os.write(1, record)
"""
        with tempfile.TemporaryDirectory() as directory:
            diagnostic_path = Path(directory) / "runner.stderr.log"
            samples, status, _, error, captured_diagnostics = benchmark._collect_measurements(
                None,
                30,
                command=[sys.executable, "-c", child],
                diagnostics_path=diagnostic_path,
                forward_output=False,
            )

            self.assertEqual(status, 0)
            self.assertIsNone(error)
            self.assertEqual(len(samples), 60)
            self.assertIn(
                (2, 22),
                {(sample["scale"], sample["sample"]) for sample in samples},
            )
            self.assertEqual(captured_diagnostics, diagnostic_path)
            self.assertIn(
                "gpui-wayland: read after revents=0x19 failed",
                diagnostic_path.read_text(encoding="utf-8"),
            )


class BaselineComparisonTests(unittest.TestCase):
    def test_one_regressing_run_only_requests_confirmation(self) -> None:
        result = benchmark.compare_reports(report(111, 121), report(100, 110))
        self.assertEqual(result["state"], "requires_independent_confirmation")

    def test_two_regressing_runs_fail_the_gate(self) -> None:
        baseline = report(100, 110)
        first = report(111, 121)
        second = report(113, 124)
        result = benchmark.compare_reports(first, baseline, second)
        self.assertEqual(result["state"], "regression_confirmed")
        self.assertIn({"scale": 1, "metric": "p50"}, result["confirmed_metrics"])

    def test_single_run_regression_is_inconclusive_until_confirmed(self) -> None:
        baseline = report(100, 110)
        result = benchmark.compare_reports(report(111, 111), baseline, report(101, 111))
        self.assertEqual(result["state"], "inconclusive")

    def test_confirmation_must_be_an_independent_run_of_same_candidate_tree(self) -> None:
        baseline = report(100, 110)
        current = report(111, 121)
        with self.assertRaisesRegex(ValueError, "distinct run IDs"):
            benchmark.compare_reports(current, baseline, current)
        confirmation = report(112, 122)
        confirmation["worktree_sha256"] = "c" * 64
        with self.assertRaisesRegex(ValueError, "same revision and worktree"):
            benchmark.compare_reports(current, baseline, confirmation)

    def test_report_rejects_replayed_log_and_unknown_runner_provenance(self) -> None:
        baseline = report(100, 110)
        replay = report(101, 111)
        replay["measurement_provenance"] = "replayed_log_unverified"
        with self.assertRaisesRegex(ValueError, "live measurement"):
            benchmark.compare_reports(replay, baseline)
        unknown = report(101, 111)
        unknown["environment"]["renderer"] = "unknown"
        with self.assertRaisesRegex(ValueError, "unusable runner field"):
            benchmark.compare_reports(unknown, baseline)

    def test_report_recomputes_statistics_from_raw_samples(self) -> None:
        baseline = report(100, 110)
        current = report(101, 111)
        current["measurements"][0]["p95"] = 500
        with self.assertRaisesRegex(ValueError, "inconsistent p95"):
            benchmark.compare_reports(current, baseline)

    def test_comparable_runs_must_match_runner_gpu_toolchain_and_workload(self) -> None:
        baseline = report(100, 110)
        for changed in (
            report(100, 110, runner="runner-b"),
            {**report(100, 110), "environment": {**report(100, 110)["environment"], "renderer": "softpipe"}},
            {**report(100, 110), "workload": {**report(100, 110)["workload"], "fixture_sha256": "b" * 64}},
        ):
            with self.subTest(changed=changed):
                with self.assertRaisesRegex(ValueError, "incomparable"):
                    benchmark.compare_reports(changed, baseline)

    def test_baseline_and_confirmation_require_complete_thirty_sample_reports(self) -> None:
        incomplete = report(100, 110)
        incomplete["measurements"][0]["sample_count"] = 29
        incomplete["measurements"][0]["raw_samples"] = [100] * 29
        incomplete["measurements"][0]["p95"] = 100
        incomplete["measurements"][0]["max"] = 100
        with self.assertRaisesRegex(ValueError, "declared sample count"):
            benchmark.compare_reports(report(100, 110), incomplete, report(100, 110))
        not_complete = report(100, 110)
        not_complete["measurement_status"] = "failed"
        with self.assertRaisesRegex(ValueError, "complete measurements"):
            benchmark.compare_reports(report(100, 110), not_complete)


if __name__ == "__main__":
    unittest.main()
