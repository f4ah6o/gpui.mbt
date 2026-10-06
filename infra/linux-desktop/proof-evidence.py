#!/usr/bin/env python3
"""Revalidate the bounded, source-bound official Why3-export-Z3 pilot."""

import hashlib
import importlib.util
import json
import math
import os
import datetime as dt
from pathlib import Path
import re
import shutil
import subprocess
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
TARGETS = (
    ("text/range.mbt", "pub struct TextRange {"),
    ("text/range.mbt", "pub fn TextRange::length("),
    ("text/document.mbt", "fn utf8_scalar_width("),
    ("text/document.mbt", "fn utf16_scalar_width("),
)
SCOPE = ["text/range.mbt::TextRange::length", "text/document.mbt::utf8_scalar_width",
         "text/document.mbt::utf16_scalar_width"]
GOALS = {"preconditions_are_inhabited'vc", "mbtp___40f4ah6o_2fcomposition_proof_2eTextRange_3a_3alength'vc",
         "utf8_scalar_width'vc", "utf16_scalar_width'vc", "range_preconditions_are_inhabited'vc"}
FIXED_FILES = {
    "implementation.mbt": "d5800067064e5131865c88a96591586fe729deb7f0849e80b5841b505f3164ed",
    "spec.mbtp": "f25112ca6066b1f2b43220a6f00dffa82ec38646cf93df82d4b40991cf4a781b",
    "boundary_wbtest.mbt": "0cfd9ddc59cb42a370e7536084ab63274dc9cc498d2c99f8af4c8781bc09a30e",
    "moon.pkg": "14f61a444631b7cfc3a27f71868b2610b09c9144ca6e8a2e3d4e20705cb4e4eb",
}
# Independently reviewed e58e2e2, with only the explicit harness-location
# packaging patch in this change. A runner/lock edit needs renewed review.
RUNNER_SHA256 = "41ca263e8dd0c99ec8fd120c19ed0043c2068feb8ade9928a7311dd209f90122"
LOCK_SHA256 = "493e83579177583ef993a098afcb102ee529dc01afd807719ce88c3b138041f2"
MUTATIONS = {
    "negative-range": ("self.end - self.start", "self.start - self.end"),
    "negative-utf8": ("if scalar <= 0x7F {", "if scalar < 0x7F {"),
}
FIELDS = ("valid", "invalid", "timeout", "oom", "step_limit", "unknown", "failure")
RUNTIME_FAILURES = {
    "negative-range": [
        '[f4ah6o/composition_proof] test boundary_wbtest.mbt:2 ("range length machine limits and source-exact Unicode partitions") failed: boundary_wbtest.mbt:3:3-3:79@f4ah6o/composition_proof FAILED: `-2147483647 != 2147483647`',
        "diff:", "--2147483647 +2147483647", "Total tests: 1, passed: 0, failed: 1.",
    ],
    "negative-utf8": [
        '[f4ah6o/composition_proof] test boundary_wbtest.mbt:2 ("range length machine limits and source-exact Unicode partitions") failed: boundary_wbtest.mbt:19:5-19:49@f4ah6o/composition_proof FAILED: `2 != 1`',
        "diff:", "-2 +1", "Total tests: 1, passed: 0, failed: 1.",
    ],
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def tree_digest(directory):
    value = hashlib.sha256()
    for path in sorted(Path(directory).rglob("*")):
        if path.is_file():
            value.update(str(path.relative_to(directory)).encode() + b"\0" + bytes.fromhex(digest(path)))
    return value.hexdigest()


def artifact(directory, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise RuntimeError("proof artifact reference must be a relative path")
    path = Path(relative)
    if path.is_absolute() or any(part in {"..", "."} for part in path.parts):
        raise RuntimeError("proof artifact reference escapes its result root")
    selected = directory / path
    if any((directory / Path(*path.parts[:index])).is_symlink() for index in range(1, len(path.parts) + 1)):
        raise RuntimeError("proof artifact reference traverses a symlink")
    if not selected.is_file() or not selected.resolve().is_relative_to(directory.resolve()):
        raise RuntimeError("proof artifact is missing or outside its result root")
    return selected


def read_json(path):
    result = json.loads(Path(path).read_text())
    if not isinstance(result, dict):
        raise RuntimeError("proof report must be a JSON object")
    return result


def load_producer(repo):
    spec = importlib.util.spec_from_file_location("gate_proof_producer", repo / "infra/linux-desktop/composition-proof.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def selected_executable(env, variable, fallback=None):
    value = env.get(variable) or (shutil.which(fallback, path=env.get("PATH")) if fallback else None)
    if not value or not Path(value).is_file():
        raise RuntimeError("proof gate needs its explicit current " + variable)
    return Path(value).resolve()


def current_tools(lock, env):
    home = Path(env.get("MOON_HOME", "")).resolve()
    solver = selected_executable(env, "GPUI_PROOF_SOLVER", "z3")
    why3 = selected_executable(env, "GPUI_PROOF_WHY3")
    child = {key: value for key, value in env.items() if not key.startswith("WHY3")}
    for name in ("ALTERGOPATH", "CVC5PATH", "MOON_PROVE_PRELUDE_OVERRIDE", "LD_PRELOAD",
                 "LD_LIBRARY_PATH", "CAML_LD_LIBRARY_PATH", "OCAMLPATH", "OCAMLRUNPARAM"):
        child.pop(name, None)
    # Probe the CLI's actual compiled prefix before introducing runtime overrides.
    if digest(why3) != lock["export_backend"]["cli_sha256"] or digest(solver) != lock["solver"]["executable_sha256"]:
        raise RuntimeError("current proof executable differs from the reviewed pin before probing")
    version = subprocess.check_output([str(why3), "--version"], env=child, text=True, timeout=10).strip()
    libdir = Path(subprocess.check_output([str(why3), "--print-libdir"], env=child, text=True, timeout=10).strip()).resolve()
    plugin = libdir / "commands/why3prove.cmxs"
    expected_plugin = (why3.parent.parent / "lib/why3/commands/why3prove.cmxs").resolve()
    if plugin.resolve() != expected_plugin:
        raise RuntimeError("effective Why3 plugin differs from its pinned implementation")
    actual = {name: digest(home / name) for name in lock["artifact_sha256"]}
    export = {"version": version, "cli_sha256": digest(why3), "prove_plugin_sha256": digest(plugin),
              "moon_why3_datadir_sha256": tree_digest(home / "share/why3")}
    if actual != lock["artifact_sha256"] or digest(solver) != lock["solver"]["executable_sha256"] or \
       export["version"] != "Why3 platform, version " + lock["export_backend"]["why3_version"] or \
       any(export[key] != lock["export_backend"][key] for key in
           ("cli_sha256", "prove_plugin_sha256", "moon_why3_datadir_sha256")):
        raise RuntimeError("current proof tools differ from independently reviewed pins")
    return {"home": home, "solver": solver, "why3": why3, "libdir": libdir,
            "artifacts": actual, "solver_sha256": digest(solver), "export": export}


def numeric_seconds(value):
    return type(value) in {int, float} and math.isfinite(value) and value >= 0


def command_log(path, expected):
    lines = path.read_text().splitlines()
    if not lines or not lines[0].startswith("COMMAND ") or json.loads(lines[0][8:]) != expected:
        raise RuntimeError("proof raw command does not match its qualified invocation")
    return lines[1:]


def check_attempt(row, log, expected, exit_code=0):
    if not isinstance(row, dict) or row.get("command") != expected or type(row.get("exit_code")) is not int or \
       row["exit_code"] != exit_code or row.get("timed_out") is not False or not numeric_seconds(row.get("seconds")):
        raise RuntimeError("proof process status is malformed, failed or timed out")
    if not isinstance(row.get("log"), str) or Path(row["log"]).resolve() != log.resolve():
        raise RuntimeError("proof process log is not the current contained artifact")
    return command_log(log, expected)


def summary(answers):
    return {key: answers.count("unsat") if key == "valid" else answers.count("sat") if key == "invalid" else 0 for key in FIELDS}


def inventory_digest(repo, inventory):
    names = inventory.split(b"\0")
    if names[-1] != b"" or len(set(names[:-1])) != len(names) - 1:
        raise RuntimeError("proof raw source inventory is malformed or duplicated")
    value = hashlib.sha256()
    for raw in sorted(names[:-1]):
        name = raw.decode()
        relative = Path(name)
        if not name or relative.is_absolute() or ".." in relative.parts or "\\" in name:
            raise RuntimeError("proof raw source inventory escapes the candidate")
        path = repo / relative
        value.update(raw + b"\0")
        if path.is_symlink():
            value.update(b"link\0" + str(path.readlink()).encode())
        elif path.is_file():
            value.update(b"file\0" + bytes.fromhex(digest(path)))
        else:
            value.update(b"missing\0")
    return value.hexdigest()


def validate(directory, repo, env, expected_snapshot, tools=None):
    try:
        return _validate(directory, repo, env, expected_snapshot, tools)
    except (OSError, ValueError, TypeError, KeyError, AttributeError, SyntaxError, subprocess.SubprocessError) as error:
        raise RuntimeError("malformed, missing or stale proof evidence: " + str(error)) from None


def _validate(directory, repo, env, expected_snapshot, tools=None):
    """Return audited scope only; stale/unknown/native-backend evidence fails."""
    directory, repo = Path(directory).resolve(), Path(repo).resolve()
    report = read_json(artifact(directory, "proof-result.json"))
    if type(report.get("schema_version")) is not int or report["schema_version"] != 1 or \
       report.get("backend") != "why3-export-z3" or report.get("status") != "passed" or \
       any(report.get(key) is not True for key in ("ok", "source_correspondence_verified")) or \
       report.get("verified_scope") != SCOPE or report.get("requested_scope") != SCOPE or \
       report.get("integer_model") != "mathematical" or report.get("user_axioms") != [] or \
       report.get("terminal") is not True or not numeric_seconds(report.get("seconds")):
        raise RuntimeError("proof backend/status/scope is unsupported, blocked, unknown or malformed")
    run_id = report.get("run_id")
    if not isinstance(run_id, str) or str(uuid.UUID(run_id)) != run_id:
        raise RuntimeError("proof attempt identity is malformed")
    started, finished = (dt.datetime.fromisoformat(report[key]) for key in ("started_utc", "finished_utc"))
    if started.tzinfo is None or finished.tzinfo is None or finished < started:
        raise RuntimeError("proof attempt timestamps are malformed")
    if report.get("source_binding", {}).get("snapshot_before") != expected_snapshot or \
       report.get("source_binding", {}).get("snapshot_after") != expected_snapshot or report.get("source_stable") is not True:
        raise RuntimeError("proof evidence is stale for the current source candidate")
    template = repo / "testing/composition_proof"
    if digest(repo / "infra/linux-desktop/composition-proof.py") != RUNNER_SHA256 or digest(template / "proof-toolchain.lock.json") != LOCK_SHA256:
        raise RuntimeError("proof producer or toolchain lock changed without independent review")
    lock = read_json(template / "proof-toolchain.lock.json")
    pin = lock.get("export_backend", {})
    if type(pin.get("expected_goal_count")) is not int or pin["expected_goal_count"] != 5 or \
       not isinstance(pin.get("expected_goal_ids"), list) or len(pin["expected_goal_ids"]) != 5 or set(pin["expected_goal_ids"]) != GOALS:
        raise RuntimeError("proof goal-count contract changed without qualification")
    for name, expected in FIXED_FILES.items():
        if digest(template / name) != expected:
            raise RuntimeError("independently reviewed proof contract/input changed: " + name)
    binding = {"files": {name: digest(repo / name) for name in ("text/range.mbt", "text/document.mbt")},
               "proof_files": {"testing/composition_proof/" + name: digest(template / name) for name in (*FIXED_FILES, "proof-toolchain.lock.json")},
               "runner_sha256": digest(repo / "infra/linux-desktop/composition-proof.py"),
               "snapshot_before": expected_snapshot, "snapshot_after": expected_snapshot}
    if report.get("source_binding") != binding:
        raise RuntimeError("proof source/contract/producer hash binding is stale")
    producer = load_producer(repo)
    correspondence = json.loads(artifact(directory, "source-correspondence.json").read_text())
    if not isinstance(correspondence, list) or len(correspondence) != len(TARGETS) or \
       {(row.get("source"), row.get("declaration")) for row in correspondence if isinstance(row, dict)} != set(TARGETS):
        raise RuntimeError("proof correspondence lacks the four exact declaration identities")
    implementation = (template / "implementation.mbt").read_text()
    for row in correspondence:
        original = producer.declaration((repo / row["source"]).read_text(), row["declaration"])
        copied = producer.declaration(implementation, row["declaration"])
        if row.get("matched") is not True or producer.canonical(original) != producer.canonical(copied) or \
           row.get("production_declaration_sha256") != hashlib.sha256(original.encode()).hexdigest() or \
           row.get("canonical_sha256") != hashlib.sha256(producer.canonical(original).encode()).hexdigest():
            raise RuntimeError("proof executable declaration differs from current production")
    tools = tools or current_tools(lock, env)
    recorded = report.get("toolchain", {})
    if recorded.get("artifact_sha256") != tools["artifacts"] or recorded.get("z3_sha256") != tools["solver_sha256"] or \
       any(recorded.get("export_runtime", {}).get(key) != value for key, value in tools["export"].items()):
        raise RuntimeError("proof report toolchain does not match current pinned tools")
    if not isinstance(recorded.get("moon"), str) or not recorded["moon"].startswith("moon " + lock["moon_version"]) or \
       "moonc v" + lock["moonc_version"] not in recorded["moon"] or not isinstance(recorded.get("z3"), str) or \
       not recorded["z3"].startswith("Z3 version " + lock["solver"]["version"] + " ") or \
       not isinstance(recorded.get("why3_metadata"), str) or 'version = "' + lock["why3_version"] + '"' not in recorded["why3_metadata"]:
        raise RuntimeError("proof recorded tool versions are missing or inconsistent")
    config = artifact(directory, "why3-export.conf")
    expected_config = ('[main]\nmagic = 14\nlibdir = "' + str(tools["libdir"]) + '"\ndatadir = "' +
                       str(tools["home"] / "share/why3") + '"\nstdlib = false\nload_default_plugins = false\n')
    if config.read_text() != expected_config:
        raise RuntimeError("proof config contains unqualified theory/plugin inputs")
    # The producer's successor must publish this exact context, not reuse ambient configuration.
    context = report.get("toolchain", {}).get("export_bindings", {})
    if context.get("config") != "why3-export.conf" or context.get("config_sha256") != digest(config) or \
       context.get("config_text") != expected_config or context.get("compiled_libdir") != str(tools["libdir"]) or \
       context.get("effective_datadir") != str(tools["home"] / "share/why3") or \
       context.get("effective_loadpaths") != [str(tools["home"] / "lib/prelude_proof"), str(tools["home"] / "share/why3/stdlib")] or \
       context.get("stdlib") is not False or context.get("load_default_plugins") is not False or context.get("plugin_entries") != [] or \
       context.get("sanitized_environment") != {"WHY3CONFIG": None, "WHY3LOADPATH": None,
           "WHY3DATA": str(tools["home"] / "share/why3"), "WHY3LIB": str(tools["libdir"])} or \
       context.get("actual_prove_plugin") != str(tools["libdir"] / "commands/why3prove.cmxs") or \
       context.get("actual_prove_plugin_sha256") != tools["export"]["prove_plugin_sha256"] or \
       context.get("run_id") != run_id or context.get("cleared_environment_prefixes") != ["WHY3"] or \
       context.get("runtime") != tools["export"]:
        raise RuntimeError("proof effective backend configuration is not bound")
    controls = report.get("negative_controls")
    if not isinstance(controls, list) or len(controls) != 2 or {row.get("name") for row in controls if isinstance(row, dict)} != set(MUTATIONS):
        raise RuntimeError("proof negative controls are missing or duplicated")
    controls = {row["name"]: row for row in controls}
    for name, control in controls.items():
        if any(control.get(key) is not True for key in ("rejected", "runtime_counterexample", "sat_counterexample")) or \
           control.get("solver_verdict") != "unproved" or control.get("mutation") != list(MUTATIONS[name]):
            raise RuntimeError("proof negative control is inconclusive or targets a different edit")
    steps = report.get("steps")
    if not isinstance(steps, list) or any(not isinstance(row, dict) or not isinstance(row.get("stage"), str) for row in steps):
        raise RuntimeError("proof process ledger is malformed")
    ledger = {row["stage"]: row for row in steps}
    expected_stages = {name + suffix for name in ("positive", *MUTATIONS) for suffix in
                       ("-typecheck", "-emit-only", "-runtime-boundaries", "-goal-inventory", "-official-export", *["-z3-goal-" + str(index) for index in range(5)])}
    probe_stages = {"moon-version", "z3-version", "why3-version", "why3-compiled-libdir"}
    git_commands = [("ls-files", "--cached", "--others", "--exclude-standard", "-z"),
                    ("rev-parse", "HEAD"), ("rev-parse", "HEAD^{tree}"),
                    ("diff", "--binary", "HEAD"), ("status", "--porcelain", "--untracked-files=all")]
    git_stages = {tag + "-git-" + str(start + index) for tag, start in (("before", 4), ("after", 39)) for index in range(5)}
    if len(ledger) != len(steps) or set(ledger) != expected_stages | probe_stages | git_stages:
        raise RuntimeError("proof process ledger is incomplete or contains unqualified stages")
    probe_commands = {"moon-version": [str(tools["home"] / "bin/moon"), "version", "--all"],
                      "z3-version": [str(tools["solver"]), "--version"],
                      "why3-version": [str(tools["why3"]), "--version"],
                      "why3-compiled-libdir": [str(tools["why3"]), "--print-libdir"]}
    for identity, command in probe_commands.items():
        lines = check_attempt(ledger[identity], artifact(directory, identity + ".log"), command)
        if identity == "why3-compiled-libdir" and (len(lines) != 1 or not lines[0] or Path(lines[0]).resolve(strict=True) != tools["libdir"]):
            raise RuntimeError("proof plugin resolution probe differs from the actual pinned library")
        if identity == "moon-version" and "\n".join(lines).strip() != recorded["moon"].strip() or \
           identity == "z3-version" and lines != [recorded["z3"]] or \
           identity == "why3-version" and lines != [tools["export"]["version"]]:
            raise RuntimeError("proof raw version probe differs from recorded tool provenance")
    current_inventory = subprocess.check_output(["git", *git_commands[0]], cwd=repo, timeout=10)
    for tag, start in (("before", 4), ("after", 39)):
        outputs = []
        for index, args in enumerate(git_commands):
            identity = tag + "-git-" + str(start + index)
            log = artifact(directory, identity + ".log")
            check_attempt(ledger[identity], log, ["git", *args])
            outputs.append(log.read_bytes().partition(b"\n")[2])
        if outputs[0] != current_inventory or outputs[1].decode().strip() != expected_snapshot["commit"] or \
           outputs[2].decode().strip() != expected_snapshot["tree"] or \
           hashlib.sha256(outputs[3]).hexdigest() != expected_snapshot["tracked_patch_sha256"] or \
           outputs[4].decode() != expected_snapshot["status"] or \
           inventory_digest(repo, outputs[0]) != expected_snapshot["input_files_sha256"]:
            raise RuntimeError("proof raw Git outputs do not bind the actual current source snapshot")
    summaries = {}
    prefix = [str(tools["why3"]), "-C", str(config), "prove", "--no-load-default-plugins", "--no-stdlib",
              "-L", str(tools["home"] / "lib/prelude_proof"), "-L", str(tools["home"] / "share/why3/stdlib")]
    for name in ("positive", *MUTATIONS):
        candidate = implementation
        if name in MUTATIONS:
            old, new = MUTATIONS[name]
            index = candidate.rfind(old) if name == "negative-range" else candidate.index(old)
            candidate = candidate[:index] + new + candidate[index + len(old):]
        if artifact(directory, name + "/implementation.mbt").read_text() != candidate:
            raise RuntimeError("proof scenario executable is not the exact current body/mutant")
        if artifact(directory, name + "/moon.mod").read_text() != 'name = "f4ah6o/composition_proof"\nversion = "0.0.0"\nsource = "."\n':
            raise RuntimeError("proof isolated module identity/import policy changed")
        for filename in ("spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"):
            if digest(artifact(directory, name + "/" + filename)) != FIXED_FILES[filename]:
                raise RuntimeError("proof scenario weakened or changed its fixed contract/tests")
        module = directory / name
        check_attempt(ledger[name + "-typecheck"], artifact(directory, name + "-check.log"), [str(tools["home"] / "bin/moon"), "check"])
        emit_command = [str(tools["home"] / "bin/moonc"), "prove", "implementation.mbt", "spec.mbtp", "-i",
                        str(tools["home"] / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude",
                        "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only",
                        "-whyml-output-path", str(module / "implementation.mlw"), "-proof-report-output-path", str(module / "emit-only.json")]
        check_attempt(ledger[name + "-emit-only"], artifact(directory, name + "-emit.log"), emit_command)
        runtime = check_attempt(ledger[name + "-runtime-boundaries"], artifact(directory, name + "-runtime.log"),
                                [str(tools["home"] / "bin/moon"), "test", "--target", "native"], 0 if name == "positive" else 2)
        expected_runtime = ["Total tests: 1, passed: 1, failed: 0."] if name == "positive" else RUNTIME_FAILURES[name]
        if runtime != expected_runtime:
            raise RuntimeError("proof negative runtime has no concrete boundary assertion failure")
        raw = read_json(artifact(directory, name + "-export-report.json"))
        inventory_log = artifact(directory, name + "-goal-inventory.log")
        inventory_lines = check_attempt(ledger[name + "-goal-inventory"], inventory_log, prefix + ["--print-theory", str(module / "implementation.mlw")])
        inventory = re.findall(r"^  goal (.+?)\s*:", "\n".join(inventory_lines), re.MULTILINE)
        if len(inventory) != 5 or set(inventory) != GOALS or raw.get("goal_inventory") != inventory:
            raise RuntimeError("proof goal inventory is missing, duplicated or unrelated")
        export_command = prefix + ["-a", "inline_all", "-a", "remove_unused", "-D", str(tools["home"] / "share/why3/drivers/z3_471.drv"),
                                   "-o", str(module / "tasks"), str(module / "implementation.mlw")]
        check_attempt(ledger[name + "-official-export"], artifact(directory, name + "-export.log"), export_command)
        if type(raw.get("schema_version")) is not int or raw["schema_version"] != 1 or raw.get("backend") != "why3-export-z3" or \
           raw.get("run_id") != run_id or raw.get("config_sha256") != digest(config) or \
           raw.get("qualified") is not True or type(raw.get("goal_count")) is not int or raw["goal_count"] != 5 or \
           type(raw.get("task_count")) is not int or raw["task_count"] != 5 or raw.get("inventory_log") != name + "-goal-inventory.log" or \
           raw.get("whyml_sha256") != digest(artifact(directory, name + "/implementation.mlw")) or \
           raw.get("transformations") != ["inline_all", "remove_unused"] or raw.get("driver") != "z3_471.drv":
            raise RuntimeError("proof exported task provenance/count/backend is malformed")
        tasks = raw.get("tasks")
        if not isinstance(tasks, list) or len(tasks) != 5 or {row.get("goal") for row in tasks if isinstance(row, dict)} != GOALS:
            raise RuntimeError("proof lacks one unique task per original goal")
        answers, task_paths, solver_logs = [], set(), set()
        target = None if name == "positive" else ("mbtp___40f4ah6o_2fcomposition_proof_2eTextRange_3a_3alength'vc" if name == "negative-range" else "utf8_scalar_width'vc")
        for row in tasks:
            task = artifact(directory, row.get("task"))
            if task.parent != module / "tasks" or task.suffix != ".smt2" or row.get("task_sha256") != digest(task) or row.get("unmodified") is not True or \
               re.findall(r'^;; Goal "([^"\n]+)"', task.read_text(), re.MULTILINE) != [row["goal"]]:
                raise RuntimeError("proof task bytes or original goal identity changed")
            log = artifact(directory, row.get("solver_log"))
            expected = [str(tools["solver"]), "-smt2", "-T:5", str(task)]
            lines = check_attempt(row, log, expected)
            answer = "sat" if row["goal"] == target else "unsat"
            if lines != [answer] or row.get("answer") != answer or row.get("stdout") != answer:
                raise RuntimeError("proof solver returned unknown/extra output or the wrong mutant-target verdict")
            match = re.fullmatch(re.escape(name) + r"-goal-(\d+)-z3\.log", log.name)
            if not match or ledger.get(name + "-z3-goal-" + match[1]) != {"stage": name + "-z3-goal-" + match[1], **{key: row[key] for key in ("command", "exit_code", "timed_out", "seconds", "log")}}:
                raise RuntimeError("proof raw solver result differs from its process ledger")
            task_paths.add(task)
            solver_logs.add(log)
            answers.append(answer)
        if len(task_paths) != 5 or len(solver_logs) != 5 or set((module / "tasks").glob("*.smt2")) != task_paths:
            raise RuntimeError("proof task/log inventory has missing, duplicate or undeclared entries")
        expected_summary = summary(answers)
        if raw.get("summary") != expected_summary or any(type(raw["summary"].get(key)) is not int for key in FIELDS):
            raise RuntimeError("proof summary differs from the actual raw solver answers")
        selected = report["positive"] if name == "positive" else controls[name]
        if selected.get("summary") != expected_summary or any(type(selected["summary"].get(key)) is not int for key in FIELDS) or \
           type(selected.get("goal_count")) is not int or selected["goal_count"] != 5:
            raise RuntimeError("proof top-level summary is stale or malformed")
        summaries[name] = expected_summary
    if report["positive"].get("verdict") != "proved" or report["positive"].get("proved") is not True:
        raise RuntimeError("proof positive obligations were not actually established")
    audited = {key: report[key] for key in ("backend", "status", "verified_scope", "integer_model", "trusted_assumptions",
               "excluded", "positive", "negative_controls", "source_binding", "toolchain", "seconds")}
    retained = [path for path in sorted(directory.rglob("*")) if (path.is_file() or path.is_symlink()) and
                not any(part in {"_build", ".mooncakes"} for part in path.relative_to(directory).parts)]
    audited["artifact_sha256"] = {path.relative_to(directory).as_posix(): digest(artifact(directory, path.relative_to(directory).as_posix()))
                                 for path in retained}
    return audited
