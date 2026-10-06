#!/usr/bin/env python3
"""Run and independently audit the pinned bounded turtles companion stage."""
from __future__ import annotations

import argparse
from collections import Counter
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LOCK_PATH = HERE / "turtles-verification.macos.integration.lock.json"
LOCK_SHA256 = "f2c7ab24dc7425dbe7282f0a47bf8c40df353ca9a2f1b240d9bb2e1c320ab63d"
FIELDS = ("command", "exit_code", "timed_out", "seconds", "log")
EPHEMERAL = re.compile(r"^\.github/workflows/_local-actrun-feedback-(?:[a-z0-9_]{8}|[0-9a-f]{32})\.yml$")


def contained_directory(root, relative):
    selected = root
    for part in Path(relative).parts:
        if part in {".", ".."}:
            raise RuntimeError("escaping campaign directory")
        selected /= part
        if selected.is_symlink() or not selected.is_dir():
            raise RuntimeError("campaign directory is missing or traverses a symlink")
    if not selected.resolve().is_relative_to(root.resolve()):
        raise RuntimeError("campaign directory escapes its run")
    return selected


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def regular_artifact(root, relative):
    path = Path(relative)
    if path.is_absolute() or any(part in {".", ".."} for part in relative.split("/")) or "\\" in relative:
        raise RuntimeError("invalid stage artifact reference")
    selected = root
    for part in path.parts:
        selected /= part
        if selected.is_symlink():
            raise RuntimeError("stage artifact traverses a symlink")
    if not selected.is_file() or not selected.resolve().is_relative_to(root.resolve()):
        raise RuntimeError("stage artifact is missing or outside its run")
    return selected


def read_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise RuntimeError("duplicate JSON key: " + key)
            result[key] = value
        return result
    return json.loads(Path(path).read_text(), object_pairs_hook=pairs,
                      parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError("nonfinite JSON: " + value)))


def uuid_value(value):
    if type(value) is not str:
        raise RuntimeError("run identity must be a UUID string")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise RuntimeError("malformed run UUID") from error
    if parsed.version != 4 or str(parsed) != value:
        raise RuntimeError("run identity must be a canonical UUID4")
    return value


def utc_value(value):
    if type(value) is not str:
        raise RuntimeError("timestamp must be a timezone-aware string")
    try:
        parsed = dt.datetime.fromisoformat(value)
    except ValueError as error:
        raise RuntimeError("malformed timestamp") from error
    if parsed.tzinfo is None:
        raise RuntimeError("timestamp lacks timezone")
    return parsed


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    old = sys.dont_write_bytecode
    try:
        sys.dont_write_bytecode = True
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = old
    return module


def git_value(repo, reference):
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    result = subprocess.run(["git", "rev-parse", reference], cwd=repo, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=10)
    value = result.stdout.strip()
    if result.returncode != 0 or not re.fullmatch(r"[0-9a-f]{40}", value):
        raise RuntimeError("cannot bind exact current Git origin: " + reference)
    return value


def runtime_support(environment, home, solver):
    profile_file = HERE / "profile.py"
    module = load_module("gpui_macos_profile_runtime", profile_file)
    root = Path(environment.get("GPUI_MACOS_PROFILE_ROOT", "")).resolve(strict=True)
    module.doctor(root)
    expected = module.profile_environment(root)
    names = ("CC", "GPUI_MACOS_TEXT_CC", "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
             "CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
             "LIBRARY_PATH", "DYLD_LIBRARY_PATH", "MOON_HOME", "GPUI_PROOF_WHY3", "GPUI_PROOF_SOLVER")
    if any(environment.get(name, "") != expected.get(name, "") for name in names):
        raise RuntimeError("native/wasm proof runtime is outside the exact Mac profile environment")
    host = module.host_identity()
    cc = Path(expected["CC"]).resolve(strict=True)
    if str(cc) != host["clang_path"]:
        raise RuntimeError("profile compiler is not the qualified Xcode clang")
    return {"policy": "macos-profile-sdk-clang-v1", "moonrun_sha256": digest(home / "bin/moonrun"),
            "cc": str(cc), "cc_sha256": digest(cc), "sdk_path": host["sdk_path"],
            "sdk_settings_sha256": host["sdk_settings_sha256"], "xcode_select_path": host["xcode_select_path"],
            "deployment_target": expected["MACOSX_DEPLOYMENT_TARGET"]}

def integration_lock():
    if LOCK_PATH.is_symlink() or digest(LOCK_PATH) != LOCK_SHA256:
        raise RuntimeError("integration lock differs from independently reviewed scope/pins")
    value = read_json(LOCK_PATH)
    if type(value) is not dict or value.get("schema") != 1 or \
       value.get("profile") != "moonbit-composition-helpers-v1" or \
       value.get("upstream_adapter") != "scripts/verify_moon_profile.py" or \
       value.get("adapter") != "infra/macos-desktop/turtles-verification-adapter.py" or \
       value.get("producer") != "infra/macos-desktop/composition-proof.py" or \
       value.get("pilot_revision") != "packaging-39b1275":
        raise RuntimeError("integration lock does not name the exact reviewed Mac source roles")
    return value


