#!/usr/bin/env python3
"""Summarizes an editor timing recording (Settings > Editor > Record editor timing).

    macos/tools/editor_telemetry.py <profile>/telemetry/editor-<date>.jsonl [--timeline N]

For each scroll gesture (a real one, split at pauses of 300 ms, or one a
benchmark played), it reports how the editor kept up:

- input: wheel events, how long each waited for the main thread
- round trip: from a scroll message being sent to the first frame that applied
  it (Fresh's `ack`), to the main thread applying that frame, and to it being drawn
- Fresh: building and diffing each frame, bytes of earlier frames still queued
  for the socket ahead of it, frames sent ahead of it that the app had not yet
  applied, wheel lines still owed
- app: parsing, waiting for the main thread, applying, drawing
- position: how far the shown line trails the line the input asked for, in
  lines and in milliseconds, and how long the view keeps moving after the input
  stops

Gestures played into the benchmark's text view (tvpos/tvdraw records) get the
same position and drawing figures, as the baseline. --timeline N prints the
Nth gesture event by event.
"""
import json
import statistics
import sys

LINES_PER_STEP = 3  # Fresh's mouse_wheel_scroll_lines: one step of the grid's wheel is a notch


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(round(p / 100 * (len(values) - 1))))]


def fmt(values, unit='ms'):
    if not values:
        return '-'
    return f'p50 {pct(values, 50):.1f}  p95 {pct(values, 95):.1f}  max {max(values):.1f} {unit}'


def load(path):
    rows = []
    for line in open(path):
        line = line.strip()
        if line:
            rows.append(json.loads(line))
    rows.sort(key=lambda r: r['t'])
    return rows


def gestures(rows):
    """Split the recording into gestures: at each benchmark `gesture` record, or
    for real input, at a pause of 300 ms between wheel events."""
    marks = [r for r in rows if r['ev'] == 'gesture']
    out = []
    if marks:
        for i, mark in enumerate(marks):
            end = marks[i + 1]['t'] if i + 1 < len(marks) else float('inf')
            out.append((mark.get('to', 'editor'), mark, [r for r in rows if mark['t'] <= r['t'] < end]))
        return out
    wheels = [r for r in rows if r['ev'] == 'wheel']
    groups, current = [], []
    for w in wheels:
        if current and w['t'] - current[-1]['t'] > 300:
            groups.append(current)
            current = []
        current.append(w)
    if current:
        groups.append(current)
    for i, group in enumerate(groups):
        start = group[0]['t'] - 1
        end = groups[i + 1][0]['t'] - 1 if i + 1 < len(groups) else float('inf')
        out.append(('editor', {'t': start, 'speed': None}, [r for r in rows if start <= r['t'] < end]))
    return out


def shown_top_at(frames, t):
    """The top line shown at time t: the last frame applied by then."""
    top = None
    for f in frames:
        if f['applied'] <= t and f.get('top') is not None:
            top = f['top']
        elif f['applied'] > t:
            break
    return top


