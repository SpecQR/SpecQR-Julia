# Native platform validation

## Claims and release gates

A passing `scripts/verify_native.py` report applies only to the real operating
system, architecture, Julia version, exact source archive, and bounds-checking
profile recorded in that report. The delivery's required lanes are native Linux
x86-64 with the official Julia **1.13.1 stable** and **1.10.12 LTS** runtimes.
Successful Linux runs do not establish Windows or macOS execution. Windows and
macOS lanes remain **unverified unless corresponding actual-native reports are
present**; their absence does not automatically block the two approved Linux
release gates. No emulator, mocked runtime, generated platform label, or shell
wrapper can establish a native platform pass.

The report is reproducible execution evidence, not a digital signature or an
attestation against a hostile machine. Review the toolchain download metadata
and official archive checksums alongside the executable hash. The harness does
not independently establish the publisher identity of an arbitrary executable.

## Requirements and invocation

Use Python 3.9+ and a direct official Julia native executable. The validation
harness uses only Python's standard library. Its target package uses Julia Base
and the bundled Base64 standard library; Test and SHA are test-only extras.

Extract the release source archive, verify its independently supplied SHA-256,
and run from its `SpecQR-Julia` directory. Keep output outside the source tree;
the inventory deliberately rejects source changes or additional source files.
The archive and extracted tree must contain the same `SOURCE-SHA256.json` and
all the same manifested bytes.

```sh
python3 scripts/test_verify_native.py
python3 scripts/verify_native.py \
  --julia /absolute/path/to/julia-1.13.1/bin/julia \
  --expect-version 1.13.1 --expect-platform linux --expect-arch x86_64 \
  --check-bounds yes \
  --source-archive /absolute/path/to/SpecQR-Julia-source.zip \
  --archive-sha256 EXACT_ARCHIVE_SHA256 \
  --output /absolute/path/to/evidence/linux-x86_64-1.13.1
```

Repeat with Julia 1.10.12 and a new output directory for the LTS gate. For an
actual Windows or macOS runner, use `windows` or `darwin`, the matching native
architecture, and its direct Julia executable. Python's argument handling
supports spaces and Unicode paths. Do not reuse an existing output directory.
A failed or interrupted lane must not be relabeled as passing; diagnose it and
run a fresh complete lane against the same source, or create a new frozen source
archive if repairs change the source.

## What a complete lane checks

1. **Actual host and runtime identity.** Python reads the current OS and host
   architecture. Windows calls `IsWow64Process2` and uses its `nativeMachine`
   result, preventing an emulated x64 Python process on Windows ARM from
   claiming an x64 host. macOS calls the in-process `sysctl.proc_translated`
   API and refuses Rosetta execution. Direct ELF, PE, or thin Mach-O image
   headers must match the requested OS, architecture, and pointer width.
   Shell launchers and universal binaries are rejected. Julia separately reports
   its actual version, kernel, architecture, pointer width, and thread count.
   WSL is a Linux lane, not a Windows lane. These checks are not a universal
   detector for every possible virtualized or translated Linux environment;
   the runner operator must use an actual matching native runtime.
2. **Immutable source binding.** Every non-generated source file is SHA-256
   checked before and after execution. The pinned compressed fixture corpus is
   checked independently. Archive bytes must match the supplied hash, and the
   archive's source subtree must exactly match the extracted manifest, including
   the manifest itself. Unsafe archive paths, symlinks, and duplicate entries
   are refused. `.git`, build/output directories, and Python bytecode caches are
   excluded from the source inventory, not used as source evidence.
3. **Real multithreaded unit suite.** The harness runs `test/runtests.jl` with
   four Julia threads and requires exactly one nonempty completion marker, at
   least 90,000 passed checks, zero failed/error/broken checks, and the expected
   Julia version. Completion counting supports both the Julia 1.10 tuple API
   and the Julia 1.13 `TestCounts` API. A log without this marker is incomplete.
4. **All source-bound reference cases.** The real Julia bridge executes all
   **10,186** requests: 3,028 generation, 1,920 estimate, 640 capacity, 22
   Structured Append, 4,320 raw-core, 255 Reed–Solomon, and one exhaustive
   finite-field request. The generation corpus includes **2,400 independent
   Nayuki matrix comparisons**. Missing, extra, malformed, wrong-typed, or
   mismatched responses, nonempty stderr, timeout, and nonzero exit all fail.
   JSON booleans cannot masquerade as integers; duplicate keys and nonfinite
   numbers are rejected. The lane's bounds profile also applies to the bridge.
