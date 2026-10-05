"""CPU-only regression for the selected-text framebuffer color oracle.

The test extracts the exact pure-C oracle from ``field_gpu_test.c`` and runs it
against deterministic fixture records. It also guards the GPU regression's
sample eligibility thresholds without starting EGL, a compositor, or a socket.
"""

from __future__ import annotations

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCE = REPO / "tests" / "ubuntu" / "field_gpu_test.c"
BEGIN_MARKER = "/* FIELD_TEXT_BLEND_BEGIN"
END_MARKER = "/* FIELD_TEXT_BLEND_END */"


HARNESS_PREFIX = r"""
#include <assert.h>
#include <math.h>
#include <stddef.h>

"""


HARNESS_MAIN = r"""
static void set_common(double *q, double x, double y, double width,
                       double height, double red, double green, double blue,
                       double alpha, double opacity, double clip_x,
                       double clip_y, double clip_width, double clip_height) {
  for (int i = 0; i < 19; ++i) q[i] = 0.0;
  q[0] = x; q[1] = y; q[2] = width; q[3] = height;
  q[4] = red; q[5] = green; q[6] = blue; q[7] = alpha;
  q[8] = q[11] = 1.0;
  q[14] = opacity;
  q[15] = clip_x; q[16] = clip_y;
  q[17] = clip_width; q[18] = clip_height;
}

static void expect_rgb(const double *selection, double sx, double sy,
                       const double *text, double coverage,
                       int red, int green, int blue) {
  int actual[3] = {-1, -1, -1};
  expected_field_text_rgb(selection, sx, sy, text, coverage, actual);
  assert(actual[0] == red && actual[1] == green && actual[2] == blue);
}

int main(void) {
  double selection[19], text[19];
  set_common(selection, 36.0, 32.0, 42.0, 21.0,
             65.0, 105.0, 225.0, 80.0, 1.0,
             36.0, 32.0, 172.0, 36.0);
  set_common(text, 0.0, 0.0, 100.0, 100.0,
             20.0, 24.0, 30.0, 255.0, 1.0,
             0.0, 0.0, 100.0, 100.0);

  /* A half-covered dark glyph must blend over the semitransparent selection,
   * at device-pixel centers for both supported fixture scales. */
  for (int scale = 1; scale <= 2; ++scale) {
    double sx = (40 * scale + 0.5) / scale;
    double sy = (40 * scale + 0.5) / scale;
    expect_rgb(selection, sx, sy, text, 0.5, 108, 116, 138);

    /* Mirror assert_text_coverage's two unchanged coverage gates for a
     * fully-inked sample inside the fully selected run. The source guard below
     * ties this positive count to the real GPU scan's no-selection-skip path. */
    int found = 0, compared = 0;
    double full_coverage = 1.0;
    if (sx >= selection[0] && sx < selection[0] + selection[2] &&
        sy >= selection[1] && sy < selection[1] + selection[3] &&
        full_coverage >= 0.82) {
      int pixel[3];
      expected_field_text_rgb(selection, sx, sy, text, full_coverage, pixel);
      if (pixel[0] < 105 && pixel[1] < 110 && pixel[2] < 120)
        ++found;
    }
    if (full_coverage >= 0.08)
      ++compared;
    assert(found > 0 && compared > 0);
  }

  /* Fully covered opaque text remains legible over a selected run. */
  expect_rgb(selection, 40.5, 40.5, text, 1.0, 20, 24, 30);
  text[7] = 128.0;
  expect_rgb(selection, 40.5, 40.5, text, 1.0, 107, 116, 137);
  text[7] = 255.0;

  /* Outside the selection rectangle, and inside its rectangle but outside its
   * clip, the field background stays white before text is composited. */
  expect_rgb(selection, 90.5, 40.5, text, 0.5, 138, 140, 143);
  selection[15] = 36.0;
  selection[17] = 5.0;
  expect_rgb(selection, 50.5, 40.5, text, 0.5, 138, 140, 143);

  /* A zero-alpha selection cannot tint the field background. */
  selection[17] = 172.0;
  selection[7] = 0.0;
  expect_rgb(selection, 40.5, 40.5, text, 0.5, 138, 140, 143);
  return 0;
}
"""


