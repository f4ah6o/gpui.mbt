#!/usr/bin/env python3
"""Encode retained Linux TextField scenes as bounded test-only GPF1/GPF2 frames.

The input scene is kept byte-for-byte in ``originals/``. The binary frame is a
private replay aid for the Ubuntu GLES test, not a wire/input protocol. Legacy
text-only scenes retain GPF1/ABI2 bytes; scenes with ``text_run`` use GPF2/ABI3.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import struct
import sys
from typing import Any


LEGACY_LABELS = (
    "end",
    "selected",
    "edited",
    "rejected_newline",
    "rejected_bidi",
    "scroll_end",
    "blurred",
)
ORIGIN_LABELS = LEGACY_LABELS + (
    "j_start",
    "accent_start",
    "j_scroll",
    "accent_scroll",
)
# Keep LABELS as the original seven-label contract for downstream users and
# tests that construct the pre-origin control fixtures.
LABELS = LEGACY_LABELS
REJECTED_LABELS = {"rejected_newline", "rejected_bidi"}
MAGIC_V1 = b"GPF1"
MAGIC_V2 = b"GPF2"
HEADER = struct.Struct("<4sII")
DOUBLE = struct.Struct("<d")
MAX_JSONL_BYTES = 2 * 1024 * 1024
MAX_TEXT_BYTES = 1024 * 1024
MAX_SCENE_TEXT_BYTES = 4096
MAX_ITEMS = 100_000
MAX_TEXT_ITEMS = 256
SOURCE_HEAD_RE = re.compile(r"^[0-9a-fA-F]{40,64}$")


class FixtureError(ValueError):
    """Input fixture is malformed or outside the bounded test contract."""


def _pairs_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise FixtureError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> None:
    raise FixtureError(f"non-finite JSON number: {value}")


def _object(value: Any, where: str, expected: set[str] | None = None) -> dict[str, Any]:
    if not isinstance(value, dict) or any(not isinstance(k, str) for k in value):
        raise FixtureError(f"{where} must be an object")
    if expected is not None and set(value) != expected:
        missing = sorted(expected - set(value))
        extra = sorted(set(value) - expected)
        raise FixtureError(f"{where} fields differ (missing={missing}, extra={extra})")
    return value


def _integer(value: Any, where: str, *, minimum: int = 0, maximum: int = 2**53 - 1) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise FixtureError(f"{where} must be an integer in [{minimum}, {maximum}]")
    return value


def _number(value: Any, where: str, *, minimum: float | None = None,
            maximum: float | None = None) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise FixtureError(f"{where} must be a number")
    number = float(value)
    if not math.isfinite(number):
        raise FixtureError(f"{where} must be finite")
    if minimum is not None and number < minimum:
        raise FixtureError(f"{where} is below {minimum}")
    if maximum is not None and number > maximum:
        raise FixtureError(f"{where} is above {maximum}")
    return 0.0 if number == 0.0 else number


def _rect(value: Any, where: str) -> tuple[float, float, float, float]:
    rect = _object(value, where, {"x", "y", "width", "height"})
    return (
        _number(rect["x"], f"{where}.x", minimum=-1e7, maximum=1e7),
        _number(rect["y"], f"{where}.y", minimum=-1e7, maximum=1e7),
        _number(rect["width"], f"{where}.width", minimum=0, maximum=1e7),
        _number(rect["height"], f"{where}.height", minimum=0, maximum=1e7),
    )


def _point(value: Any, where: str) -> tuple[float, float]:
    point = _object(value, where, {"x", "y"})
    return (
        _number(point["x"], f"{where}.x", minimum=-1e7, maximum=1e7),
        _number(point["y"], f"{where}.y", minimum=-1e7, maximum=1e7),
    )


def _color(value: Any, where: str) -> tuple[int, int, int, int]:
    color = _object(value, where, {"red", "green", "blue", "alpha"})
    return tuple(_integer(color[channel], f"{where}.{channel}", maximum=255)
                 for channel in ("red", "green", "blue", "alpha"))  # type: ignore[return-value]


def _transform(value: Any, where: str) -> tuple[float, float, float, float, float, float]:
    names = ("a", "b", "c", "d", "tx", "ty")
    transform = _object(value, where, set(names))
    return tuple(_number(transform[name], f"{where}.{name}", minimum=-1e7, maximum=1e7)
                 for name in names)  # type: ignore[return-value]


def _json_line(raw: str, line_number: int) -> dict[str, Any]:
    try:
        result = json.loads(
            raw,
            object_pairs_hook=_pairs_no_duplicates,
            parse_constant=_reject_constant,
        )
    except (json.JSONDecodeError, FixtureError) as exc:
        raise FixtureError(f"line {line_number}: invalid JSON: {exc}") from exc
    return _object(result, f"line {line_number}")


def _validate_scene(
    scene_value: Any, label: str, *, field_fixture: bool = False
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    scene = _object(scene_value, f"{label}.scene", {
        "schema_version", "viewport", "scale", "resources", "clip_chains", "items"
    })
    if _integer(scene["schema_version"], f"{label}.scene.schema_version") != 1:
        raise FixtureError(f"{label}: only scene schema version 1 is supported")
    viewport = _rect(scene["viewport"], f"{label}.scene.viewport")
    if field_fixture and viewport != (0.0, 0.0, 640.0, 240.0):
        raise FixtureError(f"{label}: original viewport must be 640x240 at (0,0)")
    scale = _number(scene["scale"], f"{label}.scene.scale", minimum=0.000001, maximum=1024)
    if field_fixture and scale != 1.0:
        raise FixtureError(f"{label}: source fixture scale must remain 1 before host normalization")
    if scene["resources"] != []:
        raise FixtureError(f"{label}: resource-backed items are not supported")
    clip_values = scene["clip_chains"]
    if not isinstance(clip_values, list) or len(clip_values) > MAX_ITEMS:
        raise FixtureError(f"{label}: clip_chains must be a bounded array")
    chains: dict[int, list[tuple[float, float, float, float]]] = {}
    for chain_index, chain_value in enumerate(clip_values):
        chain = _object(chain_value, f"{label}.scene.clip_chains[{chain_index}]", {"id", "rects"})
        chain_id = _integer(chain["id"], f"{label}.scene.clip_chains[{chain_index}].id")
        if chain_id in chains:
            raise FixtureError(f"{label}: duplicate clip chain ID {chain_id}")
        rect_values = chain["rects"]
        if not isinstance(rect_values, list) or len(rect_values) > 256:
            raise FixtureError(f"{label}: each clip chain must contain at most 256 rectangles")
        chains[chain_id] = [
            _rect(rect, f"{label}.scene.clip_chains[{chain_index}].rects[{rect_index}]")
            for rect_index, rect in enumerate(rect_values)
        ]
    if field_fixture:
        if len(chains) != 1 or 7 not in chains or chains[7] != [(36.0, 32.0, 172.0, 36.0)]:
            raise FixtureError(f"{label}: expected content clip ID 7 with bounds (36,32,172,36)")

    items_value = scene["items"]
    if not isinstance(items_value, list) or not 1 <= len(items_value) <= MAX_ITEMS:
        raise FixtureError(f"{label}: item list must contain 1..{MAX_ITEMS} items")
    items: list[dict[str, Any]] = []
    ids: set[int] = set()
    text_count = 0
    for index, item_value in enumerate(items_value):
        item = _object(item_value, f"{label}.items[{index}]")
        kind = item.get("kind")
        if kind == "quad":
            expected = {"kind", "id", "bounds", "color", "transform", "opacity", "clip_chain_id"}
        elif kind == "text":
            expected = {"kind", "id", "bounds", "text", "font_size", "color", "transform", "opacity", "clip_chain_id"}
            text_count += 1
            if text_count > MAX_TEXT_ITEMS:
                raise FixtureError(f"{label}: too many text items")
        elif kind == "text_run":
            expected = {"kind", "id", "bounds", "text_origin", "text", "font_size", "color", "transform", "opacity", "clip_chain_id"}
            text_count += 1
            if text_count > MAX_TEXT_ITEMS:
                raise FixtureError(f"{label}: too many text items")
        else:
            raise FixtureError(f"{label}.items[{index}].kind must be quad or text")
        _object(item, f"{label}.items[{index}]", expected)
        item_id = _integer(item["id"], f"{label}.items[{index}].id")
        if item_id in ids:
            raise FixtureError(f"{label}: duplicate item ID {item_id}")
        ids.add(item_id)
        bounds = _rect(item["bounds"], f"{label}.items[{index}].bounds")
        _color(item["color"], f"{label}.items[{index}].color")
        _transform(item["transform"], f"{label}.items[{index}].transform")
        _number(item["opacity"], f"{label}.items[{index}].opacity", minimum=0, maximum=1)
        clip_id = item["clip_chain_id"]
        if clip_id is not None and _integer(clip_id, f"{label}.items[{index}].clip_chain_id") not in chains:
            raise FixtureError(f"{label}.items[{index}] refers to an unknown clip chain")
        if kind in {"text", "text_run"}:
            if not isinstance(item["text"], str):
                raise FixtureError(f"{label}.items[{index}].text must be a string")
            try:
                encoded_text = item["text"].encode("utf-8", errors="strict")
            except UnicodeEncodeError as exc:
                raise FixtureError(f"{label}.items[{index}].text contains a lone surrogate") from exc
            if b"\x00" in encoded_text or len(encoded_text) > MAX_SCENE_TEXT_BYTES:
                raise FixtureError(f"{label}.items[{index}].text is outside the bounded UTF-8 range")
            if bounds[2] > 2048 or bounds[3] > 128:
                raise FixtureError(f"{label}.items[{index}].bounds exceeds the native text mask limits")
            _number(item["font_size"], f"{label}.items[{index}].font_size", minimum=0.000001, maximum=32)
            if kind == "text_run":
                _point(item["text_origin"], f"{label}.items[{index}].text_origin")
        items.append(item)
    return scene, items


def _field_contract(record: dict[str, Any], label: str) -> None:
    if set(record) != {"label", "rejected", "revision", "anchor", "head", "scene"}:
        raise FixtureError(f"{label}: fixture fields must be label,rejected,revision,anchor,head,scene")
    expected_rejected = label in REJECTED_LABELS
    if type(record["rejected"]) is not bool or record["rejected"] != expected_rejected:
        raise FixtureError(f"{label}: rejected flag does not match its fixture role")
    _integer(record["revision"], f"{label}.revision")
    anchor = _integer(record["anchor"], f"{label}.anchor", maximum=65536)
    head = _integer(record["head"], f"{label}.head", maximum=65536)
    scene, items = _validate_scene(record["scene"], label, field_fixture=True)
    del scene

    text_items = [item for item in items if item["kind"] in {"text", "text_run"}]
    if len(text_items) != 1 or text_items[0]["id"] != 106:
        raise FixtureError(f"{label}: expected one text item with ID 106")
    text = text_items[0]
    expected_text = {
        "end": "Hi 日本",
        "selected": "Hi 日本",
        "edited": "Edited 日本",
        "rejected_newline": "Edited 日本",
        "rejected_bidi": "Edited 日本",
        "scroll_end": "Wide 日本 " * 8,
        "blurred": "Wide 日本 " * 8,
        "j_start": "jJ",
        "accent_start": "ÁA\u0301",
        "j_scroll": "Wide 日本 " * 8 + "jJ",
        "accent_scroll": "Wide " * 20 + "ÁA\u0301",
    }[label]
    if text["text"] != expected_text or text["font_size"] != 18:
        raise FixtureError(f"{label}: text/font identity does not match the admitted sans 18px case")
    utf16_length = len(expected_text.encode("utf-16-le")) // 2
    if anchor > utf16_length or head > utf16_length:
        raise FixtureError(f"{label}: selection offset exceeds UTF-16 text length")
    if label == "selected":
        if (anchor, head) != (utf16_length, 0):
            raise FixtureError("selected: expected Shift+Home selection from end to start")
    elif anchor != head:
        raise FixtureError(f"{label}: expected a collapsed selection")
    if label in {"end", "selected"} and anchor != utf16_length:
        raise FixtureError(f"{label}: expected end caret/anchor")
    if label in {"j_start", "accent_start"} and anchor != 0:
        raise FixtureError(f"{label}: expected start caret/anchor")
    if label in {"scroll_end", "j_scroll", "accent_scroll"} and anchor != utf16_length:
        raise FixtureError(f"{label}: expected caret at the UTF-16 end")

    by_id = {item["id"]: item for item in items}
    expected_ids = {1, 100, 101, 102, 103, 104, 106}
    if label == "selected":
        expected_ids.add(105)
    if label != "blurred":
        expected_ids.add(107)
    if set(by_id) != expected_ids:
        raise FixtureError(f"{label}: item IDs/order do not match the bounded field paint contract")
    if [item["id"] for item in items] != [1, 100, 101, 102, 103, 104] + ([105] if label == "selected" else []) + [106] + ([107] if label != "blurred" else []):
        raise FixtureError(f"{label}: field paint item order changed")

    def assert_rect(item_id: int, rect: tuple[float, float, float, float]) -> dict[str, Any]:
        item = by_id[item_id]
        if _rect(item["bounds"], f"{label}.item[{item_id}].bounds") != rect:
            raise FixtureError(f"{label}: item {item_id} has unexpected geometry")
        return item

    bg = assert_rect(1, (0.0, 0.0, 640.0, 240.0))
    identity = (1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    if (_color(bg["color"], f"{label}.background.color") != (24, 28, 36, 255) or
            bg["clip_chain_id"] is not None or bg["opacity"] != 1 or
            _transform(bg["transform"], f"{label}.background.transform") != identity):
        raise FixtureError(f"{label}: unexpected viewport background color")
    field = assert_rect(100, (32.0, 28.0, 180.0, 44.0))
    if (_color(field["color"], f"{label}.field.color") != (255, 255, 255, 255) or
            field["clip_chain_id"] is not None or field["opacity"] != 1 or
            _transform(field["transform"], f"{label}.field.transform") != identity):
        raise FixtureError(f"{label}: field fill must be opaque white")
    border_color = (130, 140, 150, 255) if label == "blurred" else (55, 105, 220, 255)
    for item_id, rect in zip(
        (101, 102, 103, 104),
        ((32.0, 28.0, 180.0, 1.0), (32.0, 71.0, 180.0, 1.0),
         (32.0, 28.0, 1.0, 44.0), (211.0, 28.0, 1.0, 44.0)),
    ):
        border = assert_rect(item_id, rect)
        if (_color(border["color"], f"{label}.border.color") != border_color or
                border["clip_chain_id"] is not None or border["opacity"] != 1 or
                _transform(border["transform"], f"{label}.border.transform") != identity):
            raise FixtureError(f"{label}: border color does not match focus state")
    text_bounds = _rect(text["bounds"], f"{label}.text.bounds")
    text_transform = _transform(text["transform"], f"{label}.text.transform")
    if (_color(text["color"], f"{label}.text.color") != (20, 24, 30, 255) or
            text["opacity"] != 1 or text_bounds[0:2] != (0.0, 0.0) or
            text_transform[:4] != identity[:4] or text_transform[5] != 32.0):
        raise FixtureError(f"{label}: text ink color changed")
    if label in {"scroll_end", "blurred", "j_scroll", "accent_scroll"}:
        if text_transform[4] >= 36:
            raise FixtureError(f"{label}: expected horizontal scroll to keep text origin left")
    elif text_transform[4] != 36:
        raise FixtureError(f"{label}: unscrolled text origin must stay at content left")
    if text["clip_chain_id"] != 7:
        raise FixtureError(f"{label}: text must use content clip chain 7")
    if label == "selected":
        sel = by_id[105]
        selection_bounds = _rect(sel["bounds"], f"{label}.selection.bounds")
        if (sel["clip_chain_id"] != 7 or _color(sel["color"], f"{label}.selection.color") != (65, 105, 225, 80) or
                sel["opacity"] != 1 or _transform(sel["transform"], f"{label}.selection.transform") != identity or
                selection_bounds[0] < 36 or selection_bounds[1] < 32 or
                selection_bounds[0] + selection_bounds[2] > 208 or
                selection_bounds[1] + selection_bounds[3] > 68):
            raise FixtureError("selected: selection color/clip differs from the control policy")
    if label != "blurred":
        caret = by_id[107]
        if (caret["clip_chain_id"] != 7 or _color(caret["color"], f"{label}.caret.color") != (20, 24, 30, 255) or
                caret["opacity"] != 1 or _transform(caret["transform"], f"{label}.caret.transform") != identity):
            raise FixtureError(f"{label}: focused caret must be black and clipped")
        caret_rect = _rect(caret["bounds"], f"{label}.caret.bounds")
        if abs(caret_rect[2] - 1.0) > 1e-9 or not (32 <= caret_rect[0] < 208):
            raise FixtureError(f"{label}: caret must be one logical pixel inside content bounds")
    if label in {"scroll_end", "j_scroll", "accent_scroll"}:
        if abs(_rect(by_id[107]["bounds"], f"{label}.caret.bounds")[0] - 207.0) > 1e-8:
            raise FixtureError(f"{label}: one-pixel caret must sit just inside the content clip's right edge")


def _intersect(
    left: tuple[float, float, float, float], right: tuple[float, float, float, float]
) -> tuple[float, float, float, float] | None:
    x = max(left[0], right[0])
    y = max(left[1], right[1])
    r = min(left[0] + left[2], right[0] + right[2])
    b = min(left[1] + left[3], right[1] + right[3])
    if x > r or y > b:
        return None
    return (x, y, r - x, b - y)


def encode_scene(scene_value: Any) -> tuple[bytes, list[float], bytes]:
    """Encode a scene as legacy GPF1/ABI2 or origin GPF2/ABI3 binary data."""
    scene, items = _validate_scene(scene_value, "scene")
    viewport = _rect(scene["viewport"], "scene.viewport")
    chains: dict[int, list[tuple[float, float, float, float]]] = {
        _integer(chain["id"], "scene.clip_chain.id"): [
            _rect(rect, "scene.clip_chain.rect") for rect in chain["rects"]
        ]
        for chain in scene["clip_chains"]
    }

    origin_enabled = any(item["kind"] == "text_run" for item in items)
    stride = 25 if origin_enabled else 23
    magic = MAGIC_V2 if origin_enabled else MAGIC_V1
    doubles: list[float] = [viewport[0], viewport[1], viewport[2], viewport[3],
                            _number(scene["scale"], "scene.scale", minimum=0.000001, maximum=1024)]
    blob = bytearray()
    for item in items:
        item_kind = item["kind"]
        kind = 0 if item_kind == "quad" else (2 if item_kind == "text_run" else 1)
        bounds = _rect(item["bounds"], "item.bounds")
        color = _color(item["color"], "item.color")
        transform = _transform(item["transform"], "item.transform")
        opacity = _number(item["opacity"], "item.opacity", minimum=0, maximum=1)
        clip: tuple[float, float, float, float] | None = viewport
        clip_id = item["clip_chain_id"]
        if clip_id is not None:
            for rect in chains[_integer(clip_id, "item.clip_chain_id")]:
                if clip is not None:
                    clip = _intersect(clip, rect)
        if clip is None:
            clip = (0.0, 0.0, 0.0, 0.0)
        offset = 0
        text_length = 0
        font_size = 0.0
        if kind in {1, 2}:
            offset = len(blob)
            text_bytes = item["text"].encode("utf-8", errors="strict")
            if b"\x00" in text_bytes or len(text_bytes) > MAX_TEXT_BYTES - len(blob):
                raise FixtureError("combined UTF-8 frame text exceeds the bounded range")
            blob.extend(text_bytes)
            text_length = len(text_bytes)
            font_size = _number(item["font_size"], "item.font_size", minimum=0.000001, maximum=32)
        origin = _point(item["text_origin"], "item.text_origin") if kind == 2 else (0.0, 0.0)
        doubles.extend((float(kind), *bounds, *(float(channel) for channel in color),
                        *transform, opacity, *clip, float(offset), float(text_length), font_size,
                        *(origin if origin_enabled else ())))
    if len(doubles) != 5 + stride * len(items):
        raise FixtureError("internal error: mixed-frame stride mismatch")
    if len(doubles) > 5 + stride * MAX_ITEMS:
        raise FixtureError("frame exceeds native item limit")
    data = b"".join(DOUBLE.pack(0.0 if number == 0.0 else number) for number in doubles)
    frame = HEADER.pack(magic, len(doubles), len(blob)) + data + bytes(blob)
    return frame, doubles, bytes(blob)


def encode_lines(lines: list[str], source_head: str) -> list[dict[str, Any]]:
    if not SOURCE_HEAD_RE.fullmatch(source_head):
        raise FixtureError("--source-head must be a full 40-64 digit git object ID")
    if len(lines) == len(LEGACY_LABELS):
        expected_labels = LEGACY_LABELS
        origin_fixture_set = False
    elif len(lines) == len(ORIGIN_LABELS):
        expected_labels = ORIGIN_LABELS
        origin_fixture_set = True
    else:
        raise FixtureError(
            f"expected exactly {len(LEGACY_LABELS)} legacy or {len(ORIGIN_LABELS)} origin source lines, got {len(lines)}"
        )
    decoded: list[dict[str, Any]] = []
    for index, raw in enumerate(lines):
        if not raw.strip():
            raise FixtureError(f"line {index + 1}: blank records are not allowed")
        record = _json_line(raw, index + 1)
        label = record.get("label")
        expected_label = expected_labels[index]
        if label != expected_label:
            raise FixtureError(f"line {index + 1}: expected fixture label {expected_label!r}, got {label!r}")
        _field_contract(record, expected_label)
        run_item = next(item for item in record["scene"]["items"]
                        if item["id"] == 106)
        if origin_fixture_set and run_item["kind"] != "text_run":
            raise FixtureError(f"{expected_label}: origin fixture sets require text_run items")
        if not origin_fixture_set and run_item["kind"] != "text":
            raise FixtureError(f"{expected_label}: legacy fixture sets require text items")
        decoded.append(record)
    edited = decoded[2]
    for label in ("rejected_newline", "rejected_bidi"):
        candidate = decoded[LABELS.index(label)]
        for field in ("revision", "anchor", "head", "scene"):
            if candidate[field] != edited[field]:
                raise FixtureError(f"{label}: rejected edit must preserve exact edited {field}")
    scrolling = decoded[LABELS.index("scroll_end")]["scene"]
    blurred = decoded[LABELS.index("blurred")]["scene"]
    scroll_text = next(item for item in scrolling["items"] if item["id"] == 106)
    blur_text = next(item for item in blurred["items"] if item["id"] == 106)
    if blur_text != scroll_text:
        raise FixtureError("blurred: existing long text pixels/transform must be retained")
    return decoded


def _write_private(path: Path, content: bytes) -> None:
    with path.open("xb") as stream:
        stream.write(content)
    os.chmod(path, 0o600)


def build_fixture_set(input_path: Path, output_dir: Path, source_head: str) -> Path:
    raw_input = input_path.read_bytes()
    if len(raw_input) > MAX_JSONL_BYTES:
        raise FixtureError(f"JSONL input exceeds {MAX_JSONL_BYTES} bytes")
    try:
        raw_text = raw_input.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise FixtureError("JSONL must be UTF-8") from exc
    lines = raw_text.splitlines()
    if len(lines) not in {len(LEGACY_LABELS), len(ORIGIN_LABELS)}:
        raise FixtureError(
            f"expected {len(LEGACY_LABELS)} legacy or {len(ORIGIN_LABELS)} origin JSONL records, got {len(lines)}"
        )
    decoded = encode_lines(lines, source_head)
    if output_dir.exists() and (not output_dir.is_dir() or any(output_dir.iterdir())):
        raise FixtureError("--output-dir must be absent or an empty directory")
    output_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(output_dir, 0o700)
    frames_dir = output_dir / "frames"
    originals_dir = output_dir / "originals"
    frames_dir.mkdir(mode=0o700)
    originals_dir.mkdir(mode=0o700)
    manifest_records: list[dict[str, Any]] = []
    for raw, record in zip(lines, decoded):
        label = record["label"]
        source_line = (raw + "\n").encode("utf-8")
        frame, doubles, blob = encode_scene(record["scene"])
        frame_name = f"{label}.gpf"
        original_name = f"{label}.jsonl"
        _write_private(frames_dir / frame_name, frame)
        _write_private(originals_dir / original_name, source_line)
        manifest_records.append({
            "label": label,
            "rejected": record["rejected"],
            "revision": record["revision"],
            "anchor": record["anchor"],
            "head": record["head"],
            "frame": f"frames/{frame_name}",
            "frame_sha256": hashlib.sha256(frame).hexdigest(),
            "double_count": len(doubles),
            "utf8_byte_count": len(blob),
            "original": f"originals/{original_name}",
            "original_line_sha256": hashlib.sha256(source_line).hexdigest(),
        })
    origin_enabled = any(item["kind"] == "text_run"
                         for record in decoded for item in record["scene"]["items"])
    abi = 3 if origin_enabled else 2
    stride = 25 if origin_enabled else 23
    format_magic = "GPF2" if origin_enabled else "GPF1"
    manifest = {
        "format": format_magic,
        "format_header": "little-endian <4sII> magic,double_count,utf8_byte_count",
        "record": f"little-endian float64 ABI{abi} mixed frame followed by exact UTF-8 blob",
        "abi": abi,
        "stride_doubles": stride,
        "source_head": source_head.lower(),
        "scene_identity": {"viewport": [0, 0, 640, 240], "field_bounds": [32, 28, 180, 44],
                           "content_clip": [36, 32, 172, 36], "font_family": "sans", "font_size": 18},
        "replay_scope": "test-only injected control-to-renderer evidence; not wire typing or a keyboard/IME claim",
        "fixtures": manifest_records,
    }
    profile_path = input_path.parent / "font-profile.txt"
    if profile_path.is_file():
        profile_bytes = profile_path.read_bytes()
        try:
            profile_text = profile_bytes.decode("utf-8", errors="strict")
        except UnicodeDecodeError as exc:
            raise FixtureError("font-profile.txt must be UTF-8") from exc
        if f"source_head={source_head.lower()}" not in profile_text:
            raise FixtureError("font-profile.txt source_head does not match --source-head")
        manifest["font_profile"] = {
            "path": "../font-profile.txt",
            "sha256": hashlib.sha256(profile_bytes).hexdigest(),
        }
    manifest_bytes = (json.dumps(manifest, ensure_ascii=False, sort_keys=True,
                                 separators=(",", ":")) + "\n").encode("utf-8")
    _write_private(output_dir / "manifest.json", manifest_bytes)
    return output_dir / "manifest.json"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_jsonl", type=Path, help="the actual control + real-sans CLI JSONL output")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--source-head", required=True, help="exact git HEAD used to produce the source scenes")
    args = parser.parse_args(argv)
    try:
        manifest = build_fixture_set(args.input_jsonl, args.output_dir, args.source_head)
    except (FixtureError, OSError) as exc:
        print(f"encode_field_fixtures: {exc}", file=sys.stderr)
        return 2
    # Keep stdout machine-quiet: the source CLI's JSONL stays the only fixture
    # stream; this diagnostic is limited to stderr for test orchestration.
    manifest_data = json.loads(manifest.read_text(encoding="utf-8"))
    print(f"{manifest_data['format']} manifest={manifest} fixtures={len(manifest_data['fixtures'])} source_head={args.source_head}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