5. **CLI execution.** Every CLI check launches the real executable. The report
   counts actual completed invocations, rather than an estimated hard-coded
   number. Coverage includes Unicode input/output paths; NUL, CR, LF, GS, and
   UTF-8 preservation through files and raw stdin; all 256 byte values through
   binary stdin and hexadecimal input; SVG/PNG structure; overwrite refusal and
   explicit replacement; planning; manual ECI; Structured Append full split and
   symbol diagnostics; invalid options; invalid UTF-8; and missing-file errors.
6. **Isolated local Pkg consumer and separate Pkg-free runtime consumer.** See
   the offline details below. Both must finish with their exact success marker.

## Offline consumer details

A fresh Julia Pkg depot can try to install the default General registry even
with `JULIA_PKG_OFFLINE=true`, before resolving a local path. The harness therefore
creates an **explicitly empty local registry** with no registered packages or
remote sources in a new isolated consumer depot. This is a documented bootstrap
step, not an untouched-depot claim. `Registry.toml` is retained with its exact
byte count and SHA-256 in the report. The isolated environment sets
`JULIA_PKG_SERVER=''`, `JULIA_PKG_OFFLINE=true`, and the script calls
`Pkg.offline(true)` before `Pkg.develop(path=exact_source)`.

The consumer verifies its direct dependency is SpecQR and that the complete
resolved dependency names are exactly `SpecQR` and `Base64`. It encodes Unicode
and renders SVG and PNG. Its Project.toml and Manifest.toml are retained and
hashed. Pkg is Julia's own test-time tooling; any standard-library/JLL modules
used internally by Pkg do not become runtime package dependencies of SpecQR.
The consumer does not download or resolve an external runtime package.

A second process starts with a different absent depot and `JULIA_LOAD_PATH`
restricted to `@stdlib`. It includes the exact `src/SpecQR.jl` directly, makes no
Pkg calls, encodes the same Unicode payload, and renders SVG/PNG. It verifies no
new externally loaded module other than Base64 appears. Julia's own initially
loaded sysimage modules are treated as baseline, not attributed to SpecQR. This
separate test establishes package-manager-free source use.

Environment flags are not an operating-system network sandbox. For an air-gap
claim, the operator must additionally disable network access on the runner.
The reproducible test establishes that no registry or external package is
needed; it does not claim to have inspected every network syscall.

## Receipts, replay, and review

`report.json` has `status: "passed"` only after all stages and the post-run
source check succeed. It names the exact source archive/hash, source manifest,
fixture hashes, actual host, Julia native image/hash, runtime response, unit
counts, full-reference counts, CLI count, and consumer artifacts. A failure
preserves its error and any receipts already written.

Each process receipt retains the exact argument vector, working directory,
relevant Julia environment, source-manifest hash, direct executable hash,
expected/actual exit status, duration, and raw stdin/stdout/stderr bindings.
The reference bridge additionally retains its **complete lossless stdin and
stdout JSONL streams as gzip companions** and raw stderr. Compressed-artifact
hashes are bound in the report; the verifier streams decompression and checks
that the original bytes/hash equal those measured during execution. These
transcripts can be replayed into the same source-bound real bridge. They are
not mock responses and are not replaced by progress-only logs.

Retain reports, receipt JSON files, raw streams, compressed reference streams,
consumer scripts/project/manifest/empty registry, the frozen source archive,
and official toolchain metadata. Reproducible `depot/compiled` caches are not
release evidence and may be removed after validation; do not remove the empty
registry or consumer manifest referenced by the report. Diagnostic attempts
against mutable source are labeled provisional and cannot substitute for a
complete source-bound final lane.

## Harness self-tests are separate

`python3 scripts/test_verify_native.py` exercises malformed source/archive
bindings, corrupted fixtures and transcripts, wrong runtime/test markers,
wrong JSON types, native-header refusal, Windows native-machine handling,
Rosetta refusal, nonzero process exits, stderr errors, and timeouts. Synthetic
image headers and mocked platform APIs exist **only in these self-tests**.
Passing self-tests makes no operating-system or Julia execution claim and
cannot satisfy either native release gate.