def editor_report(mark, seg, rows_before):
    wheels = [r for r in seg if r['ev'] == 'wheel']
    sends = [r for r in seg if r['ev'] == 'send' and str(r.get('kind', '')).startswith('scroll')]
    frames = [r for r in seg if r['ev'] == 'frame' and 'ack' in r]
    draws = [r for r in seg if r['ev'] == 'draw']
    if not wheels:
        return None
    first_input = min(r.get('et', r['t']) for r in wheels)
    last_input = max(r['t'] for r in wheels)
    start_frames = [r for r in rows_before if r['ev'] == 'frame' and r.get('top') is not None]
    start_top = start_frames[-1]['top'] if start_frames else (frames[0]['top'] if frames else 0)

    # The line the input has asked for by each wheel event (Fresh moves 3 lines per step).
    asked = []
    position = start_top
    for w in wheels:
        steps = w.get('steps', 0)
        position -= max(-8, min(8, steps)) * LINES_PER_STEP  # negative steps scroll down
        asked.append((w['t'], position))

    report = {}
    report['wheel events'] = len(wheels)
    report['main-thread delay of input'] = fmt([r['t'] - r['et'] for r in wheels if 'et' in r])
    report['scroll messages'] = len(sends)
    report['frames'] = f"{len(frames)} ({len(frames) / max(0.001, (frames[-1]['t'] - frames[0]['t']) / 1000):.0f}/s)" if len(frames) > 1 else len(frames)

    # Round trip, by Fresh's ack: the first frame built after the message was applied.
    to_frame, to_apply, to_draw = [], [], []
    for s in sends:
        frame = next((f for f in frames if f['ack'] >= s['n']), None)
        if not frame:
            continue
        to_frame.append(frame['t'] - s['t'])
        to_apply.append(frame['applied'] - s['t'])
        draw = next((d for d in draws if d['t'] >= frame['applied'] and d.get('seq', 0) >= frame['seq']), None)
        if draw:
            to_draw.append(draw['t'] + draw['ms'] - s['t'])
    report['send -> frame received'] = fmt(to_frame)
    report['send -> frame applied'] = fmt(to_apply)
    report['send -> frame drawn'] = fmt(to_draw)
    report['Fresh build'] = fmt([f['build'] for f in frames])
    report['Fresh diff+encode'] = fmt([f['diff'] for f in frames])
    report['frame size'] = fmt([f['bytes'] / 1024 for f in frames], 'KiB')
    if any('queued' in f for f in frames):
        report['queued ahead in Fresh'] = fmt([f.get('queued', 0) / 1024 for f in frames], 'KiB')
    if any('ahead' in f for f in frames):
        report['frames not yet applied ahead'] = f"max {max(f.get('ahead', 0) for f in frames)}"
    report['app parse'] = fmt([f['parse'] for f in frames])
    report['wait for main thread'] = fmt([f['applied'] - f['t'] for f in frames])
    report['app apply'] = fmt([f['apply'] for f in frames])
    report['draw'] = fmt([d['ms'] for d in draws]) + f'  ({len(draws)} draws)'
    report['lines owed by Fresh'] = f"max {max((f.get('owed', 0) for f in frames), default=0)}"

    # Position: how far the shown line trails the asked line, sampled at each wheel event.
    behind = []
    for t, line in asked:
        shown = shown_top_at(frames, t)
        if shown is not None:
            behind.append(abs(line - shown))
    report['lines behind the input'] = fmt(behind, 'lines')
    # In time: for each frame that moved the view, when its line was first asked for.
    down = asked[-1][1] >= start_top
    time_behind = []
    shown = start_top
    for f in frames:
        top = f.get('top')
        if top is None or top == shown:
            continue
        shown = top
        when = next((t for t, line in asked if line != start_top and (line >= top if down else line <= top)), None)
        if when is not None:
            time_behind.append(f['applied'] - when)
    report['shown line, after it was asked'] = fmt(time_behind)
    moving = [f for f in frames if f.get('top') is not None]
    final = moving[-1]['top'] if moving else start_top
    settled = next((f['applied'] for f in moving if f['top'] == final), None)
    report['lines asked / moved'] = f"{abs(asked[-1][1] - start_top)} / {abs(final - start_top)}"
    report['input time'] = f"{last_input - first_input:.0f} ms"
    report['moving after the last input'] = f"{(settled - last_input):.0f} ms" if settled else '-'
    return report


def textview_report(mark, seg):
    injects = [r for r in seg if r['ev'] == 'inject' and r.get('to') == 'textview']
    positions = [r for r in seg if r['ev'] == 'tvpos']
    draws = [r for r in seg if r['ev'] == 'tvdraw']
    if not injects or not positions:
        return None
    moving = [i for i in injects if i['dy'] != 0]
    # Each delivered event moves the view once, in order.
    delays = [p['t'] - i['t'] for i, p in zip(moving, positions)]
    report = {}
    report['wheel events'] = len(injects)
    report['event -> view moved'] = fmt(delays)
    report['draw'] = fmt([d['ms'] for d in draws]) + f'  ({len(draws)} draws)'
    report['lines moved'] = f"{abs(positions[-1]['top'] - positions[0]['top']):.0f}"
    report['input time'] = f"{injects[-1]['t'] - injects[0]['t']:.0f} ms"
    report['moving after the last input'] = f"{max(0, positions[-1]['t'] - injects[-1]['t']):.0f} ms"
    return report


def timeline(seg):
    t0 = seg[0]['t']
    for r in seg:
        if r['ev'] in ('inject', 'tvdraw'):
            continue
        fields = {k: v for k, v in r.items() if k not in ('ev', 't')}
        for key in ('et', 'applied'):
            if key in fields:
                fields[key] = round(fields[key] - t0, 1)
        print(f"{r['t'] - t0:8.1f}  {r['ev']:6}  {json.dumps(fields)}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(2)
    rows = load(sys.argv[1])
    found = gestures(rows)
    if '--timeline' in sys.argv:
        index = int(sys.argv[sys.argv.index('--timeline') + 1])
        timeline(found[index][2])
        return
    for i, (target, mark, seg) in enumerate(found):
        before = [r for r in rows if r['t'] < mark['t']]
        report = editor_report(mark, seg, before) if target == 'editor' else textview_report(mark, seg)
        if not report:
            continue
        speed = f", flick {mark['speed']:+.0f} pt/s" if mark.get('speed') else ''
        if mark.get('apply_ms'):
            speed += f", frames take {mark['apply_ms']:.0f} ms longer"
        if mark.get('applied') is False:
            speed += ', applied frames not reported'
        print(f"#{i} {target}{speed}")
        for key, value in report.items():
            print(f"  {key:34} {value}")
        print()


if __name__ == '__main__':
    main()
