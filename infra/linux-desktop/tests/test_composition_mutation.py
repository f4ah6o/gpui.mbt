import copy
import difflib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("composition_mutation", HERE / "composition-mutation.py")
mutation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mutation)


class CompositionMutationTests(unittest.TestCase):
    def fixture(self, root):
        snapshot = root / "source"
        for relative in mutation.SOURCES:
            (snapshot / relative).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(mutation.REPO / relative, snapshot / relative)
        shutil.copy2(mutation.REPO / mutation.SCOPE, snapshot / "turtles.toml")
        content = (snapshot / mutation.SOURCES[1]).read_bytes()
        offset = content.index(b"+", content.index(b"let preedit_length"))
        row = {"id": "test-candidate", "path": mutation.SOURCES[1], "offset": offset,
               "end": offset + 1, "original": "+", "replacement": "-", "group": "arithmetic",
               "line": content[:offset].count(b"\n") + 1, "column": 1, "visibility": "public", "outcome": "KILLED", "reused": False,
               "killed_by": [{"package": "f4ah6o/gpui/text", "filename": "fixture_test.mbt",
                              "index": 0, "kind": "Assertion", "test_name": "fixture"}]}
        report = {"schema": 2, "turtles_version": "0.3.0", "module": str(snapshot),
                  "test_scope": "module", "moon_version": "pinned fixture", "baseline_duration_ms": "3",
                  "baseline_check_ms": "1", "baseline_test_ms": "2", "skipped_files": [],
                  "files": {path: mutation.fnv((snapshot / path).read_bytes()) for path in
                            (*mutation.SOURCES, "turtles.toml")}, "mutants": [row],
                  "summary": {"killed": 1, "survived": 0, "timeout": 0, "unviable": 0,
                              "reused": 0, "score": 100}}
        review = json.loads((mutation.REPO / mutation.REVIEW).read_text())
        for allowed in review["survivors"]:
            for relative in allowed.get("rationale_dependencies_sha256", {}):
                (snapshot / relative).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(mutation.REPO / relative, snapshot / relative)
        return report, snapshot, review

    def test_valid_fresh_attributed_evidence_is_qualified(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            result = mutation.audit(report, snapshot, review)
            self.assertEqual(result["attempted_candidates"], 1)
            self.assertEqual(result["qualified_viable"], 1)
            self.assertEqual(result["counts"]["killed"], 1)

    def test_negative_reports_fail_closed(self):
        changes = [
            lambda r: r.update(schema=3),
            lambda r: r.update(turtles_version="0.4.0"),
            lambda r: r.update(test_scope="affected"),
            lambda r: r.update(module="another-source"),
            lambda r: r.update(skipped_files=[{"path": mutation.SOURCES[0]}]),
            lambda r: r.update(mutants=[]),
            lambda r: r["summary"].update(killed=99),
            lambda r: r["summary"].update(score=99),
            lambda r: r["files"].update({"turtles.toml": "0000000000000000"}),
            lambda r: r["mutants"][0].update(reused=True),
            lambda r: r["mutants"][0].update(killed_by=[]),
            lambda r: r["mutants"][0].update(original="false"),
            lambda r: r["mutants"][0].update(path="ubuntu/native.mbt"),
            lambda r: r["mutants"].append(copy.deepcopy(r["mutants"][0])),
        ]
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            for change in changes:
                broken = copy.deepcopy(report)
                change(broken)
                with self.subTest(report=broken), self.assertRaises(ValueError):
                    mutation.audit(broken, snapshot, review)

    def test_unreviewed_survivor_timeout_and_all_unviable_are_not_green(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            for outcome in ("SURVIVED", "TIMEOUT", "UNVIABLE"):
                broken = copy.deepcopy(report)
                broken["mutants"][0]["outcome"] = outcome
                broken["summary"].update(killed=0, score=0)
                broken["summary"][outcome.lower()] = 1
                with self.subTest(outcome=outcome), self.assertRaises(ValueError):
                    mutation.audit(broken, snapshot, review)

    def test_a_mixed_check_failure_cannot_hide_behind_an_attributed_kill(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            failed = copy.deepcopy(report["mutants"][0])
            failed.update(id="check-failure", outcome="UNVIABLE")
            report["mutants"].append(failed)
            report["summary"].update(unviable=1)
            with self.assertRaisesRegex(ValueError, "unqualified check failure"):
                mutation.audit(report, snapshot, review)

    def test_discovery_requires_every_candidate_to_be_classified(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            row = report["mutants"][0]
            one = mutation.candidate_tuple(row)
            self.assertEqual(mutation.audit(report, snapshot, review, discovery=[one])["attempted_candidates"], 1)
            with self.assertRaisesRegex(ValueError, "complete fresh discovered"):
                mutation.audit(report, snapshot, review, discovery=[one, ("other.mbt", 1, 1, "+", "-", "public")])

    def test_pinned_discovery_parser_preserves_multiline_candidates_and_rejects_empty_or_skips(self):
        text = "Found 2 mutation(s).\ntext/composition.mbt:3:4: + -> - [public]\ncontrols/text_field/composition.mbt:5:6: one ||\n two -> false [private]\n"
        result = mutation.parse_discovery(text)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[1][3], "one ||\n two")
        for invalid in ("No mutations found.\n", text.replace("Found 2", "Found 3"),
                        text + "Skipped 1 block(s) marked with a turtles skip marker.\n"):
            with self.assertRaises(ValueError):
                mutation.parse_discovery(invalid)

    def test_equivalent_survivor_requires_exact_source_diff_review_and_raw_diff(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            allowed = review["survivors"][0]
            content = (snapshot / allowed["path"]).read_bytes()
            row = {key: allowed[key] for key in ("id", "path", "offset", "end", "original", "replacement", "group")}
            row.update(line=content[:row["offset"]].count(b"\n") + 1, outcome="SURVIVED", reused=False)
            report["mutants"] = [row]
            report["summary"].update(killed=0, survived=1, score=0)
            result = mutation.audit(report, snapshot, review)
            self.assertEqual(result["counts"]["killed"], 0)
            self.assertEqual(result["counts"]["survived"], 1)
            self.assertEqual(len(result["reviewed_survivors"]), 1)
            with self.assertRaisesRegex(ValueError, "missing raw survivor"):
                mutation.audit(report, snapshot, review, Path(temporary) / "missing")
            stale = copy.deepcopy(review)
            stale["survivors"][0]["source_sha256"] = "0" * 64
            with self.assertRaisesRegex(ValueError, "stale survivor"):
                mutation.audit(report, snapshot, stale)
            diffs = Path(temporary) / "survivors"
            diffs.mkdir()
            altered = content[:row["offset"]] + row["replacement"].encode() + content[row["end"]:]
            diff = "".join(difflib.unified_diff(content.decode().splitlines(keepends=True),
                altered.decode().splitlines(keepends=True), fromfile="a/" + row["path"], tofile="b/" + row["path"]))
            raw = diffs / (row["id"] + ".diff")
            raw.write_text(diff)
            self.assertEqual(mutation.audit(report, snapshot, review, diffs)["counts"]["survived"], 1)
            extra = diffs / "stale.diff"
            extra.write_text("old report")
            with self.assertRaisesRegex(ValueError, "exactly the current"):
                mutation.audit(report, snapshot, review, diffs)
            extra.unlink()
            raw.write_text("")
            with self.assertRaisesRegex(ValueError, "reviewed hunk"):
                mutation.audit(report, snapshot, review, diffs)

    def test_equivalence_review_tracks_admission_and_measurement_dependencies(self):
        with tempfile.TemporaryDirectory() as temporary:
            report, snapshot, review = self.fixture(Path(temporary))
            allowed = review["survivors"][1]
            content = (snapshot / allowed["path"]).read_bytes()
            row = {key: allowed[key] for key in ("id", "path", "offset", "end", "original", "replacement", "group")}
            row.update(line=content[:row["offset"]].count(b"\n") + 1, outcome="SURVIVED", reused=False)
            report["mutants"] = [row]
            report["summary"].update(killed=0, survived=1, score=0)
            mutation.audit(report, snapshot, review)
            dependency = snapshot / "text_layout/model.mbt"
            dependency.write_text(dependency.read_text() + "\n// changed admission\n")
            with self.assertRaisesRegex(ValueError, "stale survivor rationale dependency"):
                mutation.audit(report, snapshot, review)


if __name__ == "__main__":
    unittest.main()
