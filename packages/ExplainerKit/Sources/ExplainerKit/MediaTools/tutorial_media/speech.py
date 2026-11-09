"""Local speech and imported narration, cached by content and provider settings."""
from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import wave

from . import SCHEMA
from .core import MediaError, NS, asset, digest, read_json, write_json, load_catalog


def executable(name):
    path = shutil.which(name)
    if not path:
        raise MediaError(f'{name} is required for tutorial export; install it or add it to PATH')
    return path


def run(command, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode:
        raise MediaError(f'{Path(command[0]).name} failed ({result.returncode}): {result.stderr[-4000:]}')
    return result


def pcm_duration(path):
    with wave.open(str(path), 'rb') as audio:
        if audio.getframerate() != 48000 or audio.getsampwidth() != 2 or audio.getnchannels() != 1:
            raise MediaError(f'Expected normalized 48 kHz mono 16-bit PCM: {path}')
        if not audio.getnframes():
            raise MediaError(f'Empty narration clip: {path}')
        return round(audio.getnframes() * NS / 48000)


class SayProvider:
    """macOS's on-device stock speech engine. No cloud credentials or microphone."""
    name = 'macos-say'

    def __init__(self, voice=None, rate=180, language='en'):
        self.binary = '/usr/bin/say'
        if not Path(self.binary).exists():
            raise MediaError('Local macOS speech is unavailable; supply imported recordings')
        voices = []
        for line in run([self.binary, '-v', '?']).stdout.splitlines():
            match = re.match(r'(.+?)\s+([a-z]{2,3}_[A-Z]{2})\s+#', line)
            if match:
                voices.append((match[1].strip(), match[2]))
        if voice:
            selected = next((entry for entry in voices if entry[0] == voice), None)
        else:
            matching = [entry for entry in voices if entry[1].replace('_', '-').lower().startswith(language.lower())]
            selected = next((entry for entry in matching if entry[0] == 'Samantha'), matching[0] if matching else None)
        if not selected:
            raise MediaError(f'No installed voice matches {voice or language}; use say -v "?" to list voices')
        self.voice, self.locale = selected
        self.rate, self.language = rate, language
        if not 80 <= rate <= 300:
            raise MediaError('Speech rate must be between 80 and 300 words per minute')
        self.version = run(['/usr/bin/sw_vers', '-productVersion']).stdout.strip()

    @property
    def settings(self):
        return dict(provider=self.name, version=self.version, voice=self.voice, locale=self.locale,
                    language=self.language, rate=self.rate, normalization='loudnorm-I-18-TP-1.5-LRA7-v1',
                    format='pcm-s16le-mono-48000')

    def render(self, text, output):
        source = output.with_suffix('.txt')
        source.write_text(text)
        raw = output.with_suffix('.aiff')
        command = [self.binary, '-r', str(self.rate), '-f', str(source), '-o', str(raw)]
        if self.voice:
            command += ['-v', self.voice]
        run(command, timeout=max(60, len(text)))
        normalize(raw, output)
        source.unlink()
        raw.unlink()


def normalize(source, output):
    # Keep the normalized PCM as an editable, provider-independent source.
    run([executable('ffmpeg'), '-v', 'error', '-nostdin', '-y', '-i', str(source),
         '-af', 'loudnorm=I=-18:TP=-1.5:LRA=7', '-ar', '48000', '-ac', '1', '-c:a', 'pcm_s16le', str(output)], timeout=120)


def prepare(catalog, root, selected=None, voice=None, rate=180, imported=None, language='en'):
    """Render authored presentation text, or normalize user-supplied WAVs.

    The generic catalog is a JSON list of lessons or a directory containing the
    host's lesson JSON files. No host actions are executed by this function.
    """
    root, catalog = Path(root).resolve(), Path(catalog)
    lessons, _ = load_catalog(catalog)
    if selected:
        requested = set(selected)
        available = {lesson['id'] for lesson in lessons}
        if requested - available:
            raise MediaError(f'Unknown lessons: {sorted(requested - available)}')
        lessons = [lesson for lesson in lessons if lesson['id'] in requested]
    imported_root = Path(imported).resolve() if imported else None
    provider = None if imported_root else SayProvider(voice, rate, language)
    settings = (dict(provider='imported', language=language, normalization='loudnorm-I-18-TP-1.5-LRA7-v1',
                     format='pcm-s16le-mono-48000') if imported_root else provider.settings)
    clips, identities = {}, set()
    folder = root / 'narration/clips'
    folder.mkdir(parents=True, exist_ok=True)
    previous = read_json(root / 'narration/script.json') if (root / 'narration/script.json').exists() else {}
    for lesson in lessons:
        for step in lesson.get('steps', []):
            presentation = step.get('presentation')
            if not presentation:
                continue
            identity = presentation.get('id') or step.get('id')
            text = presentation.get('narration', '').strip()
            if not identity or identity in identities or not text:
                raise MediaError(f'Each narrated segment needs unique id and text: {identity}')
            identities.add(identity)
            source = asset(imported_root, identity + '.wav') if imported_root else None
            cache = dict(text=text, **settings)
            if source:
                cache['source_sha256'] = digest(source)
            key = hashlib.sha256(json.dumps(cache, sort_keys=True).encode()).hexdigest()
            output = folder / (key + '.wav')
            if output.exists():
                old = previous.get('clips', {}).get(identity)
                if old and old.get('cache_key') == key and old.get('sha256') != digest(output):
                    raise MediaError(f'Cached narration was modified: {identity}; remove the corrupt clip before retrying')
                pcm_duration(output)
            else:
                temporary = output.with_name(key + '.partial.wav')
                try:
                    if source:
                        normalize(source, temporary)
                    else:
                        provider.render(text, temporary)
                    pcm_duration(temporary)
                    temporary.replace(output)
                finally:
                    temporary.unlink(missing_ok=True)
            clips[identity] = dict(id=identity, lesson=lesson['id'], title=presentation.get('title', lesson['title']),
                                   text=text, path=str(output.relative_to(root)), duration_ns=pcm_duration(output),
                                   sha256=digest(output), cache_key=key, **settings)
            print(f'Narration: {identity} ({clips[identity]["duration_ns"] / NS:.2f}s)', flush=True)
    if not clips:
        raise MediaError('No authored presentation narration found in selected lessons')
    result = dict(schema=SCHEMA, language=language, settings=settings, clips=clips,
                  lessons=[lesson['id'] for lesson in lessons])
    write_json(root / 'narration/script.json', result)
    return result
