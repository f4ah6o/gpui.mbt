"""New recovery-only read helpers. Never launches, signals, or changes settings.

This is newly reviewed source, not recovered historical helper bytes. The small
IPCPathInfo decoder follows the pinned official Mozc ipc/ipc.proto schema and
SavePathName writer. Its strict profile rejects unknown or duplicate fields.
"""
import os
import hashlib
import json
from pathlib import Path
import re
import stat
import time

PROC_ROOT = Path('/proc')
MAX_STAT_BYTES = 4096
MAX_ENV_BYTES = 262144
MAX_IPC_BYTES = 1024
OWNER_KIND = 'gpui-task-owner-birth-v1'
MAX_SCAN_ENTRIES = 4096
MAX_SCAN_SECONDS = 8.0
MOZC_PRODUCT_VERSION = '2.29.5160.102'
MOZC_CONFIG = '''active_on_launch: true
engines {
  name: "mozc-jp"
  longname: "Mozc"
  layout: "default"
  rank: 80
  symbol: "あ"
  composition_mode: HIRAGANA
}
'''


def _bounded_read(path, maximum):
    with path.open('rb') as stream:
        value = stream.read(maximum + 1)
    if len(value) > maximum:
        raise ValueError('oversized process or IPC record')
    return value


def _pid(pid):
    if type(pid) is not int or not 0 < pid < 2**31:
        raise ValueError('invalid Linux PID')
    return pid


def _starttime(raw, pid):
    # comm can contain spaces, newlines, or ')'; fields follow its final ')'.
    end = raw.rfind(b')')
    if not raw.startswith(str(pid).encode('ascii') + b' (') or end < 0:
        raise ValueError('malformed /proc stat identity')
    fields = raw[end + 1:].split()
    if len(fields) < 20 or fields[0] not in (b'R', b'S', b'D', b'Z', b'T', b't', b'X', b'x', b'K', b'W', b'P', b'I'):
        raise ValueError('malformed /proc stat fields')
    if not re.fullmatch(rb'[0-9]+', fields[19]) or int(fields[19]) <= 0:
        raise ValueError('invalid /proc starttime')
    return int(fields[19])


def stat_identity(pid):
    """Read one current-user PID identity and reject races; never signal it."""
    pid = _pid(pid)
    folder = PROC_ROOT / str(pid)
    try:
        owner_uid = folder.stat().st_uid
        if owner_uid != os.geteuid():
            raise PermissionError('process is not owned by the current effective user')
        before = _starttime(_bounded_read(folder / 'stat', MAX_STAT_BYTES), pid)
        executable = os.readlink(folder / 'exe')
        if not os.path.isabs(executable) or executable.endswith(' (deleted)'):
            raise ValueError('unusable process executable identity')
        after = _starttime(_bounded_read(folder / 'stat', MAX_STAT_BYTES), pid)
        executable_after = os.readlink(folder / 'exe')
        if folder.stat().st_uid != owner_uid or owner_uid != os.geteuid():
            raise PermissionError('process ownership changed during read')
        if before != after or executable != executable_after:
            raise RuntimeError('process identity changed during read')
    except FileNotFoundError as error:
        raise ProcessLookupError(pid) from error
    return {'pid': pid, 'uid': owner_uid, 'starttime': before, 'exe': executable}


def capture_task_owner():
    """Capture this fresh native caller before private runtimes/children exist."""
    before=stat_identity(os.getpid());after=stat_identity(os.getpid())
    if before!=after or before['uid']!=os.getuid() or before['uid']!=os.geteuid():
        raise RuntimeError('native task caller identity is not stable/unprivileged')
    return dict(before,schema_version=1,kind=OWNER_KIND)


def verify_task_owner(owner):
    _validate_owner_shape(owner)
    current=stat_identity(os.getpid())
    expected={key:owner[key] for key in ('pid','uid','starttime','exe')}
    if any(type(owner[key]) is not int for key in ('pid','uid','starttime')) or type(owner['exe']) is not str or current!=expected or current['uid']!=os.getuid():
        raise RuntimeError('native task owner is not this stable current caller')
    return current


