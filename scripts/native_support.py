#!/usr/bin/env python3
"""Shared source/archive/platform checks for native Julia validation.

A passing report describes only the operating system and runtime actually used.
It is evidence of execution, not a signature or an attestation against a hostile
machine. See docs/native-platform-validation.md for the review procedure.
"""
from __future__ import annotations

import argparse
import ctypes
import errno
import datetime as dt
import gzip
import hashlib
import json
import math
import os
from pathlib import Path, PurePosixPath
import platform
import re
import runpy
import stat
import zipfile
import glob
import shutil
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zlib

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = "SOURCE-SHA256.json"
FIXTURES = {
    "public-reference.jsonl.gz": (5610, "f1649de0f2e62c87fa7b369cdd1f99bd7c092b6a1a2fa52e2e0caf5aea136f82"),
    "internal-reference.jsonl.gz": (4576, "140eec7223af96822572f87cf67a80b612619bde250db552c1cad83b603ae67e"),
}
IGNORED_DIRS = {".git", "build", "validation-output", "__pycache__"}
HEX = re.compile(r"[0-9a-f]{64}\Z")


class ValidationError(RuntimeError):
    """An incomplete or failed validation, never a passing report."""


def require(condition, message):
    if not condition:
        raise ValidationError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def file_sha(path):
    return sha(Path(path).read_bytes())


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def strict_json(data):
    def finite_float(token):
        value = float(token)
        require(math.isfinite(value), "Non-finite JSON number: " + token)
        return value
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, "Duplicate JSON key: " + key)
            result[key] = value
        return result
    try:
        return json.loads(data, object_pairs_hook=pairs, parse_float=finite_float, parse_constant=lambda x: (_ for _ in ()).throw(ValidationError("Non-finite JSON value: " + x)))
    except (ValueError, UnicodeError) as error:
        raise ValidationError("Invalid JSON: " + str(error)) from error


def canonical_arch(value):
    return {"amd64": "x86_64", "x64": "x86_64", "aarch64": "arm64", "i486": "i386", "i586": "i386", "i686": "i386", "x86": "i386"}.get(value.lower(), value.lower())


def macos_translation_state():
    # Apple's documented in-process Rosetta test. Querying a spawned universal
    # sysctl command could inspect a different architecture than this process.
    library = ctypes.CDLL(None, use_errno=True)
    value = ctypes.c_int(0)
    size = ctypes.c_size_t(ctypes.sizeof(value))
    function = library.sysctlbyname
    function.argtypes = [ctypes.c_char_p, ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
    function.restype = ctypes.c_int
    result = function(b"sysctl.proc_translated", ctypes.byref(value), ctypes.byref(size), None, 0)
    if result == -1:
        require(ctypes.get_errno() == errno.ENOENT, "Unable to establish macOS translation state")
        return 0
    require(value.value in (0, 1), "Unexpected macOS translation state")
    return value.value


def windows_native_architecture():
    # GetNativeSystemInfo deliberately exposes emulated processor details under
    # Windows ARM translation. Only IsWow64Process2's nativeMachine is suitable.
    try:
        library = ctypes.WinDLL("kernel32", use_last_error=True)
        current = library.GetCurrentProcess
        current.argtypes = []
        current.restype = ctypes.c_void_p
        function = library.IsWow64Process2
        function.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ushort), ctypes.POINTER(ctypes.c_ushort)]
        function.restype = ctypes.c_int
        process_machine, native_machine = ctypes.c_ushort(0), ctypes.c_ushort(0)
        result = function(current(), ctypes.byref(process_machine), ctypes.byref(native_machine))
    except (AttributeError, OSError) as error:
        raise ValidationError("IsWow64Process2 is unavailable; native Windows architecture cannot be established") from error
    require(result != 0, "IsWow64Process2 failed; native Windows architecture cannot be established")
    architecture = {0x014c: "i386", 0x01c4: "arm", 0x8664: "x86_64", 0xaa64: "arm64"}.get(native_machine.value)
    require(architecture is not None, "Unsupported Windows nativeMachine from IsWow64Process2")
    return architecture


