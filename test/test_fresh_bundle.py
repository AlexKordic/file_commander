"""Reconstruct the pinned Fresh revision from its upstream base and local bundle."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

repo = Path(__file__).resolve().parent.parent
spec = json.loads((repo / "dependencies.json").read_text())["git"]["fresh"]
bundle = repo / spec["bundle"]
assert hashlib.sha256(bundle.read_bytes()).hexdigest() == spec["bundle_sha256"]
with tempfile.TemporaryDirectory(prefix="fc-fresh-bundle-") as directory:
    def git(*args):
        return subprocess.check_output(["git", "-C", directory, *args], text=True, stderr=subprocess.PIPE)
    git("init", "--quiet")
    git("fetch", "--quiet", "--depth=1", str(Path(sys.argv[1]).resolve()), spec["base_revision"])
    git("checkout", "--quiet", "--detach", "FETCH_HEAD")
    git("bundle", "verify", str(bundle))
    git("fetch", "--quiet", str(bundle), "refs/heads/fc-editor-workflow")
    git("checkout", "--quiet", "--detach", spec["revision"])
    assert git("rev-parse", "HEAD").strip() == spec["revision"]
    assert not git("status", "--porcelain").strip()
    assert (Path(directory) / "crates/fresh-editor/src/app/session_recovery.rs").is_file()
print("PASS reproducible Fresh checkout from upstream base and fingerprinted bundle")
