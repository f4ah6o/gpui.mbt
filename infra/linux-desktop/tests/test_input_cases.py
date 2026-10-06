import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))
import input_cases as cases
import case_runner as runner


def fixture(name="basic-text-shift"):
    return cases.select_case(name)


class CaseFormatTests(unittest.TestCase):
    def test_named_catalog_is_valid_and_honest_about_coverage(self):
        catalog = cases.catalog()
        self.assertEqual({case["id"] for case in catalog}, {
            "basic-text-shift", "ctrl-a-replacement", "cursor-backspace-delete",
            "undo-redo", "undo-branch-edit", "focus-loss-reentry",
            "standalone-modifiers", "held-repeat", "ime-composition"})
        self.assertTrue(cases.runnable(fixture()))
        self.assertEqual(fixture("ctrl-a-replacement")["disposition"], "expected-failure")
        self.assertFalse(cases.runnable(fixture("ctrl-a-replacement")))
        self.assertEqual(fixture("held-repeat")["disposition"], "pending")
        self.assertEqual(fixture("ime-composition")["disposition"], "unsupported")

    def test_six_keys_have_predeclared_text_selection_and_fourteen_events(self):
        case = fixture()
        self.assertEqual(case["initial"], {"text": "Hello 日本", "selection": {"anchor": 8, "head": 8}, "focused": True})
        self.assertEqual(case["steps"][-1]["expect"], {"text": "Hello 日本abD", "selection": {"anchor": 10, "head": 10}, "focused": True})
        self.assertEqual(runner.key_event_count(case), 14)
        self.assertEqual(case["oracle"]["rgba_sha256"], "44f395449323e0e7581d04b6d012b4463819d65e0914aa53f0e662d534eb74d9")

    def invalid(self, mutate, pattern=None):
        case = copy.deepcopy(fixture())
        mutate(case)
        with self.assertRaisesRegex(cases.CaseError, pattern or "."):
            cases.validate_case(case)

    def test_version_type_platform_and_unknown_fields_are_rejected(self):
        for value in (2, True, "1", None):
            self.invalid(lambda case, value=value: case.update(version=value), "version")
        self.invalid(lambda case: case.update(platform="macos"), "platform")
        self.invalid(lambda case: case.update(callback="edit"), "unknown")
        self.invalid(lambda case: case.pop("initial"), "missing")

    def test_bounded_strings_events_timeout_and_artifact_paths(self):
        self.invalid(lambda case: case.update(timeout_ms=True), "integer")
        self.invalid(lambda case: case.update(timeout_ms=60001), "integer")
        self.invalid(lambda case: case.update(description="x" * 1025), "length")
        self.invalid(lambda case: case["steps"][0].update(events=[]), "events")
        self.invalid(lambda case: case["steps"][0].update(events=[{"type":"wait", "duration_ms":2001}]), "duration")
        self.invalid(lambda case: case["steps"][0].update(events=[{"type":"wait", "duration_ms":2000}] * 8), "budget")
        self.invalid(lambda case: case.update(artifacts=["../outside"]), "artifact")
        self.invalid(lambda case: case["steps"][0]["events"][0].update(type="paste"), "unknown event")

    def test_modifier_duplicates_unknown_and_bools_are_rejected(self):
        self.invalid(lambda case: case["steps"][0]["events"][0].update(modifiers=["Shift_L", "Shift_L"]), "duplicate")
        self.invalid(lambda case: case["steps"][0]["events"][0].update(modifiers=["Meta_L"]), "allowed")
        self.invalid(lambda case: case["steps"][0]["events"][0].update(keysym="日本"), "unsupported")
        self.invalid(lambda case: case["focus_click"].update(x=960), "integer")
        self.invalid(lambda case: case["focus_click"].update(y=True), "integer")
        self.invalid(lambda case: case["steps"][0]["events"][0].update(modifiers=[True]), "allowed")

    def test_utf16_offsets_support_direction_and_reject_split_surrogates(self):
        state = {"text":"A😀B", "selection":{"anchor":4,"head":1}, "focused":True}
        cases.validate_state(state, "state")
        state["selection"]["head"] = 2
        with self.assertRaisesRegex(cases.CaseError, "splits"):
            cases.validate_state(state, "state")
        self.invalid(lambda case: case["initial"]["selection"].update(head=9), "integer")
        self.invalid(lambda case: case["initial"].update(text="\ud800"), "surrogate")
        self.invalid(lambda case: case["initial"].update(text="bad\nline"), "single-line")

    def test_provenance_hashes_and_oracle_activation_need_review(self):
        self.invalid(lambda case: case["provenance"].update(app_sha256=None), "requires")
        self.invalid(lambda case: case["provenance"].update(source_commit="abc"), "hash")
        self.invalid(lambda case: case.update(oracle={"kind":"pending", "reason":"future"}), "reviewed oracle")
        self.invalid(lambda case: case["oracle"].update(fixture="../../new.png"), "existing reviewed")
        self.invalid(lambda case: case["steps"][0]["events"][0].update(keysym="x"), "exact declared")
        self.invalid(lambda case: case["oracle"].update(rgba_sha256="0"*64), "must not be replaced")

    def test_duplicate_fields_nonfinite_and_oversize_json_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "case.json"
            for content in ('{"version":1,"version":1}', '{"version":NaN}', 'x' * 65537):
                path.write_text(content)
                with self.assertRaises(cases.CaseError):
                    cases.load_case(path)

    def test_duplicate_step_ids_are_rejected(self):
        case = fixture("undo-redo")
        case["steps"][1]["id"] = case["steps"][0]["id"]
        with self.assertRaisesRegex(cases.CaseError, "duplicate"):
            cases.validate_case(case)


