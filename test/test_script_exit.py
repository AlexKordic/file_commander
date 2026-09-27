"""R30: errors, watchdogs and explicit waits have reliable process outcomes."""
from pathlib import Path
import sys
import tempfile
from lua_runner import run_script

repo = Path(__file__).resolve().parent.parent
binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else repo / "build/fc"
cases = [
    ("syntax", "this is not Lua", False, 0, 3),
    ("runtime", "error('deliberate regression failure')", False, 0, 3),
    ("returned", "print('[PASS] returned')", True, 0, 3),
    ("yield_watchdog", "coroutine.yield()", False, 5.5, 9),
    ("loop_watchdog", "while true do end", False, 5.5, 9),
    ("long_sleep", "fc.sleep(7000); print('[PASS] long_sleep')", True, 6.9, 10),
    ("long_wait", "assert(not fc.wait_event('never_emitted', 7000)); print('[PASS] long_wait')", True, 6.9, 10),
]
with tempfile.TemporaryDirectory(prefix="fc-exit-test-") as temp:
    root = Path(temp)
    for name, text, success, minimum, timeout in cases:
        script = root / (name + ".lua")
        script.write_text(text)
        rc, seconds, killed, output = run_script(binary, script, repo, root / "config", timeout)
        assert not killed, f"{name}: process hung past {timeout}s"
        assert (rc == 0) == success and rc >= 0, f"{name}: unexpected exit {rc}"
        assert seconds >= minimum, f"{name}: returned early at {seconds:.2f}s"
        if success:
            assert b"[PASS]" in output, f"{name}: completion marker missing"
        print(f"PASS {name}: exit={rc}, elapsed={seconds:.2f}s", flush=True)
