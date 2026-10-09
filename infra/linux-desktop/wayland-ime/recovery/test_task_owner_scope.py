"""Native task birth-boundary/receipt adversarial tests using fake proc trees."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import baseline_utilities as helper


def record(pid,start,state='S',threads=1):
    fields=[state.encode(),b'1',b'7',b'8']+[b'0']*46
    fields[17]=str(threads).encode();fields[19]=str(start).encode()
    return str(pid).encode()+b' (name ) with spaces) '+b' '.join(fields)+b'\n'


class BirthScopeTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.proc=self.root/'proc';self.proc.mkdir(mode=0o700)
        self.home=self.root/'home';self.config=self.root/'config';self.home.mkdir(mode=0o700);self.config.mkdir(mode=0o700)
        self.token='12'*24
        self.env=b'GPUI_IME_PROBE_TOKEN='+self.token.encode()+b'\0HOME='+os.fsencode(self.home)+b'\0XDG_CONFIG_HOME='+os.fsencode(self.config)+b'\0'
        self.process(100,1000,environment=b'')
        self.proc_patch=patch.object(helper,'PROC_ROOT',self.proc);self.proc_patch.start();self.addCleanup(self.proc_patch.stop)
        self.pid_patch=patch.object(helper.os,'getpid',return_value=100);self.pid_patch.start();self.addCleanup(self.pid_patch.stop)
        self.owner=helper.capture_task_owner()

    def process(self,pid,start,state='S',threads=1,environment=None):
        folder=self.proc/str(pid);folder.mkdir();(folder/'stat').write_bytes(record(pid,start,state,threads));(folder/'exe').symlink_to('/owned/python')
        (folder/'environ').write_bytes(self.env if environment is None else environment)
        return folder

    def terminal(self,pid=200,start=1100,threads=1,task_states=None):
        folder=self.process(pid,start,'Z',threads);uid=os.geteuid()
        (folder/'status').write_text('State:\tZ (zombie)\nTgid:\t'+str(pid)+'\nPid:\t'+str(pid)+'\nThreads:\t'+str(threads)+'\nUid:\t'+(' '.join([str(uid)]*4))+'\n')
        (folder/'task').mkdir()
        for tid,state in (task_states or {pid:'Z'}).items():
            task=folder/'task'/str(tid);task.mkdir();(task/'stat').write_bytes(record(tid,start,state,threads))
        return folder

    def scan(self,audit=None):return helper.private_processes(self.token,self.home,self.config,self.owner,audit=audit)

    def test_owner_capture_and_forgery_stale_or_cross_caller_rejection(self):
        self.assertEqual(self.owner['pid'],100);self.assertEqual(self.owner['starttime'],1000)
        for key,value in (('pid',99),('uid',os.geteuid()+1),('starttime',999),('exe','/other/exec'),('schema_version',True)):
            changed=dict(self.owner,**{key:value})
            with self.subTest(key=key):
                with self.assertRaises((ValueError,RuntimeError)):helper.verify_task_owner(changed)
        (self.proc/'100/stat').write_bytes(record(100,1001))
        with self.assertRaises(RuntimeError):helper.verify_task_owner(self.owner)

    def test_strictly_older_stable_pid_excluded_before_denied_environment(self):
        self.process(10,999);original=helper._bounded_read;attempts=[]
        def read(path,limit):
            if path==self.proc/'10/environ':attempts.append(path);raise PermissionError('must not read excluded old environ')
            return original(path,limit)
        audit={}
        with patch.object(helper,'_bounded_read',side_effect=read):self.assertEqual(self.scan(audit),[])
        self.assertEqual(attempts,[]);self.assertEqual(audit['excluded_preexisting'],[{'pid':10,'uid':os.geteuid(),'starttime':999}]);self.assertTrue(audit['scan_complete'])

    def test_same_tick_and_post_start_live_denials_fail_closed(self):
        original=helper._bounded_read
        for pid,start in ((10,1000),(20,1001)):
            self.process(pid,start)
            def read(path,limit,pid=pid):
                if path==self.proc/str(pid)/'environ':raise PermissionError('in-scope live environment denied')
                return original(path,limit)
            audit={}
            with patch.object(helper,'_bounded_read',side_effect=read):
                with self.assertRaises(PermissionError):self.scan(audit)
            self.assertFalse(audit['scan_complete']);self.assertEqual(audit['failure']['type'],'PermissionError')
            (self.proc/str(pid)/'stat').write_bytes(record(pid,999))

    def test_old_pid_reuse_and_uid_metadata_races_never_exclude(self):
        self.process(10,999);original=helper._process_meta
        for key,new_value in (('starttime',1100),('uid',os.geteuid()+1)):
            count=[0]
            def meta(pid,folder=None,key=key,new_value=new_value):
                value=original(pid,folder)
                if pid==10:
                    count[0]+=1
                    if count[0]>1:value[key]=new_value
                return value
            audit={}
            with patch.object(helper,'_process_meta',side_effect=meta):
                with self.assertRaises(RuntimeError):self.scan(audit)
            self.assertEqual(audit['excluded_preexisting'],[]);self.assertFalse(audit['scan_complete'])

    def test_newborn_peer_same_tick_allowed_but_old_ipc_peer_rejected(self):
        self.process(10,1000);self.assertEqual(helper.require_fresh_peer(10,self.owner,'/owned/python')['starttime'],1000)
        self.process(20,999)
        with self.assertRaises(RuntimeError):helper.require_fresh_peer(20,self.owner,'/owned/python')
        with self.assertRaises(RuntimeError):helper.require_fresh_peer(10,self.owner,'/wrong/executable')

    def test_current_actor_is_audited_and_never_read_as_own_descendant(self):
        (self.proc/'100/environ').write_bytes(self.env);original=helper._bounded_read
        def read(path,limit):
            if path==self.proc/'100/environ':raise AssertionError('caller environment must never be matched')
            return original(path,limit)
        audit={}
        with patch.object(helper,'_bounded_read',side_effect=read):self.assertEqual(self.scan(audit),[])
        self.assertEqual(audit['excluded_caller'],{k:self.owner[k] for k in ('pid','uid','starttime')})
        with self.assertRaises(RuntimeError):helper.require_fresh_peer(100,self.owner)

    def test_census_entry_cap_and_deadline_fail_closed(self):
        audit={}
        with patch.object(helper,'MAX_SCAN_ENTRIES',0):
            with self.assertRaises(RuntimeError):self.scan(audit)
        self.assertFalse(audit['scan_complete']);self.assertEqual(audit['examined_entries'],0)
        audit={}
        with patch.object(helper.time,'monotonic',side_effect=[0.0,8.0]):
            with self.assertRaises(TimeoutError):self.scan(audit)
        self.assertFalse(audit['scan_complete'])

    def test_missing_live_metadata_or_terminal_status_keeps_scan_unknown(self):
        folder=self.process(20,1001);(folder/'environ').unlink()
        with self.assertRaises(RuntimeError):self.scan({})
        import shutil;shutil.rmtree(folder)
        folder=self.terminal();(folder/'status').unlink()
        with self.assertRaises(RuntimeError):self.scan({})

    def test_matching_post_start_identity_and_audit_are_retained(self):
        self.process(20,1002);audit={};value=self.scan(audit)
        self.assertEqual([p['pid'] for p in value],[20]);self.assertEqual(audit['matched'],value);self.assertEqual(audit['owner'],self.owner)

    def test_proven_single_zombie_skipped_without_environ(self):
        self.terminal();original=helper._bounded_read;reads=[]
        def read(path,limit):
            if path==self.proc/'200/environ':reads.append(path);raise PermissionError('dead environ must not be attempted')
            return original(path,limit)
        audit={}
        with patch.object(helper,'_bounded_read',side_effect=read):self.assertEqual(self.scan(audit),[])
        self.assertEqual(reads,[]);self.assertEqual(audit['excluded_proven_terminal'][0]['proof'],'stable-Z-exact-single-task')

    def test_zero_count_multithread_z_and_missing_task_metadata_are_blockers(self):
        for threads,states in ((0,{200:'Z'}),(2,{200:'Z',201:'S'}),(2,{200:'Z',201:'Z'})):
            folder=self.terminal(200,1100,threads,states)
            with self.assertRaises(RuntimeError):self.scan({})
            import shutil;shutil.rmtree(folder)
        folder=self.terminal();(folder/'task/200/stat').unlink()
        # A missing corroboration is not proof of terminality, even when the
        # top-level PID still exists. It must propagate as an unknown scan.
        with self.assertRaises((RuntimeError,FileNotFoundError)):self.scan({})

    def test_terminal_identity_race_is_not_an_exit_proof(self):
        self.terminal();original=helper._process_meta;count=[0]
        def meta(pid,folder=None):
            value=original(pid,folder)
            if folder is not None and '/task/' in str(folder):
                count[0]+=1
                if count[0]>1:value['starttime']+=1
            return value
        with patch.object(helper,'_process_meta',side_effect=meta):
            with self.assertRaises(RuntimeError):self.scan({})


class RecordedOwnerReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup);self.root=Path(self.tmp.name)
        self.owner={'schema_version':1,'kind':helper.OWNER_KIND,'pid':100,'uid':1000,'starttime':1000,'exe':'/usr/bin/python3.13'}
        self.snapshot=self.root/'task-owner.snapshot.json';self.snapshot.write_text(json.dumps(self.owner))
        roles=['xvfb','session-bus','mozc-server','ibus-daemon','weston-stdio','ibus-unix-peer','ibus-wayland','gpui']
        peers=[{'pid':200+i,'uid':1000,'starttime':1000+i,'exe':'/owned/peer','role':role} for i,role in enumerate(roles)]
        audit={'schema_version':1,'kind':'gpui-fresh-task-birth-census','scope':helper.OWNER_KIND,'owner':self.owner,
            'excluded_preexisting':[{'pid':9,'uid':1000,'starttime':999}],'excluded_proven_terminal':[],'matched':[],'scan_complete':True,
            'excluded_caller':{k:self.owner[k] for k in ('pid','uid','starttime')},'limits':{'max_entries':4096,'max_seconds':8.0},'examined_entries':2,'nonmatching_post_start':0}
        self.report={'task_owner':self.owner,'evidence_inputs':{self.snapshot.name:hashlib.sha256(self.snapshot.read_bytes()).hexdigest()},'peer_ledger':peers,
            'cleanup':{'verified':True,'scan_complete':True,'errors':[],'survivors':[],'scan_audits':[audit],
                'ownership_scope':'fresh task descendants bound by owner birth, nonce, HOME and config','pidfd_signals_only':True,'no_name_based_kill':True}}

    def test_receipt_replay_is_pure_and_no_live_pid_checks(self):
        with patch.object(helper,'stat_identity',side_effect=AssertionError('no live PID in replay')):
            self.assertFalse(helper.validate_task_owner_receipt(self.root,self.report)['live_pid_verification'])

    def test_snapshot_report_hash_and_typed_owner_mutations_fail(self):
        for mutate in (lambda r:r['task_owner'].update(starttime=999),lambda r:r['evidence_inputs'].update({'task-owner.snapshot.json':'f'*64}),lambda r:r['task_owner'].update(uid=True)):
            changed=copy.deepcopy(self.report);mutate(changed)
            with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_snapshot_boolean_cannot_compare_equal_to_typed_report_integer(self):
        saved=dict(self.owner,schema_version=True);self.snapshot.write_text(json.dumps(saved))
        self.report['evidence_inputs'][self.snapshot.name]=hashlib.sha256(self.snapshot.read_bytes()).hexdigest()
        with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,self.report)

    def test_zero_peer_adopted_old_and_wrong_uid_ledgers_fail(self):
        for mutate in (lambda r:r.update(peer_ledger=[]),lambda r:r['peer_ledger'][0].update(starttime=999),lambda r:r['peer_ledger'][0].update(uid=0),lambda r:r['peer_ledger'].pop(),lambda r:r['peer_ledger'][0].update(pid=100)):
            changed=copy.deepcopy(self.report);mutate(changed)
            with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_audit_wrong_boundary_same_tick_exclusion_and_failure_cannot_pass(self):
        for mutate in (lambda r:r['cleanup']['scan_audits'][0]['owner'].update(pid=99),lambda r:r['cleanup']['scan_audits'][0]['excluded_preexisting'][0].update(starttime=1000),lambda r:r['cleanup']['scan_audits'][0].update(scan_complete=False),lambda r:r['cleanup'].update(ownership_scope='all same UID processes')):
            changed=copy.deepcopy(self.report);mutate(changed)
            with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_pre_cleanup_phase_validates_owner_and_peers_without_claiming_cleanup(self):
        report=copy.deepcopy(self.report);report['cleanup']={'verified':False}
        self.assertFalse(helper.validate_task_owner_receipt(self.root,report,require_cleanup=False)['cleanup_audit_checked'])
        with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,report)

    def test_terminal_proof_requires_typed_stable_single_task_records(self):
        terminal={'pid':400,'uid':1000,'starttime':1001,'state':'Z','ppid':100,'pgrp':400,'session':400,'num_threads':1}
        terminal=dict(terminal,status={'state':'Z','pid':400,'tgid':400,'threads':1,'uids':[1000]*4},tasks=[dict(terminal)],proof='stable-Z-exact-single-task')
        report=copy.deepcopy(self.report);report['cleanup']['scan_audits'][0]['excluded_proven_terminal']=[terminal]
        helper.validate_task_owner_receipt(self.root,report)
        for mutate in (lambda t:t.update(num_threads=True),lambda t:t['status'].update(threads=True),lambda t:t['tasks'][0].update(pid=True),lambda t:t['status']['uids'].__setitem__(0,True),lambda t:t.update(tasks=[]),lambda t:t.update(num_threads=0)):
            changed=copy.deepcopy(report);mutate(changed['cleanup']['scan_audits'][0]['excluded_proven_terminal'][0])
            with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_missing_or_untyped_census_never_qualifies(self):
        for mutate in (lambda a:a.pop('matched'),lambda a:a.pop('excluded_caller'),lambda a:a.update(schema_version=True),lambda a:a.update(nonmatching_post_start=True),lambda a:a.update(examined_entries=4097)):
            changed=copy.deepcopy(self.report);mutate(changed['cleanup']['scan_audits'][0])
            with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_required_final_cleanup_cannot_accept_failed_nonempty_census(self):
        changed=copy.deepcopy(self.report)
        changed['cleanup'].update(verified=False,scan_complete=False,survivors=[changed['peer_ledger'][0]],errors=['scan denied'])
        with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)
        self.assertFalse(helper.validate_task_owner_receipt(self.root,changed,require_cleanup=False)['cleanup_audit_checked'])

    def test_audit_owner_boolean_cannot_compare_equal_to_typed_snapshot(self):
        changed=copy.deepcopy(self.report)
        changed['cleanup']['scan_audits'][0]['owner']=dict(self.owner,schema_version=True)
        with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)

    def test_required_cleanup_field_missing_null_false_and_wrong_type_matrix(self):
        missing=object()
        fields={
            'verified':[missing,None,False,0,1,'true',[]],
            'scan_complete':[missing,None,False,0,1,'true',[]],
            'pidfd_signals_only':[missing,None,False,0,1,'true',[]],
            'no_name_based_kill':[missing,None,False,0,1,'true',[]],
            'survivors':[missing,None,False,True,0,'',{},(),[None]],
            'errors':[missing,None,False,True,0,'',{},(),['scan error']],
            'scan_audits':[missing,None,False,True,0,'',{},[],[None]],
            'ownership_scope':[missing,None,False,True,0,'',{},[],'all same-user processes'],
        }
        helper.validate_task_owner_receipt(self.root,self.report)
        for field,values in fields.items():
            for value in values:
                changed=copy.deepcopy(self.report)
                if value is missing:changed['cleanup'].pop(field)
                else:changed['cleanup'][field]=value
                with self.subTest(field=field,value='missing' if value is missing else repr(value)):
                    with self.assertRaises(ValueError):helper.validate_task_owner_receipt(self.root,changed)


if __name__=='__main__':unittest.main()
