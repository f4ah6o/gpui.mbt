#!/usr/bin/env python3
"""Small, strict v1/v2 OS-input case catalog. Validation never launches a process."""
import argparse
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
CASES = HERE / "fixtures/cases"
VERSIONS = (1, 2)
MAX_BYTES = 65536
MODIFIERS = ("Control_L", "Shift_L")
KEYSYMS = set("abcdefghijklmnopqrstuvwxyz0123456789") | {
    "Left", "Right", "Home", "End", "BackSpace", "Delete", "Escape",
    "Return", "Tab", "space", "Shift_L", "Control_L",
}
DISPOSITIONS = {"supported", "pending", "unsupported", "expected-failure"}
ARTIFACTS = ["case.json", "result.json", "focused.png", "final.png", "app.log",
             "weston.log", "xvfb.log", "events.jsonl"]
SHA256 = re.compile(r"[a-f0-9]{64}\Z")
GIT_SHA = re.compile(r"[a-f0-9]{40}\Z")
NAME = re.compile(r"[a-z][a-z0-9]*(?:-[a-z0-9]+)*\Z")


class CaseError(ValueError):
    pass


def fail(where, message):
    raise CaseError(f"{where}: {message}")


def obj(value, required, where):
    if not isinstance(value, dict):
        fail(where, "expected object")
    if set(value) != set(required):
        missing = sorted(set(required) - set(value))
        unknown = sorted(set(value) - set(required))
        fail(where, f"missing fields {missing}; unknown fields {unknown}")


def integer(value, low, high, where):
    if type(value) is not int or not low <= value <= high:
        fail(where, f"expected integer in [{low}, {high}]")


def string(value, low, high, where):
    if not isinstance(value, str) or not low <= len(value) <= high:
        fail(where, f"expected string length in [{low}, {high}]")
    try:
        value.encode("utf-8", errors="strict")
    except UnicodeEncodeError:
        fail(where, "unpaired surrogate is forbidden")


def named(value, where):
    string(value, 1, 64, where)
    if not NAME.fullmatch(value):
        fail(where, "expected lowercase hyphenated name")


def hash_value(value, regex, where, nullable=False):
    if nullable and value is None:
        return
    if not isinstance(value, str) or not regex.fullmatch(value):
        fail(where, "invalid lowercase hash")


def utf16_boundaries(text):
    boundaries = {0}
    length = 0
    for scalar in text:
        length += 2 if ord(scalar) > 0xffff else 1
        boundaries.add(length)
    return boundaries


def validate_state(value, where):
    obj(value, {"text", "selection", "focused"}, where)
    string(value["text"], 0, 4096, where + ".text")
    if any(ord(c) < 32 or ord(c) == 127 for c in value["text"]):
        fail(where + ".text", "single-line visible text required")
    if type(value["focused"]) is not bool:
        fail(where + ".focused", "expected boolean")
    obj(value["selection"], {"anchor", "head"}, where + ".selection")
    boundaries = utf16_boundaries(value["text"])
    for key in ("anchor", "head"):
        offset = value["selection"][key]
        integer(offset, 0, max(boundaries), where + ".selection." + key)
        if offset not in boundaries:
            fail(where + ".selection." + key, "offset splits UTF-16 surrogate")


def validate_event(event, where):
    if not isinstance(event, dict) or "type" not in event:
        fail(where, "event object needs type")
    kind = event["type"]
    if kind in ("key", "hold"):
        fields = {"type", "keysym", "modifiers"}
        if kind == "hold":
            fields.add("duration_ms")
        obj(event, fields, where)
        if not isinstance(event["keysym"], str) or event["keysym"] not in KEYSYMS:
            fail(where + ".keysym", "unsupported keysym; no text/paste injection")
        modifiers = event["modifiers"]
        if not isinstance(modifiers, list) or len(modifiers) > 2 or any(
                not isinstance(m, str) or m not in MODIFIERS for m in modifiers):
            fail(where + ".modifiers", "only Control_L and Shift_L are allowed")
        if len(set(modifiers)) != len(modifiers) or event["keysym"] in modifiers:
            fail(where + ".modifiers", "duplicate key or modifier")
        if kind == "hold":
            integer(event["duration_ms"], 1, 2000, where + ".duration_ms")
    elif kind == "focus":
        obj(event, {"type", "target"}, where)
        if event["target"] not in ("app", "away"):
            fail(where + ".target", "focus target must be the owned app or private decoy")
    elif kind == "click":
        obj(event, {"type", "x", "y"}, where)
        integer(event["x"], 0, 959, where + ".x")
        integer(event["y"], 0, 479, where + ".y")
    elif kind == "wait":
        obj(event, {"type", "duration_ms"}, where)
        integer(event["duration_ms"], 1, 2000, where + ".duration_ms")
    else:
        fail(where + ".type", "unknown event type")


