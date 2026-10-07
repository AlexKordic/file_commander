"""FC filesystem agent. Embedded into fc and sent to python3 over SSH stdin.

Paths are base64 encoded OS bytes. Mutations never resolve the final symlink.
The helper speaks protocol 1 on stdout; stderr is reserved for diagnostics.
"""
import base64
import errno
import ctypes
import grp
import hashlib
import json
import os
import pwd
import shutil
import stat
import sys
import time


def attributes(value):
    if hasattr(os, "listxattr"):
        return {encode(name): base64.b64encode(os.getxattr(value, name, follow_symlinks=False)).decode("ascii")
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
        out[encode(name)] = base64.b64encode(data.raw[:count]).decode("ascii")
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


def digest(value, send):
    h = hashlib.sha256()
    total = 0
    with open(value, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
            total += len(block)
            send({"bytes": total})
    return h.hexdigest()


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
            if any(current.get(key, "" if key == "link64" else None) != data for key, data in p["expected"].items()):
                raise OSError(errno.ESTALE, "Destination changed before commit", destination)
        if p.get("replace"):
            os.rename(value, destination)
        else:
            rename_exclusive(value, destination)
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
        return {"sha256": digest(value, send)}
    if method == "fsync":
        if not os.path.islink(value):
            sync_directory(value)
        return {}
    if method == "access":
        return {"allowed": os.access(value, p["mode"])}
    if method == "tree":
        entries = [{"relative64": "", "stamp": stamp(value, p.get("follow", False))}]
        if p.get("recursive", True) and stat.S_ISDIR(entries[0]["stamp"].get("mode", 0)):
            for root, directories, files in os.walk(value, followlinks=False):
                for name in directories + files:
                    child = os.path.join(root, name)
                    entries.append({"relative64": encode(os.path.relpath(child, value)), "stamp": stamp(child)})
                    if len(entries) >= 256:
                        send({"entries": entries})
                        entries = []
        return {"entries": entries}
    if method == "attributes":
        attrs = attributes(value)
        acl = acl_present(value) or any(base64.b64decode(name).startswith(b"system.posix_acl_") for name in attrs)
        return {"attributes": attrs, "platform": sys.platform, "acl": acl}
    if method == "set_attributes":
        for name, data in p["attributes"].items():
            name, data = base64.b64decode(name), base64.b64decode(data)
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
                if p.get("checkpoint") and sys.stdin.readline() != "continue\n":
                    raise OSError(errno.ECANCELED, "Copy coordinator disconnected")
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
