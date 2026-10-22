"""FC filesystem agent. Embedded into fc and sent to python3 over SSH stdin.

Paths and data are raw OS bytes. Mutations never resolve the final symlink.
The helper speaks binary protocol 2 on stdout; stderr is reserved for diagnostics.
"""
import errno
import ctypes
import grp
import hashlib
import os
import pwd
import shutil
import stat
import sys
import time
import threading
import queue

if "wire_read" not in globals():
    from remote_protocol import *


def attributes(value):
    if hasattr(os, "listxattr"):
        return {os.fsencode(name): os.getxattr(value, name, follow_symlinks=False)
                for name in os.listxattr(value, follow_symlinks=False)}
    if sys.platform != "darwin":
        raise OSError(errno.ENOTSUP, "Cannot inspect extended attributes")
    libc = ctypes.CDLL(None, use_errno=True)
    raw = os.fsencode(value)
    size = libc.listxattr(raw, None, 0, 1)
    if size < 0:
        raise OSError(ctypes.get_errno(), "Cannot list extended attributes")
    names = ctypes.create_string_buffer(size)
    if libc.listxattr(raw, names, size, 1) < 0:
        raise OSError(ctypes.get_errno(), "Cannot list extended attributes")
    out = {}
    for name in names.raw.split(b"\0"):
        if not name:
            continue
        size = libc.getxattr(raw, name, None, 0, 0, 1)
        if size < 0:
            raise OSError(ctypes.get_errno(), "Cannot read extended attribute")
        data = ctypes.create_string_buffer(size)
        count = libc.getxattr(raw, name, data, size, 0, 1)
        if count < 0:
            raise OSError(ctypes.get_errno(), "Cannot read extended attribute")
        out[name] = data.raw[:count]
    return out


