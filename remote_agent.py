"""FC filesystem agent. Embedded into fc and sent to python3 over SSH stdin.

Paths are base64 encoded OS bytes. Mutations never resolve the final symlink.
The helper speaks protocol 1 on stdout; stderr is reserved for diagnostics.
"""
import base64
import errno
import grp
import hashlib
import json
import os
import pwd
import shutil
import stat
import sys
import time


def encode(value):
    return base64.b64encode(os.fsencode(value)).decode("ascii")


def path(params, key="path"):
    value = os.fsdecode(base64.b64decode(params[key + "64"], validate=True))
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
        result["link64"] = encode(os.readlink(value))
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


def digest(value):
    h = hashlib.sha256()
    with open(value, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def dispatch(method, p, send):
    value = path(p) if "path64" in p else None
    if method == "stat":
        return stamp(value, p.get("follow", False))
    if method == "list":
        entries = []
        with os.scandir(value) as directory:
            for entry in directory:
                info = stamp(entry.path)
                if not info["exists"]:
                    continue
                info["name64"] = encode(entry.name)
                if entry.is_symlink():
                    info["target_dir"] = entry.is_dir()
                entries.append(info)
                if len(entries) >= 256:
                    send({"entries": entries})
                    entries = []
        return {"entries": entries}
    if method == "realpath":
        return {"path64": encode(os.path.realpath(value))}
    if method == "read":
        with open(value, "rb") as f:
            f.seek(p["offset"])
            return {"data": base64.b64encode(f.read(min(p["length"], 1024 * 1024))).decode("ascii")}
    if method == "write":
        flags = os.O_WRONLY | os.O_NOFOLLOW
        if p.get("exclusive"):
            flags |= os.O_CREAT | os.O_EXCL
        fd = os.open(value, flags, 0o600)
        try:
            os.lseek(fd, p["offset"], os.SEEK_SET)
            data = base64.b64decode(p["data"], validate=True)
            while data:
                n = os.write(fd, data)
                data = data[n:]
            os.fsync(fd)
        finally:
            os.close(fd)
        return {}
    if method == "mkdir":
        os.mkdir(value, 0o700)
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
        if not p.get("replace") and os.path.lexists(destination):
            raise FileExistsError(errno.EEXIST, "Destination already exists", destination)
        os.rename(value, destination)
        sync_directory(os.path.dirname(destination))
        sync_directory(os.path.dirname(value))
        return {}
    if method == "symlink":
        os.symlink(os.fsdecode(base64.b64decode(p["target64"], validate=True)), value)
        return {}
    if method == "metadata":
        if not stat.S_ISLNK(os.lstat(value).st_mode):
            os.chmod(value, p["mode"] & 0o7777)
        os.utime(value, ns=(p["mtime_ns"], p["mtime_ns"]), follow_symlinks=False)
        return {}
    if method == "digest":
        return {"sha256": digest(value)}
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


def main():
    print(json.dumps({"ready": 1, "version": 1}), flush=True)
    for line in sys.stdin:
        request = json.loads(line)
        request_id = request["id"]

        def send(data):
            print(json.dumps({"id": request_id, "data": data}, ensure_ascii=True), flush=True)

        try:
            result = dispatch(request["method"], request["params"], send)
            print(json.dumps({"id": request_id, "result": result}, ensure_ascii=True), flush=True)
        except Exception as error:
            print(json.dumps({"id": request_id, "error": str(error),
                              "errno": getattr(error, "errno", 0) or 0}, ensure_ascii=True), flush=True)


if __name__ == "__main__":
    main()
