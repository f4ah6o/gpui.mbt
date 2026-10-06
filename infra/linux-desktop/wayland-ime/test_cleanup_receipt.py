"""No native launch: exercise actual finalizer with injected ownership failures."""
import ast
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import gpui_probe as probe


class CleanupReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.runtime = self.root / 'runtime'
        self.runtime.mkdir(mode=0o700)
        self.baseline = types.SimpleNamespace(private_processes=Mock(return_value=[]),
            stat_identity=Mock())

    def cleanup(self, **kwargs):
        return probe.cleanup_owned_native(None, [], [], Mock(), self.baseline,
            'token', self.runtime / 'home', self.runtime / 'config', self.runtime,
            **kwargs)

    def test_empty_complete_scans_remove_owned_runtime(self):
        result = self.cleanup()
        self.assertTrue(result['verified'])
        self.assertTrue(result['scan_complete'])
        self.assertTrue(result['runtime_removed'])
        self.assertFalse(self.runtime.exists())

    def test_all_three_scan_sites_fail_closed(self):
        for replies in ([PermissionError('scan denied')],
                        [[], PermissionError('wait denied')],
                        [[], [], [], [], PermissionError('final denied')]):
            with self.subTest(replies=replies), patch('os.pidfd_open', side_effect=AssertionError('signal')):
                self.baseline.private_processes.side_effect = replies
                result = self.cleanup()
                self.assertFalse(result['verified'])
                self.assertFalse(result['scan_complete'])
                self.assertIsNone(result['survivors'])
                self.assertTrue(result['errors'])
                self.assertFalse(result['runtime_removed'])
                self.assertTrue(self.runtime.exists())

    def test_actual_finally_writes_failed_terminal_receipt(self):
        source = ast.parse((HERE / 'gpui_probe.py').read_text())
        run = next(n for n in source.body if isinstance(n, ast.FunctionDef) and n.name == 'run')
        final = next(n for n in run.body if isinstance(n, ast.Try) and n.finalbody).finalbody
        output = self.root / 'output'; output.mkdir()
        self.baseline.private_processes.side_effect = PermissionError('exact ownership scan denied')
        report = {'status': 'passed', 'render_readiness': []}
        namespace = dict(probe.__dict__, x=None, pressed=[], processes=[], stop=Mock(),
            baseline=self.baseline, token='token', home=self.runtime / 'home',
            config=self.runtime / 'config', runtime=self.runtime, streams=[],
            events=io.StringIO(), report=report, started=time.monotonic(), output=output,
            task_owner=None)
        with patch('os.pidfd_open', side_effect=AssertionError('signal')):
            exec(compile(ast.Module(body=final, type_ignores=[]), 'actual-finally', 'exec'), namespace)
        saved = json.loads((output / 'result.json').read_text())
        self.assertEqual(saved['status'], 'error')
        self.assertFalse(saved['cleanup']['verified'])
        self.assertFalse(saved['cleanup']['scan_complete'])
        self.assertIsNone(saved['cleanup']['survivors'])
        self.assertIn('exact ownership scan denied', saved['cleanup']['errors'][0])
        self.assertTrue(self.runtime.exists())

    def test_reused_pid_never_signalled_or_declared_clean(self):
        old = {'pid': 123, 'starttime': 1, 'exe': '/owned/exe'}
        self.baseline.private_processes.side_effect = [[old], [], [], [], []]
        self.baseline.stat_identity.return_value = dict(old, starttime=2)
        with patch('os.pidfd_open', return_value=91), patch('os.close'), patch('signal.pidfd_send_signal') as signal:
            result = self.cleanup()
        signal.assert_not_called()
        self.assertFalse(result['verified'])
        self.assertTrue(self.runtime.exists())
        self.assertIn('PID identity changed', result['errors'][0])

    def test_display_close_error_is_retained(self):
        display = Mock(); display.close.side_effect = RuntimeError('display close')
        result = probe.cleanup_owned_native(display, [], [], Mock(), self.baseline,
            'token', self.runtime / 'home', self.runtime / 'config', self.runtime)
        self.assertFalse(result['verified'])
        self.assertTrue(self.runtime.exists())
        self.assertIn('display close', result['errors'][0])

    def test_diagnostic_capture_exact_path_no_clobber(self):
        (self.root / '.gpui-ime-recovery-evidence').write_text('native-ime-recovery-evidence-v1\n')
        output = self.root / 'runs' / 'bounded-run'
        log = self.root / 'bounded-run.launcher.log'
        with patch('os.dup2') as duplicate:
            probe.capture_launcher_diagnostics(log, output, self.root)
        self.assertEqual([c.args[1] for c in duplicate.call_args_list], [1, 2])
        self.assertEqual(log.stat().st_mode & 0o777, 0o600)
        with self.assertRaises(FileExistsError):
            probe.capture_launcher_diagnostics(log, output, self.root)
        with self.assertRaises(RuntimeError):
            probe.capture_launcher_diagnostics(self.root / 'foreign.log', output, self.root)
        log.unlink(); log.symlink_to(self.root / 'foreign-target')
        with self.assertRaises(FileExistsError):
            probe.capture_launcher_diagnostics(log, output, self.root)
        self.assertFalse((self.root / 'foreign-target').exists())

    def test_check_cannot_create_diagnostic_log(self):
        with patch.object(probe, 'preflight', return_value=({'pins': {}, 'overlay': {'candidate': {}}, 'candidate_verification': {}}, None, None)), patch.object(probe, 'capture_launcher_diagnostics', side_effect=AssertionError('write')):
            with self.assertRaises(SystemExit):
                probe.main(['--check', '--deployment', str(self.root / 'overlay.json'),
                    '--diagnostic-log', str(self.root / 'check.log')])
        self.assertFalse((self.root / 'check.log').exists())

    def test_real_stdout_stderr_capture_without_native_execution(self):
        (self.root / '.gpui-ime-recovery-evidence').write_text('native-ime-recovery-evidence-v1\n')
        log = self.root / 'bounded-run.launcher.log'
        output = self.root / 'runs' / 'bounded-run'
        script = 'import sys; from pathlib import Path; sys.path.insert(0,sys.argv[1]); import gpui_probe as p; p.capture_launcher_diagnostics(Path(sys.argv[2]),Path(sys.argv[3]),Path(sys.argv[4])); print("owned stdout",flush=True); print("owned stderr",file=sys.stderr,flush=True)'
        result = subprocess.run([sys.executable, '-c', script, str(HERE), str(log), str(output), str(self.root)], capture_output=True, check=True)
        self.assertEqual(result.stdout, b''); self.assertEqual(result.stderr, b'')
        self.assertEqual(log.read_text(), 'owned stdout\nowned stderr\n')


if __name__ == '__main__':
    unittest.main()
