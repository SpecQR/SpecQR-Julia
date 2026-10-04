# Development-only JSON-line adapter, invoking the real Julia package.
using SpecQR, Base64
const S=SpecQR
bad(message)=throw(S.InvalidInputError(message))
object(x)=x isa AbstractDict ? x : bad("Expected an object")
array(x)=x isa AbstractVector ? x : bad("Expected an array")
textvalue(x)=x isa AbstractString ? String(x) : bad("Expected a string")
function integer(x)
    x isa Bool && bad("Expected an integer")
    x isa Integer && typemin(Int)<=x<=typemax(Int) && return Int(x)
    x isa AbstractFloat && isfinite(x) && isinteger(x) && typemin(Int)<=x<typemax(Int) && return Int(x)
    bad("Expected a native-range integer")
end
function bytesvalue(x)
    a=array(x); length(a)<=1_000_000 || throw(S.DataTooLongError("Payload resource limit exceeded"))
    result=Vector{UInt8}(undef,length(a))
    for (i,b) in enumerate(a); n=integer(b); 0<=n<=255 || bad("Byte outside 0..255"); result[i]=UInt8(n); end
    result
end
function wire_segment(raw)
    d=object(raw); mode=textvalue(get(d,"mode",nothing))
    if mode in ("numeric","alphanumeric","kanji")
        return S.Segment(mode,textvalue(get(d,"text",get(d,"data",nothing))))
    elseif mode=="byte"
        data=haskey(d,"bytes") ? bytesvalue(d["bytes"]) : get(d,"text",get(d,"data",nothing))
        data isa AbstractVector && (data=bytesvalue(data)); return S.Segment(mode,data)
    elseif mode=="eci"
        return S.Segment(mode; assignment_number=integer(d["assignmentNumber"]))
    elseif mode=="fnc1"
        return S.Segment(mode)
    elseif mode=="fnc1-second"
        return S.Segment(mode; application_indicator=textvalue(d["applicationIndicator"]))
    elseif mode=="structured-append"
        return S.Segment(mode; index=integer(d["index"]), total=integer(d["total"]), parity=integer(d["parity"]))
    end
    throw(S.InvalidModeError("Unknown segment mode"))
end
function wire_options(raw)
    d=object(raw); o=Dict{Symbol,Any}()
    map=("errorCorrectionLevel"=>:error_correction_level,"version"=>:version,"minVersion"=>:min_version,"maxVersion"=>:max_version,"maskPattern"=>:mask_pattern,"mode"=>:mode,"optimizeSegments"=>:optimize_segments,"boostErrorCorrection"=>:boost_error_correction,"allowKanji"=>:allow_kanji,"eci"=>:eci,"gs1"=>:gs1,"fnc1"=>:fnc1,"fnc1Second"=>:fnc1_second,"margin"=>:margin,"scale"=>:scale,"foreground"=>:foreground,"background"=>:background,"printDpi"=>:print_dpi)
    for (key,sym) in map
        if haskey(d,key)
            v=d[key]
            if key in ("version","minVersion","maxVersion","maskPattern")
                v=v===nothing || v=="auto" ? nothing : integer(v)
            end
            o[sym]=v
        end
    end
    if get(d,"structuredAppend",nothing)!==nothing
        sa=copy(object(d["structuredAppend"])); sa["mode"]="structured-append";o[:structured_append]=wire_segment(sa)
    end
    S.Options(;o...)
end
rows(matrix)=[join(matrix[y,x] ? '1' : '0' for x in axes(matrix,2)) for y in axes(matrix,1)]
function packed(matrix)
    n=length(matrix); result=zeros(UInt8,cld(n,8)); i=0
    for y in axes(matrix,1), x in axes(matrix,2)
        matrix[y,x] && (result[(i>>3)+1] |= UInt8(1<<(7-(i&7))));i+=1
    end
    base64encode(result)
end
function wire_symbol(q,r=Dict())
    out=Dict{String,Any}("version"=>q.version,"ecc"=>q.error_correction_level,"mask"=>q.mask_pattern,"data"=>bytes2hex(q.data_codewords),"codewords"=>bytes2hex(q.codewords),"matrix"=>rows(q.matrix),"matrixPacked"=>packed(q.matrix),"segments"=>[Dict("mode"=>s.mode,"count"=>s.count) for s in q.segments])
    haskey(r,"pngScale") && (out["png"]=bytes2hex(S.to_png(q;scale=integer(r["pngScale"]))))
    get(r,"diagnostics",false)==true && (out["diagnostics"]=q.diagnostics)
    if get(r,"renders",false)==true
        out["svg"]=S.to_svg(q);out["svgDataUrl"]=S.to_svg_data_url(q);out["pngDataUrl"]=S.to_png_data_url(q)
    end
    out
