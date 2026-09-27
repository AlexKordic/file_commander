"""Actual terminal byte decoding and resize, synchronized by Lua checkpoints."""
import fcntl
import os
from pathlib import Path
import signal
import struct
import sys
import tempfile
import termios
import uuid
from lua_runner import run_script
from test_results import require, validate_result
repo = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1] if len(sys.argv)>1 else repo/'build/fc')
logs = Path(os.environ.get('FC_TEST_LOG_ROOT',repo/'build/test-logs'))/'terminal'/uuid.uuid4().hex
logs.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix='fc-terminal-') as directory:
    root=Path(directory)
    for name in ('left','right'):
        (root/name).mkdir()
        (root/name/'Ω-file').write_bytes(b'exact payload\0')
    script=root/'terminal.lua'
    script.write_text('''local root=os.getenv('FC_TERMINAL_FIXTURE')
local function ready(n) local f=assert(io.open(root..'/ready','w')); f:write(tostring(n)); f:close() end
fc.left_cd(root..'/left'); assert(fc.wait_event('dir_changed',2000))
fc.right_cd(root..'/right'); assert(fc.wait_event('dir_changed',2000))
ready(1); assert(fc.wait_event('selection_changed',2000)); assert(fc.state().left.selected_count==1)
ready(2); assert(fc.wait_event('focus_changed',2000))
ready(3); assert(fc.wait_event('selection_changed',2000)); assert(fc.state().right.selected_count==1)
ready(4); assert(fc.wait_event('dialog_opened',2000)); assert(fc.state().right.active_dialog=='Copy')
ready(5); assert(fc.wait_event('dialog_closed',2000))
ready(6); assert(fc.wait_event('focus_changed',2000))
ready(7); assert(fc.wait_event('selection_changed',2000)); assert(fc.state().left.selected_count==0)
print('[PASS] terminal_input_resize')
''')
    sent=set()
    keys={1:b'\x01',2:b'\t',3:b'\x01',4:b'\x1b[15~',5:b'\x1b',6:b'\t',7:b'\x1b'}
    def tick(master, elapsed):
        if not (root/'ready').exists(): return
        text=(root/'ready').read_text()
        if not text: return
        stage=int(text)
        if stage in sent:return
        # Exercise normal, narrow and tiny geometries before actual input.
        rows, cols={2:(8,35),4:(3,12),6:(40,140)}.get(stage,(24,80))
        fcntl.ioctl(master,termios.TIOCSWINSZ,struct.pack('HHHH',rows,cols,0,0))
        os.write(master,keys[stage]);sent.add(stage)
    result=run_script(binary,script,repo,root/'config',timeout=15,extra_env={'FC_TERMINAL_FIXTURE':str(root)},on_tick=tick)
    rc,seconds,killed,output=result
    (logs/'terminal.log').write_bytes(output)
    debug=(root/'config/lua-debug.log').read_text()
    (logs/'debug.log').write_text(debug)
    validate_result('terminal',rc,killed,output,debug)
    require(sent==set(keys),'terminal checkpoints missing')
print('PASS actual PTY input and resize; logs:',logs)
