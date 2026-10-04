# Structured Append: canonical UTF-8/raw-byte parity and deterministic 2..16
# equal-version symbols. Text is always split on Unicode scalar boundaries.
struct SAResult
    symbols::Vector{QRResult}
    total::Int
    parity::Int
    input_length::Int
    byte_length::Int
    diagnostics::Dict{String,Any}
end
struct MergeResult
    data::Union{String,Vector{UInt8}}
    total::Int
    parity::Int
    parts::Vector{Dict{String,Any}}
    diagnostics::Dict{String,Any}
end
_sa_xor(values) = foldl((a,b)->xor(a,Int(b)),values;init=0)
function _sa_binary(value)
    value isa Union{AbstractVector,Tuple} || throw(InvalidInputError("Binary input must be a finite byte sequence"))
    length(value) <= MAX_PAYLOAD_UNITS || throw(DataTooLongError("Payload exceeds the resource limit"))
    all(x->x isa Integer && !(x isa Bool) && 0<=x<=255,value) ||
        throw(InvalidInputError("Binary values must be integers from 0 to 255"))
    UInt8[x for x in value]
end
function _sa_text_info(text::AbstractString)
    _payload_units(text)
    encoded = _strict_utf8(text)
    (length(encoded),_sa_xor(encoded))
end
"""XOR original UTF-8 text or raw bytes. This is not an authenticity check."""
calculate_structured_append_parity(input) = input isa AbstractString ? _sa_text_info(input)[2] : _sa_xor(_sa_binary(input))
function _sa_manual(values;unit_budget=MAX_PAYLOAD_UNITS)
    values isa Union{AbstractVector,Tuple} && !isempty(values) || throw(InvalidInputError("Structured Append needs nonempty manual segments"))
    length(values) <= MAX_MANUAL_SEGMENTS || throw(DataTooLongError("Too many manual segments"))
    segments = Segment[normalize_segments(values)...]
    units = 0
    for s in segments
        s.mode == "fnc1" && throw(InvalidGs1Error("Structured Append cannot be combined with FNC1"))
        !s.is_control || throw(InvalidModeError("Structured Append cannot include manual control segments"))
        data = s.data
        isempty(data) && throw(InvalidInputError("Structured Append requires nonempty data segments"))
        units += length(data)
        units <= min(MAX_PAYLOAD_UNITS,unit_budget) || throw(DataTooLongError("Manual payload exceeds Structured Append capacity"))
    end
    segments
end
function calculate_structured_append_segments_parity(segments;kwargs...)
    haskey(kwargs,:gs1) && throw(InvalidGs1Error("Segment parity does not accept GS1 options"))
    isempty(kwargs) || throw(InvalidModeError("Unsupported segment parity option"))
    _sa_xor(_sa_xor(s.logical_bytes) for s in _sa_manual(segments))
end
function _sa_options(base,kwargs,manual)
    d = Dict{Symbol,Any}(pairs(kwargs))
    for forbidden in (:parity,:error_correction,:mask,:encoding)
        haskey(d,forbidden) && throw(InvalidModeError("Unsupported Structured Append option: $forbidden"))
    end
    if manual
        for forbidden in (:mode,:optimize_segments,:allow_kanji)
            haskey(d,forbidden) && throw(InvalidModeError("Manual Structured Append preserves caller modes"))
        end
    end
    maximum = _api_integer(pop!(d,:max_symbols,16),"max_symbols",2,16,InvalidModeError)
    diagnostic = pop!(d,:diagnostics,false)
    detail,symbol_results = "summary","output"
    if diagnostic isa Bool
        symbol_results = diagnostic ? "diagnostics" : "output"
    elseif manual && diagnostic isa Union{AbstractDict,NamedTuple}
        dd = _api_mapping(diagnostic)
        all(k->k in ("split_units","symbol_results"),keys(dd)) || throw(InvalidInputError("Unsupported diagnostics option"))
        detail = get(dd,"split_units","summary")
        symbol_results = get(dd,"symbol_results","diagnostics")
        detail in ("summary","full") && symbol_results in ("output","diagnostics") || throw(InvalidInputError("Invalid Structured Append diagnostic detail"))
    else
        throw(InvalidInputError("diagnostics must be Bool or a manual diagnostics mapping"))
    end
    # False disables optional controls, but integer zero is a real assignment.
    for key in (:structured_append,:fnc1_second)
        get(d,key,nothing) === false && (d[key]=nothing)
    end
    opts = _api_options(base,d)
    opts.gs1 && throw(InvalidGs1Error("Structured Append cannot be combined with gs1"))
    (opts.fnc1 || opts.eci!==nothing || opts.fnc1_second!==nothing || opts.structured_append!==nothing) &&
        throw(InvalidModeError("Structured Append owns its header and cannot include other controls"))
    opts.boost_error_correction && throw(InvalidModeError("Structured Append does not support ECC boosting"))
    manual && (opts.mode!="auto" || !opts.optimize_segments) && throw(InvalidModeError("Manual Structured Append preserves caller modes"))
    opts,maximum,String(detail),String(symbol_results)