def portable_environment(repo, environment):
    """Keep every compiler setting inside the installed Mac profile contract."""
    module = load_module("gpui_macos_profile_environment", HERE / "profile.py")
    root_value = environment.get("GPUI_MACOS_PROFILE_ROOT")
    if not root_value:
        raise RuntimeError("Mac verification requires GPUI_MACOS_PROFILE_ROOT")
    root = Path(root_value).resolve(strict=True)
    module.doctor(root)
    expected = module.profile_environment(root)
    names = ("CC", "GPUI_MACOS_TEXT_CC", "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
             "CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
             "LIBRARY_PATH", "DYLD_LIBRARY_PATH", "MOON_HOME", "GPUI_MACOS_PROFILE_LOCK")
    if any(environment.get(name, "") != expected.get(name, "") for name in names):
        raise RuntimeError("verification compiler or SDK environment differs from the Mac profile")
    return dict(environment), {"policy": "macos-profile-sdk-clang-v1", "profile": str(root),
                               "profile_lock_sha256": digest(HERE / "profile.lock.json"),
                               "installed_marker_sha256": digest(root / "installed.json"),
                               "effective": {name: environment.get(name, "") for name in names}}

def load_inputs(repo, turtles_root, binary, profile_path, home, why3, solver, environment=None):
    lock = integration_lock()
    if type(lock) is not dict or type(lock.get("schema")) is not int or lock["schema"] != 1:
        raise RuntimeError("unsupported turtles verification integration lock")
    upstream_adapter = turtles_root / lock["upstream_adapter"]
    adapter = REPO / lock["adapter"]
    producer = REPO / lock["producer"]
    if digest(upstream_adapter) != lock["upstream_adapter_sha256"] or digest(adapter) != lock["adapter_sha256"] or \
       git_value(turtles_root, "HEAD") != lock["turtles_commit"] or git_value(turtles_root, "HEAD^{tree}") != lock["turtles_tree"]:
        raise RuntimeError("companion source/commit/tree differs from explicitly reviewed published mapping")
    profile_root = Path((environment or os.environ).get("GPUI_MACOS_PROFILE_ROOT", "")).resolve(strict=True)
    profile_runtime = load_module("gpui_macos_profile_inputs", HERE / "profile.py")
    profile_runtime.doctor(profile_root)
    proof_lock_path = Path((environment or os.environ).get("GPUI_PROOF_TOOLCHAIN_LOCK", "")).resolve(strict=True)
    if digest(repo / lock["producer"]) != lock["producer_sha256"] or \
       digest(proof_lock_path) != digest(profile_root / "tools/proof-toolchain.macos.lock.json") or \
       read_json(proof_lock_path) != profile_runtime._expected_proof_lock(profile_root, read_json(profile_root / "installed.json")):
        raise RuntimeError("project proof producer/lock differs from reviewed packaging revision")
    adapter_module = load_module("gpui_verified_turtles_adapter", adapter)
    profile = adapter_module.load_profile(profile_path)
    if digest(binary) != profile.get("turtles_sha256"):
        raise RuntimeError("schema-3 binary does not match the fresh installed Mac profile receipt")
    if profile["pilot_revision"] != lock["pilot_revision"] or profile["target"] != lock["target"] or profile["runtime_packages"] != lock["runtime_packages"] or profile["max_mutants"] != lock["maximum_mutants"]:
        raise RuntimeError("profile selection differs from integration scope")
    for filename, expected in adapter_module.FIXED.items():
        if digest(adapter_module.artifact(repo / lock["fixture"], filename)) != expected:
            raise RuntimeError("project proof contract/test input changed: " + filename)
    proof_lock = read_json(proof_lock_path)
    tools = adapter_module.tool_identity(proof_lock, home, why3, solver)
    runtime_support(os.environ if environment is None else environment, home, solver)
    return lock, adapter_module, profile, proof_lock, tools


def workflow_binding(repo, workflow):
    if workflow is None:
        return None
    requested = Path(workflow).absolute()
    if requested.is_symlink() or not requested.is_file() or not requested.resolve().is_relative_to(repo):
        raise RuntimeError("ephemeral workflow is not a contained current regular file")
    relative = requested.resolve().relative_to(repo).as_posix()
    if not EPHEMERAL.fullmatch(relative):
        raise RuntimeError("only the exact parent-owned generated actrun workflow may be ephemeral")
    return {"path": relative, "sha256": digest(requested), "mode": requested.stat().st_mode & 0o777}


def strip_workflow(files, expected, repo=None, require_present=False):
    if type(files) is not dict:
        raise RuntimeError("source manifest is not a typed map")
    copied = dict(files)
    if expected is not None:
        if type(expected) is not dict or set(expected) != {"path", "sha256", "mode"} or type(expected["path"]) is not str or not EPHEMERAL.fullmatch(expected["path"]) or type(expected["sha256"]) is not str or not re.fullmatch(r"[0-9a-f]{64}", expected["sha256"]) or type(expected["mode"]) is not int:
            raise RuntimeError("untrusted ephemeral workflow identity")
        entry = copied.pop(expected["path"], None)
        if require_present and entry is None:
            raise RuntimeError("bound campaign omitted the exact ephemeral workflow entry")
        if entry is not None and entry != {"sha256": expected["sha256"], "mode": expected["mode"], "link": None}:
            raise RuntimeError("ephemeral workflow bytes/mode/link identity differs")
        if repo is not None:
            current = repo / expected["path"]
            if current.exists() and (current.is_symlink() or digest(current) != expected["sha256"] or current.stat().st_mode & 0o777 != expected["mode"]):
                raise RuntimeError("current generated workflow changed")
    return copied


def attempt_lines(v, row, path, command, code=0):
    return v.check_log(row, path, command, code)


