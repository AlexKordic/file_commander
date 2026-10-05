#!/usr/bin/env python3
"""Run a bounded lane with machine-readable evidence and strict release skips."""
import argparse
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import time
import tarfile
import uuid
import xml.etree.ElementTree as ET
from release_gate import required_tests, check_build, check_discovery, check_names, check_package

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('lane',choices=['fast','integration','sanitizer','thread','extended','release'])
parser.add_argument('--build',type=Path,default=Path('build'))
parser.add_argument('--expect-os',choices=['Darwin','Linux'])
parser.add_argument('--expect-arch',choices=['arm64','x86_64'])
parser.add_argument('--jobs',type=int,default=6)
args=parser.parse_args()
actual_arch={'aarch64':'arm64','AMD64':'x86_64'}.get(platform.machine(),platform.machine())
if args.expect_os and platform.system()!=args.expect_os:raise SystemExit('native OS mismatch; compilation/emulation is not native qualification')
if args.expect_arch and actual_arch!=args.expect_arch:raise SystemExit('native architecture mismatch')
root=Path(__file__).resolve().parent.parent
artifacts=args.build.resolve()/'test-logs'/('lane-'+args.lane+'-'+uuid.uuid4().hex[:10]);artifacts.mkdir(parents=True)
command=['ctest','--test-dir',str(args.build.resolve()),'--output-on-failure','--output-junit',str(artifacts/'results.xml'),'-j',str(args.jobs)]
filters={'fast':['-L','unit|fault|harness','-LE','extended|benchmark'], 'integration':['-LE','slow|extended|benchmark'],
         'sanitizer':['-L','core','-LE','extended|benchmark'], 'thread':['-L','lifetime'],
         'extended':['-L','extended|benchmark'], 'release':[]}
command+=filters[args.lane]
env=dict(os.environ,FC_TEST_LOG_ROOT=str(artifacts),ASAN_OPTIONS='halt_on_error=1',UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1',TSAN_OPTIONS='halt_on_error=1')
if args.lane=='release':
    env['FC_REQUIRE_CAPABILITIES']='1';env['FC_REQUIRE_EXDEV']='1'
metadata={'lane':args.lane,'os':platform.system(),'architecture':actual_arch,'platform':platform.platform(),
          'revision':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
          'command':command,'started':time.time()}
print('Artifacts:',artifacts,flush=True)
if args.lane=='release':
    try:
        expected=required_tests(root)
        binaries,package=check_build(args.build.resolve(),root,platform.system(),actual_arch)
        discovery=subprocess.run(['ctest','--test-dir',str(args.build.resolve()),'--show-only=json-v1'],
                                 cwd=root,env=env,text=True,capture_output=True,check=True,timeout=30)
        (artifacts/'discovery.json').write_text(discovery.stdout)
        check_discovery(json.loads(discovery.stdout),expected)
        metadata['required_tests']=sorted(expected)
    except (OSError,ValueError,KeyError,subprocess.SubprocessError) as error:
        metadata.update(status=1,error=str(error))
        (artifacts/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
        (artifacts/'ctest.log').write_text('Release preflight failed: '+str(error)+'\n')
        raise SystemExit('Release preflight failed: '+str(error))
with (artifacts/'ctest.log').open('w') as log:
    try:
        result=subprocess.Popen(command,cwd=root,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        status=result.wait(timeout=1800)
    except subprocess.TimeoutExpired:
        os.killpg(result.pid,signal.SIGKILL)
        result.wait(timeout=5)
        status=124
metadata['seconds']=time.time()-metadata['started']
metadata['status']=status
xml=artifacts/'results.xml'
try:
    cases=ET.parse(xml).getroot().findall('.//testcase')
    metadata['tests']=len(cases);metadata['skipped']=[case.get('name') for case in cases if case.find('skipped') is not None or case.get('status') in ('notrun','disabled')]
    metadata['failed']=[case.get('name') for case in cases if case.find('failure') is not None or case.find('error') is not None or case.get('status')=='fail']
    if not cases or metadata['failed']:status=1
    if args.lane=='release':
        check_names([case.get('name') for case in cases],expected)
        if metadata['skipped']:status=1
        metadata['artifact_sha256']=check_package(package,binaries)
except (OSError,ValueError,KeyError,ET.ParseError, tarfile.TarError) as error:
    metadata['error']=str(error);status=1
metadata['status']=status
(artifacts/'metadata.json').write_text(json.dumps(metadata,indent=2)+'\n')
print((artifacts/'ctest.log').read_text()[-8000:])
raise SystemExit(status)
