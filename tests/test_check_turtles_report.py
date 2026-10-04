from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "check_turtles_report", ROOT / "scripts" / "check_turtles_report.py"
)
assert SPEC is not None and SPEC.loader is not None
checker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(checker)


def valid_report() -> dict:
    outcomes = ["KILLED", "SURVIVED", "TIMEOUT", "UNVIABLE", "KILLED"]
    groups = ["comparison", "boolean", "arithmetic", "literal", "condition"]
    mutants = [
        {
            "id": f"m-{group}",
            "path": f"primitives/{group}.mbt",
            "line": index + 1,
            "group": group,
            "original": "true",
            "replacement": "false",
            "outcome": outcome,
        }
        for index, (group, outcome) in enumerate(zip(groups, outcomes))
    ]
    return {
        "schema": 2,
        "module": "/tmp/turtles/module",
        "turtles_version": "0.3.0",
        "moon_version": "moon 0.10.14",
        "baseline_duration_ms": "200",
        "baseline_check_ms": "80",
        "baseline_test_ms": "120",
        "test_scope": "module",
        "files": {
            "turtles.toml": "0" * 16,
            "primitives/comparison.mbt": "1" * 16,
        },
        "skipped_files": [],
        "mutants": mutants,
        "summary": {
            "killed": 2,
            "survived": 1,
            "timeout": 1,
            "unviable": 1,
            "score": 50.0,
        },
    }


class TurtlesReportAuditTests(unittest.TestCase):
    def test_valid_observation_records_score_and_unresolved_mutants_pending_review(self) -> None:
        result = checker.audit_report(valid_report(), "candidate-sha")
        self.assertEqual(result["score_percent"], 50.0)
        self.assertEqual(result["baseline_state"], "observed_pending_review")
        self.assertEqual(result["release_mutation_gate"], "pending")
        self.assertEqual([row["outcome"] for row in result["unresolved"]], ["SURVIVED", "TIMEOUT"])

    def test_empty_or_all_unviable_report_cannot_pass_as_a_perfect_score(self) -> None:
        empty = valid_report()
        empty["mutants"] = []
        empty["summary"] = {
            "killed": 0,
            "survived": 0,
            "timeout": 0,
            "unviable": 0,
            "score": 100.0,
        }
        with self.assertRaisesRegex(ValueError, "non-empty mutants"):
            checker.audit_report(empty, "sha")

        unviable = valid_report()
        for mutant in unviable["mutants"]:
            mutant["outcome"] = "UNVIABLE"
        unviable["summary"] = {
            "killed": 0,
            "survived": 0,
            "timeout": 0,
            "unviable": len(unviable["mutants"]),
            "score": 100.0,
        }
        with self.assertRaisesRegex(ValueError, "no viable mutants"):
            checker.audit_report(unviable, "sha")

    def test_rejects_wrong_schema_summary_and_operator_scope(self) -> None:
        wrong_schema = valid_report()
        wrong_schema["schema"] = 3
        with self.assertRaisesRegex(ValueError, "schema 2"):
            checker.audit_report(wrong_schema, "sha")

        wrong_counts = valid_report()
        wrong_counts["summary"]["survived"] = 0
        with self.assertRaisesRegex(ValueError, "summary counters"):
            checker.audit_report(wrong_counts, "sha")

        wrong_operator = valid_report()
        wrong_operator["mutants"][0]["group"] = "body"
        with self.assertRaisesRegex(ValueError, "unexpected mutation operator"):
            checker.audit_report(wrong_operator, "sha")

        missing_group = valid_report()
        missing_group["mutants"] = [
            mutant for mutant in missing_group["mutants"] if mutant["group"] != "condition"
        ]
        missing_group["summary"] = {
            "killed": 1,
            "survived": 1,
            "timeout": 1,
            "unviable": 1,
            "score": 25.0,
        }
        with self.assertRaisesRegex(ValueError, "every configured operator"):
            checker.audit_report(missing_group, "sha")

    def test_skipped_source_and_incomplete_toolchain_metadata_are_rejected(self) -> None:
        skipped = valid_report()
        skipped["skipped_files"] = [{"path": "primitives/broken.mbt", "error": "parse failure"}]
        with self.assertRaisesRegex(ValueError, "skipped a file"):
            checker.audit_report(skipped, "sha")

        missing_toolchain = valid_report()
        missing_toolchain["moon_version"] = None
        with self.assertRaisesRegex(ValueError, "identify the MoonBit toolchain"):
            checker.audit_report(missing_toolchain, "sha")

    def test_survivor_and_timeout_diff_artifacts_must_match_report(self) -> None:
        report = valid_report()
        with tempfile.TemporaryDirectory() as temp_dir:
            survivor_dir = Path(temp_dir)
            (survivor_dir / "m-boolean.diff").write_text("--- source\n", encoding="utf-8")
            (survivor_dir / "m-arithmetic.diff").write_text("--- source\n", encoding="utf-8")
            result = checker.audit_report(report, "sha", survivor_dir)
            self.assertEqual(
                result["unresolved_diff_files"],
                ["m-arithmetic.diff", "m-boolean.diff"],
            )

            (survivor_dir / "m-arithmetic.diff").unlink()
            with self.assertRaisesRegex(ValueError, "diffs do not match"):
                checker.audit_report(report, "sha", survivor_dir)

    def test_checked_in_config_must_match_report_fingerprint_and_scope(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            config_path = Path(temp_dir) / "turtles.toml"
            config_path.write_text(
                'include = ["primitives/"]\n'
                'operators = ["comparison", "boolean", "arithmetic", "literal", "condition"]\n',
                encoding="utf-8",
            )
            report = valid_report()
            report["files"]["turtles.toml"] = checker._fnv1a64_hex(config_path.read_bytes())
            checker.validate_scope_configuration(config_path, report)

            config_path.write_text('include = ["."]\noperators = []\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "include must be exactly"):
                checker.validate_scope_configuration(config_path, report)


if __name__ == "__main__":
    unittest.main()
