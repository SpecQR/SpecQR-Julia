# Strict immutable-owned data and control segments for QR Model 2.
# Ported from SpecQR 15ad15e5c770ea0e39072f8f88b2733018f02ffd.
# Copyright (c) 2026 SpecQR contributors. MIT license.

const ALPHANUMERIC_CHARSET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:"
const _DATA_MODES = ("numeric", "alphanumeric", "kanji", "byte")
const _CONTROL_MODES = ("eci", "fnc1", "fnc1-second", "structured-append")
const MAX_SINGLE_SYMBOL_CHARACTERS = 7089
const MAX_SINGLE_SYMBOL_DATA_BITS = 23648
const MAX_PAYLOAD_UNITS = 1_000_000
const MAX_MANUAL_SEGMENTS = 16_384

function _payload_units(data)
    units = if data isa AbstractString
        ncodeunits(data) <= 4MAX_PAYLOAD_UNITS || throw(DataTooLongError("Text exceeds the payload resource limit"))
        length(data)
    elseif data isa AbstractVector || data isa Tuple
        length(data)
    else
        0
    end
    units <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Payload exceeds the $MAX_PAYLOAD_UNITS-unit resource limit"))
    return units
end

function _strict_utf8(text)
    text isa AbstractString || throw(InvalidInputError("QR text must be a string"))
    _payload_units(text)
    isvalid(text) || throw(InvalidInputError("QR text must be well-formed UTF-8 without surrogate code points"))
    for c in text
        isvalid(c) && UInt32(c) <= 0x10ffff && !(0xd800 <= UInt32(c) <= 0xdfff) ||
            throw(InvalidInputError("QR text must contain Unicode scalar values"))
    end
    return Vector{UInt8}(codeunits(String(text)))
end

function _kanji_code(character)
    c = if character isa Char
        isvalid(character) || return -1
        character
    elseif character isa AbstractString
        isvalid(character) && length(character) == 1 || return -1
        first(character)
    else
        return -1
    end
    scalar = UInt32(c)
    0x80 <= scalar <= 0xffff || return -1
    low, high = 1, length(_KANJI_KEYS)
    while low <= high
        mid = low + (high - low) ÷ 2
        key = _KANJI_KEYS[mid]
        if key < scalar
            low = mid + 1
        elseif key > scalar
            high = mid - 1
        else
            return Int(_KANJI_CODES[mid])
        end
    end
    return -1
end
can_encode_kanji(character) = _kanji_code(character) >= 0
function kanji_value(character)
    code = _kanji_code(character)
    code >= 0 || throw(InvalidModeError("kanji mode cannot encode this character"))
    adjusted = code - (code <= 0x9ffc ? 0x8140 : 0xc140)
    return (adjusted >> 8) * 0xc0 + (adjusted & 0xff)
end

function _alpha_value(c::Char)
    isascii(c) || return -1
    p = findfirst(==(c), ALPHANUMERIC_CHARSET)
    return p === nothing ? -1 : p - 1
end

function _segment_integer(value, label, minimum, maximum)
    value isa Integer && !(value isa Bool) && minimum <= value <= maximum ||
        throw(InvalidModeError("$label must be an integer from $minimum to $maximum"))
    return Int(value)
end

function _segment_mode(mode)
    m = mode isa Symbol ? String(mode) : mode
    m isa AbstractString && m in (_DATA_MODES..., _CONTROL_MODES...) ||
        throw(InvalidModeError("Unsupported segment mode"))
    return String(m)
end