end
_sa_capacity(opts,v) = 8*data_codeword_count(v,opts.error_correction_level)
_sa_capacity_version(opts) = opts.version===nothing ? opts.max_version : opts.version
_sa_unit_budget(opts,maximum) = maximum*div(max(0,_sa_capacity(opts,_sa_capacity_version(opts))-20)*3,10)
_sa_numeric_bits(n) = div(n,3)*10+(0,4,7)[mod(n,3)+1]
_sa_payload(mode,n,nb) = mode=="numeric" ? _sa_numeric_bits(n) : mode=="alphanumeric" ? div(n,2)*11+mod(n,2)*6 : mode=="kanji" ? n*13 : nb*8
function _sa_segment_bits(mode,n,nb,v)
    width = character_count_bits(v,mode)
    count = mode=="byte" ? nb : n
    count >= (1<<width) && return typemax(Int)÷4
    4+width+_sa_payload(mode,n,nb)
end
abstract type _SASource end
struct _SAInputSource <: _SASource
    data::Union{String,Vector{UInt8}}
    characters::Vector{Char}
    offsets::Vector{Int}
    binary::Bool
    length::Int
    input_length::Int
    byte_length::Int
    parity::Int
end
function _sa_offsets(text::AbstractString)
    offsets = Int[0]
    sizehint!(offsets,length(text)+1)
    for c in text
        push!(offsets,offsets[end]+_opt_utf8_length(c))
    end
    offsets
end
function _SAInputSource(value,opts,maximum)
    text = value isa AbstractString
    value isa Union{AbstractString,AbstractVector,Tuple} || throw(InvalidInputError("Input must be text or bytes"))
    n = length(value)
    n > 0 || throw(InvalidInputError("Structured Append needs at least two nonempty symbols"))
    n <= MAX_PAYLOAD_UNITS && n <= _sa_unit_budget(opts,maximum) || throw(DataTooLongError("Input exceeds Structured Append capacity"))
    if text
        nb,parity = _sa_text_info(value)
        data = String(value)
        opts.mode != "auto" && Segment(opts.mode,data)
        chars,offsets = collect(data),_sa_offsets(data)
    else
        opts.mode in ("auto","byte") || throw(InvalidModeError("Binary input requires byte mode"))
        data = _sa_binary(value)
        nb,parity = length(data),_sa_xor(data)
        chars,offsets = Char[],Int[]
    end
    mode = text ? opts.mode : "byte"
    v = _sa_capacity_version(opts)
    width = mode=="auto" ? minimum(character_count_bits(v,m) for m in _OPT_MODES) : character_count_bits(v,mode)
    required = mode=="auto" ? _sa_numeric_bits(n) : _sa_payload(mode,n,nb)
    required <= maximum*max(0,_sa_capacity(opts,v)-24-width) || throw(DataTooLongError("Input exceeds Structured Append capacity"))
    _SAInputSource(data,chars,offsets,!text,n,n,nb,parity)
end
function _sa_text_slice(text::String,offsets,start,n)
    n == 0 && return ""
    String(SubString(text,offsets[start+1]+1,prevind(text,offsets[start+n+1]+1)))
end
_sa_slice(s::_SAInputSource,start,n) = s.binary ? copy(s.data[start+1:start+n]) : _sa_text_slice(s.data,s.offsets,start,n)
_sa_byte_length(s::_SAInputSource,start,n) = s.binary ? n : s.offsets[start+n+1]-s.offsets[start+1]
function _sa_bits(s::_SAInputSource,start,n,opts,v)
    capacity = _sa_capacity(opts,v)
    _sa_numeric_bits(n)>capacity-20 && return typemax(Int)÷4
    s.binary && return 20+_sa_segment_bits("byte",n,n,v)
    opts.mode!="auto" && return 20+_sa_segment_bits(opts.mode,n,_sa_byte_length(s,start,n),v)
    if opts.optimize_segments
        tracker = SegmentOptimizationTracker(v;allow_kanji=opts.allow_kanji)
        required = 0
        for i in start+1:start+n
            required = append_character!(tracker,s.characters[i])
            required+20>capacity && break
        end
        return required+20
    end
    segments = create_segments(_sa_slice(s,start,n);mode="auto",version=v,optimize=false,allow_kanji=opts.allow_kanji)
    all(x->x.count<(1<<character_count_bits(v,x.mode)),segments) || return typemax(Int)÷4
    20+segments_bit_length(segments,v)
