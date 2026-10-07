"""Fail-closed contract tests for local Mac quality evidence."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib
from unittest import mock

HERE = Path(__file__).resolve().parents[1]
REPO = HERE.parents[1]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


profile = load("test_macos_quality_profile", "profile.py")
acceptance = load("test_macos_ime_acceptance", "ime-acceptance.py")
runner = load("test_macos_actrun", "actrun-feedback.py")
hotpath = load("test_macos_hotpath", "input-hotpath.py")
stage = load("test_macos_stage", "stage.py")
verification = load("test_macos_verification", "turtles-verification.py")


def valid_final():
    source = {"commit": "a" * 40, "tree": "b" * 40}
    binary = "c" * 64
    input_source = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
    host, initial_epoch = 11, 7
    batches = []
    for index, (sequence, counts) in enumerate(zip((4, 7, 8, 9, 10),
                                                    ((1, 0, 0), (0, 1, 0), (1, 0, 0),
                                                     (0, 0, 1), (0, 0, 0))), 1):
        digest = format(index, "064x")
        identity = {"schema_version": 1, "window_id": 3, "host_epoch": host,
                    "session_epoch": initial_epoch, "batch_sequence": sequence,
                    "accepted_revision": 12, "frame_revision": sequence + 20,
                    "frame_sha256": digest, "text": "Hello 日本語"}
        batches.append({"sequence": sequence, "owner_revision": 8 if index == 1 else 12, "epoch": initial_epoch,
                        "accepted_revision": 12, "acknowledged": True,
                        "preedit_callbacks": counts[0], "commit_callbacks": counts[1],
                        "cancel_callbacks": counts[2], "frame_identity": identity,
                        "candidate_screen_rect": {"x": 10, "y": 20, "width": 100, "height": 22}})
    receipts = []
    for index, key in enumerate(acceptance.EXPECTED_KEYS, 1):
        batch_sequence = 0 if index == 1 else 4 if index < 10 else 8
        window_sequence = index * 2
        if index == 9:
            window_sequence = receipts[-1]["window_sequence"]
        receipts.append({"schema_version": 1, "dispatch_id": index, "key_code": key,
                         "down_posted": True, "up_posted": True, "down_dispatched": True,
                         "up_dispatched": True, "host_epoch": host, "session_epoch": initial_epoch,
                         "batch_sequence": batch_sequence, "window_sequence": window_sequence})
    operations = [
        {"schema_version": 2, "operation_id": 1, "kind": "return_commit_observation",
         "scope": "serial_post_dispatch_observation", "causal_origin": "unknown",
         "origin_dispatch_id": None, "dispatch_id": 9, "key_code": 36,
         "dispatch_receipt_index": 8, "window_id": 3, "host_epoch": host,
         "session_epoch": initial_epoch, "baseline_batch_index": 1,
         "baseline_batch_sequence": 4, "baseline_accepted_revision": 12,
         "baseline_frame_revision": 24, "baseline_preedit_callbacks": 1,
         "baseline_commit_callbacks": 0, "baseline_cancel_callbacks": 0,
         "baseline_composing": True, "baseline_frame_identity": copy.deepcopy(batches[0]["frame_identity"]),
         "loop_iterations": 3, "effect_index": 0, "release_kind": None,
         "release_key_code": None, "release_batch_index": None,
         "release_batch_sequence": None, "release_frame_revision": None,
         "release_geometry_revision": None},
        {"schema_version": 2, "operation_id": 2, "kind": "escape_cancel_observation",
         "scope": "serial_post_dispatch_observation", "causal_origin": "unknown",
         "origin_dispatch_id": None, "dispatch_id": 11, "key_code": 53,
         "dispatch_receipt_index": 10, "window_id": 3, "host_epoch": host,
         "session_epoch": initial_epoch, "baseline_batch_index": 3,
         "baseline_batch_sequence": 8, "baseline_accepted_revision": 12,
         "baseline_frame_revision": 28, "baseline_preedit_callbacks": 2,
         "baseline_commit_callbacks": 1, "baseline_cancel_callbacks": 0,
         "baseline_composing": True, "baseline_frame_identity": copy.deepcopy(batches[2]["frame_identity"]),
         "loop_iterations": 4, "effect_index": 1,
         "release_kind": "forwarded_escape_release", "release_key_code": 53,
         "release_batch_index": 4, "release_batch_sequence": 10,
         "release_frame_revision": 30, "release_geometry_revision": None},
    ]
    effect_observations = [
        {"schema_version": 1, "operation_id": 1, "kind": "commit",
         "causal_origin": "unknown", "origin_dispatch_id": None,
         "batch_index": 1, "batch_sequence": 7, "window_id": 3,
         "host_epoch": host, "session_epoch": initial_epoch,
         "owner_revision": 12, "accepted_revision": 12, "frame_revision": 27,
         "preedit_callback_delta": 0, "commit_callback_delta": 1,
         "cancel_callback_delta": 0, "frame_identity": copy.deepcopy(batches[1]["frame_identity"])},
        {"schema_version": 1, "operation_id": 2, "kind": "cancel",
         "causal_origin": "unknown", "origin_dispatch_id": None,
         "batch_index": 3, "batch_sequence": 9, "window_id": 3,
         "host_epoch": host, "session_epoch": initial_epoch,
         "owner_revision": 12, "accepted_revision": 12, "frame_revision": 29,
         "preedit_callback_delta": 0, "commit_callback_delta": 0,
         "cancel_callback_delta": 1, "frame_identity": copy.deepcopy(batches[3]["frame_identity"])},
    ]
    final_identity = {"schema_version": 1, "window_id": 3, "host_epoch": host,
                      "session_epoch": 0, "batch_sequence": 10, "accepted_revision": 12,
                      "frame_revision": 40, "frame_sha256": "d" * 64, "text": "Hello 日本語"}
    report = {"schema_version": 2, "window_id": 3, "host_epoch": host,
              "session_epoch": initial_epoch, "final_session_epoch": 0,
              "input_source": input_source, "preedit_callbacks": 2, "commit_callbacks": 1,
              "cancel_callbacks": 1, "committed_text": "Hello 日本語", "composing": False,
              "focused": False, "commit_count": 1, "batches": batches, "receipts": receipts,
              "operations": operations, "effect_observations": effect_observations,
              "candidate_screen_rect": {"x": 10, "y": 20, "width": 100, "height": 22},
              "final_frame_identity": final_identity, "final_frame_revision": 40,
              "field_bounds": {"x": 24, "y": 40, "width": 512, "height": 48},
              "source_revision": source["commit"], "source_tree": source["tree"],
              "binary_sha256": binary}
    return report, source, binary


def make_png(path, rgba, width=640, height=272):
    raw = b"".join(b"\x00" + bytes(rgba) * width for _ in range(height))
    def chunk(kind, value):
        body = kind + value
        return len(value).to_bytes(4, "big") + body + (zlib.crc32(body) & 0xffffffff).to_bytes(4, "big")
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)) + \
           chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    path.write_bytes(data)


def successful_ime_summary(directory, repo):
    directory = directory.resolve(strict=True)
    source = acceptance.source_snapshot(repo)
    input_source = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
    final, _, binary_sha = valid_final()
    app_bundle = directory / "checks/text-field/build/macos/GpuiTextField.app"
    executable = app_bundle / "Contents/MacOS/GpuiTextField"
    library = app_bundle / "Contents/Frameworks/libgpui_macos.dylib"
    plist = app_bundle / "Contents/Info.plist"
    executable.parent.mkdir(parents=True)
    library.parent.mkdir(parents=True)
    executable.write_bytes(b"test app binary")
    library.write_bytes(b"test app library")
    plist.write_bytes(b"test app plist")
    actual_binary = hashlib.sha256(executable.read_bytes()).hexdigest()
    final["binary_sha256"] = actual_binary
    final["source_revision"] = source["commit"]
    final["source_tree"] = source["tree"]
    (directory / "owned-window-capture").write_bytes(b"test helper bytes")
    helper_source = directory / "owned-window-capture.swift"
    helper_source.write_text(acceptance.SWIFT_WINDOW_CAPTURE)

    initial_identity = {"schema_version": 1, "window_id": 3, "host_epoch": 11, "session_epoch": 7,
                        "batch_sequence": 0, "accepted_revision": 8, "frame_revision": 10,
                        "frame_sha256": "a" * 64, "text": "Hello "}
    initial_state = {"version": 1, "presentation": 1, "text": "Hello ", "committed": "Hello ",
                     "selection": {"anchor": 6, "head": 6}, "focused": True, "revision": 8,
                     "composing": False, "marked": None, "caret": {"x": 30, "y": 20, "width": 1, "height": 20},
                     "session_epoch": 7, "commit_count": 0, "source_revision": source["commit"],
                     "source_tree": source["tree"], "binary_sha256": actual_binary,
                     "field_bounds": {"x": 24, "y": 40, "width": 512, "height": 48}}
    window_geometry = {"schema_version": 1, "window_key": True, "app_key_matches": True,
                       "window_id": 3, "host_epoch": 11, "native_window_id": 99,
                       "first_responder_is_content_view": True, "first_responder_class": "GPView",
                       "content_view_class": "GPView", "window_visible": True, "session_active": True,
                       "direct_text": False, "session_epoch": 7,
                       "selected_input_source": "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
                       "coordinate_space": "top_left_window_points", "content_origin_in_window": {"x": 0, "y": 32},
                       "content_size": {"width": 640, "height": 240},
                       "window_size": {"width": 640, "height": 272}}
    initial_checkpoint = {"schema_version": 1, "phase": "initial-ready", "input_source": input_source,
                          "text": "Hello ", "field_revision": 8, "session_epoch": 7,
                          "frame_identity": initial_identity, "source_revision": source["commit"],
                          "source_tree": source["tree"], "binary_sha256": actual_binary,
                          "field_bounds": initial_state["field_bounds"], "window_geometry": window_geometry}
    comp_identity = copy.deepcopy(final["batches"][0]["frame_identity"])
    composition = {"schema_version": 1, "phase": "composition-ready", "input_source": input_source,
                   "text": "Hello 日本語", "committed": "Hello ", "field_revision": 12,
                   "session_epoch": 7, "composing": True, "marked": {"start": 6, "end": 9},
                   "caret": {"x": 50, "y": 20, "width": 1, "height": 20},
                   "candidate_screen_rect": final["candidate_screen_rect"], "frame_identity": comp_identity,
                   "source_revision": source["commit"], "source_tree": source["tree"],
                   "binary_sha256": actual_binary, "field_bounds": initial_state["field_bounds"]}
    files = {}
    for index, name in enumerate(("initial", "composition", "final")):
        image_path = directory / (name + "-window.png")
        make_png(image_path, ((255, 255, 255, 255), (0, 0, 0, 255), (240, 32, 64, 255))[index])
        decoded = acceptance.png_pixels(image_path)
        identity = {"initial": initial_identity, "composition": comp_identity,
                    "final": final["final_frame_identity"]}[name]
        rect = {"x": 0, "y": 0, "width": 640, "height": 272}
        scale = 1.0
        caret = (initial_state["caret"] if name == "initial" else composition["caret"] if name == "composition" else None)
        roi = acceptance.prepare_text_roi(decoded, rect, scale, initial_state["field_bounds"], caret, {"x": 0, "y": 32})
        files[name] = {"path": image_path.name, "window_id": 99, "owner_pid": 123, "title": acceptance.APP_TITLE,
                       "capture_engine": "ScreenCaptureKit.SCScreenshotManager", "width": decoded["width"],
                       "height": decoded["height"], "file_sha256": decoded["file_sha256"],
                       "pixel_sha256": decoded["pixel_sha256"], "frame_identity": identity,
                       "file_size": decoded["file_size"], "png_encoding": decoded["png_encoding"],
                       "capture_command": "ScreenCaptureKit SCScreenshotManager.captureImage(desktopIndependentWindow)",
                       "content_rect": rect, "point_pixel_scale": scale, "shadows_ignored": True,
                       "cursor_excluded": True, "child_windows_included": False,
                       "window_frame": {"width": 640, "height": 272}, "window_geometry": window_geometry,
                       "capture_region": "window", "content_offset": {"x": 0, "y": 32},
                       "field_bounds": initial_state["field_bounds"], "caret": caret, "text_roi": roi}
        files[name]["decoded"] = decoded
    differences = {"initial_to_composition": acceptance.pixel_difference(files["initial"]["decoded"], files["composition"]["decoded"]),
                   "composition_to_final": acceptance.pixel_difference(files["composition"]["decoded"], files["final"]["decoded"]),
                   "initial_to_final": acceptance.pixel_difference(files["initial"]["decoded"], files["final"]["decoded"])}
    roi_frames = {name: {"image": row["decoded"], "roi": row["text_roi"]} for name, row in files.items()}
    text_differences = {
        "initial_to_composition": acceptance.text_roi_difference(roi_frames["initial"], roi_frames["composition"]),
        "composition_to_final": acceptance.text_roi_difference(roi_frames["composition"], roi_frames["final"]),
        "initial_to_final": acceptance.text_roi_difference(roi_frames["initial"], roi_frames["final"]),
    }
    screenshots = {name: {key: value for key, value in row.items() if key != "decoded"}
                   for name, row in files.items()}
    index = {name: dict(row) for name, row in screenshots.items()}
    index_path = directory / "screenshots-index.json"
    index_path.write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n")
    log_records = ["GPUI_FIELD_MACOS_STATE " + json.dumps(initial_state),
                   "GPUI_MACOS_IME_CHECKPOINT " + json.dumps(initial_checkpoint),
                   "GPUI_MACOS_IME_CHECKPOINT " + json.dumps(composition),
                   "GPUI_MACOS_IME_ACCEPTANCE " + json.dumps(final)]
    (directory / "app.stdout.log").write_text("\n".join(log_records) + "\n")
    helper_path = directory / "owned-window-capture"
    profile_root = Path("/private/tmp/gpui-macos-quality-profile").resolve(strict=True)
    host = profile.host_identity()
    compile_environment = {"DEVELOPER_DIR": host["xcode_select_path"], "SDKROOT": host["sdk_path"],
                           "MACOSX_DEPLOYMENT_TARGET": "26.0"}
    swift_env = dict(os.environ)
    swift_env.update(compile_environment)
    swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True, env=swift_env).strip())
    swiftc_resolved = swiftc.resolve(strict=True)
    swiftc_version = subprocess.check_output([str(swiftc), "-version"], text=True, env=swift_env).strip()
    return {"schema_version": 1, "scope": "logged-in desktop, native Kotoeri callback and app-window pixels",
            "status": "passed", "ok": True, "app_exit_code": 0, "source_before": source,
            "source_after": source, "source_stable": True, "host": host, "app_pid": 123,
            "profile_root": str(profile_root),
            "app": {"bundle": str(app_bundle), "binary_sha256": actual_binary,
                    "library_sha256": hashlib.sha256(library.read_bytes()).hexdigest(),
                    "binary_path": str(executable.resolve()),
                    "info_plist_sha256": hashlib.sha256(plist.read_bytes()).hexdigest(),
                    "window_title": acceptance.APP_TITLE},
            "capture_runtime": {"swiftc": str(swiftc),
                    "swiftc_resolved": str(swiftc_resolved),
                    "swiftc_sha256": hashlib.sha256(swiftc_resolved.read_bytes()).hexdigest(),
                    "swiftc_version": swiftc_version, "compile_environment": compile_environment,
                    "helper_sha256": hashlib.sha256(helper_path.read_bytes()).hexdigest(),
                    "helper_compile_argv": [str(swiftc), "-parse-as-library", "-framework", "AppKit",
                                            "-framework", "ScreenCaptureKit", "-framework", "ImageIO",
                                            str(helper_source), "-o", str(helper_path)],
                    "engine": "ScreenCaptureKit.SCScreenshotManager",
                    "helper_source_sha256": hashlib.sha256(helper_source.read_bytes()).hexdigest()},
            "initial_state": initial_state, "initial_checkpoint": initial_checkpoint,
            "input_source": input_source,
            "composition_checkpoint": composition,
            "final_acceptance": final, "screenshots": screenshots, "pixel_differences": differences,
            "text_roi_differences": text_differences,
            "screenshots_index": index_path.name, "screenshots_index_sha256": hashlib.sha256(index_path.read_bytes()).hexdigest()}


class ProfileReceiptTests(unittest.TestCase):
    def test_prelude_receipt_migration_adds_only_reviewed_artifact(self):
        previous = {"bin/moon": "1" * 64, "tree/core_sources": "2" * 64}
        actual = {**previous, profile.PRELUDE_MI: profile.PRELUDE_MI_SHA256}
        self.assertEqual(profile._migrate_prelude_receipt(previous, actual), actual)

    def test_prelude_migration_rejects_tamper_old_changes_and_extra_scope(self):
        previous = {"bin/moon": "1" * 64}
        valid = {**previous, profile.PRELUDE_MI: profile.PRELUDE_MI_SHA256}
        for actual in (
            {**previous, profile.PRELUDE_MI: "e" * 64},
            {"bin/moon": "f" * 64, profile.PRELUDE_MI: profile.PRELUDE_MI_SHA256},
            {**valid, "other": "a" * 64},
        ):
            with self.subTest(actual=actual), self.assertRaises(profile.ProfileError):
                profile._migrate_prelude_receipt(previous, actual)

    def test_template_and_migration_share_the_reviewed_hash(self):
        template = json.loads((HERE / "proof-toolchain.macos.lock.template.json").read_text())
        self.assertEqual(template["artifact_sha256"][profile.PRELUDE_MI], profile.PRELUDE_MI_SHA256)

    def test_dedicated_home_profile_is_allowed_but_repository_and_home_root_are_not(self):
        root = Path.home() / ".cache" / "codex-tests" / "dedicated-profile"
        self.assertEqual(profile.external_path(root), root.resolve())
        for path in (Path.home(), REPO, REPO / "nested", Path("/")):
            with self.subTest(path=path), self.assertRaises(profile.ProfileError):
                profile.external_path(path)


class ActrunInventoryTests(unittest.TestCase):
    def test_sigterm_grace_covers_bounded_ime_restoration_handshake(self):
        self.assertGreaterEqual(stage.TERM_GRACE_SECONDS, 15)

    def test_generated_native_workflow_uses_nonlogin_bash_and_synthetic_gate(self):
        text = runner.workflow_text("native")
        self.assertIn("/bin/bash -c", text)
        self.assertNotIn("sh -lc", text)
        self.assertIn("check-all-targets", [row[0] for row in runner.FAST])
        self.assertIn("--target all --deny-warn", text)
        self.assertIn("script/test_macos.sh all", text)
        self.assertIn("ime-acceptance.py", text)
        self.assertIn("macos-local:", text)

    def test_missing_task_is_failed_not_green(self):
        with tempfile.TemporaryDirectory(prefix="gpui-actrun-inventory-") as temp:
            root = Path(temp)
            (root / "runs/run-1").mkdir(parents=True)
            run = {"tasks": [{"id": "macos-local/repo-tests", "status": "success", "code": 0},
                              {"id": "macos-local/__finish", "status": "success", "code": 0}],
                   "steps": [{"id": "macos-local/repo-tests", "status": "success"},
                             {"id": "macos-local/format", "status": "skipped"},
                             {"id": "macos-local/__finish", "status": "success"}]}
            (root / "runs/run-1/run.json").write_text(json.dumps(run))
            stages = [("repo-tests", "repo tests", 60, ""), ("format", "format", 60, "")]
            _, _, coverage = runner.stage_status(root, stages)
            self.assertEqual([row["status"] for row in coverage], ["passed", "failed"])

    def test_failed_actrun_stage_keeps_failed_coverage_when_finish_is_blocked(self):
        with tempfile.TemporaryDirectory(prefix="gpui-actrun-failed-stage-") as temp:
            root = Path(temp)
            (root / "runs/run-1").mkdir(parents=True)
            run = {"ok": False,
                   "tasks": [{"id": "macos-local/proof", "status": "failed", "code": 2}],
                   "steps": [{"id": "macos-local/proof", "status": "failed"},
                             {"id": "macos-local/__finish", "status": "blocked"}]}
            (root / "runs/run-1/run.json").write_text(json.dumps(run))
            _, _, coverage = runner.stage_status(root, [("proof", "five-goal proof", 60, "")])
            self.assertEqual([row["status"] for row in coverage], ["failed"])

    def test_only_generated_local_workflow_is_excluded_from_git_source_inventories(self):
        with tempfile.TemporaryDirectory(prefix="gpui-source-exclusion-") as temp:
            root = Path(temp) / "repo"
            output = Path(temp) / "run"
            root.mkdir()
            output.mkdir()
            subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
            (root / "tracked.txt").write_text("base\n")
            (root / ".gitignore").write_text(".github/workflows/_local-actrun-feedback-*.yml\n")
            subprocess.run(["git", "-c", "user.name=quality", "-c", "user.email=quality@local", "add", "tracked.txt", ".gitignore"], cwd=root, check=True)
            subprocess.run(["git", "-c", "user.name=quality", "-c", "user.email=quality@local", "commit", "--quiet", "-m", "base"], cwd=root, check=True)
            workflow = root / ".github" / "workflows" / ("_local-actrun-feedback-" + "a" * 32 + ".yml")
            workflow.parent.mkdir(parents=True)
            workflow.write_text("name: generated\n")
            environment = dict(os.environ)
            expected = runner.source_snapshot(root)
            with runner.canonical_source_environment(environment, workflow, output, root, expected):
                names = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], cwd=root).decode()
                status = subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root).decode()
                self.assertNotIn("_local-actrun-feedback-", names)
                self.assertNotIn("_local-actrun-feedback-", status)
                self.assertIn("tracked.txt", names)
                self.assertEqual(environment, dict(os.environ))

    def test_schema3_requires_the_exact_generated_workflow_in_live_snapshot(self):
        relative = ".github/workflows/_local-actrun-feedback-" + "a" * 32 + ".yml"
        expected = {"path": relative, "sha256": "b" * 64, "mode": 0o600}
        files = {relative: {"sha256": "b" * 64, "mode": 0o600, "link": None}, "source.mbt": {}}
        self.assertEqual(verification.strip_workflow(files, expected, require_present=True), {"source.mbt": {}})
        with self.assertRaises(RuntimeError):
            verification.strip_workflow({"source.mbt": {}}, expected, require_present=True)


class ImeEvidenceTests(unittest.TestCase):
    def test_diagnostic_capture_omission_cannot_qualify_as_product_green(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "summary.json"
            # Even a promoted status/ok pair must reject the diagnostic marker.
            path.write_text(json.dumps({"schema_version": 1, "status": "passed", "ok": True,
                                        "app_exit_code": 0, "diagnostic_only": True}))
            with self.assertRaisesRegex(acceptance.AcceptanceError, "completed pass"):
                acceptance.validate_summary(path)


    def test_japanese_romaji_source_allowlist_rejects_bundle_parent_and_other_modes(self):
        expected = "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"
        self.assertEqual(acceptance.KOTOERI_JAPANESE_ROMAJI_SOURCE_IDS, frozenset({expected}))
        self.assertTrue(acceptance.is_supported_kotoeri_japanese_romaji_source(expected))
        for source in ("Kotoeri", "com.apple.inputmethod.Kotoeri.RomajiTyping",
                       "com.apple.inputmethod.Kotoeri.RomajiTyping.Roman",
                       "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese.Katakana",
                       "com.apple.inputmethod.Kotoeri.Japanese"):
            with self.subTest(source=source):
                self.assertFalse(acceptance.is_supported_kotoeri_japanese_romaji_source(source))

    def test_abort_acknowledgement_binds_restoration_and_session_epochs(self):
        receipt = {"schema_version": 1, "restored": True, "session_closed": True,
                   "host_epoch": 11, "session_epoch": 7}
        self.assertEqual(acceptance.validate_abort_receipt(receipt, 11, 7), receipt)
        for changed in ({**receipt, "restored": False}, {**receipt, "host_epoch": True},
                        {**receipt, "session_epoch": 8}, {key: value for key, value in receipt.items()
                                                              if key != "session_epoch"}):
            with self.subTest(receipt=changed), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_abort_receipt(changed, 11, 7)

    def test_initial_summary_write_failure_still_aborts_and_records_terminal_pid(self):
        class FakeProfile:
            def doctor(self, root):
                return None

            def profile_environment(self, root):
                return {"DEVELOPER_DIR": "/Developer", "SDKROOT": "/SDK",
                        "MACOSX_DEPLOYMENT_TARGET": "14.0"}

            def host_identity(self):
                return {"hostname": "test-host"}

        class FakeProcess:
            def __init__(self):
                self.pid = 8724
                self.returncode = None

            def poll(self):
                return self.returncode

        class FakeApp:
            def __init__(self, process):
                self.process = process
                self.abort_calls = []
                self.close_calls = 0

            def abort_and_wait(self, **kwargs):
                self.abort_calls.append(kwargs)
                self.process.returncode = 0
                return {"requested": True, "acknowledged": True, "exit_code": 0}

            def close(self):
                self.close_calls += 1

        with tempfile.TemporaryDirectory(prefix="gpui-ime-summary-failure-") as temp:
            root = Path(temp)
            repo = root / "repo"
            profile_root = root / "profile"
            app_bundle = root / "GpuiTextField.app"
            output = root / "run"
            binary = app_bundle / "Contents/MacOS/GpuiTextField"
            library = app_bundle / "Contents/Frameworks/libgpui_macos.dylib"
            plist = app_bundle / "Contents/Info.plist"
            swiftc = root / "swiftc"
            for directory in (repo, profile_root, binary.parent, library.parent):
                directory.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"test app")
            binary.chmod(0o755)
            library.write_bytes(b"test library")
            plist.write_bytes(b"test plist")
            swiftc.write_bytes(b"test swiftc")
            process = FakeProcess()
            app = FakeApp(process)
            source = {"commit": "a" * 40, "tree": "b" * 40}
            summary_path = output.resolve() / "summary.json"
            original_write_text = Path.write_text
            failed_initial_write = False

            def fail_first_summary_write(path, data, *args, **kwargs):
                nonlocal failed_initial_write
                if path == summary_path and not failed_initial_write:
                    failed_initial_write = True
                    raise OSError("simulated summary storage failure")
                return original_write_text(path, data, *args, **kwargs)

            def check_output(argv, **kwargs):
                if argv[:2] == ["xcrun", "--find"]:
                    return str(swiftc)
                return "Apple Swift version test"

            compile_result = type("CompileResult", (), {"returncode": 0, "stdout": ""})()
            with mock.patch.object(acceptance, "load_profile", return_value=FakeProfile()), \
                 mock.patch.object(acceptance, "source_snapshot", return_value=source), \
                 mock.patch.object(acceptance, "digest", return_value="c" * 64), \
                 mock.patch.object(acceptance.subprocess, "check_output", side_effect=check_output), \
                 mock.patch.object(acceptance.subprocess, "run", return_value=compile_result), \
                 mock.patch.object(acceptance.subprocess, "Popen", return_value=process), \
                 mock.patch.object(acceptance, "AppOutput", return_value=app), \
                 mock.patch.object(Path, "write_text", new=fail_first_summary_write):
                with self.assertRaisesRegex(OSError, "simulated summary storage failure"):
                    acceptance.execute(profile_root, app_bundle, output, repo=repo)

            self.assertTrue(failed_initial_write)
            self.assertEqual(len(app.abort_calls), 1)
            self.assertEqual(app.close_calls, 1)
            self.assertEqual(process.poll(), 0)
            report = json.loads(summary_path.read_text())
            self.assertEqual(report["status"], "failed")
            self.assertEqual(report["app_pid"], process.pid)
            self.assertEqual(report["app_exit_code"], 0)
            self.assertTrue(report["cleanup"]["acknowledged"])
            self.assertTrue(report["source_stable"])
            self.assertIn("finished_utc", report)

    def test_valid_receipts_allow_equal_owner_and_accepted_revision_and_final_epoch_change(self):
        report, source, binary = valid_final()
        self.assertEqual(report["receipts"][8]["batch_sequence"], 4)
        self.assertEqual(report["effect_observations"][0]["batch_sequence"], 7)
        self.assertEqual(report["receipts"][8]["window_sequence"], report["receipts"][7]["window_sequence"])
        self.assertEqual(report["receipts"][10]["batch_sequence"], 8)
        self.assertEqual(report["effect_observations"][1]["batch_sequence"], 9)
        self.assertEqual(report["operations"][1]["release_batch_sequence"], 10)
        self.assertIs(acceptance.validate_final(report, source, binary, 8, 10), report)

    def test_v2_effect_contract_rejects_unbound_callback_provenance_or_frames(self):
        report, source, binary = valid_final()
        cases = [
            ("unsupported_final_version", lambda value: value.update(schema_version=1)),
            ("unsupported_operation_version", lambda value: value["operations"][0].update(schema_version=3)),
            ("operation_claims_origin", lambda value: value["operations"][0].update(causal_origin="dispatch", origin_dispatch_id=9)),
            ("operation_wrong_receipt", lambda value: value["operations"][0].update(dispatch_receipt_index=7)),
            ("operation_wrong_key", lambda value: value["operations"][0].update(key_code=53)),
            ("operation_wrong_host", lambda value: value["operations"][0].update(host_epoch=99)),
            ("operation_wrong_session", lambda value: value["operations"][0].update(session_epoch=99)),
            ("operation_bad_baseline_sequence", lambda value: value["operations"][0].update(baseline_batch_sequence=7)),
            ("operation_bad_baseline_frame", lambda value: value["operations"][0]["baseline_frame_identity"].update(frame_revision=99)),
            ("operation_lost_composition", lambda value: value["operations"][0].update(baseline_composing=False)),
            ("operation_timeout", lambda value: value["operations"][0].update(loop_iterations=acceptance.MAX_OPERATION_LOOP_ITERATIONS + 1)),
            ("effect_claims_origin", lambda value: value["effect_observations"][0].update(causal_origin="return", origin_dispatch_id=9)),
            ("effect_wrong_window", lambda value: value["effect_observations"][0].update(window_id=99)),
            ("effect_wrong_host", lambda value: value["effect_observations"][0].update(host_epoch=99)),
            ("effect_wrong_session", lambda value: value["effect_observations"][0].update(session_epoch=99)),
            ("effect_wrong_batch_sequence", lambda value: value["effect_observations"][0].update(batch_sequence=8)),
            ("effect_wrong_owner_revision", lambda value: value["effect_observations"][0].update(owner_revision=99)),
            ("effect_wrong_frame", lambda value: value["effect_observations"][0]["frame_identity"].update(frame_revision=99)),
            ("effect_wrong_delta", lambda value: value["effect_observations"][0].update(commit_callback_delta=2)),
            ("effect_replay", lambda value: value["effect_observations"][1].update(batch_index=1)),
            ("effect_reordered", lambda value: value["effect_observations"].reverse()),
            ("release_wrong_kind", lambda value: value["operations"][1].update(release_kind="other")),
            ("release_wrong_key", lambda value: value["operations"][1].update(release_key_code=36)),
            ("release_replay_cancel_batch", lambda value: value["operations"][1].update(release_batch_index=3)),
            ("release_wrong_sequence", lambda value: value["operations"][1].update(release_batch_sequence=9)),
            ("release_wrong_frame", lambda value: value["operations"][1].update(release_frame_revision=29)),
            ("release_geometry_without_revision", lambda value: value["operations"][1].update(release_geometry_revision=13)),
            ("release_wrong_window", lambda value: value["batches"][4]["frame_identity"].update(window_id=99)),
            ("release_extra_callback", lambda value: value["batches"][4].update(preedit_callbacks=1)),
            ("release_unacknowledged", lambda value: value["batches"][4].update(acknowledged=False)),
            ("return_claims_release", lambda value: value["operations"][0].update(
                release_kind="forwarded_escape_release")),
        ]
        for label, mutate in cases:
            changed = copy.deepcopy(report)
            mutate(changed)
            with self.subTest(case=label), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_final(changed, source, binary)
        report["operations"][0]["loop_iterations"] = acceptance.MAX_OPERATION_LOOP_ITERATIONS
        self.assertIs(acceptance.validate_final(report, source, binary), report)

    def test_escape_release_accepts_only_the_exact_pending_geometry_revision(self):
        report, source, binary = valid_final()
        release = report["batches"][4]
        release["accepted_revision"] = 13
        release["frame_identity"]["accepted_revision"] = 13
        report["operations"][1]["release_geometry_revision"] = 13
        report["final_frame_identity"]["accepted_revision"] = 13
        self.assertIs(acceptance.validate_final(report, source, binary), report)

        for marker in (None, 12, 14, True):
            changed = copy.deepcopy(report)
            changed["operations"][1]["release_geometry_revision"] = marker
            with self.subTest(marker=marker), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_final(changed, source, binary)

        changed = copy.deepcopy(report)
        changed["batches"][4]["owner_revision"] = 11
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(changed, source, binary)

    def test_escape_cancel_accepts_a_preedit_observed_after_a_noncomposing_boundary(self):
        report, source, binary = valid_final()
        report["operations"][1]["baseline_composing"] = False
        report["batches"][3]["preedit_callbacks"] = 1
        report["effect_observations"][1]["preedit_callback_delta"] = 1
        report["preedit_callbacks"] = 3
        self.assertIs(acceptance.validate_final(report, source, binary), report)

        report, source, binary = valid_final()
        report["operations"][1]["baseline_composing"] = False
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(report, source, binary)

    def test_preedit_only_ack_cannot_satisfy_a_commit_effect(self):
        report, source, binary = valid_final()
        report["batches"][1]["commit_callbacks"] = 0
        report["batches"][2]["commit_callbacks"] = 1
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(report, source, binary)

    def test_operation_wait_budget_is_tickable_once_at_the_main_loop_boundary(self):
        main = (REPO / "examples/macos_text_field/main.mbt").read_text()
        acceptance_source = (REPO / "examples/macos_text_field/ime_acceptance.mbt").read_text()
        self.assertEqual(main.count("acceptance = mac_acceptance_tick_operation_iteration(acceptance)"), 1)
        self.assertLess(main.index("mac_acceptance_operation_timed_out(acceptance)"),
                        main.index("acceptance = mac_acceptance_tick_operation_iteration(acceptance)"))
        self.assertEqual(acceptance_source.count("mac_acceptance_tick_operation_iteration("), 1)
        self.assertIn("const MAC_ACCEPTANCE_OPERATION_ITERATION_LIMIT : Int = 200", acceptance_source)

    def test_after_frame_preserves_diagnostic_state_when_recording_an_effect(self):
        source = (REPO / "examples/macos_text_field/ime_acceptance.mbt").read_text()
        after_frame = source.split("fn mac_acceptance_after_frame(", 1)[1].split(
            "fn mac_acceptance_poll_receipt(", 1)[0]
        effect_call = after_frame.split(
            "next_state = mac_acceptance_record_operation_effect(", 1
        )[1].split(")", 1)[0]
        self.assertIn("next_state", effect_call)
        self.assertIn("pending_geometry_revision", effect_call)
        self.assertIn("dispatch_trace_record_count: state.dispatch_trace_record_count + 1", source)

    def test_effect_frames_keep_exact_committed_text(self):
        report, source, binary = valid_final()
        for operation_index, batch_index in ((0, 1), (1, 3)):
            changed = copy.deepcopy(report)
            changed["effect_observations"][operation_index]["frame_identity"]["text"] = "Hello WRONG"
            changed["batches"][batch_index]["frame_identity"]["text"] = "Hello WRONG"
            with self.subTest(operation=operation_index), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_final(changed, source, binary)

    def test_batch_revision_acknowledgements_must_form_a_monotonic_chain(self):
        report, source, binary = valid_final()
        self.assertIs(acceptance.validate_final(report, source, binary, 8, 10), report)
        bad_revision = copy.deepcopy(report)
        bad_revision["batches"][1]["owner_revision"] = 11
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(bad_revision, source, binary, 8, 10)
        bad_frame = copy.deepcopy(report)
        bad_frame["batches"][2]["frame_identity"]["frame_revision"] = 22
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(bad_frame, source, binary, 8, 10)
        bool_identity = copy.deepcopy(report)
        bool_identity["receipts"][0]["host_epoch"] = True
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_final(bool_identity, source, binary, 8, 10)

    def test_pixel_deltas_must_be_inside_the_textfield_roi_after_caret_masking(self):
        width, height = 640, 272
        black = bytes((0, 0, 0, 255))
        first = {"width": width, "height": height, "pixels": black * (width * height),
                 "pixel_sha256": "a" * 64}
        second_pixels = bytearray(first["pixels"])
        # A titlebar-only change must not satisfy the text ROI contract.
        for x in range(10, 20):
            second_pixels[(10 * width + x) * 4:(10 * width + x) * 4 + 4] = bytes((255, 0, 0, 255))
        second = {**first, "pixels": bytes(second_pixels), "pixel_sha256": "b" * 64}
        geometry = {"x": 24, "y": 40, "width": 512, "height": 48}
        content = {"x": 0, "y": 0, "width": 640, "height": 240}
        caret = {"x": 100, "y": 48, "width": 1, "height": 20}
        offset = {"x": 0, "y": 32}
        roi = acceptance.prepare_text_roi(first, content, 1.0, geometry, caret, offset)
        changed_roi = acceptance.prepare_text_roi(second, content, 1.0, geometry, caret, offset)
        delta = acceptance.text_roi_difference({"image": first, "roi": roi}, {"image": second, "roi": changed_roi})
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.require_text_change(delta, "titlebar-only")
        # Caret-only changes are masked too.
        caret_pixels = bytearray(first["pixels"])
        for y in range(78, 102):
            for x in range(97, 104):
                caret_pixels[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes((255, 255, 255, 255))
        caret_image = {**first, "pixels": bytes(caret_pixels), "pixel_sha256": "c" * 64}
        caret_roi = acceptance.prepare_text_roi(caret_image, content, 1.0, geometry, caret, offset)
        delta = acceptance.text_roi_difference({"image": first, "roi": roi},
                                                {"image": caret_image, "roi": caret_roi})
        self.assertEqual(delta["changed_pixels"], 0)

    def test_final_validator_rejects_missing_or_reordered_native_receipt(self):
        report, source, binary = valid_final()
        for mutate in (lambda value: value["receipts"].pop(),
                       lambda value: value["receipts"].reverse(),
                       lambda value: value["receipts"][0].update(key_code=999),
                       lambda value: value["receipts"][0].update(down_dispatched=False)):
            changed = copy.deepcopy(report)
            mutate(changed)
            with self.subTest(receipts=changed["receipts"]), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_final(changed, source, binary)

    def test_final_validator_rejects_stale_source_binary_and_bad_final_epoch(self):
        report, source, binary = valid_final()
        for field, value in (("source_revision", "e" * 40), ("binary_sha256", "f" * 64),
                             ("final_session_epoch", 7)):
            changed = copy.deepcopy(report)
            changed[field] = value
            with self.subTest(field=field), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_final(changed, source, binary)

    def test_missing_required_checkpoint_phase_is_rejected(self):
        source = {"commit": "a" * 40, "tree": "b" * 40}
        with self.assertRaises(acceptance.AcceptanceError):
            acceptance.validate_checkpoint({"schema_version": 1, "phase": "initial-ready"},
                                            "composition-ready", source, "c" * 64)

    def test_strict_json_rejects_duplicate_and_nonfinite_values(self):
        for value in ('{"phase":"initial-ready","phase":"composition-ready"}', '{"value":NaN}'):
            with self.subTest(value=value), self.assertRaises(acceptance.AcceptanceError):
                acceptance.strict_json(value)

    def test_png_decoder_limits_expansion_before_allocation(self):
        def chunk(kind, payload):
            body = kind + payload
            return len(payload).to_bytes(4, "big") + body + (zlib.crc32(body) & 0xffffffff).to_bytes(4, "big")
        oversized = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", (20000).to_bytes(4, "big") * 2 + bytes([8, 6, 0, 0, 0])) + chunk(b"IEND", b"")
        with tempfile.TemporaryDirectory(prefix="gpui-png-limit-") as temp:
            path = Path(temp) / "oversized.png"
            path.write_bytes(oversized)
            with self.assertRaises(acceptance.AcceptanceError):
                acceptance.png_pixels(path)

    def test_summary_revalidator_checks_current_source_binary_png_and_required_phases(self):
        with tempfile.TemporaryDirectory(prefix="gpui-ime-revalidate-") as temp:
            directory = Path(temp)
            report = successful_ime_summary(directory, REPO)
            summary = directory / "summary.json"
            summary.write_text(json.dumps(report, ensure_ascii=False))
            self.assertIsNotNone(acceptance.validate_summary(summary, REPO))
            original = json.loads(summary.read_text())
            cases = [
                lambda value: value["source_before"].update(commit="e" * 40),
                lambda value: value["initial_checkpoint"].update(phase="missing"),
                lambda value: value.update(input_source="Kotoeri"),
                lambda value: value["initial_checkpoint"].update(input_source="Kotoeri"),
                lambda value: value["initial_checkpoint"]["window_geometry"].update(
                    selected_input_source="com.apple.inputmethod.Kotoeri.RomajiTyping"),
                lambda value: value["composition_checkpoint"].update(
                    input_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Roman"),
                lambda value: value["final_acceptance"].update(
                    input_source="com.apple.inputmethod.Kotoeri.RomajiTyping.Roman"),
                lambda value: value["capture_runtime"].pop("helper_compile_argv"),
                lambda value: value["capture_runtime"].update(helper_compile_argv=["swiftc", "-framework", "ImageIO"]),
                lambda value: value["final_acceptance"].update(binary_sha256="f" * 64),
                lambda value: value["initial_checkpoint"]["window_geometry"].update(native_window_id=100),
                lambda value: value["screenshots"]["initial"]["window_geometry"].update(app_key_matches=False),
            ]
            for mutate in cases:
                changed = copy.deepcopy(original)
                mutate(changed)
                summary.write_text(json.dumps(changed, ensure_ascii=False))
                with self.assertRaises(acceptance.AcceptanceError):
                    acceptance.validate_summary(summary, REPO)
            summary.write_text(json.dumps(original, ensure_ascii=False))
            (directory / "composition-window.png").write_bytes(b"tampered")
            with self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_summary(summary, REPO)


class FontResolutionTests(unittest.TestCase):
    def test_macos_hotpath_binds_actual_final_framework_link_flags(self):
        expected = ["-lm", "-framework", "Foundation", "-framework", "CoreGraphics",
                    "-framework", "CoreText"]
        self.assertEqual(hotpath.workload_link_flags(REPO / "testing/input_hotpath_macos"), expected)
        with tempfile.TemporaryDirectory(prefix="gpui-hotpath-link-flags-") as temp:
            root = Path(temp)
            package = root / "moon.pkg"
            package.write_text((REPO / "testing/input_hotpath_macos/moon.pkg").read_text().replace(
                "-framework CoreText", "-framework AppKit"))
            with self.assertRaises(hotpath.HotpathError):
                hotpath.workload_link_flags(root)

    def test_font_identity_hashes_real_latin_and_japanese_files(self):
        with tempfile.TemporaryDirectory(prefix="gpui-font-fixture-") as temp:
            font = Path(temp) / "font.dat"
            font.write_bytes(b"resolved font bytes")
            rows = []
            for segment in ("latin", "japanese"):
                rows.append({"segment": segment, "family": "Resolved Family",
                             "postscript_name": "ResolvedPS", "file_url": str(font)})
            report = hotpath.validate_font_resolution({"schema_version": 1, "fonts": rows})
            self.assertEqual({row["segment"] for row in report["fonts"]}, {"latin", "japanese"})
            self.assertTrue(all(row["sha256"] for row in report["fonts"]))
            raw = {"schema_version": 1, "fonts": rows}
            font.write_bytes(b"tampered CoreText font bytes")
            with self.assertRaises(hotpath.HotpathError):
                hotpath.validate_font_observation(raw, report)

    def test_font_workload_json_rejects_duplicate_properties_and_nonfinite_numbers(self):
        for value in ('{"fonts":[],"fonts":[]}', '{"width":NaN}'):
            with self.subTest(value=value), self.assertRaises(hotpath.HotpathError):
                hotpath.strict_json(value)

    def test_font_identity_rejects_missing_script_duplicate_and_unreadable_file(self):
        with tempfile.TemporaryDirectory(prefix="gpui-font-fixture-") as temp:
            font = Path(temp) / "font.dat"
            font.write_bytes(b"resolved font bytes")
            latin = {"segment": "latin", "family": "Latin", "postscript_name": "LatinPS", "file_url": str(font)}
            japanese = {"segment": "japanese", "family": "Japanese", "postscript_name": "JapanesePS", "file_url": str(font)}
            cases = [
                {"schema_version": 1, "fonts": [latin]},
                {"schema_version": 1, "fonts": [latin, copy.deepcopy(latin)]},
                {"schema_version": 1, "fonts": [latin, {**japanese, "file_url": None}]},
            ]
            for value in cases:
                with self.subTest(value=value), self.assertRaises(hotpath.HotpathError):
                    hotpath.validate_font_resolution(value)


if __name__ == "__main__":
    unittest.main()
