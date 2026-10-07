#!/usr/bin/env python3
"""Drive the finite Kotoeri acceptance app and retain own-window pixel evidence."""

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import platform
import queue
import re
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
import zlib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
APP_TITLE = "gpui.mbt experimental macOS TextField"
MAX_CAPTURE_BYTES = 64 * 1024 * 1024
MAX_DECODED_BYTES = 64 * 1024 * 1024
FRAME_IDENTITY_FIELDS = {"schema_version", "window_id", "host_epoch", "session_epoch", "batch_sequence",
                         "accepted_revision", "frame_revision", "frame_sha256", "text"}
KOTOERI_JAPANESE_ROMAJI_SOURCE_IDS = frozenset({
    # AppKit reports the active Hiragana mode as an input-source ID, not the
    # containing RomajiTyping input-method bundle ID.
    "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese",
})


class AcceptanceError(RuntimeError):
    pass


def is_supported_kotoeri_japanese_romaji_source(value):
    return type(value) is str and value in KOTOERI_JAPANESE_ROMAJI_SOURCE_IDS


def digest(path):
    value = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def source_snapshot(repo):
    def git(*args):
        return subprocess.check_output(["git", *args], cwd=repo, timeout=20)
    inputs = hashlib.sha256()
    names = git("ls-files", "--cached", "--others", "--exclude-standard", "-z").split(b"\0")
    for raw in sorted(name for name in names if name):
        path = repo / os.fsdecode(raw)
        inputs.update(raw + b"\0")
        if path.is_symlink():
            inputs.update(b"link\0" + os.fsencode(path.readlink()))
        elif path.is_file():
            inputs.update(b"file\0" + hashlib.sha256(path.read_bytes()).digest())
        else:
            inputs.update(b"missing\0")
    return {"commit": git("rev-parse", "HEAD").decode().strip(),
            "tree": git("rev-parse", "HEAD^{tree}").decode().strip(),
            "tracked_patch_sha256": hashlib.sha256(git("diff", "--binary", "HEAD")).hexdigest(),
            "input_files_sha256": inputs.hexdigest(),
            "status": git("status", "--porcelain", "--untracked-files=all").decode()}


