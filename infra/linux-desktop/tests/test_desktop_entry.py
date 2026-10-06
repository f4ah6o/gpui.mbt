import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "desktop-entry.py"
spec = importlib.util.spec_from_file_location("entry", SCRIPT)
entry = importlib.util.module_from_spec(spec)
spec.loader.exec_module(entry)


class DesktopEntryTests(unittest.TestCase):
    def test_idempotent_install_and_remove(self):
        with tempfile.TemporaryDirectory(prefix="entry space-") as temporary:
            root = Path(temporary) / "profile"
            applications = Path(temporary) / "apps"
            runner = Path(temporary) / "runner.py"
            runner.write_text("# test stub\n")
            arguments = ["--output", "/tmp/a space/output", "--value", "a'quoted value"]
            entry.install(root, applications, runner, arguments)
            before = (applications / entry.ENTRY_NAME).read_text()
            entry.install(root, applications, runner, arguments)
            self.assertEqual(before, (applications / entry.ENTRY_NAME).read_text())
            script = root / "launchers/run-isolated-input.sh"
            subprocess.run(["sh", "-n", str(script)], check=True)
            self.assertNotIn("autostart", before)
            self.assertIn("unset WAYLAND_SOCKET", script.read_text())
            entry.main(["--root", str(root), "--applications-dir", str(applications), "remove"])
            self.assertFalse((applications / entry.ENTRY_NAME).exists())
            self.assertFalse(script.exists())

    def test_unrelated_entry_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "profile"
            apps = Path(temporary) / "apps"
            apps.mkdir()
            target = apps / entry.ENTRY_NAME
            target.write_text("[Desktop Entry]\nName=User's existing app\n")
            with self.assertRaisesRegex(RuntimeError, "unrelated"):
                entry.install(root, apps, SCRIPT, ["--help"])
            self.assertFalse((root / "launchers").exists())
            self.assertIn("User's existing", target.read_text())

    def test_unrelated_entry_is_not_removed(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "entry"
            target.write_text("unrelated data")
            with self.assertRaisesRegex(RuntimeError, "unrelated"):
                entry.remove_owned(target)
            self.assertTrue(target.exists())

    def test_exec_quoting_escapes_fields_and_metacharacters(self):
        quoted = entry.desktop_quote('/tmp/a $value "quoted" %f')
        self.assertIn("%%f", quoted)
        self.assertIn('\\"quoted\\"', quoted)
        self.assertIn('\\$value', quoted)


if __name__ == "__main__":
    unittest.main()
