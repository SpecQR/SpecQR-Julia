@testset "Strict options and capacity" begin
    @test Options().error_correction_level == "M"
    @test Options(eci=true).eci == 26
    @test Options(eci=false).eci === nothing
    @test Options(eci=0).eci == 0
    @test Options(fnc1_second="00").fnc1_second == "00"
    @test_throws InvalidInputError Options(unknown=true)
    @test_throws InvalidEccError Options(error_correction_level="m")
    @test_throws InvalidEccError get_capacity(1,"Z")
    for field in (:version,:min_version,:max_version)
        @test_throws InvalidVersionError Options(;Dict(field=>true)...)
        @test_throws InvalidVersionError Options(;Dict(field=>0)...)
    end
    for field in (:optimize_segments,:allow_kanji,:boost_error_correction,:gs1,:fnc1)
        @test_throws InvalidInputError Options(;Dict(field=>1)...)
    end
    for field in (:mask_pattern,:margin,:scale)
        @test_throws InvalidInputError Options(;Dict(field=>true)...)
    end
    @test_throws InvalidVersionError Options(min_version=4,max_version=3)
    @test_throws InvalidModeError Options(mode="invalid")
    @test_throws InvalidModeError Options(eci=0,fnc1=true)
    @test_throws InvalidModeError Options(structured_append=(index=1,total=2,parity=0,extra=3))
    for dpi in (true,0,-1,Inf,NaN,nextfloat(0.0),"300")
        @test_throws InvalidInputError Options(print_dpi=dpi)
    end
    @test Options(print_dpi=300).print_dpi == 300.0
    @test get_capacity(1,"L";mode="numeric").maximum == 41
    @test get_capacity(1,"L";mode="byte").maximum == 17
    @test get_capacity(40,"L";mode="numeric").maximum == 7089
    @test get_capacity(40,"L";mode="byte").maximum == 2953
    @test get_capacity(1;mode="byte",control_bits=100000).maximum == 0
    @test_throws InvalidInputError get_capacity(1;control_bits=true)
end

@testset "Planning and high-level encoding" begin
    p = plan("HELLO WORLD")
    @test p.ok
    @test p.selected_version == 1
    @test p.capacity_version == 1
    @test p.data_bit_length == 74
    @test p.overflow_bits == 0
    @test p.diagnostics["phase"] == "planning"
    @test !p.diagnostics["mask_evaluated"]
    @test !p.diagnostics["codewords_built"]
    q = generate("HELLO WORLD";mask_pattern=0)
    @test q.version == p.version
    @test q.mask_pattern == 0
    @test q.diagnostics["data_bit_length"] == p.data_bit_length
    @test q.diagnostics["phase"] == "generation"
    @test size(q.matrix) == (21,21)
    @test length(q.data_codewords) == 16
    @test length(q.codewords) == 26
    @test length(q.error_correction_codewords) == 10
    @test module_at(q,1,1) == q.matrix[1,1]
    @test_throws InvalidInputError module_at(q,0,1)
    @test_throws InvalidInputError module_at(q,true,1)
    @test startswith(to_svg(q),"<svg")
    @test startswith(to_png_data_url(q),"data:image/png;base64,")
    @test render(q,"matrix") == q.matrix
    @test render(q,"matrix") !== q.matrix
    @test_throws InvalidOutputError render(q,"invalid")
    @test_throws InvalidInputError render(q,"matrix";scale=1)
    @test generate("A";error_correction_level="L",boost_error_correction=true).error_correction_level == "H"
    @test generate("A";version=10,min_version=1,max_version=1).version == 10
    @test !plan("1"^7090;error_correction_level="L").ok
    @test_throws DataTooLongError generate("1"^7090;error_correction_level="L")
    @test plan("1"^7089;error_correction_level="L").version == 40
    @test !analyze_segments([Segment("byte","a"^256)];version=9,error_correction_level="L").ok
    @test !plan("a"^256;version=9,error_correction_level="L").ok
    @test length(plan("a"^256;version=9,error_correction_level="L").segments) == 2
    @test length(plan("a"^256;version=10,error_correction_level="L").segments) == 1
    @test generate(Segment[Segment("numeric","123")]).segments[1].data == "123"
    @test estimate(Segment[Segment("numeric","123")]).ok
    @test_throws InvalidInputError generate(42)
    @test_throws InvalidInputError generate("A",Dict())
    @test_throws InvalidInputError generate(String(UInt8[0xff]))
    @test_throws InvalidInputError generate(String(UInt8[0xed,0xa0,0x80]))
    @test generate(UInt8[0xff,0,0x80]).segments[1].data == UInt8[0xff,0,0x80]
    @test_throws InvalidInputError generate([true])
    original = UInt8[0,0xff,3]
    owned = generate(original)
    original[1] = 7
    @test owned.segments[1].data == UInt8[0,0xff,3]
    exposed = owned.segments[1].data
    exposed[1] = 9
    @test owned.segments[1].data == UInt8[0,0xff,3]
    d = diagnostics(owned); d["version"]=999
    @test owned.diagnostics["version"] == 1
    @test generate("漢字";eci=26).segments[end].mode == "byte"
    @test generate("漢字";eci=26,mode="kanji").segments[end].mode == "kanji"
    @test generate("漢字";allow_kanji=false).segments[end].mode == "byte"
    @test generate("é";eci=3).segments[end].logical_bytes == UInt8[0xc3,0xa9]
    for input in ("ABC%XYZ","ABC\x1d\x1dXYZ","ABC%\x1dXYZ")
        r = generate(input;fnc1=true)
        @test reduce(vcat,(s.logical_bytes for s in r.segments);init=UInt8[]) == collect(codeunits(input))
        @test r.segments[1].mode == "fnc1"
    end
    @test_throws InvalidModeError generate("ABC%XYZ";fnc1=true,mode="alphanumeric")
    manual = generate_segments([Segment("fnc1"),Segment("alphanumeric","ABC%%XYZ")])
    @test manual.segments[end].data == "ABC%%XYZ"
    @test_throws InvalidGs1Error generate_segments([Segment("byte","ABC")];gs1=true)
    @test_throws InvalidGs1Error generate(UInt8[1];gs1=true)
    warning = plan("A";margin=0,foreground="#cccccc",background="#ffffff",scale=1,print_dpi=600)
    codes = Set(w["code"] for w in warning.warnings)
    @test "QUIET_ZONE_TOO_SMALL" in codes
    @test "COLOR_CONTRAST_LOW" in codes
    @test "PRINT_MODULE_TOO_SMALL" in codes
    @test "SCAN_RISK" in codes
