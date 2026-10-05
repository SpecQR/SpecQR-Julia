# Bounded GS1 catalog and strict, offline Digital Link adapter.
const GS1_FNC1_SEPARATOR = "\x1d"
const GS1_MAX_INPUT_CHARACTERS = 1_000_000
const GS1_MAX_ELEMENTS = 16_384
const _GS1_PRIMARY = ("00", "01", "414")

_gs1_fail(message, code="GS1_INVALID_INPUT") = throw(InvalidGs1Error(String(message), String(code)))
function _gs1_text(value, label="GS1 text")
    value isa AbstractString || _gs1_fail("$label must be a string")
    ncodeunits(value) <= 4GS1_MAX_INPUT_CHARACTERS && isvalid(value) || _gs1_fail("$label must be valid UTF-8 within the input budget")
    units = 0
    for c in value
        units += UInt32(c) > 0xffff ? 2 : 1
        units <= GS1_MAX_INPUT_CHARACTERS || _gs1_fail("$label exceeds the character work budget")
    end
    String(value)
end
_gs1_digits(s) = s isa AbstractString && !isempty(s) && all(c -> '0' <= c <= '9', s)
_gs1_is_ai(s) = s isa AbstractString && 2 <= ncodeunits(s) <= 4 && _gs1_digits(s)
_gs1_eligible(ai, primary) = primary == "01" && ai in ("10","21","22")

struct GS1Element
    ai::String
    value::String
    GS1Element(ai,value) = new(_gs1_text(ai,"GS1 AI"),_gs1_text(value,"GS1 value"))
end
Base.:(==)(a::GS1Element,b::GS1Element) = a.ai == b.ai && a.value == b.value
Base.hash(e::GS1Element,h::UInt) = hash((e.ai,e.value),h)

struct GS1AiLength
    type::String
    exact::Union{Nothing,Int}
    min::Union{Nothing,Int}
    max::Union{Nothing,Int}
end
Base.getproperty(l::GS1AiLength,s::Symbol) = s === :is_variable ? getfield(l,:type) == "variable" : getfield(l,s)
struct GS1AiInfo
    ai::String
    label::String
    length::GS1AiLength
    value_kind::String
    check_digit_rule::String
    digital_link_role::String
    separator::String
    digital_link_path_for_primary::Union{Nothing,Tuple{String}}
end
struct GS1ElementStringParseResult
    elements::Vector{GS1Element}
    has_separators::Bool
end
Base.@kwdef struct GS1ValidationIssue
    code::String
    message::String
    reason::Union{Nothing,String} = nothing
    ai::Union{Nothing,String} = nothing
    value::Union{Nothing,String} = nothing
    key::Union{Nothing,String} = nothing
    offset::Union{Nothing,Int} = nothing
    element_index::Union{Nothing,Int} = nothing
    expected::Union{Nothing,String,Bool} = nothing
    count::Union{Nothing,Int} = nothing
end
Base.@kwdef struct GS1ValidationResult
    ok::Bool
    elements::Union{Nothing,Vector{GS1Element}} = nothing
    has_separators::Union{Nothing,Bool} = nothing
    errors::Vector{GS1ValidationIssue} = GS1ValidationIssue[]
    warnings::Vector{GS1ValidationIssue} = GS1ValidationIssue[]
end
struct GS1UnknownQuery
    key::String
    value::String
end
struct GS1DigitalLinkParseResult
    elements::Vector{GS1Element}
    primary::GS1Element
    path_elements::Vector{GS1Element}
    query_elements::Vector{GS1Element}
    unknown_query::Vector{GS1UnknownQuery}
end
Base.@kwdef struct GS1DigitalLinkValidationResult
    ok::Bool
    result::Union{Nothing,GS1DigitalLinkParseResult} = nothing
    errors::Vector{GS1ValidationIssue} = GS1ValidationIssue[]
    warnings::Vector{GS1ValidationIssue} = GS1ValidationIssue[]
end

function _gs1_catalog()
    out = GS1AiInfo[]
    function add(ai,label,n; variable=false,kind="numeric",check="none",role="data-attribute")
        len = variable ? GS1AiLength("variable",nothing,1,n) : GS1AiLength("fixed",n,nothing,nothing)
        push!(out,GS1AiInfo(ai,label,len,kind,check,role,variable ? "required-when-followed" : "none", role == "key-qualifier" ? ("01",) : nothing))
    end
    add("00","Serial shipping container code",18;check="sscc",role="primary-key")
    add("01","Global trade item number",14;check="gtin",role="primary-key")
    add("02","Contained trade item GTIN",14;check="gtin")
    add("10","Batch or lot number",20;variable=true,kind="text",role="key-qualifier")
    for (ai,label) in (("11","Production date"),("12","Due date"),("13","Packaging date"),("15","Best before date"),("16","Sell by date"),("17","Expiration date"))
        add(ai,label,6)
    end
    add("20","Internal product variant",2)
    add("21","Serial number",20;variable=true,kind="text",role="key-qualifier")
    add("22","Consumer product variant",20;variable=true,kind="text",role="key-qualifier")
    add("30","Variable count",8;variable=true)
    add("37","Count of contained trade items",8;variable=true)
    for (ai,label) in (("240","Additional product identification"),("241","Customer part number"),("400","Customer purchase order number"))
        add(ai,label,30;variable=true,kind="text")
    end
    for (ai,label) in (("410","Ship to global location number"),("411","Bill to global location number"),("412","Purchased from global location number"),("413","Ship for global location number"),("414","Identification of a physical location"),("415","Global location number of the invoicing party"))
        add(ai,label,13;role=ai == "414" ? "primary-key" : "data-attribute")
    end
    add("420","Ship to postal code",20;variable=true,kind="text")
    for (ai,label) in (("422","Country of origin"),("424","Country of processing"),("425","Country of disassembly"),("426","Country covering full process chain"))
        add(ai,label,3)
    end
    for (start,label) in ((3100,"Net weight in kilograms"),(3200,"Net weight in pounds")), n in start:start+5
        add(string(n),label,6)
    end
    for n in 91:99
        add(string(n),"Company internal information",90;variable=true,kind="text")
    end
    Tuple(out)
