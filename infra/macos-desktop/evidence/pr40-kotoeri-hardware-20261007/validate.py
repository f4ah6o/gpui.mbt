#!/usr/bin/env python3
"""Validate an unresolved boundary archive; never promote NOT_RUN to Green."""
import hashlib
import json
from pathlib import Path

root = Path(__file__).resolve().parent
manifest = json.loads((root / "files-sha256.json").read_text())
for name, expected in manifest.items():
    assert hashlib.sha256((root / name).read_bytes()).hexdigest() == expected, name

def records(name):
    return [json.loads(line.split(" ", 1)[1]) for line in (root / name).read_text().splitlines()
            if line.startswith("GPUI_KOTOERI_CONTROL ")]

synthetic = json.loads((root / "synthetic.stdout.log").read_text())
assert synthetic["prefix_valid"] and not synthetic["passed"]
assert synthetic["down_delivered"] and synthetic["up_delivered"]
assert synthetic["return_iterations"] == 200 and synthetic["marked"]
assert synthetic["expected_text"] and synthetic["insert_delta"] == synthetic["unmark_delta"] == 0
assert synthetic["source_restored"] and synthetic["window_closed"] and synthetic["cleanup_ok"]
assert synthetic["original_input_source"] == synthetic["restored_input_source"]
trace = records("synthetic.stderr.log")
assert len(trace) <= 192
assert all(a["monotonic_ms"] <= b["monotonic_ms"] for a, b in zip(trace, trace[1:]))
start = next(r for r in trace if r["phase"] == "before_return")
end = next(r for r in trace if r["phase"] == "observation_end")
for counter in ("native_event_pumps", "appkit_event_pumps"):
    assert end[counter] - start[counter] + 1 == 200
for event_phase in ("app_key_down", "app_key_up", "view_key_down", "view_key_up"):
    assert [r["key_code"] for r in trace if r["phase"] == event_phase] == [45, 34, 4, 31, 45, 5, 31, 49, 36]
assert all(r["selected_input_source"] == "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
           and r["application_active"] and r["key_window"] and r["first_responder_is_view"]
           and r["current_input_context_is_view"] and r["input_context_unchanged"] for r in trace)
assert start["text"] == "Hello 日本語" and start["committed_text"] == end["committed_text"] == "Hello "
assert end["return_down_elapsed_ms"] >= end["return_up_elapsed_ms"] > 0

hardware = json.loads((root / "hardware-readiness.stdout.log").read_text())
assert hardware["status"] == "NOT_RUN" and not hardware["passed"] and not hardware["return_observed"]
assert hardware["return_down_count"] == hardware["return_up_count"] == hardware["return_iterations"] == 0
assert hardware["return_native_pumps"] == hardware["return_appkit_pumps"] == 0
assert hardware["source_restored"] and hardware["window_closed"] and hardware["cleanup_ok"]
assert [r["phase"] for r in records("hardware-readiness.stderr.log")] == ["ready", "observation_end"]
for name in ("synthetic.activation.json", "hardware-readiness.activation.json"):
    activation = json.loads((root / name).read_text())
    assert activation["executable_matches"] and activation["activation_request_sent"]
provenance = json.loads((root / "provenance.json").read_text())
assert provenance["hardware_return_status"] == "NOT_RUN" and provenance["hardware_input_confirmation"] is None
assert not provenance["product_changed"] and not provenance["product_green"]
print("PASS: hashes, synthetic failure/200 pumps, hardware NOT_RUN, ownership/cleanup; boundary unresolved, Product Green false")
