#!/usr/bin/env python3
"""Opt-in real hotpath.mbt profiling of a fixed headless native input workload."""

import argparse
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import statistics
import subprocess
import sys

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
WORKLOAD = REPO / "testing/input_hotpath"
SCHEMA_VERSION = 2
SCOPE = "synthetic headless native input/composition/Pango/scene CPU spans"
EXCLUDED = ["native input transport", "Wayland dispatch", "GPU presentation", "scanout", "hardware input-to-display latency"]
OBSERVE_POLICY = "observe-only: no universal timing gate"
WORKLOAD_FILES = ["moon.mod", "moon.pkg", "main.mbt", "clock.c"]
EXPECTED_CALLS = {"text.measure": 256, "text.admit": 256,
                  "composition.update": 64, "composition.commit": 32,
                  "history.undo": 32, "history.redo": 32,
                  "composition.cancel": 32, "input.handle": 32,
                  "scene.paint": 32, "scene.build": 32}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def runtime_lock():
    return json.loads((HERE / "hotpath.lock.json").read_text())


def workload_digest():
    if retained_files(WORKLOAD) != set(WORKLOAD_FILES):
        raise RuntimeError("workload source inventory must be exactly the four declared fixture files")
    return hashlib.sha256(b"".join((WORKLOAD / name).read_bytes() for name in WORKLOAD_FILES)).hexdigest()


def retained_files(directory):
    return {path.relative_to(directory).as_posix() for path in directory.rglob("*")
            if (path.is_file() or path.is_symlink()) and
            not any(part in {"_build", ".mooncakes"} for part in path.relative_to(directory).parts)}


def environment_words(env, name, default=""):
    # Match script/linux_text_cc.py exactly, including paths containing spaces.
    value = env.get(name, default)
    return [value] if os.path.isfile(value) else shlex.split(value)


def tool_identity(command, env, version_flag="--version"):
    if len(command) != 1:
        raise RuntimeError("profiling supports one executable per compiler/discovery command; wrapper commands are unsupported")
    selected = shutil.which(command[0], path=env.get("PATH"))
    if not selected:
        raise RuntimeError("effective native tool is unavailable: " + command[0])
    path = Path(selected).resolve()
    version = subprocess.check_output([str(path), version_flag], text=True, env=env).strip()
    return {"command": command, "resolved": str(path), "sha256": digest(path), "version": version}


