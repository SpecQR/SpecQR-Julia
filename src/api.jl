# Public native Julia planning, encoding and diagnostics. Planning is arithmetic:
# it never constructs codewords, runs Reed–Solomon, or evaluates masks.
function _api_integer(value, name, low, high, error=InvalidInputError)
    value isa Integer && !(value isa Bool) && low <= value <= high ||
        throw(error("$name must be an integer from $low to $high"))
    Int(value)
end
_api_dict(v::NamedTuple) = Dict{String,Any}(String(k) => x for (k,x) in pairs(v))
_api_dict(v::AbstractDict) = Dict{String,Any}(String(k) => x for (k,x) in pairs(v) if k isa Union{String,Symbol})
function _api_mapping(v)
    v isa Union{NamedTuple,AbstractDict} || throw(InvalidInputError("Expected a mapping"))
    all(k -> k isa Union{String,Symbol}, keys(v)) || throw(InvalidInputError("Mapping keys must be strings or symbols"))
    d = _api_dict(v)
    length(d) == length(v) || throw(InvalidInputError("Ambiguous duplicate mapping keys"))
    d
end
struct Options
    error_correction_level::String
    version::Union{Nothing,Int}
    min_version::Int
    max_version::Int
    mask_pattern::Union{Nothing,Int}
    mode::String
    optimize_segments::Bool
    allow_kanji::Bool
    boost_error_correction::Bool
    eci::Union{Nothing,Int}
    gs1::Bool
    fnc1::Bool
    fnc1_second::Union{Nothing,String}
    structured_append::Union{Nothing,Segment}
    margin::Int
    scale::Int
    foreground::String
    background::String
    print_dpi::Union{Nothing,Float64}
    function Options(; error_correction_level="M", version=nothing, min_version=1, max_version=40,
        mask_pattern=nothing, mode="auto", optimize_segments=true, allow_kanji=true,
        boost_error_correction=false, eci=nothing, gs1=false, fnc1=false,
        fnc1_second=nothing, structured_append=nothing, margin=4, scale=8,
        foreground="#000000", background="#ffffff", print_dpi=nothing, kwargs...)
        isempty(kwargs) || throw(InvalidInputError("Unknown option: $(first(keys(kwargs)))"))
        validate_level(error_correction_level)
        lo = _api_integer(min_version,"min_version",1,40,InvalidVersionError)
        hi = _api_integer(max_version,"max_version",1,40,InvalidVersionError)
        lo <= hi || throw(InvalidVersionError("min_version must not exceed max_version"))
        v = version === nothing ? nothing : _api_integer(version,"version",1,40,InvalidVersionError)
        mask = mask_pattern === nothing ? nothing : _api_integer(mask_pattern,"mask_pattern",0,7)
        mode isa AbstractString && mode in ("auto", _OPT_MODES...) || throw(InvalidModeError("Unsupported data mode"))
        for (label, value) in (("optimize_segments",optimize_segments),("allow_kanji",allow_kanji),
            ("boost_error_correction",boost_error_correction),("gs1",gs1),("fnc1",fnc1))
            value isa Bool || throw(InvalidInputError("$label must be Bool"))
        end
        assignment = eci === nothing || eci === false ? nothing : eci === true ? 26 :
            _api_integer(eci,"eci",0,999999,InvalidEciError)
        if fnc1_second !== nothing
            Segment("fnc1-second"; application_indicator=fnc1_second)
        end
        sa = structured_append
        if sa isa Union{NamedTuple,AbstractDict}
            d = _api_mapping(sa)
            Set(keys(d)) == Set(("index","total","parity")) || throw(InvalidModeError("structured_append requires index, total and parity"))
            sa = Segment("structured-append"; index=d["index"],total=d["total"],parity=d["parity"])
        end
        if sa !== nothing && (!(sa isa Segment) || sa.mode != "structured-append")
            throw(InvalidModeError("structured_append must be a Structured Append header"))
        end
        sum((gs1 || fnc1,fnc1_second !== nothing,assignment !== nothing,sa !== nothing)) <= 1 ||
            throw(InvalidModeError("FNC1, ECI, and Structured Append cannot be combined"))
        m = _api_integer(margin,"margin",0,MAX_GEOMETRY_INTEGER)
        s = _api_integer(scale,"scale",1,MAX_GEOMETRY_INTEGER)
        for (label,value) in (("foreground",foreground),("background",background))
            value isa AbstractString && isvalid(value) && ncodeunits(value) <= div(SVG_CHARACTER_BUDGET,12) ||
                throw(InvalidInputError("$label must be a bounded valid color string"))
            parse_color(value; strict=false)
        end
        dpi = nothing
        if print_dpi !== nothing
            print_dpi isa Real && !(print_dpi isa Bool) || throw(InvalidInputError("print_dpi must be a positive finite number"))
            dpi = try Float64(print_dpi) catch; throw(InvalidInputError("print_dpi is out of range")); end
            isfinite(dpi) && dpi > 0 && isfinite((177.0 + 2.0*m)*(s/dpi*25.4)) ||
                throw(InvalidInputError("print_dpi must produce finite print geometry"))
        end
        new(String(error_correction_level),v,lo,hi,mask,String(mode),optimize_segments,allow_kanji,
            boost_error_correction,assignment,gs1,fnc1,fnc1_second === nothing ? nothing : String(fnc1_second),
            sa,m,s,String(foreground),String(background),dpi)
    end