def _validate_owner_shape(owner):
    if type(owner) is not dict or set(owner)!={'schema_version','kind','pid','uid','starttime','exe'} or type(owner['schema_version']) is not int or owner['schema_version']!=1 or owner['kind']!=OWNER_KIND:
        raise ValueError('invalid native task owner record')
    _pid(owner['pid'])
    if type(owner['uid']) is not int or owner['uid']<0 or type(owner['starttime']) is not int or not 0<owner['starttime']<2**64 or type(owner['exe']) is not str or not os.path.isabs(owner['exe']) or owner['exe'].endswith(' (deleted)'):
        raise ValueError('invalid native task owner identity fields')


def validate_task_owner_receipt(root,report,require_cleanup=True):
    """Read-only recorded provenance validation; never queries a live PID."""
    owner=report.get('task_owner');_validate_owner_shape(owner)
    snapshot=Path(root)/'task-owner.snapshot.json'
    if snapshot.is_symlink() or not snapshot.is_file() or snapshot.stat().st_size>65536:raise ValueError('invalid recorded task owner snapshot')
    raw=snapshot.read_bytes()
    def unique(pairs):
        result={}
        for key,value in pairs:
            if key in result:raise ValueError('duplicate owner snapshot key')
            result[key]=value
        return result
    saved=json.loads(raw,object_pairs_hook=unique,parse_constant=lambda value:(_ for _ in ()).throw(ValueError('nonfinite owner snapshot')))
    _validate_owner_shape(saved)
    if saved!=owner or report.get('evidence_inputs',{}).get(snapshot.name)!=hashlib.sha256(raw).hexdigest():raise ValueError('recorded owner snapshot/report/hash mismatch')
    peers=report.get('peer_ledger')
    if type(peers) is not list or not peers:raise ValueError('zero-peer owner receipt cannot qualify')
    def peer(value):
        if type(value) is not dict or any(type(value.get(key)) is not int for key in ('pid','uid','starttime')) or value['uid']!=owner['uid'] or value['starttime']<owner['starttime'] or not 0<value['starttime']<2**64:
            raise ValueError('peer ledger violates caller UID/birth scope')
        _pid(value['pid'])
        if value['pid']==owner['pid']:raise ValueError('task caller is not its own descendant')
        if type(value.get('exe')) is not str or not os.path.isabs(value['exe']) or value['exe'].endswith(' (deleted)'):raise ValueError('peer executable ledger is malformed')
    for value in peers:
        peer(value)
        if type(value.get('role')) is not str or not value['role']:raise ValueError('peer ledger role missing')
    roles={p['role'] for p in peers}
    if not {'xvfb','session-bus','mozc-server','ibus-daemon','weston-stdio','ibus-unix-peer','ibus-wayland'}<=roles or not roles&{'gpui','editor'}:
        raise ValueError('private roots/bus/UI/app peer ledger is incomplete')
    for child in report.get('children',[]):
        peer(child)
        if not any(all(p.get(k)==child[k] for k in ('pid','uid','starttime','exe')) for p in peers):raise ValueError('owned launched child absent from peer ledger')
    if require_cleanup:
        cleanup=report.get('cleanup',{})
        required={'verified','scan_complete','survivors','errors','scan_audits','ownership_scope','pidfd_signals_only','no_name_based_kill'}
        if type(cleanup) is not dict or not required<=set(cleanup):raise ValueError('required final cleanup fields are missing')
        if type(cleanup['survivors']) is not list or type(cleanup['errors']) is not list or cleanup['survivors']!=[] or cleanup['errors']!=[]:raise ValueError('final cleanup requires typed empty survivors/errors lists')
        if cleanup.get('verified') is not True:raise ValueError('required final task cleanup is not verified')
        if cleanup.get('ownership_scope')!='fresh task descendants bound by owner birth, nonce, HOME and config':raise ValueError('cleanup claim is not explicitly task scoped')
        audits=cleanup.get('scan_audits')
        if type(audits) is not list or not audits:raise ValueError('task-scoped cleanup audit missing')
        for audit in audits:
            if type(audit) is not dict:raise ValueError('scan audit must be an object')
            _validate_owner_shape(audit.get('owner'))
            if type(audit) is not dict or audit.get('kind')!='gpui-fresh-task-birth-census' or type(audit.get('schema_version')) is not int or audit['schema_version']!=1 or audit.get('scope')!=OWNER_KIND or audit.get('owner')!=owner:raise ValueError('scan audit owner/scope mismatch')
            if audit.get('excluded_caller')!={key:owner[key] for key in ('pid','uid','starttime')}:raise ValueError('scan audit caller exclusion missing')
            if audit.get('limits')!={'max_entries':MAX_SCAN_ENTRIES,'max_seconds':MAX_SCAN_SECONDS} or type(audit.get('examined_entries')) is not int or not 0<=audit['examined_entries']<=MAX_SCAN_ENTRIES:raise ValueError('scan audit lacks bounded census')
            if any(type(audit.get(k)) is not list for k in ('excluded_preexisting','excluded_proven_terminal','matched')) or type(audit.get('nonmatching_post_start')) is not int or audit['nonmatching_post_start']<0:raise ValueError('scan census lists/count are missing or untyped')
            for excluded in audit.get('excluded_preexisting',[]):
                if any(type(excluded.get(k)) is not int for k in ('pid','uid','starttime')) or excluded['uid']!=owner['uid'] or not 0<excluded['starttime']<owner['starttime']:raise ValueError('preexisting exclusion is not strictly older')
                _pid(excluded['pid'])
            for terminal in audit.get('excluded_proven_terminal',[]):
                if type(terminal) is not dict or any(type(terminal.get(k)) is not int for k in ('pid','uid','starttime','ppid','pgrp','session','num_threads')):raise ValueError('terminal proof identities/counts must be typed integers')
                _pid(terminal['pid'])
                if terminal['pid']==owner['pid']:raise ValueError('caller cannot be a terminal descendant exclusion')
                status=terminal.get('status',{});tasks=terminal.get('tasks',[])
                if type(status) is not dict or type(tasks) is not list or len(tasks)!=1 or type(tasks[0]) is not dict or any(type(status.get(k)) is not int for k in ('pid','tgid','threads')) or type(status.get('uids')) is not list or len(status['uids'])!=4 or any(type(v) is not int for v in status['uids']) or any(type(tasks[0].get(k)) is not int for k in ('pid','uid','starttime','ppid','pgrp','session','num_threads')):raise ValueError('terminal status/task proof has untyped identity fields')
                if terminal.get('proof')!='stable-Z-exact-single-task' or terminal.get('uid')!=owner['uid'] or type(terminal.get('starttime')) is not int or terminal['starttime']<owner['starttime'] or terminal.get('state')!='Z' or terminal.get('num_threads')!=1 or status.get('threads')!=1 or status.get('pid')!=terminal.get('pid') or status.get('tgid')!=terminal.get('pid') or status.get('state')!='Z' or status.get('uids')!=[owner['uid']]*4 or len(tasks)!=1 or any(tasks[0].get(k)!=terminal.get(k) for k in ('pid','uid','starttime','state','ppid','pgrp','session','num_threads')):raise ValueError('terminal exclusion lacks exact single-task proof')
            for match in audit.get('matched',[]):peer(match)
        if cleanup.get('verified') is True and (cleanup.get('scan_complete') is not True or cleanup.get('pidfd_signals_only') is not True or cleanup.get('no_name_based_kill') is not True or cleanup.get('errors') or cleanup.get('survivors') or any(a.get('scan_complete') is not True or a.get('failure') for a in audits) or audits[-1].get('matched')):
            raise ValueError('incomplete/nonempty cleanup census cannot pass')
    return {'ownership_model':OWNER_KIND,'owner':owner,'recorded_peers':len(peers),'live_pid_verification':False,'cleanup_audit_checked':bool(require_cleanup)}