function _segment_fields(mode, data, assignment_number, application_indicator, index, total, parity)
    m = _segment_mode(mode)
    values = (data=data, assignment_number=assignment_number,
        application_indicator=application_indicator, index=index, total=total, parity=parity)
    allowed = m in _DATA_MODES ? (:data,) : m == "eci" ? (:assignment_number,) :
        m == "fnc1-second" ? (:application_indicator,) :
        m == "structured-append" ? (:index,:total,:parity) : ()
    for name in keys(values)
        if values[name] !== nothing && !(name in allowed)
            error = m == "fnc1" ? InvalidGs1Error : InvalidModeError
            throw(error("$m segment does not accept $name"))
        end
    end
    payload = ""
    binary = false
    nchars = 0
    assignment = nothing
    application = nothing
    si, st, sp = nothing, nothing, nothing
    if m == "eci"
        assignment_number isa Integer && !(assignment_number isa Bool) && 0 <= assignment_number <= 999999 ||
            throw(InvalidEciError("ECI assignment number must be an integer from 0 to 999999"))
        assignment = Int(assignment_number)
    elseif m == "fnc1-second"
        v = application_indicator
        v isa AbstractString && isvalid(v) &&
            ((length(v) == 2 && all(c -> '0' <= c <= '9', v)) ||
             (length(v) == 1 && ('A' <= first(v) <= 'Z' || 'a' <= first(v) <= 'z'))) ||
            throw(InvalidModeError("FNC1 second application_indicator must be two ASCII digits or one Latin letter"))
        application = String(v)
    elseif m == "structured-append"
        si = _segment_integer(index, "Structured Append index", 1, 16)
        st = _segment_integer(total, "Structured Append total", 2, 16)
        sp = _segment_integer(parity, "Structured Append parity", 0, 255)
        si <= st || throw(InvalidModeError("Structured Append index must not exceed total"))
    elseif m in _DATA_MODES
        _payload_units(data)
        if m == "byte" && (data isa AbstractVector || data isa Tuple)
            bytes = Vector{UInt8}(undef, length(data))
            for (i,v) in enumerate(data)
                v isa Integer && !(v isa Bool) && 0 <= v <= 255 ||
                    throw(InvalidInputError("byte segment requires integer bytes from 0 to 255"))
                bytes[i] = UInt8(v)
            end
            payload = String(bytes) # The fresh vector is owned and never exposed.
            binary = true
        else
            data isa AbstractString || throw(InvalidInputError("$m segment requires text$(m == "byte" ? " or a byte sequence" : "")"))
            encoded = _strict_utf8(data)
            payload = String(encoded)
            nchars = length(payload)
            m == "numeric" && !all(c -> '0' <= c <= '9', payload) &&
                throw(InvalidModeError("numeric mode can only encode decimal digits 0-9"))
            m == "alphanumeric" && !all(c -> _alpha_value(c) >= 0, payload) &&
                throw(InvalidModeError("alphanumeric mode can only encode: $ALPHANUMERIC_CHARSET"))
            m == "kanji" && !all(can_encode_kanji, payload) &&
                throw(InvalidModeError("kanji mode cannot encode one or more characters"))
        end
    end
    return (m, payload, binary, nchars, assignment, application, si, st, sp)
end

"""A validated QR segment with immutable ownership of text and raw bytes.

Text byte segments always use strict UTF-8. ECI labels data without transcoding.
Manual FNC1 data is already QR-escaped and is preserved without rewriting.
Raw binary data is stored in an immutable String, never interpreted as text.
The data and logical_bytes properties return fresh byte vectors for binary data.
"""
struct Segment
    mode::String
    _payload::String
    _binary::Bool
    _characters::Int
    assignment_number::Union{Nothing,Int}
    application_indicator::Union{Nothing,String}
    index::Union{Nothing,Int}
    total::Union{Nothing,Int}
    parity::Union{Nothing,Int}
    function Segment(mode, data=nothing; assignment_number=nothing,
                     application_indicator=nothing, index=nothing, total=nothing, parity=nothing, kwargs...)
        isempty(kwargs) || throw(InvalidInputError("Unknown segment field: $(first(keys(kwargs)))"))
        fields = _segment_fields(mode, data, assignment_number, application_indicator, index, total, parity)
        return new(fields...)
    end
end

is_control(segment::Segment) = getfield(segment, :mode) in _CONTROL_MODES
segment_text(segment::Segment) = is_control(segment) || getfield(segment,:_binary) ? nothing : getfield(segment,:_payload)
logical_bytes(segment::Segment) = Vector{UInt8}(codeunits(getfield(segment,:_payload)))
Base.count(segment::Segment) = is_control(segment) ? 0 : segment.mode == "byte" ? ncodeunits(getfield(segment,:_payload)) : getfield(segment,:_characters)
character_count(segment::Segment) = getfield(segment,:_characters)
byte_count(segment::Segment) = segment.mode == "kanji" ? count(segment) * 2 : ncodeunits(getfield(segment,:_payload))
function application_indicator_codeword(segment::Segment)
    segment.mode == "fnc1-second" || return nothing
    value = getfield(segment,:application_indicator)::String
    return ncodeunits(value) == 2 ? parse(Int,value) : Int(first(value)) + 100
end

function Base.getproperty(segment::Segment, name::Symbol)
    name === :data && return is_control(segment) ? nothing : getfield(segment,:_binary) ? logical_bytes(segment) : getfield(segment,:_payload)
    name === :count && return count(segment)
    name === :character_count && return character_count(segment)
    name === :byte_count && return byte_count(segment)
    name === :logical_bytes && return logical_bytes(segment)
    name === :text && return segment_text(segment)
    name === :is_control && return is_control(segment)
    name === :application_indicator_codeword && return application_indicator_codeword(segment)
    return getfield(segment,name)
