"""Bounded palette application acceptance, using the existing private native harness.
No runtime is launched on import. Native AT-SPI is explicitly unsupported here.
"""
import json
import re
from pathlib import Path
import gpui_evidence
import evidence

PREFIX='GPUI_PALETTE_STATE '

INPUTS=[('roman-preedit',k) for k in 'nihonn']+[('conversion',k) for k in ('space','space','Up')]+[('commit','Return'),('skip-disabled','Down')]+[('scroll-selection','Down') for _ in range(9)]+[('activate','Return'),('background-key','Return')]+[('cancel-preedit',k) for k in 'nihonn']+[('cancel-composition','Escape'),('dismiss','Escape')]+[('blur-preedit',k) for k in 'nihonn']+[('fresh-preedit',k) for k in 'ka']+[('fresh-cancel','Escape'),('final-dismiss','Escape')]
KEYS=dict(gpui_evidence.KEYS,Down=(65364,108))
STAGES=('initial','opened','kana-preedit','conversion','committed','skip-disabled','scrolled',
    'activated','background-key','reopened','cancel-preedit','cancelled','dismissed',
    'blur-reopened','blur-preedit','blurred','fresh-reopened','fresh-preedit','fresh-cancelled','final')

def merge_state(log,field):
    if field is None:return None
    lines=[line[len(PREFIX):] for line in log.splitlines() if line.startswith(PREFIX)]
    if not lines:return None
    try:palette=json.loads(lines[-1],object_pairs_hook=gpui_evidence.no_duplicates)
    except ValueError:return None
    if palette['presentation']!=field['presentation']:return None
    return dict(field,**palette)

def locate(png):
    from PIL import Image
    import gpui_probe
    image=Image.open(png).convert('RGB')
    points=[(x,y) for y in range(image.height) for x in range(image.width) if image.getpixel((x,y))==(24,28,36)]
    if not points:raise gpui_probe.PixelsNotReady('palette viewport absent')
    left,right=min(x for x,y in points),max(x for x,y in points)+1
    top,bottom=min(y for x,y in points),max(y for x,y in points)+1
    if (right-left,bottom-top)!=(640,480):raise RuntimeError('ambiguous palette viewport geometry')
    field=[left+24,top+28,left+536,top+72]
    if not all(image.getpixel((x,y))==(48,74,114) for x,y in ((field[0]+2,field[1]+2),(field[2]-3,field[1]+2),(field[0]+2,field[3]-3),(field[2]-3,field[3]-3))):
        raise gpui_probe.PixelsNotReady('admitted palette opener pixels absent')
    return dict(x=left+510,y=top+50,body=[left,top,right,bottom],field=field)

def exercise(expect,key,chord,click_field,x,window,current,output,report,wait,click,log_event):
    expect('initial',open=False,committed='',preview='',focused=False,actions=0,background_actions=0,background_releases=0,focus_owner=9)
    click.update(report['focus_click']);x.focus(window);click_field('open-palette')
    opened=expect('opened',open=True,focused=True,entered=True,query='',matches=13,active_id='palette.command.0',actions=0,background_actions=0,focus_owner=2)
    report['runtime_bind_verified']=True
    for name in 'nihonn':key(name,'roman-preedit')
    expect('kana-preedit',open=True,committed='',preview='にほん',composing=True,query='',matches=13,actions=0)
    for name in ('space','space','Up'):key(name,'conversion')
    expect('conversion',open=True,committed='',preview='日本',composing=True,query='',matches=13,actions=0)
    key('Return','commit')
    committed=expect('committed',open=True,committed='日本',preview='日本',composing=False,query='日本',matches=12,active_id='palette.command.1',actions=0,background_actions=0,commits=1)
    key('Down','skip-disabled')
    expect('skip-disabled',open=True,query='日本',active_id='palette.command.3',active_index=2,actions=0)
    for _ in range(9):key('Down','scroll-selection')
    expect('scrolled',open=True,active_id='palette.command.12',active_index=11,visible_start=4,visible_count=8,actions=0)
    key('Return','activate')
    expect('activated',open=False,actions=1,last_action='palette.command.12',background_actions=0,background_releases=0,focus_owner=9,focused=False,entered=False,direct_ready=True)
    key('Return','background-key')
    expect('background-key',open=False,actions=1,background_actions=1,background_releases=1,focus_owner=9)
    click_field('reopen-palette')
    reopened=expect('reopened',open=True,committed='',preview='',query='',matches=13,actions=1,background_actions=1,focused=True,entered=True)
    evidence.require(reopened['open_epoch']>opened['open_epoch'] and reopened['epoch']>committed['epoch'],'reopen epochs not fresh')
    for name in 'nihonn':key(name,'cancel-preedit')
    expect('cancel-preedit',open=True,committed='',preview='にほん',composing=True,query='',matches=13,actions=1)
    key('Escape','cancel-composition')
    expect('cancelled',open=True,committed='',preview='',composing=False,query='',actions=1,background_actions=1)
    key('Escape','dismiss')
    expect('dismissed',open=False,actions=1,background_actions=1,background_releases=1,focus_owner=9,direct_ready=True)
    click_field('blur-reopen')
    expect('blur-reopened',open=True,committed='',preview='',query='',focused=True,entered=True)
    for name in 'nihonn':key(name,'blur-preedit')
    before_blur=expect('blur-preedit',open=True,committed='',preview='にほん',composing=True,query='',actions=1)
    x.focus(x.away_window());log_event({'stage':'blur','type':'focus','target':'private-decoy'})
    expect('blurred',open=False,committed='',preview='',composing=False,focused=False,entered=False,epoch=0,actions=1,background_actions=1,background_releases=1,focus_owner=9)
    x.focus(window);click_field('fresh-reopen')
    fresh=expect('fresh-reopened',open=True,committed='',preview='',query='',focused=True,entered=True,actions=1,background_actions=1)
    evidence.require(fresh['epoch']>before_blur['epoch'],'blur reactivation inherited stale native epoch')
    for name in 'ka':key(name,'fresh-preedit')
    expect('fresh-preedit',open=True,committed='',preview='か',composing=True,query='',matches=13,actions=1)
    key('Escape','fresh-cancel')
    expect('fresh-cancelled',open=True,committed='',preview='',composing=False,query='',actions=1)
    key('Escape','final-dismiss')
    expect('final',open=False,committed='',preview='',composing=False,actions=1,background_actions=1,background_releases=1,focus_owner=9,direct_ready=True)
    report.update(palette_flow_verified=True,conversion_verified=True,cancel_verified=True,blur_refocus_verified=True,
        semantic_contract='PASS',native_accessibility_transport='UNSUPPORTED',candidate_contents_highlight='UNRUN')

