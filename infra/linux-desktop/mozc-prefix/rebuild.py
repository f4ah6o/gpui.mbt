#!/usr/bin/env python3
"""Build a relocatable official Mozc IBus client; never launches the IME."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import time
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(command, **kwargs):
    return subprocess.run(list(map(str, command)), check=True, **kwargs)


def package_record(row):
    return {"filename": Path(row["Filename"]).name,
            "url": "https://deb.debian.org/debian/" + row["Filename"],
            "sha256": row["SHA256"], "size": int(row["Size"])}


def fetch(record, archive_dir, caches, offline):
    dest = archive_dir / record["filename"]
    if not dest.exists():
        for cache in caches:
            source = cache / record["filename"]
            if source.is_file() and sha256(source) == record["sha256"]:
                shutil.copyfile(source, dest)
                break
        else:
            if offline:
                raise RuntimeError("Missing verified offline archive: " + record["filename"])
            if not record["url"].startswith("https://deb.debian.org/debian/"):
                raise RuntimeError("Unapproved archive origin")
            partial = dest.with_name(dest.name + ".partial")
            run(["curl", "-fsSL", "--connect-timeout", "20", "--max-time", "120",
                 record["url"], "-o", partial])
            if sha256(partial) != record["sha256"]:
                raise RuntimeError("Archive checksum mismatch: " + record["filename"])
            partial.replace(dest)
    if dest.stat().st_size != record["size"] or sha256(dest) != record["sha256"]:
        raise RuntimeError("Archive lock mismatch: " + record["filename"])
    return dest


def validate_tar(path):
    with tarfile.open(path) as archive:
        for member in archive.getmembers():
            name = Path(member.name)
            if name.is_absolute() or ".." in name.parts:
                raise RuntimeError("Unsafe source archive entry")
            if member.issym() or member.islnk():
                target = Path(member.linkname)
                if target.is_absolute() or ".." in target.parts:
                    raise RuntimeError("Unsafe source archive link")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sdk-root", required=True, type=Path,
                        help="Already bootstrapped prefix from the locked desktop profile")
    parser.add_argument("--runtime-prefix", required=True, type=Path,
                        help="Absolute prefix containing the exact stock Mozc server and runtime libraries")
    parser.add_argument("--build-root", required=True, type=Path,
                        help="New, empty, writable isolated directory")
    parser.add_argument("--cache", action="append", default=[], type=Path)
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    started = time.monotonic()
    lock = json.loads((HERE / "build.lock.json").read_text())
    sdk_base, runtime, root = (p.resolve() for p in
                              (args.sdk_root, args.runtime_prefix, args.build_root))
    server = runtime / "usr/lib/mozc/mozc_server"
    if not server.is_file() or sha256(server) != lock["server_elf_sha256"]:
        raise RuntimeError("Expected the exact pinned stock server ELF at " + str(server))
    if not (sdk_base / "usr/include/glib-2.0/glib.h").is_file():
        raise RuntimeError("Desktop SDK is missing; bootstrap the base profile first")
    installed = sdk_base.parent / "installed.json"
    if not installed.is_file():
        raise RuntimeError("Missing base SDK installation manifest")
    actual = json.loads(installed.read_text())["profile"]["packages"]
    expected = lock["sdk_base_packages"]
    fields = lambda rows: sorted((p["name"], p["version"], p["sha256"]) for p in rows)
    if fields(actual) != fields(expected):
        raise RuntimeError("Base SDK package lock differs; review before rebuilding")
    if root.exists() and any(root.iterdir()):
        raise RuntimeError("Build root must be empty; existing artifacts are never overwritten")
    root.mkdir(parents=True, exist_ok=True)
    archives, source, sdk, output = (root / p for p in
                                     ("archives", "source", "build-prefix", "artifacts"))
    for path in (archives, source, sdk, output):
        path.mkdir()
    records = lock["sources"] + [package_record(p) for p in lock["extra_build_packages"]]
    total = sum(p["size"] for p in records)
    if total > 100_000_000:
        raise RuntimeError("Additional source/build archive budget exceeds 100 MB")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        paths = list(pool.map(lambda r: fetch(r, archives, args.cache, args.offline), records))
    for record in lock["sources"]:
        path = archives / record["filename"]
        if record["filename"].endswith(".orig.tar.xz"):
            validate_tar(path)
            run(["tar", "-xJf", path, "-C", source, "--strip-components=1"])
        elif record["filename"].endswith(".debian.tar.xz"):
            validate_tar(path)
            run(["tar", "-xJf", path, "-C", source])
    for line in (source / "debian/patches/series").read_text().splitlines():
        if line and not line.startswith("#"):
            run(["patch", "--batch", "--forward", "-p1", "-i",
                 source / "debian/patches" / line], cwd=source, stdout=subprocess.DEVNULL)
    patch = HERE / "0001-scope-gyp-to-ibus.patch"
    if sha256(patch) != lock["generator_scope_patch_sha256"]:
        raise RuntimeError("Generator-scope patch checksum mismatch")
    run(["patch", "--batch", "--forward", "-p1", "-i", patch], cwd=source)
    for name, expected_sha in lock["build_contract"]["security_source_sha256"].items():
        if sha256(source / name) != expected_sha:
            raise RuntimeError("Protected source checksum differs: " + name)
    run(["cp", "-a", str(sdk_base) + "/.", sdk])
    for row in lock["extra_build_packages"]:
        run(["dpkg-deb", "-x", archives / Path(row["Filename"]).name, sdk])
    env = os.environ.copy()
    lib = sdk / "usr/lib/x86_64-linux-gnu"
    env.update({"PATH": str(sdk / "usr/bin") + ":" + env["PATH"],
                "PYTHONPATH": str(source / "src") + ":" + str(sdk / "usr/lib/python3/dist-packages"),
                "PKG_CONFIG_SYSROOT_DIR": str(sdk),
                "PKG_CONFIG_LIBDIR": str(lib / "pkgconfig") + ":" + str(sdk / "usr/share/pkgconfig"),
                "CPATH": str(sdk / "usr/include") + ":" + str(sdk / "usr/include/x86_64-linux-gnu"),
                "LIBRARY_PATH": str(lib), "LD_LIBRARY_PATH": str(lib),
                "GYP_DEFINES": "use_libprotobuf=1 use_libabseil=1 "
                + "ibus_mozc_path=" + str(output / "ibus-engine-mozc") + " "
                + "ibus_mozc_icon_path=" + str(runtime / "usr/share/ibus-mozc/product_icon.png")})
    env.pop("PKG_CONFIG_PATH", None)
    configure = ["/usr/bin/python3", "build_mozc.py", "gyp",
                 "--gypdir=" + str(sdk / "usr/bin"), "--target_platform=Linux", "--noqt",
                 "--server_dir=" + str(runtime / "usr/lib/mozc"), "--verbose"]
    build = ["ninja", "-C", "out_linux/Release", "-j4", "ibus_mozc"]
    compile_started = time.monotonic()
    with (root / "build.log").open("w") as log:
        run(configure, cwd=source / "src", env=env, stdout=log, stderr=subprocess.STDOUT,
            timeout=120)
        run(build, cwd=source / "src", env=env, stdout=log, stderr=subprocess.STDOUT,
            timeout=lock["build_contract"]["timeout_seconds"])
    shutil.copy2(source / "src/out_linux/Release/ibus_mozc", output / "ibus-engine-mozc")
    shutil.copy2(source / "src/out_linux/Release/gen/unix/ibus/mozc.xml", output / "mozc.xml")
    doctor_env = os.environ.copy()
    doctor_env["LD_LIBRARY_PATH"] = str(runtime / "usr/lib/x86_64-linux-gnu")
    linkage = run(["ldd", output / "ibus-engine-mozc"], env=doctor_env,
                  capture_output=True, text=True)
    if "not found" in linkage.stdout:
        raise RuntimeError("Runtime linkage doctor failed")
    (root / "runtime-ldd.txt").write_text(linkage.stdout)
    result = {"schema_version": 1, "source_version": lock["source_version"],
              "recipe_lock_sha256": sha256(HERE / "build.lock.json"),
              "runtime_prefix": str(runtime),
              "compiled_server_directory": str(runtime / "usr/lib/mozc"),
              "completed_utc": datetime.now(timezone.utc).isoformat(),
              "elapsed_seconds": round(time.monotonic() - started, 2),
              "configure_build_seconds": round(time.monotonic() - compile_started, 2),
              "source_build_archive_bytes": total,
              "workspace_file_bytes": sum(p.lstat().st_size for p in root.rglob("*") if p.is_file() or p.is_symlink()),
              "engine": str(output / "ibus-engine-mozc"),
              "engine_sha256": sha256(output / "ibus-engine-mozc"),
              "registration_xml": str(output / "mozc.xml"),
              "registration_xml_sha256": sha256(output / "mozc.xml"),
              "stock_server": str(server), "stock_server_sha256": sha256(server),
              "candidate_window": "ibus", "renderer_built": False,
              "security_source_verified": True, "runtime_linkage_passed": True,
              "native_conversion_tested": False,
              "configure_command": configure, "build_command": build}
    (root / "build-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