end
function Base.propertynames(::Segment, private::Bool=false)
    public = (:mode,:data,:assignment_number,:application_indicator,:index,:total,:parity,
        :count,:character_count,:byte_count,:logical_bytes,:text,:is_control,:application_indicator_codeword)
    return private ? (public...,:_payload,:_binary,:_characters) : public
end

# All construction routes use the validating inner constructor; no unchecked raw
# field constructor or caller-owned mutable storage is exposed.
function Segment(segment::Segment)
    return Segment(segment.mode, segment.data; assignment_number=segment.assignment_number,
        application_indicator=segment.application_indicator, index=segment.index,
        total=segment.total, parity=segment.parity)
end
numeric(data) = Segment("numeric",data)
alphanumeric(data) = Segment("alphanumeric",data)
byte(data) = Segment("byte",data)
bytesegment(data) = Segment("byte",data)
kanji(data) = Segment("kanji",data)
eci(assignment_number) = Segment("eci";assignment_number=assignment_number)
fnc1() = Segment("fnc1")
fnc1_first() = fnc1()
fnc1_second(application_indicator) = Segment("fnc1-second";application_indicator=application_indicator)
structured_append_segment(index,total,parity) = Segment("structured-append";index=index,total=total,parity=parity)

function bit_length(segment::Segment, version)
    validate_version(version)
    m = segment.mode
    if m == "eci"
        n = segment.assignment_number::Int
        return n < 128 ? 12 : n < 16384 ? 20 : 28
    end
    m == "fnc1" && return 4
    m == "fnc1-second" && return 12
    m == "structured-append" && return 20
    width = character_count_bits(version,m)
    n = count(segment)
    payload = m == "numeric" ? n ÷ 3 * 10 + (0,4,7)[n % 3 + 1] :
              m == "alphanumeric" ? n ÷ 2 * 11 + n % 2 * 6 : n * (m == "kanji" ? 13 : 8)
    return 4 + width + payload
end
segment_bit_length(segment::Segment,version) = bit_length(segment,version)

function _append_bits!(result::Vector{Int}, value::Integer, width::Int)
    for shift in (width - 1):-1:0
        push!(result, Int((value >> shift) & 1))
    end
    return result
end

function bits(segment::Segment, version)
    nbits = bit_length(segment,version)
    !is_control(segment) && count(segment) >= 1 << character_count_bits(version,segment.mode) &&
        throw(DataTooLongError("Input has too many $(segment.mode) units for version $version"))
    nbits <= MAX_SINGLE_SYMBOL_DATA_BITS || throw(DataTooLongError("Segment exceeds the maximum single-symbol bit capacity"))
    result = Int[]
    sizehint!(result,nbits)
    m = segment.mode
    indicator = m == "numeric" ? 1 : m == "alphanumeric" ? 2 : m == "byte" ? 4 :
        m == "kanji" ? 8 : m == "eci" ? 7 : m == "fnc1" ? 5 : m == "fnc1-second" ? 9 : 3
    _append_bits!(result,indicator,4)
    if m == "eci"
        value = segment.assignment_number::Int
        if value < 128
            _append_bits!(result,value,8)
        elseif value < 16384
            _append_bits!(result,2,2)
            _append_bits!(result,value,14)
        else
            _append_bits!(result,6,3)
            _append_bits!(result,value,21)
        end
    elseif m == "fnc1-second"
        _append_bits!(result,application_indicator_codeword(segment)::Int,8)
    elseif m == "structured-append"
        _append_bits!(result,(segment.index::Int) - 1,4)
        _append_bits!(result,(segment.total::Int) - 1,4)
        _append_bits!(result,segment.parity::Int,8)
    elseif !is_control(segment)
        _append_bits!(result,count(segment),character_count_bits(version,m))
        payload = getfield(segment,:_payload)
        if m == "byte"
            for value in codeunits(payload)
                _append_bits!(result,value,8)
            end
        elseif m == "numeric"
            data = codeunits(payload)
            for start in 1:3:length(data)
                chunk_length = min(3,length(data)-start+1)
                value = 0
                for i in start:(start+chunk_length-1)
                    value = 10value + Int(data[i]) - Int('0')
                end
                _append_bits!(result,value,(4,7,10)[chunk_length])
            end
        elseif m == "alphanumeric"
            data = codeunits(payload)
            for start in 1:2:(length(data)-1)
                _append_bits!(result,_alpha_value(Char(data[start]))*45+_alpha_value(Char(data[start+1])),11)
            end
            isodd(length(data)) && _append_bits!(result,_alpha_value(Char(data[end])),6)
        else
            for c in payload
                _append_bits!(result,kanji_value(c),13)
            end
        end
    end
    length(result) == nbits || throw(InvalidInputError("Inconsistent QR segment bit length"))
    return result
end

