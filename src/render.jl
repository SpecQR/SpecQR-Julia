# Portable renderers. PNG uses only stored DEFLATE, CRC-32 and Adler-32 below.
const RASTER_PIXEL_BUDGET = 4 * 1024 * 1024
const SVG_CHARACTER_BUDGET = 8 * 1024 * 1024
const DATA_URL_CHARACTER_BUDGET = 32 * 1024 * 1024
const MAX_GEOMETRY_INTEGER = 1_000_000_000

function _render_integer(value, name, minimum)
    value isa Integer && !(value isa Bool) && minimum <= value <= MAX_GEOMETRY_INTEGER ||
        throw(InvalidInputError("$name must be an integer from $minimum to $MAX_GEOMETRY_INTEGER"))
    Int(value)
end

function _render_matrix(matrix)
    matrix isa AbstractMatrix{Bool} || throw(InvalidInputError("matrix must be a square boolean matrix"))
    n = size(matrix, 1)
    1 <= n <= 177 && size(matrix, 2) == n || throw(InvalidInputError("matrix must be square with dimension 1..177"))
    axes(matrix) == (Base.OneTo(n), Base.OneTo(n)) || throw(InvalidInputError("matrix must have one-based indices"))
    matrix
end

function _render_geometry(matrix, margin, scale; raster=false)
    m = _render_integer(margin, "margin", 0)
    s = _render_integer(scale, "scale", 1)
    mat = _render_matrix(matrix)
    n = size(mat, 1)
    m <= (MAX_GEOMETRY_INTEGER - n) ÷ 2 || throw(InvalidInputError("render dimension exceeds geometry bound"))
    span = n + 2m
    s <= MAX_GEOMETRY_INTEGER ÷ span || throw(InvalidInputError("render dimension exceeds geometry bound"))
    d = span * s
    !raster || d <= 2048 || throw(InvalidInputError("raster exceeds the 4194304 pixel budget"))
    mat, d, m, s
end

function _render_color_text(value)
    value isa AbstractString || throw(InvalidColorError("color must be a string"))
    ncodeunits(value) <= 64 && isvalid(value) || throw(InvalidColorError("color must be valid UTF-8 with at most 64 bytes"))
    text = strip(String(value))
    isempty(text) && throw(InvalidColorError("color must not be empty"))
    if startswith(text, "#")
        ncodeunits(text) in (4,5,7,9) && all(c -> c in "0123456789abcdefABCDEF", text[2:end]) ||
            throw(InvalidColorError("invalid hexadecimal color"))
    else
        all(c -> 'a' <= c <= 'z' || 'A' <= c <= 'Z', text) ||
            throw(InvalidColorError("SVG colors must be hex or simple ASCII CSS names"))
    end
    text
end

"""Parse bounded hex RGB/RGBA, black, white or transparent into an RGBA tuple."""
function parse_color(value; strict=true)
    strict isa Bool || throw(InvalidInputError("strict must be a boolean"))
    text = lowercase(_render_color_text(value))
    text == "black" && return (0,0,0,255)
    text == "white" && return (255,255,255,255)
    text == "transparent" && return (0,0,0,0)
    if startswith(text, "#")
        h = text[2:end]
        parts = length(h) <= 4 ? [parse(Int, string(c); base=16)*17 for c in h] :
            [parse(Int, h[i:i+1]; base=16) for i in 1:2:length(h)]
        length(parts) == 3 && push!(parts, 255)
        return Tuple(parts)
    end
    strict && throw(InvalidColorError("raster colors must be hex RGB/RGBA, black, white, or transparent"))
    nothing
end

function _render_channels(value)
    value isa AbstractString && return parse_color(value)
    (value isa Tuple || value isa AbstractVector) && length(value) == 4 ||
        throw(InvalidColorError("color channels must contain four integers from 0 to 255"))
    all(v -> v isa Integer && !(v isa Bool) && 0 <= v <= 255, value) ||
        throw(InvalidColorError("color channels must contain four integers from 0 to 255"))
    Tuple(Int(v) for v in value)