end
const _GS1_CATALOG = _gs1_catalog()
const _GS1_AI_INFO = Dict(e.ai=>e for e in _GS1_CATALOG)
get_supported_gs1_ais() = _GS1_CATALOG
get_gs1_ai_info(ai) = ai isa AbstractString ? get(_GS1_AI_INFO,ai,nothing) : nothing

function _gs1_numeric(value,label)
    s = _gs1_text(value,label)
    _gs1_digits(s) || _gs1_fail("$label must contain digits only","GS1_INVALID_CHARSET")
    s
end
function calculate_gs1_check_digit(value)
    s = _gs1_numeric(value,"GS1 check digit input")
    total, weight = 0, 3
    for c in Iterators.reverse(codeunits(s))
        total = (total + (Int(c)-48)*weight) % 10; weight = 4-weight
    end
    string(mod(-total,10))
end
function validate_gs1_check_digit(value)
    s = _gs1_numeric(value,"GS1 check digit value")
    length(s) >= 2 || _gs1_fail("GS1 check digit value must include body and check digit","GS1_INVALID_LENGTH")
    calculate_gs1_check_digit(s[1:end-1]) == s[end:end]
end
function calculate_gtin_check_digit(value)
    s = _gs1_numeric(value,"GTIN body")
    length(s) in (7,11,12,13) || _gs1_fail("GTIN body must be 7, 11, 12, or 13 digits","GS1_INVALID_LENGTH")
    calculate_gs1_check_digit(s)
end
append_gtin_check_digit(value) = _gs1_text(value,"GTIN body") * calculate_gtin_check_digit(value)
function validate_gtin_check_digit(value)
    s = _gs1_numeric(value,"GTIN")
    length(s) in (8,12,13,14) || _gs1_fail("GTIN must be 8, 12, 13, or 14 digits","GS1_INVALID_LENGTH")
    validate_gs1_check_digit(s)
end
function calculate_sscc_check_digit(value)
    s = _gs1_numeric(value,"SSCC body")
    length(s) == 17 || _gs1_fail("SSCC body must be exactly 17 digits","GS1_INVALID_LENGTH")
    calculate_gs1_check_digit(s)
end
append_sscc_check_digit(value) = _gs1_text(value,"SSCC body") * calculate_sscc_check_digit(value)
function validate_sscc_check_digit(value)
    s = _gs1_numeric(value,"SSCC")
    length(s) == 18 || _gs1_fail("SSCC must be exactly 18 digits","GS1_INVALID_LENGTH")
    validate_gs1_check_digit(s)
end

function _gs1_fields(element)
    element isa GS1Element && return (element.ai,element.value)
    if element isa NamedTuple
        return (get(element,:ai,nothing),get(element,:value,nothing))
    elseif element isa AbstractDict
        return (get(element,"ai",get(element,:ai,nothing)),get(element,"value",get(element,:value,nothing)))
    elseif element isa Pair
        return (first(element),last(element))
    end
    _gs1_fail("GS1 elements must have string ai and value fields")
end
function _gs1_bounded(values; path_ais=false)
    values isa GS1ElementStringParseResult && (values = values.elements)
    (values isa AbstractString || values isa AbstractDict || !applicable(iterate,values)) &&
        _gs1_fail("GS1 elements must be an iterable of elements")
    out = Any[]; work = 0
    for value in values
        length(out) < GS1_MAX_ELEMENTS || _gs1_fail("GS1 element count exceeds limit")
        fields = path_ais ? (value,) : value isa GS1Element || value isa NamedTuple || value isa AbstractDict || value isa Pair ? _gs1_fields(value) : ()
        for field in fields
            if field isa AbstractString
                ncodeunits(field) <= GS1_MAX_INPUT_CHARACTERS-work || _gs1_fail("GS1 aggregate text exceeds input budget")
                work += ncodeunits(field)
            end
        end
        push!(out,value)
    end
    out