function validate_control_segments(segments)
    (segments isa AbstractVector || segments isa Tuple) || throw(InvalidInputError("manual segments must be a finite sequence"))
    length(segments) <= MAX_MANUAL_SEGMENTS || throw(DataTooLongError("Manual segments exceed the resource limit"))
    found = Dict(mode => Int[] for mode in _CONTROL_MODES)
    units = 0
    for (index,segment) in enumerate(segments)
        segment isa Segment || throw(InvalidInputError("manual sequence must contain validated Segment values"))
        units += getfield(segment,:_binary) ? ncodeunits(getfield(segment,:_payload)) : character_count(segment)
        units <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Manual payload exceeds the resource limit"))
        is_control(segment) && push!(found[segment.mode],index)
    end
    for mode in ("fnc1","fnc1-second","structured-append")
        positions = found[mode]
        error = mode == "fnc1" ? InvalidGs1Error : InvalidModeError
        length(positions) <= 1 || throw(error("manual segments can include at most one $mode segment"))
        isempty(positions) || positions[1] == 1 || throw(error("manual $mode segment must be the first segment"))
    end
    if count(mode -> !isempty(found[mode]),_CONTROL_MODES) > 1
        error = isempty(found["fnc1"]) ? InvalidModeError : InvalidGs1Error
        throw(error("FNC1, FNC1 second, Structured Append, and ECI cannot be combined in this implementation"))
    end
    return Tuple(segments)
end

function normalize_segments(segments)
    (segments isa AbstractVector || segments isa Tuple) || throw(InvalidInputError("manual segments must be a finite sequence"))
    length(segments) <= MAX_MANUAL_SEGMENTS || throw(DataTooLongError("Manual segments exceed the $MAX_MANUAL_SEGMENTS-segment resource limit"))
    result = Segment[]
    units = 0
    allowed = (:mode,:data,:assignment_number,:application_indicator,:index,:total,:parity,:text,:bytes)
    for (index,item) in enumerate(segments)
        if item isa Segment
            # Revalidation at the public boundary also makes independent ownership
            # explicit, without trusting mutable input arrays or bypass paths.
            units += getfield(item,:_binary) ? ncodeunits(getfield(item,:_payload)) : character_count(item)
            units <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Manual payload exceeds the resource limit"))
            push!(result,Segment(item))
            continue
        end
        item isa AbstractDict || item isa NamedTuple || throw(InvalidInputError("segments[$index] must be a Segment or mapping"))
        values = Dict{Symbol,Any}()
        for (k,v) in pairs(item)
            k isa Symbol || k isa AbstractString || throw(InvalidInputError("segments[$index] has unsupported fields"))
            key = Symbol(k)
            key in allowed && !haskey(values,key) || throw(InvalidInputError("segments[$index] has unsupported or duplicate fields"))
            values[key] = v
        end
        payload_names = [k for k in (:data,:text,:bytes) if haskey(values,k)]
        length(payload_names) <= 1 || throw(InvalidInputError("segments[$index] has ambiguous payload fields"))
        haskey(values,:mode) || throw(InvalidModeError("segments[$index] requires mode"))
        m = _segment_mode(values[:mode])
        if m in _CONTROL_MODES && !isempty(payload_names)
            error = m == "fnc1" ? InvalidGs1Error : InvalidModeError
            throw(error("segments[$index] control segment must not include a payload field"))
        end
        if !isempty(payload_names) && payload_names[1] != :data
            values[:data] = pop!(values,payload_names[1])
        end
        units += _payload_units(get(values,:data,nothing))
        units <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Manual payload exceeds the resource limit"))
        pop!(values,:mode)
        data = pop!(values,:data,nothing)
        push!(result,Segment(m,data;values...))
    end
    return validate_control_segments(result)
end

function segments_bit_length(segments, version)
    validate_version(version)
    (segments isa AbstractVector || segments isa Tuple) || throw(InvalidInputError("segments must be a finite sequence"))
    length(segments) <= MAX_MANUAL_SEGMENTS || throw(DataTooLongError("Manual segments exceed the resource limit"))
    total = 0
    units = 0
    for segment in segments
        segment isa Segment || throw(InvalidInputError("segments must contain Segment values"))
        units += getfield(segment,:_binary) ? ncodeunits(getfield(segment,:_payload)) : character_count(segment)
        units <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Manual payload exceeds the resource limit"))
        total += bit_length(segment,version)
    end
    return total
end

function segments_bits(segments, version)
    normalized = normalize_segments(segments)
    total = segments_bit_length(normalized,version)
    total <= MAX_SINGLE_SYMBOL_DATA_BITS || throw(DataTooLongError("Segments exceed the maximum single-symbol bit capacity"))
    result = Int[]
    sizehint!(result,total)
    for segment in normalized
        append!(result,bits(segment,version))
    end
    return result
end
