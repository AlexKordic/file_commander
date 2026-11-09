"""Attach stable recording metadata to an existing lesson without changing actions."""
import copy
import hashlib
import json
import re

from .core import slug

OPTIONS = {'hold', 'timeout', 'gap', 'ms', 'as_job', 'sub', 'nth', 'approach_ms', 'speed', 'note', 'id', 'presentation'}


def spoken(text):
    replacements = {'SSH': 'S S H', 'SIGKILL': 'sig kill', 'Lua': 'Loo ah', '⌘': 'Command ', '⌃': 'Control ', '⌥': 'Option ', '⇧': 'Shift ', 'MiB': 'mebibytes'}
    for source, target in replacements.items():
        text = text.replace(source, target)
    names = {1: 'one', 2: 'two', 3: 'three', 4: 'four', 5: 'five', 6: 'six', 7: 'seven', 8: 'eight', 9: 'nine', 10: 'ten', 11: 'eleven', 12: 'twelve'}
    text = re.sub(r'\bF(1[0-2]|[1-9])\b', lambda match: 'F ' + names[int(match[1])], text)
    return text.strip().rstrip('.!?') + '.'


def with_presentations(lesson, narration=None, speech_transform=None):
    """IDs derive from content, not list position; explicit authored IDs win.

    A content edit can intentionally introduce a new identity. Identical repeated
    actions get occurrence suffixes; moving unrelated actions preserves IDs.
    ``narration`` lets a host author natural speech independently of captions.
    """
    lesson = copy.deepcopy(lesson)
    narration = narration or {}
    speak = speech_transform or spoken
    occurrences, presentations = {}, set()
    for index, step in enumerate(lesson['steps']):
        action = next(key for key in step if key not in OPTIONS)
        material = {key: value for key, value in step.items() if key not in ('id', 'presentation')}
        fingerprint = hashlib.sha256(json.dumps(material, sort_keys=True, ensure_ascii=False).encode()).hexdigest()[:10]
        occurrences[fingerprint] = occurrences.get(fingerprint, 0) + 1
        step.setdefault('id', f'{lesson["id"]}.a-{fingerprint}-{occurrences[fingerprint]}')
        if action == 'caption':
            value = step['caption']
            title = value if isinstance(value, str) else value.get('title', '')
            subtitle = step.get('sub', '') if isinstance(value, str) else value.get('sub', '')
            identity = lesson['id'] + '.' + slug(title).lower()
            original, suffix = identity, 1
            while identity in presentations:
                suffix += 1; identity = original + f'-{suffix}'
            presentations.add(identity)
            speech = narration.get(identity, f'{title}. {subtitle}'.strip())
            step.setdefault('presentation', dict(id=identity, title=title, narration=speak(speech), trailing_hold=.35, lead_in=.12))
        elif index == 0:
            identity = lesson['id'] + '.introduction'
            presentations.add(identity)
            step.setdefault('presentation', dict(id=identity, title=lesson['title'],
                                                narration=speak(narration.get(identity, lesson.get('summary') or lesson['title'])),
                                                trailing_hold=.35, lead_in=.12))
    return lesson