def qualify_warning_rejection(output, exit_code, checkout, mapped):
    """Only the two observed, attributable utf16 deny-warn rejections.

    A generic nonzero check code cannot establish compiler rejection. Unknown
    diagnostics, tool failure and crashes never enter a qualified denominator.
    """
    if type(exit_code) is not int or exit_code != 255 or type(mapped) is not dict or mapped.get("path") != "text/document.mbt" or mapped.get("head") != "fn utf16_scalar_width(" or mapped.get("original") != "scalar <= 0xFFFF" or mapped.get("replacement") not in {"true", "false"}:
        raise RuntimeError("runtime check failure is unknown/unattributed, not qualified UNVIABLE")
    source = checkout / mapped["path"]
    text = source.read_text()
    marker = "fn utf16_scalar_width("
    if text.count(marker) != 1:
        raise RuntimeError("compiler diagnostic helper declaration is ambiguous")
    parameter = text.index(marker) + len(marker)
    if text[parameter:parameter+12] != "scalar : Int":
        raise RuntimeError("unsupported compiler diagnostic parameter layout")
    line = text[:parameter].count("\n") + 1
    column = parameter - text.rfind("\n", 0, parameter)
    source_line = text.splitlines()[line-1]
    lines = output.splitlines()
    footer = ["Failed with 0 warnings, 1 errors.", "Error: failed to run check for target Wasm", "", "Caused by:", "    failed when checking project"]
    gutter = " " * (len(str(line)) + 2)
    expected = ["Error: [0002]", f"{gutter}╭─[ {source}:{line}:{column} ]", f"{gutter}│", f" {line} │ {source_line}",
                gutter + "│" + " " * column + "───┬──  ",
                gutter + "│" + " " * (column + 3) + "╰──── Error Warning (unused_value): Unused variable 'scalar'",
                "─" * (len(str(line)) + 2) + "╯", *footer]
    if lines != expected:
        raise RuntimeError("runtime compiler rejection lacks exact source-attributed unused-scalar evidence")
    return "warning-denied-unused-scalar"


def audit_runtime(v, directory, recorded, checkout, home, profile, mapped=None):
    if type(recorded) is not dict or recorded.get("outcome") not in {"KILLED", "SURVIVED", "UNVIABLE", "TIMEOUT", "INCONCLUSIVE"}:
        raise RuntimeError("unknown runtime verdict")
    check_command = [str(home / "bin/moon"), "check", *profile["runtime_packages"], "--target", profile["target"], "--deny-warn"]
    check = recorded.get("check")
    check_log = v.artifact(directory, "runtime-check.log")
    if type(check) is not dict or check.get("command") != check_command or check.get("log") != str(check_log) or type(check.get("exit_code")) is not int or check.get("timed_out") is not False or type(check.get("seconds")) not in (int, float) or not math.isfinite(check["seconds"]) or check["seconds"] < 0:
        raise RuntimeError("runtime check ledger is incomplete or timed out")
    lines = check_log.read_text().splitlines()
    if not lines or lines[0] != "COMMAND " + json.dumps(check_command):
        raise RuntimeError("runtime check raw argv differs")
    if check["exit_code"] != 0:
        if recorded.get("outcome") != "UNVIABLE" or recorded.get("killed_by") != [] or "test" in recorded:
            raise RuntimeError("compiler/warning failure was counted as a runtime kill")
        qualify_warning_rejection("\n".join(lines[1:]), check["exit_code"], checkout, mapped)
        return "UNVIABLE"
    test_command = [str(home / "bin/moon"), "test", *profile["runtime_packages"], "--target", profile["target"], "--deny-warn", "--test-failure-json"]
    test = recorded.get("test")
    test_log = v.artifact(directory, "runtime-test.log")
    if type(test) is not dict or type(test.get("exit_code")) is not int or test.get("exit_code") not in (0, 2):
        raise RuntimeError("runtime execution is unknown, crashed or malformed")
    output = attempt_lines(v, test, test_log, test_command, test["exit_code"])
    kills = []
    for line in output:
        if line.startswith("{"):
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if type(row) is dict and all(type(row.get(key)) is str for key in ("package", "filename", "test_name", "message")) and type(row.get("index")) in (str, int):
                kills.append(row)
    outcome = "SURVIVED" if test["exit_code"] == 0 and not kills and re.search(r"Total tests: [1-9]\d*, passed: [1-9]\d*, failed: 0\.", "\n".join(output)) else "KILLED" if test["exit_code"] == 2 and kills else "INCONCLUSIVE"
    if recorded.get("outcome") != outcome or recorded.get("killed_by") != kills or outcome == "INCONCLUSIVE":
        raise RuntimeError("runtime result differs from concrete raw test evidence")
    return outcome


def validate(directory, repo, environment, expected_workflow=None):
    return _validate(directory, repo, environment, expected_workflow)


