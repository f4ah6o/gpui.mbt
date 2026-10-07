#!/usr/bin/env python3
from pathlib import Path
import datetime,json,os,subprocess,sys
repo=Path('/Users/fu2hito/.codex/worktrees/pr40-script-e2e/gpui.mbt')
root=Path(__file__).resolve().parent
expected='c7e6cae99ffd218320d0377a53ea3cd5218421b4'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()==expected
assert not subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True).strip()
argv=[sys.executable,str(repo/'infra/macos-desktop/actrun-feedback.py'),'--root','/private/tmp/gpui-macos-quality-profile','--mode','native','--run-dir',str(root/'native')]
record={'source_HEAD':expected,'worktree':str(repo),'branch':'test/20261007-pr40-script-e2e','argv':argv,'driver_pid':os.getpid(),'started_at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'status':'running','computer_use':False,'subagents':False}
(root/'driver.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps({'run_dir':str(root),'command':argv}),flush=True)
with (root/'runner.log').open('xb') as output:
 child=subprocess.Popen(argv,cwd=repo,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
 record['runner_pid']=child.pid
 (root/'driver.json').write_text(json.dumps(record,indent=2)+'\n')
 code=child.wait()
record.update(status='finished',exit_code=code,runner_reaped=True,finished_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),source_HEAD_after=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),worktree_clean=not subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True).strip())
(root/'driver.json').write_text(json.dumps(record,indent=2)+'\n')
print(json.dumps(record),flush=True)
sys.exit(code)
