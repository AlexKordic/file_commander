#!/usr/bin/env python3
"""Create isolated pinned checkouts; never reset or edit existing input trees."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
repo=Path(__file__).resolve().parent.parent
manifest=json.loads((repo/'dependencies.json').read_text())
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root',type=Path,required=True)
parser.add_argument('--ftxui-url',default=os.getenv('FC_FTXUI_MIRROR'))
parser.add_argument('--fresh-url',default=os.getenv('FC_FRESH_MIRROR'))
parser.add_argument('--lzma-source',type=Path,required=True,help='Provisioned SDK 26.00 source, checked against manifest')
args=parser.parse_args();root=args.root.resolve();root.mkdir(parents=True,exist_ok=True)
paths={}
for name,spec in manifest['git'].items():
    target=root/name;paths[name]=target
    if not target.exists():
        source=args.ftxui_url if name=='ftxui' and args.ftxui_url else spec['source']
        if name == 'fresh' and args.fresh_url:
            source = args.fresh_url
        bundle = repo / spec['bundle'] if 'bundle' in spec else None
        if bundle and hashlib.sha256(bundle.read_bytes()).hexdigest() != spec['bundle_sha256']:
            raise SystemExit(f'{name}: dependency bundle fingerprint mismatch')
        subprocess.run(['git','clone','--no-checkout',source,str(target)],check=True,timeout=600)
        if bundle:
            subprocess.run(['git','-C',str(target),'bundle','verify',str(bundle)],check=True,timeout=60)
            subprocess.run(['git','-C',str(target),'fetch',str(bundle),'refs/heads/fc-editor-workflow'],check=True,timeout=60)
        subprocess.run(['git','-C',str(target),'checkout','--detach',spec['revision']],check=True,timeout=60)
sdk=root/'lzma'
if not sdk.exists():shutil.copytree(args.lzma_source,sdk,ignore=shutil.ignore_patterns('_o','_o_*','.git'))
command=[sys.executable,str(repo/'tools/check_dependencies.py'),'--lzma',str(sdk)]
for name,path in paths.items():command+=['--'+name,str(path)]
subprocess.run(command,check=True,timeout=60)
print('Pinned dependency root:',root)
