#!/usr/bin/env python3
"""Run bounded declarative cases through XTest → private Xvfb → Weston → GPUI.
Run this only in an authorized process-launch context. EPERM is not retried by
changing launch routes, sandbox settings or display targets. No live desktop
input or GPUI edit callbacks are used. Importing this module launches nothing.
"""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import time

import input_cases

HERE = Path(__file__).resolve().parent
STATE_PREFIX = "GPUI_FIELD_STATE "
KEY_EVENT = re.compile(r"wl_keyboard(?:#|@)\d+\.key\(")
KEYBOARD_ENTER = re.compile(r"wl_keyboard(?:#|@)\d+\.enter\(")
KEYBOARD_LEAVE = re.compile(r"wl_keyboard(?:#|@)\d+\.leave\(")
FRAME = re.compile(r"\{Default Queue\}[^\n]*wl_surface(?:#|@)(?P<surface>\d+)\.frame\(new id wl_callback(?:#|@)(?P<callback>\d+)\)")
DONE = re.compile(r"\{Default Queue\}[^\n]*wl_callback(?:#|@)(\d+)\.done\(")
POINTER_ENTER = re.compile(r"wl_pointer(?:#|@)\d+\.enter\(\d+,\s*wl_surface(?:#|@)(\d+),\s*([-\d.]+),\s*([-\d.]+)\)")
POINTER_LEAVE = re.compile(r"wl_pointer(?:#|@)\d+\.leave\(")
POINTER_MOTION = re.compile(r"wl_pointer(?:#|@)\d+\.motion\(\d+,\s*([-\d.]+),\s*([-\d.]+)\)")
POINTER_BUTTON = re.compile(r"wl_pointer(?:#|@)\d+\.button\(\d+,\s*\d+,\s*(\d+),\s*(\d+)\)")
XKB_RESOURCES = ("rules/evdev", "keycodes/evdev", "symbols/pc", "symbols/us", "types/complete", "compat/complete")


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def read_log(path):
    return path.read_text(errors="replace") if path.exists() else ""


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def auth_file(path, number, cookie):
    fields = (b"", str(number).encode(), b"MIT-MAGIC-COOKIE-1", cookie)
    path.write_bytes(struct.pack(">H", 65535) + b"".join(
        struct.pack(">H", len(field)) + field for field in fields))
    path.chmod(0o600)


def private_display_number(inherited_display, choose=None, exists=None):
    """Never select the caller's display or an occupied X socket/lock."""
    choose = choose or (lambda: 1000 + secrets.randbelow(10000))
    exists = exists or (lambda path: path.exists())
    match = re.search(r":(\d+)(?:\.\d+)?$", inherited_display or "")
    inherited_number = int(match.group(1)) if match else None
    number = choose()
    if type(number) is not int or not 1000 <= number < 11000:
        raise RuntimeError("invalid private display allocation")
    if number == inherited_number:
        raise RuntimeError("refusing inherited display")
    if exists(Path(f"/tmp/.X{number}-lock")) or exists(Path(f"/tmp/.X11-unix/X{number}")):
        raise RuntimeError("private display number already in use")
    return number


def xvfb_readiness(process, number, framebuffer, uid=None):
    """Read-only readiness for the owned server; never probes a connection."""
    if process.poll() is not None:
        raise RuntimeError("owned Xvfb exited before readiness")
    uid = os.geteuid() if uid is None else uid
    lock = Path(f"/tmp/.X{number}-lock")
    socket = Path(f"/tmp/.X11-unix/X{number}")
    paths = [(lock, stat.S_ISREG), (socket, stat.S_ISSOCK), (Path(framebuffer), stat.S_ISREG)]
    observations = []
    for path, allowed in paths:
        try:
            entry = path.lstat()
        except FileNotFoundError:
            return None
        if entry.st_uid != uid or not allowed(entry.st_mode):
            raise RuntimeError("owned Xvfb readiness ownership/type mismatch: " + str(path))
        observations.append([entry.st_dev, entry.st_ino, entry.st_uid, entry.st_mode, entry.st_size])
    pid_text = lock.read_text(encoding="ascii").strip()
    if not pid_text:
        return None
    if not pid_text.isdecimal() or int(pid_text) != process.pid:
        raise RuntimeError("Xvfb lock PID does not match the owned child")
    if observations[-1][-1] < 100:
        return None
    return {"pid": process.pid, "display": number, "identities": observations}


def connect_owned_once(x, process, display, authority, number, framebuffer, wait, pause):
    ready = wait(lambda: xvfb_readiness(process, number, framebuffer), "owned Xvfb PID/socket/framebuffer readiness")
    pause(80)
    if xvfb_readiness(process, number, framebuffer) != ready:
        raise RuntimeError("owned Xvfb readiness drift before authenticated connection")
    if not x.connect(display, authority):
        raise RuntimeError("one authenticated private X connection failed; no retry")
    return ready


