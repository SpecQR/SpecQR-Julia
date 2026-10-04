# QR Model 2 tables, ported from SpecQR 15ad15e5c770ea0e39072f8f88b2733018f02ffd.
# Copyright (c) 2026 SpecQR contributors. MIT license.

const ERROR_CORRECTION_LEVEL_ORDER = ("L", "M", "Q", "H")
const _FORMAT_BITS = (1, 0, 3, 2)
const ECC_CODEWORDS_PER_BLOCK = (
    (7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28),
    (13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
    (17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30),
)
const NUM_ERROR_CORRECTION_BLOCKS = (
    (1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25),
    (1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49),
    (1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68),
    (1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81),
)

function validate_version(version)
    version isa Integer && !(version isa Bool) && 1 <= version <= 40 ||
        throw(InvalidVersionError("QR version must be an integer from 1 to 40"))
    return nothing
end

function validate_level(level)
    level isa AbstractString && level in ERROR_CORRECTION_LEVEL_ORDER ||
        throw(InvalidEccError("Error correction level must be one of L, M, Q, H"))
    return nothing
end

function _level_index(level)
    validate_level(level)
    return findfirst(==(level), ERROR_CORRECTION_LEVEL_ORDER)::Int
end
format_bits(level) = _FORMAT_BITS[_level_index(level)]
function qr_size(version)
    validate_version(version)
    return Int(version) * 4 + 17
end

function raw_codeword_count(version)
    validate_version(version)
    v = Int(version)
    result = (16v + 128)v + 64
    if v >= 2
        n = v ÷ 7 + 2
        result -= (25n - 10)n - 55
        v >= 7 && (result -= 36)
    end
    return result ÷ 8
end

function block_info(version, level)
    validate_version(version)
    ordinal = _level_index(level)
    v = Int(version)
    blocks = NUM_ERROR_CORRECTION_BLOCKS[ordinal][v]
    ecc = ECC_CODEWORDS_PER_BLOCK[ordinal][v]
    raw = raw_codeword_count(v)
    return (blocks=blocks, ecc_per_block=ecc, raw_codewords=raw,
            data_codewords=raw - blocks * ecc)
end
data_codeword_count(version, level) = block_info(version, level).data_codewords

function alignment_positions(version)
    validate_version(version)
    v = Int(version)
    v == 1 && return ()
    n = v ÷ 7 + 2
    denominator = n * 2 - 2
    step = v == 32 ? 26 : ((v * 4 + 4 + denominator - 1) ÷ denominator) * 2
    return (6, (qr_size(v) - 7 - i * step for i in (n - 2):-1:0)...)
end

function character_count_bits(version, mode)
    validate_version(version)
    group = version <= 9 ? 1 : version <= 26 ? 2 : 3
    m = mode isa Symbol ? String(mode) : mode
    m == "numeric" && return (10, 12, 14)[group]
    m == "alphanumeric" && return (9, 11, 13)[group]
    m == "byte" && return (8, 16, 16)[group]
    m == "kanji" && return (8, 10, 12)[group]
    throw(InvalidModeError("Mode must be numeric, alphanumeric, byte, or kanji"))
end
