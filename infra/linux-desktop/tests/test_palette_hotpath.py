import importlib.util
from pathlib import Path
import unittest

HERE = Path(__file__).parents[1]
SPEC = importlib.util.spec_from_file_location("palette_hotpath", HERE / "palette-hotpath.py")
palette = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(palette)


class PaletteHotpathTests(unittest.TestCase):
    def test_shared_validator_exact_fixture_and_both_producers_are_bound(self):
        profile = palette.profile
        self.assertEqual(profile.PRODUCER_FILES, ["input-hotpath.py", "palette-hotpath.py"])
        self.assertEqual(profile.retained_files(profile.WORKLOAD), set(profile.WORKLOAD_FILES))
        self.assertEqual(len(profile.workload_digest()), 64)
        self.assertNotEqual(profile.producer_digest(), profile.digest(HERE / "input-hotpath.py"))
        self.assertEqual(profile.EXPECTED_CALLS["picker.filter"], 32)
        self.assertEqual(profile.EXPECTED_CALLS["picker.visible"], 32)
        self.assertEqual(profile.EXPECTED_CALLS["scene.list"], 32)
        self.assertEqual(profile.EXPECTED_CALLS["scene.build"], 32)
        self.assertIn("CPU", profile.SCOPE)
        self.assertIn("hardware input-to-display latency", profile.EXCLUDED)

    def test_fixture_uses_reusable_painter_and_no_input_content_metrics(self):
        text = (palette.profile.WORKLOAD / "main.mbt").read_text(encoding="utf-8")
        self.assertIn(".paint_items(", text)
        self.assertIn("install_field_at", text)
        self.assertIn("SceneSnapshot::new", text)
        self.assertIn("canonical_json()", text)
        self.assertNotIn("println(scene", text)
        self.assertNotIn('\\\"query\\\"', text)
        self.assertNotIn('\\\"label_text\\\"', text)
        self.assertIn('"picker.filter"', text)
        self.assertIn('"picker.visible"', text)
        self.assertIn('"scene.list"', text)

    def test_plain_rows_and_strict_numeric_schema_reuse_the_qualified_validator(self):
        rows = [{"kind": "result", "instrumented": False, "cycles": 32,
                 "checksum": 1, "fingerprint": 42, "workload_ns": 1,
                 "clock_resolution_ns": 1, "observed_min_tick_ns": 20,
                 "backward_reads": 0, "invalid_clocks": 0, "dropped_samples": 0}]
        self.assertEqual(palette.profile.validate_run(rows, False)["fingerprint"], 42)
        rows[0]["query"] = "private content"
        with self.assertRaisesRegex(RuntimeError, "unexpected metric fields"):
            palette.profile.validate_run(rows, False)


if __name__ == "__main__":
    unittest.main()
