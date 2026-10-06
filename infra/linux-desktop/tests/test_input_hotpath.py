import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("input_hotpath", HERE / "input-hotpath.py")
profile = importlib.util.module_from_spec(spec)
spec.loader.exec_module(profile)


def fixture(active=True):
    rows = [{"kind": "result", "instrumented": active, "cycles": 32, "checksum": 1,
             "fingerprint": 42, "workload_ns": 100000, "clock_resolution_ns": 1,
             "observed_min_tick_ns": 20, "backward_reads": 0, "invalid_clocks": 0,
             "dropped_samples": 0}]
    if active:
        for label, count in profile.EXPECTED_CALLS.items():
            rows += [{"kind": "sample", "label": label, "ns": 123} for _ in range(count)]
            rows.append({"kind": "aggregate", "label": label, "calls": count,
                         "total_ns": count * 123, "min_ns": 123, "max_ns": 123,
                         "p50_estimate_ns": 123, "p95_estimate_ns": 123,
                         "total_saturated": False})
        rows.append({"kind": "calibration", "calls": 4096, "span_total_ns": 100,
                     "full_ns": 200, "wrapper_full_ns": 300})
    return rows


def report():
    labels = {label: {"median_ns": 1000, "mad_ns": 10} for label in profile.EXPECTED_CALLS}
    return {"ok": True, "environment": {"cpu": "fixture"}, "workload_sha256": "fixture",
            "hotpath_runtime": {"ns": "fixture"}, "behavior_signature": [1, 42],
            "runs": [{"result": {"clock_resolution_ns": 1}} for _ in range(14)],
            "statistics": {"labels": labels, "empty_raw_wrapper_ns_per_call": {"median_ns": 100}}}


def policy_compare(current, baseline, tolerance):
    # Isolate threshold arithmetic; retained-evidence tests below exercise the
    # real validator and never replace it.
    current["producer_sha256"] = baseline["producer_sha256"] = "fixture"
    with patch.object(profile, "validate_evidence", side_effect=lambda value, _: value):
        return profile.compare_baseline(current, baseline, tolerance, Path("current"), Path("baseline"))


def retained_fixture(root):
    root.mkdir(parents=True, exist_ok=True)
    source = root / "source"
    source.mkdir()
    (source / "fixture.mbt").write_text("fixture source")
    entries = {"fixture.mbt": {"kind": "file", "sha256": profile.digest(source / "fixture.mbt")}}
    lock = {"runtime_files": {name: profile.hashlib.sha256(name.encode()).hexdigest()
                             for name in ["moon.mod", "src/moon.pkg", "src/hotpath.mbt", "src/nanoseconds.mbt"]}}
    for name in lock["runtime_files"]:
        path = root / "hotpath" / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(name)
    (root / "workload").mkdir()
    for name in profile.WORKLOAD_FILES:
        (root / "workload" / name).write_bytes((profile.WORKLOAD / name).read_bytes())
    (root / "build").mkdir()
    (root / "build/fixture.exe").write_bytes(b"fixture executable identity")
    before = {"commit": "a" * 40, "tree": "b" * 40, "tracked_patch_sha256": "c" * 64,
              "input_files_sha256": profile.source_manifest_digest(entries), "status": ""}
    value = {"schema_version": 2, "ok": True, "source_stable": True, "behavior_equal": True,
             "scope": profile.SCOPE, "excluded": profile.EXCLUDED,
             "producer_sha256": profile.digest(HERE / "input-hotpath.py"), "repeats": 7,
             "source_before": before, "source_after": dict(before), "hotpath_lock": lock,
             "hotpath_runtime": lock["runtime_files"], "workload_sha256": profile.workload_digest(),
             "binary_relative_path": "build/fixture.exe", "binary_sha256": profile.digest(root / "build/fixture.exe"),
             "environment": {"fixture": True}, "runs": [], "behavior_signature": [1, 42]}
    (root / "staging-manifest.json").write_text(json.dumps({"source_files": entries, "source_snapshot": before,
        "compiler_path_override": str(root / "source/script/linux_text_cc.py"), "environment": value["environment"]}))
    for index in range(7):
        for active in [False, True]:
            rows = fixture(active)
            name = str(index) + ("-on.jsonl" if active else "-off.jsonl")
            (root / name).write_text("".join(json.dumps(row) + "\n" for row in rows))
            value["runs"].append({"index": index, "instrumented": active, "raw_file": name,
                                  "rows": rows, "result": profile.validate_run(rows, active)})
    value["statistics"] = profile.summarize(value["runs"])
    value["artifact_hashes"] = {name: profile.digest(root / name) for name in
                                ["staging-manifest.json", "build/fixture.exe"] + [row["raw_file"] for row in value["runs"]]}
    return value, lock


