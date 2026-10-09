"""Build and run the isolated native owner-ID allocator race test."""

from __future__ import annotations

import platform
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


@unittest.skipIf(platform.system() == "Windows", "pthread test runs in Linux CI")
class AccessibilityOwnerIdAllocatorTests(unittest.TestCase):
    def test_native_allocator_is_concurrent_unique_and_never_reuses(self) -> None:
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler, "a C11 compiler is required for this test")
        source = ROOT / "tests/native/accessibility_owner_id_allocator_test.c"

        with tempfile.TemporaryDirectory(prefix="gpui-owner-id-") as temporary:
            executable = Path(temporary) / "owner-id-test"
            compile_result = subprocess.run(
                [
                    compiler,
                    "-std=c11",
                    "-O2",
                    "-Wall",
                    "-Wextra",
                    "-Werror",
                    "-pthread",
                    str(source),
                    "-o",
                    str(executable),
                ],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                compile_result.returncode,
                0,
                compile_result.stdout + compile_result.stderr,
            )
            run_result = subprocess.run(
                [str(executable)],
                cwd=ROOT,
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(
                run_result.returncode,
                0,
                run_result.stdout + run_result.stderr,
            )
            self.assertIn("tests passed", run_result.stdout)