def native_build_identity(env):
    compiler = environment_words(env, "GPUI_LINUX_TEXT_CC", env.get("CC", "cc"))
    discovery = environment_words(env, "PKG_CONFIG", "pkg-config")
    identity = {"compiler": tool_identity(compiler, env), "pkg_config": tool_identity(discovery, env),
                "wrapper_sha256": digest(REPO / "script/linux_text_cc.py"),
                "flags": {name: environment_words(env, name) for name in ["CPPFLAGS", "CFLAGS", "LDFLAGS"]},
                "discovery_environment": {name: env.get(name) for name in
                    ["PKG_CONFIG_SYSROOT_DIR", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_PATH"]}}
    def query(*args):
        return subprocess.check_output([*discovery, *args, "pangoft2", "fontconfig"], text=True, env=env).strip()
    subprocess.run([*discovery, "--atleast-version=1.50", "pangoft2"], env=env, check=True)
    identity["package_versions"] = query("--modversion").splitlines()
    identity["package_cflags"] = shlex.split(query("--cflags"))
    identity["package_libraries"] = shlex.split(query("--libs"))
    return identity


def load_feedback():
    spec = importlib.util.spec_from_file_location("hotpath_feedback", HERE / "actrun-feedback.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_hotpath(root):
    root = Path(root).resolve()
    lock = runtime_lock()
    for name, expected in lock["runtime_files"].items():
        path = root / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise RuntimeError("hotpath runtime does not match lock: " + name)
    return lock


def verify_profile(root):
    if not root:
        raise RuntimeError("GPUI_DESKTOP_ROOT must name the already-prepared pinned profile")
    root = Path(root).resolve()
    marker = root / "installed.json"
    if not marker.is_file():
        raise RuntimeError("prepared profile marker is missing")
    installed = json.loads(marker.read_text())
    expected = json.loads((HERE / "profile.lock.json").read_text())
    if (installed.get("lock_sha256") != digest(HERE / "profile.lock.json") or
            installed.get("profile") != expected):
        raise RuntimeError("prepared profile is stale or does not match the current profile lock")
    return root, digest(marker)


def validate_run(rows, instrumented):
    allowed = {
        "result": {"kind", "instrumented", "cycles", "checksum", "fingerprint", "workload_ns",
                   "clock_resolution_ns", "observed_min_tick_ns", "backward_reads", "invalid_clocks", "dropped_samples"},
        "sample": {"kind", "label", "ns"},
        "aggregate": {"kind", "label", "calls", "total_ns", "min_ns", "max_ns", "p50_estimate_ns", "p95_estimate_ns", "total_saturated"},
        "calibration": {"kind", "calls", "span_total_ns", "full_ns", "wrapper_full_ns"},
    }
    for row in rows:
        if not isinstance(row, dict) or row.get("kind") not in allowed or set(row) != allowed[row["kind"]]:
            raise RuntimeError("unexpected metric fields; text/content must never enter metrics")
        for key, value in row.items():
            if key in {"kind", "label"}:
                continue
            if key in {"instrumented", "total_saturated"}:
                valid = type(value) is bool
            else:
                valid = type(value) is int and 0 <= value <= 9223372036854775807
                if key == "fingerprint":
                    valid = type(value) is int and 0 <= value <= 18446744073709551615
            if not valid:
                raise RuntimeError("invalid numeric metric: " + key)
    results = [row for row in rows if row.get("kind") == "result"]
    if len(results) != 1:
        raise RuntimeError("workload must report exactly one result")
    result = results[0]
    if (result["instrumented"] != instrumented or result["cycles"] != 32 or
            result["workload_ns"] <= 0 or result["clock_resolution_ns"] < 1 or
            not 0 < result["observed_min_tick_ns"] < 9223372036854775807 or
            any(result[name] != 0 for name in ["backward_reads", "invalid_clocks", "dropped_samples"])):
        raise RuntimeError("invalid workload or monotonic clock diagnostics")
    samples = [row for row in rows if row.get("kind") == "sample"]
    aggregates = [row for row in rows if row.get("kind") == "aggregate"]
    calibrations = [row for row in rows if row.get("kind") == "calibration"]
    if not instrumented:
        if samples or aggregates or calibrations:
            raise RuntimeError("disabled instrumentation emitted measurements")
        return result
    counts = {label: 0 for label in EXPECTED_CALLS}
    sums = {label: 0 for label in EXPECTED_CALLS}
    for sample in samples:
        if sample["label"] not in counts or type(sample["ns"]) is not int or not 0 <= sample["ns"] <= 9223372036854775807:
            raise RuntimeError("unknown label or invalid raw sample")
        counts[sample["label"]] += 1
        sums[sample["label"]] += sample["ns"]
    if counts != EXPECTED_CALLS or len(aggregates) != len(EXPECTED_CALLS):
        raise RuntimeError("workload did not execute exact declared span counts")
    seen = set()
    for row in aggregates:
        label = row["label"]
        raw = [sample["ns"] for sample in samples if sample["label"] == label]
        if (label not in counts or label in seen or row["calls"] != counts[label] or
                row["total_ns"] != sums[label] or row["total_saturated"]):
            raise RuntimeError("hotpath aggregates disagree with raw samples")
        if (row["min_ns"] != min(raw) or row["max_ns"] != max(raw) or
                not row["min_ns"] <= row["p50_estimate_ns"] <= row["p95_estimate_ns"] <= row["max_ns"]):
            raise RuntimeError("hotpath aggregate range disagrees with raw samples")
        seen.add(label)
    if (len(calibrations) != 1 or calibrations[0]["calls"] != 4096 or
            any(calibrations[0][name] <= 0 for name in ["full_ns", "wrapper_full_ns"])):
        raise RuntimeError("instrumentation calibration missing or invalid")
    return result


def describe(values):
    median = statistics.median(values)
    return {"median_ns": median,
            "mad_ns": statistics.median([abs(value - median) for value in values]),
            "min_ns": min(values), "max_ns": max(values), "values_ns": values}


def summarize(runs):
    plain = [run["result"]["workload_ns"] for run in runs if not run["instrumented"]]
    active = [run["result"]["workload_ns"] for run in runs if run["instrumented"]]
    calibration = [row for run in runs for row in run["rows"] if row["kind"] == "calibration"]
    labels = {}
    for label in EXPECTED_CALLS:
        # Compare repeated run means; exact per-span samples remain in JSONL.
        values = [sum(row["ns"] for row in run["rows"] if row.get("kind") == "sample" and row["label"] == label)
                  / EXPECTED_CALLS[label] for run in runs if run["instrumented"]]
        labels[label] = describe(values)
    return {"plain_workload": describe(plain), "instrumented_workload": describe(active),
            "observed_overhead_ratio": statistics.median(active) / statistics.median(plain),
            "empty_hotpath_api_ns_per_call": describe([row["full_ns"] / 4096 for row in calibration]),
            "empty_raw_wrapper_ns_per_call": describe([row["wrapper_full_ns"] / 4096 for row in calibration]),
            "labels": labels}


def safe_artifact(directory, name):
    if not isinstance(name, str) or not name or "\\" in name:
        raise RuntimeError("artifact path is malformed")
    relative = Path(name)
    if relative.is_absolute() or any(part in {".", ".."} for part in relative.parts):
        raise RuntimeError("artifact path must remain inside its retained directory")
    path = directory / relative
    if not path.resolve().is_relative_to(directory.resolve()):
        raise RuntimeError("artifact path escapes its retained directory")
    return path


def source_manifest_digest(entries):
    inputs = hashlib.sha256()
    for name, entry in sorted(entries.items()):
        inputs.update(os.fsencode(name) + b"\0")
        if entry["kind"] == "file":
            inputs.update(b"file\0" + bytes.fromhex(entry["sha256"]))
        elif entry["kind"] == "link":
            inputs.update(b"link\0" + entry["target"].encode())
        elif entry["kind"] == "missing":
            inputs.update(b"missing\0")
        else:
            raise RuntimeError("source manifest has an unknown input kind")
    return inputs.hexdigest()


def restore_compiler_path(data, directory, override=None):
    return data.replace(json.dumps(override or str(directory / "source/script/linux_text_cc.py")).encode(),
                        b'"script/linux_text_cc.py"')


def validate_evidence(report, directory):
    """Revalidate retained source, executable, raw observations and derived data."""
    try:
        return _validate_evidence(report, Path(directory))
    except (KeyError, TypeError, AttributeError, ValueError, OSError) as error:
        raise RuntimeError("malformed or missing retained hotpath evidence: " + str(error)) from None


def _validate_evidence(report, directory):
    if (type(report.get("schema_version")) is not int or report["schema_version"] != SCHEMA_VERSION or
            any(report.get(key) is not True for key in ["ok", "source_stable", "behavior_equal"])):
        raise RuntimeError("hotpath evidence requires exact typed successful schema and stable behavior")
    if report.get("scope") != SCOPE or report.get("excluded") != EXCLUDED:
        raise RuntimeError("hotpath evidence has an incompatible measured boundary")
    if report.get("producer_sha256") != digest(HERE / "input-hotpath.py"):
        raise RuntimeError("hotpath evidence has an incompatible producer")
    before = report["source_before"]
    if before != report["source_after"]:
        raise RuntimeError("hotpath source snapshot is stale or changed")
    for key, length in [("commit", 40), ("tree", 40), ("tracked_patch_sha256", 64), ("input_files_sha256", 64)]:
        if not isinstance(before.get(key), str) or not re.fullmatch("[0-9a-f]{" + str(length) + "}", before[key]):
            raise RuntimeError("hotpath source identity is malformed")
    if not isinstance(before.get("status"), str):
        raise RuntimeError("hotpath source status is malformed")
    lock = runtime_lock()
    if report["hotpath_lock"] != lock or report["hotpath_runtime"] != lock["runtime_files"]:
        raise RuntimeError("hotpath evidence has incompatible runtime pins")
    for name, expected in lock["runtime_files"].items():
        path = safe_artifact(directory, "hotpath/" + name)
        if path.is_symlink() or digest(path) != expected:
            raise RuntimeError("retained hotpath runtime bytes are stale")
    if retained_files(directory / "hotpath") != set(lock["runtime_files"]):
        raise RuntimeError("retained hotpath runtime inventory contains undeclared inputs")
    repeats = report.get("repeats")
    runs = report.get("runs")
    if type(repeats) is not int or not 7 <= repeats <= 31 or not isinstance(runs, list) or len(runs) != repeats * 2:
        raise RuntimeError("hotpath evidence has an invalid paired repetition count")
    if any(not isinstance(row, dict) or type(row.get("index")) is not int or type(row.get("instrumented")) is not bool for row in runs):
        raise RuntimeError("hotpath evidence run identities are malformed")
    if {(row["index"], row["instrumented"]) for row in runs} != {(index, active) for index in range(repeats) for active in (False, True)}:
        raise RuntimeError("hotpath evidence must retain every distinct on/off pair")
    artifacts = report["artifact_hashes"]
    expected_names = {"staging-manifest.json", report["binary_relative_path"]}
    expected_names.update(str(row["index"]) + ("-on.jsonl" if row["instrumented"] else "-off.jsonl") for row in runs)
    if not isinstance(artifacts, dict) or set(artifacts) != expected_names:
        raise RuntimeError("hotpath retained artifact inventory is incomplete")
    for name, expected in artifacts.items():
        path = safe_artifact(directory, name)
        if not isinstance(expected, str) or not re.fullmatch("[0-9a-f]{64}", expected) or path.is_symlink() or digest(path) != expected:
            raise RuntimeError("hotpath retained artifact bytes are stale: " + name)
    if report["binary_sha256"] != artifacts[report["binary_relative_path"]]:
        raise RuntimeError("hotpath binary identity does not match its retained executable")
    manifest = json.loads((directory / "staging-manifest.json").read_text())
    override = manifest["compiler_path_override"]
    if not isinstance(override, str) or not Path(override).is_absolute() or not override.endswith("/source/script/linux_text_cc.py"):
        raise RuntimeError("retained compiler-path rewrite is malformed")
    if manifest["source_snapshot"] != before:
        raise RuntimeError("hotpath retained source snapshot is stale")
    if manifest["environment"] != report["environment"]:
        raise RuntimeError("hotpath retained build environment is stale")
    entries = manifest["source_files"]
    if retained_files(directory / "source") != {name for name, entry in entries.items() if entry["kind"] != "missing"}:
        raise RuntimeError("retained source inventory contains missing or undeclared inputs")
    for name, entry in entries.items():
        path = safe_artifact(directory, "source/" + name)
        if entry["kind"] == "file":
            if path.is_symlink():
                raise RuntimeError("retained source file became a symlink")
            data = path.read_bytes()
            if name.endswith("moon.pkg"):
                data = restore_compiler_path(data, directory, override)
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise RuntimeError("retained source input is stale: " + name)
        elif entry["kind"] == "link":
            if not path.is_symlink() or str(path.readlink()) != entry["staged_target"]:
                raise RuntimeError("retained source link is stale")
        elif path.exists() or path.is_symlink():
            raise RuntimeError("retained missing source input now exists")
    if source_manifest_digest(entries) != before["input_files_sha256"]:
        raise RuntimeError("retained source manifest disagrees with its declared source snapshot")
    fixture = []
    if retained_files(directory / "workload") != set(WORKLOAD_FILES):
        raise RuntimeError("retained workload inventory contains missing or undeclared inputs")
    for name in WORKLOAD_FILES:
        data = safe_artifact(directory, "workload/" + name).read_bytes()
        fixture.append(restore_compiler_path(data, directory, override) if name == "moon.pkg" else data)
    if report["workload_sha256"] != workload_digest() or hashlib.sha256(b"".join(fixture)).hexdigest() != report["workload_sha256"]:
        raise RuntimeError("retained workload is incompatible or stale")
    for row in runs:
        name = str(row["index"]) + ("-on.jsonl" if row["instrumented"] else "-off.jsonl")
        if row["raw_file"] != name:
            raise RuntimeError("hotpath evidence raw filename is malformed")
        lines = [json.loads(line) for line in (directory / name).read_text().splitlines()]
        if lines != row["rows"] or validate_run(lines, row["instrumented"]) != row["result"]:
            raise RuntimeError("hotpath retained raw rows do not match validated results")
    signatures = {(row["result"]["checksum"], row["result"]["fingerprint"]) for row in runs}
    if len(signatures) != 1 or report["behavior_signature"] != list(next(iter(signatures))):
        raise RuntimeError("hotpath retained on/off behavior disagrees")
    if json.dumps(report["statistics"], sort_keys=True, allow_nan=False) != json.dumps(summarize(runs), sort_keys=True, allow_nan=False):
        raise RuntimeError("hotpath statistics do not equal recomputed retained observations")
    return report


def compare_baseline(current, baseline, relative_tolerance, current_directory=None, baseline_directory=None):
    if relative_tolerance is None or not math.isfinite(relative_tolerance) or relative_tolerance <= 0:
        raise RuntimeError("a baseline requires an explicit positive relative tolerance")
    if current_directory is None or baseline_directory is None:
        raise RuntimeError("a baseline comparison requires retained current and baseline artifact directories")
    validate_evidence(current, current_directory)
    validate_evidence(baseline, baseline_directory)
    for name in ["environment", "workload_sha256", "hotpath_runtime", "behavior_signature", "producer_sha256"]:
        if name not in baseline or current[name] != baseline[name]:
            raise RuntimeError("baseline is incompatible: " + name)
    regressions, comparisons = [], []
    floor = current["statistics"]["empty_raw_wrapper_ns_per_call"]["median_ns"]
    resolution = max(run["result"]["clock_resolution_ns"] for run in current["runs"])
    for label, row in current["statistics"]["labels"].items():
        try:
            old = baseline["statistics"]["labels"][label]
            if any(type(old[key]) not in {int, float} or not math.isfinite(old[key]) or old[key] < 0
                   for key in ["median_ns", "mad_ns"]):
                raise ValueError("invalid statistics")
        except (KeyError, TypeError, ValueError):
            raise RuntimeError("baseline has invalid statistics: " + label) from None
        # Six MADs of run-level means, plus measured wrapper/clock floor.
        allowance = max(old["median_ns"] * relative_tolerance,
                        6 * (old["mad_ns"] + row["mad_ns"]), floor, resolution)
        delta = row["median_ns"] - old["median_ns"]
        comparisons.append({"label": label, "delta_ns": delta, "allowance_ns": allowance})
        if delta > allowance:
            regressions.append(label)
    return {"relative_tolerance": relative_tolerance, "comparisons": comparisons,
            "regressions": regressions}


def stage(output, hotpath, lock):
    feedback = load_feedback()
    # Only source inputs; exclude caches and ignored machine-local state.
    source = output / "source"
    source.mkdir()
    entries = {}
    names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=REPO).split(b"\0")
    for name in names:
        if not name:
            continue
        relative = Path(os.fsdecode(name))
        original = REPO / relative
        if original.is_symlink():
            target = original.resolve(strict=True)
            if not target.is_relative_to(REPO):
                raise RuntimeError("external source symlink is not permitted in the profiling fixture")
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.symlink_to(os.path.relpath(target, original.parent))
            entries[str(relative)] = {"kind": "link", "target": str(original.readlink()),
                                      "staged_target": str(destination.readlink())}
            continue
        if original.is_file():
            entries[str(relative)] = {"kind": "file", "sha256": digest(original)}
            destination = source / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(original, destination)
        else:
            entries[str(relative)] = {"kind": "missing"}
    library = output / "hotpath"
    for name in lock["runtime_files"]:
        destination = library / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(hotpath / name, destination)
    # Runtime package's bench-only import needs no bench tests in this fixture.
    workload = output / "workload"
    shutil.copytree(WORKLOAD, workload,
                    ignore=shutil.ignore_patterns("_build", ".mooncakes"))
    (output / "moon.work").write_text('members = ["./source", "./hotpath", "./workload"]\n')
    # Moon resolves dependency compiler paths relative to the invocation cwd.
    for package in source.rglob("moon.pkg"):
        text = package.read_text()
        package.write_text(text.replace('"script/linux_text_cc.py"', json.dumps(str(source / "script/linux_text_cc.py"))))
    package = workload / "moon.pkg"
    package.write_text(package.read_text().replace('"script/linux_text_cc.py"', json.dumps(str(source / "script/linux_text_cc.py"))))
    return feedback, workload, entries


def execute(hotpath, output, repeats=7, baseline=None, tolerance=None):
    feedback = load_feedback()
    output = feedback.external_path(output, REPO)
    output.mkdir(parents=True, exist_ok=False)
    before = feedback.source_snapshot(REPO)
    report = {"schema_version": SCHEMA_VERSION, "scope": SCOPE, "excluded": EXCLUDED,
              "producer_sha256": digest(HERE / "input-hotpath.py"), "repeats": repeats,
              "source_before": before, "ok": False, "runs": []}
    try:
        hotpath = Path(hotpath).resolve()
        lock = verify_hotpath(hotpath)
        profile_root, installed_hash = verify_profile(os.environ.get("GPUI_DESKTOP_ROOT"))
        report["hotpath_runtime"] = lock["runtime_files"]
        report["hotpath_lock"] = lock
        report["workload_sha256"] = workload_digest()
        _, workload, source_entries = stage(output, hotpath, lock)
        env = os.environ.copy()
        env.pop("DISPLAY", None)
        env.pop("WAYLAND_DISPLAY", None)
        env["XDG_CACHE_HOME"] = str(output / "cache")
        moon = shutil.which("moon", path=env.get("PATH"))
        if not moon:
            raise RuntimeError("MoonBit must already be available in the explicit profile")
        if Path(moon).resolve() != (profile_root / "moon/bin/moon").resolve():
            raise RuntimeError("active MoonBit executable is outside the explicit pinned profile")
        if Path(env.get("MOON_HOME", "")).resolve() != (profile_root / "moon").resolve():
            raise RuntimeError("active MoonBit standard library is outside the explicit pinned profile")
        env_info = {"machine": platform.machine(), "system": platform.system(),
                    "release": platform.release(),
                    "moon": subprocess.check_output([moon, "version"], text=True, env=env).strip(),
                    "fontconfig_sha256": digest(env["FONTCONFIG_FILE"]) if env.get("FONTCONFIG_FILE") else None,
                    "profile_lock_sha256": digest(HERE / "profile.lock.json")}
        env_info["installed_profile_sha256"] = installed_hash
        env_info["native_build"] = native_build_identity(env)
        env_info["tools"] = {"moon": tool_identity([moon], env, "version"),
                             "moonc": tool_identity([str(profile_root / "moon/bin/moonc")], env, "-v"),
                             "moonrun": {"sha256": digest(profile_root / "moon/bin/moonrun")},
                             "default_cc": tool_identity(environment_words(env, "CC", "cc"), env),
                             "fc_match": tool_identity(["fc-match"], env)}
        env_info["core_module_sha256"] = digest(profile_root / "moon/lib/core/moon.mod")
        env_info["fonts"] = {}
        for family in ["sans", "Noto Sans CJK JP"]:
            font = subprocess.check_output(["fc-match", "-f", "%{file}", family], text=True, env=env).strip()
            if not font or not Path(font).is_file():
                raise RuntimeError("the workload font fixture could not be resolved: " + family)
            env_info["fonts"][family] = digest(font)
        cpu = Path("/proc/cpuinfo").read_text() if Path("/proc/cpuinfo").is_file() else ""
        env_info["cpu_model"] = next((line.split(":", 1)[1].strip() for line in cpu.splitlines() if line.startswith("model name")), None)
        report["environment"] = env_info
        (output / "staging-manifest.json").write_text(json.dumps({"source_files": source_entries, "source_snapshot": before,
                                                                 "compiler_path_override": str(output / "source/script/linux_text_cc.py"),
                                                                 "environment": env_info}, indent=2) + "\n")
        command = [moon, "build", ".", "--target", "native", "--release", "--warn-list", "-27-79", "--deny-warn", "--target-dir", str(output / "build")]
        with (output / "build.log").open("w") as stream:
            subprocess.run(command, cwd=workload, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
        binaries = list((output / "build/native/release/build").rglob("*.exe"))
        if len(binaries) != 1:
            raise RuntimeError("expected exactly one workload executable")
        binary = binaries[0]
        report["binary_sha256"] = digest(binary)
        report["binary_relative_path"] = binary.relative_to(output).as_posix()
        for index in range(repeats):
            # Alternate order to avoid always warming one mode first.
            for active in ([False, True] if index % 2 == 0 else [True, False]):
                name = str(index) + ("-on" if active else "-off")
                result = subprocess.run([str(binary)] + (["--instrumented"] if active else []), env=env, text=True, capture_output=True, check=True)
                (output / (name + ".jsonl")).write_text(result.stdout)
                (output / (name + ".stderr")).write_text(result.stderr)
                rows = [json.loads(line) for line in result.stdout.splitlines()]
                measured = validate_run(rows, active)
                report["runs"].append({"index": index, "instrumented": active, "raw_file": name + ".jsonl", "result": measured, "rows": rows})
        fingerprints = {(run["result"]["checksum"], run["result"]["fingerprint"]) for run in report["runs"]}
        if len(fingerprints) != 1:
            raise RuntimeError("instrumentation changed the workload's behavior")
        report["behavior_equal"] = True
        report["behavior_signature"] = list(next(iter(fingerprints)))
        report["statistics"] = summarize(report["runs"])
        report["performance_policy"] = OBSERVE_POLICY
        report["artifact_hashes"] = {name: digest(output / name) for name in
                                      ["staging-manifest.json", report["binary_relative_path"]] +
                                      [row["raw_file"] for row in report["runs"]]}
        report["source_after"] = feedback.source_snapshot(REPO)
        report["source_stable"] = before == report["source_after"]
        report["ok"] = True
        validate_evidence(report, output)
        if baseline:
            report["baseline"] = compare_baseline(report, json.loads(Path(baseline).read_text()), tolerance,
                                                  output, Path(baseline).resolve().parent)
            report["performance_policy"] = "explicit compatible baseline with relative/noise/calibration allowance"
            if report["baseline"]["regressions"]:
                raise RuntimeError("performance regression: " + ", ".join(report["baseline"]["regressions"]))
        report["ok"] = True
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        report["ok"] = False
        report["error"] = str(error)
    finally:
        report["source_after"] = feedback.source_snapshot(REPO)
        report["source_stable"] = before == report["source_after"]
        if not report["source_stable"]:
            report["ok"] = False
            report["error"] = "source changed during profiling"
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Input hotpath profile " + ("passed" if report["ok"] else "failed") + ": " + str(output / "summary.json"))
    return 0 if report["ok"] else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hotpath-root", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--relative-tolerance", type=float)
    args = parser.parse_args()
    if not 7 <= args.repeats <= 31:
        parser.error("repeats must be between7 and31")
    if bool(args.baseline) != (args.relative_tolerance is not None):
        parser.error("baseline and explicit relative tolerance must be supplied together")
    if args.relative_tolerance is not None and (not math.isfinite(args.relative_tolerance) or args.relative_tolerance <= 0):
        parser.error("relative tolerance must be finite and positive")
    return execute(args.hotpath_root, args.output, args.repeats, args.baseline, args.relative_tolerance)


if __name__ == "__main__":
    sys.exit(main())
