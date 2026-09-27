"""Relocation: embedded Lua and real bundled helper bytes with proven paths."""
from test_results import require, validate_result
from fixture_tool import manifest
from pathlib import Path
import hashlib
import json
import platform
import shutil
import os
import shlex
import subprocess
import sys
import tarfile
import tempfile
import uuid
from lua_runner import run_script

repo=Path(__file__).resolve().parent.parent
archive=Path(sys.argv[1]) if len(sys.argv)>1 else next((repo/'build/dist').glob('*.tar.gz'))
logs=archive.parent/'test-logs'/uuid.uuid4().hex
logs.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix="fc-package-test-") as temp:
    root=Path(temp)
    with tarfile.open(archive) as package: package.extractall(root/'relocated package',filter='data')
    binary=next((root/'relocated package').glob('*/bin/fc')).resolve()
    unrelated=root/'unrelated';unrelated.mkdir()
    for name in ('source','archives','output','editor'): (root/name).mkdir()
    (root/'source/sub').mkdir()
    (root/'editor/sub').mkdir()
    (root/'source/alpha').write_bytes(b'archive\0payload\xff')
    (root/'source/sub/Ω-file').write_bytes(b'nested bytes')
    trace=root/'helper-trace'
    for name in ('7zr','fresh'):
        helper=binary.parent/name
        if not helper.is_file():
            print(f'SKIP package tools: missing bundled {name}')
            raise SystemExit(1 if os.getenv('FC_REQUIRE_CAPABILITIES') else 77)
        real=helper.with_name(name+'.real');helper.rename(real)
        helper.write_text('#!/bin/sh\n' +
          'printf "%s\\n" "$0 $*" >> '+shlex.quote(str(trace))+'\n' +
          ('if [ "${FC_HELPER_FAIL:-0}" = 1 ]; then exit 11; fi\n' if name=='7zr' else '')+
          'exec '+shlex.quote(str(real))+(' --version\n' if name=='fresh' else ' "$@"\n'))
        helper.chmod(0o755)
    env={'HOME':str(root/'home'),'XDG_DATA_HOME':str(root/'data'),'XDG_CACHE_HOME':str(root/'cache'),
         'XDG_RUNTIME_DIR':str(root/'runtime'),'PATH':'/usr/bin:/bin','FC_FRESH_BIN':'', 'FC_PACKAGE_FIXTURE':str(root)}
    script=unrelated/'check.lua'
    script.write_text('''local root=os.getenv('FC_PACKAGE_FIXTURE')
check(type(fc.key)=='function','embedded framework')
fc.left_cd(root..'/source'); assert(fc.wait_event('dir_changed',2000))
fc.right_cd(root..'/archives'); assert(fc.wait_event('dir_changed',2000))
fc.cmd('select_all'); fc.cmd('copy'); assert(fc.wait_event('discovery_completed',10000))
fc.key('up'); for c in ('/bundle.7z'):gmatch('.') do fc.key(c) end
fc.key('f5'); assert(fc.wait_event('dialog_closed',2000)); assert(fc.wait_for_jobs(10000))
assert(#fc.errors()==0, 'packaged archive create failed')
fc.right_cd(root..'/archives'); assert(fc.wait_event('dir_changed',2000))
fc.cmd('switch_panel'); fc.cmd('enter_dir'); assert(fc.wait_event('dir_changed',10000))
fc.left_cd(root..'/output'); assert(fc.wait_event('dir_changed',2000))
fc.cmd('select_all'); fc.cmd('copy'); assert(fc.wait_event('discovery_completed',10000))
fc.key({'<-','ret'}); assert(fc.wait_event('dialog_closed',2000)); assert(fc.wait_for_jobs(10000))
assert(#fc.errors()==0,'packaged extraction failed')
fc.cmd('switch_panel'); fc.left_cd(root..'/editor'); assert(fc.wait_event('dir_changed',2000)); fc.cmd('open_in_editor')
for _,e in ipairs(fc.errors()) do print('ERROR DETAIL',e) end
assert(#fc.errors()==0,'packaged Fresh version adapter failed')
test_pass('packaged_script')
''')
    denied=[repo.resolve(),*( (repo/path).resolve() for path in ('../alex_ftxui','../editor-fresh','../luajit','../lzma2600'))]
    prefix=[]
    if platform.system()=='Darwin' and shutil.which('sandbox-exec'):
        profile='(version 1)(allow default)' + ''.join('(deny file-read* (subpath '+json.dumps(str(path))+'))' for path in denied)
        prefix=['sandbox-exec','-p',profile]
    elif platform.system()=='Linux' and shutil.which('bwrap'):
        prefix=['bwrap','--ro-bind','/','/','--dev-bind','/dev','/dev','--tmpfs','/tmp','--bind',str(root),str(root)]
        for path in denied:
            if path.exists():prefix+=['--tmpfs',str(path)]
        prefix+=['--chdir',str(unrelated),'--']
    isolated=bool(prefix)
    if isolated:
        probe=subprocess.run([*prefix,'/bin/cat',str(repo/'CMakeLists.txt')],cwd=unrelated,capture_output=True,timeout=5)
        allowed=subprocess.run([*prefix,'/bin/cat',str(root/'source/alpha')],cwd=unrelated,capture_output=True,timeout=5)
        require(probe.returncode!=0 and allowed.stdout==b'archive\0payload\xff','package sandbox does not enforce intended read boundary')
    elif os.getenv('FC_REQUIRE_CAPABILITIES'):
        raise SystemExit('required relocation isolation unavailable: install bwrap (Linux) or sandbox-exec (macOS)')
    rc,seconds,killed,output=run_script(binary,script,unrelated,root/'config',20,env,command_prefix=prefix)
    debug=(root/'config/lua-debug.log').read_text()
    (logs/'package.log').write_bytes(output);(logs/'debug.log').write_text(debug)
    (logs/'helpers.log').write_text(trace.read_text() if trace.exists() else 'no helper calls')
    print('Package logs:',logs,flush=True)
    validate_result('package',rc,killed,output,debug)
    require(manifest(root/'source')==manifest(root/'output'),'packaged archive changed tree/bytes')
    observed=trace.read_text();(logs/'helpers.log').write_text(observed)
    for name in ('7zr','fresh'):
        require(str(binary.parent/name) in observed,f'build/PATH helper bypassed relocated {name}')
    require(' a ' in observed and ' x ' in observed,'real archive create/extract not executed')
    require(not (unrelated/'fc_framework.lua').exists(),'framework unexpectedly external')
    # Invoke both relocated executables directly, including their failure path.
    archive_tool=binary.parent/'7zr'
    failed=subprocess.run([str(archive_tool),'x',str(root/'missing.7z')],cwd=unrelated,env=dict(os.environ,**env),capture_output=True,timeout=10)
    require(failed.returncode>0,'missing archive falsely succeeded')
    for name in ('7zr','fresh'):
        require((binary.parent/(name+'.real')).stat().st_size>1024,'helper was not a real binary')
    print(f'PASS relocated package archive tree, helper provenance and Fresh version; isolation={isolated}; logs: {logs}')
    if not isolated:
        print('SKIP full isolation: bwrap/sandbox-exec unavailable')
        raise SystemExit(77)
