# QR block coding, finite-field arithmetic, module placement and mask selection.
# Ported from SpecQR 15ad15e5c770ea0e39072f8f88b2733018f02ffd.
# Copyright (c) 2026 SpecQR contributors. MIT license.

const _MAX_CODEWORDS = 3706

function _core_integer(value, lower, upper, label)
    value isa Integer && !(value isa Bool) && lower <= value <= upper ||
        throw(InvalidInputError("$label must be an integer from $lower to $upper"))
    return Int(value)
end

# Public byte arrays are copied and range-checked before use. A UInt8 vector is
# accepted as binary even when it contains malformed UTF-8; byte data is opaque.
function _core_bytes(data, label)
    (data isa AbstractVector || data isa Tuple) ||
        throw(InvalidInputError("$label must be a finite byte sequence"))
    length(data) <= _MAX_CODEWORDS ||
        throw(InvalidInputError("$label exceeds the maximum QR codeword count"))
    result = Vector{UInt8}(undef, length(data))
    for (i, value) in enumerate(data)
        result[i] = UInt8(_core_integer(value, 0, 255, "$label value"))
    end
    return result
end

"""Pad complete 0/1 integer segment bits to exact QR data capacity."""
function pad_data_bits(bits, version, level)
    capacity = data_codeword_count(version, level)
    (bits isa AbstractVector || bits isa Tuple) ||
        throw(InvalidInputError("Bits must be a finite sequence of integer 0/1 values"))
    n = length(bits)
    n <= capacity * 8 || throw(DataTooLongError(
        "Input requires $n bits, but version $version-$level has $(capacity * 8) data bits"))
    result = zeros(UInt8, capacity)
    for (index, value) in enumerate(bits)
        value isa Integer && !(value isa Bool) && value in (0, 1) ||
            throw(InvalidInputError("Bits must contain only integer 0/1 values"))
        result[(index - 1) ÷ 8 + 1] |= UInt8(value) << (7 - (index - 1) % 8)
    end
    terminated = n + min(4, capacity * 8 - n)
    padded_bytes = (terminated + 7) ÷ 8
    for index in padded_bytes:(capacity - 1)
        result[index + 1] = (index - padded_bytes) % 2 == 0 ? 0xec : 0x11
    end
    return result
end

function _gf_multiply(left::Int, right::Int)
    product = 0
    while right != 0
        right & 1 != 0 && (product ⊻= left)
        right >>= 1
        left <<= 1
        left & 0x100 != 0 && (left ⊻= 0x11d)
    end
    return product
end

"""Multiply bytes in QR GF(256), reduction polynomial 0x11D."""
function gf_multiply(left, right)
    a = _core_integer(left, 0, 255, "Left operand")
    b = _core_integer(right, 0, 255, "Right operand")
    return _gf_multiply(a, b)
end

function _divisor(degree::Int)
    coefficients = zeros(UInt8, degree + 1)
    coefficients[1] = 1
    root = 1
    for factor in 0:(degree - 1)
        for index in (factor + 1):-1:1
            coefficients[index + 1] ⊻= UInt8(_gf_multiply(Int(coefficients[index]), root))
        end
        root = _gf_multiply(root, 2)
    end
    return coefficients
end

"""Descending-power Reed-Solomon divisor coefficients, including monic 1."""
reed_solomon_divisor(degree) = _divisor(_core_integer(degree, 1, 255, "Reed-Solomon degree"))

function _remainder(data::Vector{UInt8}, divisor::Vector{UInt8})
    degree = length(divisor) - 1
    result = zeros(UInt8, degree)
    for value in data
        factor = Int(value ⊻ result[1])
        for index in 1:(degree - 1)
            result[index] = result[index + 1] ⊻ UInt8(_gf_multiply(Int(divisor[index + 1]), factor))
        end
        result[end] = UInt8(_gf_multiply(Int(divisor[end]), factor))
    end
    return result
end

"""Compute bounded QR Reed-Solomon parity without shared mutable caches."""
function reed_solomon_remainder(data, degree)
    bytes = _core_bytes(data, "Data")
    return _remainder(bytes, reed_solomon_divisor(degree))
end