end
function _sa_chunk(s::_SAInputSource,start,n)
    _sa_slice(s,start,n),Dict{String,Any}("input_start"=>start,"input_length"=>n,
        "byte_start"=>s.binary ? start : s.offsets[start+1],"byte_length"=>_sa_byte_length(s,start,n))
end
struct _SADescriptor
    segment::Segment
    data::Union{String,Vector{UInt8}}
    source_index::Int
    split_start::Int
    split_count::Int
    byte_start::Int
    byte_length::Int
    offsets::Vector{Int}
end
struct _SASegmentSource <: _SASource
    segments::Vector{Segment}
    descriptors::Vector{_SADescriptor}
    length::Int
    input_length::Int
    byte_length::Int
    parity::Int
end
function _SASegmentSource(values,opts,maximum)
    segments = _sa_manual(values;unit_budget=_sa_unit_budget(opts,maximum))
    descriptors = _SADescriptor[]
    n = nb = parity = total_bits = 0
    v = _sa_capacity_version(opts)
    for (i,segment) in enumerate(segments)
        data = segment.data
        len = length(data)
        bytes = segment.logical_bytes
        size = length(bytes)
        split = segment.mode=="byte" ? len : 1
        offsets = data isa String && segment.mode=="byte" ? _sa_offsets(data) : Int[]
        push!(descriptors,_SADescriptor(segment,data,i-1,n,split,nb,size,offsets))
        n += split; nb += size; parity = xor(parity,_sa_xor(bytes))
        total_bits += 4+character_count_bits(v,segment.mode)+_sa_payload(segment.mode,len,size)
    end
    total_bits <= maximum*max(0,_sa_capacity(opts,v)-20) || throw(DataTooLongError("Segments exceed Structured Append capacity"))
    _SASegmentSource(segments,descriptors,n,length(segments),nb,parity)
end
function _sa_ranges(s::_SASegmentSource,start,n)
    result = Tuple{_SADescriptor,Int,Int}[]
    finish = start+n
    for d in s.descriptors
        d.split_start+d.split_count<=start && continue
        d.split_start>=finish && break
        overlap = max(start,d.split_start)
        push!(result,(d,overlap-d.split_start,min(finish,d.split_start+d.split_count)-overlap))
    end
    result
end
function _sa_range_bytes(d::_SADescriptor,start,n)
    d.segment.mode!="byte" && return d.byte_start,d.byte_length
    d.data isa String && return d.byte_start+d.offsets[start+1],d.offsets[start+n+1]-d.offsets[start+1]
    d.byte_start+start,n
end
function _sa_bits(s::_SASegmentSource,start,n,opts,v)
    result = 20
    for (d,local_start,local_n) in _sa_ranges(s,start,n)
        _,nb = _sa_range_bytes(d,local_start,local_n)
        len = d.segment.mode=="byte" ? local_n : length(d.data)
        result += _sa_segment_bits(d.segment.mode,len,nb,v)
        result > _sa_capacity(opts,v) && break
    end
    result
end
function _sa_chunk(s::_SASegmentSource,start,n)
    result = Segment[]
    first_index = last_index = byte_start = nothing
    byte_length = 0
    for (d,local_start,local_n) in _sa_ranges(s,start,n)
        offset,size = _sa_range_bytes(d,local_start,local_n)
        if first_index===nothing
            first_index,byte_start = d.source_index,offset
        end
        last_index = d.source_index+1
        byte_length += size
        if d.segment.mode=="byte"
            data = d.data isa String ? _sa_text_slice(d.data,d.offsets,local_start,local_n) : copy(d.data[local_start+1:local_start+local_n])
            push!(result,Segment("byte",data))
        else
            push!(result,d.segment)
        end
    end
    result,Dict{String,Any}("source_segment_start"=>first_index,"source_segment_end"=>last_index,
        "split_unit_start"=>start,"split_unit_length"=>n,"byte_start"=>byte_start,"byte_length"=>byte_length)
