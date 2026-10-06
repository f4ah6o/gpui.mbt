#!/usr/bin/python3
"""Prepare an isolated GPUI native launcher. Preparation never launches services/input."""
import argparse
import importlib.util
import json
import os
import tempfile
from pathlib import Path
import re
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import gpui_probe
spec=importlib.util.spec_from_file_location('frozen_prepare',HERE/'prepare-launcher.py')
frozen=importlib.util.module_from_spec(spec);spec.loader.exec_module(frozen)


def prepare(deployment,run_name,held_shortcuts=False,palette=False):
    if not re.fullmatch(r'[a-z][a-z0-9-]{0,63}',run_name): raise RuntimeError('choose a new simple run name')
    data,_,_=gpui_probe.preflight(deployment,current=True)
    root=Path(data['output_root']); output=root/'runs'/run_name; launcher=root/(run_name+'.desktop')
    if output.exists() or launcher.exists(): raise RuntimeError('refusing existing run/launcher')
    lib=Path(data['prefix'])/'usr/lib/x86_64-linux-gnu'
    typelibs=Path(data['support'])/'prefix/usr/lib/x86_64-linux-gnu/girepository-1.0'
    command=['/usr/bin/env','PYTHONDONTWRITEBYTECODE=1','LD_LIBRARY_PATH='+str(lib)+':'+str(lib/'weston'),
        'GI_TYPELIB_PATH='+str(typelibs),'/usr/bin/python3',str(HERE/'gpui_probe.py'),
        '--run-native','--deployment',str(deployment.resolve()),'--output',str(output),'--timeout-seconds','60']
    if held_shortcuts: command.append('--held-shortcuts')
    if palette: command.append('--palette')
    if data.get('kind') == 'native-ime-recovery-baseline':
        diagnostic=root/(run_name+'.launcher.log')
        if diagnostic.exists() or diagnostic.is_symlink(): raise RuntimeError('refusing existing diagnostic log')
        command.extend(['--diagnostic-log',str(diagnostic)])
    contents='\n'.join(['[Desktop Entry]','Version=1.0','Type=Application',
        'Name=Verify GPUI Japanese IME ('+run_name+')','Comment=Private OSdriver GPUI-only IME acceptance',
        'Exec='+' '.join(map(frozen.desktop_quote,command)),'Terminal=false','StartupNotify=false',''])
    # Publish complete bytes atomically: File Manager must never cache a
    # just-created zero-byte .desktop entry. link remains no-clobber.
    with tempfile.NamedTemporaryFile(mode='w',dir=root,prefix='.launcher-',delete=False) as stream:
        temporary=Path(stream.name);stream.write(contents);stream.flush();os.fsync(stream.fileno())
    try:
        temporary.chmod(0o755);os.link(temporary,launcher)
    finally:
        temporary.unlink(missing_ok=True)
    return launcher,output


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--deployment',type=Path,required=True);p.add_argument('--run-name',required=True)
    p.add_argument('--held-shortcuts',action='store_true');p.add_argument('--palette',action='store_true')
    a=p.parse_args();l,o=prepare(a.deployment,a.run_name,a.held_shortcuts,a.palette)
    print(json.dumps({'prepared_launcher':str(l),'new_output':str(o),'native_executed':False},indent=2))

if __name__=='__main__': main()