def _validate(directory, repo, environment, expected_workflow=None, allow_auditing=False):
    """Fresh source-current post-actrun audit; no success boolean shortcut."""
    requested = Path(directory).absolute()
    if requested.is_symlink():
        raise RuntimeError("stage result root is a symlink")
    directory, repo = requested.resolve(strict=True), Path(repo).resolve(strict=True)
    invocation = read_json(regular_artifact(directory, "invocation.json"))
    if type(invocation) is not dict or invocation.get("terminal") is not True or not (invocation.get("status") == "passed" and invocation.get("ok") is True or allow_auditing and invocation.get("status") == "auditing" and invocation.get("ok") is False):
        raise RuntimeError("companion invocation is incomplete/blocked")
    if type(invocation.get("schema")) is not int or invocation["schema"] != 1:
        raise RuntimeError("unsupported invocation schema")
    run_ids = {uuid_value(invocation.get("run_id"))}
    invocation_started, invocation_finished = utc_value(invocation.get("started_utc")), utc_value(invocation.get("finished_utc"))
    if invocation_finished < invocation_started:
        raise RuntimeError("invocation timestamp order is invalid")
    if invocation.get("runner_sha256") != digest(HERE / "turtles-verification.py") or invocation.get("integration_lock_sha256") != digest(LOCK_PATH):
        raise RuntimeError("stage runner/integration lock changed")
    if invocation.get("ephemeral_workflow") != expected_workflow:
        raise RuntimeError("ephemeral workflow was not attested by this parent invocation")
    environment, normalized = portable_environment(repo, environment)
    if invocation.get("portable_environment") != normalized:
        raise RuntimeError("portable child environment normalization differs from this current parent/profile")
    def selected(name):
        value = environment.get(name)
        if not value:
            raise RuntimeError("missing explicit companion input: " + name)
        return Path(value).resolve(strict=True)
    turtles_root = selected("GPUI_TURTLES_VERIFICATION_ROOT")
    binary = selected("GPUI_TURTLES_SCHEMA3_BIN")
    profile_path = selected("GPUI_TURTLES_VERIFICATION_PROFILE")
    home, why3, solver = selected("MOON_HOME"), selected("GPUI_PROOF_WHY3"), selected("GPUI_PROOF_SOLVER")
    lock, v, profile, proof_lock, tools = load_inputs(repo, turtles_root, binary, profile_path, home, why3, solver, environment)
    proof_lock_path = Path(environment.get("GPUI_PROOF_TOOLCHAIN_LOCK", "")).resolve(strict=True)
    campaign = contained_directory(directory, "campaign")
    report_path = v.artifact(campaign, "verification-report.json")
    report = v.read_json(report_path)
    if type(report.get("schema")) is not int or report["schema"] != 1 or report.get("profile") != lock["profile"] or report.get("terminal") is not True or report.get("ok") is not True or report.get("status") != "complete" or report.get("source_stable") is not True or report.get("runtime_score_modified_by_proof") is not False:
        raise RuntimeError("campaign is incomplete/unknown or mislabeled")
    campaign_id = uuid_value(report.get("run_id"))
    if campaign_id in run_ids:
        raise RuntimeError("campaign reused an invocation identity")
    run_ids.add(campaign_id)
    if invocation.get("campaign_run_id") != report["run_id"] or invocation.get("campaign_report_sha256") != digest(report_path):
        raise RuntimeError("campaign result is stale or changed since live completion")
    for name in ("started_utc", "finished_utc"):
        value = utc_value(report.get(name))
        if not invocation_started <= value <= invocation_finished:
            raise RuntimeError("campaign timestamps are outside the fresh invocation")
    if utc_value(report["finished_utc"]) < utc_value(report["started_utc"]):
        raise RuntimeError("campaign timestamp order is invalid")
    identity = report.get("identity", {})
    expected_origin = {"commit": git_value(repo, "HEAD"), "tree": git_value(repo, "HEAD^{tree}")}
    if identity.get("source_origin") != expected_origin or invocation.get("source_origin") != expected_origin:
        raise RuntimeError("campaign origin does not match current production commit/tree")
    source_before = identity.get("source_before")
    current = v.snapshot(repo)
    if report.get("source_after") != source_before or \
       strip_workflow(source_before, expected_workflow, require_present=expected_workflow is not None) != \
       strip_workflow(current, expected_workflow, repo, require_present=expected_workflow is not None):
        raise RuntimeError("campaign production/test/config source manifest is stale or polluted")
    if identity.get("profile_sha256") != digest(profile_path) or identity.get("adapter_sha256") != lock["adapter_sha256"] or identity.get("turtles_sha256") != profile.get("turtles_sha256") or identity.get("producer_sha256") != lock["producer_sha256"] or identity.get("pilot_revision") != lock["pilot_revision"] or identity.get("proof_fixture_path") != lock["fixture"] or identity.get("lock_sha256") != digest(proof_lock_path) or identity.get("tools") != tools or identity.get("target") != lock["target"] or identity.get("runtime_packages") != lock["runtime_packages"] or identity.get("fixed_inputs") != v.FIXED or identity.get("model_pbt_seeds") != v.SEEDS or identity.get("model_pbt_count_per_seed") != 1000:
        raise RuntimeError("campaign source/contract/tool/runtime selection differs from current pins")
    if identity.get("runtime_support") != runtime_support(environment, home, solver):
        raise RuntimeError("native/wasm runtime support differs from executed identity")
    command = [sys.executable, str(HERE / "turtles-verification-adapter.py"), "--profile", str(profile_path), "--source-root", str(repo), "--turtles-bin", str(binary), "--artifact-dir", str(campaign), "--moon-home", str(home), "--why3", str(why3), "--solver", str(solver)]
    attempt_lines(v, invocation.get("process"), v.artifact(directory, "companion.log"), command)
    producer = v.load_producer(repo, profile["pilot_revision"])
    template = repo / lock["fixture"]
    implementation = (template / "implementation.mbt").read_text()
    for path, head, _ in v.TARGETS:
        if producer.canonical(producer.declaration((repo / path).read_text(), head)) != producer.canonical(producer.declaration(implementation, head)):
            raise RuntimeError("pristine proof body no longer corresponds to active production")
    contract_hash = v.fixed_contracts(producer, implementation)
    if identity.get("fixed_contracts_sha256") != contract_hash:
        raise RuntimeError("fixed reviewed contracts/witnesses changed")
    source = contained_directory(campaign, "source")
    expected_files = {name: {**row, "link": None} for name, row in source_before.items()}
    if v.snapshot(source) != expected_files:
        raise RuntimeError("pristine isolated snapshot differs from bound caller source")
    baseline = contained_directory(campaign, "baseline-proof")
    raw_baseline = v.read_json(v.artifact(baseline, "proof-result.json"))
    if raw_baseline.get("terminal") is not True or raw_baseline.get("ok") is not True or raw_baseline.get("status") != "passed" or raw_baseline.get("source_correspondence_verified") is not True or raw_baseline.get("source_stable") is not True:
        raise RuntimeError("pristine proof/control result is inconclusive")
    baseline_id = uuid_value(raw_baseline.get("run_id"))
    if baseline_id in run_ids:
        raise RuntimeError("baseline reused another scenario identity")
    run_ids.add(baseline_id)
    env = producer.sanitized_environment(dict(environment), home, solver)
    with tempfile.TemporaryDirectory(prefix="turtles-verification-audit-") as scratch:
        source_snapshot = producer.source_snapshot(source, Path(scratch), env, "current", 10, [])
    binding = raw_baseline.get("source_binding", {})
    expected_binding = {"files": {name: digest(source / name) for name in ("text/range.mbt", "text/document.mbt")},
                        "proof_files": {**{lock["fixture"] + "/" + name: digest(template / name) for name in v.FIXED},
                                        "profile/proof-toolchain.macos.lock.json": digest(proof_lock_path)},
                        "runner_sha256": lock["producer_sha256"], "snapshot_before": source_snapshot, "snapshot_after": source_snapshot}
    if binding != expected_binding:
        raise RuntimeError("baseline source/contract/Git correspondence is stale")
    baseline_audits = {}
    for name in ("positive", "negative-range", "negative-utf8"):
        expected = implementation
        target = None
        if name != "positive":
            old, new = ("self.end - self.start", "self.start - self.end") if name == "negative-range" else ("if scalar <= 0x7F {", "if scalar < 0x7F {")
            index = expected.rfind(old) if name == "negative-range" else expected.index(old)
            expected = expected[:index] + new + expected[index+len(old):]
            target = v.TARGETS[1 if name == "negative-range" else 2][2]
        audited = v.audit_export(baseline, baseline / name, name, raw_baseline["toolchain"]["export_bindings"], proof_lock, why3, home, solver, raw_baseline["run_id"], raw_baseline["steps"], expected, target)
        audited["native_control"] = v.audit_native_control(baseline, name, raw_baseline["steps"], home)
        if name == "positive" and audited["outcome"] != "PROVED":
            raise RuntimeError("pristine proof has an actual counterexample")
        baseline_audits[name] = audited
    if report.get("baseline_proof") != baseline_audits:
        raise RuntimeError("baseline qualification summary differs from actual raw controls")
    baseline_runtime = contained_directory(campaign, "baseline-runtime")
    if audit_runtime(v, baseline_runtime, report["baseline_runtime"], source, home, profile) != "SURVIVED":
        raise RuntimeError("pristine production runtime baseline did not actually pass")
    repeat = contained_directory(campaign, "baseline-runtime-repeat")
    repeat_source = contained_directory(repeat, "source")
    if v.snapshot(repeat_source) != expected_files:
        raise RuntimeError("restored production baseline snapshot changed")
    if audit_runtime(v, repeat, report["baseline_runtime_repeat"], repeat_source, home, profile) != "SURVIVED":
        raise RuntimeError("restored production runtime baseline did not actually pass")
    helper = contained_directory(campaign, "helper-discovery")
    extracted, mappings = v.extract(repo)
    expected_helper = {
        "implementation.mbt": extracted,
        "boundary_wbtest.mbt": (template / "boundary_wbtest.mbt").read_bytes(),
        "model_pbt_wbtest.mbt": v.MODEL_PBT.encode(),
        "moon.mod": b'name = "f4ah6o/composition_proof"\nversion = "0.0.0"\n',
        "moon.pkg": b'import { "moonbitlang/core/quickcheck", } for "wbtest"\n',
        "turtles.toml": b'include = ["implementation.mbt"]\noperators = ["comparison", "boolean", "arithmetic", "literal", "condition"]\n',
    }
    if set(v.snapshot(helper)) != set(expected_helper) or any(v.artifact(helper, name).read_bytes() != contents for name, contents in expected_helper.items()):
        raise RuntimeError("independent helper model/tests/config differ from reviewed adapter")
    raw_helper_path = v.artifact(campaign, "helper-runtime-report.json")
    raw_helper = v.read_json(raw_helper_path)
    rows = v.audit_turtles(raw_helper, helper, extracted, lock["maximum_mutants"])
    if report.get("helper_runtime_report") != {"path": raw_helper_path.name, "sha256": digest(raw_helper_path), "summary": raw_helper["summary"]} or v.read_json(v.artifact(campaign, "source-mappings.json")) != mappings or v.read_json(v.artifact(campaign, "discovered-mutants.json")) != rows:
        raise RuntimeError("discovery/model-runtime raw inventory changed")
    coverage = report.get("coverage", {})
    if coverage.get("inventory_complete") is not True or type(coverage.get("discovered_mutants")) is not int or coverage["discovered_mutants"] != len(rows) or type(coverage.get("evaluated_mutants")) is not int or coverage["evaluated_mutants"] != len(rows) or coverage.get("unexecuted_discovery_ids") != [] or coverage.get("discovery_ids") != [row["id"] for row in rows] or coverage.get("inventory_sha256") != digest(campaign / "discovered-mutants.json") or coverage.get("discovery_target") != lock["discovery_target"] or coverage.get("production_runtime_target") != lock["target"]:
        raise RuntimeError("campaign coverage is incomplete, stale or different-target")
    discovery_log = v.artifact(campaign, "helper-discovery.log")
    discovery_text = discovery_log.read_text()
    discovery_command = [str(binary), "--dir", str(helper), "--target", "native", "--list"]
    counts = re.findall(r"^Found (\d+) mutation\(s\)\.$", discovery_text, re.MULTILINE)
    if not discovery_text.splitlines() or discovery_text.splitlines()[0] != "COMMAND " + json.dumps(discovery_command) or len(counts) != 1 or int(counts[0]) != len(rows) or "Skipped " in discovery_text or "target-inactive:" in discovery_text or "Target native: 0 target-inactive mutation(s) not listed" not in discovery_text.splitlines():
        raise RuntimeError("fresh parser discovery argv/count/active-source evidence is incomplete")
    discovery = re.findall(r"^(implementation\.mbt):(\d+):(\d+): (.*?) -> (.*?) \[(public|private)\]$", discovery_log.read_text(), re.MULTILINE)
    expected_discovery = [(row["path"], str(row["line"]), str(row["column"]), row["original"], row["replacement"], row["visibility"]) for row in rows]
    if discovery != expected_discovery or coverage.get("discovery_inventory") != [list(row) for row in discovery] or coverage.get("discovery_log_sha256") != digest(discovery_log):
        raise RuntimeError("fresh parser discovery differs from evaluated candidates")
    plan_log = v.artifact(campaign, "production-target-plan.log")
    plan_command = [str(home / "bin/moon"), "test", *profile["runtime_packages"], "--target", profile["target"], "--dry-run"]
    if identity.get("production_target_plan_sha256") != digest(plan_log) or plan_log.read_text().splitlines()[0] != "COMMAND " + json.dumps(plan_command):
        raise RuntimeError("production target planning provenance is stale")
    active = set()
    for line in plan_log.read_text().splitlines()[1:]:
        words = shlex.split(line)
        if len(words) < 2 or Path(words[0]).name != "moonc" or words[1] != "build-package" or "-pkg" not in words or words[words.index("-pkg") + 1] != "f4ah6o/gpui/text" or "-target" not in words or words[words.index("-target") + 1] != "wasm":
            continue
        for word in words[2:]:
            if word.endswith(".mbt"):
                value = Path(word)
                absolute = value if value.is_absolute() else source / value
                if absolute.resolve().is_relative_to(source):
                    active.add(absolute.resolve().relative_to(source).as_posix())
    if not {"text/range.mbt", "text/document.mbt"}.issubset(active):
        raise RuntimeError("bound production declarations are inactive or absent from actual target plan")
    mutants = report.get("mutants")
    if type(mutants) is not list or len(mutants) != len(rows) or any(type(candidate) is not dict for candidate in mutants):
        raise RuntimeError("missing/duplicate candidate results")
    runtime_counts, proof_counts = Counter(), Counter()
    compiler_rejections = []
    replay_count = 0
    for index, (row, candidate) in enumerate(zip(rows, mutants)):
        mapped = v.map_mutation(row, extracted, mappings, source)
        case = contained_directory(campaign, f"mutant-{index:03}")
        checkout = contained_directory(case, "source")
        if candidate.get("id") != mapped["production_mutant_id"] or candidate.get("discovery_id") != row["id"] or candidate.get("source_edit") != mapped:
            raise RuntimeError("candidate does not map its genuine discovered source edit")
        expected_mutant_files = dict(expected_files)
        data = (source / mapped["path"]).read_bytes()
        changed = data[:mapped["offset"]] + mapped["replacement"].encode() + data[mapped["end"]:]
        expected_mutant_files[mapped["path"]] = {**expected_files[mapped["path"]], "sha256": hashlib.sha256(changed).hexdigest()}
        if v.snapshot(checkout) != expected_mutant_files or (checkout / mapped["path"]).read_bytes() != changed or candidate.get("source_before_sha256") != digest(source / mapped["path"]) or candidate.get("source_mutant_sha256") != digest(checkout / mapped["path"]):
            raise RuntimeError("isolated candidate is not exactly its one source edit")
        if candidate.get("helper_runtime") != {"outcome": row["outcome"], "killed_by": row.get("killed_by", []), "regressions": [p for p in raw_helper.get("regressions", []) if row["id"] in p]}:
            raise RuntimeError("helper runtime attribution was changed")
        runtime_outcome = audit_runtime(v, case, candidate.get("runtime"), checkout, home, profile, mapped)
        runtime_counts[runtime_outcome] += 1
        if runtime_outcome == "UNVIABLE":
            rejected_log = v.artifact(case, "runtime-check.log")
            compiler_rejections.append({"id": candidate["id"], "source": mapped["path"], "log": rejected_log.relative_to(campaign).as_posix(),
                                        "log_sha256": digest(rejected_log), "raw_reason": rejected_log.read_text().splitlines()[1:]})
        proof = contained_directory(case, "proof")
        regenerated = v.regenerate(producer, implementation, checkout)
        proof_binding = candidate.get("proof_binding", {})
        if proof_binding.get("source_sha256") != digest(checkout / mapped["path"]) or proof_binding.get("implementation_sha256") != hashlib.sha256(regenerated.encode()).hexdigest() or proof_binding.get("fixed_contracts_sha256") != contract_hash or v.fixed_contracts(producer, regenerated) != contract_hash or proof_binding.get("tools") != tools:
            raise RuntimeError("candidate body/fixed contract/tool identity differs")
        candidate_id = uuid_value(proof_binding.get("run_id"))
        if candidate_id in run_ids:
            raise RuntimeError("candidate reused a stale/duplicate scenario identity")
        run_ids.add(candidate_id)
        audited = v.audit_export(proof, proof / "positive", "positive", proof_binding["export_context"], proof_lock, why3, home, solver, proof_binding["run_id"], v.read_json(v.artifact(proof, "process-ledger.json")), regenerated)
        if any(goal != mapped["goal"] for goal, answer in audited["answers"].items() if answer == "sat") or candidate.get("proof") != audited:
            raise RuntimeError("candidate proof is stale, unqualified or targets an unrelated goal")
        if audited["outcome"] == "PROVED" and row["outcome"] == "KILLED":
            raise RuntimeError("proof contradicts the independent valid-input model oracle")
        if "equivalence" in candidate and not (audited["outcome"] == "PROVED" and row["outcome"] == "SURVIVED" and candidate["runtime"]["outcome"] == "SURVIVED"):
            raise RuntimeError("unsupported contract-equivalence classification")
        proof_counts[audited["outcome"]] += 1
        replay = candidate.get("regression_replay", {})
        if replay.get("status") == "replayed":
            audit_replay(v, replay, case, source, mapped, home, profile, row)
            replay_count += 1
        elif replay.get("status") != "unsupported":
            raise RuntimeError("concrete regression replay is incomplete/unknown")
        if v.read_json(v.artifact(proof, "candidate-evidence.json")) != candidate:
            raise RuntimeError("final candidate artifact disagrees with campaign report")
    viable = sum(runtime_counts[key] for key in ("KILLED", "SURVIVED", "TIMEOUT"))
    summary = {"mutants": len(rows), "production_runtime": dict(runtime_counts), "proof": dict(proof_counts), "runtime_viable": viable,
               "runtime_score": 100 * runtime_counts["KILLED"] / viable if viable else None, "proof_counterexamples_added_to_runtime_kills": 0,
               "equivalents_under_contract": sum("equivalence" in candidate for candidate in mutants)}
    if report.get("summary") != summary:
        raise RuntimeError("runtime denominator/proof summary is forged or conflated")
    actual_summary = report["summary"]
    if any(type(actual_summary.get(key)) is not int for key in ("mutants", "runtime_viable", "proof_counterexamples_added_to_runtime_kills", "equivalents_under_contract")) or any(type(value) is not int for category in ("production_runtime", "proof") for value in actual_summary[category].values()) or type(actual_summary.get("runtime_score")) not in (int, float, type(None)):
        raise RuntimeError("summary contains untyped/boolean counts")
    audited = {"kind": "bounded-real-mutant-helper-verification", "profile": lock["profile"], "source_origin": expected_origin,
            "report_sha256": digest(report_path), "adapter_sha256": lock["adapter_sha256"], "upstream_adapter_sha256": lock["upstream_adapter_sha256"], "integration_lock_sha256": digest(LOCK_PATH),
            "target": lock["target"], "discovery_target": lock["discovery_target"], "coverage": {"discovered": len(rows), "evaluated": len(mutants)},
            "summary": summary, "actual_regression_replays": replay_count, "proof_goals_audited": 15 + len(rows) * 5,
            "compiler_rejections": compiler_rejections,
            "solver_concrete_values": "unsupported", "scope": "TextRange length and UTF8/16 scalar widths only"}
    if not allow_auditing:
        receipt = regular_artifact(directory, "audited-summary.json")
        if invocation.get("audit_receipt_sha256") != digest(receipt) or read_json(receipt) != audited:
            raise RuntimeError("live audit receipt is missing, stale or different from independent revalidation")
    return audited


