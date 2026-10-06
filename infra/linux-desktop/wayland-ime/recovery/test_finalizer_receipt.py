"""Execute only the actual terminal finally block with inert process objects.

No native services, display connection, signals, or foreign process reads occur.
Strict scan errors must persist a failed receipt and keep the private runtime.
"""
import ast
import hashlib
import io
import json
from pathlib import Path
import shutil
import signal
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock


HERE = Path(__file__).resolve().parents[1]


class TickClock:
    def __init__(self):
        self.value = 0.0

    def monotonic(self):
        self.value += 0.1
        return self.value

    def sleep(self, seconds):
        self.value += seconds


def terminal_block(path):
    tree = ast.parse(path.read_text())
    run = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'run')
    blocks = [node.finalbody for node in run.body if isinstance(node, ast.Try) and node.finalbody]
    if len(blocks) != 1:
        raise AssertionError('expected the one native-run terminal finally block')
    cleanup_tree = tree if path.name=='probe.py' else ast.parse((HERE/'probe.py').read_text())
    cleanup = next(node for node in cleanup_tree.body if isinstance(node,ast.FunctionDef) and node.name=='cleanup_owned_native')
    return compile(ast.Module(body=[cleanup]+blocks[0], type_ignores=[]), str(path), 'exec')


class CleanupReceiptTests(unittest.TestCase):
    def exercise(self, name='gpui_probe.py', failure=None, fail_at=None):
        source = HERE / name
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        runtime, output = root/'private-runtime', root/'output'
        runtime.mkdir(mode=0o700); output.mkdir(mode=0o700)
        home, config = runtime/'home', runtime/'config'
        home.mkdir(mode=0o700); config.mkdir(mode=0o700)
        calls = []

        def scan(*arguments):
            calls.append(arguments)
            if failure is not None and (fail_at is None or len(calls) == fail_at):
                raise failure
            return []

        def write_json(path, value):
            path.write_text(json.dumps(value, ensure_ascii=False, indent=2)+'\n')

        remove = Mock(side_effect=shutil.rmtree)
        no_signal = Mock(side_effect=AssertionError('no real or fake PID should be signaled by this empty fixture'))
        report = {'schema_version':1, 'status':'passed', 'native_executed':True,
                  'full_suite_verified':True, 'render_readiness':[]}
        namespace = {
            '__file__':str(source), 'x':None, 'pressed':[], 'processes':[],
            'streams':[], 'events':io.StringIO(), 'report':report,
            'baseline':SimpleNamespace(private_processes=scan),
            'token':'a1'*24, 'home':home, 'config':config, 'runtime':runtime,
            'task_owner':None,
            'output':output, 'time':TickClock(), 'started':0.0,
            'signal':SimpleNamespace(SIGTERM=signal.SIGTERM, SIGKILL=signal.SIGKILL,
                                     pidfd_send_signal=no_signal),
            'os':SimpleNamespace(pidfd_open=no_signal, close=no_signal),
            'shutil':SimpleNamespace(rmtree=remove), 'write_json':write_json,
            'sha':lambda path:hashlib.sha256(Path(path).read_bytes()).hexdigest(),
            'stop':Mock(side_effect=AssertionError('this empty fixture has no children to stop')),
        }
        exec(terminal_block(source), namespace, namespace)
        no_signal.assert_not_called()
        result = output/'result.json'
        self.assertTrue(result.is_file(), 'terminal result must survive a strict scan exception')
        return json.loads(result.read_text()), runtime, remove, calls

    def assert_failed_retained(self, value, runtime, remove, expected):
        self.assertEqual(value['status'], 'error')
        self.assertIs(value['cleanup']['verified'], False)
        self.assertTrue(value['cleanup']['errors'])
        self.assertTrue(any(expected in message for message in value['cleanup']['errors']))
        self.assertIn('cleanup_blocker', value)
        self.assertTrue(runtime.exists(), 'unverified runtime must be retained')
        remove.assert_not_called()

    def test_permission_malformed_and_race_scan_errors_persist_failed_receipt(self):
        for error in (PermissionError('owned proc read denied'),
                      ValueError('malformed ownership environment'),
                      RuntimeError('private process identity changed')):
            with self.subTest(error=type(error).__name__):
                value, runtime, remove, calls = self.exercise(failure=error)
                self.assertTrue(calls)
                self.assert_failed_retained(value, runtime, remove, str(error))

    def test_initial_poll_and_final_scan_sites_all_fail_closed(self):
        successful, _, _, calls = self.exercise()
        self.assertTrue(successful['cleanup']['verified'])
        # Enumerate actual normal-path calls, then inject at each one. This
        # covers the initial signal scan, poll, and terminal survivors audit.
        self.assertGreaterEqual(len(calls), 3)
        for index in range(1, len(calls)+1):
            with self.subTest(scan_call=index):
                value, runtime, remove, _ = self.exercise(
                    failure=PermissionError('scan failure '+str(index)), fail_at=index)
                self.assert_failed_retained(value, runtime, remove, 'scan failure '+str(index))

    def test_empty_success_control_writes_verified_receipt_and_removes_runtime(self):
        value, runtime, remove, calls = self.exercise()
        self.assertEqual(value['status'], 'passed')
        self.assertIs(value['cleanup']['verified'], True)
        self.assertFalse(value['cleanup']['errors'])
        self.assertFalse(runtime.exists())
        remove.assert_called_once()
        self.assertTrue(calls)


if __name__ == '__main__':
    unittest.main()