end

# Independent O(n²) reference only for short test strings, including count-field
# boundaries. Production uses the linear monotonic-queue implementation.
function api_brute_bits(text,v;allow_kanji=true)
    chars = collect(text); n=length(chars)
    costs = fill(typemax(Int)÷4,n+1); costs[1]=0
    for stop in 1:n, start in 0:stop-1, mode in ("numeric","alphanumeric","kanji","byte")
        chunk=String(chars[start+1:stop])
        mode=="kanji" && !allow_kanji && continue
        try
            s=Segment(mode,chunk)
            s.count < (1<<SpecQR.character_count_bits(v,mode)) || continue
            costs[stop+1]=min(costs[stop+1],costs[start+1]+SpecQR.bit_length(s,v))
        catch e
            e isa InvalidModeError || rethrow()
        end
    end
    costs[end]
end
@testset "Exact bounded optimizer" begin
    cases=("123a456789ABC","AB12a34CD56","漢字1234漢a","A😀1234567890B","123456ABC123456a","A"^30*"x"*"1"^30)
    for text in cases, v in (1,9,10,26,27,40), allow in (true,false)
        segments=optimize_segments(text;version=v,allow_kanji=allow)
        @test join(s.data for s in segments) == text
        @test SpecQR.segments_bit_length(segments,v) == api_brute_bits(text,v;allow_kanji=allow)
        tracker=SegmentOptimizationTracker(v;allow_kanji=allow)
        for c in text
            SpecQR.append_character!(tracker,c)
        end
        @test tracker.costs[end] == SpecQR.segments_bit_length(segments,v)
    end
    @test_throws DataTooLongError optimize_segments("1"^7090)
    @test_throws InvalidInputError SegmentOptimizationTracker(1;allow_kanji=1)
    @test_throws InvalidInputError SpecQR.append_character!(SegmentOptimizationTracker(),"ab")
    @test create_segments("")[1].mode == "byte"
    @test create_segments("123";optimize=false)[1].mode == "numeric"
    @test create_segments("ABC";optimize=false)[1].mode == "alphanumeric"
    @test create_segments("漢字";optimize=false)[1].mode == "kanji"
    @test_throws InvalidInputError create_segments("123";optimize=1)
    @test_throws InvalidModeError create_segments(UInt8[1];mode="numeric")
end

