using Test
@testset "Strict built-in JSON" begin
    for v in (nothing,true,false,0,typemax(Int),typemin(Int),1.25,"", "hello\n\r\t\0\b\f日😀",Any[1,nothing,true,"日"],Dict("x"=>"\\\"/","unicode"=>"日😀"))
        @test SpecQR.json_parse(SpecQR.json_stringify(v))==v
    end
    @test SpecQR.json_parse("\"\\ud83d\\ude00\"")=="😀"
    @test SpecQR.json_parse("\"\\u0000\"")=="\0"
    for s in ("", " ","[1,]","{\"a\":1,}","{\"a\":1,\"a\":2}","01","-01","+1","1.",".1","1e","1e309","NaN","true false","\"\\ud800\"","\"\\udc00\"","\"\\ud800x\"","\"\\x\"","\"\n\"",repeat("[",66)*"0"*repeat("]",66),"18446744073709551616")
        @test_throws SpecQR.InvalidInputError SpecQR.json_parse(s)
    end
    for b in (UInt8[0x22,0xff,0x22],UInt8[0x22,0xed,0xa0,0x80,0x22],UInt8[0x22,0xc0,0x80,0x22])
        @test_throws SpecQR.InvalidInputError SpecQR.json_parse(b)
    end
    @test_throws SpecQR.InvalidInputError SpecQR.json_stringify(NaN)
    @test_throws SpecQR.InvalidInputError SpecQR.json_stringify(Inf)
    @test_throws SpecQR.InvalidInputError SpecQR.json_stringify(String(UInt8[0xff]))
    for i in 0:0x20
        s=string(Char(i)); @test SpecQR.json_parse(SpecQR.json_stringify(s))==s
    end
end
