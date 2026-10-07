#!/usr/bin/env python3
"""Validate this failure archive, never promote it to Product Green."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[3]
spec = importlib.util.spec_from_file_location('ime_acceptance', REPO / 'infra/macos-desktop/ime-acceptance.py')
a = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a)

def rows(path, prefix):
    return [json.loads(line[len(prefix):]) for line in path.read_text().splitlines() if line.startswith(prefix)]

def one(values):
    assert len(values) == 1, 'expected exactly one record'
    return values[0]

for name, expected in json.loads((ROOT / 'files-sha256.json').read_text()).items():
    path = ROOT / name
    assert not path.is_symlink() and path.is_file() and path.resolve().is_relative_to(ROOT)
    assert hashlib.sha256(path.read_bytes()).hexdigest() == expected, name
reports = {}
for name in ('experiment-a', 'normal'):
    directory = ROOT / name
    report = json.loads((directory / 'summary.json').read_text())
    reports[name] = report
    assert report['status'] == 'failed' and report['ok'] is False
    assert report['source_before'] == report['source_after'] and report['source_stable'] is True
    assert report['source_before']['commit'] == '8a7cf7c30a4e51862484818200f2fb3dcf8e57ce'
    log = directory / 'app.stdout.log'
    timeout = one([r for r in rows(log, 'GPUI_MACOS_IME_DIAGNOSTIC_TRACE ') if r['phase'] == 'operation_timeout'])
    assert timeout['key_code'] == 36 and timeout['dispatch_id'] == 9 and timeout['loop_iterations'] == 200
    assert timeout['commit_callbacks'] == 0 and timeout['composing'] is True
    assert timeout['pending_batch'] is False and timeout['pending_owner_sync'] is False and timeout['pending_ack_sequence'] is None
    assert timeout['last_accepted_batch_sequence'] == 11
    for key in ('down_posted', 'up_posted', 'down_dispatched', 'up_dispatched'):
        assert timeout['current_dispatch_receipt'][key] is True
    timing = rows(log, 'GPUI_MACOS_IME_TIMING ')
    assert 3 <= len(timing) <= 64
    snapshot = one([r for r in timing if r['phase'] == 'window_state_snapshot'])
    assert snapshot['native_event_pumps'] == snapshot['appkit_event_pumps'] == 200
    assert snapshot['elapsed_ms'] > 0 and snapshot['return_down_elapsed_ms'] > 0 and snapshot['return_up_elapsed_ms'] > 0
    assert not any(r['phase'] in ('insert_text', 'unmark_text') for r in timing)
    abort = one(rows(log, 'GPUI_MACOS_IME_ABORTED '))
    a.validate_abort_receipt(abort, 1, 1)
    assert report['cleanup']['acknowledged'] is True and report['cleanup']['receipt'] == abort
    assert isinstance(report['cleanup']['exit_code'], int)
    try:
        a.validate_summary(directory / 'summary.json')
    except a.AcceptanceError as error:
        assert 'completed pass' in str(error)
    else:
        raise AssertionError('failed run qualified as Product Green')
    source, binary = report['source_before'], report['app']['binary_sha256']
    a.validate_state(report['initial_state'], source, binary, initial=True)
    a.validate_checkpoint(report['initial_checkpoint'], 'initial-ready', source, binary)
    a.validate_checkpoint(report['composition_checkpoint'], 'composition-ready', source, binary)
    for capture in report['screenshots'].values():
        pixels = a.png_pixels(directory / capture['path'])
        assert pixels['file_sha256'] == capture['file_sha256']
        assert pixels['pixel_sha256'] == capture['pixel_sha256']
    assert report['diagnostic_only'] is (name == 'experiment-a')
    assert set(report['screenshots']) == ({'initial'} if name == 'experiment-a' else {'initial', 'composition'})
assert reports['experiment-a']['app'] == reports['normal']['app']
assert reports['experiment-a']['source_before'] == reports['normal']['source_before']
normal = reports['normal']
frames = {name: {'image': a.png_pixels(ROOT / 'normal' / capture['path']), 'roi': capture['text_roi']}
          for name, capture in normal['screenshots'].items()}
a.require_text_change(a.text_roi_difference(frames['initial'], frames['composition']), 'initial_to_composition')
control = one([json.loads(line) for line in (ROOT / 'B-final.log').read_text().splitlines() if line.startswith('{')])
for key in ('prefix_valid', 'expected_text', 'marked', 'down_delivered', 'up_delivered', 'source_restored', 'window_closed'):
    assert control[key] is True, key
assert control['passed'] is False and control['return_iterations'] == 200
assert control['insert_delta'] == control['unmark_delta'] == 0
one([r for r in rows(ROOT / 'B-final.log', 'GPUI_MACOS_IME_TIMING ') if r['phase'] == 'observation_end'])
print('PASS: archive hashes, A/B failure contracts, partial pixels, restoration/closure; Product Green rejected')