end
function _api_options(options, kwargs)
    options === nothing && return Options(; kwargs...)
    options isa Options || throw(InvalidInputError("options must be Options or nothing"))
    isempty(kwargs) && return options
    values = Dict{Symbol,Any}(name => getfield(options,name) for name in fieldnames(Options))
    merge!(values, Dict{Symbol,Any}(pairs(kwargs)))
    Options(; values...)
end
struct Capacity
    version::Int
    error_correction_level::String
    size::Int
    data_codewords::Int
    total_codewords::Int
    capacity_bits::Int
    mode::Union{Nothing,String}
    character_count_bits::Union{Nothing,Int}
    mode_indicator_bits::Union{Nothing,Int}
    control_bits::Int
    payload_bits::Union{Nothing,Int}
    max_characters::Union{Nothing,Int}
    max_bytes::Union{Nothing,Int}
end
function Base.getproperty(c::Capacity, name::Symbol)
    name === :maximum && return getfield(c,:mode) == "byte" ? getfield(c,:max_bytes) : getfield(c,:max_characters)
    getfield(c,name)
end
function get_capacity(version,error_correction_level="M"; mode=nothing,control_bits=0)
    v = _api_integer(version,"version",1,40,InvalidVersionError)
    validate_level(error_correction_level)
    control = _api_integer(control_bits,"control_bits",0,2^53-1)
    data = data_codeword_count(v,error_correction_level)
    width = payload = maximum = nothing
    if mode !== nothing
        mode isa AbstractString && mode in _OPT_MODES || throw(InvalidModeError("Capacity requires a data mode"))
        width = character_count_bits(v,mode)
        payload = max(0,8*data-control-4-width)
        maximum = mode == "numeric" ? div(payload,10)*3 + (mod(payload,10)>=7 ? 2 : mod(payload,10)>=4 ? 1 : 0) :
            mode == "alphanumeric" ? div(payload,11)*2 + Int(mod(payload,11)>=6) : div(payload,mode == "byte" ? 8 : 13)
        maximum = min(maximum,(1<<width)-1)
    end
    Capacity(v,String(error_correction_level),qr_size(v),data,raw_codeword_count(v),8*data,
        mode === nothing ? nothing : String(mode),width,mode === nothing ? nothing : 4,control,payload,
        mode == "byte" ? nothing : maximum,mode == "byte" ? maximum : nothing)
end
struct Plan
    ok::Bool
    version::Union{Nothing,Int}
    capacity_version::Int
    error_correction_level::String
    requested_error_correction_level::String
    boosted_error_correction::Bool
    data_bit_length::Int
    capacity_bits::Int
    remaining_bits::Int
    segments::Vector{Segment}
    diagnostics::Dict{String,Any}