class CaseRunnerTests(unittest.TestCase):
    def test_concrete_actions_balance_modifiers_and_hold_release(self):
        event = {"type":"key", "keysym":"z", "modifiers":["Control_L","Shift_L"]}
        actions = runner.physical_actions(event)
        self.assertEqual([(item["keysym"],item["down"]) for item in actions],
                         [("Control_L",True),("Shift_L",True),("z",True),("z",False),("Shift_L",False),("Control_L",False)])
        hold = runner.physical_actions({"type":"hold","keysym":"a","modifiers":[],"duration_ms":600})
        self.assertEqual(hold, [{"type":"key","keysym":"a","down":True},
                               {"type":"wait","duration_ms":600},
                               {"type":"key","keysym":"a","down":False}])
        keys = [action for step in fixture()["steps"] for event in step["events"]
                for action in runner.physical_actions(event) if action["type"]=="key"]
        self.assertEqual(len(keys), 14)
        self.assertEqual(runner.physical_actions({"type":"click","x":500,"y":50}),
                         [{"type":"motion","x":500,"y":50},{"type":"button","button":1,"down":True},{"type":"button","button":1,"down":False}])

    def test_focus_away_os_ledger_differs_from_client_delivery(self):
        case = fixture("focus-loss-reentry")
        self.assertEqual(runner.key_event_count(case), 4)
        self.assertEqual(runner.key_event_count(case, client_only=True), 2)
        events = case["steps"][0]["events"]
        self.assertEqual(runner.physical_actions(events[0]), [{"type":"focus","target":"away"}])
        self.assertEqual(len(runner.physical_actions(events[1])), 2)
        # Clicking outside the field does not move the client keyboard target.
        case["steps"][0]["events"][0] = {"type":"click","x":600,"y":150}
        case["steps"][1]["events"] = case["steps"][1]["events"][1:]
        self.assertEqual(runner.key_event_count(case, client_only=True), 4)
        with self.assertRaisesRegex(cases.CaseError, "focus target"):
            cases.validate_event({"type":"focus","target":"live-desktop"}, "event")

    def test_validator_cli_and_list_never_launch_or_load_xlib(self):
        with patch.object(runner.subprocess, "Popen") as process, patch.object(runner.C, "CDLL") as library, patch("sys.stdout", new=io.StringIO()):
            self.assertEqual(runner.main(["--validate", "--all"]), 0)
            self.assertEqual(runner.main(["--list"]), 0)
            process.assert_not_called()
            library.assert_not_called()

    def test_pending_unsupported_and_unresolved_xfail_stop_before_launch(self):
        with patch.object(runner, "verify_inputs") as verify, patch.object(runner.subprocess, "Popen") as process, patch("sys.stdout", new=io.StringIO()):
            for name in ("held-repeat", "ime-composition", "ctrl-a-replacement"):
                self.assertEqual(runner.main(["--case", name]), 3)
                with self.assertRaisesRegex(RuntimeError, "pending/unsupported"):
                    runner.run_case(fixture(name), None, Path("/not-created"))
            verify.assert_not_called()
            process.assert_not_called()

    def test_one_case_and_all_cases_selection_with_explicit_skips(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "verify_inputs", return_value=({},None)), patch("sys.stdout", new=io.StringIO()):
            output = Path(temporary) / "all"
            with patch.object(runner, "run_case", side_effect=lambda case, args, path: {"case_id":case["id"], "status":"passed"}) as execute:
                self.assertEqual(runner.main(["--all", "--output", str(output)]), 0)
                self.assertEqual(execute.call_count, 1)
                report = json.loads((output / "summary.json").read_text())
                self.assertEqual((report["executed"], report["skipped"], report["all_cases_executed"]), (1,8,False))
                self.assertIn("skipped-unsupported", {item["status"] for item in report["results"]})
                self.assertEqual(runner.main(["--case", "basic-text-shift", "--output", str(Path(temporary) / "one")]), 0)
                self.assertEqual(execute.call_count, 2)

    def test_all_with_zero_runnable_cases_returns_nonzero_skipped_status(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner.subprocess, "Popen") as process, patch("sys.stdout", new=io.StringIO()) as stdout:
            directory = Path(temporary) / "cases"
            directory.mkdir()
            (directory / "ime.json").write_text(json.dumps(fixture("ime-composition")))
            output = Path(temporary) / "out"
            self.assertEqual(runner.main(["--all", "--cases-dir", str(directory), "--output", str(output)]), 3)
            report = json.loads((output / "summary.json").read_text())
            self.assertEqual(report["status"], "skipped-no-runnable-cases")
            self.assertEqual((report["executed"],report["skipped"]), (0,1))
            self.assertFalse(report["all_cases_executed"])
            self.assertIn("skipped-no-runnable-cases", stdout.getvalue())
            process.assert_not_called()

    def test_missing_prefix_xkb_is_clear_and_stops_before_launch(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner.subprocess, "Popen") as process:
            prefix = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "missing private prefix XKB resources.*locked xkb-data"):
                runner.verify_prefix_resources(prefix)
            root = prefix / "usr/share/X11/xkb"
            for name in runner.XKB_RESOURCES:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("reviewed-resource-stub")
            hashes = runner.verify_prefix_resources(prefix)
            self.assertEqual(set(hashes), set(runner.XKB_RESOURCES))
            self.assertTrue(all(len(value)==64 for value in hashes.values()))
            process.assert_not_called()

    def test_output_reuse_is_rejected_before_input(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner, "verify_inputs", return_value=({},None)), patch.object(runner, "run_case") as execute, patch("sys.stderr", new=io.StringIO()):
            with self.assertRaises(SystemExit) as exit:
                runner.main(["--case", "basic-text-shift", "--output", temporary])
            self.assertEqual(exit.exception.code, 2)
            execute.assert_not_called()

    def test_private_display_rejects_inherited_and_socket_lock_occupancy(self):
        for inherited in (":4321", ":4321.0", "host:4321.1"):
            with self.assertRaisesRegex(RuntimeError, "inherited"):
                runner.private_display_number(inherited, choose=lambda:4321, exists=lambda path:False)
        for suffix in (".X4321-lock", "X4321"):
            with self.assertRaisesRegex(RuntimeError, "already in use"):
                runner.private_display_number(":0.0", choose=lambda:4321, exists=lambda path,suffix=suffix:path.name==suffix)
        self.assertEqual(runner.private_display_number(":0.0", choose=lambda:4321, exists=lambda path:False), 4321)
        with self.assertRaisesRegex(RuntimeError, "invalid"):
            runner.private_display_number(":0", choose=lambda:0, exists=lambda path:False)

    def test_missing_xkb_cli_preflight_does_not_create_output_or_processes(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(runner.subprocess, "Popen") as process, patch("sys.stderr", new=io.StringIO()) as stderr:
            root = Path(temporary)
            app, fonts = root / "app", root / "fonts.conf"
            app.write_text("not executed")
            fonts.write_text("not loaded")
            output = root / "must-not-create"
            with self.assertRaises(SystemExit) as exit:
                runner.main(["--case","basic-text-shift","--prefix",str(root),"--repo",str(root),
                             "--app",str(app),"--app-sha256","0"*64,"--fontconfig",str(fonts),"--output",str(output)])
            self.assertEqual(exit.exception.code, 2)
            self.assertIn("missing private prefix XKB resources", stderr.getvalue())
            self.assertFalse(output.exists())
            process.assert_not_called()

    def test_observer_schema_monotonicity_and_utf16_are_strict(self):
        record = {"version":1,"presentation":1,"text":"Hello 日本","selection":{"anchor":8,"head":8},"focused":True,"revision":1}
        encode = lambda value: runner.STATE_PREFIX + json.dumps(value)
        self.assertEqual(runner.presented_states("ignored line\n" + encode(record)), [record])
        self.assertEqual(runner.state_of(record), fixture()["initial"])
        for mutate in (lambda value:value.update(version=True), lambda value:value.update(presentation=0), lambda value:value.update(focused=1), lambda value:value.update(revision=-1), lambda value:value.update(command="edit")):
            changed = copy.deepcopy(record)
            mutate(changed)
            with self.assertRaises(RuntimeError):
                runner.presented_states(encode(changed))
        with self.assertRaisesRegex(RuntimeError, "presentation"):
            runner.presented_states(encode(record) + "\n" + encode(record))
        with self.assertRaises(RuntimeError):
            runner.presented_states(runner.STATE_PREFIX + '{"version":1,"version":1}')


if __name__ == "__main__":
    unittest.main()