end
function _gs1_element(raw,index=0)
    ai,value = _gs1_fields(raw)
    ai = _gs1_text(ai,"GS1 element $index AI"); value = _gs1_text(value,"GS1 element $index value")
    _gs1_is_ai(ai) || _gs1_fail("GS1 element $index AI must be a 2 to 4 digit string")
    info = get_gs1_ai_info(ai)
    info === nothing && _gs1_fail("Unsupported GS1 AI $ai","GS1_UNSUPPORTED_AI")
    prefix = "GS1 AI $ai value"
    isempty(value) && _gs1_fail("$prefix must not be empty","GS1_INVALID_LENGTH")
    occursin(GS1_FNC1_SEPARATOR,value) && _gs1_fail("$prefix must not contain the FNC1 separator","GS1_UNEXPECTED_SEPARATOR")
    (occursin('(',value) || occursin(')',value)) && _gs1_fail("$prefix must be raw data without human-readable parentheses")
    all(c -> ' ' <= c <= '~', value) || _gs1_fail("$prefix must use printable ASCII characters","GS1_INVALID_CHARSET")
    info.value_kind == "numeric" && !_gs1_digits(value) && _gs1_fail("$prefix must contain digits only","GS1_INVALID_CHARSET")
    if info.length.is_variable
        length(value) <= info.length.max || _gs1_fail("$prefix must be at most $(info.length.max) characters","GS1_INVALID_LENGTH")
    else
        length(value) == info.length.exact || _gs1_fail("$prefix must be exactly $(info.length.exact) characters","GS1_INVALID_LENGTH")
    end
    info.check_digit_rule == "gtin" && !validate_gtin_check_digit(value) && _gs1_fail("$prefix has an invalid GTIN check digit","GS1_INVALID_CHECK_DIGIT")
    info.check_digit_rule == "sscc" && !validate_sscc_check_digit(value) && _gs1_fail("$prefix has an invalid SSCC check digit","GS1_INVALID_CHECK_DIGIT")
    GS1Element(ai,value)
end
function _gs1_elements(values)
    bounded = _gs1_bounded(values)
    isempty(bounded) && _gs1_fail("GS1 elements must not be empty")
    [_gs1_element(value,index-1) for (index,value) in enumerate(bounded)]
end
function _gs1_push!(elements,e)
    length(elements) < GS1_MAX_ELEMENTS || _gs1_fail("GS1 element count exceeds limit")
    push!(elements,e)
end
function _gs1_ascii_input(value,label)
    s = _gs1_text(value,label)
    isascii(s) || _gs1_fail("$label must use ASCII characters","GS1_INVALID_CHARSET")
    isempty(s) && _gs1_fail("$label must not be empty")
    s
end
function parse_gs1_human_readable(value)
    s = _gs1_ascii_input(value,"GS1 human-readable input")
    out = GS1Element[]; p = 1
    while p <= lastindex(s)
        s[p] == '(' || _gs1_fail("GS1 AI must be parenthesized at offset $(p-1)")
        q = findnext(')',s,p+1)
        q === nothing && _gs1_fail("GS1 AI is missing closing parenthesis at offset $(p-1)")
        stop = findnext('(',s,q+1); stop === nothing && (stop=ncodeunits(s)+1)
        _gs1_push!(out,_gs1_element(GS1Element(s[p+1:q-1],s[q+1:stop-1]),length(out)))
        p = stop
    end
    out
end
function _gs1_read_ai(s,p)
    for n in (4,3,2)
        p+n-1 <= ncodeunits(s) || continue
        info = get_gs1_ai_info(s[p:p+n-1])
        info === nothing || return info
    end
    nothing
end
function parse_gs1_element_string(value)
    s = _gs1_ascii_input(value,"GS1 element string")
    (occursin('(',s) || occursin(')',s)) && _gs1_fail("GS1 element string must be raw data without parentheses")
    out = GS1Element[]; p = 1; n = ncodeunits(s)
    while p <= n
        s[p] == '\x1d' && _gs1_fail("Unexpected FNC1 separator at offset $(p-1)","GS1_UNEXPECTED_SEPARATOR")
        info = _gs1_read_ai(s,p)
        info === nothing && _gs1_fail("Unsupported GS1 AI at offset $(p-1)","GS1_UNSUPPORTED_AI")
        start = p+ncodeunits(info.ai)
        stop = info.length.is_variable ? findnext('\x1d',s,start) : min(n+1,start+info.length.exact)
        stop === nothing && (stop=n+1)
        if info.length.is_variable && stop == n+1
            for off in max(start+1,stop-22):stop-1
                tail = _gs1_read_ai(s,off)
                if tail !== nothing && !tail.length.is_variable && off+length(tail.ai)+tail.length.exact == stop
                    _gs1_fail("GS1 variable field is missing an FNC1 separator before offset $(off-1)","GS1_MISSING_SEPARATOR")
                end
            end
        end
        _gs1_push!(out,_gs1_element(GS1Element(info.ai,s[start:stop-1]),length(out)))
        p = stop
        if info.length.is_variable && p <= n
            p += 1
            p <= n || _gs1_fail("GS1 element string must not end with an FNC1 separator","GS1_UNEXPECTED_SEPARATOR")
        end
    end
    GS1ElementStringParseResult(out,occursin(GS1_FNC1_SEPARATOR,s))