end
function _sa_full_detail(s::_SASegmentSource)
    result = Dict{String,Any}[]
    for d in s.descriptors, unit in 0:d.split_count-1
        byte_start,byte_length = _sa_range_bytes(d,unit,1)
        push!(result,Dict{String,Any}("source_segment_index"=>d.source_index,"mode"=>d.segment.mode,
            "unit_start"=>d.segment.mode=="byte" ? unit : 0,"unit_length"=>d.segment.mode=="byte" ? 1 : length(d.data),
            "byte_start"=>byte_start,"byte_length"=>byte_length))
    end
    result
end
function _sa_largest_prefix(source,start,maximum,opts,v)
    if source isa _SAInputSource && !source.binary && opts.mode=="auto" && opts.optimize_segments
        tracker = SegmentOptimizationTracker(v;allow_kanji=opts.allow_kanji)
        capacity = _sa_capacity(opts,v)-20
        for i in 1:maximum
            append_character!(tracker,source.characters[start+i])>capacity && return i-1
        end
        return maximum
    end
    low,high,best = 1,maximum,0
    capacity = _sa_capacity(opts,v)
    while low<=high
        n = (low+high)÷2
        if _sa_bits(source,start,n,opts,v)<=capacity
            best,low = n,n+1
        else
            high = n-1
        end
    end
    best
end
function _sa_attempt(source,opts,v,maximum)
    _sa_bits(source,0,source.length,opts,v)<=_sa_capacity(opts,v) && return :single,Tuple{Int,Int}[]
    ranges = Tuple{Int,Int}[]
    start = 0
    while start<source.length
        length(ranges)==maximum && return :too_long,Tuple{Int,Int}[]
        n = _sa_largest_prefix(source,start,source.length-start-(isempty(ranges) ? 1 : 0),opts,v)
        n>0 || return :too_long,Tuple{Int,Int}[]
        push!(ranges,(start,n)); start+=n
    end
    length(ranges)>=2 ? (:ok,ranges) : (:single,Tuple{Int,Int}[])
end
function _sa_select(source,opts,maximum)
    versions = opts.version===nothing ? (opts.min_version:opts.max_version) : (opts.version:opts.version)
    saw_too_long = false
    for v in versions
        status,ranges = _sa_attempt(source,opts,v,maximum)
        status===:ok && return v,ranges,opts.version===nothing ? "auto-minimum" : "fixed"
        saw_too_long |= status===:too_long
    end
    saw_too_long && throw(DataTooLongError("Input cannot be split into $maximum or fewer symbols in the selected version range"))
    throw(InvalidInputError("Input fits in one symbol; use generate or a low-level Structured Append header"))
end
function _sa_generate(source,opts,maximum,detail,symbol_results,manual)
    v,ranges,selection = _sa_select(source,opts,maximum)
    total = length(ranges)
    symbols = QRResult[]
    detail_symbols = Dict{String,Any}[]
    for (index,(start,n)) in enumerate(ranges)
        chunk,offsets = _sa_chunk(source,start,n)
        header = Segment("structured-append";index=index,total=total,parity=source.parity)
        selected = _api_options(opts,(version=v,min_version=v,max_version=v,structured_append=header))
        result = manual ? generate_segments(chunk,selected) : generate(chunk,selected)
        push!(symbols,result)
        required = result.diagnostics["data_bit_length"]
        d = Dict{String,Any}("index"=>index,"total"=>total,"parity"=>source.parity,
            "sequence_index"=>index-1,"sequence_total"=>total-1,"sequence_indicator"=>((index-1)<<4)|(total-1),
            "version"=>v,"error_correction_level"=>result.error_correction_level,"data_bit_length"=>required,
            "capacity_bits"=>_sa_capacity(opts,v),"remaining_bits"=>_sa_capacity(opts,v)-required,"mask_pattern"=>result.mask_pattern)
        merge!(d,offsets); push!(detail_symbols,d)
    end
    warnings = Dict{String,Any}[]
    if total==maximum
        push!(warnings,Dict{String,Any}("code"=>"STRUCTURED_APPEND_MAX_SYMBOLS_NEAR_LIMIT","severity"=>"info",
            "message"=>"The set uses the configured maximum number of symbols.","details"=>Dict("total"=>total,"max_symbols"=>maximum)))
    end
    if symbol_results=="diagnostics"
        push!(warnings,Dict{String,Any}("code"=>"STRUCTURED_APPEND_DECODER_SUPPORT_VARIES","severity"=>"info",
            "message"=>"Decoder APIs vary in how they expose Structured Append metadata.","details"=>Dict("total"=>total)))
    end
    summary = Dict{String,Any}("version"=>v,"error_correction_level"=>opts.error_correction_level,
        "version_selection"=>selection,"version_selection_reason"=>selection=="fixed" ? "Version $v was requested explicitly." :
            "Version $v is the smallest version in $(opts.min_version)..$(opts.max_version) that can split the payload into $total symbols.",
        "total"=>total,"parity"=>source.parity,"byte_length"=>source.byte_length,"input_length"=>source.input_length,
        "max_symbols"=>maximum,"split_strategy"=>manual ? "segment-boundary-byte-chunk" : "greedy-largest-fitting",
        "symbols"=>detail_symbols,"warnings"=>warnings)
    if manual
        summary["segment_count"]=length(source.segments); summary["split_unit_count"]=source.length
        summary["split_units_detail"]=detail
        detail=="full" && (summary["split_units"]=_sa_full_detail(source))
    end
    SAResult(symbols,total,source.parity,source.input_length,source.byte_length,summary)