end

"""Contrast after background-on-white and foreground-on-background alpha composition."""
function contrast_ratio(foreground, background)
    fg, bg = _render_channels(foreground), _render_channels(background)
    linear(v) = v <= 0.04045 ? v/12.92 : ((v+0.055)/1.055)^2.4
    ba, fa = bg[4]/255, fg[4]/255
    back = ntuple(i -> bg[i]/255*ba + 1-ba, 3)
    front = ntuple(i -> fg[i]/255*fa + back[i]*(1-fa), 3)
    weights = (0.2126,0.7152,0.0722)
    a = sum(linear(front[i])*weights[i] for i in 1:3)
    b = sum(linear(back[i])*weights[i] for i in 1:3)
    (max(a,b)+0.05)/(min(a,b)+0.05)
end

function render_dimensions(matrix; margin=4, scale=8, dpi=nothing)
    _, d, m, s = _render_geometry(matrix, margin, scale)
    if dpi === nothing
        return (width=d, height=d, module_pixels=s, margin_modules=m, dpi=nothing, module_size_mm=nothing, symbol_size_mm=nothing)
    end
    dpi isa Real && !(dpi isa Bool) && isfinite(dpi) && dpi > 0 ||
        throw(InvalidInputError("print DPI must be finite and positive"))
    p = Float64(dpi)
    modmm, sizemm = (s/p)*25.4, (d/p)*25.4
    all(v -> isfinite(v) && v > 0, (p,modmm,sizemm)) ||
        throw(InvalidInputError("physical dimensions must be finite and positive"))
    (width=d, height=d, module_pixels=s, margin_modules=m, dpi=p, module_size_mm=modmm, symbol_size_mm=sizemm)
end

_render_xml(value) = replace(value, '&'=>"&amp;", '<'=>"&lt;", '>'=>"&gt;", '"'=>"&quot;", '\''=>"&apos;")

function to_svg(matrix; margin=4, scale=8, foreground="black", background="white")
    mat, d, m, s = _render_geometry(matrix, margin, scale)
    fg, bg = _render_xml(_render_color_text(foreground)), _render_xml(_render_color_text(background))
    bound = count(mat)*(7 + 2ndigits(d) + 3ndigits(s)) + 512 + 6(ncodeunits(fg)+ncodeunits(bg))
    bound <= SVG_CHARACTER_BUDGET || throw(InvalidInputError("SVG exceeds character budget"))
    out = IOBuffer(sizehint=bound)
    print(out, "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"", d, "\" height=\"", d,
          "\" viewBox=\"0 0 ", d, ' ', d, "\" role=\"img\"><rect width=\"100%\" height=\"100%\" fill=\"", bg,
          "\"/><path fill=\"", fg, "\" d=\"")
    for y in axes(mat,1), x in axes(mat,2)
        mat[y,x] && print(out, 'M', (x-1+m)*s, ',', (y-1+m)*s, 'h', s, 'v', s, "h-", s, 'z')
    end
    print(out, "\"/></svg>")
    String(take!(out))
end

struct Pixels
    width::Int
    height::Int
    pixels::Vector{UInt8}
end

function to_pixels(matrix; margin=4, scale=8, foreground="black", background="white")
    mat, d, m, s = _render_geometry(matrix, margin, scale; raster=true)
    fg, bg = parse_color(foreground), parse_color(background)
    n = size(mat,1)
    data = Vector{UInt8}(undef, 4d*d)
    p = 1
    for y in 0:d-1
        my = y ÷ s - m + 1
        for x in 0:d-1
            mx = x ÷ s - m + 1
            c = 1 <= my <= n && 1 <= mx <= n && mat[my,mx] ? fg : bg
            for k in 1:4
                data[p] = UInt8(c[k]); p += 1
            end
        end
    end
    Pixels(d,d,data)
end

function render_rgba(matrix; kwargs...)
    p = to_pixels(matrix; kwargs...)
    (width=p.width, height=p.height, data=p.pixels)
end

