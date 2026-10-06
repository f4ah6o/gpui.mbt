import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
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


if __name__ == "__main__":
    unittest.main()
