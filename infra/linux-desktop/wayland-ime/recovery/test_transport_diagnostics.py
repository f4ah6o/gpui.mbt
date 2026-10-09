"""Static typed-Gio/adversarial fixtures: no bus, service or input is launched."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch
from gi.repository import GLib, Gio
import transport_diagnostics as p


def message(member='ProcessKeyEvent', interface=p.INPUT_CONTEXT, signature='uuu',
            args=(110,49,0), serial=4):
    m=Gio.DBusMessage.new_method_call(':1.0','/org/freedesktop/IBus/InputContext_2',interface,member)
    m.set_serial(serial);m.set_flags(Gio.DBusMessageFlags.NO_AUTO_START)
    if signature is not None:m.set_body(GLib.Variant('('+signature+')',args))
    return m


def frame(m, direction='SENT'):
    marker='>>>>' if direction=='SENT' else '<<<<'
    return p.SEPARATOR+'\nGDBus-debug:Message:\n  '+marker+' '+direction+' D-Bus message ('+str(len(m.to_blob(Gio.DBusCapabilityFlags.NONE)))+' bytes)\n'+m.print_(2)


def signal(name='CommitText', text='日本', cursor=2, visible=True, mode=1, marker='IBusText'):
    m=Gio.DBusMessage.new_signal('/org/freedesktop/IBus/InputContext_2',p.INPUT_CONTEXT,name)
    m.set_serial(6)
    attributes=GLib.Variant('(sa{sv}av)',('IBusAttrList',{},[]))
    ibus=GLib.Variant('(sa{sv}sv)',(marker,{},text,attributes))
    signatures={'CommitText':('v',(ibus,)), 'UpdatePreeditText':('vub',(ibus,cursor,visible)),
                'UpdatePreeditTextWithMode':('vubu',(ibus,cursor,visible,mode))}
    sig,args=signatures[name];m.set_body(GLib.Variant('('+sig+')',args))
    return m


class ParserTests(unittest.TestCase):
    def test_import_has_no_native_launch_or_gi_requirement(self):
        with patch('subprocess.Popen',side_effect=AssertionError('launch')),patch('subprocess.run',side_effect=AssertionError('launch')):
            spec=importlib.util.spec_from_file_location('parser_import_check',Path(p.__file__))
            spec.loader.exec_module(importlib.util.module_from_spec(spec))

    def test_real_gio_key_frame(self):
        v=p.parse_transport_log(frame(message()))[0]
        self.assertEqual((v['keyval'],v['keycode'],v['state']),(110,49,0))
        self.assertEqual(v['category'],'sent_process_key_event')
        self.assertEqual(v['direction'],'SENT');self.assertEqual(v['frame'],1)
        self.assertEqual(v['headers']['destination'],':1.0')

    def test_real_gio_boolean_reply(self):
        call=message();reply=call.new_method_reply();reply.set_serial(5)
        reply.set_sender(':1.0');reply.set_destination(':1.1');reply.set_body(GLib.Variant('(b)',(False,)))
        v=p.parse_transport_log(frame(reply,'RECEIVED'))[0]
        self.assertEqual(v['type'],'method-return');self.assertEqual(v['headers']['reply-serial'],4)
        self.assertEqual(GLib.Variant.parse(GLib.VariantType.new('(b)'),v['body'],None,None).unpack(),(False,))

    def test_real_gio_context_reply_and_focus(self):
        call=message('CreateInputContext','org.freedesktop.IBus','s',('wayland',))
        reply=call.new_method_reply();reply.set_serial(5);reply.set_body(GLib.Variant('(o)',('/org/freedesktop/IBus/InputContext_2',)))
        focus=message('FocusIn',signature=None,serial=6)
        v=p.parse_transport_log(frame(call)+frame(reply,'RECEIVED')+frame(focus))
        self.assertEqual([x['frame'] for x in v],[1,2,3]);self.assertEqual(v[2]['body'],'()')
        self.assertEqual(v[1]['signature'],'o')

    def test_real_gio_error(self):
        call=message();m=call.new_method_error_literal('org.freedesktop.DBus.Error.Failed','failure')
        m.set_serial(7);v=p.parse_transport_log(frame(m,'RECEIVED'))[0]
        self.assertEqual(v['type'],'error');self.assertEqual(v['headers']['reply-serial'],4)

    def test_real_ibus_commit_signal(self):
        v=p.parse_transport_log(frame(signal(),'RECEIVED'))[0]
        self.assertEqual(v['text'],'日本');self.assertEqual(v['category'],'received_inputcontext_signal')

    def test_real_ibus_preedit_and_mode_signals(self):
        for name in ('UpdatePreeditText','UpdatePreeditTextWithMode'):
            v=p.parse_transport_log(frame(signal(name,text='にほん',cursor=3),'RECEIVED'))[0]
            self.assertEqual((v['text'],v['cursor'],v['visible']),('にほん',3,True))
            if name.endswith('WithMode'):self.assertEqual(v['mode'],1)

    def test_uint32_boundaries_and_real_release_state(self):
        for values in ((0,0,1<<30),(0xffffffff,0xffffffff,0xffffffff)):
            v=p.parse_transport_log(frame(message(args=values)))[0]
            self.assertEqual((v['keyval'],v['keycode'],v['state']),values)
        for bad in (-1,0x100000000,True,1.0):
            with self.assertRaises(p.DiagnosticsError):p._uint(bad,'test')

    def test_typed_header_body_and_trailing_variant_injection(self):
        good=frame(message())
        for bad in [good.replace("signature 'uuu'","signature 's'"),good.replace('uint32 110','uint64 110'),
                    good.replace('uint32 49','int32 49'),good.replace('uint32 0)','uint32 0) garbage'),
                    good.replace('uint32 110','uint32 4294967296'),good.replace("signature 'uuu'","signature 'a'"),
                    good.replace("signature 'uuu'","signature '*'"),good.replace('  Body: (uint32 110, uint32 49, uint32 0)','  Body: (none)')]:
            with self.subTest(bad=bad),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_invalid_semantic_header_values(self):
        good=frame(message())
        for old,new in [("objectpath '/org/freedesktop/IBus/InputContext_2'","objectpath 'not/a/path'"),
                        ("'org.freedesktop.IBus.InputContext'","'bad interface'"),
                        ("'ProcessKeyEvent'","'bad.member'"),("':1.0'","'not-a-bus-name'")]:
            with self.subTest(new=new),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good.replace(old,new))

    def test_duplicate_header_and_empty_mixing(self):
        good=frame(message());line="    member -> 'ProcessKeyEvent'\n"
        for bad in [good.replace(line,line+line),good.replace(line,"    (none)\n"+line),
                    good.replace('  Headers:\n','  Headers:\n    (none)\n')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_duplicate_nested_variant_dictionary_keys(self):
        m=message('Other',signature='v',args=(GLib.Variant('a{sv}',{'unique':GLib.Variant('s','ok')}),))
        good=frame(m)
        duplicate=good.replace("'unique': <'ok'>","'unique': <'ok'>, 'unique': <'evil'>")
        self.assertIn("'unique': <'evil'>",duplicate)
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(duplicate)
        # Different spellings of the same typed string key remain duplicates.
        duplicate=good.replace("'unique': <'ok'>","'unique': <'ok'>, '\\u0075nique': <'evil'>")
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(duplicate)

    def test_nested_distinct_dictionary_keys_and_quoted_lookalikes(self):
        m=message('Other',signature='v',args=(GLib.Variant('a{sv}',{
            'a':GLib.Variant('s','GDBus-debug:Message: ProcessKeyEvent'),
            'b':GLib.Variant('s','日本\u2028kana')}),))
        v=p.parse_transport_log(frame(m))[0];self.assertEqual(v['category'],'other')
        self.assertIn('日本',v['body'])

    def test_actual_lookalike_member_interface_is_not_a_key(self):
        for iface,name in ((p.INPUT_CONTEXT+'Extra','ProcessKeyEvent'),(p.INPUT_CONTEXT,'ProcessKeyEventExtra')):
            m=message(name,iface,'s',('ProcessKeyEvent uint32 110',))
            self.assertEqual(p.parse_transport_log(frame(m))[0]['category'],'other')

    def test_relevant_wrong_direction_or_kind_is_rejected(self):
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(frame(message(),'RECEIVED'))
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(frame(signal(),'SENT'))
        m=Gio.DBusMessage.new_signal('/org/freedesktop/IBus/InputContext_2',p.INPUT_CONTEXT,'ProcessKeyEvent');m.set_serial(8);m.set_body(GLib.Variant('(uuu)',(1,2,3)))
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(frame(m,'RECEIVED'))

    def test_serial_and_bytecount_bounds(self):
        good=frame(message())
        for bad in [good.replace('  Serial:  4','  Serial:  0'),good.replace('  Serial:  4','  Serial:  4294967296'),good.replace('  Serial:  4','  Serial:  04'),good.replace('  Serial:  4','  Serial:  '+('9'*5000)),
                    good.replace('message (180 bytes)','message (0 bytes)'),good.replace('message (180 bytes)','message (999999999 bytes)')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_required_and_unknown_headers(self):
        good=frame(message())
        for bad in [good.replace("    member -> 'ProcessKeyEvent'\n",''),
                    good.replace('  Headers:\n','  Headers:\n    unknown -> uint32 1\n'),
                    good.replace('  Headers:\n','  Headers:\n    reply-serial -> uint32 2\n')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_reply_required_serial_and_wrong_typed_reply(self):
        r=message().new_method_reply();r.set_serial(5);r.set_body(GLib.Variant('(b)',(True,)));good=frame(r,'RECEIVED')
        for bad in [good.replace('    reply-serial -> uint32 4\n',''),good.replace('reply-serial -> uint32 4','reply-serial -> int32 4'),
                    good.replace('reply-serial -> uint32 4','reply-serial -> uint32 0')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_ibus_text_marker_and_signature(self):
        for m in [signal(marker='FakeText'),signal('UpdatePreeditText')]:
            good=frame(m,'RECEIVED')
            if m.get_member()=='UpdatePreeditText':good=good.replace("signature 'vub'","signature 'vbu'")
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good)

    def test_complete_framing_prefix_tail_and_embedded_markers(self):
        good=frame(message())
        for bad in ['warning\n'+good,good+'warning\n',good+p.SEPARATOR+'\n',good+good.split(p.SEPARATOR+'\n',1)[1],
                    good.replace('  Type:    method-call','GDBus-debug:Message:\n  Type:    method-call'),
                    good.replace('  Headers:\n','  Headers:\n'+p.SEPARATOR+'\n'),good.replace(p.SEPARATOR+'\n','',1)]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_every_noncomplete_eof_tail_and_missing_final_lf(self):
        good=frame(message());lines=good.splitlines(keepends=True)
        for i in range(1,len(lines)):
            with self.subTest(tail=i),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(''.join(lines[:i]))
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good[:-1])
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good.replace('    (none)\n','    (no',1))

    def test_descriptors_are_explicitly_unsupported(self):
        good=frame(message())
        for bad in [good.replace('    (none)\n','    fd 8: dev=0:10\n'),
                    good.replace('  Headers:\n','  Headers:\n    num-unix-fds -> uint32 1\n')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_typed_handle_without_descriptors_is_not_silently_accepted(self):
        m=message('Other',signature='h',args=(0,))
        with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(frame(m))

    def test_version_flags_and_corrupt_field_order(self):
        good=frame(message())
        for bad in [good.replace('  Version: 0','  Version: 1'),good.replace('Flags:   no-auto-start','Flags:   unknown'),
                    good.replace('Flags:   no-auto-start','Flags:   no-auto-start,no-auto-start'),
                    good.replace('Flags:   no-auto-start','Flags:   no-auto-start,no-reply-expected'),
                    good.replace('  Type:    method-call','  Type: method-call')]:
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_all_actual_gio_flags(self):
        m=message();m.set_flags(Gio.DBusMessageFlags.NO_REPLY_EXPECTED | Gio.DBusMessageFlags.NO_AUTO_START | Gio.DBusMessageFlags.ALLOW_INTERACTIVE_AUTHORIZATION)
        self.assertEqual(p.parse_transport_log(frame(m))[0]['flags'],','.join(p.FLAGS))

    def test_log_body_message_count_and_variant_limits(self):
        good=frame(message())
        with patch.object(p,'MAX_LOG_BYTES',10),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good)
        with patch.object(p,'MAX_BODY_BYTES',5),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good)
        with patch.object(p,'MAX_MESSAGES',1),self.assertRaises(p.DiagnosticsError):p.parse_transport_log(good+good)
        with patch.object(p,'MAX_VARIANT_NODES',2),self.assertRaises(p.DiagnosticsError):p._variant('(uint32 1, uint32 2, uint32 3)','(uuu)')
        with patch.object(p,'MAX_VARIANT_DEPTH',0),self.assertRaises(p.DiagnosticsError):p._variant('(uint32 1,)','(u)')

    def test_empty_is_not_a_qualification_and_invalid_utf8_rejected(self):
        self.assertEqual(p.parse_transport_log(''),[]);self.assertEqual(p.parse_transport_log('\n  \n'),[])
        for bad in (None,b'log','\x00','\ud800',frame(message()).replace('\n','\r\n')):
            with self.assertRaises(p.DiagnosticsError):p.parse_transport_log(bad)

    def test_never_calls_shell_evaluation(self):
        m=message('Other',signature='s',args=("__import__('os').system('touch forbidden')",))
        with patch('subprocess.Popen',side_effect=AssertionError('launch')),patch('subprocess.run',side_effect=AssertionError('launch')):
            self.assertEqual(p.parse_transport_log(frame(m))[0]['category'],'other')


if __name__=='__main__':unittest.main()
