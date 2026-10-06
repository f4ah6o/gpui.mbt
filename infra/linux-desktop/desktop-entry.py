#!/usr/bin/env python3
"""Install/remove only this profile's opt-in native desktop test launcher."""

import argparse
import os
from pathlib import Path
import shlex
import tempfile

HERE = Path(__file__).resolve().parent
OWNER = "# Managed by gpui-linux-desktop-v1"
ENTRY_NAME = "gpui-linux-desktop-input.desktop"


def desktop_quote(value):
    # Desktop Entry Exec quoting is not shell quoting; percent escapes fields.
    value = str(value).replace("%", "%%")
    for character in ["\\", '"', "`", "$"]:
        value = value.replace(character, "\\" + character)
    return '"' + value + '"'


def write_owned(path, content, mode):
    if path.exists() and OWNER not in path.read_text():
        raise RuntimeError("refusing to replace an unrelated launcher: " + str(path))
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        stream.write(content)
        temporary = Path(stream.name)
    try:
        temporary.chmod(mode)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def remove_owned(path):
    if path.exists():
        if OWNER not in path.read_text():
            raise RuntimeError("refusing to remove an unrelated launcher: " + str(path))
        path.unlink()


def install(root, applications, runner, arguments):
    if not runner.is_file():
        raise RuntimeError("missing runner: " + str(runner))
    if not arguments:
        raise RuntimeError("supply the runner's explicit arguments after --")
    launcher = root / "launchers/run-isolated-input.sh"
    log = root / "logs/input-e2e-XXXXXX.log"
    prefix = root / "prefix"
    lib = prefix / "usr/lib/x86_64-linux-gnu"
    script = "\n".join([
        "#!/bin/sh", OWNER, "set -eu",
        "mkdir -p " + shlex.quote(str(log.parent)),
        "log=$(mktemp " + shlex.quote(str(log)) + ")",
        "export LD_LIBRARY_PATH=" + shlex.quote(f"{lib}:{lib / 'weston'}") + '${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}',
        "export PATH=" + shlex.quote(str(prefix / "usr/bin")) + ':"$PATH"',
        "export WESTON_DATA_DIR=" + shlex.quote(str(prefix / "usr/share/weston")),
        "unset WAYLAND_SOCKET",
        "exec python3 -u " + shlex.join([str(runner), *arguments]) + ' > "$log" 2>&1',
        "",
    ])
    entry = "\n".join([
        "[Desktop Entry]", OWNER, "Version=1.0", "Type=Application",
        "Name=GPUI Isolated Input Benchmark",
        "Comment=Run an explicit authenticated private-display GPUI test",
        "Exec=" + desktop_quote(launcher), "Terminal=false",
        "Categories=Development;", "StartupNotify=false", "",
    ])
    local_entry = root / "launchers" / ENTRY_NAME
    installed_entry = applications / ENTRY_NAME
    # Refuse every conflicting destination before modifying either one.
    for path in [launcher, local_entry, installed_entry]:
        if path.exists() and OWNER not in path.read_text():
            raise RuntimeError("unrelated existing launcher: " + str(path))
    write_owned(launcher, script, 0o755)
    write_owned(local_entry, entry, 0o755)
    write_owned(installed_entry, entry, 0o755)
    print("Installed: " + str(installed_entry))
    print("File Manager launch fallback: open " + str(local_entry))
    print("Per-run output: " + str(log.parent / "input-e2e-*.log"))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--runner", type=Path, default=HERE / "os-input-e2e.py")
    parser.add_argument("--applications-dir", type=Path,
                        default=Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "applications")
    parser.add_argument("action", choices=["install", "remove"])
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    root = args.root.expanduser().resolve()
    applications = args.applications_dir.expanduser().resolve()
    runner = args.runner.expanduser().resolve()
    if root == Path("/") or root == Path.home():
        raise RuntimeError("choose a dedicated private profile root")
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    if args.action == "install":
        install(root, applications, runner, arguments)
    else:
        for path in [applications / ENTRY_NAME, root / "launchers" / ENTRY_NAME,
                     root / "launchers/run-isolated-input.sh"]:
            remove_owned(path)
        print("Removed this profile's launcher. No test process or other desktop setting was changed.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(str(error))
