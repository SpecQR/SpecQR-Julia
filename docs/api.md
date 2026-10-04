# Public API

See [native API contracts](native-api.md) for options, strict text and binary
input, exact optimizer behavior, capacity planning, result ownership,
diagnostics, and Structured Append. See [GS1](gs1.md) and [rendering](rendering.md)
for those families. All examples run with `using SpecQR` after local development
installation, or `using .SpecQR` after including `src/SpecQR.jl`.

Errors derive from `SpecQRError`; use `error_code(error)` for a stable machine
code. Invalid ECC inputs raise `InvalidEccError` (`INVALID_ECC_LEVEL`). Digital
Link/GS1 errors expose the top-level `INVALID_GS1` code and a structured
`detail_code`. Julia runtime/programming errors are not mislabeled as valid QR
results.

JSON is a small built-in strict codec for CLI/test I/O, not a generic JSON
package promise. It accepts finite JSON floats and native-range integers,
rejects duplicate keys and malformed Unicode, and bounds depth/input/value
counts. Public Julia input APIs reject Bool where an integer is required.

Source and CLI examples intentionally use private/non-sensitive example data.