def check_platform(expected, expected_arch=None, allow_32bit_compatibility=False):
    actual = platform.system().lower()
    require(actual in ("linux", "windows", "darwin"), "Unsupported actual OS: " + actual)
    require(actual == expected, "Actual OS %s does not match requested OS %s" % (actual, expected))
    architecture = windows_native_architecture() if actual == "windows" else canonical_arch(platform.machine())
    if actual == "darwin":
        require(macos_translation_state() == 0, "Rosetta translation cannot establish a native platform pass")
    if expected_arch:
        compatible = allow_32bit_compatibility and actual in ("linux", "windows") and architecture == "x86_64" and canonical_arch(expected_arch) == "i386"
        require(architecture == canonical_arch(expected_arch) or compatible, "Actual architecture %s does not match requested architecture %s" % (architecture, expected_arch))
    return {"system": actual, "release": platform.release(), "version": platform.version(), "machine": platform.machine(), "architecture": architecture, "python": sys.version, "pythonExecutable": sys.executable, "pythonPointerBits": struct.calcsize("P") * 8}


def inventory(root):
    result = {}
    for path in sorted(Path(root).rglob("*")):
        rel = path.relative_to(root)
        if any(part in IGNORED_DIRS or part.startswith(".build") for part in rel.parts) or path.suffix == ".pyc" or rel.as_posix() == MANIFEST:
            continue
        require(not path.is_symlink(), "Source symlinks are not accepted: " + str(rel))
        if path.is_file():
            result[rel.as_posix()] = file_sha(path)
    return result


def verify_source(root):
    path = Path(root) / MANIFEST
    require(path.is_file() and not path.is_symlink(), "Missing or symlinked " + MANIFEST)
    data = strict_json(path.read_bytes())
    require(isinstance(data, dict) and type(data.get("schemaVersion")) is int and data.get("schemaVersion") == 1 and isinstance(data.get("files"), dict) and bool(data["files"]), "Invalid source manifest schema")
    for name, digest in data["files"].items():
        require(isinstance(name, str) and "\\" not in name and ":" not in name and not PurePosixPath(name).is_absolute() and all(p not in ("", ".", "..") for p in name.split("/")), "Unsafe manifest path: " + repr(name))
        require(isinstance(digest, str) and HEX.fullmatch(digest), "Malformed digest for " + name)
    actual = inventory(root)
    require(actual == data["files"], "Source inventory or SHA-256 mismatch (missing, additional, or modified file)")
    return {"manifestSha256": file_sha(path), "files": actual, "fileCount": len(actual)}


def verify_fixtures(root):
    base = Path(root) / "verification" / "fixtures"
    manifest = strict_json((base / "manifest.json").read_bytes())
    require(type(manifest.get("schemaVersion")) is int and manifest.get("schemaVersion") == 1 and set(manifest.get("files", {})) == set(FIXTURES), "Unexpected fixture manifest")
    result = {}
    for name, (count, digest) in FIXTURES.items():
        entry = manifest["files"][name]
        require(entry == {"sha256": digest, "records": count}, "Fixture manifest differs from pinned corpus: " + name)
        raw = (base / name).read_bytes()
        require(sha(raw) == digest, "Fixture SHA-256 mismatch: " + name)
        try:
            lines = gzip.decompress(raw).decode("utf-8").splitlines()
        except (OSError, EOFError, UnicodeError) as error:
            raise ValidationError("Unreadable fixture: " + name) from error
        require(len(lines) == count, "Fixture record count mismatch: " + name)
        for line in lines:
            record = strict_json(line)
            require(isinstance(record, dict) and isinstance(record.get("request"), dict) and isinstance(record.get("expected"), dict), "Malformed fixture record: " + name)
        result[name] = {"sha256": digest, "records": count}
    return result


def resolve_command(name):
    path = shutil.which(name)
    require(path is not None, "Required command not found: " + name)
    path = Path(path).resolve()
    require(path.is_file(), "Command is not a file: " + str(path))
    return str(path)


def binding(path):
    path = Path(path).resolve()
    require(path.is_file(), "Missing bound artifact: " + str(path))
    return {"path": str(path), "sha256": file_sha(path), "bytes": path.stat().st_size}


