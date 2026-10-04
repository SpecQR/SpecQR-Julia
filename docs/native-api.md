# Native Julia API

SpecQR runs entirely in Julia; the only runtime dependency is the `Base64`
standard library. Arrays use ordinary Julia indexing. QR matrices are square
`Matrix{Bool}` objects indexed as `matrix[y, x]`, without the quiet zone.
`module_at(code, x, y)` uses **one-based** coordinates.

```julia
using SpecQR

options = Options(error_correction_level="M", min_version=1, max_version=40)
preview = plan("Hello, 世界", options)
preview.ok || error("Payload does not fit")
code = generate("Hello, 世界", options; mask_pattern=2)
write("hello.svg", to_svg(code))
write("hello.png", to_png(code; scale=6))
```

`estimate` and `plan` return a `Plan` without building codewords, Reed–Solomon
parity, masks, or a matrix. Its fields include `ok`, `version`,
`capacity_version`, `error_correction_level`, `data_bit_length`, `capacity_bits`,
`remaining_bits`, `segments`, and `diagnostics`. A failed automatic plan has
`version === nothing`; its capacity refers to `capacity_version` at the upper
end of the requested range. Fixed versions take precedence over range bounds.
`overflow_bits`, `capacity_utilization`, `warnings`, and `selected_version` are
convenience properties. `generate` raises `DataTooLongError` when no symbol fits.

`get_capacity(1, "L"; mode="byte").maximum == 17`. Capacity supports numeric,
alphanumeric, byte, and Kanji modes and a `control_bits` allowance.

## Input and ownership

Text is strictly validated Unicode and byte-mode text is always UTF-8. Native
byte vectors and tuples permit arbitrary bytes, including invalid UTF-8; every
value must be an integer in `0:255`, excluding `Bool`. Options also distinguish
booleans from integers. ECI labels subsequent bytes and never transcodes them:
use native bytes for a non-UTF-8 encoding.

`Segment` owns immutable payload storage; its binary `data` and `logical_bytes`
properties return copies. Every encoder result owns its matrix, codewords,
segment collection, and diagnostics. There are no mutable global caches.
Results may be changed independently; callers sharing a mutable result between
threads remain responsible for synchronizing their own mutations.

The resource limits are one million input scalars or binary bytes, one million
aggregate manual payload units, and 16,384 manual segments. Exact automatic
single-symbol optimization is limited to 7,089 scalars. High-level oversized
planning uses a bounded unoptimized estimate. Optimization is linear in text
length, respects segment count-field limits, and is cached locally by the three
QR version bands. Its deterministic tie policy minimizes bits, then segment
count, with numeric/alphanumeric/Kanji/byte mode order and older equivalent
starts preferred. This can choose a different equally optimal segmentation
than another port's historical tie policy.

## Manual segments and controls

```julia
segments = [Segment("numeric", "1234567890"), Segment("byte", UInt8[0xff, 0x00])]
preview = analyze_segments(segments)
code = generate_segments(segments)
```

Control segment modes are `eci`, `fnc1`, `fnc1-second`, and
`structured-append`. FNC1 and Structured Append headers must be first and
unique. ECI can occur after data and can repeat to relabel later byte segments.
Different control families cannot be combined in this implementation. `Options(eci=true)` selects UTF-8 ECI 26; integer `0` remains a valid
assignment. `Options(fnc1_second="00")` preserves the indicator.

`gs1=true` validates a high-level GS1 element string and emits first-position
FNC1. `fnc1=true` emits that header for caller-controlled text without invoking
GS1 AI validation. Literal percent in high-level FNC1 data selects byte mode
(or is rejected when alphanumeric mode is explicitly forced). U+001D group
separators, including consecutive separators, remain real bytes. Manual FNC1
alphanumeric segments are already escaped QR data and are never rewritten:
`%` denotes a separator and `%%` a literal percent for readers.

## Structured Append

```julia
set = generate_structured_append("HELLO WORLD "^40;
    version=2, error_correction_level="M", max_symbols=16)

manual = generate_segments_structured_append(
    [Segment("numeric", "12345"), Segment("byte", "é😀"^30)];
    version=2, diagnostics=(split_units="full", symbol_results="diagnostics"))
```

A set contains 2–16 symbols, all at one selected version. Automatic selection
chooses the smallest permitted version that can split the payload into the
configured maximum count. Each part is the largest fitting next prefix. Text
splits only at Unicode scalar boundaries. Manual numeric, alphanumeric, and
Kanji segments remain atomic; only manual byte segments are split.

If the whole input fits one symbol in the selected range, use `generate` or an
explicit low-level header. Structured Append generation owns its headers and
does not accept FNC1, GS1, ECI, ECC boosting, or a parity override. Indices and
totals are one-based; canonical parity is the XOR of original UTF-8 text or raw
bytes, including UTF-8 rather than Shift JIS for Kanji text.

`SAResult` exposes `symbols`, `total`, `parity`, `input_length`, `byte_length`,
and `diagnostics`. Offset diagnostics are explicitly zero-based offsets into
the original input. `merge_structured_append_parts` accepts decoded mappings
containing `index`, `total`, `parity`, and `data`; it checks completeness,
duplicates, consistent types, and parity before concatenation. Parts may arrive
in any order. XOR parity detects some corruption and is not authentication.

## Diagnostics and rendering

`diagnostics(result)` returns a deep copy. Planning and generation diagnostics
report segment costs, version/ECC selection, capacity, controls, GS1 validation,
quiet-zone sufficiency, contrast, transparency, and optional print size. Passing
`print_dpi` requires finite positive derived geometry. Warning codes include
`QUIET_ZONE_TOO_SMALL`, `COLOR_CONTRAST_LOW`, `COLOR_ALPHA_USED`,
`PRINT_MODULE_TOO_SMALL`, `CAPACITY_NEAR_LIMIT`, and `SCAN_RISK`.

Use `to_svg`, `to_png`, `to_pixels`, `to_svg_data_url`, or `to_png_data_url` on a
QR result. Result methods inherit its margin, scale, and colors, with keyword
overrides. `render(code, "matrix")` returns a copied matrix; other outputs are
`"svg"`, `"png"`, `"pixels"`, `"svg-data-url"`, and `"png-data-url"`.
