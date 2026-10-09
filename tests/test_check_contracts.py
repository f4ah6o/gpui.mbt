"""Focused tests for release-ledger validation and evidence enforcement."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("check_contracts", ROOT / "scripts/check_contracts.py")
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


class ReleaseLedgerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def pending_document(self) -> dict[str, object]:
        return {
            "schema_version": 1,
            "release": "1.0",
            "status": "pending",
            "candidate_revision": None,
            "gates": [
                {"id": gate_id, "status": "pending", "evidence": []}
                for gate_id in checker.REQUIRED_GATE_IDS
            ],
        }

    def write_manifest(self, gate_id: str, revision: str) -> tuple[str, str]:
        path = Path("release-evidence") / f"{gate_id}.json"
        absolute = self.root / path
        absolute.parent.mkdir(parents=True, exist_ok=True)
        document = {
            "schema_version": 1,
            "gate_id": gate_id,
            "result": "pass",
            "candidate_revision": revision,
            "toolchain": "moon 0.1.20260920 / moonc 0.10.14+7d59c7ec9",
            "target": "ubuntu-latest / native",
            "run": "https://github.com/example/gpui/actions/runs/1234",
            "artifacts": [
                {
                    "name": "test-report.json",
                    "uri": "https://github.com/example/gpui/actions/runs/1234/artifacts/5678",
                    "sha256": "a" * 64,
                }
            ],
        }
        absolute.write_text(json.dumps(document, sort_keys=True), encoding="utf-8")
        digest = hashlib.sha256(absolute.read_bytes()).hexdigest()
        return path.as_posix(), digest

    def mark_one_gate_pass(self, document: dict[str, object], gate_id: str) -> str:
        revision = "b" * 40
        document["candidate_revision"] = revision
        gates = document["gates"]
        assert isinstance(gates, list)
        for gate in gates:
            assert isinstance(gate, dict)
            if gate["id"] == gate_id:
                gate["status"] = "pass"
                path, digest = self.write_manifest(gate_id, revision)
                gate["evidence"] = [{"type": "ci-report", "path": path, "sha256": digest}]
                break
        document["status"] = "pending"  # Other required gates are still pending.
        return revision

    def test_all_pending_gates_are_a_valid_non_ready_ledger(self) -> None:
        self.assertEqual(checker.validate_release_gates(self.pending_document(), self.root), [])

    def test_missing_and_duplicate_required_gates_fail(self) -> None:
        missing = self.pending_document()
        missing["gates"] = missing["gates"][:-1]  # type: ignore[index]
        errors = checker.validate_release_gates(missing, self.root)
        self.assertTrue(any("missing required gates" in error for error in errors))

        duplicate = self.pending_document()
        duplicate["gates"].append(dict(duplicate["gates"][0]))  # type: ignore[index]
        errors = checker.validate_release_gates(duplicate, self.root)
        self.assertTrue(any("duplicate release gate id" in error for error in errors))

    def test_malformed_status_types_fail_without_raising(self) -> None:
        document = self.pending_document()
        document["status"] = ["ready"]
        document["gates"][0]["status"] = {"pass": True}  # type: ignore[index]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("release ledger status" in error for error in errors))
        self.assertTrue(any("gate compatibility: status" in error for error in errors))

    def test_pass_without_evidence_or_candidate_commit_fails(self) -> None:
        document = self.pending_document()
        document["gates"][0]["status"] = "pass"  # type: ignore[index]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("requires at least one" in error for error in errors))
        self.assertTrue(any("requires a pinned candidate_revision" in error for error in errors))

    def test_evidence_path_must_exist_and_match_its_digest(self) -> None:
        document = self.pending_document()
        revision = "b" * 40
        document["candidate_revision"] = revision
        document["gates"][0]["status"] = "pass"  # type: ignore[index]
        document["gates"][0]["evidence"] = [  # type: ignore[index]
            {"type": "ci-report", "path": "missing.json", "sha256": "a" * 64}
        ]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("evidence file does not exist" in error for error in errors))

        path, digest = self.write_manifest("compatibility", revision)
        document["gates"][0]["evidence"] = [  # type: ignore[index]
            {"type": "ci-report", "path": path, "sha256": "0" * 64}
        ]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("checksum mismatch" in error for error in errors))
        self.assertEqual(len(digest), 64)

    def test_source_document_cannot_stand_in_for_structured_pass_manifest(self) -> None:
        document = self.pending_document()
        revision = "b" * 40
        document["candidate_revision"] = revision
        prose = self.root / "docs" / "release.md"
        prose.parent.mkdir()
        prose.write_text("This gate passes.", encoding="utf-8")
        digest = hashlib.sha256(prose.read_bytes()).hexdigest()
        document["gates"][0]["status"] = "pass"  # type: ignore[index]
        document["gates"][0]["evidence"] = [  # type: ignore[index]
            {"type": "ci-report", "path": "docs/release.md", "sha256": digest}
        ]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("invalid JSON" in error for error in errors))

    def test_pass_manifest_must_match_gate_and_candidate_revision(self) -> None:
        document = self.pending_document()
        revision = self.mark_one_gate_pass(document, "compatibility")
        path, digest = self.write_manifest("correctness", revision)
        document["gates"][0]["evidence"] = [  # type: ignore[index]
            {"type": "ci-report", "path": path, "sha256": digest}
        ]
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("gate_id must match" in error for error in errors))

    def test_ready_requires_every_gate_to_pass(self) -> None:
        document = self.pending_document()
        document["status"] = "ready"
        errors = checker.validate_release_gates(document, self.root)
        self.assertTrue(any("gate states require 'pending'" in error for error in errors))

    def test_json_loader_rejects_malformed_and_duplicate_keys(self) -> None:
        path = self.root / "malformed.json"
        path.write_text("{", encoding="utf-8")
        with self.assertRaises(checker.ContractError):
            checker.load_json(path)
        path.write_text('{"status":"pending","status":"ready"}', encoding="utf-8")
        with self.assertRaises(checker.ContractError):
            checker.load_json(path)

    def test_non_object_ledger_fails_without_raising(self) -> None:
        self.assertEqual(
            checker.validate_release_gates(["not", "an", "object"], self.root),
            ["release ledger must be a JSON object"],
        )


class RuntimeDependencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        (self.root / "moon.mod").write_text('name = "f4ah6o/gpui"\n', encoding="utf-8")
        manifests = {
            "primitives": '',
            "accessibility": 'import { "f4ah6o/gpui/primitives" }\n',
            "diagnostics": 'import { "f4ah6o/gpui/primitives" }\n',
            "core": 'import { "f4ah6o/gpui/diagnostics", "f4ah6o/gpui/primitives" }\n',
            "layout": 'import { "f4ah6o/gpui/primitives" }\n',
            "scene": 'import { "f4ah6o/gpui/primitives" }\n',
            "element": (
                'import { "f4ah6o/gpui/core", "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/layout", "f4ah6o/gpui/scene" }\n'
            ),
        }
        for package, content in manifests.items():
            directory = self.root / package
            directory.mkdir()
            (directory / "moon.pkg").write_text(content, encoding="utf-8")

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_test_only_quickcheck_import_is_allowed(self) -> None:
        path = self.root / "primitives/moon.pkg"
        path.write_text(
            'import { "moonbitlang/core/quickcheck" } for "test"\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

    def test_runtime_quickcheck_import_is_rejected(self) -> None:
        path = self.root / "primitives/moon.pkg"
        path.write_text('import { "moonbitlang/core/quickcheck" }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("QuickCheck must be a test-only import" in error for error in errors))

    def test_third_party_runtime_import_is_rejected(self) -> None:
        path = self.root / "primitives/moon.pkg"
        path.write_text('import { "vendor/random" }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("third-party runtime import is forbidden" in error for error in errors))


    def test_layout_may_depend_only_on_primitives(self) -> None:
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        path = self.root / "layout/moon.pkg"
        path.write_text('import { "f4ah6o/gpui/core" }\\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("forbidden runtime package edge" in error for error in errors))

    def test_scene_and_element_edges_are_bounded(self) -> None:
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        scene = self.root / "scene/moon.pkg"
        scene.write_text('import { "f4ah6o/gpui/core" }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("forbidden runtime package edge" in error for error in errors))
        scene.write_text('import { "f4ah6o/gpui/primitives" }\n', encoding="utf-8")
        element = self.root / "element/moon.pkg"
        element.write_text('import { "f4ah6o/gpui/diagnostics" }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("forbidden runtime package edge" in error for error in errors))

    def test_new_runtime_package_requires_an_approved_layer(self) -> None:
        directory = self.root / "widgets"
        directory.mkdir()
        (directory / "moon.pkg").write_text("", encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("widgets: runtime package has no approved dependency layer" in error for error in errors))

    def test_text_model_is_an_independent_core_only_layer(self) -> None:
        directory = self.root / "text"
        directory.mkdir()
        manifest = directory / "moon.pkg"
        manifest.write_text(
            'import { "moonbitlang/core/int" }\n'
            'import { "moonbitlang/core/quickcheck", '
            '"f4ah6o/gpui/text" } for "test"\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        manifest.write_text('import { "f4ah6o/gpui/scene" }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("text/: forbidden runtime package edge" in error for error in errors))

    def test_accessibility_is_portable_and_cannot_import_native_or_action_leaves(self) -> None:
        manifest = self.root / "accessibility/moon.pkg"
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        for dependency in ("platform", "capability", "mcp"):
            manifest.write_text(
                f'import {{ "f4ah6o/gpui/{dependency}" }}\n',
                encoding="utf-8",
            )
            errors = checker.validate_runtime_dependencies(self.root)
            self.assertTrue(
                any("accessibility/: forbidden runtime package edge" in error for error in errors),
                msg=f"accessibility must not depend on {dependency}",
            )
        manifest.write_text('import { "f4ah6o/gpui/primitives" }\n', encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

    def test_capability_and_mcp_edges_are_explicit_and_bounded(self) -> None:
        for package, content in {
            "capability": 'import { "f4ah6o/gpui/core", "f4ah6o/gpui/diagnostics" }\n',
            "mcp": (
                'import { "f4ah6o/gpui/capability", '
                '"f4ah6o/gpui/diagnostics" }\n'
            ),
        }.items():
            directory = self.root / package
            directory.mkdir()
            (directory / "moon.pkg").write_text(content, encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        (self.root / "capability/moon.pkg").write_text(
            'import { "f4ah6o/gpui/mcp" }\n',
            encoding="utf-8",
        )
        self.assertTrue(
            any(
                "capability/: forbidden runtime package edge" in error
                for error in checker.validate_runtime_dependencies(self.root)
            )
        )

        (self.root / "capability/moon.pkg").write_text(
            'import { "f4ah6o/gpui/diagnostics" }\n',
            encoding="utf-8",
        )
        (self.root / "mcp/moon.pkg").write_text(
            'import { "f4ah6o/gpui/core" }\n',
            encoding="utf-8",
        )
        self.assertTrue(
            any(
                "mcp/: forbidden runtime package edge" in error
                for error in checker.validate_runtime_dependencies(self.root)
            )
        )

    def test_capability_lifecycle_edge_has_no_reverse_or_platform_dependency(self) -> None:
        directory = self.root / "capability"
        directory.mkdir()
        manifest = directory / "moon.pkg"
        manifest.write_text('import { "f4ah6o/gpui/core" }\n', encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        (self.root / "core/moon.pkg").write_text(
            'import { "f4ah6o/gpui/capability" }\n', encoding="utf-8"
        )
        self.assertTrue(any(
            "core/: forbidden runtime package edge" in error
            for error in checker.validate_runtime_dependencies(self.root)
        ))
        (self.root / "core/moon.pkg").write_text('', encoding="utf-8")
        manifest.write_text('import { "f4ah6o/gpui/platform" }\n', encoding="utf-8")
        self.assertTrue(any(
            "capability/: forbidden runtime package edge" in error
            for error in checker.validate_runtime_dependencies(self.root)
        ))

    def test_approved_headless_example_runtime_edges_are_allowed(self) -> None:
        directory = self.root / "examples/headless"
        directory.mkdir(parents=True)
        (directory / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/core", "f4ah6o/gpui/diagnostics", '
            '"f4ah6o/gpui/primitives" }\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

    def test_ubuntu_button_fixture_stays_above_portable_button(self) -> None:
        manifests = {
            "controls/button": (
                'import { "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/element", "f4ah6o/gpui/scene" }\n'
            ),
            "examples/ubuntu_button/fixture": (
                'import { "f4ah6o/gpui/controls/button", '
                '"f4ah6o/gpui/element", "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/scene" }\n'
            ),
            "examples/ubuntu_button": (
                'import { "f4ah6o/gpui/ubuntu", "f4ah6o/gpui/platform", '
                '"f4ah6o/gpui/diagnostics", "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/examples/ubuntu_button/fixture", '
                '"moonbitlang/core/env" }\n'
            ),
        }
        for package, content in manifests.items():
            directory = self.root / package
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "moon.pkg").write_text(content, encoding="utf-8")

        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        fixture_manifest = self.root / "examples/ubuntu_button/fixture/moon.pkg"
        fixture_manifest.write_text(
            'import { "f4ah6o/gpui/controls/button", '
            '"f4ah6o/gpui/platform" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any(
                "examples/ubuntu_button/fixture/: forbidden runtime package edge" in error
                for error in errors
            )
        )

        app_manifest = self.root / "examples/ubuntu_button/moon.pkg"
        app_manifest.write_text(
            'import { "f4ah6o/gpui/controls/button" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any(
                "examples/ubuntu_button/: forbidden runtime package edge" in error
                for error in errors
            )
        )

    def test_ubuntu_button_semantics_stay_in_the_headless_fixture_layer(self) -> None:
        manifests = {
            "controls/button": (
                'import { "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/element", "f4ah6o/gpui/scene" }\n'
            ),
            "examples/ubuntu_button/fixture": (
                'import { "f4ah6o/gpui/accessibility", '
                '"f4ah6o/gpui/controls/button", "f4ah6o/gpui/element", '
                '"f4ah6o/gpui/primitives", "f4ah6o/gpui/scene" }\n'
            ),
            "examples/ubuntu_button": (
                'import { "f4ah6o/gpui/ubuntu", "f4ah6o/gpui/platform", '
                '"f4ah6o/gpui/diagnostics", "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/examples/ubuntu_button/fixture", '
                '"moonbitlang/core/env" }\n'
            ),
        }
        for package, content in manifests.items():
            directory = self.root / package
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "moon.pkg").write_text(content, encoding="utf-8")

        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        fixture_manifest = self.root / "examples/ubuntu_button/fixture/moon.pkg"
        fixture_manifest.write_text(
            'import { "f4ah6o/gpui/accessibility", '
            '"f4ah6o/gpui/platform" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any(
                "examples/ubuntu_button/fixture/: forbidden runtime package edge" in error
                for error in errors
            )
        )

        app_manifest = self.root / "examples/ubuntu_button/moon.pkg"
        app_manifest.write_text(
            'import { "f4ah6o/gpui/accessibility" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any(
                "examples/ubuntu_button/: forbidden runtime package edge" in error
                for error in errors
            )
        )

    def test_browser_host_is_a_leaf_above_the_portable_app_fixture(self) -> None:
        browser_app = self.root / "examples/browser_app"
        browser_app.mkdir(parents=True)
        (browser_app / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/core", "f4ah6o/gpui/diagnostics", '
            '"f4ah6o/gpui/element", "f4ah6o/gpui/layout", '
            '"f4ah6o/gpui/platform", "f4ah6o/gpui/primitives", '
            '"f4ah6o/gpui/scene" }\n',
            encoding="utf-8",
        )
        browser = self.root / "examples/browser"
        browser.mkdir(parents=True)
        browser_manifest = browser / "moon.pkg"
        browser_manifest.write_text(
            'import { "f4ah6o/gpui/examples/browser_app", '
            '"f4ah6o/gpui/diagnostics", "f4ah6o/gpui/platform", '
            '"f4ah6o/gpui/primitives" }\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        (browser_app / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/examples/browser" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any("forbidden runtime package edge" in error for error in errors)
        )

    def test_task_board_host_is_a_leaf_above_the_portable_board(self) -> None:
        board = self.root / "examples/task_board"
        board.mkdir(parents=True)
        (board / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/capability", "f4ah6o/gpui/core", '
            '"f4ah6o/gpui/element", "f4ah6o/gpui/layout", '
            '"f4ah6o/gpui/platform", "f4ah6o/gpui/primitives", '
            '"f4ah6o/gpui/scene" }\n',
            encoding="utf-8",
        )
        host = self.root / "examples/browser_board"
        host.mkdir(parents=True)
        (host / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/examples/task_board" }\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        (board / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/examples/browser_board" }\n',
            encoding="utf-8",
        )
        self.assertTrue(any(
            "examples/task_board/: forbidden runtime package edge" in error
            for error in checker.validate_runtime_dependencies(self.root)
        ))

    def test_mcp_stdio_host_is_a_leaf_above_the_mcp_adapter(self) -> None:
        directory = self.root / "examples/mcp_stdio"
        directory.mkdir(parents=True)
        manifest = directory / "moon.pkg"
        manifest.write_text(
            'import { "f4ah6o/gpui/capability", '
            '"f4ah6o/gpui/diagnostics", "f4ah6o/gpui/mcp" }\n',
            encoding="utf-8",
        )
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        manifest.write_text(
            'import { "f4ah6o/gpui/core" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any(
                "examples/mcp_stdio/: forbidden runtime package edge" in error
                for error in errors
            )
        )

    def test_approved_example_still_rejects_third_party_runtime_edges(self) -> None:
        directory = self.root / "examples/headless"
        directory.mkdir(parents=True)
        (directory / "moon.pkg").write_text(
            'import { "f4ah6o/gpui/core", "vendor/unreviewed" }\n',
            encoding="utf-8",
        )
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(
            any("third-party runtime import is forbidden" in error for error in errors)
        )

    def test_test_harness_package_is_not_a_runtime_layer(self) -> None:
        directory = self.root / "testing/core_model"
        directory.mkdir(parents=True)
        (directory / "moon.pkg").write_text('import { "vendor/model-checker" }\n', encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

    def test_backend_edges_aliases_and_whitebox_imports_are_audited(self) -> None:
        for package, content in {
            "platform": 'import { "f4ah6o/gpui/scene", "f4ah6o/gpui/diagnostics" }',
            "ubuntu": 'import { "f4ah6o/gpui/platform" @shared, "f4ah6o/gpui/scene" }\nimport { "moonbitlang/core/env" } for "wbtest"',
            "examples/ubuntu": 'import { "f4ah6o/gpui/ubuntu" @native }',
        }.items():
            directory = self.root / package
            directory.mkdir(parents=True)
            (directory / "moon.pkg").write_text(content)
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        (self.root / "core/moon.pkg").write_text('import { "f4ah6o/gpui/ubuntu" @native }')
        self.assertTrue(any("forbidden runtime package edge" in error
                            for error in checker.validate_runtime_dependencies(self.root)))

    def test_native_edges_are_explicit_and_cannot_leak_into_core(self) -> None:
        for package, content in {
            "platform": 'import { "f4ah6o/gpui/primitives", "f4ah6o/gpui/diagnostics", "f4ah6o/gpui/scene" }',
            "platform/macos": 'import { "f4ah6o/gpui/platform", "f4ah6o/gpui/scene" }',
            "examples/native_macos": 'import { "f4ah6o/gpui/platform/macos", "f4ah6o/gpui/platform" }',
        }.items():
            directory = self.root / package
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "moon.pkg").write_text(content, encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])
        (self.root / "core/moon.pkg").write_text('import { "f4ah6o/gpui/platform/macos" }', encoding="utf-8")
        self.assertTrue(any("forbidden runtime package edge" in error for error in checker.validate_runtime_dependencies(self.root)))

    def test_native_text_and_readback_seams_are_bounded_leaves(self) -> None:
        manifests = {
            "platform/testing": (
                'import { "f4ah6o/gpui/platform", '
                '"f4ah6o/gpui/diagnostics" }\n'
            ),
            "platform/macos_text": (
                'import { "f4ah6o/gpui/primitives", "f4ah6o/gpui/text", '
                '"f4ah6o/gpui/text_layout" }\n'
            ),
            "platform/macos": (
                'import { "f4ah6o/gpui/platform", "f4ah6o/gpui/primitives", '
                '"f4ah6o/gpui/diagnostics", "f4ah6o/gpui/scene", '
                '"f4ah6o/gpui/platform/testing" }\n'
            ),
            "ubuntu": (
                'import { "f4ah6o/gpui/platform", '
                '"f4ah6o/gpui/platform/linux_text", '
                '"f4ah6o/gpui/platform/testing", "f4ah6o/gpui/text", '
                '"f4ah6o/gpui/primitives", "f4ah6o/gpui/diagnostics", '
                '"f4ah6o/gpui/scene" }\n'
            ),
            "windows": (
                'import { "f4ah6o/gpui/platform", '
                '"f4ah6o/gpui/platform/windows_text", '
                '"f4ah6o/gpui/platform/testing", "f4ah6o/gpui/text", '
                '"f4ah6o/gpui/primitives", "f4ah6o/gpui/diagnostics", '
                '"f4ah6o/gpui/scene" }\n'
            ),
        }
        for package, content in manifests.items():
            directory = self.root / package
            directory.mkdir(parents=True, exist_ok=True)
            (directory / "moon.pkg").write_text(content, encoding="utf-8")
        self.assertEqual(checker.validate_runtime_dependencies(self.root), [])

        (self.root / "platform/testing/moon.pkg").write_text(
            'import { "f4ah6o/gpui/platform/macos" }\n', encoding="utf-8"
        )
        self.assertTrue(any(
            "platform/testing/: forbidden runtime package edge" in error
            for error in checker.validate_runtime_dependencies(self.root)
        ))

        (self.root / "platform/testing/moon.pkg").write_text(
            manifests["platform/testing"], encoding="utf-8"
        )
        (self.root / "core/moon.pkg").write_text(
            'import { "f4ah6o/gpui/platform/testing" }\n', encoding="utf-8"
        )
        self.assertTrue(any(
            "core/: forbidden runtime package edge" in error
            for error in checker.validate_runtime_dependencies(self.root)
        ))

    def test_malformed_package_manifest_fails_cleanly(self) -> None:
        path = self.root / "primitives/moon.pkg"
        path.write_text('import { moonbitlang/core/quickcheck }\n', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("malformed import list" in error for error in errors))

    def test_malformed_json_package_manifest_fails_cleanly(self) -> None:
        path = self.root / "primitives/moon.pkg"
        path.unlink()
        (self.root / "primitives/moon.pkg.json").write_text('{"import": [}', encoding="utf-8")
        errors = checker.validate_runtime_dependencies(self.root)
        self.assertTrue(any("invalid JSON" in error for error in errors))


class WorkflowContractTests(unittest.TestCase):
    def test_repository_workflow_has_required_commands_and_full_sha_pins(self) -> None:
        self.assertEqual(
            checker._validate_workflow(ROOT / ".github/workflows/contracts.yml"),
            [],
        )


if __name__ == "__main__":
    unittest.main()