def qualify(root,report,data):
    root=Path(root);require=evidence.require
    if data.get('kind') == 'native-ime-recovery-baseline':
        import gpui_probe
        helper=gpui_probe.load_module(Path(data['baseline_utilities']),'recorded_palette_owner_validator')
        helper.validate_task_owner_receipt(root,report,require_cleanup=report.get('status')=='passed')
    require(report.get('xopen_attempts')==1 and report['private_display']!=report['inherited_display_excluded'],'private X ownership gate missing')
    require(report.get('palette_flow_verified') is True,'palette flow incomplete')
    for name,digest in report['evidence_inputs'].items():require(evidence.sha(root/name)==digest,'retained evidence changed: '+name)
    require(evidence.sha(root/'gpui-build.snapshot.json')==data['overlay']['candidate']['manifest']['sha256'],'build snapshot changed')
    require(tuple(p['stage'] for p in report['checkpoints'])==STAGES,'palette checkpoints incomplete')
    gpui=(root/'gpui-snapshot.log').read_text();ui=(root/'ibus-wayland-snapshot.log').read_text()
    require('GPUI_PALETTE_REJECT' not in gpui and 'GPUI_IME_REJECT' not in gpui,'palette rejected actual native input')
    require('protocol error' not in (gpui+ui).lower() and 'wl_display#1.error(' not in gpui+ui,'protocol error')
    require(report['selected_engine']=='mozc-jp','wrong Japanese engine')
    diagnostics=gpui_evidence.diagnostic_inventory(ui)
    states=gpui_evidence.presented_states(gpui)
    readiness=[v for v in report['render_readiness'] if v['status']=='ready']
    require(tuple(v['stage'] for v in readiness)==STAGES,'accepted frame readiness incomplete')
    for point,item in zip(report['checkpoints'],readiness):
        value=point['observer'];require(value['visible_count']<=8,'unbounded rendered option count')
        require(any(field['presentation']==value['presentation'] for field in states),'unaccepted palette observer')
        require(item['frame']==gpui_evidence.presentation_frame_ready(gpui,value['presentation']) and item['frame']['ready'],'uncorrelated palette frame')
        require(evidence.sha(root/point['pixels']['file'])==point['pixels']['sha256']==item['pixels']['sha256'],'checkpoint pixels changed')
        if value['open']:
            semantic=value['semantic'];require(semantic['role']=='dialog' and semantic['search_name']=='Search commands' and semantic['search_value']==value['committed'] and semantic['collection_role']=='listbox','portable semantics mismatch')
            selected=[v for v in semantic['options'] if v['selected']]
            require(len(selected)==1 and selected[0]['id']==value['active_id'] and not selected[0]['disabled'],'active semantics not exposed')
    frames,removed=evidence.strict_dbus_frames((root/'ibus-dbus-snapshot.log').read_text(),Path(data['transport_parser']))
    require(not removed,'Wayland log contaminated Gio stream')
    received=[(int(code),bool(int(state))) for code,state in re.findall(r'wl_keyboard(?:#|@)\d+\.key\(\d+, \d+, (\d+), ([01])\)',ui)]
    events=[json.loads(line) for line in (root/'events.jsonl').read_text().splitlines()]
    injected=[(event['stage'],event['keysym'],event['down']) for event in events if 'keysym' in event]
    intended=[(stage,key,down) for stage,key in INPUTS for down in (True,False)]
    require(injected==intended,'exact palette physical input sequence changed')
    native_expected=[(KEYS[key][1],down) for stage,key,down in intended if stage!='background-key']
    require(received==native_expected,'grabbed native keyboard differs from intended private OSdriver keys')
    calls=[f for f in frames if f['category']=='sent_process_key_event']
    require(calls and [(f['keycode'],bool(not(f['state']&(1<<30)))) for f in calls]==received,'actual IBus ProcessKeyEvent differs from grabbed native keys')
    for call in calls:
        replies=[f for f in frames if f['direction']=='RECEIVED' and f['headers'].get('reply-serial')==call['serial']]
        require(len(replies)==1 and replies[0]['type']=='method-return' and replies[0]['signature']=='b','native key typed reply absent')
        require(any(e['direction']=='SENT' and e['member']=='FocusIn' and e['path']==call['path'] and e['frame']<call['frame'] for e in frames),'key context lacked actual FocusIn')
    outgoing=evidence.text_events(ui,'zwp_input_method_context_v1',True)
    incoming=evidence.text_events(gpui,'zwp_text_input_v1',False)
    require(outgoing and [{k:v for k,v in e.items() if k!='object'} for e in outgoing]==[{k:v for k,v in e.items() if k!='object'} for e in incoming],'genuine native preedit/commit differs from application receipt')
    require(any(event['member']=='commit_string' and event['text']=='日本' for event in outgoing),'Japanese native conversion commit absent')
    # Compare actual field pixels at meaningful states, independently of text DTOs.
    from PIL import Image
    field=report['focus_click']['field']
    crops={p['stage']:Image.open(root/p['pixels']['file']).convert('RGB').crop(field).tobytes() for p in report['checkpoints']}
    require(crops['kana-preedit']!=crops['opened'] and crops['conversion']!=crops['kana-preedit'],'preedit/conversion pixels unchanged')
    require(crops['committed']!=crops['opened'],'committed Japanese pixels absent')
    require(crops['cancelled']==crops['reopened'] and crops['fresh-cancelled']==crops['fresh-reopened'],'cancel did not restore actual empty search pixels')
    # The real native cursor moved into the opener after the initial capture.
    # Exclude only its bounded 32px footprint at the retained click hotspot;
    # all other opener/text pixels must remain byte-identical.
    from PIL import ImageChops,ImageDraw
    initial_opener=Image.open(root/'initial.png').convert('RGB').crop(field)
    activated_opener=Image.open(root/'activated.png').convert('RGB').crop(field)
    pointer_x=report['focus_click']['x']-field[0];pointer_y=report['focus_click']['y']-field[1]
    delta=ImageChops.difference(initial_opener,activated_opener)
    ImageDraw.Draw(delta).rectangle((pointer_x-3,pointer_y-3,pointer_x+28,pointer_y+28),fill=(0,0,0))
    require(delta.getbbox() is None,'palette dismissal did not restore opener pixels outside exact cursor footprint')
    by_stage={p['stage']:p for p in report['checkpoints']}
    for stage in ('opened','committed','skip-disabled','scrolled'):
        point=by_stage[stage];value=point['observer'];image=Image.open(root/point['pixels']['file']).convert('RGB')
        left,top,right,bottom=field
        for offset in range(value['visible_count']):
            selected=value['active_index']==value['visible_start']+offset
            expected=(48,74,114) if selected else (30,34,44)
            require(image.getpixel((left+2,top+56+offset*36+2))==expected,'actual option highlight/row pixels differ at '+stage)
    require(report['checkpoints'][-1]['observer']['background_actions']==1 and report['checkpoints'][-1]['observer']['background_releases']==1,'closing press/release leaked to restored background')
    return {'status':'PASS','checkpoints':len(STAGES),'accepted_presentations':len(states),'genuine_native_key_events':len(received),'native_text_events':len(outgoing),'native_diagnostics':diagnostics,'semantic_contract':'PASS','native_accessibility_transport':'UNSUPPORTED','candidate_window_contents_highlight':'UNRUN','opener_cursor_exclusion':{'hotspot':[report['focus_click']['x'],report['focus_click']['y']],'rectangle_relative_to_field':[pointer_x-3,pointer_y-3,pointer_x+28,pointer_y+28]}}
