#!/usr/bin/env python3
"""Use the existing collector and predicates, with an explicit test producer."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

repo, app, profile, run, activation = map(Path, sys.argv[1:])
repo, app, profile, run = (p.resolve(strict=True) for p in (repo, app, profile, run))
binary = app / "Contents/MacOS/GpuiTextField"
spec = importlib.util.spec_from_file_location("gpui_ime", repo / "infra/macos-desktop/ime-acceptance.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original = subprocess.Popen
requests = []
class OwnedPopen(original):
    def __init__(self, args, *a, **kw):
        super().__init__(args, *a, **kw)
        if isinstance(args, list) and args and Path(args[0]) == binary:
            result = subprocess.run([str(activation), str(self.pid), str(binary)],
                                    capture_output=True, text=True, timeout=5)
            requests.append({"pid": self.pid, "status": result.returncode,
                             "stdout": result.stdout, "stderr": result.stderr})
            pid_file = run / "app.pid"
            fd = os.open(pid_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(str(self.pid))
producer = activation.parent / "producer"
def source_snapshot():
    return json.loads(subprocess.check_output([str(producer), "--source", str(os.geteuid())], text=True, timeout=5))
source_before = source_snapshot()
subprocess.Popen = OwnedPopen
os.environ.update({"GPUI_FIELD_MACOS_IME_TIMING_TRACE": "1", "GPUI_FIELD_MACOS_IME_DISPATCH_TRACE": "1"})
try:
    # execute preserves the existing gate and all three screenshot handshakes.
    # Its result alone is not Product Green: root validates producer evidence next.
    report = module.execute(profile, app, run / "acceptance", repo, 90)
    (run / "collector-result.json").write_text(json.dumps({"status": "PASS", "ok": report["ok"]}, indent=2))
except Exception as error:
    (run / "collector-result.json").write_text(json.dumps({"status": "FAIL", "error": str(error)}, indent=2))
    print(str(error), file=sys.stderr)
    sys.exit(1)
finally:
    subprocess.Popen = original
    source_after = source_snapshot()
    (run / "input-source.json").write_text(json.dumps({"before": source_before, "after": source_after}, indent=2))
    (run / "activation.json").write_text(json.dumps(requests, indent=2))