end
function create_gs1_element_string(elements)
    values = _gs1_elements(elements); out=IOBuffer()
    for (i,e) in enumerate(values)
        print(out,e.ai,e.value)
        i < length(values) && get_gs1_ai_info(e.ai).length.is_variable && print(out,GS1_FNC1_SEPARATOR)
        position(out) <= GS1_MAX_INPUT_CHARACTERS || _gs1_fail("GS1 output exceeds character budget")
    end
    String(take!(out))
end
function gs1_to_human_readable(elements)
    values = _gs1_elements(elements)
    out = join("("*e.ai*")"*e.value for e in values)
    _gs1_text(out,"GS1 output")
end
normalize_gs1_elements(value::AbstractString) = startswith(value,"(") ? parse_gs1_human_readable(value) : parse_gs1_element_string(value).elements
normalize_gs1_elements(value) = _gs1_elements(value)
gs1_element_string_to_human_readable(value) = gs1_to_human_readable(parse_gs1_element_string(value).elements)

function _gs1_issue(error; element=nothing,element_index=nothing)
    code = error.detail_code
    reasons = Dict("GS1_UNSUPPORTED_AI"=>"unsupported-ai","GS1_INVALID_LENGTH"=>"invalid-length","GS1_INVALID_CHARSET"=>"invalid-charset",
        "GS1_MISSING_SEPARATOR"=>"missing-separator","GS1_UNEXPECTED_SEPARATOR"=>"unexpected-separator","GS1_INVALID_CHECK_DIGIT"=>"invalid-check-digit",
        "GS1_INVALID_PERCENT_ENCODING"=>"invalid-percent-encoding","GS1_INVALID_DIGITAL_LINK_PLACEMENT"=>"invalid-digital-link-placement",
        "GS1_DUPLICATE_AI"=>"duplicate-ai","GS1_DIGITAL_LINK_UNKNOWN_QUERY"=>"unknown-query","GS1_DIGITAL_LINK_UNSUPPORTED_HOST"=>"unsupported-host",
        "GS1_DIGITAL_LINK_INVALID_URI"=>"invalid-uri","GS1_DIGITAL_LINK_FRAGMENT_NOT_ALLOWED"=>"fragment-not-allowed")
    ai = nothing; value = nothing
    if element isa GS1Element || element isa NamedTuple || element isa AbstractDict || element isa Pair
        rawai,rawval = _gs1_fields(element)
        ai = rawai isa AbstractString && ncodeunits(rawai) <= 4 && isvalid(rawai) ? String(rawai) : nothing
        value = rawval isa AbstractString && ncodeunits(rawval) <= 90 && isvalid(rawval) ? String(rawval) : nothing
    end
    if ai === nothing
        found=match(r"GS1 AI ([0-9]{2,4})",error.message)
        found === nothing || (ai=String(found.captures[1]))
    end
    off = match(r"offset ([0-9]+)",error.message)
    expected = code == "GS1_DIGITAL_LINK_UNSUPPORTED_HOST" ? "ASCII URL host or RFC IPv6; Unicode/IDNA hosts are unsupported" : nothing
    GS1ValidationIssue(code=code,message=error.message,reason=get(reasons,code,"invalid-input"),ai=ai,value=value,element_index=element_index,
        offset=off === nothing ? nothing : parse(Int,off.captures[1]),expected=expected)
end
function _gs1_validation_options(context,collect_all_errors,allow_unsupported_ai)
    context isa AbstractString && context in ("element-string","digital-link") || _gs1_fail("GS1 validation context must be element-string or digital-link")
    collect_all_errors isa Bool || _gs1_fail("GS1 validation collect_all_errors must be a boolean")
    allow_unsupported_ai === false || _gs1_fail("GS1 validation allow_unsupported_ai must be false")
