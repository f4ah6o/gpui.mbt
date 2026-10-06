"""Recovery helper safety/grammar tests; no native services or input."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import baseline_utilities as util


def varint(number):
    result = bytearray()
    while number >= 128:
        result.append((number & 127) | 128)
        number >>= 7
    result.append(number)
    return bytes(result)


def string_field(number, text):
    raw = text.encode('utf-8')
    return varint(number * 8 + 2) + varint(len(raw)) + raw


def uint_field(number, value):
    return varint(number * 8) + varint(value)


def record(pid=1234, key='1a' * 16, thread=0, protocol=3, version='2.29.5160.102'):
    return (string_field(1, key) + uint_field(2, pid) + uint_field(3, thread) +
            uint_field(4, protocol) + string_field(5, version))


def proc_stat(pid, starttime=123, comm=b'worker (complex) name'):
    fields = [b'S'] + [b'0'] * 18 + [str(starttime).encode()] + [b'0'] * 30
    fields[17]=b'1'
    return str(pid).encode() + b' (' + comm + b') ' + b' '.join(fields) + b'\n'


class IPCGrammarTests(unittest.TestCase):
    def test_official_complete_writer_schema(self):
        self.assertEqual(util.ipc_pid(record()), 1234)

    def test_schema_order_independent(self):
        self.assertEqual(util.ipc_pid(string_field(5, '2.29.5160.102') + uint_field(4, 3) +
            uint_field(3, 0) + uint_field(2, 44) + string_field(1, 'a' * 32)), 44)

    def test_duplicate_unknown_and_wire_mutations_fail(self):
        for mutation in (record() + uint_field(2, 1234), record() + uint_field(6, 1),
                         bytes([8]) + record()[1:], bytes([19]) + record()[1:]):
            with self.subTest(mutation=mutation):
                with self.assertRaises(ValueError): util.ipc_pid(mutation)

    def test_missing_field_fails(self):
        with self.assertRaises(ValueError):
            util.ipc_pid(string_field(1, 'a' * 32) + uint_field(2, 1234))

    def test_truncation_and_trailing_garbage_fail(self):
        for cut in range(len(record())):
            with self.subTest(cut=cut):
                with self.assertRaises(ValueError): util.ipc_pid(record()[:cut])
        with self.assertRaises(ValueError): util.ipc_pid(record() + b'\x00')

    def test_overlong_overflow_and_unterminated_varints_fail(self):
        for value in (b'\x90\x00\x01', b'\x10\xff\xff\xff\xff\x10',
                      b'\x10\x80\x80\x80\x80\x80', b'\x10\x80'):
            with self.subTest(value=value):
                with self.assertRaises(ValueError): util.ipc_pid(value)

    def test_invalid_identity_fields_fail(self):
        for kwargs in ({'pid': 0}, {'pid': 2**31}, {'pid': 2**32-1}, {'key': 'x'*32},
                       {'key':'a'*31}, {'thread':1}, {'protocol':2}, {'version':'bad'},
                       {'version':'2.29.5160.103'}):
            with self.subTest(kwargs=kwargs):
                with self.assertRaises(ValueError): util.ipc_pid(record(**kwargs))

    def test_invalid_utf8_and_oversized_input_fail(self):
        for raw in (b'\x0a\x01\xff' + record()[34:], b'x'*1025, bytearray(record())):
            with self.assertRaises(ValueError): util.ipc_pid(raw)


class ProcessIdentityTests(unittest.TestCase):
    def test_live_self_identity_is_nonmutating(self):
        value = util.stat_identity(os.getpid())
        self.assertEqual(value['pid'], os.getpid())
        self.assertGreater(value['starttime'], 0)
        self.assertEqual(value['exe'], os.readlink('/proc/self/exe'))

    def test_identity_dict_covers_actual_native_caller_uid_contract(self):
        value = util.stat_identity(os.getpid())
        self.assertEqual(set(value), {'pid', 'uid', 'starttime', 'exe'})
        self.assertIs(type(value['uid']), int)
        self.assertEqual(value['uid'], os.geteuid())

    def test_stat_handles_complex_comm(self):
        self.assertEqual(util._starttime(proc_stat(123, comm=b'a ) b\n(c)'), 123), 123)

    def test_stat_wrong_pid_and_bad_start_fail(self):
        for raw in (proc_stat(2), proc_stat(123, starttime=0), b'bad', proc_stat(123).replace(b'123 0', b'nope 0')):
            with self.assertRaises(ValueError): util._starttime(raw, 123)

    def test_invalid_pid_and_disappeared_process_fail(self):
        for pid in (0, -1, True, '1', 2**31):
            with self.assertRaises(ValueError): util.stat_identity(pid)
        with tempfile.TemporaryDirectory() as folder, patch.object(util, 'PROC_ROOT', Path(folder)):
            with self.assertRaises(ProcessLookupError): util.stat_identity(123)

    def test_identity_races_and_deleted_executable_fail(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); process = root/'123'; process.mkdir()
            (process/'stat').write_bytes(proc_stat(123)); (process/'exe').symlink_to('/owned/exe')
            with patch.object(util, 'PROC_ROOT', root):
                with patch.object(util, '_bounded_read', side_effect=[proc_stat(123), proc_stat(123, 124)]):
                    with self.assertRaises(RuntimeError): util.stat_identity(123)
                with patch.object(util.os, 'readlink', side_effect=['/owned/exe', '/owned/other']):
                    with self.assertRaises(RuntimeError): util.stat_identity(123)
                with patch.object(util.os, 'readlink', return_value='/owned/exe (deleted)'):
                    with self.assertRaises(ValueError): util.stat_identity(123)

    def test_other_owner_rejected(self):
        with patch.object(util.os, 'geteuid', return_value=os.geteuid()+1):
            with self.assertRaises(PermissionError): util.stat_identity(os.getpid())

    def test_owner_change_during_identity_read_fails(self):
        from types import SimpleNamespace
        metadata=[SimpleNamespace(st_uid=os.geteuid()),SimpleNamespace(st_uid=os.geteuid()+1)]
        with patch('pathlib.Path.stat',side_effect=metadata):
            with self.assertRaises(PermissionError): util.stat_identity(os.getpid())


class OwnershipScanTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name); self.proc = self.root/'proc'; self.proc.mkdir(mode=0o700)
        self.home = self.root/'home'; self.config = self.root/'config'
        self.home.mkdir(mode=0o700); self.config.mkdir(mode=0o700)
        self.token = '12'*24
        self.environment = (b'OTHER=ignored\0GPUI_IME_PROBE_TOKEN=' + self.token.encode() +
            b'\0HOME=' + os.fsencode(self.home) + b'\0XDG_CONFIG_HOME=' + os.fsencode(self.config) + b'\0')
        self.fake(50,b'');(self.proc/'50/stat').write_bytes(proc_stat(50,starttime=100))
        self.proc_patch=patch.object(util,'PROC_ROOT',self.proc);self.proc_patch.start();self.addCleanup(self.proc_patch.stop)
        self.pid_patch=patch.object(util.os,'getpid',return_value=50);self.pid_patch.start();self.addCleanup(self.pid_patch.stop)
        self.owner=util.capture_task_owner()

    def scan(self,token=None,home=None,config=None):
        return util.private_processes(token or self.token,home or self.home,config or self.config,self.owner)

    def fake(self, pid, environment):
        p = self.proc/str(pid); p.mkdir(); (p/'environ').write_bytes(environment)
        (p/'stat').write_bytes(proc_stat(pid)); (p/'exe').symlink_to('/owned/exe')

    def test_only_exact_triple_matches(self):
        self.fake(20, self.environment); self.fake(10, self.environment.replace(self.token.encode(), b'34'*24))
        self.fake(30, self.environment.replace(os.fsencode(self.home), b'/different/home'))
        self.fake(40, self.environment.replace(os.fsencode(self.config), b'/different/config'))
        with patch.object(util, 'PROC_ROOT', self.proc):
            self.assertEqual([p['pid'] for p in self.scan()], [20])

    def test_missing_owner_key_never_matches(self):
        self.fake(20, b'GPUI_IME_PROBE_TOKEN='+self.token.encode()+b'\0')
        with patch.object(util, 'PROC_ROOT', self.proc):
            self.assertEqual(self.scan(), [])

    def test_duplicate_truncated_and_oversized_environment_fail(self):
        for index, environment in enumerate((self.environment+b'HOME=/duplicate\0', self.environment[:-1], b'x'*262145),1):
            self.fake(index, environment)
            with patch.object(util, 'PROC_ROOT', self.proc):
                with self.assertRaises(ValueError): self.scan()
            (self.proc/str(index)/'environ').write_bytes(b'')

    def test_same_user_read_error_fails_closed(self):
        self.fake(20,self.environment)
        with patch.object(util, 'PROC_ROOT', self.proc), patch.object(util,'_bounded_read',side_effect=PermissionError('denied')):
            with self.assertRaises(PermissionError): self.scan()

    def test_ownership_race_fails_closed(self):
        self.fake(20,self.environment)
        original=util._process_meta;seen=[0]
        def changing(pid,folder=None):
            value=original(pid,folder)
            if pid==20:seen[0]+=1;value['starttime']=123+seen[0]
            return value
        with patch.object(util,'_process_meta',side_effect=changing):
            with self.assertRaises(RuntimeError):self.scan()

    def test_bad_token_permissions_and_indirect_paths_fail(self):
        for token in ('short','ff'*23,'AA'*24):
            with self.assertRaises(ValueError): self.scan(token=token)
        self.home.chmod(0o755)
        with self.assertRaises(PermissionError): self.scan()
        self.home.chmod(0o700); link=self.root/'link';link.symlink_to(self.home)
        with self.assertRaises(ValueError): self.scan(home=link)

    def test_import_launches_and_signals_nothing(self):
        path=Path(util.__file__)
        with patch('subprocess.Popen',side_effect=AssertionError('launch forbidden')), patch('os.kill',side_effect=AssertionError('signal forbidden')):
            spec=importlib.util.spec_from_file_location('nonmutating_recovery_util',path)
            spec.loader.exec_module(importlib.util.module_from_spec(spec))


if __name__ == '__main__':
    unittest.main()
