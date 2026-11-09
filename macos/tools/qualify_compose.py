#!/usr/bin/env python3
"""Prepare an isolated app and disposable fixtures for interactive Compose checks.

Uses already-built products and an explicitly supplied matching Fresh binary.
Preparing does not launch an app, contact SSH or change an installed app.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import inspect
import io
import json
import os
from pathlib import Path
import plistlib
import re
import shlex
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import uuid
import zlib


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def write_json(path, value):
    temporary = path.with_suffix(".new")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def fixture_files(root):
    """Small sources with exact CRLF bytes; binary images are never source text."""
    root.mkdir(mode=0o700, parents=True)
    width, height = 160, 80
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))
    pixels = b"".join(b"\0" + b"".join(bytes((x * 255 // width, y * 255 // height, 128))
                                      for x in range(width)) for y in range(height))
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
    (root / "sample.png").write_bytes(png)
    source = """# Compose qualification

Proportional text: iiiiii WWWWWW café é 👩🏽‍💻 日本語 العربية עברית.
Resize the pane: prose should use available pixels rather than fixed columns.

## Heading two
### Heading three
#### Heading four
##### Heading five
###### Heading six

Setext heading
==============

**Bold**, *emphasis*, ~~strike~~ and [a link](https://example.invalid).
Before ![Inline PNG](sample.png) after. Edit its alt text and destination.

![Block JPEG](sample.jpg)

![Missing image keeps editable source](missing.png)

> A quote with **nested emphasis**.
>
> 1. A list item with a proportional continuation that should keep its indent.
>    - Nested item with ![small image](sample.png).
>
>    ```swift
>    let greeting = "café 👩🏽‍💻"
>    ```

| Name | Value | Image |
| :--- | ---: | :---: |
| Proportional prose | 42 | ![Cell PNG](sample.png) |
| 日本語 é | 123456 | source remains editable |

---

""" + "\n\n".join(("Paragraph %d. " % i) + ("Wide words WWWW and narrow iii, Unicode café 👩🏽‍💻. " * 8)
                        for i in range(1, 25)) + "\n"
    (root / "compose.md").write_bytes(source.replace("\n", "\r\n").encode())
    (root / "second.md").write_text("# Second editor tab\n\nKeep an unsaved edit here while switching to the first tab.\n")


def private_environment(root, inherited):
    env = {key: value for key, value in inherited.items() if not key.startswith("FC_")}
    for key, name in {"HOME": "home", "CFFIXED_USER_HOME": "home", "TMPDIR": "tmp",
                      "XDG_CONFIG_HOME": "config", "XDG_DATA_HOME": "data", "XDG_CACHE_HOME": "cache",
                      "XDG_STATE_HOME": "state", "XDG_RUNTIME_DIR": "runtime", "FRESH_FC_DATA_DIR": "session"}.items():
        env[key] = str(root / name)
    for key in ("DYLD_INSERT_LIBRARIES",):
        env.pop(key, None)
    env["FC_EDITOR_SWITCH_KEY"] = "f10"
    env["FC_FRESH_BIN"] = str(root / "Compose Check.app/Contents/MacOS/fresh")
    return env


def remote_fixture():
    # Sent as Python source over SSH. All imports are local so this function
    # also runs independently on the remote host, without installing a helper.
    import io
    import json
    import os
    from pathlib import Path, PurePosixPath
    import re
    import shutil
    import stat
    import sys
    import tarfile

    action, nonce = sys.argv[1:]
    if not re.fullmatch(r"[a-f0-9]{32}", nonce):
        raise ValueError("Invalid fixture identity")
    root = Path("/tmp") / ("fc-compose-check-" + nonce)
    if action == "create":
        archive = sys.stdin.buffer.read(4 * 1024 * 1024 + 1)
        if len(archive) > 4 * 1024 * 1024:
            raise ValueError("Fixture archive exceeds 4 MiB")
        # Validate before creating anything. This tool uploads only flat files.
        with tarfile.open(fileobj=io.BytesIO(archive), mode="r:") as tar:
            entries = tar.getmembers()
            if not entries or len({item.name for item in entries}) != len(entries) or any(not item.isfile() or item.sparse is not None
                                  or item.size > 4 * 1024 * 1024 or PurePosixPath(item.name).name != item.name
                                  or len(PurePosixPath(item.name).parts) != 1
                                  or item.name in (".", "..", ".owner") or item.name.startswith("/")
                                  for item in entries):
                raise ValueError("Invalid fixture archive member")
            root.mkdir(mode=0o700)  # Never reuse or overwrite another fixture.
            (root / ".owner").write_text(nonce)
            for item in entries:
                with (root / item.name).open("xb") as output:
                    output.write(tar.extractfile(item).read())
    elif action in ("check", "remove"):
        metadata = root.lstat()
        marker = root / ".owner"
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.getuid() or marker.is_symlink() or marker.read_text() != nonce:
            raise ValueError("Fixture ownership does not match; retained")
        if action == "remove":
            shutil.rmtree(root)
    else:
        raise ValueError("Unknown fixture action")
    print(json.dumps({"root": str(root), "action": action}))


def ssh_fixture(host, action, nonce, archive=None):
    # A host alias only, rather than an arbitrary SSH argv or URL.
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", host):
        raise ValueError("Use an SSH host alias such as dev")
    source = inspect.getsource(remote_fixture) + "\nremote_fixture()\n"
    command = shlex.join(["python3", "-c", source, action, nonce])
    result = subprocess.run(["/usr/bin/ssh", "-oBatchMode=yes", "-oConnectTimeout=10", host, command],
                            input=archive or b"", capture_output=True, timeout=40)
    if result.returncode:
        raise RuntimeError(result.stderr.decode(errors="replace").strip())
    record = json.loads(result.stdout)
    if record != {"root": "/tmp/fc-compose-check-" + nonce, "action": action}:
        raise ValueError("Unexpected remote fixture reply")
    return record["root"]


def load_manifest(directory):
    root = Path(directory).resolve()
    record = json.loads((root / "manifest.json").read_text())
    if record.get("format") != 1 or record.get("root") != str(root) or not re.fullmatch(r"[a-f0-9]{32}", record.get("nonce", "")):
        raise ValueError("Invalid qualification manifest")
    if (root / ".owner").read_text() != record["nonce"]:
        raise ValueError("Qualification ownership does not match")
    return root, record


@contextmanager
def locked(root):
    with (root / "run.lock").open("a") as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("This test app is already running; quit it normally first") from None
        yield


def prepared_inputs(products, fresh, engine):
    """Check every input before creating an app or a private profile."""
    files = {name: products / name for name in ("FileCommander", "fc-relaunch", "fc-askpass")}
    files.update(fresh=fresh, fc=engine / "fc", **{"7z.so": engine / "third_party/7zip/_o/7z.so"})
    for path in files.values():
        if not path.is_file():
            raise ValueError("Missing built product: " + str(path))
    resources = [products / name for name in ("FileCommander_FileCommander.bundle", "SwiftProtobuf_SwiftProtobuf.bundle")]
    # SwiftTerm 1.11.2 has no resource target. Older products can still contain
    # its bundle; include it when present, without requiring a nonexistent one.
    swiftterm = products / "SwiftTerm_SwiftTerm.bundle"
    if swiftterm.exists():
        resources.append(swiftterm)
    for path in resources:
        if not path.is_dir():
            raise ValueError("Missing built resource bundle: " + str(path))
    return files, resources


def prepare(args):
    if sys.platform != "darwin":
        raise ValueError("App preparation requires macOS")
    products, fresh, engine = args.products.resolve(), args.fresh.resolve(), args.engine_build.resolve()
    files, resource_bundles = prepared_inputs(products, fresh, engine)
    root = Path(tempfile.mkdtemp(prefix="fc-cq-", dir="/tmp")).resolve()
    nonce = uuid.uuid4().hex
    (root / ".owner").write_text(nonce)
    for name in ("home", "config", "data", "cache", "state", "runtime", "session", "tmp", "logs"):
        (root / name).mkdir(mode=0o700)
    app = root / "Compose Check.app"
    binaries, resources = app / "Contents/MacOS", app / "Contents/Resources"
    binaries.mkdir(parents=True); resources.mkdir()
    for name, path in files.items():
        shutil.copy2(path, binaries / name)
    for path in resource_bundles:
        shutil.copytree(path, resources / path.name)
    info = dict(CFBundleIdentifier="org.filecommander.composecheck." + nonce, CFBundleName="Compose Check",
                CFBundleDisplayName="File Commander Compose Check", CFBundleExecutable="FileCommander",
                CFBundlePackageType="APPL", CFBundleShortVersionString="0.0.0", CFBundleVersion="1",
                LSMinimumSystemVersion="14.0", NSHighResolutionCapable=True, NSPrincipalClass="NSApplication")
    with (app / "Contents/Info.plist").open("wb") as stream:
        plistlib.dump(info, stream)
    repo = Path(__file__).resolve().parents[2]
    with (root / "logs/signing.log").open("w") as log:
        subprocess.run([str(repo / "macos/tools/sign_app.sh"), str(app)],
                       env=dict(os.environ, FC_CODESIGN_IDENTITY="-"), stdout=log, stderr=log, check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], stdout=log, stderr=log, check=True)
    fixture_files(root / "files")
    subprocess.run(["/usr/bin/sips", "-s", "format", "jpeg", str(root / "files/sample.png"),
                    "--out", str(root / "files/sample.jpg")], capture_output=True, check=True)
    fresh_config = root / "home/.config/fresh/config.json"
    fresh_config.parent.mkdir(parents=True)
    write_json(fresh_config, {"check_for_updates": False,
               "plugins": {"orchestrator": {"settings": {"autoOpenDock": "never"}},
                           "welcome_screen": {"settings": {"showOnStartup": False}}}})
    profile = root / "config/file_commander"
    profile.mkdir()
    write_json(profile / "app_settings.json", {"welcomeShown": True, "terminalEditor": False,
               "editorWasOpen": False, "editorTelemetry": True})
    shutil.copy2(__file__, root / "qualify.py")
    for name, extra in (("launch.command", []), ("launch-dev.command", ["--remote", "dev"])):
        (root / name).write_text("#!/bin/sh\nexec " + shlex.join([sys.executable, str(root / "qualify.py"), "run", str(root)] + extra) + "\n")
        (root / name).chmod(0o700)
    shutil.copy2(repo / "macos/tools/compose_manual_checklist.md", root / "CHECKLIST.md")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=True).stdout.strip()
    record = dict(format=1, root=str(root), nonce=nonce, source_head=head, manual_verified=False,
                  source_note="Source reference only; executable SHA-256 hashes identify the prepared build.",
                  bundle_id=info["CFBundleIdentifier"], remote=None,
                  binaries={name: digest(binaries / name) for name in files},
                  fixture_sha256={path.name: digest(path) for path in sorted((root / "files").iterdir())})
    write_json(root / "manifest.json", record)
    print(json.dumps({"prepared": str(root), "launch": str(root / "launch.command"),
                      "ssh_dev_launch": str(root / "launch-dev.command"), "manual_verified": False}, indent=2))


def run(args):
    root, record = load_manifest(args.directory)
    with locked(root):
        return launch(root, record, args.remote)


def launch(root, record, host):
    for name, expected in record["binaries"].items():
        if digest(root / "Compose Check.app/Contents/MacOS" / name) != expected:
            raise ValueError("Prepared binary changed: " + name)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(root / "Compose Check.app")], check=True)
    right = str(root / "files")
    if host:
        if record["remote"]:
            if record["remote"]["host"] != host:
                raise ValueError("This fixture belongs to another SSH host")
            remote = ssh_fixture(host, "check", record["nonce"])
        else:
            data = io.BytesIO()
            with tarfile.open(fileobj=data, mode="w:") as tar:
                for path in sorted((root / "files").iterdir()):
                    tar.add(path, arcname=path.name, recursive=False)
            remote = ssh_fixture(host, "create", record["nonce"], data.getvalue())
            record["remote"] = {"host": host, "path": remote}
            write_json(root / "manifest.json", record)
        right = "ssh://" + host + remote
    print("Checklist:", root / "CHECKLIST.md", flush=True)
    print("Private app; local panel:", root / "files", "right panel:", right, flush=True)
    print("Quit the test app normally. Its private backend is retained for restart checks.", flush=True)
    env = private_environment(root, os.environ)
    with (root / "logs/app.log").open("ab") as log:
        result = subprocess.run([str(root / "Compose Check.app/Contents/MacOS/FileCommander"), "--profile", str(root / "config"),
                                 str(root / "files"), right], cwd=root / "files", env=env, stdout=log, stderr=log)
    print("App exit:", result.returncode, "Logs:", root / "logs", flush=True)
    return result.returncode


def stop_backend(args):
    root, record = load_manifest(args.directory)
    with locked(root):
        session = json.loads((root / "config/file_commander/editor_session.json").read_text())["id"]
        if not re.fullmatch(r"fc-[A-Za-z0-9_-]+", session):
            raise ValueError("Invalid private editor identity")
        env = private_environment(root, os.environ)
        subprocess.run([env["FC_FRESH_BIN"], "--cmd", "session", "prepare-restart", session],
                       cwd=root / "files", env=env, timeout=30, check=True)
    print("Private backend checkpointed. The next launch uses its recovery data.")


def remove_remote(args):
    root, record = load_manifest(args.directory)
    with locked(root):
        if record["remote"]:
            ssh_fixture(record["remote"]["host"], "remove", record["nonce"])
            record["remote"] = None
            write_json(root / "manifest.json", record)
            print("Removed only this run's owned remote fixture. Local evidence retained.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    preparation = sub.add_parser("prepare", help="Assemble and verify; does not launch or contact SSH")
    preparation.add_argument("--products", type=Path, required=True)
    preparation.add_argument("--fresh", type=Path, required=True)
    preparation.add_argument("--engine-build", type=Path, default=Path(__file__).resolve().parents[2] / "build-macos")
    launch = sub.add_parser("run", help="Launch the private app from a normal macOS Terminal")
    launch.add_argument("directory", type=Path); launch.add_argument("--remote", metavar="SSH_ALIAS")
    for name in ("stop-backend", "remove-remote"):
        sub.add_parser(name).add_argument("directory", type=Path)
    args = parser.parse_args()
    return {"prepare": prepare, "run": run, "stop-backend": stop_backend, "remove-remote": remove_remote}[args.action](args)


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
