"""Cross-language wire compatibility and hostile message boundaries."""
import io
from pathlib import Path
import struct
import subprocess
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from remote_protocol import *

binary = sys.argv[1]
payload = subprocess.check_output([binary, '--emit'])
value = wire_decode(payload)
assert value['path'] == b'/tmp/raw-\xff' and value['data'] == b'\0\xff\r\n'
assert value['sha256'] == b'\xa5' * 32
assert value['offset'] == 2**64 - 1 and value['mtime_ns'] == -(2**63)
subprocess.run([binary, '--accept'], input=wire_encode(value), check=True)
for n in range(len(payload)):
    try:
        wire_decode(payload[:n])
    except (ValueError, IndexError, struct.error):
        pass
    else:
        raise AssertionError('Accepted truncated value')
for malformed in (payload + b'x', b'\6\xff\xff\xff\xff', b'\7\xff\xff\xff\xff', b'\xff'):
    try:
        wire_decode(malformed)
    except ValueError:
        pass
    else:
        raise AssertionError('Accepted malformed value')
for kind, flags, operation, length in ((0, 0, 1, 0), (1, 1, 1, 0), (1, 0, 65535, 0),
                                      (1, 0, 1, WIRE_LIMIT + 1), (5, 0, 1, WIRE_BLOCK + 1)):
    try:
        wire_read(io.BytesIO(struct.pack('!BBHQI', kind, flags, operation, 1, length)))
    except ValueError:
        pass
    else:
        raise AssertionError('Accepted malformed frame bounds')
print('PASS C++/Python binary compatibility, truncation and frame bounds')
