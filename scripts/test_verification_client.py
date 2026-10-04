#!/usr/bin/env python3
"""Stdlib subprocess failure controls; these are not native Julia evidence."""
import collections
import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

import verification_support as client


class ProcessHarnessTests(unittest.TestCase):
    def tearDown(self):
        client.finish_clients(raise_errors=False, timeout=0.5)

    def command(self, ending=''):
        return self.script('import sys\nfor line in sys.stdin:\n'
                           ' print(\'{"value":1}\', flush=True)\n' + ending)

    def script(self, code):
        return [sys.executable, '-u', '-c', code]

    def rejected_shutdown(self, ending):
        client.execute(self.command(ending), [{}])
        report = {}
        with self.assertRaises(RuntimeError):
            client.finish_clients(report, timeout=2)
        row = report['nativeProcesses'][0]
        self.assertEqual(row['status'], 'failed')
        self.assertTrue(row['readersFinished'])
        self.assertEqual(client.finish_clients(report), [])
        self.assertEqual(len(report['nativeProcesses']), 1)
        return row

    def test_julia_command_preserves_native_project(self):
        with patch.dict(client.os.environ, {}, clear=True):
            command = client.julia_command(sys.executable)
        self.assertEqual(command, [str(Path(sys.executable).resolve()), '--startup-file=no',
                                  '--history-file=no', '--project=' + str(client.PKG),
                                  str(client.PKG / 'scripts/bridge.jl')])

    def test_optional_gc_hint_is_forwarded_as_one_native_argument(self):
        for hint in ('500M', '1G'):
            with self.subTest(hint=hint), patch.dict(client.os.environ, {'SPECQR_JULIA_HEAP_SIZE_HINT': hint}):
                command = client.julia_command(sys.executable)
                self.assertEqual(command[0], str(Path(sys.executable).resolve()))
                self.assertEqual(command[1], '--heap-size-hint=' + hint)
                self.assertEqual(command[-1], str(client.PKG / 'scripts/bridge.jl'))

    def test_invalid_gc_hints_are_rejected(self):
        for hint in ('', '0M', '-1G', '0.5G', '1T', '9999999G', '500M --bad', 'NaN'):
            with self.subTest(hint=hint), patch.dict(client.os.environ, {'SPECQR_JULIA_HEAP_SIZE_HINT': hint}):
                with self.assertRaisesRegex(RuntimeError, 'positive integer M/G'):
                    client.julia_command(sys.executable)

    def test_clean_reuse_has_complete_closure_receipt(self):
        command = self.command()
        self.assertEqual(client.execute(command, [{}, {}]), [{'value': 1}] * 2)
        first = client._CLIENTS[tuple(command)]
        self.assertEqual(client.execute(command, [{}]), [{'value': 1}])
        self.assertIs(client._CLIENTS[tuple(command)], first)
        report = {}
        rows = client.finish_clients(report, timeout=2)
        self.assertEqual(rows, report['nativeProcesses'])
        row = rows[0]
        self.assertEqual(row['status'], 'passed')
        self.assertEqual(row['exitCode'], 0)
        self.assertEqual((row['requests'], row['responses']), (3, 3))
        output = b'{"value":1}\n' * 3
        self.assertEqual(row['stdoutSha256'], hashlib.sha256(output).hexdigest())
        self.assertEqual(row['stdoutBytes'], len(output))
        self.assertEqual(row['stderrBytes'], 0)
        self.assertEqual(row['stderrSha256'], hashlib.sha256(b'').hexdigest())
        self.assertEqual(row['trailingStdoutBytes'], 0)
        self.assertTrue(row['stdoutEof'])
        self.assertTrue(row['readersFinished'])
        self.assertFalse(row['queryTimeout'])
        self.assertFalse(row['shutdownTimeout'])
        self.assertEqual(row['errors'], [])
        self.assertIsNotNone(first.proc.poll())
        self.assertTrue(first.proc.stdin.closed)
        self.assertTrue(first.proc.stdout.closed)
        self.assertTrue(first.proc.stderr.closed)
        client.execute(command, [{}])
        self.assertIsNot(client._CLIENTS[tuple(command)], first)
        self.assertEqual(client.finish_clients(timeout=2)[0]['status'], 'passed')

    def test_nonzero_final_exit_rejected(self):
        self.assertEqual(self.rejected_shutdown('sys.exit(7)')['exitCode'], 7)

    def test_late_stdout_rejected(self):
        row = self.rejected_shutdown('print(\'{"extra":true}\', flush=True)')
        data = b'{"extra":true}\n'
        self.assertEqual(row['trailingStdoutBytes'], len(data))
        self.assertEqual(row['trailingStdoutLines'], 1)
        self.assertEqual(row['trailingStdoutSha256'], hashlib.sha256(data).hexdigest())

    def test_late_unterminated_stdout_rejected(self):
        row = self.rejected_shutdown('sys.stdout.write("unexpected"); sys.stdout.flush()')
        self.assertEqual(row['trailingStdoutBytes'], len(b'unexpected'))
        self.assertEqual(row['trailingStdoutSha256'], hashlib.sha256(b'unexpected').hexdigest())

    def test_late_stderr_rejected(self):
        row = self.rejected_shutdown('print("late error", file=sys.stderr, flush=True)')
        data = b'late error\n'
        self.assertEqual(row['stderrBytes'], len(data))
        self.assertEqual(row['stderrSha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(row['stderrPreview'], data.decode())

    def test_original_exit_and_extra_output_false_pass_rejected(self):
        row = self.rejected_shutdown('print(\'{"extra":true}\', flush=True)\nsys.exit(7)')
        self.assertEqual(row['exitCode'], 7)
        self.assertEqual(row['trailingStdoutLines'], 1)

    def test_stdout_larger_than_queue_is_fully_drained(self):
        row = self.rejected_shutdown('sys.stdout.write("{}\\n" * 10000); sys.stdout.flush()')
        data = b'{}\n' * 10000
        self.assertEqual(row['trailingStdoutBytes'], len(data))
        self.assertEqual(row['trailingStdoutLines'], 10000)
        self.assertEqual(row['trailingStdoutSha256'], hashlib.sha256(data).hexdigest())

    def test_large_stderr_is_hashed_with_bounded_preview(self):
        row = self.rejected_shutdown('sys.stderr.write("x" * 150000); sys.stderr.flush()')
        self.assertEqual(row['stderrBytes'], 150000)
        self.assertEqual(row['stderrSha256'], hashlib.sha256(b'x' * 150000).hexdigest())
        self.assertEqual(len(row['stderrPreview']), client._STDERR_PREVIEW_BYTES)

    def test_missing_response_survives_exit_zero_in_failure_receipt(self):
        command = self.script('import sys; sys.stdin.readline()')
        with self.assertRaisesRegex(RuntimeError, 'stopped before its response'):
            client.execute(command, [{}], timeout=2)
        report = {}
        with self.assertRaises(RuntimeError):
            client.finish_clients(report, timeout=0.5)
        row = report['nativeProcesses'][0]
        self.assertEqual(row['status'], 'failed')
        self.assertEqual(row['exitCode'], 0)
        self.assertEqual(row['responses'], 0)
        self.assertFalse(row['shutdownTimeout'])
        self.assertTrue(row['stdoutEof'])
        self.assertTrue(any('stopped before its response' in error for error in row['errors']))

    def test_extra_response_is_not_hidden_by_reuse(self):
        command = self.script('import sys\nfor line in sys.stdin:\n'
                              ' print(\'{"value":1}\\n{"extra":true}\', flush=True)')
        client.execute(command, [{}])
        client.execute(command, [{}])
        report = {}
        with self.assertRaises(RuntimeError):
            client.finish_clients(report, timeout=2)
        self.assertEqual(report['nativeProcesses'][0]['responses'], 2)
        self.assertEqual(report['nativeProcesses'][0]['trailingStdoutLines'], 2)

    def test_malformed_response_failure_is_retained(self):
        values = ['{', '{"value":1,"value":2}', '{"nested":{"v":1,"v":2}}',
                  '{"value":NaN}', '{"value":Infinity}', '{"value":-Infinity}',
                  '{"value":1e10000}', '{} {}', '', 'null', '[]', '1', '"text"']
        for value in values:
            with self.subTest(value=value):
                command = self.script('import sys; sys.stdin.readline(); print(' + repr(value) + ', flush=True)')
                with self.assertRaises(RuntimeError):
                    client.execute(command, [{}], timeout=2)
                rows = client.finish_clients(raise_errors=False, timeout=2)
                self.assertEqual(rows[0]['status'], 'failed')
                self.assertEqual(rows[0]['responses'], 0)
                self.assertTrue(rows[0]['errors'])

    def test_invalid_utf8_response_rejected(self):
        command = self.script('import sys; sys.stdin.readline(); sys.stdout.buffer.write(b"\\xff\\n")')
        with self.assertRaises(RuntimeError):
            client.execute(command, [{}], timeout=2)
        self.assertEqual(client.finish_clients(raise_errors=False, timeout=2)[0]['status'], 'failed')

    def test_valid_json_without_line_terminator_rejected(self):
        command = self.script('import sys; sys.stdin.readline(); sys.stdout.write("{}")')
        with self.assertRaisesRegex(RuntimeError, 'terminator'):
            client.execute(command, [{}], timeout=2)
        self.assertEqual(client.finish_clients(raise_errors=False, timeout=2)[0]['status'], 'failed')

    def test_malformed_matrix_rejected_before_response_counted(self):
        command = self.script('import sys; sys.stdin.readline(); print(\'{"matrix":["00"]}\')')
        with self.assertRaisesRegex(RuntimeError, 'matrix dimensions'):
            client.execute(command, [{}], timeout=2)
        self.assertEqual(client.finish_clients(raise_errors=False, timeout=2)[0]['responses'], 0)

    def test_oversized_response_rejected(self):
        command = self.script('import sys; sys.stdin.readline(); print("x" * 1000, flush=True)')
        with patch.object(client, '_MAX_RESPONSE_BYTES', 64):
            with self.assertRaisesRegex(RuntimeError, 'bounded line budget'):
                client.execute(command, [{}], timeout=2)
            row = client.finish_clients(raise_errors=False, timeout=2)[0]
        self.assertEqual(row['status'], 'failed')
        self.assertFalse(row['shutdownTimeout'])
        self.assertFalse(row['stdoutEof'])

    def test_shutdown_timeout_reaps_child(self):
        command = self.command('import time; time.sleep(60)')
        client.execute(command, [{}])
        process = client._CLIENTS[tuple(command)].proc
        report = {}
        with self.assertRaises(RuntimeError):
            client.finish_clients(report, timeout=0.1)
        self.assertTrue(report['nativeProcesses'][0]['shutdownTimeout'])
        self.assertIsNotNone(process.poll())
        self.assertTrue(report['nativeProcesses'][0]['readersFinished'])

    def test_query_timeout_reaps_child(self):
        command = self.script('import time; time.sleep(60)')
        with self.assertRaises((RuntimeError, TimeoutError)):
            client.execute(command, [{}], timeout=0.1)
        process = client._CLIENTS[tuple(command)].proc
        row = client.finish_clients(raise_errors=False, timeout=2)[0]
        self.assertEqual(row['status'], 'failed')
        self.assertTrue(row['queryTimeout'])
        self.assertIsNotNone(process.poll())
        self.assertTrue(row['readersFinished'])

    def test_query_timeout_interrupts_blocked_stdin_write(self):
        command = self.script('import time; time.sleep(60)')
        with self.assertRaises((RuntimeError, TimeoutError, BrokenPipeError)):
            client.execute(command, [{'text': 'x' * 262144}], timeout=0.1)
        row = client.finish_clients(raise_errors=False, timeout=2)[0]
        self.assertEqual(row['status'], 'failed')
        self.assertTrue(row['queryTimeout'])
        self.assertTrue(row['readersFinished'])

    def test_shutdown_timeout_applies_after_stdout_eof(self):
        command = self.command('import os, time; os.close(sys.stdout.fileno()); time.sleep(60)')
        client.execute(command, [{}])
        row = client.finish_clients(raise_errors=False, timeout=0.1)[0]
        self.assertEqual(row['status'], 'failed')
        self.assertTrue(row['shutdownTimeout'])
        self.assertTrue(row['stdoutEof'])
        self.assertTrue(row['readersFinished'])

    def test_continuous_trailing_stdout_cannot_defeat_timeout(self):
        command = self.command('while True:\n sys.stdout.write("{}\\n" * 100); sys.stdout.flush()')
        client.execute(command, [{}])
        row = client.finish_clients(raise_errors=False, timeout=0.1)[0]
        self.assertEqual(row['status'], 'failed')
        self.assertTrue(row['shutdownTimeout'])
        self.assertGreater(row['trailingStdoutBytes'], 0)
        self.assertTrue(row['readersFinished'])

    def test_failed_process_cannot_be_reused(self):
        command = self.script('import sys; sys.stdin.readline(); print("null", flush=True)')
        with self.assertRaises(RuntimeError):
            client.execute(command, [{}])
        with self.assertRaisesRegex(RuntimeError, 'reuse a failed'):
            client.execute(command, [{}])

    def test_environment_change_does_not_silently_reuse_client(self):
        command = self.command()
        environment = dict(os.environ)
        client.execute(command, [{}], env=environment)
        environment['SPECQR_SELFTEST_ENVIRONMENT'] = 'changed'
        with self.assertRaisesRegex(RuntimeError, 'different environment'):
            client.execute(command, [{}], env=environment)

    def test_all_children_finalized_after_one_fails(self):
        commands = [self.command('sys.exit(7)'), self.command(), self.command('sys.exit(9)')]
        for command in commands:
            client.execute(command, [{}])
        children = list(client._CLIENTS.values())
        report = {}
        with self.assertRaises(RuntimeError):
            client.finish_clients(report, timeout=2)
        self.assertEqual([row['exitCode'] for row in report['nativeProcesses']], [7, 0, 9])
        self.assertTrue(all(child.proc.poll() is not None for child in children))
        self.assertEqual(client.finish_clients(report), [])
        self.assertEqual(len(report['nativeProcesses']), 3)

    def test_finally_cleanup_preserves_original_exception(self):
        report = {}
        with self.assertRaisesRegex(ValueError, 'original failure'):
            try:
                client.execute(self.command('sys.exit(7)'), [{}])
                raise ValueError('original failure')
            finally:
                client.finish_clients(report, timeout=2, raise_errors=False)
        self.assertEqual(report['nativeProcesses'][0]['exitCode'], 7)

    def test_best_effort_atexit_cleanup_never_raises(self):
        with patch.object(client, 'finish_clients', side_effect=RuntimeError('cleanup failed')):
            client.close_clients()

    def test_timeout_values_rejected_before_start(self):
        for value in (0, -1, float('inf'), float('nan')):
            with self.subTest(timeout=value):
                with self.assertRaises(RuntimeError):
                    client.execute(self.command(), [{}], timeout=value)
                with self.assertRaises(RuntimeError):
                    client.finish_clients(timeout=value)
        self.assertFalse(client._CLIENTS)


class Fnc1OutcomeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = client.PKG / 'verification/fixtures/expected-contract-vectors.json'
        if client.digest(path) != 'd08eb74343ac0fd17b2840c5c34e651569b3e90deaf924296faf228514486dff':
            raise AssertionError('Pinned FNC1 fixture digest changed')
        cls.vectors = json.loads(path.read_text())['vectors']

    def test_exact_fixture_outcome_counts(self):
        outcomes = collections.Counter(map(client.expected_fnc1_outcome, self.vectors))
        self.assertEqual(outcomes, {'success': 44, 'INVALID_MODE': 34, 'DATA_TOO_LONG': 24})

    def test_all_expected_outcomes_accept_the_matching_response(self):
        for vector in self.vectors:
            with self.subTest(vector=vector['id']):
                expected = client.expected_fnc1_outcome(vector)
                response = {} if expected == 'success' else {'error': 'SpecQRError', 'code': expected}
                self.assertEqual(client.check_fnc1_outcome(vector, response), expected)

    def test_every_fitting_vector_rejects_false_capacity_failure(self):
        for vector in self.vectors:
            if client.expected_fnc1_outcome(vector) == 'success':
                with self.subTest(vector=vector['id']), self.assertRaises(RuntimeError):
                    client.check_fnc1_outcome(vector, {'error': 'DataTooLongError', 'code': 'DATA_TOO_LONG'})

    def test_every_rejection_vector_rejects_false_success(self):
        for vector in self.vectors:
            if client.expected_fnc1_outcome(vector) != 'success':
                with self.subTest(vector=vector['id']), self.assertRaises(RuntimeError):
                    client.check_fnc1_outcome(vector, {})

    def test_rejection_requires_error_and_exact_code(self):
        for vector in self.vectors:
            expected = client.expected_fnc1_outcome(vector)
            if expected != 'success':
                for response in ({'code': expected}, {'error': 'failure'},
                                 {'error': 'failure', 'code': 'INTERNAL_ERROR'}):
                    with self.subTest(vector=vector['id'], response=response), self.assertRaises(RuntimeError):
                        client.check_fnc1_outcome(vector, response)

    def vector(self, text='%', version=1, capacity=24, second=False):
        options = {'mode': 'byte', 'version': version}
        options.update({'fnc1Second': '37'} if second else {'fnc1': True})
        return {'id': 'synthetic-boundary', 'input': text, 'expectedPayloadUtf8Hex': text.encode().hex(),
                'options': options, 'capacityBits': capacity}

    def test_control_and_utf8_bit_boundaries(self):
        for second, text, bits in [(False, '%', 24), (True, '%', 32), (False, '%é', 40)]:
            with self.subTest(second=second, text=text):
                self.assertEqual(client.expected_fnc1_outcome(self.vector(text, capacity=bits, second=second)), 'success')
                self.assertEqual(client.expected_fnc1_outcome(self.vector(text, capacity=bits - 1, second=second)), 'DATA_TOO_LONG')

    def test_version_9_to_10_count_width(self):
        for version, count_bits in [(9, 8), (10, 16), (26, 16), (27, 16)]:
            bits = 4 + 4 + count_bits + 8
            self.assertEqual(client.expected_fnc1_outcome(self.vector(version=version, capacity=bits)), 'success')
            self.assertEqual(client.expected_fnc1_outcome(self.vector(version=version, capacity=bits - 1)), 'DATA_TOO_LONG')
        self.assertEqual(client.expected_fnc1_outcome(self.vector('%' * 256, version=9, capacity=99999)), 'DATA_TOO_LONG')
        self.assertEqual(client.expected_fnc1_outcome(self.vector('%' * 256, version=10, capacity=99999)), 'success')

    def test_outcome_does_not_use_other_ports_success_fields(self):
        for vector in self.vectors:
            changed = copy.deepcopy(vector)
            changed.update(expectedFits=False, expectedGenerateError='INTERNAL_ERROR', expectedDataBitLength=999999)
            self.assertEqual(client.expected_fnc1_outcome(changed), client.expected_fnc1_outcome(vector))

    def test_payload_disagreement_rejected(self):
        vector = self.vector()
        vector['expectedPayloadUtf8Hex'] = '00'
        with self.assertRaisesRegex(RuntimeError, 'text/bytes disagree'):
            client.expected_fnc1_outcome(vector)


class SourceSnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="specqr-snapshot-control-")
        self.root = Path(self.temporary.name)
        (self.root / "SOURCE-SHA256.json").write_text("{}\n")
        self.scope = patch.object(client, "PKG", self.root)
        self.scope.start()

    def tearDown(self):
        self.scope.stop()
        self.temporary.cleanup()

    def test_fixture_document_and_manifest_changes_are_detected(self):
        for name in ("fixture.json", "README.md", "SOURCE-SHA256.json"):
            with self.subTest(name=name):
                path = self.root / name
                path.write_text("before")
                before = client.snapshot()
                self.assertIn(name, before)
                path.write_text("after")
                self.assertNotEqual(client.snapshot(), before)

    def test_added_and_removed_source_files_are_detected(self):
        before = client.snapshot()
        path = self.root / "extra.json"
        path.write_text("{}")
        after = client.snapshot()
        self.assertNotEqual(after, before)
        path.unlink()
        self.assertNotEqual(client.snapshot(), after)
        self.assertEqual(client.snapshot(), before)

    def test_expected_cache_files_do_not_change_source_snapshot(self):
        before = client.snapshot()
        cache = self.root / "__pycache__"
        cache.mkdir()
        (cache / "transient.pyc").write_bytes(b"cache")
        self.assertEqual(client.snapshot(), before)


if __name__ == '__main__':
    unittest.main(verbosity=2)
