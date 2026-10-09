"""Fail-closed qualification checks, independent of the build's CTest registry."""
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import re
import tarfile


def required_tests(repo):
    manifest = json.loads((repo / 'test/release_required.json').read_text())
    names = set(manifest['standalone'])
    for group, cases in manifest['groups'].items():
        names.update(f'fc.{group}.{case}' for case in cases)
    names.update('fc.command.' + name for name in re.findall(
        r'^FC_COMMAND_CASE\(([a-z_]+)\)', (repo / 'test/command_cases.inc').read_text(), re.M))
    names.update('fc.regression.' + name for name in re.findall(
        r'^FC_REVIEW_CASE\([A-Za-z0-9_]+, "([^"]+)"\)', (repo / 'test/review_cases.inc').read_text(), re.M))
    for suite, spec in json.loads((repo / 'test/lua_suites.json').read_text()).items():
        names.update(f'fc.lua.{suite}.{case}' for case in spec['cases']) if spec['cases'] else names.add(f'fc.lua.{suite}')
    names.update('fc.negative.' + name for name in json.loads((repo / 'test/negative_controls.json').read_text()))
    return names


def manual_tests(repo):
    names = json.loads((repo / 'test/release_required.json').read_text())['manual']
    if len(names) != len(set(names)) or set(names) - required_tests(repo):
        raise ValueError('manual tests must be unique entries in the qualification registry')
    return set(names)


def check_names(actual, expected):
    counts = Counter(actual)
    missing, extra = expected - counts.keys(), counts.keys() - expected
    duplicates = {name for name, count in counts.items() if count != 1}
    if missing or extra or duplicates:
        raise ValueError(f'incomplete release suite: missing={sorted(missing)}, unexpected={sorted(extra)}, duplicates={sorted(duplicates)}')


def architecture(value):
    return {'aarch64': 'arm64', 'AMD64': 'x86_64'}.get(value, value)


def built_executables(build):
    binaries = {'fc': build / 'fc', 'fresh': build / 'third_party/fresh/bin/fresh',
                '7zr': build / 'third_party/lzma/_o/7zr'}
    for path in binaries.values():
        if not path.is_file() or not os.access(path, os.X_OK) or not path.stat().st_size:
            raise ValueError(f'missing release executable: {path}')
    return binaries


def check_build(build, repo, system, arch):
    cache = dict(re.findall(r'^([^#/:\n][^:\n]*):[^=\n]+=(.*)$', (build / 'CMakeCache.txt').read_text(), re.M))
    if Path(cache.get('CMAKE_HOME_DIRECTORY', '')).resolve() != repo.resolve():
        raise ValueError('release build belongs to a different source tree')
    required = {'CMAKE_BUILD_TYPE': 'Release', 'BUILD_TESTING': 'ON', 'FC_CORE_ONLY': 'OFF',
                'FC_ALLOW_UNPINNED_DEPENDENCIES': 'OFF', 'FC_BUILD_FRESH': 'ON',
                'FC_BUILD_LZMA_TOOL': 'ON', 'FC_TEST_DEPENDENCY_REBUILDS': 'ON'}
    for key, value in required.items():
        if cache.get(key) != value:
            raise ValueError(f'release requires {key}={value}, got {cache.get(key)!r}')
    if cache.get('FETCHCONTENT_SOURCE_DIR_BOOST'):
        raise ValueError('release disallows an unchecked Boost source override')
    version = '.'.join(cache['CMAKE_CACHE_' + part + '_VERSION'] for part in ('MAJOR', 'MINOR', 'PATCH'))
    system_file = (build / 'CMakeFiles' / version / 'CMakeSystem.cmake').read_text()
    target = dict(re.findall(r'set\((CMAKE_[A-Z_]+) "([^"]*)"\)', system_file))
    if (target.get('CMAKE_SYSTEM_NAME') != system or architecture(target.get('CMAKE_SYSTEM_PROCESSOR')) != arch or
            target.get('CMAKE_CROSSCOMPILING') != 'FALSE'):
        raise ValueError('release requires a native target matching the current OS and architecture')
    binaries = built_executables(build)
    package_name = f"fc-{system}-{target['CMAKE_SYSTEM_PROCESSOR']}"
    return binaries, build / 'dist' / (package_name + '.tar.gz')


def check_discovery(discovery, expected, manual=None):
    tests = discovery['tests']
    check_names([test['name'] for test in tests], expected)
    for test in tests:
        if manual is not None:
            labels = next((p['value'] for p in test.get('properties', []) if p['name'] == 'LABELS'), [])
            if ('manual' in labels) != (test['name'] in manual):
                raise ValueError(f"manual test label disagrees with qualification registry: {test['name']}")
        disabled = next((p['value'] for p in test.get('properties', []) if p['name'] == 'DISABLED'), False)
        if disabled or not test.get('command'):
            raise ValueError(f"required release test disabled or not built: {test['name']}")
        if not os.access(test['command'][0], os.X_OK):
            raise ValueError(f"required release test executable missing: {test['name']}")


def check_package(archive, binaries):
    hashes = {}
    with tarfile.open(archive, 'r:gz') as package:
        # An executable-only archive must not pass distribution qualification.
        notices = ('share/licenses/file-commander/LICENSE', 'share/licenses/ftxui/LICENSE',
                   'share/licenses/luajit/COPYRIGHT', 'share/licenses/boost/LICENSE_1_0.txt',
                   'share/licenses/lzma-sdk/lzma-sdk.txt', 'share/licenses/fresh/LICENSE',
                   'share/file-commander/THIRD_PARTY_NOTICES.md',
                   'share/file-commander/dependencies.json')
        for relative in notices:
            members = [m for m in package.getmembers() if m.name == f'{archive.name[:-7]}/{relative}']
            if len(members) != 1 or not members[0].isfile() or not members[0].size:
                raise ValueError(f'package missing license/source notice: {relative}')
        for name, binary in binaries.items():
            members = [m for m in package.getmembers() if m.name == f'{archive.name[:-7]}/bin/{name}']
            if len(members) != 1 or not members[0].isfile() or not members[0].mode & 0o111:
                raise ValueError(f'package missing executable: {name}')
            with binary.open('rb') as stream:
                expected = hashlib.file_digest(stream, 'sha256').hexdigest()
            with package.extractfile(members[0]) as stream:
                actual = hashlib.file_digest(stream, 'sha256').hexdigest()
            if actual != expected:
                raise ValueError(f'package contains stale executable: {name}')
            hashes[name] = actual
    return hashes
