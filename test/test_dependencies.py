"""Pinned-input rejection controls operate only on disposable checkout copies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from test_results import require
repo=Path(__file__).resolve().parent.parent
ftxui,luajit,lzma=map(Path,sys.argv[1:4])
with tempfile.TemporaryDirectory(prefix='fc-dependencies-') as directory:
    root=Path(directory);copy=root/'ftxui'
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
