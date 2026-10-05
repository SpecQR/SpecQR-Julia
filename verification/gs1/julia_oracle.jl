# Audit-only adapter; every operation calls the actual public Julia implementation.
using SpecQR
const S = SpecQR
function wire(v)
    if v isa AbstractDict || v isa NamedTuple
        camel(k)=replace(string(k),r"_([a-z])"=>m->uppercase(m[2:end]))
        return Dict(camel(k)=>wire(v[k]) for k in keys(v))
    elseif v isa Tuple || v isa AbstractVector
        return [wire(x) for x in v]
    elseif isstructtype(typeof(v)) && !(v isa Number || v isa AbstractString || v===nothing)
        return wire((; (k=>getproperty(v,k) for k in propertynames(v))...))
    end
    v
end
const M = Dict("dictionary"=>S.get_supported_gs1_ais,"info"=>S.get_gs1_ai_info,"checkDigit"=>S.calculate_gs1_check_digit,"validateCheckDigit"=>S.validate_gs1_check_digit,"gtinDigit"=>S.calculate_gtin_check_digit,"gtinAppend"=>S.append_gtin_check_digit,"gtinValidate"=>S.validate_gtin_check_digit,"ssccDigit"=>S.calculate_sscc_check_digit,"ssccAppend"=>S.append_sscc_check_digit,"ssccValidate"=>S.validate_sscc_check_digit,"human"=>S.parse_gs1_human_readable,"raw"=>S.parse_gs1_element_string,"create"=>S.create_gs1_element_string,"validateElements"=>S.validate_gs1_elements,"validateRaw"=>S.validate_gs1_element_string,"linkCreate"=>S.create_gs1_digital_link,"linkParse"=>S.parse_gs1_digital_link,"linkValidate"=>S.validate_gs1_digital_link,"linkNormalize"=>S.normalize_gs1_digital_link)
function request(f)
    op=f["op"]; op=="dictionary" && return wire(M[op]())
    options=get(f,"options",Dict()); options===nothing && (options=Dict())
    snake(k)=Symbol(replace(k,r"[A-Z]"=>m->"_"*lowercase(m)))
    kw=Dict(snake(k)=>v for (k,v) in options)
    wire(M[op](get(f,"elements",get(f,"input",nothing));kw...))
end
for line in eachline(stdin)
    result=try
        request(S.json_parse(line))
    catch err
        err isa S.InvalidGs1Error || rethrow()
        Dict("throws"=>Dict("code"=>S.error_code(err),"message"=>err.message,"detailCode"=>err.detail_code))
    end
    println(S.json_stringify(result))
end
