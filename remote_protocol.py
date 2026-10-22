"""FC SSH protocol 2; embedded before the agent. No text payload encodings."""
import struct

WIRE_HELLO = b"FCSSH\0\2\0"
WIRE_LIMIT = 64 * 1024 * 1024
WIRE_BLOCK = 1024 * 1024
WIRE_REQUEST, WIRE_RESULT, WIRE_ERROR, WIRE_EVENT, WIRE_DATA, WIRE_END = range(1, 7)
WIRE_METHODS = ('', 'stat', 'list', 'realpath', 'read', 'write', 'mkdir', 'remove', 'rename',
                'symlink', 'metadata', 'digest', 'fsync', 'access', 'tree', 'attributes', 'set_attributes',
                'copy', 'stream_read', 'stream_write', 'stream_copy', 'stream_control')
WIRE_FIELDS = ('', 'path', 'destination', 'target', 'follow', 'offset', 'length', 'data', 'exclusive',
               'recursive', 'replace', 'expected', 'mode', 'mtime_ns', 'ctime_ns', 'exists', 'dev', 'ino',
               'uid', 'gid', 'size', 'link', 'owner', 'group', 'target_dir', 'entries', 'name', 'relative',
               'stamp', 'attributes', 'platform', 'acl', 'allowed', 'sha256', 'bytes', 'errno', 'message',
               'checkpoint', 'verified', 'durable', 'rate', 'paused', 'cancelled', 'source', 'phase', 'flushes')
_WIRE_KEYS = {key: n for n, key in enumerate(WIRE_FIELDS) if n}


def wire_encode(value, depth=0):
    if depth > 32:
        raise ValueError('SSH value exceeds depth limit')
    if value is None:
        return b'\0'
    if isinstance(value, bool):
        return b'\2' if value else b'\1'
    if isinstance(value, int):
        return b'\3' + struct.pack('!q', value) if value < 0 else b'\4' + struct.pack('!Q', value)
    if isinstance(value, str):
        value = value.encode('utf-8', 'surrogateescape')
    if isinstance(value, bytes):
        if len(value) > WIRE_LIMIT:
            raise ValueError('SSH byte string exceeds limit')
        return b'\5' + struct.pack('!I', len(value)) + value
    if isinstance(value, (list, tuple)):
        return b'\6' + struct.pack('!I', len(value)) + b''.join(wire_encode(v, depth + 1) for v in value)
    if isinstance(value, dict):
        parts = [b'\7', struct.pack('!I', len(value))]
        for key, data in value.items():
            n = _WIRE_KEYS.get(key, 0)
            parts.append(struct.pack('!H', n))
            if not n:
                raw = key if isinstance(key, bytes) else key.encode('utf-8', 'surrogateescape')
                parts.extend((struct.pack('!I', len(raw)), raw))
            parts.append(wire_encode(data, depth + 1))
        return b''.join(parts)
    raise ValueError('Unsupported SSH binary value')


def wire_decode(data):
    at, nodes = 0, 0

    def take(n):
        nonlocal at
        if n > len(data) - at:
            raise ValueError('Truncated SSH binary message')
        out = data[at:at + n]
        at += n
        return out

    def length():
        return struct.unpack('!I', take(4))[0]

    def value(depth=0):
        nonlocal nodes
        nodes += 1
        if depth > 32 or nodes > 1000000:
            raise ValueError('SSH value exceeds limit')
        kind = take(1)[0]
        if kind == 0:
            return None
        if kind in (1, 2):
            return kind == 2
        if kind in (3, 4):
            return struct.unpack('!q' if kind == 3 else '!Q', take(8))[0]
        if kind == 5:
            return take(length())
        if kind == 6:
            count = length()
            if count > min(1000000, len(data) - at):
                raise ValueError('Invalid SSH array size')
            return [value(depth + 1) for _ in range(count)]
        if kind == 7:
            count = length()
            if count > min(1000000, (len(data) - at) // 3):
                raise ValueError('Invalid SSH object size')
            out = {}
            for _ in range(count):
                n = struct.unpack('!H', take(2))[0]
                if n >= len(WIRE_FIELDS):
                    raise ValueError('Unknown SSH field')
                key = WIRE_FIELDS[n] if n else take(length())
                if key in out:
                    raise ValueError('Duplicate SSH field')
                out[key] = value(depth + 1)
            return out
        raise ValueError('Unknown SSH binary value')

    result = value()
    if at != len(data):
        raise ValueError('Trailing SSH binary data')
    return result


def wire_exact(stream, n, eof=False):
    parts = bytearray()
    while len(parts) < n:
        block = stream.read(n - len(parts))
        if not block:
            if eof and not parts:
                return None
            raise EOFError('SSH binary stream closed')
        parts.extend(block)
    return bytes(parts)


def wire_read(stream):
    header = wire_exact(stream, 16, eof=True)
    if header is None:
        return None
    kind, flags, operation, identity, length = struct.unpack('!BBHQI', header)
    if (flags or not 1 <= kind <= 6 or not 0 < operation < len(WIRE_METHODS)
            or length > WIRE_LIMIT or (kind == WIRE_DATA and length > WIRE_BLOCK)):
        raise ValueError('Invalid SSH frame bounds')
    return kind, operation, identity, wire_exact(stream, length)


def wire_write(stream, kind, operation, identity, payload):
    if len(payload) > WIRE_LIMIT or (kind == WIRE_DATA and len(payload) > WIRE_BLOCK):
        raise ValueError('SSH frame exceeds limit')
    for part in (struct.pack('!BBHQI', kind, 0, operation, identity, len(payload)), payload):
        view = memoryview(part)
        while view:
            count = stream.write(view)
            if not count:
                raise EOFError('SSH binary stream closed while writing')
            view = view[count:]
    if kind != WIRE_DATA:
        stream.flush()
