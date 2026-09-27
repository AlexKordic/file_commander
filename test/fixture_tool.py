"""Binary-safe filesystem manifests for independent test expectations."""
import hashlib
import json
import os
from pathlib import Path
import stat
import sys


def manifest(root):
    result = {}
    def visit(directory):
        for entry in sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name)):
            path = Path(entry.path)
            name = path.relative_to(root).as_posix()
            mode = entry.stat(follow_symlinks=False).st_mode
            if stat.S_ISLNK(mode):
                result[name] = {'type': 'link', 'target': os.readlink(path)}
            elif stat.S_ISDIR(mode):
                result[name] = {'type': 'directory'}
                visit(path)
            elif stat.S_ISREG(mode):
                with path.open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                result[name] = {'type': 'file', 'size': path.stat().st_size, 'sha256': digest}
            else:
                result[name] = {'type': 'special', 'mode': stat.S_IFMT(mode)}
    visit(Path(root))
    return result


if __name__ == '__main__':
    operation, path = sys.argv[1:]
    if operation != 'manifest':
        raise SystemExit('unknown operation: ' + operation)
    print(json.dumps(manifest(Path(path)), sort_keys=True, separators=(',', ':')))
