#!/usr/bin/env python3
from pathlib import Path
import datetime,hashlib,json,os,plistlib,subprocess,sys
repo=Path('/Users/fu2hito/.codex/worktrees/pr40-script-e2e/gpui.mbt')
root=Path(__file__).resolve().parent
app=root/'native/checks/text-field/build/macos/GpuiTextField.app'
binary=app/'Contents/MacOS'/plistlib.loads((app/'Contents/Info.plist').read_bytes())['CFBundleExecutable']
assert not (root/'ime-trace').exists()
assert not subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True).strip()
argv=[sys.executable,str(repo/'infra/macos-desktop/ime-acceptance.py'),'--repo',str(repo),'--profile','/private/tmp/gpui-macos-quality-profile','--app',str(app),'--output',str(root/'ime-trace')]
env=dict(os.environ)
env['GPUI_FIELD_MACOS_IME_DISPATCH_TRACE']='1'
env.pop('GPUI_FIELD_MACOS_IME_STYLE_TRACE',None)
record={'argv':argv,'diagnostic_opt_in':'GPUI_FIELD_MACOS_IME_DISPATCH_TRACE=1','started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'computer_use':False,'subagents':False,'binary_sha256':hashlib.sha256(binary.read_bytes()).hexdigest()}
with (root/'ime-trace-runner.log').open('xb') as log:
 child=subprocess.Popen(argv,cwd=repo,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 record['runner_pid']=child.pid
 (root/'ime-trace-driver.json').write_text(json.dumps(record,indent=2)+'\n')
 code=child.wait()
record.update(exit_code=code,runner_reaped=True,finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
(root/'ime-trace-driver.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record),flush=True)
sys.exit(code)
