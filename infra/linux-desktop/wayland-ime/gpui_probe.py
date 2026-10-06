#!/usr/bin/python3
"""GPUI opt-in native Wayland IME qualification on the frozen private stack.
Import and --check launch nothing. --run-native uses the approved desktop route.
All input is XTest into a fresh authenticated private Xvfb, never the desktop.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import threading

import probe as frozen_probe
import evidence
import gpui_evidence

HERE = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')


def read_log(path):
    return path.read_text(errors='replace') if path.exists() else ''


def load_module(path, name):
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(path.parent))
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def preflight(deployment, *, current=False):
    data = json.loads(deployment.read_text())
    if data.get('schema_version') != 1 or data.get('kind') != 'gpui-ime-overlay':
        raise RuntimeError('unsupported GPUI deployment overlay')
    base = Path(data['baseline_deployment'])
    if sha(base) != data['baseline_deployment_sha256']:
        raise RuntimeError('changed frozen baseline deployment')
    original, driver, baseline = frozen_probe.preflight(base)
    candidate = data['candidate']
    for name in ('app', 'manifest'):
        if sha(candidate[name]['path']) != candidate[name]['sha256']:
            raise RuntimeError('changed GPUI candidate ' + name)
    manifest = json.loads(Path(candidate['manifest']['path']).read_text())
    binary = manifest['binary']
    if binary['path'] != candidate['app']['path'] or binary['sha256'] != candidate['app']['sha256']:
        raise RuntimeError('GPUI candidate build manifest mismatch')
    if manifest.get('source_consistent') is not True:
        raise RuntimeError('GPUI source snapshot was not consistent during build')
    original = dict(original, gpui_app=candidate['app']['path'],
        gpui_build_manifest=candidate['manifest']['path'], overlay=data)
    original['pins'] = dict(original['pins'], **{v['path']:v['sha256'] for v in candidate.values()})
    if current:
        original['candidate_verification']=verify_current_candidate(candidate['manifest']['path'])
    return original, driver, baseline


def verify_current_candidate(manifest_path):
    # Established exact-build verifier checks current commit/tree, worktree
    # bytes, binary and full captured runtime/font/tool/generated closure.
    verifier=load_module(HERE.parent/'build_manifest.py','gpui_current_build_manifest')
    manifest=verifier.verify_build_manifest(manifest_path)
    if manifest['mode']!='built' or manifest.get('source_consistent') is not True:
        raise RuntimeError('native qualification requires a compiled exact-source candidate')
    return {'source_current_verified':True,'runtime_current_verified':True,
        'build_manifest_sha256':sha(manifest_path),'source':manifest['source'],
        'binary':manifest['binary'],'runtime_file_count':len(manifest['runtime']['files']),
        'runtime_tree_count':len(manifest['runtime']['trees'])}



def gpui_click_from_pixels(png):
    """Locate the actual GPUI viewport color, never infer desktop placement."""
    from PIL import Image
    im = Image.open(png).convert('RGB')
    points = [(x,y) for y in range(im.height) for x in range(im.width)
              if im.getpixel((x,y)) == (24,28,36)]
    if not points:
        raise RuntimeError('GPUI viewport absent from private pixels')
    l,r = min(x for x,y in points), max(x for x,y in points)+1
    t,b = min(y for x,y in points), max(y for x,y in points)+1
    if (r-l,b-t) != (640,240):
        raise RuntimeError('ambiguous GPUI viewport geometry: ' + str((l,t,r,b)))
    return {'x':l+510, 'y':t+50, 'body':[l,t,r,b], 'field':[l+24,t+28,l+536,t+72]}


def input_method_wrapper(prefix, output):
    """Weston must launch this itself, preserving its privileged socket FD."""
    return '\n'.join([
        '#!/bin/sh', 'set -eu', 'test -n "${WAYLAND_SOCKET:-}"',
        'printf "%s\\n" "$$" > ' + shlex.quote(str(output / 'ibus-wayland.pid')),
        'printf "%s\\n" "$WAYLAND_SOCKET" > ' + shlex.quote(str(output / 'inherited-wayland-socket.txt')),
        'unset GTK_IM_MODULE QT_IM_MODULE',
        'export GDK_BACKEND=wayland WAYLAND_DEBUG=client G_DBUS_DEBUG=message IBUS_ENABLE_SYNC_MODE=1',
        'exec ' + shlex.quote(str(prefix / 'usr/libexec/ibus-ui-gtk3')) +
        ' --enable-wayland-im > ' + shlex.quote(str(output / 'ibus-dbus.log')) +
        ' 2> ' + shlex.quote(str(output / 'ibus-wayland.log')), ''])


def weston_config(prefix, wrapper):
    return '\n'.join([
        '[shell]', 'client=' + str(prefix / 'usr/libexec/weston-desktop-shell'),
        'panel-position=none', 'locking=false', 'background-color=0xff202020',
        'animation=none', 'startup-animation=none', 'close-animation=none', 'focus-animation=none',
        'background-image=', '[input-method]', 'path=' + str(wrapper), ''])


def protocol_text(log, member, text):
    return re.search(r'zwp_text_input_v1(?:#|@)\d+\.' + member + r'\(\d+, "' + re.escape(text) + r'"', log) is not None


def surrounding_text(log):
    return re.findall(r'zwp_text_input_v1(?:#|@)\d+\.set_surrounding_text\("([^"\\]*)", (\d+), (\d+)\)', log)


def editor_click_from_pixels(png):
    """Read-only stock editor white-body geometry; fail on ambiguous placement."""
    from PIL import Image
    image = Image.open(png).convert('RGB')
    spans = []
    for y in range(image.height):
        start = None
        for x in range(image.width + 1):
            white = x < image.width and image.getpixel((x, y)) == (255, 255, 255)
            if white and start is None:
                start = x
            elif not white and start is not None:
                if 400 <= x - start <= 550:
                    spans.append((start, x, y))
                start = None
    if not spans:
        raise RuntimeError('stock editor white body not located in captured private pixels')
    left, right = min(s[0] for s in spans), max(s[1] for s in spans)
    top, bottom = min(s[2] for s in spans), max(s[2] for s in spans)
    if not 400 <= right-left <= 550 or not 280 <= bottom-top <= 420:
        raise RuntimeError('ambiguous stock editor pixel geometry')
    return {'x': left + 50, 'y': top + 100, 'body': [left, top, right, bottom]}


def run(args, data, driver, baseline):
    output = args.output.resolve()
    root = Path(data['output_root']).resolve()
    if root not in output.parents or output.exists():
        raise RuntimeError('output must be a new directory within the locked task output root')
    output.mkdir(parents=True, mode=0o700)
    shutil.copyfile(__file__, output / 'probe.snapshot.py')
    shutil.copyfile(HERE / 'gpui_evidence.py', output / 'gpui-evidence.snapshot.py')
    shutil.copyfile(HERE / 'probe.py', output / 'frozen-probe.snapshot.py')
    shutil.copyfile(HERE / 'evidence.py', output / 'frozen-evidence.snapshot.py')
    shutil.copyfile(args.deployment, output / 'deployment.snapshot.json')
    shutil.copyfile(data['gpui_build_manifest'], output / 'gpui-build.snapshot.json')
    write_json(output/'current-candidate-verification.snapshot.json',data['candidate_verification'])
    runtime = Path(tempfile.mkdtemp(prefix='gwi-', dir='/tmp')); runtime.chmod(0o700)
    home, config = runtime / 'home', runtime / 'config'
    for path in (home, config / 'mozc', runtime / 'cache', runtime / 'data', runtime / 'framebuffer', runtime / 'component'):
        path.mkdir(parents=True, mode=0o700)
    prefix, support = Path(data['prefix']), Path(data['support'])
    lib = prefix / 'usr/lib/x86_64-linux-gnu'
    schemas = runtime / 'schemas'; schemas.mkdir(mode=0o700)
    for source in (support / 'config/schemas').glob('*.xml'):
        shutil.copyfile(source, schemas / source.name)
    overrides = '[org.freedesktop.ibus.general]\npreload-engines=[\'mozc-jp\']\nengines-order=[\'mozc-jp\']\nuse-system-keyboard-layout=true\n'
    (schemas / '99-private-mozc.gschema.override').write_text(overrides)
    # Own config compilation only, no schema installation or global settings.
    try:
        subprocess.run([data['schema_compiler'], '--strict', str(schemas)],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
    except Exception as error:
        # No runtime children or sockets exist at this preparation stage.
        shutil.rmtree(runtime)
        write_json(output / 'result.json', {'schema_version': 1, 'status': 'error',
            'stage': 'private-schema-preparation', 'error': str(error),
            'native_executed': False, 'gpui_ime_verified': False,
            'cleanup': {'verified': True, 'survivors': [], 'errors': []}})
        return 1
    (output / '99-private-mozc.gschema.override').write_text(overrides)
    (config / 'mozc/ibus_config.textproto').write_text(baseline.MOZC_CONFIG)
    for original in (support / 'config/ibus/component').glob('*.xml'):
        if original.name != 'mozc.xml':
            (runtime / 'component' / original.name).write_text(original.read_text().replace(str(support / 'prefix'), str(prefix)))
    shutil.copyfile(data['component'], runtime / 'component/mozc.xml')
    fontconfig = runtime / 'fonts.conf'
    fontconfig.write_text('<fontconfig><dir>' + str(support / 'prefix/usr/share/fonts') + '</dir><cachedir>' + str(runtime / 'cache/fontconfig') + '</cachedir></fontconfig>')
    wrapper = runtime / 'ibus-wayland-wrapper.sh'
    wrapper.write_text(input_method_wrapper(prefix, output)); wrapper.chmod(0o700)
    ini = runtime / 'weston.ini'; ini.write_text(weston_config(prefix, wrapper))
    shutil.copyfile(wrapper, output / 'ibus-wayland-wrapper.sh')
    shutil.copyfile(ini, output / 'weston.ini')
    token = secrets.token_hex(24)
    env = {'PATH': str(prefix / 'usr/bin') + ':/usr/bin:/bin', 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
        'HOME': str(home), 'XDG_CONFIG_HOME': str(config), 'XDG_CACHE_HOME': str(runtime / 'cache'),
        'XDG_DATA_HOME': str(runtime / 'data'), 'XDG_RUNTIME_DIR': str(runtime),
        'XDG_DATA_DIRS': str(prefix / 'usr/share') + ':/usr/share',
        'LD_LIBRARY_PATH': str(lib) + ':' + str(lib / 'weston'),
        'GSETTINGS_SCHEMA_DIR': str(schemas), 'GSETTINGS_BACKEND': 'memory',
        'IBUS_COMPONENT_PATH': str(runtime / 'component'), 'IBUS_ADDRESS_FILE': str(runtime / 'ibus-address'),
        'IBUS_TIMEOUT': '3000', 'MOZC_IBUS_CANDIDATE_WINDOW': 'ibus', 'NO_AT_BRIDGE': '1',
        'GI_TYPELIB_PATH': str(support / 'prefix/usr/lib/x86_64-linux-gnu/girepository-1.0'),
        'XKB_CONFIG_ROOT': str(prefix / 'usr/share/X11/xkb'), 'WESTON_DATA_DIR': str(prefix / 'usr/share/weston'),
        'WESTON_MODULE_MAP': 'x11-backend.so=' + str(lib / 'libweston-14/x11-backend.so'),
        'FONTCONFIG_FILE': str(fontconfig), 'GPUI_IME_PROBE_TOKEN': token,
        'XAUTHORITY': str(runtime / 'Xauthority')}
    number = driver.private_display_number(os.environ.get('DISPLAY'))
    driver.auth_file(runtime / 'Xauthority', number, secrets.token_bytes(16)); env['DISPLAY'] = ':' + str(number)
    started = time.monotonic(); deadline = started + args.timeout_seconds
    report = {'schema_version': 1, 'evidence_schema_version':2, 'candidate_verification':data['candidate_verification'], 'status': 'error', 'native_executed': True, 'gpui_ime_verified': False,
        'runtime_bind_verified': False, 'conversion_verified': False, 'cancel_verified': False,
        'history_verified': False, 'blur_refocus_verified': False,
        'private_display': env['DISPLAY'], 'inherited_display_excluded': os.environ.get('DISPLAY'),
        'runtime': str(runtime), 'pins': data['pins'], 'checkpoints': [], 'cleanup': {'verified': False},
        'shortcut_hold_ms':100 if args.held_shortcuts else 0,
        'route': 'XTest -> authenticated private Xvfb -> Weston X11 desktop-shell -> privileged IBus Wayland v1 -> Mozc -> GPUI native text-session ABI3 -> owned experimental field'}
    processes, streams, pressed = [], [], []
    events = (output / 'events.jsonl').open('w')
    x = None

    def left(maximum=5):
        remaining = min(maximum, deadline - time.monotonic())
        if remaining <= 0:
            raise RuntimeError('total qualification timeout exceeded')
        return remaining

    def wait(predicate, label, maximum=5):
        end = time.monotonic() + left(maximum)
        while time.monotonic() < end:
            found = predicate()
            if found:
                return found
            time.sleep(.02)
        raise RuntimeError('timed out: ' + label)

    def launch(command, name, extra=None):
        stream = (output / (name + '.log')).open('wb'); streams.append(stream)
        child = subprocess.Popen(command, env=dict(env, **(extra or {})), stdout=stream, stderr=subprocess.STDOUT, start_new_session=True)
        identity = baseline.stat_identity(child.pid); processes.append((child, identity))
        report.setdefault('children', []).append(dict(identity, argv=command, log=name + '.log'))
        return child

    def stop(child, identity):
        if child.poll() is not None:
            return
        now = baseline.stat_identity(child.pid)
        if (now['starttime'], now['exe']) != (identity['starttime'], identity['exe']):
            raise RuntimeError('owned process identity changed')
        fd = os.pidfd_open(child.pid)
        try:
            signal.pidfd_send_signal(fd, signal.SIGTERM)
            try:
                child.wait(timeout=.5)
            except subprocess.TimeoutExpired:
                signal.pidfd_send_signal(fd, signal.SIGKILL); child.wait(timeout=.5)
        finally:
            os.close(fd)

    def capture(stage):
        shutil.copyfile(runtime / 'framebuffer/Xvfb_screen0', output / (stage + '.xwd'))
        subprocess.run(['/usr/bin/convert', str(output / (stage + '.xwd')), str(output / (stage + '.png'))],
            env=env, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=left(3))
        return {'file': stage + '.png', 'sha256': sha(output / (stage + '.png'))}

    def log_event(value):
        events.write(json.dumps(dict(value, elapsed_ms=(time.monotonic()-started)*1000)) + '\n'); events.flush()

    def key(name, stage):
        if not x.owns_window(window):
            raise RuntimeError('private Weston window lost')
        x.key(name, True); pressed.append(name); log_event({'stage': stage, 'keysym': name, 'down': True})
        x.key(name, False); pressed.remove(name); log_event({'stage': stage, 'keysym': name, 'down': False})
        time.sleep(min(.1, left()))

    def current_gpui():
        if gpui.poll() is not None:
            raise RuntimeError('GPUI candidate exited: ' + read_log(output / 'gpui.log')[-1200:])
        return read_log(output / 'gpui.log')

    def state():
        values = gpui_evidence.presented_states(current_gpui())
        return values[-1] if values else None

    def expect(label, **values):
        found = wait(lambda: (value if value and all(value[k] == v for k,v in values.items()) else None)
            if (value := state()) is not None else None, label)
        if values.get('entered') is True:
            activations = len(re.findall(r'zwp_text_input_v1(?:#|@)\d+\.activate\(', current_gpui()))
            def fresh_native_ready():
                ui = read_log(output / 'ibus-wayland.log')
                active = len(re.findall(r'zwp_input_method_v1(?:#|@)\d+\.activate\(', ui))
                grabs = len(re.findall(r'zwp_input_method_context_v1(?:#|@)\d+\.grab_keyboard\(', ui))
                return active == activations and grabs == activations and evidence.native_context_ready(read_log(output / 'ibus-dbus.log'))
            wait(fresh_native_ready, label + ' latest matching native activation/FocusIn/grab')
        report['checkpoints'].append({'stage':label, 'observer':found, 'pixels':capture(label)})
        return found

    def chord(name, stage, modifiers=('Control_L',)):
        # Same immediate physical chord semantics as the frozen case catalog.
        # Do not silently add a held modifier across owner session recreation.
        for k in (*modifiers,name):
            x.key(k,True); pressed.append(k); log_event({'stage':stage,'keysym':k,'down':True})
        if args.held_shortcuts:
            time.sleep(min(.1,left()))
            log_event({'stage':stage,'type':'modifier-hold','duration_ms':100})
        for k in reversed((*modifiers,name)):
            x.key(k,False); pressed.remove(k); log_event({'stage':stage,'keysym':k,'down':False})
        time.sleep(min(.1,left()))

    def click_field(stage):
        x.motion(click['x'],click['y']); x.button(1,True); x.button(1,False)
        log_event({'stage':stage,'type':'pointer',**click})


    try:
        xvfb = launch([str(prefix / 'usr/bin/Xvfb'), env['DISPLAY'], '-screen', '0', '960x640x24', '-nolisten', 'tcp', '-auth', env['XAUTHORITY'], '-fbdir', str(runtime / 'framebuffer')], 'xvfb')
        def xvfb_ready():
            if xvfb.poll() is not None:
                raise RuntimeError('private Xvfb exited')
            try:
                return int(Path('/tmp/.X' + str(number) + '-lock').read_text().strip()) == xvfb.pid and Path('/tmp/.X11-unix/X' + str(number)).exists() and (runtime / 'framebuffer/Xvfb_screen0').stat().st_size > 0
            except (OSError, ValueError):
                return False
        wait(xvfb_ready, 'owned private Xvfb PID lock/socket/framebuffer'); time.sleep(.25)
        x = driver.PrivateX(); report['xopen_attempts'] = 1
        if not x.connect(env['DISPLAY'], runtime / 'Xauthority'):
            raise RuntimeError('terminal blocker: sole authenticated private XOpenDisplay failed; no retry or alternate route')
        bus_config = runtime / 'session-bus.conf'
        bus_config.write_text('<busconfig><type>session</type><listen>unix:path=' + str(runtime / 'session-bus') + '</listen><auth>EXTERNAL</auth><policy context="default"><allow send_destination="*"/><allow receive_sender="*"/><allow own="*"/></policy></busconfig>')
        launch(['/usr/bin/dbus-daemon', '--nofork', '--config-file=' + str(bus_config)], 'session-bus')
        wait(lambda: (runtime / 'session-bus').exists(), 'private session bus')
        env['DBUS_SESSION_BUS_ADDRESS'] = 'unix:path=' + str(runtime / 'session-bus')
        server = launch([str(prefix / 'usr/lib/mozc/mozc_server')], 'mozc-server')
        wait(lambda: server.poll() is None and (config / 'mozc/.session.ipc').exists() and baseline.ipc_pid((config / 'mozc/.session.ipc').read_bytes()) == server.pid, 'foreground stock Mozc server identity')
        ibus = launch([str(prefix / 'usr/bin/ibus-daemon'), '--cache=none', '--address=unix:path=' + str(runtime / 'ibus-bus'), '--panel=disable', '--config=' + str(prefix / 'usr/libexec/ibus-dconf'), '--emoji-extension=disable', '--timeout=3000', '--verbose'], 'ibus-daemon')
        wait(lambda: (runtime / 'ibus-address').exists(), 'private IBus address')
        address = read_log(runtime / 'ibus-address')
        match = re.search(r'^IBUS_ADDRESS=(.+)$', address, re.M); pid = re.search(r'^IBUS_DAEMON_PID=(\d+)$', address, re.M)
        if not match or not pid or int(pid[1]) != ibus.pid or not match[1].startswith('unix:path=' + str(runtime / 'ibus-bus')):
            raise RuntimeError('private IBus PID/address mismatch')
        env['IBUS_ADDRESS'] = match[1]
        for name in ('DISPLAY', 'XAUTHORITY', 'IBUS_ADDRESS', 'DBUS_SESSION_BUS_ADDRESS', 'WAYLAND_DISPLAY', 'WAYLAND_SOCKET', 'GTK_IM_MODULE', 'QT_IM_MODULE'):
            os.environ.pop(name, None)
        os.environ.update(env)
        import gi
        gi.require_version('IBus', '1.0')
        from gi.repository import Gio, GLib, IBus
        IBus.init()
        cancellation = Gio.Cancellable()
        timer = threading.Timer(left(3), cancellation.cancel); timer.daemon = True; timer.start()
        try:
            conn = Gio.DBusConnection.new_for_address_sync(match[1], Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, cancellation)
        finally:
            timer.cancel()
        conn.call_sync('org.freedesktop.IBus', '/org/freedesktop/IBus', 'org.freedesktop.IBus', 'SetGlobalEngine', GLib.Variant('(s)', ('mozc-jp',)), GLib.VariantType.new('()'), Gio.DBusCallFlags.NONE, int(left()*1000), None)
        description = IBus.Serializable.deserialize_object(conn.call_sync('org.freedesktop.IBus', '/org/freedesktop/IBus', 'org.freedesktop.IBus', 'GetGlobalEngine', None, None, Gio.DBusCallFlags.NONE, int(left()*1000), None).get_child_value(0).get_variant())
        if description.get_name() != 'mozc-jp':
            raise RuntimeError('private global engine selection mismatch')
        report['selected_engine'] = description.get_name(); conn.close_sync(None)
        weston = launch([str(prefix / 'usr/bin/weston'), '--backend=x11', '--renderer=pixman', '--shell=' + str(lib / 'weston/desktop-shell.so'), '--socket=gpui-ime-v1', '--width=960', '--height=640', '--idle-time=0', '--config=' + str(ini), '--log=' + str(output / 'weston.log')], 'weston-stdio')
        def weston_ready():
            if weston.poll() is not None:
                raise RuntimeError('Weston exited')
            found = re.search(r'x11 output .*?window id (\d+)', read_log(output / 'weston.log'))
            value = int(found[1]) if found else None
            return value if value and x.owns_window(value) else None
        window = wait(weston_ready, 'owned Weston X output')
        def ibus_bind_ready():
            log = read_log(output / 'ibus-wayland.log')
            if 'permission' in log.lower() or 'protocol error' in log.lower():
                raise RuntimeError('IBus Wayland permission/protocol error')
            return all(re.search(r'\.bind\(\d+, "' + name + r'", 1,', log) for name in ('zwp_input_method_v1', 'zwp_input_panel_v1'))
        wait(ibus_bind_ready, 'privileged compositor-launched IBus v1 bindings')
        ui_pid = int((output / 'ibus-wayland.pid').read_text().strip())
        ui_identity = baseline.stat_identity(ui_pid)
        if ui_identity['exe'] != str(prefix / 'usr/libexec/ibus-ui-gtk3') or ui_identity['uid'] != os.getuid():
            raise RuntimeError('IBus Wayland exec identity mismatch')
        report['ibus_wayland_process'] = ui_identity
        client_env = {'WAYLAND_DISPLAY': 'gpui-ime-v1', 'XDG_SESSION_TYPE': 'wayland', 'WAYLAND_DEBUG': 'client'}
        client_env.update(GPUI_FIELD_WAYLAND_IME='1', GPUI_FIELD_E2E_STATE='1')
        gpui = launch([data['gpui_app']], 'gpui', client_env)
        initial = expect('initial', committed='Hello 日本', preview='Hello 日本', focused=False,
            composing=False, commits=0, can_undo=False, can_redo=False)
        if initial['selection'] != {'anchor':0,'head':0}:
            raise RuntimeError('unexpected initial selection')
        x.focus(window)
        click = gpui_click_from_pixels(output / 'initial.png'); report['focus_click'] = click
        click_field('focus-field')
        focused = expect('focused', focused=True, entered=True, committed='Hello 日本', composing=False)
        wait(lambda: evidence.native_context_ready(read_log(output / 'ibus-dbus.log')) and
            re.search(r'zwp_input_method_context_v1(?:#|@)\d+\.grab_keyboard\(', read_log(output / 'ibus-wayland.log')),
            'GPUI native IBus FocusIn and keyboard grab')
        report['runtime_bind_verified'] = True
        chord('a','select-all')
        expect('selected', entered=True, focused=True, selection={'anchor':0,'head':8}, committed='Hello 日本', composing=False)
        for name in 'nihonn': key(name,'roman-preedit')
        expect('kana-preedit', committed='Hello 日本', preview='にほん', composing=True,
            marked={'start':0,'end':3}, commits=0)
        for name in ('space','space','Up'): key(name,'conversion')
        expect('conversion', committed='Hello 日本', preview='日本', composing=True, commits=0)
        key('Return','commit')
        committed = expect('committed', committed='日本', preview='日本', composing=False,
            marked=None, selection={'anchor':2,'head':2}, commits=1, can_undo=True, can_redo=False)
        report['conversion_verified'] = True
        chord('z','undo')
        expect('undone', entered=True, focused=True, committed='Hello 日本', preview='Hello 日本', composing=False,
            selection={'anchor':0,'head':8}, commits=1, can_undo=False, can_redo=True)
        chord('z','redo',('Control_L','Shift_L'))
        expect('redone', entered=True, focused=True, committed='日本', preview='日本', composing=False,
            selection={'anchor':2,'head':2}, commits=1, can_undo=True, can_redo=False)
        report['history_verified'] = True
        for name in 'nihonn': key(name,'cancel-preedit')
        expect('cancel-preedit', committed='日本', preview='日本にほん', composing=True, commits=1)
        key('space','cancel-convert')
        expect('cancel-conversion', committed='日本', preview='日本日本', composing=True, commits=1)
        key('Escape','cancel-revert')
        expect('cancel-reverted', committed='日本', preview='日本にほん', composing=True, commits=1)
        key('Escape','cancel-clear')
        expect('cancelled', committed='日本', preview='日本', composing=False, marked=None,
            selection={'anchor':2,'head':2}, commits=1)
        report['cancel_verified'] = True
        for name in 'nihonn': key(name,'blur-preedit')
        before_blur = expect('blur-preedit', committed='日本', preview='日本にほん', composing=True, commits=1)
        x.focus(x.away_window()); log_event({'stage':'blur','type':'focus','target':'private-decoy'})
        expect('blurred', committed='日本', preview='日本', focused=False, composing=False,
            entered=False, epoch=0, commits=1)
        x.focus(window); click_field('refocus-field')
        refocused = expect('refocused', committed='日本', preview='日本', selection={'anchor':2,'head':2}, focused=True,
            composing=False, entered=True, commits=1)
        if refocused['epoch'] <= before_blur['epoch']:
            raise RuntimeError('refocus did not establish a newer session epoch')
        # Fresh typing verifies stale engine composition cannot revive on reactivation.
        key('k','refocus-preedit'); key('a','refocus-preedit')
        expect('refocus-preedit', committed='日本', preview='日本か', composing=True, commits=1)
        key('Escape','refocus-cancel')
        expect('final', committed='日本', preview='日本', composing=False, marked=None,
            focused=True, entered=True, selection={'anchor':2,'head':2}, commits=1)
        report['blur_refocus_verified'] = True
        if 'GPUI_IME_REJECT' in current_gpui():
            raise RuntimeError('GPUI rejected genuine IME output')
        before_audit = baseline.stat_identity(ui_pid)
        if (before_audit['starttime'], before_audit['exe']) != (ui_identity['starttime'], ui_identity['exe']):
            raise RuntimeError('owned IBus Wayland identity changed before audit')
        for name in ('ibus-wayland','ibus-dbus','gpui'):
            shutil.copyfile(output / (name + '.log'), output / (name + '-snapshot.log'))
        report['evidence_inputs'] = {name:sha(output/name) for name in gpui_evidence.INPUT_FILES}
        report['transport_evidence'] = gpui_evidence.qualify(output,report,data)
        write_json(output/'transport-evidence.json',report['transport_evidence'])
        report['gpui_ime_verified'] = True
        report['panel'] = gpui_evidence.panel_evidence(output,report)
        report['full_suite_verified'] = args.held_shortcuts and report['panel']['pixel_show_verified'] and report['panel']['pixel_hide_verified']
        report['status'] = 'passed' if report['full_suite_verified'] else 'qualified-partial'
    except Exception as error:
        report['error'] = str(error)
        # Preserve actual diagnostics before cleanup on failed attempts too.
        for name in ('ibus-wayland','ibus-dbus','gpui'):
            source=output/(name+'.log'); target=output/(name+'-snapshot.log')
            if source.exists() and not target.exists(): shutil.copyfile(source,target)
    finally:
        if x:
            for name in reversed(pressed):
                try: x.key(name, False)
                except Exception: pass
            x.close()
        errors, terminated = [], []
        for child, identity in reversed(processes):
            try: stop(child, identity)
            except ProcessLookupError: pass
            except Exception as error: errors.append(str(error))
        for sig in (signal.SIGTERM, signal.SIGKILL):
            for identity in baseline.private_processes(token, home, config):
                try:
                    fd = os.pidfd_open(identity['pid'])
                    try:
                        now = baseline.stat_identity(identity['pid'])
                        if (now['starttime'], now['exe']) != (identity['starttime'], identity['exe']):
                            raise RuntimeError('private-profile PID identity changed')
                        signal.pidfd_send_signal(fd, sig); terminated.append(dict(identity, signal=int(sig)))
                    finally: os.close(fd)
                except ProcessLookupError: pass
                except Exception as error: errors.append(str(error))
            end = time.monotonic() + .5
            while time.monotonic() < end and baseline.private_processes(token, home, config): time.sleep(.02)
        survivors = baseline.private_processes(token, home, config)
        report['cleanup'] = {'verified': not survivors and not errors, 'survivors': survivors, 'errors': errors, 'private_profile_terminated': terminated, 'pidfd_signals_only': True, 'no_name_based_kill': True}
        if survivors or errors:
            report['status'] = 'error'; report['cleanup_blocker'] = 'runtime retained because owned cleanup was not verified'
        else:
            shutil.rmtree(runtime)
        for stream in streams: stream.close()
        events.close()
        report['elapsed_seconds'] = round(time.monotonic() - started, 3)
        report['probe_sha256'] = sha(__file__)
        write_json(output / 'result.json', report)
    return 0 if report['status'] == 'passed' else (2 if report['status'] == 'qualified-partial' else 1)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true'); mode.add_argument('--run-native', action='store_true')
    parser.add_argument('--deployment', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--held-shortcuts', action='store_true', help='hold Ctrl+A/undo/redo for 100ms; required regression tier')
    parser.add_argument('--timeout-seconds', type=int, default=60, choices=range(30, 91))
    args = parser.parse_args(argv)
    data, driver, baseline = preflight(args.deployment,current=True)
    if args.check:
        print(json.dumps({'pins': data['pins'], 'native_executed': False, 'gpui_ime_verified': False, 'candidate': data['overlay']['candidate'], 'candidate_verification': data['candidate_verification']}, indent=2)); return 0
    if args.output is None:
        parser.error('--run-native needs --output')
    if os.environ.get('LD_LIBRARY_PATH', '').split(':')[0] != str(Path(data['prefix']) / 'usr/lib/x86_64-linux-gnu'):
        parser.error('native Python startup requires the locked prefix library path')
    return run(args, data, driver, baseline)


if __name__ == '__main__':
    raise SystemExit(main())
