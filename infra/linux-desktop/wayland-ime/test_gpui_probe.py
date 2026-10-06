#!/usr/bin/python3
"""Static GPUI probe safety and fail-closed observer/replay acceptance checks."""
import ast
from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import gpui_evidence as e
import gpui_probe as p


def state(n=1):
    return dict(version=1,presentation=n,committed='Hello 日本',preview='Hello 日本',
        selection={'anchor':0,'head':0},committed_selection={'anchor':0,'head':0},
        marked=None,composing=False,focused=False,revision=0,epoch=0,entered=False,
        commits=0,can_undo=False,can_redo=False,caret={'x':28,'y':36,'width':1,'height':22})


def line(v): return e.STATE_PREFIX+json.dumps(v,ensure_ascii=False)


class GpuiProbeTests(unittest.TestCase):
    def test_import_read_only(self):
        with patch('subprocess.Popen',side_effect=AssertionError('launch')),patch('subprocess.run',side_effect=AssertionError('launch')):
            spec=importlib.util.spec_from_file_location('gpui_import',HERE/'gpui_probe.py');spec.loader.exec_module(importlib.util.module_from_spec(spec))

    def test_check_read_only(self):
        with patch('subprocess.Popen',side_effect=AssertionError('launch')),patch('subprocess.run',side_effect=AssertionError('launch')),patch('builtins.print'),patch.object(p,'preflight',return_value=({'pins':{},'overlay':{'candidate':{}},'candidate_verification':{}},None,None)):
            self.assertEqual(p.main(['--check','--deployment','/explicit/fixture.json']),0)

    def test_frozen_baseline_preserved(self):
        data=json.loads((HERE/'deployment.lock.json').read_text())
        server=data['prefix']+'/usr/lib/mozc/mozc_server'
        self.assertEqual(data['pins'][server],'020f50a6cd53b3a0a5e6c66a30f698b05d5c68df4b5be73e663c1435bc8c432e')
        # GPUI source never carries a candidate-specific self-referential lock.
        self.assertFalse((HERE/'gpui-deployment.lock.json').exists())

    def test_candidate_overlay_requires_exact_consistent_manifest(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);base=root/'baseline.json';base.write_text('{}')
            app=root/'app';app.write_bytes(b'fixture');manifest=root/'build.json'
            m={'binary':{'path':str(app),'sha256':p.sha(app)},'source_consistent':True}
            manifest.write_text(json.dumps(m))
            data={'schema_version':1,'kind':'gpui-ime-overlay','baseline_deployment':str(base),
                'baseline_deployment_sha256':p.sha(base),'candidate':{'app':{'path':str(app),'sha256':p.sha(app)},
                'manifest':{'path':str(manifest),'sha256':p.sha(manifest)}}}
            overlay=root/'overlay.json';overlay.write_text(json.dumps(data))
            with patch.object(p.frozen_probe,'preflight',return_value=({'pins':{}},'driver','baseline')):
                result,driver,baseline=p.preflight(overlay)
                self.assertEqual(result['gpui_app'],str(app));self.assertEqual(driver,'driver')
                app.write_bytes(b'changed')
                with self.assertRaises(RuntimeError):p.preflight(overlay)

    def test_overlay_generator_read_only_and_refuses_reuse(self):
        spec=importlib.util.spec_from_file_location('gpui_deployment_generator',HERE/'prepare-gpui-deployment.py')
        generator=importlib.util.module_from_spec(spec);spec.loader.exec_module(generator)
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);base=root/'baseline.json';base.write_text('{}');app=root/'app';app.write_bytes(b'fixture')
            manifest=root/'build.json';manifest.write_text(json.dumps({'source_consistent':True,'binary':{'path':str(app),'sha256':p.sha(app)}}))
            evidence_root=root/'evidence';evidence_root.mkdir();output=evidence_root/'overlay.json'
            with patch.object(p,'verify_current_candidate',return_value={'fixture_verified':True}),patch.object(p.frozen_probe,'preflight',return_value=({'pins':{},'output_root':str(evidence_root)},None,None)),patch('subprocess.Popen',side_effect=AssertionError('launch')),patch('subprocess.run',side_effect=AssertionError('launch')):
                value=generator.prepare(base,manifest,output)
                self.assertEqual(value['candidate']['app']['sha256'],p.sha(app))
                with self.assertRaises(RuntimeError):generator.prepare(base,manifest,output)
                with self.assertRaises(RuntimeError):generator.prepare(base,manifest,root/'source-overlay.json')

    def test_live_exact_source_tree_and_runtime_mutations(self):
        verifier=p.load_module(HERE.parent/'build_manifest.py','fixture_build_verifier')
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);app=root/'app';app.write_bytes(b'fixture')
            source={'repo':str(root),'head':'a'*40,'tree':'b'*40,'tracked_patch_utf8':'',
                'tracked_patch_sha256':'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
                'status':'','untracked_files':[]}
            manifest=root/'build.json';value={'version':1,'kind':'gpui-field-build','mode':'built',
                'source':source,'source_consistent':True,'binary':verifier.file_identity(app),
                'runtime':{'files':[],'trees':[]}}
            manifest.write_text(json.dumps(value))
            with patch.object(p,'load_module',return_value=verifier),patch.object(verifier,'capture_source',return_value=source),patch.object(verifier,'verify_runtime') as runtime:
                got=p.verify_current_candidate(manifest);self.assertTrue(got['source_current_verified']);runtime.assert_called_once()
            for field in ('head','tree','status','untracked_files'):
                changed=deepcopy(source);changed[field]=[] if field=='status' else 'changed'
                with patch.object(p,'load_module',return_value=verifier),patch.object(verifier,'capture_source',return_value=changed),patch.object(verifier,'verify_runtime'):
                    with self.assertRaises(RuntimeError):p.verify_current_candidate(manifest)
            with patch.object(p,'load_module',return_value=verifier),patch.object(verifier,'capture_source',return_value=source),patch.object(verifier,'verify_runtime',side_effect=RuntimeError('runtime closure changed')):
                with self.assertRaises(RuntimeError):p.verify_current_candidate(manifest)
            value['mode']='bound';manifest.write_text(json.dumps(value))
            with patch.object(p,'load_module',return_value=verifier),patch.object(verifier,'capture_source',return_value=source),patch.object(verifier,'verify_runtime'):
                with self.assertRaises(RuntimeError):p.verify_current_candidate(manifest)

    def test_only_one_xopen(self):
        tree=ast.parse((HERE/'gpui_probe.py').read_text())
        calls=[n for n in ast.walk(tree) if isinstance(n,ast.Call) and isinstance(n.func,ast.Attribute) and n.func.attr=='connect']
        self.assertEqual(len(calls),1)

    def test_owned_cleanup_and_optin(self):
        s=(HERE/'gpui_probe.py').read_text()
        for word in ('pidfd_send_signal','private_processes','GPUI_FIELD_WAYLAND_IME','GPUI_FIELD_E2E_STATE','held-shortcuts'): self.assertIn(word,s)
        for word in ('killall','pkill','weston-editor'): self.assertNotIn(word,s)

    def test_observer_schema(self): self.assertEqual(e.presented_states(line(state())),[state()])

    def test_missing_or_extra_fields(self):
        for k in state():
            v=state();del v[k]
            with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(v))
        v=state();v['injected']=True
        with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(v))

    def test_duplicate_json(self):
        with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(state())[:-1]+',"version":1}')

    def test_invalid_numeric_boolean(self):
        for k in ('version','presentation','revision','epoch','commits'):
            v=state();v[k]=True
            with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(v))

    def test_repeated_skipped_reordered(self):
        for n in (1,3,0):
            with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(state())+'\n'+line(state(n)))

    def test_utf16_bounds(self):
        v=state();v['preview']='😀';v['selection']={'anchor':0,'head':2}
        self.assertEqual(len(e.presented_states(line(v))),1)
        v['selection']['head']=3
        with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(v))

    def test_marked_composition(self):
        for changes in ({'composing':True},{'marked':{'start':0,'end':1}},{'caret':None}):
            v=state();v.update(changes)
            with self.assertRaises(e.evidence.EvidenceError):e.presented_states(line(v))

    def test_empty_never_qualifies(self):
        with self.assertRaises(e.evidence.EvidenceError):e.validate_checkpoints([],[])

    def test_checkpoint_requirements(self):
        states=[];points=[]
        for i,stage in enumerate(e.REQUIRED_STAGES,1):
            v=state(i);v.update(e.EXPECTED[stage]);v['epoch']=10 if stage=='refocused' else v['epoch']
            if stage=='undone':v['committed_selection']={'anchor':0,'head':8}
            if stage=='redone':v['committed_selection']={'anchor':2,'head':2}
            states.append(v);points.append({'stage':stage,'observer':v})
        e.validate_checkpoints(points,states)
        for i,stage in enumerate(e.REQUIRED_STAGES):
            wrong=deepcopy(points);wrong[i]['observer']['commits']+=1
            with self.assertRaises(e.evidence.EvidenceError):e.validate_checkpoints(wrong,[x['observer'] for x in wrong])

    def test_pixel_geometry(self):
        from PIL import Image,ImageDraw
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'im.png';im=Image.new('RGB',(960,640),(32,32,32));ImageDraw.Draw(im).rectangle((101,81,740,320),fill=(24,28,36));ImageDraw.Draw(im).rectangle((125,109,636,152),fill=(255,255,255));im.save(path)
            self.assertEqual(p.gpui_click_from_pixels(path)['body'],[101,81,741,321])
            ImageDraw.Draw(im).point((0,0),fill=(24,28,36));im.save(path)
            with self.assertRaises(RuntimeError):p.gpui_click_from_pixels(path)

    def test_diagnostics_preserved_and_timed(self):
        activation='[1000.000] {Default Queue} zwp_input_method_v1#2.activate(new id zwp_input_method_context_v1#3)\n'
        warning="(ibus-ui-gtk3:123): Gdk-CRITICAL **: 15:00:00.001: gdk_window_get_events: assertion 'GDK_IS_WINDOW (window)' failed\n"
        value=e.diagnostic_inventory(warning+activation)
        self.assertTrue(value['warnings_present'])
        self.assertEqual(value['known_baseline_startup_assertions'][0]['message'],"gdk_window_get_events: assertion 'GDK_IS_WINDOW (window)' failed")
        for text in (activation+warning,'arbitrary warning\n'+activation,warning):
            with self.assertRaises(e.evidence.EvidenceError):e.diagnostic_inventory(text)

    def test_wrapper_separates_actual_streams(self):
        text=p.input_method_wrapper(Path('/owned/prefix'),Path('/owned/output'))
        self.assertIn('--enable-wayland-im > /owned/output/ibus-dbus.log 2> /owned/output/ibus-wayland.log',text)
        self.assertNotIn('2>&1',text)
        self.assertIn('IBUS_ENABLE_SYNC_MODE=1',text)
        self.assertIn('test -n "${WAYLAND_SOCKET:-}"',text)

    def test_held_ordering_exact_context_and_mutations(self):
        def wl(text):return '[1000.000] {Default Queue} '+text+'\n'
        ui=wl('zwp_input_method_v1#8.activate(new id zwp_input_method_context_v1#11)')+wl(' -> zwp_input_method_context_v1#11.grab_keyboard(new id wl_keyboard#1)')
        gpui=wl(' -> zwp_text_input_v1#9.activate(seat,surface)')+wl('zwp_text_input_v1#9.enter(surface)')
        injected=[]
        for n,stage in enumerate(('select-all','undo','redo'),1):
            injected.extend([(stage,'Control_L',True),(stage,'Control_L',False)])
            ui+=wl(f'wl_keyboard#{n}.key(1, 2, 29, 1)')+wl(f'wl_keyboard#{n}.key(1, 2, 29, 0)')+wl(f'wl_keyboard#{n}.modifiers(2, 0, 0, 0, 0)')
            ui+=wl(f'zwp_input_method_v1#8.deactivate(zwp_input_method_context_v1#{n+10})')+wl(f'zwp_input_method_v1#8.activate(new id zwp_input_method_context_v1#{n+11})')+wl(f' -> zwp_input_method_context_v1#{n+11}.grab_keyboard(new id wl_keyboard#{n+1})')
            gpui+=wl(' -> zwp_text_input_v1#9.deactivate(seat)')+wl('zwp_text_input_v1#9.leave()')+wl(' -> zwp_text_input_v1#9.activate(seat,surface)')+wl('zwp_text_input_v1#9.enter(surface)')
        self.assertEqual(len(e.held_modifier_ordering(ui,gpui,injected)),3)
        altered=[]
        altered.append(ui.replace('.modifiers(2, 0, 0, 0, 0)','.modifiers(2, 4, 0, 0, 0)'))
        altered.append(ui.replace('deactivate(zwp_input_method_context_v1#11)','deactivate(zwp_input_method_context_v1#99)'))
        altered.append(ui.replace('zwp_input_method_context_v1#12.grab_keyboard','zwp_input_method_context_v1#99.grab_keyboard'))
        altered.append(ui.replace('wl_keyboard#1.key(1, 2, 29, 0)','wl_keyboard#99.key(1, 2, 29, 0)'))
        # Early deactivate/new context before each release, followed by normal
        # later cycles, must not let an unrelated later zero/deactivate pass.
        early=ui
        for n in (1,2,3):
            insertion=wl(f'zwp_input_method_v1#8.deactivate(zwp_input_method_context_v1#{n+10})')+wl(f'zwp_input_method_v1#8.activate(new id zwp_input_method_context_v1#{n+10})')+wl(f' -> zwp_input_method_context_v1#{n+10}.grab_keyboard(new id wl_keyboard#{n})')
            early=early.replace(wl(f'wl_keyboard#{n}.key(1, 2, 29, 0)'),insertion+wl(f'wl_keyboard#{n}.key(1, 2, 29, 0)'))
        altered.append(early)
        for bad in altered:
            with self.assertRaises(e.evidence.EvidenceError):e.held_modifier_ordering(bad,gpui,injected)

    def test_rendered_pairs_and_mutations_fail_closed(self):
        from PIL import Image,ImageDraw
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);report={'focus_click':{'field':[24,28,536,72]}}
            for stage in ('selected','undone','committed','redone','cancelled','final'):
                im=Image.new('RGB',(960,640),(24,28,36));draw=ImageDraw.Draw(im)
                draw.rectangle((24,28,535,71),fill=(255,255,255))
                draw.rectangle((29,33,45 if stage in ('selected','undone') else 37,45),fill=(0,0,0));im.save(root/(stage+'.png'))
            self.assertEqual(len(e.validate_rendered_fields(root,report)['exact_pairs']),4)
            for stage in ('undone','redone','cancelled','final'):
                path=root/(stage+'.png');original=path.read_bytes();im=Image.open(path);im.putpixel((100,40),(0,0,0));im.save(path)
                with self.assertRaises(e.evidence.EvidenceError):e.validate_rendered_fields(root,report)
                path.write_bytes(original)
            report['focus_click']['field'][2]=535
            with self.assertRaises(e.evidence.EvidenceError):e.validate_rendered_fields(root,report)

    def test_correlated_frame_readiness_before_pixels(self):
        from PIL import Image,ImageDraw
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);log='[1000.000] {Default Queue}  -> xdg_wm_base#1.get_xdg_surface(new id xdg_surface#2, wl_surface#3)\n[1000.001] {Default Queue}  -> wl_surface#3.frame(new id wl_callback#4)\n[1000.002] {mesa egl surface queue}  -> wl_surface#3.frame(new id wl_callback#5)\n[1000.003] {mesa egl surface queue}  -> wl_surface#3.commit()\n'+line(state())+'\n'
            self.assertFalse(p.presentation_frame_ready(log,1)['ready'])
            log+='[1000.004] {Default Queue} wl_callback#4.done(1)\n'
            self.assertTrue(p.presentation_frame_ready(log,1)['ready'])
            self.assertEqual(p.presentation_frame_ready(log,1)['requested_callbacks'],[4])
            # An earlier callback or EGL display-sync callback cannot settle
            # the accepted main-field presentation, even with a reused ID.
            for bad in (log.replace('[1000.004] {Default Queue} wl_callback#4.done(1)\n','[1000.004] {mesa egl surface queue} wl_callback#5.done(1)\n'),log.replace(line(state())+'\n','').replace('[1000.004] {Default Queue} wl_callback#4.done(1)\n','[1000.004] {Default Queue} wl_callback#4.done(1)\n'+line(state())+'\n')):
                self.assertFalse(p.presentation_frame_ready(bad,1)['ready'])
            tick=[0];captured=[];audit=[]
            def clock():return tick[0]
            def poll():tick[0]+=.02
            def capture(name):
                captured.append(name);path=root/(name+'.png');im=Image.new('RGB',(960,640),(32,32,32))
                if len(captured)>1:
                    draw=ImageDraw.Draw(im);draw.rectangle((101,81,740,320),fill=(24,28,36));draw.rectangle((125,109,636,152),fill=(255,255,255))
                im.save(path);return {'file':path.name,'sha256':p.sha(path)}
            pixels,geometry=p.await_presented_pixels('initial',1,lambda:log,capture,lambda v:root/v['file'],audit,locate=True,clock=clock,poll=poll,timeout_seconds=.1)
            self.assertEqual(len(captured),2);self.assertEqual(audit[0]['status'],'awaiting-actual-viewport-field-pixels');self.assertEqual(audit[-1]['status'],'ready')
            self.assertTrue((root/audit[0]['pixels']['file']).exists());self.assertEqual(geometry['body'],[101,81,741,321])
            # Accepted state alone must never qualify or capture before callback.
            audit=[];captured=[];tick[0]=0
            with self.assertRaisesRegex(RuntimeError,'timed out'):
                p.await_presented_pixels('initial',1,lambda:log.replace('wl_callback#4.done(1)','wl_callback#99.done(1)'),capture,lambda v:root/v['file'],audit,locate=True,clock=clock,poll=poll,timeout_seconds=.1)
            self.assertEqual(captured,[])
            # Ambiguous geometry is a failed assertion, not a hidden retry.
            bad=root/'bad.png';im=Image.new('RGB',(960,640),(24,28,36));im.save(bad);tick[0]=0;audit=[]
            with self.assertRaisesRegex(RuntimeError,'ambiguous'):
                p.await_presented_pixels('initial',1,lambda:log,lambda n:{'file':bad.name,'sha256':p.sha(bad)},lambda v:root/v['file'],audit,locate=True,clock=clock,poll=poll,timeout_seconds=.1)
            self.assertEqual(audit[0]['status'],'failed-pixel-assertion')

    def test_readiness_replay_recomputes_protocol_not_self_report(self):
        with tempfile.TemporaryDirectory() as root:
            root=Path(root);log='[1000.000] {Default Queue}  -> xdg_wm_base#1.get_xdg_surface(new id xdg_surface#2, wl_surface#3)\n'
            points=[];audit=[]
            for i,stage in enumerate(e.REQUIRED_STAGES,1):
                callback=100+i
                log+=f'[1000.001] {{Default Queue}}  -> wl_surface#3.frame(new id wl_callback#{callback})\n[1000.002] {{mesa egl surface queue}}  -> wl_surface#3.commit()\n'+line(state(i))+f'\n[1000.003] {{Default Queue}} wl_callback#{callback}.done(1)\n'
                path=root/(stage+'.png');path.write_bytes(b'capture:'+stage.encode());pixels={'file':path.name,'sha256':p.sha(path)}
                points.append({'stage':stage,'observer':{'presentation':i},'pixels':pixels})
                audit.append({'stage':stage,'status':'ready','presentation':i,'pixels':pixels,'frame':e.presentation_frame_ready(log,i)})
            report={'checkpoints':points,'render_readiness':audit};(root/'render-readiness.json').write_text(json.dumps(audit));(root/'gpui-snapshot.log').write_text(log)
            self.assertEqual(e.validate_render_readiness(root,report)['qualified_checkpoints'],17)
            for bad in (log.replace('wl_callback#101.done(1)','wl_callback#999.done(1)'),log.replace('[1000.003] {Default Queue} wl_callback#101.done(1)\n','')):
                (root/'gpui-snapshot.log').write_text(bad)
                with self.assertRaises(e.evidence.EvidenceError):e.validate_render_readiness(root,report)
            (root/'gpui-snapshot.log').write_text(log);wrong=deepcopy(audit);wrong[0]['frame']['requested_callbacks']=[999]
            report['render_readiness']=wrong;(root/'render-readiness.json').write_text(json.dumps(wrong))
            with self.assertRaises(e.evidence.EvidenceError):e.validate_render_readiness(root,report)

    def test_exact_physical_sequence_nonzero(self):
        seq=e.physical_expected();self.assertGreater(len(seq),60)
        for stage in ('select-all','undo','redo'):
            events=[x for x in seq if x[0]==stage]
            self.assertEqual(events[0][1:3],('Control_L',True));self.assertEqual(events[-1][1:3],('Control_L',False))

if __name__=='__main__':unittest.main()
