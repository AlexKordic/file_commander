#!/usr/bin/env python3
"""Test installed Safari with existing macOS accessibility access, without WebDriver.

Creates an isolated HTML copy with a read-only state observer, drives real page
controls through AX, and leaves the local preview open. No Safari privacy setting
is changed. The original HTML/media/player code remain unchanged.
"""
import argparse
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid

OBSERVER = r'''
<script>
(()=>{
 const state=document.createElement('textarea');state.readOnly=true;state.setAttribute('aria-label','Safari qualification state');
 state.style.cssText='position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:0;font-size:1px;opacity:.02;z-index:99999';document.body.prepend(state);
 const done=document.createElement('button');done.textContent='Finish Safari verification';done.style.cssText=state.style.cssText+';left:2px';document.body.prepend(done);
 function tick(){const v=document.getElementById('video'),p=window.tutorialPlayer,d=p?.data;
 state.value=JSON.stringify({ready:!!p,user_agent:navigator.userAgent,source_sha256:SOURCE_HASH,
 paused:v.paused,time:v.currentTime,duration:v.duration,width:v.videoWidth,height:v.videoHeight,
 status:document.getElementById('status').textContent,selected:p?.selected,stop:p?.lastBoundaryStop||null,
 captions:v.textTracks[0]?.mode||'',cues:v.textTracks[0]?.cues?.length||0,
 chapters:d?.chapters.map(c=>({title:c.title,start:c.start_ns/1e9}))||[],
 external_requests:performance.getEntriesByType('resource').filter(x=>/^https?:/.test(x.name)).map(x=>x.name)});}
 const timer=setInterval(tick,50);tick();
 function finish(){clearInterval(timer);clearTimeout(watchdog);state.remove();done.remove();document.title=ORIGINAL_TITLE;}
 const watchdog=setTimeout(finish,240000);done.onclick=finish;
})();
</script>
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('page', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if sys.platform != 'darwin':
        parser.error('Installed Safari qualification requires macOS')
    os.umask(0o077)
    folder = args.out.resolve(); folder.mkdir(parents=True, exist_ok=True)
    source = args.page.resolve()
    with source.open('rb') as stream:
        source_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    content = source.read_text()
    original = html.unescape(re.search(r'<title>(.*?)</title>', content, re.S).group(1))
    token = uuid.uuid4().hex[:10]
    title = 'Tutorial Safari qualification ' + token
    content = re.sub(r'<title>.*?</title>', '<title>' + title + '</title>', content, count=1, flags=re.S)
    script = OBSERVER.replace('SOURCE_HASH', json.dumps(source_hash)).replace('ORIGINAL_TITLE', json.dumps(original).replace('<', '\\u003c'))
    page = folder / ('standalone-' + token + '.html'); page.write_text(content + script)
    driver = folder / 'tutorial-safari-test'
    with (folder / 'build.log').open('w') as log:
        subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', str(Path(__file__).with_suffix('.swift')),
                        '-o', str(driver)], stdout=log, stderr=subprocess.STDOUT, check=True, timeout=90)
    report = folder / 'results.json'; report.unlink(missing_ok=True)
    with (folder / 'driver.log').open('w') as log:
        completed = subprocess.run([str(driver), str(page), title, str(report)], stdout=log, stderr=subprocess.STDOUT, timeout=300)
    result = json.loads(report.read_text())
    result.update(engine='safari', standalone_sha256=source_hash, privacy_settings_changed=False,
                  instrumentation='Read-only AX observer appended to an isolated copy; only document title changed; original player code and media unchanged',
                  observed_file_sha256=hashlib.sha256(page.read_bytes()).hexdigest())
    report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    return completed.returncode


if __name__ == '__main__':
    raise SystemExit(main())
