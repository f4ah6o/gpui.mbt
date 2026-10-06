import hashlib
import importlib.util
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "build_manifest.py"
spec = importlib.util.spec_from_file_location("build_manifest_test", SCRIPT)
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class BuildManifestTests(unittest.TestCase):
    def test_source_captures_tracked_patch_and_untracked_regular_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            source = repo / "new.mbt"
            source.write_text("let value = 1\n")
            responses = {("diff", "HEAD", "--binary", "--no-ext-diff", "--no-textconv", "--"): b"tracked patch\n",
                         ("ls-files", "-v", "-z"): b"H tracked.mbt\0",
                         ("ls-files", "--others", "--exclude-standard", "-z"): b"new.mbt\0",
                         ("rev-parse", "HEAD"): b"a" * 40 + b"\n",
                         ("rev-parse", "HEAD^{tree}"): b"b" * 40 + b"\n",
                         ("status", "--porcelain"): b"?? new.mbt\n"}
            with patch.object(build, "git", side_effect=lambda repo, *args: responses[args]):
                captured = build.capture_source(repo)
            self.assertEqual(captured["tracked_patch_sha256"], hashlib.sha256(b"tracked patch\n").hexdigest())
            self.assertEqual(captured["untracked_files"], [{"relative_path": "new.mbt", "sha256": build.digest(source), "size": source.stat().st_size}])

    def test_untracked_links_are_not_silently_omitted(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            (repo / "link").symlink_to("missing")
            def fake_git(repo, *args):
                return b"link\0" if args == ("ls-files", "--others", "--exclude-standard", "-z") else b""
            with patch.object(build, "git", side_effect=fake_git):
                with self.assertRaisesRegex(RuntimeError, "links/special"):
                    build.capture_source(repo)

    def test_hidden_tracked_source_flags_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            for flag in [b"h", b"S", b"s"]:
                with self.subTest(flag=flag):
                    with patch.object(build, "git", return_value=flag + b" hidden.mbt\0") as git:
                        with self.assertRaisesRegex(RuntimeError, "assume-unchanged/skip-worktree"):
                            build.capture_source(temporary)
                        git.assert_called_once_with(Path(temporary), "ls-files", "-v", "-z")

    def test_tracked_patch_ignores_lossy_textconv(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.STDOUT)
            git("init", "-q")
            (repo / "source.mbt").write_text("let value = 1\n")
            (repo / ".gitattributes").write_text("source.mbt diff=mask\n")
            git("add", ".")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "-qm", "fixture", "--no-gpg-sign")
            git("config", "diff.mask.textconv", "printf constant-output")
            before = build.capture_source(repo)
            (repo / "source.mbt").write_text("let value = 2\n")
            after = build.capture_source(repo)
            self.assertNotEqual(before, after)
            self.assertIn("+let value = 2", after["tracked_patch_utf8"])

    def test_hidden_index_flags_never_mask_changed_tracked_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.STDOUT)
            git("init", "-q")
            source = repo / "source.mbt"
            source.write_text("let value = 1\n")
            git("add", "source.mbt")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                "commit", "-qm", "fixture", "--no-gpg-sign")
            for flag in ["assume-unchanged", "skip-worktree"]:
                with self.subTest(flag=flag):
                    git("update-index", "--" + flag, "source.mbt")
                    source.write_text("let value = 2\n")
                    with self.assertRaisesRegex(RuntimeError, "assume-unchanged/skip-worktree"):
                        build.capture_source(repo)
                    source.write_text("let value = 1\n")
                    git("update-index", "--no-" + flag, "source.mbt")

    def runtime_fixture(self, root):
        profile, repo, tools = root / "profile", root / "repo", root / "tools"
        for directory in [profile / "moon/lib/core", repo / "ubuntu", tools]:
            directory.mkdir(parents=True)
        (profile / "installed.json").write_text("{}")
        (profile / "fonts.conf").write_text("<fontconfig/>")
        (profile / "moon/lib/core/source.mbt").write_text("core")
        for name in ["moon", "moonc", "moonrun", "internal/tcc"]:
            tool = profile / "moon/bin" / name
            tool.parent.mkdir(parents=True, exist_ok=True)
            tool.write_bytes(b"fixture tool")
            tool.chmod(0o755)
        for name in ["cc", "pkg-config", "pkg-config-wrapper", "override pkg-config", "wayland-scanner", "fc-list"]:
            tool = tools / name
            tool.write_bytes(b"fixture " + name.encode())
            tool.chmod(0o755)
        for name in build.XKB:
            path = profile / "prefix/usr/share/X11/xkb" / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture xkb")
        for name in ["xdg-shell-client-protocol.h", "xdg-shell-protocol.c"]:
            (repo / "ubuntu" / name).write_text("fixture generated protocol")
        return profile, repo, {"PATH": str(tools)}

    def test_pkg_config_override_records_and_probes_actual_shell_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile, repo, env = self.runtime_fixture(root)
            overrides = [(str(root / "tools/override pkg-config"), [str(root / "tools/override pkg-config")]),
                         (shlex.quote(str(root / "tools/override pkg-config")) + " --marker pkg-config",
                          [str(root / "tools/override pkg-config"), "--marker", "pkg-config"]),
                         ("pkg-config-wrapper --marker pkg-config", ["pkg-config-wrapper", "--marker", "pkg-config"])]
            for value, words in overrides:
                with self.subTest(command=value):
                    with patch.object(build.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="fixture 1", stderr="")) as run, \
                         patch.object(build, "configured_fonts", return_value=[]):
                        captured = build.capture_runtime(profile, profile / "fonts.conf", dict(env, PKG_CONFIG=value), repo)
                    self.assertEqual(captured["pkg_config_command"], words)
                    selected = next(row for row in captured["files"] if row.get("role") == "tool:pkg-config")
                    expected = root / "tools" / words[0] if not Path(words[0]).is_absolute() else Path(words[0])
                    self.assertEqual(selected["path"], str(expected))
                    self.assertTrue(any(call.args[0] == [str(expected), *words[1:], "--version"] for call in run.call_args_list))
                    if len(words) > 1:
                        self.assertTrue(any(row.get("role") == "tool:pkg-config-wrapper-child" and row["path"] == str(root / "tools/pkg-config") for row in captured["files"]))
            with patch.object(build.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout="fixture 1", stderr="")), \
                 patch.object(build, "configured_fonts", return_value=[]):
                plain = build.capture_runtime(profile, profile / "fonts.conf", env, repo)
                explicit = build.capture_runtime(profile, profile / "fonts.conf", dict(env, PKG_CONFIG="pkg-config"), repo)
            self.assertNotEqual(plain["build_environment_sha256"], explicit["build_environment_sha256"])

    def test_fontconfig_includes_are_rejected_before_tool_probes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            profile, repo, env = self.runtime_fixture(root)
            for include in ["<include>/tmp/uncaptured.conf</include>",
                            '<include ignore_missing="yes">optional.conf</include>',
                            '<x:include xmlns:x="urn:fixture">external.conf</x:include>']:
                with self.subTest(include=include):
                    config = profile / "fonts.conf"
                    config.write_text("<fontconfig>" + include + "</fontconfig>")
                    with patch.object(build.subprocess, "run") as run, \
                         patch.object(build.subprocess, "check_output") as probe:
                        with self.assertRaisesRegex(RuntimeError, "XML includes are unsupported"):
                            build.capture_runtime(profile, config, env, repo)
                        with self.assertRaisesRegex(RuntimeError, "XML includes are unsupported"):
                            build.configured_fonts(config, profile / "prefix", root / "tools/fc-list", env)
                        run.assert_not_called()
                        probe.assert_not_called()

    def test_changed_source_during_build_never_writes_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "manifest.json"
            with self.assertRaisesRegex(RuntimeError, "changed during build"):
                build.write_build_manifest(path, {"head": "before"}, {"head": "after"}, path, {}, [])
            self.assertFalse(path.exists())

    def test_matching_build_is_deterministic_and_does_not_approve_oracles(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "app"
            binary.write_bytes(b"native executable fixture")
            source = {"head": "same", "tracked_patch_sha256": "fixed"}
            first = build.write_build_manifest(root / "first.json", source, source, binary, {}, ["compiler", "build"])
            second = build.write_build_manifest(root / "second.json", source, source, binary, {}, ["compiler", "build"])
            self.assertEqual(first, second)
            self.assertEqual(first["mode"], "built")
            self.assertNotIn("golden", first)
            self.assertNotIn("expected_text", first)
            self.assertEqual((root / "first.json").read_bytes(), (root / "second.json").read_bytes())

    def test_bound_mode_never_claims_compilation(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "app"
            binary.write_bytes(b"supplied executable")
            with patch.object(build, "capture_source", return_value={"repo": str(root)}):
                result = build.make_bound_manifest(root, binary, {})
            self.assertEqual(result["mode"], "bound")
            self.assertIn("not established", result["source_claim"])
            self.assertEqual(result["command"], [])

    def test_runtime_file_change_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            file = Path(temporary) / "font"
            file.write_bytes(b"first")
            runtime = {"files": [build.file_identity(file)], "generated_protocols": [], "trees": []}
            file.write_bytes(b"changed")
            with self.assertRaisesRegex(RuntimeError, "runtime file changed"):
                build.verify_runtime(runtime)

    def test_runtime_tree_detects_added_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            tree = Path(temporary)
            (tree / "first").write_text("font")
            runtime = {"files": [], "generated_protocols": [], "trees": [{"path": str(tree), "sha256": build.tree_digest(tree)}]}
            (tree / "added").write_text("different font")
            with self.assertRaisesRegex(RuntimeError, "runtime tree changed"):
                build.verify_runtime(runtime)

    def test_matching_runtime_snapshots_accept_equal_values(self):
        before = {"files": [{"path": "/tmp/compiler", "sha256": "same"}], "trees": []}
        after = json.loads(json.dumps(before))
        self.assertIsNone(build.require_matching_runtime(before, after))

    def test_runtime_snapshot_drift_is_rejected_for_every_identity_kind(self):
        before = {"files": [], "trees": [], "versions": {}, "generated_protocols": [],
                  "compiler_command": ["cc"], "build_environment_sha256": "same"}
        replacements = {"files": [{"sha256": "changed compiler or font"}],
                        "trees": [{"sha256": "changed prefix or core"}],
                        "versions": {"cc": "changed version"},
                        "generated_protocols": [{"sha256": "changed generated protocol"}],
                        "compiler_command": ["other-cc"],
                        "build_environment_sha256": "changed flags"}
        for key, value in replacements.items():
            with self.subTest(identity=key):
                after = dict(before, **{key: value})
                with self.assertRaisesRegex(RuntimeError, "runtime changed during build"):
                    build.require_matching_runtime(before, after)

    def test_configured_font_inventory_addition_is_rejected(self):
        runtime = {"fontconfig": "/tmp/config", "prefix": "/tmp/prefix", "files": [
            {"role": "tool:fc-list", "path": "/tmp/fc-list", "sha256": "a", "size": 1},
            {"role": "configured-font", "path": "/tmp/font", "sha256": "b", "size": 1}],
            "generated_protocols": [], "trees": []}
        with patch.object(build, "file_identity", side_effect=lambda p: next({k: v for k, v in row.items() if k != "role"} for row in runtime["files"] if row["path"] == p)), patch.object(build, "configured_fonts", return_value=[*runtime["files"][1:], {"path": "/tmp/added"}]):
            with self.assertRaisesRegex(RuntimeError, "font inventory changed"):
                build.verify_runtime(runtime)


if __name__ == "__main__":
    unittest.main()
