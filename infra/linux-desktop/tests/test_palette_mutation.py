import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

HERE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("palette_mutation", HERE / "palette-mutation.py")
mutation = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mutation)


class PaletteMutationTests(unittest.TestCase):
    def fixture(self, directory):
        snapshot = Path(directory) / "source"
        snapshot.mkdir()
        for name in (*mutation.SOURCES, "turtles.toml"):
            path = snapshot / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("true\n")
        rows = []
        for index, outcome in enumerate(("KILLED", "SURVIVED", "UNVIABLE")):
            rows.append({"id": "m-" + str(index), "path": mutation.SOURCES[0], "line": 1,
                         "column": 1, "offset": 0, "end": 4, "group": "boolean",
                         "visibility": "public", "original": "true", "replacement": "false",
                         "outcome": outcome, "reused": False,
                         "killed_by": [{"package": "f4ah6o/gpui/controls/command_palette",
                                        "filename": "palette_wbtest.mbt", "index": 0, "kind": "Assertion"}] if outcome == "KILLED" else []})
        # UNVIABLE includes compiler/warning rejection; it never raises kills or
        # enters the viable denominator, even if the compiler log is retained.
        report = {"schema": 2, "turtles_version": "0.3.0", "module": str(snapshot),
                  "test_scope": "module", "skipped_files": [], "moon_version": "fixture",
                  "baseline_duration_ms": "1", "baseline_check_ms": "1", "baseline_test_ms": "1",
                  "files": {name: mutation.fnv((snapshot / name).read_bytes()) for name in (*mutation.SOURCES, "turtles.toml")},
                  "mutants": rows, "summary": {"killed": 1, "survived": 1, "timeout": 0,
                                               "unviable": 1, "reused": 0, "score": 50}}
        survivors = Path(directory) / "survivors"
        survivors.mkdir()
        (survivors / "m-1.diff").write_text("-true\n+false\n")
        return snapshot, report, survivors

    def test_observation_keeps_survivors_and_warning_unviable_separate(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot, report, survivors = self.fixture(directory)
            result = mutation.audit(report, snapshot, survivors)
            self.assertEqual(result["qualified_viable"], 2)
            self.assertEqual(result["counts"], {"killed": 1, "survived": 1, "timeout": 0, "unviable": 1})
            self.assertEqual(len(result["unresolved"]), 1)
            self.assertEqual(len(result["unviable_candidates"]), 1)
            self.assertIn("no score threshold", result["mutation_policy"])

    def test_no_cached_invented_or_out_of_scope_classifications(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot, report, survivors = self.fixture(directory)
            corruptions = [lambda r: r["summary"].update(killed=2),
                           lambda r: r["mutants"][0].update(reused=True),
                           lambda r: r["mutants"][0].update(killed_by=[]),
                           lambda r: r["mutants"][0].update(path="controls/text_field/composition.mbt"),
                           lambda r: r["mutants"][0].update(original="fake"),
                           lambda r: r["mutants"][1].update(id="m-0"),
                           lambda r: r["files"].update({"turtles.toml": "0000000000000000"}),
                           lambda r: r.update(skipped_files=[{"path": mutation.SOURCES[0]}])]
            for corrupt in corruptions:
                changed = copy.deepcopy(report)
                corrupt(changed)
                with self.assertRaises(ValueError):
                    mutation.audit(changed, snapshot, survivors)

    def test_complete_fresh_discovery_and_retained_diffs_required(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot, report, survivors = self.fixture(directory)
            discovery = [mutation.candidate_tuple(row) for row in report["mutants"]]
            # Different candidates can have the same text mutation; real
            # discovery uses unique locations. This fixture's duplicated tuple
            # is intentionally not passed as complete discovery.
            with self.assertRaises(ValueError):
                mutation.audit(report, snapshot, survivors, discovery[:1])
            (survivors / "m-1.diff").unlink()
            with self.assertRaises(ValueError):
                mutation.audit(report, snapshot, survivors)

    def test_scope_has_only_new_state_sources_and_no_skip_markers(self):
        config = mutation.tomllib.loads((mutation.REPO / mutation.SCOPE).read_text())
        self.assertEqual(config["include"], list(mutation.SOURCES))
        self.assertEqual(set(config["operators"]), mutation.OPERATORS)
        for name in mutation.SOURCES:
            self.assertNotRegex((mutation.REPO / name).read_text(), r"#turtles\.skip|turtles:\s*skip")


if __name__ == "__main__":
    unittest.main()
