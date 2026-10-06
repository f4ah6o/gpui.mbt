import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import tarfile
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "gpui-desktop.py"
spec = importlib.util.spec_from_file_location("desktop", SCRIPT)
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)


class ProfileTests(unittest.TestCase):
    def test_lock_has_exact_official_urls_and_unique_archives(self):
        data = desktop.profile()
        items = data["packages"] + data["toolchain"]["archives"]
        self.assertEqual(len({item["archive"] for item in items}), len(items))
        for item in items:
            self.assertRegex(item["sha256"], r"^[a-f0-9]{64}$")
            self.assertEqual(Path(item["archive"]).name, item["archive"])
            self.assertTrue(item["url"].startswith(("https://deb.debian.org/debian/pool/",
                                                    "https://cli.moonbitlang.com/")))
            self.assertNotIn("latest", item["url"])
        versions = {item["name"]: item["version"] for item in data["packages"]}
        self.assertEqual(versions["weston"], "14.0.2-1")
        self.assertEqual(versions["ibus"], "1.5.32-2")
        self.assertEqual(versions["mozc-server"], "2.29.5160.102+dfsg-1.4")
        self.assertEqual(versions["xvfb"], "2:21.1.16-1.3+deb13u3")
        self.assertEqual(versions["xserver-common"], versions["xvfb"])
        self.assertIn("libxtst6", versions)
        self.assertEqual(versions["fonts-dejavu-extra"], "2.37-8")

    def test_valid_offline_cache_avoids_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.deb"
            path.write_bytes(b"locked bytes")
            item = {"archive": path.name, "sha256": desktop.digest(path), "url": "https://example.invalid/"}
            with patch.object(desktop, "run") as run:
                self.assertEqual(desktop.fetch(item, path.parent, offline=True), path)
                run.assert_not_called()

    def test_corrupt_cache_never_extracts_offline(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.deb"
            path.write_bytes(b"changed")
            item = {"archive": path.name, "sha256": hashlib.sha256(b"expected").hexdigest()}
            with self.assertRaisesRegex(RuntimeError, "corrupt offline"):
                desktop.fetch(item, path.parent, offline=True)

    def test_download_hash_mismatch_keeps_old_cache_and_cleans_partial(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "test.deb"
            path.write_bytes(b"old")
            item = {"archive": path.name, "sha256": hashlib.sha256(b"expected").hexdigest(), "url": "https://example.invalid/"}
            def fake_download(command):
                Path(command[command.index("--output") + 1]).write_bytes(b"wrong")
            with patch.object(desktop, "run", side_effect=fake_download):
                with self.assertRaisesRegex(RuntimeError, "SHA-256 mismatch"):
                    desktop.fetch(item, path.parent)
            self.assertEqual(path.read_bytes(), b"old")
            self.assertFalse(path.with_name("test.deb.partial").exists())

    def test_tar_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            archive = Path(temporary) / "bad.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                member = tarfile.TarInfo("../escape")
                member.size = 1
                tar.addfile(member, io.BytesIO(b"x"))
            with self.assertRaises(tarfile.TarError):
                desktop.untar(archive, Path(temporary) / "out")
            self.assertFalse((Path(temporary) / "escape").exists())

    def test_native_environment_handles_spaces_and_keeps_real_display(self):
        with patch.dict(os.environ, {"DISPLAY": ":7", "PATH": "/usr/bin", "HOME": "/home/example"}, clear=True):
            env = desktop.native_environment(Path("/tmp/a root"))
        self.assertEqual(env["DISPLAY"], ":7")
        self.assertEqual(env["HOME"], "/home/example")
        self.assertIn("'-I/tmp/a root/prefix/usr/include'", env["CPPFLAGS"])
        self.assertEqual(env["MOON_HOME"], "/tmp/a root/moon")

    def test_build_runtime_snapshots_bracket_compile_and_write_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, repo = base / "profile", base / "repo"
            root.mkdir()
            repo.mkdir()
            binary = root / "build/native/debug/build/examples/linux_text_field/field.exe"
            order = []
            source = {"repo": str(repo), "head": "fixture"}
            runtime = {"identity": "stable"}

            def fake_run(command, **kwargs):
                if command[0] == "sh":
                    order.append("prepare-protocols")
                else:
                    order.append("compile")
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"fixture executable")

            def capture_runtime(*args):
                order.append("capture-runtime")
                return dict(runtime)

            with patch.object(desktop, "run", side_effect=fake_run), \
                 patch.object(desktop.build_manifest, "capture_source", return_value=source), \
                 patch.object(desktop.build_manifest, "capture_runtime", side_effect=capture_runtime), \
                 patch("sys.stdout", new=io.StringIO()):
                desktop.build(SimpleNamespace(repo=repo, output_dir=None), root)
            self.assertEqual(order, ["prepare-protocols", "capture-runtime", "compile", "capture-runtime"])
            recorded = json.loads((root / "field-build.json").read_text())
            self.assertEqual(recorded["runtime"], runtime)
            self.assertEqual(recorded["binary"]["sha256"], desktop.digest(binary))
            self.assertEqual((root / "field-binary.txt").read_text(), str(binary) + "\n")

    def test_build_runtime_drift_removes_stale_readiness_and_never_writes_new_claim(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, repo = base / "profile", base / "repo"
            root.mkdir()
            repo.mkdir()
            for name in ["field-build.json", "field-binary.txt"]:
                (root / name).write_text("stale readiness")
            binary = root / "build/native/debug/build/examples/linux_text_field/field.exe"

            def fake_run(command, **kwargs):
                if command[0] != "sh":
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"fixture executable")

            with patch.object(desktop, "run", side_effect=fake_run), \
                 patch.object(desktop.build_manifest, "capture_source", return_value={"repo": str(repo)}), \
                 patch.object(desktop.build_manifest, "capture_runtime", side_effect=[{"compiler": "before"}, {"compiler": "after"}]), \
                 patch.object(desktop.build_manifest, "write_build_manifest") as write:
                with self.assertRaisesRegex(RuntimeError, "runtime changed during build"):
                    desktop.build(SimpleNamespace(repo=repo, output_dir=None), root)
                write.assert_not_called()
            self.assertFalse((root / "field-build.json").exists())
            self.assertFalse((root / "field-binary.txt").exists())

    def test_failed_prebuild_runtime_capture_stops_compilation_without_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, repo = base / "profile", base / "repo"
            root.mkdir()
            repo.mkdir()
            for name in ["field-build.json", "field-binary.txt"]:
                (root / name).write_text("stale readiness")
            with patch.object(desktop, "run") as run, \
                 patch.object(desktop.build_manifest, "capture_source", return_value={"repo": str(repo)}), \
                 patch.object(desktop.build_manifest, "capture_runtime", side_effect=RuntimeError("missing captured tool")):
                with self.assertRaisesRegex(RuntimeError, "missing captured tool"):
                    desktop.build(SimpleNamespace(repo=repo, output_dir=None), root)
                self.assertEqual(run.call_count, 1)
                self.assertEqual(run.call_args.args[0][0], "sh")
            self.assertFalse((root / "field-build.json").exists())
            self.assertFalse((root / "field-binary.txt").exists())

    def test_explicit_build_manifest_preserves_prior_profile_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, repo = base / "profile", base / "repo"
            root.mkdir()
            repo.mkdir()
            for name in ["field-build.json", "field-binary.txt"]:
                (root / name).write_text("preserved readiness")
            manifest = base / "results/new-build.json"
            binary = base / "candidate-build/native/debug/build/examples/linux_text_field/field.exe"
            def fake_run(command, **kwargs):
                if command[0] != "sh":
                    binary.parent.mkdir(parents=True)
                    binary.write_bytes(b"new executable")
            with patch.object(desktop, "run", side_effect=fake_run), \
                 patch.object(desktop.build_manifest, "capture_source", return_value={"repo": str(repo)}), \
                 patch.object(desktop.build_manifest, "capture_runtime", return_value={"identity": "stable"}), \
                 patch("sys.stdout", new=io.StringIO()):
                args = SimpleNamespace(repo=repo, output_dir=base / "candidate-build", manifest_output=manifest)
                desktop.build(args, root)
                self.assertTrue(manifest.is_file())
                self.assertEqual(json.loads(manifest.read_text())["binary"]["sha256"], desktop.digest(binary))
                for name in ["field-build.json", "field-binary.txt"]:
                    self.assertEqual((root / name).read_text(), "preserved readiness")
                with self.assertRaisesRegex(RuntimeError, "new file"):
                    desktop.build(args, root)
                args.manifest_output = repo / "manifest.json"
                with self.assertRaisesRegex(RuntimeError, "outside"):
                    desktop.build(args, root)

    def test_graphical_session_has_isolated_ibus_registry(self):
        env = desktop.graphical_environment(Path("/tmp/profile"))
        self.assertEqual(env["IBUS_COMPONENT_PATH"], "/tmp/profile/config/ibus/component")
        self.assertEqual(env["MOZC_IBUS_CANDIDATE_WINDOW"], "ibus")
        self.assertIn("x11-backend.so=/tmp/profile/prefix/usr/lib/x86_64-linux-gnu/libweston-14/x11-backend.so", env["WESTON_MODULE_MAP"])
        self.assertEqual(env["HOME"], "/tmp/profile/home")

    def test_graphical_session_preserves_verified_implicit_xauthority(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            (home / ".Xauthority").write_bytes(b"synthetic test data")
            with patch.dict(os.environ, {"HOME": str(home), "WAYLAND_SOCKET": "42"}, clear=True):
                env = desktop.graphical_environment(Path("/tmp/profile"))
            self.assertEqual(env["XAUTHORITY"], str(home / ".Xauthority"))
            self.assertNotIn("WAYLAND_SOCKET", env)
            self.assertEqual(env["HOME"], "/tmp/profile/home")

    def test_graphical_session_preserves_explicit_xauthority(self):
        with patch.dict(os.environ, {"XAUTHORITY": "/tmp/explicit-auth", "WAYLAND_SOCKET": "42"}, clear=True):
            env = desktop.graphical_environment(Path("/tmp/profile"))
        self.assertEqual(env["XAUTHORITY"], "/tmp/explicit-auth")
        self.assertNotIn("WAYLAND_SOCKET", env)

    def test_repository_and_home_are_rejected_as_install_roots(self):
        for root in [desktop.REPO, desktop.REPO / "_build/profile", Path.home(), Path("/")]:
            with self.assertRaisesRegex(RuntimeError, "outside the repository"):
                desktop.main(["--root", str(root), "env"])

    def test_denied_ipc_is_not_retried(self):
        with patch.object(desktop.socket, "socket", side_effect=PermissionError(1, "Operation not permitted")) as socket:
            with self.assertRaises(PermissionError):
                desktop.ipc_probe()
            socket.assert_called_once()

    def test_missing_doctor_tool_is_a_reportable_failed_probe(self):
        with patch.object(desktop.subprocess, "run", side_effect=FileNotFoundError("missing tool")):
            result = desktop.diagnostic_probe(["pkg-config"], {})
        self.assertEqual(result.returncode, 127)
        self.assertIn("missing tool", result.stderr)

    def test_corrupt_marker_is_repairable(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "installed.json").write_text("partial JSON")
            self.assertFalse(desktop.locked_install_ready(root))
            (root / "installed.json").write_text(json.dumps({"lock_sha256": desktop.digest(desktop.LOCK)}))
            self.assertTrue(desktop.locked_install_ready(root))

    def test_unowned_prefix_is_never_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "prefix").mkdir()
            user_file = root / "prefix/user-file"
            user_file.write_text("keep")
            with patch.object(desktop, "fetch") as fetch:
                with self.assertRaisesRegex(RuntimeError, "unowned"):
                    desktop.main(["--root", str(root), "bootstrap", "--force"])
                fetch.assert_not_called()
            self.assertEqual(user_file.read_text(), "keep")

    def test_failed_forced_repair_invalidates_old_readiness(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ["prefix", "moon"]:
                (root / name).mkdir()
            (root / ".gpui-desktop-profile").write_text("gpui-linux-desktop-v1\n")
            marker = root / "installed.json"
            marker.write_text(json.dumps({"lock_sha256": desktop.digest(desktop.LOCK)}))
            (root / "field-binary.txt").write_text("old-binary")
            def fake_unpack(archive, destination):
                (destination / "bin").mkdir(exist_ok=True)
                (destination / "bin/moon").write_text("stub")
            def fail_bundle(command, **kwargs):
                if "bundle" in command:
                    raise RuntimeError("simulated bundle failure")
            with patch.object(desktop, "fetch", return_value=root / "archive"), patch.object(desktop, "untar", side_effect=fake_unpack), patch.object(desktop, "run", side_effect=fail_bundle):
                with self.assertRaisesRegex(RuntimeError, "simulated bundle"):
                    desktop.main(["--root", str(root), "bootstrap", "--force"])
            self.assertFalse(marker.exists())
            self.assertFalse((root / "field-binary.txt").exists())
            self.assertFalse(desktop.locked_install_ready(root))

    def test_bootstrap_verify_only_checks_all_items_without_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(desktop, "fetch", return_value=root / "archive") as fetch, patch.object(desktop, "run") as run:
                desktop.main(["--root", str(root), "bootstrap", "--verify-only", "--offline"])
                self.assertEqual(fetch.call_count, len(desktop.profile()["packages"]) + 2)
                run.assert_not_called()
            self.assertFalse((root / "prefix").exists())


if __name__ == "__main__":
    unittest.main()