def extract_marked_helper() -> str:
    source = SOURCE.read_text(encoding="utf-8")
    if source.count(BEGIN_MARKER) != 1 or source.count(END_MARKER) != 1:
        raise AssertionError("field-text-blend helper markers must each appear exactly once")
    begin = source.index(BEGIN_MARKER)
    end = source.index(END_MARKER, begin)
    if end <= begin:
        raise AssertionError("field-text-blend helper markers are out of order")
    block = source[begin:end + len(END_MARKER)]
    if "expected_field_text_rgb" not in block:
        raise AssertionError("marked block does not contain the expected RGB helper")
    return block


def function_body(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening + 1:index]
    raise AssertionError(f"unterminated function body for {signature}")


def if_blocks(source: str):
    """Yield C if-condition/body pairs for the small source-level guard below."""
    for match in re.finditer(r"\bif\s*\(", source):
        start = match.end()
        depth = 1
        index = start
        while index < len(source) and depth:
            depth += (source[index] == "(") - (source[index] == ")")
            index += 1
        if depth:
            raise AssertionError("unbalanced if condition in assert_text_coverage")
        condition = source[start:index - 1]
        while index < len(source) and source[index].isspace():
            index += 1
        if index < len(source) and source[index] == "{":
            opening = index
            brace_depth = 0
            while index < len(source):
                brace_depth += (source[index] == "{") - (source[index] == "}")
                index += 1
                if brace_depth == 0:
                    yield condition, source[opening + 1:index - 1]
                    break
        else:
            end = source.find(";", index)
            if end >= 0:
                yield condition, source[index:end + 1]


class FieldTextBlendTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        compiler = os.environ.get("CC", "cc")
        if not shutil.which(compiler):
            raise RuntimeError(f"C compiler not found: {compiler}")
        build_root = REPO.parent / "tmp"
        build_root.mkdir(parents=True, exist_ok=True)
        cls._temporary = tempfile.TemporaryDirectory(
            prefix="field-text-blend-", dir=build_root
        )
        build_dir = Path(cls._temporary.name)
        harness = build_dir / "field_text_blend_harness.c"
        executable = build_dir / "field_text_blend_harness"
        harness.write_text(
            HARNESS_PREFIX + extract_marked_helper() + "\n" + HARNESS_MAIN,
            encoding="utf-8",
        )
        result = subprocess.run(
            [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O0",
             str(harness), "-lm", "-o", str(executable)],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AssertionError(
                "failed to compile extracted field-text-blend helper:\n" + result.stderr
            )
        cls._executable = executable

    @classmethod
    def tearDownClass(cls) -> None:
        if hasattr(cls, "_temporary"):
            cls._temporary.cleanup()

    def test_selected_text_rgb_matches_independent_cpu_oracle(self) -> None:
        result = subprocess.run(
            [str(self._executable)], capture_output=True, text=True, timeout=5
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_gpu_oracle_keeps_selected_samples_and_nonzero_thresholds(self) -> None:
        source = SOURCE.read_text(encoding="utf-8")
        body = function_body(source, "static void assert_text_coverage(")
        self.assertIn("expected_field_text_rgb", body)
        self.assertIn("coverage < 0.82", body)
        self.assertIn("coverage < 0.08", body)
        self.assertRegex(body, r"assert\s*\(\s*found\s*\)\s*;")
        self.assertRegex(body, r"assert\s*\(\s*compared\s*>\s*0\s*\)\s*;")

        for condition, statement in if_blocks(body):
            if re.search(r"\b(?:selected|selection)\b", condition):
                self.assertNotRegex(
                    statement,
                    r"\bcontinue\s*;",
                    "selected text pixels must remain eligible for RGB comparison",
                )


if __name__ == "__main__":
    unittest.main()