end
function Base.getproperty(p::Plan, name::Symbol)
    name === :selected_version && return getfield(p,:version)
    name === :overflow_bits && return max(0,-getfield(p,:remaining_bits))
    name === :capacity_utilization && return getfield(p,:data_bit_length)/getfield(p,:capacity_bits)
    name === :warnings && return getfield(p,:diagnostics)["warnings"]
    getfield(p,name)
end
struct QRResult
    matrix::Matrix{Bool}
    version::Int
    mask_pattern::Int
    error_correction_level::String
    data_codewords::Vector{UInt8}
    codewords::Vector{UInt8}
    segments::Vector{Segment}
    diagnostics::Dict{String,Any}
    options::Options
end
function Base.getproperty(q::QRResult,name::Symbol)
    name === :error_correction_codewords && return getfield(q,:codewords)[length(getfield(q,:data_codewords))+1:end]
    name === :size && return size(getfield(q,:matrix),1)
    getfield(q,name)
end
function _api_controls(segments,opts::Options)
    prefix = opts.eci !== nothing ? [Segment("eci";assignment_number=opts.eci)] :
        opts.gs1 || opts.fnc1 ? [Segment("fnc1")] :
        opts.fnc1_second !== nothing ? [Segment("fnc1-second";application_indicator=opts.fnc1_second)] :
        opts.structured_append !== nothing ? [opts.structured_append] : Segment[]
    normalize_segments(Segment[prefix...;segments...])
end
_api_segment_diagnostic(s,v) = Dict{String,Any}("mode"=>s.mode,"character_count"=>s.character_count,
    "byte_count"=>s.byte_count,"count"=>s.count,"bit_length"=>bit_length(s,v))
