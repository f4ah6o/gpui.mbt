import copy
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "composition-proof.py"
spec = importlib.util.spec_from_file_location("composition_proof", MODULE_PATH)
proof = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proof)
ROOT = MODULE_PATH.parents[2]
LOCK = json.loads((ROOT / "testing/composition_proof/proof-toolchain.lock.json").read_text())


class CompositionProofTests(unittest.TestCase):
    def test_native_server_never_qualifies_any_summary(self):
        for report in [{"result": "success", "summary": {"valid": 5}}, {"status": "proved"}, {}]:
            with self.assertRaises(proof.ProofBlocked):
                proof.report_verdict(report)

    def test_actual_sources_match_and_a_body_mutation_does_not(self):
        implementation = (ROOT / "testing/composition_proof/implementation.mbt").read_text()
        for filename, head in proof.TARGETS:
            self.assertEqual(proof.canonical(proof.declaration((ROOT / filename).read_text(), head)),
                             proof.canonical(proof.declaration(implementation, head)))
        changed = implementation.replace("if scalar <= 0x7F {", "if scalar < 0x7F {")
        self.assertNotEqual(proof.canonical(proof.declaration(implementation, "fn utf8_scalar_width(")),
                            proof.canonical(proof.declaration(changed, "fn utf8_scalar_width(")))

    def test_exact_goal_ids_reject_missing_extra_duplicate_malformed_and_arbitrary_names(self):
        expected = LOCK["export_backend"]["expected_goal_ids"]
        self.assertEqual(proof.exact_goal_inventory(expected, LOCK), expected)
        bad = [expected[:-1], expected + ["extra'vc"], expected[:-1] + [expected[0]],
               expected[:-1] + [False], ["arbitrary'vc"] * 5, "five-goals"]
        for goals in bad:
            with self.assertRaises(ValueError):
                proof.exact_goal_inventory(goals, LOCK)

    def test_exact_control_target_does_not_use_suffix_matching(self):
        ids = LOCK["export_backend"]["expected_goal_ids"]
        for name in ["positive", "negative-range", "negative-utf8"]:
            answers = [proof.expected_answer(name, goal, LOCK) for goal in ids]
            self.assertEqual(answers.count("sat"), 0 if name == "positive" else 1)
        with self.assertRaises(ValueError):
            proof.expected_answer("negative-range", "forged_TextRange_3a_3alength'vc", LOCK)

    def test_environment_drops_poisoned_why3_and_dynamic_loading_overrides(self):
        env = proof.sanitized_environment({"PATH": "/usr/bin", "WHY3LOADPATH": "/poison",
             "WHY3CONFIG": "/poison/with-plugin", "WHY3LIB": "/poison", "WHY3DATA": "/poison",
             "WHY3MLWPRINTERIDS": "poison", "LD_PRELOAD": "evil.so", "OCAMLPATH": "/poison"},
             Path("/moon"), Path("/solver/z3"))
        self.assertFalse(any(key.startswith("WHY3") for key in env))
        self.assertNotIn("LD_PRELOAD", env)
        self.assertNotIn("OCAMLPATH", env)

    def fixture_runtime(self, base):
        prefix = base / "why3-prefix"
        why3 = prefix / "bin/why3"
        plugin = prefix / "lib/why3/commands/why3prove.cmxs"
        for path in [why3, plugin]:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"owned fixture " + path.name.encode())
        moon = base / "moon"
        for path in [moon / "lib/prelude_proof", moon / "share/why3/stdlib"]:
            path.mkdir(parents=True)
        lock = copy.deepcopy(LOCK)
        lock["export_backend"].update(cli_sha256=proof.digest(why3), prove_plugin_sha256=proof.digest(plugin),
                                      moon_why3_datadir_sha256=proof.tree_digest(moon / "share/why3"))
        return why3, plugin, moon, lock

    def test_exact_fresh_config_has_no_plugin_or_ambient_loadpaths(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            why3, plugin, moon, lock = self.fixture_runtime(base)
            out = base / "out"
            out.mkdir()
            probes = [b"Why3 platform, version 1.7.2\n", str(plugin.parent.parent).encode() + b"\n"]
            with patch.object(proof, "probe", side_effect=probes):
                bindings = proof.bind_export_runtime(why3, moon, out, {}, lock, 1, [], "run-id")
            self.assertEqual(bindings["actual_prove_plugin"], str(plugin))
            self.assertEqual(bindings["effective_loadpaths"], [str(moon / "lib/prelude_proof"), str(moon / "share/why3/stdlib")])
            self.assertEqual(bindings["plugin_entries"], [])
            self.assertFalse(bindings["stdlib"])
            self.assertFalse(bindings["load_default_plugins"])
            config = out / "why3-export.conf"
            original = config.read_text()
            config.write_text(original + 'plugin = "poison"\n')
            with patch.object(proof, "probe", side_effect=probes), self.assertRaises(FileExistsError):
                proof.bind_export_runtime(why3, moon, out, {}, lock, 1, [], "new-run")
            self.assertIn('plugin = "poison"', config.read_text())

    def test_relocated_cli_and_actual_plugin_hash_mismatch_are_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            why3, plugin, moon, lock = self.fixture_runtime(base)
            out = base / "out"
            out.mkdir()
            foreign = base / "compiled-old-prefix/lib/why3"
            foreign.mkdir(parents=True)
            with patch.object(proof, "probe", side_effect=[b"Why3 platform, version 1.7.2\n", str(foreign).encode()]), self.assertRaises(ValueError):
                proof.bind_export_runtime(why3, moon, out, {}, lock, 1, [], "run")
            plugin.write_bytes(b"poisoned loaded plugin")
            with patch.object(proof, "probe", side_effect=[b"Why3 platform, version 1.7.2\n", str(plugin.parent.parent).encode()]), self.assertRaises(ValueError):
                proof.bind_export_runtime(why3, moon, out, {}, lock, 1, [], "run")

    def test_solver_fields_log_command_and_unknown_are_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "solver.log"
            log.write_text('COMMAND ["z3", "task"]\nunsat\n')
            attempt = dict(command=["z3", "task"], exit_code=0, timed_out=False, seconds=0.1)
            self.assertEqual(proof.solver_answer(attempt, log), "unsat")
            for key, bad in [("exit_code", False), ("timed_out", 0), ("seconds", True),
                             ("seconds", float("nan")), ("command", [False])]:
                row = dict(attempt)
                row[key] = bad
                with self.assertRaises(ValueError):
                    proof.solver_answer(row, log)
            with self.assertRaises(ValueError):
                proof.solver_answer({**attempt, "command": ["different"]}, log)
            for answer in ["unknown", "timeout", "sat\nunsat", "(error poison)"]:
                log.write_text('COMMAND ["z3", "task"]\n' + answer + '\n')
                with self.assertRaises(proof.ProofBlocked):
                    proof.solver_answer(attempt, log)

    def test_reused_directory_archives_old_pass_and_current_attempt_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "old"
            out.mkdir()
            (out / "proof-result.json").write_text('{"ok":true,"status":"passed","run_id":"old"}')
            argv = [str(MODULE_PATH), "--source-root", str(ROOT), "--artifact-dir", str(out)]
            with patch.object(sys, "argv", argv):
                self.assertEqual(proof.main(), 2)
            current = json.loads((out / "proof-result.json").read_text())
            self.assertFalse(current["ok"])
            self.assertTrue(current["terminal"])
            self.assertEqual(current["status"], "failed")
            self.assertNotEqual(current["run_id"], "old")
            self.assertEqual(len(list(out.glob("previous-proof-result-*.json"))), 1)

    def mini_source_and_tools(self, base):
        root = base / "source"
        for name in ["text/range.mbt", "text/document.mbt"]:
            target = root / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, target)
        shutil.copytree(ROOT / "testing/composition_proof", root / "testing/composition_proof")
        moon = base / "moon"
        lock_path = root / "testing/composition_proof/proof-toolchain.lock.json"
        lock = json.loads(lock_path.read_text())
        for name in lock["artifact_sha256"]:
            target = moon / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(b"owned fixture " + name.encode())
            lock["artifact_sha256"][name] = proof.digest(target)
        (moon / "lib/why3/META").write_text('version = "1.7.2"\n')
        solver = base / "z3"
        solver.write_bytes(b"owned solver fixture")
        lock["solver"]["executable_sha256"] = proof.digest(solver)
        lock_path.write_text(json.dumps(lock))
        return root, moon, solver

    def test_failed_and_interrupted_version_probe_leave_terminal_non_success(self):
        for error, status in [(proof.ProofBlocked("failed version command"), "blocked"),
                              (KeyboardInterrupt(), "interrupted"), (RuntimeError("unexpected probe bug"), "failed")]:
            with tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp)
                root, moon, solver = self.mini_source_and_tools(base)
                out = base / "evidence"
                argv = [str(MODULE_PATH), "--source-root", str(root), "--artifact-dir", str(out),
                        "--moon-home", str(moon), "--solver", str(solver)]
                with patch.object(sys, "argv", argv), patch.object(proof, "probe", side_effect=error):
                    self.assertEqual(proof.main(), 2)
                result = json.loads((out / "proof-result.json").read_text())
                self.assertFalse(result["ok"])
                self.assertTrue(result["terminal"])
                self.assertEqual(result["status"], status)
                self.assertEqual(result["verified_scope"], [])

    def test_hanging_version_probe_is_bounded_and_cleans_descendant_group(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            code = 'import subprocess,sys,time; child=subprocess.Popen([sys.executable,"-c","import time; time.sleep(30)"]); print(child.pid,flush=True); time.sleep(30)'
            with self.assertRaises(proof.ProofBlocked):
                proof.probe([sys.executable, "-c", code], out, dict(os.environ), out, "version", 0.15, [])
            lines = proof.output_bytes(out / "version.log").decode().splitlines()
            self.assertTrue(lines)
            status = Path("/proc") / lines[0] / "status"
            if status.exists():
                self.assertIn("\nState:\tZ", status.read_text())

    def test_failed_external_probe_is_bounded(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            with self.assertRaises(proof.ProofBlocked):
                proof.probe([sys.executable, "-c", "raise SystemExit(7)"], out, dict(os.environ), out, "failed-version", 1, [])
            self.assertIn("COMMAND ", (out / "failed-version.log").read_text())

    def test_real_sigterm_interrupts_version_and_keeps_atomic_non_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            root, moon, solver = self.mini_source_and_tools(base)
            fake_moon = moon / "bin/moon"
            fake_moon.write_text("#!" + sys.executable + "\nimport os,time\nprint(os.getpid(),flush=True)\ntime.sleep(30)\n")
            fake_moon.chmod(0o755)
            lock_path = root / "testing/composition_proof/proof-toolchain.lock.json"
            lock = json.loads(lock_path.read_text())
            lock["artifact_sha256"]["bin/moon"] = proof.digest(fake_moon)
            lock_path.write_text(json.dumps(lock))
            out = base / "evidence"
            proc = subprocess.Popen([sys.executable, str(MODULE_PATH), "--source-root", str(root),
                                     "--artifact-dir", str(out), "--moon-home", str(moon), "--solver", str(solver)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            child_pid = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    log = out / "moon-version.log"
                    if log.exists():
                        lines = proof.output_bytes(log).decode().splitlines()
                        if lines:
                            child_pid = int(lines[0])
                            break
                    time.sleep(0.01)
                self.assertIsNotNone(child_pid)
                initial = json.loads((out / "proof-result.json").read_text())
                self.assertFalse(initial["ok"])
                self.assertFalse(initial["terminal"])
                proc.terminate()
                proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 2)
                terminal = json.loads((out / "proof-result.json").read_text())
                self.assertFalse(terminal["ok"])
                self.assertTrue(terminal["terminal"])
                self.assertEqual(terminal["status"], "interrupted")
                child = Path("/proc") / str(child_pid) / "status"
                if child.exists():
                    self.assertIn("\nState:\tZ", child.read_text())
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate(timeout=3)
                if child_pid:
                    try:
                        os.killpg(child_pid, 9)
                    except ProcessLookupError:
                        pass


if __name__ == "__main__":
    unittest.main()
