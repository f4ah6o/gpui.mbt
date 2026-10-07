import importlib.util, pathlib, subprocess, os, sys, json, time
repo=pathlib.Path('/Users/fu2hito/.codex/worktrees/17c6/gpui.mbt')
root=pathlib.Path('/private/tmp/gpui-kotoeri-20261007')
mode=sys.argv[1]
app=pathlib.Path(sys.argv[2]) if len(sys.argv)>2 else root/'baseline-build/macos/GpuiTextField.app'
binary=app/'Contents/MacOS/GpuiTextField'
spec=importlib.util.spec_from_file_location('ime',repo/'infra/macos-desktop/ime-acceptance.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
original=subprocess.Popen
activation=[]
class OwnedPopen(original):
 def __init__(self,args,*a,**kw):
  super().__init__(args,*a,**kw)
  if isinstance(args,list) and args and pathlib.Path(args[0])==binary:
   r=subprocess.run([str(root/'activate_owned_app'),str(self.pid),str(binary)],text=True,capture_output=True,timeout=5)
   activation.append({'exit_code':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
subprocess.Popen=OwnedPopen
os.environ['GPUI_FIELD_MACOS_IME_DISPATCH_TRACE']='1'
output=root/mode
try:
 code=m.main(['--repo',str(repo),'--profile','/private/tmp/gpui-macos-quality-profile','--app',str(app),'--output',str(output),'--timeout','20'] + (['--diagnostic-immediate-preview'] if mode.startswith('A') else []))
finally:
 subprocess.Popen=original
 (root/(mode+'-activation.json')).write_text(json.dumps(activation,indent=2))
 if output.joinpath('summary.json').exists():
  report=json.loads(output.joinpath('summary.json').read_text())
  if mode.startswith('A'):
   report.update(diagnostic_only=True,product_green=False,diagnostic_final_acceptance_pass='final_acceptance' in report)
   output.joinpath('summary.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
 print('RUN_RESULT',mode,code)

sys.exit(code)