def presented_states(log):
    """Parse the proposed read-only observer. It is never an input channel."""
    states = []
    previous_presentation = 0
    for line in log.splitlines():
        if not line.startswith(STATE_PREFIX):
            continue
        try:
            record = json.loads(line[len(STATE_PREFIX):], object_pairs_hook=input_cases.reject_duplicates)
            input_cases.obj(record, {"version", "presentation", "text", "selection", "focused", "revision"}, "observer")
            if type(record["version"]) is not int or record["version"] != 1:
                raise input_cases.CaseError("unsupported observer version")
            input_cases.integer(record["presentation"], previous_presentation + 1, 2**53 - 1, "observer.presentation")
            input_cases.integer(record["revision"], 0, 2**53 - 1, "observer.revision")
            input_cases.validate_state({key: record[key] for key in ("text", "selection", "focused")}, "observer.state")
        except (ValueError, TypeError) as error:
            raise RuntimeError("invalid presented-state record: " + str(error)) from error
        previous_presentation = record["presentation"]
        states.append(record)
    return states


def state_of(record):
    return {key: record[key] for key in ("text", "selection", "focused")}


def completed_frame(log, observer=False):
    """Match the actual app queue callback; accepted state alone is insufficient."""
    accepted_at = log.rfind(STATE_PREFIX) if observer else len(log)
    if accepted_at < 0:
        return None
    requests = list(FRAME.finditer(log[:accepted_at]))
    if not requests:
        return None
    request = requests[-1]
    after = accepted_at if observer else request.end()
    done = [match for match in DONE.finditer(log, after) if match[1] == request["callback"]]
    if not done:
        return None
    result = {"surface_id": int(request["surface"]), "callback_id": int(request["callback"]),
              "request_offset": request.start(), "done_offset": done[-1].start(),
              "queue": "Default Queue", "callback_completed": True}
    if observer:
        result.update(accepted_record=presented_states(log)[-1], accepted_state_offset=accepted_at,
                      callback_completed_after_accepted=True)
    return result


def pointer_ready(log, surface, x, y):
    """Require wire pointer focus/coordinates before sending the click."""
    target = None
    for line in log.splitlines():
        enter, motion = POINTER_ENTER.search(line), POINTER_MOTION.search(line)
        if enter:
            target = (int(enter[1]), float(enter[2]), float(enter[3]))
        elif POINTER_LEAVE.search(line):
            target = None
        elif motion and target is not None:
            target = (target[0], float(motion[1]), float(motion[2]))
    return target == (surface, float(x), float(y))


def key_event_count(case, client_only=False):
    """Separate all OS key actions from keys routed to the GPUI client.
    Field-level blur leaves the client focused; private-window focus-away does
    not. Held keys can add genuine compositor repeats to the minimum count.
    """
    count, target = 0, "app"
    for step in case["steps"]:
        for event in step["events"]:
            if event["type"] == "focus":
                target = event["target"]
            elif event["type"] in {"key", "hold"} and (not client_only or target == "app"):
                count += 2 * (1 + len(event["modifiers"]))
    return count


def physical_actions(event):
    """The concrete XTest press/release/motion sequence, not GPUI callbacks."""
    kind = event["type"]
    if kind == "focus":
        return [{"type": "focus", "target": event["target"]}]
    if kind == "click":
        return [{"type": "motion", "x": event["x"], "y": event["y"]},
                {"type": "button", "button": 1, "down": True},
                {"type": "button", "button": 1, "down": False}]
    if kind == "wait":
        return [{"type": "wait", "duration_ms": event["duration_ms"]}]
    names = event["modifiers"] + [event["keysym"]]
    actions = [{"type": "key", "keysym": name, "down": True} for name in names]
    if kind == "hold":
        actions.append({"type": "wait", "duration_ms": event["duration_ms"]})
    return actions + [{"type": "key", "keysym": name, "down": False} for name in reversed(names)]


def verify_prefix_resources(prefix):
    root = prefix / "usr/share/X11/xkb"
    missing = [name for name in XKB_RESOURCES if not (root / name).is_file()]
    if missing:
        raise RuntimeError("missing private prefix XKB resources under " + str(root) + ": "
                           + ", ".join(missing) + "; materialize the reviewed locked xkb-data archive "
                           "or use a fully bootstrapped profile. No host-XKB fallback is used.")
    return {name: digest(root / name) for name in XKB_RESOURCES}


