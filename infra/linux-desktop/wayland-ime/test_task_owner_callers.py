"""Focused owner boundary/peer/census tests; never opens native displays."""
import ast
import json
import io
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import Mock, patch

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import probe
import gpui_probe

OWNER={'schema_version':1,'kind':'gpui-task-owner-birth-v1','pid':123,
       'uid':1000,'starttime':50,'exe':'/trusted/python'}


class TaskOwnerCallerTests(unittest.TestCase):
    def test_new_kind_cannot_omit_model_or_capture(self):
        helper=Mock(); helper.capture_task_owner.return_value=OWNER
        data={'kind':'native-ime-recovery-baseline'}
        with self.assertRaises(RuntimeError):probe.capture_run_owner(data,helper)
        helper.capture_task_owner.assert_not_called()
        data['ownership_model']='gpui-task-owner-birth-v1'
        self.assertEqual(probe.capture_run_owner(data,helper),OWNER)
        helper.capture_task_owner.assert_called_once_with()
        self.assertIsNone(probe.capture_run_owner({'kind':'historical'},helper))

    def test_both_native_entries_capture_before_any_output_creation(self):
        for module in (probe,gpui_probe):
            with self.subTest(module=module.__name__),tempfile.TemporaryDirectory() as root:
                root=Path(root);output=root/'new-run'
                helper=Mock();helper.capture_task_owner.side_effect=PermissionError('owner unavailable')
                args=types.SimpleNamespace(output=output)
                with patch('subprocess.Popen',side_effect=AssertionError('launch')):
                    with self.assertRaises(PermissionError):
                        module.run(args,{'kind':'native-ime-recovery-baseline','ownership_model':'gpui-task-owner-birth-v1'},None,helper)
                self.assertFalse(output.exists())

    def test_actual_prefix_snapshots_owner_before_source_copy(self):
        for module in (probe,gpui_probe):
            source=ast.parse(Path(module.__file__).read_text())
            run=next(n for n in source.body if isinstance(n,ast.FunctionDef) and n.name=='run')
            cutoff=next(i for i,n in enumerate(run.body) if isinstance(n,ast.Expr) and isinstance(n.value,ast.Call) and isinstance(n.value.func,ast.Attribute) and n.value.func.attr=='copyfile')
            with tempfile.TemporaryDirectory() as root:
                root=Path(root);output=root/'runs'/'new-run'
                helper=Mock();helper.capture_task_owner.return_value=OWNER
                namespace=dict(module.__dict__,args=types.SimpleNamespace(output=output),
                    data={'kind':'native-ime-recovery-baseline','ownership_model':'gpui-task-owner-birth-v1','output_root':str(root)},baseline=helper)
                exec(compile(ast.Module(body=run.body[:cutoff],type_ignores=[]),'native-entry-prefix','exec'),namespace)
                self.assertEqual(json.loads((output/'task-owner.snapshot.json').read_text()),OWNER)

    def test_fresh_peer_adapter_uses_exact_owner_and_executable(self):
        helper=Mock();identity={'pid':124,'uid':1000,'starttime':51,'exe':'/trusted/service'}
        helper.require_fresh_peer.return_value=identity
        self.assertEqual(probe.run_peer_identity(helper,OWNER,124,'/trusted/service'),identity)
        helper.require_fresh_peer.assert_called_once_with(124,OWNER,expected_exe='/trusted/service')
        helper.require_fresh_peer.side_effect=RuntimeError('preexisting peer')
        with self.assertRaises(RuntimeError):probe.run_peer_identity(helper,OWNER,1)

    def test_existing_unix_connection_credentials_fail_closed(self):
        helper=Mock();identity={'pid':124,'uid':1000,'starttime':51,'exe':'/trusted/ibus'}
        helper.require_fresh_peer.return_value=identity
        credentials=Mock();credentials.get_unix_pid.return_value=124;credentials.get_unix_user.return_value=1000
        stream=Mock();stream.get_socket.return_value.get_credentials.return_value=credentials
        self.assertEqual(probe.require_bus_peer(stream,helper,OWNER,124,'/trusted/ibus'),identity)
        for pid,uid in ((1,1000),(124,0),(True,1000)):
            credentials.get_unix_pid.return_value=pid;credentials.get_unix_user.return_value=uid
            with self.assertRaises(RuntimeError):probe.require_bus_peer(stream,helper,OWNER,124,'/trusted/ibus')
        stream.get_socket.return_value.get_credentials.return_value=None
        with self.assertRaises(RuntimeError):probe.require_bus_peer(stream,helper,OWNER,124,'/trusted/ibus')

    def test_same_single_stream_checked_before_gdbus_owns_it(self):
        order=[];stream=Mock();connection=Mock();client=Mock()
        client.connect.side_effect=lambda *args:order.append('connect') or stream
        gio=types.SimpleNamespace(SocketClient=Mock(),UnixSocketAddress=Mock(),
            DBusConnectionFlags=types.SimpleNamespace(AUTHENTICATION_CLIENT=1,MESSAGE_BUS_CONNECTION=2),
            DBusConnection=Mock())
        gio.SocketClient.new.return_value=client
        gio.DBusConnection.new_sync.side_effect=lambda *args:order.append('authenticate') or connection
        connection.get_guid.return_value='a'*32
        with patch.object(probe,'require_bus_peer',side_effect=lambda *args:order.append('check-peer') or {'pid':124}):
            result=probe.connect_owned_bus(gio,'unix:path=/owned/ibus,guid='+'a'*32,Path('/owned/ibus'),Mock(),OWNER,124,'/trusted/ibus',None)
        self.assertEqual(result,(connection,{'pid':124}))
        self.assertEqual(order,['connect','check-peer','authenticate'])
        gio.DBusConnection.new_sync.assert_called_once_with(stream,None,3,None,None)
        gio.DBusConnection.new_for_address_sync.assert_not_called()
        stream.close.assert_not_called()
        with patch.object(probe,'require_bus_peer',side_effect=RuntimeError('foreign peer')):
            with self.assertRaises(RuntimeError):probe.connect_owned_bus(gio,'unix:path=/owned/ibus',Path('/owned/ibus'),Mock(),OWNER,124,'/trusted/ibus',None)
        stream.close.assert_called_once_with(None)
        self.assertEqual(gio.DBusConnection.new_sync.call_count,1)

    def test_cleanup_propagates_owner_and_keeps_complete_scan_census(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);runtime=root/'private';runtime.mkdir()
            def scan(token,home,config,owner,audit):
                self.assertEqual(owner,OWNER)
                audit.update(owner=owner,scan_complete=True,matched=[])
                return []
            helper=types.SimpleNamespace(private_processes=Mock(side_effect=scan))
            report=probe.cleanup_owned_native(None,[],[],Mock(),helper,'token',runtime/'home',runtime/'config',runtime,OWNER)
            self.assertTrue(report['verified']);self.assertTrue(report['scan_audits'])
            self.assertTrue(runtime.exists())  # Deletion waits for sealed receipt validation.
            self.assertTrue(all(v['owner']==OWNER and v['scan_complete'] for v in report['scan_audits']))
            self.assertIn('fresh task descendants',report['ownership_scope'])

    def test_unknown_post_scope_scan_keeps_failed_audit_and_runtime(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);runtime=root/'private';runtime.mkdir()
            def scan(token,home,config,owner,audit):
                audit.update(owner=owner,scan_complete=False,failure='post-start unreadable')
                raise PermissionError('post-start unreadable')
            helper=types.SimpleNamespace(private_processes=Mock(side_effect=scan))
            report=probe.cleanup_owned_native(None,[],[],Mock(),helper,'token',runtime/'home',runtime/'config',runtime,OWNER)
            self.assertFalse(report['verified']);self.assertIsNone(report['survivors'])
            self.assertEqual(report['scan_audits'][0]['failure'],'post-start unreadable')
            self.assertTrue(runtime.exists())

    def test_actual_fresh_finalizer_validates_before_runtime_removal(self):
        source=ast.parse(Path(gpui_probe.__file__).read_text())
        run=next(n for n in source.body if isinstance(n,ast.FunctionDef) and n.name=='run')
        final=next(n for n in run.body if isinstance(n,ast.Try) and n.finalbody).finalbody
        for rejects in (False,True):
            with self.subTest(rejects=rejects),tempfile.TemporaryDirectory() as root:
                root=Path(root);runtime=root/'runtime';runtime.mkdir();output=root/'output';output.mkdir()
                def scan(token,home,config,owner,audit):
                    audit.update(owner=owner,scan_complete=True,matched=[]);return []
                def validate(*args):
                    self.assertTrue(runtime.exists())
                    if rejects:raise ValueError('receipt gap')
                    return {'verified':True}
                helper=types.SimpleNamespace(private_processes=Mock(side_effect=scan),validate_task_owner_receipt=Mock(side_effect=validate))
                report={'status':'passed','render_readiness':[]}
                namespace=dict(gpui_probe.__dict__,x=None,pressed=[],processes=[],stop=Mock(),
                    baseline=helper,token='token',home=runtime/'home',config=runtime/'config',
                    runtime=runtime,streams=[],events=io.StringIO(),report=report,
                    started=time.monotonic(),output=output,task_owner=OWNER)
                exec(compile(ast.Module(body=final,type_ignores=[]),'fresh-finally','exec'),namespace)
                saved=json.loads((output/'result.json').read_text())
                self.assertEqual(saved['status'],'error' if rejects else 'passed')
                self.assertEqual(saved['cleanup']['verified'],not rejects)
                self.assertEqual(saved['cleanup']['runtime_removed'],not rejects)
                self.assertEqual(runtime.exists(),rejects)


if __name__=='__main__':unittest.main()
