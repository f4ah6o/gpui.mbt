#!/usr/bin/env python3
"""Bounded OS-input E2E: private authenticated Xvfb -> Weston -> GPUI.
No connection or input is sent to an existing display. No GPUI callbacks are invoked.
"""
import argparse, ctypes as C, hashlib, json, os, pathlib, re, secrets, select, shutil, struct, subprocess, sys, tempfile, time
from PIL import Image

P=pathlib.Path
ap=argparse.ArgumentParser()
ap.add_argument('--prefix',type=P,required=True)
ap.add_argument('--repo',type=P,required=True)
ap.add_argument('--baseline',type=P,required=True)
ap.add_argument('--fixed',type=P,required=True)
ap.add_argument('--output',type=P,required=True)
ap.add_argument('--baseline-sha256',required=True)
ap.add_argument('--fixed-sha256',required=True)
ap.add_argument('--fixed-patch',type=P,required=True)
ap.add_argument('--golden',type=P,required=True)
ap.add_argument('--fontconfig',type=P,help='fixture config override; default is repo/tests/linux_text/fonts.conf')
ap.add_argument('--fixed-repo',type=P,help='candidate source checkout; defaults to --repo')
ap.add_argument('--golden-provenance',default='Explicitly supplied reviewed synthetic field golden; see fixture provenance')
a=ap.parse_args()
a.fontconfig=a.fontconfig or a.repo/'tests/linux_text/fonts.conf'
a.fixed_repo=a.fixed_repo or a.repo
whole_run_start=time.monotonic_ns()/1e6
for path in (a.prefix,a.repo,a.fixed_repo,a.baseline,a.fixed,a.fixed_patch,a.golden,a.fontconfig):
 if not path.exists():raise SystemExit('Missing input: '+str(path))
for binary,expected in [(a.baseline,a.baseline_sha256),(a.fixed,a.fixed_sha256)]:
 if hashlib.sha256(binary.read_bytes()).hexdigest()!=expected:raise SystemExit('Refusing changed binary: '+str(binary))
