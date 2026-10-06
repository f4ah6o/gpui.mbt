#!/usr/bin/env python3
"""Capture exact local build identities without approving any new output."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True

HERE = Path(__file__).resolve().parent
GENERATED_PROTOCOLS = ("xdg-shell-client-protocol.h", "xdg-shell-protocol.c",
                       "text-input-v1-client-protocol.h", "text-input-v1-protocol.c")
XKB = ("rules/evdev", "keycodes/evdev", "symbols/pc", "symbols/us", "types/complete", "compat/complete")


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(data)
    return value.hexdigest()


def canonical(data):
    return json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def file_identity(path, role=None):
    path = Path(path).resolve(strict=True)
    if not path.is_file():
        raise RuntimeError("identity requires a regular file: " + str(path))
    result = {"path": str(path), "sha256": digest(path), "size": path.stat().st_size}
    if role:
        result["role"] = role
    return result


def tree_digest(path):
    path = Path(path).resolve(strict=True)
    if not path.is_dir():
        raise RuntimeError("identity requires a directory: " + str(path))
    entries = []
    for item in sorted(path.rglob("*")):
        relative = item.relative_to(path).as_posix()
        if item.is_symlink():
            entries.append([relative, "link", os.readlink(item)])
        elif item.is_file():
            entries.append([relative, "file", digest(item)])
        elif not item.is_dir():
            raise RuntimeError("special file in identity tree: " + str(item))
    return hashlib.sha256(canonical(entries).encode()).hexdigest()


def git(repo, *arguments):
    return subprocess.check_output(["git", "-C", str(repo), *arguments], timeout=15)


def capture_source(repo):
    repo = Path(repo).resolve(strict=True)
    for entry in git(repo, "ls-files", "-v", "-z").split(b"\0"):
        if entry and (entry[:1].islower() or entry[:1] == b"S"):
            raise RuntimeError("tracked source uses assume-unchanged/skip-worktree: " + os.fsdecode(entry[2:]))
    patch = git(repo, "diff", "HEAD", "--binary", "--no-ext-diff", "--no-textconv", "--")
    untracked = []
    for name in git(repo, "ls-files", "--others", "--exclude-standard", "-z").split(b"\0"):
        if not name:
            continue
        relative = os.fsdecode(name)
        path = repo / relative
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("untracked source links/special entries require explicit handling: " + relative)
        untracked.append({"relative_path": relative, "sha256": digest(path), "size": path.stat().st_size})
    return {"repo": str(repo), "head": git(repo, "rev-parse", "HEAD").decode().strip(),
            "tree": git(repo, "rev-parse", "HEAD^{tree}").decode().strip(),
            "tracked_patch_utf8": patch.decode("utf-8"), "tracked_patch_sha256": hashlib.sha256(patch).hexdigest(),
            "status": git(repo, "status", "--porcelain").decode("utf-8"),
            "untracked_files": sorted(untracked, key=lambda row: row["relative_path"])}


def require_closed_fontconfig(fontconfig):
    """Included XML rules need a captured closure this bounded profile lacks."""
    try:
        tree = ET.parse(fontconfig)
    except ET.ParseError as error:
        raise RuntimeError("invalid captured Fontconfig XML: " + str(error)) from error
    if any(element.tag.rsplit("}", 1)[-1] == "include" for element in tree.iter()):
        raise RuntimeError("Fontconfig XML includes are unsupported; use a self-contained configuration")


def tool_command(value, role):
    words = [value] if Path(value).is_file() else shlex.split(value)
    if not words:
        raise RuntimeError("captured " + role + " command is empty")
    return words


def configured_fonts(fontconfig, prefix, fc_list, environment=None):
    require_closed_fontconfig(fontconfig)
    env = (environment or os.environ).copy()
    env["PYTHONDONTWRITEBYTECODE"] = "1"
    env["FONTCONFIG_FILE"] = str(fontconfig)
    env["FONTCONFIG_PATH"] = str(Path(fontconfig).parent)
    lib = Path(prefix) / "usr/lib/x86_64-linux-gnu"
    env["LD_LIBRARY_PATH"] = f"{lib}:{lib / 'weston'}" + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else "")
    paths = subprocess.check_output([str(fc_list), "--format", "%{file}\n"], env=env, text=True, timeout=15)
    selected = sorted(set(line for line in paths.splitlines() if line))
    if not selected or len(selected) > 2048:
        raise RuntimeError("configured font inventory is empty or exceeds the bounded profile")
    return [file_identity(path, "configured-font") for path in selected]


def capture_runtime(profile_root, fontconfig, env, repo):
    root, repo = Path(profile_root).resolve(strict=True), Path(repo).resolve(strict=True)
    prefix, moon = root / "prefix", root / "moon"
    fonts = Path(fontconfig).resolve(strict=True)
    require_closed_fontconfig(fonts)
    files = [file_identity(HERE / "profile.lock.json", "profile-lock"),
             file_identity(root / "installed.json", "installed-profile"),
             file_identity(fonts, "fontconfig")]
    versions = {}
    compiler_value = env.get("GPUI_LINUX_TEXT_CC", env.get("CC", "cc"))
    compiler_words = tool_command(compiler_value, "compiler")
    compiler_path = shutil.which(compiler_words[0], path=env["PATH"])
    pkg_config_words = tool_command(env.get("PKG_CONFIG", "pkg-config"), "pkg-config")
    pkg_config_path = shutil.which(pkg_config_words[0], path=env["PATH"])
    for role, executable, version_args in [
        ("moon", moon / "bin/moon", ["version", "--all"]),
        ("moonc", moon / "bin/moonc", ["-v"]),
        ("moonrun", moon / "bin/moonrun", ["--version"]),
        ("cc", compiler_path, compiler_words[1:] + ["--version"]),
        ("pkg-config", pkg_config_path, pkg_config_words[1:] + ["--version"]),
        ("wayland-scanner", shutil.which("wayland-scanner", path=env["PATH"]), ["--version"]),
        ("fc-list", shutil.which("fc-list", path=env["PATH"]), ["--version"]),
    ]:
        if not executable:
            raise RuntimeError("missing captured tool: " + role)
        files.append(file_identity(executable, "tool:" + role))
        result = subprocess.run([str(executable), *version_args], env=env, text=True, capture_output=True, timeout=15)
        if result.returncode:
            raise RuntimeError("version probe failed: " + role + ": " + result.stderr)
        versions[role] = (result.stdout + result.stderr).strip()
    for role, words in [("compiler", compiler_words), ("pkg-config", pkg_config_words)]:
        for argument in words[1:]:
            executable = shutil.which(argument, path=env["PATH"]) if not argument.startswith("-") else None
            if executable:
                files.append(file_identity(executable, "tool:" + role + "-wrapper-child"))
    files.append(file_identity(moon / "bin/internal/tcc", "tool:tcc"))
    for name in XKB:
        files.append(file_identity(prefix / "usr/share/X11/xkb" / name, "xkb:" + name))
    fc_list = next(row["path"] for row in files if row.get("role") == "tool:fc-list")
    files.extend(configured_fonts(fonts, prefix, fc_list, env))
    generated = [file_identity(repo / "ubuntu" / name) for name in GENERATED_PROTOCOLS]
    trees = [{"role": "moon-core", "path": str(moon / "lib/core"), "sha256": tree_digest(moon / "lib/core")},
             {"role": "native-profile", "path": str(prefix), "sha256": tree_digest(prefix)}]
    build_environment = {key: env.get(key, "") for key in ["GPUI_LINUX_TEXT_CC", "CC", "CPPFLAGS", "CFLAGS", "LDFLAGS", "PKG_CONFIG", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_SYSROOT_DIR"]}
    return {"profile_root": str(root), "prefix": str(prefix), "fontconfig": str(fonts),
            "compiler_command": compiler_words,
            "pkg_config_command": pkg_config_words,
            "build_environment_sha256": hashlib.sha256(canonical(build_environment).encode()).hexdigest(),
            "files": files, "trees": trees, "versions": versions, "generated_protocols": generated}


def verify_runtime(runtime):
    for row in runtime["files"] + runtime["generated_protocols"]:
        current = file_identity(row["path"])
        if current["sha256"] != row["sha256"] or current["size"] != row["size"]:
            raise RuntimeError("captured runtime file changed: " + row["path"])
    for row in runtime["trees"]:
        if tree_digest(row["path"]) != row["sha256"]:
            raise RuntimeError("captured runtime tree changed: " + row["path"])
    fc_list = next(row["path"] for row in runtime["files"] if row.get("role") == "tool:fc-list")
    expected_fonts = [row for row in runtime["files"] if row.get("role") == "configured-font"]
    if configured_fonts(runtime["fontconfig"], runtime["prefix"], fc_list) != expected_fonts:
        raise RuntimeError("configured font inventory changed; prepare this iteration again")


def require_matching_runtime(runtime_before, runtime_after):
    """Reject build attribution if any captured runtime identity changed."""
    if runtime_before != runtime_after:
        raise RuntimeError("runtime changed during build; no executable readiness claim written")


def manifest(source, binary, runtime, command, mode):
    return {"version": 1, "kind": "gpui-field-build", "mode": mode,
            "source": source, "source_consistent": True, "binary": file_identity(binary),
            "runtime": runtime, "command": list(map(str, command)),
            "source_claim": "compiled between matching source snapshots" if mode == "built" else
            "source identity sampled at binding; compilation attribution not established"}


def write_build_manifest(path, source_before, source_after, binary, runtime, command):
    if source_before != source_after:
        raise RuntimeError("source changed during build; no current-candidate manifest written")
    result = manifest(source_before, binary, runtime, command, "built")
    Path(path).write_text(json.dumps(result, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    return result


def make_bound_manifest(repo, binary, runtime):
    before = capture_source(repo)
    result = manifest(before, binary, runtime, [], "bound")
    if before != capture_source(repo):
        raise RuntimeError("source changed during binding")
    return result


def verify_build_manifest(path):
    result = json.loads(Path(path).read_text())
    if result.get("version") != 1 or result.get("kind") != "gpui-field-build" or result.get("mode") not in ["built", "bound"]:
        raise RuntimeError("unsupported build manifest")
    source = result["source"]
    if hashlib.sha256(source["tracked_patch_utf8"].encode()).hexdigest() != source["tracked_patch_sha256"] or capture_source(source["repo"]) != source:
        raise RuntimeError("captured source identity changed; rebuild/prepare this iteration")
    binary = file_identity(result["binary"]["path"])
    if binary["sha256"] != result["binary"]["sha256"] or binary["size"] != result["binary"]["size"]:
        raise RuntimeError("captured executable changed")
    verify_runtime(result["runtime"])
    return result
