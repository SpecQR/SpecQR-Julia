#!/usr/bin/env julia
include(joinpath(@__DIR__, "..", "src", "SpecQR.jl"))
using .SpecQR
const S=SpecQR
const HELP="""
SpecQR Julia 0.1.0
Usage: julia bin/specqr.jl --text TEXT [options]
Input: --text TEXT | --input FILE | --stdin | --hex HEX | --segment MODE:VALUE
       --binary interprets file/stdin as bytes; otherwise strict UTF-8.
Encode: --ecc L|M|Q|H --mode auto|numeric|alphanumeric|byte|kanji
        --version N --min-version N --max-version N --mask auto|0..7
        --eci N --fnc1 --fnc1-second AA --gs1 --no-optimize --no-kanji --boost-ecc
Plan: --plan (or --estimate)
Render: --format svg|png|json|matrix|png-data-url|svg-data-url (default svg)
        --output FILE --force --scale N --margin N --foreground COLOR
        --background COLOR --dpi N
Append: --structured-append --max-symbols 2..16 --full-split-units
        --symbol-diagnostics; JSON or PNG/SVG with --output PREFIX
Manual: repeat --segment numeric:123 --segment alphanumeric:ABC
        byte:TEXT, hex:BYTES, kanji:TEXT, eci:26, fnc1:,
        fnc1-second:AA, structured-append:INDEX,TOTAL,PARITY
        Manual FNC1 alphanumeric is already escaped (% = GS, %% = percent).
Info: --help --library-version --runtime
"""
fail(s)=throw(InvalidInputError(s))
function number(s)
    occursin(r"^-?[0-9]+$",s) || fail("Expected an integer")
    n=tryparse(Int,s);n===nothing && fail("Integer outside supported range");n
end
function unhex(s)
    iseven(ncodeunits(s)) && occursin(r"^[0-9A-Fa-f]*$",s) || fail("Expected even-length hexadecimal bytes")
    ncodeunits(s)<=2_000_000 || throw(DataTooLongError("Binary input resource limit"))
    hex2bytes(s)
end
function manual_segment(description)
    p=findfirst(==(':'),description);p===nothing && fail("Segments use MODE:VALUE")
    mode=description[1:prevind(description,p)];value=description[nextind(description,p):end]
    mode in ("numeric","alphanumeric","byte","kanji") && return Segment(mode,value)
    mode=="hex" && return Segment("byte",unhex(value))
    mode=="eci" && return Segment("eci";assignment_number=number(value))
    mode=="fnc1-second" && return Segment(mode;application_indicator=value)
    mode=="fnc1" && (isempty(value) || fail("FNC1 first takes no value");return Segment(mode))
    if mode=="structured-append"
        fields=split(value,',');length(fields)==3 || fail("SA header needs INDEX,TOTAL,PARITY")
        return Segment(mode;index=number(fields[1]),total=number(fields[2]),parity=number(fields[3]))
    end
    throw(InvalidModeError("Unknown segment mode"))
end
rows(matrix)=[join(matrix[y,x] ? '1' : '0' for x in axes(matrix,2)) for y in axes(matrix,1)]
function result_json(q)
    Dict("version"=>q.version,"errorCorrectionLevel"=>q.error_correction_level,"maskPattern"=>q.mask_pattern,"matrix"=>rows(q.matrix),"dataCodewords"=>bytes2hex(q.data_codewords),"codewords"=>bytes2hex(q.codewords),"diagnostics"=>q.diagnostics)
end
function plan_json(p)
    Dict("ok"=>p.ok,"version"=>p.version,"capacityVersion"=>p.capacity_version,"errorCorrectionLevel"=>p.error_correction_level,"requiredBits"=>p.data_bit_length,"capacityBits"=>p.capacity_bits,"remainingBits"=>p.remaining_bits,"diagnostics"=>p.diagnostics)
end
function output_bytes(q,format)
    format=="png" && return to_png(q)
    text=format=="svg" ? to_svg(q) : format=="json" ? S.json_stringify(result_json(q))*"\n" : format=="matrix" ? join(rows(q.matrix),'\n')*"\n" : format=="png-data-url" ? to_png_data_url(q)*"\n" : format=="svg-data-url" ? to_svg_data_url(q)*"\n" : fail("Unknown output format")
    Vector{UInt8}(codeunits(text))
end
function write_file(path,data,force)
    islink(path) && fail("Refusing to overwrite a symbolic link")
    if !force
        f=Base.Filesystem.open(path,Base.JL_O_WRONLY|Base.JL_O_CREAT|Base.JL_O_EXCL,0o666)
        try write(f,data) finally close(f) end
    else
        open(path,"w") do io;write(io,data);end
    end
end
function read_bounded(io)
    data=read(io,4_000_001);length(data)<=4_000_000 || throw(DataTooLongError("Input byte resource limit"));data
