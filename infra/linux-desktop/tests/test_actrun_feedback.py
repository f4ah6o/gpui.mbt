import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("feedback", HERE / "actrun-feedback.py")
feedback = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feedback)


class ActrunFeedbackTests(unittest.TestCase):
    def test_runner_identity_and_bytes_are_both_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "dist").mkdir()
            cli = root / "dist/actrun.js"
            cli.write_bytes(b"runner")
            (root / "package.json").write_text(json.dumps({"name": "@mizchi/actrun", "version": "0.32.0"}))
            lock = {"name": "@mizchi/actrun", "version": "0.32.0",
                    "cli_sha256": hashlib.sha256(b"runner").hexdigest()}
            real_read = Path.read_text
            def read(path, *args, **kwargs):
                return json.dumps(lock) if path.name == "actrun-runner.lock.json" else real_read(path, *args, **kwargs)
            with patch.object(Path, "read_text", read):
                self.assertEqual(feedback.verify_runner(cli)[0], cli)
                cli.write_bytes(b"tampered")
                with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                    feedback.verify_runner(cli)
                (root / "package.json").write_text(json.dumps({"name": "other", "version": "0.32.0"}))
                with self.assertRaisesRegex(RuntimeError, "name/version"):
                    feedback.verify_runner(cli)

    def test_workflow_cleanup_preserves_existing_workflows_even_on_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            directory = repo / ".github/workflows"
            directory.mkdir(parents=True)
            hosted = directory / "ubuntu-native.yml"
            hosted.write_text("preserve this")
            with self.assertRaisesRegex(RuntimeError, "interrupted"):
                with feedback.temporary_workflow(repo) as generated:
                    self.assertTrue(generated.exists())
                    self.assertEqual(generated.parent, directory)
                    raise RuntimeError("interrupted")
            self.assertFalse(generated.exists())
            self.assertEqual(hosted.read_text(), "preserve this")
            self.assertEqual(list(directory.iterdir()), [hosted])

    def test_workflow_directory_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            (repo / ".github").mkdir(parents=True)
            target = root / "other"
            target.mkdir()
            (repo / ".github/workflows").symlink_to(target, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, "own .github"):
                with feedback.temporary_workflow(repo):
                    self.fail("a symlink must not be used")

    def test_state_must_stay_outside_checkout(self):
        repo = Path("/tmp/example-checkout")
        with self.assertRaisesRegex(RuntimeError, "outside"):
            feedback.external_path(repo / "state", repo)
        self.assertEqual(feedback.external_path("/tmp/example-profile", repo), Path("/tmp/example-profile"))

    def test_profile_failure_never_runs_actrun_and_is_recorded(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "actrun.js"
            runner.write_bytes(b"unused")
            snapshot = {"commit": "frozen", "tree": "tree", "status": ""}
            with patch.object(feedback, "source_snapshot", return_value=snapshot), \
                 patch.object(feedback.subprocess, "run", return_value=type("Result", (), {"returncode": 1})()) as run:
                self.assertEqual(feedback.execute(root / "profile", runner, root / "output"), 1)
            self.assertEqual(run.call_count, 1)
            self.assertIn("doctor", run.call_args.args[0])
            summary = json.loads((root / "output/summary.json").read_text())
            self.assertFalse(summary["ok"])
            self.assertNotIn("actrun_seconds", summary)
            self.assertTrue(summary["source_stable"])

    def test_template_keeps_exact_headless_workload_and_no_setup_skips(self):
        text = (HERE / "actrun-feedback.yml").read_text()
        self.assertIn("run: sh scripts/test_linux_text.sh", text)
        self.assertNotIn("uses:", text)
        self.assertNotIn("sleep", text)
        self.assertNotIn("sudo", text)
        self.assertFalse((HERE.parents[1] / ".github/workflows/actrun-feedback.yml").exists())

    def test_source_snapshot_detects_untracked_content_changes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            def git(*args):
                subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
            git("init", "--quiet")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (repo / "moon.mod").write_text("fixture")
            git("add", "moon.mod")
            git("commit", "--quiet", "-m", "Fixture")
            pending = repo / "untracked.mbt"
            pending.write_text("before")
            before = feedback.source_snapshot(repo)
            pending.write_text("after")
            after = feedback.source_snapshot(repo)
            self.assertEqual(before["status"], after["status"])
            self.assertNotEqual(before["input_files_sha256"], after["input_files_sha256"])

    def test_temporary_workflow_does_not_invalidate_candidate_source_after_cleanup(self):
        spec = importlib.util.spec_from_file_location("gate_build_manifest", HERE / "build_manifest.py")
        manifests = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(manifests)
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            directory = repo / ".github/workflows"
            directory.mkdir(parents=True)
            def git(*args):
                subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)
            git("init", "--quiet")
            git("config", "user.name", "Fixture")
            git("config", "user.email", "fixture@example.invalid")
            (repo / ".gitignore").write_text(".github/workflows/_local-actrun-feedback-*.yml\n")
            (repo / "input.mbt").write_text("real input")
            git("add", ".gitignore", "input.mbt")
            git("commit", "--quiet", "-m", "Fixture")
            before = manifests.capture_source(repo)
            with feedback.temporary_workflow(repo, "acceptance"):
                self.assertEqual(manifests.capture_source(repo), before)
                candidate_source = manifests.capture_source(repo)
            self.assertEqual(manifests.capture_source(repo), candidate_source)
            (repo / "new-input.mbt").write_text("real new input")
            self.assertNotEqual(manifests.capture_source(repo), candidate_source)

    def test_mode_templates_compose_real_checks_without_hosted_setup(self):
        fast = feedback.workflow_text("fast")
        wider = feedback.workflow_text("acceptance")
        for mode in ("fast", "acceptance"):
            text = feedback.workflow_text(mode)
            self.assertIn("run: |", text)
            self.assertIn("sh scripts/test_linux_text.sh", text)
            self.assertIn("python3 scripts/check_contracts.py", text)
            self.assertNotIn("uses:", text)
            self.assertNotIn("sudo", text)
            self.assertNotIn("npm install", text)
        self.assertIn("moon test text controls/text_field platform ubuntu examples/linux_text_field --target native --deny-warn", fast)
        self.assertNotIn("case_runner.py", fast)
        self.assertNotIn("--target all", fast)
        self.assertIn("moon test --target all --deny-warn", wider)
        self.assertIn("doctor --build-only --input-e2e --ipc", wider)
        self.assertIn("--manifest-output", wider)
        self.assertIn("case_runner.py --candidate", wider)
        self.assertIn("--all", wider)

    def test_invalid_native_catalog_still_records_failed_acceptance(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "runner.js"
            runner.write_bytes(b"fixture")
            with patch.object(feedback, "source_snapshot", return_value={"commit": "frozen"}), \
                 patch.object(feedback, "native_coverage", side_effect=RuntimeError("invalid native catalog")), \
                 patch.object(feedback.subprocess, "run") as run:
                self.assertEqual(feedback.execute(root / "profile", runner, root / "output", "acceptance"), 1)
            run.assert_not_called()
            report = json.loads((root / "output/summary.json").read_text())
            self.assertFalse(report["ok"])
            self.assertEqual(report["error"], "invalid native catalog")
            self.assertEqual(report["doctor_status"], "not-run")

    def test_default_mode_is_fast_and_headless_remains_explicit(self):
        with patch.object(feedback, "verify_runner", return_value=(Path("/tmp/runner"), {})), \
             patch.object(feedback, "execute", return_value=0) as execute:
            self.assertEqual(feedback.main(["--root", "/tmp/gate-profile"]), 0)
            self.assertEqual(execute.call_args.args[-1], "fast")
            self.assertEqual(feedback.main(["--root", "/tmp/gate-profile", "--mode", "headless"]), 0)
            self.assertEqual(execute.call_args.args[-1], "headless")

    def test_missing_failed_and_skipped_tasks_cannot_be_passed(self):
        tasks = [{"id": "linux-local/contracts", "status": "success", "code": 0},
                 {"id": "linux-local/infra", "status": "failed", "code": 1},
                 {"id": "linux-local/recipe", "status": "skipped", "code": 0}]
        coverage = {row["id"]: row for row in feedback.coverage_for("fast", tasks)}
        self.assertEqual(coverage["contracts"]["status"], "passed")
        self.assertEqual(coverage["infra"]["status"], "failed")
        self.assertEqual(coverage["recipe"]["status"], "not-run")
        self.assertEqual(coverage["test-native"]["status"], "not-run")
        self.assertEqual(coverage["native-input"]["status"], "skipped")
        self.assertEqual(coverage["windows-native"]["status"], "skipped")

    def run_record_fixture(self, base, snapshots=None, tasks=None):
        runner = base / "actrun.js"
        runner.write_bytes(b"fixture")
        output = base / "output"
        rows = tasks if tasks is not None else [
            {"id": "linux-local/" + identity, "status": "success", "code": 0}
            for identity, _, _ in feedback.steps_for("fast")]
        def run(command, **kwargs):
            if "doctor" in command:
                return SimpleNamespace(returncode=0)
            recorded = output / "runs/run-1"
            recorded.mkdir(parents=True)
            (recorded / "run.json").write_text(json.dumps({"tasks": rows, "ok": True,
                "state": "completed", "workspace_root": str(feedback.REPO)}))
            return SimpleNamespace(returncode=0, stdout="run_id=run-1\n")
        with patch.object(feedback, "source_snapshot", side_effect=snapshots or [{"commit": "frozen"}] * 2), \
             patch.object(feedback, "profile_environment", return_value={"PATH": os.environ["PATH"]}), \
             patch.object(feedback.subprocess, "run", side_effect=run), \
             patch.object(feedback.subprocess, "check_output", return_value="v24.11.0\n"):
            code = feedback.execute(base / "profile", runner, output)
        return code, json.loads((output / "summary.json").read_text())

    def test_success_has_only_scoped_green_and_explicit_skips(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report = self.run_record_fixture(Path(temporary))
        self.assertEqual(code, 0)
        self.assertTrue(report["ok"])
        self.assertEqual(report["green_scope"], "local Linux fast")
        self.assertTrue(any(row["status"] == "skipped" for row in report["coverage"]))
        self.assertNotIn("native_cases", report)

    def test_runner_ok_cannot_hide_a_missing_required_step(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report = self.run_record_fixture(Path(temporary), tasks=[])
        self.assertEqual(code, 1)
        self.assertFalse(report["ok"])
        self.assertIsNone(report["green_scope"])
        self.assertIn("not run", report["error"])

    def test_source_change_revokes_scoped_green(self):
        with tempfile.TemporaryDirectory() as temporary:
            code, report = self.run_record_fixture(Path(temporary),
                snapshots=[{"commit": "before"}, {"commit": "after"}])
        self.assertEqual(code, 1)
        self.assertFalse(report["source_stable"])
        self.assertIsNone(report["green_scope"])

    def test_native_coverage_requires_every_ready_case_and_preserves_skips(self):
        spec = importlib.util.spec_from_file_location("fixture_cases", HERE / "input_cases.py")
        cases = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cases)
        catalog = cases.catalog(cases.CASES)
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            (output / "native-cases").mkdir()
            path = output / "native-cases/summary.json"
            results = [{"case_id": case["id"], "status": "passed" if cases.runnable(case)
                        else "skipped-" + case["disposition"]} for case in catalog]
            def write(rows):
                path.write_text(json.dumps({"results": rows, "executed": sum(cases.runnable(case) for case in catalog)}))
            write(results)
            coverage = feedback.native_coverage(output)
            self.assertEqual(sum(row["status"] == "passed" for row in coverage), 7)
            self.assertEqual({row["id"] for row in coverage if row["status"] == "skipped"}, {"held-repeat", "ime-composition"})
            write(results[:-1])
            with self.assertRaisesRegex(RuntimeError, "exact current catalog"):
                feedback.native_coverage(output)
            write(results + [results[0]])
            with self.assertRaisesRegex(RuntimeError, "exact current catalog"):
                feedback.native_coverage(output)
            wrong = [dict(row) for row in results]
            next(row for row in wrong if row["case_id"] == "held-repeat")["status"] = "passed"
            write(wrong)
            with self.assertRaisesRegex(RuntimeError, "mislabeled"):
                feedback.native_coverage(output)
            wrong = [dict(row) for row in results]
            next(row for row in wrong if row["case_id"] == "basic-text-shift")["status"] = "skipped"
            write(wrong)
            coverage = {row["id"]: row for row in feedback.native_coverage(output)}
            self.assertEqual(coverage["basic-text-shift"]["status"], "failed")
            self.assertEqual(coverage["ctrl-a-replacement"]["status"], "passed")
            path.unlink()
            coverage = {row["id"]: row for row in feedback.native_coverage(output)}
            self.assertEqual(coverage["basic-text-shift"]["status"], "not-run")
            self.assertEqual(coverage["ime-composition"]["status"], "skipped")


if __name__ == "__main__":
    unittest.main()