def validate_case(case):
    if not isinstance(case, dict) or type(case.get("version")) is not int or case["version"] not in VERSIONS:
        fail("case.version", "unsupported format version")
    fields = {"version", "id", "description", "platform", "disposition", "reason",
               "timeout_ms", "initial", "focus_click", "steps", "oracle",
               "expected_failure", "artifacts"}
    if case["version"] == 1:
        fields.add("provenance")
    obj(case, fields, "case")
    named(case["id"], "case.id")
    string(case["description"], 1, 1024, "case.description")
    if case["platform"] != "linux-x11-weston":
        fail("case.platform", "only the proven Linux X11→Weston route is supported")
    if not isinstance(case["disposition"], str) or case["disposition"] not in DISPOSITIONS:
        fail("case.disposition", "unknown disposition")
    string(case["reason"], 1, 2048, "case.reason")
    integer(case["timeout_ms"], 1000, 60000, "case.timeout_ms")
    validate_state(case["initial"], "case.initial")
    validate_event(case["focus_click"], "case.focus_click")
    if case["focus_click"]["type"] != "click":
        fail("case.focus_click", "must be click")
    steps = case["steps"]
    if not isinstance(steps, list) or not 0 <= len(steps) <= 32:
        fail("case.steps", "expected at most 32 steps")
    if not steps and case["disposition"] != "unsupported":
        fail("case.steps", "at least one step required")
    ids, total_events, total_wait = set(), 0, 0
    for index, step in enumerate(steps):
        where = f"case.steps[{index}]"
        obj(step, {"id", "events", "expect"}, where)
        named(step["id"], where + ".id")
        if step["id"] in ids:
            fail(where + ".id", "duplicate step name")
        ids.add(step["id"])
        events = step["events"]
        if not isinstance(events, list) or not 1 <= len(events) <= 128:
            fail(where + ".events", "expected 1–128 events")
        for event_index, event in enumerate(events):
            validate_event(event, f"{where}.events[{event_index}]")
            total_wait += event.get("duration_ms", 0)
        total_events += len(events)
        validate_state(step["expect"], where + ".expect")
    if total_events > 256 or total_wait + 1000 > case["timeout_ms"]:
        fail("case.steps", "event count or wait budget exceeds bounds")
    oracle = case["oracle"]
    if not isinstance(oracle, dict) or "kind" not in oracle:
        fail("case.oracle", "expected oracle object")
    kind = oracle["kind"]
    if kind == "reviewed_pixels":
        obj(oracle, {"kind", "fixture", "rgba_sha256", "review", "ocr_prefix", "ocr_suffix"}, "case.oracle")
        if oracle["fixture"] != "field-six-keys.png":
            fail("case.oracle.fixture", "only the existing reviewed six-key golden is accepted")
        hash_value(oracle["rgba_sha256"], SHA256, "case.oracle.rgba_sha256")
        string(oracle["review"], 1, 1024, "case.oracle.review")
        for key in ("ocr_prefix", "ocr_suffix"):
            string(oracle[key], 1, 128, "case.oracle." + key)
        if len(steps) != 1:
            fail("case.oracle", "reviewed six-key pixels cover one final checkpoint")
        known_initial = {"text": "Hello 日本", "selection": {"anchor": 8, "head": 8}, "focused": True}
        known_final = {"text": "Hello 日本abD", "selection": {"anchor": 10, "head": 10}, "focused": True}
        known_events = [{"type": "key", "keysym": key, "modifiers": mods}
                        for key, mods in [("a", []), ("b", []), ("c", []), ("d", ["Shift_L"]), ("Left", []), ("BackSpace", [])]]
        if case["initial"] != known_initial or steps[0]["expect"] != known_final or steps[0]["events"] != known_events:
            fail("case.oracle", "existing pixel golden covers only the exact declared six-key scenario")
        if oracle["rgba_sha256"] != "44f395449323e0e7581d04b6d012b4463819d65e0914aa53f0e662d534eb74d9":
            fail("case.oracle", "existing pixel golden hash must not be replaced automatically")
    elif kind == "presented_state":
        obj(oracle, {"kind", "version", "prefix", "review"}, "case.oracle")
        if oracle["version"] != 1 or type(oracle["version"]) is not int or oracle["prefix"] != "GPUI_FIELD_STATE ":
            fail("case.oracle", "unsupported observer contract")
        string(oracle["review"], 1, 1024, "case.oracle.review")
    elif kind == "pending":
        obj(oracle, {"kind", "reason"}, "case.oracle")
        string(oracle["reason"], 1, 2048, "case.oracle.reason")
    else:
        fail("case.oracle.kind", "unknown oracle")
    failure = case["expected_failure"]
    if case["disposition"] == "expected-failure":
        obj(failure, {"kind", "observed"}, "case.expected_failure")
        if failure["kind"] != "state_mismatch":
            fail("case.expected_failure.kind", "only exact observed state mismatch is described")
        validate_state(failure["observed"], "case.expected_failure.observed")
        if not steps or failure["observed"] == steps[-1]["expect"]:
            fail("case.expected_failure", "failure state must differ from intended final state")
    elif failure is not None:
        fail("case.expected_failure", "only expected-failure cases may declare failure")
    if case["artifacts"] != ARTIFACTS:
        fail("case.artifacts", "required artifact list must be retained without custom paths")
    if case["disposition"] == "supported" and kind == "pending":
        fail("case.oracle", "supported case needs a reviewed oracle")
    if case["disposition"] == "expected-failure" and kind not in {"pending", "presented_state"}:
        fail("case.oracle", "expected-failure requires exact presented state")
    if case["version"] == 1:
        source = case["provenance"]
        obj(source, {"source_commit", "source_tree", "app_sha256", "patch_sha256", "fontconfig_sha256", "notes"}, "case.provenance")
        for key in ("source_commit", "source_tree"):
            hash_value(source[key], GIT_SHA, "case.provenance." + key)
        for key in ("app_sha256", "patch_sha256", "fontconfig_sha256"):
            hash_value(source[key], SHA256, "case.provenance." + key, nullable=True)
        string(source["notes"], 1, 2048, "case.provenance.notes")
        if case["disposition"] == "supported" and any(source[key] is None for key in ("app_sha256", "fontconfig_sha256")):
            fail("case.provenance", "supported case requires app/fontconfig hashes")
    return case