def as_bytes(value):
    if value is None:
        return b""
    return value.encode("utf-8") if isinstance(value, str) else value


class Recorder:
    def __init__(self, directory, source_sha, env, timeout):
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.source_sha = source_sha
        self.env = env
        self.timeout = timeout
        self.receipts = []

    def run(self, name, argv, cwd, stdin=b"", expected=0, empty_stderr=True, env=None):
        argv = [str(x) for x in argv]
        # Keep cmd.exe metacharacters out of batch launcher arguments.
        # A native Julia lane separately requires a direct native image.
        if os.name == "nt" and Path(argv[0]).suffix.lower() in (".bat", ".cmd"):
            require(not any(re.search(r'[&|<>^%!\r\n"]', a) for a in argv), "Windows batch-launcher path/argument contains unsupported shell metacharacters")
        execution_env = self.env if env is None else env
        index = len(self.receipts) + 1
        prefix = self.directory / ("%03d-%s" % (index, name))
        prefix.with_suffix(".stdin").write_bytes(stdin)
        receipt = {"name": name, "argv": argv, "cwd": str(Path(cwd).resolve()), "startedUtc": now(), "sourceManifestSha256": self.source_sha, "executable": binding(argv[0]), "expectedExitCode": expected, "stdin": binding(prefix.with_suffix(".stdin")), "environment": {key: execution_env.get(key) for key in ("JULIA_DEPOT_PATH", "JULIA_LOAD_PATH", "JULIA_PKG_OFFLINE", "JULIA_PKG_SERVER", "JULIA_PKG_PRECOMPILE_AUTO", "JULIA_NUM_THREADS")}}
        started = time.monotonic()
        try:
            proc = subprocess.run(argv, cwd=cwd, env=execution_env, input=stdin, capture_output=True, timeout=self.timeout, shell=False)
            out, err = proc.stdout, proc.stderr
            receipt["exitCode"] = proc.returncode
        except (OSError, subprocess.TimeoutExpired) as error:
            out, err = as_bytes(getattr(error, "stdout", None)), as_bytes(getattr(error, "stderr", None))
            receipt["error"] = str(error)
            receipt["exitCode"] = None
            proc = None
        prefix.with_suffix(".stdout").write_bytes(out)
        prefix.with_suffix(".stderr").write_bytes(err)
        receipt.update(elapsedSeconds=round(time.monotonic() - started, 4), stdout=binding(prefix.with_suffix(".stdout")), stderr=binding(prefix.with_suffix(".stderr")))
        self.receipts.append(receipt)
        write_json(prefix.with_suffix(".json"), receipt)
        require(proc is not None, "Command failed to execute: " + name)
        require(proc.returncode == expected, "%s exited %s, expected %s; see %s" % (name, proc.returncode, expected, prefix.with_suffix(".stderr")))
        if empty_stderr:
            require(not err, "Unexpected stderr: " + name)
        return out