function _api_diagnostics(segments,v,level,required,opts;planning,ok)
    capacity = 8*data_codeword_count(v,level)
    controls = filter(s->s.is_control,segments)
    modes = unique([s.mode for s in segments if !s.is_control])
    mode = isempty(modes) ? "byte" : length(modes)==1 ? only(modes) : "mixed"
    warnings = Dict{String,Any}[]
    warn(code,severity,message;details...) = push!(warnings,Dict{String,Any}("code"=>code,"severity"=>severity,
        "message"=>message,"details"=>Dict{String,Any}(String(k)=>val for (k,val) in details)))
    opts.margin < 4 && warn("QUIET_ZONE_TOO_SMALL","warning","QR readers expect at least four quiet-zone modules.";margin=opts.margin)
    fg,bg = parse_color(opts.foreground;strict=false),parse_color(opts.background;strict=false)
    ratio = fg === nothing || bg === nothing ? nothing : contrast_ratio(fg,bg)
    if ratio === nothing
        warn("COLOR_CONTRAST_UNKNOWN","info","These SVG colors cannot be checked for contrast.")
    elseif ratio < 4.5
        warn("COLOR_CONTRAST_LOW","warning","Color contrast is below the recommended minimum.";ratio=ratio)
    elseif ratio < 7
        warn("COLOR_CONTRAST_MODERATE","info","Stronger color contrast is recommended.";ratio=ratio)
    end
    fg !== nothing && bg !== nothing && (fg[4]<255 || bg[4]<255) &&
        warn("COLOR_ALPHA_USED","warning","Transparent colors can reduce scan reliability.")
    0 <= capacity-required < capacity*0.05 && warn("CAPACITY_NEAR_LIMIT","info","The selected version is close to full capacity.")
    mm = opts.print_dpi === nothing ? nothing : opts.scale/opts.print_dpi*25.4
    mm !== nothing && mm<0.25 && warn("PRINT_MODULE_TOO_SMALL","warning","Print modules are smaller than 0.25 mm.";module_size_mm=mm)
    blocking = [w["code"] for w in warnings if w["severity"] == "warning"]
    !isempty(blocking) && warn("SCAN_RISK","warning","One or more settings may reduce scan reliability.";blocking_warnings=blocking)
    sa = findfirst(s->s.mode=="structured-append",controls)
    second = findfirst(s->s.mode=="fnc1-second",controls)
    ec = findfirst(s->s.mode=="eci",controls)
    sa = sa === nothing ? nothing : controls[sa]
    second = second === nothing ? nothing : controls[second]
    fn = any(s->s.mode=="fnc1",controls) ? "first-position" : second === nothing ? nothing : "second-position"
    selection = opts.version !== nothing ? "fixed" : ok ? "auto-minimum" : "auto-range"
    reason = opts.version !== nothing ? "Version $v was requested explicitly." : ok ?
        "Version $v is the smallest version in $(opts.min_version)..$(opts.max_version) that fits." :
        "No version in $(opts.min_version)..$(opts.max_version) fits; capacity is for version $v."
    Dict{String,Any}("phase"=>planning ? "planning" : "generation","render_planned"=>false,
        "mask_evaluated"=>!planning,"codewords_built"=>!planning,"ok"=>ok,
        "version"=>(ok || opts.version !== nothing) ? v : nothing,"capacity_version"=>v,
        "size"=>(ok || opts.version !== nothing) ? qr_size(v) : nothing,
        "error_correction_level"=>level,"requested_error_correction_level"=>opts.error_correction_level,
        "boosted_error_correction"=>level != opts.error_correction_level,"version_selection"=>selection,
        "version_selection_reason"=>reason,"mode"=>mode,
        "control_segments"=>[_api_segment_diagnostic(s,v) for s in controls],
        "eci_assignment_number"=>ec === nothing ? nothing : controls[ec].assignment_number,
        "fnc1"=>fn,"gs1"=>fn=="first-position",
        "gs1_validation"=>Dict{String,Any}("enabled"=>false,"element_count"=>0,"ais"=>String[],"has_separators"=>false),
        "fnc1_second"=>Dict{String,Any}("enabled"=>second!==nothing,
            "application_indicator"=>second===nothing ? nothing : second.application_indicator,
            "application_indicator_codeword"=>second===nothing ? nothing : second.application_indicator_codeword),
        "structured_append"=>Dict{String,Any}("enabled"=>sa!==nothing,"index"=>sa===nothing ? nothing : sa.index,
            "total"=>sa===nothing ? nothing : sa.total,"parity"=>sa===nothing ? nothing : sa.parity,
            "sequence_index"=>sa===nothing ? nothing : sa.index-1,"sequence_total"=>sa===nothing ? nothing : sa.total-1,
            "sequence_indicator"=>sa===nothing ? nothing : ((sa.index-1)<<4)|(sa.total-1)),
        "segments"=>[_api_segment_diagnostic(s,v) for s in segments],"data_bit_length"=>required,
        "capacity_bits"=>capacity,"remaining_bits"=>capacity-required,"overflow_bits"=>max(0,required-capacity),
        "capacity_utilization"=>required/capacity,"input_bytes"=>sum(s->length(s.logical_bytes),segments;init=0),
        "quiet_zone"=>Dict("modules"=>opts.margin,"recommended_modules"=>4,"is_sufficient"=>opts.margin>=4),
        "colors"=>Dict{String,Any}("ratio"=>ratio,"is_inspectable"=>ratio!==nothing,"foreground_alpha"=>fg===nothing ? nothing : fg[4],
            "background_alpha"=>bg===nothing ? nothing : bg[4],"is_strong"=>ratio!==nothing && ratio>=7,
            "is_sufficient"=>ratio!==nothing && ratio>=4.5 && fg[4]==bg[4]==255),
        "print"=>Dict{String,Any}("dpi"=>opts.print_dpi,"module_pixels"=>opts.scale,"module_size_mm"=>mm,
            "symbol_size_mm"=>mm===nothing ? nothing : (qr_size(v)+2*opts.margin)*mm,
            "recommended_minimum_module_size_mm"=>0.25,"is_module_size_sufficient"=>mm===nothing ? nothing : mm>=0.25),
        "warnings"=>warnings)