def verify_v1_inputs(case, args):
    for name in ("prefix", "repo", "app", "fontconfig"):
        path = getattr(args, name)
        if not path or not path.exists():
            raise RuntimeError("missing runtime input: --" + name)
    xkb_resources = verify_prefix_resources(args.prefix)
    if not args.app.is_file() or not os.access(args.app, os.X_OK):
        raise RuntimeError("app must be an executable file")
    expected = args.app_sha256
    input_cases.hash_value(expected, input_cases.SHA256, "--app-sha256")
    if digest(args.app) != expected:
        raise RuntimeError("refusing changed app")
    source = case["provenance"]
    if source["app_sha256"] is None or source["fontconfig_sha256"] is None:
        raise RuntimeError("case has no reviewed app/fontconfig pins")
    if expected != source["app_sha256"] or digest(args.fontconfig) != source["fontconfig_sha256"]:
        raise RuntimeError("runtime app/fontconfig does not match reviewed case")
    head = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "HEAD"], text=True, timeout=3).strip()
    tree = subprocess.check_output(["git", "-C", str(args.repo), "rev-parse", "HEAD^{tree}"], text=True, timeout=3).strip()
    if head != source["source_commit"] or tree != source["source_tree"]:
        raise RuntimeError("source HEAD/tree does not match reviewed case")
    patch_hash = None
    if source["patch_sha256"] is not None:
        if not args.source_patch or not args.source_patch.is_file():
            raise RuntimeError("case requires --source-patch with reviewed bytes")
        patch_hash = digest(args.source_patch)
        if patch_hash != source["patch_sha256"]:
            raise RuntimeError("source patch does not match reviewed case")
    diff = subprocess.check_output(["git", "-C", str(args.repo), "diff", "HEAD", "--binary"], timeout=3)
    actual_source = {"source_commit": head, "source_tree": tree, "app_sha256": expected,
                     "patch_sha256": patch_hash, "fontconfig_sha256": digest(args.fontconfig),
                     "worktree_diff_sha256": hashlib.sha256(diff).hexdigest(),
                     "worktree_diff_empty": not diff, "xkb_resources": xkb_resources}
    return actual_source, verified_golden(case, args)


def verified_golden(case, args):
    golden = None
    if case["oracle"]["kind"] == "reviewed_pixels":
        golden = args.golden or HERE / "fixtures" / case["oracle"]["fixture"]
        if not golden.is_file():
            raise RuntimeError("missing reviewed golden")
        from PIL import Image
        with Image.open(golden) as image:
            image = image.convert("RGBA")
            if image.size != (960, 480) or hashlib.sha256(image.tobytes()).hexdigest() != case["oracle"]["rgba_sha256"]:
                raise RuntimeError("refusing changed golden pixels")
    return golden


def verify_inputs(case, args):
    if case["version"] == 1:
        if getattr(args, "candidate", None):
            raise RuntimeError("historical v1 cases require their exact runtime pins, not a candidate override")
        return verify_v1_inputs(case, args)
    if not getattr(args, "candidate", None):
        raise RuntimeError("semantic v2 cases require --candidate PREPARED_BUNDLE; do not repin committed cases")
    import candidate_bundle
    if not getattr(args, "_candidate_applied", False):
        for name in ("prefix", "repo", "app", "app_sha256", "fontconfig", "source_patch"):
            if getattr(args, name, None) is not None:
                raise RuntimeError("--candidate cannot override recorded --" + name.replace("_", "-"))
    manifest, resolved = candidate_bundle.verify_candidate(args.candidate)
    candidate_sha = digest(args.candidate / "manifest.json")
    prior = getattr(args, "_candidate_manifest_sha256", None)
    if prior is not None and prior != candidate_sha:
        raise RuntimeError("candidate manifest changed within this run")
    args._candidate_manifest_sha256 = candidate_sha
    for name, value in resolved.items():
        setattr(args, name, value)
    args._candidate_applied = True
    source = manifest["source"]
    provenance = {"candidate_manifest_sha256": candidate_sha, "candidate_mode": manifest["mode"],
                  "source_claim": manifest["source_claim"], "source_commit": source["head"],
                  "source_tree": source["tree"], "worktree_diff_sha256": source["tracked_patch_sha256"],
                  "source_untracked_files": source["untracked_files"], "app_sha256": resolved["app_sha256"],
                  "fontconfig_sha256": digest(resolved["fontconfig"]), "runtime_manifest": manifest["runtime"],
                  "xkb_resources": verify_prefix_resources(resolved["prefix"])}
    return provenance, verified_golden(case, args)