function interleave_codewords(data, version, level)
    info = block_info(version, level)
    bytes = _core_bytes(data, "Data codewords")
    length(bytes) == info.data_codewords || throw(InvalidInputError(
        "Expected $(info.data_codewords) data codewords; got $(length(bytes))"))
    short_count = info.blocks - info.raw_codewords % info.blocks
    short_data_length = info.raw_codewords ÷ info.blocks - info.ecc_per_block
    divisor = _divisor(info.ecc_per_block)
    blocks = NamedTuple{(:data, :ecc),Tuple{Vector{UInt8},Vector{UInt8}}}[]
    offset = 0
    for index in 0:(info.blocks - 1)
        n = short_data_length + Int(index >= short_count)
        block_data = bytes[(offset + 1):(offset + n)]
        push!(blocks, (data=block_data, ecc=_remainder(block_data, divisor)))
        offset += n
    end
    result = UInt8[]
    sizehint!(result, info.raw_codewords)
    for column in 1:(short_data_length + 1), block in blocks
        column <= length(block.data) && push!(result, block.data[column])
    end
    for column in 1:info.ecc_per_block, block in blocks
        push!(result, block.ecc[column])
    end
    offset == length(bytes) && length(result) == info.raw_codewords ||
        throw(InvalidInputError("Inconsistent QR block interleaving length"))
    return (codewords=result, blocks=Tuple(blocks), data_codewords=info.data_codewords,
        error_correction_codewords=info.raw_codewords-info.data_codewords,
        total_codewords=info.raw_codewords)
end

function _mask_condition(mask::Int, x::Int, y::Int)
    mask == 0 && return (x + y) % 2 == 0
    mask == 1 && return y % 2 == 0
    mask == 2 && return x % 3 == 0
    mask == 3 && return (x + y) % 3 == 0
    mask == 4 && return (y ÷ 2 + x ÷ 3) % 2 == 0
    mask == 5 && return x * y % 2 + x * y % 3 == 0
    mask == 6 && return (x * y % 2 + x * y % 3) % 2 == 0
    return ((x + y) % 2 + x * y % 3) % 2 == 0
end

function mask_condition(mask, x, y)
    m = _core_integer(mask, 0, 7, "Mask pattern")
    col = _core_integer(x, 0, 176, "Column")
    row = _core_integer(y, 0, 176, "Row")
    return _mask_condition(m, col, row)
end

function _line_penalty(line)
    penalty = 0
    run_color = -1
    run_length = 0
    window = 0
    for (index, v) in enumerate(line)
        value = Int(v)
        if value == run_color
            run_length += 1
        else
            run_length >= 5 && (penalty += run_length - 2)
            run_color = value
            run_length = 1
        end
        window = ((window << 1) | value) & 0x7ff
        index >= 11 && window in (0b10111010000, 0b00001011101) && (penalty += 40)
    end
    run_length >= 5 && (penalty += run_length - 2)
    return penalty
end

function _penalty_score(matrix::Matrix{Bool})
    side = size(matrix, 1)
    score = 0
    for i in 1:side
        score += _line_penalty(@view matrix[i, :])
        score += _line_penalty(@view matrix[:, i])
    end
    for y in 1:(side - 1), x in 1:(side - 1)
        matrix[y,x] == matrix[y,x+1] == matrix[y+1,x] == matrix[y+1,x+1] && (score += 3)
    end
    total = side * side
    dark = count(identity, matrix)
    return score + abs(dark * 20 - total * 10) ÷ total * 10
end

"""Score a square 1–177 matrix of exact Bool modules using SpecQR N1–N4."""
function penalty_score(matrix)
    matrix isa AbstractMatrix || throw(InvalidInputError("Matrix must be a square 1 to 177 module matrix"))
    rows, cols = size(matrix)
    1 <= rows <= 177 && rows == cols || throw(InvalidInputError("Matrix must be a square 1 to 177 module matrix"))
    result = Matrix{Bool}(undef, rows, cols)
    for (dest, value) in zip(eachindex(result), matrix)
        value isa Bool || throw(InvalidInputError("Matrix modules must be booleans"))
        result[dest] = value
    end
    return _penalty_score(result)
end

struct _Grid
    side::Int
    modules::Matrix{Bool}
    functions::Matrix{Bool}
end
_Grid(side::Int) = _Grid(side, fill(false, side, side), fill(false, side, side))

function _function!(grid::_Grid, x::Int, y::Int, dark)
    if 0 <= x < grid.side && 0 <= y < grid.side
        grid.modules[y + 1, x + 1] = dark != 0
        grid.functions[y + 1, x + 1] = true
    end
    return nothing
end

function _finder!(grid::_Grid, left::Int, top::Int)
    for dy in -1:7, dx in -1:7
        in_pattern = 0 <= dx <= 6 && 0 <= dy <= 6
        dark = in_pattern && (dx in (0, 6) || dy in (0, 6) || (2 <= dx <= 4 && 2 <= dy <= 4))
        _function!(grid, left + dx, top + dy, dark)
    end
end

