#!/usr/bin/env python3
"""Run the unchanged repository IME E2E with bounded owned-PID activation."""
from pathlib import Path
import datetime
import hashlib
import importlib.util
import json
import os
import plistlib
import subprocess
import sys

repo = Path('/Users/fu2hito/.codex/worktrees/pr40-script-e2e/gpui.mbt')
root = Path(__file__).resolve().parent
app = root / 'native/checks/text-field/build/macos/GpuiTextField.app'
binary = app / 'Contents/MacOS' / plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleExecutable']
expected = 'c7e6cae99ffd218320d0377a53ea3cd5218421b4'
assert subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip() == expected
assert not subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True).strip()
assert not (root / 'ime-activated').exists()
original_popen = subprocess.Popen
activation_records = []

class OwnedAppPopen(original_popen):
    def __init__(self, args, *positional, **kwargs):
        super().__init__(args, *positional, **kwargs)
        if isinstance(args, list) and args and Path(args[0]) == binary:
            helper_args = [str(root / 'activate_owned_app'), str(self.pid), str(binary)]
            with original_popen(helper_args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as helper:
                output, errors = helper.communicate(timeout=5)
                activation_records.append({'helper_exit_code': helper.returncode,
                                           'record': json.loads(output) if output.strip() else None,
                                           'stderr': errors})
            (root / 'activation.json').write_text(json.dumps(activation_records, indent=2) + '\n')

spec = importlib.util.spec_from_file_location('ime_e2e', repo / 'infra/macos-desktop/ime-acceptance.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
os.environ['GPUI_FIELD_MACOS_IME_DISPATCH_TRACE'] = '1'
os.environ.pop('GPUI_FIELD_MACOS_IME_STYLE_TRACE', None)
argv = ['--repo', str(repo), '--profile', '/private/tmp/gpui-macos-quality-profile',
        '--app', str(app), '--output', str(root / 'ime-activated')]
record = {'started_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
          'source_HEAD': expected, 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
          'repository_entrypoint': str(module.__file__), 'entrypoint_arguments': argv,
          'computer_use': False, 'subagents': False,
          'change_scope': 'launch activation only; repository driver, input sequence and predicates unchanged'}
subprocess.Popen = OwnedAppPopen
try:
    code = module.main(argv)
finally:
    subprocess.Popen = original_popen
record.update(exit_code=code, activation_records=activation_records,
              finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
(root / 'ime-activated-driver.json').write_text(json.dumps(record, indent=2) + '\n')
print(json.dumps(record), flush=True)
sys.exit(code)