def audit_replay(v, replay, case, source, mapped, home, profile, row):
    if replay.get("origin") != "independent helper-model QuickCheck shrunk witness" or replay.get("automatic_source_repair") is not False or mapped["head"] != "pub fn TextRange::length(":
        raise RuntimeError("regression replay lacks typed PBT provenance")
    witness = replay.get("raw_input")
    witnessed = [kill.get("counterexample") for kill in row.get("killed_by", []) if kill.get("filename") == "model_pbt_wbtest.mbt" and kill.get("test_name") == "independent range reconstruction model fixed seeded PBT" and kill.get("kind") == "Property"]
    if witnessed != [witness]:
        raise RuntimeError("regression input was not the actual unique model-PBT shrunk witness")
    match = re.fullmatch(r"\((-?\d+), (-?\d+)\)", witness) if type(witness) is str else None
    if not match:
        raise RuntimeError("unrecognized concrete regression tuple")
    values = [int(value) for value in match.groups()]
    if any(not -2147483648 <= value <= 2147483647 for value in values):
        raise RuntimeError("regression tuple exceeds signed Int domain")
    start, end = sorted(value & 0x7FFFFFFF for value in values)
    code = f'///|\ntest "turtles deterministic shrunk range regression" {{\n  assert_eq(({{ start: {start}, end: {end} }} : TextRange).length(), {end - start})\n}}\n'
    artifact = v.artifact(case, "counterexample_regression.mbt")
    if artifact.read_text() != code or replay.get("regression_sha256") != digest(artifact) or replay.get("concrete_valid_input") != {"start": start, "end": end} or replay.get("expected") != end-start:
        raise RuntimeError("regression artifact/input differs from actual shrunk tuple")
    for name in ("regression-pristine", "regression-remutated"):
        out = contained_directory(case, name)
        checkout = contained_directory(out, "source")
        files = v.snapshot(source)
        if name == "regression-remutated":
            data = (source / mapped["path"]).read_bytes()
            changed = data[:mapped["offset"]] + mapped["replacement"].encode() + data[mapped["end"]:]
            files[mapped["path"]] = {**files[mapped["path"]], "sha256": hashlib.sha256(changed).hexdigest()}
        files["text/turtles_counterexample_regression_wbtest.mbt"] = {"sha256": hashlib.sha256(code.encode()).hexdigest(), "mode": 0o644, "link": None}
        if v.snapshot(checkout) != files:
            raise RuntimeError("regression snapshot has undeclared changes")
        outcome = audit_runtime(v, out, replay.get(name), checkout, home, profile)
        if outcome != ("SURVIVED" if name == "regression-pristine" else "KILLED"):
            raise RuntimeError("regression original/re-mutation oracle failed")
    if not any(kill.get("test_name") == "turtles deterministic shrunk range regression" and kill.get("filename") == "turtles_counterexample_regression_wbtest.mbt" for kill in replay["regression-remutated"]["killed_by"]):
        raise RuntimeError("same mutant was not killed by its generated concrete regression")


