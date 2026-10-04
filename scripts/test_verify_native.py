#!/usr/bin/env python3
"""Python stdlib harness self-tests, never native Julia platform evidence.

Mocked platform facts and synthetic image headers are used only to test refusal
paths and parsing. A release lane must separately run verify_native.py with the
real, direct Julia executable and a frozen source archive.
"""
from __future__ import annotations
import gzip
import json
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

import native_support as support
import verify_native as native
import verify_reference as reference


class HarnessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="specqr-harness-selftest-")
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def manifest(self):
        (self.root / "src").mkdir(exist_ok=True)
        (self.root / "src" / "example.jl").write_text('println("example")\n')
        support.write_json(self.root / support.MANIFEST, {"schemaVersion": 1, "files": support.inventory(self.root)})
        return support.verify_source(self.root)

    def image(self, data):
        image = self.root / "synthetic-image"
        image.write_bytes(data)
        return image

    def elf(self, machine=62, bits=64):
        data = bytearray(64)
        data[:6] = b"\x7fELF" + bytes([2 if bits == 64 else 1, 1])
        data[18:20] = machine.to_bytes(2, "little")
        return self.image(data)

    def marker(self, **changes):
        data = dict(status="passed", checks=90001, julia="1.10.12", threads=4, failed=0, errored=0, broken=0)
        data.update(changes)
        return b"SPECQR_TESTS_JSON=" + json.dumps(data).encode() + b"\n"

    def test_strict_json_duplicate(self):
        with self.assertRaises(support.ValidationError): support.strict_json('{"x":1,"x":2}')

    def test_strict_json_nonfinite(self):
        for value in ("NaN", "Infinity", "-Infinity", "1e10000"):
            with self.subTest(value=value), self.assertRaises(support.ValidationError): support.strict_json(value)

    def test_reference_rejects_boolean_integer_confusion(self):
        for expected, actual in ((1, True), (0, False), (True, 1), (False, 0)):
            with self.subTest(expected=expected, actual=actual), self.assertRaises(RuntimeError): reference.compare(expected, actual)

    def test_reference_accepts_valid_numeric_equivalence(self):
        reference.compare({"x": [1, 2.0, True]}, {"x": [1.0, 2, True]})

    def test_reference_rejects_missing_fields_and_extra_matrix_dimensions(self):
        with self.assertRaises(RuntimeError): reference.compare({"x": 1}, {})
        with self.assertRaises(RuntimeError): reference.enrich({"matrix": ["00"]})

    def test_source_inventory_passes(self):
        self.assertEqual(self.manifest()["fileCount"], 1)

    def test_source_modified_file_fails(self):
        self.manifest(); (self.root / "src" / "example.jl").write_text("changed")
        with self.assertRaises(support.ValidationError): support.verify_source(self.root)

    def test_source_additional_file_fails(self):
        self.manifest(); (self.root / "extra.txt").write_text("extra")
        with self.assertRaises(support.ValidationError): support.verify_source(self.root)

    def test_source_missing_file_fails(self):
        self.manifest(); (self.root / "src" / "example.jl").unlink()
        with self.assertRaises(support.ValidationError): support.verify_source(self.root)

    def test_source_unsafe_manifest_path_fails(self):
        for path in ("../x", "/x", "C:/x", "a\\b", "a//b", "./x"):
            support.write_json(self.root / support.MANIFEST, {"schemaVersion": 1, "files": {path: "0" * 64}})
            with self.subTest(path=path), self.assertRaises(support.ValidationError): support.verify_source(self.root)

    def test_source_symlink_fails(self):
        self.manifest()
        try: (self.root / "alias").symlink_to(self.root / "src" / "example.jl")
        except (OSError, NotImplementedError): self.skipTest("Symlink creation unavailable")
        with self.assertRaises(support.ValidationError): support.verify_source(self.root)

    def test_shell_wrapper_rejected(self):
        with self.assertRaises(support.ValidationError): support.binary_identity(self.image(b"#!/bin/sh\nexec julia \"$@\"\n"))

    def test_elf_native_identity(self):
        self.assertEqual(support.require_native_image(self.elf(), "linux", "amd64")["bits"], 64)

    def test_elf_wrong_os_arch_and_width_rejected(self):
        for system, arch, bits in (("windows", "x86_64", 64), ("linux", "arm64", 64), ("linux", "x86_64", 32)):
            with self.subTest(system=system, arch=arch, bits=bits), self.assertRaises(support.ValidationError): support.require_native_image(self.elf(bits=bits), system, arch)

    def test_elf_unknown_machine_rejected(self):
        with self.assertRaises(support.ValidationError): support.binary_identity(self.elf(machine=0))

    def test_pe_native_identity(self):
        data = bytearray(128); data[:2] = b"MZ"; data[60:64] = (64).to_bytes(4, "little"); data[64:68] = b"PE\0\0"; data[68:70] = (0x8664).to_bytes(2, "little"); data[88:90] = (0x20b).to_bytes(2, "little")
        self.assertEqual(support.require_native_image(self.image(data), "windows", "x86_64")["format"], "PE")

    def test_malformed_pe_rejected(self):
        with self.assertRaises(support.ValidationError): support.binary_identity(self.image(b"MZ" + b"\0" * 70))

    def test_thin_macho_native_identity(self):
        self.assertEqual(support.require_native_image(self.image(b"\xcf\xfa\xed\xfe" + (0x100000c).to_bytes(4, "little") + b"\0" * 24), "darwin", "arm64")["bits"], 64)

    def test_universal_macho_rejected(self):
        with self.assertRaises(support.ValidationError): support.binary_identity(self.image(b"\xca\xfe\xba\xbe" + b"\0" * 60))

    def test_wrong_actual_os_rejected(self):
        with patch.object(support.platform, "system", return_value="Linux"), self.assertRaises(support.ValidationError): support.check_platform("windows", "x86_64")

    def test_windows_host_arch_overrules_platform_machine(self):
        with patch.object(support.platform, "system", return_value="Windows"), patch.object(support.platform, "machine", return_value="AMD64"), patch.object(support, "windows_native_architecture", return_value="arm64"):
            with self.assertRaises(support.ValidationError): support.check_platform("windows", "x86_64")

    def test_windows_uses_iswow64process2_native_machine(self):
        library = Mock()
        def api(handle, process, native):
            process._obj.value = 0x8664; native._obj.value = 0xaa64; return 1
        library.IsWow64Process2.side_effect = api
        with patch.object(support.ctypes, "WinDLL", return_value=library, create=True):
            self.assertEqual(support.windows_native_architecture(), "arm64")
            library.IsWow64Process2.assert_called_once()
            library.GetNativeSystemInfo.assert_not_called()

    def test_windows_api_failure_rejected(self):
        library = Mock(); library.IsWow64Process2.return_value = 0
        with patch.object(support.ctypes, "WinDLL", return_value=library, create=True), self.assertRaises(support.ValidationError): support.windows_native_architecture()

    def test_rosetta_rejected(self):
        with patch.object(support.platform, "system", return_value="Darwin"), patch.object(support.platform, "machine", return_value="x86_64"), patch.object(support, "macos_translation_state", return_value=1), self.assertRaises(support.ValidationError): support.check_platform("darwin", "x86_64")

    def test_runtime_identity(self):
        value = dict(julia="1.10.12", os="Linux", arch="x86_64", wordSize=64, threads=4)
        self.assertEqual(native.runtime_info(json.dumps(value), "1.10.12", "linux", "amd64"), value)
        for key, replacement in (("julia", "1.0.0"), ("os", "NT"), ("arch", "arm64"), ("wordSize", 32), ("threads", 1)):
            with self.subTest(key=key), self.assertRaises(support.ValidationError): native.runtime_info(json.dumps({**value, key: replacement}), "1.10.12", "linux", "x86_64")

    def test_unit_marker_passes(self):
        self.assertEqual(native.test_summary(self.marker(), "1.10.12")["checks"], 90001)

    def test_unit_marker_empty_duplicate_and_truncated_fail(self):
        for data in (b"", self.marker() * 2, b"SPECQR_TESTS_JSON={"):
            with self.subTest(data=data), self.assertRaises(support.ValidationError): native.test_summary(data, "1.10.12")

    def test_unit_marker_failed_incomplete_and_wrong_runtime_fail(self):
        for changes in (dict(checks=0), dict(checks=True), dict(failed=1), dict(errored=1), dict(broken=1), dict(julia="1.0.0"), dict(threads=1), dict(status="running")):
            with self.subTest(changes=changes), self.assertRaises(support.ValidationError): native.test_summary(self.marker(**changes), "1.10.12")

    def archive(self, source, additions=()):
        path = self.root.parent / (self.root.name + ".zip")
        self.addCleanup(lambda: path.unlink(missing_ok=True))
        with zipfile.ZipFile(path, "w") as archive:
            for name in [*source["files"], support.MANIFEST]: archive.write(self.root / name, "SpecQR-Julia/" + name)
            for name, content in additions: archive.writestr(name, content)
        return path

    def test_archive_exact_source(self):
        source = self.manifest(); archive = self.archive(source)
        self.assertTrue(support.verify_archive(archive, support.file_sha(archive), source)["exactSourceMatch"])

    def test_archive_wrong_digest_and_mismatch_fail(self):
        source = self.manifest(); archive = self.archive(source)
        with self.assertRaises(support.ValidationError): support.verify_archive(archive, "0" * 64, source)
        with self.assertRaises(support.ValidationError): support.verify_archive(archive, support.file_sha(archive), {**source, "manifestSha256": "0" * 64})

    def test_archive_unsafe_member_fails(self):
        source = self.manifest(); archive = self.archive(source, [("../evil", "bad")])
        with self.assertRaises(support.ValidationError): support.verify_archive(archive, support.file_sha(archive), source)

    def test_archive_additional_source_file_fails(self):
        source = self.manifest(); archive = self.archive(source, [("SpecQR-Julia/extra", "extra")])
        with self.assertRaises(support.ValidationError): support.verify_archive(archive, support.file_sha(archive), source)

    def test_fixture_corruption_rejected(self):
        fixtures = self.root / "verification" / "fixtures"; fixtures.mkdir(parents=True)
        support.write_json(fixtures / "manifest.json", {"schemaVersion": 1, "files": {name: dict(sha256=digest, records=count) for name, (count, digest) in support.FIXTURES.items()}})
        for name in support.FIXTURES: (fixtures / name).write_bytes(b"corrupt")
        with self.assertRaises(support.ValidationError): support.verify_fixtures(self.root)

    def test_compressed_transcript_passes(self):
        data = b'{"x":1}\n' * 10; path = self.root / "transcript.gz"; path.write_bytes(gzip.compress(data))
        self.assertEqual(support.verify_gzip_transcript(support.binding(path), support.sha(data), len(data))["uncompressedBytes"], len(data))

    def test_compressed_transcript_corruption_and_wrong_counts_fail(self):
        data = b"hello\n"; path = self.root / "transcript.gz"; path.write_bytes(gzip.compress(data)); artifact = support.binding(path)
        for digest, count in (("0" * 64, len(data)), (support.sha(data), len(data) - 1), (support.sha(data), len(data) + 1)):
            with self.subTest(digest=digest, count=count), self.assertRaises(support.ValidationError): support.verify_gzip_transcript(artifact, digest, count)
        path.write_bytes(b"bad")
        with self.assertRaises(support.ValidationError): support.verify_gzip_transcript(artifact, support.sha(data), len(data))

    def test_recorder_retains_failure(self):
        recorder = support.Recorder(self.root / "receipts", "0" * 64, os.environ.copy(), 10)
        with self.assertRaises(support.ValidationError): recorder.run("selftest-failure", [sys.executable, "-c", 'import sys; print("out"); print("err",file=sys.stderr); sys.exit(7)'], self.root)
        receipt = recorder.receipts[0]
        self.assertEqual(receipt["exitCode"], 7)
        self.assertEqual(Path(receipt["stdout"]["path"]).read_bytes(), b"out\n")
        self.assertEqual(Path(receipt["stderr"]["path"]).read_bytes(), b"err\n")

    def test_recorder_rejects_unexpected_stderr(self):
        recorder = support.Recorder(self.root / "receipts", "0" * 64, os.environ.copy(), 10)
        with self.assertRaises(support.ValidationError): recorder.run("selftest-stderr", [sys.executable, "-c", 'import sys; print("warning",file=sys.stderr)'], self.root)

    def test_recorder_retains_timeout(self):
        recorder = support.Recorder(self.root / "receipts", "0" * 64, os.environ.copy(), 0.05)
        with self.assertRaises(support.ValidationError): recorder.run("selftest-timeout", [sys.executable, "-c", 'import time; time.sleep(10)'], self.root)
        self.assertIsNone(recorder.receipts[0]["exitCode"])
        self.assertIn("error", recorder.receipts[0])


def load_tests(loader, tests, pattern):
    import test_verification_client
    tests.addTests(loader.loadTestsFromModule(test_verification_client))
    return tests


if __name__ == "__main__":
    unittest.main(verbosity=2)
