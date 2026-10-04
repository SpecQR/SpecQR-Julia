# SpecQR Julia

A from-scratch QR Model 2 encoder implemented in Julia. Runtime dependencies are
Julia Base and the bundled Base64 standard library only. No external packages,
JLL artifacts, FFI, QR wrappers, runtime downloads, or network services.

## Use locally

```julia
using Pkg
Pkg.develop(path="/absolute/path/to/SpecQR-Julia")
using SpecQR

qr = generate("Hello, 世界 🌍"; error_correction_level="Q")
write("hello.svg", to_svg(qr))
write("hello.png", to_png(qr))
println(qr.version, " / ", qr.mask_pattern)
```

For a source-only, package-manager-free workflow:

```julia
include("src/SpecQR.jl")
using .SpecQR
qr = generate("HELLO 123")
```

## Features

- Versions 1–40; ECC L/M/Q/H; all eight masks and deterministic auto-mask scoring
- Numeric, alphanumeric, UTF-8 byte, binary byte, and Kanji modes
- Optimal mixed-mode segmentation with version-band and count-field limits
- ECI, FNC1 first/second position, explicit control segments
- GS1 element strings, check digits, AI metadata, and strict-profile Digital Link
- Structured Append splitting, parity, detailed planning, and validated merging
- Pure-Julia SVG, RGBA pixels, PNG, and data URLs
- Capacity, planning, diagnostics, ECC boosting, and CLI

## Examples

```julia
plan("HELLO 123"; version=1)                 # No matrix or ECC work
get_capacity(1, "L"; mode="numeric").maximum # 41

generate(UInt8[0x00, 0xff, 0x1d]; mode="byte")
generate_segments([Segment("eci"; assignment_number=26),
                   Segment("byte", "日本語")])

gs1 = create_gs1_element_string([(ai="01", value="09506000134352"),
                                 (ai="10", value="BATCH%ONE")])
generate(gs1; gs1=true)

set = generate_structured_append(repeat("SPECQR ", 20); version=1)
for (i, symbol) in enumerate(set.symbols)
    write("part-$i.png", to_png(symbol))
end
```

Text is strict UTF-8. Malformed Julia strings and surrogate encodings are
rejected. Binary input preserves all byte values. ECI labels bytes; it does not
transcode text. Text byte segments always contain UTF-8. No Unicode normalization
is performed. Public matrix indexing is Julia-native: `matrix[y,x]` and
`module_at(qr,x,y)` use 1-based indices. Masks remain the QR-standard values 0–7;
Structured Append public part indices are 1–16.

## CLI

```sh
julia --startup-file=no bin/specqr.jl --text 'Hello 世界' --output hello.svg
julia --startup-file=no bin/specqr.jl --stdin --binary --format png --output bytes.png
julia --startup-file=no bin/specqr.jl --text '123456789' --plan
julia --startup-file=no bin/specqr.jl --help
```

File/stdin text retains every input byte, including NUL, CR/LF, and final newline.
Text must be valid UTF-8. Outputs are not overwritten unless `--force` is given;
symbolic-link output paths are rejected. Multiple input sources, duplicate
options, unknown options, and invalid numeric settings fail explicitly.

## Validation and support

The source is portable Julia and does not artificially restrict operating
systems. The release candidate is verified on native Linux x86_64 with official
Julia 1.10.12 LTS and 1.13.1 stable. Windows, macOS, non-x86_64, and 32-bit lanes
are not verified and are not claimed as tested. In particular, native Windows
and macOS CLI Unicode filenames, raw stdio, exclusive file creation, and local
package-consumer workflows need execution on those systems before those lanes
can be called supported.

See [verification](docs/verification.md),
[native validation](docs/native-platform-validation.md), and [API](docs/api.md).
Run local tests with `julia --project=. test/runtests.jl`; the bundled `Test` and
`SHA` standard libraries are test-only dependencies. The Python verification
scripts and optional independent decoders are development tools, not runtime
requirements. There is no claim of formal ISO/GS1 certification or universal
scanner compatibility.

## Deliberate bounds

Input caps protect planning and encoding as well as rendering: 1,000,000 input
units, 16,384 manual segments, and 7,089 scalars for single-symbol optimization.
Normal QR capacity is much smaller. PNG/RGBA images are limited to 4,194,304
pixels; SVG output and data URLs also have deterministic budgets. Digital Link
uses an explicit ASCII-authority profile, not a browser URL parser. See the
specific API documents for exact constraints and interoperability caveats.

MIT license. This directory is source, tests, and documentation; publication
status is tracked separately from platform validation.
