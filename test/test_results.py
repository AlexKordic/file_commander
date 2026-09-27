"""Pass/fail decisions must remain enabled under Python -O."""
import re
import json


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


def validate_protocol(suite, specification, data):
    require(len(data) <= 512 * 1024, f'{suite}: result protocol exceeds size limit')
    try:
        records = [json.loads(line) for line in data.splitlines()]
    except (ValueError, UnicodeError) as error:
        raise TestFailure(f'{suite}: malformed result protocol: {error}') from error
    expected = [('case', case) for case in specification['cases']]
    expected.append(('complete', specification['completion']))
    require(len(records) == len(expected), f'{suite}: incomplete or duplicate case/completion records')
    for record, (kind, case) in zip(records, expected):
        require(record == {'kind': kind, 'suite': suite, 'id': case, 'status': 'passed'},
                f'{suite}: unexpected case/completion record: {record!r}; expected {kind} {case}')
