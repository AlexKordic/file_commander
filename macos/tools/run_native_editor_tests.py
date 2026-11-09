#!/usr/bin/env python3
"""Qualify the compiled native editor suite against an explicit engine/Fresh pair.

Runs private offscreen views and disposable backend sessions. Actual macOS
input methods, VoiceOver and live SSH remain separate interactive checks.
"""
import argparse
from collections import Counter
import datetime
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test"))
from lua_runner import process_tree

TARGETS = ("FreshKitTests", "NativeEditorTests")
FILTER = r"^(FreshKitTests|NativeEditorTests)\."


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def discover(text, required):
    names = [line.strip() for line in text.splitlines()
             if re.fullmatch(r"(?:FreshKitTests|NativeEditorTests)\.[A-Za-z0-9_]+/test[A-Za-z0-9_]+", line.strip())]
    counts = Counter(names)
    if not names or any(count != 1 for count in counts.values()):
        raise ValueError("Native test discovery is empty or contains duplicates")
    suites = {name.split("/")[0] for name in names}
    missing = set(required) - suites
    if missing:
        raise ValueError("Required native suites missing: " + ", ".join(sorted(missing)))
    if {name.split(".")[0] for name in names} != set(TARGETS):
        raise ValueError("Native discovery must include both test targets")
    return sorted(names)


def results(text, expected):
    # Swift's swiftbuild driver currently accepts --xunit-output but does not
    # emit it. Verify complete XCTest case receipts against compiled discovery;
    # an unfamiliar format, partial run, duplicate or skip fails closed.
    receipts = []
    aliases = {}
    for name in expected:
        suite, method = name.split("/")
        for alias in (f"-[{suite} {method}]", f"{suite}.{method}", f"{suite.split('.')[-1]}.{method}"):
            aliases.setdefault(alias, []).append(name)
    for line in text.splitlines():
        match = re.fullmatch(r"Test Case '([^']+)' (passed|failed|skipped) \(([0-9.]+) seconds\)\.", line.strip())
        if not match:
            continue
        name, status, seconds = match.groups()
        if len(aliases.get(name, [])) != 1:
            raise ValueError("Unexpected or ambiguous native test receipt: " + name)
        receipts.append({"name": aliases[name][0], "status": status, "seconds": float(seconds)})
    counts = Counter(item["name"] for item in receipts)
    missing = set(expected) - counts.keys()
    duplicates = {name for name, count in counts.items() if count != 1}
    if missing or duplicates:
        raise ValueError(f"Incomplete native results: missing={sorted(missing)}, duplicates={sorted(duplicates)}")
    return receipts


def write_results(path, receipts):
    suite = ET.Element("testsuite", name="fc.macos.native_editor", tests=str(len(receipts)),
                       failures=str(sum(item["status"] == "failed" for item in receipts)),
                       skipped=str(sum(item["status"] == "skipped" for item in receipts)))
    for item in receipts:
        name, method = item["name"].split("/")
        case = ET.SubElement(suite, "testcase", classname=name, name=method, time=str(item["seconds"]))
        if item["status"] != "passed":
            ET.SubElement(case, "skipped" if item["status"] == "skipped" else "failure")
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def execute(command, path, env, timeout, metadata, check=True):
    record = {"argv": list(map(str, command)), "log": path.name}
    metadata["commands"].append(record)
    start = time.monotonic()
    with path.open("w") as log:
        process = subprocess.Popen(command, cwd=ROOT, env=env, stdin=subprocess.DEVNULL,
                                   stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        known = {}
        try:
            while process.poll() is None:
                process_tree(process.pid, known)
                remaining = timeout - (time.monotonic() - start)
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout)
                try:
                    process.wait(timeout=min(0.1, remaining))
                except subprocess.TimeoutExpired:
                    pass
            status = process.returncode
        finally:
            try:
                # Foundation's XCTest/Fresh processes can own separate groups.
                # Use the shared supervisor's observed ancestry/start identities.
                table = process_tree(process.pid, known)
                retired = []
                for pid, identity in known.items():
                    if pid in table and table[pid][1] == identity:
                        try:
                            os.kill(pid, signal.SIGKILL); retired.append(pid)
                        except ProcessLookupError:
                            pass
                record["retired_descendants"] = retired
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=3)
    record.update(status=status, seconds=time.monotonic() - start)
    if status and check:
        raise ValueError(f"Native test command exited {status}; see {path}")
    return path.read_text()


