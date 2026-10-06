"""New strict read-only Gio diagnostic parser, not recovered historical bytes.

API: parse_transport_log(str) -> list[dict]. Only complete G_DBUS_DEBUG=message
frames on their dedicated stdout channel are admitted. No bus connection,
process launch, input, signal, repair, or warning filtering occurs here.
"""
import re

SEPARATOR = '=' * 72
MAX_LOG_BYTES = 16 * 1024 * 1024
MAX_MESSAGE_BYTES = 8 * 1024 * 1024
MAX_BODY_BYTES = 1024 * 1024
MAX_MESSAGES = 8192
MAX_VARIANT_NODES = 65536
MAX_VARIANT_DEPTH = 64
INPUT_CONTEXT = 'org.freedesktop.IBus.InputContext'
SIGNALS = {'CommitText': 'v', 'UpdatePreeditText': 'vub',
           'UpdatePreeditTextWithMode': 'vubu'}
HEADER_TYPES = {'path': 'o', 'interface': 's', 'member': 's',
                'error-name': 's', 'reply-serial': 'u', 'destination': 's',
                'sender': 's', 'signature': 'g', 'num-unix-fds': 'u'}
FLAGS = ('no-reply-expected', 'no-auto-start', 'allow-interactive-authorization')


class DiagnosticsError(ValueError):
    pass


def _gi():
    # Lazy import keeps importing this module read-only and GI-independent.
    import gi
    gi.require_version('GLib', '2.0')
    gi.require_version('Gio', '2.0')
    from gi.repository import GLib, Gio
    return GLib, Gio


def _uint(value, name, positive=False):
    if type(value) is not int or not (int(positive) <= value <= 0xffffffff):
        raise DiagnosticsError('invalid ' + name)
    return value


def _text_bytes(value, limit, name):
    if not isinstance(value, str) or '\x00' in value:
        raise DiagnosticsError('invalid ' + name)
    try:
        size = len(value.encode('utf-8'))
    except UnicodeError as error:
        raise DiagnosticsError('invalid UTF-8 ' + name) from error
    if size > limit:
        raise DiagnosticsError('oversized ' + name)
    return size


def _variant(text, expected_type):
    _text_bytes(text, MAX_BODY_BYTES, 'variant text')
    GLib, _ = _gi()
    try:
        # Null endptr is intentional: trailing input is rejected by GLib.
        # First infer the formatter's actual annotations. In GLib2.84.4 a
        # supplied expected type can coerce explicit int32/uint64 annotations;
        # never let that make wrong typed wire diagnostics look correct.
        inferred = GLib.Variant.parse(None, text, None, None)
        if inferred.get_type_string() != expected_type:
            raise DiagnosticsError('actual variant type disagrees with header')
        value = GLib.Variant.parse(GLib.VariantType.new(expected_type), text,
                                   None, None)
    except (GLib.Error, ValueError, TypeError) as error:
        raise DiagnosticsError('invalid typed variant') from error
    if value.get_type_string() != expected_type:
        raise DiagnosticsError('typed variant mismatch')
    stack, nodes = [(value, 0)], 0
    while stack:
        node, depth = stack.pop()
        nodes += 1
        if nodes > MAX_VARIANT_NODES or depth > MAX_VARIANT_DEPTH:
            raise DiagnosticsError('variant resource limit')
        if node.get_type_string() == 'h':
            raise DiagnosticsError('file-descriptor handles unsupported in this profile')
        count = node.n_children() if node.is_container() else 0
        if nodes + len(stack) + count > MAX_VARIANT_NODES:
            raise DiagnosticsError('variant resource limit')
        if node.get_type_string().startswith('a{'):
            keys = set()
            for i in range(node.n_children()):
                key = node.get_child_value(i).get_child_value(0).print_(True)
                if key in keys:
                    raise DiagnosticsError('duplicate nested dictionary key')
                keys.add(key)
        if node.is_container():
            stack.extend((node.get_child_value(i), depth + 1) for i in range(count))
    return value


