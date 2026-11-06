#!/usr/bin/env python3
"""Native gate negative controls: no Swift compiler, GUI, SSH or Fresh sessions."""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_native_editor_tests as gate

NAMES = ["FreshKitTests.ComposeTests/testMeasured", "NativeEditorTests.ComposeBackendTests/testBackend"]


class NativeGateTests(unittest.TestCase):
    def test_discovery_requires_both_targets_required_suites_and_unique_methods(self):
        required = [name.split("/")[0] for name in NAMES]
        self.assertEqual(gate.discover("\n".join(NAMES), required), NAMES)
        for text in ("", NAMES[0], "\n".join(NAMES + [NAMES[0]]), "\n".join(NAMES).replace("ComposeBackendTests", "OtherTests")):
            with self.subTest(text=text), self.assertRaises(ValueError):
                gate.discover(text, required)

    def test_complete_receipts_require_every_discovered_case_once(self):
        text = "\n".join(f"Test Case '-[{name.replace('/', ' ')}]' passed (0.001 seconds)." for name in NAMES)
        self.assertEqual([item["name"] for item in gate.results(text, NAMES)], NAMES)
        for modified in ("", text.splitlines()[0], text + "\n" + text.splitlines()[0], text.replace("testBackend", "testOther")):
            with self.subTest(text=modified), self.assertRaises(ValueError):
                gate.results(modified, NAMES)
        self.assertEqual(gate.results(text.replace("passed", "skipped"), NAMES)[0]["status"], "skipped")
        self.assertEqual(gate.results(text.replace("passed", "failed"), NAMES)[0]["status"], "failed")

    def test_classic_receipts_are_allowed_only_when_they_identify_one_discovered_method(self):
        text = "\n".join(f"Test Case '{name.replace('/', '.')}' passed (0.001 seconds)." for name in NAMES)
        self.assertEqual(len(gate.results(text, NAMES)), 2)
        ambiguous = ["FreshKitTests.SameTests/testOne", "NativeEditorTests.SameTests/testOne"]
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            gate.results("Test Case 'SameTests.testOne' passed (0.001 seconds).", ambiguous)

    def test_driver_rejects_false_green_results_and_changed_qualification_inputs(self):
        with tempfile.TemporaryDirectory(prefix="fc-native-gate-") as directory:
            root = Path(directory).resolve()
            registry = root / "macos/Tests/required_editor_suites.json"
            registry.parent.mkdir(parents=True)
            registry.write_text(json.dumps([name.split("/")[0] for name in NAMES]))
            engine = root / "engine"; engine.mkdir()
            fresh = root / "fresh"; fresh.write_text("fixture\n"); fresh.chmod(0o700)
            archive = engine / "libfc_engine_bundle.a"; archive.write_text("engine fixture\n")
            products = root / "products"
            executable = products / "NativeTests.xctest/Contents/MacOS/NativeTests"
            executable.parent.mkdir(parents=True); executable.write_text("compiled fixture"); executable.chmod(0o700)
            swift = root / "swift"
            swift.write_text("#!" + sys.executable + '''
import json, os, sys
from pathlib import Path
names = ['FreshKitTests.ComposeTests/testMeasured', 'NativeEditorTests.ComposeBackendTests/testBackend']
assert os.environ['FC_COMPOSE_TEST_FRESH'] == str(Path(__file__).with_name('fresh'))
assert os.environ['FC_ENGINE_LIBRARY_DIR'] == str(Path(__file__).with_name('engine'))
mode = os.environ['FC_NATIVE_GATE_CONTROL']
if '--show-bin-path' in sys.argv:
 print(Path(__file__).with_name('products'))
elif 'list' in sys.argv:
 if mode == 'empty': names = []
 if mode == 'missing_suite': names = names[:1]
 print('\\n'.join(names))
else:
 if mode == 'missing_result': names = names[:1]
 if mode == 'duplicate': names.append(names[0])
 if mode == 'unknown': names[0] = 'FreshKitTests.OtherTests/testOther'
 status = 'skipped' if mode == 'skip' else 'failed' if mode == 'failure' else 'passed'
 for name in names:
  print("Test Case '-[" + name.replace('/', ' ') + "]' " + status + ' (0.001 seconds).')
 if mode == 'changed_fresh': Path(os.environ['FC_COMPOSE_TEST_FRESH']).write_text('changed')
 if mode == 'changed_engine': (Path(os.environ['FC_ENGINE_LIBRARY_DIR']) / 'libfc_engine_bundle.a').write_text('changed')
 if mode == 'changed_tests': (Path(__file__).with_name('products') / 'NativeTests.xctest/Contents/MacOS/NativeTests').write_text('changed')
 if mode == 'nonzero': sys.exit(1)
''')
            swift.chmod(0o700)
            args = argparse.Namespace(engine_build=engine, fresh=fresh, scratch_path=root / "scratch", swift=swift, configuration="debug")
            for mode in ("pass", "empty", "missing_suite", "missing_result", "duplicate", "unknown", "skip", "failure", "nonzero", "changed_fresh", "changed_engine", "changed_tests"):
                with self.subTest(mode=mode), patch.object(gate, "ROOT", root), patch.object(gate.platform, "system", return_value="Darwin"), \
                     patch.dict(os.environ, FC_TEST_LOG_ROOT=str(root / mode), FC_NATIVE_GATE_CONTROL=mode), contextlib.redirect_stdout(io.StringIO()):
                    if mode == "pass": gate.run(args)
                    else:
                        with self.assertRaises(ValueError): gate.run(args)
                    records = list((root / mode).glob("native-editor-*/metadata.json"))
                    self.assertEqual(len(records), 1)
                    metadata = json.loads(records[0].read_text())
                    self.assertEqual(metadata["status"], "passed" if mode == "pass" else "failed")
                    if mode == "pass":
                        self.assertEqual(metadata["tests"], 2)
                        self.assertTrue(records[0].with_name("results.xml").is_file())

    def test_timeout_terminates_the_owned_process_and_cannot_report_success(self):
        with tempfile.TemporaryDirectory(prefix="fc-native-timeout-") as directory:
            root = Path(directory); pidfile = root / "pid"
            script = "import os,time;from pathlib import Path;Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid()));time.sleep(60)"
            with self.assertRaises(subprocess.TimeoutExpired):
                gate.execute([sys.executable, "-c", script], root / "command.log", dict(os.environ), 1, {"commands": []})
            self.assertTrue(pidfile.is_file())
            with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()), 0)

    def test_timeout_tracks_a_descendant_that_leaves_the_parents_process_group(self):
        with tempfile.TemporaryDirectory(prefix="fc-native-child-") as directory:
            root = Path(directory); pidfile = root / "child-pid"
            child = "import os,time;from pathlib import Path;os.setsid();Path(" + repr(str(pidfile)) + ").write_text(str(os.getpid()));time.sleep(60)"
            parent = "import subprocess,sys;p=subprocess.Popen([sys.executable,'-c'," + repr(child) + "]);p.wait()"
            with self.assertRaises(subprocess.TimeoutExpired):
                gate.execute([sys.executable, "-c", parent], root / "command.log", dict(os.environ), 1, {"commands": []})
            self.assertTrue(pidfile.is_file())
            pid = int(pidfile.read_text())
            # A killed orphan may briefly remain a zombie awaiting system reap.
            state = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True, check=False).stdout.strip()
            self.assertTrue(not state or state.startswith("Z"), state)


if __name__ == "__main__":
    unittest.main()
