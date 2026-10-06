#!/usr/bin/python3
"""Static safety, protocol parsing and pixel-geometry tests; no native launch."""
import ast
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import evidence
import probe
spec = importlib.util.spec_from_file_location('prepare_launcher', HERE / 'prepare-launcher.py')
prepare_launcher = importlib.util.module_from_spec(spec); spec.loader.exec_module(prepare_launcher)


class ProbeTests(unittest.TestCase):
    def test_import_is_read_only(self):
        with patch('subprocess.Popen', side_effect=AssertionError('must not launch')), patch('subprocess.run', side_effect=AssertionError('must not launch')):
            spec = importlib.util.spec_from_file_location('probe_import_safety', HERE / 'probe.py')
            spec.loader.exec_module(importlib.util.module_from_spec(spec))

    def test_check_is_read_only(self):
        with patch('subprocess.Popen', side_effect=AssertionError('must not launch')), patch('subprocess.run', side_effect=AssertionError('must not launch')):
            with patch('builtins.print'):
                self.assertEqual(probe.main(['--check']), 0)

    def test_wrapper_preserves_privileged_socket(self):
        script = probe.input_method_wrapper(Path('/owned/prefix'), Path('/owned/output'))
        self.assertIn('test -n "${WAYLAND_SOCKET:-}"', script)
        self.assertNotIn('unset WAYLAND_SOCKET', script)
        self.assertNotIn('WAYLAND_SOCKET=', script)
        self.assertIn('exec /owned/prefix/usr/libexec/ibus-ui-gtk3 --enable-wayland-im', script)
        self.assertNotIn('--exec-daemon', script)

    def test_wrapper_has_isolated_native_mode(self):
        script = probe.input_method_wrapper(Path('/owned/prefix'), Path('/owned/output'))
        self.assertIn('unset GTK_IM_MODULE QT_IM_MODULE', script)
        self.assertIn('GDK_BACKEND=wayland', script)
        self.assertIn('IBUS_ENABLE_SYNC_MODE=1', script)

    def test_config_uses_desktop_shell_and_owned_wrapper(self):
        config = probe.weston_config(Path('/owned/prefix'), Path('/owned/wrapper'))
        self.assertIn('client=/owned/prefix/usr/libexec/weston-desktop-shell', config)
        self.assertIn('startup-animation=none', config)
        self.assertIn('panel-position=none', config)
        self.assertIn('locking=false', config)
        self.assertIn('[input-method]\npath=/owned/wrapper', config)
        self.assertNotIn('kiosk', config)

    def test_only_one_x_connection_call(self):
        tree = ast.parse((HERE / 'probe.py').read_text())
        calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'connect']
        self.assertEqual(len(calls), 1)
        source = (HERE / 'probe.py').read_text()
        self.assertIn('sole authenticated private XOpenDisplay failed; no retry or alternate route', source)
        self.assertNotIn('XOpenDisplay(', source)

    def test_cleanup_stays_identity_bound(self):
        source = (HERE / 'probe.py').read_text()
        self.assertIn('pidfd_send_signal', source)
        self.assertNotIn('killall', source)
        self.assertNotIn('pkill', source)
        self.assertIn("'GPUI_IME_PROBE_TOKEN': token", source)
        self.assertIn('baseline.private_processes(token, home, config)', source)

    def test_no_callback_or_japanese_input_injection(self):
        source = (HERE / 'probe.py').read_text()
        self.assertNotIn('type_text', source)
        self.assertNotIn('CommitText', source)
        self.assertNotIn('UpdatePreeditText', source)
        self.assertNotIn('GPUI_FIELD_E2E_STATE', source)
        self.assertIn("for name in 'nihonn'", source)

    def test_fresh_native_context_focus(self):
        focus = "    path -> objectpath '/org/freedesktop/IBus/InputContext_2'\n    interface -> 'org.freedesktop.IBus.InputContext'\n    member -> 'FocusIn'"
        self.assertFalse(evidence.native_context_ready(focus))
        self.assertFalse(evidence.native_context_ready(focus + "\n  Body: ('wayland',)"))
        self.assertTrue(evidence.native_context_ready("  Body: ('wayland',)\n" + focus))

    def test_exact_context_focus_precedes_first_key(self):
        frame = {'direction': 'SENT', 'type': 'method-call', 'interface': 'org.freedesktop.IBus.InputContext',
                 'member': 'FocusIn', 'path': '/org/freedesktop/IBus/InputContext_2', 'frame': 10}
        self.assertTrue(evidence.exact_context_focused([frame], frame['path'], 8, 12))
        self.assertFalse(evidence.exact_context_focused([frame], '/org/freedesktop/IBus/InputContext_20', 8, 12))
        self.assertFalse(evidence.exact_context_focused([frame], frame['path'], 10, 12))
        self.assertFalse(evidence.exact_context_focused([frame], frame['path'], 8, 10))

    def test_text_receipts_parse_exactly(self):
        log = '[123.000] {Default Queue} zwp_text_input_v1#21.preedit_string(4, "にほん", "にほん")\n[124.000] {Default Queue} zwp_text_input_v1#21.commit_string(5, "日本")\n'
        events = evidence.text_events(log, 'zwp_text_input_v1', False)
        self.assertEqual([e['text'] for e in events], ['にほん', '日本'])
        self.assertEqual([e['serial'] for e in events], [4, 5])
        self.assertEqual([e['object'] for e in events], [21, 21])

    def test_text_outputs_parse_exactly(self):
        log = '[123.000] {Default Queue}  -> zwp_input_method_context_v1#4278190080.preedit_string(4, "にほん", "にほん")\n'
        self.assertEqual(evidence.text_events(log, 'zwp_input_method_context_v1', True)[0]['text'], 'にほん')

    def test_malformed_text_signature_fails_closed(self):
        log = '[123.000] {Default Queue} zwp_text_input_v1#21.preedit_string(4, "にほん")\n'
        with self.assertRaises(evidence.EvidenceError):
            evidence.text_events(log, 'zwp_text_input_v1', False)

    def test_unknown_text_format_fails_closed(self):
        log = '[123.000] {Default Queue} zwp_text_input_v1#21.commit_string(4, unquoted)\n'
        with self.assertRaises(evidence.EvidenceError):
            evidence.text_events(log, 'zwp_text_input_v1', False)

    def test_direction_is_not_reclassified(self):
        log = '[123.000] {Default Queue}  -> zwp_text_input_v1#21.commit_string(4, "日本")\n'
        self.assertEqual(evidence.text_events(log, 'zwp_text_input_v1', False), [])

    def test_pixel_bound_click_is_inside_top_entry(self):
        from PIL import Image, ImageDraw
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'image.png'
            image = Image.new('RGB', (960, 640), (32, 32, 32))
            ImageDraw.Draw(image).rectangle((135, 198, 570, 527), fill='white')
            image.save(path)
            self.assertEqual(probe.editor_click_from_pixels(path), {'x': 185, 'y': 298, 'body': [135, 198, 571, 527]})

    def test_empty_pixel_geometry_fails(self):
        from PIL import Image
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'image.png'; Image.new('RGB', (960, 640), (32, 32, 32)).save(path)
            with self.assertRaises(RuntimeError): probe.editor_click_from_pixels(path)

    def test_ambiguous_pixel_geometry_fails(self):
        from PIL import Image, ImageDraw
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'image.png'; image = Image.new('RGB', (1200, 640), (32, 32, 32))
            draw = ImageDraw.Draw(image); draw.rectangle((20, 100, 455, 429), fill='white'); draw.rectangle((650, 100, 1085, 429), fill='white'); image.save(path)
            with self.assertRaises(RuntimeError): probe.editor_click_from_pixels(path)

    def test_gpui_ime_claim_rejected(self):
        with self.assertRaises(evidence.EvidenceError):
            evidence.qualify(Path('/unused'), {'gpui_ime_verified': True}, {})

    def test_raw_shutdown_log_is_not_silently_trimmed(self):
        data = json.loads((HERE / 'deployment.lock.json').read_text())
        with self.assertRaises(ValueError):
            evidence.strict_dbus_frames('========================================================================\nGDBus-debug:Message:\n  >>>> SENT D-Bus message (348 bytes)\n', Path(data['transport_parser']))

    def test_relevant_strict_gio_key_frame(self):
        data = json.loads((HERE / 'deployment.lock.json').read_text())
        log = '\n'.join(['========================================================================', 'GDBus-debug:Message:', '  >>>> SENT D-Bus message (200 bytes)',
            '[123.000] {Default Queue} wl_keyboard#19.key(5, 123, 49, 1)',
            '  Type:    method-call', '  Flags:   no-auto-start', '  Version: 0', '  Serial:  4', '  Headers:',
            "    path -> objectpath '/org/freedesktop/IBus/InputContext_2'", "    interface -> 'org.freedesktop.IBus.InputContext'", "    member -> 'ProcessKeyEvent'",
            "    destination -> ':1.0'", "    signature -> signature 'uuu'", '  Body: (uint32 110, uint32 49, uint32 0)', '  UNIX File Descriptors:', '    (none)', ''])
        frames, removed = evidence.strict_dbus_frames(log, Path(data['transport_parser']))
        self.assertEqual(len(removed), 1)
        self.assertEqual(frames[0]['keyval'], 110)
        self.assertEqual(frames[0]['keycode'], 49)

    def test_launcher_preparation_does_not_execute(self):
        with tempfile.TemporaryDirectory() as folder:
            data = {'output_root': folder, 'prefix': '/owned/prefix', 'support': '/owned/support'}
            with patch.object(probe, 'preflight', return_value=(data, None, None)), patch('subprocess.Popen', side_effect=AssertionError('must not launch')):
                launcher, output = prepare_launcher.prepare(Path('/owned/deployment.json'), 'replay-one')
            self.assertTrue(launcher.is_file())
            self.assertFalse(output.exists())
            self.assertIn('--run-native', launcher.read_text())
            self.assertIn('LD_LIBRARY_PATH=/owned/prefix/usr/lib/x86_64-linux-gnu', launcher.read_text())

    def test_launcher_reuse_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            data = {'output_root': folder, 'prefix': '/owned/prefix', 'support': '/owned/support'}
            with patch.object(probe, 'preflight', return_value=(data, None, None)):
                prepare_launcher.prepare(Path('/owned/deployment.json'), 'replay-one')
                with self.assertRaises(RuntimeError): prepare_launcher.prepare(Path('/owned/deployment.json'), 'replay-one')

    def test_launcher_name_cannot_escape_task_root(self):
        for name in ('../other', 'native/one', '', '/absolute', 'a b'):
            with self.assertRaises(RuntimeError): prepare_launcher.prepare(Path('/owned/deployment.json'), name)

    def test_desktop_quote_escapes_field_codes(self):
        value = prepare_launcher.desktop_quote('/owned/a %f $b "c"')
        self.assertIn('%%f', value)
        self.assertIn('\\' * 2 + '$b', value)
        self.assertIn('\\' * 2 + '"c' + '\\' * 2 + '"', value)
        self.assertIn('\\' * 4 + 'b', prepare_launcher.desktop_quote('a\\b'))


if __name__ == '__main__':
    unittest.main()
