#!/usr/bin/env python3
"""Prepare and inspect a user-owned, externally located macOS quality profile."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import urllib.request
import uuid
import zipfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
LOCK_PATH = HERE / "profile.lock.json"
ACTRUN_LOCK = HERE / "actrun-package-lock.json"
TURTLES_SCHEMA2_LOCK = HERE / "turtles-schema2.lock.json"
TURTLES_SCHEMA3_LOCK = HERE / "turtles-verification.macos.lock.json"
HOTPATH_LOCK = HERE / "hotpath.lock.json"
PROOF_LOCK_TEMPLATE = HERE / "proof-toolchain.macos.lock.template.json"
PRELUDE_MI = "lib/core/_build/wasm/release/bundle/prelude/prelude.mi"
PRELUDE_MI_SHA256 = "e72d19774700d3e12dfb53731430453e08de9b8f8fefa35bb4f6999f0fcd2217"
OWNED_ENTRIES = {"downloads", "moon", "tools", "build", "bootstrap-logs",
                 "bootstrap-in-progress.json", "installed.json"}


class ProfileError(RuntimeError):
    pass


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def lock():
    value = json.loads(LOCK_PATH.read_text())
    if type(value.get("schema_version")) is not int or value["schema_version"] != 1:
        raise ProfileError("unsupported macOS profile lock")
    if value["actrun"]["package_lock_sha256"] != digest(ACTRUN_LOCK):
        raise ProfileError("actrun package lock is stale")
    return value


def external_path(value, repo=REPO):
    candidate = Path(value).expanduser().absolute()
    if candidate.is_symlink():
        raise ProfileError("profile root must not be a symbolic link")
    path = candidate.resolve()
    home = Path.home().resolve()
    if path == Path("/") or path == home or path == repo or repo in path.parents:
        raise ProfileError("profile must be dedicated and outside the source checkout")
    return path


def run(argv, *, env=None, cwd=None, log=None, timeout=1800):
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    if log:
        Path(log).parent.mkdir(parents=True, exist_ok=True)
        Path(log).write_text("$ " + " ".join(map(str, argv)) + "\n" + result.stdout)
    if result.returncode:
        raise ProfileError("command failed (" + str(result.returncode) + "): " + " ".join(map(str, argv)) +
                           ("; see " + str(log) if log else ""))
    return result.stdout.strip()


def host_identity():
    lock_value = lock()["host_contract"]
    if platform.system() != "Darwin" or platform.machine() != lock_value["architecture"]:
        raise ProfileError("profile requires the pinned macOS architecture")
    product = run(["sw_vers", "-productVersion"])
    build = run(["sw_vers", "-buildVersion"])
    xcode = run(["xcodebuild", "-version"]).splitlines()
    sdk = run(["xcrun", "--sdk", "macosx", "--show-sdk-version"])
    if product != lock_value["product_version"] or build != lock_value["build_version"] or \
       xcode != [lock_value["xcode_version"], lock_value["xcode_build_version"]] or sdk != lock_value["macos_sdk_version"]:
        raise ProfileError("current OS/Xcode/SDK differs from the reviewed macOS host contract")
    clang = Path(run(["xcrun", "--find", "clang"])).resolve(strict=True)
    sdk_path = Path(run(["xcrun", "--sdk", "macosx", "--show-sdk-path"])).resolve(strict=True)
    settings = sdk_path / "SDKSettings.plist"
    if not settings.is_file():
        raise ProfileError("selected macOS SDK is missing SDKSettings.plist")
    return {
        "system": platform.system(), "product_version": product, "build_version": build,
        "architecture": platform.machine(), "xcode": xcode,
        "xcode_select_path": run(["xcode-select", "-p"]), "sdk_version": sdk,
        "sdk_path": str(sdk_path), "sdk_settings_sha256": digest(settings),
        "clang_path": str(clang), "clang_sha256": digest(clang),
        "clang_version": run([str(clang), "--version"]).splitlines()[0],
    }


def profile_environment(root, base=None):
    root = Path(root).resolve(strict=True)
    current = dict(os.environ if base is None else base)
    host = host_identity()
    moon_home = root / "moon"
    node = shutil.which("node", path=current.get("PATH", os.defpath))
    if node:
        current["PATH"] = os.pathsep.join([str(moon_home / "bin"), str(root / "tools/z3/bin"),
                                           str(root / "tools/opam-switch/_opam/bin"),
                                           str(Path(node).resolve().parent),
                                           current.get("PATH", os.defpath)])
    else:
        current["PATH"] = os.pathsep.join([str(moon_home / "bin"), str(root / "tools/z3/bin"),
                                           str(root / "tools/opam-switch/_opam/bin"), current.get("PATH", os.defpath)])
    current["MOON_HOME"] = str(moon_home)
    current["DEVELOPER_DIR"] = host["xcode_select_path"]
    current["SDKROOT"] = host["sdk_path"]
    current["CC"] = host["clang_path"]
    current["GPUI_MACOS_TEXT_CC"] = host["clang_path"]
    current["MACOSX_DEPLOYMENT_TARGET"] = "26.0"
    # Do not inherit caller include/library search paths into the native build.
    # The selected Xcode SDK and the package's explicit frameworks are the full
    # compiler inputs; these empty values are also recorded in the evidence.
    for name in ("CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
                 "LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
        current[name] = ""
    current["GPUI_MACOS_PROFILE_ROOT"] = str(root)
    current["GPUI_MACOS_PROFILE_LOCK"] = str(LOCK_PATH)
    current["GPUI_TURTLES_BIN"] = str(root / "tools/turtles-schema2/turtles")
    current["GPUI_TURTLES_VERIFICATION_ROOT"] = str(root / "tools/turtles-verification")
    current["GPUI_TURTLES_SCHEMA3_BIN"] = str(root / "build/turtles-verification/native/release/build/cmd/turtles/turtles.exe")
    current["GPUI_TURTLES_VERIFICATION_PROFILE"] = str(root / "tools/turtles-verification-profile.json")
    current["GPUI_PROOF_WHY3"] = str(root / "tools/opam-switch/_opam/bin/why3")
    current["GPUI_PROOF_SOLVER"] = str(root / "tools/z3/bin/z3")
    current["GPUI_PROOF_TOOLCHAIN_LOCK"] = str(root / "tools/proof-toolchain.macos.lock.json")
    current["GPUI_HOTPATH_ROOT"] = str(root / "tools/hotpath")
    return current


def _download(url, target, expected):
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + ".part-" + uuid.uuid4().hex)
    value = hashlib.sha256()
    try:
        with urllib.request.urlopen(url, timeout=60) as response, partial.open("xb") as stream:
            while True:
                data = response.read(1024 * 1024)
                if not data:
                    break
                value.update(data)
                stream.write(data)
        if value.hexdigest() != expected:
            raise ProfileError("download SHA-256 differs from the profile lock: " + url)
        partial.replace(target)
    finally:
        partial.unlink(missing_ok=True)
    return target


def _safe_extract_tar(archive, destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:*") as bundle:
        members = bundle.getmembers()
        for member in members:
            name = Path(member.name)
            if name.is_absolute() or any(part in {"..", ""} for part in name.parts):
                raise ProfileError("archive contains a path outside its destination")
            if member.issym() or member.islnk():
                link = Path(member.linkname)
                if link.is_absolute() or any(part in {"..", ""} for part in link.parts):
                    raise ProfileError("archive contains an invalid link target")
                base = destination if member.islnk() else destination / name.parent
                resolved = (base / link).resolve()
                if not resolved.is_relative_to(destination):
                    raise ProfileError("archive link escapes its destination")
        bundle.extractall(destination, filter="data")


def _safe_extract_zip(archive, destination):
    destination = Path(destination).resolve()
    destination.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as bundle:
        for name in bundle.namelist():
            path = Path(name)
            if path.is_absolute() or any(part in {"..", ""} for part in path.parts):
                raise ProfileError("archive contains a path outside its destination")
        bundle.extractall(destination)


def _toolchain_files(root):
    required = ["bin/moon", "bin/moonc", "bin/moonfmt", "bin/moonrun",
                "lib/why3/why3server", "lib/prelude_proof/moonbit_builtin_prelude.mlw",
                "share/why3/drivers/z3_471.drv", "lib/core/moon.mod",
                "lib/core/_build/wasm/release/bundle/prelude/prelude.mi"]
    result = {}
    for name in required:
        path = root / "moon" / name
        if not path.is_file() or path.is_symlink():
            raise ProfileError("pinned Moon/core archive is incomplete: " + name)
        result[name] = digest(path)
    if result[PRELUDE_MI] != PRELUDE_MI_SHA256:
        raise ProfileError("bundled Moon proof prelude differs from its reviewed archive-derived hash")
    for name, relative in {
        "tree/core_sources": "lib/core",
        "tree/prelude_proof": "lib/prelude_proof",
        "tree/why3_drivers": "share/why3/drivers",
        "tree/why3_stdlib": "share/why3/stdlib",
    }.items():
        result[name] = source_tree_digest(root / "moon" / relative)
    return result


def _migrate_prelude_receipt(previous, actual):
    additions = set(actual) - set(previous)
    if additions != {PRELUDE_MI} or actual.get(PRELUDE_MI) != PRELUDE_MI_SHA256 or \
       any(actual.get(name) != value for name, value in previous.items()):
        raise ProfileError("cannot safely extend the older Moon receipt with the reviewed prelude artifact")
    migrated = dict(previous)
    migrated[PRELUDE_MI] = PRELUDE_MI_SHA256
    return migrated


def _verify_moon_source_trees(root, profile):
    archives = {item["destination"]: root / "downloads" / item["name"]
                for item in profile["toolchain"]["archives"]}
    for item in profile["toolchain"]["archives"]:
        path = archives[item["destination"]]
        if not path.is_file() or digest(path) != item["sha256"]:
            raise ProfileError("pinned Moon/core source archive is unavailable for source qualification")
    scratch = root / "build/moon-source-qualification"
    _remove_owned(scratch)
    moon_archive = scratch / "moon-archive"
    core_archive = scratch / "core-archive"
    moon_archive.mkdir(parents=True)
    core_archive.mkdir(parents=True)
    _safe_extract_tar(archives["moon"], moon_archive)
    _safe_extract_tar(archives["moon/lib"], core_archive)
    pairs = [
        (root / "moon/lib/core", core_archive / "core"),
        (root / "moon/lib/prelude_proof", moon_archive / "lib/prelude_proof"),
        (root / "moon/share/why3/drivers", moon_archive / "share/why3/drivers"),
        (root / "moon/share/why3/stdlib", moon_archive / "share/why3/stdlib"),
    ]
    for installed, archived in pairs:
        if not installed.is_dir() or not archived.is_dir() or \
           source_tree_digest(installed) != source_tree_digest(archived):
            raise ProfileError("installed Moon/core proof source differs from its pinned archive: " + str(installed))
    _remove_owned(scratch)


def tree_digest(path):
    path = Path(path).resolve(strict=True)
    value = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        if entry.is_symlink():
            raise ProfileError("tool runtime tree contains a symlink: " + str(entry))
        if entry.is_file():
            value.update(entry.relative_to(path).as_posix().encode() + b"\0" + bytes.fromhex(digest(entry)))
    return value.hexdigest()


def source_tree_digest(path):
    path = Path(path).resolve(strict=True)
    value = hashlib.sha256()
    ignored = {"_build", ".mooncakes", ".git"}
    for entry in sorted(path.rglob("*")):
        if any(part in ignored for part in entry.relative_to(path).parts):
            continue
        if entry.is_symlink():
            target = entry.resolve(strict=True)
            if not target.is_relative_to(path):
                raise ProfileError("qualified source/runtime symlink escapes its tree: " + str(entry))
            value.update(entry.relative_to(path).as_posix().encode() + b"\0link\0" +
                         os.readlink(entry).encode() + b"\0" + bytes.fromhex(digest(target)))
        elif entry.is_file():
            value.update(entry.relative_to(path).as_posix().encode() + b"\0" + bytes.fromhex(digest(entry)))
    return value.hexdigest()


def _remove_owned(path):
    if path.is_symlink():
        raise ProfileError("refusing to replace a symlinked bootstrap artifact: " + str(path))
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def _git_value(root, expression):
    return run(["git", "-C", str(root), "rev-parse", expression])


def _git_tracked_clean(root):
    return subprocess.run(["git", "-C", str(root), "diff", "--quiet", "HEAD", "--"],
                          check=False).returncode == 0 and \
        subprocess.run(["git", "-C", str(root), "diff", "--cached", "--quiet", "HEAD", "--"],
                       check=False).returncode == 0


def _checkout_exact(destination, repository, commit, tree):
    destination = Path(destination)
    if destination.is_dir() and not destination.is_symlink() and (destination / ".git").exists():
        try:
            origin = run(["git", "-C", str(destination), "remote", "get-url", "origin"])
            status = run(["git", "-C", str(destination), "status", "--porcelain", "--untracked-files=all"])
            untracked = [line[3:] for line in status.splitlines() if line.startswith("?? ")]
            tracked_clean = subprocess.run(["git", "-C", str(destination), "diff", "--quiet", "HEAD", "--"],
                                           check=False).returncode == 0
            cached_clean = subprocess.run(["git", "-C", str(destination), "diff", "--cached", "--quiet", "HEAD", "--"],
                                          check=False).returncode == 0
            generated_only = all(path == ".mooncakes" or path.startswith(".mooncakes/") for path in untracked)
            if origin == repository and _git_value(destination, "HEAD") == commit and \
               _git_value(destination, "HEAD^{tree}") == tree and tracked_clean and cached_clean and generated_only:
                return destination
        except (ProfileError, subprocess.SubprocessError):
            pass
    if destination.exists():
        _remove_owned(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["git", "clone", "--quiet", repository, str(destination)], timeout=1200)
    run(["git", "-C", str(destination), "checkout", "--quiet", "--detach", commit], timeout=300)
    if _git_value(destination, "HEAD") != commit or _git_value(destination, "HEAD^{tree}") != tree:
        raise ProfileError("pinned source checkout differs from its exact commit/tree: " + str(destination))
    return destination


def _quality_locks():
    return (json.loads(TURTLES_SCHEMA2_LOCK.read_text()),
            json.loads(TURTLES_SCHEMA3_LOCK.read_text()),
            json.loads(HOTPATH_LOCK.read_text()))


def _prepare_registry_index(root, index_lock):
    path = Path(root) / "moon/registry/index"
    if path.is_dir() and not path.is_symlink() and (path / ".git").exists():
        origin = run(["git", "-C", str(path), "remote", "get-url", "origin"])
        if origin == index_lock["url"] and _git_value(path, "HEAD") == index_lock["commit"] and \
           _git_value(path, "HEAD^{tree}") == index_lock["tree"]:
            run(["git", "-C", str(path), "reset", "--hard", index_lock["commit"]])
            run(["git", "-C", str(path), "clean", "-fd"])
            return path
    return _checkout_exact(path, index_lock["url"], index_lock["commit"], index_lock["tree"])


def _verify_registry_dependencies(root, index_lock, packages):
    path = Path(root) / "moon/registry/index"
    if _git_value(path, "HEAD") != index_lock["commit"] or \
       _git_value(path, "HEAD^{tree}") != index_lock["tree"]:
        raise ProfileError("Moon registry index commit/tree differs from Mac lock")
    resolved = {}
    for archive_path, expected in packages.items():
        parts = Path(archive_path).parts
        if len(parts) != 3 or not parts[2].endswith(".zip"):
            raise ProfileError("malformed locked Moon package archive path: " + archive_path)
        user, module = parts[:2]
        version = parts[2][:-4]
        relative_index = "user/" + user + "/" + module + ".index"
        index_bytes = subprocess.check_output(["git", "-C", str(path), "show",
                                               index_lock["commit"] + ":" + relative_index])
        if hashlib.sha256(index_bytes).hexdigest() != index_lock.get("package_records_sha256", {}).get(relative_index):
            raise ProfileError("pinned Moon registry package index bytes differ from the lock: " + relative_index)
        text = index_bytes.decode()
        rows = [json.loads(line) for line in text.splitlines() if line.strip()]
        candidates = [row for row in rows if row.get("name") == user + "/" + module and row.get("version") == version]
        if len(candidates) != 1:
            raise ProfileError("pinned Moon registry has no unique package record for " + archive_path)
        row = candidates[0]
        if row.get("checksum") != expected or row.get("yanked") is True:
            raise ProfileError("pinned Moon registry package record differs from locked archive: " + archive_path)
        cache = Path(root) / "moon/registry/cache" / archive_path
        if not cache.is_file() or digest(cache) != expected:
            raise ProfileError("resolved Moon package archive differs from pinned registry checksum: " + archive_path)
        working_index = path / relative_index
        if working_index.is_file():
            current_rows = [json.loads(line) for line in working_index.read_text().splitlines() if line.strip()]
            current = [row for row in current_rows if row.get("name") == user + "/" + module and row.get("version") == version]
            if len(current) != 1 or current[0].get("checksum") != expected or current[0].get("yanked") is True:
                raise ProfileError("Moon's active registry working index changed the locked package record: " + archive_path)
        resolved[user + "/" + module + "@" + version] = expected
    return resolved


def _prepare_quality_tools(root, env, logs):
    schema2, schema3, hotpath = _quality_locks()
    if schema2.get("toolchain_profile_lock") != LOCK_PATH.name or schema3.get("toolchain_profile_lock") != LOCK_PATH.name:
        raise ProfileError("Mac Turtles tool locks do not reference this profile lock")
    moon = root / "moon/bin/moon"
    tools = root / "tools"
    build = root / "build"
    schema2_bin = root / schema2["binary_path"]
    schema2_bin.parent.mkdir(parents=True, exist_ok=True)
    _prepare_registry_index(root, schema2["registry_index"])
    run([str(moon), "install", schema2["package"], "--bin", str(schema2_bin.parent),
         "--target-dir", str(build / "turtles-schema2")], env=env, cwd=REPO,
        log=logs / "turtles-schema2-install.log", timeout=2400)
    if not schema2_bin.is_file():
        raise ProfileError("schema-2 Turtles install produced no executable")
    version = run([str(schema2_bin), "--version"], env=env)
    if version != schema2["version"]:
        raise ProfileError("schema-2 Turtles version differs from the Mac artifact lock")
    dependency_inventory = _verify_registry_dependencies(root, schema2["registry_index"],
                                                         schema2["registry_archives"])
    for package, expected in schema2["registry_archives"].items():
        archive = root / "moon/registry/cache" / package
        if not archive.is_file() or digest(archive) != expected:
            raise ProfileError("Moon registry package cache differs from Mac Turtles lock: " + package)

    schema3_source = _checkout_exact(tools / "turtles-verification",
                                     schema3["upstream"]["repository"], schema3["upstream"]["commit"],
                                     schema3["upstream"]["tree"])
    adapter = schema3_source / schema3["upstream"]["adapter"]
    if not adapter.is_file() or digest(adapter) != schema3["upstream"]["adapter_sha256"]:
        raise ProfileError("schema-3 Turtles adapter source differs from the reviewed upstream pin")
    schema3_bin = root / schema3["binary_path"]
    _prepare_registry_index(root, schema3["registry_index"])
    _remove_owned(schema3_source / ".mooncakes")
    run([str(moon), "build", "--target", "native", "--release", "--deny-warn",
         "--target-dir", str(build / "turtles-verification")], env=env, cwd=schema3_source,
        log=logs / "turtles-schema3-build.log", timeout=2400)
    if not schema3_bin.is_file():
        raise ProfileError("schema-3 Turtles build produced no executable")
    if run([str(schema3_bin), "--version"], env=env) != schema3["version"]:
        raise ProfileError("schema-3 Turtles version differs from its Mac artifact lock")
    _verify_registry_dependencies(root, schema3["registry_index"], schema2["registry_archives"])
    profile_path = tools / "turtles-verification-profile.json"
    generated_profile = {**schema3["profile_template"], "turtles_sha256": digest(schema3_bin)}
    profile_path.write_text(json.dumps(generated_profile, indent=2) + "\n")
    schema2_dependencies = build / "turtles-schema2/native/release/build/.mooncakes"
    schema3_dependencies = schema3_source / ".mooncakes"
    if not schema2_dependencies.is_dir() or not schema3_dependencies.is_dir():
        raise ProfileError("pinned Turtles builds did not retain resolved dependency source trees")

    hotpath_root = _checkout_exact(tools / "hotpath", hotpath["repository"],
                                   hotpath["published_source"]["main_commit"],
                                   hotpath["published_source"]["tree"])
    for name, expected in hotpath["runtime_files"].items():
        file = hotpath_root / name
        if not file.is_file() or file.is_symlink() or digest(file) != expected:
            raise ProfileError("pinned hotpath runtime source differs from Mac lock: " + name)
    return {
        "schema2_lock_sha256": digest(TURTLES_SCHEMA2_LOCK),
        "schema2_binary_sha256": digest(schema2_bin),
        "schema2_version": schema2["version"],
        "schema2_dependency_tree_sha256": source_tree_digest(schema2_dependencies),
        "registry_archives": schema2["registry_archives"],
        "registry_index_commit": schema2["registry_index"]["commit"],
        "registry_index_tree": schema2["registry_index"]["tree"],
        "resolved_dependencies": dependency_inventory,
        "schema3_lock_sha256": digest(TURTLES_SCHEMA3_LOCK),
        "schema3_profile_sha256": digest(profile_path),
        "schema3_profile": generated_profile,
        "schema3_source_commit": _git_value(schema3_source, "HEAD"),
        "schema3_source_tree": _git_value(schema3_source, "HEAD^{tree}"),
        "schema3_adapter_sha256": digest(adapter),
        "schema3_binary_sha256": digest(schema3_bin),
        "schema3_version": schema3["version"],
        "schema3_dependency_tree_sha256": source_tree_digest(schema3_dependencies),
        "hotpath_lock_sha256": digest(HOTPATH_LOCK),
        "hotpath_source_commit": _git_value(hotpath_root, "HEAD"),
        "hotpath_source_tree": _git_value(hotpath_root, "HEAD^{tree}"),
        "hotpath_runtime_files": {name: digest(hotpath_root / name) for name in hotpath["runtime_files"]},
        "turtles_build_environment": {name: env.get(name, "") for name in
            ("CC", "GPUI_MACOS_TEXT_CC", "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
             "CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
             "LIBRARY_PATH", "DYLD_LIBRARY_PATH")},
        "moon_binary_sha256": digest(moon),
        "moonc_binary_sha256": digest(root / "moon/bin/moonc"),
        "profile_root": str(root),
    }


def bootstrap(root, *, with_proof=True):
    root = external_path(root)
    profile = lock()
    host = host_identity()
    if root.exists() and (root / "installed.json").is_file():
        # A base profile can be extended in a later run without throwing away
        # the expensive, already qualified OPAM/Why3 build. Only the exact
        # profile receipt authorizes this continuation.
        old_marker = json.loads((root / "installed.json").read_text())
        old_quality = isinstance(old_marker.get("quality_tools"), dict)
        proof_lock_exists = (root / "tools/proof-toolchain.macos.lock.json").is_file()
        doctor(root, require_proof=with_proof and proof_lock_exists, require_quality=False)
        if old_quality:
            try:
                doctor(root, require_proof=with_proof, require_quality=True)
                print("profile is already current: " + str(root))
                return
            except ProfileError:
                # One additive schema migration records the generated bundled
                # Moon proof prelude that older receipts did not inventory.
                # Every previously recorded input must remain byte-identical;
                # no Turtles/Why3/host/tool receipt may be silently refreshed.
                previous = old_marker.get("moon", {}).get("toolchain_files", {})
                actual = _toolchain_files(root)
                try:
                    migrated = _migrate_prelude_receipt(previous, actual)
                except ProfileError:
                    raise
                old_marker.setdefault("moon", {})["toolchain_files"] = migrated
                (root / "installed.json").write_text(json.dumps(old_marker, indent=2) + "\n")
                if with_proof:
                    _write_proof_lock(root, old_marker)
                doctor(root, require_proof=with_proof, require_quality=True)
                print("profile_receipt_migrated=" + str(root))
                return
        progress = root / "bootstrap-in-progress.json"
        receipt = {"schema_version": 1, "root": str(root), "lock_sha256": digest(LOCK_PATH),
                   "profile": profile, "host": host}
        temporary = root / (".bootstrap-in-progress-" + uuid.uuid4().hex)
        temporary.write_text(json.dumps(receipt, indent=2) + "\n")
        temporary.replace(progress)
        logs = root / "bootstrap-logs"
        logs.mkdir(exist_ok=True)
        env = profile_environment(root)
        _verify_moon_source_trees(root, profile)
        quality = _prepare_quality_tools(root, env, logs)
        marker_path = root / "installed.json"
        marker = json.loads(marker_path.read_text())
        marker.setdefault("moon", {})["toolchain_files"] = _toolchain_files(root)
        marker["quality_tools"] = quality
        marker_path.write_text(json.dumps(marker, indent=2) + "\n")
        _write_proof_lock(root, marker)
        progress.unlink(missing_ok=True)
        doctor(root, require_proof=with_proof, require_quality=True)
        print("quality_tools_prepared=" + str(root))
        return
    if root.exists():
        marker = root / "installed.json"
        if marker.is_file():
            doctor(root)
            print("profile is already current: " + str(root))
            return
        progress = root / "bootstrap-in-progress.json"
        if progress.is_file() and not progress.is_symlink():
            receipt = json.loads(progress.read_text())
            if receipt.get("schema_version") != 1 or receipt.get("root") != str(root) or \
               receipt.get("lock_sha256") != digest(LOCK_PATH) or receipt.get("profile") != profile or \
               receipt.get("host") != host:
                raise ProfileError("in-progress receipt does not authorize recovery for this profile/host/lock")
            unknown = {entry.name for entry in root.iterdir()} - OWNED_ENTRIES
            if unknown:
                raise ProfileError("refusing recovery because the profile contains unowned entries: " + ", ".join(sorted(unknown)))
        elif any(root.iterdir()):
            raise ProfileError("refusing to replace a non-empty directory without this tool's recovery receipt")
    else:
        root.mkdir(parents=True, exist_ok=False)
    receipt = {"schema_version": 1, "root": str(root), "lock_sha256": digest(LOCK_PATH),
               "profile": profile, "host": host}
    progress_path = root / "bootstrap-in-progress.json"
    temporary_receipt = root / (".bootstrap-in-progress-" + uuid.uuid4().hex)
    temporary_receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    temporary_receipt.replace(progress_path)
    downloads = root / "downloads"
    tools = root / "tools"
    (root / "moon").mkdir(parents=True, exist_ok=True)
    (tools / "actrun").mkdir(parents=True, exist_ok=True)
    env = profile_environment(root)
    env["MOON_HOME"] = str(root / "moon")
    env["PATH"] = str(root / "moon/bin") + os.pathsep + env.get("PATH", os.defpath)
    logs = root / "bootstrap-logs"
    logs.mkdir(exist_ok=True)

    for archive in profile["toolchain"]["archives"]:
        item = _download(archive["url"], downloads / archive["name"], archive["sha256"])
        destination = root / archive["destination"]
        _safe_extract_tar(item, destination)
    # The published Moon archive stores command binaries without executable
    # mode bits. Restore only the known executable names in this private copy.
    moon_bin = root / "moon/bin"
    for name in ("moon", "moonc", "moonfmt", "moonrun", "moondoc", "mooninfo",
                 "mooncake", "moon-ide", "moon-lsp", "moon-wasm-opt", "moon-cram"):
        path = moon_bin / name
        if path.is_file():
            path.chmod(path.stat().st_mode | 0o111)
    if not (root / "moon/lib/core/moon.mod").is_file():
        raise ProfileError("the Moon core archive did not install its pinned module")
    run([str(root / "moon/bin/moon"), "bundle", "--target", "all"],
        env=env, cwd=root / "moon/lib/core", log=logs / "moon-bundle.log", timeout=1200)
    moon_version = run([str(root / "moon/bin/moon"), "version"], env=env,
                       log=logs / "moon-version.log")
    if profile["toolchain"]["moon_version"] not in moon_version or \
       profile["toolchain"]["moonbit_version"] not in run([str(root / "moon/bin/moonc"), "-v"], env=env):
        raise ProfileError("installed Moon compiler/tool version differs from the lock")

    package_lock = ACTRUN_LOCK.read_bytes()
    actrun_lock = profile["actrun"]
    if hashlib.sha256(package_lock).hexdigest() != actrun_lock["package_lock_sha256"]:
        raise ProfileError("actrun dependency lock hash differs from the profile lock")
    package_root = tools / "actrun"
    (package_root / "package.json").write_text(json.dumps({
        "name": "gpui-macos-actrun", "version": "1.0.0", "private": True,
        "dependencies": {"@mizchi/actrun": actrun_lock["version"]}}, indent=2) + "\n")
    (package_root / "package-lock.json").write_bytes(package_lock)
    run(["npm", "ci", "--prefix", str(package_root), "--ignore-scripts", "--no-audit", "--no-fund",
         "--registry=https://registry.npmjs.org"], log=logs / "actrun-npm-ci.log", timeout=300)
    cli = package_root / "node_modules/@mizchi/actrun/dist/actrun.js"
    if not cli.is_file() or digest(cli) != actrun_lock["cli_sha256"]:
        raise ProfileError("installed actrun CLI differs from @mizchi/actrun 0.32.0 pin")

    z3 = profile["proof_build_inputs"]
    z3_archive = _download(z3["z3_url"], downloads / Path(z3["z3_url"]).name, z3["z3_archive_sha256"])
    _safe_extract_zip(z3_archive, tools / "z3-extract")
    z3_binary = tools / "z3-extract/z3-4.13.3-arm64-osx-13.7/bin/z3"
    if not z3_binary.is_file():
        raise ProfileError("pinned Z3 archive has no macOS arm64 executable")
    z3_bin_dir = tools / "z3/bin"
    z3_bin_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(z3_binary, z3_bin_dir / "z3")
    (z3_bin_dir / "z3").chmod(0o755)
    if digest(z3_bin_dir / "z3") != z3["z3_executable_sha256"]:
        raise ProfileError("installed Z3 executable differs from the platform archive lock")

    proof_tools = {"z3_archive_sha256": digest(z3_archive), "z3_sha256": digest(z3_bin_dir / "z3")}
    if with_proof:
        proof_root = tools / "proof"
        opam_dir = tools / "opam"
        opam_dir.mkdir(parents=True, exist_ok=True)
        opam_source = _download(z3["opam_url"], downloads / ("opam-" + Path(z3["opam_url"]).name),
                                z3["opam_sha256"])
        opam_bin = opam_dir / "opam"
        shutil.copy2(opam_source, opam_bin)
        opam_bin.chmod(0o755)
        repository_archive = _download(z3["opam_repository_url"],
                                       downloads / ("opam-repository-" + z3["opam_repository_commit"] + ".tar.gz"),
                                       z3["opam_repository_sha256"])
        why3_source = _download(z3["why3_source_url"], downloads / Path(z3["why3_source_url"]).name,
                                z3["why3_source_sha256"])
        repository = proof_root / "opam-repository"
        _remove_owned(repository)
        repository.mkdir(parents=True, exist_ok=True)
        _safe_extract_tar(repository_archive, repository)
        entries = list(repository.iterdir())
        if len(entries) == 1 and entries[0].is_dir():
            extracted = entries[0]
            stage = proof_root / "opam-repository-root"
            extracted.replace(stage)
            repository.rmdir()
            stage.replace(repository)
        opam_root = tools / "opam-root"
        switch_root = tools / "opam-switch"
        switch = switch_root / "_opam"
        repo_uri = repository.as_uri()
        if (opam_root / "config").is_file():
            repositories = run([str(opam_bin), "repository", "list", "--all", "--root=" + str(opam_root)])
            if repo_uri not in repositories:
                raise ProfileError("existing OPAM root does not select this profile's pinned local repository")
        else:
            run([str(opam_bin), "init", "--bare", "--no-setup", "--no-opamrc",
                 "--yes", "--root=" + str(opam_root), "macos-proof", repo_uri],
                log=logs / "opam-init.log", timeout=300)
        if (switch / "bin/ocamlc").is_file():
            if run([str(switch / "bin/ocamlc"), "-version"]) != z3["ocaml_version"]:
                raise ProfileError("existing OPAM switch compiler does not match the locked version")
        else:
            if switch_root.exists():
                _remove_owned(switch_root)
            run([str(opam_bin), "switch", "create", str(switch_root), "ocaml-base-compiler." + z3["ocaml_version"],
                 "--no-switch", "--yes", "--root=" + str(opam_root)],
                log=logs / "opam-ocaml-switch.log", timeout=2400)
        opam_env = {**os.environ, "OPAMROOT": str(opam_root), "OPAMSWITCH": str(switch_root),
                    "OPAMYES": "1", "OPAMNOAUTOUPGRADE": "1"}
        run([str(opam_bin), "install", "--yes", "--root=" + str(opam_root), "--switch=" + str(switch_root),
             "why3." + z3["why3_version"]], env=opam_env, log=logs / "opam-why3-install.log", timeout=3600)
        why3_bin = switch / "bin/why3"
        if not why3_bin.is_file() or not (switch / "lib/why3/commands/why3prove.cmxs").is_file():
            raise ProfileError("pinned opam switch did not produce Why3 and its prove plugin")
        why3_libdir = Path(run([str(why3_bin), "--print-libdir"], env=opam_env)).resolve(strict=True)
        plugin = why3_libdir / "commands/why3prove.cmxs"
        proof_tools.update({"opam_version": run([str(opam_bin), "--version"]),
                            "opam_repository_commit": z3["opam_repository_commit"],
                            "opam_binary_sha256": digest(opam_bin),
                            "opam_repository_archive_sha256": digest(repository_archive),
                            "why3_source_archive_sha256": digest(downloads / Path(z3["why3_source_url"]).name),
                            "ocaml_version": run([str(opam_bin), "exec", "--root=" + str(opam_root),
                                "--switch=" + str(switch_root), "--", "ocamlc", "-version"], env=opam_env),
                            "ocamlc_sha256": digest(switch / "bin/ocamlc"),
                            "why3_version": run([str(why3_bin), "--version"], env=opam_env),
                            "why3_sha256": digest(why3_bin),
                            "why3_plugin_sha256": digest(plugin),
                            "why3_libdir": str(why3_libdir),
                            "why3_tree_sha256": tree_digest(why3_libdir)})

    quality_tools = _prepare_quality_tools(root, profile_environment(root), logs)
    marker = {
        "schema_version": 1, "lock_sha256": digest(LOCK_PATH), "profile": profile,
        "installed_at_host": host, "moon": {"version": moon_version,
            "toolchain_files": _toolchain_files(root)},
        "actrun": {"package_lock_sha256": digest(package_root / "package-lock.json"),
                   "cli_sha256": digest(cli), "version": actrun_lock["version"]},
        "proof_tools": proof_tools, "quality_tools": quality_tools,
        "global_settings_changed": False,
    }
    (root / "installed.json").write_text(json.dumps(marker, indent=2) + "\n")
    if with_proof:
        _write_proof_lock(root, marker)
    progress_path.unlink(missing_ok=True)
    print("prepared=" + str(root))
    print("installed=" + str(root / "installed.json"))


def doctor(root, *, require_proof=True, require_quality=True):
    root = external_path(root)
    marker_path = root / "installed.json"
    if marker_path.is_symlink() or not marker_path.is_file():
        raise ProfileError("profile has no regular installed.json marker; run profile.py bootstrap")
    marker = json.loads(marker_path.read_text())
    current = lock()
    if marker.get("schema_version") != 1 or marker.get("lock_sha256") != digest(LOCK_PATH) or marker.get("profile") != current:
        raise ProfileError("installed profile marker is stale for the current Mac lock")
    host = host_identity()
    if marker.get("installed_at_host") != host:
        raise ProfileError("profile host/SDK identity differs from the installed evidence")
    actual_toolchain = _toolchain_files(root)
    recorded_toolchain = marker.get("moon", {}).get("toolchain_files", {})
    if any(actual_toolchain.get(name) != value for name, value in recorded_toolchain.items()) or \
       (require_quality and recorded_toolchain != actual_toolchain):
        raise ProfileError("Moon/core installed bytes changed after bootstrap")
    if marker.get("moon", {}).get("version") != run([str(root / "moon/bin/moon"), "version"],
                                                       env={**os.environ, "MOON_HOME": str(root / "moon")}):
        raise ProfileError("Moon executable version differs from installed marker")
    actrun_cli = root / "tools/actrun/node_modules/@mizchi/actrun/dist/actrun.js"
    if digest(actrun_cli) != current["actrun"]["cli_sha256"] or \
       marker.get("actrun", {}).get("cli_sha256") != digest(actrun_cli):
        raise ProfileError("actrun binary differs from locked package")
    node = shutil.which("node")
    if not node:
        raise ProfileError("Node.js is required to run actrun; install it in a user-owned runtime")
    node_version = run([node, "--version"])
    try:
        node_major = int(node_version.removeprefix("v").split(".", 1)[0])
    except (ValueError, IndexError):
        raise ProfileError("Node.js reported an invalid version") from None
    if node_major < current["actrun"]["node_minimum_major"]:
        raise ProfileError("Node.js is below the actrun package minimum")
    z3_path = root / "tools/z3/bin/z3"
    if not z3_path.is_file() or digest(z3_path) != current["proof_build_inputs"]["z3_executable_sha256"] or \
       marker.get("proof_tools", {}).get("z3_sha256") != digest(z3_path):
        raise ProfileError("Mac Z3 is missing or differs from bootstrap evidence")
    proof_tools = marker.get("proof_tools", {})
    proof_inputs = current["proof_build_inputs"]
    if proof_tools.get("z3_archive_sha256") != proof_inputs["z3_archive_sha256"] or \
       marker.get("proof_tools", {}).get("z3_sha256") != digest(z3_path):
        raise ProfileError("proof source/archive receipts differ from the platform lock")
    why3_path = root / "tools/opam-switch/_opam/bin/why3"
    if not why3_path.is_file():
        if require_proof:
            raise ProfileError("profile has no qualified Why3 build; run profile.py bootstrap")
    else:
        opam_bin = root / "tools/opam/opam"
        opam_archive = root / "downloads" / ("opam-" + Path(proof_inputs["opam_url"]).name)
        repository_archive = root / "downloads" / ("opam-repository-" + proof_inputs["opam_repository_commit"] + ".tar.gz")
        why3_source = root / "downloads" / Path(proof_inputs["why3_source_url"]).name
        if not opam_bin.is_file() or digest(opam_bin) != proof_inputs["opam_sha256"] or \
           not opam_archive.is_file() or digest(opam_archive) != proof_inputs["opam_sha256"]:
            raise ProfileError("profile-owned OPAM binary/archive differs from the platform lock")
        if not repository_archive.is_file() or digest(repository_archive) != proof_inputs["opam_repository_sha256"] or \
           proof_tools.get("opam_repository_commit") != proof_inputs["opam_repository_commit"] or \
           proof_tools.get("opam_repository_archive_sha256") != proof_inputs["opam_repository_sha256"]:
            raise ProfileError("pinned OPAM repository source receipt is missing or stale")
        if not why3_source.is_file() or digest(why3_source) != proof_inputs["why3_source_sha256"] or \
           proof_tools.get("why3_source_archive_sha256") != proof_inputs["why3_source_sha256"]:
            raise ProfileError("pinned Why3 source archive receipt is missing or stale")
        if proof_tools.get("opam_binary_sha256") != digest(opam_bin) or \
           proof_tools.get("why3_sha256") != digest(why3_path) or \
           proof_tools.get("why3_version") != run([str(why3_path), "--version"]):
            raise ProfileError("Why3/OPAM executable differs from bootstrap evidence")
        why3_libdir = Path(run([str(why3_path), "--print-libdir"])).resolve(strict=True)
        plugin = why3_libdir / "commands/why3prove.cmxs"
        if str(why3_libdir) != proof_tools.get("why3_libdir") or not plugin.is_file() or \
           digest(plugin) != proof_tools.get("why3_plugin_sha256") or \
           tree_digest(why3_libdir) != proof_tools.get("why3_tree_sha256"):
            raise ProfileError("Why3 plugin/runtime data tree differs from bootstrap evidence")
        ocamlc = root / "tools/opam-switch/_opam/bin/ocamlc"
        if not ocamlc.is_file() or digest(ocamlc) != proof_tools.get("ocamlc_sha256") or \
           proof_tools.get("ocaml_version") != run([str(ocamlc), "-version"]):
            raise ProfileError("OCaml compiler differs from the OPAM build receipt")
    if require_quality:
        _doctor_quality(root, marker)
    if require_proof:
        _doctor_proof_lock(root, marker)
    print("doctor=passed")
    print("profile=" + str(root))
    print("host=" + json.dumps(host, sort_keys=True))


def _doctor_quality(root, marker):
    schema2, schema3, hotpath = _quality_locks()
    receipt = marker.get("quality_tools")
    if not isinstance(receipt, dict):
        raise ProfileError("quality tools are not provisioned; run profile.py bootstrap")
    schema2_bin = root / schema2["binary_path"]
    schema3_bin = root / schema3["binary_path"]
    schema3_root = root / "tools/turtles-verification"
    profile_path = root / "tools/turtles-verification-profile.json"
    hotpath_root = root / "tools/hotpath"
    if receipt.get("schema2_lock_sha256") != digest(TURTLES_SCHEMA2_LOCK) or \
       not schema2_bin.is_file() or \
       receipt.get("schema2_binary_sha256") != digest(schema2_bin) or \
       run([str(schema2_bin), "--version"]) != schema2["version"]:
        raise ProfileError("schema-2 Turtles installation differs from its Mac lock")
    for package, expected in schema2["registry_archives"].items():
        archive = root / "moon/registry/cache" / package
        if not archive.is_file() or digest(archive) != expected or receipt.get("registry_archives", {}).get(package) != expected:
            raise ProfileError("pinned Turtles registry archive is missing or stale: " + package)
    if receipt.get("schema3_lock_sha256") != digest(TURTLES_SCHEMA3_LOCK) or \
       receipt.get("schema3_profile_sha256") != digest(profile_path) or \
       json.loads(profile_path.read_text()) != receipt.get("schema3_profile") or \
       receipt.get("schema3_profile") != {**schema3["profile_template"],
                                            "turtles_sha256": receipt.get("schema3_binary_sha256")}:
        raise ProfileError("schema-3 Turtles profile/lock receipt is stale")
    if _git_value(schema3_root, "HEAD") != schema3["upstream"]["commit"] or \
       _git_value(schema3_root, "HEAD^{tree}") != schema3["upstream"]["tree"] or \
       not _git_tracked_clean(schema3_root) or \
       digest(schema3_root / schema3["upstream"]["adapter"]) != schema3["upstream"]["adapter_sha256"] or \
       receipt.get("schema3_source_commit") != schema3["upstream"]["commit"] or \
       receipt.get("schema3_source_tree") != schema3["upstream"]["tree"] or \
       receipt.get("schema3_adapter_sha256") != schema3["upstream"]["adapter_sha256"]:
        raise ProfileError("schema-3 Turtles exact source/adapter bytes changed")
    if not schema3_bin.is_file() or receipt.get("schema3_binary_sha256") != digest(schema3_bin) or \
       run([str(schema3_bin), "--version"]) != schema3["version"]:
        raise ProfileError("schema-3 Turtles executable differs from its profile build receipt")
    index_lock = schema2["registry_index"]
    if receipt.get("registry_index_commit") != index_lock["commit"] or \
       receipt.get("registry_index_tree") != index_lock["tree"] or \
       receipt.get("resolved_dependencies") != _verify_registry_dependencies(root, index_lock,
                                                                            schema2["registry_archives"]):
        raise ProfileError("Turtles dependency versions/checksums differ from the pinned Moon registry")
    schema2_dependencies = root / "build/turtles-schema2/native/release/build/.mooncakes"
    schema3_dependencies = schema3_root / ".mooncakes"
    if not schema2_dependencies.is_dir() or not schema3_dependencies.is_dir() or \
       receipt.get("schema2_dependency_tree_sha256") != source_tree_digest(schema2_dependencies) or \
       receipt.get("schema3_dependency_tree_sha256") != source_tree_digest(schema3_dependencies):
        raise ProfileError("resolved Turtles dependency source inputs changed after the locked build")
    current_env = profile_environment(root)
    env_names = ("CC", "GPUI_MACOS_TEXT_CC", "SDKROOT", "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET",
                 "CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH",
                 "LIBRARY_PATH", "DYLD_LIBRARY_PATH")
    if receipt.get("turtles_build_environment") != {name: current_env.get(name, "") for name in env_names} or \
       receipt.get("profile_root") != str(root) or \
       receipt.get("moon_binary_sha256") != digest(root / "moon/bin/moon") or \
       receipt.get("moonc_binary_sha256") != digest(root / "moon/bin/moonc"):
        raise ProfileError("Turtles build environment/compiler identity changed since profile bootstrap")
    if receipt.get("hotpath_lock_sha256") != digest(HOTPATH_LOCK) or \
       _git_value(hotpath_root, "HEAD") != hotpath["published_source"]["main_commit"] or \
       _git_value(hotpath_root, "HEAD^{tree}") != hotpath["published_source"]["tree"] or \
       not _git_tracked_clean(hotpath_root):
        raise ProfileError("pinned published hotpath checkout differs from the Mac lock")
    expected_files = {name: digest(hotpath_root / name) for name in hotpath["runtime_files"]}
    for name, expected in hotpath["runtime_files"].items():
        path = hotpath_root / name
        if not path.is_file() or path.is_symlink() or digest(path) != expected:
            raise ProfileError("pinned Mac hotpath runtime byte changed: " + name)
    if receipt.get("hotpath_source_commit") != hotpath["published_source"]["main_commit"] or \
       receipt.get("hotpath_source_tree") != hotpath["published_source"]["tree"] or \
       receipt.get("hotpath_runtime_files") != expected_files:
        raise ProfileError("hotpath bootstrap source receipt is stale")


def _expected_proof_lock(root, marker):
    template = json.loads(PROOF_LOCK_TEMPLATE.read_text())
    proof = marker.get("proof_tools", {})
    source = lock()["proof_build_inputs"]
    why3 = root / "tools/opam-switch/_opam/bin/why3"
    plugin = root / "tools/opam-switch/_opam/lib/why3/commands/why3prove.cmxs"
    opam = root / "tools/opam/opam"
    ocamlc = root / "tools/opam-switch/_opam/bin/ocamlc"
    runtime_tree = root / "tools/opam-switch/_opam/lib/why3"
    generated = json.loads(json.dumps(template))
    generated["solver"]["executable_sha256"] = digest(root / "tools/z3/bin/z3")
    actual_artifacts = marker.get("moon", {}).get("toolchain_files", {})
    if set(actual_artifacts) < set(generated["artifact_sha256"]):
        raise ProfileError("profile receipt omits a required Moon proof artifact")
    generated["artifact_sha256"] = {name: actual_artifacts[name] for name in generated["artifact_sha256"]}
    export = generated["export_backend"]
    export["cli_sha256"] = digest(why3)
    export["prove_plugin_sha256"] = digest(plugin)
    export["moon_why3_datadir_sha256"] = tree_digest(root / "moon/share/why3")
    generated["profile_build_receipt"] = {
        "profile_lock_sha256": digest(LOCK_PATH), "profile": lock()["profile"],
        "profile_root": str(root), "host_identity": marker.get("installed_at_host"),
        "opam_repository_commit": source["opam_repository_commit"],
        "opam_repository_archive_sha256": digest(root / "downloads" /
            ("opam-repository-" + source["opam_repository_commit"] + ".tar.gz")),
        "opam_binary_sha256": digest(opam), "why3_source_archive_sha256": digest(root / "downloads" / Path(source["why3_source_url"]).name),
        "ocaml_version": run([str(ocamlc), "-version"]), "ocamlc_sha256": digest(ocamlc),
        "why3_version": run([str(why3), "--version"]), "why3_libdir": str(Path(run([str(why3), "--print-libdir"])).resolve(strict=True)),
        "why3_executable_sha256": digest(why3), "prove_plugin_path": str(plugin.resolve(strict=True)),
        "prove_plugin_sha256": digest(plugin), "why3_runtime_tree_sha256": tree_digest(runtime_tree),
    }
    return generated


def _write_proof_lock(root, marker):
    path = root / "tools/proof-toolchain.macos.lock.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(_expected_proof_lock(root, marker), indent=2) + "\n")


def _doctor_proof_lock(root, marker):
    path = root / "tools/proof-toolchain.macos.lock.json"
    if path.is_symlink() or not path.is_file() or json.loads(path.read_text()) != _expected_proof_lock(root, marker):
        raise ProfileError("generated per-profile proof lock differs from exact source/build inputs and runtime probes")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True,
                        help="dedicated external user-owned profile directory (HOME descendants are allowed; repository paths are not)")
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare = subparsers.add_parser("bootstrap", help="download and install exact pinned tools into the external profile")
    prepare.add_argument("--skip-proof", action="store_true", help="omit OPAM/Why3 setup; proof and quality modes will fail closed")
    doctor_parser = subparsers.add_parser("doctor", help="verify host, installed lock and tool bytes without modifying them")
    doctor_parser.add_argument("--allow-no-proof", action="store_true", help="permit a partial profile made with --skip-proof")
    environment_parser = subparsers.add_parser("environment", help="emit selected profile build environment as shell exports or JSON")
    environment_parser.add_argument("--format", choices=("shell", "json"), default="shell")
    args = parser.parse_args(argv)
    if args.command == "bootstrap":
        bootstrap(args.root, with_proof=not args.skip_proof)
    elif args.command == "doctor":
        doctor(args.root, require_proof=not args.allow_no_proof)
    else:
        environment = profile_environment(external_path(args.root))
        names = ("MOON_HOME", "PATH", "GPUI_MACOS_PROFILE_ROOT", "GPUI_MACOS_PROFILE_LOCK",
                 "GPUI_TURTLES_BIN", "GPUI_TURTLES_VERIFICATION_ROOT", "GPUI_TURTLES_SCHEMA3_BIN",
                 "GPUI_TURTLES_VERIFICATION_PROFILE", "GPUI_PROOF_WHY3", "GPUI_PROOF_SOLVER", "GPUI_PROOF_TOOLCHAIN_LOCK",
                 "GPUI_HOTPATH_ROOT", "DEVELOPER_DIR", "SDKROOT", "CC", "GPUI_MACOS_TEXT_CC",
                 "MACOSX_DEPLOYMENT_TARGET", "CPPFLAGS", "CFLAGS", "LDFLAGS", "CPATH",
                 "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "LIBRARY_PATH", "DYLD_LIBRARY_PATH")
        selected = {name: environment.get(name, "") for name in names}
        if args.format == "json":
            print(json.dumps(selected, sort_keys=True))
        else:
            import shlex
            for name, value in selected.items():
                print("export " + name + "=" + shlex.quote(value))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, ProfileError, subprocess.SubprocessError) as error:
        print("macos-profile: " + str(error), file=sys.stderr)
        sys.exit(1)