end
function _api_select(factory,opts;gs1_validation=nothing)
    versions = opts.version === nothing ? (opts.min_version:opts.max_version) : (opts.version:opts.version)
    cache = Dict{Int,Tuple{Vector{Segment},Int,Bool}}()
    segments, required, ok, v = Segment[],0,false,last(versions)
    for candidate in versions
        group = candidate <= 9 ? 1 : candidate <= 26 ? 2 : 3
        segments,required,counts_fit = get!(cache,group) do
            found = Segment[factory(candidate)...]
            counts = all(s -> s.is_control || s.count < (1 << character_count_bits(candidate,s.mode)),found)
            (found,segments_bit_length(found,candidate),counts)
        end
        v = candidate
        ok = counts_fit && required <= 8*data_codeword_count(v,opts.error_correction_level)
        ok && break
    end
    level = opts.error_correction_level
    if ok && opts.boost_error_correction
        levels = ("L","M","Q","H")
        for stronger in levels[findfirst(==(level),levels):end]
            required <= 8*data_codeword_count(v,stronger) && (level=stronger)
        end
    end
    capacity = 8*data_codeword_count(v,level)
    d = _api_diagnostics(segments,v,level,required,opts;planning=true,ok=ok)
    gs1_validation !== nothing && (d["gs1_validation"]=gs1_validation)
    Plan(ok,ok || opts.version!==nothing ? v : nothing,v,level,opts.error_correction_level,
        level!=opts.error_correction_level,required,capacity,capacity-required,segments,d)
end
function _api_input_plan(value,opts)
    validation = nothing
    if opts.gs1
        value isa AbstractString || throw(InvalidGs1Error("High-level GS1 requires text"))
        parsed = parse_gs1_element_string(value)
        validation = Dict{String,Any}("enabled"=>true,"element_count"=>length(parsed.elements),
            "ais"=>[e.ai for e in parsed.elements],"has_separators"=>occursin('\x1d',value))
    end
    mode = opts.mode
    if (opts.gs1 || opts.fnc1 || opts.fnc1_second!==nothing) && value isa AbstractString && occursin('%',value)
        mode == "alphanumeric" && throw(InvalidModeError("Literal percent in high-level FNC1 requires byte mode; use escaped manual segments"))
        mode == "auto" && (mode="byte")
    end
    factory = function(version)
        optimize = opts.optimize_segments && !(value isa AbstractString && length(value)>MAX_SINGLE_SYMBOL_CHARACTERS)
        data = create_segments(value;mode=mode,version=version,optimize=optimize,
            allow_kanji=opts.allow_kanji && opts.eci===nothing)
        _api_controls(data,opts)
    end
    _api_select(factory,opts;gs1_validation=validation)
end
"""Estimate capacity and segmentation without building a QR matrix."""
estimate(value,options=nothing;kwargs...) = _api_input_plan(value,_api_options(options,kwargs))
plan(value,options=nothing;kwargs...) = estimate(value,options;kwargs...)
function analyze_segments(segments,options=nothing;kwargs...)
    opts = _api_options(options,kwargs)
    opts.gs1 && throw(InvalidGs1Error("Manual GS1 data requires an explicit FNC1 segment"))
    found = _api_controls(normalize_segments(segments),opts)
    _api_select(_->found,opts)
