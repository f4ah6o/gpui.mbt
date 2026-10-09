#!/usr/bin/env python3
"""Compile and link the bounded CoreText adapter on macOS."""

import os
import shlex
import subprocess
import sys


def command_words(name: str, default: str) -> list[str]:
    value = os.environ.get(name, default)
    if os.path.isfile(value):
        return [value]
    return shlex.split(value)


def main() -> int:
    compiler = command_words("CC", "cc")
    if not compiler:
        print("CC must name a C compiler", file=sys.stderr)
        return 2
    args = [*compiler, *sys.argv[1:]]
    if sys.platform == "darwin" and "-c" not in sys.argv[1:]:
        args.extend(
            ["-framework", "CoreText", "-framework", "CoreGraphics", "-framework", "CoreFoundation"]
        )
    return subprocess.run(args, check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
