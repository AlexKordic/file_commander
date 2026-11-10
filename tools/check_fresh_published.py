#!/usr/bin/env python3
"""Check that the Fresh fork's published branch is at the pinned revision. Needs network; run before a release."""
import json
from pathlib import Path
import subprocess
import sys

spec = json.loads((Path(__file__).resolve().parent.parent / 'dependencies.json').read_text())['git']['fresh']
remote = sys.argv[1] if len(sys.argv) > 1 else spec['fork']
head = 'refs/heads/' + spec['branch']
listing = subprocess.run(['git', 'ls-remote', remote, head], check=True, capture_output=True, text=True, timeout=60).stdout
published = listing.split()[0] if listing.strip() else 'nothing'
if published != spec['revision']:
    raise SystemExit(f"{remote}: {spec['branch']} is at {published}, but dependencies.json pins {spec['revision']}; push {spec['branch']}.")
print(f"PASS {remote} publishes the pinned Fresh revision on {spec['branch']}")
