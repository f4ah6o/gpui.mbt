"""Adversarial stage/consumer gates; synthetic fixtures are not proof evidence."""
import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace
import tempfile
import unittest
import shutil
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("turtles_verification", Path(__file__).parents[1] / "turtles-verification.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


class VerificationStageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_lock_edits_block_before_import_or_execution(self):
        original = M.read_json(M.LOCK_PATH)
        fixture = self.root / "lock.json"
        for key, value in (("adapter_sha256", "a"*64), ("turtles_commit", "a"*40), ("producer_sha256", "a"*64), ("maximum_stage_seconds", 99999), ("schema", True), ("extra", "arbitrary hook")):
            fixture.write_text(json.dumps({**original, key: value}))
            with self.subTest(key=key), patch.object(M, "LOCK_PATH", fixture), patch.object(M, "load_module", side_effect=AssertionError("must not import")), patch.object(M, "git_value", side_effect=AssertionError("must not execute")), self.assertRaisesRegex(RuntimeError, "integration lock differs"):
                M.load_inputs(*([self.root]*7))

    def test_workflow_exact_path_hash_mode_and_presence(self):
        workflow = self.root / ".github/workflows/_local-actrun-feedback-12345678.yml"
        workflow.parent.mkdir(parents=True)
        workflow.write_text("parent fixed workflow")
        bound = M.workflow_binding(self.root, workflow)
        manifest = {bound["path"]: {"sha256": bound["sha256"], "mode": bound["mode"], "link": None}, "real.mbt": {"sha256": "a"*64, "mode": 0o644, "link": None}}
        self.assertEqual(set(M.strip_workflow(manifest, bound, require_present=True)), {"real.mbt"})
        with self.assertRaises(RuntimeError):
            M.strip_workflow({}, bound, require_present=True)
        self.assertEqual(M.strip_workflow({}, bound, self.root), {})
        for bad in ({**bound, "path": ".github/workflows/ci.yml"}, {**bound, "mode": True}, {**bound, "sha256": "old"}):
            with self.assertRaises(RuntimeError):
                M.strip_workflow(manifest, bad, require_present=True)
        uuid_workflow = workflow.with_name("_local-actrun-feedback-" + "a"*32 + ".yml")
        uuid_workflow.write_text("uuid generator")
        M.workflow_binding(self.root, uuid_workflow)
        workflow.write_text("changed")
        with self.assertRaises(RuntimeError):
            M.strip_workflow(manifest, bound, self.root)

    def test_artifact_and_directory_symlinks_are_rejected(self):
        (self.root / "a").mkdir()
        (self.root / "a/file.json").write_text("{}")
        (self.root / "alias").symlink_to(self.root / "a", target_is_directory=True)
        (self.root / "manifest.json").symlink_to(self.root / "a/file.json")
        with self.assertRaises(RuntimeError):
            M.contained_directory(self.root, "alias")
        with self.assertRaises(RuntimeError):
            M.regular_artifact(self.root, "manifest.json")
        with self.assertRaises(RuntimeError):
            M.regular_artifact(self.root, "alias/file.json")
        self.assertEqual(M.regular_artifact(self.root, "a/file.json"), self.root / "a/file.json")

    def test_unknown_uuid_timestamps_and_json_are_blockers(self):
        valid = "960a9bef-554d-4f79-83d7-dd35bad390a2"
        self.assertEqual(M.uuid_value(valid), valid)
        for value in (None, False, 1, "not-uuid", valid.upper()):
            with self.assertRaises(RuntimeError):
                M.uuid_value(value)
        for value in (None, False, 1, "bad", "2026-10-06T00:00:00"):
            with self.assertRaises(RuntimeError):
                M.utc_value(value)
        fixture = self.root / "bad.json"
        for value in ('{"a":1,"a":2}', '{"seconds":NaN}'):
            fixture.write_text(value)
            with self.assertRaises(RuntimeError):
                M.read_json(fixture)

    def test_runtime_overrides_rejected_before_support_probe(self):
        for variable in ("CC", "CFLAGS", "LDFLAGS", "MOON_CC"):
            with self.subTest(variable=variable), patch.object(M.shutil, "which", side_effect=AssertionError("must not resolve")), self.assertRaisesRegex(RuntimeError, "environment override"):
                M.runtime_support({variable: "unqualified"}, self.root, self.root / "z3")

    def test_only_verified_profile_ffi_flags_are_normalized_in_copy(self):
        repo = self.root / "repo"
        directory = repo / "infra/linux-desktop"
        directory.mkdir(parents=True)
        for name in ("gpui-desktop.py", "build_manifest.py", "profile.lock.json"):
            shutil.copyfile(Path(__file__).parents[1] / name, directory / name)
        profile = self.root / "profile with spaces"
        profile.mkdir()
        installed = profile / "installed.json"
        installed.write_text(json.dumps({"lock_sha256": M.digest(directory / "profile.lock.json"), "profile": M.read_json(directory / "profile.lock.json")}))
        prefix = profile / "prefix"
        flags = {"LDFLAGS": M.shlex.join(["-L" + str(prefix / "usr/lib/x86_64-linux-gnu")]) + " ",
                 "CPPFLAGS": M.shlex.join(["-I" + str(prefix / "usr/include"), "-I" + str(prefix / "usr/include/x86_64-linux-gnu")]) + " "}
        parent = {"GPUI_DESKTOP_ROOT": str(profile), "KEEP": "unchanged", **flags}
        # The fixture may run on the preserved older base or composed main.
        # Both dependency bytes were explicitly reviewed; this unit fixture
        # never relaxes the production lock's current-main-only cc1e pin.
        fixture_lock = M.integration_lock()
        dependency_hash = M.digest(directory / "build_manifest.py")
        self.assertIn(dependency_hash, {"ee76fca7b0e63870824f06f28679bd9d3b25ff7abff53ba28a6d7fcd0e1bc02a", "cc1e9976380a1b0d4ff7fc6d505387249124e910b46ea7c380134c8f6f9115fe"})
        fixture_lock["native_environment_dependency_sha256"] = dependency_hash
        def derive(environment):
            with patch.object(M, "integration_lock", return_value=fixture_lock):
                return M.portable_environment(repo, environment)
        child, recorded = derive(parent)
        self.assertEqual(parent, {"GPUI_DESKTOP_ROOT": str(profile), "KEEP": "unchanged", **flags})
        self.assertNotIn("LDFLAGS", child)
        self.assertNotIn("CPPFLAGS", child)
        self.assertEqual(child["KEEP"], "unchanged")
        self.assertEqual(recorded["removed"], flags)
        self.assertEqual(derive(parent), (child, recorded))
        dependency = directory / "build_manifest.py"
        original_dependency = dependency.read_bytes()
        dependency.write_text("raise RuntimeError('must not execute')")
        with self.assertRaisesRegex(RuntimeError, "unreviewed"):
            derive(parent)
        dependency.write_bytes(original_dependency)
        for variable in ("LDFLAGS", "CPPFLAGS", "CC", "CFLAGS", "MOON_CC"):
            bad = {**parent, variable: parent.get(variable, "") + " -unknown-user-override"}
            with self.subTest(variable=variable), self.assertRaises(RuntimeError):
                derive(bad)
        installed.write_text('{"lock_sha256":"stale"}')
        with self.assertRaises(RuntimeError):
            derive(parent)

    def test_ffi_flags_without_verified_profile_are_not_scrubbed(self):
        for flags in ({"LDFLAGS": "-Lwhatever"}, {"CPPFLAGS": "-Iwhatever"}):
            with self.assertRaises(RuntimeError):
                M.portable_environment(self.root, flags)
        child, recorded = M.portable_environment(self.root, {"PATH": "/usr/bin"})
        self.assertEqual(child, {"PATH": "/usr/bin"})
        self.assertEqual(recorded, {"policy": "portable-no-native-flags-v1", "removed": {}})

    def test_unviable_is_separate_and_baseline_guard_needs_survive(self):
        # The public consumer has explicit baseline SURVIVED guards, while
        # candidate compiler rejection stays outside the runtime denominator.
        text = (Path(__file__).parents[1] / "turtles-verification.py").read_text()
        self.assertIn('!= "SURVIVED"', text)
        self.assertIn('"compiler_rejections": compiler_rejections', text)
        self.assertIn('"proof_counterexamples_added_to_runtime_kills": 0', text)

    def test_only_attributed_compiler_warning_is_unviable(self):
        checkout = self.root / "source"
        file = checkout / "text/document.mbt"
        file.parent.mkdir(parents=True)
        declaration = "fn utf16_scalar_width(scalar : Int) -> Int {"
        file.write_text(declaration + "\n  if true { 1 } else { 2 }\n}\n")
        mapped = {"path": "text/document.mbt", "head": "fn utf16_scalar_width(", "original": "scalar <= 0xFFFF", "replacement": "true"}
        output = f"Error: [0002]\n   ╭─[ {file}:1:23 ]\n   │\n 1 │ {declaration}\n   │" + " "*23 + "───┬──  \n   │" + " "*26 + "╰──── Error Warning (unused_value): Unused variable 'scalar'\n───╯\nFailed with 0 warnings, 1 errors.\nError: failed to run check for target Wasm\n\nCaused by:\n    failed when checking project"
        self.assertEqual(M.qualify_warning_rejection(output, 255, checkout, mapped), "warning-denied-unused-scalar")
        for code, text in ((127, "moon: not found"), (139, "Segmentation fault"), (1, ""), (255, ""), (255, output.replace(":1:23", ":2:23")), (255, output.replace("unused_value", "parse_error"))):
            with self.subTest(code=code, text=text), self.assertRaises(RuntimeError):
                M.qualify_warning_rejection(text, code, checkout, mapped)
        with self.assertRaises(RuntimeError):
            M.qualify_warning_rejection(output, 255, checkout, {**mapped, "head": "fn utf8_scalar_width("})
        for index in (2, 4, 5, 6):
            injected = output.splitlines()
            injected[index] = "Segmentation fault (unknown tool failure)"
            with self.subTest(index=index), self.assertRaises(RuntimeError):
                M.qualify_warning_rejection("\n".join(injected), 255, checkout, mapped)

    def test_interrupted_audit_never_leaves_success(self):
        repo = self.root / "repo"
        repo.mkdir()
        output = self.root / "run"
        profile = self.root / "profile.json"
        profile.write_text("{}")
        adapter = SimpleNamespace(write_json=lambda p, o: p.write_text(json.dumps(o)),
                                  run=lambda *a: {"exit_code": 0, "timed_out": False},
                                  artifact=lambda root, rel: root/rel,
                                  read_json=lambda p: {"run_id": "960a9bef-554d-4f79-83d7-dd35bad390a2"})
        args = SimpleNamespace(repo=repo, output=output, turtles_root=self.root, turtles_bin=profile, profile=profile,
                               moon_home=self.root, why3=profile, solver=profile, ephemeral_workflow=None)
        # This unit models interruption after preflight. Profile normalization
        # has its own real positive/negative tests and must not read the host
        # profile through this synthetic fixture's mocked digest function.
        with patch.object(M, "portable_environment", return_value=({}, {"policy": "portable-no-native-flags-v1", "removed": {}})), patch.object(M, "load_inputs", return_value=({"maximum_stage_seconds": 1}, adapter, {}, {}, {})), patch.object(M, "git_value", return_value="a"*40), patch.object(M, "digest", return_value="a"*64), patch.object(M, "_validate", side_effect=KeyboardInterrupt("audit interrupted")):
            self.assertEqual(M.execute(args), 2)
        invocation = M.read_json(output / "invocation.json")
        self.assertFalse(invocation["ok"])
        self.assertEqual(invocation["status"], "interrupted")
        self.assertTrue(invocation["terminal"])


if __name__ == "__main__":
    unittest.main()