def require_fresh_peer(pid,owner,expected_exe=None):
    """A private root/IPC/UI peer cannot predate or differ from this caller."""
    caller=verify_task_owner(owner);identity=stat_identity(pid)
    if identity['pid']==caller['pid'] or identity['uid']!=caller['uid'] or identity['starttime']<caller['starttime']:
        raise RuntimeError('private peer predates or is not owned by the task caller')
    if expected_exe is not None and identity['exe']!=os.fspath(expected_exe):
        raise RuntimeError('private peer executable differs')
    return identity


def _process_meta(pid,folder=None):
    pid=_pid(pid);folder=folder or PROC_ROOT/str(pid)
    uid=folder.stat().st_uid
    if uid!=os.geteuid():raise PermissionError('process metadata is not current-user owned')
    raw=_bounded_read(folder/'stat',MAX_STAT_BYTES);start=_starttime(raw,pid)
    fields=raw[raw.rfind(b')')+1:].split()
    if not raw.endswith(b'\n') or len(fields)<50 or any(not re.fullmatch(rb'-?[0-9]+',v) for v in fields[1:]):
        raise ValueError('incomplete full process stat record')
    if any(not re.fullmatch(rb'[0-9]+',fields[n]) or int(fields[n])>=2**31 for n in (1,2,3,17)):
        raise ValueError('invalid process/group/session/thread count')
    if folder.stat().st_uid!=uid:raise RuntimeError('process metadata ownership changed')
    return {'pid':pid,'uid':uid,'starttime':start,'state':fields[0].decode('ascii'),
            'ppid':int(fields[1]),'pgrp':int(fields[2]),'session':int(fields[3]),'num_threads':int(fields[17])}