def _header_value(text, name):
    if name not in HEADER_TYPES:
        raise DiagnosticsError('unsupported header ' + name)
    value = _variant(text, HEADER_TYPES[name]).unpack()
    GLib, Gio = _gi()
    if name == 'path' and not GLib.Variant.is_object_path(value):
        raise DiagnosticsError('invalid object path')
    if name in ('interface', 'error-name') and not Gio.dbus_is_interface_name(value):
        raise DiagnosticsError('invalid interface/error name')
    if name == 'member' and not Gio.dbus_is_member_name(value):
        raise DiagnosticsError('invalid member name')
    if name in ('sender', 'destination') and not Gio.dbus_is_name(value):
        raise DiagnosticsError('invalid bus name')
    if name == 'reply-serial':
        _uint(value, 'reply serial', positive=True)
    if name == 'num-unix-fds':
        if _uint(value, 'file-descriptor count') != 0:
            raise DiagnosticsError('file descriptors unsupported in this profile')
    if name == 'signature':
        if len(value.encode('ascii', errors='replace')) > 255 or not GLib.Variant.is_signature(value):
            raise DiagnosticsError('invalid signature')
    return value


def _validate_headers(kind, headers):
    required = {'method-call': {'path', 'member'},
                'signal': {'path', 'interface', 'member'},
                'method-return': {'reply-serial'},
                'error': {'reply-serial', 'error-name'}}[kind]
    if not required <= headers.keys():
        raise DiagnosticsError('required message header missing')
    # Reject incompatible shapes instead of treating injected headers as extras.
    if kind in ('method-call', 'signal') and ('reply-serial' in headers or 'error-name' in headers):
        raise DiagnosticsError('incompatible reply header')
    if kind in ('method-return', 'error') and any(k in headers for k in ('path', 'interface', 'member')):
        raise DiagnosticsError('incompatible call/signal header')
    if kind != 'error' and 'error-name' in headers:
        raise DiagnosticsError('incompatible error header')


def _decode_relevant(record, body):
    interface, member = record['interface'], record['member']
    if interface != INPUT_CONTEXT:
        return
    if member == 'ProcessKeyEvent':
        if record['type'] != 'method-call' or record['direction'] != 'SENT' or record['signature'] != 'uuu':
            raise DiagnosticsError('unexpected ProcessKeyEvent type/direction/signature')
        keyval, keycode, state = body.unpack()
        record.update(keyval=_uint(keyval, 'keyval'), keycode=_uint(keycode, 'keycode'),
                      state=_uint(state, 'key state'), category='sent_process_key_event')
    elif member in SIGNALS:
        if record['type'] != 'signal' or record['direction'] != 'RECEIVED' or record['signature'] != SIGNALS[member]:
            raise DiagnosticsError('unexpected InputContext signal type/direction/signature')
        text = body.get_child_value(0).get_variant()
        if text.get_type_string() != '(sa{sv}sv)' or text.get_child_value(0).get_string() != 'IBusText':
            raise DiagnosticsError('signal does not contain serialized IBusText')
        record['text'] = text.get_child_value(2).get_string()
        if member != 'CommitText':
            record['cursor'] = _uint(body.get_child_value(1).get_uint32(), 'preedit cursor')
            record['visible'] = body.get_child_value(2).get_boolean()
        if member == 'UpdatePreeditTextWithMode':
            record['mode'] = _uint(body.get_child_value(3).get_uint32(), 'preedit mode')
        record['category'] = 'received_inputcontext_signal'


