"""Binary-safe filesystem manifests for independent test expectations."""
import hashlib
import json
import os
from pathlib import Path
import stat
import shutil
import sys


def manifest(root, max_entries=None, max_bytes=None):
    result = {}
    hashed = 0
    def visit(directory):
        nonlocal hashed
        for entry in sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name)):
            if max_entries is not None and len(result) >= max_entries:
                raise ValueError("fixture manifest exceeds entry budget")
            path = Path(entry.path)
            name = path.relative_to(root).as_posix()
            mode = entry.stat(follow_symlinks=False).st_mode
            if stat.S_ISLNK(mode):
                result[name] = {'type': 'link', 'target': os.readlink(path)}
            elif stat.S_ISDIR(mode):
                result[name] = {'type': 'directory'}
                visit(path)
            elif stat.S_ISREG(mode):
                hashed += path.stat().st_size
                if max_bytes is not None and hashed > max_bytes:
                    raise ValueError('fixture manifest exceeds content budget')
                with path.open('rb') as stream:
                    digest = hashlib.file_digest(stream, 'sha256').hexdigest()
                result[name] = {'type': 'file', 'size': path.stat().st_size, 'sha256': digest}
            else:
                result[name] = {'type': 'special', 'mode': stat.S_IFMT(mode)}
    visit(Path(root))
    return result


if __name__ == '__main__':
    operation, *args = sys.argv[1:]
    path = Path(args[0])
    if operation == 'manifest':
        print(json.dumps(manifest(path), sort_keys=True, separators=(',', ':')))
    elif operation == 'mkdir':
        path.mkdir(parents=True, exist_ok=True)
    elif operation == 'rmdir':
        if path.is_symlink(): path.unlink()
        elif path.exists(): shutil.rmtree(path)
    elif operation == 'symlink':
        os.symlink(args[0], args[1])
    elif operation == 'readlink':
        sys.stdout.write(os.readlink(path))
    elif operation == 'realpath':
        sys.stdout.write(str(path.resolve(strict=True)))
    elif operation == 'count':
        print(len(list(path.iterdir())))
    elif operation == 'isdir':
        print('1' if path.is_dir() else '0')
    elif operation == 'islink':
        print('1' if path.is_symlink() else '0')
    else:
        raise SystemExit('unknown operation: ' + operation)
