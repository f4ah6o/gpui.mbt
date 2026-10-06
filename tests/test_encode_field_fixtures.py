import hashlib
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import encode_field_fixtures as encoder  # noqa: E402


IDENTITY = {"a": 1, "b": 0, "c": 0, "d": 1, "tx": 0, "ty": 0}


def rect(x, y, width, height):
    return {"x": x, "y": y, "width": width, "height": height}


def item(kind, item_id, bounds, color, *, text=None, font_size=None, clip=None,
         transform=None, text_origin=None):
    value = {
        "kind": kind,
        "id": item_id,
        "bounds": bounds,
        "color": dict(zip(("red", "green", "blue", "alpha"), color)),
        "transform": transform or dict(IDENTITY),
        "opacity": 1,
        "clip_chain_id": clip,
    }
    if kind == "text":
        value["text"] = text
        value["font_size"] = font_size
    if kind == "text_run":
        value["text_origin"] = text_origin
        value["text"] = text
        value["font_size"] = font_size
    return value


def reference_scene():
    # Deliberately hand-authored independently of the encoder output.
    return {
        "schema_version": 1,
        "viewport": rect(0, 0, 640, 240),
        "scale": 1,
        "resources": [],
        "clip_chains": [
            {"id": 7, "rects": [rect(36, 32, 172, 36), rect(40, 30, 80, 50)]}
        ],
        "items": [
            item("quad", 1, rect(0, 0, 640, 240), (24, 28, 36, 255)),
            item("text", 106, rect(0, 0, 12, 18), (20, 24, 30, 255),
                 text="é", font_size=18, clip=7),
            item("quad", 107, rect(40, 32, 1, 18), (20, 24, 30, 255), clip=7),
        ],
    }


def field_scene(label, text, *, focused=True, selected=False, scrolled=False):
    items = [
        item("quad", 1, rect(0, 0, 640, 240), (24, 28, 36, 255)),
        item("quad", 100, rect(32, 28, 180, 44), (255, 255, 255, 255)),
    ]
    border = (55, 105, 220, 255) if focused else (130, 140, 150, 255)
    for item_id, bounds in zip(
        (101, 102, 103, 104),
        (rect(32, 28, 180, 1), rect(32, 71, 180, 1),
         rect(32, 28, 1, 44), rect(211, 28, 1, 44)),
    ):
        items.append(item("quad", item_id, bounds, border))
    if selected:
        items.append(item("quad", 105, rect(36, 32, 42, 21), (65, 105, 225, 80), clip=7))
    text_x = -300 if scrolled else 36
    items.append(item("text", 106, rect(0, 0, 350 if scrolled else 90, 22),
                      (20, 24, 30, 255), text=text, font_size=18, clip=7,
                      transform={"a": 1, "b": 0, "c": 0, "d": 1, "tx": text_x, "ty": 32}))
    if focused:
        caret_x = 207 if scrolled else (36 if selected else 84)
        items.append(item("quad", 107, rect(caret_x, 33, 1, 21), (20, 24, 30, 255), clip=7))
    return {
        "schema_version": 1,
        "viewport": rect(0, 0, 640, 240),
        "scale": 1,
        "resources": [],
        "clip_chains": [{"id": 7, "rects": [rect(36, 32, 172, 36)]}],
        "items": items,
    }