end
function generate_structured_append(input,options=nothing;kwargs...)
    opts,maximum,detail,symbol_results = _sa_options(options,kwargs,false)
    _sa_generate(_SAInputSource(input,opts,maximum),opts,maximum,detail,symbol_results,false)
end
function generate_segments_structured_append(segments,options=nothing;kwargs...)
    opts,maximum,detail,symbol_results = _sa_options(options,kwargs,true)
    _sa_generate(_SASegmentSource(segments,opts,maximum),opts,maximum,detail,symbol_results,true)
end
"""Validate, sort, checksum and merge a complete decoded Structured Append set."""
function merge_structured_append_parts(parts;kwargs...)
    isempty(kwargs) || throw(InvalidModeError("Unsupported merge option"))
    parts isa Union{AbstractVector,Tuple} && 1<=length(parts)<=16 || throw(InvalidInputError("parts must contain 1..16 decoded mappings"))
    ordered = Dict{Int,Tuple{Any,Dict{String,Any}}}()
    total = parity = kind = nothing
    nb = actual = units = 0
    for part in parts
        d = _api_mapping(part)
        index = _api_integer(get(d,"index",nothing),"index",1,16)
        t = _api_integer(get(d,"total",nothing),"total",2,16)
        p = _api_integer(get(d,"parity",nothing),"parity",0,255)
        index<=t || throw(InvalidInputError("Index exceeds total"))
        total!==nothing && t!=total && throw(InvalidInputError("Structured Append total mismatch"))
        parity!==nothing && p!=parity && throw(InvalidInputError("Structured Append parity mismatch"))
        haskey(ordered,index) && throw(InvalidInputError("Duplicate Structured Append index $index"))
        data = get(d,"data",nothing)
        data isa Union{AbstractString,AbstractVector,Tuple} || throw(InvalidInputError("Part data must be text or bytes"))
        units += length(data)
        units<=MAX_PAYLOAD_UNITS || throw(DataTooLongError("Merged input exceeds the resource limit"))
        if data isa AbstractString
            typ = "string"; size,checksum = _sa_text_info(data); data=String(data)
        else
            typ = "binary"; data=_sa_binary(data); size,checksum=length(data),_sa_xor(data)
        end
        kind!==nothing && kind!=typ && throw(InvalidInputError("Parts must not mix text and binary data"))
        total,parity,kind = t,p,typ
        nb+=size; actual=xor(actual,checksum)
        ordered[index]=(data,Dict{String,Any}("index"=>index,"total"=>total,"parity"=>parity,"data_type"=>kind,"byte_length"=>size))
    end
    missing = [i for i in 1:total if !haskey(ordered,i)]
    isempty(missing) || throw(InvalidInputError("Missing Structured Append indexes: $(join(missing,", "))"))
    length(parts)==total || throw(InvalidInputError("Part count does not match total"))
    actual==parity || throw(InvalidInputError("Structured Append parity check failed"))
    sorted = [ordered[i] for i in 1:total]
    merged = kind=="string" ? join(x[1] for x in sorted) : reduce(vcat,(x[1] for x in sorted);init=UInt8[])
    d = Dict{String,Any}("part_count"=>total,"total"=>total,"parity"=>parity,"data_type"=>kind,
        "byte_length"=>nb,"missing"=>Int[],"duplicate"=>Int[],"parity_check"=>Dict("expected"=>parity,"actual"=>actual,"matches"=>true))
    MergeResult(merged,total,parity,[x[2] for x in sorted],d)
end
diagnostics(result::Union{SAResult,MergeResult}) = deepcopy(result.diagnostics)

generate_structured_append(segments::AbstractVector{Segment},options=nothing;kwargs...) = generate_segments_structured_append(segments,options;kwargs...)
