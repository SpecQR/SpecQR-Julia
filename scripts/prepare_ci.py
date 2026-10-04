#!/usr/bin/env python3
"""Test-only manifest generation, checked CI staging and evidence collection."""
import argparse
import json
import shutil
from pathlib import Path
import zipfile

from native_support import ROOT, MANIFEST, file_sha, inventory, require, verify_archive, verify_source


def manifest():
    # Explicit maintainer command only. CI never refreshes the committed manifest.
    return {"schemaVersion": 1, "files": inventory(ROOT)}


def stage(output):
    output = output.resolve()
    require(output != ROOT and ROOT not in output.parents, "Keep CI output outside the source tree")
    source = verify_source(ROOT)
    output.mkdir(parents=True, exist_ok=False)
    target = output / "stage" / "SpecQR-Julia"
    target.mkdir(parents=True)
    names = sorted([*source["files"], MANIFEST])
    for name in names:
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT / name, destination)
    require(verify_source(target) == source, "Staged source differs from checkout")
    archive = output / "SpecQR-Julia-source.zip"
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as stream:
        for name in names:
            info = zipfile.ZipInfo("SpecQR-Julia/" + name, date_time=(1980, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            stream.writestr(info, (target / name).read_bytes(), compresslevel=9)
    require(verify_source(ROOT) == source, "Checkout changed while staging")
    result = {"source": source, "stagedRoot": str(target),
              "archive": verify_archive(archive, file_sha(archive), source)}
    (output / "stage-report.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def collect(native, output):
    # Keep failure receipts too. Exclude reproducible caches, but retain the exact
    # empty registry referenced by the offline-consumer receipt.
    native, output = native.resolve(), output.resolve()
    require(output != native and native not in output.parents, "Evidence destination must be outside native output")
    output.mkdir(parents=True, exist_ok=True)
    count = 0
    for path in sorted(native.rglob("*")):
        require(not path.is_symlink(), "Symlink in native evidence: " + str(path))
        if not path.is_file():
            continue
        relative = path.relative_to(native)
        registry = path.name == "Registry.toml" and path.parent.name == "SpecQROfflineEmpty"
        if not registry and any("depot" in part or part == "__pycache__" for part in relative.parts):
            continue
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, destination)
        count += 1
    return {"copiedFiles": count, "missingNativeOutput": not native.is_dir()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("manifest", help="Print a fresh manifest for an explicitly reviewed source update")
    staging = sub.add_parser("stage", help="Check the committed manifest, copy its exact source, and archive it")
    staging.add_argument("--output", type=Path, required=True)
    collecting = sub.add_parser("collect", help="Retain native evidence while omitting Julia caches")
    collecting.add_argument("--native", type=Path, required=True)
    collecting.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = manifest() if args.action == "manifest" else stage(args.output) if args.action == "stage" else collect(args.native, args.output)
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