function _draw_format!(grid::_Grid, level, mask::Int)
    data = (format_bits(level) << 3) | mask
    remainder = data
    for _ in 1:10
        remainder = (remainder << 1) ⊻ (((remainder >> 9) & 1) * 0x537)
    end
    bits = ((data << 10) | remainder) ⊻ 0x5412
    for index in 0:5
        _function!(grid, 8, index, (bits >> index) & 1)
    end
    _function!(grid, 8, 7, (bits >> 6) & 1)
    _function!(grid, 8, 8, (bits >> 7) & 1)
    _function!(grid, 7, 8, (bits >> 8) & 1)
    for index in 9:14
        _function!(grid, 14 - index, 8, (bits >> index) & 1)
    end
    for index in 0:7
        _function!(grid, grid.side - 1 - index, 8, (bits >> index) & 1)
    end
    for index in 8:14
        _function!(grid, 8, grid.side - 15 + index, (bits >> index) & 1)
    end
end

function _draw_functions!(grid::_Grid, version::Int, level)
    _finder!(grid, 0, 0)
    _finder!(grid, grid.side - 7, 0)
    _finder!(grid, 0, grid.side - 7)
    for index in 8:(grid.side - 9)
        _function!(grid, index, 6, index % 2 == 0)
        _function!(grid, 6, index, index % 2 == 0)
    end
    positions = alignment_positions(version)
    last = length(positions)
    for (yi, y) in enumerate(positions), (xi, x) in enumerate(positions)
        (xi, yi) in ((1,1), (last,1), (1,last)) && continue
        for dy in -2:2, dx in -2:2
            _function!(grid, x + dx, y + dy, max(abs(dx), abs(dy)) != 1)
        end
    end
    _draw_format!(grid, level, 0)
    _function!(grid, 8, grid.side - 8, true)
    if version >= 7
        remainder = version
        for _ in 1:12
            remainder = (remainder << 1) ⊻ (((remainder >> 11) & 1) * 0x1f25)
        end
        bits = (version << 12) | remainder
        for index in 0:17
            a, b = grid.side - 11 + index % 3, index ÷ 3
            _function!(grid, a, b, (bits >> index) & 1)
            _function!(grid, b, a, (bits >> index) & 1)
        end
    end
end

function _draw_codewords!(grid::_Grid, codewords::Vector{UInt8})
    bit_index = 0
    right = grid.side - 1
    while right >= 1
        right == 6 && (right = 5)
        for vertical in 0:(grid.side - 1)
            y = ((right + 1) & 2) == 0 ? grid.side - 1 - vertical : vertical
            for x in (right, right - 1)
                if !grid.functions[y + 1, x + 1]
                    if bit_index < length(codewords) * 8
                        grid.modules[y + 1, x + 1] = ((codewords[bit_index ÷ 8 + 1] >> (7 - bit_index % 8)) & 1) != 0
                    end
                    bit_index += 1
                end
            end
        end
        right -= 2
    end
    0 <= bit_index - length(codewords) * 8 <= 7 ||
        throw(InvalidInputError("Inconsistent QR data-module count"))
end

function _masked(grid::_Grid, level, mask::Int)
    # No reservation array is shared with a returned candidate, even temporarily.
    candidate = _Grid(grid.side, copy(grid.modules), copy(grid.functions))
    for y in 0:(grid.side - 1), x in 0:(grid.side - 1)
        if !candidate.functions[y + 1, x + 1] && _mask_condition(mask, x, y)
            candidate.modules[y + 1, x + 1] ⊻= true
        end
    end
    _draw_format!(candidate, level, mask)
    return candidate
end

function build_matrix(codewords, version, level, mask=nothing; mask_pattern=nothing)
    if mask_pattern !== nothing
        mask === nothing || throw(InvalidInputError("Specify mask only once"))
        mask = mask_pattern
    end
    side = qr_size(version)
    validate_level(level)
    mask === nothing || _core_integer(mask, 0, 7, "Mask pattern")
    bytes = _core_bytes(codewords, "Interleaved codewords")
    expected = raw_codeword_count(version)
    length(bytes) == expected || throw(InvalidInputError("Expected $expected interleaved codewords; got $(length(bytes))"))
    base = _Grid(side)
    _draw_functions!(base, Int(version), level)
    _draw_codewords!(base, bytes)
    best = nothing
    best_mask = 0
    best_penalty = typemax(Int)
    penalties = NamedTuple{(:mask_pattern, :penalty),Tuple{Int,Int}}[]
    candidates = mask === nothing ? (0:7) : (Int(mask):Int(mask))
    for m in candidates
        candidate = _masked(base, level, m)
        penalty = _penalty_score(candidate.modules)
        push!(penalties, (mask_pattern=m, penalty=penalty))
        if best === nothing || penalty < best_penalty
            best = candidate.modules
            best_mask, best_penalty = m, penalty
        end
    end
    return (matrix=best::Matrix{Bool}, mask_pattern=best_mask,
            penalty=best_penalty, mask_penalties=Tuple(penalties))
end
