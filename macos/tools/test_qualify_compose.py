#!/usr/bin/env python3
"""Fixture isolation and remote cleanup contracts; no GUI or SSH connection."""
import inspect
import io
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import unittest
import uuid

import qualify_compose as q


class QualificationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fc-cq-tool-")
        self.addCleanup(self.temporary.cleanup)
        self.local = Path(self.temporary.name)
        self.nonce = uuid.uuid4().hex
        self.remote = Path("/tmp") / ("fc-compose-check-" + self.nonce)
        self.addCleanup(self.clean_remote)

    def clean_remote(self):
        if self.remote.is_symlink():
            self.remote.unlink()
        elif self.remote.is_dir():
            shutil.rmtree(self.remote)

    def remote_command(self, action, archive=b"", nonce=None):
        source = inspect.getsource(q.remote_fixture) + "\nremote_fixture()\n"
        return subprocess.run([sys.executable, "-c", source, action, nonce or self.nonce],
                              input=archive, capture_output=True, timeout=10)

    def archive(self, names=("compose.md", "sample.png")):
        stream = io.BytesIO()
        with tarfile.open(fileobj=stream, mode="w:") as tar:
            for name in names:
                item = tarfile.TarInfo(name); item.size = 3
                tar.addfile(item, io.BytesIO(b"a\0b"))
        return stream.getvalue()

    def test_fixture_has_exact_crlf_unicode_and_binary_png(self):
        q.fixture_files(self.local / "files")
        text = (self.local / "files/compose.md").read_bytes()
        self.assertNotIn(b"\n", text.replace(b"\r\n", b""))
        self.assertIn("é 👩🏽‍💻 日本語".encode(), text)
        self.assertIn(b"![Inline PNG](sample.png)", text)
        image = (self.local / "files/sample.png").read_bytes()
        self.assertEqual(image[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II", image[16:24]), (160, 80))

    def test_environment_is_private_and_preserves_normal_authentication(self):
        original = {"HOME": "/user/home", "TMPDIR": "/user/tmp", "SSH_AUTH_SOCK": "/user/agent",
                    "FC_SSH_BIN": "/stub", "FC_LEGACY_CHECKPOINT": "/user/checkpoint", "FC_OTHER": "inherited",
                    "DYLD_INSERT_LIBRARIES": "/uid-shim", "PATH": "/usr/bin"}
        env = q.private_environment(self.local, original)
        self.assertEqual(original["HOME"], "/user/home")
        for key in ("HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "FRESH_FC_DATA_DIR"):
            self.assertTrue(Path(env[key]).is_relative_to(self.local))
        self.assertEqual(env["SSH_AUTH_SOCK"], "/user/agent")
        self.assertEqual(env["PATH"], "/usr/bin")
        for key in ("FC_SSH_BIN", "FC_LEGACY_CHECKPOINT", "FC_OTHER", "DYLD_INSERT_LIBRARIES"):
            self.assertNotIn(key, env)
        self.assertEqual(env["FC_NATIVE_RICH_COMPOSE"], "1")

    def test_remote_binary_fixture_refuses_overwrite_and_wrong_marker_cleanup(self):
        created = self.remote_command("create", self.archive())
        self.assertEqual(created.returncode, 0, created.stderr)
        self.assertEqual(json.loads(created.stdout)["root"], str(self.remote))
        self.assertEqual((self.remote / "sample.png").read_bytes(), b"a\0b")
        self.assertEqual(self.remote.stat().st_mode & 0o777, 0o700)
        self.assertNotEqual(self.remote_command("create", self.archive()).returncode, 0)
        self.assertEqual(self.remote_command("check").returncode, 0)
        (self.remote / ".owner").write_text("wrong")
        self.assertNotEqual(self.remote_command("remove").returncode, 0)
        self.assertTrue((self.remote / "compose.md").exists())
        (self.remote / ".owner").write_text(self.nonce)
        self.assertEqual(self.remote_command("remove").returncode, 0)
        self.assertFalse(self.remote.exists())

    def test_remote_rejects_unsafe_archive_before_creating_any_directory(self):
        for names in (("../escape",), ("/absolute",), (".owner",), ("same", "same")):
            with self.subTest(names=names):
                result = self.remote_command("create", self.archive(names))
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.remote.exists())
        self.assertNotEqual(self.remote_command("create", self.archive(), nonce="../other").returncode, 0)
        self.assertFalse(self.remote.exists())

    def test_remote_cleanup_refuses_symlink_root_and_symlink_marker(self):
        target = self.local / "target"; target.mkdir()
        (target / ".owner").write_text(self.nonce)
        self.remote.symlink_to(target)
        self.assertNotEqual(self.remote_command("remove").returncode, 0)
        self.assertTrue(target.exists())
        self.remote.unlink(); self.remote.mkdir()
        (self.remote / ".owner").symlink_to(target / ".owner")
        self.assertNotEqual(self.remote_command("remove").returncode, 0)
        self.assertTrue(target.exists())

    def test_active_launch_lock_refuses_a_second_launcher_and_recovers_after_release(self):
        with q.locked(self.local):
            with self.assertRaisesRegex(ValueError, "already running"):
                with q.locked(self.local):
                    self.fail("Acquired an active launch lock")
        with q.locked(self.local):
            pass

    def test_manifest_cannot_redirect_profile_or_reuse_another_owner(self):
        (self.local / ".owner").write_text(self.nonce)
        record = dict(format=1, root=str(self.local.resolve()), nonce=self.nonce)
        q.write_json(self.local / "manifest.json", record)
        self.assertEqual(q.load_manifest(self.local)[0], self.local.resolve())
        record["root"] = "/different/profile"
        q.write_json(self.local / "manifest.json", record)
        with self.assertRaisesRegex(ValueError, "manifest"):
            q.load_manifest(self.local)
        record["root"] = str(self.local.resolve())
        q.write_json(self.local / "manifest.json", record)
        (self.local / ".owner").write_text("another owner")
        with self.assertRaisesRegex(ValueError, "ownership"):
            q.load_manifest(self.local)


if __name__ == "__main__":
    unittest.main()
