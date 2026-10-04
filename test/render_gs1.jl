using Test
using SpecQR
using Base64
const RG = SpecQR

@testset "Bounded rendering" begin
    mat = Bool[true false; false true]
    image = RG.to_pixels(mat; scale=2,margin=1,foreground="#1234",background="transparent")
    @test (image.width,image.height,length(image.pixels)) == (8,8,256)
    for y in 0:7, x in 0:7
        dark = (x in 2:3 && y in 2:3) || (x in 4:5 && y in 4:5)
        @test image.pixels[(y*8+x)*4+1:(y*8+x)*4+4] == (dark ? UInt8[17,34,51,68] : zeros(UInt8,4))
    end
    svg=RG.to_svg(mat; scale=2,margin=1,foreground="#1234",background="transparent")
    @test occursin("width=\"8\" height=\"8\"",svg)
    @test occursin("M2,2h2v2h-2zM4,4h2v2h-2z",svg)
    png=RG.to_png(mat;scale=2,margin=1,foreground="#1234",background="transparent")
    @test length(png)==332
    @test png[1:8] == UInt8[137,80,78,71,13,10,26,10]
    @test png[25:26] == UInt8[8,6]
    @test Base64.base64decode(split(RG.to_png_data_url(mat),',';limit=2)[2]) == RG.to_png(mat)
    @test startswith(RG.to_svg_data_url(mat),"data:image/svg+xml;charset=utf-8,%3Csvg")
    @test RG.to_data_url(mat;format="png") == RG.to_png_data_url(mat)
    @test RG.to_data_url(mat;format="svg") == RG.to_svg_data_url(mat)
    @test RG.parse_color("#abcdef80") == (171,205,239,128)
    @test RG.parse_color(" WHITE ") == (255,255,255,255)
    @test RG.parse_color("#000") == (0,0,0,255)
    @test RG.parse_color("red";strict=false) === nothing
    @test RG.contrast_ratio("black","white") ≈ 21
    @test RG.contrast_ratio("transparent","black") ≈ 1
    @test RG.contrast_ratio("black","transparent") ≈ 21
    @test RG.render_dimensions(mat;scale=2,margin=1,dpi=300).symbol_size_mm ≈ 8/300*25.4
    @test RG.render_dimensions(mat;dpi=nothing).dpi === nothing
    for color in ("red\" onload=\"x","url(x)",String(UInt8[0xff]),"#xyz","",repeat("a",65),"#12345",1)
        @test_throws RG.InvalidColorError RG.to_svg(mat;foreground=color)
    end
    @test occursin("fill=\"red\"",RG.to_svg(mat;foreground="red"))
    @test_throws RG.InvalidColorError RG.to_png(mat;foreground="red")
    for dpi in (NaN,Inf,-1,0,1e-320,true,"300",big"1e-10000",big"1e10000")
        @test_throws RG.InvalidInputError RG.render_dimensions(mat;dpi=dpi)
    end
    for scale in (0,-1,NaN,Inf,true,1.0,big(typemax(Int))+1)
        @test_throws RG.InvalidInputError RG.to_svg(mat;scale=scale)
    end
    for margin in (-1,NaN,Inf,true,1.0,big(typemax(Int))+1)
        @test_throws RG.InvalidInputError RG.to_svg(mat;margin=margin)
    end
    @test_throws RG.InvalidInputError RG.to_png(mat;scale=1025,margin=0)
    @test_throws RG.InvalidInputError RG.to_svg(mat;scale=RG.MAX_GEOMETRY_INTEGER)
    @test_throws RG.InvalidInputError RG.to_svg(mat;margin=RG.MAX_GEOMETRY_INTEGER)
    for badmatrix in (zeros(Bool,0,0),zeros(Bool,2,1),zeros(Int,2,2),[[true]],"1",zeros(Bool,178,178))
        @test_throws RG.InvalidInputError RG.to_svg(badmatrix)
    end
    for format in ("other",nothing,missing,1)
        @test_throws RG.InvalidOutputError RG.to_data_url(mat;format=format)
    end
    # Independent bit-at-a-time CRC and stored-block/Adler parser.
    be32(b,p) = foldl((v,x)->(v<<8)|UInt32(x),b[p:p+3];init=UInt32(0))
    function independent_crc(bytes)
        c=typemax(UInt32)
        for b in bytes
            c ⊻= b
            for _ in 1:8
                c=(c>>1) ⊻ (isodd(c) ? UInt32(0xedb88320) : UInt32(0))
            end
        end
        c ⊻ typemax(UInt32)
    end
    # >65535 bytes exercises multiple blocks; asymmetry checks row/column order.
    m=Bool[true false true; false true false; true true false]
    png=RG.to_png(m;scale=32,margin=1)
    p=9; rawidat=UInt8[]; kinds=String[]
    while p <= length(png)
        n=Int(be32(png,p)); push!(kinds,String(png[p+4:p+7])); data=png[p+8:p+7+n]
        @test be32(png,p+8+n)==independent_crc(png[p+4:p+7+n])
        last(kinds)=="IDAT" && append!(rawidat,data)
        p+=12+n
    end
    @test kinds==["IHDR","IDAT","IEND"]
    @test rawidat[1:2]==UInt8[0x78,0x01]
    raw=UInt8[]; p=3; final=false; blocks=0
    while !final
        blocks+=1; flag=rawidat[p]; p+=1
        @test flag in (0,1)
        final=flag==1
        n=Int(rawidat[p])+(Int(rawidat[p+1])<<8)
        inv=Int(rawidat[p+2])+(Int(rawidat[p+3])<<8); p+=4
        @test n ⊻ inv == 65535
        append!(raw,rawidat[p:p+n-1]); p+=n
    end
    @test blocks>1
    a,b=1,0
    for v in raw
        a=mod(a+v,65521); b=mod(b+a,65521)
    end
    @test be32(rawidat,p)==UInt32((b<<16)|a)
    @test p+3==length(rawidat)
    im=RG.to_pixels(m;scale=32,margin=1); stride=4im.width
    @test length(raw)==(stride+1)*im.height
    for y in 0:im.height-1
        @test raw[y*(stride+1)+1]==0
        @test raw[y*(stride+1)+2:(y+1)*(stride+1)]==im.pixels[y*stride+1:(y+1)*stride]
    end
