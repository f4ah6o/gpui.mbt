#!/usr/bin/env python3
"""Strict source-corresponding MoonBit proof pilot for composition helpers."""
from __future__ import annotations

import argparse
import hashlib
import datetime
import math
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import uuid
import time

TARGETS = [
    ("text/range.mbt", "pub struct TextRange {"),
    ("text/range.mbt", "pub fn TextRange::length("),
    ("text/document.mbt", "fn utf8_scalar_width("),
    ("text/document.mbt", "fn utf16_scalar_width("),
]
SCOPE = ["text/range.mbt::TextRange::length", "text/document.mbt::utf8_scalar_width", "text/document.mbt::utf16_scalar_width"]


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def tree_digest(path: Path) -> str:
    hash_value = hashlib.sha256()
    for file in sorted(path.rglob("*")):
        if file.is_file():
            hash_value.update(str(file.relative_to(path)).encode() + b"\0" + bytes.fromhex(digest(file)))
    return hash_value.hexdigest()


def block_end(text: str, start: int) -> int:
    depth = 1
    i = start + 1
    while depth and i < len(text):
        depth += (text[i] == "{") - (text[i] == "}")
        i += 1
    if depth:
        raise ValueError("unclosed declaration")
    return i


def declaration(text: str, head: str) -> str:
    if text.count(head) != 1:
        raise ValueError(f"expected exactly one declaration: {head}")
    start = text.index(head)
    first = text.index("{", start)
    # The narrowly scoped helpers contain no strings/comments with braces.
    header = text[start:first]
    if "where" in header:
        end_contract = block_end(text, first)
        body = text.index("{", end_contract)
        return header[:header.index("where")] + text[body:block_end(text, body)]
    return text[start:block_end(text, first)]


def canonical(text: str) -> str:
    return re.sub(r",(?=\))", "", re.sub(r"\s+", "", text))