def _stable_birth(pid):
    first=_process_meta(pid);second=_process_meta(pid)
    keys=('pid','uid','starttime')
    if any(first[k]!=second[k] for k in keys):raise RuntimeError('process birth identity changed during scope check')
    return second


def _terminal_status(folder,pid):
    values={}
    for line in _bounded_read(folder/'status',65536).splitlines():
        key,sep,value=line.partition(b':')
        if sep and key==b'State':
            if key in values:raise ValueError('duplicate process status state')
            words=value.split()
            if not words or words[0]!=b'Z':raise RuntimeError('terminal status state disagrees')
            values[key]='Z'
        elif sep and key in (b'Tgid',b'Pid',b'Threads',b'Uid'):
            if key in values:raise ValueError('duplicate terminal status identity')
            words=value.split()
            if not words or any(not re.fullmatch(rb'[0-9]+',v) for v in words):raise ValueError('invalid terminal status integer')
            values[key]=[int(v) for v in words]
    if set(values)!={b'State',b'Tgid',b'Pid',b'Threads',b'Uid'} or values[b'Tgid']!=[pid] or values[b'Pid']!=[pid] or values[b'Threads']!=[1] or values[b'Uid']!=[os.geteuid()]*4:
        raise RuntimeError('terminal status identity/count is ambiguous')
    return {'state':'Z','pid':pid,'tgid':pid,'threads':1,'uids':values[b'Uid']}


def _single_terminal_proof(pid,initial,checkpoint=lambda:None):
    if initial['state']!='Z' or initial['num_threads']!=1:
        raise RuntimeError('terminal process group is ambiguous, not a single-task zombie')
    folder=PROC_ROOT/str(pid);status=_terminal_status(folder,pid)
    def members():
        ids=[]
        for entry in (folder/'task').iterdir():
            checkpoint()
            if re.fullmatch(r'[1-9][0-9]*',entry.name):
                ids.append(int(entry.name))
                if len(ids)>1:raise RuntimeError('terminal leader still has other tasks')
        if ids!=[pid]:raise RuntimeError('terminal task membership missing or ambiguous')
        return ids
    before_ids=members();task=folder/'task'/str(pid)
    first=_process_meta(pid,task);second=_process_meta(pid,task)
    after=_process_meta(pid);after_status=_terminal_status(folder,pid);after_ids=members()
    if first!=second or first!=initial or after!=initial or after_status!=status or before_ids!=after_ids:
        raise RuntimeError('terminal process identity/state/membership changed')
    return dict(initial,status=status,tasks=[first],proof='stable-Z-exact-single-task')


