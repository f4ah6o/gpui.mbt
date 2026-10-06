#!/usr/bin/env python3
"""Recreate the bounded Debian 13 desktop profile without root or postinsts."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
import xml.etree.ElementTree as ET

import build_manifest

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LOCK = HERE / "profile.lock.json"
TRIPLET = "x86_64-linux-gnu"


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def profile():
    return json.loads(LOCK.read_text())


def locked_install_ready(root):
    try:
        return json.loads((root / "installed.json").read_text()).get("lock_sha256") == digest(LOCK)
    except (OSError, ValueError, AttributeError):
        return False


def run(command, **kwargs):
    print("+ " + shlex.join(map(str, command)), file=sys.stderr)
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def diagnostic_probe(command, env):
    try:
        return subprocess.run(list(map(str, command)), env=env, capture_output=True, text=True)
    except OSError as error:
        return subprocess.CompletedProcess(command, 127, "", str(error))


def fetch(item, cache, offline=False):
    """Never execute or extract bytes before matching the reviewed SHA-256."""
    path = cache / item["archive"]
    if path.is_file() and digest(path) == item["sha256"]:
        return path
    if offline:
        raise RuntimeError("missing or corrupt offline archive: " + str(path))
    temporary = path.with_name(path.name + ".partial")
    try:
        run(["curl", "--fail", "--location", "--proto", "=https", "--tlsv1.2",
             "--retry", "3", "--connect-timeout", "20", "--max-time", "300",
             "--output", temporary, item["url"]])
        if digest(temporary) != item["sha256"]:
            raise RuntimeError("SHA-256 mismatch: " + item["archive"])
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)
    return path


def untar(archive, destination):
    # Python's data filter rejects traversal, special files and escaping links.
    with tarfile.open(archive, "r:gz") as source:
        source.extractall(destination, filter="data")


def native_environment(root):
    prefix = root / "prefix"
    lib = prefix / "usr/lib" / TRIPLET
    env = os.environ.copy()
    def prepend(key, value):
        env[key] = str(value) + (":" + env[key] if env.get(key) else "")
    env["GPUI_DESKTOP_ROOT"] = str(root)
    env["MOON_HOME"] = str(root / "moon")
    prepend("PATH", f"{root / 'moon/bin'}:{prefix / 'usr/bin'}")
    prepend("LD_LIBRARY_PATH", f"{lib}:{lib / 'weston'}")
    env["PKG_CONFIG_SYSROOT_DIR"] = str(prefix)
    env["PKG_CONFIG_LIBDIR"] = f"{lib / 'pkgconfig'}:{prefix / 'usr/share/pkgconfig'}"
    env.pop("PKG_CONFIG_PATH", None)
    env["WAYLAND_PROTOCOLS_DIR"] = str(prefix / "usr/share/wayland-protocols")
    env["CPPFLAGS"] = shlex.join(["-I" + str(prefix / "usr/include"),
                                 "-I" + str(prefix / "usr/include" / TRIPLET)]) + " " + env.get("CPPFLAGS", "")
    env["LDFLAGS"] = shlex.join(["-L" + str(lib)]) + " " + env.get("LDFLAGS", "")
    env["FONTCONFIG_FILE"] = str(root / "config/fonts.conf")
    env["GPUI_LINUX_TEXT_FONTCONFIG_FILE"] = env["FONTCONFIG_FILE"]
    env["FONTCONFIG_PATH"] = str(root / "config")
    return env


def graphical_environment(root):
    env = native_environment(root)
    prefix = root / "prefix"
    lib = prefix / "usr/lib" / TRIPLET
    if not env.get("XAUTHORITY"):
        implicit_authority = Path(env.get("HOME", str(Path.home()))) / ".Xauthority"
        if implicit_authority.is_file():
            env["XAUTHORITY"] = str(implicit_authority)
    # An inherited fd takes precedence over WAYLAND_DISPLAY for native clients.
    env.pop("WAYLAND_SOCKET", None)
    env["HOME"] = str(root / "home")
    env["XDG_CONFIG_HOME"] = str(root / "config")
    env["XDG_CACHE_HOME"] = str(root / "cache")
    env["XDG_DATA_HOME"] = str(root / "data")
    env["XDG_DATA_DIRS"] = f"{prefix / 'usr/share'}:/usr/local/share:/usr/share"
    env["GSETTINGS_SCHEMA_DIR"] = str(root / "config/schemas")
    env["GI_TYPELIB_PATH"] = str(lib / "girepository-1.0")
    env["PYTHONPATH"] = str(prefix / "usr/lib/python3/dist-packages")
    env["IBUS_COMPONENT_PATH"] = str(root / "config/ibus/component")
    env["GTK_IM_MODULE"] = "ibus"
    env["QT_IM_MODULE"] = "ibus"
    env["XMODIFIERS"] = "@im=ibus"
    env["GTK_IM_MODULE_FILE"] = str(root / "config/gtk-immodules.cache")
    env["XCURSOR_PATH"] = f"{prefix / 'usr/share/icons'}:/usr/share/icons"
    env["WESTON_DATA_DIR"] = str(prefix / "usr/share/weston")
    env["XKB_CONFIG_ROOT"] = str(prefix / "usr/share/X11/xkb")
    env["MOZC_IBUS_CANDIDATE_WINDOW"] = "ibus"
    env["LIBGL_ALWAYS_SOFTWARE"] = "1"
    env["WESTON_MODULE_MAP"] = ";".join(
        name + "=" + str(lib / directory / name)
        for name, directory in [("x11-backend.so", "libweston-14"),
                                ("headless-backend.so", "libweston-14"),
                                ("gl-renderer.so", "libweston-14")])
    return env


def configure(root):
    prefix = root / "prefix"
    config = root / "config"
    for name in ["home", "config", "cache", "data", "logs"]:
        (root / name).mkdir(parents=True, exist_ok=True)
    # Generated absolute prefix paths live outside the checkout.
    fonts = ET.Element("fontconfig")
    for directory in ["truetype/dejavu", "opentype/noto", "truetype/noto"]:
        ET.SubElement(fonts, "dir").text = str(prefix / "usr/share/fonts" / directory)
    ET.SubElement(fonts, "cachedir").text = str(root / "cache/fontconfig")
    ET.ElementTree(fonts).write(config / "fonts.conf", encoding="utf-8", xml_declaration=True)
    components = config / "ibus/component"
    components.mkdir(parents=True, exist_ok=True)
    for source in (prefix / "usr/share/ibus/component").glob("*.xml"):
        tree = ET.parse(source)
        for element in tree.iter():
            if element.tag == "exec" and element.text:
                element.text = element.text.replace("/usr/", str(prefix / "usr") + "/")
            if "exec" in element.attrib:
                element.set("exec", element.get("exec").replace("/usr/", str(prefix / "usr") + "/"))
        tree.write(components / source.name, encoding="utf-8", xml_declaration=True)
    schemas = config / "schemas"
    schemas.mkdir(exist_ok=True)
    for source in (prefix / "usr/share/glib-2.0/schemas").glob("*.xml"):
        shutil.copy2(source, schemas / source.name)
    compiler = next((path for path in [prefix / "usr/bin/glib-compile-schemas",
                    prefix / "usr/lib" / TRIPLET / "glib-2.0/glib-compile-schemas",
                    Path("/usr/lib") / TRIPLET / "glib-2.0/glib-compile-schemas",
                    Path(shutil.which("glib-compile-schemas") or "/nonexistent")]
                    if path.is_file()), Path("/nonexistent"))
    if compiler.exists():
        run([compiler, schemas], env=native_environment(root))
    query = prefix / "usr/lib" / TRIPLET / "libgtk-3-0t64/gtk-query-immodules-3.0"
    module = prefix / "usr/lib" / TRIPLET / "gtk-3.0/3.0.0/immodules/im-ibus.so"
    if query.exists() and module.exists():
        result = run([query, module], env=native_environment(root), capture_output=True, text=True)
        (config / "gtk-immodules.cache").write_text(result.stdout)
    # Header packages may have unversioned links whose runtime target is on
    # the matching Debian host. Preserve that dependency explicitly.
    lib = prefix / "usr/lib" / TRIPLET
    for link in lib.glob("*.so"):
        if link.is_symlink() and not link.exists():
            target = Path(os.readlink(link)).name
            host = Path("/usr/lib") / TRIPLET / target
            if host.is_file():
                link.unlink()
                link.symlink_to(host)


def bootstrap(args, root):
    if platform.system() != "Linux" or platform.machine() not in ["x86_64", "amd64"]:
        raise RuntimeError("this lock is for Debian 13 Linux amd64 only")
    owner = root / ".gpui-desktop-profile"
    if not args.verify_only and any((root / name).exists() for name in ["prefix", "moon"]):
        if not owner.is_file() or owner.read_text() != "gpui-linux-desktop-v1\n":
            raise RuntimeError("refusing to replace an unowned prefix/moon directory; choose a new private root")
    cache = Path(args.cache).expanduser().resolve() if args.cache else root / "archives"
    cache.mkdir(parents=True, exist_ok=True)
    data = profile()
    items = data["packages"] + data["toolchain"]["archives"]
    with ThreadPoolExecutor(max_workers=4) as pool:
        paths = list(pool.map(lambda item: fetch(item, cache, args.offline), items))
    archives = dict(zip([item["archive"] for item in items], paths))
    if args.verify_only:
        print("All locked archive checksums match.")
        return
    root.mkdir(parents=True, exist_ok=True)
    marker = root / "installed.json"
    lock_hash = digest(LOCK)
    if not args.force and locked_install_ready(root):
        configure(root)
        print("The locked prefix is already installed; generated configuration refreshed.")
        return
    # A clean, private staging directory prevents partial installs looking ready.
    with tempfile.TemporaryDirectory(prefix="bootstrap-", dir=root) as temporary:
        staging = Path(temporary)
        prefix = staging / "prefix"
        prefix.mkdir()
        for item in data["packages"]:
            run(["dpkg-deb", "--extract", archives[item["archive"]], prefix])
        moon = staging / "moon"
        moon.mkdir()
        untar(archives[data["toolchain"]["archives"][0]["archive"]], moon)
        # Official MoonBit installer makes the archive's 0664 CLI files
        # executable; mirror that required installation step on our own files.
        for executable in (moon / "bin").iterdir():
            if executable.is_file():
                executable.chmod(executable.stat().st_mode | 0o111)
        tcc = moon / "bin/internal/tcc"
        if tcc.is_file():
            tcc.chmod(tcc.stat().st_mode | 0o111)
        (moon / "lib").mkdir(exist_ok=True)
        untar(archives[data["toolchain"]["archives"][1]["archive"]], moon / "lib")
        owner.write_text("gpui-linux-desktop-v1\n")
        # A failed forced repair must not retain a previous readiness claim.
        # The marker is recreated only after bundle and configuration succeed.
        marker.unlink(missing_ok=True)
        (root / "field-binary.txt").unlink(missing_ok=True)
        for name in ["prefix", "moon"]:
            destination = root / name
            if destination.exists():
                shutil.rmtree(destination)
            (staging / name).replace(destination)
    env = native_environment(root)
    run([root / "moon/bin/moon", "-C", root / "moon/lib/core", "bundle", "--warn-list", "-a", "--all"], env=env)
    configure(root)
    marker.write_text(json.dumps({"lock_sha256": lock_hash, "profile": data,
                                  "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, indent=2) + "\n")
    print("Installed exact locked archives. Run doctor before build or launch.")


def ipc_probe():
    # Stop on EPERM; neither changing permissions nor indirect launch is a fix.
    with tempfile.TemporaryDirectory(prefix="gpui-ipc-") as temporary:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(Path(temporary) / "probe.sock"))
            server.listen(1)


def mozc_system_ready(root):
    system = Path("/usr/lib/mozc/mozc_server")
    locked = root / "prefix/usr/lib/mozc/mozc_server"
    return system.is_file() and locked.is_file() and digest(system) == digest(locked)


def doctor(args, root):
    checks = []
    def check(name, success, detail):
        checks.append({"check": name, "ok": bool(success), "detail": str(detail)})
    os_release = Path("/etc/os-release").read_text() if Path("/etc/os-release").exists() else ""
    check("host-profile", 'VERSION_ID="13"' in os_release and platform.machine() == "x86_64",
          "Debian 13 amd64, host C compiler/libc/Python/Mesa are external prerequisites")
    env = graphical_environment(root)
    for command in ["curl", "dpkg-deb", "cc", "pkg-config", "dbus-run-session", "ldd"]:
        found = shutil.which(command, path=env["PATH"])
        check("command:" + command, found, found or "missing")
    marker = root / "installed.json"
    check("locked-install", locked_install_ready(root),
          "bootstrap must finish for this exact lock")
    for path in ["usr/bin/weston", "usr/bin/ibus-daemon", "usr/bin/mousepad",
                 "usr/lib/ibus-mozc/ibus-engine-mozc", "usr/lib/mozc/mozc_server",
                 "usr/lib/x86_64-linux-gnu/libweston-14/x11-backend.so",
                 "usr/lib/x86_64-linux-gnu/weston/kiosk-shell.so"]:
        file = root / "prefix" / path
        if file.exists():
            result = diagnostic_probe(["ldd", file], env)
            missing = [line.strip() for line in result.stdout.splitlines() if "not found" in line]
            check("link:" + path, result.returncode == 0 and not missing, "; ".join(missing) or "resolved")
        else:
            check("link:" + path, False, "missing")
    for command, expected in [(root / "moon/bin/moonc", profile()["toolchain"]["version"]),
                              (root / "prefix/usr/bin/weston", "14.0.2")]:
        try:
            result = diagnostic_probe([command, "-v" if command.name == "moonc" else "--version"], env)
            version = (result.stdout + result.stderr).strip()
            check("version:" + command.name, result.returncode == 0 and expected in version, version)
        except OSError as error:
            check("version:" + command.name, False, error)
    for name in ["wayland-client", "wayland-egl", "egl", "glesv2", "xkbcommon", "pangoft2", "fontconfig"]:
        result = diagnostic_probe(["pkg-config", "--modversion", name], env)
        check("pkg-config:" + name, result.returncode == 0, (result.stdout + result.stderr).strip())
    result = diagnostic_probe(["pkg-config", "--cflags", "--libs", "pangoft2", "fontconfig"], env)
    check("native-link-flags", result.returncode == 0, (result.stdout + result.stderr).strip())
    try:
        result = diagnostic_probe(["/usr/bin/python3", "-c", "import gi; gi.require_version('Gtk', '3.0'); gi.require_version('IBus', '1.0'); from gi.repository import Gtk, IBus"], env)
        check("python3-gi-abi", result.returncode == 0, result.stderr.strip() or "GTK3/IBus typelibs import")
    except OSError as error:
        check("python3-gi-abi", False, error)
    if args.build_only:
        checks.append({"check": "display-present", "ok": None, "detail": "not required by build-only diagnostics"})
    else:
        check("display-present", bool(env.get("DISPLAY")), "DISPLAY=" + env.get("DISPLAY", "<unset>"))
    for path in ["config/schemas/gschemas.compiled", "config/gtk-immodules.cache"]:
        check("generated:" + path, (root / path).is_file(), "required by IBus/GTK baseline")
    if args.input_e2e:
        xkb = root / "prefix/usr/share/X11/xkb"
        for resource in ["rules/evdev", "keycodes/evdev", "symbols/pc", "symbols/us", "types/complete", "compat/complete"]:
            check("input-e2e:xkb:" + resource, (xkb / resource).is_file(), "locked prefix XKB data required before any OS input")
        xvfb = root / "prefix/usr/bin/Xvfb"
        if xvfb.exists():
            result = diagnostic_probe(["ldd", xvfb], env)
            missing = [line.strip() for line in result.stdout.splitlines() if "not found" in line]
            check("input-e2e:xvfb-link", result.returncode == 0 and not missing, "; ".join(missing) or "resolved")
        else:
            check("input-e2e:xvfb-link", False, "missing locked Xvfb")
        for command in ["convert", "tesseract"]:
            found = shutil.which(command, path=env["PATH"])
            check("input-e2e:" + command, found, found or "host screenshot/text oracle prerequisite missing")
        result = diagnostic_probe([sys.executable, "-c", "from PIL import Image; import ctypes; ctypes.CDLL('libX11.so.6'); ctypes.CDLL('libXtst.so.6')"], env)
        check("input-e2e:python-oracles", result.returncode == 0, result.stderr.strip() or "Pillow/X11/XTest load")
    if args.ipc:
        try:
            ipc_probe()
            check("unix-ipc", True, "socket creation and bind allowed in this executor")
        except OSError as error:
            check("unix-ipc", False, f"{error}; compositor/D-Bus cannot launch here. Stop, use a supported desktop execution context.")
    else:
        checks.append({"check": "unix-ipc", "ok": None, "detail": "not probed; use doctor --ipc in intended execution context"})
    mozc_path = Path("/usr/lib/mozc/mozc_server")
    mozc_ready = mozc_system_ready(root)
    checks.append({"check": "mozc-system-path", "ok": True if mozc_ready else None,
                   "detail": "Debian Mozc requires the exact locked server at /usr/lib/mozc/mozc_server. Prefix-only conversion is blocked." if not mozc_ready else "canonical server matches the locked package bytes"})
    print(json.dumps({"checks": checks, "native_key_smoke": "not run", "japanese_preedit_conversion": "not run",
                      "gpui_ime": "unimplemented; baseline GTK/Mozc smoke is separate"}, indent=2))
    return 0 if all(item["ok"] is not False for item in checks) else 1


def build(args, root):
    env = native_environment(root)
    repo = Path(args.repo).expanduser().resolve()
    if root == repo or repo in root.parents:
        raise RuntimeError("keep build/profile output outside the candidate source checkout")
    explicit_record = getattr(args, "manifest_output", None)
    build_record = Path(explicit_record).expanduser().resolve() if explicit_record else root / "field-build.json"
    if build_record == repo or repo in build_record.parents:
        raise RuntimeError("keep the build manifest outside the candidate source checkout")
    if explicit_record and build_record.exists():
        raise RuntimeError("explicit build manifest output must be a new file")
    build_record.parent.mkdir(parents=True, exist_ok=True)
    if not explicit_record:
        build_record.unlink(missing_ok=True)
        (root / "field-binary.txt").unlink(missing_ok=True)
    source_before = build_manifest.capture_source(repo)
    run(["sh", repo / "scripts/prepare_ubuntu.sh"], cwd=repo, env=env)
    target = Path(args.output_dir).expanduser().resolve() if args.output_dir else root / "build"
    if target == repo or repo in target.parents:
        raise RuntimeError("keep candidate build output outside its source checkout")
    command = [root / "moon/bin/moon", "build", "examples/linux_text_field", "--target", "native",
               "--target-dir", target]
    # Generated protocols are build inputs, so capture them after preparation
    # together with the compiler, core, prefix and configured font identities.
    runtime_before = build_manifest.capture_runtime(root, Path(env["FONTCONFIG_FILE"]), env, repo)
    run(command, cwd=repo, env=env)
    binaries = list(target.glob("native/debug/build/examples/linux_text_field/*.exe"))
    if len(binaries) != 1:
        raise RuntimeError("expected exactly one field executable; inspect build output")
    source_after = build_manifest.capture_source(repo)
    if source_before != source_after:
        raise RuntimeError("source changed during build; no executable readiness claim written")
    runtime = build_manifest.capture_runtime(root, Path(env["FONTCONFIG_FILE"]), env, repo)
    build_manifest.require_matching_runtime(runtime_before, runtime)
    build_manifest.write_build_manifest(build_record, source_before, source_after,
                                        binaries[0], runtime, command)
    if not explicit_record:
        (root / "field-binary.txt").write_text(str(binaries[0].resolve()) + "\n")
    print("Built: " + str(binaries[0]))
    print("Build manifest: " + str(build_record))


def wait_for(predicate, process, description, seconds=10):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        if process.poll() is not None:
            raise RuntimeError(description + " exited; inspect logs")
        time.sleep(0.1)
    raise RuntimeError("timeout waiting for " + description + "; inspect logs")


def launch(args, root):
    ipc_probe()
    if args.command == "ime-baseline" and not mozc_system_ready(root):
        raise RuntimeError("Debian Mozc validates the compiled /usr/lib/mozc/mozc_server path; the prefix-only baseline is blocked. See install-system-mozc.sh. No unverified workaround is attempted.")
    env = graphical_environment(root)
    if not env.get("DISPLAY"):
        raise RuntimeError("DISPLAY must identify the real X11 desktop; no display is guessed")
    if not args.session:
        # Private D-Bus avoids replacing any user's existing desktop IME.
        command = ["dbus-run-session", "--", sys.executable, __file__, "--root", root,
                   args.command, "--session"]
        return run(command, env=env).returncode
    prefix = root / "prefix"
    lib = prefix / "usr/lib" / TRIPLET
    processes = []
    logs = []
    with tempfile.TemporaryDirectory(prefix="gpd-", dir="/tmp") as temporary:
        runtime = Path(temporary)
        runtime.chmod(0o700)
        env["XDG_RUNTIME_DIR"] = str(runtime)
        if len(os.fsencode(runtime / "gpui-wayland")) >= 108:
            raise RuntimeError("Wayland socket pathname exceeds the AF_UNIX limit")
        env["IBUS_ADDRESS_FILE"] = str(runtime / "ibus-address")
        env.pop("IBUS_ADDRESS", None)
        def start(command, name, launch_env=env):
            log = (root / "logs" / (name + ".log")).open("w")
            logs.append(log)
            process = subprocess.Popen(list(map(str, command)), env=launch_env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(process)
            return process
        try:
            if args.command == "launch":
                weston_env = env.copy()
                weston_env.pop("WAYLAND_DISPLAY", None)
                weston_env.pop("WAYLAND_SOCKET", None)
                weston = start([prefix / "usr/bin/weston", "--backend=x11", "--renderer=pixman",
                                "--shell=" + str(lib / "weston/kiosk-shell.so"), "--no-config",
                                "--idle-time=0", "--socket=gpui-wayland", "--width=960", "--height=540"], "weston", weston_env)
                wait_for(lambda: (runtime / "gpui-wayland").is_socket(), weston, "Weston socket")
                env["WAYLAND_DISPLAY"] = "gpui-wayland"
                env["XDG_SESSION_TYPE"] = "wayland"
                env.pop("WAYLAND_SOCKET", None)
                file = root / "field-binary.txt"
                if not file.exists():
                    raise RuntimeError("run build first")
                app = start([Path(file.read_text().strip())], "field")
                return app.wait()
            # Environment-only Japanese baseline, deliberately on outer X11.
            env.pop("WAYLAND_DISPLAY", None)
            env["GDK_BACKEND"] = "x11"
            env["XDG_SESSION_TYPE"] = "x11"
            start(["/usr/lib/mozc/mozc_server"], "mozc-server")
            daemon = start([prefix / "usr/bin/ibus-daemon", "--cache=none",
                            "--panel=" + str(prefix / "usr/libexec/ibus-ui-gtk3"),
                            "--config=" + str(prefix / "usr/libexec/ibus-dconf"),
                            "--emoji-extension=disable"], "ibus")
            ibus = prefix / "usr/bin/ibus"
            wait_for(lambda: subprocess.run([str(ibus), "address"], env=env, capture_output=True).returncode == 0,
                     daemon, "IBus address")
            run([ibus, "engine", "mozc-jp"], env=env)
            return start([prefix / "usr/bin/mousepad", "--disable-server"], "mousepad").wait()
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=3)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
            for log in logs:
                log.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    default = Path(os.environ.get("GPUI_DESKTOP_ROOT", Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "gpui-linux-desktop"))
    parser.add_argument("--root", default=str(default), help="private installation/state root")
    commands = parser.add_subparsers(dest="command", required=True)
    bootstrap_parser = commands.add_parser("bootstrap")
    bootstrap_parser.add_argument("--cache", help="verified archives cache; can be kept across resets")
    bootstrap_parser.add_argument("--offline", action="store_true")
    bootstrap_parser.add_argument("--verify-only", action="store_true")
    bootstrap_parser.add_argument("--force", action="store_true", help="re-extract exact lock to repair installation drift")
    doctor_parser = commands.add_parser("doctor")
    doctor_parser.add_argument("--ipc", action="store_true", help="check Unix IPC in this execution context")
    doctor_parser.add_argument("--build-only", action="store_true", help="do not require DISPLAY for build diagnostics")
    doctor_parser.add_argument("--input-e2e", action="store_true", help="check private-Xvfb/XTest and host screenshot/text-oracle prerequisites")
    commands.add_parser("env")
    build_parser = commands.add_parser("build")
    build_parser.add_argument("--repo", type=Path, default=REPO,
                              help="current candidate checkout; defaults to this project")
    build_parser.add_argument("--output-dir", type=Path,
                              help="separate external build directory; defaults to profile/build")
    build_parser.add_argument("--manifest-output", type=Path,
                              help="new external manifest file; preserve the profile's previous build record")
    for name in ["launch", "ime-baseline"]:
        commands.add_parser(name).add_argument("--session", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    root = Path(args.root).expanduser().resolve()
    if root == Path("/") or root == Path.home() or root == REPO or REPO in root.parents:
        raise RuntimeError("keep installation/state outside the repository and separate from HOME")
    if args.command == "env":
        env = native_environment(root)
        for key in sorted(env):
            if env.get(key) != os.environ.get(key):
                print("export " + key + "=" + shlex.quote(env[key]))
        print("unset PKG_CONFIG_PATH")
        return 0
    functions = {"bootstrap": bootstrap, "doctor": doctor, "build": build,
                 "launch": launch, "ime-baseline": launch}
    return functions[args.command](args, root) or 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print("gpui-desktop: " + str(error), file=sys.stderr)
        sys.exit(1)
