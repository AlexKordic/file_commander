"""Pass/fail decisions must remain enabled under Python -O."""
import re


class TestFailure(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise TestFailure(message)


def validate_result(name, rc, killed, output, debug='', expected_error=None):
    require(not killed, f'{name}: timeout')
    require(rc >= 0, f'{name}: terminated by signal {-rc}')
    if expected_error is not None:
        require(rc > 0, f'{name}: negative control unexpectedly passed')
        require(expected_error in debug, f'{name}: failed for an unrelated reason')
    else:
        require(rc == 0, f'{name}: unexpected exit {rc}')
        require(re.search(rb'\[PASS\] [^\r\n\x1b]+', output), f'{name}: completion marker missing')