if a.output.exists() and any(a.output.iterdir()):raise SystemExit('Refusing nonempty artifact directory; preserve prior evidence and choose a fresh output')
a.output.mkdir(parents=True,exist_ok=True)
(a.output/'execution-inventory.json').write_text(json.dumps({'uid':os.geteuid(),'dpkg_status_exists':P('/var/lib/dpkg/status').is_file(),'tools':{name:shutil.which(name) for name in ['apt-get','dpkg','sudo']},'observed_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime())},indent=2)+'\n')

def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def stamp():return time.monotonic_ns()/1e6

def auth_file(path,number,cookie):
 # Server imports the cookie independently of this display-name metadata.
 # The client record is rewritten with the allocated display before connecting.
 fields=(b'',str(number).encode(),b'MIT-MAGIC-COOKIE-1',cookie)
 path.write_bytes(struct.pack('>H',65535)+b''.join(struct.pack('>H',len(x))+x for x in fields))
 path.chmod(0o600)

def wait_for(predicate,timeout,label):
 start=stamp()
 while stamp()-start<timeout*1000:
  value=predicate()
  if value:return value
  time.sleep(.01)
 raise RuntimeError('Timed out: '+label)

xlib=C.CDLL('libX11.so.6');xtest=C.CDLL('libXtst.so.6')
xlib.XOpenDisplay.argtypes=[C.c_char_p];xlib.XOpenDisplay.restype=C.c_void_p
xlib.XCloseDisplay.argtypes=[C.c_void_p]
xlib.XDefaultRootWindow.argtypes=[C.c_void_p];xlib.XDefaultRootWindow.restype=C.c_ulong
xlib.XQueryTree.argtypes=[C.c_void_p,C.c_ulong,C.POINTER(C.c_ulong),C.POINTER(C.c_ulong),C.POINTER(C.POINTER(C.c_ulong)),C.POINTER(C.c_uint)]
xlib.XFetchName.argtypes=[C.c_void_p,C.c_ulong,C.POINTER(C.c_char_p)]
xlib.XFree.argtypes=[C.c_void_p]
xlib.XStringToKeysym.argtypes=[C.c_char_p];xlib.XStringToKeysym.restype=C.c_ulong
xlib.XKeysymToKeycode.argtypes=[C.c_void_p,C.c_ulong];xlib.XKeysymToKeycode.restype=C.c_ubyte
xlib.XSetInputFocus.argtypes=[C.c_void_p,C.c_ulong,C.c_int,C.c_ulong]
xlib.XRaiseWindow.argtypes=[C.c_void_p,C.c_ulong]
xlib.XSync.argtypes=[C.c_void_p,C.c_int]
xtest.XTestFakeKeyEvent.argtypes=[C.c_void_p,C.c_uint,C.c_int,C.c_ulong]
xtest.XTestFakeButtonEvent.argtypes=[C.c_void_p,C.c_uint,C.c_int,C.c_ulong]
xtest.XTestFakeMotionEvent.argtypes=[C.c_void_p,C.c_int,C.c_int,C.c_int,C.c_ulong]

def window_named(display,needle,logged_window=None):
 root=xlib.XDefaultRootWindow(display);r=C.c_ulong();parent=C.c_ulong();children=C.POINTER(C.c_ulong)();n=C.c_uint()
 if not xlib.XQueryTree(display,root,C.byref(r),C.byref(parent),C.byref(children),C.byref(n)):return None
 result=None
 try:
  for i in range(n.value):
   if logged_window is not None and int(children[i])==logged_window:
    result=logged_window;break
   name=C.c_char_p()
   if xlib.XFetchName(display,children[i],C.byref(name)) and name.value:
    title=name.value.decode(errors='replace');xlib.XFree(name)
    if needle in title:result=int(children[i]);break
 finally:
  if children:xlib.XFree(children)
 return result

def capture(fb,out):
 shutil.copyfile(fb,out.with_suffix('.xwd'))
 subprocess.run(['convert',str(out.with_suffix('.xwd')),str(out)],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
 return digest(out)

def text_oracle(image):
 crop=image.with_name(image.stem+'-field.png')
 with Image.open(image) as im:im.crop((25,29,490,70)).resize((1860,164)).save(crop)
 r=subprocess.run(['tesseract',str(crop),'stdout','--psm','7','-l','eng'],text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 return {'ocr_text':r.stdout.strip(),'ocr_status':r.returncode,'suffix_abD':r.stdout.strip().endswith('abD'),'ocr_ascii_coverage':'Hello prefix and abD suffix only; Japanese prefix needs retained-pixel review'}

def read_log(p):return p.read_text(errors='replace') if p.exists() else ''

def source_metadata(repo):
 return {'head':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),
         'tree':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD^{tree}'],text=True).strip(),
         'status':subprocess.check_output(['git','-C',str(repo),'status','--porcelain'],text=True).strip(),
         'tracked_diff_sha256':hashlib.sha256(subprocess.check_output(['git','-C',str(repo),'diff','HEAD','--'])).hexdigest()}

def run(label,binary,mode='six_keys'):
 out=a.output/label;out.mkdir(exist_ok=False)
 runtime_directory=tempfile.TemporaryDirectory(prefix='gpe-',dir='/tmp')
 runtime=P(runtime_directory.name);runtime.chmod(0o700);fbdir=out/'framebuffer';fbdir.mkdir()
 report={'label':label,'mode':mode,'input_route':'XTest -> private Xvfb -> Weston X11 wl_keyboard -> GPUI','binary_sha256':digest(binary),'started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),'status':'error','initial_text':'Hello 日本','initial_text_evidence':'accepted example literal; actual focused screenshot retained','expected_final_text':'Hello 日本abD','additional_setup_keys':[],'fixed_patch_sha256':hashlib.sha256(a.fixed_patch.read_bytes()).hexdigest(),'source_head':subprocess.check_output(['git','-C',str(a.repo),'rev-parse','HEAD'],text=True).strip(),'source_tree':subprocess.check_output(['git','-C',str(a.repo),'rev-parse','HEAD^{tree}'],text=True).strip()}
 report['baseline_source']=source_metadata(a.repo)
 report['candidate_source']=source_metadata(a.fixed_repo)
 env=os.environ.copy();env['LD_LIBRARY_PATH']=str(a.prefix/'usr/lib/x86_64-linux-gnu')+':'+str(a.prefix/'usr/lib/x86_64-linux-gnu/weston')+(':'+env['LD_LIBRARY_PATH'] if env.get('LD_LIBRARY_PATH') else '')
 env['PATH']=str(a.prefix/'usr/bin')+':'+env.get('PATH','');env['XDG_RUNTIME_DIR']=str(runtime);env['XAUTHORITY']=str(runtime/'Xauthority')
 env['WESTON_MODULE_MAP']=';'.join(n+'='+str(a.prefix/'usr/lib/x86_64-linux-gnu/libweston-14'/n) for n in ['x11-backend.so','gl-renderer.so'])
 env['LIBGL_ALWAYS_SOFTWARE']='1';env['FONTCONFIG_FILE']=str(a.fontconfig);env['FONTCONFIG_PATH']=str(a.fontconfig.parent);env['XDG_CACHE_HOME']=str(out/'cache');env.pop('WAYLAND_DISPLAY',None);env.pop('WAYLAND_SOCKET',None)
 cookie=secrets.token_bytes(16);auth_file(runtime/'Xauthority',0,cookie)
 processes=[];files=[];display=None;start=stamp()
 def launch(cmd,log,e=env,pass_fds=()):
  f=open(log,'wb');files.append(f);p=subprocess.Popen(cmd,env=e,stdout=f,stderr=subprocess.STDOUT,pass_fds=pass_fds);processes.append(p);return p
 def key(name,down):
  code=xlib.XKeysymToKeycode(display,xlib.XStringToKeysym(name.encode()))
  if not code:raise RuntimeError('Keysym unavailable: '+name)
  if not xtest.XTestFakeKeyEvent(display,code,int(down),0):raise RuntimeError('XTest key failed')
  xlib.XSync(display,False)
 try:
  if len(os.fsencode(runtime/'gpui-e2e'))>=108:raise RuntimeError('Wayland socket pathname exceeds AF_UNIX limit')
  inherited_display=env.get('DISPLAY','')
  # Never let automatic allocation select the desktop's usual :0 display.
  number=str(1000+secrets.randbelow(10000))
  inherited_number=re.search(r':(\d+)(?:\.\d+)?$',inherited_display)
  if inherited_number and number==inherited_number.group(1):raise RuntimeError('Refusing inherited display')
  if P('/tmp/.X'+number+'-lock').exists() or P('/tmp/.X11-unix/X'+number).exists():raise RuntimeError('Private display number already in use')
  auth_file(runtime/'Xauthority',number,cookie)
  xvfb=launch([str(a.prefix/'usr/bin/Xvfb'),':'+number,'-screen','0','960x480x24','-nolisten','tcp','-auth',env['XAUTHORITY'],'-fbdir',str(fbdir)],out/'xvfb.log')
  env['DISPLAY']=':'+number;os.environ['XAUTHORITY']=env['XAUTHORITY']
  report['private_display']=env['DISPLAY'];report['inherited_display_excluded']=inherited_display
  def connect_private_display():
   if xvfb.poll() is not None:raise RuntimeError('Owned Xvfb exited before connection; see xvfb.log')
   return xlib.XOpenDisplay(env['DISPLAY'].encode())
  display=wait_for(connect_private_display,10,'private authenticated X display')
  report['xvfb_ready_ms']=stamp()-start
  weston=launch([str(a.prefix/'usr/bin/weston'),'--backend=x11','--renderer=pixman','--shell='+str(a.prefix/'usr/lib/x86_64-linux-gnu/weston/kiosk-shell.so'),'--socket=gpui-e2e','--width=960','--height=480','--idle-time=0','--no-config','--log='+str(out/'weston.log')],out/'weston-stdio.log')
  def discover_window():
   if weston.poll() is not None:raise RuntimeError('Owned Weston exited before window discovery; see weston.log')
   match=re.search(r'x11 output .*?window id (\d+)',read_log(out/'weston.log'))
   return window_named(display,'Weston Compositor',int(match.group(1)) if match else None)
  window=wait_for(discover_window,10,'private Weston window')
  report['window_discovery']='actual Weston output ID verified against private X root tree'
  app_env=env.copy();app_env.update(WAYLAND_DISPLAY='gpui-e2e',XDG_SESSION_TYPE='wayland',WAYLAND_DEBUG='client',XKB_LOG_LEVEL='debug')
  app=launch([str(binary)],out/'app.log',app_env)
  wait_for(lambda:'.frame(' in read_log(out/'app.log') and '.done(' in read_log(out/'app.log')[read_log(out/'app.log').rfind('.frame('):] or app.poll() is not None,10,'GPUI first frame')
  if app.poll() is not None:raise RuntimeError('GPUI exited before first frame')
  launch_done=stamp();report['launch_to_frame_ms']=launch_done-start
  xlib.XRaiseWindow(display,window);xlib.XSetInputFocus(display,window,2,0)
  xtest.XTestFakeMotionEvent(display,0,500,50,0);xtest.XTestFakeButtonEvent(display,1,1,0);xtest.XTestFakeButtonEvent(display,1,0,0);xlib.XSync(display,False)
  wait_for(lambda:'wl_pointer' in read_log(out/'app.log') and '.button(' in read_log(out/'app.log'),2,'compositor pointer focus')
  focus_done=stamp();report['focus_ms']=focus_done-launch_done
  report['initial_png_sha256']=capture(fbdir/'Xvfb_screen0',out/'focused.png')
  input_start=stamp()
  for name in (['a'] if mode=='isolate_modifier' else ['a','b','c']):
   key(name,True);key(name,False)
  if mode=='isolate_modifier':
   time.sleep(.08);report['before_modifier_alive']=app.poll() is None;capture(fbdir/'Xvfb_screen0',out/'before-modifier.png')
   key('Shift_L',True);key('Shift_L',False)
  else:
   key('Shift_L',True);key('d',True);key('d',False);key('Shift_L',False)
   key('Left',True);key('Left',False);key('BackSpace',True);key('BackSpace',False)
  input_done=stamp();report['input_sequence_ms']=input_done-input_start
  # Wait for the events and any resulting frame, bounded and identical across binaries.
  time.sleep(.2)
  report['final_png_sha256']=capture(fbdir/'Xvfb_screen0',out/'final.png');report.update(text_oracle(out/'final.png'))
  report['app_alive']=app.poll() is None;report['app_returncode']=app.poll();report['native_failure']='next_event: native_failure' in read_log(out/'app.log')
  report['wayland_key_events']=len(re.findall(r'wl_keyboard(?:#|@)\d+\.key\(',read_log(out/'app.log'))) # raw event log retained for precise review
  report['post_input_oracle_ms']=stamp()-input_done;report['launch_focus_input_oracle_ms']=stamp()-start
  if label.startswith('fixed'):
   with Image.open(out/'final.png') as actual, Image.open(a.golden) as expected:
    actual=actual.convert('RGBA');expected=expected.convert('RGBA')
    report['golden_pixel_match']=actual.size==expected.size and actual.tobytes()==expected.tobytes()
    report['golden_pixel_sha256']=hashlib.sha256(expected.tobytes()).hexdigest()
    report['actual_pixel_sha256']=hashlib.sha256(actual.tobytes()).hexdigest()
    report['golden_provenance']=a.golden_provenance
  report['fontconfig_sha256']=digest(a.fontconfig)
  report['status']='passed' if report['app_alive'] and report.get('suffix_abD') and report.get('ocr_text','').startswith('Hello ') and report['wayland_key_events']==14 and report.get('golden_pixel_match',False) else 'failed'
  report['expected_baseline_failure_reproduced']=label.startswith('baseline') and not report['app_alive'] and report['native_failure']
 except Exception as exc:
  report['error']=repr(exc);report['launch_focus_input_oracle_ms']=stamp()-start
 finally:
  if display:xlib.XCloseDisplay(display)
  for proc in reversed(processes):
   if proc.poll() is None:
    proc.terminate()
    try:proc.wait(timeout=2)
    except subprocess.TimeoutExpired:proc.kill();proc.wait(timeout=2)
  for f in files:f.close()
  # The ephemeral Xauthority contains only this run's local display cookie.
  (runtime/'Xauthority').unlink(missing_ok=True)
  runtime_directory.cleanup()
  report['including_cleanup_ms']=stamp()-start
  (out/'result.json').write_text(json.dumps(report,indent=2)+'\n')
  print(json.dumps(report),flush=True)
 return report

results=[]
for label,binary,mode in [('baseline-isolation',a.baseline,'isolate_modifier'),('baseline-six-keys',a.baseline,'six_keys'),('fixed-six-keys',a.fixed,'six_keys')]:
 results.append(run(label,binary,mode))
(a.output/'summary.json').write_text(json.dumps({'baseline_sha256':digest(a.baseline),'fixed_sha256':digest(a.fixed),'results':results,'whole_runner_ms':stamp()-whole_run_start},indent=2)+'\n')
sys.exit(0 if results[-1]['status']=='passed' else 1)
