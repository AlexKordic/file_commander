"""Qualification cannot turn missing results, skips or wrong hosts into passes."""
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile
from test_results import require
repo=Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='fc-lane-check-') as directory:
    root=Path(directory);fake=root/'ctest'
    fake.write_text('#!'+sys.executable+'''\nimport os,sys
from pathlib import Path
mode=os.environ['FC_LANE_CONTROL']
p=Path(sys.argv[sys.argv.index('--output-junit')+1])
if mode!='missing':
 p.write_text('<testsuite>'+('' if mode=='empty' else '<testcase name="fixture">'+('<skipped/>' if mode=='skip' else '')+'</testcase>')+'</testsuite>')
''');fake.chmod(0o700)
    base=[sys.executable,str(repo/'tools/run_test_lane.py')]
    for lane,control,valid in [('fast','pass',True),('fast','skip',True),('release','pass',True),('release','skip',False),('fast','empty',False),('fast','missing',False)]:
        env=dict(os.environ,PATH=str(root)+os.pathsep+os.environ['PATH'],FC_LANE_CONTROL=control)
        result=subprocess.run([*base,lane,'--build',str(root/'build')],env=env,capture_output=True,text=True,timeout=5)
        require((result.returncode==0)==valid,f'lane control {lane}/{control}: {result.stdout} {result.stderr}')
    wrong='Linux' if platform.system()=='Darwin' else 'Darwin'
    result=subprocess.run([*base,'fast','--expect-os',wrong],capture_output=True,text=True,timeout=5)
    require(result.returncode!=0 and 'native OS mismatch' in result.stderr,'cross-host qualification accepted')
print('PASS lane result completeness, strict skips and native host identity')
