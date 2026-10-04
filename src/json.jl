# Small strict JSON codec for the CLI and conformance adapter; no dependencies.
const MAX_JSON_BYTES = 8_000_000
const MAX_JSON_DEPTH = 64
mutable struct JSONCursor
    data::Vector{UInt8}
    at::Int
    values::Int
end
_json_fail(message) = throw(InvalidInputError("JSON: " * message))
function _json_space!(p)
    while p.at <= length(p.data) && p.data[p.at] in (0x20,0x09,0x0a,0x0d)
        p.at += 1
    end
end
function _json_hex4!(p)
    p.at + 3 <= length(p.data) || _json_fail("incomplete Unicode escape")
    n = 0
    for _ in 1:4
        b=p.data[p.at]; p.at+=1
        d=0x30<=b<=0x39 ? Int(b)-0x30 : 0x41<=b<=0x46 ? Int(b)-0x41+10 : 0x61<=b<=0x66 ? Int(b)-0x61+10 : -1
        d>=0 || _json_fail("invalid Unicode escape")
        n=(n<<4)|d
    end
    n
end
function _json_string!(p)
    p.at+=1; out=IOBuffer()
    while p.at<=length(p.data)
        b=p.data[p.at]; p.at+=1
        if b==0x22
            s=String(take!(out)); isvalid(s) || _json_fail("invalid UTF-8"); return s
        elseif b==0x5c
            p.at<=length(p.data) || _json_fail("incomplete escape")
            b=p.data[p.at]; p.at+=1
            if b==0x75
                u=_json_hex4!(p)
                if 0xd800<=u<=0xdbff
                    p.at+1<=length(p.data) && p.data[p.at:p.at+1]==UInt8[0x5c,0x75] || _json_fail("unpaired high surrogate")
                    p.at+=2; lo=_json_hex4!(p); 0xdc00<=lo<=0xdfff || _json_fail("invalid low surrogate")
                    u=0x10000+(u-0xd800)*0x400+(lo-0xdc00)
                elseif 0xdc00<=u<=0xdfff
                    _json_fail("unpaired low surrogate")
                end
                print(out,Char(u))
            elseif b in (0x22,0x5c,0x2f)
                write(out,b)
            else
                esc = b==0x62 ? 0x08 : b==0x66 ? 0x0c : b==0x6e ? 0x0a : b==0x72 ? 0x0d : b==0x74 ? 0x09 : -1
                esc>=0 || _json_fail("invalid escape"); write(out,UInt8(esc))
            end
        else
            b>=0x20 || _json_fail("unescaped control character"); write(out,b)
        end
    end
    _json_fail("unterminated string")
end
function _json_value!(p,depth)
    depth<=MAX_JSON_DEPTH || _json_fail("nesting limit exceeded")
    p.values+=1; p.values<=1_000_000 || _json_fail("value limit exceeded")
    _json_space!(p); p.at<=length(p.data) || _json_fail("expected value")
    b=p.data[p.at]
    b==0x22 && return _json_string!(p)
    if b==0x7b || b==0x5b
        object=b==0x7b; close=object ? 0x7d : 0x5d; p.at+=1; _json_space!(p)
        out=object ? Dict{String,Any}() : Any[]
        if p.at<=length(p.data) && p.data[p.at]==close; p.at+=1; return out; end
        while true
            if object
                p.at<=length(p.data) && p.data[p.at]==0x22 || _json_fail("object key must be a string")
                key=_json_string!(p); haskey(out,key) && _json_fail("duplicate object key")
                _json_space!(p); p.at<=length(p.data) && p.data[p.at]==0x3a || _json_fail("expected colon"); p.at+=1
                out[key]=_json_value!(p,depth+1)
            else
                push!(out,_json_value!(p,depth+1))
            end
            _json_space!(p); p.at<=length(p.data) || _json_fail("unterminated container")
            c=p.data[p.at]; p.at+=1
            c==close && return out
            c==0x2c || _json_fail("expected comma")
            _json_space!(p)
        end
    elseif b in (0x74,0x66,0x6e)
        token,val=b==0x74 ? ("true",true) : b==0x66 ? ("false",false) : ("null",nothing)
        n=ncodeunits(token); p.at+n-1<=length(p.data) && p.data[p.at:p.at+n-1]==codeunits(token) || _json_fail("invalid literal")
        p.at+=n; return val
    elseif b==0x2d || 0x30<=b<=0x39
        start=p.at
        while p.at<=length(p.data) && (p.data[p.at] in (0x2d,0x2b,0x2e,0x65,0x45) || 0x30<=p.data[p.at]<=0x39); p.at+=1; end
        p.at-start<=128 || _json_fail("number token too long")
        token=String(p.data[start:p.at-1])
        occursin(r"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$",token) || _json_fail("invalid number")
        if !occursin(r"[.eE]",token)
            n=tryparse(Int,token); n===nothing && _json_fail("integer outside native range"); return n
        end
        n=tryparse(Float64,token); n!==nothing && isfinite(n) || _json_fail("non-finite number"); return n
    end
    _json_fail("unexpected character")
end
function json_parse(input::Union{AbstractString,AbstractVector{UInt8}})
    n=sizeof(input); n<=MAX_JSON_BYTES || _json_fail("input too large")
    data=Vector{UInt8}(input isa AbstractString ? codeunits(input) : input)
    isvalid(String(copy(data))) || _json_fail("invalid UTF-8")
    p=JSONCursor(data,1,0); result=_json_value!(p,0); _json_space!(p)
    p.at==length(data)+1 || _json_fail("trailing data"); result
end
function _json_write_string(io,s::AbstractString)
    isvalid(s) || _json_fail("cannot encode invalid UTF-8")
    write(io,UInt8('"'))
    for c in s
        if c=='"'; print(io,"\\\"")
        elseif c=='\\'; print(io,"\\\\")
        elseif c=='\n'; print(io,"\\n")
        elseif c=='\r'; print(io,"\\r")
        elseif c=='\t'; print(io,"\\t")
        elseif c=='\b'; print(io,"\\b")
        elseif c=='\f'; print(io,"\\f")
        elseif UInt32(c)<0x20; print(io,"\\u",string(UInt32(c),base=16,pad=4))
        else; print(io,c)
        end
    end
    write(io,UInt8('"'))
end
function _json_write(io,v,depth)
    depth<=MAX_JSON_DEPTH || _json_fail("output nesting limit")
    if v===nothing; print(io,"null")
    elseif v isa Bool; print(io,v ? "true" : "false")
    elseif v isa Integer; print(io,v)
    elseif v isa AbstractFloat; isfinite(v) || _json_fail("cannot encode non-finite number"); print(io,v)
    elseif v isa AbstractString || v isa Symbol; _json_write_string(io,string(v))
    elseif v isa AbstractDict || v isa NamedTuple
        print(io,'{'); first=true
        for k in sort!(collect(keys(v)); by=string)
            first || print(io,','); first=false; _json_write_string(io,string(k)); print(io,':'); _json_write(io,v[k],depth+1)
        end
        print(io,'}')
    elseif v isa Tuple || v isa AbstractVector
        print(io,'[')
        for (i,x) in enumerate(v); i==1 || print(io,','); _json_write(io,x,depth+1); end
        print(io,']')
    else
        _json_fail("unsupported output type $(typeof(v))")
    end
end
function json_stringify(value)
    io=IOBuffer(); _json_write(io,value,0); String(take!(io))
end