def load_profile():
    spec = importlib.util.spec_from_file_location("gpui_macos_acceptance_profile", HERE / "profile.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def strict_json(value):
    def pairs(items):
        result = {}
        for key, item in items:
            if key in result:
                raise AcceptanceError("app emitted a duplicate JSON key: " + key)
            result[key] = item
        return result
    def reject(value):
        raise AcceptanceError("app emitted non-finite JSON value: " + value)
    return json.loads(value, object_pairs_hook=pairs, parse_constant=reject)


def png_pixels(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_CAPTURE_BYTES:
        raise AcceptanceError("captured PNG is missing, a symlink, or over the size limit")
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise AcceptanceError("own-window capture is not a PNG file")
    offset, header, palette, transparency = 8, None, None, None
    compressed = bytearray()
    seen_end = False
    while offset < len(data):
        if offset + 12 > len(data):
            raise AcceptanceError("PNG chunk header is truncated")
        size = struct.unpack_from(">I", data, offset)[0]
        if size > MAX_CAPTURE_BYTES or offset + 12 + size > len(data):
            raise AcceptanceError("PNG chunk size is malformed")
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + size]
        expected_crc = struct.unpack_from(">I", data, offset + 8 + size)[0]
        if zlib.crc32(kind + payload) & 0xffffffff != expected_crc:
            raise AcceptanceError("PNG chunk checksum failed")
        if kind == b"IHDR":
            if header is not None or size != 13:
                raise AcceptanceError("PNG must contain one valid header")
            header = struct.unpack(">IIBBBBB", payload)
        elif kind == b"PLTE":
            palette = payload
        elif kind == b"tRNS":
            transparency = payload
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            if size != 0:
                raise AcceptanceError("PNG end chunk is malformed")
            seen_end = True
            offset += 12
            break
        offset += size + 12
    if not seen_end or offset != len(data) or header is None:
        raise AcceptanceError("PNG has no canonical IEND or has trailing bytes")
    width, height, depth, color, compression, filtering, interlace = header
    if not 1 <= width <= 20000 or not 1 <= height <= 20000 or width * height > 12_000_000 or \
       depth != 8 or compression != 0 or filtering != 0 or interlace != 0:
        raise AcceptanceError("PNG uses unsupported dimensions/encoding for pixel verification")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    if channels is None or color == 3 and (not palette or len(palette) % 3):
        raise AcceptanceError("PNG has an unsupported color type/palette")
    stride = width * channels
    expected_raw = height * (stride + 1)
    if expected_raw > MAX_DECODED_BYTES:
        raise AcceptanceError("PNG decoded pixels exceed the bounded evidence limit")
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(bytes(compressed), expected_raw + 1)
        if len(raw) <= expected_raw:
            raw += decoder.flush(expected_raw + 1 - len(raw))
    except zlib.error as error:
        raise AcceptanceError("PNG pixel stream is invalid: " + str(error)) from None
    if len(raw) != expected_raw or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise AcceptanceError("PNG decoded pixel length differs from its dimensions")
    reconstructed = bytearray(height * stride)
    source = 0
    for y in range(height):
        mode = raw[source]
        source += 1
        row_start = y * stride
        for x in range(stride):
            left = reconstructed[row_start + x - channels] if x >= channels else 0
            above = reconstructed[row_start - stride + x] if y else 0
            upper_left = reconstructed[row_start - stride + x - channels] if y and x >= channels else 0
            value = raw[source]
            source += 1
            if mode == 1:
                value += left
            elif mode == 2:
                value += above
            elif mode == 3:
                value += (left + above) // 2
            elif mode == 4:
                predictor = left + above - upper_left
                pa, pb, pc = abs(predictor - left), abs(predictor - above), abs(predictor - upper_left)
                value += left if pa <= pb and pa <= pc else above if pb <= pc else upper_left
            elif mode != 0:
                raise AcceptanceError("PNG uses an invalid scanline filter")
            reconstructed[row_start + x] = value & 0xff
    if color == 3:
        normalized = bytearray(width * height * 4)
        for index, palette_index in enumerate(reconstructed):
            offset = palette_index * 3
            if offset + 2 >= len(palette):
                raise AcceptanceError("PNG palette index is outside PLTE")
            target = index * 4
            normalized[target:target + 4] = bytes((palette[offset], palette[offset + 1], palette[offset + 2],
                                                  transparency[palette_index] if transparency and palette_index < len(transparency) else 255))
        pixels = bytes(normalized)
    elif color in (0, 2):
        normalized = bytearray(width * height * 4)
        for index in range(width * height):
            if color == 0:
                gray = reconstructed[index]
                rgb = (gray, gray, gray)
            else:
                rgb = tuple(reconstructed[index * 3:index * 3 + 3])
            normalized[index * 4:index * 4 + 4] = bytes((*rgb, 255))
        pixels = bytes(normalized)
    elif color == 4:
        normalized = bytearray(width * height * 4)
        for index in range(width * height):
            gray, alpha = reconstructed[index * 2:index * 2 + 2]
            normalized[index * 4:index * 4 + 4] = bytes((gray, gray, gray, alpha))
        pixels = bytes(normalized)
    else:
        pixels = bytes(reconstructed)
    return {"width": width, "height": height, "pixels": pixels,
            "pixel_sha256": hashlib.sha256(pixels).hexdigest(), "file_sha256": hashlib.sha256(data).hexdigest(),
            "file_size": len(data), "png_encoding": {"bit_depth": depth, "color_type": color}}


def pixel_difference(before, after):
    if (before["width"], before["height"]) != (after["width"], after["height"]):
        raise AcceptanceError("own-window captures changed dimensions during one acceptance run")
    first, second = before["pixels"], after["pixels"]
    width, height = before["width"], before["height"]
    changed, bounds = 0, [width, height, -1, -1]
    for index in range(width * height):
        pos = index * 4
        if first[pos:pos + 4] != second[pos:pos + 4]:
            changed += 1
            x, y = index % width, index // width
            bounds[0], bounds[1] = min(bounds[0], x), min(bounds[1], y)
            bounds[2], bounds[3] = max(bounds[2], x), max(bounds[3], y)
    rect = None if not changed else {"left": bounds[0], "top": bounds[1],
                                     "right": bounds[2] + 1, "bottom": bounds[3] + 1}
    return {"changed_pixels": changed, "changed_fraction": changed / (width * height), "bounds": rect,
            "before_pixels_sha256": before["pixel_sha256"], "after_pixels_sha256": after["pixel_sha256"]}


def prepare_text_roi(image, content_rect, scale, field_bounds, caret=None, content_offset=None):
    """Return a content-only pixel region, masking the app's software caret."""
    validate_rect(content_rect, "ScreenCaptureKit content rect")
    validate_field_bounds(field_bounds, "accepted TextField")
    if not _finite_number(scale) or scale <= 0:
        raise AcceptanceError("ScreenCaptureKit point-to-pixel scale is invalid")
    if field_bounds["x"] + field_bounds["width"] > content_rect["width"] + 1 / scale or \
       field_bounds["y"] + field_bounds["height"] > content_rect["height"] + 1 / scale:
        raise AcceptanceError("TextField bounds lie outside the captured content view")
    if content_offset is None:
        content_offset = {"x": 0, "y": 0}
    if type(content_offset) is not dict or set(content_offset) != {"x", "y"} or \
       any(not _finite_number(content_offset.get(key)) for key in ("x", "y")):
        raise AcceptanceError("captured content-view origin in the window is invalid")
    width, height = image["width"], image["height"]
    field_x, field_y = field_bounds["x"] + content_offset["x"], field_bounds["y"] + content_offset["y"]
    left = max(0, math.ceil((field_x + 3) * scale))
    top = max(0, math.ceil((field_y + 3) * scale))
    right = min(width, math.floor((field_x + field_bounds["width"] - 3) * scale))
    bottom = min(height, math.floor((field_y + field_bounds["height"] - 3) * scale))
    if right - left < 16 or bottom - top < 8:
        raise AcceptanceError("TextField pixel ROI is too small for text verification")
    excluded = None
    if caret is not None:
        validate_rect(caret, "accepted caret")
        # Mask a small margin around the caret so caret blinking or a moved
        # insertion bar cannot satisfy the text-change assertion.
        excluded = {"left": max(left, math.floor((caret["x"] + content_offset["x"] - 3) * scale)),
                    "top": max(top, math.floor((caret["y"] + content_offset["y"] - 2) * scale)),
                    "right": min(right, math.ceil((caret["x"] + content_offset["x"] + caret["width"] + 3) * scale)),
                    "bottom": min(bottom, math.ceil((caret["y"] + content_offset["y"] + caret["height"] + 2) * scale))}
        if excluded["right"] <= excluded["left"] or excluded["bottom"] <= excluded["top"]:
            excluded = None
    return {"pixel_bounds": {"left": left, "top": top, "right": right, "bottom": bottom},
            "field_bounds": dict(field_bounds), "scale": scale, "excluded_caret": excluded,
            "content_offset": dict(content_offset), "inset_points": 3}


def text_roi_difference(before, after):
    before_roi, after_roi = before["roi"], after["roi"]
    stable_keys = ("pixel_bounds", "field_bounds", "scale", "content_offset", "inset_points")
    if any(before_roi.get(key) != after_roi.get(key) for key in stable_keys) or \
       (before["image"]["width"], before["image"]["height"]) != \
       (after["image"]["width"], after["image"]["height"]):
        raise AcceptanceError("TextField ROI geometry changed between accepted frames")
    roi = {key: before_roi[key] for key in stable_keys}
    bounds = roi["pixel_bounds"]
    left, top, right, bottom = (bounds[key] for key in ("left", "top", "right", "bottom"))
    width = before["image"]["width"]
    first, second = before["image"]["pixels"], after["image"]["pixels"]
    exclusions = [value for value in (before_roi.get("excluded_caret"), after_roi.get("excluded_caret"))
                  if value is not None]
    changed, changed_bounds = 0, [right, bottom, -1, -1]
    eligible = 0
    for y in range(top, bottom):
        for x in range(left, right):
            if any(mask["left"] <= x < mask["right"] and mask["top"] <= y < mask["bottom"]
                   for mask in exclusions):
                continue
            eligible += 1
            pos = (y * width + x) * 4
            if first[pos:pos + 4] != second[pos:pos + 4]:
                changed += 1
                changed_bounds[0], changed_bounds[1] = min(changed_bounds[0], x), min(changed_bounds[1], y)
                changed_bounds[2], changed_bounds[3] = max(changed_bounds[2], x), max(changed_bounds[3], y)
    rect = None if not changed else {"left": changed_bounds[0], "top": changed_bounds[1],
                                     "right": changed_bounds[2] + 1, "bottom": changed_bounds[3] + 1}
    return {"changed_pixels": changed, "changed_fraction": changed / max(1, eligible), "bounds": rect,
            "roi": roi, "before_pixels_sha256": before["image"]["pixel_sha256"],
            "after_pixels_sha256": after["image"]["pixel_sha256"],
            "excluded_carets": exclusions}


def require_text_change(difference, context):
    bounds = difference.get("bounds")
    if difference.get("changed_pixels", 0) < 64 or type(bounds) is not dict or \
       bounds["right"] - bounds["left"] < 8 or bounds["bottom"] - bounds["top"] < 3:
        raise AcceptanceError(context + " did not change enough non-caret TextField pixels")


def validate_state(record, source, binary_sha, *, initial=False):
    if type(record) is not dict or type(record.get("version")) is not int or record.get("version") != 1 or \
       record.get("source_revision") != source["commit"] or record.get("source_tree") != source["tree"] or \
       record.get("binary_sha256") != binary_sha or type(record.get("presentation")) is not int or \
       type(record.get("revision")) is not int or record["presentation"] <= 0 or record["revision"] < 0 or \
       record.get("focused") is not True:
        raise AcceptanceError("accepted field-state identity is stale or malformed")
    if initial:
        if record.get("text") != "Hello " or record.get("committed") != "Hello " or \
           record.get("composing") is not False or record.get("marked") is not None or \
           record.get("selection") != {"anchor": 6, "head": 6} or not isinstance(record.get("caret"), dict) or \
           type(record.get("session_epoch")) is not int or record["session_epoch"] <= 0 or \
           type(record.get("commit_count")) is not int or record["commit_count"] < 0:
            raise AcceptanceError("initial accepted field frame is not the focused Hello/caret state")
        validate_field_bounds(record.get("field_bounds"), "initial field state")
    return record


def validate_checkpoint(record, phase, source, binary_sha):
    if type(record) is not dict or type(record.get("schema_version")) is not int or \
       record.get("schema_version") != 1 or record.get("phase") != phase or \
       type(record.get("field_revision")) is not int or record["field_revision"] < 0 or \
       type(record.get("session_epoch")) is not int or record["session_epoch"] < 0:
        raise AcceptanceError("required app-owned IME phase is missing: " + phase)
    if record.get("source_revision") != source["commit"] or record.get("source_tree") != source["tree"] or \
       record.get("binary_sha256") != binary_sha:
        raise AcceptanceError("IME checkpoint is stale for the built app/source")
    validate_field_bounds(record.get("field_bounds"), phase)
    if phase == "initial-ready":
        validate_window_geometry(record.get("window_geometry"), phase)
    if phase == "composition-ready" and (type(record.get("session_epoch")) is not int or record["session_epoch"] <= 0):
        raise AcceptanceError("composition checkpoint omitted its positive editor session epoch")
    return record


EXPECTED_KEYS = [45, 34, 4, 31, 45, 5, 31, 49, 36, 45, 53]


def _finite_number(value):
    return type(value) in (int, float) and math.isfinite(value)


def validate_field_bounds(value, context):
    if type(value) is not dict or set(value) != {"x", "y", "width", "height"} or \
       any(not _finite_number(value.get(key)) for key in ("x", "y", "width", "height")) or \
       value["x"] < 0 or value["y"] < 0 or value["width"] <= 0 or value["height"] <= 0:
        raise AcceptanceError(context + " omitted finite logical content-view field bounds")
    return value


def validate_frame_identity(value, context):
    integer_fields = ("schema_version", "window_id", "host_epoch", "session_epoch", "batch_sequence",
                      "accepted_revision", "frame_revision")
    if type(value) is not dict or set(value) != FRAME_IDENTITY_FIELDS or \
       any(type(value.get(key)) is not int for key in integer_fields) or \
       value["schema_version"] != 1 or value["window_id"] <= 0 or value["host_epoch"] <= 0 or \
       value["session_epoch"] < 0 or value["batch_sequence"] < 0 or value["accepted_revision"] < 0 or \
       value["frame_revision"] <= 0 or not isinstance(value.get("frame_sha256"), str) or \
       not re.fullmatch(r"[0-9a-f]{64}", value["frame_sha256"]) or not isinstance(value.get("text"), str):
        raise AcceptanceError(context + " has an invalid typed frame identity")
    return value


def validate_rect(value, context):
    if type(value) is not dict or set(value) != {"x", "y", "width", "height"} or \
       any(not _finite_number(value.get(key)) for key in ("x", "y", "width", "height")) or \
       value["width"] <= 0 or value["height"] <= 0:
        raise AcceptanceError(context + " omitted a finite positive rectangle")
    return value


def validate_window_geometry(value, context):
    fields = {"schema_version", "window_key", "app_key_matches", "window_id", "host_epoch", "native_window_id",
              "first_responder_is_content_view", "first_responder_class", "content_view_class", "window_visible",
              "session_active", "direct_text", "session_epoch", "selected_input_source", "coordinate_space",
              "content_origin_in_window", "content_size", "window_size"}
    if type(value) is not dict or set(value) != fields or type(value.get("schema_version")) is not int or \
       value.get("schema_version") != 1 or value.get("coordinate_space") != "top_left_window_points":
        raise AcceptanceError(context + " checkpoint omitted app-owned content/window geometry")
    if type(value.get("window_id")) is not int or value["window_id"] <= 0 or \
       type(value.get("host_epoch")) is not int or value["host_epoch"] <= 0 or \
       type(value.get("native_window_id")) is not int or value["native_window_id"] <= 0 or \
       type(value.get("session_epoch")) is not int or value["session_epoch"] < 0 or \
       any(type(value.get(key)) is not bool for key in ("window_key", "app_key_matches",
           "first_responder_is_content_view", "window_visible", "session_active", "direct_text")) or \
       any(not isinstance(value.get(key), str) or not value[key] for key in
           ("first_responder_class", "content_view_class", "selected_input_source")):
        raise AcceptanceError(context + " app-owned native/logical window identity is invalid")
    origin = value["content_origin_in_window"]
    if type(origin) is not dict or set(origin) != {"x", "y"} or \
       any(not _finite_number(origin.get(key)) or origin[key] < 0 for key in ("x", "y")):
        raise AcceptanceError(context + " app-owned content origin is invalid")
    sizes = []
    for name in ("content_size", "window_size"):
        size = value[name]
        if type(size) is not dict or set(size) != {"width", "height"} or \
           any(not _finite_number(size.get(key)) or size[key] <= 0 for key in ("width", "height")):
            raise AcceptanceError(context + " app-owned " + name + " is invalid")
        sizes.append(size)
    content, window = sizes
    if origin["x"] + content["width"] > window["width"] + 1 or \
       origin["y"] + content["height"] > window["height"] + 1:
        raise AcceptanceError(context + " content rectangle escapes its app-owned window")
    return value


def validate_initial_window(checkpoint, state, identity):
    geometry = validate_window_geometry(checkpoint.get("window_geometry"), "initial-ready")
    checkpoint_source = checkpoint.get("input_source")
    if geometry["window_key"] is not True or geometry["app_key_matches"] is not True or \
       geometry["first_responder_is_content_view"] is not True or geometry["window_visible"] is not True or \
       geometry["session_active"] is not True or geometry["direct_text"] is not False or \
       not is_supported_kotoeri_japanese_romaji_source(checkpoint_source) or \
       geometry["selected_input_source"] != checkpoint_source or \
       geometry["window_id"] != identity["window_id"] or geometry["host_epoch"] != identity["host_epoch"] or \
       geometry["session_epoch"] != identity["session_epoch"] or \
       geometry["content_size"]["width"] + 1 < state["field_bounds"]["x"] + state["field_bounds"]["width"] or \
       geometry["content_size"]["height"] + 1 < state["field_bounds"]["y"] + state["field_bounds"]["height"]:
        raise AcceptanceError("initial native window is not the focused, session-active Kotoeri content view")
    return geometry


def validate_abort_receipt(receipt, expected_host_epoch=None, expected_session_epoch=None):
    if type(receipt) is not dict or set(receipt) != {"schema_version", "restored", "session_closed",
                                                     "host_epoch", "session_epoch"} or \
       type(receipt.get("schema_version")) is not int or receipt.get("schema_version") != 1 or \
       receipt.get("restored") is not True or receipt.get("session_closed") is not True or \
       type(receipt.get("host_epoch")) is not int or type(receipt.get("session_epoch")) is not int or \
       expected_host_epoch is not None and receipt["host_epoch"] != expected_host_epoch or \
       expected_session_epoch is not None and receipt["session_epoch"] != expected_session_epoch:
        raise AcceptanceError("app abort acknowledgement did not prove input-source restoration and session closure")
    return receipt


def validate_capture_item(item, manifest, expected_frame, expected_window_geometry, owner_pid, image, name):
    expected_keys = {"path", "window_id", "width", "height", "owner_pid", "title", "capture_engine",
                     "content_rect", "point_pixel_scale", "shadows_ignored", "cursor_excluded",
                     "child_windows_included", "capture_command", "file_sha256", "pixel_sha256", "file_size",
                     "png_encoding", "frame_identity", "field_bounds", "caret", "window_geometry",
                     "window_frame", "capture_region", "content_offset", "text_roi"}
    if type(item) is not dict or type(manifest) is not dict or set(item) != expected_keys or \
       item.get("path") != name + "-window.png" or item.get("frame_identity") != expected_frame or \
       item.get("capture_engine") != "ScreenCaptureKit.SCScreenshotManager" or \
       item.get("capture_command") != "ScreenCaptureKit SCScreenshotManager.captureImage(desktopIndependentWindow)" or \
       type(item.get("window_id")) is not int or type(item.get("owner_pid")) is not int or \
       item.get("owner_pid") != owner_pid or item.get("title") != APP_TITLE or \
       item.get("shadows_ignored") is not True or item.get("cursor_excluded") is not True or \
       item.get("child_windows_included") is not False or \
       (item.get("width"), item.get("height")) != (image["width"], image["height"]):
        raise AcceptanceError("screenshot file is not bound to its native checkpoint/window identity")
    rect = validate_rect(item.get("content_rect"), name + " captured content rect")
    scale = item.get("point_pixel_scale")
    if not _finite_number(scale) or scale <= 0 or \
       abs(image["width"] - round(rect["width"] * scale)) > 1 or \
       abs(image["height"] - round(rect["height"] * scale)) > 1:
        raise AcceptanceError("screenshot content geometry/scale differs from captured pixels")
    bounds = validate_field_bounds(item.get("field_bounds"), name + " captured TextField")
    caret = item.get("caret")
    if caret is not None:
        validate_rect(caret, name + " captured caret")
    geometry = validate_window_geometry(item.get("window_geometry"), name)
    if geometry != expected_window_geometry:
        raise AcceptanceError("captured TextField geometry differs from the initial app-owned window")
    if item.get("window_id") != geometry["native_window_id"] or \
       expected_frame.get("window_id") != geometry["window_id"] or \
       expected_frame.get("host_epoch") != geometry["host_epoch"]:
        raise AcceptanceError("ScreenCaptureKit window and app frame identities do not cross-bind")
    window_frame = item.get("window_frame")
    if type(window_frame) is not dict or set(window_frame) != {"width", "height"} or \
       any(not _finite_number(window_frame.get(key)) for key in ("width", "height")) or \
       abs(window_frame["width"] - geometry["window_size"]["width"]) > 1 or \
       abs(window_frame["height"] - geometry["window_size"]["height"]) > 1:
        raise AcceptanceError("ScreenCaptureKit and app-owned NSWindow geometry disagree")
    capture_size = {"width": rect["width"], "height": rect["height"]}
    if all(abs(capture_size[key] - window_frame[key]) <= 1 for key in ("width", "height")):
        capture_region, offset = "window", geometry["content_origin_in_window"]
    elif all(abs(capture_size[key] - geometry["content_size"][key]) <= 1 for key in ("width", "height")):
        capture_region, offset = "content", {"x": 0.0, "y": 0.0}
    else:
        raise AcceptanceError("ScreenCaptureKit bounds match neither the app window nor its content view")
    if item.get("capture_region") != capture_region or item.get("content_offset") != offset:
        raise AcceptanceError("screenshot's content-view-to-window mapping was altered")
    roi = prepare_text_roi(image, rect, scale, bounds, caret, offset)
    if item.get("text_roi") != roi:
        raise AcceptanceError("retained TextField ROI/caret mask differs from current screenshot geometry")
    if image["file_sha256"] != item.get("file_sha256") or image["pixel_sha256"] != item.get("pixel_sha256") or \
       item.get("file_size") != image["file_size"] or item.get("png_encoding") != image["png_encoding"]:
        raise AcceptanceError("screenshot bytes/pixels differ from the accepted frame manifest")
    if {key: manifest.get(key) for key in expected_keys} != item:
        raise AcceptanceError("screenshot index disagrees with its summary: " + name)
    return {"image": image, "roi": roi}


def validate_final(record, source, binary_sha, initial_revision=None, initial_frame_revision=None):
    expected = {"schema_version": 1, "input_source": None, "committed_text": "Hello 日本語",
                "composing": False, "focused": False, "commit_count": 1, "commit_callbacks": 1}
    allowed = {"schema_version", "window_id", "host_epoch", "session_epoch", "final_session_epoch",
               "input_source", "preedit_callbacks", "commit_callbacks", "cancel_callbacks", "committed_text",
               "composing", "focused", "commit_count", "batches", "receipts", "candidate_screen_rect",
               "final_frame_identity", "final_frame_revision", "field_bounds", "source_revision", "source_tree", "binary_sha256"}
    if type(record) is not dict or set(record) != allowed or type(record.get("schema_version")) is not int or \
       type(record.get("composing")) is not bool or type(record.get("focused")) is not bool or \
       type(record.get("commit_count")) is not int or type(record.get("commit_callbacks")) is not int or \
       type(record.get("cancel_callbacks")) is not int or record.get("cancel_callbacks", 0) < 1 or \
       any(record.get(key) != value for key, value in expected.items() if key != "input_source") or \
       not is_supported_kotoeri_japanese_romaji_source(record.get("input_source")) or \
       type(record.get("preedit_callbacks")) is not int or record["preedit_callbacks"] < 1 or \
       type(record.get("window_id")) is not int or record["window_id"] <= 0 or \
       type(record.get("host_epoch")) is not int or record["host_epoch"] <= 0 or \
       type(record.get("session_epoch")) is not int or record["session_epoch"] <= 0 or \
       type(record.get("final_session_epoch")) is not int or record["final_session_epoch"] < 0 or \
       type(record.get("final_frame_revision")) is not int or record["final_frame_revision"] <= 0 or \
       record.get("source_revision") != source["commit"] or record.get("source_tree") != source["tree"] or \
       record.get("binary_sha256") != binary_sha:
        raise AcceptanceError("Kotoeri commit/callback/final-frame contract is incomplete")
    validate_field_bounds(record.get("field_bounds"), "final accepted frame")
    frame = record.get("final_frame_identity")
    validate_frame_identity(frame, "final frame")
    if type(frame) is not dict or set(frame) != {"schema_version", "window_id", "host_epoch", "session_epoch",
       "batch_sequence", "accepted_revision", "frame_revision", "frame_sha256", "text"} or \
       type(frame.get("schema_version")) is not int or frame.get("schema_version") != 1 or \
       type(frame.get("window_id")) is not int or frame.get("window_id") != record["window_id"] or \
       type(frame.get("host_epoch")) is not int or frame.get("host_epoch") != record["host_epoch"] or \
       type(frame.get("session_epoch")) is not int or frame.get("session_epoch") != record["final_session_epoch"] or \
       type(frame.get("frame_revision")) is not int or frame.get("frame_revision") != record["final_frame_revision"] or \
       type(frame.get("accepted_revision")) is not int or frame["accepted_revision"] < 0 or \
       type(frame.get("batch_sequence")) is not int or frame["batch_sequence"] < 0 or \
       frame.get("text") != "Hello 日本語" or \
       not isinstance(frame.get("frame_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", frame["frame_sha256"]):
        raise AcceptanceError("final frame identity is not the committed, accepted Kotoeri presentation")
    rect = record.get("candidate_screen_rect")
    if type(rect) is not dict or set(rect) != {"x", "y", "width", "height"} or \
       any(not _finite_number(rect.get(key)) for key in ("x", "y", "width", "height")) or \
       rect["width"] <= 0 or rect["height"] <= 0:
        raise AcceptanceError("Kotoeri candidate screen rectangle is missing or invalid")
    batches = record.get("batches")
    if type(batches) is not list or not 1 <= len(batches) <= 64:
        raise AcceptanceError("IME acceptance omitted ordered app-owned native batches")
    sequences, preedits, commits, cancellations = [], 0, 0, 0
    previous_accepted_revision = initial_revision
    previous_frame_revision = initial_frame_revision
    if previous_accepted_revision is not None and type(previous_accepted_revision) is not int:
        raise AcceptanceError("initial field revision is not an integer")
    if previous_frame_revision is not None and type(previous_frame_revision) is not int:
        raise AcceptanceError("initial frame revision is not an integer")
    for row in batches:
        batch_fields = {"sequence", "owner_revision", "epoch", "accepted_revision", "acknowledged",
                        "preedit_callbacks", "commit_callbacks", "cancel_callbacks", "frame_identity",
                        "candidate_screen_rect"}
        if type(row) is not dict or set(row) != batch_fields or \
           type(row.get("sequence")) is not int or row["sequence"] < 1 or \
           type(row.get("epoch")) is not int or row["epoch"] != record["session_epoch"] or \
           type(row.get("accepted_revision")) is not int or row["accepted_revision"] < 0 or \
           type(row.get("owner_revision")) is not int or row["owner_revision"] < 0 or \
           row.get("acknowledged") is not True or any(type(row.get(key)) is not int or row[key] < 0 for key in
             ("preedit_callbacks", "commit_callbacks", "cancel_callbacks")):
            raise AcceptanceError("IME batch is malformed or lacks its owner acknowledgement")
        if previous_accepted_revision is not None and row["owner_revision"] != previous_accepted_revision:
            raise AcceptanceError("IME batch owner revision does not continue the previous accepted revision")
        if row["accepted_revision"] < row["owner_revision"]:
            raise AcceptanceError("IME acknowledgement moved the field revision backwards")
        identity = row.get("frame_identity")
        validate_frame_identity(identity, "IME batch frame")
        if type(identity) is not dict or set(identity) != {"schema_version", "window_id", "host_epoch", "session_epoch",
             "batch_sequence", "accepted_revision", "frame_revision", "frame_sha256", "text"} or \
           type(identity.get("schema_version")) is not int or identity.get("schema_version") != 1 or \
           type(identity.get("window_id")) is not int or identity.get("window_id") != record["window_id"] or \
           type(identity.get("host_epoch")) is not int or identity.get("host_epoch") != record["host_epoch"] or \
           type(identity.get("session_epoch")) is not int or identity.get("session_epoch") != record["session_epoch"] or \
           type(identity.get("batch_sequence")) is not int or identity.get("batch_sequence") != row["sequence"] or \
           type(identity.get("accepted_revision")) is not int or identity.get("accepted_revision") != row["accepted_revision"] or \
           type(identity.get("frame_revision")) is not int or identity["frame_revision"] <= 0 or \
           not isinstance(identity.get("text"), str) or \
           not isinstance(identity.get("frame_sha256"), str) or not re.fullmatch(r"[0-9a-f]{64}", identity["frame_sha256"]):
            raise AcceptanceError("IME batch lacks its accepted presentation identity")
        if previous_frame_revision is not None and identity["frame_revision"] <= previous_frame_revision:
            raise AcceptanceError("IME batch frame revision did not increase")
        if row["preedit_callbacks"]:
            candidate = row.get("candidate_screen_rect")
            if type(candidate) is not dict or set(candidate) != {"x", "y", "width", "height"} or \
               any(not _finite_number(candidate.get(key)) for key in ("x", "y", "width", "height")) or \
               candidate["width"] <= 0 or candidate["height"] <= 0:
                raise AcceptanceError("preedit batch omitted a finite candidate rectangle")
        elif row.get("candidate_screen_rect") is not None and type(row.get("candidate_screen_rect")) is not dict:
            raise AcceptanceError("IME batch candidate rectangle is malformed")
        sequences.append(row["sequence"])
        previous_accepted_revision = row["accepted_revision"]
        previous_frame_revision = identity["frame_revision"]
        preedits += row["preedit_callbacks"]
        commits += row["commit_callbacks"]
        cancellations += row["cancel_callbacks"]
    if sequences != sorted(set(sequences)) or \
       (preedits, commits, cancellations) != (record["preedit_callbacks"], record["commit_callbacks"], record["cancel_callbacks"]):
        raise AcceptanceError("IME batches are replayed or callback counts differ from the reported inventory")
    if frame["accepted_revision"] != batches[-1]["accepted_revision"] or \
       frame["batch_sequence"] < batches[-1]["sequence"] or \
       previous_frame_revision is not None and frame["frame_revision"] <= previous_frame_revision:
        raise AcceptanceError("final presented state does not preserve the last acknowledged editor revision")
    receipts = record.get("receipts")
    if type(receipts) is not list or len(receipts) != len(EXPECTED_KEYS):
        raise AcceptanceError("native acceptance did not retain all 11 physical key dispatch receipts")
    previous_batch_sequence, previous_window_sequence = 0, 0
    acknowledged_sequences = {0, *sequences}
    for index, receipt in enumerate(receipts):
        receipt_fields = {"schema_version", "dispatch_id", "key_code", "down_posted", "up_posted",
                          "down_dispatched", "up_dispatched", "host_epoch", "session_epoch",
                          "batch_sequence", "window_sequence"}
        if type(receipt) is not dict or set(receipt) != receipt_fields or \
           type(receipt.get("schema_version")) is not int or receipt.get("schema_version") != 1 or \
           type(receipt.get("dispatch_id")) is not int or receipt.get("dispatch_id") != index + 1 or \
           type(receipt.get("key_code")) is not int or receipt.get("key_code") != EXPECTED_KEYS[index] or \
           receipt.get("down_posted") is not True or receipt.get("up_posted") is not True or \
           receipt.get("down_dispatched") is not True or receipt.get("up_dispatched") is not True or \
           type(receipt.get("host_epoch")) is not int or receipt.get("host_epoch") != record["host_epoch"] or \
           type(receipt.get("session_epoch")) is not int or receipt.get("session_epoch") != record["session_epoch"] or \
           type(receipt.get("batch_sequence")) is not int or receipt["batch_sequence"] < previous_batch_sequence or \
           receipt["batch_sequence"] not in acknowledged_sequences or \
           type(receipt.get("window_sequence")) is not int or receipt["window_sequence"] <= previous_window_sequence:
            raise AcceptanceError("native key receipts do not prove the exact ordered Kotoeri dispatch sequence")
        previous_batch_sequence = receipt["batch_sequence"]
        previous_window_sequence = receipt["window_sequence"]
    return record


SWIFT_WINDOW_CAPTURE = r'''import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

@main
struct OwnedWindowCapture {
  @MainActor
  static func main() async {
    guard CommandLine.arguments.count == 4,
          let pid = Int32(CommandLine.arguments[1]) else {
      fputs("usage: owned-window-capture PID TITLE OUTPUT.png\n", stderr)
      exit(2)
    }
    // Establish the process's WindowServer connection before CoreGraphics' capture path.
    _ = NSApplication.shared
    let title = CommandLine.arguments[2]
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    do {
      let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      let windows = content.windows.filter { window in
        window.owningApplication?.processID == pid && window.title == title
      }
      guard windows.count == 1, let window = windows.first else {
        fputs("expected exactly one visible app-owned ScreenCaptureKit window\n", stderr)
        exit(4)
      }
      let filter = SCContentFilter(desktopIndependentWindow: window)
      let contentRect = filter.contentRect
      let scale = CGFloat(filter.pointPixelScale)
      guard scale.isFinite, scale > 0, contentRect.width.isFinite, contentRect.height.isFinite,
            contentRect.width > 0, contentRect.height > 0 else {
        fputs("ScreenCaptureKit returned invalid content geometry\n", stderr)
        exit(7)
      }
      let config = SCStreamConfiguration()
      config.width = max(1, Int((contentRect.width * scale).rounded()))
      config.height = max(1, Int((contentRect.height * scale).rounded()))
      config.capturesAudio = false
      config.showsCursor = false
      config.ignoreShadowsSingleWindow = true
      config.includeChildWindows = false
      let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fputs("cannot create the ScreenCaptureKit PNG destination\n", stderr)
        exit(5)
      }
      CGImageDestinationAddImage(destination, image, nil)
      guard CGImageDestinationFinalize(destination) else {
        fputs("cannot finalize ScreenCaptureKit PNG\n", stderr)
        exit(6)
      }
      let response: [String: Any] = ["window_id": Int(window.windowID),
                                     "width": image.width, "height": image.height,
                                     "owner_pid": Int(pid), "title": title,
                                     "window_frame": ["width": Double(window.frame.width),
                                                      "height": Double(window.frame.height)],
                                     "capture_engine": "ScreenCaptureKit.SCScreenshotManager",
                                     "content_rect": ["x": Double(contentRect.origin.x),
                                                      "y": Double(contentRect.origin.y),
                                                      "width": Double(contentRect.width),
                                                      "height": Double(contentRect.height)],
                                     "point_pixel_scale": Double(scale),
                                     "shadows_ignored": true, "cursor_excluded": true,
                                     "child_windows_included": false]
      let bytes = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
      print(String(decoding: bytes, as: UTF8.self))
    } catch {
      fputs("ScreenCaptureKit capture failed (including Screen Recording permission): \(error.localizedDescription)\n", stderr)
      exit(10)
    }
  }
}
'''


def capture_own_window(pid, title, output, helper, timeout=12):
    deadline = time.monotonic() + timeout
    last_error = "no window appeared"
    details = None
    while time.monotonic() < deadline:
        result = subprocess.run([str(helper), str(pid), title, str(output)], text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        if result.returncode == 0:
            try:
                details = json.loads(result.stdout)
            except json.JSONDecodeError:
                last_error = "ScreenCaptureKit helper returned malformed metadata"
                break
            break
        last_error = result.stderr.strip() or "ScreenCaptureKit helper failed with exit " + str(result.returncode)
        if result.returncode not in {4}:
            break
        time.sleep(0.2)
    if details is None:
        raise AcceptanceError("ScreenCaptureKit could not capture exactly one visible app-owned window: " + last_error)
    rect = details.get("content_rect") if type(details) is dict else None
    window_frame = details.get("window_frame") if type(details) is dict else None
    scale = details.get("point_pixel_scale") if type(details) is dict else None
    if type(details) is not dict or details.get("owner_pid") != pid or details.get("title") != title or \
       type(details.get("window_id")) is not int or details["window_id"] <= 0 or \
       details.get("capture_engine") != "ScreenCaptureKit.SCScreenshotManager" or \
       type(window_frame) is not dict or set(window_frame) != {"width", "height"} or \
       any(not _finite_number(window_frame.get(key)) or window_frame[key] <= 0 for key in ("width", "height")) or \
       type(rect) is not dict or set(rect) != {"x", "y", "width", "height"} or \
       any(not _finite_number(rect.get(key)) for key in ("x", "y", "width", "height")) or \
       rect["width"] <= 0 or rect["height"] <= 0 or not _finite_number(scale) or scale <= 0 or \
       details.get("shadows_ignored") is not True or details.get("cursor_excluded") is not True or \
       details.get("child_windows_included") is not False:
        raise AcceptanceError("ScreenCaptureKit metadata does not identify the launched app window")
    image = png_pixels(output)
    expected_size = (round(rect["width"] * scale), round(rect["height"] * scale))
    if (image["width"], image["height"]) != (details.get("width"), details.get("height")) or \
       abs(image["width"] - expected_size[0]) > 1 or abs(image["height"] - expected_size[1]) > 1:
        raise AcceptanceError("ScreenCaptureKit PNG dimensions disagree with the captured window identity")
    image.pop("pixels")
    return {**details, "capture_command": "ScreenCaptureKit SCScreenshotManager.captureImage(desktopIndependentWindow)", **image}


def bind_capture(capture, name, frame_identity, field_bounds, caret, window_geometry, png_path):
    image = png_pixels(png_path)
    rect = capture.get("content_rect")
    scale = capture.get("point_pixel_scale")
    geometry = validate_window_geometry(window_geometry, name)
    frame = capture["window_frame"]
    if all(abs(rect[key] - frame[key]) <= 1 for key in ("width", "height")):
        capture_region, offset = "window", geometry["content_origin_in_window"]
    elif all(abs(rect[key] - geometry["content_size"][key]) <= 1 for key in ("width", "height")):
        capture_region, offset = "content", {"x": 0.0, "y": 0.0}
    else:
        raise AcceptanceError("ScreenCaptureKit bounds match neither app window nor its content view")
    roi = prepare_text_roi(image, rect, scale, field_bounds, caret, offset)
    return {**capture, "path": Path(png_path).name, "frame_identity": frame_identity,
            "field_bounds": dict(field_bounds), "caret": None if caret is None else dict(caret),
            "window_geometry": geometry, "capture_region": capture_region,
            "content_offset": offset, "text_roi": roi}


def validate_summary(path, repo=REPO, expected_source=None):
    path = Path(path).resolve(strict=True)
    directory = path.parent
    report = strict_json(path.read_text())
    if type(report) is not dict or type(report.get("schema_version")) is not int or report.get("schema_version") != 1 or \
       report.get("ok") is not True or report.get("status") != "passed" or \
       type(report.get("app_exit_code")) is not int or report.get("app_exit_code") != 0:
        raise AcceptanceError("retained IME report does not declare a completed pass")
    source = source_snapshot(Path(repo).resolve(strict=True))
    if report.get("source_before") != report.get("source_after") or report.get("source_before") != source or \
       expected_source is not None and report.get("source_before") != expected_source:
        raise AcceptanceError("IME report source snapshot differs from the current checkout or before/after binding")
    profile_root = report.get("profile_root")
    if not isinstance(profile_root, str) or not Path(profile_root).is_absolute():
        raise AcceptanceError("IME report omitted its qualified external profile root")
    profile = load_profile()
    try:
        current_host = profile.host_identity()
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        raise AcceptanceError("current macOS/Xcode identity cannot be revalidated: " + str(error)) from None
    if report.get("host") != current_host:
        raise AcceptanceError("IME report OS/Xcode/SDK identity differs from the current host")
    app = report.get("app")
    if type(app) is not dict:
        raise AcceptanceError("IME report omits its app identity")
    bundle = Path(app.get("bundle", "")).resolve(strict=True)
    executable = bundle / "Contents/MacOS/GpuiTextField"
    library = bundle / "Contents/Frameworks/libgpui_macos.dylib"
    plist = bundle / "Contents/Info.plist"
    if app.get("binary_path") != str(executable) or not executable.is_file() or not library.is_file() or not plist.is_file() or \
       digest(executable) != app.get("binary_sha256") or digest(library) != app.get("library_sha256") or \
       digest(plist) != app.get("info_plist_sha256"):
        raise AcceptanceError("app executable, native library or bundle metadata differs from the captured report")
    capture = report.get("capture_runtime")
    helper = directory / "owned-window-capture"
    helper_source = directory / "owned-window-capture.swift"
    swiftc_value = capture.get("swiftc") if type(capture) is dict else None
    swiftc = Path(swiftc_value) if isinstance(swiftc_value, str) and swiftc_value else None
    swiftc_resolved_value = capture.get("swiftc_resolved") if type(capture) is dict else None
    swiftc_resolved = Path(swiftc_resolved_value) if isinstance(swiftc_resolved_value, str) and swiftc_resolved_value else None
    compile_environment = {"DEVELOPER_DIR": current_host["xcode_select_path"],
                           "SDKROOT": current_host["sdk_path"], "MACOSX_DEPLOYMENT_TARGET": "26.0"}
    swift_env = dict(os.environ)
    swift_env.update(compile_environment)
    try:
        selected_swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True,
                                                       env=swift_env, timeout=10).strip())
        current_swiftc_version = subprocess.check_output([str(selected_swiftc), "-version"], text=True,
                                                         env=swift_env, timeout=15).strip()
    except (OSError, subprocess.SubprocessError) as error:
        raise AcceptanceError("current pinned Swift compiler could not be resolved: " + str(error)) from None
    if type(capture) is not dict or set(capture) != {"swiftc", "swiftc_resolved", "swiftc_sha256", "swiftc_version",
        "compile_environment", "helper_sha256", "helper_compile_argv", "engine", "helper_source_sha256"} or \
       capture.get("engine") != "ScreenCaptureKit.SCScreenshotManager" or \
       capture.get("compile_environment") != compile_environment or capture.get("swiftc") != str(selected_swiftc) or \
       capture.get("swiftc_version") != current_swiftc_version or \
       capture.get("helper_compile_argv") != [
           str(selected_swiftc), "-parse-as-library", "-framework", "AppKit",
           "-framework", "ScreenCaptureKit", "-framework", "ImageIO",
           str(helper_source), "-o", str(helper),
       ] or \
       swiftc is None or not swiftc.is_absolute() or not swiftc.is_file() or \
       swiftc_resolved is None or not swiftc_resolved.is_absolute() or \
       swiftc.resolve(strict=True) != swiftc_resolved or digest(swiftc_resolved) != capture.get("swiftc_sha256") or \
       not helper.is_file() or digest(helper) != capture.get("helper_sha256") or \
       not helper_source.is_file() or digest(helper_source) != capture.get("helper_source_sha256") or \
       helper_source.read_text() != SWIFT_WINDOW_CAPTURE:
        raise AcceptanceError("ScreenCaptureKit capture tool/source identity is stale or incomplete")
    binary_sha = app["binary_sha256"]
    initial = validate_state(report.get("initial_state"), source, binary_sha, initial=True)
    initial_checkpoint = validate_checkpoint(report.get("initial_checkpoint"), "initial-ready", source, binary_sha)
    final = validate_final(report.get("final_acceptance"), source, binary_sha, initial["revision"],
                           initial_checkpoint.get("frame_identity", {}).get("frame_revision"))
    composition = validate_checkpoint(report.get("composition_checkpoint"), "composition-ready", source, binary_sha)
    initial_identity = initial_checkpoint.get("frame_identity")
    validate_frame_identity(initial_identity, "initial checkpoint frame")
    composition_identity = composition.get("frame_identity")
    validate_frame_identity(composition_identity, "composition checkpoint frame")
    geometry = validate_initial_window(initial_checkpoint, initial, initial_identity)
    if not is_supported_kotoeri_japanese_romaji_source(initial_checkpoint.get("input_source")) or \
       report.get("input_source") != initial_checkpoint.get("input_source") or \
       composition.get("input_source") != initial_checkpoint.get("input_source") or \
       final.get("input_source") != initial_checkpoint.get("input_source") or \
       initial_checkpoint.get("text") != "Hello " or initial_checkpoint.get("session_epoch") != initial["session_epoch"] or \
       initial_checkpoint.get("field_revision") != initial["revision"] or \
       type(initial_identity) is not dict or set(initial_identity) != {"schema_version", "window_id", "host_epoch",
           "session_epoch", "batch_sequence", "accepted_revision", "frame_revision", "frame_sha256", "text"} or \
       initial_identity.get("schema_version") != 1 or initial_identity.get("window_id") <= 0 or \
       initial_identity.get("host_epoch") <= 0 or initial_identity.get("session_epoch") != initial["session_epoch"] or \
       initial_identity.get("batch_sequence") != 0 or initial_identity.get("accepted_revision") != initial["revision"] or \
       initial_identity.get("frame_revision", 0) <= 0 or initial_identity.get("text") != "Hello " or \
       not re.fullmatch(r"[0-9a-f]{64}", str(initial_identity.get("frame_sha256", ""))) or \
       composition.get("composing") is not True or composition.get("committed") != "Hello " or \
       composition.get("session_epoch") != initial.get("session_epoch") or \
       not isinstance(composition.get("text"), str) or not any(char in composition["text"] for char in "日本語にほんご") or \
       not isinstance(composition.get("marked"), dict) or \
       type(composition["marked"].get("start")) is not int or type(composition["marked"].get("end")) is not int or \
       composition["marked"]["start"] < 0 or composition["marked"]["end"] <= composition["marked"]["start"] or \
       not isinstance(composition.get("caret"), dict) or \
       any(not _finite_number(composition["caret"].get(key)) for key in ("x", "y", "width", "height")) or \
       composition["caret"]["width"] <= 0 or composition["caret"]["height"] <= 0:
        raise AcceptanceError("initial/preedit checkpoints do not describe the required focused Kotoeri frames")
    candidate = composition.get("candidate_screen_rect")
    if type(candidate) is not dict or set(candidate) != {"x", "y", "width", "height"} or \
       any(not _finite_number(candidate.get(key)) for key in ("x", "y", "width", "height")) or \
       candidate["width"] <= 0 or candidate["height"] <= 0:
        raise AcceptanceError("preedit checkpoint candidate geometry is missing or nonfinite")
    if type(composition_identity) is not dict or set(composition_identity) != {"schema_version", "window_id", "host_epoch",
           "session_epoch", "batch_sequence", "accepted_revision", "frame_revision", "frame_sha256", "text"} or \
       composition_identity.get("schema_version") != 1 or \
       composition_identity.get("window_id") != initial_identity.get("window_id") or \
       composition_identity.get("host_epoch") != initial_identity.get("host_epoch") or \
       composition_identity.get("session_epoch") != initial_identity.get("session_epoch") or \
       composition_identity.get("batch_sequence") < 0 or \
       composition_identity.get("accepted_revision") != composition.get("field_revision") or \
       composition_identity.get("frame_revision", 0) <= initial_identity.get("frame_revision", 0) or \
       composition_identity.get("text") != composition.get("text") or \
       not re.fullmatch(r"[0-9a-f]{64}", str(composition_identity.get("frame_sha256", ""))):
        raise AcceptanceError("preedit checkpoint frame identity differs from the accepted text/caret/mark")
    if type(initial_identity) is not dict or type(composition_identity) is not dict or \
       type(composition.get("frame_identity")) is not dict or \
       final["window_id"] != initial_identity.get("window_id") or \
       final["host_epoch"] != initial_identity.get("host_epoch") or \
       final["session_epoch"] != initial.get("session_epoch") or \
       final["final_frame_revision"] <= composition["frame_identity"].get("frame_revision", 0):
        raise AcceptanceError("final app-owned frame does not continue the initial and composition checkpoints")
    app_log = directory / "app.stdout.log"
    if not app_log.is_file() or app_log.is_symlink():
        raise AcceptanceError("app stdout log is missing from retained IME evidence")
    checkpoint_rows, state_rows, final_rows = [], [], []
    for line in app_log.read_text(encoding="utf-8").splitlines():
        if "GPUI_MACOS_IME_ACCEPTANCE_FAIL" in line:
            raise AcceptanceError("app log contains an explicit IME acceptance failure")
        for prefix, destination in (("GPUI_FIELD_MACOS_STATE ", state_rows),
                                    ("GPUI_MACOS_IME_CHECKPOINT ", checkpoint_rows),
                                    ("GPUI_MACOS_IME_ACCEPTANCE ", final_rows)):
            if line.startswith(prefix):
                destination.append(strict_json(line[len(prefix):]))
                break
    phases = [row.get("phase") for row in checkpoint_rows]
    if phases.count("initial-ready") != 1 or phases.count("composition-ready") != 1 or len(final_rows) != 1 or \
       not state_rows or state_rows[0] != initial or \
       next(row for row in checkpoint_rows if row.get("phase") == "composition-ready") != composition or \
       final_rows[0] != final:
        raise AcceptanceError("app log is missing or disagrees with a required IME checkpoint/final callback")
    index_path = directory / "screenshots-index.json"
    if report.get("screenshots_index") != index_path.name or not index_path.is_file() or index_path.is_symlink() or \
       digest(index_path) != report.get("screenshots_index_sha256"):
        raise AcceptanceError("screenshot index is missing or its recorded hash is stale")
    index = strict_json(index_path.read_text())
    screenshots = report.get("screenshots")
    if type(index) is not dict or set(index) != {"initial", "composition", "final"} or \
       type(screenshots) is not dict or set(screenshots) != set(index):
        raise AcceptanceError("screenshot stage inventory is missing a required initial/composition/final frame")
    expected_frames = {"initial": initial_checkpoint["frame_identity"],
                       "composition": composition["frame_identity"],
                       "final": final["final_frame_identity"]}
    images = {}
    roi_frames = {}
    for name, basename in (("initial", "initial-window.png"), ("composition", "composition-window.png"),
                           ("final", "final-window.png")):
        item = screenshots[name]
        manifest = index[name]
        image_path = directory / basename
        if not image_path.is_file() or image_path.is_symlink():
            raise AcceptanceError("screenshot PNG is absent or is a symlink")
        image = png_pixels(image_path)
        roi = validate_capture_item(item, manifest, expected_frames[name],
                                    initial_checkpoint["window_geometry"], report.get("app_pid"), image, name)
        expected_bounds = final["field_bounds"] if name == "final" else initial_checkpoint["field_bounds"]
        if item["field_bounds"] != expected_bounds:
            raise AcceptanceError("captured TextField bounds differ from the accepted app presentation")
        images[name] = image
        roi_frames[name] = roi
    actual_differences = {"initial_to_composition": pixel_difference(images["initial"], images["composition"]),
                          "composition_to_final": pixel_difference(images["composition"], images["final"]),
                          "initial_to_final": pixel_difference(images["initial"], images["final"])}
    actual_roi_differences = {
        "initial_to_composition": text_roi_difference(roi_frames["initial"], roi_frames["composition"]),
        "composition_to_final": text_roi_difference(roi_frames["composition"], roi_frames["final"]),
        "initial_to_final": text_roi_difference(roi_frames["initial"], roi_frames["final"]),
    }
    if report.get("pixel_differences") != actual_differences or \
       any(value["changed_pixels"] < 32 for value in actual_differences.values()) or \
       report.get("text_roi_differences") != actual_roi_differences:
        raise AcceptanceError("pixel deltas do not match retained ScreenCaptureKit frame bytes/ROI")
    for phase, difference in actual_roi_differences.items():
        require_text_change(difference, phase)
    return report


class AppOutput:
    def __init__(self, process, log_path):
        self.process = process
        self.lines = queue.Queue()
        self.log_path = Path(log_path)
        self.log = self.log_path.open("w", encoding="utf-8")
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self):
        for line in self.process.stdout:
            self.log.write(line)
            self.log.flush()
            self.lines.put(line.rstrip("\n"))
        self.lines.put(None)

    def wait_line(self, prefix, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                line = self.lines.get(timeout=min(0.25, max(0.01, deadline - time.monotonic())))
            except queue.Empty:
                if self.process.poll() is not None:
                    break
                continue
            if line is None:
                break
            if "GPUI_MACOS_IME_ACCEPTANCE_FAIL" in line:
                raise AcceptanceError(line)
            if line.startswith(prefix):
                return strict_json(line[len(prefix):].strip())
        raise AcceptanceError("app did not emit required line before timeout: " + prefix)

    def retained_abort(self, expected_host_epoch=None, expected_session_epoch=None):
        if not self.log_path.is_file() or self.log_path.is_symlink():
            return None
        prefix = "GPUI_MACOS_IME_ABORTED "
        matches = [line[len(prefix):] for line in self.log_path.read_text(encoding="utf-8").splitlines()
                   if line.startswith(prefix)]
        if not matches:
            return None
        if len(matches) != 1:
            raise AcceptanceError("app log contains duplicate abort receipts")
        return validate_abort_receipt(strict_json(matches[0]), expected_host_epoch, expected_session_epoch)

    def abort_and_wait(self, timeout=8, expected_host_epoch=None, expected_session_epoch=None):
        if self.process.poll() is not None:
            try:
                receipt = self.retained_abort(expected_host_epoch, expected_session_epoch)
            except AcceptanceError as error:
                return {"requested": False, "acknowledged": False, "reason": str(error),
                        "exit_code": self.process.returncode}
            if receipt is not None:
                return {"requested": False, "acknowledged": True, "receipt": receipt,
                        "exit_code": self.process.returncode}
            return {"requested": False, "acknowledged": False,
                    "exit_code": self.process.returncode, "reason": "app already exited"}
        try:
            self.process.stdin.write("abort\n")
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            return {"requested": True, "acknowledged": False, "reason": str(error)}
        try:
            receipt = self.wait_line("GPUI_MACOS_IME_ABORTED ", timeout)
            try:
                validate_abort_receipt(receipt, expected_host_epoch, expected_session_epoch)
            except AcceptanceError as error:
                return {"requested": True, "acknowledged": False, "receipt": receipt, "reason": str(error)}
            try:
                exit_code = self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                return {"requested": True, "acknowledged": True, "receipt": receipt,
                        "reason": "app did not exit after restoration acknowledgement"}
            return {"requested": True, "acknowledged": True, "receipt": receipt,
                    "exit_code": exit_code}
        except (AcceptanceError, subprocess.SubprocessError) as error:
            try:
                receipt = self.retained_abort(expected_host_epoch, expected_session_epoch)
            except AcceptanceError as validation_error:
                return {"requested": True, "acknowledged": False, "reason": str(validation_error)}
            if receipt is not None:
                try:
                    exit_code = self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    return {"requested": True, "acknowledged": True, "receipt": receipt,
                            "reason": "app did not exit after its retained restoration acknowledgement"}
                return {"requested": True, "acknowledged": True, "receipt": receipt,
                        "exit_code": exit_code, "prior_wait_error": str(error)}
            return {"requested": True, "acknowledged": False, "reason": str(error)}

    def close(self):
        self.thread.join(timeout=2)
        self.log.close()


def execute(profile_root, app_bundle, output, repo=REPO, timeout=90):
    repo = Path(repo).resolve(strict=True)
    profile_root = Path(profile_root).resolve(strict=True)
    app_bundle = Path(app_bundle).resolve(strict=True)
    output = Path(output).expanduser().absolute()
    if output.is_symlink() or output.resolve().is_relative_to(repo) or output == Path("/"):
        raise AcceptanceError("acceptance output must be a fresh directory outside the source checkout")
    output.mkdir(parents=True, exist_ok=False)
    output = output.resolve(strict=True)
    profile = load_profile()
    profile.doctor(profile_root)
    env = profile.profile_environment(profile_root)
    before = source_snapshot(repo)
    binary = app_bundle / "Contents/MacOS/GpuiTextField"
    library = app_bundle / "Contents/Frameworks/libgpui_macos.dylib"
    plist = app_bundle / "Contents/Info.plist"
    if not binary.is_file() or not os.access(binary, os.X_OK) or not library.is_file() or not plist.is_file():
        raise AcceptanceError("fresh test-hook app bundle is incomplete")
    binary_sha = digest(binary)
    library_sha = digest(library)
    host = profile.host_identity()
    # Keep the xcrun-selected `swiftc` symlink as argv[0]. Xcode's swiftc is a
    # symlink to swift-frontend; invoking the resolved target changes argv[0]
    # and makes the frontend reject normal compiler arguments.
    swiftc = Path(subprocess.check_output(["xcrun", "--find", "swiftc"], text=True, env=env, timeout=10).strip())
    if not swiftc.is_absolute() or not swiftc.is_file():
        raise AcceptanceError("xcrun did not select an installed Swift compiler")
    swiftc_resolved = swiftc.resolve(strict=True)
    swiftc_version = subprocess.check_output([str(swiftc), "-version"], text=True, env=env, timeout=15).strip()
    compile_environment = {key: env[key] for key in ("DEVELOPER_DIR", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET")}
    swift_source = output / "owned-window-capture.swift"
    helper = output / "owned-window-capture"
    swift_source.write_text(SWIFT_WINDOW_CAPTURE)
    helper_compile_argv = [str(swiftc), "-parse-as-library", "-framework", "AppKit",
                           "-framework", "ScreenCaptureKit", "-framework", "ImageIO",
                           str(swift_source), "-o", str(helper)]
    compile_result = subprocess.run(helper_compile_argv,
                                    env=env, text=True, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=60)
    (output / "window-capture-build.log").write_text(compile_result.stdout)
    if compile_result.returncode != 0:
        raise AcceptanceError("could not build the ScreenCaptureKit own-window capture helper")
    env.update({"GPUI_FIELD_MACOS_IME": "1", "GPUI_FIELD_MACOS_E2E_STATE": "1",
                "GPUI_FIELD_MACOS_SOURCE_REVISION": before["commit"],
                "GPUI_FIELD_MACOS_SOURCE_TREE": before["tree"],
                "GPUI_FIELD_MACOS_BINARY_SHA256": binary_sha,
                "GPUI_MACOS_LIBRARY": str(library)})
    process = subprocess.Popen([str(binary), "--ime-acceptance"], cwd=repo, env=env,
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, bufsize=1, start_new_session=True)
    app = AppOutput(process, output / "app.stdout.log")
    report = {"schema_version": 1, "scope": "logged-in desktop, native Kotoeri callback and app-window pixels",
              "status": "running", "source_before": before, "host": host,
        "profile_root": str(profile_root),
        "app": {"bundle": str(app_bundle), "binary_sha256": binary_sha,
                      "library_sha256": library_sha, "binary_path": str(binary),
                      "info_plist_sha256": digest(plist),
                      "window_title": APP_TITLE},
              "capture_runtime": {"swiftc": str(swiftc), "swiftc_resolved": str(swiftc_resolved),
                                  "swiftc_sha256": digest(swiftc_resolved),
                                  "swiftc_version": swiftc_version,
                                  "compile_environment": compile_environment,
                                  "helper_compile_argv": helper_compile_argv,
                                  "helper_sha256": digest(helper), "engine": "ScreenCaptureKit.SCScreenshotManager",
                                  "helper_source_sha256": hashlib.sha256(SWIFT_WINDOW_CAPTURE.encode()).hexdigest()},
              "screenshots": {}, "ok": False}
    cleanup = None
    try:
        initial_state = app.wait_line("GPUI_FIELD_MACOS_STATE ", timeout)
        initial_ready = app.wait_line("GPUI_MACOS_IME_CHECKPOINT ", timeout)
        initial_ready = validate_checkpoint(initial_ready, "initial-ready", before, binary_sha)
        if not is_supported_kotoeri_japanese_romaji_source(initial_ready.get("input_source")):
            raise AcceptanceError("initial checkpoint did not prove a supported Kotoeri Japanese Romaji mode")
        validate_state(initial_state, before, binary_sha, initial=True)
        initial_identity = initial_ready.get("frame_identity")
        validate_frame_identity(initial_identity, "initial checkpoint frame")
        if type(initial_identity) is not dict or \
           initial_identity.get("window_id", 0) <= 0 or initial_identity.get("host_epoch", 0) <= 0 or \
           initial_identity.get("session_epoch") != initial_state.get("session_epoch") or \
           initial_ready.get("session_epoch") != initial_state.get("session_epoch") or \
           initial_ready.get("text") != initial_state.get("text") or \
           initial_ready.get("field_revision") != initial_state.get("revision") or \
           initial_identity.get("accepted_revision") != initial_state.get("revision") or \
           initial_identity.get("frame_revision", 0) <= 0 or \
           initial_identity.get("text") != initial_state.get("text") or \
           not re.fullmatch(r"[0-9a-f]{64}", str(initial_identity.get("frame_sha256", ""))):
            raise AcceptanceError("initial state observer and accepted native frame identity disagree")
        initial_geometry = validate_initial_window(initial_ready, initial_state, initial_identity)
        report["initial_state"] = initial_state
        report["app_pid"] = process.pid
        report["initial_checkpoint"] = initial_ready
        report["input_source"] = initial_ready["input_source"]
        initial_png = output / "initial-window.png"
        initial_capture = capture_own_window(process.pid, APP_TITLE, initial_png, helper)
        report["screenshots"]["initial"] = bind_capture(initial_capture, "initial", initial_identity,
                                                            initial_state["field_bounds"], initial_state["caret"],
                                                            initial_geometry, initial_png)
        process.stdin.write("begin\n")
        process.stdin.flush()

        composing = app.wait_line("GPUI_MACOS_IME_CHECKPOINT ", timeout)
        composing = validate_checkpoint(composing, "composition-ready", before, binary_sha)
        validate_frame_identity(composing.get("frame_identity"), "composition checkpoint frame")
        if composing.get("composing") is not True or composing.get("marked") is None or \
           composing.get("committed") != "Hello " or not isinstance(composing.get("text"), str) or \
           not any(char in composing["text"] for char in "日本語にほんご"):
            raise AcceptanceError("accepted preedit frame does not render a marked Japanese composition")
        identity = composing.get("frame_identity")
        if type(identity) is not dict or identity.get("window_id") != initial_identity["window_id"] or \
           identity.get("host_epoch") != initial_identity["host_epoch"] or \
           identity.get("session_epoch") != initial_identity["session_epoch"] or \
           identity.get("accepted_revision") != composing.get("field_revision") or \
           identity.get("frame_revision", 0) <= initial_identity.get("frame_revision", 0) or \
           identity.get("text") != composing.get("text") or \
           not re.fullmatch(r"[0-9a-f]{64}", str(identity.get("frame_sha256", ""))):
            raise AcceptanceError("preedit screenshot checkpoint is not bound to its accepted frame")
        if not isinstance(composing.get("marked"), dict) or \
           type(composing["marked"].get("start")) is not int or type(composing["marked"].get("end")) is not int or \
           composing["marked"]["start"] < 0 or composing["marked"]["end"] <= composing["marked"]["start"] or \
           composing.get("session_epoch") != initial_state.get("session_epoch") or \
           not isinstance(composing.get("caret"), dict) or not _finite_number(composing["caret"].get("x")) or \
           not _finite_number(composing["caret"].get("y")) or \
           not _finite_number(composing["caret"].get("width")) or not _finite_number(composing["caret"].get("height")) or \
           composing["caret"]["width"] <= 0 or composing["caret"]["height"] <= 0:
            raise AcceptanceError("composition checkpoint omits a valid mark range or caret geometry")
        candidate = composing.get("candidate_screen_rect")
        if type(candidate) is not dict or set(candidate) != {"x", "y", "width", "height"} or \
           any(not _finite_number(candidate.get(key)) for key in ("x", "y", "width", "height")) or \
           candidate["width"] <= 0 or candidate["height"] <= 0:
            raise AcceptanceError("composition checkpoint omits finite candidate geometry")
        report["composition_checkpoint"] = composing
        composition_png = output / "composition-window.png"
        composition_capture = capture_own_window(process.pid, APP_TITLE, composition_png, helper)
        report["screenshots"]["composition"] = bind_capture(composition_capture, "composition", identity,
                                                               composing["field_bounds"], composing["caret"],
                                                               initial_geometry, composition_png)
        process.stdin.write("preview\n")
        process.stdin.flush()

        final = app.wait_line("GPUI_MACOS_IME_ACCEPTANCE ", timeout)
        final = validate_final(final, before, binary_sha, initial_state["revision"], initial_identity["frame_revision"])
        if final["window_id"] != initial_identity["window_id"] or final["host_epoch"] != initial_identity["host_epoch"] or \
           final["session_epoch"] != initial_identity["session_epoch"] or \
           final["final_frame_revision"] <= identity["frame_revision"]:
            raise AcceptanceError("final accepted presentation is not a newer frame from the launched host/session")
        report["final_acceptance"] = final
        final_png = output / "final-window.png"
        final_capture = capture_own_window(process.pid, APP_TITLE, final_png, helper)
        report["screenshots"]["final"] = bind_capture(final_capture, "final", final["final_frame_identity"],
                                                         final["field_bounds"], None, initial_geometry, final_png)
        process.stdin.write("quit\n")
        process.stdin.flush()
        exit_code = process.wait(timeout=timeout)
        if exit_code != 0:
            raise AcceptanceError("IME acceptance app exited unsuccessfully: " + str(exit_code))
        app.close()
        pixels = {name: png_pixels(output / report["screenshots"][name]["path"])
                  for name in ("initial", "composition", "final")}
        deltas = {"initial_to_composition": pixel_difference(pixels["initial"], pixels["composition"]),
                  "composition_to_final": pixel_difference(pixels["composition"], pixels["final"]),
                  "initial_to_final": pixel_difference(pixels["initial"], pixels["final"])}
        roi_frames = {name: {"image": pixels[name], "roi": report["screenshots"][name]["text_roi"]}
                      for name in ("initial", "composition", "final")}
        roi_deltas = {"initial_to_composition": text_roi_difference(roi_frames["initial"], roi_frames["composition"]),
                      "composition_to_final": text_roi_difference(roi_frames["composition"], roi_frames["final"]),
                      "initial_to_final": text_roi_difference(roi_frames["initial"], roi_frames["final"])}
        if any(item["changed_pixels"] < 32 for item in deltas.values()):
            raise AcceptanceError("own-window text/preedit changes were not present in captured pixels")
        for phase, difference in roi_deltas.items():
            require_text_change(difference, phase)
        report["pixel_differences"] = deltas
        report["text_roi_differences"] = roi_deltas
        screenshot_index = {name: dict(item) for name, item in report["screenshots"].items()}
        screenshot_index_path = output / "screenshots-index.json"
        screenshot_index_path.write_text(json.dumps(screenshot_index, indent=2, ensure_ascii=False) + "\n")
        report["screenshots_index"] = screenshot_index_path.name
        report["screenshots_index_sha256"] = digest(screenshot_index_path)
        report["app_exit_code"] = exit_code
        report["ok"] = True
        report["status"] = "passed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = str(error)
        if process.poll() is None:
            try:
                initial = report.get("initial_state", {})
                checkpoint = report.get("initial_checkpoint", {})
                frame = checkpoint.get("frame_identity", {})
                cleanup = app.abort_and_wait(expected_host_epoch=frame.get("host_epoch"),
                                             expected_session_epoch=initial.get("session_epoch"))
            except subprocess.SubprocessError:
                cleanup = {"requested": True, "acknowledged": False,
                           "reason": "app-owned abort handshake failed"}
            if process.poll() is None:
                try:
                    process.kill()
                    process.wait(timeout=5)
                    cleanup["forced_termination"] = True
                except subprocess.SubprocessError:
                    cleanup["forced_termination"] = "failed"
        report["cleanup"] = cleanup
        try:
            app.close()
        except Exception:
            pass
        raise
    finally:
        after = source_snapshot(repo)
        report["source_after"] = after
        report["source_stable"] = before == after
        if before != after:
            report["ok"] = False
            report["status"] = "failed"
            report["error"] = "source changed during IME/pixel acceptance"
        report["finished_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        (output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if report.get("ok") is True:
        try:
            validate_summary(output / "summary.json", repo, before)
        except (AcceptanceError, OSError, ValueError, KeyError, TypeError) as error:
            report["ok"] = False
            report["status"] = "failed"
            report["error"] = "independent IME artifact validation failed: " + str(error)
            (output / "summary.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    if not report["ok"]:
        raise AcceptanceError(report.get("error", "IME/pixel acceptance failed"))
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=REPO)
    parser.add_argument("--profile", required=True, help="external qualified Mac quality profile root")
    parser.add_argument("--app", required=True, type=Path, help="fresh GPUI text-field test-hook app bundle")
    parser.add_argument("--output", required=True, type=Path, help="new external evidence directory")
    parser.add_argument("--timeout", type=int, default=90)
    args = parser.parse_args(argv)
    if not 10 <= args.timeout <= 600:
        parser.error("--timeout must be in 10..600 seconds")
    prior_sigterm = signal.getsignal(signal.SIGTERM)
    def handle_sigterm(_signum, _frame):
        raise AcceptanceError("actrun requested bounded termination; attempting app-owned input-source restoration")
    signal.signal(signal.SIGTERM, handle_sigterm)
    try:
        try:
            report = execute(args.profile, args.app, args.output, args.repo, args.timeout)
            print("summary=" + str(Path(args.output).resolve() / "summary.json"))
            print("GREEN scope=macos-kotoeri-pixels source=" + report["source_before"]["commit"])
            return 0
        except (AcceptanceError, OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            print("macos-ime-acceptance: " + str(error), file=sys.stderr)
            return 1
    finally:
        signal.signal(signal.SIGTERM, prior_sigterm)


if __name__ == "__main__":
    sys.exit(main())
