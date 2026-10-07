#!/usr/bin/env python3
"""Compile/link the bounded macOS CoreText provider with Darwin-only frameworks."""

import os
import platform
import shlex
import subprocess
import sys


def words(name: str, default: str = "") -> list[str]:
    value = os.environ.get(name, default)
    if os.path.isfile(value):
        return [value]
    return shlex.split(value)


def main() -> int:
    compiler = words("GPUI_MACOS_TEXT_CC", os.environ.get("CC", "cc"))
    if not compiler:
        print("GPUI_MACOS_TEXT_CC must name a compiler", file=sys.stderr)
        return 2
    cppflags = words("CPPFLAGS")
    cflags = words("CFLAGS")
    ldflags = words("LDFLAGS")
    frameworks: list[str] = []
    # Moon invokes the package compiler for both standalone object compilation
    # and final linking. Framework flags are link inputs and trigger clang
    # warnings (or -Werror failures) on `-c` compile calls.
    compiling_only = any(
        flag in sys.argv[1:] for flag in ("-c", "-S", "-E", "-fsyntax-only")
    )
    if platform.system() == "Darwin" and not compiling_only:
        frameworks = [
            "-framework", "Foundation",
            "-framework", "CoreGraphics",
            "-framework", "CoreText",
        ]
    return subprocess.run(
        [*compiler, *cppflags, *sys.argv[1:], *cflags, *ldflags, *frameworks],
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
