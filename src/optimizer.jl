# Exact, bounded linear-time segmentation. The four monotonic queue families
# account for both payload remainders and per-segment character-count limits.
const _OPT_MODES = ("numeric", "alphanumeric", "kanji", "byte")
const _OPT_ALPHA = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ \$%*+-./:"
mutable struct _OptQueue
    values::Vector{Int}
    head::Int
end
mutable struct SegmentOptimizationTracker
    version::Int
    allow_kanji::Bool
    offsets::Vector{Int}
    costs::Vector{Int}
    counts::Vector{Int}
    previous::Vector{Int}
    chosen::Vector{Int}
    queues::Matrix{_OptQueue}
    keys::Vector{Vector{Int}}
    widths::NTuple{4,Int}
end
function SegmentOptimizationTracker(version=1; allow_kanji=true)
    validate_version(version)
    allow_kanji isa Bool || throw(InvalidInputError("allow_kanji must be Bool"))
    queues = [_OptQueue(Int[], 1) for _ in 1:4, _ in 1:3]
    SegmentOptimizationTracker(Int(version), allow_kanji, [0], [0], [0], [0], [0],
        queues, [Int[] for _ in 1:4], ntuple(i -> character_count_bits(version, _OPT_MODES[i]), 4))
end
_opt_utf8_length(c::Char) = Int(c) < 0x80 ? 1 : Int(c) < 0x800 ? 2 : Int(c) < 0x10000 ? 3 : 4
_opt_eligible(c::Char, mode::Int, allow_kanji::Bool) = mode == 4 ||
    (mode == 1 && '0' <= c <= '9') || (mode == 2 && c in _OPT_ALPHA) ||
    (mode == 3 && allow_kanji && can_encode_kanji(c))
_opt_base(t::SegmentOptimizationTracker, m::Int, at::Int) = m == 1 ? 10 * div(at, 3) :
    m == 2 ? 11 * div(at, 2) : m == 3 ? 13 * at : 8 * t.offsets[at + 1]
_opt_count(t::SegmentOptimizationTracker, m::Int, a::Int, b::Int) = m == 4 ?
    t.offsets[b + 1] - t.offsets[a + 1] : b - a
function _opt_payload(t::SegmentOptimizationTracker, m::Int, a::Int, b::Int)
    n = b - a
    m == 1 ? 10 * div(n, 3) + (0, 4, 7)[mod(n, 3) + 1] :
    m == 2 ? 11 * div(n, 2) + 6 * mod(n, 2) :
    m == 3 ? 13 * n : 8 * (t.offsets[b + 1] - t.offsets[a + 1])
end
"""Append one Unicode scalar and return its exact optimal prefix bit length."""
function append_character!(t::SegmentOptimizationTracker, character)
    c = if character isa Char
        character
    elseif character isa AbstractString && isvalid(character) && length(character) == 1
        first(character)
    else
        throw(InvalidInputError("append_character! requires one Unicode scalar"))
    end
    isvalid(c) && !(0xd800 <= Int(c) <= 0xdfff) || throw(InvalidInputError("Text must contain Unicode scalar values"))
    n = length(t.costs)
    n <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Optimizer resource limit exceeded"))
    push!(t.offsets, t.offsets[end] + _opt_utf8_length(c))
    best_cost, best_count, best_mode, best_start = typemax(Int), typemax(Int), 0, 0
    for m in 1:4
        start = n - 1
        key = t.costs[start + 1] - _opt_base(t, m, start)
        push!(t.keys[m], key)
        if !_opt_eligible(c, m, t.allow_kanji)
            for lane in 1:3
                empty!(t.queues[m, lane].values)
                t.queues[m, lane].head = 1
            end
            continue
        end
        lanes = m == 1 ? 3 : m == 2 ? 2 : 1
        q = t.queues[m, mod(start, lanes) + 1]
        while length(q.values) >= q.head
            j = q.values[end]
            if t.keys[m][j + 1] > key || (t.keys[m][j + 1] == key && t.counts[j + 1] > t.counts[start + 1])
                pop!(q.values)
            else
                break
            end
        end
        push!(q.values, start)
        limit = (1 << t.widths[m]) - 1
        for lane in 1:lanes
            q = t.queues[m, lane]
            while q.head <= length(q.values) && _opt_count(t, m, q.values[q.head], n) > limit
                q.head += 1
            end
            q.head > length(q.values) && continue
            j = q.values[q.head]
            cost = t.costs[j + 1] + 4 + t.widths[m] + _opt_payload(t, m, j, n)
            count = t.counts[j + 1] + 1
            if cost < best_cost || (cost == best_cost && count < best_count)
                best_cost, best_count, best_mode, best_start = cost, count, m, j
            end
        end
    end
    best_mode != 0 || throw(InvalidInputError("No valid segmentation path"))
    push!(t.costs, best_cost); push!(t.counts, best_count)
    push!(t.chosen, best_mode); push!(t.previous, best_start)
    best_cost
end
function optimize_segments(text; version=1, allow_kanji=true)
    text isa AbstractString || throw(InvalidInputError("Optimized input must be text"))
    _payload_units(text); _strict_utf8(text)
    length(text) <= MAX_SINGLE_SYMBOL_CHARACTERS || throw(DataTooLongError("Optimized input exceeds 7089 scalars"))
    t = SegmentOptimizationTracker(version; allow_kanji=allow_kanji)
    isempty(text) && return [Segment("byte", "")]
    for c in text
        append_character!(t, c)
    end
    source = String(text)
    result = Segment[]
    n = length(t.costs) - 1
    while n > 0
        j, mode = t.previous[n + 1], t.chosen[n + 1]
        # Offsets are zero-based UTF-8 byte boundaries, not scalar indexes.
        chunk = String(SubString(source, t.offsets[j + 1] + 1, prevind(source, t.offsets[n + 1] + 1)))
        push!(result, Segment(_OPT_MODES[mode], chunk))
        n = j
    end
    reverse!(result)
end
"""Create owned QR data segments. ECI labels bytes and never transcodes text."""
function create_segments(input; mode="auto", version=1, optimize=true, eci=nothing, allow_kanji=true)
    validate_version(version)
    optimize isa Bool || throw(InvalidInputError("optimize must be Bool"))
    allow_kanji isa Bool || throw(InvalidInputError("allow_kanji must be Bool"))
    mode isa AbstractString && mode in ("auto", _OPT_MODES...) || throw(InvalidModeError("Unsupported data mode"))
    assignment = eci === nothing || eci === false ? nothing : eci === true ? 26 : eci
    prefix = assignment === nothing ? Segment[] : [Segment("eci"; assignment_number=assignment)]
    data = if input isa AbstractString
        _payload_units(input); _strict_utf8(input)
        if mode != "auto"
            [Segment(mode, input)]
        elseif optimize
            optimize_segments(input; version=version, allow_kanji=allow_kanji && assignment === nothing)
        else
            selected = !isempty(input) && all(c -> '0' <= c <= '9', input) ? "numeric" :
                !isempty(input) && all(c -> c in _OPT_ALPHA, input) ? "alphanumeric" :
                !isempty(input) && allow_kanji && assignment === nothing && all(can_encode_kanji, input) ? "kanji" : "byte"
            [Segment(selected, input)]
        end
    elseif input isa AbstractVector || input isa Tuple
        mode in ("auto", "byte") || throw(InvalidModeError("Binary input requires byte mode"))
        [Segment("byte", input)]
    else
        throw(InvalidInputError("Input must be text or a finite byte sequence"))
    end
    vcat(prefix, data)
end