class PrivateX:
    """Owned connection only; no callback/edit/shell injection API."""
    def __init__(self):
        self.xlib = C.CDLL("libX11.so.6")
        self.xtest = C.CDLL("libXtst.so.6")
        self.display = None
        self.decoy = None
        definitions = {
            "XOpenDisplay": ([C.c_char_p], C.c_void_p),
            "XCloseDisplay": ([C.c_void_p], C.c_int),
            "XDefaultRootWindow": ([C.c_void_p], C.c_ulong),
            "XQueryTree": ([C.c_void_p, C.c_ulong, C.POINTER(C.c_ulong), C.POINTER(C.c_ulong), C.POINTER(C.POINTER(C.c_ulong)), C.POINTER(C.c_uint)], C.c_int),
            "XCreateSimpleWindow": ([C.c_void_p, C.c_ulong, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_uint, C.c_ulong, C.c_ulong], C.c_ulong),
            "XMapWindow": ([C.c_void_p, C.c_ulong], C.c_int),
            "XDestroyWindow": ([C.c_void_p, C.c_ulong], C.c_int),
            "XGetInputFocus": ([C.c_void_p, C.POINTER(C.c_ulong), C.POINTER(C.c_int)], C.c_int),
            "XFree": ([C.c_void_p], C.c_int),
            "XStringToKeysym": ([C.c_char_p], C.c_ulong),
            "XKeysymToKeycode": ([C.c_void_p, C.c_ulong], C.c_ubyte),
            "XSetInputFocus": ([C.c_void_p, C.c_ulong, C.c_int, C.c_ulong], C.c_int),
            "XRaiseWindow": ([C.c_void_p, C.c_ulong], C.c_int),
            "XSync": ([C.c_void_p, C.c_int], C.c_int),
        }
        for name, (arguments, result) in definitions.items():
            function = getattr(self.xlib, name)
            function.argtypes, function.restype = arguments, result
        for name, arguments in {
            "XTestFakeKeyEvent": [C.c_void_p, C.c_uint, C.c_int, C.c_ulong],
            "XTestFakeButtonEvent": [C.c_void_p, C.c_uint, C.c_int, C.c_ulong],
            "XTestFakeMotionEvent": [C.c_void_p, C.c_int, C.c_int, C.c_int, C.c_ulong],
        }.items():
            function = getattr(self.xtest, name)
            function.argtypes, function.restype = arguments, C.c_int

    def connect(self, name, authority):
        previous = os.environ.get("XAUTHORITY")
        os.environ["XAUTHORITY"] = str(authority)
        try:
            self.display = self.xlib.XOpenDisplay(name.encode())
        finally:
            if previous is None:
                os.environ.pop("XAUTHORITY", None)
            else:
                os.environ["XAUTHORITY"] = previous
        return self.display

    def owns_window(self, window):
        root = self.xlib.XDefaultRootWindow(self.display)
        actual_root, parent, count = C.c_ulong(), C.c_ulong(), C.c_uint()
        children = C.POINTER(C.c_ulong)()
        if not self.xlib.XQueryTree(self.display, root, C.byref(actual_root), C.byref(parent), C.byref(children), C.byref(count)):
            return False
        try:
            return actual_root.value == root and window in [int(children[i]) for i in range(count.value)]
        finally:
            if children:
                self.xlib.XFree(children)

    def focus(self, window):
        if not self.owns_window(window):
            raise RuntimeError("Weston window is not owned by the private X root")
        self.xlib.XRaiseWindow(self.display, window)
        self.xlib.XSetInputFocus(self.display, window, 2, 0)
        self.xlib.XSync(self.display, False)
        actual, revert = C.c_ulong(), C.c_int()
        self.xlib.XGetInputFocus(self.display, C.byref(actual), C.byref(revert))
        if actual.value != window:
            raise RuntimeError("private focus target was not installed")

    def away_window(self):
        if self.decoy is None:
            root = self.xlib.XDefaultRootWindow(self.display)
            self.decoy = self.xlib.XCreateSimpleWindow(self.display, root, -10, -10, 1, 1, 0, 0, 0)
            if not self.decoy:
                raise RuntimeError("private decoy window creation failed")
            self.xlib.XMapWindow(self.display, self.decoy)
            self.xlib.XSync(self.display, False)
        if not self.owns_window(self.decoy):
            raise RuntimeError("private decoy is not owned by the private X root")
        return self.decoy

    def key(self, name, down):
        code = self.xlib.XKeysymToKeycode(self.display, self.xlib.XStringToKeysym(name.encode()))
        if not code or not self.xtest.XTestFakeKeyEvent(self.display, code, int(down), 0):
            raise RuntimeError("XTest key failed: " + name)
        self.xlib.XSync(self.display, False)

    def motion(self, x, y):
        if not self.xtest.XTestFakeMotionEvent(self.display, 0, x, y, 0):
            raise RuntimeError("XTest motion failed")
        self.xlib.XSync(self.display, False)

    def button(self, button, down):
        if not self.xtest.XTestFakeButtonEvent(self.display, button, int(down), 0):
            raise RuntimeError("XTest button failed")
        self.xlib.XSync(self.display, False)

    def close(self):
        if self.display:
            if self.decoy is not None:
                self.xlib.XDestroyWindow(self.display, self.decoy)
                self.xlib.XSync(self.display, False)
                self.decoy = None
            self.xlib.XCloseDisplay(self.display)
            self.display = None


