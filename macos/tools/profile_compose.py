#!/usr/bin/env python3
"""Profile actual Fresh parser/projection/wire inputs and native Core Text layout.

This is an explicit resource experiment, not interactive or release qualification.
It creates no backend session, opens no window and accesses no system clipboard.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]


def capture(command, cwd=ROOT):
    return subprocess.check_output(command, cwd=cwd, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fresh", type=Path, required=True, help="matching Fresh source checkout")
    parser.add_argument("--output", type=Path, required=True, help="artifact directory")
    parser.add_argument("--profile", choices=("debug", "release"), default="debug")
    args = parser.parse_args()
    fresh, output = args.fresh.resolve(), args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    metadata = {
        "started": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "profile": args.profile,
        "os": platform.platform(),
        "machine": platform.machine(),
        "fc_head": capture(["git", "rev-parse", "HEAD"]),
        "fresh_head": capture(["git", "rev-parse", "HEAD"], fresh),
        "fc_dirty": bool(capture(["git", "status", "--porcelain"])),
        "fresh_dirty": bool(capture(["git", "status", "--porcelain"], fresh)),
        "swift": capture(["swift", "--version"]),
        "rust": capture(["rustc", "--version"]),
        "commands": [],
        "scope": "isolated parser/projection/encoding and native layout; not plugin, image-decode, drawing or typing-to-paint qualification",
    }
    if platform.system() == "Darwin":
        metadata["hardware"] = {key: capture(["sysctl", "-n", key]) for key in ("hw.model", "hw.memsize", "hw.ncpu", "machdep.cpu.brand_string")}

    def run(command, log, cwd=ROOT, env=None):
        record = {"argv": list(map(str, command)), "cwd": str(cwd), "log": log}
        metadata["commands"].append(record)
        start = time.monotonic()
        print(f"Running {log}", flush=True)
        with (output / log).open("w") as stream:
            result = subprocess.run(command, cwd=cwd, env=env, stdout=stream, stderr=subprocess.STDOUT)
        record["wall_seconds"] = time.monotonic() - start
        record["exit_code"] = result.returncode
        (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
        result.check_returncode()

    cargo = ["cargo", "test", "--locked", "-p", "fresh-editor", "--features", "web", "--lib"]
    if args.profile == "release":
        cargo.append("--release")
    cargo += ["profile_rich_compose_document_workloads", "--", "--ignored", "--nocapture"]
    run(cargo, "backend.log", cwd=fresh, env=dict(os.environ, FC_COMPOSE_PROFILE_OUTPUT=str(output)))
    metadata["fixture_sha256"] = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in sorted(output.glob("*.pb"))}
    build = ["swift", "build", "--package-path", str(ROOT / "macos"), "-c", args.profile]
    run(build + ["--product", "fc-compose-profile"], "native-build.log")
    binary = Path(capture(build + ["--show-bin-path"])) / "fc-compose-profile"
    run([str(binary), str(output), str(output / "native.json")], "native.log")
    print(f"Artifacts: {output}")
    backend = json.loads((output / "backend.json").read_text())
    native = {case["case"]: case for case in json.loads((output / "native.json").read_text())["cases"]}
    for case in backend["cases"]:
        layout = native[case["case"]]
        print(f"{case['case']}: {case['source_bytes']} source bytes; "
              f"parse max {max(case['parse_ms']):.2f} ms; "
              f"layout max {max(layout['cold_layout_ms']):.2f} ms; "
              f"retained max {max(layout['retained_layout_ms']):.2f} ms; "
              f"{case['pane_bytes']} pane bytes")


if __name__ == "__main__":
    main()