end

@testset "GS1 catalog and element strings" begin
    @test length(RG.get_supported_gs1_ais())==50
    for info in RG.get_supported_gs1_ais()
        @test RG.get_gs1_ai_info(info.ai) === info
        value=info.length.is_variable ? (info.value_kind=="numeric" ? "123" : "ABC") : repeat("0",info.length.exact)
        e=RG.GS1Element(info.ai,value)
        @test RG.parse_gs1_element_string(RG.create_gs1_element_string([e])).elements == [e]
        @test RG.parse_gs1_human_readable(RG.gs1_to_human_readable([e])) == [e]
        @test !RG.validate_gs1_elements([RG.GS1Element(info.ai,value*repeat("0",100))]).ok
    end
    @test RG.get_gs1_ai_info("03") === nothing
    @test RG.get_gs1_ai_info(1) === nothing
    @test RG.calculate_gtin_check_digit("0950600013435")=="2"
    @test RG.append_gtin_check_digit("0950600013435")=="09506000134352"
    @test RG.validate_gtin_check_digit("09506000134352")
    @test !RG.validate_gtin_check_digit("09506000134353")
    @test RG.append_sscc_check_digit("12345678901234567")=="123456789012345675"
    @test RG.validate_sscc_check_digit("123456789012345675")
    @test !RG.validate_sscc_check_digit("123456789012345674")
    for f in (RG.calculate_gs1_check_digit,RG.validate_gs1_check_digit,RG.calculate_gtin_check_digit,RG.append_gtin_check_digit,RG.validate_gtin_check_digit,RG.calculate_sscc_check_digit,RG.append_sscc_check_digit,RG.validate_sscc_check_digit)
        for bad in ("","abc",123,true,nothing,String(UInt8[0xff]))
            @test_throws RG.InvalidGs1Error f(bad)
        end
    end
    e=RG.parse_gs1_human_readable("(01)09506000134352(10)LOT%1(17)251231")
    raw=RG.create_gs1_element_string(e)
    @test raw=="010950600013435210LOT%1\x1d17251231"
    @test RG.parse_gs1_element_string(raw).has_separators
    @test RG.parse_gs1_element_string(raw).elements==e
    @test RG.normalize_gs1_elements(raw)==e
    @test RG.normalize_gs1_elements("(01)09506000134352")==e[1:1]
    @test RG.create_gs1_element_string(["10"=>"100%REAL"])=="10100%REAL"
    @test RG.gs1_element_string_to_human_readable(raw)=="(01)09506000134352(10)LOT%1(17)251231"
    for bad in ("","\x1d0109506000134352","0109506000134352\x1d","10A\x1d","10A\x1d\x1d17251231","10ABC17251231","03999","0109506000134353","1123","10雪",String(UInt8[0x31,0x30,0xff]))
        @test_throws RG.InvalidGs1Error RG.parse_gs1_element_string(bad)
        @test !RG.validate_gs1_element_string(bad).ok
    end
    result=RG.validate_gs1_elements([(ai="01",value="bad"),(ai="10",value="")])
    @test !result.ok && length(result.errors)==2
    @test result.errors[1].element_index==0
    @test length(RG.validate_gs1_elements([(ai="01",value="bad"),(ai="10",value="")];collect_all_errors=false).errors)==1
    @test !RG.validate_gs1_elements(["10"=>"A"];context="digital-link").ok
    @test !RG.validate_gs1_element_string("10A";context="digital-link").ok
    @test !RG.validate_gs1_elements(e;collect_all_errors=1).ok
    @test !RG.validate_gs1_elements(e;allow_unsupported_ai=1).ok
    @test !RG.validate_gs1_elements(e;context=missing).ok
    @test_throws RG.InvalidGs1Error RG.create_gs1_element_string(Iterators.repeated("10"=>"A"))
    @test_throws RG.InvalidGs1Error RG.create_gs1_element_string(fill("10"=>repeat("A",90),RG.GS1_MAX_ELEMENTS))
    @test_throws RG.InvalidGs1Error RG.parse_gs1_element_string(repeat("A",RG.GS1_MAX_INPUT_CHARACTERS+1))