def acl_present(value):
    if sys.platform != "darwin":
        return False  # Linux ACLs are represented in xattrs.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.acl_get_link_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_free.argtypes = [ctypes.c_void_p]
    acl = libc.acl_get_link_np(os.fsencode(value), 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        if ctypes.get_errno() in (errno.ENOENT, errno.ENOTSUP):
            return False
        raise OSError(ctypes.get_errno(), "Cannot inspect ACL")
    try:
        entry = ctypes.c_void_p()
        return libc.acl_get_entry(acl, 0, ctypes.byref(entry)) == 0
    finally:
        libc.acl_free(acl)


def path(params, key="path"):
    value = os.fsdecode(params[key])
    if not os.path.isabs(value) or "\0" in value:
        raise ValueError("An absolute filesystem path is required")
    return os.path.normpath(value)


def stamp(value, follow=False):
    try:
        s = os.stat(value, follow_symlinks=follow)
    except FileNotFoundError:
        return {"exists": False}
    result = dict(exists=True, mode=s.st_mode, dev=s.st_dev, ino=s.st_ino,
                  uid=s.st_uid, gid=s.st_gid, size=s.st_size,
                  mtime_ns=s.st_mtime_ns, ctime_ns=s.st_ctime_ns)
    if stat.S_ISLNK(s.st_mode):
        result["link"] = os.fsencode(os.readlink(value))
    try:
        result["owner"] = pwd.getpwuid(s.st_uid).pw_name
    except KeyError:
        result["owner"] = str(s.st_uid)
    try:
        result["group"] = grp.getgrgid(s.st_gid).gr_name
    except KeyError:
        result["group"] = str(s.st_gid)
    return result


def sync_directory(value):
    fd = os.open(value, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def digest(value, send):
    h = hashlib.sha256()
    total = 0
    with open(value, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
            total += len(block)
            send({"bytes": total})
    return h.digest()


def rename_exclusive(source, destination):
    libc = ctypes.CDLL(None, use_errno=True)
    a, b = os.fsencode(source), os.fsencode(destination)
    if sys.platform == "darwin":
        result = libc.renamex_np(a, b, 4)  # RENAME_EXCL
    elif hasattr(libc, "renameat2"):
        result = libc.renameat2(-100, a, -100, b, 1)  # RENAME_NOREPLACE
    else:
        raise OSError(errno.ENOTSUP, "Atomic exclusive rename is unavailable")
    if result:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), destination)


def dispatch(method, p, send):
    value = path(p) if "path" in p else None
    if method == "stat":
        return stamp(value, p.get("follow", False))
    if method == "list":
        entries = []
        with os.scandir(value) as directory:
            for entry in directory:
                info = stamp(entry.path)
                if not info["exists"]:
                    continue
                info["name"] = os.fsencode(entry.name)
                if entry.is_symlink():
                    info["target_dir"] = entry.is_dir()
                entries.append(info)
                if len(entries) >= 256:
                    send({"entries": entries})
                    entries = []
        return {"entries": entries}
    if method == "realpath":
        return {"path": os.fsencode(os.path.realpath(value))}
    if method == "read":
        with open(value, "rb") as f:
            f.seek(p["offset"])
            return {"data": f.read(min(p["length"], 1024 * 1024))}
    if method == "write":
        flags = os.O_WRONLY | os.O_NOFOLLOW
        if p.get("exclusive"):
            flags |= os.O_CREAT | os.O_EXCL
        fd = os.open(value, flags, 0o600)
        try:
            os.lseek(fd, p["offset"], os.SEEK_SET)
            data = p["data"]
            while data:
                n = os.write(fd, data)
                data = data[n:]
            os.fsync(fd)
        finally:
            os.close(fd)
        return {}
    if method == "mkdir":
        os.mkdir(value, 0o700)
        if sys.platform == "darwin":
            libc = ctypes.CDLL(None, use_errno=True)
            libc.acl_init.restype = ctypes.c_void_p
            libc.acl_set_file.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
            libc.acl_free.argtypes = [ctypes.c_void_p]
            acl = libc.acl_init(0)
            try:
                if not acl or libc.acl_set_file(os.fsencode(value), 0x100, acl):
                    raise OSError(ctypes.get_errno(), "Cannot make staging directory private")
            finally:
                if acl:
                    libc.acl_free(acl)
        elif hasattr(os, "removexattr"):
            for name in ("system.posix_acl_access", "system.posix_acl_default"):
                try:
                    os.removexattr(value, name)
                except OSError as error:
                    if error.errno not in (errno.ENODATA, errno.ENOTSUP):
                        raise
        sync_directory(os.path.dirname(value))
        return {}
    if method == "remove":
        if stat.S_ISDIR(os.lstat(value).st_mode):
            if p.get("recursive"):
                shutil.rmtree(value)
            else:
                os.rmdir(value)
        else:
            os.unlink(value)
        sync_directory(os.path.dirname(value))
        return {}
    if method == "rename":
        destination = path(p, "destination")
        if "expected" in p:
            current = stamp(destination)
            if any(current.get(key, "" if key == "link" else None) != data for key, data in p["expected"].items()):
                raise OSError(errno.ESTALE, "Destination changed before commit", destination)
        if p.get("replace"):
            os.rename(value, destination)
        else:
            rename_exclusive(value, destination)
        sync_directory(os.path.dirname(destination))
        sync_directory(os.path.dirname(value))
        return {}
    if method == "symlink":
        os.symlink(os.fsdecode(p["target"]), value)
        return {}
    if method == "metadata":
        if not stat.S_ISLNK(os.lstat(value).st_mode):
            os.chmod(value, p["mode"] & 0o7777)
        os.utime(value, ns=(p["mtime_ns"], p["mtime_ns"]), follow_symlinks=False)
        return {}
    if method == "digest":
        return {"sha256": digest(value, send)}
    if method == "fsync":
        if not os.path.islink(value):
            sync_directory(value)
        return {}
    if method == "access":
        return {"allowed": os.access(value, p["mode"])}
    if method == "tree":
        entries = [{"relative": b"", "stamp": stamp(value, p.get("follow", False))}]
        if p.get("recursive", True) and stat.S_ISDIR(entries[0]["stamp"].get("mode", 0)):
            for root, directories, files in os.walk(value, followlinks=False):
                for name in directories + files:
                    child = os.path.join(root, name)
                    entries.append({"relative": os.fsencode(os.path.relpath(child, value)), "stamp": stamp(child)})
                    if len(entries) >= 256:
                        send({"entries": entries})
                        entries = []
        return {"entries": entries}
    if method == "attributes":
        attrs = attributes(value)
        acl = acl_present(value) or any(os.fsencode(name).startswith(b"system.posix_acl_") for name in attrs)
        return {"attributes": attrs, "platform": sys.platform, "acl": acl}
    if method == "set_attributes":
        for name, data in p["attributes"].items():
            name = os.fsencode(name)
            if hasattr(os, "setxattr"):
                os.setxattr(value, os.fsdecode(name), data, follow_symlinks=False)
            elif sys.platform == "darwin":
                libc = ctypes.CDLL(None, use_errno=True)
                if libc.setxattr(os.fsencode(value), name, data, len(data), 0, 1):
                    raise OSError(ctypes.get_errno(), "Cannot set extended attribute")
            else:
                raise OSError(errno.ENOTSUP, "Cannot set extended attributes")
        return {}
    if method == "copy":
        destination = path(p, "destination")
        # Only an owned staging path may be passed by the coordinator.
        total = 0
        with open(value, "rb") as source, open(destination, "xb") as target:
            while True:
                block = source.read(1024 * 1024)
                if not block:
                    break
                target.write(block)
                total += len(block)
                send({"bytes": total})
            target.flush()
            os.fsync(target.fileno())
        return {"bytes": total}
    raise ValueError("Unknown filesystem method: " + method)


def source_identity(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid,
            s.st_size, s.st_mtime_ns, s.st_ctime_ns)


def stream_source(value, expected, consume, block_size=lambda: WIRE_BLOCK):
    fd = os.open(value, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        current = stamp(value)
        if (not stat.S_ISREG(before.st_mode) or
                any(current.get(key, b'' if key == 'link' else None) != data
                    for key, data in expected.items())):
            raise OSError(errno.ESTALE, 'Source changed before streaming', value)
        h, total = hashlib.sha256(), 0
        while total < before.st_size:
            block = os.read(fd, min(block_size(), before.st_size - total))
            if not block:
                raise OSError(errno.EIO, 'Unexpected EOF while streaming', value)
            h.update(block)
            consume(block)
            total += len(block)
        if (source_identity(os.fstat(fd)) != source_identity(before) or
                source_identity(os.stat(value, follow_symlinks=False)) != source_identity(before)):
            raise OSError(errno.ESTALE, 'Source changed while streaming', value)
        return {'sha256': h.digest(), 'bytes': total}
    finally:
        os.close(fd)


class StreamWriter:
    """One open staging FD; write ingress never waits for hash or fsync work."""
    def __init__(self, value, size, emit, checkpoint_bytes=1024**3):
        self.value, self.size, self.emit = value, size, emit
        self.checkpoint_bytes = checkpoint_bytes
        self.fd = os.open(value, os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        self.cv, self.io_lock = threading.Condition(), threading.Lock()
        self.written = self.verified = self.durable = self.flushes = 0
        self.finished = self.closed = False
        self.failure = self.expected_hash = self.end_identity = None
        self.reported = (0, 0, 0)
        self.reported_time = time.monotonic()
        self.worker = threading.Thread(target=self.verify, daemon=True)
        self.worker.start()

    def progress(self):
        with self.cv:
            return dict(bytes=self.written, verified=self.verified, durable=self.durable, flushes=self.flushes)

    def report(self, force=False):
        with self.cv:
            before = self.reported
            now = time.monotonic()
            if (not force and now - self.reported_time < 0.2 and self.written - before[0] < 8 * WIRE_BLOCK
                    and self.verified - before[1] < 8 * WIRE_BLOCK and self.durable == before[2]):
                return
            self.reported = (self.written, self.verified, self.durable)
            self.reported_time = now
            value = self.progress()
        self.emit(WIRE_EVENT, value)

    def write(self, data):
        with self.io_lock:
            if self.failure or self.finished or self.closed:
                raise OSError(errno.ECANCELED, 'Staging writer is closed')
            if self.written + len(data) > self.size:
                raise OSError(errno.EFBIG, 'Stream exceeds expected file length')
            view, offset = memoryview(data), self.written
            while view:
                n = os.pwrite(self.fd, view, offset)
                if n <= 0:
                    raise OSError(errno.EIO, 'Short staging write')
                offset += n
                view = view[n:]
            with self.cv:
                self.written = offset
                self.cv.notify_all()

    def end(self, digest):
        if len(digest) != 32:
            raise ValueError('Invalid SHA-256 digest length')
        with self.io_lock, self.cv:
            if self.finished or self.closed:
                raise ValueError('Duplicate stream end')
            self.expected_hash = digest
            self.end_identity = source_identity(os.fstat(self.fd))
            self.finished = True
            self.cv.notify_all()

    def fail(self, error):
        with self.cv:
            first = self.failure is None
            self.failure = error
            self.cv.notify_all()
        if first:
            self.emit(WIRE_ERROR, {'message': str(error), 'errno': getattr(error, 'errno', 0) or errno.EIO})

    def verify(self):
        try:
            h = hashlib.sha256()
            while True:
                with self.cv:
                    self.cv.wait_for(lambda: self.failure or self.written > self.verified or self.finished)
                    if self.failure:
                        return
                    written, finished = self.written, self.finished
                while self.verified < written:
                    block = os.pread(self.fd, min(WIRE_BLOCK, written - self.verified), self.verified)
                    if not block:
                        raise OSError(errno.EIO, 'Unexpected EOF during destination verification')
                    h.update(block)
                    with self.cv:
                        self.verified += len(block)
                    self.report()
                if finished:
                    if written != self.size or h.digest() != self.expected_hash:
                        raise OSError(errno.EIO, 'Transfer digest mismatch; destination was not published')
                    # EOF and a GiB boundary share one data fsync. Commit-time
                    # metadata and directory durability are handled separately.
                    if not self.flushes or self.durable != written:
                        os.fsync(self.fd)
                        with self.cv:
                            self.flushes += 1
                    with self.cv:
                        self.durable = written
                    if (source_identity(os.fstat(self.fd)) != self.end_identity or
                            source_identity(os.stat(self.value, follow_symlinks=False)) != self.end_identity):
                        raise OSError(errno.ESTALE, 'Staging file changed during verification')
                    self.emit(WIRE_RESULT, {**self.progress(), 'stamp': stamp(self.value)})
                    return
                if written - self.durable >= self.checkpoint_bytes:
                    os.fsync(self.fd)
                    with self.cv:
                        self.flushes += 1
                        self.durable = written
                    self.report(force=True)
        except Exception as error:
            self.fail(error)
        finally:
            with self.io_lock:
                self.closed = True
                os.close(self.fd)


class StreamControls:
    def __init__(self):
        self.cv = threading.Condition()
        self.paused = self.cancelled = False
        self.rate = self.total = self.base = 0
        self.started = time.monotonic()

    def update(self, p):
        with self.cv:
            rate = p.get('rate', 0)
            if rate != self.rate or self.paused != p.get('paused', False):
                self.started, self.base = time.monotonic(), self.total
            self.rate, self.paused, self.cancelled = rate, p.get('paused', False), p.get('cancelled', False)
            self.cv.notify_all()

    def consume(self, n):
        with self.cv:
            self.total += n
            while True:
                if self.cancelled:
                    raise OSError(errno.ECANCELED, 'Transfer interrupted')
                if self.paused:
                    self.cv.wait()
                    continue
                delay = self.started + (self.total - self.base) / self.rate - time.monotonic() if self.rate else 0
                if delay <= 0:
                    return
                self.cv.wait(delay)

    def block_size(self):
        with self.cv:
            return max(1, min(WIRE_BLOCK, self.rate // 10)) if self.rate else WIRE_BLOCK


def main():
    sys.stdout.buffer.write(WIRE_HELLO)
    sys.stdout.buffer.flush()
    output_lock, writers_lock = threading.Lock(), threading.Lock()
    writers, controls = {}, StreamControls()
    copies = queue.Queue(maxsize=32)
    reads = queue.Queue(maxsize=32)

    def emitter(operation, identity):
        def emit(kind, value):
            with output_lock:
                wire_write(sys.stdout.buffer, kind, operation, identity, wire_encode(value))
            if kind in (WIRE_RESULT, WIRE_ERROR):
                with writers_lock:
                    writers.pop(identity, None)
        return emit

    def copy_worker():
        while (work := copies.get()) is not None:
            writer, p = work
            try:
                def consume(block):
                    controls.consume(len(block))
                    writer.write(block)
                    writer.report()
                result = stream_source(path(p, 'source'), p['expected'], consume, controls.block_size)
                writer.emit(WIRE_EVENT, {**writer.progress(), 'phase': 1})
                writer.end(result['sha256'])
            except Exception as error:
                writer.fail(error)

    threading.Thread(target=copy_worker, daemon=True).start()

    def read_worker():
        while (work := reads.get()) is not None:
            operation, identity, p, emit = work
            try:
                def consume(block):
                    controls.consume(len(block))
                    with output_lock:
                        wire_write(sys.stdout.buffer, WIRE_DATA, operation, identity, block)
                emit(WIRE_RESULT, stream_source(path(p), p['expected'], consume, controls.block_size))
            except Exception as error:
                emit(WIRE_ERROR, {'message': str(error), 'errno': getattr(error, 'errno', 0) or errno.EIO})

    threading.Thread(target=read_worker, daemon=True).start()
    try:
        while (frame := wire_read(sys.stdin.buffer)) is not None:
            kind, operation, identity, payload = frame
            method = WIRE_METHODS[operation]
            emit = emitter(operation, identity)
            try:
                if method == 'stream_control' and kind == WIRE_REQUEST and identity == 0:
                    controls.update(wire_decode(payload))
                    continue  # One-way control; never a data-block credit/ACK.
                if kind in (WIRE_DATA, WIRE_END) and method == 'stream_write':
                    with writers_lock:
                        writer = writers.get(identity)
                    if writer is None:
                        raise ValueError('Unknown or closed stream writer')
                    if kind == WIRE_DATA:
                        writer.write(payload)
                        writer.report()
                    else:
                        writer.report(force=True)
                        writer.end(payload)
                    continue
                if kind != WIRE_REQUEST:
                    raise ValueError('Expected an SSH request')
                p = wire_decode(payload)
                if method == 'stream_read':
                    reads.put((operation, identity, p, emit))
                elif method in ('stream_write', 'stream_copy'):
                    with writers_lock:
                        if len(writers) >= 32 or identity in writers:
                            raise ValueError('Too many or duplicate staging streams')
                        writer = StreamWriter(path(p), p['size'], emit)
                        writers[identity] = writer
                    if method == 'stream_copy':
                        copies.put((writer, p))
                else:
                    emit(WIRE_RESULT, dispatch(method, p, lambda value: emit(WIRE_EVENT, value)))
            except Exception as error:
                with writers_lock:
                    writer = writers.get(identity)
                if writer is not None:
                    writer.fail(error)
                else:
                    emit(WIRE_ERROR, {'message': str(error), 'errno': getattr(error, 'errno', 0) or errno.EIO})
    finally:
        controls.update({'cancelled': True})
        with writers_lock:
            remaining = list(writers.values())
        for writer in remaining:
            with writer.cv:
                writer.failure = EOFError('Copy coordinator disconnected')
                writer.cv.notify_all()


if __name__ == "__main__":
    main()