def write_json(path: Path, obj: object) -> None:
    """Atomic status/report writes; interruption never exposes partial JSON."""
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, prefix=".proof-status-", delete=False) as stream:
        temporary = Path(stream.name)
        json.dump(obj, stream, indent=2, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    try:
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


class ProofBlocked(ValueError):
    pass


class OutputReused(ValueError):
    pass


class RunInterrupted(BaseException):
    pass


def terminate_group(proc: subprocess.Popen) -> None:
    # The group can still contain descendants after the leader has exited.
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    proc.wait(timeout=2)


def run(command: list[str], cwd: Path, env: dict[str, str], log: Path, timeout: float) -> dict:
    started = time.monotonic()
    with log.open("x") as stream:
        stream.write("COMMAND " + json.dumps(command) + "\n")
        stream.flush()
        proc = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
            timed_out = False
        except subprocess.TimeoutExpired:
            terminate_group(proc)
            code = proc.returncode
            timed_out = True
        except BaseException:
            terminate_group(proc)
            raise
        finally:
            terminate_group(proc)
    return {"command": command, "exit_code": code, "timed_out": timed_out,
            "seconds": round(time.monotonic() - started, 6), "log": str(log)}


def output_bytes(log: Path) -> bytes:
    lines = log.read_bytes().split(b"\n", 1)
    if len(lines) != 2 or not lines[0].startswith(b"COMMAND "):
        raise ValueError("malformed command log")
    return lines[1]


def probe(command: list[str], root: Path, env: dict[str, str], out: Path, name: str, timeout: float, steps: list) -> bytes:
    attempt = run(command, root, env, out / (name + ".log"), min(timeout, 10))
    steps.append({"stage": name, **attempt})
    if attempt["timed_out"] or attempt["exit_code"] != 0:
        raise ProofBlocked(f"bounded command probe failed or timed out: {name}")
    return output_bytes(out / (name + ".log"))


def sanitized_environment(environment: dict[str, str], moon_home: Path, solver: Path) -> dict[str, str]:
    env = {key: value for key, value in environment.items() if not key.startswith("WHY3")}
    for key in ["MOON_PROVE_PRELUDE_OVERRIDE", "ALTERGOPATH", "CVC5PATH", "LD_PRELOAD", "LD_LIBRARY_PATH", "CAML_LD_LIBRARY_PATH", "OCAMLPATH", "OCAMLRUNPARAM"]:
        env.pop(key, None)
    env.update(MOON_HOME=str(moon_home), Z3PATH=str(solver))
    env["PATH"] = str(moon_home / "bin") + ":" + str(solver.parent) + ":" + env.get("PATH", os.defpath)
    return env


def source_snapshot(root: Path, out: Path, env: dict[str, str], tag: str, timeout: float, steps: list) -> dict:
    def git(*args):
        name = tag + "-git-" + str(len(steps))
        return probe(["git", *args], root, env, out, name, timeout, steps)
    inputs = hashlib.sha256()
    for name in sorted(git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")):
        if not name:
            continue
        path = root / name.decode()
        inputs.update(name + b"\0")
        if path.is_symlink():
            inputs.update(b"link\0" + str(path.readlink()).encode())
        elif path.is_file():
            inputs.update(b"file\0" + bytes.fromhex(digest(path)))
        else:
            inputs.update(b"missing\0")
    return {"commit": git("rev-parse", "HEAD").decode().strip(),
            "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
            "tracked_patch_sha256": hashlib.sha256(git("diff", "--binary", "HEAD")).hexdigest(),
            "input_files_sha256": inputs.hexdigest(),
            "status": git("status", "--porcelain", "--untracked-files=all").decode()}


def prepare_output(out: Path, result: dict) -> None:
    if out.is_symlink():
        raise ValueError("artifact directory cannot be a symlink")
    try:
        out.mkdir(parents=True, exist_ok=False)
    except FileExistsError:
        if not out.is_dir():
            raise ValueError("artifact path is not a directory")
        old = out / "proof-result.json"
        if old.exists():
            os.replace(old, out / ("previous-proof-result-" + result["run_id"] + ".json"))
        write_json(out / "proof-result.json", result)
        raise OutputReused("refusing reused artifact directory; previous result is archival, current attempt is failed")
    write_json(out / "proof-result.json", result)


def report_verdict(report: dict, negative: bool = False) -> dict:
    raise ProofBlocked("native-server reports are diagnostic-only and cannot qualify this pilot")


def exact_goal_inventory(goals: object, lock: dict) -> list[str]:
    expected = lock["export_backend"]["expected_goal_ids"]
    if type(goals) is not list or any(type(goal) is not str for goal in goals) or len(goals) != 5 or set(goals) != set(expected):
        raise ValueError("verification inventory must contain exactly the five pinned unique goal IDs")
    return goals


def solver_answer(attempt: dict, log: Path) -> str:
    if (type(attempt.get("exit_code")) is not int or attempt["exit_code"] != 0 or
            attempt.get("timed_out") is not False or type(attempt.get("seconds")) not in (int, float) or
            not math.isfinite(attempt["seconds"]) or attempt["seconds"] < 0 or
            type(attempt.get("command")) is not list or any(type(arg) is not str for arg in attempt["command"])):
        raise ValueError("malformed or unsuccessful solver command result")
    header = log.read_text().splitlines()[0]
    if json.loads(header[len("COMMAND "):]) != attempt["command"]:
        raise ValueError("solver log command differs from recorded argv")
    stdout = output_bytes(log).decode().strip()
    if stdout not in ("sat", "unsat"):
        raise ProofBlocked("solver returned unknown, timeout or malformed output: " + stdout)
    return stdout


def expected_answer(name: str, goal: str, lock: dict) -> str:
    target = {"positive": None,
              "negative-range": "mbtp___40f4ah6o_2fcomposition_proof_2eTextRange_3a_3alength'vc",
              "negative-utf8": "utf8_scalar_width'vc"}[name]
    if goal not in lock["export_backend"]["expected_goal_ids"]:
        raise ValueError("unrecognized verification goal")
    return "sat" if goal == target else "unsat"


def bind_export_runtime(why3: Path, moon_home: Path, out: Path, env: dict, lock: dict,
                        timeout: float, steps: list, run_id: str) -> dict:
    pin = lock["export_backend"]
    if digest(why3) != pin["cli_sha256"]:
        raise ValueError("Why3 CLI differs from reviewed hash before version probe")
    why3_version = probe([str(why3), "--version"], out, env, out, "why3-version", timeout, steps).decode().strip()
    compiled_libdir_text = probe([str(why3), "--print-libdir"], out, env, out, "why3-compiled-libdir", timeout, steps).decode().strip()
    if not compiled_libdir_text or "\n" in compiled_libdir_text:
        raise ValueError("malformed Why3 compiled plugin directory")
    compiled_libdir = Path(compiled_libdir_text).resolve(strict=True)
    adjacent_libdir = (why3.parent.parent / "lib/why3").resolve(strict=True)
    if compiled_libdir != adjacent_libdir:
        raise ValueError("relocated Why3 CLI: compiled plugin resolution differs from reviewed adjacent prefix")
    actual_plugin = (compiled_libdir / "commands/why3prove.cmxs").resolve(strict=True)
    runtime = {"version": why3_version, "cli_sha256": digest(why3), "prove_plugin_sha256": digest(actual_plugin),
               "moon_why3_datadir_sha256": tree_digest(moon_home / "share/why3")}
    if why3_version != "Why3 platform, version " + pin["why3_version"] or any(
            runtime[key] != pin[key] for key in ["cli_sha256", "prove_plugin_sha256", "moon_why3_datadir_sha256"]):
        raise ValueError("official export backend differs from reviewed source/build/runtime pin")
    datadir = (moon_home / "share/why3").resolve(strict=True)
    loadpaths = [(moon_home / "lib/prelude_proof").resolve(strict=True), (datadir / "stdlib").resolve(strict=True)]
    for path in [compiled_libdir, datadir, *loadpaths]:
        if any(char in str(path) for char in ['"', "\n", "\r"]):
            raise ValueError("unsupported quote/control character in proof path")
    config_text = ('[main]\nmagic = 14\nlibdir = "' + str(compiled_libdir) + '"\ndatadir = "' + str(datadir) +
                   '"\nstdlib = false\nload_default_plugins = false\n')
    config = out / "why3-export.conf"
    with config.open("x") as stream:
        stream.write(config_text)
    env["WHY3DATA"] = str(datadir)
    env["WHY3LIB"] = str(compiled_libdir)
    bindings = {"run_id": run_id, "config": config.name, "config_sha256": digest(config), "config_text": config_text,
                "compiled_libdir": str(compiled_libdir), "actual_prove_plugin": str(actual_plugin),
                "actual_prove_plugin_sha256": digest(actual_plugin), "effective_datadir": str(datadir),
                "effective_loadpaths": [str(path) for path in loadpaths], "stdlib": False,
                "load_default_plugins": False, "plugin_entries": [],
                "sanitized_environment": {"WHY3CONFIG": None, "WHY3LOADPATH": None,
                                          "WHY3DATA": str(datadir), "WHY3LIB": str(compiled_libdir)},
                "cleared_environment_prefixes": ["WHY3"], "runtime": runtime}
    return bindings


def export_solve(name: str, module: Path, out: Path, why3: Path, moon_home: Path,
                 solver: Path, env: dict[str, str], timeout: float, lock: dict, bindings: dict) -> tuple[dict, list[dict]]:
    """Official Why3 task inventory/export; never hand-translates or edits SMT."""
    conf = out / bindings["config"]
    if digest(conf) != bindings["config_sha256"] or conf.read_text() != bindings["config_text"]:
        raise ValueError("exact generated Why3 configuration changed")
    prefix = [str(why3), "-C", str(conf), "prove", "--no-load-default-plugins", "--no-stdlib"]
    for path in bindings["effective_loadpaths"]:
        prefix += ["-L", path]
    inventory_log = out / f"{name}-goal-inventory.log"
    inventory_run = run(prefix + ["--print-theory", str(module / "implementation.mlw")], module, env, inventory_log, timeout)
    steps = [{"stage": name + "-goal-inventory", **inventory_run}]
    if inventory_run["exit_code"] != 0 or inventory_run["timed_out"]:
        raise ValueError("official Why3 goal inventory failed or timed out")
    inventory = re.findall(r"^  goal (.+?)\s*:", inventory_log.read_text(), re.MULTILINE)
    exact_goal_inventory(inventory, lock)
    task_dir = module / "tasks"
    task_dir.mkdir()
    export_run = run(prefix + ["-a", "inline_all", "-a", "remove_unused", "-D",
                              str(moon_home / "share/why3/drivers/z3_471.drv"), "-o", str(task_dir),
                              str(module / "implementation.mlw")], module, env, out / f"{name}-export.log", timeout)
    steps.append({"stage": name + "-official-export", **export_run})
    if export_run["exit_code"] != 0 or export_run["timed_out"]:
        raise ValueError("official Why3 task export failed or timed out")
    tasks = sorted(task_dir.glob("*.smt2"))
    if len(tasks) != len(inventory):
        raise ValueError("exported task count differs from original verification goal count")
    rows = []
    for index, task in enumerate(tasks):
        if task.is_symlink() or not task.is_file() or task.resolve().parent != task_dir.resolve():
            raise ValueError("exported task is not a contained regular file")
        goals = re.findall(r'^;; Goal "([^"\n]+)"', task.read_text(), re.MULTILINE)
        if len(goals) != 1 or goals[0] not in inventory:
            raise ValueError("exported task does not identify exactly one original verification goal")
        before = digest(task)
        solver_log = out / f"{name}-goal-{index}-z3.log"
        attempt = run([str(solver), "-smt2", "-T:5", str(task)], module, env, solver_log, min(timeout, 10))
        steps.append({"stage": name + "-z3-goal-" + str(index), **attempt})
        stdout = solver_answer(attempt, solver_log)
        if before != digest(task):
            raise ValueError("exported task changed during solver execution")
        if attempt["timed_out"] or attempt["exit_code"] != 0 or stdout not in ("sat", "unsat"):
            raise ValueError(f"{name} goal returned unknown, timeout, or solver failure: {stdout}")
        rows.append({"goal": goals[0], "task": str(task.relative_to(out)), "task_sha256": before,
                     "unmodified": True, "answer": stdout, "stdout": stdout,
                     "solver_log": str(solver_log.relative_to(out)), **attempt})
    if set(row["goal"] for row in rows) != set(inventory):
        raise ValueError("not all original verification goals were exported and solved")
    qualified = all(row["answer"] == expected_answer(name, row["goal"], lock) for row in rows)
    report = {"schema_version": 1, "backend": "why3-export-z3", "run_id": bindings["run_id"], "config_sha256": bindings["config_sha256"], "qualified": qualified,
              "whyml_sha256": digest(module / "implementation.mlw"),
              "goal_inventory": inventory, "goal_count": len(inventory), "task_count": len(tasks),
              "inventory_log": str(inventory_log.relative_to(out)), "transformations": ["inline_all", "remove_unused"],
              "driver": "z3_471.drv", "tasks": rows,
              "summary": {"valid": sum(row["answer"] == "unsat" for row in rows),
                          "invalid": sum(row["answer"] == "sat" for row in rows),
                          "timeout": 0, "oom": 0, "step_limit": 0, "unknown": 0, "failure": 0}}
    if digest(conf) != bindings["config_sha256"]:
        raise ValueError("generated Why3 configuration changed during export")
    write_json(out / f"{name}-export-report.json", report)
    if not qualified:
        raise ValueError(f"{name} did not establish its exact expected solver outcomes")
    return report, steps


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--artifact-dir", type=Path, required=True)
    parser.add_argument("--moon-home", type=Path, default=os.environ.get("MOON_HOME"))
    parser.add_argument("--solver", type=Path, default=os.environ.get("GPUI_PROOF_SOLVER") or os.environ.get("Z3PATH"))
    parser.add_argument("--why3", type=Path, default=os.environ.get("GPUI_PROOF_WHY3"), help="Use the qualified official socket-free Why3 export backend")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("--timeout must be 1..300 seconds")
    root = args.source_root.resolve()
    requested_out = args.artifact_dir.absolute()
    out = requested_out.resolve()
    result = {"schema_version": 1, "run_id": str(uuid.uuid4()), "terminal": False, "started_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(), "status": "initializing", "ok": False, "source_correspondence_verified": False, "positive": {"verdict": "not-run"}, "verified_scope": [], "requested_scope": SCOPE,
              "backend": "why3-export-z3" if args.why3 else "moon-prove", "integer_model": "mathematical", "trusted_assumptions": [
                  "MoonBit compiler and bundled Why3 1.7.2 lowering/prelude, Z3 solver",
                  "Valid TextRange precondition: 0 <= start <= end <= Int.MAX_VALUE",
                  "Valid Unicode scalar precondition: 0..0x10FFFF excluding surrogates",
                  "Source-equivalent extracted TextRange has identical fields; Eq derivation/extensions are excluded and unused",
              ], "excluded": ["Entire composition transaction, Result-returning arithmetic guards, UTF decoder, GUI, FFI, native IME protocol",
                              "Caller establishment of these preconditions", "General machine-integer overflow verification"],
              "user_axioms": [], "steps": [], "negative_controls": []}
    started = time.monotonic()
    previous_handlers = {}
    output_initialized = False
    def interrupted(signum, _frame):
        raise RunInterrupted("received signal " + str(signum))
    try:
        if requested_out.is_symlink():
            raise ValueError("artifact directory cannot be a symlink")
        if out == root or root in out.parents:
            raise ValueError("artifact directory must be outside the source checkout")
        try:
            prepare_output(out, result)
            output_initialized = True
        except OutputReused:
            output_initialized = True
            raise
        out = out.resolve(strict=True)
        for signum in (signal.SIGTERM, signal.SIGINT):
            previous_handlers[signum] = signal.signal(signum, interrupted)
        template = root / "testing/composition_proof"
        lock_value = os.environ.get("GPUI_PROOF_TOOLCHAIN_LOCK")
        if not lock_value:
            raise ValueError("the profile-qualified GPUI_PROOF_TOOLCHAIN_LOCK is required")
        lock_path = Path(lock_value).resolve(strict=True)
        lock = json.loads(lock_path.read_text())
        implementation = (template / "implementation.mbt").read_text()
        correspondence = []
        for path, head in TARGETS:
            actual = declaration((root / path).read_text(), head)
            candidate = declaration(implementation, head)
            same = canonical(actual) == canonical(candidate)
            correspondence.append({"source": path, "declaration": head, "matched": same,
                                   "production_declaration_sha256": hashlib.sha256(actual.encode()).hexdigest(),
                                   "canonical_sha256": hashlib.sha256(canonical(actual).encode()).hexdigest()})
            if not same:
                raise ValueError(f"source correspondence failed: {head}")
        result["source_binding"] = {"files": {name: digest(root / name) for name in ["text/range.mbt", "text/document.mbt"]},
                                    "proof_files": {**{"testing/composition_proof/" + name: digest(template / name) for name in
                                                    ["implementation.mbt", "spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"]},
                                                    "profile/proof-toolchain.macos.lock.json": digest(lock_path)},
                                    "runner_sha256": digest(Path(__file__).resolve())}
        write_json(out / "source-correspondence.json", correspondence)
        result["source_correspondence_verified"] = True
        if re.search(r"proof_axiomatized|#proof_external|#proof_import", implementation + (template / "spec.mbtp").read_text()):
            raise ValueError("user axioms or external proof stubs are prohibited in this pilot")
        if args.moon_home is None:
            raise ValueError("MOON_HOME/--moon-home is required")
        moon_home = args.moon_home.resolve()
        moon = moon_home / "bin/moon"
        moonc = moon_home / "bin/moonc"
        solver = args.solver.resolve() if args.solver else Path(shutil.which("z3") or "")
        if not moon.is_file() or not moonc.is_file():
            raise ValueError("missing MoonBit toolchain")
        if not solver.is_file():
            raise ValueError("missing Z3; install the locked official solver into a user prefix")
        env = sanitized_environment(dict(os.environ), moon_home, solver)
        observed_moon_hashes = {name: digest(moon_home / name) for name in lock["artifact_sha256"]}
        if observed_moon_hashes != lock["artifact_sha256"] or digest(solver) != lock["solver"]["executable_sha256"]:
            raise ValueError("Moon/solver runtime differs from reviewed hashes before version probes")
        versions = {"moon": probe([str(moon), "version", "--all"], out, env, out, "moon-version", args.timeout, result["steps"]).decode(),
                    "z3": probe([str(solver), "--version"], out, env, out, "z3-version", args.timeout, result["steps"]).decode().strip(),
                    "why3_metadata": (moon_home / "lib/why3/META").read_text()}
        if "moonc v" + lock["moonc_version"] not in versions["moon"]:
            raise ValueError("compiler differs from reviewed proof pin")
        if "moon " + lock["moon_version"] not in versions["moon"]:
            raise ValueError("moon build tool differs from reviewed proof pin")
        if f'Z3 version {lock["solver"]["version"]} ' not in versions["z3"]:
            raise ValueError("Z3 differs from reviewed proof pin")
        if f'version = "{lock["why3_version"]}"' not in versions["why3_metadata"]:
            raise ValueError("bundled Why3 metadata differs from reviewed proof pin")
        versions["artifact_sha256"] = observed_moon_hashes
        versions["z3_sha256"] = digest(solver)
        if versions["artifact_sha256"] != lock["artifact_sha256"]:
            raise ValueError("compiler/server/proof prelude differs from reviewed hashes")
        if versions["z3_sha256"] != lock["solver"]["executable_sha256"]:
            raise ValueError("solver executable differs from reviewed hash")
        if args.why3:
            why3 = args.why3.resolve(strict=True)
            bindings = bind_export_runtime(why3, moon_home, out, env, lock, args.timeout, result["steps"], result["run_id"])
            versions["export_runtime"] = bindings["runtime"]
            versions["export_bindings"] = bindings
        result["source_binding"]["snapshot_before"] = source_snapshot(root, out, env, "before", args.timeout, result["steps"])
        result["toolchain"] = versions
        scenarios = [("positive", None), ("negative-range", ("self.end - self.start", "self.start - self.end")),
                     ("negative-utf8", ("if scalar <= 0x7F {", "if scalar < 0x7F {"))]
        controls = {name: {"name": name, "mutation": mutation, "rejected": False, "solver_verdict": "not-run", "runtime_counterexample": False}
                    for name, mutation in scenarios if mutation}
        result["negative_controls"] = list(controls.values())
        for name, mutation in scenarios:
            module = out / name
            if module.exists():
                raise ValueError(f"refusing stale scenario directory: {module}")
            module.mkdir()
            for filename in ["moon.pkg", "implementation.mbt", "spec.mbtp", "boundary_wbtest.mbt"]:
                shutil.copyfile(template / filename, module / filename)
            (module / "moon.mod").write_text('name = "f4ah6o/composition_proof"\nversion = "0.0.0"\nsource = "."\n')
            if mutation:
                candidate = (module / "implementation.mbt").read_text()
                # Mutate executable body only, keeping the original contract.
                old, new = mutation
                if candidate.count(old) != (2 if name == "negative-range" else 1):
                    raise ValueError(f"unexpected mutant site count: {name}")
                index = candidate.rfind(old) if name == "negative-range" else candidate.index(old)
                candidate = candidate[:index] + new + candidate[index+len(old):]
                (module / "implementation.mbt").write_text(candidate)
            check = run([str(moon), "check"], module, env, out / f"{name}-check.log", args.timeout)
            result["steps"].append({"stage": name + "-typecheck", **check})
            if check["exit_code"] != 0 or check["timed_out"]:
                raise ValueError(f"{name} typecheck failed or timed out")
            emit = run([str(moonc), "prove", "implementation.mbt", "spec.mbtp",
                        "-i", str(moon_home / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude",
                        "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only",
                        "-whyml-output-path", str(module / "implementation.mlw"),
                        "-proof-report-output-path", str(module / "emit-only.json")],
                       module, env, out / f"{name}-emit.log", args.timeout)
            result["steps"].append({"stage": name + "-emit-only", **emit})
            if emit["exit_code"] != 0 or emit["timed_out"]:
                raise ValueError(f"{name} WhyML generation failed or timed out")
            test = run([str(moon), "test", "--target", "native"], module, env, out / f"{name}-runtime.log", args.timeout)
            result["steps"].append({"stage": name + "-runtime-boundaries", **test})
            if test["timed_out"]:
                raise ValueError(f"{name} runtime boundary tests timed out")
            if name == "positive" and test["exit_code"] != 0:
                raise ValueError("source-exact runtime boundary tests failed")
            if mutation:
                log_text = (out / f"{name}-runtime.log").read_text()
                counterexample = test["exit_code"] != 0 and "failed: 1" in log_text
                controls[name]["runtime_counterexample"] = counterexample
                if not counterexample:
                    raise ValueError(f"mutant had no runtime boundary counterexample: {name}")
        if not args.why3:
            raise ProofBlocked("native-server backend is diagnostic-only and unqualified; use the reviewed official export backend")
        for name, mutation in scenarios:
            module = out / name
            report, export_steps = export_solve(name, module, out, why3, moon_home, solver, env, args.timeout, lock, bindings)
            result["steps"].extend(export_steps)
            if name == "positive":
                result["positive"] = {"verdict": "proved", "proved": True, "summary": report["summary"], "goal_count": report["goal_count"]}
            else:
                controls[name].update(rejected=True, solver_verdict="unproved", sat_counterexample=True,
                                      summary=report["summary"], goal_count=report["goal_count"])
        result["source_binding"]["snapshot_after"] = source_snapshot(root, out, env, "after", args.timeout, result["steps"])
        result["source_stable"] = result["source_binding"]["snapshot_before"] == result["source_binding"]["snapshot_after"]
        if not result["source_stable"]:
            raise ValueError("source snapshot changed during proof run")
        if digest(out / bindings["config"]) != bindings["config_sha256"]:
            raise ValueError("generated Why3 configuration changed before completion")
        result["status"] = "passed"
        result["ok"] = True
        result["verified_scope"] = SCOPE
        return_code = 0
    except BaseException as error:
        result["ok"] = False
        result["verified_scope"] = []
        result["reason"] = str(error) or type(error).__name__
        result["status"] = "interrupted" if isinstance(error, (RunInterrupted, KeyboardInterrupt)) else (
            "blocked" if isinstance(error, ProofBlocked) or "missing" in str(error) or "required" in str(error) else "failed")
        return_code = 2
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        result["terminal"] = True
        result["finished_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        result["seconds"] = round(time.monotonic() - started, 6)
        if output_initialized:
            write_json(out / "proof-result.json", result)
    print(json.dumps({"status": result["status"], "reason": result.get("reason"), "result": str(out / "proof-result.json")}))
    return return_code


if __name__ == "__main__":
    sys.exit(main())
