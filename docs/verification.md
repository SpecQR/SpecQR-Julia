# Verification

The package includes deterministic native Julia tests and a pinned compressed
language-neutral corpus. Verification invokes the actual Julia executable.
No transpiler, compatibility interpreter, QR wrapper, or remote QR service is
used to produce candidate results.

## Exact corpus

- 5,610 public operations: 3,028 generation, 1,920 planning, 640 capacity, and
  22 Structured Append cases
- 4,576 internal operations: 4,320 raw matrix/codeword/mask cases, all 255
  Reed–Solomon degrees, and the complete 65,536-entry GF multiplication table
- 2,400 corpus matrices have independent Nayuki reference agreement
- Includes every version 1–40, ECC L/M/Q/H, and mask 0–7

`verification/fixtures/manifest.json` pins the compressed files by SHA-256.
Both compressed corpus files are included, so core verification is offline.

```sh
julia --startup-file=no --project=. test/runtests.jl
python3 scripts/verify_reference.py --julia /absolute/path/to/julia --output reference.json
```

The verifier checks required fields, row dimensions, matrix hashes, exact
counts, clean process termination, stream hashes, and source stability. A
changed source tree invalidates the source-bound run even if comparisons pass.

## Independent decoding and rendering

Optional development scripts invoke independently installed ZXing-C++ 3.1.1
and ZXing Java 3.5.4. Every generated PNG is checked with independent CRC,
DEFLATE, dimensions, and full pixel reconstruction before actual image
recognition. GS1/FNC1, ECI, Kanji, binary bytes, all modes, masks/ECC combinations,
and high-level Structured Append are covered. Java also checks SA metadata,
codeword bytes, and matrix decoding separately from actual-PNG detection.

SVG is rasterized by independent librsvg, then every pixel is compared with the
pure-Julia PNG output; both images are decoded. PNG/SVG data URLs round-trip.
Decoder/rasterizer/Python libraries are optional verification tools and are
never included in `Project.toml` runtime dependencies.

Known scanner limitations must be reported as failures for that specific
configuration. A successful alternate pixel scale is not evidence that the
original scale passed. Passing a corpus is not formal standards certification.

## Review and native proof

The deliverable records actual versions, commands, source/archive hashes,
comparison counts, SDK checksums, and test results. Final source is archived
with deterministic ordering and timestamps. A separate native harness checks
that archive against the entire source inventory, native executable headers,
actual OS/architecture, Julia's own runtime identity, unit tests, full corpus,
CLI control-byte/Unicode I/O, and a clean offline local package consumer.
See [native validation](native-platform-validation.md).