end
function main(args=ARGS)
    options=Dict{Symbol,Any}();seen=Set{String}();segments=Segment[]; source="";sources=0;value=nothing;inputpath="";output="";format="svg";binary=false;force=false;planning=false;appending=false;maxsymbols=16;full=false;symbol_diagnostics=false
    valueopts=Dict("--ecc"=>:error_correction_level,"--mode"=>:mode,"--version"=>:version,"--min-version"=>:min_version,"--max-version"=>:max_version,"--mask"=>:mask_pattern,"--eci"=>:eci,"--fnc1-second"=>:fnc1_second,"--scale"=>:scale,"--margin"=>:margin,"--foreground"=>:foreground,"--background"=>:background,"--dpi"=>:print_dpi)
    integers=Set((:version,:min_version,:max_version,:mask_pattern,:eci,:scale,:margin))
    i=1
    while i<=length(args)
        key=args[i];isvalid(key) || fail("Invalid UTF-8 argument");key=="--estimate" && (key="--plan")
        key=="--help" && (print(HELP);return)
        key=="--library-version" && (println("0.1.0");return)
        key=="--runtime" && (println(S.json_stringify(Dict("julia"=>string(VERSION),"os"=>string(Sys.KERNEL),"arch"=>string(Sys.ARCH),"wordSize"=>Sys.WORD_SIZE,"threads"=>Threads.nthreads())));return)
        key!="--segment" && key in seen && fail("Duplicate option: $key");push!(seen,key)
        if haskey(valueopts,key) || key in ("--text","--input","--hex","--segment","--output","--format","--max-symbols")
            i+=1;i<=length(args) || fail("Missing value for $key");v=args[i];isvalid(v) || fail("Invalid UTF-8 argument")
            if key=="--text";source="text";value=v;sources+=1
            elseif key=="--input";source="file";inputpath=v;sources+=1
            elseif key=="--hex";source="bytes";value=unhex(v);sources+=1
            elseif key=="--segment"
                if source!="segments";source="segments";sources+=1;end
                length(segments)<16384 || throw(DataTooLongError("Too many segments"));push!(segments,manual_segment(v))
            elseif key=="--output";output=v
            elseif key=="--format";format=v
            elseif key=="--max-symbols";maxsymbols=number(v)
            else
                k=valueopts[key]
                if k==:mask_pattern && v=="auto";options[k]=nothing
                elseif k in integers;options[k]=number(v)
                elseif k==:print_dpi;n=tryparse(Float64,v);n===nothing && fail("DPI must be a number");options[k]=n
                else;options[k]=v
                end
            end
        elseif key=="--stdin";source="stdin";sources+=1
        elseif key=="--binary";binary=true
        elseif key=="--force";force=true
        elseif key=="--plan";planning=true
        elseif key=="--structured-append";appending=true
        elseif key=="--full-split-units";full=true
        elseif key=="--symbol-diagnostics";symbol_diagnostics=true
        elseif key=="--no-optimize";options[:optimize_segments]=false
        elseif key=="--no-kanji";options[:allow_kanji]=false
        elseif key=="--boost-ecc";options[:boost_error_correction]=true
        elseif key=="--gs1";options[:gs1]=true
        elseif key=="--fnc1";options[:fnc1]=true
        else;fail("Unknown option: $key")
        end
        i+=1
    end
    sources==1 || fail("Choose exactly one input source")
    binary && !(source in ("file","stdin")) && fail("--binary requires --input or --stdin")
    format in ("svg","png","json","matrix","png-data-url","svg-data-url") || fail("Unknown output format")
    planning && appending && fail("Planning cannot combine with Structured Append")
    !appending && ("--max-symbols" in seen || full || symbol_diagnostics) && fail("Append options require --structured-append")
    !isempty(output) && !force && (ispath(output)||islink(output)) && fail("Output exists; use --force to replace it")
    if source in ("file","stdin")
        data=source=="file" ? open(read_bounded,inputpath,"r") : read_bounded(stdin)
        value=binary ? data : String(data)
    elseif source=="segments";value=segments
    end
    o=Options(;options...)
    bytes=if planning
        Vector{UInt8}(codeunits(S.json_stringify(plan_json(plan(value,o)))*"\n"))
    elseif appending
        full && source!="segments" && fail("--full-split-units requires manual segments")
        detail=source=="segments" ? (split_units=full ? "full" : "summary",symbol_results=symbol_diagnostics ? "diagnostics" : "output") : symbol_diagnostics
        sa=generate_structured_append(value,o;max_symbols=maxsymbols,diagnostics=detail)
        if format=="json"
            Vector{UInt8}(codeunits(S.json_stringify(Dict("total"=>sa.total,"parity"=>sa.parity,"inputLength"=>sa.input_length,"byteLength"=>sa.byte_length,"symbols"=>[result_json(q) for q in sa.symbols],"diagnostics"=>sa.diagnostics))*"\n"))
        else
            !isempty(output) && format in ("svg","png") || fail("Append rendering requires --output PREFIX with PNG/SVG")
            paths=[output*"-"*lpad(string(i),2,'0')*"."*format for i in 1:sa.total]
            any(islink,paths) && fail("Output is a symbolic link")
            !force && any(ispath,paths) && fail("Append output exists; use --force")
            for (p,q) in zip(paths,sa.symbols);write_file(p,output_bytes(q,format),force);end
            println(S.json_stringify(Dict("total"=>sa.total,"parity"=>sa.parity,"files"=>paths)));return
        end
    else
        output_bytes(generate(value,o),format)
    end
    isempty(output) ? write(stdout,bytes) : write_file(output,bytes,force)
end
try
    main()
catch e
    e isa InterruptException && rethrow()
    if e isa SpecQRError
        println(stderr,sprint(showerror,e));exit(2)
    elseif e isa Base.IOError || e isa SystemError
        println(stderr,"IO_ERROR: ",sprint(showerror,e));exit(3)
    else
        println(stderr,"INTERNAL_ERROR: ",sprint(showerror,e));exit(4)
    end
end
