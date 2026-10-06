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
    host, initial_epoch = 11, 7
    batches = []
    for index, (sequence, counts) in enumerate(zip((4, 7, 9), ((1, 0, 0), (0, 1, 0), (0, 0, 1))), 1):
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
        batch_sequence = 0 if index == 1 else 4 if index < 5 else 7 if index < 9 else 9
        receipts.append({"schema_version": 1, "dispatch_id": index, "key_code": key,
                         "down_posted": True, "up_posted": True, "down_dispatched": True,
                         "up_dispatched": True, "host_epoch": host, "session_epoch": initial_epoch,
                         "batch_sequence": batch_sequence, "window_sequence": index * 3})
    final_identity = {"schema_version": 1, "window_id": 3, "host_epoch": host,
                      "session_epoch": 0, "batch_sequence": 9, "accepted_revision": 12,
                      "frame_revision": 40, "frame_sha256": "d" * 64, "text": "Hello 日本語"}
    report = {"schema_version": 1, "window_id": 3, "host_epoch": host,
              "session_epoch": initial_epoch, "final_session_epoch": 0,
              "input_source": "Kotoeri", "preedit_callbacks": 1, "commit_callbacks": 1,
              "cancel_callbacks": 1, "committed_text": "Hello 日本語", "composing": False,
              "focused": False, "commit_count": 1, "batches": batches, "receipts": receipts,
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
    source = acceptance.source_snapshot(repo)
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
                       "selected_input_source": "com.apple.inputmethod.Kotoeri.RomajiTyping",
                       "coordinate_space": "top_left_window_points", "content_origin_in_window": {"x": 0, "y": 32},
                       "content_size": {"width": 640, "height": 240},
                       "window_size": {"width": 640, "height": 272}}
    initial_checkpoint = {"schema_version": 1, "phase": "initial-ready", "input_source": "Kotoeri",
                          "text": "Hello ", "field_revision": 8, "session_epoch": 7,
                          "frame_identity": initial_identity, "source_revision": source["commit"],
                          "source_tree": source["tree"], "binary_sha256": actual_binary,
                          "field_bounds": initial_state["field_bounds"], "window_geometry": window_geometry}
    comp_identity = copy.deepcopy(final["batches"][0]["frame_identity"])
    composition = {"schema_version": 1, "phase": "composition-ready", "input_source": "Kotoeri",
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
                    "engine": "ScreenCaptureKit.SCScreenshotManager",
                    "helper_source_sha256": hashlib.sha256(helper_source.read_bytes()).hexdigest()},
            "initial_state": initial_state, "initial_checkpoint": initial_checkpoint,
            "input_source": "Kotoeri", "composition_checkpoint": composition,
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
    def test_abort_acknowledgement_binds_restoration_and_session_epochs(self):
        receipt = {"schema_version": 1, "restored": True, "session_closed": True,
                   "host_epoch": 11, "session_epoch": 7}
        self.assertEqual(acceptance.validate_abort_receipt(receipt, 11, 7), receipt)
        for changed in ({**receipt, "restored": False}, {**receipt, "host_epoch": True},
                        {**receipt, "session_epoch": 8}, {key: value for key, value in receipt.items()
                                                              if key != "session_epoch"}):
            with self.subTest(receipt=changed), self.assertRaises(acceptance.AcceptanceError):
                acceptance.validate_abort_receipt(changed, 11, 7)

    def test_valid_receipts_allow_equal_owner_and_accepted_revision_and_final_epoch_change(self):
        report, source, binary = valid_final()
        self.assertIs(acceptance.validate_final(report, source, binary, 8, 10), report)

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
