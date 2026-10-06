"""Structural consumer fixtures are test data, never solver evidence or kills."""

import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import uuid
import subprocess

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]
spec = importlib.util.spec_from_file_location("proof_evidence", HERE / "proof-evidence.py")
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


def fixture(root):
    repo, out = root / "repo", root / "result"
    for relative in ("text/range.mbt", "text/document.mbt", "infra/linux-desktop/composition-proof.py",
                     *["testing/composition_proof/" + name for name in (*evidence.FIXED_FILES, "proof-toolchain.lock.json")]):
        target = repo / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(REPO / relative, target)
    out.mkdir()
    lock = json.loads((repo / "testing/composition_proof/proof-toolchain.lock.json").read_text())
    tools = {"home": root / "moon", "solver": root / "solver/z3", "why3": root / "why3/bin/why3",
             "libdir": root / "why3/lib/why3", "artifacts": lock["artifact_sha256"],
             "solver_sha256": lock["solver"]["executable_sha256"],
             "export": {"version": "Why3 platform, version 1.7.2", **{key: lock["export_backend"][key] for key in
                        ("cli_sha256", "prove_plugin_sha256", "moon_why3_datadir_sha256")}}}
    tools["libdir"].mkdir(parents=True)
    (repo / ".gitignore").write_text("__pycache__/\n*.pyc\n")
    for command in (["init", "--quiet"], ["config", "user.name", "Fixture"],
                    ["config", "user.email", "fixture@example.invalid"], ["add", "."],
                    ["commit", "--quiet", "-m", "Structural fixture"]):
        subprocess.run(["git", *command], cwd=repo, check=True, capture_output=True)
    git_commands = [("ls-files", "--cached", "--others", "--exclude-standard", "-z"), ("rev-parse", "HEAD"),
                    ("rev-parse", "HEAD^{tree}"), ("diff", "--binary", "HEAD"), ("status", "--porcelain", "--untracked-files=all")]
    git_outputs = [subprocess.check_output(["git", *args], cwd=repo) for args in git_commands]
    snapshot = {"commit": git_outputs[1].decode().strip(), "tree": git_outputs[2].decode().strip(),
                "tracked_patch_sha256": hashlib.sha256(git_outputs[3]).hexdigest(),
                "input_files_sha256": evidence.inventory_digest(repo, git_outputs[0]), "status": git_outputs[4].decode()}
    run_id = str(uuid.uuid4())
    config = ('[main]\nmagic = 14\nlibdir = "' + str(tools["libdir"]) + '"\ndatadir = "' +
              str(tools["home"] / "share/why3") + '"\nstdlib = false\nload_default_plugins = false\n')
    (out / "why3-export.conf").write_text(config)
    context = {"run_id": run_id, "config": "why3-export.conf", "config_sha256": evidence.digest(out / "why3-export.conf"),
               "config_text": config, "compiled_libdir": str(tools["libdir"]),
               "actual_prove_plugin": str(tools["libdir"] / "commands/why3prove.cmxs"),
               "actual_prove_plugin_sha256": tools["export"]["prove_plugin_sha256"],
               "effective_datadir": str(tools["home"] / "share/why3"),
               "effective_loadpaths": [str(tools["home"] / "lib/prelude_proof"), str(tools["home"] / "share/why3/stdlib")],
               "stdlib": False, "load_default_plugins": False, "plugin_entries": [],
               "sanitized_environment": {"WHY3CONFIG": None, "WHY3LOADPATH": None,
                    "WHY3DATA": str(tools["home"] / "share/why3"), "WHY3LIB": str(tools["libdir"])},
               "cleared_environment_prefixes": ["WHY3"], "runtime": tools["export"]}
    moon_version = "moon " + lock["moon_version"] + "\nmoonc v" + lock["moonc_version"]
    z3_version = "Z3 version " + lock["solver"]["version"] + " - 64 bit"
    report = {"schema_version": 1, "backend": "why3-export-z3", "run_id": run_id, "terminal": True,
              "started_utc": "2026-10-06T00:00:00+00:00", "finished_utc": "2026-10-06T00:00:01+00:00",
              "status": "passed", "ok": True, "source_correspondence_verified": True, "source_stable": True,
              "verified_scope": evidence.SCOPE, "requested_scope": evidence.SCOPE, "integer_model": "mathematical",
              "user_axioms": [], "trusted_assumptions": ["fixture compiler/solver"], "excluded": ["whole composition"],
              "positive": {"verdict": "proved", "proved": True, "summary": evidence.summary(["unsat"] * 5), "goal_count": 5},
              "negative_controls": [{"name": name, "mutation": list(mutation), "rejected": True,
                    "runtime_counterexample": True, "sat_counterexample": True, "solver_verdict": "unproved",
                    "summary": evidence.summary(["sat"] + ["unsat"] * 4), "goal_count": 5} for name, mutation in evidence.MUTATIONS.items()],
              "source_binding": {"files": {relative: evidence.digest(repo / relative) for relative in ("text/range.mbt", "text/document.mbt")},
                    "proof_files": {"testing/composition_proof/" + name: evidence.digest(repo / "testing/composition_proof" / name) for name in (*evidence.FIXED_FILES, "proof-toolchain.lock.json")},
                    "runner_sha256": evidence.digest(repo / "infra/linux-desktop/composition-proof.py"),
                    "snapshot_before": snapshot, "snapshot_after": snapshot},
              "toolchain": {"moon": moon_version, "z3": z3_version, "why3_metadata": 'version = "1.7.2"',
                    "artifact_sha256": tools["artifacts"], "z3_sha256": tools["solver_sha256"],
                    "export_runtime": tools["export"], "export_bindings": context}, "seconds": 1, "steps": []}
    producer = evidence.load_producer(repo)
    implementation = (repo / "testing/composition_proof/implementation.mbt").read_text()
    correspondence = []
    for relative, head in evidence.TARGETS:
        actual = producer.declaration((repo / relative).read_text(), head)
        correspondence.append({"source": relative, "declaration": head, "matched": True,
            "production_declaration_sha256": hashlib.sha256(actual.encode()).hexdigest(),
            "canonical_sha256": hashlib.sha256(producer.canonical(actual).encode()).hexdigest()})
    (out / "source-correspondence.json").write_text(json.dumps(correspondence))
    def attempt(identity, command, filename, payload="", code=0):
        log = out / filename
        log.write_text("COMMAND " + json.dumps(command) + "\n" + payload)
        result = {"command": command, "exit_code": code, "timed_out": False, "seconds": 0.01, "log": str(log)}
        report["steps"].append({"stage": identity, **result})
        return result
    for identity, command, payload in (
        ("moon-version", [str(tools["home"] / "bin/moon"), "version", "--all"], moon_version + "\n"),
        ("z3-version", [str(tools["solver"]), "--version"], z3_version + "\n"),
        ("why3-version", [str(tools["why3"]), "--version"], tools["export"]["version"] + "\n"),
        ("why3-compiled-libdir", [str(tools["why3"]), "--print-libdir"], str(tools["libdir"]) + "\n")):
        attempt(identity, command, identity + ".log", payload)
    for tag, start in (("before", 4), ("after", 39)):
        for index, command in enumerate(git_commands):
            identity = tag + "-git-" + str(start + index)
            attempt(identity, ["git", *command], identity + ".log", git_outputs[index].decode())
    prefix = [str(tools["why3"]), "-C", str(out / "why3-export.conf"), "prove", "--no-load-default-plugins", "--no-stdlib",
              "-L", str(tools["home"] / "lib/prelude_proof"), "-L", str(tools["home"] / "share/why3/stdlib")]
    inventory = sorted(evidence.GOALS)
    for name in ("positive", *evidence.MUTATIONS):
        module = out / name
        tasks_dir = module / "tasks"
        tasks_dir.mkdir(parents=True)
        candidate = implementation
        if name in evidence.MUTATIONS:
            old, new = evidence.MUTATIONS[name]
            index = candidate.rfind(old) if name == "negative-range" else candidate.index(old)
            candidate = candidate[:index] + new + candidate[index + len(old):]
        (module / "implementation.mbt").write_text(candidate)
        (module / "moon.mod").write_text('name = "f4ah6o/composition_proof"\nversion = "0.0.0"\nsource = "."\n')
        for filename in ("spec.mbtp", "boundary_wbtest.mbt", "moon.pkg"):
            shutil.copy2(repo / "testing/composition_proof" / filename, module / filename)
        (module / "implementation.mlw").write_text("fixture WhyML for " + name)
        attempt(name + "-typecheck", [str(tools["home"] / "bin/moon"), "check"], name + "-check.log")
        emit = [str(tools["home"] / "bin/moonc"), "prove", "implementation.mbt", "spec.mbtp", "-i",
                str(tools["home"] / "lib/core/_build/wasm/release/bundle/prelude/prelude.mi") + ":prelude",
                "-pkg", "f4ah6o/composition_proof", "-pkg-type", "library", "-emit-only", "-whyml-output-path", str(module / "implementation.mlw"),
                "-proof-report-output-path", str(module / "emit-only.json")]
        attempt(name + "-emit-only", emit, name + "-emit.log")
        attempt(name + "-runtime-boundaries", [str(tools["home"] / "bin/moon"), "test", "--target", "native"],
                name + "-runtime.log", "\n".join(evidence.RUNTIME_FAILURES[name]) + "\n" if name != "positive" else "Total tests: 1, passed: 1, failed: 0.\n", 2 if name != "positive" else 0)
        attempt(name + "-goal-inventory", prefix + ["--print-theory", str(module / "implementation.mlw")],
                name + "-goal-inventory.log", "".join("  goal " + goal + " :\n" for goal in inventory))
        attempt(name + "-official-export", prefix + ["-a", "inline_all", "-a", "remove_unused", "-D", str(tools["home"] / "share/why3/drivers/z3_471.drv"),
                "-o", str(tasks_dir), str(module / "implementation.mlw")], name + "-export.log")
        target = None if name == "positive" else ("mbtp___40f4ah6o_2fcomposition_proof_2eTextRange_3a_3alength'vc" if name == "negative-range" else "utf8_scalar_width'vc")
        rows = []
        for index, goal in enumerate(inventory):
            task = tasks_dir / (str(index) + ".smt2")
            task.write_text(';; Goal "' + goal + '"\n; Structural test fixture, not a solver task.\n')
            answer = "sat" if goal == target else "unsat"
            result = attempt(name + "-z3-goal-" + str(index), [str(tools["solver"]), "-smt2", "-T:5", str(task)],
                             name + "-goal-" + str(index) + "-z3.log", answer + "\n")
            rows.append({"goal": goal, "task": task.relative_to(out).as_posix(), "task_sha256": evidence.digest(task),
                         "unmodified": True, "answer": answer, "stdout": answer,
                         "solver_log": name + "-goal-" + str(index) + "-z3.log", **result})
        raw = {"schema_version": 1, "backend": "why3-export-z3", "run_id": run_id, "config_sha256": context["config_sha256"],
               "qualified": True, "whyml_sha256": evidence.digest(module / "implementation.mlw"), "goal_inventory": inventory,
               "goal_count": 5, "task_count": 5, "inventory_log": name + "-goal-inventory.log",
               "transformations": ["inline_all", "remove_unused"], "driver": "z3_471.drv", "tasks": rows,
               "summary": evidence.summary([row["answer"] for row in rows])}
        (out / (name + "-export-report.json")).write_text(json.dumps(raw))
    (out / "proof-result.json").write_text(json.dumps(report))
    return repo, out, tools, snapshot


