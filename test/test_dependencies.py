"""Pinned-input rejection controls operate only on disposable checkout copies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import hashlib
import io
import json
import tarfile
from test_results import require
repo=Path(__file__).resolve().parent.parent
sys.path.insert(0, str(repo / 'tools'))
from bootstrap_dependencies import provision_lzma
ftxui,luajit,lzma=map(Path,sys.argv[1:4])
with tempfile.TemporaryDirectory(prefix='fc-dependencies-') as directory:
    root=Path(directory);copy=root/'ftxui'
    spec=json.loads((repo/'dependencies.json').read_text())['lzma']
    unpacked=root/'unpacked'
    provision_lzma(repo,spec,unpacked)
    require((unpacked/'CPP/7zip/Bundles/Alone7z/makefile.gcc').is_file(),'SDK snapshot omitted the 7zr build inputs')
    override=root/'override'
    provision_lzma(repo,spec,override,unpacked)
    require((override/'C/LzmaDec.c').read_bytes()==(unpacked/'C/LzmaDec.c').read_bytes(),'SDK source override changed bytes')
    try: provision_lzma(repo,dict(spec,archive_sha256='0'*64),root/'rejected')
    except ValueError: pass
    else: raise RuntimeError('corrupt SDK checksum accepted')
    unsafe=root/'unsafe.tar.gz'
    with tarfile.open(unsafe,'w:gz') as package:
        member=tarfile.TarInfo('../escaped');member.size=1
        package.addfile(member,io.BytesIO(b'x'))
    unsafe_spec=dict(spec,archive=str(unsafe),archive_sha256=hashlib.sha256(unsafe.read_bytes()).hexdigest())
    try: provision_lzma(repo,unsafe_spec,root/'rejected')
    except tarfile.FilterError: pass
    else: raise RuntimeError('SDK archive traversal accepted')
    require(not (root/'rejected').exists() and not (root/'escaped').exists(),'rejected SDK left a partial checkout or escaped extraction')
    subprocess.run(['git','clone','--quiet','--shared',str(ftxui),str(copy)],check=True)
    sdk=root/'sdk';shutil.copytree(lzma,sdk,ignore=shutil.ignore_patterns('_o','_o_*','.git'))
    command=[sys.executable,str(repo/'tools/check_dependencies.py'),'--ftxui',str(copy),'--luajit',str(luajit),'--lzma',str(sdk),'--skip-fresh']
    def check(valid,diagnostic=''):
        result=subprocess.run(command,capture_output=True,text=True,timeout=20)
        require((result.returncode==0)==valid and (valid or diagnostic in result.stderr),f'dependency control: {result.stdout} {result.stderr}')
    check(True)
    tracked=subprocess.check_output(['git','-C',str(copy),'ls-files'],text=True).splitlines()[0]
    path=copy/tracked;original=path.read_bytes();path.write_bytes(original+b'\nfixture corruption\n')
    check(False,'modified tracked files');path.write_bytes(original);check(True)
    subprocess.run(['git','-C',str(copy),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','--quiet','--allow-empty','-m','wrong revision'],check=True)
    check(False,'ftxui: expected clean')
    subprocess.run(['git','-C',str(copy),'reset','--quiet','--hard','HEAD^'],check=True)
    source=next(sdk.rglob('*.c'));source.chmod(0o600);source.write_bytes(source.read_bytes()+b'\n/* changed fixture */\n');check(False,'lzma: source set differs')
    shutil.rmtree(copy);check(False,'cannot read checkout')
print('PASS pinned dependency clean/dirty/revision/missing/fingerprint controls')