def execute(args):
    repo = args.repo.resolve(strict=True)
    output = args.output.absolute()
    if output.is_symlink() or output.resolve().is_relative_to(repo):
        raise RuntimeError("fresh integration output must be outside the source checkout")
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve(strict=True)
    invocation = {"schema": 1, "run_id": str(uuid.uuid4()), "terminal": False, "status": "initializing", "ok": False,
                  "started_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "runner_sha256": digest(Path(__file__)), "integration_lock_sha256": digest(LOCK_PATH)}
    handlers = {}
    def interrupted(signum, _frame):
        raise KeyboardInterrupt("received signal " + str(signum))
    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            handlers[signum] = signal.signal(signum, interrupted)
        turtles_root, binary, profile_path, home, why3, solver = [value.resolve(strict=True) for value in (args.turtles_root, args.turtles_bin, args.profile, args.moon_home, args.why3, args.solver)]
        child_environment, normalized = portable_environment(repo, dict(os.environ))
        invocation["portable_environment"] = normalized
        lock, v, _, _, _ = load_inputs(repo, turtles_root, binary, profile_path, home, why3, solver, child_environment)
        invocation["ephemeral_workflow"] = workflow_binding(repo, args.ephemeral_workflow)
        invocation["source_origin"] = {"commit": git_value(repo, "HEAD"), "tree": git_value(repo, "HEAD^{tree}")}
        v.write_json(output / "invocation.json", invocation)
        command = [sys.executable, str(HERE / "turtles-verification-adapter.py"), "--profile", str(profile_path), "--source-root", str(repo), "--turtles-bin", str(binary), "--artifact-dir", str(output / "campaign"), "--moon-home", str(home), "--why3", str(why3), "--solver", str(solver)]
        invocation["process"] = v.run(command, repo, child_environment, output / "companion.log", lock["maximum_stage_seconds"])
        if invocation["process"]["exit_code"] != 0 or invocation["process"]["timed_out"]:
            raise RuntimeError("bounded real-mutant companion failed, timed out or was blocked")
        raw = v.read_json(v.artifact(output / "campaign", "verification-report.json"))
        invocation.update(terminal=True, status="auditing", ok=False, campaign_run_id=raw["run_id"], campaign_report_sha256=digest(output / "campaign/verification-report.json"),
                          finished_utc=dt.datetime.now(dt.timezone.utc).isoformat())
        v.write_json(output / "invocation.json", invocation)
        env = {**os.environ, "GPUI_TURTLES_VERIFICATION_ROOT": str(turtles_root), "GPUI_TURTLES_SCHEMA3_BIN": str(binary), "GPUI_TURTLES_VERIFICATION_PROFILE": str(profile_path),
               "MOON_HOME": str(home), "GPUI_PROOF_WHY3": str(why3), "GPUI_PROOF_SOLVER": str(solver)}
        audited = _validate(output, repo, env, invocation["ephemeral_workflow"], allow_auditing=True)
        v.write_json(output / "audited-summary.json", audited)
        invocation.update(status="passed", ok=True, audit_receipt_sha256=digest(output / "audited-summary.json"))
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        invocation.update(ok=False, status="blocked", reason=str(error))
    except KeyboardInterrupt as error:
        invocation.update(ok=False, status="interrupted", reason=str(error) or "interrupted")
    finally:
        for signum, handler in handlers.items():
            signal.signal(signum, handler)
        invocation["terminal"] = True
        invocation["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        temporary = output / "invocation.json.tmp"
        temporary.write_text(json.dumps(invocation, indent=2) + "\n")
        temporary.replace(output / "invocation.json")
    print(json.dumps({key: invocation.get(key) for key in ("ok", "status", "reason", "campaign_run_id")}))
    return 0 if invocation["ok"] else 2


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=REPO)
    parser.add_argument("--turtles-root", type=Path, required=True)
    parser.add_argument("--turtles-bin", type=Path, required=True)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--moon-home", type=Path, required=True)
    parser.add_argument("--why3", type=Path, required=True)
    parser.add_argument("--solver", type=Path, required=True)
    parser.add_argument("--ephemeral-workflow", type=Path)
    return execute(parser.parse_args(argv))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, ValueError) as error:
        print(json.dumps({"ok": False, "status": "blocked", "reason": str(error)}))
        sys.exit(2)