end
function wire_gs1(v)
    if v isa NamedTuple || v isa AbstractDict
        mapping=Dict("base_url"=>"baseUrl","element_string"=>"elementString","primary_ai"=>"primaryAi","path_elements"=>"pathElements","query_elements"=>"queryElements","unknown_query"=>"unknownQuery","has_separators"=>"hasSeparators","element_index"=>"elementIndex")
        return Dict(get(mapping,string(k),string(k))=>wire_gs1(v[k]) for k in keys(v))
    elseif v isa Tuple || v isa AbstractVector
        return [wire_gs1(x) for x in v]
    elseif isstructtype(typeof(v)) && !(v isa Number || v isa AbstractString || v===nothing)
        return wire_gs1((; (k=>getproperty(v,k) for k in propertynames(v))...))
    end
    v
end
function request(raw)
    r=object(raw); command=get(r,"command","generate"); command===nothing && (command="generate")
    if command=="gf"
        return Dict("bytes"=>bytes2hex(UInt8[S.gf_multiply(a,b) for a in 0:255 for b in 0:255]))
    elseif command=="rs"
        degree=integer(r["degree"]); data=UInt8[(i*61+degree)&255 for i in 0:299]
        return Dict("generator"=>bytes2hex(S.reed_solomon_divisor(degree)),"remainder"=>bytes2hex(S.reed_solomon_remainder(data,degree)))
    elseif command=="raw"
        v=integer(r["version"]);ecc=textvalue(r["ecc"]);seed=integer(r["seed"]); mask=integer(r["mask"])
        0<=seed<=31 || bad("Seed outside 0..31");ordinal=findfirst(==(ecc),("L","M","Q","H"));ordinal===nothing && throw(S.InvalidEccError("Unknown ECC"));ordinal-=1
        data=UInt8[seed==0 ? 0 : seed==1 ? 255 : xor(i*149+v*43+ordinal*89+seed*67,i>>(seed+1))&255 for i in 0:S.data_codeword_count(v,ecc)-1]
        inter=S.interleave_codewords(data,v,ecc);q=S.build_matrix(inter.codewords,v,ecc;mask_pattern=mask<0 ? nothing : mask)
        return Dict("data"=>bytes2hex(data),"codewords"=>bytes2hex(inter.codewords),"matrix"=>rows(q.matrix),"matrixPacked"=>packed(q.matrix),"mask"=>q.mask_pattern,"penalty"=>q.penalty,"penalties"=>[x.penalty for x in q.mask_penalties])
    elseif command=="gs1-build"
        return Dict("value"=>S.create_gs1_element_string(r["elements"]))
    elseif command=="digital-link-build"
        lo=object(get(r,"linkOptions",Dict()));kw=Dict{Symbol,Any}(:base_url=>lo["baseUrl"])
        haskey(lo,"pathAis") && (kw[:path_ais]=lo["pathAis"])
        return Dict("value"=>S.create_gs1_digital_link(r["elements"];kw...))
    elseif command=="digital-link-parse"
        return wire_gs1(S.parse_gs1_digital_link(r["url"]))
    elseif command=="digital-link-validate"
        return wire_gs1(S.validate_gs1_digital_link(r["url"]))
    elseif command=="digital-link-normalize"
        return Dict("value"=>S.normalize_gs1_digital_link(r["url"]))
    end
    rawopts=get(r,"options",Dict{String,Any}());rawopts===nothing && (rawopts=Dict{String,Any}());o=wire_options(rawopts)
    if command=="capacity"
        c=S.get_capacity(o.version,o.error_correction_level;mode=o.mode)
        return Dict("maximum"=>c.maximum,"dataCodewords"=>c.data_codewords,"capacityBits"=>c.capacity_bits,"countBits"=>c.character_count_bits)
    end
    data=haskey(r,"segments") ? [wire_segment(s) for s in array(r["segments"])] : haskey(r,"bytes") ? bytesvalue(r["bytes"]) : textvalue(get(r,"text",""))
    if command=="estimate" || command=="plan"
        p=S.plan(data,o)
        return Dict("fits"=>p.ok,"version"=>p.capacity_version,"requiredBits"=>p.data_bit_length,"capacityBits"=>p.capacity_bits)
    elseif command=="structured-append"
        maxsymbols=integer(get(rawopts,"maxSymbols",16))
        set=S.generate_structured_append(data,o;max_symbols=maxsymbols)
        symbols=[wire_symbol(q,r) for q in set.symbols]
        return Dict("total"=>set.total,"parity"=>set.parity,"inputLength"=>set.input_length,"byteLength"=>set.byte_length,"symbols"=>symbols,"versions"=>[x["version"] for x in symbols],"masks"=>[x["mask"] for x in symbols])
    elseif command=="generate"
        return wire_symbol(S.generate(data,o),r)
    end
    bad("Unknown command")
end
function run_request(r)
    try
        request(r)
    catch e
        e isa InterruptException && rethrow()
        Dict("error"=>string(nameof(typeof(e))),"isSpecQRError"=>e isa S.SpecQRError,"code"=>e isa S.SpecQRError ? S.error_code(e) : "INTERNAL_ERROR","message"=>sprint(showerror,e))
    end
end