const _PNG_CRC_TABLE = ntuple(256) do index
    c = UInt32(index-1)
    for _ in 1:8
        c = (c >> 1) ⊻ (isodd(c) ? UInt32(0xedb88320) : UInt32(0))
    end
    c
end
function _png_crc(data)
    c = typemax(UInt32)
    for b in data
        c = _PNG_CRC_TABLE[Int((c ⊻ b) & 0xff)+1] ⊻ (c >> 8)
    end
    c ⊻ typemax(UInt32)
end
function _png_adler(data)
    a, b = UInt32(1), UInt32(0)
    for v in data
        a = (a + v) % UInt32(65521); b = (b+a) % UInt32(65521)
    end
    (b << 16) | a
end
function _png_be32(out, n)
    value = UInt32(n)
    for shift in (24,16,8,0)
        write(out, UInt8((value >> shift) & 0xff))
    end
end
function _png_chunk(out, kind, data)
    _png_be32(out, length(data))
    write(out, codeunits(kind)); write(out, data)
    c = typemax(UInt32)
    for bytes in (codeunits(kind), data), b in bytes
        c = _PNG_CRC_TABLE[Int((c ⊻ b) & 0xff)+1] ⊻ (c >> 8)
    end
    _png_be32(out, c ⊻ typemax(UInt32))
end

function to_png(matrix; kwargs...)
    image = to_pixels(matrix; kwargs...)
    stride = 4image.width
    raw = Vector{UInt8}(undef, (stride+1)*image.height)
    for y in 0:image.height-1
        raw[y*(stride+1)+1] = 0
        copyto!(raw,y*(stride+1)+2,image.pixels,y*stride+1,stride)
    end
    z = IOBuffer(sizehint=length(raw)+5cld(length(raw),65535)+6)
    write(z, UInt8[0x78,0x01])
    p = 1
    while p <= length(raw)
        n = min(65535,length(raw)-p+1)
        write(z, UInt8(p+n > length(raw)))
        inv = n ⊻ 65535
        write(z, UInt8[n & 255,n >> 8,inv & 255,inv >> 8])
        write(z, @view raw[p:p+n-1]); p += n
    end
    _png_be32(z,_png_adler(raw))
    header = IOBuffer(); _png_be32(header,image.width); _png_be32(header,image.height)
    write(header, UInt8[8,6,0,0,0])
    out = IOBuffer(sizehint=length(raw)+5cld(length(raw),65535)+100)
    write(out, UInt8[137,80,78,71,13,10,26,10])
    _png_chunk(out,"IHDR",take!(header)); _png_chunk(out,"IDAT",take!(z)); _png_chunk(out,"IEND",UInt8[])
    take!(out)
end

function to_svg_data_url(matrix; kwargs...)
    svg = to_svg(matrix; kwargs...)
    3ncodeunits(svg)+31 <= DATA_URL_CHARACTER_BUDGET || throw(InvalidInputError("SVG data URL exceeds character budget"))
    out = IOBuffer(sizehint=3ncodeunits(svg)+31)
    print(out,"data:image/svg+xml;charset=utf-8,")
    for b in codeunits(svg)
        if UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z') || UInt8('0') <= b <= UInt8('9') || b in codeunits("~!*'()-._")
            write(out,b)
        else
            print(out,'%',uppercase(string(b;base=16,pad=2)))
        end
    end
    String(take!(out))
end
function to_png_data_url(matrix; kwargs...)
    png = to_png(matrix; kwargs...)
    4cld(length(png),3)+22 <= DATA_URL_CHARACTER_BUDGET || throw(InvalidInputError("PNG data URL exceeds character budget"))
    "data:image/png;base64," * Base64.base64encode(png)
end
function to_data_url(matrix; format="png", kwargs...)
    format isa AbstractString || throw(InvalidOutputError("data URL format must be png or svg"))
    format == "png" && return to_png_data_url(matrix; kwargs...)
    format == "svg" && return to_svg_data_url(matrix; kwargs...)
    throw(InvalidOutputError("data URL format must be png or svg"))
end
