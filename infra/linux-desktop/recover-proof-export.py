#!/usr/bin/env python3
"""Recover the official Why3 source build in a fresh owned prefix. Never re-pin."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tarfile
import time


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, cwd, env, log, timeout):
    with log.open("x") as stream:
        stream.write("COMMAND " + json.dumps(args) + "\n")
        stream.flush()
        proc = subprocess.Popen(args, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = proc.wait(timeout=timeout)
            if code:
                raise RuntimeError(f"command failed ({code}): {log.name}")
        finally:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait(timeout=3)


def materialize(record, cache, archives, env, logs):
    name = record["filename"]
    target = archives / name
    cached = cache / name if cache else None
    if cached and cached.is_file() and digest(cached) == record["sha256"]:
        shutil.copyfile(cached, target)
    else:
        # Official registry cache is the same hash-locked Why3 source archive.
        url = record.get("registry_cache_url", record["url"])
        download = archives / (name + ".download")
        command(["curl", "--fail", "--location", "--max-time", "90", "--output", str(download), url],
                archives, env, logs / (name + "-download.log"), 95)
        if digest(download) != record["sha256"]:
            raise RuntimeError("archive hash mismatch: " + name)
        os.replace(download, target)
    if digest(target) != record["sha256"]:
        raise RuntimeError("archive hash mismatch before extraction: " + name)
    return target


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--archive-cache", type=Path)
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.jobs <= 8:
        parser.error("--jobs must be 1..8")
    destination = args.destination.resolve()
    if args.destination.is_symlink():
        parser.error("destination must not be a symlink")
    destination.mkdir(parents=True, exist_ok=False)
    here = Path(__file__).resolve().parents[2]
    lock_path = here / "testing/composition_proof/proof-recovery.lock.json"
    lock = json.loads(lock_path.read_text())
    cache = args.archive_cache.resolve() if args.archive_cache else None
    archives = destination / "archives"
    logs = destination / "logs"
    archives.mkdir()
    logs.mkdir()
    result = {"schema_version": 1, "status": "incomplete", "qualified": False,
              "lock_sha256": digest(lock_path), "note": "Recovered build never changes the reviewed proof runtime pin."}
    (destination / "recovery-result.json").write_text(json.dumps(result, indent=2) + "\n")
    started = time.monotonic()
    env = {key: value for key, value in os.environ.items() if not key.startswith("WHY3")}
    for key in ["LD_PRELOAD", "OCAMLLIB", "OCAMLPATH", "OCAMLFIND_CONF", "OCAMLFIND_LDCONF", "OCAMLPARAM", "CAML_LD_LIBRARY_PATH"]:
        env.pop(key, None)
    try:
        prefix = destination / "ocaml-prefix"
        prefix.mkdir()
        for package in lock["ocaml_packages"]:
            archive = materialize(package, cache, archives, env, logs)
            command(["dpkg-deb", "--extract", str(archive), str(prefix)], destination, env,
                    logs / (package["name"] + "-extract.log"), 30)
        source_archive = materialize(lock["why3_source"], cache, archives, env, logs)
        # Hash verification above is mandatory before reading or extracting.
        with tarfile.open(source_archive, "r:gz") as archive:
            archive.extractall(destination, filter="data")
        source = destination / "why3-1.7.2"
        stdlib = prefix / "usr/lib/x86_64-linux-gnu/ocaml/5.3.0"
        local_config = destination / "ocamlfind-local.conf"
        local_ldconf = destination / "ocamlfind-local.ld.conf"
        local_ldconf.write_text(str(stdlib / "stublibs") + "\n")
        local_config.write_text(f'destdir="{stdlib}"\npath="{stdlib}"\nstdlib="{stdlib}"\nldconf="{local_ldconf}"\n')
        env.update(OCAMLLIB=str(stdlib), OCAMLPATH=str(stdlib), OCAMLFIND_CONF=str(local_config),
                   OCAMLFIND_LDCONF=str(local_ldconf), OCAMLPARAM=lock["ocamlparam"],
                   CAML_LD_LIBRARY_PATH=str(stdlib / "stublibs"))
        env["PATH"] = str(prefix / "usr/bin") + ":" + env.get("PATH", os.defpath)
        why3_prefix = destination / "why3-prefix"
        command(["./configure", "--prefix=" + str(why3_prefix), *lock["configure_flags"]], source, env,
                logs / "configure.log", 60)
        command(["make", "-j" + str(args.jobs), "all"], source, env, logs / "build.log", 300)
        # Avoid upstream `make install`, which also has optional /etc completion targets.
        command(["make", *lock["install_targets"]], source, env, logs / "install.log", 60)
        why3 = why3_prefix / "bin/why3"
        command([str(why3), "--version"], destination, env, logs / "version.log", 10)
        command([str(why3), "--print-libdir"], destination, env, logs / "compiled-libdir.log", 10)
        plugin = why3_prefix / "lib/why3/commands/why3prove.cmxs"
        observed = {"cli_sha256": digest(why3), "prove_plugin_sha256": digest(plugin)}
        reviewed = json.loads((here / "testing/composition_proof/proof-toolchain.lock.json").read_text())["export_backend"]
        result.update(status="built-unqualified", runtime=observed,
                      matches_reviewed_binary=all(observed[key] == reviewed[key] for key in observed),
                      why3=str(why3), compiled_libdir=str(plugin.parent.parent))
    except BaseException as error:
        result.update(status="failed", reason=str(error) or type(error).__name__)
    result["seconds"] = round(time.monotonic() - started, 6)
    (destination / "recovery-result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))
    return 0 if result["status"] == "built-unqualified" else 2


if __name__ == "__main__":
    raise SystemExit(main())