end
plan_segments(segments,options=nothing;kwargs...) = analyze_segments(segments,options;kwargs...)
function _api_build(p::Plan,opts::Options)
    p.ok || throw(DataTooLongError("Input requires $(p.data_bit_length) bits; version $(p.capacity_version)-$(p.error_correction_level) holds $(p.capacity_bits)"))
    v,level = p.capacity_version,p.error_correction_level
    payload = Int[]
    sizehint!(payload,p.data_bit_length)
    for s in p.segments
        append!(payload,bits(s,v))
    end
    data = pad_data_bits(payload,v,level)
    interleaved = interleave_codewords(data,v,level)
    built = build_matrix(interleaved.codewords,v,level,opts.mask_pattern)
    d = _api_diagnostics(p.segments,v,level,p.data_bit_length,opts;planning=false,ok=true)
    d["gs1_validation"] = deepcopy(p.diagnostics["gs1_validation"])
    merge!(d,Dict{String,Any}("mask_pattern"=>built.mask_pattern,"mask_penalty"=>built.penalty,
        "mask_penalties"=>[Dict("mask_pattern"=>x.mask_pattern,"penalty"=>x.penalty) for x in built.mask_penalties],
        "mask_selection_reason"=>opts.mask_pattern===nothing ? "Lowest penalty; first mask wins ties." : "Explicit mask requested.",
        "data_codewords"=>length(data),"error_correction_codewords"=>length(interleaved.codewords)-length(data),
        "total_codewords"=>length(interleaved.codewords)))
    QRResult(Matrix{Bool}(built.matrix),v,built.mask_pattern,level,copy(data),copy(interleaved.codewords),copy(p.segments),d,opts)
end
function generate(value,options=nothing;kwargs...)
    opts = _api_options(options,kwargs)
    _api_build(_api_input_plan(value,opts),opts)
end
function generate_segments(segments,options=nothing;kwargs...)
    opts = _api_options(options,kwargs)
    _api_build(analyze_segments(segments,opts),opts)
end
diagnostics(result::Union{Plan,QRResult}) = deepcopy(result.diagnostics)
function module_at(result::QRResult,x,y)
    # Coordinates follow normal Julia indexing (row y, column x), starting at 1.
    xx = _api_integer(x,"x",1,size(result.matrix,2)); yy = _api_integer(y,"y",1,size(result.matrix,1))
    result.matrix[yy,xx]
end
function _api_render_options(q::QRResult,kwargs)
    opts = Dict{Symbol,Any}(name=>getfield(q.options,name) for name in (:margin,:scale,:foreground,:background))
    merge!(opts,Dict{Symbol,Any}(pairs(kwargs)))
end
to_svg(q::QRResult;kwargs...) = to_svg(q.matrix;_api_render_options(q,kwargs)...)
to_png(q::QRResult;kwargs...) = to_png(q.matrix;_api_render_options(q,kwargs)...)
to_pixels(q::QRResult;kwargs...) = to_pixels(q.matrix;_api_render_options(q,kwargs)...)
to_svg_data_url(q::QRResult;kwargs...) = to_data_url(q.matrix;format="svg",_api_render_options(q,kwargs)...)
to_png_data_url(q::QRResult;kwargs...) = to_data_url(q.matrix;format="png",_api_render_options(q,kwargs)...)
function render(q::QRResult,output="svg";kwargs...)
    output == "matrix" && (isempty(kwargs) || throw(InvalidInputError("Matrix output does not use render options")); return copy(q.matrix))
    output == "svg" && return to_svg(q;kwargs...)
    output == "png" && return to_png(q;kwargs...)
    output == "pixels" && return to_pixels(q;kwargs...)
    output == "svg-data-url" && return to_svg_data_url(q;kwargs...)
    output == "png-data-url" && return to_png_data_url(q;kwargs...)
    throw(InvalidOutputError("Unsupported output format"))
end

generate(segments::AbstractVector{Segment},options=nothing;kwargs...) = generate_segments(segments,options;kwargs...)
estimate(segments::AbstractVector{Segment},options=nothing;kwargs...) = analyze_segments(segments,options;kwargs...)
plan(segments::AbstractVector{Segment},options=nothing;kwargs...) = analyze_segments(segments,options;kwargs...)

Base.propertynames(::Capacity,private::Bool=false) = (fieldnames(Capacity)...,:maximum)
Base.propertynames(::Plan,private::Bool=false) = (fieldnames(Plan)...,:selected_version,:overflow_bits,:capacity_utilization,:warnings)
Base.propertynames(::QRResult,private::Bool=false) = (fieldnames(QRResult)...,:error_correction_codewords,:size)
