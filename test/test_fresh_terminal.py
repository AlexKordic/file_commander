"""Pinned real Fresh attach/quit returns functioning terminal input to fc."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import termios
import uuid
from lua_runner import run_script
from test_results import require,validate_result
repo=Path(__file__).resolve().parent.parent
binary,fresh=map(lambda p:Path(p).resolve(),sys.argv[1:3])
negative="--failure" in sys.argv[3:]
if not fresh.is_file():
    print('SKIP real Fresh: packaged/pinned executable absent')
    raise SystemExit(1 if os.getenv('FC_REQUIRE_CAPABILITIES') else 77)
logs=Path(os.environ.get('FC_TEST_LOG_ROOT',repo/'build/test-logs'))/'fresh'/uuid.uuid4().hex
logs.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix='fc-fresh-',dir='/tmp') as directory:
    root=Path(directory);(root/'editor').mkdir();(root/'runtime').mkdir(mode=0o700)
    (root/'probe.txt').write_text('FC_FRESH_SMOKE_READY\n')
    (root/'fresh.json').write_text('{}')
    trace=root/'args.json';wrapper=root/'fresh-wrapper'
    wrapper.write_text('#!'+sys.executable+'\nimport os,sys,json\n'+
        'open('+repr(str(trace))+',"w").write(json.dumps(sys.argv[1:]))\n'+
        'os.execv('+repr(str(fresh))+',['+repr(str(fresh))+',"--no-plugins","--no-upgrade-check","--no-restore","--config",'+repr(str(root/'fresh.json'))+']+sys.argv[1:]+['+repr(str(root/'probe.txt'))+'])\n')
    if negative:
        wrapper.write_text(wrapper.read_text().replace('"--no-plugins"','"--fc-invalid-option"'))
    wrapper.chmod(0o700)
    env={'HOME':str(root/'home'),'XDG_CONFIG_HOME':str(root/'config'),'XDG_DATA_HOME':str(root/'data'),
         'XDG_CACHE_HOME':str(root/'cache'),'XDG_RUNTIME_DIR':str(root/'runtime'),'FC_FRESH_BIN':str(wrapper),'FC_FRESH_FIXTURE':str(root)}
    script=root/'test.lua'
    script.write_text('''local root=os.getenv('FC_FRESH_FIXTURE')
local function mark(name) local f=assert(io.open(root..'/'..name,'w'));f:write('ready');f:close() end
fc.left_cd(root); assert(fc.wait_event('dir_changed',2000))
-- Select the editor directory explicitly, independent of fixture filename sorting.
fc.cmd('glob_select'); fc.key({'e','d','i','t','o','r','ret'}); assert(fc.wait_event('dialog_closed',2000))
mark('starting'); local deadline=fc.monotonic_ms()+2000
while true do local f=io.open(root..'/ack','r'); if f then f:close(); break end; assert(fc.monotonic_ms()<deadline,'PTY setup handshake'); fc.sleep(1) end
fc.cmd('open_in_editor')
for _,e in ipairs(fc.errors()) do print('EDITOR ERROR',e) end
assert(#fc.errors()==0,'real Fresh attach failed')
mark('returned'); assert(fc.wait_event('selection_changed',3000)); assert(#fc.selected()>1,'terminal input did not resume')
print('[PASS] fresh_handoff')
''')
    if negative:
        script.write_text(script.read_text().replace("assert(#fc.errors()==0,'real Fresh attach failed')","assert(#fc.errors()>0,'invalid Fresh invocation falsely succeeded')"))
    seen=bytearray();sent=set();modes={}
    def output(data):
        seen.extend(data)
        if len(seen)>256*1024:del seen[:-256*1024]
    def tick(master,elapsed):
        if (root/'starting').exists() and 'before' not in modes:
            modes['before']=termios.tcgetattr(master)[3];(root/'ack').write_text('ready')
        if b'Ln 1, Col 1' in seen and 'quit' not in sent:
            os.write(master,b'\x11');sent.add('quit')
        if (root/'returned').exists() and 'select' not in sent:
            modes['after']=termios.tcgetattr(master)[3];os.write(master,b'\x01');sent.add('select')
    try:
        result=run_script(binary,script,root,root/'config',25,env,on_tick=tick,on_output=output)
        rc,seconds,killed,data=result;(logs/'terminal.log').write_bytes(data)
        debug=(root/'config/lua-debug.log').read_text();(logs/'debug.log').write_text(debug)
        validate_result('fresh_handoff',rc,killed,data,debug)
        require(sent==({'select'} if negative else {'quit','select'}),'real Fresh did not render its status line and return input')
        (logs/'modes.json').write_text(json.dumps(modes))
        mask=termios.ICANON|termios.ECHO
        require(modes['before']&mask==modes['after']&mask,'terminal mode restoration changed canonical/echo flags')
    finally:
        if trace.exists():
            arguments=json.loads(trace.read_text());(logs/'arguments.json').write_text(json.dumps(arguments))
            if '-a' in arguments:
                session=arguments[arguments.index('-a')+1]
                subprocess.run([str(fresh),'--cmd','session','kill',session],env=dict(os.environ,**env),capture_output=True,timeout=5)
print('PASS real Fresh failure' if negative else 'PASS real Fresh attach/quit', 'input/modes; logs:',logs)
