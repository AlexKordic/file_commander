"""Prove ingress and the next file continue while an earlier fsync is blocked."""
import errno
import hashlib
import os
from pathlib import Path
import sys
import tempfile
import threading
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from remote_agent import StreamWriter
from remote_protocol import WIRE_RESULT, WIRE_ERROR

with tempfile.TemporaryDirectory(prefix='fc-stream-verifier-') as directory:
    entered, release, completed = threading.Event(), threading.Event(), threading.Event()
    results = []
    data = b'raw\0bytes\xff' * 10000
    real_fsync = os.fsync
    first_fd = None

    def blocked_fsync(fd):
        if fd == first_fd:
            entered.set()
            assert release.wait(5), 'Test did not release fsync'
        real_fsync(fd)

    first = StreamWriter(directory + '/one', len(data), lambda kind, value: results.append((kind, value)))
    first_fd = first.fd
    try:
        with patch('os.fsync', blocked_fsync):
            first.write(data)
            first.end(hashlib.sha256(data).digest())
            assert entered.wait(5), 'Verifier did not reach fsync'
            second = StreamWriter(directory + '/two', len(data),
                                  lambda kind, value: completed.set() if kind == WIRE_RESULT else None)
            second.write(data)
            second.end(hashlib.sha256(data).digest())
            assert completed.wait(5), 'Next file waited for the previous fsync'
            assert not any(kind == WIRE_RESULT for kind, _ in results), 'Blocked file completed early'
            assert Path(directory + '/two').read_bytes() == data
            release.set()
            second.worker.join(5)
            first.worker.join(5)
        assert not first.worker.is_alive() and not second.worker.is_alive()
        assert [value['flushes'] for kind, value in results if kind == WIRE_RESULT] == [1]
    finally:
        release.set()
        first.worker.join(5)

    bad_results = []
    corrupt = StreamWriter(directory + '/corrupt', len(data), lambda kind, value: bad_results.append((kind, value)))
    real_pread = os.pread

    def wrong_read(fd, length, offset):
        block = real_pread(fd, length, offset)
        return bytes([block[0] ^ 1]) + block[1:] if fd == corrupt.fd and block else block

    with patch('os.pread', wrong_read):
        corrupt.write(data)
        corrupt.end(hashlib.sha256(data).digest())
        corrupt.worker.join(5)
    assert not corrupt.worker.is_alive()
    assert any(kind == WIRE_ERROR and 'digest mismatch' in value['message'] for kind, value in bad_results)
    assert not any(kind == WIRE_RESULT for kind, _ in bad_results)

    # Exercise coarse checkpoints deterministically without a GiB fixture.
    checkpoints, checkpoint_seen = [], threading.Event()
    block = b'x' * 65536
    def checkpoint_event(kind, value):
        if kind == WIRE_RESULT:
            checkpoints.append(value)
        if value.get('durable') == len(block):
            checkpoint_seen.set()
    writer = StreamWriter(directory + '/checkpoints', 2 * len(block), checkpoint_event, checkpoint_bytes=len(block))
    writer.write(block)
    assert checkpoint_seen.wait(5)
    writer.write(block)
    writer.end(hashlib.sha256(block * 2).digest())
    writer.worker.join(5)
    assert checkpoints and checkpoints[-1]['flushes'] == 2
print('PASS asynchronous fsync, consecutive files, corruption detection and coarse checkpoints')
