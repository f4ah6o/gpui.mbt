"""Pure helper/fixture checks: these tests never launch or inject input."""
import ast
import ctypes as C
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest
from PIL import Image

HERE = Path(__file__).resolve().parents[1]
SOURCE = HERE / "os-input-e2e.py"
TEXT = SOURCE.read_text()
TREE = ast.parse(TEXT)
HELPERS = ast.Module(body=[node for node in TREE.body if isinstance(node, ast.FunctionDef)
                          and node.name in ["auth_file", "window_named"]], type_ignores=[])
NAMESPACE = {"C": C, "struct": struct}
exec(compile(HELPERS, str(SOURCE), "exec"), NAMESPACE)


class FakeXlib:
    def __init__(self, ids):
        self.ids = (C.c_ulong * len(ids))(*ids)
        self.frees = 0
    def XDefaultRootWindow(self, display):
        return 1
    def XQueryTree(self, display, root, root_pointer, parent_pointer, children_pointer, count_pointer):
        C.cast(children_pointer, C.POINTER(C.POINTER(C.c_ulong)))[0] = C.cast(self.ids, C.POINTER(C.c_ulong))
        C.cast(count_pointer, C.POINTER(C.c_uint))[0] = len(self.ids)
        return 1
    def XFetchName(self, *args):
        return 0
    def XFree(self, *args):
        self.frees += 1


class AdapterTests(unittest.TestCase):
    def test_logged_window_ownership_works_without_legacy_name(self):
        xlib = FakeXlib([4194309])
        NAMESPACE["xlib"] = xlib
        self.assertEqual(NAMESPACE["window_named"](object(), "Weston", 4194309), 4194309)
        self.assertEqual(xlib.frees, 1)
    def test_unrelated_window_id_is_rejected(self):
        NAMESPACE["xlib"] = FakeXlib([7])
        self.assertIsNone(NAMESPACE["window_named"](object(), "Weston", 4194309))
    def test_private_authentication_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "auth"
            NAMESPACE["auth_file"](path, 4321, b"x" * 16)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertTrue(path.read_bytes().endswith(struct.pack(">H", 16) + b"x" * 16))
    def test_static_display_guards_and_short_runtime(self):
        for required in ["1000+secrets.randbelow(10000)", "Refusing inherited display",
                         "Private display number already in use", "prefix='gpe-',dir='/tmp'",
                         "len(os.fsencode(runtime/'gpui-e2e'))>=108", "runtime_directory.cleanup()",
                         "env.pop('WAYLAND_SOCKET',None)"]:
            self.assertIn(required, TEXT)
        self.assertIn("'-nolisten','tcp','-auth',env['XAUTHORITY']", TEXT)
        self.assertNotIn("'-ac'", TEXT)
    def test_exact_protocol_and_pixel_oracles_are_required(self):
        self.assertIn("report['wayland_key_events']==14", TEXT)
        self.assertIn("report.get('golden_pixel_match',False)", TEXT)
        self.assertIn("Refusing changed binary", TEXT)
        self.assertIn("sys.exit(0 if results[-1]['status']=='passed' else 1)", TEXT)
        self.assertIn("Refusing nonempty artifact directory", TEXT)
    def test_synthetic_golden_matches_predeclared_metadata(self):
        metadata = json.loads((HERE / "fixtures/field-six-keys.provenance.json").read_text())
        image = HERE / "fixtures" / metadata["image"]
        self.assertEqual(hashlib.sha256(image.read_bytes()).hexdigest(), metadata["png_sha256"])
        with Image.open(image) as opened:
            pixels = opened.convert("RGBA")
            self.assertEqual(list(pixels.size), metadata["dimensions"])
            self.assertEqual(hashlib.sha256(pixels.tobytes()).hexdigest(), metadata["rgba_pixel_sha256"])
        self.assertEqual(metadata["expected_text"], "Hello 日本abD")
        self.assertEqual(metadata["expected_selection_utf16"], {"anchor": 10, "focus": 10})


if __name__ == "__main__":
    unittest.main()
