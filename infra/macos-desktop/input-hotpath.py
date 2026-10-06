#!/usr/bin/env python3
"""Measure the pinned input workload through the actual macOS CoreText provider."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import urllib.parse

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WORKLOAD = REPO / "testing/input_hotpath_macos"
WORKLOAD_FILES = ["moon.mod", "moon.pkg", "main.mbt", "clock.c"]
SCOPE = "synthetic headless native input/composition/CoreText/scene CPU spans"
EXCLUDED = ["native input transport", "window-server dispatch", "GPU presentation", "scanout",
            "hardware input-to-display latency"]
OBSERVE_POLICY = "observe-only: no universal timing gate"


class HotpathError(RuntimeError):
    pass


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


common = load("gpui_linux_hotpath_common", REPO / "infra/linux-desktop/input-hotpath.py")
common.HERE = HERE
common.REPO = REPO
common.WORKLOAD = WORKLOAD
common.WORKLOAD_FILES = WORKLOAD_FILES
common.SCOPE = SCOPE
common.EXCLUDED = EXCLUDED
common.COMPILER_WRAPPER = "script/macos_text_cc.py"


def digest(path):
    return common.digest(path)


def strict_json(value):
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise HotpathError("workload emitted a duplicate JSON property")
            result[key] = item
        return result
    def reject(value):
        raise HotpathError("workload emitted a non-finite JSON number")
    try:
        return json.loads(value, object_pairs_hook=pairs, parse_constant=reject)
    except (json.JSONDecodeError, TypeError) as error:
        raise HotpathError("workload emitted malformed JSON: " + str(error)) from None


def runtime_lock():
    value = json.loads((HERE / "hotpath.lock.json").read_text())
    if value.get("repository") != "https://github.com/gpui-mbt/hotpath.mbt" or \
       value.get("published_source", {}).get("main_commit") != "87a8d8494d5e2c2b4fed2115882315ba652dc37c" or \
       value.get("published_source", {}).get("tree") != "f351f46137009ceaf864c12fd620fb8d23089c63":
        raise HotpathError("Mac workload requires the independently pinned published hotpath source")
    return value


common.runtime_lock = runtime_lock


MAC_FRAMEWORK_LINK_FLAGS = ["-framework", "Foundation", "-framework", "CoreGraphics",
                            "-framework", "CoreText"]


def workload_link_flags(workload):
    package = Path(workload) / "moon.pkg"
    text = package.read_text(encoding="utf-8")
    matches = re.findall(r'"cc-link-flags"\s*:\s*"([^"\\]*(?:\\.[^"\\]*)*)"', text)
    if len(matches) != 1:
        raise HotpathError("Mac workload must declare exactly one native final-link flag set")
    flags = shlex.split(matches[0])
    expected = ["-lm", *MAC_FRAMEWORK_LINK_FLAGS]
    if flags != expected:
        raise HotpathError("Mac workload final link must bind exactly Foundation/CoreGraphics/CoreText")
    return flags


def verify_profile(root):
    profile = load("gpui_macos_profile", HERE / "profile.py")
    profile.doctor(root)
    root = Path(root).resolve(strict=True)
    return root, digest(root / "installed.json")


def validate_font_resolution(value):
    if type(value) is not dict or set(value) != {"schema_version", "fonts"} or \
       type(value["schema_version"]) is not int or value["schema_version"] != 1 or \
       type(value["fonts"]) is not list:
        raise HotpathError("CoreText font-resolution report has an unsupported schema")
    resolved = []
    segments = set()
    for row in value["fonts"]:
        if type(row) is not dict or set(row) != {"segment", "family", "postscript_name", "file_url"} or \
           row.get("segment") not in {"latin", "japanese", "other"} or \
           not isinstance(row.get("family"), str) or not row["family"] or \
           not isinstance(row.get("postscript_name"), str) or not row["postscript_name"]:
            raise HotpathError("CoreText font-resolution identity is malformed")
        path_value = row.get("file_url")
        if row["segment"] in {"latin", "japanese"}:
            if not isinstance(path_value, str) or not path_value:
                raise HotpathError("CoreText did not report a local font file for a required script")
            parsed = urllib.parse.urlparse(path_value)
            if parsed.scheme == "file":
                if parsed.netloc not in {"", "localhost"}:
                    raise HotpathError("CoreText returned a non-local font URL")
                path_value = urllib.parse.unquote(parsed.path)
            elif parsed.scheme or not Path(path_value).is_absolute():
                raise HotpathError("CoreText font path is not an absolute local file")
            font = Path(path_value)
            if font.is_symlink() and not font.resolve(strict=True).is_file():
                raise HotpathError("CoreText font symlink does not resolve to a regular file")
            font = font.resolve(strict=True)
            if not font.is_file():
                raise HotpathError("CoreText font is not a regular file")
            segments.add(row["segment"])
            resolved.append({"segment": row["segment"], "family": row["family"],
                             "postscript_name": row["postscript_name"],
                             "path": str(font), "sha256": digest(font)})
        elif path_value is not None and not isinstance(path_value, str):
            raise HotpathError("optional CoreText font file identity is malformed")
    if not {"latin", "japanese"}.issubset(segments):
        raise HotpathError("CoreText did not resolve both Latin and Japanese font runs")
    if len({(row["segment"], row["family"], row["postscript_name"], row["path"]) for row in resolved}) != len(resolved):
        raise HotpathError("CoreText font report contains duplicate run identities")
    return {"schema_version": 1, "fonts": resolved}


def validate_font_observation(value, expected):
    current = validate_font_resolution(value)
    if current != expected:
        raise HotpathError("current CoreText font identities/bytes differ from the retained observation")
    return current


def host_identity(profile_root):
    profile = load("gpui_macos_profile_host", HERE / "profile.py")
    host = profile.host_identity()
    host["profile_lock_sha256"] = digest(HERE / "profile.lock.json")
    host["installed_profile_sha256"] = digest(Path(profile_root) / "installed.json")
    return host


def tool_identity(executable, env, version_flag="--version"):
    path = Path(executable).resolve(strict=True)
    version = subprocess.check_output([str(path), version_flag], text=True, env=env, timeout=15).strip()
    return {"resolved": str(path), "sha256": digest(path), "version": version}


def native_build_identity(env, host, staged_source, workload):
    selected = env.get("GPUI_MACOS_TEXT_CC") or env.get("CC") or "cc"
    words = [selected] if os.path.isfile(selected) else __import__("shlex").split(selected)
    if len(words) != 1:
        raise HotpathError("Mac CoreText build accepts one compiler executable, not an unbound wrapper")
    compiler = shutil.which(words[0], path=env.get("PATH"))
    if not compiler:
        raise HotpathError("effective CoreText C compiler is missing")
    compiler = str(Path(compiler).resolve(strict=True))
    if compiler != host["clang_path"] or env.get("CC") != host["clang_path"] or \
       env.get("GPUI_MACOS_TEXT_CC") != host["clang_path"]:
        raise HotpathError("effective CoreText compiler is not the pinned Xcode clang executable")
    sdkroot = Path(env.get("SDKROOT", "")).resolve(strict=True)
    if str(sdkroot) != host["sdk_path"] or env.get("DEVELOPER_DIR") != host["xcode_select_path"] or \
       env.get("MACOSX_DEPLOYMENT_TARGET") != "26.0":
        raise HotpathError("effective SDKROOT/Xcode/deployment target differs from the pinned native environment")
    framework_root = Path(host["sdk_path"]) / "System/Library/Frameworks"
    frameworks = {}
    for name in ("Foundation", "CoreGraphics", "CoreText"):
        stub = framework_root / (name + ".framework") / (name + ".tbd")
        if not stub.is_file():
            raise HotpathError("selected Xcode SDK lacks framework link stub: " + name)
        frameworks[name] = {"stub_path": str(stub.resolve()), "stub_sha256": digest(stub)}
    final_link_flags = workload_link_flags(workload)
    return {
        "compiler": tool_identity(compiler, env),
        "compiler_wrapper_path": str(staged_source / "script/macos_text_cc.py"),
        "compiler_wrapper_sha256": digest(staged_source / "script/macos_text_cc.py"),
        "frameworks": frameworks,
        "framework_link_flags": [flag for name in ("Foundation", "CoreGraphics", "CoreText")
                                 for flag in ("-framework", name)],
        "workload_final_link_flags": final_link_flags,
        "flags": {name: env.get(name, "") for name in ("CPPFLAGS", "CFLAGS", "LDFLAGS", "GPUI_MACOS_TEXT_CC",
                                                          "CC", "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
                                                          "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
                                                          "LIBRARY_PATH", "DYLD_LIBRARY_PATH")},
        "sdk_path": str(sdkroot), "sdk_version": host["sdk_version"],
        "sdk_settings_sha256": host["sdk_settings_sha256"],
        "architecture": platform.machine(), "os_product_version": host["product_version"],
    }


def stage(output, hotpath, lock_value, snapshot):
    source = output / "source"
    source.mkdir()
    entries = {}
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
                                    cwd=REPO).split(b"\0")
    for name in names:
        if not name:
            continue
        relative = Path(os.fsdecode(name))
        original = REPO / relative
        if original.is_symlink():
            target = original.resolve(strict=True)
            if not target.is_relative_to(REPO):
                raise HotpathError("external source symlink is not permitted in the profiling fixture")
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(os.path.relpath(target, original.parent))
            entries[str(relative)] = {"kind": "link", "target": str(original.readlink()),
                                      "staged_target": str(destination.readlink())}
        elif original.is_file():
            entries[str(relative)] = {"kind": "file", "sha256": digest(original)}
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, destination)
        else:
            entries[str(relative)] = {"kind": "missing"}
    library = output / "hotpath"
    for name in lock_value["runtime_files"]:
        destination = library / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(hotpath / name, destination)
    workload = output / "workload"
    shutil.copytree(WORKLOAD, workload, ignore=shutil.ignore_patterns("_build", ".mooncakes"))
    (output / "moon.work").write_text('members = ["./source", "./hotpath", "./workload"]\n')
    for package in source.rglob("moon.pkg"):
        text = package.read_text()
        package.write_text(text.replace('"script/macos_text_cc.py"',
                                        json.dumps(str(source / "script/macos_text_cc.py"))))
    package = workload / "moon.pkg"
    package.write_text(package.read_text().replace('"script/macos_text_cc.py"',
                                                   json.dumps(str(source / "script/macos_text_cc.py"))))
    return workload, entries


def parse_workload(stdout, instrumented, expected_fonts=None):
    lines = stdout.splitlines()
    font_lines = [line[len("FONT_RESOLUTION "):] for line in lines if line.startswith("FONT_RESOLUTION ")]
    if len(font_lines) != 1:
        raise HotpathError("workload must report exactly one CoreText font-resolution record")
    raw_fonts = strict_json(font_lines[0])
    fonts = validate_font_resolution(raw_fonts) if expected_fonts is None else \
        validate_font_observation(raw_fonts, expected_fonts)
    rows = [strict_json(line) for line in lines if line and not line.startswith("FONT_RESOLUTION ")]
    return common.validate_run(rows, instrumented), rows, fonts


def execute(hotpath, output, repeats=7):
    feedback = common.load_feedback()
    output = feedback.external_path(output, REPO)
    output.mkdir(parents=True, exist_ok=False)
    before = feedback.source_snapshot(REPO)
    report = {"schema_version": common.SCHEMA_VERSION, "scope": SCOPE, "excluded": EXCLUDED,
              "producer_sha256": digest(HERE / "input-hotpath.py"), "repeats": repeats,
              "source_before": before, "ok": False, "runs": [],
              "performance_policy": OBSERVE_POLICY}
    try:
        hotpath = Path(hotpath).resolve(strict=True)
        lock_value = runtime_lock()
        common.verify_hotpath(hotpath)
        profile_root, installed_hash = verify_profile(os.environ.get("GPUI_MACOS_PROFILE_ROOT"))
        report["hotpath_runtime"] = lock_value["runtime_files"]
        report["hotpath_lock"] = lock_value
        report["workload_sha256"] = common.workload_digest()
        workload, source_entries = stage(output, hotpath, lock_value, before)
        env = dict(os.environ)
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)
        env["MOON_HOME"] = str(profile_root / "moon")
        env["PATH"] = str(profile_root / "moon/bin") + os.pathsep + env.get("PATH", os.defpath)
        env["XDG_CACHE_HOME"] = str(output / "cache")
        moon = shutil.which("moon", path=env["PATH"])
        if not moon or Path(moon).resolve() != (profile_root / "moon/bin/moon").resolve():
            raise HotpathError("active Moon executable is outside the current Mac profile")
        host = host_identity(profile_root)
        native = native_build_identity(env, host, output / "source", workload)
        env_info = {"host": host, "profile_root": str(profile_root),
                    "profile_lock_sha256": digest(HERE / "profile.lock.json"),
                    "installed_profile_sha256": installed_hash,
                    "moon": run_version([moon, "version"], env),
                    "tools": {"moon": tool_identity(moon, env, "version"),
                              "moonc": tool_identity(profile_root / "moon/bin/moonc", env, "-v"),
                              "moonrun_sha256": digest(profile_root / "moon/bin/moonrun"),
                              "default_cc": native["compiler"]},
                    "native_build": native,
                    "core_module_sha256": digest(profile_root / "moon/lib/core/moon.mod")}
        report["environment"] = env_info
        command = [moon, "build", ".", "--target", "native", "--release", "--warn-list", "-27-79",
                   "--deny-warn", "--target-dir", str(output / "build")]
        with (output / "build.log").open("w") as stream:
            result = subprocess.run(command, cwd=workload, env=env, stdout=stream, stderr=subprocess.STDOUT,
                                    text=True)
        if result.returncode:
            raise HotpathError("Mac CoreText hotpath build failed; see build.log")
        binaries = list((output / "build/native/release/build").rglob("*.exe"))
        if len(binaries) != 1:
            raise HotpathError("expected exactly one Mac workload executable")
        binary = binaries[0]
        report["binary_sha256"] = digest(binary)
        report["binary_relative_path"] = binary.relative_to(output).as_posix()
        font_identity = None
        for index in range(repeats):
            for active in ([False, True] if index % 2 == 0 else [True, False]):
                name = str(index) + ("-on" if active else "-off")
                result = subprocess.run([str(binary)] + (["--instrumented"] if active else []), env=env,
                                        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=120)
                (output / (name + ".stderr")).write_text(result.stderr)
                if result.returncode:
                    raise HotpathError("Mac workload process failed: " + name)
                if len(result.stdout.encode("utf-8")) > 1024 * 1024:
                    raise HotpathError("Mac workload stdout exceeded the bounded evidence size")
                measured, rows, fonts = parse_workload(result.stdout, active)
                if font_identity is None:
                    font_identity = fonts
                elif fonts != font_identity:
                    raise HotpathError("CoreText selected different font bytes during paired observations")
                raw_name = name + ".jsonl"
                stdout_name = name + ".stdout.txt"
                (output / stdout_name).write_text(result.stdout, encoding="utf-8")
                (output / raw_name).write_text("".join(json.dumps(row, separators=(",", ":")) + "\n" for row in rows))
                report["runs"].append({"index": index, "instrumented": active, "raw_file": raw_name,
                                       "stdout_file": stdout_name, "font_resolution": fonts,
                                       "result": measured, "rows": rows})
        env_info["font_resolution"] = font_identity
        manifest = {"source_files": source_entries, "source_snapshot": before,
                    "compiler_path_override": str(output / "source/script/macos_text_cc.py"),
                    "environment": env_info}
        (output / "staging-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        signatures = {(row["result"]["checksum"], row["result"]["fingerprint"]) for row in report["runs"]}
        if len(signatures) != 1:
            raise HotpathError("instrumentation changed behavior across Mac paired runs")
        report["behavior_equal"] = True
        report["behavior_signature"] = list(next(iter(signatures)))
        report["statistics"] = common.summarize(report["runs"])
        report["artifact_hashes"] = {name: digest(output / name) for name in
            ["staging-manifest.json", report["binary_relative_path"]] +
            [name for row in report["runs"] for name in (row["raw_file"], row["stdout_file"])]}
        report["source_after"] = feedback.source_snapshot(REPO)
        report["source_stable"] = report["source_after"] == before
        report["ok"] = True
        validate_evidence(report, output)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        report["error"] = str(error)
        report["ok"] = False
    finally:
        report["source_after"] = feedback.source_snapshot(REPO)
        report["source_stable"] = report["source_after"] == before
        if not report["source_stable"]:
            report["ok"] = False
            report["error"] = "source changed during Mac hotpath profiling"
        (output / "summary.json").write_text(json.dumps(report, indent=2, allow_nan=False) + "\n")
    print("Mac CoreText hotpath " + ("passed" if report["ok"] else "failed") + ": " + str(output / "summary.json"))
    return 0 if report["ok"] else 1


def run_version(argv, env):
    return subprocess.check_output(argv, text=True, env=env, timeout=15).strip()


def validate_current_runtime(environment, directory):
    profile_root = Path(environment.get("profile_root", ""))
    if not profile_root.is_absolute():
        raise HotpathError("hotpath evidence omitted its qualified profile root")
    profile_root = profile_root.resolve(strict=True)
    profile = load("gpui_macos_hotpath_runtime_profile", HERE / "profile.py")
    profile.doctor(profile_root)
    env = profile.profile_environment(profile_root)
    env["MOON_HOME"] = str(profile_root / "moon")
    env["XDG_CACHE_HOME"] = str(Path(directory) / "cache")
    host = host_identity(profile_root)
    staged_source = Path(directory) / "source"
    native = native_build_identity(env, host, staged_source, Path(directory) / "workload")
    moon = profile_root / "moon/bin/moon"
    moonc = profile_root / "moon/bin/moonc"
    moonrun = profile_root / "moon/bin/moonrun"
    current = {
        "host": host,
        "profile_root": str(profile_root),
        "profile_lock_sha256": digest(HERE / "profile.lock.json"),
        "installed_profile_sha256": digest(profile_root / "installed.json"),
        "moon": run_version([str(moon), "version"], env),
        "tools": {"moon": tool_identity(moon, env, "version"),
                  "moonc": tool_identity(moonc, env, "-v"),
                  "moonrun_sha256": digest(moonrun), "default_cc": native["compiler"]},
        "native_build": native,
        "core_module_sha256": digest(profile_root / "moon/lib/core/moon.mod"),
    }
    for key, value in current.items():
        if environment.get(key) != value:
            raise HotpathError("current Mac host/compiler/SDK/tool identity differs from retained evidence: " + key)
    return current


def validate_evidence(report, directory):
    """Reparse source-bound workload output, actual font files and current SDK/tool identity."""
    directory = Path(directory).resolve(strict=True)
    try:
        if type(report) is not dict or type(report.get("runs")) is not list:
            raise HotpathError("Mac CoreText evidence has no typed run inventory")
        repeats = report.get("repeats")
        if type(repeats) is not int or not 7 <= repeats <= 31 or len(report["runs"]) != repeats * 2:
            raise HotpathError("Mac CoreText run inventory is not the complete paired observation set")
        mac_runs = report["runs"]
        for row in mac_runs:
            if type(row) is not dict or set(row) != {"index", "instrumented", "raw_file", "stdout_file",
                                                     "font_resolution", "result", "rows"}:
                raise HotpathError("Mac CoreText per-run font/raw identity is malformed")
        portable = dict(report)
        portable["runs"] = [{key: row[key] for key in ("index", "instrumented", "raw_file", "result", "rows")}
                            for row in mac_runs]
        expected_portable_artifacts = {"staging-manifest.json", report["binary_relative_path"]}
        expected_portable_artifacts.update(row["raw_file"] for row in mac_runs)
        artifacts = report.get("artifact_hashes")
        if type(artifacts) is not dict:
            raise HotpathError("Mac CoreText artifact hash inventory is malformed")
        portable["artifact_hashes"] = {name: artifacts[name] for name in expected_portable_artifacts
                                       if name in artifacts}
        common.validate_evidence(portable, directory)
        expected_names = {"staging-manifest.json", report["binary_relative_path"]}
        expected_names.update(row["raw_file"] for row in mac_runs)
        expected_names.update(row["stdout_file"] for row in mac_runs)
        if set(artifacts) != expected_names:
            raise HotpathError("Mac CoreText artifact inventory is missing or contains undeclared outputs")
        for name, expected in artifacts.items():
            if not isinstance(name, str) or not isinstance(expected, str) or len(expected) != 64:
                raise HotpathError("Mac CoreText artifact hash record is malformed")
            path = common.safe_artifact(directory, name)
            if path.is_symlink() or digest(path) != expected:
                raise HotpathError("Mac CoreText retained artifact hash is stale: " + name)
        if report["environment"].get("font_resolution") is None:
            raise HotpathError("Mac CoreText evidence omitted its resolved font inventory")
        baseline_fonts = None
        expected_run_pairs = {(index, active) for index in range(repeats) for active in (False, True)}
        observed_run_pairs = set()
        for row in mac_runs:
            if type(row.get("index")) is not int or type(row.get("instrumented")) is not bool:
                raise HotpathError("Mac CoreText per-run pair identity is malformed")
            pair = (row["index"], row["instrumented"])
            if pair not in expected_run_pairs or pair in observed_run_pairs:
                raise HotpathError("Mac CoreText paired observation identity is duplicated or unexpected")
            observed_run_pairs.add(pair)
            expected_suffix = "on" if row["instrumented"] else "off"
            if row["raw_file"] != str(row["index"]) + "-" + expected_suffix + ".jsonl" or \
               row["stdout_file"] != str(row["index"]) + "-" + expected_suffix + ".stdout.txt":
                raise HotpathError("Mac CoreText output filename differs from the observation identity")
            stdout_path = common.safe_artifact(directory, row["stdout_file"])
            if stdout_path.is_symlink() or stdout_path.stat().st_size > 1024 * 1024:
                raise HotpathError("Mac CoreText raw stdout is a symlink or exceeds the bounded evidence size")
            measured, rows, fonts = parse_workload(stdout_path.read_text(encoding="utf-8"),
                                                    row["instrumented"], row["font_resolution"])
            if rows != row["rows"] or measured != row["result"] or fonts != row["font_resolution"]:
                raise HotpathError("Mac CoreText stdout differs from its parsed spans or resolved font bytes")
            if baseline_fonts is None:
                baseline_fonts = fonts
            elif fonts != baseline_fonts:
                raise HotpathError("CoreText font fallback identity changed across paired observations")
        if observed_run_pairs != expected_run_pairs or baseline_fonts != report["environment"]["font_resolution"]:
            raise HotpathError("Mac CoreText font provenance is not complete and stable across all runs")
        validate_current_runtime(report["environment"], directory)
        return report
    except (RuntimeError, KeyError, TypeError, ValueError, OSError, subprocess.SubprocessError) as error:
        raise HotpathError(str(error)) from None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hotpath-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=7)
    args = parser.parse_args(argv)
    if not 7 <= args.repeats <= 31:
        parser.error("repeats must be between 7 and 31")
    return execute(args.hotpath_root, args.output, args.repeats)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print("macos-input-hotpath: " + str(error), file=sys.stderr)
        sys.exit(1)