@testset "Structured Append" begin
    @test calculate_structured_append_parity("") == 0
    @test calculate_structured_append_parity("漢😀") == foldl(xor,Int.(codeunits("漢😀"));init=0)
    @test calculate_structured_append_parity(UInt8[0,0xff,0x80]) == 0x7f
    @test_throws InvalidInputError calculate_structured_append_parity([true])
    @test_throws InvalidInputError calculate_structured_append_parity(String(UInt8[0xff]))
    @test_throws InvalidInputError generate_structured_append("A";version=1)
    @test_throws InvalidModeError generate_structured_append("A"^100;eci=0)
    @test_throws InvalidGs1Error generate_structured_append("A"^100;gs1=true)
    @test_throws InvalidModeError generate_structured_append("A"^100;max_symbols=true)
    @test_throws InvalidModeError generate_structured_append("A"^100;max_symbols=17)
    @test_throws InvalidModeError generate_structured_append("A"^100;parity=0)
    @test_throws InvalidModeError generate_structured_append("A"^100;boost_error_correction=true)
    @test_throws DataTooLongError generate_structured_append("1"^1_000_001)
    data = "HELLO WORLD "^8
    result = generate_structured_append(data;version=1,diagnostics=true,mask_pattern=0)
    @test 2 <= result.total <= 16
    @test result.parity == calculate_structured_append_parity(data)
    @test result.input_length == length(data)
    @test result.byte_length == ncodeunits(data)
    @test all(q->q.version==1,result.symbols)
    @test join(join(s.data for s in q.segments if !s.is_control) for q in result.symbols) == data
    @test all(q->q.segments[1].mode=="structured-append",result.symbols)
    @test [q.segments[1].index for q in result.symbols] == collect(1:result.total)
    unicode = "é😀漢"^15
    multi = generate_structured_append(unicode;version=2,mode="byte",mask_pattern=0)
    @test join(q.segments[end].data for q in multi.symbols) == unicode
    @test all(q->isvalid(q.segments[end].data),multi.symbols)
    bytes = UInt8[mod(i,256) for i in 1:100]
    binary = generate_structured_append(bytes;version=1,mask_pattern=0)
    @test reduce(vcat,(q.segments[end].data for q in binary.symbols)) == bytes
    manual = Segment[Segment("numeric","1234567890"),Segment("byte","é😀"^20),Segment("alphanumeric","END")]
    set = SpecQR.generate_segments_structured_append(manual;version=2,mask_pattern=0,
        diagnostics=(split_units="full",symbol_results="diagnostics"))
    @test 2 <= set.total <= 16
    @test set.diagnostics["split_strategy"] == "segment-boundary-byte-chunk"
    @test haskey(set.diagnostics,"split_units")
    @test set.parity == SpecQR.calculate_structured_append_segments_parity(manual)
    @test sum(q->count(s->s.mode=="numeric",q.segments),set.symbols)==1
    @test join(join(s.data for s in q.segments if !s.is_control) for q in set.symbols)==join(s.data for s in manual)
    @test_throws InvalidModeError SpecQR.generate_segments_structured_append(manual;mode="byte")
    @test_throws InvalidGs1Error SpecQR.generate_segments_structured_append([Segment("fnc1"),Segment("byte","A")])
    @test_throws InvalidInputError SpecQR.generate_segments_structured_append([Segment("byte","")])
    parity=calculate_structured_append_parity("AB")
    parts=[(index=2,total=2,parity=parity,data="B"),(index=1,total=2,parity=parity,data="A")]
    merged=SpecQR.merge_structured_append_parts(parts)
    @test merged.data=="AB"
    @test merged.diagnostics["parity_check"]["matches"]
    @test_throws InvalidInputError SpecQR.merge_structured_append_parts(parts[1:1])
    @test_throws InvalidInputError SpecQR.merge_structured_append_parts([parts[1],parts[1]])
    @test_throws InvalidInputError SpecQR.merge_structured_append_parts([(index=1,total=2,parity=0,data="A"),(index=2,total=2,parity=0,data="B")])
    @test_throws InvalidInputError SpecQR.merge_structured_append_parts([(index=1,total=2,parity=3,data="A"),(index=2,total=2,parity=3,data=UInt8[0x42])])
end

@testset "Independent concurrent encoders" begin
    opts=Options(error_correction_level="Q",mask_pattern=3)
    baseline=generate("Thread-safe 漢字 1234567890",opts)
    tasks=[Threads.@spawn(generate("Thread-safe 漢字 1234567890",opts)) for _ in 1:24]
    results=fetch.(tasks)
    @test all(q->q.matrix==baseline.matrix && q.codewords==baseline.codewords,results)
    @test results[1].matrix !== results[2].matrix
    @test results[1].codewords !== results[2].codewords
    @test results[1].segments !== results[2].segments
    @test results[1].diagnostics !== results[2].diagnostics
    results[1].matrix[1,1] = !results[1].matrix[1,1]
    @test results[2].matrix == baseline.matrix
    results[1].codewords[1] = 0
    @test results[2].codewords == baseline.codewords
    @test_throws DataTooLongError plan("A"^1_000_001)
    @test_throws DataTooLongError analyze_segments(fill(Segment("byte",""),16_385))
    @test_throws DataTooLongError analyze_segments([Segment("byte","A"^600_000),Segment("byte","B"^600_000)])
end

@testset "Validated GS1 generation" begin
    raw="010950600013435210LOT%1\x1d17251231"
    q=generate(raw;gs1=true)
    @test q.segments[1].mode=="fnc1"
    @test q.segments[2].mode=="byte"
    @test q.segments[2].data==raw
    @test q.diagnostics["gs1_validation"]["enabled"]
    @test q.diagnostics["gs1_validation"]["element_count"]==3
    @test q.diagnostics["gs1_validation"]["ais"]==["01","10","17"]
    @test q.diagnostics["gs1_validation"]["has_separators"]
    @test_throws InvalidModeError generate(raw;gs1=true,mode="alphanumeric")
    @test_throws InvalidGs1Error generate("10A\x1d\x1d17251231";gs1=true)
    @test_throws InvalidColorError Options(foreground="url(https://bad.invalid)")
end