class ProofEvidenceTests(unittest.TestCase):
    def test_structural_complete_current_export_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo, out, tools, snapshot = fixture(Path(temporary))
            result = evidence.validate(out, repo, {}, snapshot, tools)
            self.assertEqual(result["positive"]["summary"]["valid"], 5)
            self.assertEqual(len(result["negative_controls"]), 2)
            self.assertIn("positive-export-report.json", result["artifact_sha256"])

    def test_stale_current_source_contract_producer_and_correspondence_fail(self):
        for change in ("source", "contract", "producer", "snapshot", "correspondence"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                repo, out, tools, snapshot = fixture(Path(temporary))
                if change in {"source", "contract", "producer"}:
                    relative = {"source": "text/document.mbt", "contract": "testing/composition_proof/spec.mbtp",
                                "producer": "infra/linux-desktop/composition-proof.py"}[change]
                    path = repo / relative
                    path.write_text(path.read_text() + "\n// changed input\n")
                elif change == "snapshot":
                    snapshot = {**snapshot, "commit": "e" * 40}
                else:
                    (out / "source-correspondence.json").write_text(json.dumps([{"matched": True}] * 4))
                with self.assertRaises(RuntimeError):
                    evidence.validate(out, repo, {}, snapshot, tools)

    def test_status_type_nonce_configuration_and_toolchain_corruptions_fail(self):
        changes = [lambda r: r.update(schema_version=True), lambda r: r.update(terminal=False),
                   lambda r: r.update(status="unknown"), lambda r: r.update(backend="moon-prove"),
                   lambda r: r.update(run_id="invalid"), lambda r: r.update(seconds=float("nan")),
                   lambda r: r["toolchain"].update(z3_sha256="0" * 64),
                   lambda r: r["toolchain"]["export_bindings"].update(plugin_entries=["foreign-plugin"]),
                   lambda r: r["toolchain"]["export_bindings"]["sanitized_environment"].update(WHY3LOADPATH="foreign"),
                   lambda r: r["negative_controls"][0].update(runtime_counterexample=False),
                   lambda r: r["steps"][0].update(timed_out=True), lambda r: r["steps"][0].update(exit_code=False)]
        for change in changes:
            with tempfile.TemporaryDirectory() as temporary:
                repo, out, tools, snapshot = fixture(Path(temporary))
                path = out / "proof-result.json"
                report = json.loads(path.read_text())
                change(report)
                path.write_text(json.dumps(report))
                with self.assertRaises(RuntimeError):
                    evidence.validate(out, repo, {}, snapshot, tools)

    def test_wrong_zero_duplicate_goal_unknown_extra_stdout_and_raw_hashes_fail(self):
        changes = [lambda r: r.update(goal_count=0), lambda r: r.update(task_count=True),
                   lambda r: r.update(goal_inventory=["arbitrary"] * 5),
                   lambda r: r["tasks"].__setitem__(1, copy.deepcopy(r["tasks"][0])),
                   lambda r: r["tasks"][0].update(answer="unknown", stdout="unknown"),
                   lambda r: r["tasks"][0].update(task_sha256="0" * 64),
                   lambda r: r["tasks"][0].update(task="../foreign.smt2"),
                   lambda r: r["tasks"][0].update(solver_log="/tmp/foreign.log"),
                   lambda r: r["tasks"][0].update(seconds=True),
                   lambda r: r["tasks"][0].update(command=["foreign-z3"]),
                   lambda r: r.update(run_id=str(uuid.uuid4()))]
        for change in changes:
            with tempfile.TemporaryDirectory() as temporary:
                repo, out, tools, snapshot = fixture(Path(temporary))
                path = out / "positive-export-report.json"
                raw = json.loads(path.read_text())
                change(raw)
                path.write_text(json.dumps(raw))
                with self.assertRaises(RuntimeError):
                    evidence.validate(out, repo, {}, snapshot, tools)
        with tempfile.TemporaryDirectory() as temporary:
            repo, out, tools, snapshot = fixture(Path(temporary))
            log = out / "positive-goal-0-z3.log"
            log.write_text(log.read_text() + "unknown\n")
            with self.assertRaises(RuntimeError):
                evidence.validate(out, repo, {}, snapshot, tools)

    def test_wrong_negative_target_and_scenario_mutations_fail(self):
        for change in ("target", "body", "contract", "task-symlink", "missing-log", "fake-boundary-failure"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                repo, out, tools, snapshot = fixture(Path(temporary))
                raw = json.loads((out / "negative-range-export-report.json").read_text())
                if change == "target":
                    row = next(row for row in raw["tasks"] if row["answer"] == "sat")
                    row.update(answer="unsat", stdout="unsat")
                    (out / row["solver_log"]).write_text("COMMAND " + json.dumps(row["command"]) + "\nunsat\n")
                    (out / "negative-range-export-report.json").write_text(json.dumps(raw))
                elif change in {"body", "contract"}:
                    path = out / "negative-range" / ("implementation.mbt" if change == "body" else "spec.mbtp")
                    path.write_text(path.read_text() + "\n// changed\n")
                elif change == "task-symlink":
                    path = out / raw["tasks"][0]["task"]
                    external = Path(temporary) / "external.smt2"
                    external.write_bytes(path.read_bytes())
                    path.unlink()
                    path.symlink_to(external)
                elif change == "fake-boundary-failure":
                    path = out / "negative-range-runtime.log"
                    header = path.read_text().splitlines()[0]
                    path.write_text(header + "\narbitrary crash, failed: 1\nTotal tests: 1, passed: 0, failed: 1.\n")
                else:
                    (out / raw["tasks"][0]["solver_log"]).unlink()
                with self.assertRaises(RuntimeError):
                    evidence.validate(out, repo, {}, snapshot, tools)

    def test_relabelled_snapshots_and_raw_git_output_mismatches_fail(self):
        for change in ("relabelled", "commit", "tree", "patch", "status", "inventory", "duplicate-inventory"):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as temporary:
                repo, out, tools, snapshot = fixture(Path(temporary))
                if change == "relabelled":
                    snapshot = {**snapshot, "commit": "e" * 40, "tree": "f" * 40, "input_files_sha256": "a" * 64}
                    path = out / "proof-result.json"
                    report = json.loads(path.read_text())
                    report["source_binding"].update(snapshot_before=snapshot, snapshot_after=snapshot)
                    path.write_text(json.dumps(report))
                else:
                    index = {"commit": 1, "tree": 2, "patch": 3, "status": 4, "inventory": 0, "duplicate-inventory": 0}[change]
                    path = out / ("before-git-" + str(4 + index) + ".log")
                    header, _, body = path.read_bytes().partition(b"\n")
                    corrupt = body + body.split(b"\0")[0] + b"\0" if change == "duplicate-inventory" else b"unrelated-output\n"
                    path.write_bytes(header + b"\n" + corrupt)
                with self.assertRaisesRegex(RuntimeError, "raw Git outputs"):
                    evidence.validate(out, repo, {}, snapshot, tools)


if __name__ == "__main__":
    unittest.main()
