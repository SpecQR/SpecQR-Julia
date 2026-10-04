"""Development-only persistent native-Julia client with checked process shutdown."""
import atexit
import hashlib
import json
import os
import re
import pathlib
import queue
import subprocess
import threading
import time

from native_support import strict_json, inventory, MANIFEST
from verify_reference import ROOT as PKG, enrich, require

_CLIENTS = {}
_MAX_RESPONSE_BYTES = 96 * 1024 * 1024
_STDERR_PREVIEW_BYTES = 4096


def digest(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def snapshot():
    """Bind every source/fixture/document file plus the committed manifest."""
    return dict(inventory(PKG), **{MANIFEST: digest(PKG / MANIFEST)})


def julia_command(executable):
    """Use the direct native executable, optionally with an official GC hint.

    SPECQR_JULIA_HEAP_SIZE_HINT=500M (or an integer G value) is a development-only
    pressure control. Julia's hint triggers earlier GC; it is not a hard limit.
    The actual argument is retained in every process receipt. The QR library and
    the default verification command are unchanged when this variable is absent.
    """
    command = [str(pathlib.Path(executable).resolve()), '--startup-file=no',
               '--history-file=no', '--project=' + str(PKG), str(PKG / 'scripts/bridge.jl')]
    hint = os.environ.get('SPECQR_JULIA_HEAP_SIZE_HINT')
    if hint is not None:
        require(re.fullmatch(r'[1-9][0-9]{0,5}[MG]', hint) is not None,
                'SPECQR_JULIA_HEAP_SIZE_HINT needs a positive integer M/G value')
        command.insert(1, '--heap-size-hint=' + hint)
    return command


class _Client:
    def __init__(self, command, env):
        self.command = list(command)
        self.env = None if env is None else dict(env)
        self.proc = subprocess.Popen(command, cwd=PKG, env=env, stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = queue.Queue(maxsize=2)
        self.stop_reader = threading.Event()
        self.stdout_eof = threading.Event()
        self.stdout_hash = hashlib.sha256()
        self.stderr_hash = hashlib.sha256()
        self.stdout_bytes = self.stderr_bytes = 0
        self.stderr_preview = bytearray()
        self.reader_errors = []
        self.query_errors = []
        self.query_timeout = False
        self.requests = self.responses = 0
        self.stdout_reader = threading.Thread(target=self._read_stdout, daemon=True)
        self.stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self.stdout_reader.start()
        self.stderr_reader.start()

    def _read_stdout(self):
        try:
            while True:
                line = self.proc.stdout.readline(_MAX_RESPONSE_BYTES + 1)
                if not line:
                    self.stdout_eof.set()
                    break
                self.stdout_hash.update(line)
                self.stdout_bytes += len(line)
                if len(line) > _MAX_RESPONSE_BYTES:
                    self.reader_errors.append('Response exceeds the bounded line budget')
                    self.kill()
                    break
                while not self.stop_reader.is_set():
                    try:
                        self.lines.put(line, timeout=0.1)
                        break
                    except queue.Full:
                        pass
        except BaseException as error:
            self.reader_errors.append('stdout reader: ' + repr(error))

    def _read_stderr(self):
        try:
            while True:
                data = self.proc.stderr.read(65536)
                if not data:
                    break
                self.stderr_hash.update(data)
                self.stderr_bytes += len(data)
                room = _STDERR_PREVIEW_BYTES - len(self.stderr_preview)
                if room > 0:
                    self.stderr_preview.extend(data[:room])
        except BaseException as error:
            self.reader_errors.append('stderr reader: ' + repr(error))

    def next_line(self, deadline):
        # EOF is persistent: a missing response must not consume an EOF marker
        # that finalization then waits for a second time.
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('Native process did not provide stdout before the deadline')
            try:
                return self.lines.get_nowait()
            except queue.Empty:
                if not self.stdout_reader.is_alive():
                    # The reader can enqueue its final line between the empty
                    # check and its exit, so inspect the queue once more.
                    try:
                        return self.lines.get_nowait()
                    except queue.Empty:
                        return None
            try:
                return self.lines.get(timeout=min(0.1, remaining))
            except queue.Empty:
                pass

    def kill(self):
        if self.proc.poll() is None:
            self.proc.kill()


def execute(command, requests, env=None, timeout=900):
    """Consume one strict JSON object per request; callers must finish_clients()."""
    require(0 < timeout < float('inf'), 'Query timeout must be positive and finite')
    key = tuple(command)
    if key not in _CLIENTS:
        _CLIENTS[key] = _Client(command, env)
    client = _CLIENTS[key]
    require(client.env == env, 'Cannot reuse a native process with a different environment')
    require(not client.query_errors, 'Cannot reuse a failed native process')
    results = []
    for request in requests:
        deadline = time.monotonic() + timeout

        def expire():
            client.query_timeout = True
            client.kill()

        timer = threading.Timer(timeout, expire)
        timer.start()
        try:
            client.proc.stdin.write((json.dumps(request, ensure_ascii=True, allow_nan=False) + '\n').encode())
            client.proc.stdin.flush()
            client.requests += 1
            line = client.next_line(deadline)
            require(not client.query_timeout, 'Native request timed out')
            require(not client.reader_errors, '; '.join(client.reader_errors))
            require(line is not None, 'Native process stopped before its response')
            require(line.endswith(b'\n'), 'Native response lacks its JSON-line terminator')
            response = strict_json(line)
            require(isinstance(response, dict), 'Native response must be a JSON object')
            results.append(enrich(response))
            client.responses += 1
        except BaseException as error:
            if isinstance(error, TimeoutError):
                client.query_timeout = True
            client.query_errors.append(repr(error))
            client.kill()
            raise
        finally:
            timer.cancel()
            timer.join()
    return results


def expected_fnc1_outcome(vector):
    """Independent byte-fallback arithmetic using the pinned fixture's capacity.

    The shared fixture's escaped-alphanumeric expectedFits fields describe a
    different implementation contract. Julia promises whole-payload byte fallback
    for literal percent, or INVALID_MODE for forced alphanumeric. The byte count
    excludes the second-position application indicator, which occupies 8 control
    bits in addition to its 4-bit mode indicator.
    """
    options = vector['options']
    require('%' in vector['input'], 'Expected a literal-percent contract vector')
    mode = options['mode']
    require(mode in ('auto', 'byte', 'alphanumeric'), 'Unexpected FNC1 vector mode')
    if mode == 'alphanumeric':
        return 'INVALID_MODE'
    payload = bytes.fromhex(vector['expectedPayloadUtf8Hex'])
    require(payload == vector['input'].encode('utf-8'), 'Fixture payload text/bytes disagree')
    version = options['version']
    require(type(version) is int and 1 <= version <= 40, 'Unexpected fixture version')
    count_bits = 8 if version <= 9 else 16
    control_bits = 12 if 'fnc1Second' in options else 4
    require('fnc1Second' in options or options.get('gs1') is True or options.get('fnc1') is True,
            'Expected an FNC1 control option')
    bits = control_bits + 4 + count_bits + len(payload) * 8
    capacity = vector['capacityBits']
    require(type(capacity) is int and capacity > 0, 'Invalid pinned fixture capacity')
    return 'DATA_TOO_LONG' if bits > capacity or len(payload) >= 2**count_bits else 'success'


def check_fnc1_outcome(vector, response):
    expected = expected_fnc1_outcome(vector)
    require(isinstance(response, dict), 'FNC1 response must be a JSON object')
    if expected == 'success':
        require('error' not in response, 'Expected FNC1 encoding success: ' + vector['id'])
    else:
        require('error' in response and response.get('code') == expected,
                'Unexpected FNC1 outcome: ' + vector['id'] + '; expected ' + expected)
    return expected


def finish_clients(report=None, timeout=20, raise_errors=True):
    """Require stdout EOF, zero exit and empty stderr for every registered child.

    Finalize every child and attach closure evidence before raising. Calling again
    in a finally block is safe; raise_errors=False preserves an earlier exception.
    """
    require(0 < timeout < float('inf'), 'Shutdown timeout must be positive and finite')
    clients = list(_CLIENTS.values())
    _CLIENTS.clear()
    outcomes = []
    for client in clients:
        errors = []
        trailing_hash = hashlib.sha256()
        trailing_bytes = trailing_lines = 0
        shutdown_timeout = False

        def drain(deadline):
            nonlocal trailing_bytes, trailing_lines
            while True:
                line = client.next_line(deadline)
                if line is None:
                    return
                trailing_hash.update(line)
                trailing_bytes += len(line)
                trailing_lines += 1

        deadline = time.monotonic() + timeout
        try:
            try:
                client.proc.stdin.close()
            except (BrokenPipeError, OSError):
                pass
            drain(deadline)
            client.proc.wait(timeout=max(0.001, deadline - time.monotonic()))
        except (TimeoutError, subprocess.TimeoutExpired) as error:
            shutdown_timeout = True
            errors.append(str(error))
            client.kill()
        except BaseException as error:
            errors.append(repr(error))
            client.kill()
        finally:
            try:
                client.proc.wait(timeout=5)
                # Killing on a timeout can leave output in the pipe or bounded
                # queue. Drain it before joining, so the reader cannot deadlock.
                drain(time.monotonic() + 5)
            except BaseException as error:
                errors.append('Unable to finish native process: ' + repr(error))
            client.stop_reader.set()
            client.stdout_reader.join(timeout=5)
            client.stderr_reader.join(timeout=5)
            readers_finished = not (client.stdout_reader.is_alive() or client.stderr_reader.is_alive())
            if not readers_finished:
                errors.append('Native stream reader did not finish')
            else:
                client.proc.stdout.close()
                client.proc.stderr.close()
        errors.extend(client.query_errors)
        errors.extend(client.reader_errors)
        if not client.stdout_eof.is_set():
            errors.append('Native stdout EOF was not observed')
        if client.proc.returncode != 0:
            errors.append('Native process exit code: ' + str(client.proc.returncode))
        if trailing_bytes:
            errors.append('Unexpected trailing stdout')
        if client.stderr_bytes:
            errors.append('Unexpected stderr')
        if client.query_timeout:
            errors.append('Native request timed out')
        outcome = {
            'argv': client.command, 'status': 'failed' if errors else 'passed',
            'exitCode': client.proc.returncode, 'requests': client.requests, 'responses': client.responses,
            'stdoutSha256': client.stdout_hash.hexdigest(), 'stdoutBytes': client.stdout_bytes,
            'stderrSha256': client.stderr_hash.hexdigest(), 'stderrBytes': client.stderr_bytes,
            'stderrPreview': client.stderr_preview.decode(errors='replace'),
            'trailingStdoutSha256': trailing_hash.hexdigest(),
            'trailingStdoutBytes': trailing_bytes, 'trailingStdoutLines': trailing_lines,
            'stdoutEof': client.stdout_eof.is_set(), 'readersFinished': readers_finished,
            'queryTimeout': client.query_timeout, 'shutdownTimeout': shutdown_timeout,
            'errors': errors,
        }
        outcomes.append(outcome)
    if report is not None and outcomes:
        report.setdefault('nativeProcesses', []).extend(outcomes)
    if raise_errors:
        require(all(row['status'] == 'passed' for row in outcomes),
                'Native process finalization failed: ' + repr(outcomes))
    return outcomes


def close_clients():
    """Best-effort atexit cleanup only; success requires explicit finish_clients()."""
    try:
        finish_clients(raise_errors=False)
    except BaseException:
        pass


atexit.register(close_clients)
