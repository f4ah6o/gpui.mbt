#!/usr/bin/env python3
"""Additional producer proof; never substitutes for existing IME/pixel gates."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

CODES = [45,34,4,31,45,5,31,49,36,45,53]
TEXTS = ["n","i","h","o","n","g","o"," ","\r","n","\x1b"]

def require(value, message):
    if not value:
        raise ValueError(message)

def validate_producer(records, app_pid):
    peer = [r for r in records if r.get("kind") == "peer"]
    require(len(peer) == 1 and peer[0]["pid"] == app_pid and peer[0]["uid"] == 501, "authenticated target peer")
    queued = [r for r in records if r.get("kind") == "pair_queued"]
    reports = [r for r in records if r.get("kind") == "report"]
    received = [r for r in records if r.get("kind") == "received"]
    probes = [r for r in records if r.get("kind") == "gui_probe"]
    ended = [r for r in records if r.get("kind") == "ended"]
    require(len(queued) == 11 and len(reports) == len(received) == 22, "exact 11 pairs / 22 reports and receipts")
    require(len(probes) == 11 and all(r.get("ok") is True for r in probes), "all source/target probes")
    require(len(ended) == 1 and ended[0].get("ok") is True and ended[0].get("received") == 22, "producer completion")
    nonces = set()
    timings = []
    for i, code in enumerate(CODES):
        queue = queued[i]
        request = queue["request"]
        nonce = request["nonce"]
        require(nonce not in nonces and len(nonce) == 36, "unique pair nonce")
        nonces.add(nonce)
        require(request["dispatch_id"] == i+1 and request["key_code"] == code and
                request["pid"] == app_pid and request["characters"] == request["ignoring"] == TEXTS[i], "fixed key sequence")
        require(queue["report_count"] == 2 and queue["hold_ms"] == 50, "both actual scheduler reports queued")
        for j, phase in enumerate(("down", "up")):
            report, receipt = reports[2*i+j], received[2*i+j]
            require(all(r["nonce"] == nonce and r["dispatch_id"] == i+1 and r["key_code"] == code and
                        r["phase"] == phase for r in (report, receipt)), "pair/phase/order correlation")
            require(report["monotonic_ms"] >= queue["monotonic_ms"], "report follows queue")
            require(abs(receipt["report_ms"] - report["monotonic_ms"]) < 1, "authenticated report timestamp")
            require(-1 <= receipt["event_uptime_ms"] - report["uptime_ms"] <= 500, "actual event follows producer report")
            require(abs(receipt["report_uptime_ms"] - report["uptime_ms"]) < 1 and
                    receipt["characters"] == receipt["ignoring"] == TEXTS[i] and receipt["flags"] == 256 and
                    receipt["source_pid"] == 0 and receipt["source_state"] == 1 and
                    receipt["keyboard_type"] == 40 and receipt["user_data"] == 0, "real HID event metadata")
        hold = reports[2*i+1]["monotonic_ms"] - reports[2*i]["monotonic_ms"]
        require(hold >= 50, "independent 50ms release")
        timings.append({"dispatch_id": i+1, "key_code": code, "report_hold_ms": hold,
                        "event_hold_ms": received[2*i+1]["event_uptime_ms"] - received[2*i]["event_uptime_ms"]})
    return timings

def main(repo, run):
    repo, run = Path(repo).resolve(strict=True), Path(run).resolve(strict=True)
    result = {"product_green": False, "producer_validation": "FAIL", "acceptance_validation": "NOT_RUN"}
    try:
        for manifest in ("binaries.sha256", "sources.sha256"):
            for line in (run / manifest).read_text().splitlines():
                expected, path = line.split("  ", 1)
                require(hashlib.sha256(Path(path).read_bytes()).hexdigest() == expected, "producer binary/source identity")
        require((run / "collector.exit").read_text().strip() == "0" and
                (run / "producer.exit").read_text().strip() == "0", "collector/producer exit")
        records = [json.loads(line) for line in (run / "producer.jsonl").read_text().splitlines()]
        result["timings"] = validate_producer(records, int((run / "app.pid").read_text()))
        result["producer_validation"] = "PASS"
        spec = importlib.util.spec_from_file_location("gpui_ime", repo / "infra/macos-desktop/ime-acceptance.py")
        ime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(ime)
        ime.validate_summary(run / "acceptance/summary.json", repo)
        summary = json.loads((run / "acceptance/summary.json").read_text())
        final = summary["final_acceptance"]
        queued = [r for r in records if r.get("kind") == "pair_queued"]
        window = summary["initial_checkpoint"]["window_geometry"]["native_window_id"]
        for pair, receipt in zip(queued, final["receipts"]):
            request = pair["request"]
            require(request["window"] == window and all(request[key] == receipt[key]
                    for key in ("dispatch_id", "key_code", "host_epoch", "session_epoch")), "native acceptance / HID identity binding")
        result["acceptance_validation"] = "PASS"
        cleanup = json.loads((run / "runtime-cleanup.json").read_text())
        require(cleanup["owned_daemon_stopped"] and cleanup["producer_stopped"] and cleanup["app_stopped"], "owned process cleanup")
        sources = json.loads((run / "input-source.json").read_text())
        require(sources["before"]["input_source"] == sources["after"]["input_source"] and
                sources["after"]["uid"] == 501, "GUI input source restoration")
        result["cleanup"] = "PASS"
        result["product_green"] = True
    except Exception as error:
        result["error"] = str(error)
    result["artifacts"] = {str(p.relative_to(run)): hashlib.sha256(p.read_bytes()).hexdigest()
                           for p in run.rglob("*") if p.is_file() and p.name not in ("virtual-hid-validation.json", "validation.stdout.log", "validation.stderr.log")}
    (run / "virtual-hid-validation.json").write_text(json.dumps(result, indent=2, ensure_ascii=False)+"\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("timings", "artifacts")}, ensure_ascii=False))
    return 0 if result["product_green"] else 1

if __name__ == "__main__":
    sys.exit(main(*sys.argv[1:]))
