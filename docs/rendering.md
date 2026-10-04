# Rendering and geometry

SpecQR renders directly from a one-based, square boolean matrix with rows indexed
as `matrix[y, x]`. Encoder results use ordinary `Matrix{Bool}` storage. The direct
renderers also accept other one-based `AbstractMatrix{Bool}` values. Matrix side
length must be 1–177. Defaults are margin 4 modules, scale 8 pixels per module,
black foreground, and white background.

```julia
using SpecQR
q = generate("Hello, Julia!")
svg = to_svg(q)
png = to_png(q)                 # Vector{UInt8}, standard RGBA PNG
url = to_data_url(q; format="png")
write("hello.svg", svg)
write("hello.png", png)
```

Direct matrix calls have the same `margin`, `scale`, `foreground`, and
`background` keyword arguments. `to_svg_data_url` and `to_png_data_url` are
explicit alternatives to `to_data_url`. SVG data URLs use UTF-8 percent encoding;
PNG data URLs use standard Base64. No network requests or external codecs are
used.

## Supported colors

* SVG: `#RGB`, `#RGBA`, `#RRGGBB`, `#RRGGBBAA`, or a simple ASCII CSS name
* PNG/RGBA: those hexadecimal forms, `black`, `white`, or `transparent`
* Hexadecimal and named raster colors are case insensitive
* Leading/trailing whitespace is trimmed; each supplied color is limited to
  64 UTF-8 bytes before trimming

SVG intentionally excludes arbitrary CSS expressions, URL paints, `var(...)`,
functions, and markup. All accepted color text is also XML escaped before
insertion. An unrecognized simple CSS name may render differently across SVG
consumers; `parse_color(name; strict=false)` returns `nothing` when raster color
semantics are unavailable. Malformed or unsafe color strings always fail.

`to_pixels(matrix; ...)` returns a `Pixels` value with `width`, `height`, and
`pixels`, a row-major `Vector{UInt8}` containing unpremultiplied RGBA bytes.
`render_rgba` returns equivalent `(width, height, data)` fields.

`contrast_ratio(foreground, background)` accepts raster color strings or four
integer channel values. It composites background alpha over white, foreground
alpha over that result, then computes relative-luminance contrast. Transparent
colors therefore do not receive an opaque-color contrast score accidentally.

## PNG implementation

PNG is written from scratch: 8-bit RGBA, filter type 0 per scanline, one IDAT
chunk, and a zlib wrapper containing deterministic stored-DEFLATE blocks of at
most 65,535 bytes. CRC-32 and Adler-32 are computed by local Julia routines.
PNG output has no timestamps or nondeterministic metadata. It is intentionally
larger than PNG compressed with a general-purpose DEFLATE encoder. Production
rendering requires only Base and the Base64 standard library, with no image
package, JLL dependency, codec FFI, shell command, or remote service.

## Resource limits and print sizes

`margin` must be a nonnegative integer and `scale` a positive integer. Booleans
and floating-point values are rejected. Each and the final dimension are bounded
by 1,000,000,000; multiplication is checked before performing it.

Raster output is capped at 4,194,304 pixels (2048 × 2048 for a square). SVG has an
8 MiB character budget and data URLs a 32 MiB character budget. Bounds are checked
before output-sized allocation. Invalid geometry and resource limits throw
`InvalidInputError`; unsafe or unsupported colors throw `InvalidColorError`;
unsupported data URL formats throw `InvalidOutputError`.

`render_dimensions(matrix; margin=4, scale=8, dpi=nothing)` reports pixel geometry.
A positive, finite `dpi` additionally reports `module_size_mm` and
`symbol_size_mm`, using 25.4 mm per inch. Any conversion yielding zero or
non-finite physical dimensions is rejected. Print dimensions describe output
geometry, not a guarantee of scanner performance or GS1 print-quality compliance.