end
function validate_gs1_elements(elements; context="element-string",collect_all_errors=true,allow_unsupported_ai=false)
    errors=GS1ValidationIssue[]; normalized=GS1Element[]
    try
        _gs1_validation_options(context,collect_all_errors,allow_unsupported_ai)
        values=_gs1_bounded(elements)
        isempty(values) && _gs1_fail("GS1 elements must not be empty")
        for (i,e) in enumerate(values)
            try
                push!(normalized,_gs1_element(e,i-1))
            catch err
                err isa InvalidGs1Error || rethrow()
                push!(errors,_gs1_issue(err;element=e,element_index=i-1))
                collect_all_errors || break
            end
        end
        isempty(errors) || return GS1ValidationResult(ok=false,errors=errors)
        context == "digital-link" && !any(e -> e.ai in _GS1_PRIMARY,normalized) &&
            _gs1_fail("GS1 Digital Link requires primary AI 00, 01, or 414","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
        GS1ValidationResult(ok=true,elements=normalized)
    catch err
        err isa InvalidGs1Error || rethrow()
        GS1ValidationResult(ok=false,errors=[_gs1_issue(err)])
    end
end
function validate_gs1_element_string(value; context="element-string",collect_all_errors=true,allow_unsupported_ai=false)
    try
        _gs1_validation_options(context,collect_all_errors,allow_unsupported_ai)
        parsed=parse_gs1_element_string(value)
        checked=validate_gs1_elements(parsed.elements;context=context,collect_all_errors=collect_all_errors,allow_unsupported_ai=allow_unsupported_ai)
        GS1ValidationResult(ok=checked.ok,elements=checked.elements,has_separators=parsed.has_separators,errors=checked.errors,warnings=checked.warnings)
    catch err
        err isa InvalidGs1Error || rethrow()
        GS1ValidationResult(ok=false,errors=[_gs1_issue(err)])
    end
end

# Offline HTTP(S) lexical/authority compatibility. Malformed percent/UTF-8 and
# raw GS1 dot-path payloads stay strict; this is not a complete UTS46 implementation.
_gs1_percent_fail() = _gs1_fail("GS1 URI must use valid percent-encoding and UTF-8","GS1_INVALID_PERCENT_ENCODING")
_gs1_hex(b) = UInt8('0') <= b <= UInt8('9') ? Int(b)-48 : UInt8('a') <= b <= UInt8('f') ? Int(b)-87 : UInt8('A') <= b <= UInt8('F') ? Int(b)-55 : -1
function _gs1_decode(value; form=false)
    bytes=codeunits(value); out=IOBuffer(sizehint=length(bytes)); i=1
    while i <= length(bytes)
        b=bytes[i]
        if b == UInt8('%')
            i+2 <= length(bytes) || _gs1_percent_fail()
            a,c=_gs1_hex(bytes[i+1]),_gs1_hex(bytes[i+2])
            a >= 0 && c >= 0 || _gs1_percent_fail()
            write(out,UInt8(16a+c)); i+=3
        else
            write(out,form && b == UInt8('+') ? UInt8(' ') : b); i+=1
        end
    end
    text=String(take!(out)); isvalid(text) || _gs1_percent_fail()
    text
end
function _gs1_encode(value; form=false)
    out=IOBuffer(sizehint=3ncodeunits(value))
    for b in codeunits(value)
        safe = UInt8('a') <= b <= UInt8('z') || UInt8('A') <= b <= UInt8('Z') || UInt8('0') <= b <= UInt8('9') || b in codeunits("*-._")
        !form && (safe |= b in codeunits("~!'()"))
        if safe
            write(out,b)
        elseif form && b == UInt8(' ')
            write(out,UInt8('+'))
        else
            print(out,'%',uppercase(string(b;base=16,pad=2)))
        end
    end
    String(take!(out))
end
function _gs1_split(value, separator, limit)
    count(==(separator),value) < limit || _gs1_fail("GS1 URL component count exceeds limit")
    String.(split(value,separator;keepempty=true))
end
function _gs1_query_pair(value)
    parts=split(value,'=';limit=2,keepempty=true)
    GS1UnknownQuery(_gs1_decode(parts[1];form=true),length(parts)==1 ? "" : _gs1_decode(parts[2];form=true))
end
function _gs1_ipv4(value)
    parts=split(value,'.';keepempty=true)
    length(parts)==4 || return false
    for part in parts
        1 <= ncodeunits(part) <= 3 && _gs1_digits(part) || return false
        ncodeunits(part)>1 && startswith(part,"0") && return false
        parse(Int,part) <= 255 || return false
    end
    true
end
function _gs1_ipv6_side(value;allow_ipv4=false)
    isempty(value) && return 0
    parts=split(value,':';keepempty=true); n=0
    for (i,part) in enumerate(parts)
        isempty(part) && return nothing
        if occursin('.',part)
            allow_ipv4 && i==length(parts) && _gs1_ipv4(part) || return nothing
            n+=2
        else
            ncodeunits(part)<=4 && all(b -> _gs1_hex(b)>=0,codeunits(part)) || return nothing
            n+=1
        end
    end
    n
end
function _gs1_ipv6(value)
    pair=split(value,"::";keepempty=true)
    if length(pair)==1
        n=_gs1_ipv6_side(pair[1];allow_ipv4=true)
        return n !== nothing && n==8
    elseif length(pair)==2
        a=_gs1_ipv6_side(pair[1]); b=_gs1_ipv6_side(pair[2];allow_ipv4=true)
        return a !== nothing && b !== nothing && a+b<8
    end
    false
end
_gs1_host_fail() = _gs1_fail("Unsupported host profile; use an ASCII URL host or RFC IPv6","GS1_DIGITAL_LINK_UNSUPPORTED_HOST")
function _gs1_ipv4_number(value)
    isempty(value) && return -1
    radix=10
    if startswith(lowercase(value),"0x")
        radix=16; value=value[3:end]
    elseif ncodeunits(value)>=2 && startswith(value,"0")
        radix=8; value=value[2:end]
    end
    number=0
    for byte in codeunits(value)
        digit=_gs1_hex(byte)
        0 <= digit < radix || return -1
        # Bounded accumulation: never overflow, even for very long input.
        if number < 0x100000000
            number=number > div(0xffffffff-digit,radix) ? 0x100000000 : number*radix+digit
        end
    end
    number
end
function _gs1_normalize_ipv4(host)
    parts=split(host,'.';keepempty=true)
    length(parts)>1 && isempty(last(parts)) && pop!(parts)
    tail=last(parts)
    !_gs1_digits(tail) && _gs1_ipv4_number(tail)<0 && return host
    length(parts)<=4 || _gs1_host_fail()
    numbers=[_gs1_ipv4_number(p) for p in parts]
    all(n -> 0 <= n <= 0xffffffff,numbers) || _gs1_host_fail()
    all(n -> n<=255,numbers[1:end-1]) || _gs1_host_fail()
    last(numbers) < (Int64(1) << (8*(5-length(numbers)))) || _gs1_host_fail()
    address=last(numbers)
    for i in 1:length(numbers)-1
        address+=numbers[i] << (8*(4-i))
    end
    join(((address >> n)&255 for n in (24,16,8,0)),'.')
end
function _gs1_ipv6_groups(side)
    groups=Int[]
    isempty(side) && return groups
    for part in split(side,':')
        if occursin('.',part)
            bytes=parse.(Int,split(part,'.'))
            push!(groups,(bytes[1]<<8)|bytes[2],(bytes[3]<<8)|bytes[4])
        else
            push!(groups,parse(Int,part;base=16))
        end
    end
    groups
end
function _gs1_normalize_ipv6(address)
    sides=split(address,"::";keepempty=true); groups=_gs1_ipv6_groups(sides[1])
    if length(sides)==2
        right=_gs1_ipv6_groups(sides[2]); append!(groups,zeros(Int,8-length(groups)-length(right)));append!(groups,right)
    end
    best_start,best_size,at=0,1,1
    while at<=8
        if groups[at]!=0;at+=1;continue;end
        start=at
        while at<=8 && groups[at]==0;at+=1;end
        if at-start>best_size;best_start=start;best_size=at-start;end
    end
    pieces=[string(g;base=16) for g in groups]
    best_start==0 && return join(pieces,':')
    join(pieces[1:best_start-1],':')*"::"*join(pieces[best_start+best_size:end],':')
end
function _gs1_url_encode(value;userinfo=false)
    out=IOBuffer()
    for c in value
        escaped=c<=' ' || c>='\x7f' || c in (userinfo ? "\"#/:;<=>?@[\\]^`{|}" : "\"#<>?^`{}")
        if escaped
            for byte in codeunits(string(c));print(out,'%',uppercase(string(byte;base=16,pad=2)));end
        else
            print(out,c)
        end
    end
    String(take!(out))
end
function _gs1_authority(value,scheme)
    1 <= ncodeunits(value) <= 1024 || _gs1_host_fail()
    userinfo=""; at=findlast('@',value)
    if at!==nothing
        raw=value[1:prevind(value,at)];_gs1_decode(raw)
        pair=split(raw,':';limit=2,keepempty=true)
        username=_gs1_url_encode(pair[1];userinfo=true)
        password=length(pair)==1 ? "" : _gs1_url_encode(pair[2];userinfo=true)
        if !isempty(username) || !isempty(password)
            userinfo=username*(isempty(password) ? "" : ":"*password)*"@"
        end
        value=value[nextind(value,at):end]
    end
    host="";port=nothing
    if startswith(value,"[")
        close=findfirst(']',value);close===nothing && _gs1_host_fail()
        address=value[2:prevind(value,close)];_gs1_ipv6(address) || _gs1_host_fail()
        host="["*_gs1_normalize_ipv6(address)*"]"
        tail=value[close+1:end]
        if !isempty(tail)
            startswith(tail,":") || _gs1_host_fail();port=tail[2:end]
        end
    else
        parts=split(value,':';limit=2,keepempty=true)
        host=_gs1_decode(parts[1]);length(parts)==2 && (port=parts[2])
        # Julia Base/Base64 have no UTS46/IDNA service. Do not implement partial IDNA.
        !isempty(host) && all(c -> ' ' < c < '\x7f' && !(c in "#%/:<>?@[\\]^|"),host) || _gs1_host_fail()
        host=_gs1_normalize_ipv4(lowercase(host))
    end
    if port!==nothing && !isempty(port)
        _gs1_digits(port) || _gs1_fail("GS1 port must contain decimal digits from 0 to 65535","GS1_DIGITAL_LINK_INVALID_URI")
        number=0
        for c in port
            number=number*10+Int(c)-48
            number<=65535 || _gs1_fail("GS1 port must be from 0 to 65535","GS1_DIGITAL_LINK_INVALID_URI")
        end
        if !((scheme=="http" && number==80) || (scheme=="https" && number==443));host*=":"*string(number);end
    end
    userinfo*host
end
struct _GS1Url
    scheme::String
    authority::String
    path::String
    query::Union{Nothing,String}
    empty_fragment::Bool
end
_gs1_base(url::_GS1Url) = url.scheme*"://"*url.authority
function _gs1_url(value)
    s=_gs1_text(value,"GS1 Digital Link URI")
    occursin('\0',s) && _gs1_fail("GS1 URI must not contain raw NUL","GS1_DIGITAL_LINK_INVALID_URI")
    s=replace(strip(c->c<=' ',s),'\t'=>"",'\n'=>"",'\r'=>"")
    fragment=findfirst('#',s);empty_fragment=fragment!==nothing
    if empty_fragment
        fragment==lastindex(s) || _gs1_fail("GS1 Digital Link URI must not include a fragment","GS1_DIGITAL_LINK_FRAGMENT_NOT_ALLOWED")
        s=s[1:prevind(s,fragment)]
    end
    # A literal query backslash is data; only authority/path backslashes repair.
    parts=split(s,'?';limit=2,keepempty=true)
    head=replace(parts[1],'\\'=>'/');query=length(parts)==1 ? nothing : String(parts[2])
    found=match(r"(?i)^(https?):/*([^/]*)(.*)$",head)
    found===nothing && _gs1_fail("GS1 URI must be an absolute http or https URL","GS1_DIGITAL_LINK_INVALID_URI")
    scheme=lowercase(found.captures[1]);authority=_gs1_authority(found.captures[2],scheme)
    path=_gs1_url_encode(found.captures[3])
    for part in _gs1_split(path,'/',2GS1_MAX_ELEMENTS+1);_gs1_decode(part);end
    if query!==nothing
        for pair in _gs1_split(query,'&',GS1_MAX_ELEMENTS);_gs1_query_pair(pair);end
    end
    _GS1Url(scheme,authority,path,query,empty_fragment)
end
function _gs1_primary(ai)
    ai isa AbstractString && ai in _GS1_PRIMARY || _gs1_fail("GS1 primary_ai must be one of 00, 01, or 414")
    String(ai)
end
function _gs1_policy(policy)
    policy isa AbstractString && policy in ("preserve","reject") || _gs1_fail("GS1 unknown_query must be preserve or reject")
    policy
end
function _gs1_placement(ai,primary)
    get_gs1_ai_info(ai) === nothing && _gs1_fail("Unsupported GS1 AI $ai","GS1_UNSUPPORTED_AI")
    _gs1_eligible(ai,primary) || _gs1_fail("GS1 AI $ai cannot be placed in the Digital Link path after primary AI $primary","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
end
function _gs1_unique!(seen,ai)
    ai in seen && _gs1_fail("GS1 Digital Link must not contain duplicate AI $ai","GS1_DUPLICATE_AI")
    push!(seen,ai)
end
function _gs1_prefix(parts)
    stack=String[]
    for part in parts
        decoded=_gs1_decode(part)
        decoded in ("", ".") && continue
        if decoded == ".."
            isempty(stack) || pop!(stack)
        else
            push!(stack,part)
        end
    end
    isempty(stack) ? "" : "/"*join(stack,'/')
end
function _gs1_path_parts(path)
    value=strip(path,'/')
    isempty(value) && _gs1_fail("GS1 Digital Link path must include primary AI 00, 01, or 414","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    parts=_gs1_split(value,'/',2GS1_MAX_ELEMENTS+1)
    any(isempty,parts) && _gs1_fail("GS1 Digital Link path must not contain empty segments")
    parts
end
function _gs1_first_ai(parts,primary_ai)
    start=findfirst(p -> primary_ai === nothing ? p in _GS1_PRIMARY : p==primary_ai,parts)
    start === nothing && _gs1_fail("GS1 Digital Link path must include primary AI 00, 01, or 414","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    start
end

"""Build a Digital Link using the strict offline URL profile; dot-only qualifiers stay in query."""
function create_gs1_digital_link(elements; base_url=nothing,primary_ai="01",path_ais=nothing)
    primary=_gs1_primary(primary_ai)
    base_url === nothing && _gs1_fail("GS1 Digital Link base_url is required")
    base=_gs1_url(base_url)
    (base.query === nothing || isempty(base.query)) || _gs1_fail("GS1 Digital Link base_url must not include query components")
    paths=nothing
    if path_ais !== nothing
        paths=Set{String}()
        for ai in _gs1_bounded(path_ais;path_ais=true)
            _gs1_is_ai(ai) || _gs1_fail("GS1 path_ais entries must be 2 to 4 digit AI strings")
            if ai != primary
                _gs1_placement(ai,primary); push!(paths,String(ai))
            end
        end
    end
    normalized=_gs1_elements(elements); seen=Set{String}()
    for e in normalized
        _gs1_unique!(seen,e.ai)
    end
    selected=findfirst(e -> e.ai==primary,normalized)
    selected === nothing && _gs1_fail("GS1 input must include primary AI $primary","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    path=GS1Element[normalized[selected]]; query=GS1Element[]
    for (i,e) in enumerate(normalized)
        i==selected && continue
        inpath=paths === nothing ? _gs1_eligible(e.ai,primary) : e.ai in paths
        if inpath && !(e.value in (".",".."))
            _gs1_placement(e.ai,primary); push!(path,e)
        else
            push!(query,e)
        end
    end
    sort!(query;by=e -> (e.ai,e.value))
    prefix=_gs1_prefix(_gs1_split(base.path,'/',2GS1_MAX_ELEMENTS+1))
    for part in _gs1_split(prefix,'/',2GS1_MAX_ELEMENTS+1)
        _gs1_decode(part) in _GS1_PRIMARY && _gs1_fail("GS1 base URL normalized path must not contain a primary AI component (00, 01, or 414), including percent-encoded equivalents","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    end
    out=IOBuffer(); print(out,_gs1_base(base),prefix)
    for e in path
        print(out,'/',_gs1_encode(e.ai),'/',_gs1_encode(e.value))
    end
    for (i,e) in enumerate(query)
        print(out,i==1 ? '?' : '&',_gs1_encode(e.ai;form=true),'=',_gs1_encode(e.value;form=true))
    end
    base.empty_fragment && print(out,'#')
    _gs1_text(String(take!(out)),"GS1 Digital Link output")
end
function _gs1_parse_link(url,primary_ai,unknown_query)
    primary_ai === nothing || _gs1_primary(primary_ai)
    _gs1_policy(unknown_query)
    parts=_gs1_path_parts(url.path); start=_gs1_first_ai(parts,primary_ai)
    for i in start:length(parts)
        _gs1_decode(parts[i]) in (".","..") && _gs1_fail("GS1 Digital Link path values must not be dot segments; place these values in the query","GS1_INVALID_DIGITAL_LINK_PLACEMENT")
    end
    iseven(length(parts)-start+1) || _gs1_fail("GS1 Digital Link path must contain AI/value pairs")
    path=GS1Element[]; query=GS1Element[]; unknown=GS1UnknownQuery[]; seen=Set{String}()
    for i in start:2:length(parts)
        ai=parts[i]
        _gs1_is_ai(ai) || _gs1_fail("GS1 Digital Link path segment $i must be a GS1 AI")
        e=_gs1_element(GS1Element(ai,_gs1_decode(parts[i+1])),length(path))
        isempty(path) || _gs1_placement(ai,path[1].ai)
        _gs1_unique!(seen,ai); _gs1_push!(path,e)
    end
    if url.query !== nothing
        for rawpair in _gs1_split(url.query,'&',GS1_MAX_ELEMENTS)
            isempty(rawpair) && continue
            pair=_gs1_query_pair(rawpair)
            if _gs1_is_ai(pair.key)
                e=_gs1_element(GS1Element(pair.key,pair.value),length(path)+length(query))
                _gs1_unique!(seen,e.ai); _gs1_push!(query,e)
            elseif unknown_query=="preserve"
                push!(unknown,pair)
            else
                _gs1_fail("GS1 Digital Link query parameter is not a GS1 AI","GS1_DIGITAL_LINK_UNKNOWN_QUERY")
            end
            length(path)+length(query)+length(unknown) <= GS1_MAX_ELEMENTS || _gs1_fail("GS1 element and query pair count exceeds limit")
        end
    end
    GS1DigitalLinkParseResult(vcat(path,query),path[1],path,query,unknown)
end
function parse_gs1_digital_link(uri;primary_ai=nothing,unknown_query="preserve")
    _gs1_parse_link(_gs1_url(uri),primary_ai,unknown_query)
end
function validate_gs1_digital_link(uri;primary_ai=nothing,unknown_query="preserve",normalize=false)
    try
        normalize === false || _gs1_fail("GS1 validation normalize is unsupported; call normalize_gs1_digital_link")
        url=_gs1_url(uri); parsed=_gs1_parse_link(url,primary_ai,unknown_query)
        warnings=GS1ValidationIssue[]
        url.scheme=="http" && push!(warnings,GS1ValidationIssue(code="GS1_DIGITAL_LINK_HTTP",message="URI uses HTTP; use HTTPS when transport security is required",reason="http-uri"))
        !isempty(parsed.unknown_query) && push!(warnings,GS1ValidationIssue(code="GS1_DIGITAL_LINK_UNKNOWN_QUERY_PRESERVED",message="Non-GS1 query parameters are preserved",reason="unknown-query-preserved",count=length(parsed.unknown_query)))
        GS1DigitalLinkValidationResult(ok=true,result=parsed,warnings=warnings)
    catch err
        err isa InvalidGs1Error || rethrow()
        GS1DigitalLinkValidationResult(ok=false,errors=[_gs1_issue(err)])
    end
end
function normalize_gs1_digital_link(uri;primary_ai=nothing,unknown_query="preserve",mode="specqr-deterministic")
    mode isa AbstractString && mode == "specqr-deterministic" || _gs1_fail("GS1 normalization mode must be specqr-deterministic")
    url=_gs1_url(uri); parsed=_gs1_parse_link(url,primary_ai,unknown_query)
    parts=_gs1_path_parts(url.path); start=_gs1_first_ai(parts,primary_ai)
    stem=_gs1_base(url)*_gs1_prefix(parts[1:start-1])
    result=create_gs1_digital_link(parsed.elements;base_url=stem,primary_ai=parsed.primary.ai)
    if !isempty(parsed.unknown_query)
        suffix=join((_gs1_encode(p.key;form=true)*"="*_gs1_encode(p.value;form=true) for p in parsed.unknown_query),'&')
        result *= (occursin('?',result) ? "&" : "?")*suffix
    end
    _gs1_text(result,"GS1 Digital Link output")
end

# Friendly equivalents for the full element-string helper family.
gs1_normalize(value) = normalize_gs1_elements(value)
gs1_from_human_readable(value) = parse_gs1_human_readable(value)
gs1_to_element_string(elements) = create_gs1_element_string(elements)
gs1_build(elements) = create_gs1_element_string(elements)
gs1_parse(value) = parse_gs1_element_string(value)
gs1_digital_link(elements;kwargs...) = create_gs1_digital_link(elements;kwargs...)
gs1_to_digital_link(elements;kwargs...) = create_gs1_digital_link(elements;kwargs...)
