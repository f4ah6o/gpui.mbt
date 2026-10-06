"""Adversarial recovery binding tests. All fixtures are private synthetic files.

The established source/runtime verifier is mocked here; the actual prepared
profile must separately pass that verifier before any native qualification.
"""
import ast
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

import prepare_deployment as recovery


def write(path, value):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(value,sort_keys=True,indent=2)+'\n')


class RecoveryBindingTests(unittest.TestCase):
    def setUp(self):
        self.temporary=tempfile.TemporaryDirectory();self.addCleanup(self.temporary.cleanup)
        self.root=Path(self.temporary.name)
        self.iac=self.root/'iac';self.desktop=self.iac/'infra/linux-desktop';self.here=self.desktop/'wayland-ime/recovery'
        self.profile=self.root/'profile';self.mozc=self.root/'mozc';self.repo=self.root/'app-source';self.build=self.root/'app-build'
        self.output_root=self.root/'evidence';self.output=self.output_root/'new-profile.json'
        for directory in (self.here,self.profile,self.mozc,self.repo,self.build):directory.mkdir(parents=True,mode=0o700)
        self.addCleanup(patch.stopall)
        patch.object(recovery,'HERE',self.here).start();patch.object(recovery,'DESKTOP',self.desktop).start();patch.object(recovery,'REPO',self.iac).start()
        for relative in recovery.REQUIRED_SOURCE_FILES:
            p=self.desktop/relative;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('verified-source:'+relative)
        self.prefix=self.profile/'prefix';self.prefix.mkdir()
        components=['dconf.xml','gtkextension.xml','simple.xml','memconf.xml','mozc.xml','gtkpanel.xml']
        for name in components:
            original=self.prefix/'usr/share/ibus/component'/name;original.parent.mkdir(parents=True,exist_ok=True)
            original.write_text('<component><exec>/usr/bin/'+name+'</exec><engines exec="/usr/bin/'+name+' --xml"/></component>')
            tree=ET.parse(original)
            for element in tree.iter():
                if element.tag=='exec' and element.text:element.text=element.text.replace('/usr/',str(self.prefix/'usr')+'/')
                if 'exec' in element.attrib:element.set('exec',element.get('exec').replace('/usr/',str(self.prefix/'usr')+'/'))
            generated=self.profile/'config/ibus/component'/name;generated.parent.mkdir(parents=True,exist_ok=True)
            generated.write_bytes(recovery.xml_bytes(tree))
        fonts=ET.Element('fontconfig')
        for name in ('truetype/dejavu','opentype/noto','truetype/noto'):ET.SubElement(fonts,'dir').text=str(self.prefix/'usr/share/fonts'/name)
        ET.SubElement(fonts,'cachedir').text=str(self.profile/'cache/fontconfig')
        (self.profile/'config/fonts.conf').write_bytes(recovery.xml_bytes(ET.ElementTree(fonts)))
        schema=self.profile/'config/schemas/gschemas.compiled';schema.parent.mkdir();schema.write_bytes(b'locked schema')
        server=self.prefix/'usr/lib/mozc/mozc_server';server.parent.mkdir(parents=True);server.write_bytes(b'exact server')
        (self.profile/'.gpui-desktop-profile').write_text('gpui-linux-desktop-v1\n')
        profile={'schema_version':1,'packages':[{'name':'known','version':'1','sha256':'a'*64}]};write(self.desktop/'profile.lock.json',profile)
        self.profile_hash=recovery.sha(self.desktop/'profile.lock.json')
        write(self.profile/'installed.json',{'lock_sha256':self.profile_hash,'profile':profile})
        protected=self.mozc/'source/src/ipc/ipc_path_manager.cc';protected.parent.mkdir(parents=True);protected.write_bytes(b'protected official source')
        archive=self.mozc/'archives/source.tar.xz';archive.parent.mkdir();archive.write_bytes(b'exact source archive')
        self.contract={'source_version':'2.29.5160.102+dfsg-1.4','server_elf_sha256':recovery.sha(server),
            'sources':[{'filename':'source.tar.xz','sha256':recovery.sha(archive),'size':archive.stat().st_size}],
            'extra_build_packages':[],'build_contract':{'security_source_sha256':{'src/ipc/ipc_path_manager.cc':recovery.sha(protected)}}}
        write(self.desktop/'mozc-prefix/build.lock.json',self.contract);self.mozc_lock_hash=recovery.sha(self.desktop/'mozc-prefix/build.lock.json')
        self.engine=self.mozc/'artifacts/ibus-engine-mozc';self.engine.parent.mkdir();self.engine.write_bytes(b'new exact engine')
        self.component=self.mozc/'artifacts/mozc.xml';self.component.write_text('<component><exec>'+str(self.engine)+' --ibus</exec><engines exec="'+str(self.engine)+' --xml"/></component>')
        (self.mozc/'build-prefix').mkdir();(self.mozc/'runtime-ldd.txt').write_text('libc => /usr/lib/libc.so\n')
        self.result={'schema_version':1,'source_version':self.contract['source_version'],'recipe_lock_sha256':self.mozc_lock_hash,
            'runtime_prefix':str(self.prefix),'compiled_server_directory':str(self.prefix/'usr/lib/mozc'),
            'engine':str(self.engine),'engine_sha256':recovery.sha(self.engine),'registration_xml':str(self.component),'registration_xml_sha256':recovery.sha(self.component),
            'stock_server':str(server),'stock_server_sha256':recovery.sha(server),'security_source_verified':True,'runtime_linkage_passed':True,
            'renderer_built':False,'candidate_window':'ibus','native_conversion_tested':False,'source_build_archive_bytes':archive.stat().st_size,
            'configure_command':['/usr/bin/python3','build_mozc.py','gyp','--gypdir='+str(self.mozc/'build-prefix/usr/bin'),'--target_platform=Linux','--noqt','--server_dir='+str(self.prefix/'usr/lib/mozc'),'--verbose'],
            'build_command':['ninja','-C','out_linux/Release','-j4','ibus_mozc']}
        write(self.mozc/'build-result.json',self.result)
        self.app=self.build/'app.exe';self.app.write_bytes(b'exact app');self.manifest=self.build/'field-build.json'
        tool_rows=[];tools={}
        for name in ('moon','moonc','moonrun','cc','pkg-config','wayland-scanner','fc-list','tcc'):
            relative='tools/'+name;p=self.profile/relative;p.parent.mkdir(exist_ok=True);p.write_bytes(('exact tool '+name).encode())
            tools[name]={'location':'profile','relative_path':relative,'sha256':recovery.sha(p)}
            tool_rows.append({'role':'tool:'+name,'path':str(p),'sha256':recovery.sha(p),'size':p.stat().st_size})
        self.runtime={'profile_root':str(self.profile),'prefix':str(self.prefix),'fontconfig':str(self.profile/'config/fonts.conf'),
            'compiler_command':['cc'],'pkg_config_command':['pkg-config'],'files':tool_rows,
            'trees':[{'role':'native-profile','path':str(self.prefix),'sha256':'b'*64},{'role':'moon-core','path':str(self.profile/'moon/lib/core'),'sha256':'b'*64}],
            'generated_protocols':[{'path':str(self.repo/'ubuntu'/n),'sha256':'c'*64,'size':1} for n in recovery.build_manifest.GENERATED_PROTOCOLS]}
        self.candidate={'version':1,'kind':'gpui-field-build','mode':'built','source_consistent':True,'source':{'repo':str(self.repo)},
            'binary':{'path':str(self.app),'sha256':recovery.sha(self.app),'size':self.app.stat().st_size},'runtime':self.runtime}
        write(self.manifest,self.candidate)
        historic=self.desktop/'wayland-ime/deployment.lock.json';historic.write_bytes(b'unchanged historical lock')
        self.historical_bytes=historic.read_bytes()
        self.recipe={'schema_version':1,'kind':'native-ime-recovery-recipe','native_qualified':False,
            'historical_deployment_sha256':recovery.sha(historic),'profile_lock_sha256':self.profile_hash,'mozc_recipe_lock_sha256':self.mozc_lock_hash,
            'fixed_prefix_tree_sha256':'b'*64,'fixed_prefix_files':{'usr/lib/mozc/mozc_server':recovery.sha(server)},
            'fixed_config_files':{'config/schemas/gschemas.compiled':recovery.sha(schema)},'host_executables':{},
            'generated_component_names':components,'build_tools':tools,
            'source_files':{relative:recovery.sha(self.desktop/relative) for relative in recovery.REQUIRED_SOURCE_FILES}}
        write(self.here/'recipe.lock.json',self.recipe)
        self.tree_mock=patch.object(recovery.build_manifest,'tree_digest',return_value='b'*64).start()
        self.source_mock=patch.object(recovery.build_manifest,'capture_source',return_value={'repo':str(self.iac),'head':'fake-iac','status':'frozen'}).start()
        self.build_mock=patch.object(recovery.build_manifest,'verify_build_manifest',side_effect=lambda p:json.loads(Path(p).read_text())).start()
        self.arguments={'profile_root':self.profile,'mozc_build_root':self.mozc,'candidate_repo':self.repo,'candidate_build_root':self.build,
            'candidate_manifest':self.manifest,'output_root':self.output_root,'output':self.output,'expected':self.expected()}

    def expected(self):
        return {'engine':recovery.sha(self.engine),'component':recovery.sha(self.component),
            'mozc_build_result':recovery.sha(self.mozc/'build-result.json'),'candidate_manifest':recovery.sha(self.manifest)}

    def construct(self):return recovery.construct(**self.arguments)

    def changed_candidate(self):
        write(self.manifest,self.candidate);self.arguments['expected']['candidate_manifest']=recovery.sha(self.manifest)

    def test_success_is_explicitly_new_unqualified_and_historical_unchanged(self):
        value=self.construct();self.assertEqual(value['kind'],'native-ime-recovery-baseline');self.assertIs(value['native_qualified'],False)
        self.assertEqual(value['ownership_model'],'gpui-task-owner-birth-v1')
        self.assertIn('before private runtime or child creation',value['ownership_boundary'])
        self.assertEqual(value['qualification_status'],'prepared-native-unqualified');self.assertEqual(Path(value['baseline_utilities']),self.here/'baseline_utilities.py')
        self.assertEqual((self.desktop/'wayland-ime/deployment.lock.json').read_bytes(),self.historical_bytes)
        self.assertFalse(self.output_root.exists())

    def test_same_reviewed_combined_source_is_supported_with_separate_build_roots(self):
        self.arguments['candidate_repo']=self.iac
        self.candidate['source']['repo']=str(self.iac)
        self.candidate['runtime']['generated_protocols']=[{'path':str(self.iac/'ubuntu'/n),'sha256':'c'*64,'size':1} for n in recovery.build_manifest.GENERATED_PROTOCOLS]
        self.changed_candidate();value=self.construct()
        self.assertEqual(value['iac_source']['repo'],str(self.iac))
        self.assertEqual(value['recovery_inputs']['candidate_repo'],str(self.iac))

    def test_combined_source_still_rejects_source_build_and_output_overlap(self):
        self.arguments['candidate_repo']=self.iac;self.arguments['candidate_build_root']=self.iac
        with self.assertRaisesRegex(RuntimeError,'overlap'):self.construct()

    def test_equal_source_profile_and_mozc_roots_are_rejected(self):
        for root in (self.profile,self.mozc):
            self.arguments['candidate_repo']=root
            with self.subTest(root=root):
                with self.assertRaisesRegex(RuntimeError,'overlap'):self.construct()

    def test_bytecode_policy_is_explicit_at_all_public_native_and_probe_entries(self):
        actual=Path(__file__).resolve().parents[1]
        # Source text only. Never invokes a compositor, display, or launch entry.
        for name in ('probe.py','gpui_probe.py','evidence.py'):
            self.assertIn('sys.dont_write_bytecode = True',(actual/name).read_text())
        for name in ('probe.py','gpui_probe.py','prepare-launcher.py','prepare-gpui-launcher.py'):
            self.assertIn('PYTHONDONTWRITEBYTECODE',(actual/name).read_text())
        desktop=actual.parent
        self.assertIn('env["PYTHONDONTWRITEBYTECODE"] = "1"',(desktop/'gpui-desktop.py').read_text())
        self.assertIn('env["PYTHONDONTWRITEBYTECODE"] = "1"',(desktop/'build_manifest.py').read_text())

    def test_actual_native_directory_setup_keeps_config_private_under_umask022(self):
        actual=Path(__file__).resolve().parents[1]
        for name in ('probe.py','gpui_probe.py'):
            tree=ast.parse((actual/name).read_text())
            loops=[node for node in ast.walk(tree) if isinstance(node,ast.For) and isinstance(node.target,ast.Name) and node.target.id=='path' and isinstance(node.iter,ast.Tuple) and any(isinstance(x,ast.Name) and x.id=='home' for x in node.iter.elts)]
            self.assertEqual(len(loops),1);loop=loops[0]
            direct=[x.id for x in loop.iter.elts if isinstance(x,ast.Name)]
            self.assertIn('config',direct)
            # Execute only the reviewed directory-creation statement. Its AST
            # permits Path division/constants and one path.mkdir; no other API.
            for expression in loop.iter.elts:
                self.assertTrue(isinstance(expression,(ast.Name,ast.BinOp)))
                if isinstance(expression,ast.BinOp):
                    self.assertIsInstance(expression.op,ast.Div)
                    self.assertIsInstance(expression.left,ast.Name)
                    self.assertIn(expression.left.id,('config','runtime'))
                    self.assertIsInstance(expression.right,ast.Constant)
                    self.assertIsInstance(expression.right.value,str)
                    self.assertNotIn('/',expression.right.value)
            self.assertEqual(len(loop.body),1);call=loop.body[0].value
            self.assertIsInstance(call,ast.Call);self.assertEqual(ast.unparse(call.func),'path.mkdir')
            self.assertEqual({k.arg:ast.literal_eval(k.value) for k in call.keywords},{'parents':True,'mode':0o700})
            with tempfile.TemporaryDirectory() as folder:
                runtime=Path(folder);home=runtime/'home';config=runtime/'config';old=os.umask(0o022)
                try:
                    exec(compile(ast.Module(body=[loop],type_ignores=[]),name,'exec'),{'__builtins__':{}},{'runtime':runtime,'home':home,'config':config})
                finally:os.umask(old)
                self.assertEqual(config.stat().st_mode & 0o777,0o700)
                self.assertEqual((config/'mozc').stat().st_mode & 0o777,0o700)

    def test_fresh_prepare_and_recheck_write_no_services(self):
        with patch('subprocess.Popen',side_effect=AssertionError('no launch')),patch('subprocess.run',side_effect=AssertionError('no launch')):
            path,value=recovery.prepare(**self.arguments);self.assertEqual(path,self.output)
            self.assertEqual(recovery.verify_deployment(path),value)
        self.assertEqual((self.desktop/'wayland-ime/deployment.lock.json').read_bytes(),self.historical_bytes)

    def test_missing_source_closure_and_changed_helper_fail(self):
        self.recipe['source_files']={};write(self.here/'recipe.lock.json',self.recipe)
        with self.assertRaisesRegex(RuntimeError,'frozen'):self.construct()
        self.recipe['source_files']={'build_manifest.py':recovery.sha(self.desktop/'build_manifest.py')};write(self.here/'recipe.lock.json',self.recipe)
        with self.assertRaisesRegex(RuntimeError,'incomplete'):self.construct()

    def test_changed_helper_hash_fails(self):
        (self.here/'baseline_utilities.py').write_text('changed helper')
        with self.assertRaisesRegex(RuntimeError,'hash'):self.construct()

    def test_wrong_explicit_artifact_hashes_fail(self):
        for name in recovery.EXPECTED_FIELDS:
            original=self.arguments['expected'][name];self.arguments['expected'][name]='f'*64
            with self.subTest(name=name):
                with self.assertRaisesRegex(RuntimeError,'hash'):self.construct()
            self.arguments['expected'][name]=original

    def test_incomplete_or_invalid_explicit_expected_hashes_fail(self):
        self.arguments['expected']={'engine':'f'*64}
        with self.assertRaises(RuntimeError):self.construct()
        self.arguments['expected']=self.expected();self.arguments['expected']['engine']='not-a-hash'
        with self.assertRaises(RuntimeError):self.construct()

    def test_foreign_manifest_and_app_fail_before_verifier(self):
        foreign=self.root/'foreign.json';foreign.write_bytes(self.manifest.read_bytes());self.arguments['candidate_manifest']=foreign
        with self.assertRaisesRegex(RuntimeError,'foreign candidate manifest'):self.construct()
        self.arguments['candidate_manifest']=self.manifest;self.candidate['binary']['path']=str(self.root/'foreign.exe');self.changed_candidate()
        with self.assertRaisesRegex(RuntimeError,'foreign path'):self.construct()
        self.build_mock.assert_not_called()

    def test_foreign_runtime_config_and_probe_tool_fail_before_verifier(self):
        self.candidate['runtime']['fontconfig']=str(self.root/'foreign-fonts.conf');self.changed_candidate()
        with self.assertRaisesRegex(RuntimeError,'foreign runtime'):self.construct()
        self.candidate['runtime']['fontconfig']=str(self.profile/'config/fonts.conf')
        self.candidate['runtime']['files'][0]['path']=str(self.root/'foreign-tool');self.changed_candidate()
        with self.assertRaisesRegex(RuntimeError,'foreign captured runtime executable'):self.construct()
        self.build_mock.assert_not_called()

    def test_unreviewed_wrapper_and_foreign_protocols_fail(self):
        self.candidate['runtime']['compiler_command']=['wrapper','cc'];self.changed_candidate()
        with self.assertRaisesRegex(RuntimeError,'wrapper'):self.construct()
        self.candidate['runtime']['compiler_command']=['cc'];self.candidate['runtime']['generated_protocols'][0]['path']=str(self.root/'foreign-protocol.h');self.changed_candidate()
        with self.assertRaisesRegex(RuntimeError,'foreign generated'):self.construct()

    def test_bound_inconsistent_and_foreign_source_builds_fail(self):
        for key,value in (('mode','bound'),('source_consistent',False),('source',{'repo':str(self.root/'other')})):
            old=self.candidate[key];self.candidate[key]=value;self.changed_candidate()
            with self.subTest(key=key):
                with self.assertRaisesRegex(RuntimeError,'exact-source'):self.construct()
            self.candidate[key]=old

    def test_changed_live_source_or_runtime_verifier_failure_propagates(self):
        self.build_mock.side_effect=RuntimeError('captured source identity changed')
        with self.assertRaisesRegex(RuntimeError,'source identity changed'):self.construct()
        self.build_mock.side_effect=RuntimeError('captured runtime tree changed')
        with self.assertRaisesRegex(RuntimeError,'runtime tree changed'):self.construct()

    def test_changed_iac_source_during_binding_fails(self):
        self.source_mock.side_effect=[{'status':'before'},{'status':'after'}]
        with self.assertRaisesRegex(RuntimeError,'IaC source changed'):self.construct()

    def test_output_overlap_symlink_unowned_and_existing_fail(self):
        self.arguments['output_root']=self.repo/'evidence';self.arguments['output']=self.repo/'evidence/new.json'
        with self.assertRaisesRegex(RuntimeError,'overlaps'):self.construct()
        self.arguments['output_root']=self.output_root;self.arguments['output']=self.output
        self.output_root.mkdir(mode=0o700)
        with self.assertRaisesRegex(RuntimeError,'unowned'):self.construct()
        (self.output_root/recovery.MARKER).write_text(recovery.MARKER_TEXT);self.output.symlink_to(self.manifest)
        with self.assertRaisesRegex(RuntimeError,'direct absolute'):self.construct()
        self.output.unlink();self.output.write_text('old evidence')
        with self.assertRaisesRegex(RuntimeError,'existing deployment'):recovery.prepare(**self.arguments)
        self.assertEqual(self.output.read_text(),'old evidence')

    def test_changed_config_inventory_bytes_and_profile_tree_fail(self):
        (self.profile/'config/fonts.conf').write_text('<fontconfig><include>/foreign</include></fontconfig>')
        with self.assertRaisesRegex(RuntimeError,'Fontconfig'):self.construct()

    def test_new_component_or_compiled_server_path_cannot_be_repinned_silently(self):
        self.result['compiled_server_directory']='/foreign/server';write(self.mozc/'build-result.json',self.result)
        self.arguments['expected']['mozc_build_result']=recovery.sha(self.mozc/'build-result.json')
        with self.assertRaisesRegex(RuntimeError,'foreign compiled'):self.construct()

    def test_altered_mozc_command_and_native_qualification_claim_fail(self):
        self.result['build_command']=['ninja','all'];write(self.mozc/'build-result.json',self.result);self.arguments['expected']['mozc_build_result']=recovery.sha(self.mozc/'build-result.json')
        with self.assertRaisesRegex(RuntimeError,'build command'):self.construct()
        self.result['build_command']=['ninja','-C','out_linux/Release','-j4','ibus_mozc'];self.result['native_conversion_tested']=True
        write(self.mozc/'build-result.json',self.result);self.arguments['expected']['mozc_build_result']=recovery.sha(self.mozc/'build-result.json')
        with self.assertRaisesRegex(RuntimeError,'built-unqualified'):self.construct()

    def test_prefix_tree_archive_protected_source_and_historical_drift_fail(self):
        self.tree_mock.return_value='d'*64
        with self.assertRaisesRegex(RuntimeError,'prefix tree'):self.construct()
        self.tree_mock.return_value='b'*64;(self.mozc/'archives/source.tar.xz').write_bytes(b'changed archive')
        with self.assertRaisesRegex(RuntimeError,'hash'):self.construct()

    def test_historical_lock_and_protected_source_hash_changes_fail(self):
        historical=self.desktop/'wayland-ime/deployment.lock.json';historical.write_bytes(b'changed historic lock')
        with self.assertRaisesRegex(RuntimeError,'hash'):self.construct()
        historical.write_bytes(self.historical_bytes);(self.mozc/'source/src/ipc/ipc_path_manager.cc').write_bytes(b'changed protected source')
        with self.assertRaisesRegex(RuntimeError,'hash'):self.construct()

    def test_deployment_data_tampering_and_relocation_fail(self):
        path,value=recovery.prepare(**self.arguments);value['native_qualified']=True;write(path,value)
        with self.assertRaisesRegex(RuntimeError,'unsupported'):recovery.verify_deployment(path)
        value['native_qualified']=False;write(path,value);moved=self.output_root/'moved.json';moved.write_bytes(path.read_bytes())
        with self.assertRaisesRegex(RuntimeError,'moved'):recovery.verify_deployment(moved)

    def test_json_duplicates_fail(self):
        self.manifest.write_text('{"mode":"built","mode":"bound"}');self.arguments['expected']['candidate_manifest']=recovery.sha(self.manifest)
        with self.assertRaisesRegex(RuntimeError,'duplicate'):self.construct()


if __name__ == '__main__':unittest.main()