def _private_directory(path):
    path = Path(path)
    if not path.is_absolute() or path == Path('/') or path.is_symlink():
        raise ValueError('private directory must be an absolute owned directory')
    metadata = path.stat()
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
        raise PermissionError('private directory is not exclusively current-user owned')
    if path.resolve() != path:
        raise ValueError('private directory has an indirect path')
    return path


def _owner_environment(raw):
    if raw and not raw.endswith(b'\0'):
        raise ValueError('truncated process environment')
    wanted = {b'GPUI_IME_PROBE_TOKEN', b'HOME', b'XDG_CONFIG_HOME'}
    values = {}
    for item in raw.split(b'\0'):
        key, separator, value = item.partition(b'=')
        if separator and key in wanted:
            if key in values:
                raise ValueError('duplicate process ownership environment key')
            values[key] = value
    return values


def private_processes(token, home, config, owner, audit=None):
    """Find this fresh caller's nonce/HOME/config descendants; never signal.

    Stable strictly older births are outside this run and excluded before any
    environment read. Same-tick/post-start live unreadable or ambiguous entries
    fail closed. Only corroborated stable single-task Z groups can be skipped.
    """
    caller=verify_task_owner(owner)
    if audit is not None and (type(audit) is not dict or audit):raise ValueError('fresh empty scan audit required')
    census=audit if audit is not None else {}
    census.update(schema_version=1,kind='gpui-fresh-task-birth-census',scope=OWNER_KIND,owner=dict(owner),
        excluded_preexisting=[],excluded_proven_terminal=[],excluded_caller=None,matched=[],nonmatching_post_start=0,scan_complete=False,
        limits={'max_entries':MAX_SCAN_ENTRIES,'max_seconds':MAX_SCAN_SECONDS},examined_entries=0)
    if type(token) is not str or not re.fullmatch(r'[0-9a-f]{48}', token):
        raise ValueError('expected an unpredictable 24-byte lowercase hex marker')
    home, config = _private_directory(home), _private_directory(config)
    if home == config or home.parent != config.parent:
        raise ValueError('private HOME and config must be distinct siblings')
    _private_directory(home.parent)
    expected = {b'GPUI_IME_PROBE_TOKEN': token.encode('ascii'),
                b'HOME': os.fsencode(home), b'XDG_CONFIG_HOME': os.fsencode(config)}
    found = []
    deadline=time.monotonic()+MAX_SCAN_SECONDS
    def checkpoint():
        if time.monotonic()>=deadline:raise TimeoutError('fresh task census deadline exceeded')
    try:
      for folder in PROC_ROOT.iterdir():
        checkpoint()
        if census['examined_entries']>=MAX_SCAN_ENTRIES:raise RuntimeError('fresh task census entry cap exceeded')
        census['examined_entries']+=1
        if not re.fullmatch(r'[1-9][0-9]*', folder.name):continue
        try:
            if folder.stat().st_uid != os.geteuid():
                continue
            pid=int(folder.name);birth=_stable_birth(pid)
            if pid==caller['pid']:
                if any(birth[key]!=caller[key] for key in ('pid','uid','starttime')):raise RuntimeError('caller birth changed during own exclusion')
                census['excluded_caller']={key:birth[key] for key in ('pid','uid','starttime')};continue
            if birth['starttime']<caller['starttime']:
                census['excluded_preexisting'].append({key:birth[key] for key in ('pid','uid','starttime')});continue
            if birth['state'] in ('Z','X','x'):
                try:
                    proof=_single_terminal_proof(pid,birth,checkpoint)
                except (FileNotFoundError,ProcessLookupError) as error:
                    raise RuntimeError('terminal corroboration missing; group state remains unknown') from error
                census['excluded_proven_terminal'].append(proof);continue
            environment = _owner_environment(_bounded_read(folder / 'environ', MAX_ENV_BYTES))
            if environment != expected:
                repeated=_owner_environment(_bounded_read(folder/'environ',MAX_ENV_BYTES))
                after_birth=_stable_birth(pid)
                if repeated!=environment or any(after_birth[key]!=birth[key] for key in ('pid','uid','starttime')) or after_birth['state'] in ('Z','X','x'):
                    raise RuntimeError('nonmatching in-scope process changed during ownership read')
                census['nonmatching_post_start']+=1
                continue
            before = require_fresh_peer(pid,owner)
            repeated = _owner_environment(_bounded_read(folder / 'environ', MAX_ENV_BYTES))
            after = stat_identity(int(folder.name))
            if before != after or repeated != expected:
                raise RuntimeError('private process identity or ownership changed during scan')
            if any(before[key]!=birth[key] for key in ('pid','uid','starttime')):
                raise RuntimeError('private process birth changed after scope check')
            found.append(before)
        except (FileNotFoundError, ProcessLookupError) as error:
            try: folder.stat()
            except FileNotFoundError: continue
            raise RuntimeError('process metadata unavailable while numeric PID still exists') from error
      verify_task_owner(owner)
      checkpoint()
      if census['excluded_caller'] is None:raise RuntimeError('current caller absent from process census')
    except Exception as error:
        census['failure']={'type':type(error).__name__,'detail':str(error)[:1024]}
        raise
    census['matched']=sorted(found,key=lambda item:item['pid']);census['scan_complete']=True
    return sorted(found, key=lambda item: item['pid'])