def reject_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise CaseError("duplicate JSON field: " + key)
        value[key] = item
    return value


def load_case(path):
    path = Path(path)
    if path.stat().st_size > MAX_BYTES:
        raise CaseError("case file exceeds 64 KiB: " + str(path))
    try:
        case = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicates,
                          parse_constant=lambda value: fail("JSON", "non-finite number " + value))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise CaseError(f"invalid JSON in {path}: {error}") from error
    return validate_case(case)


def catalog(directory=CASES):
    cases = [load_case(path) for path in sorted(Path(directory).glob("*.json"))]
    if len({case["id"] for case in cases}) != len(cases):
        raise CaseError("duplicate catalog case id")
    return cases


def select_case(value, directory=CASES):
    path = Path(value)
    if path.is_file():
        return load_case(path)
    return load_case(Path(directory) / (value + ".json"))


def runnable(case):
    return case["disposition"] in {"supported", "expected-failure"} and case["oracle"]["kind"] != "pending"


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases-dir", type=Path, default=CASES)
    choice = parser.add_mutually_exclusive_group()
    choice.add_argument("--case", help="catalog name or JSON file")
    choice.add_argument("--all", action="store_true", help="validate every catalog case")
    parser.add_argument("--list", action="store_true", help="list validated catalog")
    args = parser.parse_args(argv)
    try:
        cases = [select_case(args.case, args.cases_dir)] if args.case else catalog(args.cases_dir)
        for case in cases:
            if args.list:
                print(f"{case['id']}\t{case['disposition']}\t{'ready' if runnable(case) else 'blocked'}\t{case['reason']}")
            else:
                print(f"validated {case['id']} (v{case['version']}, {case['disposition']})")
    except (CaseError, OSError) as error:
        parser.exit(2, str(error) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