def run(args):
    if platform.system() != "Darwin":
        raise ValueError("Native editor qualification requires macOS")
    engine, fresh = args.engine_build.resolve(), args.fresh.resolve()
    archive = engine / "libfc_engine_bundle.a"
    for path in (archive, fresh):
        if not path.is_file() or not path.stat().st_size:
            raise ValueError("Missing qualification input: " + str(path))
    if not os.access(fresh, os.X_OK):
        raise ValueError("Fresh qualification input is not executable: " + str(fresh))
    parent = Path(os.environ.get("FC_TEST_LOG_ROOT", engine / "test-logs"))
    output = parent / ("native-editor-" + uuid.uuid4().hex[:10])
    output.mkdir(parents=True)
    metadata = {"started": datetime.datetime.now(datetime.timezone.utc).isoformat(), "os": platform.platform(),
                "configuration": args.configuration, "engine_archive": str(archive), "fresh": str(fresh),
                "engine_sha256": sha256(archive), "fresh_sha256": sha256(fresh),
                "scope": "Compiled FreshKit and NativeEditor tests, including real private Fresh backend workflows; no actual GUI/IME/VoiceOver/live SSH qualification",
                "status": "running", "commands": []}
    print("Native editor artifacts:", output, flush=True)
    try:
        env = dict(os.environ, FC_ENGINE_LIBRARY_DIR=str(engine), FC_COMPOSE_TEST_FRESH=str(fresh),
                   FC_COMPOSE_ARTIFACT_DIR=str(output / "fixtures"), FC_REQUIRE_CAPABILITIES="1")
        base = [str(args.swift), "test", "--package-path", str(ROOT / "macos"),
                "--scratch-path", str(args.scratch_path.resolve()), "--configuration", args.configuration,
                "--disable-automatic-resolution"]
        required = json.loads((ROOT / "macos/Tests/required_editor_suites.json").read_text())
        discovery = execute(base + ["list"], output / "discovery.log", env, 600, metadata)
        expected = discover(discovery, required)
        (output / "discovery.json").write_text(json.dumps(expected, indent=2) + "\n")
        products = execute([base[0], "build"] + base[2:] + ["--show-bin-path"], output / "products.log", env, 60, metadata).strip()
        directory = Path(products)
        if not directory.is_absolute() or not directory.is_dir():
            raise ValueError("Swift did not identify its compiled products directory")
        binaries = [path for path in directory.glob("*.xctest/Contents/MacOS/*") if path.is_file() and os.access(path, os.X_OK)]
        if not binaries:
            raise ValueError("Compiled XCTest executables are missing")
        metadata["native_test_sha256"] = {str(path): sha256(path) for path in binaries}
        text = execute(base + ["--skip-build", "--filter", FILTER], output / "tests.log", env, 480, metadata, check=False)
        receipts = results(text, expected)
        write_results(output / "results.xml", receipts)
        metadata["tests"] = len(receipts)
        metadata["suites"] = dict(Counter(item["name"].split("/")[0] for item in receipts))
        metadata["skipped"] = [item["name"] for item in receipts if item["status"] == "skipped"]
        metadata["failed"] = [item["name"] for item in receipts if item["status"] == "failed"]
        if metadata["skipped"] or metadata["failed"]:
            raise ValueError("Native qualification refuses failed or skipped test cases")
        if metadata["commands"][-1]["status"]:
            raise ValueError("Native test driver failed despite complete passing case receipts")
        if sha256(archive) != metadata["engine_sha256"] or sha256(fresh) != metadata["fresh_sha256"]:
            raise ValueError("Qualification inputs changed while tests were running")
        if any(sha256(Path(path)) != expected_hash for path, expected_hash in metadata["native_test_sha256"].items()):
            raise ValueError("Compiled XCTest executables changed while tests were running")
        metadata["status"] = "passed"
        print(f"PASS {len(receipts)} compiled native tests, no skips; engine/Fresh hashes retained", flush=True)
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        metadata.update(status="failed", error=str(error))
        raise
    finally:
        metadata["finished"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine-build", type=Path, required=True)
    parser.add_argument("--fresh", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True)
    parser.add_argument("--swift", type=Path, default=Path("swift"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    run(parser.parse_args())


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        sys.exit(str(error))