def binary_identity(path):
    """Read the native image header without launching a wrapper or using file(1)."""
    data = Path(path).read_bytes()
    if data.startswith(b"\x7fELF") and len(data) >= 20:
        require(data[4] in (1, 2) and data[5] in (1, 2), "Malformed ELF header")
        machine = int.from_bytes(data[18:20], "little" if data[5] == 1 else "big")
        arch = {3: "i386", 62: "x86_64", 183: "arm64", 40: "arm"}.get(machine)
        result = {"format": "ELF", "system": "linux", "architecture": arch, "bits": 32 if data[4] == 1 else 64}
    elif data.startswith(b"MZ") and len(data) >= 64:
        off = int.from_bytes(data[60:64], "little")
        require(off + 26 <= len(data) and data[off:off + 4] == b"PE\0\0", "Malformed PE header")
        machine = int.from_bytes(data[off + 4:off + 6], "little")
        magic = int.from_bytes(data[off + 24:off + 26], "little")
        require(magic in (0x10b, 0x20b), "Malformed PE optional header")
        result = {"format": "PE", "system": "windows", "architecture": {0x14c: "i386", 0x8664: "x86_64", 0xaa64: "arm64"}.get(machine), "bits": 64 if magic == 0x20b else 32}
    elif data[:4] in (b"\xce\xfa\xed\xfe", b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf") and len(data) >= 8:
        endian = "little" if data[:1] in (b"\xce", b"\xcf") else "big"
        cpu = int.from_bytes(data[4:8], endian)
        result = {"format": "Mach-O", "system": "darwin", "architecture": {7: "i386", 0x1000007: "x86_64", 12: "arm", 0x100000c: "arm64"}.get(cpu), "bits": 64 if cpu & 0x1000000 else 32}
    else:
        raise ValidationError("Expected a direct ELF, PE, or thin Mach-O Julia executable; shell wrappers and universal binaries are not accepted: " + str(path))
    require(result["architecture"] is not None, "Unrecognized native executable architecture")
    return result


def require_native_image(path, system, arch):
    identity = binary_identity(path)
    require(identity["system"] == system and identity["architecture"] == canonical_arch(arch), "Native executable OS or architecture differs from requested lane: " + str(path))
    expected_bits = 32 if identity["architecture"] in ("i386", "arm") else 64
    require(identity["bits"] == expected_bits, "Native executable pointer width/architecture mismatch")
    return identity


def safe_relative(name):
    require(isinstance(name, str) and "\\" not in name and ":" not in name and not name.startswith("/") and all(p not in ("", ".", "..") for p in name.split("/")), "Unsafe archive path: " + repr(name))


def verify_archive(path, expected_hash, source):
    require(isinstance(expected_hash, str) and HEX.fullmatch(expected_hash), "Archive proof needs the exact expected SHA-256")
    require(file_sha(path) == expected_hash, "Source archive SHA-256 mismatch")
    with zipfile.ZipFile(path) as archive:
        members = archive.infolist()
        names = [m.filename for m in members]
        require(len(names) == len(set(names)), "Duplicate ZIP member")
        for member in members:
            safe_relative(member.filename.rstrip("/"))
            require(not stat.S_ISLNK(member.external_attr >> 16), "Archive contains a symlink")
            require(member.file_size <= 128 * 1024 * 1024, "Archive member exceeds safety bound")
        roots = [m.filename[:-len(MANIFEST)] for m in members if m.filename == MANIFEST or m.filename.endswith("/" + MANIFEST)]
        require(len(roots) == 1, "Archive must contain exactly one source manifest")
        prefix = roots[0]
        actual = {m.filename[len(prefix):]: sha(archive.read(m)) for m in members if not m.is_dir() and m.filename.startswith(prefix)}
        expected = dict(source["files"], **{MANIFEST: source["manifestSha256"]})
        require(actual == expected, "Archive source subtree does not match the exact validated source")
    return {**binding(path), "sourcePrefix": prefix, "sourceFileCount": len(expected), "exactSourceMatch": True, "expectedSha256": expected_hash}



def verify_gzip_transcript(artifact, expected_hash, expected_bytes, maximum=512 * 1024 * 1024):
    require(isinstance(artifact, dict) and isinstance(artifact.get("path"), str), "Missing compressed transcript artifact")
    require(artifact == binding(artifact["path"]), "Compressed transcript binding mismatch")
    require(isinstance(expected_hash, str) and HEX.fullmatch(expected_hash), "Invalid transcript stream hash")
    require(type(expected_bytes) is int and 0 < expected_bytes <= maximum, "Invalid transcript byte count")
    digest, size = hashlib.sha256(), 0
    try:
        with gzip.open(artifact["path"], "rb") as stream:
            while chunk := stream.read(1024 * 1024):
                size += len(chunk)
                require(size <= expected_bytes, "Transcript exceeds recorded byte count")
                digest.update(chunk)
    except (OSError, EOFError) as error:
        raise ValidationError("Invalid compressed transcript") from error
    require(size == expected_bytes and digest.hexdigest() == expected_hash, "Transcript bytes/hash differ from process receipt")
    return {**artifact, "uncompressedBytes": size, "uncompressedSha256": digest.hexdigest()}
