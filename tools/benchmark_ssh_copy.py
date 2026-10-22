#!/usr/bin/env python3
"""Qualify FC copy throughput, verification, data fsyncs and protocol overhead.

All data lives in owned temporary directories. --fixture exercises the exact
agent locally; it is software qualification, not a network benchmark.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='box')
    parser.add_argument('--build', type=Path, default=Path('build-macos'))
    parser.add_argument('--gib', type=float, default=1)
    parser.add_argument('--files', type=int, default=2)
    parser.add_argument('--fixture', action='store_true')
    parser.add_argument('--skip-build', action='store_true')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if not math.isfinite(args.gib) or not 0 < args.gib <= 1024 or not 1 <= args.files <= 10000:
        parser.error('use 0 < --gib <= 1024 and 1 <= --files <= 10000')
    if not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.@:+%-]*', args.host):
        parser.error('--host must be an SSH config target or user@host')
    root = Path(__file__).resolve().parent.parent
    build = args.build.resolve()
    output = args.output or build / 'test-logs' / ('ssh-copy-' + time.strftime('%Y%m%d-%H%M%S'))
    output.mkdir(parents=True, exist_ok=True)
    binary = build / 'fc_remote_copy_benchmark'
    if not args.skip_build:
        subprocess.run(['cmake', '--build', str(build), '--target', 'fc_remote_copy_benchmark', '-j8'], check=True)
    if not binary.is_file():
        parser.error(f'benchmark executable is absent: {binary}')
    host = 'fixture' if args.fixture else args.host
    size = max(1, int(args.gib * 1024**3))
    total = size * args.files
    env = dict(os.environ)
    if args.fixture:
        env['FC_SSH_BIN'] = str(root / 'test/ssh_fixture.py')
    else:
        env.pop('FC_SSH_BIN', None)
    for key in tuple(env):
        if key.startswith('FC_SSH_FIXTURE_'):
            del env[key]
    results = {'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(),
               'platform': platform.platform(), 'host': host, 'fixture': args.fixture,
               'bytes_per_file': size, 'files': args.files, 'results': [], 'passed': False,
               'scope': 'job submission through verified, durable publication; source generation excluded',
               'protocol_counts': 'plaintext FC bytes including timed helper bootstraps; SSH/TCP framing excluded'}
    remote = None
    ssh = os.environ.get('FC_BENCH_SSH_BIN', 'ssh')
    control_dir = Path('/tmp') / f'fcmd-ssh-{os.getuid()}'
    control_dir.mkdir(mode=0o700, exist_ok=True)
    s = control_dir.lstat()
    if not control_dir.is_dir() or control_dir.is_symlink() or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise RuntimeError('SSH control directory is not private')
    control = str(control_dir / hashlib.sha256(host.encode()).hexdigest()[:24])
    options = ['-oBatchMode=yes', '-oStrictHostKeyChecking=yes', '-oConnectTimeout=10',
               '-oServerAliveInterval=10', '-oServerAliveCountMax=2', '-oCompression=no',
               '-oControlMaster=auto', '-oControlPersist=600', '-oControlPath=' + control]

    def remote_python(code, *arguments, stdin=None):
        return subprocess.run([ssh, '-T', *options, host, shlex.join(['python3', '-c', code, *map(str, arguments)])],
                              stdin=stdin, capture_output=True, check=True, timeout=3600, env=env)

    def remote_mkdir(name):
        path = str(Path(remote) / name)
        if args.fixture:
            Path(path).mkdir()
        else:
            remote_python('import os,sys;os.mkdir(sys.argv[1],0o700)', path)
        return path

    def remote_remove(path):
        if args.fixture:
            shutil.rmtree(path)
        else:
            remote_python('import shutil,sys;shutil.rmtree(sys.argv[1])', path)

    def location(path):
        return f'ssh://{host}{path}'

    def measured(name, action):
        print(name + '...', flush=True)
        started = time.monotonic()
        action()
        seconds = time.monotonic() - started
        result = dict(name=name, bytes=total, seconds=seconds, mib_per_second=total / seconds / 1024**2)
        results['results'].append(result)
        print(f"  {result['mib_per_second']:.1f} MiB/s ({seconds:.2f}s)", flush=True)

    def fc(name, source, destination, profile):
        print(name + ' (copy + independent verification + commit)...', flush=True)
        run = subprocess.run([str(binary), str(source), str(destination), str(args.files), str(profile)],
                             capture_output=True, text=True, env=env, timeout=3600)
        (output / (name + '.stderr')).write_text(run.stderr)
        (output / (name + '.json')).write_text(run.stdout)
        if run.returncode:
            raise RuntimeError(name + ' failed: ' + (run.stderr or run.stdout))
        result = json.loads(run.stdout)
        if not result['passed'] or any(result[key] != total for key in ('written', 'verified', 'durable')):
            raise RuntimeError(name + ': incomplete copy or verification')
        # Data checkpoints are once per GiB plus EOF, coalesced on boundaries.
        if not args.files <= result['data_fsync_count'] <= args.files * max(1, math.ceil(size / 1024**3)):
            raise RuntimeError(name + ': unexpected data fsync count')
        result['name'] = name
        results['results'].append(result)
        print(f"  {result['mib_per_second']:.1f} MiB/s, {result['data_fsync_count']} data fsyncs, "
              f"peak RSS {result['peak_rss_bytes'] / 1024**2:.1f} MiB", flush=True)

    try:
        with tempfile.TemporaryDirectory(prefix='fc-ssh-copy-local-') as local:
            local = Path(local)
            if shutil.disk_usage(local).free < 2 * total + 512 * 1024**2:
                raise RuntimeError('Not enough local space for source and verified download fixtures')
            if args.fixture:
                remote = tempfile.mkdtemp(prefix='fc-ssh-copy-', dir='/tmp')
                free = shutil.disk_usage(remote).free
            else:
                probe = remote_python("import tempfile,shutil; p=tempfile.mkdtemp(prefix='fc-ssh-copy-',dir='/tmp'); "
                                      "print(p); print(shutil.disk_usage(p).free)")
                lines = probe.stdout.decode().splitlines()
                if len(lines) != 2 or not re.fullmatch(r'/tmp/fc-ssh-copy-[A-Za-z0-9_-]+', lines[0]):
                    raise RuntimeError('Remote benchmark directory reply was invalid')
                remote, free = lines[0], int(lines[1])
            results['remote_directory'] = remote
            if free < 2 * total + 512 * 1024**2:
                raise RuntimeError('Not enough remote space for two owned transfer fixtures')
            source = local / 'source'; source.mkdir()
            print(f'Generating {args.files} independent incompressible files, {size / 1024**3:g} GiB each...', flush=True)
            names = [f'payload-{n:04}.bin' for n in range(args.files)]
            for name in names:
                with (source / name).open('wb') as stream:
                    remaining = size
                    while remaining:
                        block = os.urandom(min(1024**2, remaining))
                        stream.write(block); remaining -= len(block)
                    stream.flush(); os.fsync(stream.fileno())

            def read_local():
                for name in names:
                    with (source / name).open('rb') as stream:
                        while stream.read(1024**2):
                            pass
            measured('local_read', read_local)
            disk_target = local / 'disk-write'; disk_target.mkdir()

            def write_local():
                for name in names:
                    with (source / name).open('rb') as src, (disk_target / name).open('wb') as dst:
                        shutil.copyfileobj(src, dst, 1024**2); dst.flush(); os.fsync(dst.fileno())
            measured('local_write_fsync', write_local)
            shutil.rmtree(disk_target)

            upload = remote_mkdir('fc-upload')
            fc('fc_upload', source, location(upload), local / 'upload-journal')
            download = local / 'download'; download.mkdir()
            fc('fc_download', location(upload), download, local / 'download-journal')
            shutil.rmtree(download)
            onhost = remote_mkdir('fc-onhost')
            fc('fc_same_host', location(upload), location(onhost), local / 'onhost-journal')
            remote_remove(onhost)

            raw = remote_mkdir('raw')
            sink = '''import os,sys
with open(sys.argv[1], 'wb') as f:
    while block := sys.stdin.buffer.read(1024*1024):
        f.write(block)
    f.flush()
    os.fsync(f.fileno())
    if f.tell() != int(sys.argv[2]):
        raise RuntimeError('Raw baseline received a short stream')
'''
            def raw_upload():
                for name in names:
                    with (source / name).open('rb') as stream:
                        target = str(Path(raw) / name)
                        if args.fixture:
                            subprocess.run([sys.executable, '-c', sink, target, str(size)], stdin=stream, check=True)
                        else:
                            remote_python(sink, target, size, stdin=stream)
            measured('raw_local_process' if args.fixture else 'raw_ssh_upload_fsync', raw_upload)
            remote_remove(raw)
            if not args.fixture:
                target = remote_mkdir('sftp')
                batch = local / 'sftp.batch'
                def quote(value):
                    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'
                batch.write_text(''.join(f'put {quote(source / name)} {quote(Path(target) / name)}\n' for name in names))
                def sftp_upload():
                    subprocess.run(['sftp', '-q', '-f', '-b', str(batch), *options, host],
                                   check=True, env=env, timeout=3600)
                    # Also flush explicitly so this baseline remains durable
                    # with servers that lack fsync@openssh.com support.
                    remote_python('''import os,sys
for entry in os.scandir(sys.argv[1]):
    fd = os.open(entry.path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
''', target)
                measured('sftp_upload_fsync', sftp_upload)
                remote_remove(target)
            results['passed'] = True
    except Exception as error:
        results['error'] = str(error)
        raise
    finally:
        if remote is not None:
            try:
                remote_remove(remote)
                results['cleanup_complete'] = True
            except Exception as error:
                results['cleanup_error'] = str(error)
                results['cleanup_complete'] = False
                results['passed'] = False
        (output / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print('Artifacts: ' + str(output.resolve()), flush=True)
    if not results['passed']:
        raise RuntimeError(results.get('error', results.get('cleanup_error', 'Qualification failed')))


if __name__ == '__main__':
    main()
