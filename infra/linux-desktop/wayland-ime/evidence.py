"""Fail-closed read-only evidence replay for the private Wayland IME probe."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

QUOTE = r'"(?:[^"\\]|\\.)*"'
KEYS = {'n': (110, 49), 'i': (105, 23), 'h': (104, 35), 'o': (111, 24),
        'space': (32, 57), 'Up': (65362, 103), 'Return': (65293, 28), 'Escape': (65307, 1)}
INTENDED = list('nihonn') + ['space', 'space', 'Up', 'Return'] + list('nihonn') + ['space', 'Escape', 'Escape']
WAYLAND_LINE = re.compile(r'^\[[0-9]+\.[0-9]+\] \{[^{}\r\n]+\} [^\r\n]*\n?$', re.M)
INPUT_FILES = ('ibus-wayland-snapshot.log', 'editor-snapshot.log', 'events.jsonl',
               'gpui-registry.log', 'probe.snapshot.py', 'evidence.snapshot.py',
               'deployment.snapshot.json', 'inherited-wayland-socket.txt')


class EvidenceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def text_events(log, interface, outgoing):
    expression = re.compile(r'^\[[0-9]+\.[0-9]+\] \{[^{}\r\n]+\} ' +
        (r' -> ' if outgoing else '') + re.escape(interface) + r'(?:#|@)(\d+)\.' +
        r'(preedit_string|commit_string)\((\d+), (' + QUOTE + r')(?:, (' + QUOTE + r'))?\)$', re.M)
    records = []
    for match in expression.finditer(log):
        object_id, member, serial, text, commit = match.groups()
        require((member == 'preedit_string') == (commit is not None), 'text event signature mismatch')
        records.append({'object': int(object_id), 'member': member, 'serial': int(serial),
                        'text': json.loads(text), 'commit': json.loads(commit) if commit else None})
    relevant = sum('.preedit_string(' in line or '.commit_string(' in line for line in log.splitlines()
                   if interface in line and (' -> ' in line) == outgoing)
    require(relevant == len(records), 'malformed or unrecognized relevant Wayland text event')
    return records


def strict_dbus_frames(log, parser_path):
    """Demultiplex only whole official Wayland-debug lines; retain an audit.
    The original mixed stdout is unchanged. Unknown/malformed D-Bus framing,
    embedded Wayland fragments and incomplete trailing frames fail closed.
    """
    removed, kept = [], []
    for index, line in enumerate(log.splitlines(keepends=True), 1):
        if WAYLAND_LINE.fullmatch(line):
            removed.append({'line': index, 'sha256': hashlib.sha256(line.encode()).hexdigest()})
        else:
            kept.append(line)
    spec = importlib.util.spec_from_file_location('frozen_gio_diagnostics', parser_path)
    parser = importlib.util.module_from_spec(spec); spec.loader.exec_module(parser)
    return parser.parse_transport_log(''.join(kept)), removed


def native_context_ready(log):
    """Readiness is fresh FocusIn after the actual wayland context request."""
    created = log.rfind("Body: ('wayland',)")
    return created >= 0 and re.search(r"path -> objectpath '/org/freedesktop/IBus/InputContext_\d+'\n"
        r"    interface -> 'org.freedesktop.IBus.InputContext'\n    member -> 'FocusIn'", log[created:]) is not None


def exact_context_focused(frames, path, creation_frame, first_key_frame):
    return any(frame['direction'] == 'SENT' and frame['type'] == 'method-call' and
        frame['interface'] == 'org.freedesktop.IBus.InputContext' and
        frame['member'] == 'FocusIn' and frame['path'] == path and
        creation_frame < frame['frame'] < first_key_frame for frame in frames)


def qualify(root, report, deployment):
    root = Path(root)
    require(report.get('gpui_ime_verified') is False, 'environment evidence cannot claim GPUI IME')
    require(report.get('runtime_bind_verified') is True, 'runtime binding gate did not pass')
    require(report.get('xopen_attempts') == 1, 'not the sole private XOpenDisplay attempt')
    require(report.get('private_display') != report.get('inherited_display_excluded'), 'inherited display reused')
    require(report.get('selected_engine') == 'mozc-jp', 'wrong engine selected')
    hashes = report.get('evidence_inputs', {})
    require(set(hashes) == set(INPUT_FILES), 'complete evidence-input manifest missing')
    for name, expected in hashes.items():
        require(sha(root / name) == expected, 'evidence input changed: ' + name)
    require(json.loads((root / 'deployment.snapshot.json').read_text()) == deployment, 'deployment does not match retained snapshot')
    ui = (root / 'ibus-wayland-snapshot.log').read_text()
    editor = (root / 'editor-snapshot.log').read_text()
    gpui = (root / 'gpui-registry.log').read_text()
    require('"zwp_text_input_manager_v1", 1)' in gpui, 'GPUI did not observe native manager')
    require('"zwp_text_input_manager_v1", 1, new id' not in gpui, 'unmodified GPUI unexpectedly bound manager')
    require('wl_display#1.error(' not in ui + editor + gpui, 'Wayland protocol error')
    for name in ('zwp_input_method_v1', 'zwp_input_panel_v1'):
        require(re.search(r'\.bind\(\d+, "' + name + r'", 1,', ui), 'missing privileged ' + name + ' bind')
    require((root / 'inherited-wayland-socket.txt').read_text().strip().isdigit(), 'privileged inherited socket was not retained')
    require(report['ibus_wayland_process']['exe'] == deployment['prefix'] + '/usr/libexec/ibus-ui-gtk3', 'unexpected owned UI executable')
    require(native_context_ready(ui), 'fresh native context FocusIn absent')
    grabs = re.findall(r'zwp_input_method_context_v1(?:#|@)(\d+)\.grab_keyboard\(new id wl_keyboard(?:#|@)(\d+)\)', ui)
    require(len(grabs) == 1, 'ambiguous native keyboard grab')
    context, keyboard = map(int, grabs[0])
    events = [json.loads(line) for line in (root / 'events.jsonl').read_text().splitlines()]
    injected = [(e['keysym'], e['down']) for e in events if 'keysym' in e]
    expected = [(key, down) for key in INTENDED for down in (True, False)]
    require(injected == expected, 'injected key sequence is not exact')
    received = [(int(code), bool(int(state))) for code, state in re.findall(
        r'wl_keyboard(?:#|@)' + str(keyboard) + r'\.key\(\d+, \d+, (\d+), ([01])\)', ui)]
    require(received == [(KEYS[key][1], down) for key, down in expected], 'native grabbed wl_keyboard delivery mismatch')
    parser_path = Path(deployment['transport_parser'])
    require(sha(parser_path) == deployment['pins'][str(parser_path)], 'changed frozen transport parser')
    frames, removed = strict_dbus_frames(ui, parser_path)
    calls = [frame for frame in frames if frame['category'] == 'sent_process_key_event']
    require([(call['keyval'], call['keycode'], call['state']) for call in calls] ==
        [(KEYS[key][0], KEYS[key][1], 0 if down else 1 << 30) for key, down in expected], 'genuine IBus ProcessKeyEvent sequence mismatch')
    paths = {call['path'] for call in calls}
    require(len(paths) == 1, 'ProcessKeyEvent delivered to ambiguous contexts')
    create_calls = [frame for frame in frames if frame['direction'] == 'SENT' and frame['type'] == 'method-call' and frame['member'] == 'CreateInputContext' and frame['signature'] == 's' and frame['body'] == "('wayland',)"]
    require(len(create_calls) == 1, 'ambiguous native IBus context creation')
    create_replies = [frame for frame in frames if frame['direction'] == 'RECEIVED' and frame['headers'].get('reply-serial') == create_calls[0]['serial'] and frame['signature'] == 'o']
    require(len(create_replies) == 1 and create_replies[0]['type'] == 'method-return', 'native IBus context reply mismatch')
    from gi.repository import GLib
    actual_context = GLib.Variant.parse(GLib.VariantType.new('(o)'), create_replies[0]['body'], None, None).unpack()[0]
    require(actual_context == next(iter(paths)), 'native IBus context object path mismatch')
    ui_bus_name = create_replies[0]['destination']
    require(isinstance(ui_bus_name, str) and re.fullmatch(r':[0-9]+\.[0-9]+', ui_bus_name), 'native IBus reply destination is not a unique name')
    require(exact_context_focused(frames, actual_context, create_replies[0]['frame'], calls[0]['frame']), 'actual native IBus context was not focused before keys')
    for call in calls:
        replies = [frame for frame in frames if frame['headers'].get('reply-serial') == call['serial'] and frame['direction'] == 'RECEIVED' and frame['destination'] == ui_bus_name]
        require(len(replies) == 1 and replies[0]['type'] == 'method-return' and replies[0]['signature'] == 'b', 'ProcessKeyEvent failed or reply missing')
    outgoing = text_events(ui, 'zwp_input_method_context_v1', True)
    incoming = text_events(editor, 'zwp_text_input_v1', False)
    require({event['object'] for event in outgoing} == {context}, 'IME text output from wrong context')
    require(len({event['object'] for event in incoming}) == 1, 'editor text delivered to ambiguous entries')
    require([{k: v for k, v in e.items() if k != 'object'} for e in outgoing] ==
        [{k: v for k, v in e.items() if k != 'object'} for e in incoming], 'compositor text delivery does not match owned IME outputs')
    commits = [event for event in incoming if event['member'] == 'commit_string']
    require(len(commits) == 1 and commits[0]['text'] == '日本', 'commit/cancel produced unexpected final commits')
    position = incoming.index(commits[0])
    before = [e['text'] for e in incoming[:position] if e['member'] == 'preedit_string']
    after = [e['text'] for e in incoming[position+1:] if e['member'] == 'preedit_string']
    require('にほん' in before and before[-1] == '日本', 'kana/conversion before commit missing')
    require(after[-4:] == ['にほん', '日本', 'にほん', ''], 'two-stage Escape cancel sequence mismatch')
    surrounding = re.findall(r'zwp_text_input_v1(?:#|@)\d+\.set_surrounding_text\("([^"\\]*)", (\d+), (\d+)\)', editor)
    require(surrounding and surrounding[-1] == ('日本', '6', '6'), 'final actual editor text/cursor mismatch')
    require(not any(word in editor for word in ('Ignore commit', 'Ignore preedit', 'Invalid previous')), 'stock editor rejected text-input events')
    for checkpoint in report['checkpoints']:
        pixels = checkpoint.get('pixels')
        if pixels:
            require(sha(root / pixels['file']) == pixels['sha256'], 'checkpoint image changed')
    require(report.get('editor_conversion_verified') is True and report.get('editor_cancel_verified') is True, 'live editor gates not complete')
    return {'status': 'matched', 'gpui_ime_verified': False, 'runtime_bind_verified': True,
            'editor_conversion_verified': True, 'editor_cancel_verified': True,
            'matched_injected_events': len(injected), 'matched_grabbed_events': len(received),
            'matched_ibus_key_calls': len(calls), 'matched_v1_text_events': len(incoming),
            'ibus_context_path': next(iter(paths)), 'native_keyboard_object': keyboard,
            'ibus_wayland_bus_name': ui_bus_name,
            'input_method_context_object': context, 'editor_text_input_object': incoming[0]['object'],
            'complete_dbus_frames': len(frames), 'demultiplexed_wayland_lines': len(removed),
            'demultiplex_audit': removed, 'final_text': '日本', 'final_cursor_utf8': 6,
            'candidate_table_verified': False, 'api_sender_pid_verified': False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('run', type=Path)
    parser.add_argument('--deployment', type=Path, default=Path(__file__).with_name('deployment.lock.json'))
    args = parser.parse_args()
    report = json.loads((args.run / 'result.json').read_text())
    require(report['status'] == 'passed' and report['cleanup']['verified'], 'live qualification/cleanup failed')
    result = qualify(args.run, report, json.loads(args.deployment.read_text()))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