def _varint(data, offset):
    begin, value = offset, 0
    for index in range(5):
        if offset >= len(data):
            raise ValueError('truncated uint32 protobuf varint')
        byte = data[offset]
        offset += 1
        if index == 4 and byte > 0x0f:
            raise ValueError('overflowing uint32 protobuf varint')
        value |= (byte & 0x7f) << (7 * index)
        if not byte & 0x80:
            if offset - begin > 1 and byte == 0:
                raise ValueError('noncanonical uint32 protobuf varint')
            return value, offset
    raise ValueError('unterminated uint32 protobuf varint')


def ipc_pid(data):
    """Decode the pinned Linux Mozc IPCPathInfo record and return its PID.

    Official schema: fields 1/key and 5/product_version are strings; fields
    2/process_id, 3/thread_id and 4/protocol_version are uint32. SavePathName
    explicitly writes all five. No heuristic byte search or PID identity fake.
    """
    if type(data) is not bytes or not 0 < len(data) <= MAX_IPC_BYTES:
        raise ValueError('invalid bounded IPCPathInfo bytes')
    offset, fields = 0, {}
    while offset < len(data):
        tag, offset = _varint(data, offset)
        number, wire = tag >> 3, tag & 7
        if number not in (1, 2, 3, 4, 5) or number in fields:
            raise ValueError('unknown or duplicate IPCPathInfo field')
        if number in (1, 5):
            if wire != 2:
                raise ValueError('wrong IPCPathInfo string wire type')
            length, offset = _varint(data, offset)
            if offset + length > len(data):
                raise ValueError('truncated IPCPathInfo string')
            try:
                fields[number] = data[offset:offset + length].decode('utf-8', errors='strict')
            except UnicodeDecodeError as error:
                raise ValueError('invalid UTF-8 IPCPathInfo string') from error
            offset += length
        else:
            if wire != 0:
                raise ValueError('wrong IPCPathInfo uint32 wire type')
            fields[number], offset = _varint(data, offset)
    if set(fields) != {1, 2, 3, 4, 5}:
        raise ValueError('incomplete pinned IPCPathInfo writer record')
    if not re.fullmatch(r'[0-9a-f]{32}', fields[1]):
        raise ValueError('invalid official Mozc IPC key')
    if fields[3] != 0 or fields[4] != 3:
        raise ValueError('unexpected Linux thread ID or Mozc IPC protocol')
    if fields[5] != MOZC_PRODUCT_VERSION:
        raise ValueError('unexpected pinned Mozc product version')
    return _pid(fields[2])