def run_case(case, args, output):
    """A fresh app/compositor/display and process cleanup for every case."""
    if not input_cases.runnable(case):
        raise RuntimeError("case is pending/unsupported or has no reviewed oracle")
    source, golden = verify_inputs(case, args)
    output.mkdir(mode=0o700, exist_ok=False)
    write_json(output / "case.json", case)
    # Artifact directories can be arbitrarily long; AF_UNIX socket paths cannot.
    temporary_runtime = tempfile.TemporaryDirectory(prefix="gpe-", dir="/tmp")
    runtime, framebuffer = Path(temporary_runtime.name), output / "framebuffer"
    runtime.chmod(0o700)
    if len(os.fsencode(str(runtime / "gpui-e2e"))) >= 108:
        temporary_runtime.cleanup()
        raise RuntimeError("private Wayland socket exceeds AF_UNIX pathname bound")
    framebuffer.mkdir(mode=0o700)
    started = time.monotonic()
    deadline = started + case["timeout_ms"] / 1000
    report = {"case_id": case["id"], "format_version": case["version"],
              "disposition": case["disposition"], "status": "error",
              "input_route": "XTest -> private Xvfb -> Weston X11 wl_keyboard -> GPUI",
              "expected_initial": case["initial"], "expected_checkpoints": [{"id": step["id"], "state": step["expect"]} for step in case["steps"]],
              "provenance": source, "driver_sha256": digest(Path(__file__)),
              "case_sha256": hashlib.sha256(json.dumps(case, sort_keys=True, ensure_ascii=False).encode()).hexdigest(),
              "runtime_isolation": "fresh owned short /tmp/gpe-* directory; removed after child cleanup",
              "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "checkpoints": []}
    processes, files, pressed = [], [], []
    x = None
    focus_target = "app"
    events_file = (output / "events.jsonl").open("w")
    env = os.environ.copy()
    inherited_display = env.pop("DISPLAY", "")
    for name in ("WAYLAND_DISPLAY", "WAYLAND_SOCKET", "DBUS_SESSION_BUS_ADDRESS", "GPUI_FIELD_SMOKE", "GPUI_FIELD_FIXTURES", "GPUI_FIELD_E2E_STATE"):
        env.pop(name, None)
    lib = args.prefix / "usr/lib/x86_64-linux-gnu"
    env.update(LD_LIBRARY_PATH=f"{lib}:{lib / 'weston'}" + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else ""),
               PATH=str(args.prefix / "usr/bin") + ":" + env.get("PATH", ""),
               XDG_RUNTIME_DIR=str(runtime), XAUTHORITY=str(runtime / "Xauthority"),
               XDG_CACHE_HOME=str(output / "cache"), FONTCONFIG_FILE=str(args.fontconfig),
               GPUI_LINUX_TEXT_FONTCONFIG_FILE=str(args.fontconfig), FONTCONFIG_PATH=str(args.fontconfig.parent),
               XKB_CONFIG_ROOT=str(args.prefix / "usr/share/X11/xkb"), LIBGL_ALWAYS_SOFTWARE="1",
               WESTON_MODULE_MAP=";".join(name + "=" + str(lib / "libweston-14" / name) for name in ("x11-backend.so", "gl-renderer.so")))

    def remaining(maximum=10):
        value = min(maximum, deadline - time.monotonic())
        if value <= 0:
            raise RuntimeError("case timeout exceeded")
        return value

    def wait_for(predicate, label, maximum=10):
        until = time.monotonic() + remaining(maximum)
        while time.monotonic() < until:
            value = predicate()
            if value:
                return value
            time.sleep(0.01)
        raise RuntimeError("timed out: " + label)

    def pause(milliseconds):
        duration = milliseconds / 1000
        if remaining() < duration:
            raise RuntimeError("case timeout exceeded during event")
        time.sleep(duration)

    def launch(command, log, environment=env):
        stream = log.open("wb")
        files.append(stream)
        process = subprocess.Popen(command, env=environment, stdout=stream, stderr=subprocess.STDOUT)
        processes.append(process)
        return process

    def capture(name):
        from PIL import Image
        png = output / (name + ".png")
        xwd = output / (name + ".xwd")
        shutil.copyfile(framebuffer / "Xvfb_screen0", xwd)
        subprocess.run(["convert", str(xwd), str(png)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=remaining(3))
        with Image.open(png) as image:
            image = image.convert("RGBA")
            field_colors = len(set(image.crop((24, 28, 536, 72)).getdata()))
            if image.size != (960, 480) or field_colors < 2:
                raise RuntimeError("private frame pixels have invalid dimensions or blank field")
            return {"png_sha256": digest(png), "rgba_sha256": hashlib.sha256(image.tobytes()).hexdigest(), "dimensions": list(image.size), "field_color_count": field_colors, "pixel_sanity": True}

    def record_event(action, step_id, kind):
        events_file.write(json.dumps({"step": step_id, "elapsed_ms": (time.monotonic() - started) * 1000,
                                     "kind": kind, "event": action}) + "\n")
        events_file.flush()

    def emit(event, step_id):
        nonlocal focus_target
        record_event(event, step_id, "semantic-intent")
        if case["version"] == 2 and event["type"] == "click":
            frame = wait_for(lambda: completed_frame(read_log(output / "app.log")), "completed app frame before click", 2)
            x.motion(event["x"], event["y"])
            record_event({"type": "motion", "x": event["x"], "y": event["y"]}, step_id, "successful-XTest")
            wait_for(lambda: pointer_ready(read_log(output / "app.log"), frame["surface_id"], event["x"], event["y"]),
                     "actual app pointer entry/motion before click", 2)
            offset = len(read_log(output / "app.log"))
            for down in (True, False):
                x.button(1, down)
                record_event({"type": "button", "button": 1, "down": down}, step_id, "successful-XTest")
                expected = [("272", "1")] if down else [("272", "1"), ("272", "0")]
                wait_for(lambda: POINTER_BUTTON.findall(read_log(output / "app.log")[offset:]) == expected,
                         "actual primary button " + ("press" if down else "press/release") + " delivery", 2)
            return
        for action in physical_actions(event):
            if action["type"] == "focus":
                marker = KEYBOARD_ENTER if action["target"] == "app" else KEYBOARD_LEAVE
                before = len(marker.findall(read_log(output / "app.log")))
                target_window = window if action["target"] == "app" else x.away_window()
                x.focus(target_window)
                wait_for(lambda: len(marker.findall(read_log(output / "app.log"))) > before,
                         "actual client keyboard " + action["target"] + " focus transition", 2)
                focus_target = action["target"]
                report.setdefault("private_focus_targets", []).append({"target": focus_target, "window": int(target_window), "verified_private_root": True})
            elif action["type"] == "key":
                x.key(action["keysym"], action["down"])
                if action["down"]:
                    pressed.append(action["keysym"])
                else:
                    pressed.remove(action["keysym"])
            elif action["type"] == "motion":
                x.motion(action["x"], action["y"])
            elif action["type"] == "button":
                x.button(action["button"], action["down"])
            else:
                pause(action["duration_ms"])
            record_event(action, step_id, "successful-XTest" if action["type"] != "wait" else "elapsed-wait")

    def observed_state():
        states = presented_states(read_log(output / "app.log"))
        return states[-1] if states else None

    try:
        number = private_display_number(inherited_display)
        auth_file(runtime / "Xauthority", number, secrets.token_bytes(16))
        env["DISPLAY"] = ":" + str(number)
        report.update(private_display=env["DISPLAY"], inherited_display_excluded=inherited_display)
        xvfb = launch([str(args.prefix / "usr/bin/Xvfb"), env["DISPLAY"], "-screen", "0", "960x480x24", "-nolisten", "tcp", "-auth", env["XAUTHORITY"], "-fbdir", str(framebuffer)], output / "xvfb.log")
        x = PrivateX()
        if case["version"] == 2:
            report["xvfb_readiness"] = connect_owned_once(x, xvfb, env["DISPLAY"], runtime / "Xauthority", number,
                                                        framebuffer / "Xvfb_screen0", wait_for, pause)
            report["authenticated_connect_attempts"] = 1
        else:
            # Preserved strict historical v1 replay path; v2 never retries connect.
            wait_for(lambda: x.connect(env["DISPLAY"], runtime / "Xauthority") or (xvfb.poll() is not None and (_ for _ in ()).throw(RuntimeError("Xvfb exited"))), "authenticated private X display")
        weston = launch([str(args.prefix / "usr/bin/weston"), "--backend=x11", "--renderer=pixman", "--shell=" + str(lib / "weston/kiosk-shell.so"), "--socket=gpui-e2e", "--width=960", "--height=480", "--idle-time=0", "--no-config", "--log=" + str(output / "weston.log")], output / "weston-stdio.log")
        def find_window():
            if weston.poll() is not None:
                raise RuntimeError("Weston exited before private window")
            match = re.search(r"x11 output .*?window id (\d+)", read_log(output / "weston.log"))
            window = int(match.group(1)) if match else None
            return window if window is not None and x.owns_window(window) else None
        window = wait_for(find_window, "Weston output owned by private root")
        report["window_discovery"] = "actual Weston output ID verified against private X root child tree"
        app_env = env.copy()
        app_env.update(WAYLAND_DISPLAY="gpui-e2e", XDG_SESSION_TYPE="wayland", WAYLAND_DEBUG="client", XKB_LOG_LEVEL="debug")
        if case["oracle"]["kind"] == "presented_state":
            app_env["GPUI_FIELD_E2E_STATE"] = "1"
        app = launch([str(args.app)], output / "app.log", app_env)
        def first_frame():
            if app.poll() is not None:
                raise RuntimeError("GPUI exited before first frame")
            log = read_log(output / "app.log")
            if case["version"] == 2:
                return completed_frame(log)
            return ".frame(" in log and ".done(" in log[log.rfind(".frame("):]
        report["first_frame_evidence"] = wait_for(first_frame, "GPUI first completed frame")
        x.focus(window)
        emit(case["focus_click"], "initial-focus")
        wait_for(lambda: ".button(" in read_log(output / "app.log"), "compositor pointer focus", 2)
        if case["oracle"]["kind"] == "presented_state":
            wait_for(lambda: observed_state() and state_of(observed_state()) == case["initial"], "exact initial presented state", 2)
            report["observed_initial"] = observed_state()
            report["observed_initial_frame"] = wait_for(lambda: completed_frame(read_log(output / "app.log"), observer=True),
                                                        "matching completed initial compositor frame", 2)
        else:
            report["initial_state_evidence"] = "accepted source literal, controlled end-of-field click, retained focused pixels; no integrated state observer"
        report["focused_pixels"] = capture("focused")
        minimum_events = 0
        for step in case["steps"]:
            previous_state = observed_state() if case["oracle"]["kind"] == "presented_state" else None
            for event in step["events"]:
                if not x.owns_window(window):
                    raise RuntimeError("private target lost before injection")
                emit(event, step["id"])
                if event["type"] in {"key", "hold"} and focus_target == "app":
                    minimum_events += 2 * (1 + len(event["modifiers"]))
            wait_for(lambda: len(KEY_EVENT.findall(read_log(output / "app.log"))) >= minimum_events or app.poll() is not None, "actual wl_keyboard delivery", 2)
            if app.poll() is not None:
                raise RuntimeError("GPUI exited during OS input")
            pause(200)
            checkpoint = {"id": step["id"], "expected": step["expect"]}
            if case["oracle"]["kind"] == "presented_state":
                accepted_states = [step["expect"]]
                if case["disposition"] == "expected-failure" and step is case["steps"][-1]:
                    accepted_states.append(case["expected_failure"]["observed"])
                def checkpoint_state():
                    record = observed_state()
                    if not record or state_of(record) not in accepted_states:
                        return None
                    meaningful = previous_state is None or state_of(record) != state_of(previous_state)
                    if meaningful and previous_state and record["presentation"] <= previous_state["presentation"]:
                        return None
                    return record
                checkpoint["observed"] = wait_for(checkpoint_state, "exact presented checkpoint " + step["id"], 2)
                checkpoint["observer_frame"] = wait_for(lambda: completed_frame(read_log(output / "app.log"), observer=True),
                                                         "matching completed checkpoint compositor frame " + step["id"], 2)
                if checkpoint["observer_frame"]["accepted_record"] != checkpoint["observed"]:
                    raise RuntimeError("checkpoint state changed before its completed frame")
                checkpoint["state_match"] = state_of(checkpoint["observed"]) == step["expect"]
                checkpoint["fresh_presentation"] = previous_state is None or checkpoint["observed"]["presentation"] > previous_state["presentation"]
                if previous_state and step["expect"] == state_of(previous_state):
                    checkpoint["no_op_record_unchanged"] = checkpoint["observed"] == previous_state
                    if not checkpoint["no_op_record_unchanged"]:
                        raise RuntimeError("no-op checkpoint changed the accepted revision/presentation record")
            checkpoint["pixels"] = capture("step-" + step["id"])
            report["checkpoints"].append(checkpoint)
        report["final_pixels"] = capture("final")
        log = read_log(output / "app.log")
        report.update(app_alive=app.poll() is None, app_returncode=app.poll(), native_failure="next_event: native_failure" in log, wayland_key_events=len(KEY_EVENT.findall(log)), minimum_wayland_key_events=key_event_count(case, client_only=True), planned_os_key_events=key_event_count(case))
        has_hold = any(event["type"] == "hold" for step in case["steps"] for event in step["events"])
        report["native_event_count_match"] = report["wayland_key_events"] >= report["minimum_wayland_key_events"] if has_hold else report["wayland_key_events"] == report["minimum_wayland_key_events"]
        if golden:
            from PIL import Image
            with Image.open(output / "final.png") as actual, Image.open(golden) as expected:
                actual, expected = actual.convert("RGBA"), expected.convert("RGBA")
                report["golden_pixel_match"] = actual.size == expected.size and actual.tobytes() == expected.tobytes()
                actual.crop((25, 29, 490, 70)).resize((1860, 164)).save(output / "final-field.png")
            ocr = subprocess.run(["tesseract", str(output / "final-field.png"), "stdout", "--psm", "7", "-l", "eng"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=remaining(3))
            text = ocr.stdout.strip()
            report.update(ocr_text=text, ocr_status=ocr.returncode, ocr_ascii_coverage="ASCII prefix/suffix only; Japanese and caret covered by reviewed exact pixels")
            report["ocr_match"] = ocr.returncode == 0 and text.startswith(case["oracle"]["ocr_prefix"]) and text.endswith(case["oracle"]["ocr_suffix"])
            oracle_pass = report["golden_pixel_match"] and report["ocr_match"]
        else:
            oracle_pass = all(item["state_match"] and item["pixels"]["pixel_sanity"] for item in report["checkpoints"])
            report["pixel_oracle_coverage"] = "nonblank private-frame sanity and retained pixels paired with exact successfully presented state; no auto-generated golden"
        report["owner_rejection"] = any(marker in log for marker in ("Field scene failed;", "Field input/layout/grayscale admission rejected;", "Field bounds rejected;"))
        healthy = not report["owner_rejection"] and report["app_alive"] and not report["native_failure"] and report["native_event_count_match"]
        if case["disposition"] == "expected-failure":
            last = report["checkpoints"][-1]
            known_failure = state_of(last["observed"]) == case["expected_failure"]["observed"]
            report["status"] = "expected-failure" if healthy and known_failure and not last["state_match"] else "unexpected-pass" if healthy and oracle_pass else "failed"
        else:
            report["status"] = "passed" if healthy and oracle_pass else "failed"
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
    finally:
        if x:
            for name in reversed(pressed):
                try:
                    x.key(name, False)
                except Exception:
                    pass
            x.close()
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2)
        for stream in files:
            stream.close()
        events_file.close()
        (runtime / "Xauthority").unlink(missing_ok=True)
        temporary_runtime.cleanup()
        report["including_cleanup_ms"] = (time.monotonic() - started) * 1000
        report["artifacts"] = sorted({"result.json"} | {path.name for path in output.iterdir() if path.is_file()})
        write_json(output / "result.json", report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    select = parser.add_mutually_exclusive_group()
    select.add_argument("--case", help="catalog name or JSON path")
    select.add_argument("--all", action="store_true", help="run ready cases and record explicit skipped coverage")
    parser.add_argument("--cases-dir", type=Path, default=input_cases.CASES)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--validate", action="store_true", help="validation only; no process/display access")
    for name in ("prefix", "repo", "app", "fontconfig", "output", "golden", "source-patch"):
        parser.add_argument("--" + name, type=Path)
    parser.add_argument("--app-sha256", help="historical v1 replay only")
    parser.add_argument("--candidate", type=Path, help="verified outside-repo bundle for reusable v2 semantic cases")
    args = parser.parse_args(argv)
    try:
        cases = [input_cases.select_case(args.case, args.cases_dir)] if args.case else input_cases.catalog(args.cases_dir)
        if args.list or args.validate:
            for case in cases:
                print(f"{case['id']}\t{case['disposition']}\t{'ready' if input_cases.runnable(case) else 'blocked'}")
            return 0
        if not args.case and not args.all:
            raise RuntimeError("select --case NAME or --all")
        selected = [case for case in cases if input_cases.runnable(case)]
        if not selected and args.case:
            print(json.dumps({"case_id": cases[0]["id"], "status": "skipped-" + cases[0]["disposition"], "reason": cases[0]["reason"], "oracle": cases[0]["oracle"]}, ensure_ascii=False))
            return 3
        if not selected and not args.output:
            print(json.dumps({"status": "skipped-no-runnable-cases", "executed": 0, "skipped": len(cases), "results": [{"case_id": case["id"], "status": "skipped-" + case["disposition"], "reason": case["reason"]} for case in cases]}, ensure_ascii=False))
            return 3
        if not args.output:
            raise RuntimeError("--output FRESH_DIR is required")
        for case in selected:
            verify_inputs(case, args)
        args.output.mkdir(parents=True, mode=0o700, exist_ok=False)
        results = []
        for case in cases:
            if input_cases.runnable(case):
                result = run_case(case, args, args.output / case["id"])
            else:
                result = {"case_id": case["id"], "disposition": case["disposition"], "status": "skipped-" + case["disposition"], "reason": case["reason"], "oracle": case["oracle"]}
            results.append(result)
            print(json.dumps(result, ensure_ascii=False), flush=True)
        summary = {"status": "completed" if selected else "skipped-no-runnable-cases", "version": 1, "results": results, "executed": len(selected), "skipped": len(cases) - len(selected), "all_cases_executed": bool(selected) and len(selected) == len(cases)}
        write_json(args.output / "summary.json", summary)
        if not selected:
            print(json.dumps({"status": "skipped-no-runnable-cases", "executed": 0, "skipped": len(cases)}, ensure_ascii=False), flush=True)
            return 3
        return 0 if all(result["status"] in {"passed", "expected-failure"} for result in results if result["case_id"] in {case["id"] for case in selected}) else 1
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    sys.exit(main())
