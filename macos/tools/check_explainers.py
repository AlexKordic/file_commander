#!/usr/bin/env python3
"""Checks the explainer scripts without running the app.

- every file parses, has the required fields and a known chapter;
- every step has exactly one known action, and only known options;
- "@command" keys and command steps name commands from the catalog
  (app_model.cpp), and chords parse;
- every anchor a script points at is declared in the Swift sources
  (an .explainerAnchor("...") or a resolver prefix);
- conditions use known keys;
- coverage: every visible command is exercised or covered by an explainer.

Exit status 0 when everything holds; problems are printed one per line.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXPLAINERS = ROOT / 'macos/Sources/FileCommander/Explainers'
SWIFT = ROOT / 'macos/Sources'

RUNNER_STEPS = {'caption', 'uncaption', 'chapter', 'highlight', 'unhighlight', 'spotlight', 'unspotlight', 'stamp', 'point',
                'click', 'drag', 'keys', 'type', 'pause', 'wait', 'wait_not', 'expect', 'try'}
HOST_STEPS = {'open_tabs', 'navigate', 'focus', 'cursor', 'command', 'set_transfer_speed', 'set_preference', 'open_window',
              'close_window', 'front', 'dismiss_sheet', 'touch', 'crash', 'relaunch', 'editor_type', 'notice', 'editor_keys',
              'remove_bookmark', 'remember', 'run_script'}
OPTIONS = {'hold', 'timeout', 'gap', 'ms', 'as_job', 'sub', 'nth', 'approach_ms', 'speed', 'note', 'id', 'presentation'}
CONDITIONS = {'all', 'any', 'not', 'rows', 'listing', 'selected', 'cursor', 'path', 'filter', 'loaded', 'loading', 'tabs', 'focused',
              'single', 'sort', 'columns', 'sheet', 'palette', 'glob', 'text_focus', 'anchor', 'job', 'running_job', 'queued_at_least',
              'event', 'clipboard', 'hud', 'errors_at_least', 'no_errors', 'window', 'editor', 'bookmark', 'no_bookmark',
              'transfer_rate', 'file', 'theme', 'font_size', 'cursor_visible', 'menubar'}
RESOLVERS = ['pane.left.row', 'pane.right.row', 'editor.text', 'editor.tabs', 'editor.status', 'editor.palette', 'editor.popup',
             'editor.explorer']
NAMED_KEYS = {f'F{n}' for n in range(1, 13)} | {'Enter', 'Esc', 'Tab', 'Space', 'Backspace', 'Delete', 'Up', 'Down', 'Left',
                                               'Right', 'Home', 'End', 'PageUp', 'PageDown', 'Return', 'Escape'}
MODIFIERS = {'ctrl', 'control', 'opt', 'option', 'alt', 'shift', 'cmd', 'command'}


def commands():
    text = (ROOT / 'app_model.cpp').read_text()
    out = {}
    for match in re.finditer(r'\{"(\w+)", "([^"]*)", "(\w+)", "(\w+)", "(\w*)", "([^"]*)", "([^"]*)", "[^"]*"(, true)?\}', text):
        out[match.group(1)] = {'hidden': bool(match.group(8))}
    return out


def swift_literals(text):
    """The string arguments of .explainerAnchor("..."), with interpolations as None parts."""
    marker = 'explainerAnchor("'
    at = text.find(marker)
    while at >= 0:
        i = at + len(marker)
        parts, current = [], ''
        while i < len(text) and text[i] != '"':
            if text.startswith('\\(', i):
                parts.append(current)
                current = ''
                depth, i = 1, i + 2
                while i < len(text) and depth:
                    depth += {'(': 1, ')': -1}.get(text[i], 0)
                    i += 1
                parts.append(None)
                continue
            current += text[i]
            i += 1
        parts.append(current)
        yield parts
        at = text.find(marker, i)


def anchor_patterns():
    patterns = []
    for path in SWIFT.rglob('*.swift'):
        for parts in swift_literals(path.read_text()):
            regex = ''.join('[^\\]]+' if part is None else re.escape(part) for part in parts)
            patterns.append(re.compile('^' + regex + '$'))
    return patterns


def chord_ok(chord):
    if chord.startswith('@'):
        return True
    if chord == '+':
        return True
    parts = chord[:-2].split('+') + ['+'] if chord.endswith('++') else chord.split('+')
    *mods, key = parts
    return all(m.lower() in MODIFIERS for m in mods) and (len(key) == 1 or key in NAMED_KEYS)


def main():
    problems = []
    catalog = commands()
    if not catalog:
        print('no commands parsed from app_model.cpp')
        return 1
    patterns = anchor_patterns()
    chapters = {c['id'] for c in json.loads((EXPLAINERS / 'chapters.json').read_text())}
    exercised = set()
    orders = {}
    action_ids, presentation_ids = set(), set()

    def anchor(script, where, raw):
        name = raw.replace('pane.focused', 'pane.left').replace('pane.other', 'pane.right')
        if any(name.startswith(prefix) for prefix in RESOLVERS):
            return
        if not any(p.match(name) for p in patterns):
            problems.append(f'{script}: {where}: unknown anchor {raw}')

    def condition(script, where, cond):
        if isinstance(cond, bool) or cond is None:
            return
        if not isinstance(cond, dict) or len(cond) != 1:
            problems.append(f'{script}: {where}: a condition needs exactly one key: {cond}')
            return
        (key, value), = cond.items()
        if key not in CONDITIONS:
            problems.append(f'{script}: {where}: unknown condition {key}')
        if key in ('all', 'any'):
            for c in value:
                condition(script, where, c)
        if key == 'not':
            condition(script, where, value)
        if key == 'anchor':
            anchor(script, where, value)

    def step(script, index, s):
        where = f'step {index + 1}'
        identity = s.get('id')
        if identity is not None:
            if not isinstance(identity, str) or not re.fullmatch(r'[a-zA-Z0-9_.-]+', identity):
                problems.append(f'{script}: {where}: invalid or duplicate action id {identity}')
            elif identity in action_ids:
                problems.append(f'{script}: {where}: duplicate action id {identity}')
            else:
                action_ids.add(identity)
        if 'presentation' in s:
            p = s['presentation']
            if not isinstance(p, dict) or not isinstance(p.get('id'), str) or not re.fullmatch(r'[a-zA-Z0-9_.-]+', p['id']):
                problems.append(f'{script}: {where}: presentation needs a filename-safe id')
            else:
                if p['id'] in presentation_ids:
                    problems.append(f'{script}: {where}: duplicate presentation id {p["id"]}')
                presentation_ids.add(p['id'])
            if not isinstance(p, dict) or not p.get('title') or not p.get('narration'):
                problems.append(f'{script}: {where}: presentation needs a title and spoken narration')
        actions = [k for k in s if k not in OPTIONS]
        if len(actions) != 1:
            problems.append(f'{script}: {where}: needs exactly one action, has {actions}')
            return
        action = actions[0]
        value = s[action]
        unknown_options = [k for k in s if k in OPTIONS and k == action]
        if action not in RUNNER_STEPS | HOST_STEPS:
            problems.append(f'{script}: {where}: unknown step {action}')
        if action in ('keys', 'editor_keys'):
            for chord in value:
                if not chord_ok(chord):
                    problems.append(f'{script}: {where}: bad key {chord}')
                if chord.startswith('@'):
                    command = chord[1:]
                    if command not in catalog:
                        problems.append(f'{script}: {where}: unknown command {command}')
                    exercised.add(command)
        if action == 'command':
            if value not in catalog:
                problems.append(f'{script}: {where}: unknown command {value}')
            exercised.add(value)
        if action in ('highlight', 'click', 'point', 'spotlight'):
            for a in value if isinstance(value, list) else [value]:
                anchor(script, where, a)
        if action == 'drag':
            anchor(script, where, value['from'])
            anchor(script, where, value['to'])
        if action in ('wait', 'wait_not', 'expect'):
            condition(script, where, value)
        if action == 'try':
            for a in ([value['hint']] if isinstance(value.get('hint'), str) else value.get('hint', [])):
                anchor(script, where, a)
            condition(script, where, value.get('accept'))
            for i, inner in enumerate(value.get('show', [])):
                step(script, index, inner)
        if action == 'crash':
            exercised.add('simulate_crash')
        if action == 'run_script':
            exercised.add('run_script')
        del unknown_options

    files = sorted(p for p in EXPLAINERS.glob('*.json') if p.name != 'chapters.json')
    for path in files:
        try:
            script = json.loads(path.read_text())
        except json.JSONDecodeError as error:
            problems.append(f'{path.name}: {error}')
            continue
        sid = script.get('id', path.stem)
        if sid != path.stem:
            problems.append(f'{path.name}: id {sid} differs from the file name')
        for field in ('id', 'title', 'summary', 'chapter', 'order', 'steps'):
            if field not in script:
                problems.append(f'{sid}: missing {field}')
        if script.get('chapter') not in chapters:
            problems.append(f'{sid}: unknown chapter {script.get("chapter")}')
        if script.get('order') in orders:
            problems.append(f'{sid}: order {script["order"]} already used by {orders[script["order"]]}')
        orders[script.get('order')] = sid
        for command in script.get('covers', {}).get('commands', []):
            if command not in catalog:
                problems.append(f'{sid}: covers unknown command {command}')
            exercised.add(command)
        for a in script.get('covers', {}).get('anchors', []):
            anchor(sid, 'covers', a)
        for index, s in enumerate(script.get('steps', [])):
            step(sid, index, s)

    missing = sorted(c for c, info in catalog.items() if not info['hidden'] and c not in exercised)
    for command in missing:
        problems.append(f'coverage: no explainer covers {command}')
    for problem in problems:
        print(problem)
    print(f'{len(files)} explainers, {len(catalog)} commands, {len(problems)} problems')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
