"""Exercise the real build entrypoint with mocked compilers, never a desktop.

Run with /bin/bash so macOS exercises its system Bash, including Bash 3.2.
These tests validate shell argument handling, not native compilation or IME.
"""

import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "script" / "build_and_run.sh"
MOCK_TOOL = r'''
import hashlib
import json
import os
from pathlib import Path
import sys

name, args = Path(sys.argv[0]).name, sys.argv[1:]
if name == "uname":
    assert args == ["-s"], args
    print("Darwin")
elif name == "shasum":
    assert args[:2] == ["-a", "256"], args
    path = Path(args[2])
    print(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + str(path))
else:
    with open(os.environ["GPUI_MOCK_CALLS"], "a", encoding="utf-8") as stream:
        stream.write(json.dumps([name, *args]) + "\n")
    if name == "xcrun":
        assert args[0] == "clang", args
        Path(args[args.index("-o") + 1]).write_bytes(b"mock dylib")
    elif name == "moon":
        assert args[0] == "build", args
        target = Path(args[args.index("--target-dir") + 1])
        package = args[-1]
        output = target / "native/debug/build" / package / (Path(package).name + ".exe")
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(b"mock executable; never launched\n")
        output.chmod(0o755)
    else:
        raise AssertionError("unexpected mocked command: " + name)
'''


class BuildEntrypointTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="gpui-build-entrypoint-")
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name).resolve()
        self.root = base / "checkout with spaces"
        (self.root / "script").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.root / "script/build_and_run.sh")
        self.tools = base / "tools"
        self.tools.mkdir()
        for name in ("uname", "xcrun", "moon", "shasum"):
            tool = self.tools / name
            tool.write_text("#!" + sys.executable + "\n" + MOCK_TOOL, encoding="utf-8")
            tool.chmod(0o755)
        self.calls = base / "calls.jsonl"
        self.target = base / "build with spaces"
        self.env = {key: value for key, value in os.environ.items()
                    if not key.startswith("GPUI_") and key not in ("BASH_ENV", "ENV")}
        self.env.update({"PATH": str(self.tools) + os.pathsep + os.environ.get("PATH", ""),
                         "GPUI_MOCK_CALLS": str(self.calls),
                         "GPUI_FIELD_MACOS_SOURCE_REVISION": "1" * 40,
                         "GPUI_FIELD_MACOS_SOURCE_TREE": "2" * 40})

    def run_build(self, demo, hooks=False):
        command = ["/bin/bash", str(self.root / "script/build_and_run.sh"),
                   "--build", "--demo", demo, "--target-dir", str(self.target)]
        if hooks:
            command.append("--test-hooks")
        result = subprocess.run(command, cwd=self.root, env=self.env,
                                text=True, capture_output=True, timeout=20)
        calls = ([json.loads(line) for line in self.calls.read_text().splitlines()]
                 if self.calls.exists() else [])
        return result, calls

    def assert_build(self, demo, hooks):
        result, calls = self.run_build(demo, hooks)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        app = "GpuiNative" if demo == "quad" else "GpuiTextField"
        package = "examples/native_macos" if demo == "quad" else "examples/macos_text_field"
        bundle = self.target / "macos" / (app + ".app")
        flags = ["-dynamiclib", "-fobjc-arc", "-Wall", "-Wextra", "-Werror"]
        if hooks:
            flags.append("-DGPUI_TESTING")
        self.assertEqual(calls, [
            ["xcrun", "clang", *flags, "platform/macos/native.m",
             "platform/macos_text/core_text.c", "-framework", "AppKit",
             "-framework", "QuartzCore", "-framework", "Metal",
             "-framework", "CoreText", "-framework", "CoreGraphics", "-o",
             str(bundle / "Contents/Frameworks/libgpui_macos.dylib")],
            ["moon", "build", "--target", "native", "--deny-warn",
             "--target-dir", str(self.target), package],
        ])
        self.assertEqual(result.stdout.strip(), str(bundle))
        self.assertTrue((bundle / "Contents/MacOS" / app).is_file())
        plist = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        self.assertEqual(plist["CFBundleExecutable"], app)

    def test_quad_build_without_test_hooks(self):
        self.assert_build("quad", False)

    def test_text_field_build_without_test_hooks(self):
        self.assert_build("text-field", False)

    def test_text_field_build_with_test_hooks(self):
        self.assert_build("text-field", True)

    def test_quad_rejects_test_hooks_before_compiling(self):
        result, calls = self.run_build("quad", True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("--test-hooks is available only for --demo text-field.", result.stderr)
        self.assertEqual(calls, [])


if __name__ == "__main__":
    unittest.main()
