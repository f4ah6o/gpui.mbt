#!/usr/bin/env python3
"""Prepare exact candidate bytes outside the repo; semantic cases stay reusable.
Built candidates consume the checked build manifest. Explicit bound candidates
capture an executable/source association without asserting compilation origin.
No display connection, app launch, input injection or golden generation occurs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys

import build_manifest

VERSION = 1
MAX_MANIFEST_BYTES = 32 * 1024 * 1024
FILES = {"app", "tracked-source.patch", "fonts.conf", "build-manifest.json"}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode("utf-8")


def unique_object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise RuntimeError("duplicate manifest field: " + key)
        value[key] = item
    return value


def load_json(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_MANIFEST_BYTES:
        raise RuntimeError("manifest must be a bounded regular file: " + str(path))
    return json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object,
                      parse_constant=lambda value: (_ for _ in ()).throw(RuntimeError("non-finite manifest value: " + value)))


def fields(value, expected, where):
    if not isinstance(value, dict) or set(value) != set(expected):
        raise RuntimeError("invalid " + where + " fields")


def sha(value, where):
    if not isinstance(value, str) or len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise RuntimeError("invalid " + where + " SHA-256")


def regular_copy(source, destination, executable=False):
    source = Path(source)
    if not source.is_file():
        raise RuntimeError("missing candidate input: " + str(source))
    shutil.copyfile(source, destination)
    destination.chmod(0o500 if executable else 0o400)
    return {"file": destination.name, "sha256": digest(destination), "size": destination.stat().st_size}


def live_source(record, patch):
    source = dict(record)
    source["tracked_patch_utf8"] = patch.read_text(encoding="utf-8")
    return source


def verify_file(bundle, record, name):
    fields(record, {"file", "sha256", "size"}, name)
    if record["file"] != name or name not in FILES:
        raise RuntimeError("invalid candidate filename: " + str(record["file"]))
    sha(record["sha256"], name)
    if type(record["size"]) is not int or record["size"] < 0:
        raise RuntimeError("invalid candidate file size")
    path = bundle / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size != record["size"] or digest(path) != record["sha256"]:
        raise RuntimeError("changed candidate file: " + name)
    return path


def verify_candidate(bundle):
    """Recheck every recorded identity before any OS input; import-safe API."""
    bundle = Path(bundle).expanduser().resolve()
    manifest_path = bundle / "manifest.json"
    seal = bundle / "manifest.sha256"
    if seal.is_symlink() or not seal.is_file():
        raise RuntimeError("missing candidate manifest identity")
    expected_manifest = seal.read_text().strip()
    sha(expected_manifest, "manifest")
    if digest(manifest_path) != expected_manifest:
        raise RuntimeError("changed candidate manifest")
    manifest = load_json(manifest_path)
    fields(manifest, {"version", "kind", "mode", "source", "source_claim", "runtime", "binary",
                      "tracked_patch", "fontconfig_snapshot", "build_manifest"}, "candidate manifest")
    if type(manifest["version"]) is not int or manifest["version"] != VERSION or manifest["kind"] != "gpui-input-candidate":
        raise RuntimeError("unsupported candidate manifest version/kind")
    if manifest["mode"] not in {"built", "bound"} or not isinstance(manifest["source_claim"], str):
        raise RuntimeError("invalid candidate provenance mode")
    source = manifest["source"]
    fields(source, {"repo", "head", "tree", "tracked_patch_sha256", "status", "untracked_files"}, "candidate source")
    app = verify_file(bundle, manifest["binary"], "app")
    if not os.access(app, os.X_OK):
        raise RuntimeError("candidate app is not executable")
    patch = verify_file(bundle, manifest["tracked_patch"], "tracked-source.patch")
    config = verify_file(bundle, manifest["fontconfig_snapshot"], "fonts.conf")
    build_path = verify_file(bundle, manifest["build_manifest"], "build-manifest.json")
    captured = load_json(build_path)
    fields(captured, {"version", "kind", "mode", "source", "source_consistent", "binary", "runtime", "command", "source_claim"}, "build snapshot")
    if type(captured["version"]) is not int or captured.get("version") != 1 or captured.get("kind") != "gpui-field-build" or captured.get("mode") != manifest["mode"]:
        raise RuntimeError("candidate/build provenance mismatch")
    if captured.get("runtime") != manifest["runtime"] or captured.get("source") != live_source(source, patch):
        raise RuntimeError("candidate/build snapshot mismatch")
    if captured.get("binary", {}).get("sha256") != manifest["binary"]["sha256"] or captured.get("binary", {}).get("size") != manifest["binary"]["size"]:
        raise RuntimeError("candidate/build app mismatch")
    if manifest["mode"] == "built" and captured.get("source_consistent") is not True:
        raise RuntimeError("built candidate has no consistent build source evidence")
    if manifest["source_claim"] != captured.get("source_claim"):
        raise RuntimeError("candidate source claim changed")
    if digest(patch) != source["tracked_patch_sha256"]:
        raise RuntimeError("candidate tracked source patch mismatch")
    if build_manifest.capture_source(Path(source["repo"])) != live_source(source, patch):
        raise RuntimeError("source changed since candidate preparation")
    runtime = manifest["runtime"]
    build_manifest.verify_runtime(runtime)
    live_config = Path(runtime["fontconfig"])
    if digest(config) != digest(live_config):
        raise RuntimeError("candidate fontconfig snapshot differs from verified live config")
    # Use the live config's original base for relative Fontconfig paths.
    return manifest, {"repo": Path(source["repo"]), "prefix": Path(runtime["prefix"]),
                      "app": app, "app_sha256": manifest["binary"]["sha256"], "fontconfig": live_config}


def outside_repo(output, repo):
    output, repo = Path(output).expanduser().resolve(), Path(repo).resolve()
    if output == repo or repo in output.parents:
        raise RuntimeError("candidate bundles must stay outside the repository")
    if output.exists():
        raise RuntimeError("candidate output must be a fresh directory")
    return output


def prepare_manifest(captured, output, original_bytes=None):
    """Freeze checked build/bind bytes, never mutate a case or existing bundle."""
    source = captured["source"]
    if build_manifest.capture_source(Path(source["repo"])) != source:
        raise RuntimeError("source changed before candidate preparation")
    build_manifest.verify_runtime(captured["runtime"])
    binary = Path(captured["binary"]["path"])
    if digest(binary) != captured["binary"]["sha256"] or binary.stat().st_size != captured["binary"]["size"]:
        raise RuntimeError("build executable changed before candidate preparation")
    if not os.access(binary, os.X_OK):
        raise RuntimeError("build executable is not executable")
    output = outside_repo(output, source["repo"])
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Failed preparation remains a new directory; it never becomes a valid seal.
    app_record = regular_copy(binary, output / "app", executable=True)
    (output / "tracked-source.patch").write_text(source["tracked_patch_utf8"], encoding="utf-8")
    (output / "tracked-source.patch").chmod(0o400)
    patch_record = {"file": "tracked-source.patch", "sha256": digest(output / "tracked-source.patch"), "size": (output / "tracked-source.patch").stat().st_size}
    config_record = regular_copy(Path(captured["runtime"]["fontconfig"]), output / "fonts.conf")
    (output / "build-manifest.json").write_bytes(original_bytes if original_bytes is not None else encoded(captured))
    (output / "build-manifest.json").chmod(0o400)
    build_record = {"file": "build-manifest.json", "sha256": digest(output / "build-manifest.json"), "size": (output / "build-manifest.json").stat().st_size}
    copied_source = dict(source)
    del copied_source["tracked_patch_utf8"]
    manifest = {"version": VERSION, "kind": "gpui-input-candidate", "mode": captured["mode"],
                "source": copied_source, "source_claim": captured.get("source_claim", "source snapshot was unchanged around the recorded native build command"),
                "runtime": captured["runtime"], "binary": app_record, "tracked_patch": patch_record,
                "fontconfig_snapshot": config_record, "build_manifest": build_record}
    # Recheck source/runtime and source→copied bytes after copying to close races.
    if app_record["sha256"] != captured["binary"]["sha256"] or patch_record["sha256"] != source["tracked_patch_sha256"]:
        raise RuntimeError("candidate bytes changed during preparation")
    if build_manifest.capture_source(Path(source["repo"])) != source:
        raise RuntimeError("source changed during candidate preparation")
    build_manifest.verify_runtime(captured["runtime"])
    if digest(Path(captured["runtime"]["fontconfig"])) != config_record["sha256"]:
        raise RuntimeError("fontconfig changed during preparation")
    (output / "manifest.json").write_bytes(encoded(manifest))
    (output / "manifest.json").chmod(0o400)
    (output / "manifest.sha256").write_text(digest(output / "manifest.json") + "\n")
    (output / "manifest.sha256").chmod(0o400)
    verify_candidate(output)
    return manifest


def prepare_from_build(path, output):
    path = Path(path).expanduser().resolve()
    captured = build_manifest.verify_build_manifest(path)
    return prepare_manifest(captured, output, path.read_bytes())


def bound_environment(profile_root, fontconfig):
    env = os.environ.copy()
    lib = profile_root / "prefix/usr/lib/x86_64-linux-gnu"
    env.update(PATH=f"{profile_root / 'moon/bin'}:{profile_root / 'prefix/usr/bin'}:" + env.get("PATH", ""),
               LD_LIBRARY_PATH=f"{lib}:{lib / 'weston'}" + (":" + env["LD_LIBRARY_PATH"] if env.get("LD_LIBRARY_PATH") else ""),
               FONTCONFIG_FILE=str(fontconfig), FONTCONFIG_PATH=str(fontconfig.parent))
    return env


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    prepare = actions.add_parser("prepare")
    prepare.add_argument("--build-manifest", type=Path)
    prepare.add_argument("--profile-root", type=Path)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--bind-app", type=Path, help="explicit captured artifact; does not assert it was compiled from this source")
    prepare.add_argument("--repo", type=Path)
    prepare.add_argument("--fontconfig", type=Path)
    verify = actions.add_parser("verify")
    verify.add_argument("candidate", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.action == "verify":
            manifest, runtime = verify_candidate(args.candidate)
            print(json.dumps({"status": "verified", "mode": manifest["mode"], "manifest_sha256": digest(args.candidate / "manifest.json"), "app_sha256": runtime["app_sha256"]}))
            return 0
        if args.bind_app:
            if args.build_manifest or not args.repo or not args.profile_root:
                raise RuntimeError("--bind-app requires --repo/--profile-root and cannot claim --build-manifest")
            repo, profile = args.repo.resolve(), args.profile_root.resolve()
            config = (args.fontconfig or profile / "config/fonts.conf").resolve()
            runtime = build_manifest.capture_runtime(profile, config, bound_environment(profile, config), repo)
            captured = build_manifest.make_bound_manifest(repo, args.bind_app.resolve(), runtime)
            manifest = prepare_manifest(captured, args.output)
        else:
            if args.repo or args.fontconfig:
                raise RuntimeError("built preparation consumes recorded source/fonts; do not override them")
            path = args.build_manifest or (args.profile_root / "field-build.json" if args.profile_root else None)
            if path is None:
                raise RuntimeError("prepare requires --build-manifest or --profile-root")
            manifest = prepare_from_build(path, args.output)
        print(json.dumps({"status": "prepared", "candidate": str(args.output.resolve()), "mode": manifest["mode"],
                          "manifest_sha256": digest(args.output / "manifest.json"), "app_sha256": manifest["binary"]["sha256"]}, ensure_ascii=False))
        return 0
    except (OSError, ValueError, RuntimeError) as error:
        parser.exit(2, str(error) + "\n")


if __name__ == "__main__":
    sys.exit(main())
