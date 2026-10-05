#!/usr/bin/env python3
"""Compile Linux text FFI files with distro pkg-config discovery."""

import os
import shlex
import subprocess
import sys


def environment_words(name: str, default: str = "") -> list[str]:
    value = os.environ.get(name, default)
    # Preserve a compiler/pkg-config executable path that itself contains
    # spaces; shlex still supports the conventional `ccache cc` form.
    if os.path.isfile(value):
        return [value]
    return shlex.split(value)


def pkg_config(*args: str) -> list[str]:
    pkg_config_command = environment_words("PKG_CONFIG", "pkg-config")
    if not pkg_config_command:
        raise FileNotFoundError("PKG_CONFIG is empty")
    result = subprocess.run(
        [*pkg_config_command, *args, "pangoft2", "fontconfig"],
        check=True,
        capture_output=True,
        text=True,
    )
    return shlex.split(result.stdout)


def main() -> int:
    compiler = environment_words(
        "GPUI_LINUX_TEXT_CC", os.environ.get("CC", "cc")
    )
    if not compiler:
        print("GPUI_LINUX_TEXT_CC must name a compiler", file=sys.stderr)
        return 2
    try:
        cflags = pkg_config("--cflags")
        libraries = pkg_config("--libs")
    except (subprocess.CalledProcessError, FileNotFoundError) as error:
        print(
            "Linux text measurement requires pkg-config metadata for "
            "pangoft2 and fontconfig. Install the development packages first.",
            file=sys.stderr,
        )
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr.rstrip(), file=sys.stderr)
        return 2
    cppflags = environment_words("CPPFLAGS")
    user_cflags = environment_words("CFLAGS")
    ldflags = environment_words("LDFLAGS")
    return subprocess.run(
        [*compiler, *cflags, *cppflags, *sys.argv[1:], *user_cflags, *ldflags, *libraries],
        check=False,
    ).returncode


if __name__ == "__main__":
    raise SystemExit(main())