end

@testset "Strict GS1 Digital Link" begin
    gtin="09506000134352"; root="https://example.com/01/"*gtin
    e=RG.parse_gs1_human_readable("(01)"*gtin*"(10)LOT%1(17)251231(21)SER/1")
    u=RG.create_gs1_digital_link(e;base_url="HTTPS://ID.GS1.ORG:443/prefix/./x/../")
    @test u=="https://id.gs1.org/prefix/01/"*gtin*"/10/LOT%251/21/SER%2F1?17=251231"
    @test RG.normalize_gs1_digital_link(u)==u
    p=RG.parse_gs1_digital_link(u)
    @test (length(p.elements),length(p.path_elements),length(p.query_elements))==(4,3,1)
    @test !occursin("/10/",RG.create_gs1_digital_link(e;base_url="https://example.com",path_ais=[]))
    for dot in (".","..")
        value=RG.create_gs1_digital_link(["01"=>gtin,"10"=>dot];base_url="https://example.com")
        @test value==root*"?10="*dot
        @test RG.normalize_gs1_digital_link(value)==value
        @test RG.parse_gs1_digital_link(value).query_elements[1].value==dot
    end
    value=RG.create_gs1_digital_link(["01"=>gtin,"10"=>"%2e"];base_url="https://example.com")
    @test value==root*"/10/%252e"
    @test RG.parse_gs1_digital_link(value).elements[2].value=="%2e"
    raw="HTTPS://EXAMPLE.COM:443/pre/./a/../01/"*gtin*"?note=+A%20B+&10=+LOT+&other=%2B&note=%E6%BC%A2%E5%AD%97&empty&tab=%09&nul=%00"
    canonical="https://example.com/pre/01/"*gtin*"/10/%20LOT%20?note=+A+B+&other=%2B&note=%E6%BC%A2%E5%AD%97&empty=&tab=%09&nul=%00"
    @test RG.normalize_gs1_digital_link(raw)==canonical
    @test RG.normalize_gs1_digital_link(canonical)==canonical
    @test RG.parse_gs1_digital_link(canonical).unknown_query[4].value==""
    @test RG.parse_gs1_digital_link(canonical).unknown_query[3].value=="漢字"
    @test length(RG.validate_gs1_digital_link("http://example.com/01/"*gtin*"?note=A").warnings)==2
    @test !RG.validate_gs1_digital_link(raw;unknown_query="reject").ok
    @test !RG.validate_gs1_digital_link(raw;normalize=true).ok
    @test_throws RG.InvalidGs1Error RG.normalize_gs1_digital_link(raw;mode=missing)
    reject_hosts=("0x","0X","1.0x","example.0x","0x.","1.0X","1.2.3.0x","127.1","2130706433","0x7f000001","127.00.0.1","127.0.0.1.","256.0.0.1","example..com","-bad.example","bad-.example","a_b.example","user@example.com","%65xample.com","[fe80::1%25eth0]","例.jp","[1:2:3]","[1:2:3:4:5:6:7:8:9]","[1::2::3]","[:::1]","[1::2:]","[:1::2]","[::ffff:192.00.2.1]","[::1]suffix","[gggg::]")
    for host in reject_hosts
        uri="https://"*host*"/01/"*gtin
        @test_throws RG.InvalidGs1Error RG.parse_gs1_digital_link(uri)
        @test_throws RG.InvalidGs1Error RG.normalize_gs1_digital_link(uri)
        result=RG.validate_gs1_digital_link(uri)
        @test !result.ok && result.errors[1].code=="GS1_DIGITAL_LINK_UNSUPPORTED_HOST"
    end
    for host in ("[::]","[::1]","[2001:db8::1]","[1:2:3:4:5:6:7:8]","[::ffff:192.0.2.1]","127.0.0.1","EXAMPLE.COM.")
        @test RG.parse_gs1_digital_link("https://"*host*"/01/"*gtin).primary.value==gtin
    end
    for dot in (".","..","%2e","%2e.",".%2E","%2e%2E"), suffix in ("/10/"*dot,"/"*dot*"/A")
        @test_throws RG.InvalidGs1Error RG.parse_gs1_digital_link(root*suffix)
        @test RG.validate_gs1_digital_link(root*suffix).errors[1].code=="GS1_INVALID_DIGITAL_LINK_PLACEMENT"
    end
    for suffix in ("?10=%","?x=%FF","?10=A&10=B","/17/251231","?03=A","#","#x","?10=A B","/10/%C0%AF","/10/%ED%A0%80","?x=%F4%90%80%80")
        @test_throws RG.InvalidGs1Error RG.parse_gs1_digital_link(root*suffix)
        @test !RG.validate_gs1_digital_link(root*suffix).ok
    end
    for uri in ("https://example.com/%FF/01/"*gtin,"https://example.com:65536/01/"*gtin,"https://example.com:/01/"*gtin,"http:example.com/01/"*gtin,"ftp://example.com/01/"*gtin," https://example.com/01/"*gtin,"https://example.com\\a/01/"*gtin)
        @test_throws RG.InvalidGs1Error RG.parse_gs1_digital_link(uri)
    end
    good=("","/","/prefix","/prefix/sub/","/./prefix","/old/../prefix","/01/../prefix","/00/../prefix","/414/../prefix","/%30%31/%2E%2E/prefix","/prefix//sub","/prefix/./sub/../end","/prefix%20space","/%E6%BC%A2","/000/010/4140","/%2530%2531","/01/../","/01/%2e%2e/00/%2e%2e/414/%2e%2e","/漢字")
    bad=("/01/prefix","/00/prefix","/414/prefix","/prefix/01","/prefix/00","/prefix/414","/%30%31/prefix","/%30%30/prefix","/%34%31%34/prefix","/0%31/prefix","/%300/prefix","/4%314/prefix","/./01/prefix","/old/../01/prefix","/01/./prefix","/prefix/%30%31/","/01/x/../prefix","/%30%31/x/%2E%2E/prefix")
    for (primary,value) in (("01",gtin),("00","123456789012345675"),("414","1234567890123"))
        elements=[primary=>value,"10"=>"LOT","17"=>"251231"]
        for prefix in good
            uri=RG.create_gs1_digital_link(elements;base_url="https://example.com"*prefix,primary_ai=primary)
            @test RG.parse_gs1_digital_link(uri).elements==RG.normalize_gs1_elements(elements)
            @test RG.parse_gs1_digital_link(uri;primary_ai=primary).elements==RG.normalize_gs1_elements(elements)
            @test RG.normalize_gs1_digital_link(uri)==uri
        end
        for prefix in bad, f in (RG.create_gs1_digital_link,RG.gs1_digital_link,RG.gs1_to_digital_link)
            @test_throws RG.InvalidGs1Error f(elements;base_url="https://example.com"*prefix,primary_ai=primary)
        end
    end
    for unicode in ("雪","漢字","🙂","é")
        p=RG.parse_gs1_digital_link(root*"?note="*unicode)
        @test p.unknown_query[1].value==unicode
        @test RG.parse_gs1_digital_link(RG.normalize_gs1_digital_link(root*"?note="*unicode)).unknown_query[1].value==unicode
    end
end