class InputHotpathTests(unittest.TestCase):
    def test_exact_counts_raw_aggregate_and_disabled(self):
        self.assertEqual(sum(profile.EXPECTED_CALLS.values()), 800)
        self.assertEqual(profile.validate_run(fixture(), True)["checksum"], 1)
        profile.validate_run(fixture(False), False)

    def test_missing_span_fails(self):
        rows = fixture()
        rows.pop(1)
        with self.assertRaisesRegex(RuntimeError, "counts"):
            profile.validate_run(rows, True)

    def test_wrong_totals_duplicate_aggregates_and_saturation_fail(self):
        for change in ["total_ns", "total_saturated", "label"]:
            rows = fixture()
            aggregate = next(row for row in rows if row["kind"] == "aggregate")
            aggregate[change] = {"total_ns": 1, "total_saturated": True, "label": "private text"}[change]
            with self.assertRaisesRegex(RuntimeError, "aggregates"):
                profile.validate_run(rows, True)

    def test_clock_failures_do_not_pass(self):
        for name in ["backward_reads", "invalid_clocks", "dropped_samples"]:
            rows = fixture()
            rows[0][name] = 1
            with self.assertRaisesRegex(RuntimeError, "clock"):
                profile.validate_run(rows, True)

    def test_raw_units_and_content_fields_are_strict(self):
        for value in [-1, 1.5, 9223372036854775808]:
            rows = fixture()
            rows[1]["ns"] = value
            with self.assertRaisesRegex(RuntimeError, "raw sample|numeric metric"):
                profile.validate_run(rows, True)
        rows = fixture()
        rows[0]["document"] = "never export"
        with self.assertRaisesRegex(RuntimeError, "content"):
            profile.validate_run(rows, True)

    def test_disabled_has_zero_hotpath_rows(self):
        rows = fixture(False)
        rows.append({"kind": "sample", "label": "input.handle", "ns": 1})
        with self.assertRaisesRegex(RuntimeError, "disabled"):
            profile.validate_run(rows, False)

    def test_calibration_required(self):
        rows = fixture()[:-1]
        with self.assertRaisesRegex(RuntimeError, "calibration"):
            profile.validate_run(rows, True)

    def test_baseline_requires_explicit_finite_tolerance_and_compatibility(self):
        current = report()
        for tolerance in [None, 0, -1, float("nan"), float("inf")]:
            with self.assertRaisesRegex(RuntimeError, "tolerance"):
                policy_compare(current, report(), tolerance)
        for field in ["environment", "workload_sha256", "hotpath_runtime", "behavior_signature"]:
            baseline = report()
            baseline[field] = "different"
            with self.assertRaisesRegex(RuntimeError, "incompatible"):
                policy_compare(current, baseline, .1)

    def test_noise_and_calibration_allowance_and_clear_regression(self):
        current, baseline = report(), report()
        current["statistics"]["labels"]["scene.paint"]["median_ns"] = 1119
        result = policy_compare(current, baseline, .05)
        self.assertEqual(result["regressions"], [])
        current["statistics"]["labels"]["scene.paint"]["median_ns"] = 1121
        self.assertEqual(policy_compare(current, baseline, .05)["regressions"], ["scene.paint"])

    def test_baseline_nan_or_missing_statistics_cannot_pass(self):
        for value in [float("nan"), float("inf"), -1, "100"]:
            baseline = report()
            baseline["statistics"]["labels"]["scene.paint"]["median_ns"] = value
            with self.assertRaisesRegex(RuntimeError, "invalid statistics"):
                policy_compare(report(), baseline, .1)
        baseline = report()
        baseline["statistics"]["labels"].pop("scene.paint")
        with self.assertRaisesRegex(RuntimeError, "invalid statistics"):
            policy_compare(report(), baseline, .1)

    def test_runtime_pin_rejects_changed_library(self):
        lock = json.loads((HERE / "hotpath.lock.json").read_text())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in lock["runtime_files"]:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("changed")
            with self.assertRaisesRegex(RuntimeError, "match lock"):
                profile.verify_hotpath(root)

    def test_stale_profile_is_rejected_before_any_timing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            expected = json.loads((HERE / "profile.lock.json").read_text())
            marker = root / "installed.json"
            marker.write_text(json.dumps({"lock_sha256": "stale", "profile": expected}))
            with self.assertRaisesRegex(RuntimeError, "stale"):
                profile.verify_profile(root)
            marker.write_text(json.dumps({"lock_sha256": profile.digest(HERE / "profile.lock.json"), "profile": expected}))
            self.assertEqual(profile.verify_profile(root)[0], root)
            expected["packages"] = []
            marker.write_text(json.dumps({"lock_sha256": profile.digest(HERE / "profile.lock.json"), "profile": expected}))
            with self.assertRaisesRegex(RuntimeError, "stale"):
                profile.verify_profile(root)
        with self.assertRaisesRegex(RuntimeError, "GPUI_DESKTOP_ROOT"):
            profile.verify_profile(None)

    def test_retained_evidence_requires_typed_success_pairs_and_recomputed_stats(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            valid, lock = retained_fixture(root)
            with patch.object(profile, "runtime_lock", return_value=lock):
                self.assertIs(profile.validate_evidence(valid, root), valid)
                for key, value in [("ok", "forged truthy success"), ("schema_version", True),
                                   ("source_stable", 1), ("repeats", True), ("runs", [{}] * 14)]:
                    broken = copy.deepcopy(valid)
                    broken[key] = value
                    with self.subTest(key=key), self.assertRaises(RuntimeError):
                        profile.validate_evidence(broken, root)
                broken = copy.deepcopy(valid)
                broken["runs"][0]["index"] = 1
                with self.assertRaisesRegex(RuntimeError, "distinct"):
                    profile.validate_evidence(broken, root)
                broken = copy.deepcopy(valid)
                broken["statistics"]["labels"]["scene.paint"]["median_ns"] = 999999
                with self.assertRaisesRegex(RuntimeError, "recomputed"):
                    profile.validate_evidence(broken, root)
                broken = copy.deepcopy(valid)
                broken["statistics"]["observed_overhead_ratio"] = float("nan")
                with self.assertRaises(RuntimeError):
                    profile.validate_evidence(broken, root)

    def test_retained_stale_source_environment_binary_workload_and_missing_raw_fail(self):
        cases = ["source", "environment", "binary", "workload", "raw", "declared_source", "declared_binary",
                 "extra_source", "extra_workload", "extra_runtime"]
        for case in cases:
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                value, lock = retained_fixture(root)
                if case == "source": (root / "source/fixture.mbt").write_text("changed")
                elif case == "environment": value["environment"] = {"fixture": "stale compiler"}
                elif case == "binary": (root / "build/fixture.exe").write_text("stale binary")
                elif case == "workload": (root / "workload/main.mbt").write_text("stale workload")
                elif case == "raw": (root / "0-on.jsonl").unlink()
                elif case == "declared_source":
                    value["source_before"]["input_files_sha256"] = "d" * 64
                    value["source_after"] = dict(value["source_before"])
                elif case == "declared_binary": value["binary_sha256"] = "e" * 64
                elif case == "extra_source": (root / "source/extra.mbt").write_text("undeclared input")
                elif case == "extra_workload": (root / "workload/extra.mbt").write_text("undeclared input")
                elif case == "extra_runtime": (root / "hotpath/src/extra.mbt").write_text("undeclared input")
                with patch.object(profile, "runtime_lock", return_value=lock), self.subTest(case=case), self.assertRaises(RuntimeError):
                    profile.validate_evidence(value, root)

    def test_comparison_cannot_accept_forged_success_without_retained_evidence(self):
        broken = report()
        broken.update(ok="forged truthy success", runs=[{}] * 14)
        with self.assertRaisesRegex(RuntimeError, "retained"):
            profile.compare_baseline(report(), broken, .1)
        with tempfile.TemporaryDirectory() as temporary:
            current_dir, baseline_dir = Path(temporary) / "current", Path(temporary) / "baseline"
            current, lock = retained_fixture(current_dir)
            baseline, _ = retained_fixture(baseline_dir)
            with patch.object(profile, "runtime_lock", return_value=lock):
                self.assertEqual(profile.compare_baseline(current, baseline, .1, current_dir, baseline_dir)["regressions"], [])
                baseline["ok"] = "forged truthy success"
                baseline["runs"] = [{}] * 14
                with self.assertRaisesRegex(RuntimeError, "typed"):
                    profile.compare_baseline(current, baseline, .1, current_dir, baseline_dir)

    def test_effective_compiler_discovery_and_flags_identity_are_bound(self):
        env = {"PATH": "/usr/bin:/bin", "GPUI_LINUX_TEXT_CC": "cc", "PKG_CONFIG": "pkg-config",
               "CPPFLAGS": "-DFIXTURE=1", "CFLAGS": "-O2", "LDFLAGS": "-Wl,--as-needed"}
        with patch.object(profile.subprocess, "check_output", return_value="fixture-version\n"), \
             patch.object(profile.subprocess, "run"):
            original = profile.native_build_identity(env)
            for key, value in [("GPUI_LINUX_TEXT_CC", "/usr/bin/cc"), ("PKG_CONFIG", "/usr/bin/pkg-config"),
                               ("CPPFLAGS", "-DFIXTURE=2"), ("CFLAGS", "-O3"), ("LDFLAGS", "-Wl,--no-as-needed")]:
                changed = dict(env, **{key: value})
                self.assertNotEqual(profile.native_build_identity(changed), original, key)
        for key in ["GPUI_LINUX_TEXT_CC", "PKG_CONFIG"]:
            with self.assertRaisesRegex(RuntimeError, "wrapper commands"):
                profile.native_build_identity(dict(env, **{key: "ccache cc"}))

    def test_native_monotonic_clock_resolution_and_overflow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "clock-test.c"
            source.write_text('#include "' + str(HERE.parents[1] / "testing/input_hotpath/clock.c") + '"\n'
                              '#include <assert.h>\nint main(void) {\n'
                              'assert(checked_ns((struct timespec){0, 1}) == 1);\n'
                              'assert(checked_ns((struct timespec){-1, 0}) == -1);\n'
                              'assert(checked_ns((struct timespec){0, 1000000000}) == -1);\n'
                              'assert(checked_ns((struct timespec){9223372036LL, 854775807}) == INT64_MAX);\n'
                              'assert(checked_ns((struct timespec){9223372036LL, 854775808}) == -1);\n'
                              'assert(gpui_hotpath_resolution_ns() > 0);\n'
                              'int64_t previous = gpui_hotpath_now_ns(); assert(previous >= 0);\n'
                              'for(int i=0;i<10000;i++) { int64_t now=gpui_hotpath_now_ns(); assert(now>=previous); previous=now; }\n'
                              'return 0; }\n')
            binary = root / "clock-test"
            subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(source), "-o", str(binary)], check=True, capture_output=True)
            subprocess.run([str(binary)], check=True)


if __name__ == "__main__":
    unittest.main()
