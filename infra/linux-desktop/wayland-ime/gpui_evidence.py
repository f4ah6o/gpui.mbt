"""Strict GPUI-only read-only replay. Frozen native baseline is not a GPUI pass."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import evidence

STATE_PREFIX = 'GPUI_FIELD_IME_STATE '
HISTORICAL_INPUT_FILES = ('ibus-dbus-snapshot.log','ibus-wayland-snapshot.log','gpui-snapshot.log','events.jsonl',
    'probe.snapshot.py','gpui-evidence.snapshot.py','frozen-probe.snapshot.py',
    'frozen-evidence.snapshot.py','deployment.snapshot.json','gpui-build.snapshot.json','inherited-wayland-socket.txt')
INPUT_FILES = HISTORICAL_INPUT_FILES + ('current-candidate-verification.snapshot.json','render-readiness.json')
KEYS = dict(evidence.KEYS, Control_L=(65507,29), Shift_L=(65505,42), a=(97,30), z=(122,44), k=(107,37))
INTENDED = [('select-all',['Control_L','a'])] + [('roman-preedit',[x]) for x in 'nihonn'] + [
    ('conversion',[x]) for x in ('space','space','Up')] + [('commit',['Return']),
    ('undo',['Control_L','z']),('redo',['Control_L','Shift_L','z'])] + [
    ('cancel-preedit',[x]) for x in 'nihonn'] + [('cancel-convert',['space']),
    ('cancel-revert',['Escape']),('cancel-clear',['Escape'])] + [
    ('blur-preedit',[x]) for x in 'nihonn'] + [('refocus-preedit',[x]) for x in 'ka'] + [('refocus-cancel',['Escape'])]
REQUIRED_STAGES = ('initial','focused','selected','kana-preedit','conversion','committed',
    'undone','redone','cancel-preedit','cancel-conversion','cancel-reverted','cancelled',
    'blur-preedit','blurred','refocused','refocus-preedit','final')
EXPECTED = {
    'initial': dict(committed='Hello 日本',preview='Hello 日本',focused=False,composing=False,commits=0,can_undo=False,can_redo=False,selection={'anchor':0,'head':0}),
    'focused': dict(committed='Hello 日本',preview='Hello 日本',focused=True,entered=True,composing=False,commits=0),
    'selected': dict(committed='Hello 日本',preview='Hello 日本',focused=True,entered=True,composing=False,selection={'anchor':0,'head':8},commits=0),
    'kana-preedit': dict(committed='Hello 日本',preview='にほん',composing=True,marked={'start':0,'end':3},commits=0),
    'conversion': dict(committed='Hello 日本',preview='日本',composing=True,marked={'start':0,'end':2},commits=0),
    'committed': dict(committed='日本',preview='日本',composing=False,marked=None,selection={'anchor':2,'head':2},commits=1,can_undo=True,can_redo=False),
    'undone': dict(committed='Hello 日本',preview='Hello 日本',composing=False,selection={'anchor':0,'head':8},commits=1,can_undo=False,can_redo=True,entered=True,focused=True),
    'redone': dict(committed='日本',preview='日本',composing=False,selection={'anchor':2,'head':2},commits=1,can_undo=True,can_redo=False,entered=True,focused=True),
    'cancel-preedit': dict(committed='日本',preview='日本にほん',composing=True,commits=1),
    'cancel-conversion': dict(committed='日本',preview='日本日本',composing=True,commits=1),
    'cancel-reverted': dict(committed='日本',preview='日本にほん',composing=True,commits=1),
    'cancelled': dict(committed='日本',preview='日本',composing=False,marked=None,selection={'anchor':2,'head':2},commits=1),
    'blur-preedit': dict(committed='日本',preview='日本にほん',composing=True,commits=1),
    'blurred': dict(committed='日本',preview='日本',composing=False,focused=False,entered=False,epoch=0,commits=1),
    'refocused': dict(committed='日本',preview='日本',composing=False,focused=True,entered=True,selection={'anchor':2,'head':2},commits=1),
    'refocus-preedit': dict(committed='日本',preview='日本か',composing=True,commits=1),
    'final': dict(committed='日本',preview='日本',composing=False,marked=None,focused=True,entered=True,selection={'anchor':2,'head':2},commits=1),
}


def validate_checkpoints(points,states):
    require(tuple(p['stage'] for p in points)==REQUIRED_STAGES,'GPUI acceptance checkpoints incomplete')
    last=0
    for point in points:
        v=point['observer']; require(v in states,'checkpoint is not an accepted observer record')
        require(v['presentation']>last,'repeated/reordered checkpoint')
        last=v['presentation']
        require(all(v[k]==x for k,x in EXPECTED[point['stage']].items()),'wrong accepted state at '+point['stage'])
    by_stage={p['stage']:p['observer'] for p in points}
    require(by_stage['refocused']['epoch']>by_stage['blur-preedit']['epoch'],'refocus epoch did not advance')
    require(by_stage['undone']['committed_selection']=={'anchor':0,'head':8},'undo did not restore directional transaction selection')
    require(by_stage['redone']['committed_selection']=={'anchor':2,'head':2},'redo selection mismatch')
    return by_stage

require = evidence.require
sha = evidence.sha


def no_duplicates(pairs):
    result={}
    for k,v in pairs:
        require(k not in result,'duplicate observer key: '+k); result[k]=v
    return result


def presented_states(log):
    values=[]; previous=0
    expected={'version','presentation','committed','preview','selection','committed_selection',
        'marked','composing','focused','revision','epoch','entered','commits','can_undo','can_redo','caret'}
    for line in log.splitlines():
        if not line.startswith(STATE_PREFIX): continue
        try: value=json.loads(line[len(STATE_PREFIX):],object_pairs_hook=no_duplicates)
        except (TypeError,ValueError) as e: raise evidence.EvidenceError('malformed observer: '+str(e)) from e
        require(type(value) is dict and set(value)==expected,'observer schema mismatch')
        require(type(value['version']) is int and value['version']==1,'observer version mismatch')
        for k in ('presentation','revision','epoch','commits'):
            require(type(value[k]) is int and 0<=value[k]<2**53,'invalid observer integer '+k)
        require(value['presentation']==previous+1,'missing, repeated or reordered accepted presentation')
        previous=value['presentation']
        for k in ('committed','preview'): require(type(value[k]) is str,'invalid observer text')
        for k in ('composing','focused','entered','can_undo','can_redo'):
            require(type(value[k]) is bool,'invalid observer boolean '+k)
        for k,text in [('selection',value['preview']),('committed_selection',value['committed'])]:
            n=len(text.encode('utf-16-le'))//2
            require(type(value[k]) is dict and set(value[k])=={'anchor','head'},'invalid selection schema')
            require(all(type(v) is int and 0<=v<=n for v in value[k].values()),'selection out of UTF16 bounds')
        marked=value['marked']
        require((marked is not None)==value['composing'],'marked/composing disagreement')
        if marked is not None:
            require(type(marked) is dict and set(marked)=={'start','end'},'invalid marked range')
            require(all(type(v) is int for v in marked.values()) and 0<=marked['start']<=marked['end']<=len(value['preview'].encode('utf-16-le'))//2,'marked bounds')
        rect=value['caret']
        require(type(rect) is dict and set(rect)=={'x','y','width','height'},'accepted caret missing')
        require(all(type(v) is int and -(2**31)<=v<2**31 for v in rect.values()),'invalid caret integer')
        require(rect['width']>0 and rect['height']>0,'empty caret')
        values.append(value)
    return values


def presentation_frame_ready(log,presentation):
    """Correlate accepted observer N to its actual main-surface frame callbacks."""
    surfaces=re.findall(r'xdg_wm_base(?:#|@)\d+\.get_xdg_surface\(new id xdg_surface(?:#|@)\d+, wl_surface(?:#|@)(\d+)\)',log)
    if len(set(surfaces))!=1:
        return {'ready':False,'reason':'main surface not yet uniquely configured'}
    surface=surfaces[0];observer_at=None
    offset=0
    for line in log.splitlines(keepends=True):
        if line.startswith(STATE_PREFIX):
            value=json.loads(line[len(STATE_PREFIX):],object_pairs_hook=no_duplicates)
            if value['presentation']==presentation:observer_at=offset;break
        offset+=len(line)
    if observer_at is None:return {'ready':False,'reason':'accepted observer record not yet complete'}
    prefix=log[:observer_at]
    commits=list(re.finditer(r'wl_surface(?:#|@)'+surface+r'\.commit\(\)',prefix))
    if not commits:return {'ready':False,'reason':'accepted main-surface commit absent'}
    commit=commits[-1];previous=commits[-2].end() if len(commits)>1 else 0
    requests=list(re.finditer(r'^\[[0-9]+\.[0-9]+\] \{Default Queue\}  -> wl_surface(?:#|@)'+surface+r'\.frame\(new id wl_callback(?:#|@)(\d+)\)$',prefix[previous:commit.start()],re.M))
    ids=[int(m[1]) for m in requests]
    if len(ids)!=1:return {'ready':False,'reason':'one exact own Default Queue frame request not yet bound'}
    observer_end=log.find('\n',observer_at)
    if observer_end<0:return {'ready':False,'reason':'observer line incomplete'}
    tail=log[observer_end+1:]
    done=[]
    for callback in ids:
        match=re.search(r'^\[[0-9]+\.[0-9]+\] \{Default Queue\} wl_callback(?:#|@)'+str(callback)+r'\.done\(\d+\)$',tail,re.M)
        if match:done.append({'callback':callback,'line':log[:observer_end+1+match.start()].count('\n')+1})
    return {'ready':len(done)==len(ids),'surface':int(surface),'presentation':presentation,
        'request_line':prefix[:previous+requests[0].start()].count('\n')+1,
        'commit_line':prefix[:commit.start()].count('\n')+1,
        'observer_line':prefix.count('\n')+1,'requested_callbacks':ids,'completed_callbacks':done}



def validate_render_readiness(root,report):
    root=Path(root)
    readiness=json.loads((root/'render-readiness.json').read_text())
    require(readiness==report['render_readiness'],'render readiness audit differs from retained capture')
    ready=[v for v in readiness if v['status']=='ready']
    require(tuple(v['stage'] for v in ready)==REQUIRED_STAGES,'accepted frame/pixel readiness incomplete')
    for item in readiness:
        if 'pixels' in item:
            require(sha(root/item['pixels']['file'])==item['pixels']['sha256'],'readiness capture changed')
        require(item['status']!='failed-pixel-assertion','readiness concealed a failed pixel assertion')
    for item,point in zip(ready,report['checkpoints']):
        require(item['presentation']==point['observer']['presentation'] and item['frame']['ready'] is True,
            'checkpoint was not the correlated accepted/latched presentation')
        actual=presentation_frame_ready((root/'gpui-snapshot.log').read_text(),item['presentation'])
        require(actual==item['frame'],'readiness callback binding differs from actual native protocol bytes')
        require(item['pixels']['sha256']==point['pixels']['sha256'],'checkpoint differs from ready native pixels')

    return {'qualified_checkpoints':len(ready),'audit_observations':len(readiness),
        'preserved_unready_pixel_captures':sum('pixels' in v and v['status']!='ready' for v in readiness)}


def physical_expected():
    return [(stage,k,down) for stage,keys in INTENDED
            for k,down in [(k,True) for k in keys]+[(k,False) for k in reversed(keys)]]


def validate_rendered_fields(root,report):
    """Compare actual private field pixels, independently of observer text."""
    from PIL import Image,ImageChops
    root=Path(root);field=report['focus_click']['field']
    require(len(field)==4 and all(type(v) is int for v in field),'invalid field pixel bounds')
    l,t,r,b=field
    require(0<=l<r<=960 and 0<=t<b<=640 and (r-l,b-t)==(512,44),'field pixel bounds differ from admitted geometry')
    stages=('selected','undone','committed','redone','cancelled','final')
    crops={}
    for stage in stages:
        im=Image.open(root/(stage+'.png')).convert('RGB')
        require(im.size==(960,640),'private screenshot dimensions changed')
        crops[stage]=im.crop(field)
    pairs=[]
    for before,after in (('selected','undone'),('committed','redone'),('committed','cancelled'),('committed','final')):
        require(crops[before].tobytes()==crops[after].tobytes(),
            'actual rendered field pixels differ: '+before+' -> '+after)
        pairs.append({'before':before,'after':after,'changed_pixels':0,
            'rgb_crop_sha256':hashlib.sha256(crops[before].tobytes()).hexdigest()})
    delta=ImageChops.difference(crops['selected'],crops['committed'])
    require(sum(max(pixel)>0 for pixel in delta.getdata())>20,'replacement did not change actual rendered field')
    # Exclude border/caret: genuine glyph ink must exist in the committed band.
    committed=crops['committed'].crop((2,2,100,31))
    require(sum(max(pixel)<160 for pixel in committed.getdata())>20,'committed Japanese field is visually blank')
    return {'field_bounds':field,'exact_pairs':pairs,'replacement_visually_changed':True,'committed_glyph_ink_present':True}


def held_modifier_ordering(ui,gpui,injected):
    """Bind a whole physical shortcut to one exact active context/grab interval."""
    key_records=list(re.finditer(r'wl_keyboard(?:#|@)(\d+)\.key\(\d+, \d+, (\d+), ([01])\)',ui))
    require(len(key_records)==len(injected),'held ordering needs complete native key records')
    changes=re.compile(r'zwp_input_method_v1(?:#|@)\d+\.(activate|deactivate)\((?:new id )?zwp_input_method_context_v1(?:#|@)(\d+)\)|'
        r'zwp_input_method_context_v1(?:#|@)(\d+)\.grab_keyboard\(new id wl_keyboard(?:#|@)(\d+)\)')
    intervals=[]; active=None
    for m in changes.finditer(ui):
        operation,context,grab_context,keyboard=m.groups()
        if operation=='activate':
            require(active is None,'native context activated before its predecessor deactivated')
            active={'context':int(context),'activate':m.start(),'keyboard':None}
        elif operation=='deactivate':
            require(active is not None and int(context)==active['context'],'deactivation substituted the exact active context')
            require(active['keyboard'] is not None,'active context has no genuine keyboard grab')
            active.update(deactivate=m.start(),deactivate_end=m.end());intervals.append(active);active=None
        else:
            require(active is not None and int(grab_context)==active['context'] and active['keyboard'] is None,'keyboard grab substituted/duplicated active context')
            active.update(keyboard=int(keyboard),grab=m.start(),grab_end=m.end())
    if active is not None:
        require(active['keyboard'] is not None,'final context has no genuine keyboard grab')
        active.update(deactivate=None,deactivate_end=None);intervals.append(active)
    require(intervals,'no native context/grab intervals')
    lifecycle=list(re.finditer(r'zwp_text_input_v1(?:#|@)(\d+)\.(activate|enter|deactivate|leave)\(',gpui))
    require(len(lifecycle)>=4,'GPUI lifecycle missing')
    # The corresponding nth native activation must be the nth GPUI activation.
    gpui_activations=[i for i,m in enumerate(lifecycle) if m[2]=='activate']
    require(len(gpui_activations)==len(intervals),'native/GPUI activation generations differ')
    def time_at(log,pos):
        line=log[log.rfind('\n',0,pos)+1:]
        m=re.match(r'\[([0-9]+\.[0-9]+)\]',line)
        require(m is not None,'official timestamp missing from held lifecycle')
        return float(m[1])
    audit=[]
    for stage in ('select-all','undo','redo'):
        indexes=[i for i,e in enumerate(injected) if e[0]==stage]
        require(indexes and injected[indexes[0]][1:]==('Control_L',True) and
            injected[indexes[-1]][1:]==('Control_L',False),'held stage does not span genuine Ctrl press/release')
        first,release=key_records[indexes[0]],key_records[indexes[-1]]
        owners=[(i,v) for i,v in enumerate(intervals) if v['grab_end']<first.start() and
            (v['deactivate'] is None or first.start()<v['deactivate'])]
        require(len(owners)==1,'initial Ctrl press is not within one exact active grab')
        generation,old=owners[0]
        require(old['deactivate'] is not None,'held old context was never deactivated')
        require(all(int(key_records[i][1])==old['keyboard'] and key_records[i].end()<old['deactivate']
            for i in indexes),'held shortcut release crossed an early context deactivation or keyboard substitution')
        zero=re.search(r'wl_keyboard(?:#|@)'+str(old['keyboard'])+r'\.modifiers\(\d+, 0, 0, 0, 0\)',ui[release.end():old['deactivate']])
        require(zero is not None,'exact old genuine grab lacked modifier0 before deactivation')
        zero_at=release.end()+zero.start()
        require(generation+1<len(intervals),'held shortcut lacks a fresh next native context/grab')
        new=intervals[generation+1]
        require(new['activate']>old['deactivate_end'] and new['grab']>new['activate'],'fresh next context/grab ordering mismatch')
        gpui_i=gpui_activations[generation]
        cycle=lifecycle[gpui_i:gpui_i+6]
        require([m[2] for m in cycle]==['activate','enter','deactivate','leave','activate','enter'] and
            len({m[1] for m in cycle})==1,'exact old GPUI generation lacked leave/new activation/Entered')
        require(time_at(gpui,cycle[2].start())>=time_at(ui,zero_at),
            'GPUI physically deactivated before exact old genuine modifier0')
        audit.append({'stage':stage,'old_context_object':old['context'],'old_keyboard_object':old['keyboard'],
            'old_activation_generation':generation+1,'fresh_context_object':new['context'],'fresh_keyboard_object':new['keyboard'],
            'release_line':ui[:release.start()].count('\n')+1,
            'modifier_zero_line':ui[:zero_at].count('\n')+1,
            'deactivate_line':ui[:old['deactivate']].count('\n')+1,
            'fresh_activate_line':ui[:new['activate']].count('\n')+1})
    return audit


def diagnostic_inventory(log):
    """Preserve every stderr line; known baseline startup assertions are disclosed.
    Unknown diagnostics or any nonempty diagnostic after first activation fail.
    """
    lines=log.splitlines()
    activation=next((i for i,l in enumerate(lines,1) if re.search(r'zwp_input_method_v1(?:#|@)\d+\.activate\(',l)),None)
    require(activation is not None,'no first native activation for diagnostic timing')
    known={
        "IBUS-CRITICAL": ["string_substring: assertion '(offset + len) <= string_length' failed", "string_substring: assertion 'self != NULL' failed"],
        "Gdk-CRITICAL": ["gdk_window_get_events: assertion 'GDK_IS_WINDOW (window)' failed", "gdk_window_set_events: assertion 'GDK_IS_WINDOW (window)' failed"],
    }
    inventory=[]
    for number,line in enumerate(lines,1):
        if not line: continue
        if evidence.WAYLAND_LINE.fullmatch(line+'\n'): continue
        m=re.fullmatch(r"\(ibus-ui-gtk3:(\d+)\): (IBUS-CRITICAL|Gdk-CRITICAL) \*\*: ([0-9:.]+): (.+)",line)
        require(m is not None,'unknown native stderr diagnostic at line '+str(number))
        require(m[4] in known[m[2]],'unexpected native stderr assertion: '+m[4])
        require(number<activation,'native stderr assertion after activation: '+m[4])
        inventory.append({'line':number,'sha256':hashlib.sha256(line.encode()).hexdigest(),
            'pid':int(m[1]),'severity':m[2],'wall_time':m[3],'message':m[4],'before_first_activation':True})
    return {'warnings_present':bool(inventory),'known_baseline_startup_assertions':inventory,
        'first_native_activation_line':activation,'unexpected_or_post_activation_diagnostics':False}


def qualify(root,report,deployment):
    root=Path(root)
    require(report.get('xopen_attempts')==1,'sole authenticated XOpenDisplay gate missing')
    require(report.get('private_display')!=report.get('inherited_display_excluded'),'inherited display reused')
    require(report.get('selected_engine')=='mozc-jp','wrong engine')
    for gate in ('runtime_bind_verified','conversion_verified','cancel_verified','history_verified','blur_refocus_verified'):
        require(report.get(gate) is True,'live GPUI gate failed: '+gate)
    hashes=report.get('evidence_inputs',{})
    version=report.get('evidence_schema_version',1)
    require(version in (1,2),'unsupported evidence schema')
    require(set(hashes)==set(INPUT_FILES if version==2 else HISTORICAL_INPUT_FILES),'complete GPUI evidence manifest missing')
    if version==2:
        captured=json.loads((root/'current-candidate-verification.snapshot.json').read_text())
        require(captured==report['candidate_verification'],'current candidate verification snapshot differs')
        require(captured['source_current_verified'] is True and captured['runtime_current_verified'] is True,
            'live exact source/runtime candidate gates missing')
        require(captured['build_manifest_sha256']==deployment['overlay']['candidate']['manifest']['sha256'],
            'current candidate verification refers to another build')
        build_snapshot=json.loads((root/'gpui-build.snapshot.json').read_text())
        require(captured['source']==build_snapshot['source'] and captured['binary']==build_snapshot['binary'],
            'current candidate exact source/binary identities differ from captured build')
        require(captured['runtime_file_count']==len(build_snapshot['runtime']['files']) and captured['runtime_tree_count']==len(build_snapshot['runtime']['trees']),
            'current candidate runtime closure inventory differs from captured build')
        readiness_summary=validate_render_readiness(root,report)
    else:
        require(report.get('full_suite_verified') is not True and report.get('shortcut_hold_ms')==0,
            'historical diagnostic cannot claim exact-current full held qualification')

    for name,expected in hashes.items(): require(sha(root/name)==expected,'evidence changed: '+name)
    require(json.loads((root/'deployment.snapshot.json').read_text())==deployment['overlay'],'deployment snapshot changed')
    require(sha(root/'gpui-build.snapshot.json')==deployment['overlay']['candidate']['manifest']['sha256'],'candidate manifest snapshot changed')
    ui=(root/'ibus-wayland-snapshot.log').read_text(); gpui=(root/'gpui-snapshot.log').read_text()
    require('wl_display#1.error(' not in ui+gpui and 'protocol error' not in (ui+gpui).lower(),'Wayland protocol error')
    require('GPUI_IME_REJECT' not in gpui,'accepted transport was rejected by GPUI owner')
    diagnostics=diagnostic_inventory(ui)
    require(re.search(r'\.bind\(\d+, "zwp_text_input_manager_v1", 1,',gpui),'GPUI did not bind native manager')
    for name in ('zwp_input_method_v1','zwp_input_panel_v1'):
        require(re.search(r'\.bind\(\d+, "'+name+r'", 1,',ui),'privileged native bind absent: '+name)
    require((root/'inherited-wayland-socket.txt').read_text().strip().isdigit(),'privileged inherited Wayland FD missing')
    require(report['ibus_wayland_process']['exe']==deployment['prefix']+'/usr/libexec/ibus-ui-gtk3','wrong owned UI')
    events=[json.loads(line) for line in (root/'events.jsonl').read_text().splitlines()]
    injected=[(e['stage'],e['keysym'],e['down']) for e in events if 'keysym' in e]
    require(injected==physical_expected(),'exact physical input sequence changed')
    require(report.get('shortcut_hold_ms') in (0,100),'shortcut timing tier missing')
    holds=[e for e in events if e.get('type')=='modifier-hold']
    require([(e['stage'],e['duration_ms']) for e in holds]==
        ([(stage,100) for stage in ('select-all','undo','redo')] if report['shortcut_hold_ms']==100 else []),
        'held shortcut regression cases missing')
    if holds:
        for stage in ('select-all','undo','redo'):
            keys=[e for e in events if e['stage']==stage and 'keysym' in e]
            require(keys[-1]['elapsed_ms']-keys[0]['elapsed_ms']>=90,'held modifier released too early')
    received=[(int(code),bool(int(state))) for code,state in re.findall(r'wl_keyboard(?:#|@)\d+\.key\(\d+, \d+, (\d+), ([01])\)',ui)]
    require(received==[(KEYS[k][1],d) for _,k,d in injected],'grabbed native wl_keyboard delivery differs from OSdriver')
    parser_path=Path(deployment['transport_parser'])
    require(sha(parser_path)==deployment['pins'][str(parser_path)],'frozen Gio parser changed')
    frames,removed=evidence.strict_dbus_frames((root/'ibus-dbus-snapshot.log').read_text(),parser_path)
    require(not removed,'Wayland frames unexpectedly leaked into the separate Gio stdout stream')
    calls=[f for f in frames if f['category']=='sent_process_key_event']
    require([(f['keycode'],bool(not (f['state'] & (1<<30)))) for f in calls]==received,'IBus ProcessKeyEvent physical sequence differs')
    modifiers=0; expected_calls=[]
    for stage,k,down in injected:
        keyval=KEYS[k][0]
        if k=='z' and modifiers&1: keyval=ord('Z')
        expected_calls.append((keyval,KEYS[k][1],modifiers|(0 if down else 1<<30)))
        bit={'Control_L':4,'Shift_L':1}.get(k,0)
        if down: modifiers|=bit
        else: modifiers&=~bit
    require([(f['keyval'],f['keycode'],f['state']) for f in calls]==expected_calls,
        'genuine IBus keysym/modifier state differs from complete physical OSdriver sequence')
    held_order=held_modifier_ordering(ui,gpui,injected) if report['shortcut_hold_ms']==100 else []

    from gi.repository import GLib
    creates=[f for f in frames if f['direction']=='SENT' and f['type']=='method-call' and f['member']=='CreateInputContext' and f['signature']=='s' and f['body']=="('wayland',)"]
    contexts={}
    for c in creates:
        replies=[f for f in frames if f['direction']=='RECEIVED' and f['headers'].get('reply-serial')==c['serial']]
        require(len(replies)==1 and replies[0]['type']=='method-return' and replies[0]['signature']=='o','native context typed reply missing')
        reply=replies[0]; path=GLib.Variant.parse(GLib.VariantType.new('(o)'),reply['body'],None,None).unpack()[0]
        require(path not in contexts,'ambiguous native context reuse'); contexts[path]=reply
    require(contexts and calls,'zero-case native transport cannot qualify')
    for call in calls:
        require(call['path'] in contexts,'key targeted unknown context')
        create=contexts[call['path']]
        require(evidence.exact_context_focused(frames,call['path'],create['frame'],call['frame']),'actual key context lacked FocusIn')
        replies=[f for f in frames if f['direction']=='RECEIVED' and f['headers'].get('reply-serial')==call['serial'] and f['destination']==create['destination']]
        require(len(replies)==1 and replies[0]['type']=='method-return' and replies[0]['signature']=='b','IBus key typed reply missing')
    outgoing=evidence.text_events(ui,'zwp_input_method_context_v1',True)
    incoming=evidence.text_events(gpui,'zwp_text_input_v1',False)
    require([{k:v for k,v in e.items() if k!='object'} for e in outgoing]==[{k:v for k,v in e.items() if k!='object'} for e in incoming],'native IME output differs from GPUI protocol receipts')
    commits=[e for e in incoming if e['member']=='commit_string']
    require(len(commits)==1 and commits[0]['text']=='日本','not exactly one 日本 native commit')
    require(any(e['member']=='preedit_string' and e['text']=='にほん' for e in incoming),'native kana preedit missing')
    states=presented_states(gpui); require(states,'no accepted GPUI states')
    points=report['checkpoints']; validate_checkpoints(points,states)
    for point in points:
        require(point['observer'] in states,'checkpoint is not an accepted observer record')
        require(sha(root/point['pixels']['file'])==point['pixels']['sha256'],'checkpoint pixels changed')
    rendered=validate_rendered_fields(root,report)
    require(states[-1]['committed']=='日本' and states[-1]['preview']=='日本' and states[-1]['commits']==1 and not states[-1]['composing'],'final accepted state differs')
    surrounding=re.findall(r'zwp_text_input_v1(?:#|@)\d+\.set_surrounding_text\("([^"\\]*)", (\d+), (\d+)\)',gpui)
    require(surrounding and surrounding[-1]==('日本','6','6'),'final committed surrounding UTF8 mismatch')
    require(all(t not in ('にほん','日本にほん','日本日本','日本か') for t,_,_ in surrounding),'provisional preview leaked into native surrounding text')
    require(re.search(r'zwp_text_input_v1(?:#|@)\d+\.deactivate\(',gpui),'real blur deactivation absent')
    carets=[tuple(map(int,v)) for v in re.findall(r'zwp_text_input_v1(?:#|@)\d+\.set_cursor_rectangle\((-?\d+), (-?\d+), (\d+), (\d+)\)',gpui)]
    for point in points:
        v=point['observer']; c=v['caret']
        if v['focused']: require(tuple(c[k] for k in ('x','y','width','height')) in carets,'presented caret was not published to native protocol')
    return {'status':'matched','gpui_ime_verified':True,'runtime_diagnostics':diagnostics,'rendered_pixel_evidence':rendered,
            'current_source_runtime_verified_at_launch':version==2,
            'render_readiness':readiness_summary if version==2 else {'historical_frame_fence_verified':False},'matched_injected_events':len(injected),
        'matched_grabbed_events':len(received),'matched_ibus_key_calls':len(calls),'matched_v1_text_events':len(incoming),
        'native_context_paths':sorted(contexts),'accepted_presentations':len(states),'checkpoints':list(REQUIRED_STAGES),
        'complete_dbus_frames':len(frames),'demultiplexed_wayland_lines':len(removed),'demultiplex_audit':removed,
        'shortcut_hold_ms':report['shortcut_hold_ms'],'held_shortcut_regression_verified':report['shortcut_hold_ms']==100,'held_modifier_ordering':held_order,
        'exact_commits':1,'final_text':'日本','final_cursor_utf8':6,'api_sender_pid_verified':False}


def panel_evidence(root,report):
    from PIL import Image,ImageChops
    gpui=(Path(root)/'gpui-snapshot.log').read_text()
    requests={'show_requests':len(re.findall(r'zwp_text_input_v1(?:#|@)\d+\.show_input_panel\(',gpui)),
        'hide_requests':len(re.findall(r'zwp_text_input_v1(?:#|@)\d+\.hide_input_panel\(',gpui))}
    require(requests['show_requests']>0 and requests['hide_requests']>=4,'actual GPUI panel show/hide requests incomplete')
    requests['native_panel_states']=[int(x) for x in re.findall(r'zwp_text_input_v1(?:#|@)\d+\.input_panel_state\(([01])\)',gpui)]
    # Pixel lifetime requires the popup to vanish outside the owner field/window.
    # Distinguish verified protocol requests from actually visible UI lifetime.
    base=Image.open(Path(root)/'initial.png').convert('RGB')
    l,t,r,b=report['focus_click']['body']
    metrics={}
    for stage in ('kana-preedit','conversion','committed','cancelled','blurred','final'):
        current=Image.open(Path(root)/(stage+'.png')).convert('RGB')
        diff=ImageChops.difference(base,current)
        # Exclude only owner field/title and known pointer locations.
        # A candidate popup drawn inside the GPUI viewport must remain visible.
        from PIL import ImageDraw
        draw=ImageDraw.Draw(diff)
        draw.rectangle(report['focus_click']['field'],fill=(0,0,0))
        draw.rectangle((l-12,t-40,r+12,t-1),fill=(0,0,0))
        draw.rectangle((470,310,505,352),fill=(0,0,0))
        cx,cy=report['focus_click']['x'],report['focus_click']['y']
        draw.rectangle((cx-12,cy-12,cx+32,cy+38),fill=(0,0,0))
        # Current pointer is at the clicked field; initial pointer can be anywhere.
        changed=sum(max(pixel)>16 for pixel in diff.getdata())
        metrics[stage]=changed
    showing=max(metrics['kana-preedit'],metrics['conversion'])>100
    hidden=all(metrics[k]<=100 for k in ('committed','cancelled','blurred','final'))
    return dict(requests,pixel_show_verified=showing,pixel_hide_verified=showing and hidden,
        outside_viewport_changed_pixels=metrics,candidate_table_verified=False,
        limitation=None if showing and hidden else 'GPUI protocol show/hide requests are separate from popup lifetime; native popup visibility remains pending if pixels linger.')


def main():
    p=argparse.ArgumentParser(description=__doc__); p.add_argument('run',type=Path); a=p.parse_args()
    import gpui_probe
    overlay=a.run/'deployment.snapshot.json'; data,_,_=gpui_probe.preflight(overlay,current=False)
    report=json.loads((a.run/'result.json').read_text())
    require(report['status'] in ('passed','qualified-partial') and report['cleanup']['verified'],'live GPUI/owned cleanup failed')
    print(json.dumps({'transport':qualify(a.run,report,data),'panel':panel_evidence(a.run,report)},ensure_ascii=False,indent=2))

if __name__=='__main__': main()