def _parse_frame(chunk, index):
    # Split LF only: valid Unicode string contents are not framing delimiters.
    lines = chunk.split('\n')
    while lines and lines[-1] == '':
        lines.pop()
    if len(lines) < 11 or lines[0] != 'GDBus-debug:Message:':
        raise DiagnosticsError('incomplete message frame')
    marker = re.fullmatch(r'  (>>>> SENT|<<<< RECEIVED) D-Bus message \(([1-9][0-9]{0,7}) bytes\)', lines[1])
    if not marker or int(marker[2]) > MAX_MESSAGE_BYTES:
        raise DiagnosticsError('invalid direction/frame size marker')
    patterns = (('type', r'  Type:    (method-call|method-return|error|signal)'),
                ('flags', r'  Flags:   (.+)'), ('version', r'  Version: ([0-9]+)'),
                ('serial', r'  Serial:  ([1-9][0-9]{0,9})'))
    fields = {}
    for line, (name, pattern) in zip(lines[2:6], patterns):
        match = re.fullmatch(pattern, line)
        if not match:
            raise DiagnosticsError('invalid ' + name + ' field')
        fields[name] = match[1]
    if fields['version'] != '0' or lines[6] != '  Headers:':
        raise DiagnosticsError('unsupported version/headers format')
    if fields['flags'] != 'none':
        bits = fields['flags'].split(',')
        if len(set(bits)) != len(bits) or any(v not in FLAGS for v in bits) or bits != [v for v in FLAGS if v in bits]:
            raise DiagnosticsError('unsupported/noncanonical message flags')
    serial = _uint(int(fields['serial']), 'message serial', positive=True)
    headers, i = {}, 7
    while i < len(lines) and lines[i].startswith('    '):
        if lines[i] == '    (none)':
            if headers:
                raise DiagnosticsError('mixed empty/nonempty headers')
            i += 1
            if i < len(lines) and lines[i].startswith('    '):
                raise DiagnosticsError('headers after empty marker')
            break
        match = re.fullmatch(r'    ([a-z][a-z-]*) -> (.+)', lines[i])
        if not match or match[1] in headers:
            raise DiagnosticsError('invalid or duplicate header')
        headers[match[1]] = _header_value(match[2], match[1])
        i += 1
    _validate_headers(fields['type'], headers)
    if i >= len(lines) or not lines[i].startswith('  Body: '):
        raise DiagnosticsError('missing body')
    raw_body = lines[i][8:]
    signature = headers.get('signature', '')
    if raw_body == '(none)':
        if signature:
            raise DiagnosticsError('nonempty signature with no body')
        body, canonical_body = None, None
    else:
        body = _variant(raw_body, '(' + signature + ')')
        canonical_body = body.print_(False)
    i += 1
    if lines[i:] != ['  UNIX File Descriptors:', '    (none)']:
        raise DiagnosticsError('incomplete/interleaved/trailing file-descriptor frame')
    record = dict(fields, version=0, serial=serial, frame=index,
                  direction=marker[1].split()[1], byte_count=int(marker[2]),
                  headers=headers, signature=signature, body=canonical_body,
                  file_descriptors=['(none)'], category='other')
    for key in ('path', 'interface', 'member', 'sender', 'destination'):
        record[key] = headers.get(key)
    _decode_relevant(record, body)
    return record


def parse_transport_log(text):
    """Parse all complete typed frames; malformed/unframed data fails closed.

    Empty/whitespace input returns []; qualification must enforce its own
    nonzero exact expected message/event sequence. No incomplete tail is trimmed.
    """
    _text_bytes(text, MAX_LOG_BYTES, 'log text')
    if '\r' in text:
        raise DiagnosticsError('unexpected non-LF framing')
    if text.strip() and not text.endswith('\n'):
        raise DiagnosticsError('incomplete final LF')
    chunks = text.split(SEPARATOR + '\n')
    if chunks[0].strip():
        raise DiagnosticsError('unframed diagnostic data')
    if len(chunks) == 1:
        return []
    records = []
    for chunk in chunks[1:]:
        if not chunk.startswith('GDBus-debug:Message:'):
            raise DiagnosticsError('missing/interleaved debug frame')
        if len(records) >= MAX_MESSAGES:
            raise DiagnosticsError('too many message frames')
        records.append(_parse_frame(chunk, len(records) + 1))
    return records