def seven_source_records():
    short = "Hi 日本"
    edited = "Edited 日本"
    long = "Wide 日本 " * 8
    configs = [
        ("end", short, True, False, False, len(short.encode("utf-16-le")) // 2,
         len(short.encode("utf-16-le")) // 2, False),
        ("selected", short, True, True, False, len(short.encode("utf-16-le")) // 2, 0, False),
        ("edited", edited, True, False, False, len(edited.encode("utf-16-le")) // 2,
         len(edited.encode("utf-16-le")) // 2, False),
        ("rejected_newline", edited, True, False, False, len(edited.encode("utf-16-le")) // 2,
         len(edited.encode("utf-16-le")) // 2, True),
        ("rejected_bidi", edited, True, False, False, len(edited.encode("utf-16-le")) // 2,
         len(edited.encode("utf-16-le")) // 2, True),
        ("scroll_end", long, True, False, True, len(long.encode("utf-16-le")) // 2,
         len(long.encode("utf-16-le")) // 2, False),
        ("blurred", long, False, False, True, len(long.encode("utf-16-le")) // 2,
         len(long.encode("utf-16-le")) // 2, False),
    ]
    return [
        {
            "label": label,
            "rejected": rejected,
            "revision": 3 if label in {"rejected_newline", "rejected_bidi"} else index + 1,
            "anchor": anchor,
            "head": head,
            "scene": field_scene(label, text, focused=focused, selected=selected, scrolled=scrolled),
        }
        for index, (label, text, focused, selected, scrolled, anchor, head, rejected)
        in enumerate(configs)
    ]


def origin_field_scene(label, text, *, focused=True, selected=False, scrolled=False,
                       origin=(1.25, 2.5)):
    scene = field_scene(label, text, focused=focused, selected=selected,
                        scrolled=scrolled)
    for scene_item in scene["items"]:
        if scene_item["kind"] == "text":
            scene_item["kind"] = "text_run"
            scene_item["text_origin"] = {"x": origin[0], "y": origin[1]}
            break
    return scene


def origin_source_records():
    # Preserve all original controls/rejection fixtures while promoting their
    # scene leaves to TextRunItem. The four bearing controls are appended in
    # the same order as the control generator contract.
    records = seven_source_records()
    for record in records:
        text = next(scene_item for scene_item in record["scene"]["items"]
                    if scene_item["kind"] == "text")
        text["kind"] = "text_run"
        text["text_origin"] = {"x": 1.25, "y": 2.5}
    additions = [
        ("j_start", "jJ", False),
        ("accent_start", "ÁA\u0301", False),
        ("j_scroll", "Wide 日本 " * 8 + "jJ", True),
        ("accent_scroll", "Wide " * 20 + "ÁA\u0301", True),
    ]
    for index, (label, text, scrolled) in enumerate(additions, start=8):
        records.append({
            "label": label,
            "rejected": False,
            "revision": index,
            "anchor": (0 if label in {"j_start", "accent_start"}
                       else len(text.encode("utf-16-le")) // 2),
            "head": (0 if label in {"j_start", "accent_start"}
                     else len(text.encode("utf-16-le")) // 2),
            "scene": origin_field_scene(label, text, scrolled=scrolled),
        })
    return records


def origin_reference_scene():
    # Mixed ABI3 frame: quad and legacy text preserve the old 23 fields with
    # zero origin slots, while text_run carries independent fractional origin.
    return {
        "schema_version": 1,
        "viewport": rect(0, 0, 640, 240),
        "scale": 1,
        "resources": [],
        "clip_chains": [
            {"id": 7, "rects": [rect(36, 32, 172, 36), rect(40, 30, 80, 50)]}
        ],
        "items": [
            item("quad", 1, rect(0, 0, 640, 240), (24, 28, 36, 255)),
            item("text", 106, rect(0, 0, 12, 18), (20, 24, 30, 255),
                 text="π", font_size=18, clip=7),
            item("text_run", 108, rect(1, 2, 12, 18), (20, 24, 30, 255),
                 text="é", font_size=18, clip=7,
                 text_origin={"x": 2.5, "y": -1.25}),
        ],
    }


class FieldFixtureEncoderTests(unittest.TestCase):
    def test_repeated_run_allocation_retains_previous_encoded_evidence(self):
        fixture_sets = [seven_source_records(), origin_source_records()]
        with tempfile.TemporaryDirectory(prefix="field rerun ") as temp:
            root = Path(temp) / "evidence with spaces"
            runs = []
            for records in fixture_sets:
                lines = [json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                         for record in records]
                for _ in range(2):
                    result = subprocess.run(
                        ["sh", str(ROOT / "scripts/create_field_fixture_run.sh"), str(root)],
                        text=True, capture_output=True, check=False,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    run = Path(result.stdout.strip())
                    self.assertTrue(run.is_absolute())
                    self.assertEqual(run.parent, root)
                    self.assertEqual(list(run.iterdir()), [])
                    self.assertEqual(run.stat().st_mode & 0o777, 0o700)
                    source = run / "fixtures.jsonl"
                    source.write_text("\n".join(lines) + "\n", encoding="utf-8")
                    encoder.build_fixture_set(source, run / "encoded", "a" * 40)
                    runs.append((run, lines))
            self.assertEqual(len({run for run, _ in runs}), 4)
            self.assertEqual(len(list(root.iterdir())), 4)
            for run, lines in runs:
                self.assertEqual((run / "fixtures.jsonl").read_text(encoding="utf-8"),
                                 "\n".join(lines) + "\n")
                self.assertEqual(len(list((run / "encoded/frames").iterdir())), len(lines))
                self.assertTrue((run / "encoded/manifest.json").is_file())

    def test_independent_binary_reference_includes_exact_utf8_and_clip_intersection(self):
        frame, doubles, blob = encoder.encode_scene(reference_scene())
        self.assertEqual(len(doubles), 5 + 3 * 23)
        self.assertEqual(blob, b"\xc3\xa9")
        # The expected 23-double records are hand-written from the v2 ABI.
        expected = [
            0, 0, 640, 240, 1,
            0, 0, 0, 640, 240, 24, 28, 36, 255, 1, 0, 0, 1, 0, 0, 1, 0, 0, 640, 240, 0, 0, 0,
            1, 0, 0, 12, 18, 20, 24, 30, 255, 1, 0, 0, 1, 0, 0, 1, 40, 32, 80, 36, 0, 2, 18,
            0, 40, 32, 1, 18, 20, 24, 30, 255, 1, 0, 0, 1, 0, 0, 1, 40, 32, 80, 36, 0, 0, 0,
        ]
        self.assertEqual(struct.unpack("<74d", frame[12:12 + 74 * 8]), tuple(expected))
        self.assertEqual(frame[:12], struct.pack("<4sII", b"GPF1", 74, 2))
        self.assertEqual(frame[-2:], b"\xc3\xa9")

    def test_independent_abi3_reference_encodes_kind_origin_and_zero_legacy_slots(self):
        frame, doubles, blob = encoder.encode_scene(origin_reference_scene())
        self.assertEqual(len(doubles), 5 + 3 * 25)
        self.assertEqual(blob, b"\xcf\x80\xc3\xa9")
        expected = [
            0, 0, 640, 240, 1,
            0, 0, 0, 640, 240, 24, 28, 36, 255, 1, 0, 0, 1, 0, 0, 1, 0, 0, 640, 240, 0, 0, 0, 0, 0,
            1, 0, 0, 12, 18, 20, 24, 30, 255, 1, 0, 0, 1, 0, 0, 1, 40, 32, 80, 36, 0, 2, 18, 0, 0,
            2, 1, 2, 12, 18, 20, 24, 30, 255, 1, 0, 0, 1, 0, 0, 1, 40, 32, 80, 36, 2, 2, 18, 2.5, -1.25,
        ]
        self.assertEqual(doubles, expected)
        self.assertEqual(frame[:12], struct.pack("<4sII", b"GPF2", 80, 4))
        self.assertEqual(struct.unpack("<80d", frame[12:12 + 80 * 8]), tuple(expected))
        self.assertEqual(frame[-4:], blob)

    def test_cli_keeps_each_source_line_and_emits_rejected_frames_identical_to_edit(self):
        records = seven_source_records()
        lines = [json.dumps(record, ensure_ascii=False, separators=(",", ":")) for record in records]
        source_head = "18e8fadf470823b389feff3b9d496213b4d3f67a"
        with tempfile.TemporaryDirectory() as temp:
            temp_path = Path(temp)
            source = temp_path / "field.jsonl"
            source.write_text("\n".join(lines) + "\n", encoding="utf-8")
            output = temp_path / "fixtures"
            result = subprocess.run(
                [sys.executable, str(ROOT / "scripts/encode_field_fixtures.py"),
                 str(source), "--output-dir", str(output), "--source-head", source_head],
                text=True, capture_output=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["source_head"], source_head)
            self.assertEqual(manifest["scene_identity"]["font_family"], "sans")
            self.assertEqual([entry["label"] for entry in manifest["fixtures"]], list(encoder.LABELS))
            for original, line in zip(manifest["fixtures"], lines):
                saved = (output / original["original"]).read_text(encoding="utf-8")
                self.assertEqual(saved, line + "\n")
                self.assertEqual(original["original_line_sha256"], hashlib.sha256(saved.encode()).hexdigest())
                self.assertEqual((output / original["frame"]).stat().st_mode & 0o777, 0o600)
            edited = (output / "frames/edited.gpf").read_bytes()
            self.assertEqual((output / "frames/rejected_newline.gpf").read_bytes(), edited)
            self.assertEqual((output / "frames/rejected_bidi.gpf").read_bytes(), edited)
            self.assertEqual(result.stdout, "")

    def test_origin_cli_preserves_eleven_sources_and_rejection_identity(self):
        records = origin_source_records()
        lines = [json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                 for record in records]
        source_head = "b" * 40
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "field.jsonl"
            source.write_text("\n".join(lines) + "\n", encoding="utf-8")
            profile = ("source_head=" + source_head + "\n" +
                       "fontconfig=/tmp/profile.conf\n" +
                       "fc_match_request=sans\n" +
                       "fc_match_request=sans:charset=65e5\n" +
                       "font content hash fixture\n")
            (root / "font-profile.txt").write_text(profile, encoding="utf-8")
            output = root / "fixtures"
            encoder.build_fixture_set(source, output, source_head)
            manifest = json.loads((output / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["format"], "GPF2")
            self.assertEqual(manifest["abi"], 3)
            self.assertEqual(manifest["stride_doubles"], 25)
            self.assertEqual(manifest["source_head"], source_head)
            self.assertEqual(manifest["font_profile"], {
                "path": "../font-profile.txt",
                "sha256": hashlib.sha256(profile.encode()).hexdigest(),
            })
            self.assertEqual([entry["label"] for entry in manifest["fixtures"]],
                             list(encoder.ORIGIN_LABELS))
            for entry, line in zip(manifest["fixtures"], lines):
                self.assertEqual((output / entry["original"]).read_text(encoding="utf-8"),
                                 line + "\n")
                frame = (output / entry["frame"]).read_bytes()
                self.assertEqual(frame[:4], b"GPF2")
                self.assertEqual(entry["double_count"] % 25, 5)
            edited = (output / "frames/edited.gpf").read_bytes()
            self.assertEqual((output / "frames/rejected_newline.gpf").read_bytes(), edited)
            self.assertEqual((output / "frames/rejected_bidi.gpf").read_bytes(), edited)

    def test_rejects_a_font_profile_from_a_different_source_head(self):
        records = origin_source_records()
        lines = [json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                 for record in records]
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "field.jsonl"
            source.write_text("\n".join(lines) + "\n", encoding="utf-8")
            (root / "font-profile.txt").write_text("source_head=" + "c" * 40 + "\n",
                                                   encoding="utf-8")
            with self.assertRaisesRegex(encoder.FixtureError, "source_head does not match"):
                encoder.build_fixture_set(source, root / "fixtures", "b" * 40)

    def test_rejects_unknown_kind_and_malformed_origin_point(self):
        scene = origin_reference_scene()
        scene["items"][2]["text_origin"] = {"x": 0.5, "y": math.inf}
        with self.assertRaisesRegex(encoder.FixtureError, "text_origin.y must be finite"):
            encoder.encode_scene(scene)
        scene["items"][2]["text_origin"] = {"x": 0.5, "y": 0.25, "z": 3}
        with self.assertRaisesRegex(encoder.FixtureError, "text_origin fields differ"):
            encoder.encode_scene(scene)
        scene["items"][2]["text_origin"] = {"x": 0.5, "y": 0.25}
        scene["items"][2]["kind"] = "glyphs"
        with self.assertRaisesRegex(encoder.FixtureError, "kind must be quad or text"):
            encoder.encode_scene(scene)

    def test_rejects_bad_field_identity_duplicate_keys_bad_numbers_and_clip_refs(self):
        lines = [json.dumps(record, ensure_ascii=False, separators=(",", ":"))
                 for record in seven_source_records()]
        valid_head = "a" * 40
        bad = seven_source_records()
        bad[0]["scene"]["items"][1]["bounds"]["width"] = -1
        with self.assertRaisesRegex(encoder.FixtureError, "below 0"):
            encoder.encode_lines([json.dumps(record, ensure_ascii=False) for record in bad], valid_head)
        with self.assertRaisesRegex(encoder.FixtureError, "duplicate JSON object key"):
            encoder._json_line('{"label":"end","label":"edited"}', 1)
        with self.assertRaisesRegex(encoder.FixtureError, "non-finite"):
            encoder._json_line('{"bad":NaN}', 1)
        bad_clip = reference_scene()
        bad_clip["items"][1]["clip_chain_id"] = 8
        with self.assertRaisesRegex(encoder.FixtureError, "unknown clip chain"):
            encoder.encode_scene(bad_clip)
        oversize_text = reference_scene()
        oversize_text["items"][1]["text"] = "x" * 4097
        with self.assertRaisesRegex(encoder.FixtureError, "bounded UTF-8 range"):
            encoder.encode_scene(oversize_text)
        with self.assertRaisesRegex(encoder.FixtureError, "expected fixture label"):
            encoder.encode_lines([lines[1], *lines[1:]], valid_head)

    def test_intersects_nested_rect_clips_and_preserves_item_order(self):
        frame, doubles, blob = encoder.encode_scene(reference_scene())
        self.assertEqual(blob, "é".encode("utf-8"))
        first_quad = doubles[5:28]
        text = doubles[28:51]
        later_quad = doubles[51:74]
        self.assertEqual(first_quad[0], 0)  # first record remains the viewport quad
        self.assertEqual(text[0], 1)
        self.assertEqual(text[16:20], [40, 32, 80, 36])
        self.assertEqual(later_quad[0], 0)
        self.assertEqual(later_quad[20:23], [0, 0, 0])
        self.assertEqual(frame[-len(blob):], blob)

    def test_text_spans_use_utf8_byte_offsets_not_character_counts(self):
        scene = reference_scene()
        scene["items"].insert(
            2,
            item("text", 108, rect(0, 0, 12, 18), (20, 24, 30, 255),
                 text="π", font_size=18, clip=7),
        )
        frame, doubles, blob = encoder.encode_scene(scene)
        self.assertEqual(blob, b"\xc3\xa9\xcf\x80")
        second_text_record = doubles[5 + 2 * 23:5 + 3 * 23]
        self.assertEqual(second_text_record[20:23], [2, 2, 18])
        trailing_quad_record = doubles[5 + 3 * 23:5 + 4 * 23]
        self.assertEqual(trailing_quad_record[20:23], [0, 0, 0])
        self.assertEqual(frame[-4:], blob)


if __name__ == "__main__":
    unittest.main()
