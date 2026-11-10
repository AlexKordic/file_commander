'use strict';
// Tutorial player: replays the recorded movie by chapter, lesson and step. It only seeks and plays media; it never runs application commands.
(() => {
  const $ = id => document.getElementById(id);
  const source = window.tutorialTimeline;
  if (!source || !Array.isArray(source.steps) || !source.steps.length) {
    $('problem-title').textContent = 'The lessons did not load';
    $('problem-text').textContent = 'timeline.js is missing or empty. Reload the page to try again.';
    $('problem').hidden = false;
    return;
  }

  const NS = 1e9, PLAY = 'M5 3.2v9.6l7.6-4.8z', PAUSE = 'M4.5 3.5h2.6v9H4.5zM8.9 3.5h2.6v9H8.9z';
  // In the recording a step's own caption card needs this long to replace the card of the step before it.
  const LEAD = 0.4;
  const video = $('video'), win = $('window'), timeline = $('timeline'), track = $('track'), search = $('search');
  const media = source.media || {}, duration = source.duration_ns / NS, fps = source.fps || 30;

  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = text;
    return node;
  }

  // Model: chapters hold lessons, lessons hold steps, and every time is in seconds.
  const chapters = source.chapters.map((c, index) => ({id: c.id, title: c.title, start: c.start_ns / NS, end: c.end_ns / NS, index}));
  const chapterOf = new Map(chapters.map(chapter => [chapter.id, chapter]));
  const lessons = source.lessons.map((l, index) => ({id: l.id, title: l.title, chapter: chapterOf.get(l.chapter) || chapters[0], start: l.start_ns / NS, end: l.end_ns / NS, index, steps: []}));
  const lessonOf = new Map(lessons.map(lesson => [lesson.id, lesson]));
  const steps = [];
  for (const s of source.steps) {
    const lesson = lessonOf.get(s.lesson);
    if (!lesson) continue;
    const step = {id: s.id, title: s.title, text: s.text || '', start: s.start_ns / NS, end: s.end_ns / NS, lesson, index: steps.length};
    // Most narration opens by repeating the step's title; the page shows the title once.
    step.body = step.text.startsWith(`${step.title}.`) ? step.text.slice(step.title.length + 1).trim() : step.text;
    step.number = lesson.steps.push(step);
    steps.push(step);
  }
  const stepOf = new Map(steps.map(step => [step.id, step]));
  // A lesson opens with a step that carries its own title: that step's text introduces the lesson.
  for (const lesson of lessons) lesson.summary = lesson.steps[0] && lesson.steps[0].title === lesson.title ? lesson.steps[0].body : '';

  // The step showing at a time: the last one that has started. The moment before a lesson's first step already belongs to that lesson.
  function indexAt(time) {
    let found = 0;
    for (const step of steps) {
      if (time < (step.number === 1 ? Math.min(step.start, step.lesson.start) : step.start)) break;
      found = step.index;
    }
    return found;
  }

  // Words
  function clock(seconds) {
    const whole = Math.max(0, Math.floor(seconds));
    return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, '0')}`;
  }
  function span(seconds) {
    const whole = Math.round(seconds), minutes = Math.floor(whole / 60), rest = whole % 60;
    if (whole < 10) return `${Number(seconds.toFixed(1))} s`;
    return minutes ? (rest ? `${minutes} min ${rest} s` : `${minutes} min`) : `${rest} s`;
  }
  const count = (number, word) => `${number} ${word}${number === 1 ? '' : 's'}`;
  const sentence = title => /[.!?:…]$/.test(title) ? title : `${title}.`;
  const part = time => `${(Math.max(0, Math.min(duration, time)) / duration * 100).toFixed(3)}%`;

  // Choices persist per browser; the page works the same when storage is refused.
  const saved = {
    get(key) { try { return localStorage.getItem(`fc-tutorial.${key}`); } catch { return null; } },
    set(key, value) { try { localStorage.setItem(`fc-tutorial.${key}`, value); } catch {} },
  };

  let current = -1, touched = false, stepMode = saved.get('pace') === 'step';

  // Playback state. A generation number retires older requests, so a slow seek cannot take over from a newer one.
  // finished is the step that played to its end and stopped there; shown is the step that is on screen without playing.
  let generation = 0, boundary = null, finished = null, shown = null, wanted = null, intent = false, ownSeek = false, ownPause = 0;
  let frameCallback = null, guardTimer = null, readyPromise = null, lastBoundaryStop = null, noticeTimer = null;
  let scrub = null, scrubWanted = null, scrubBusy = false;

  // The parts that never change: title, chapters, the marks of the timeline and the recording's facts.
  $('title').textContent = document.title = source.title;
  $('summary').textContent = `${count(lessons.length, 'lesson')} · ${count(steps.length, 'step')} · ${span(duration)}`;
  $('length').textContent = ` / ${clock(duration)}`;
  timeline.setAttribute('aria-valuemax', duration.toFixed(1));
  $('frame').style.setProperty('--ratio', String((media.width || source.width) / (media.height || source.height)));
  // A recording without narration has a silent sound track; muted, it may start without waiting for a click.
  if (media.silent) video.muted = true;
  for (const chapter of chapters) {
    const button = el('button', '', chapter.title), name = el('span', '', chapter.title);
    button.type = 'button';
    button.dataset.chapter = name.dataset.chapter = chapter.id;
    button.addEventListener('click', () => choose(chapter.start));
    name.style.flexGrow = String(chapter.end - chapter.start);
    $('chapters').append(button);
    $('chapter-labels').append(name);
  }
  for (const lesson of lessons.slice(1)) {
    const mark = el('i', lesson.chapter === lessons[lesson.index - 1].chapter ? '' : 'chapter');
    mark.style.left = part(lesson.start);
    $('marks').append(mark);
  }
  const facts = [['Length', span(duration)], ['Lessons', String(lessons.length)], ['Steps', String(steps.length)]];
  if (media.width) facts.push(['Picture', `${media.width} × ${media.height}`]);
  facts.push(['Sound', media.silent ? 'None, captions only' : 'Narration']);
  if (media.bytes) facts.push(['Download', `${(media.bytes / 1e6).toFixed(1)} MB`]);
  if (media.recorded) facts.push(['Recorded', new Date(`${media.recorded}T12:00:00`).toLocaleDateString('en', {year: 'numeric', month: 'short', day: 'numeric'})]);
  for (const [name, value] of facts) $('recording').append(el('dt', '', name), el('dd', '', value));

  // Lessons: the source list, grouped by chapter and filtered by the search field.
  function match(lesson, words) {
    const whole = {time: lesson.start, note: `${count(lesson.steps.length, 'step')} · ${span(lesson.end - lesson.start)}`};
    const has = text => words.every(word => text.toLowerCase().includes(word));
    if (!words.length || has(`${lesson.title} ${lesson.chapter.title}`)) return whole;
    // A lesson found through its steps opens at the first step that matches.
    const hits = lesson.steps.filter(step => has(`${step.title} ${step.text}`));
    if (!hits.length) return null;
    return {time: hits[0].start, index: hits[0].index, note: hits.length > 1 ? `${hits[0].title} and ${hits.length - 1} more` : hits[0].title};
  }
  function renderLessons() {
    const list = $('lessons'), query = search.value.trim(), words = query.toLowerCase().split(/\s+/).filter(Boolean);
    let shown = 0, group = null;
    list.replaceChildren();
    for (const lesson of lessons) {
      const hit = match(lesson, words);
      if (!hit) continue;
      if (lesson.chapter !== group) list.append(el('div', 'group-label', (group = lesson.chapter).title));
      const row = el('div', 'source'), button = el('button', 'source-open'), sub = el('span', 'source-sub');
      row.setAttribute('role', 'listitem');
      row.dataset.lesson = lesson.id;
      button.type = 'button';
      button.append(el('span', 'source-name named', lesson.title));
      button.addEventListener('click', () => choose(hit.time, hit.index));
      sub.append(el('span', 'meta', hit.note));
      row.append(button, el('span', 'source-time', clock(hit.time)), sub);
      list.append(row);
      shown++;
    }
    if (!shown) list.append(el('p', 'sidebar-empty', `No lesson or step matches “${query}”. Try a shorter word.`));
    $('lesson-count').textContent = words.length ? `${shown} of ${count(lessons.length, 'lesson')}` : `${count(lessons.length, 'lesson')} · ${count(steps.length, 'step')}`;
    markLesson();
  }
  // Scrolls a list just enough to show a row, and leaves it alone while the pointer is reading it.
  function reveal(list, row, top = 0) {
    if (list.scrollHeight <= list.clientHeight || list.matches(':hover')) return;
    const outer = list.getBoundingClientRect(), box = row.getBoundingClientRect();
    if (box.top < outer.top + top) list.scrollTop -= outer.top + top - box.top;
    else if (box.bottom > outer.bottom) list.scrollTop += box.bottom - outer.bottom + 4;
  }
  // One tab stop per list: the current row, or the first when the current one is filtered away.
  function markRows(list, rows, isCurrent, top) {
    let stop = null;
    for (const row of rows) {
      const button = row.querySelector('button'), on = isCurrent(row);
      if (on) button.setAttribute('aria-current', 'true'); else button.removeAttribute('aria-current');
      button.tabIndex = -1;
      if (on) { stop = button; reveal(list, row, top); }
    }
    if (!stop && rows.length) stop = rows[0].querySelector('button');
    if (stop) stop.tabIndex = 0;
  }
  function markLesson() {
    const lesson = steps[current] && steps[current].lesson, rows = [...$('lessons').querySelectorAll('.source')];
    for (const row of rows) row.classList.toggle('current', !!lesson && row.dataset.lesson === lesson.id);
    markRows($('lessons'), rows, row => row.classList.contains('current'), 30);
  }
  function showLesson(lesson) {
    const list = $('steps');
    $('lesson-title').textContent = lesson.title;
    $('lesson-summary').textContent = lesson.summary || `${lesson.chapter.title} · ${count(lesson.steps.length, 'step')} · ${span(lesson.end - lesson.start)}`;
    $('step-count').textContent = `(${lesson.steps.length})`;
    list.replaceChildren();
    list.scrollTop = 0;
    for (const step of lesson.steps) {
      const row = el('li'), button = el('button');
      button.type = 'button';
      button.dataset.step = step.id;
      button.append(el('time', '', clock(step.start)), el('span', 'label', step.title));
      if (step.body) button.append(el('span', 'step-text', step.body));
      button.addEventListener('click', () => choose(step.start, step.index));
      row.append(button);
      list.append(row);
    }
    for (const button of $('chapters').children) {
      const on = button.dataset.chapter === lesson.chapter.id;
      button.classList.toggle('active', on);
      button.setAttribute('aria-pressed', String(on));
    }
    for (const name of $('chapter-labels').children) name.classList.toggle('current', name.dataset.chapter === lesson.chapter.id);
    markLesson();
    if (touched) document.title = `${lesson.title} · ${source.title}`;
  }

  // Selection: the step whose caption, list row and lesson the page shows.
  function select(index) {
    index = Math.max(0, Math.min(steps.length - 1, index));
    if (index === current) return;
    const before = steps[current], step = steps[index];
    current = index;
    if (!before || before.lesson !== step.lesson) showLesson(step.lesson);
    $('caption').replaceChildren(el('b', '', step.body ? sentence(step.title) : step.title), step.body ? ` ${step.body}` : '');
    markRows($('steps'), [...$('steps').children], row => row.firstChild.dataset.step === step.id);
    $('previous').disabled = index === 0;
    $('next').disabled = index === steps.length - 1;
    $('where').textContent = `Lesson ${step.lesson.index + 1} of ${lessons.length} · Step ${step.number} of ${step.lesson.steps.length}`;
    if (touched) remember();
    label();
  }
  function position(time) {
    const text = clock(time);
    $('done').style.width = $('knob').style.left = part(time);
    timeline.setAttribute('aria-valuenow', Math.max(0, Math.min(duration, time)).toFixed(1));
    if ($('clock').textContent !== text) $('clock').textContent = text;
    if (steps[current]) timeline.setAttribute('aria-valuetext', `${text} of ${clock(duration)}, ${steps[current].lesson.title}: ${steps[current].title}`);
  }
  // The address always names the current step, without adding to the browser's history.
  function remember() {
    try { history.replaceState(null, '', `#${new URLSearchParams({step: steps[current].id})}`); } catch {}
  }
  function fromHash() {
    const query = new URLSearchParams(location.hash.slice(1)), step = stepOf.get(query.get('step'));
    const section = lessonOf.get(query.get('lesson')) || chapterOf.get(query.get('chapter')), seconds = Number(query.get('t'));
    if (step) return {time: step.start, index: step.index};
    if (section) return {time: section.start};
    return query.has('t') && Number.isFinite(seconds) ? {time: Math.max(0, Math.min(duration, seconds))} : null;
  }

  function notice(text, alert = false) {
    $('notice-text').textContent = text;
    $('notice').setAttribute('role', alert ? 'alert' : 'status');
    $('notice').hidden = false;
    clearTimeout(noticeTimer);
    // Information leaves after four seconds; an alert stays until it is dismissed.
    if (!alert) noticeTimer = setTimeout(() => { $('notice').hidden = true; }, 4000);
  }
  function fail(error) {
    if (error && error.name === 'AbortError') return;
    setIntent(false);
    notice(error && error.name === 'NotAllowedError' ? 'The browser held playback back. Press Play to start it.' : (error && error.message) || String(error), true);
  }

  // Playback
  function label() {
    $('play-label').textContent = intent ? 'Pause' : finished !== null && steps[finished + 1] ? 'Continue' : 'Play';
    $('play-glyph').setAttribute('d', intent ? PAUSE : PLAY);
  }
  function setIntent(playing) { intent = playing; label(); }
  function cancelWatch() {
    if (frameCallback !== null && video.cancelVideoFrameCallback) video.cancelVideoFrameCallback(frameCallback);
    if (guardTimer !== null) clearInterval(guardTimer);
    frameCallback = guardTimer = null;
  }
  function checkBoundary(time) {
    if (!boundary || boundary.generation !== generation || time < boundary.end - 0.004) return;
    const observed = Math.max(time, video.currentTime), {start, end, index} = boundary;
    lastBoundaryStop = {target: end, observed, error_ms: (observed - end) * 1000, generation};
    boundary = null;
    finished = index;
    cancelWatch();
    video.pause();
    select(index);
    setIntent(false);
    // Park one frame before the end, so the picture still belongs to this step.
    ownSeek = true;
    video.currentTime = Math.max(start, end - 1 / fps);
  }
  // Frame callbacks stop on the exact frame; the timer covers browsers without them and frames that never come.
  function watch() {
    cancelWatch();
    const token = generation;
    function frame(_, metadata) {
      if (token !== generation) return;
      checkBoundary(metadata.mediaTime);
      if (!video.paused && token === generation) frameCallback = video.requestVideoFrameCallback(frame);
    }
    if (video.requestVideoFrameCallback) frameCallback = video.requestVideoFrameCallback(frame);
    guardTimer = setInterval(() => { if (token === generation) checkBoundary(video.currentTime); }, 20);
  }
  function ready() {
    if (video.readyState >= 1) return Promise.resolve();
    if (!readyPromise) {
      readyPromise = new Promise((resolve, reject) => {
        const timer = setTimeout(() => settle(new Error('The video did not load within 30 s. Reload the page to try again.')), 30000);
        const loaded = () => settle(), broken = () => settle(new Error('This browser could not load or decode the video.'));
        function settle(error) {
          clearTimeout(timer);
          video.removeEventListener('loadedmetadata', loaded);
          video.removeEventListener('error', broken);
          if (error) { readyPromise = null; reject(error); } else resolve();
        }
        video.addEventListener('loadedmetadata', loaded);
        video.addEventListener('error', broken);
        if (video.error) broken();
        // A browser that held the download back starts it once a position is asked for.
        else if (video.networkState !== HTMLMediaElement.NETWORK_LOADING) video.preload = 'auto';
      });
    }
    return readyPromise;
  }
  // Pauses for a seek without ending the viewer's wish to play.
  function hold() {
    if (video.paused) return;
    ownPause++;
    video.pause();
  }
  async function seek(time, token) {
    await ready();
    if (token !== generation) return false;
    hold();
    cancelWatch();
    const target = Math.max(0, Math.min(time, video.duration || duration));
    if (Math.abs(video.currentTime - target) < 0.001 && !video.seeking) return true;
    ownSeek = true;
    // From here on the picture is the place sought, in every browser, not the poster.
    video.removeAttribute('poster');
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => { video.removeEventListener('seeked', done); ownSeek = false; reject(new Error('Seeking timed out. Reload the page to try again.')); }, 10000);
      function done() { clearTimeout(timer); video.removeEventListener('seeked', done); ownSeek = false; resolve(); }
      video.addEventListener('seeked', done);
      video.currentTime = target;
    });
    return token === generation;
  }
  // In step mode playback stops at the end of the step it is in; from the pause between two steps it runs through the next one.
  function bound(time, token) {
    let step = steps[indexAt(time)];
    if (time >= step.end - 0.02 && steps[step.index + 1]) step = steps[step.index + 1];
    boundary = {generation: token, start: step.start, end: step.end, index: step.index};
  }
  // Every move goes through here: show the place at once, seek, then play or stay paused as the viewer had it.
  async function go(time, {play, index, bounded = false} = {}) {
    const token = ++generation, start = play === undefined ? intent : play;
    boundary = finished = shown = null;
    touched = true;
    select(index === undefined ? indexAt(time) : index);
    // A step that is shown without playing shows the picture with its own caption card, so the picture agrees with the text under it. Playing still starts at the step's start.
    if (!start && index !== undefined) {
      shown = current;
      time = Math.max(time, Math.min(steps[current].start + LEAD, steps[current].end - 1 / fps));
    }
    wanted = time;
    remember();
    position(place());
    label();
    try {
      // The first Play from the very start needs no seek, and playing at once keeps the click's permission to play.
      if ((video.readyState >= 1 || time > 0.001 || !start) && !await seek(time, token)) return;
      wanted = null;
      if (!start) { setIntent(false); return; }
      if (bounded) boundary = {generation: token, start: steps[current].start, end: steps[current].end, index: current};
      else if (stepMode) bound(time, token);
      setIntent(true);
      await video.play();
    } catch (error) {
      if (token !== generation) return;
      wanted = null;
      fail(error);
    }
  }
  const here = () => wanted !== null ? wanted : video.currentTime;
  // The time the page names: a step that is only shown counts from its start.
  const place = () => shown !== null ? steps[shown].start : here();
  function resume() {
    // After a step that stopped at its end, playing goes on with the next one; a step that was only shown plays from its start.
    if (finished !== null) return go(steps[finished + 1] ? steps[finished + 1].start : 0, {play: true});
    if (shown !== null) return go(steps[shown].start, {play: true, index: shown});
    return go(video.ended || here() >= duration - 0.05 ? 0 : here(), {play: true});
  }
  function pause() {
    if (wanted !== null) return go(wanted, {play: false});
    boundary = null;
    setIntent(false);
    video.pause();
  }
  const toggle = () => intent ? pause() : resume();
  const replay = () => go(steps[current].start, {play: true, index: current, bounded: true});
  function stepBy(delta) {
    const step = steps[current + delta];
    if (step) go(step.start, {index: step.index});
  }
  function lessonBy(delta) {
    const lesson = lessons[steps[current].lesson.index + delta];
    if (lesson) go(lesson.start);
  }
  // Choosing from a list plays from there, brings the video into view on a page that scrolls, and hands the keyboard to Play.
  function choose(time, index) {
    go(time, {play: true, index});
    const box = $('frame').getBoundingClientRect();
    if (box.top < 0 || box.bottom > innerHeight) $('stage').scrollIntoView({block: 'start'});
    $('play').focus({preventScroll: true});
  }

  video.addEventListener('play', () => { shown = null; watch(); setIntent(true); });
  video.addEventListener('pause', () => {
    cancelWatch();
    if (ownPause) ownPause--; else setIntent(false);
  });
  video.addEventListener('ended', () => { cancelWatch(); boundary = finished = null; setIntent(false); });
  video.addEventListener('seeked', () => {
    ownSeek = false;
    if (!scrub && wanted === null) position(place());
  });
  // A seek the page did not make, such as one from the system's own player, takes over from whatever was pending.
  video.addEventListener('seeking', () => {
    if (ownSeek) return;
    ++generation;
    boundary = finished = shown = wanted = null;
    cancelWatch();
    if (!video.paused) watch();
    label();
  });
  video.addEventListener('timeupdate', () => {
    const time = video.currentTime;
    checkBoundary(time);
    if (scrub || wanted !== null) return;
    if (finished === null && shown === null) select(indexAt(time));
    position(place());
  });
  video.addEventListener('loadedmetadata', () => {
    if (video.videoWidth && video.videoHeight) $('frame').style.setProperty('--ratio', String(video.videoWidth / video.videoHeight));
  });
  video.addEventListener('error', () => {
    const link = el('a', '', 'open the video file');
    link.href = video.currentSrc || 'tutorial.mp4';
    setIntent(false);
    $('problem-text').replaceChildren('This browser could not load or decode tutorial.mp4. Reload the page, or ', link, '.');
    $('problem').hidden = false;
  });
  video.addEventListener('click', toggle);
  video.addEventListener('dblclick', fullscreen);

  // Timeline: a click goes to the start of the step under it; a drag scans the movie and stays where it is let go.
  const timeAt = x => {
    const box = track.getBoundingClientRect();
    return Math.max(0, Math.min(1, (x - box.left) / box.width)) * duration;
  };
  function tip(x) {
    const time = timeAt(x), step = steps[indexAt(time)], node = $('tip'), box = timeline.getBoundingClientRect();
    $('tip-time').textContent = clock(time);
    $('tip-text').textContent = step.title === step.lesson.title ? step.title : `${step.lesson.title} · ${step.title}`;
    node.hidden = false;
    node.style.left = `${Math.max(0, Math.min(box.width - node.offsetWidth, x - box.left - node.offsetWidth / 2))}px`;
  }
  // Only the newest position of a drag is sought; the ones passed on the way are dropped.
  async function scrubSeek(time) {
    scrubWanted = time;
    if (scrubBusy) return;
    scrubBusy = true;
    try {
      while (scrub && scrubWanted !== null) {
        const target = scrubWanted, token = ++generation;
        scrubWanted = boundary = finished = shown = null;
        wanted = target;
        await seek(target, token);
      }
    } catch {} finally { scrubBusy = false; }
  }
  function release(event) {
    if (!scrub) return;
    const {keep, moved, last} = scrub, cancelled = event.type === 'pointercancel', time = timeAt(cancelled ? last : event.clientX);
    scrub = scrubWanted = null;
    timeline.classList.remove('scrubbing');
    if (cancelled || event.pointerType !== 'mouse') $('tip').hidden = true;
    if (moved) go(time, {play: keep});
    else if (!cancelled) go(steps[indexAt(time)].start, {play: keep, index: indexAt(time)});
  }
  timeline.addEventListener('pointerdown', event => {
    if (event.button) return;
    scrub = {keep: intent, x: event.clientX, last: event.clientX, moved: false};
    timeline.setPointerCapture(event.pointerId);
    timeline.classList.add('scrubbing');
    tip(event.clientX);
  });
  timeline.addEventListener('pointermove', event => {
    if (!scrub) { if (event.pointerType === 'mouse') tip(event.clientX); return; }
    if (!scrub.moved && Math.abs(event.clientX - scrub.x) < 3) return;
    const time = timeAt(event.clientX);
    scrub.moved = touched = true;
    scrub.last = event.clientX;
    tip(event.clientX);
    select(indexAt(time));
    position(time);
    scrubSeek(time);
  });
  timeline.addEventListener('pointerup', release);
  timeline.addEventListener('pointercancel', release);
  timeline.addEventListener('pointerleave', () => { if (!scrub) $('tip').hidden = true; });
  // The slider's unit is a step: arrows move by step everywhere on the page, and here the page keys move by lesson.
  timeline.addEventListener('keydown', event => {
    const moves = {ArrowUp: () => stepBy(1), ArrowDown: () => stepBy(-1), PageUp: () => lessonBy(1), PageDown: () => lessonBy(-1), Home: () => go(0), End: () => go(steps[steps.length - 1].start)};
    if (!moves[event.key] || event.ctrlKey || event.metaKey || event.altKey) return;
    moves[event.key]();
    event.preventDefault();
  });

  // Lists: the arrow keys move between rows, and Enter plays the row.
  for (const list of [$('lessons'), $('steps')]) {
    list.addEventListener('keydown', event => {
      const moves = {ArrowDown: 1, ArrowUp: -1, Home: -Infinity, End: Infinity};
      if (!(event.key in moves) || event.ctrlKey || event.metaKey || event.altKey) return;
      const rows = [...list.querySelectorAll('button')], at = rows.indexOf(document.activeElement);
      if (at < 0) return;
      rows[Math.max(0, Math.min(rows.length - 1, at + moves[event.key]))].focus();
      event.preventDefault();
    });
  }
  search.addEventListener('input', renderLessons);
  search.addEventListener('keydown', event => {
    if (event.key !== 'Escape' || !search.value) return;
    search.value = '';
    renderLessons();
    event.preventDefault();
  });

  // Keys of the page. Typing in a field stays typing, and Space on a button still presses that button.
  document.addEventListener('keydown', event => {
    const target = event.target, name = target.tagName;
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.altKey) return;
    if (name === 'TEXTAREA' || name === 'SELECT' || target.isContentEditable || name === 'INPUT' && target.type !== 'checkbox') return;
    switch (event.key) {
      case ' ': if (target.closest('button, a, input, summary')) return; toggle(); break;
      case 'k': case 'K': toggle(); break;
      case 'ArrowLeft': if (event.shiftKey) lessonBy(-1); else stepBy(-1); break;
      case 'ArrowRight': if (event.shiftKey) lessonBy(1); else stepBy(1); break;
      case 'r': case 'R': replay(); break;
      case 'f': case 'F': fullscreen(); break;
      case '/': search.focus(); search.select(); break;
      default: return;
    }
    event.preventDefault();
  });

  // Transport
  $('play').addEventListener('click', toggle);
  $('previous').addEventListener('click', () => stepBy(-1));
  $('next').addEventListener('click', () => stepBy(1));
  $('replay').addEventListener('click', replay);
  $('fullscreen').addEventListener('click', fullscreen);
  $('dismiss').addEventListener('click', () => { $('notice').hidden = true; });
  $('pace').checked = stepMode;
  $('pace').addEventListener('change', () => {
    stepMode = $('pace').checked;
    saved.set('pace', stepMode ? 'step' : 'through');
    // The change applies to the step that is playing.
    if (intent && wanted === null) { if (stepMode) bound(video.currentTime, generation); else boundary = null; }
  });
  const speed = Number(saved.get('speed'));
  if ([...$('speed').options].some(option => Number(option.value) === speed)) $('speed').value = String(speed);
  function applySpeed() { video.defaultPlaybackRate = video.playbackRate = Number($('speed').value); }
  applySpeed();
  $('speed').addEventListener('change', () => { applySpeed(); saved.set('speed', $('speed').value); });

  // Full screen shows the stage alone. A phone that can only show the video itself gets the captions drawn on it meanwhile.
  function fullscreen() {
    const stage = $('stage'), active = document.fullscreenElement || document.webkitFullscreenElement;
    if (active) return (document.exitFullscreen || document.webkitExitFullscreen).call(document);
    if (stage.requestFullscreen) return stage.requestFullscreen().catch(fail);
    if (stage.webkitRequestFullscreen) return stage.webkitRequestFullscreen();
    if (!video.webkitEnterFullscreen) return notice('This browser has no full screen for pages.');
    for (const text of video.textTracks) text.mode = 'showing';
    video.webkitEnterFullscreen();
  }
  video.addEventListener('webkitendfullscreen', () => { for (const text of video.textTracks) text.mode = 'disabled'; });
  function fullscreenChanged() {
    const name = document.fullscreenElement || document.webkitFullscreenElement ? 'Leave full screen' : 'Full screen';
    $('fullscreen').title = `${name} (F)`;
    $('fullscreen').setAttribute('aria-label', name);
  }
  document.addEventListener('fullscreenchange', fullscreenChanged);
  document.addEventListener('webkitfullscreenchange', fullscreenChanged);

  $('copy-link').addEventListener('click', async () => {
    const step = steps[current], link = new URL(location.href);
    link.hash = String(new URLSearchParams({step: step.id}));
    try {
      await navigator.clipboard.writeText(link.href);
      notice(`Link to “${step.title}” copied.`);
    } catch {
      // The address bar then carries the same link.
      touched = true;
      remember();
      notice('This browser did not allow copying. The address bar now holds the link to this step.', true);
    }
  });

  // Panes: below 1180 px the inspector is opened by its button, above it is closed by it; both choices persist.
  const narrow = matchMedia('(max-width: 1179.98px)');
  function markPanes() {
    $('toggle-sidebar').setAttribute('aria-pressed', String(!win.classList.contains('no-sidebar')));
    $('toggle-inspector').setAttribute('aria-pressed', String(narrow.matches ? win.classList.contains('show-inspector') : !win.classList.contains('no-inspector')));
  }
  win.classList.toggle('no-sidebar', saved.get('lessons') === 'hidden');
  win.classList.toggle('no-inspector', saved.get('steps') === 'hidden');
  win.classList.toggle('show-inspector', saved.get('steps-narrow') === 'shown');
  $('toggle-sidebar').addEventListener('click', () => {
    saved.set('lessons', win.classList.toggle('no-sidebar') ? 'hidden' : 'shown');
    markPanes();
  });
  $('toggle-inspector').addEventListener('click', () => {
    if (narrow.matches) saved.set('steps-narrow', win.classList.toggle('show-inspector') ? 'shown' : 'hidden');
    else saved.set('steps', win.classList.toggle('no-inspector') ? 'hidden' : 'shown');
    markPanes();
  });
  narrow.addEventListener('change', markPanes);
  markPanes();

  // Start: the first step, or the place the address names. A link never starts playback by itself.
  renderLessons();
  select(0);
  position(0);
  label();
  function follow() {
    const target = fromHash();
    if (target) go(target.time, {play: intent, index: target.index});
  }
  follow();
  window.addEventListener('hashchange', follow);
  window.addEventListener('pagehide', cancelWatch);

  // Read-only diagnostics and explicit controls for automated browser checks.
  window.tutorialPlayer = {
    data: source, ready,
    playStep: id => go(stepOf.get(id).start, {play: true, index: stepOf.get(id).index, bounded: true}),
    jump: time => go(time, {play: true}),
    get selected() { return steps[current] && steps[current].id; },
    get playing() { return intent; },
    get boundary() { return boundary; },
    get lastBoundaryStop() { return lastBoundaryStop; },
  };
})();
