#!/usr/bin/python3
"""Prepare a new task-owned launcher; never execute, install or publish it."""
import argparse
import json
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import probe


def desktop_quote(value):
    value = str(value).replace('%', '%%')
    for character in ('\\', '"', '`', '$'):
        value = value.replace(character, '\\' + character)
    # Desktop Entry string escapes are decoded before Exec argument quoting.
    value = value.replace('\\', '\\\\')
    return '"' + value + '"'


def prepare(deployment, run_name, bind_only=False):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}', run_name):
        raise RuntimeError('choose a simple new run name')
    data, _, _ = probe.preflight(deployment)
    root = Path(data['output_root']); output = root / 'runs' / run_name
    launcher = root / (run_name + '.desktop')
    if output.exists() or launcher.exists():
        raise RuntimeError('refusing to reuse a launcher or existing native output')
    lib = Path(data['prefix']) / 'usr/lib/x86_64-linux-gnu'
    typelibs = Path(data['support']) / 'prefix/usr/lib/x86_64-linux-gnu/girepository-1.0'
    command = ['/usr/bin/env', 'LD_LIBRARY_PATH=' + str(lib) + ':' + str(lib / 'weston'),
        'GI_TYPELIB_PATH=' + str(typelibs), '/usr/bin/python3', str(HERE / 'probe.py'),
        '--run-native', '--deployment', str(deployment.resolve()), '--output', str(output), '--timeout-seconds', '60']
    if bind_only:
        command.append('--bind-only')
    text = '\n'.join(['[Desktop Entry]', 'Version=1.0', 'Type=Application',
        'Name=Verify private Wayland IME runtime', 'Comment=Bounded private Wayland environment qualification',
        'Exec=' + ' '.join(map(desktop_quote, command)), 'Terminal=false', 'StartupNotify=false', ''])
    root.mkdir(parents=True, exist_ok=True)
    with launcher.open('x') as stream:
        stream.write(text)
    launcher.chmod(0o755)
    return launcher, output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deployment', type=Path, default=HERE / 'deployment.lock.json')
    parser.add_argument('--run-name', required=True)
    parser.add_argument('--bind-only', action='store_true')
    args = parser.parse_args()
    launcher, output = prepare(args.deployment, args.run_name, args.bind_only)
    print(json.dumps({'prepared_launcher': str(launcher), 'new_output': str(output), 'native_executed': False}, indent=2))


if __name__ == '__main__':
    main()
