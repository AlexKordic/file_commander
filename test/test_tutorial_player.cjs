#!/usr/bin/env node
// Real offline media playback. Install Playwright separately; it is not an app dependency.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const playwright = require(process.env.TUTORIAL_PLAYWRIGHT_PATH || 'playwright');

async function check(engine, pageFile, output) {
  const options={headless:true};
  if(engine==='chromium'&&process.env.TUTORIAL_CHROME_BIN)options.executablePath=process.env.TUTORIAL_CHROME_BIN;
  const browser = await playwright[engine].launch(options);
  const context = await browser.newContext({offline: true, viewport: {width: 1100, height: 850}});
  const page = await context.newPage(), failures = [], network = [];
  page.on('pageerror', error => failures.push(String(error)));
  page.on('request', request => { if (/^https?:/.test(request.url())) network.push(request.url()); });
  const report = {engine, browser:options.executablePath?'Google Chrome for Testing':engine,
                  version: browser.version(), checks: [], status: 'running'};
  report.standalone_sha256=require('node:crypto').createHash('sha256').update(fs.readFileSync(pageFile)).digest('hex');
  try {
    const started=performance.now();
    await page.goto(pathToFileURL(pageFile).href,{timeout:90000});
    await page.waitForFunction(() => !!window.tutorialPlayer);
    await page.evaluate(() => window.tutorialPlayer.ready());
    report.startup_to_metadata_ms=Math.round(performance.now()-started);
    report.standalone_bytes=fs.statSync(pageFile).size;
    if(engine==='chromium'){
      const cdp=await context.newCDPSession(page);
      report.javascript_heap_after_metadata=await cdp.send('Runtime.getHeapUsage');
      const system=await browser.newBrowserCDPSession();
      const info=await system.send('SystemInfo.getProcessInfo');
      const pids=info.processInfo.map(p=>String(p.id));
      const rss=require('node:child_process').spawnSync('/bin/ps',['-o','rss=','-p',pids.join(',')],{encoding:'utf8'});
      if(rss.status===0)report.owned_browser_resident_bytes_after_metadata=rss.stdout.trim().split(/\s+/).reduce((n,v)=>n+Number(v)*1024,0);
      await cdp.detach();await system.detach();
    }
    const data = await page.evaluate(() => window.tutorialPlayer.data);
    assert(data.steps.length >= 3, 'Qualification needs at least three presentation steps');
    const media = await page.evaluate(() => {
      const v = document.getElementById('video');
      return {duration: v.duration, width: v.videoWidth, height: v.videoHeight, source: v.src};
    });
    assert.equal(media.width, data.width); assert.equal(media.height, data.height);
    assert(Math.abs(media.duration - data.duration_ns/1e9) <= 1/data.fps+.025);
    assert(media.source.startsWith('blob:'), 'Standalone video must come from embedded bytes');
    report.checks.push('offline-embedded-media-and-dimensions');
    await page.locator('#captions').click();
    await page.waitForFunction(() => {
      const v = document.getElementById('video');
      return v.textTracks.length && v.textTracks[0].mode === 'showing' && v.textTracks[0].cues?.length > 0;
    });
    report.checks.push('offline-caption-track');
    await page.evaluate(() => { document.getElementById('video').playbackRate = 2; });
    const step = data.steps[1];
    await page.locator(`.step[data-step="${step.id}"] button`).click();
    await page.waitForFunction(() => !document.getElementById('video').paused);
    await page.waitForFunction(() => document.getElementById('video').paused && document.getElementById('status').textContent.startsWith('Step finished'), null, {timeout: 60000});
    const end = await page.evaluate(() => document.getElementById('video').currentTime);
    const observed=await page.evaluate(()=>window.tutorialPlayer.lastBoundaryStop);
    assert(observed&&Math.abs(observed.target-step.end_ns/1e9)<.001);
    report.step_boundary_error_ms = Math.abs(observed.error_ms);
    report.paused_frame_offset_ms=Math.abs(end-step.end_ns/1e9)*1000;
    assert(report.step_boundary_error_ms <= 100, `Step boundary error ${report.step_boundary_error_ms}ms`);
    assert.equal(await page.evaluate(() => window.tutorialPlayer.selected), step.id);
    report.checks.push('bounded-step-playback');
    await page.evaluate(()=>Object.defineProperty(document.getElementById('video'),'requestVideoFrameCallback',{value:undefined,configurable:true}));
    await page.locator('#replay').click();
    await page.waitForFunction(()=>!document.getElementById('video').paused);
    await page.waitForFunction(()=>document.getElementById('video').paused&&document.getElementById('status').textContent.startsWith('Step finished'),null,{timeout:60000});
    const fallbackEnd=await page.evaluate(()=>document.getElementById('video').currentTime);
    const fallbackObserved=await page.evaluate(()=>window.tutorialPlayer.lastBoundaryStop);
    assert(fallbackObserved&&Math.abs(fallbackObserved.target-step.end_ns/1e9)<.001);
    report.fallback_boundary_error_ms=Math.abs(fallbackObserved.error_ms);
    report.fallback_paused_frame_offset_ms=Math.abs(fallbackEnd-step.end_ns/1e9)*1000;
    assert(report.fallback_boundary_error_ms<=100,'Timer fallback exceeded its step boundary tolerance');
    await page.evaluate(()=>{delete document.getElementById('video').requestVideoFrameCallback;});
    report.checks.push('bounded-step-timer-fallback');
    await page.locator('#replay').click();
    await page.waitForFunction(start => {
      const v = document.getElementById('video'); return !v.paused && v.currentTime >= start && v.currentTime < start+1;
    }, step.start_ns/1e9);
    await page.locator('#pause').click();
    report.checks.push('replay-current-step');
    // Exercise an older pending seek racing a newer request, without allowing
    // its completion/boundary callback to retake ownership of playback.
    await page.evaluate(async ids => {
      const player = window.tutorialPlayer;
      await Promise.all([player.playStep(ids[0]), player.playStep(ids[1])]);
    }, [data.steps[0].id, data.steps[2].id]);
    await page.waitForFunction(id => window.tutorialPlayer.selected === id && !document.getElementById('video').paused, data.steps[2].id);
    await page.locator('#pause').click();
    report.checks.push('rapid-selection-cancels-stale-seek');
    await page.locator('#previous').click();
    await page.waitForFunction(id => window.tutorialPlayer.selected === id && document.getElementById('video').paused, data.steps[1].id);
    await page.locator('#next').click();
    await page.waitForFunction(id => window.tutorialPlayer.selected === id && document.getElementById('video').paused, data.steps[2].id);
    report.checks.push('previous-next-select-without-playing');
    await page.locator('#continuous').check();
    await page.locator(`.step[data-step="${data.steps[0].id}"] button`).click();
    await page.waitForFunction(end => !document.getElementById('video').paused && document.getElementById('video').currentTime > end+.15,
                               data.steps[0].end_ns/1e9, {timeout: 60000});
    await page.locator('#pause').click();
    report.checks.push('continuous-playback-crosses-step-boundary');
    const videoBottom = await page.locator('video').evaluate(v => v.getBoundingClientRect().bottom + scrollY);
    const chaptersTop = await page.locator('nav').evaluate(v => v.getBoundingClientRect().top + scrollY);
    assert(chaptersTop >= videoBottom, 'Chapters must be below the movie');
    await page.setViewportSize({width: 480, height: 850});
    assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth+1), 'Page overflows on a narrow viewport');
    await page.keyboard.press('Tab');
    report.checks.push('chapters-below-video-responsive-keyboard-ui');
    const chapter=data.chapters[data.chapters.length-1];
    await page.locator(`.chapter[data-chapter="${chapter.id}"]`).click();
    await page.waitForFunction(start=>{const v=document.getElementById('video');return !v.paused&&v.currentTime>=start&&v.currentTime<start+2;},chapter.start_ns/1e9);
    assert.equal(await page.evaluate(()=>new URLSearchParams(location.hash.slice(1)).get('chapter')),chapter.id);
    assert(await page.locator('video').evaluate(v=>v.getBoundingClientRect().top>=-1&&v.getBoundingClientRect().top<innerHeight));
    await page.locator('#pause').click();
    report.checks.push('chapter-jump-plays-and-reveals-video');
    const lessonIndex=Math.floor(data.lessons.length/2),lesson=data.lessons[lessonIndex];
    await page.locator('.lesson').nth(lessonIndex).locator('button').first().click();
    await page.waitForFunction(start=>{const v=document.getElementById('video');return !v.paused&&v.currentTime>=start&&v.currentTime<start+2;},lesson.start_ns/1e9);
    assert.equal(await page.evaluate(()=>document.activeElement.id),'video');
    await page.locator('#pause').click();
    report.checks.push('lesson-jump-plays-and-focuses-video');
    await page.screenshot({path: path.join(output, engine+'-player.png'), fullPage: true});
    const deep = await context.newPage();
    await deep.goto(pathToFileURL(pageFile).href + '#step=' + encodeURIComponent(data.steps[2].id));
    await deep.waitForFunction(start => {
      const v = document.getElementById('video');return v.readyState>=1 && v.paused && Math.abs(v.currentTime-start)<.1;
    }, data.steps[2].start_ns/1e9);
    report.checks.push('deep-link-selects-step-without-autoplay');
    assert.equal(network.length, 0, 'Standalone page attempted network access');
    assert.deepEqual(failures, []);
    report.status = 'passed';
  } catch (error) {
    report.status = 'failed'; report.error = error.stack || String(error);
    report.page_errors = failures; report.network = network;
  } finally { await context.close(); await browser.close(); }
  return report;
}

(async () => {
  const source = path.resolve(process.argv[2] || ''), output = path.resolve(process.argv[3] || path.join(path.dirname(source), 'browser-qualification'));
  fs.mkdirSync(output, {recursive:true});
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'tutorial-offline-'));
  const isolated = path.join(temporary, 'standalone.html');fs.copyFileSync(source, isolated);
  const reports = [];
  try {
    for(const engine of ['chromium','firefox','webkit']) {
      const report = await check(engine, isolated, output);reports.push(report);
      fs.writeFileSync(path.join(output,'results.json'),JSON.stringify(reports,null,2)+'\n');
      console.log(engine+': '+report.status+(report.error?' — '+report.error.split('\n')[0]:''));
    }
  } finally { fs.rmSync(temporary,{recursive:true,force:true}); }
  if(reports.some(r=>r.status!=='passed'))process.exitCode=1;
})().catch(error=>{console.error(error);process.exitCode=1;});
