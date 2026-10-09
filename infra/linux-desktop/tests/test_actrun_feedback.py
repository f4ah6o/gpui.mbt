import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

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
                    self.assertRegex(generated.name, r"^_local-actrun-feedback-[0-9a-f]{32}\.yml$")
                    self.assertEqual(generated.stat().st_mode & 0o777, 0o600)
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

    def test_palette_modes_are_focused_and_keep_fifteen_foundation_quality_stages(self):
        self.assertEqual(len(feedback.steps_for("quality")), 15)
        self.assertEqual([row[0] for row in feedback.steps_for("palette")], ["palette-wasm", "palette-native"])
        self.assertEqual([row[0] for row in feedback.steps_for("palette-quality")],
                         ["palette-wasm", "palette-native", "palette-mutation", "palette-hotpath"])
        quick = feedback.workflow_text("palette")
        final = feedback.workflow_text("palette-quality")
        self.assertNotIn("turtles", quick)
        self.assertNotIn("hotpath", quick)
        self.assertIn("palette-mutation.py", final)
        self.assertIn("palette-hotpath.py", final)
        self.assertNotIn("composition-proof", final)
        self.assertNotIn("uses:", final)
        self.assertNotIn("install", final)
        empty = [row for row in feedback.coverage_for("palette-quality", []) if "scope" in row]
        self.assertEqual(len(empty), 4)
        self.assertTrue(all(row["status"] == "not-run" for row in empty))

    def test_palette_evidence_missing_stage_fails_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "no regular audited summary"):
                feedback.palette_mutation_evidence(root)
            with self.assertRaisesRegex(RuntimeError, "no regular measured summary"):
                feedback.hotpath_evidence(root, artifact_name="palette-hotpath")

    def test_mutation_is_a_real_named_opt_in_step_and_not_a_fast_default(self):
        scoped = feedback.workflow_text("mutation")
        quality = feedback.workflow_text("quality")
        self.assertIn("id: composition-model", scoped)
        self.assertIn("--target wasm --deny-warn", scoped)
        self.assertIn("id: composition-mutation", scoped)
        self.assertIn('composition-mutation.py --turtles-bin "$GPUI_TURTLES_BIN"', scoped)
        self.assertIn("id: test-native", quality)
        self.assertIn("id: composition-mutation", quality)
        self.assertIn("id: moon-proof", quality)
        self.assertIn("id: input-hotpath", quality)
        self.assertNotIn("composition-mutation.py", feedback.workflow_text("fast"))
        rows = {row["id"]: row for row in feedback.coverage_for("mutation", [])}
        self.assertEqual(rows["composition-mutation"]["status"], "not-run")
        self.assertNotIn("mutation", rows)
        self.assertEqual(rows["full-mutation"]["status"], "skipped")

    def test_requested_proof_and_performance_are_required_scopes_not_quality_skips(self):
        for mode, identity, command in (("proof", "moon-proof", "composition-proof.py"),
                                        ("performance", "input-hotpath", "input-hotpath.py")):
            text = feedback.workflow_text(mode)
            self.assertIn("id: " + identity, text)
            self.assertIn(command, text)
            rows = [row for row in feedback.coverage_for("quality", []) if row["id"] == identity]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["status"], "not-run")
            self.assertIn("scope", rows[0])
        self.assertNotIn("moon-proof", feedback.workflow_text("fast"))
        self.assertNotIn("input-hotpath", feedback.workflow_text("fast"))

    def test_real_mutant_verification_is_required_in_quality_and_opt_in_elsewhere(self):
        scoped = feedback.workflow_text("verification")
        self.assertIn("id: turtles-verification", scoped)
        self.assertIn('turtles-verification.py --repo "$PWD"', scoped)
        for name in ("GPUI_TURTLES_VERIFICATION_ROOT", "GPUI_TURTLES_SCHEMA3_BIN",
                     "GPUI_TURTLES_VERIFICATION_PROFILE", "GPUI_ACTRUN_WORKFLOW"):
            self.assertIn(name, scoped)
        self.assertNotIn('"$GPUI_TURTLES_BIN"', scoped)
        self.assertNotIn("turtles-verification.py", feedback.workflow_text("fast"))
        for mode in ("verification", "quality"):
            rows = [row for row in feedback.coverage_for(mode, []) if row["id"] == "turtles-verification"]
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["status"], "not-run")
            self.assertIn("scope", rows[0])
        self.assertEqual(len(feedback.steps_for("quality")), 15)

    def test_mutation_requires_an_actual_fresh_audited_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "no audited summary"):
                feedback.mutation_evidence(root)
            directory = root / "composition-mutation"
            directory.mkdir()
            (directory / "summary.json").write_text(json.dumps({"ok": True, "qualified_viable": 1}))
            with self.assertRaisesRegex(RuntimeError, "fresh audited scope"):
                feedback.mutation_evidence(root)

    def test_proof_wrapper_delegates_to_strict_current_export_consumer(self):
        root = Path("/tmp/quality-proof-fixture")
        environment = {"MOON_HOME": "/tmp/pinned-moon", "GPUI_PROOF_WHY3": "/tmp/pinned-why3"}
        current = {"commit": "current"}
        module = SimpleNamespace(validate=Mock(return_value={"status": "passed"}))
        with patch.object(feedback, "load_quality_module", return_value=module), \
             patch.object(feedback, "source_snapshot", return_value=current):
            self.assertEqual(feedback.proof_evidence(root, environment), {"status": "passed"})
        module.validate.assert_called_once_with(root / "moon-proof", feedback.REPO, environment, current)

    def test_verification_wrapper_requires_exact_parent_workflow_attestation(self):
        root = Path("/tmp/quality-verification-fixture")
        environment = {"GPUI_TURTLES_SCHEMA3_BIN": "/tmp/pinned-schema3"}
        expected = {"path": ".github/workflows/_local-actrun-feedback-" + "a" * 32 + ".yml",
                    "sha256": "b" * 64, "mode": 0o600}
        audited = {"kind": "bounded-real-mutant-helper-verification"}
        module = SimpleNamespace(validate=Mock(return_value=audited))
        with patch.object(feedback, "load_quality_module", return_value=module):
            self.assertEqual(feedback.verification_evidence(root, environment, expected), audited)
            module.validate.assert_called_once_with(root / "turtles-verification", feedback.REPO, environment,
                                                     expected_workflow=expected)
            for malformed in (None, False, [], {}, {"status": "blocked"}, {"kind": "unqualified"}):
                module.validate.return_value = malformed
                with self.subTest(value=malformed), self.assertRaisesRegex(RuntimeError, "declared audited scope"):
                    feedback.verification_evidence(root, environment, expected)
            module.validate.side_effect = RuntimeError("campaign source changed")
            with self.assertRaisesRegex(RuntimeError, "campaign source changed"):
                feedback.verification_evidence(root, environment, expected)

    def test_verification_missing_explicit_inputs_fails_without_running_actrun(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            runner = root / "runner.js"
            runner.write_bytes(b"fixture")
            with patch.object(feedback, "source_snapshot", return_value={"commit": "frozen"}), \
                 patch.object(feedback, "profile_environment", return_value={"PATH": os.environ["PATH"]}), \
                 patch.object(feedback.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run, \
                 patch.object(feedback.subprocess, "check_output", return_value="v24.11.0\n"):
                self.assertEqual(feedback.execute(root / "profile", runner, root / "output", "verification"), 1)
            self.assertEqual(run.call_count, 1)
            report = json.loads((root / "output/summary.json").read_text())
            self.assertFalse(report["ok"])
            self.assertIn("requires explicit pinned input", report["error"])
            self.assertNotIn("actrun_seconds", report)
            self.assertEqual(next(row for row in report["coverage"] if row["id"] == "turtles-verification")["status"], "not-run")

    def test_verification_stage_receives_and_audits_current_generated_workflow(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            repo = root / "repo"
            (repo / ".github/workflows").mkdir(parents=True)
            runner = root / "runner.js"
            runner.write_bytes(b"fixture")
            output = root / "output"
            environment = {"PATH": os.environ["PATH"], "MOON_HOME": "/tmp/moon",
                           "GPUI_PROOF_WHY3": "/tmp/why3", "GPUI_PROOF_SOLVER": "/tmp/z3",
                           "GPUI_TURTLES_VERIFICATION_ROOT": "/tmp/turtles",
                           "GPUI_TURTLES_SCHEMA3_BIN": "/tmp/schema3", "GPUI_TURTLES_VERIFICATION_PROFILE": "/tmp/profile.json"}
            captured = {}
            def run(command, **kwargs):
                if "doctor" in command:
                    return SimpleNamespace(returncode=0)
                captured.update(kwargs["env"])
                workflow = Path(captured["GPUI_ACTRUN_WORKFLOW"])
                self.assertTrue(workflow.is_file())
                self.assertIn("id: turtles-verification", workflow.read_text())
                recorded = output / "runs/run-1"
                recorded.mkdir(parents=True)
                (recorded / "run.json").write_text(json.dumps({"tasks": [
                    {"id": "linux-local/turtles-verification", "status": "success", "code": 0}],
                    "ok": True, "state": "completed", "workspace_root": str(repo)}))
                return SimpleNamespace(returncode=0, stdout="run_id=run-1\n")
            collector = Mock(return_value={"status": "passed"})
            with patch.object(feedback, "REPO", repo), \
                 patch.object(feedback, "source_snapshot", return_value={"commit": "frozen"}), \
                 patch.object(feedback, "profile_environment", return_value=environment), \
                 patch.object(feedback.subprocess, "run", side_effect=run), \
                 patch.object(feedback.subprocess, "check_output", return_value="v24.11.0\n"), \
                 patch.object(feedback, "verification_evidence", collector):
                self.assertEqual(feedback.execute(root / "profile", runner, output, "verification"), 0)
            report = json.loads((output / "summary.json").read_text())
            self.assertFalse(Path(captured["GPUI_ACTRUN_WORKFLOW"]).exists())
            expected = report["generated_workflow"]
            self.assertEqual(expected["path"], Path(captured["GPUI_ACTRUN_WORKFLOW"]).relative_to(repo).as_posix())
            self.assertEqual(expected["mode"], 0o600)
            self.assertEqual(expected["sha256"], hashlib.sha256((output / "workflow.yml").read_bytes()).hexdigest())
            collector.assert_called_once_with(output, environment, expected)

    def test_hotpath_wrapper_requires_strict_schema_policy_and_current_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "input-hotpath"
            with self.assertRaisesRegex(RuntimeError, "no regular measured"):
                feedback.hotpath_evidence(root)
            directory.mkdir()
            current = {"commit": "current", "tree": "current-tree"}
            valid = {"schema_version": 2, "repeats": 7, "performance_policy": "observe-only: no universal timing gate",
                     "source_before": current, "source_after": current, "scope": "fixture", "excluded": [],
                     "hotpath_runtime": {}, "binary_sha256": "fixture", "workload_sha256": "fixture",
                     "behavior_equal": True, "statistics": {}}
            path = directory / "summary.json"
            path.write_text(json.dumps(valid))
            module = SimpleNamespace(validate_evidence=Mock(side_effect=lambda report, _: report))
            with patch.object(feedback, "load_quality_module", return_value=module), \
                 patch.object(feedback, "source_snapshot", return_value=current):
                self.assertTrue(feedback.hotpath_evidence(root)["behavior_equal"])
                module.validate_evidence.assert_called_once_with(valid, directory)
                broken = dict(valid)
                broken["source_before"] = {"commit": "previous"}
                path.write_text(json.dumps(broken))
                with self.assertRaisesRegex(RuntimeError, "stale for the current"):
                    feedback.hotpath_evidence(root)
                for key, value in (("schema_version", 1), ("schema_version", True), ("repeats", 6),
                                   ("performance_policy", "baseline")):
                    broken = dict(valid)
                    broken[key] = value
                    path.write_text(json.dumps(broken))
                    with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, "requires fresh schema2"):
                        feedback.hotpath_evidence(root)
                path.write_text(json.dumps(valid))
                module.validate_evidence.side_effect = RuntimeError("raw statistics differ")
                with self.assertRaisesRegex(RuntimeError, "raw statistics differ"):
                    feedback.hotpath_evidence(root)

    def test_hotpath_current_fontconfig_fonts_and_default_tools_are_bound(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / "input-hotpath"
            directory.mkdir()
            config, font = root / "fonts.conf", root / "fixture.ttf"
            config.write_text("current fontconfig")
            font.write_bytes(b"current font")
            snapshot = {"commit": "current"}
            recorded = {"installed_profile_sha256": "marker", "profile_lock_sha256": "digest",
                        "native_build": "native", "core_module_sha256": "digest", "fontconfig_sha256": "digest",
                        "fonts": {"sans": "digest", "Noto Sans CJK JP": "digest"},
                        "tools": {"moon": "tool", "moonc": "tool", "moonrun": {"sha256": "digest"},
                                  "default_cc": "tool", "fc_match": "tool"}}
            report = {"schema_version": 2, "repeats": 7, "performance_policy": "observe-only: no universal timing gate",
                      "source_before": snapshot, "source_after": snapshot, "scope": "fixture", "excluded": [],
                      "hotpath_runtime": {}, "binary_sha256": "digest", "workload_sha256": "digest",
                      "behavior_equal": True, "statistics": {}, "environment": recorded}
            path = directory / "summary.json"
            path.write_text(json.dumps(report))
            module = SimpleNamespace(validate_evidence=lambda report, _: report,
                      verify_profile=lambda _: (root / "profile", "marker"), native_build_identity=lambda _: "native",
                      environment_words=lambda *args: ["cc"], tool_identity=lambda *args: "tool")
            environment = {"GPUI_DESKTOP_ROOT": str(root / "profile"), "FONTCONFIG_FILE": str(config)}
            with patch.object(feedback, "load_quality_module", return_value=module), \
                 patch.object(feedback, "source_snapshot", return_value=snapshot), \
                 patch.object(feedback, "digest", return_value="digest"), \
                 patch.object(feedback.subprocess, "check_output", return_value=str(font)):
                self.assertTrue(feedback.hotpath_evidence(root, environment)["behavior_equal"])
                for field in ("fontconfig_sha256", "fonts", "default_cc", "fc_match"):
                    broken = json.loads(json.dumps(report))
                    if field in ("default_cc", "fc_match"):
                        broken["environment"]["tools"][field] = "old tool"
                    else:
                        broken["environment"][field] = "old bytes"
                    path.write_text(json.dumps(broken))
                    with self.subTest(field=field), self.assertRaisesRegex(RuntimeError, "hotpath current"):
                        feedback.hotpath_evidence(root, environment)

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


class ImeIngressGateTests(unittest.TestCase):
    def test_fast_and_acceptance_include_production_ime_ingress(self):
        for mode in ("fast", "acceptance"):
            steps = feedback.steps_for(mode)
            identities = [row[0] for row in steps]
            self.assertEqual(identities.count("ubuntu-ingress"), 1)
            self.assertLess(identities.index("protocols"), identities.index("ubuntu-ingress"))
            self.assertEqual(dict((i,c) for i,_,c in steps)["ubuntu-ingress"],
                             "sh scripts/test_ubuntu_ingress.sh")

    def test_fast_checks_portable_read_only_ime_owner_harness(self):
        steps = {i:c for i,_,c in feedback.steps_for("fast")}
        self.assertEqual(steps["ime-owner-safety"],
                         "python3 infra/linux-desktop/wayland-ime/test_gpui_probe.py")

    def test_missing_ime_ingress_can_never_be_green(self):
        tasks = [{"id": "linux-local/" + identity, "status": "success", "code": 0}
                 for identity, _, _ in feedback.steps_for("fast")
                 if identity != "ubuntu-ingress"]
        coverage = {row["id"]: row for row in feedback.coverage_for("fast", tasks)}
        self.assertEqual(coverage["ubuntu-ingress"]["status"], "not-run")


if __name__ == "__main__":
    unittest.main()
